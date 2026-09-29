; macros.inc -- glider: macros of the frame loop (included after
; equates.inc, before the first use).

; wbound: narrow the row's cell range [d4,d5] with the half-plane test
; whose record (DF.l, (2*nwin)*DF.l, DF>>16.w, pad) is at (a0), for
; f(t) = d0 + t*DF over t = 0..2*nwin; branches to \1 when no cell of
; the row passes. All/none come exactly from f at both row ends; a
; crossing is bounded by one divide on the integer parts with a 2-cell
; margin (error under 1/16 at the |DF>>16| >= 16 threshold; flatter
; slopes stay unbounded and the per-cell tests sort them out).
; In:      d0.l = f(0) (16.16), d4/d5 = cell range lo/hi, a0 = record
; Out:     d4/d5 narrowed and a0 = next record (+12); or the branch to
;          \1, a0 not advanced
; Trashes: d0, d1, d6
wbound  macro
        move.l  (a0),d1             ; DF
        bmi.s   .wn\@
        beq.s   .wz\@
        tst.l   d0                  ; DF > 0: f rises along the row
        bge.s   .wx\@               ; f(0) >= 0: all pass
        move.l  d0,d6
        add.l   4(a0),d6            ; f(2*nwin)
        bmi     \1                  ; < 0: none pass
        move.w  8(a0),d1            ; DF>>16
        cmp.w   #16,d1
        blt.s   .wx\@               ; too flat to bound
        neg.l   d0
        swap    d0
        ext.l   d0                  ; -f(0) in units (floor)
        divs.w  d1,d0               ; crossing t in cells
        subq.w  #2,d0
        cmp.w   d0,d4
        bge.s   .wx\@
        move.w  d0,d4               ; lo = max(lo, t-2)
        bra.s   .wx\@
.wn\@:  tst.l   d0                  ; DF < 0: f falls along the row
        bmi     \1                  ; f(0) < 0: none pass
        move.l  d0,d6
        add.l   4(a0),d6            ; f(2*nwin)
        bge.s   .wx\@               ; >= 0: all pass
        move.w  8(a0),d1
        cmp.w   #-16,d1
        bgt.s   .wx\@               ; too flat to bound
        neg.w   d1
        swap    d0
        ext.l   d0                  ; f(0) in units (floor)
        divs.w  d1,d0               ; crossing t in cells
        addq.w  #2,d0
        cmp.w   d0,d5
        ble.s   .wx\@
        move.w  d0,d5               ; hi = min(hi, t+2)
        bra.s   .wx\@
.wz\@:  tst.l   d0                  ; DF = 0: f constant along the row
        bmi     \1
.wx\@:  lea     12(a0),a0
        endm

; beat_poll: consume a frame edge that fired since the last poll and
; count it in xbeats. The frame bit cannot count two edges, so the work
; is polled at stage boundaries (after the lattice, after each drawn
; object; every stage is under a beat) and the loop's beats = 1 + the
; edges consumed.
; In:      none
; Out:     xbeats + 1 when an edge was pending (and the edge consumed)
; Trashes: none
beat_poll macro
        btst    #pc__frame,pc_intr
        beq.s   .bp\@
        move.b  #1<<pc__frame,pc_intr
        move.l  a0,-(sp)
        lea     xbeats(pc),a0
        addq.w  #1,(a0)
        move.l  (sp)+,a0
.bp\@:
        endm

; sight_ops: the sight's pixels (spec 5.4) through one byte op: \1 = or
; with \2 = 0 draws them, \1 = and with \2 = $ff clears them (the masks
; are XORed with \2). The four-corner bracket, 32 px between its legs:
; bars at rows horizon-11 and horizon+11 from x 240 to 272, 4-row legs
; at their ends pointing at the horizon, and stalks at x 256 (the line
; of fire) out to rows horizon-26 and horizon+26.
; In:      a0 = colour byte base (back buffer base: +0 green, +1 red)
; Out:     none
; Trashes: d0, a1
sight_ops macro
        lea     (horizon-26)*scr_llen+64(a0),a1
        moveq   #15-1,d0
.st\@:  \1.b    #$80^\2,(a1)                ; top stalk: rows -26..-12
        \1.b    #$80^\2,38*scr_llen(a1)     ; bottom stalk: +12..+26
        lea     scr_llen(a1),a1
        dbf     d0,.st\@
        lea     (horizon-10)*scr_llen+60(a0),a1
        moveq   #4-1,d0
.lg\@:  \1.b    #$80^\2,(a1)                ; top legs: rows -10..-7
        \1.b    #$80^\2,8(a1)
        \1.b    #$80^\2,17*scr_llen(a1)     ; bottom legs: +7..+10
        \1.b    #$80^\2,17*scr_llen+8(a1)
        lea     scr_llen(a1),a1
        dbf     d0,.lg\@
        \1.b    #$ff^\2,(horizon-11)*scr_llen+60(a0)    ; top bar, x 240..272
        \1.b    #$ff^\2,(horizon-11)*scr_llen+62(a0)
        \1.b    #$ff^\2,(horizon-11)*scr_llen+64(a0)
        \1.b    #$ff^\2,(horizon-11)*scr_llen+66(a0)
        \1.b    #$80^\2,(horizon-11)*scr_llen+68(a0)
        \1.b    #$ff^\2,(horizon+11)*scr_llen+60(a0)    ; bottom bar
        \1.b    #$ff^\2,(horizon+11)*scr_llen+62(a0)
        \1.b    #$ff^\2,(horizon+11)*scr_llen+64(a0)
        \1.b    #$ff^\2,(horizon+11)*scr_llen+66(a0)
        \1.b    #$80^\2,(horizon+11)*scr_llen+68(a0)
        endm
