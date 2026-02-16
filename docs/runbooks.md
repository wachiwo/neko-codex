# Runbooks

## Responsibility Map

- `worker`: own task file + own inbox + own report evidence
- `kashira`: queue/reports/status/approval/guard monitoring and dispatch decisions
- `oyabun`: exception approval, high-risk decisions, final policy oversight

## Daily Quick Checks (kashira)

```bash
cd /mnt/c/tools/neko-codex
scripts/check_system.sh
```

## Review Dispatch (fixed template)

```bash
cd /mnt/c/tools/neko-codex
scripts/dispatch_review_task.sh \
  --task-id cmd_XXX \
  --parent-cmd cmd_XXX \
  --workers worker1,worker2,worker3,worker4 \
  --description-file scripts/descriptions/review_template.txt \
  --review-ext md \
  --effort medium
```

## Approval Lane

Request:

```bash
cd /mnt/c/tools/neko-codex
scripts/request_approval.sh --task-id bridge_XXX --reason "High-risk operation"
```

Resolve:

```bash
cd /mnt/c/tools/neko-codex
scripts/resolve_approval.sh --task-id bridge_XXX --decision approved
```

## If Blocked by Guard

1. Confirm missing evidence:

```bash
cd /mnt/c/tools/neko-codex
scripts/bridge_done_guard.sh --task-id bridge_XXX --bridge-root /mnt/c/tools/bridge --min-workers 4
```

2. Re-dispatch missing worker reports.
3. Regenerate outbox with `worker_count` + `worker_report_paths`.

## Handshake Guard (new)

Dispatch now supports handshake enforcement (`task_ack` + `first_action`) before normal follow-up.

```bash
cd /mnt/c/tools/neko-codex
scripts/dispatch_and_followup.sh \
  --workers worker1,worker2,worker3,worker4 \
  --task-id cmd_XXX \
  --parent-cmd cmd_XXX \
  --description "..." \
  --require-handshake true \
  --ack-timeout-sec 180 \
  --first-action-timeout-sec 300
```

Compatibility mode (temporary):

```bash
scripts/dispatch_and_followup.sh ... --compat-mode
```

## Fast Bridge Finalize (format automation)

Use this when worker reports are already collected and you want to auto-generate
the bridge outbox skeleton, proof block, guard check, and index update.

```bash
cd /mnt/c/tools/neko-codex
scripts/bridge_finalize.sh \
  --task-id bridge_XXX \
  --report-cmd-id cmd_YYY
```

Notes:
- This script automates non-critical formatting and evidence wiring.
- It still expects you to replace scaffold bullets with substantive content.
- Use `--force` only when you intentionally overwrite an existing outbox file.

## Discussion Index (auto generated)

Generate a single view of discussion threads, active worker debate tasks, and recent debate reports:

```bash
cd /mnt/c/tools/neko-codex
scripts/update_discussion_index.sh --output docs/discussion_index.md
```

## Skill Auto-Generation Pipeline

1) Collect candidates from worker reports and auto-update dashboard:

```bash
cd /mnt/c/tools/neko-codex
scripts/skill_collect_candidates.sh
```

2) Evaluate with 20-point rubric and emit design docs for score >= 12:

```bash
cd /mnt/c/tools/neko-codex
scripts/skill_evaluate_candidates.sh
```

3) Approval and generation:
- Edit `queue/skill_approvals.yaml` and set:
  - `decision: approved`
  - `cross_review: passed`
  - `trigger_quality: passed`

```bash
cd /mnt/c/tools/neko-codex
scripts/skill_generate_from_approvals.sh
```

Notes:
- Target path default: `~/.codex/skills/`
- Duplicate skills are blocked before generation.
- One candidate per `task_id`.

## Oyabun Discussion Backlog

Keep a running list of next brainstorm topics in:
- `logs/oyabun_session.md` (section: `議論したいやつ一覧（次回ブレスト候補）`)

Add one topic row quickly:

```bash
cd /mnt/c/tools/neko-codex
scripts/add_discussion_topic.sh \
  --id D4 \
  --theme "テーマ" \
  --background "背景"
```

## If Persona Mismatch

```bash
cd /mnt/c/tools/neko-codex
scripts/detect_persona.sh --format kv
```

If expected role differs, stop and restart agent in correct tmux window.

## If Watcher Down

```bash
cd /mnt/c/tools/neko-codex
scripts/start_bridge_auto_reader.sh
scripts/health_snapshot.sh
```

Confirm in `status/health_snapshot.yaml`:
- `watcher_alive: "yes"`
- `supervisor_alive: "yes"`

## Mandatory: Snapshot Before Any Restart

Before restarting workers/sessions/watchers, always capture tmux scrollback first:

```bash
cd /mnt/c/tools/neko-codex
scripts/snapshot_tmux_buffers.sh --lines 4000
```

Outputs:
- `logs/tmux_snapshots/<timestamp>/SUMMARY.md`
- one log file per pane

Rule:
- If snapshot fails, do not restart immediately.
- Escalate to oyabun with failure reason and retry once.

## Bridge Reply Confirmation (Mandatory)

After sending a bridge inbox task, do not declare "no reply" immediately.

### Step 1: Wait

- Wait at least 30-60 seconds before first judgment.

### Step 2: 3-point check (all required)

1. outbox file existence
2. index row status
3. watcher log evidence

Example:

```bash
ls -la /mnt/c/tools/bridge/outbox/bridge_XXX.md
grep -n 'bridge_XXX' /mnt/c/tools/bridge/index.md
tail -n 120 /mnt/c/tools/neko-multi-agent/logs/bridge_watcher.log | grep 'bridge_XXX'
```

### Step 3: Fixed report format

Always report in this order:
1. `outbox`: exists / missing
2. `index`: todo / in_progress / done / blocked
3. `log evidence`: one concrete line
4. `judgment`: no-reply / in-progress / completed
