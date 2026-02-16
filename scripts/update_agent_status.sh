#!/usr/bin/env bash
set -euo pipefail

yaml_escape() {
  local s="${1:-}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

yaml_value() {
  local file="$1"
  local key="$2"
  awk -F': ' -v k="$key" '
    $1 ~ "^[[:space:]]*" k "$" {
      sub(/^[[:space:]]+/, "", $2)
      gsub(/^"/, "", $2)
      gsub(/"$/, "", $2)
      print $2
      exit
    }
  ' "$file" 2>/dev/null || true
}

latest_line() {
  local file="$1"
  if [[ -f "$file" ]]; then
    tail -n 1 "$file"
  fi
}

report_exists_for_task() {
  local worker="$1"
  local task_id="$2"
  [[ -n "$task_id" ]] || return 1
  [[ -f "queue/reports/${worker}_${task_id}_report.yaml" ]] && return 0
  compgen -G "queue/reports/${worker}_${task_id}_*_report.yaml" >/dev/null
}

task_timeout_minutes() {
  local effort="${1,,}"
  case "$effort" in
    low|small) echo 10 ;;
    medium) echo 30 ;;
    high|large) echo 60 ;;
    *) echo 30 ;;
  esac
}

latest_report_file() {
  local worker="$1"
  ls -1t queue/reports/${worker}_*_report.yaml 2>/dev/null | head -n 1 || true
}

handshake_state_for_task() {
  local worker="$1"
  local task="$2"
  local f="status/worker_handshake.tsv"
  [[ -f "$f" && -n "$task" ]] || return 0
  awk -F'\t' -v w="$worker" -v t="$task" '
    $1==t && $2==w { st=$8 }
    END { if (st!="") print st }
  ' "$f" 2>/dev/null || true
}

render_alerts() {
  local alerts_file="status/alerts.md"
  local src="queue/inbox/kashira.queue"
  {
    echo "# Alerts"
    echo "updated: $now"
    echo
  } > "$alerts_file"
  if [[ ! -f "$src" ]]; then
    echo "- no queue/inbox/kashira.queue" >> "$alerts_file"
    return 0
  fi
  hits="$(tail -n 400 "$src" | rg 'notify_failed|dispatch_failed|report_rejected_seq_guard|handshake_timeout|reassign_ack_timeout|retry_exhausted|delegation_guard_failed' || true)"
  if [[ -z "$hits" ]]; then
    echo "- no critical alerts in recent window" >> "$alerts_file"
    return 0
  fi
  echo "| timestamp | source | event | task |" >> "$alerts_file"
  echo "|---|---|---|---|" >> "$alerts_file"
  printf '%s\n' "$hits" | tail -n 40 | awk -F'|' '
    {
      ts=$1; src=$2; ev=$3; task=$4;
      if (task=="") task="-";
      print "| " ts " | " src " | " ev " | " task " |"
    }
  ' >> "$alerts_file"
}

mkdir -p status
now="$(date '+%Y-%m-%dT%H:%M:%S%z')"

oyabun_event="$(latest_line queue/inbox/oyabun.queue)"
kashira_event="$(latest_line queue/inbox/kashira.queue)"

pending_workers=()
worker_yaml_blocks=()
worker_md_rows=()

for worker in worker1 worker2 worker3 worker4; do
  task_file="queue/tasks/${worker}.yaml"
  task_id="$(yaml_value "$task_file" task_id)"
  task_status="$(yaml_value "$task_file" status)"
  task_seq="$(yaml_value "$task_file" seq)"
  task_ts="$(yaml_value "$task_file" timestamp)"
  task_effort="$(yaml_value "$task_file" estimated_effort)"
  last_report="$(latest_report_file "$worker")"
  last_worker_event="$(latest_line "queue/inbox/${worker}.queue")"
  handshake_state="$(handshake_state_for_task "$worker" "$task_id")"

  state="idle"
  if [[ "$task_status" == "assigned" || "$task_status" == "in_progress" ]]; then
    if report_exists_for_task "$worker" "$task_id"; then
      state="done_waiting_next"
    else
      task_epoch="$(date -d "$task_ts" +%s 2>/dev/null || true)"
      timeout_min="$(task_timeout_minutes "$task_effort")"
      now_epoch="$(date +%s)"
      if [[ -n "$task_epoch" ]]; then
        age_min=$(( (now_epoch - task_epoch) / 60 ))
      else
        age_min=0
      fi
      if (( age_min >= timeout_min )); then
        state="stalled"
      else
        state="working"
      fi
      case "$handshake_state" in
        assigned|"")
          if (( age_min >= 3 )); then
            state="queued_no_ack"
          fi
          ;;
        acked) state="acked_waiting_start" ;;
        started) state="working" ;;
        reported) state="done_waiting_next" ;;
      esac
      pending_workers+=("$worker:$task_id")
    fi
  fi

  worker_yaml_blocks+=(
"  ${worker}:
    state: \"$(yaml_escape "$state")\"
    task_id: \"$(yaml_escape "$task_id")\"
    task_status: \"$(yaml_escape "$task_status")\"
    seq: \"$(yaml_escape "$task_seq")\"
    task_timestamp: \"$(yaml_escape "$task_ts")\"
    latest_report: \"$(yaml_escape "$last_report")\"
    latest_inbox_event: \"$(yaml_escape "$last_worker_event")\"
    handshake_state: \"$(yaml_escape "$handshake_state")\""
  )

  worker_md_rows+=("| ${worker} | ${state} | ${task_id:-"-"} | ${last_report:-"-"} |")
done

pending_count="${#pending_workers[@]}"
pending_csv=""
if (( pending_count > 0 )); then
  pending_csv="$(IFS=', '; echo "${pending_workers[*]}")"
fi

kashira_state="idle"
if (( pending_count > 0 )); then
  kashira_state="coordinating"
fi

oyabun_state="idle"
if [[ -s queue/oyabun_to_kashira.yaml ]]; then
  oyabun_state="active_queue_present"
fi

{
  echo "last_updated: \"$now\""
  echo "summary:"
  echo "  pending_worker_tasks: \"$pending_count\""
  echo "  pending_list: \"$(yaml_escape "$pending_csv")\""
  echo "agents:"
  echo "  oyabun:"
  echo "    state: \"$(yaml_escape "$oyabun_state")\""
  echo "    latest_inbox_event: \"$(yaml_escape "$oyabun_event")\""
  echo "  kashira:"
  echo "    state: \"$(yaml_escape "$kashira_state")\""
  echo "    latest_inbox_event: \"$(yaml_escape "$kashira_event")\""
  echo "workers:"
  printf '%s\n' "${worker_yaml_blocks[@]}"
} > status/agent_status.yaml

{
  echo "# Agent Status Snapshot"
  echo "updated: $now"
  echo
  echo "- oyabun: $oyabun_state"
  echo "- kashira: $kashira_state"
  echo "- pending_worker_tasks: $pending_count"
  if (( pending_count > 0 )); then
    echo "- pending: $pending_csv"
  fi
  echo
  echo "| worker | state | task_id | latest_report |"
  echo "|---|---|---|---|"
  printf '%s\n' "${worker_md_rows[@]}"
} > status/agent_status.md

render_alerts

echo "status_updated|file=status/agent_status.yaml|pending=${pending_count}"
