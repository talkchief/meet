# Fake Cowork for the meeting-service VM test: answers room_check from
# /state/rooms.json and logs every signed event to /state/events.log.
# rooms.json: {"<room>": {"allow": bool, "instant": bool, "reason": str,
#   "delay": seconds, "status": http code, "guests_off": bool (refuse guests),
#   "fail_events": n (answer 500 to the first n room events of this room)}}
import hashlib, hmac, json, os, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SECRET = os.environ.get('SECRET', '').encode()


def load_rooms():
    try:
        return json.load(open('/state/rooms.json'))
    except Exception:
        return {}


class H(BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get('Content-Length', '0')))
        sig = hmac.new(SECRET, body, hashlib.sha256).hexdigest()
        ok = hmac.compare_digest(sig, (self.headers.get('X-TalkChief-Signature') or '').lower())
        try:
            ev = json.loads(body)
        except Exception:
            ev = {}
        rooms = load_rooms()
        r = rooms.get(ev.get('room'), {'allow': True})
        status = 200 if ev.get('event') == 'room_check' else 204
        if ok and ev.get('event') in ('room_created', 'room_destroyed') and r.get('fail_events', 0) > 0:
            # Cowork not taking the event (restarting).
            r['fail_events'] -= 1
            rooms[ev.get('room')] = r
            json.dump(rooms, open('/state/rooms.json', 'w'))
            status = 500
        if not ok:
            status = 401
        with open('/state/events.log', 'a') as f:
            f.write(json.dumps({'at': time.time(), 'signed': ok, 'status': status, **ev}) + '\n')
        if status in (401, 500):
            self.send_response(status)
            self.end_headers()
            return
        if ev.get('event') == 'room_check':
            if ev.get('guest') and r.get('guests_off'):
                r = {'allow': False, 'reason': 'guests_off', 'instant': r.get('instant', False)}
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
        self.send_response(204)
        self.end_headers()

    def log_message(self, *a):
        pass


ThreadingHTTPServer(('0.0.0.0', 80), H).serve_forever()
