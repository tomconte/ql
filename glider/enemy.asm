; enemy.asm -- glider: the enemy gliders (spec 6, 7): their AI and
; flight, one step per beat, their bumps with the craft, launching
; them; the enemy shots. Included by glider.asm.

; ------------------------------------------------------------- gliders step
; gliders_step: one beat of every live glider: its gun's cooldown and
; its phase clock, its AI every gt_think beats (glider_think: the turn
; and thrust keys it holds until the next think, and its shots), a beat
; of the section-4 model with its type's constants (glider_fly), a
; contact with the craft (glider_bump), and its entity following it.
; In:      none
; Out:     glpool and the gliders' entities (e_x, e_z, e_head); enemy
;          shots fired (eshots, nelive); the craft (bumped), shield,
;          shield_chg, hurt_t, sight_col
; Trashes: d0-d4, a0-a3, a5
gliders_step:
        lea     glpool(pc),a0
.gl:    move.l  g_ent(a0),a5
        tst.w   e_flags(a5)
        beq.s   .next               ; a free slot
        move.l  g_type(a0),a2
        tst.w   g_fire(a0)
        beq.s   .f0
        subq.w  #1,g_fire(a0)       ; the gun's cooldown
.f0:    addq.w  #1,g_mode(a0)       ; the phase clock (the wedge's orbit)
        cmp.w   #orbit_b+attack_b,g_mode(a0)
        blo.s   .m0
        clr.w   g_mode(a0)
.m0:    subq.w  #1,g_think(a0)
        bne.s   .fly
        move.w  gt_think(a2),g_think(a0)
        bsr     glider_think
.fly:   lea     sintab(pc),a1
        bsr     glider_fly
        bsr     glider_bump
        move.w  g_x(a0),e_x(a5)     ; the entity follows
        move.w  g_z(a0),e_z(a5)
        move.w  g_head(a0),e_head(a5)
.next:  lea     g_size(a0),a0
        lea     glpool+ngl*g_size(pc),a1
        cmpa.l  a1,a0
        blo.s   .gl
        rts

; ------------------------------------------------------------- glider think
; glider_think: the AI's decision for the next gt_think beats. The
; player is taken into the glider's frame (forward = (s, c), right =
; (c, -s), the vector to it wrapped to its nearest image),
;   fwd = (dx*s + dz*c) >> 8,  rgt = (dx*c - dz*s) >> 8,
; with the range ~ max(|dx|, |dz|) + min/2. The glider turns toward
; the player until the aim error across is within deadw (inside
; gt_swerve it aims gt_aimoff beside it instead, to pass: the dart),
; and thrusts beyond gt_hold. A glider with gt_orbit, inside its range
; + orbit_m for the first orbit_b beats of every orbit_b + attack_b,
; holds the player abeam on its right at full thrust (the wedge circles
; it, then turns in). It fires when the player is ahead within
; gt_frange and within firew across its nose: gt_burst shots gt_bgap
; beats apart, then gt_fcd beats of cooldown (all enemy shots in
; flight: it tries again at the next think).
; In:      a0 = the glider, a2 = its type
; Out:     g_dir, g_thr, g_fire, g_burst; an enemy shot fired (eshots,
;          nelive)
; Trashes: d0-d4, a1, a3
glider_think:
        move.l  craft+c_px(pc),d0
        lsr.l   #8,d0
        sub.w   g_x(a0),d0
        lsl.w   #16-sector_sh,d0
        asr.w   #16-sector_sh,d0    ; dx = player - glider (nearest image)
        move.l  craft+c_pz(pc),d1
        lsr.l   #8,d1
        sub.w   g_z(a0),d1
        lsl.w   #16-sector_sh,d1
        asr.w   #16-sector_sh,d1    ; dz
        move.w  d0,d3               ; the range: max + min/2
        bpl.s   .ax
        neg.w   d3
.ax:    move.w  d1,d4
        bpl.s   .az
        neg.w   d4
.az:    cmp.w   d4,d3
        bhs.s   .mx
        exg     d3,d4
.mx:    lsr.w   #1,d4
        add.w   d4,d3               ; d3 = range
        move.w  d0,d2
        muls.w  g_s(a0),d2          ; dx*s
        move.w  d1,d4
        muls.w  g_c(a0),d4          ; dz*c
        add.l   d4,d2
        asr.l   #8,d2               ; d2 = fwd
        muls.w  g_c(a0),d0          ; dx*c
        muls.w  g_s(a0),d1          ; dz*s
        sub.l   d1,d0
        asr.l   #8,d0               ; d0 = rgt
; --- steering: the orbit phase, else seek
        tst.w   gt_orbit(a2)
        beq.s   .seek
        cmp.w   #orbit_b,g_mode(a0)
        bhs.s   .seek               ; the attack phase
        move.w  gt_hold(a2),d1
        add.w   #orbit_m,d1
        cmp.w   d1,d3
        bhs.s   .seek               ; out of its range: close in first
        moveq   #1,d1               ; the player abeam on the right:
        tst.w   d2                  ; behind it, turn right,
        ble.s   .orb
        moveq   #-1,d1              ; ahead, turn left (away)
.orb:   move.w  d1,g_dir(a0)
        move.w  #1,g_thr(a0)
        bra.s   .fire
.seek:  move.w  d0,d1               ; d1 = the aim error: rgt
        tst.w   d2
        ble.s   .turn               ; behind: turn toward it
        cmp.w   gt_swerve(a2),d2
        bge.s   .aim
        sub.w   gt_aimoff(a2),d1    ; inside gt_swerve: aim to pass
        tst.w   d0                  ; gt_aimoff beside it
        bpl.s   .aim
        add.w   gt_aimoff(a2),d1
        add.w   gt_aimoff(a2),d1
.aim:   move.w  d1,d4
        bpl.s   .aa
        neg.w   d4
.aa:    cmp.w   #deadw,d4
        bgt.s   .turn
        clr.w   g_dir(a0)           ; on target: no turn
        bra.s   .thr
.turn:  moveq   #1,d4               ; toward the side of the error
        tst.w   d1
        bpl.s   .tr
        moveq   #-1,d4
.tr:    move.w  d4,g_dir(a0)
.thr:   clr.w   g_thr(a0)
        cmp.w   gt_hold(a2),d3
        bls.s   .fire               ; inside its hold range: coast
        move.w  #1,g_thr(a0)
; --- fire
.fire:  tst.w   g_fire(a0)
        bne.s   .done               ; cooling down
        tst.w   g_burst(a0)
        bne.s   .shoot              ; a burst under way
        tst.w   d2
        ble.s   .done               ; behind it
        cmp.w   gt_frange(a2),d2
        bgt.s   .done               ; out of range
        tst.w   d0
        bpl.s   .fp
        neg.w   d0
.fp:    cmp.w   #firew,d0
        bgt.s   .done               ; off its nose
        move.w  gt_burst(a2),g_burst(a0)
.shoot: bsr     eshot_fire
        bcs.s   .done               ; none free: the next think
        subq.w  #1,g_burst(a0)
        move.w  gt_fcd(a2),g_fire(a0)
        tst.w   g_burst(a0)
        beq.s   .done
        move.w  gt_bgap(a2),g_fire(a0)  ; the burst's next shot
.done:  rts

; --------------------------------------------------------------- glider fly
; glider_fly: one beat of the section-4 model with the type's constants
; and the AI's keys (g_dir, g_thr): the turn ramps from gt_tmin by
; gt_tramp up to gt_tmax while held and resets on release; the trig and
; the thrust vector change only with the heading; thrust, drag (the
; drift), the move wrapped into the sector. No brake, reverse or speed
; cap: the AI uses none of them, and the terminal speed (thrust <<
; drag_shift) stays under vmax.
; In:      a0 = the glider, a1 = sintab, a2 = its type
; Out:     the glider stepped
; Trashes: d0-d2
glider_fly:
        move.w  g_dir(a0),d1
        beq.s   .trel
        move.w  g_turn(a0),d0
        bne.s   .ramp
        move.w  gt_tmin(a2),d0      ; a turn starts
        bra.s   .tapp
.ramp:  add.w   gt_tramp(a2),d0
        cmp.w   gt_tmax(a2),d0
        ble.s   .tapp
        move.w  gt_tmax(a2),d0
.tapp:  move.w  d0,g_turn(a0)
        tst.w   d1
        bpl.s   .trt
        neg.w   d0
.trt:   add.w   d0,g_head(a0)       ; Right increases the heading
        bsr     glider_trig
        bra.s   .thr
.trel:  clr.w   g_turn(a0)
.thr:   move.w  g_vx(a0),d0
        move.w  g_vz(a0),d1
        tst.w   g_thr(a0)
        beq.s   .drag
        add.w   g_tx(a0),d0
        add.w   g_tz(a0),d1
.drag:  move.w  d0,d2               ; v -= v >> drag_shift
        asr.w   #drag_shift,d2
        sub.w   d2,d0
        move.w  d0,g_vx(a0)
        move.w  d1,d2
        asr.w   #drag_shift,d2
        sub.w   d2,d1
        move.w  d1,g_vz(a0)
        ext.l   d0                  ; the move: 8.8 into the 16.16 position,
        asl.l   #8,d0               ; the integer word wrapped
        add.l   d0,g_x(a0)
        andi.w  #sector-1,g_x(a0)
        ext.l   d1
        asl.l   #8,d1
        add.l   d1,g_z(a0)
        andi.w  #sector-1,g_z(a0)
        rts

; -------------------------------------------------------------- glider trig
; glider_trig: sin and cos of the glider's heading, and its thrust
; vector (gt_thrust along them).
; In:      a0 = the glider, a1 = sintab, a2 = its type
; Out:     g_s, g_c, g_tx, g_tz
; Trashes: d0, d2
glider_trig:
        move.w  g_head(a0),d0
        lsr.w   #8,d0               ; integer brad
        add.w   d0,d0
        move.w  (a1,d0.w),d2
        move.w  d2,g_s(a0)          ; s
        muls.w  gt_thrust(a2),d2
        asr.l   #8,d2
        move.w  d2,g_tx(a0)
        add.w   #128,d0             ; cos = sin(a + 64)
        and.w   #511,d0
        move.w  (a1,d0.w),d2
        move.w  d2,g_c(a0)          ; c
        muls.w  gt_thrust(a2),d2
        asr.l   #8,d2
        move.w  d2,g_tz(a0)
        rts

; -------------------------------------------------------------- glider bump
; glider_bump: the glider against the craft, both moved this beat (spec
; 7): a box reject, then |d|^2 < (g_crad + craft_r)^2 with d = craft -
; glider. In contact and closing, the bodies swap the normal component
; of their relative velocity w (equal masses: v_craft -= t d, v_glider
; += t d, t = w.d/d.d), both velocities are halved and both moves undone,
; so neither stays inside the other. A bump of bump_v or more along the
; normal costs 1 shield, as a wall does (once in hurt_b beats). A deep
; overlap (|d| under 32: a glider launched onto the craft) only undoes
; the moves: the divide needs d.d >= 64.
; In:      a0 = the glider
; Out:     the glider and the craft (velocity, position), shield,
;          shield_chg, hurt_t, sight_col
; Trashes: d0-d4, a1, a3
glider_bump:
        move.w  g_crad(a0),d2
        add.w   #craft_r,d2         ; d2 = R: the contact distance
        move.l  craft+c_px(pc),d0
        lsr.l   #8,d0
        sub.w   g_x(a0),d0
        lsl.w   #16-sector_sh,d0
        asr.w   #16-sector_sh,d0    ; dx = craft - glider (nearest image)
        move.w  d0,d3
        bpl.s   .x
        neg.w   d3
.x:     cmp.w   d2,d3
        bge     .none
        move.l  craft+c_pz(pc),d1
        lsr.l   #8,d1
        sub.w   g_z(a0),d1
        lsl.w   #16-sector_sh,d1
        asr.w   #16-sector_sh,d1    ; dz
        move.w  d1,d3
        bpl.s   .z
        neg.w   d3
.z:     cmp.w   d2,d3
        bge     .none
        move.w  d0,d3
        muls.w  d3,d3
        move.w  d1,d4
        muls.w  d4,d4
        add.l   d4,d3               ; |d|^2
        mulu.w  d2,d2               ; R^2
        cmp.l   d2,d3
        bge     .none               ; outside the circle
; --- contact: d scaled by 1/4 (so d.d fits a divisor), w = v_craft -
; v_glider (8.8)
        asr.w   #2,d0
        asr.w   #2,d1
        lea     craft(pc),a1
        move.w  c_vx(a1),d3
        sub.w   g_vx(a0),d3
        muls.w  d0,d3
        move.w  c_vz(a1),d4
        sub.w   g_vz(a0),d4
        muls.w  d1,d4
        add.l   d4,d3               ; w.d
        bpl     .none               ; parting, or sliding past: let them
        move.w  g_crad(a0),d2       ; a bump? |w.d| >= bump_v * |d|, with
        add.w   #craft_r,d2         ; |d| ~ R/4 at contact (scaled d)
        mulu.w  #bump_v*64,d2       ; bump_v * 256 (8.8) * R/4
        move.l  d3,d4
        neg.l   d4
        cmp.l   d2,d4
        blt.s   .push               ; a push, not a bump
        lea     hurt_t(pc),a3
        tst.w   (a3)
        bne.s   .push               ; hurt just now: no more damage
        moveq   #-1,d2
        bsr     shield_add          ; (keeps d0, d1, d3, a1)
.push:  move.w  d0,d4
        muls.w  d4,d4
        move.w  d1,d2
        muls.w  d2,d2
        add.l   d2,d4               ; d.d
        cmp.l   #64,d4
        blt.s   .undo               ; a deep overlap: no push
        divs.w  d4,d3               ; t = w.d/d.d
        muls.w  d3,d0               ; t dx (8.8)
        muls.w  d3,d1               ; t dz
        move.w  c_vx(a1),d2         ; the craft: (v - t d) / 2
        ext.l   d2
        sub.l   d0,d2
        asr.l   #1,d2
        move.w  d2,c_vx(a1)
        move.w  c_vz(a1),d2
        ext.l   d2
        sub.l   d1,d2
        asr.l   #1,d2
        move.w  d2,c_vz(a1)
.undo:  move.l  c_ox(a1),c_px(a1)   ; undo the craft's move,
        move.l  c_oz(a1),c_pz(a1)
        move.w  g_vx(a0),d2         ; the glider's (the velocity it moved by)
        ext.l   d2
        asl.l   #8,d2
        sub.l   d2,g_x(a0)
        andi.w  #sector-1,g_x(a0)
        move.w  g_vz(a0),d2
        ext.l   d2
        asl.l   #8,d2
        sub.l   d2,g_z(a0)
        andi.w  #sector-1,g_z(a0)
        cmp.l   #64,d4
        blt.s   .none               ; (a deep overlap: velocities kept)
        move.w  g_vx(a0),d2         ; the glider: (v + t d) / 2
        ext.l   d2
        add.l   d0,d2
        asr.l   #1,d2
        move.w  d2,g_vx(a0)
        move.w  g_vz(a0),d2
        ext.l   d2
        add.l   d1,d2
        asr.l   #1,d2
        move.w  d2,g_vz(a0)
.none:  rts

; ------------------------------------------------------------ glider launch
; glider_launch: a glider of type a2 in the first free slot, at rest at
; (d0, d1) heading d2, its first shot gl_wait beats away, its think
; phase alternating with the previous launch's.
; In:      d0.w = x, d1.w = z (world units), d2.w = heading (8.8
;          brads), a2 = its type, a3 = the generator launching it (0:
;          none)
; Out:     carry clear: a0 = the glider, its entity live; carry set: no
;          free slot (a0 changed); ccr
; Trashes: d0-d2, a1, a5
glider_launch:
        lea     glpool(pc),a0
.f:     move.l  g_ent(a0),a5
        tst.w   e_flags(a5)
        beq.s   .got
        lea     g_size(a0),a0
        lea     glpool+ngl*g_size(pc),a1
        cmpa.l  a1,a0
        blo.s   .f
        ori     #1,ccr              ; all ngl are flying
        rts
.got:   and.w   #sector-1,d0
        and.w   #sector-1,d1
        move.w  d0,g_x(a0)
        clr.w   g_x+2(a0)
        move.w  d1,g_z(a0)
        clr.w   g_z+2(a0)
        move.w  d2,g_head(a0)
        clr.w   g_turn(a0)
        clr.w   g_vx(a0)
        clr.w   g_vz(a0)
        move.l  a2,g_type(a0)
        move.l  a3,g_gen(a0)
        clr.w   g_dir(a0)
        clr.w   g_thr(a0)
        lea     gl_phase(pc),a1
        eori.w  #3,(a1)             ; 1, 2, 1, ...
        move.w  (a1),g_think(a0)
        move.w  #gl_wait,g_fire(a0)
        clr.w   g_mode(a0)
        clr.w   g_burst(a0)
        move.w  d0,e_x(a5)          ; the entity
        move.w  d1,e_z(a5)
        move.w  #gl_y,e_y(a5)
        move.w  d2,e_head(a5)
        clr.w   e_hp(a5)
        clr.w   e_tmr(a5)
        move.w  gt_mesh(a2),d0
        move.w  d0,e_mesh(a5)
        lsl.w   #5,d0
        lea     objdir(pc),a1
        move.w  od_crad(a1,d0.w),g_crad(a0)
        lea     sintab(pc),a1
        bsr     glider_trig
        move.w  #1,e_flags(a5)      ; live (the move clears the carry)
        rts

; --------------------------------------------------------------- eshot fire
; eshot_fire: an enemy shot from the glider's nose (eshot_nose ahead of
; its centre) along its heading, eshot_v units a beat for eshot_life
; beats, red; the static entity it will stop at is cast at launch
; (shot_cast), as for the player's shots.
; In:      a0 = the glider
; Out:     carry clear: a shot fired (eshots, nelive); carry set: all
;          neshots in flight; ccr
; Trashes: d0-d3, a1, a3
eshot_fire:
        lea     eshots(pc),a1
        lea     neshots*sh_size(a1),a3
.free:  tst.w   sh_life(a1)
        beq.s   .got
        lea     sh_size(a1),a1
        cmpa.l  a3,a1
        blo.s   .free
        ori     #1,ccr
        rts
.got:   move.w  g_s(a0),d1          ; s
        move.w  g_c(a0),d2          ; c
        move.w  d1,sh_s(a1)
        move.w  d2,sh_c(a1)
        move.w  d1,d3
        muls.w  #eshot_v,d3
        asr.l   #8,d3
        move.w  d3,sh_vx(a1)        ; velocity: eshot_v along the heading
        move.w  d2,d3
        muls.w  #eshot_v,d3
        asr.l   #8,d3
        move.w  d3,sh_vz(a1)
        move.w  d1,d3
        muls.w  #-eshot_len,d3
        asr.l   #8,d3
        move.w  d3,sh_tx(a1)        ; head to tail: eshot_len back
        move.w  d2,d3
        muls.w  #-eshot_len,d3
        asr.l   #8,d3
        move.w  d3,sh_tz(a1)
        muls.w  #eshot_nose,d1
        asr.l   #8,d1
        add.w   g_x(a0),d1
        move.w  d1,sh_x(a1)         ; the head starts at the nose
        muls.w  #eshot_nose,d2
        asr.l   #8,d2
        add.w   g_z(a0),d2
        move.w  d2,sh_z(a1)
        move.w  #eshot_life,sh_life(a1)
        move.w  #eshot_v,sh_v(a1)
        lea     nelive(pc),a3
        addq.w  #1,(a3)
        movem.l a0/a5,-(sp)
        bsr     shot_cast
        movem.l (sp)+,a0/a5
        move.w  #col_red,sh_col(a1) ; (the move clears the carry: fired)
        rts

; -------------------------------------------------------------- eshots step
; eshots_step: one beat of the enemy shots: each ages and moves, then
; hits the craft if its head swept it this beat -- in the shot's frame,
; with w = craft - head, across = (wx*c - wz*s) >> 8 within craft_r and
; along = (wx*s + wz*c) >> 8 between the head's last position and
; craft_r ahead of it (a box for the capsule, after a box reject) -- or
; stops at the static entity cast at launch (a new cast when that one
; went). A hit costs 1 shield and stops the shot.
; In:      none
; Out:     eshots, nelive; shield, shield_chg, hurt_t, sight_col
; Trashes: d0-d4, a0, a1, a3, a5
eshots_step:
        move.w  nelive(pc),d0
        beq     .none
        lea     eshots(pc),a1
        moveq   #0,d4               ; in flight after this beat
.sh:    tst.w   sh_life(a1)
        beq     .next
        subq.w  #1,sh_life(a1)
        beq     .next               ; burnt out
        move.w  sh_vx(a1),d0
        add.w   d0,sh_x(a1)
        move.w  sh_vz(a1),d0
        add.w   d0,sh_z(a1)
        move.l  craft+c_px(pc),d0
        lsr.l   #8,d0
        sub.w   sh_x(a1),d0
        lsl.w   #16-sector_sh,d0
        asr.w   #16-sector_sh,d0    ; wx = craft - head (nearest image)
        move.w  d0,d2
        bpl.s   .x
        neg.w   d2
.x:     cmp.w   #eshot_v+craft_r,d2
        bge.s   .miss
        move.l  craft+c_pz(pc),d1
        lsr.l   #8,d1
        sub.w   sh_z(a1),d1
        lsl.w   #16-sector_sh,d1
        asr.w   #16-sector_sh,d1    ; wz
        move.w  d1,d2
        bpl.s   .z
        neg.w   d2
.z:     cmp.w   #eshot_v+craft_r,d2
        bge.s   .miss
        move.w  d0,d2
        muls.w  sh_c(a1),d2         ; wx*c
        move.w  d1,d3
        muls.w  sh_s(a1),d3         ; wz*s
        sub.l   d3,d2
        asr.l   #8,d2               ; across
        bpl.s   .ac
        neg.w   d2
.ac:    cmp.w   #craft_r,d2
        bge.s   .miss
        muls.w  sh_s(a1),d0         ; wx*s
        muls.w  sh_c(a1),d1         ; wz*c
        add.l   d1,d0
        asr.l   #8,d0               ; along: the craft ahead of the head
        cmp.w   #craft_r,d0
        bge.s   .miss               ; not reached yet
        cmp.w   #-eshot_v-craft_r,d0
        ble.s   .miss               ; passed it before this beat
        clr.w   sh_life(a1)         ; a hit: the shot stops,
        moveq   #-1,d2              ; the craft loses 1
        bsr     shield_add
        bra.s   .next
.miss:  move.w  sh_life(a1),d0      ; at the cast entity?
        cmp.w   sh_hit(a1),d0
        bne.s   .fly
        move.l  sh_tgt(a1),a5
        tst.w   e_flags(a5)
        beq.s   .cast
        clr.w   sh_life(a1)         ; stopped by it
        bra.s   .next
.cast:  bsr     shot_cast           ; it went: what is behind it?
.fly:   addq.w  #1,d4
.next:  lea     sh_size(a1),a1
        lea     eshots+neshots*sh_size(pc),a0
        cmpa.l  a0,a1
        blo     .sh
        lea     nelive(pc),a0
        move.w  d4,(a0)
.none:  rts

; ------------------------------------------------------------------ gl test
; gl_test: the test rig's gliders (test_gl), until the generators launch
; them: a dart, a wedge and a kite 2200..2600 ahead of the spawn (taken
; as looking along +z), facing it.
; In:      none
; Out:     three gliders launched (glpool, their entities)
; Trashes: d0-d2, a0-a3, a5
gl_test:
        suba.l  a3,a3               ; no generator
        move.w  #spawn_x-700,d0
        move.w  #spawn_z+2200,d1
        move.w  #(spawn_head+(128<<8))&$ffff,d2
        lea     gt_dart(pc),a2
        bsr     glider_launch
        move.w  #spawn_x,d0
        move.w  #spawn_z+2600,d1
        move.w  #(spawn_head+(128<<8))&$ffff,d2
        lea     gt_wedge(pc),a2
        bsr     glider_launch
        move.w  #spawn_x+700,d0
        move.w  #spawn_z+2200,d1
        move.w  #(spawn_head+(128<<8))&$ffff,d2
        lea     gt_kite(pc),a2
        bra     glider_launch       ; tail call
