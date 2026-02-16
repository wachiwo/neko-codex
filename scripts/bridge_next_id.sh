#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  scripts/bridge_next_id.sh [--bridge-root /mnt/c/tools/bridge] [--lock-timeout 10]

Description:
  - Acquires bridge/index.lock with flock
  - Reads max bridge_XXX from index/inbox/outbox
  - Prints next id (e.g., bridge_060)
USAGE
}

bridge_root="${BRIDGE_ROOT:-/mnt/c/tools/bridge}"
lock_timeout="10"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bridge-root) bridge_root="${2:-}"; shift 2 ;;
    --lock-timeout) lock_timeout="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if ! command -v flock >/dev/null 2>&1; then
  echo "flock not found; install util-linux" >&2
  exit 1
fi

if [[ ! "$lock_timeout" =~ ^[0-9]+$ ]]; then
  echo "Invalid --lock-timeout: $lock_timeout" >&2
  exit 1
fi

index_file="${bridge_root}/index.md"
inbox_dir="${bridge_root}/inbox"
outbox_dir="${bridge_root}/outbox"
lock_file="${bridge_root}/index.lock"

mkdir -p "$bridge_root" "$inbox_dir" "$outbox_dir"
touch "$lock_file"
[[ -f "$index_file" ]] || : > "$index_file"

exec 9>"$lock_file"
if ! flock -w "$lock_timeout" 9; then
  echo "Failed to acquire lock: $lock_file (timeout=${lock_timeout}s)" >&2
  exit 1
fi

max_idx="$(
  {
    rg -o 'bridge_[0-9]+' "$index_file" 2>/dev/null || true
    rg -o 'bridge_[0-9]+' "$inbox_dir" "$outbox_dir" 2>/dev/null || true
  } | sed -E 's/^bridge_0*//' | sed '/^$/d' | sort -n | tail -n 1
)"
max_idx="${max_idx:-0}"

next_idx=$((max_idx + 1))
printf 'bridge_%03d\n' "$next_idx"

