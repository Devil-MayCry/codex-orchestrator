# Failure Modes (Plus Variant)

## Hermes Terminal Timeout

Do not run the foreground pipeline inside `hermes -z`. Start a background worker through `screen`, `tmux`, or `nohup`, then monitor with short commands.

## False Orphan Status

If the launcher exits after starting `screen`, a PID-only monitor can report `ORPHANED` while work continues. Monitor detached session state as well as PID and status files.

For `screen -ls`, the session field is usually formatted as `PID.session-name`, for example `57204.hamlet-t1-...`. Do not match only ` whitespace + session-name + whitespace`; parse the field after the first dot or use an equivalent exact session-name check. A false `ORPHANED` during active log movement is a monitor bug, not a pipeline failure.

## Dirty Worktree

Dirty worktrees make unattended commits unsafe. Before each task, remove ignored runtime files and refuse uncommitted non-runtime changes. If a previous run was interrupted, preserve staged/worktree patches to the run directory before resetting.

## Missing Or Half-Initialized Dependencies

Dependency setup must be verified by preflight and by the runner. For databases, use isolated services where practical and detect half-initialized schemas before spending Codex attempts.

## Verifier Formatting

The verifier must return a bare first-line verdict. The parser should still search the first few lines for known tokens to tolerate accidental markdown decorations, then treat unknown output as `NEED_FIX`.

## Premature Blocking

Before accepting `BLOCKED`, the verifier/escalator must consider:

- smaller safe slices
- alternate check targets
- local dependency repair
- migration reset or service restart
- committing a partial but coherent prerequisite

Only record human intervention when automation cannot safely advance the dependency chain.

## Blind Retry

Do not wait for all fix attempts to fail before using reasoning. After each failed check or rejected verifier verdict, run a recovery decision pass. The next action must be one of:

- bounded recovery build
- whitelisted replacement checks
- scoped acceptance with explicit metadata
- true block

This prevents wasting attempts on the same failure class and lets the runner fix test harness or environment issues before dependency cascades.

Do not introduce a second recovery-build budget that is lower than the normal build retry budget. `MAX_FIX_ATTEMPTS=2` should allow three build attempts total, but each transition to the next build must still be explicitly authorized by a recovery decision.

## Double Budget Premature Block

If one recovery build completes missing scope and the next attempt fails with a deterministic regression, do not block solely because a separate recovery counter is exhausted. Example: a task first needed AG2 routing after opening arbitration, then the routing change dropped a `StorylineRuntime` import and produced `NameError` across API tests. Hermes correctly diagnosed a one-file import repair; the runner should allow the next build when the task still has attempts remaining under `MAX_FIX_ATTEMPTS`.

## Full-Suite Harness Race

If focused task checks pass but full-suite pytest fails in unrelated teardown or background scheduler code, classify it as `test_harness` unless the task diff is on that stack. Example: a background generation worker keeps using the database while a shared fixture runs `DELETE FROM characters`, causing a PostgreSQL deadlock. The safe recovery path is to make the test harness scheduler-quiescent, rerun bounded checks, or scoped-accept only if the verifier says the task diff is committable and the remaining failure is unrelated.

## Dependency Cascade

Do not blindly continue dependent work after an upstream task blocks. Skip dependent tasks as `SKIPPED_DEPENDENCY`, continue independent tasks, and include the skipped dependency graph in the final report.

## Runtime Artifact Pollution

Run logs, JSONL, app runtime directories, coverage, and temporary env files should be ignored by git. The commit gate must explicitly unstage or remove them before committing.

The runtime cleanup path must not delete the active `${RUN_DIR}` while the task runner is writing prompts, reports, and decision markers. If `${RUN_DIR}` is inside the configured `runs/` path for the current `REPO_WORKDIR`, unstage runtime paths but skip worktree deletion for that path. The runner dry-run smoke in preflight exists to catch regressions here.

## Verifier Staging Gap

Codex build phases must not be responsible for `git add`. In linked worktrees, a sandboxed Codex phase may be unable to write the Git index under the source repo's `.git/worktrees/...` directory. The shell runner should stage the candidate diff before each read-only verifier pass, unstage runtime artifacts, then stage again at commit time before the `FILE:` scope audit.

## Decision Timeout Auto-Approve

The plus variant blocks every recovery on a Hermes decision recorded through `decide-recovery.sh`. If `HERMES_DECISION_TIMEOUT_SECONDS` (default 300s) elapses with no decision, the runner auto-approves the Codex advisory and writes `decision_source: auto_approved_by_timeout` plus `auto_approved_by_timeout=1` into `recovery-decisions.md`. This keeps the pipeline making progress even if the supervisor is idle, but it transfers responsibility for the outcome to the timeout policy. Always inspect the timeout-fallback count in `final-report.md` after each run; if it is non-zero, either lower the latency between monitor polls or raise `HERMES_DECISION_TIMEOUT_SECONDS` so the supervisor can keep up.

## Phase Timeout

Each individual Codex `exec` invocation runs under `CODEX_PHASE_TIMEOUT_SECONDS` (default 1800s). When exceeded, the runner sends `SIGTERM`, then `SIGKILL` after a 5s grace period, and writes a `<phase>.timeout` marker. The next recovery advisory prompt is annotated with the timeout fact so Codex can classify the failure (often `dependency` or `task_spec`) appropriately. Do not raise this cap to silence symptoms — the cap is the only protection against a stuck `codex exec` consuming the entire run window.

## Commit-Scope Audit Mismatch

When `PASS_COMMIT` fires, the runner cross-checks `git diff --cached --name-only` against the verifier's declared `FILE:` lines plus `COMMIT_SCOPE_ALLOW_PATTERNS`. Paths outside both sets cause `PASS_COMMIT` to be downgraded to `NEED_FIX` and a `commit-scope-audit-attempt-<NN>.md` record is written. The next recovery advisory will see this audit fact, so Codex can either explicitly enumerate the additional path or shrink the diff. Do not silence the audit by widening `COMMIT_SCOPE_ALLOW_PATTERNS` reflexively; only add patterns that genuinely should be allowed for every task in this project.
