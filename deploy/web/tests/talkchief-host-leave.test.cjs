// node --test deploy/web/tests/
// The Meet now host-leave prompt (static/talkchief-host-leave.js): when it
// asks, whom it offers as the new host, and that Leave always works.
const test = require('node:test');
const assert = require('node:assert');
const path = require('node:path');

const leave = require(path.join(__dirname, '..', 'branding', 'static', 'talkchief-host-leave.js'));

function person(id, opts = {}) {
    return {
        getId: () => id,
        getDisplayName: () => opts.name || id,
        getRole: () => opts.role || 'participant',
        isHidden: () => Boolean(opts.hidden),
        getJid: () => opts.jid || `${id}@meet.jitsi/abc`
    };
}

const USER_LEAVE = [ true ]; // leaveConference(): hangup(true)

test('Meet now host links carry talkchief.instant (as Cowork JSON-encodes it)', () => {
    assert.strictEqual(leave.isInstant('#config.localSubject=%22Meeting%22&talkchief.instant=%22true%22'), true);
    assert.strictEqual(leave.isInstant('#talkchief.instant=true'), true);
    assert.strictEqual(leave.isInstant('#config.localSubject=%22Planning%22'), false);
    assert.strictEqual(leave.isInstant(''), false);
});

test('the host leaving a Meet now meeting with others and no other moderator is asked', () => {
    const choice = leave.leaveChoice(USER_LEAVE, true, 'moderator', [ person('a', { name: 'Ada' }), person('b', { name: 'Bob' }) ]);
    assert.deepStrictEqual(choice, { candidates: [ { id: 'a', name: 'Ada' }, { id: 'b', name: 'Bob' } ] });
});

test('guests and hidden participants are never offered as host; guests alone still ask', () => {
    const others = [ person('g', { jid: 'abc@guest.meet.jitsi/x' }), person('rec', { hidden: true }), person('m') ];
    assert.deepStrictEqual(leave.leaveChoice(USER_LEAVE, true, 'moderator', others).candidates.map(c => c.id), [ 'm' ]);
    assert.deepStrictEqual(leave.leaveChoice(USER_LEAVE, true, 'moderator', [ person('g', { jid: 'abc@guest.meet.jitsi/x' }) ]),
        { candidates: [] });
});

test('leaving at once: not Meet now, not the host, alone, a co-host stays, or Jitsi itself leaving', () => {
    const others = [ person('a') ];
    assert.strictEqual(leave.leaveChoice(USER_LEAVE, false, 'moderator', others), null, 'scheduled meeting');
    assert.strictEqual(leave.leaveChoice(USER_LEAVE, true, 'participant', others), null, 'not the host');
    assert.strictEqual(leave.leaveChoice(USER_LEAVE, true, 'moderator', []), null, 'alone');
    assert.strictEqual(leave.leaveChoice(USER_LEAVE, true, 'moderator', [ person('rec', { hidden: true }) ]), null, 'only hidden');
    assert.strictEqual(leave.leaveChoice(USER_LEAVE, true, 'moderator', [ person('a'), person('c', { role: 'moderator' }) ]),
        null, 'a co-host stays');
    assert.strictEqual(leave.leaveChoice([ true, 'The meeting was ended', true ], true, 'moderator', others), null, 'meeting ended');
    assert.strictEqual(leave.leaveChoice([], true, 'moderator', others), null, 'hangup() from Jitsi');
});

function fakeWindow(participants, localRole) {
    const calls = [];
    const conference = {
        hangup(...args) {
            calls.push(args);
            return 'left';
        }
    };
    const win = {
        APP: {
            conference,
            store: {
                getState: () => ({
                    'features/base/conference': { conference: { getParticipants: () => participants } },
                    'features/base/participants': { local: { role: localRole } }
                })
            }
        }
    };
    return { win, calls };
}

test('install wraps hangup once; leaving that needs no question goes straight through', () => {
    const { win, calls } = fakeWindow([ person('a') ], 'participant');
    assert.strictEqual(leave.install(win, true), true);
    const wrapped = win.APP.conference.hangup;
    assert.strictEqual(leave.install(win, true), true, 'already installed');
    assert.strictEqual(win.APP.conference.hangup, wrapped, 'not wrapped twice');
    assert.strictEqual(win.APP.conference.hangup(true), 'left');
    assert.deepStrictEqual(calls, [ [ true ] ]);
});

test('Leave always works: when the question cannot be shown, it leaves', () => {
    const { win, calls } = fakeWindow([ person('a') ], 'moderator');
    leave.install(win, true);
    // No document in Node: showing the question throws, so it leaves.
    assert.strictEqual(win.APP.conference.hangup(true), 'left');
    assert.deepStrictEqual(calls, [ [ true ] ]);
});

test('Leave always works: a Jitsi without the expected state leaves', () => {
    const calls = [];
    const win = { APP: { conference: { hangup: (...a) => { calls.push(a); return 'left'; } }, store: { getState: () => ({}) } } };
    leave.install(win, true);
    assert.strictEqual(win.APP.conference.hangup(true), 'left');
    assert.strictEqual(calls.length, 1);
});

test('nothing to wrap yet: install reports false and changes nothing', () => {
    assert.strictEqual(leave.install({}, true), false);
    assert.strictEqual(leave.install({ APP: { conference: {} } }, true), false);
});
