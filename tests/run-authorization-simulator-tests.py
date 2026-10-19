#!/usr/bin/env python3
"""Run the offline fixture already installed by the sibling shell runner.

Calls the production AppDelegate URL entry point in-process; this deliberately
avoids the simulator's system confirmation for simctl openurl. The separate
web-completion case exercises ASWebAuthenticationSession's completion handler.
Native cases replace UIApplication handoff with synthetic open results and
callbacks, so Discord itself is never launched.
"""
import json
import os
import pathlib
import subprocess
import sys
import time

udid, output = sys.argv[1:]
output = pathlib.Path(output)
bundle = 'com.kainograze.iPresence.AuthorizationTests'

def sim(*args, **kwargs):
    return subprocess.run(['xcrun', 'simctl', *args], check=True, text=True,
                          capture_output=True, **kwargs)

container = pathlib.Path(sim('get_app_container', udid, bundle, 'data').stdout.strip())
doc = container / 'Documents'

def wait_result():
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        try:
            return json.loads((doc / 'AuthResult.json').read_text())
        except (json.JSONDecodeError, FileNotFoundError):
            time.sleep(.1)
    raise RuntimeError('Timed out waiting for authorization fixture')

results = []
scenarios = ['success', 'web-completion', 'server-error', 'denied', 'cancel',
             'timeout', 'browser-cancel', 'forged-state', 'duplicate',
             'exchange-cancel', 'exchange-timeout', 'retry', 'browser-explicit',
             'native-success', 'native-open-failure', 'native-cancel', 'native-timeout',
             'native-stale-open']
try:
    for scenario in scenarios:
        subprocess.run(['xcrun', 'simctl', 'terminate', udid, bundle], capture_output=True)
        for name in ['AuthFixture.json', 'AuthResult.json']:
            (doc / name).unlink(missing_ok=True)
        env = os.environ.copy()
        env['SIMCTL_CHILD_IP_AUTH_TEST_SCENARIO'] = scenario
        sim('launch', udid, bundle, env=env)
        result = wait_result()
        expected = scenario in ['success', 'web-completion', 'forged-state', 'duplicate', 'retry',
                                'browser-explicit', 'native-success', 'native-open-failure', 'native-stale-open']
        expected_requests = 2 if scenario == 'retry' else int(scenario in [
            'success', 'web-completion', 'forged-state', 'duplicate', 'server-error',
            'exchange-cancel', 'exchange-timeout', 'browser-explicit',
            'native-success', 'native-open-failure', 'native-stale-open'])
        assert result['success'] == expected and not result['busy'], result
        assert result['completions'] == (2 if scenario in ['retry', 'native-stale-open'] else 1), result
        assert result['storedSynthetic'] == expected, result
        assert result['signInEnabled'] and result['browserSignInEnabled'] and result['cancelHidden'] and not result['sharingEnabled'], result
        assert 'Finishing' not in result['statusText'] and 'Complete sign-in' not in result['statusText'], result
        assert result['tokenRequests'] == expected_requests, result
        assert result['requestValidated'], result
        assert result['nativeRequestValidated'] and result['browsersEphemeral'], result
        if scenario.startswith('native-'):
            expected_native = 2 if scenario == 'native-stale-open' else 1
            assert result['nativeOpens'] == expected_native and result['nativeAvailabilityChecks'] == expected_native, result
            assert result['webStarts'] == int(scenario == 'native-open-failure'), result
        elif scenario == 'browser-explicit':
            # Availability is recorded for diagnostics, but the user's explicit
            # browser choice must never open the Discord application.
            assert result['nativeOpens'] == 0 and result['nativeAvailabilityChecks'] == 1 and result['webStarts'] == 1, result
        else:
            assert result['nativeOpens'] == 0 and result['webStarts'] == (2 if scenario == 'retry' else 1), result
        if scenario in ['success', 'forged-state', 'duplicate', 'server-error', 'denied',
                        'exchange-cancel', 'exchange-timeout', 'retry', 'browser-explicit',
                        'native-success', 'native-open-failure', 'native-stale-open']:
            assert result['delegateAccepted'], result
        results.append(result)
        print(json.dumps(result), flush=True)
        if scenario in ['success', 'cancel', 'retry', 'native-success', 'native-stale-open']:
            sim('io', udid, 'screenshot', str(output / (scenario + '.png')))
    (output / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
finally:
    subprocess.run(['xcrun', 'simctl', 'terminate', udid, bundle], capture_output=True)
print(f'All {len(results)} offline simulator authorization scenarios passed.', flush=True)
