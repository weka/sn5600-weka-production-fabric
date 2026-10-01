#!/bin/bash
# Run on the Mac. Fixed eight-switch inventory; 172.31.17.3 is excluded.
set -euo pipefail
SN_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$SN_DIR"
SN_ACTION=${1:-help}
SN_GROUP=${2:-all}
SN_NAMES=(spine-01 spine-02 spine-03 spine-04 leaf-01 leaf-02 leaf-03 leaf-04)
SN_IPS=(172.31.17.5 172.31.17.18 172.31.17.20 172.31.17.22 172.31.17.19 172.31.17.21 172.31.17.23 172.31.17.24)
# RoCE accepts a single switch name or all; migration still accepts spine groups.
case "$SN_ACTION" in
  roce-check|roce-apply|roce-validate|roce-rollback)
    SN_TARGETS=()
    for i in "${!SN_NAMES[@]}"; do
      if [[ "$SN_GROUP" == all || "$SN_GROUP" == "${SN_NAMES[$i]}" ]]; then
        SN_TARGETS+=("$i")
      fi
    done
    [[ ${#SN_TARGETS[@]} -gt 0 ]] || { echo 'Unknown active switch' >&2; exit 1; }
    if [[ "$SN_ACTION" == roce-rollback && "$SN_GROUP" == all ]]; then
      echo 'Rollback one named switch at a time, e.g. roce-rollback leaf-01' >&2
      exit 1
    fi
    roce_switch() {
      local idx=$1
      shift
      printf '\n%s (%s): %s\n' "${SN_NAMES[$idx]}" "${SN_IPS[$idx]}" "$*"
      ssh -t "cumulus@${SN_IPS[$idx]}" "bash /home/cumulus/SN5600_Numbered31/${SN_NAMES[$idx]}.sh $*"
    }
    if [[ "$SN_ACTION" == roce-apply ]]; then
      for i in "${SN_TARGETS[@]}"; do roce_switch "$i" roce-check; done
      for i in "${SN_TARGETS[@]}"; do roce_switch "$i" roce-enable --apply; done
    elif [[ "$SN_ACTION" == roce-rollback ]]; then
      for i in "${SN_TARGETS[@]}"; do roce_switch "$i" roce-rollback --apply; done
    else
      SN_RC=0
      for i in "${SN_TARGETS[@]}"; do roce_switch "$i" "$SN_ACTION" || SN_RC=1; done
      exit "$SN_RC"
    fi
    exit 0
    ;;
esac
case "$SN_GROUP" in all|spine-01|spine-02|spine-03|spine-04) ;; *) echo 'Invalid spine group' >&2; exit 1;; esac
run_switch() {
  local idx=$1
  shift
  printf '\n%s (%s): %s\n' "${SN_NAMES[$idx]}" "${SN_IPS[$idx]}" "$*"
  ssh -t "cumulus@${SN_IPS[$idx]}" "bash /home/cumulus/SN5600_Numbered31/${SN_NAMES[$idx]}.sh $*"
}
selected=()
for i in "${!SN_NAMES[@]}"; do
  if [[ "$SN_GROUP" == all || "${SN_NAMES[$i]}" == "$SN_GROUP" || "${SN_NAMES[$i]}" == leaf-* ]]; then
    selected+=("$i")
  fi
done
case "$SN_ACTION" in
  copy)
    shasum -a 256 -c SHA256SUMS
    for i in "${!SN_NAMES[@]}"; do
      scp -r "$SN_DIR" "cumulus@${SN_IPS[$i]}:/home/cumulus/"
    done
    ;;
  check)
    for i in "${selected[@]}"; do run_switch "$i" check; done
    ;;
  addresses)
    [[ "$SN_GROUP" == all ]] || { echo 'Run addresses on all eight switches' >&2; exit 1; }
    for i in "${!SN_NAMES[@]}"; do run_switch "$i" check; done
    for i in "${!SN_NAMES[@]}"; do run_switch "$i" addresses --apply; done
    echo 'Addresses applied on all eight switches. BGP migration is a separate step.'
    ;;
  migrate|rollback)
    [[ "$SN_GROUP" != all ]] || { echo 'Specify one group, e.g. migrate spine-01' >&2; exit 1; }
    for i in "${selected[@]}"; do run_switch "$i" check; done
    if [[ "$SN_ACTION" == migrate ]]; then
      SN_PHASE=bgp
      SN_VERIFY=validate
      for i in "${selected[@]}"; do run_switch "$i" probe "$SN_GROUP"; done
    else
      SN_PHASE=rollback-bgp
      SN_VERIFY=validate-unnumbered
    fi
    for i in "${selected[@]}"; do run_switch "$i" "$SN_PHASE" "$SN_GROUP" --apply; done
    echo 'Waiting 15 seconds for BGP convergence...'
    sleep 15
    SN_RC=0
    for i in "${selected[@]}"; do run_switch "$i" "$SN_VERIFY" "$SN_GROUP" || SN_RC=1; done
    if [[ "$SN_RC" != 0 ]]; then
      echo 'STOP: inspect failures. If still converging, rerun validation. Do not migrate the next spine yet.' >&2
      exit 1
    fi
    echo 'Group complete. Read the validation output; DEGRADED means some links are still missing.'
    ;;
  validate|validate-unnumbered|probe)
    SN_RC=0
    for i in "${selected[@]}"; do run_switch "$i" "$SN_ACTION" "$SN_GROUP" || SN_RC=1; done
    exit "$SN_RC"
    ;;
  *)
    cat <<'USAGE'
Run in this extracted directory on the Mac:
  bash fabric.sh copy                 Copy files to the eight switches
  bash fabric.sh check                Read-only preflight of all eight
  bash fabric.sh addresses            Add /31 addresses on all eight; keep current BGP peers
  bash fabric.sh probe spine-01       Test /31 peer reachability without changing BGP
  bash fabric.sh migrate spine-01     Convert this spine plus matching ports on all four leaves
  bash fabric.sh migrate spine-02     Run only after the previous group validates
  bash fabric.sh migrate spine-03
  bash fabric.sh migrate spine-04
  bash fabric.sh validate             Validate numbered BGP after all four groups
  bash fabric.sh validate spine-01    Recheck a single group
  bash fabric.sh rollback spine-01    Restore this group's original unnumbered peers at both ends
  bash fabric.sh validate-unnumbered spine-01
  bash fabric.sh roce-check           Read-only RoCE preflight after /31 migration
  bash fabric.sh roce-apply           Enable lossless RoCE, one switch at a time; validate each
  bash fabric.sh roce-apply leaf-01   Enable/verify RoCE on one named switch
  bash fabric.sh roce-validate        Check PFC/ECN/DSCP on all 32 fabric ports per switch
  bash fabric.sh roce-rollback leaf-01  Restore that switch's saved RoCE baseline
Read ROCE.md for host requirements and validation limits.
Read START_HERE.md. Migration resets the selected BGP sessions; schedule downtime.
USAGE
    ;;
esac
