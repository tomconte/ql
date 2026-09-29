; lattice.asm -- glider: the ground lattice stage of the frame loop
; (spec 5.3) and its wedge records. Included by glider.asm.

; ------------------------------------------------------------ lattice stage
; lattice: this frame's red ground dots, recorded in the buffer's dot
; list for the erase. Camera-space corner of the cell window and the two
; world step vectors, all 16.16 so the walk below is exact. The window
; is (2*nwin+1)^2 cells around the camera cell; the corner is at
; (-nwin*latd - rx, -nwin*latd - rz) relative to the camera, rx/rz the
; camera's offset within its cell. Camera transform (spec 5.1):
;   xc = dx*c - dz*s,  zc = dz*c + dx*s      (8.8 trig, 256 = 1.0)
; In:      d7 = back buffer index, a4 = back buffer base, the dot list
;          open (dots_open)
; Out:     the dots appended to the dot list (dl_next, count)
; Trashes: d0-d6, a0-a3, a5, a6, lat_uz, wdg, lst_max
lattice:
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
        move.l  dl_next(pc),a1      ; a1 = first record
        lea     maxdots*4(a1),a0
        lea     lst_max(pc),a6
        move.l  a0,(a6)             ; row-granular overflow check below
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
        lea     dl_next(pc),a0      ; the records into the count
        move.l  a1,d0
        sub.l   (a0),d0
        lsr.l   #2,d0
        move.l  a1,(a0)
        move.l  dl_base(pc),a0
        add.w   d0,(a0)
        rts

; ------------------------------------------------------------- wedge record
; wdg_put: one wedge test record for wbound (12 bytes): DF = w*latd
; (16.16), (2*nwin)*DF, DF>>16, pad.
; In:      d0.w = w (trig sum, 8.8), a0 = record
; Out:     a0 = next record (+12)
; Trashes: d0, d1, d4
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
