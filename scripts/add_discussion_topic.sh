#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage:
  scripts/add_discussion_topic.sh \
    --id D4 \
    --theme "テーマ" \
    --background "背景" \
    [--date YYYY-MM-DD] \
    [--file logs/oyabun_session.md]

Behavior:
  - Appends one row to "議論したいやつ一覧（次回ブレスト候補）" table.
USAGE
}

id=""
theme=""
background=""
date_val="$(date '+%Y-%m-%d')"
file="logs/oyabun_session.md"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --id) id="${2:-}"; shift 2 ;;
    --theme) theme="${2:-}"; shift 2 ;;
    --background) background="${2:-}"; shift 2 ;;
    --date) date_val="${2:-}"; shift 2 ;;
    --file) file="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$id" || -z "$theme" || -z "$background" ]]; then
  echo "--id, --theme, --background are required" >&2
  exit 2
fi

if [[ ! -f "$file" ]]; then
  echo "session log not found: $file" >&2
  exit 3
fi

row="| ${id} | ${theme} | ${background} | ${date_val} |"

tmp="$(mktemp)"
awk -v row="$row" '
  { print }
  /^\|---\|--------\|------\|--------\|$/ { in_table=1; next }
  in_table && /^$/ && !done { print row; done=1; in_table=0 }
  END {
    if (!done) print row
  }
' "$file" > "$tmp"
mv "$tmp" "$file"

echo "discussion_topic_added|file=${file}|id=${id}"
