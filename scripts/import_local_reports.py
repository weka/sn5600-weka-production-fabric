#!/usr/bin/env python3
"""Copy available dated reports, redact matching lines and retain provenance."""
from pathlib import Path
import datetime,hashlib,json,re,shutil
root=Path(__file__).resolve().parents[1];source=Path.home()/'Downloads'
stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
dest=root/'evidence/local-reports'/stamp;dest.mkdir(parents=True)
allowed={'.txt','.log','.tsv','.csv','.json','.html','.svg','.md','.yaml','.yml'}
pattern=re.compile(r'password|passwd|secret|community|token|private.key|authentication.key|-----BEGIN .*PRIVATE KEY|\bgh[pousr]_[A-Za-z0-9]+',re.I)
manifest=[]
sources=[]
for glob in ['RoCE_*','CX7_Link_Mode_Scan_*','CX7_IB_to_ETH_*','SN5600_Post_Reboot_Status_*','SN5600_local_rack_scan_*']:
 sources.extend(f for f in source.glob(glob) if f.is_dir())
standalone=[]
for glob in ['roce_*audit*.txt','CX7_ready*.txt','SN5600_leaf_server_ports_*.txt','SN5600_Overall_Status_*.txt','WEKA_OS_BMC_Ping_*.csv','AXIOM_*link.txt','*_eeprom.txt','weka64_vs_weka65_cx7_diag.txt','post-reboot-fabric-validation.txt','SN5600_Cumulus_5.11.5_Upgrade_Guide.md']:
 standalone.extend(f for f in source.glob(glob) if f.is_file())
groups=[sorted(folder.rglob('*')) for folder in sorted(set(sources))]+[sorted(set(standalone))]
for group in groups:
 for f in group:
  if not f.is_file() or f.is_symlink() or f.suffix.lower() not in allowed:continue
  if f.stat().st_size>20*1024*1024:continue
  relative=f.relative_to(source)
  if 'reference' in relative.parts:continue
  data=f.read_bytes()
  try:text=data.decode('utf-8')
  except UnicodeError:continue
  # Remove personal workstation home paths while retaining usable report names.
  text=re.sub(r'/Users/[^/\s]+','/Users/OPERATOR',text)
  lines=text.splitlines(keepends=True);redacted=0;out=[]
  for line in lines:
   if pattern.search(line):out.append('[REDACTED sensitive line]\n');redacted+=1
   else:out.append(line)
  output=dest/relative
  if f.name=='SN5600_Cumulus_5.11.5_Upgrade_Guide.md':output=output.with_suffix('.md.txt')
  output.parent.mkdir(parents=True,exist_ok=True);output.write_text(''.join(out))
  manifest.append({'source_relative':str(relative),'original_sha256':hashlib.sha256(data).hexdigest(),'redacted_lines':redacted,'stored_sha256':hashlib.sha256(output.read_bytes()).hexdigest(),'interpretation':'IMPORTED_NOT_RESULT_REVIEWED'})
(dest/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
(dest/'README.md').write_text('# Imported local RoCE reports\n\nCopied from available selected production report folders on the operator workstation. Scripts, binary archives, oversized files and reference payloads were excluded. Credential-pattern lines and workstation home paths were sanitized; originals remain in Downloads. Files and summaries can include failed or incomplete runs. Import does not establish that pending tests passed and does not overwrite the curated evidence summary. Review the latest complete report, both QP exit codes, server logs and counter deltas before changing current status or sharing a heatmap.\n')
print(f'Imported {len(manifest)} text report files into {dest}')
if not manifest:print('NO_REPORT_FILES_FOUND: document this gap; no test results invented.')
