#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage:
  scripts/dispatch_and_followup.sh \
    [--workers worker1,worker2,worker3,worker4] \
    --task-id cmd_011 \
    --parent-cmd cmd_011 \
    --description 'Common task description' \
    [--description-map 'worker1:desc1;worker2:desc2'] \
    [--description-file scripts/descriptions/cmd_011.txt] \
    [--hints 'h1,h2'] [--effort low] [--mode normal] \
    [--notify-message 'Check queue/tasks/workerN.yaml'] \
    [--followup-attempts 3] [--followup-interval 20] [--no-followup]
    [--require-handshake true|false] [--ack-timeout-sec 180] [--first-action-timeout-sec 300] [--compat-mode]
    [--auto-recover-handshake-timeout true|false]
    [--review-criteria --review-ext md|sh|html | --review-lang markdown|shell|html_css]

Behavior:
  1) Assign task YAML for each worker
  2) Notify workers (inbox + tmux send + Enter)
  3) Auto-followup missing reports (optional)

Tip:
  For standardized review dispatch, prefer scripts/dispatch_review_task.sh
USAGE
}

workers_csv="worker1,worker2,worker3,worker4"
task_id=""
parent_cmd=""
common_desc=""
desc_map=""
desc_file=""
hints_csv=""
effort="low"
mode="normal"
heads_up="false"
notify_message="Check queue/tasks/workerN.yaml"
followup_attempts=3
followup_interval=20
no_followup=0
require_handshake="true"
ack_timeout_sec=180
first_action_timeout_sec=300
compat_mode=0
auto_recover_handshake_timeout="true"
review_ext=""
review_lang=""
review_criteria=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workers) workers_csv="${2:-}"; shift 2 ;;
    --task-id) task_id="${2:-}"; shift 2 ;;
    --parent-cmd) parent_cmd="${2:-}"; shift 2 ;;
    --description) common_desc="${2:-}"; shift 2 ;;
    --description-map) desc_map="${2:-}"; shift 2 ;;
    --description-file) desc_file="${2:-}"; shift 2 ;;
    --hints) hints_csv="${2:-}"; shift 2 ;;
    --effort) effort="${2:-}"; shift 2 ;;
    --mode) mode="${2:-}"; shift 2 ;;
    --heads-up) heads_up="${2:-}"; shift 2 ;;
    --notify-message) notify_message="${2:-}"; shift 2 ;;
    --followup-attempts) followup_attempts="${2:-}"; shift 2 ;;
    --followup-interval) followup_interval="${2:-}"; shift 2 ;;
    --no-followup) no_followup=1; shift ;;
    --require-handshake) require_handshake="${2:-}"; shift 2 ;;
    --ack-timeout-sec) ack_timeout_sec="${2:-}"; shift 2 ;;
    --first-action-timeout-sec) first_action_timeout_sec="${2:-}"; shift 2 ;;
    --compat-mode) compat_mode=1; shift ;;
    --auto-recover-handshake-timeout) auto_recover_handshake_timeout="${2:-}"; shift 2 ;;
    --review-ext) review_ext="${2:-}"; shift 2 ;;
    --review-lang) review_lang="${2:-}"; shift 2 ;;
    --review-criteria) review_criteria=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$task_id" || -z "$parent_cmd" ]]; then
  echo "--task-id and --parent-cmd are required" >&2
  exit 2
fi

criteria_hints=""
if [[ $review_criteria -eq 1 ]]; then
  criteria_cmd=(scripts/review_criteria_hints.sh --format csv)
  if [[ -n "$review_lang" ]]; then
    criteria_cmd+=(--lang "$review_lang")
  elif [[ -n "$review_ext" ]]; then
    criteria_cmd+=(--ext "$review_ext")
  fi
  criteria_hints="$("${criteria_cmd[@]}" 2>/dev/null || true)"
fi

if [[ -n "$criteria_hints" ]]; then
  if [[ -n "$hints_csv" ]]; then
    hints_csv="${hints_csv},${criteria_hints}"
  else
    hints_csv="${criteria_hints}"
  fi
fi

if [[ -z "$common_desc" && -z "$desc_map" && -z "$desc_file" ]]; then
  echo "Either --description, --description-map, or --description-file is required" >&2
  exit 2
fi

declare -A desc_for_worker=()
if [[ -n "$desc_map" ]]; then
  IFS=';' read -r -a pairs <<< "$desc_map"
  for p in "${pairs[@]}"; do
    [[ -z "$p" ]] && continue
    key="${p%%:*}"
    val="${p#*:}"
    if [[ -n "$key" && -n "$val" && "$key" != "$val" ]]; then
      desc_for_worker["$key"]="$val"
    fi
  done
fi

if [[ -n "$desc_file" ]]; then
  if [[ ! -f "$desc_file" ]]; then
    echo "Description file not found: $desc_file" >&2
    exit 2
  fi

  while IFS= read -r line; do
    # Ignore blank lines and comments.
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    key="${line%%:*}"
    val="${line#*:}"
    # Trim leading/trailing spaces.
    key="${key#"${key%%[![:space:]]*}"}"
    key="${key%"${key##*[![:space:]]}"}"
    val="${val#"${val%%[![:space:]]*}"}"
    val="${val%"${val##*[![:space:]]}"}"
    if [[ -n "$key" && -n "$val" && "$key" != "$val" ]]; then
      desc_for_worker["$key"]="$val"
    fi
  done < "$desc_file"
fi

IFS=',' read -r -a workers <<< "$workers_csv"
notify_failed_workers=()
notify_mode_flags=()
if [[ $compat_mode -eq 0 ]]; then
  notify_mode_flags+=(--strict-tmux)
else
  notify_mode_flags+=(--allow-degraded)
fi

for w in "${workers[@]}"; do
  desc="${desc_for_worker[$w]:-$common_desc}"
  if [[ -z "$desc" ]]; then
    echo "Missing description for ${w}. Use --description or --description-map." >&2
    exit 2
  fi

  scripts/assign_task.sh \
    --worker "$w" \
    --task-id "$task_id" \
    --parent-cmd "$parent_cmd" \
    --description "$desc" \
    --mode "$mode" \
    --effort "$effort" \
    --heads-up "$heads_up" \
    --hints "$hints_csv"
done

if [[ $compat_mode -eq 1 ]]; then
  scripts/notify_workers.sh \
    --workers "$workers_csv" \
    --message "$notify_message" \
    --from kashira \
    --event task_assigned \
    --task "$task_id" \
    --inbox-only
fi

# Send explicit worker-specific wake messages (no placeholder paths).
for w in "${workers[@]}"; do
  if ! scripts/notify_agent.sh \
    --to "$w" \
    --from kashira \
    --event task_assigned \
    --task "$task_id" \
    --message "Check queue/tasks/${w}.yaml and execute ${task_id} now. Immediately send task_ack then first_action to kashira for ${task_id}." \
    "${notify_mode_flags[@]}"; then
    notify_failed_workers+=("$w")
  fi
done

if (( ${#notify_failed_workers[@]} > 0 )); then
  echo "dispatch_failed|task=${task_id}|reason=notify_failed|workers=$(IFS=,; echo "${notify_failed_workers[*]}")" >&2
  exit 1
fi

if [[ "$require_handshake" == "true" && $compat_mode -eq 0 ]]; then
  scripts/worker_handshake_watchdog.sh init \
    --task "$task_id" \
    --workers "$workers_csv" \
    --grace-sec 120 >/dev/null
  if ! scripts/worker_handshake_watchdog.sh await \
    --task "$task_id" \
    --workers "$workers_csv" \
    --ack-timeout-sec "$ack_timeout_sec" \
    --first-action-timeout-sec "$first_action_timeout_sec" \
    --grace-sec 120; then
    ts="$(date '+%Y-%m-%dT%H:%M:%S%z')"
    printf '%s|dispatch|handshake_timeout|task=%s|workers=%s\n' \
      "$ts" "$task_id" "$workers_csv" >> queue/inbox/kashira.queue
    if [[ "$auto_recover_handshake_timeout" == "true" ]]; then
      recover_out="$(scripts/stale_task_watchdog.sh --workers "$workers_csv" --default-timeout 0 --reassign-ack-timeout-sec "$ack_timeout_sec" 2>&1 || true)"
      printf '%s|dispatch|handshake_timeout_recovery|task=%s|detail=%s\n' \
        "$ts" "$task_id" "$(printf '%s' "$recover_out" | tr '\n' ';')" >> queue/inbox/kashira.queue
      echo "dispatch_degraded|task=${task_id}|reason=handshake_timeout|recovery=watchdog_triggered"
    else
      echo "dispatch_failed|task=${task_id}|reason=handshake_timeout" >&2
      exit 1
    fi
  fi
fi

if [[ $no_followup -eq 0 ]]; then
  scripts/auto_followup_reports.sh \
    --workers "$workers_csv" \
    --task "$task_id" \
    --message "${notify_message} (${task_id} pending)" \
    --attempts "$followup_attempts" \
    --interval "$followup_interval"
fi

echo "dispatch_done|task=${task_id}|workers=${workers_csv}|followup=$((1-no_followup))"
