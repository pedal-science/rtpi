#!/usr/bin/env bash
# Prove pro's automatic fallback works, with a trial that is MEANT to fail.
#
# This is the rehearsal piv has (scripts/safety/rehearse-piv.sh) and the one vip's record calls the
# reason to believe its fallback at all: a safety net nobody has dropped something into is a
# hypothesis. It runs the real path — arm a one-shot, reboot, fail, mark bad, come back — using the
# kernel pro is already running, so nothing new is being tested except the machinery.
#
#   --leg validate   (default) the trial boots fine but has no network, so pro-boot-validate fails
#                    it. Exercises: grub-reboot's one-shot, the trial entry, the validate hook, the
#                    rollback reboot and `pro-boot settle`.
#   --leg dracut     the trial has a root= that does not exist, so the initramfs never finds a root.
#                    Exercises DRACUT_SAFETY_ARGS (rd.emergency=reboot and the timeouts), which is
#                    the one path that can need a power cycle if it does not work. Opt in on purpose.
#
# Either way the machine should come back on its own, running the same kernel from the saved
# default, with the trial marked bad.
#
# Usage: rehearse-pro.sh [--leg validate|dracut]
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
load_device pro
require_ssh

LEG=validate
while [[ $# -gt 0 ]]; do
  case "$1" in
    --leg) LEG="$2"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

"$RTPI_ROOT/scripts/safety/preflight.sh" pro

RUNNING=$(dev_ssh 'uname -r')
SAVED=$(dev_ssh "sudo -n grub-editenv $GRUBENV list | sed -n 's/^saved_entry=//p'")
log "pro is running $RUNNING; its saved default is $SAVED"

case "$LEG" in
  validate)
    # No WiFi driver means no address on a real interface, which is check 2 of the validate hook.
    # iwlmvm has to go with iwlwifi or the first pulls the second back in.
    BREAK="modprobe.blacklist=iwlwifi,iwlmvm"
    WHY="the trial will boot but have no network, so validation fails it"
    ;;
  dracut)
    warn "the dracut leg is the one that can need a power cycle if rd.emergency=reboot does not"
    warn "work. pro is on the bench and its BIOS restores power state, so that is recoverable —"
    warn "but do not run this leg from somewhere you cannot reach the machine."
    BREAK="root=/dev/does-not-exist"
    WHY="the initramfs will never find a root, so dracut must reboot by itself"
    ;;
  *) die "unknown leg: $LEG (validate or dracut)" ;;
esac

log "the deliberately broken argument is: $BREAK"
log "$WHY"
confirm "Reboot $SSH_HOST into a trial that is meant to fail?"

# The trial keeps the running kernel and carries ONLY the breakage: no isolation arguments. The
# thing under test is the machinery — arm, boot, fail, mark bad, come back — and a rehearsal with
# two new variables in it cannot tell you which one you proved. The isolation arguments get their
# own trial afterwards, which is meant to succeed.
dev_ssh "sudo -n pro-boot try --kernel '$RUNNING' --args '$BREAK'" \
  || die "arming the trial failed; nothing has been rebooted"

# The validate leg goes down once and comes back twice: once as the trial (which fails and reboots
# itself) and once on the default. The dracut leg may not become reachable at all in between. Either
# way --settle makes watch-reboot wait through the bounce rather than declaring victory at the first
# answer.
"$RTPI_ROOT/scripts/safety/watch-reboot.sh" pro --expect "$RUNNING" --timeout 900 --settle 120 \
  || warn "watch-reboot did not end cleanly; read the checks below before concluding anything"

echo
log "what the machine says now"
dev_ssh "sudo -n pro-boot status" || true

fails=0
expect() { # expect <description> <remote test>
  local desc="$1"; shift
  if dev_ssh "$*" >/dev/null 2>&1; then ok "$desc"; else warn "FAIL: $desc"; fails=$((fails+1)); fi
}
expect "pro is back on its saved default ($SAVED)" \
  "test \"\$(sudo -n grub-editenv $GRUBENV list | sed -n 's/^saved_entry=//p')\" = '$SAVED'"
expect "this boot is not the trial" "! grep -q 'pedalboot.profile=trial' /proc/cmdline"
expect "the trial is marked bad"    "grep -qx 'state=bad' /var/lib/rtpi/pro-boot/trial"
expect "no trial entry is left in the menu" "! sudo -n grep -q \"'$ENTRY_TRIAL'\" /boot/grub/grub.cfg"
# GRUB clears the one-shot by setting next_entry to the EMPTY string, not by removing the variable:
# 00_header's generated code does `set next_entry=` then `save_env next_entry`. So the test is that
# it has no value — `grub-editenv list` still prints the name. Asserting the variable's absence
# instead reported a failure on a rehearsal that had worked perfectly (2026-11-01).
expect "the one-shot was consumed" \
  "test -z \"\$(sudo -n grub-editenv $GRUBENV list | sed -n 's/^next_entry=//p')\""
expect "the engine is running again" "systemctl is-active --quiet namchaind.service"
log "the trial's own reason: $(dev_ssh "sed -n 's/^reason=//p' /var/lib/rtpi/pro-boot/trial" || true)"

echo
if (( fails )); then
  die "$fails check(s) failed. The fallback did NOT behave as designed — read the journal from the
         failed boot (journalctl -b -1 -u pro-boot-validate) before trying a real kernel."
fi
ok "the fallback works: pro failed a trial and came back by itself."
echo "  A real kernel can now be tried with: make pro-rt && make pro-try"
