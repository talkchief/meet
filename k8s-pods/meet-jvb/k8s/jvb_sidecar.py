#!/usr/bin/env python3
"""Helper of every video bridge pod (k8s-pods/meet-jvb/README.md). Python standard library only.

Modes:
  advertise  init container: read the node's public IPv4 from the Hetzner metadata service, write it
             for the jvb container (JVB_ADVERTISE_IPS), write the node's site (hel1, nbg1, fsn1 from
             the metadata availability zone), and copy custom-jvb.conf into jvb's /config.
  run        sidecar: mark the pod with its site (annotation talkchief.io/bridge-site) and keep the
             pod annotation controller.kubernetes.io/pod-deletion-cost at the bridge's participant
             count, plus SITE_BONUS while it is the only bridge in its site, so a scale-in removes
             the emptiest bridge of a site that keeps another one and never empties a site while
             another site has two (L18); and serve only /metrics of the bridge on METRICS_PORT (the
             bridge's own REST API stays on 127.0.0.1).
  drain      preStop of this container: tell the bridge to drain (Jicofo puts no new conference
             on it), wait until it carries no participants, then ask for a graceful shutdown and
             wait until the bridge has exited or has no conference, then write the file the jvb
             container's preStop waits for. Bounded by the pod's termination grace period.

Never logs a secret; prints `meet-jvb-sidecar event=...` lines.
"""

import http.server
import ipaddress
import json
import os
import re
import signal
import shutil
import ssl
import sys
import threading
import time
import urllib.error
import urllib.request

COLIBRI = os.environ.get('JVB_COLIBRI_URL', 'http://127.0.0.1:8080')
METADATA_URL = os.environ.get('METADATA_URL', 'http://169.254.169.254/hetzner/v1/metadata/public-ipv4')
ZONE_URL = os.environ.get('ZONE_URL', 'http://169.254.169.254/hetzner/v1/metadata/availability-zone')
SHARED = os.environ.get('SHARED_DIR', '/shared')
DELETION_COST = 'controller.kubernetes.io/pod-deletion-cost'
SITE = 'talkchief.io/bridge-site'
# Larger than any participant count (the annotation is an int32), so the last bridge of a site goes
# after every bridge of a site that keeps one.
SITE_BONUS = 1000000
SITE_PATTERN = re.compile(r'^([a-z]+[0-9]+)(-dc[0-9]+)?$')
SA_DIR = os.environ.get('SA_DIR', '/var/run/secrets/kubernetes.io/serviceaccount')


def log(event, **fields):
    extra = ''.join(' %s=%s' % (k, v) for k, v in sorted(fields.items()))
    print('meet-jvb-sidecar event=%s%s' % (event, extra), flush=True)


def http_json(url, method='GET', body=None, timeout=5):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(url, data=data, method=method)
    if data is not None:
        req.add_header('Content-Type', 'application/json')
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        raw = resp.read()
        return resp.status, (json.loads(raw) if raw.strip() else {})


def public_ipv4(text):
    """The metadata answer as a public IPv4 address, or ValueError."""
    addr = ipaddress.IPv4Address(text.strip())
    if not addr.is_global:
        raise ValueError('not a public address')
    return str(addr)


def participants(stats):
    """Participants on this bridge from /colibri/stats (0 when the field is missing), without the
    relayed endpoints of other bridges: after a shard restart a relayed conference that Jicofo never
    expired kept "participants" at 9 with nobody on the bridge, so the drain waited out the 3 h grace
    period (test cluster 2026-11-25)."""
    return max(0, int(stats.get('participants', 0) or 0) - int(stats.get('octo_endpoints', 0) or 0))


def deletion_cost_patch(count):
    return {'metadata': {'annotations': {DELETION_COST: str(int(count))}}}


def site_of(zone):
    """The site (Hetzner location) of a metadata availability zone: 'hel1-dc2' -> 'hel1'; '' when the
    answer does not look like one."""
    match = SITE_PATTERN.match((zone or '').strip())
    return match.group(1) if match else ''


def site_patch(site):
    return {'metadata': {'annotations': {SITE: site}}}


def last_in_site(site, own_name, pods):
    """True when no other live bridge pod (not being deleted) carries this pod's site. A pod without a
    site (metadata unreadable, or not yet marked) never counts as the last of a site."""
    if not site:
        return False
    for pod in pods:
        meta = pod.get('metadata') or {}
        if meta.get('name') == own_name or meta.get('deletionTimestamp'):
            continue
        if (meta.get('annotations') or {}).get(SITE) == site:
            return False
    return True


def deletion_cost(count, last):
    """pod-deletion-cost (the ReplicaSet removes the lowest first): the participant count keeps the
    emptiest bridge first; the bonus keeps a site's last bridge until no site has two."""
    return int(count) + (SITE_BONUS if last else 0)


def api_request(path, method='GET', body=None):
    host = os.environ['KUBERNETES_SERVICE_HOST']
    port = os.environ.get('KUBERNETES_SERVICE_PORT', '443')
    with open(os.path.join(SA_DIR, 'token'), encoding='ascii') as handle:
        token = handle.read().strip()
    context = ssl.create_default_context(cafile=os.path.join(SA_DIR, 'ca.crt'))
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request('https://%s:%s%s' % (host, port, path), data=data, method=method)
    if data is not None:
        req.add_header('Content-Type', 'application/merge-patch+json')
    req.add_header('Authorization', 'Bearer ' + token)
    with urllib.request.urlopen(req, timeout=10, context=context) as resp:
        raw = resp.read()
        return resp.status, (json.loads(raw) if raw.strip() else {})


def patch_own_pod(body):
    status, _ = api_request('/api/v1/namespaces/%s/pods/%s' % (os.environ['POD_NAMESPACE'], os.environ['POD_NAME']),
                            method='PATCH', body=body)
    return status


def bridge_pods():
    """The bridge pods of this namespace (label app.kubernetes.io/name=meet-jvb)."""
    _, body = api_request('/api/v1/namespaces/%s/pods?labelSelector=app.kubernetes.io%%2Fname%%3Dmeet-jvb'
                          % os.environ['POD_NAMESPACE'])
    return body.get('items') or []


def advertise():
    with urllib.request.urlopen(METADATA_URL, timeout=5) as resp:
        ip = public_ipv4(resp.read().decode('ascii'))
    with open(os.path.join(SHARED, 'advertise-ip'), 'w', encoding='ascii') as handle:
        handle.write(ip)
    # The site only orders scale-in: a bridge whose site cannot be read still starts (it just never
    # counts as the last bridge of a site).
    try:
        with urllib.request.urlopen(ZONE_URL, timeout=5) as resp:
            site = site_of(resp.read().decode('ascii', 'replace'))
    except (urllib.error.URLError, OSError):
        site = ''
    with open(os.path.join(SHARED, 'site'), 'w', encoding='ascii') as handle:
        handle.write(site)
    src = os.environ.get('CUSTOM_JVB_CONF', '/talkchief/custom-jvb.conf')
    shutil.copyfile(src, os.path.join(os.environ.get('JVB_CONFIG_DIR', '/config'), 'custom-jvb.conf'))
    log('advertise', ip=ip, site=site or 'unknown')


class MetricsProxy(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        if self.path == '/healthz':
            self.send_response(204)
            self.end_headers()
            return
        if self.path != '/metrics':
            self.send_response(404)
            self.end_headers()
            return
        try:
            # The bridge's /metrics fails with a NullPointerException (HTTP 500) when the request has
            # no Accept header (stable-11248-2, test cluster 2026-11-25), so ask for the text format.
            req = urllib.request.Request(COLIBRI + '/metrics', headers={'Accept': 'text/plain; version=0.0.4'})
            with urllib.request.urlopen(req, timeout=5) as resp:
                body = resp.read()
                ctype = resp.headers.get('Content-Type', 'text/plain')
            self.send_response(200)
            self.send_header('Content-Type', ctype)
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except (urllib.error.URLError, OSError):
            self.send_response(502)
            self.end_headers()


def run():
    # PID 1 of the container: without a handler the kernel ignores SIGTERM, so after the preStop drain
    # the pod waited out terminationGracePeriodSeconds (3 h) and kept its bridge node (test cluster
    # 2026-11-25). The drain itself runs in the preStop process, so exiting here is safe.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    port = int(os.environ.get('METRICS_PORT', '9888'))
    server = http.server.ThreadingHTTPServer(('0.0.0.0', port), MetricsProxy)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    interval = int(os.environ.get('INTERVAL_SECONDS', '15'))
    try:
        with open(os.path.join(SHARED, 'site'), encoding='ascii') as handle:
            site = site_of(handle.read())
    except OSError:
        site = ''
    marked = not site
    alone = False
    last = None
    while True:
        try:
            if not marked:
                patch_own_pod(site_patch(site))
                log('site', value=site)
                marked = True
            _, stats = http_json(COLIBRI + '/colibri/stats')
            count = participants(stats)
            try:
                alone = last_in_site(site, os.environ['POD_NAME'], bridge_pods())
            except (urllib.error.URLError, OSError, ValueError) as err:
                # Keep the previous answer: dropping the bonus on an API hiccup could let a scale-in
                # take a site's last bridge.
                log('list_failed', reason=type(err).__name__)
            cost = deletion_cost(count, alone)
            if cost != last:
                patch_own_pod(deletion_cost_patch(cost))
                log('deletion_cost', value=cost, participants=count, last_in_site=alone)
                last = cost
        except (urllib.error.URLError, OSError, ValueError) as err:
            log('stats_failed', reason=type(err).__name__)
        time.sleep(interval)


def drain(deadline_seconds=None, poll=10, clock=time.monotonic, sleep=time.sleep):
    """Drain, wait for 0 participants, graceful shutdown, wait for the bridge to finish."""
    deadline_seconds = deadline_seconds or int(os.environ.get('DRAIN_DEADLINE_SECONDS', '10740'))
    end = clock() + deadline_seconds
    done_file = os.path.join(SHARED, 'drained')
    try:
        status, _ = http_json(COLIBRI + '/colibri/drain/enable', method='POST')
        log('drain_enabled', status=status)
        while clock() < end:
            _, stats = http_json(COLIBRI + '/colibri/stats')
            if participants(stats) == 0:
                break
            sleep(poll)
        status, _ = http_json(COLIBRI + '/colibri/shutdown', method='POST', body={'graceful-shutdown': 'true'})
        log('graceful_shutdown', status=status)
        misses = 0
        while clock() < end and misses < 3:
            try:
                _, stats = http_json(COLIBRI + '/colibri/stats')
                misses = 0
                if int(stats.get('conferences', 0) or 0) == 0 and participants(stats) == 0:
                    break
            except (urllib.error.URLError, OSError):
                misses += 1
            sleep(poll)
    except (urllib.error.URLError, OSError, ValueError) as err:
        # The bridge is gone or not answering: nothing left to drain.
        log('drain_unreachable', reason=type(err).__name__)
    with open(done_file, 'w', encoding='ascii') as handle:
        handle.write('done\n')
    log('drained')


def main(argv):
    mode = argv[1] if len(argv) > 1 else 'run'
    if mode == 'advertise':
        advertise()
    elif mode == 'drain':
        drain()
    elif mode == 'run':
        run()
    else:
        sys.exit('usage: jvb_sidecar.py advertise|run|drain')


if __name__ == '__main__':
    main(sys.argv)
