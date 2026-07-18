# Sinclair QL — 68000 Assembly Projects

Cross-development workspace for the Sinclair QL (Motorola 68008, QDOS):
write assembly on Windows, assemble with a modern cross-toolchain, and run
the result in the Q-emuLator emulator with one command.

## Prerequisites

| Tool | Where | Notes |
|---|---|---|
| vasm + vlink | `C:\Users\tomco\app\vasm\` | 68k cross-assembler (`vasmm68k_mot.exe`, Motorola/Devpac syntax) and linker. Not on PATH by design; Makefiles use the full path. From <http://sun.hasenbraten.de/vasm/> |
| GNU make | `scoop install make` | Drives the builds |
| Q-emuLator 4 | `C:\Program Files (x86)\QemuLator\QemuLator 4\` | Windows QL emulator (QDOS JS ROM), runs our `.qlpak` packages |

## Quick start

```
cd hello
make        # assemble hello.asm and package hello.qlpak
make run    # launch Q-emuLator with it (auto-boots and runs the job)
make clean
```

Close Q-emuLator before rebuilding — it keeps the `.qlpak` file locked
while running.

## Layout

```
hello/            "Hello, World!" QDOS job — the template for new programs
  hello.asm       68008 source (QDOS job with its own console window)
  boot            SuperBASIC boot file that EXECs the binary (LF endings!)
  hello.QCF       Q-emuLator session config bundled into the package
  Makefile        all / run / clean
takeover/         bare-metal demo: seizes the machine from QDOS, bounces a
                  dot on the mode 4 screen with VBL sync (one-way — reset
                  to exit)
sound_test/       takeover demo + music: same bouncing dot, plus a looping
                  melody played by bit-banging the 8049 IPC directly
                  (ipc_sound.asm: the low-level send/receive + beep/kill
                  routines; sound_test.asm: frame-counted melody player)
tools/
  mkqlpak.ps1     shared: adds the QDOS executable header + zips the .qlpak
docs/             deep dives (see below)
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

## External references

- QL scene orientation notes (emulators, OS landscape, hardware):
  Obsidian vault, `Retro/QL/Sinclair QL - Technical Landscape.md`
- [QDOS/SMS Reference Manual](https://ia801404.us.archive.org/0/items/SinclairQLHomepage/docs/manuals/QDOS%20_%20SMS%20Reference%20Guide%20v4.3.pdf) — the OS API bible
- [Minerva ROM sources](https://github.com/MarcelKilgus/Minerva) — readable
  QDOS reimplementation; `inc/` holds the authoritative trap equates
- [chibiakumas QL tutorials](https://www.chibiakumas.com/68000/sinclairql.php)
- [vasm docs](http://sun.hasenbraten.de/vasm/release/vasm.html) (site is HTTP-only)
- [The QL Forum](https://theqlforum.com/) · [QL Wiki](https://qlwiki.theqlforum.com/)
