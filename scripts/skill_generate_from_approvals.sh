#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  scripts/skill_generate_from_approvals.sh \
    [--approvals queue/skill_approvals.yaml] \
    [--skills-root ~/.codex/skills] \
    [--results status/skill_generation_results.md]

Approval schema (flat list):
approvals:
  - task_id: cmd_123
    name: neko-example-skill
    decision: approved            # approved | rejected | pending
    description: "..."
    trigger: "..."
    source_report: "queue/reports/worker1_cmd_123_report.yaml"
    cross_review: passed          # passed required to generate
    trigger_quality: passed       # passed required to generate
USAGE
}

approvals_file="queue/skill_approvals.yaml"
skills_root="${HOME}/.codex/skills"
results_file="status/skill_generation_results.md"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --approvals) approvals_file="${2:-}"; shift 2 ;;
    --skills-root) skills_root="${2:-}"; shift 2 ;;
    --results) results_file="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ ! -f "$approvals_file" ]]; then
  echo "Approvals file not found: $approvals_file" >&2
  exit 1
fi

mkdir -p "$skills_root" "$(dirname "$results_file")"

trim() {
  local v="$1"
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  v="${v%\"}"
  v="${v#\"}"
  v="${v%\'}"
  v="${v#\'}"
  printf '%s' "$v"
}

description_quality_ok() {
  local d="$1"
  local lower
  lower="$(printf '%s' "$d" | tr '[:upper:]' '[:lower:]')"
  if (( ${#d} < 25 )); then
    return 1
  fi
  if [[ "$lower" =~ when|if|for|whenever|場合|とき|時 ]]; then
    return 0
  fi
  return 1
}

existing_name_conflict() {
  local name="$1"
  if [[ -d "${skills_root}/${name}" ]]; then
    return 0
  fi
  if find "$skills_root" -maxdepth 2 -type f -name 'SKILL.md' -print0 2>/dev/null | \
    xargs -0 rg -n "^name:[[:space:]]*${name}$" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

write_skill_file() {
  local dir="$1"
  local name="$2"
  local description="$3"
  local trigger="$4"
  local source_report="$5"
  local task_id="$6"
  local now
  now="$(date '+%Y-%m-%dT%H:%M:%S%z')"

  mkdir -p "$dir/scripts" "$dir/resources"
  cat > "${dir}/SKILL.md" <<EOF
---
name: ${name}
description: ${description}
---

# ${name}

## Overview
Reusable workflow skill generated from approved candidate.

## When to Use
${trigger}

## Pre-Requisites
- Confirm required input files are available.
- Confirm expected output path and completion criteria.

## Critical Rules
1. Follow chain-of-command and reporting protocol.
2. Keep source attribution for reused ideas.
3. Do not run destructive actions without explicit approval.

## Instructions
STEP 0: Read the task context and confirm success criteria.
STEP 1: Gather relevant files and extract constraints.
STEP 2: Execute the workflow with reproducible commands.
STEP 3: Produce output and include verification evidence.
STEP 4: Report summary, files changed, and next actions.

## Pitfalls
- Vague triggers reduce auto-invocation precision.
- Missing evidence causes repeated review cycles.

## Example
Input: Task that matches trigger conditions.
Output: Completed deliverable with evidence and attribution.

## Metadata
- generated_at: ${now}
- source_task_id: ${task_id}
- source_report: ${source_report}
EOF
}

now_ts="$(date '+%Y-%m-%dT%H:%M:%S%z')"
{
  echo "# Skill Generation Results"
  echo
  echo "- generated_at: ${now_ts}"
  echo "- approvals_file: ${approvals_file}"
  echo "- skills_root: ${skills_root}"
  echo
  echo "## Entries"
} > "$results_file"

declare -A generated_this_run=()

task_id=""
name=""
decision=""
description=""
trigger=""
source_report=""
cross_review=""
trigger_quality=""
entry_open=0

process_entry() {
  local task_id_local="$1"
  local name_local="$2"
  local decision_local="$3"
  local description_local="$4"
  local trigger_local="$5"
  local source_report_local="$6"
  local cross_review_local="$7"
  local trigger_quality_local="$8"

  [[ -z "$task_id_local" && -z "$name_local" ]] && return 0
  if [[ "$decision_local" != "approved" ]]; then
    echo "- ${task_id_local:-unknown}: skipped (decision=${decision_local:-missing})" >> "$results_file"
    return 0
  fi
  if [[ "$cross_review_local" != "passed" || "$trigger_quality_local" != "passed" ]]; then
    echo "- ${task_id_local:-unknown}: skipped (cross_review/trigger_quality gate failed)" >> "$results_file"
    return 0
  fi
  if [[ -z "$name_local" || -z "$description_local" || -z "$trigger_local" ]]; then
    echo "- ${task_id_local:-unknown}: skipped (missing required fields)" >> "$results_file"
    return 0
  fi
  if ! description_quality_ok "$description_local"; then
    echo "- ${task_id_local:-unknown}: skipped (description quality gate failed)" >> "$results_file"
    return 0
  fi
  if [[ -n "${generated_this_run[$name_local]:-}" ]]; then
    echo "- ${task_id_local:-unknown}: skipped (duplicate name in same run: ${name_local})" >> "$results_file"
    return 0
  fi
  if existing_name_conflict "$name_local"; then
    echo "- ${task_id_local:-unknown}: skipped (duplicate existing skill: ${name_local})" >> "$results_file"
    return 0
  fi

  write_skill_file "${skills_root}/${name_local}" "$name_local" "$description_local" "$trigger_local" "$source_report_local" "$task_id_local"
  generated_this_run["$name_local"]=1
  echo "- ${task_id_local}: generated ${skills_root}/${name_local}/SKILL.md" >> "$results_file"
}

while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
  line="$(trim "$raw_line")"
  [[ -z "$line" ]] && continue
  [[ "$line" == "approvals:" ]] && continue

  if [[ "$line" == "- task_id:"* ]]; then
    if [[ $entry_open -eq 1 ]]; then
      process_entry "$task_id" "$name" "$decision" "$description" "$trigger" "$source_report" "$cross_review" "$trigger_quality"
    fi
    task_id="$(trim "${line#- task_id:}")"
    name=""
    decision=""
    description=""
    trigger=""
    source_report=""
    cross_review=""
    trigger_quality=""
    entry_open=1
    continue
  fi

  [[ $entry_open -eq 0 ]] && continue

  if [[ "$line" == "name:"* ]]; then
    name="$(trim "${line#name:}")"
  elif [[ "$line" == "decision:"* ]]; then
    decision="$(trim "${line#decision:}")"
  elif [[ "$line" == "description:"* ]]; then
    description="$(trim "${line#description:}")"
  elif [[ "$line" == "trigger:"* ]]; then
    trigger="$(trim "${line#trigger:}")"
  elif [[ "$line" == "source_report:"* ]]; then
    source_report="$(trim "${line#source_report:}")"
  elif [[ "$line" == "cross_review:"* ]]; then
    cross_review="$(trim "${line#cross_review:}")"
  elif [[ "$line" == "trigger_quality:"* ]]; then
    trigger_quality="$(trim "${line#trigger_quality:}")"
  fi
done < "$approvals_file"

if [[ $entry_open -eq 1 ]]; then
  process_entry "$task_id" "$name" "$decision" "$description" "$trigger" "$source_report" "$cross_review" "$trigger_quality"
fi

echo "skill_generation_done|results=${results_file}|skills_root=${skills_root}"
