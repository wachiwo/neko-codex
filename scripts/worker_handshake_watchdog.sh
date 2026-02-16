#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage:
  scripts/worker_handshake_watchdog.sh init --task <task_id> --workers worker1,worker2 [--grace-sec 120]
  scripts/worker_handshake_watchdog.sh mark --task <task_id> --worker worker1 --event task_ack|first_action|report_done|closed
  scripts/worker_handshake_watchdog.sh await --task <task_id> --workers worker1,worker2 [--grace-sec 120] [--ack-timeout-sec 180] [--first-action-timeout-sec 300]

Behavior:
  - Persists task/worker handshake states in status/worker_handshake.tsv
  - Ingests queue/inbox/kashira.queue events for task_ack/first_action/report_done
  - await exits non-zero on handshake timeout
USAGE
}

cmd="${1:-}"
if [[ -z "$cmd" || "$cmd" == "-h" || "$cmd" == "--help" ]]; then
  usage
  exit 0
fi
shift || true

task_id=""
workers_csv=""
worker=""
event=""
grace_sec=120
ack_timeout_sec=180
first_action_timeout_sec=300

while [[ $# -gt 0 ]]; do
  case "$1" in
    --task) task_id="${2:-}"; shift 2 ;;
    --workers) workers_csv="${2:-}"; shift 2 ;;
    --worker) worker="${2:-}"; shift 2 ;;
    --event) event="${2:-}"; shift 2 ;;
    --grace-sec) grace_sec="${2:-}"; shift 2 ;;
    --ack-timeout-sec) ack_timeout_sec="${2:-}"; shift 2 ;;
    --first-action-timeout-sec) first_action_timeout_sec="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

state_file="status/worker_handshake.tsv"
inbox_file="queue/inbox/kashira.queue"
mkdir -p status queue/inbox
touch "$state_file"

is_int() {
  [[ "${1:-}" =~ ^[0-9]+$ ]]
}

for n in "$grace_sec" "$ack_timeout_sec" "$first_action_timeout_sec"; do
  if ! is_int "$n"; then
    echo "Timeout values must be integer seconds" >&2
    exit 2
  fi
done

set_row() {
  local task="$1"
  local w="$2"
  local assigned="$3"
  local ack="$4"
  local first="$5"
  local report="$6"
  local closed="$7"
  local state="$8"
  local now
  now="$(date '+%Y-%m-%dT%H:%M:%S%z')"
  tmp="$(mktemp)"
  awk -F'\t' -v OFS='\t' \
    -v t="$task" -v w="$w" \
    -v assigned="$assigned" -v ack="$ack" -v first="$first" -v report="$report" -v closed="$closed" -v state="$state" -v now="$now" '
    BEGIN { updated=0 }
    $1==t && $2==w {
      print t, w, assigned, ack, first, report, closed, state, now
      updated=1
      next
    }
    { print $0 }
    END {
      if (!updated) print t, w, assigned, ack, first, report, closed, state, now
    }
  ' "$state_file" > "$tmp"
  mv "$tmp" "$state_file"
}

get_row() {
  local task="$1"
  local w="$2"
  awk -F'\t' -v t="$task" -v w="$w" '
    $1==t && $2==w {
      print $0
      found=1
      exit
    }
    END { if (!found) print t "\t" w "\t\t\t\t\t\tunknown\t" }
  ' "$state_file"
}

mark_event() {
  local task="$1"
  local w="$2"
  local ev="$3"
  local now state assigned ack first report closed row
  now="$(date '+%Y-%m-%dT%H:%M:%S%z')"
  row="$(get_row "$task" "$w")"
  assigned="$(printf '%s' "$row" | cut -f3)"
  ack="$(printf '%s' "$row" | cut -f4)"
  first="$(printf '%s' "$row" | cut -f5)"
  report="$(printf '%s' "$row" | cut -f6)"
  closed="$(printf '%s' "$row" | cut -f7)"
  state="$(printf '%s' "$row" | cut -f8)"
  [[ -n "$assigned" ]] || assigned="$now"
  case "$ev" in
    task_ack)
      [[ -n "$ack" ]] || ack="$now"
      [[ -n "$first" ]] && state="started" || state="acked"
      ;;
    first_action)
      [[ -n "$ack" ]] || ack="$now"
      [[ -n "$first" ]] || first="$now"
      state="started"
      ;;
    report_done)
      [[ -n "$ack" ]] || ack="$now"
      [[ -n "$first" ]] || first="$now"
      [[ -n "$report" ]] || report="$now"
      state="reported"
      ;;
    closed)
      [[ -n "$closed" ]] || closed="$now"
      state="closed"
      ;;
    *)
      echo "Unsupported event: $ev" >&2
      exit 2
      ;;
  esac
  set_row "$task" "$w" "$assigned" "$ack" "$first" "$report" "$closed" "$state"
}

ingest_events() {
  local task="$1"
  [[ -f "$inbox_file" ]] || return 0
  awk -F'|' -v t="$task" '
    $4==t && ($3=="task_ack" || $3=="first_action" || $3=="report_done") {
      print $2 "|" $3
    }
  ' "$inbox_file" | while IFS='|' read -r w ev; do
    [[ "$w" =~ ^worker[1-4]$ ]] || continue
    mark_event "$task" "$w" "$ev"
  done
}

report_exists_for_task() {
  local worker="$1"
  local task="$2"
  [[ -n "$task" ]] || return 1
  [[ -f "queue/reports/${worker}_${task}_report.yaml" ]] && return 0
  compgen -G "queue/reports/${worker}_${task}_*_report.yaml" >/dev/null
}

ingest_report_files() {
  local task="$1"
  local workers="$2"
  local w
  IFS=',' read -r -a ws <<< "$workers"
  for w in "${ws[@]}"; do
    if report_exists_for_task "$w" "$task"; then
      mark_event "$task" "$w" report_done
    fi
  done
}

all_started() {
  local task="$1"
  local workers="$2"
  local w first report row
  IFS=',' read -r -a ws <<< "$workers"
  for w in "${ws[@]}"; do
    row="$(get_row "$task" "$w")"
    first="$(printf '%s' "$row" | cut -f5)"
    report="$(printf '%s' "$row" | cut -f6)"
    if [[ -z "$first" && -z "$report" ]]; then
      return 1
    fi
  done
  return 0
}

check_timeout() {
  local task="$1"
  local workers="$2"
  local now_epoch assigned_epoch assigned ack first report w state elapsed row closed
  now_epoch="$(date +%s)"
  IFS=',' read -r -a ws <<< "$workers"
  for w in "${ws[@]}"; do
    row="$(get_row "$task" "$w")"
    assigned="$(printf '%s' "$row" | cut -f3)"
    ack="$(printf '%s' "$row" | cut -f4)"
    first="$(printf '%s' "$row" | cut -f5)"
    report="$(printf '%s' "$row" | cut -f6)"
    closed="$(printf '%s' "$row" | cut -f7)"
    state="$(printf '%s' "$row" | cut -f8)"
    [[ -n "$assigned" ]] || continue
    [[ -n "$closed" ]] && continue
    assigned_epoch="$(date -d "$assigned" +%s 2>/dev/null || true)"
    [[ -n "$assigned_epoch" ]] || continue
    elapsed=$((now_epoch - assigned_epoch))
    if (( elapsed < grace_sec )); then
      continue
    fi
    if [[ -z "$ack" ]] && (( elapsed > grace_sec + ack_timeout_sec )); then
      set_row "$task" "$w" "$assigned" "$ack" "$first" "$report" "$closed" "ack_timeout"
      echo "handshake_timeout|task=${task}|worker=${w}|phase=ack|elapsed_sec=${elapsed}"
      return 1
    fi
    if [[ -z "$first" && -z "$report" ]] && (( elapsed > grace_sec + first_action_timeout_sec )); then
      set_row "$task" "$w" "$assigned" "$ack" "$first" "$report" "$closed" "first_action_timeout"
      echo "handshake_timeout|task=${task}|worker=${w}|phase=first_action|elapsed_sec=${elapsed}"
      return 1
    fi
    [[ "$state" == "reported" || "$state" == "started" || "$state" == "acked" || "$state" == "assigned" || "$state" == "unknown" ]] || true
  done
  return 0
}

case "$cmd" in
  init)
    [[ -n "$task_id" && -n "$workers_csv" ]] || { echo "--task and --workers are required" >&2; exit 2; }
    now="$(date '+%Y-%m-%dT%H:%M:%S%z')"
    IFS=',' read -r -a ws <<< "$workers_csv"
    for w in "${ws[@]}"; do
      set_row "$task_id" "$w" "$now" "" "" "" "" "assigned"
    done
    echo "handshake_init|task=${task_id}|workers=${workers_csv}"
    ;;
  mark)
    [[ -n "$task_id" && -n "$worker" && -n "$event" ]] || { echo "--task, --worker, --event are required" >&2; exit 2; }
    mark_event "$task_id" "$worker" "$event"
    echo "handshake_marked|task=${task_id}|worker=${worker}|event=${event}"
    ;;
  await)
    [[ -n "$task_id" && -n "$workers_csv" ]] || { echo "--task and --workers are required" >&2; exit 2; }
    while true; do
      ingest_events "$task_id"
      ingest_report_files "$task_id" "$workers_csv"
      if all_started "$task_id" "$workers_csv"; then
        echo "handshake_ok|task=${task_id}|workers=${workers_csv}"
        exit 0
      fi
      timeout_msg="$(check_timeout "$task_id" "$workers_csv" || true)"
      if [[ -n "$timeout_msg" ]]; then
        echo "$timeout_msg" >&2
        exit 1
      fi
      sleep 1
    done
    ;;
  *)
    echo "Unknown command: $cmd" >&2
    usage >&2
    exit 2
    ;;
esac
