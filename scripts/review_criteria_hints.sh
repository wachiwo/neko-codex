#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage:
  scripts/review_criteria_hints.sh --ext md
  scripts/review_criteria_hints.sh --lang markdown
  scripts/review_criteria_hints.sh --ext sh --format csv

Options:
  --config <path>   Criteria file path (default: config/review_criteria.yaml)
  --ext <ext>       File extension without dot (e.g. md, sh, html)
  --lang <lang>     Language key directly (e.g. markdown, shell)
  --format csv|nl   Output format (default: nl)
USAGE
}

cfg="config/review_criteria.yaml"
ext=""
lang=""
fmt="nl"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) cfg="${2:-}"; shift 2 ;;
    --ext) ext="${2:-}"; shift 2 ;;
    --lang) lang="${2:-}"; shift 2 ;;
    --format) fmt="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ ! -f "$cfg" ]]; then
  echo "criteria config not found: $cfg" >&2
  exit 1
fi

if [[ -z "$lang" && -z "$ext" ]]; then
  echo "Either --lang or --ext is required" >&2
  exit 2
fi

if [[ -z "$lang" ]]; then
  ext="$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]' | sed 's/^\.//')"
  lang="$(awk -F': ' -v k="ext_${ext}" '
    $1==k {gsub(/"/, "", $2); print $2; exit}
  ' "$cfg")"
fi

if [[ -z "$lang" ]]; then
  lang="markdown"
fi

mapfile -t checks < <(
  awk -F': ' -v l="$lang" '
    /^base_check_[0-9]+:/ {
      v=$2; gsub(/^"/, "", v); gsub(/"$/, "", v); print v
    }
    $1 ~ ("^" l "_check_[0-9]+$") {
      v=$2; gsub(/^"/, "", v); gsub(/"$/, "", v); print v
    }
  ' "$cfg"
)

if [[ "${#checks[@]}" -eq 0 ]]; then
  exit 0
fi

if [[ "$fmt" == "csv" ]]; then
  out=""
  for c in "${checks[@]}"; do
    c="${c//,/;}"
    if [[ -z "$out" ]]; then
      out="$c"
    else
      out="${out},${c}"
    fi
  done
  echo "$out"
else
  printf '%s\n' "${checks[@]}"
fi
