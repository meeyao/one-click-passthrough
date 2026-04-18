#!/usr/bin/env bash
# lib/hooks.sh — Single-GPU prepare/release hook generation and qemu dispatcher.
# Sourced by passthrough-setup.sh; requires lib/common.sh.

create_single_gpu_hooks() {
  local vm_name="$1"
  local session_user="$2"
  local video_pci="$3"
  local audio_pci="$4"
  local video_node audio_node prepare release dispatcher

  video_node="pci_${video_pci//[:.]/_}"
  audio_node="pci_${audio_pci//[:.]/_}"

  prepare=$(cat <<EOF
#!/usr/bin/env bash
# qemu-single-gpu-prepare — runs as root via libvirt QEMU hook on VM start.
# CRITICAL DESIGN RULES:
#   1. Never use set -e — every failure must be handled explicitly so the
#      display can always be restored if we abort mid-sequence.
#   2. Always call emergency_restore before any hard exit so the user isn't
#      left with a black screen and no way back.
#   3. VT consoles are ONLY unbound AFTER the GPU driver has confirmed it
#      is fully gone — not before.

GPU_VIDEO_NODE="${video_node}"
GPU_AUDIO_NODE="${audio_node}"
GPU_PCI="${video_pci}"
GPU_AUDIO_PCI="${audio_pci}"
WAIT_SECONDS=20
STATE_DIR="/run/passthrough"
SESSION_USER="${session_user}"

# ── helpers ────────────────────────────────────────────────────────────────

log() {
  logger -t qemu-single-gpu-prepare -- "\$*"
  echo "[qemu-single-gpu-prepare] \$*" >&2
}

# Restore the display manager and GPU so the user can still use their system.
# Called before any hard exit so we never leave a black screen.
emergency_restore() {
  log "EMERGENCY RESTORE: attempting to bring display back..."
  # Re-bind VT consoles (in case we already unbound)
  for vt in /sys/class/vtconsole/vtcon*; do
    [[ -w "\${vt}/bind" ]] || continue
    echo 1 > "\${vt}/bind" 2>/dev/null || true
  done
  # Re-bind EFI framebuffer
  if [[ -e /sys/bus/platform/drivers/efi-framebuffer/bind ]]; then
    echo efi-framebuffer.0 > /sys/bus/platform/drivers/efi-framebuffer/bind 2>/dev/null || true
  fi
  # Reattach devices from vfio back to host driver
  virsh nodedev-reattach "\${GPU_AUDIO_NODE}" >/dev/null 2>&1 || true
  virsh nodedev-reattach "\${GPU_VIDEO_NODE}" >/dev/null 2>&1 || true
  modprobe -r vfio_pci vfio_iommu_type1 vfio 2>/dev/null || true
  # Reload GPU driver
  reload_gpu_drivers_for_pci "\${GPU_PCI}"
  # Restart display manager
  local dm_unit
  dm_unit="\$(saved_display_manager)"
  log "Restarting \${dm_unit}..."
  systemctl restart "\${dm_unit}" 2>/dev/null || systemctl start "\${dm_unit}" 2>/dev/null || true
  systemctl start nvidia-persistenced.service nvidia-powerd.service 2>/dev/null || true
  log "Emergency restore complete. Your desktop should return within a few seconds."
}

saved_display_manager() {
  local sf="\${STATE_DIR}/\${GPU_VIDEO_NODE}.display-manager"
  if [[ -f "\${sf}" ]]; then
    cat "\${sf}"
  else
    echo "display-manager.service"
  fi
}

reload_gpu_drivers_for_pci() {
  local pci="\$1" driver
  driver="\$(lspci -nnk -s "\${pci}" 2>/dev/null | awk -F': ' '/Kernel modules/ {print \$2; exit}' | awk '{print \$1}')"
  case "\${driver}" in
    nvidia)
      for mod in nvidia nvidia_modeset nvidia_uvm nvidia_drm; do
        modprobe "\${mod}" 2>/dev/null || true
      done
      ;;
    amdgpu|radeon|nouveau|xe|i915)
      modprobe "\${driver}" 2>/dev/null || true
      ;;
    *)
      # Fallback: try all common ones
      for mod in nvidia nvidia_modeset nvidia_uvm nvidia_drm amdgpu radeon i915; do
        modprobe "\${mod}" 2>/dev/null || true
      done
      ;;
  esac
}

nvidia_device_minor_for_pci() {
  local info_file="/proc/driver/nvidia/gpus/\${GPU_PCI}/information"
  [[ -f "\${info_file}" ]] || return 0
  awk -F': *' '/Device Minor/ {print \$2; exit}' "\${info_file}" 2>/dev/null || true
}

gpu_device_paths() {
  local sysfs_base="/sys/bus/pci/devices/\${GPU_PCI}"
  local drm_dir entry devnode minor
  [[ -d "\${sysfs_base}" ]] || return 0

  drm_dir="\${sysfs_base}/drm"
  if [[ -d "\${drm_dir}" ]]; then
    for entry in "\${drm_dir}"/card* "\${drm_dir}"/renderD*; do
      [[ -e "\${entry}" ]] || continue
      devnode="/dev/\$(basename "\${entry}")"
      [[ -e "\${devnode}" ]] && printf '%s\n' "\${devnode}"
    done
  fi

  minor="\$(nvidia_device_minor_for_pci)"
  if [[ "\${minor}" =~ ^[0-9]+\$ ]] && [[ -e "/dev/nvidia\${minor}" ]]; then
    printf '%s\n' "/dev/nvidia\${minor}"
  fi
  # Also include /dev/nvidiactl, /dev/nvidia-modeset if they exist
  for extra in /dev/nvidiactl /dev/nvidia-modeset; do
    [[ -e "\${extra}" ]] && printf '%s\n' "\${extra}"
  done
}

state_file_for() {
  local suffix="\$1"
  printf '%s/%s.%s\n' "\${STATE_DIR}" "\${GPU_VIDEO_NODE}" "\${suffix}"
}

user_uid() {
  id -u "\${SESSION_USER}" 2>/dev/null || true
}

user_bus_ready() {
  local uid
  uid="\$(user_uid)"
  [[ -n "\${uid}" ]] && [[ -S "/run/user/\${uid}/bus" ]]
}

get_active_display_manager() {
  local dm
  dm=\$(systemctl list-units --type=service --state=running 2>/dev/null \
    | grep -E 'gdm|sddm|lightdm|lxdm|ly|greetd' \
    | awk '{print \$1}' | head -n1)
  echo "\${dm:-display-manager.service}"
}

# Signal KWin / DRM compositors to gracefully release the GPU card node before
# we yank the driver. Technique from VFIO-Nvidia-dynamic-unbind:
#   udevadm trigger --action=remove /dev/dri/card1
# which maps to kwin drm_backend.cpp:L190 hot-remove path.
udevadm_signal_drm_remove() {
  local sysfs_base="/sys/bus/pci/devices/\${GPU_PCI}/drm"
  local card
  [[ -d "\${sysfs_base}" ]] || return 0
  for card in "\${sysfs_base}"/card*; do
    [[ -d "\${card}" ]] || continue
    log "Sending udev remove event to DRM card: \${card}"
    udevadm trigger --action=remove "\${card}" 2>/dev/null || true
  done
  sleep 1
}

stop_system_units() {
  local dm
  dm="\$(get_active_display_manager)"
  log "Stopping display manager: \${dm}"
  systemctl stop "\${dm}" 2>/dev/null || true
  # Give the DM up to 5s to release GPU resources
  local i=0
  while (( i < 5 )); do
    systemctl is-active "\${dm}" >/dev/null 2>&1 || break
    sleep 1
    (( i++ ))
  done
  systemctl stop nvidia-persistenced.service nvidia-powerd.service 2>/dev/null || true
}

stop_user_units() {
  local uid unit
  uid="\$(user_uid)"
  [[ -n "\${uid}" ]] || return 0

  if user_bus_ready; then
    for unit in graphical-session.target wayland-session.target \
                plasma-plasmashell.service xdg-desktop-portal.service \
                niri.service; do
      runuser -u "\${SESSION_USER}" -- env \
        XDG_RUNTIME_DIR="/run/user/\${uid}" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/\${uid}/bus" \
        systemctl --user stop "\${unit}" 2>/dev/null || true
    done
  fi
}

kill_user_processes() {
  # Kill compositors and GPU-holding user processes
  local -a procs=(
    Xorg Xwayland
    sway Hyprland kwin_wayland kwin_x11 gnome-shell plasmashell
    plasma_session niri quickshell qs
    # KDE powerdevil silently holds the GPU I2C bus, blocking nvidia_drm unload
    org_kde_powerdevil
    # Common GPU users
    firefox chromium chrome Discord discord zoom obs
  )
  local proc
  for proc in "\${procs[@]}"; do
    pkill -u "\${SESSION_USER}" -TERM -x "\${proc}" 2>/dev/null || true
  done
  sleep 2
  for proc in "\${procs[@]}"; do
    pkill -u "\${SESSION_USER}" -KILL -x "\${proc}" 2>/dev/null || true
  done
}

# Kill ALL processes (any user, including system) that hold open GPU device nodes.
# This is broader than kill_user_processes and is the last resort before module unload.
nuke_all_gpu_users() {
  local -a devices=()
  local pid pids_out
  mapfile -t devices < <(gpu_device_paths)
  [[ "\${#devices[@]}" -gt 0 ]] || return 0

  local count=0
  while (( count < 6 )); do
    pids_out="\$(fuser "\${devices[@]}" 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -u || true)"
    [[ -n "\${pids_out}" ]] || return 0   # Nothing left holding GPU

    # Don't kill ourselves or our parent (qemu/virsh/libvirt)
    local our_sid
    our_sid="\$(cat /proc/\$\$/sessionid 2>/dev/null || true)"
    while IFS= read -r pid; do
      [[ "\${pid}" =~ ^[0-9]+\$ ]] || continue
      [[ "\${pid}" == "\$\$" ]] && continue
      [[ "\${pid}" == "\${PPID}" ]] && continue
      local comm
      comm="\$(cat /proc/\${pid}/comm 2>/dev/null || true)"
      # Never kill libvirt/qemu infrastructure
      case "\${comm}" in
        libvirtd|virtqemud|qemu*|virsh) continue ;;
      esac
      log "Killing GPU user: pid=\${pid} comm=\${comm:-unknown}"
      kill -KILL "\${pid}" 2>/dev/null || true
    done <<< "\${pids_out}"

    sleep 1
    (( count++ ))
  done

  # Final check
  pids_out="\$(fuser "\${devices[@]}" 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -u || true)"
  if [[ -n "\${pids_out}" ]]; then
    log "WARNING: GPU still has holders after kill attempts: \$(echo "\${pids_out}" | tr '\n' ' ')"
    # Log what they are
    while IFS= read -r pid; do
      [[ "\${pid}" =~ ^[0-9]+\$ ]] || continue
      local comm user
      comm="\$(cat /proc/\${pid}/comm 2>/dev/null || true)"
      user="\$(stat -c '%U' /proc/\${pid} 2>/dev/null || true)"
      log "  Remaining holder: pid=\${pid} user=\${user:-?} cmd=\${comm:-?}"
    done <<< "\${pids_out}"
    # Continue anyway — the module unload will be attempted regardless.
    # Returning non-zero here used to abort the whole thing and black-screen us.
    return 0
  fi
}

# Release logind session seat so it drops DRM master before we unload
release_logind_seat() {
  local uid
  uid="\$(user_uid)"
  [[ -n "\${uid}" ]] || return 0
  # Tell logind to release the session's drm master
  # loginctl terminate-session works but also logs out; seat-release is gentler.
  loginctl lock-sessions 2>/dev/null || true
  sleep 0.5
  # Ask logind to release control of the session devices
  if user_bus_ready; then
    runuser -u "\${SESSION_USER}" -- env \
      XDG_RUNTIME_DIR="/run/user/\${uid}" \
      DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/\${uid}/bus" \
      gdbus call --session \
        --dest org.freedesktop.login1 \
        --object-path /org/freedesktop/login1/session/auto \
        --method org.freedesktop.login1.Session.ReleaseControl \
      2>/dev/null || true
  fi
}

wait_for_module_gone() {
  local module="\$1"
  local deadline=\$((SECONDS + WAIT_SECONDS))
  while (( SECONDS < deadline )); do
    if ! lsmod | awk '{print \$1}' | grep -qx "\${module}"; then
      return 0
    fi
    sleep 1
  done
  return 1
}

driver_in_use() {
  local pci="\$1"
  lspci -nnk -s "\${pci}" 2>/dev/null | awk -F': ' '/Kernel driver in use/ {print \$2; exit}'
}

already_detached_to_vfio() {
  [[ "\$(driver_in_use "\${GPU_PCI}")" == "vfio-pci" ]] && \
  [[ "\$(driver_in_use "\${GPU_AUDIO_PCI}")" == "vfio-pci" ]]
}

unload_modules_for_driver() {
  case "\$1" in
    nvidia)
      printf '%s\n' nvidia_drm nvidia_modeset nvidia_uvm nvidia
      ;;
    amdgpu|radeon|nouveau|xe|i915)
      printf '%s\n' "\$1"
      ;;
  esac
}

reload_modules_for_driver() {
  case "\$1" in
    nvidia)
      printf '%s\n' nvidia nvidia_modeset nvidia_uvm nvidia_drm
      ;;
    amdgpu|radeon|nouveau|xe|i915)
      printf '%s\n' "\$1"
      ;;
  esac
}

save_release_state() {
  local driver
  driver="\$(driver_in_use "\${GPU_PCI}")"
  mkdir -p "\${STATE_DIR}"
  printf '%s\n' "\${driver}" > "\$(state_file_for driver)"
  reload_modules_for_driver "\${driver}" > "\$(state_file_for modules)" || true
  printf '%s\n' "\$(get_active_display_manager)" > "\$(state_file_for display-manager)"
}

unload_gpu_drivers() {
  local driver module
  local -a modules=()
  driver="\$(driver_in_use "\${GPU_PCI}")"
  mapfile -t modules < <(unload_modules_for_driver "\${driver}")
  [[ "\${#modules[@]}" -gt 0 ]] || { log "No GPU modules to unload for driver '\${driver}'"; return 0; }
  log "Unloading GPU driver stack for \${GPU_PCI}: \${modules[*]}"
  # Attempt bulk unload first, then module-by-module with verification
  modprobe -r "\${modules[@]}" 2>/dev/null || true
  local failed=0
  for module in "\${modules[@]}"; do
    if lsmod | grep -q "^\${module}"; then
      modprobe -r "\${module}" 2>/dev/null || true
      if ! wait_for_module_gone "\${module}"; then
        log "WARNING: \${module} still loaded after unload attempt — continuing anyway"
        failed=1
      fi
    fi
  done
  return \${failed}
}

wait_for_vfio_bind() {
  local deadline=\$((SECONDS + WAIT_SECONDS))
  while (( SECONDS < deadline )); do
    if [[ "\$(driver_in_use "\${GPU_PCI}")" == "vfio-pci" ]] && \
       [[ "\$(driver_in_use "\${GPU_AUDIO_PCI}")" == "vfio-pci" ]]; then
      return 0
    fi
    sleep 1
  done
  return 1
}

# ── main sequence ──────────────────────────────────────────────────────────

log "Starting single-GPU prepare hook for \${GPU_PCI}"

if already_detached_to_vfio; then
  log "GPU is already bound to vfio-pci — nothing to do"
  exit 0
fi

# Step 1: Gracefully signal compositors to drop DRM master
udevadm_signal_drm_remove

# Step 2: Stop display manager and user session units
stop_system_units
release_logind_seat
stop_user_units
kill_user_processes
sleep 1

# Step 3: Kill any remaining GPU holders (all users, any process)
nuke_all_gpu_users

# Step 4: Save state for the release hook BEFORE we unbind anything
mkdir -p "\${STATE_DIR}"
save_release_state

# Step 5: Unload the GPU driver stack.
# If unload fails we still attempt VFIO bind — some processes releasing
# their fd after a SIGKILL can un-stick the module.
unload_gpu_drivers
UNLOAD_OK=\$?

# Step 6: Unbind VT framebuffers — NOW, only after driver (mostly) gone.
# If we do this earlier and then fail, we have no way back.
for vt in /sys/class/vtconsole/vtcon*; do
  [[ -w "\${vt}/bind" ]] || continue
  echo 0 > "\${vt}/bind" 2>/dev/null || true
done

if [[ -e /sys/bus/platform/drivers/efi-framebuffer/unbind ]]; then
  echo efi-framebuffer.0 > /sys/bus/platform/drivers/efi-framebuffer/unbind 2>/dev/null || true
fi

# Step 7: Load VFIO and detach GPU from host
modprobe vfio 2>/dev/null || true
modprobe vfio_pci 2>/dev/null || true
modprobe vfio_iommu_type1 2>/dev/null || true

virsh nodedev-detach "\${GPU_AUDIO_NODE}" 2>/dev/null || true
virsh nodedev-detach "\${GPU_VIDEO_NODE}" 2>/dev/null || true

command -v udevadm >/dev/null 2>&1 && udevadm settle 2>/dev/null || true

# Step 8: Verify VFIO bind
if ! wait_for_vfio_bind; then
  log "ERROR: GPU functions did not bind to vfio-pci within \${WAIT_SECONDS}s"
  log "Triggering emergency restore to bring desktop back..."
  emergency_restore
  exit 1
fi

log "Single-GPU prepare hook complete — GPU is now bound to vfio-pci"
EOF
)

  release=$(cat <<EOF
#!/usr/bin/env bash
# qemu-single-gpu-release — runs as root via libvirt QEMU hook on VM stop.
# This script MUST succeed even if parts of it fail — we always restore
# the display so the user is not left with a black screen.
# Do NOT use set -e here.

GPU_VIDEO_NODE="${video_node}"
GPU_AUDIO_NODE="${audio_node}"
STATE_DIR="/run/passthrough"

log() {
  logger -t qemu-single-gpu-release -- "\$*"
  echo "[qemu-single-gpu-release] \$*" >&2
}

state_file_for() {
  local suffix="\$1"
  printf '%s/%s.%s\n' "\${STATE_DIR}" "\${GPU_VIDEO_NODE}" "\${suffix}"
}

reload_modules_for_driver() {
  case "\$1" in
    nvidia)
      printf '%s\n' nvidia nvidia_modeset nvidia_uvm nvidia_drm
      ;;
    amdgpu|radeon|nouveau|xe|i915)
      printf '%s\n' "\$1"
      ;;
  esac
}

reload_gpu_drivers() {
  local module
  local -a modules=()

  if [[ -f "\$(state_file_for modules)" ]]; then
    mapfile -t modules < "\$(state_file_for modules)"
  fi

  if [[ "\${#modules[@]}" -eq 0 ]] && [[ -f "\$(state_file_for driver)" ]]; then
    mapfile -t modules < <(reload_modules_for_driver "\$(cat "\$(state_file_for driver)")")
  fi

  if [[ "\${#modules[@]}" -eq 0 ]]; then
    # Fallback: try everything
    modules=(nvidia nvidia_modeset nvidia_uvm nvidia_drm amdgpu radeon nouveau xe i915)
  fi

  log "Reloading host GPU driver stack: \${modules[*]}"
  for module in "\${modules[@]}"; do
    modprobe "\${module}" 2>/dev/null || true
  done
}

log "Starting single-GPU release hook"

# Step 1: Reattach GPU devices from vfio back to host
virsh nodedev-reattach "\${GPU_AUDIO_NODE}" 2>/dev/null || true
virsh nodedev-reattach "\${GPU_VIDEO_NODE}" 2>/dev/null || true

# Step 2: Unload VFIO modules
modprobe -r vfio_pci vfio_iommu_type1 vfio 2>/dev/null || true

# Step 3: Reload host GPU drivers
reload_gpu_drivers

# Step 4: Give driver a moment to settle and create device nodes
sleep 2

# Step 5: Re-bind VT consoles
for vt in /sys/class/vtconsole/vtcon*; do
  [[ -w "\${vt}/bind" ]] || continue
  echo 1 > "\${vt}/bind" 2>/dev/null || true
done

# Step 6: Re-bind EFI framebuffer
if [[ -e /sys/bus/platform/drivers/efi-framebuffer/bind ]]; then
  echo efi-framebuffer.0 > /sys/bus/platform/drivers/efi-framebuffer/bind 2>/dev/null || true
fi

# Step 7: Restart NVIDIA services
log "Restarting optional NVIDIA services..."
systemctl start nvidia-persistenced.service 2>/dev/null || true
systemctl start nvidia-powerd.service 2>/dev/null || true

# Step 8: Restart display manager
log "Restarting display manager..."
dm_unit="\$(cat "\$(state_file_for display-manager)" 2>/dev/null || echo "display-manager.service")"
# Allow up to 3 restart attempts in case the DM exits immediately on first try
local_attempt=0
while (( local_attempt < 3 )); do
  systemctl restart "\${dm_unit}" 2>/dev/null && break || true
  sleep 1
  (( local_attempt++ ))
done
# Final fallback: try any known DM
systemctl is-active "\${dm_unit}" >/dev/null 2>&1 || {
  log "Primary DM \${dm_unit} did not come up — trying fallback display managers..."
  for fallback in sddm gdm lightdm display-manager; do
    systemctl start "\${fallback}.service" 2>/dev/null && break || true
  done
}

log "Single-GPU release hook complete — display manager restarted"
EOF
)

  dispatcher=$(cat <<EOF
#!/usr/bin/env bash
# qemu hook dispatcher — routes libvirt QEMU hook calls to the correct scripts.
# set -euo pipefail is intentionally ABSENT — never kill the dispatcher with a
# subcommand failure; the sub-scripts handle their own error paths.

VM_NAME="${vm_name}"
HOOK_DIR="/etc/libvirt/hooks"
STATE_FILE="/etc/passthrough/passthrough.conf"

guest="\${1:-}"
operation="\${2:-}"
suboperation="\${3:-}"

if [[ "\${guest}" != "\${VM_NAME}" ]]; then
  exit 0
fi

if [[ -f "\${STATE_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "\${STATE_FILE}"
fi

if [[ "\${INSTALL_STAGE:-host-configured}" != "gpu-passthrough" ]]; then
  exit 0
fi

case "\${operation}/\${suboperation}" in
  prepare/begin)
    exec "\${HOOK_DIR}/qemu.d/\${VM_NAME}/prepare/begin/prepare.sh"
    ;;
  release/end|stopped/end)
    exec "\${HOOK_DIR}/qemu.d/\${VM_NAME}/release/end/release.sh"
    ;;
esac
EOF
)

  write_file "/etc/libvirt/hooks/qemu" "${dispatcher}"
  run chmod +x /etc/libvirt/hooks/qemu
  write_file "/etc/libvirt/hooks/qemu.d/${vm_name}/prepare/begin/prepare.sh" "${prepare}"
  write_file "/etc/libvirt/hooks/qemu.d/${vm_name}/release/end/release.sh" "${release}"
  run chmod +x "/etc/libvirt/hooks/qemu.d/${vm_name}/prepare/begin/prepare.sh"
  run chmod +x "/etc/libvirt/hooks/qemu.d/${vm_name}/release/end/release.sh"
}

clear_single_gpu_hooks() {
  local vm_name="$1"
  local hook_dir="/etc/libvirt/hooks/qemu.d/${vm_name}"
  local noop_hook

  if [[ -e /etc/libvirt/hooks/qemu ]]; then
    backup_file /etc/libvirt/hooks/qemu
  fi
  if [[ -d "${hook_dir}" ]]; then
    ensure_dir "${BACKUP_DIR}"
    run cp -a "${hook_dir}" "${BACKUP_DIR}/$(basename "${hook_dir}").${TIMESTAMP}.bak"
    run rm -rf "${hook_dir}"
  fi

  noop_hook=$'#!/usr/bin/env bash\nexit 0\n'
  write_file "/etc/libvirt/hooks/qemu" "${noop_hook}"
  run chmod +x /etc/libvirt/hooks/qemu
}
