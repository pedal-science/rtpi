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

  *) die "unknown device $DEVICE" ;;
esac

echo
if (( fails )); then
  die "$fails preflight check(s) failed — NOT safe to arm a candidate"
fi
ok "all preflight checks passed"
