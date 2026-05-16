#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LONGRUN_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel)"

load_config_defaults() {
  local config_file="$1"
  local line key value
  [[ -f "${config_file}" ]] || return 0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]] && continue
    [[ "${line}" == *"="* ]] || continue
    key="${line%%=*}"
    key="${key#"${key%%[![:space:]]*}"}"
    key="${key%"${key##*[![:space:]]}"}"
    [[ "${key}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    if [[ -z "${!key+x}" ]]; then
      value="${line#*=}"
      value="${value#"${value%%[![:space:]]*}"}"
      value="${value%"${value##*[![:space:]]}"}"
      if [[ "${#value}" -ge 2 && "${value:0:1}" == '"' && "${value: -1}" == '"' ]]; then
        value="${value:1:${#value}-2}"
      elif [[ "${#value}" -ge 2 && "${value:0:1}" == "'" && "${value: -1}" == "'" ]]; then
        value="${value:1:${#value}-2}"
      fi
      export "${key}=${value}"
    fi
  done <"${config_file}"
}

load_config_defaults "${LONGRUN_DIR}/config.env"
load_config_defaults "${LONGRUN_DIR}/config.defaults.env"

CODEX_MODEL="${CODEX_MODEL:-gpt-5.5}"
CODEX_ANALYZE_EFFORT="${CODEX_ANALYZE_EFFORT:-xhigh}"
RUN_ID="${RUN_ID:-manual-plan-$(date +%Y%m%d-%H%M%S)}"
RUNS_DIR="${RUNS_DIR:-ops/hermes-longrun/runs}"
RUN_DIR="${RUN_DIR:-${REPO_ROOT}/${RUNS_DIR}/${RUN_ID}}"
REQUIREMENTS_DOC="${REQUIREMENTS_DOC:-ops/hermes-longrun/requirements.md}"
AUTO_PLAN_ARTIFACT_DIR="${AUTO_PLAN_ARTIFACT_DIR:-ops/hermes-longrun/generated}"
AUTO_PLAN_DEFAULT_CHECKS="${AUTO_PLAN_DEFAULT_CHECKS:-git diff --check}"
AUTO_PLAN_DRY_RUN="${AUTO_PLAN_DRY_RUN:-0}"

log() {
  printf '[generate-task-plan] %s\n' "$*"
}

fail() {
  printf '[generate-task-plan][ERROR] %s\n' "$*" >&2
  exit 1
}

longrun_relpath() {
  python3 - "$LONGRUN_DIR" "$REPO_ROOT" <<'PY'
import os
import sys
print(os.path.relpath(sys.argv[1], sys.argv[2]))
PY
}

repo_path() {
  python3 - "$REPO_ROOT" "$1" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1]).resolve()
path = Path(sys.argv[2]).expanduser()
if not path.is_absolute():
    path = root / path
print(path.resolve(strict=False))
PY
}

ensure_repo_relative() {
  local rel="$1"
  python3 - "$REPO_ROOT" "$rel" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1]).resolve()
path = Path(sys.argv[2]).expanduser()
if not path.is_absolute():
    path = root / path
path = path.resolve(strict=False)
try:
    print(path.relative_to(root))
except ValueError:
    raise SystemExit(1)
PY
}

requirements_path="$(repo_path "${REQUIREMENTS_DOC}")"
requirements_rel="$(ensure_repo_relative "${REQUIREMENTS_DOC}")" || fail "REQUIREMENTS_DOC must stay inside repo: ${REQUIREMENTS_DOC}"
artifact_rel="$(ensure_repo_relative "${AUTO_PLAN_ARTIFACT_DIR}")" || fail "AUTO_PLAN_ARTIFACT_DIR must stay inside repo: ${AUTO_PLAN_ARTIFACT_DIR}"
longrun_rel="$(longrun_relpath)"
task_queue_rel="${longrun_rel}/task-queue.md"
task_queue_path="${REPO_ROOT}/${task_queue_rel}"

requirements_ready() {
  [[ -f "${requirements_path}" ]] || return 1
  grep -q '[^[:space:]]' "${requirements_path}" || return 1
  ! grep -q 'HERMES_LONGRUN_REQUIREMENTS_PLACEHOLDER' "${requirements_path}"
}

write_dry_run_plan() {
  local plan_dir="${REPO_ROOT}/${artifact_rel}"
  local tasks_dir="${plan_dir}/tasks"
  mkdir -p "${tasks_dir}"
  cat >"${plan_dir}/plan.md" <<EOF
# Generated Plan

AUTO_PLAN_DRY_RUN=1 generated this deterministic single-task plan from ${requirements_rel}.
EOF
  cat >"${tasks_dir}/P01.md" <<EOF
# P01: Dry-run requirements slice

## 需求描述

Implement the first coherent slice from ${requirements_rel}.

## 完成后形态

The dry-run runner can exercise the generated task plan without editing business code.

## 依赖前置

None.

## 开发步骤

1. Read ${requirements_rel}.
2. Inspect the relevant project files.
3. Implement the smallest coherent slice.
4. Run the configured checks.

## 注意事项

需要人工补强检查: AUTO_PLAN_DRY_RUN used ${AUTO_PLAN_DEFAULT_CHECKS}.

## 验收方式

The configured checks pass.

## 回归测试

Run ${AUTO_PLAN_DEFAULT_CHECKS}.
EOF
  cat >"${task_queue_path}" <<EOF
# Task Queue

Generated from ${requirements_rel} by AUTO_PLAN_DRY_RUN=1.

TASK|P01|Dry-run requirements slice|${artifact_rel}/tasks/P01.md||${AUTO_PLAN_DEFAULT_CHECKS}
EOF
}

assert_plan_scope() {
  python3 - "$REPO_ROOT" "$requirements_rel" "$task_queue_rel" "$artifact_rel" <<'PY'
from __future__ import annotations

import subprocess
import sys

repo, requirements_rel, task_queue_rel, artifact_rel = sys.argv[1:5]

def lines(command: list[str]) -> list[str]:
    result = subprocess.run(command, cwd=repo, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
    return [line for line in result.stdout.splitlines() if line]

changed = set(lines(["git", "diff", "--name-only"]))
changed.update(lines(["git", "ls-files", "--others", "--exclude-standard"]))

allowed_exact = {requirements_rel, task_queue_rel}
artifact_prefix = artifact_rel.rstrip("/") + "/"
violations = [
    path
    for path in sorted(changed)
    if path not in allowed_exact and not path.startswith(artifact_prefix)
]
if violations:
    for path in violations:
        print(f"[generate-task-plan][ERROR] planning modified disallowed path: {path}", file=sys.stderr)
    raise SystemExit(1)
PY
}

if ! requirements_ready; then
  fail "requirements document is missing or still contains the placeholder: ${requirements_rel}"
fi

mkdir -p "${RUN_DIR}" "${REPO_ROOT}/${artifact_rel}"

if [[ "${AUTO_PLAN_DRY_RUN}" == "1" ]]; then
  log "AUTO_PLAN_DRY_RUN=1; writing deterministic plan"
  write_dry_run_plan
else
  plan_prompt="${RUN_DIR}/plan-from-requirements.prompt.md"
  plan_summary="${RUN_DIR}/plan-from-requirements.md"
  plan_jsonl="${RUN_DIR}/plan-from-requirements.jsonl"
  sed \
    -e "s|{{AUTO_PLAN_ARTIFACT_DIR}}|${artifact_rel}|g" \
    -e "s|{{TASK_QUEUE_PATH}}|${task_queue_rel}|g" \
    "${LONGRUN_DIR}/prompts/plan-from-requirements.md" >"${plan_prompt}"
  {
    printf '\n\nPrompt context:\n'
    printf -- '- Requirements doc: %s\n' "${requirements_rel}"
    printf -- '- Task queue path: %s\n' "${task_queue_rel}"
    printf -- '- Artifact dir: %s\n' "${artifact_rel}"
    printf -- '- Default checks when project checks cannot be inferred: %s\n' "${AUTO_PLAN_DEFAULT_CHECKS}"
    printf '\nAllowed write paths:\n'
    printf -- '- %s\n' "${requirements_rel}"
    printf -- '- %s\n' "${task_queue_rel}"
    printf -- '- %s/**\n' "${artifact_rel}"
  } >>"${plan_prompt}"

  log "running Codex planning phase"
  codex exec \
    --ephemeral \
    --json \
    --cd "${REPO_ROOT}" \
    --sandbox workspace-write \
    -m "${CODEX_MODEL}" \
    -c "model_reasoning_effort=\"${CODEX_ANALYZE_EFFORT}\"" \
    -o "${plan_summary}" \
    - <"${plan_prompt}" >"${plan_jsonl}" 2>&1 || {
      sed -n '1,160p' "${plan_jsonl}" >&2 || true
      fail "Codex planning phase failed"
    }
fi

assert_plan_scope
"${SCRIPT_DIR}/validate-task-plan.py" --repo-root "${REPO_ROOT}" --longrun-dir "${LONGRUN_DIR}"
log "task plan generated and validated"
