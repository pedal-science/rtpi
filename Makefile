# rtpi — reproducible PREEMPT_RT kernels for piv (Pi 500) and vip (Pi 5, the Core host)
#
# Safety first: nothing here makes an untested kernel the default. Candidates are always
# staged, tried once, and validated before promotion.

SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

IMAGE   := rtpi-build:latest
VOLUME  := rtpi-src
CCACHE  := rtpi-ccache
SCRIPTS := scripts

.PHONY: help
help: ## Show this help
	@awk 'BEGIN{FS=":.*##"; print "targets:\n"} \
	     /^[a-zA-Z0-9_-]+:.*##/ {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2} \
	     /^## /{printf "\n\033[1m%s\033[0m\n", substr($$0,4)}' $(MAKEFILE_LIST)

## Environment
.PHONY: colima-up
colima-up: ## Start colima sized for kernel builds (6 CPU / 8G)
	@# 8G of the Mac's 16G, and 6 of 8 CPUs. The original 12G left macOS 4G and would have
	@# swapped -- which on a build this I/O-heavy costs more than the extra RAM gains.
	@# Disk is whatever the profile was created with; colima cannot shrink it in place.
	@colima status >/dev/null 2>&1 && echo "colima already running" || \
	  colima start --cpu 6 --memory 8
	@docker info >/dev/null

.PHONY: image
image: colima-up ## Build the arm64 build container
	docker build -t $(IMAGE) docker/

.PHONY: shell
shell: image ## Interactive shell in the build container
	docker run --rm -it -v $(VOLUME):/src -v $(CCACHE):/ccache \
	  -v "$(PWD)":/rtpi:ro $(IMAGE) /bin/bash

## Safety — run these before and around anything risky
.PHONY: backup-piv
backup-piv: ## Back up piv boot assets and pull a copy to the Mac
	scripts/safety/backup-boot.sh piv

.PHONY: preflight-piv
preflight-piv: ## Check piv is safe to stage a candidate onto
	scripts/safety/preflight.sh piv

.PHONY: harden-piv
harden-piv: ## Install validate hook, watchdog + dracut drop-ins on piv
	scripts/deploy/harden-piv.sh

.PHONY: hold-piv unhold-piv
hold-piv: ## Stop unattended-upgrades touching kernel/initramfs on piv
	scripts/safety/hold-packages.sh piv hold
unhold-piv: ## Undo hold-piv
	scripts/safety/hold-packages.sh piv unhold

.PHONY: status-piv
status-piv: ## Show piv A/B slot state
	scripts/safety/status.sh piv

.PHONY: watch-piv
watch-piv: ## Watch piv through a reboot, report which kernel returned
	scripts/safety/watch-reboot.sh piv

.PHONY: panic-piv
panic-piv: ## Restore piv to its known-good kernel
	scripts/safety/panic-button.sh piv

## Rehearsals — prove the rollback works BEFORE trusting it with a real RT kernel
.PHONY: rehearse-piv-success rehearse-piv-failure
rehearse-piv-success: ## Prove tryboot->validate->promote works with a known-good kernel
	scripts/safety/rehearse-piv.sh success
rehearse-piv-failure: ## Prove automatic fallback works with a deliberately broken kernel
	scripts/safety/rehearse-piv.sh failure

## Kernels
.PHONY: piv-apt-rt
piv-apt-rt: ## Install Ubuntu's linux-raspi-realtime on piv via the tryboot path
	scripts/deploy/piv-apt-rt.sh

## pro — the x86 Core host for the bigger case. GRUB, not the Pi firmware: its one-shot boot
## (grub-reboot) is what a trial rides on, so there are no kernel slots to manage.
.PHONY: backup-pro preflight-pro status-pro hold-pro unhold-pro
backup-pro: ## Back up pro's GRUB config, grubenv, EFI boot order and BIOS settings
	$(SCRIPTS)/safety/backup-boot.sh pro
preflight-pro: ## Check pro is safe to try a kernel on (grubenv writable, fallback present, …)
	$(SCRIPTS)/safety/preflight.sh pro
status-pro: ## Show pro's boot entries, default, trial and isolation
	$(SCRIPTS)/safety/status.sh pro
hold-pro: ## Stop apt replacing pro's kernel, initramfs or GRUB
	$(SCRIPTS)/safety/hold-packages.sh pro hold
unhold-pro: ## Undo hold-pro
	$(SCRIPTS)/safety/hold-packages.sh pro unhold

.PHONY: harden-pro harden-pro-watchdog
harden-pro: ## 1. Install pro-boot, the pedal's GRUB entries and the fallback machinery
	$(SCRIPTS)/deploy/harden-pro.sh
harden-pro-watchdog: ## As harden-pro, and arm the chipset watchdog (off by default: see device.env)
	$(SCRIPTS)/deploy/harden-pro.sh --watchdog

.PHONY: pro-rt
pro-rt: ## 2. Install Ubuntu's amd64 realtime kernel (not booted)
	$(SCRIPTS)/deploy/pro-rt.sh

.PHONY: pro-try
pro-try: ## 3. Try that kernel with the isolation arguments for one boot, and watch it
	@REL=$$(sed -n 's/^PEDAL_KERNEL=//p' devices/pro/device.env | tr -d '"'); \
	  ARGS=$$(sed -n 's/^AUDIO_TUNING_ARGS=//p' devices/pro/device.env | tr -d '"'); \
	  echo "trying $$REL with: $$ARGS"; \
	  : "pro-boot reboots at the end, which closes the connection and makes ssh exit 255. That"; \
	  : "is the success path, so the exit status cannot be the test — it failed the whole target"; \
	  : "on a trial that had armed correctly (2026-11-01). watch-reboot is the test instead: its"; \
	  : "first phase fails with 'device never went down' when nothing was actually armed."; \
	  ssh pro "sudo -n pro-boot try --kernel $$REL --args '$$ARGS'" || true; \
	  sleep 5; \
	  $(SCRIPTS)/safety/watch-reboot.sh pro --expect "$$REL"

.PHONY: pro-loose pro-stock
pro-loose: ## Boot pro once with no isolation and no engine (the loose profile)
	ssh pro sudo -n pro-boot loose
pro-stock: ## Make Ubuntu's own stock-kernel entry the default again
	ssh pro sudo -n pro-boot default stock

.PHONY: rehearse-pro-failure
rehearse-pro-failure: ## Prove the fallback: try a deliberately broken boot line and watch it return
	$(SCRIPTS)/safety/rehearse-pro.sh

## vip — the pedal Core host: rebuild its Ubuntu kernel with NUMA emulation and patches/vip/
.PHONY: vip-rt
vip-rt: ## 1. Build vip's pedal kernel (stock baseline + the fragment) into build/vip
	$(SCRIPTS)/build/vip-ubuntu-rt.sh

.PHONY: vip-install-rt
vip-install-rt: ## 2. Install it into the running pedal root, beside the stock kernel
	$(SCRIPTS)/deploy/vip-install-rt.sh

.PHONY: vip-try
vip-try: ## 3. Stage the candidate slot, reboot once, watch validation promote or roll back
	@REL=$$(cat build/vip/kernelrelease 2>/dev/null); \
	  [ -n "$$REL" ] || { echo "no build/vip/kernelrelease — build and install first"; exit 1; }; \
	  ssh vip 'sudo vip-boot try-kernel '"$$REL" || exit 1; \
	  $(SCRIPTS)/safety/watch-reboot.sh vip --expect "$$REL"

## piv audio tuning — the runtime half is safe to apply any time; the boot half reboots
.PHONY: piv-audio-tune
piv-audio-tune: ## 1. Install + apply IRQ pinning and priority (runtime only, reverts on reboot)
	scripts/deploy/piv-audio-tune.sh --apply-now

.PHONY: piv-audio-boot-args
piv-audio-boot-args: ## 2. Stage the running kernel with CPU isolation and try it via tryboot
	@REL=$$(ssh piv uname -r); \
	  echo "staging $$REL as a candidate with AUDIO_TUNING_ARGS"; \
	  ssh piv "sudo flash-kernel $$REL" && \
	  scripts/safety/arm-try-piv.sh --expect "$$REL" --realtime --audio-tuning --reboot && \
	  scripts/safety/watch-reboot.sh piv --expect "$$REL"

.PHONY: piv-audio-status
piv-audio-status: ## Show whether the audio tuning is actually in force on piv
	@ssh piv 'echo "cmdline tuning : $$(grep -o "isolcpus=[^ ]*" /proc/cmdline || echo NONE)"; \
	          echo "isolated cpus  : $$(cat /sys/devices/system/cpu/isolated)"; \
	          echo "nohz_full cpus : $$(cat /sys/devices/system/cpu/nohz_full)"; \
	          grep -E "xhci-hcd:usb2" /proc/interrupts; \
	          ps -eLo tid,psr,cls,rtprio,comm= | grep "irq/.*xhci-hcd:usb2"'

# The small route for the boot half: one file, no kernel staged, and no candidate behind the
# change -- that is `piv-audio-boot-args` above, which is the one to use for an argument set
# that has not been booted before. Like piv-boot set-args itself, these show what they would do
# until given --yes; the reboot is then a separate, deliberate act.
.PHONY: piv-boot-status piv-boot-args
piv-boot-status: ## Show piv's card, running and proposed command lines (writes nothing)
	@ssh piv sudo piv-boot status
piv-boot-args: ## Rewrite the ACTIVE cmdline.txt from AUDIO_TUNING_ARGS (shows the diff; add ARGS to write)
	@ssh piv sudo piv-boot set-args $(ARGS)

.PHONY: piv-ubuntu-rt piv-vendor-rt
piv-ubuntu-rt: image ## Build an audio-tuned RT kernel from Ubuntu linux-raspi source
	scripts/build/piv-ubuntu-rt.sh
piv-vendor-rt: image ## Build an RT kernel from the raspberrypi/linux tree
	scripts/build/piv-vendor-rt.sh

## Tests
.PHONY: test-tools test-piv report
test-tools: ## Run the off-board suites (vip-boot, piv-boot, pro-boot) — no board is touched
	@python3 -m unittest discover -s tests/vip-boot
	@python3 -m unittest discover -s tests/piv-boot
	@python3 -m unittest discover -s tests/pro-boot
test-piv: ## Run the latency + xrun suite on piv
	scripts/test/run-suite.sh piv
report: ## Render a comparison table across all recorded runs
	scripts/test/report.sh
