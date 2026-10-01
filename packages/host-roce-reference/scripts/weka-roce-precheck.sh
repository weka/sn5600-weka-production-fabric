#!/usr/bin/env bash

###############################################################################
# WEKA RoCE Read-Only Pre-Check
#
# This script does NOT:
#   - Change RoCE or NIC settings
#   - Stop or restart WEKA
#   - Restart containers
#   - Modify systemd
#   - Reboot the host
#
# Automatic role detection:
#   Backend:
#     Local drives*, compute*, or ssdproxy containers are present
#     Default expected TOS: 96
#
#   Client:
#     No backend containers are present
#     Default expected TOS: 106
#
# Examples:
#
#   Automatic detection:
#     /root/weka-roce-precheck.sh
#
#   Automatic role with explicit NICs:
#     /root/weka-roce-precheck.sh \
#       --nics eno16795np0,eno16595np0
#
#   Explicit backend:
#     /root/weka-roce-precheck.sh \
#       --role backend \
#       --nics eno16795np0,eno16595np0 \
#       --expected-tos 96
#
#   Explicit client:
#     /root/weka-roce-precheck.sh \
#       --role client \
#       --nics ens4047f0np0,ens4047f1np1 \
#       --expected-tos 106
###############################################################################

set -uo pipefail

REQUESTED_ROLE="auto"
DETECTED_ROLE=""
NIC_LIST=""
EXPECTED_TOS=""
REPORT_DIR="/root/roce-precheck-reports"

declare -a SUMMARY_CHECK=()
declare -a SUMMARY_STATE=()
declare -a SUMMARY_DETAIL=()
declare -a ROCE_NICS=()

###############################################################################
# Common functions
###############################################################################

usage()
{
    cat <<'EOF'
Usage:
  weka-roce-precheck.sh \
    [--role auto|backend|client] \
    [--nics NIC1,NIC2] \
    [--expected-tos VALUE]

Options:
  --role
      auto, backend, or client

      Default: auto

      Automatic detection considers the host a backend when local
      drives*, compute*, or ssdproxy containers are present.

  --nics
      Comma-separated RoCE Ethernet interfaces.

      If omitted, all Ethernet interfaces mapped to mlx5 RDMA
      devices are checked.

  --expected-tos
      Expected RoCE traffic class/TOS.

      Default:
        Backend: 96
        Client:  106

  --help
      Display this help message.

Examples:

  Automatic:
    /root/weka-roce-precheck.sh

  Backend:
    /root/weka-roce-precheck.sh \
      --role backend \
      --nics eno16795np0,eno16595np0 \
      --expected-tos 96

  Client:
    /root/weka-roce-precheck.sh \
      --role client \
      --nics ens4047f0np0,ens4047f1np1 \
      --expected-tos 106
EOF
}

section()
{
    echo
    echo "================================================================"
    echo "$1"
    echo "================================================================"
}

add_result()
{
    SUMMARY_CHECK+=("$1")
    SUMMARY_STATE+=("$2")
    SUMMARY_DETAIL+=("$3")
}

command_exists()
{
    command -v "$1" >/dev/null 2>&1
}

sanitize_output()
{
    tr -d '\000'
}

get_ibdev()
{
    local nic="$1"
    local mappings=""

    if command_exists ibdev2netdev; then
        mappings="$(ibdev2netdev 2>/dev/null || true)"
    fi

    awk -v nic="${nic}" \
        '$5 == nic {print $1; exit}' <<<"${mappings}"
}

get_netdev()
{
    local ibdev="$1"
    local mappings=""

    if command_exists ibdev2netdev; then
        mappings="$(ibdev2netdev 2>/dev/null || true)"
    fi

    awk -v ibdev="${ibdev}" \
        '$1 == ibdev {print $5; exit}' <<<"${mappings}"
}

print_summary_table()
{
    printf "%-36s %-7s %s\n" \
        "CHECK" \
        "RESULT" \
        "DETAIL"

    printf "%-36s %-7s %s\n" \
        "------------------------------------" \
        "-------" \
        "------------------------------------------------"
}

###############################################################################
# Parse command-line options
###############################################################################

while [[ $# -gt 0 ]]; do
    case "$1" in
        --role)
            REQUESTED_ROLE="${2:-}"
            shift 2
            ;;

        --nics)
            NIC_LIST="${2:-}"
            shift 2
            ;;

        --expected-tos)
            EXPECTED_TOS="${2:-}"
            shift 2
            ;;

        --help|-h)
            usage
            exit 0
            ;;

        *)
            echo "ERROR: Unknown option: $1"
            usage
            exit 2
            ;;
    esac
done

case "${REQUESTED_ROLE}" in
    auto|backend|client)
        ;;

    *)
        echo "ERROR: --role must be auto, backend, or client"
        exit 2
        ;;
esac

if [[ -n "${EXPECTED_TOS}" ]] &&
   [[ ! "${EXPECTED_TOS}" =~ ^[0-9]+$ ]]; then
    echo "ERROR: --expected-tos must be numeric"
    exit 2
fi

###############################################################################
# Initialize report
###############################################################################

HOST="$(hostname -s)"
STAMP="$(date '+%Y%m%d-%H%M%S')"

mkdir -p "${REPORT_DIR}"

REPORT="${REPORT_DIR}/${HOST}-roce-precheck-${STAMP}.log"

exec > >(tee "${REPORT}") 2>&1

###############################################################################
# Required command validation
###############################################################################

section "1. REQUIRED COMMANDS"

required_commands=(
    weka
    ip
    ethtool
    ibdev2netdev
    rdma
    mlnx_qos
    sysctl
    systemctl
    journalctl
    findmnt
    awk
    sed
    grep
    sort
    head
    tail
    tr
    wc
)

missing_commands=0

for command_name in "${required_commands[@]}"; do
    if command_exists "${command_name}"; then
        printf "PASS  %s\n" "${command_name}"
    else
        printf "FAIL  %s is missing\n" "${command_name}"
        missing_commands=$((missing_commands + 1))
    fi
done

if (( missing_commands == 0 )); then
    add_result \
        "Required commands" \
        "PASS" \
        "All required commands are available"
else
    add_result \
        "Required commands" \
        "FAIL" \
        "${missing_commands} required command(s) missing"
fi

###############################################################################
# Obtain local WEKA container information and detect role
###############################################################################

WEKA_LOCAL_PS=""
WEKA_LOCAL_PS_RC=0

if command_exists weka; then
    WEKA_LOCAL_PS="$(
        weka local ps 2>&1 |
        sanitize_output
    )" || WEKA_LOCAL_PS_RC=$?
fi

backend_container_count="$(
    awk '
        NR == 1 {
            next
        }

        $1 ~ /^(drives|compute|ssdproxy)/ {
            count++
        }

        END {
            print count + 0
        }
    ' <<<"${WEKA_LOCAL_PS}"
)"

all_container_count="$(
    awk '
        NR == 1 {
            next
        }

        NF > 0 &&
        $1 !~ /^error:/ &&
        $1 != "Error:" {
            count++
        }

        END {
            print count + 0
        }
    ' <<<"${WEKA_LOCAL_PS}"
)"

if [[ "${REQUESTED_ROLE}" == "auto" ]]; then
    if (( backend_container_count > 0 )); then
        DETECTED_ROLE="backend"
        ROLE_REASON="${backend_container_count} backend container(s) detected"
    else
        DETECTED_ROLE="client"
        ROLE_REASON="No backend containers detected"
    fi
else
    DETECTED_ROLE="${REQUESTED_ROLE}"
    ROLE_REASON="Role explicitly provided"
fi

if [[ -z "${EXPECTED_TOS}" ]]; then
    if [[ "${DETECTED_ROLE}" == "backend" ]]; then
        EXPECTED_TOS=96
    else
        EXPECTED_TOS=106
    fi
fi

###############################################################################
# Header
###############################################################################

echo
echo "WEKA RoCE Read-Only Pre-Check"
echo
echo "Host:             ${HOST}"
echo "Requested role:   ${REQUESTED_ROLE}"
echo "Detected role:    ${DETECTED_ROLE}"
echo "Role reason:      ${ROLE_REASON}"
echo "Expected TOS:     ${EXPECTED_TOS}"
echo "Date:             $(date)"
echo "Report:           ${REPORT}"
echo
echo "No configuration changes will be made."

add_result \
    "Host role" \
    "PASS" \
    "${DETECTED_ROLE}; ${ROLE_REASON}"

###############################################################################
# System information
###############################################################################

section "2. SYSTEM INFORMATION"

date
hostnamectl 2>/dev/null || hostname
uptime
uname -r

###############################################################################
# WEKA cluster status
###############################################################################

section "3. WEKA CLUSTER STATUS"

WEKA_STATUS=""
WEKA_STATUS_RC=0

if command_exists weka; then
    WEKA_STATUS="$(
        weka status 2>&1 |
        sanitize_output
    )" || WEKA_STATUS_RC=$?

    echo "${WEKA_STATUS}"

    if grep -Eq \
       'status:[[:space:]]+OK' \
       <<<"${WEKA_STATUS}"; then

        add_result \
            "WEKA cluster status" \
            "PASS" \
            "Cluster reports OK"

        protection_detail="$(
            grep -E 'protection:' <<<"${WEKA_STATUS}" |
            head -1 |
            sed 's/^[[:space:]]*//' ||
            true
        )"

        if grep -Eq \
           'protection:.*fully protected' \
           <<<"${WEKA_STATUS}"; then

            add_result \
                "WEKA protection" \
                "PASS" \
                "${protection_detail}"
        else
            add_result \
                "WEKA protection" \
                "FAIL" \
                "${protection_detail:-Cluster is not fully protected}"
        fi

    elif [[ "${DETECTED_ROLE}" == "client" ]] &&
         grep -Eq \
         'Failed connecting to http://127\.0\.0\.1:14000|weka local status' \
         <<<"${WEKA_STATUS}"; then

        add_result \
            "WEKA cluster status" \
            "INFO" \
            "Local cluster API unavailable on containerless client"

        add_result \
            "WEKA protection" \
            "INFO" \
            "Validate protection from backend or management host"

    else
        if [[ "${DETECTED_ROLE}" == "backend" ]]; then
            add_result \
                "WEKA cluster status" \
                "FAIL" \
                "Backend does not report cluster status OK"

            add_result \
                "WEKA protection" \
                "FAIL" \
                "Protection status unavailable"
        else
            add_result \
                "WEKA cluster status" \
                "WARN" \
                "Unable to validate cluster status locally"

            add_result \
                "WEKA protection" \
                "INFO" \
                "Validate protection from backend or management host"
        fi
    fi
else
    echo "weka command unavailable"

    add_result \
        "WEKA cluster status" \
        "FAIL" \
        "weka command unavailable"

    add_result \
        "WEKA protection" \
        "FAIL" \
        "Unable to validate protection"
fi

###############################################################################
# WEKA alerts
###############################################################################

section "4. WEKA ALERT DETAILS"

WEKA_ALERTS=""
WEKA_ALERTS_RC=0

if command_exists weka; then
    WEKA_ALERTS="$(
        weka alerts 2>&1 |
        sanitize_output
    )" || WEKA_ALERTS_RC=$?

    echo "${WEKA_ALERTS}"

    if (( WEKA_ALERTS_RC == 0 )); then
        alert_count="$(
            awk '
                NR == 1 {
                    next
                }

                NF > 0 {
                    count++
                }

                END {
                    print count + 0
                }
            ' <<<"${WEKA_ALERTS}"
        )"

        if (( alert_count == 0 )); then
            add_result \
                "WEKA active alerts" \
                "PASS" \
                "No active alerts"
        else
            add_result \
                "WEKA active alerts" \
                "WARN" \
                "${alert_count} active alert(s); review before maintenance"
        fi

    elif [[ "${DETECTED_ROLE}" == "client" ]] &&
         grep -Eq \
         'Failed connecting to http://127\.0\.0\.1:14000|weka local status' \
         <<<"${WEKA_ALERTS}"; then

        add_result \
            "WEKA active alerts" \
            "INFO" \
            "Local alert API unavailable on containerless client"

    else
        if [[ "${DETECTED_ROLE}" == "backend" ]]; then
            add_result \
                "WEKA active alerts" \
                "WARN" \
                "Unable to query backend alerts"
        else
            add_result \
                "WEKA active alerts" \
                "INFO" \
                "Validate alerts from backend or management host"
        fi
    fi
else
    echo "weka command unavailable"

    add_result \
        "WEKA active alerts" \
        "WARN" \
        "weka command unavailable"
fi

###############################################################################
# Local WEKA containers
###############################################################################

section "5. LOCAL WEKA CONTAINERS"

echo "${WEKA_LOCAL_PS}"

unhealthy_container_count=0
nonpersistent_container_count=0

while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    [[ "${line}" == CONTAINER* ]] && continue
    [[ "${line}" == error:* ]] && continue
    [[ "${line}" == Error:* ]] && continue

    if ! grep -qE \
       '[[:space:]]Running[[:space:]]' \
       <<<"${line}" ||
       ! grep -qE \
       '[[:space:]]Ready[[:space:]]' \
       <<<"${line}"; then

        unhealthy_container_count=$((unhealthy_container_count + 1))
    fi

    if ! grep -qE \
       '[[:space:]]True[[:space:]]+[0-9]+' \
       <<<"${line}"; then

        nonpersistent_container_count=$((nonpersistent_container_count + 1))
    fi
done <<<"${WEKA_LOCAL_PS}"

if [[ "${DETECTED_ROLE}" == "backend" ]]; then
    if (( backend_container_count == 0 )); then
        add_result \
            "Local WEKA containers" \
            "FAIL" \
            "No backend containers found"
    elif (( unhealthy_container_count > 0 )); then
        add_result \
            "Local WEKA containers" \
            "FAIL" \
            "${unhealthy_container_count} unhealthy container(s)"
    elif (( nonpersistent_container_count > 0 )); then
        add_result \
            "Local WEKA containers" \
            "WARN" \
            "${nonpersistent_container_count} container(s) may not be persistent"
    else
        add_result \
            "Local WEKA containers" \
            "PASS" \
            "${all_container_count} container(s), all Running and Ready"
    fi
else
    if (( all_container_count == 0 )); then
        add_result \
            "Local WEKA containers" \
            "PASS" \
            "No local client containers configured"
    elif (( unhealthy_container_count == 0 )); then
        add_result \
            "Local WEKA containers" \
            "PASS" \
            "${all_container_count} local client container(s), all healthy"
    else
        add_result \
            "Local WEKA containers" \
            "WARN" \
            "${unhealthy_container_count} local client container(s) unhealthy"
    fi
fi

###############################################################################
# WEKA services
###############################################################################

section "6. WEKA SYSTEMD SERVICES"

for service_name in \
    weka-agent.service \
    weka-bootstrap.service \
    weka-roce.service; do

    echo
    echo "---------------- ${service_name} ----------------"

    systemctl show "${service_name}" \
        -p LoadState \
        -p UnitFileState \
        -p ActiveState \
        -p SubState \
        -p Result \
        -p MainPID \
        2>&1 || true
done

agent_state="$(
    systemctl is-active weka-agent.service 2>/dev/null ||
    true
)"

if [[ "${agent_state}" == "active" ]]; then
    add_result \
        "weka-agent.service" \
        "PASS" \
        "Active and running"
else
    add_result \
        "weka-agent.service" \
        "FAIL" \
        "Current state: ${agent_state:-unknown}"
fi

bootstrap_load_state="$(
    systemctl show weka-bootstrap.service \
        -p LoadState \
        --value 2>/dev/null ||
    true
)"

bootstrap_result="$(
    systemctl show weka-bootstrap.service \
        -p Result \
        --value 2>/dev/null ||
    true
)"

if [[ "${bootstrap_load_state}" == "loaded" ]]; then
    if [[ "${bootstrap_result}" == "success" ||
          -z "${bootstrap_result}" ]]; then

        add_result \
            "weka-bootstrap.service" \
            "PASS" \
            "Unit loaded; last result ${bootstrap_result:-unknown}"
    else
        add_result \
            "weka-bootstrap.service" \
            "WARN" \
            "Unit loaded; last result ${bootstrap_result}"
    fi
else
    add_result \
        "weka-bootstrap.service" \
        "INFO" \
        "Unit not installed"
fi

roce_load_state="$(
    systemctl show weka-roce.service \
        -p LoadState \
        --value 2>/dev/null ||
    true
)"

roce_active_state="$(
    systemctl show weka-roce.service \
        -p ActiveState \
        --value 2>/dev/null ||
    true
)"

roce_result="$(
    systemctl show weka-roce.service \
        -p Result \
        --value 2>/dev/null ||
    true
)"

if [[ "${roce_load_state}" == "loaded" ]]; then
    if [[ "${roce_active_state}" == "active" &&
          "${roce_result}" == "success" ]]; then

        add_result \
            "weka-roce.service" \
            "PASS" \
            "Installed, active, and successful"
    else
        add_result \
            "weka-roce.service" \
            "FAIL" \
            "Installed but state=${roce_active_state}, result=${roce_result}"
    fi
else
    add_result \
        "weka-roce.service" \
        "INFO" \
        "RoCE persistence service not installed"
fi

###############################################################################
# WEKA service dependency ordering
###############################################################################

section "7. WEKA SERVICE DEPENDENCIES"

agent_requires="$(
    systemctl show weka-agent.service \
        -p Requires \
        --value 2>/dev/null ||
    true
)"

agent_after="$(
    systemctl show weka-agent.service \
        -p After \
        --value 2>/dev/null ||
    true
)"

echo "weka-agent Requires:"
echo "${agent_requires}"
echo
echo "weka-agent After:"
echo "${agent_after}"
echo

systemctl show weka-bootstrap.service \
    -p Requires \
    -p Wants \
    -p After \
    -p Before \
    2>&1 || true

if [[ "${roce_load_state}" == "loaded" ]]; then
    if grep -qw \
       'weka-roce.service' \
       <<<"${agent_requires}" &&
       grep -qw \
       'weka-roce.service' \
       <<<"${agent_after}"; then

        add_result \
            "RoCE/WEKA startup order" \
            "PASS" \
            "weka-agent requires and starts after weka-roce"
    else
        add_result \
            "RoCE/WEKA startup order" \
            "FAIL" \
            "weka-agent dependency on weka-roce is incomplete"
    fi
else
    add_result \
        "RoCE/WEKA startup order" \
        "INFO" \
        "Dependency not installed"
fi

###############################################################################
# Active WEKA filesystem mounts
###############################################################################

section "8. ACTIVE WEKA FILESYSTEM MOUNTS"

WEKA_MOUNTS="$(
    findmnt -rn -t wekafs 2>/dev/null ||
    true
)"

if [[ -n "${WEKA_MOUNTS}" ]]; then
    echo "${WEKA_MOUNTS}"

    mount_count="$(
        wc -l <<<"${WEKA_MOUNTS}" |
        tr -d ' '
    )"

    if [[ "${DETECTED_ROLE}" == "client" ]]; then
        add_result \
            "Active WEKA mounts" \
            "INFO" \
            "${mount_count} active wekafs mount(s); maintenance required before restart"
    else
        add_result \
            "Active WEKA mounts" \
            "INFO" \
            "${mount_count} active wekafs mount(s)"
    fi
else
    echo "No active wekafs mounts."

    add_result \
        "Active WEKA mounts" \
        "PASS" \
        "No active wekafs mounts"
fi

###############################################################################
# Discover RoCE NICs
###############################################################################

section "9. ROCE NIC DISCOVERY"

if [[ -n "${NIC_LIST}" ]]; then
    IFS=',' read -r -a ROCE_NICS <<<"${NIC_LIST}"

    for index in "${!ROCE_NICS[@]}"; do
        ROCE_NICS["${index}"]="$(
            sed \
                's/^[[:space:]]*//;s/[[:space:]]*$//' \
                <<<"${ROCE_NICS[${index}]}"
        )"
    done
else
    if command_exists ibdev2netdev; then
        mapfile -t ROCE_NICS < <(
            ibdev2netdev 2>/dev/null |
            awk '$1 ~ /^mlx5_/ {print $5}' |
            sort -u
        )
    fi
fi

echo "Selected RoCE interfaces:"

if (( ${#ROCE_NICS[@]} == 0 )); then
    echo "None"

    add_result \
        "RoCE NIC discovery" \
        "FAIL" \
        "No mlx5 Ethernet interfaces discovered"
else
    printf '  %s\n' "${ROCE_NICS[@]}"

    add_result \
        "RoCE NIC discovery" \
        "PASS" \
        "${#ROCE_NICS[@]} interface(s) selected"
fi

echo
echo "RDMA mapping:"

if command_exists ibdev2netdev; then
    ibdev2netdev 2>&1 || true
fi

echo
echo "RDMA link state:"

if command_exists rdma; then
    rdma link show 2>&1 || true
fi

###############################################################################
# Interface state, speed, MTU and RDMA link
###############################################################################

section "10. NETWORK AND RDMA INTERFACE STATE"

for nic in "${ROCE_NICS[@]}"; do
    echo
    echo "================ ${nic} ================"

    if [[ ! -e "/sys/class/net/${nic}" ]]; then
        echo "Interface not found"

        add_result \
            "${nic} interface" \
            "FAIL" \
            "Interface not found"

        continue
    fi

    ibdev="$(get_ibdev "${nic}")"
    operstate="$(
        cat "/sys/class/net/${nic}/operstate" 2>/dev/null ||
        echo unknown
    )"

    mtu="$(
        cat "/sys/class/net/${nic}/mtu" 2>/dev/null ||
        echo unknown
    )"

    ip -br address show dev "${nic}" 2>&1 || true
    ip -d link show dev "${nic}" 2>&1 || true

    echo
    ethtool -i "${nic}" 2>&1 || true

    echo
    ethtool "${nic}" 2>&1 |
        grep -E \
        'Speed:|Duplex:|Auto-negotiation:|Link detected:' ||
        true

    speed="$(
        ethtool "${nic}" 2>/dev/null |
        awk -F': ' '/Speed:/ {print $2; exit}'
    )"

    link_detected="$(
        ethtool "${nic}" 2>/dev/null |
        awk -F': ' '/Link detected:/ {print $2; exit}'
    )"

    rdma_active="no"

    if command_exists rdma &&
       rdma link show 2>/dev/null |
       grep -Eq \
       "state ACTIVE.*netdev[[:space:]]+${nic}([[:space:]]|$)"; then

        rdma_active="yes"
    fi

    if [[ -n "${ibdev}" &&
          "${operstate}" == "up" &&
          "${link_detected}" == "yes" &&
          "${rdma_active}" == "yes" ]]; then

        add_result \
            "${nic} link/RDMA" \
            "PASS" \
            "${ibdev}, ${speed:-speed unknown}, MTU ${mtu}, ACTIVE"
    else
        add_result \
            "${nic} link/RDMA" \
            "FAIL" \
            "ibdev=${ibdev:-none}, state=${operstate}, link=${link_detected:-unknown}, RDMA=${rdma_active}"
    fi

    if [[ "${mtu}" == "9000" ||
          "${mtu}" == "9216" ]]; then

        add_result \
            "${nic} MTU" \
            "PASS" \
            "MTU ${mtu}"
    else
        add_result \
            "${nic} MTU" \
            "WARN" \
            "MTU ${mtu}; verify expected fabric MTU"
    fi
done

###############################################################################
# RoCE QoS
###############################################################################

section "11. CURRENT ROCE QOS SETTINGS"

for nic in "${ROCE_NICS[@]}"; do
    echo
    echo "================ ${nic} ================"

    if [[ ! -e "/sys/class/net/${nic}" ]]; then
        continue
    fi

    qos_output="$(
        mlnx_qos -i "${nic}" 2>&1 ||
        true
    )"

    echo "${qos_output}"

    if grep -q \
       'Priority trust state: dscp' \
       <<<"${qos_output}"; then

        add_result \
            "${nic} DSCP trust" \
            "PASS" \
            "Trust mode is DSCP"
    else
        current_trust="$(
            grep \
                'Priority trust state:' \
                <<<"${qos_output}" |
            head -1 |
            sed 's/^[[:space:]]*//' ||
            true
        )"

        add_result \
            "${nic} DSCP trust" \
            "FAIL" \
            "${current_trust:-Trust state unavailable}"
    fi

    if grep -Eq \
       'enabled[[:space:]]+0[[:space:]]+0[[:space:]]+0[[:space:]]+1[[:space:]]+0[[:space:]]+0[[:space:]]+0[[:space:]]+0' \
       <<<"${qos_output}"; then

        add_result \
            "${nic} PFC" \
            "PASS" \
            "PFC enabled on priority 3 only"
    else
        pfc_line="$(
            grep -E \
                'enabled[[:space:]]+' \
                <<<"${qos_output}" |
            head -1 |
            sed 's/^[[:space:]]*//' ||
            true
        )"

        add_result \
            "${nic} PFC" \
            "FAIL" \
            "${pfc_line:-PFC status unavailable}"
    fi
done

###############################################################################
# RDMA traffic class
###############################################################################

section "12. RDMA TRAFFIC CLASS"

for nic in "${ROCE_NICS[@]}"; do
    ibdev="$(get_ibdev "${nic}")"

    echo
    echo -n "${nic} -> ${ibdev:-unmapped}: "

    if [[ -z "${ibdev}" ]]; then
        echo "No RDMA mapping"

        add_result \
            "${nic} traffic class" \
            "FAIL" \
            "No RDMA device mapping"

        continue
    fi

    tc_file="/sys/class/infiniband/${ibdev}/tc/1/traffic_class"

    if [[ ! -r "${tc_file}" ]]; then
        echo "traffic_class file unavailable"

        add_result \
            "${nic} traffic class" \
            "FAIL" \
            "${tc_file} unavailable"

        continue
    fi

    tc_output="$(cat "${tc_file}")"

    echo "${tc_output}"

    current_tos="$(
        sed -nE \
            's/.*=([0-9]+).*/\1/p' \
            <<<"${tc_output}" |
        head -1
    )"

    if [[ "${current_tos}" == "${EXPECTED_TOS}" ]]; then
        add_result \
            "${nic} traffic class" \
            "PASS" \
            "${ibdev} TOS ${current_tos}"
    else
        add_result \
            "${nic} traffic class" \
            "FAIL" \
            "${ibdev} TOS ${current_tos:-unknown}; expected ${EXPECTED_TOS}"
    fi
done

###############################################################################
# TCP ECN
###############################################################################

section "13. TCP ECN"

tcp_ecn="$(
    sysctl -n net.ipv4.tcp_ecn 2>/dev/null ||
    echo unknown
)"

echo "net.ipv4.tcp_ecn = ${tcp_ecn}"

if [[ "${tcp_ecn}" == "1" ]]; then
    add_result \
        "TCP ECN" \
        "PASS" \
        "net.ipv4.tcp_ecn=1"
else
    add_result \
        "TCP ECN" \
        "FAIL" \
        "Current value ${tcp_ecn}; expected 1"
fi

###############################################################################
# Persistence files
###############################################################################

section "14. ROCE PERSISTENCE CONFIGURATION"

persistence_files=(
    /etc/weka-roce.conf
    /etc/sysctl.d/99-weka-roce.conf
    /usr/local/sbin/weka-roce-startup.sh
    /usr/local/sbin/weka-roce-config.sh
    /etc/systemd/system/weka-roce.service
    /etc/systemd/system/weka-agent.service.d/10-roce.conf
)

existing_persistence_count=0

for file in "${persistence_files[@]}"; do
    if [[ -e "${file}" ]]; then
        ls -l "${file}"
        existing_persistence_count=$((existing_persistence_count + 1))
    else
        echo "NOT PRESENT: ${file}"
    fi
done

if (( existing_persistence_count == 0 )); then
    add_result \
        "RoCE persistence files" \
        "INFO" \
        "Not installed"
else
    add_result \
        "RoCE persistence files" \
        "INFO" \
        "${existing_persistence_count} persistence component(s) present"
fi

###############################################################################
# Other RoCE startup/configuration mechanisms
###############################################################################

section "15. OTHER ROCE CONFIGURATION SOURCES"

ROCE_SEARCH_RESULT="$(
    {
        grep -RnsE \
            'mlnx_qos|cma_roce_tos|traffic_class|tcp_ecn|--trust[[:space:]]+dscp|--pfc' \
            /etc/systemd/system \
            /usr/lib/systemd/system \
            /etc/init.d \
            /etc/cron.d \
            /etc/cron.daily \
            /usr/local/sbin \
            /usr/local/bin \
            2>/dev/null

        grep -nsE \
            'mlnx_qos|cma_roce_tos|traffic_class|tcp_ecn|--trust[[:space:]]+dscp|--pfc' \
            /root/*.sh \
            2>/dev/null
    } |
    grep -vE \
        'weka-roce-precheck(-v[0-9]+)?\.sh|roce-precheck-reports' |
    head -200 ||
    true
)"

if [[ -n "${ROCE_SEARCH_RESULT}" ]]; then
    echo "${ROCE_SEARCH_RESULT}"

    source_count="$(
        cut -d: -f1 <<<"${ROCE_SEARCH_RESULT}" |
        sort -u |
        wc -l |
        tr -d ' '
    )"

    add_result \
        "Other RoCE config sources" \
        "INFO" \
        "${source_count} possible source file(s); review output"
else
    echo "No alternate RoCE configuration source found."

    add_result \
        "Other RoCE config sources" \
        "INFO" \
        "No alternate source found"
fi

###############################################################################
# Network-online status
###############################################################################

section "16. NETWORK-ONLINE STATUS"

wait_online_timeouts="$(
    journalctl -b \
        -u systemd-networkd-wait-online.service \
        --no-pager 2>/dev/null |
    grep -c \
        'Timeout occurred' ||
    true
)"

wait_online_timeouts="${wait_online_timeouts:-0}"

systemctl show systemd-networkd-wait-online.service \
    -p ActiveState \
    -p SubState \
    -p Result \
    2>&1 || true

echo "Current-boot wait-online timeout count: ${wait_online_timeouts}"

if [[ "${wait_online_timeouts}" =~ ^[0-9]+$ ]] &&
   (( wait_online_timeouts == 0 )); then

    add_result \
        "network-online wait" \
        "PASS" \
        "No current-boot timeout"
else
    add_result \
        "network-online wait" \
        "WARN" \
        "${wait_online_timeouts} timeout event(s) in current boot"
fi

###############################################################################
# Relevant current-boot WEKA/RDMA/NIC/NVMe errors
###############################################################################

section "17. RELEVANT CURRENT-BOOT WARNINGS"

NIC_PATTERN=""

if (( ${#ROCE_NICS[@]} > 0 )); then
    NIC_PATTERN="$(
        IFS='|'
        echo "${ROCE_NICS[*]}"
    )"
fi

relevant_errors="$(
    {
        journalctl -b \
            -p warning..alert \
            --no-pager 2>/dev/null |
        grep -Ei \
            "(mlx5|rdma|weka${NIC_PATTERN:+|${NIC_PATTERN}}).*(failed|failure|error|timeout|reset|link.*down)" ||
        true

        journalctl -b \
            -p warning..alert \
            --no-pager 2>/dev/null |
        grep -Ei \
            'nvme.*(I/O error|timeout|controller reset|critical warning|media error)' ||
        true
    } |
    sort -u |
    tail -100
)"

if [[ -n "${relevant_errors}" ]]; then
    echo "${relevant_errors}"

    error_count="$(
        wc -l <<<"${relevant_errors}" |
        tr -d ' '
    )"

    add_result \
        "Relevant boot warnings" \
        "WARN" \
        "${error_count} matching line(s); review output"
else
    echo "No matching WEKA/RDMA/RoCE/NVMe warning patterns found."

    add_result \
        "Relevant boot warnings" \
        "PASS" \
        "No matching critical patterns"
fi

###############################################################################
# Final summary
###############################################################################

section "18. PRE-CHECK SUMMARY"

print_summary_table

pass_count=0
warn_count=0
fail_count=0
info_count=0

for index in "${!SUMMARY_CHECK[@]}"; do
    printf "%-36s %-7s %s\n" \
        "${SUMMARY_CHECK[${index}]}" \
        "${SUMMARY_STATE[${index}]}" \
        "${SUMMARY_DETAIL[${index}]}"

    case "${SUMMARY_STATE[${index}]}" in
        PASS)
            pass_count=$((pass_count + 1))
            ;;

        WARN)
            warn_count=$((warn_count + 1))
            ;;

        FAIL)
            fail_count=$((fail_count + 1))
            ;;

        INFO)
            info_count=$((info_count + 1))
            ;;
    esac
done

echo
echo "----------------------------------------------------------------"
echo "PASS: ${pass_count}   WARN: ${warn_count}   FAIL: ${fail_count}   INFO: ${info_count}"
echo "----------------------------------------------------------------"

if (( fail_count > 0 )); then
    OVERALL="NOT READY"
    EXIT_CODE=2
elif (( warn_count > 0 )); then
    OVERALL="READY AFTER WARNING REVIEW"
    EXIT_CODE=1
else
    OVERALL="READY FOR CONTROLLED CHANGE"
    EXIT_CODE=0
fi

echo
echo "Overall assessment: ${OVERALL}"
echo "Host:               ${HOST}"
echo "Detected role:      ${DETECTED_ROLE}"
echo "Role reason:        ${ROLE_REASON}"
echo "Expected traffic:   TOS ${EXPECTED_TOS}"
echo "RoCE interfaces:    ${ROCE_NICS[*]:-none}"
echo "Report:              ${REPORT}"
echo

if (( ${#ROCE_NICS[@]} > 0 )); then
    NIC_CSV="$(
        IFS=,
        echo "${ROCE_NICS[*]}"
    )"

    echo "Suggested deployment command:"
    echo
    echo "/root/deploy-weka-roce.sh \\"
    echo "  --role ${DETECTED_ROLE} \\"
    echo "  --nics ${NIC_CSV} \\"
    echo "  --tos ${EXPECTED_TOS}"
fi

echo
echo "No configuration changes were made."

exit "${EXIT_CODE}"
