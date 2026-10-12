# rtpi

Reproducible PREEMPT_RT kernels for low-latency audio on `piv` (Raspberry Pi 500, arm64, the
bench stand-in) and `vip` (Raspberry Pi 5, arm64, the pedal's Core host), with automatic
rollback so a bad kernel can never cost remote access. It also holds each board's device
facts and deployed config under `devices/<host>/`.

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
- **vip's kernel is Ubuntu's raspi RT build plus `config/` fragments, and today no patches.** The
  first candidate change — StarFive's fix for the RP1 audio DMA starting a transfer while the
  channel is still non-idle, which is what kills an `arecord` capture on vip with
  `pcm_read: Input/output error` — is recorded in `README.md`, "vip's kernel: the first candidate
  change", with the evidence, the two other patches in the same code, and what carrying it would
  take.
- **piv's designed route for an arguments change is the tryboot one-shot**:
  `scripts/safety/arm-try-piv.sh --expect <release> --audio-tuning` (`make piv-audio-boot-args`)
  stages `current/` as a candidate in `new/` with the tuned arguments, boots it once and falls back
  by itself. The smaller route is `devices/piv/usr/local/sbin/piv-boot set-args`, which rewrites the
  command line the firmware actually reads — `config.txt`'s `os_prefix` for a normal boot, so
  `/boot/firmware/current/cmdline.txt`, never a `cmdline.txt` left at the root of the boot
  partition — with `AUDIO_TUNING_ARGS` from `devices/piv/device.env`, keeping every other argument
  and the line it replaced; a tuning this boot has not run takes `--write-active-line` as well as
  `--yes`, because that line has not been booted; `--restore` puts that line back; `tests/piv-boot`
  tests it off the board
  (`python3 -m unittest discover -s tests/piv-boot`). It edits the *active* line in place, with no
  candidate behind it and no automatic fallback, which is why an untested change goes through
  tryboot instead. A new kernel still goes through tryboot as before.

System context (the pedal, how the repos fit together, the plan): `~/code.local/pedal/pedal.project`, starting at its `CLAUDE.md` and `docs/working-across-repos.md`.
