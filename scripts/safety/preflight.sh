#!/usr/bin/env bash
# Prove the rollback path is intact BEFORE arming anything risky.
# Read-only. Exits non-zero if it is not safe to proceed.
# Usage: preflight.sh piv
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
DEVICE="${1:?usage: preflight.sh piv}"
load_device "$DEVICE"
require_ssh
ok "ssh to $SSH_HOST works"

fails=0
check() { # check <description> <remote test command>
  local desc="$1"; shift
  if dev_ssh "$*" >/dev/null 2>&1; then ok "$desc"; else warn "FAIL: $desc"; fails=$((fails+1)); fi
}

case "$DEVICE" in
  piv)
    guard_stock_kernel_installed
    guard_boot_space "$BOOT_MOUNT" "$BOOT_MIN_FREE_MB"

    check "known-good slot exists with a kernel" "sudo test -f $BOOT_MOUNT/current/vmlinuz"
    check "known-good slot is marked good"       "sudo grep -qx good $BOOT_MOUNT/current/state"
    check "board dtb present in known-good slot" "sudo test -f $BOOT_MOUNT/current/$BOARD_DTB"
    check "tryboot A/B is enabled"               "sudo grep -q tryboot_a_b=1 $BOOT_MOUNT/autoboot.txt"
    check "config.txt has a [tryboot] section"   "sudo grep -q '^\[tryboot\]' $BOOT_MOUNT/config.txt"
    check "config.txt sets os_prefix=current/"   "sudo grep -q '^os_prefix=current/' $BOOT_MOUNT/config.txt"
    check "piboot-try is installed"              "test -x /usr/sbin/piboot-try"
    check "piboot-try-reboot.service enabled"    "systemctl is-enabled piboot-try-reboot.service"
    check "piboot-try-validate.service enabled"  "systemctl is-enabled piboot-try-validate.service"
    check "validate hook is ours, not stock"     "sudo grep -q 'piboot-validate:' /etc/flash-kernel/piboot-validate"
    check "validate timeout drop-in installed"   "test -f /etc/systemd/system/piboot-try-validate.service.d/10-rtpi-timeout.conf"
    check "watchdog drop-in installed"           "test -f /etc/systemd/system.conf.d/10-rtpi-watchdog.conf"
    check "watchdog is actually armed"           "systemctl show | grep -q 'RuntimeWatchdogUSec=1[0-9]s'"
    check "kernel/initramfs packages are held"   "apt-mark showhold | grep -q dracut"

    # A local backup must exist, or there is nothing to restore from off-device.
    if [[ -e "$RTPI_ROOT/devices/piv/backups/latest" ]]; then
      ok "off-device backup present ($(readlink "$RTPI_ROOT/devices/piv/backups/latest"))"
    else
      warn "FAIL: no off-device backup — run 'make backup-piv' first"; fails=$((fails+1))
    fi
    ;;

  pro)
    guard_stock_kernel_installed
    guard_boot_space "$BOOT_MOUNT" "$BOOT_MIN_FREE_MB"

    # The one assumption the whole design rests on: GRUB must be able to write grubenv, or its
    # one-shot boot silently does nothing and a trial becomes permanent. /boot is a plain ext4
    # partition here; this proves it rather than trusting it.
    abstraction=$(dev_ssh "sudo -n grub-probe --target=abstraction /boot 2>/dev/null | tr '\n' ' '" || true)
    if [[ -z ${abstraction// /} ]]; then ok "/boot is a plain filesystem (GRUB can write grubenv)"
    else warn "FAIL: /boot sits on '$abstraction'; GRUB cannot write grubenv there"; fails=$((fails+1)); fi
    check "grubenv is readable"                  "sudo -n grub-editenv $GRUBENV list"
    check "grubenv is writable"                  "sudo -n grub-editenv $GRUBENV set rtpi_preflight=1 && sudo -n grub-editenv $GRUBENV unset rtpi_preflight"

    check "pro-boot is installed"                "test -x /usr/local/sbin/pro-boot"
    check "the validate hook is installed"       "test -x /usr/local/libexec/pro-boot-validate"
    check "42_pedal is installed"                "test -x /etc/grub.d/42_pedal"
    check "GRUB_DEFAULT=saved is in force"       "grep -q '^GRUB_DEFAULT=saved' /etc/default/grub.d/90-rtpi.cfg"
    check "device.env is on the host"            "test -r /etc/rtpi/device.env"
    check "pro-boot-settle.service enabled"      "systemctl is-enabled pro-boot-settle.service"
    check "pro-boot-validate.service enabled"    "systemctl is-enabled pro-boot-validate.service"
    check "pro-boot-deadline.service enabled"    "systemctl is-enabled pro-boot-deadline.service"
    check "the emergency reboot drop-in is in"   "test -f /etc/systemd/system/emergency.service.d/10-pro-reboot.conf"
    check "the tuned entry exists"               "sudo -n grep -q \"'$ENTRY_TUNED'\" /boot/grub/grub.cfg"
    check "Ubuntu's own entry exists (the fallback)" "sudo -n grep -q 'gnulinux-simple-' /boot/grub/grub.cfg"
    check "kernel and GRUB packages are held"    "apt-mark showhold | grep -q grub"
    # turbostat is version-matched to the kernel, so a kernel change silently leaves the wrapper
    # printing "turbostat not found for kernel …". It is the instrument that found 726 SMIs in one
    # window during a soak (pedal.project bench-results/2026-11-01-soak-pro-rt), which is the only
    # way an SMI stall is visible at all — so losing it is losing the measurement, quietly.
    check "turbostat works on the running kernel" \
      "sudo -n turbostat --quiet --show SMI --num_iterations 1 --interval 1 >/dev/null 2>&1"

    # The saved default must name an entry that is actually in the menu. A default that does not
    # exist means GRUB falls through to its own first entry, which is not necessarily the one
    # anybody chose.
    saved=$(dev_ssh "sudo -n grub-editenv $GRUBENV list | sed -n 's/^saved_entry=//p'" || true)
    if [[ -z $saved ]]; then
      warn "FAIL: grubenv has no saved_entry, but GRUB_DEFAULT=saved"; fails=$((fails+1))
    elif dev_ssh "sudo -n grep -q \"'$saved'\" /boot/grub/grub.cfg"; then
      ok "the saved default ($saved) is an entry that exists"
    else
      warn "FAIL: the saved default '$saved' is not in grub.cfg"; fails=$((fails+1))
    fi

    # A trial left marked trying would make `pro-boot try` refuse, and means the last one was
    # never settled.
    trial_state=$(dev_ssh "sed -n 's/^state=//p' /var/lib/rtpi/pro-boot/trial 2>/dev/null" || true)
    case "$trial_state" in
      "")      ok "no trial armed" ;;
      bad)     ok "the last trial is marked bad (settled)" ;;
      trying)  warn "FAIL: a trial is armed and untested. Reboot to run it, or run 'pro-boot settle'"
               fails=$((fails+1)) ;;
      *)       warn "FAIL: unexpected trial state '$trial_state'"; fails=$((fails+1)) ;;
    esac

    if [[ -e "$RTPI_ROOT/devices/pro/backups/latest" ]]; then
      ok "off-device backup present ($(readlink "$RTPI_ROOT/devices/pro/backups/latest"))"
    else
      warn "FAIL: no off-device backup — run 'make backup-pro' first"; fails=$((fails+1))
    fi
    ;;

  *) die "unknown device $DEVICE" ;;
esac

echo
if (( fails )); then
  die "$fails preflight check(s) failed — NOT safe to arm a candidate"
fi
ok "all preflight checks passed"
