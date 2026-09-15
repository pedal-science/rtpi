# rtpi — reproducible PREEMPT_RT kernels for piv (Pi 500) and tib (Tinker Board S)
#
# Safety first: nothing here makes an untested kernel the default. Candidates are always
# staged, tried once, and validated before promotion.

SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

IMAGE   := rtpi-build:latest
VOLUME  := rtpi-src
CCACHE  := rtpi-ccache

.PHONY: help
help: ## Show this help
	@awk 'BEGIN{FS=":.*##"; print "targets:\n"} \
	     /^[a-zA-Z0-9_-]+:.*##/ {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2} \
	     /^## /{printf "\n\033[1m%s\033[0m\n", substr($$0,4)}' $(MAKEFILE_LIST)

## Environment
.PHONY: colima-up
colima-up: ## Start colima sized for kernel builds (8 CPU / 12G / 80G)
	@colima status >/dev/null 2>&1 && echo "colima already running" || \
	  colima start --cpu 8 --memory 12 --disk 80
	@docker info >/dev/null

.PHONY: image
image: colima-up ## Build the arm64 build container
	docker build -t $(IMAGE) docker/

.PHONY: shell
shell: image ## Interactive shell in the build container
	docker run --rm -it -v $(VOLUME):/src -v $(CCACHE):/ccache \
	  -v "$(PWD)":/rtpi:ro $(IMAGE) /bin/bash

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

.PHONY: piv-ubuntu-rt piv-vendor-rt tib-rt
piv-ubuntu-rt: image ## Build an audio-tuned RT kernel from Ubuntu linux-raspi source
	scripts/build/piv-ubuntu-rt.sh
piv-vendor-rt: image ## Build an RT kernel from the raspberrypi/linux tree
	scripts/build/piv-vendor-rt.sh
tib-rt: image ## Build an RT kernel for tib (Armbian edge 7.2.6+, no patches needed)
	scripts/build/tib-rt.sh

## Tests
.PHONY: test-piv test-tib report
test-piv: ## Run the latency + xrun suite on piv
	scripts/test/run-suite.sh piv
test-tib: ## Run the latency + xrun suite on tib
	scripts/test/run-suite.sh tib
report: ## Render a comparison table across all recorded runs
	scripts/test/report.sh
