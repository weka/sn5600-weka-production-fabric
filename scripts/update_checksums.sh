#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
python3 - "$ROOT" <<'PY'
from pathlib import Path
import hashlib,sys
r=Path(sys.argv[1]); rows=[]
for p in sorted(r.rglob('*')):
    if not p.is_file():continue
    rel=p.relative_to(r)
    if any(x in {'.git','__pycache__','reports','local-private'} for x in rel.parts):continue
    if rel.as_posix()=='SHA256SUMS' or p.suffix=='.pyc':continue
    rows.append(hashlib.sha256(p.read_bytes()).hexdigest()+'  '+rel.as_posix())
(r/'SHA256SUMS').write_text('\n'.join(rows)+'\n')
print('Updated',len(rows),'file hashes')
PY
