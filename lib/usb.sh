#!/usr/bin/env bash
# lib/usb.sh — USB controller and device listing, selection, and classification.
# Sourced by passthrough-setup.sh; requires lib/common.sh, lib/detect.sh.

usb_ids_file() {
  local candidate
  for candidate in /usr/share/hwdata/usb.ids /usr/share/misc/usb.ids; do
    [[ -f "${candidate}" ]] && {
      printf '%s\n' "${candidate}"
      return 0
    }
  done
  return 1
}

usb_vendor_name() {
  local vendor_id="${1,,}"
  local file
  file="$(usb_ids_file || true)"
  [[ -n "${file}" ]] || return 1
  awk -v vendor="${vendor_id}" '
    tolower($1) == vendor && $0 !~ /^\t/ {
      $1=""
      sub(/^[[:space:]]+/, "", $0)
      print
      exit
    }' "${file}"
}

usb_product_name() {
  local vendor_id="${1,,}"
  local product_id="${2,,}"
  local file
  file="$(usb_ids_file || true)"
  [[ -n "${file}" ]] || return 1
  awk -v vendor="${vendor_id}" -v product="${product_id}" '
    BEGIN { in_vendor = 0 }
    $0 !~ /^\t/ {
      in_vendor = (tolower($1) == vendor)
      next
    }
    in_vendor && $0 ~ /^\t[0-9a-fA-F]{4}[[:space:]]+/ {
      line=$0
      sub(/^\t/, "", line)
      split(line, parts, /[[:space:]]+/)
      if (tolower(parts[1]) == product) {
        sub(/^[[:space:]]*[0-9a-fA-F]{4}[[:space:]]+/, "", line)
        print line
        exit
      }
    }' "${file}"
}

usb_device_blacklisted() {
  local vendor="${1,,}"
  local product="${2,,}"
  case "${vendor}:${product}" in
    1d6b:0001|1d6b:0002|1d6b:0003|1d6b:0004)
      return 0
      ;;
  esac
  return 1
}

list_usb_controllers() {
  lspci -Dnn | awk '
    /USB controller|USB 3|xHCI|EHCI|OHCI/ {
      slot=$1
      desc=$0
      sub(/^[^ ]+ /, "", desc)
      print slot "|" desc
    }'
}

isolated_usb_controllers() {
  local entries="$1"
  local slot desc
  while IFS='|' read -r slot desc; do
    [[ -n "${slot}" ]] || continue
    if pci_group_isolated "${slot}"; then
      printf '%s|%s\n' "${slot}" "${desc}"
    fi
  done <<< "${entries}"
  return 0
}

recommended_usb_controller() {
  local entries="$1"
  local line
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    case "${line,,}" in
      *asmedia*|*asm1143*|*renesas*)
        printf '%s\n' "${line}"
        return 0
        ;;
    esac
  done <<< "${entries}"
  printf '%s\n' "${entries}" | head -n1
}

list_usb_devices() {
  local dev vendor product manufacturer product_name busnum devnum line vendor_name product_label
  for dev in /sys/bus/usb/devices/*; do
    [[ -f "${dev}/idVendor" && -f "${dev}/idProduct" ]] || continue
    [[ -f "${dev}/busnum" && -f "${dev}/devnum" ]] || continue
    vendor="$(<"${dev}/idVendor")"
    product="$(<"${dev}/idProduct")"
    usb_device_blacklisted "${vendor}" "${product}" && continue
    manufacturer="$(<"${dev}/manufacturer" 2>/dev/null || true)"
    product_name="$(<"${dev}/product" 2>/dev/null || true)"
    busnum="$(<"${dev}/busnum")"
    devnum="$(<"${dev}/devnum")"
    vendor_name="$(usb_vendor_name "${vendor}" || true)"
    product_label="$(usb_product_name "${vendor}" "${product}" || true)"
    [[ -z "${manufacturer}" ]] && manufacturer="${vendor_name}"
    [[ -z "${product_name}" ]] && product_name="${product_label}"
    line="${vendor}:${product}|bus $(printf '%03d' "${busnum}") device $(printf '%03d' "${devnum}") - ${manufacturer:-Unknown Vendor} ${product_name:-Unknown Product}"
    printf '%s\n' "${line}" | sed 's/[[:space:]]\+/ /g; s/ - $//'
  done | awk '!seen[$1]++'
}

render_plain_menu() {
  local entries="$1"
  local index=1 line
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    printf '  %b%2d)%b %s\n' "${C_BLUE}" "${index}" "${C_RESET}" "${line}" >&2
    index=$((index + 1))
  done <<< "${entries}"
}

classify_usb_entry() {
  local entry="${1,,}"
  case "${entry}" in
    *keyboard* ) printf 'keyboard\n' ;;
    *mouse* ) printf 'mouse\n' ;;
    *controller*|*gamepad*|*xbox*|*dualshock*|*dualsense* ) printf 'controller\n' ;;
    *bluetooth* ) printf 'bluetooth\n' ;;
    *receiver*|*wireless* ) printf 'receiver\n' ;;
    *) printf 'other\n' ;;
  esac
}

prompt_usb_mode() {
  local default="$1"
  local answer
  local default_index="1"
  case "${default}" in
    controller) default_index="2" ;;
    devices|device) default_index="3" ;;
    evdev) default_index="4" ;;
  esac

  answer="$(prompt_menu_choice "USB passthrough mode" "${default_index}" \
    "No USB passthrough [none]" \
    "Pass through one whole USB controller [controller]" \
    "Pass through selected USB devices [devices]" \
    "Pass through input devices via evdev [evdev]")"
  case "${answer}" in
    *"[none]") printf 'none\n' ;;
    *"[controller]") printf 'controller\n' ;;
    *"[devices]") printf 'devices\n' ;;
    *"[evdev]") printf 'evdev\n' ;;
    *) fail "Unexpected USB mode selection." ;;
  esac
}

select_usb_controller() {
  local entries="$1"
  local recommended="$2"
  local recommended_index=1 choice selected index=1 line
  render_plain_menu "${entries}"
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    [[ "${line}" == "${recommended}" ]] && recommended_index="${index}"
    index=$((index + 1))
  done <<< "${entries}"
  printf 'Recommended for beginners: %s\n' "${recommended}" >&2
  while :; do
    choice="$(prompt "Select the USB controller number to pass through" "${recommended_index}")"
    [[ "${choice}" =~ ^[1-9][0-9]*$ ]] || {
      warn "Invalid controller selection."
      continue
    }
    selected="$(printf '%s\n' "${entries}" | sed -n "${choice}p")"
    [[ -n "${selected}" ]] && {
      printf '%s\n' "${selected}"
      return 0
    }
    warn "Invalid controller selection."
  done
}

select_usb_devices() {
  local entries="$1"
  local selection action selected_lines="" item entry class
  render_plain_menu "${entries}"
  ui_note "Pick one or more USB devices. Commands: number, comma list, list, clear, done." >&2
  while :; do
    if [[ -n "${selected_lines}" ]]; then
      printf '%bCurrently selected:%b\n' "${C_BOLD}" "${C_RESET}" >&2
      printf '%s' "${selected_lines}" | awk 'NF && !seen[$0]++ { printf "  - %s\n", $0 }' >&2
    else
      printf '%bCurrently selected:%b none\n' "${C_BOLD}" "${C_RESET}" >&2
    fi
    action="$(prompt "USB devices to pass through" "done")"
    action="${action// /}"
    case "${action,,}" in
      "")
        continue
        ;;
      done)
        printf '%s' "${selected_lines}" | awk 'NF && !seen[$0]++'
        return 0
        ;;
      list)
        render_plain_menu "${entries}"
        continue
        ;;
      clear)
        selected_lines=""
        continue
        ;;
    esac
    IFS=',' read -r -a items <<< "${action}"
    for item in "${items[@]}"; do
      [[ "${item}" =~ ^[1-9][0-9]*$ ]] || {
        warn "Skipping invalid USB selection: ${item}"
        continue
      }
      entry="$(printf '%s\n' "${entries}" | sed -n "${item}p")"
      [[ -n "${entry}" ]] || {
        warn "Skipping missing USB selection: ${item}"
        continue
      }
      class="$(classify_usb_entry "${entry}")"
      case "${class}" in
        keyboard|mouse|receiver)
          warn "Selected ${class}: ${entry}"
          warn "If this is your only host input device, you may lock yourself out during VM use."
          ;;
      esac
      selected_lines="${selected_lines}${entry}"$'\n'
    done
    selected_lines="$(printf '%s' "${selected_lines}" | awk 'NF && !seen[$0]++')"
    [[ -n "${selected_lines}" ]] && selected_lines="${selected_lines}"$'\n'
  done
}
