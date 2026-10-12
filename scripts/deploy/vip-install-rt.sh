#!/usr/bin/env bash
# Install the vip kernel built by scripts/build/vip-ubuntu-rt.sh into the RUNNING pedal root:
# its modules, /boot files, the device trees, and the guarded initramfs. The work itself is
# devices/vip/usr/local/sbin/vip-install-kernel — the same script pedal.project's image build runs
# inside the root it is building, so the gates, the device-tree copy and the dracut invocation
# exist once (pedal.project docs/vip-kernel-image.md says why the kernel is an artefact).
#
# Installs only; `make vip-try` stages it in the spare slot and reboots once. The running stock
# kernel and its modules are left untouched (the separate release string), so the known-good slot
# always has something to fall back to.
#
# The installation is a recorded, idempotent set of file copies. It is not dpkg: vip is built
# from an image and its kernel never comes from apt (no flash-kernel, no piboot-try).

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

load_device vip

OUT="$RTPI_ROOT/build/vip"
RELEASE=$(cat "$OUT/kernelrelease" 2>/dev/null) || die "no build/vip/kernelrelease — run make vip-rt first"
STOCK="$FALLBACK_KERNEL"

require_ssh
log "installing $RELEASE beside $STOCK on $SSH_HOST"

# Only on the pedal root, with a good active slot and nothing armed — vip-boot's own gate,
# read before anything is copied.
status=$(dev_ssh "sudo vip-boot status")
echo "$status" | sed 's/^/  /' >&2
echo "$status" | grep -q '^running    root=pedal' || die "not running on the pedal root"
echo "$status" | grep -q 'nothing armed' || die "a one-shot is armed — resolve it first"
echo "$status" | awk '$3=="*" && $4!="good" {exit 1}' || die "the active slot is not marked good"
running=$(dev_ssh 'uname -r')
[[ $running != "$RELEASE" ]] || die \
  "refusing to install $RELEASE over the kernel vip is running — a trial needs its own release string"

# A half-written kernel tree is worse than none.
avail=$(dev_ssh "df -Pm / | awk 'NR==2{print \$4}'")
(( avail >= 600 )) || die "only ${avail}MB free on / — need 600MB"
ok "${avail}MB free on /"

# What vip-install-kernel reads, plus the checksum list when the build wrote one.
FILES=("boot-$RELEASE.tar.gz" "modules-$RELEASE.tar.gz" kernelrelease build-kind trimmed-ok.txt
       proc-modules bcm2712-rpi-5-b.dtb.sha256)
[[ -e "$OUT/sha256sums" ]] && FILES+=(sha256sums)
for f in "${FILES[@]}"; do
  [[ -s "$OUT/$f" ]] || die "missing or empty $OUT/$f — did the build finish?"
done
scp "${SSH_OPTS[@]}" "${FILES[@]/#/$OUT/}" \
    "$RTPI_ROOT/devices/vip/usr/local/sbin/vip-install-kernel" "$SSH_HOST:/tmp/" || die "upload failed"
ok "artefacts and the installer uploaded"

# Run the uploaded installer, not the one on the card: this may be the first kernel after a change
# to that script, and apply may not have run yet.
dev_ssh "sudo bash -euo pipefail -s" <<REMOTE || die "installing $RELEASE failed on $SSH_HOST"
mkdir -p /tmp/rtpi-vip
for f in ${FILES[*]}; do mv "/tmp/\$f" /tmp/rtpi-vip/ || exit 1; done
mv /tmp/vip-install-kernel /tmp/rtpi-vip/
chmod +x /tmp/rtpi-vip/vip-install-kernel
/tmp/rtpi-vip/vip-install-kernel --artefacts /tmp/rtpi-vip --root /
rm -rf /tmp/rtpi-vip
REMOTE

ok "installed $RELEASE on $SSH_HOST (the stock $STOCK is untouched)"
log "next: make vip-try — stages the candidate slot and reboots once"
