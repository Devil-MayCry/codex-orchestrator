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
CODEX_BUILD_EFFORT="${CODEX_BUILD_EFFORT:-high}"
CODEX_VERIFY_EFFORT="${CODEX_VERIFY_EFFORT:-high}"
CODEX_SMOKE_EFFORTS="${CODEX_SMOKE_EFFORTS:-${CODEX_ANALYZE_EFFORT} ${CODEX_BUILD_EFFORT} ${CODEX_VERIFY_EFFORT}}"
REQUIRED_COMMANDS="${REQUIRED_COMMANDS:-}"
PROJECT_PREFLIGHT_COMMANDS="${PROJECT_PREFLIGHT_COMMANDS:-}"
RUNS_DIR="${RUNS_DIR:-ops/hermes-longrun/runs}"
USE_HERMES_KANBAN="${USE_HERMES_KANBAN:-1}"
REQUIRE_KANBAN="${REQUIRE_KANBAN:-0}"
SKIP_CODEX_SMOKE="${SKIP_CODEX_SMOKE:-0}"
SKIP_HERMES_SMOKE="${SKIP_HERMES_SMOKE:-0}"
SKIP_RUNNER_SMOKE="${SKIP_RUNNER_SMOKE:-0}"

log() {
  printf '[preflight] %s\n' "$*"
}

warn() {
  printf '[preflight][WARN] %s\n' "$*" >&2
}

fail() {
  printf '[preflight][ERROR] %s\n' "$*" >&2
  exit 1
}

require_command() {
  local name="$1"
  command -v "${name}" >/dev/null 2>&1 || fail "Missing command: ${name}"
  log "found ${name}: $(command -v "${name}")"
}

split_commands() {
  python3 - "$1" <<'PY'
import sys
text = sys.argv[1]
for item in text.split(" &&& "):
    item = item.strip()
    if item:
        print(item)
PY
}

log "repo root: ${REPO_ROOT}"
log "longrun dir: ${LONGRUN_DIR}"

for cmd in codex hermes git rg python3; do
  require_command "${cmd}"
done
for cmd in ${REQUIRED_COMMANDS}; do
  require_command "${cmd}"
done
if [[ "${SUPERVISOR_DETACH_METHOD:-screen}" == "screen" ]]; then
  require_command screen
fi

if [[ "${SKIP_CODEX_SMOKE}" != "1" ]]; then
  for effort in ${CODEX_SMOKE_EFFORTS}; do
    codex_out="$(mktemp -t codex-longrun-smoke.XXXXXX)"
    codex_log="$(mktemp -t codex-longrun-smoke-log.XXXXXX)"
    log "running Codex CLI smoke test effort=${effort}"
    if ! codex exec \
      --ephemeral \
      --sandbox read-only \
      --cd "${REPO_ROOT}" \
      -m "${CODEX_MODEL}" \
      -c "model_reasoning_effort=\"${effort}\"" \
      -o "${codex_out}" \
      - \
      <<'PROMPT' >"${codex_log}" 2>&1; then
Smoke test only. Reply exactly CODEX_OK. Do not inspect or edit files.
PROMPT
      sed -n '1,120p' "${codex_log}" >&2
      fail "Codex smoke test failed for effort=${effort}"
    fi
    if ! grep -q 'CODEX_OK' "${codex_out}"; then
      sed -n '1,120p' "${codex_log}" >&2
      cat "${codex_out}" >&2
      fail "Codex smoke test did not return CODEX_OK for effort=${effort}"
    fi
  done
  log "Codex CLI smoke OK"
else
  warn "SKIP_CODEX_SMOKE=1; Codex smoke test skipped"
fi

if [[ "${SKIP_HERMES_SMOKE}" != "1" ]]; then
  log "running Hermes smoke test"
  hermes_out="$(hermes -z 'Smoke test only. Reply exactly HERMES_OK.' 2>&1 || true)"
  if ! grep -q 'HERMES_OK' <<<"${hermes_out}"; then
    printf '%s\n' "${hermes_out}" >&2
    fail "Hermes smoke test failed"
  fi
  log "Hermes smoke OK"
else
  warn "SKIP_HERMES_SMOKE=1; Hermes smoke test skipped"
fi

tracked_runtime="$(git -C "${REPO_ROOT}" ls-files "${RUNS_DIR}/*" 2>/dev/null || true)"
if [[ -n "${tracked_runtime}" ]]; then
  fail "runtime files are tracked and can break unattended dirty checks: ${tracked_runtime//$'\n'/, }"
fi

if [[ -f "${LONGRUN_DIR}/task-queue.md" ]]; then
  if grep -q '^TASK|EX-001|' "${LONGRUN_DIR}/task-queue.md"; then
    fail "task-queue.md still contains the EX-001 placeholder. Replace it with real tasks before launching."
  fi
  if ! grep -q '^TASK|' "${LONGRUN_DIR}/task-queue.md"; then
    fail "task-queue.md has no TASK| lines. The runner would treat the queue as empty."
  fi
else
  fail "task-queue.md is missing under ${LONGRUN_DIR}"
fi

if [[ "${SKIP_RUNNER_SMOKE}" != "1" ]]; then
  first_task="$(awk -F'|' '$1 == "TASK" { print $2; exit }' "${LONGRUN_DIR}/task-queue.md")"
  runner_smoke_log="$(mktemp -t hermes-runner-smoke.XXXXXX)"
  runner_smoke_id="preflight-runner-smoke-$(date +%Y%m%d-%H%M%S)"
  runner_smoke_run_dir="${REPO_ROOT}/${RUNS_DIR%/}/${runner_smoke_id}"
  log "running runner dry-run smoke test task=${first_task}"
  if ! DRY_RUN=1 \
    ALLOW_DIRTY_WORKTREE=1 \
    RUNS_DIR="${RUNS_DIR}" \
    RUN_ID="${runner_smoke_id}" \
    RUN_DIR="${runner_smoke_run_dir}" \
    DRY_RUN_VERIFY_VERDICT=PASS_COMMIT \
    bash "${SCRIPT_DIR}/run-one-task.sh" "${first_task}" >"${runner_smoke_log}" 2>&1; then
    sed -n '1,160p' "${runner_smoke_log}" >&2
    fail "runner dry-run smoke test failed"
  fi
  log "runner dry-run smoke OK"
else
  warn "SKIP_RUNNER_SMOKE=1; runner dry-run smoke test skipped"
fi

if [[ -n "${PROJECT_PREFLIGHT_COMMANDS}" ]]; then
  while IFS= read -r cmd; do
    [[ -z "${cmd}" ]] && continue
    log "project preflight: ${cmd}"
    (cd "${REPO_ROOT}" && bash -lc "${cmd}") || fail "project preflight failed: ${cmd}"
  done < <(split_commands "${PROJECT_PREFLIGHT_COMMANDS}")
else
  warn "PROJECT_PREFLIGHT_COMMANDS is empty; add project dependency/import/build checks before unattended runs"
fi

if [[ "${USE_HERMES_KANBAN}" == "1" ]]; then
  kanban_db="$(hermes kanban boards show 2>/dev/null | awk -F'DB path:[[:space:]]*' '/DB path:/ {print $2; exit}')"
  kanban_db="${kanban_db:-${HOME}/.hermes/kanban.db}"
  if [[ -f "${kanban_db}" ]]; then
    log "Hermes kanban DB exists: ${kanban_db}"
    hermes kanban stats >/dev/null || fail "Hermes kanban DB exists but stats failed"
  else
    msg="Hermes kanban DB is missing at ${kanban_db}. Run scripts/setup-hermes-kanban.sh before unattended execution."
    if [[ "${REQUIRE_KANBAN}" == "1" ]]; then
      fail "${msg}"
    fi
    warn "${msg}"
  fi
fi

log "preflight completed"
