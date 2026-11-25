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
--  * Guests who arrive before any member wait in mod_muc_wait_for_host's lobby.
--    That module only fires 'create-persistent-lobby-room'; mod_persistent_lobby
--    creates the lobby and must run on the main VirtualHost. The docker image has
--    no setting for a main-VirtualHost-only module (XMPP_MODULES also loads it on
--    the guest VirtualHost, which registers its global handlers twice), so this
--    module loads it. Without it guests walked straight into empty guest rooms.
--  * Fail closed: a guest never enters a guest room before a member has been in it.
--    If the waiting lobby is missing for any reason, the guest is refused.

local jid = require 'util.jid';
local st = require 'util.stanza';
local modulemanager = require 'core.modulemanager';
local util = module:require 'util';
local is_healthcheck_room = util.is_healthcheck_room;
local process_host_module = util.process_host_module;

local guest_domain = module:get_option_string('talkchief_guest_domain', 'guest.meet.jitsi');
local main_domain = module:get_option_string('muc_mapper_domain_base', 'meet.jitsi');
local GUEST_ROOM_PREFIX = 'g-';

process_host_module(main_domain, function (_, host)
    if modulemanager.is_loaded(host, 'persistent_lobby') then
        return;
    end
    local ok, err = modulemanager.load(host, 'persistent_lobby');
    if ok then
        module:log('info', 'loaded persistent_lobby on %s for muc_wait_for_host', host);
    else
        module:log('error', 'could not load persistent_lobby on %s: %s; guests are refused until a member is in the room', host, tostring(err));
    end
end);

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

-- After mod_muc_wait_for_host (0) and the lobby gate (-4): a guest who gets here in a
-- room that has had no member and has no lobby would walk straight in.
module:hook('muc-occupant-pre-join', function (event)
    local room, occupant = event.room, event.occupant;
    if is_healthcheck_room(room.jid) or not is_guest(occupant) or room.has_host or room:get_members_only() then
        return;
    end
    module:log('warn', 'guest %s refused from %s: no member yet and no waiting lobby', occupant.bare_jid, room.jid);
    event.origin.send(st.error_reply(event.stanza, 'auth', 'not-authorized'));
    return true;
end, -4.5);

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
