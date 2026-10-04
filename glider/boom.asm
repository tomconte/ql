; boom.asm -- glider: explosions (spec 5.6): dot sparks from the bursts
; tools/gensparks.py precomputes (sparks.inc). Included by glider.asm.

; ---------------------------------------------------------------- boom add
; boom_add: an explosion where an entity has just gone (spec 5.6): its
; mesh's burst (od_spk: one per centre height) in its colour, and its
; sound (a generator's the deeper one).
; In:      a5 = the entity
; Out:     booms, nbooms, boom_mir, sfx_want
; Trashes: d0, a3
boom_add:
        cmp.w   #msh_gen,e_mesh(a5)
        bne.s   .small
        sfx     sfx_big
        bra.s   .snd
.small: sfx     sfx_boom
.snd:   move.l  a0,-(sp)
        move.w  e_mesh(a5),d0
        lsl.w   #5,d0
        lea     objdir(pc),a0
        move.w  od_spk(a0,d0.w),d0
        lea     sparks(pc),a0
        adda.w  d0,a0
        bsr.s   boom_put
        move.l  (sp)+,a0
        rts

; ---------------------------------------------------------------- boom hit
; boom_hit: a puff of 4 sparks where a shot hit an entity without
; destroying it (spec 5.6), in its colour, and the hit sound.
; In:      a5 = the entity
; Out:     booms, nbooms, boom_mir, sfx_want
; Trashes: d0, a3
boom_hit:
        sfx     sfx_hit
        move.l  a0,-(sp)
        lea     spk_hit(pc),a0
        bsr.s   boom_put
        move.l  (sp)+,a0
        rts

; ---------------------------------------------------------------- boom put
; boom_put: an explosion record for the entity with burst a0, at its
; centre in its mesh's colour, mirrored on every other one for variety.
; With all nboom records busy the first is reused.
; In:      a0 = the burst (sparks.inc), a5 = the entity
; Out:     booms, nbooms, boom_mir
; Trashes: d0, a3
boom_put:
        move.l  a1,-(sp)
        lea     booms(pc),a3
        lea     nboom*bm_size(a3),a1
.f:     tst.w   bm_live(a3)
        beq.s   .got
        lea     bm_size(a3),a3
        cmpa.l  a1,a3
        blo.s   .f
        lea     booms(pc),a3        ; all busy: the first goes
        bra.s   .set
.got:   lea     nbooms(pc),a1
        addq.w  #1,(a1)
.set:   move.w  #spk_life,bm_live(a3)
        move.w  e_x(a5),bm_x(a3)
        move.w  e_z(a5),bm_z(a3)
        move.w  e_y(a5),bm_y(a3)
        move.w  e_mesh(a5),d0
        lsl.w   #5,d0
        lea     objdir(pc),a1
        move.w  od_col(a1,d0.w),bm_col(a3)
        move.l  a0,bm_pat(a3)
        lea     boom_mir(pc),a1
        not.w   (a1)
        move.w  (a1),bm_mir(a3)
        move.l  (sp)+,a1
        rts

; --------------------------------------------------------------- boom draw
; boom_draw: the explosions (spec 5.6). Each ages by the beats of this
; loop's simulation (headroom+16) and goes after spk_life beats; the
; rest are drawn: the centre into camera space and on screen, its scale
; per world unit at that depth (kx = xfocal*256/zc, ky likewise: two
; divides an explosion), then the live sparks of the burst's row for its
; age at centre + offset * scale -- two multiplies a spark and no
; rotation (a burst is isotropic) -- a pixel per colour plane, appended
; to the dot list where it turned a pixel on. A burst wholly inside the
; play area (its extent, from the pattern header) skips the per-spark
; bounds. Drawn after the sight, so a spark never records, and never
; erases, a sight pixel.
; In:      d7 = back buffer index, a4 = back buffer base, the dot list
;          open, ocam (this frame's camera)
; Out:     booms aged (nbooms), the sparks appended (dl_next, count)
; Trashes: d0-d6, a0-a3, a5, a6
boom_draw:
        move.w  nbooms(pc),d0
        beq     .none
        lea     booms(pc),a5
.bm:    move.w  bm_live(a5),d0
        beq     .next
        sub.w   headroom+16(pc),d0  ; age by the loop's beats
        bgt.s   .alive
        clr.w   bm_live(a5)         ; burnt out
        lea     nbooms(pc),a0
        subq.w  #1,(a0)
        bra     .next
.alive: move.w  d0,bm_live(a5)
        move.w  bm_x(a5),d0         ; the centre in camera space (spec 5.1)
        sub.w   ocam+oc_px(pc),d0
        lsl.w   #16-sector_sh,d0
        asr.w   #16-sector_sh,d0    ; dx (nearest image)
        move.w  bm_z(a5),d1
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
        cmp.w   #znear_o,d1
        blt     .next               ; behind, or too close
        move.w  d2,d0
        bpl.s   .xa
        neg.w   d0
.xa:    sub.w   d1,d0
        cmp.w   #256,d0
        bgt     .next               ; |xc| > zc + 256: no spark can show
        move.l  #xfocal<<8,d3
        divu.w  d1,d3               ; d3 = kx: pixels per world unit, 8.8
        move.l  #yfocal<<8,d6
        divu.w  d1,d6               ; d6 = ky: rows per world unit
        move.w  d2,d4
        muls.w  d3,d4
        asr.l   #8,d4
        add.w   #256,d4             ; d4 = centre x
        move.w  #cam_h,d5
        sub.w   bm_y(a5),d5         ; yc
        muls.w  d6,d5
        asr.l   #8,d5
        add.w   #horizon,d5         ; d5 = centre y
        move.l  bm_pat(a5),a0       ; the burst's row for its age: the
        move.w  #spk_life,d0        ; live sparks, as (x, y) pairs
        sub.w   bm_live(a5),d0      ; age (>= 1)
        add.w   d0,d0
        move.w  spx_rows(a0,d0.w),d0
        lea     (a0,d0.w),a6
        moveq   #0,d0
        move.b  (a6)+,d0            ; how many
        beq     .next
        add.w   d0,d0
        lea     (a6,d0.w),a2        ; a2 = past the last pair
        move.l  dl_next(pc),a1
; wholly inside the play area? (offsets are in units of spk_scale = 2,
; hence the >> 7)
        move.w  spx_xm(a0),d0
        mulu.w  d3,d0
        lsr.l   #7,d0               ; half-width in pixels
        move.w  d4,d1
        sub.w   d0,d1
        bmi.s   .slow               ; past the left edge
        add.w   d4,d0
        cmp.w   #511,d0
        bgt.s   .slow               ; past the right one
        move.w  spx_y0(a0),d0
        muls.w  d6,d0
        asr.l   #7,d0
        add.w   d5,d0
        cmp.w   #playtop,d0
        blt.s   .slow               ; into the top strip
        move.w  spx_y1(a0),d0
        muls.w  d6,d0
        asr.l   #7,d0
        add.w   d5,d0
        cmp.w   #playbot,d0
        bgt.s   .slow               ; into the bottom band
        bsr     .kxy
        suba.l  a3,a3               ; the green plane
        btst    #1,bm_col+1(a5)
        beq.s   .fr
        bsr     .fast
.fr:    btst    #0,bm_col+1(a5)
        beq.s   .tail
        move.w  #1,a3               ; the red plane (white: both)
        bsr     .fast
        bra.s   .tail
.slow:  bsr.s   .kxy
        suba.l  a3,a3
        btst    #1,bm_col+1(a5)
        beq.s   .sr
        bsr     .slw
.sr:    btst    #0,bm_col+1(a5)
        beq.s   .tail
        move.w  #1,a3
        bsr     .slw
.tail:  move.l  a1,d0               ; the records into the count
        sub.l   dl_next(pc),d0
        lsr.w   #2,d0
        move.l  dl_base(pc),a0
        add.w   d0,(a0)
        lea     dl_next(pc),a0
        move.l  a1,(a0)
.next:  lea     bm_size(a5),a5
        lea     booms+nboom*bm_size(pc),a0
        cmpa.l  a0,a5
        blo     .bm
.none:  rts
; .kxy: d2 = kx (negated for a mirrored burst), d3 = ky. Trashes none.
.kxy:   move.w  d3,d2
        tst.w   bm_mir(a5)
        beq.s   .nm
        neg.w   d2
.nm:    move.w  d6,d3
        rts
; .fast: the row's sparks (a6 .. a2) in plane a3 at x = d4 + (ox*d2) >>
; 7, y = d5 + (oy*d3) >> 7, all on screen; recorded at (a1)+ when bset
; turned the pixel on. No room for a whole row (4 bytes a spark, its
; pair 2): nothing. Trashes d0, d1, d6, a0.
.fast:  move.l  a2,d0
        sub.l   a6,d0
        add.l   d0,d0
        add.l   a1,d0
        cmp.l   dl_end(pc),d0
        bhi.s   .fx                 ; the list is full
        move.l  a6,a0
.fs:    move.b  (a0)+,d0
        ext.w   d0
        muls.w  d2,d0
        asr.l   #7,d0
        add.w   d4,d0               ; x
        move.b  (a0)+,d1
        ext.w   d1
        muls.w  d3,d1
        asr.l   #7,d1
        add.w   d5,d1               ; y
        lsl.w   #7,d1               ; row offset
        move.w  d0,d6
        lsr.w   #3,d6
        add.w   d6,d1
        add.w   d6,d1               ; + (x>>3)*2: the green byte
        add.w   a3,d1               ; the plane's byte
        not.w   d0
        and.w   #7,d0               ; bit number: 7 - (x & 7)
        bset    d0,(a4,d1.w)
        bne.s   .fn                 ; on already: not ours to erase
        move.w  d1,(a1)+            ; record: offset,
        moveq   #-1,d6
        bclr    d0,d6
        move.w  d6,(a1)+            ;   inverse mask
.fn:    cmpa.l  a2,a0
        blo.s   .fs
.fx:    rts
; .slw: .fast with the bounds: a spark outside the play area is skipped.
.slw:   move.l  a2,d0
        sub.l   a6,d0
        add.l   d0,d0
        add.l   a1,d0
        cmp.l   dl_end(pc),d0
        bhi.s   .sx
        move.l  a6,a0
.ss:    move.b  (a0)+,d0
        move.b  (a0)+,d1
        ext.w   d0
        muls.w  d2,d0
        asr.l   #7,d0
        add.w   d4,d0               ; x
        cmp.w   #511,d0
        bhi.s   .sn                 ; off the sides
        ext.w   d1
        muls.w  d3,d1
        asr.l   #7,d1
        add.w   d5,d1               ; y
        cmp.w   #playtop,d1
        blt.s   .sn
        cmp.w   #playbot,d1
        bgt.s   .sn
        lsl.w   #7,d1
        move.w  d0,d6
        lsr.w   #3,d6
        add.w   d6,d1
        add.w   d6,d1
        add.w   a3,d1
        not.w   d0
        and.w   #7,d0
        bset    d0,(a4,d1.w)
        bne.s   .sn
        move.w  d1,(a1)+
        moveq   #-1,d6
        bclr    d0,d6
        move.w  d6,(a1)+
.sn:    cmpa.l  a2,a0
        blo.s   .ss
.sx:    rts
