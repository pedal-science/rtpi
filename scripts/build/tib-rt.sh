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
# WHY THE MODULE SET IS TRIMMED
# That config builds 1486 modules. The board loads 61. localmodconfig, driven by
# /proc/modules pulled off the board at build time, is what removes the other 1400 -- with
# config/tib-keep.fragment for the handful that must stay loadable when the hardware is not
# attached on the build day, wifi above all, because wlan0 is tib's only network path.
# Trimming is ON by default; --no-trim reproduces the vendor's module set.
#
# WHY THERE IS NO DEBUG INFO LEFT TO STRIP
# Armbian's config builds DWARF5. INSTALL_MOD_STRIP=1 threw it away at install time, but
# only after paying to compile it: a 1.1GB module tree, mac80211.ko at 29.3MB against
# 1.6MB stripped. audio-rt-common.fragment now sets CONFIG_DEBUG_INFO_NONE=y so it is never
# generated. The strip is still passed and its result still checked below, because "we
# stripped it" is not a claim that should rest on one variable being spelled correctly.
#
# WHY --localversion EXISTS
# Slots are A/B but /lib/modules is NOT: the frozen known-good slot is a copy of
# zImage/uInitrd/dtb only, and it boots against /lib/modules/<release>. Installing a build
# under a release name that is already in use therefore rewrites the modules underneath the
# fallback, and a trimmed tree would leave the fallback without wifi or audio. A distinct
# localversion gives the new kernel its own module tree and leaves the fallback intact.
#
# Usage: tib-rt.sh [--version 7.2.6] [--jobs N] [--localversion -tib1]
#                   [--no-trim] [--config-only] [--shell]

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

load_device tib

KVER="${KERNEL_MIN_VERSION:-7.2.6}"
JOBS=""
DROP_TO_SHELL=0
LOCALVERSION=""
TRIM=1
CONFIG_ONLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)      KVER="$2"; shift 2 ;;
    --jobs)         JOBS="$2"; shift 2 ;;
    --localversion) LOCALVERSION="$2"; shift 2 ;;
    --no-trim)      TRIM=0; shift ;;
    --config-only)  CONFIG_ONLY=1; shift ;;
    --shell)        DROP_TO_SHELL=1; shift ;;
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

# The loaded-module list, same reasoning as the config: take it from the board rather than
# keeping a copy in the repo, so it always matches what is actually running. /proc/modules
# rather than lsmod, because that is the format streamline_config.pl parses.
if (( TRIM )); then
  log "fetching the loaded module list from $SSH_HOST"
  dev_ssh 'cat /proc/modules' > "$OUT/proc-modules" || die "could not fetch /proc/modules"
  ok "$(wc -l < "$OUT/proc-modules") modules loaded on the board"
fi

log "building linux-$KVER for armhf with -j$JOBS"

docker run --rm -i \
  -v "$VOLUME":/src -v "$CCACHE":/ccache \
  -v "$RTPI_ROOT/config":/config:ro \
  -v "$RTPI_ROOT/patches":/patches:ro \
  -v "$OUT":/out \
  -e KVER="$KVER" -e JOBS="$JOBS" -e DROP_TO_SHELL="$DROP_TO_SHELL" \
  -e TRIM="$TRIM" -e RTPI_LOCALVERSION="$LOCALVERSION" -e CONFIG_ONLY="$CONFIG_ONLY" \
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

# ---------------------------------------------------------------- module trim
# Order matters: fragments, then the trim, then the keep-list. The trim is the only step
# that removes anything, so it has to run after the fragments have said what must be built
# in, and the keep-list has to run after the trim or it would be trimmed away itself.
if [[ ${TRIM:-1} == 1 ]]; then
  [[ -s /out/proc-modules ]] || { echo "!!! trim requested but /out/proc-modules is empty" >&2; exit 1; }
  mods_before=$(grep -c '=m$' .config)
  echo "==> trimming modules to the $(wc -l < /out/proc-modules) this board loads (from $mods_before)"
  # LSMOD is the module list. Everything =m that is neither in it nor needed as a
  # dependency of something in it goes back to n. Built-in symbols are not touched.
  # </dev/null because the target ends in `conf --oldconfig`, which prompts on stdin --
  # and stdin here is the rest of this script.
  make LSMOD=/out/proc-modules localmodconfig >/dev/null < /dev/null
  ./scripts/kconfig/merge_config.sh -m .config /config/tib-keep.fragment | tail -5
  make olddefconfig >/dev/null
  echo "    $mods_before -> $(grep -c '=m$' .config) modules"
fi

# A localversion is set on the CONFIG rather than passed as a make variable, so that it is
# recorded in built.config and in every artifact name derived from kernelrelease below.
# Deliberately not passed in the environment as LOCALVERSION: make and setlocalversion both
# read that variable, and a doubled suffix is exactly the kind of thing nobody notices.
if [[ -n ${RTPI_LOCALVERSION:-} ]]; then
  echo "==> local version: $RTPI_LOCALVERSION"
  ./scripts/config --set-str CONFIG_LOCALVERSION "$RTPI_LOCALVERSION"
  make olddefconfig >/dev/null
fi

# include/config/auto.conf is regenerated by syncconfig, NOT by olddefconfig, and everything
# that asks make for the release string reads it from there. Without this, kernelrelease
# comes back without the localversion until the first build target happens to resync it --
# which is how you ship artifacts named after the wrong release.
make syncconfig >/dev/null

# ---------------------------------------------------------------- verify the config
# merge_config.sh warns about symbols it could not apply but still exits 0, and
# olddefconfig will happily drop a symbol whose dependencies are unmet. Neither failure is
# visible until you boot the result and find it is not realtime. So assert, do not assume.
echo "==> verifying the symbols that matter actually landed"
fail=0
want_y() {
  if grep -q "^$1=y" .config; then echo "    [y]  $1"; else echo "    [!!] $1 is NOT set to y"; fail=1; fi
}
want_m() {
  if grep -q "^$1=m" .config; then echo "    [m]  $1"
  elif grep -q "^$1=y" .config; then echo "    [Y]  $1 (built in, acceptable)"
  else echo "    [!!] $1 is neither =m nor =y"; fail=1; fi
}
want_unset() {
  if grep -q "^# $1 is not set" .config; then echo "    [n]  $1"
  elif grep -q "^$1=" .config; then echo "    [!!] $1 is SET but must not be: $(grep "^$1=" .config)"; fail=1
  else echo "    [n]  $1 (absent)"; fi
}
want_y CONFIG_PREEMPT_RT
want_y CONFIG_HIGH_RES_TIMERS
# NO_HZ_IDLE and NO_HZ_FULL are members of the "Timer tick handling" choice, so exactly one
# of them is set. Asserting both -- which the fragment did until 2026-09-19 -- is a
# contradiction Kconfig resolves by silently dropping one.
want_y CONFIG_NO_HZ_FULL
want_unset CONFIG_NO_HZ_IDLE
want_y CONFIG_OSNOISE_TRACER
want_y CONFIG_TIMERLAT_TRACER
want_unset CONFIG_RT_GROUP_SCHED
want_unset CONFIG_DEBUG_PREEMPT
want_unset CONFIG_HIGHPTE

# No debug info is generated. CONFIG_DEBUG_INFO itself is only ever selected by the DWARF
# choices, so with NONE it should be absent from the file entirely, not "# ... is not set".
want_y CONFIG_DEBUG_INFO_NONE
want_unset CONFIG_DEBUG_INFO
want_unset CONFIG_DEBUG_INFO_BTF

# Sound is BUILT IN, and this is the assertion that would have caught the 2026-09-15 build:
# the fragment asked for SND_USB_AUDIO=y, sound/Kconfig nests SND inside "if SOUND", the
# base config has SOUND=m, and olddefconfig quietly downgraded the whole family to m. The
# merge reported success and the old check here accepted =m as "enabled".
want_y CONFIG_SOUND
want_y CONFIG_SND
want_y CONFIG_SND_USB_AUDIO
want_y CONFIG_SND_HRTIMER

echo "    HZ = $(grep -E '^CONFIG_HZ=' .config | cut -d= -f2)"
[[ $(grep -E '^CONFIG_HZ=' .config | cut -d= -f2) == 1000 ]] || { echo "    [!!] HZ is not 1000"; fail=1; }

# The board's own drivers must survive both the 6.18 -> 7.2 migration and the module trim.
want_m CONFIG_RTW88_8723DS
want_y CONFIG_DWMAC_ROCKCHIP
want_y CONFIG_MMC_DW_ROCKCHIP

# The keep-list is the deliberate exception to the trim, and it is precisely the set that
# the coverage check after the build CANNOT see -- it exists for hardware that is not
# attached today. So check it here, symbol by symbol.
if [[ ${TRIM:-1} == 1 ]]; then
  keepfail=0
  while read -r line; do
    grep -q "^${line}$" .config || { echo "    [!!] keep-list symbol did not survive: $line"; keepfail=1; }
  done < <(grep -E '^CONFIG_' /config/tib-keep.fragment)
  if (( keepfail == 0 )); then echo "    [ok] all $(grep -cE '^CONFIG_' /config/tib-keep.fragment) keep-list symbols survived"
  else fail=1; fi
fi

# Sanity on the trim itself. The upper bound is the point: without it, a trim that silently
# did nothing would look exactly like a trim that worked.
modcount=$(grep -c '=m$' .config)
echo "    modules to build: $modcount"
if (( TRIM )); then
  (( modcount <= 400 )) || { echo "    [!!] $modcount modules left; the trim did not do its job"; fail=1; }
  (( modcount >= 20 ))  || { echo "    [!!] only $modcount modules; the trim removed too much"; fail=1; }
fi

if (( fail )); then
  echo "!!! config verification FAILED — refusing to build" >&2
  exit 1
fi
echo "==> config verified"

cp .config /out/built.config

if [[ ${CONFIG_ONLY:-0} == 1 ]]; then
  echo "==> config-only run: stopping before the build"
  echo "    LOCALVERSION  = $(grep -E '^CONFIG_LOCALVERSION=' .config | cut -d= -f2)"
  echo "    kernelrelease = $(make -s kernelrelease)"
  exit 0
fi

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
#
# The test greps the flattened blob for the property NAME, which is in the dtb's string
# table only if some node actually carries the property. That needs no device-tree-compiler:
# the earlier version fell back to a warning when dtc was missing, and it did exactly that on
# the 2026-09-19 build, so the single assertion guarding the wifi was skipped on the run that
# needed it. A check that degrades to a warning is not a check.
if grep -a -q 'post-power-on-delay-ms' /out/staging/dtb/rk3288-tinker-s.dtb; then
  echo "    [ok] sdio settle delay present in rk3288-tinker-s.dtb"
else
  echo "!!! rk3288-tinker-s.dtb has NO post-power-on-delay-ms -- wifi will not come up" >&2
  exit 1
fi

# INSTALL_MOD_STRIP=1 strips the modules at install time. It is now a belt rather than the
# braces: audio-rt-common.fragment sets CONFIG_DEBUG_INFO_NONE=y, so there is no DWARF to
# strip in the first place. It stays because a base config that has debug info re-enabled
# for some reason would otherwise ship a 1.1GB module tree (mac80211.ko at 29.3MB against
# 1.6MB) across a 1x1 SDIO wifi link measured as low as 171 KB/s.
make -j"$JOBS" INSTALL_MOD_PATH=/out/staging/modroot INSTALL_MOD_STRIP=1 modules_install >/dev/null
rm -f "/out/staging/modroot/lib/modules/$KREL/build" "/out/staging/modroot/lib/modules/$KREL/source"

# Verify the strip and the debug-info setting actually did what they claim, on the files
# that are about to be shipped, rather than on the variables that were supposed to cause it.
biggest=$(find /out/staging/modroot -name '*.ko' -printf '%s %p\n' | sort -rn | head -1 | cut -d' ' -f2-)
if readelf -S "$biggest" 2>/dev/null | grep -q '\.debug_info'; then
  echo "!!! $(basename "$biggest") still carries .debug_info -- the strip did not happen" >&2
  exit 1
fi
if find /out/staging/modroot -name '*.ko' -print0 | xargs -0 -r readelf -S 2>/dev/null | grep -q '\.debug_info'; then
  echo "!!! some modules still carry .debug_info -- the strip did not happen" >&2
  exit 1
fi
echo "    [ok] no debug info in $(find /out/staging/modroot -name '*.ko' | wc -l) modules (largest: $(basename "$biggest"), $(( $(stat -c %s "$biggest") / 1024 ))KB)"

tar -C /out/staging/modroot -czf "/out/modules-$KREL.tar.gz" lib/modules
echo "    modules: $(find /out/staging/modroot -name '*.ko' | wc -l) files, $(du -h "/out/modules-$KREL.tar.gz" | cut -f1) compressed"

# Every module the board loads today must be either built in or present in what we just
# built. localmodconfig works from the same list, so this should hold by construction --
# which is exactly why it is worth asserting: it catches a module that depends on something
# the trim removed, and it catches the trim being pointed at the wrong list.
#
# The comparison is against the built .ko files rather than against .config, because a
# module name does not always match its CONFIG symbol (aes-arm-bs.ko <- CONFIG_CRYPTO_AES_ARM_BS)
# and because a module that became built in has no .ko at all.
if [[ ${TRIM:-1} == 1 && -s /out/proc-modules ]]; then
  # Modules the board loads that this build deliberately does not have. Every entry is a
  # claim with a reason attached: the alternative -- tolerating any missing module -- is how
  # a trimmed kernel loses the wifi and nobody finds out until the reboot.
  #
  #   snd_seq_device  existed only because the vendor config had SND_SEQUENCER=m, and
  #                   sound/core/Kconfig pulls it in with "select SND_SEQ_DEVICE if
  #                   SND_SEQUENCER != n". The board never loads the sequencer (its lsmod has
  #                   no snd_seq module), so the trim removed the cause and the object went
  #                   with it. Not a functional loss: the built vmlinux contains no
  #                   seq_device symbols at all, and USB MIDI still works through
  #                   snd-usbmidi-lib, which modules.builtin lists as built in. What is gone
  #                   is /dev/snd/seq, i.e. routing MIDI between applications, which a
  #                   self-contained effects box does not do.
  TRIMMED_OK="snd_seq_device"
  built_ko=$(find /out/staging/modroot -name '*.ko' -printf '%f\n' | sed 's/\.ko$//' | tr '-' '_' | sort -u)
  # Built-in modules: ask the kernel rather than the config. modules.builtin lists them by
  # .ko path, which is the same namespace /proc/modules uses, so nothing has to guess at the
  # relationship between a module name and its CONFIG symbol. The first version of this check
  # guessed, and reported soundcore (=CONFIG_SOUND) and snd_usbmidi_lib (=CONFIG_SND_USB_AUDIO)
  # as missing when both were built in.
  if [[ -f modules.builtin ]]; then
    builtin=$(sed 's|.*/||; s/\.ko$//' modules.builtin | tr '-' '_' | sort -u)
    builtin_src="modules.builtin"
  else
    builtin=$(grep '=y$' .config | cut -d= -f1 | sed 's/^CONFIG_//' | tr 'A-Z' 'a-z')
    builtin_src=".config (modules.builtin missing, so this mapping is approximate)"
  fi
  missing=0
  while read -r mod _; do
    grep -qx "$mod" <<<"$built_ko" && continue
    grep -qx "$mod" <<<"$builtin" && continue
    if [[ " $TRIMMED_OK " == *" $mod "* ]]; then
      echo "    [--] $mod is deliberately absent (listed in TRIMMED_OK)"
      continue
    fi
    echo "    [!!] $mod is loaded on the board but is neither built in nor in the new modules" >&2
    missing=1
  done < /out/proc-modules
  (( missing == 0 )) || { echo "!!! module coverage FAILED -- this kernel would lose a driver the board uses" >&2; exit 1; }
  echo "    [ok] all $(wc -l < /out/proc-modules) modules the board loads are present, built in per $builtin_src, or a recorded removal"
fi

tar -C /out/staging -czf "/out/boot-$KREL.tar.gz" boot dtb
echo "    boot assets: $(du -h "/out/boot-$KREL.tar.gz" | cut -f1)"

echo "$KREL" > /out/kernelrelease
echo "==> done: $KREL"
REMOTE

KREL=$(cat "$OUT/kernelrelease" 2>/dev/null || echo "")
if (( CONFIG_ONLY )); then
  ok "config-only run finished; no kernel was built"
  ls -l "$OUT/built.config" >&2
  exit 0
fi
[[ -n $KREL ]] || die "build did not produce a kernel release string"

ok "built $KREL"
ls -lh "$OUT"/*.tar.gz 2>/dev/null | awk '{print "    "$5"  "$9}' >&2
log "next: scripts/deploy/tib-install-rt.sh --release $KREL"
