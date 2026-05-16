# Recovery Playbook (Plus Variant)

Use this when a long-run task fails checks or verifier review. In the plus variant Codex writes an *advisory* and Hermes (or, after `HERMES_DECISION_TIMEOUT_SECONDS` of inactivity, the timeout fallback) writes the final decision through `decide-recovery.sh`.

## Decision Order

1. Confirm focused task checks and migration state.
2. Classify the failure: implementation, test harness, stale check target, dependency, migration, or task-spec ambiguity.
3. Read the Codex advisory (`recovery-advisory-attempt-<NN>.md`) and decide whether to accept it. The advisory is a recommendation; you may override it.
4. Choose exactly one action and call `decide-recovery.sh`:
   - `RECOVER_BUILD` for a bounded fix with an explicit write scope. Only valid when `MAX_FIX_ATTEMPTS` budget has room.
   - `RECOVER_CHECKS --checks "<cmd>[ &&& <cmd>]"` for stale or overbroad checks with exact replacement commands. Each command must be in the task's `target_checks`.
   - `ACCEPT_SCOPED [--accept-failed "<cmd>[ &&& <cmd>]"]` for scoped task success with unrelated failures. Use `--accept-failed` whenever the failures are not the configured `FULL_TEST_COMMAND`; each command must appear verbatim in `[check failed]` lines of the checks log.
   - `BLOCKED` only when recovery is unsafe.
5. Always pass `--reason "..."` to make the audit trail explain *why*.

`MAX_FIX_ATTEMPTS` is the only build retry budget. A `RECOVER_BUILD` decision authorizes the next build only when that total attempt budget still has room; do not also gate it behind a separate recovery-build counter.

## When To Use Each Action Argument

| Action | Required arguments | Optional arguments | Notes |
| --- | --- | --- | --- |
| RECOVER_BUILD | `--reason` | - | The next build attempt will receive `Mode: recovery-attempt-NN`. |
| RECOVER_CHECKS | `--checks`, `--reason` | - | `--checks` lists exact command(s) (separated by ` &&& `). The runner refuses commands outside `target_checks`. |
| ACCEPT_SCOPED | `--reason` | `--accept-failed` | `--accept-failed` is required unless the only failed check is the configured `FULL_TEST_COMMAND`. |
| BLOCKED | `--reason` | - | The runner preserves the current patch and continues with independent tasks. |

## Common Recoveries

- Stale focused test path: run the current focused test file and full suite; update the check target via `RECOVER_CHECKS --checks "<cmd>"`.
- Full-suite unrelated failure: inspect the failing stack. If background schedulers, workers, or shared fixtures race teardown, prefer fixing the harness via `RECOVER_BUILD`. Use `ACCEPT_SCOPED` only when task checks passed and the verifier approves.
- Dependency failure: restart or recreate isolated services when the state is local to the run; this often justifies `RECOVER_BUILD` with a scope limited to dependency setup.
- Migration failure: repair the migration or reset the isolated database only when the project policy allows it.
- Interrupted worktree: preserve patches, reset to last committed state, and continue from committed work only.

## Timeout Fallback Awareness

If you do not call `decide-recovery.sh` within `HERMES_DECISION_TIMEOUT_SECONDS` (default 300s), the runner auto-approves the Codex advisory and records `decision_source: auto_approved_by_timeout`. Read the final report's decision-source breakdown after every run; long-tail timeout fallbacks usually mean the supervisor was idle too long or the timeout is set too low for your operator response time.
