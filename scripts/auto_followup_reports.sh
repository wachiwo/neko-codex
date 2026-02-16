#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage:
  scripts/auto_followup_reports.sh \
    --workers worker2,worker3 \
    --task cmd_003 \
    --message 'Check queue/tasks/workerN.yaml (cmd_003 pending)' \
    [--attempts 3] [--interval 20] [--from kashira]

Behavior:
  - Checks if each worker report for the task exists in queue/reports.
  - If missing, sends reminder via scripts/notify_agent.sh.
  - Repeats until all reports arrive or max attempts reached.
USAGE
}

workers_csv=""
task_id=""
message=""
attempts=3
interval=20
sender="kashira"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workers)
      workers_csv="${2:-}"
      shift 2
      ;;
    --task)
      task_id="${2:-}"
      shift 2
      ;;
    --message)
      message="${2:-}"
      shift 2
      ;;
    --attempts)
      attempts="${2:-}"
      shift 2
      ;;
    --interval)
      interval="${2:-}"
      shift 2
      ;;
    --from)
      sender="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$workers_csv" || -z "$task_id" || -z "$message" ]]; then
  echo "--workers, --task, --message are required" >&2
  exit 2
fi

IFS=',' read -r -a workers <<< "$workers_csv"

report_exists() {
  local worker="$1"
  local exact="queue/reports/${worker}_${task_id}_report.yaml"
  local expanded="queue/reports/${worker}_${task_id}_*_report.yaml"
  [[ -f "$exact" ]] || compgen -G "$expanded" >/dev/null
}

pending_workers() {
  local w
  local pending=()
  for w in "${workers[@]}"; do
    if ! report_exists "$w"; then
      pending+=("$w")
    fi
  done
  echo "${pending[*]}"
}

attempt=1
while [[ $attempt -le $attempts ]]; do
  pending="$(pending_workers)"
  if [[ -z "$pending" ]]; then
    echo "all_reports_received|task=${task_id}"
    exit 0
  fi

  notify_fail=0
  for w in $pending; do
    if ! scripts/notify_agent.sh \
      --to "$w" \
      --from "$sender" \
      --event task_reminder \
      --task "$task_id" \
      --message "$message" \
      --strict-tmux; then
      notify_fail=1
    fi
  done

  if [[ $notify_fail -eq 1 ]]; then
    echo "notify_failed|task=${task_id}|attempt=${attempt}|pending=${pending}" >&2
  fi

  if [[ $attempt -lt $attempts ]]; then
    sleep "$interval"
  fi

  attempt=$((attempt + 1))
done

pending="$(pending_workers)"
echo "retry_exhausted|task=${task_id}|pending=${pending}"
exit 1
