# Lifecycle Contract

This file defines the common task lifecycle contract for neko-codex.

## Standard States

1. `queued`
2. `assigned`
3. `reviewing`
4. `integrated`
5. `done`
6. `blocked`

## Standard Transitions

Allowed:
- `queued -> assigned`
- `assigned -> reviewing`
- `reviewing -> integrated`
- `integrated -> done`
- `queued -> blocked`
- `assigned -> blocked`
- `reviewing -> blocked`
- `integrated -> blocked`
- `blocked -> assigned` (retry path)

## Exception Path

For non-standard transitions, require:
- `exception_reason`
- `approved_by` (oyabun or explicit policy)

Without these keys, non-standard transitions are invalid.

## Responsibility

- `worker`: execute assigned tasks and report with evidence
- `kashira`: enforce lifecycle consistency and report completeness
- `oyabun`: approve exception path and high-risk policy decisions
