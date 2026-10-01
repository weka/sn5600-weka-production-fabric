#!/usr/bin/env bash
# Mac runner: 4 representative clients, 12 directed tests, 2 NICs per test.
set -uo pipefail
# Optional automatic authentication: supply SSHPASS only when launching.
if [ -n "${SSHPASS:-}" ]; then
  command -v sshpass >/dev/null 2>&1 || {
    echo "STOP: install sshpass on the Mac with: brew install sshpass"; exit 1;
  }
  export SSHPASS
  ssh() { sshpass -e ssh -o NumberOfPasswordPrompts=1 "$@"; }
fi
if [ "${1:-}" = --resume ]; then
  REPORT_DIR="${2:-}"
  [ -s "$REPORT_DIR/summary.tsv" ] || { echo "Usage: bash $0 --resume EXISTING_REPORT_DIRECTORY"; exit 1; }
  cp -p "$REPORT_DIR/summary.tsv" "$REPORT_DIR/summary-before-resume-$(date +%Y%m%d_%H%M%S).tsv" || exit 1
  # Preserve measured results when only server-log collection failed.
  while IFS=$'\t' read -r SRC DST B0 B1 TOTAL STATUS; do
    if [ "$STATUS" = FAILED ] && grep -Fxq 'EXIT|0|0' "$REPORT_DIR/${SRC}_to_${DST}_client.log" 2>/dev/null &&
       [ -n "$B0" ] && [ -n "$B1" ]; then
      printf '%s\t%s\t%s\t%s\t%s\tCOMPLETED_LOG_COLLECTION_WARNING\n' "$SRC" "$DST" "$B0" "$B1" "$TOTAL"
    else
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$SRC" "$DST" "$B0" "$B1" "$TOTAL" "$STATUS"
    fi
  done < "$REPORT_DIR/summary.tsv" > "$REPORT_DIR/summary-resume.tmp"
  mv "$REPORT_DIR/summary-resume.tmp" "$REPORT_DIR/summary.tsv"
else
  REPORT_DIR="$HOME/Downloads/RoCE_Cross_Leaf_$(date +%Y%m%d_%H%M%S)"
fi
mkdir -p "$REPORT_DIR" || exit 1
RUN_ID=$(date +%Y%m%dT%H%M%S)
SSH_OPTS=(-o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=3)
[ -s "$REPORT_DIR/summary.tsv" ] || printf 'SOURCE\tDESTINATION\tMLX5_0_Gbps\tMLX5_1_Gbps\tCOMBINED_Gbps\tRESULT\n' > "$REPORT_DIR/summary.tsv"
echo "Reports: $REPORT_DIR"

cat > "$REPORT_DIR/preflight.sh" <<'REMOTE'
set -euo pipefail
trap 'echo "FAIL: preflight line $LINENO: $BASH_COMMAND" >&2' ERR
H="$1"
for CMD in ib_write_bw timeout python3 rdma ethtool; do command -v "$CMD"; done
HELP_LOG=$(mktemp /tmp/roce-perftest-help.XXXXXX)
# Capture fully: grep -q on a live pipe can cause SIGPIPE under pipefail.
# Some perftest versions also return a nonzero status for --help.
ib_write_bw --help > "$HELP_LOG" 2>&1 || true
if ! grep -q -- --tclass "$HELP_LOG"; then
  cat "$HELP_LOG"
  echo "FAIL: installed ib_write_bw does not advertise --tclass"
  rm -f "$HELP_LOG"
  exit 1
fi
rm -f "$HELP_LOG"
echo "PASS: ib_write_bw supports --tclass"
systemctl is-active weka-roce.service
rdma link show
for K in 0 1; do
  D="mlx5_$K"
  P="/sys/class/infiniband/$D/ports/1"
  [ "$(cat "$P/link_layer")" = Ethernet ]
  grep -q ACTIVE "$P/state"
  [ "$(cat "$P/gid_attrs/types/3")" = 'RoCE v2' ]
  I=$(cat "$P/gid_attrs/ndevs/3")
  OCTET=$((K*2+1)); EXPECTED="10.200.$H.$OCTET"
  python3 - "$P/gids/3" "$EXPECTED" <<'PY'
import ipaddress,sys
gid=ipaddress.IPv6Address(open(sys.argv[1]).read().strip())
assert str(gid.ipv4_mapped)==sys.argv[2], (str(gid),sys.argv[2])
PY
  ip -4 -o addr show dev "$I" | awk '{print $4}' | grep -Fxq "$EXPECTED/31"
  [ "$(cat /sys/class/net/"$I"/operstate)" = up ]
  [ "$(cat /sys/class/net/"$I"/mtu)" = 9000 ]
  echo "$D GID3=$EXPECTED netdev=$I speedMbps=$(cat /sys/class/net/"$I"/speed)"
done
echo "PREFLIGHT_PASS|weka$H"
REMOTE

cat > "$REPORT_DIR/counters.sh" <<'REMOTE'
echo "===== $(hostname) $(date -u +%FT%TZ) ====="
for D in mlx5_0 mlx5_1; do
  I=$(cat /sys/class/infiniband/"$D"/ports/1/gid_attrs/ndevs/3)
  echo "===== $D $I ====="
  ethtool -S "$I" | grep -E 'rx_ecn_mark:|rx_crc_errors_phy:|rx_discards_phy:|tx_discards_phy:|tx_errors_phy:|rx_prio3_discards:|rx_prio3_pause:|tx_prio3_pause:|tx_pause_storm' || true
done
REMOTE

cat > "$REPORT_DIR/server.sh" <<'REMOTE'
set -euo pipefail
DIR="$1"
mkdir -p "$DIR"
for PORT in 18615 18616; do
  if ss -ltnH "sport = :$PORT" | grep -q .; then
    echo "STOP: TCP port $PORT already used"; exit 1
  fi
done
for K in 0 1; do
  PORT=$((18615+K))
  nohup timeout 180 ib_write_bw -d "mlx5_$K" -x 3 -F -D 30 \
    --tclass 106 --report_gbits -p "$PORT" > "$DIR/mlx5_${K}.log" 2>&1 < /dev/null &
  echo "$!" > "$DIR/mlx5_${K}.pid"
done
for ATTEMPT in $(seq 1 10); do
  if [ "$(ss -ltnH 'sport = :18615 or sport = :18616' | wc -l)" -eq 2 ]; then
    echo "SERVERS_READY"; exit 0
  fi
  sleep 1
done
cat "$DIR"/*.log
echo "STOP: benchmark listeners not ready"; exit 1
REMOTE

cat > "$REPORT_DIR/client.sh" <<'REMOTE'
set -uo pipefail
DIR="$1"; TARGET="$2"
mkdir -p "$DIR"
timeout 90 ib_write_bw -d mlx5_0 -x 3 -F -D 30 --tclass 106 \
  --report_gbits -p 18615 "$TARGET" > "$DIR/mlx5_0.log" 2>&1 &
P0=$!
timeout 90 ib_write_bw -d mlx5_1 -x 3 -F -D 30 --tclass 106 \
  --report_gbits -p 18616 "$TARGET" > "$DIR/mlx5_1.log" 2>&1 &
P1=$!
wait "$P0"; R0=$?
wait "$P1"; R1=$?
for K in 0 1; do
  echo "===== mlx5_$K ====="
  cat "$DIR/mlx5_${K}.log"
  BW=$(awk '$1==65536 && NF>=5 {v=$4} END {print v}' "$DIR/mlx5_${K}.log")
  echo "BW|$K|$BW"
done
echo "EXIT|$R0|$R1"
[ "$R0" -eq 0 ] && [ "$R1" -eq 0 ]
REMOTE

echo "===== PREFLIGHT FOUR REPRESENTATIVE CLIENTS ====="
for H in 68 60 49 40; do
  if ! ssh "${SSH_OPTS[@]}" "root@172.31.18.$H" bash -s -- "$H" \
    < "$REPORT_DIR/preflight.sh" 2>&1 | tee "$REPORT_DIR/weka${H}_preflight.log"; then
    echo "STOP: weka$H preflight failed. No bandwidth tests started."; exit 1
  fi
  ssh "${SSH_OPTS[@]}" "root@172.31.18.$H" bash -s < "$REPORT_DIR/counters.sh" \
    > "$REPORT_DIR/weka${H}_counters_before_${RUN_ID}.log" 2>&1 || exit 1
done

FAILED=0
for PAIR in 68,60 60,68 68,49 49,68 68,40 40,68 60,49 49,60 60,40 40,60 49,40 40,49; do
  SRC=${PAIR%,*}; DST=${PAIR#*,}
  TAG="weka${SRC}_to_weka${DST}"
  if awk -F '\t' -v s="weka$SRC" -v d="weka$DST" '$1==s && $2==d && $6 ~ /^COMPLETED/ {ok=1} END {exit !ok}' "$REPORT_DIR/summary.tsv"; then
    echo "SKIP $TAG: successful measured result already recorded"
    continue
  fi
  REMOTE_DIR="/root/roce-cross-leaf-$RUN_ID/$TAG"
  echo "===== $TAG: BOTH NICS, 30 SECONDS ====="
  if ! ssh "${SSH_OPTS[@]}" "root@172.31.18.$DST" bash -s -- "$REMOTE_DIR" \
    < "$REPORT_DIR/server.sh" 2>&1 | tee "$REPORT_DIR/${TAG}_startup.log"; then
    echo "STOP: server startup failed. Started servers expire after 180 seconds."
    FAILED=1; break
  fi
  RC=0
  ssh "${SSH_OPTS[@]}" "root@172.31.18.$SRC" bash -s -- "$REMOTE_DIR" "172.31.18.$DST" \
    < "$REPORT_DIR/client.sh" 2>&1 | tee "$REPORT_DIR/${TAG}_client.log" || RC=$?
  COLLECTED=0
  for TRY in 1 2 3; do
    if ssh "${SSH_OPTS[@]}" "root@172.31.18.$DST" \
      "cat '$REMOTE_DIR/mlx5_0.log' '$REMOTE_DIR/mlx5_1.log'" \
      > "$REPORT_DIR/${TAG}_server_attempt${TRY}.log" 2>&1; then
      cp "$REPORT_DIR/${TAG}_server_attempt${TRY}.log" "$REPORT_DIR/${TAG}_server.log"
      COLLECTED=1; break
    fi
    echo "WARNING: server-log retrieval failed (attempt $TRY of 3)"
    sleep 2
  done
  B0=$(awk -F '|' '$1=="BW" && $2==0 {print $3}' "$REPORT_DIR/${TAG}_client.log")
  B1=$(awk -F '|' '$1=="BW" && $2==1 {print $3}' "$REPORT_DIR/${TAG}_client.log")
  TOTAL=$(awk -v a="$B0" -v b="$B1" 'BEGIN {printf "%.2f",a+b}')
  STATUS=COMPLETED
  [ "$COLLECTED" -eq 1 ] || STATUS=COMPLETED_LOG_COLLECTION_WARNING
  if [ "$RC" -ne 0 ] || [ -z "$B0" ] || [ -z "$B1" ]; then STATUS=FAILED; FAILED=1; fi
  awk -F '\t' -v s="weka$SRC" -v d="weka$DST" '!($1==s && $2==d)' "$REPORT_DIR/summary.tsv" > "$REPORT_DIR/summary-row.tmp"
  mv "$REPORT_DIR/summary-row.tmp" "$REPORT_DIR/summary.tsv"
  printf 'weka%s\tweka%s\t%s\t%s\t%s\t%s\n' "$SRC" "$DST" "$B0" "$B1" "$TOTAL" "$STATUS" >> "$REPORT_DIR/summary.tsv"
  if [ "$FAILED" -eq 1 ]; then
    echo "STOP: review $TAG logs. Benchmark processes have bounded timeouts."; break
  fi
done
for H in 68 60 49 40; do
  ssh "${SSH_OPTS[@]}" "root@172.31.18.$H" bash -s < "$REPORT_DIR/counters.sh" \
    > "$REPORT_DIR/weka${H}_counters_after.log" 2>&1 || FAILED=1
done
echo "===== CROSS-LEAF BANDWIDTH SUMMARY ====="
cat "$REPORT_DIR/summary.tsv"
echo "Reports: $REPORT_DIR"
echo "COMPLETED means the benchmark succeeded; throughput and counter changes still need review."
echo "Leaf-01's 200G NICs limit those pairs. Other pairs use 400G NICs."
echo "This tests representative routes, not every ECMP uplink, congestion response or WEKA application I/O."
awk -F '\t' '
BEGIN {
  split("weka68 weka60 weka49 weka40",h," ")
  leaf["weka68"]="Leaf-01"; leaf["weka60"]="Leaf-02"; leaf["weka49"]="Leaf-03"; leaf["weka40"]="Leaf-04"
  print "<!doctype html><html lang=\"en\"><meta charset=\"utf-8\"><title>RoCE cross-leaf bandwidth</title>"
  print "<style>body{font-family:Arial,sans-serif;color:#142b3b;background:#f4f7fa;margin:40px}main{max-width:1100px;margin:auto;background:white;padding:32px;border-radius:14px}h1{font-size:28px}p{line-height:1.5;color:#526474}table{border-collapse:separate;border-spacing:6px;width:100%;table-layout:fixed}th{font-size:14px;padding:14px}td{text-align:center;padding:22px 8px;border-radius:8px;height:72px}strong{font-size:24px}small{display:block;margin-top:7px;font-size:12px}.muted{background:#eef2f5;color:#62717b}.failed{background:#fde8e7;color:#992a28}@media print{body{margin:0;background:white}main{padding:12px}td{-webkit-print-color-adjust:exact;print-color-adjust:exact}}</style><main>"
  print "<h1>RoCE bandwidth across the leaf–spine fabric</h1><p>Rows = source; columns = destination. Each result combines two NICs running concurrently for 30 seconds. Values are measured RDMA write bandwidth in Gbit/s.</p>"
}
NR>1 { key=$1 SUBSEP $2; b0[key]=$3; b1[key]=$4; total[key]=$5; status[key]=$6 }
END {
  print "<table><tr><th>Source ↓ / Destination →</th>"
  for(j=1;j<=4;j++) printf "<th>%s<br>%s</th>",leaf[h[j]],h[j]
  print "</tr>"
  for(i=1;i<=4;i++) {
    printf "<tr><th>%s<br>%s</th>",leaf[h[i]],h[i]
    for(j=1;j<=4;j++) {
      k=h[i] SUBSEP h[j]
      if(i==j) print "<td class=\"muted\">Same leaf<br><small>Not tested here</small></td>"
      else if(!(k in status)) print "<td class=\"muted\">Not tested</td>"
      else if(status[k] !~ /^COMPLETED/) print "<td class=\"failed\"><strong>Failed</strong><small>Review benchmark logs</small></td>"
      else {
        cap=(h[i]=="weka68" || h[j]=="weka68") ? 400 : 800
        ratio=total[k]/cap; shade=ratio; if(shade>1)shade=1; if(shade<0)shade=0
        color=sprintf("hsl(192,55%%,%.1f%%)",96-60*shade)
        ink=(shade>0.65)?"white":"#142b3b"
        printf "<td style=\"background:%s;color:%s\"><strong>%.2f</strong><small>NIC 0: %.2f · NIC 1: %.2f</small><small>%.1f%% of %dG combined link rate</small></td>",color,ink,total[k],b0[k],b1[k],100*ratio,cap
      }
    }
    print "</tr>"
  }
  print "</table><p><b>Color scale:</b> pale to dark blue indicates increasing throughput relative to the slower endpoint’s combined nominal link rate. This is a comparison scale, not a pass/fail threshold. Leaf-01 has 2 × 200G NICs; the other selected clients have 2 × 400G NICs.</p>"
  for(k in status) if(status[k]=="COMPLETED_LOG_COLLECTION_WARNING") {
    split(k,p,SUBSEP)
    printf "<p><b>Evidence note:</b> %s → %s succeeded in both client benchmark logs; server-log retrieval failed. See summary.tsv and SSH logs.</p>",p[1],p[2]
  }
  print "<p><b>Scope:</b> one representative client per leaf, all six leaf pairs in both directions. This does not validate every ECMP uplink, congestion behavior, failover, every client, or WEKA application performance. Physical and congestion counter snapshots are saved separately.</p>"
  print "<p>Control connections use management IPs; RDMA data uses verified RoCE v2 GID index 3 on the 10.200 datapath. Traffic class is explicitly set to 106.</p></main></html>"
}' "$REPORT_DIR/summary.tsv" > "$REPORT_DIR/heatmap.html"
echo "Shareable heatmap: $REPORT_DIR/heatmap.html"
[ "$FAILED" -eq 0 ]
