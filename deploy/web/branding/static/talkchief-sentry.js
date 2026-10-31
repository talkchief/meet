// TalkChief Cowork Meetings: error and call-problem reporting to Sentry
// (project talkchief-meetings). Loaded in <head>, right after the vendored
// Sentry browser bundle, so errors during start-up are caught too.
//
// Privacy: no names, tokens, addresses or device labels are sent. Meeting
// URLs carry the member's token (?jwt=) and the display name
// (#userInfo.displayName=), so every URL is cut to its path before sending,
// console logs are never recorded, and there is no session replay or tracing.
// Reports go through meet.talkchief.io itself (/talkchief-sentry), so ad
// blockers don't drop them.
(function () {
    if (!window.Sentry || !window.Sentry.init) {
        return;
    }
    var DSN = 'https://2e0b865328e61274abfdb555f7b33298@o4504000494174208.ingest.us.sentry.io/4512351601491968';

    function cleanUrl(u) {
        if (typeof u !== 'string') {
            return u;
        }
        return u.replace(/[?#].*$/, '');
    }
    function cleanText(s) {
        if (typeof s !== 'string') {
            return s;
        }
        return s
            .replace(/([?&#](jwt|token)=)[^&#\s"']+/gi, '$1[removed]')
            .replace(/(userInfo\.(displayName|email)=)[^&#\s"']+/gi, '$1[removed]')
            .replace(/eyJ[\w-]{10,}\.[\w-]{10,}\.[\w-]{10,}/g, '[token]');
    }
    function cleanEvent(event) {
        if (event.request) {
            event.request.url = cleanUrl(event.request.url);
            delete event.request.query_string;
            delete event.request.cookies;
            if (event.request.headers) {
                delete event.request.headers.Referer;
                delete event.request.headers.referer;
            }
        }
        if (event.message) {
            event.message = cleanText(event.message);
        }
        (event.exception && event.exception.values || []).forEach(function (ex) {
            ex.value = cleanText(ex.value);
            (ex.stacktrace && ex.stacktrace.frames || []).forEach(function (f) {
                f.filename = cleanUrl(f.filename);
                f.abs_path = cleanUrl(f.abs_path);
            });
        });
        delete event.user;
        return event;
    }

    var path = window.location.pathname.split('/').filter(Boolean);
    var tenant = path.length > 1 ? path[0] : '';
    var room = path.length ? path[path.length - 1] : '';
    var page = room ? 'meeting' : 'other';
    if (/^static\//.test(window.location.pathname.slice(1))) {
        page = 'static';
    }

    window.Sentry.init({
        dsn: DSN,
        tunnel: '/talkchief-sentry',
        environment: 'production',
        release: 'meet-web@' + (document.currentScript && (document.currentScript.src.match(/[?&]v=(\w+)/) || [])[1] || 'dev'),
        sendDefaultPii: false,
        tracesSampleRate: 0,
        maxBreadcrumbs: 40,
        integrations: function (defaults) {
            return defaults.filter(function (i) {
                return i.name !== 'Breadcrumbs';
            }).concat([ window.Sentry.breadcrumbsIntegration({ console: false, dom: true, fetch: true, xhr: true, history: true }) ]);
        },
        // Noise from browser extensions and third-party scripts.
        denyUrls: [ /^chrome-extension:/, /^moz-extension:/, /^safari-(web-)?extension:/ ],
        ignoreErrors: [ 'ResizeObserver loop limit exceeded', 'ResizeObserver loop completed with undelivered notifications' ],
        beforeBreadcrumb: function (b) {
            if (b.category === 'console') {
                return null;
            }
            if (b.data) {
                [ 'url', 'from', 'to' ].forEach(function (k) {
                    if (b.data[k]) {
                        b.data[k] = cleanUrl(b.data[k]);
                    }
                });
            }
            if (b.message) {
                b.message = cleanText(b.message);
            }
            return b;
        },
        beforeSend: cleanEvent
    });
    window.Sentry.setTags({
        component: 'meeting-page',
        page: page,
        tenant: tenant,
        room: room,
        guest: /^g-/.test(room) ? 'yes' : 'no'
    });

    // Call problems the meeting page notices (talkchief-room.js calls this
    // from its diagnostics). Each kind is reported at most once per page every
    // 10 minutes, with the last minute of connection samples attached.
    var REPORT = {
        'signalling-failed': { level: 'error', title: 'Lost the connection to the meeting service' },
        'conference-failed': { level: 'error', title: 'Could not join or stay in the meeting' },
        'ice-failed': { level: 'error', title: 'Media connection failed (ICE failed)' },
        'media-stuck': { level: 'warning', title: 'Media interrupted for more than 15 seconds' },
        'mic-ended': { level: 'warning', title: 'Microphone stopped during the meeting' },
        'audio-restart-refused': { level: 'warning', title: 'Could not restart paused incoming audio' }
    };
    var lastSent = {};
    var stuckTimer = null;
    function report(kind, detail) {
        var r = REPORT[kind];
        var now = Date.now();
        if (!r || (lastSent[kind] && now - lastSent[kind] < 600000)) {
            return;
        }
        lastSent[kind] = now;
        var snap = typeof window.tcDiagSnapshot === 'function' ? window.tcDiagSnapshot() : null;
        window.Sentry.withScope(function (scope) {
            scope.setLevel(r.level);
            scope.setTag('problem', kind);
            scope.setFingerprint([ 'call-problem', kind ]);
            if (snap) {
                scope.setTag('ep', snap.ep || '');
                scope.setContext('call', {
                    detail: detail === undefined ? null : cleanText(String(detail)).slice(0, 120),
                    minutesInMeeting: snap.joinedAt ? Math.round((now - snap.joinedAt) / 6000) / 10 : null,
                    // [time, ice, sent, received, lost, concealed %, jitter ms, rtt ms, path, mic, paused, video]
                    lastSamples: JSON.stringify(snap.samples),
                    lastEvents: JSON.stringify(snap.events)
                });
            }
            window.Sentry.captureMessage(r.title);
        });
    }
    window.tcReport = function (type, detail) {
        try {
            if (type === 'ice' && detail === 'failed') {
                report('ice-failed', detail);
            } else if (type === 'media-interrupted') {
                clearTimeout(stuckTimer);
                stuckTimer = setTimeout(function () { report('media-stuck'); }, 15000);
            } else if (type === 'media-restored' || type === 'left') {
                clearTimeout(stuckTimer);
            } else if (REPORT[type]) {
                report(type, detail);
            }
        } catch (e) {
            // reporting must never break the meeting
        }
    };
})();
