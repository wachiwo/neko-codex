#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage:
  scripts/detect_persona.sh [--expect oyabun|kashira|worker1|worker2|worker3|worker4] [--format text|kv]

Behavior:
  - Detect current role from tmux session/window/pane
  - Prints role + instruction path
  - Exits non-zero when --expect is given and role mismatches
USAGE
}

expect=""
fmt="text"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --expect) expect="${2:-}"; shift 2 ;;
    --format) fmt="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if ! command -v tmux >/dev/null 2>&1; then
  echo "tmux not found" >&2
  exit 1
fi

tmux_target="${TMUX_PANE:-}"
if [[ -n "$tmux_target" ]]; then
  session="$(tmux display-message -p -t "$tmux_target" '#S' 2>/dev/null || true)"
  window="$(tmux display-message -p -t "$tmux_target" '#W' 2>/dev/null || true)"
  pane_idx="$(tmux display-message -p -t "$tmux_target" '#P' 2>/dev/null || true)"
else
  session="$(tmux display-message -p '#S' 2>/dev/null || true)"
  window="$(tmux display-message -p '#W' 2>/dev/null || true)"
  pane_idx="$(tmux display-message -p '#P' 2>/dev/null || true)"
fi

role="unknown"
instruction=""

case "$session:$window:$pane_idx" in
  codex-oyabun:main:*|oyabun:*:*)
    role="oyabun"
    instruction="instructions/oyabun.md"
    ;;
  nekocodex:kashira:*|nekocodex:0:*|multiagent:0:0)
    role="kashira"
    instruction="instructions/kashira.md"
    ;;
  nekocodex:w1:*|nekocodex:1:*|multiagent:0:1)
    role="worker1"
    instruction="instructions/1gou-neko.md"
    ;;
  nekocodex:w2:*|nekocodex:2:*|multiagent:0:2)
    role="worker2"
    instruction="instructions/2gou-inu.md"
    ;;
  nekocodex:w3:*|nekocodex:3:*|multiagent:0:3)
    role="worker3"
    instruction="instructions/3gou-neko.md"
    ;;
  nekocodex:w4:*|nekocodex:4:*|multiagent:0:4)
    role="worker4"
    instruction="instructions/4gou-neko.md"
    ;;
esac

if [[ "$fmt" == "kv" ]]; then
  echo "session=${session}"
  echo "window=${window}"
  echo "pane=${pane_idx}"
  echo "role=${role}"
  echo "instruction=${instruction}"
else
  echo "persona_detected|session=${session}|window=${window}|pane=${pane_idx}|role=${role}|instruction=${instruction}"
fi

if [[ -n "$expect" && "$role" != "$expect" ]]; then
  echo "persona_mismatch|expected=${expect}|actual=${role}" >&2
  exit 3
fi
