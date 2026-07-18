# Taking over the machine (games & demos)

How a QDOS job seizes the whole QL — CPU, screen, interrupts — the way
games and demos do. `takeover/takeover.asm` implements this. Sources:
QDOS/SMS Reference Guide v4.3 (§2.2 traps, §2.2.3 atomic actions, §10
hardware), the Minerva ROM sources (`inc/mc`, `inc/pc`), and the
chibiakumas QL tutorials.

## The takeover sequence

```asm
        trap    #0                  ; 1. enter supervisor mode
        move.w  #$2700,sr           ; 2. mask all interrupts
        lea     mystack(pc),sp      ; 3. own supervisor stack
        move.b  #0,$18063           ; 4. own the display
```

1. **TRAP #0** is QDOS's documented "special trap for entering supervisor
   mode" (its intended use is bracketing atomic actions). Only the stack
   pointer changes; execution continues at the next instruction in
   supervisor mode. Works on QDOS, Minerva and SMSQ/E.
2. With all interrupt levels masked, the 50 Hz frame interrupt never
   reaches the ROM handler: no scheduler, no keyboard scan, no SuperBASIC.
   QDOS is still in memory but will never run again.
3. After TRAP #0 the SSP points into QDOS's supervisor stack (jobs are
   only promised 64 bytes there) — point it at your own buffer.
4. From here on, hardware is yours. QDOS system calls are off-limits.

**This is one-way.** Restoring QDOS would mean unwinding the supervisor
state, re-enabling interrupts and returning through the job mechanism —
in practice nobody does; games end with a reset. Design for it: the demo
loops forever, and you exit by resetting/closing the emulator.

Notes:
- You cannot rewrite the 68008 exception vectors — addresses 0–$3FF are
  ROM on the QL. Custom handlers go through QDOS (MT.TRAPV for per-job
  exception vectors) *before* takeover, or you simply mask interrupts and
  poll, as we do.
- If you want to stay QDOS-friendly instead (keyboard, sound, multitask),
  the alternative is hooking the 50 Hz **polled task list** (MT.LPOLL) —
  handlers end with RTS, and QDOS survives. That's the civilised route;
  this document is about the uncivilised one.

## Hardware registers

Verified against the Minerva sources; the reference manual (§10.1) lists
the same map. All are on the 68008's byte-wide bus.

| Address | Chip | Read | Write |
|---|---|---|---|
| `$18021` | ZX8302 | pending interrupts, bits 4..0 | write a set bit to clear it |
| `$18063` | ZX8301 | — (write-only) | display control |

**`$18021` (pc_intr)** read bits: 0 gap, 1 interface, 2 transmit,
3 **frame (50/60 Hz)**, 4 external. Bits 5–7 are *not* interrupt flags
(clock LSB, microdrive-running, baud clock) and change constantly — mask
them off when testing. Write bits 5–7 are interrupt-enable masks for
gap/interface/transmit.

**`$18063` (mc_stat)** write bits: 1 = blank display, 3 = mode
(0 = 512-pixel/4-colour, 1 = 256-pixel/8-colour), 7 = screen base
(0 = $20000, 1 = $28000 — "dual screen", unsupported by QDOS). All other
bits are reserved: write zeros. The register is write-only, so keep your
own copy if you toggle things.

## VBL sync by polling

The ZX8302 sets the frame bit at every vertical blank regardless of the
CPU interrupt mask, so with interrupts dead we sync by polling:

```asm
        move.b  #%00001000,$18021   ; ack the frame bit
wait:   btst    #3,$18021           ; wait for the next vblank
        beq.s   wait
```

Ack first, then wait: that guarantees one full loop iteration per frame
(50 per second on PAL). Test **bit 3 only** — code that tests the whole
byte (as some tutorials do) falls through immediately because of the
clock/microdrive bits.

## Mode 4 screen layout

32 KB at `$20000`, 512×256, 128 bytes per line, addressed in raster
order. Each 16-bit word covers 8 pixels in two colour planes:

```
even byte (high): G7 G6 G5 G4 G3 G2 G1 G0     bit 7 = leftmost pixel
odd  byte (low):  R7 R6 R5 R4 R3 R2 R1 R0
```

Per pixel: green+red = white, green only, red only, neither = black.
For pixel (x, y):

```
word address = $20000 + y*128 + (x >> 3)*2
bit          = 7 - (x & 7)        ; in both bytes of the word
```

A shape at arbitrary x straddles two words; build a 16-bit mask and split
it (see `calcpos`/`draw` in takeover.asm). OR into both planes to draw
white, AND the complement to erase.

## Mode 8 (for later)

Set bit 3 of `$18063`: 256×256, 8 colours + per-pixel flash, 4 bits per
pixel, same 32 KB / 128 bytes per line. Word layout
(manual §10.2):

```
even byte: G3 F3 G2 F2 G1 F1 G0 F0     4 pixels per word
odd  byte: R3 B3 R2 B2 R1 B1 R0 B0
```

G/R/B combine to 8 fixed colours; F is a hardware flash toggle (freezes
the background colour and flashes subsequent pixels until the next F bit
or end of line). Switching mode changes pixel addressing but not the
memory size or line stride.

## What you give up (future work)

- **Keyboard/joystick/sound** live behind the 8049 IPC on a bit-banged
  serial link (`$18003`). QDOS talks to it via MT.IPCOM/SMS.HDOP; after
  takeover you'd have to speak the IPC protocol yourself — doable, and
  the usual way games read keys post-takeover. Deep dive for another day.
- **Timing**: no scheduler means all timing comes from counting frames.
- On real hardware and accurate emulators (Q-emuLator), microdrive access
  is impossible after takeover — load everything first.
