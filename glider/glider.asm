; glider.asm -- M1 flight rig for the hovercraft raid (docs/engine-spec.md)
;
; First-person, yaw-only camera at a fixed height over a flat world:
; an IPC keyboard read on alternate frames (row 1: arrows + Enter), the
; section-4 flight model (ramped turn, thrust, drag = drift, brake then
; reverse),
; a world-aligned lattice of red ground dots, the fixed horizon, a
; reticle and HUD readouts. No objects yet: the craft spawns on an
; unbounded lattice. The rig exists to tune the flight constants (the
; equ block below) by feel and to measure the lattice budget.
;
; Scaffold from shapes/shapes.asm: MODE 4 takeover, double buffer with
; VBL flip, beat-scaled simulation (1|2 beats per loop), live headroom
; bar + averaged decimal meters (lib/draw_dec.asm). The lattice replaces
; the mesh pipeline; the erase is a per-buffer dot list instead of the
; bounding-box movem clear. The lattice is a wedge scan: per world row
; the four visibility tests bound the cell range analytically, and the
; dots project through two tables (row offset, reciprocal) built into
; the job's dataspace at startup -- the first version walked all 361
; cells and divided twice per dot, at 20 ms a frame.
;
; Assemble: vasmm68k_mot -m68008 -Fbin -o glider_bin glider.asm

; hardware
mc_stat     equ     $18063          ; ZX8301 display control (write-only)
pc_intr     equ     $18021          ; ZX8302 interrupt register
pc__frame   equ     3               ; bit 3 = 50/60 Hz frame interrupt

scr0        equ     $20000          ; screen 0 (displayed at boot)
scr1        equ     $28000          ; screen 1 (ex-QDOS sysvars, now ours)
scr_llen    equ     128             ; bytes per scan line

; ----- flight model (spec section 4) -- THE tuning knobs.
; Velocities are 8.8 world units per beat (20 ms), angles 8.8 brads
; (256 brads per turn; word wrap is the modulo). Terminal speed under
; drag alone is thrust << drag_shift = 24 units/beat with these values,
; below vmax: top speed is set by thrust/drag, the cap only bites in
; reverse (rev_max 20 < 24).
thrust      equ     384             ; 1.5 units/beat per beat
drag_shift  equ     4               ; v -= v >> 4 per beat (drift feel)
vmax        equ     48              ; forward speed cap, units/beat
brake_shift equ     2               ; Down: v -= v >> 2 per beat
rev_max     equ     20              ; reverse speed cap, units/beat
v_rest      equ     128             ; 0.5 units/beat: "at rest" threshold
rev_delay   equ     25              ; beats at rest before reverse engages
; Turn rates in 8.8 brads/beat: 256 = 1 brad/beat = 70 degrees/s. The
; spec's 1..3 (70..211 deg/s) strobed the near dots and outran the drag
; time constant (16 beats) so far that every turn became a sideways
; slide; 0.25..1.25 (17..88 deg/s) ramped over 0.6 s is the second try.
turn_min    equ     64              ; 0.25 brad/beat when a turn starts
turn_max    equ     320             ; 1.25 brads/beat
turn_ramp   equ     8               ; +1/32 brad/beat per beat held

; ----- camera and lattice (spec sections 5.1, 5.3). The viewport is
; shifted: the horizon sits in the upper part of the screen so the view
; is mostly ground (hovering over a plane); the projection stays linear
; (sy = horizon + y*yfocal/z), no pitch involved. Camera height and
; lattice spacing set how fast successive dot rows spread down the
; screen: 40/512 read as flat (rows 133,126,124,123...), 128/256 give
; 165,122,108,101,97,94. znear is derived so the nearest dot lands on
; the last play row.
cam_h       equ     128             ; camera height over the ground
horizon     equ     80              ; screen row of the horizon
xfocal      equ     256             ; sx = 256 + x*xfocal/z: 256 = 90-deg
                                    ; horizontal FOV, 384 = 67 deg
yfocal      equ     170             ; sy = horizon + y*yfocal/z; keep
                                    ; yfocal = xfocal*2/3 (mode 4 pixels
                                    ; are 1.5x taller than wide on 4:3)
playbot     equ     239             ; last play-area row (HUD from 240)
znear       equ     cam_h*yfocal/(playbot-horizon)+1 ; nearest depth drawn
zfar        equ     2048            ; farthest: 10 rows under the horizon
latd        equ     256             ; lattice spacing, MUST be 2^n
nwin        equ     zfar/latd+1     ; half-window in cells (+1: the
                                    ; in-cell offset eats up to a cell)
maxdots     equ     128             ; dot list capacity per buffer

; ----- HUD band (rows 240-255): separator 240, readouts 242-246 and
; 248-252, headroom bar 254-255
hb_y        equ     254             ; bar top line (2 rows tall)
hb_shift    equ     4
mwin        equ     128             ; meter window, loops (power of 2)
mshift      equ     7

; profiling flags: skip a stage to measure its cost as the meter delta
no_kbd      equ     0               ; skip the IPC keyboard read
no_lat      equ     0               ; skip the lattice (erase still runs)
no_hud      equ     0               ; skip the flight readouts

; craft state record offsets
c_px        equ     0               ; long, 16.8 world x
c_pz        equ     4               ; long, 16.8 world z
c_head      equ     8               ; word, 8.8 brads (0 = looking +z)
c_turn      equ     10              ; word, current turn rate (0 = released)
c_vx        equ     12              ; word, 8.8 units/beat
c_vz        equ     14
c_stop      equ     16              ; word, beats at rest with Down held
c_rev       equ     18              ; word, 1 = reversing
c_s         equ     20              ; word, sin head (8.8)
c_c         equ     22              ; word, cos head (8.8)
c_size      equ     24

; wbound: narrow the row's cell range [d4,d5] with the half-plane test
; whose record (DF.l, (2*nwin)*DF.l, DF>>16.w, pad) is at (a0), for
; f(t) = d0 + t*DF over t = 0..2*nwin; branches to \1 when no cell of
; the row passes. All/none come exactly from f at both row ends; a
; crossing is bounded by one divide on the integer parts with a 2-cell
; margin (error under 1/16 at the |DF>>16| >= 16 threshold; flatter
; slopes stay unbounded and the per-cell tests sort them out).
; Trashes d0, d1, d6; advances a0 to the next record.
wbound  macro
        move.l  (a0),d1             ; DF
        bmi.s   .wn\@
        beq.s   .wz\@
        tst.l   d0                  ; DF > 0: f rises along the row
        bge.s   .wx\@               ; f(0) >= 0: all pass
        move.l  d0,d6
        add.l   4(a0),d6            ; f(2*nwin)
        bmi     \1                  ; < 0: none pass
        move.w  8(a0),d1            ; DF>>16
        cmp.w   #16,d1
        blt.s   .wx\@               ; too flat to bound
        neg.l   d0
        swap    d0
        ext.l   d0                  ; -f(0) in units (floor)
        divs.w  d1,d0               ; crossing t in cells
        subq.w  #2,d0
        cmp.w   d0,d4
        bge.s   .wx\@
        move.w  d0,d4               ; lo = max(lo, t-2)
        bra.s   .wx\@
.wn\@:  tst.l   d0                  ; DF < 0: f falls along the row
        bmi     \1                  ; f(0) < 0: none pass
        move.l  d0,d6
        add.l   4(a0),d6            ; f(2*nwin)
        bge.s   .wx\@               ; >= 0: all pass
        move.w  8(a0),d1
        cmp.w   #-16,d1
        bgt.s   .wx\@               ; too flat to bound
        neg.w   d1
        swap    d0
        ext.l   d0                  ; f(0) in units (floor)
        divs.w  d1,d0               ; crossing t in cells
        addq.w  #2,d0
        cmp.w   d0,d5
        ble.s   .wx\@
        move.w  d0,d5               ; hi = min(hi, t+2)
        bra.s   .wx\@
.wz\@:  tst.l   d0                  ; DF = 0: f constant along the row
        bmi     \1
.wx\@:  lea     12(a0),a0
        endm

; ---------------------------------------------------------------- job header
start:
        bra.s   main
        dc.l    0
        dc.w    $4afb               ; "job name follows" flag
        dc.w    jobname_e-jobname
jobname:
        dc.b    'Glider'
jobname_e:
        even

; ----------------------------------------------------------------- take over
main:
        trap    #0                  ; QDOS: enter supervisor mode
        move.w  #$2700,sr           ; mask all interrupts -- QDOS is gone
        lea     sv_stack_top(pc),sp ; run on our own supervisor stack

        move.b  #0,mc_stat          ; mode 4, screen 0 displayed

        lea     scr0,a0             ; clear BOTH screens ($20000-$2FFFF)
        move.w  #$10000/4-1,d0
        moveq   #0,d1
.clr:   move.l  d1,(a0)+
        dbf     d0,.clr

        lea     scr0+240*scr_llen,a0    ; static HUD separator, both buffers
        lea     scr1+240*scr_llen,a1
        moveq   #-1,d1
        moveq   #32-1,d0
.sep:   move.l  d1,(a0)+
        move.l  d1,(a1)+
        dbf     d0,.sep

; ----- projection tables into the dataspace (QDOS appends it to the
; code, see ds_base): rowoff[zi] = (horizon + cam_h*yfocal/zi)*128 + 1
; = the red byte of column 0 on the row where ground depth zi lands;
; invtab[zi] = xfocal*4096/zi, so sx = 256 + (xi*invtab[zi]) >> 12.
; Exact per integer depth, so no banding (a zc>>4 table would band the
; near rows), and both divides leave the per-dot path.
        lea     ds_base(pc),a0
        lea     invtab(a0),a1
        move.w  #znear,d2
.tab:   move.w  d2,d1
        add.w   d1,d1               ; word index
        move.l  #cam_h*yfocal,d0
        divu.w  d2,d0
        add.w   #horizon,d0
        lsl.w   #7,d0
        addq.w  #1,d0
        move.w  d0,(a0,d1.w)
        move.l  #xfocal<<12,d0
        divu.w  d2,d0
        move.w  d0,(a1,d1.w)
        addq.w  #1,d2
        cmp.w   #zfar,d2
        blt.s   .tab

        bsr     craft_reset         ; spawn in the open field
        move.b  #1<<pc__frame,pc_intr   ; discard any pending frame bit
        moveq   #1,d7               ; back buffer index: screen 1

; ---------------------------------------------------------------- frame loop
frame_loop:
        lea     scr0,a4             ; a4 = back buffer base
        tst.w   d7
        beq.s   .bb0
        lea     scr1,a4
.bb0:
; ----- erase the dots this buffer held two frames ago (red byte AND)
        bsr     dots_sel            ; a1 = this buffer's dot list
        move.w  (a1)+,d0            ; count
        beq.s   .noer
        subq.w  #1,d0
.er:    move.w  (a1)+,d1            ; offset of the red byte
        move.w  (a1)+,d2            ; inverse mask (low byte)
        and.b   d2,(a4,d1.w)
        dbf     d0,.er
.noer:

; ----- input: the row-1 bits read at the end of the previous loop (the
; IPC read sits between the work and the VBL wait, see there)
        lea     kbd_prev(pc),a2
        move.b  kbd_cur-kbd_prev(a2),d0
        move.b  (a2),d3             ; previous frame's bits (edge detect)
        move.b  d0,(a2)
        move.b  d0,d5               ; d5 = held keys through the sim
        not.b   d3
        and.b   d0,d3               ; d3 = newly pressed
        btst    #k1__enter,d3
        beq.s   .nrst
        bsr     craft_reset         ; Enter: back to the spawn point
.nrst:

; ----- flight: one beat step per beat of the previous loop (1|2), so
; thrust/drag/turn stay defined per 20 ms whatever the frame rate
        move.w  headroom+16(pc),d6
        subq.w  #1,d6
        lea     craft(pc),a0
        lea     sintab(pc),a1
.beat:  bsr     flight_step
        dbf     d6,.beat

        ifeq    no_lat
; ----- lattice: camera-space corner of the cell window and the two
; world step vectors, all 16.16 so the walk below is exact. The window
; is (2*nwin+1)^2 cells around the camera cell; the corner is at
; (-nwin*latd - rx, -nwin*latd - rz) relative to the camera, rx/rz the
; camera's offset within its cell. Camera transform (spec 5.1):
;   xc = dx*c - dz*s,  zc = dz*c + dx*s      (8.8 trig, 256 = 1.0)
        lea     craft(pc),a0
        move.w  c_s(a0),d2          ; s
        move.w  c_c(a0),d3          ; c
        move.l  c_px(a0),d0
        asr.l   #8,d0               ; integer x
        and.w   #latd-1,d0          ; rx
        neg.w   d0
        sub.w   #nwin*latd,d0       ; dx0
        move.l  c_pz(a0),d1
        asr.l   #8,d1
        and.w   #latd-1,d1
        neg.w   d1
        sub.w   #nwin*latd,d1       ; dz0
        move.w  d0,d4
        muls.w  d3,d4               ; dx0*c
        move.w  d1,d5
        muls.w  d2,d5               ; dz0*s
        sub.l   d5,d4
        asl.l   #8,d4               ; xc0, 16.16
        move.l  d4,a2               ; a2 = row start xc
        move.w  d1,d4
        muls.w  d3,d4               ; dz0*c
        move.w  d0,d5
        muls.w  d2,d5               ; dx0*s
        add.l   d5,d4
        asl.l   #8,d4               ; zc0, 16.16
        move.l  d4,a3               ; a3 = row start zc
        move.w  d2,d4
        muls.w  #latd,d4
        asl.l   #8,d4               ; latd*s, 16.16
        move.w  d3,d5
        muls.w  #latd,d5
        asl.l   #8,d5               ; latd*c, 16.16
        lea     lat_uz(pc),a0       ; uz (one world z step) = (-latd*s, latd*c)
        move.l  d4,d0
        neg.l   d0
        move.l  d0,(a0)+
        move.l  d5,(a0)
        move.l  d5,d2               ; ux (one world x step) = (latd*c, latd*s)
        move.l  d4,d3
        bsr     dots_sel            ; a1 = dot list (count word first)
        lea     2+maxdots*4(a1),a0
        lea     lst_max(pc),a6
        move.l  a0,(a6)             ; row-granular overflow check below
        addq.l  #2,a1               ; a1 = first record
        lea     ds_base(pc),a5      ; a5 = rowoff table
        lea     invtab(a5),a6       ; a6 = reciprocal table
; wedge prep: each of the four half-plane tests f = a*x + b*z + c >= 0
; is linear along a row, f(t) = F + t*DF with DF = a*Ux + b*Uz. Since
; Ux = latd*(c, s) and Uz = latd*(-s, c), every DF is latd times a trig
; sum w, which wdg_put expands into the record wbound reads:
;   0 behind   (z - ZN):       w = s
;   1 beyond   (ZF-1 - z):     w = -s
;   2 right    (z - x - 1.0):  w = s - c
;   3 left     (z + x - 1.0):  w = s + c
        lea     wdg(pc),a0
        move.w  craft+c_s(pc),d0
        bsr     wdg_put
        move.w  craft+c_s(pc),d0
        neg.w   d0
        bsr     wdg_put
        move.w  craft+c_s(pc),d0
        sub.w   craft+c_c(pc),d0
        bsr     wdg_put
        move.w  craft+c_s(pc),d0
        add.w   craft+c_c(pc),d0
        bsr     wdg_put
; rows: d7 = rows left (the buffer index is parked on the stack), a2/a3
; = row start (x, z), d2/d3 = Ux. Per row the four tests narrow the
; cell range [d4,d5]; only that range is walked, with the exact
; per-cell tests. Rows behind the camera fall out at the first test.
        move.l  d7,-(sp)
        move.w  #2*nwin+1,d7
.lrow:  moveq   #0,d4               ; lo
        moveq   #2*nwin,d5          ; hi
        lea     wdg(pc),a0
        move.l  a3,d0
        sub.l   #znear<<16,d0       ; f = z - ZN
        wbound  .rnext
        move.l  #(zfar<<16)-1,d0
        sub.l   a3,d0               ; f = ZF-1 - z
        wbound  .rnext
        move.l  a3,d0
        sub.l   a2,d0
        sub.l   #1<<16,d0           ; f = z - x - 1.0
        wbound  .rnext
        move.l  a3,d0
        add.l   a2,d0
        sub.l   #1<<16,d0           ; f = z + x - 1.0
        wbound  .rnext
        cmp.w   d4,d5
        blt.s   .rnext              ; empty range
        move.l  a2,d0               ; walk start = row start + lo*Ux
        move.l  a3,d1
        move.w  d4,d6
        beq.s   .wk
        subq.w  #1,d6
.skp:   add.l   d2,d0
        add.l   d3,d1
        dbf     d6,.skp
.wk:    sub.w   d4,d5
        move.w  d5,d6               ; cells to walk - 1
; cell: exact tests (behind, beyond zfar, outside the 90-degree FOV with
; the 1-unit margin that keeps the floored xi below zi), then the
; table-driven plot of one red pixel (odd byte of the screen word),
; recorded for the erase.
.lcol:  cmp.l   #znear<<16,d1
        blt.s   .lnext
        cmp.l   #zfar<<16,d1
        bge.s   .lnext
        move.l  d0,d4
        bpl.s   .lpos
        neg.l   d4
.lpos:  add.l   #1<<16,d4
        cmp.l   d1,d4
        bgt.s   .lnext
        move.l  d1,d5
        swap    d5                  ; zi (znear..zfar-1)
        add.w   d5,d5               ; word index
        move.w  (a5,d5.w),a0        ; a0 = row*128 + 1
        move.l  d0,d4
        swap    d4                  ; xi (signed, floor)
        muls.w  (a6,d5.w),d4        ; xi * xfocal*4096/zi
        asr.l   #8,d4
        asr.w   #4,d4               ; sx - 256: -256..255 at xfocal 256
        add.w   #256,d4             ; sx
        cmp.w   #511,d4
        bhi.s   .lnext              ; off-screen (narrower FOV than 90)
        move.w  d4,d5
        lsr.w   #3,d5
        add.w   d5,d5               ; (sx>>3)*2: screen word
        add.w   d5,a0               ; a0 = offset of the red byte
        and.w   #7,d4
        move.w  #$80,d5
        lsr.w   d4,d5               ; pixel mask
        or.b    d5,(a4,a0.w)
        move.w  a0,(a1)+            ; record: offset,
        not.b   d5
        move.w  d5,(a1)+            ;   inverse mask
.lnext: add.l   d2,d0               ; next cell: one world x step
        add.l   d3,d1
        dbf     d6,.lcol
.rnext: adda.l  lat_uz(pc),a2       ; next row: one world z step
        adda.l  lat_uz+4(pc),a3
        cmpa.l  lst_max(pc),a1
        bhs.s   .ldone              ; list full: stop (a row of slack)
        subq.w  #1,d7
        bne     .lrow
.ldone: move.l  (sp)+,d7
        move.l  a1,d0               ; store the count for the erase
        bsr     dots_sel
        sub.l   a1,d0
        subq.l  #2,d0
        lsr.l   #2,d0
        move.w  d0,(a1)
        endc

; ----- horizon: full-width white line with a 16-px gap at the centre,
; every frame (nothing moves it)
        lea     horizon*scr_llen(a4),a0
        moveq   #-1,d0
        moveq   #32-1,d1
.hz:    move.l  d0,(a0)+
        dbf     d1,.hz
        clr.l   horizon*scr_llen+62(a4)         ; gap: x 248..263

; ----- reticle: green gunsight around the aim point (256, horizon).
; Every target at hover height projects onto the horizon row whatever
; its distance (yaw-only world), so the sight lives there; the gap in
; the line and the four ticks keep the two apart.
        or.b    #$3c,horizon*scr_llen+62(a4)    ; left tick, x 250..253
        or.b    #$1e,horizon*scr_llen+64(a4)    ; right tick, x 259..262
        moveq   #4-1,d1
        lea     (horizon-6)*scr_llen+64(a4),a0  ; upper tick, 4 rows
        lea     (horizon+3)*scr_llen+64(a4),a1  ; lower tick
.ret:   or.b    #$80,(a0)
        or.b    #$80,(a1)
        lea     scr_llen(a0),a0
        lea     scr_llen(a1),a1
        dbf     d1,.ret

; ----- HUD readouts, headroom bar, meters, then VBL sync + flip. A
; pending frame bit at end-of-work marks a 2-beat loop; consume it,
; wait for the next real edge (flips stay VBL-aligned), consume that
; too so the next loop's test is honest.
        ifeq    no_hud
        bsr     draw_hud
        endc
        bsr     draw_hbar
        bsr     draw_meters
        moveq   #0,d6               ; d6 = 1 if this was a 2-beat loop
        btst    #pc__frame,pc_intr
        beq.s   .onb
        moveq   #1,d6
        move.b  #1<<pc__frame,pc_intr   ; consume the mid-work edge
.onb:
; ----- keyboard: one IPC round trip for row 1, after the work and its
; beat classification, before the wait. At the top of the loop it
; wrecked the meters on Q-emuLator (47% spurious 2-beat loops, min idle
; 1 spin, average work unchanged): the emulated 8049's reply is tied to
; the frame clock, so a read can stall to a tick and drag the frame
; across the beat. Here a stall only eats idle time. On real hardware
; the read costs its ~0.5 ms wherever it sits; input latency is the
; same either way (the next loop uses it). Read on buffer-1 loops
; only, so the buffer-0 spins stay a pure headroom readout and the
; buffer-1 spins show the read's cost.
        ifeq    no_kbd
        tst.w   d7
        beq.s   .nokb
        moveq   #key_row1,d0
        bsr     kbd_row             ; d0.b = key bits, 1 = held
        lea     kbd_cur(pc),a2
        move.b  d0,(a2)
.nokb:
        endc
        move.w  d6,d1
        moveq   #0,d0
.wait:  addq.l  #1,d0               ; count idle spins = headroom
        btst    #pc__frame,pc_intr
        beq.s   .wait
        move.b  #1<<pc__frame,pc_intr   ; consume the terminal edge
        lea     headroom(pc),a2
        move.l  d0,(a2)
        add.l   d0,4(a2)            ; window accumulators: spins,
        add.w   d1,8(a2)            ; 2-beat loops,
        tst.w   d7                  ; spins per back buffer (64 loops
        bne.s   .b1                 ; each in a window),
        add.l   d0,20(a2)
        bra.s   .b2
.b1:    add.l   d0,24(a2)
.b2:    cmp.w   28(a2),d0           ; min and max spins
        bhs.s   .nmin
        move.w  d0,28(a2)
.nmin:  cmp.w   30(a2),d0
        bls.s   .nmax
        move.w  d0,30(a2)
.nmax:  addq.w  #1,d1
        move.w  d1,16(a2)           ; beats for the next sim step
        subq.w  #1,10(a2)           ; loops left in the window
        bne     .flip
        move.w  #mwin,10(a2)
        move.l  4(a2),d0            ; latch: avg spins/loop,
        lsr.l   #mshift,d0
        move.w  d0,12(a2)
        move.w  8(a2),14(a2)        ; 2-beat count of the window,
        move.l  20(a2),d0           ; avg spins on buffer-0 loops,
        lsr.l   #mshift-1,d0
        move.w  d0,32(a2)
        move.l  24(a2),d0           ; on buffer-1 loops,
        lsr.l   #mshift-1,d0
        move.w  d0,34(a2)
        move.w  28(a2),36(a2)       ; min, max
        move.w  30(a2),38(a2)
        move.w  #2,18(a2)           ; draw the meters into both buffers
        clr.l   4(a2)
        clr.w   8(a2)
        clr.l   20(a2)
        clr.l   24(a2)
        move.w  #$7fff,28(a2)
        clr.w   30(a2)
.flip:
        move.w  d7,d0               ; flip: display the buffer just drawn
        ror.b   #1,d0               ; 0 -> $00, 1 -> $80
        move.b  d0,mc_stat
        eori.w  #1,d7               ; other buffer becomes the back one
        bra     frame_loop

; --------------------------------------------------------------- flight step
; One beat of the section-4 model. In: a0 = craft, a1 = sintab, d5.b =
; held keys (row-1 bits). Trashes d0-d4; preserves d5-d7, a0-a6.
flight_step:
; --- turn: ramp while Left xor Right is held, reset on release
        move.w  c_turn(a0),d0
        moveq   #0,d1               ; d1 = -1 left, +1 right, 0 none/chord
        btst    #k1__left,d5
        beq.s   .nl
        subq.w  #1,d1
.nl:    btst    #k1__right,d5
        beq.s   .nr
        addq.w  #1,d1
.nr:    tst.w   d1
        beq.s   .trel
        tst.w   d0
        bne.s   .ramp
        move.w  #turn_min,d0        ; turn just started
        bra.s   .tapp
.ramp:  add.w   #turn_ramp,d0
        cmp.w   #turn_max,d0
        ble.s   .tapp
        move.w  #turn_max,d0
.tapp:  move.w  d0,c_turn(a0)
        tst.w   d1
        bmi.s   .tlft
        add.w   d0,c_head(a0)       ; Right increases the heading
        bra.s   .trig
.tlft:  sub.w   d0,c_head(a0)
        bra.s   .trig
.trel:  clr.w   c_turn(a0)
; --- forward vector (sin, cos) of the heading
.trig:  move.w  c_head(a0),d0
        lsr.w   #8,d0               ; integer brad
        add.w   d0,d0
        move.w  (a1,d0.w),c_s(a0)   ; s
        add.w   #128,d0             ; cos = sin(a + 64)
        and.w   #511,d0
        move.w  (a1,d0.w),c_c(a0)   ; c
; --- Up = thrust, Down = brake, then (after rev_delay beats at rest)
; reverse thrust. d4 = thrust direction: +1 forward, -1 reverse, 0 none
        moveq   #0,d4
        btst    #k1__up,d5
        beq.s   .nup
        moveq   #1,d4
.nup:   btst    #k1__down,d5
        bne.s   .down
        clr.w   c_stop(a0)          ; Down released: clear the sequence
        clr.w   c_rev(a0)
        bra.s   .thr
.down:  tst.w   c_rev(a0)
        beq.s   .brake
        moveq   #-1,d4              ; reversing: thrust along -forward
        bra.s   .thr
.brake: move.w  c_vx(a0),d0         ; strong drag
        move.w  d0,d1
        asr.w   #brake_shift,d1
        sub.w   d1,d0
        move.w  d0,c_vx(a0)
        move.w  c_vz(a0),d1
        move.w  d1,d2
        asr.w   #brake_shift,d2
        sub.w   d2,d1
        move.w  d1,c_vz(a0)
        tst.w   d0                  ; at rest = both |components| < v_rest
        bpl.s   .ax
        neg.w   d0
.ax:    tst.w   d1
        bpl.s   .az
        neg.w   d1
.az:    cmp.w   #v_rest,d0
        bge.s   .mov
        cmp.w   #v_rest,d1
        bge.s   .mov
        addq.w  #1,c_stop(a0)
        cmp.w   #rev_delay,c_stop(a0)
        blt.s   .thr
        move.w  #1,c_rev(a0)        ; full stop held long enough
        bra.s   .thr
.mov:   clr.w   c_stop(a0)
.thr:   tst.w   d4
        beq.s   .nthr
        move.w  c_s(a0),d0
        muls.w  #thrust,d0
        asr.l   #8,d0               ; thrust*s, 8.8
        move.w  c_c(a0),d1
        muls.w  #thrust,d1
        asr.l   #8,d1               ; thrust*c
        tst.w   d4
        bmi.s   .rthr
        add.w   d0,c_vx(a0)
        add.w   d1,c_vz(a0)
        bra.s   .nthr
.rthr:  sub.w   d0,c_vx(a0)
        sub.w   d1,c_vz(a0)
.nthr:
; --- drag: v -= v >> drag_shift (velocity lags heading = drift)
        move.w  c_vx(a0),d0
        move.w  d0,d1
        asr.w   #drag_shift,d1
        sub.w   d1,d0
        move.w  d0,c_vx(a0)
        move.w  c_vz(a0),d1
        move.w  d1,d2
        asr.w   #drag_shift,d2
        sub.w   d2,d1
        move.w  d1,c_vz(a0)
; --- soft speed cap: over the cap, cut 1/8 per beat (no sqrt; thrust
; overshoots by at most 1.5 units/beat)
        move.w  d0,d2
        muls.w  d2,d2
        move.w  d1,d3
        muls.w  d3,d3
        add.l   d3,d2               ; |v|^2, 16.16
        move.l  #(vmax*256)*(vmax*256),d3
        tst.w   c_rev(a0)
        beq.s   .capf
        move.l  #(rev_max*256)*(rev_max*256),d3
.capf:  cmp.l   d3,d2
        ble.s   .ncap
        move.w  d0,d2
        asr.w   #3,d2
        sub.w   d2,d0
        move.w  d0,c_vx(a0)
        move.w  d1,d2
        asr.w   #3,d2
        sub.w   d2,d1
        move.w  d1,c_vz(a0)
.ncap:
; --- position
        ext.l   d0
        add.l   d0,c_px(a0)
        ext.l   d1
        add.l   d1,c_pz(a0)
        rts

; -------------------------------------------------------------- craft reset
; Spawn between four lattice points, looking along +z, at rest.
; Preserves everything but a0.
craft_reset:
        lea     craft(pc),a0
        move.l  #(latd/2)<<8,c_px(a0)
        move.l  #(latd/2)<<8,c_pz(a0)
        clr.w   c_head(a0)
        clr.w   c_turn(a0)
        clr.w   c_vx(a0)
        clr.w   c_vz(a0)
        clr.w   c_stop(a0)
        clr.w   c_rev(a0)
        rts

; ---------------------------------------------------------- dot list select
; a1 = the dot list of back buffer d7 (count word, then maxdots records
; of offset.w, inverse-mask.w). Preserves everything else.
dots_sel:
        lea     dots0(pc),a1
        tst.w   d7
        beq.s   .d0
        lea     dots1(pc),a1
.d0:    rts

; ------------------------------------------------------------- wedge record
; d0.w = w (trig sum, 8.8), a0 -> 12-byte record: DF = w*latd (16.16),
; (2*nwin)*DF, DF>>16. Trashes d0, d1, d4; advances a0.
wdg_put:
        move.w  d0,d1
        muls.w  #latd,d1            ; w*latd: units per cell, 8.8
        move.l  d1,d4
        asl.l   #8,d4
        move.l  d4,(a0)+            ; DF, 16.16
        muls.w  #2*nwin*latd,d0
        asl.l   #8,d0
        move.l  d0,(a0)+            ; (2*nwin)*DF: change over a row
        asr.l   #8,d1
        move.w  d1,(a0)+            ; DF>>16 (floor)
        addq.l  #2,a0               ; pad
        rts

; ---------------------------------------------------------------- HUD readouts
; Three decimal fields on rows 242-246 (lib/draw_dec.asm, self-erasing):
;   green byte 0:  forward speed, tenths of a unit/beat (24.0 -> 240)
;   green byte 8:  drift = sideways speed, tenths (the drag_shift feel)
;   green byte 16: heading, integer brads 0..255
; The speeds are magnitudes: in reverse the dots flow the other way.
; Refreshed every 4th frame (drawn twice, once per buffer): five
; draw_dec calls a frame cost ~4 ms, a third of the original budget.
draw_hud:
        lea     hud_tick(pc),a2
        move.w  (a2),d0
        addq.w  #1,d0
        and.w   #3,d0
        move.w  d0,(a2)
        cmp.w   #2,d0
        bcc.s   .skip
        lea     craft(pc),a2
        move.w  c_vx(a2),d0
        muls.w  c_s(a2),d0
        move.w  c_vz(a2),d1
        muls.w  c_c(a2),d1
        add.l   d1,d0               ; v . forward, 16.16
        bsr.s   .tenths
        move.w  d0,d5
        move.w  c_vx(a2),d0
        muls.w  c_c(a2),d0
        move.w  c_vz(a2),d1
        muls.w  c_s(a2),d1
        sub.l   d1,d0               ; v . right, 16.16
        bsr.s   .tenths
        move.w  d0,d6
        move.w  d5,d0
        lea     242*scr_llen(a4),a0
        bsr     draw_dec
        move.w  d6,d0
        lea     242*scr_llen+8(a4),a0
        bsr     draw_dec
        move.w  craft+c_head(pc),d0
        lsr.w   #8,d0
        lea     242*scr_llen+16(a4),a0
        bra     draw_dec            ; tail call
.skip:  rts
.tenths:                            ; d0.l 16.16 -> |d0| in tenths (word)
        asr.l   #8,d0               ; 8.8, |v| <= 12288
        bpl.s   .tp
        neg.l   d0
.tp:    muls.w  #10,d0
        asr.l   #8,d0
        rts

; ------------------------------------------------------------------- meters
; Six decimal readouts latched from the mwin-loop window, at green
; bytes 48, 56, 64 (x 192, 224, 256):
;   rows 242-246: avg idle spins per loop (1 spin ~ 20 us) | avg spins
;                 on buffer-0 loops | min spins in the window
;   rows 248-252: 2-beat loops out of mwin (0 = pure 50 Hz) | avg spins
;                 on buffer-1 loops | max spins in the window
; Blank until the first full window has latched; then drawn only in
; the two frames after each latch (one per buffer), since the values
; change only then.
draw_meters:
        lea     headroom(pc),a1
        tst.w   18(a1)              ; frames left to draw after a latch
        beq.s   .none
        subq.w  #1,18(a1)
        move.w  12(a1),d0
        lea     242*scr_llen+48(a4),a0
        bsr     draw_dec
        move.w  headroom+32(pc),d0
        lea     242*scr_llen+56(a4),a0
        bsr     draw_dec
        move.w  headroom+36(pc),d0
        lea     242*scr_llen+64(a4),a0
        bsr     draw_dec
        move.w  headroom+14(pc),d0
        lea     248*scr_llen+48(a4),a0
        bsr     draw_dec
        move.w  headroom+34(pc),d0
        lea     248*scr_llen+56(a4),a0
        bsr     draw_dec
        move.w  headroom+38(pc),d0
        lea     248*scr_llen+64(a4),a0
        bra     draw_dec            ; tail call: its rts returns
.none:  rts

; -------------------------------------------------------------- headroom bar
; 64 groups of 8 px, lit = green byte $ff; the unlit remainder is
; written black, so the bar self-erases. Long writes: two groups each.
draw_hbar:
        lea     headroom(pc),a1
        move.l  (a1),d0
        lsr.l   #hb_shift,d0
        cmp.w   #64,d0
        bls.s   .clip
        moveq   #64,d0
.clip:  lea     hb_y*scr_llen(a4),a0
        move.l  #$ff00ff00,d4       ; two lit groups (green bytes)
        moveq   #2-1,d3
.row:   move.w  d0,d1
        lsr.w   #1,d1               ; lit longs
        moveq   #32,d2
        sub.w   d1,d2               ; the rest (dark, or one half-lit)
        bra.s   .lt
.lit:   move.l  d4,(a0)+
.lt:    dbf     d1,.lit
        btst    #0,d0               ; odd count: one half-lit long
        beq.s   .dt
        move.w  #$ff00,(a0)+
        clr.w   (a0)+
        subq.w  #1,d2
        bra.s   .dt
.drk:   clr.l   (a0)+
.dt:    dbf     d2,.drk
        dbf     d3,.row             ; 128 bytes written = next line
        rts

; ---------------------------------------------------------------------- data
        even
craft:  ds.b    c_size              ; see the c_* offsets (craft_reset inits)
kbd_prev:
        dc.b    0                   ; row-1 bits the last sim step used
kbd_cur:
        dc.b    0                   ; row-1 bits from the latest IPC read
        even
lat_uz: dc.l    0,0                 ; world z step in camera space, 16.16
wdg:    ds.b    4*12                ; wedge test records (wdg_put)
lst_max:
        dc.l    0                   ; this buffer's dot list limit
hud_tick:
        dc.w    0                   ; readout refresh phase

headroom:
        dc.l    0                   ; idle spins in last loop's VBL wait
        dc.l    0                   ; +4  window: spins accumulator
        dc.w    0                   ; +8  window: 2-beat loop count
        dc.w    mwin                ; +10 loops left in the window
        dc.w    0                   ; +12 latched avg spins (meter A)
        dc.w    0                   ; +14 latched 2-beat count (meter B)
        dc.w    1                   ; +16 beats of the last loop (1|2)
        dc.w    0                   ; +18 frames left to draw the meters
        dc.l    0                   ; +20 window: spins on buffer-0 loops
        dc.l    0                   ; +24 window: spins on buffer-1 loops
        dc.w    $7fff               ; +28 window: min spins
        dc.w    0                   ; +30 window: max spins
        dc.w    0,0,0,0             ; +32 latched avg0, avg1, min, max

; per-buffer dot lists: count, then (red byte offset, inverse mask);
; the scan checks the limit per row, so a row of slack follows
dots0:  dc.w    0
        ds.w    (maxdots+2*nwin+1)*2
dots1:  dc.w    0
        ds.w    (maxdots+2*nwin+1)*2

        include "sin.inc"

        even
sv_stack:
        ds.b    64                  ; private supervisor stack
sv_stack_top:

        include "../lib/ipc_sound_takeover.asm"
        include "../lib/ipc_keys_takeover.asm"
        include "../lib/draw_line_w.asm"
        include "../lib/draw_line.asm"
        include "../lib/draw_dec.asm"

; ---------------------------------------------------------------- dataspace
; QDOS places the job's dataspace right after the code, so ds_base (the
; end of this file) addresses it: the projection tables live there,
; built at startup, and the file stays small. DATASPACE in the Makefile
; (passed in as ds_avail) must cover ds_size.
rowoff      equ     0               ; word[zfar]: row*128+1 per depth
invtab      equ     zfar*2          ; word[zfar]: xfocal*4096/depth
ds_size     equ     zfar*4
        if      ds_size>ds_avail
        fail    "DATASPACE in the Makefile is smaller than ds_size"
        endc
        even
ds_base:
