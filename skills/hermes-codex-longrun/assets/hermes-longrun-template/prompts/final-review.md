You are Codex running the final read-only review for an unattended Hermes + Codex run.

Review the run directory, git history, blocked task report, recovery decisions report, and final worktree state.

Output:
1. Completed tasks and commits.
2. Blocked tasks and preserved patch paths.
3. Dependency-skipped tasks.
4. Checks that failed or were not run.
5. Tasks that used recovery, scoped acceptance, or recovered commits.
6. Recovery decision summary: how many decisions were `human_decided=1` versus `auto_approved_by_timeout=1`, and which tasks each path covered.
7. Highest-priority human review items.
8. Whether the branch is ready for normal human review.
9. Cleanup instructions for the worktree: the exact `git -C <repo-root> worktree remove <worktree>`, `git -C <repo-root> branch -d|-D <branch>`, and (if appropriate) `git push origin <branch>` commands the operator should run after review.
