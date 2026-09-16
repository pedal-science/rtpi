# rtpi

Reproducible PREEMPT_RT kernels for low-latency audio on two ARM boards, with automatic
rollback so a bad kernel can never cost remote access.

| host | board | arch | OS | stock kernel |
|---|---|---|---|---|
| `piv` | Raspberry Pi 500 (BCM2712) | arm64 | Ubuntu 26.04 resolute | `7.0.0-1017-raspi` |
| `tib` | ASUS Tinker Board S (RK3288) | armhf (ARMv7) | Armbian 26.8.3 | `6.18.44-current-rockchip` |

Audio hardware: an SSL 2+ Mk II on piv, a Realtek USB interface on tib.

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

### tib — a self-clearing one-shot in the U-Boot environment

RK3288 has no tryboot, so `devices/tib/boot/boot.cmd` builds the equivalent: if the
U-Boot variable `rt_try` is `1`, it clears the flag, **persists and verifies the clear**,
and only then boots the candidate. Any failure in that sequence boots the frozen
known-good slot instead, so a failed clear fails *safe* rather than into a boot loop.

Note the inversion: the **candidate** is the normal Armbian `zImage`/`uInitrd`/`dtb`
symlinks (which Armbian's postinst keeps pointing at the newest kernel), and the
**known-good** is a frozen copy we make (`*-good`). So a routine Armbian kernel upgrade
can never silently become the default boot.

## tib bring-up from a fresh Armbian install

Every step below is a script in this repo. Run them in this order; each one refuses to
proceed if the previous one has not been done.

```bash
make colima-up && make image          # build environment (6 CPU / 8G on a 16G Mac)

make tib-freeze-good                  # 1. freeze the running stock kernel as the fallback
make tib-bootscr                      # 2. install the one-shot boot script
ssh tib 'sudo systemctl reboot'       #    reboot once: rtpi region 1 bootstraps the U-Boot env
make status-tib                       #    must report VALID before any fw_setenv
ssh tib 'sudo apt-get install -y libubootenv-tool'
make tib-validate-service             # 3. install the candidate-boot validate service

make tib-rt                           # 4. build mainline 7.2.6 + patches/tib + RT fragments
make tib-install-rt                   #    stage it into the candidate slot
make tib-try                          # 5. arm the one-shot, reboot, watch the result
```

If it comes back on the candidate and you are happy with it, make it permanent:

```bash
make tib-freeze-good                  # promote: the candidate becomes the new known-good
```

Promotion is deliberate and separate on purpose. A candidate that passes validation is
still a one-shot — the next reboot returns to the frozen slot — so nothing becomes the
default until you say so.

### What each piece contributes, and what breaks without it

| step | without it |
|---|---|
| freeze-good | nothing to fall back to; a bad kernel is permanent |
| bootscr | the `-good` files are inert; Armbian's postinst decides what boots |
| env bootstrap | `fw_setenv` writes a one-variable environment and kills `bootcmd` |
| validate service | a candidate that boots without network sits there unreachable |
| `patches/tib/` | SDIO wifi never enumerates on 7.2.6 — the board has no network |
| RT fragments | no `PREEMPT_RT`; and with `RT_GROUP_SCHED` left on, no `SCHED_FIFO` at all |

### Testing

```bash
make test-tib                         # or, to match the recorded results exactly:
./scripts/test/run-suite.sh tib --duration 300 --periods "64 128 256" \
    --governor performance --max-freq 1416000 --label "..."
./scripts/test/report.sh --board tib
```

**Always cap the clock for sustained runs.** This board cannot hold 1.8GHz: an uncapped
15-minute suite drove it into the 90C critical trip and the kernel shut it down mid-run.
1416MHz holds at 72-76C and, more importantly, is reproducible — uncapped, thermal
throttling means every run measures a different machine.

### What is NOT captured in this repo

- The Armbian install itself. Start from a working Armbian image on a card the board boots
  from, with networking configured. See the card-compatibility note in RECOVERY.
- `/etc/fw_env.config`, written by `tib-install-bootscr.sh`'s follow-up step above.
- Anything about `piv`, which uses an entirely different mechanism (`tryboot`).

## piv low-latency audio tuning

piv already runs Ubuntu's `linux-raspi-realtime`. Canonical's config is genuinely good
(PREEMPT_RT, HZ_1000, NO_HZ_FULL, RCU_BOOST, `RT_GROUP_SCHED` off, debug options off,
osnoise/timerlat left on so `rtla` works), so **there is very little a custom rebuild of
that source could change**. The measurable win is on the kernel command line and at
runtime instead. See "Is a custom kernel worth building for piv?" below.

The profile has two halves, installed separately and on purpose:

```bash
make piv-audio-tune       # runtime: IRQ pinning + priority. Reverts on reboot.
make piv-audio-boot-args  # boot: CPU isolation. Goes through tryboot.
make piv-audio-status     # is it actually in force?
```

| half | what it does | risk | rollback |
|---|---|---|---|
| runtime (`rtpi-audio-tune`) | pins the audio interrupt to a reserved core, raises its thread to SCHED_FIFO 85 | none — changes nothing that boots | power cycle |
| boot (`AUDIO_TUNING_ARGS`) | `isolcpus` / `nohz_full` / `rcu_nocbs` on cores 2-3, `irqaffinity` to 0-1, `skew_tick` | can stop the machine booting | tryboot one-shot, same as a bad kernel |

Install the runtime half first. It is the part you can test immediately and undo with a
power cycle, so it is how you find out whether this board's interrupt controller honours
affinity **before** committing to a reboot with changed boot arguments.

The boot half stages the *same kernel* as the candidate and changes only the command
line. That is a deliberately clean experiment: the one difference between candidate and
known-good is the arguments, so a failure to come back is unambiguously the arguments.

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

A 300s run of the promoted config (900k/450k/225k samples) gives p99 22/27/31us, p99.9
42/50/58us, max 126/182/139us — worst case 6.8% of its period budget — holding 2400MHz
for the full 15 minutes with a 48.5C peak and no throttling at any point. piv has
thermal headroom that tib does not: trips are at 50/60/67.5/75C with critical at 110C,
and it idles at 38C.

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

`/etc/rtpi/audio-tune.conf` matches the audio interrupt by name (`xhci-hcd:usb2`), never
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
| `RT_GROUP_SCHED` | already off (unlike Armbian on tib) |
| `DEBUG_PREEMPT`, `PROVE_LOCKING`, `SCHED_DEBUG`, `SLUB_DEBUG_ON`, `KASAN` | already off |
| `NO_HZ_FULL`, `RCU_NOCB_CPU` | already on — activated by *command line*, not a rebuild |
| `TRANSPARENT_HUGEPAGE`, `NUMA_BALANCING` | not built at all; nothing to disable |
| `FUNCTION_TRACER` | on, but `DYNAMIC_FTRACE` means nops until used — and `rtla` needs it |
| `ARM64_MTE` | dead code on a Cortex-A76 (ARMv8.2, MTE is v8.5) |
| `STACKPROTECTOR_STRONG`, `RANDOMIZE_BASE` | small cost, but removing them is a security decision |

A rebuild is worth it for something you cannot get any other way — an out-of-tree patch,
or a different page size for large DSP working sets (`CONFIG_ARM64_4K_PAGES` is what
Ubuntu ships). It is not worth it to re-set options that are already set.

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

Armbian's stock tib kernel ships `CONFIG_RT_GROUP_SCHED=y`, and the system runs cgroup v2
with the `cpu` controller enabled. That combination denies `SCHED_FIFO` to every task
outside the root cgroup — **including root**:

```bash
$ sudo chrt -f 50 true
chrt: failed to set pid 0's policy: Operation not permitted

$ sudo bash -c 'echo $$ > /sys/fs/cgroup/cgroup.procs; chrt -f 50 true'   # works
```

This is not a benchmarking curiosity. Every systemd service and login session lives in a
non-root cgroup, so on this kernel **JACK and every other realtime audio application is
refused a realtime priority**. `cyclictest` fails the same way, with the unhelpful message
`Unable to change scheduling policy!` even under `sudo`.

`scripts/test/run-suite.sh` works around it by moving the measurement process into the root
cgroup first. That is fine for a benchmark and wrong for production — the real fix is
`CONFIG_RT_GROUP_SCHED=n`, which our config fragment already specifies. Treat this as an
independent reason to build a custom kernel for tib, separate from PREEMPT_RT.

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

## Bootstrapping tib's U-Boot environment

**Do this before any `fw_setenv`, or you will stop the board booting.**

The env region (`/dev/mmcblk0` at `0x3F8000`, 32 KB, ending exactly at partition 1) is
currently **all zeros with a zero CRC** — U-Boot has never saved an environment and runs
on its compiled-in defaults. `libubootenv`'s `fw_setenv` has no built-in defaults (it
reads `/etc/u-boot-initial-env`, which does not exist), so a *first* `fw_setenv` writes a
valid-CRC environment containing **only** your variable, destroying `bootcmd`.

**This needs no serial console.** `saveenv` *from inside U-Boot* has no such problem — it
serialises the complete in-memory environment, which at that point is the full compiled-in
default set. So rtpi region 1 of our [boot.cmd](devices/tib/boot/boot.cmd) does the
bootstrap itself, on the first boot that finds `rt_try` undefined:

```
if test "${rt_try}" = ""; then
	setenv rt_try 0
	if saveenv; then ...
fi
```

It is placed *before* the `armbianEnv.txt` import, so what gets persisted is U-Boot's own
defaults plus `rt_try` — not a copy of `armbianEnv.txt`, which is re-imported from the
filesystem every boot anyway.

Verified against this board's own U-Boot config (`/usr/lib/u-boot/tinker-s-rk3288_defconfig`):

| symbol | value | meaning |
|---|---|---|
| `CONFIG_ENV_IS_IN_MMC` | `y` | env lives in MMC |
| `CONFIG_ENV_MMC_DEVICE_INDEX` | **`1`** | U-Boot mmc1 = **the SD card**, not eMMC |
| `CONFIG_ENV_OFFSET` | `0x3f8000` | matches `UBOOT_ENV_OFFSET` |
| `CONFIG_ENV_SIZE` | `0x8000` | matches `UBOOT_ENV_SIZE` |
| `CONFIG_CMD_SAVEENV` | `y` | `saveenv` is compiled in |

So the order is: **install `boot.scr` → reboot once → verify → only then `fw_setenv`.**

```bash
make status-tib                    # decodes and CRC-checks the region — must say VALID
sudo fw_printenv | head            # should list ~27 variables including bootcmd
```

`scripts/safety/preflight.sh tib` refuses to proceed until this reports VALID. If the
bootstrap `saveenv` failed for any reason the region simply stays unwritten, U-Boot keeps
using its defaults, and the board still boots — so this fails safe.

## Out-of-band console

**Serial is optional on tib.** Its U-Boot is built with `CONFIG_VIDEO=y`,
`CONFIG_VIDEO_DW_HDMI=y`, `CONFIG_USB_KEYBOARD=y` and `CONFIG_CONSOLE_MUX=y`, and its
built-in environment is:

```
stdout=serial,vidconsole
stderr=serial,vidconsole
stdin=serial,usbkbd
```

So **a monitor plus a USB keyboard gives a fully interactive U-Boot prompt**, including
"Hit any key to stop autoboot". The kernel cmdline already carries
`console=ttyS2,115200n8 console=tty1`, so kernel messages reach the screen too.

What HDMI does *not* give you, and serial does:

| | serial | HDMI + USB keyboard |
|---|---|---|
| interactive U-Boot rescue | yes | **yes** |
| see the kernel boot failure | yes | yes |
| earliest SPL output, before video init | yes | **no** |
| capture/scroll the log into a file | yes | photograph the screen |
| read a failure **remotely, unattended** | yes | no — you walk over and look |

A permanently-attached FTDI cable is the only way to read a failed boot from the Mac
without being at the board. That is its remaining value; nothing in this repo *requires*
it.

Also compiled in: `CONFIG_PSTORE_RAM=y` and `CONFIG_PSTORE_CONSOLE=y`, so a reserved
ramoops region would let the kernel log survive the watchdog reset and be read from
`/sys/fs/pstore` on the fallback boot — kernel-stage diagnosis with no cable at all. Not
set up yet.

### Pinouts, if you do use serial

One **FTDI TTL-232R-3V3** cable per board. (The Raspberry Pi Debug Probe adds nothing here.)

| board | TX | RX | GND | settings |
|---|---|---|---|---|
| `tib` (ttyS2) | pin **32** | pin **33** | pin **34** | 115200 8N1 |
| `piv` (ttyAMA0) | pin **8** | pin **10** | pin **6** | 115200 8N1 |

tib's console is **not** on pins 8/10 — those are UART1. On piv, `BOOT_UART=1` outputs to
a JST header the Pi 500's case does not expose, so it buys nothing externally; add
`enable_rp1_uart=1` and `uart_2ndstage=1` to `config.txt` to get earlier output onto the
40-pin header.

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

### tib will not come back

**There is no eMMC on this board.** `mmc@ff0f0000` (the eMMC controller) is enabled but
reports no card, and `mmc@ff0e0000` is disabled — `lsblk` shows only `mmcblk0`, the SD.
The Rockchip idbloader is at sector 64 of `/dev/mmcblk0` and the env region at LBA 8128,
both *before* partition 1 at sector 8192. So **writing a fresh image to the SD card
replaces the bootloader, its environment and the root filesystem in one go**, with nothing
surviving elsewhere to override it. Step 4 below is a genuine total reset.

1. **Power-cycle once.** The one-shot flag is cleared before the candidate boots, so a
   cold boot uses the frozen known-good slot.
2. **Attach a monitor and a USB keyboard.** U-Boot's console is muxed to HDMI and it
   accepts a USB keyboard, so you get the prompt without any cable. Interrupt U-Boot
   (`BOOTDELAY=1`, so be quick) and boot known-good by hand:
   ```
   => setenv rt_try 0
   => saveenv
   => boot
   ```
   (Serial, on pins 32/33/34 at 115200, gets you the same prompt — plus the earliest
   output, which HDMI misses because video init happens later.)
3. **If the U-Boot environment is corrupt**, U-Boot falls back to its compiled-in defaults,
   which still boot. To reset it explicitly:
   ```
   => env default -a
   => saveenv
   ```
4. **Restore the env region from backup** on another machine, with the SD card inserted:
   ```bash
   sudo dd if=devices/tib/backups/latest/uboot-env.bin of=/dev/diskN bs=512 seek=8128 count=64
   ```
   Check `decode-uboot-env.py` reports VALID on the backup first.
5. **Write a fresh image to the spare SD card.** This is the floor: it always works, and
   because everything lives on the card it is a complete reset. The cost is that you lose
   the board's state and learn nothing about *why* it failed — which is what the scripts
   in this repo exist to make cheap to rebuild. Afterwards, re-run the tib setup from this
   repo (Phase 5: freeze the known-good slot, install `boot.scr`, reboot to bootstrap the
   env, then `make tib-rt`).

### What none of this covers

- A hang *before* the watchdog driver loads (roughly the first 5–15 seconds). No software
  can catch that; it needs a physical power cycle. A network-controlled smart plug is the
  only remote fix, and is the single best hardware addition if you ever want to run these
  tests unattended.
- Firmware/bootloader blob updates on piv. `pi-try` copies those to the boot partition
  root as well as into the slot, and the source notes that part *"is not subject to
  tryboot"* — so firmware updates are **not** protected by the A/B mechanism.
- A corrupt boot partition or EEPROM.

---

## Layout

```
devices/<host>/device.env    single source of truth for each board's facts
devices/<host>/etc/          files deployed to the device (validate hook, drop-ins)
devices/<host>/boot/         boot scripts (tib's custom boot.cmd)
devices/<host>/backups/      pulled backups — off-device, which is the point
config/*.fragment            kernel config deltas, with rationale per symbol
patches/                     empty for tib by design; 7.2.6 already has the RT fixes
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

**tib** — ARM32 PREEMPT_RT became available in mainline **v7.1** (commit `c6e61c06d606`,
*"ARM: 9463/1: Allow to enable RT"*). Three follow-up fixes missed 7.2 but landed in
stable **v7.2.6**; verified by bisecting stable tags —
`HAVE_POSIX_CPU_TIMERS_TASK_WORK` is absent in v7.2…v7.2.5 and present in v7.2.6.

One board patch **is** required, in `patches/tib/`: mainline's `rk3288-tinker.dtsi` gives
the wifi `mmc-pwrseq-simple` node no `post-power-on-delay-ms`, which defaults to 0. The
8723ds is then probed before its power rail has settled and SDIO enumerates nothing, so
the board boots with no network at all. A 20ms delay fixes it. `scripts/build/tib-rt.sh`
applies everything in `patches/tib/` and then asserts the property is present in the
BUILT dtb — checking the source is not enough, because a patch applied to a `.dtsi` the
board's `.dtb` does not include would pass every other check and still ship a kernel with
no network.

The real regression risk moving tib from 6.18 to 7.2 is not the device tree
(`rk3288-tinker-s.dts` is byte-identical between v6.18.52 and v7.2.6) but
`drivers/net/ethernet/stmicro/stmmac/dwmac-rk.c`, rewritten wholesale across 7.1/7.2.
That is the one code path that can cost ssh, which is why validation checks the network
first and accepts wlan0 as an independent fallback path.
