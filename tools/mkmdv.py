#!/usr/bin/env python3
"""mkmdv - build and verify QLay-format .mdv Microdrive images.

Build mode (run from a project directory, mkqlpak.ps1-style):

    python ../tools/mkmdv.py --name game8 --dataspace 512

reads `boot` and `game8_bin` from the current directory and writes
`game8.mdv`, a 174930-byte QLay sector image: `boot` as a plain file
(type 0, LF-only) and `game8_bin` as an executable (type 1) carrying the
dataspace in its QDOS file header.  The image also runs in Q-emuLator
(`Slot1=MDV: path`) and on vDriveQL / ZX Spectrum Next QL core hardware.

Verify mode:

    python ../tools/mkmdv.py --verify image.mdv

parses an existing image (QLay 174930-byte sector dumps and Q-emuLator
`Mdv*Dump` images), validates sector structure, checksums, map and
directory, and lists the files.  Exit status 0 = no errors.

Format facts come from primary sources - the Minerva ROM microdrive
driver (md/write.asm, md/formt.asm, md/read.asm, md/serve.asm, inc/md),
the QDOS/SMS Reference Guide v4.3 (section 7, file header) and the QLay
emulator source (qlio.c) - and were cross-checked against known-good
images.  See docs/mdv-format.md for the full story.  Stdlib only.
"""

import argparse
import struct
import sys
from pathlib import Path

# --- QLay container geometry (qlay2 qlio.c: SECTLEN = 14+14+512+26+120) ---
SECTOR_LEN = 686
NUM_SECTORS = 255
QLAY_SIZE = SECTOR_LEN * NUM_SECTORS   # 174930

# Offsets inside a QLay 686-byte sector slot
OFF_HDR = 12          # after 10x00 + 2xFF preamble
OFF_BLKHDR = 40       # after second 10x00 + 2xFF preamble (0x28)
OFF_DATA = 52         # after 6x00 + 2xFF data preamble (0x34)
OFF_DATACS = 564      # 0x234
OFF_EXTRA = 566       # 0x236: 84 bytes of format-time filler
OFF_EXTRACS = 650     # 0x28A: format-time long-block checksum
OFF_GAP = 652         # 0x28C: 34 bytes of inter-sector gap

PRE12 = bytes(10) + b"\xff\xff"
PRE8 = bytes(6) + b"\xff\xff"
GAP = bytes(34)

# Map codes (Minerva md/formt.asm st_* and inc/md)
MAP_MAPFILE = 0xF8    # sector 0 map entry marks itself
MAP_FREE = 0xFD
MAP_DODGY = 0xFE
MAP_BAD = 0xFF
BLKHDR_MAPFILE = 0x80  # on-tape block header of the map sector
                       # (md/serve.asm: mapfile equ $80)

# Q-emuLator mdump container
MDUMP_MAGIC = b"Mdv*Dump"

FT_NAMES = {0: "data", 1: "exec", 2: "reloc", 255: "dir"}


def qsum(payload: bytes) -> int:
    """QDOS microdrive checksum: $0F0F plus the sum of all bytes, mod 2^16.

    Minerva md/write.asm: move.w #$0f0f,d3 / add.w d4,d3 per byte; the
    16-bit result is written to tape least-significant byte first.
    """
    return (0x0F0F + sum(payload)) & 0xFFFF


def csbytes(payload: bytes) -> bytes:
    return qsum(payload).to_bytes(2, "little")


# ---------------------------------------------------------------------------
# Parsing (verify mode)
# ---------------------------------------------------------------------------

class Report:
    def __init__(self):
        self.errors = []
        self.warnings = []

    def error(self, msg):
        self.errors.append(msg)

    def warn(self, msg):
        self.warnings.append(msg)


class Sector:
    __slots__ = ("number", "name", "rand", "hdr_cs_ok", "fileno", "blockno",
                 "blkhdr_cs_ok", "data", "data_cs_ok", "slot")

    def __init__(self, number, name, rand, hdr_cs_ok, fileno, blockno,
                 blkhdr_cs_ok, data, data_cs_ok, slot):
        self.number = number
        self.name = name
        self.rand = rand
        self.hdr_cs_ok = hdr_cs_ok
        self.fileno = fileno
        self.blockno = blockno
        self.blkhdr_cs_ok = blkhdr_cs_ok
        self.data = data
        self.data_cs_ok = data_cs_ok
        self.slot = slot


def parse_qlay(data: bytes, rep: Report):
    """Parse a QLay 174930-byte sector image into Sector objects."""
    sectors = {}
    for slot in range(NUM_SECTORS):
        s = data[slot * SECTOR_LEN:(slot + 1) * SECTOR_LEN]
        hdr = s[OFF_HDR:OFF_HDR + 16]
        if hdr[0] != 0xFF:
            # Not a written sector header (e.g. the dead slot covering the
            # tape splice in real-tape dumps); skip it.
            rep.warn(f"slot {slot}: no sector header (flag ${hdr[0]:02x}), skipped")
            continue
        number = hdr[1]
        if s[0:12] != PRE12:
            rep.warn(f"sector {number}: nonstandard header preamble")
        if s[OFF_HDR + 16:OFF_HDR + 28] != PRE12:
            rep.warn(f"sector {number}: nonstandard block preamble")
        if s[OFF_BLKHDR + 4:OFF_BLKHDR + 12] != PRE8:
            rep.warn(f"sector {number}: nonstandard data preamble")
        hdr_cs_ok = int.from_bytes(hdr[14:16], "little") == qsum(hdr[:14])
        blk = s[OFF_BLKHDR:OFF_BLKHDR + 4]
        blk_cs_ok = int.from_bytes(blk[2:4], "little") == qsum(blk[:2])
        payload = s[OFF_DATA:OFF_DATA + 512]
        data_cs_ok = (int.from_bytes(s[OFF_DATACS:OFF_DATACS + 2], "little")
                      == qsum(payload))
        if number in sectors:
            rep.error(f"sector {number} appears twice (slots "
                      f"{sectors[number].slot} and {slot})")
            continue
        sectors[number] = Sector(number, hdr[2:12], hdr[12:14], hdr_cs_ok,
                                 blk[0], blk[1], blk_cs_ok, payload,
                                 data_cs_ok, slot)
    return sectors


def parse_mdump(data: bytes, rep: Report):
    """Parse a Q-emuLator Mdv*Dump image (made by the mdump_task utility).

    Layout (reverse engineered from the QL Pawn dumps):
      $00  8 bytes  "Mdv*Dump"
      $08  u32 BE   $22 (offset of info block)
      $0C  u32 BE   offset of first sector record ($2E)
      $10  u16 BE   sector record length ($212 = 530)
      $12  u8       number of sector records
      ...
    Record: flag $FF, sector number, medium name[10], random[2],
    file/block[2], data[512], big-endian data checksum[2].
    Records are in tape order; bad sectors are simply absent.
    """
    rec_off = int.from_bytes(data[0x0C:0x10], "big")
    rec_len = int.from_bytes(data[0x10:0x12], "big")
    count = data[0x12]
    avail = (len(data) - rec_off) // rec_len
    if (len(data) - rec_off) % rec_len:
        rep.warn(f"trailing bytes after last record")
    if count != avail:
        rep.warn(f"header says {count} records, file holds {avail}")
    sectors = {}
    for i in range(avail):
        r = data[rec_off + i * rec_len: rec_off + (i + 1) * rec_len]
        if r[0] != 0xFF:
            rep.error(f"record {i}: bad flag byte ${r[0]:02x}")
            continue
        number = r[1]
        payload = r[16:528]
        cs_ok = int.from_bytes(r[528:530], "big") == qsum(payload)
        if number in sectors:
            rep.error(f"sector {number} appears twice")
            continue
        sectors[number] = Sector(number, r[2:12], r[12:14], True,
                                 r[14], r[15], True, payload, cs_ok, i)
    return sectors


def parse_directory(dirdata: bytes, rep: Report):
    """Split the directory file (file 0) into 64-byte header entries."""
    if len(dirdata) < 64:
        rep.error("directory shorter than its own 64-byte header")
        return 64, []
    dirlen = int.from_bytes(dirdata[0:4], "big")
    if dirlen < 64 or dirlen > len(dirdata):
        rep.error(f"directory length field {dirlen} out of range "
                  f"(have {len(dirdata)} bytes)")
        dirlen = min(max(dirlen, 64), len(dirdata) - len(dirdata) % 64)
    entries = []
    for fileno in range(1, dirlen // 64):
        e = dirdata[fileno * 64:(fileno + 1) * 64]
        length = int.from_bytes(e[0:4], "big")
        access = e[4]
        ftype = e[5]
        dataspace = int.from_bytes(e[6:10], "big")
        extra = int.from_bytes(e[10:14], "big")
        namelen = int.from_bytes(e[14:16], "big")
        if namelen == 0 and length == 0:
            entries.append(None)        # deleted entry
            continue
        if namelen > 36:
            rep.error(f"file {fileno}: name length {namelen} > 36")
            entries.append(None)
            continue
        name = e[16:16 + namelen].decode("ascii", "replace")
        entries.append({"fileno": fileno, "length": length, "access": access,
                        "type": ftype, "dataspace": dataspace, "extra": extra,
                        "name": name, "header": e})
    return dirlen, entries


def collect_file(fileno, sectors, filemap, rep):
    """Assemble a file's data from its map blocks; returns bytes or None."""
    blocks = filemap.get(fileno, {})
    if not blocks:
        return None, []
    out = bytearray()
    secs = []
    for blockno in range(max(blocks) + 1):
        if blockno not in blocks:
            rep.error(f"file {fileno}: block {blockno} missing from map")
            return None, secs
        sec = blocks[blockno]
        secs.append(sec)
        if sec not in sectors:
            rep.error(f"file {fileno}: block {blockno} allocated to "
                      f"sector {sec} which is not in the image")
            return None, secs
        out += sectors[sec].data
    return bytes(out), secs


def verify(path: Path) -> int:
    data = path.read_bytes()
    rep = Report()
    if data[:8] == MDUMP_MAGIC:
        container = "Q-emuLator mdump image"
        sectors = parse_mdump(data, rep)
    elif len(data) == QLAY_SIZE:
        container = "QLay sector image (255 x 686 bytes)"
        sectors = parse_qlay(data, rep)
    else:
        print(f"{path}: unknown container ({len(data)} bytes; expected "
              f"{QLAY_SIZE} for QLay or an Mdv*Dump signature)")
        return 1

    print(f"Image    : {path}")
    print(f"Container: {container}, {len(sectors)} sectors present")

    # Medium name/random must be identical on every sector (the ROM compares
    # all 12 bytes on each pass - Minerva md/serve.asm chk_med).
    names = {(s.name, bytes(s.rand)) for s in sectors.values()}
    if len(names) > 1:
        rep.error(f"inconsistent medium name/random across sectors: {names}")
    if sectors:
        any_sec = next(iter(sectors.values()))
        rand = int.from_bytes(any_sec.rand, "big")
        print(f"Medium   : {any_sec.name.decode('ascii', 'replace')!r} "
              f"random ${rand:04x}")

    hdr_bad = sorted(s.number for s in sectors.values() if not s.hdr_cs_ok)
    if hdr_bad:
        rep.warn(f"{len(hdr_bad)} sector header checksums stale (medium "
                 f"renamed after format?): sectors {hdr_bad[:8]}...")

    if 0 not in sectors:
        rep.error("sector 0 (the map) is missing")
    map_ok = 0 in sectors
    filemap = {}      # fileno -> {blockno: sector}
    counts = {"free": 0, "bad": 0, "dodgy": 0, "file": 0}
    if map_ok:
        m = sectors[0].data
        if not sectors[0].data_cs_ok:
            rep.error("map sector data checksum bad")
        if sectors[0].fileno not in (BLKHDR_MAPFILE, MAP_MAPFILE):
            rep.warn(f"map sector block header says file "
                     f"${sectors[0].fileno:02x} (expected $80 or $f8)")
        for sec in range(NUM_SECTORS):
            fno, bno = m[2 * sec], m[2 * sec + 1]
            if sec == 0:
                if fno != MAP_MAPFILE:
                    rep.error(f"map entry 0 is ${fno:02x}, expected $f8")
                continue
            if fno == MAP_FREE:
                counts["free"] += 1
            elif fno == MAP_BAD:
                counts["bad"] += 1
            elif fno == MAP_DODGY:
                counts["dodgy"] += 1
            else:
                counts["file"] += 1
                dup = filemap.setdefault(fno, {})
                if bno in dup:
                    rep.error(f"file {fno} block {bno} mapped to two sectors")
                dup[bno] = sec
                if sec not in sectors:
                    rep.error(f"map: file {fno} block {bno} on sector {sec}, "
                              "but that sector is not in the image")
                elif not sectors[sec].data_cs_ok:
                    rep.error(f"sector {sec} (file {fno} block {bno}): "
                              "data checksum bad")
        print(f"Map      : {counts['file']} file / {counts['free']} free / "
              f"{counts['dodgy']} dodgy / {counts['bad']} bad sectors; "
              f"dir pointer word ${int.from_bytes(m[510:512], 'big'):04x}")

    # Cross-check on-tape block headers against the map
    for s in sectors.values():
        if s.number == 0 or not map_ok:
            continue
        fno, bno = (sectors[0].data[2 * s.number],
                    sectors[0].data[2 * s.number + 1])
        if fno < 0xF8 and (s.fileno, s.blockno) not in ((fno, bno), (0, 0)):
            rep.warn(f"sector {s.number}: block header {s.fileno}/{s.blockno} "
                     f"disagrees with map {fno}/{bno}")

    # Directory = file 0
    files = []
    if map_ok:
        dirdata, dirsecs = collect_file(0, sectors, filemap, rep)
        if dirdata is None:
            rep.error("directory (file 0) has no blocks in the map")
        else:
            dirlen, entries = parse_directory(dirdata, rep)
            nfiles = sum(1 for e in entries if e)
            print(f"Directory: {dirlen} bytes on sectors {dirsecs} "
                  f"({nfiles} live entries)")
            print("  no type  length dataspace name")
            for e in entries:
                if not e:
                    continue
                files.append(e)
                edata, esecs = collect_file(e["fileno"], sectors, filemap, rep)
                tname = FT_NAMES.get(e["type"], str(e["type"]))
                ds = str(e["dataspace"]) if e["type"] == 1 else "-"
                print(f"  {e['fileno']:2} {tname:5} {e['length']:6} {ds:9} "
                      f"{e['name']}")
                if edata is None:
                    rep.error(f"file {e['fileno']} ({e['name']}): "
                              "no data blocks")
                    continue
                if e["length"] > len(edata):
                    rep.error(f"file {e['fileno']} ({e['name']}): directory "
                              f"length {e['length']} exceeds mapped data "
                              f"{len(edata)}")
                elif e["length"] < 64:
                    rep.error(f"file {e['fileno']} ({e['name']}): length "
                              f"{e['length']} below 64-byte header")
                if edata is not None and edata[:64] != e["header"]:
                    rep.warn(f"file {e['fileno']} ({e['name']}): block-0 "
                             "header copy differs from directory entry")
            # A mapped file number without a directory entry is legal on
            # tape (copy-protected titles like The Pawn hide files this
            # way) but would be a bug in an image we built ourselves.
            for fno in sorted(filemap):
                if fno == 0:
                    continue
                if fno >= len(entries) + 1 or entries[fno - 1] is None:
                    rep.warn(f"map contains file {fno} "
                             f"({len(filemap[fno])} sectors) with no "
                             "directory entry (hidden file?)")

    for w in rep.warnings:
        print(f"warning: {w}")
    for e in rep.errors:
        print(f"ERROR: {e}")
    status = "FAILED" if rep.errors else "OK"
    print(f"Result   : {status} ({len(rep.errors)} errors, "
          f"{len(rep.warnings)} warnings)")
    return 1 if rep.errors else 0


# ---------------------------------------------------------------------------
# Building (write mode)
# ---------------------------------------------------------------------------

def make_header(name: str, length: int, ftype: int, dataspace: int) -> bytes:
    """64-byte QDOS file header (QDOS/SMS Reference Guide section 7)."""
    h = bytearray(64)
    h[0:4] = length.to_bytes(4, "big")          # file length incl. header
    h[4] = 0                                    # access key
    h[5] = ftype                                # 0 data, 1 exec, 2 reloc
    if ftype == 1:
        h[6:10] = dataspace.to_bytes(4, "big")  # default dataspace
    nb = name.encode("ascii")
    if len(nb) > 36:
        raise SystemExit(f"mkmdv: file name too long (>36): {name}")
    h[14:16] = len(nb).to_bytes(2, "big")
    h[16:16 + len(nb)] = nb
    return bytes(h)


def free_block_area() -> bytes:
    """Data area of a freshly formatted, unused sector.

    Reproduces Minerva md/formt.asm: block header $FD/$00 with checksum,
    preamble, 512 bytes of $AA55, embedded checksum, 84 more $AA55 bytes
    and the trailing checksum of the whole 610-byte 'long block'.
    """
    blk = bytes((MAP_FREE, 0)) + csbytes(bytes((MAP_FREE, 0)))
    payload = b"\xaa\x55" * 256
    extra = b"\xaa\x55" * 42
    longblock = blk + PRE8 + payload + csbytes(payload) + extra
    return longblock + csbytes(longblock)


def build_sector(number: int, medium: bytes, rand: bytes, body: bytes) -> bytes:
    hdr = bytes((0xFF, number)) + medium + rand
    s = PRE12 + hdr + csbytes(hdr) + PRE12 + body + GAP
    assert len(s) == SECTOR_LEN, len(s)
    return s


def used_block_area(fileno: int, blockno: int, payload: bytes) -> bytes:
    """Data area of a sector rewritten by the ROM's md_write.

    md_write rewrites block header + checksum, data preamble, 512 data
    bytes + checksum; the format-time filler beyond that survives on tape,
    so we emit the same $AA55 remnants and long-block checksum FORMAT left.
    """
    assert len(payload) == 512
    blk = bytes((fileno, blockno))
    remnant = free_block_area()[OFF_DATACS - OFF_BLKHDR + 2:]
    return blk + csbytes(blk) + PRE8 + payload + csbytes(payload) + remnant


def build(name: str, dataspace: int, label: str | None, out: Path | None,
          bootfile: Path, binfile: Path) -> Path:
    label = (label or name)[:10].ljust(10)
    medium = label.encode("ascii")
    # Deterministic 'random' word so builds are reproducible
    rand = (sum(medium) * 259 % 65536).to_bytes(2, "big")
    out = out or Path(f"{name}.mdv")

    boot = bootfile.read_bytes().replace(b"\r\n", b"\n")
    if boot and not boot.endswith(b"\n"):
        boot += b"\n"
    binary = binfile.read_bytes()

    qfiles = [("boot", 0, 0, boot), (f"{name}_bin", 1, dataspace, binary)]

    # Directory (file 0): its own 64-byte header, then one entry per file
    direntries = [make_header(fn, len(data) + 64, ft, ds)
                  for fn, ft, ds, data in qfiles]
    dirlen = 64 * (1 + len(qfiles))
    dirdata = make_header("", dirlen, 0, 0) + b"".join(direntries)

    # Each file's on-tape data: header copy in block 0, then the contents
    streams = [(0, dirdata)]
    for fno, (hdr, (fn, ft, ds, data)) in enumerate(zip(direntries, qfiles), 1):
        streams.append((fno, hdr + data))

    # Allocate sectors 1.. upward, in file order (sector 0 is the map)
    mapbytes = bytearray(bytes((MAP_FREE, 0)) * 256)
    mapbytes[0:2] = bytes((MAP_MAPFILE, 0))
    sector_payloads = {}
    next_sector = 1
    dir_sector = 1
    for fno, stream in streams:
        for blockno in range(0, (len(stream) + 511) // 512):
            if next_sector >= NUM_SECTORS:
                raise SystemExit("mkmdv: files exceed cartridge capacity "
                                 f"({(NUM_SECTORS - 1) * 512} data bytes)")
            block = stream[blockno * 512:(blockno + 1) * 512].ljust(512, b"\0")
            mapbytes[2 * next_sector:2 * next_sector + 2] = bytes((fno, blockno))
            sector_payloads[next_sector] = (fno, blockno, block)
            next_sector += 1
    mapbytes[510:512] = (2 * dir_sector).to_bytes(2, "big")

    image = bytearray()
    for number in range(NUM_SECTORS):
        if number == 0:
            body = used_block_area(BLKHDR_MAPFILE, 0, bytes(mapbytes[:512]))
        elif number in sector_payloads:
            fno, blockno, block = sector_payloads[number]
            body = used_block_area(fno, blockno, block)
        else:
            body = free_block_area()
        image += build_sector(number, medium, rand, body)
    assert len(image) == QLAY_SIZE
    out.write_bytes(bytes(image))
    used = next_sector - 1
    print(f"Built {out} ({len(qfiles)} files, {used} data sectors used, "
          f"{NUM_SECTORS - 1 - used} free, dataspace {dataspace})")
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--verify", metavar="IMAGE",
                    help="verify/list an existing image instead of building")
    ap.add_argument("--name", help="project name (expects <name>_bin and "
                    "boot in the current directory; writes <name>.mdv)")
    ap.add_argument("--dataspace", type=int, default=512,
                    help="QDOS dataspace for the executable (default 512)")
    ap.add_argument("--label", help="medium name, max 10 chars "
                    "(default: project name)")
    ap.add_argument("--out", type=Path, help="output image path")
    ap.add_argument("--boot", type=Path, default=Path("boot"),
                    help="boot file (default ./boot)")
    ap.add_argument("--bin", type=Path,
                    help="executable (default ./<name>_bin)")
    args = ap.parse_args()

    if args.verify:
        sys.exit(verify(Path(args.verify)))
    if not args.name:
        ap.error("--name is required in build mode (or use --verify)")
    binfile = args.bin or Path(f"{args.name}_bin")
    for p in (args.boot, binfile):
        if not p.exists():
            raise SystemExit(f"mkmdv: missing input file: {p}")
    out = build(args.name, args.dataspace, args.label, args.out,
                args.boot, binfile)
    sys.exit(verify(out))


if __name__ == "__main__":
    main()
