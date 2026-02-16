#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  scripts/skill_evaluate_candidates.sh \
    [--candidates status/skill_candidates.tsv] \
    [--evaluations queue/skill_evaluations.yaml] \
    [--designs queue/skill_designs.yaml] \
    [--skills-root ~/.codex/skills]

Behavior:
  - Scores each skill candidate on a 20-point rubric.
  - Applies duplicate deductions.
  - Writes evaluations and auto-generated design docs (score >= 12).
USAGE
}

candidates_tsv="status/skill_candidates.tsv"
evaluations_yaml="queue/skill_evaluations.yaml"
designs_yaml="queue/skill_designs.yaml"
skills_root="${HOME}/.codex/skills"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --candidates) candidates_tsv="${2:-}"; shift 2 ;;
    --evaluations) evaluations_yaml="${2:-}"; shift 2 ;;
    --designs) designs_yaml="${2:-}"; shift 2 ;;
    --skills-root) skills_root="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ ! -f "$candidates_tsv" ]]; then
  echo "Candidates file not found: $candidates_tsv" >&2
  exit 1
fi

mkdir -p "$(dirname "$evaluations_yaml")" "$(dirname "$designs_yaml")"

sanitize_yaml() {
  local v="$1"
  v="${v//\\/\\\\}"
  v="${v//\"/\\\"}"
  printf '%s' "$v"
}

score_reusability() {
  local d="$1" r="$2"
  local text
  text="$(printf '%s %s' "$d" "$r" | tr '[:upper:]' '[:lower:]')"
  local s=2
  [[ ${#d} -ge 40 ]] && s=$((s + 1))
  if [[ "$text" =~ reusable|repeat|across|common|template|automation|再利用|複数|横断|汎用 ]]; then
    s=$((s + 2))
  fi
  (( s > 5 )) && s=5
  echo "$s"
}

score_complexity() {
  local d="$1" r="$2"
  local text
  text="$(printf '%s %s' "$d" "$r" | tr '[:upper:]' '[:lower:]')"
  local s=1
  [[ ${#r} -ge 40 ]] && s=$((s + 1))
  if [[ "$text" =~ pipeline|workflow|multi|step|gate|validation|analysis|統合|段階|複雑|検証 ]]; then
    s=$((s + 2))
  fi
  if [[ "$text" =~ guard|review|cross-review|handoff|ルーブリック ]]; then
    s=$((s + 1))
  fi
  (( s > 5 )) && s=5
  echo "$s"
}

score_stability() {
  local d="$1" r="$2"
  local text
  text="$(printf '%s %s' "$d" "$r" | tr '[:upper:]' '[:lower:]')"
  local s=3
  if [[ "$text" =~ incident|temporary|temp|urgent|hotfix|ad-hoc|緊急|一時|暫定 ]]; then
    s=$((s - 2))
  fi
  if [[ "$text" =~ standard|routine|stable|policy|template|定型|標準 ]]; then
    s=$((s + 1))
  fi
  (( s < 0 )) && s=0
  (( s > 5 )) && s=5
  echo "$s"
}

score_value() {
  local d="$1" r="$2"
  local text
  text="$(printf '%s %s' "$d" "$r" | tr '[:upper:]' '[:lower:]')"
  local s=2
  [[ ${#r} -ge 50 ]] && s=$((s + 1))
  if [[ "$text" =~ save|faster|reduce|prevent|improve|automate|削減|短縮|高速|防止|自動 ]]; then
    s=$((s + 2))
  fi
  (( s > 5 )) && s=5
  echo "$s"
}

declare -A name_count=()
while IFS=$'\t' read -r task_id name description reason worker report_path timestamp; do
  [[ "$task_id" == "task_id" ]] && continue
  [[ -z "$name" ]] && continue
  name_count["$name"]=$(( ${name_count["$name"]:-0} + 1 ))
done < "$candidates_tsv"

{
  echo "evaluations:"
} > "$evaluations_yaml"

{
  echo "skill_designs:"
} > "$designs_yaml"

while IFS=$'\t' read -r task_id name description reason worker report_path timestamp; do
  [[ "$task_id" == "task_id" ]] && continue
  [[ -z "$name" ]] && continue

  r_score="$(score_reusability "$description" "$reason")"
  c_score="$(score_complexity "$description" "$reason")"
  s_score="$(score_stability "$description" "$reason")"
  v_score="$(score_value "$description" "$reason")"
  subtotal=$((r_score + c_score + s_score + v_score))

  deduction=0
  existing_skill=false
  if [[ -d "${skills_root}/${name}" ]]; then
    existing_skill=true
    deduction=$((deduction + 5))
  fi
  collisions="${name_count["$name"]:-1}"
  if (( collisions > 1 )); then
    deduction=$((deduction + 2))
  fi

  total=$((subtotal - deduction))
  (( total < 0 )) && total=0

  recommendation="skip"
  action="skip"
  if (( total >= 16 )); then
    recommendation="strongly_recommended"
    action="design_doc"
  elif (( total >= 12 )); then
    recommendation="recommended"
    action="design_doc"
  fi

  {
    echo "  - task_id: ${task_id}"
    echo "    name: \"$(sanitize_yaml "$name")\""
    echo "    proposed_by: ${worker}"
    echo "    source_report: \"$(sanitize_yaml "$report_path")\""
    echo "    score:"
    echo "      reusability: ${r_score}"
    echo "      complexity: ${c_score}"
    echo "      stability: ${s_score}"
    echo "      value: ${v_score}"
    echo "      subtotal: ${subtotal}"
    echo "      deduction: ${deduction}"
    echo "      total: ${total}"
    echo "    recommendation: ${recommendation}"
    echo "    action: ${action}"
    echo "    duplicate_check:"
    echo "      existing_skill: ${existing_skill}"
    echo "      name_collision_in_batch: ${collisions}"
    echo "    candidate:"
    echo "      description: \"$(sanitize_yaml "$description")\""
    echo "      reason: \"$(sanitize_yaml "$reason")\""
  } >> "$evaluations_yaml"

  if [[ "$action" == "design_doc" ]]; then
    {
      echo "  - task_id: ${task_id}"
      echo "    name: \"$(sanitize_yaml "$name")\""
      echo "    description: \"$(sanitize_yaml "$description")\""
      echo "    trigger: \"$(sanitize_yaml "$description")\""
      echo "    structure:"
      echo "      - SKILL.md"
      echo "      - scripts/"
      echo "      - resources/"
      echo "    save_path: \"${skills_root}/${name}/\""
      echo "    instructions:"
      echo "      overview: \"$(sanitize_yaml "$reason")\""
      echo "      when_to_use: \"$(sanitize_yaml "$description")\""
      echo "      critical_rules:"
      echo "        - \"Use this skill only when trigger conditions are explicit.\""
      echo "        - \"Do not bypass duplicate check before generation.\""
      echo "      steps:"
      echo "        - \"Collect concrete inputs and expected outputs.\""
      echo "        - \"Run with reproducible commands and evidence output.\""
      echo "        - \"Attach source_attribution in the final report.\""
      echo "    evaluation:"
      echo "      score: \"${total}/20\""
      echo "      recommendation: \"${recommendation}\""
      echo "    existing_skill_comparison:"
      echo "      checked: true"
      echo "      existing_skills_found: []"
      echo "      deduction: ${deduction}"
      echo "      action: \"${action}\""
      echo "    source_report: \"$(sanitize_yaml "$report_path")\""
    } >> "$designs_yaml"
  fi
done < "$candidates_tsv"

echo "skill_candidates_evaluated|evaluations=${evaluations_yaml}|designs=${designs_yaml}"
