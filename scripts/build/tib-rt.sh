#!/usr/bin/env bash
# Build a PREEMPT_RT kernel for tib (RK3288, armhf) in the build container.
#
# WHY MAINLINE AND NOT ARMBIAN'S BUILD SYSTEM
# We need three things: 7.2.6+ source, a config that works on this board, and RT enabled.
# Armbian's framework would also produce .debs, but we install into our own A/B slots by
# hand anyway, so the packaging is exactly the part we do not need -- and it is the heavy,
# slow, network-hungry part. rk3288-tinker-s.dts is in mainline and is byte-identical
# between 6.18.52 and 7.2.6, so mainline supports this board directly.
#
# WHY 7.2.6 SPECIFICALLY
# ARM32 PREEMPT_RT landed in v7.1 (c6e61c06d606, "ARM: 9463/1: Allow to enable RT"). Three
# follow-up fixes missed 7.2 and landed in stable 7.2.6 -- verified by bisecting the stable
# tags for HAVE_POSIX_CPU_TIMERS_TASK_WORK, absent in 7.2..7.2.5 and present in 7.2.6. So
# 7.2.6 is the first release where this is expected to work, so no RT patches are needed.
# One BOARD patch is required, though -- see patches/tib/. Mainline does not give the
# Tinker Board's SDIO wifi a power-on settle delay, and without it the chip fails to
# enumerate on 7.2.6 and the board comes up with no network at all.
#
# WHERE THE CONFIG COMES FROM
# The running kernel's own config, pulled off the board. It is the configuration that
# demonstrably boots this exact hardware -- every driver, every board quirk -- which is a
# far better starting point than a defconfig. olddefconfig migrates it 6.18 -> 7.2, then
# our fragments apply the RT deltas on top.
#
# Usage: tib-rt.sh [--version 7.2.6] [--jobs N] [--shell]

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

load_device tib

KVER="${KERNEL_MIN_VERSION:-7.2.6}"
JOBS=""
DROP_TO_SHELL=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) KVER="$2"; shift 2 ;;
    --jobs)    JOBS="$2"; shift 2 ;;
    --shell)   DROP_TO_SHELL=1; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done

IMAGE="${IMAGE:-rtpi-build:latest}"
VOLUME="${VOLUME:-rtpi-src}"
CCACHE="${CCACHE:-rtpi-ccache}"
OUT="$RTPI_ROOT/build/tib"

docker info >/dev/null 2>&1 || die "docker is not available. Run: make colima-up"
docker image inspect "$IMAGE" >/dev/null 2>&1 || die "image $IMAGE missing. Run: make image"

[[ -n $JOBS ]] || JOBS=$(docker run --rm "$IMAGE" nproc)
mkdir -p "$OUT"

# The board's own working config. Fetched fresh rather than kept in the repo, so it always
# matches whatever is actually running.
log "fetching the running config from $SSH_HOST"
require_ssh
RUNNING=$(dev_ssh 'uname -r')
dev_ssh "cat /boot/config-$RUNNING" > "$OUT/base.config" \
  || die "could not fetch /boot/config-$RUNNING"
ok "base config: $RUNNING ($(wc -l < "$OUT/base.config") lines)"

log "building linux-$KVER for armhf with -j$JOBS"

docker run --rm -i \
  -v "$VOLUME":/src -v "$CCACHE":/ccache \
  -v "$RTPI_ROOT/config":/config:ro \
  -v "$RTPI_ROOT/patches":/patches:ro \
  -v "$OUT":/out \
  -e KVER="$KVER" -e JOBS="$JOBS" -e DROP_TO_SHELL="$DROP_TO_SHELL" \
  "$IMAGE" bash -euo pipefail -s <<'REMOTE'
cd /src

TARBALL="linux-${KVER}.tar.xz"
TREE="/src/linux-${KVER}"

# ---------------------------------------------------------------- source
if [[ ! -d $TREE ]]; then
  if [[ ! -f $TARBALL ]]; then
    echo "==> downloading $TARBALL"
    curl -fSL --retry 3 -o "$TARBALL.part" \
      "https://cdn.kernel.org/pub/linux/kernel/v7.x/$TARBALL"
    mv "$TARBALL.part" "$TARBALL"
  fi
  echo "==> extracting (this takes a couple of minutes)"
  tar -xf "$TARBALL"
fi
cd "$TREE"
echo "==> source: $(make kernelversion 2>/dev/null)"

# ---------------------------------------------------------------- patches
# Applied idempotently: the tree lives in a Docker volume and survives between runs, so a
# second build must not double-apply. A reverse dry-run tells us whether a patch is already
# in place far more reliably than tracking state in a file.
#
# A patch that neither applies nor is already applied is fatal. Skipping it would produce a
# kernel that looks fine and is missing the reason the patch exists -- which for the SDIO
# delay means a board with no network, discovered only after a deploy and a reboot cycle.
shopt -s nullglob
PATCHES=(/patches/tib/*.patch)
shopt -u nullglob
if (( ${#PATCHES[@]} == 0 )); then
  echo "==> no patches in patches/tib/"
else
  echo "==> applying ${#PATCHES[@]} patch(es) from patches/tib/"
  for pf in "${PATCHES[@]}"; do
    name=$(basename "$pf")
    if patch -p1 --dry-run -R -f < "$pf" >/dev/null 2>&1; then
      echo "    already applied: $name"
    elif patch -p1 --dry-run -f < "$pf" >/dev/null 2>&1; then
      patch -p1 < "$pf" >/dev/null
      echo "    applied:         $name"
    else
      echo "!!! $name will not apply and is not already applied." >&2
      echo "!!! Refusing to build a kernel that is missing it." >&2
      exit 1
    fi
  done
fi

# ---------------------------------------------------------------- preconditions
# Fail here rather than after a 25-minute build that quietly produced a non-RT kernel.
echo "==> checking this source really supports PREEMPT_RT on ARM"
if ! grep -rq 'select ARCH_SUPPORTS_RT' arch/arm/Kconfig; then
  echo "!!! arch/arm/Kconfig does not select ARCH_SUPPORTS_RT." >&2
  echo "!!! ARM32 RT landed in v7.1; this tree appears older or altered." >&2
  exit 1
fi
echo "    arch/arm/Kconfig selects ARCH_SUPPORTS_RT"
grep -n 'HAVE_POSIX_CPU_TIMERS_TASK_WORK' arch/arm/Kconfig | head -2 | sed 's/^/    /' || true

export ARCH=arm
export CROSS_COMPILE=arm-linux-gnueabihf-

# ---------------------------------------------------------------- config
echo "==> migrating the board's 6.18 config to $KVER"
cp /out/base.config .config
make olddefconfig >/dev/null

echo "==> merging RT fragments"
./scripts/kconfig/merge_config.sh -m .config \
  /config/audio-rt-common.fragment /config/tib-rt.fragment | tail -20
make olddefconfig >/dev/null

# ---------------------------------------------------------------- verify the config
# merge_config.sh warns about symbols it could not apply but still exits 0, and
# olddefconfig will happily drop a symbol whose dependencies are unmet. Neither failure is
# visible until you boot the result and find it is not realtime. So assert, do not assume.
echo "==> verifying the symbols that matter actually landed"
fail=0
want_y() {
  if grep -q "^$1=y" .config; then echo "    [y]  $1"; else echo "    [!!] $1 is NOT set to y"; fail=1; fi
}
want_unset() {
  if grep -q "^# $1 is not set" .config; then echo "    [n]  $1"
  elif grep -q "^$1=" .config; then echo "    [!!] $1 is SET but must not be: $(grep "^$1=" .config)"; fail=1
  else echo "    [n]  $1 (absent)"; fi
}
want_y CONFIG_PREEMPT_RT
want_y CONFIG_HIGH_RES_TIMERS
want_y CONFIG_OSNOISE_TRACER
want_y CONFIG_TIMERLAT_TRACER
want_unset CONFIG_RT_GROUP_SCHED
want_unset CONFIG_DEBUG_PREEMPT
want_unset CONFIG_HIGHPTE
echo "    HZ = $(grep -E '^CONFIG_HZ=' .config | cut -d= -f2)"
[[ $(grep -E '^CONFIG_HZ=' .config | cut -d= -f2) == 1000 ]] || { echo "    [!!] HZ is not 1000"; fail=1; }

# The board's own drivers must survive the migration, or we build a kernel that cannot
# reach its own network or storage.
for s in CONFIG_RTW88_8723DS CONFIG_DWMAC_ROCKCHIP CONFIG_MMC_DW_ROCKCHIP CONFIG_SND_USB_AUDIO; do
  v=$(grep -E "^$s=" .config | cut -d= -f2 || true)
  [[ -n $v ]] && echo "    [$v]  $s" || { echo "    [!!] $s is not enabled"; fail=1; }
done

if (( fail )); then
  echo "!!! config verification FAILED — refusing to build" >&2
  exit 1
fi
echo "==> config verified"

cp .config /out/built.config

if [[ ${DROP_TO_SHELL:-0} == 1 ]]; then
  echo "==> dropping to a shell as requested (tree is $PWD)"
  exec bash
fi

# ---------------------------------------------------------------- build
echo "==> building zImage, modules and dtbs (-j$JOBS)"
make -j"$JOBS" zImage modules dtbs

KREL=$(make -s kernelrelease)
echo "==> built $KREL"

# ---------------------------------------------------------------- collect
rm -rf /out/staging && mkdir -p /out/staging/boot /out/staging/dtb
cp arch/arm/boot/zImage /out/staging/boot/
cp .config              "/out/staging/boot/config-$KREL"
cp System.map           "/out/staging/boot/System.map-$KREL"

# Flat, matching this board's layout: fdtfile is a bare filename, not vendor-prefixed.
find arch/arm/boot/dts -name '*.dtb' -exec cp {} /out/staging/dtb/ \;
if [[ -d arch/arm/boot/dts/overlay ]]; then
  mkdir -p /out/staging/dtb/overlay
  find arch/arm/boot/dts/overlay -name '*.dtbo' -exec cp {} /out/staging/dtb/overlay/ \;
fi
echo "    dtbs: $(ls /out/staging/dtb/*.dtb | wc -l), including:"
ls /out/staging/dtb/ | grep -i tinker | sed 's/^/      /'

# Assert the SDIO settle delay reached the BUILT dtb, not merely the source. A patch that
# applied to a .dtsi the board's .dtb does not include would pass every check above and
# still ship a kernel with no wifi.
if command -v dtc >/dev/null 2>&1 || apt-get install -y -qq device-tree-compiler >/dev/null 2>&1; then
  if dtc -I dtb -O dts /out/staging/dtb/rk3288-tinker-s.dtb 2>/dev/null | grep -q 'post-power-on-delay-ms'; then
    echo "    [ok] sdio settle delay present in rk3288-tinker-s.dtb"
  else
    echo "!!! rk3288-tinker-s.dtb has NO post-power-on-delay-ms -- wifi will not come up" >&2
    exit 1
  fi
else
  echo "    [warn] dtc unavailable; could not verify the sdio settle delay in the dtb"
fi

# INSTALL_MOD_STRIP=1 is not optional here. This config has CONFIG_DEBUG_INFO=y with
# DWARF5, which Armbian's own packaging strips before shipping. Unstripped, the module
# tree is 1.1GB -- mac80211.ko alone is 29.3MB against 1.6MB stripped. That matters twice
# over: tib has 5.5GB free, and the tree has to cross a 1x1 SDIO wifi link that has been
# measured as low as 171 KB/s. An hour of transfer to deliver debug symbols nobody will
# read on an audio appliance.
make -j"$JOBS" INSTALL_MOD_PATH=/out/staging/modroot INSTALL_MOD_STRIP=1 modules_install >/dev/null
rm -f "/out/staging/modroot/lib/modules/$KREL/build" "/out/staging/modroot/lib/modules/$KREL/source"
tar -C /out/staging/modroot -czf "/out/modules-$KREL.tar.gz" lib/modules
echo "    modules: $(du -h "/out/modules-$KREL.tar.gz" | cut -f1)"

tar -C /out/staging -czf "/out/boot-$KREL.tar.gz" boot dtb
echo "    boot assets: $(du -h "/out/boot-$KREL.tar.gz" | cut -f1)"

echo "$KREL" > /out/kernelrelease
echo "==> done: $KREL"
REMOTE

KREL=$(cat "$OUT/kernelrelease" 2>/dev/null || echo "")
[[ -n $KREL ]] || die "build did not produce a kernel release string"

ok "built $KREL"
ls -lh "$OUT"/*.tar.gz 2>/dev/null | awk '{print "    "$5"  "$9}' >&2
log "next: scripts/deploy/tib-install-rt.sh --release $KREL"
