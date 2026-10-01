#!/usr/bin/env bash
# Generated for weka76; run as root. Management networking is not modified.
set -euo pipefail

EXPECTED_HOST='weka76'
EXPECTED_MGMT='172.31.18.76'
IF1='ens4047f0np0'
IF2='ens4047f1np1'
MAC1='a0:88:c2:d5:66:92'
MAC2='a0:88:c2:d5:66:93'
LEAF1='10.200.76.0'
LEAF2='10.200.76.2'
IP1='10.200.76.1/31'
IP2='10.200.76.3/31'
STATE_DIR="/root/sn5600-client31-state/$EXPECTED_HOST"
CANDIDATE="$STATE_DIR/70-datapath.yaml.candidate"
TARGET="/etc/netplan/70-datapath.yaml"

die() { echo "ERROR: $*" >&2; exit 1; }

check_iface() {
  local iface=$1 expected_mac=$2 actual_mac rdma layer
  [[ -d "/sys/class/net/$iface" ]] || die "$iface does not exist"
  actual_mac="$(tr '[:upper:]' '[:lower:]' < "/sys/class/net/$iface/address")"
  [[ "$actual_mac" == "$expected_mac" ]] || die "$iface MAC is $actual_mac; expected $expected_mac"
  rdma="$(find "/sys/class/net/$iface/device/infiniband" -mindepth 1 -maxdepth 1 -printf '%f
' 2>/dev/null | head -n 1)"
  [[ -n "$rdma" ]] || die "$iface has no RDMA device"
  layer="$(cat "/sys/class/infiniband/$rdma/ports/1/link_layer")"
  [[ "$layer" == "Ethernet" ]] || die "$iface is $layer, not Ethernet"
}

preflight() {
  [[ "$EUID" -eq 0 ]] || die "run as root"
  [[ "$(hostname -s)" == "$EXPECTED_HOST" ]] || die "expected hostname $EXPECTED_HOST, found $(hostname -s)"
	  ip -4 -o address show | awk '{print $4}' | grep -Eq "^${EXPECTED_MGMT}/" || die "management IP $EXPECTED_MGMT is not present"
  command -v netplan >/dev/null || die "netplan is not installed"
  check_iface "$IF1" "$MAC1"
  check_iface "$IF2" "$MAC2"
  local f iface
  for iface in "$IF1" "$IF2"; do
    for f in /etc/netplan/*.yaml /etc/netplan/*.yml; do
      [[ -e "$f" || -L "$f" ]] || continue
      [[ "$f" == "$TARGET" ]] && continue
	      grep -Eq "^[[:space:]]+${iface}:([[:space:]]*)$" "$f" && die "$iface is also defined in $f"
    done
  done
  echo "Preflight passed: $EXPECTED_HOST; both CX-7 ports are Ethernet and MACs match."
}

write_candidate() {
  mkdir -p -m 700 "$STATE_DIR"
  umask 077
  cat > "$CANDIDATE" <<'NETPLAN'
network:
  version: 2
  renderer: networkd
  ethernets:
    ens4047f0np0:
      match:
        macaddress: a0:88:c2:d5:66:92
      set-name: ens4047f0np0
      dhcp4: false
      dhcp6: false
      accept-ra: false
      link-local: []
      mtu: 9000
      addresses:
        - 10.200.76.1/31
      routes:
        - to: 10.200.0.0/16
          via: 10.200.76.0
          table: 100
      routing-policy:
        - from: 10.200.76.1/32
          table: 100
          priority: 32764
      ignore-carrier: true
      optional: true
    ens4047f1np1:
      match:
        macaddress: a0:88:c2:d5:66:93
      set-name: ens4047f1np1
      dhcp4: false
      dhcp6: false
      accept-ra: false
      link-local: []
      mtu: 9000
      addresses:
        - 10.200.76.3/31
      routes:
        - to: 10.200.0.0/16
          via: 10.200.76.2
          table: 101
      routing-policy:
        - from: 10.200.76.3/32
          table: 101
          priority: 32765
      ignore-carrier: true
      optional: true
NETPLAN
  chmod 600 "$CANDIDATE"
  local test_root rc=0
  test_root="$(mktemp -d)"
  mkdir -p "$test_root/etc/netplan"
  install -m 600 "$CANDIDATE" "$test_root/etc/netplan/70-datapath.yaml"
  netplan generate --root-dir "$test_root" || rc=$?
  rm -rf -- "$test_root"
  return "$rc"
}

stage() {
  preflight
  write_candidate
  echo "===== candidate Netplan ====="
  sed -n '1,220p' "$CANDIDATE"
  echo "===== diff against $TARGET ====="
  if [[ -e "$TARGET" ]]; then diff -u "$TARGET" "$CANDIDATE" || true; else echo "$TARGET does not exist"; fi
  echo "Staged only at $CANDIDATE"
}

backup() {
  local stamp archive
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  archive="$STATE_DIR/netplan-before-$stamp.tar.gz"
  tar -C /etc -czf "$archive" netplan
  chmod 600 "$archive"
  echo "Backup: $archive"
}

apply_config() {
  preflight
  write_candidate
  backup
  install -m 600 "$CANDIDATE" "$TARGET"
  if ! netplan generate || ! netplan apply; then
    echo "Netplan apply failed. Use the printed backup archive and console/BMC access to restore /etc/netplan." >&2
    exit 1
  fi
  echo "Applied $TARGET on $EXPECTED_HOST."
}

validate() {
  preflight
  local failures=0 speed
  ip -4 -o address show dev "$IF1" | awk '{print $4}' | grep -Fxq "$IP1" || { echo "FAIL $IF1 lacks $IP1"; failures=$((failures+1)); }
  ip -4 -o address show dev "$IF2" | awk '{print $4}' | grep -Fxq "$IP2" || { echo "FAIL $IF2 lacks $IP2"; failures=$((failures+1)); }
	  ip rule show | grep -Eq "from ${IP1%/*} lookup 100" || { echo "FAIL source rule table 100"; failures=$((failures+1)); }
	  ip rule show | grep -Eq "from ${IP2%/*} lookup 101" || { echo "FAIL source rule table 101"; failures=$((failures+1)); }
  ip -4 route show table 100 | grep -Eq "^10.200.0.0/16 via $LEAF1 dev $IF1" || { echo "FAIL route table 100"; failures=$((failures+1)); }
  ip -4 route show table 101 | grep -Eq "^10.200.0.0/16 via $LEAF2 dev $IF2" || { echo "FAIL route table 101"; failures=$((failures+1)); }
  for iface in "$IF1" "$IF2"; do
    speed="$(cat "/sys/class/net/$iface/speed" 2>/dev/null || true)"
	    echo "$iface state=$(cat "/sys/class/net/$iface/operstate") speedMbps=${speed:-unknown} mtu=$(cat "/sys/class/net/$iface/mtu")"
  done
  ping -n -I "$IF1" -c 3 -W 2 -M do -s 8972 "$LEAF1" >/dev/null 2>&1     && echo "PASS $IF1 9000-byte probe to $LEAF1"     || { echo "FAIL $IF1 probe to $LEAF1"; failures=$((failures+1)); }
  ping -n -I "$IF2" -c 3 -W 2 -M do -s 8972 "$LEAF2" >/dev/null 2>&1     && echo "PASS $IF2 9000-byte probe to $LEAF2"     || { echo "FAIL $IF2 probe to $LEAF2"; failures=$((failures+1)); }
  [[ "$failures" -eq 0 ]] || die "$failures validation failure(s)"
  echo "PASS: $EXPECTED_HOST /31 addresses, policy routes, MTU probes and Ethernet mode."
}

restore_backup() {
  [[ "$EUID" -eq 0 ]] || die "run as root"
	  local archive=${1:-}
  [[ -f "$archive" ]] || die "backup archive not found: $archive"
  tar -tzf "$archive" | grep -q '^netplan/' || die "archive does not contain the netplan directory"
  tar -C /etc -xzf "$archive"
  netplan generate
  netplan apply
  echo "Restored /etc/netplan from $archive"
}

	case "${1:---help}" in
  --check) preflight ;;
  --stage) stage ;;
  --apply) apply_config ;;
  --validate) validate ;;
	  --restore) restore_backup "${2:-}" ;;
  *) echo "Usage: $0 --check|--stage|--apply|--validate|--restore BACKUP.tar.gz"; exit 2 ;;
esac
