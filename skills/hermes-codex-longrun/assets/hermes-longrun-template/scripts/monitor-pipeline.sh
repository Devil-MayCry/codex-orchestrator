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

RUNS_DIR="${RUNS_DIR:-ops/hermes-longrun/runs}"
RUN_DIR="${1:-}"
if [[ -z "${RUN_DIR}" ]]; then
  if [[ -f "${REPO_ROOT}/${RUNS_DIR}/current-supervisor.env" ]]; then
    # shellcheck disable=SC1090
    source "${REPO_ROOT}/${RUNS_DIR}/current-supervisor.env"
  else
    RUN_DIR="$(ls -td "${REPO_ROOT}/${RUNS_DIR}"/[0-9]* 2>/dev/null | head -n 1 || true)"
  fi
fi

if [[ -z "${RUN_DIR}" || ! -d "${RUN_DIR}" ]]; then
  printf 'STATE=NO_RUN\n'
  exit 1
fi

SUPERVISOR_ENV="${RUN_DIR}/supervisor.env"
STATUS_FILE="${RUN_DIR}/supervisor-status.env"
PIPELINE_LOG="${RUN_DIR}/pipeline.log"
SUPERVISOR_LOG="${RUN_DIR}/supervisor.log"
FINAL_REPORT="${RUN_DIR}/final-report.md"
BLOCKED_TASKS="${RUN_DIR}/blocked-tasks.md"
RECOVERY_DECISIONS="${RUN_DIR}/recovery-decisions.md"

if [[ -f "${SUPERVISOR_ENV}" ]]; then
  # shellcheck disable=SC1090
  source "${SUPERVISOR_ENV}"
fi
if [[ -f "${STATUS_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${STATUS_FILE}"
fi

pid="${PIPELINE_PID:-}"
session="${SCREEN_SESSION:-}"
state="${STATE:-UNKNOWN}"

screen_session_alive() {
  local candidate="$1"
  local listing=""
  [[ -n "${candidate}" ]] || return 1
  command -v screen >/dev/null 2>&1 || return 1
  listing="$(screen -ls 2>/dev/null || true)"
  awk -v session="${candidate}" '
    {
      dot = index($1, ".")
      if (dot > 0 && substr($1, dot + 1) == session) {
        found = 1
      }
    }
    END { exit(found ? 0 : 1) }
  ' <<<"${listing}"
}

pipeline_process_alive() {
  local candidate_pid="$1"
  local run_dir="$2"
  if [[ -n "${candidate_pid}" ]] && kill -0 "${candidate_pid}" 2>/dev/null; then
    return 0
  fi
  command -v ps >/dev/null 2>&1 || return 1
  if [[ -n "${candidate_pid}" ]] && ps -p "${candidate_pid}" -o command= 2>/dev/null | awk '/pipeline-background-worker|run-pipeline|run-one-task|codex exec/ { found = 1 } END { exit(found ? 0 : 1) }'; then
    return 0
  fi
  if [[ -n "${run_dir}" ]] && ps -axo command= 2>/dev/null | awk -v run_dir="${run_dir}" '
    index($0, run_dir) &&
    $0 ~ /pipeline-background-worker|run-pipeline|run-one-task|codex exec/ &&
    $0 !~ /monitor-pipeline/ {
      found = 1
    }
    END { exit(found ? 0 : 1) }
  '; then
    return 0
  fi
  return 1
}

screen_alive=0
if screen_session_alive "${session}"; then
  screen_alive=1
fi

process_alive=0
if pipeline_process_alive "${pid}" "${RUN_DIR}"; then
  process_alive=1
fi

if [[ "${state}" == "RUNNING" || "${state}" == "AWAITING_DECISION" ]]; then
  if [[ "${screen_alive}" == "1" ]]; then
    :
  elif [[ "${process_alive}" == "1" ]]; then
    :
  else
    state="ORPHANED"
  fi
fi

printf 'STATE=%s\n' "${state}"
printf 'RUN_DIR=%s\n' "${RUN_DIR}"
printf 'PIPELINE_PID=%s\n' "${pid:-}"
printf 'SCREEN_SESSION=%s\n' "${session:-}"
printf 'SCREEN_ALIVE=%s\n' "${screen_alive}"
printf 'PROCESS_ALIVE=%s\n' "${process_alive}"
printf 'EXIT_CODE=%s\n' "${EXIT_CODE:-}"

if [[ -f "${PIPELINE_LOG}" ]]; then
  printf 'PIPELINE_LOG=%s\n' "${PIPELINE_LOG}"
  printf 'PIPELINE_LOG_MTIME=%s\n' "$(stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S %Z' "${PIPELINE_LOG}" 2>/dev/null || stat -c '%y' "${PIPELINE_LOG}")"
  printf '\n--- pipeline tail ---\n'
  tail -n "${MONITOR_TAIL_LINES:-80}" "${PIPELINE_LOG}"
else
  printf 'PIPELINE_LOG_MISSING=1\n'
fi

if [[ -f "${SUPERVISOR_LOG}" ]]; then
  printf '\n--- supervisor tail ---\n'
  tail -n 40 "${SUPERVISOR_LOG}"
fi

AWAITING_DIR="${RUN_DIR}/awaiting-decisions"
if compgen -G "${AWAITING_DIR}/*.env" >/dev/null 2>&1; then
  printf '\n--- awaiting decisions ---\n'
  now_epoch="$(date +%s)"
  for marker in "${AWAITING_DIR}"/*.env; do
    [[ -f "${marker}" ]] || continue
    awaiting_task="$(awk -F= '$1=="TASK"{sub(/^[^=]*=/,""); gsub(/^"|"$/,""); print; exit}' "${marker}")"
    awaiting_attempt="$(awk -F= '$1=="ATTEMPT"{sub(/^[^=]*=/,""); gsub(/^"|"$/,""); print; exit}' "${marker}")"
    awaiting_default="$(awk -F= '$1=="DEFAULT_ACTION"{sub(/^[^=]*=/,""); gsub(/^"|"$/,""); print; exit}' "${marker}")"
    awaiting_advisory="$(awk -F= '$1=="ADVISORY_PATH"{sub(/^[^=]*=/,""); gsub(/^"|"$/,""); print; exit}' "${marker}")"
    awaiting_deadline="$(awk -F= '$1=="DEADLINE_EPOCH"{sub(/^[^=]*=/,""); gsub(/^"|"$/,""); print; exit}' "${marker}")"
    remaining=""
    if [[ -n "${awaiting_deadline}" ]]; then
      remaining=$(( awaiting_deadline - now_epoch ))
    fi
    printf '\nTASK=%s ATTEMPT=%s DEFAULT_ACTION=%s REMAINING=%ss\n' \
      "${awaiting_task}" "${awaiting_attempt}" "${awaiting_default}" "${remaining}"
    printf 'ADVISORY=%s\n' "${awaiting_advisory}"
    if [[ -f "${awaiting_advisory}" ]]; then
      printf '%s\n' '--- advisory head ---'
      sed -n '1,60p' "${awaiting_advisory}"
      printf '\n'
    fi
    longrun_dir_for_decide="$(cd "${SCRIPT_DIR}/.." && pwd)"
    decide_path="${longrun_dir_for_decide}/scripts/decide-recovery.sh"
    printf 'Decide examples (Hermes runs ONE of these):\n'
    printf '  bash %s --run-dir %s --task %s --attempt %s --action RECOVER_BUILD --reason "..."\n' \
      "${decide_path}" "${RUN_DIR}" "${awaiting_task}" "${awaiting_attempt}"
    printf '  bash %s --run-dir %s --task %s --attempt %s --action RECOVER_CHECKS --checks "<cmd>" --reason "..."\n' \
      "${decide_path}" "${RUN_DIR}" "${awaiting_task}" "${awaiting_attempt}"
    printf '  bash %s --run-dir %s --task %s --attempt %s --action ACCEPT_SCOPED --accept-failed "<failed-cmd>" --reason "..."\n' \
      "${decide_path}" "${RUN_DIR}" "${awaiting_task}" "${awaiting_attempt}"
    printf '  bash %s --run-dir %s --task %s --attempt %s --action BLOCKED --reason "..."\n' \
      "${decide_path}" "${RUN_DIR}" "${awaiting_task}" "${awaiting_attempt}"
  done
fi

if [[ -f "${BLOCKED_TASKS}" ]]; then
  printf '\n--- blocked tasks ---\n'
  sed -n '1,220p' "${BLOCKED_TASKS}"
fi

if [[ -f "${RECOVERY_DECISIONS}" ]]; then
  printf '\n--- recovery decisions ---\n'
  sed -n '1,220p' "${RECOVERY_DECISIONS}"
fi

if [[ -f "${FINAL_REPORT}" ]]; then
  printf '\n--- final report ---\n'
  sed -n '1,220p' "${FINAL_REPORT}"
fi
