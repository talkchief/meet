// TalkChief Cowork Meetings: small room behaviours added to the meeting page.
(function () {
    // When the host ends the meeting for everyone (the room is destroyed), go
    // straight to the "Meeting ended" page. The stock client first tries to
    // leave the room that no longer exists and waits for its timeouts, which
    // left people on a dead screen for several seconds.
    var ended = false;
    function showEnded() {
        if (!ended) {
            ended = true;
            window.location.replace('/static/close2.html');
        }
    }
    setInterval(function () {
        var room = window.APP && window.APP.conference && window.APP.conference._room;
        if (!room || typeof room.on !== 'function' || room.__talkchiefWatched) {
            return;
        }
        room.__talkchiefWatched = true;
        room.on('conference.failed', function (error) {
            if (error === 'conference.destroyed') {
                showEnded();
            }
        });
    }, 1000);

    // The control bar always shows (stock Jitsi hides it over the video), so
    // Jitsi must lay the videos out in the space above it. Every Jitsi resize
    // uses the full window height; correct it right after, and share the bar
    // height with the stylesheet (--tc-toolbar-h).
    function toolbarHeight() {
        var bar = document.querySelector('#new-toolbox .toolbox-content-items');
        return bar && bar.offsetHeight ? bar.offsetHeight : 0;
    }
    var fitting = false;
    function fitAboveToolbar() {
        var store = window.APP && window.APP.store;
        if (!store || fitting) {
            return;
        }
        var bar = toolbarHeight();
        if (!bar) {
            return;
        }
        document.documentElement.style.setProperty('--tc-toolbar-h', bar + 'px');
        var ui = store.getState()['features/base/responsive-ui'] || {};
        var wanted = window.innerHeight - bar;
        if (ui.clientHeight === window.innerHeight && wanted > 0) {
            fitting = true;
            try {
                store.dispatch({
                    type: 'CLIENT_RESIZED',
                    clientWidth: ui.clientWidth,
                    clientHeight: wanted,
                    videoSpaceWidth: ui.videoSpaceWidth
                });
            } finally {
                fitting = false;
            }
        }
    }
    var fitWatched = false;
    setInterval(function () {
        var store = window.APP && window.APP.store;
        if (!store) {
            return;
        }
        if (!fitWatched) {
            fitWatched = true;
            store.subscribe(fitAboveToolbar);
        }
        fitAboveToolbar();
    }, 1000);

    // Screen sharing and sound: browsers only include sound when it is asked
    // for in their share picker, so say whether this share carries sound and,
    // if not, how to include it.
    var sharing = false;
    function notify(type, title, description, timeout) {
        window.APP.store.dispatch({
            type: 'SHOW_NOTIFICATION',
            props: { appearance: type, title: title, description: description },
            timeout: timeout,
            uid: 'talkchief-share-audio-' + Date.now()
        });
    }
    setInterval(function () {
        var store = window.APP && window.APP.store;
        if (!store) {
            return;
        }
        var state = store.getState();
        var tracks = state['features/base/tracks'] || [];
        var now = tracks.some(function (t) {
            return t.local && t.mediaType === 'video' && t.videoType === 'desktop';
        });
        if (now && !sharing) {
            setTimeout(function () {
                var shareState = store.getState()['features/screen-share'] || {};
                if (shareState.desktopAudioTrack) {
                    notify('success', 'Sharing with sound',
                        'Everyone hears the sound from what you share.', 5000);
                } else {
                    notify('normal', 'Sharing without sound',
                        'To include sound, stop sharing and share again: pick a browser tab and turn on '
                        + '"Also share tab audio", or pick your entire screen and turn on "Share system audio" '
                        + '(Windows and ChromeOS). A single app window cannot share sound.', 12000);
                }
            }, 1500);
        }
        sharing = now;
    }, 1000);
})();
