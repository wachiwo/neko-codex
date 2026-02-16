#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage:
  scripts/bridge_auto_reader.sh --once
  scripts/bridge_auto_reader.sh --watch [--interval 30]

Behavior:
  - Reads ${BRIDGE_ROOT}/inbox/bridge_*.md
  - Detects new tasks from claude -> codex with status: todo
  - Auto-Rally: handles auto_rally=true with hop/session guards
  - Records seen tasks in status/bridge_seen_tasks.tsv
  - Records processed hops in status/processed_hops.tsv
  - Appends arrival event to queue/inbox/kashira.queue
  - Updates status/bridge_pending.md snapshot
USAGE
}

mode=""
interval=30
lock_fd=9
lock_file="status/bridge_auto_reader.watch.lock"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --once) mode="once"; shift ;;
    --watch) mode="watch"; shift ;;
    --interval) interval="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$mode" ]]; then
  usage >&2
  exit 2
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
default_bridge_root="${repo_root}/bridge"
env_bridge_root="${BRIDGE_ROOT:-}"

count_inbox_files() {
  local root="$1"
  local files=()
  shopt -s nullglob
  files=("${root}/inbox"/bridge_*.md)
  shopt -u nullglob
  echo "${#files[@]}"
}

select_bridge_root() {
  local env_root="$1"
  local default_root="$2"

  if [[ -n "$env_root" && -d "${env_root}/inbox" ]]; then
    echo "$env_root"
    return
  fi

  echo "$default_root"
}

bridge_root="$(select_bridge_root "$env_bridge_root" "$default_bridge_root")"
inbox_dir="${bridge_root}/inbox"
outbox_dir="${bridge_root}/outbox"
index_file="${bridge_root}/index.md"
seen_file="status/bridge_seen_tasks.tsv"
processed_hops_file="status/processed_hops.tsv"
active_rally_file="status/auto_rally_active.tsv"
pending_snapshot="status/bridge_pending.md"
log_file="logs/bridge_auto_reader.log"
delegation_requirements_file="status/bridge_delegation_requirements.tsv"
delegation_violations_file="status/bridge_guard_violations.tsv"
delegation_notified_file="status/bridge_guard_notified.tsv"
outbox_seen_file="status/bridge_outbox_seen.tsv"
outbox_events_file="status/bridge_outbox_events.tsv"
kashira_progress_guard_file="status/bridge_kashira_progress.tsv"
min_worker_reports="${BRIDGE_MIN_WORKER_REPORTS:-4}"
approval_queue_file="queue/approval_required.yaml"
auto_rally_target="${AUTO_RALLY_TARGET:-codex-oyabun:0.0}"
non_rally_auto_reply="${BRIDGE_NON_RALLY_AUTO_REPLY:-false}"
non_rally_auto_dispatch="${BRIDGE_NON_RALLY_AUTO_DISPATCH:-true}"
non_rally_dispatch_target="${BRIDGE_NON_RALLY_TARGET:-codex-oyabun:0.0}"
kashira_progress_timeout_sec="${BRIDGE_KASHIRA_PROGRESS_TIMEOUT_SEC:-180}"
kashira_progress_max_nudges="${BRIDGE_KASHIRA_PROGRESS_MAX_NUDGES:-2}"
kashira_progress_fallback_target="${BRIDGE_KASHIRA_FALLBACK_TARGET:-nekocodex:kashira}"
kashira_progress_enable_fallback="${BRIDGE_KASHIRA_ENABLE_FALLBACK:-true}"

mkdir -p status logs queue/inbox "$outbox_dir"
touch "$seen_file" "$processed_hops_file" "$log_file" \
  "$delegation_requirements_file" "$delegation_violations_file" "$delegation_notified_file" \
  "$outbox_seen_file" "$outbox_events_file" "$kashira_progress_guard_file"
[[ -f "$approval_queue_file" ]] || echo "approvals: []" > "$approval_queue_file"

if [[ ! -d "$inbox_dir" ]]; then
  echo "bridge_reader_error|missing_inbox_dir=${inbox_dir}" >&2
  printf '%s BRIDGE_READER_ERROR missing_inbox_dir=%s env_bridge_root=%s default_bridge_root=%s\n' \
    "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$inbox_dir" "${env_bridge_root:-unset}" "$default_bridge_root" >> "$log_file"
  exit 1
fi

printf '%s BRIDGE_READER_START bridge_root=%s env_bridge_root=%s default_bridge_root=%s inbox_count=%s\n' \
  "$(date '+%Y-%m-%dT%H:%M:%S%z')" \
  "$bridge_root" \
  "${env_bridge_root:-unset}" \
  "$default_bridge_root" \
  "$(count_inbox_files "$bridge_root")" >> "$log_file"

if [[ "$mode" == "watch" || "$mode" == "once" ]]; then
  exec {lock_fd}>"$lock_file"
  if ! flock -n "$lock_fd"; then
    echo "bridge_reader_already_running|mode=${mode}|lock_file=${lock_file}"
    exit 0
  fi
fi

extract_field() {
  local file="$1"
  local key="$2"
  awk -v k="$key" '
    function emit(v) {
      sub(/\r$/, "", v)
      gsub(/^[[:space:]]+/, "", v)
      gsub(/[[:space:]]+$/, "", v)
      gsub(/^"/, "", v)
      gsub(/"$/, "", v)
      print v
      exit
    }
    k=="task_id" && $0 ~ "^#[[:space:]]*bridge_[0-9A-Za-z._-]+" {
      line=$0
      sub("^#[[:space:]]*", "", line)
      sub("[[:space:]].*$", "", line)
      emit(line)
    }
    $0 ~ "^#[[:space:]]*" k "[[:space:]]*:[[:space:]]*" {
      line=$0
      sub("^#[[:space:]]*" k "[[:space:]]*:[[:space:]]*", "", line)
      emit(line)
    }
    $0 ~ "^[[:space:]]*-[[:space:]]*" k "[[:space:]]*:[[:space:]]*" {
      line=$0
      sub("^[[:space:]]*-[[:space:]]*" k "[[:space:]]*:[[:space:]]*", "", line)
      emit(line)
    }
    $0 ~ "^[[:space:]]*\\*\\*" k "\\*\\*[[:space:]]*:[[:space:]]*" {
      line=$0
      sub("^[[:space:]]*\\*\\*" k "\\*\\*[[:space:]]*:[[:space:]]*", "", line)
      emit(line)
    }
    $0 ~ "^[[:space:]]*" k "[[:space:]]*:[[:space:]]*" {
      line=$0
      sub("^[[:space:]]*" k "[[:space:]]*:[[:space:]]*", "", line)
      emit(line)
    }
  ' "$file" 2>/dev/null || true
}

normalize_actor() {
  local raw="${1:-}"
  local v
  v="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  if [[ "$v" =~ ^([a-z0-9_-]+) ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  else
    printf '%s' "$v"
  fi
}

normalize_status() {
  local raw="${1:-}"
  local v
  v="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  if [[ "$v" =~ ^([a-z_]+) ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  else
    printf '%s' "$v"
  fi
}

infer_status() {
  local status_raw="${1:-}"
  local from_norm="${2:-}"
  local to_norm="${3:-}"
  local status_norm
  status_norm="$(normalize_status "$status_raw")"
  if [[ -z "$status_norm" && "$from_norm" == "claude" && "$to_norm" == "codex" ]]; then
    echo "todo"
    return
  fi
  echo "$status_norm"
}

extract_section() {
  local file="$1"
  local heading="$2"
  awk -v h="$heading" '
    BEGIN { in=0 }
    $0 ~ "^##[[:space:]]*" h "[[:space:]]*$" { in=1; next }
    /^##[[:space:]]+/ { if (in) exit }
    in { print }
  ' "$file" 2>/dev/null || true
}

is_seen() {
  local task_id="$1"
  awk -F'\t' -v id="$task_id" '$1==id{found=1} END{exit(found?0:1)}' "$seen_file"
}

mark_seen() {
  local task_id="$1"
  local src="$2"
  local ts
  ts="$(date '+%Y-%m-%dT%H:%M:%S%z')"
  printf '%s\t%s\t%s\n' "$task_id" "$ts" "$src" >> "$seen_file"
}

is_done_by_outbox() {
  local task_id="$1"
  [[ -f "${outbox_dir}/${task_id}.md" ]]
}

ensure_index_file() {
  if [[ -f "$index_file" ]]; then
    return
  fi
  cat > "$index_file" <<'EOF'
# Bridge Index — タスク一覧台帳

| task_id | owner | status | updated_at | latest_file |
|---------|-------|--------|------------|-------------|
EOF
}

update_index_row() {
  local task_id="$1"
  local owner="$2"
  local status="$3"
  local latest_file="$4"
  local updated_at
  local tmp
  updated_at="$(date '+%Y-%m-%dT%H:%M')"
  tmp="$(mktemp)"
  ensure_index_file
  awk -v id="$task_id" -v owner="$owner" -v st="$status" -v ts="$updated_at" -v lf="$latest_file" '
    BEGIN {
      row="| " id " | " owner " | " st " | " ts " | " lf " |"
      replaced=0
    }
    {
      if ($0 ~ "^\\|[[:space:]]*" id "[[:space:]]*\\|") {
        print row
        replaced=1
      } else {
        print
      }
    }
    END {
      if (!replaced) {
        print row
      }
    }
  ' "$index_file" > "$tmp"
  mv "$tmp" "$index_file"
}

to_bool() {
  local v="${1:-}"
  v="$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')"
  [[ "$v" == "true" ]]
}

is_integer() {
  local v="${1:-}"
  [[ "$v" =~ ^[0-9]+$ ]]
}

to_epoch() {
  local v="${1:-}"
  date -d "$v" '+%s' 2>/dev/null || true
}

is_expired() {
  local expires_at="${1:-}"
  [[ -n "$expires_at" ]] || return 1
  local exp now
  exp="$(to_epoch "$expires_at")"
  [[ -n "$exp" ]] || return 1
  now="$(date '+%s')"
  (( now >= exp ))
}

get_active_rally() {
  [[ -f "$active_rally_file" ]] || return 0
  awk -F'\t' 'NR==1{print $1}' "$active_rally_file" 2>/dev/null || true
}

set_active_rally() {
  local rally_id="$1"
  local task_id="$2"
  local ts
  ts="$(date '+%Y-%m-%dT%H:%M:%S%z')"
  printf '%s\t%s\t%s\n' "$rally_id" "$task_id" "$ts" > "$active_rally_file"
}

clear_active_rally_if_match() {
  local rally_id="$1"
  local current
  current="$(get_active_rally)"
  if [[ "$current" == "$rally_id" ]]; then
    rm -f "$active_rally_file"
  fi
}

is_hop_processed() {
  local rally_id="$1"
  local hop_id="$2"
  local from="$3"
  local to="$4"
  awk -F'\t' -v r="$rally_id" -v h="$hop_id" -v f="$from" -v t="$to" '
    $1==r && $2==h && $3==f && $4==t {found=1}
    END{exit(found?0:1)}
  ' "$processed_hops_file"
}

mark_hop_processed() {
  local rally_id="$1"
  local hop_id="$2"
  local from="$3"
  local to="$4"
  local ts
  ts="$(date '+%Y-%m-%dT%H:%M:%S%z')"
  printf '%s\t%s\t%s\t%s\t%s\n' "$rally_id" "$hop_id" "$from" "$to" "$ts" >> "$processed_hops_file"
}

has_delegation_requirement() {
  local task_id="$1"
  awk -F'\t' -v id="$task_id" '$1==id{found=1} END{exit(found?0:1)}' "$delegation_requirements_file"
}

register_delegation_requirement() {
  local task_id="$1"
  local min_workers="$2"
  local source_file="$3"
  local ts
  if has_delegation_requirement "$task_id"; then
    return 0
  fi
  ts="$(date '+%Y-%m-%dT%H:%M:%S%z')"
  printf '%s\t%s\t%s\t%s\n' "$task_id" "$min_workers" "$source_file" "$ts" >> "$delegation_requirements_file"
}

is_delegation_notified() {
  local task_id="$1"
  awk -F'\t' -v id="$task_id" '$1==id{found=1} END{exit(found?0:1)}' "$delegation_notified_file"
}

mark_delegation_notified() {
  local task_id="$1"
  local ts
  if is_delegation_notified "$task_id"; then
    return 0
  fi
  ts="$(date '+%Y-%m-%dT%H:%M:%S%z')"
  printf '%s\t%s\n' "$task_id" "$ts" >> "$delegation_notified_file"
}

clear_delegation_notified() {
  local task_id="$1"
  local tmp
  tmp="$(mktemp)"
  awk -F'\t' -v id="$task_id" '$1!=id' "$delegation_notified_file" > "$tmp"
  mv "$tmp" "$delegation_notified_file"
}

approval_status_for_task() {
  local task_id="$1"
  local status
  status="$(awk -v id="$task_id" '
    BEGIN{cur_task=""; cur_status=""; last=""}
    /^  - id:/ {
      if (cur_task==id && cur_status!="") {last=cur_status}
      cur_task=""; cur_status=""
      next
    }
    /^    task_id:/ {cur_task=$2; next}
    /^    status:/ {cur_status=$2; next}
    END{
      if (cur_task==id && cur_status!="") {last=cur_status}
      print last
    }
  ' "$approval_queue_file" 2>/dev/null || true)"
  if [[ -z "$status" ]]; then
    echo "none"
  else
    echo "$status"
  fi
}

get_outbox_seen_mtime() {
  local task_id="$1"
  awk -F'\t' -v id="$task_id" '$1==id{print $2; exit}' "$outbox_seen_file"
}

set_outbox_seen_mtime() {
  local task_id="$1"
  local mtime="$2"
  local tmp
  tmp="$(mktemp)"
  awk -F'\t' -v id="$task_id" '$1!=id' "$outbox_seen_file" > "$tmp"
  printf '%s\t%s\n' "$task_id" "$mtime" >> "$tmp"
  mv "$tmp" "$outbox_seen_file"
}

register_kashira_progress_guard() {
  local task_id="$1"
  local source_file="$2"
  local now
  now="$(date +%s)"
  if awk -F'\t' -v id="$task_id" '$1==id{found=1} END{exit(found?0:1)}' "$kashira_progress_guard_file"; then
    return 0
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$task_id" "$now" 0 0 "$source_file" >> "$kashira_progress_guard_file"
}

has_kashira_progress_for_task() {
  local task_id="$1"
  [[ -f "queue/inbox/kashira.queue" ]] || return 1
  awk -F'|' -v t="$task_id" '
    $4==t && ($3=="task_assigned" || $3=="task_ack" || $3=="first_action" || $3=="report_done") { found=1; exit }
    END { exit(found?0:1) }
  ' queue/inbox/kashira.queue
}

dispatch_kashira_fallback() {
  local source_file="$1"
  local task_id="$2"
  local msg
  msg="Fallback dispatch request. Bridge task ${task_id} shows no kashira progress. Read ${source_file}, decompose, dispatch workers now, and report progress to oyabun."
  if ! command -v tmux >/dev/null 2>&1; then
    return 1
  fi
  if ! tmux has-session -t "${kashira_progress_fallback_target%%:*}" 2>/dev/null; then
    return 1
  fi
  tmux send-keys -t "$kashira_progress_fallback_target" "$msg"
  sleep 0.5
  tmux send-keys -t "$kashira_progress_fallback_target" Enter
}

enforce_kashira_progress_guards() {
  local tmp now task_id first_ts last_nudge_ts nudges source_file elapsed ts
  now="$(date +%s)"
  tmp="$(mktemp)"
  while IFS=$'\t' read -r task_id first_ts last_nudge_ts nudges source_file; do
    [[ -n "$task_id" ]] || continue
    if [[ -f "${outbox_dir}/${task_id}.md" ]]; then
      continue
    fi
    if has_kashira_progress_for_task "$task_id"; then
      continue
    fi

    elapsed=$((now - first_ts))
    if (( elapsed >= kashira_progress_timeout_sec )); then
      ts="$(date '+%Y-%m-%dT%H:%M:%S%z')"
      if (( nudges < kashira_progress_max_nudges )); then
        scripts/notify_agent.sh \
          --to oyabun \
          --from bridge \
          --event delegation_stall_nudge \
          --task "$task_id" \
          --message "No kashira progress for ${task_id} (${elapsed}s). Please delegate to kashira now." \
          --allow-degraded >/dev/null 2>&1 || true
        scripts/notify_agent.sh \
          --to kashira \
          --from bridge \
          --event delegation_stall_nudge \
          --task "$task_id" \
          --message "Bridge task ${task_id} has no progress yet. Start decomposition/worker dispatch now." \
          --allow-degraded >/dev/null 2>&1 || true
        printf '%s BRIDGE_NUDGE %s elapsed=%s\n' "$ts" "$task_id" "$elapsed" >> "$log_file"
        last_nudge_ts="$now"
        nudges=$((nudges + 1))
      elif to_bool "$kashira_progress_enable_fallback" && (( nudges == kashira_progress_max_nudges )); then
        if dispatch_kashira_fallback "$source_file" "$task_id"; then
          printf '%s BRIDGE_FALLBACK %s target=%s elapsed=%s\n' \
            "$ts" "$task_id" "$kashira_progress_fallback_target" "$elapsed" >> "$log_file"
          scripts/notify_agent.sh \
            --to oyabun \
            --from bridge \
            --event delegation_fallback_dispatched \
            --task "$task_id" \
            --message "Fallback dispatched to kashira for ${task_id} after stall (${elapsed}s)." \
            --inbox-only >/dev/null 2>&1 || true
          nudges=$((nudges + 1))
          last_nudge_ts="$now"
        fi
      fi
    fi

    printf '%s\t%s\t%s\t%s\t%s\n' "$task_id" "$first_ts" "$last_nudge_ts" "$nudges" "$source_file" >> "$tmp"
  done < "$kashira_progress_guard_file"
  mv "$tmp" "$kashira_progress_guard_file"
}

scan_outbox_replies() {
  local f task_id from to mtime prev ts
  shopt -s nullglob
  for f in "${outbox_dir}"/bridge_*.md; do
    [[ -f "$f" ]] || continue
    task_id="$(extract_field "$f" "task_id")"
    from="$(extract_field "$f" "from")"
    to="$(extract_field "$f" "to")"
    [[ -n "$task_id" ]] || continue

    # Track replies addressed to codex from peer systems.
    if [[ "$to" != "codex" ]]; then
      continue
    fi
    if [[ "$from" != "claude" && "$from" != "gemini" ]]; then
      continue
    fi

    mtime="$(stat -c %Y "$f" 2>/dev/null || true)"
    [[ -n "$mtime" ]] || continue
    prev="$(get_outbox_seen_mtime "$task_id")"
    if [[ -n "$prev" && "$mtime" -le "$prev" ]]; then
      continue
    fi

    ts="$(date '+%Y-%m-%dT%H:%M:%S%z')"
    printf '%s\t%s\t%s\t%s\t%s\n' "$ts" "$task_id" "$from" "$to" "$f" >> "$outbox_events_file"
    scripts/notify_agent.sh \
      --to oyabun \
      --from bridge \
      --event outbox_reply \
      --task "$task_id" \
      --message "Bridge reply detected: ${task_id} from ${from} (${f})" \
      --inbox-only >/dev/null 2>&1 || true
    scripts/notify_agent.sh \
      --to kashira \
      --from bridge \
      --event outbox_reply \
      --task "$task_id" \
      --message "Bridge reply detected: ${task_id} from ${from} (${f})" \
      --inbox-only >/dev/null 2>&1 || true
    printf '%s OUTBOX_REPLY %s from=%s path=%s\n' "$ts" "$task_id" "$from" "$f" >> "$log_file"
    set_outbox_seen_mtime "$task_id" "$mtime"
  done
}

enforce_delegation_guards() {
  local task_id min_workers source_file reason ts outbox_path
  while IFS=$'\t' read -r task_id min_workers source_file _; do
    [[ -n "$task_id" ]] || continue
    outbox_path="${outbox_dir}/${task_id}.md"
    [[ -f "$outbox_path" ]] || continue

    if scripts/bridge_done_guard.sh \
      --task-id "$task_id" \
      --bridge-root "$bridge_root" \
      --min-workers "$min_workers" \
      --source-file "$source_file" >/dev/null 2>&1; then
      clear_delegation_notified "$task_id"
      continue
    fi

    reason="$(scripts/bridge_done_guard.sh \
      --task-id "$task_id" \
      --bridge-root "$bridge_root" \
      --min-workers "$min_workers" \
      --source-file "$source_file" 2>&1 || true)"
    ts="$(date '+%Y-%m-%dT%H:%M:%S%z')"
    printf '%s\t%s\t%s\t%s\n' "$ts" "$task_id" "$min_workers" "$reason" >> "$delegation_violations_file"
    update_index_row "$task_id" "codex" "blocked" "outbox/${task_id}.md"

    if ! is_delegation_notified "$task_id"; then
      scripts/notify_agent.sh \
        --to kashira \
        --from guard \
        --event delegation_guard_failed \
        --task "$task_id" \
        --message "Bridge guard blocked ${task_id}: ${reason}" \
        --inbox-only >/dev/null 2>&1 || true
      mark_delegation_notified "$task_id"
    fi
  done < "$delegation_requirements_file"
}

mark_done_with_guard() {
  local task_id="$1"
  local source_file="$2"
  local min_workers="$3"
  local reason ts

  if scripts/bridge_done_guard.sh \
    --task-id "$task_id" \
    --bridge-root "$bridge_root" \
    --min-workers "$min_workers" \
    --source-file "$source_file" >/dev/null 2>&1; then
    update_index_row "$task_id" "codex" "done" "outbox/${task_id}.md"
    clear_delegation_notified "$task_id"
    return 0
  fi

  reason="$(scripts/bridge_done_guard.sh \
    --task-id "$task_id" \
    --bridge-root "$bridge_root" \
    --min-workers "$min_workers" \
    --source-file "$source_file" 2>&1 || true)"
  ts="$(date '+%Y-%m-%dT%H:%M:%S%z')"
  printf '%s\t%s\t%s\t%s\n' "$ts" "$task_id" "$min_workers" "$reason" >> "$delegation_violations_file"
  update_index_row "$task_id" "codex" "blocked" "outbox/${task_id}.md"
  scripts/notify_agent.sh \
    --to kashira \
    --from guard \
    --event done_guard_blocked \
    --task "$task_id" \
    --message "Done guard blocked ${task_id}: ${reason}" \
    --inbox-only >/dev/null 2>&1 || true
  mark_delegation_notified "$task_id"
  return 1
}

dispatch_auto_rally_to_worker() {
  local source_file="$1"
  local task_id="$2"
  local rally_id="$3"
  local next_hop="$4"
  local rally_max="$5"
  local origin_task_id="$6"
  local expires_at="$7"

  if ! command -v tmux >/dev/null 2>&1; then
    return 1
  fi
  if ! tmux has-session -t "${auto_rally_target%%:*}" 2>/dev/null; then
    return 1
  fi

  local status_field
  if (( next_hop >= rally_max * 2 )); then
    status_field="done"
  else
    status_field="in_progress"
  fi

  local msg
  msg="First run scripts/detect_persona.sh --expect oyabun. Then read ${source_file}. Mandatory chain: oyabun must delegate to kashira first, and kashira must dispatch workers before any final answer. Write substantive reply to ${outbox_dir}/${task_id}.md with exact headers task_id=${task_id}, from=codex, to=claude, status=${status_field}, auto_rally=true, rally_id=${rally_id}, hop_id=${next_hop}, rally_max=${rally_max}, origin_task_id=${origin_task_id}, expires_at=${expires_at}. If status=done, include explicit proof lines worker_count: N and worker_report_paths: with existing report files (minimum ${min_worker_reports}). Answer inbox content, no template-only ACK. Then update ${index_file} row ${task_id} to owner=codex status=${status_field} latest_file=outbox/${task_id}.md."

  # keep message and Enter as two independent tmux calls with sleep.
  tmux send-keys -t "$auto_rally_target" "$msg"
  sleep 0.5
  tmux send-keys -t "$auto_rally_target" Enter
}

dispatch_non_rally_to_worker() {
  local source_file="$1"
  local task_id="$2"

  if ! command -v tmux >/dev/null 2>&1; then
    return 1
  fi
  if ! tmux has-session -t "${non_rally_dispatch_target%%:*}" 2>/dev/null; then
    return 1
  fi

  local msg
  msg="First run scripts/detect_persona.sh --expect oyabun. Then read ${source_file}. Mandatory chain: oyabun must delegate to kashira first, and kashira must dispatch workers before final response. Write substantive reply to ${outbox_dir}/${task_id}.md with exact headers task_id=${task_id}, from=codex, to=claude, status=done. Use sections: 結論, 各問題点への見解, 改善計画(分類: instruction-change/code-change/poc + 見積), Claude側への支援依頼, 関連ファイル. Include explicit source attribution for borrowed ideas. Mandatory proof block: worker_count: N and worker_report_paths: list existing report files (minimum ${min_worker_reports}). Then update ${index_file} row ${task_id} to owner=codex status=done latest_file=outbox/${task_id}.md."

  tmux send-keys -t "$non_rally_dispatch_target" "$msg"
  sleep 0.5
  tmux send-keys -t "$non_rally_dispatch_target" Enter
}

build_auto_rally_reply() {
  local source_file="$1"
  local task_id="$2"
  local status="$3"
  local auto_rally="$4"
  local rally_id="$5"
  local hop_id="$6"
  local rally_max="$7"
  local origin_task_id="$8"
  local expires_at="$9"
  local conclusion="${10}"
  local detail="${11}"
  local objective
  objective="$(extract_section "$source_file" "目的" | sed '/^[[:space:]]*$/d' | head -n 3 || true)"
  {
    printf '# task_id: %s\n' "$task_id"
    echo "- from: codex"
    echo "- to: claude"
    printf -- "- status: %s\n" "$status"
    printf -- "- auto_rally: %s\n" "$auto_rally"
    printf -- "- rally_id: %s\n" "$rally_id"
    printf -- "- hop_id: %s\n" "$hop_id"
    printf -- "- rally_max: %s\n" "$rally_max"
    printf -- "- origin_task_id: %s\n" "$origin_task_id"
    [[ -n "$expires_at" ]] && printf -- "- expires_at: %s\n" "$expires_at"
    echo
    echo "## 結論"
    echo "$conclusion"
    echo
    echo "## 実施内容"
    echo "$detail"
    if [[ -n "$objective" ]]; then
      echo
      echo "## 受信タスク要約"
      echo "$objective"
    fi
    echo
    echo "## 関連ファイル"
    printf -- "- %s\n" "$source_file"
  } > "${outbox_dir}/${task_id}.md"
}

build_non_rally_reply() {
  local source_file="$1"
  local task_id="$2"
  local status="$3"
  local conclusion="$4"
  local detail="$5"
  local objective
  objective="$(extract_section "$source_file" "目的" | sed '/^[[:space:]]*$/d' | head -n 3 || true)"
  {
    printf '# task_id: %s\n' "$task_id"
    echo "- from: codex"
    echo "- to: claude"
    printf -- "- status: %s\n" "$status"
    echo "- auto_rally: false"
    echo
    echo "## 結論"
    echo "$conclusion"
    echo
    echo "## 実施内容"
    echo "$detail"
    if [[ -n "$objective" ]]; then
      echo
      echo "## 受信タスク要約"
      echo "$objective"
    fi
    echo
    echo "## 関連ファイル"
    printf -- "- %s\n" "$source_file"
  } > "${outbox_dir}/${task_id}.md"
}

handle_non_rally() {
  local f="$1"
  local task_id="$2"
  local ts
  local conclusion detail

  if dispatch_non_rally_to_worker "$f" "$task_id"; then
    ts="$(date '+%Y-%m-%dT%H:%M:%S%z')"
    printf '%s DISPATCH_NON_RALLY %s target=%s\n' "$ts" "$task_id" "$non_rally_dispatch_target" >> "$log_file"
    register_delegation_requirement "$task_id" "$min_worker_reports" "$f"
    register_kashira_progress_guard "$task_id" "$f"
    update_index_row "$task_id" "codex" "in_progress" "inbox/${task_id}.md"
  else
    # Dispatch failed — do NOT write ACK. Mark as blocked so agent can retry.
    ts="$(date '+%Y-%m-%dT%H:%M:%S%z')"
    printf '%s DISPATCH_FAILED %s %s target=%s\n' "$ts" "$task_id" "$f" "$non_rally_dispatch_target" >> "$log_file"
    update_index_row "$task_id" "codex" "blocked" "inbox/${task_id}.md"
  fi

  ts="$(date '+%Y-%m-%dT%H:%M:%S%z')"
  printf '%s|bridge|task_arrived|%s\n' "$ts" "$task_id" >> queue/inbox/kashira.queue
  scripts/notify_agent.sh \
    --to kashira \
    --from bridge \
    --event task_arrived \
    --task "$task_id" \
    --message "Bridge task arrived: ${task_id} (check ${f})" >/dev/null 2>&1 || true
  mark_seen "$task_id" "$f"
  printf '%s NEW %s %s\n' "$ts" "$task_id" "$f" >> "$log_file"
  return 0
}

handle_auto_rally() {
  local f="$1"
  local task_id="$2"
  local from="$3"
  local to="$4"
  local auto_rally rally_id hop_id rally_max origin_task_id expires_at
  local limit active next_hop
  auto_rally="$(extract_field "$f" "auto_rally")"
  rally_id="$(extract_field "$f" "rally_id")"
  hop_id="$(extract_field "$f" "hop_id")"
  rally_max="$(extract_field "$f" "rally_max")"
  origin_task_id="$(extract_field "$f" "origin_task_id")"
  expires_at="$(extract_field "$f" "expires_at")"

  if ! to_bool "$auto_rally"; then
    return 1
  fi

  if [[ -z "$rally_id" || -z "$hop_id" || -z "$rally_max" || -z "$origin_task_id" ]]; then
    build_auto_rally_reply \
      "$f" "$task_id" "blocked" "false" "${rally_id:-unknown}" "${hop_id:-0}" "${rally_max:-5}" "${origin_task_id:-$task_id}" "$expires_at" \
      "Auto-Rally必須フィールド不足のため停止" \
      "rally_id/hop_id/rally_max/origin_task_id が不足。manual modeへフォールバックが必要。"
    update_index_row "$task_id" "codex" "blocked" "outbox/${task_id}.md"
    mark_seen "$task_id" "$f"
    return 0
  fi

  if ! is_integer "$hop_id" || ! is_integer "$rally_max"; then
    build_auto_rally_reply \
      "$f" "$task_id" "blocked" "false" "$rally_id" "${hop_id:-0}" "${rally_max:-5}" "$origin_task_id" "$expires_at" \
      "Auto-Rallyフィールド形式エラーで停止" \
      "hop_id/rally_max は整数が必要。入力値を修正して再送。"
    update_index_row "$task_id" "codex" "blocked" "outbox/${task_id}.md"
    mark_seen "$task_id" "$f"
    return 0
  fi

  if is_hop_processed "$rally_id" "$hop_id" "$from" "$to"; then
    mark_seen "$task_id" "$f"
    return 0
  fi

  active="$(get_active_rally)"
  if [[ -n "$active" && "$active" != "$rally_id" ]]; then
    build_auto_rally_reply \
      "$f" "$task_id" "blocked" "false" "$rally_id" "$hop_id" "$rally_max" "$origin_task_id" "$expires_at" \
      "別ラリーが稼働中のため受付拒否" \
      "single-session制約により、現行ラリー完了後に再実行が必要。"
    update_index_row "$task_id" "codex" "blocked" "outbox/${task_id}.md"
    mark_hop_processed "$rally_id" "$hop_id" "$from" "$to"
    mark_seen "$task_id" "$f"
    return 0
  fi
  set_active_rally "$rally_id" "$task_id"

  limit=$((rally_max * 2))
  if is_expired "$expires_at"; then
    build_auto_rally_reply \
      "$f" "$task_id" "done" "false" "$rally_id" "$hop_id" "$rally_max" "$origin_task_id" "$expires_at" \
      "expires_at到達のため自動ラリー停止" \
      "期限到達を検出。必要なら新しいrally_idで再開。"
    mark_done_with_guard "$task_id" "$f" "$min_worker_reports" || true
    clear_active_rally_if_match "$rally_id"
    mark_hop_processed "$rally_id" "$hop_id" "$from" "$to"
    mark_seen "$task_id" "$f"
    return 0
  fi

  if (( hop_id >= limit )); then
    build_auto_rally_reply \
      "$f" "$task_id" "done" "false" "$rally_id" "$hop_id" "$rally_max" "$origin_task_id" "$expires_at" \
      "hop上限到達のため自動ラリー停止" \
      "hop_id >= rally_max*2 を検出。必要なら新しいrally_idで継続。"
    mark_done_with_guard "$task_id" "$f" "$min_worker_reports" || true
    clear_active_rally_if_match "$rally_id"
    mark_hop_processed "$rally_id" "$hop_id" "$from" "$to"
    mark_seen "$task_id" "$f"
    return 0
  fi

  next_hop=$((hop_id + 1))
  if dispatch_auto_rally_to_worker "$f" "$task_id" "$rally_id" "$next_hop" "$rally_max" "$origin_task_id" "$expires_at"; then
    local ts
    ts="$(date '+%Y-%m-%dT%H:%M:%S%z')"
    printf '%s DISPATCH %s target=%s next_hop=%s\n' "$ts" "$task_id" "$auto_rally_target" "$next_hop" >> "$log_file"
    register_delegation_requirement "$task_id" "$min_worker_reports" "$f"
    update_index_row "$task_id" "codex" "in_progress" "inbox/${task_id}.md"
    mark_hop_processed "$rally_id" "$hop_id" "$from" "$to"
    mark_seen "$task_id" "$f"
    return 0
  fi

  build_auto_rally_reply \
    "$f" "$task_id" "blocked" "false" "$rally_id" "$hop_id" "$rally_max" "$origin_task_id" "$expires_at" \
    "Auto-Rallyの自動実行に失敗" \
    "tmuxワーカーディスパッチ失敗（target=${auto_rally_target}）。ワーカー起動状態とセッション名を確認して再送が必要。"
  update_index_row "$task_id" "codex" "blocked" "outbox/${task_id}.md"
  clear_active_rally_if_match "$rally_id"
  mark_hop_processed "$rally_id" "$hop_id" "$from" "$to"
  mark_seen "$task_id" "$f"
  return 0
}

refresh_pending_snapshot() {
  {
    echo "# Bridge Pending Tasks"
    echo "updated: $(date '+%Y-%m-%dT%H:%M:%S%z')"
    echo
    echo "| task_id | from | to | status | file |"
    echo "|---|---|---|---|---|"
  } > "$pending_snapshot"

  local f task_id from_raw to_raw status_raw from to status
  shopt -s nullglob
  for f in "${inbox_dir}"/bridge_*.md; do
    task_id="$(extract_field "$f" "task_id")"
    from_raw="$(extract_field "$f" "from")"
    to_raw="$(extract_field "$f" "to")"
    status_raw="$(extract_field "$f" "status")"
    from="$(normalize_actor "$from_raw")"
    to="$(normalize_actor "$to_raw")"
    status="$(infer_status "$status_raw" "$from" "$to")"
    [[ -n "$task_id" ]] || continue
    if [[ "$from" == "claude" && "$to" == "codex" && "$status" == "todo" ]] && ! is_done_by_outbox "$task_id"; then
      printf '| %s | %s | %s | %s | %s |\n' "$task_id" "$from" "$to" "$status" "$f" >> "$pending_snapshot"
    fi
  done
}

process_once() {
  local f task_id from_raw to_raw status_raw from to status ts
  local auto_rally approval_required approval_reason approval_status
  local new_count=0
  local file_count
  file_count="$(count_inbox_files "$bridge_root")"
  printf '%s SCAN inbox_dir=%s files=%s bridge_root=%s\n' \
    "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$inbox_dir" "$file_count" "$bridge_root" >> "$log_file"
  shopt -s nullglob
  for f in "${inbox_dir}"/bridge_*.md; do
    task_id="$(extract_field "$f" "task_id")"
    from_raw="$(extract_field "$f" "from")"
    to_raw="$(extract_field "$f" "to")"
    status_raw="$(extract_field "$f" "status")"
    from="$(normalize_actor "$from_raw")"
    to="$(normalize_actor "$to_raw")"
    status="$(infer_status "$status_raw" "$from" "$to")"
    auto_rally="$(extract_field "$f" "auto_rally")"
    approval_required="$(extract_field "$f" "approval_required")"
    approval_reason="$(extract_field "$f" "approval_reason")"
    [[ -n "$task_id" ]] || continue
    [[ "$from" == "claude" && "$to" == "codex" && "$status" == "todo" ]] || continue
    if is_done_by_outbox "$task_id"; then
      mark_seen "$task_id" "$f"
      continue
    fi
    if is_seen "$task_id"; then
      continue
    fi

    if to_bool "$approval_required"; then
      approval_status="$(approval_status_for_task "$task_id")"
      case "$approval_status" in
        approved)
          # proceed
          ;;
        rejected)
          update_index_row "$task_id" "codex" "blocked" "inbox/${task_id}.md"
          mark_seen "$task_id" "$f"
          ts="$(date '+%Y-%m-%dT%H:%M:%S%z')"
          printf '%s APPROVAL_REJECTED %s %s\n' "$ts" "$task_id" "$f" >> "$log_file"
          continue
          ;;
        pending)
          update_index_row "$task_id" "codex" "blocked" "inbox/${task_id}.md"
          continue
          ;;
        none)
          scripts/request_approval.sh \
            --task-id "$task_id" \
            --source bridge \
            --requested-by oyabun \
            --risk-level high \
            --reason "${approval_reason:-Bridge task marked approval_required=true}" \
            --action "Review and approve before bridge dispatch" >/dev/null 2>&1 || true
          ts="$(date '+%Y-%m-%dT%H:%M:%S%z')"
          printf '%s APPROVAL_REQUESTED %s %s\n' "$ts" "$task_id" "$f" >> "$log_file"
          update_index_row "$task_id" "codex" "blocked" "inbox/${task_id}.md"
          scripts/notify_agent.sh \
            --to kashira \
            --from bridge \
            --event approval_required \
            --task "$task_id" \
            --message "Approval required for ${task_id}. Check queue/approval_required.yaml." \
            --inbox-only >/dev/null 2>&1 || true
          continue
          ;;
      esac
    fi

    if to_bool "$auto_rally"; then
      if handle_auto_rally "$f" "$task_id" "$from" "$to"; then
        ts="$(date '+%Y-%m-%dT%H:%M:%S%z')"
        printf '%s AUTO_RALLY %s %s\n' "$ts" "$task_id" "$f" >> "$log_file"
        printf '%s|bridge|auto_rally_processed|%s\n' "$ts" "$task_id" >> queue/inbox/kashira.queue
        scripts/notify_agent.sh \
          --to kashira \
          --from bridge \
          --event auto_rally_processed \
          --task "$task_id" \
          --message "Bridge auto-rally processed: ${task_id} (check ${f})" \
          --inbox-only >/dev/null 2>&1 || true
      fi
    else
      handle_non_rally "$f" "$task_id" || true
    fi
    new_count=$((new_count + 1))
  done
  scan_outbox_replies
  enforce_delegation_guards
  enforce_kashira_progress_guards
  refresh_pending_snapshot
  echo "bridge_reader_once_done|new=${new_count}|snapshot=${pending_snapshot}"
}

if [[ "$mode" == "once" ]]; then
  process_once
  exit 0
fi

# Polling only: more reliable on /mnt/c (WSL <-> Windows filesystem events can be missed).
while true; do
  process_once
  sleep "$interval"
done
