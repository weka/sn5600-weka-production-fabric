#!/usr/bin/env bash
# Generated for leaf-04; Cumulus Linux 5.11.5 SN5600. Does not modify swp33-64.
set -euo pipefail

EXPECTED_HOSTNAME='leaf-04'
EXPECTED_MGMT='172.31.17.24/21'
EXPECTED_ASN='65104'
EXPECTED_RID='10.255.0.14'
PORTS=('swp4s1' 'swp4s0' 'swp3s1' 'swp3s0' 'swp8s1' 'swp8s0' 'swp7s1' 'swp7s0' 'swp2s1' 'swp2s0' 'swp1s1' 'swp1s0' 'swp6s1' 'swp6s0' 'swp5s1' 'swp5s0')
ADDRS=('10.200.40.0/31' '10.200.40.2/31' '10.200.41.0/31' '10.200.41.2/31' '10.200.42.0/31' '10.200.42.2/31' '10.200.43.0/31' '10.200.43.2/31' '10.200.44.0/31' '10.200.44.2/31' '10.200.45.0/31' '10.200.45.2/31' '10.200.46.0/31' '10.200.46.2/31' '10.200.47.0/31' '10.200.47.2/31')
NETWORKS=('10.200.40.0/31' '10.200.40.2/31' '10.200.41.0/31' '10.200.41.2/31' '10.200.42.0/31' '10.200.42.2/31' '10.200.43.0/31' '10.200.43.2/31' '10.200.44.0/31' '10.200.44.2/31' '10.200.45.0/31' '10.200.45.2/31' '10.200.46.0/31' '10.200.46.2/31' '10.200.47.0/31' '10.200.47.2/31')
SERVER_IPS=('10.200.40.1' '10.200.40.3' '10.200.41.1' '10.200.41.3' '10.200.42.1' '10.200.42.3' '10.200.43.1' '10.200.43.3' '10.200.44.1' '10.200.44.3' '10.200.45.1' '10.200.45.3' '10.200.46.1' '10.200.46.3' '10.200.47.1' '10.200.47.3')
LABELS=('weka40-link1' 'weka40-link2' 'weka41-link1' 'weka41-link2' 'weka42-link1' 'weka42-link2' 'weka43-link1' 'weka43-link2' 'weka44-link1' 'weka44-link2' 'weka45-link1' 'weka45-link2' 'weka46-link1' 'weka46-link2' 'weka47-link1' 'weka47-link2')
KNOWN_DOWN=('no' 'no' 'no' 'no' 'no' 'no' 'no' 'no' 'yes' 'no' 'no' 'no' 'no' 'no' 'no' 'no')

die() { echo "ERROR: $*" >&2; exit 1; }

identity_check() {
  [[ "$(hostname -s)" == "$EXPECTED_HOSTNAME" ]] || die "expected hostname $EXPECTED_HOSTNAME, found $(hostname -s)"
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ "$ID" == "cumulus-linux" && "$VERSION_ID" == "5.11.5" ]] || die "requires Cumulus Linux 5.11.5"
  nv show system | grep -q 'x86_64-nvidia_sn5600-r0' || die "requires physical SN5600"
  ip -4 -o address show dev eth0 | awk '{print $4}' | grep -Fxq "$EXPECTED_MGMT" || die "management address is not $EXPECTED_MGMT"
  local bgp
  bgp="$(nv show router bgp)"
  grep -Eq "autonomous-system[[:space:]]+$EXPECTED_ASN([[:space:]]|$)" <<<"$bgp" || die "BGP ASN is not $EXPECTED_ASN"
  grep -Eq "router-id[[:space:]]+$EXPECTED_RID([[:space:]]|$)" <<<"$bgp" || die "BGP router ID is not $EXPECTED_RID"
}

preflight() {
  identity_check
  [[ -z "$(nv config diff)" ]] || die "pending NVUE changes exist; review/apply or detach them before continuing"
  declare -A planned=()
  local i port address live master
	  for i in "${!PORTS[@]}"; do
	    port="${PORTS[$i]}"; address="${ADDRS[$i]}"; planned["$port"]="$address"
    ip link show dev "$port" >/dev/null 2>&1 || die "$port does not exist; do not change breakout mode with this package"
    master=""
    if [[ -L "/sys/class/net/$port/master" ]]; then
      master="$(basename "$(readlink "/sys/class/net/$port/master")")"
    fi
    [[ -z "$master" ]] || die "$port is enslaved to $master"
    [[ "$(cat "/sys/class/net/$port/mtu")" == "9216" ]] || die "$port MTU is not 9216"
    live="$(ip -4 -o address show dev "$port" | awk '{print $4}' | paste -sd, -)"
    [[ -z "$live" || "$live" == "$address" ]] || die "$port has unexpected IPv4 address(es): $live"
  done
  while read -r dev address; do
    [[ "$address" == 10.200.* ]] || continue
	    [[ -n "${planned[$dev]:-}" && "${planned[$dev]}" == "$address" ]] || die "existing 10.200.0.0/16 address conflicts: $dev $address"
  done < <(ip -4 -o address show | awk '{print $2, $4}')
	  echo "Preflight passed: $EXPECTED_HOSTNAME; ${#PORTS[@]} confirmed server links; swp33-64 untouched."
}

backup() {
  local state stamp dir
  state="$HOME/sn5600-client31-state/$EXPECTED_HOSTNAME"
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  dir="$state/$stamp"
  mkdir -p -m 700 "$dir"
  nv config show > "$dir/before.yaml"
  sudo vtysh -c 'show running-config' > "$dir/before-frr.txt"
  ip -4 -o address show > "$dir/before-ipv4-addresses.txt"
  echo "Backup: $dir"
}

stage_commands() {
  local i port address network
	  for i in "${!PORTS[@]}"; do
	    port="${PORTS[$i]}"; address="${ADDRS[$i]}"; network="${NETWORKS[$i]}"
    nv set interface "$port" type swp
    nv set interface "$port" link state up
    nv set interface "$port" link mtu 9216
    nv set interface "$port" link fec auto
    nv set interface "$port" ip ipv4 forward on
    nv set interface "$port" ip address "$address"
    nv set vrf default router bgp address-family ipv4-unicast network "$network"
  done
}

stage() {
  preflight
  stage_commands
  echo "===== NVUE candidate diff ====="
  nv config diff
  echo "Staged only. Review the diff, then run: nv config apply --assume-yes && nv config save"
}

apply_config() {
  preflight
  backup
  stage_commands
  echo "===== NVUE candidate diff ====="
  nv config diff
  nv config apply --assume-yes
  nv config save
  echo "Applied and saved $EXPECTED_HOSTNAME server-facing /31 configuration."
}

validate_config() {
  identity_check
  [[ -z "$(nv config diff)" ]] || die "pending NVUE changes exist"
  local i port address network oper failures=0 degraded=0
	  for i in "${!PORTS[@]}"; do
	    port="${PORTS[$i]}"; address="${ADDRS[$i]}"; network="${NETWORKS[$i]}"
	    ip -4 -o address show dev "$port" | awk '{print $4}' | grep -Fxq "$address" || { echo "FAIL ${LABELS[$i]}: $port lacks $address"; failures=$((failures+1)); continue; }
	    sudo vtysh -c 'show running-config bgpd' | grep -Fq "network $network" || { echo "FAIL ${LABELS[$i]}: BGP network $network missing"; failures=$((failures+1)); }
    oper="$(cat "/sys/class/net/$port/operstate")"
    if [[ "$oper" == "up" ]]; then
	      echo "PASS ${LABELS[$i]}: $port up, $address, BGP $network"
	    elif [[ "${KNOWN_DOWN[$i]}" == "yes" ]]; then
	      echo "DEGRADED ${LABELS[$i]}: $port remains $oper (known-down baseline)"
      degraded=$((degraded+1))
    else
	      echo "FAIL ${LABELS[$i]}: $port is $oper"
      failures=$((failures+1))
    fi
  done
  [[ "$failures" -eq 0 ]] || die "$failures configuration/link validation failure(s)"
  echo "Validation passed; known-down exceptions: $degraded"
}

validate_endpoints() {
  validate_config
  local i port server oper failures=0 skipped=0
	  for i in "${!PORTS[@]}"; do
	    port="${PORTS[$i]}"; server="${SERVER_IPS[$i]}"; oper="$(cat "/sys/class/net/$port/operstate")"
	    if [[ "$oper" != "up" && "${KNOWN_DOWN[$i]}" == "yes" ]]; then
	      echo "SKIP ${LABELS[$i]}: known-down link"
      skipped=$((skipped+1)); continue
    fi
    sudo ip vrf exec default ping -n -I "$port" -c 3 -W 2 -M do -s 8972 "$server" >/dev/null 2>&1 	      && echo "PASS ${LABELS[$i]}: 9000-byte peer probe to $server" 	      || { echo "FAIL ${LABELS[$i]}: peer probe to $server"; failures=$((failures+1)); }
  done
  [[ "$failures" -eq 0 ]] || die "$failures endpoint probe failure(s)"
  echo "Endpoint validation passed; skipped known-down links: $skipped"
}

rollback_stage_commands() {
  local i
	  for i in "${!PORTS[@]}"; do
	    nv unset interface "${PORTS[$i]}" ip address "${ADDRS[$i]}"
	    nv unset vrf default router bgp address-family ipv4-unicast network "${NETWORKS[$i]}"
  done
}

	case "${1:---help}" in
  --check) preflight ;;
  --stage) stage ;;
  --apply) apply_config ;;
  --validate) validate_config ;;
  --end-to-end) validate_endpoints ;;
  --rollback-stage) preflight; rollback_stage_commands; nv config diff; echo 'Rollback staged only; review before applying.' ;;
  *) echo "Usage: $0 --check|--stage|--apply|--validate|--end-to-end|--rollback-stage"; exit 2 ;;
esac
