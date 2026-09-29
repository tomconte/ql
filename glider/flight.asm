; flight.asm -- glider: the section-4 flight model (one beat step) and
; the craft reset. Included by glider.asm.

; --------------------------------------------------------------- flight step
; flight_step: one beat of the section-4 model.
; In:      a0 = craft, a1 = sintab, d5.b = held keys (row-1 bits)
; Out:     the craft record stepped
; Trashes: d0-d4
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
; --- position, wrapped into the sector (spec 6): 0..sector-1, 16.8
        ext.l   d0
        add.l   d0,c_px(a0)
        andi.l  #(sector<<8)-1,c_px(a0)
        ext.l   d1
        add.l   d1,c_pz(a0)
        andi.l  #(sector<<8)-1,c_pz(a0)
        rts

; -------------------------------------------------------------- craft reset
; craft_reset: spawn between four lattice points, looking along +z, at
; rest.
; In:      none
; Out:     a0 = craft, the record reset
; Trashes: none
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
