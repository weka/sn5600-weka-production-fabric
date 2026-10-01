#!/usr/bin/env bash
# Creates a PRIVATE repo, commits reviewed local files and pushes. Run on the Mac.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TARGET="${1:-}"
[[ "$TARGET" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || {
  echo "Usage: bash scripts/publish_github.sh OWNER/sn5600-weka-production-fabric"; exit 2;
}
command -v gh >/dev/null || { echo "GitHub CLI required; install it, then gh auth login"; exit 1; }
gh auth status
cd "$ROOT"
python3 scripts/validate_repository.py
bash scripts/update_checksums.sh
if [ ! -d .git ]; then git init -b main; fi
if git remote get-url origin >/dev/null 2>&1; then
  echo "STOP: origin already exists. Inspect it before pushing to another repository."; exit 1
fi
git add --all
if ! git diff --cached --quiet; then git commit -m 'Document production SN5600 WEKA fabric and validated rollout'; fi
gh repo create "$TARGET" --private --source "$ROOT" --remote origin --push
echo "Created private repository: https://github.com/$TARGET"
