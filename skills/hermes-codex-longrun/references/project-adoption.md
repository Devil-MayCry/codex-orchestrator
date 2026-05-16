# Project Adoption

## Required Project Decisions

Before launching unattended work, define:

- Task identifiers, task docs, execution order, and dependencies.
- Target checks for each task.
- Which checks are critical task gates, which are full-suite regression gates, and when scoped acceptance is allowed.
- Recovery policy: allowed recovery write scopes, replacement check whitelist, and how `MAX_FIX_ATTEMPTS` bounds total build attempts.
- Required services and how to start isolated local dependencies.
- Which files count as runtime artifacts and must be ignored.
- Commit message convention.
- Whether a blocked task should stop the run or allow independent tasks to continue.

## Recommended Setup Flow

1. Scaffold the template into the project.
2. Commit the scaffold before the first long run so new worktrees can see stable scripts.
3. Fill `task-queue.md` with task ids, docs, dependencies, and checks.
4. Copy `config.env.example` to `config.env` and override only what you need. Defaults live in `config.defaults.env`; the runner loads `config.env` first and falls back to `config.defaults.env`.
5. Customize prompt templates for project conventions and acceptance criteria.
6. Run `scripts/preflight.sh`.
7. Run `scripts/setup-hermes-kanban.sh` if Hermes kanban trace is desired.
8. Start Hermes with `hermes -z "$(cat ops/hermes-longrun/HERMES_SUPERVISOR_PROMPT.md)"`.

## Preflight Expectations

Preflight should prove the unattended run can proceed:

- `codex`, `hermes`, `git`, `rg`, `python3`, and the project package manager are present.
- Codex can run smoke prompts for all required reasoning efforts.
- Hermes can run a smoke prompt.
- Required containers/images/services can start or are already healthy.
- Runtime artifact paths are ignored or untracked.
- Project dependencies can import/build/test enough to catch missing third-party packages.
- Runner dry-run smoke reaches a verifier verdict without deleting its active run artifacts.
- Kanban is initialized if the runner requires it.
- Recovery dry-runs prove that a failed check routes through recovery diagnosis before any retry or block.

## Project-Specific Hooks

The template intentionally uses placeholder functions for:

- `task_doc`
- `task_title`
- `task_dependencies`
- `target_checks`
- `recovery` prompt and decision parsing
- optional dependency service startup
- optional kanban task creation

Do not leave these generic before a real run. The runner must know enough about the project to choose checks and avoid wasting Codex time.

## Launch Protocol

Use this exact supervision shape:

```bash
cd /path/to/project
bash ops/hermes-longrun/scripts/preflight.sh
bash ops/hermes-longrun/scripts/setup-hermes-kanban.sh
hermes -z "$(cat ops/hermes-longrun/HERMES_SUPERVISOR_PROMPT.md)"
```

Hermes should run only:

```bash
bash ops/hermes-longrun/scripts/start-supervised-pipeline.sh
bash ops/hermes-longrun/scripts/monitor-pipeline.sh
```

The second command can be repeated after short waits.
