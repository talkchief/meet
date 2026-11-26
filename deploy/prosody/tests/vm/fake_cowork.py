# Fake Cowork for the meeting-service VM test: answers room_check from
# /state/rooms.json and logs every signed event to /state/events.log.
import hashlib, hmac, json, os, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SECRET = os.environ.get('SECRET', '').encode()

class H(BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get('Content-Length', '0')))
        sig = hmac.new(SECRET, body, hashlib.sha256).hexdigest()
        ok = hmac.compare_digest(sig, (self.headers.get('X-TalkChief-Signature') or '').lower())
        try:
            ev = json.loads(body)
        except Exception:
            ev = {}
        with open('/state/events.log', 'a') as f:
            f.write(json.dumps({'at': time.time(), 'signed': ok, **ev}) + '\n')
        if not ok:
            self.send_response(401); self.end_headers(); return
        if ev.get('event') == 'room_check':
            try:
                rooms = json.load(open('/state/rooms.json'))
            except Exception:
                rooms = {}
            r = rooms.get(ev.get('room'), {'allow': True})
            if r.get('delay'):
                time.sleep(r['delay'])
            status = r.get('status', 200)
            payload = json.dumps({k: r[k] for k in ('allow', 'instant', 'reason') if k in r}).encode()
            self.send_response(status)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        self.send_response(204); self.end_headers()

    def log_message(self, *a):
        pass

ThreadingHTTPServer(('0.0.0.0', 80), H).serve_forever()
