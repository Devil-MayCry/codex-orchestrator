from __future__ import annotations

import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
VALIDATOR = (
    REPO_ROOT
    / "skills/hermes-codex-longrun/assets/hermes-longrun-template/scripts/validate-task-plan.py"
)


class ValidateTaskPlanTests(unittest.TestCase):
    def run_validator(self, task_queue: str, docs: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            longrun = repo / "ops/hermes-longrun"
            longrun.mkdir(parents=True)
            (longrun / "task-queue.md").write_text(task_queue, encoding="utf-8")
            for rel_path, body in (docs or {}).items():
                path = repo / rel_path
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(body, encoding="utf-8")
            return subprocess.run(
                [
                    "python3",
                    str(VALIDATOR),
                    "--repo-root",
                    str(repo),
                    "--longrun-dir",
                    str(longrun),
                ],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )

    def test_valid_queue_passes(self) -> None:
        result = self.run_validator(
            "\n".join(
                [
                    "TASK|P01|First slice|ops/hermes-longrun/generated/tasks/P01.md||git diff --check",
                    "TASK|P02|Second slice|ops/hermes-longrun/generated/tasks/P02.md|P01|python -m pytest",
                ]
            ),
            {
                "ops/hermes-longrun/generated/tasks/P01.md": "# P01\n",
                "ops/hermes-longrun/generated/tasks/P02.md": "# P02\n",
            },
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("OK: 2 task(s)", result.stdout)

    def test_duplicate_id_fails(self) -> None:
        result = self.run_validator(
            "\n".join(
                [
                    "TASK|P01|First|ops/hermes-longrun/generated/tasks/P01.md||git diff --check",
                    "TASK|P01|Duplicate|ops/hermes-longrun/generated/tasks/P02.md||git diff --check",
                ]
            ),
            {
                "ops/hermes-longrun/generated/tasks/P01.md": "# P01\n",
                "ops/hermes-longrun/generated/tasks/P02.md": "# P02\n",
            },
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("duplicate task id", result.stderr)

    def test_unknown_dependency_fails(self) -> None:
        result = self.run_validator(
            "TASK|P01|First|ops/hermes-longrun/generated/tasks/P01.md|P00|git diff --check",
            {"ops/hermes-longrun/generated/tasks/P01.md": "# P01\n"},
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("depends on unknown task", result.stderr)

    def test_dependency_cycle_fails(self) -> None:
        result = self.run_validator(
            "\n".join(
                [
                    "TASK|P01|First|ops/hermes-longrun/generated/tasks/P01.md|P02|git diff --check",
                    "TASK|P02|Second|ops/hermes-longrun/generated/tasks/P02.md|P01|git diff --check",
                ]
            ),
            {
                "ops/hermes-longrun/generated/tasks/P01.md": "# P01\n",
                "ops/hermes-longrun/generated/tasks/P02.md": "# P02\n",
            },
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("dependency cycle detected", result.stderr)

    def test_missing_doc_fails(self) -> None:
        result = self.run_validator(
            "TASK|P01|First|ops/hermes-longrun/generated/tasks/P01.md||git diff --check"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("task doc does not exist", result.stderr)

    def test_empty_checks_fail(self) -> None:
        result = self.run_validator(
            "TASK|P01|First|ops/hermes-longrun/generated/tasks/P01.md||",
            {"ops/hermes-longrun/generated/tasks/P01.md": "# P01\n"},
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("checks are empty", result.stderr)

    def test_placeholder_fails(self) -> None:
        result = self.run_validator(
            "TASK|EX-001|Replace with first real task|docs/tasks/ex-001.md||python -m pytest",
            {"docs/tasks/ex-001.md": "# placeholder\n"},
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("EX-001 placeholder", result.stderr)


if __name__ == "__main__":
    unittest.main()
