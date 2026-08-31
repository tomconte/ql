# Upstream issue for MiSTer-devel/QL_MiSTer

Written Aug 2026, against `master` at that date; **filed upstream Aug
2026**: <https://github.com/MiSTer-devel/QL_MiSTer/issues/9>
(cross-file with the MEGA65 port, where the behaviour was observed,
once there's movement). Status: the Tang Nano port has the
corrected latch and displays our double-buffered programs correctly
(verified Aug 2026); the MEGA65 port waits on the upstream merge. Our
code keeps the classic draw → wait → flip protocol and ships no
workaround — background in `takeover.md` ("Double buffering"). The
filed issue text follows the line.

---

**Title:** ZX8301 latches the screen base before the frame interrupt is
raised — double-buffered software always displays its work buffer

## Summary

`rtl/zx8301.v` samples `mc_stat[7]` (the screen-base / dual-screen bit)
into the video fetch address once per frame, ~24 lines **before**
`rtl/zx8302.v` raises the frame interrupt for that vertical blank. As a
result, the classic QL double-buffering protocol — draw into the hidden
screen, wait for the frame bit at `$18021`, write the flip to `$18063` —
misses the latch on every frame: the flip takes effect one frame late.

In steady state this inverts double buffering: the screen being scanned
out is always the one the program is currently erasing and redrawing.
Software shows half-erased, flickering frames instead of tear-free
animation. Emulators (verified with Q-emuLator) show the same software
pixel-perfect.

Observed on the MEGA65 port of this core (which uses the same RTL); the
analysis below is from this repository's sources, so MiSTer itself
should behave identically — worth a quick confirmation on MiSTer
hardware.

## Root cause

`zx8301.v` — the base is committed for the next frame at line 257 of the
PAL frame (`V = 256`, one line after the active area):

```verilog
if((v_cnt == V+1) && (h_cnt == H+1))
    addr <= membase ? 15'h4000 : 15'h0000;  // word! address
```

but `vs` — the signal whose rising edge sets the frame interrupt in
`zx8302.v` — only rises 24 lines later, at line 281
(`PAL_VFP = 25`):

```verilog
if(v_cnt == V+vfp) begin
    vs <= 1;
    ...
```

`zx8302.v` then latches it correctly (this side is fine):

```verilog
else if(~old_vs & vs) vsync_irq <= 1'b1;
```

Timeline of one PAL frame (312 lines):

| line    | event                                                        |
|---------|--------------------------------------------------------------|
| 0–255   | active display                                               |
| **257** | `addr` latched from `mc_stat[7]` — next frame's base is now fixed |
| **281** | `vs` rises → `vsync_irq` set — the CPU learns about vblank here |
| 287     | `vs` falls                                                   |
| 311→0   | counters wrap, fetch of the next frame begins                |

Any `$18063` write made in response to the frame interrupt therefore
arrives ~24 lines after the latch and only shows up one frame later.
With NTSC timing the margin is 1 line instead of 24, but the order is
the same, so the bug is too.

On a real QL the exact moment the ZX8301 applies the DB bit is
undocumented, but the frame interrupt marks the start of the blanking
period, and the software protocol (used since the 1980s: wait for frame
interrupt, then flip) requires that a flip written just after the
interrupt is visible on the very next frame. The current core makes
that protocol impossible by construction. QDOS itself never touches
screen 1, which is presumably why this has gone unnoticed.

## Reproduction

Any program of this shape (full takeover, interrupts masked):

```asm
loop:   ; draw the next frame into the hidden screen
        move.b  #%00001000,$18021   ; ack the frame bit
wait:   btst    #3,$18021
        beq.s   wait                ; wait for vblank
        move.b  d7,$18063           ; flip: $00 <-> $80
        bchg    #7,d7
        bra.s   loop
```

Expected: tear-free animation, each frame complete.
Actual: every displayed frame is the buffer being redrawn — partially
erased content, missing lines, flicker.

I have a self-contained test binary (a wireframe-3D demo on a bootable
MDV image) that shows the artifact immediately and can attach it —
both the affected build and one with the `$18063` write moved before
the wait loop, which the analysis above predicts runs clean.

## Suggested fix

Latch the base after `vs` has risen instead of before, e.g. at the end
of the vsync pulse:

```verilog
if((v_cnt == V+vfp+vsw) && (h_cnt == H+1))
    addr <= membase ? 15'h4000 : 15'h0000;
```

Any line between the `vs` rise and the first memory-enable of the next
frame works (287–310 for PAL, 260–261 for NTSC); the point is only that
the interrupt must come first. One-line change; I have not synthesized
it myself.

## Workaround for software authors

Write the flip at draw-completion, before waiting for the frame bit.
That runs correctly on this core and in emulators, at the cost of ~1.5
ms of the theoretical frame budget.
