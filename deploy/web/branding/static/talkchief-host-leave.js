// TalkChief Cowork Meetings: "assign a new host or end for all", like Zoom.
//
// When the host of a Meet now meeting (Cowork adds talkchief.instant=true to
// the host's join link) presses Leave while other people are still in the
// meeting and nobody else is a moderator, they choose first:
//   * make someone else host (Jitsi's "grant moderator") and leave,
//   * end the meeting for everyone (Jitsi's own End meeting for all), or
//   * leave anyway: then mod_talkchief_host_drop on the server ends the
//     meeting when no host has been back for 60 seconds.
//
// Upgrade-safe by design: it wraps Jitsi's single leave path on the web,
// APP.conference.hangup, which Leave (leaveConference -> hangup(true)) goes
// through; it never patches Jitsi's DOM. Only a user's own Leave prompts:
// leaves Jitsi starts itself (meeting ended, kicked) pass a reason and go
// straight through. If anything it relies on is missing or throws, it calls
// the original hangup, so Leave always works. Tested on docker-jitsi-meet
// stable-11248-2 (deploy/VERSION).
(function () {
    var INSTANT_KEY = 'talkchief.instant';

    function isInstant(hash) {
        try {
            var value = new URLSearchParams(String(hash || '').replace(/^#/, '')).get(INSTANT_KEY);
            return value === 'true' || value === '"true"';
        } catch (e) {
            return false;
        }
    }

    function role(p) {
        try {
            return typeof p.getRole === 'function' ? p.getRole() : p.role;
        } catch (e) {
            return undefined;
        }
    }

    function isHidden(p) {
        try {
            return typeof p.isHidden === 'function' ? p.isHidden() : Boolean(p.hidden);
        } catch (e) {
            return false;
        }
    }

    // A guest joined anonymously through the guest domain (guest.meet.jitsi);
    // the host, a moderator, sees real addresses. Unknown means not a guest.
    function isGuest(p) {
        try {
            var jid = typeof p.getJid === 'function' ? p.getJid() : p.jid;
            return typeof jid === 'string' && /@guest\./.test(jid);
        } catch (e) {
            return false;
        }
    }

    function name(p) {
        try {
            return (typeof p.getDisplayName === 'function' ? p.getDisplayName() : p.displayName) || 'Participant';
        } catch (e) {
            return 'Participant';
        }
    }

    /**
     * What Leave should do. args: the hangup arguments (requestFeedback,
     * feedbackTitle, notifyOnConferenceTermination); local: the local role;
     * others: the other participants (JitsiParticipant-like).
     * Returns null to leave at once, else {candidates: [{id, name}]} to ask.
     */
    function leaveChoice(args, instant, localRole, others) {
        // Only the user's own Leave: hangup(true) with no reason.
        if (!instant || !args || args[0] !== true || args[1] !== undefined || args[2] !== undefined) {
            return null;
        }
        if (localRole !== 'moderator') {
            return null;
        }
        var people = (others || []).filter(function (p) { return !isHidden(p); });
        if (people.length === 0) {
            return null;
        }
        for (var i = 0; i < people.length; i++) {
            if (role(people[i]) === 'moderator') {
                return null;
            }
        }
        return {
            candidates: people.filter(function (p) { return !isGuest(p); }).map(function (p) {
                return { id: typeof p.getId === 'function' ? p.getId() : p.id, name: name(p) };
            })
        };
    }

    function el(tag, attrs, text) {
        var node = document.createElement(tag);
        Object.keys(attrs || {}).forEach(function (k) { node.setAttribute(k, attrs[k]); });
        if (text) {
            node.textContent = text;
        }
        return node;
    }

    function ask(choice, actions) {
        var old = document.getElementById('tc-host-leave');
        if (old) {
            old.remove();
        }
        var box = el('div', { id: 'tc-host-leave', 'class': 'tc-media-blocked tc-host-leave', role: 'alertdialog',
            'aria-labelledby': 'tc-host-leave-title', 'aria-describedby': 'tc-host-leave-text' });
        box.appendChild(el('strong', { id: 'tc-host-leave-title' }, 'You are the host'));
        box.appendChild(el('p', { id: 'tc-host-leave-text' }, choice.candidates.length
            ? 'Choose a new host before you leave, or end the meeting for everyone. If you leave without a host, the meeting ends a minute later.'
            : 'If you leave, the meeting ends a minute later. You can also end it for everyone now.'));
        var close = function () { box.remove(); document.removeEventListener('keydown', onKey, true); };
        var onKey = function (e) {
            if (e.key === 'Escape') {
                e.stopPropagation();
                close();
            }
        };
        var row = el('div', {});
        if (choice.candidates.length) {
            var select = el('select', { 'aria-label': 'New host' });
            choice.candidates.forEach(function (c) {
                var option = el('option', { value: c.id }, c.name);
                select.appendChild(option);
            });
            box.insertBefore(select, row);
            var assign = el('button', { type: 'button' }, 'Make host and leave');
            assign.onclick = function () { close(); actions.assignAndLeave(select.value); };
            row.appendChild(assign);
        }
        var end = el('button', { type: 'button', 'class': 'secondary' }, 'End for everyone');
        end.onclick = function () { close(); actions.endForAll(); };
        var leave = el('button', { type: 'button', 'class': 'secondary' }, 'Leave anyway');
        leave.onclick = function () { close(); actions.leave(); };
        var cancel = el('button', { type: 'button', 'class': 'secondary' }, 'Cancel');
        cancel.onclick = close;
        row.appendChild(end);
        row.appendChild(leave);
        row.appendChild(cancel);
        box.appendChild(row);
        document.body.appendChild(box);
        document.addEventListener('keydown', onKey, true);
        (row.querySelector('button') || cancel).focus();
    }

    function install(win, instant) {
        var app = win.APP;
        var conference = app && app.conference;
        if (!conference || typeof conference.hangup !== 'function' || conference.__talkchiefHostLeave) {
            return Boolean(conference && conference.__talkchiefHostLeave);
        }
        var original = conference.hangup;
        conference.__talkchiefHostLeave = true;
        conference.hangup = function () {
            var self = this;
            var args = arguments;
            var leaveNow = function () { return original.apply(self, args); };
            try {
                var state = app.store.getState();
                var jitsiConference = state['features/base/conference'].conference;
                var local = state['features/base/participants'].local || {};
                var choice = leaveChoice(args, instant, local.role, jitsiConference.getParticipants());
                if (!choice) {
                    return leaveNow();
                }
                ask(choice, {
                    leave: leaveNow,
                    endForAll: function () {
                        try {
                            jitsiConference.end();
                        } catch (e) {
                            leaveNow();
                        }
                    },
                    assignAndLeave: function (id) {
                        try {
                            jitsiConference.grantOwner(id);
                        } catch (e) {}
                        // The grant reaches the server before our presence leaves.
                        setTimeout(leaveNow, 300);
                    }
                });
                return Promise.resolve();
            } catch (e) {
                return leaveNow();
            }
        };
        return true;
    }

    if (typeof module !== 'undefined' && module.exports) {
        module.exports = { isInstant: isInstant, leaveChoice: leaveChoice, install: install };
        return;
    }

    var instant = isInstant(window.location.hash);
    if (!instant) {
        return;
    }
    var tries = 0;
    var timer = setInterval(function () {
        tries++;
        if (install(window, instant) || tries > 600) {
            clearInterval(timer);
        }
    }, 1000);
})();
