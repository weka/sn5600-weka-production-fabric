#!/usr/bin/env python3
"""Read-only client capture, sanitized before saving. Unreachable hosts are recorded."""
from pathlib import Path
import argparse,datetime,json,os,re,subprocess,sys
p=argparse.ArgumentParser();p.add_argument('--hosts',default=' '.join(map(str,range(40,80))));a=p.parse_args()
root=Path(__file__).resolve().parents[1]
stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
dest=root/'configs/servers'/stamp;dest.mkdir(parents=True)
remote=r'''
from pathlib import Path
import subprocess,json,datetime,socket
r={'hostname':socket.gethostname(),'collected_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'commands':{},'files':{}}
commands=['uname -a','cat /etc/os-release','cat /proc/sys/kernel/random/boot_id','uptime','ip -br link','ip -4 -o address','ip -4 rule show','ip -4 route show table all','rdma link show','ibdev2netdev','lspci -Dnn','systemctl is-enabled weka-roce.service','systemctl is-active weka-roce.service weka-agent.service','systemctl cat weka-roce.service weka-agent.service','systemctl --failed --no-pager','sysctl net.ipv4.tcp_ecn','networkctl list --no-pager','journalctl -b -u weka-roce.service -u systemd-networkd-wait-online.service --no-pager -n 150']
for cmd in commands:
 try:
  o=subprocess.run(cmd,shell=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=30);r['commands'][cmd]={'exit':o.returncode,'output':o.stdout}
 except subprocess.TimeoutExpired:r['commands'][cmd]={'exit':124,'output':'COMMAND_TIMEOUT'}
files=list(Path('/etc/netplan').glob('*.yaml'))+[Path(x) for x in ['/etc/weka-roce.conf','/etc/sysctl.d/99-weka-roce.conf','/usr/local/sbin/weka-roce-config.sh','/usr/local/sbin/weka-roce-startup.sh','/etc/systemd/system/weka-roce.service','/etc/systemd/system/weka-agent.service.d/10-roce.conf']]
for f in files:
 if f.is_file():r['files'][str(f)]=f.read_text(errors='replace')
r['nics']=[]
for d in Path('/sys/class/net').iterdir():
 try:
  pci=(d/'device').resolve()
  if not (d/'device').exists() or (pci/'vendor').read_text().strip()!='0x15b3':continue
 except OSError:continue
 nic={'name':d.name,'pci':pci.name}
 for key in ['address','mtu','operstate','speed']:
  try:nic[key]=(d/key).read_text().strip()
  except OSError:nic[key]='unavailable'
 for cmd in [f'ethtool -i {d.name}',f'ethtool {d.name}',f'ethtool --show-fec {d.name}',f'mlnx_qos -i {d.name}',f'ethtool -S {d.name}']:
  try:
   o=subprocess.run(cmd,shell=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=20);r['commands'][cmd]={'exit':o.returncode,'output':o.stdout}
  except subprocess.TimeoutExpired:r['commands'][cmd]={'exit':124,'output':'COMMAND_TIMEOUT'}
 r['nics'].append(nic)
print(json.dumps(r))
'''
pattern=re.compile(r'password|passwd|secret|community|token|private.key|authentication.key|-----BEGIN .*PRIVATE KEY|\bgh[pousr]_[A-Za-z0-9]+',re.I)
def sanitize(value):
 if isinstance(value,dict):return {k:sanitize(v) for k,v in value.items()}
 if isinstance(value,list):return [sanitize(v) for v in value]
 if isinstance(value,str):return '\n'.join('[REDACTED sensitive line]' if pattern.search(line) else line for line in value.split('\n'))
 return value
rows=['host\tip\tresult\tdetails'];failures=0
for number in a.hosts.split():
 if not number.isdigit() or not 40<=int(number)<=79:raise SystemExit('Only client numbers 40-79 are allowed')
 host='weka'+number;ip='172.31.18.'+number
 print('===== READ-ONLY COLLECTION '+host+' '+ip+' =====',flush=True)
 ssh=['ssh','-o','ConnectTimeout=12','-o','ServerAliveInterval=15','-o','ServerAliveCountMax=2','-o','NumberOfPasswordPrompts=1','root@'+ip,'python3 -']
 if os.environ.get('SSHPASS'):ssh=['sshpass','-e']+ssh
 try:
  result=subprocess.run(ssh,input=remote,stdout=subprocess.PIPE,text=True,timeout=300)
  if result.returncode:raise ValueError('SSH_EXIT_'+str(result.returncode))
  data=json.loads(result.stdout)
  if data['hostname'].split('.')[0]!=host:raise ValueError('HOSTNAME_MISMATCH')
  errors=sum(v['exit']!=0 for v in data['commands'].values())
  data=sanitize(data);data['expected_host']=host;data['management_ip']=ip;data['assessment']='CAPTURED_NOT_HEALTH_VALIDATED';data['failed_commands']=errors
  (dest/(host+'.json')).write_text(json.dumps(data,indent=2)+'\n')
  rows.append(f'{host}\t{ip}\tCAPTURED_NOT_HEALTH_VALIDATED\tfailed_commands={errors}')
 except (subprocess.TimeoutExpired,ValueError,KeyError) as exc:
  failures+=1;rows.append(f'{host}\t{ip}\tCOLLECTION_FAILED\t{type(exc).__name__}')
(dest/'summary.tsv').write_text('\n'.join(rows)+'\n')
(dest/'README.md').write_text('# Client snapshots\n\nRead-only configuration and runtime collection; no configuration changes, reboots or tests. Sensitive matching lines were redacted before writing. Missing or failed commands are recorded; capture is not a health pass. Netplan files must be considered together. Historical maps remain historical; this collection does not automatically update validated status.\n')
print('\n'.join(rows));print('Snapshots: '+str(dest));print('Uncollected hosts: '+str(failures))
