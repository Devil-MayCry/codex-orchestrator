# Task Queue

Edit the machine-readable `TASK|...` lines before a real run.

Format (the parser reads lines that start with `TASK|`):

```text
TASK_LINE|<id>|<title>|<task-doc-path>|<comma-separated-dependencies>|<checks separated by " &&& ">
```

Rules:

- Machine-readable task lines must start with the literal `TASK|`. Lines starting with anything else (including `TASK_LINE|`) are ignored by the runner.
- Task ids must not contain `|`.
- Dependency ids are comma-separated, for example `S01,S02`.
- Checks run from the repository root through `bash -lc`.
- Leave dependencies blank when a task has no upstream dependency.
- Keep task docs and checks project-specific; the runner does not infer acceptance criteria.
- Remove the `EX-001` placeholder before launching a real run; preflight refuses to start while it is still present.

Example placeholder (delete this line and the one below it before running):

```text
TASK_LINE|EX-001|Replace with first real task|docs/tasks/ex-001.md||python -m pytest
```

TASK|EX-001|Replace with first real task|docs/tasks/ex-001.md||python -m pytest
