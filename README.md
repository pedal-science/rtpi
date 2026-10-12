# rtpi

Reproducible PREEMPT_RT kernels for low-latency audio on two ARM boards, with automatic
rollback so a bad kernel can never cost remote access.

| host | board | arch | OS | stock kernel |
|---|---|---|---|---|
| `piv` | Raspberry Pi 500 (BCM2712) | arm64 | Ubuntu 26.04 resolute | `7.0.0-1017-raspi` |
| `vip` | Raspberry Pi 5 (BCM2712) | arm64 | Ubuntu 26.04 resolute | `7.0.0-1017-raspi-realtime` |

Audio hardware: an SSL 2+ Mk II on piv; vip's audio is the pedal's own WM8960 codec.

---

## → If a board will not come back, read [RECOVERY](#recovery) first.

---

## Quick start

```bash
make help                 # every target, grouped
make backup-piv           # ALWAYS do this first; pulls a copy to this Mac
make hold-piv             # stop unattended-upgrades fighting us (see below)
make harden-piv           # close the two lockout gaps
make preflight-piv        # verify it is safe to proceed
make rehearse-piv-failure # PROVE rollback works before trusting it
make piv-apt-rt           # install Ubuntu's Pi-specific RT kernel
```

## How the safety model works

### piv — the Pi bootloader's one-shot `tryboot`

Ubuntu ships `piboot-try`, which implements A/B kernel testing on top of a firmware flag.
From the Raspberry Pi documentation (`bootflow-eeprom.adoc`):

> *"The bootloader/firmware provide a one-shot flag which, if set, is cleared but causes
> `tryboot.txt` to be loaded instead of `config.txt`. … Since the flag is cleared
> **before starting the firmware**, a crash or reset will cause the original `config.txt`
> file to be loaded on the next reboot."*

The cycle:

1. A kernel install stages assets into `/boot/firmware/new/` with `state=unknown`.
2. `piboot-try-reboot` (at `sysinit.target`) writes `trying` and reboots into tryboot.
3. `[tryboot] os_prefix=new/` in `config.txt` makes the firmware boot `new/`.
4. Reaching `multi-user.target` runs `/etc/flash-kernel/piboot-validate`. Exit 0 promotes
   `new/` → `current/` → `old/`.
5. Anything else — hang, panic, watchdog reset, power cut — boots `current/` again, and
   the next boot marks `new/state=bad` so it never retries in a loop.

`tryboot_a_b=1` in `autoboot.txt` means *config.txt is loaded instead of tryboot.txt*, so
no `tryboot.txt` is needed; the `[tryboot]` section **is** the supported mechanism, and
`tryboot_a_b=1` is required for it.

### vip — two slots, and a pedal kernel that is not a package

vip is built from an image, not upgraded with apt (pedal.project, `docs/vip-image.md`), so
`flash-kernel` and `piboot-try` do not apply: `vip-boot` owns the same firmware-level job, with
two fixed slots in the pedal's boot partition instead of `current`/`new`/`old` directories.

The pedal's kernel is Ubuntu's `linux-raspi` **rebuilt** — NUMA emulation on, modules trimmed to
what the board loads — which exists in no archive and so cannot come from a package:

```
make vip-rt          # scripts/build/vip-ubuntu-rt.sh: build/vip/{boot,modules}-<rel>.tar.gz,
                     #   kernelrelease, build-kind, trimmed-ok.txt, proc-modules, built-from, sha256sums
make vip-install-rt  # scripts/deploy/vip-install-rt.sh: install it into the RUNNING pedal root,
                     #   beside the stock kernel, with a guarded initramfs (vip-install-kernel does
                     #   the work; pedal.project's image build runs the same script in its chroot)
make vip-try         # vip-boot try-kernel: fill the SPARE slot, reboot once, watch validation
                     #   promote it or fall back
```

The stock kernel stays installed — it is the baseline the rebuild is measured against, and slot b
boots it, so `vip-boot try-kernel 7.0.0-1017-raspi-realtime` is a validated way back from a pedal
kernel that will not come up. A card written by pedal.project's `make-card` carries both slots:
slot a the rebuild (from the artefacts above, pinned by hash in `devices/vip/image.lock`), slot b
the stock kernel, both `good`. Nothing about a rebuild reaches the board by apt, and a rebuilt
kernel with the same release string is a different kernel — the release string is the only thing
that separates two module sets, which is why trials get their own suffix
(`--localversion -numaemu2-trimmed`) and go through `vip-try` before anything pins them.

### Changing the boot arguments on a board that is already up

`AUDIO_TUNING_ARGS` reaches a boot tree only when the tree is built (`init-pedal-boot` on vip,
`flash-kernel` + `arm-try-piv.sh` on piv). Both boards have a smaller way to move a board that is
already running onto the arguments in `device.env`, with no kernel staged and no slot promoted:

```bash
ssh vip sudo vip-boot set-args            # every slot's cmdline-tuned.txt, in one pass
ssh piv sudo piv-boot set-args            # the tree os_prefix names: current/cmdline.txt

# both: print the diff and the proposed line, and write nothing
ssh vip sudo vip-boot set-args
ssh piv sudo piv-boot set-args
# write it (the file it replaces is kept beside it), then reboot when you choose
ssh vip sudo vip-boot set-args --yes
ssh piv sudo piv-boot set-args --yes
# on piv, a tuning this boot has not run takes one more word: the line has not been booted, so
# --yes alone refuses it
ssh piv sudo piv-boot set-args --yes --write-active-line
# put the previous line back
ssh vip sudo vip-boot set-args --restore
ssh piv sudo piv-boot set-args --restore
```

On vip both slots move together, because a fallback that boots the old arguments is a boot into a
layout the pedal's rules no longer describe. On piv there is one command line that applies — the
one in the tree `os_prefix` selects for a normal boot — so `piv-boot` reads `config.txt`, resolves
`<BOOT_MOUNT>/<os_prefix>cmdline.txt` (`/boot/firmware/current/cmdline.txt`), prints it, and
rewrites that file; a `cmdline.txt` at the root of the boot partition is a leftover from before the
slots that the firmware has not read since `os_prefix` arrived. It keeps what it replaced as
`cmdline.txt.bak-<UTC stamp>` beside it, and `--restore` puts the newest one back.

`piv-boot` only ever moves the arguments the audio profile owns; everything else on the line stays
as it was. It refuses to write a line that would lose `rd.shell=` / `rd.emergency=` / `rd.retry=` /
`rd.timeout=` / `panic=` or that would not carry the same `root=` it replaced, and it reads the
line it wrote back before it reports success. Running it twice does nothing the second time.
Off the board, `tests/piv-boot/` checks all of that against a fake boot partition.

It also writes only a line it can show has been booted: if the tuning arguments about to be written
are not the ones `/proc/cmdline` is running, `--yes` on its own refuses the write, and
`--write-active-line` is how you say you mean it anyway. A `/proc/cmdline` that cannot be read is
taken as no proof rather than as agreement, and the refusal names the file it could not read.
`--restore` follows the same rule, and it is the one case that stays a single command: putting back
the line this boot is running — the ordinary undo of a write that just happened — needs no flag.

**What `piv-boot set-args` is not.** It edits the *active* command line — the tree that boots — so
there is no candidate behind the change and no automatic fallback: a line that does not boot needs a
serial console, a card reader, or recovery step 5. The route the project designed for an argument
change on piv is the one-shot,

```bash
scripts/safety/arm-try-piv.sh --expect "$(ssh piv uname -r)" --audio-tuning --reboot
# or: make piv-audio-boot-args
```

which copies `current/` to `new/` so the candidate inherits the known-good command line, writes the
safety arguments into `new/cmdline.txt` after `flash-kernel`, checks that the candidate holds a
`vmlinuz` and a `.dtb` (without both, the firmware silently ignores `os_prefix`), and reboots once
through tryboot, leaving `current/` bootable. `set-args` says that in its own output as well as
refusing the untried line: it is the smaller tool for a board that is already up, a card with no
candidate, and arguments already known to boot.

`make vip-try` / `vip-boot try-kernel`, and `make piv-audio-boot-args`, remain the heavier route,
which is what a *new kernel* needs.

### The boot half of piv's audio profile

The route for the boot half is the tryboot one-shot (`make piv-audio-boot-args`), which stages the
running kernel as a candidate and lets the firmware's A/B ladder roll it back — the right hammer for
a new kernel, for the first application of a profile, and for any set of arguments that has not been
booted before, since an argument set that does not come back is just as effective a way to lose a
machine as a bad kernel. `piv-boot set-args` above is the smaller second route: one file, one
reboot, no candidate behind it, for a board that is already up and arguments already known to boot
— which it enforces, by asking for `--write-active-line` before it writes a tuning this boot has not
run.

### Testing

```bash
make test-piv                         # or, for one run shaped to match the recorded results:
./scripts/test/run-suite.sh piv --duration 300 --periods "64 128 256" \
    --governor performance --label "..."
./scripts/test/report.sh --board piv
```

`run-suite.sh` takes any device that has a `devices/<host>/device.env` and `cyclictest` installed;
these are the recordings that exist for piv.

**For a sustained run, cap the clock at a frequency the board can actually hold.** An
uncapped run does not measure a machine at its top bin; it measures whatever the thermal
governor leaves after throttling, and a different amount of it on every run — so two
uncapped runs are not comparable. `--max-freq` sets the cap for the run and restores the
old value afterwards, which is what makes the figure reproducible rather than merely
survivable.

### What is NOT captured in this repo

- The OS install itself. Start from a working image on a card the board boots from, with
  networking configured; RECOVERY says what to do when it does not come back.

## piv low-latency audio tuning

piv already runs Ubuntu's `linux-raspi-realtime`. Canonical's config is genuinely good
(PREEMPT_RT, HZ_1000, NO_HZ_FULL, RCU_BOOST, `RT_GROUP_SCHED` off, debug options off,
osnoise/timerlat left on so `rtla` works), so **there is very little a custom rebuild of
that source could change**. The measurable win is on the kernel command line and at
runtime instead. See "Is a custom kernel worth building for piv?" below.

The profile has two halves, installed separately and on purpose:

```bash
make piv-audio-tune       # runtime: IRQ pinning + priority. Reverts on reboot.
make piv-audio-boot-args  # boot: CPU isolation, via the tryboot one-shot (stages the kernel)
make piv-audio-status     # is it actually in force?
ssh piv sudo piv-boot set-args   # boot: the small route -- rewrite the active line, no kernel staged
```

| half | what it does | risk | rollback |
|---|---|---|---|
| runtime (`rtpi-audio-tune`) | pins the audio interrupt to reserved core 1, raises its thread to SCHED_FIFO 85 | none — changes nothing that boots | power cycle |
| boot (`AUDIO_TUNING_ARGS`) | `isolcpus` / `nohz_full` / `rcu_nocbs` on cores 1-3, `irqaffinity` to 0, `skew_tick` | can stop the machine booting | tryboot one-shot (same as a bad kernel, and it falls back by itself), or `piv-boot set-args --restore` for the in-place route |

Install the runtime half first. It is the part you can test immediately and undo with a
power cycle, so it is how you find out whether this board's interrupt controller honours
affinity **before** committing to a reboot with changed boot arguments.

The boot half stages the *same kernel* as the candidate and changes only the command
line. That is a deliberately clean experiment: the one difference between candidate and
known-good is the arguments, so a failure to come back is unambiguously the arguments — and
because the candidate is a real slot, the failure comes back by itself. That is why it is the route
for an argument set that has not been booted before. `piv-boot set-args` is the same experiment
without the staging: one file, one reboot, no candidate, and the line it replaced kept beside it —
and it will not write a tuning this boot has not run unless `--write-active-line` says you mean it.

### Measured effect

60s per period under `stress-ng --cpu 4 --io 2 --vm 1` + hackbench, 48 kHz periods:

| | p99 | p99.9 | p99.99 | max | audio-core avg |
|---|---|---|---|---|---|
| 64 fr untuned | 52 | 74 | 94 | 138 | 11.0 / 12.3 |
| 64 fr tuned | **24** | **47** | **75** | **92** | **3.9 / 4.6** |
| 128 fr untuned | 58 | 81 | 101 | 115 | 13.5 / 12.9 |
| 128 fr tuned | **26** | **46** | **74** | 168 | **4.8 / 4.7** |
| 256 fr untuned | 65 | 88 | 108 | 129 | 14.4 / 13.4 |
| 256 fr tuned | **32** | **58** | **83** | **90** | **5.6 / 5.6** |

Percentiles roughly halve at every period, and average latency on the reserved cores
drops about 2.5-3x. Read the one number that got worse honestly: the 168us at 128 frames
is a **single** event on cpu0, a housekeeping core, whose whole distribution is otherwise
far better than the untuned run. Cores 0-1 now absorb every interrupt AND all the load
that can no longer spread onto 2-3, so the worst outlier moving there is the tuning
working, not failing. Maxima are rare events and 60s under-samples them; the percentiles,
drawn from 45k-180k samples per core, are the robust comparison. `report.sh` therefore
ranks a tuning change on p99.9 and prints max alongside, rather than ranking on max.

**These figures are the pre-2026-10-09 split** (cores 2-3 reserved, 0-1 housekeeping). The
amended rules reserve 1-3 and leave core 0 to do everything else, so the same rig on the
current arguments is a *different* experiment and has not been re-measured;
`arm-try-piv.sh --audio-tuning` (`make piv-audio-boot-args`) is how the boot half moves to it
without risking the card.

A 300s run of the promoted config (900k/450k/225k samples) gives p99 22/27/31us, p99.9
42/50/58us, max 126/182/139us — worst case 6.8% of its period budget — holding 2400MHz
for the full 15 minutes with a 48.5C peak and no throttling at any point. piv has plenty
of thermal headroom to spare: trips are at 50/60/67.5/75C with critical at 110C, and it
idles at 38C.

**Not yet measured: a 300s *untuned* baseline.** The comparison table above is 60s on both
sides, which is a fair comparison but under-samples maxima. To get the 300s pair, stage a
candidate without `--audio-tuning`, run the suite, then re-apply. `report.sh` will only
compare runs of equal duration, so it will not silently pair the 300s tuned run against a
60s baseline and report the extra sampling as a regression.

### Pin your audio threads, or you get none of this

`isolcpus` reserves cores 2-3; it does not put anything on them. Nothing migrates there
by itself, so an unpinned JACK or PipeWire process runs on the busy housekeeping cores
and sees the *worse* numbers. Pin explicitly:

```bash
taskset -c 2,3 jackd -R -P 80 -d alsa -d hw:2 -r 48000 -p 64 -n 2
```

### Interrupt numbers are not stable on this board; names are

`/etc/rtpi/audio-tune.conf` matches the audio interrupt by name (`xhci-hcd:usb4` today), never
by number. The numbers are allocated in probe order under `rp1_irq_chip`: across the
single reboot that installed this profile the audio interrupt moved from **138 to 139**.
A config pinning "IRQ 138" would have silently pinned an unrelated device, and would have
looked like it worked.

### You cannot `taskset` an interrupt thread, and you should not try

Interrupt threads carry `PF_NO_SETAFFINITY`; `taskset` on one fails with *"affinity
cannot be set due to PF_NO_SETAFFINITY flag set"*. The kernel owns their placement and
ties it to the interrupt's own affinity, so writing `/proc/irq/N/smp_affinity_list` is the
entire job. The thread's `Cpus_allowed_list` may still read as every CPU; that is normal.

### An affinity change only takes effect at the next interrupt

Write `smp_affinity_list` on an idle device and `/proc/interrupts` keeps showing every
count against the old core — indistinguishable from the write having failed. For an
edge-triggered interrupt the move is queued and performed from the handler. Generate
traffic before concluding anything:

```bash
arecord -D hw:2,0 -f S32_LE -r 48000 -c 8 -d 5 /dev/null
```

(The SSL 2+ Mk II presents 8 capture / 6 playback channels at a 125us packet interval;
`-c 2` fails with *"Channels count non available"*.)

### Is a custom kernel worth building for piv?

Probably not, and the config audit is why. Everything that normally justifies a custom RT
build is already set the way you would set it, and the remaining levers are not free wins:

| lever | state on `7.0.0-1017-raspi-realtime` |
|---|---|
| `PREEMPT_RT`, `PREEMPT_LAZY`, `HZ=1000`, `RCU_BOOST`, `HIGH_RES_TIMERS` | already on |
| `RT_GROUP_SCHED` | already off |
| `DEBUG_PREEMPT`, `PROVE_LOCKING`, `SCHED_DEBUG`, `SLUB_DEBUG_ON`, `KASAN` | already off |
| `NO_HZ_FULL`, `RCU_NOCB_CPU` | already on — activated by *command line*, not a rebuild |
| `TRANSPARENT_HUGEPAGE`, `NUMA_BALANCING` | not built at all; nothing to disable |
| `FUNCTION_TRACER` | on, but `DYNAMIC_FTRACE` means nops until used — and `rtla` needs it |
| `ARM64_MTE` | dead code on a Cortex-A76 (ARMv8.2, MTE is v8.5) |
| `STACKPROTECTOR_STRONG`, `RANDOMIZE_BASE` | small cost, but removing them is a security decision |

A rebuild is worth it for something you cannot get any other way — an out-of-tree patch,
or a different page size for large DSP working sets (`CONFIG_ARM64_4K_PAGES` is what
Ubuntu ships). It is not worth it to re-set options that are already set.

## vip's kernel: the first candidate change

vip runs Ubuntu's `linux-raspi-realtime` rebuilt with the config fragments in `config/` and the
patches in `patches/vip/`. The first of those is StarFive's fix for the capture DMA race below.
`scripts/build/vip-ubuntu-rt.sh` applies every `patches/vip/*.patch` onto the stock tag before it
builds. A patched kernel is a different kernel, so the trial has its own `--localversion`
(`-numaemu3-dmaidle1-trimmed`) and goes through `make vip-try`; the build refuses to reuse the
release the board is already running, because that would replace the modules the active slot boots.

**The symptom.** A capture on vip dies with

    arecord: pcm_read:2285: read error: Input/output error

and takes the measurement with it. Twice on 2026-10-12, and both times the kernel had already said
why, on `dma2chan3` — the **I2S capture** direction of the RP1's AXI DMA controller (`dma2chan2` is
playback), which `/sys/kernel/debug/dmaengine/summary` names:

    dma dma2chan3: dma2chan3 is non-idle!
    dma dma2chan3: Bad descriptor submitted for dma2chan3, cookie: 54, irq: 0x00002000

**What it is.** `is non-idle!` is `axi_chan_block_xfer_start()` finding the hardware channel still
enabled while a new transfer is being started — a stream stopping and another starting, which is
what a measurement session is made of. **The stock driver prints that and returns without
programming the new transfer**, so the engine goes on to fetch a descriptor it rejects: `irq:
0x00002000` is bit 13 of `INTSTATUS`, *shadow register or LLI invalid error*
(`DWAXIDMAC_IRQ_INVALID_ERR`). `axi_chan_handle_err()` then reports it as `Bad descriptor
submitted` — a message the maintainers agree is misleading, since it fires for decode and slave
errors too — dumps the transfer's LLIs, and fails it. ALSA turns that into `-EIO`, which is the
`arecord` error above. The two failures are identical down to the descriptor dump, so this is a
race with a fixed shape, not corruption.

**The patches.**

- StarFive's fix disables the channel and re-issues the descriptor instead of returning:
  [1013-dmaengine-dw-axi-dmac-Handle-xfer-start-while-non-id.patch](https://git.cdn.openwrt.org/openwrt/staging/linusw/plain/target/linux/starfive/patches-6.12/1013-dmaengine-dw-axi-dmac-Handle-xfer-start-while-non-id.patch?id=0a1e1016b4d82dabedcb231dc4fd7fb65ba16736).
  OpenWrt carries it for its StarFive target; it is **not in mainline**, so
  `7.0.0-1017-raspi-realtime` does not have it. It is 12 lines across two files.
- Upstream is in the same code: [PATCH 3/3, 2026-10-06](https://lists.openwall.net/linux-kernel/2026/10/06/57)
  decodes these errors properly and **explicitly leaves the transfer result and recovery path
  unchanged** — it would relabel this log, not stop the error. Worth taking for the diagnosis, not
  as the fix.
- [raspberrypi/linux#7320](https://github.com/raspberrypi/linux/issues/7320) is the playback-side
  relative (a PCM512x HAT, ending in an oops) and is still open.

**Rebase.** `patches/vip/1013-dmaengine-dw-axi-dmac-Handle-xfer-start-while-non-id.patch` is
StarFive's change on the shipped `Ubuntu-raspi-7.0.0-1017.17` driver. The OpenWrt patch does not
apply as-is: this tree's `axi_chan_block_xfer_start()` has no `axi_dma_enable()` call (runtime PM
enables the controller from `alloc_chan_resources`), and that was the context line the hunk
needed. `axi_chan_handle_err()` matches upstream 7.0.12. The behaviour is StarFive's: disable the
channel and program the transfer instead of returning, and on the error that follows, re-issue
that descriptor instead of failing it.

**Tried, and promoted, on 2026-10-12.** The release is
`7.0.0-1017-raspi-realtime-numaemu3-dmaidle1-trimmed`. Validation promoted slot a (sshd, wlan0,
PREEMPT_RT, the release it was sent to try). Slot b kept
`7.0.0-1017-raspi-realtime-numaemu3-trimmed`, still marked good. `namchaind` came back holding
the capture device, and eight one-second `arecord` stop/start cycles on `hw:wm8960` produced no
`non-idle` line and no `Bad descriptor`. `PEDAL_KERNEL` in `devices/vip/device.env` names this
release, and so does pedal.project's `devices/vip/image.lock`.

The evidence, the log decoded, and the measurement-side procedure are in pedal.project's
[docs/audio-dma-irq.md](../pedal.project/docs/audio-dma-irq.md#when-the-capture-dies-pcm_read-inputoutput-error).

## Things that will bite you

### `unattended-upgrades` re-runs flash-kernel behind your back

Observed live on 2026-09-15 06:37: it upgraded **dracut** — not a kernel. Regenerating
the initramfs fired `/etc/initramfs/post-update.d/flash-kernel`, which ran the `pi-try`
method, which does `rm -rf old new` when `old/` exists. That **destroyed the rollback
slot** and staged an unrequested candidate. If it happens while an RT candidate is
staged, your candidate is silently replaced mid-test.

`make hold-piv` holds the kernel *and* the initramfs generators. `make unhold-piv` undoes it.

### …but that `rm -rf old new` is also load-bearing, not just destructive

Every state-machine case in `piboot-try` that accepts a staged candidate is
`[01]/-/good/unknown` — the `-` means **`old/` must be absent**. flash-kernel guarantees
that by removing `old/` before it stages. Leave `old/` in place next to an untested
`new/` and the key becomes `1/good/good/unknown`, which no case matches; piboot-try
aborts with *"piboot is in an invalid or unexpected state"* and silently refuses to
tryboot.

So anything that hand-stages a candidate (the rehearsals do) must remove `old/` too.
`arm-try-piv.sh` refuses to arm if `old/` is present, because the failure otherwise only
shows up at reboot time.

### Verified, not assumed

Both rehearsals have been run on the real hardware:

| rehearsal | result |
|---|---|
| success | `new/` promoted to `current/`, `current/` demoted to `old/`, settled in 146s |
| failure | board rebooted **itself** and returned on the known-good kernel in 249s, `new/state=bad` |

The failure rehearsal used a valid kernel with `root=LABEL=rtpi-no-such-fs`, so it
exercised the exact path we fear on this board — root not found on the USB-SATA bridge —
and proved the dracut arguments turn it into an automatic reboot rather than a permanent
hang.

### The candidate always inherits the known-good cmdline

flash-kernel's `pi-try` does, verbatim:

```sh
cp "$boot_mnt"/current/cmdline.txt "$boot_mnt"/new/cmdline.txt
```

So candidate-specific kernel arguments must be written **after** flash-kernel runs and
**before** arming. `scripts/safety/arm-try-piv.sh` does it in that order. Get it backwards
and the dracut safety arguments are silently overwritten.

### The dracut lockout (the most likely RT failure on piv)

piv's root is on a USB-SATA bridge. If a candidate kernel fails to enumerate xHCI it boots
but cannot mount root — and dracut will hang **forever**, in two independent ways:

- **The eternal wait.** `dracut-rootfs-generator` sets `JobTimeoutSec=infinity` on the
  root device unit when `rd.timeout` is unset, overriding systemd's 90s default. The
  emergency handler is never even reached.
- **The sulogin trap.** If the job does fail, `dracut-emergency` runs `exec sulogin` when
  `rd.shell` is set (it defaults to 1), so the `reboot -f` branch is never reached —
  `rd.emergency=reboot` is silently ignored. And `rd.shell=0` *alone* falls through to
  `poweroff`, which with no smart plug is worse than a hang.

All four arguments are required, none is sufficient alone:

```
rd.shell=0 rd.emergency=reboot rd.retry=60 rd.timeout=90
```

**`panic=N` does not help here.** With an initramfs the kernel never calls
`prepare_namespace()`, so it never panics on "unable to mount root" — dracut owns that
failure. `panic=` only covers real kernel panics.

### Never use a custom kernel flavour name on piv

`check_kflavors` rejects unknown flavours and flash-kernel **exits 0 having written
nothing** — a silent no-op that looks like success. Keep the flavour `raspi-realtime` and
bump only the ABI (e.g. `7.0.0-1017rt1-raspi-realtime`).

### Do not add `threadirqs` to an RT kernel

`kernel/irq/manage.c` guards that `early_param` with
`#if defined(CONFIG_IRQ_FORCED_THREADING) && !defined(CONFIG_PREEMPT_RT)`. Under
PREEMPT_RT it is not registered and forced threading is unconditional. Passing it is a
no-op that will mislead you.

### `RT_GROUP_SCHED=y` blocks SCHED_FIFO entirely on cgroup v2

A kernel built with `CONFIG_RT_GROUP_SCHED=y`, on a system running cgroup v2 with the `cpu`
controller enabled, denies `SCHED_FIFO` to every task outside the root cgroup — **including
root**:

```bash
$ sudo chrt -f 50 true
chrt: failed to set pid 0's policy: Operation not permitted

$ sudo bash -c 'echo $$ > /sys/fs/cgroup/cgroup.procs; chrt -f 50 true'   # works
```

This is not a benchmarking curiosity. Every systemd service and login session lives in a
non-root cgroup, so on such a kernel **JACK and every other realtime audio application is
refused a realtime priority**. `cyclictest` fails the same way, with the unhelpful message
`Unable to change scheduling policy!` even under `sudo`.

`scripts/test/run-suite.sh` works around it by moving the measurement process into the root
cgroup first. That is fine for a benchmark and wrong for production — the real fix is
`CONFIG_RT_GROUP_SCHED=n`, which `config/audio-rt-common.fragment` specifies. It is an
independent reason to care about the kernel config, separate from `PREEMPT_RT`: Ubuntu's
`raspi-realtime` flavour already has it off, so the workaround is insurance for any other
kernel these scripts are pointed at.

Check it on any kernel with:

```bash
grep RT_GROUP_SCHED /boot/config-$(uname -r)
```

### Detecting RT at runtime

`/sys/kernel/realtime` **does not exist** — it was an out-of-tree RT-patch artifact that
was never merged. Use the version banner:

```bash
uname -v | grep -q PREEMPT_RT
```

## Out-of-band console

Serial is optional on both boards. What it buys you is the one thing nothing else does:
the ability to **read a failed boot remotely, from the Mac, without walking over to the
board**. A permanently-attached FTDI cable is the only way to do that.

| | serial | HDMI + USB keyboard |
|---|---|---|
| interactive rescue (U-Boot prompt, or a dracut shell) | yes | yes |
| see the kernel boot failure | yes | yes |
| earliest firmware output, before video init | yes | **no** |
| capture/scroll the log into a file | yes | photograph the screen |
| read a failure **remotely, unattended** | yes | no |

A kernel log that survives the watchdog reset would cover the same ground with no cable at
all (`pstore`/`ramoops`, read from `/sys/fs/pstore` on the fallback boot). Not set up yet.

### Pinouts, if you do use serial

One **FTDI TTL-232R-3V3** cable per board. (The Raspberry Pi Debug Probe adds nothing here.)

| board | TX | RX | GND | settings |
|---|---|---|---|---|
| `piv` (ttyAMA0) | pin **8** | pin **10** | pin **6** | 115200 8N1 |
| `vip` (ttyAMA10, 3-pin header) | — | — | — | 115200 8N1 |

On vip the console is on the board's own 3-pin UART header, where the Debug Probe plugs in,
and every pedal command line carries `console=ttyAMA10,115200` (see
`devices/vip/device.env`). On piv, `BOOT_UART=1` outputs to a JST header the Pi 500's case
does not expose, so it buys nothing externally; add `enable_rp1_uart=1` and
`uart_2ndstage=1` to `config.txt` to get earlier output onto the 40-pin header.

From the Mac:

```bash
ls /dev/cu.usbserial-*
screen /dev/cu.usbserial-XXXX 115200      # ctrl-a k to quit
```

---

## RECOVERY

Work down this list. Each step assumes the one before it failed.

### piv will not come back

1. **Wait 5 minutes.** A failed tryboot takes two reboots to settle, and the watchdog
   needs up to 14s plus a boot cycle. `make watch-piv` will tell you what returned.
2. **Power-cycle it once.** tryboot is one-shot and already consumed, so a cold boot
   loads `current/` — the known-good kernel. This resolves most cases.
3. **Serial console** (pins 8/10/6, 115200). You will see either the firmware, the kernel
   log, or a dracut message. If you reach a shell:
   ```bash
   sudo piboot-try --status          # what does it think is going on?
   sudo cat /boot/firmware/*/state
   sudo piboot-try --restore-old     # swap old/ back into current/
   ```
4. **From this Mac**, if ssh works at all: `make panic-piv` marks the candidate bad and
   forces `current/` to good.
5. **Pull the boot media** (the USB SSD) and mount partition 1 on another machine. Restore
   from `devices/piv/backups/latest/boot-firmware.tar`:
   ```bash
   sudo tar -C /Volumes/system-boot -xf boot-firmware.tar
   ```
   Or minimally: delete the `new/` directory and make sure `current/state` says `good`.

### vip will not come back

vip has a **rescue root of its own** on the card, separate from the pedal root, and its
`vip-boot` decides independently which boot partition, kernel slot and profile come up. So the
recovery ladder starts with the mechanism rather than with a card writer.

1. **Wait ~5 minutes.** A pedal boot that never reaches `pedal-guard` writes the reason to
   `bootsel` and reboots into rescue by itself — three boots in a row that never got that far
   and rescue becomes sticky. `scripts/safety/watch-reboot.sh vip` will tell you what came
   back.
2. **Power-cycle it once.** A candidate is one-shot, so a cold boot loads the active slot —
   the one that was good before. This resolves most cases.
3. **Serial console** (the 3-pin UART header, 115200; every pedal command line carries
   `console=ttyAMA10,115200`). In rescue:
   ```bash
   vip-boot status              # which slot/profile/root, and why rescue was entered
   vip-boot default pedal       # stop being sticky: boot the pedal root again
   vip-reimage pedal            # restore the pedal root from pedal-data/images/
   ```
4. **From this Mac**, if ssh works at all: `make vip-try` puts a candidate in the spare slot,
   and anything other than a clean validation returns to the active slot and marks the candidate
   bad.
5. **The spare card is the floor.** The card's layout, the rescue root's contents and how an
   image is written are pedal.project's `docs/vip-image.md`. The one act with no card-level
   fallback at all is a bootloader EEPROM write.

### What none of this covers

- A hang *before* the watchdog driver loads (roughly the first 5–15 seconds), and a default
  kernel that hangs before its initramfs runs — the boot counter never moves, so it resets into
  the same thing. No software can catch either; they need a physical power cycle. A
  network-controlled smart plug is the only remote fix, and is the single best hardware
  addition if you ever want to run these tests unattended.
- Firmware/bootloader blob updates on piv. `pi-try` copies those to the boot partition
  root as well as into the slot, and the source notes that part *"is not subject to
  tryboot"* — so firmware updates are **not** protected by the A/B mechanism.
- A corrupt boot partition, a corrupt EEPROM, or a dead card.

---

## Layout

```
devices/<host>/device.env    single source of truth for each board's facts
devices/<host>/etc/          files deployed to the device (validate hook, drop-ins)
devices/<host>/backups/      pulled backups — off-device, which is the point
config/*.fragment            kernel config deltas, with rationale per symbol
patches/vip/*.patch          out-of-tree fixes applied onto vip's stock tag
scripts/lib/common.sh        shared helpers and the safety guards
scripts/safety/              backup, preflight, arm, watch, rehearse, panic-button
scripts/deploy/              things that change a device
scripts/build/               things that run in the build container
scripts/test/                latency and xrun harness
results/                     one JSON per run
```

## Kernel sources

**piv** — Ubuntu's `linux-raspi` source already defines a `raspi-realtime` flavour, and
Canonical has already tuned it well for RT (PREEMPT_RT, HZ_1000, NO_HZ_FULL, RCU_BOOST,
RT_GROUP_SCHED off, and the osnoise/timerlat tracers left **on** so `rtla` works). So the
audio delta is small, and most of the remaining win is cmdline and runtime tuning.
Source is Format 1.0: `.orig.tar.gz` + `.diff.gz`, no `.debian.tar.xz`. Config comes from
`debian.raspi/config/annotations`, not `config.flavour.*`. Note `7.0.0-1017.17` is in
`resolute-updates`/`resolute-security`, **not** the plain `resolute` pocket.

**vip** — the same `linux-raspi` source and the same `raspi-realtime` flavour as piv, rebuilt from
the tag the stock package was built from (`Ubuntu-raspi-<abi>.<upload>`, read off the board) with
two deltas: `config/vip-numa-emu.fragment` turns `CONFIG_NUMA_EMU` on, which cannot be set at boot
(the stock kernel answers `Malformed early option 'numa'`), and `patches/vip/` is applied on top
(today StarFive's non-idle DMA fix). The module set is trimmed to what
the board loads plus `config/vip-keep.fragment`'s deliberate exceptions. The config baseline is
always the **stock** kernel's `/boot/config-*`, never the running rebuild's: a rebuild's config
already carries the fragment and the trim, so a delta measured against it would be empty. The
build asserts the delta is exactly `CONFIG_NUMA_EMU` and `CONFIG_LOCALVERSION`, that every module
the board loads is present or built in (minus `trimmed-ok.txt`), that the modules are stripped,
and that `make kernelrelease` is the string it meant to build.

