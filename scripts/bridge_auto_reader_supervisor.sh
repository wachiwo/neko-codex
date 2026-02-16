#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage:
  scripts/bridge_auto_reader_supervisor.sh [--check-interval 10]

Behavior:
  - Keeps scripts/bridge_auto_reader.sh --watch always running
  - Restarts watcher automatically if it stops
  - Writes watcher pid to status/bridge_auto_reader.pid
  - Writes supervisor pid to status/bridge_auto_reader_supervisor.pid
USAGE
}

check_interval=10
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check-interval) check_interval="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if ! [[ "$check_interval" =~ ^[0-9]+$ ]] || [[ "$check_interval" -lt 1 ]]; then
  echo "Invalid --check-interval: $check_interval" >&2
  exit 2
fi

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"

bridge_root="${BRIDGE_ROOT:-/mnt/c/tools/bridge}"
watch_interval="${BRIDGE_READER_INTERVAL:-15}"
non_rally_target="${BRIDGE_NON_RALLY_TARGET:-codex-oyabun:0.0}"
auto_rally_target="${AUTO_RALLY_TARGET:-codex-oyabun:0.0}"
min_worker_reports="${BRIDGE_MIN_WORKER_REPORTS:-4}"

watcher_pid_file="${repo_root}/status/bridge_auto_reader.pid"
supervisor_pid_file="${repo_root}/status/bridge_auto_reader_supervisor.pid"
watcher_log_file="${repo_root}/logs/bridge_auto_reader.log"
supervisor_log_file="${repo_root}/logs/bridge_auto_reader_supervisor.log"
heartbeat_file="${repo_root}/status/bridge_auto_reader_supervisor.heartbeat"

mkdir -p "${repo_root}/status" "${repo_root}/logs"
echo "$$" > "$supervisor_pid_file"

cleanup() {
  if [[ -f "$supervisor_pid_file" ]] && [[ "$(cat "$supervisor_pid_file" 2>/dev/null || true)" == "$$" ]]; then
    rm -f "$supervisor_pid_file"
  fi
}
trap cleanup EXIT INT TERM

watcher_running() {
  local pid
  if [[ ! -f "$watcher_pid_file" ]]; then
    return 1
  fi
  pid="$(cat "$watcher_pid_file" 2>/dev/null || true)"
  [[ -n "$pid" ]] || return 1
  ps -p "$pid" -o args= 2>/dev/null | grep -q "bridge_auto_reader.sh --watch"
}

start_watcher() {
  nohup env BRIDGE_ROOT="$bridge_root" \
    BRIDGE_READER_INTERVAL="$watch_interval" \
    BRIDGE_NON_RALLY_TARGET="$non_rally_target" \
    AUTO_RALLY_TARGET="$auto_rally_target" \
    BRIDGE_MIN_WORKER_REPORTS="$min_worker_reports" \
    "${script_dir}/bridge_auto_reader.sh" --watch --interval "$watch_interval" \
    >> "$watcher_log_file" 2>&1 &
  local new_pid=$!
  echo "$new_pid" > "$watcher_pid_file"
  printf '%s watcher_started|pid=%s|root=%s|interval=%s\n' \
    "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$new_pid" "$bridge_root" "$watch_interval" >> "$supervisor_log_file"
}

printf '%s supervisor_started|pid=%s|root=%s|watch_interval=%s|check_interval=%s\n' \
  "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$$" "$bridge_root" "$watch_interval" "$check_interval" >> "$supervisor_log_file"

while true; do
  if ! watcher_running; then
    start_watcher
  fi
  printf '%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" > "$heartbeat_file"
  sleep "$check_interval"
done
