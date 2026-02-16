#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage:
  scripts/bridge_finalize.sh \
    --task-id bridge_037 \
    --report-cmd-id cmd_013 \
    [--bridge-root /mnt/c/tools/bridge] \
    [--worker-report-glob '/mnt/c/tools/neko-codex/queue/reports/*cmd_013*_report.yaml'] \
    [--min-workers 4] [--force]

Behavior:
  - Reads inbox/<task_id>.md
  - Generates outbox/<task_id>.md scaffold with required sections
  - Auto-fills proof block (worker_count + worker_report_paths)
  - Runs bridge_done_guard
  - Updates bridge/index.md row to owner=codex,status=done,latest_file=outbox/<task_id>.md

Notes:
  - This automates non-critical formatting and evidence wiring.
  - Replace scaffold bullet points with substantive content before sharing externally.
USAGE
}

task_id=""
report_cmd_id=""
worker_report_glob=""
bridge_root="${BRIDGE_ROOT:-/mnt/c/tools/bridge}"
repo_root="/mnt/c/tools/neko-codex"
min_workers="${BRIDGE_MIN_WORKER_REPORTS:-4}"
force=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --task-id) task_id="${2:-}"; shift 2 ;;
    --report-cmd-id) report_cmd_id="${2:-}"; shift 2 ;;
    --worker-report-glob) worker_report_glob="${2:-}"; shift 2 ;;
    --bridge-root) bridge_root="${2:-}"; shift 2 ;;
    --repo-root) repo_root="${2:-}"; shift 2 ;;
    --min-workers) min_workers="${2:-}"; shift 2 ;;
    --force) force=1; shift ;;
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

if [[ -z "$report_cmd_id" && -z "$worker_report_glob" ]]; then
  echo "Either --report-cmd-id or --worker-report-glob is required" >&2
  exit 2
fi

if ! [[ "$min_workers" =~ ^[0-9]+$ ]]; then
  echo "--min-workers must be integer" >&2
  exit 2
fi

inbox_file="${bridge_root}/inbox/${task_id}.md"
outbox_file="${bridge_root}/outbox/${task_id}.md"
index_file="${bridge_root}/index.md"

if [[ ! -f "$inbox_file" ]]; then
  echo "inbox not found: $inbox_file" >&2
  exit 3
fi

if [[ -f "$outbox_file" && $force -ne 1 ]]; then
  echo "outbox already exists (use --force to overwrite): $outbox_file" >&2
  exit 4
fi

extract_header_value() {
  local file="$1"
  local key="$2"
  local v

  v="$(awk -F': ' -v k="$key" '
    $1 ~ "^[[:space:]]*-[[:space:]]*" k "$" {
      print $2
      exit
    }
  ' "$file" 2>/dev/null | tr -d '\r')"

  if [[ -z "$v" ]]; then
    v="$(awk -F'=' -v k="$key" '$1==k{print $2; exit}' "$file" 2>/dev/null | tr -d '\r')"
  fi

  printf '%s' "$v"
}

from_inbox="$(extract_header_value "$inbox_file" "from")"
to_inbox="$(extract_header_value "$inbox_file" "to")"

if [[ -z "$from_inbox" ]]; then
  from_inbox="claude"
fi

target_peer="$from_inbox"
if [[ "$target_peer" == "codex" && -n "$to_inbox" ]]; then
  target_peer="$to_inbox"
fi

if [[ "$target_peer" == "codex" || -z "$target_peer" ]]; then
  target_peer="claude"
fi

collect_reports() {
  local -a paths=()

  if [[ -n "$worker_report_glob" ]]; then
    while IFS= read -r p; do
      [[ -n "$p" ]] && paths+=("$p")
    done < <(compgen -G "$worker_report_glob" | sort)
  else
    while IFS= read -r p; do
      [[ -n "$p" ]] && paths+=("$p")
    done < <(find "${repo_root}/queue/reports" -maxdepth 1 -type f \( -name "worker*_${report_cmd_id}_*_report.yaml" -o -name "worker*_${report_cmd_id}_report.yaml" \) | sort)
  fi

  printf '%s\n' "${paths[@]}"
}

mapfile -t report_paths < <(collect_reports)

if (( ${#report_paths[@]} < min_workers )); then
  echo "insufficient reports: ${#report_paths[@]} < ${min_workers}" >&2
  exit 5
fi

for p in "${report_paths[@]}"; do
  if [[ ! -f "$p" ]]; then
    echo "report not found: $p" >&2
    exit 6
  fi
done

mkdir -p "${bridge_root}/outbox"

{
  echo "task_id=${task_id}"
  echo "from=codex"
  echo "to=${target_peer}"
  echo "status=done"
  echo
  echo "## 結論"
  echo "- ここに最終結論を記入。"
  echo
  echo '```text'
  echo "worker_count: ${#report_paths[@]}"
  echo "worker_report_paths:"
  for p in "${report_paths[@]}"; do
    echo "- ${p}"
  done
  echo '```'
  echo
  echo "## 各問題点への見解"
  echo "- 論点1: ここに記入。"
  echo "- 論点2: ここに記入。"
  echo
  echo "## 改善計画(分類: instruction-change/code-change/poc + 見積)"
  echo "- instruction-change: ここに記入（見積）。"
  echo "- code-change: ここに記入（見積）。"
  echo "- poc: ここに記入（見積）。"
  echo
  echo "## ${target_peer^}側への支援依頼"
  echo "- ここに必要な支援依頼を記入。"
  echo
  echo "## 関連ファイル"
  echo "- ${inbox_file}"
  for p in "${report_paths[@]}"; do
    echo "- ${p}"
  done
  echo
  echo "## Source Attribution"
  echo "- Request source: ${inbox_file}"
  for p in "${report_paths[@]}"; do
    echo "- Worker analysis source: ${p}"
  done
} > "$outbox_file"

scripts/bridge_done_guard.sh \
  --task-id "$task_id" \
  --bridge-root "$bridge_root" \
  --min-workers "$min_workers" \
  --source-file "$inbox_file"

if [[ ! -f "$index_file" ]]; then
  cat > "$index_file" <<'INDEXEOF'
# Bridge Index — タスク一覧台帳

| task_id | owner | status | updated_at | latest_file |
|---------|-------|--------|------------|-------------|
INDEXEOF
fi

updated_at="$(date '+%Y-%m-%dT%H:%M')"
new_row="| ${task_id} | codex | done | ${updated_at} | outbox/${task_id}.md |"
tmp="$(mktemp)"
awk -v id="$task_id" -v row="$new_row" '
  BEGIN{done=0}
  {
    if ($0 ~ "^\\|[[:space:]]*" id "[[:space:]]*\\|") {
      print row
      done=1
    } else {
      print
    }
  }
  END {
    if (!done) {
      print row
    }
  }
' "$index_file" > "$tmp"
mv "$tmp" "$index_file"

echo "bridge_finalize_done|task_id=${task_id}|outbox=${outbox_file}|reports=${#report_paths[@]}|index=${index_file}"
