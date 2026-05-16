#!/usr/bin/env bash
set -Eeuo pipefail

TASK_KEY="${1:-}"
if [[ -z "${TASK_KEY}" ]]; then
  printf 'usage: %s TASK-ID\n' "$0" >&2
  exit 64
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LONGRUN_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ORCH_REPO_ROOT="${ORCH_REPO_ROOT:-$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel)}"
REPO_WORKDIR="${REPO_WORKDIR:-${ORCH_REPO_ROOT}}"

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
CODEX_BUILD_EFFORT="${CODEX_BUILD_EFFORT:-high}"
CODEX_VERIFY_EFFORT="${CODEX_VERIFY_EFFORT:-high}"
CODEX_TRANSPORT_RETRIES="${CODEX_TRANSPORT_RETRIES:-2}"
CODEX_HEARTBEAT_SECONDS="${CODEX_HEARTBEAT_SECONDS:-60}"
CODEX_PHASE_TIMEOUT_SECONDS="${CODEX_PHASE_TIMEOUT_SECONDS:-1800}"
MAX_FIX_ATTEMPTS="${MAX_FIX_ATTEMPTS:-2}"
RECOVERY_DECISION_ENGINE="${RECOVERY_DECISION_ENGINE:-hermes}"
HERMES_DECISION_TIMEOUT_SECONDS="${HERMES_DECISION_TIMEOUT_SECONDS:-300}"
HERMES_DECISION_POLL_SECONDS="${HERMES_DECISION_POLL_SECONDS:-5}"
COMMIT_SCOPE_ALLOW_PATTERNS="${COMMIT_SCOPE_ALLOW_PATTERNS:-docs/ CHANGELOG CHANGELOG.md tests/ task-queue.md}"
RUN_FULL_TESTS="${RUN_FULL_TESTS:-0}"
FULL_TEST_COMMAND="${FULL_TEST_COMMAND:-}"
RUN_ID="${RUN_ID:-manual-$(date +%Y%m%d-%H%M%S)}"
DRY_RUN="${DRY_RUN:-0}"
DRY_RUN_BLOCK_TASKS="${DRY_RUN_BLOCK_TASKS:-}"
DRY_RUN_CHECK_FAILURE_KIND="${DRY_RUN_CHECK_FAILURE_KIND:-}"
DRY_RUN_CHECK_FAILURE_ONCE="${DRY_RUN_CHECK_FAILURE_ONCE:-0}"
DRY_RUN_CHECK_FAILURE_ATTEMPTS="${DRY_RUN_CHECK_FAILURE_ATTEMPTS:-}"
DRY_RUN_RECOVERY_ACTION="${DRY_RUN_RECOVERY_ACTION:-BLOCKED}"
DRY_RUN_RECOVERY_ACTIONS="${DRY_RUN_RECOVERY_ACTIONS:-}"
DRY_RUN_VERIFY_VERDICT="${DRY_RUN_VERIFY_VERDICT:-PASS_COMMIT}"
DRY_RUN_VERIFY_VERDICTS="${DRY_RUN_VERIFY_VERDICTS:-}"
DRY_RUN_DECIDE_AS_ADVISORY="${DRY_RUN_DECIDE_AS_ADVISORY:-1}"
ALLOW_DIRTY_WORKTREE="${ALLOW_DIRTY_WORKTREE:-0}"
ALLOW_SCOPED_ACCEPT="${ALLOW_SCOPED_ACCEPT:-1}"
RUNS_DIR="${RUNS_DIR:-ops/hermes-longrun/runs}"

RUN_DIR="${RUN_DIR:-${ORCH_REPO_ROOT}/${RUNS_DIR}/${RUN_ID}}"
TASK_RUN_DIR="${RUN_DIR}/${TASK_KEY}"
mkdir -p "${TASK_RUN_DIR}"

log() {
  printf '[%s] %s\n' "${TASK_KEY}" "$*"
}

timestamp() {
  date '+%Y-%m-%dT%H:%M:%S%z'
}

fail() {
  printf '[%s][ERROR] %s\n' "${TASK_KEY}" "$*" >&2
  exit 1
}

task_in_list() {
  local needle="$1"
  local item
  for item in ${2:-}; do
    [[ "${item}" == "${needle}" ]] && return 0
  done
  return 1
}

task_row() {
  awk -F'|' -v key="${TASK_KEY}" '$1 == "TASK" && $2 == key { print; exit }' "${LONGRUN_DIR}/task-queue.md"
}

task_field() {
  local index="$1"
  task_row | awk -F'|' -v index="${index}" '{ print $index }'
}

split_checks() {
  python3 - "$1" <<'PY'
import sys
text = sys.argv[1]
for item in text.split(" &&& "):
    item = item.strip()
    if item:
        print(item)
PY
}

render_template() {
  local template="$1"
  local build_mode="${2:-initial}"
  sed \
    -e "s|{{TASK_KEY}}|${TASK_KEY}|g" \
    -e "s|{{TASK_TITLE}}|${TASK_TITLE}|g" \
    -e "s|{{TASK_DOC}}|${TASK_DOC}|g" \
    -e "s|{{BUILD_MODE}}|${build_mode}|g" \
    "${template}"
}

attempt_number_from_text() {
  local text="$1"
  if [[ "${text}" =~ attempt-([0-9]+) ]]; then
    printf '%s' "${BASH_REMATCH[1]#0}"
  else
    printf '1'
  fi
}

attempt_in_list() {
  local needle="$1"
  local item
  for item in ${2:-}; do
    item="${item#0}"
    [[ -z "${item}" ]] && item="0"
    [[ "${item}" == "${needle}" ]] && return 0
  done
  return 1
}

dry_run_sequence_value() {
  local sequence="$1"
  local attempt="$2"
  local fallback="$3"
  local index=1
  local item
  for item in ${sequence:-}; do
    if [[ "${index}" == "${attempt}" ]]; then
      printf '%s' "${item}"
      return 0
    fi
    index=$((index + 1))
  done
  printf '%s' "${fallback}"
}

codex_transport_failure() {
  local jsonl_file="$1"
  [[ -s "${jsonl_file}" ]] || return 1
  awk '
    BEGIN { found = 0 }
    /tls handshake eof/ ||
    /stream disconnected/ ||
    /failed to connect to websocket/ ||
    /Reconnecting/ ||
    /connection reset by peer/ ||
    /\"type\"[[:space:]]*:[[:space:]]*\"error\"/ {
      if ($0 ~ /tls handshake eof|stream disconnected|failed to connect to websocket|Reconnecting|connection reset by peer/) {
        found = 1
      }
    }
    END { exit(found ? 0 : 1) }
  ' "${jsonl_file}"
}

run_codex() {
  local phase="$1"
  local effort="$2"
  local sandbox="$3"
  local prompt_file="$4"
  local summary_file="$5"
  local jsonl_file="$6"

  if [[ "${DRY_RUN}" == "1" ]]; then
    if [[ "${phase}" == verify-* ]]; then
      local attempt verdict
      attempt="$(attempt_number_from_text "${phase}")"
      verdict="$(dry_run_sequence_value "${DRY_RUN_VERIFY_VERDICTS}" "${attempt}" "${DRY_RUN_VERIFY_VERDICT}")"
      {
        if task_in_list "${TASK_KEY}" "${DRY_RUN_BLOCK_TASKS}"; then
          printf 'BLOCKED\n\n'
        else
          printf '%s\n\n' "${verdict}"
        fi
        printf 'DRY_RUN phase=%s effort=%s sandbox=%s\n\n' "${phase}" "${effort}" "${sandbox}"
        cat "${prompt_file}"
      } >"${summary_file}"
    elif [[ "${phase}" == recovery-diagnose-* ]]; then
      local attempt action
      attempt="$(attempt_number_from_text "${phase}")"
      action="$(dry_run_sequence_value "${DRY_RUN_RECOVERY_ACTIONS}" "${attempt}" "${DRY_RUN_RECOVERY_ACTION}")"
      {
        printf 'ADVISE_%s\n\n' "${action}"
        printf 'failure_class: dry_run\n'
        printf 'reason: simulated recovery advisory for attempt %s\n' "${attempt}"
        printf 'allowed_write_scope: task implementation, checks, and test harness only\n'
        printf 'downstream_impact: dry-run scaffold validation\n'
        if [[ "${action}" == "RECOVER_CHECKS" ]]; then
          printf 'CHECK: %s\n' "$(target_checks | head -n 1)"
        fi
        printf 'recommended_decision_command: bash scripts/decide-recovery.sh --run-dir %s --task %s --attempt %s --action %s --reason "dry-run advisory"\n' "${RUN_DIR}" "${TASK_KEY}" "${attempt}" "${action}"
        printf '\nDRY_RUN phase=%s effort=%s sandbox=%s\n\n' "${phase}" "${effort}" "${sandbox}"
        cat "${prompt_file}"
      } >"${summary_file}"
    else
      {
        printf 'DRY_RUN phase=%s effort=%s sandbox=%s\n\n' "${phase}" "${effort}" "${sandbox}"
        cat "${prompt_file}"
      } >"${summary_file}"
    fi
    : >"${jsonl_file}"
    return 0
  fi

  local try=1
  local max_tries=$((CODEX_TRANSPORT_RETRIES + 1))
  local status=0
  local timeout_marker="${jsonl_file%.jsonl}.timeout"
  rm -f "${timeout_marker}" 2>/dev/null || true

  while (( try <= max_tries )); do
    if (( try > 1 )); then
      log "codex ${phase}: retry ${try}/${max_tries} after transport failure"
    else
      log "codex ${phase}: effort=${effort} sandbox=${sandbox} timeout=${CODEX_PHASE_TIMEOUT_SECONDS}s"
    fi

    : >"${jsonl_file}"
    codex exec \
      --ephemeral \
      --json \
      --cd "${REPO_WORKDIR}" \
      --sandbox "${sandbox}" \
      -m "${CODEX_MODEL}" \
      -c "model_reasoning_effort=\"${effort}\"" \
      -o "${summary_file}" \
      - <"${prompt_file}" >"${jsonl_file}" 2>&1 &
    local codex_pid=$!

    local elapsed=0
    local sleep_step="${CODEX_HEARTBEAT_SECONDS}"
    if (( sleep_step <= 0 )); then sleep_step=30; fi
    local timed_out=0

    while kill -0 "${codex_pid}" 2>/dev/null; do
      sleep "${sleep_step}"
      elapsed=$((elapsed + sleep_step))
      if kill -0 "${codex_pid}" 2>/dev/null; then
        log "codex ${phase}: still running pid=${codex_pid} elapsed=${elapsed}s"
      fi
      if (( CODEX_PHASE_TIMEOUT_SECONDS > 0 && elapsed >= CODEX_PHASE_TIMEOUT_SECONDS )); then
        log "codex ${phase}: phase timeout reached (${elapsed}s >= ${CODEX_PHASE_TIMEOUT_SECONDS}s); sending SIGTERM to pid=${codex_pid}"
        kill -TERM "${codex_pid}" 2>/dev/null || true
        local grace=0
        while kill -0 "${codex_pid}" 2>/dev/null; do
          sleep 1
          grace=$((grace + 1))
          if (( grace >= 5 )); then
            log "codex ${phase}: SIGTERM did not stop pid=${codex_pid}; sending SIGKILL"
            kill -KILL "${codex_pid}" 2>/dev/null || true
            break
          fi
        done
        timed_out=1
        break
      fi
    done

    if (( timed_out == 1 )); then
      wait "${codex_pid}" 2>/dev/null || true
      {
        printf 'phase=%s\n' "${phase}"
        printf 'timeout_seconds=%s\n' "${CODEX_PHASE_TIMEOUT_SECONDS}"
        printf 'elapsed_seconds=%s\n' "${elapsed}"
        printf 'killed_at=%s\n' "$(timestamp)"
      } >"${timeout_marker}"
      printf '\n[phase timeout] %s killed after %ss (cap=%ss)\n' "${phase}" "${elapsed}" "${CODEX_PHASE_TIMEOUT_SECONDS}" >>"${jsonl_file}"
      return 124
    fi

    if wait "${codex_pid}"; then
      return 0
    else
      status=$?
    fi

    if ! codex_transport_failure "${jsonl_file}"; then
      return "${status}"
    fi
    try=$((try + 1))
  done

  return "${status}"
}

target_checks() {
  split_checks "${TASK_CHECKS}"
  if [[ "${RUN_FULL_TESTS}" == "1" && -n "${FULL_TEST_COMMAND}" ]]; then
    printf '%s\n' "${FULL_TEST_COMMAND}"
  fi
}

simulate_dry_run_checks() {
  local log_file="$1"
  local attempt="$2"
  local failure_kind="${DRY_RUN_CHECK_FAILURE_KIND}"
  local status=0
  local cmd

  if [[ -z "${failure_kind}" ]]; then
    {
      printf '\nDRY_RUN: checks not executed. Planned commands:\n'
      target_checks
    } >>"${log_file}"
    return 0
  fi

  if [[ "${DRY_RUN_CHECK_FAILURE_ONCE}" == "1" && "${attempt}" != "1" ]]; then
    {
      printf '\nDRY_RUN: simulated check failure was one-shot and no longer applies.\n'
      printf 'Planned commands:\n'
      target_checks
    } >>"${log_file}"
    return 0
  fi

  if [[ -n "${DRY_RUN_CHECK_FAILURE_ATTEMPTS}" ]] && ! attempt_in_list "${attempt}" "${DRY_RUN_CHECK_FAILURE_ATTEMPTS}"; then
    {
      printf '\nDRY_RUN: simulated check failure does not apply to attempt %s.\n' "${attempt}"
      printf 'Planned commands:\n'
      target_checks
    } >>"${log_file}"
    return 0
  fi

  {
    printf '\nDRY_RUN: simulated check execution, failure_kind=%s attempt=%s\n' "${failure_kind}" "${attempt}"
  } >>"${log_file}"

  while IFS= read -r cmd; do
    [[ -z "${cmd}" ]] && continue
    printf '\n$ %s\n' "${cmd}" >>"${log_file}"
    case "${failure_kind}" in
      focused)
        if [[ "${cmd}" != "${FULL_TEST_COMMAND}" ]]; then
          printf '[check failed] %s\n' "${cmd}" >>"${log_file}"
          status=1
        else
          printf '[check passed] %s\n' "${cmd}" >>"${log_file}"
        fi
        ;;
      full-suite-harness|full-suite|unrelated-full-suite)
        if [[ -n "${FULL_TEST_COMMAND}" && "${cmd}" == "${FULL_TEST_COMMAND}" ]]; then
          printf '[check failed] %s\n' "${cmd}" >>"${log_file}"
          status=1
        else
          printf '[check passed] %s\n' "${cmd}" >>"${log_file}"
        fi
        ;;
      migration)
        if [[ "${cmd}" =~ (migration|migrate|alembic) ]]; then
          printf '[check failed] %s\n' "${cmd}" >>"${log_file}"
          status=1
        else
          printf '[check passed] %s\n' "${cmd}" >>"${log_file}"
        fi
        ;;
      *)
        printf '[check failed] %s\n' "${cmd}" >>"${log_file}"
        status=1
        ;;
    esac
  done < <(target_checks)

  return "${status}"
}

run_checks() {
  local log_file="$1"
  local attempt="${2:-1}"
  local status=0
  {
    printf '## Checks for %s\n' "${TASK_KEY}"
    timestamp
    printf 'Repo workdir: %s\n\n' "${REPO_WORKDIR}"
  } >"${log_file}"

  if [[ "${DRY_RUN}" == "1" ]]; then
    simulate_dry_run_checks "${log_file}" "${attempt}"
    return $?
  fi

  while IFS= read -r cmd; do
    [[ -z "${cmd}" ]] && continue
    {
      printf '\n$ %s\n' "${cmd}"
      timestamp
    } >>"${log_file}"
    log "check: ${cmd}"
    if ! (cd "${REPO_WORKDIR}" && bash -lc "${cmd}") >>"${log_file}" 2>&1; then
      status=1
      printf '\n[check failed] %s\n' "${cmd}" >>"${log_file}"
      log "check failed: ${cmd}"
    else
      log "check passed: ${cmd}"
    fi
  done < <(target_checks)

  return "${status}"
}

strict_first_token() {
  local file="$1"
  local pattern="$2"
  python3 - "$file" "$pattern" <<'PY'
import re
import sys

path, pattern = sys.argv[1], sys.argv[2]
try:
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for raw in fh:
            line = raw.strip()
            if not line:
                continue
            if re.fullmatch(pattern, line):
                print(line)
            break
except FileNotFoundError:
    pass
PY
}

fallback_token_scan() {
  local file="$1"
  local pattern="$2"
  local lines="$3"
  [[ -f "${file}" ]] || return 0
  sed -n "1,${lines}p" "$file" | grep -Eo "${pattern}" | head -n 1 || true
}

note_token_match_mode() {
  local file="$1"
  local mode="$2"
  [[ -f "${file}" ]] || return 0
  if grep -q "^token_match=" "${file}" 2>/dev/null; then
    return 0
  fi
  printf '\ntoken_match=%s\n' "${mode}" >>"${file}"
}

first_verdict() {
  local strict
  strict="$(strict_first_token "$1" 'PASS_COMMIT|NEED_FIX|ESCALATE_XHIGH|BLOCKED')"
  if [[ -n "${strict}" ]]; then
    note_token_match_mode "$1" "first_line_strict"
    printf '%s' "${strict}"
    return 0
  fi
  local fallback
  fallback="$(fallback_token_scan "$1" '\b(PASS_COMMIT|NEED_FIX|ESCALATE_XHIGH|BLOCKED)\b' 5)"
  if [[ -n "${fallback}" ]]; then
    note_token_match_mode "$1" "fallback_regex"
  fi
  printf '%s' "${fallback}"
}

first_recovery_action() {
  local strict
  strict="$(strict_first_token "$1" 'ADVISE_RECOVER_BUILD|ADVISE_RECOVER_CHECKS|ADVISE_ACCEPT_SCOPED|ADVISE_BLOCKED|RECOVER_BUILD|RECOVER_CHECKS|ACCEPT_SCOPED|BLOCKED')"
  if [[ -n "${strict}" ]]; then
    note_token_match_mode "$1" "first_line_strict"
    printf '%s' "${strict#ADVISE_}"
    return 0
  fi
  local fallback
  fallback="$(fallback_token_scan "$1" '\b(ADVISE_RECOVER_BUILD|ADVISE_RECOVER_CHECKS|ADVISE_ACCEPT_SCOPED|ADVISE_BLOCKED|RECOVER_BUILD|RECOVER_CHECKS|ACCEPT_SCOPED|BLOCKED)\b' 8)"
  if [[ -n "${fallback}" ]]; then
    note_token_match_mode "$1" "fallback_regex"
  fi
  printf '%s' "${fallback#ADVISE_}"
}

extract_decision_field() {
  local decision_file="$1"
  local key="$2"
  awk -v key="${key}" '
    BEGIN { IGNORECASE = 0 }
    {
      if (match($0, "^[[:space:]]*" key "[[:space:]]*:[[:space:]]*")) {
        value = substr($0, RSTART + RLENGTH)
        sub(/[[:space:]]+$/, "", value)
        print value
        exit
      }
    }
  ' "${decision_file}" 2>/dev/null
}

append_lessons_entry() {
  local padded="$1"
  local action="$2"
  local decision_file="$3"
  local lessons_file="${RUN_DIR}/lessons.md"

  [[ -n "${RUN_DIR:-}" ]] || return 0

  if [[ ! -f "${lessons_file}" ]]; then
    {
      printf '# Lessons learned for run %s\n\n' "${RUN_ID}"
      printf 'Each entry summarizes one recovery decision so later analyze passes can avoid repeating known failures.\n'
    } >"${lessons_file}"
  fi

  local failure_class reason mitigation source
  failure_class="$(extract_decision_field "${decision_file}" failure_class)"
  reason="$(extract_decision_field "${decision_file}" reason)"
  if [[ -z "${reason}" ]]; then
    reason="$(extract_decision_field "${decision_file}" decision_reason)"
  fi
  mitigation="$(extract_decision_field "${decision_file}" allowed_write_scope)"
  source="$(extract_decision_field "${decision_file}" decision_source)"

  {
    printf '\n## %s attempt %s\n' "${TASK_KEY}" "${padded}"
    printf -- '- action: %s\n' "${action}"
    [[ -n "${failure_class}" ]] && printf -- '- failure_class: %s\n' "${failure_class}"
    [[ -n "${reason}" ]] && printf -- '- reason: %s\n' "${reason}"
    [[ -n "${mitigation}" ]] && printf -- '- mitigation: %s\n' "${mitigation}"
    [[ -n "${source}" ]] && printf -- '- decision_source: %s\n' "${source}"
  } >>"${lessons_file}"
}

append_recovery_decision() {
  local padded="$1"
  local action="$2"
  local decision_file="$3"
  local summary_file="${TASK_RUN_DIR}/recovery-summary.md"

  {
    printf '\n## attempt %s\n\n' "${padded}"
    printf -- '- action: %s\n' "${action}"
    printf -- '- decision: %s\n\n' "${decision_file}"
    sed -n '1,120p' "${decision_file}" 2>/dev/null || true
    printf '\n'
  } >>"${summary_file}"

  if [[ -n "${RECOVERY_DECISIONS_FILE:-}" ]]; then
    {
      printf '\n## %s attempt %s\n\n' "${TASK_KEY}" "${padded}"
      printf -- '- action: %s\n' "${action}"
      printf -- '- task_dir: %s\n' "${TASK_RUN_DIR}"
      printf -- '- decision: %s\n\n' "${decision_file}"
      sed -n '1,80p' "${decision_file}" 2>/dev/null || true
      printf '\n'
    } >>"${RECOVERY_DECISIONS_FILE}"
  fi

  append_lessons_entry "${padded}" "${action}" "${decision_file}"
}

advisory_to_action() {
  local raw="$1"
  raw="${raw#ADVISE_}"
  case "${raw}" in
    RECOVER_BUILD|RECOVER_CHECKS|ACCEPT_SCOPED|BLOCKED) printf '%s' "${raw}" ;;
    *) printf 'BLOCKED' ;;
  esac
}

write_decision_file_from_advisory() {
  local decision_file="$1"
  local advisory_file="$2"
  local action="$3"
  local source_marker="$4"
  local extra_reason="${5:-}"

  {
    printf '%s\n\n' "${action}"
    printf '%s\n' "decision_source: ${source_marker}"
    if [[ -n "${extra_reason}" ]]; then
      printf '%s\n' "decision_reason: ${extra_reason}"
    fi
    printf '\n'
    if [[ -f "${advisory_file}" ]]; then
      printf 'Advisory excerpt (Codex):\n\n'
      sed -n '1,200p' "${advisory_file}"
    fi
  } >"${decision_file}"
}

write_decision_file_from_hermes() {
  local decision_file="$1"
  local advisory_file="$2"
  local hermes_env="$3"

  local ACTION="" CHECKS="" ACCEPT_FAILED="" REASON="" DECIDED_AT="" DECIDED_BY=""
  if [[ -f "${hermes_env}" ]]; then
    # shellcheck disable=SC1090
    source "${hermes_env}"
  fi
  ACTION="${ACTION:-BLOCKED}"

  {
    printf '%s\n\n' "${ACTION}"
    printf '%s\n' "decision_source: hermes"
    [[ -n "${DECIDED_BY}" ]] && printf '%s\n' "decided_by: ${DECIDED_BY}"
    [[ -n "${DECIDED_AT}" ]] && printf '%s\n' "decided_at: ${DECIDED_AT}"
    if [[ -n "${REASON}" ]]; then
      printf '%s\n' "decision_reason: ${REASON}"
    fi
    if [[ -n "${CHECKS}" ]]; then
      printf '\n'
      while IFS= read -r entry; do
        [[ -z "${entry}" ]] && continue
        printf 'CHECK: %s\n' "${entry}"
      done < <(printf '%s\n' "${CHECKS}" | sed 's/ &&& /\n/g')
    fi
    if [[ -n "${ACCEPT_FAILED}" ]]; then
      printf '\n'
      while IFS= read -r entry; do
        [[ -z "${entry}" ]] && continue
        printf 'ACCEPT_FAILED_CHECK: %s\n' "${entry}"
      done < <(printf '%s\n' "${ACCEPT_FAILED}" | sed 's/ &&& /\n/g')
    fi
    printf '\n'
    if [[ -f "${advisory_file}" ]]; then
      printf 'Advisory excerpt (Codex):\n\n'
      sed -n '1,200p' "${advisory_file}"
    fi
  } >"${decision_file}"
}

awaiting_marker_path() {
  local padded="$1"
  printf '%s/awaiting-decisions/%s-%s.env' "${RUN_DIR}" "${TASK_KEY}" "${padded}"
}

publish_awaiting_marker() {
  local padded="$1"
  local advisory_file="$2"
  local default_action="$3"
  local deadline_epoch="$4"
  local task_marker="${TASK_RUN_DIR}/awaiting-decision.env"
  local run_marker
  run_marker="$(awaiting_marker_path "${padded}")"
  mkdir -p "${RUN_DIR}/awaiting-decisions"

  local now_epoch
  now_epoch="$(date +%s)"

  {
    printf 'TASK=%q\n' "${TASK_KEY}"
    printf 'ATTEMPT=%q\n' "${padded}"
    printf 'TASK_RUN_DIR=%q\n' "${TASK_RUN_DIR}"
    printf 'ADVISORY_PATH=%q\n' "${advisory_file}"
    printf 'DECISION_PATH=%q\n' "${TASK_RUN_DIR}/decision-attempt-${padded}.env"
    printf 'DEFAULT_ACTION=%q\n' "${default_action}"
    printf 'STARTED_AT=%q\n' "${now_epoch}"
    printf 'DEADLINE_EPOCH=%q\n' "${deadline_epoch}"
    printf 'TIMEOUT_SECONDS=%q\n' "${HERMES_DECISION_TIMEOUT_SECONDS}"
  } >"${task_marker}"
  cp "${task_marker}" "${run_marker}"
}

clear_awaiting_marker() {
  local padded="$1"
  rm -f "${TASK_RUN_DIR}/awaiting-decision.env" 2>/dev/null || true
  rm -f "$(awaiting_marker_path "${padded}")" 2>/dev/null || true
  rmdir "${RUN_DIR}/awaiting-decisions" 2>/dev/null || true
}

wait_for_hermes_decision() {
  local padded="$1"
  local advisory_file="$2"
  local default_action="$3"
  local decision_file="$4"
  local decision_env="${TASK_RUN_DIR}/decision-attempt-${padded}.env"
  local poll_seconds="${HERMES_DECISION_POLL_SECONDS:-5}"
  if (( poll_seconds <= 0 )); then poll_seconds=5; fi
  local timeout_seconds="${HERMES_DECISION_TIMEOUT_SECONDS:-300}"
  local deadline_epoch=$(( $(date +%s) + timeout_seconds ))

  publish_awaiting_marker "${padded}" "${advisory_file}" "${default_action}" "${deadline_epoch}"
  log "awaiting Hermes decision: task=${TASK_KEY} attempt=${padded} default=${default_action} timeout=${timeout_seconds}s"

  local sigtrap_action="BLOCKED"
  local sigtrap_reason="supervisor_killed"
  trap '_run_one_task_signal_handler "'"${padded}"'" "'"${advisory_file}"'" "'"${decision_file}"'" "'"${sigtrap_action}"'" "'"${sigtrap_reason}"'"; exit 130' INT TERM

  if [[ "${DRY_RUN}" == "1" && "${DRY_RUN_DECIDE_AS_ADVISORY}" == "1" ]]; then
    write_decision_file_from_advisory "${decision_file}" "${advisory_file}" "${default_action}" "dry_run_auto_advisory" "DRY_RUN auto-approved advisory without waiting"
    clear_awaiting_marker "${padded}"
    log "DRY_RUN: auto-approved advisory action=${default_action}"
    trap - INT TERM
    return 0
  fi

  while :; do
    if [[ -s "${decision_env}" ]]; then
      write_decision_file_from_hermes "${decision_file}" "${advisory_file}" "${decision_env}"
      log "received Hermes decision attempt=${padded}"
      clear_awaiting_marker "${padded}"
      trap - INT TERM
      return 0
    fi
    local now_epoch
    now_epoch="$(date +%s)"
    if (( now_epoch >= deadline_epoch )); then
      write_decision_file_from_advisory "${decision_file}" "${advisory_file}" "${default_action}" "auto_approved_by_timeout" "Hermes did not respond within ${timeout_seconds}s; advisory auto-approved"
      log "decision timeout reached after ${timeout_seconds}s; auto-approved advisory action=${default_action}"
      clear_awaiting_marker "${padded}"
      trap - INT TERM
      return 0
    fi
    sleep "${poll_seconds}"
  done
}

_run_one_task_signal_handler() {
  local padded="$1"
  local advisory_file="$2"
  local decision_file="$3"
  local action="$4"
  local reason="$5"
  write_decision_file_from_advisory "${decision_file}" "${advisory_file}" "${action}" "supervisor_killed" "${reason}"
  clear_awaiting_marker "${padded}"
}

run_recovery_diagnose() {
  local padded="$1"
  local attempt="$2"
  local checks_log="$3"
  local verifier_file="$4"
  local decision_prompt="${TASK_RUN_DIR}/recovery-advisory-attempt-${padded}.prompt.md"
  local advisory_file="${TASK_RUN_DIR}/recovery-advisory-attempt-${padded}.md"
  local decision_file="${TASK_RUN_DIR}/recovery-decision-attempt-${padded}.md"
  local timeout_marker_prev="${TASK_RUN_DIR}/build-attempt-${padded}.timeout"

  {
    cat "${LONGRUN_DIR}/prompts/recover.md"
    printf '\n\nTask: %s %s\n' "${TASK_KEY}" "${TASK_TITLE}"
    printf 'Build attempt: %s\n' "${attempt}"
    printf 'Max build attempts: %s\n' "${max_attempts}"
    printf 'Checks status: %s\n' "${last_checks_status}"
    printf 'Verifier verdict after guardrails: %s\n' "${last_verdict}"
    printf 'Recovery attempts used for logging: %s\n' "${recovery_attempts_used}"
    printf 'Allow scoped accept: %s\n' "${ALLOW_SCOPED_ACCEPT}"
    if [[ -f "${timeout_marker_prev}" ]]; then
      printf '\nPrevious build phase timed out after %s seconds (cap=%s seconds). Treat this as a strong signal when classifying the failure.\n' \
        "$(awk -F= '$1=="elapsed_seconds"{print $2}' "${timeout_marker_prev}")" \
        "${CODEX_PHASE_TIMEOUT_SECONDS}"
    fi
    printf '\n\nAnalysis summary:\n'
    cat "${TASK_RUN_DIR}/analysis.md"
    printf '\n\nBuilder summary:\n'
    cat "${TASK_RUN_DIR}/builder-attempt-${padded}.md"
    printf '\n\nVerifier report:\n'
    cat "${verifier_file}"
    printf '\n\nChecks log tail:\n'
    tail -n 260 "${checks_log}" || true
  } >"${decision_prompt}"

  run_codex \
    "recovery-diagnose-attempt-${padded}" \
    "${CODEX_VERIFY_EFFORT}" \
    "read-only" \
    "${decision_prompt}" \
    "${advisory_file}" \
    "${TASK_RUN_DIR}/recovery-advisory-attempt-${padded}.jsonl" || true

  if [[ ! -s "${advisory_file}" ]]; then
    {
      printf 'ADVISE_BLOCKED\n\n'
      printf 'failure_class: environment\n'
      printf 'reason: Codex did not produce a usable advisory file.\n'
      printf 'allowed_write_scope: none\n'
      printf 'downstream_impact: human review required before continuing this dependency chain\n'
    } >"${advisory_file}"
  fi

  local advisory_token
  advisory_token="$(first_recovery_action "${advisory_file}")"
  local default_action
  default_action="$(advisory_to_action "${advisory_token:-BLOCKED}")"

  wait_for_hermes_decision "${padded}" "${advisory_file}" "${default_action}" "${decision_file}"
}

allowed_recovery_check() {
  local candidate="$1"
  local allowed
  while IFS= read -r allowed; do
    [[ "${candidate}" == "${allowed}" ]] && return 0
  done < <(target_checks)
  return 1
}

run_recovery_checks() {
  local decision_file="$1"
  local log_file="$2"
  local status=0
  local cmd saw_check=0

  {
    printf '## Recovery checks for %s\n' "${TASK_KEY}"
    timestamp
    printf 'Decision: %s\n\n' "${decision_file}"
  } >"${log_file}"

  while IFS= read -r cmd; do
    cmd="${cmd#CHECK: }"
    [[ -z "${cmd}" ]] && continue
    saw_check=1
    if ! allowed_recovery_check "${cmd}"; then
      printf '[recovery check denied] %s\n' "${cmd}" >>"${log_file}"
      status=1
      continue
    fi
    printf '\n$ %s\n' "${cmd}" >>"${log_file}"
    if [[ "${DRY_RUN}" == "1" ]]; then
      printf 'DRY_RUN: recovery check accepted but not executed.\n' >>"${log_file}"
      continue
    fi
    if ! (cd "${REPO_WORKDIR}" && bash -lc "${cmd}") >>"${log_file}" 2>&1; then
      status=1
      printf '\n[recovery check failed] %s\n' "${cmd}" >>"${log_file}"
    fi
  done < <(grep '^CHECK: ' "${decision_file}" || true)

  if [[ "${saw_check}" == "0" ]]; then
    printf 'No CHECK lines provided by recovery decision.\n' >>"${log_file}"
    return 1
  fi
  return "${status}"
}

only_full_test_failed() {
  local log_file="$1"
  local failed_line failed_cmd saw_failed=0
  [[ -n "${FULL_TEST_COMMAND}" ]] || return 1
  while IFS= read -r failed_line; do
    failed_cmd="${failed_line#\[check failed\] }"
    [[ -z "${failed_cmd}" ]] && continue
    saw_failed=1
    [[ "${failed_cmd}" == "${FULL_TEST_COMMAND}" ]] || return 1
  done < <(grep '^\[check failed\]' "${log_file}" || true)
  [[ "${saw_failed}" == "1" ]]
}

checks_only_in_accept_list() {
  local log_file="$1"
  local accept_list="$2"
  local failed_line failed_cmd saw_failed=0 allowed
  [[ -f "${log_file}" ]] || return 1
  while IFS= read -r failed_line; do
    failed_cmd="${failed_line#\[check failed\] }"
    [[ -z "${failed_cmd}" ]] && continue
    saw_failed=1
    allowed=0
    while IFS= read -r entry; do
      [[ -z "${entry}" ]] && continue
      if [[ "${failed_cmd}" == "${entry}" ]]; then
        allowed=1
        break
      fi
    done < <(printf '%s\n' "${accept_list}" | tr '\t' '\n' | sed 's/ &&& /\n/g')
    [[ "${allowed}" == "1" ]] || return 1
  done < <(grep '^\[check failed\]' "${log_file}" || true)
  [[ "${saw_failed}" == "1" ]]
}

extract_accept_failed_list() {
  local decision_file="$1"
  [[ -f "${decision_file}" ]] || return 0
  awk '
    /^ACCEPT_FAILED_CHECK:[[:space:]]*/ {
      sub(/^ACCEPT_FAILED_CHECK:[[:space:]]*/, "")
      printf "%s\n", $0
    }
  ' "${decision_file}"
}

scoped_accept_eligible() {
  local verifier_file="$1"
  local checks_log="$2"
  local decision_file="${3:-}"
  [[ "${ALLOW_SCOPED_ACCEPT}" == "1" ]] || return 1
  [[ "$(first_verdict "${verifier_file}")" == "PASS_COMMIT" ]] || return 1
  if only_full_test_failed "${checks_log}"; then
    return 0
  fi
  if [[ -n "${decision_file}" && -f "${decision_file}" ]]; then
    local accept_list
    accept_list="$(extract_accept_failed_list "${decision_file}" | paste -sd $'\n' -)"
    if [[ -n "${accept_list}" ]] && checks_only_in_accept_list "${checks_log}" "${accept_list}"; then
      return 0
    fi
  fi
  return 1
}

extract_verifier_files() {
  local verifier_file="$1"
  [[ -f "${verifier_file}" ]] || return 0
  awk '
    /^FILE:[[:space:]]*/ {
      path = $0
      sub(/^FILE:[[:space:]]*/, "", path)
      gsub(/[[:space:]]+$/, "", path)
      if (length(path) > 0) print path
    }
    /^FILES:[[:space:]]*/ {
      list = $0
      sub(/^FILES:[[:space:]]*/, "", list)
      n = split(list, parts, ",")
      for (i = 1; i <= n; i++) {
        item = parts[i]
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", item)
        if (length(item) > 0) print item
      }
    }
  ' "${verifier_file}" | sort -u
}

path_matches_allow_pattern() {
  local path="$1"
  local pattern
  for pattern in ${COMMIT_SCOPE_ALLOW_PATTERNS}; do
    [[ -z "${pattern}" ]] && continue
    if [[ "${pattern}" == */ ]]; then
      [[ "${path}" == "${pattern}"* ]] && return 0
    else
      [[ "${path}" == "${pattern}" ]] && return 0
      [[ "${path}" == "${pattern}"/* ]] && return 0
    fi
  done
  return 1
}

verifier_scope_audit() {
  local verifier_file="$1"
  local audit_file="$2"
  local rel
  rel="$(longrun_relpath)"
  local declared
  declared="$(extract_verifier_files "${verifier_file}" || true)"
  local staged
  staged="$(git -C "${REPO_WORKDIR}" diff --cached --name-only)"

  : >"${audit_file}"
  {
    printf '## commit-scope audit for %s\n' "${TASK_KEY}"
    timestamp
    printf 'verifier: %s\n' "${verifier_file}"
    printf 'declared FILE/FILES set:\n'
    if [[ -z "${declared}" ]]; then
      printf '(none declared)\n'
    else
      printf '%s\n' "${declared}"
    fi
    printf '\nstaged paths:\n'
    if [[ -z "${staged}" ]]; then
      printf '(no staged paths)\n'
    else
      printf '%s\n' "${staged}"
    fi
  } >>"${audit_file}"

  if [[ -z "${staged}" ]]; then
    return 0
  fi

  if [[ -z "${declared}" ]]; then
    {
      printf '\nresult: BLOCK\n'
      printf 'reason: verifier returned PASS_COMMIT without declaring any FILE: lines.\n'
    } >>"${audit_file}"
    return 1
  fi

  local violations=""
  local path
  while IFS= read -r path; do
    [[ -z "${path}" ]] && continue
    if [[ -n "${rel}" && ( "${path}" == "${rel}/runs"/* || "${path}" == "${rel}/runs" ) ]]; then
      continue
    fi
    if printf '%s\n' "${declared}" | grep -Fxq "${path}"; then
      continue
    fi
    if path_matches_allow_pattern "${path}"; then
      continue
    fi
    violations+="${path}"$'\n'
  done <<<"${staged}"

  if [[ -n "${violations}" ]]; then
    {
      printf '\nresult: BLOCK\n'
      printf 'reason: staged paths outside declared FILE: set and outside COMMIT_SCOPE_ALLOW_PATTERNS\n'
      printf 'violations:\n%s' "${violations}"
    } >>"${audit_file}"
    return 1
  fi

  printf '\nresult: OK\n' >>"${audit_file}"
  return 0
}

longrun_relpath() {
  python3 - "$LONGRUN_DIR" "$ORCH_REPO_ROOT" <<'PY'
import os
import sys
print(os.path.relpath(sys.argv[1], sys.argv[2]))
PY
}

reset_runtime_artifacts() {
  local rel
  local cleanup_path
  local run_path
  rel="$(longrun_relpath)"
  cleanup_path="$(python3 - "${REPO_WORKDIR}" "${rel}/runs" <<'PY'
from pathlib import Path
import sys

print((Path(sys.argv[1]) / sys.argv[2]).resolve(strict=False))
PY
)"
  run_path="$(python3 - "${RUN_DIR}" <<'PY'
from pathlib import Path
import sys

print(Path(sys.argv[1]).resolve(strict=False))
PY
)"
  git -C "${REPO_WORKDIR}" restore --staged -- "${rel}/runs" 2>/dev/null || true
  if [[ "${run_path}" == "${cleanup_path}" || "${run_path}" == "${cleanup_path}/"* ]]; then
    return 0
  fi
  git -C "${REPO_WORKDIR}" restore --worktree -- "${rel}/runs" 2>/dev/null || true
  git -C "${REPO_WORKDIR}" clean -fdX -- "${rel}/runs" >/dev/null 2>&1 || true
}

stage_candidate_for_verifier() {
  local attempt_label="$1"
  local rel
  rel="$(longrun_relpath)"
  reset_runtime_artifacts

  if [[ "${DRY_RUN}" == "1" ]]; then
    log "DRY_RUN: not staging candidate diff before verifier ${attempt_label}"
    return 0
  fi

  git -C "${REPO_WORKDIR}" add -A
  git -C "${REPO_WORKDIR}" restore --staged -- "${rel}/runs" 2>/dev/null || true

  local staged
  staged="$(git -C "${REPO_WORKDIR}" diff --cached --name-only || true)"
  if [[ -z "${staged}" ]]; then
    log "verifier ${attempt_label}: no staged candidate diff after runner staging"
  else
    log "verifier ${attempt_label}: staged candidate diff for read-only verifier"
  fi
}

stage_and_commit() {
  local commit_msg="$1"
  local verifier_file="${2:-}"
  local audit_file="${3:-}"
  local rel
  rel="$(longrun_relpath)"
  reset_runtime_artifacts
  git -C "${REPO_WORKDIR}" add -A
  git -C "${REPO_WORKDIR}" restore --staged -- "${rel}/runs" 2>/dev/null || true

  if git -C "${REPO_WORKDIR}" diff --cached --quiet; then
    log "no staged diff to commit"
    return 1
  fi

  if [[ -n "${verifier_file}" ]]; then
    local audit_target="${audit_file:-${TASK_RUN_DIR}/commit-scope-audit.md}"
    if ! verifier_scope_audit "${verifier_file}" "${audit_target}"; then
      log "commit-scope audit failed; staged paths exceed verifier FILE: scope. See ${audit_target}"
      git -C "${REPO_WORKDIR}" reset --quiet >/dev/null 2>&1 || true
      return 2
    fi
  fi

  git -C "${REPO_WORKDIR}" commit -m "${commit_msg}"
}

TASK_ROW="$(task_row)"
[[ -n "${TASK_ROW}" ]] || fail "unknown task key in task-queue.md: ${TASK_KEY}"
TASK_TITLE="$(task_field 3)"
TASK_DOC="$(task_field 4)"
TASK_CHECKS="$(task_field 6)"
[[ -n "${TASK_CHECKS}" ]] || fail "task has no checks in task-queue.md: ${TASK_KEY}"

if [[ ! -f "${REPO_WORKDIR}/${TASK_DOC}" ]]; then
  if [[ "${DRY_RUN}" == "1" ]]; then
    log "DRY_RUN: task doc missing but accepted: ${TASK_DOC}"
  else
    fail "task document not found in workdir: ${REPO_WORKDIR}/${TASK_DOC}"
  fi
fi

reset_runtime_artifacts
mkdir -p "${TASK_RUN_DIR}"
if [[ "${ALLOW_DIRTY_WORKTREE}" != "1" ]] && [[ -n "$(git -C "${REPO_WORKDIR}" status --porcelain)" ]]; then
  git -C "${REPO_WORKDIR}" status --short >&2
  fail "refusing to start in a dirty worktree; set ALLOW_DIRTY_WORKTREE=1 to override"
fi

log "workdir: ${REPO_WORKDIR}"
log "task doc: ${TASK_DOC}"

analysis_prompt="${TASK_RUN_DIR}/analysis.prompt.md"
{
  render_template "${LONGRUN_DIR}/prompts/analyze.md"
  if [[ -n "${BLOCKED_TASKS:-}" ]]; then
    printf '\n\nEarlier tasks blocked in this run: %s\n' "${BLOCKED_TASKS}"
    printf 'Continue only against committed work. Do not assume blocked-task patches are present.\n'
    [[ -n "${BLOCKED_TASKS_REPORT:-}" ]] && printf 'Blocked task report: %s\n' "${BLOCKED_TASKS_REPORT}"
  fi
  lessons_file="${RUN_DIR}/lessons.md"
  if [[ -f "${lessons_file}" ]]; then
    printf '\n\nLessons from earlier recovery decisions in this run (read-only context; mention any that apply to this task and how you will avoid them):\n\n'
    awk '
      BEGIN { count = 0; want = 25 }
      /^## / { entries[++count] = "" }
      count > 0 { entries[count] = entries[count] $0 "\n" }
      END {
        start = (count > want) ? count - want + 1 : 1
        for (i = start; i <= count; i++) {
          printf "%s", entries[i]
        }
      }
    ' "${lessons_file}"
  fi
} >"${analysis_prompt}"

if run_codex \
  "analysis" \
  "${CODEX_ANALYZE_EFFORT}" \
  "read-only" \
  "${analysis_prompt}" \
  "${TASK_RUN_DIR}/analysis.md" \
  "${TASK_RUN_DIR}/analysis.jsonl"; then
  analysis_status=0
else
  analysis_status=$?
fi

if [[ "${analysis_status}" != "0" ]]; then
  log "analysis phase failed status=${analysis_status}; continuing with failure context"
  if [[ ! -s "${TASK_RUN_DIR}/analysis.md" ]]; then
    {
      printf 'Analysis phase failed before producing a summary.\n'
      printf 'status: %s\n' "${analysis_status}"
      printf 'jsonl: %s\n' "${TASK_RUN_DIR}/analysis.jsonl"
    } >"${TASK_RUN_DIR}/analysis.md"
  else
    printf '\nAnalysis phase exited non-zero: %s\n' "${analysis_status}" >>"${TASK_RUN_DIR}/analysis.md"
  fi
fi

attempt=1
max_attempts=$((MAX_FIX_ATTEMPTS + 1))
last_verdict="NEED_FIX"
last_checks_status=1
recovery_attempts_used=0
next_build_mode="initial"

while (( attempt <= max_attempts )); do
  padded="$(printf '%02d' "${attempt}")"
  build_mode="${next_build_mode}"
  build_status=0
  verifier_status=0

  build_prompt="${TASK_RUN_DIR}/build-attempt-${padded}.prompt.md"
  {
    render_template "${LONGRUN_DIR}/prompts/build.md" "${build_mode}"
    printf '\n\nAnalysis summary:\n'
    cat "${TASK_RUN_DIR}/analysis.md"
    if (( attempt > 1 )); then
      printf '\n\nPrevious verifier report:\n'
      cat "${TASK_RUN_DIR}/verifier-attempt-$(printf '%02d' $((attempt - 1))).md"
      printf '\n\nPrevious checks log tail:\n'
      tail -n 160 "${TASK_RUN_DIR}/checks-attempt-$(printf '%02d' $((attempt - 1))).log" || true
    fi
    if [[ "${build_mode}" == recovery-* ]]; then
      latest_recovery="$(find "${TASK_RUN_DIR}" -maxdepth 1 -name 'recovery-decision-attempt-*.md' ! -name '*.prompt.md' -print 2>/dev/null | sort | tail -n 1 || true)"
      if [[ -n "${latest_recovery}" ]]; then
        printf '\n\nRecovery decision to implement:\n'
        cat "${latest_recovery}"
      fi
    fi
  } >"${build_prompt}"

  if run_codex \
    "build-attempt-${padded}" \
    "${CODEX_BUILD_EFFORT}" \
    "workspace-write" \
    "${build_prompt}" \
    "${TASK_RUN_DIR}/builder-attempt-${padded}.md" \
    "${TASK_RUN_DIR}/builder-attempt-${padded}.jsonl"; then
    build_status=0
  else
    build_status=$?
  fi

  checks_log="${TASK_RUN_DIR}/checks-attempt-${padded}.log"
  verifier_file="${TASK_RUN_DIR}/verifier-attempt-${padded}.md"
  if [[ "${build_status}" != "0" ]]; then
    log "build attempt ${padded} failed status=${build_status}; sending to recovery decision"
    if [[ ! -s "${TASK_RUN_DIR}/builder-attempt-${padded}.md" ]]; then
      {
        printf 'Build phase failed before producing a summary.\n'
        printf 'status: %s\n' "${build_status}"
        printf 'jsonl: %s\n' "${TASK_RUN_DIR}/builder-attempt-${padded}.jsonl"
      } >"${TASK_RUN_DIR}/builder-attempt-${padded}.md"
    else
      printf '\nBuild phase exited non-zero: %s\n' "${build_status}" >>"${TASK_RUN_DIR}/builder-attempt-${padded}.md"
    fi
    {
      printf '## Checks for %s\n' "${TASK_KEY}"
      timestamp
      printf 'Repo workdir: %s\n\n' "${REPO_WORKDIR}"
      printf '[check failed] build-phase: codex build exited with status %s\n' "${build_status}"
    } >"${checks_log}"
    {
      printf 'NEED_FIX\n\n'
      printf 'Build phase failed before a verifier pass could run.\n'
      printf 'status: %s\n' "${build_status}"
      printf 'builder: %s\n' "${TASK_RUN_DIR}/builder-attempt-${padded}.md"
      printf 'jsonl: %s\n' "${TASK_RUN_DIR}/builder-attempt-${padded}.jsonl"
    } >"${verifier_file}"
    last_checks_status=1
  else
    if run_checks "${checks_log}" "${attempt}"; then
      last_checks_status=0
    else
      last_checks_status=1
    fi

    stage_candidate_for_verifier "${padded}"

    verifier_prompt="${TASK_RUN_DIR}/verifier-attempt-${padded}.prompt.md"
    {
      render_template "${LONGRUN_DIR}/prompts/verify.md"
      printf '\n\nAnalysis summary:\n'
      cat "${TASK_RUN_DIR}/analysis.md"
      printf '\n\nBuilder summary:\n'
      cat "${TASK_RUN_DIR}/builder-attempt-${padded}.md"
      printf '\n\nChecks log tail:\n'
      tail -n 240 "${checks_log}" || true
    } >"${verifier_prompt}"

    if run_codex \
      "verify-attempt-${padded}" \
      "${CODEX_VERIFY_EFFORT}" \
      "read-only" \
      "${verifier_prompt}" \
      "${verifier_file}" \
      "${TASK_RUN_DIR}/verifier-attempt-${padded}.jsonl"; then
      verifier_status=0
    else
      verifier_status=$?
    fi

    if [[ "${verifier_status}" != "0" ]]; then
      log "verifier attempt ${padded} failed status=${verifier_status}; forcing NEED_FIX"
      if [[ ! -s "${verifier_file}" ]]; then
        {
          printf 'NEED_FIX\n\n'
          printf 'Verifier phase failed before producing a report.\n'
          printf 'status: %s\n' "${verifier_status}"
          printf 'jsonl: %s\n' "${TASK_RUN_DIR}/verifier-attempt-${padded}.jsonl"
        } >"${verifier_file}"
      else
        printf '\nVerifier phase exited non-zero: %s\n' "${verifier_status}" >>"${verifier_file}"
      fi
    fi
  fi

  last_verdict="$(first_verdict "${verifier_file}")"
  last_verdict="${last_verdict:-NEED_FIX}"
  if [[ "${build_status:-0}" != "0" || "${verifier_status:-0}" != "0" ]]; then
    last_verdict="NEED_FIX"
    printf '\nForced verdict override: phase failure requires recovery before commit.\n' >>"${verifier_file}"
  fi
  if [[ "${last_verdict}" == "PASS_COMMIT" && "${last_checks_status}" != "0" ]]; then
    last_verdict="NEED_FIX"
    printf '\nForced verdict override: checks failed, so PASS_COMMIT is not accepted.\n' >>"${verifier_file}"
  fi

  log "attempt ${padded} verdict=${last_verdict} checks_status=${last_checks_status}"

  if [[ "${last_verdict}" == "PASS_COMMIT" ]]; then
    summary_verdict="PASS_COMMIT"
    if (( recovery_attempts_used > 0 )); then
      summary_verdict="RECOVERED"
    fi
    if [[ "${DRY_RUN}" == "1" ]]; then
      {
        printf '# %s summary\n\n' "${TASK_KEY}"
        printf '%s\n' "- verdict: ${summary_verdict}"
        printf '%s\n' '- commit: DRY_RUN'
        printf '%s\n' "- checks: ${checks_log}"
        printf '%s\n' "- task doc: ${TASK_DOC}"
        [[ -f "${TASK_RUN_DIR}/recovery-summary.md" ]] && printf '%s\n' "- recovery: ${TASK_RUN_DIR}/recovery-summary.md"
      } >"${TASK_RUN_DIR}/summary.md"
      exit 0
    fi
    commit_msg="longrun: ${TASK_KEY} ${TASK_TITLE}"
    audit_file="${TASK_RUN_DIR}/commit-scope-audit-attempt-${padded}.md"
    if stage_and_commit "${commit_msg}" "${verifier_file}" "${audit_file}"; then
      commit_status=0
    else
      commit_status=$?
    fi
    if [[ "${commit_status}" == "0" ]]; then
      commit_sha="$(git -C "${REPO_WORKDIR}" rev-parse --short HEAD)"
      {
        printf '# %s summary\n\n' "${TASK_KEY}"
        printf '%s\n' "- verdict: ${summary_verdict}"
        printf '%s\n' "- commit: ${commit_sha}"
        printf '%s\n' "- checks: ${checks_log}"
        printf '%s\n' "- task doc: ${TASK_DOC}"
        [[ -f "${TASK_RUN_DIR}/recovery-summary.md" ]] && printf '%s\n' "- recovery: ${TASK_RUN_DIR}/recovery-summary.md"
      } >"${TASK_RUN_DIR}/summary.md"
      exit 0
    fi
    if [[ "${commit_status}" == "2" ]]; then
      last_verdict="NEED_FIX"
      printf '\nForced verdict override: commit-scope audit rejected the staged diff (see %s).\n' "${audit_file}" >>"${verifier_file}"
      log "PASS_COMMIT downgraded to NEED_FIX due to commit-scope audit"
    else
      last_verdict="BLOCKED"
      break
    fi
  fi

  run_recovery_diagnose "${padded}" "${attempt}" "${checks_log}" "${verifier_file}"
  recovery_decision_file="${TASK_RUN_DIR}/recovery-decision-attempt-${padded}.md"
  recovery_action="$(first_recovery_action "${recovery_decision_file}")"
  recovery_action="${recovery_action:-BLOCKED}"

  case "${recovery_action}" in
    RECOVER_BUILD)
      if (( attempt >= max_attempts )); then
        {
          printf '\nBLOCKED\n\n'
          printf 'Recovery requested RECOVER_BUILD, but total build attempt budget is exhausted: attempt %s/%s.\n' "${attempt}" "${max_attempts}"
          printf 'MAX_FIX_ATTEMPTS is the only build retry budget; increase it for a longer run.\n'
        } >>"${recovery_decision_file}"
        append_recovery_decision "${padded}" "BLOCKED" "${recovery_decision_file}"
        last_verdict="BLOCKED"
        break
      fi
      recovery_attempts_used=$((recovery_attempts_used + 1))
      append_recovery_decision "${padded}" "${recovery_action}" "${recovery_decision_file}"
      attempt=$((attempt + 1))
      next_build_mode="recovery-attempt-$(printf '%02d' "${attempt}")"
      continue
      ;;
    RECOVER_CHECKS)
      append_recovery_decision "${padded}" "${recovery_action}" "${recovery_decision_file}"
      if [[ "$(first_verdict "${verifier_file}")" != "PASS_COMMIT" ]]; then
        printf '\nRecovery checks denied by runner guardrails: verifier did not return PASS_COMMIT.\n' >>"${recovery_decision_file}"
        last_verdict="BLOCKED"
        break
      fi
      recovery_checks_log="${TASK_RUN_DIR}/recovery-checks-attempt-${padded}.log"
      if run_recovery_checks "${recovery_decision_file}" "${recovery_checks_log}"; then
        if [[ "${DRY_RUN}" == "1" ]]; then
          {
            printf '# %s summary\n\n' "${TASK_KEY}"
            printf '%s\n' '- verdict: PASS_COMMIT_SCOPED'
            printf '%s\n' '- commit: DRY_RUN'
            printf '%s\n' "- checks: ${recovery_checks_log}"
            printf '%s\n' "- recovery: ${TASK_RUN_DIR}/recovery-summary.md"
            printf '%s\n' "- task doc: ${TASK_DOC}"
          } >"${TASK_RUN_DIR}/summary.md"
          exit 0
        fi
        commit_msg="longrun: ${TASK_KEY} ${TASK_TITLE} (scoped checks)"
        audit_file="${TASK_RUN_DIR}/commit-scope-audit-attempt-${padded}-recovery.md"
        if stage_and_commit "${commit_msg}" "${verifier_file}" "${audit_file}"; then
          commit_status=0
        else
          commit_status=$?
        fi
        if [[ "${commit_status}" == "0" ]]; then
          commit_sha="$(git -C "${REPO_WORKDIR}" rev-parse --short HEAD)"
          {
            printf '# %s summary\n\n' "${TASK_KEY}"
            printf '%s\n' '- verdict: PASS_COMMIT_SCOPED'
            printf '%s\n' "- commit: ${commit_sha}"
            printf '%s\n' "- checks: ${recovery_checks_log}"
            printf '%s\n' "- recovery: ${TASK_RUN_DIR}/recovery-summary.md"
            printf '%s\n' "- task doc: ${TASK_DOC}"
          } >"${TASK_RUN_DIR}/summary.md"
          exit 0
        fi
        if [[ "${commit_status}" == "2" ]]; then
          printf '\nCommit-scope audit rejected scoped checks commit; see %s.\n' "${audit_file}" >>"${recovery_decision_file}"
        fi
      fi
      last_verdict="BLOCKED"
      break
      ;;
    ACCEPT_SCOPED)
      append_recovery_decision "${padded}" "${recovery_action}" "${recovery_decision_file}"
      if scoped_accept_eligible "${verifier_file}" "${checks_log}" "${recovery_decision_file}"; then
        if [[ "${DRY_RUN}" == "1" ]]; then
          {
            printf '# %s summary\n\n' "${TASK_KEY}"
            printf '%s\n' '- verdict: PASS_COMMIT_SCOPED'
            printf '%s\n' '- commit: DRY_RUN'
            printf '%s\n' "- checks: ${checks_log}"
            printf '%s\n' "- recovery: ${TASK_RUN_DIR}/recovery-summary.md"
            printf '%s\n' "- task doc: ${TASK_DOC}"
          } >"${TASK_RUN_DIR}/summary.md"
          exit 0
        fi
        commit_msg="longrun: ${TASK_KEY} ${TASK_TITLE} (scoped accept)"
        audit_file="${TASK_RUN_DIR}/commit-scope-audit-attempt-${padded}-accept.md"
        if stage_and_commit "${commit_msg}" "${verifier_file}" "${audit_file}"; then
          commit_status=0
        else
          commit_status=$?
        fi
        if [[ "${commit_status}" == "0" ]]; then
          commit_sha="$(git -C "${REPO_WORKDIR}" rev-parse --short HEAD)"
          {
            printf '# %s summary\n\n' "${TASK_KEY}"
            printf '%s\n' '- verdict: PASS_COMMIT_SCOPED'
            printf '%s\n' "- commit: ${commit_sha}"
            printf '%s\n' "- checks: ${checks_log}"
            printf '%s\n' "- recovery: ${TASK_RUN_DIR}/recovery-summary.md"
            printf '%s\n' "- task doc: ${TASK_DOC}"
          } >"${TASK_RUN_DIR}/summary.md"
          exit 0
        fi
        if [[ "${commit_status}" == "2" ]]; then
          printf '\nCommit-scope audit rejected scoped accept commit; see %s.\n' "${audit_file}" >>"${recovery_decision_file}"
        fi
      else
        printf '\nScoped acceptance denied by runner guardrails.\n' >>"${recovery_decision_file}"
      fi
      last_verdict="BLOCKED"
      break
      ;;
    BLOCKED|*)
      append_recovery_decision "${padded}" "BLOCKED" "${recovery_decision_file}"
      last_verdict="BLOCKED"
      break
      ;;
  esac
done

escalation_prompt="${TASK_RUN_DIR}/escalation.prompt.md"
{
  render_template "${LONGRUN_DIR}/prompts/escalate.md"
  printf '\n\nAnalysis summary:\n'
  cat "${TASK_RUN_DIR}/analysis.md"
  printf '\n\nLatest builder summary:\n'
  ls "${TASK_RUN_DIR}"/builder-attempt-*.md >/dev/null 2>&1 && cat "$(ls "${TASK_RUN_DIR}"/builder-attempt-*.md | sort | tail -n 1)"
  printf '\n\nLatest verifier report:\n'
  ls "${TASK_RUN_DIR}"/verifier-attempt-*.md >/dev/null 2>&1 && cat "$(ls "${TASK_RUN_DIR}"/verifier-attempt-*.md | sort | tail -n 1)"
  printf '\n\nLatest recovery decision:\n'
  latest_recovery="$(find "${TASK_RUN_DIR}" -maxdepth 1 -name 'recovery-decision-attempt-*.md' ! -name '*.prompt.md' -print 2>/dev/null | sort | tail -n 1 || true)"
  [[ -n "${latest_recovery}" ]] && cat "${latest_recovery}"
  printf '\n\nLatest checks log tail:\n'
  latest_checks="$(ls "${TASK_RUN_DIR}"/checks-attempt-*.log 2>/dev/null | sort | tail -n 1 || true)"
  [[ -n "${latest_checks}" ]] && tail -n 240 "${latest_checks}"
} >"${escalation_prompt}"

run_codex \
  "escalation" \
  "${CODEX_ANALYZE_EFFORT}" \
  "read-only" \
  "${escalation_prompt}" \
  "${TASK_RUN_DIR}/escalation.md" \
  "${TASK_RUN_DIR}/escalation.jsonl" || true

{
  printf '# %s summary\n\n' "${TASK_KEY}"
  printf '%s\n' "- verdict: ${last_verdict}"
  printf '%s\n' "- checks_status: ${last_checks_status}"
  printf '%s\n' "- task doc: ${TASK_DOC}"
  printf '%s\n' "- escalation: ${TASK_RUN_DIR}/escalation.md"
  [[ -f "${TASK_RUN_DIR}/recovery-summary.md" ]] && printf '%s\n' "- recovery: ${TASK_RUN_DIR}/recovery-summary.md"
} >"${TASK_RUN_DIR}/summary.md"

exit 2
