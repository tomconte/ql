# Q-emuLator packaging and deployment

How we get a cross-assembled binary running in Q-emuLator 4
(`C:\Program Files (x86)\QemuLator\QemuLator 4\QemuLator.exe`). The format
details below were reverse-engineered from the working `QL Vroom.qlpak`
in `C:\Users\tomco\app\ql\` and verified with our own `hello.qlpak`.

## The .qlpak package

A `.qlpak` is an ordinary **zip** with a session config at the root and
one folder of QL files:

```
hello.qlpak
├── hello.QCF          session config (CRLF text)
└── hello/             the "package" directory
    ├── boot           SuperBASIC, auto-run at power-on (LF-only!)
    └── hello_bin      executable, with ]!QDOS File Header prefix
```

Opening the package (double-click, or `QemuLator.exe hello.qlpak`) starts
an emulator session from the `.QCF`. With `Slot1=PAK:` +
`PakDir1=hello` + `UseFloppyName=Yes`/`FloppyName=FLP`, the package
directory is mounted as **FLP1**, QDOS auto-LRUNs `flp1_boot`, and the
boot script `EXEC_W`s the binary. Zip entry paths must use forward
slashes (pwsh `Compress-Archive` does; Windows PowerShell 5.1's may not).

While a session is running the `.qlpak` stays **locked** — close
Q-emuLator before rebuilding.

## The .QCF config

Plain `Key=Value` lines, CRLF. The keys we use (see `hello/hello.QCF`,
cloned from the Vroom package):

| Key | Meaning |
|---|---|
| `Ram=128K` | machine memory (a stock QL) |
| `MainRom=QL ROMs\QL_ROM_JS` | ROM, path relative to the Q-emuLator install dir |
| `Slot1=PAK:` / `PakDir1=<dir>` | mount the package folder in drive slot 1 |
| `UseFloppyName=Yes` / `FloppyName=FLP` | slot appears as FLP1 |
| `AutoStartSession=Yes` / `FastStartup=Yes` | boot immediately, skip splash |
| `FirstKey=F1` | auto-answer the F1-monitor/F2-TV boot prompt |
| `Speed=QL` | authentic 7.5 MHz speed (`Full` = host speed) |
| `DisplayMode=Window` / `WindowHeight=370` | windowed display |

Unknown/omitted keys fall back to the emulator's saved defaults.

## The ]!QDOS File Header prefix

QDOS keeps a file's type and dataspace in its *directory header*, which
plain Windows files and zip entries can't store. Q-emuLator's convention:
prepend a **30-byte header** to the file content. Layout (all big-endian):

| Offset | Size | Content |
|---|---|---|
| 0 | 18 | ASCII `]!QDOS File Header` |
| 18 | 1 | `$00` |
| 19 | 1 | `$0F` — total header length in 16-bit words (15 = 30 bytes) |
| 20 | 2 | file type: `$0001` = executable |
| 22 | 4 | dataspace in bytes |
| 26 | 4 | `$00000000` (extra info) |
| 30 | — | the real file content starts here |

`hello/mkqlpak.ps1` writes this prefix (dataspace from the Makefile's
`DATASPACE` variable) and builds the zip. Files *without* the prefix are
served to QDOS as plain data files — fine for `boot`, fatal for
anything you want to `EXEC`.

An alternative convention used by other tools is the **XTcc trailer**
(`XTcc` + dataspace long appended at the end, produced by the xtc68 C
cross-compiler); we standardized on the header prefix because it's what
Q-emuLator's own packages use.

## Debugging tips

- `qemulator.log` is written **on exit** to
  `%LOCALAPPDATA%\QemuLator\qemulator.log` (4.0.4; the copy in the
  install dir is a stale one from an older version). It lists ROM loads,
  drivers, the emulator/QDOS versions of the last session, and where
  each job was loaded (`Loaded glider_bin from 3b7e8 to 3ddfc`).
- To see the screen or read memory without a human, use `tools/qlshot.py`
  (next section) instead of screen capture: desktop grabs come back black
  (HDR) and `PrintWindow` white (Direct3D) on this machine.
- The window title shows the loaded package name (e.g. "hello -
  QemuLator") — a quick check that the qlpak was accepted.
- A binary that `EXEC`s but crashes immediately usually has a missing or
  too-small dataspace, or non-PC-relative addressing.
- To poke around interactively: the boot script ends back in SuperBASIC,
  where `DIR flp1_` lists the package contents and you can `EXEC` things
  by hand.
- Q-emuLator ships a 68k debugger DLL (`debug_68k.dll`, manual:
  `docs\debug_68k.pdf` in the install dir) for when things get serious.
- **Timing model** (measured via game8's headroom gauge): `Speed=QL`
  applies a uniform rate — per-region video-RAM contention is *not*
  simulated. Moving code to uncontended expansion RAM (`Ram=640K`, job
  loads high) changed nothing here, though it should help on real
  hardware or an accurate FPGA clone. Performance conclusions from
  Q-emuLator are therefore approximate; contention-sensitive
  optimizations need real hardware to evaluate.

## Looking inside a running emulator: qlshot

`tools/qlshot.py` reads the emulated QL out of the Q-emuLator process
(read-only `ReadProcessMemory`, stdlib `ctypes`) and turns it into a PNG
of the displayed screen or into numbers:

```
make shot                                  # relaunch, wait 3 s, qlshot.png, close
make shot SHOTWAIT=14 PEEK="headroom+12:w headroom+32:w*4"
python ../tools/qlshot.py shot -o x.png    # the emulator already running
python ../tools/qlshot.py peek kbd_cur:b '$28034:b' 'emtab:w*8'
python ../tools/qlshot.py info             # block, screen, mode, load address
python ../tools/qlshot.py close            # WM_CLOSE: clean exit, log written
```

Peek specs are `EXPR[:SIZE][*COUNT]`: SIZE `b`/`w`/`l` (prefix `s` for
signed, default `w`), EXPR a label, `$hex`, `0xhex` or decimal with `+`/`-`
offsets. Labels come from `<name>.lst`, the vasm listing `make` writes
(`-L`, same binary), and are relocated to where QDOS loaded
`<name>_bin`. qlshot finds that by searching RAM for the binary's first
64 bytes and takes the highest hit (a QDOS slave block can cache a copy
lower down; the job sits above it). An equate prints its value.

What it relies on (found and checked 2026-09-29 on 4.0.4, 32-bit):

- **QL memory is one flat, big-endian block** in the emulator's heap:
  QL address 0 (the ROM) at the start of a private read-write allocation
  of RAM top + 4K ($41000 for 128K). It moves on every launch; qlshot
  finds it by matching the block's first 64 bytes against the ROM images
  in the install dir's `QL ROMs`. The I/O area is not mirrored in it:
  `$18063` reads 0 whatever the program writes.
- **Display state lives in QemuLator.exe's static data** (fixed image
  base $400000, no ASLR): a long at `$6648D0` holds the QL address of the
  displayed screen ($20000/$28000; flips every frame under flip8, steady
  $20000 under QDOS) and a byte at `$671526` is nonzero in mode 8
  (followed `sv_mcsta` through MODE 8/MODE 4 switches, 56/56 samples).
  A long at `$671E08` points to the QL memory block; qlshot trusts the
  other two only when that pointer matches, so a different build falls
  back to the QDOS sysvars (sv_ident $D254 at $28000: screen 0, mode
  from sv_mcsta) or, after a takeover, to both screens stacked and
  `--mode`.
- **Re-deriving the statics** after an emulator update (`EMU_STATICS` in
  qlshot.py): snapshot the exe's writable image sections several times
  under flip8, game8 (mode 8) and flip, hello (mode 4); the mode byte is
  the one stable within each run that separates the two groups, and the
  screen long is the one that alternates $20000/$28000 under flip8 but
  holds $20000 under hello. The memory pointer is the long equal to the
  block address.

## IPC reads and frame timing

Measured on the glider rig (2026-09-10): a KEYROW read (`kbd_row`, 16
IPC bit transactions) at the top of the frame loop turned 47% of the
loops into spurious 2-beat loops with a minimum idle count of 1 spin,
while the average work per frame was unchanged (16.3 ms with or
without the read). The emulated 8049's replies appear to be serviced
on the emulator's frame clock, so a read can stall until a tick, and
the frame then misses the beat. Without the read the same loop locked
at 50 Hz (2 spills in 128). Place IPC reads after the frame's work
and its beat classification, before the VBL wait: a stall then only
eats idle time. Real hardware is not expected to behave this way (the
8049 answers asynchronously, about 0.5 ms per KEYROW); measure there
before drawing conclusions about the IPC's real cost.
