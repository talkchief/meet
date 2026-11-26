# TalkChief Prosody module tests

## Unit tests (Prosody stubbed)

From the repository root, with busted for Lua 5.4:

    busted deploy/prosody/tests/

`mod_talkchief_room_gate_spec.lua`, `mod_talkchief_host_drop_spec.lua` and `mod_talkchief_room_events_spec.lua` cover the decisions (also: the guest flag and separate guest/member answers; host_left/host_ended reasons; retries with the same nonce): refused and allowed rooms, the cache, fail open (error, timeout, a join that can't wait), skipped health checks and Jitsi components; the host-drop timer, a host back in time, a co-host, scheduled meetings, breakout rooms and rooms that closed first.

## VM test (the real Prosody and Jicofo)

`vm/` runs Prosody and Jicofo from docker-jitsi-meet (`deploy/VERSION`) with every TalkChief module and `deploy/env.talkchief`, a fake Cowork in place of the `events` relay (`vm/fake_cowork.py`: answers `room_check` from `/state/rooms.json`, logs every signed event), and XMPP clients with RS256 member tokens signed by a throwaway key (`vm/run.mjs`). The host-drop grace is 10 s there instead of 60 s. On a disposable Linux VM with Docker and Node, with this repository at `/home/user/meet`:

    bash deploy/prosody/tests/vm/setup.sh
    (cd deploy/prosody/tests/vm && npm install @xmpp/client@0.13.1 jsonwebtoken@9)
    docker run --rm --network deploy_meet.jitsi -v $PWD/deploy/prosody/tests/vm:/it -v /home/user/state:/state -w /it node:22-alpine node run.mjs

Notes from writing it:
- Jicofo's `/conference-request/v1` and the clients use the tenant form `room@muc.<tenant>.meet.jitsi`; `room@conference.<tenant>...` is refused as a remote domain.
- The web client sends the tenant as `?prefix=<tenant>` next to `?room=`; mod_end_conference needs it to find the room.
- The join presence needs a `<nick xmlns="http://jabber.org/protocol/nick">` (`ENABLE_REQUIRE_DISPLAY_NAME`), and room nicknames may not contain `-` (`muc_resource_validate`).
- The host-drop scenarios use member rooms: a `g-` room switches its lobby on when the host arrives, and a raw XMPP client can't knock and be admitted. The host-drop logic is the same for both kinds of room.

Last run: 2026-11-26 on a Boat VM (docker-jitsi-meet stable-11248-2, Prosody 13.0.7): 24/24 scenarios (End meeting for all → host_ended, guests off refused, retried room event with the same nonce added on 2026-11-26), and 18/18 busted specs.
