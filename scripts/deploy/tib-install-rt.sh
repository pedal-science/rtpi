#!/usr/bin/env bash
# Install a built kernel into tib's CANDIDATE slot. Does not arm it, does not reboot.
#
# WHICH SLOT IS WHICH, because it is counter-intuitive
# The candidate is the plain /boot/{zImage,uInitrd,dtb} symlinks -- the ones Armbian's own
# postinst repoints at the newest installed kernel. The known-good is the frozen *-good
# copies. That inversion is deliberate: it means a routine Armbian kernel upgrade can never
# silently become the default boot, because our boot.cmd defaults to the frozen slot and
# only touches the symlinks when explicitly armed.
#
# So installing a kernel the normal Debian way IS staging a candidate. Nothing here can
# change what the board boots by default; only fw_setenv rt_try 1 can do that, and only
# once.
#
# Usage: tib-install-rt.sh --release 7.2.6 [--yes]

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

load_device tib
require_ssh

KREL=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --release) KREL="$2"; shift 2 ;;
    --yes)     RTPI_ASSUME_YES=1; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done
[[ -n $KREL ]] || KREL=$(cat "$RTPI_ROOT/build/tib/kernelrelease" 2>/dev/null || true)
[[ -n $KREL ]] || die "--release is required (or build first)"

BOOT_TAR="$RTPI_ROOT/build/tib/boot-$KREL.tar.gz"
MOD_TAR="$RTPI_ROOT/build/tib/modules-$KREL.tar.gz"
[[ -f $BOOT_TAR && -f $MOD_TAR ]] || die "missing artifacts for $KREL. Run scripts/build/tib-rt.sh"

log "installing $KREL as the candidate on $SSH_HOST"

# --- the fallback must be intact BEFORE we touch anything ---------------------------
log "verifying the known-good slot before we start"
dev_ssh "test -f $BOOT_DIR/zImage$GOOD_SLOT_SUFFIX && test -f $BOOT_DIR/uInitrd$GOOD_SLOT_SUFFIX && test -d $BOOT_DIR/dtb$GOOD_SLOT_SUFFIX" \
  || die "known-good slot is incomplete. Refusing — there would be nothing to fall back to."
GOOD_BEFORE=$(dev_ssh "sha256sum $BOOT_DIR/zImage$GOOD_SLOT_SUFFIX $BOOT_DIR/uInitrd$GOOD_SLOT_SUFFIX | sha256sum | cut -d' ' -f1")
ok "known-good slot present (fingerprint ${GOOD_BEFORE:0:16}…)"

dev_ssh "systemctl is-enabled rtpi-validate.service >/dev/null 2>&1" \
  || warn "rtpi-validate.service is not enabled — a candidate that boots without network
         will sit there unreachable. Install it: scripts/deploy/tib-install-validate.sh"

AVAIL=$(dev_ssh "df -Pm / | awk 'NR==2{print \$4}'")
(( AVAIL >= 600 )) || die "only ${AVAIL}MB free on / — need 600MB"
ok "${AVAIL}MB free"

confirm "Install $KREL into the candidate slot on $SSH_HOST?"

# --- transfer ------------------------------------------------------------------------
log "transferring ($(du -h "$MOD_TAR" | cut -f1) modules + $(du -h "$BOOT_TAR" | cut -f1) boot)"
scp "${SSH_OPTS[@]}" -q "$BOOT_TAR" "$MOD_TAR" "$SSH_HOST:/var/tmp/"

# --- install -------------------------------------------------------------------------
dev_ssh "bash -s" <<REMOTE || die "install failed on the device"
set -euo pipefail
cd /var/tmp

echo "==> modules"
sudo tar -C / -xzf "modules-$KREL.tar.gz"
sudo depmod -a "$KREL"
echo "    /lib/modules/$KREL: \$(sudo du -sh /lib/modules/$KREL | cut -f1)"

echo "==> boot assets"
sudo rm -rf /tmp/rtpi-boot && mkdir -p /tmp/rtpi-boot
tar -C /tmp/rtpi-boot -xzf "boot-$KREL.tar.gz"
sudo install -m 0644 /tmp/rtpi-boot/boot/zImage            "$BOOT_DIR/vmlinuz-$KREL"
sudo install -m 0644 "/tmp/rtpi-boot/boot/config-$KREL"    "$BOOT_DIR/config-$KREL"
sudo install -m 0644 "/tmp/rtpi-boot/boot/System.map-$KREL" "$BOOT_DIR/System.map-$KREL"
sudo rm -rf "$BOOT_DIR/dtb-$KREL"
sudo cp -a /tmp/rtpi-boot/dtb "$BOOT_DIR/dtb-$KREL"
rm -rf /tmp/rtpi-boot

echo "==> initramfs"
# Armbian's /etc/initramfs/post-update.d/99-uboot runs automatically here: it mkimage-wraps
# initrd.img-<ver> into uInitrd-<ver> AND repoints the /boot/uInitrd symlink. So this one
# command stages two thirds of the candidate slot by itself.
sudo update-initramfs -c -k "$KREL" 2>&1 | tail -5

echo "==> pointing the candidate slot at $KREL"
sudo ln -sfn "vmlinuz-$KREL" "$BOOT_DIR/zImage"
sudo ln -sfn "dtb-$KREL"     "$BOOT_DIR/dtb"
sudo ln -sfn "uInitrd-$KREL" "$BOOT_DIR/uInitrd"
sudo sync

rm -f "/var/tmp/boot-$KREL.tar.gz" "/var/tmp/modules-$KREL.tar.gz"
REMOTE

# --- verify --------------------------------------------------------------------------
log "verifying the candidate slot"
FDT=$(dev_ssh "grep -oP '(?<=^fdtfile=).*' $BOOT_ENV_FILE 2>/dev/null" || true)
[[ -n $FDT ]] || FDT="$BOARD_DTB"

dev_ssh "bash -s" <<REMOTE || die "candidate slot is incomplete"
set -e
fail=0
for f in "$BOOT_DIR/zImage" "$BOOT_DIR/uInitrd" "$BOOT_DIR/dtb/$FDT"; do
  if [ -e "\$f" ]; then echo "    OK      \$f -> \$(readlink -f "\$f" | xargs basename)"; else echo "    MISSING \$f"; fail=1; fi
done
# The symlinks must resolve to the version we just installed, not the old one.
for l in zImage uInitrd dtb; do
  t=\$(readlink "$BOOT_DIR/\$l")
  case "\$t" in *"$KREL"*) echo "    OK      \$l points at $KREL" ;;
                        *) echo "    WRONG   \$l points at \$t, expected $KREL"; fail=1 ;; esac
done
[ -d "/lib/modules/$KREL" ] && echo "    OK      /lib/modules/$KREL" || { echo "    MISSING modules"; fail=1; }
exit \$fail
REMOTE

# --- the fallback must be untouched --------------------------------------------------
GOOD_AFTER=$(dev_ssh "sha256sum $BOOT_DIR/zImage$GOOD_SLOT_SUFFIX $BOOT_DIR/uInitrd$GOOD_SLOT_SUFFIX | sha256sum | cut -d' ' -f1")
if [[ $GOOD_BEFORE == "$GOOD_AFTER" ]]; then
  ok "known-good slot is byte-identical to before the install"
else
  die "THE KNOWN-GOOD SLOT CHANGED during the install. Do not reboot.
         before ${GOOD_BEFORE:0:16}…  after ${GOOD_AFTER:0:16}…"
fi

echo >&2
ok "$KREL is staged as the candidate"
log "the board still boots the known-good slot. To try it ONCE:"
log "    ssh $SSH_HOST 'sudo /usr/bin/fw_setenv rt_try 1' && ssh $SSH_HOST 'sudo systemctl reboot'"
log "    ./scripts/safety/watch-reboot.sh tib --expect $KREL"
