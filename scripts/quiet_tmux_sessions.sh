#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage:
  scripts/quiet_tmux_sessions.sh [--sessions nekocodex,codex-oyabun,nekogemini,gemini-oyabun]

Behavior:
  - Apply low-noise tmux UI options to existing sessions only.
  - Keep internal processing running while suppressing noisy status redraw.
USAGE
}

sessions_csv="nekocodex,codex-oyabun,nekogemini,gemini-oyabun"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sessions)
      sessions_csv="${2:-}"
      shift 2
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

if ! command -v tmux >/dev/null 2>&1; then
  echo "quiet_tmux_skipped|reason=tmux_not_found"
  exit 0
fi

applied=0
skipped=0
IFS=',' read -r -a sessions <<< "$sessions_csv"
for session in "${sessions[@]}"; do
  [[ -n "$session" ]] || continue
  if ! tmux has-session -t "$session" 2>/dev/null; then
    skipped=$((skipped + 1))
    continue
  fi
  tmux set-option -t "$session" status off
  tmux set-option -t "$session" automatic-rename off
  tmux set-option -t "$session" allow-rename off
  tmux set-option -t "$session" monitor-activity off
  tmux set-option -t "$session" visual-activity off
  applied=$((applied + 1))
done

echo "quiet_tmux_done|applied=${applied}|skipped=${skipped}|sessions=${sessions_csv}"
