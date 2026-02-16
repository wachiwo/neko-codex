#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage:
  scripts/notify_workers.sh --workers <list> --message <text> [--from <sender>] [--event <event>] [--task <task_id>] [--inbox-only] [--strict-tmux] [--allow-degraded]

Examples:
  scripts/notify_workers.sh --workers worker1,worker2,worker3 --message 'Check queue/tasks/workerN.yaml' --event task_assigned --task cmd_003
USAGE
}

workers_csv=""
message=""
sender="kashira"
event="notify"
task_id="-"
inbox_only=0
strict_tmux=0
allow_degraded=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workers)
      workers_csv="${2:-}"
      shift 2
      ;;
    --message)
      message="${2:-}"
      shift 2
      ;;
    --from)
      sender="${2:-}"
      shift 2
      ;;
    --event)
      event="${2:-}"
      shift 2
      ;;
    --task)
      task_id="${2:-}"
      shift 2
      ;;
    --inbox-only)
      inbox_only=1
      shift
      ;;
    --strict-tmux)
      strict_tmux=1
      shift
      ;;
    --allow-degraded)
      allow_degraded=1
      shift
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

if [[ -z "$workers_csv" ]]; then
  echo "--workers is required" >&2
  exit 2
fi

IFS=',' read -r -a workers <<< "$workers_csv"
for w in "${workers[@]}"; do
  cmd=(scripts/notify_agent.sh --to "$w" --from "$sender" --event "$event" --task "$task_id")
  if [[ $inbox_only -eq 1 ]]; then
    cmd+=(--inbox-only)
  else
    cmd+=(--message "$message")
    if [[ $strict_tmux -eq 1 ]]; then
      cmd+=(--strict-tmux)
    fi
    if [[ $allow_degraded -eq 1 ]]; then
      cmd+=(--allow-degraded)
    fi
  fi
  "${cmd[@]}"
done
