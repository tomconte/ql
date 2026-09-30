; strip.asm -- glider: the top strip and the sight (spec 5.4): the
; four-corner sight over the play area, the shield bar at the left of
; the strip, the heading-up radar at its centre. Included by glider.asm.

; -------------------------------------------------------------- sight erase
; sight_erase: at the erase stage, clear the sight this buffer shows
; when this frame's differs (off, or the other colour), and latch this
; frame's colour: the simulation may change sight_col later in the
; loop, and the draw must match what the erase assumed. An unchanged
; sight stays, and is redrawn (sight_rd) only if something may have cut
; it: an erase box just cleared that overlapped it (sight_hit, noted by
; the object stage when it built the box), or, while it is red, the
; lattice's red dot erase. Objects and dots only OR over it.
; In:      d7 = back buffer index, a4 = back buffer base
; Out:     sight_now = this frame's sight colour, sight_rd = redraw it
; Trashes: d0, d1, a0, a1
sight_erase:
        lea     sight_col(pc),a0
        move.b  (a0),d1             ; wanted: 0 off, 1 red, 2 green
        move.b  d1,sight_now-sight_col(a0)
        move.b  sight_buf-sight_col(a0,d7.w),d0 ; what this buffer shows
        st      sight_rd-sight_col(a0)          ; redraw, unless intact:
        cmp.b   d0,d1
        bne.s   .chg
        cmp.b   #col_red,d1
        beq     .keep               ; red: the dot erase may have cut it
        tst.b   sight_hit-sight_col(a0,d7.w)
        bne     .keep               ; an erase box overlapped it
        sf      sight_rd-sight_col(a0)          ; intact
        bra     .keep
.chg:   tst.b   d0
        beq     .keep               ; shows none
        move.l  a4,a0
        btst    #1,d0
        bne.s   .grn
        addq.l  #1,a0               ; red: the odd bytes
.grn:   sight_ops and,$ff
.keep:  rts

; --------------------------------------------------------------- sight draw
; sight_draw: the sight in this frame's colour (sight_now, latched by
; sight_erase), drawn over the objects unless it is intact in this
; buffer (sight_rd clear), and noted as what this buffer shows.
; In:      d7 = back buffer index, a4 = back buffer base
; Out:     sight_buf[d7] = sight_now
; Trashes: d0, a0, a1
sight_draw:
        lea     sight_now(pc),a0
        move.b  (a0),d0
        move.b  d0,sight_buf-sight_now(a0,d7.w)
        beq     .off
        tst.b   sight_rd-sight_now(a0)
        beq     .off                ; intact since this buffer drew it
        move.l  a4,a0
        btst    #1,d0
        bne.s   .grn
        addq.l  #1,a0               ; red: the odd bytes
.grn:   sight_ops or,0
.off:   rts

; -------------------------------------------------------------- radar frame
; radar_frame: the radar's static frame, drawn once into each buffer at
; start: the 90-degree view wedge (two green lines from the centre to
; the rim at 45 degrees either side of straight ahead) and four 2-px
; ticks inside the rim. Nothing erases it: the radar records a dot only
; where it turned a pixel on (radar, .dot).
; In:      a4 = screen base
; Out:     none
; Trashes: d0-d5, a0, a1
radar_frame:
        move.w  #rad_x,d0
        move.w  #rad_y,d1
        move.w  #rad_x-(rad_rx*181+128)/256,d2  ; sin 45 = 181/256
        move.w  #rad_y-(rad_ry*181+128)/256,d3
        moveq   #col_green,d4
        bsr     draw_line
        move.w  #rad_x,d0
        move.w  #rad_y,d1
        move.w  #rad_x+(rad_rx*181+128)/256,d2
        move.w  #rad_y-(rad_ry*181+128)/256,d3
        moveq   #col_green,d4
        bsr     draw_line
        or.b    #$80>>(rad_x&7),(rad_y-rad_ry)*scr_llen+(rad_x>>3)*2(a4)
        or.b    #$80>>(rad_x&7),(rad_y-rad_ry+1)*scr_llen+(rad_x>>3)*2(a4)
        or.b    #$80>>(rad_x&7),(rad_y+rad_ry)*scr_llen+(rad_x>>3)*2(a4)
        or.b    #$80>>(rad_x&7),(rad_y+rad_ry-1)*scr_llen+(rad_x>>3)*2(a4)
        or.b    #$80>>((rad_x-rad_rx)&7),rad_y*scr_llen+((rad_x-rad_rx)>>3)*2(a4)
        or.b    #$80>>((rad_x-rad_rx+1)&7),rad_y*scr_llen+((rad_x-rad_rx+1)>>3)*2(a4)
        or.b    #$80>>((rad_x+rad_rx)&7),rad_y*scr_llen+((rad_x+rad_rx)>>3)*2(a4)
        or.b    #$80>>((rad_x+rad_rx-1)&7),rad_y*scr_llen+((rad_x+rad_rx-1)>>3)*2(a4)
        rts

; --------------------------------------------------------------- shield bar
; shield_bar: the shield at the top left of the strip, into both screens
; at once (it changes rarely, and nothing else draws there): shield_max
; slots of 8 px, 16 px apart, on rows sb_y..sb_y+5; a full slot solid,
; an empty one only its floor row; green, red at shield_low or less.
; In:      none
; Out:     none
; Trashes: d0-d4, a0, a1
shield_bar:
        move.w  shield(pc),d2
        move.w  #$ff00,d3           ; a slot's word: green (the even byte)
        cmp.w   #shield_low,d2
        bgt.s   .grn
        move.w  #$00ff,d3           ; red (the odd byte)
.grn:   lea     scr0+sb_y*scr_llen+sb_x/4,a0
        bsr.s   .bar
        lea     scr1+sb_y*scr_llen+sb_x/4,a0
.bar:   moveq   #0,d1               ; slot index
.slot:  moveq   #0,d4
        cmp.w   d2,d1
        bge.s   .emp
        move.w  d3,d4               ; full
.emp:   move.w  d4,(a0)
        move.w  d4,scr_llen(a0)
        move.w  d4,2*scr_llen(a0)
        move.w  d4,3*scr_llen(a0)
        move.w  d4,4*scr_llen(a0)
        move.w  d3,5*scr_llen(a0)   ; the floor
        addq.l  #4,a0               ; next slot: 16 px on
        addq.w  #1,d1
        cmp.w   #shield_max,d1
        blt.s   .slot
        rts

; --------------------------------------------------------------- radar tabs
; radar_tabs: the sweep's pixel lists, built into the dataspace at start
; (radtab: rad_nang lists of rad_stride bytes). List i is the line from
; the centre to the rim at 4i brads (0 = straight ahead, clockwise),
; walked in 8.8 steps of at most one pixel and dotted: every other
; pixel, counted back from the rim one (half the sweep's cost, 2026-09-
; 29). Less the pixels the static frame has on -- tested on screen 0,
; where radar_frame drew it -- so the sweep never records, and never
; erases, a frame pixel. Records are the dot list's own: (byte offset,
; inverse mask), after a count word.
; In:      screen 0 holds the radar frame
; Out:     radtab built
; Trashes: d0-d7, a0-a3
radar_tabs:
        lea     ds_base(pc),a2
        lea     radtab(a2),a2       ; a2 = list 0
        lea     sintab(pc),a1
        moveq   #0,d6               ; list index
.ang:   move.w  d6,d0
        lsl.w   #3,d0               ; 4i brads, word index
        move.w  (a1,d0.w),d2        ; sin
        add.w   #128,d0             ; cos = sin(a + 64)
        and.w   #511,d0
        move.w  (a1,d0.w),d3        ; cos
        muls.w  #rad_rx,d2
        add.l   #128,d2
        asr.l   #8,d2               ; dx to the rim (right = +)
        muls.w  #-rad_ry,d3
        add.l   #128,d3
        asr.l   #8,d3               ; dy to the rim (up = -)
        move.w  d2,d4               ; steps = max(|dx|, |dy|): 12..rad_rx
        bpl.s   .ax
        neg.w   d4
.ax:    move.w  d3,d5
        bpl.s   .ay
        neg.w   d5
.ay:    cmp.w   d5,d4
        bge.s   .mx
        move.w  d5,d4
.mx:    ext.l   d2
        asl.l   #8,d2
        divs.w  d4,d2               ; x step, 8.8
        ext.l   d3
        asl.l   #8,d3
        divs.w  d4,d3               ; y step, 8.8
        move.w  #128,d5             ; x offset, 8.8 (+0.5: the floor rounds)
        move.w  #128,d7             ; y offset
        lea     2(a2),a3            ; records
        subq.w  #1,d4
.px:    add.w   d2,d5
        add.w   d3,d7
        btst    #0,d4
        bne.s   .fr                 ; dotted: the rim pixel, then every other
        move.w  d7,d1
        asr.w   #8,d1
        add.w   #rad_y,d1
        lsl.w   #7,d1               ; row offset
        move.w  d5,d0
        asr.w   #8,d0
        add.w   #rad_x,d0           ; x
        move.w  d0,a0
        lsr.w   #3,d0
        add.w   d0,d1
        add.w   d0,d1               ; + (x>>3)*2: the green byte
        move.w  a0,d0
        not.w   d0
        and.w   #7,d0               ; bit number: 7 - (x & 7)
        lea     scr0,a0
        btst    d0,(a0,d1.w)
        bne.s   .fr                 ; a frame pixel: left out
        move.w  d1,(a3)+            ; offset,
        moveq   #-1,d1
        bclr    d0,d1
        move.w  d1,(a3)+            ;   inverse mask
.fr:    dbf     d4,.px
        move.l  a3,d0               ; count
        sub.l   a2,d0
        subq.l  #2,d0
        lsr.l   #2,d0
        move.w  d0,(a2)
        lea     rad_stride(a2),a2
        addq.w  #1,d6
        cmp.w   #rad_nang,d6
        blt     .ang
        rts

; -------------------------------------------------------------------- radar
; radar: this frame's sweep, copied from its pixel list (radar_tabs)
; into the screen and the buffer's dot list, in the room dots_open
; keeps for it past dl_end: the erase stage clears it. The blips come
; from the object stage (objects, .blip). The sweep turns once in
; ~1.4 s, stepped by the previous loop's beats like the flight model;
; list i covers 4i..4i+3 brads.
; In:      d7 = back buffer index, a4 = back buffer base, the dot list
;          open
; Out:     the sweep appended to the dot list (dl_next, count), sweep
;          advanced
; Trashes: d0-d2, a0, a1
radar:
        lea     sweep(pc),a0
        move.w  headroom+16(pc),d0  ; beats of the previous loop
        mulu.w  #rad_sweep,d0
        add.w   (a0),d0
        move.w  d0,(a0)
        rol.w   #6,d0
        and.w   #rad_nang-1,d0      ; list index: the angle's top 6 bits
        mulu.w  #rad_stride,d0
        lea     ds_base(pc),a0
        add.l   d0,a0
        lea     radtab(a0),a0       ; this angle's list
        move.l  dl_base(pc),a1
        move.w  (a0)+,d1            ; the sweep's pixels: 0 where the
        add.w   d1,(a1)             ; list lies on a wedge line
        move.l  dl_next(pc),a1
        bra.s   .swe
.sw:    move.l  (a0)+,d0            ; offset : inverse mask
        move.l  d0,(a1)+            ; the dot record
        move.w  d0,d2
        not.b   d2                  ; the mask
        swap    d0
        or.b    d2,(a4,d0.w)
.swe:   dbf     d1,.sw
        lea     dl_next(pc),a0
        move.l  a1,(a0)
        rts
