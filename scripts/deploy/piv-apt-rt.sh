#!/usr/bin/env bash
# Install Ubuntu's Pi-specific realtime kernel on piv, through the safe tryboot path.
#
# This is the package the 13 Sep attempt should have used. `ubuntu-realtime` pulls the
# GENERIC arm64 RT kernel, which ships no BCM2712 device tree (flash-kernel dies with
# "Couldn't find DTB bcm2712-rpi-5-b.dtb") and whose postinst runs grub-mkconfig, which
# cannot work on a Pi. `linux-raspi-realtime` is a flavour of the SAME source package as
# the running kernel, is in main (no Ubuntu Pro needed), and coexists with the stock
# kernel (apt --dry-run reports "0 to remove").
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
load_device piv
require_ssh

"$RTPI_ROOT/scripts/safety/preflight.sh" piv

log "checking the package resolves as expected"
dev_ssh "apt-get install --dry-run $RT_APT_PKG 2>&1 | tail -20"
dev_ssh "apt-get install --dry-run $RT_APT_PKG 2>&1 | grep -qE '^0 upgraded, [0-9]+ newly installed, 0 to remove'" \
  || die "dry-run does not show '0 to remove' — refusing, as this could displace the stock kernel"
ok "coexists with the stock kernel (0 to remove)"

confirm "Install $RT_APT_PKG on $SSH_HOST? (stages into $CANDIDATE_SLOT/, does not reboot)"

# Holds would block the install; drop them just for this, then restore.
held=$(dev_ssh "apt-mark showhold | tr '\n' ' '" || true)
if [[ -n ${held// /} ]]; then
  log "temporarily releasing holds: $held"
  dev_ssh "sudo apt-mark unhold $held >/dev/null"
fi

log "installing $RT_APT_PKG"
dev_ssh "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y $RT_APT_PKG"

if [[ -n ${held// /} ]]; then
  log "restoring holds"
  dev_ssh "sudo apt-mark hold $held >/dev/null"
fi

log "candidate state after install:"
dev_ssh "sudo piboot-try --status 2>&1 || true"
dev_ssh "sudo cat $BOOT_MOUNT/$CANDIDATE_SLOT/state 2>/dev/null | sed 's/^/  new\/state = /'"

echo
ok "staged. Next:"
echo "  scripts/safety/arm-try-piv.sh --expect $RT_APT_KERNEL --realtime --reboot"
echo "  scripts/safety/watch-reboot.sh piv --expect $RT_APT_KERNEL"
