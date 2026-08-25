# Vector line performance — the road to 3D

How fast can the QL draw lines? The scoreboard for the line-drawing
experiments (`lines/`), aiming at wireframe 3D. Inspiration: the Atari ST
scene's line-routine arms race (atari-forum.com t=9549) — their classic
figure is **~15 full-screen (320 px) lines/frame ≈ 4800 px/frame** on an
8 MHz 68000, achieved with per-octant specialized loops, fixed-point
slope-adds instead of Bresenham's error branch, unrolling/self-modifying
code, and buffering pixels in registers to cut memory traffic.

## The rig (`lines/lines.asm`)

Draw lines *continuously* from a fixed table, round-robin, testing the
frame bit between lines; at each VBL the counts are accumulated, and every
256 frames (~5 s) the averages are latched to two on-screen 16-bit binary
counters (MSB left, one 8-px cell per bit, dashed ruler marking the cells):
**pixels/frame** on top, **lines/frame** below. The rig self-throttles —
no tuning loop — and the drawn fan doubles as the correctness check.

Test pattern: a 92-line fan, centre (256,120) to border points every
16 px — all octants, exact horizontal/vertical/diagonal cases, average
major-axis length ≈ **187 px** (best case for setup amortization; a
short-line table for cube-sized edges is future work). MODE 4, green
plane only = 1 byte RMW per pixel (white doubles the writes).

The averaging window spans ~12 fan cycles: a 32-frame window made the
pixel counter visibly wander because the fan *phase* (which mix of long
border lines lands in the window) shifted between windows.

## Results (Q-emuLator, Speed=QL, 128K)

Budget: 7.5 MHz / 50 Hz = **150 000 CPU cycles per 20 ms frame**.

Tables: **fan** = the 92-line all-octant fan (avg 187 px);
**shallow** = its 28 left/right-border lines only (avg 256 px, slopes
1:2.5 to 1:32 -- the fast path's class, `shallow equ 1`).

| Variant | table | lines/f | px/frame | eff. cyc/px | notes |
|---|---|---|---|---|---|
| Baseline Bresenham | fan | 4.6 | 853 | 176 | 3 loops (x-maj, y-maj L/R), incremental addr+mask |
| Baseline Bresenham | shallow | 3.4 | 879 | 171 | baseline is slope-uniform (control run) |
| + xfast dispatch | fan | 5.8 | 1078 | 139 | **1.26x** -- gain diluted by the fan's slope mix |
| + xfast dispatch | shallow | 6.5 | 1677 | 89 | **1.91x** on the class it targets |

(Measured 2026-08-25; fan visually verified, and xfast is pixel-identical
to the baseline by exhaustive simulation -- `use_fast equ 0/1` to A/B.)

**Caveat** (docs/qemulator.md): Q-emuLator applies a uniform QL-speed rate,
no per-region video-RAM contention — variant *comparisons* are meaningful,
absolute numbers approximate. Cross-check: game8's headroom calibration
found the same ≈2× factor over naive 68008 cycle counts that this
measurement shows, so the two rigs agree.

## Analysis of the baseline

Nominal 68008 count for the x-major inner loop (byte bus: each
instruction word ≈ 8 clocks of fetch), common path:

| step | cycles |
|---|---|
| `or.b d4,(a0)` — the actual pixel | 24 |
| `add.w d2,d3` — error term | 8 |
| `bmi.s` skip minor step | 18 |
| `ror.b #1,d4` — x step | 12 |
| `bcc.s` skip word advance | 18 |
| `dbf` | 18 |
| **total** | **~98** |

Only a quarter of the time is the pixel write; **the three branches cost
more than half**. That is exactly why the ST routines went branchless.
Observed 176 effective ≈ 98 × 1.8 — the emulator's ~2× uniform factor,
matching game8's headroom-gauge calibration.

## Round 2: byte-granular shallow lines (xfast)

The planned "byte-combining" turned into **slope-classed dispatch** — the
same architecture the ST routines converged on — because any
byte-building loop pays a flush (~100 cycles nominal) at every y-step:
near-diagonal lines step every 1–2 px and would *lose* to the plain loop.
So `draw_line` dispatches x-major lines with |dx| ≥ 2|dy| to `xfast`:

- **Pending-run mask** (d4 = `$ff>>s`): the unrolled 8-slot byte block
  does only `add.w` (error) + untaken `bpl.s` per pixel — 20 nominal
  cycles; pixels reach memory as run masks, once per byte (`or.b` of the
  whole pending run) or per row-run at a y-step (8 out-of-line handlers,
  one per slot, each with its run-end/reopen mask pair).
- Lead-in/tail to the byte grid reuse the baseline body, so placement is
  pixel-identical to the baseline (verified by simulation over all fan
  lines + 5000 random lines).
- Measured: **89 eff. cycles/px on the shallow class (1.91×)**; pure
  horizontals approach ~28 nominal/px. Dispatch threshold 2:1 is right at
  the break-even the estimate predicted.

## What this means for 3D (so far)

A wireframe cube (12 edges × ~80 px ≈ 1000 px) now roughly fits one
frame at the fan mix (1078 px/frame) — before erase, transform, and
projection, so real scenes still need more. Remaining rounds, in
expected value order:

1. **Steep-line mirror of xfast** — vertical runs can't combine into
   bytes, but the same pending-run structure drops the per-pixel
   `ror/bcc` x-bookkeeping: ~1.3× on the y-major class.
2. **Unroll the mid-slope baseline** (1:1..2:1 lines, the worst class
   now) — dilutes `dbf`, ~15%.
3. **White lines** — 2 planes double the partial-byte writes, but xfast
   full bytes become one `move.w $ffff` (both planes, 8 px, ~20 cycles):
   white shallow lines may cost *less* per pixel than green ones.
4. **Short-line table** — real 3D edges are 40–80 px; setup amortization
   (~600 eff. cycles/line: div-free but ~30 instructions) matters more
   there.
5. Then the first **rotating wireframe** with double buffering (erase =
   redraw in black, halving the px budget) — and note for later: solid
   polygon fill is all horizontal runs, i.e. the regime where the byte
   tricks give 3000–5000 px/frame. Filled 3D may beat wireframe.
