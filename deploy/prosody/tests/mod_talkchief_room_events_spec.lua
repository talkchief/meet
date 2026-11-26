-- Unit tests for mod_talkchief_room_events.lua. From the repository root:
--   busted deploy/prosody/tests/
-- Prosody and Cowork are stubbed; the VM test in deploy/prosody/tests/README.md
-- covers the real meeting service.

local hooks, tasks, requests = {}, {}, {};
local codes = {}; -- answers for the next requests, in order

local real_getenv = os.getenv;
os.getenv = function (k)
    if k == 'TALKCHIEF_EVENTS_SECRET' then return 'secret' end
    return real_getenv(k);
end

local n = 0;
package.loaded['util.id'] = { medium = function () n = n + 1; return 'nonce' .. n end };
package.loaded['util.json'] = {
    encode = function (t)
        return table.concat({ t.event, t.tenant, t.room, t.reason or '-', t.nonce }, '|');
    end,
};
package.loaded['util.hashes'] = { hmac_sha256 = function () return 'sig' end };
package.loaded['util.timer'] = { add_task = function (delay, fn) table.insert(tasks, { delay = delay, fn = fn }) end };
package.loaded['util.jid'] = { node = function (j) return j:match('^(.-)@') end };
package.loaded['net.http'] = {
    request = function (url, options, callback)
        table.insert(requests, options.body);
        callback('', table.remove(codes, 1));
    end,
};

_G.module = {
    host = 'muc.meet.jitsi',
    log = function () end,
    require = function (_, name)
        if name == 'util' then
            return { is_healthcheck_room = function () return false end };
        end
        return {};
    end,
    hook = function (_, name, fn) hooks[name] = fn end,
};

local mod = dofile('deploy/prosody/plugins/mod_talkchief_room_events.lua');

local function room(data)
    return { jid = '[acme]g-room@muc.meet.jitsi', _data = data or {} };
end

describe('mod_talkchief_room_events', function ()
    before_each(function ()
        tasks, requests, codes = {}, {}, {};
    end);

    it('says why a room closed: host_left from the host-drop module, host_ended from End meeting for all', function ()
        assert.are.equal('host_left', mod.close_reason(room({ talkchief_end_reason = 'host_left' }), nil));
        assert.are.equal('host_ended', mod.close_reason(room(), 'The meeting has been terminated'));
        assert.is_nil(mod.close_reason(room(), nil), 'the last person left');
        assert.is_nil(mod.close_reason(room(), 'some other reason'));

        codes = { 204 };
        hooks['muc-room-destroyed']({ room = room(), reason = 'The meeting has been terminated' });
        assert.truthy(requests[1]:match('^room_destroyed|acme|g%-room|host_ended|nonce'));
    end);

    it('retries an event Cowork did not take, with the same nonce, then gives up', function ()
        codes = { 503, 0, 500, 502 };
        hooks['muc-room-created']({ room = room() });
        assert.are.equal(1, #requests);
        for i, delay in ipairs({ 5, 30, 120 }) do
            assert.are.equal(1, #tasks, 'one retry scheduled at attempt ' .. i);
            assert.are.equal(delay, tasks[1].delay);
            local task = table.remove(tasks, 1);
            task.fn();
        end
        assert.are.equal(4, #requests);
        assert.are.equal(0, #tasks, 'gave up after three retries');
        for i = 2, 4 do
            assert.are.equal(requests[1], requests[i], 'the same signed body, nonce included');
        end
    end);

    it('does not retry an event Cowork refused (4xx other than 429)', function ()
        assert.is_false(mod.should_retry(400));
        assert.is_false(mod.should_retry(401));
        assert.is_true(mod.should_retry(429));
        assert.is_true(mod.should_retry(nil));
        codes = { 401 };
        hooks['muc-room-created']({ room = room() });
        assert.are.equal(0, #tasks);
    end);
end);
