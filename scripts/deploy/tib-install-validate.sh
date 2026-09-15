#!/usr/bin/env bash
# Install the candidate-boot validate service on tib.
#
# Safe to install at any time: the unit is gated on ConditionKernelCommandLine, so on a
# known-good boot systemd skips it entirely. It only ever acts on a candidate boot.
#
# Usage: tib-install-validate.sh [--yes]

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

load_device tib
require_ssh
[[ ${1:-} == --yes ]] && RTPI_ASSUME_YES=1

SCRIPT_SRC="$RTPI_ROOT/devices/tib/usr/local/sbin/rtpi-validate"
UNIT_SRC="$RTPI_ROOT/devices/tib/etc/systemd/system/rtpi-validate.service"
[[ -f $SCRIPT_SRC && -f $UNIT_SRC ]] || die "missing source files"

# The service is useless without the slot marker: with no rtpi.slot on the cmdline the
# unit condition never matches and it silently never runs. Check the running system has it.
log "checking the slot marker is on the kernel command line"
SLOT=$(dev_ssh "grep -o 'rtpi\.slot=[a-z-]*' /proc/cmdline" || true)
[[ -n $SLOT ]] \
  || die "no rtpi.slot marker on /proc/cmdline. Install the one-shot boot script first:
         scripts/deploy/tib-install-bootscr.sh"
ok "slot marker present ($SLOT)"

log "checking the tools the validate script relies on"
dev_ssh "command -v ss >/dev/null && command -v ip >/dev/null" \
  || die "ss or ip missing on $SSH_HOST (iproute2)"
ok "ip and ss present"

confirm "Install rtpi-validate.service on $SSH_HOST?"

log "installing"
scp "${SSH_OPTS[@]}" -q "$SCRIPT_SRC" "$SSH_HOST:/tmp/rtpi-validate"
scp "${SSH_OPTS[@]}" -q "$UNIT_SRC"   "$SSH_HOST:/tmp/rtpi-validate.service"
dev_ssh "sudo install -m 0755 -o root -g root /tmp/rtpi-validate /usr/local/sbin/rtpi-validate
         sudo install -m 0644 -o root -g root /tmp/rtpi-validate.service /etc/systemd/system/rtpi-validate.service
         rm -f /tmp/rtpi-validate /tmp/rtpi-validate.service
         sudo mkdir -p /var/lib/rtpi
         sudo systemctl daemon-reload
         sudo systemctl enable rtpi-validate.service" 2>&1 | sed 's/^/    /' >&2

log "verifying"
dev_ssh "systemctl is-enabled rtpi-validate.service" | sed 's/^/    enabled: /' >&2

# Prove the condition actually gates it, rather than trusting the syntax. On a known-good
# boot the unit must be inactive with its condition unmet.
COND=$(dev_ssh "systemctl show rtpi-validate.service -p ConditionResult --value" || true)
ACTIVE=$(dev_ssh "systemctl is-active rtpi-validate.service" || true)
log "on this (${SLOT#rtpi.slot=}) boot: ConditionResult=$COND active=$ACTIVE"
if [[ ${SLOT#rtpi.slot=} == known-good ]]; then
  [[ $COND == no || $ACTIVE == inactive ]] \
    && ok "correctly dormant on a known-good boot" \
    || warn "expected it to be dormant on a known-good boot — check the condition"
fi

ok "installed and enabled"
log "it will run on the next boot that selects the candidate slot."
