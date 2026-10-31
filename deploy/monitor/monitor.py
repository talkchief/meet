"""TalkChief Cowork Meetings: server-side monitoring to Sentry (project talkchief-meetings).

Two jobs, both in this one small process:

1. Errors: follows the Docker logs of the meeting services (jicofo, jvb,
   prosody, web, coturn) and sends their error lines to Sentry, one issue per
   kind of error (numbers, IDs and addresses are blanked to group them). Each
   kind is sent at most once every 10 minutes; the next report says how many
   were held back.
2. Health: every minute, checks each service (meet-jvb, meet-jicofo,
   meet-bridge, meet-prosody, meet-web, meet-turn). A check that fails twice
   in a row opens an issue naming it, and the one Sentry cron monitor
   (meet-health) gets an error check-in; Sentry also alerts when its
   check-ins stop arriving (the whole server is down). It also reports when
   jicofo counts participants whose media failed, or video bridges that
   failed.

Logs are read from /dockerlogs (the host's /var/lib/docker/containers,
mounted read-only). Tokens, passwords, e-mail and IP addresses are removed
before anything is sent.
"""
import glob
import json
import os
import re
import socket
import ssl
import struct
import threading
import time
import urllib.error
import urllib.request

import sentry_sdk
from sentry_sdk.crons import capture_checkin
from sentry_sdk.crons.consts import MonitorStatus

LOG_ROOT = os.environ.get('DOCKER_LOGS', '/dockerlogs')
SERVICES = {'jicofo', 'jvb', 'prosody', 'web', 'coturn'}
PROJECT = os.environ.get('COMPOSE_PROJECT', '')
THROTTLE = 600
TURN_HOST = os.environ.get('TURN_HOST', '46.225.31.248')
HEALTH_SLUG = os.environ.get('HEALTH_MONITOR', 'meet-health')

sentry_sdk.init(
    dsn=os.environ['SENTRY_DSN'],
    environment=os.environ.get('SENTRY_ENVIRONMENT', 'production'),
    release=os.environ.get('SENTRY_RELEASE', 'meet-server'),
    send_default_pii=False,
    traces_sample_rate=0,
    server_name='meet.talkchief.io',
    default_integrations=False,
    integrations=[],
)
sentry_sdk.set_tag('component', 'server')


def log(*a):
    print(time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()), *a, flush=True)


# ── Errors from the service logs ─────────────────────────────────────────
SCRUB = [
    (re.compile(r'eyJ[\w-]{10,}\.[\w-]{10,}\.[\w-]{10,}'), '[token]'),
    (re.compile(r'(?i)((?:password|passwd|secret|token|jwt|credential)s?["\']?\s*[=:]\s*)["\']?[^\s,"\'&]+'), r'\1[removed]'),
    (re.compile(r'[\w.+-]+@(?![\w.-]*jitsi\b)[\w-]+\.[\w.-]+'), '[email]'),   # not XMPP addresses (...@muc.meet.jitsi)
    (re.compile(r'\b(?:\d{1,3}\.){3}\d{1,3}(?::\d+)?\b'), '[ip]'),
    (re.compile(r'\b[0-9a-f]{0,4}(?::[0-9a-f]{0,4}){3,7}\b', re.I), '[ip]'),
]
NORMALIZE = [
    (re.compile(r'\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b', re.I), '<id>'),
    (re.compile(r'\b[0-9a-f]{6,}\b', re.I), '<id>'),
    (re.compile(r'\b[a-z0-9]{20,}\b', re.I), '<id>'),
    (re.compile(r'\d+'), '<n>'),
    (re.compile(r'\s+'), ' '),
]
# [level, rest] for each service's log format.
JAVA = re.compile(r'\b(SEVERE|WARNING|INFO|FINE\w*):\s*(.*)')                # jicofo, jvb (java.util.logging)
PROSODY = re.compile(r'^\S+ \S+ (\S+)\s+(error|warn|info|debug)\s+(.*)')     # prosody
NGINX = re.compile(r'\[(emerg|alert|crit|error|warn)\]\s*(?:\d+#\d+:\s*)?(.*)')
# Error lines that are not problems.
IGNORE = [
    re.compile(r'No such file or directory'),          # nginx: scanners asking for missing files
    re.compile(r'client intended to send too large'),
]


def scrub(text):
    for pattern, repl in SCRUB:
        text = pattern.sub(repl, text)
    return text


def normalize(text):
    for pattern, repl in NORMALIZE:
        text = pattern.sub(repl, text)
    return text.strip()[:200]


def classify(service, line):
    """Returns (level, message, logger) for an error line, else None."""
    if service in ('jicofo', 'jvb'):
        m = JAVA.search(line)
        if m and m.group(1) == 'SEVERE':
            return 'error', m.group(2), service
    elif service == 'prosody':
        m = PROSODY.match(line)
        if m and m.group(2) == 'error':
            return 'error', m.group(3), m.group(1)
    elif service == 'web':
        m = NGINX.search(line)
        if m and m.group(1) in ('emerg', 'alert', 'crit', 'error'):
            return ('fatal' if m.group(1) in ('emerg', 'alert') else 'error'), m.group(2), 'nginx'
    elif service == 'coturn':
        if re.search(r'\bERROR\b', line):
            return 'error', line, 'coturn'
    return None


sent_at = {}
held = {}


def report(service, level, message, logger, context):
    message = scrub(message.strip())
    if any(p.search(message) for p in IGNORE):
        return
    key = (service, normalize(message))
    now = time.time()
    if now - sent_at.get(key, 0) < THROTTLE:
        held[key] = held.get(key, 0) + 1
        return
    sent_at[key] = now
    skipped = held.pop(key, 0)
    with sentry_sdk.new_scope() as scope:
        scope.set_level(level)
        scope.set_tag('service', service)
        scope.set_tag('logger', logger)
        scope.fingerprint = ['meet-server', service, key[1]]
        scope.set_context('log', {
            'service': service,
            'heldBackSinceLastReport': skipped,
            'nextLines': scrub('\n'.join(context))[:4000],
        })
        sentry_sdk.capture_message('%s: %s' % (service, message[:300]))
    log('reported', service, level, message[:120])


class Tail:
    def __init__(self, path, service):
        self.path, self.service = path, service
        self.f = open(path, 'r', encoding='utf-8', errors='replace')
        self.f.seek(0, os.SEEK_END)
        self.ino = os.fstat(self.f.fileno()).st_ino

    def lines(self):
        try:
            st = os.stat(self.path)
            if st.st_ino != self.ino or st.st_size < self.f.tell():   # rotated or truncated
                self.f.close()
                self.f = open(self.path, 'r', encoding='utf-8', errors='replace')
                self.ino = os.fstat(self.f.fileno()).st_ino
        except FileNotFoundError:
            return None
        out = []
        for raw in self.f.readlines():
            try:
                out.append(json.loads(raw).get('log', '').rstrip('\n'))
            except ValueError:
                pass
        return out


def discover():
    found = {}
    for cfg in glob.glob(os.path.join(LOG_ROOT, '*', 'config.v2.json')):
        try:
            with open(cfg, encoding='utf-8') as fh:
                c = json.load(fh)
        except (OSError, ValueError):
            continue
        labels = (c.get('Config') or {}).get('Labels') or {}
        service = labels.get('com.docker.compose.service')
        if service not in SERVICES or (PROJECT and labels.get('com.docker.compose.project') != PROJECT):
            continue
        if not (c.get('State') or {}).get('Running'):
            continue
        cid = c.get('ID', '')
        path = os.path.join(LOG_ROOT, cid, cid + '-json.log')
        if os.path.exists(path):
            found[path] = service
    return found


def follow_logs():
    tails = {}
    last_scan = 0
    while True:
        if time.time() - last_scan > 30:
            last_scan = time.time()
            current = discover()
            for path, service in current.items():
                if path not in tails:
                    try:
                        tails[path] = Tail(path, service)
                        log('following', service, path[-80:])
                    except OSError as e:
                        log('cannot follow', service, e)
            for path in list(tails):
                if path not in current:
                    tails.pop(path).f.close()
        for path, t in list(tails.items()):
            lines = t.lines()
            if lines is None:
                tails.pop(path).f.close()
                continue
            for i, line in enumerate(lines):
                hit = classify(t.service, line)
                if hit:
                    following = [l for l in lines[i + 1:i + 30] if l.startswith(('\t', ' ', 'Caused by', 'stack traceback'))]
                    report(t.service, hit[0], hit[1], hit[2], following)
        time.sleep(1)


# ── Health check-ins ─────────────────────────────────────────────────────
MONITOR = {
    'schedule': {'type': 'interval', 'value': 1, 'unit': 'minute'},
    'checkin_margin': 2,
    'max_runtime': 1,
    'failure_issue_threshold': 2,
    'recovery_threshold': 1,
    'timezone': 'UTC',
}


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None


# The monitor runs on the host's network: jicofo and the bridge only answer
# on the host's loopback (published 127.0.0.1:8888 and :8080), and the web
# container is reached the way visitors reach it, on 443 (its certificate is
# for meet.talkchief.io and is a Cloudflare origin certificate, so it is not
# verified; the connection never leaves the host).
LOCAL_TLS = ssl.create_default_context()
LOCAL_TLS.check_hostname = False
LOCAL_TLS.verify_mode = ssl.CERT_NONE
OPENER = urllib.request.build_opener(NoRedirect, urllib.request.HTTPSHandler(context=LOCAL_TLS))
SITE = {'Host': 'meet.talkchief.io'}


def http_ok(url, ok=lambda s: s == 200, headers=None):
    try:
        with OPENER.open(urllib.request.Request(url, headers=headers or {}), timeout=8) as r:
            return ok(r.status), 'HTTP %d' % r.status
    except urllib.error.HTTPError as e:
        return ok(e.code), 'HTTP %d' % e.code
    except Exception as e:  # noqa: BLE001 - any failure is a failed check
        return False, repr(e)[:200]


def stun_ok(host, port=3478):
    """Sends a STUN binding request to coturn and expects a binding success."""
    tid = os.urandom(12)
    req = struct.pack('!HHI12s', 0x0001, 0, 0x2112A442, tid)
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(3)
    try:
        for _ in range(2):
            s.sendto(req, (host, port))
            try:
                data, _ = s.recvfrom(2048)
            except socket.timeout:
                continue
            if len(data) >= 20 and struct.unpack('!H', data[:2])[0] == 0x0101 and data[8:20] == tid:
                return True, 'binding success'
        return False, 'no STUN answer'
    except OSError as e:
        return False, repr(e)[:200]
    finally:
        s.close()


def jicofo_stats():
    try:
        with OPENER.open('http://127.0.0.1:8888/stats', timeout=5) as r:
            return json.load(r)
    except Exception:  # noqa: BLE001 - reported by the meet-jicofo check
        return None


def bridge_ok():
    stats = jicofo_stats()
    if stats is None:
        return False, 'no jicofo stats'
    n = (stats.get('bridge_selector') or {}).get('operational_bridge_count', 0)
    return n >= 1, '%s operational video bridge(s)' % n


CHECKS = {
    'meet-jvb': lambda: http_ok('http://127.0.0.1:8080/about/health'),
    'meet-jicofo': lambda: http_ok('http://127.0.0.1:8888/about/health'),
    'meet-bridge': bridge_ok,          # jicofo can reach a working video bridge
    # Prosody through the web container's /http-bind proxy: 502 when prosody is down.
    'meet-prosody': lambda: http_ok('https://127.0.0.1/http-bind', ok=lambda s: s < 500, headers=SITE),
    'meet-web': lambda: http_ok('https://127.0.0.1/', ok=lambda s: s < 500, headers=SITE),
    'meet-turn': lambda: stun_ok(TURN_HOST),
}

# Jicofo counters that only go up when something went wrong in a meeting.
PROBLEM_COUNTERS = {
    ('participant_notifications', 'ice_failed'): 'participants whose media connection failed (ICE failed)',
    ('participant_notifications', 'request_restart'): 'participants who asked to restart their media session',
    ('bridge_failures', 'participants_moved'): 'participants moved off a failed video bridge',
    ('bridge_failures', 'bridges_removed'): 'video bridges removed after failing',
    ('bridge_selector', 'lost_bridges'): 'video bridges lost',
}
last_counts = {}


def meeting_problems():
    """Reports increases in jicofo's problem counters, with the current load."""
    stats = jicofo_stats()
    if stats is None:
        return
    load = {k: stats.get(k) for k in ('conferences', 'participants', 'largest_conference', 'total_conferences_created')}
    for (group, name), what in PROBLEM_COUNTERS.items():
        value = (stats.get(group) or {}).get(name)
        if not isinstance(value, int):
            continue
        before = last_counts.get((group, name))
        last_counts[(group, name)] = value
        if before is None or value <= before:      # first look, or jicofo restarted
            continue
        report_counter(name, value - before, what, load)


def report_counter(name, delta, what, load):
    key = ('jicofo-counter', name)
    now = time.time()
    if now - sent_at.get(key, 0) < THROTTLE:
        held[key] = held.get(key, 0) + delta
        return
    sent_at[key] = now
    total = delta + held.pop(key, 0)
    with sentry_sdk.new_scope() as scope:
        scope.set_level('warning')
        scope.set_tag('service', 'jicofo')
        scope.set_tag('problem', name)
        scope.fingerprint = ['meet-server', 'jicofo-counter', name]
        scope.set_context('meetings', dict(load, count=total))
        sentry_sdk.capture_message('jicofo: %d %s' % (total, what))
    log('reported counter', name, total)


def report_unhealthy(name, detail, minutes):
    """One issue per service that keeps failing, repeated at most hourly."""
    key = ('health', name)
    if time.time() - sent_at.get(key, 0) < 3600:
        return
    sent_at[key] = time.time()
    with sentry_sdk.new_scope() as scope:
        scope.set_level('error')
        scope.set_tag('service', name.replace('meet-', ''))
        scope.set_tag('check', name)
        scope.fingerprint = ['meet-health', name]
        scope.set_context('health', {'check': name, 'detail': detail, 'failingForMinutes': minutes})
        sentry_sdk.capture_message('%s health check failing: %s' % (name, detail))


def health_loop():
    fails = {}
    while True:
        started = time.time()
        unhealthy = []
        for name, check in CHECKS.items():
            ok, detail = check()
            before = fails.get(name, 0)
            fails[name] = 0 if ok else before + 1
            if ok != (before == 0):
                log('health', name, 'ok' if ok else 'FAILING', detail)
            if fails[name] >= 2:                       # twice in a row, like Sentry's own threshold
                unhealthy.append(name)
                report_unhealthy(name, detail, fails[name])
        # One heartbeat for the whole meeting server (the plan has one cron
        # monitor): error while any check keeps failing, and missing when the
        # server or this monitor is down.
        capture_checkin(monitor_slug=HEALTH_SLUG,
                        status=MonitorStatus.ERROR if unhealthy else MonitorStatus.OK,
                        monitor_config=MONITOR)
        meeting_problems()
        time.sleep(max(1, 60 - (time.time() - started)))


if __name__ == '__main__':
    log('meet monitor started; services:', ', '.join(sorted(SERVICES)))
    threading.Thread(target=health_loop, daemon=True).start()
    follow_logs()
