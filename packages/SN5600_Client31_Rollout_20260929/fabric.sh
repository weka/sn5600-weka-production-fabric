#!/usr/bin/env bash
# Run from macOS/Linux in this extracted directory. Passwords are prompted; none are stored.
set -euo pipefail
	ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
	ACTION=${1:-help}
	TARGET=${2:-all}
LEAF_NAMES=('leaf-01' 'leaf-02' 'leaf-03' 'leaf-04')
LEAF_IPS=('172.31.17.19' '172.31.17.21' '172.31.17.23' '172.31.17.24')
SERVER_NAMES=('weka40' 'weka41' 'weka42' 'weka43' 'weka44' 'weka45' 'weka46' 'weka47' 'weka49' 'weka50' 'weka51' 'weka52' 'weka53' 'weka54' 'weka55' 'weka56' 'weka57' 'weka58' 'weka60' 'weka61' 'weka62' 'weka63' 'weka65' 'weka66' 'weka67' 'weka68' 'weka69' 'weka70' 'weka71' 'weka72' 'weka73' 'weka74' 'weka75' 'weka76' 'weka77')
SERVER_IPS=('172.31.18.40' '172.31.18.41' '172.31.18.42' '172.31.18.43' '172.31.18.44' '172.31.18.45' '172.31.18.46' '172.31.18.47' '172.31.18.49' '172.31.18.50' '172.31.18.51' '172.31.18.52' '172.31.18.53' '172.31.18.54' '172.31.18.55' '172.31.18.56' '172.31.18.57' '172.31.18.58' '172.31.18.60' '172.31.18.61' '172.31.18.62' '172.31.18.63' '172.31.18.65' '172.31.18.66' '172.31.18.67' '172.31.18.68' '172.31.18.69' '172.31.18.70' '172.31.18.71' '172.31.18.72' '172.31.18.73' '172.31.18.74' '172.31.18.75' '172.31.18.76' '172.31.18.77')

selected() { [[ "$TARGET" == "all" || "$TARGET" == "$1" ]]; }
run_leaf() {
  local i=$1 mode=$2
	  echo; echo "===== ${LEAF_NAMES[$i]} ${LEAF_IPS[$i]} $mode ====="
	  ssh -t "cumulus@${LEAF_IPS[$i]}" "bash /home/cumulus/SN5600_Client31_Rollout_20260929/switches/${LEAF_NAMES[$i]}_client31.sh $mode"
}
run_server() {
  local i=$1 mode=$2
	  echo; echo "===== ${SERVER_NAMES[$i]} ${SERVER_IPS[$i]} $mode ====="
	  ssh -t "root@${SERVER_IPS[$i]}" "bash /root/SN5600_Client31_Rollout_20260929/servers/${SERVER_NAMES[$i]}_client31.sh $mode"
}

case "$ACTION" in
  copy-switches)
	    for i in "${!LEAF_NAMES[@]}"; do
	      if selected "${LEAF_NAMES[$i]}"; then
	        scp -r "$ROOT_DIR" "cumulus@${LEAF_IPS[$i]}:/home/cumulus/"
	      fi
	    done ;;
  copy-servers)
	    for i in "${!SERVER_NAMES[@]}"; do
	      if selected "${SERVER_NAMES[$i]}"; then
	        scp -r "$ROOT_DIR" "root@${SERVER_IPS[$i]}:/root/"
	      fi
	    done ;;
  switch-check|switch-stage|switch-apply|switch-validate|switch-end-to-end)
	    mode="--${ACTION#switch-}"
	    for i in "${!LEAF_NAMES[@]}"; do
	      if selected "${LEAF_NAMES[$i]}"; then
	        run_leaf "$i" "$mode"
	      fi
	    done ;;
  server-check|server-stage|server-apply|server-validate)
	    mode="--${ACTION#server-}"
	    for i in "${!SERVER_NAMES[@]}"; do
	      if selected "${SERVER_NAMES[$i]}"; then
	        run_server "$i" "$mode"
	      fi
	    done ;;
  *) cat <<'USAGE'
Run from the extracted package directory:
  bash fabric.sh copy-switches [all|leaf-01]
  bash fabric.sh switch-check [all|leaf-01]
  bash fabric.sh switch-stage leaf-01
  bash fabric.sh switch-apply leaf-01
  bash fabric.sh switch-validate [all|leaf-01]
  bash fabric.sh copy-servers [all|weka40]
  bash fabric.sh server-check [all|weka40]
  bash fabric.sh server-stage weka40
  bash fabric.sh server-apply weka40
  bash fabric.sh server-validate [all|weka40]
  bash fabric.sh switch-end-to-end [all|leaf-01]

Use one leaf/server at a time for apply operations. Read README.md first.
USAGE
  ;;
esac
