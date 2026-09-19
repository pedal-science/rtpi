#!/usr/bin/env bash
# NOT IMPLEMENTED — build an RT kernel from the raspberrypi/linux vendor tree.
#
# Lower priority than it looks. Ubuntu's linux-raspi IS a derivative of this tree with
# Canonical's RT work on top, and it is already configured well for audio (see
# scripts/build/piv-ubuntu-rt.sh for the audit). The vendor tree does not ship PREEMPT_RT
# itself, so this route means carrying the RT patches yourself and losing Canonical's
# tuning, in exchange for vendor patches that linux-raspi mostly already carries.
#
# Worth doing only if a specific piece of hardware needs a downstream driver that has not
# reached linux-raspi. Nothing observed on piv so far does: the SSL 2+ works on
# snd-usb-audio, wifi and the USB-SATA bridge all come up on the stock kernel.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
die "piv-vendor-rt.sh is not implemented, and is not the recommended route -- see the
       comments in this file. Prefer the apt RT kernel plus 'make piv-audio-tune'."
