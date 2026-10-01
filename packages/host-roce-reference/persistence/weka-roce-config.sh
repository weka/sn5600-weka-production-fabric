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

required_commands=(
    ip
    ethtool
    ibdev2netdev
    mlnx_qos
    cma_roce_tos
    sysctl
    grep
    awk
)

for command_name in "${required_commands[@]}"; do
    command -v "${command_name}" >/dev/null 2>&1 ||
        fail "Required command missing: ${command_name}"
done

(( ${#ROCE_NICS[@]} > 0 )) ||
    fail "No RoCE interfaces configured"

log "Setting TCP ECN to 1"
sysctl -w net.ipv4.tcp_ecn=1 >/dev/null

for nic in "${ROCE_NICS[@]}"; do
    [[ -e "/sys/class/net/${nic}" ]] ||
        fail "Interface missing: ${nic}"

    ibdev="$(get_ibdev "${nic}")"

    [[ -n "${ibdev}" ]] ||
        fail "No RDMA mapping found for ${nic}"

    tc_file="/sys/class/infiniband/${ibdev}/tc/1/traffic_class"

    [[ -w "${tc_file}" ]] ||
        fail "Traffic-class file is not writable: ${tc_file}"

    log "${nic}: setting DSCP trust"
    mlnx_qos -i "${nic}" \
        --trust dscp \
        >/dev/null

    log "${nic}: enabling PFC priority 3"
    mlnx_qos -i "${nic}" \
        --pfc 0,0,0,1,0,0,0,0 \
        >/dev/null

    log "${ibdev}: setting traffic class ${ROCE_TOS}"
    echo "${ROCE_TOS}" >"${tc_file}"

    log "${ibdev}: setting CMA RoCE TOS ${ROCE_TOS}"
    cma_roce_tos \
        -d "${ibdev}" \
        -t "${ROCE_TOS}" \
        >/dev/null
done

log "Verifying RoCE configuration"

tcp_ecn="$(sysctl -n net.ipv4.tcp_ecn)"

[[ "${tcp_ecn}" == "1" ]] ||
    fail "TCP ECN is ${tcp_ecn}; expected 1"

for nic in "${ROCE_NICS[@]}"; do
    ibdev="$(get_ibdev "${nic}")"
    tc_file="/sys/class/infiniband/${ibdev}/tc/1/traffic_class"

    qos_output="$(mlnx_qos -i "${nic}")"
    tc_output="$(cat "${tc_file}")"

    grep -q \
        'Priority trust state: dscp' \
        <<<"${qos_output}" ||
        fail "${nic}: DSCP trust validation failed"

    grep -Eq \
        'enabled[[:space:]]+0[[:space:]]+0[[:space:]]+0[[:space:]]+1[[:space:]]+0[[:space:]]+0[[:space:]]+0[[:space:]]+0' \
        <<<"${qos_output}" ||
        fail "${nic}: PFC priority 3 validation failed"

    current_tos=""

    if [[ "${tc_output}" =~ ([0-9]+)$ ]]; then
        current_tos="${BASH_REMATCH[1]}"
    fi

    [[ "${current_tos}" == "${ROCE_TOS}" ]] ||
        fail "${ibdev}: traffic class '${tc_output}', expected ${ROCE_TOS}"

    log "${nic}/${ibdev}: DSCP trust verified"
    log "${nic}/${ibdev}: PFC priority 3 verified"
    log "${nic}/${ibdev}: traffic class ${ROCE_TOS} verified"
done

log "RoCE configuration and verification completed successfully"
