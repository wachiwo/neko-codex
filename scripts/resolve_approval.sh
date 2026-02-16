#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage:
  scripts/resolve_approval.sh --id appr_xxx --decision approved|rejected [--note "optional"]
  scripts/resolve_approval.sh --task-id bridge_032 --decision approved|rejected [--note "optional"]

Behavior:
  - Updates queue/approval_required.yaml status from pending to approved/rejected
  - When --task-id is used, resolves the most recent pending entry for that task
USAGE
}

approval_file="queue/approval_required.yaml"
id=""
task_id=""
decision=""
note=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --id) id="${2:-}"; shift 2 ;;
    --task-id) task_id="${2:-}"; shift 2 ;;
    --decision) decision="${2:-}"; shift 2 ;;
    --note) note="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$decision" || ( -z "$id" && -z "$task_id" ) ]]; then
  echo "Either --id or --task-id, and --decision are required" >&2
  exit 2
fi

if [[ "$decision" != "approved" && "$decision" != "rejected" ]]; then
  echo "--decision must be approved or rejected" >&2
  exit 2
fi

if [[ ! -f "$approval_file" ]]; then
  echo "approval file not found: $approval_file" >&2
  exit 1
fi

if [[ -z "$id" ]]; then
  id="$(awk -v tid="$task_id" '
    BEGIN{in_block=0; cur_id=""; cur_task=""; cur_status=""; last=""}
    /^  - id:/ {
      if (cur_task==tid && cur_status=="pending") {last=cur_id}
      cur_id=$3; cur_task=""; cur_status=""
      next
    }
    /^    task_id:/ {cur_task=$2; next}
    /^    status:/ {cur_status=$2; next}
    END {
      if (cur_task==tid && cur_status=="pending") {last=cur_id}
      print last
    }
  ' "$approval_file")"
  if [[ -z "$id" ]]; then
    echo "no pending approval found for task_id=${task_id}" >&2
    exit 1
  fi
fi

ts="$(date '+%Y-%m-%dT%H:%M:%S%z')"
tmp="$(mktemp)"
esc_note="$(printf '%s' "$note" | sed 's/"/\\"/g')"

awk -v target="$id" -v decision="$decision" -v ts="$ts" -v note="$esc_note" '
  BEGIN{in_target=0; resolved=0}
  /^  - id:/ {
    if ($3==target) {in_target=1} else {in_target=0}
  }
  {
    if (in_target && $1=="status:") {
      print "    status: " decision
      resolved=1
      next
    }
    if (in_target && $1=="updated_at:") {
      print "    updated_at: \"" ts "\""
      next
    }
    print
    if (in_target && note!="" && $1=="updated_at:") {
      print "    decision_note: \"" note "\""
    }
  }
  END{
    if (!resolved) {
      exit 3
    }
  }
' "$approval_file" > "$tmp" || {
  rc=$?
  rm -f "$tmp"
  if [[ $rc -eq 3 ]]; then
    echo "approval id not found: ${id}" >&2
    exit 1
  fi
  exit $rc
}

mv "$tmp" "$approval_file"
echo "approval_resolved|id=${id}|decision=${decision}"
