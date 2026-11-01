// TalkChief Cowork Meetings: small room behaviours added to the meeting page.
(function () {
    // When the host ends the meeting for everyone (the room is destroyed), go
    // straight to the "Meeting ended" page. The stock client first tries to
    // leave the room that no longer exists and waits for its timeouts, which
    // left people on a dead screen for several seconds.
    var ended = false;
    // Refusals that are part of the normal flow (a guest waiting in the
    // lobby, a wrong token), not problems worth reporting to Sentry.
    var EXPECTED_FAILURES = [ 'conference.connectionError.membersOnly', 'conference.connectionError.accessDenied', 'conference.authenticationRequired', 'conference.connectionError.notAllowed', 'conference.connectionError.passwordRequired' ];
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
            } else if (window.tcReport && EXPECTED_FAILURES.indexOf(error) < 0) {
                window.tcReport('conference-failed', error);
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
        if (wanted > 0 && ui.clientHeight !== wanted) {
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

    // Background settings without camera access: stock Jitsi closes the
    // whole Settings window when the camera preview cannot start. Keep the
    // window open and say so in the Background tab, with a way to grant it.
    var PREVIEW = '[class*="-virtualBackgroundPreview"]';
    function cameraHelp(error) {
        var name = error && error.name;
        if (name === 'NotFoundError' || name === 'OverconstrainedError') {
            return 'No camera was found. Connect a camera, then try again.';
        }
        if (name === 'NotReadableError') {
            return 'Your camera is being used by another app. Close that app, then try again.';
        }
        if (name === 'NotAllowedError' || name === 'SecurityError') {
            return 'Camera access is blocked. In the browser, click the camera icon in the address bar and '
                + 'allow it; in the Cowork app, turn on Settings > Privacy & security > Camera for desktop '
                + 'apps. Then try again.';
        }
        return 'Allow camera access to preview and choose a background.';
    }
    function showCameraBlocked(dispatch, store, error) {
        var preview = document.querySelector(PREVIEW);
        if (!preview) {
            return;
        }
        var panel = preview.querySelector('.tc-camera-blocked');
        if (!panel) {
            panel = document.createElement('div');
            panel.className = 'tc-camera-blocked';
            panel.setAttribute('role', 'alert');
            var title = document.createElement('strong');
            title.textContent = 'No camera access';
            var text = document.createElement('p');
            var button = document.createElement('button');
            button.type = 'button';
            button.textContent = 'Grant camera access';
            button.onclick = function () {
                button.disabled = true;
                navigator.mediaDevices.getUserMedia({ video: true }).then(function (stream) {
                    stream.getTracks().forEach(function (t) { t.stop(); });
                    // Open the same Settings window again so the preview restarts.
                    var dialog = store.getState()['features/base/dialog'] || {};
                    dispatch({ type: 'HIDE_DIALOG' });
                    if (dialog.component) {
                        dispatch({ type: 'OPEN_DIALOG', component: dialog.component,
                            componentProps: dialog.componentProps });
                    }
                }, function (err) {
                    button.disabled = false;
                    button.textContent = 'Try again';
                    text.textContent = cameraHelp(err);
                });
            };
            panel.appendChild(title);
            panel.appendChild(text);
            panel.appendChild(button);
            preview.appendChild(panel);
        }
        panel.querySelector('p').textContent = cameraHelp(error);
    }
    function guardBackgroundSettings(store) {
        var dispatch = store.dispatch;
        store.dispatch = function (action) {
            if (action && action.type === 'HIDE_DIALOG' && !action.tcAllow && document.querySelector(PREVIEW)) {
                // Wait one tick: on a camera failure Jitsi posts its warning
                // right after asking to close.
                setTimeout(function () {
                    var state = store.getState()['features/notifications'] || {};
                    var warning = (state.notifications || []).filter(function (n) {
                        return n.props && n.props.titleKey === 'virtualBackground.backgroundEffectError';
                    })[0];
                    if (!warning) {
                        dispatch(action);
                        return;
                    }
                    dispatch({ type: 'HIDE_NOTIFICATION', uid: warning.uid });
                    if (navigator.permissions && navigator.permissions.query) {
                        navigator.permissions.query({ name: 'camera' }).then(function (status) {
                            showCameraBlocked(dispatch, store,
                                status.state === 'denied' ? { name: 'NotAllowedError' } : null);
                        }, function () { showCameraBlocked(dispatch, store, null); });
                    } else {
                        showCameraBlocked(dispatch, store, null);
                    }
                }, 0);
                return action;
            }
            return dispatch(action);
        };
    }
    var dialogsGuarded = false;
    setInterval(function () {
        if (!dialogsGuarded && window.APP && window.APP.store) {
            dialogsGuarded = true;
            guardBackgroundSettings(window.APP.store);
        }
    }, 500);

    // A chime when someone else starts sharing their screen, like Zoom. Not
    // for your own share, nor for shares already running when you join.
    var seenShares = null;
    function chime() {
        try {
            var Ctx = window.AudioContext || window.webkitAudioContext;
            if (!Ctx) {
                return;
            }
            var ctx = chime.ctx || (chime.ctx = new Ctx());
            if (ctx.state === 'suspended') {
                ctx.resume();
            }
            [ 659.25, 880 ].forEach(function (freq, i) {
                var start = ctx.currentTime + i * 0.16;
                var osc = ctx.createOscillator();
                var gain = ctx.createGain();
                osc.type = 'sine';
                osc.frequency.value = freq;
                gain.gain.setValueAtTime(0.0001, start);
                gain.gain.exponentialRampToValueAtTime(0.18, start + 0.02);
                gain.gain.exponentialRampToValueAtTime(0.0001, start + 0.32);
                osc.connect(gain);
                gain.connect(ctx.destination);
                osc.start(start);
                osc.stop(start + 0.35);
            });
        } catch (e) {
            // sound is a nicety
        }
    }
    function watchShares() {
        var store = window.APP && window.APP.store;
        if (!store) {
            return;
        }
        // A share is its own track kind ('screenshare') with multi-stream on,
        // and Jitsi lists remote shares in the video layout state.
        var state = store.getState();
        var layout = state['features/video-layout'] || {};
        var now = {};
        if (Array.isArray(layout.remoteScreenShares)) {
            layout.remoteScreenShares.forEach(function (id) {
                now[id] = true;
            });
        } else {
            (state['features/base/tracks'] || []).forEach(function (t) {
                if (!t.local && t.videoType === 'desktop' && t.participantId) {
                    now[t.participantId] = true;
                }
            });
        }
        if (seenShares) {
            var started = Object.keys(now).some(function (id) { return !seenShares[id]; });
            if (started) {
                chime();
            }
        }
        seenShares = now;
    }
    var sharesWatched = false;
    setInterval(function () {
        var store = window.APP && window.APP.store;
        if (!store || sharesWatched) {
            return;
        }
        if (window.APP.conference && window.APP.conference.isJoined && window.APP.conference.isJoined()) {
            sharesWatched = true;
            watchShares();
            store.subscribe(watchShares);
        }
    }, 1000);

    // A room without a title (nobody set one: guests who arrived before the
    // host, or a plain room link) would show its random id as words
    // ("G Dw 8 Ho 4 ..."). Show a plain name instead until the host's
    // title arrives.
    var titled = false;
    setInterval(function () {
        var store = window.APP && window.APP.store;
        if (titled || !store || !(window.APP.conference && window.APP.conference.isJoined && window.APP.conference.isJoined())) {
            return;
        }
        var c = store.getState()['features/base/conference'] || {};
        if (c.localSubject || c.subject || c.pendingSubjectChange) {
            titled = true;
            return;
        }
        titled = true;
        store.dispatch({ type: 'CONFERENCE_LOCAL_SUBJECT_CHANGED', localSubject: 'TalkChief Cowork meeting' });
        // The host's title replaces it when it arrives (subject wins over
        // this placeholder only once the placeholder is cleared).
        var unsubscribe = store.subscribe(function () {
            var now = store.getState()['features/base/conference'] || {};
            if (now.subject && now.localSubject === 'TalkChief Cowork meeting') {
                unsubscribe();
                store.dispatch({ type: 'CONFERENCE_LOCAL_SUBJECT_CHANGED', localSubject: '' });
            }
        });
    }, 2000);

    // Microphone or camera blocked: pressing the button again asks the browser
    // again (it shows its prompt again when the earlier answer was a dismissal,
    // or a one-time block). When the browser still refuses without asking,
    // say where to allow it, with a Try again that turns it on once allowed.
    // Buttons are found by their place (.audio-preview / .video-preview), not
    // their labels, which are translated.
    var MEDIA = {
        audio: { permission: 'microphone', name: 'microphone', container: '.audio-preview',
            notice: 'deviceError.microphonePermission' },
        video: { permission: 'camera', name: 'camera', container: '.video-preview',
            notice: 'deviceError.cameraPermission' }
    };
    function mediaButton(kind) {
        return document.querySelector(MEDIA[kind].container + ' .toolbox-button');
    }
    // Off as the button shows it (pressed = muted). The meeting's own state
    // already reads "on" after an attempt the browser refused.
    function mediaMuted(kind) {
        var button = mediaButton(kind);
        var pressed = button && button.getAttribute('aria-pressed');
        if (pressed === 'true' || pressed === 'false') {
            return pressed === 'true';
        }
        var store = window.APP && window.APP.store;
        var media = store && store.getState()['features/base/media'];
        return Boolean(media && media[kind] && media[kind].muted);
    }
    function mediaKindOf(target) {
        var button = target && target.closest && target.closest('.toolbox-button');
        if (!button) {
            return null;
        }
        for (var kind in MEDIA) {
            if (button.closest(MEDIA[kind].container) && mediaMuted(kind)) {
                return { kind: kind, button: button };
            }
        }
        return null;
    }
    function capitalized(text) {
        return text[0].toUpperCase() + text.slice(1);
    }
    function where(kind) {
        var ua = navigator.userAgent;
        var name = MEDIA[kind].name;
        var ios = /iPhone|iPad|iPod/.test(ua) || (/Macintosh/.test(ua) && navigator.maxTouchPoints > 1);
        if (ios) {
            return 'Tap aA (or the page icon) in the address bar > Website Settings > ' + capitalized(name)
                + ' > Allow. Or reload this page to be asked again.';
        }
        if (/Android/.test(ua)) {
            return 'Tap the icon left of the address > Permissions > ' + capitalized(name) + ' > Allow.';
        }
        var text = /Firefox\//.test(ua)
            ? 'Click the crossed-out ' + name + ' icon in the address bar and remove the block.'
            : /Safari\//.test(ua) && !/Chrome\//.test(ua)
                ? 'In Safari, choose Safari > Settings for this website > ' + capitalized(name)
                    + ' > Allow, or reload this page to be asked again.'
                : 'Click the ' + name + ' icon (or the site settings icon) at the right of the address bar and choose Allow.';
        return text + ' In the TalkChief Cowork app, allow it for desktop apps in your computer’s privacy settings ('
            + (/Mac/.test(navigator.platform) ? 'System Settings > Privacy & Security > ' : 'Settings > Privacy & security > ')
            + capitalized(name) + ').';
    }
    var retrying = false;
    function turnOn(kind) {
        var button = mediaButton(kind);
        if (!button || !mediaMuted(kind)) {
            return;
        }
        retrying = true;
        try {
            button.click();
        } finally {
            retrying = false;
        }
    }
    var helpOpener = null;
    function closeMediaHelp() {
        var old = document.getElementById('tc-media-blocked');
        if (!old) {
            return;
        }
        var refocus = old.contains(document.activeElement);
        old.remove();
        document.removeEventListener('keydown', escapeCloses, true);
        if (refocus && helpOpener && document.body.contains(helpOpener)) {
            helpOpener.focus();
        }
        helpOpener = null;
    }
    function escapeCloses(event) {
        if (event.key === 'Escape') {
            event.stopPropagation();
            closeMediaHelp();
        }
    }
    function showMediaHelp(kind, error) {
        var opener = helpOpener || (document.activeElement !== document.body ? document.activeElement : null);
        closeMediaHelp();
        helpOpener = opener || mediaButton(kind);
        var name = MEDIA[kind].name;
        var box = document.createElement('div');
        box.id = 'tc-media-blocked';
        box.className = 'tc-media-blocked';
        box.setAttribute('role', 'alertdialog');
        box.setAttribute('aria-labelledby', 'tc-media-blocked-title');
        box.setAttribute('aria-describedby', 'tc-media-blocked-text');
        var title = document.createElement('strong');
        title.id = 'tc-media-blocked-title';
        var text = document.createElement('p');
        text.id = 'tc-media-blocked-text';
        var other = error && error.name && error.name !== 'NotAllowedError' && error.name !== 'SecurityError';
        title.textContent = other ? 'Your ' + name + ' isn’t available' : capitalized(name) + ' access is blocked';
        text.textContent = other
            ? (error.name === 'NotFoundError' || error.name === 'OverconstrainedError'
                ? 'No ' + name + ' was found. Connect one, then try again.'
                : 'Your ' + name + ' may be in use by another app. Close that app, then try again.')
            : where(kind);
        var actions = document.createElement('div');
        var again = document.createElement('button');
        again.type = 'button';
        again.textContent = 'Try again';
        var close = document.createElement('button');
        close.type = 'button';
        close.className = 'secondary';
        close.textContent = 'Close';
        close.onclick = closeMediaHelp;
        again.onclick = function () {
            again.disabled = true;
            askAgain(kind, function (err) {
                again.disabled = false;
                showMediaHelp(kind, err);
            });
        };
        actions.appendChild(again);
        actions.appendChild(close);
        box.appendChild(title);
        box.appendChild(text);
        box.appendChild(actions);
        document.body.appendChild(box);
        document.addEventListener('keydown', escapeCloses, true);
        again.focus();
    }
    // Asks the browser for the device; once it is allowed, the button is
    // pressed again so the meeting turns it on.
    function askAgain(kind, onRefused) {
        var constraints = {};
        constraints[kind] = true;
        navigator.mediaDevices.getUserMedia(constraints).then(function (stream) {
            stream.getTracks().forEach(function (t) { t.stop(); });
            closeMediaHelp();
            turnOn(kind);
        }, onRefused);
    }
    function permissionState(kind) {
        if (!navigator.permissions || !navigator.permissions.query) {
            return Promise.resolve('unknown');
        }
        return navigator.permissions.query({ name: MEDIA[kind].permission }).then(function (s) {
            return s.state;
        }, function () { return 'unknown'; });
    }
    var pressedAt = { audio: 0, video: 0 };
    document.addEventListener('click', function (event) {
        if (retrying || !navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
            return;
        }
        var hit = mediaKindOf(event.target);
        if (!hit) {
            return;
        }
        pressedAt[hit.kind] = Date.now();
        permissionState(hit.kind).then(function (state) {
            if (state === 'unknown') {
                // No answer from the browser (Firefox): if the button is still
                // off a moment later, the meeting couldn't turn it on; ask.
                setTimeout(function () {
                    if (mediaMuted(hit.kind) && !document.getElementById('tc-media-blocked')) {
                        askAgain(hit.kind, function (err) {
                            showMediaHelp(hit.kind, err);
                        });
                    }
                }, 1500);
                return;
            }
            if (state !== 'denied') {
                return; // the meeting asks the browser itself
            }
            // The meeting's own attempt fails at once; ask again (shows the
            // prompt where the browser allows it), else explain.
            askAgain(hit.kind, function (err) {
                showMediaHelp(hit.kind, err);
            });
        });
    }, true);
    // Browsers that can't tell the permission (Firefox): the meeting reports
    // the refusal as a warning; right after the person pressed the button,
    // show the explanation instead of that warning.
    var noticesSeen = {};
    var noticesWatched = false;
    function watchMediaNotices() {
        var store = window.APP.store;
        var list = (store.getState()['features/notifications'] || {}).notifications || [];
        list.forEach(function (n) {
            if (noticesSeen[n.uid]) {
                return;
            }
            noticesSeen[n.uid] = true;
            for (var kind in MEDIA) {
                if (n.props && n.props.titleKey === MEDIA[kind].notice && Date.now() - pressedAt[kind] < 8000) {
                    store.dispatch({ type: 'HIDE_NOTIFICATION', uid: n.uid });
                    if (!document.getElementById('tc-media-blocked')) {
                        showMediaHelp(kind, { name: 'NotAllowedError' });
                    }
                }
            }
        });
    }
    setInterval(function () {
        if (!noticesWatched && window.APP && window.APP.store) {
            noticesWatched = true;
            window.APP.store.subscribe(watchMediaNotices);
        }
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
            return t.local && t.videoType === 'desktop';
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

    // Guests who arrived before the host wait in the "waiting for host"
    // lobby. When the host arrives, that lobby closes and the meeting's own
    // lobby opens (mod_talkchief_room_policy), so the guest is refused once
    // more as members-only, now without "waiting for host". Jitsi still
    // thinks the guest is knocking and never knocks again: they stayed on
    // "waiting for a moderator" while the host saw nobody. Knock on the
    // meeting's lobby then, so the host can admit them.
    var waitedForHost = false;
    var watchingLobby = false;
    function knockAfterHostArrived() {
        var store = window.APP.store;
        var state = store.getState();
        var conference = state['features/base/conference'] || {};
        var lobby = state['features/lobby'] || {};
        if (conference.lobbyWaitingForHost) {
            waitedForHost = true;
            return;
        }
        if (!waitedForHost || !conference.membersOnly || !lobby.knocking) {
            return;
        }
        waitedForHost = false;
        var me = (state['features/base/participants'] || {}).local || {};
        try {
            conference.membersOnly.joinLobby(me.name, me.email);
        } catch (e) {
            // the meeting's own retry still applies
        }
    }
    setInterval(function () {
        if (!watchingLobby && window.APP && window.APP.store) {
            watchingLobby = true;
            window.APP.store.subscribe(knockAfterHostArrived);
        }
    }, 500);

    // ── Call diagnostics and the audio safety net ────────────────────────
    // A small record of this person's own connection, so a report like
    // "my audio dropped" can be checked: every 10 s the audio sent and
    // received, loss, delay and connection type, plus events (connection
    // lost and back, microphone stopped, paused audio restarted). No names
    // and no addresses. Sent to the meeting server every minute and on leave
    // (/talkchief-diag), which keeps it for 14 days.
    var DIAG_URL = '/talkchief-diag';
    var diag = { joinedAt: 0, samples: [], events: [], sentSamples: 0, sentEvents: 0, last: null };
    function diagEvent(type, detail) {
        if (!diag.joinedAt) {
            return;
        }
        diag.events.push(detail === undefined ? [ Date.now(), type ] : [ Date.now(), type, String(detail).slice(0, 80) ]);
        var drop = diag.events.length - 400;
        if (drop > 0) {
            diag.events.splice(0, drop);
            diag.sentEvents = Math.max(0, diag.sentEvents - drop);
        }
        if (window.tcReport) {
            window.tcReport(type, detail); // call problems to Sentry (talkchief-sentry.js)
        }
    }
    // The last minute of the record, attached to Sentry reports.
    window.tcDiagSnapshot = function () {
        var c = window.APP && window.APP.conference;
        return {
            ep: (c && c.getMyUserId && c.getMyUserId()) || '',
            joinedAt: diag.joinedAt,
            samples: diag.samples.slice(-6),
            events: diag.events.slice(-20)
        };
    };
    function joinedRoom() {
        var c = window.APP && window.APP.conference;
        return c && c.isJoined && c.isJoined() ? c._room : null;
    }
    function activePC(room) {
        var tpc = room && room.getActivePeerConnection && room.getActivePeerConnection();
        return tpc && tpc.peerconnection;
    }

    // Audio safety net: some browsers (Safari, Firefox) pause incoming audio
    // after a network interruption and never start it again, which sounds
    // like "the audio dropped until I rejoined". Start it again.
    var blockedAudio = {};
    setInterval(function () {
        var room = joinedRoom();
        if (!room) {
            return;
        }
        watchConnection(room); // start the record as soon as the person is in
        Array.prototype.forEach.call(document.querySelectorAll('audio'), function (el) {
            var stream = el.srcObject;
            var live = stream && stream.getAudioTracks && stream.getAudioTracks().some(function (t) {
                return t.readyState === 'live';
            });
            if (!live || !el.paused || el.ended) {
                if (!el.paused) {
                    delete blockedAudio[el.id];
                }
                return;
            }
            var playing = el.play();
            if (!blockedAudio[el.id]) {
                diagEvent('audio-restarted', el.id);
            }
            if (playing && playing.catch) {
                playing.catch(function (err) {
                    if (!blockedAudio[el.id]) {
                        blockedAudio[el.id] = true;
                        diagEvent('audio-restart-refused', err && err.name);
                    }
                });
            }
        });
    }, 3000);

    function watchConnection(room) {
        if (room.__talkchiefDiag) {
            return;
        }
        room.__talkchiefDiag = true;
        diag.joinedAt = Date.now();
        diagEvent('joined');
        room.on('conference.connectionInterrupted', function () { diagEvent('media-interrupted'); });
        room.on('conference.connectionRestored', function () { diagEvent('media-restored'); });
        var conn = window.APP.connection;
        if (conn && conn.addEventListener) {
            conn.addEventListener('connection.connectionFailed', function (e) { diagEvent('signalling-failed', e); });
        }
    }
    var watchedPC = null;
    var watchedMic = null;
    function watchPeer(pc) {
        if (!pc || pc === watchedPC) {
            return;
        }
        watchedPC = pc;
        diagEvent('peer', pc.iceConnectionState);
        pc.addEventListener('iceconnectionstatechange', function () { diagEvent('ice', pc.iceConnectionState); });
        pc.addEventListener('connectionstatechange', function () { diagEvent('conn', pc.connectionState); });
    }
    function localMic() {
        var tracks = (window.APP.store.getState()['features/base/tracks'] || []).filter(function (t) {
            return t.local && t.mediaType === 'audio';
        });
        return tracks[0] || null;
    }
    function watchMic(track) {
        var mst = track && track.jitsiTrack && track.jitsiTrack.getTrack && track.jitsiTrack.getTrack();
        if (!mst || mst === watchedMic) {
            return;
        }
        watchedMic = mst;
        diagEvent('mic'); // no device label: it can carry a person's name
        mst.addEventListener('ended', function () { diagEvent('mic-ended'); });
        mst.addEventListener('mute', function () { diagEvent('mic-silenced'); }); // the system took the microphone
        mst.addEventListener('unmute', function () { diagEvent('mic-back'); });
    }
    function sum(stats, type, kind, field) {
        var total = 0;
        stats.forEach(function (s) {
            if (s.type === type && (s.kind || s.mediaType) === kind && typeof s[field] === 'number') {
                total += s[field];
            }
        });
        return total;
    }
    function sample() {
        var room = joinedRoom();
        if (!room) {
            return;
        }
        watchConnection(room);
        var pc = activePC(room);
        watchPeer(pc);
        var mic = localMic();
        watchMic(mic);
        if (!pc) {
            return;
        }
        pc.getStats().then(function (stats) {
            var now = {
                sent: sum(stats, 'outbound-rtp', 'audio', 'packetsSent'),
                recv: sum(stats, 'inbound-rtp', 'audio', 'packetsReceived'),
                lost: sum(stats, 'inbound-rtp', 'audio', 'packetsLost'),
                conc: sum(stats, 'inbound-rtp', 'audio', 'concealedSamples'),
                samp: sum(stats, 'inbound-rtp', 'audio', 'totalSamplesReceived'),
                vrecv: sum(stats, 'inbound-rtp', 'video', 'packetsReceived')
            };
            var jitter = 0;
            var rtt = null;
            var path = '';
            var pair = null;
            stats.forEach(function (s) {
                if (s.type === 'inbound-rtp' && (s.kind || s.mediaType) === 'audio' && s.jitter > jitter) {
                    jitter = s.jitter;
                }
                if (s.type === 'transport' && s.selectedCandidatePairId) {
                    pair = stats.get(s.selectedCandidatePairId);
                }
            });
            if (pair) {
                rtt = typeof pair.currentRoundTripTime === 'number' ? Math.round(pair.currentRoundTripTime * 1000) : null;
                var local = stats.get(pair.localCandidateId);
                path = local ? (local.candidateType || '') + '/' + (local.protocol || '') +
                    (local.relayProtocol ? '/' + local.relayProtocol : '') : '';
            }
            var prev = diag.last || now;
            var paused = Array.prototype.filter.call(document.querySelectorAll('audio'), function (el) {
                return el.srcObject && el.paused;
            }).length;
            var micTrack = mic && mic.jitsiTrack && mic.jitsiTrack.getTrack && mic.jitsiTrack.getTrack();
            // [time, ice, sent, received, lost, concealed %, jitter ms, rtt ms,
            //  path, mic (on/off/silenced/ended/none), paused remote audio, video received]
            diag.samples.push([
                Date.now(), pc.iceConnectionState,
                now.sent - prev.sent, now.recv - prev.recv, now.lost - prev.lost,
                now.samp - prev.samp > 0 ? Math.round(100 * (now.conc - prev.conc) / (now.samp - prev.samp)) : null,
                Math.round(jitter * 1000), rtt, path,
                !micTrack ? 'none' : micTrack.readyState === 'ended' ? 'ended' : micTrack.muted ? 'silenced' : mic.muted ? 'off' : 'on',
                paused, now.vrecv - prev.vrecv
            ]);
            diag.last = now;
            var dropped = diag.samples.length - 90;
            if (dropped > 0) {
                diag.samples.splice(0, dropped);
                diag.sentSamples = Math.max(0, diag.sentSamples - dropped);
            }
        }, function () { /* the connection is changing; next time */ });
    }
    setInterval(sample, 10000);

    function sendDiag(leaving) {
        var room = joinedRoom();
        if (!diag.joinedAt || (!room && !leaving)) {
            return;
        }
        var samples = diag.samples.slice(diag.sentSamples);
        var events = diag.events.slice(diag.sentEvents);
        if (!samples.length && !events.length && !leaving) {
            return;
        }
        var report = {
            v: 1,
            room: (window.APP.conference.roomName || '').slice(0, 80),
            ep: (window.APP.conference.getMyUserId && window.APP.conference.getMyUserId()) || '',
            ua: navigator.userAgent.slice(0, 200),
            joined: diag.joinedAt,
            leaving: Boolean(leaving),
            samples: samples,
            events: events
        };
        var body = JSON.stringify(report);
        var sent = false;
        try {
            sent = navigator.sendBeacon && navigator.sendBeacon(DIAG_URL, new Blob([ body ], { type: 'text/plain' }));
        } catch (e) {
            sent = false;
        }
        if (!sent) {
            try {
                fetch(DIAG_URL, { method: 'POST', body: body, keepalive: true, credentials: 'omit' });
            } catch (e) {
                return;
            }
        }
        diag.sentSamples = diag.samples.length;
        diag.sentEvents = diag.events.length;
    }
    setInterval(function () { sendDiag(false); }, 60000);
    window.addEventListener('pagehide', function () {
        diagEvent('left');
        sendDiag(true);
    });
    document.addEventListener('visibilitychange', function () {
        diagEvent(document.visibilityState === 'hidden' ? 'page-hidden' : 'page-shown');
    });
    window.addEventListener('offline', function () { diagEvent('offline'); });
    window.addEventListener('online', function () { diagEvent('online'); });
})();

// Reactions open on click, like every other toolbar button (stock Jitsi
// opens them on hover). A picker opened any other way is closed at once;
// a second click, a click outside or Escape closes it.
(function reactionsOnClick() {
    var CONTAINER = '.reactions-menu-popup-container';
    var clickOpen = false;
    var store = function () { return window.APP && window.APP.store; };
    var isOpen = function () { var s = store(); var r = s && s.getState()['features/reactions']; return Boolean(r && r.visible); };
    var toggle = function () { var s = store(); if (s) { s.dispatch({type: 'TOGGLE_REACTIONS_VISIBLE'}); } };
    var watch = function () {
        var s = store();
        if (!s) { setTimeout(watch, 500); return; }
        // Hover opens the picker in stock Jitsi; only a click may open it here.
        s.subscribe(function () {
            if (isOpen() && !clickOpen) { toggle(); }
            if (!isOpen()) { clickOpen = false; }
        });
    };
    watch();
    document.addEventListener('click', function (e) {
        var target = e.target;
        var button = target.closest && target.closest(CONTAINER + ' .toolbox-button');
        if (button) {
            e.preventDefault();
            e.stopPropagation();
            clickOpen = !isOpen();
            toggle();
            return;
        }
        if (isOpen() && !(target.closest && target.closest(CONTAINER))) {
            toggle();
        }
    }, true);
    document.addEventListener('keydown', function (e) { if (e.key === 'Escape' && isOpen()) { toggle(); } }, true);
})();
