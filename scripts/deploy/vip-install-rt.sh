#!/usr/bin/env bash
# Install the vip kernel built by scripts/build/vip-ubuntu-rt.sh into the RUNNING pedal root:
# its modules, /boot files, the device trees, and the guarded initramfs (dracut, shaped by the
# pedal root's vip-guard drop-ins — the same command the image build runs in that root,
# devices/common/image/build-image). Installs only; `make vip-try` stages it in the spare slot
# and reboots once. The running stock kernel and its modules are left untouched (the separate
# release string), so the known-good slot always has something to fall back to.
#
# The installation is a recorded, idempotent set of file copies. It is not dpkg: vip is built
# from an image and its kernel never comes from apt (no flash-kernel, no piboot-try).

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

load_device vip

OUT="$RTPI_ROOT/build/vip"
RELEASE=$(cat "$OUT/kernelrelease" 2>/dev/null) || die "no build/vip/kernelrelease — run make vip-rt first"
STOCK="$PEDAL_KERNEL"

require_ssh
log "installing $RELEASE beside $STOCK on $SSH_HOST"

# Only on the pedal root, with a good active slot and nothing armed — vip-boot's own gate,
# read before anything is copied.
status=$(dev_ssh "sudo vip-boot status")
echo "$status" | sed 's/^/  /' >&2
echo "$status" | grep -q '^running    root=pedal' || die "not running on the pedal root"
echo "$status" | grep -q 'nothing armed' || die "a one-shot is armed — resolve it first"
echo "$status" | awk '$3=="*" && $4!="good" {exit 1}' || die "the active slot is not marked good"

# A half-written kernel tree is worse than none.
avail=$(dev_ssh "df -Pm / | awk 'NR==2{print \$4}'")
(( avail >= 600 )) || die "only ${avail}MB free on / — need 600MB"
ok "${avail}MB free on /"

for f in "boot-$RELEASE.tar.gz" "modules-$RELEASE.tar.gz" "bcm2712-rpi-5-b.dtb.sha256"; do
  [[ -s "$OUT/$f" ]] || die "missing $OUT/$f — did the build finish?"
done
scp "${SSH_OPTS[@]}" "$OUT/boot-$RELEASE.tar.gz" "$OUT/modules-$RELEASE.tar.gz" \
    "$OUT/bcm2712-rpi-5-b.dtb.sha256" "$SSH_HOST:/tmp/" || die "upload failed"
ok "artifacts uploaded"

dev_ssh "sudo bash -euo pipefail -s" <<REMOTE
REL=$RELEASE
STOCK=$STOCK

mkdir -p /tmp/rtpi-vip
mv /tmp/boot-\$REL.tar.gz /tmp/modules-\$REL.tar.gz /tmp/bcm2712-rpi-5-b.dtb.sha256 /tmp/rtpi-vip/

# Modules: our own tree; the stock one is untouched (the fallback boots against it).
# The tarball's paths start at lib/modules, so it extracts at /.
rm -rf "/lib/modules/\$REL"
mkdir -p "/lib/modules/\$REL"
tar -C / -xzf "/tmp/rtpi-vip/modules-\$REL.tar.gz"
[[ -s "/lib/modules/\$REL/modules.dep" ]] || { echo "no modules.dep — modules_install did not finish"; exit 1; }
echo "modules in place: \$(find /lib/modules/\$REL -name '*.ko' | wc -l) .ko files"

# Every module the stock kernel ships must exist in the new tree. This catches a module
# make silently dropped (it happened once, mid-deploy development: four netfilter .ko lost
# to a disk-full link failure that the next make never re-linked). Name-based, because the
# strip and the module signing make byte-comparison meaningless.
comm -13 \
  <(find "/lib/modules/\$REL/kernel" -name '*.ko' -printf '%f\n' | sed 's/\.ko$//' | sort -u) \
  <(find "/lib/modules/\$STOCK/kernel" -name '*.ko*' -printf '%f\n' | sed 's/\.ko.*//' | sort -u) \
  > /tmp/rtpi-vip/missing-modules.txt || true
if [[ -s /tmp/rtpi-vip/missing-modules.txt ]]; then
  echo "!!! these stock modules are missing from the new tree:" >&2
  cat /tmp/rtpi-vip/missing-modules.txt >&2
  rm -rf "/lib/modules/\$REL"
  exit 1
fi
echo "module set matches the stock kernel's"

# /boot: the names vip-boot try-kernel's copy_kernel reads.
tar -C /tmp/rtpi-vip -xzf "/tmp/rtpi-vip/boot-\$REL.tar.gz"
install -m 644 /tmp/rtpi-vip/boot/vmlinuz          /boot/vmlinuz-\$REL
install -m 644 "/tmp/rtpi-vip/boot/config-\$REL"   /boot/config-\$REL
install -m 644 "/tmp/rtpi-vip/boot/System.map-\$REL" /boot/System.map-\$REL

# Device trees: the overlays this tree builds are byte-identical to the ones the stock package
# ships (checked on the build that introduced this: 367 .dtbo plus overlay_map/hat_map, all
# matching), so they come from the stock release's directory; the built bcm2712* dtbs are
# checked against the stock ones before either is trusted.
mkdir -p "/usr/lib/firmware/\$REL"
cp -a "/usr/lib/firmware/\$STOCK/device-tree" "/usr/lib/firmware/\$REL/device-tree"
stock_sha=\$(sha256sum "/usr/lib/firmware/\$STOCK/device-tree/broadcom/bcm2712-rpi-5-b.dtb" | cut -d' ' -f1)
built_sha=\$(cut -d' ' -f1 /tmp/rtpi-vip/bcm2712-rpi-5-b.dtb.sha256)
if [[ "\$stock_sha" == "\$built_sha" ]]; then
  echo "built bcm2712-rpi-5-b.dtb is byte-identical to the stock one (\$built_sha)"
else
  echo "!!! built bcm2712-rpi-5-b.dtb differs from stock (\$built_sha vs \$stock_sha) — keeping the stock dtbs" >&2
fi
cp /tmp/rtpi-vip/dtb/*.dtb "/usr/lib/firmware/\$REL/device-tree/broadcom/"

# The guarded initramfs, built on the pedal root so its own drop-ins shape it (the watchdog
# dracut conf and the vip-guard module), exactly as devices/common/image/build-image does.
dracut --quiet --force --no-hostonly --kver "\$REL" \
  --add-drivers "sdhci-brcmstb sdhci-iproc mmc_block ext4 vfat" "/boot/initrd.img-\$REL"
lsinitrd "/boot/initrd.img-\$REL" > /tmp/rtpi-vip/initrd-list.txt
grep -q 'vip-guard\.sh' /tmp/rtpi-vip/initrd-list.txt \
  || { echo "!!! vip-guard.sh is not in the new initramfs" >&2; exit 1; }
echo "vip-guard.sh is in the initramfs"
ls -l /boot/vmlinuz-\$REL /boot/initrd.img-\$REL

rm -rf /tmp/rtpi-vip
REMOTE

ok "installed $RELEASE on $SSH_HOST (the stock $STOCK is untouched)"
log "next: make vip-try — stages the candidate slot and reboots once"
