#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage:
  scripts/stale_task_watchdog.sh [--workers worker1,worker2,worker3,worker4] [--default-timeout 30] [--reassign-ack-timeout-sec 300] [--max-hops 2] [--guidance-wait-min 1] [--guidance-nudge-cooldown-sec 120]

Behavior:
  - One-shot check only (no loop, no polling daemon).
  - Timeout by effort:
      low/small=10m, medium=30m, high/large=60m
  - Recovery stages:
      stage1: notify stalled worker
      stage2: reassign to fallback worker (with ack timeout / multi-hop)
      stage3: escalate to oyabun
USAGE
}

workers_csv="worker1,worker2,worker3,worker4"
default_timeout=30
reassign_ack_timeout_sec=300
max_hops=2
state_file="status/recovery_state.tsv"
guidance_wait_min=1
guidance_nudge_cooldown_sec=120
guidance_state_file="status/guidance_nudge_state.tsv"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workers) workers_csv="${2:-}"; shift 2 ;;
    --default-timeout) default_timeout="${2:-}"; shift 2 ;;
    --reassign-ack-timeout-sec) reassign_ack_timeout_sec="${2:-}"; shift 2 ;;
    --max-hops) max_hops="${2:-}"; shift 2 ;;
    --guidance-wait-min) guidance_wait_min="${2:-}"; shift 2 ;;
    --guidance-nudge-cooldown-sec) guidance_nudge_cooldown_sec="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

mkdir -p status queue/inbox
touch "$state_file"
touch "$guidance_state_file"

yaml_value() {
  local file="$1"
  local key="$2"
  awk -F': ' -v k="$key" '
    $1 ~ "^[[:space:]]*" k "$" {
      v=$2
      sub(/^[[:space:]]+/, "", v)
      gsub(/^"/, "", v)
      gsub(/"$/, "", v)
      print v
      exit
    }
  ' "$file" 2>/dev/null || true
}

task_timestamp_epoch() {
  local ts="$1"
  date -d "$ts" +%s 2>/dev/null || true
}

task_timeout_minutes() {
  local effort="${1,,}"
  case "$effort" in
    low|small) echo 10 ;;
    medium) echo 30 ;;
    high|large) echo 60 ;;
    *) echo "$default_timeout" ;;
  esac
}

report_exists_for_task() {
  local worker="$1"
  local task_id="$2"
  [[ -n "$task_id" ]] || return 1
  [[ -f "queue/reports/${worker}_${task_id}_report.yaml" ]] && return 0
  compgen -G "queue/reports/${worker}_${task_id}_*_report.yaml" >/dev/null
}

state_get() {
  local worker="$1"
  local task_id="$2"
  awk -F'\t' -v w="$worker" -v t="$task_id" '
    $1==w && $2==t {
      print $0
      found=1
      exit
    }
    END {
      if (!found) print w "\t" t "\t0\t\t\t0\t\t"
    }
  ' "$state_file"
}

state_upsert() {
  local worker="$1"
  local task_id="$2"
  local stage="$3"
  local note="$4"
  local hop_count="$5"
  local target_worker="$6"
  local target_task="$7"
  local reassign_ts="$8"
  awk -F'\t' -v OFS='\t' \
    -v w="$worker" -v t="$task_id" -v s="$stage" -v n="$note" -v h="$hop_count" -v tw="$target_worker" -v tt="$target_task" -v rt="$reassign_ts" '
    BEGIN { updated=0 }
    $1==w && $2==t {
      print w, t, s, n, h, tw, tt, rt
      updated=1
      next
    }
    { print $0 }
    END {
      if (!updated) print w, t, s, n, h, tw, tt, rt
    }
  ' "$state_file" > "${state_file}.tmp"
  mv "${state_file}.tmp" "$state_file"
}

state_remove() {
  local worker="$1"
  local task_id="$2"
  awk -F'\t' -v OFS='\t' -v w="$worker" -v t="$task_id" '
    !($1==w && $2==t) { print $0 }
  ' "$state_file" > "${state_file}.tmp"
  mv "${state_file}.tmp" "$state_file"
}

next_worker() {
  local w="$1"
  case "$w" in
    worker1) echo worker2 ;;
    worker2) echo worker3 ;;
    worker3) echo worker4 ;;
    worker4) echo worker1 ;;
    *) echo worker1 ;;
  esac
}

worker_pane() {
  local worker="$1"
  case "$worker" in
    worker1) echo "nekocodex:1.0" ;;
    worker2) echo "nekocodex:2.0" ;;
    worker3) echo "nekocodex:3.0" ;;
    worker4) echo "nekocodex:4.0" ;;
    *) echo "" ;;
  esac
}

worker_is_waiting_guidance() {
  local worker="$1"
  local pane
  pane="$(worker_pane "$worker")"
  [[ -n "$pane" ]] || return 1
  command -v tmux >/dev/null 2>&1 || return 1
  local title
  title="$(tmux display-message -p -t "$pane" '#{pane_title}' 2>/dev/null || true)"
  title="${title,,}"
  [[ "$title" == *"awaiting guidance"* || "$title" == *"ready"* ]]
}

guidance_state_get() {
  local worker="$1"
  local task_id="$2"
  awk -F'\t' -v w="$worker" -v t="$task_id" '
    $1==w && $2==t {
      print $3 "\t" $4
      found=1
      exit
    }
    END {
      if (!found) print "0\t0"
    }
  ' "$guidance_state_file"
}

guidance_state_upsert() {
  local worker="$1"
  local task_id="$2"
  local last_nudge_epoch="$3"
  local nudge_count="$4"
  awk -F'\t' -v OFS='\t' \
    -v w="$worker" -v t="$task_id" -v l="$last_nudge_epoch" -v c="$nudge_count" '
    BEGIN { updated=0 }
    $1==w && $2==t {
      print w, t, l, c
      updated=1
      next
    }
    { print $0 }
    END {
      if (!updated) print w, t, l, c
    }
  ' "$guidance_state_file" > "${guidance_state_file}.tmp"
  mv "${guidance_state_file}.tmp" "$guidance_state_file"
}

guidance_state_remove() {
  local worker="$1"
  local task_id="$2"
  awk -F'\t' -v OFS='\t' -v w="$worker" -v t="$task_id" '
    !($1==w && $2==t) { print $0 }
  ' "$guidance_state_file" > "${guidance_state_file}.tmp"
  mv "${guidance_state_file}.tmp" "$guidance_state_file"
}

notify_retry_exhausted() {
  local worker="$1"
  local task_id="$2"
  local age_minutes="$3"
  local ts_now="$4"
  if scripts/notify_agent.sh \
    --to oyabun \
    --from watchdog \
    --event retry_exhausted \
    --task "$task_id" \
    --message "retry_exhausted|worker=${worker}|task=${task_id}|age_min=${age_minutes}" \
    --strict-tmux; then
    printf '%s|watchdog|escalated|worker=%s|task=%s|age=%sm\n' \
      "$ts_now" "$worker" "$task_id" "$age_minutes" >> queue/inbox/kashira.queue
    return 0
  fi
  printf '%s|watchdog|notify_failed|to=oyabun|task=%s|stage=3\n' \
    "$ts_now" "$task_id" >> queue/inbox/kashira.queue
  return 1
}

ts_now="$(date '+%Y-%m-%dT%H:%M:%S%z')"
now_epoch="$(date +%s)"
actions=0
stales=0

IFS=',' read -r -a workers <<< "$workers_csv"
for w in "${workers[@]}"; do
  task_file="queue/tasks/${w}.yaml"
  [[ -f "$task_file" ]] || continue

  task_id="$(yaml_value "$task_file" task_id)"
  task_status="$(yaml_value "$task_file" status)"
  task_ts="$(yaml_value "$task_file" timestamp)"
  effort="$(yaml_value "$task_file" estimated_effort)"
  parent_cmd="$(yaml_value "$task_file" parent_cmd)"
  mode="$(yaml_value "$task_file" mode)"
  desc="$(yaml_value "$task_file" description)"
  heads_up="$(yaml_value "$task_file" heads_up)"

  [[ -n "$task_id" && -n "$task_ts" ]] || continue
  [[ "$task_status" == "assigned" || "$task_status" == "in_progress" ]] || continue

  IFS=$'\t' read -r _ _ stage note hop_count target_worker target_task reassign_ts < <(state_get "$w" "$task_id")
  stage="${stage:-0}"
  hop_count="${hop_count:-0}"

  if report_exists_for_task "$w" "$task_id"; then
    state_remove "$w" "$task_id"
    guidance_state_remove "$w" "$task_id"
    continue
  fi
  if [[ -n "$target_worker" && -n "$target_task" ]] && report_exists_for_task "$target_worker" "$target_task"; then
    state_remove "$w" "$task_id"
    guidance_state_remove "$w" "$task_id"
    continue
  fi

  task_epoch="$(task_timestamp_epoch "$task_ts")"
  [[ -n "$task_epoch" ]] || continue
  age_minutes=$(( (now_epoch - task_epoch) / 60 ))
  timeout_minutes="$(task_timeout_minutes "$effort")"

  if (( age_minutes >= guidance_wait_min )) && worker_is_waiting_guidance "$w"; then
    IFS=$'\t' read -r last_nudge_epoch nudge_count < <(guidance_state_get "$w" "$task_id")
    last_nudge_epoch="${last_nudge_epoch:-0}"
    nudge_count="${nudge_count:-0}"
    if ! [[ "$last_nudge_epoch" =~ ^[0-9]+$ ]]; then
      last_nudge_epoch=0
    fi
    if ! [[ "$nudge_count" =~ ^[0-9]+$ ]]; then
      nudge_count=0
    fi
    since_last_nudge=$((now_epoch - last_nudge_epoch))
    if (( since_last_nudge >= guidance_nudge_cooldown_sec )); then
      if scripts/notify_agent.sh \
        --to "$w" \
        --from watchdog \
        --event guidance_nudge \
        --task "$task_id" \
        --message "awaiting_guidance検知: task=${task_id} は担当中です。queue/tasks/${w}.yaml を開いて即時継続してください。" \
        --strict-tmux; then
        next_count=$((nudge_count + 1))
        guidance_state_upsert "$w" "$task_id" "$now_epoch" "$next_count"
        printf '%s|watchdog|guidance_nudge|worker=%s|task=%s|age=%sm|count=%s\n' \
          "$ts_now" "$w" "$task_id" "$age_minutes" "$next_count" >> queue/inbox/kashira.queue
      else
        printf '%s|watchdog|notify_failed|to=%s|task=%s|event=guidance_nudge\n' \
          "$ts_now" "$w" "$task_id" >> queue/inbox/kashira.queue
      fi
    fi
  fi

  if (( age_minutes < timeout_minutes )) && [[ "$stage" -lt 2 ]]; then
    continue
  fi

  stales=$((stales + 1))

  if [[ "$stage" -lt 1 ]]; then
    printf '%s|watchdog|stale_detected|%s|%s|age=%sm|timeout=%sm\n' \
      "$ts_now" "$w" "$task_id" "$age_minutes" "$timeout_minutes" >> queue/inbox/kashira.queue
    if scripts/notify_agent.sh \
      --to "$w" \
      --from watchdog \
      --event stale_task \
      --task "$task_id" \
      --message "Stale task detected (${task_id}, ${age_minutes}m >= ${timeout_minutes}m). Execute now: queue/tasks/${w}.yaml" \
      --strict-tmux; then
      state_upsert "$w" "$task_id" 1 "renotify" "$hop_count" "" "" ""
      actions=$((actions + 1))
    else
      printf '%s|watchdog|notify_failed|to=%s|task=%s|stage=1\n' \
        "$ts_now" "$w" "$task_id" >> queue/inbox/kashira.queue
    fi
    continue
  fi

  if [[ "$stage" -lt 2 ]]; then
    fallback="$(next_worker "$w")"
    new_hops=$((hop_count + 1))
    new_task_id="${task_id}_reassign_${w}_hop${new_hops}"
    new_desc="Recovery reassignment from ${w}: ${desc}"
    scripts/assign_task.sh \
      --worker "$fallback" \
      --task-id "$new_task_id" \
      --parent-cmd "${parent_cmd:-$task_id}" \
      --description "$new_desc" \
      --mode "${mode:-normal}" \
      --effort "${effort:-medium}" \
      --heads-up "${heads_up:-false}" >/dev/null
    if scripts/notify_agent.sh \
      --to "$fallback" \
      --from watchdog \
      --event reassigned \
      --task "$new_task_id" \
      --message "Recovery reassigned task from ${w}. Read queue/tasks/${fallback}.yaml and execute ${new_task_id}." \
      --strict-tmux; then
      printf '%s|watchdog|reassigned|from=%s|to=%s|task=%s|new_task=%s|hop=%s\n' \
        "$ts_now" "$w" "$fallback" "$task_id" "$new_task_id" "$new_hops" >> queue/inbox/kashira.queue
      state_upsert "$w" "$task_id" 2 "reassigned_to_${fallback}" "$new_hops" "$fallback" "$new_task_id" "$now_epoch"
      actions=$((actions + 1))
    else
      printf '%s|watchdog|notify_failed|to=%s|task=%s|stage=2|reassigned=%s\n' \
        "$ts_now" "$fallback" "$task_id" "$new_task_id" >> queue/inbox/kashira.queue
    fi
    continue
  fi

  if [[ "$stage" -eq 2 ]]; then
    reassign_epoch="${reassign_ts:-0}"
    if ! [[ "$reassign_epoch" =~ ^[0-9]+$ ]]; then
      reassign_epoch="$now_epoch"
    fi
    waited=$((now_epoch - reassign_epoch))
    if (( waited < reassign_ack_timeout_sec )); then
      continue
    fi

    if (( hop_count < max_hops )); then
      next="${target_worker:-$(next_worker "$w")}"
      next="$(next_worker "$next")"
      next_hops=$((hop_count + 1))
      next_task_id="${task_id}_reassign_${w}_hop${next_hops}"
      scripts/assign_task.sh \
        --worker "$next" \
        --task-id "$next_task_id" \
        --parent-cmd "${parent_cmd:-$task_id}" \
        --description "Recovery reassignment hop ${next_hops} from ${w}: ${desc}" \
        --mode "${mode:-normal}" \
        --effort "${effort:-medium}" \
        --heads-up "${heads_up:-false}" >/dev/null
      if scripts/notify_agent.sh \
        --to "$next" \
        --from watchdog \
        --event reassigned \
        --task "$next_task_id" \
        --message "reassign_ack_timeout triggered. Execute ${next_task_id} from queue/tasks/${next}.yaml." \
        --strict-tmux; then
        printf '%s|watchdog|reassign_ack_timeout|from=%s|to=%s|task=%s|new_task=%s|hop=%s\n' \
          "$ts_now" "$w" "$next" "$task_id" "$next_task_id" "$next_hops" >> queue/inbox/kashira.queue
        state_upsert "$w" "$task_id" 2 "reassign_ack_timeout_to_${next}" "$next_hops" "$next" "$next_task_id" "$now_epoch"
        actions=$((actions + 1))
      else
        printf '%s|watchdog|notify_failed|to=%s|task=%s|stage=2|reassigned=%s\n' \
          "$ts_now" "$next" "$task_id" "$next_task_id" >> queue/inbox/kashira.queue
      fi
      continue
    fi

    if notify_retry_exhausted "$w" "$task_id" "$age_minutes" "$ts_now"; then
      state_upsert "$w" "$task_id" 3 "escalated_to_oyabun_max_hops" "$hop_count" "$target_worker" "$target_task" "$reassign_ts"
      actions=$((actions + 1))
    fi
    continue
  fi

  if [[ "$stage" -lt 3 ]]; then
    if notify_retry_exhausted "$w" "$task_id" "$age_minutes" "$ts_now"; then
      state_upsert "$w" "$task_id" 3 "escalated_to_oyabun" "$hop_count" "$target_worker" "$target_task" "$reassign_ts"
      actions=$((actions + 1))
    fi
  fi
done

scripts/update_agent_status.sh >/dev/null 2>&1 || true
echo "watchdog_done|stale=${stales}|actions=${actions}|state_file=${state_file}|guidance_state_file=${guidance_state_file}|reassign_ack_timeout_sec=${reassign_ack_timeout_sec}|guidance_wait_min=${guidance_wait_min}|guidance_nudge_cooldown_sec=${guidance_nudge_cooldown_sec}|max_hops=${max_hops}"
