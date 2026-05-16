# Architecture (Plus Variant)

## Layering

Hermes controls the outer loop **and the recovery decision**. It starts one background supervisor, then uses short monitor commands to inspect progress. It never directly invokes individual task workers or edits project files. When the runner reports `STATE=AWAITING_DECISION`, Hermes is the decision maker; Codex only writes an advisory.

Shell scripts control the state machine. They decide which task is next (topological order from `task-queue.md`), create the worktree, start dependency services, run checks, stage the candidate diff before read-only verification, parse the verifier verdict, run the Codex recovery advisory pass, publish the awaiting marker, wait for Hermes to call `decide-recovery.sh` (with timeout fallback to the advisory), stage and audit commits, preserve blocked patches, and write stable logs.

Codex CLI controls implementation work and recovery analysis. Each task runs as a bounded loop:

1. `analyze`: read-only, high or xhigh effort.
2. `build`: workspace-write, high effort, one coherent slice. Codex edits files only; it does not run staging or commit commands.
3. `checks`: deterministic project commands.
4. `verify`: read-only, high effort, first-line verdict, reviews the runner-staged candidate diff, and declares the staged file scope via `FILE:` lines.
5. `recovery advisory`: read-only Codex pass that proposes one of `ADVISE_RECOVER_BUILD / ADVISE_RECOVER_CHECKS / ADVISE_ACCEPT_SCOPED / ADVISE_BLOCKED`.
6. `awaiting decision`: pipeline blocks while Hermes (or the timeout fallback) writes the final decision file via `decide-recovery.sh`.
7. `recovery build` or `recovery checks`: only when the recorded decision authorizes it.
8. `block`: only after the recorded decision is `BLOCKED` (either by Hermes or by timeout fallback when the advisory was `ADVISE_BLOCKED`).

## State Machine

The supervisor creates a run directory, records environment in `supervisor.env`, launches a background worker, runs an `awaiting_watch_loop`, and updates `supervisor-status.env`.

Expected states:

- `NO_RUN`: no run directory exists.
- `RUNNING`: background worker is alive or a declared detached session is active and no task is waiting for a decision.
- `AWAITING_DECISION`: at least one task has published an `awaiting-decisions/<task>-<NN>.env` marker; Hermes is expected to call `decide-recovery.sh` before the deadline.
- `FINISHED`: pipeline exited successfully.
- `FAILED`: pipeline exited non-zero and wrote status.
- `ORPHANED`: monitor cannot prove the worker or detached session is alive.

When using `screen` or `tmux`, monitor logic must check the session as first-class state. PID-only checks are not enough because the initial launcher may exit while the detached session continues. For `screen`, parse the `PID.session-name` field from `screen -ls`; do not use a whitespace-only grep for the raw session name.

## Decision Wait + Timeout Fallback

After the recovery advisory is written, the runner:

1. Writes `${TASK_RUN_DIR}/awaiting-decision.env` and a per-task index file `${RUN_DIR}/awaiting-decisions/${TASK}-${NN}.env`.
2. Polls every `HERMES_DECISION_POLL_SECONDS` (default 5s) for `${TASK_RUN_DIR}/decision-attempt-${NN}.env`, which `decide-recovery.sh` writes atomically.
3. If `HERMES_DECISION_TIMEOUT_SECONDS` (default 300s) elapses without a decision, the runner auto-approves the advisory and marks the resulting decision file with `decision_source: auto_approved_by_timeout`.
4. Decisions written by Hermes are recorded with `decision_source: hermes` and `human_decided=1` in `recovery-decisions.md`.
5. `SIGINT`/`SIGTERM` to the worker writes a `BLOCKED + decision_source: supervisor_killed` decision and exits, preventing zombies.

`MAX_FIX_ATTEMPTS` remains the only build retry budget. A `RECOVER_BUILD` decision authorizes the next build only when that total attempt budget still has room.

## Task Continuation

The runner uses the dependency graph in `task-queue.md` to:

- Compute a topological execution order (task with all dependencies satisfied first).
- Cascade-skip dependent tasks when an upstream task is blocked.

When a task blocks:

- Save staged diff, worktree diff, and status into the task run directory.
- Write `summary.md` and append to `blocked-tasks.md`.
- Reset the worktree to the latest committed state.
- Continue tasks that do not depend on the blocked task.
- Mark dependent tasks as `SKIPPED_DEPENDENCY` without spending Codex time on them.

Execution is strictly serial; only one task runs at a time. Parallel scheduling is intentionally not supported in the plus variant.

## Commit Gate

Only commit when all are true:

- The verifier first non-empty line contains exactly `PASS_COMMIT`.
- Checks passed, or the verifier explicitly classifies failures as environmental/non-blocking.
- The verifier declared the file scope via `FILE: <path>` (or `FILES: a,b,c`) lines, and every runner-staged path is either declared or matches `COMMIT_SCOPE_ALLOW_PATTERNS`.
- Runtime files and secrets are not staged.
- The diff is scoped to the current task.

If the staged diff exceeds the declared scope, the verifier verdict is downgraded to `NEED_FIX` and the audit lands in `commit-scope-audit-attempt-<NN>.md`.

## Observability

Every run should produce:

- `pipeline.log`
- `supervisor.log`
- `run.env`
- `awaiting-decisions/` (transient)
- `blocked-tasks.md`
- `recovery-decisions.md`
- `final-report.md`
- Per-task `analysis.md`, builder summaries, check logs, verifier reports, recovery advisories (`recovery-advisory-attempt-<NN>.md`), recovery decisions (`recovery-decision-attempt-<NN>.md`), Hermes decision env files (`decision-attempt-<NN>.env`), commit-scope audits, escalation reports, and `summary.md`

The Hermes supervisor should summarize these files rather than infer progress from live terminal output alone.
