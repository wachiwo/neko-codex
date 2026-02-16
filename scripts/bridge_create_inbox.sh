#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  scripts/bridge_create_inbox.sh \
    --from codex --to claude \
    [--status todo] [--summary "short text"] \
    [--due-by 2026-02-12T18:00+09:00] [--body-file path] \
    [--bridge-root /mnt/c/tools/bridge] [--lock-timeout 10]

Description:
  - Atomically (single lock section):
    1) allocate next bridge_XXX id
    2) create inbox/bridge_XXX.md
    3) append index.md row
  - Prints created task_id and file path
USAGE
}

bridge_root="${BRIDGE_ROOT:-/mnt/c/tools/bridge}"
from=""
to=""
status="todo"
summary=""
due_by=""
body_file=""
lock_timeout="10"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bridge-root) bridge_root="${2:-}"; shift 2 ;;
    --from) from="${2:-}"; shift 2 ;;
    --to) to="${2:-}"; shift 2 ;;
    --status) status="${2:-}"; shift 2 ;;
    --summary) summary="${2:-}"; shift 2 ;;
    --due-by) due_by="${2:-}"; shift 2 ;;
    --body-file) body_file="${2:-}"; shift 2 ;;
    --lock-timeout) lock_timeout="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$from" || -z "$to" ]]; then
  echo "--from and --to are required" >&2
  usage >&2
  exit 2
fi
if [[ ! "$status" =~ ^(todo|in_progress|done|blocked)$ ]]; then
  echo "Invalid --status: $status" >&2
  exit 1
fi
if [[ -n "$body_file" && ! -f "$body_file" ]]; then
  echo "body file not found: $body_file" >&2
  exit 1
fi
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
task_id="$(printf 'bridge_%03d' "$next_idx")"

inbox_file="${inbox_dir}/${task_id}.md"
if [[ -f "$inbox_file" || -f "${outbox_dir}/${task_id}.md" ]]; then
  echo "collision detected for ${task_id}; retry" >&2
  exit 1
fi

tmp_file="$(mktemp "${inbox_dir}/.${task_id}.XXXXXX")"
{
  echo "# task_id: ${task_id}"
  echo "- from: ${from}"
  echo "- to: ${to}"
  echo "- status: ${status}"
  [[ -n "$due_by" ]] && echo "- due_by: ${due_by}"
  [[ -n "$summary" ]] && echo "- context_pack.task_summary: ${summary}"
  echo
  if [[ -n "$body_file" ]]; then
    cat "$body_file"
  else
    cat <<'BODY'
## 目的
- (記入)

## 前提
- (記入)

## 制約
- (記入)

## 求める出力
- (記入)

## 関連ファイル
- (記入)
BODY
  fi
} >"$tmp_file"
mv "$tmp_file" "$inbox_file"

updated_at="$(date '+%Y-%m-%dT%H:%M')"
printf '| %s | %s | %s | %s | inbox/%s.md |\n' "$task_id" "$from" "$status" "$updated_at" "$task_id" >> "$index_file"

echo "bridge_inbox_created|task_id=${task_id}|inbox=${inbox_file}|index=${index_file}"

