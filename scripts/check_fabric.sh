#!/usr/bin/env bash
# Read-only snapshots, not a declaration that every planned path is healthy.
set -uo pipefail
REPORT_DIR="${REPORT_DIR:-$HOME/Downloads/SN5600_Fabric_Snapshot_$(date +%Y%m%d_%H%M%S)}"
mkdir -p "$REPORT_DIR" || exit 1
printf 'SWITCH\tRESULT\n' > "$REPORT_DIR/summary.tsv"
FAILED=0
for ENTRY in spine-01,172.31.17.5 spine-02,172.31.17.18 spine-03,172.31.17.20 spine-04,172.31.17.22 leaf-01,172.31.17.19 leaf-02,172.31.17.21 leaf-03,172.31.17.23 leaf-04,172.31.17.24; do
  NAME=${ENTRY%,*}; IP=${ENTRY#*,}
  echo "===== $NAME $IP ====="
  if ssh -tt -o ConnectTimeout=10 -o ServerAliveInterval=15 "cumulus@$IP" '
    set -e
    hostname
    date -u
    uptime
    echo "===== ALL INTERFACES ====="
    nv show interface
    echo "===== ROCE ====="
    nv show qos roce
    echo "===== PENDING CANDIDATE ====="
    nv config diff
    echo "===== BGP ====="
    sudo vtysh -c "show bgp ipv4 unicast summary"
    echo "===== CLIENT ROUTE EXAMPLES ====="
    sudo vtysh -c "show ip route 10.200.40.0/31"
    sudo vtysh -c "show ip route 10.200.49.0/31"
    sudo vtysh -c "show ip route 10.200.60.0/31"
    sudo vtysh -c "show ip route 10.200.68.0/31"
    echo SNAPSHOT_CAPTURED
  ' 2>&1 | tee "$REPORT_DIR/$NAME.log"; then
    printf '%s\tCAPTURED_REVIEW_REQUIRED\n' "$NAME" >> "$REPORT_DIR/summary.tsv"
  else
    printf '%s\tCAPTURE_FAILED\n' "$NAME" >> "$REPORT_DIR/summary.tsv"; FAILED=1
  fi
done
cat "$REPORT_DIR/summary.tsv"
echo "Reports: $REPORT_DIR"
echo "Compare link and BGP state with inventory and known issues; captured is not a health pass."
[ "$FAILED" -eq 0 ]
