#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
case "${1:-help}" in
  verify)
    cd "$ROOT"
    if command -v shasum >/dev/null; then shasum -a 256 -c SHA256SUMS
    else sha256sum -c SHA256SUMS; fi
    python3 scripts/validate_repository.py
    ;;
  all-switches) bash "$ROOT/scripts/check_fabric.sh" ;;
  leaf-check|leaf-validate|leaf-end-to-end|server-check|server-validate)
    ACTION="$1"; TARGET="${2:-}"
    [ -n "$TARGET" ] || { echo "Name a target; for example leaf-02 or weka60"; exit 2; }
    case "$ACTION" in leaf-*) ACTION="switch-${ACTION#leaf-}" ;; esac
    cd "$ROOT/packages/SN5600_Client31_Rollout_20260929"
    bash fabric.sh "$ACTION" "$TARGET"
    ;;
  *)
    echo "Read-only: bash run_checks.sh verify | all-switches"
    echo "Read-only target: leaf-check | leaf-validate | leaf-end-to-end LEAF"
    echo "Read-only target: server-check | server-validate HOST"
    echo "No underlay migration-era preflight is used as a current-state gate."
    ;;
esac
