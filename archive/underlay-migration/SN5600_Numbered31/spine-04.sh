#!/bin/bash
set -euo pipefail
SN_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
case "${1:-}" in
  roce-check|roce-enable|roce-validate|roce-rollback)
    SN_ROCE_ACTION=${1#roce-}
    shift
    exec python3 "$SN_DIR/roce.py" spine-04 "$SN_ROCE_ACTION" "$@"
    ;;
  *) exec python3 "$SN_DIR/migrate.py" spine-04 "$@" ;;
esac
