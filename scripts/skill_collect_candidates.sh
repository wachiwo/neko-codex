#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  scripts/skill_collect_candidates.sh \
    [--reports-dir queue/reports] \
    [--dashboard dashboard.md] \
    [--output status/skill_candidates.tsv] \
    [--conflicts status/skill_candidate_conflicts.tsv]

Behavior:
  - Scans worker reports for skill_candidate blocks.
  - Enforces "1 candidate per task_id" policy.
  - Writes candidate TSV + conflict TSV.
  - Updates dashboard.md "## Skill Candidates" section automatically.
USAGE
}

reports_dir="queue/reports"
dashboard_file="dashboard.md"
output_tsv="status/skill_candidates.tsv"
conflict_tsv="status/skill_candidate_conflicts.tsv"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --reports-dir) reports_dir="${2:-}"; shift 2 ;;
    --dashboard) dashboard_file="${2:-}"; shift 2 ;;
    --output) output_tsv="${2:-}"; shift 2 ;;
    --conflicts) conflict_tsv="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ ! -d "$reports_dir" ]]; then
  echo "Reports directory not found: $reports_dir" >&2
  exit 1
fi

mkdir -p "$(dirname "$output_tsv")" "$(dirname "$conflict_tsv")" "$(dirname "$dashboard_file")"

strip_quotes() {
  local v="$1"
  v="${v%\"}"
  v="${v#\"}"
  v="${v%\'}"
  v="${v#\'}"
  printf '%s' "$v"
}

extract_task_id() {
  local file="$1"
  local task_id
  task_id="$(awk -F': ' '/^task_id:[[:space:]]*/ {print $2; exit}' "$file" | tr -d '\r' || true)"
  if [[ -n "$task_id" ]]; then
    task_id="$(strip_quotes "$task_id")"
    printf '%s' "$task_id"
    return
  fi
  local base
  base="$(basename "$file")"
  base="${base#*_}"
  base="${base%_report.yaml}"
  printf '%s' "$base"
}

extract_timestamp() {
  local file="$1"
  awk -F': ' '/^timestamp:[[:space:]]*/ {print $2; exit}' "$file" | tr -d '\r' || true
}

parse_skill_block() {
  local file="$1"
  awk '
    BEGIN {
      in_block=0
      found=""
      name=""
      desc=""
      reason=""
      saw_none=0
    }
    /^skill_candidate:[[:space:]]*none[[:space:]]*$/ {
      saw_none=1
      exit
    }
    /^skill_candidate:[[:space:]]*$/ {
      in_block=1
      next
    }
    in_block==1 {
      if ($0 ~ /^[^[:space:]]/) {
        in_block=0
      } else {
        line=$0
        sub(/^[[:space:]]+/, "", line)
        if (line ~ /^found:[[:space:]]*/) {
          sub(/^found:[[:space:]]*/, "", line)
          found=line
        } else if (line ~ /^name:[[:space:]]*/) {
          sub(/^name:[[:space:]]*/, "", line)
          name=line
        } else if (line ~ /^description:[[:space:]]*/) {
          sub(/^description:[[:space:]]*/, "", line)
          desc=line
        } else if (line ~ /^reason:[[:space:]]*/) {
          sub(/^reason:[[:space:]]*/, "", line)
          reason=line
        }
      }
    }
    END {
      if (saw_none==1) {
        print "mode=none"
      } else if (found != "" || name != "" || desc != "" || reason != "") {
        print "mode=block"
        print "found=" found
        print "name=" name
        print "description=" desc
        print "reason=" reason
      } else {
        print "mode=missing"
      }
    }
  ' "$file"
}

safe_cell() {
  local v="$1"
  v="${v//$'\t'/ }"
  v="${v//$'\n'/ }"
  printf '%s' "$v"
}

declare -A task_owner=()
declare -A task_name=()
declare -A task_path=()
declare -A task_desc=()
declare -A task_reason=()
declare -A task_ts=()

{
  printf 'task_id\tname\tdescription\treason\tworker\treport_path\ttimestamp\n'
} > "$output_tsv"
{
  printf 'task_id\texisting_name\tnew_name\texisting_worker\tnew_worker\texisting_report\tnew_report\n'
} > "$conflict_tsv"

while IFS= read -r report; do
  [[ -f "$report" ]] || continue
  worker="$(basename "$report" | cut -d'_' -f1)"
  task_id="$(extract_task_id "$report")"
  ts="$(extract_timestamp "$report")"
  ts="$(strip_quotes "$ts")"

  mode=""
  found=""
  name=""
  description=""
  reason=""
  while IFS='=' read -r key val; do
    case "$key" in
      mode) mode="$val" ;;
      found) found="$(strip_quotes "$val")" ;;
      name) name="$(strip_quotes "$val")" ;;
      description) description="$(strip_quotes "$val")" ;;
      reason) reason="$(strip_quotes "$val")" ;;
    esac
  done < <(parse_skill_block "$report")

  if [[ "$mode" != "block" ]]; then
    continue
  fi

  lower_found="$(printf '%s' "$found" | tr '[:upper:]' '[:lower:]')"
  if [[ "$lower_found" != "true" ]]; then
    continue
  fi
  if [[ -z "$name" || "$name" == "null" ]]; then
    continue
  fi

  if [[ -n "${task_name[$task_id]:-}" ]]; then
    if [[ "${task_name[$task_id]}" != "$name" ]]; then
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$(safe_cell "$task_id")" \
        "$(safe_cell "${task_name[$task_id]}")" \
        "$(safe_cell "$name")" \
        "$(safe_cell "${task_owner[$task_id]}")" \
        "$(safe_cell "$worker")" \
        "$(safe_cell "${task_path[$task_id]}")" \
        "$(safe_cell "$report")" >> "$conflict_tsv"
    fi
    continue
  fi

  task_owner["$task_id"]="$worker"
  task_name["$task_id"]="$name"
  task_path["$task_id"]="$report"
  task_desc["$task_id"]="$description"
  task_reason["$task_id"]="$reason"
  task_ts["$task_id"]="$ts"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(safe_cell "$task_id")" \
    "$(safe_cell "$name")" \
    "$(safe_cell "$description")" \
    "$(safe_cell "$reason")" \
    "$(safe_cell "$worker")" \
    "$(safe_cell "$report")" \
    "$(safe_cell "$ts")" >> "$output_tsv"
done < <(find "$reports_dir" -maxdepth 1 -type f -name 'worker*_*_report.yaml' | sort)

now_ts="$(date '+%Y-%m-%dT%H:%M:%S%z')"
section_tmp="$(mktemp)"

{
  echo "## Skill Candidates"
  echo "Updated: ${now_ts}"
  echo
  echo "### Active Candidates"
  echo "| Task | Candidate | Description | Worker | Report |"
  echo "|------|-----------|-------------|--------|--------|"
  row_count=0
  while IFS=$'\t' read -r task_id name description reason worker report_path ts; do
    [[ "$task_id" == "task_id" ]] && continue
    row_count=$((row_count + 1))
    if [[ -z "$description" ]]; then
      description="(no description)"
    fi
    echo "| ${task_id} | ${name} | ${description} | ${worker} | \`${report_path}\` |"
  done < "$output_tsv"
  if [[ $row_count -eq 0 ]]; then
    echo "| - | - | No active skill candidates | - | - |"
  fi
  echo
  echo "### Candidate Conflicts"
  echo "| Task | Existing | New | Existing Worker | New Worker |"
  echo "|------|----------|-----|-----------------|------------|"
  conflict_count=0
  while IFS=$'\t' read -r task_id existing_name new_name existing_worker new_worker existing_report new_report; do
    [[ "$task_id" == "task_id" ]] && continue
    conflict_count=$((conflict_count + 1))
    echo "| ${task_id} | ${existing_name} | ${new_name} | ${existing_worker} | ${new_worker} |"
  done < "$conflict_tsv"
  if [[ $conflict_count -eq 0 ]]; then
    echo "| - | - | No conflicts | - | - |"
  fi
} > "$section_tmp"

if [[ ! -f "$dashboard_file" ]]; then
  cat > "$dashboard_file" <<EOF
# =^._.^= にゃんボード (Codex版)
最終更新: ${now_ts}

## 要対応 - ご主人様のご判断をお待ちしておりますにゃ
なし

$(cat "$section_tmp")
EOF
else
  if rg -n '^最終更新:' "$dashboard_file" >/dev/null 2>&1; then
    sed -i "s/^最終更新:.*/最終更新: ${now_ts}/" "$dashboard_file"
  fi
  tmp_dashboard="$(mktemp)"
  awk -v section_file="$section_tmp" '
    BEGIN {
      in_section=0
      replaced=0
      while ((getline line < section_file) > 0) {
        section = section line "\n"
      }
      close(section_file)
    }
    /^## Skill Candidates$/ {
      printf "%s", section
      in_section=1
      replaced=1
      next
    }
    /^## / {
      if (in_section==1) {
        in_section=0
      }
    }
    {
      if (in_section==0) {
        print $0
      }
    }
    END {
      if (replaced==0) {
        print ""
        printf "%s", section
      }
    }
  ' "$dashboard_file" > "$tmp_dashboard"
  mv "$tmp_dashboard" "$dashboard_file"
fi

rm -f "$section_tmp"
echo "skill_candidates_collected|output=${output_tsv}|conflicts=${conflict_tsv}|dashboard=${dashboard_file}"
