#!/usr/bin/env python3
"""Generate review files only. Never connect to or modify switches."""
import json, ipaddress, re
from pathlib import Path
root=Path(__file__).resolve().parent
p=json.loads((root/'plan.json').read_text())
if not all(p['approvals'].values()) or not p['target_release'] or not re.fullmatch(r'[0-9a-fA-F]{64}',p['image_sha256'] or ''):
    raise SystemExit('STOP: complete release/checksum and all discovery/review approvals in plan.json')
if len(p['links']) != 32 or not all(x['verified_free'] and x['verified_cable'] for x in p['links']):
    raise SystemExit('STOP: all 32 proposed links must be verified')
ports=set();ips=set()
for x in p['links']:
    for dev,port in [('leaf-05',x['leaf_port']),(x['spine'],x['spine_port'])]:
        if not re.fullmatch(r'swp(?:[1-9]|[1-5][0-9]|6[0-4])',port) or (dev,port) in ports:
            raise SystemExit('STOP: duplicate/invalid interface')
        ports.add((dev,port))
    a=ipaddress.ip_interface(x['leaf_ip']); b=ipaddress.ip_interface(x['spine_ip'])
    if a.version!=4 or a.network.prefixlen!=31 or a.network!=b.network or a.ip==b.ip:
        raise SystemExit('STOP: invalid point-to-point pair')
    for addr in (str(a.ip),str(b.ip)):
        if addr in ips: raise SystemExit('STOP: duplicate address')
        ips.add(addr)
if p['proposed_asn']!=65105 or p['proposed_router_id']!='10.255.0.15':
    raise SystemExit('STOP: revised identity requires updating this reviewed generator')
out=root/'generated';out.mkdir(exist_ok=True)
commands={'leaf-05':['nv set system hostname leaf-05','nv set interface lo ip address 10.255.0.15/32','nv set router bgp enable on','nv set router bgp autonomous-system 65105','nv set router bgp router-id 10.255.0.15','nv set vrf default router bgp address-family ipv4-unicast network 10.255.0.15/32','nv set qos roce','nv set qos roce mode lossless']}
probes={}
for x in p['links']:
    for dev,port,addr,peer,asn in [('leaf-05',x['leaf_port'],x['leaf_ip'],x['spine_ip'].split('/')[0],65200),(x['spine'],x['spine_port'],x['spine_ip'],x['leaf_ip'].split('/')[0],65105)]:
        commands.setdefault(dev,[]).extend([f'nv set interface {port} link state up',f'nv set interface {port} link mtu 9216',f'nv set interface {port} ip address {addr}',f'nv set interface {port} ip ipv4 forward on',f'nv set vrf default router bgp neighbor {peer} type numbered',f'nv set vrf default router bgp neighbor {peer} remote-as {asn}',f'nv set vrf default router bgp neighbor {peer} enable on',f'nv set vrf default router bgp neighbor {peer} address-family ipv4-unicast enable on'])
        probes.setdefault(dev,[]).append(f'sudo ip vrf exec default ping -n -I {addr.split("/")[0]} -c 5 -W 2 -M do -s 8972 {peer}')
for dev,lines in commands.items():
    (out/f'{dev}-stage.sh').write_text('#!/usr/bin/env bash\nset -euo pipefail\n# Stages only; run after backing up and confirming a clean candidate.\n'+ '\n'.join(lines)+'\nnv config diff\n')
    (out/f'{dev}-peer-tests.sh').write_text('#!/usr/bin/env bash\nset -euo pipefail\n'+ '\n'.join(probes[dev])+'\necho "PASS: directly connected jumbo peers only; complete BGP and cross-fabric acceptance separately"\n')
(out/'plan-lock.json').write_text(json.dumps(p,indent=2)+'\n')
print(f'Generated review files: {out}. No equipment modified; no apply command executed.')
