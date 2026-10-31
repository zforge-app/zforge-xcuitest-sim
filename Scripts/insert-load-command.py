#!/usr/bin/env python3
"""Adds an LC_LOAD_WEAK_DYLIB load command to a Mach-O executable (thin or universal).

Used on a *copy* of a test build so the app agent is loaded the same way a library linked
into a dedicated test configuration would be. The existing signature is removed first; the
caller re-signs. Usage: insert-load-command.py <dylib path> <binary> [<binary>...]
"""
import struct, subprocess, sys

LC_LOAD_WEAK_DYLIB = 0x80000018
LC_SEGMENT_64 = 0x19
MH_MAGIC_64 = 0xFEEDFACF
FAT_MAGIC = 0xCAFEBABE


class NoSpace(Exception):
    pass


def patch_slice(data, base, dylib):
    magic, cputype, subtype, filetype, ncmds, sizeofcmds, flags, reserved = struct.unpack_from("<IiiIIIII", data, base)
    if magic != MH_MAGIC_64:
        raise SystemExit("only 64-bit little-endian slices are supported")
    header = 32
    offset = base + header
    first_section = None
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, offset)
        if cmd == LC_LOAD_WEAK_DYLIB or cmd == 0xC:
            name_offset = struct.unpack_from("<I", data, offset + 8)[0]
            name = bytes(data[offset + name_offset: offset + size]).split(b"\0")[0].decode()
            if name == dylib:
                return False
        if cmd == LC_SEGMENT_64:
            nsects = struct.unpack_from("<I", data, offset + 64)[0]
            for s in range(nsects):
                sect = offset + 72 + s * 80
                sect_offset = struct.unpack_from("<I", data, sect + 48)[0]
                if sect_offset and (first_section is None or sect_offset < first_section):
                    first_section = sect_offset
        offset += size
    path = dylib.encode() + b"\0"
    cmdsize = (24 + len(path) + 7) & ~7
    end = header + sizeofcmds
    if first_section is None or end + cmdsize > first_section:
        raise NoSpace(f"{first_section - end if first_section else 0} bytes free, {cmdsize} needed")
    command = struct.pack("<IIIIII", LC_LOAD_WEAK_DYLIB, cmdsize, 24, 2, 0x10000, 0x10000) + path
    command += b"\0" * (cmdsize - len(command))
    data[base + end: base + end + cmdsize] = command
    struct.pack_into("<II", data, base + 16, ncmds + 1, sizeofcmds + cmdsize)
    return True


def patch(binary, dylib):
    with open(binary, "rb") as f:
        data = bytearray(f.read())
    changed = False
    if struct.unpack_from(">I", data, 0)[0] == FAT_MAGIC:
        count = struct.unpack_from(">I", data, 4)[0]
        for i in range(count):
            cputype, subtype, offset, size, align = struct.unpack_from(">iiIII", data, 8 + i * 20)
            changed |= patch_slice(data, offset, dylib)
    else:
        changed = patch_slice(data, 0, dylib)
    if changed:
        subprocess.run(["codesign", "--remove-signature", binary], check=True)
        with open(binary, "rb") as f:
            unsigned = bytearray(f.read())
        # Re-apply on the unsigned file (removing the signature shrinks __LINKEDIT only).
        if struct.unpack_from(">I", unsigned, 0)[0] == FAT_MAGIC:
            for i in range(struct.unpack_from(">I", unsigned, 4)[0]):
                offset = struct.unpack_from(">iiIII", unsigned, 8 + i * 20)[2]
                patch_slice(unsigned, offset, dylib)
        else:
            patch_slice(unsigned, 0, dylib)
        with open(binary, "wb") as f:
            f.write(unsigned)
    print(("inserted into " if changed else "already present in ") + binary)


def main():
    # Tries each candidate binary in order (e.g. the main executable, then Xcode's debug dylib).
    dylib, candidates = sys.argv[1], sys.argv[2:]
    for binary in candidates:
        try:
            patch(binary, dylib)
            return
        except NoSpace as error:
            print(f"{binary}: {error}")
    raise SystemExit("no candidate binary has room for the load command")


if __name__ == "__main__":
    main()
