#!/usr/bin/env python3
"""Decode and validate a U-Boot environment image.

Read-only. Used both to inspect the live region on tib before we ever write to it, and
to check backups.

The U-Boot env format (non-redundant, which is what this board uses — CONFIG_ENV_REDUNDANT
is not set) is:

    offset 0: uint32 little-endian CRC32 of everything that follows
    offset 4: NUL-separated KEY=VALUE pairs, terminated by an empty entry

Why this matters: on tib the region is currently ALL ZERO with a zero CRC, meaning U-Boot
has never run `saveenv` and is using its compiled-in default environment. libubootenv's
fw_setenv has no built-in defaults (it reads /etc/u-boot-initial-env, which does not
exist), so a first `fw_setenv` would write a valid-CRC environment containing ONLY the
variable you set — destroying bootcmd and stopping the board booting.

So: this script must report VALID before anything calls fw_setenv.

Exit codes:  0 = valid env   1 = empty/never-written   2 = present but CRC mismatch
"""

import sys
import zlib

def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <env-image>", file=sys.stderr)
        return 3

    data = open(sys.argv[1], "rb").read()
    if len(data) < 5:
        print(f"IMAGE TOO SHORT: {len(data)} bytes")
        return 3

    stored = int.from_bytes(data[:4], "little")
    body = data[4:]
    computed = zlib.crc32(body) & 0xFFFFFFFF

    print(f"image size      : {len(data)} bytes")
    print(f"stored CRC32    : 0x{stored:08x}")
    print(f"computed CRC32  : 0x{computed:08x}")

    nonzero = sum(1 for b in data if b)
    if stored == 0 and nonzero == 0:
        print("STATUS          : EMPTY — U-Boot has never saved an environment.")
        print()
        print("  U-Boot is running on its compiled-in default environment.")
        print("  DO NOT run fw_setenv against this. Run `saveenv` once at the U-Boot")
        print("  serial console first, which persists the complete current environment.")
        return 1

    if stored != computed:
        print(f"STATUS          : CRC MISMATCH (non-zero bytes: {nonzero})")
        print()
        print("  The region holds something, but it is not a valid U-Boot environment.")
        print("  Do not write to it until this is understood.")
        return 2

    # Valid: decode the NUL-separated pairs.
    text = body.split(b"\x00\x00")[0]
    pairs = [p for p in text.split(b"\x00") if p]
    print(f"STATUS          : VALID — {len(pairs)} variables")
    print()
    for p in pairs:
        print("  " + p.decode("utf-8", "replace"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
