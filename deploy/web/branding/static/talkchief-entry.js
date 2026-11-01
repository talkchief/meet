// A room link opened without a member token (shared, copied, from WhatsApp)
// goes straight to the "Open in TalkChief Cowork / Continue in browser" page,
// before the meeting app starts. Without this, Jitsi first shows its pre-join
// screen and only sends people there after they press Join.
(function () {
    try {
        var m = location.pathname.match(/^\/([a-z0-9-]+)\/([A-Za-z0-9-]+)\/?$/);
        if (!m || new URLSearchParams(location.search).get('jwt')) {
            return;
        }
        location.replace('/static/talkchief-access.html?tenant=' + encodeURIComponent(m[1]) +
            '&room=' + encodeURIComponent(m[2].toLowerCase()));
    } catch (e) {}
})();
