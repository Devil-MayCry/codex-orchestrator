#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LONGRUN_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

RUN_ID="${RUN_ID:?RUN_ID is required}"
RUN_DIR="${RUN_DIR:-${LONGRUN_DIR}/runs/${RUN_ID}}"
STATUS_FILE="${RUN_DIR}/supervisor-status.env"
mkdir -p "${RUN_DIR}"

write_status() {
  local state="$1"
  local exit_code="${2:-}"
  local tmp="${STATUS_FILE}.tmp"
  {
    printf 'RUN_ID=%q\n' "${RUN_ID}"
    printf 'RUN_DIR=%q\n' "${RUN_DIR}"
    printf 'STATE=%q\n' "${state}"
    printf 'PIPELINE_PID=%q\n' "$$"
    printf 'UPDATED_AT=%q\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
    if [[ -n "${exit_code}" ]]; then
      printf 'EXIT_CODE=%q\n' "${exit_code}"
    fi
  } >"${tmp}"
  mv "${tmp}" "${STATUS_FILE}"
}

awaiting_watch_loop() {
  while :; do
    sleep 5
    if [[ ! -d "${RUN_DIR}" ]]; then
      continue
    fi
    if compgen -G "${RUN_DIR}/awaiting-decisions/*.env" >/dev/null 2>&1; then
      write_status AWAITING_DECISION
    else
      write_status RUNNING
    fi
  done
}

write_status RUNNING

awaiting_watch_loop &
AWAITING_WATCH_PID=$!
trap 'kill "${AWAITING_WATCH_PID}" 2>/dev/null || true' EXIT

set +e
"${SCRIPT_DIR}/run-pipeline.sh"
exit_code=$?
set -e

kill "${AWAITING_WATCH_PID}" 2>/dev/null || true
wait "${AWAITING_WATCH_PID}" 2>/dev/null || true
trap - EXIT

if [[ "${exit_code}" == "0" ]]; then
  write_status FINISHED "${exit_code}"
else
  write_status FAILED "${exit_code}"
fi

exit "${exit_code}"
