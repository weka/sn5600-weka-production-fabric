#!/usr/bin/env bash
set -euo pipefail
D="$HOME/backend-expansion-state"
mkdir -p "$D"
preflight() {
@CHECKS@
}
case "${1:-}" in
 --check) preflight; nv show qos roce; nv config diff ;;
 --stage)
 preflight
 [[ -z "$(nv config diff | tr -d '[:space:]')" ]] || { echo 'STOP: existing candidate'; exit 1; }
 nv config show > "$D/before-$(date -u +%Y%m%dT%H%M%SZ).yaml"
 nv config show | sha256sum > "$D/applied.hash"
@COMMANDS@
 nv config diff | tee "$D/staged.diff"
 sha256sum "$D/staged.diff" > "$D/staged.hash"
 echo 'STAGED ONLY. Review candidate and baseline BGP before applying.'
 ;;
 --apply)
 preflight
 nv config diff > "$D/current.diff"
 [[ "$(sha256sum "$D/current.diff" | awk '{print $1}')" == "$(awk '{print $1}' "$D/staged.hash")" ]] || { echo 'STOP: candidate changed'; exit 1; }
 [[ "$(nv config show | sha256sum | awk '{print $1}')" == "$(awk '{print $1}' "$D/applied.hash")" ]] || { echo 'STOP: applied configuration changed'; exit 1; }
 nv config apply --assume-yes
 nv config save
 ;;
 --validate) preflight
@VALIDATE@
nv show interface; nv show qos roce; sudo vtysh -c 'show bgp ipv4 unicast summary'; sudo vtysh -c 'show ip route'; echo 'REVIEW_REQUIRED: compare exact expected networks, peers and endpoint probes.' ;;
 *) echo 'Usage: --check|--stage|--apply|--validate'; exit 2 ;;
esac
