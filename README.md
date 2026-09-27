# Sinclair QL — 68000 Assembly Projects

Cross-development workspace for the Sinclair QL (Motorola 68008, QDOS):
write assembly on Windows, assemble with a modern cross-toolchain, and run
the result in the Q-emuLator emulator with one command.

The programs build on each other: a QDOS "Hello, World!", bare-metal
takeover demos with sound, double buffering and direct keyboard reads,
then line drawing, a wireframe 3D engine, and the game it is growing
into, [`glider/`](glider/README.md).

## Prerequisites

| Tool | Where | Notes |
|---|---|---|
| vasm + vlink | `C:\Users\tomco\app\vasm\` | 68k cross-assembler (`vasmm68k_mot.exe`, Motorola/Devpac syntax) and linker. Not on PATH by design; Makefiles use the full path. From <http://sun.hasenbraten.de/vasm/> |
| GNU make | `scoop install make` | Drives the builds |
| Python 3 | on PATH | The build tools in `tools/` (standard library only) |
| PowerShell 7 | `pwsh` on PATH | Packaging script and the `run` targets |
| Q-emuLator 4 | `C:\Program Files (x86)\QemuLator\QemuLator 4\` | Windows QL emulator (QDOS JS ROM), runs our `.qlpak` packages |

## Quick start

```
cd hello
make        # assemble hello.asm and package hello.qlpak
make run    # launch Q-emuLator with it (auto-boots and runs the job)
make clean
```

In `game8/`, `shapes/` and `glider/` additionally:

```
make mdv    # build <name>.mdv, a QLay-format Microdrive image (verified)
make runmdv # boot it in Q-emuLator via the real QDOS mdv driver
```

The `.mdv` is the portable artifact: the same file boots in Q-emuLator,
on the ZX Spectrum Next QL core (copy to SD card) and on a real QL with
a vDriveQL.

Close Q-emuLator before rebuilding — it keeps the `.qlpak` (and any
mounted `.mdv`) locked while running.

In `hello/` and `glider/`, `make` first checks the register contracts
(`tools/regcheck.py`) and stops on a problem; `make check` runs the
check alone. The rules are in [CLAUDE.md](CLAUDE.md).

## Layout

```
hello/            "Hello, World!" QDOS job — the template for new programs
  hello.asm       68008 source (QDOS job with its own console window)
  boot            SuperBASIC boot file that EXECs the binary (LF endings!)
  hello.QCF       Q-emuLator session config bundled into the package
  Makefile        all / check / run / clean
takeover/         bare-metal demo: seizes the machine from QDOS, bounces a
                  dot on the mode 4 screen with VBL sync (one-way — reset
                  to exit)
sound_test/       takeover demo + music: same bouncing dot, plus a looping
                  melody played by bit-banging the 8049 IPC directly
                  (ipc_sound.asm: the low-level send/receive + beep/kill
                  routines; sound_test.asm: frame-counted melody player)
flip/             double-buffered takeover demo: ten 16×16 sprites + the
                  melody, page-flipping between screen 0 ($20000) and
                  screen 1 ($28000, the ex-sysvars area) at VBL — the
                  tear-free way to draw scenes bigger than the blanking
                  window
flip8/            the same demo in mode 8: 256×256, all seven visible
                  colours, 8×16 sprites (visually square — mode 8 pixels
                  are double-wide); only the pixel-format code differs
game8/            proto-game skeleton (mode 8): arrows move the player,
                  space fires a bolt with a laser sfx over the music —
                  keyboard read directly from the 8049 IPC, one KEYROW
                  round trip per frame; sprites cover all seven visible
                  colours on the black playfield
lines/            line-drawing benchmark (mode 4): a fan of lines redrawn
                  flat out, pixels per frame counted on screen — the
                  numbers behind docs/vector-perf.md
cube/             first 3D milestone: a rotating white wireframe cube,
                  double-buffered at a steady 25 Hz
shapes/           the reference 3D engine: a parade of five validated
                  meshes with backface culling, box erase, colour lines
                  and live performance meters
glider/           the game in progress: a first-person wireframe hovercraft
                  raid over a flat world (see glider/README.md)
lib/
  ipc_sound_takeover.asm  shared: IPC sound for takeover programs (the
                  sysvar-reading snd_clrint removed; original kept in
                  sound_test/)
  ipc_keys_takeover.asm   shared: IPC keyboard (command 9 / KEYROW);
                  include after the sound lib
  draw_line.asm   shared: mode 4 line drawer in red, green or white
  draw_line_w.asm shared: the white (both planes) drawer it calls
  draw_dec.asm    shared: 6-digit decimal readout (meters, scores)
tools/
  mkqlpak.ps1     shared: adds the QDOS executable header + zips the .qlpak
  mkmdv.py        shared: builds + verifies QLay-format .mdv Microdrive
                  images
  gensin.py       sine table (8.8 fixed point) as a vasm include
  genmesh.py      meshes as data, validated (closed, consistent winding)
                  and emitted as vasm include tables
  regcheck.py     register-contract checker, run by make before vasm
docs/             deep dives (see below)
specs/            specs written before building a tool (mkmdv)
CLAUDE.md         conventions and hard-won rules (written for Claude Code,
                  useful to humans too)
```

## Documentation

- [docs/qdos-programming.md](docs/qdos-programming.md) — anatomy of a QDOS
  job, trap call reference (verified against the Minerva ROM sources),
  console windows, dataspace.
- [docs/qemulator.md](docs/qemulator.md) — the `.qlpak` package format, the
  `.QCF` config file, and the `]!QDOS File Header` executable prefix.
- [docs/takeover.md](docs/takeover.md) — taking over the machine for games
  and demos: TRAP #0 / supervisor mode, masking interrupts, VBL sync by
  polling, and the mode 4 / mode 8 screen layouts.
- [docs/mdv-format.md](docs/mdv-format.md) — the QLay `.mdv` container and
  the QDOS Microdrive filesystem (sectors, checksums, map, directory),
  established from the Minerva/QLay sources.
- [docs/vector-perf.md](docs/vector-perf.md) — line-drawing measurements,
  cycle analysis and the optimisation roadmap toward wireframe 3D.
- [docs/engine-spec.md](docs/engine-spec.md) — the game's design: concept,
  flight model, rendering, budgets, milestones and open questions.
- [docs/mister-flip-latch-issue.md](docs/mister-flip-latch-issue.md) — why
  double-buffered programs flicker on the MiSTer QL core (a core bug,
  reported upstream).

## External references

- QL scene orientation notes (emulators, OS landscape, hardware):
  Obsidian vault, `Retro/QL/Sinclair QL - Technical Landscape.md`
- [QDOS/SMS Reference Manual](https://ia801404.us.archive.org/0/items/SinclairQLHomepage/docs/manuals/QDOS%20_%20SMS%20Reference%20Guide%20v4.3.pdf) — the OS API bible
- [Minerva ROM sources](https://github.com/MarcelKilgus/Minerva) — readable
  QDOS reimplementation; `inc/` holds the authoritative trap equates
- [chibiakumas QL tutorials](https://www.chibiakumas.com/68000/sinclairql.php)
- [vasm docs](http://sun.hasenbraten.de/vasm/release/vasm.html) (site is HTTP-only)
- [The QL Forum](https://theqlforum.com/) · [QL Wiki](https://qlwiki.theqlforum.com/)
