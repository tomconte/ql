; shapes.asm -- 3D shape parade: plausible game assets on the engine
;
; The cube engine (cube/cube.asm) generalized to data-driven meshes: a
; demo-style slideshow cycling five validated solids -- cube, dart
; fighter, hexagonal tower, space mine, and a 10-face Starglider-style
; enemy fighter -- 8 seconds each, tumbling under the same yaw+pitch.
;
; Meshes come from meshes.inc, generated and VALIDATED by
; tools/genmesh.py: closed 2-manifolds, consistent outward winding
; (the backface cull relies on it), <=16 vertices/faces, radius within
; the projection-safe bound. Per object: vertex words, face test
; triples (last face first: the cull loop's dbf counter is the bit
; number), and 4-byte edge records i*4, j*4, two-face mask word.
;
; Everything else is the cube engine, measured in docs/vector-perf.md:
; MODE 4 takeover, double buffer, exact-mask movem erase (self-
; modifying bursts), 8.8-brad beat-scaled rotation, backface culling,
; white edges via lib/draw_line_w.asm, live headroom bar + averaged
; meters (top: avg idle spins, ~20 us each; bottom: 2-beat loops out
; of 128). The meters now profile each OBJECT as it shows.
;
; Assemble: vasmm68k_mot -m68008 -Fbin -o shapes_bin shapes.asm

; hardware
mc_stat     equ     $18063          ; ZX8301 display control (write-only)
pc_intr     equ     $18021          ; ZX8302 interrupt register
pc__frame   equ     3               ; bit 3 = 50/60 Hz frame interrupt

scr0        equ     $20000          ; screen 0 (displayed at boot)
scr1        equ     $28000          ; screen 1 (ex-QDOS sysvars, now ours)
scr_llen    equ     128             ; bytes per scan line

; projection (see the radius bound in tools/genmesh.py)
zdist       equ     300             ; Z0: eye distance to object centre
yfocal      equ     170             ; py = 120 + y'*yfocal/(Z0+z)
ctr_x       equ     256             ; px = 256 + x'*256/(Z0+z)
ctr_y       equ     120

; angles are 8.8 fixed-point brads (65536 = full turn, word wrap is the
; modulo), stepped per BEAT (20 ms) scaled by the last loop's beats
da          equ     256             ; yaw: 1 brad/beat
db          equ     384             ; pitch: 1.5 brads/beat

showtime    equ     400             ; beats per object (8 s)

; headroom bar (game8 calibration: ~1000 idle spins = a whole free frame)
hb_y        equ     252             ; bar top line (2 rows tall)
hb_shift    equ     4

; profiling flags: skip a stage to measure its cost as the meter delta
no_erase    equ     0
no_draw     equ     0

mwin        equ     128             ; meter window, loops (power of 2)
mshift      equ     7

; ---------------------------------------------------------------- job header
start:
        bra.s   main
        dc.l    0
        dc.w    $4afb               ; "job name follows" flag
        dc.w    jobname_e-jobname
jobname:
        dc.b    'Shapes'
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

        bsr     obj_next            ; arm object 0 (obj_ix starts at -1)
        move.b  #1<<pc__frame,pc_intr   ; discard any pending frame bit
        moveq   #1,d7               ; back buffer index: screen 1

; ---------------------------------------------------------------- frame loop
frame_loop:
        lea     scr0,a4             ; a4 = back buffer base
        tst.w   d7
        beq.s   .bb0
        lea     scr1,a4
.bb0:
; ----- erase what this buffer held two frames ago: movem-clear the
; bounding box rows (bbox: miny, nrows, end-of-span offset, L = longs
; per row; nrows = 0 -> nothing yet). Nine registers hold zeros for
; free; the two burst masks below are patched per frame from emtab so
; each row clears exactly L longs (empty mask = legal no-op).
        ifeq    no_erase
        lea     bbox0(pc),a2
        move.w  d7,d0
        lsl.w   #3,d0
        adda.w  d0,a2               ; a2 = bbox[d7]
        move.w  (a2)+,d1            ; miny
        move.w  (a2)+,d2            ; nrows
        beq     .noer
        move.w  (a2)+,d3            ; end-of-span offset in the row
        move.w  (a2),d4             ; L: longs to clear per row
        lsl.w   #7,d1
        add.w   d3,d1
        lea     (a4,d1.w),a0        ; end of the first row's span
        lea     emtab(pc),a1        ; patch the burst masks for L
        moveq   #9,d1
        moveq   #0,d3
        cmp.w   d1,d4
        ble.s   .esm
        move.w  d4,d3
        sub.w   d1,d3               ; L > 9: remainder mask L-9 regs
        bra.s   .epq
.esm:   move.w  d4,d1               ; L <= 9: first mask L regs only
.epq:   add.w   d1,d1
        move.w  (a1,d1.w),d1        ; first burst mask
        add.w   d3,d3
        move.w  (a1,d3.w),d3        ; second burst mask
        lea     .em1+2(pc),a1
        move.w  d1,(a1)
        lea     .em2+2(pc),a1
        move.w  d3,(a1)
        lsl.w   #2,d4
        add.w   #scr_llen,d4        ; row stride = 128 + 4L
        moveq   #0,d0               ; nine zeros for the bursts
        moveq   #0,d1
        moveq   #0,d3
        moveq   #0,d5
        moveq   #0,d6
        suba.l  a1,a1
        suba.l  a2,a2
        suba.l  a3,a3
        suba.l  a5,a5
.erow:
.em1:   movem.l d0-d1/d3/d5-d6/a1-a3/a5,-(a0)   ; masks patched above
.em2:   movem.l d0-d1/d3/d5-d6/a1-a3/a5,-(a0)
        adda.w  d4,a0
        subq.w  #1,d2
        bne.s   .erow
.noer:
        endc

; ----- rotate: advance angles by the previous loop's beats (constant
; angular speed in TIME), look up sin/cos into trig(pc)
        lea     angles(pc),a0
        lea     sintab(pc),a1
        lea     trig(pc),a2
        move.w  headroom+16(pc),d2  ; beats of the previous loop (1|2)
        move.w  d2,d1
        muls.w  #da,d1              ; yaw step
        move.w  (a0),d0
        add.w   d1,d0               ; word wrap = mod 256 brads
        move.w  d0,(a0)
        lsr.w   #8,d0               ; integer brad
        add.w   d0,d0
        move.w  (a1,d0.w),d1
        move.w  d1,(a2)             ; sa
        lsr.w   #1,d0
        add.w   #64,d0              ; cos = sin(a+64)
        and.w   #255,d0
        add.w   d0,d0
        move.w  (a1,d0.w),d1
        move.w  d1,2(a2)            ; ca
        move.w  d2,d1
        muls.w  #db,d1              ; pitch step
        move.w  2(a0),d0
        add.w   d1,d0
        move.w  d0,2(a0)
        lsr.w   #8,d0
        add.w   d0,d0
        move.w  (a1,d0.w),d1
        move.w  d1,4(a2)            ; sb
        lsr.w   #1,d0
        add.w   #64,d0
        and.w   #255,d0
        add.w   d0,d0
        move.w  (a1,d0.w),d1
        move.w  d1,6(a2)            ; cb

; ----- transform + project the current object's vertices into vtx2d
        lea     cur(pc),a0
        move.w  12(a0),d6           ; nvtx-1
        move.l  (a0),a0             ; a0 = vertex table
        lea     vtx2d(pc),a1
.vtx:   move.w  (a0)+,d0            ; x
        move.w  (a0)+,d1            ; y
        move.w  (a0)+,d2            ; z
        move.w  d0,d3               ; yaw: x' = (x*ca + z*sa) >> 8
        muls.w  2(a2),d3
        move.w  d2,d4
        muls.w  (a2),d4
        add.l   d4,d3
        asr.l   #8,d3               ; d3 = x'
        muls.w  2(a2),d2            ; z' = (z*ca - x*sa) >> 8
        muls.w  (a2),d0
        sub.l   d0,d2
        asr.l   #8,d2               ; d2 = z'
        move.w  d1,d4               ; pitch: y' = (y*cb - z'*sb) >> 8
        muls.w  6(a2),d4
        move.w  d2,d5
        muls.w  4(a2),d5
        sub.l   d5,d4
        asr.l   #8,d4               ; d4 = y'
        muls.w  4(a2),d1            ; z'' = (y*sb + z'*cb) >> 8
        muls.w  6(a2),d2
        add.l   d2,d1
        asr.l   #8,d1               ; d1 = z''
        add.w   #zdist,d1           ; d1 = Z0 + z'' (always > 0)
        move.w  d3,d0               ; perspective x
        ext.l   d0
        asl.l   #8,d0               ; x' * 256
        divs.w  d1,d0
        add.w   #ctr_x,d0
        move.w  d0,(a1)+            ; px
        muls.w  #yfocal,d4          ; perspective y
        divs.w  d1,d4
        add.w   #ctr_y,d4
        move.w  d4,(a1)+            ; py
        dbf     d6,.vtx

; ----- bounding box of the new projection (for this buffer's NEXT erase)
        lea     cur(pc),a0
        move.w  12(a0),d6           ; nvtx-1
        subq.w  #1,d6               ; minus the seed vertex
        lea     vtx2d(pc),a0
        move.w  (a0)+,d0            ; minx = maxx = x0
        move.w  d0,d1
        move.w  (a0)+,d2            ; miny = maxy = y0
        move.w  d2,d3
.bb:    move.w  (a0)+,d4
        cmp.w   d4,d0
        ble.s   .b1
        move.w  d4,d0
.b1:    cmp.w   d4,d1
        bge.s   .b2
        move.w  d4,d1
.b2:    move.w  (a0)+,d4
        cmp.w   d4,d2
        ble.s   .b3
        move.w  d4,d2
.b3:    cmp.w   d4,d3
        bge.s   .b4
        move.w  d4,d3
.b4:    dbf     d6,.bb
        lea     bbox0(pc),a2
        move.w  d7,d4
        lsl.w   #3,d4
        adda.w  d4,a2
        move.w  d2,(a2)+            ; miny
        sub.w   d2,d3
        addq.w  #1,d3
        move.w  d3,(a2)+            ; nrows
        lsr.w   #5,d0               ; 32-px (8-byte) units
        lsr.w   #5,d1
        sub.w   d0,d1               ; units spanned - 1 (radius-capped,
        lsl.w   #3,d0               ; so L = 2*units+2 <= 16 and the
        add.w   d1,d1               ; two 9-max bursts always cover it)
        addq.w  #2,d1
        move.w  d1,d4
        lsl.w   #2,d4               ; 4L = bytes cleared per row
        add.w   d4,d0
        move.w  d0,(a2)+            ; end-of-span offset
        move.w  d1,(a2)             ; L, longs to clear per row

; ----- backface culling: build the face-visibility mask in d5. Faces
; are wound so a front face projects with cross > 0 (y grows down):
;   cross = (bx-ax)*(cy-ay) - (by-ay)*(cx-ax)   (long)
; The face table is last-face-first: the dbf counter is the bit number.
        ifeq    no_draw
        lea     cur(pc),a0
        move.w  14(a0),d6           ; nfaces-1
        move.l  4(a0),a0            ; a0 = face test triples
        lea     vtx2d(pc),a3        ; a3 stays vtx2d through the draws
        moveq   #0,d5
.face:  moveq   #0,d0
        move.b  (a0)+,d0            ; vertex a (offsets pre-multiplied)
        moveq   #0,d1
        move.b  (a0)+,d1            ; vertex b
        moveq   #0,d2
        move.b  (a0)+,d2            ; vertex c
        move.w  (a3,d1.w),d3        ; bx - ax
        sub.w   (a3,d0.w),d3
        move.w  2(a3,d2.w),d4       ; cy - ay
        sub.w   2(a3,d0.w),d4
        muls.w  d4,d3
        move.w  2(a3,d1.w),d4       ; by - ay
        sub.w   2(a3,d0.w),d4
        move.w  (a3,d2.w),d1        ; cx - ax
        sub.w   (a3,d0.w),d1
        muls.w  d1,d4
        sub.l   d4,d3               ; cross
        ble.s   .hid                ; <= 0: backface (or edge-on)
        bset    d6,d5
.hid:   dbf     d6,.face
        move.w  d5,a5               ; park the mask across the draws

; ----- draw the edges whose faces are not all hidden
        lea     cur(pc),a2
        move.w  16(a2),d6           ; nedges-1
        move.l  8(a2),a2            ; a2 = edge records
.edge:  move.w  a5,d0
        and.w   2(a2),d0            ; edge's two-face mask vs visibility
        beq.s   .skip
        moveq   #0,d2
        move.b  (a2),d0             ; vertex offsets (pre-multiplied)
        move.b  1(a2),d2
        and.w   #$ff,d0
        move.w  2(a3,d0.w),d1       ; y1
        move.w  (a3,d0.w),d0        ; x1
        move.w  2(a3,d2.w),d3       ; y2
        move.w  (a3,d2.w),d2        ; x2
        bsr     draw_line_w
.skip:  addq.l  #4,a2
        dbf     d6,.edge
        endc

; ----- headroom bar + meters, then VBL sync + flip. A pending frame
; bit at end-of-work marks a 2-beat loop; consume it, wait for the
; next real edge (flips stay VBL-aligned), consume that too so the
; next loop's test is honest. Then pay the object timer in beats.
        bsr     draw_hbar
        bsr     draw_meters
        moveq   #0,d1               ; d1 = 1 if this was a 2-beat loop
        btst    #pc__frame,pc_intr
        beq.s   .onb
        moveq   #1,d1
        move.b  #1<<pc__frame,pc_intr   ; consume the mid-work edge
.onb:   moveq   #0,d0
.wait:  addq.l  #1,d0               ; count idle spins = headroom
        btst    #pc__frame,pc_intr
        beq.s   .wait
        move.b  #1<<pc__frame,pc_intr   ; consume the terminal edge
        lea     headroom(pc),a2
        move.l  d0,(a2)
        add.l   d0,4(a2)            ; window accumulators: spins,
        add.w   d1,8(a2)            ; 2-beat loops,
        addq.w  #1,d1
        move.w  d1,16(a2)           ; beats for the rotation step
        subq.w  #1,10(a2)           ; loops left in the window
        bne.s   .tmr
        move.w  #mwin,10(a2)
        move.l  4(a2),d0            ; latch: avg spins/loop,
        lsr.l   #mshift,d0
        move.w  d0,12(a2)
        move.w  8(a2),14(a2)        ; 2-beat count of the window
        clr.l   4(a2)
        clr.w   8(a2)
.tmr:   lea     obj_ix(pc),a0       ; slideshow: charge the beats
        move.w  2(a0),d0
        sub.w   d1,d0
        bgt.s   .tok
        bsr     obj_next            ; timer spent: next object
        bra.s   .flip
.tok:   move.w  d0,2(a0)
.flip:
        move.w  d7,d0               ; flip: display the buffer just drawn
        ror.b   #1,d0               ; 0 -> $00, 1 -> $80
        move.b  d0,mc_stat
        eori.w  #1,d7               ; other buffer becomes the back one
        bra     frame_loop

; --------------------------------------------------------------- next object
; Advance obj_ix (wrapping), reset the show timer, and cache the new
; object's table pointers and counts in cur. Preserves d7, a4.
obj_next:
        lea     obj_ix(pc),a0
        move.w  (a0),d0
        addq.w  #1,d0
        cmp.w   #nobjs,d0
        blt.s   .ok
        moveq   #0,d0
.ok:    move.w  d0,(a0)
        move.w  #showtime,2(a0)     ; obj_time
        move.w  d0,d1               ; directory entry = objdir + idx*12
        lsl.w   #2,d1
        move.w  d1,d2
        add.w   d1,d1
        add.w   d2,d1
        lea     objdir(pc),a1
        adda.w  d1,a1
        lea     cur(pc),a2
        move.w  (a1)+,12(a2)        ; nvtx-1
        move.w  (a1)+,14(a2)        ; nfaces-1
        move.w  (a1)+,16(a2)        ; nedges-1
        lea     meshes(pc),a0
        move.l  a0,d0
        moveq   #0,d1
        move.w  (a1)+,d1
        add.l   d0,d1
        move.l  d1,(a2)             ; vertex table
        moveq   #0,d1
        move.w  (a1)+,d1
        add.l   d0,d1
        move.l  d1,4(a2)            ; face table
        moveq   #0,d1
        move.w  (a1)+,d1
        add.l   d0,d1
        move.l  d1,8(a2)            ; edge table
        rts

; ------------------------------------------------------------------- meters
; Two 16-bit binary readouts (MSB left, 8-px cell per bit, dashed
; ruler under each), averaged over the mwin-loop window:
;   rows 240-242: average idle spins per loop (1 spin ~ 20 us)
;   rows 245-247: 2-beat loops out of mwin (0 = pure 50 Hz)
draw_meters:
        lea     headroom+12(pc),a1
        move.w  (a1)+,d0
        lea     240*scr_llen+48(a4),a0
        bsr.s   draw_ro
        move.w  (a1),d0
        lea     245*scr_llen+48(a4),a0
draw_ro:                            ; (fallthrough: 2nd readout's rts
        moveq   #16-1,d2            ;  returns to draw_meters' caller)
.cell:  moveq   #0,d1
        add.w   d0,d0               ; MSB out into carry
        bcc.s   .un
        move.b  #$fc,d1             ; lit: 6 px block + 2 px gap
.un:    move.b  d1,(a0)             ; green byte, 2 value rows
        move.b  d1,scr_llen(a0)
        move.b  #$fc,2*scr_llen(a0) ; ruler row
        addq.l  #2,a0
        dbf     d2,.cell
        rts

; -------------------------------------------------------------- headroom bar
; game8's gauge in mode 4: 64 groups of 8 px, lit = green byte $ff.
; The unlit remainder is written black, so the bar self-erases.
draw_hbar:
        lea     headroom(pc),a1
        move.l  (a1),d0
        lsr.l   #hb_shift,d0
        cmp.w   #64,d0
        bls.s   .clip
        moveq   #64,d0
.clip:  lea     hb_y*scr_llen(a4),a0
        moveq   #2-1,d3
.row:   move.w  d0,d1               ; lit groups
        moveq   #64,d2
        sub.w   d0,d2               ; dark groups
        tst.w   d1
        beq.s   .dark
        subq.w  #1,d1
.lit:   move.b  #$ff,(a0)+          ; green byte
        clr.b   (a0)+               ; red byte
        dbf     d1,.lit
.dark:  tst.w   d2
        beq.s   .next
        subq.w  #1,d2
.drk:   clr.b   (a0)+
        clr.b   (a0)+
        dbf     d2,.drk
.next:  dbf     d3,.row             ; 128 bytes written = next line
        rts

; ---------------------------------------------------------------------- data
        even
angles: dc.w    0,0                 ; yaw, pitch (8.8 brads)
trig:   dc.w    0,0,0,0             ; sa, ca, sb, cb (8.8, set per frame)
headroom:
        dc.l    0                   ; idle spins in last loop's VBL wait
        dc.l    0                   ; +4  window: spins accumulator
        dc.w    0                   ; +8  window: 2-beat loop count
        dc.w    mwin                ; +10 loops left in the window
        dc.w    0                   ; +12 latched avg spins (meter A)
        dc.w    0                   ; +14 latched 2-beat count (meter B)
        dc.w    1                   ; +16 beats of the last loop (1|2)

obj_ix: dc.w    -1                  ; current object (armed by obj_next)
        dc.w    1                   ; +2 show time left, in beats

cur:    dc.l    0                   ; +0  vertex table   } cached by
        dc.l    0                   ; +4  face table     } obj_next
        dc.l    0                   ; +8  edge table
        dc.w    0,0,0               ; +12 nvtx-1, +14 nfaces-1, +16 nedges-1

; per-buffer erase boxes: miny, nrows, end-of-span offset, longs/row
bbox0:  dc.w    0,0,0,0             ; nrows = 0: nothing to erase yet
bbox1:  dc.w    0,0,0,0

; movem predecrement register masks for the first 0..9 registers of
; the zeroed set d0,d1,d3,d5,d6,a1,a2,a3,a5 (predec mask: bit 15 = d0)
emtab:  dc.w    $0000,$8000,$c000,$d000,$d400
        dc.w    $d600,$d640,$d660,$d670,$d674

        include "meshes.inc"

vtx2d:  ds.w    32                  ; projected x,y per vertex (max 16)

        include "sin.inc"

        even
sv_stack:
        ds.b    64                  ; private supervisor stack
sv_stack_top:

        include "../lib/draw_line_w.asm"
