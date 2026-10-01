#!/usr/bin/env bash
# Run on the Mac with bash. No passwords are stored. No configuration is changed.
set -uo pipefail
HOSTS="40 41 42 43 45 46 47 49 50 51 52 53 54 55 56 57 58 63 65 70 71 72 73 74 75 76 77"
SSH_OPTS=(-o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=3)
MODE="${1:---reboot}"
case "$MODE" in
  --reboot)
    REPORT_DIR="$HOME/Downloads/RoCE_Reboot_Validate_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$REPORT_DIR" || exit 1
    ;;
  --validate)
    REPORT_DIR="${2:-}"
    [ -d "$REPORT_DIR" ] && [ -s "$REPORT_DIR/baseline.tsv" ] || {
      echo "Usage: bash $0 --validate EXISTING_REPORT_DIRECTORY"; exit 1;
    }
    ;;
  *) echo "Usage: bash $0 [--reboot | --validate EXISTING_REPORT_DIRECTORY]"; exit 1 ;;
esac
echo "Reports: $REPORT_DIR"

cat > "$REPORT_DIR/remote-check.sh" <<'REMOTE'
set -uo pipefail
H="$1"
EXPECTED_BOOT="$2"
CURRENT_BOOT=$(cat /proc/sys/kernel/random/boot_id)
echo "HOST=$(hostname) BOOT_ID=$CURRENT_BOOT"
if [ "$EXPECTED_BOOT" != "preflight" ] && [ "$CURRENT_BOOT" = "$EXPECTED_BOOT" ]; then
  echo "FAIL: boot ID unchanged; reboot not confirmed"; exit 1
fi
if [ "$H" -lt 65 ]; then
  NICS="ens4047np0,ens3919np0"
  I0=ens4047np0; I1=ens3919np0
else
  NICS="ens4047f0np0,ens4047f1np1"
  I0=ens4047f0np0; I1=ens4047f1np1
fi
if [ -n "$(findmnt -rn -t wekafs 2>/dev/null)" ]; then
  echo "FAIL: active WEKA mounts; stopped"; exit 1
fi
test -x /root/weka-roce-precheck.sh || { echo "FAIL: precheck missing/not executable"; exit 1; }
CHECK_LOG=$(mktemp /root/roce-reboot-validation.XXXXXX)
/root/weka-roce-precheck.sh --role client --nics "$NICS" --expected-tos 106 > "$CHECK_LOG" 2>&1
RC=$?
cat "$CHECK_LOG"
echo "Precheck exit=$RC; retained report=$CHECK_LOG"
if [ "$RC" -gt 1 ] ||
   ! grep -Eq '^PASS:.*FAIL: 0([[:space:]]|$)' "$CHECK_LOG" ||
   ! grep -Eq '^Overall assessment: (READY|READY AFTER WARNING REVIEW)[[:space:]]*$' "$CHECK_LOG"; then
  echo "FAIL: precheck did not meet readiness checks"; exit 1
fi
[ "$RC" -eq 0 ] || echo "WARNING: warning-only precheck accepted; warnings remain open"
systemctl is-enabled weka-roce.service || exit 1
systemctl is-active weka-roce.service || exit 1
systemctl is-active weka-agent.service || exit 1
for LINK in 1 2; do
  if [ "$LINK" -eq 1 ]; then I="$I0"; SRC="10.200.$H.1"; GW="10.200.$H.0"; TABLE=100
  else I="$I1"; SRC="10.200.$H.3"; GW="10.200.$H.2"; TABLE=101; fi
  [ "$(cat /sys/class/net/"$I"/operstate)" = up ] || { echo "FAIL: $I down"; exit 1; }
  [ "$(cat /sys/class/net/"$I"/mtu)" = 9000 ] || { echo "FAIL: $I MTU"; exit 1; }
  ip -4 -o address show dev "$I" | awk '{print $4}' | grep -Fxq "$SRC/31" || {
    echo "FAIL: $I expected $SRC/31"; exit 1;
  }
  ROUTE=$(ip -4 route get 10.200.250.1 from "$SRC") || exit 1
  echo "$ROUTE"
  case "$ROUTE" in *"via $GW dev $I table $TABLE"*) ;; *) echo "FAIL: source policy route"; exit 1 ;; esac
  ping -n -I "$SRC" -c 3 -W 2 -M do -s 8972 "$GW" || exit 1
done
echo "PASS_HOST|weka$H|boot=$CURRENT_BOOT|RoCE_services_routes_jumbo"
REMOTE

if [ "$MODE" = --reboot ]; then
  printf 'HOST\tBOOT_ID\n' > "$REPORT_DIR/baseline.tsv"
  echo "===== PREFLIGHT ALL 27 CLIENTS; NO REBOOTS YET ====="
  for H in $HOSTS; do
    echo "===== PREFLIGHT weka$H ====="
    if ! ssh "${SSH_OPTS[@]}" "root@172.31.18.$H" bash -s -- "$H" preflight \
         < "$REPORT_DIR/remote-check.sh" 2>&1 | tee "$REPORT_DIR/weka${H}_before.log"; then
      echo "STOP: weka$H preflight failed. No clients rebooted."; exit 1
    fi
    BOOT=$(sed -n "s/^PASS_HOST|weka$H|boot=\([^|]*\)|.*/\1/p" "$REPORT_DIR/weka${H}_before.log")
    [ -n "$BOOT" ] || { echo "STOP: missing boot ID; no clients rebooted"; exit 1; }
    printf 'weka%s\t%s\n' "$H" "$BOOT" >> "$REPORT_DIR/baseline.tsv"
  done
  printf 'HOST\tRESULT\n' > "$REPORT_DIR/reboot-requests.tsv"
  echo "===== QUEUE REBOOTS FOR ALL 27 CLIENTS ====="
  for H in $HOSTS; do
    echo "===== REBOOT weka$H ====="
    if ssh "${SSH_OPTS[@]}" "root@172.31.18.$H" \
       'systemd-run --unit="roce-validation-reboot-$(date +%s)" --on-active=15s /sbin/reboot' \
       2>&1 | tee "$REPORT_DIR/weka${H}_reboot.log"; then
      printf 'weka%s\tREBOOT_SCHEDULED\n' "$H" >> "$REPORT_DIR/reboot-requests.tsv"
    else
      printf 'weka%s\tREBOOT_REQUEST_FAILED\n' "$H" >> "$REPORT_DIR/reboot-requests.tsv"
      echo "STOP: request failed. Earlier clients may already be rebooting."
      echo "Resume checks only: bash $0 --validate \"$REPORT_DIR\""
      exit 1
    fi
  done
  # Allow the last scheduled reboot to start before checking SSH availability.
  sleep 20
fi

printf 'HOST\tRESULT\n' > "$REPORT_DIR/validation-summary.tsv"
FAILURES=0
for H in $HOSTS; do
  BOOT=$(awk -F '\t' -v host="weka$H" '$1==host {print $2}' "$REPORT_DIR/baseline.tsv")
  if [ -z "$BOOT" ]; then
    printf 'weka%s\tNO_BASELINE\n' "$H" >> "$REPORT_DIR/validation-summary.tsv"
    FAILURES=$((FAILURES+1)); continue
  fi
  echo "===== WAITING FOR weka$H SSH (up to 5 minutes) ====="
  READY=0
  for ATTEMPT in $(seq 1 60); do
    if nc -z -G 2 "172.31.18.$H" 22 >/dev/null 2>&1; then READY=1; break; fi
    sleep 5
  done
  if [ "$READY" -ne 1 ]; then
    printf 'weka%s\tSSH_TIMEOUT\n' "$H" >> "$REPORT_DIR/validation-summary.tsv"
    FAILURES=$((FAILURES+1)); continue
  fi
  echo "===== POST-REBOOT VALIDATION weka$H ====="
  if ssh "${SSH_OPTS[@]}" "root@172.31.18.$H" bash -s -- "$H" "$BOOT" \
       < "$REPORT_DIR/remote-check.sh" 2>&1 | tee "$REPORT_DIR/weka${H}_after.log"; then
    printf 'weka%s\tPASS_REBOOT_VALIDATED_WARNINGS_REVIEW\n' "$H" >> "$REPORT_DIR/validation-summary.tsv"
  else
    printf 'weka%s\tFAIL_REVIEW_LOG\n' "$H" >> "$REPORT_DIR/validation-summary.tsv"
    FAILURES=$((FAILURES+1))
  fi
done
echo "===== FINAL REBOOT SUMMARY ====="
cat "$REPORT_DIR/validation-summary.tsv"
echo "Failures: $FAILURES"
echo "Reports: $REPORT_DIR"
echo "Warnings still need review. Cross-leaf RDMA and congestion tests are not included."
[ "$FAILURES" -eq 0 ]
