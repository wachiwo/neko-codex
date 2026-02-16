#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage:
  scripts/system_health_check.sh [--workers worker1,worker2,worker3,worker4]

Behavior:
  - One-shot integrated health check (no polling loop).
  - Evaluates stale tasks by effort timeout (10/30/60).
  - Evaluates recovery/escalation state, seq-guard violations, queue lag.
  - Writes:
      status/system_health.yaml
      status/system_health.md
USAGE
}

workers_csv="worker1,worker2,worker3,worker4"
bridge_root="${BRIDGE_ROOT:-/mnt/c/tools/neko-codex/bridge}"
bridge_reader_pid_file="status/bridge_auto_reader.pid"
bridge_supervisor_pid_file="status/bridge_auto_reader_supervisor.pid"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workers) workers_csv="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

yaml_value() {
  local file="$1"
  local key="$2"
  awk -F': ' -v k="$key" '
    $1 ~ "^[[:space:]]*" k "$" {
      v=$2
      sub(/^[[:space:]]+/, "", v)
      gsub(/^"/, "", v)
      gsub(/"$/, "", v)
      print v
      exit
    }
  ' "$file" 2>/dev/null || true
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

report_exists_for_task() {
  local worker="$1"
  local task_id="$2"
  [[ -n "$task_id" ]] || return 1
  [[ -f "queue/reports/${worker}_${task_id}_report.yaml" ]] && return 0
  compgen -G "queue/reports/${worker}_${task_id}_*_report.yaml" >/dev/null
}

mkdir -p status queue/inbox
now="$(date '+%Y-%m-%dT%H:%M:%S%z')"
now_epoch="$(date +%s)"

tmux_ok="unknown"
if tmux list-panes -a >/dev/null 2>&1; then
  tmux_ok="ok"
else
  tmux_ok="degraded"
fi

stale_count=0
stale_items=()
pending_count=0
pending_items=()

IFS=',' read -r -a workers <<< "$workers_csv"
for w in "${workers[@]}"; do
  task_file="queue/tasks/${w}.yaml"
  [[ -f "$task_file" ]] || continue

  task_id="$(yaml_value "$task_file" task_id)"
  task_status="$(yaml_value "$task_file" status)"
  task_ts="$(yaml_value "$task_file" timestamp)"
  effort="$(yaml_value "$task_file" estimated_effort)"
  [[ -n "$task_id" && -n "$task_ts" ]] || continue

  if [[ "$task_status" != "assigned" && "$task_status" != "in_progress" ]]; then
    continue
  fi

  if report_exists_for_task "$w" "$task_id"; then
    continue
  fi

  pending_count=$((pending_count + 1))
  pending_items+=("${w}:${task_id}")

  task_epoch="$(date -d "$task_ts" +%s 2>/dev/null || true)"
  [[ -n "$task_epoch" ]] || continue
  age_min=$(( (now_epoch - task_epoch) / 60 ))
  timeout_min="$(task_timeout_minutes "$effort")"
  if (( age_min >= timeout_min )); then
    stale_count=$((stale_count + 1))
    stale_items+=("${w}:${task_id}:${age_min}m>=${timeout_min}m")
  fi
done

seq_guard_rejects=0
if [[ -f queue/inbox/kashira.queue ]]; then
  seq_guard_rejects="$(rg -n 'stale_seq_rejected|report_rejected|complete_rejected' queue/inbox/kashira.queue || true)"
  seq_guard_rejects="$(printf '%s\n' "$seq_guard_rejects" | sed '/^$/d' | wc -l)"
fi

escalation_count=0
if [[ -f status/recovery_state.tsv ]]; then
  escalation_count="$(awk -F'\t' '
    BEGIN {
      while ((getline < "queue/tasks/worker1.yaml") > 0) {
        if ($1 ~ /task_id:/) w1_task=$2
        if ($1 ~ /status:/) w1_status=$2
      }
      close("queue/tasks/worker1.yaml")
      while ((getline < "queue/tasks/worker2.yaml") > 0) {
        if ($1 ~ /task_id:/) w2_task=$2
        if ($1 ~ /status:/) w2_status=$2
      }
      close("queue/tasks/worker2.yaml")
      while ((getline < "queue/tasks/worker3.yaml") > 0) {
        if ($1 ~ /task_id:/) w3_task=$2
        if ($1 ~ /status:/) w3_status=$2
      }
      close("queue/tasks/worker3.yaml")
      while ((getline < "queue/tasks/worker4.yaml") > 0) {
        if ($1 ~ /task_id:/) w4_task=$2
        if ($1 ~ /status:/) w4_status=$2
      }
      close("queue/tasks/worker4.yaml")
    }
    {
      worker=$1; task=$2; stage=$3+0
      active=0
      if (worker=="worker1" && task==w1_task && (w1_status=="assigned" || w1_status=="in_progress")) active=1
      if (worker=="worker2" && task==w2_task && (w2_status=="assigned" || w2_status=="in_progress")) active=1
      if (worker=="worker3" && task==w3_task && (w3_status=="assigned" || w3_status=="in_progress")) active=1
      if (worker=="worker4" && task==w4_task && (w4_status=="assigned" || w4_status=="in_progress")) active=1
      if (stage>=3 && active==1) c++
    }
    END{print c+0}
  ' status/recovery_state.tsv)"
fi

bridge_pending=0
if [[ -f "${bridge_root}/index.md" ]]; then
  bridge_pending="$(rg -n '\|\s*bridge_[0-9]+\s*\|\s*codex\s*\|\s*todo\s*\|' "${bridge_root}/index.md" || true)"
  bridge_pending="$(printf '%s\n' "$bridge_pending" | sed '/^$/d' | wc -l)"
fi

bridge_reader_running="no"
if [[ -f "$bridge_reader_pid_file" ]]; then
  bridge_reader_pid="$(cat "$bridge_reader_pid_file" 2>/dev/null || true)"
  if [[ -n "${bridge_reader_pid:-}" ]] && ps -p "$bridge_reader_pid" -o args= 2>/dev/null | rg -q "bridge_auto_reader.sh --watch"; then
    bridge_reader_running="yes"
  fi
fi

bridge_supervisor_running="no"
if [[ -f "$bridge_supervisor_pid_file" ]]; then
  bridge_supervisor_pid="$(cat "$bridge_supervisor_pid_file" 2>/dev/null || true)"
  if [[ -n "${bridge_supervisor_pid:-}" ]] && ps -p "$bridge_supervisor_pid" -o args= 2>/dev/null | rg -q "bridge_auto_reader_supervisor.sh"; then
    bridge_supervisor_running="yes"
  fi
fi
if [[ "$bridge_supervisor_running" != "yes" ]] && command -v tmux >/dev/null 2>&1; then
  if tmux has-session -t bridgewatch 2>/dev/null; then
    pane_cmd="$(tmux list-panes -t bridgewatch:reader -F '#{pane_current_command}' 2>/dev/null | head -n 1 || true)"
    if [[ "$pane_cmd" == "bash" ]]; then
      bridge_supervisor_running="yes"
    fi
  fi
fi

health="ok"
if (( stale_count > 0 || escalation_count > 0 )); then
  health="critical"
elif [[ "$tmux_ok" != "ok" || "$seq_guard_rejects" -gt 0 || "$bridge_pending" -gt 0 || "$bridge_reader_running" != "yes" || "$bridge_supervisor_running" != "yes" ]]; then
  health="warn"
fi

{
  echo "timestamp: \"$now\""
  echo "health: \"$health\""
  echo "checks:"
  echo "  tmux: \"$tmux_ok\""
  echo "  pending_tasks: \"$pending_count\""
  echo "  stale_tasks: \"$stale_count\""
  echo "  seq_guard_rejects_total: \"$seq_guard_rejects\""
  echo "  recovery_escalations: \"$escalation_count\""
  echo "  bridge_todo: \"$bridge_pending\""
  echo "  bridge_reader_running: \"$bridge_reader_running\""
  echo "  bridge_supervisor_running: \"$bridge_supervisor_running\""
  echo "details:"
  echo "  pending: \"$(IFS=', '; echo "${pending_items[*]:-}")\""
  echo "  stale: \"$(IFS=', '; echo "${stale_items[*]:-}")\""
} > status/system_health.yaml

{
  echo "# System Health"
  echo "updated: $now"
  echo
  echo "- overall: $health"
  echo "- tmux: $tmux_ok"
  echo "- pending_tasks: $pending_count"
  echo "- stale_tasks: $stale_count"
  echo "- seq_guard_rejects_total: $seq_guard_rejects"
  echo "- recovery_escalations: $escalation_count"
  echo "- bridge_todo: $bridge_pending"
  echo "- bridge_reader_running: $bridge_reader_running"
  echo "- bridge_supervisor_running: $bridge_supervisor_running"
  echo
  if (( pending_count > 0 )); then
    echo "## Pending"
    for it in "${pending_items[@]}"; do echo "- $it"; done
    echo
  fi
  if (( stale_count > 0 )); then
    echo "## Stale"
    for it in "${stale_items[@]}"; do echo "- $it"; done
    echo
  fi
} > status/system_health.md

echo "health_check_done|health=${health}|stale=${stale_count}|pending=${pending_count}|escalations=${escalation_count}"
if [[ "$health" == "critical" ]]; then
  exit 1
fi
