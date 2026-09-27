; render.asm -- glider: rendering helpers of the frame loop: per-buffer
; list selectors, erase-box extend, projection and outcodes, edge
; clipping, lattice wedge records. Included by glider.asm.

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
