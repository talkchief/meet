-- Unit tests for mod_talkchief_room_gate.lua. From the repository root:
--   busted deploy/prosody/tests/
-- Prosody and Cowork are stubbed; the VM test in deploy/prosody/tests/README.md
-- covers the real meeting service.

local hooks, tasks, requests = {}, {}, {};
local priority;
local healthcheck, ready = false, true;
local reply; -- function (callback) answering the next request

local real_getenv = os.getenv;
os.getenv = function (k)
    if k == 'TALKCHIEF_EVENTS_SECRET' then return 'secret' end
    return real_getenv(k);
end

local bodies = {};
package.loaded['cjson.safe'] = {
    encode = function (t) return 'check:' .. t.tenant .. '/' .. t.room .. (t.guest and ':guest' or '') end,
    decode = function (s) return bodies[s] end,
};
package.loaded['util.hashes'] = { hmac_sha256 = function () return 'sig' end };
package.loaded['util.timer'] = { add_task = function (delay, fn) table.insert(tasks, fn) end };
package.loaded['util.stanza'] = {
    error_reply = function (_, kind, condition) return { kind = kind, condition = condition } end,
};
package.loaded['util.jid'] = {
    node = function (j) return j:match('^(.-)@') end,
    host = function (j) return j:match('@([^/]+)') end,
};
package.loaded['net.http'] = {
    request = function (url, options, callback)
        table.insert(requests, { url = url, options = options });
        if reply then reply(callback) end
        return {};
    end,
    destroy_request = function () end,
};
package.loaded['util.async'] = {
    ready = function () return ready end,
    waiter = function () return function () end, function () end end,
};

_G.module = {
    host = 'muc.meet.jitsi',
    log = function () end,
    get_option_number = function (_, _key, default) return default end,
    require = function (_, name)
        if name == 'util' then
            return {
                is_healthcheck_room = function () return healthcheck end,
                is_admin = function (j) return j:match('@auth%.meet%.jitsi') ~= nil end,
            };
        end
        return {};
    end,
    hook = function (_, name, fn, prio)
        hooks[name] = fn;
        if name == 'muc-occupant-pre-join' then priority = prio end
    end,
    get_option_string = function (_, _key, default) return default end,
};

local mod = dofile('deploy/prosody/plugins/mod_talkchief_room_gate.lua');
local n = 0;

local function new_room()
    n = n + 1;
    return { jid = '[acme]g-room' .. n .. '@muc.meet.jitsi', _data = {} };
end

local function join(room, bare)
    local sent = {};
    local result = hooks['muc-occupant-pre-join']({
        room = room,
        occupant = { bare_jid = bare or 'someone@meet.jitsi' },
        origin = { send = function (s) table.insert(sent, s) end },
        stanza = {},
    });
    return result, sent;
end

local function answer(code, body)
    return function (callback)
        local key = 'body' .. tostring(#requests);
        bodies[key] = body;
        callback(body and key or nil, code);
    end;
end

describe('mod_talkchief_room_gate', function ()
    before_each(function ()
        tasks, requests, healthcheck, ready, reply = {}, {}, false, true, nil;
    end);

    it('reads Cowork answers and room names', function ()
        assert.are.same({ allow = true, instant = true }, (function ()
            bodies.x = { allow = true, instant = true };
            return mod.parse_answer('x', 200);
        end)());
        assert.is_nil(mod.parse_answer('x', 500));
        bodies.y = { reason = 'ended' };
        assert.is_nil(mod.parse_answer('y', 200), 'no allow field: no usable answer');
        local tenant, name = mod.tenant_and_room({ jid = '[acme]g-abc@muc.meet.jitsi' });
        assert.are.equal('acme', tenant);
        assert.are.equal('g-abc', name);
    end);

    it('lets people into a room Cowork allows, and marks a Meet now room', function ()
        reply = answer(200, { allow = true, instant = true });
        local room = new_room();
        local result, sent = join(room);
        assert.is_nil(result);
        assert.are.equal(0, #sent);
        assert.is_true(room._data.talkchief_instant);
        assert.are.equal('check:acme/' .. room.jid:match('%](.-)@'), requests[1].options.body);
        assert.are.equal('sig', requests[1].options.headers['X-TalkChief-Signature']);
    end);

    it('refuses an ended meeting, even with an old token', function ()
        reply = answer(200, { allow = false, reason = 'ended', instant = true });
        local result, sent = join(new_room());
        assert.is_true(result);
        assert.are.same({ kind = 'auth', condition = 'not-authorized' }, sent[1]);
    end);

    it('asks once per room for a while', function ()
        reply = answer(200, { allow = false, reason = 'unknown' });
        local room = new_room();
        join(room);
        join(room);
        assert.are.equal(1, #requests);
    end);

    it('fails open: an error, a timeout or a join that cannot wait gets in', function ()
        reply = answer(502, nil);
        assert.is_nil(join(new_room()));

        reply = nil; -- Cowork never answers; the 2 s timer gives up
        local room = new_room();
        assert.is_nil(join(room));
        for _, t in ipairs(tasks) do t() end

        ready = false;
        reply = answer(200, { allow = false, reason = 'ended' });
        local later = new_room();
        assert.is_nil(join(later), 'let in now');
        ready = true;
        local result = join(later);
        assert.is_true(result, 'the next join uses the answer that came meanwhile');
    end);

    it('says whether the joiner is a guest, and keeps guest and member answers apart', function ()
        local room = new_room();
        reply = answer(200, { allow = false, reason = 'guests_off' });
        local result, sent = join(room, 'x1@guest.meet.jitsi');
        assert.is_true(result, 'guest refused');
        assert.are.same({ kind = 'auth', condition = 'not-authorized' }, sent[1]);
        assert.truthy(requests[1].options.body:match(':guest$'));

        reply = answer(200, { allow = true });
        assert.is_nil(join(room, 'member@meet.jitsi'), 'member let in');
        assert.is_nil(requests[2].options.body:match(':guest$'));
        assert.is_true(join(room, 'x2@guest.meet.jitsi'), 'the guest answer is cached for guests');
        assert.are.equal(2, #requests);
    end);

    it('runs after the room policy (priority below 20)', function ()
        assert.is_true(priority < 20);
    end);

    it('never checks health-check rooms or Jitsi components', function ()
        reply = answer(200, { allow = false });
        assert.is_nil(join(new_room(), 'focus@auth.meet.jitsi'));
        healthcheck = true;
        assert.is_nil(join(new_room()));
        assert.are.equal(0, #requests);
    end);
end);
