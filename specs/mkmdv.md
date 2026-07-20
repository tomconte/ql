# Spec: mkmdv — native QLay-format .mdv image builder

## Goal

A native tool (`tools/mkmdv.py`, Python) that builds a **QLay-specification
`.mdv` Microdrive image** containing a project's `boot` file and
executable, with a **genuine QDOS directory header** carrying the
executable's file type (1) and dataspace. Integrated as a `make mdv`
target in project Makefiles (start with `game8/`).

Why: the current `.qlpak` pipeline only works in Q-emuLator — its
`]!QDOS File Header` byte prefix is a Q-emuLator convention. The target
now is the **ZX Spectrum Next QL core**, which mounts `.mdv` images
("must conform to the specification set by the QLay emulator" — official
primer, <https://www.specnext.com/sinclair_ql-qs/>) from its FAT32 SD
card, memory-mapped, and auto-boots a file named `boot` on the device.
A `.mdv` also runs in Q-emuLator and on a vDriveQL-equipped real QL —
one artifact, three targets.

## Language & environment

- **Python 3.14** (system install: Windows Store python on PATH,
  `C:\Users\tomco\AppData\Local\Microsoft\WindowsApps\python.exe`).
- **Stdlib only** (`struct`, `argparse`, `pathlib`, …) — this task needs
  no third-party packages. HOUSE RULE: if a dependency ever becomes
  necessary, create a gitignored `.venv` and reference its interpreter
  from build scripts — never `pip install` into the system Python.
- Existing packaging tool `tools/mkqlpak.ps1` (PowerShell) stays as-is;
  PowerShell was fine for prepend-and-zip glue, Python is the right tool
  for binary format work.

## Deliverables

1. `tools/mkmdv.py` — builds `<name>.mdv` from a project dir (same
   calling-convention spirit as mkqlpak.ps1: `--name`, `--dataspace`).
   Must include a **verify/list mode** that parses an existing image
   back (sector structure, map, directory, checksums) and reports
   contents — the automated acceptance test and a debugging aid.
2. `make mdv` target in `game8/Makefile` (pattern reusable by other
   projects; `make run` keeps launching the qlpak as today).
3. `docs/mdv-format.md` — deep dive on the QLay `.mdv` container format
   and the QDOS Microdrive filesystem (sector layout, map, directory,
   file headers), sources cited. Follow the style of existing `docs/`.
4. README.md + CLAUDE.md updates per repo conventions.

## Format knowledge required (research first — house rule)

Two layered formats, both need to be right:

- **QLay `.mdv` container**: byte-level sector image (255 sectors; each
  sector = preamble/header/gap/data blocks with checksums). Primary
  sources: QLay emulator source/docs (Jan Venema; QLAY2 descendants);
  sQLux source may read mdv too; Q-emuLator is compatible. Get the
  exact per-sector byte layout and checksum algorithms from source
  code, not from memory or summaries.
- **QDOS Microdrive filesystem**: sector-0 map, directory file, 64-byte
  file headers (length, access, **type**, **dataspace**, name, dates),
  block allocation. Primary sources: QDOS/SMS Reference Guide v4.3
  (file system + directory sections) — PDF at
  <https://ia801404.us.archive.org/0/items/SinclairQLHomepage/docs/manuals/QDOS%20_%20SMS%20Reference%20Guide%20v4.3.pdf>,
  `pdftotext` is installed (scoop poppler); the Minerva ROM sources
  (<https://github.com/MarcelKilgus/Minerva>, `md/` = microdrive driver,
  `inc/` equates); qltools C source (the QDOS floppy filesystem is
  closely related and its source documents directory/map structures).

**Local known-good reference images** (cross-check parsing against these
BEFORE writing a single byte of the writer):
- `C:\Users\tomco\app\ql\Pitman.MDV`
- `C:\Users\tomco\app\ql\mdv_pawn\QL Pawn Boot.mdv` (and siblings)
If the verifier can't parse these, the format understanding is wrong.

## Constraints & repo conventions (read CLAUDE.md first)

- Format/hardware facts are verified against primary sources (Minerva
  source, official manuals, emulator source code) before use; published
  summaries have been wrong before in this project.
- `boot` files inside images must be LF-only. Executables: file type 1
  + dataspace in the QDOS header (game8 uses `DATASPACE := 512`).
- Docs style: self-contained deep dives that cite sources and record
  hard-won gotchas. Update README layout + CLAUDE hard-won rules where
  relevant. Commit style: imperative subject, body explains why, ends
  with the Claude co-author line (see git log).

## Acceptance criteria

1. `python tools/mkmdv.py --verify <image>` parses the Pitman/Pawn
   known-good images correctly (lists files, sizes, headers, no
   checksum errors).
2. `make mdv` in `game8/` produces `game8.mdv`; verify mode round-trips
   it cleanly (map/directory/checksums valid, `boot` + `game8_bin`
   present, dataspace 512 on the executable).
3. Q-emuLator boots the image: mount `game8.mdv` as MDV1 (a `.QCF` can
   reference an image in a drive slot — check `Q-emuLator.pdf` in the
   emulator's install dir for the exact key; `MdvImageDriver=QDOS`
   already appears in our QCFs) and confirm the game auto-boots and
   runs identically to the qlpak version. Process/window checks can be
   automated; final visual confirmation is the user's.
4. The image is ready to copy to a Next SD card unchanged (nothing
   Q-emuLator-specific inside).

## Validation strategy notes

- Build the **verifier first** against the known-good images, then the
  writer — the verifier is the oracle for the writer.
- Cross-check option if stuck: Q-emuLator itself can FORMAT an mdv
  image and COPY files onto it from a mounted directory (SuperBASIC
  boot script in a builder qlpak); an image it produces is a byte-level
  reference for what the writer should emit.
- Keep the emulator closed during builds (it locks mounted files).

## Out of scope

QXL.WIN builder (future: when a project outgrows ~110 KB or targets
QL-SD hardware), floppy images (Next core doesn't support them yet),
changes to the takeover/game code itself.
