#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage:
  scripts/validate_lifecycle.sh

Behavior:
  - Validates status values in queue/tasks, queue/reports, bridge/index.md
  - Writes:
      status/lifecycle_validation.yaml
      status/lifecycle_validation.md
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
cd "$repo_root"

allowed="queued assigned reviewing integrated done blocked in_progress todo completed ready failed"
is_allowed() {
  local s="${1:-}"
  for a in $allowed; do
    [[ "$s" == "$a" ]] && return 0
  done
  return 1
}

mkdir -p status
now="$(date '+%Y-%m-%dT%H:%M:%S%z')"
issues=0
issue_lines=()

check_yaml_status() {
  local f="$1"
  local s
  s="$(awk -F': ' '/^[[:space:]]*status:[[:space:]]*/{print $2; exit}' "$f" 2>/dev/null | tr -d '"\r' || true)"
  [[ -n "$s" ]] || return 0
  if ! is_allowed "$s"; then
    issues=$((issues + 1))
    issue_lines+=("invalid_status|file=${f}|status=${s}")
  fi
}

for f in queue/tasks/*.yaml; do
  [[ -f "$f" ]] || continue
  check_yaml_status "$f"
done

for f in queue/reports/*.yaml; do
  [[ -f "$f" ]] || continue
  check_yaml_status "$f"
done

if [[ -f bridge/index.md ]]; then
  while IFS= read -r line; do
    [[ "$line" =~ ^\|[[:space:]]*bridge_ ]] || continue
    status_val="$(printf '%s' "$line" | awk -F'|' '{gsub(/ /,"",$4); print $4}')"
    if [[ -n "$status_val" ]] && ! is_allowed "$status_val"; then
      issues=$((issues + 1))
      issue_lines+=("invalid_index_status|line=${line}")
    fi
  done < bridge/index.md
fi

health="ok"
if (( issues > 0 )); then
  health="warn"
fi

{
  echo "timestamp: \"$now\""
  echo "health: \"$health\""
  echo "issues: \"$issues\""
  if (( issues > 0 )); then
    echo "details:"
    for it in "${issue_lines[@]}"; do
      echo "  - \"$it\""
    done
  fi
} > status/lifecycle_validation.yaml

{
  echo "# Lifecycle Validation"
  echo "updated: $now"
  echo
  echo "- health: $health"
  echo "- issues: $issues"
  if (( issues > 0 )); then
    echo
    echo "## Details"
    for it in "${issue_lines[@]}"; do
      echo "- $it"
    done
  fi
} > status/lifecycle_validation.md

echo "lifecycle_validation_done|health=${health}|issues=${issues}"
if (( issues > 0 )); then
  exit 1
fi
