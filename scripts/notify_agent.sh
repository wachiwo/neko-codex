#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage:
  scripts/notify_agent.sh --to <agent> --message <text> [--from <sender>] [--event <event>] [--task <task_id>] [--inbox-only] [--strict-tmux] [--allow-degraded]

Options:
  --to        Destination agent (worker1|worker2|worker3|worker4|kashira|oyabun)
  --message   Message sent to tmux pane
  --from      Sender name for inbox record (default: kashira)
  --event     Inbox event name (default: notify)
  --task      Task ID for inbox record (default: -)
  --inbox-only  Write inbox entry only; skip tmux send-keys
  --strict-tmux  Fail if tmux send-keys fails
  --allow-degraded  Allow degraded success even when tmux send fails
USAGE
}

agent=""
message=""
sender="kashira"
event="notify"
task_id="-"
inbox_only=0
strict_tmux=1
allow_degraded=0
guard_note=""
report_rejected=0

apply_report_done_guard() {
  if [[ "$sender" =~ ^worker[1-4]$ && "$event" == "report_done" ]]; then
    if ! guard_note="$(scripts/worker_seq_guard.sh --worker "$sender" --mode complete --allow-implicit-preflight 2>&1)"; then
      report_rejected=1
      event="report_rejected_seq_guard"
      message="SEQ_GUARD_REJECTED|worker=${sender}|task=${task_id}|detail=${guard_note}"
      printf '%s|seq_guard|report_rejected|worker=%s|task=%s|detail=%s\n' \
        "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$sender" "$task_id" "$guard_note" >> queue/inbox/kashira.queue
    fi
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --to)
      agent="${2:-}"
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
      strict_tmux=0
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

if [[ -z "$agent" ]]; then
  echo "--to is required" >&2
  exit 2
fi

if [[ -z "$message" && $inbox_only -eq 0 ]]; then
  echo "--message is required unless --inbox-only is used" >&2
  exit 2
fi

apply_report_done_guard

case "$agent" in
  worker1) pane="nekocodex:1.0" ;;
  worker2) pane="nekocodex:2.0" ;;
  worker3) pane="nekocodex:3.0" ;;
  worker4) pane="nekocodex:4.0" ;;
  kashira) pane="nekocodex:0.0" ;;
  oyabun)  pane="oyabun:0.0" ;;
  *)
    echo "Unsupported agent: $agent" >&2
    exit 2
    ;;
esac

mkdir -p queue/inbox
inbox_file="queue/inbox/${agent}.queue"
ts="$(date '+%Y-%m-%dT%H:%M:%S%z')"

if [[ $inbox_only -eq 1 ]]; then
  printf '%s|%s|%s|%s\n' "$ts" "$sender" "$event" "$task_id" >> "$inbox_file"
  scripts/update_agent_status.sh >/dev/null 2>&1 || true
  echo "inbox_only_done|to=${agent}|event=${event}|task=${task_id}"
  exit 0
fi

# Keep message + Enter in two separate tmux calls as required by system rules.
if tmux send-keys -t "$pane" "$message" && tmux send-keys -t "$pane" Enter; then
  printf '%s|%s|%s|%s\n' "$ts" "$sender" "$event" "$task_id" >> "$inbox_file"
  if [[ "$sender" =~ ^worker[1-4]$ ]] && [[ "$task_id" != "-" ]]; then
    case "$event" in
      task_ack|first_action|report_done)
        scripts/worker_handshake_watchdog.sh mark --task "$task_id" --worker "$sender" --event "$event" >/dev/null 2>&1 || true
        ;;
    esac
  fi
  scripts/update_agent_status.sh >/dev/null 2>&1 || true
  if [[ $report_rejected -eq 1 ]]; then
    echo "notify_done|to=${agent}|pane=${pane}|event=${event}|task=${task_id}|guard=rejected"
  else
    echo "notify_done|to=${agent}|pane=${pane}|event=${event}|task=${task_id}"
  fi
  exit 0
fi

printf '%s|%s|notify_failed|%s\n' "$ts" "$sender" "$task_id" >> "$inbox_file"
printf '%s|notify_agent|notify_failed|to=%s|event=%s|task=%s|sender=%s\n' \
  "$ts" "$agent" "$event" "$task_id" "$sender" >> queue/inbox/kashira.queue

if [[ $strict_tmux -eq 1 && $allow_degraded -eq 0 ]]; then
  scripts/update_agent_status.sh >/dev/null 2>&1 || true
  echo "notify_failed|to=${agent}|pane=${pane}|event=${event}|task=${task_id}" >&2
  exit 1
fi

scripts/update_agent_status.sh >/dev/null 2>&1 || true
if [[ $report_rejected -eq 1 ]]; then
  echo "notify_degraded|to=${agent}|pane=${pane}|event=${event}|task=${task_id}|guard=rejected|reason=tmux_failed|allow_degraded=${allow_degraded}"
else
  echo "notify_degraded|to=${agent}|pane=${pane}|event=${event}|task=${task_id}|reason=tmux_failed|allow_degraded=${allow_degraded}"
fi
