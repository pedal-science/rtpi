#!/usr/bin/env bash
# Stop unattended-upgrades from re-running flash-kernel behind our back.
#
# WHY THIS EXISTS — observed live on 2026-09-15 06:37: unattended-upgrades upgraded
# *dracut* (not a kernel). Regenerating the initramfs fired
# /etc/initramfs/post-update.d/flash-kernel, which ran the pi-try method, which does
# `rm -rf old new` when old/ exists. That destroyed the rollback slot and staged an
# unrequested candidate. If that happens while an RT candidate is staged, the candidate
# is silently replaced mid-test.
#
# So: hold the kernel AND the initramfs generators, not just the kernel.
#
# Usage: hold-packages.sh <device> <hold|unhold>
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
DEVICE="${1:?usage: hold-packages.sh <device> <hold|unhold>}"
ACTION="${2:?usage: hold-packages.sh <device> <hold|unhold>}"
load_device "$DEVICE"
require_ssh

case "$DEVICE" in
  pro)
    # What must not change under a staged trial. The initramfs generators are here for the same
    # reason as on piv (regenerating one is what re-ran flash-kernel and destroyed a rollback slot),
    # and GRUB's packages are here because their postinst runs update-grub — which would rewrite
    # the menu, and with it the trial entry, mid-test.
    PKGS=(dracut dracut-core dracut-install dracut-network initramfs-tools initramfs-tools-core
          grub-common grub2-common grub-efi-amd64 grub-efi-amd64-bin grub-efi-amd64-signed
          shim-signed
          "$STOCK_KERNEL_PKG" "linux-modules-$STOCK_KERNEL"
          "$RT_APT_PKG" "$RT_APT_MODULES")
    ;;
  *)
    PKGS=(dracut dracut-core dracut-install dracut-network initramfs-tools initramfs-tools-core
          linux-image-raspi linux-raspi piboot-try flash-kernel)
    ;;
esac

case "$ACTION" in
  hold)
    log "holding ${#PKGS[@]} packages on $SSH_HOST"
    for p in "${PKGS[@]}"; do
      if dev_ssh "dpkg -l '$p' 2>/dev/null | grep -q '^ii'"; then
        dev_ssh "sudo apt-mark hold '$p'" || warn "could not hold $p"
      fi
    done
    ok "held. Undo with: make unhold-$DEVICE"
    ;;
  unhold)
    log "releasing holds on $SSH_HOST"
    for p in "${PKGS[@]}"; do dev_ssh "sudo apt-mark unhold '$p' 2>/dev/null || true"; done
    ok "released"
    ;;
  *) die "action must be hold or unhold" ;;
esac
echo "current holds:"; dev_ssh "apt-mark showhold | sed 's/^/  /'"
