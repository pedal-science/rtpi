#!/usr/bin/env bash
# Put pro's boot tooling on the machine, and make GRUB safe to add kernels to.
#
# Run this BEFORE installing the realtime kernel (scripts/deploy/pro-rt.sh). The reason is in
# devices/pro/etc/default/grub.d/90-rtpi.cfg: with Ubuntu's stock `GRUB_DEFAULT=0`, installing a
# newer kernel changes what the machine boots, because 10_linux writes its "Ubuntu" entry for the
# newest kernel it can find. Running this first pins that entry to the stock kernel and makes the
# default a named entry in grubenv instead of a position in the menu.
#
# What it installs:
#   /etc/rtpi/device.env                        the device facts, read by pro-boot and 42_pedal
#   /usr/local/sbin/pro-boot                    the boot tool
#   /usr/local/libexec/pro-boot-validate        what decides whether a trial is promoted
#   /etc/grub.d/42_pedal                        the pedal's menu entries
#   /etc/default/grub.d/90-rtpi.cfg             GRUB_DEFAULT=saved, GRUB_TOP_LEVEL, and two others
#   pro-boot-{settle,validate,deadline}.service enabled
#   emergency/rescue drop-ins                   reboot instead of waiting, on a trial boot only
#   /var/lib/rtpi/pro-boot/promoted             kernel=<stock>, args= — nothing claimed yet
#
# It changes nothing about what boots: the default is set to the entry Ubuntu was already booting.
# Everything here is reversible with --revert.
#
# Usage: harden-pro.sh [--watchdog] [--revert]
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
load_device pro
require_ssh

WATCHDOG=0
REVERT=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --watchdog) WATCHDOG=1; shift ;;
    --revert)   REVERT=1; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done

DEV_DIR="$RTPI_ROOT/devices/pro"

if (( REVERT )); then
  confirm "Remove pro's boot tooling and put GRUB back as Ubuntu had it?"
  log "setting the default back to Ubuntu's own entry before removing the tooling"
  dev_ssh "sudo -n /usr/local/sbin/pro-boot default stock" || warn "could not set the default; check by hand"
  dev_ssh "sudo -n bash -s" <<'REMOTE'
set -u
for u in pro-boot-validate pro-boot-settle pro-boot-deadline; do
  systemctl disable --now "$u.service" 2>/dev/null || true
done
rm -f /etc/grub.d/42_pedal /etc/default/grub.d/90-rtpi.cfg \
      /etc/systemd/system/pro-boot-*.service \
      /etc/systemd/system/emergency.service.d/10-pro-reboot.conf \
      /etc/systemd/system/rescue.service.d/10-pro-reboot.conf \
      /etc/systemd/system.conf.d/10-rtpi-watchdog.conf \
      /etc/modules-load.d/10-rtpi-watchdog.conf \
      /usr/local/sbin/pro-boot /usr/local/libexec/pro-boot-validate
rmdir /etc/systemd/system/emergency.service.d /etc/systemd/system/rescue.service.d 2>/dev/null || true
systemctl daemon-reload
# Ubuntu's GRUB_DEFAULT=0 is back in force now that the drop-in is gone.
update-grub
echo "reverted. /etc/rtpi and /var/lib/rtpi are left (they hold this machine's record)."
REMOTE
  ok "reverted"
  exit 0
fi

# ---------------------------------------------------------------- preconditions
"$RTPI_ROOT/scripts/safety/backup-boot.sh" pro

log "checking GRUB can write its environment"
# This is the one assumption the whole one-shot design rests on. On an LVM or RAID /boot, GRUB
# cannot write grubenv: `grub-reboot` would succeed, change nothing, and a trial would become a
# permanent boot. /boot is its own ext4 partition on pro, and this proves it rather than trusting it.
abstraction=$(dev_ssh "sudo -n grub-probe --target=abstraction /boot 2>/dev/null | tr '\n' ' '" || true)
[[ -z ${abstraction// /} ]] \
  || die "/boot sits on '$abstraction'. GRUB cannot write grubenv there, so a one-shot boot would
         never be undone. Move /boot to a plain partition before using this."
dev_ssh "sudo -n grub-editenv $GRUBENV list >/dev/null" \
  || die "cannot read $GRUBENV on $SSH_HOST"
ok "/boot is a plain filesystem and $GRUBENV is readable"

guard_stock_kernel_installed
guard_boot_space "$BOOT_MOUNT" "$BOOT_MIN_FREE_MB"

# ---------------------------------------------------------------- stage and install
log "staging devices/pro onto $SSH_HOST"
stage="/var/tmp/rtpi-pro-$(timestamp)"
# Not /tmp: it is a RAM disk on this machine (pedal.project docs/pro.md).
tar -C "$DEV_DIR" --no-xattrs -cf - etc usr | dev_ssh "mkdir -p '$stage' && tar -C '$stage' -xf -"
tar -C "$DEV_DIR" --no-xattrs -cf - device.env | dev_ssh "tar -C '$stage' -xf -"

WANT_WATCHDOG=$WATCHDOG dev_ssh "sudo -n WATCHDOG=$WATCHDOG STAGE='$stage' \
  STOCK_KERNEL='$STOCK_KERNEL' ENTRY_TUNED='$ENTRY_TUNED' bash -s" <<'REMOTE'
set -euo pipefail
say() { echo "harden-pro: $*"; }

install -D -m 0644 "$STAGE/device.env"                                   /etc/rtpi/device.env
install -D -m 0755 "$STAGE/usr/local/sbin/pro-boot"                      /usr/local/sbin/pro-boot
install -D -m 0755 "$STAGE/usr/local/libexec/pro-boot-validate"          /usr/local/libexec/pro-boot-validate
install -D -m 0755 "$STAGE/etc/grub.d/42_pedal"                          /etc/grub.d/42_pedal
install -D -m 0644 "$STAGE/etc/default/grub.d/90-rtpi.cfg"               /etc/default/grub.d/90-rtpi.cfg
for u in pro-boot-settle pro-boot-validate pro-boot-deadline; do
  install -D -m 0644 "$STAGE/etc/systemd/system/$u.service"              "/etc/systemd/system/$u.service"
done
install -D -m 0644 "$STAGE/etc/systemd/system/emergency.service.d/10-pro-reboot.conf" \
                   /etc/systemd/system/emergency.service.d/10-pro-reboot.conf
install -D -m 0644 "$STAGE/etc/systemd/system/rescue.service.d/10-pro-reboot.conf" \
                   /etc/systemd/system/rescue.service.d/10-pro-reboot.conf

if [[ ${WATCHDOG:-0} == 1 ]]; then
  install -D -m 0644 "$STAGE/etc/modules-load.d/10-rtpi-watchdog.conf"   /etc/modules-load.d/10-rtpi-watchdog.conf
  install -D -m 0644 "$STAGE/etc/systemd/system.conf.d/10-rtpi-watchdog.conf" \
                     /etc/systemd/system.conf.d/10-rtpi-watchdog.conf
  # Load it now as well as at the next boot, and say whether the chipset actually gave us one: the
  # BIOS can refuse, and an armed RuntimeWatchdogSec with no device is a setting that does nothing.
  modprobe iTCO_wdt 2>/dev/null || say "WARNING: iTCO_wdt would not load"
  if [[ -e /dev/watchdog0 ]]; then
    say "watchdog: /dev/watchdog0 present ($(cat /sys/class/watchdog/watchdog0/identity 2>/dev/null))"
    say "watchdog: it arms at the next boot (systemd reads system.conf at startup)"
  else
    say "WARNING: no /dev/watchdog0 after loading the module. The BIOS setting 'Watchdog Timer' is"
    say "         Disable on this machine; leave the drop-ins in place or revert them, but do not"
    say "         count on a watchdog until this line says it exists."
  fi
fi

# The state the menu entries are generated from. Nothing is claimed yet: the tuned entry points at
# the stock kernel with no isolation arguments, so it is a harmless twin of Ubuntu's own entry until
# a trial has been validated. Not overwritten if it already exists — that would throw away a
# promotion.
if [[ ! -e /var/lib/rtpi/pro-boot/promoted ]]; then
  install -d -m 0755 /var/lib/rtpi/pro-boot
  printf '# Written by pro-boot. Edit with pro-boot, not by hand.\nkernel=%s\nargs=\n' \
    "$STOCK_KERNEL" > /var/lib/rtpi/pro-boot/promoted
  say "promoted: kernel=$STOCK_KERNEL, no isolation arguments (nothing claimed yet)"
else
  say "promoted: left as it is ($(sed -n 's/^kernel=//p' /var/lib/rtpi/pro-boot/promoted))"
fi

systemctl daemon-reload
systemctl enable pro-boot-settle.service pro-boot-validate.service pro-boot-deadline.service >/dev/null
say "units enabled"

# Regenerate the menu with 42_pedal and 90-rtpi.cfg in place, then record the entry the machine is
# already booting as the saved default. This is the step that must not change what boots.
update-grub
stock_id=$(grep -o "gnulinux-simple-[^']*" /boot/grub/grub.cfg | head -1)
[[ -n $stock_id ]] || { say "no gnulinux-simple-* entry in grub.cfg; refusing to set a default"; exit 1; }
grub-set-default "$stock_id"
say "default boot entry: $stock_id (Ubuntu's own, the stock kernel — unchanged)"
REMOTE

dev_ssh "rm -rf '$stage'"

# ---------------------------------------------------------------- prove it
log "checking the entries exist and the one-shot works"
for id in "$ENTRY_TUNED" "$ENTRY_LOOSE"; do
  dev_ssh "sudo -n grep -q \"'$id'\" /boot/grub/grub.cfg" \
    && ok "menu entry $id" || die "menu entry $id is missing from grub.cfg"
done
# Arm and immediately disarm a one-shot. If grubenv were not writable this is where it shows, and it
# shows without having rebooted anything.
dev_ssh "sudo -n grub-reboot '$ENTRY_LOOSE' && sudo -n grub-editenv $GRUBENV list | grep -q '^next_entry=$ENTRY_LOOSE'" \
  || die "grub-reboot did not write next_entry. The one-shot does not work on this machine, so do
         NOT try a kernel here: a trial would become permanent."
dev_ssh "sudo -n grub-editenv $GRUBENV unset next_entry"
ok "grub-reboot writes and clears next_entry"
dev_ssh "sudo -n grub-editenv $GRUBENV list | sed 's/^/  /'"

# unattended-upgrades is masked by pedal.project's devices/pro, but a hold is what stops an apt run
# anybody starts by hand from replacing the kernel or GRUB under a staged trial.
"$RTPI_ROOT/scripts/safety/hold-packages.sh" pro hold

echo
ok "pro is hardened. Nothing about what it boots has changed."
echo "  next:  scripts/deploy/pro-rt.sh          install the realtime kernel (still not booted)"
echo "         scripts/safety/status.sh pro      see the entries and the default"
