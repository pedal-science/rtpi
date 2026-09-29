#!/bin/sh
# vip-guard — runs in the pedal's initramfs, before the root is mounted.
#
# Every boot of the pedal without the tryboot flag adds one to bootsel's vipboot/count, and
# `vip-boot guard-clear` (pedal-guard.service) sets it back to 0 once the pedal has reached its
# target. So the count is the number of boots in a row that never got that far. When it reaches
# GUARD_LIMIT, this makes rescue the default root (sticky), says why in vipboot/reason, and
# reboots.
#
# A candidate (tryboot flag set) isn't counted: it is one-shot, and vip-boot handles it.
#
# The formats are vip-boot's (count_text, reason_text, autoboot_text): same length, written in
# place. tests/vip-boot checks the two agree. Nothing here may stop a boot: any failure returns
# and the boot carries on uncounted.
#
# Sourced by dracut's hook runner, so: no exit, no set -e, everything in a function.

vip_guard() {
    _p=${VIPGUARD_PREFIX:-}
    _env=$_p/etc/rtpi/device.env
    [ -r "$_env" ] || return 0
    _get() { sed -n "s/^$1=\"\{0,1\}\([^\"]*\)\"\{0,1\}\$/\1/p" "$_env" | head -n 1; }

    case " $(cat "$_p/proc/cmdline" 2>/dev/null) " in
        *" vipboot.root=pedal "*) ;;
        *) return 0 ;;
    esac
    _tb=$_p/proc/device-tree/chosen/bootloader/tryboot
    if [ -r "$_tb" ] && [ "$(od -An -tx1 "$_tb" | tr -d ' \n')" != "00000000" ]; then
        echo "vip-guard: tryboot: a candidate, not counted" >&2
        return 0
    fi

    _label=$(_get BOOTSEL_LABEL); _limit=$(_get GUARD_LIMIT)
    _pedal=$(_get PEDAL_BOOT_PART); _rescue=$(_get RESCUE_BOOT_PART)
    [ -n "$_label" ] && [ -n "$_limit" ] && [ -n "$_pedal" ] && [ -n "$_rescue" ] || return 0

    _mp=$_p/run/vip-guard
    if [ -z "${VIPGUARD_NO_MOUNT:-}" ]; then
        mkdir -p "$_mp"
        mount -t vfat -o rw,noatime "/dev/disk/by-label/$_label" "$_mp" 2>/dev/null || {
            echo "vip-guard: cannot mount $_label: boot not counted" >&2; return 0; }
    fi
    _count=$_mp/vipboot/count
    _n=$(sed -n 's/^count=\([0-9][0-9]*\).*/\1/p' "$_count" 2>/dev/null)
    _n=${_n:-0}

    # write <file> <width> <text>: text padded with spaces to width-1, then a newline, in place.
    _put() {
        [ -f "$1" ] && [ "$(wc -c < "$1")" -eq "$2" ] || return 1
        printf "%-$(( $2 - 1 ))s\n" "$3" | dd of="$1" bs="$2" count=1 conv=notrunc,fsync 2>/dev/null
    }

    if [ "$_n" -ge "$_limit" ]; then
        echo "vip-guard: $_n boots in a row never reached pedal-guard: making rescue the default" >&2
        _put "$_mp/vipboot/reason" 256 \
            "vip-guard: $_n pedal boots in a row never reached pedal-guard; rescue made the default"
        _ab=$_mp/autoboot.txt
        _new=$(printf '[all]\ntryboot_a_b=1\nboot_partition=%s\n\n[tryboot]\nboot_partition=%s\n' "$_rescue" "$_pedal")
        if [ "$(wc -c < "$_ab")" -eq "$(( ${#_new} + 1 ))" ]; then
            printf '%s\n' "$_new" | dd of="$_ab" bs=4096 count=1 conv=notrunc,fsync 2>/dev/null
        fi
        _put "$_count" 16 "count=0"
        sync
        [ -n "${VIPGUARD_NO_MOUNT:-}" ] || umount "$_mp"
        if [ -n "${VIPGUARD_REBOOT:-}" ]; then "$VIPGUARD_REBOOT"; return 0; fi
        reboot -f || echo b > /proc/sysrq-trigger
        return 0
    fi

    _put "$_count" 16 "count=$(( _n + 1 ))" \
        || echo "vip-guard: $_count is not vip-boot's: boot not counted" >&2
    sync
    [ -n "${VIPGUARD_NO_MOUNT:-}" ] || umount "$_mp"
    return 0
}

vip_guard
