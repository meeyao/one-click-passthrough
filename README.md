# One-Click Passthrough

A robust, modular, cross-distro Linux script that automates the setup of PCI passthrough / VFIO for Windows VMs.

## Features

- **Cross-Distro Support**: Works on Arch, Debian/Ubuntu, and Fedora.
- **Hardware Topology Detection**: Automatically handles single-GPU, dual-GPU (iGPU + dGPU), and multi-dGPU setups.
- **Libvirt / KVM Setup**: Automates standard VM tuning, CPU topology, and Hyper-V enlightenments.
- **Bootloader & Initramfs**: Native configuration for GRUB, systemd-boot, and Limine. Rebuilds mkinitcpio, dracut, or update-initramfs transparently.
- **Anticheat / Concealment**: Automatically sets standard VM concealment flags (CPU virtualization bits, `kvm.hidden`, `ssbd` mitigations) to improve transparency for anti-cheat and anti-virtualization.
- **Automated Windows ISO Patching**: Directly downloads the latest Windows 11 ISO (via Dockur mirror bypassing Microsoft walls), handles the `virtio` drivers, and injects `unattend.xml` with local user creation, test-signing flags, and Debloat (Winhance) hooks.

## Dependencies

The script checks for required dependencies. Basic requirements:
- KVM / Libvirt / QEMU
- VFIO utilities
- bash, curl, jq, 7z/bsdtar, virt-install

## Usage

1. Open a terminal and run the main setup script configuration:
   ```bash
   sudo ./passthrough-setup.sh
   ```
2. Follow the interactive prompts to select your GPU, configure Libvirt, and optionally download/patch a Windows ISO.
3. Manage your VM lifecycle easily via the newly installed `windows-vm` command (or `./windows`):
   ```bash
   windows-vm start      # Smart start (creates or launches the VM)
   windows-vm stop       # ACPI shutdown
   windows-vm attach-gpu # Finalize passthrough
   windows-vm status     # Check VM stage
   ```

### Stages of VM Setup

The script uses a staged approach to safely build a Windows VM:

1. **Spice Install**: The VM boots with emulated graphics (QXL/Spice). You complete the Windows setup.
2. **GPU Passthrough**: Running `windows-vm attach-gpu` (or `windows-vm start`) strips the emulated graphics, attaches the physical GPU/USB controllers via XML rewrites, and enables deep KVM concealment.

## Contributing & Development

This project is structured modularly:
- `passthrough-setup.sh`: Thin orchestrator.
- `lib/`: Core logic (detect, bootloader, vm config, os parsing).
- `windows`: The `windows-vm` CLI manager.

## License

This project is licensed under the GPLv3 License. See the [LICENSE](LICENSE) file for more information.
