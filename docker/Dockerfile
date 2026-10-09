# Build environment for both targets.
#
#   piv  — arm64 kernel, built NATIVELY (the container is arm64 on Apple Silicon)
#   vip  — arm64 kernel, same source and flavour as piv, rebuilt with the NUMA fragment
#
# Both are arm64, so one arm64 image covers them. Pin by digest in docker/image.lock for
# reproducibility.
FROM ubuntu:26.04

ARG DEBIAN_FRONTEND=noninteractive

# Kernel build essentials. dwarves supplies pahole, needed for BTF generation; without
# it modern kernel builds fail late and confusingly. gawk builds modules.builtin.ranges
# (scripts/Makefile.vmlinux); without it a build that has compiled everything dies at
# the final vmlinux step, which is how it was found (vip's first rebuild).
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential bc bison flex gawk \
      libssl-dev libelf-dev libncurses-dev \
      dwarves rsync kmod cpio zstd xz-utils \
      git ca-certificates curl wget \
      python3 python3-dev \
      fakeroot debhelper dh-exec devscripts \
      kernel-wedge makedumpfile \
      u-boot-tools \
      ccache \
    && rm -rf /var/lib/apt/lists/*

# Ubuntu kernel packaging pulls a few extras when building the raspi flavour.
RUN apt-get update && apt-get install -y --no-install-recommends \
      libdw-dev libnewt-dev libiberty-dev default-jdk-headless \
      java-common rsync libudev-dev libpci-dev libcap-dev libbabeltrace-dev \
      libsystemd-dev libtraceevent-dev pkg-config \
    && rm -rf /var/lib/apt/lists/* || true

ENV KBUILD_BUILD_USER=rtpi \
    KBUILD_BUILD_HOST=rtpi-builder \
    PATH=/usr/lib/ccache:$PATH \
    CCACHE_DIR=/ccache

# IMPORTANT: kernel sources live in a Docker VOLUME mounted here, never on a macOS bind
# mount. macOS is case-insensitive by default and the kernel tree contains files that
# differ only in case; a bind mount would also make this I/O-bound build much slower.
VOLUME /src
VOLUME /ccache
WORKDIR /src

CMD ["/bin/bash"]
