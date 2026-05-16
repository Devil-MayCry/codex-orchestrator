# Codex Orchestrator

Codex Orchestrator is a Codex skill for turning one large requirements document into a supervised long-running implementation pipeline:

- **Hermes** supervises the run, monitors state, and makes final recovery decisions.
- **Codex CLI** generates task slices, then performs analysis, implementation, verification, and recovery advisory work through `codex exec`.
- **Shell scripts** own deterministic control flow: preflight, background execution, state files, timeouts, recovery gates, git staging, commits, and blocked-task records.

This repository packages the installable skill as `skills/hermes-codex-longrun` while keeping GitHub-facing documentation at the repository root.

## What It Does

Codex Orchestrator is the `plus` variant of the Hermes + Codex long-run workflow. Codex writes `ADVISE_*` recovery advisories, but Hermes is the supervisor of record and writes the final decision through `decide-recovery.sh`.

Key behavior:

- Automatic task-plan generation from `ops/hermes-longrun/requirements.md`.
- Serial execution with topological task ordering from generated or manually supplied `task-queue.md`.
- Dependency-cascade skipping for downstream tasks after an explicit block.
- Per-phase Codex wall-clock timeouts.
- Verifier file-scope cross-checks before commit.
- Isolated git worktrees and branches for each run.
- `lessons.md` transfer across tasks.
- Recovery decisions of `RECOVER_BUILD`, `RECOVER_CHECKS`, `ACCEPT_SCOPED`, or `BLOCKED`.
- A default 300 second Hermes decision timeout that auto-approves the Codex advisory and records `auto_approved_by_timeout=1`.

## Installation

Install from GitHub with the Codex skill installer:

```bash
python3 ~/.codex/skills/.system/skill-installer/scripts/install-skill-from-github.py \
  --repo Devil-MayCry/codex-orchestrator \
  --path skills/hermes-codex-longrun
```

Restart Codex after installing so the skill is discovered.

For local development from a checked-out copy:

```bash
rsync -a --delete \
  skills/hermes-codex-longrun/ \
  "${CODEX_HOME:-$HOME/.codex}/skills/hermes-codex-longrun/"
```

Restart Codex after syncing local changes.

## Quick Start

Scaffold the long-run template into a target project:

```bash
python3 ~/.codex/skills/hermes-codex-longrun/scripts/init_longrun_template.py \
  --repo /path/to/project \
  --target ops/hermes-longrun
```

In the target project, replace the generated requirements placeholder:

```bash
$EDITOR ops/hermes-longrun/requirements.md
```

Then start Hermes:

```bash
hermes -z "$(cat ops/hermes-longrun/HERMES_SUPERVISOR_PROMPT.md)"
```

The startup command creates the long-run worktree and branch. If `task-queue.md` still contains the placeholder, Codex generates `generated/plan.md`, `generated/tasks/*.md`, and a real `task-queue.md`, then commits those planning artifacts before preflight and execution.

For local overrides, copy `config.env.example` to `config.env`. `config.env` is ignored by the template and is copied into the long-run worktree at startup.

Advanced users may replace `task-queue.md` and provide task docs manually. If the queue already validates, requirements-based auto-planning is skipped.

If you scaffolded into another directory, replace `ops/hermes-longrun` with that path.

## Monitoring And Recovery

Hermes should monitor the background pipeline with:

```bash
bash ops/hermes-longrun/scripts/monitor-pipeline.sh
```

If the monitor reports `STATE=RUNNING`, Hermes must keep supervising and run the bounded wait-and-monitor command until the pipeline reaches a terminal state or needs a decision:

```bash
bash ops/hermes-longrun/scripts/wait-and-monitor.sh
```

If it reports `STATE=AWAITING_DECISION`, read the advisory, verifier report, and checks log, then record the final decision with one of the copy-paste commands printed by the monitor. Valid actions are:

- `RECOVER_BUILD`
- `RECOVER_CHECKS`
- `ACCEPT_SCOPED`
- `BLOCKED`

Only `STATE=FINISHED`, `STATE=FAILED`, `STATE=ORPHANED`, or `STATE=NO_RUN` should be treated as terminal. The background runner may continue if Hermes exits, but that is a fallback, not the intended supervision flow.

The runner records decisions under `runs/<run-id>/recovery-decisions.md`. Blocked tasks are recorded under `runs/<run-id>/blocked-tasks.md`.

## Repository Layout

```text
.
├── README.md
├── LICENSE
├── skills/
│   └── hermes-codex-longrun/
│       ├── SKILL.md
│       ├── agents/openai.yaml
│       ├── scripts/
│       ├── references/
│       └── assets/hermes-longrun-template/
├── tests/
└── .gitignore
```

## 中文说明

Codex Orchestrator 是一个用于长时间无人值守软件任务的 Codex skill。它把职责拆开：

- **Hermes** 负责监督流程、轮询状态、总结日志，并对每次恢复动作做最终决策。
- **Codex CLI** 通过 `codex exec` 负责分析、实现、验证和恢复建议。
- **Shell 脚本** 负责确定性的控制流，包括 preflight、后台执行、状态文件、超时、恢复闸门、Git 暂存、提交和 blocked task 记录。

这是 Hermes + Codex long-run 工作流的 `plus` 版本：Codex 只写 `ADVISE_*` 恢复建议，Hermes 通过 `decide-recovery.sh` 写入最终决策。默认情况下，如果 Hermes 在 300 秒内没有写入决策，runner 会自动批准 Codex 的建议，并记录 `auto_approved_by_timeout=1`。

## 中文安装

从 GitHub 安装：

```bash
python3 ~/.codex/skills/.system/skill-installer/scripts/install-skill-from-github.py \
  --repo Devil-MayCry/codex-orchestrator \
  --path skills/hermes-codex-longrun
```

安装后重启 Codex。

本地开发时，可以把仓库里的 skill 同步到 Codex skills 目录：

```bash
rsync -a --delete \
  skills/hermes-codex-longrun/ \
  "${CODEX_HOME:-$HOME/.codex}/skills/hermes-codex-longrun/"
```

同步后重启 Codex。

## 中文快速开始

在目标项目中生成长任务模板：

```bash
python3 ~/.codex/skills/hermes-codex-longrun/scripts/init_longrun_template.py \
  --repo /path/to/project \
  --target ops/hermes-longrun
```

然后只需要把 `requirements.md` 替换成你的大需求文档，再用生成的 `HERMES_SUPERVISOR_PROMPT.md` 启动 Hermes：

```bash
$EDITOR ops/hermes-longrun/requirements.md
hermes -z "$(cat ops/hermes-longrun/HERMES_SUPERVISOR_PROMPT.md)"
```

启动脚本会创建 long-run worktree/branch。如果 `task-queue.md` 仍是占位内容，它会先从 `requirements.md` 自动生成 `generated/plan.md`、`generated/tasks/*.md` 和真实 `task-queue.md`，并把这些规划产物提交到 long-run 分支，然后自动运行 preflight、kanban setup 和任务执行流程。

如果你已经手工写好了 `task-queue.md` 和任务文档，且校验通过，自动拆分会跳过，继续使用现有手工队列。

运行期间先用 `monitor-pipeline.sh` 观察状态；如果是 `STATE=RUNNING`，Hermes 必须继续监督，用有界等待命令继续轮询，直到进入终态或需要决策：

```bash
bash ops/hermes-longrun/scripts/wait-and-monitor.sh
```

当进入 `STATE=AWAITING_DECISION` 时，读取 advisory、verifier report 和 checks log，再使用 monitor 输出的 `decide-recovery.sh` 示例命令写入 `RECOVER_BUILD`、`RECOVER_CHECKS`、`ACCEPT_SCOPED` 或 `BLOCKED`。只有 `STATE=FINISHED`、`STATE=FAILED`、`STATE=ORPHANED` 或 `STATE=NO_RUN` 才算终态；后台 runner 可能在 Hermes 退出后继续跑完，但这只是容错，不是推荐监督流程。

## License

MIT
