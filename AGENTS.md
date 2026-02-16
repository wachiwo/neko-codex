# neko-codex System Configuration

> **Version**: 1.0.0 (Codex Port)
> **Based on**: neko-multi-agent v2.1.0 (Claude Code)

## Overview
neko-codex is a multi-agent parallel development platform using OpenAI Codex CLI + tmux.
Ported from the Claude Code-based neko-multi-agent system.
Hierarchical cat team structure for managing multiple projects in parallel.

## Post-Compaction Recovery (Mandatory)

After context reset, always:

1. Check your pane: `tmux display-message -p '#W'`
2. Read the corresponding instructions in `instructions/`
3. Confirm forbidden actions before starting

## Hierarchy

```
Master (Human)
  │
  ▼
┌──────────────┐
│   OYABUN     │ ← Boss cat (project oversight)
└──────┬───────┘
       │ via YAML files
       ▼
┌──────────────┐
│   KASHIRA    │ ← Head cat (task management)
└──────┬───────┘
       │ via YAML files
       ▼
┌──────┬──────┬──────┬──────┐
│  W1  │  W2  │  W3  │  W4  │ ← Workers
└──────┴──────┴──────┴──────┘
```

### Pane Mapping

| Pane | ID | Instruction |
|------|-----|------------|
| nekocodex:0.0 | kashira | instructions/kashira.md |
| nekocodex:0.1 | worker1 | instructions/1gou-neko.md |
| nekocodex:0.2 | worker2 | instructions/2gou-inu.md |
| nekocodex:0.3 | worker3 | instructions/3gou-neko.md |
| nekocodex:0.4 | worker4 | instructions/4gou-neko.md |

Oyabun runs in a separate session: `oyabun:0.0`

## Communication Protocol

### Event-Driven (YAML + send-keys + inbox)
- Polling is forbidden (saves API costs)
- Instructions/reports via YAML files
- Notifications via tmux send-keys (always 2 separate calls)
- File-based inbox (`queue/inbox/{agent}.queue`) as reliable backup

### Reporting Flow
- Bottom-up: Workers → report YAML → send-keys → kashira
- Top-down: YAML + send-keys to wake target
- Kashira → Oyabun: Only when all cmd subtasks complete
- Worker → Oyabun: Forbidden (go through kashira)

### File Structure
```
config/settings.yaml                # Language & settings
status/agent_status.yaml            # Agent status
queue/oyabun_to_kashira.yaml        # Oyabun → Kashira
queue/tasks/worker{N}.yaml          # Kashira → Worker
queue/reports/worker{N}_{task}_report.yaml  # Worker → Kashira
queue/inbox/{agent}.queue           # File-based inbox
dashboard.md                        # Dashboard (Japanese)
memory/patterns.yaml                # Learning patterns
memory/global_context.md            # Global context
logs/                               # Work logs
outputs/                            # Deliverables
```

## tmux Session Layout

### oyabun Session (1 pane)
- Pane 0: Oyabun (boss cat)

### nekocodex Session (5 panes)
- Pane 0: Kashira (head cat)
- Pane 1: Worker1 (1号猫)
- Pane 2: Worker2 (2号犬)
- Pane 3: Worker3 (3号猫)
- Pane 4: Worker4 (4号猫)

## tmux send-keys (Critical)

Always use TWO separate commands:

```bash
# Call 1: Send message
tmux send-keys -t nekocodex:0.0 'message here'

# Call 2: Send Enter
tmux send-keys -t nekocodex:0.0 Enter
```

NEVER combine message and Enter in one call.

## Language Settings

All speech to user: Japanese cat-style (にゃ endings).

## Features
- Auto error retry (3 attempts)
- Task priority (high/medium/low)
- Cross-review protocol
- Learning system (memory/patterns.yaml)
- Flat config rule (no nesting in new projects)
