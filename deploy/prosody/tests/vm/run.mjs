// VM test of mod_talkchief_room_gate and mod_talkchief_host_drop against the
// real Prosody and Jicofo (docker-jitsi-meet, deploy/VERSION), with a fake
// Cowork (fake_cowork.py). Runs on the compose network.
import { client, xml } from '@xmpp/client';
import jwt from 'jsonwebtoken';
import fs from 'node:fs';
import crypto from 'node:crypto';

const KEY = fs.readFileSync('/state/key.pem');
const TENANT = 'acme';
const GRACE = 10; // talkchief_host_drop_grace in this test's .env
const results = [];
const sleep = ms => new Promise(r => setTimeout(r, ms));

// Host-drop scenarios use member rooms (no g- prefix): a g- room switches its
// lobby on when the host arrives (mod_talkchief_room_policy), and a raw XMPP
// test client can't knock and be admitted. The host-drop logic is the same for
// both kinds of room; the gate scenarios use g- rooms.
function roomName(prefix = '') {
    return prefix + crypto.randomBytes(13).toString('hex').slice(0, 26);
}
function mucJid(room) {
    return `${room}@muc.${TENANT}.meet.jitsi`;
}
function setRooms(map) {
    fs.writeFileSync('/state/rooms.json', JSON.stringify(map));
}
function events() {
    return fs.readFileSync('/state/events.log', 'utf8').trim().split('\n').filter(Boolean).map(l => JSON.parse(l));
}
function token(room, affiliation, id) {
    return jwt.sign({
        iss: 'talkchief-cowork', aud: 'talkchief-meet', sub: TENANT, room,
        context: { user: { id, name: id, affiliation } }
    }, KEY, { algorithm: 'RS256', keyid: 'talkchief-cowork-1', expiresIn: '1h' });
}

async function connect(room, affiliation, id) {
    const url = new URL('ws://prosody:5280/xmpp-websocket');
    url.searchParams.set('room', room);
    url.searchParams.set('prefix', TENANT); // as the web client sends it (tenant rooms)
    url.searchParams.set('token', token(room, affiliation, id));
    const x = client({ service: url.toString(), domain: 'meet.jitsi' });
    x.on('error', () => {});
    const stanzas = [];
    x.on('stanza', s => stanzas.push(s));
    await x.start();
    return { x, stanzas, id };
}

// An anonymous guest on the guest domain, as from an invitation page.
async function connectGuest(room) {
    const url = new URL('ws://prosody:5280/xmpp-websocket');
    url.searchParams.set('room', room);
    url.searchParams.set('prefix', TENANT);
    const x = client({ service: url.toString(), domain: 'guest.meet.jitsi' });
    x.on('error', () => {});
    const stanzas = [];
    x.on('stanza', s => stanzas.push(s));
    await x.start();
    return { x, stanzas, id: 'guest' };
}

async function startConference(room) {
    const res = await fetch('http://jicofo:8888/conference-request/v1', {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ room: mucJid(room), properties: {} })
    });
    return res.status;
}

// Joins and resolves with 'joined', or the error condition.
async function join(c, room, nick) {
    c.nick = nick;
    const to = `${mucJid(room)}/${nick}`;
    // The display name, as the web client sends it (the lobby requires one).
    await c.x.send(xml('presence', { to }, xml('x', { xmlns: 'http://jabber.org/protocol/muc' }),
        xml('nick', { xmlns: 'http://jabber.org/protocol/nick' }, nick)));
    for (let i = 0; i < 100; i++) {
        for (const s of c.stanzas) {
            if (s.name === 'presence' && s.attrs.from === to) {
                if (s.attrs.type === 'error') {
                    const err = s.getChild('error');
                    return err?.children?.find(ch => ch.name !== 'text')?.name || 'error';
                }
                const codes = (s.getChild('x', 'http://jabber.org/protocol/muc#user')?.getChildren('status') || []).map(st => st.attrs.code);
                if (codes.includes('110')) {
                    return 'joined';
                }
            }
        }
        await sleep(100);
    }
    return 'timeout';
}

function destroyed(c, room) {
    return c.stanzas.some(s => s.name === 'presence' && s.attrs.type === 'unavailable' &&
        s.attrs.from?.startsWith(mucJid(room)) &&
        s.getChild('x', 'http://jabber.org/protocol/muc#user')?.getChild('destroy'));
}

function check(name, ok, detail = '') {
    results.push({ name, ok });
    console.log(`${ok ? 'PASS' : 'FAIL'} ${name}${detail ? ` (${detail})` : ''}`);
}

async function meeting(room, rooms) {
    setRooms(rooms);
    const status = await startConference(room);
    await sleep(1500);
    return status;
}

// 1. Allowed Meet now room; the host leaves the member behind -> ended.
{
    const room = roomName();
    await meeting(room, { [room]: { allow: true, instant: true } });
    const host = await connect(room, 'owner', 'host1');
    const member = await connect(room, 'member', 'member1');
    check('allowed room: host joins', await join(host, room, 'host') === 'joined');
    check('allowed room: member joins', await join(member, room, 'member') === 'joined');
    const checks = events().filter(e => e.event === 'room_check' && e.room === room);
    check('Cowork was asked once, signed', checks.length === 1 && checks[0].signed, `${checks.length} checks`);
    await host.x.stop();
    await sleep((GRACE - 4) * 1000);
    check('room still open before the grace period ends', !destroyed(member, room));
    await sleep(8000);
    check('room ended for the member after the grace period', destroyed(member, room));
    const end = events().find(e => e.event === 'room_destroyed' && e.room === room);
    check('room-closed event says host_left', end?.reason === 'host_left', JSON.stringify(end));
    await member.x.stop().catch(() => {});
}

// 2. The host comes back in time -> nothing happens.
{
    const room = roomName();
    await meeting(room, { [room]: { allow: true, instant: true } });
    const host = await connect(room, 'owner', 'host2');
    const member = await connect(room, 'member', 'member2');
    await join(host, room, 'host');
    await join(member, room, 'member');
    await host.x.stop();
    await sleep(3000);
    const back = await connect(room, 'owner', 'host2');
    const rejoined = await join(back, room, 'hostback');
    check('host rejoins within the grace period', rejoined === 'joined', rejoined);
    await sleep((GRACE + 3) * 1000);
    check('room kept when the host is back', !destroyed(member, room));
    await back.x.stop(); await member.x.stop();
}

// 3. A co-host stays -> nothing happens.
{
    const room = roomName();
    await meeting(room, { [room]: { allow: true, instant: true } });
    const host = await connect(room, 'owner', 'host3');
    const member = await connect(room, 'member', 'member3');
    const other = await connect(room, 'member', 'member3b');
    await join(host, room, 'host');
    await join(member, room, 'member');
    await join(other, room, 'other');
    const grant = await host.x.iqCaller.request(xml('iq', { type: 'set', to: mucJid(room) },
        xml('query', { xmlns: 'http://jabber.org/protocol/muc#admin' }, xml('item', { nick: 'member', role: 'moderator' }))))
        .then(() => 'ok').catch(e => e.condition || String(e));
    check('host makes the member a moderator (co-host)', grant === 'ok', grant);
    await host.x.stop();
    await sleep((GRACE + 3) * 1000);
    check('room kept while a co-host stays', !destroyed(other, room));
    await member.x.stop(); await other.x.stop();
}

// 4. A scheduled meeting (not instant) -> the host leaving never ends it.
{
    const room = roomName();
    await meeting(room, { [room]: { allow: true } });
    const host = await connect(room, 'owner', 'host4');
    const member = await connect(room, 'member', 'member4');
    await join(host, room, 'host');
    await join(member, room, 'member');
    await host.x.stop();
    await sleep((GRACE + 3) * 1000);
    check('scheduled meeting kept when the host leaves', !destroyed(member, room));
    await member.x.stop();
}

// 5. Refused rooms: ended, unknown -> not-authorized, even with a valid token.
for (const reason of [ 'ended', 'unknown', 'cancelled' ]) {
    const room = roomName('g-');
    await meeting(room, { [room]: { allow: false, reason } });
    const c = await connect(room, 'owner', 'late-' + reason);
    const r = await join(c, room, 'late');
    check(`${reason} room refused with a valid token`, r === 'not-authorized', r);
    await c.x.stop();
}

// 6. Fail open: Cowork too slow (5 s > 2 s timeout) or erroring -> let in.
for (const [ label, answer ] of [ [ 'slow', { allow: false, delay: 5 } ], [ 'error 500', { allow: false, status: 500 } ] ]) {
    const room = roomName('g-');
    await meeting(room, { [room]: answer });
    const c = await connect(room, 'owner', 'open-' + label.replace(' ', ''));
    const t0 = Date.now();
    const r = await join(c, room, 'someone');
    check(`Cowork ${label}: let in (fail open)`, r === 'joined', `${r} after ${Date.now() - t0} ms`);
    await c.x.stop();
}

// 7. End meeting for all (a moderator's end_conference) -> host_ended.
{
    const room = roomName();
    await meeting(room, { [room]: { allow: true, instant: true } });
    const host = await connect(room, 'owner', 'host7');
    const member = await connect(room, 'member', 'member7');
    await join(host, room, 'host');
    await join(member, room, 'member');
    await host.x.send(xml('message', { to: 'endconference.meet.jitsi' }, xml('end_conference')));
    await sleep(3000);
    check('End meeting for all ends the room for the member', destroyed(member, room));
    const end = events().find(e => e.event === 'room_destroyed' && e.room === room);
    check('room-closed event says host_ended', end?.reason === 'host_ended', JSON.stringify(end));
    await host.x.stop().catch(() => {}); await member.x.stop().catch(() => {});
}

// 8. Guests off: the gate tells Cowork the joiner is a guest; a guest is
//    refused while a member gets in. With guests on, a guest goes on to the
//    lobby (the gate let them through).
for (const guestsOff of [ true, false ]) {
    const room = roomName('g-');
    await meeting(room, { [room]: { allow: true, instant: true, guests_off: guestsOff } });
    const host = await connect(room, 'owner', 'host8' + guestsOff);
    await join(host, room, 'host');
    const guest = await connectGuest(room);
    const r = await join(guest, room, 'guest');
    const asked = events().filter(e => e.event === 'room_check' && e.room === room && e.guest === true);
    check(`guest check says guest (guests ${guestsOff ? 'off' : 'on'})`, asked.length >= 1, `${asked.length}`);
    if (guestsOff) {
        check('guests off: the guest is refused', r === 'not-authorized', r);
    } else {
        check('guests on: the gate lets the guest on to the lobby', r !== 'not-authorized', r);
    }
    await guest.x.stop().catch(() => {}); await host.x.stop().catch(() => {});
}

// 9. Cowork doesn't take a room event (restarting): retried 5 s later with
//    the same nonce.
{
    const room = roomName();
    setRooms({ [room]: { allow: true, fail_events: 1 } });
    await startConference(room);
    await sleep(7500);
    const created = events().filter(e => e.event === 'room_created' && e.room === room);
    check('room event retried after Cowork failed it', created.length === 2 && created[0].status === 500 && created[1].status === 204,
        created.map(e => e.status).join(','));
    check('the retry carries the same nonce', created.length === 2 && created[0].nonce && created[0].nonce === created[1].nonce);
}

const failed = results.filter(r => !r.ok).length;
console.log(`\n${results.length - failed}/${results.length} passed`);
process.exit(failed ? 1 : 0);
