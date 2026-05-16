#!/usr/bin/env python3
"""Scaffold a Hermes + Codex long-run template into a repository."""

from __future__ import annotations

import argparse
import shutil
import sys
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True, help="Target repository root.")
    parser.add_argument(
        "--target",
        default="ops/hermes-longrun",
        help="Template destination relative to --repo, or an absolute path.",
    )
    parser.add_argument("--force", action="store_true", help="Overwrite existing files.")
    parser.add_argument("--dry-run", action="store_true", help="List files without writing.")
    return parser.parse_args()


def iter_template_files(template_root: Path) -> list[Path]:
    return sorted(
        path
        for path in template_root.rglob("*")
        if path.is_file()
        and "__pycache__" not in path.parts
        and path.suffix not in {".pyc", ".pyo"}
    )


def main() -> int:
    args = parse_args()
    skill_root = Path(__file__).resolve().parents[1]
    template_root = skill_root / "assets" / "hermes-longrun-template"
    repo = Path(args.repo).expanduser().resolve()
    target = Path(args.target).expanduser()
    if not target.is_absolute():
        target = repo / target
    target = target.resolve()

    if not repo.exists() or not repo.is_dir():
        print(f"[init-longrun][ERROR] repo does not exist: {repo}", file=sys.stderr)
        return 2
    if not template_root.exists():
        print(f"[init-longrun][ERROR] template missing: {template_root}", file=sys.stderr)
        return 2

    template_files = iter_template_files(template_root)
    planned: list[tuple[Path, Path]] = []
    conflicts: list[Path] = []
    for src in template_files:
        rel = src.relative_to(template_root)
        dest = target / rel
        planned.append((src, dest))
        if dest.exists() and not args.force:
            conflicts.append(dest)

    if conflicts:
        print("[init-longrun][ERROR] refusing to overwrite existing files:", file=sys.stderr)
        for path in conflicts:
            print(f"  {path}", file=sys.stderr)
        print("Use --force to overwrite.", file=sys.stderr)
        return 3

    for _, dest in planned:
        action = "would write" if args.dry_run else "write"
        print(f"[init-longrun] {action}: {dest}")

    if args.dry_run:
        return 0

    for src, dest in planned:
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dest)
        if dest.suffix == ".sh" or dest.name.endswith(".py"):
            dest.chmod(dest.stat().st_mode | 0o755)

    print(f"[init-longrun] scaffolded {len(planned)} files into {target}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
