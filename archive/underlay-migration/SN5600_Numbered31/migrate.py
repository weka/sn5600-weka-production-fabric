#!/usr/bin/env python3
"""NVUE migration for the existing eight-switch SN5600 fabric. No remote access."""
import argparse, copy, datetime, ipaddress, json, os, pathlib, re, shlex, subprocess, sys
import yaml

ROOT = pathlib.Path(__file__).resolve().parent
PLAN = json.loads((ROOT / 'plan.json').read_text())

def run(*args):
    return subprocess.check_output(args, text=True)

def execute(args):
    print('+ ' + shlex.join(args), flush=True)
    subprocess.run(args, check=True)

def merge(a, b):
    for k, v in b.items():
        if isinstance(v, dict) and isinstance(a.get(k), dict):
            merge(a[k], v)
        else:
            a[k] = copy.deepcopy(v)

def parse_config(raw):
    result = {}
    for doc in yaml.safe_load_all(raw):
        for item in doc if isinstance(doc, list) else [doc]:
            if isinstance(item, dict) and isinstance(item.get('set'), dict):
                merge(result, item['set'])
    if not result:
        raise ValueError('Cannot parse applied NVUE configuration')
    return result

def expand_map(items):
    out = {}
    for selector, attrs in items.items():
        if not str(selector).startswith('swp'):
            merge(out.setdefault(str(selector), {}), attrs or {})
            continue
        for token in str(selector).split(','):
            m = re.fullmatch(r'(?:swp)?(\d+)(?:-(?:swp)?(\d+))?', token)
            if not m:
                merge(out.setdefault(token, {}), attrs or {})
                continue
            for n in range(int(m[1]), int(m[2] or m[1]) + 1):
                merge(out.setdefault('swp' + str(n), {}), attrs or {})
    return out

def cfg_neighbors(cfg):
    return expand_map(cfg.get('vrf', {}).get('default', {}).get('router', {}).get('bgp', {}).get('neighbor', {}))

def live_peers():
    result = json.loads(run('sudo', 'vtysh', '-c', 'show bgp neighbors json'))
    if not isinstance(result, dict):
        raise ValueError('Unrecognized FRR neighbor JSON')
    return result

def good_peer(p, link, sw):
    return (p.get('bgpState') == 'Established' and str(p.get('remoteAs')) == str(link['remote_as'])
            and str(p.get('localAs')) == str(sw['asn']) and p.get('remoteRouterId') == link['remote_rid'])

def identity(sw):
    ver = dict(x.strip().split('=', 1) for x in pathlib.Path('/etc/os-release').read_text().splitlines() if '=' in x)
    if ver.get('VERSION_ID', '').strip('"') != '5.11.5' or ver.get('ID', '').strip('"') != 'cumulus-linux':
        raise ValueError('Requires Cumulus Linux 5.11.5')
    if run('hostname').strip() != sw['name']:
        raise ValueError('Wrong hostname; expected ' + sw['name'])
    if not re.search(r'^platform\s+x86_64-nvidia_sn5600-r0(?:\s|$)', run('nv', 'show', 'system'), re.M):
        raise ValueError('Requires physical SN5600')
    live = json.loads(run('ip', '-j', 'address', 'show'))
    mgmt = {a['local'] + '/' + str(a['prefixlen']) for i in live if i['ifname'] == 'eth0'
            for a in i.get('addr_info', []) if a['family'] == 'inet'}
    if mgmt != {sw['ip'] + '/' + str(sw['prefix'])}:
        raise ValueError('Wrong management address: ' + str(mgmt))
    return live

def preflight(sw, need_addresses=False):
    live = identity(sw)
    if run('nv', 'config', 'diff').strip():
        raise ValueError('Pending NVUE changes exist. Review/apply them or use nv config detach before retrying.')
    raw = run('nv', 'config', 'show')
    cfg = parse_config(raw)
    intfs = expand_map(cfg.get('interface', {}))
    peers = cfg_neighbors(cfg)
    global_bgp = cfg.get('router', {}).get('bgp', {})
    bgp = cfg.get('vrf', {}).get('default', {}).get('router', {}).get('bgp', {})
    if str(global_bgp.get('autonomous-system')) != str(sw['asn']) or global_bgp.get('router-id') != sw['rid']:
        raise ValueError('Applied BGP ASN/router ID differs from the address plan')
    af = bgp.get('address-family', {})
    v4 = af.get('ipv4-unicast', {})
    if set(af) - {'ipv4-unicast'} or set(v4) - {'enable', 'network', 'multipaths'}:
        raise ValueError('Additional BGP address families, redistribution or policies require reconciliation')
    if set(v4.get('network', {})) != {sw['rid'] + '/32'}:
        raise ValueError('Expected only the existing loopback BGP network')
    if str(v4.get('multipaths', {}).get('ebgp')) != '64':
        raise ValueError('Expected the existing 64-path eBGP configuration')
    if set(bgp) - {'enable', 'neighbor', 'address-family'}:
        raise ValueError('Additional VRF BGP policy/options require reconciliation')
    settings = cfg.get('system', {}).get('config', {})
    if settings.get('snippet') or settings.get('apply', {}).get('ignore') or settings.get('apply', {}).get('snippet'):
        raise ValueError('NVUE snippets/file ignores require reconciliation')
    byname = {x['ifname'].split('@')[0]: x for x in live}
    expected = {l['port']: l for l in sw['links']}
    pool = ipaddress.ip_network(PLAN['pool'])
    allowed_nets = {str(ipaddress.ip_interface(l['address']).network) for l in sw['links']}
    for name, obj in byname.items():
        for a in obj.get('addr_info', []):
            if a['family'] != 'inet':
                continue
            cidr = a['local'] + '/' + str(a['prefixlen'])
            if ipaddress.ip_interface(cidr).network.overlaps(pool) and not (name in expected and cidr == expected[name]['address']):
                raise ValueError('Existing address overlaps 10.254.0.0/24: ' + name + ' ' + cidr)
    for route in json.loads(run('ip', '-j', '-4', 'route', 'show', 'table', 'main')):
        dst = route.get('dst', 'default')
        if dst == 'default':
            continue
        if ipaddress.ip_network(dst, strict=False).overlaps(pool):
            if not (dst in allowed_nets and route.get('protocol') == 'kernel' and route.get('dev') in expected):
                raise ValueError('Existing main-table route overlaps the /31 pool: ' + dst)
    for l in sw['links']:
        port, addr = l['port'], l['address']
        obj, applied = byname.get(port, {}), intfs.get(port, {})
        if not obj or obj.get('master') or obj.get('mtu') != 9216:
            raise ValueError(port + ': expected native routed interface with MTU 9216')
        if any(re.fullmatch(re.escape(port) + r'(?:s\d+|\.\d+)', x) for x in set(byname) | set(intfs)):
            raise ValueError(port + ': breakout/subinterface conflict')
        ip = applied.get('ip', {})
        if applied.get('bridge') or applied.get('bond') or applied.get('acl') or ip.get('vrf') not in (None, 'default'):
            raise ValueError(port + ': bridge/bond/ACL/VRF needs reconciliation')
        addresses = set(ip.get('address', {}))
        if addresses - {addr}:
            raise ValueError(port + ': unexpected applied address ' + str(addresses))
        live_v4 = {a['local'] + '/' + str(a['prefixlen']) for a in obj.get('addr_info', []) if a['family'] == 'inet'}
        if need_addresses and (addresses != {addr} or live_v4 != {addr}):
            raise ValueError(port + ': apply the addresses stage on all eight switches first')
        if port not in peers and l['peer'] not in peers:
            raise ValueError(port + ': neither old nor planned BGP neighbor exists')
        if port in peers and l['peer'] in peers:
            raise ValueError(port + ': both numbered and unnumbered neighbors exist; reconcile first')
        for key, kind in [(port, 'unnumbered'), (l['peer'], 'numbered')]:
            p = peers.get(key)
            if p is None:
                continue
            if set(p) - {'type', 'remote-as', 'enable', 'address-family'}:
                raise ValueError(key + ': neighbor policy/options would need preservation')
            if p.get('type', kind) != kind or str(p.get('remote-as')) not in (str(l['remote_as']), 'external'):
                raise ValueError(key + ': unexpected peer type or ASN')
            paf = p.get('address-family', {})
            if set(paf) - {'ipv4-unicast'} or set(paf.get('ipv4-unicast', {})) - {'enable'}:
                raise ValueError(key + ': address-family policy requires reconciliation')
    print('Preflight passed: ' + sw['name'] + ' ' + sw['ip'], flush=True)
    return raw, cfg

def state_dir(sw):
    return pathlib.Path.home() / 'sn5600-numbered31-state' / sw['name']

def backup(sw, raw, cfg):
    base = state_dir(sw)
    base.mkdir(parents=True, exist_ok=True, mode=0o700)
    record = base / 'baseline.json'
    if record.exists():
        old = json.loads(record.read_text())
        if old['release'] != PLAN['release'] or old['ip'] != sw['ip']:
            raise ValueError('A different migration baseline exists at ' + str(base))
    else:
        peers = cfg_neighbors(cfg)
        if any(l['port'] not in peers or l['peer'] in peers for l in sw['links']):
            raise ValueError('A first backup requires all original unnumbered peers. Do not replace a lost baseline.')
        live = live_peers()
        data = {'release':PLAN['release'], 'ip':sw['ip'], 'time_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),
                'neighbors':{l['port']:peers[l['port']] for l in sw['links']},
                'established_ports':[l['port'] for l in sw['links'] if good_peer(live.get(l['port'], {}), l, sw)],
                'original_addresses':{l['port']:list(expand_map(cfg.get('interface', {})).get(l['port'], {}).get('ip', {}).get('address', {})) for l in sw['links']}}
        (base / 'before.yaml').write_text(raw)
        (base / 'before-bgp.json').write_text(json.dumps(live, indent=2))
        (base / 'before-frr.txt').write_text(run('sudo', 'vtysh', '-c', 'show running-config'))
        record.write_text(json.dumps(data, indent=2))
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    actiondir = base / stamp
    actiondir.mkdir(mode=0o700)
    (actiondir / 'before.yaml').write_text(raw)
    print('Backup: ' + str(actiondir), flush=True)
    return actiondir

def select_links(sw, group):
    return [l for l in sw['links'] if group == 'all' or l['group'] == group]

def probe(sw, group):
    preflight(sw, need_addresses=True)
    baseline = json.loads((state_dir(sw)/'baseline.json').read_text())
    live = {i['ifname']:i for i in json.loads(run('ip','-j','address','show'))}
    failed = []
    for l in select_links(sw, group):
        if live[l['port']].get('operstate') != 'UP':
            print('DOWN: ' + l['port'] + ' -> ' + l['peer'])
            if l['port'] in baseline['established_ports']:
                failed.append(l['port'] + ': previously established link is down')
            continue
        r = subprocess.run(['sudo','ip','vrf','exec','default','ping','-n','-I',l['port'],'-c','2','-W','2','-M','do','-s','8972',l['peer']], text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
        ok = r.returncode == 0 and bool(re.search(r'\b0% packet loss',r.stdout))
        print(('PASS ' if ok else 'FAIL ') + l['port'] + ' /31 peer ' + l['peer'])
        if not ok:
            failed.append(l['port'] + ': direct /31 peer probe failed')
    if failed:
        raise ValueError('; '.join(failed))
    print('Direct /31 probes passed on active links; down links remain listed above.')
    return 0

def onoff(obj):
    if isinstance(obj, bool):
        return 'on' if obj else 'off'
    if isinstance(obj, dict):
        return {k:onoff(v) for k,v in obj.items()}
    if isinstance(obj, list):
        return [onoff(v) for v in obj]
    return obj

def validate(sw, group, numbered=True):
    identity(sw)
    links = select_links(sw, group)
    peers = live_peers()
    rows = {p[0]:p[1:5] for p in (line.split() for line in run('nv','show','interface').splitlines()) if p and p[0].startswith('swp')}
    baseline_file = state_dir(sw) / 'baseline.json'
    if not baseline_file.exists():
        raise ValueError('No migration baseline. Run the addresses stage first.')
    baseline = json.loads(baseline_file.read_text())
    missing, regression, found = [], [], []
    for l in links:
        key = l['peer'] if numbered else l['port']
        p = peers.get(key, {})
        if good_peer(p, l, sw):
            found.append(l)
            if rows.get(l['port']) != ['up','up','800G','9216']:
                regression.append(l['port'] + ': established but not up/800G/MTU9216')
        else:
            missing.append(l['port'] + ' -> ' + l['remote_name'] + ' ' + l['remote_port'] + ' (' + key + ')')
            if l['port'] in baseline['established_ports']:
                regression.append(l['port'] + ': previously established session is now missing')
    for remote in sorted({l['remote_name'] for l in links}):
        n = sum(l['remote_name'] == remote for l in found)
        print(remote + ': ' + str(n) + '/8 established')
        if n == 0:
            regression.append(remote + ': no established session in this group')
    destinations = {l['remote_rid'] for l in links}
    if group == 'all' and sw['role'] == 'leaf':
        destinations |= {s['rid'] for s in PLAN['switches'].values() if s['role']=='leaf' and s['name']!=sw['name']}
    for dst in sorted(destinations, key=ipaddress.ip_address):
        p = subprocess.run(['sudo','ip','vrf','exec','default','ping','-n','-I',sw['rid'],'-c','3','-W','2','-M','do','-s','8972',dst], text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
        ok = p.returncode == 0 and bool(re.search(r'\b0% packet loss',p.stdout))
        print(('PASS ' if ok else 'FAIL ') + '9000-byte IPv4 loopback probe to ' + dst)
        if not ok:
            regression.append('Loopback probe failed: ' + dst)
    if missing:
        print('DEGRADED: ' + str(len(missing)) + ' selected pairs lack an established session:\n  ' + '\n  '.join(missing))
    if regression:
        print('STOP: validation failed:\n  ' + '\n  '.join(regression))
        return 1
    print(('DEGRADED, no additional BGP losses versus saved baseline.' if missing else 'PASS: all selected sessions established at 800G; probes passed.'))
    print('This does not replace FEC/error-counter, ASIC ECMP or sustained traffic checks.')
    return 0

def main():
    os.umask(0o077)
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('switch', choices=sorted(PLAN['switches']))
    p.add_argument('action', choices=['check','addresses','probe','bgp','rollback-bgp','remove-addresses','validate','validate-unnumbered'])
    p.add_argument('group', nargs='?', default='all', choices=['all','spine-01','spine-02','spine-03','spine-04'])
    p.add_argument('--apply', action='store_true', help='stage, show diff, apply and save; otherwise only stage')
    args = p.parse_args()
    sw = PLAN['switches'][args.switch]
    links = select_links(sw, args.group)
    if not links:
        raise ValueError('This switch has no links in that spine group')
    if args.action == 'probe':
        return probe(sw, args.group)
    if args.action.startswith('validate'):
        return validate(sw, args.group, args.action == 'validate')
    if args.action in ('bgp','rollback-bgp') and args.group == 'all':
        raise ValueError('Specify one spine group; migrate/rollback one spine at a time')
    raw, cfg = preflight(sw, need_addresses=args.action=='bgp')
    if args.action == 'check':
        return 0
    execute(['sudo','-v'])
    actiondir = backup(sw, raw, cfg)
    neighbors = cfg_neighbors(cfg)
    patch = None
    commands = []
    if args.action == 'addresses':
        commands = [['nv','set','interface',l['port'],'ip','address',l['address']] for l in sw['links']]
    elif args.action == 'bgp':
        for l in links:
            if l['port'] in neighbors:
                commands.append(['nv','unset','vrf','default','router','bgp','neighbor',l['port']])
            prefix = ['nv','set','vrf','default','router','bgp','neighbor',l['peer']]
            commands += [prefix+['type','numbered'],prefix+['remote-as',str(l['remote_as'])],prefix+['enable','on'],prefix+['address-family','ipv4-unicast','enable','on']]
    elif args.action == 'rollback-bgp':
        baseline = json.loads((state_dir(sw)/'baseline.json').read_text())
        for l in links:
            if l['peer'] in neighbors:
                commands.append(['nv','unset','vrf','default','router','bgp','neighbor',l['peer']])
        patch = [{'set':{'vrf':{'default':{'router':{'bgp':{'neighbor':{l['port']:baseline['neighbors'][l['port']] for l in links}}}}}}}]
    elif args.action == 'remove-addresses':
        if any(l['peer'] in neighbors or l['port'] not in neighbors for l in sw['links']):
            raise ValueError('Restore every original unnumbered BGP neighbor before removing /31 addresses')
        baseline = json.loads((state_dir(sw)/'baseline.json').read_text())
        for l in sw['links']:
            if l['address'] not in baseline['original_addresses'][l['port']]:
                commands.append(['nv','unset','interface',l['port'],'ip','address',l['address']])
    (actiondir/'commands.txt').write_text('\n'.join(shlex.join(c) for c in commands)+'\n')
    for c in commands:
        execute(c)
    if patch is not None:
        path=actiondir/'rollback.patch.yaml'
        path.write_text(yaml.safe_dump(onoff(patch),sort_keys=False))
        execute(['nv','config','patch',str(path)])
    diff=run('nv','config','diff')
    (actiondir/'diff.yaml').write_text(diff)
    print(diff, flush=True)
    if not args.apply:
        print('STAGED ONLY. Review above, then: nv config apply && nv config save')
        print('To abandon the pending candidate: nv config detach')
        return 0
    execute(['nv','config','apply','--assume-yes'])
    execute(['nv','config','save'])
    (actiondir/'after.yaml').write_text(run('nv','config','show'))
    print('Applied. Complete this stage at the other endpoints, then validate.')
    return 0

if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ValueError, KeyError, TypeError, OSError, subprocess.CalledProcessError) as exc:
        print('STOP: ' + str(exc), file=sys.stderr)
        print('If commands were staged or apply failed, inspect nv config diff before any retry. No automatic rollback was performed.', file=sys.stderr)
        sys.exit(1)
