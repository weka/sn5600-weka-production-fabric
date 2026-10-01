#!/usr/bin/env bash
# Generated for leaf-01; Cumulus Linux 5.11.5 SN5600. Does not modify swp33-64.
set -euo pipefail

EXPECTED_HOSTNAME='leaf-01'
EXPECTED_MGMT='172.31.17.19/21'
EXPECTED_ASN='65101'
EXPECTED_RID='10.255.0.11'
PORTS=('swp6s2' 'swp6s3' 'swp5s2' 'swp5s3' 'swp6s0' 'swp6s1' 'swp5s0' 'swp5s1' 'swp4s0' 'swp4s1' 'swp3s2' 'swp3s3' 'swp4s2' 'swp4s3' 'swp3s0' 'swp3s1' 'swp2s2' 'swp2s3' 'swp1s2' 'swp1s3')
ADDRS=('10.200.68.0/31' '10.200.68.2/31' '10.200.69.0/31' '10.200.69.2/31' '10.200.70.0/31' '10.200.70.2/31' '10.200.71.0/31' '10.200.71.2/31' '10.200.72.0/31' '10.200.72.2/31' '10.200.73.0/31' '10.200.73.2/31' '10.200.74.0/31' '10.200.74.2/31' '10.200.75.0/31' '10.200.75.2/31' '10.200.76.0/31' '10.200.76.2/31' '10.200.77.0/31' '10.200.77.2/31')
NETWORKS=('10.200.68.0/31' '10.200.68.2/31' '10.200.69.0/31' '10.200.69.2/31' '10.200.70.0/31' '10.200.70.2/31' '10.200.71.0/31' '10.200.71.2/31' '10.200.72.0/31' '10.200.72.2/31' '10.200.73.0/31' '10.200.73.2/31' '10.200.74.0/31' '10.200.74.2/31' '10.200.75.0/31' '10.200.75.2/31' '10.200.76.0/31' '10.200.76.2/31' '10.200.77.0/31' '10.200.77.2/31')
SERVER_IPS=('10.200.68.1' '10.200.68.3' '10.200.69.1' '10.200.69.3' '10.200.70.1' '10.200.70.3' '10.200.71.1' '10.200.71.3' '10.200.72.1' '10.200.72.3' '10.200.73.1' '10.200.73.3' '10.200.74.1' '10.200.74.3' '10.200.75.1' '10.200.75.3' '10.200.76.1' '10.200.76.3' '10.200.77.1' '10.200.77.3')
LABELS=('weka68-link1' 'weka68-link2' 'weka69-link1' 'weka69-link2' 'weka70-link1' 'weka70-link2' 'weka71-link1' 'weka71-link2' 'weka72-link1' 'weka72-link2' 'weka73-link1' 'weka73-link2' 'weka74-link1' 'weka74-link2' 'weka75-link1' 'weka75-link2' 'weka76-link1' 'weka76-link2' 'weka77-link1' 'weka77-link2')
KNOWN_DOWN=('no' 'no' 'no' 'no' 'no' 'no' 'no' 'no' 'no' 'no' 'no' 'no' 'no' 'no' 'no' 'no' 'no' 'no' 'no' 'no')

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
