#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage:
  scripts/assign_task.sh \
    --worker worker1 \
    --task-id cmd_010_w1 \
    --parent-cmd cmd_010 \
    --description 'Do X' \
    [--seq 2] [--mode normal] [--effort low] [--target-path <path>] \
    [--heads-up false] [--hints 'hint1,hint2'] [--status assigned]

Behavior:
  - Writes queue/tasks/<worker>.yaml.
  - If --seq is omitted, increments current seq automatically.
  - If --target-path is omitted, uses queue/reports/<worker>_<task_id>_report.yaml.
USAGE
}

worker=""
task_id=""
parent_cmd=""
seq=""
mode="normal"
effort="low"
description=""
target_path=""
heads_up="false"
hints_csv=""
status="assigned"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --worker) worker="${2:-}"; shift 2 ;;
    --task-id) task_id="${2:-}"; shift 2 ;;
    --parent-cmd) parent_cmd="${2:-}"; shift 2 ;;
    --seq) seq="${2:-}"; shift 2 ;;
    --mode) mode="${2:-}"; shift 2 ;;
    --effort) effort="${2:-}"; shift 2 ;;
    --description) description="${2:-}"; shift 2 ;;
    --target-path) target_path="${2:-}"; shift 2 ;;
    --heads-up) heads_up="${2:-}"; shift 2 ;;
    --hints) hints_csv="${2:-}"; shift 2 ;;
    --status) status="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$worker" || -z "$task_id" || -z "$parent_cmd" || -z "$description" ]]; then
  echo "--worker, --task-id, --parent-cmd, --description are required" >&2
  exit 2
fi

case "$worker" in
  worker1|worker2|worker3|worker4) ;;
  *)
    echo "Unsupported worker: $worker" >&2
    exit 2
    ;;
esac

task_file="queue/tasks/${worker}.yaml"
mkdir -p queue/tasks queue/reports

if [[ -z "$seq" ]]; then
  prev_seq="$(awk '/^[[:space:]]*seq:[[:space:]]*[0-9]+/ {print $2; exit}' "$task_file" 2>/dev/null || true)"
  if [[ -z "$prev_seq" ]]; then
    seq=1
  else
    seq=$((prev_seq + 1))
  fi
fi

if [[ -z "$target_path" ]]; then
  target_path="queue/reports/${worker}_${task_id}_report.yaml"
fi

if [[ -n "$hints_csv" ]]; then
  IFS=',' read -r -a hints_arr <<< "$hints_csv"
  hints_yaml="["
  for i in "${!hints_arr[@]}"; do
    h="${hints_arr[$i]}"
    if [[ $i -gt 0 ]]; then
      hints_yaml+=", "
    fi
    hints_yaml+="\"$h\""
  done
  hints_yaml+="]"
else
  hints_yaml="[]"
fi

ts="$(date '+%Y-%m-%dT%H:%M:%S%z')"
cat > "$task_file" <<EOF
task:
  task_id: ${task_id}
  parent_cmd: ${parent_cmd}
  seq: ${seq}
  mode: ${mode}
  estimated_effort: ${effort}
  description: "${description}"
  target_path: "${target_path}"
  heads_up: ${heads_up}
  hints: ${hints_yaml}
  status: ${status}
  timestamp: "${ts}"
EOF

echo "task_assigned|worker=${worker}|task_id=${task_id}|seq=${seq}|task_file=${task_file}"
scripts/update_agent_status.sh >/dev/null 2>&1 || true
