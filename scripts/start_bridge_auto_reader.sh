#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"

pid_file="${repo_root}/status/bridge_auto_reader.pid"
supervisor_pid_file="${repo_root}/status/bridge_auto_reader_supervisor.pid"
session_file="${repo_root}/status/bridge_auto_reader_supervisor.session"
log_file="${repo_root}/logs/bridge_auto_reader.log"
supervisor_log_file="${repo_root}/logs/bridge_auto_reader_supervisor.log"
bridge_root="${BRIDGE_ROOT:-/mnt/c/tools/bridge}"
interval="${BRIDGE_READER_INTERVAL:-15}"
check_interval="${BRIDGE_READER_CHECK_INTERVAL:-10}"
non_rally_target="${BRIDGE_NON_RALLY_TARGET:-codex-oyabun:0.0}"
auto_rally_target="${AUTO_RALLY_TARGET:-codex-oyabun:0.0}"
min_worker_reports="${BRIDGE_MIN_WORKER_REPORTS:-4}"
tmux_session="${BRIDGE_READER_TMUX_SESSION:-bridgewatch}"
tmux_window="${BRIDGE_READER_TMUX_WINDOW:-reader}"

mkdir -p "${repo_root}/status" "${repo_root}/logs"

tmux_usable=0
if command -v tmux >/dev/null 2>&1; then
  tmux start-server >/dev/null 2>&1 || true
  tmux_usable=1
fi

is_supervisor_running=0
if [[ "$tmux_usable" -eq 1 ]]; then
  if tmux has-session -t "$tmux_session" 2>/dev/null; then
    pane_cmd="$(tmux list-panes -t "${tmux_session}:${tmux_window}" -F '#{pane_current_command}' 2>/dev/null | head -n 1 || true)"
    if [[ "$pane_cmd" == "bash" ]]; then
      is_supervisor_running=1
    fi
  fi
fi

if [[ "$is_supervisor_running" -eq 0 && -f "$supervisor_pid_file" ]]; then
  supervisor_pid="$(cat "$supervisor_pid_file" 2>/dev/null || true)"
  if [[ -n "${supervisor_pid:-}" ]] && ps -p "$supervisor_pid" -o args= 2>/dev/null | grep -q "bridge_auto_reader_supervisor.sh"; then
    is_supervisor_running=1
  fi
fi

if [[ "$is_supervisor_running" -eq 1 ]]; then
  watcher_pid="$(cat "$pid_file" 2>/dev/null || true)"
  echo "bridge_reader_supervisor_already_running|supervisor_pid=$(cat "$supervisor_pid_file" 2>/dev/null || echo unknown)|watcher_pid=${watcher_pid:-unknown}|root=$bridge_root|interval=$interval|check_interval=$check_interval|session=${tmux_session}:${tmux_window}"
  exit 0
fi

if [[ "$tmux_usable" -eq 1 ]]; then
  tmux kill-session -t "$tmux_session" 2>/dev/null || true
  tmux new-session -d -s "$tmux_session" -n "$tmux_window" \
    "cd '${repo_root}' && BRIDGE_ROOT='${bridge_root}' BRIDGE_READER_INTERVAL='${interval}' BRIDGE_READER_CHECK_INTERVAL='${check_interval}' BRIDGE_NON_RALLY_TARGET='${non_rally_target}' AUTO_RALLY_TARGET='${auto_rally_target}' BRIDGE_MIN_WORKER_REPORTS='${min_worker_reports}' bash '${script_dir}/bridge_auto_reader_supervisor.sh' --check-interval '${check_interval}' >> '${supervisor_log_file}' 2>&1"
  tmux_pid="$(tmux list-panes -t "${tmux_session}:${tmux_window}" -F '#{pane_pid}' 2>/dev/null | head -n 1 || true)"
  [[ -n "${tmux_pid:-}" ]] && echo "$tmux_pid" > "$supervisor_pid_file"
  echo "${tmux_session}:${tmux_window}" > "$session_file"
  echo "bridge_reader_supervisor_started|pid=${tmux_pid:-unknown}|root=$bridge_root|interval=$interval|check_interval=$check_interval|min_worker_reports=$min_worker_reports|session=${tmux_session}:${tmux_window}|watch_log=$log_file|supervisor_log=$supervisor_log_file"
  exit 0
fi

nohup env BRIDGE_ROOT="$bridge_root" \
  BRIDGE_READER_INTERVAL="$interval" \
  BRIDGE_READER_CHECK_INTERVAL="$check_interval" \
  BRIDGE_NON_RALLY_TARGET="$non_rally_target" \
  AUTO_RALLY_TARGET="$auto_rally_target" \
  BRIDGE_MIN_WORKER_REPORTS="$min_worker_reports" \
  "${script_dir}/bridge_auto_reader_supervisor.sh" --check-interval "$check_interval" \
  >> "$supervisor_log_file" 2>&1 &

new_supervisor_pid=$!
echo "$new_supervisor_pid" > "$supervisor_pid_file"
echo "nohup-fallback" > "$session_file"
sleep 1
if ps -p "$new_supervisor_pid" -o args= 2>/dev/null | grep -q "bridge_auto_reader_supervisor.sh"; then
  echo "bridge_reader_supervisor_started|pid=$new_supervisor_pid|root=$bridge_root|interval=$interval|check_interval=$check_interval|min_worker_reports=$min_worker_reports|session=nohup-fallback|watch_log=$log_file|supervisor_log=$supervisor_log_file"
  exit 0
fi

ts="$(date '+%Y-%m-%dT%H:%M:%S%z')"
printf '%s|watchdog|bridge_reader_start_failed|mode=nohup-fallback\n' "$ts" >> "${repo_root}/queue/inbox/kashira.queue"
"${script_dir}/notify_agent.sh" \
  --to kashira \
  --from watchdog \
  --event bridge_reader_start_failed \
  --task bridge_watcher \
  --message "Bridge watcherが起動直後に停止。Codex側ヘルプ対応が必要。" \
  --inbox-only >/dev/null 2>&1 || true
echo "bridge_reader_supervisor_failed|pid=$new_supervisor_pid|root=$bridge_root|interval=$interval|check_interval=$check_interval|min_worker_reports=$min_worker_reports|session=nohup-fallback"
exit 1
