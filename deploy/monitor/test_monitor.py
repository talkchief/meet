"""Tests for monitor.py's configuration and check selection. No network, no
Sentry: sentry_sdk is replaced by a stub and every check function is patched.

    python -m unittest discover -s deploy/monitor -v
"""
import importlib.util
import itertools
import os
import sys
import types
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
ENV_KEYS = ('MONITOR_ROLE', 'BRIDGES', 'EXPECTED_BRIDGES', 'TURN_HOST', 'SENTRY_SERVER_NAME',
            'COMPOSE_PROJECT', 'HEALTH_MONITOR', 'SENTRY_ENVIRONMENT', 'SENTRY_RELEASE')
ORIGINAL_CHECKS = ['meet-jvb', 'meet-jicofo', 'meet-bridge', 'meet-prosody', 'meet-web', 'meet-turn']
_counter = itertools.count()


class StopLoop(Exception):
    pass


def stub_sentry():
    sdk = types.ModuleType('sentry_sdk')
    sdk.inits = []
    sdk.init = lambda **kw: sdk.inits.append(kw)
    sdk.set_tag = lambda *a, **k: None
    sdk.new_scope = mock.MagicMock()
    sdk.capture_message = mock.MagicMock()
    crons = types.ModuleType('sentry_sdk.crons')
    crons.capture_checkin = mock.MagicMock()
    consts = types.ModuleType('sentry_sdk.crons.consts')
    consts.MonitorStatus = types.SimpleNamespace(OK='ok', ERROR='error')
    sdk.crons = crons
    crons.consts = consts
    return {'sentry_sdk': sdk, 'sentry_sdk.crons': crons, 'sentry_sdk.crons.consts': consts}


def load(**env):
    """Imports a fresh copy of monitor.py with exactly these monitor settings."""
    environ = {k: v for k, v in os.environ.items() if k not in ENV_KEYS}
    environ['SENTRY_DSN'] = 'https://public@example.invalid/1'
    environ.update(env)
    modules = stub_sentry()
    spec = importlib.util.spec_from_file_location('monitor_under_test_%d' % next(_counter),
                                                  os.path.join(HERE, 'monitor.py'))
    mod = importlib.util.module_from_spec(spec)
    with mock.patch.dict(os.environ, environ, clear=True), mock.patch.dict(sys.modules, modules):
        spec.loader.exec_module(mod)
    mod._sentry = modules['sentry_sdk']
    return mod


def run_checks(mod):
    """Runs every check with http_ok / stun_ok / jicofo_stats patched; returns the calls made."""
    calls = []

    def http_ok(url, ok=None, headers=None):
        calls.append(('http', url, headers))
        return True, 'HTTP 200'

    def stun_ok(host, port=3478):
        calls.append(('stun', host))
        return True, 'binding success'

    with mock.patch.object(mod, 'http_ok', http_ok), mock.patch.object(mod, 'stun_ok', stun_ok), \
            mock.patch.object(mod, 'jicofo_stats', lambda: {'bridge_selector': {'operational_bridge_count': 1}}):
        results = {name: check() for name, check in mod.CHECKS.items()}
    return calls, results


class DefaultsUnchanged(unittest.TestCase):
    """With BRIDGES and MONITOR_ROLE unset, the checks are exactly the original six."""

    def test_same_checks_same_targets(self):
        mod = load()
        self.assertEqual(mod.ROLE, 'main')
        self.assertEqual(list(mod.CHECKS), ORIGINAL_CHECKS)
        self.assertEqual(mod.SERVICES, {'jicofo', 'jvb', 'prosody', 'web', 'coturn'})
        self.assertEqual(mod._sentry.inits[0]['server_name'], 'meet.talkchief.io')
        self.assertEqual(mod.EXPECTED_BRIDGES, 1)
        calls, results = run_checks(mod)
        site = {'Host': 'meet.talkchief.io'}
        self.assertEqual(calls, [
            ('http', 'http://127.0.0.1:8080/about/health', None),
            ('http', 'http://127.0.0.1:8888/stats', None),
            ('http', 'https://127.0.0.1/http-bind', site),
            ('http', 'https://127.0.0.1/', site),
            ('stun', '46.225.31.248'),
        ])
        self.assertEqual(results['meet-bridge'], (True, '1 operational video bridge(s)'))

    def test_empty_values_from_compose_mean_unset(self):
        # The override passes BRIDGES= and EXPECTED_BRIDGES= when not configured.
        mod = load(BRIDGES='', EXPECTED_BRIDGES='', TURN_HOST='46.225.31.248')
        self.assertEqual(list(mod.CHECKS), ORIGINAL_CHECKS)
        self.assertEqual(mod.EXPECTED_BRIDGES, 1)

    def test_bridge_check_still_fails_with_no_bridge(self):
        mod = load()
        with mock.patch.object(mod, 'jicofo_stats', lambda: {'bridge_selector': {'operational_bridge_count': 0}}):
            self.assertEqual(mod.bridge_ok(), (False, '0 operational video bridge(s)'))
        with mock.patch.object(mod, 'jicofo_stats', lambda: None):
            self.assertEqual(mod.bridge_ok(), (False, 'no jicofo stats'))


class Parsing(unittest.TestCase):
    def setUp(self):
        self.mod = load()

    def test_parse_bridges(self):
        self.assertEqual(self.mod.parse_bridges(' 10.1.0.50, 10.1.0.51,,10.1.0.50,bogus,10.1.0.300 '),
                         (['10.1.0.50', '10.1.0.51'], ['bogus', '10.1.0.300']))
        self.assertEqual(self.mod.parse_bridges(''), ([], []))
        self.assertEqual(self.mod.parse_bridges(None), ([], []))

    def test_parse_turn_hosts(self):
        p = self.mod.parse_turn_hosts
        self.assertEqual(p('46.225.31.248'), (['46.225.31.248'], []))
        self.assertEqual(p('46.225.31.248,10.1.0.44'), (['46.225.31.248'], ['10.1.0.44']))
        self.assertEqual(p('turn1.talkchief.io, turn2.talkchief.io,turn1.talkchief.io'),
                         (['turn1.talkchief.io', 'turn2.talkchief.io'], []))
        self.assertEqual(p('127.0.0.1,'), ([], ['127.0.0.1']))
        self.assertEqual(p(''), ([], []))

    def test_parse_expected_bridges(self):
        p = self.mod.parse_expected_bridges
        self.assertEqual(p('', ['a', 'b']), 3)
        self.assertEqual(p('2', ['a', 'b']), 2)
        self.assertEqual(p('0', ['a']), 2)
        self.assertEqual(p('many', []), 1)

    def test_bridges_short(self):
        s = self.mod.bridges_short
        self.assertTrue(s(1, 2))
        self.assertFalse(s(2, 2))
        self.assertFalse(s(3, 2))
        self.assertFalse(s(0, 2))       # none at all is meet-bridge's error, not a warning
        self.assertFalse(s(None, 2))
        self.assertFalse(s(True, 2))

    def test_parse_role(self):
        self.assertEqual(self.mod.parse_role(None), 'main')
        self.assertEqual(self.mod.parse_role(' Main '), 'main')
        self.assertEqual(self.mod.parse_role('BRIDGE'), 'bridge')
        with self.assertRaises(SystemExit):
            self.mod.parse_role('shard')


class MainWithBridges(unittest.TestCase):
    def test_remote_bridge_checks_follow_the_original_six(self):
        mod = load(BRIDGES='10.1.0.50,10.1.0.51')
        self.assertEqual(list(mod.CHECKS), ORIGINAL_CHECKS + ['meet-jvb-10.1.0.50', 'meet-jvb-10.1.0.51'])
        self.assertEqual(mod.EXPECTED_BRIDGES, 3)
        calls, results = run_checks(mod)
        self.assertIn(('http', 'http://10.1.0.50:8080/about/health', None), calls)
        self.assertIn(('http', 'http://10.1.0.51:8080/about/health', None), calls)
        self.assertEqual(results['meet-bridge'], (True, '1 of 3 video bridges operational'))

    def test_turn_host_list(self):
        mod = load(TURN_HOST='turn1.talkchief.io,10.1.0.44,turn2.talkchief.io')
        self.assertEqual(list(mod.CHECKS), ORIGINAL_CHECKS + ['meet-turn-turn2.talkchief.io'])
        calls, _ = run_checks(mod)
        self.assertEqual([c for c in calls if c[0] == 'stun'], [('stun', 'turn1.talkchief.io'), ('stun', 'turn2.talkchief.io')])

    def test_no_public_turn_host_fails_meet_turn(self):
        mod = load(TURN_HOST='10.1.0.44')
        ok, detail = mod.CHECKS['meet-turn']()
        self.assertFalse(ok)
        self.assertIn('no public TURN host', detail)

    def test_warning_after_two_short_minutes_and_heartbeat_stays_ok(self):
        mod = load(BRIDGES='10.1.0.50')
        mod.CHECKS = {'meet-bridge': lambda: (mod.bridge_seen.update(operational=1), (True, 'x'))[1]}
        sleeps = itertools.count()

        def sleep(_):
            if next(sleeps) >= 1:
                raise StopLoop

        with mock.patch.object(mod.time, 'sleep', sleep), mock.patch.object(mod, 'meeting_problems', lambda: None), \
                mock.patch.object(mod, 'capture_checkin') as checkin, \
                mock.patch.object(mod, 'report_bridges_short') as short:
            with self.assertRaises(StopLoop):
                mod.health_loop()
        short.assert_called_once_with(1, 2, 2)
        self.assertEqual([c.kwargs['status'] for c in checkin.call_args_list], ['ok', 'ok'])


class BridgeRole(unittest.TestCase):
    def test_bridge_role(self):
        mod = load(MONITOR_ROLE='bridge', SENTRY_SERVER_NAME='meet-bridge-b1', BRIDGES='10.1.0.50')
        self.assertEqual(mod.ROLE, 'bridge')
        self.assertEqual(mod.SERVICES, {'jvb'})
        self.assertEqual(list(mod.CHECKS), ['meet-jvb'])
        self.assertEqual(mod.BRIDGES, [])                        # ignored on a bridge node
        self.assertEqual(mod._sentry.inits[0]['server_name'], 'meet-bridge-b1')
        calls, _ = run_checks(mod)
        self.assertEqual(calls, [('http', 'http://127.0.0.1:8080/about/health', None)])

    def test_default_server_name_uses_hostname(self):
        mod = load(MONITOR_ROLE='bridge')
        self.assertTrue(mod.SERVER_NAME.startswith('meet-bridge-'))

    def test_no_cron_checkin_and_no_jicofo_reads(self):
        mod = load(MONITOR_ROLE='bridge')
        mod.CHECKS = {'meet-jvb': lambda: (True, 'HTTP 200')}
        with mock.patch.object(mod.time, 'sleep', side_effect=StopLoop), \
                mock.patch.object(mod, 'capture_checkin') as checkin, \
                mock.patch.object(mod, 'meeting_problems') as problems:
            with self.assertRaises(StopLoop):
                mod.health_loop()
        checkin.assert_not_called()
        problems.assert_not_called()

    def test_main_role_still_checks_in(self):
        mod = load()
        mod.CHECKS = {'meet-jvb': lambda: (True, 'HTTP 200')}
        with mock.patch.object(mod.time, 'sleep', side_effect=StopLoop), \
                mock.patch.object(mod, 'capture_checkin') as checkin, \
                mock.patch.object(mod, 'meeting_problems') as problems:
            with self.assertRaises(StopLoop):
                mod.health_loop()
        checkin.assert_called_once()
        self.assertEqual(checkin.call_args.kwargs['monitor_slug'], 'meet-health')
        problems.assert_called_once()


if __name__ == '__main__':
    unittest.main()
