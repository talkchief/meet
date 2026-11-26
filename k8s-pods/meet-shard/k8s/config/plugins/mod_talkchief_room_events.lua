-- TalkChief Cowork Meetings room events, loaded on the main MUC component.
--
-- Tells Cowork when a meeting room opens and when it closes (the last person
-- left, or a moderator ended the meeting for everyone), so Cowork's meeting
-- cards show "Ended" and the conversation's next call starts a new meeting.
-- A closed room says why when it is known (reason host_left or host_ended);
-- events carry a nonce and are retried when Cowork doesn't take them.
--
-- Events go to the internal "events" relay (docker-compose.override.yml), an
-- nginx reachable only on the compose network, which forwards them to Cowork
-- over the private network with TLS verified. Each event is signed with
-- HMAC-SHA256 (header X-TalkChief-Signature); the key is derived from the
-- meeting signing key, which Cowork also holds (deploy/scripts/install.sh,
-- EventsSecretFromKey in Cowork), and reaches this container as
-- TALKCHIEF_EVENTS_SECRET. Without it the module stays idle.

local jid = require 'util.jid';
local json = require 'util.json';
local hashes = require 'util.hashes';
local http = require 'net.http';
local id = require 'util.id';
local timer = require 'util.timer';
local util = module:require 'util';
local is_healthcheck_room = util.is_healthcheck_room;

local secret = os.getenv('TALKCHIEF_EVENTS_SECRET') or '';
local url = os.getenv('TALKCHIEF_EVENTS_URL') or 'http://events/talkchief/meetings/events';

if secret == '' then
    module:log('warn', 'TALKCHIEF_EVENTS_SECRET is not set; room events are not sent');
    return;
end

-- Multi-tenant rooms are named "[tenant]room".
local function tenant_and_room(room)
    local node = jid.node(room.jid) or '';
    local tenant, name = node:match('^%[(.-)%](.*)$');
    return tenant, name;
end

-- mod_end_conference (a moderator's "End meeting for all") destroys the room
-- with this reason after checking the sender is a moderator.
local END_CONFERENCE_REASON = 'The meeting has been terminated';

-- Retries for an event that got no 2xx (Cowork restarting, a network blip):
-- 5 s, 30 s and 120 s later, all within the 5 minutes Cowork accepts an event.
-- Each event carries a random nonce, so a retry Cowork already handled (or a
-- replay) changes nothing there.
local RETRY_DELAYS = { 5, 30, 120 };

local function should_retry(code)
    return code == nil or code == 0 or code == 429 or (type(code) == 'number' and code >= 500);
end

local function deliver(what, body, attempt)
    http.request(url, {
        method = 'POST';
        body = body;
        headers = {
            ['Content-Type'] = 'application/json';
            ['X-TalkChief-Signature'] = hashes.hmac_sha256(secret, body, true);
        };
    }, function(_, code)
        if code == 204 or code == 200 then
            return;
        end
        local delay = should_retry(code) and RETRY_DELAYS[attempt];
        if delay then
            module:log('warn', 'room event %s answered %s; retrying in %ss', what, tostring(code), tostring(delay));
            timer.add_task(delay, function () deliver(what, body, attempt + 1); end);
        else
            module:log('warn', 'room event %s answered %s; giving up', what, tostring(code));
        end
    end);
end

-- Why the room closed, when it is known: "host_left" (mod_talkchief_host_drop)
-- or "host_ended" (a moderator's End meeting for all). Either ends a Meet now
-- meeting in Cowork at once.
local function close_reason(room, destroy_reason)
    if room._data and room._data.talkchief_end_reason then
        return room._data.talkchief_end_reason;
    end
    if destroy_reason == END_CONFERENCE_REASON then
        return 'host_ended';
    end
    return nil;
end

local function send(event, room, destroy_reason)
    if is_healthcheck_room(room.jid) then
        return;
    end
    local tenant, name = tenant_and_room(room);
    if not tenant or tenant == '' or not name or name == '' then
        return;
    end
    local reason = event == 'room_destroyed' and close_reason(room, destroy_reason) or nil;
    local body = json.encode({ event = event; tenant = tenant; room = name; ts = os.time(); reason = reason; nonce = id.medium() });
    deliver(event .. ' for ' .. tenant .. '/' .. name, body, 1);
end

module:hook('muc-room-created', function (event)
    send('room_created', event.room);
end, -100);

module:hook('muc-room-destroyed', function (event)
    send('room_destroyed', event.room, event.reason);
end, -100);

-- For tests (Prosody ignores a module's return value).
return {
    close_reason = close_reason;
    should_retry = should_retry;
};
