#!/usr/bin/env bash

# Inventory CX-7 ports on WEKA clients before assigning server-facing /31s.
# Defaults:
#   Hosts: weka40 through weka79
#   Excluded: weka64, weka78 and weka79
#   Expected CX-7 ports: 4 on weka40-55, 2 on weka56-79
#
# Optional overrides:
#   EXCLUDE_HOSTS="64 78 79" bash cx7_ready_server_inventory.sh
#   HOSTS="40 41 42" bash cx7_ready_server_inventory.sh
#   SSH_USER=root bash cx7_ready_server_inventory.sh

set -u

SSH_USER="${SSH_USER:-root}"
SSH_CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT:-8}"
EXCLUDE_HOSTS="${EXCLUDE_HOSTS:-64 78 79}"

if [ -n "${HOSTS:-}" ]; then
    HOST_LIST="$HOSTS"
else
    HOST_LIST=""
    HOST_NUMBER=40
    while [ "$HOST_NUMBER" -le 79 ]; do
        HOST_LIST="$HOST_LIST $HOST_NUMBER"
        HOST_NUMBER=$((HOST_NUMBER + 1))
    done
fi

RUN_STAMP="$(date +%Y%m%d_%H%M%S)"
REPORT_DIR="${HOME}/Downloads"
REPORT="${REPORT_DIR}/CX7_ready_server_inventory_${RUN_STAMP}.txt"
mkdir -p "$REPORT_DIR"

USE_SSHPASS=0
if command -v sshpass >/dev/null 2>&1; then
    USE_SSHPASS=1
    printf 'Root SSH password (input hidden): '
    IFS= read -r -s SSHPASS
    printf '\n'
    export SSHPASS
fi

cleanup_password() {
    if [ "$USE_SSHPASS" -eq 1 ]; then
        unset SSHPASS
    fi
}
trap cleanup_password EXIT HUP INT TERM

is_excluded() {
    CHECK_NUMBER="$1"
    for EXCLUDED_NUMBER in $EXCLUDE_HOSTS; do
        if [ "$CHECK_NUMBER" = "$EXCLUDED_NUMBER" ]; then
            return 0
        fi
    done
    return 1
}

run_ssh() {
    if [ "$USE_SSHPASS" -eq 1 ]; then
        sshpass -e ssh "$@"
    else
        ssh "$@"
    fi
}

{
    echo "NIC|HOST|PCI|RDMA|NETDEV|MAC|RUNTIME|RDMA_STATE|OPER|SPEED_MBPS|MTU|IPV4|FW_VERSION|FW_MODE"

    for HOST_NUMBER in $HOST_LIST; do
        if is_excluded "$HOST_NUMBER"; then
            echo "SKIP|weka${HOST_NUMBER}|excluded"
            continue
        fi

        if [ "$HOST_NUMBER" -le 55 ]; then
            EXPECTED_PORTS=4
        else
            EXPECTED_PORTS=2
        fi

        HOSTNAME_EXPECTED="weka${HOST_NUMBER}"
        HOST_IP="172.31.18.${HOST_NUMBER}"

        echo
        echo "===== ${HOSTNAME_EXPECTED} ${HOST_IP} expected=${EXPECTED_PORTS} ====="

        if ! run_ssh \
            -o ConnectTimeout="$SSH_CONNECT_TIMEOUT" \
            -o ServerAliveInterval=10 \
            -o ServerAliveCountMax=2 \
            -o StrictHostKeyChecking=accept-new \
            "${SSH_USER}@${HOST_IP}" \
            "EXPECTED_PORTS='${EXPECTED_PORTS}' HOST_IP='${HOST_IP}' bash -s" <<'REMOTE_SCRIPT'
set -u

HOST="$(hostname -s)"
FOUND=0
BAD_MODE=0

for RDMA_PATH in /sys/class/infiniband/*; do
    [ -d "$RDMA_PATH" ] || continue

    RDMA_DEVICE="${RDMA_PATH##*/}"
    PORT_PATH=""

    for CANDIDATE_PORT in "$RDMA_PATH"/ports/*; do
        if [ -d "$CANDIDATE_PORT" ]; then
            PORT_PATH="$CANDIDATE_PORT"
            break
        fi
    done

    if [ -n "$PORT_PATH" ]; then
        RUNTIME="$(cat "$PORT_PATH/link_layer" 2>/dev/null)"
        RDMA_STATE="$(cat "$PORT_PATH/state" 2>/dev/null | tr ' ' '_')"
    else
        RUNTIME="unknown"
        RDMA_STATE="unknown"
    fi

    [ -n "$RUNTIME" ] || RUNTIME="unknown"
    [ -n "$RDMA_STATE" ] || RDMA_STATE="unknown"

    if [ "$RUNTIME" != "Ethernet" ]; then
        BAD_MODE=1
    fi

    for NET_PATH in "$RDMA_PATH"/device/net/*; do
        [ -d "$NET_PATH" ] || continue

        NETDEV="${NET_PATH##*/}"
        PCI_BDF="$(basename "$(readlink -f "/sys/class/net/$NETDEV/device")")"
        MAC="$(cat "/sys/class/net/$NETDEV/address" 2>/dev/null)"
        OPER="$(cat "/sys/class/net/$NETDEV/operstate" 2>/dev/null)"
        SPEED="$(cat "/sys/class/net/$NETDEV/speed" 2>/dev/null)"
        MTU="$(cat "/sys/class/net/$NETDEV/mtu" 2>/dev/null)"
        IPV4="$(ip -4 -o address show dev "$NETDEV" 2>/dev/null | awk '{print $4}' | paste -sd, -)"
        FW_VERSION="$(ethtool -i "$NETDEV" 2>/dev/null | awk -F': ' '/firmware-version:/ {print $2; exit}')"
        FW_MODE="$(mlxconfig -d "$PCI_BDF" q 2>/dev/null | awk '$1 ~ /^LINK_TYPE_P[12]$/ {print $1 "=" $2}' | paste -sd, -)"

        [ -n "$MAC" ] || MAC="unknown"
        [ -n "$OPER" ] || OPER="unknown"
        [ -n "$SPEED" ] || SPEED="unknown"
        [ -n "$MTU" ] || MTU="unknown"
        [ -n "$IPV4" ] || IPV4="none"
        [ -n "$FW_VERSION" ] || FW_VERSION="unknown"
        [ -n "$FW_MODE" ] || FW_MODE="unknown"

        FOUND=$((FOUND + 1))

        echo "NIC|$HOST|$PCI_BDF|$RDMA_DEVICE|$NETDEV|$MAC|$RUNTIME|$RDMA_STATE|$OPER|$SPEED|$MTU|$IPV4|$FW_VERSION|$FW_MODE"
    done
done

if [ "$FOUND" -eq "$EXPECTED_PORTS" ] && [ "$BAD_MODE" -eq 0 ]; then
    STATUS="PASS"
else
    STATUS="CHECK"
fi

echo "COUNT|$HOST|found=$FOUND|expected=$EXPECTED_PORTS|$STATUS"
REMOTE_SCRIPT
        then
            SSH_STATUS=$?
            echo "UNREACHABLE|${HOSTNAME_EXPECTED}|${HOST_IP}|ssh-status-${SSH_STATUS}"
        fi
    done
} 2>&1 | tee "$REPORT"

cleanup_password
trap - EXIT HUP INT TERM

echo
echo "===== SUMMARY ====="
grep -E '^(COUNT|SKIP|UNREACHABLE)\|' "$REPORT" || true
echo
echo "Detected CX-7 interfaces: $(grep -c '^NIC|weka' "$REPORT" 2>/dev/null || true)"
echo "Report: $REPORT"

