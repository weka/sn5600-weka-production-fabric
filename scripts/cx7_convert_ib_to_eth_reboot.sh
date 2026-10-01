#!/usr/bin/env bash

# Scan NVIDIA/Mellanox RDMA adapters, convert firmware port mode from
# InfiniBand to Ethernet when required, and reboot only changed hosts.
#
# Run from the management workstation:
#   bash cx7_convert_ib_to_eth_reboot.sh --check
#   HOSTS="64" bash cx7_convert_ib_to_eth_reboot.sh --apply
#   HOSTS="64" bash cx7_convert_ib_to_eth_reboot.sh --validate
#   bash cx7_convert_ib_to_eth_reboot.sh --apply
#   bash cx7_convert_ib_to_eth_reboot.sh --validate

set -u

MODE="${1:---check}"
case "$MODE" in
    --check|--apply|--validate) ;;
    *)
        echo "Usage: $0 [--check|--apply|--validate]"
        exit 2
        ;;
esac

SSH_USER="${SSH_USER:-root}"
SSH_CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT:-7}"

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

if [ "$MODE" = "--apply" ]; then
    echo "WARNING: This can change CX adapter firmware settings and reboot hosts."
    echo "Stop application and WEKA I/O first, and confirm BMC console access."
    echo
    printf "Type CONVERT-TO-ETHERNET to continue: "
    read -r CONFIRMATION
    if [ "$CONFIRMATION" != "CONVERT-TO-ETHERNET" ]; then
        echo "Cancelled."
        exit 1
    fi
fi

RUN_STAMP="$(date +%Y%m%d_%H%M%S)"
LOG_DIR="${HOME}/Downloads/CX7_IB_to_ETH_${MODE#--}_${RUN_STAMP}"
mkdir -p "$LOG_DIR"

echo "Mode: $MODE"
echo "SSH user: $SSH_USER"
echo "Hosts: $HOST_LIST"
echo "Logs: $LOG_DIR"

for HOST_NUMBER in $HOST_LIST; do
    HOSTNAME_EXPECTED="weka${HOST_NUMBER}"
    HOST_IP="172.31.18.${HOST_NUMBER}"
    HOST_LOG="$LOG_DIR/${HOSTNAME_EXPECTED}_${HOST_IP}.log"

    echo
    echo "[$HOSTNAME_EXPECTED] $MODE at $HOST_IP"

    if ssh \
        -o ConnectTimeout="$SSH_CONNECT_TIMEOUT" \
        -o ServerAliveInterval=10 \
        -o ServerAliveCountMax=2 \
        -o StrictHostKeyChecking=accept-new \
        "${SSH_USER}@${HOST_IP}" \
        "REQUESTED_MODE='$MODE' EXPECTED_HOST='$HOSTNAME_EXPECTED' HOST_IP='$HOST_IP' bash -s" \
        >"$HOST_LOG" <<'REMOTE_SCRIPT'
set -u

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR|${EXPECTED_HOST}|root login is required"
    exit 10
fi

ACTUAL_HOST="$(hostname -s)"
echo "HOST|$ACTUAL_HOST|$HOST_IP|$REQUESTED_MODE"

if ! command -v mlxconfig >/dev/null 2>&1; then
    echo "ERROR|$ACTUAL_HOST|mlxconfig is not installed"
    exit 11
fi

PCI_LIST="$({
    for DEVICE_PATH in /sys/class/infiniband/*; do
        [ -d "$DEVICE_PATH" ] || continue
        basename "$(readlink -f "$DEVICE_PATH/device")"
    done
} | sort -u)"

if [ -z "$PCI_LIST" ]; then
    echo "ERROR|$ACTUAL_HOST|no RDMA devices found"
    exit 12
fi

RUNTIME_IB=0
FIRMWARE_IB=0
CHANGE_APPLIED=0
CONFIG_ERROR=0

echo "SECTION|runtime-link-layer"
for DEVICE_PATH in /sys/class/infiniband/*; do
    [ -d "$DEVICE_PATH" ] || continue

    RDMA_DEVICE="${DEVICE_PATH##*/}"
    PCI_BDF="$(basename "$(readlink -f "$DEVICE_PATH/device")")"
    NETDEVS="$(ls "$DEVICE_PATH/device/net" 2>/dev/null | paste -sd, -)"

    for PORT_PATH in "$DEVICE_PATH"/ports/*; do
        [ -d "$PORT_PATH" ] || continue

        PORT_NUMBER="${PORT_PATH##*/}"
        LINK_LAYER="$(cat "$PORT_PATH/link_layer")"
        PORT_STATE="$(cat "$PORT_PATH/state")"

        echo "RUNTIME|$ACTUAL_HOST|$PCI_BDF|$RDMA_DEVICE|$PORT_NUMBER|$LINK_LAYER|$NETDEVS|$PORT_STATE"

        if [ "$LINK_LAYER" = "InfiniBand" ]; then
            RUNTIME_IB=1
        fi
    done
done

echo "SECTION|firmware-link-type"
for PCI_BDF in $PCI_LIST; do
    QUERY_OUTPUT="$(mlxconfig -d "$PCI_BDF" q 2>&1)"
    QUERY_STATUS=$?

    if [ "$QUERY_STATUS" -ne 0 ]; then
        echo "ERROR|$ACTUAL_HOST|$PCI_BDF|mlxconfig query failed"
        printf '%s\n' "$QUERY_OUTPUT"
        CONFIG_ERROR=1
        continue
    fi

    printf '%s\n' "$QUERY_OUTPUT" |
        grep -E 'Device type:|Name:|Description:|Device:|LINK_TYPE_P[12]' |
        sed "s/^/FIRMWARE|$ACTUAL_HOST|$PCI_BDF|/"

    SET_ARGUMENTS=""

    if printf '%s\n' "$QUERY_OUTPUT" |
        grep -Eq 'LINK_TYPE_P1[[:space:]]+IB\(1\)'; then
        SET_ARGUMENTS="$SET_ARGUMENTS LINK_TYPE_P1=2"
        FIRMWARE_IB=1
    fi

    if printf '%s\n' "$QUERY_OUTPUT" |
        grep -Eq 'LINK_TYPE_P2[[:space:]]+IB\(1\)'; then
        SET_ARGUMENTS="$SET_ARGUMENTS LINK_TYPE_P2=2"
        FIRMWARE_IB=1
    fi

    if [ -n "$SET_ARGUMENTS" ]; then
        echo "PLAN|$ACTUAL_HOST|$PCI_BDF|mlxconfig set$SET_ARGUMENTS"

        if [ "$REQUESTED_MODE" = "--apply" ]; then
            # Intentional word splitting: SET_ARGUMENTS contains mlxconfig key=value arguments.
            if mlxconfig -y -d "$PCI_BDF" set $SET_ARGUMENTS; then
                echo "APPLY|$ACTUAL_HOST|$PCI_BDF|SUCCESS|$SET_ARGUMENTS"
                CHANGE_APPLIED=1
            else
                echo "APPLY|$ACTUAL_HOST|$PCI_BDF|FAILED|$SET_ARGUMENTS"
                CONFIG_ERROR=1
            fi
        fi
    else
        echo "PLAN|$ACTUAL_HOST|$PCI_BDF|no firmware change required"
    fi
done

if [ "$REQUESTED_MODE" = "--check" ]; then
    if [ "$RUNTIME_IB" -eq 1 ] || [ "$FIRMWARE_IB" -eq 1 ]; then
        echo "CHECK|$ACTUAL_HOST|IB_FOUND"
    elif [ "$CONFIG_ERROR" -eq 1 ]; then
        echo "CHECK|$ACTUAL_HOST|INCOMPLETE"
    else
        echo "CHECK|$ACTUAL_HOST|ALL_ETHERNET"
    fi
fi

if [ "$REQUESTED_MODE" = "--validate" ]; then
    if [ "$RUNTIME_IB" -eq 1 ] || [ "$FIRMWARE_IB" -eq 1 ]; then
        echo "VALIDATION|$ACTUAL_HOST|FAIL|IB remains present"
    elif [ "$CONFIG_ERROR" -eq 1 ]; then
        echo "VALIDATION|$ACTUAL_HOST|INCOMPLETE|configuration query error"
    else
        echo "VALIDATION|$ACTUAL_HOST|PASS|all discovered RDMA ports are Ethernet"
    fi
fi

if [ "$REQUESTED_MODE" = "--apply" ]; then
    if [ "$CONFIG_ERROR" -eq 1 ]; then
        echo "REBOOT|$ACTUAL_HOST|NOT_SCHEDULED|configuration error"
        exit 20
    fi

    if [ "$CHANGE_APPLIED" -eq 1 ] || [ "$RUNTIME_IB" -eq 1 ]; then
        echo "REBOOT|$ACTUAL_HOST|SCHEDULED|5 seconds"
        sync
        nohup sh -c 'sleep 5; systemctl reboot' >/dev/null 2>&1 &
    else
        echo "REBOOT|$ACTUAL_HOST|NOT_REQUIRED|already Ethernet"
    fi
fi

exit 0
REMOTE_SCRIPT
    then
        STATUS_LINE="$(grep -E '^(CHECK|VALIDATION|REBOOT)\|' "$HOST_LOG" | tail -n 1)"
        if [ -n "$STATUS_LINE" ]; then
            echo "$STATUS_LINE"
        else
            echo "Completed; inspect $HOST_LOG"
        fi
    else
        SSH_STATUS=$?
        echo "UNREACHABLE|$HOSTNAME_EXPECTED|$HOST_IP|ssh-status-$SSH_STATUS" >> "$HOST_LOG"
        echo "Unable to complete $HOSTNAME_EXPECTED; inspect $HOST_LOG"
    fi
done

SUMMARY_FILE="$LOG_DIR/summary.txt"
grep -h -E '^(HOST|RUNTIME|PLAN|APPLY|CHECK|VALIDATION|REBOOT|ERROR|UNREACHABLE)\|' \
    "$LOG_DIR"/*.log > "$SUMMARY_FILE" 2>/dev/null || true

ARCHIVE_PATH="${LOG_DIR}.zip"
(
    cd "$(dirname "$LOG_DIR")" || exit 1
    zip -qr "$(basename "$ARCHIVE_PATH")" "$(basename "$LOG_DIR")"
)

echo
echo "Summary: $SUMMARY_FILE"
echo "Archive: $ARCHIVE_PATH"

case "$MODE" in
    --check)
        echo "Review CHECK and PLAN lines before running --apply."
        ;;
    --apply)
        echo "After the hosts return, run the same script with --validate."
        ;;
    --validate)
        echo "Every converted host should report VALIDATION|<host>|PASS."
        ;;
esac

