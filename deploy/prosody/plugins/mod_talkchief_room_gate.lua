-- mod_talkchief_room_gate.lua
-- TalkChief Cowork Meetings: asks Cowork whether a room may be joined, loaded
-- on the main MUC component.
--
-- When someone joins a room the module hasn't checked recently, it sends Cowork
-- a signed {"event":"room_check","tenant","room","ts"} through the same private
-- "events" relay and HMAC key as mod_talkchief_room_events. Cowork answers
-- {"allow":bool,"reason":"unknown|cancelled|ended|closed","instant":bool}
-- (talkchiefMeetingsRoomCheck in Cowork):
--
--  * refused rooms (a room Cowork doesn't know in that tenant, a cancelled
--    meeting, an ended Meet now meeting, a meeting past its close) answer the
--    join with not-authorized, like mod_talkchief_room_policy, so the web
--    client shows the branded access page, whose links lead to Cowork's
--    "This meeting has ended" page. This holds even for someone who still has
--    an old member token or room address.
--  * instant=true marks a Meet now room (room._data.talkchief_instant), which
--    mod_talkchief_host_drop ends when its last moderator has been gone for
--    the grace period.
--
-- Fail open (owner's decision, 2026-11-26): no answer within
-- talkchief_room_check_timeout seconds (default 2), an error, an unsigned
-- setup, or a join that can't wait lets the person in. A Cowork outage never
-- blocks a meeting. Answers are cached per room for a short while so a room
-- filling up asks once.
--
-- Skipped: health-check rooms and Jitsi's own components (focus, recorders),
-- which join without a meeting of their own.

local jid = require 'util.jid';
local json = require 'cjson.safe';
local hashes = require 'util.hashes';
local http = require 'net.http';
local st = require 'util.stanza';
local timer = require 'util.timer';

local util = module:require 'util';
local is_healthcheck_room = util.is_healthcheck_room;
local is_admin = util.is_admin;

local have_async, async = pcall(require, 'util.async');

local secret = os.getenv('TALKCHIEF_EVENTS_SECRET') or '';
local url = os.getenv('TALKCHIEF_EVENTS_URL') or 'http://events/talkchief/meetings/events';
local check_timeout = module:get_option_number('talkchief_room_check_timeout', 2);
local cache_seconds = module:get_option_number('talkchief_room_check_cache', 30);

if secret == '' then
    module:log('warn', 'TALKCHIEF_EVENTS_SECRET is not set; rooms are not checked with Cowork (everyone is let in)');
    return;
end

-- room jid -> { allow = bool, instant = bool, reason = string, at = seconds }
local answers = {};

-- Multi-tenant rooms are named "[tenant]room".
local function tenant_and_room(room)
    local node = jid.node(room.jid) or '';
    local tenant, name = node:match('^%[(.-)%](.*)$');
    return tenant, name;
end

local function now()
    return os.time();
end

-- The answer Cowork gave, or nil for "no usable answer" (fail open).
local function parse_answer(body, code)
    if code ~= 200 or type(body) ~= 'string' then
        return nil;
    end
    local data = json.decode(body);
    if type(data) ~= 'table' or type(data.allow) ~= 'boolean' then
        return nil;
    end
    return {
        allow = data.allow;
        instant = data.instant == true;
        reason = type(data.reason) == 'string' and data.reason or nil;
    };
end

-- Asks Cowork; calls back once with the answer or nil (timeout, error).
local function ask(tenant, name, callback)
    local body = json.encode({ event = 'room_check'; tenant = tenant; room = name; ts = os.time() });
    local finished = false;
    local function finish(answer)
        if finished then
            return;
        end
        finished = true;
        callback(answer);
    end
    local request = http.request(url, {
        method = 'POST';
        body = body;
        headers = {
            ['Content-Type'] = 'application/json';
            ['X-TalkChief-Signature'] = hashes.hmac_sha256(secret, body, true);
        };
    }, function (response_body, code)
        if code ~= 200 then
            module:log('warn', 'room check for %s/%s answered %s; letting people in', tenant, name, tostring(code));
        end
        finish(parse_answer(response_body, code));
    end);
    timer.add_task(check_timeout, function ()
        if not finished then
            module:log('warn', 'room check for %s/%s timed out after %ss; letting people in', tenant, name, tostring(check_timeout));
            if request and http.destroy_request then
                http.destroy_request(request);
            end
            finish(nil);
        end
    end);
end

local function remember(room, answer)
    if answer then
        answer.at = now();
        answers[room.jid] = answer;
        if answer.instant then
            room._data.talkchief_instant = true;
        end
    end
end

local function cached(room)
    local answer = answers[room.jid];
    if answer and now() - answer.at < cache_seconds then
        return answer;
    end
    return nil;
end

module:hook('muc-occupant-pre-join', function (event)
    local room, occupant = event.room, event.occupant;
    if is_healthcheck_room(room.jid) or is_admin(occupant.bare_jid) then
        return;
    end
    local tenant, name = tenant_and_room(room);
    if not tenant or tenant == '' or not name or name == '' then
        return;
    end

    local answer = cached(room);
    if not answer then
        if not (have_async and async.ready and async.ready()) then
            -- This join can't wait: let it in, and ask for the next one.
            ask(tenant, name, function (a) remember(room, a); end);
            return;
        end
        local wait, done = async.waiter();
        ask(tenant, name, function (a)
            answer = a;
            done();
        end);
        wait();
        remember(room, answer);
    end

    if answer and not answer.allow then
        module:log('info', 'refused %s from %s: %s', occupant.bare_jid, room.jid, tostring(answer.reason));
        event.origin.send(st.error_reply(event.stanza, 'auth', 'not-authorized'));
        return true;
    end
end, 30);

module:hook('muc-room-destroyed', function (event)
    answers[event.room.jid] = nil;
end, -100);

-- For tests (Prosody ignores a module's return value).
return {
    parse_answer = parse_answer;
    tenant_and_room = tenant_and_room;
};
