-- TalkChief Cowork Meetings room events, loaded on the main MUC component.
--
-- Tells Cowork when a meeting room opens and when it closes (the last person
-- left, or a moderator ended the meeting for everyone), so Cowork's meeting
-- cards show "Ended" and the conversation's next call starts a new meeting.
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

local function send(event, room)
    if is_healthcheck_room(room.jid) then
        return;
    end
    local tenant, name = tenant_and_room(room);
    if not tenant or tenant == '' or not name or name == '' then
        return;
    end
    local body = json.encode({ event = event; tenant = tenant; room = name; ts = os.time() });
    http.request(url, {
        method = 'POST';
        body = body;
        headers = {
            ['Content-Type'] = 'application/json';
            ['X-TalkChief-Signature'] = hashes.hmac_sha256(secret, body, true);
        };
    }, function(_, code)
        if code ~= 204 and code ~= 200 then
            module:log('warn', 'room event %s for %s/%s answered %s', event, tenant, name, tostring(code));
        end
    end);
end

module:hook('muc-room-created', function (event)
    send('room_created', event.room);
end, -100);

module:hook('muc-room-destroyed', function (event)
    send('room_destroyed', event.room);
end, -100);
