#!/usr/bin/env bash
# Copy exact tested scripts and persistence files; never deploy/reboot.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TARGET=root@172.31.18.61
DEST="$ROOT/packages/host-roce-reference"
STAMP=$(date +%Y%m%d_%H%M%S)
if [ -d "$DEST" ]; then
  echo "STOP: $DEST already exists; review it rather than overwriting exact reference files."; exit 1
fi
mkdir -p "$DEST/scripts" "$DEST/persistence"
SSH_OPTS=(-o ConnectTimeout=10 -o ServerAliveInterval=15)
scp "${SSH_OPTS[@]}" "$TARGET:/root/weka-roce-precheck.sh" "$DEST/scripts/"
scp "${SSH_OPTS[@]}" "$TARGET:/root/deploy-weka-roce.sh" "$DEST/scripts/"
for FILE in /etc/weka-roce.conf /etc/sysctl.d/99-weka-roce.conf /usr/local/sbin/weka-roce-config.sh /usr/local/sbin/weka-roce-startup.sh /etc/systemd/system/weka-roce.service /etc/systemd/system/weka-agent.service.d/10-roce.conf; do
  scp "${SSH_OPTS[@]}" "$TARGET:$FILE" "$DEST/persistence/"
done
ssh "${SSH_OPTS[@]}" "$TARGET" 'date -u; hostname; sha256sum /root/weka-roce-precheck.sh /root/deploy-weka-roce.sh; systemctl cat weka-roce.service weka-agent.service' > "$DEST/provenance-$STAMP.txt"
bash -n "$DEST/scripts/weka-roce-precheck.sh"
bash -n "$DEST/scripts/deploy-weka-roce.sh"
echo "Collected from weka61 into $DEST. No configuration changes made."
echo "Review files for credentials and update current status before committing."
echo "Then run: python3 scripts/validate_repository.py && bash scripts/update_checksums.sh"
