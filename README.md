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

## Things that will bite you

### `unattended-upgrades` re-runs flash-kernel behind your back

Observed live on 2026-09-15 06:37: it upgraded **dracut** — not a kernel. Regenerating
the initramfs fired `/etc/initramfs/post-update.d/flash-kernel`, which ran the `pi-try`
method, which does `rm -rf old new` when `old/` exists. That **destroyed the rollback
slot** and staged an unrequested candidate. If it happens while an RT candidate is
staged, your candidate is silently replaced mid-test.

`make hold-piv` holds the kernel *and* the initramfs generators. `make unhold-piv` undoes it.

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

So, once, over the serial console, at the U-Boot prompt:

```
=> saveenv
```

That persists the complete current environment. Then verify from Linux:

```bash
sudo fw_printenv | head            # should list ~27 variables including bootcmd
make status-tib                    # decodes and CRC-checks the region
```

`scripts/safety/preflight.sh tib` refuses to proceed until this reports VALID.

## Serial console

One **FTDI TTL-232R-3V3** cable per board is all you need. (The Raspberry Pi Debug Probe
adds nothing here.)

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

1. **Power-cycle once.** The one-shot flag is cleared before the candidate boots, so a
   cold boot uses the frozen known-good slot.
2. **Serial console** (pins 32/33/34, 115200). Interrupt U-Boot (`BOOTDELAY=1`, so be
   quick) and boot known-good by hand:
   ```
   => setenv rt_try 0
   => saveenv
   => boot
   ```
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
5. **Swap in the spare SD card.** This is the floor: it always works.

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
`HAVE_POSIX_CPU_TIMERS_TASK_WORK` is absent in v7.2…v7.2.5 and present in v7.2.6. Armbian's
`edge` branch tracks `branch:linux-7.2.y`, so **no patches are needed**.

The real regression risk moving tib from 6.18 to 7.2 is not the device tree
(`rk3288-tinker-s.dts` is byte-identical between v6.18.52 and v7.2.6) but
`drivers/net/ethernet/stmicro/stmmac/dwmac-rk.c`, rewritten wholesale across 7.1/7.2.
That is the one code path that can cost ssh, which is why validation checks the network
first and accepts wlan0 as an independent fallback path.
