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

usage() {
  printf 'Usage: %s [run-dir]\n' "$(basename "$0")" >&2
}

load_config_defaults "${LONGRUN_DIR}/config.env"
load_config_defaults "${LONGRUN_DIR}/config.defaults.env"

MONITOR_WAIT_SECONDS="${MONITOR_WAIT_SECONDS:-60}"

if (( $# > 1 )); then
  usage
  exit 2
fi

if [[ ! "${MONITOR_WAIT_SECONDS}" =~ ^[0-9]+$ ]]; then
  printf '[wait-and-monitor][ERROR] MONITOR_WAIT_SECONDS must be a non-negative integer: %s\n' "${MONITOR_WAIT_SECONDS}" >&2
  exit 2
fi

if (( MONITOR_WAIT_SECONDS > 0 )); then
  sleep "${MONITOR_WAIT_SECONDS}"
fi

if (( $# == 1 )); then
  exec "${SCRIPT_DIR}/monitor-pipeline.sh" "$1"
fi
exec "${SCRIPT_DIR}/monitor-pipeline.sh"
