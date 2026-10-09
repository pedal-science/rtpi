#!/usr/bin/env bash
# NOT IMPLEMENTED — and, on the evidence, not currently worth implementing.
#
# The plan called for building an audio-tuned RT kernel from Ubuntu's linux-raspi source
# to compare against the stock linux-raspi-realtime package. Auditing the running kernel's
# config first (2026-09-16) showed there is almost nothing left for such a build to
# change. Every option a custom RT build normally exists to set is already set:
#
#   already on   PREEMPT_RT, PREEMPT_LAZY, HZ=1000, RCU_BOOST, HIGH_RES_TIMERS,
#                NO_HZ_FULL, RCU_NOCB_CPU, IRQ_FORCED_THREADING
#   already off  RT_GROUP_SCHED, DEBUG_PREEMPT, PROVE_LOCKING, SCHED_DEBUG,
#                SLUB_DEBUG_ON, KASAN
#   not built    TRANSPARENT_HUGEPAGE, NUMA_BALANCING  (nothing to disable)
#   harmless     ARM64_MTE (dead code on a Cortex-A76), DYNAMIC_FTRACE (nops until used,
#                and rtla needs it)
#
# NO_HZ_FULL and RCU_NOCB_CPU are the ones worth dwelling on: they are compiled in and
# inert until the *command line* activates them. That is a boot argument, not a rebuild.
#
# What actually moved the numbers was command-line and runtime tuning, which needs no
# custom kernel at all -- see "piv low-latency audio tuning" in the README and:
#     make piv-audio-tune        (runtime: IRQ pinning and priority)
#     make piv-audio-boot-args   (boot: CPU isolation, via tryboot)
# Measured: p99 latency roughly halved at every tested period, average latency on the
# reserved cores down about 2.5-3x.
#
# WHEN TO IMPLEMENT THIS ANYWAY
# A custom build earns its keep only for something unobtainable at runtime:
#   - an out-of-tree patch this board needs (piv so far needs none),
#   - a larger page size for big DSP working sets -- Ubuntu ships CONFIG_ARM64_4K_PAGES
#     with VA_BITS=48, and 16K/64K pages cut TLB pressure but cannot be set at boot,
#   - dropping STACKPROTECTOR_STRONG / RANDOMIZE_BASE, which is a security decision and
#     should be made deliberately rather than as a default.
#
# If you do implement it, note two traps documented in the README: the flavour name must
# stay `raspi-realtime` (check_kflavors silently makes flash-kernel a no-op otherwise),
# and the build must still ship bcm2712-rpi-5-b.dtb even though the Pi 500 boots
# bcm2712-rpi-500.dtb, because find_dtb_file() aborts without it.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
die "piv-ubuntu-rt.sh is not implemented. The config audit found no meaningful delta to
       build -- see the comments in this file and the README section 'Is a custom kernel
       worth building for piv?'. Use 'make piv-audio-tune' and 'make piv-audio-boot-args',
       which is where the measured improvement actually came from."
