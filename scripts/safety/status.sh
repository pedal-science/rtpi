#!/usr/bin/env bash
# Show a device's boot-slot state at a glance. Read-only; safe to run any time.
# Usage: status.sh piv
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
DEVICE="${1:?usage: status.sh piv}"
load_device "$DEVICE"
require_ssh

echo "=== $SSH_HOST ==="
dev_ssh 'echo "running kernel : $(uname -r)"; echo "version banner : $(uname -v)"'
dev_ssh 'printf "realtime       : "; uname -v | grep -q PREEMPT_RT && echo "YES (PREEMPT_RT)" || echo "no"'
dev_ssh 'printf "uptime         : "; uptime -p'
echo

case "$DEVICE" in
  piv)
    echo "--- A/B slots ---"
    dev_ssh "for d in current new old; do
               printf '  %-8s ' \$d
               if sudo test -d $BOOT_MOUNT/\$d; then
                 printf 'state=%-8s ' \"\$(sudo cat $BOOT_MOUNT/\$d/state 2>/dev/null || echo '?')\"
                 printf 'kernel=%s\n' \"\$(sudo zcat -f $BOOT_MOUNT/\$d/vmlinuz 2>/dev/null | strings -a 2>/dev/null | grep -m1 -oE 'Linux version [0-9][^ ]*' || echo '?')\"
               else
                 echo '(absent)'
               fi
             done"
    echo
    echo "--- tryboot ---"
    dev_ssh "printf '  this boot is a tryboot: '; od -An -tu4 --endian=big /proc/device-tree/chosen/bootloader/tryboot | tr -d ' '"
    echo "--- piboot-try ---"
    dev_ssh "sudo piboot-try --status 2>&1 || true"
    echo "  (silent above == stable: nothing staged, nothing pending)"
    echo
    echo "--- watchdog ---"
    dev_ssh "systemctl show | grep -E 'RuntimeWatchdogUSec|WatchdogDevice'"
    echo "--- boot partition space ---"
    dev_ssh "df -h $BOOT_MOUNT | tail -1"
    echo "--- package holds ---"
    dev_ssh "apt-mark showhold 2>/dev/null | sed 's/^/  /' || true"
    ;;

  *) die "unknown device $DEVICE" ;;
esac
