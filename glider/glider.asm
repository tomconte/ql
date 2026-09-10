; glider.asm -- the hovercraft raid, M2 world (docs/engine-spec.md)
;
; First-person, yaw-only camera at a fixed height over a flat world:
; an IPC keyboard read on alternate frames (row 1: arrows + Enter), the
; section-4 flight model (ramped turn, thrust, drag = drift, brake then
; reverse), a world-aligned lattice of red ground dots, the fixed
; horizon, a reticle and HUD readouts (M1, the flight rig), and now
; wireframe objects on the lattice (M2): a static entity table (towers,
; blocks, mines from meshes.inc), the camera transform, four-level
; culling (world box, bounding sphere against the frustum, faces by
; their planes with the eye in the mesh's frame, edges by outcodes),
; near-plane and 2D clipping for the edges the line drawers cannot
; take, and one erase box per drawn object. The flight constants (the
; equ block below) were tuned by feel in M1.
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
hz_line     equ     0               ; 1 = draw the horizon line, 0 = none
                                    ; (Starglider 1 look, 2026-09-10: the
                                    ; reticle alone marks the aim row)
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

; ----- objects (spec sections 5.1, 5.2, 6). The near plane for meshes
; is closer than the lattice's: their edges are clipped, the dots are
; not. r_active bounds every camera-space coordinate to a word (the
; frustum and the eye-in-mesh-frame products need that). Meshes,
; planes and the directory come from meshes.inc (genmesh --game).
znear_o     equ     32              ; object near plane (z' <= it: clipped)
r_active    equ     2560            ; world box half-side: zfar + radius + slack
maxobj      equ     16              ; erase boxes per buffer = objects drawn
nent        equ     64              ; entity pool

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
no_obj      equ     0               ; skip the objects (box erase still runs)

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

; entity record (entpool, 16 bytes; the level table has the same shape)
e_mesh      equ     0               ; word, directory index; -1 ends the pool
e_flags     equ     2               ; word, 0 = inactive
e_x         equ     4               ; word, world x (integer units)
e_z         equ     6               ; word, world z
e_y         equ     8               ; word, centre height over the ground
e_head      equ     10              ; word, 8.8 brads
e_hp        equ     12              ; reserved (M3)
e_tmr       equ     14              ; reserved (M3)
e_size      equ     16

; mesh directory entry (objdir in meshes.inc, 32 bytes)
od_nv       equ     0               ; nvtx-1
od_nf       equ     2               ; nfaces-1
od_ne       equ     4               ; nedges-1
od_col      equ     6               ; draw_line colour
od_v        equ     8               ; table offsets from meshes
od_f        equ     10
od_e        equ     12
od_n        equ     14              ; face planes
od_yb       equ     16              ; ybase
od_rad      equ     18              ; bounding radius
od_crad     equ     20              ; collision radius (M3)

; camera block for the object stage (ocam)
oc_px       equ     0               ; long, camera x, integer units
oc_pz       equ     4               ; long
oc_s        equ     8               ; word, sin head
oc_c        equ     10              ; word, cos head
oc_n        equ     12              ; word, objects drawn this frame

; current object (cur)
cu_v        equ     0               ; long, vertex table
cu_e        equ     4               ; long, edge table
cu_n        equ     8               ; long, plane table
cu_nv       equ     12              ; nvtx-1
cu_nf       equ     14              ; nfaces-1
cu_ne       equ     16              ; nedges-1
cu_col      equ     18              ; colour
cu_xc       equ     20              ; centre in camera space
cu_zc       equ     22
cu_yc       equ     24
cu_sa       equ     26              ; sin, cos of (object - camera) heading
cu_ca       equ     28
cu_vis      equ     30              ; face visibility mask
cu_oc       equ     32              ; OR of the vertex outcodes
cu_cnt      equ     34              ; loop counter
cu_minx     equ     36              ; erase box accumulators
cu_maxx     equ     38
cu_miny     equ     40
cu_maxy     equ     42
cu_size     equ     44

; vertex scratch record (vscr, 12 bytes; edge tables index by i*12)
vs_x        equ     0               ; camera space x', y', z'
vs_y        equ     2
vs_z        equ     4
vs_sx       equ     6               ; projected
vs_sy       equ     8
vs_oc       equ     10              ; outcode: 1 left, 2 right, 4 above,
                                    ; 8 below, $10 behind the near plane
; clip work area (cwrk): two vs records, A then B
cw_x        equ     vs_x
cw_y        equ     vs_y
cw_z        equ     vs_z
cw_sx       equ     vs_sx
cw_sy       equ     vs_sy
cw_oc       equ     vs_oc
cw_size     equ     12

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

; beat_poll: consume a frame edge that fired since the last poll and
; count it in xbeats. The frame bit cannot count two edges, so the work
; is polled at stage boundaries (after the lattice, after each drawn
; object; every stage is under a beat) and the loop's beats = 1 + the
; edges consumed. Register-transparent.
beat_poll macro
        btst    #pc__frame,pc_intr
        beq.s   .bp\@
        move.b  #1<<pc__frame,pc_intr
        move.l  a0,-(sp)
        lea     xbeats(pc),a0
        addq.w  #1,(a0)
        move.l  (sp)+,a0
.bp\@:
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

        lea     level(pc),a0        ; static entities into the pool
        lea     entpool(pc),a1
.lvl:   move.w  (a0),d0
        move.l  (a0)+,(a1)+
        move.l  (a0)+,(a1)+
        move.l  (a0)+,(a1)+
        move.l  (a0)+,(a1)+
        tst.w   d0
        bpl.s   .lvl                ; copies the -1 terminator too

        bsr     craft_reset         ; spawn in the open field
        move.b  #1<<pc__frame,pc_intr   ; discard any pending frame bit
        moveq   #1,d7               ; back buffer index: screen 1

; ---------------------------------------------------------------- frame loop
frame_loop:
        lea     scr0,a4             ; a4 = back buffer base
        tst.w   d7
        beq.s   .bb0
        lea     scr1,a4
.bb0:   lea     xbeats(pc),a0
        clr.w   (a0)                ; frame edges consumed during the work

; ----- erase the object boxes this buffer held two frames ago (parade
; format: miny, nrows, end-of-span offset, L longs per row). Per row
; eight zeroed registers go out in movem bursts of 32 bytes: the full
; bursts via a computed jump, the remainder through a mask patched per
; box (emtab); L reaches 32 for a screen-wide object.
        bsr     bbox_sel            ; a6 = this buffer's box list
        move.w  (a6)+,d0
        beq.s   .noeb
        lsl.w   #3,d0
        lea     (a6,d0.w),a0
        move.l  a0,-(sp)            ; end of the records
.ebox:  move.w  (a6)+,d1            ; miny
        move.w  (a6)+,d2            ; nrows
        move.w  (a6)+,d3            ; end-of-span offset
        move.w  (a6)+,d4            ; L
        lsl.w   #7,d1
        add.w   d3,d1
        lea     (a4,d1.w),a0        ; end of the first row's span
        move.w  d4,d5
        lsr.w   #3,d5               ; full bursts
        neg.w   d5
        addq.w  #4,d5
        lsl.w   #2,d5               ; jump offset: skip 4 - full bursts
        move.w  d4,d0
        and.w   #7,d0
        add.w   d0,d0
        lea     emtab(pc),a1
        move.w  (a1,d0.w),d0        ; remainder mask
        lea     .erm+2(pc),a1
        move.w  d0,(a1)
        lsl.w   #2,d4
        add.w   #scr_llen,d4        ; row stride = 128 + 4L
        moveq   #0,d0               ; eight zeros for the bursts
        moveq   #0,d1
        moveq   #0,d3
        moveq   #0,d6
        suba.l  a1,a1
        suba.l  a2,a2
        suba.l  a3,a3
        suba.l  a5,a5
.erow:  jmp     .ej(pc,d5.w)
.ej:    movem.l d0-d1/d3/d6/a1-a3/a5,-(a0)
        movem.l d0-d1/d3/d6/a1-a3/a5,-(a0)
        movem.l d0-d1/d3/d6/a1-a3/a5,-(a0)
        movem.l d0-d1/d3/d6/a1-a3/a5,-(a0)
.erm:   movem.l d0-d1/d3/d6/a1-a3/a5,-(a0)   ; mask patched above
        adda.w  d4,a0
        subq.w  #1,d2
        bne.s   .erow
        cmpa.l  (sp),a6
        blo.s   .ebox
        addq.l  #4,sp
.noeb:

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
        beat_poll

; ----- horizon (hz_line): full-width red line with a 16-px gap at the
; centre, every frame (nothing moves it, but erase boxes cut it). Red
; like the lattice since M2: a white line through the red mine sitting
; on it (hover height) read badly; off by default since the same day.
        ifne    hz_line
        lea     horizon*scr_llen(a4),a0
        move.l  #$00ff00ff,d0       ; red plane = the odd bytes
        moveq   #32-1,d1
.hz:    move.l  d0,(a0)+
        dbf     d1,.hz
        clr.l   horizon*scr_llen+62(a4)         ; gap: x 248..263
        endc

; ----- objects: every active entity through the four-level cull (world
; box, bounding sphere against the frustum, faces by their planes with
; the eye in the mesh's frame, edges by outcodes), then its vertices
; into camera space and on screen, and its edges drawn: straight to
; draw_line when every vertex is on screen, else through clip_edge.
; Across the stage a4 = back buffer, a5 = entity, d7 = buffer index;
; draw_line trashes a0/a1, so a1 (cur) is reloaded after every line.
        ifeq    no_obj
        lea     craft(pc),a0
        lea     ocam(pc),a1
        move.l  c_px(a0),d0
        asr.l   #8,d0
        move.l  d0,oc_px(a1)        ; camera position, integer units
        move.l  c_pz(a0),d0
        asr.l   #8,d0
        move.l  d0,oc_pz(a1)
        move.w  c_s(a0),oc_s(a1)
        move.w  c_c(a0),oc_c(a1)
        clr.w   oc_n(a1)
        bsr     bbox_sel
        clr.w   (a6)                ; this buffer's box list starts empty
        lea     entpool(pc),a5
.ent:   tst.w   e_mesh(a5)
        bmi     .edone              ; end of the pool
        tst.w   e_flags(a5)
        beq     .enext              ; inactive
; --- world box: |dx|, |dz| < r_active, as longs (the lattice is unbounded)
        move.w  e_x(a5),d0
        ext.l   d0
        sub.l   ocam+oc_px(pc),d0   ; dx
        move.l  d0,d1
        bpl.s   .bx
        neg.l   d1
.bx:    cmp.l   #r_active,d1
        bge     .enext
        move.w  e_z(a5),d2
        ext.l   d2
        sub.l   ocam+oc_pz(pc),d2   ; dz
        move.l  d2,d1
        bpl.s   .bz
        neg.l   d1
.bz:    cmp.l   #r_active,d1
        bge     .enext
; --- centre into camera space (spec 5.1):
;   xc = (dx*c - dz*s) >> 8,  zc = (dz*c + dx*s) >> 8,  yc = cam_h - e_y
        move.w  ocam+oc_s(pc),d3
        move.w  ocam+oc_c(pc),d4
        move.w  d0,d1
        muls.w  d4,d1               ; dx*c
        move.w  d2,d5
        muls.w  d3,d5               ; dz*s
        sub.l   d5,d1
        asr.l   #8,d1               ; xc
        muls.w  d4,d2               ; dz*c
        muls.w  d3,d0               ; dx*s
        add.l   d0,d2
        asr.l   #8,d2               ; zc
        move.w  #cam_h,d3
        sub.w   e_y(a5),d3          ; yc (y down: the eye is above the ground)
; --- frustum on the bounding sphere. Conservative forms (never reject
; a sphere touching the view volume, checked in the M2 model): the side
; planes at 1.5r (> r*sqrt2 for 45-degree planes), the top and bottom
; planes at 2r against the 0.47/0.935 slopes of the shifted viewport.
        move.w  e_mesh(a5),d0
        lsl.w   #5,d0
        lea     objdir(pc),a0
        adda.w  d0,a0               ; a0 = directory entry
        move.w  od_rad(a0),d4       ; r
        move.w  d2,d0
        add.w   d4,d0
        cmp.w   #znear_o,d0
        blt     .enext              ; wholly behind the near plane
        move.w  d1,d0
        bpl.s   .fx
        neg.w   d0
.fx:    sub.w   d2,d0               ; |xc| - zc
        move.w  d4,d5
        asr.w   #1,d5
        add.w   d4,d5               ; 1.5 r
        cmp.w   d5,d0
        bgt     .enext              ; wholly outside the 90-degree FOV
        move.w  d4,d5
        add.w   d5,d5               ; 2r
        move.w  d3,d0
        sub.w   d2,d0               ; yc - zc
        cmp.w   d5,d0
        bgt     .enext              ; wholly below the play area
        move.w  d2,d0
        asr.w   #1,d0
        add.w   d3,d0
        add.w   d5,d0               ; yc + zc/2 + 2r
        bmi     .enext              ; wholly above it
        bsr     bbox_sel
        cmp.w   #maxobj,(a6)
        bge     .enext              ; no erase box left: not drawn
; --- cache the object: tables, counts, colour, centre, and the angle
; a = object heading - camera heading (the yaw the mesh is drawn at)
        lea     cur(pc),a1
        move.w  d1,cu_xc(a1)
        move.w  d2,cu_zc(a1)
        move.w  d3,cu_yc(a1)
        move.w  od_nv(a0),cu_nv(a1)
        move.w  od_nf(a0),cu_nf(a1)
        move.w  od_ne(a0),cu_ne(a1)
        move.w  od_col(a0),cu_col(a1)
        lea     meshes(pc),a2
        move.l  a2,d0
        moveq   #0,d5
        move.w  od_v(a0),d5
        add.l   d0,d5
        move.l  d5,cu_v(a1)
        moveq   #0,d5
        move.w  od_e(a0),d5
        add.l   d0,d5
        move.l  d5,cu_e(a1)
        moveq   #0,d5
        move.w  od_n(a0),d5
        add.l   d0,d5
        move.l  d5,cu_n(a1)
        move.w  e_head(a5),d0
        sub.w   craft+c_head(pc),d0
        lsr.w   #8,d0               ; integer brad
        add.w   d0,d0
        lea     sintab(pc),a2
        move.w  (a2,d0.w),d5        ; sa
        move.w  d5,cu_sa(a1)
        add.w   #128,d0             ; cos = sin(a + 64)
        and.w   #511,d0
        move.w  (a2,d0.w),d6        ; ca
        move.w  d6,cu_ca(a1)
        clr.w   cu_oc(a1)
        move.w  #511,cu_minx(a1)    ; empty box: minx > maxx
        clr.w   cu_maxx(a1)
        move.w  #playbot,cu_miny(a1)
        clr.w   cu_maxy(a1)
; --- the eye in the mesh's frame: the inverse of the vertex transform
; below applied to the camera origin,
;   ex = (zc*sa - xc*ca) >> 8,  ez = -((zc*ca + xc*sa) >> 8),  ey = -yc
        move.w  d2,d0
        muls.w  d5,d0               ; zc*sa
        move.w  d1,d4
        muls.w  d6,d4               ; xc*ca
        sub.l   d4,d0
        asr.l   #8,d0               ; ex
        move.w  d2,d4
        muls.w  d6,d4               ; zc*ca
        muls.w  d5,d1               ; xc*sa
        add.l   d1,d4
        asr.l   #8,d4
        neg.w   d4                  ; ez
        neg.w   d3                  ; ey
; --- faces: bit f of the visibility mask when the eye is on the outer
; side of face f's plane, n.e > d. Records are last-face-first, so the
; dbf counter is the bit number (as in the parade's cross test).
        move.l  cu_n(a1),a0
        move.w  cu_nf(a1),d6
        moveq   #0,d5
.face:  move.w  (a0)+,d1
        muls.w  d0,d1               ; nx*ex
        move.w  (a0)+,d2
        muls.w  d3,d2               ; ny*ey
        add.l   d2,d1
        move.w  (a0)+,d2
        muls.w  d4,d2               ; nz*ez
        add.l   d2,d1
        cmp.l   (a0)+,d1            ; against d
        ble.s   .hid
        bset    d6,d5
.hid:   dbf     d6,.face
        move.w  d5,cu_vis(a1)
; --- vertices into camera space (the parade's yaw formula plus the
; centre), projected with outcodes into vscr; a vertex at or behind
; the near plane gets outcode $10 and no projection
;   x' = (x*ca + z*sa) >> 8 + xc,  z' = (z*ca - x*sa) >> 8 + zc,  y' = y + yc
        move.l  cu_v(a1),a0
        lea     vscr(pc),a2
        move.w  cu_nv(a1),d6
        move.w  cu_sa(a1),d4
        move.w  cu_ca(a1),d5
.vtx:   move.w  (a0)+,d0            ; x
        move.w  (a0)+,d1            ; y
        move.w  (a0)+,d2            ; z
        move.w  d0,d3
        muls.w  d5,d3               ; x*ca
        muls.w  d4,d0               ; x*sa
        move.w  d2,a3               ; park z
        muls.w  d4,d2               ; z*sa
        add.l   d2,d3
        asr.l   #8,d3
        add.w   cu_xc(a1),d3        ; x'
        move.w  a3,d2
        muls.w  d5,d2               ; z*ca
        sub.l   d0,d2
        asr.l   #8,d2
        add.w   cu_zc(a1),d2        ; z'
        add.w   cu_yc(a1),d1        ; y'
        move.w  d3,(a2)+
        move.w  d1,(a2)+
        move.w  d2,(a2)+
        cmp.w   #znear_o+1,d2
        blt.s   .vnear
        move.w  d3,d0
        bsr     proj_oc             ; d0 = sx, d1 = sy, d3 = outcode
        move.w  d0,(a2)+
        move.w  d1,(a2)+
        move.w  d3,(a2)+
        or.w    d3,cu_oc(a1)
        dbf     d6,.vtx
        bra.s   .vdone
.vnear: addq.l  #4,a2               ; no projection
        move.w  #$10,(a2)+
        or.w    #$10,cu_oc(a1)
        dbf     d6,.vtx
.vdone:
; --- edges whose two faces are not both hidden. a6 parks the
; visibility mask (draw_line leaves a2, a3, a5, a6, d6, d7 alone).
        move.l  cu_e(a1),a2
        lea     vscr(pc),a3
        move.w  cu_vis(a1),a6
        move.w  cu_ne(a1),cu_cnt(a1)
        tst.w   cu_oc(a1)
        bne.s   .cedge              ; some vertex off screen: clip path
.edge:  move.w  a6,d0
        and.w   2(a2),d0            ; edge's two-face mask vs visibility
        beq.s   .eskip
        moveq   #0,d0
        move.b  (a2),d0             ; vertex offsets (pre-multiplied by 12)
        moveq   #0,d2
        move.b  1(a2),d2
        move.w  vs_sy(a3,d0.w),d1
        move.w  vs_sx(a3,d0.w),d0
        move.w  vs_sy(a3,d2.w),d3
        move.w  vs_sx(a3,d2.w),d2
        bsr     bb_ext
        move.w  cu_col(a1),d4
        bsr     draw_line
        lea     cur(pc),a1
.eskip: addq.l  #4,a2
        subq.w  #1,cu_cnt(a1)
        bge.s   .edge
        bra     .box
.cedge: move.w  a6,d0
        and.w   2(a2),d0
        beq     .cskip
        moveq   #0,d0
        move.b  (a2),d0
        moveq   #0,d2
        move.b  1(a2),d2
        move.w  vs_oc(a3,d0.w),d4
        move.w  vs_oc(a3,d2.w),d5
        move.w  d4,d1
        or.w    d5,d1
        beq.s   .cin                ; both on screen: straight draw
        and.w   d5,d4
        bne     .cskip              ; both past one edge, or both behind
        lea     cwrk(pc),a0         ; copy both records for clip_edge
        lea     (a3,d0.w),a1
        move.l  (a1)+,(a0)+
        move.l  (a1)+,(a0)+
        move.l  (a1)+,(a0)+
        lea     (a3,d2.w),a1
        move.l  (a1)+,(a0)+
        move.l  (a1)+,(a0)+
        move.l  (a1)+,(a0)+
        bsr     clip_edge           ; d0-d3 = segment, d4 = 0 if none
        lea     cur(pc),a1
        tst.w   d4
        beq.s   .cskip
        bra.s   .cdrw
.cin:   move.w  vs_sy(a3,d0.w),d1
        move.w  vs_sx(a3,d0.w),d0
        move.w  vs_sy(a3,d2.w),d3
        move.w  vs_sx(a3,d2.w),d2
.cdrw:  bsr     bb_ext
        move.w  cu_col(a1),d4
        bsr     draw_line
        lea     cur(pc),a1
.cskip: addq.l  #4,a2
        subq.w  #1,cu_cnt(a1)
        bge     .cedge
; --- the erase box for this buffer's next pass (parade format) when
; anything was drawn; count the object; poll the frame edge
.box:   move.w  cu_minx(a1),d0
        move.w  cu_maxx(a1),d1
        cmp.w   d1,d0
        bgt     .enext              ; nothing drawn
        move.w  cu_miny(a1),d2
        move.w  cu_maxy(a1),d3
        bsr     bbox_sel            ; a6 = box list
        move.w  (a6),d4
        addq.w  #1,(a6)
        lsl.w   #3,d4
        lea     2(a6,d4.w),a0       ; the new record
        move.w  d2,(a0)+            ; miny
        sub.w   d2,d3
        addq.w  #1,d3
        move.w  d3,(a0)+            ; nrows
        lsr.w   #5,d0               ; 32-px (8-byte) units
        lsr.w   #5,d1
        sub.w   d0,d1               ; units spanned - 1
        lsl.w   #3,d0               ; byte offset of the first unit
        add.w   d1,d1
        addq.w  #2,d1               ; L = 2 longs per unit, <= 32
        move.w  d1,d4
        lsl.w   #2,d4               ; 4L bytes per row
        add.w   d4,d0
        move.w  d0,(a0)+            ; end-of-span offset
        move.w  d1,(a0)             ; L
        lea     ocam(pc),a0
        addq.w  #1,oc_n(a0)
        beat_poll
.enext: lea     e_size(a5),a5
        bra     .ent
.edone:
        endc

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

; ----- HUD readouts, headroom bar, meters, then VBL sync + flip. The
; frame edges consumed during the work (beat_poll at the stage
; boundaries, plus one last poll here) are the loop's extra beats;
; then wait for the next real edge (flips stay VBL-aligned) and consume
; that too so the next loop's count is honest.
        ifeq    no_hud
        bsr     draw_hud
        endc
        bsr     draw_hbar
        bsr     draw_meters
        beat_poll
        move.w  xbeats(pc),d6       ; d6 = extra beats of this loop (0..2)
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

; ---------------------------------------------------------- box list select
; a6 = the erase-box list of back buffer d7 (count word, then maxobj
; records of miny, nrows, end-of-span offset, L). Preserves the rest.
bbox_sel:
        lea     bbox0(pc),a6
        tst.w   d7
        beq.s   .b0
        lea     bbox1(pc),a6
.b0:    rts

; --------------------------------------------------------------- box extend
; Grow the current object's erase box (cur, a1) by the on-screen
; segment d0,d1 - d2,d3. Preserves every register.
bb_ext:
        cmp.w   cu_minx(a1),d0
        bge.s   .x1
        move.w  d0,cu_minx(a1)
.x1:    cmp.w   cu_maxx(a1),d0
        ble.s   .x2
        move.w  d0,cu_maxx(a1)
.x2:    cmp.w   cu_minx(a1),d2
        bge.s   .x3
        move.w  d2,cu_minx(a1)
.x3:    cmp.w   cu_maxx(a1),d2
        ble.s   .y0
        move.w  d2,cu_maxx(a1)
.y0:    cmp.w   cu_miny(a1),d1
        bge.s   .y1
        move.w  d1,cu_miny(a1)
.y1:    cmp.w   cu_maxy(a1),d1
        ble.s   .y2
        move.w  d1,cu_maxy(a1)
.y2:    cmp.w   cu_miny(a1),d3
        bge.s   .y3
        move.w  d3,cu_miny(a1)
.y3:    cmp.w   cu_maxy(a1),d3
        ble.s   .y4
        move.w  d3,cu_maxy(a1)
.y4:    rts

; ------------------------------------------------------ project + outcode
; proj_oc: d0 = x', d1 = y', d2 = z' (> 0) -> d0 = sx, d1 = sy, d3 =
; outcode (spec 5.1: sx = 256 + x'*256/z', sy = horizon + y'*yfocal/z').
; outcode: d0 = sx, d1 = sy -> d3. Both trash only d0, d1, d3.
proj_oc:
        ext.l   d0
        asl.l   #8,d0
        divs.w  d2,d0
        add.w   #256,d0             ; sx
        muls.w  #yfocal,d1
        divs.w  d2,d1
        add.w   #horizon,d1         ; sy
outcode:
        moveq   #0,d3
        tst.w   d0
        bpl.s   .o1
        moveq   #1,d3               ; left of the screen
.o1:    cmp.w   #511,d0
        ble.s   .o2
        addq.w  #2,d3               ; right
.o2:    tst.w   d1
        bpl.s   .o3
        addq.w  #4,d3               ; above
.o3:    cmp.w   #playbot,d1
        ble.s   .o4
        addq.w  #8,d3               ; below the play area
.o4:    rts

; ---------------------------------------------------------------- clip edge
; In: cwrk holds two vertex records A, B (vs_* layout), not both behind
; the near plane and not both past the same screen edge. A record with
; outcode $10 (z' <= znear_o) is moved along the edge to z' = znear_o
; (parametric, t in 0.15 fixed point: one divs, two muls) and projected;
; then Cohen-Sutherland against 0..511 x 0..playbot, one muls + divs
; per boundary crossed (the outside endpoint moves to the boundary of
; its lowest set bit; every step clears a bit for good, so at most a
; few rounds -- a guard drops the edge after eight).
; Out: d0-d3 = x1,y1,x2,y2 on screen and d4 = 1, or d4 = 0 for nothing.
; Trashes d0-d5, a0, a1.
clip_edge:
        lea     cwrk(pc),a0
        lea     cw_size(a0),a1
        btst    #4,cw_oc+1(a0)      ; A behind the near plane?
        bne.s   .near
        btst    #4,cw_oc+1(a1)      ; B?
        beq.s   .cs
        exg     a0,a1               ; the near one at a0
.near:  move.w  #znear_o,d0
        sub.w   cw_z(a0),d0         ; znear_o - zA (>= 0)
        ext.l   d0
        asl.l   #8,d0
        asl.l   #7,d0               ; << 15
        move.w  cw_z(a1),d1
        sub.w   cw_z(a0),d1         ; zB - zA (> 0)
        divs.w  d1,d0               ; t = 0.15 fraction along A->B
        move.w  cw_x(a1),d1
        sub.w   cw_x(a0),d1
        muls.w  d0,d1
        asr.l   #8,d1
        asr.l   #7,d1
        add.w   cw_x(a0),d1         ; x at the near plane
        move.w  cw_y(a1),d2
        sub.w   cw_y(a0),d2
        muls.w  d0,d2
        asr.l   #8,d2
        asr.l   #7,d2
        add.w   cw_y(a0),d2         ; y
        move.w  d1,d0
        move.w  d2,d1
        move.w  #znear_o,d2
        bsr     proj_oc
        move.w  d0,cw_sx(a0)
        move.w  d1,cw_sy(a0)
        move.w  d3,cw_oc(a0)
        lea     cwrk(pc),a0
        lea     cw_size(a0),a1
.cs:    move.w  #8,-(sp)            ; round guard
.round: move.w  cw_oc(a0),d4
        move.w  cw_oc(a1),d5
        move.w  d4,d0
        or.w    d5,d0
        beq     .acc
        and.w   d5,d4
        bne     .rej
        subq.w  #1,(sp)
        bmi     .rej
        tst.w   cw_oc(a0)
        bne.s   .p
        exg     a0,a1               ; P (a0) = the outside endpoint
.p:     move.w  cw_oc(a0),d4
        move.w  cw_sx(a0),d0        ; x1, y1 = P
        move.w  cw_sy(a0),d1
        move.w  cw_sx(a1),d2        ; x2, y2 = Q
        move.w  cw_sy(a1),d3
        sub.w   d0,d2               ; dx
        sub.w   d1,d3               ; dy
        btst    #2,d4
        beq.s   .n4
        neg.w   d1                  ; top: x += dx*(0 - y1)/dy, y = 0
        muls.w  d1,d2
        divs.w  d3,d2
        add.w   d2,d0
        moveq   #0,d1
        bra.s   .put
.n4:    btst    #3,d4
        beq.s   .n8
        move.w  #playbot,d5         ; bottom: x += dx*(playbot - y1)/dy
        sub.w   d1,d5
        muls.w  d5,d2
        divs.w  d3,d2
        add.w   d2,d0
        move.w  #playbot,d1
        bra.s   .put
.n8:    btst    #0,d4
        beq.s   .n1
        neg.w   d0                  ; left: y += dy*(0 - x1)/dx, x = 0
        muls.w  d0,d3
        divs.w  d2,d3
        add.w   d3,d1
        moveq   #0,d0
        bra.s   .put
.n1:    move.w  #511,d5             ; right: y += dy*(511 - x1)/dx
        sub.w   d0,d5
        muls.w  d5,d3
        divs.w  d2,d3
        add.w   d3,d1
        move.w  #511,d0
.put:   move.w  d0,cw_sx(a0)
        move.w  d1,cw_sy(a0)
        bsr     outcode             ; d3 from d0, d1
        move.w  d3,cw_oc(a0)
        bra     .round
.acc:   addq.l  #2,sp
        move.w  cw_sx(a0),d0
        move.w  cw_sy(a0),d1
        move.w  cw_sx(a1),d2
        move.w  cw_sy(a1),d3
        moveq   #1,d4
        rts
.rej:   addq.l  #2,sp
        moveq   #0,d4
        rts

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
; Four decimal fields (lib/draw_dec.asm, self-erasing):
;   rows 242-246, green byte 0:  forward speed, tenths of a unit/beat
;                 green byte 8:  drift = sideways speed, tenths
;                 green byte 16: heading, integer brads 0..255
;   rows 248-252, green byte 0:  objects drawn this frame
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
        bsr     draw_dec
        move.w  ocam+oc_n(pc),d0    ; objects drawn this frame
        lea     248*scr_llen(a4),a0
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
;   rows 248-252: extra beats in the window (0 = pure 50 Hz) | avg spins
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
xbeats: dc.w    0                   ; frame edges consumed during the work
ocam:   ds.b    16                  ; object-stage camera block (oc_*)
cur:    ds.b    cu_size             ; current object (cu_*)

headroom:
        dc.l    0                   ; idle spins in last loop's VBL wait
        dc.l    0                   ; +4  window: spins accumulator
        dc.w    0                   ; +8  window: extra beats
        dc.w    mwin                ; +10 loops left in the window
        dc.w    0                   ; +12 latched avg spins (meter A)
        dc.w    0                   ; +14 latched extra beats (meter B)
        dc.w    1                   ; +16 beats of the last loop (1..3)
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

; object scratch: transformed vertices, the clip work area, and the
; per-buffer erase-box lists (count, then maxobj parade-format records)
vscr:   ds.b    16*12
cwrk:   ds.b    2*cw_size
bbox0:  dc.w    0
        ds.w    maxobj*4
bbox1:  dc.w    0
        ds.w    maxobj*4

; movem predecrement masks for the first 0..7 registers of the zeroed
; set d0,d1,d3,d6,a1,a2,a3,a5 (bit 15 = d0 ... bit 0 = a7)
emtab:  dc.w    $0000,$8000,$c000,$d000,$d200,$d240,$d260,$d270

; entity pool (e_* offsets), filled from the level table at start
entpool:
        ds.b    (nent+1)*e_size

; ------------------------------------------------------------------- level
; Static entities (spec 6): mesh, flags, x, z, centre height, heading,
; two reserved words; -1 ends the table. The spawn is (128, 128) looking
; along +z: an avenue of towers ahead (x -256 and 512, every 768 in z),
; blocks on the flanks, mines down the middle at hover height, and a
; few towers beside and behind the spawn for turning.
level:
        dc.w    msh_tower,1,-256,768,yb_tower,0,0,0
        dc.w    msh_tower,1,512,768,yb_tower,0,0,0
        dc.w    msh_tower,1,-256,1536,yb_tower,21<<8,0,0
        dc.w    msh_tower,1,512,1536,yb_tower,21<<8,0,0
        dc.w    msh_tower,1,-256,2304,yb_tower,0,0,0
        dc.w    msh_tower,1,512,2304,yb_tower,0,0,0
        dc.w    msh_tower,1,-256,3072,yb_tower,21<<8,0,0
        dc.w    msh_tower,1,512,3072,yb_tower,21<<8,0,0
        dc.w    msh_tower,1,-256,3840,yb_tower,0,0,0
        dc.w    msh_tower,1,512,3840,yb_tower,0,0,0
        dc.w    msh_tower,1,-256,4608,yb_tower,0,0,0
        dc.w    msh_tower,1,512,4608,yb_tower,0,0,0
        dc.w    msh_block,1,-768,1152,yb_block,0,0,0
        dc.w    msh_block,1,1024,1920,yb_block,32<<8,0,0
        dc.w    msh_block,1,-768,2688,yb_block,32<<8,0,0
        dc.w    msh_block,1,1024,3456,yb_block,0,0,0
        dc.w    msh_mine,1,128,1152,cam_h,0,0,0
        dc.w    msh_mine,1,128,2688,cam_h,0,0,0
        dc.w    msh_mine,1,128,4224,cam_h,0,0,0
        dc.w    msh_tower,1,-1280,128,yb_tower,0,0,0
        dc.w    msh_tower,1,1536,128,yb_tower,0,0,0
        dc.w    msh_tower,1,128,-1024,yb_tower,0,0,0
        dc.w    msh_tower,1,-768,-768,yb_tower,0,0,0
        dc.w    msh_tower,1,1024,-768,yb_tower,0,0,0
        dc.w    -1

        include "meshes.inc"
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
