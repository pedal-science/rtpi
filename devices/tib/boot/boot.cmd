# Armbian boot script for tinkerboard (rk3288), MODIFIED by rtpi to add a
# self-clearing one-shot candidate boot.
#
# Base: upstream config/bootscripts/boot-rockchip.cmd (byte-identical to the stock
# /boot/boot.cmd on this device). Four marked rtpi regions are added, and every path that
# upstream writes as ${prefix}dtb is retargeted to ${rtpi_dtb} so that the chosen slot is
# self-contained -- including the OVERLAY paths, which are marked inline below.
#
# WHAT THIS GIVES US
# The Raspberry Pi has a firmware "tryboot" flag that is one-shot: it is cleared BEFORE
# the firmware starts, so any crash, reset or power cycle returns to the known-good
# config. RK3288 U-Boot has no such thing, so we build the equivalent out of the U-Boot
# environment:
#
#   default              -> boot the FROZEN known-good kernel (*-good)
#   rt_try=1 in the env  -> clear the flag, PERSIST the clear, verify it persisted,
#                           and only then boot the candidate
#
# The flag is cleared BEFORE the risky kernel runs, so if the candidate hangs, the next
# boot (after a watchdog reset or a power cycle) finds rt_try=0 and boots known-good.
#
# NOTE ON WHICH IS WHICH: the *candidate* is the normal Armbian zImage/uInitrd/dtb
# symlinks, because Armbian's own postinst keeps those pointing at the newest installed
# kernel. The *known-good* is a frozen copy we make ourselves (*-good). That inversion
# means a routine Armbian kernel upgrade can never silently become the default boot.
#
# Compile with:
#   mkimage -C none -A arm -T script -d /boot/boot.cmd /boot/boot.scr

# ==================== rtpi region 1 of 4: bootstrap the environment ====================
# This board has NEVER run saveenv: the env region (0x3f8000, 0x8000 bytes) is all zeros
# with a zero CRC, so U-Boot is running on its compiled-in defaults.
#
# That is a trap for the Linux side. libubootenv's fw_setenv has no built-in defaults --
# it reads /etc/u-boot-initial-env, which does not exist here -- so the FIRST fw_setenv
# would write a valid-CRC environment containing ONLY the variable it was asked to set,
# destroying bootcmd and stopping the board booting.
#
# saveenv from inside U-Boot has no such problem: it serialises the CURRENT in-memory
# environment -- the complete working environment U-Boot booted with. So we do the
# bootstrap here, from the boot script, and NO SERIAL CONSOLE is required for it.
#
# Confirmed against this board's own U-Boot config, shipped at
# /usr/lib/u-boot/tinker-s-rk3288_defconfig by linux-u-boot-tinkerboard-current:
#   CONFIG_ENV_IS_IN_MMC=y   CONFIG_CMD_SAVEENV=y
#   CONFIG_ENV_MMC_DEVICE_INDEX=1   <- U-Boot mmc1 is the SD card, so saveenv and
#                                      fw_setenv write the SAME region
#   CONFIG_ENV_OFFSET=0x3f8000   CONFIG_ENV_SIZE=0x8000
#
# Deliberately the FIRST thing the script does: before our own setenv defaults below and
# before the armbianEnv.txt import, so what gets persisted is the environment U-Boot
# itself booted with plus rt_try -- not this script's working variables, and not a copy of
# armbianEnv.txt, which is re-imported from the filesystem on every boot anyway.
#
# Runs once: after this, rt_try is defined, so the test is false on every later boot.
# If saveenv fails we carry on regardless -- the env simply stays unwritten, U-Boot keeps
# using its defaults, and the board still boots. The Linux side must NOT assume this
# worked: verify with scripts/safety/decode-uboot-env.py before ever calling fw_setenv.
if test "${rt_try}" = ""; then
	echo "rtpi: no rt_try in environment - bootstrapping a full env with saveenv"
	setenv rt_try 0
	if saveenv; then
		echo "rtpi: environment bootstrapped; fw_setenv is now safe to use"
	else
		echo "rtpi: saveenv FAILED - env still unwritten, do NOT use fw_setenv"
	fi
fi
# ==================== end rtpi region 1 of 4 ====================

setenv ramdisk_addr_r "0x21000000"
setenv load_addr "0x39000000"
setenv overlay_error "false"
# default values
setenv rootdev "/dev/mmcblk0p1"
setenv verbosity "1"
setenv console "both"
setenv bootlogo "false"
setenv rootfstype "ext4"
setenv docker_optimizations "on"
setenv earlycon "off"

echo "Boot script loaded from ${devtype} ${devnum}"

if test -e ${devtype} ${devnum} ${prefix}armbianEnv.txt; then
	load ${devtype} ${devnum} ${load_addr} ${prefix}armbianEnv.txt
	env import -t ${load_addr} ${filesize}
fi

# ==================== rtpi region 2 of 4: choose the slot ====================
# Default to the frozen known-good slot. Every failure path below leaves these alone,
# so anything unexpected fails SAFE.
setenv rtpi_krn "${prefix}zImage-good"
setenv rtpi_ird "${prefix}uInitrd-good"
setenv rtpi_dtb "${prefix}dtb-good"
setenv rtpi_slot "known-good"

if test "${rt_try}" = "1"; then
	echo "rtpi: one-shot candidate boot requested (rt_try=1)"

	# Clear the flag FIRST and persist it. If this does not stick, we must NOT boot the
	# candidate — otherwise a candidate that hangs would be retried forever.
	setenv rt_try 0
	if saveenv; then
		echo "rtpi: flag cleared and saved; verifying it persisted..."

		# Verify by re-reading the env region straight off the SD card and importing
		# ONLY rt_try from it. mmc dev 1 is the SD card: U-Boot's rk3288-u-boot.dtsi
		# overrides the aliases to mmc0=&emmc, mmc1=&sdmmc (corroborated by the built-in
		# boot_targets="mmc1 mmc0 ..."). Env is at 0x3f8000 = LBA 0x1fc0, 0x8000 bytes
		# = 0x40 blocks, which is the 32KB gap ending exactly at partition 1 (LBA 8192).
		# "env import -c" CRC-validates the image, and naming rt_try imports only that
		# one variable, so a corrupt or unexpected env cannot inject anything else.
		mmc dev 1
		if mmc read ${load_addr} 0x1fc0 0x40; then
			if env import -c ${load_addr} 0x8000 rt_try; then
				if test "${rt_try}" = "0"; then
					setenv rtpi_krn "${prefix}zImage"
					setenv rtpi_ird "${prefix}uInitrd"
					setenv rtpi_dtb "${prefix}dtb"
					setenv rtpi_slot "CANDIDATE"
				else
					echo "rtpi: readback says rt_try=${rt_try}, expected 0 - booting known-good"
				fi
			else
				echo "rtpi: env readback failed CRC - booting known-good"
			fi
		else
			echo "rtpi: mmc read of env region failed - booting known-good"
		fi
	else
		echo "rtpi: saveenv FAILED - refusing to boot candidate, booting known-good"
	fi
fi

echo "rtpi: booting slot: ${rtpi_slot}  (${rtpi_krn})"
# ==================== end rtpi region 2 of 4 ====================

if test "${logo}" = "disabled"; then setenv logo "logo.nologo"; fi

# Tinkerboard walkaround.
if test "${console}" = "ttyS2,115200n8"; then setenv console "both"; fi
if test "${console}" = "display" || test "${console}" = "both"; then setenv consoleargs "console=tty1"; fi
if test "${console}" = "serial" || test "${console}" = "both"; then setenv consoleargs "console=ttyS2,115200n8 ${consoleargs}"; fi
if test "${earlycon}" = "on"; then setenv consoleargs "earlycon ${consoleargs}"; fi
if test "${bootlogo}" = "true"; then
	setenv consoleargs "splash plymouth.ignore-serial-consoles ${consoleargs}"
else
	setenv consoleargs "splash=verbose ${consoleargs}"
fi

# get PARTUUID of first partition on SD/eMMC the boot script was loaded from
if test "${devtype}" = "mmc"; then part uuid mmc ${devnum}:1 partuuid; fi

setenv bootargs "earlyprintk root=${rootdev} rootwait rootfstype=${rootfstype} ${consoleargs} consoleblank=0 loglevel=${verbosity} ubootpart=${partuuid} usb-storage.quirks=${usbstoragequirks} ${extraargs} ${extraboardargs}"

if test "${docker_optimizations}" = "on"; then setenv bootargs "${bootargs} cgroup_enable=cpuset cgroup_memory=1 cgroup_enable=memory"; fi

if test "${board}" = "miqi_rk3288"; then setenv fdtfile "rk3288-miqi.dtb"; fi

# ==================== rtpi region 3 of 4: load from the chosen slot ====================
# Upstream loads ${prefix}uInitrd / ${prefix}zImage / ${prefix}dtb/${fdtfile} directly.
# We load from the slot selected above instead.
load ${devtype} ${devnum} ${ramdisk_addr_r} ${rtpi_ird}
load ${devtype} ${devnum} ${kernel_addr_r} ${rtpi_krn}

load ${devtype} ${devnum} ${fdt_addr_r} ${rtpi_dtb}/${fdtfile}
# ==================== end rtpi region 3 of 4 ====================
fdt addr ${fdt_addr_r}
fdt resize 65536
for overlay_file in ${overlays}; do
	# rtpi: ${rtpi_dtb}, not ${prefix}dtb. Upstream takes overlays from the live dtb
	# directory, which Armbian's postinst repoints at the newest installed kernel. Left
	# alone, a fallback boot would apply the CANDIDATE's overlays to the known-good DTB --
	# so once the candidate is a 7.2 kernel, every fallback would be mixing 7.2 overlays
	# into a 6.18 device tree. It fails safe (overlay_error restores the slot DTB) but
	# fails safe means losing i2c1/i2c4/spi2/spidev2/uart1/uart2. The fallback path is the
	# one that must never be fragile, so each slot uses its own overlays.
	if load ${devtype} ${devnum} ${load_addr} ${rtpi_dtb}/overlay/${overlay_prefix}-${overlay_file}.dtbo; then
		echo "Applying kernel provided DT overlay ${overlay_prefix}-${overlay_file}.dtbo"
		fdt apply ${load_addr} || setenv overlay_error "true"
	fi
done
for overlay_file in ${user_overlays}; do
	if load ${devtype} ${devnum} ${load_addr} ${prefix}overlay-user/${overlay_file}.dtbo; then
		echo "Applying user provided DT overlay ${overlay_file}.dtbo"
		fdt apply ${load_addr} || setenv overlay_error "true"
	fi
done
if test "${overlay_error}" = "true"; then
	echo "Error applying DT overlays, restoring original DT"
	# ============= rtpi region 4 of 4: restore from the chosen slot =============
	load ${devtype} ${devnum} ${fdt_addr_r} ${rtpi_dtb}/${fdtfile}
	# ============= end rtpi region 4 of 4 =============
else
	# rtpi: from the chosen slot, for the same reason as the overlays above.
	if load ${devtype} ${devnum} ${load_addr} ${rtpi_dtb}/overlay/${overlay_prefix}-fixup.scr; then
		echo "Applying kernel provided DT fixup script (${overlay_prefix}-fixup.scr)"
		source ${load_addr}
	fi
	if test -e ${devtype} ${devnum} ${prefix}fixup.scr; then
		load ${devtype} ${devnum} ${load_addr} ${prefix}fixup.scr
		echo "Applying user provided fixup script (fixup.scr)"
		source ${load_addr}
	fi
fi

bootz ${kernel_addr_r} ${ramdisk_addr_r} ${fdt_addr_r}

# Recompile with:
# mkimage -C none -A arm -T script -d /boot/boot.cmd /boot/boot.scr
