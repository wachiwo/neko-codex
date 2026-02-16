#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage:
  scripts/check_system.sh

Behavior:
  - Runs lifecycle validation
  - Runs health snapshot
  - Runs guard audit
  - Prints consolidated exit status
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
cd "$repo_root"

rc=0

scripts/validate_lifecycle.sh || rc=1
scripts/health_snapshot.sh || rc=1
scripts/audit_guards.sh || rc=1

echo "check_system_done|rc=${rc}"
exit "$rc"
