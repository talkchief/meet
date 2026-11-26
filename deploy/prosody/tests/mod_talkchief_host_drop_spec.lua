-- Unit tests for mod_talkchief_host_drop.lua. From the repository root:
--   busted deploy/prosody/tests/
-- Prosody is stubbed; the VM test in deploy/prosody/tests/README.md covers the
-- real meeting service.

local hooks, tasks = {}, {};
local healthcheck, rooms = false, {};

package.loaded['util.timer'] = {
    add_task = function (delay, fn) table.insert(tasks, { delay = delay, fn = fn }); end,
};

_G.module = {
    host = 'muc.meet.jitsi',
    log = function () end,
    get_option_number = function (_, _key, default) return default end,
    require = function (_, name)
        if name == 'util' then
            return {
                is_healthcheck_room = function () return healthcheck end,
                is_admin = function (jid) return jid:match('@auth%.meet%.jitsi') ~= nil end,
                get_room_from_jid = function (jid) return rooms[jid] end,
            };
        end
        return {};
    end,
    hook = function (_, name, fn) hooks[name] = fn end,
};

local mod = dofile('deploy/prosody/plugins/mod_talkchief_host_drop.lua');

local function occupant(nick, role, bare)
    return { nick = nick, role = role, bare_jid = bare or (nick .. '@meet.jitsi') };
end

local count = 0;
local function room(instant, occupants)
    count = count + 1;
    local r = {
        jid = '[acme]g-room' .. count .. '@muc.meet.jitsi',
        _data = { talkchief_instant = instant },
        occupants = occupants,
        destroyed = nil,
    };
    function r:each_occupant()
        local i = 0;
        return function ()
            i = i + 1;
            local o = self.occupants[i];
            if o then return o.nick, o end
        end;
    end
    function r:destroy(_, reason) self.destroyed = reason end
    rooms[r.jid] = r;
    return r;
end

local function leave(r, o)
    hooks['muc-occupant-pre-leave']({ room = r, occupant = o });
    for i, other in ipairs(r.occupants) do
        if other == o then table.remove(r.occupants, i) break end
    end
end

local function fire_all()
    local pending = tasks;
    tasks = {};
    for _, t in ipairs(pending) do t.fn() end
end

describe('mod_talkchief_host_drop', function ()
    before_each(function ()
        tasks, healthcheck = {}, false;
    end);

    it('ends a Meet now room 60 s after its only host left others behind', function ()
        local host, guest = occupant('host', 'moderator'), occupant('guest', 'participant', 'x@guest.meet.jitsi');
        local r = room(true, { occupant('focus', 'moderator', 'focus@auth.meet.jitsi'), host, guest });
        leave(r, host);
        assert.are.equal(1, #tasks);
        assert.are.equal(60, tasks[1].delay);
        fire_all();
        assert.are.equal('The host left the meeting.', r.destroyed);
        assert.are.equal('host_left', r._data.talkchief_end_reason);
    end);

    it('keeps the room when the host is back in time', function ()
        local host = occupant('host', 'moderator');
        local r = room(true, { host, occupant('a', 'participant') });
        leave(r, host);
        table.insert(r.occupants, occupant('host2', 'moderator'));
        fire_all();
        assert.is_nil(r.destroyed);
    end);

    it('does nothing while a co-host stays', function ()
        local host = occupant('host', 'moderator');
        local r = room(true, { host, occupant('cohost', 'moderator'), occupant('a', 'participant') });
        leave(r, host);
        assert.are.equal(0, #tasks);
    end);

    it('does nothing when a participant leaves, or the host leaves alone', function ()
        local host, a = occupant('host', 'moderator'), occupant('a', 'participant');
        local r = room(true, { host, a });
        leave(r, a);
        assert.are.equal(0, #tasks);
        leave(r, host);
        assert.are.equal(0, #tasks, 'nobody left: Prosody closes the room itself');
    end);

    it('leaves scheduled meetings and health checks alone', function ()
        local host = occupant('host', 'moderator');
        local r = room(false, { host, occupant('a', 'participant') });
        leave(r, host);
        assert.are.equal(0, #tasks);
        healthcheck = true;
        local h = occupant('host', 'moderator');
        local r2 = room(true, { h, occupant('a', 'participant') });
        leave(r2, h);
        assert.are.equal(0, #tasks);
    end);

    it('waits while breakout rooms are open', function ()
        local host = occupant('host', 'moderator');
        local r = room(true, { host, occupant('a', 'participant') });
        leave(r, host);
        r._data.breakout_rooms_active = true;
        fire_all();
        assert.is_nil(r.destroyed);
    end);

    it('forgets a room that closed before the timer fired', function ()
        local host = occupant('host', 'moderator');
        local r = room(true, { host, occupant('a', 'participant') });
        leave(r, host);
        hooks['muc-room-destroyed']({ room = r });
        fire_all();
        assert.is_nil(r.destroyed);
        assert.is_nil(mod.pending[r.jid]);
    end);
end);
