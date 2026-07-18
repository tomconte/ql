# QDOS assembly programming

How to write a QDOS program in 68000 assembly that behaves like a proper
citizen: a *job* with its own console window, started with `EXEC`/`EXEC_W`,
that cleans up after itself. `hello/hello.asm` implements everything on
this page.

## Anatomy of a job

A QDOS executable is a **file of type 1** whose header carries a
**dataspace** value (see below). Execution starts at byte 0 of the file.
By convention the file begins with a standard job header so utilities can
identify the job by name:

```asm
start:
        bra.s   main            ; skip the header
        dc.l    0
        dc.w    $4afb           ; "job name follows" flag
        dc.w    5               ; name length
        dc.b    'Hello'         ; the name shown by job-listing tools
        even
main:   ...
```

Code must be **position-independent** — QDOS loads jobs anywhere in RAM
and there is no relocation in a flat binary. Use PC-relative addressing
(`lea label(pc),a0`, `bsr`, `bra`) throughout; vasm errors out on most
accidental absolute references when they'd be wrong.

A job must terminate by removing itself (falling off the end crashes):

```asm
        moveq   #5,d0           ; mt_frjob
        moveq   #-1,d1          ; job id -1 = this job
        moveq   #0,d3           ; error code returned to EXEC_W
        trap    #1
```

## Dataspace

The dataspace is a per-executable value stored in the *file header*, not
in the file contents. QDOS allocates that many bytes above the loaded
code and points the user stack at the top of it (minus the startup
command-string info). It is your stack + scratch memory. 512 bytes is
plenty for a small job; be generous if you `bsr` deeply or buffer data.

Because plain Windows files/zips have no QDOS header, the dataspace must
travel some other way — for Q-emuLator that's the `]!QDOS File Header`
prefix added at packaging time (see [qemulator.md](qemulator.md)).

## Trap reference (verified)

Values checked against the Minerva ROM sources
(<https://github.com/MarcelKilgus/Minerva>, `inc/io` and `inc/sd`) —
don't trust random web tables, several disagree.

**Trap #1 — manager calls** (`d0` = key):

| Key | Value | Purpose |
|---|---|---|
| mt.frjob | $05 | force-remove job (`d1` job id, -1 = self; `d3` error code) |

**Trap #2 — channel open/close** (`d0` = key):

| Key | Value | Purpose |
|---|---|---|
| io.open | $01 | open channel: `a0` → counted name, `d1` owner job (-1 = self), `d3` mode; returns channel id in `a0`, error in `d0` |
| io.close | $02 | close channel in `a0` |

Open modes (`d3`): 0 io.old (exclusive), 1 io.share, 2 io.new,
3 io.overw, 4 io.dir.

**Trap #3 — I/O on an open channel** (`a0` = channel id, `d3.w` = timeout,
-1 = wait forever; error returned in `d0`):

| Key | Value | Purpose |
|---|---|---|
| io.pend | $00 | test for pending input |
| io.fbyte | $01 | fetch one byte → `d1.b` |
| io.fline | $02 | fetch line into `(a1)`, max `d2.w` bytes |
| io.fstrg | $03 | fetch `d2.w` bytes |
| io.edlin | $04 | edit line |
| io.sbyte | $05 | send byte in `d1.b` |
| io.sstrg | $07 | send `d2.w` bytes from `(a1)` |
| sd.bordr | $0c | window border: colour `d1.b`, width `d2.w` |
| sd.wdef | $0d | redefine window |
| sd.pos | $10 | absolute cursor position |
| sd.nl | $12 | newline |
| sd.clear | $20 | clear window to paper colour |
| sd.setpa | $27 | set paper colour `d1.b` |
| sd.setst | $28 | set strip colour `d1.b` |
| sd.setin | $29 | set ink colour `d1.b` |
| sd.setmd | $2c | set character mode |
| sd.setsz | $2d | set character size |

Errors come back negative in `d0.l` (0 = OK). QDOS newline is a single
LF (`$0A`) — it works in strings sent with io.sstrg.

## Console windows

Channel names are counted strings: a length word followed by the
characters. A console with geometry is
`con_<width>x<height>a<x>x<y>` (pixels), e.g.:

```asm
conname:
        dc.w    17
        dc.b    'con_320x120a96x60'   ; 320×120 window at (96,60)
```

The screen is 512×256 (mode 4) or 256×256 (mode 8). A freshly opened
window is *not* cleared — set border/paper/ink and sd.clear before
printing, or the desktop shows through.

**Colours** (mode 4): 0 black, 2 red, 4 green, 6 white (odd values add
contrast stipples; 7 renders as white). Mode 8 adds blue 1, magenta 3,
cyan 5, yellow 6→7 etc.

## Running under SuperBASIC

- `EXEC flp1_hello_bin` — start the job and return to BASIC immediately.
- `EXEC_W flp1_hello_bin` — start it and wait until it removes itself
  (the `d3` error code from mt.frjob becomes the return status).

Both are stock SuperBASIC keywords. A file named `boot` on the boot
device auto-LRUNs at power-on — that's how packaged programs start.
