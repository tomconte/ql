# The QLay .mdv container and the QDOS Microdrive filesystem

How `tools/mkmdv.py` builds a bootable Microdrive image, and why every
byte is where it is. One `.mdv` serves three targets: Q-emuLator
(`Slot1=MDV: path` in a `.QCF`), the ZX Spectrum Next QL core (image on
the FAT32 SD card, auto-boots a file named `boot`), and a real QL fitted
with a vDriveQL.

Primary sources — the format facts below were taken from these, then
cross-checked byte-for-byte against known-good images
(`C:\Users\tomco\app\ql\Pitman.MDV`, the QL Pawn mdump images, and the
pristine `Release/MDV/MDV1.MDV` shipped in the qlay2 repo):

- **Minerva ROM microdrive driver** —
  <https://github.com/MarcelKilgus/Minerva>, files `md/write.asm`
  (checksum algorithm, block write layout), `md/formt.asm` (what FORMAT
  puts on tape), `md/read.asm` (what the ROM verifies on read),
  `md/serve.asm` (runtime map handling), `inc/md` (map codes, 64-byte
  directory entry). The microdrive hardware is a dumb shift register;
  **all structure and checksums are computed by this ROM code**, so it
  is the definitive spec.
- **QLay emulator source** — <https://github.com/xXorAa/qlay2>,
  `qlio.c`: `SECTLEN = (14+14+512+26+120)` = 686, `NOSECTS 255`. QLay
  feeds image bytes through the emulated hardware to the real ROM
  driver, which is why the container is a raw dump of what FORMAT
  writes. Jan Venema's readme: "The native OS MDV files have to be
  exactly 174930 bytes long."
- **QDOS/SMS Reference Guide v4.3**, section 7 (Directory Device
  Drivers): the 64-byte file header, file types, dataspace.
- **Q-emuLator Users' Manual** (`docs\Q-emuLator.pdf` in the install
  dir): image types it mounts (QLay, mdump, mdvraw, mdi), the
  `Slot1=MDV: path` QCF key, and the two mdv drivers (see gotchas).

## The QLay container

A QLay `.mdv` is exactly **174930 bytes = 255 slots x 686 bytes**: a
linear dump of the tape loop, one slot per physical sector, in the order
the read head would meet them. Sectors are identified by the number
*inside* the header, not by slot position — Pitman's tape order is
0, 253, 252, ... 1; mkmdv writes ascending 0..254 like QLAYT did.

Each 686-byte slot (offsets in hex):

| Offset | Size | Content |
|---|---|---|
| $000 | 12 | preamble: 10 x `$00`, 2 x `$FF` (hardware sync, ROM never sees it) |
| $00C | 16 | **sector header**: `$FF`, sector number, medium name (10 chars, space-padded), random word, checksum |
| $01C | 12 | preamble: 10 x `$00`, 2 x `$FF` |
| $028 | 4 | **block header**: file number, block number, checksum |
| $02C | 8 | data preamble: 6 x `$00`, 2 x `$FF` (PLL resync) |
| $034 | 512 | **sector data** |
| $234 | 2 | data checksum |
| $236 | 84 | `$AA $55` filler written by FORMAT, never rewritten |
| $28A | 2 | FORMAT's checksum over the whole 610-byte "long block" ($3B19 on a fresh cartridge) |
| $28C | 34 | inter-sector gap (zeros) |

**The checksum** (every one of them): 16-bit sum initialised to
`$0F0F`, each byte added as an unsigned word, result stored **least
significant byte first** (Minerva `md/write.asm`: `move.w #$0f0f,d3` /
`add.w d4,d3`). The header checksum covers its 14 bytes, the block
header checksum its 2, the data checksum the 512 data bytes.

FORMAT (`md/formt.asm`) writes each sector as the 14-byte header block
plus one 610-byte "long block": block header `$FD/$00` + checksum,
preamble, 512 bytes of `$AA55`, an *embedded* data checksum ($0E0F),
84 more `$AA55` bytes — then `md_wblok` appends a checksum over all 610
bytes ($3B19). A later file write (`md_write`) only rewrites through
the data checksum; the `$AA55` filler and $3B19 remain on tape forever.
mkmdv emits exactly that remnant, which is why its output matches
Pitman byte-for-byte in every region a fresh cartridge would carry.

## The QDOS Microdrive filesystem

**Sector 0 is the map**: 255 entries of 2 bytes — file number, block
number — indexed by sector number, then one spare word which FORMAT
uses to record 2 x the directory's sector. File-number codes
(`md/formt.asm` `st_*`, `inc/md`):

| Code | Meaning |
|---|---|
| `$F8` | the map itself (map entry 0) |
| `$FD` | free sector |
| `$FE` | failed one FORMAT verify ("dodgy") |
| `$FF` | bad / nonexistent |
| `$FC` | pending delete (runtime state) |
| 0 | the directory |
| 1+ | ordinary files |

The map sector's *on-tape block header* says file `$80`, not `$F8` —
`md/serve.asm` line 29: `mapfile equ $80  (hm... documentation suggests
this is $f8!)`. Both appear in the wild; the verifier accepts either.

**The directory is file 0**, a table of 64-byte entries. Entry 0 is the
directory's own header (its length long = total directory length);
the entry at offset 64 x n describes file n. Deleted files leave
zeroed entries. Entry layout (QDOS/SMS Reference Guide section 7,
Minerva `inc/md` `md_de*` — all values big-endian):

| Offset | Size | Content |
|---|---|---|
| $00 | 4 | file length **including this 64-byte header** |
| $04 | 1 | access key (0) |
| $05 | 1 | file type: 0 data, 1 executable, 2 relocatable |
| $06 | 4 | type-dependent info: **dataspace** for type 1 |
| $0A | 4 | more info (0) |
| $0E | 2+36 | length-prefixed file name |
| $34 | 4 | update date |
| $38 | 2+2 | version and unit |
| $3C | 4 | backup date |

**Files** are chains of 512-byte blocks located via the map (block
numbers count from 0). Block 0 begins with a copy of the file's
64-byte header; content starts at byte 64, so a file occupies
`ceil((64 + content) / 512)` sectors. Every sector's header carries the
same medium name + random word — the ROM compares all 12 bytes on every
pass (`md/serve.asm` `chk_med`) to detect cartridge changes.

The medium holds 253 free sectors after the map and an empty directory
(~126.5 KB); FORMAT rejects cartridges with fewer than 200 good
sectors, and sectors 254/255 never exist on a real tape (seeing them
after the verify pass means the tape runs too slow — `md/formt.asm`).
An emulator-style "perfect" image with all 255 sectors good is
accepted fine.

## The mdump container (read-only in mkmdv)

Q-emuLator also mounts images made by the `mdump_task` QL utility (the
QL Pawn images are these): magic `Mdv*Dump`, u32 offsets at $08/$0C
(info block, first record), u16 record length ($212 = 530) at $10,
record count byte at $12. Each record: `$FF`, sector number, medium
name (10), random (2), file/block (2), 512 data bytes, then the data
checksum stored **big-endian** (unlike tape order). Bad sectors are
simply absent, so file sizes vary. The verifier parses these so real
cartridge dumps can serve as references.

## Hard-won gotchas

- **Nobody checks the sector-header checksum until something does.**
  Pitman.MDV's 254 header checksums are all stale — the medium was
  renamed after formatting (each is exactly the sum of an older,
  cheaper name) — yet it "works" because Q-emuLator's default driver
  hooks QDOS above checksum level. With `MdvImageDriver=QDOS`, or on
  a hardware-level implementation, the real ROM reads the header
  *through the checksum comparator* (`md/read.asm` `md_sectr` →
  `checksum`) and silently skips every bad sector. Write correct
  checksums everywhere; assume nothing about which layer a target
  emulates.
- **Freed sectors keep their old contents.** Only the map entry
  changes on delete — don't expect `$AA55` in a free sector of a used
  cartridge, and don't read anything into data of sectors the map
  calls free.
- **Copy protection hides files.** The Pawn's map allocates files 2
  and 3 (187 sectors) with no directory entries. Orphan map files are
  a warning, not an error, when verifying foreign images.
- **The map's directory pointer word rots.** FORMAT records the
  directory sector in the map's spare word, but QDOS never updates it
  when the directory grows or moves (Pitman: pointer says 38,
  directory lives on sectors 222/83). Locate the directory via the
  map's file-0 entries, never via that word.
- **`EXEC mdv1_...` in boot works on every target.** Q-emuLator
  aliases MDV1_/FLP1_/WIN1_ to the same slot, so a boot script written
  for the mdv image also runs from a qlpak; the reverse (`flp1_`) dies
  on a real QL or the Next core, which only have mdv.
- Q-emuLator **locks a mounted image** like it locks a qlpak — close
  it before `make mdv`.
