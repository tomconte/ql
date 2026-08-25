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

| Variant | lines/frame | px/frame | eff. cycles/px | notes |
|---|---|---|---|---|
| Baseline Bresenham | 4.6 | 853 | ~176 | 3 loops (x-maj, y-maj L/R), incremental addr+mask |

(Measured 2026-08-25; fan visually verified correct in all octants.)

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

## What this means for 3D (so far)

A wireframe cube (12 edges × ~80 px ≈ 1000 px) eats a bit more than one
full frame at baseline — before erase, transform, or projection. So 50 Hz
is out and even 25 Hz needs the optimization rounds to earn real margin:

1. **Byte-combining for shallow runs** — build up to 8 pixels in a
   register, one write per byte instead of one RMW per pixel; kills the
   per-pixel `bcc` too. The big 68008 win (fetch+RMW dominate).
2. **Fixed-point slope-add** (EarX's ST method) — one division at setup,
   then `add` + carry instead of the error-term branch.
3. **Unrolling** — dilutes the `dbf`.
4. Then: white (2-plane) cost, short-line setup overhead, and the first
   rotating wireframe with double buffering (erase = redraw in black,
   i.e. the px/frame budget halves).
