# CLAUDE.md — Sinclair QL assembly workspace

Cross-development for the Sinclair QL (68008, QDOS). Programs are written in
68000 assembly (Motorola syntax), built with vasm on Windows, and tested in
Q-emuLator. `hello/` is the working reference project — copy its structure
for new programs.

## Tool paths (fixed, not on PATH)

- Assembler: `C:\Users\tomco\app\vasm\vasmm68k_mot.exe` (also `vlink.exe`,
  `vobjdump.exe` in the same dir)
- Emulator: `C:\Program Files (x86)\QemuLator\QemuLator 4\QemuLator.exe`
  (accepts a `.qlpak` path as argument; logs to `qemulator.log` in its
  install dir, written on exit)
- Reference QL software/images: `C:\Users\tomco\app\ql\`

## Build & run

```
make        # in a project dir: assemble + package .qlpak
make run    # launch Q-emuLator with the package
```

Assemble step is `vasmm68k_mot -m68008 -Fbin -o <name>_bin <name>.asm` —
flat binary, PC-relative code only (no relocation). The packaging step
(shared `tools/mkqlpak.ps1`, called by each project's Makefile) prepends
the 30-byte `]!QDOS File Header` carrying the QDOS file type and
dataspace, then zips config + files into a `.qlpak`.

`make mdv` (game8, pattern reusable) builds `<name>.mdv` instead — a
QLay-format Microdrive image via `tools/mkmdv.py` (Python 3, stdlib
only; builds carry a genuine QDOS directory header with type 1 +
dataspace). The `.mdv` boots in Q-emuLator (`make runmdv`,
`Slot1=MDV: <path>` in a QCF), on the ZX Spectrum Next QL core and on a
vDriveQL. `python tools/mkmdv.py --verify <image>` checks any image;
format spec in `docs/mdv-format.md`.

## Hard-won rules — do not rediscover these

1. **Executables need a dataspace.** A raw `-Fbin` output is not EXECable;
   QDOS needs the dataspace value from the file header. On Windows/zip
   storage Q-emuLator reads it from the `]!QDOS File Header` prefix
   (format in `docs/qemulator.md`). Dataspace is the `DATASPACE` variable
   in each Makefile (job stack + BSS; 512 is fine for small jobs).
2. **Line endings matter.** SuperBASIC `boot` files must be LF-only
   (QDOS newline = `$0A`); `.QCF` config files are CRLF. `mkqlpak.ps1`
   normalizes both at packaging time, so repo files can be either.
3. **Verify trap codes against the Minerva sources**
   (<https://github.com/MarcelKilgus/Minerva>, files `inc/io`, `inc/sd`,
   `inc/mt`), not from memory — several published lists disagree. The
   verified table is in `docs/qdos-programming.md`.
4. **Q-emuLator locks the `.qlpak` while running.** Close it before
   `make`, or the packaging step fails.
5. **vasm's site is HTTP-only** (`http://sun.hasenbraten.de/vasm/`);
   WebFetch force-upgrades to HTTPS and fails — use `curl.exe` to fetch.
6. Don't add tools to PATH — the convention in `C:\Users\tomco\app` is
   full paths from build scripts.
7. `label name conflicts with directive` warnings from vasm: avoid label
   names like `entry`, `list`, `end`.
8. `sound_test/ipc_sound.asm` (the original) ends with an `end`
   directive, which stops vasm entirely — include it as the **last**
   line. The `lib/` variants have the `end` stripped so several can be
   included; order matters: `ipc_sound_takeover.asm` first, then
   `ipc_keys_takeover.asm` (it uses the sound lib's `ipc_nib` and
   `ipc_rdbyte`).
9. Flat PIC binaries can't hold absolute pointers in data (`dc.l label`
   is file-relative garbage at runtime) — initialize pointers at runtime
   with `lea label(pc)` (see the melody player's `mel_state`).
10. **Microdrive images: write every checksum correctly** (`$0f0f` +
    byte sum, LSB first — Minerva `md/write.asm`). Wrong sector-header
    checksums "work" under Q-emuLator's default driver, which hooks QDOS
    above checksum level (Pitman.MDV's are all stale), but the real ROM
    driver (`MdvImageDriver=QDOS`, hardware-level cores) silently skips
    every sector that fails the comparator. Details: `docs/mdv-format.md`.
11. Boot scripts use `EXEC mdv1_...`, not `flp1_`: Q-emuLator aliases
    MDV1_/FLP1_/WIN1_ to the same slot, so mdv1_ works for qlpaks *and*
    mdv images — flp1_ doesn't exist on a real QL or the Next core.
12. **Double buffering is draw → wait for VBL → flip; don't add core
    workarounds.** The MiSTer QL core latches the screen base ~24
    lines before raising the frame interrupt, so on it (and the MEGA65
    port until the upstream fix lands) the flip is a frame late and
    shapes flicker. That's a core bug — reported upstream, already
    fixed in the Tang Nano port. Flip-before-wait "fixes" were tried
    and reverted (residual races, real-HW risk): status + analysis in
    `docs/takeover.md` "Double buffering", issue text in
    `docs/mister-flip-latch-issue.md`.

## Conventions

- New program = new top-level dir copied from `hello/` (asm + boot + QCF +
  Makefile; change `NAME` in the Makefile), binary named `<name>_bin`
  (QDOS style, no dots). Packaging is shared: `tools/mkqlpak.ps1`.
- Hardware-takeover programs (games/demos) follow the sequence in
  `docs/takeover.md`: TRAP #0 → `move.w #$2700,sr` → own supervisor
  stack → poll `$18021` bit 3 for VBL. Takeover is one-way; QDOS calls
  are forbidden afterwards. Hardware register facts come from the
  Minerva sources `inc/mc` and `inc/pc` — same rule as trap codes.
- Shared assembly sources live in `lib/` (included as
  `../lib/<file>.asm`). Takeover programs use
  `lib/ipc_sound_takeover.asm` for sound (no sysvar access — required
  once $28000 is screen 1); QDOS-cohabiting programs use the original
  `sound_test/ipc_sound.asm`. Double-buffered programs: `flip/` (mode 4)
  and `flip8/` (mode 8) are the reference implementations — new work
  copies whichever mode matches.
- 3D/vector work: `lib/draw_line.asm` is the colour line entry
  (`d4` = 1 red / 2 green / 3 white, register API, no clipping): white
  tail-calls `lib/draw_line_w.asm` (word ops, both planes, slope-classed
  fast path), red/green go to the single-plane byte-op twin
  `draw_line_p` -- red is the green drawer with the screen base at
  `a4+1`. Include both lib files;
  `lib/draw_dec.asm` prints a word as a 6-digit decimal readout
  (3x5 green digits, mode 4 — meters, future score displays); meshes are defined
  and validated in `tools/genmesh.py` (winding-consistent closed
  solids -> `.inc` tables), sin tables come from `tools/gensin.py`;
  `shapes/` is the reference 3D engine (cull, erase, meters).
  Measurements and method: `docs/vector-perf.md`.
- Jobs start with the standard QDOS job header (`bra.s` + `dc.l 0` +
  `dc.w $4afb` + counted name) and exit via MT.FRJOB.
- Trap key equates are spelled `io_open`, `sd_clear`, … (underscores; the
  originals use dots, which vasm labels can't).

## Docs

- `docs/qdos-programming.md` — QDOS job anatomy, verified trap reference,
  console channels, colours, dataspace.
- `docs/qemulator.md` — `.qlpak`/`.QCF`/`]!QDOS File Header` formats,
  deployment, debugging tips.
- `docs/takeover.md` — machine takeover for games/demos: supervisor mode,
  interrupt masking, VBL polling, mode 4/8 screen memory layouts.
- `docs/mdv-format.md` — QLay `.mdv` container + QDOS Microdrive
  filesystem: sector/checksum layout, map, directory, sources.
- `docs/vector-perf.md` — line-drawing benchmark results (`lines/` rig),
  cycle analysis, optimization roadmap toward wireframe 3D.
- Background/scene notes live in the Obsidian vault:
  `C:\Users\tomco\OneDrive\Applications\remotely-save\Vault\Retro\QL\`
