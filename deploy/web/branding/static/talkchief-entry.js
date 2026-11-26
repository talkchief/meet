// A room link opened without a member token (shared, copied, from WhatsApp)
// goes straight to the "Open in TalkChief Cowork / Continue in browser" page,
// before the meeting app starts. Without this, Jitsi first shows its pre-join
// screen and only sends people there after they press Join.
//
// Guests are the exception. Cowork's invitation page (/j/<code>) answers the
// name form with the guest room (g-) and the typed name in the fragment
// (userInfo.displayName), never with a token. They join anonymously, and the
// chooser would send them to the Cowork sign-in page, which they can't use.
// A bare or copied g- room address still gets the chooser. This only steers
// the browser: Prosody's room policy decides who may enter (guests only in g-
// rooms, waiting for a host, knocking in the lobby).
(function () {
    try {
        var m = location.pathname.match(/^\/([a-z0-9-]+)\/([A-Za-z0-9-]+)\/?$/);
        if (!m || new URLSearchParams(location.search).get('jwt')) {
            return;
        }
        var fragment = new URLSearchParams((location.hash || '').replace(/^#/, ''));
        if (/^g-/i.test(m[2]) && fragment.get('userInfo.displayName')) {
            return;
        }
        location.replace('/static/talkchief-access.html?tenant=' + encodeURIComponent(m[1]) +
            '&room=' + encodeURIComponent(m[2].toLowerCase()));
    } catch (e) {}
})();
