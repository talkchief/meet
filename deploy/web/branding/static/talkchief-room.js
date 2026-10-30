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
})();
