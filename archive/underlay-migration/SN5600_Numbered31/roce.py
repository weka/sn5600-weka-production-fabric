#!/usr/bin/env python3
"""Lossless RoCE delta for the existing SN5600 /31 fabric on Cumulus 5.11.5."""
import argparse
import copy
import datetime
import json
import os
import pathlib
import re
import subprocess
import sys
import time

import migrate as m


def enabled(value):
    return value is True or str(value).lower() in ('on', 'enabled', 'enable', 'yes')


def qos_guard(cfg):
    """Stop before overwriting existing custom QoS or native-800G AR."""
    qos = cfg.get('qos', {}) or {}
    if set(qos) - {'roce'}:
        raise ValueError('Custom QoS exists. Reconcile it before applying the standard RoCE profile.')
    roce = qos.get('roce', {}) or {}
    if set(roce) - {'enable', 'mode'}:
        raise ValueError('Custom RoCE options exist; preserve/reconcile these first.')
    if roce.get('mode', 'lossless') != 'lossless':
        raise ValueError('Existing lossy RoCE policy requires deliberate reconciliation.')
    if 'state' in roce:
        raise ValueError('Expected Cumulus 5.11 enable syntax, not state syntax.')
    ar = cfg.get('router', {}).get('adaptive-routing', {}) or {}
    if enabled(ar.get('enable')) or enabled(ar.get('state')) or ar.get('profile'):
        raise ValueError('Adaptive routing is configured; unsupported on this native-800G design.')
    for name, data in m.expand_map(cfg.get('interface', {})).items():
        if data.get('qos'):
            raise ValueError(name + ': existing per-interface QoS requires reconciliation.')
        ar = data.get('router', {}).get('adaptive-routing', {}) or {}
        if enabled(ar.get('enable')) or enabled(ar.get('state')):
            raise ValueError(name + ': adaptive routing is enabled.')
        if name.startswith('swp'):
            pause = data.get('link', {}).get('pause', {}) or {}
            if any(enabled(v) for v in pause.values()):
                raise ValueError(name + ': link pause conflicts with PFC.')
    return qos


def preflight(sw):
    raw, cfg = m.preflight(sw, need_addresses=True)
    peers = m.cfg_neighbors(cfg)
    if any(l['peer'] not in peers or l['port'] in peers for l in sw['links']):
        raise ValueError('Finish numbered /31 BGP migration on this switch before adding RoCE.')
    qos_guard(cfg)
    return raw, cfg


def base_dir(sw):
    return pathlib.Path.home() / 'sn5600-roce-state' / sw['name']


def established(sw):
    peers = m.live_peers()
    return [l['port'] for l in sw['links'] if m.good_peer(peers.get(l['peer'], {}), l, sw)]


def backup(sw, raw, cfg):
    base = base_dir(sw)
    base.mkdir(mode=0o700, parents=True, exist_ok=True)
    record = base / 'baseline.json'
    if record.exists():
        saved = json.loads(record.read_text())
        if saved.get('ip') != sw['ip'] or saved.get('schema') != 1:
            raise ValueError('Unexpected existing RoCE baseline: ' + str(record))
    else:
        saved = {'schema': 1, 'ip': sw['ip'], 'qos': copy.deepcopy(cfg.get('qos', {}) or {}),
                 'required_ports': established(sw)}
        (base / 'before.yaml').write_text(raw)
        record.write_text(json.dumps(saved, indent=2))
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    action_dir = base / stamp
    action_dir.mkdir(mode=0o700)
    (action_dir / 'before.yaml').write_text(raw)
    print('RoCE backup: ' + str(action_dir), flush=True)
    return action_dir


def fields(text):
    result = {}
    for line in text.splitlines():
        match = re.match(r'^\s*([a-z][a-z-]*)\s{2,}(\S+)', line)
        if match:
            result[match[1]] = match[2].lower().rstrip(',')
    return result


def status_errors(text):
    f = fields(text)
    errors = []
    if f.get('mode') != 'lossless':
        errors.append('lossless mode not confirmed')
    if f.get('congestion-mode') != 'ecn':
        errors.append('ECN not confirmed')
    if '3' not in f.get('enabled-tc', '').split(','):
        errors.append('ECN traffic class 3 not confirmed')
    if f.get('pfc-priority') != '3':
        errors.append('PFC priority 3 not confirmed')
    for direction in ('rx-enabled', 'tx-enabled'):
        if not enabled(f.get(direction)):
            errors.append('PFC ' + direction + ' not confirmed')
    if 'dscp' not in f.get('trust-mode', '').split(','):
        errors.append('DSCP trust not confirmed')
    return errors


def verify(sw):
    preflight(sw)
    errors = []
    base = base_dir(sw)
    base.mkdir(mode=0o700, parents=True, exist_ok=True)
    logfile = base / 'latest-validation.txt'
    output = m.run('nv', 'show', 'qos', 'roce')
    print(output, flush=True)
    errors.extend('global: ' + x for x in status_errors(output))
    logs = ['GLOBAL\n' + output]
    for link in sw['links']:
        port = link['port']
        output = m.run('nv', 'show', 'interface', port, 'qos', 'roce', 'status')
        logs.append(port + '\n' + output)
        local_errors = status_errors(output)
        errors.extend(port + ': ' + x for x in local_errors)
        print(port + ': ' + ('CHECK FAILED' if local_errors else 'lossless / PFC 3 RX+TX / ECN TC3 / DSCP trust confirmed'), flush=True)
    logfile.write_text('\n\n'.join(logs))
    record = base / 'baseline.json'
    if record.exists():
        missing = set(json.loads(record.read_text())['required_ports']) - set(established(sw))
        errors.extend(p + ': BGP session present before RoCE is missing' for p in sorted(missing))
    if m.validate(sw, 'all'):
        errors.append('Numbered fabric validation failed')
    print('Detailed QoS output: ' + str(logfile))
    if errors:
        print('CHECK FAILED (or unrecognized output; inspect the saved log):\n  ' + '\n  '.join(errors))
        return 1
    print('PASS: switch RoCE settings verified. Down-link warnings from fabric validation still apply.')
    print('Host NIC settings, RDMA traffic, congestion response and sustained losslessness are NOT validated.')
    return 0


def change(sw, rollback=False, apply=False):
    raw, cfg = preflight(sw)
    current = cfg.get('qos', {}) or {}
    if rollback:
        record = base_dir(sw) / 'baseline.json'
        if not record.exists():
            raise ValueError('No saved RoCE baseline; refusing to guess rollback state.')
        baseline = json.loads(record.read_text())
        if baseline.get('schema') != 1 or baseline.get('ip') != sw['ip']:
            raise ValueError('Wrong RoCE baseline identity')
        original = baseline['qos']
        qos_guard({'qos': original})
        commands = [['nv', 'unset', 'qos', 'roce']] if current.get('roce') is not None else []
        for key, val in (original.get('roce', {}) or {}).items():
            commands.append(['nv', 'set', 'qos', 'roce', key, str(m.onoff(val))])
        if current == original:
            print('RoCE already matches the saved baseline; no apply needed.')
            return 0
    else:
        commands = [['nv', 'set', 'qos', 'roce'], ['nv', 'set', 'qos', 'roce', 'mode', 'lossless']]
        # The BGP baseline must not be newly established while fabric is regressing.
        if m.validate(sw, 'all'):
            raise ValueError('Resolve fabric validation failure before adding RoCE.')
        if enabled(current.get('roce', {}).get('enable')) and current['roce'].get('mode', 'lossless') == 'lossless':
            print('Lossless RoCE is already configured; verifying without applying.')
            return verify(sw)
    action_dir = backup(sw, raw, cfg)
    (action_dir / 'commands.json').write_text(json.dumps(commands, indent=2))
    for command in commands:
        m.execute(command)
    diff = m.run('nv', 'config', 'diff')
    (action_dir / 'diff.yaml').write_text(diff)
    print(diff, flush=True)
    if not diff.strip():
        print('No configuration difference. Do not run a no-op apply; inspect nv config diff if a pending revision remains.')
        return 0
    if not apply:
        print('STAGED ONLY. Review nv config diff, then nv config apply && nv config save.')
        print('After applying, run this switch\'s roce-validate action. To abandon the candidate: nv config detach')
        return 0
    m.execute(['nv', 'config', 'apply', '--assume-yes'])
    m.execute(['nv', 'config', 'save'])
    (action_dir / 'after.yaml').write_text(m.run('nv', 'config', 'show'))
    if rollback:
        print('Restored the saved RoCE configuration. Other fabric configuration is retained.')
        return 0
    print('Waiting 15 seconds before checking switch RoCE and routing...', flush=True)
    time.sleep(15)
    return verify(sw)


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('switch', choices=sorted(m.PLAN['switches']))
    parser.add_argument('action', choices=['check', 'enable', 'validate', 'rollback'])
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    sw = m.PLAN['switches'][args.switch]
    if args.action == 'check':
        preflight(sw)
        print('Standard lossless RoCE delta is compatible with the applied configuration.')
        return m.validate(sw, 'all')
    if args.action == 'validate':
        return verify(sw)
    return change(sw, args.action == 'rollback', args.apply)


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ValueError, KeyError, TypeError, OSError, subprocess.CalledProcessError) as exc:
        print('STOP: ' + str(exc), file=sys.stderr)
        print('Inspect nv config diff before retrying. No automatic rollback was performed.', file=sys.stderr)
        sys.exit(1)
