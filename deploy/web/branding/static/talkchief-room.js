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
        var tracks = store.getState()['features/base/tracks'] || [];
        var now = {};
        tracks.forEach(function (t) {
            if (!t.local && t.mediaType === 'video' && t.videoType === 'desktop' && t.participantId) {
                now[t.participantId] = true;
            }
        });
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
