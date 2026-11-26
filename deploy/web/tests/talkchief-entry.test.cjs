// Regression tests for branding/static/talkchief-entry.js, the first script in
// the meeting app's <head>. Run: node --test deploy/web/tests/
'use strict';

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const SCRIPT = fs.readFileSync(path.join(__dirname, '..', 'branding', 'static', 'talkchief-entry.js'), 'utf8');

// Runs the entry script for an address and returns where it sent the browser
// (null when the meeting app is left to start).
function entryFor(address) {
    const url = new URL(address);
    let replaced = null;
    const location = {
        pathname: url.pathname,
        search: url.search,
        hash: url.hash,
        replace: (to) => { replaced = to; },
    };
    vm.runInNewContext(SCRIPT, { location, URLSearchParams, encodeURIComponent });
    return replaced;
}

const CHOOSER = '/static/talkchief-access.html?tenant=acme&room=';

test('a room link without a token opens the app/browser chooser', () => {
    assert.strictEqual(entryFor('https://meet.example/acme/Abc123def456'), CHOOSER + 'abc123def456');
});

test('a guest-room link without the invitation page\'s name still opens the chooser', () => {
    // Copied or shared g- room address: guests must come through their
    // invitation link (expiry and rotation), members through Cowork.
    assert.strictEqual(entryFor('https://meet.example/acme/g-abc123'), CHOOSER + 'g-abc123');
    assert.strictEqual(entryFor('https://meet.example/acme/g-abc123#config.localSubject=%22Demo%22'), CHOOSER + 'g-abc123');
});

test('a member join with a token starts the meeting', () => {
    assert.strictEqual(entryFor('https://meet.example/acme/abc123?jwt=eyJ.x.y'), null);
});

test('a guest sent by the invitation page starts the meeting as a guest', () => {
    // talkchiefMeetingsGuestPage (Cowork) answers the name form with a 303 to
    // the g- room and the typed name in the fragment, never with a token.
    // Sending that guest to the chooser ends on the Cowork sign-in page.
    const fromInvitation = 'https://meet.example/acme/g-abc123def456' +
        '#userInfo.displayName=%22Grace%20Hopper%22&config.localSubject=%22Customer%20demo%22';
    assert.strictEqual(entryFor(fromInvitation), null);
});

test('the guest exception needs a guest room', () => {
    // The name fragment alone does not skip the chooser on an internal room.
    assert.strictEqual(entryFor('https://meet.example/acme/abc123#userInfo.displayName=%22X%22'), CHOOSER + 'abc123');
});

test('other paths are left alone', () => {
    assert.strictEqual(entryFor('https://meet.example/'), null);
    assert.strictEqual(entryFor('https://meet.example/static/talkchief-access.html?tenant=acme&room=x'), null);
});
