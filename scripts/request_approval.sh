#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage:
  scripts/request_approval.sh \
    --task-id bridge_032 \
    --reason "External API charge risk" \
    [--source bridge] [--requested-by oyabun] [--risk-level high] [--action "Proceed with dispatch"]

Behavior:
  - Appends a pending approval item to queue/approval_required.yaml
  - Prevents duplicate pending entries for the same task_id
USAGE
}

task_id=""
reason=""
source="bridge"
requested_by="oyabun"
risk_level="high"
action="Manual approval required before execution"
approval_file="queue/approval_required.yaml"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --task-id) task_id="${2:-}"; shift 2 ;;
    --reason) reason="${2:-}"; shift 2 ;;
    --source) source="${2:-}"; shift 2 ;;
    --requested-by) requested_by="${2:-}"; shift 2 ;;
    --risk-level) risk_level="${2:-}"; shift 2 ;;
    --action) action="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$task_id" || -z "$reason" ]]; then
  echo "--task-id and --reason are required" >&2
  exit 2
fi

mkdir -p queue
if [[ ! -f "$approval_file" ]]; then
  echo "approvals: []" > "$approval_file"
fi

if awk -v id="$task_id" '
  BEGIN{in_block=0; t=""; s=""}
  /^  - id:/ {
    if (t==id && s=="pending") {found=1}
    in_block=1; t=""; s=""
  }
  in_block && /^    task_id:/ {t=$2}
  in_block && /^    status:/ {s=$2}
  END {
    if (t==id && s=="pending") {found=1}
    exit(found?0:1)
  }
' "$approval_file"; then
  echo "approval_pending_exists|task_id=${task_id}"
  exit 0
fi

ts="$(date '+%Y-%m-%dT%H:%M:%S%z')"
id="appr_${task_id}_$(date '+%Y%m%d%H%M%S')"
esc_reason="$(printf '%s' "$reason" | sed 's/"/\\"/g')"
esc_action="$(printf '%s' "$action" | sed 's/"/\\"/g')"

if grep -q '^approvals:[[:space:]]*\[\][[:space:]]*$' "$approval_file"; then
  cat > "$approval_file" <<EOF
approvals:
  - id: ${id}
    task_id: ${task_id}
    source: ${source}
    requested_by: ${requested_by}
    risk_level: ${risk_level}
    reason: "${esc_reason}"
    action: "${esc_action}"
    status: pending
    created_at: "${ts}"
    updated_at: "${ts}"
EOF
else
  cat >> "$approval_file" <<EOF
  - id: ${id}
    task_id: ${task_id}
    source: ${source}
    requested_by: ${requested_by}
    risk_level: ${risk_level}
    reason: "${esc_reason}"
    action: "${esc_action}"
    status: pending
    created_at: "${ts}"
    updated_at: "${ts}"
EOF
fi

echo "approval_requested|id=${id}|task_id=${task_id}|risk=${risk_level}"
