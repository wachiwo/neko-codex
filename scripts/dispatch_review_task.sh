#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage:
  scripts/dispatch_review_task.sh \
    --task-id cmd_100 \
    --parent-cmd cmd_100 \
    --workers worker1,worker2,worker3,worker4 \
    [--description "Common description"] \
    [--description-map "worker1:desc1;worker2:desc2"] \
    [--description-file scripts/descriptions/example_cmd.txt] \
    [--review-ext md|sh|html|css|yaml] \
    [--review-lang markdown|shell|html_css|yaml] \
    [--hints "h1,h2"] \
    [--effort low|medium|high] \
    [--followup-attempts 3] [--followup-interval 20] [--no-followup]

Behavior:
  - Enforces persona preflight for kashira
  - Always enables --review-criteria
  - Forwards to scripts/dispatch_and_followup.sh
USAGE
}

for a in "$@"; do
  if [[ "$a" == "-h" || "$a" == "--help" ]]; then
    usage
    exit 0
  fi
done

if ! scripts/detect_persona.sh --expect kashira >/dev/null; then
  echo "persona preflight failed: this command must be run from kashira context" >&2
  exit 3
fi

args=()
review_ext=""
review_lang=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --review-ext) review_ext="${2:-}"; args+=("$1" "$2"); shift 2 ;;
    --review-lang) review_lang="${2:-}"; args+=("$1" "$2"); shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *)
      args+=("$1")
      shift
      ;;
  esac
done

if [[ -n "$review_ext" && -n "$review_lang" ]]; then
  echo "Use either --review-ext or --review-lang (not both)" >&2
  exit 2
fi

scripts/dispatch_and_followup.sh --review-criteria "${args[@]}"
