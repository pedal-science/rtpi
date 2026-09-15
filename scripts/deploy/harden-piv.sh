#!/usr/bin/env bash
# Close the two lockout gaps on piv. Run this BEFORE any RT kernel is tried.
#
# Gap 1: /etc/flash-kernel/piboot-validate is the stock `true`, and
#        piboot-try-validate.service has no network dependency. A kernel that reaches
#        multi-user.target with no working network is marked good and PROMOTED — losing
#        remote access permanently. Our hook requires sshd and an address.
# Gap 2: kernel.panic=0, no panic= in cmdline, RuntimeWatchdogUSec=0. A panic or hang
#        stops dead and needs a physical power cycle. Arming the watchdog makes the
#        fallback automatic: the reset lands on the known-good kernel (tryboot is
#        one-shot and already consumed) and piboot-try-reboot then marks the candidate bad.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
load_device piv
require_ssh

SRC="$RTPI_ROOT/devices/piv/etc"

log "installing validate hook"
# Keep a copy of the stock hook the first time, so we can always get back.
dev_ssh "sudo test -f /etc/flash-kernel/piboot-validate.rtpi-orig || \
         sudo cp -a /etc/flash-kernel/piboot-validate /etc/flash-kernel/piboot-validate.rtpi-orig"
scp "${SSH_OPTS[@]}" -q "$SRC/flash-kernel/piboot-validate" "$SSH_HOST:/tmp/piboot-validate"
dev_ssh "sudo install -m 0755 -o root -g root /tmp/piboot-validate /etc/flash-kernel/piboot-validate && rm -f /tmp/piboot-validate"
ok "validate hook installed"

log "installing systemd drop-ins"
scp "${SSH_OPTS[@]}" -q "$SRC/systemd/system.conf.d/10-rtpi-watchdog.conf" "$SSH_HOST:/tmp/10-rtpi-watchdog.conf"
dev_ssh "sudo install -D -m 0644 /tmp/10-rtpi-watchdog.conf /etc/systemd/system.conf.d/10-rtpi-watchdog.conf && rm -f /tmp/10-rtpi-watchdog.conf"

scp "${SSH_OPTS[@]}" -q "$SRC/systemd/system/piboot-try-validate.service.d/10-rtpi-timeout.conf" "$SSH_HOST:/tmp/10-rtpi-timeout.conf"
dev_ssh "sudo install -D -m 0644 /tmp/10-rtpi-timeout.conf /etc/systemd/system/piboot-try-validate.service.d/10-rtpi-timeout.conf && rm -f /tmp/10-rtpi-timeout.conf"
ok "systemd drop-ins installed"

log "installing dracut drop-in (arms the watchdog inside the initramfs too)"
scp "${SSH_OPTS[@]}" -q "$SRC/dracut.conf.d/20-rtpi-watchdog.conf" "$SSH_HOST:/tmp/20-rtpi-watchdog.conf"
dev_ssh "sudo install -D -m 0644 /tmp/20-rtpi-watchdog.conf /etc/dracut.conf.d/20-rtpi-watchdog.conf && rm -f /tmp/20-rtpi-watchdog.conf"
ok "dracut drop-in installed"

log "recording audio device id for the validate hook"
dev_ssh "printf '%s\n' '$AUDIO_USB_ID' | sudo tee /etc/rtpi-audio-usb-id >/dev/null"

log "reloading systemd so the watchdog arms now"
dev_ssh "sudo systemctl daemon-reexec"

echo
log "verifying:"
dev_ssh "systemctl show | grep -E 'RuntimeWatchdogUSec|WatchdogDevice' | sed 's/^/  /'"
dev_ssh "systemctl show piboot-try-validate.service -p TimeoutStartUSec | sed 's/^/  /'"

echo
warn "NOTE: RuntimeWatchdogSec only takes effect after daemon-reexec, which is done."
warn "The dracut drop-in applies to the NEXT initramfs generation."
ok "piv hardened. Run 'make preflight-piv' to confirm."
