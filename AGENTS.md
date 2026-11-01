# rtpi

PREEMPT_RT kernels and boot safety for the pedal's hosts, with automatic rollback so a bad kernel
can never cost remote access. It holds each host's device facts and deployed boot config under
`devices/<host>/`.

| Host | What it is | Its kernel | Its boot |
|---|---|---|---|
| `vip` | Raspberry Pi 5, arm64, the pedal's Core host | Ubuntu's raspi RT build, **rebuilt here** (`CONFIG_NUMA_EMU`, a module trim, an RP1 DMA patch) | the Pi firmware's `tryboot`, two FAT kernel slots, a rescue root — `vip-boot` |
| `piv` | Raspberry Pi 500, arm64, the bench stand-in and build host | Ubuntu's `linux-raspi-realtime` from apt | `piboot-try` plus `tryboot` |
| `pro` | HP ProDesk 600 G5 Mini, **x86-64**, the Core host for the bigger case | Ubuntu's **signed** amd64 `realtime` flavour from apt, **not rebuilt** (Secure Boot is on, and the flavour already has everything `config/audio-rt-common.fragment` asks for) | GRUB: `grub-reboot`'s one-shot and `GRUB_DEFAULT=saved` — `pro-boot` |

## Commands

`make help` lists every target. The common ones:

```sh
make backup-piv            # always first, before changing a board
make status-piv            # slot state
make piv-audio-tune        # runtime half of the audio profile; reverts on reboot
make piv-audio-boot-args   # boot half (CPU isolation), tried through tryboot
make vip-rt                # build vip's kernel in the container (stock baseline + fragment)
make vip-install-rt        # install it beside the stock kernel in the running pedal root
make vip-try               # stage the candidate slot, reboot once, watch it promote or roll back
make test-piv              # latency and xrun suite; results go to results/

make backup-pro            # pro: GRUB config, grubenv, EFI boot order, BIOS settings
make harden-pro            # pro: 1. pro-boot, the pedal's GRUB entries, the fallback machinery
make rehearse-pro-failure  # pro: prove the fallback with a trial that is meant to fail
make pro-rt                # pro: 2. install Ubuntu's amd64 realtime kernel (not booted)
make pro-try               # pro: 3. try it with isolation for one boot, and watch it
make pro-stock             # pro: go back to Ubuntu's own stock-kernel entry
```

## Constraints

- **Never risk remote access.** Every kernel goes through a candidate slot (`tryboot` on piv,
  `vip-boot try-kernel` on vip). Do not install over the known-good kernel, and back up first.
- **If a board does not come back, read RECOVERY in `README.md` before doing anything.**
- **Device-tree changes belong here**, not in a distro package: they are what makes the WM8960
  audio card and the UART work on these boards.
- **vip** (Raspberry Pi 5, the pedal's Core host) is built from an image, not upgraded with apt:
  no flash-kernel, no piboot-try. `devices/vip/usr/local/sbin/vip-boot` selects its kernel slot,
  profile and root, and `try-config` gives a running board a `config.txt` line the same way (the
  pedal's `config.txt` is written once, at card build): tried once in the spare slot, promoted by
  validation into `profile.txt`, kept through later kernel trials, taken away with `drop-config`;
  `tests/vip-boot` tests it off the board
  (`python3 -m unittest discover -s tests/vip-boot`, on Linux). The card layout and the reasons
  are in pedal.project's `docs/vip-image.md`.
  `devices/vip/dt/` holds device-tree overlays the boot partition has to carry, because the
  firmware applies those from `config.txt` before any driver probes: today
  `rp1-i2c1-recovery.dts`, which gives the I2C1 controller the `scl-gpios`/`sda-gpios` its driver
  needs to free a stuck bus (vip had none, so a bus held low needed a reboot — pedal.project
  `bench-results/2026-10-06-codec-i2c-reads-and-the-sda-hold-time.md`). `vip-boot init-pedal-boot`
  and `init-rescue-boot` compile every `.dts` there into each boot tree's `overlays/` and write the
  matching `dtoverlay=` lines, so the files and the config cannot disagree; a `.dts` that will not
  compile stops the build. `dtc` is in the build container for that.
- On piv: no custom kernel flavour names, no `threadirqs` on an RT kernel,
  `RT_GROUP_SCHED` off. `README.md` "Things that will bite you" says why.
- **pro** (x86-64, UEFI, Secure Boot on) takes the **stock signed** `realtime` package and is never
  rebuilt here: an unsigned kernel would not load. Its one-shot is GRUB's, which works only because
  `/boot` is a plain partition — on LVM or RAID, GRUB cannot write `grubenv`, `grub-reboot` would
  silently do nothing, and a trial would become permanent. `pro-boot` reads `next_entry` back after
  arming for exactly that reason, and `preflight.sh pro` checks it too.
  **Run `harden-pro` before `pro-rt`:** with Ubuntu's `GRUB_DEFAULT=0`, merely installing a newer
  kernel changes what the machine boots, because `10_linux` writes its "Ubuntu" entry for the newest
  one it finds. `devices/pro/etc/default/grub.d/90-rtpi.cfg` pins that entry to the stock kernel and
  makes the default a named entry instead of a menu position.
  pro's watchdog is **off by default**, unlike vip's: `devices/pro/device.env` says why, and
  `harden-pro --watchdog` opts in. So a kernel that wedges before systemd starts needs a power cycle
  there; everything after systemd starts is covered.
- **vip's kernel is Ubuntu's raspi RT build plus `config/` fragments and `patches/vip/`.** The
  first patch is StarFive's fix for the RP1 audio DMA starting a transfer while the channel is
  still non-idle, which is what kills an `arecord` capture on vip with
  `pcm_read: Input/output error`. `README.md`, "vip's kernel: the first candidate change", has the
  evidence and the two other patches in the same code that this tree does not carry. A trial uses
  its own `--localversion` and `make vip-try`.
- **piv's designed route for an arguments change is the tryboot one-shot**:
  `scripts/safety/arm-try-piv.sh --expect <release> --audio-tuning` (`make piv-audio-boot-args`)
  stages `current/` as a candidate in `new/` with the tuned arguments, boots it once and falls back
  by itself. A new kernel always goes this way.
- **The smaller route, `devices/piv/usr/local/sbin/piv-boot set-args`, has no fallback.** It edits the
  *active* command line in place, with `AUDIO_TUNING_ARGS` from `devices/piv/device.env`, keeping
  every other argument and the line it replaced (`--restore` puts that back). The active line is the
  one `config.txt`'s `os_prefix` points at on a normal boot, `/boot/firmware/current/cmdline.txt` — never a
  `cmdline.txt` at the root of the boot partition. A tuning this boot has not run needs
  `--write-active-line` as well as `--yes`, because that line has never been booted. So an untested
  change goes through tryboot instead. Tests: `python3 -m unittest discover -s tests/piv-boot`.

System context (the pedal, how the repos fit together, the plan): `~/code.local/pedal/pedal.project`, starting at its `AGENTS.md` and `docs/working-across-repos.md`.
