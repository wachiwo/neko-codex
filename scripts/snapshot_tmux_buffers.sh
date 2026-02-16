#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage:
  scripts/snapshot_tmux_buffers.sh [--output-dir logs/tmux_snapshots] [--lines 4000]

Behavior:
  - Captures tmux scrollback buffers before restart/recovery.
  - Writes one file per critical pane + summary file.
USAGE
}

output_dir="logs/tmux_snapshots"
lines=4000

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir) output_dir="${2:-}"; shift 2 ;;
    --lines) lines="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if ! [[ "$lines" =~ ^[0-9]+$ ]] || [[ "$lines" -lt 200 ]]; then
  echo "--lines must be integer >= 200" >&2
  exit 2
fi

if ! command -v tmux >/dev/null 2>&1; then
  echo "tmux not found" >&2
  exit 1
fi

ts="$(date '+%Y%m%d_%H%M%S')"
run_dir="${output_dir}/${ts}"
mkdir -p "$run_dir"

panes=(
  "codex-oyabun:0.0"
  "nekocodex:0.0"
  "nekocodex:1.0"
  "nekocodex:2.0"
  "nekocodex:3.0"
  "nekocodex:4.0"
  "bridgewatch:0.0"
  "watchdog:0.0"
)

summary_file="${run_dir}/SUMMARY.md"
{
  echo "# tmux Snapshot"
  echo "timestamp: $(date '+%Y-%m-%dT%H:%M:%S%z')"
  echo
  echo "| pane | file | status |"
  echo "|---|---|---|"
} > "$summary_file"

captured=0
missing=0

for pane in "${panes[@]}"; do
  safe_name="${pane//[:.]/_}"
  out_file="${run_dir}/${safe_name}.log"
  if tmux has-session -t "${pane%%:*}" 2>/dev/null; then
    if tmux capture-pane -t "$pane" -p -S "-${lines}" > "$out_file" 2>/dev/null; then
      echo "| ${pane} | ${out_file} | captured |" >> "$summary_file"
      captured=$((captured + 1))
    else
      echo "| ${pane} | - | capture_failed |" >> "$summary_file"
      missing=$((missing + 1))
    fi
  else
    echo "| ${pane} | - | session_missing |" >> "$summary_file"
    missing=$((missing + 1))
  fi
done

echo "snapshot_done|dir=${run_dir}|captured=${captured}|missing=${missing}|summary=${summary_file}"
