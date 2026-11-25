#!/usr/bin/env python3
"""Helper of every video bridge pod (k8s-pods/meet-jvb/README.md). Python standard library only.

Modes:
  advertise  init container: read the node's public IPv4 from the Hetzner metadata service, write it
             for the jvb container (JVB_ADVERTISE_IPS), and copy custom-jvb.conf into jvb's /config.
  run        sidecar: keep the pod annotation controller.kubernetes.io/pod-deletion-cost equal to
             the bridge's participant count, so a scale-in removes the emptiest bridge; and serve
             only /metrics of the bridge on METRICS_PORT (the bridge's own REST API stays on
             127.0.0.1).
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
import shutil
import ssl
import sys
import threading
import time
import urllib.error
import urllib.request

COLIBRI = os.environ.get('JVB_COLIBRI_URL', 'http://127.0.0.1:8080')
METADATA_URL = os.environ.get('METADATA_URL', 'http://169.254.169.254/hetzner/v1/metadata/public-ipv4')
SHARED = os.environ.get('SHARED_DIR', '/shared')
DELETION_COST = 'controller.kubernetes.io/pod-deletion-cost'
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
    """Participant count from /colibri/stats (0 when the field is missing)."""
    return int(stats.get('participants', 0) or 0)


def deletion_cost_patch(count):
    return {'metadata': {'annotations': {DELETION_COST: str(int(count))}}}


def patch_own_pod(body):
    host = os.environ['KUBERNETES_SERVICE_HOST']
    port = os.environ.get('KUBERNETES_SERVICE_PORT', '443')
    url = 'https://%s:%s/api/v1/namespaces/%s/pods/%s' % (host, port, os.environ['POD_NAMESPACE'], os.environ['POD_NAME'])
    with open(os.path.join(SA_DIR, 'token'), encoding='ascii') as handle:
        token = handle.read().strip()
    context = ssl.create_default_context(cafile=os.path.join(SA_DIR, 'ca.crt'))
    req = urllib.request.Request(url, data=json.dumps(body).encode(), method='PATCH')
    req.add_header('Content-Type', 'application/merge-patch+json')
    req.add_header('Authorization', 'Bearer ' + token)
    with urllib.request.urlopen(req, timeout=10, context=context) as resp:
        return resp.status


def advertise():
    with urllib.request.urlopen(METADATA_URL, timeout=5) as resp:
        ip = public_ipv4(resp.read().decode('ascii'))
    with open(os.path.join(SHARED, 'advertise-ip'), 'w', encoding='ascii') as handle:
        handle.write(ip)
    src = os.environ.get('CUSTOM_JVB_CONF', '/talkchief/custom-jvb.conf')
    shutil.copyfile(src, os.path.join(os.environ.get('JVB_CONFIG_DIR', '/config'), 'custom-jvb.conf'))
    log('advertise', ip=ip)


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
    port = int(os.environ.get('METRICS_PORT', '9888'))
    server = http.server.ThreadingHTTPServer(('0.0.0.0', port), MetricsProxy)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    interval = int(os.environ.get('INTERVAL_SECONDS', '15'))
    last = None
    while True:
        try:
            _, stats = http_json(COLIBRI + '/colibri/stats')
            count = participants(stats)
            if count != last:
                patch_own_pod(deletion_cost_patch(count))
                log('deletion_cost', value=count)
                last = count
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
