#!/usr/bin/env bash
# Build vip's pedal kernel: Ubuntu's linux-raspi 7.0.0-1017-raspi-realtime, rebuilt with
# CONFIG_NUMA_EMU=y and the patches in patches/vip/.
#
# WHY UBUNTU'S SOURCE AND NOT MAINLINE
# vip runs Ubuntu's RT kernel, the one every pedal number was measured on. The source is
# linux-raspi at the exact tag the installed package was built from (Ubuntu-raspi-<abi>.<upload>,
# read off the board). The rebuild differs from that tag by the fragment and by patches/vip/
# (today StarFive's non-idle DMA fix; README, "vip's kernel: the first candidate change").
#
# WHERE THE CONFIG COMES FROM
# FALLBACK_KERNEL's own /boot/config-*, pulled off the board — the stock configuration that
# demonstrably boots this exact hardware, and the one the spare slot keeps booting. The board must
# be running the stock kernel or a rebuild of it (this script's own releases). olddefconfig applies
# the config to the matching source, then the fragment flips NUMA emulation on. The script prints
# the whole config delta; it must be exactly CONFIG_NUMA_EMU and CONFIG_LOCALVERSION, or something
# unexpected drifted.
#
# WHY A SEPARATE RELEASE STRING
# Kernel slots are A/B but /lib/modules is NOT: the known-good slot is a copy of vmlinuz,
# initrd and dtbs only, and boots against /lib/modules/<release>. Installing a rebuild under
# the release name already in use would rewrite the modules underneath the fallback. The
# stock kernel's "-1017-raspi-realtime" came from Ubuntu's build machinery, not from
# CONFIG_LOCALVERSION (the shipped config has it empty), so this build sets the whole string
# and asserts `make kernelrelease` against it.
#
# WHAT IT BUILDS, AND FROM WHAT BASELINE
# The target release is FALLBACK_KERNEL plus a suffix, and the default suffix is PEDAL_KERNEL's own:
# running this with no arguments rebuilds exactly the release the card image pins (pedal.project
# devices/vip/image.lock). A new trial gets its own suffix instead (--localversion
# -numaemu3-dmaidle1-trimmed) and goes through `make vip-try` like any candidate before anything
# pins it. patches/vip/ must not be built as FALLBACK_KERNEL. vip-install-rt.sh refuses to
# install a release over the kernel the board is running.
#
# WHAT IT LEAVES BEHIND
# build/vip/: the two tarballs, kernelrelease, build-kind, trimmed-ok.txt, proc-modules, the dtb
# hash, and — so that every binary carries its commit — built-from (this repo's commit, -dirty if
# the tree was dirty) and sha256sums over what the card image verifies and pins before it installs
# them.
#
# WHY NUMA EMULATION AT ALL
# Fake NUMA needs CONFIG_NUMA_EMU; the boot argument alone is not enough (see
# config/vip-numa-emu.fragment). Without a boot argument the rebuild boots exactly like the
# stock kernel, so trying it is safe.
#
# WHY MODULES ARE TRIMMED
# The stock config builds 6,470 modules; vip loads 74. The trim (localmodconfig driven by the
# board's own /proc/modules, then the keep-list) cuts the build to the few hundred the pedal
# uses. Default ON; --no-trim reproduces the full module set. Trimmed builds get "-trimmed" in
# the release string, because two different module sets must not share a name.
#
# Usage: vip-ubuntu-rt.sh [--jobs N] [--localversion -suffix] [--config-only] [--no-trim]

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

load_device vip

JOBS=""
SUFFIX=""
SUFFIX_EXPLICIT=0
CONFIG_ONLY=0
TRIM=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --jobs)         JOBS="$2"; shift 2 ;;
    --localversion) SUFFIX="$2"; SUFFIX_EXPLICIT=1; shift 2 ;;
    --config-only)  CONFIG_ONLY=1; shift ;;
    --no-trim)      TRIM=0; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done

IMAGE="${IMAGE:-rtpi-build:latest}"
VOLUME="${VOLUME:-rtpi-src}"
CCACHE="${CCACHE:-rtpi-ccache}"
OUT="$RTPI_ROOT/build/vip"

docker info >/dev/null 2>&1 || die "docker is not available. Run: make colima-up"
docker image inspect "$IMAGE" >/dev/null 2>&1 || die "image $IMAGE missing. Run: make image"

[[ -n $JOBS ]] || JOBS=$(docker run --rm "$IMAGE" nproc)
mkdir -p "$OUT"

# The config comes from the STOCK kernel (FALLBACK_KERNEL), fetched fresh rather than kept in the
# repo. Deliberately not from whatever is running: a rebuild's config already carries the fragment
# and the trim, so a delta asserted against it would be empty and mean nothing. The stock package
# stays installed in the root for the life of the card — it is what the spare slot boots — so this
# is always there.
require_ssh
RUNNING=$(dev_ssh 'uname -r')
case "$RUNNING" in
  "$FALLBACK_KERNEL"|"$FALLBACK_KERNEL"-*) : ;;
  *) die "vip runs $RUNNING, not the recorded stock $FALLBACK_KERNEL or a rebuild of it — refusing to build against a surprise kernel" ;;
esac
dev_ssh "cat /boot/config-$FALLBACK_KERNEL" > "$OUT/base.config" \
  || die "could not fetch /boot/config-$FALLBACK_KERNEL: the stock kernel has to stay installed on $SSH_HOST"
ok "base config: $FALLBACK_KERNEL ($(wc -l < "$OUT/base.config") lines)"

# The loaded-module list, fetched from the board for the same reason as the config: it always
# matches what is actually running. /proc/modules rather than lsmod, because that is the format
# streamline_config.pl parses.
if (( TRIM )); then
  log "fetching the loaded module list from $SSH_HOST (the trim builds only these, plus the keep-list)"
  dev_ssh 'cat /proc/modules' > "$OUT/proc-modules" || die "could not fetch /proc/modules"
  ok "$(wc -l < "$OUT/proc-modules") modules loaded on the board"
fi

# The Ubuntu source tag for the installed package: version 7.0.0-1017.17 -> Ubuntu-raspi-7.0.0-1017.17.
# Read from the STOCK package, not from the running release: a suffixed rebuild has no package
# of its own, but it was built from this tag.
PKG_VER=$(dev_ssh "dpkg-query -W -f='\${Version}' linux-image-$FALLBACK_KERNEL")
[[ $PKG_VER =~ ^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+\.[0-9]+$ ]] || die "unexpected package version: $PKG_VER"
TAG="Ubuntu-raspi-$PKG_VER"
log "source tag for $FALLBACK_KERNEL ($PKG_VER): $TAG"
# The ^{} form peels an annotated tag to its commit: ls-remote prints two lines for one, and
# the tag object's own hash is not the commit to build (or to verify against).
TAG_COMMIT=$(git ls-remote "https://git.launchpad.net/~ubuntu-kernel/ubuntu/+source/linux-raspi/+git/resolute" "refs/tags/$TAG^{}" | awk '{print $1}')
[[ -n $TAG_COMMIT ]] || die "no commit found for tag $TAG"
ok "tag $TAG -> $TAG_COMMIT"

# The release is the STOCK string plus a suffix, and the default suffix is the pedal kernel's own:
# with no arguments this rebuilds exactly the release the card image pins. Two different module
# sets must not share a release name, which is why the trim is in the name and why a full build
# over a trimmed name is refused rather than silently done.
if (( ! SUFFIX_EXPLICIT )); then
  SUFFIX="${PEDAL_KERNEL#"$FALLBACK_KERNEL"}"
fi
if (( TRIM )) && [[ $SUFFIX != *-trimmed* ]]; then
  SUFFIX="${SUFFIX}-trimmed"
elif (( ! TRIM )) && [[ $SUFFIX == *-trimmed* ]]; then
  die "--no-trim would rebuild the trimmed name $FALLBACK_KERNEL$SUFFIX: pass --localversion"
fi
KREL_EXPECT="${FALLBACK_KERNEL}${SUFFIX}"
printf '%s\n' "$([[ $TRIM == 1 ]] && echo trimmed || echo full)" > "$OUT/build-kind"
log "target release: $KREL_EXPECT (building with -j$JOBS, modules: $([[ $TRIM == 1 ]] && echo trimmed || echo full))"

# patches/vip/ must not be built under the stock fallback's release: that package's modules
# are what a stock slot boots. A trial of a further change still takes its own --localversion.
# vip-install-rt.sh refuses to install over the kernel the board is running.
if compgen -G "$RTPI_ROOT/patches/vip/*.patch" >/dev/null; then
  [[ $KREL_EXPECT != "$FALLBACK_KERNEL" ]] || die \
    "patches/vip must not be built as the stock fallback $FALLBACK_KERNEL"
  log "patches: $(cd "$RTPI_ROOT/patches/vip" && ls -1 *.patch | tr '\n' ' ')"
fi

docker run --rm -i \
  -v "$VOLUME":/src -v "$CCACHE":/ccache \
  -v "$RTPI_ROOT/config":/config:ro \
  -v "$RTPI_ROOT/patches/vip":/patches:ro \
  -v "$OUT":/out \
  -e TAG="$TAG" -e TAG_COMMIT="$TAG_COMMIT" -e SUFFIX="$SUFFIX" -e KREL_EXPECT="$KREL_EXPECT" \
  -e JOBS="$JOBS" -e CONFIG_ONLY="$CONFIG_ONLY" -e TRIM="$TRIM" \
  "$IMAGE" bash -euo pipefail -s <<'REMOTE'
cd /src

TREE="linux-raspi-${TAG}"
URL="https://git.launchpad.net/~ubuntu-kernel/ubuntu/+source/linux-raspi/+git/resolute"

# ---------------------------------------------------------------- source
# The tree lives in a Docker volume and survives between runs. A tree at the wrong commit is
# fatal: building against a slightly different source would look fine and quietly ship
# something else. A shallow tag clone; retried once, because launchpad is not cdn.kernel.org.
# A killed clone can leave a half-made tree behind, so the guard is on the commit, not on the
# directory existing.
if [[ $(git -C "$TREE" rev-parse HEAD 2>/dev/null) != "$TAG_COMMIT" ]]; then
  echo "==> cloning $TAG (depth 1, this is the slow part)"
  rm -rf "$TREE"
  git clone --quiet --depth 1 --branch "$TAG" "$URL" "$TREE" \
    || { echo "    clone failed, retrying once"; rm -rf "$TREE"; \
         git clone --quiet --depth 1 --branch "$TAG" "$URL" "$TREE"; }
fi
cd "$TREE"
HEAD=$(git rev-parse HEAD)
[[ $HEAD == "$TAG_COMMIT" ]] || { echo "!!! $TREE is at $HEAD, expected $TAG_COMMIT ($TAG)" >&2; exit 1; }
echo "==> source: $TAG ($HEAD)"

# ---------------------------------------------------------------- patches
# Out-of-tree fixes the shipped tag does not have. The tree lives in the volume and keeps its
# object files between runs, so the patched sources are restored to the tag first: a second
# build applies the patches as they are now, instead of stacking them on last run's copy.
shopt -s nullglob
patches=(/patches/*.patch)
shopt -u nullglob
if (( ${#patches[@]} )); then
  mapfile -t pfiles < <(git apply --numstat "${patches[@]}" | awk '{print $3}' | sort -u)
  for f in "${pfiles[@]}"; do
    if git cat-file -e "HEAD:$f" 2>/dev/null; then
      git checkout -f HEAD -- "$f"
    fi
  done
  for p in "${patches[@]}"; do
    echo "==> applying $(basename "$p")"
    git apply --verbose "$p"
  done
else
  echo "==> no patches in /patches"
fi

export ARCH=arm64

# Ubuntu ships this tree as 7.0.0-1017 even though the Makefile carries upstream's 7.0.12:
# their packaging overrides the version — their own CONFIG_VERSION_SIGNATURE records both halves
# ("Ubuntu 7.0.0-1017.17-raspi-realtime 7.0.12"). Command-line make variables replicate that
# without patching the tree (the Makefile's own assignments beat environment variables, which is
# why these are not exports), and they ride MAKEFLAGS into every sub-make. LOCALVERSION=""
# (set, but empty, exported) stops scripts/setlocalversion appending its "+" for the shallow
# clone, which would otherwise ride along on the release string. MKVER must prefix ANY make call
# that computes or uses the release, or include/config/kernel.release is regenerated with the
# wrong version.
export LOCALVERSION=""
MKVER="VERSION=7 PATCHLEVEL=0 SUBLEVEL=0"

# ---------------------------------------------------------------- config
echo "==> applying the board's config to $TAG"
cp /out/base.config .config
make $MKVER olddefconfig >/dev/null

echo "==> merging the NUMA emulation fragment"
./scripts/kconfig/merge_config.sh -m .config /config/vip-numa-emu.fragment | tail -5
make $MKVER olddefconfig >/dev/null

# The stock "-1017-raspi-realtime" suffix was Ubuntu's build machinery, not CONFIG_LOCALVERSION
# (the shipped config has it empty). Set the whole string on the config, so it is recorded in
# built.config and in every artifact name; never as a make variable, or it can double up.
echo "==> local version: -1017-raspi-realtime${SUFFIX}"
./scripts/config --set-str CONFIG_LOCALVERSION "-1017-raspi-realtime${SUFFIX}"
# The version signature keeps the package half accurate too: the shipped
# "Ubuntu 7.0.0-1017.17-raspi-realtime 7.0.12" becomes
# "Ubuntu 7.0.0-1017.17-raspi-realtime-numaemu1 7.0.12".
SIG=$(sed -n 's/^CONFIG_VERSION_SIGNATURE=//p' /out/base.config)
NEWSIG="${SIG% *}${SUFFIX} ${SIG##* }"
./scripts/config --set-str CONFIG_VERSION_SIGNATURE "$NEWSIG"

# ---------------------------------------------------------------- module trim
# Order matters: the fragments first (they say what must be built in), then the trim (the only
# step that removes anything), then the keep-list (which must run after the trim or it would
# be trimmed away itself). localmodconfig leaves built-ins alone and turns every =m that the
# board does not load into n; the keep-list restores the deliberate exceptions.
if [[ ${TRIM:-1} == 1 ]]; then
  [[ -s /out/proc-modules ]] || { echo "!!! trim requested but /out/proc-modules is empty" >&2; exit 1; }
  mods_before=$(grep -c '=m$' .config)
  echo "==> trimming modules to the $(wc -l < /out/proc-modules) this board loads (from $mods_before)"
  # </dev/null because localmodconfig ends in a config frontend that would prompt on stdin --
  # and stdin here is the rest of this script.
  make $MKVER LSMOD=/out/proc-modules localmodconfig >/dev/null < /dev/null
  ./scripts/kconfig/merge_config.sh -m .config /config/vip-keep.fragment | tail -3
  echo "    $mods_before -> $(grep -c '=m$' .config) modules (=m)"
fi

make $MKVER olddefconfig >/dev/null
make $MKVER syncconfig >/dev/null

# ---------------------------------------------------------------- verify the config
# merge_config.sh warns about symbols it could not apply but still exits 0, and olddefconfig
# will happily drop a symbol whose dependencies are unmet. Assert, do not assume.
echo "==> verifying the symbols that matter actually landed"
fail=0
want_y() {
  if grep -q "^$1=y" .config; then echo "    [y]  $1"; else echo "    [!!] $1 is NOT set to y"; fail=1; fi
}
want_y CONFIG_NUMA_EMU
want_y CONFIG_NUMA
want_y CONFIG_NUMA_MEMBLKS
want_y CONFIG_PREEMPT_RT
[[ $(grep -E '^CONFIG_HZ=' .config | cut -d= -f2) == 1000 ]] || { echo "    [!!] HZ is not 1000"; fail=1; }
KREL=$(make $MKVER -s kernelrelease)
echo "    kernelrelease = $KREL"
[[ $KREL == "$KREL_EXPECT" ]] || { echo "    [!!] expected $KREL_EXPECT"; fail=1; }

if [[ ${TRIM:-1} == 1 ]]; then
  # The keep-list is the deliberate exception to the trim, and it is exactly the set that the
  # coverage check after the build CANNOT see: it exists for hardware that is not attached
  # today. Check it here, symbol by symbol.
  keepfail=0
  while read -r line; do
    grep -q "^${line}$" .config || { echo "    [!!] keep-list symbol did not survive: $line"; keepfail=1; }
  done < <(grep -E '^CONFIG_' /config/vip-keep.fragment)
  if (( keepfail == 0 )); then echo "    [ok] all $(grep -cE '^CONFIG_' /config/vip-keep.fragment) keep-list symbols survived"
  else fail=1; fi

  # Sanity on the trim itself: the bounds catch a trim that did nothing (still ~6470) and one
  # that removed too much, without pinning an exact number that every kernel bump would move.
  modcount=$(grep -c '=m$' .config)
  echo "    modules to build: $modcount"
  (( modcount <= 600 )) || { echo "    [!!] $modcount =m left; the trim did not do its job"; fail=1; }
  (( modcount >= 40 ))  || { echo "    [!!] only $modcount =m; the trim removed too much"; fail=1; }
fi

(( fail == 0 )) || { echo "!!! config verification FAILED — refusing to build" >&2; exit 1; }
echo "==> config verified"

# The whole delta against the shipped config. A full build must show exactly the NUMA_EMU flip,
# the localversion string and the version signature; anything else means the shipped config and
# this source tag do not agree. A trimmed build additionally shows the =m -> n removals.
echo "==> config delta vs the shipped config (full: CONFIG_NUMA_EMU, CONFIG_LOCALVERSION and CONFIG_VERSION_SIGNATURE only; trimmed adds the module removals):"
diff <(grep -vE '^#|^$' /out/base.config | sort) <(grep -vE '^#|^$' .config | sort) || true

cp .config /out/built.config

if [[ ${CONFIG_ONLY:-0} == 1 ]]; then
  echo "==> config-only run: stopping before the build"
  exit 0
fi

# ---------------------------------------------------------------- build
# Ubuntu's config points CONFIG_SYSTEM_TRUSTED_KEYS and CONFIG_SYSTEM_REVOCATION_KEYS at
# debian/canonical-{,revoked-}certs.pem. The git tree ships the component certs, not the
# concatenations: Ubuntu's packaging makes them (debian/rules, "debian/canonical-certs.pem:").
# Make them with the same recipe, so the built kernel's keyrings match the shipped kernel's
# and the config needs no change.
if [[ ! -f debian/canonical-certs.pem ]]; then
  echo "==> making the canonical cert bundles (debian/rules' recipe)"
  cat debian/certs/*.pem > debian/canonical-certs.pem
  cat debian/revoked-certs/*.pem > debian/canonical-revoked-certs.pem
fi

echo "==> building Image.gz, modules and dtbs (-j$JOBS)"
make $MKVER -j"$JOBS" Image.gz modules dtbs

KREL=$(make $MKVER -s kernelrelease)
[[ $KREL == "$KREL_EXPECT" ]] || { echo "!!! built release $KREL, expected $KREL_EXPECT" >&2; exit 1; }
echo "==> built $KREL"

# ---------------------------------------------------------------- collect
# Staging lives on the CONTAINER's filesystem, not on /out: the /out bind mount crosses
# colima's virtiofs, and a parallel (-j) modules_install into it silently loses files there
# (found the hard way: the same four netfilter .ko went missing on every install into /out
# while the identical install into the container fs was complete). Only the finished tarballs
# cross the mount, one sequential stream each.
rm -rf /staging && mkdir -p /staging/boot /staging/dtb
cp arch/arm64/boot/Image.gz /staging/boot/vmlinuz
cp .config              "/staging/boot/config-$KREL"
cp System.map           "/staging/boot/System.map-$KREL"

# Only the BCM2712 trees this board family uses; the flat layout matches what vip-boot's
# copy_kernel expects for a slot.
find arch/arm64/boot/dts/broadcom -name 'bcm2712*.dtb' -exec cp {} /staging/dtb/ \;
sha256sum arch/arm64/boot/dts/broadcom/bcm2712-rpi-5-b.dtb > /out/bcm2712-rpi-5-b.dtb.sha256
echo "    dtbs: $(ls /staging/dtb/*.dtb | wc -l)"

# The shipped config builds DWARF5 + BTF, so the modules are stripped at install time (the
# same way the shipped linux-modules package ships them), and the strip is verified below.
make $MKVER -j"$JOBS" INSTALL_MOD_PATH=/staging/modroot INSTALL_MOD_STRIP=1 modules_install >/dev/null
rm -f "/staging/modroot/lib/modules/$KREL/build" "/staging/modroot/lib/modules/$KREL/source"

# ---------------------------------------------------------------- module coverage (trim only)
# Every module the board loads today must be either built in or present in what we just built.
# localmodconfig works from the same list, so this should hold by construction -- which is
# exactly why it is worth asserting: it catches a module that depends on something the trim
# removed, and it catches the trim being pointed at the wrong list. The comparison is against
# the built .ko files and modules.builtin rather than against .config, because a module name
# does not always match its CONFIG symbol.
if [[ ${TRIM:-1} == 1 && -s /out/proc-modules ]]; then
  # Modules the board loads that this build deliberately does not have. Every entry is a claim
  # with a reason attached; the alternative -- tolerating any missing module -- is how a
  # trimmed kernel loses the wifi and nobody finds out until the reboot.
  #
  # ac97_bus, snd_compress: loaded on the board only as dependency edges out of snd-soc-core.
  # The selectors behind those edges (SND_SOC_AC97_BUS, SND_SOC_COMPRESS) belong to codec
  # drivers the trim removes, so the trimmed snd-soc-core has no ac97/compress references
  # (checked: zero undefined symbols) and these two would never load. Kept as recorded
  # removals rather than forced back in (they are promptless symbols only a select can set;
  # forcing them would drag the unused codec set back).
  TRIMMED_OK="ac97_bus snd_compress"
  built_ko=$(find /staging/modroot -name '*.ko' -printf '%f\n' | sed 's/\.ko$//' | tr '-' '_' | sort -u)
  builtin=$(sed 's|.*/||; s/\.ko$//' /staging/modroot/lib/modules/$KREL/modules.builtin 2>/dev/null | tr '-' '_' | sort -u)
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
  echo "    [ok] all $(wc -l < /out/proc-modules) modules the board loads are present or built in"
  # The deploy script's own gate needs the same list of recorded removals, so it ships beside
  # the kernel: the build is the one place this judgement is made, and a copied list would
  # drift.
  if [[ -n $TRIMMED_OK ]]; then printf '%s\n' $TRIMMED_OK > /out/trimmed-ok.txt; else : > /out/trimmed-ok.txt; fi
fi

# The strip actually happened, on the files about to be shipped, not on the variables that
# were supposed to cause it.
if find /staging/modroot -name '*.ko' -print0 | xargs -0 -r readelf -S 2>/dev/null | grep -q '\.debug_info'; then
  echo "!!! some modules still carry .debug_info -- the strip did not happen" >&2
  exit 1
fi
echo "    [ok] no debug info in $(find /staging/modroot -name '*.ko' | wc -l) modules"

tar -C /staging/modroot -czf "/out/modules-$KREL.tar.gz" lib/modules
echo "    modules: $(du -h "/out/modules-$KREL.tar.gz" | cut -f1) compressed"
tar -C /staging -czf "/out/boot-$KREL.tar.gz" boot dtb
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
[[ $KREL == "$KREL_EXPECT" ]] || die "build produced $KREL, expected $KREL_EXPECT"

# Every binary carries its commit. The artefacts are what the card image pins by hash
# (pedal.project devices/vip/image.lock), and a kernel is not bit-reproducible by construction —
# its config baseline is the board's, its trim is driven by the board's /proc/modules — so the
# commit and the hashes are the record that makes the artefact defensible rather than magic.
COMMIT=$(git -C "$RTPI_ROOT" rev-parse HEAD)
[[ -z $(git -C "$RTPI_ROOT" status --porcelain) ]] || COMMIT="$COMMIT-dirty"
printf '%s\n' "$COMMIT" > "$OUT/built-from"
( cd "$OUT" && shasum -a 256 "boot-$KREL.tar.gz" "modules-$KREL.tar.gz" bcm2712-rpi-5-b.dtb.sha256 > sha256sums )

ok "built $KREL from $COMMIT"
ls -lh "$OUT"/*.tar.gz 2>/dev/null | awk '{print "    "$5"  "$9}' >&2
log "next: scripts/deploy/vip-install-rt.sh (installs beside the stock $FALLBACK_KERNEL), then make vip-try"
