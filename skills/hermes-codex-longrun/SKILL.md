---
name: hermes-codex-longrun
description: >-
  Use when planning, setting up, supervising, or recovering unattended
  long-running software work coordinated by Hermes (final decision maker) and
  Codex CLI (field commander producing advisories), especially when starting
  from one large requirements document that should be split into task docs and
  then executed. Plus variant: Codex writes ADVISE_* recovery advisories, Hermes
  writes the final decision through decide-recovery.sh, with a 300s decision
  timeout that auto-approves the advisory. Serial execution only; the dependency
  graph is used for topological ordering and dependency-cascade skipping. Covers
  requirements-to-task planning, per-phase wall-clock timeouts, verifier
  file-scope cross-check, lessons.md cross-task experience transfer, worktree
  isolation, blocked-task continuation, and reusable project scaffolding.
---

# Hermes + Codex Long-Run Plus

Use this skill for complex work that is too large for one interactive Codex turn and needs Hermes to keep a long-running local pipeline moving. This is the `plus` variant of `hermes-codex-longrun`: Codex stays as the strongest reasoner but it only produces *advisories*; Hermes is the supervisor of record and writes the final decision.

## Core Contract

- Hermes is the supervisor and the final decision maker. It starts the pipeline, polls status, summarizes logs, and explicitly decides every recovery action through `decide-recovery.sh`.
- Hermes does not edit business code, open Codex TUI, split tasks ad hoc, run foreground long loops, or bypass sandbox/approval controls.
- Codex CLI owns software work through `codex exec`: read-only analysis, bounded workspace-write implementation, read-only verification, read-only recovery *advisory*, and high-effort escalation. Codex never decides recovery on its own.
- Shell scripts own deterministic control flow: requirements-to-task planning, preflight, background execution, state files, decision wait + timeout, recovery gates, logs, dependency guards, Git staging, commits, and blocked-task records.
- Codex build phases edit files only. The runner stages the candidate diff before read-only verification and stages again before commit.
- The pipeline is strictly serial. The dependency graph in `task-queue.md` is used to choose execution order (topological sort) and to cascade-skip blocked downstream tasks. Parallel scheduling is intentionally disabled in this variant to keep the commit gate simple.
- Every failed check or non-committable verifier verdict triggers a Codex recovery advisory pass and then enters `AWAITING_DECISION`. Hermes must call `decide-recovery.sh` with one of `RECOVER_BUILD / RECOVER_CHECKS / ACCEPT_SCOPED / BLOCKED`. If no decision lands within `HERMES_DECISION_TIMEOUT_SECONDS` (default 300), the runner auto-approves the advisory and records `auto_approved_by_timeout=1`.
- `MAX_FIX_ATTEMPTS` is the single build retry budget; `RECOVER_BUILD` only consumes attempts that the budget still has.
- A blocked task is recorded only after Hermes (or the timeout fallback) explicitly chooses `BLOCKED`. Independent downstream tasks may continue, while dependent tasks are skipped and recorded.
- Every run uses an isolated git worktree/branch. Commit only after checks pass and the verifier returns `PASS_COMMIT` *and* the runner-staged diff is within the verifier's declared `FILE:` scope.
- Runtime files live under an ignored `runs/` directory and must never make the worktree dirty.

## When Setting Up A Project

1. Read `references/project-adoption.md` before writing project-specific configuration.
2. Scaffold the template with:

   ```bash
   python3 ~/.codex/skills/hermes-codex-longrun/scripts/init_longrun_template.py \
     --repo /path/to/project \
     --target ops/hermes-longrun
   ```

3. Replace `ops/hermes-longrun/requirements.md` with the large requirement, PRD, or implementation brief.
4. Optionally copy `config.env.example` to `config.env` for local overrides. Default values live in `config.defaults.env`; do not edit that file unless you are changing the template.
5. Start Hermes with the generated `HERMES_SUPERVISOR_PROMPT.md`. The startup script creates the long-run worktree, generates `task-queue.md` and `generated/tasks/*.md` when the queue still contains the placeholder, commits that plan on the long-run branch, runs preflight, sets up kanban, and then executes the tasks.
6. Advanced/manual mode remains supported: replace `task-queue.md` and provide task docs yourself. If the queue is already valid, auto-planning is skipped.

## When Supervising Or Debugging

- Read `references/architecture.md` for the state machine (including the `AWAITING_DECISION` state and the 300s decision timeout) and role split.
- Read `references/failure-modes.md` before changing retry, monitor, decision-timeout, or blocked-task behavior.
- Read `references/recovery-playbook.md` when designing or debugging Hermes recovery decisions.
- Hermes must not treat `STATE=RUNNING` as a stopping point. Use `scripts/wait-and-monitor.sh` for bounded waits, then continue monitoring until `FINISHED`, `FAILED`, `ORPHANED`, `NO_RUN`, or `AWAITING_DECISION`.
- Prefer fixing the runner, check target, test harness, or project configuration before marking a task blocked.
- When you see `STATE=AWAITING_DECISION`, you are the decision maker: read the advisory, the verifier report, and the checks log, then call `decide-recovery.sh`. Do not let the timeout decide on your behalf unless the advisory is obviously correct and you record that judgment as the reason.
- If automation truly cannot continue a task, preserve patches, reset to the last committed state, record why, and continue only tasks whose dependencies remain healthy.

## Safety Defaults

- Never use `--dangerously-bypass-approvals-and-sandbox`.
- Avoid Hermes terminal calls that can exceed local terminal timeouts; use the background worker plus short monitor calls.
- Treat kanban as state trace, not as the execution engine.
- Treat dependency setup as a runner responsibility, not as an implementation-task afterthought.
- Every Codex phase has a wall-clock cap (`CODEX_PHASE_TIMEOUT_SECONDS`, default 1800s); the runner kills phases that exceed it and feeds the timeout into the next recovery advisory.
- Every commit goes through a verifier file-scope cross-check; staged paths outside the declared `FILE:` set (and the configurable allow list) downgrade `PASS_COMMIT` to `NEED_FIX`.
