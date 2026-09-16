# rtpi — reproducible PREEMPT_RT kernels for piv (Pi 500) and tib (Tinker Board S)
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

## tib bring-up — run in this order on a fresh Armbian install

.PHONY: tib-freeze-good
tib-freeze-good: ## 1. Freeze the running kernel as the known-good fallback
	$(SCRIPTS)/deploy/tib-freeze-good.sh

.PHONY: tib-bootscr
tib-bootscr: ## 2. Install the one-shot boot script (reboot after, to bootstrap the env)
	$(SCRIPTS)/deploy/tib-install-bootscr.sh

.PHONY: tib-validate-service
tib-validate-service: ## 3. Install the candidate-boot validate service
	$(SCRIPTS)/deploy/tib-install-validate.sh

.PHONY: tib-install-rt
tib-install-rt: ## 4. Install a built kernel into the candidate slot
	$(SCRIPTS)/deploy/tib-install-rt.sh

.PHONY: tib-try
tib-try: ## 5. Arm the one-shot and reboot into the candidate, watching the result
	@REL=$$(cat build/tib/kernelrelease 2>/dev/null); \
	  [ -n "$$REL" ] || { echo "no build/tib/kernelrelease — build first"; exit 1; }; \
	  ssh tib 'sudo /usr/bin/fw_setenv rt_try 1 && sudo systemctl reboot' || true; \
	  $(SCRIPTS)/safety/watch-reboot.sh tib --expect "$$REL"

## Safety — run these before and around anything risky
.PHONY: backup-piv backup-tib
backup-piv: ## Back up piv boot assets and pull a copy to the Mac
	scripts/safety/backup-boot.sh piv
backup-tib: ## Back up tib boot assets + U-Boot env region to the Mac
	scripts/safety/backup-boot.sh tib

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

.PHONY: status-piv status-tib
status-piv: ## Show piv A/B slot state
	scripts/safety/status.sh piv
status-tib: ## Show tib slot + U-Boot env state
	scripts/safety/status.sh tib

.PHONY: watch-piv watch-tib
watch-piv: ## Watch piv through a reboot, report which kernel returned
	scripts/safety/watch-reboot.sh piv
watch-tib: ## Watch tib through a reboot, report which kernel returned
	scripts/safety/watch-reboot.sh tib

.PHONY: panic-piv panic-tib
panic-piv: ## Restore piv to its known-good kernel
	scripts/safety/panic-button.sh piv
panic-tib: ## Restore tib to its known-good kernel
	scripts/safety/panic-button.sh tib

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

.PHONY: piv-ubuntu-rt piv-vendor-rt tib-rt
piv-ubuntu-rt: image ## Build an audio-tuned RT kernel from Ubuntu linux-raspi source
	scripts/build/piv-ubuntu-rt.sh
piv-vendor-rt: image ## Build an RT kernel from the raspberrypi/linux tree
	scripts/build/piv-vendor-rt.sh
tib-rt: image ## Build an RT kernel for tib (mainline 7.2.6 + patches/tib)
	scripts/build/tib-rt.sh

## Tests
.PHONY: test-piv test-tib report
test-piv: ## Run the latency + xrun suite on piv
	scripts/test/run-suite.sh piv
test-tib: ## Run the latency + xrun suite on tib
	scripts/test/run-suite.sh tib
report: ## Render a comparison table across all recorded runs
	scripts/test/report.sh
