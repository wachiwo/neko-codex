#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage:
  scripts/health_snapshot.sh

Behavior:
  - Collects one-shot health snapshot from status/queue files
  - Writes:
      status/health_snapshot.yaml
      status/health_snapshot.md
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
cd "$repo_root"

mkdir -p status
now="$(date '+%Y-%m-%dT%H:%M:%S%z')"

count_lines() {
  local f="$1"
  [[ -f "$f" ]] || { echo 0; return; }
  wc -l < "$f"
}

count_pending_approvals() {
  local f="queue/approval_required.yaml"
  [[ -f "$f" ]] || { echo 0; return; }
  awk '
    /^    status:[[:space:]]*pending/ {c++}
    END{print c+0}
  ' "$f"
}

bridge_guard_violations="$(count_lines status/bridge_guard_violations.tsv)"
pending_approvals="$(count_pending_approvals)"
bridge_todo="$(grep -E '^\|[[:space:]]*bridge_[0-9]+' bridge/index.md 2>/dev/null | grep -c '| todo |' || true)"

watcher_pid="$(cat status/bridge_auto_reader.pid 2>/dev/null || true)"
supervisor_pid="$(cat status/bridge_auto_reader_supervisor.pid 2>/dev/null || true)"
watcher_alive="no"
supervisor_alive="no"
if [[ -n "$watcher_pid" ]] && ps -p "$watcher_pid" >/dev/null 2>&1; then watcher_alive="yes"; fi
if [[ -n "$supervisor_pid" ]] && ps -p "$supervisor_pid" >/dev/null 2>&1; then supervisor_alive="yes"; fi

status_age_sec=-1
if [[ -f status/agent_status.yaml ]]; then
  now_epoch="$(date +%s)"
  mod_epoch="$(stat -c %Y status/agent_status.yaml 2>/dev/null || echo 0)"
  status_age_sec=$((now_epoch - mod_epoch))
fi

health="ok"
if [[ "$watcher_alive" != "yes" || "$supervisor_alive" != "yes" ]]; then
  health="warn"
fi
if (( pending_approvals > 0 || bridge_guard_violations > 0 )); then
  health="warn"
fi
if (( status_age_sec > 3600 )); then
  health="warn"
fi

{
  echo "timestamp: \"$now\""
  echo "health: \"$health\""
  echo "watcher_alive: \"$watcher_alive\""
  echo "supervisor_alive: \"$supervisor_alive\""
  echo "pending_approvals: \"$pending_approvals\""
  echo "bridge_guard_violations: \"$bridge_guard_violations\""
  echo "bridge_todo: \"$bridge_todo\""
  echo "agent_status_age_sec: \"$status_age_sec\""
} > status/health_snapshot.yaml

{
  echo "# Health Snapshot"
  echo "updated: $now"
  echo
  echo "- health: $health"
  echo "- watcher_alive: $watcher_alive"
  echo "- supervisor_alive: $supervisor_alive"
  echo "- pending_approvals: $pending_approvals"
  echo "- bridge_guard_violations: $bridge_guard_violations"
  echo "- bridge_todo: $bridge_todo"
  echo "- agent_status_age_sec: $status_age_sec"
} > status/health_snapshot.md

echo "health_snapshot_done|health=${health}|pending_approvals=${pending_approvals}|violations=${bridge_guard_violations}"
