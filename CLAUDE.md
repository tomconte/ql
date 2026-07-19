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
8. The IPC sound sources end with an `end` directive, which stops vasm
   entirely — `include` them as the **last** line of the main source.
9. Flat PIC binaries can't hold absolute pointers in data (`dc.l label`
   is file-relative garbage at runtime) — initialize pointers at runtime
   with `lea label(pc)` (see the melody player's `mel_state`).

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
- Background/scene notes live in the Obsidian vault:
  `C:\Users\tomco\OneDrive\Applications\remotely-save\Vault\Retro\QL\`
