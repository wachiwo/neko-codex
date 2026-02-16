#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage:
  scripts/bridge_done_guard.sh --task-id bridge_030 [--bridge-root /mnt/c/tools/bridge] [--min-workers 4] [--source-file /mnt/c/tools/bridge/inbox/bridge_030.md]

Behavior:
  - Validates outbox/<task_id>.md when status=done.
  - Requires explicit worker evidence:
    - worker_count: <N> (N >= min-workers)
    - worker report file paths in the body, and those files must exist.
USAGE
}

task_id=""
bridge_root="${BRIDGE_ROOT:-/mnt/c/tools/bridge}"
min_workers="${BRIDGE_MIN_WORKER_REPORTS:-4}"
source_file=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --task-id) task_id="${2:-}"; shift 2 ;;
    --bridge-root) bridge_root="${2:-}"; shift 2 ;;
    --min-workers) min_workers="${2:-}"; shift 2 ;;
    --source-file) source_file="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$task_id" ]]; then
  echo "--task-id is required" >&2
  exit 2
fi

if ! [[ "$min_workers" =~ ^[0-9]+$ ]]; then
  echo "--min-workers must be an integer: $min_workers" >&2
  exit 2
fi

outbox_file="${bridge_root}/outbox/${task_id}.md"
if [[ ! -f "$outbox_file" ]]; then
  echo "outbox file not found: $outbox_file" >&2
  exit 3
fi

status="$(
  awk -F': ' '/^[[:space:]]*-[[:space:]]*status:[[:space:]]*/{print $2; exit}' "$outbox_file" | tr -d '\r'
)"
if [[ -z "$status" ]]; then
  status="$(
    awk -F'=' '/^status=/{print $2; exit}' "$outbox_file" | tr -d '\r'
  )"
fi
if [[ "$status" != "done" ]]; then
  echo "status is not done (${status:-missing}); guard skipped"
  exit 0
fi

worker_count="$(awk '
  match($0, /worker_count[[:space:]]*:[[:space:]]*([0-9]+)/, m) { print m[1]; exit }
' "$outbox_file")"

if [[ -z "$worker_count" ]]; then
  echo "missing worker_count in done outbox: $outbox_file" >&2
  exit 4
fi

if (( worker_count < min_workers )); then
  echo "worker_count too small: ${worker_count} < ${min_workers}" >&2
  exit 5
fi

mapfile -t report_paths < <(
  grep -Eo '(/mnt/c/tools/neko-codex/)?queue/reports/worker[0-9A-Za-z_./-]*_report\.ya?ml' "$outbox_file" | awk '!seen[$0]++'
)

if (( ${#report_paths[@]} == 0 )); then
  echo "missing worker_report_paths in done outbox: $outbox_file" >&2
  exit 6
fi

existing=0
missing_list=""
for p in "${report_paths[@]}"; do
  if [[ "$p" != /* ]]; then
    p="/mnt/c/tools/neko-codex/${p}"
  fi
  if [[ -f "$p" ]]; then
    existing=$((existing + 1))
  else
    if [[ -z "$missing_list" ]]; then
      missing_list="$p"
    else
      missing_list="${missing_list}, $p"
    fi
  fi
done

if (( existing < min_workers )); then
  echo "existing worker reports too few: ${existing} < ${min_workers}; missing=${missing_list:-none}" >&2
  exit 7
fi

if [[ -n "$source_file" && -f "$source_file" ]]; then
  source_mtime="$(stat -c %Y "$source_file" 2>/dev/null || true)"
  if [[ -n "$source_mtime" ]]; then
    fresh=0
    for p in "${report_paths[@]}"; do
      if [[ "$p" != /* ]]; then
        p="/mnt/c/tools/neko-codex/${p}"
      fi
      [[ -f "$p" ]] || continue
      report_mtime="$(stat -c %Y "$p" 2>/dev/null || true)"
      if [[ -n "$report_mtime" ]] && (( report_mtime >= source_mtime )); then
        fresh=$((fresh + 1))
      fi
    done
    if (( fresh < min_workers )); then
      echo "fresh worker reports too few: ${fresh} < ${min_workers}; source=${source_file}" >&2
      exit 8
    fi
  fi
fi

echo "guard_pass|task_id=${task_id}|worker_count=${worker_count}|reports=${existing}|min=${min_workers}"
