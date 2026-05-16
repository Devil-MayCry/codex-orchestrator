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

RUN_ID="${RUN_ID:-$(date +%Y%m%d-%H%M%S)}"
RUNS_DIR="${RUNS_DIR:-ops/hermes-longrun/runs}"
RUN_DIR="${RUN_DIR:-${REPO_ROOT}/${RUNS_DIR}/${RUN_ID}}"
SUPERVISOR_ENV="${RUN_DIR}/supervisor.env"
SUPERVISOR_LOG="${RUN_DIR}/supervisor.log"
LAUNCH_SCRIPT="${RUN_DIR}/supervisor-launch.sh"
CURRENT_ENV="${REPO_ROOT}/${RUNS_DIR}/current-supervisor.env"
RECOVER_INTERRUPTED_WORKTREE="${RECOVER_INTERRUPTED_WORKTREE:-1}"
SUPERVISOR_DETACH_METHOD="${SUPERVISOR_DETACH_METHOD:-screen}"

mkdir -p "${RUN_DIR}" "${REPO_ROOT}/${RUNS_DIR}"

screen_session_alive() {
  local session="$1"
  local listing=""
  [[ -n "${session}" ]] || return 1
  command -v screen >/dev/null 2>&1 || return 1
  listing="$(screen -ls 2>/dev/null || true)"
  awk -v session="${session}" '
    {
      dot = index($1, ".")
      if (dot > 0 && substr($1, dot + 1) == session) {
        found = 1
      }
    }
    END { exit(found ? 0 : 1) }
  ' <<<"${listing}"
}

active_from_current() {
  [[ -f "${CURRENT_ENV}" ]] || return 1
  local current_pid current_session current_run_dir
  current_pid="$(bash -c 'source "$1"; printf "%s" "${PIPELINE_PID:-}"' bash "${CURRENT_ENV}")"
  current_session="$(bash -c 'source "$1"; printf "%s" "${SCREEN_SESSION:-}"' bash "${CURRENT_ENV}")"
  current_run_dir="$(bash -c 'source "$1"; printf "%s" "${RUN_DIR:-}"' bash "${CURRENT_ENV}")"
  if [[ -n "${current_pid}" ]] && kill -0 "${current_pid}" 2>/dev/null; then
    ACTIVE_REF="pid=${current_pid}"
    ACTIVE_RUN_DIR="${current_run_dir}"
    return 0
  fi
  if screen_session_alive "${current_session}"; then
    ACTIVE_REF="screen=${current_session}"
    ACTIVE_RUN_DIR="${current_run_dir}"
    return 0
  fi
  return 1
}

resolve_interrupted_worktree() {
  [[ -z "${WORKTREE_DIR:-}" ]] || return 0
  [[ -f "${CURRENT_ENV}" ]] || return 0

  local previous_run_dir previous_worktree
  previous_run_dir="$(bash -c 'source "$1"; printf "%s" "${RUN_DIR:-}"' bash "${CURRENT_ENV}")"
  [[ -n "${previous_run_dir}" && -f "${previous_run_dir}/run.env" ]] || return 0

  previous_worktree="$(bash -c 'source "$1"; printf "%s" "${WORKTREE_DIR:-}"' bash "${previous_run_dir}/run.env")"
  if [[ -n "${previous_worktree}" ]]; then
    WORKTREE_DIR="${previous_worktree}"
  fi
}

preserve_and_reset_dirty_worktree() {
  [[ "${RECOVER_INTERRUPTED_WORKTREE}" == "1" ]] || return 0
  resolve_interrupted_worktree
  [[ -n "${WORKTREE_DIR:-}" ]] || return 0
  [[ -d "${WORKTREE_DIR}" ]] || return 0
  [[ -n "$(git -C "${WORKTREE_DIR}" status --porcelain 2>/dev/null || true)" ]] || return 0

  local recovery_dir="${RUN_DIR}/interrupted-worktree-recovery"
  mkdir -p "${recovery_dir}"
  git -C "${WORKTREE_DIR}" status --short >"${recovery_dir}/status.txt" 2>/dev/null || true
  git -C "${WORKTREE_DIR}" diff --cached --binary >"${recovery_dir}/staged.patch" 2>/dev/null || true
  git -C "${WORKTREE_DIR}" add -N . >/dev/null 2>&1 || true
  git -C "${WORKTREE_DIR}" diff --binary >"${recovery_dir}/worktree.patch" 2>/dev/null || true
  git -C "${WORKTREE_DIR}" restore --staged --worktree -- . >/dev/null 2>&1 || true
  git -C "${WORKTREE_DIR}" clean -fd >/dev/null 2>&1 || true

  {
    printf '[supervisor] preserved interrupted dirty worktree before restart\n'
    printf '[supervisor] worktree: %s\n' "${WORKTREE_DIR}"
    printf '[supervisor] recovery: %s\n' "${recovery_dir}"
  } >>"${SUPERVISOR_LOG}"
}

if active_from_current; then
  printf '[supervisor] active pipeline already running: %s run_dir=%s\n' "${ACTIVE_REF}" "${ACTIVE_RUN_DIR:-}"
  exit 0
fi

preserve_and_reset_dirty_worktree

{
  printf 'RUN_ID=%q\n' "${RUN_ID}"
  printf 'RUN_DIR=%q\n' "${RUN_DIR}"
  printf 'REPO_ROOT=%q\n' "${REPO_ROOT}"
  printf 'STARTED_AT=%q\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
  printf 'SUPERVISOR_LOG=%q\n' "${SUPERVISOR_LOG}"
} >"${SUPERVISOR_ENV}"

write_export_if_set() {
  local key="$1"
  [[ -n "${!key+x}" ]] || return 0
  printf 'export %s=%q\n' "${key}" "${!key}" >>"${LAUNCH_SCRIPT}"
}

{
  printf '#!/usr/bin/env bash\n'
  printf 'set -Eeuo pipefail\n'
  printf 'cd %q\n' "${REPO_ROOT}"
  printf 'export RUN_ID=%q\n' "${RUN_ID}"
  printf 'export RUN_DIR=%q\n' "${RUN_DIR}"
} >"${LAUNCH_SCRIPT}"

for key in \
  CODEX_MODEL CODEX_ANALYZE_EFFORT CODEX_BUILD_EFFORT CODEX_VERIFY_EFFORT \
  CODEX_TRANSPORT_RETRIES CODEX_HEARTBEAT_SECONDS CODEX_PHASE_TIMEOUT_SECONDS \
  CODEX_SMOKE_EFFORTS MAX_TASKS_PER_RUN MAX_FIX_ATTEMPTS \
  RECOVERY_DECISION_ENGINE ALLOW_SCOPED_ACCEPT HERMES_DECISION_TIMEOUT_SECONDS \
  HERMES_DECISION_POLL_SECONDS COMMIT_SCOPE_ALLOW_PATTERNS FULL_TEST_COMMAND \
  AUTO_PLAN_FROM_REQUIREMENTS REQUIREMENTS_DOC AUTO_PLAN_ARTIFACT_DIR \
  AUTO_PLAN_DEFAULT_CHECKS AUTO_SETUP_KANBAN AUTO_PLAN_DRY_RUN \
  RUN_FULL_TESTS RUN_PREFLIGHT CONTINUE_ON_BLOCKED SKIP_DEPENDENTS_ON_BLOCKED \
  RUNS_DIR HERMES_BOARD USE_HERMES_KANBAN WORKTREE_PARENT WORKTREE_PREFIX \
  WORKTREE_BRANCH_PREFIX WORKTREE_DIR BRANCH TASK_SEQUENCE DRY_RUN DRY_RUN_BLOCK_TASKS \
  DRY_RUN_CHECK_FAILURE_KIND DRY_RUN_CHECK_FAILURE_ONCE DRY_RUN_CHECK_FAILURE_ATTEMPTS \
  DRY_RUN_RECOVERY_ACTION DRY_RUN_RECOVERY_ACTIONS DRY_RUN_VERIFY_VERDICT DRY_RUN_VERIFY_VERDICTS \
  DRY_RUN_DECIDE_AS_ADVISORY ALLOW_DIRTY_WORKTREE REQUIRED_COMMANDS PROJECT_PREFLIGHT_COMMANDS \
  SKIP_CODEX_SMOKE SKIP_HERMES_SMOKE; do
  write_export_if_set "${key}"
done

{
  printf 'exec %q >>%q 2>&1 </dev/null\n' \
    "${SCRIPT_DIR}/pipeline-background-worker.sh" \
    "${SUPERVISOR_LOG}"
} >>"${LAUNCH_SCRIPT}"
chmod +x "${LAUNCH_SCRIPT}"

SCREEN_SESSION=""
screen_session_name="longrun-${RUN_ID//[^A-Za-z0-9_.-]/-}"
if [[ "${SUPERVISOR_DETACH_METHOD}" == "screen" ]] && command -v screen >/dev/null 2>&1; then
  SCREEN_SESSION="${screen_session_name}"
  screen -dmS "${SCREEN_SESSION}" "${LAUNCH_SCRIPT}"
  printf 'SCREEN_SESSION=%q\n' "${SCREEN_SESSION}" >>"${SUPERVISOR_ENV}"
  printf 'PIPELINE_PID=%q\n' "" >>"${SUPERVISOR_ENV}"
else
  (
    cd "${REPO_ROOT}"
    nohup "${LAUNCH_SCRIPT}" >>"${SUPERVISOR_LOG}" 2>&1 </dev/null &
    pipeline_pid=$!
    printf 'PIPELINE_PID=%q\n' "${pipeline_pid}" >>"${SUPERVISOR_ENV}"
  )
fi

cp "${SUPERVISOR_ENV}" "${CURRENT_ENV}"

printf '[supervisor] started background pipeline\n'
printf '[supervisor] run_id=%s\n' "${RUN_ID}"
printf '[supervisor] run_dir=%s\n' "${RUN_DIR}"
printf '[supervisor] env=%s\n' "${SUPERVISOR_ENV}"
printf '[supervisor] log=%s\n' "${SUPERVISOR_LOG}"
if [[ -n "${SCREEN_SESSION:-}" ]]; then
  printf '[supervisor] screen_session=%s\n' "${SCREEN_SESSION}"
fi
