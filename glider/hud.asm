; hud.asm -- glider: the HUD band: flight readouts, meters, headroom
; bar. Included by glider.asm.

; ---------------------------------------------------------------- HUD readouts
; draw_hud: four decimal fields (lib/draw_dec.asm, self-erasing):
;   rows 242-246, green byte 0:  forward speed, tenths of a unit/beat
;                 green byte 8:  drift = sideways speed, tenths
;                 green byte 16: heading, integer brads 0..255
;   rows 248-252, green byte 0:  objects drawn this frame
; The speeds are magnitudes: in reverse the dots flow the other way.
; Refreshed every 4th frame (drawn twice, once per buffer): five
; draw_dec calls a frame cost ~4 ms, a third of the original budget.
; In:      a4 = back buffer base
; Out:     none
; Trashes: d0-d6, a0-a3
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
; draw_meters: six decimal readouts latched from the mwin-loop window,
; at green bytes 48, 56, 64 (x 192, 224, 256):
;   rows 242-246: avg idle spins per loop (1 spin ~ 20 us) | avg spins
;                 on buffer-0 loops | min spins in the window
;   rows 248-252: extra beats in the window (0 = pure 50 Hz) | avg spins
;                 on buffer-1 loops | max spins in the window
; Blank until the first full window has latched; then drawn only in
; the two frames after each latch (one per buffer), since the values
; change only then.
; In:      a4 = back buffer base
; Out:     none
; Trashes: d0-d4, a0-a3
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
; draw_hbar: 64 groups of 8 px, lit = green byte $ff; the unlit
; remainder is written black, so the bar self-erases. Long writes: two
; groups each.
; In:      a4 = back buffer base
; Out:     none
; Trashes: d0-d4, a0, a1
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
