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
RUN_PREFLIGHT="${RUN_PREFLIGHT:-1}"
MAX_TASKS_PER_RUN="${MAX_TASKS_PER_RUN:-0}"
WORKTREE_PARENT="${WORKTREE_PARENT:-$(dirname "${REPO_ROOT}")}"
WORKTREE_PREFIX="${WORKTREE_PREFIX:-longrun}"
WORKTREE_BRANCH_PREFIX="${WORKTREE_BRANCH_PREFIX:-codex/longrun}"
RUN_ID="${RUN_ID:-$(date +%Y%m%d-%H%M%S)}"
RUNS_DIR="${RUNS_DIR:-ops/hermes-longrun/runs}"
RUN_DIR="${RUN_DIR:-${REPO_ROOT}/${RUNS_DIR}/${RUN_ID}}"
PIPELINE_LOG="${RUN_DIR}/pipeline.log"
BLOCKED_TASKS_FILE="${RUN_DIR}/blocked-tasks.md"
RECOVERY_DECISIONS_FILE="${RUN_DIR}/recovery-decisions.md"
CONTINUE_ON_BLOCKED="${CONTINUE_ON_BLOCKED:-1}"
SKIP_DEPENDENTS_ON_BLOCKED="${SKIP_DEPENDENTS_ON_BLOCKED:-1}"
USE_HERMES_KANBAN="${USE_HERMES_KANBAN:-1}"
DRY_RUN="${DRY_RUN:-0}"
AUTO_PLAN_FROM_REQUIREMENTS="${AUTO_PLAN_FROM_REQUIREMENTS:-1}"
REQUIREMENTS_DOC="${REQUIREMENTS_DOC:-ops/hermes-longrun/requirements.md}"
AUTO_PLAN_ARTIFACT_DIR="${AUTO_PLAN_ARTIFACT_DIR:-ops/hermes-longrun/generated}"
AUTO_SETUP_KANBAN="${AUTO_SETUP_KANBAN:-1}"
ACTIVE_LONGRUN_DIR="${LONGRUN_DIR}"
ACTIVE_SCRIPT_DIR="${SCRIPT_DIR}"

mkdir -p "${RUN_DIR}"
exec > >(tee -a "${PIPELINE_LOG}") 2>&1

log() {
  printf '[pipeline] %s\n' "$*"
}

fail() {
  printf '[pipeline][ERROR] %s\n' "$*" >&2
  exit 1
}

task_rows() {
  grep '^TASK|' "${ACTIVE_LONGRUN_DIR}/task-queue.md" || true
}

task_sequence() {
  if [[ -n "${TASK_SEQUENCE:-}" ]]; then
    printf '%s\n' ${TASK_SEQUENCE}
    return 0
  fi
  python3 - "${ACTIVE_LONGRUN_DIR}/task-queue.md" <<'PY'
import sys
from collections import defaultdict, deque

path = sys.argv[1]
order = []
deps = defaultdict(list)
revs = defaultdict(set)
known = set()

with open(path, "r", encoding="utf-8") as fh:
    for raw in fh:
        line = raw.rstrip("\n")
        if not line.startswith("TASK|"):
            continue
        parts = line.split("|")
        if len(parts) < 6:
            continue
        key = parts[1].strip()
        if not key:
            continue
        order.append(key)
        known.add(key)
        dep_field = parts[4].strip() if len(parts) > 4 else ""
        for dep in dep_field.split(","):
            dep = dep.strip()
            if dep:
                deps[key].append(dep)

for key in known:
    for dep in deps.get(key, []):
        if dep not in known:
            print(f"[task_sequence][ERROR] task {key} depends on unknown task {dep}", file=sys.stderr)
            sys.exit(2)
        revs[dep].add(key)

# Kahn's algorithm preserving the file order to keep output deterministic.
indeg = {k: len(deps.get(k, [])) for k in order}
queue = deque(k for k in order if indeg[k] == 0)
result = []
while queue:
    node = queue.popleft()
    result.append(node)
    for child in order:
        if child not in revs[node]:
            continue
        indeg[child] -= 1
        if indeg[child] == 0:
            queue.append(child)

if len(result) != len(order):
    remaining = [k for k in order if k not in result]
    print(f"[task_sequence][ERROR] dependency cycle detected; unresolved tasks: {remaining}", file=sys.stderr)
    sys.exit(2)

for k in result:
    print(k)
PY
}

task_field_for() {
  local key="$1"
  local index="$2"
  awk -F'|' -v key="${key}" -v index="${index}" '$1 == "TASK" && $2 == key { print $index; exit }' "${ACTIVE_LONGRUN_DIR}/task-queue.md"
}

task_doc_for() {
  task_field_for "$1" 4
}

task_dependencies() {
  local deps
  deps="$(task_field_for "$1" 5)"
  python3 - "$deps" <<'PY'
import sys
for item in sys.argv[1].split(","):
    item = item.strip()
    if item:
        print(item)
PY
}

task_in_words() {
  local needle="$1"
  local item
  for item in ${2:-}; do
    [[ "${item}" == "${needle}" ]] && return 0
  done
  return 1
}

first_blocked_dependency() {
  local key="$1"
  local blocked="$2"
  local dep
  while IFS= read -r dep; do
    [[ -z "${dep}" ]] && continue
    if task_in_words "${dep}" "${blocked}"; then
      printf '%s' "${dep}"
      return 0
    fi
  done < <(task_dependencies "${key}")
  return 1
}

task_var_name() {
  local key="$1"
  key="${key//-/_}"
  key="${key//./_}"
  printf 'HERMES_TASK_ID_%s' "${key}"
}

kanban_task_id_for() {
  local key="$1"
  local var
  var="$(task_var_name "${key}")"
  printf '%s' "${!var:-}"
}

complete_kanban_task() {
  local key="$1"
  local summary_file="$2"
  [[ "${USE_HERMES_KANBAN}" == "1" && "${DRY_RUN}" != "1" ]] || return 0
  local task_id
  task_id="$(kanban_task_id_for "${key}")"
  [[ -z "${task_id}" ]] && return 0
  local summary
  summary="$(head -c 3500 "${summary_file}" 2>/dev/null || true)"
  hermes kanban complete "${task_id}" \
    --result "${key} completed by run ${RUN_ID}" \
    --summary "${summary}" >/dev/null 2>&1 || true
}

block_kanban_task() {
  local key="$1"
  local reason="$2"
  [[ "${USE_HERMES_KANBAN}" == "1" && "${DRY_RUN}" != "1" ]] || return 0
  local task_id
  task_id="$(kanban_task_id_for "${key}")"
  [[ -z "${task_id}" ]] && return 0
  hermes kanban block "${task_id}" "${reason}" >/dev/null 2>&1 || true
}

snapshot_blocked_task_diff() {
  local key="$1"
  local task_dir="${RUN_DIR}/${key}"
  mkdir -p "${task_dir}"

  git -C "${WORKTREE_DIR}" status --short >"${task_dir}/blocked-worktree-status.txt" 2>/dev/null || true
  git -C "${WORKTREE_DIR}" diff --cached --binary >"${task_dir}/blocked-staged.patch" 2>/dev/null || true
  git -C "${WORKTREE_DIR}" add -N . >/dev/null 2>&1 || true
  git -C "${WORKTREE_DIR}" diff --binary >"${task_dir}/blocked-worktree.patch" 2>/dev/null || true
}

reset_after_blocked_task() {
  git -C "${WORKTREE_DIR}" restore --staged --worktree -- . >/dev/null 2>&1 || true
  git -C "${WORKTREE_DIR}" clean -fd >/dev/null 2>&1 || true
}

record_blocked_task() {
  local key="$1"
  local exit_code="$2"
  local summary_file="${RUN_DIR}/${key}/summary.md"
  local task_dir="${RUN_DIR}/${key}"

  {
    printf '\n## %s\n\n' "${key}"
    printf -- '- exit_code: %s\n' "${exit_code}"
    printf -- '- summary: %s\n' "${summary_file}"
    printf -- '- escalation: %s\n' "${task_dir}/escalation.md"
    printf -- '- preserved_staged_patch: %s\n' "${task_dir}/blocked-staged.patch"
    printf -- '- preserved_worktree_patch: %s\n' "${task_dir}/blocked-worktree.patch"
    printf -- '- preserved_status: %s\n\n' "${task_dir}/blocked-worktree-status.txt"
    if [[ -f "${summary_file}" ]]; then
      printf 'Summary excerpt:\n\n'
      sed -n '1,80p' "${summary_file}"
      printf '\n'
    fi
  } >>"${BLOCKED_TASKS_FILE}"
}

record_dependency_blocked_task() {
  local key="$1"
  local dependency="$2"
  local task_dir="${RUN_DIR}/${key}"
  local summary_file="${task_dir}/summary.md"
  mkdir -p "${task_dir}"

  {
    printf '# %s summary\n\n' "${key}"
    printf '%s\n' '- verdict: SKIPPED_DEPENDENCY'
    printf '%s\n' "- blocked_dependency: ${dependency}"
    printf '%s\n' "- task doc: $(task_doc_for "${key}")"
  } >"${summary_file}"

  {
    printf '\n## %s\n\n' "${key}"
    printf -- '- exit_code: dependency\n'
    printf -- '- verdict: SKIPPED_DEPENDENCY\n'
    printf -- '- blocked_dependency: %s\n' "${dependency}"
    printf -- '- summary: %s\n\n' "${summary_file}"
    printf 'This task was not run because an upstream dependency was blocked.\n'
  } >>"${BLOCKED_TASKS_FILE}"
}

repo_relpath() {
  local path="$1"
  local root="${2:-${REPO_ROOT}}"
  python3 - "$path" "$root" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1]).resolve(strict=False)
root = Path(sys.argv[2]).resolve(strict=False)
try:
    print(path.relative_to(root))
except ValueError:
    raise SystemExit(1)
PY
}

repo_path_for_config() {
  local root="$1"
  local configured="$2"
  python3 - "$root" "$configured" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1]).resolve()
path = Path(sys.argv[2]).expanduser()
if not path.is_absolute():
    path = root / path
print(path.resolve(strict=False))
PY
}

sync_file_to_worktree() {
  local rel="$1"
  local src="${REPO_ROOT}/${rel}"
  local dest="${WORKTREE_DIR}/${rel}"
  [[ -f "${src}" ]] || return 0
  mkdir -p "$(dirname "${dest}")"
  cp "${src}" "${dest}"
}

sync_runtime_inputs_to_worktree() {
  local longrun_rel="$1"
  sync_file_to_worktree "${longrun_rel}/config.env"
  sync_file_to_worktree "${REQUIREMENTS_REL}"
}

task_queue_needs_auto_plan() {
  [[ "${AUTO_PLAN_FROM_REQUIREMENTS}" == "1" ]] || return 1
  local queue="${ACTIVE_LONGRUN_DIR}/task-queue.md"
  [[ ! -f "${queue}" ]] && return 0
  if grep -q '^TASK|EX-001|' "${queue}"; then
    return 0
  fi
  if ! grep -q '^TASK|' "${queue}"; then
    return 0
  fi
  return 1
}

generate_and_commit_task_plan() {
  log "auto planning from requirements: ${REQUIREMENTS_REL}"
  RUN_ID="${RUN_ID}" RUN_DIR="${RUN_DIR}" "${ACTIVE_SCRIPT_DIR}/generate-task-plan.sh"

  git -C "${WORKTREE_DIR}" add -- \
    "${REQUIREMENTS_REL}" \
    "${TASK_QUEUE_REL}" \
    "${AUTO_PLAN_ARTIFACT_REL}"

  if git -C "${WORKTREE_DIR}" diff --cached --quiet; then
    fail "auto planning produced no committable plan changes"
  fi

  git -C "${WORKTREE_DIR}" commit -m "longrun: generate task plan from requirements"
  log "committed generated task plan"
}

log "run id: ${RUN_ID}"
log "repo root: ${REPO_ROOT}"
log "source longrun dir: ${LONGRUN_DIR}"
log "execution mode: serial (plus variant; dependency graph drives topological order)"
log "continue on blocked: ${CONTINUE_ON_BLOCKED}"

timestamp="$(date +%Y%m%d-%H%M%S)"
BRANCH="${BRANCH:-${WORKTREE_BRANCH_PREFIX}-${timestamp}}"
WORKTREE_DIR="${WORKTREE_DIR:-${WORKTREE_PARENT}/${WORKTREE_PREFIX}-${timestamp}}"

if [[ -d "${WORKTREE_DIR}/.git" || -f "${WORKTREE_DIR}/.git" ]]; then
  log "using existing worktree: ${WORKTREE_DIR}"
else
  log "creating worktree ${WORKTREE_DIR} on branch ${BRANCH}"
  git -C "${REPO_ROOT}" worktree add -b "${BRANCH}" "${WORKTREE_DIR}" HEAD
fi

LONGRUN_REL="$(repo_relpath "${LONGRUN_DIR}" "${REPO_ROOT}")" || fail "long-run directory must be inside repository"
ACTIVE_LONGRUN_DIR="${WORKTREE_DIR}/${LONGRUN_REL}"
ACTIVE_SCRIPT_DIR="${ACTIVE_LONGRUN_DIR}/scripts"
REQUIREMENTS_PATH="$(repo_path_for_config "${REPO_ROOT}" "${REQUIREMENTS_DOC}")"
REQUIREMENTS_REL="$(repo_relpath "${REQUIREMENTS_PATH}" "${REPO_ROOT}")" || fail "REQUIREMENTS_DOC must be inside repository"
AUTO_PLAN_ARTIFACT_PATH="$(repo_path_for_config "${REPO_ROOT}" "${AUTO_PLAN_ARTIFACT_DIR}")"
AUTO_PLAN_ARTIFACT_REL="$(repo_relpath "${AUTO_PLAN_ARTIFACT_PATH}" "${REPO_ROOT}")" || fail "AUTO_PLAN_ARTIFACT_DIR must be inside repository"
TASK_QUEUE_REL="${LONGRUN_REL}/task-queue.md"

sync_runtime_inputs_to_worktree "${LONGRUN_REL}"

if task_queue_needs_auto_plan; then
  generate_and_commit_task_plan
else
  log "using existing task queue; auto planning skipped"
fi

if [[ "${USE_HERMES_KANBAN}" == "1" && "${AUTO_SETUP_KANBAN}" == "1" && "${DRY_RUN}" != "1" ]]; then
  log "setting up Hermes kanban from active task plan"
  "${ACTIVE_SCRIPT_DIR}/setup-hermes-kanban.sh"
fi

if [[ -f "${ACTIVE_LONGRUN_DIR}/runs/kanban-task-map.env" ]]; then
  # shellcheck disable=SC1091
  source "${ACTIVE_LONGRUN_DIR}/runs/kanban-task-map.env"
fi

planned_sequence="$(task_sequence | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
if [[ -n "${planned_sequence}" ]]; then
  log "planned task sequence: ${planned_sequence}"
fi

if [[ "${RUN_PREFLIGHT}" == "1" ]]; then
  log "running preflight"
  REQUIRE_KANBAN="${USE_HERMES_KANBAN}" "${ACTIVE_SCRIPT_DIR}/preflight.sh"
fi

{
  printf 'RUN_ID=%q\n' "${RUN_ID}"
  printf 'REPO_ROOT=%q\n' "${REPO_ROOT}"
  printf 'WORKTREE_DIR=%q\n' "${WORKTREE_DIR}"
  printf 'BRANCH=%q\n' "${BRANCH}"
  printf 'ACTIVE_LONGRUN_DIR=%q\n' "${ACTIVE_LONGRUN_DIR}"
  printf 'HERMES_BOARD=%q\n' "${HERMES_BOARD:-}"
  printf 'CONTINUE_ON_BLOCKED=%q\n' "${CONTINUE_ON_BLOCKED}"
  printf 'SKIP_DEPENDENTS_ON_BLOCKED=%q\n' "${SKIP_DEPENDENTS_ON_BLOCKED}"
  printf 'BLOCKED_TASKS_FILE=%q\n' "${BLOCKED_TASKS_FILE}"
  printf 'RECOVERY_DECISIONS_FILE=%q\n' "${RECOVERY_DECISIONS_FILE}"
} >"${RUN_DIR}/run.env"

{
  printf '# Blocked tasks for run %s\n\n' "${RUN_ID}"
  printf 'Tasks listed here exhausted automated attempts, requested human intervention, or were skipped because an upstream dependency was blocked. Directly blocked task patches are preserved before the worktree resets.\n'
} >"${BLOCKED_TASKS_FILE}"

{
  printf '# Recovery decisions for run %s\n\n' "${RUN_ID}"
  printf 'This file records recovery-diagnose decisions, scoped acceptances, and recovered tasks. A task belongs in blocked-tasks.md only after recovery cannot safely continue.\n'
} >"${RECOVERY_DECISIONS_FILE}"

count=0
blocked_count=0
blocked_tasks=""
last_blocked_task=""
while IFS= read -r task; do
  [[ -z "${task}" ]] && continue
  count=$((count + 1))
  if (( MAX_TASKS_PER_RUN > 0 && count > MAX_TASKS_PER_RUN )); then
    log "MAX_TASKS_PER_RUN=${MAX_TASKS_PER_RUN} reached; stopping"
    break
  fi

  if [[ "${SKIP_DEPENDENTS_ON_BLOCKED}" == "1" ]]; then
    blocked_dependency="$(first_blocked_dependency "${task}" "${blocked_tasks}" || true)"
    if [[ -n "${blocked_dependency}" ]]; then
      blocked_count=$((blocked_count + 1))
      blocked_tasks="${blocked_tasks:+${blocked_tasks} }${task}"
      last_blocked_task="${task}"
      log "skipping ${task}; upstream dependency ${blocked_dependency} is blocked"
      record_dependency_blocked_task "${task}" "${blocked_dependency}"
      block_kanban_task "${task}" "run ${RUN_ID} skipped this task because dependency ${blocked_dependency} is blocked; see ${RUN_DIR}/${task}/summary.md"
      continue
    fi
  fi

  log "starting ${task}"
  if REPO_WORKDIR="${WORKTREE_DIR}" \
    ORCH_REPO_ROOT="${WORKTREE_DIR}" \
    RUN_ID="${RUN_ID}" \
    RUN_DIR="${RUN_DIR}" \
    DRY_RUN="${DRY_RUN}" \
    BLOCKED_TASKS="${blocked_tasks}" \
    BLOCKED_TASKS_REPORT="${BLOCKED_TASKS_FILE}" \
    RECOVERY_DECISIONS_FILE="${RECOVERY_DECISIONS_FILE}" \
    "${ACTIVE_SCRIPT_DIR}/run-one-task.sh" "${task}"; then
    log "${task} completed"
    complete_kanban_task "${task}" "${RUN_DIR}/${task}/summary.md"
  else
    task_exit=$?
    last_blocked_task="${task}"
    blocked_count=$((blocked_count + 1))
    blocked_tasks="${blocked_tasks:+${blocked_tasks} }${task}"
    log "${task} failed or blocked after automated attempts; preserving patch and recording for human review"
    snapshot_blocked_task_diff "${task}"
    record_blocked_task "${task}" "${task_exit}"
    block_kanban_task "${task}" "run ${RUN_ID} blocked this task and continued; see ${RUN_DIR}/${task}/summary.md and ${BLOCKED_TASKS_FILE}"
    if [[ "${CONTINUE_ON_BLOCKED}" == "1" ]]; then
      reset_after_blocked_task
      log "continuing after blocked task ${task}; dependency guard will skip unhealthy downstream tasks"
      continue
    fi
    log "CONTINUE_ON_BLOCKED=${CONTINUE_ON_BLOCKED}; stopping pipeline after ${task}"
    break
  fi
done < <(task_sequence)

final_prompt="${RUN_DIR}/final-review.prompt.md"
{
  cat "${ACTIVE_LONGRUN_DIR}/prompts/final-review.md"
  printf '\n\nRun directory: %s\n' "${RUN_DIR}"
  printf 'Worktree: %s\n' "${WORKTREE_DIR}"
  printf 'Branch: %s\n' "${BRANCH}"
  printf 'Blocked tasks report: %s\n' "${BLOCKED_TASKS_FILE}"
  printf 'Recovery decisions report: %s\n' "${RECOVERY_DECISIONS_FILE}"
  if [[ -n "${blocked_tasks}" ]]; then
    printf 'Blocked tasks: %s\n' "${blocked_tasks}"
  fi
  if [[ -n "${last_blocked_task}" ]]; then
    printf 'Last blocked task: %s\n' "${last_blocked_task}"
  fi
} >"${final_prompt}"

if [[ "${DRY_RUN}" == "1" ]]; then
  {
    printf 'DRY_RUN final review\n'
    cat "${final_prompt}"
  } >"${RUN_DIR}/final-report.md"
else
  log "running final read-only Codex review"
  codex exec \
    --ephemeral \
    --cd "${WORKTREE_DIR}" \
    --sandbox read-only \
    -m "${CODEX_MODEL}" \
    -c "model_reasoning_effort=\"${CODEX_ANALYZE_EFFORT}\"" \
    -o "${RUN_DIR}/final-report.md" \
    - <"${final_prompt}" >"${RUN_DIR}/final-review.log" 2>&1 || true
fi

log "pipeline finished"
log "worktree: ${WORKTREE_DIR}"
log "branch: ${BRANCH}"
log "run dir: ${RUN_DIR}"
if [[ "${blocked_count}" != "0" ]]; then
  log "blocked tasks: ${blocked_tasks}"
  log "blocked tasks report: ${BLOCKED_TASKS_FILE}"
fi
log "recovery decisions report: ${RECOVERY_DECISIONS_FILE}"

if [[ "${blocked_count}" != "0" ]]; then
  exit 3
fi
