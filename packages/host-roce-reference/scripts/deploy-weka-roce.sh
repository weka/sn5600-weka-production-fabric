#!/usr/bin/env bash

###############################################################################
# Automated WEKA RoCE Deployment
#
# Workflow:
#   1. Detect backend/client role
#   2. Discover or validate RoCE NICs
#   3. Run /root/weka-roce-precheck.sh
#   4. Refuse deployment if pre-check fails
#   5. Back up existing configuration
#   6. Install RoCE configuration and systemd persistence
#   7. Apply and verify RoCE settings
#   8. Run post-deployment pre-check
#   9. Optionally test WEKA agent dependency ordering
#
# Default traffic class:
#   Backend: 96
#   Client:  106
#
# This script does not reboot the host.
###############################################################################

set -Eeuo pipefail

REQUESTED_ROLE="auto"
ROLE=""
NIC_LIST=""
ROCE_TOS=""
PRECHECK_SCRIPT="/root/weka-roce-precheck.sh"

ACCEPT_WARNINGS=false
TEST_AGENT=false
MAINTENANCE_APPROVED=false

WAIT_TIMEOUT=300
WAIT_INTERVAL=2

###############################################################################
# Functions
###############################################################################

usage()
{
    cat <<'EOF'
Usage:
  deploy-weka-roce.sh \
    [--role auto|backend|client] \
    [--nics NIC1,NIC2] \
    [--tos VALUE] \
    [--accept-warnings] \
    [--test-agent] \
    [--maintenance-approved]

Options:

  --role
      auto, backend, or client.

      Default: auto

      Automatic detection:
        Backend = drives*, compute*, or ssdproxy containers found
        Client  = no backend containers found

  --nics
      Comma-separated RoCE interfaces.

      When omitted, mlx5 Ethernet interfaces are discovered automatically.
      Automatic discovery must find exactly two interfaces.

  --tos
      RoCE traffic class/TOS.

      Default:
        Backend: 96
        Client:  106

  --accept-warnings
      Continue when the pre-check returns warnings but no failures.

  --test-agent
      After deployment, stop weka-agent and validate that starting it
      automatically starts and completes weka-roce.service first.

      This is disruptive to a backend and to clients with active mounts.

  --maintenance-approved
      Confirms that maintenance approval has been obtained.

      Required for:
        - Any backend deployment
        - Client deployment with active WEKA mounts
        - Backend WEKA agent dependency testing

  --help
      Display this help.

Examples:

  Client:
    ./deploy-weka-roce.sh \
      --role client \
      --nics ens4047f0np0,ens4047f1np1 \
      --tos 106 \
      --accept-warnings

  Backend:
    ./deploy-weka-roce.sh \
      --role backend \
      --nics eno16795np0,eno16595np0 \
      --tos 96 \
      --accept-warnings \
      --maintenance-approved

  Client dependency test:
    ./deploy-weka-roce.sh \
      --role client \
      --nics ens4047f0np0,ens4047f1np1 \
      --tos 106 \
      --accept-warnings \
      --test-agent
EOF
}

log()
{
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*"
}

fail()
{
    log "ERROR: $*"
    exit 1
}

command_exists()
{
    command -v "$1" >/dev/null 2>&1
}

get_ibdev()
{
    local nic="$1"
    local mappings=""

    mappings="$(ibdev2netdev 2>/dev/null || true)"

    awk -v nic="${nic}" \
        '$5 == nic {print $1; exit}' <<<"${mappings}"
}

backup_file()
{
    local source_file="$1"
    local destination=""

    if [[ -e "${source_file}" ]]; then
        destination="${BACKUP_DIR}${source_file}"

        mkdir -p "$(dirname "${destination}")"
        cp -a "${source_file}" "${destination}"

        log "Backed up ${source_file}"
    fi
}

run_precheck()
{
    "${PRECHECK_SCRIPT}" \
        --role "${ROLE}" \
        --nics "${NIC_CSV}" \
        --expected-tos "${ROCE_TOS}"
}

get_latest_precheck_report()
{
    local report_dir="/root/roce-precheck-reports"
    local host=""

    host="$(hostname -s)"

    ls -1t \
        "${report_dir}/${host}-roce-precheck-"*.log \
        2>/dev/null |
    head -1
}

validate_predeployment_failures()
{
    local report=""
    local summary=""
    local fail_lines=""
    local warn_lines=""
    local unexpected_failures=""

    report="$(get_latest_precheck_report)"

    [[ -n "${report}" && -r "${report}" ]] ||
        fail "Unable to locate the pre-check report"

    log "Reviewing pre-deployment failures from ${report}"

    summary="$(
        sed -n \
            '/^18\. PRE-CHECK SUMMARY/,/^Overall assessment:/p' \
            "${report}"
    )"

    fail_lines="$(
        grep -E \
            '[[:space:]]FAIL[[:space:]]' \
            <<<"${summary}" ||
        true
    )"

    warn_lines="$(
        grep -E \
            '[[:space:]]WARN[[:space:]]' \
            <<<"${summary}" ||
        true
    )"

    if [[ -n "${warn_lines}" &&
          "${ACCEPT_WARNINGS}" != true ]]; then

        echo
        echo "Pre-check warnings:"
        echo "${warn_lines}"
        echo

        fail "Warnings require --accept-warnings"
    fi

    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue

        if grep -Eq \
           '^weka-roce\.service[[:space:]]+FAIL|^RoCE/WEKA startup order[[:space:]]+FAIL|^TCP ECN[[:space:]]+FAIL|^[^[:space:]]+[[:space:]]+(DSCP trust|PFC|traffic class)[[:space:]]+FAIL' \
           <<<"${line}"; then

            log "REMEDIABLE: ${line}"
        else
            unexpected_failures+="${line}"$'\n'
        fi
    done <<<"${fail_lines}"

    if [[ -n "${unexpected_failures}" ]]; then
        echo
        echo "Blocking pre-check failures:"
        printf '%s' "${unexpected_failures}"
        echo

        fail "Pre-deployment validation found non-remediable failures"
    fi

    log "All pre-deployment failures are expected RoCE configuration items"
    log "Deployment may continue"
}

handle_precheck_result()
{
    local rc="$1"
    local stage="$2"
    local mode="${3:-strict}"

    case "${rc}" in
        0)
            log "${stage} pre-check passed"
            ;;

        1)
            if [[ "${ACCEPT_WARNINGS}" == true ]]; then
                log "${stage} pre-check completed with accepted warnings"
            else
                fail "${stage} pre-check returned warnings. Review them and rerun with --accept-warnings"
            fi
            ;;

        2)
            if [[ "${mode}" == "bootstrap" ]]; then
                validate_predeployment_failures
            else
                fail "${stage} pre-check found one or more failures"
            fi
            ;;

        *)
            fail "${stage} pre-check returned unexpected exit code ${rc}"
            ;;
    esac
}

###############################################################################
# Parse arguments
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

        --tos)
            ROCE_TOS="${2:-}"
            shift 2
            ;;

        --accept-warnings)
            ACCEPT_WARNINGS=true
            shift
            ;;

        --test-agent)
            TEST_AGENT=true
            shift
            ;;

        --maintenance-approved)
            MAINTENANCE_APPROVED=true
            shift
            ;;

        --help|-h)
            usage
            exit 0
            ;;

        *)
            fail "Unknown option: $1"
            ;;
    esac
done

###############################################################################
# Basic validation
###############################################################################

[[ "${EUID}" -eq 0 ]] ||
    fail "Run this script as root"

case "${REQUESTED_ROLE}" in
    auto|backend|client)
        ;;

    *)
        fail "--role must be auto, backend, or client"
        ;;
esac

if [[ -n "${ROCE_TOS}" ]] &&
   [[ ! "${ROCE_TOS}" =~ ^[0-9]+$ ]]; then
    fail "--tos must be numeric"
fi

[[ -x "${PRECHECK_SCRIPT}" ]] ||
    fail "Pre-check script is missing or not executable: ${PRECHECK_SCRIPT}"

required_commands=(
    weka
    ip
    ethtool
    ibdev2netdev
    rdma
    mlnx_qos
    cma_roce_tos
    sysctl
    systemctl
    systemd-analyze
    awk
    sed
    grep
    sort
    findmnt
)

for command_name in "${required_commands[@]}"; do
    command_exists "${command_name}" ||
        fail "Required command is missing: ${command_name}"
done

systemctl cat weka-agent.service >/dev/null 2>&1 ||
    fail "weka-agent.service is not installed"

###############################################################################
# Detect host role
###############################################################################

log "Detecting WEKA host role"

WEKA_LOCAL_PS="$(
    weka local ps 2>&1 |
    tr -d '\000' ||
    true
)"

backend_container_count="$(
    awk '
        NR > 1 &&
        $1 ~ /^(drives|compute|ssdproxy)/ {
            count++
        }

        END {
            print count + 0
        }
    ' <<<"${WEKA_LOCAL_PS}"
)"

if [[ "${REQUESTED_ROLE}" == "auto" ]]; then
    if (( backend_container_count > 0 )); then
        ROLE="backend"
        ROLE_REASON="${backend_container_count} backend container(s) detected"
    else
        ROLE="client"
        ROLE_REASON="No backend containers detected"
    fi
else
    ROLE="${REQUESTED_ROLE}"
    ROLE_REASON="Role explicitly supplied"
fi

if [[ -z "${ROCE_TOS}" ]]; then
    if [[ "${ROLE}" == "backend" ]]; then
        ROCE_TOS=96
    else
        ROCE_TOS=106
    fi
fi

log "Role: ${ROLE}"
log "Role reason: ${ROLE_REASON}"
log "Target traffic class/TOS: ${ROCE_TOS}"

###############################################################################
# Discover or parse RoCE NICs
###############################################################################

declare -a ROCE_NICS=()

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
    mapfile -t ROCE_NICS < <(
        ibdev2netdev 2>/dev/null |
        awk '$1 ~ /^mlx5_/ && $5 != "" {print $5}' |
        sort -u
    )

    if (( ${#ROCE_NICS[@]} != 2 )); then
        fail "Automatic discovery found ${#ROCE_NICS[@]} mlx5 interface(s). Specify --nics explicitly"
    fi
fi

(( ${#ROCE_NICS[@]} > 0 )) ||
    fail "No RoCE interfaces selected"

NIC_CSV="$(
    IFS=,
    echo "${ROCE_NICS[*]}"
)"

log "Selected RoCE interfaces: ${ROCE_NICS[*]}"

###############################################################################
# Validate interfaces and RDMA mappings
###############################################################################

for nic in "${ROCE_NICS[@]}"; do
    [[ -e "/sys/class/net/${nic}" ]] ||
        fail "Interface does not exist: ${nic}"

    ethtool -i "${nic}" >/dev/null 2>&1 ||
        fail "Unable to read driver information for ${nic}"

    ibdev="$(get_ibdev "${nic}")"

    [[ -n "${ibdev}" ]] ||
        fail "No RDMA device maps to ${nic}"

    [[ -d "/sys/class/infiniband/${ibdev}" ]] ||
        fail "RDMA device directory missing for ${ibdev}"

    log "${nic} maps to ${ibdev}"
done

###############################################################################
# Maintenance safety checks
###############################################################################

WEKA_MOUNTS="$(
    findmnt -rn -t wekafs 2>/dev/null ||
    true
)"

if [[ "${ROLE}" == "backend" &&
      "${MAINTENANCE_APPROVED}" != true ]]; then

    fail "Backend deployment requires --maintenance-approved"
fi

if [[ "${ROLE}" == "client" &&
      -n "${WEKA_MOUNTS}" &&
      "${MAINTENANCE_APPROVED}" != true ]]; then

    echo "${WEKA_MOUNTS}"
    fail "Active WEKA mounts found. Maintenance approval is required"
fi

if [[ "${TEST_AGENT}" == true &&
      "${ROLE}" == "backend" &&
      "${MAINTENANCE_APPROVED}" != true ]]; then

    fail "Backend agent testing requires --maintenance-approved"
fi

###############################################################################
# Run pre-deployment pre-check
###############################################################################

log "Running pre-deployment validation"

set +e
run_precheck
PRECHECK_RC=$?
set -e

handle_precheck_result "${PRECHECK_RC}" "Pre-deployment" "bootstrap"

###############################################################################
# Back up current state
###############################################################################

STAMP="$(date '+%Y%m%d-%H%M%S')"
BACKUP_DIR="/root/weka-roce-deployment-backup/${STAMP}"

mkdir -p "${BACKUP_DIR}"

log "Creating backup in ${BACKUP_DIR}"

{
    echo "Host: $(hostname)"
    echo "Date: $(date)"
    echo "Role: ${ROLE}"
    echo "Role reason: ${ROLE_REASON}"
    echo "NICs: ${ROCE_NICS[*]}"
    echo "TOS: ${ROCE_TOS}"
    echo

    echo "=== WEKA local containers ==="
    echo "${WEKA_LOCAL_PS}"
    echo

    echo "=== WEKA mounts ==="
    echo "${WEKA_MOUNTS}"
    echo

    echo "=== Addresses ==="
    ip -br address
    echo

    echo "=== RDMA mapping ==="
    ibdev2netdev
    echo

    echo "=== TCP ECN ==="
    sysctl net.ipv4.tcp_ecn
    echo

    for nic in "${ROCE_NICS[@]}"; do
        echo
        echo "=== ${nic} QoS ==="
        mlnx_qos -i "${nic}" || true
    done
} >"${BACKUP_DIR}/pre-deployment-state.txt" 2>&1

files_to_backup=(
    /etc/weka-roce.conf
    /etc/sysctl.d/99-weka-roce.conf
    /usr/local/sbin/weka-roce-config.sh
    /usr/local/sbin/weka-roce-startup.sh
    /etc/systemd/system/weka-roce.service
    /etc/systemd/system/weka-agent.service.d/10-roce.conf
)

for file in "${files_to_backup[@]}"; do
    backup_file "${file}"
done

###############################################################################
# Create RoCE configuration
###############################################################################

log "Creating /etc/weka-roce.conf"

{
    echo "# Generated by deploy-weka-roce.sh"
    echo "WEKA_ROLE=$(printf '%q' "${ROLE}")"
    echo "ROCE_TOS=$(printf '%q' "${ROCE_TOS}")"
    echo "WAIT_TIMEOUT=$(printf '%q' "${WAIT_TIMEOUT}")"
    echo "WAIT_INTERVAL=$(printf '%q' "${WAIT_INTERVAL}")"
    echo
    echo "ROCE_NICS=("

    for nic in "${ROCE_NICS[@]}"; do
        printf '    %q\n' "${nic}"
    done

    echo ")"
} >/etc/weka-roce.conf

chmod 0644 /etc/weka-roce.conf

###############################################################################
# Create RoCE configuration and validation script
###############################################################################

log "Creating /usr/local/sbin/weka-roce-config.sh"

cat >/usr/local/sbin/weka-roce-config.sh <<'ROCE_CONFIG_SCRIPT'
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
ROCE_CONFIG_SCRIPT

chmod 0755 /usr/local/sbin/weka-roce-config.sh

###############################################################################
# Create startup wrapper
###############################################################################

log "Creating /usr/local/sbin/weka-roce-startup.sh"

cat >/usr/local/sbin/weka-roce-startup.sh <<'ROCE_STARTUP_SCRIPT'
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
ROCE_STARTUP_SCRIPT

chmod 0755 /usr/local/sbin/weka-roce-startup.sh

###############################################################################
# Persist TCP ECN
###############################################################################

log "Creating /etc/sysctl.d/99-weka-roce.conf"

cat >/etc/sysctl.d/99-weka-roce.conf <<'SYSCTL_CONF'
# WEKA RoCE TCP ECN
net.ipv4.tcp_ecn = 1
SYSCTL_CONF

chmod 0644 /etc/sysctl.d/99-weka-roce.conf

###############################################################################
# Create systemd service
###############################################################################

log "Creating weka-roce.service"

cat >/etc/systemd/system/weka-roce.service <<'ROCE_UNIT'
[Unit]
Description=Configure and Validate RoCE Before WEKA Agent
Wants=network-online.target
After=network-online.target systemd-modules-load.service
Before=weka-agent.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/weka-roce-startup.sh
RemainAfterExit=yes
TimeoutStartSec=360
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
ROCE_UNIT

chmod 0644 /etc/systemd/system/weka-roce.service

###############################################################################
# Create WEKA agent dependency
###############################################################################

log "Creating WEKA agent dependency"

mkdir -p /etc/systemd/system/weka-agent.service.d

cat >/etc/systemd/system/weka-agent.service.d/10-roce.conf <<'AGENT_DROPIN'
[Unit]
Requires=weka-roce.service
After=weka-roce.service
AGENT_DROPIN

chmod 0644 \
    /etc/systemd/system/weka-agent.service.d/10-roce.conf

###############################################################################
# Syntax and systemd validation
###############################################################################

log "Validating generated scripts"

bash -n /usr/local/sbin/weka-roce-config.sh
bash -n /usr/local/sbin/weka-roce-startup.sh

systemctl daemon-reload

log "Validating systemd configuration"

systemd-analyze verify \
    /etc/systemd/system/weka-roce.service \
    /etc/systemd/system/weka-agent.service \
    2>&1 |
tee "${BACKUP_DIR}/systemd-verify.txt" ||
true

systemctl enable weka-roce.service

###############################################################################
# Apply RoCE configuration
###############################################################################

log "Starting and validating weka-roce.service"

if ! systemctl restart weka-roce.service; then
    systemctl status weka-roce.service --no-pager -l || true

    journalctl \
        -u weka-roce.service \
        --since "-15 minutes" \
        --no-pager ||
        true

    fail "weka-roce.service failed"
fi

systemctl is-active --quiet weka-roce.service ||
    fail "weka-roce.service is not active"

log "weka-roce.service completed successfully"

###############################################################################
# Run post-deployment validation
###############################################################################

log "Running post-deployment pre-check"

set +e
run_precheck
POSTCHECK_RC=$?
set -e

handle_precheck_result "${POSTCHECK_RC}" "Post-deployment" "strict"

###############################################################################
# Optional WEKA agent dependency test
###############################################################################

if [[ "${TEST_AGENT}" == true ]]; then
    log "Starting WEKA agent dependency test"

    if [[ -n "${WEKA_MOUNTS}" &&
          "${MAINTENANCE_APPROVED}" != true ]]; then

        fail "Active WEKA mounts prevent agent dependency testing"
    fi

    systemctl stop weka-agent.service
    systemctl stop weka-roce.service

    systemctl reset-failed weka-agent.service || true
    systemctl reset-failed weka-roce.service || true

    log "Starting only weka-agent.service"

    if ! systemctl start weka-agent.service; then
        systemctl status \
            weka-roce.service \
            weka-agent.service \
            --no-pager -l ||
            true

        journalctl \
            -u weka-roce.service \
            -u weka-agent.service \
            --since "-15 minutes" \
            --no-pager ||
            true

        fail "WEKA agent dependency test failed"
    fi

    systemctl is-active --quiet weka-roce.service ||
        fail "weka-roce.service is not active after dependency test"

    systemctl is-active --quiet weka-agent.service ||
        fail "weka-agent.service is not active after dependency test"

    agent_requires="$(
        systemctl show weka-agent.service \
            -p Requires \
            --value
    )"

    agent_after="$(
        systemctl show weka-agent.service \
            -p After \
            --value
    )"

    grep -qw weka-roce.service <<<"${agent_requires}" ||
        fail "weka-agent does not require weka-roce.service"

    grep -qw weka-roce.service <<<"${agent_after}" ||
        fail "weka-agent is not ordered after weka-roce.service"

    log "WEKA agent dependency test passed"
fi

###############################################################################
# Final report
###############################################################################

FINAL_REPORT="${BACKUP_DIR}/deployment-summary.txt"

{
    echo "WEKA RoCE deployment completed"
    echo
    echo "Host: $(hostname)"
    echo "Date: $(date)"
    echo "Role: ${ROLE}"
    echo "Role reason: ${ROLE_REASON}"
    echo "NICs: ${ROCE_NICS[*]}"
    echo "TOS: ${ROCE_TOS}"
    echo "Agent dependency test: ${TEST_AGENT}"
    echo
    echo "weka-roce enabled:"
    systemctl is-enabled weka-roce.service
    echo
    echo "weka-roce state:"
    systemctl show weka-roce.service \
        -p ActiveState \
        -p SubState \
        -p Result
    echo
    echo "weka-agent state:"
    systemctl show weka-agent.service \
        -p ActiveState \
        -p SubState \
        -p Result
    echo
    echo "weka-agent dependency:"
    systemctl show weka-agent.service \
        -p Requires \
        -p After
    echo
    echo "RDMA mapping:"
    ibdev2netdev
    echo
    echo "TCP ECN:"
    sysctl net.ipv4.tcp_ecn
    echo

    for nic in "${ROCE_NICS[@]}"; do
        ibdev="$(get_ibdev "${nic}")"

        echo
        echo "=== ${nic}/${ibdev} ==="

        mlnx_qos -i "${nic}" |
            grep -E \
                'Priority trust state|PFC configuration|^[[:space:]]*enabled'

        cat "/sys/class/infiniband/${ibdev}/tc/1/traffic_class"
    done
} >"${FINAL_REPORT}" 2>&1

echo
echo "================================================================"
echo "WEKA RoCE deployment completed successfully"
echo "================================================================"
echo
echo "Host:            $(hostname -s)"
echo "Role:            ${ROLE}"
echo "RoCE interfaces: ${ROCE_NICS[*]}"
echo "Traffic class:   ${ROCE_TOS}"
echo "Backup:          ${BACKUP_DIR}"
echo "Report:          ${FINAL_REPORT}"
echo
echo "Reboot was not performed."
echo
echo "Next validation:"
echo "  /root/weka-roce-precheck.sh"
echo
echo "For a later reboot test:"
echo "  reboot"
echo
