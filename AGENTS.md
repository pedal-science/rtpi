# rtpi

Reproducible PREEMPT_RT kernels for low-latency audio on piv (Raspberry Pi 500, arm64) and
`tib` (ASUS Tinker Board S, RK3288, armhf), with automatic rollback so a bad kernel can never
cost remote access. It also holds each board's device facts and deployed config under
`devices/<host>/`.

## Commands

`make help` lists every target. The common ones:

```sh
make backup-tib            # always first, before changing a board (same for piv)
make status-tib            # slot and U-Boot env state
make tib-rt                # build tib's kernel in the container (mainline 7.2.6 + patches/tib)
make tib-install-rt        # install a built kernel into the candidate slot
make tib-try               # arm the one-shot, reboot into the candidate, watch it
make panic-tib             # restore the known-good kernel
make test-tib              # latency and xrun suite; results go to results/
```

## Constraints

- **Never risk remote access.** Every kernel goes through the candidate slot (U-Boot one-shot
  on `tib`, `tryboot` on piv). Do not install over the known-good kernel, and back up first.
- **If a board does not come back, read RECOVERY in `README.md` before doing anything.**
- **`tib` is not a Raspberry Pi.** No `config.txt`, no Pi overlays. Its device tree changes
  (the WM8960 audio card, the UART) belong here.
- **Cap `tib`'s clock for sustained runs** (1416 MHz). Uncapped, it hits the thermal trip.
- **vip** (Raspberry Pi 5, the pedal's Core host) is built from an image, not upgraded with apt:
  no flash-kernel, no piboot-try. `devices/vip/usr/local/sbin/vip-boot` selects its kernel slot,
  profile and root; `tests/vip-boot` tests it off the board
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

System context (the pedal, how the repos fit together, the plan): `~/code.local/pedal/pedal.project`, starting at its `CLAUDE.md` and `docs/working-across-repos.md`.
