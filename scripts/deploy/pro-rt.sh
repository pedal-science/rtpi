#!/usr/bin/env bash
# Install Ubuntu's amd64 realtime kernel on pro. It is NOT booted by this script.
#
# pro takes the stock signed package rather than a kernel rtpi builds, and devices/pro/device.env
# gives the three reasons (Secure Boot is on, there is nothing in rtpi's fragments that Ubuntu's
# flavour lacks, and it is in main). This is piv's route — `linux-raspi-realtime` through apt — on a
# machine where the one-shot boot is GRUB's rather than the Pi firmware's.
#
# After this, the kernel is on the disk and in Ubuntu's "Advanced options" submenu, and the machine
# still boots exactly what it booted before. Booting it is a separate, deliberate act:
#
#     ssh pro sudo pro-boot try --kernel <release>          (or: make pro-try)
#
# Usage: pro-rt.sh [--revert]
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
load_device pro
require_ssh

if [[ ${1:-} == --revert ]]; then
  confirm "Remove $PEDAL_KERNEL from $SSH_HOST?"
  running=$(dev_ssh 'uname -r')
  [[ $running != "$PEDAL_KERNEL" ]] \
    || die "$SSH_HOST is running $PEDAL_KERNEL right now. Boot the stock kernel first:
         ssh $SSH_HOST sudo pro-boot default stock && ssh $SSH_HOST sudo systemctl reboot"
  dev_ssh "sudo -n apt-mark unhold $RT_APT_PKG $RT_APT_MODULES >/dev/null 2>&1 || true"
  dev_ssh "sudo -n DEBIAN_FRONTEND=noninteractive apt-get remove -y $RT_APT_PKG $RT_APT_MODULES"
  dev_ssh "sudo -n update-grub"
  ok "removed. The stock kernel is still installed and still the fallback."
  exit 0
fi

"$RTPI_ROOT/scripts/safety/preflight.sh" pro

log "checking the package resolves as expected"
# The versioned packages by name, not the `linux-realtime` meta package: that one Recommends
# thermald, a daemon that moves frequency and power limits to hold a temperature — which is the
# jitter the pedal's performance governor exists to remove. --no-install-recommends says the same
# thing, and naming the versions keeps the ABI in device.env rather than in whatever apt resolves
# today.
dry=$(dev_ssh "apt-get install --no-install-recommends --dry-run $RT_APT_PKG $RT_APT_MODULES 2>&1" )
printf '%s\n' "$dry" | tail -20
grep -qE '^0 upgraded, [0-9]+ newly installed, 0 to remove' <<<"$dry" \
  || die "the dry run does not say '0 to remove'. Refusing: this could displace the stock kernel,
         which is the only thing pro has to fall back to."
grep -q 'thermald' <<<"$dry" \
  && die "thermald is in the install set. It must not be: it changes the CPU's frequency and power
         limits behind the engine's back. Check --no-install-recommends is taking effect."
ok "coexists with the stock kernel (0 to remove), and pulls in no thermald"

# The pedal's own GRUB configuration has to be in place first, or the kernel's postinst will run
# update-grub with Ubuntu's GRUB_DEFAULT=0 and the new kernel becomes the default with no isolation
# arguments and no trial. This is the most likely way to get the whole exercise wrong.
dev_ssh "test -r /etc/default/grub.d/90-rtpi.cfg && test -x /usr/local/sbin/pro-boot" \
  || die "pro has not been hardened. Run scripts/deploy/harden-pro.sh first: without it, installing
         this kernel would change what the machine boots."
ok "pro-boot and 90-rtpi.cfg are in place, so the default will not move"

confirm "Install $RT_APT_PKG on $SSH_HOST? (it is not booted by this)"

held=$(dev_ssh "apt-mark showhold | tr '\n' ' '" || true)
if [[ -n ${held// /} ]]; then
  log "temporarily releasing holds: $held"
  dev_ssh "sudo -n apt-mark unhold $held >/dev/null"
fi

log "installing $RT_APT_PKG, $RT_APT_MODULES and $RT_APT_TOOLS"
dev_ssh "sudo -n DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
         $RT_APT_PKG $RT_APT_MODULES $RT_APT_TOOLS"

if [[ -n ${held// /} ]]; then
  log "restoring holds"
  dev_ssh "sudo -n apt-mark hold $held >/dev/null"
fi
# And the new kernel too, so nothing replaces it under a staged trial.
dev_ssh "sudo -n apt-mark hold $RT_APT_PKG $RT_APT_MODULES >/dev/null"

log "checking what landed"
for f in "/boot/vmlinuz-$PEDAL_KERNEL" "/boot/initrd.img-$PEDAL_KERNEL" "/lib/modules/$PEDAL_KERNEL"; do
  dev_ssh "test -e '$f'" && ok "$f" || die "$f is missing: the install did not complete"
done
# A kernel whose config lacks these would make the isolation arguments silently do nothing, and
# pro-boot-validate checks isolcpus took effect for exactly that reason. Better to know now.
log "the new kernel's own configuration"
dev_ssh "grep -E '^CONFIG_(PREEMPT_RT|PREEMPT_DYNAMIC|HZ|NO_HZ_FULL|RCU_NOCB_CPU|CPU_ISOLATION|HIGH_RES_TIMERS|RT_GROUP_SCHED)=' /boot/config-$PEDAL_KERNEL | sed 's/^/  /'" || true
dev_ssh "grep -q '^CONFIG_PREEMPT_RT=y' /boot/config-$PEDAL_KERNEL" \
  && ok "CONFIG_PREEMPT_RT=y" || die "$PEDAL_KERNEL is not a PREEMPT_RT kernel"

# The default must still be Ubuntu's own entry. The kernel's postinst ran update-grub, and this is
# the assertion that it did not move anything.
default=$(dev_ssh "sudo -n grub-editenv $GRUBENV list | sed -n 's/^saved_entry=//p'" || true)
case "$default" in
  gnulinux-*) ok "the default is still Ubuntu's own entry ($default)" ;;
  *) die "the saved default is now '$default', not Ubuntu's own entry. Put it back before booting
         anything: ssh $SSH_HOST sudo pro-boot default stock" ;;
esac

echo
ok "$PEDAL_KERNEL is installed, held, and not booted."
echo "  next:  ssh $SSH_HOST sudo pro-boot try --kernel $PEDAL_KERNEL --args '$AUDIO_TUNING_ARGS'"
echo "         or, with the watching done for you:  make pro-try"
