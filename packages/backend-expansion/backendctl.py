#!/usr/bin/env python3
"""Future backend rollout. Unresolved inventory is never deployable."""
from pathlib import Path
import argparse,datetime,ipaddress,json,re,subprocess,sys
ROOT=Path(__file__).resolve().parent
LEAVES={'leaf-01':('172.31.17.19',1),'leaf-02':('172.31.17.21',2),'leaf-03':('172.31.17.23',4),'leaf-04':('172.31.17.24',5)}
p=argparse.ArgumentParser();p.add_argument('action',choices=['status','scan','generate','server-check','server-stage','server-apply','server-validate','switch-check','switch-stage','switch-apply','switch-validate','roce-stage','roce-apply','roce-validate','test']);p.add_argument('target',nargs='?');a=p.parse_args()
plan=json.loads((ROOT/'plan.json').read_text())
def run(args,**kwargs):return subprocess.run(args,check=True,**kwargs)
def ssh(ip,cmd,user='root'):run(['ssh','-tt','-o','ConnectTimeout=12',user+'@'+ip,cmd])
def validate(h):
 assert h['approved'] and all(h[k] for k in ['verified_cabling','verified_address_reservation','verified_netplan_review']), 'approval/cabling/IP/Netplan review incomplete'
 assert re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9.-]*',h['hostname'] or ''),'hostname missing/invalid'
 for k,prefix in [('management_ip','172.31.18.'),('bmc_ip','172.31.16.')]:
  assert str(ipaddress.IPv4Address(h[k])).startswith(prefix), k+' missing/out of range'
 assert h['leaf'] in LEAVES and h['rack']==LEAVES[h['leaf']][1],'leaf/rack mismatch'
 assert h['chassis'] and h['chassis_slot'] in [1,2,3,4],'chassis/slot missing'
 for x in h['interfaces']:
  assert re.fullmatch(r'[A-Za-z0-9_.-]+',x['name'] or ''),'netdev missing/invalid'
  assert re.fullmatch(r'(?:[0-9a-f]{2}:){5}[0-9a-f]{2}',x['mac'] or ''),'MAC missing/invalid; lowercase required'
  m=re.fullmatch(r'swp(\d+)s([01])',x['leaf_port'] or '')
  assert m and 13<=int(m[1])<=32,'only swp13-32, 2x400G children allowed in this draft'
  addr=ipaddress.ip_interface(x['server_ip']);peer=ipaddress.ip_address(x['peer'])
  assert addr.network.prefixlen==31 and peer in addr.network and peer!=addr.ip,'invalid /31 pair'
  assert str(addr.ip).startswith('10.200.'),'datapath must remain inside routed 10.200/16'
 assert len({x['name'] for x in h['interfaces']})==2 and len({x['mac'] for x in h['interfaces']})==2,'duplicate interfaces'
def global_check():
 ips=set();ports=set();slots=set();counts={1:0,2:0,4:0,5:0}
 for h in plan['hosts']:
  if not h['approved']:continue
  validate(h);counts[h['rack']]+=1
  slot=(h['chassis'],h['chassis_slot']);assert slot not in slots,'duplicate chassis slot';slots.add(slot)
  for ip in [h['management_ip'],h['bmc_ip']]+[str(ipaddress.ip_interface(x['server_ip']).ip) for x in h['interfaces']]+[x['peer'] for x in h['interfaces']]:assert ip not in ips,'duplicate IP';ips.add(ip)
  for x in h['interfaces']:
   port=(h['leaf'],x['leaf_port']);assert port not in ports,'duplicate leaf port';ports.add(port)
 for rack,count in counts.items():assert count<=plan['rack_capacity'][str(rack)],'rack capacity exceeded'
if a.action=='status':
 print(f"Draft: {len(plan['hosts'])} planned, {sum(h['approved'] for h in plan['hosts'])} operator-approved. 60 supplied management IPs; 16 unknown. No production readiness inferred.");sys.exit()
if a.action=='scan':
 stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ');dest=ROOT/'discovery'/stamp;dest.mkdir(parents=True)
 known=json.loads((ROOT/'known-management.json').read_text())
 for ch in known['chassis']:
  for h in ch['hosts']:
   ip=h['management_ip'];print('READ-ONLY '+ip,flush=True)
   cmd='hostname; ip -br link; ip -4 -o address; rdma link show; ibdev2netdev; lspci -Dnn; for I in /sys/class/net/*; do [ -e "$I/device" ] || continue; echo "NETDEV $(basename "$I")"; cat "$I/address" "$I/mtu" "$I/operstate"; done'
   result=subprocess.run(['ssh','-o','ConnectTimeout=10','root@'+ip,cmd],capture_output=True,text=True)
   text=result.stdout+'\nSSH_EXIT='+str(result.returncode)+'\n'+result.stderr
   text='\n'.join('[REDACTED]' if re.search('password|secret|token|private.key',line,re.I) else line for line in text.splitlines())
   (dest/(ip+'.txt')).write_text(text+'\n')
 print('Discovery retained; populate plan from physical confirmation. No configuration changes.');sys.exit()
try:global_check()
except (AssertionError,TypeError,ValueError) as e:raise SystemExit('STOP: '+str(e))
h=next((h for h in plan['hosts'] if h['id']==a.target),None)
if a.action.startswith('switch-'):
 assert a.target in LEAVES,'select leaf-01 through leaf-04'
 selected=[h for h in plan['hosts'] if h['approved'] and h['leaf']==a.target];assert selected,'no approved hosts for leaf'
 expected=json.dumps(selected,sort_keys=True)
 assert (ROOT/'generated'/a.target/'plan-lock.json').read_text()==expected,'plan changed: regenerate before switch operations'
 ip=LEAVES[a.target][0];f=ROOT/'generated'/a.target/'switch.sh';assert f.exists(),'generate approved hosts first'
 run(['scp',str(f),'cumulus@'+ip+':/home/cumulus/backend-expansion.sh']);ssh(ip,'bash /home/cumulus/backend-expansion.sh --'+a.action.split('-',1)[1],'cumulus');sys.exit()
assert h,'select a backend ID such as BE001';validate(h)
if a.action=='generate':
 out=ROOT/'generated'/h['id'];out.mkdir(parents=True,exist_ok=True)
 s=(ROOT/'templates/server-reference.sh').read_text();x,y=h['interfaces']
 replacements={'weka60':h['hostname'],'172.31.18.60':h['management_ip'],'ens4047np0':x['name'],'ens3919np0':y['name'],'d8:94:24:1d:d5:2c':x['mac'],'e0:9d:73:1d:d8:34':y['mac'],'10.200.60.0':x['peer'],'10.200.60.2':y['peer'],'10.200.60.1':str(ipaddress.ip_interface(x['server_ip']).ip),'10.200.60.3':str(ipaddress.ip_interface(y['server_ip']).ip)}
 for old,new in replacements.items():s=s.replace(old,new)
 s=s.replace('TEMPLATE_ONLY_GUARD','true')
 (out/'server.sh').write_text(s);(out/'plan.json').write_text(json.dumps(h,indent=2)+'\n')
 selected=[z for z in plan['hosts'] if z['approved'] and z['leaf']==h['leaf']]
 lines=[];checks=[]
 for z in selected:
  for l in z['interfaces']:
   lines += [f'nv set interface {l["leaf_port"]} ip address {l["peer"]}/31',f'nv set interface {l["leaf_port"]} ip ipv4 forward on',f'nv set vrf default router bgp address-family ipv4-unicast network {ipaddress.ip_interface(l["server_ip"]).network}']
   checks += [f'test "$(cat /sys/class/net/{l["leaf_port"]}/speed)" = 400000',f'test "$(cat /sys/class/net/{l["leaf_port"]}/mtu)" = 9216',f'test ! -L /sys/class/net/{l["leaf_port"]}/master']
 validations=[]
 for z in selected:
  for l in z['interfaces']:
   validations += [f'ip -4 -o address show dev {l["leaf_port"]} | grep -F "{l["peer"]}/31"',f'sudo ip vrf exec default ping -n -I {l["peer"]} -c 3 -W 2 -M do -s 8972 {ipaddress.ip_interface(l["server_ip"]).ip}']
 script=(ROOT/'templates/switch.sh').read_text().replace('@VALIDATE@','\n'.join(validations)).replace('@CHECKS@','\n'.join(checks)).replace('@COMMANDS@','\n'.join(lines))
 folder=ROOT/'generated'/h['leaf'];folder.mkdir(exist_ok=True);(folder/'switch.sh').write_text(script);(folder/'plan-lock.json').write_text(json.dumps(selected,sort_keys=True))
 print('Generated candidate scripts. Re-generate after any plan edit; no device changes.');sys.exit()
if a.action.startswith('server-'):
 f=ROOT/'generated'/h['id']/'server.sh';assert f.exists(),'generate first'
 assert json.loads((f.parent/'plan.json').read_text())==h,'plan changed: re-generate first'
 run(['scp',str(f),'root@'+h['management_ip']+':/root/backend31.sh']);ssh(h['management_ip'],'bash /root/backend31.sh --'+a.action.split('-',1)[1]);sys.exit()
if a.action.startswith('roce-'):
 ip=h['management_ip'];nics=','.join(x['name'] for x in h['interfaces'])
 if a.action=='roce-stage':
  source=ROOT.parents[1]/'packages/host-roce-reference/scripts'
  run(['scp',str(source/'weka-roce-precheck.sh'),str(source/'deploy-weka-roce.sh'),'root@'+ip+':/root/'])
  ssh(ip,'chmod u+x /root/weka-roce-precheck.sh /root/deploy-weka-roce.sh; /root/weka-roce-precheck.sh --role backend --nics '+nics+' --expected-tos 96')
 elif a.action=='roce-apply':ssh(ip,'/root/deploy-weka-roce.sh --role backend --nics '+nics+' --tos 96')
 else:ssh(ip,'/root/weka-roce-precheck.sh --role backend --nics '+nics+' --expected-tos 96')
 sys.exit()
if a.action=='test':
 for x in h['interfaces']:ssh(h['management_ip'],f'ping -n -I {ipaddress.ip_interface(x["server_ip"]).ip} -c 5 -W 2 -M do -s 8972 {x["peer"]}')
 print('Local peer jumbo tests only. Cross-leaf RDMA, reboot and WEKA I/O remain separate acceptance tests.')
