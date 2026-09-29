; combat.asm -- glider: the player's shots (spec 7): fired and moved
; once per beat, their static targets found at launch, drawn once per
; frame. Included by glider.asm.

; --------------------------------------------------------------- shots step
; shots_step: one beat of the player's shots. Fire: with Space held and
; the cooldown over, a free shot leaves the next gun port (alternately
; gun_dx either side of the eye) along the heading at shot_v units a
; beat, and shot_cast finds its target. Then every live shot ages and
; moves, and hits when its countdown says so: the world is static, so a
; shot's first hit is known at launch (testing every shot against every
; nearby entity each beat cost ~8 ms a frame). A hit stops the shot; an
; entity whose mesh has od_hp takes it (e_hp) and goes (e_flags = 0) at
; od_hp hits, the rest are obstacles. A target gone meanwhile (another
; shot got it) means a new cast from where the shot is. Last, the sight
; blinks (blink_b beats on, as many off) while any shot is in flight.
; With none in flight and Space up it returns at once.
; In:      d5.b = held keys (row-1 bits)
; Out:     shots, nlive, fire_t, gun_lr, blink, sight_col; entities hit
;          (e_hp, e_flags)
; Trashes: d0-d4, a0-a3, a5
shots_step:
        lea     fire_t(pc),a2
        tst.w   (a2)
        beq.s   .cd
        subq.w  #1,(a2)             ; cooldown, in beats
.cd:    btst    #k1__spc,d5
        bne.s   .fkey
        tst.w   nlive-fire_t(a2)
        bne     .move
        rts                         ; nothing to fire, nothing in flight
.fkey:  tst.w   (a2)
        bne     .move
        lea     shots(pc),a1        ; a free shot?
        lea     nshots*sh_size(a1),a3
.free:  tst.w   sh_life(a1)
        beq.s   .fire
        lea     sh_size(a1),a1
        cmpa.l  a3,a1
        blo.s   .free
        bra     .move               ; all in flight
.fire:  move.w  #fire_cd,(a2)
        addq.w  #1,nlive-fire_t(a2)
        lea     craft(pc),a0
        move.w  c_s(a0),d1          ; s
        move.w  c_c(a0),d2          ; c
        move.w  d1,sh_s(a1)
        move.w  d2,sh_c(a1)
        move.w  d1,d3
        muls.w  #shot_v,d3
        asr.l   #8,d3
        move.w  d3,sh_vx(a1)        ; velocity: shot_v along the heading
        move.w  d2,d3
        muls.w  #shot_v,d3
        asr.l   #8,d3
        move.w  d3,sh_vz(a1)
        move.w  d1,d3
        muls.w  #-shot_len,d3
        asr.l   #8,d3
        move.w  d3,sh_tx(a1)        ; head to tail: shot_len back
        move.w  d2,d3
        muls.w  #-shot_len,d3
        asr.l   #8,d3
        move.w  d3,sh_tz(a1)
        muls.w  #gun_dx,d2
        asr.l   #8,d2               ; the port: gun_dx * right, right =
        muls.w  #gun_dx,d1          ; (c, -s)
        asr.l   #8,d1
        lea     gun_lr(pc),a3
        not.w   (a3)                ; alternate ports
        bne.s   .rgt
        neg.w   d2                  ; the left one
        neg.w   d1
.rgt:   move.l  c_px(a0),d0
        lsr.l   #8,d0
        add.w   d2,d0
        move.w  d0,sh_x(a1)
        move.l  c_pz(a0),d0
        lsr.l   #8,d0
        sub.w   d1,d0
        move.w  d0,sh_z(a1)
        move.w  #shot_life,sh_life(a1)
        bsr     shot_cast
; --- every live shot: age, move, hit when the countdown says so
.move:  lea     shots(pc),a1
        moveq   #0,d4               ; shots in flight after this beat
.shot:  tst.w   sh_life(a1)
        beq.s   .snext
        subq.w  #1,sh_life(a1)
        beq.s   .snext              ; burnt out
        move.w  sh_vx(a1),d0
        add.w   d0,sh_x(a1)
        move.w  sh_vz(a1),d0
        add.w   d0,sh_z(a1)
        move.w  sh_life(a1),d0
        cmp.w   sh_hit(a1),d0
        bne.s   .fly                ; not there yet (or no target)
        move.l  sh_tgt(a1),a5
        tst.w   e_flags(a5)
        bne.s   .hit
        bsr     shot_cast           ; the target went: what is behind it?
        bra.s   .fly                ; (at least a beat away)
.hit:   clr.w   sh_life(a1)         ; the shot stops
        move.w  e_mesh(a5),d0
        lsl.w   #5,d0
        lea     objdir(pc),a0
        move.w  od_hp(a0,d0.w),d0
        beq.s   .snext              ; an obstacle
        addq.w  #1,e_hp(a5)
        cmp.w   e_hp(a5),d0
        bgt.s   .snext
        clr.w   e_flags(a5)         ; destroyed
        bra.s   .snext
.fly:   addq.w  #1,d4
.snext: lea     sh_size(a1),a1
        lea     shots+nshots*sh_size(pc),a0
        cmpa.l  a0,a1
        blo.s   .shot
; --- the sight blinks while a shot is in flight, steady otherwise
        lea     nlive(pc),a0
        move.w  d4,(a0)
        lea     blink(pc),a0
        moveq   #col_green,d0
        tst.w   d4
        bne.s   .blk
        clr.w   (a0)
        bra.s   .sc
.blk:   addq.w  #1,(a0)
        cmp.w   #2*blink_b,(a0)
        blo.s   .ph
        clr.w   (a0)
.ph:    cmp.w   #blink_b,(a0)
        blo.s   .sc
        moveq   #0,d0               ; the off half
.sc:    lea     sight_col(pc),a0
        move.b  d0,(a0)
        rts

; ---------------------------------------------------------------- shot cast
; shot_cast: the first static entity a shot will hit, from where it is:
; each entity in near (inside the world box, from the last frame; the
; shot's whole path stays inside it) is taken into the shot's frame,
;   across = (wx*c - wz*s) >> 8,  along = (wx*s + wz*c) >> 8
; and the path enters its collision circle at about along - r (exact
; head-on, up to r early for a grazing pass; beats are shot_v = 80 units
; anyway). The nearest entry gives the beat j >= 1 the head reaches it,
; stored as the life the shot will have then (sh_hit = life - j, or 0 if
; it burns out first) with the entity (sh_tgt).
; In:      a1 = the shot
; Out:     sh_hit, sh_tgt of the shot
; Trashes: d0-d3, a0, a3, a5
shot_cast:
        move.w  #$7fff,d3           ; nearest entry so far
        lea     near(pc),a3
        move.w  (a3)+,d0
        lsl.w   #2,d0
        lea     (a3,d0.w),a0        ; a0 = end of the list
        move.l  a0,-(sp)
        bra.s   .cend
.cent:  move.l  (a3)+,a5
        tst.w   e_flags(a5)
        beq.s   .cend               ; gone
        move.w  e_x(a5),d0
        sub.w   sh_x(a1),d0
        lsl.w   #16-sector_sh,d0
        asr.w   #16-sector_sh,d0    ; wx (nearest image)
        move.w  e_z(a5),d1
        sub.w   sh_z(a1),d1
        lsl.w   #16-sector_sh,d1
        asr.w   #16-sector_sh,d1    ; wz
        move.w  sh_c(a1),d2
        muls.w  d0,d2               ; wx*c
        move.w  d1,-(sp)
        muls.w  sh_s(a1),d1         ; wz*s
        sub.l   d1,d2
        asr.l   #8,d2               ; across
        bpl.s   .ap
        neg.w   d2
.ap:    move.w  e_mesh(a5),d1
        lsl.w   #5,d1
        lea     objdir(pc),a0
        move.w  od_crad(a0,d1.w),d1 ; r
        cmp.w   d1,d2
        bgt.s   .miss               ; passes beside it
        muls.w  sh_s(a1),d0         ; wx*s
        move.w  (sp),d2
        muls.w  sh_c(a1),d2         ; wz*c
        add.l   d2,d0
        asr.l   #8,d0               ; along
        move.w  d0,d2
        add.w   d1,d2
        bmi.s   .miss               ; wholly behind the head
        sub.w   d1,d0               ; entry: along - r
        cmp.w   d3,d0
        bge.s   .miss
        move.w  d0,d3               ; the nearest so far
        move.l  a5,sh_tgt(a1)
.miss:  addq.l  #2,sp
.cend:  cmpa.l  (sp),a3
        blo.s   .cent
        addq.l  #4,sp
        clr.w   sh_hit(a1)
        cmp.w   #$7fff,d3
        beq.s   .none               ; nothing on its path
        move.w  d3,d0               ; the beat j the head gets there:
        ble.s   .j1                 ; already in: the next one
        ext.l   d0
        add.l   #shot_v-1,d0
        divu.w  #shot_v,d0          ; j = ceil(entry / shot_v)
        bra.s   .jj
.j1:    moveq   #1,d0
.jj:    move.w  sh_life(a1),d1
        sub.w   d0,d1               ; its life then
        bls.s   .none               ; <= 0: it burns out first
        move.w  d1,sh_hit(a1)
.none:  rts

; --------------------------------------------------------------- shots draw
; shots_draw: every live shot as a green segment from its head to its
; tail, gun_dy below the eye, with an erase box. Drawn only when both
; ends lie between the lattice's near and far planes inside the
; 90-degree view, so no clipping: a shot shows from its second beat or
; so, and burns out before zfar. The ends project through the lattice's
; reciprocal table (no divides): sx = 256 + (xc*invtab) >> 12, sy =
; horizon + (invtab*shot_ym) >> 16. Needs this frame's ocam (the object
; stage sets it).
; In:      d7 = back buffer index, a4 = back buffer base
; Out:     this buffer's box list extended, sight_hit[d7]
; Trashes: d0-d6, a0-a3, a5, a6
shots_draw:
        move.w  nlive(pc),d0        ; (no tst on pc-relative: 68020+)
        beq     .none
        lea     shots(pc),a5
.sh:    tst.w   sh_life(a5)
        beq     .next
        bsr     bbox_sel
        cmp.w   #maxobj,(a6)
        bge     .next               ; no erase box left: not drawn
        move.w  sh_x(a5),d0
        move.w  sh_z(a5),d1
        bsr     shot_proj           ; the head
        bcs     .next
        move.w  d0,d5
        move.w  d1,d6
        move.w  sh_x(a5),d0
        add.w   sh_tx(a5),d0
        move.w  sh_z(a5),d1
        add.w   sh_tz(a5),d1
        bsr     shot_proj           ; the tail
        bcs     .next
        move.w  d0,a2               ; a2, a3 = the tail; d5, d6 = the head
        move.w  d1,a3
        move.w  d5,d1               ; the box: min/max of the two ends
        cmp.w   d1,d0
        ble.s   .bx
        exg     d0,d1               ; d0 = minx, d1 = maxx
.bx:    move.w  a3,d2
        move.w  d6,d3
        cmp.w   d3,d2
        ble.s   .by
        exg     d2,d3               ; d2 = miny, d3 = maxy
.by:    bsr     box_add             ; keeps d5, d6, a2, a3, a5
        move.w  d5,d0
        move.w  d6,d1
        move.w  a2,d2
        move.w  a3,d3
        moveq   #col_green,d4
        bsr     draw_line
.next:  lea     sh_size(a5),a5
        lea     shots+nshots*sh_size(pc),a0
        cmpa.l  a0,a5
        blo     .sh
.none:  rts

; ---------------------------------------------------------------- shot proj
; shot_proj: a world point at gun height (gun_dy below the eye) onto the
; screen through the lattice's reciprocal table, for shots_draw.
; In:      d0.w = x, d1.w = z (world units), ocam = this frame's camera
; Out:     carry clear: d0.w = sx, d1.w = sy; carry set: the point lies
;          outside znear..zfar-1 or the 90-degree view (d0, d1 changed);
;          ccr
; Trashes: d2, d3, a0
shot_proj:
        sub.w   ocam+oc_px(pc),d0
        lsl.w   #16-sector_sh,d0
        asr.w   #16-sector_sh,d0    ; dx (nearest image)
        sub.w   ocam+oc_pz(pc),d1
        lsl.w   #16-sector_sh,d1
        asr.w   #16-sector_sh,d1    ; dz
        move.w  d0,d2
        muls.w  ocam+oc_c(pc),d2    ; dx*c
        move.w  d1,d3
        muls.w  ocam+oc_s(pc),d3    ; dz*s
        sub.l   d3,d2
        asr.l   #8,d2               ; xc
        muls.w  ocam+oc_c(pc),d1    ; dz*c
        muls.w  ocam+oc_s(pc),d0    ; dx*s
        add.l   d0,d1
        asr.l   #8,d1               ; zc
        cmp.w   #znear,d1
        blt.s   .off
        cmp.w   #zfar,d1
        bge.s   .off
        move.w  d2,d0
        bpl.s   .xp
        neg.w   d0
.xp:    cmp.w   d1,d0
        bge.s   .off                ; |xc| >= zc: outside the view
        lea     ds_base(pc),a0
        lea     invtab(a0),a0
        add.w   d1,d1
        move.w  (a0,d1.w),d3        ; xfocal*4096/zc
        muls.w  d3,d2
        asr.l   #8,d2
        asr.l   #4,d2
        add.w   #256,d2             ; sx
        mulu.w  #shot_ym,d3
        swap    d3
        add.w   #horizon,d3         ; sy
        move.w  d2,d0
        move.w  d3,d1               ; (move clears the carry)
        rts
.off:   ori     #1,ccr
        rts
