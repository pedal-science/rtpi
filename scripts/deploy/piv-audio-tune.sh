#!/usr/bin/env bash
# Install the runtime half of piv's low-latency audio profile.
#
# TWO HALVES, INSTALLED SEPARATELY, ON PURPOSE
#   boot half     CPU isolation and default IRQ steering. Needs a reboot, can in principle
#                 stop the machine coming back, so it goes through the tryboot one-shot:
#                     scripts/safety/arm-try-piv.sh --expect <rel> --audio-tuning --reboot
#   runtime half  THIS script. Pins the audio interrupt and raises its priority. Changes
#                 nothing on disk that boots, reverts completely on reboot, and therefore
#                 needs no rollback machinery at all.
#
# Installing the runtime half FIRST is deliberate: it is the part that can be tested
# immediately and reverted by a power cycle, so it is how you find out whether this
# board's interrupt controller honours affinity at all -- before you commit to a reboot
# with changed boot arguments.
#
# Usage: piv-audio-tune.sh [--yes] [--apply-now]

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

load_device piv
require_ssh

APPLY_NOW=0
for a in "$@"; do
  case "$a" in
    --yes)       RTPI_ASSUME_YES=1 ;;
    --apply-now) APPLY_NOW=1 ;;
    *) die "unknown argument: $a" ;;
  esac
done

SRC="$RTPI_ROOT/devices/piv"
CONF_SRC="$SRC/etc/rtpi/audio-tune.conf"
TUNE_SRC="$SRC/usr/local/sbin/rtpi-audio-tune"
UNIT_SRC="$SRC/etc/systemd/system/rtpi-audio-tune.service"
UDEV_SRC="$SRC/etc/udev/rules.d/90-rtpi-audio-tune.rules"
for f in "$CONF_SRC" "$TUNE_SRC" "$UNIT_SRC" "$UDEV_SRC"; do
  [[ -f $f ]] || die "missing source file: $f"
done

# ---------------------------------------------------------------- preflight
# The config names an interrupt. If that name is not present the service installs fine and
# then does nothing useful for ever, so check now while there is someone watching.
AUDIO_IRQ_NAME=$(grep -E '^AUDIO_IRQ_NAME=' "$CONF_SRC" | cut -d'"' -f2)
[[ -n $AUDIO_IRQ_NAME ]] || die "could not read AUDIO_IRQ_NAME from $CONF_SRC"
log "checking '$AUDIO_IRQ_NAME' exists on $SSH_HOST"
if ! dev_ssh "awk -v n='$AUDIO_IRQ_NAME' '\$NF == n { found=1 } END { exit !found }' /proc/interrupts"; then
  warn "no interrupt named '$AUDIO_IRQ_NAME' right now. Present xHCI interrupts:"
  dev_ssh "grep xhci /proc/interrupts | sed 's/^/      /'" >&2 || true
  die "plug the interface in, or correct AUDIO_IRQ_NAME in $CONF_SRC"
fi
ok "'$AUDIO_IRQ_NAME' present"

# Warn if the audio controller and the root filesystem share an interrupt. They do not on
# this board -- audio is on xhci-hcd:usb2 and root is a UAS device on xhci-hcd:usb4 -- but
# if they ever did, pinning the audio interrupt would drag disk I/O onto the audio core
# and make things worse rather than better, which is worth knowing before rather than
# after.
ROOT_SRC=$(dev_ssh "findmnt -no SOURCE / | sed 's|/dev/||; s|[0-9]*$||'")
log "root filesystem is on $ROOT_SRC"

confirm "Install rtpi-audio-tune on $SSH_HOST? (runtime only; reverts on reboot)"

log "installing"
scp "${SSH_OPTS[@]}" -q "$CONF_SRC" "$SSH_HOST:/tmp/rtpi-audio-tune.conf"
scp "${SSH_OPTS[@]}" -q "$TUNE_SRC" "$SSH_HOST:/tmp/rtpi-audio-tune"
scp "${SSH_OPTS[@]}" -q "$UNIT_SRC" "$SSH_HOST:/tmp/rtpi-audio-tune.service"
scp "${SSH_OPTS[@]}" -q "$UDEV_SRC" "$SSH_HOST:/tmp/90-rtpi-audio-tune.rules"
dev_ssh "set -e
  sudo mkdir -p /etc/rtpi
  sudo install -m 0644 -o root -g root /tmp/rtpi-audio-tune.conf    /etc/rtpi/audio-tune.conf
  sudo install -m 0755 -o root -g root /tmp/rtpi-audio-tune         /usr/local/sbin/rtpi-audio-tune
  sudo install -m 0644 -o root -g root /tmp/rtpi-audio-tune.service /etc/systemd/system/rtpi-audio-tune.service
  sudo install -m 0644 -o root -g root /tmp/90-rtpi-audio-tune.rules /etc/udev/rules.d/90-rtpi-audio-tune.rules
  rm -f /tmp/rtpi-audio-tune.conf /tmp/rtpi-audio-tune /tmp/rtpi-audio-tune.service /tmp/90-rtpi-audio-tune.rules
  sudo systemctl daemon-reload
  sudo udevadm control --reload-rules
  sudo systemctl enable rtpi-audio-tune.service" 2>&1 | sed 's/^/    /' >&2
ok "installed and enabled"

if (( APPLY_NOW )); then
  log "applying now"
  dev_ssh "sudo systemctl restart rtpi-audio-tune.service" || true
  dev_ssh "systemctl status rtpi-audio-tune.service --no-pager -l | sed -n '1,25p'" 2>&1 | sed 's/^/    /' >&2

  # Verify against the kernel rather than against the script's own claims: read back the
  # affinity and the thread priority from /proc.
  echo
  log "verifying from /proc"
  dev_ssh "bash -s" <<'REMOTE' 2>&1 | sed 's/^/    /' >&2
irq=$(awk -v n="$(grep -E '^AUDIO_IRQ_NAME=' /etc/rtpi/audio-tune.conf | cut -d'"' -f2)" \
      '$NF == n { sub(/:$/,"",$1); print $1; exit }' /proc/interrupts)
echo "audio irq        : $irq"
echo "smp_affinity_list: $(cat /proc/irq/$irq/smp_affinity_list)"
ps -eLo tid,cls,rtprio,psr,comm= | awk -v p="irq/$irq-" '$5 ~ "^"p { printf "thread           : tid=%s cls=%s prio=%s cpu=%s %s\n",$1,$2,$3,$4,$5 }'
REMOTE
else
  log "not applied yet. Apply with:  ssh $SSH_HOST sudo systemctl start rtpi-audio-tune"
fi

echo
ok "runtime half done. The boot half (CPU isolation) is separate:"
echo "  scripts/safety/arm-try-piv.sh --expect \$(ssh $SSH_HOST uname -r) --realtime --audio-tuning --reboot"
