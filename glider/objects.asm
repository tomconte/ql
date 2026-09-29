; objects.asm -- glider: the object stage of the frame loop (spec 5.1,
; 5.2). Included by glider.asm.

; ------------------------------------------------------------- object stage
; objects: every active entity through the four-level cull (world box,
; bounding sphere against the frustum, faces by their planes with the
; eye in the mesh's frame, edges by outcodes), then its vertices into
; camera space and on screen, and its edges drawn: straight to
; draw_line when every vertex is on screen, else through clip_edge; one
; erase box per drawn object, and a frame-edge poll after it. Across
; the stage a5 = entity; draw_line trashes a0/a1, so a1 (cur) is
; reloaded after every line.
; In:      d7 = back buffer index, a4 = back buffer base
; Out:     this buffer's erase-box list rebuilt, ocam (oc_n = objects
;          drawn), xbeats (frame edges polled)
; Trashes: d0-d6, a0-a3, a5, a6, cur, vscr, cwrk
objects:
        lea     craft(pc),a0
        lea     ocam(pc),a1
        move.l  c_px(a0),d0
        lsr.l   #8,d0
        move.w  d0,oc_px(a1)        ; camera position, integer units
        move.l  c_pz(a0),d0
        lsr.l   #8,d0
        move.w  d0,oc_pz(a1)
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
; --- world box on the nearest image (the sector wraps, spec 6): the
; 16-bit difference cut to 13 bits and sign-extended, -4096..4095; then
; |dx|, |dz| < r_active
        move.w  e_x(a5),d0
        sub.w   ocam+oc_px(pc),d0
        lsl.w   #16-sector_sh,d0
        asr.w   #16-sector_sh,d0    ; dx
        move.w  d0,d1
        bpl.s   .bx
        neg.w   d1
.bx:    cmp.w   #r_active,d1
        bge     .enext
        move.w  e_z(a5),d2
        sub.w   ocam+oc_pz(pc),d2
        lsl.w   #16-sector_sh,d2
        asr.w   #16-sector_sh,d2    ; dz
        move.w  d2,d1
        bpl.s   .bz
        neg.w   d1
.bz:    cmp.w   #r_active,d1
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
.edone: rts
