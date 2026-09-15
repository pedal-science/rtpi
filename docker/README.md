# Build container

One arm64 image builds both kernels: native arm64 for piv, cross armhf for tib.

## colima sizing

The pre-existing `default` colima profile is 2 CPU / 2 GiB — far too small for a kernel
build. Resize before first use:

```bash
colima stop
colima start --cpu 8 --memory 12 --disk 80
```

The Mac has ~35 GiB free, so keep an eye on it; the 80 GiB colima disk is sparse.

## Why sources live in a volume

macOS is case-insensitive by default, and the Linux kernel tree contains filenames that
differ only in case — checking one out onto a bind mount corrupts it. Bind-mount I/O is
also slow, which dominates a kernel build. So `make shell` mounts a named Docker volume
at `/src` and only the finished `.deb`s are copied back out.
