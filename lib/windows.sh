#!/usr/bin/env bash
# lib/windows.sh — Windows version/language maps, unattend XML, SetupComplete.cmd.
# Sourced by passthrough-setup.sh; requires lib/common.sh.

# ---------------------------------------------------------------------------
# Windows version normalization
# ---------------------------------------------------------------------------
normalize_windows_version() {
  local version="${1:-}"
  version="$(printf '%s' "${version}" | tr '[:upper:]' '[:lower:]')"
  version="$(printf '%s' "${version}" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  [[ -z "${version}" ]] && version="win11x64"

  case "${version}" in
    11|11p|win11|pro11|win11p|windows11|"windows 11")
      printf 'win11x64\n' ;;
    11e|win11e|windows11e|"windows 11e")
      printf 'win11x64-enterprise-eval\n' ;;
    11i|11iot|iot11|win11i|win11-iot|win11x64-iot)
      printf 'win11x64-enterprise-iot-eval\n' ;;
    11l|11ltsc|ltsc11|win11l|win11-ltsc|win11x64-ltsc)
      printf 'win11x64-enterprise-ltsc-eval\n' ;;
    10|10p|win10|pro10|win10p|windows10|"windows 10")
      printf 'win10x64\n' ;;
    10e|win10e|windows10e|"windows 10e")
      printf 'win10x64-enterprise-eval\n' ;;
    10l|10ltsc|ltsc10|win10l|win10-ltsc|win10x64-ltsc)
      printf 'win10x64-enterprise-ltsc-eval\n' ;;
    2025|win2025|windows2025|"windows 2025")
      printf 'win2025-eval\n' ;;
    2022|win2022|windows2022|"windows 2022")
      printf 'win2022-eval\n' ;;
    2019|win2019|windows2019|"windows 2019")
      printf 'win2019-eval\n' ;;
    2016|win2016|windows2016|"windows 2016")
      printf 'win2016-eval\n' ;;
    *)
      printf '%s\n' "${version}" ;;
  esac
}

# ---------------------------------------------------------------------------
# Language normalization and lookup tables
# ---------------------------------------------------------------------------
normalize_windows_language() {
  local lang="${1:-en}"
  lang="$(printf '%s' "${lang}" | tr '[:upper:]' '[:lower:]')"
  lang="${lang//_/-}"
  case "${lang}" in
    ""|en|en-us|english) printf 'en\n' ;;
    gb|en-gb|british) printf 'en-gb\n' ;;
    ar|arabic) printf 'ar\n' ;;
    de|german|deutsch) printf 'de\n' ;;
    es|spanish|espanol|español) printf 'es\n' ;;
    fr|french|francais|français) printf 'fr\n' ;;
    it|italian|italiano) printf 'it\n' ;;
    ja|jp|japanese) printf 'ja\n' ;;
    ko|kr|korean) printf 'ko\n' ;;
    nl|dutch) printf 'nl\n' ;;
    pl|polish) printf 'pl\n' ;;
    pt|pt-br|br|portuguese|portugues|português) printf 'pt-br\n' ;;
    ru|russian) printf 'ru\n' ;;
    tr|turkish) printf 'tr\n' ;;
    uk|ua|ukrainian) printf 'uk\n' ;;
    zh|cn|chinese) printf 'zh\n' ;;
    *) printf '%s\n' "${lang}" ;;
  esac
}

windows_language_name() {
  case "$1" in
    ar) printf 'Arabic\n' ;;
    de) printf 'German\n' ;;
    en-gb) printf 'English International\n' ;;
    en) printf 'English\n' ;;
    es) printf 'Spanish\n' ;;
    fr) printf 'French\n' ;;
    it) printf 'Italian\n' ;;
    ja) printf 'Japanese\n' ;;
    ko) printf 'Korean\n' ;;
    nl) printf 'Dutch\n' ;;
    pl) printf 'Polish\n' ;;
    pt-br) printf 'Brazilian Portuguese\n' ;;
    ru) printf 'Russian\n' ;;
    tr) printf 'Turkish\n' ;;
    uk) printf 'Ukrainian\n' ;;
    zh) printf 'Chinese (Simplified)\n' ;;
    *) printf 'English\n' ;;
  esac
}

windows_language_desc() {
  case "$1" in
    ar) printf 'Arabic\n' ;;
    de) printf 'German\n' ;;
    en-gb|en) printf 'English\n' ;;
    es) printf 'Spanish\n' ;;
    fr) printf 'French\n' ;;
    it) printf 'Italian\n' ;;
    ja) printf 'Japanese\n' ;;
    ko) printf 'Korean\n' ;;
    nl) printf 'Dutch\n' ;;
    pl) printf 'Polish\n' ;;
    pt-br) printf 'Portuguese\n' ;;
    ru) printf 'Russian\n' ;;
    tr) printf 'Turkish\n' ;;
    uk) printf 'Ukrainian\n' ;;
    zh) printf 'Chinese\n' ;;
    *) printf 'English\n' ;;
  esac
}

windows_language_culture() {
  case "$1" in
    ar) printf 'ar-SA\n' ;;
    de) printf 'de-DE\n' ;;
    en-gb) printf 'en-GB\n' ;;
    en) printf 'en-US\n' ;;
    es) printf 'es-ES\n' ;;
    fr) printf 'fr-FR\n' ;;
    it) printf 'it-IT\n' ;;
    ja) printf 'ja-JP\n' ;;
    ko) printf 'ko-KR\n' ;;
    nl) printf 'nl-NL\n' ;;
    pl) printf 'pl-PL\n' ;;
    pt-br) printf 'pt-BR\n' ;;
    ru) printf 'ru-RU\n' ;;
    tr) printf 'tr-TR\n' ;;
    uk) printf 'uk-UA\n' ;;
    zh) printf 'zh-CN\n' ;;
    *) printf 'en-US\n' ;;
  esac
}

# ---------------------------------------------------------------------------
# Version / language prompt menus
# ---------------------------------------------------------------------------
prompt_windows_version() {
  local default="${1:-win11x64}"
  local options=(
    "Windows 11 Pro/Enterprise [win11x64]"
    "Windows 11 Enterprise Eval [win11x64-enterprise-eval]"
    "Windows 11 LTSC [win11x64-ltsc]"
    "Windows 10 Pro/Enterprise [win10x64]"
    "Windows 10 Enterprise Eval [win10x64-enterprise-eval]"
    "Windows Server 2022 Eval [win2022eval]"
  )
  local default_index="1"

  case "${default}" in
    win11x64-enterprise-eval) default_index="2" ;;
    win11x64-ltsc) default_index="3" ;;
    win10x64) default_index="4" ;;
    win10x64-enterprise-eval) default_index="5" ;;
    win2022eval) default_index="6" ;;
  esac

  case "$(prompt_menu_choice "Windows version" "${default_index}" "${options[@]}")" in
    *"[win11x64]") printf 'win11x64\n' ;;
    *"[win11x64-enterprise-eval]") printf 'win11x64-enterprise-eval\n' ;;
    *"[win11x64-ltsc]") printf 'win11x64-ltsc\n' ;;
    *"[win10x64]") printf 'win10x64\n' ;;
    *"[win10x64-enterprise-eval]") printf 'win10x64-enterprise-eval\n' ;;
    *"[win2022eval]") printf 'win2022eval\n' ;;
    *) fail "Unexpected Windows version selection." ;;
  esac
}

prompt_windows_language() {
  local default="${1:-en}"
  local options=(
    "English (US) [en]"
    "English (UK) [en-gb]"
    "German [de]"
    "French [fr]"
    "Japanese [ja]"
  )
  local default_index="1"

  case "${default}" in
    en-gb) default_index="2" ;;
    de) default_index="3" ;;
    fr) default_index="4" ;;
    ja) default_index="5" ;;
  esac

  case "$(prompt_menu_choice "Windows language" "${default_index}" "${options[@]}")" in
    *"[en]") printf 'en\n' ;;
    *"[en-gb]") printf 'en-gb\n' ;;
    *"[de]") printf 'de\n' ;;
    *"[fr]") printf 'fr\n' ;;
    *"[ja]") printf 'ja\n' ;;
    *) fail "Unexpected Windows language selection." ;;
  esac
}
