#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage:
  scripts/auto_recover_if_unhealthy.sh [--workers worker1,worker2,worker3,worker4] [--recover-on warn|critical]

Behavior:
  1) Run system health check
  2) If health level matches threshold, run stale_task_watchdog once
  3) Re-run health check and print before/after
USAGE
}

workers_csv="worker1,worker2,worker3,worker4"
recover_on="critical"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workers) workers_csv="${2:-}"; shift 2 ;;
    --recover-on) recover_on="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$recover_on" in
  warn|critical) ;;
  *)
    echo "--recover-on must be warn or critical" >&2
    exit 2
    ;;
esac

mkdir -p status

bridge_start_out="$(scripts/start_bridge_auto_reader.sh 2>&1 || true)"
if ! printf '%s' "$bridge_start_out" | rg -q 'bridge_reader_supervisor_(started|already_running)'; then
  ts="$(date '+%Y-%m-%dT%H:%M:%S%z')"
  printf '%s|watchdog|bridge_reader_start_failed|detail=%s\n' "$ts" "$bridge_start_out" >> queue/inbox/kashira.queue
  scripts/notify_agent.sh \
    --to kashira \
    --from watchdog \
    --event bridge_reader_start_failed \
    --task bridge_watcher \
    --message "Bridge watcherの自己復旧に失敗。手動確認が必要。" \
    --inbox-only >/dev/null 2>&1 || true
fi

scripts/system_health_check.sh --workers "$workers_csv" >/dev/null || true
before="$(awk -F'"' '/^health:/ {print $2; exit}' status/system_health.yaml 2>/dev/null || echo unknown)"

should_recover=0
if [[ "$recover_on" == "warn" ]]; then
  [[ "$before" == "warn" || "$before" == "critical" ]] && should_recover=1
else
  [[ "$before" == "critical" ]] && should_recover=1
fi

if [[ $should_recover -eq 0 ]]; then
  echo "auto_recover_skip|health_before=${before}|threshold=${recover_on}"
  exit 0
fi

watchdog_out="$(scripts/stale_task_watchdog.sh --workers "$workers_csv" || true)"
scripts/system_health_check.sh --workers "$workers_csv" >/dev/null || true
after="$(awk -F'"' '/^health:/ {print $2; exit}' status/system_health.yaml 2>/dev/null || echo unknown)"

echo "auto_recover_done|health_before=${before}|health_after=${after}|threshold=${recover_on}|watchdog=${watchdog_out}"
