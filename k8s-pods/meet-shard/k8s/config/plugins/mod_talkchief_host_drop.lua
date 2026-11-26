-- mod_talkchief_host_drop.lua
-- TalkChief Cowork Meetings: a Meet now meeting ends when its host is gone,
-- like Zoom's instant meetings. Loaded on the main MUC component.
--
-- Only rooms mod_talkchief_room_gate marked as instant (Cowork's room check
-- said so). When the last moderator leaves (closed tab, lost network, or Leave
-- without choosing a new host) while other people are still in the room, a
-- timer starts (talkchief_host_drop_grace seconds, default 60). When it fires
-- and there is still no moderator in the room (the host didn't come back, and
-- nobody was made host or co-host), the room is destroyed for everyone.
-- mod_talkchief_room_events then reports the room closed with reason
-- "host_left", and Cowork ends the meeting at once: its links answer "This
-- meeting has ended", and mod_talkchief_room_gate refuses the room.
--
-- Nothing happens while any moderator (the host, or a co-host someone made
-- moderator) is in the room, while breakout rooms are open (people in them
-- have left the main room), or when the room empties (Prosody closes it, and
-- Cowork ends the meeting after its own grace period).

local util = module:require 'util';
local is_healthcheck_room = util.is_healthcheck_room;
local is_admin = util.is_admin;
local get_room_from_jid = util.get_room_from_jid;

local timer = require 'util.timer';

local grace = module:get_option_number('talkchief_host_drop_grace', 60);

-- room jid -> the pending timer's token (a new token cancels the old timer)
local pending = {};

local function is_person(occupant)
    return occupant and not is_admin(occupant.bare_jid);
end

-- Whether anyone but the leaving occupant (nick) is a moderator, and whether
-- anyone but them is in the room at all.
local function others(room, leaving_nick)
    local moderator, people = false, false;
    for _, occupant in room:each_occupant() do
        if occupant.nick ~= leaving_nick and is_person(occupant) then
            people = true;
            if occupant.role == 'moderator' then
                moderator = true;
            end
        end
    end
    return moderator, people;
end

local function breakout_rooms_open(room)
    local data = room._data or {};
    return data.breakout_rooms_active == true;
end

-- Ends the room if, after the grace period, nobody is its host.
local function check(room_jid, token)
    if pending[room_jid] ~= token then
        return;
    end
    pending[room_jid] = nil;
    local room = get_room_from_jid(room_jid);
    if not room or room.destroying then
        return;
    end
    local moderator, people = others(room, nil);
    if moderator or not people or breakout_rooms_open(room) then
        return;
    end
    module:log('info', 'no host in %s for %ss: ending the meeting', room_jid, tostring(grace));
    room._data.talkchief_end_reason = 'host_left';
    room:destroy(nil, 'The host left the meeting.');
end

module:hook('muc-occupant-pre-leave', function (event)
    local room, occupant = event.room, event.occupant;
    if is_healthcheck_room(room.jid) or not room._data.talkchief_instant then
        return;
    end
    if not is_person(occupant) or occupant.role ~= 'moderator' then
        return;
    end
    local moderator, people = others(room, occupant.nick);
    if moderator or not people or pending[room.jid] then
        return;
    end
    local token = {};
    pending[room.jid] = token;
    module:log('info', 'last moderator left %s; ending it in %ss unless a host is back', room.jid, tostring(grace));
    timer.add_task(grace, function ()
        check(room.jid, token);
    end);
end);

module:hook('muc-room-destroyed', function (event)
    pending[event.room.jid] = nil;
end, -100);

-- For tests (Prosody ignores a module's return value).
return {
    others = others;
    check = check;
    pending = pending;
};
