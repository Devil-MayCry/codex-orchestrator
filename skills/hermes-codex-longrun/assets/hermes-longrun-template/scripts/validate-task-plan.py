#!/usr/bin/env python3
"""Validate a Hermes + Codex long-run task plan."""

from __future__ import annotations

import argparse
import subprocess
import sys
from collections import defaultdict, deque
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Task:
    key: str
    title: str
    doc: str
    deps: tuple[str, ...]
    checks: str
    line_no: int


def parse_args() -> argparse.Namespace:
    script_dir = Path(__file__).resolve().parent
    default_longrun = script_dir.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--longrun-dir",
        default=str(default_longrun),
        help="Path to the ops/hermes-longrun directory.",
    )
    parser.add_argument(
        "--repo-root",
        default=None,
        help="Repository root. Defaults to git rev-parse from --longrun-dir.",
    )
    return parser.parse_args()


def resolve_repo_root(longrun_dir: Path, explicit: str | None) -> Path:
    if explicit:
        return Path(explicit).expanduser().resolve()
    try:
        result = subprocess.run(
            ["git", "-C", str(longrun_dir), "rev-parse", "--show-toplevel"],
            check=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    except (OSError, subprocess.CalledProcessError):
        return Path.cwd().resolve()
    return Path(result.stdout.strip()).resolve()


def parse_task_queue(path: Path) -> tuple[list[Task], list[str]]:
    errors: list[str] = []
    tasks: list[Task] = []
    seen: dict[str, int] = {}

    if not path.exists():
        return [], [f"task-queue.md is missing: {path}"]

    for line_no, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not raw.startswith("TASK|"):
            continue
        parts = raw.split("|", 5)
        if len(parts) != 6:
            errors.append(f"line {line_no}: expected 6 TASK fields, got {len(parts)}")
            continue
        _, key, title, doc, dep_field, checks = [part.strip() for part in parts]
        if key == "EX-001":
            errors.append("task-queue.md still contains the EX-001 placeholder")
        if not key:
            errors.append(f"line {line_no}: task id is empty")
        if any(ch.isspace() for ch in key):
            errors.append(f"line {line_no}: task id must not contain whitespace: {key!r}")
        if key in seen:
            errors.append(f"line {line_no}: duplicate task id {key!r}; first seen on line {seen[key]}")
        elif key:
            seen[key] = line_no
        if not title:
            errors.append(f"line {line_no}: title is empty for task {key!r}")
        if not doc:
            errors.append(f"line {line_no}: task doc path is empty for task {key!r}")
        if not checks:
            errors.append(f"line {line_no}: checks are empty for task {key!r}")
        deps = tuple(dep.strip() for dep in dep_field.split(",") if dep.strip())
        tasks.append(Task(key=key, title=title, doc=doc, deps=deps, checks=checks, line_no=line_no))

    if not tasks:
        errors.append("task-queue.md has no TASK| lines")
    return tasks, errors


def validate_docs(tasks: list[Task], repo_root: Path) -> list[str]:
    errors: list[str] = []
    for task in tasks:
        if not task.doc:
            continue
        doc_path = (repo_root / task.doc).resolve()
        try:
            doc_path.relative_to(repo_root)
        except ValueError:
            errors.append(f"line {task.line_no}: task doc escapes repo root: {task.doc}")
            continue
        if not doc_path.is_file():
            errors.append(f"line {task.line_no}: task doc does not exist: {task.doc}")
    return errors


def validate_dependencies(tasks: list[Task]) -> list[str]:
    errors: list[str] = []
    keys = [task.key for task in tasks if task.key]
    known = set(keys)
    deps_by_key = {task.key: list(task.deps) for task in tasks if task.key}
    children: dict[str, set[str]] = defaultdict(set)

    for task in tasks:
        for dep in task.deps:
            if dep not in known:
                errors.append(f"line {task.line_no}: task {task.key!r} depends on unknown task {dep!r}")
            else:
                children[dep].add(task.key)

    if errors:
        return errors

    indeg = {key: len(deps_by_key.get(key, [])) for key in keys}
    queue: deque[str] = deque(key for key in keys if indeg[key] == 0)
    result: list[str] = []
    while queue:
        node = queue.popleft()
        result.append(node)
        for child in keys:
            if child not in children[node]:
                continue
            indeg[child] -= 1
            if indeg[child] == 0:
                queue.append(child)

    if len(result) != len(keys):
        unresolved = [key for key in keys if key not in result]
        errors.append(f"dependency cycle detected; unresolved tasks: {', '.join(unresolved)}")
    return errors


def main() -> int:
    args = parse_args()
    longrun_dir = Path(args.longrun_dir).expanduser().resolve()
    repo_root = resolve_repo_root(longrun_dir, args.repo_root)
    tasks, errors = parse_task_queue(longrun_dir / "task-queue.md")
    errors.extend(validate_dependencies(tasks))
    errors.extend(validate_docs(tasks, repo_root))

    if errors:
        for error in errors:
            print(f"[validate-task-plan][ERROR] {error}", file=sys.stderr)
        return 1

    print(f"[validate-task-plan] OK: {len(tasks)} task(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
