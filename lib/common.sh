#!/usr/bin/env bash
# lib/common.sh — Shared constants, logging, UI helpers, and prompt utilities.
# Sourced by passthrough-setup.sh; not meant to run standalone.

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
SCRIPT_NAME="${SCRIPT_NAME:-$(basename "$0")}"
STATE_DIR="${STATE_DIR:-/etc/passthrough}"
BACKUP_DIR="${BACKUP_DIR:-${STATE_DIR}/backups}"
STATE_FILE="${STATE_FILE:-${STATE_DIR}/passthrough.conf}"
TIMESTAMP="${TIMESTAMP:-$(date +%Y%m%d-%H%M%S)}"
DRY_RUN="${DRY_RUN:-0}"

# ---------------------------------------------------------------------------
# Colors (auto-disabled when stdout is not a terminal or NO_COLOR is set)
# ---------------------------------------------------------------------------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'
  C_CYAN=$'\033[36m'
else
  C_RESET="" C_BOLD="" C_DIM="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_CYAN=""
fi

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log() {
  printf '%b[%s]%b %s\n' "${C_BLUE}" "${SCRIPT_NAME}" "${C_RESET}" "$*"
}

warn() {
  printf '%b[%s] WARN:%b %s\n' "${C_YELLOW}" "${SCRIPT_NAME}" "${C_RESET}" "$*" >&2
}

fail() {
  printf '%b[%s] ERROR:%b %s\n' "${C_RED}" "${SCRIPT_NAME}" "${C_RESET}" "$*" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# Dry-run wrapper
# ---------------------------------------------------------------------------
run() {
  if (( DRY_RUN )); then
    printf '[dry-run] %s\n' "$*"
    return 0
  fi
  "$@"
}

# ---------------------------------------------------------------------------
# UI chrome
# ---------------------------------------------------------------------------
ui_hr() {
  printf '%b\n' "${C_DIM}------------------------------------------------------------------------${C_RESET}"
}

ui_space() { printf '\n'; }

ui_box() {
  local text="$1" pad border
  printf -v pad '%*s' $(( ${#text} + 2 )) ''
  border="${pad// /═}"
  printf '\n  ╔%s╗\n  ║ %s ║\n  ╚%s╝\n\n' "${border}" "${text}" "${border}"
}

ui_section() {
  ui_space
  ui_hr
  printf '%b%s%b\n' "${C_BOLD}${C_CYAN}" "$1" "${C_RESET}"
  ui_hr
}

ui_kv() {
  printf '  %b%-20s%b %s\n' "${C_DIM}" "$1" "${C_RESET}" "$2"
}

ui_note() {
  printf '%b%s%b\n' "${C_DIM}" "$1" "${C_RESET}"
}

ui_banner() {
  ui_box ">> One-Click Passthrough <<"
  printf '  %bInteractive Windows GPU passthrough setup%b\n' "${C_DIM}" "${C_RESET}"
}

# ---------------------------------------------------------------------------
# Privilege escalation (sudo/doas/pkexec)
# ---------------------------------------------------------------------------
ROOT_ESC=""

detect_escalation_cmd() {
  local cmd
  for cmd in sudo doas pkexec; do
    if command -v "${cmd}" >/dev/null 2>&1; then
      ROOT_ESC="${cmd}"
      return 0
    fi
  done
  ROOT_ESC="sudo"
}

run_privileged() {
  if [[ "${EUID}" -eq 0 ]]; then
    "$@"
  else
    ${ROOT_ESC:-sudo} "$@"
  fi
}

# ---------------------------------------------------------------------------
# Prompts
# ---------------------------------------------------------------------------
prompt() {
  local message="$1"
  local default="${2:-}"
  local answer
  if [[ -n "${default}" ]]; then
    read -r -p "$(printf '%b›%b %s %b[%s]%b: ' "${C_GREEN}" "${C_RESET}" "${message}" "${C_DIM}" "${default}" "${C_RESET}")" answer
    printf '%s\n' "${answer:-$default}"
  else
    read -r -p "$(printf '%b›%b %s: ' "${C_GREEN}" "${C_RESET}" "${message}")" answer
    printf '%s\n' "${answer}"
  fi
}

prompt_menu_choice() {
  local message="$1"
  local default_index="$2"
  shift 2
  local options=("$@")
  local answer selected index

  while :; do
    index=1
    for selected in "${options[@]}"; do
      printf '  %b%2d)%b %s\n' "${C_BLUE}" "${index}" "${C_RESET}" "${selected}" >&2
      index=$((index + 1))
    done
    answer="$(prompt "${message}" "${default_index}")"
    if [[ "${answer}" =~ ^[1-9][0-9]*$ ]]; then
      selected="${options[$((answer - 1))]:-}"
      if [[ -n "${selected}" ]]; then
        printf '%s\n' "${selected}"
        return 0
      fi
    fi
    warn "Choose one of the listed options."
  done
}

prompt_secret() {
  local message="$1"
  local default="${2:-}"
  local answer
  while :; do
    if [[ -n "${default}" ]]; then
      read -r -s -p "$(printf '%b›%b %s %b[hidden, press Enter to keep current]%b: ' "${C_GREEN}" "${C_RESET}" "${message}" "${C_DIM}" "${C_RESET}")" answer
      printf '\n' >&2
      printf '%s\n' "${answer:-$default}"
      return 0
    fi
    read -r -s -p "$(printf '%b›%b %s: ' "${C_GREEN}" "${C_RESET}" "${message}")" answer
    printf '\n' >&2
    [[ -n "${answer}" ]] || {
      warn "${message} cannot be blank."
      continue
    }
    printf '%s\n' "${answer}"
    return 0
  done
}

prompt_number() {
  local label="$1"
  local default="$2"
  local min="${3:-1}"
  local answer

  while :; do
    answer="$(prompt "${label}" "${default}")"
    [[ "${answer}" =~ ^[0-9]+$ ]] || {
      warn "${label} must be a whole number."
      continue
    }
    (( answer >= min )) || {
      warn "${label} must be at least ${min}."
      continue
    }
    printf '%s\n' "${answer}"
    return 0
  done
}

confirm() {
  local message="$1"
  local default="${2:-y}"
  local suffix='[y/N]'
  local answer
  [[ "${default}" == "y" ]] && suffix='[Y/n]'
  read -r -p "$(printf '%b?%b %s %b%s%b: ' "${C_BLUE}" "${C_RESET}" "${message}" "${C_DIM}" "${suffix}" "${C_RESET}")" answer
  answer="${answer:-$default}"
  [[ "${answer}" =~ ^[Yy]([Ee][Ss])?$ ]]
}

xml_escape() {
  local value="${1:-}"
  value="${value//&/&amp;}"
  value="${value//</&lt;}"
  value="${value//>/&gt;}"
  printf '%s\n' "${value}"
}

# ---------------------------------------------------------------------------
# Filesystem helpers
# ---------------------------------------------------------------------------
ensure_dir() {
  [[ -d "$1" ]] || run mkdir -p "$1"
}

backup_file() {
  local file="$1"
  [[ -e "${file}" ]] || return 0
  ensure_dir "${BACKUP_DIR}"
  run cp -a "${file}" "${BACKUP_DIR}/$(basename "${file}").${TIMESTAMP}.bak"
}

write_file() {
  local path="$1"
  shift
  ensure_dir "$(dirname "${path}")"
  backup_file "${path}"
  if (( DRY_RUN )); then
    printf '[dry-run] write %s\n' "${path}"
    return 0
  fi
  printf '%s' "$1" > "${path}"
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || fail "Run this script as root."
}

available_space_gb() {
  local target="${1:-/var/lib/libvirt/images}"
  df -BG "${target}" 2>/dev/null | awk 'NR==2 {gsub(/G/, "", $4); print $4; exit}'
}

required_space_gb() {
  local disk_size_gb="${1:-64}"
  local iso_overhead_gb="${2:-10}"
  printf '%s\n' "$((disk_size_gb + iso_overhead_gb))"
}

check_disk_space() {
  local target="$1"
  local disk_size_gb="$2"
  local existing_disk_path="${3:-}"
  local required available
  if [[ -n "${existing_disk_path}" && -f "${existing_disk_path}" ]]; then
    required="10"
  else
    required="$(required_space_gb "${disk_size_gb}" "10")"
  fi
  available="$(available_space_gb "${target}" || true)"
  [[ -n "${available}" ]] || {
    warn "Could not determine free disk space for ${target}"
    return 0
  }
  if (( available < required )); then
    if [[ -n "${existing_disk_path}" && -f "${existing_disk_path}" ]]; then
      fail "Insufficient free space at ${target}: ${available}G available, ${required}G required (~10G install media overhead while reusing existing VM disk ${existing_disk_path})."
    fi
    fail "Insufficient free space at ${target}: ${available}G available, ${required}G required (${disk_size_gb}G VM disk + ~10G install media overhead)."
  fi
}

file_size_bytes() {
  local path="$1"
  stat -c '%s' "${path}" 2>/dev/null || wc -c < "${path}" 2>/dev/null
}
