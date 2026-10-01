#!/usr/bin/env bash
# Read-only equipment collection; creates dated local snapshots and pushes to GitHub.
set -euo pipefail
ROOT="${1:-$HOME/Downloads/sn5600-weka-production-fabric}"
cd "$ROOT"
[[ -d .git ]] || { echo 'STOP: not a Git checkout'; exit 1; }
[[ "$(git remote get-url origin)" == *sekharg-weka/sn5600-weka-production-fabric* ]] || { echo 'STOP: unexpected Git remote'; exit 1; }
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
REL="configs/switches/$STAMP"
DEST="$ROOT/$REL"
mkdir -p "$DEST"
printf 'switch\tip\trole\tresult\n' > "$DEST/summary.tsv"
FAILED=0
for ENTRY in spine-01,172.31.17.5 spine-02,172.31.17.18 spine-03,172.31.17.20 spine-04,172.31.17.22 leaf-01,172.31.17.19 leaf-02,172.31.17.21 leaf-03,172.31.17.23 leaf-04,172.31.17.24 leaf-05,172.31.17.3; do
 NAME=${ENTRY%,*}; IP=${ENTRY#*,}; ROLE=active
 [[ "$NAME" != leaf-05 ]] || ROLE=deferred
 DIR="$DEST/$NAME"; mkdir -p "$DIR"
 REMOTE="sn5600-config-snapshots/$STAMP"
 echo "===== COLLECT $NAME $IP ($ROLE) ====="
 if ssh -tt -o ConnectTimeout=15 -o ServerAliveInterval=15 "cumulus@$IP" "
 set -e
 umask 077
 D=\"\$HOME/$REMOTE\"
 mkdir -p \"\$D\"
 hostname > \"\$D/hostname.txt\"
 date -u > \"\$D/collected-utc.txt\"
 cat /etc/os-release > \"\$D/os-release.txt\"
 uname -a > \"\$D/kernel.txt\"
 uptime > \"\$D/uptime.txt\"
 nv config show > \"\$D/applied.yaml\"
 nv config show -o commands > \"\$D/applied-commands.txt\"
 nv config diff > \"\$D/pending-diff.txt\"
 nv show interface > \"\$D/interfaces.txt\"
 nv show qos roce > \"\$D/roce.txt\"
 ip -4 route show table all > \"\$D/kernel-routes.txt\"
 sudo -v
 sudo vtysh -c 'show bgp ipv4 unicast summary' > \"\$D/bgp-summary.txt\"
 sudo vtysh -c 'show ip route' > \"\$D/frr-routes.txt\"
 sudo lldpctl > \"\$D/lldp.txt\"
 sudo cat /etc/network/interfaces > \"\$D/interfaces-config.txt\"
 sudo cat /etc/frr/frr.conf > \"\$D/frr.conf\"
 sudo cat /etc/nvue.d/startup.yaml > \"\$D/startup.yaml\"
 test -s \"\$D/applied.yaml\"
 echo COLLECTION_COMPLETE
 " && scp -q -o ConnectTimeout=15 "cumulus@$IP:$REMOTE/*" "$DIR/"; then
   ACTUAL=$(tr -d '\r\n' < "$DIR/hostname.txt")
   if [[ "$ACTUAL" == "$NAME" ]] || [[ "$NAME" == leaf-05 && "$ACTUAL" == MT2324XZ0TB0 ]]; then
     printf '%s\t%s\t%s\tCAPTURED_NOT_HEALTH_VALIDATED\n' "$NAME" "$IP" "$ROLE" >> "$DEST/summary.tsv"
   else
     echo "STOP: hostname mismatch on $IP"; FAILED=1
     printf '%s\t%s\t%s\tHOSTNAME_MISMATCH\n' "$NAME" "$IP" "$ROLE" >> "$DEST/summary.tsv"
   fi
 else
   FAILED=1
   printf '%s\t%s\t%s\tCOLLECTION_FAILED\n' "$NAME" "$IP" "$ROLE" >> "$DEST/summary.tsv"
 fi
done
cat > "$DEST/README.md" <<'DOC'
# Dated production switch snapshots

Applied NVUE YAML and command export, startup YAML, pending candidate diff,
FRR and Linux interface configuration, versions, LLDP, routes, BGP and RoCE
state were collected without applying configuration or rebooting equipment.
Collection success is not a fabric health pass. Leaf-05 is deferred.
Switch timestamps may differ; the directory timestamp is from the operator Mac.
These are reference snapshots, not an automatic restore procedure.
DOC
cat "$DEST/summary.tsv"
[[ "$FAILED" -eq 0 ]] || { echo "STOP: incomplete collection. Files retained at $DEST; nothing committed or pushed."; exit 1; }
# Report file names/line numbers only; never print possible credential values.
python3 - "$DEST" <<'PY'
from pathlib import Path
import re,sys
root=Path(sys.argv[1]); hits=[]
patterns=[r'(?i)\b(password|passwd|secret|community|token|private-key|authentication-key|encrypted-password|hashed-password)\b',r'-----BEGIN .*PRIVATE KEY-----',r'\b(?:ghp_|gho_|github_pat_)[A-Za-z0-9_]+']
for p in root.rglob('*'):
 if not p.is_file():continue
 for n,line in enumerate(p.read_text(errors='replace').splitlines(),1):
  if any(re.search(pattern,line) for pattern in patterns):hits.append(f'{p.relative_to(root)}:{n}')
if hits:
 print('STOP: possible credentials require review. Nothing will be uploaded. Matches:')
 print('\n'.join(hits)); sys.exit(1)
print('Snapshot credential-pattern check passed (not a guarantee that all secrets are absent).')
PY
python3 scripts/validate_repository.py
bash scripts/update_checksums.sh
git add -- "$REL" SHA256SUMS
git commit -m "Capture dated production switch configuration and operational snapshots"
git push origin main
echo "Uploaded switch snapshots: $REL"
