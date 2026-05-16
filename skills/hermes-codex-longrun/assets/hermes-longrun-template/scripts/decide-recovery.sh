#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LONGRUN_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

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

RUN_FULL_TESTS="${RUN_FULL_TESTS:-0}"
FULL_TEST_COMMAND="${FULL_TEST_COMMAND:-}"

usage() {
  cat <<'EOF'
decide-recovery.sh - Hermes records the final recovery decision for a waiting task.

Usage:
  decide-recovery.sh --run-dir <path> --task <id> --attempt <n> \
                     --action <RECOVER_BUILD|RECOVER_CHECKS|ACCEPT_SCOPED|BLOCKED> \
                     [--checks 'cmd1 &&& cmd2'] \
                     [--accept-failed 'cmd1 &&& cmd2'] \
                     [--reason 'short reason']

Notes:
- --run-dir is the run directory printed by start-supervised-pipeline.sh.
- --task and --attempt must match the awaiting marker (monitor-pipeline.sh prints both).
- --checks is required for RECOVER_CHECKS and is rejected for the other actions.
  Each command must already exist in the task's target_checks (the runner cross-checks).
- --accept-failed lists failed check commands the runner is allowed to ignore when
  ACCEPT_SCOPED is chosen and the failures are not the configured FULL_TEST_COMMAND.
EOF
}

RUN_DIR=""
TASK=""
ATTEMPT=""
ACTION=""
CHECKS=""
ACCEPT_FAILED=""
REASON=""

while (( $# > 0 )); do
  case "$1" in
    --run-dir)        RUN_DIR="$2"; shift 2 ;;
    --task)           TASK="$2"; shift 2 ;;
    --attempt)        ATTEMPT="$2"; shift 2 ;;
    --action)         ACTION="$2"; shift 2 ;;
    --checks)         CHECKS="$2"; shift 2 ;;
    --accept-failed)  ACCEPT_FAILED="$2"; shift 2 ;;
    --reason)         REASON="$2"; shift 2 ;;
    -h|--help)        usage; exit 0 ;;
    *) printf '[decide-recovery][ERROR] unknown argument: %s\n' "$1" >&2; usage >&2; exit 64 ;;
  esac
done

fail() {
  printf '[decide-recovery][ERROR] %s\n' "$*" >&2
  exit 1
}

[[ -n "${RUN_DIR}" ]] || fail "--run-dir is required"
[[ -n "${TASK}" ]] || fail "--task is required"
[[ -n "${ATTEMPT}" ]] || fail "--attempt is required"
[[ -n "${ACTION}" ]] || fail "--action is required"

[[ -d "${RUN_DIR}" ]] || fail "RUN_DIR does not exist: ${RUN_DIR}"

case "${ACTION}" in
  RECOVER_BUILD|RECOVER_CHECKS|ACCEPT_SCOPED|BLOCKED) ;;
  *) fail "invalid --action: ${ACTION}. Allowed: RECOVER_BUILD RECOVER_CHECKS ACCEPT_SCOPED BLOCKED" ;;
esac

PADDED="$(printf '%02d' "${ATTEMPT#0}")" || fail "--attempt must be numeric"

TASK_RUN_DIR="${RUN_DIR}/${TASK}"
[[ -d "${TASK_RUN_DIR}" ]] || fail "task directory not found: ${TASK_RUN_DIR}"

AWAITING="${TASK_RUN_DIR}/awaiting-decision.env"
[[ -f "${AWAITING}" ]] || fail "no awaiting decision marker for task=${TASK} attempt=${PADDED}; nothing to record (looked at ${AWAITING})"

marker_field() {
  local key="$1"
  awk -F= -v key="${key}" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "${AWAITING}" | sed -e 's/^"//' -e 's/"$//'
}

MARKER_TASK="$(marker_field TASK)"
MARKER_ATTEMPT="$(marker_field ATTEMPT)"
[[ "${MARKER_TASK}" == "${TASK}" ]] || fail "task mismatch with awaiting marker (marker=${MARKER_TASK} arg=${TASK})"
[[ "${MARKER_ATTEMPT}" == "${PADDED}" ]] || fail "attempt mismatch with awaiting marker (marker=${MARKER_ATTEMPT} arg=${PADDED})"

ADVISORY_PATH="${TASK_RUN_DIR}/recovery-advisory-attempt-${PADDED}.md"
DECISION_ENV="${TASK_RUN_DIR}/decision-attempt-${PADDED}.env"
CHECKS_LOG="${TASK_RUN_DIR}/checks-attempt-${PADDED}.log"

if [[ "${ACTION}" == "RECOVER_CHECKS" ]]; then
  [[ -n "${CHECKS}" ]] || fail "RECOVER_CHECKS requires --checks"
fi

if [[ "${ACTION}" != "RECOVER_CHECKS" && -n "${CHECKS}" ]]; then
  fail "--checks is only valid with --action RECOVER_CHECKS"
fi

split_pipeline() {
  printf '%s\n' "$1" | sed 's/ &&& /\n/g'
}

configured_target_checks() {
  split_pipeline "${TASK_CHECKS}"
  if [[ "${RUN_FULL_TESTS}" == "1" && -n "${FULL_TEST_COMMAND}" ]]; then
    printf '%s\n' "${FULL_TEST_COMMAND}"
  fi
}

if [[ -n "${CHECKS}" ]]; then
  # Walk back from RUN_DIR to RUNS_DIR parent to locate task-queue.md
  RUNS_DIR_PARENT="$(dirname "$(dirname "${RUN_DIR}")")"
  TASK_QUEUE_FILE="${RUNS_DIR_PARENT}/task-queue.md"
  [[ -f "${TASK_QUEUE_FILE}" ]] || fail "cannot find task-queue.md (looked at ${TASK_QUEUE_FILE}); pass the absolute --run-dir from monitor output"

  TASK_ROW="$(awk -F'|' -v key="${TASK}" '$1=="TASK" && $2==key {print; exit}' "${TASK_QUEUE_FILE}")"
  [[ -n "${TASK_ROW}" ]] || fail "task ${TASK} not in ${TASK_QUEUE_FILE}"
  TASK_CHECKS="$(printf '%s\n' "${TASK_ROW}" | awk -F'|' '{print $6}')"

  while IFS= read -r candidate; do
    [[ -z "${candidate}" ]] && continue
    found=0
    while IFS= read -r allowed; do
      [[ -z "${allowed}" ]] && continue
      if [[ "${candidate}" == "${allowed}" ]]; then
        found=1
        break
      fi
    done < <(configured_target_checks)
    if [[ "${found}" != "1" ]]; then
      fail "--checks contains a command not in target_checks for ${TASK}: ${candidate}"
    fi
  done < <(split_pipeline "${CHECKS}")
fi

if [[ -n "${ACCEPT_FAILED}" ]]; then
  if [[ "${ACTION}" != "ACCEPT_SCOPED" ]]; then
    fail "--accept-failed is only valid with --action ACCEPT_SCOPED"
  fi
  if [[ ! -f "${CHECKS_LOG}" ]]; then
    fail "checks log missing; cannot validate --accept-failed: ${CHECKS_LOG}"
  fi
  while IFS= read -r entry; do
    [[ -z "${entry}" ]] && continue
    if ! grep -Fxq "[check failed] ${entry}" "${CHECKS_LOG}"; then
      fail "--accept-failed entry not present in checks log as failed: ${entry}"
    fi
  done < <(split_pipeline "${ACCEPT_FAILED}")
fi

DECIDED_AT="$(date '+%Y-%m-%dT%H:%M:%S%z')"
DECIDED_BY="${HERMES_DECIDED_BY:-hermes}"

TMP="${DECISION_ENV}.tmp.$$"
{
  printf 'TASK=%q\n' "${TASK}"
  printf 'ATTEMPT=%q\n' "${PADDED}"
  printf 'ACTION=%q\n' "${ACTION}"
  printf 'CHECKS=%q\n' "${CHECKS}"
  printf 'ACCEPT_FAILED=%q\n' "${ACCEPT_FAILED}"
  printf 'REASON=%q\n' "${REASON}"
  printf 'DECIDED_AT=%q\n' "${DECIDED_AT}"
  printf 'DECIDED_BY=%q\n' "${DECIDED_BY}"
} >"${TMP}"
mv "${TMP}" "${DECISION_ENV}"

PIPELINE_LOG="${RUN_DIR}/pipeline.log"
RECOVERY_DECISIONS="${RUN_DIR}/recovery-decisions.md"
{
  printf '\n## %s attempt %s (decided by %s at %s)\n' "${TASK}" "${PADDED}" "${DECIDED_BY}" "${DECIDED_AT}"
  printf -- '- action: %s\n' "${ACTION}"
  printf -- '- decision_source: hermes\n'
  printf -- '- human_decided: 1\n'
  [[ -n "${REASON}" ]] && printf -- '- reason: %s\n' "${REASON}"
  [[ -n "${CHECKS}" ]] && printf -- '- checks: %s\n' "${CHECKS}"
  [[ -n "${ACCEPT_FAILED}" ]] && printf -- '- accept_failed: %s\n' "${ACCEPT_FAILED}"
} >>"${RECOVERY_DECISIONS}"

if [[ -f "${PIPELINE_LOG}" ]]; then
  printf '[decide-recovery] task=%s attempt=%s action=%s decided_by=%s\n' \
    "${TASK}" "${PADDED}" "${ACTION}" "${DECIDED_BY}" >>"${PIPELINE_LOG}"
fi

printf '[decide-recovery] recorded decision: task=%s attempt=%s action=%s\n' \
  "${TASK}" "${PADDED}" "${ACTION}"
