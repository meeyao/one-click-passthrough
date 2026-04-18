#!/usr/bin/env bash
# lib/bootloader.sh — GRUB, systemd-boot, and Limine kernel command line management.
# Sourced by passthrough-setup.sh; requires lib/common.sh.

normalize_cmdline() {
  printf '%s\n' "$*" | awk '{$1=$1; print}'
}

extract_grub_cmdline_default() {
  local file="$1"
  local current
  current="$(grep -E '^GRUB_CMDLINE_LINUX_DEFAULT=' "${file}" | head -n1 | cut -d'"' -f2)"
  current="${current#GRUB_CMDLINE_LINUX_DEFAULT=}"
  current="${current#\'}"
  current="${current%\'}"
  normalize_cmdline "${current}"
}

cmdline_add_tokens() {
  local current="$1"
  shift
  local token updated="${current}"
  for token in "$@"; do
    [[ -n "${token}" ]] || continue
    if ! printf ' %s ' "${updated}" | grep -Fq " ${token} "; then
      updated="${updated} ${token}"
    fi
  done
  normalize_cmdline "${updated}"
}

cmdline_remove_prefix() {
  local current="$1"
  local prefix="$2"
  printf '%s\n' "${current}" | awk -v prefix="${prefix}" '
    {
      out=""
      for (i = 1; i <= NF; i++) {
        if (index($i, prefix) == 1) {
          continue
        }
        out = out ? out " " $i : $i
      }
      print out
    }'
}

update_grub_cmdline() {
  local args="$1"
  local file="/etc/default/grub"
  local current updated
  backup_file "${file}"
  current="$(extract_grub_cmdline_default "${file}")"
  updated="$(cmdline_add_tokens "${current}" ${args})"
  if (( DRY_RUN )); then
    printf '[dry-run] update %s GRUB_CMDLINE_LINUX_DEFAULT -> %s\n' "${file}" "${updated}"
    return 0
  fi
  sed -i -E "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"${updated}\"|" "${file}"
}

remove_grub_token_prefix() {
  local prefix="$1"
  local file="/etc/default/grub"
  local current updated
  backup_file "${file}"
  current="$(extract_grub_cmdline_default "${file}")"
  updated="$(cmdline_remove_prefix "${current}" "${prefix}")"
  if (( DRY_RUN )); then
    printf '[dry-run] remove tokens with prefix %s from %s\n' "${prefix}" "${file}"
    return 0
  fi
  sed -i -E "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"${updated}\"|" "${file}"
}

update_systemd_boot_cmdline() {
  local args="$1"
  local file="/etc/kernel/cmdline"
  local current updated
  current="$(tr '\n' ' ' < "${file}")"
  updated="$(cmdline_add_tokens "${current}" ${args})"
  write_file "${file}" "${updated}"$'\n'
}

remove_systemd_boot_prefix() {
  local prefix="$1"
  local file="/etc/kernel/cmdline"
  local current updated
  current="$(tr '\n' ' ' < "${file}")"
  updated="$(cmdline_remove_prefix "${current}" "${prefix}")"
  write_file "${file}" "${updated}"$'\n'
}

# ---------------------------------------------------------------------------
# Limine bootloader support
# ---------------------------------------------------------------------------
LIMINE_ENTRY_REGEX='^KERNEL_CMDLINE\[.*\]\+?='

update_limine_cmdline() {
  local args="$1"
  local file="/etc/default/limine"
  [[ -f "${file}" ]] || return 1
  backup_file "${file}"

  if (( DRY_RUN )); then
    printf '[dry-run] append to Limine KERNEL_CMDLINE entries: %s\n' "${args}"
    return 0
  fi

  # Strip existing VFIO/IOMMU tokens, then append new ones
  local vfio_regex='(intel_iommu=[^ ]*|iommu=[^ ]*|vfio-pci\.ids=[^ ]*|rd\.driver\.pre=[^ ]*)'
  sed -E -i "/${LIMINE_ENTRY_REGEX}/ {
    s/${vfio_regex}//g;
    s/[[:space:]]+/ /g;
  }" "${file}"

  if ! grep -E "${LIMINE_ENTRY_REGEX}" "${file}" | grep -q "iommu="; then
    sed -E -i "/${LIMINE_ENTRY_REGEX}/ s/\"$/ ${args}\"/" "${file}"
  fi
}

remove_limine_token_prefix() {
  local prefix="$1"
  local file="/etc/default/limine"
  [[ -f "${file}" ]] || return 0
  backup_file "${file}"
  local escaped_prefix
  escaped_prefix="$(printf '%s' "${prefix}" | sed 's/[.[\/]/\\&/g')"
  sed -E -i "/${LIMINE_ENTRY_REGEX}/ {
    s/${escaped_prefix}[^ ]*//g;
    s/[[:space:]]+/ /g;
    s/\"[[:space:]]+\"/\"\"/;
  }" "${file}"
}

configure_bootloader() {
  local mode="$1"
  local vfio_ids="$2"
  local cpu_vendor="$3"
  local bootloader iommu_args args

  bootloader="$(detect_bootloader)"
  iommu_args="$(default_iommu_params "${cpu_vendor}")"
  args="${iommu_args}"

  if [[ "${mode}" == "double" ]]; then
    args="${args} rd.driver.pre=vfio-pci vfio-pci.ids=${vfio_ids}"
  fi

  case "${bootloader}" in
    grub)
      update_grub_cmdline "${args}"
      if [[ "${mode}" == "single" ]]; then
        remove_grub_token_prefix "vfio-pci.ids="
        remove_grub_token_prefix "rd.driver.pre="
      fi
      ;;
    systemd-boot)
      update_systemd_boot_cmdline "${args}"
      if [[ "${mode}" == "single" ]]; then
        remove_systemd_boot_prefix "vfio-pci.ids="
        remove_systemd_boot_prefix "rd.driver.pre="
      fi
      ;;
    limine)
      update_limine_cmdline "${args}"
      if [[ "${mode}" == "single" ]]; then
        remove_limine_token_prefix "vfio-pci.ids="
        remove_limine_token_prefix "rd.driver.pre="
      fi
      ;;
    *)
      fail "Unsupported bootloader. Expected GRUB, systemd-boot, or Limine."
      ;;
  esac

  printf '%s\n' "${bootloader}"
}

rebuild_bootloader() {
  local cmd=() output_path tmp_log
  case "$1" in
    grub)
      tmp_log="$(mktemp)"
      if [[ -d /boot/grub ]]; then
        cmd=(grub-mkconfig -o /boot/grub/grub.cfg)
        output_path="/boot/grub/grub.cfg"
      elif [[ -d /boot/grub2 ]]; then
        cmd=(grub2-mkconfig -o /boot/grub2/grub.cfg)
        output_path="/boot/grub2/grub.cfg"
      else
        warn "GRUB detected but grub.cfg path was not obvious. Rebuild it manually."
        rm -f "${tmp_log}"
        return 1
      fi
      if (( DRY_RUN )); then
        printf '[dry-run] %s\n' "${cmd[*]}"
        rm -f "${tmp_log}"
        return 0
      fi
      if "${cmd[@]}" > >(tee "${tmp_log}") 2> >(tee -a "${tmp_log}" >&2); then
        rm -f "${tmp_log}"
        return 0
      fi
      warn "GRUB rebuild failed. The passthrough config files were written, but ${output_path} was not regenerated."
      warn "This usually means there is a syntax error in /etc/default/grub or in one of the scripts under /etc/grub.d."
      warn "Check the failing line reported above and inspect /boot/grub/grub.cfg.new if GRUB created it."
      rm -f "${tmp_log}"
      return 1
      ;;
    systemd-boot)
      if command -v kernel-install >/dev/null 2>&1; then
        run kernel-install add "$(uname -r)" "/usr/lib/modules/$(uname -r)/vmlinuz" || true
      fi
      if command -v bootctl >/dev/null 2>&1; then
        run bootctl update || true
      fi
      ;;
    limine)
      if command -v limine-mkinitcpio >/dev/null 2>&1; then
        run limine-mkinitcpio || true
      else
        log "Limine config updated. Ensure your Limine configuration is regenerated."
      fi
      ;;
  esac
}
