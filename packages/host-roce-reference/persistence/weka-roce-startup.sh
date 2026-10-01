#!/usr/bin/env bash

set -Eeuo pipefail

CONFIG_FILE="/etc/weka-roce.conf"

log()
{
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*"
}

fail()
{
    log "ERROR: $*"
    exit 1
}

get_ibdev()
{
    local nic="$1"
    local mappings=""

    mappings="$(ibdev2netdev 2>/dev/null || true)"

    awk -v nic="${nic}" \
        '$5 == nic {print $1; exit}' <<<"${mappings}"
}

[[ -r "${CONFIG_FILE}" ]] ||
    fail "Configuration file missing: ${CONFIG_FILE}"

# shellcheck source=/etc/weka-roce.conf
source "${CONFIG_FILE}"

WAIT_TIMEOUT="${WAIT_TIMEOUT:-300}"
WAIT_INTERVAL="${WAIT_INTERVAL:-2}"

for command_name in ip ethtool ibdev2netdev; do
    command -v "${command_name}" >/dev/null 2>&1 ||
        fail "Required command missing: ${command_name}"
done

for nic in "${ROCE_NICS[@]}"; do
    elapsed=0

    log "Waiting for ${nic} and its RDMA device"

    while (( elapsed < WAIT_TIMEOUT )); do
        ibdev="$(get_ibdev "${nic}" || true)"

        if [[ -e "/sys/class/net/${nic}" ]] &&
           ip link show dev "${nic}" >/dev/null 2>&1 &&
           ethtool -i "${nic}" >/dev/null 2>&1 &&
           [[ -n "${ibdev}" ]] &&
           [[ -d "/sys/class/infiniband/${ibdev}" ]]; then

            log "${nic} is ready and mapped to ${ibdev}"
            break
        fi

        sleep "${WAIT_INTERVAL}"
        elapsed=$((elapsed + WAIT_INTERVAL))
    done

    if (( elapsed >= WAIT_TIMEOUT )); then
        fail "${nic} or its RDMA device was not ready after ${WAIT_TIMEOUT} seconds"
    fi
done

exec /usr/local/sbin/weka-roce-config.sh
