#!/usr/bin/env bash
# Show a device's boot-slot state at a glance. Read-only; safe to run any time.
# Usage: status.sh <piv|tib>
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
DEVICE="${1:?usage: status.sh <piv|tib>}"
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
                 printf 'kernel=%s\n' \"\$(sudo strings -a $BOOT_MOUNT/\$d/vmlinuz 2>/dev/null | grep -m1 -oE 'Linux version [0-9][^ ]*' || echo '?')\"
               else
                 echo '(absent)'
               fi
             done"
    echo
    echo "--- tryboot ---"
    dev_ssh "printf '  this boot is a tryboot: '; od -An -tu4 --endian=big /proc/device-tree/chosen/bootloader/tryboot | tr -d ' '"
    echo "--- piboot-try ---"
    dev_ssh "sudo piboot-try --status 2>&1 || true"
    echo "  (no output above == stable, nothing pending)"
    echo
    echo "--- watchdog ---"
    dev_ssh "systemctl show | grep -E 'RuntimeWatchdogUSec|WatchdogDevice'"
    echo "--- boot partition space ---"
    dev_ssh "df -h $BOOT_MOUNT | tail -1"
    echo "--- package holds ---"
    dev_ssh "apt-mark showhold 2>/dev/null | sed 's/^/  /' || true"
    ;;

  tib)
    echo "--- kernel slots ---"
    dev_ssh "cd $BOOT_DIR && for f in zImage uInitrd zImage$GOOD_SLOT_SUFFIX uInitrd$GOOD_SLOT_SUFFIX; do
               printf '  %-14s ' \$f
               if [ -e \"\$f\" ]; then ls -l \"\$f\" | awk '{print \$NF}'; else echo '(absent)'; fi
             done"
    echo
    echo "--- U-Boot env ---"
    if dev_ssh "command -v fw_printenv >/dev/null 2>&1"; then
      dev_ssh "sudo fw_printenv $TRY_VAR 2>&1 | sed 's/^/  /'" || echo "  ($TRY_VAR not set)"
    else
      echo "  fw_printenv not installed (package: $UBOOT_ENV_PKG)"
    fi
    echo "  env region validity:"
    dev_ssh "sudo dd if=$UBOOT_ENV_DEV bs=512 skip=$UBOOT_ENV_LBA count=$UBOOT_ENV_BLOCKS status=none" \
      | python3 "$RTPI_ROOT/scripts/safety/decode-uboot-env.py" /dev/stdin 2>&1 \
      | sed 's/^/    /' | head -12
    echo
    echo "--- watchdog ---"
    dev_ssh "systemctl show | grep -E 'RuntimeWatchdogUSec|WatchdogDevice'"
    ;;
esac
