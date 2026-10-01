#!/usr/bin/env bash
# Deploy the tested client profile. No reboots or switch changes.
set -uo pipefail

REPORT_DIR="$HOME/Downloads/RoCE_Client_Deploy_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$REPORT_DIR/reference" || exit 1
printf 'HOST\tRESULT\n' > "$REPORT_DIR/summary.txt"
SSH_OPTS=(-o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=3)

scp "${SSH_OPTS[@]}" root@172.31.18.61:/root/weka-roce-precheck.sh "$REPORT_DIR/reference/" || exit 1
scp "${SSH_OPTS[@]}" root@172.31.18.61:/root/deploy-weka-roce.sh "$REPORT_DIR/reference/" || exit 1

# weka40 already deployed successfully; resume from weka41.
for H in 41 42 43 45 46 47 49 50 51 52 53 54 55 56 57 58 63 65 70 71 72 73 74 75 76 77
do
  HOST="weka${H}"
  HOST_IP="172.31.18.${H}"
  if [ "$H" -lt 65 ]; then
    NICS="ens4047np0,ens3919np0"
  else
    NICS="ens4047f0np0,ens4047f1np1"
  fi
  echo "===== DEPLOYING $HOST: $NICS ====="

  if ! ssh "${SSH_OPTS[@]}" "root@$HOST_IP" '
    set -e
    BACKUP_DIR="$(mktemp -d /root/roce-script-backup.XXXXXX)"
    for FILE in /root/weka-roce-precheck.sh /root/deploy-weka-roce.sh
    do
      if [ -e "$FILE" ]; then
        cp -p "$FILE" "$BACKUP_DIR/"
      fi
    done
    echo "Existing-script backup: $BACKUP_DIR"
  '; then
    printf '%s\tBACKUP_OR_SSH_FAILED\n' "$HOST" >> "$REPORT_DIR/summary.txt"
    break
  fi

  if ! scp "${SSH_OPTS[@]}" "$REPORT_DIR/reference/weka-roce-precheck.sh" "$REPORT_DIR/reference/deploy-weka-roce.sh" "root@$HOST_IP:/root/"; then
    printf '%s\tCOPY_FAILED\n' "$HOST" >> "$REPORT_DIR/summary.txt"
    break
  fi

  if ssh -tt "${SSH_OPTS[@]}" "root@$HOST_IP" "
    set -e
    chmod u+x /root/weka-roce-precheck.sh /root/deploy-weka-roce.sh
    /root/deploy-weka-roce.sh --role client --nics $NICS --tos 106 --accept-warnings
    VALIDATION_LOG=\$(mktemp /root/roce-batch-validation.XXXXXX)
    set +e
    /root/weka-roce-precheck.sh --role client --nics $NICS --expected-tos 106 >\"\$VALIDATION_LOG\" 2>&1
    CHECK_RC=\$?
    set -e
    cat \"\$VALIDATION_LOG\"
    echo \"Precheck exit status: \$CHECK_RC; report: \$VALIDATION_LOG\"
    if [ \"\$CHECK_RC\" -ne 0 ] && [ \"\$CHECK_RC\" -ne 1 ]; then
      echo 'STOP: unexpected precheck error'
      exit 1
    fi
    if ! grep -Eq '^PASS:.*FAIL: 0([[:space:]]|$)' \"\$VALIDATION_LOG\" ||
       ! grep -Eq '^Overall assessment: (READY|READY AFTER WARNING REVIEW)[[:space:]]*$' \"\$VALIDATION_LOG\"; then
      echo 'STOP: validation failures or missing readiness summary'
      exit 1
    fi
    if [ \"\$CHECK_RC\" -eq 1 ]; then
      echo 'WARNING-ONLY RESULT ACCEPTED: zero failures; warnings remain open'
    fi
    systemctl is-enabled weka-roce.service
    systemctl is-active weka-roce.service
    systemctl is-active weka-agent.service
    echo DEPLOYMENT_AND_VALIDATION_COMPLETED
  " 2>&1 | tee "$REPORT_DIR/${HOST}_deploy.log"; then
    printf '%s\tDEPLOYED_VALIDATED_NOT_REBOOTED\n' "$HOST" >> "$REPORT_DIR/summary.txt"
  else
    printf '%s\tFAILED_REVIEW_LOG\n' "$HOST" >> "$REPORT_DIR/summary.txt"
    echo "STOP: review $HOST. No automatic rollback."
    break
  fi
done

echo "===== BATCH SUMMARY ====="
cat "$REPORT_DIR/summary.txt"
echo "===== PRECHECK ASSESSMENTS ====="
grep -H -E 'Overall assessment:|PASS:.*WARN:.*FAIL:|ERROR:' "$REPORT_DIR"/weka*_deploy.log || true
echo "Reports: $REPORT_DIR"
echo "No reboots were requested. Accepted warnings remain open for review."
if grep -Eq 'BACKUP_OR_SSH_FAILED|COPY_FAILED|FAILED_REVIEW_LOG' "$REPORT_DIR/summary.txt"; then
  exit 1
fi
