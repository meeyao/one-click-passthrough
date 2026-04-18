#!/usr/bin/env bash
# lib/libvirt.sh — libvirt daemon configuration, networking, and service setup.
# Sourced by passthrough-setup.sh; requires lib/common.sh.

configure_libvirt() {
  local user_name="$1"
  local network_conf="/etc/libvirt/network.conf"
  local libvirtd_conf="/etc/libvirt/libvirtd.conf"

  if [[ -f "${network_conf}" ]]; then
    backup_file "${network_conf}"
    if (( DRY_RUN )); then
      printf '[dry-run] ensure firewall_backend=iptables in %s\n' "${network_conf}"
    else
      if grep -qE '^[#[:space:]]*firewall_backend' "${network_conf}"; then
        sed -i -E 's|^[#[:space:]]*firewall_backend.*|firewall_backend = "iptables"|' "${network_conf}"
      else
        printf '\nfirewall_backend = "iptables"\n' >> "${network_conf}"
      fi
    fi
  fi

  if [[ -f "${libvirtd_conf}" ]]; then
    backup_file "${libvirtd_conf}"
    if (( DRY_RUN )); then
      printf '[dry-run] ensure unix_sock_group/unix_sock_rw_perms in %s\n' "${libvirtd_conf}"
    else
      if grep -qE '^[#[:space:]]*unix_sock_group' "${libvirtd_conf}"; then
        sed -i -E 's|^[#[:space:]]*unix_sock_group.*|unix_sock_group = "libvirt"|' "${libvirtd_conf}"
      else
        printf '\nunix_sock_group = "libvirt"\n' >> "${libvirtd_conf}"
      fi
      if grep -qE '^[#[:space:]]*unix_sock_rw_perms' "${libvirtd_conf}"; then
        sed -i -E 's|^[#[:space:]]*unix_sock_rw_perms.*|unix_sock_rw_perms = "0770"|' "${libvirtd_conf}"
      else
        printf 'unix_sock_rw_perms = "0770"\n' >> "${libvirtd_conf}"
      fi
    fi
  fi

  if id -nG "${user_name}" 2>/dev/null | tr ' ' '\n' | grep -qx 'libvirt'; then
    :
  else
    run usermod -aG libvirt "${user_name}"
  fi

  if id -nG "${user_name}" 2>/dev/null | tr ' ' '\n' | grep -qx 'input'; then
    :
  else
    run usermod -aG input "${user_name}"
  fi

  run systemctl enable --now libvirtd.service
  run systemctl enable --now libvirtd.socket
  run virsh net-autostart default

  # Randomize the default network MAC and move to 10.0.0.x subnet
  local network_xml="/etc/libvirt/qemu/networks/default.xml"
  if [[ -f "${network_xml}" ]]; then
    local oui="b0:4e:26"
    local random_mac="${oui}:$(printf '%02x:%02x:%02x' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)))"
    backup_file "${network_xml}"
    if (( DRY_RUN )); then
      printf '[dry-run] spoof MAC and IP in %s -> %s\n' "${network_xml}" "${random_mac}"
    else
      sed -i \
        -e "s|<mac address='[0-9A-Fa-f:]\{17\}'|<mac address='${random_mac}'|g" \
        -e "s|address='192\.168\.122\.1'|address='10.0.0.1'|g" \
        -e "s|start='192\.168\.122\.2'|start='10.0.0.2'|g" \
        -e "s|end='192\.168\.122\.254'|end='10.0.0.254'|g" \
        "${network_xml}"
    fi
  fi

  if [[ "$(virsh net-info default 2>/dev/null | awk -F': *' '/^Active:/ {print tolower($2); exit}')" != "yes" ]]; then
    run virsh net-start default
  fi
  run systemctl restart libvirtd.service
}
