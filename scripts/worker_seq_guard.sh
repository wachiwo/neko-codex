#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage:
  scripts/worker_seq_guard.sh --worker worker1 --mode preflight|complete [--allow-implicit-preflight]

Behavior:
  - preflight: reject task when seq <= last_processed_seq
  - complete : mark current seq as processed (requires accepted preflight)
  - complete + --allow-implicit-preflight:
      if preflight state is missing/mismatch but seq is fresh (seq > last_processed_seq),
      recover automatically and continue as completed
USAGE
}

worker=""
mode=""
allow_implicit_preflight=0
state_file="status/worker_seq_state.tsv"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --worker) worker="${2:-}"; shift 2 ;;
    --mode) mode="${2:-}"; shift 2 ;;
    --allow-implicit-preflight) allow_implicit_preflight=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$worker" in
  worker1|worker2|worker3|worker4) ;;
  *)
    echo "--worker must be worker1..worker4" >&2
    exit 2
    ;;
esac

case "$mode" in
  preflight|complete) ;;
  *)
    echo "--mode must be preflight or complete" >&2
    exit 2
    ;;
esac

mkdir -p status queue/inbox
touch "$state_file"

task_file="queue/tasks/${worker}.yaml"
task_id="$(awk -F': ' '/^[[:space:]]*task_id:/ {print $2; exit}' "$task_file" 2>/dev/null || true)"
seq="$(awk -F': ' '/^[[:space:]]*seq:/ {print $2; exit}' "$task_file" 2>/dev/null || true)"
ts_now="$(date '+%Y-%m-%dT%H:%M:%S%z')"

[[ -n "$task_id" && -n "$seq" ]] || {
  echo "guard_error|worker=${worker}|reason=missing_task_or_seq" >&2
  exit 1
}

state_row="$(
  awk -F'\t' -v w="$worker" '
    $1==w { print $0; found=1; exit }
    END { if (!found) print "" }
  ' "$state_file"
)"

last_seq="$(
  awk -F'\t' -v w="$worker" '
    $1==w { print $2; found=1; exit }
    END { if (!found) print 0 }
  ' "$state_file"
)"

upsert_state() {
  local new_last="$1"
  local current_task="$2"
  local current_seq="$3"
  local status="$4"
  awk -F'\t' -v OFS='\t' -v w="$worker" -v ls="$new_last" -v ct="$current_task" -v cs="$current_seq" -v st="$status" -v ts="$ts_now" '
    BEGIN { updated=0 }
    $1==w {
      print w, ls, ct, cs, st, ts
      updated=1
      next
    }
    { print $0 }
    END {
      if (!updated) print w, ls, ct, cs, st, ts
    }
  ' "$state_file" > "${state_file}.tmp"
  mv "${state_file}.tmp" "$state_file"
}

if [[ "$mode" == "preflight" ]]; then
  if (( seq <= last_seq )); then
    printf '%s|%s|stale_seq_rejected|%s|seq=%s|last=%s\n' \
      "$ts_now" "$worker" "$task_id" "$seq" "$last_seq" >> queue/inbox/kashira.queue
    upsert_state "$last_seq" "$task_id" "$seq" "rejected_stale"
    echo "stale_rejected|worker=${worker}|task=${task_id}|seq=${seq}|last=${last_seq}"
    exit 3
  fi
  upsert_state "$last_seq" "$task_id" "$seq" "accepted"
  echo "preflight_ok|worker=${worker}|task=${task_id}|seq=${seq}|last=${last_seq}"
  exit 0
fi

prev_task="$(printf '%s' "$state_row" | awk -F'\t' '{print $3}')"
prev_seq="$(printf '%s' "$state_row" | awk -F'\t' '{print $4}')"
prev_status="$(printf '%s' "$state_row" | awk -F'\t' '{print $5}')"
if [[ -z "$prev_status" ]]; then
  prev_status="none"
fi

if [[ "$prev_status" != "accepted" || "$prev_task" != "$task_id" || "$prev_seq" != "$seq" ]]; then
  if (( allow_implicit_preflight == 1 )) && (( seq > last_seq )); then
    printf '%s|%s|implicit_preflight_recovered|%s|seq=%s|last=%s|prev_state=%s|prev_task=%s|prev_seq=%s\n' \
      "$ts_now" "$worker" "$task_id" "$seq" "$last_seq" "$prev_status" "$prev_task" "$prev_seq" >> queue/inbox/kashira.queue
    upsert_state "$seq" "-" "-" "completed"
    echo "complete_ok_recovered|worker=${worker}|task=${task_id}|seq=${seq}|last=${seq}|prev_state=${prev_status}"
    exit 0
  fi
  printf '%s|%s|complete_rejected|%s|seq=%s|state=%s|prev_task=%s|prev_seq=%s\n' \
    "$ts_now" "$worker" "$task_id" "$seq" "$prev_status" "$prev_task" "$prev_seq" >> queue/inbox/kashira.queue
  upsert_state "$last_seq" "$task_id" "$seq" "rejected_missing_preflight"
  echo "complete_rejected|worker=${worker}|task=${task_id}|seq=${seq}|reason=missing_or_mismatch_preflight"
  exit 4
fi

new_last="$last_seq"
if (( seq > last_seq )); then
  new_last="$seq"
fi
upsert_state "$new_last" "-" "-" "completed"
echo "complete_ok|worker=${worker}|task=${task_id}|seq=${seq}|last=${new_last}"
