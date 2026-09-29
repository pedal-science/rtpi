#!/bin/bash
# vip-guard: count the pedal's boots on bootsel, and send vip to rescue when too many in a row
# never reached `vip-boot guard-clear`. Included by name (dracut.conf.d/30-vip-guard.conf) and
# only in the pedal root's initramfs.
check() { return 255; }
depends() { return 0; }
installkernel() { hostonly='' instmods vfat nls_cp437 nls_iso8859_1 nls_ascii; }
install() {
    inst_multiple mount umount dd sed od tr cat sync mkdir
    inst_simple /etc/rtpi/device.env
    inst_hook pre-mount 10 "$moddir/vip-guard.sh"
}
