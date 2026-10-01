#!/usr/bin/env bash
set -euo pipefail
cd "${1:-$HOME/Downloads/sn5600-weka-production-fabric}"
[[ -d .git ]] || { echo 'STOP: not a Git checkout'; exit 1; }
[[ "$(git remote get-url origin)" == *sekharg-weka/sn5600-weka-production-fabric* ]] || { echo 'STOP: unexpected Git remote'; exit 1; }
python3 - <<'PY'
from pathlib import Path
from datetime import datetime, timezone
import os,re,shutil
folder=Path('configs/switches/20261001T044650Z')
if not folder.is_dir():raise SystemExit('STOP: expected snapshot directory missing')
if (folder/'leaf-05/hostname.txt').read_text().strip()!='MT2324XZ0TB0':raise SystemExit('STOP: unexpected leaf-05 hostname')
backup=Path.home()/'Downloads'/('SN5600_Private_Config_Backup_'+datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ'))
shutil.copytree(folder,backup)
os.chmod(backup,0o700)
for p in backup.rglob('*'):os.chmod(p,0o700 if p.is_dir() else 0o600)
pattern=re.compile(r'password|passwd|secret|community|token|private.key|authentication.key',re.I)
count=0
for p in folder.rglob('*'):
 if not p.is_file():continue
 lines=p.read_text(errors='replace').splitlines(keepends=True); output=[]
 for line in lines:
  if pattern.search(line):
   output.append(line[:len(line)-len(line.lstrip())]+'# REDACTED sensitive configuration entry\n');count+=1
  else:output.append(line)
 p.write_text(''.join(output))
p=folder/'summary.tsv'
rows=p.read_text().splitlines()
rows=['leaf-05\t172.31.17.3\tdeferred\tCAPTURED_IDENTITY_CONFIRMED' if r.startswith('leaf-05\t') else r for r in rows]
p.write_text('\n'.join(rows)+'\n')
(folder/'leaf-05/IDENTITY.md').write_text('# Confirmed leaf-05 identity\n\nManagement IP: 172.31.17.3\nObserved hostname: MT2324XZ0TB0\nIdentity confirmed by Sekhar.\n\nDeferred switch; not configured as part of this rollout. Existing hostname remains unchanged.\n')
note='\nSensitive configuration lines were removed before publication. These sanitized exports are not complete restore files. Original snapshots are retained outside the repository.\n'
p=folder/'README.md'
if note not in p.read_text():p.write_text(p.read_text()+note)
for p in folder.rglob('*'):
 if p.is_file() and pattern.search(p.read_text(errors='replace')):raise SystemExit('STOP: credential-pattern match remains in '+str(p))
print(f'Redacted {count} lines. Private originals: {backup}')
print(p.parent)
PY
python3 scripts/validate_repository.py
bash scripts/update_checksums.sh
git add -- configs/switches/20261001T044650Z SHA256SUMS
if ! git diff --cached --quiet; then
 git commit -m 'Add sanitized switch snapshots and confirmed deferred leaf-05 identity'
fi
git push origin main
echo 'Switch snapshots uploaded successfully.'
