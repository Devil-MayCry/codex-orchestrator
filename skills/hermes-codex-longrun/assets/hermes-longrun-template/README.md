# Hermes + Codex Long-Run (Plus)

This folder is a reusable local runner for unattended long-running work. The default flow starts from one `requirements.md` document and lets Codex generate the task plan before the existing Hermes-supervised execution loop begins.

This is the **plus** variant: Codex only writes recovery advisories; Hermes makes the final recovery decision through `scripts/decide-recovery.sh`. If Hermes does not respond within `HERMES_DECISION_TIMEOUT_SECONDS` (default 300), the runner auto-approves the advisory and records `auto_approved_by_timeout=1`. Execution is strictly serial; the dependency graph in `task-queue.md` is used for topological ordering and dependency-cascade skipping only.

## First-Time Setup

1. Replace `requirements.md` with the requirement, PRD, or implementation brief.
2. Optionally copy `config.env.example` to `config.env` and add only the values you want to override; defaults live in `config.defaults.env` (do not edit that file).
3. Commit this scaffold before launching a real run. The edited `requirements.md` may remain uncommitted; the startup script copies it into the long-run worktree and commits the generated plan there.
4. Run:

```bash
hermes -z "$(cat ops/hermes-longrun/HERMES_SUPERVISOR_PROMPT.md)"
```

The startup command creates a long-run worktree and branch. If `task-queue.md`
still contains the placeholder, it generates `generated/plan.md`,
`generated/tasks/*.md`, and a real `task-queue.md`, then commits those planning
artifacts before running preflight and the task loop.

If you scaffolded into a different directory, replace `ops/hermes-longrun` with that path.

## Manual Task Queue Mode

Advanced users can replace `task-queue.md` and provide task docs manually. When
the task queue already validates, auto-planning from `requirements.md` is
skipped.

## Monitoring

Hermes should only use:

```bash
bash ops/hermes-longrun/scripts/monitor-pipeline.sh
```

If `STATE=RUNNING`, wait about 60 seconds and run the monitor again. Do not run foreground `tail -f` loops inside Hermes. If `STATE=AWAITING_DECISION`, read the advisory printed by the monitor and call `bash ops/hermes-longrun/scripts/decide-recovery.sh ...` to record the final decision.

## After A Successful Run

The pipeline leaves the worktree and branch in place so you can review and merge them yourself. Typical cleanup:

```bash
# review commits
( cd <worktree-dir> && git log --oneline )

# fast-forward merge into main (or open a PR)
git -C <repo-root> fetch
git -C <repo-root> checkout main
git -C <repo-root> merge --ff-only <branch>
# or: git -C <repo-root> push origin <branch>:refs/heads/review/<branch>

# remove the worktree (the branch can stay or be deleted afterwards)
git -C <repo-root> worktree remove <worktree-dir>
git -C <repo-root> branch -d <branch>      # only after merging
# git -C <repo-root> branch -D <branch>     # if you decided not to keep the work
```

Both `<worktree-dir>` and `<branch>` are printed in the final report and in `runs/<run-id>/run.env`.

## Recovery

Every failed check or non-committable verifier verdict enters a recovery decision pass before retry or block. `MAX_FIX_ATTEMPTS` is the single build retry budget; Hermes decides whether each failed attempt deserves the next build, alternate checks, scoped acceptance, or a true block.

Codex build phases should not run Git staging commands. The shell runner stages
the candidate diff immediately before each read-only verifier pass, then stages
again at commit time and applies the verifier `FILE:` scope audit.

Recovery decisions are recorded in `runs/<run-id>/recovery-decisions.md`. Blocked tasks are recorded in `runs/<run-id>/blocked-tasks.md`. Directly blocked task patches are preserved under the task run directory, then the worktree is reset so independent tasks can continue.

If a run is interrupted, start the supervisor again. It will refuse to launch another active pipeline and will preserve interrupted dirty worktree patches when configured.
