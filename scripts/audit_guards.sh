#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage:
  scripts/audit_guards.sh [--warn-violations 3] [--warn-pending-hours 24]

Behavior:
  - Audits guard and approval queue signals
  - Writes:
      status/guard_audit.yaml
      status/guard_audit.md
USAGE
}

warn_violations=3
warn_pending_hours=24

while [[ $# -gt 0 ]]; do
  case "$1" in
    --warn-violations) warn_violations="${2:-}"; shift 2 ;;
    --warn-pending-hours) warn_pending_hours="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
cd "$repo_root"

mkdir -p status
now="$(date '+%Y-%m-%dT%H:%M:%S%z')"
now_epoch="$(date +%s)"

violations=0
if [[ -f status/bridge_guard_violations.tsv ]]; then
  violations="$(wc -l < status/bridge_guard_violations.tsv)"
fi

pending=0
old_pending=0
if [[ -f queue/approval_required.yaml ]]; then
  while IFS='|' read -r status created; do
    [[ "$status" == "pending" ]] || continue
    pending=$((pending + 1))
    if [[ -n "$created" ]]; then
      created_epoch="$(date -d "$created" +%s 2>/dev/null || echo 0)"
      if (( created_epoch > 0 )); then
        age_hours=$(( (now_epoch - created_epoch) / 3600 ))
        if (( age_hours >= warn_pending_hours )); then
          old_pending=$((old_pending + 1))
        fi
      fi
    fi
  done < <(
    awk '
      BEGIN{status=""; created=""}
      /^  - id:/ {
        if (status!="") {
          print status "|" created
        }
        status=""
        created=""
        next
      }
      /^    status:/ {status=$2; next}
      /^    created_at:/ {gsub(/"/, "", $2); created=$2; next}
      END{
        if (status!="") {
          print status "|" created
        }
      }
    ' queue/approval_required.yaml
  )
fi

health="ok"
if (( violations >= warn_violations || old_pending > 0 )); then
  health="warn"
fi

{
  echo "timestamp: \"$now\""
  echo "health: \"$health\""
  echo "violations: \"$violations\""
  echo "pending_approvals: \"$pending\""
  echo "old_pending_approvals: \"$old_pending\""
  echo "threshold_warn_violations: \"$warn_violations\""
  echo "threshold_warn_pending_hours: \"$warn_pending_hours\""
} > status/guard_audit.yaml

{
  echo "# Guard Audit"
  echo "updated: $now"
  echo
  echo "- health: $health"
  echo "- violations: $violations (warn>=${warn_violations})"
  echo "- pending_approvals: $pending"
  echo "- old_pending_approvals: $old_pending (warn if >=1 over ${warn_pending_hours}h)"
} > status/guard_audit.md

echo "guard_audit_done|health=${health}|violations=${violations}|pending=${pending}|old_pending=${old_pending}"
