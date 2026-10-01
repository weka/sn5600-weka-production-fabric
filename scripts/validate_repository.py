#!/usr/bin/env python3
"""Offline validation only: never connect to a switch or server."""
from pathlib import Path
import ast,csv,hashlib,ipaddress,json,re,subprocess,sys,zipfile
ROOT=Path(__file__).resolve().parents[1]
errors=[]; counts={'shell':0,'python':0,'client_links':0,'underlay_endpoints':0}
def bad(message):errors.append(message)
def files():
    for p in ROOT.rglob('*'):
        if p.is_file() and not any(x in {'.git','__pycache__','reports','local-private'} for x in p.relative_to(ROOT).parts):yield p

# Avoid storing a credential literal in this scanner itself.
for p in files():
    rel=p.relative_to(ROOT)
    if p.suffix=='.sh':
        r=subprocess.run(['bash','-n',str(p)],capture_output=True,text=True)
        if r.returncode:bad(f'Shell syntax {rel}: {r.stderr.strip()}')
        counts['shell']+=1
    if p.suffix=='.py':
        try:ast.parse(p.read_text())
        except (SyntaxError,UnicodeError) as exc:bad(f'Python syntax {rel}: {exc}')
        counts['python']+=1
    payload=p.read_bytes()
    if p.suffix=='.docx':
        with zipfile.ZipFile(p) as z:payload=b'\n'.join(z.read(n) for n in z.namelist() if n.endswith('.xml'))
    if b'Weka'+b'Service' in payload:bad(f'Known password found: {rel}')
    if re.search(rb'-----BEGIN (?:OPENSSH |RSA |EC )?PRIVATE KEY-----',payload):bad(f'Private key found: {rel}')
    if re.search(rb'\bgh[pousr]_[A-Za-z0-9]{30,}',payload):bad(f'GitHub token found: {rel}')
    if p.suffix=='.md':
        text=p.read_text()
        for target in re.findall(r'\]\(([^\s)]+)\)',text):
            if target.startswith(('http:','https:','#','mailto:')):continue
            target=target.split('#')[0]
            if target and not (p.parent/target).exists():bad(f'Broken Markdown link: {rel} -> {target}')

mapping=json.loads((ROOT/'inventory/client-port-map.json').read_text())
racks={'leaf-01':'Rack 1','leaf-02':'Rack 2','leaf-03':'Rack 4','leaf-04':'Rack 5'}
assert len(mapping['hosts'])==40
used_ips=set();used_ports=set()
for h in mapping['hosts']:
    if h['status']!='Ready':continue
    assert len(h['links'])==2,(h['name'],'expected two mapped links')
    for link in h['links']:
        a=ipaddress.ip_interface(link['leafIp']);b=ipaddress.ip_interface(link['serverIp'])
        assert a.network==b.network and a.network.prefixlen==31 and a.ip!=b.ip,(h['name'],link)
        assert str(a.ip)==link['peer']
        port=(h['leaf'],link['port']);assert port not in used_ports;used_ports.add(port)
        for ip in (a.ip,b.ip):assert ip not in used_ips;used_ips.add(ip)
        counts['client_links']+=1
assert counts['client_links']==70
for row in mapping['rows']:assert row['rack']==racks[row['leaf']]
plan=json.loads((ROOT/'inventory/underlay-plan.json').read_text())
endpoints={}
for name,s in plan['switches'].items():
    for l in s['links']:endpoints[name,l['port']]=l;counts['underlay_endpoints']+=1
assert counts['underlay_endpoints']==256
for (name,port),l in endpoints.items():
    peer=endpoints[l['remote_name'],l['remote_port']]
    a=ipaddress.ip_interface(l['address']);b=ipaddress.ip_interface(peer['address'])
    assert a.network==b.network and a.network.prefixlen==31 and a.ip!=b.ip
    assert str(b.ip)==l['peer'] and peer['remote_name']==name and peer['remote_port']==port
status=list(csv.DictReader((ROOT/'inventory/client-status.csv').open()))
assert len(status)==40
assert sum(r['reboot_validation'].startswith('passed') for r in status)==30
assert sum(r['roce']!='deferred' for r in status)==34
summary=list(csv.DictReader((ROOT/'evidence/cross-leaf-summary-2026-09-30.tsv').open(),delimiter='\t'))
assert len(summary)==5
for r in summary:assert abs(float(r['MLX5_0_Gbps'])+float(r['MLX5_1_Gbps'])-float(r['COMBINED_Gbps']))<.011
missing=[n for n in ['weka-roce-precheck.sh','deploy-weka-roce.sh'] if not (ROOT/'packages/host-roce-reference/scripts'/n).exists()]
if missing:print('DOCUMENTED GAP: exact host reference payloads not yet collected:',', '.join(missing))
if errors:
    print('\n'.join(errors));sys.exit(1)
print('OFFLINE VALIDATION PASSED:',counts)
print('This does not validate live equipment, performance or missing runtime evidence.')
