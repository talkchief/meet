-- mod_talkchief_room_policy.lua
-- TalkChief Cowork Meetings room policy, loaded on the main MUC component.
--
-- Cowork members always carry a Cowork-signed JWT (main VirtualHost). External
-- guests join anonymously through the guest VirtualHost, so mod_muc_wait_for_host
-- keeps treating them as non-hosts. On top of that:
--
--  * Guests may only enter rooms the host opened to guests: room names that start
--    with "g-". Every other room answers not-authorized, which the web client turns
--    into the branded access page (config.tokenAuthUrl).
--  * Token holders get member affiliation before the lobby gate (-4) so Cowork
--    members never knock; mod_token_affiliation (-3.5) upgrades hosts to owner.
--  * When a token holder is in a guest room, the lobby is switched on so every
--    later guest knocks and a moderator admits them (waiting room).

local jid = require 'util.jid';
local st = require 'util.stanza';
local util = module:require 'util';
local is_healthcheck_room = util.is_healthcheck_room;

local guest_domain = module:get_option_string('talkchief_guest_domain', 'guest.meet.jitsi');
local GUEST_ROOM_PREFIX = 'g-';

local function room_name(room)
    local node = jid.node(room.jid) or '';
    -- multi-tenant rooms are named "[tenant]room"
    return node:match('^%[.-%](.*)$') or node;
end

local function is_guest_room(room)
    return room_name(room):sub(1, #GUEST_ROOM_PREFIX) == GUEST_ROOM_PREFIX;
end

local function is_guest(occupant)
    return jid.host(occupant.bare_jid) == guest_domain;
end

-- mod_auth_token marks the sessions whose token it verified.
local function has_verified_token(session)
    return session and session.auth_token and session._jitsi_auth_done;
end

module:hook('muc-occupant-pre-join', function (event)
    local room, occupant = event.room, event.occupant;
    if is_healthcheck_room(room.jid) then
        return;
    end
    if is_guest(occupant) and not is_guest_room(room) then
        module:log('info', 'guest %s refused from internal room %s', occupant.bare_jid, room.jid);
        event.origin.send(st.error_reply(event.stanza, 'auth', 'not-authorized'));
        return true;
    end
end, 20);

module:hook('muc-occupant-pre-join', function (event)
    local room, occupant = event.room, event.occupant;
    if is_healthcheck_room(room.jid) or not room:get_members_only() then
        return;
    end
    if not has_verified_token(event.origin) then
        return;
    end
    local affiliation = room:get_affiliation(occupant.bare_jid);
    if not affiliation or affiliation == 'none' then
        room:set_affiliation(true, occupant.bare_jid, 'member');
    end
end, -3);

module:hook('muc-occupant-joined', function (event)
    local room = event.room;
    if is_healthcheck_room(room.jid) or not is_guest_room(room) or room:get_members_only() then
        return;
    end
    if not has_verified_token(event.origin) then
        return;
    end
    module:log('info', 'enabling lobby in guest room %s', room.jid);
    prosody.events.fire_event('create-lobby-room', { room = room; });
end, -10);
