#!/usr/bin/env bash
# Shared helpers. Source this, do not execute it.
#
# Every script that can touch a device sources this and uses its guards. The guards
# exist because a mistake here costs ssh access to a machine we cannot physically
# reach quickly.

set -euo pipefail

RTPI_ROOT="${RTPI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# Consistent ssh behaviour everywhere: never prompt, fail fast, survive a slow boot.
SSH_OPTS=(
  -o BatchMode=yes
  -o ConnectTimeout=10
  -o ServerAliveInterval=5
  -o ServerAliveCountMax=3
  -o StrictHostKeyChecking=accept-new
)

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }
ok()   { printf '\033[1;32m[✓]\033[0m %s\n' "$*" >&2; }

# load_device <name> — source devices/<name>/device.env into the environment.
load_device() {
  local name="$1"
  local env_file="$RTPI_ROOT/devices/$name/device.env"
  [[ -f $env_file ]] || die "no such device: $name (expected $env_file)"
  # shellcheck disable=SC1090
  source "$env_file"
  : "${SSH_HOST:?device.env must set SSH_HOST}"
}

# dev_ssh <cmd...> — run a command on the loaded device.
dev_ssh() { ssh "${SSH_OPTS[@]}" "$SSH_HOST" "$@"; }

# dev_ssh_quiet <cmd...> — as above but swallow output; returns the exit status.
dev_ssh_quiet() { ssh "${SSH_OPTS[@]}" "$SSH_HOST" "$@" >/dev/null 2>&1; }

# require_ssh — fail early and clearly rather than half-way through a risky sequence.
require_ssh() {
  dev_ssh_quiet true \
    || die "cannot ssh to $SSH_HOST. If the 1Password agent is locked, unlock it
         (check with: ssh-add -l)."
}

# --- Safety guards -----------------------------------------------------------------
# Each of these enforces one rule from the plan. They are cheap; call them liberally.

# guard_stock_kernel_installed — refuse to proceed if the fallback kernel is gone.
# Without a known-good kernel installed there is nothing to roll back TO.
guard_stock_kernel_installed() {
  : "${STOCK_KERNEL:?}"
  local found
  found=$(dev_ssh "ls /boot/vmlinuz-$STOCK_KERNEL /boot/firmware/current/vmlinuz 2>/dev/null | head -1" || true)
  [[ -n $found ]] \
    || die "stock kernel $STOCK_KERNEL is not installed on $SSH_HOST — refusing to continue.
         There would be nothing to fall back to."
  ok "fallback kernel present ($STOCK_KERNEL)"
}

# guard_boot_space <mount> <min_mb> — a half-written candidate is worse than none.
guard_boot_space() {
  local mount="${1:-$BOOT_MOUNT}" min_mb="${2:-$BOOT_MIN_FREE_MB}"
  local avail
  avail=$(dev_ssh "df -Pm '$mount' | awk 'NR==2{print \$4}'")
  [[ -n $avail ]] || die "could not read free space on $mount"
  (( avail >= min_mb )) \
    || die "only ${avail}MB free on $mount, need ${min_mb}MB. Refusing to stage a candidate."
  ok "${avail}MB free on $mount (need ${min_mb}MB)"
}

# guard_not_default — refuse to promote something that has not passed a real boot test.
guard_candidate_untested() {
  local state
  state=$(dev_ssh "sudo cat $BOOT_MOUNT/$CANDIDATE_SLOT/state 2>/dev/null" || echo "-")
  [[ $state != "good" ]] \
    || die "candidate is already marked good — nothing to test."
}

# confirm <prompt> — interactive gate for anything that reboots or writes a bootloader.
confirm() {
  local prompt="$1"
  if [[ ${RTPI_ASSUME_YES:-0} == 1 ]]; then
    warn "auto-confirming: $prompt"
    return 0
  fi
  read -r -p "$prompt [type YES to proceed]: " reply
  [[ $reply == "YES" ]] || die "aborted by user"
}

# timestamp — stable, sortable, filesystem-safe.
timestamp() { date -u +%Y%m%dT%H%M%SZ; }
