; draw_line_w -- white mode 4 line drawer (both colour planes)
;
; The lines/ benchmark drawer (lines/lines.asm round 2) adapted for use
; as a library routine:
;   - entry in registers, no table pointer, no benchmark accounting:
;       d0 = x1, d1 = y1, d2 = x2, d3 = y2 (words, on-screen coords --
;       no clipping: the caller guarantees 0..511 x 0..255)
;       a4 = screen base
;     trashes d0-d5, a0, a1; preserves d6, d7, a2, a3, a5.
;   - WHITE: every plot is a word op on the even-addressed screen word,
;     hitting the green byte (high) and red byte (low) together. All the
;     masks are byte-pairs ($8080, $C0C0, ...), and the per-pixel x step
;     is ror.w -- $0101 rotates to $8080 with carry, advancing the word.
;   - the shallow fast path (pending-run byte blocks, |dx| >= 2|dy|) is
;     always on. Pixel placement identical to the baseline loops
;     (verified by simulation on the green original).
;
; No "end" directive -- meant to be included.

dlw_llen    equ     128             ; bytes per scan line

draw_line_w:
        sub.w   d0,d2               ; d2 = dx
        sub.w   d1,d3               ; d3 = dy
        move.w  d2,d4
        bge.s   .adx
        neg.w   d4                  ; d4 = |dx|
.adx:   move.w  d3,d5
        bge.s   .ady
        neg.w   d5                  ; d5 = |dy|
.ady:   cmp.w   d4,d5
        bgt     dlw_ymaj            ; |dy| > |dx| (ties go x-major)

; ----- x-major: normalize to left->right, minor y step sign in a1
        tst.w   d2
        bge.s   .nsw
        add.w   d2,d0               ; swap endpoints: start at the left
        add.w   d3,d1
        neg.w   d3                  ; dy flips with the swap
.nsw:   move.w  #dlw_llen,a1        ; minor step: down...
        tst.w   d3
        bge.s   .sdn
        move.w  #-dlw_llen,a1       ; ...or up
.sdn:   move.w  d5,d2               ; shallow (|dx| >= 2|dy|)? fast path
        add.w   d2,d2
        cmp.w   d2,d4
        bge     dlw_xfast
        lsl.w   #7,d1               ; y*128
        move.w  d0,d2
        lsr.w   #3,d2
        add.w   d2,d2               ; (x>>3)*2: screen word offset
        add.w   d2,d1
        lea     (a4,d1.w),a0
        and.w   #7,d0
        move.w  #$8080,d2
        lsr.w   d0,d2               ; d2 = pixel mask, both planes
        move.w  d4,d0               ; d0 = loop count (|dx| -> |dx|+1 px)
        move.w  d4,d1
        add.w   d1,d1               ; d1 = 2|dx| (error decrement)
        move.w  d4,d3
        neg.w   d3                  ; d3 = error, starts at -|dx|
        move.w  d2,d4               ; d4 = mask
        move.w  d5,d2
        add.w   d2,d2               ; d2 = 2|dy| (error increment)
.xl:    or.w    d4,(a0)             ; plot (green + red byte)
        add.w   d2,d3               ; err += 2|dy|
        bmi.s   .ny
        adda.w  a1,a0               ; y minor step (+-128)
        sub.w   d1,d3               ; err -= 2|dx|
.ny:    ror.w   #1,d4               ; x step right; $0101 wraps -> carry
        bcc.s   .nx
        addq.l  #2,a0               ; next screen word
.nx:    dbf     d0,.xl
        rts

; ----- y-major: normalize to top->bottom, then split on x direction
dlw_ymaj:
        tst.w   d3
        bge.s   .nsw
        add.w   d2,d0               ; swap endpoints: start at the top
        add.w   d3,d1
        neg.w   d2                  ; dx flips with the swap
.nsw:   lsl.w   #7,d1               ; address + mask, as above
        move.w  d0,d3
        lsr.w   #3,d3
        add.w   d3,d3
        add.w   d3,d1
        lea     (a4,d1.w),a0
        and.w   #7,d0
        move.w  #$8080,d3
        lsr.w   d0,d3               ; d3 = pixel mask (parked)
        move.w  d5,d0               ; d0 = loop count (|dy| -> |dy|+1 px)
        move.w  d5,d1
        add.w   d1,d1               ; d1 = 2|dy| (error decrement)
        neg.w   d5                  ; d5 = error, starts at -|dy|
        tst.w   d2                  ; which way does x step?
        bmi.s   dlw_ymajl
        add.w   d2,d2               ; d2 = 2|dx| (error increment)
        move.w  d3,d4               ; d4 = mask
        move.w  d5,d3               ; d3 = error
.yr:    or.w    d4,(a0)             ; plot
        add.w   d2,d3               ; err += 2|dx|
        bmi.s   .nx
        ror.w   #1,d4               ; x minor step right
        bcc.s   .nc
        addq.l  #2,a0
.nc:    sub.w   d1,d3               ; err -= 2|dy|
.nx:    lea     dlw_llen(a0),a0     ; y major step, unconditional
        dbf     d0,.yr
        rts

dlw_ymajl:
        neg.w   d2
        add.w   d2,d2               ; d2 = 2|dx| (error increment)
        move.w  d3,d4               ; d4 = mask
        move.w  d5,d3               ; d3 = error
.yl:    or.w    d4,(a0)             ; plot
        add.w   d2,d3               ; err += 2|dx|
        bmi.s   .nx
        rol.w   #1,d4               ; x minor step left; $8080 -> $0101
        bcc.s   .nc
        subq.l  #2,a0
.nc:    sub.w   d1,d3               ; err -= 2|dy|
.nx:    lea     dlw_llen(a0),a0     ; y major step, unconditional
        dbf     d0,.yl
        rts

; ----- x-major fast path: shallow lines (|dx| >= 2|dy|), word writes.
; Pending-run word mask in d4 (byte-pair runs, $ffff = full byte both
; planes); common path per pixel is the error add + an untaken bpl.
; See lines/lines.asm for the annotated green original.
dlw_xfast:
        lsl.w   #7,d1               ; address
        move.w  d0,d2
        lsr.w   #3,d2
        add.w   d2,d2
        add.w   d2,d1
        lea     (a4,d1.w),a0
        and.w   #7,d0               ; d0 = p, bit position in the byte
        move.w  d4,d2               ; split T = |dx|+1 pixels into
        addq.w  #1,d2               ; lead / blocks of 8 / tail
        moveq   #8,d1
        sub.w   d0,d1
        and.w   #7,d1               ; lead = (8-p) & 7 ...
        cmp.w   d2,d1
        ble.s   .lok
        move.w  d2,d1               ; ... clamped to T (tiny line)
.lok:   sub.w   d1,d2               ; rest = T - lead
        move.w  d2,d3
        and.w   #7,d3
        move.w  d3,-(sp)            ; push tail = rest & 7
        lsr.w   #3,d2
        move.w  d2,-(sp)            ; push blocks = rest >> 3
        move.w  d1,-(sp)            ; push lead
        move.w  d4,d3
        neg.w   d3                  ; d3 = error, starts at -|dx|
        move.w  d4,d1
        add.w   d1,d1               ; d1 = 2|dx| (error decrement)
        move.w  d5,d2
        add.w   d2,d2               ; d2 = 2|dy| (error increment)
        move.w  #$8080,d4
        lsr.w   d0,d4               ; d4 = pixel mask at p, both planes
        move.w  (sp)+,d5            ; --- lead-in: per-pixel body
        bra.s   .ltst
.lpx:   or.w    d4,(a0)
        add.w   d2,d3
        bmi.s   .ln
        adda.w  a1,a0
        sub.w   d1,d3
.ln:    ror.w   #1,d4
        bcc.s   .ltst
        addq.l  #2,a0
.ltst:  dbf     d5,.lpx

        move.w  (sp)+,d5            ; --- middle: unrolled byte blocks
        moveq   #-1,d4              ; pending run opens at slot 0
        bra.s   .btst

.st0:   move.w  d4,d0               ; y-step flushes, slots 0-3
        and.w   #$8080,d0           ; pending & run-end-at-slot mask
        or.w    d0,(a0)             ; write the run to the leaving row
        move.w  #$7f7f,d4           ; pending reopens at the next slot
        adda.w  a1,a0
        sub.w   d1,d3
        bra.s   .r1
.st1:   move.w  d4,d0
        and.w   #$c0c0,d0
        or.w    d0,(a0)
        move.w  #$3f3f,d4
        adda.w  a1,a0
        sub.w   d1,d3
        bra.s   .r2
.st2:   move.w  d4,d0
        and.w   #$e0e0,d0
        or.w    d0,(a0)
        move.w  #$1f1f,d4
        adda.w  a1,a0
        sub.w   d1,d3
        bra.s   .r3
.st3:   move.w  d4,d0
        and.w   #$f0f0,d0
        or.w    d0,(a0)
        move.w  #$0f0f,d4
        adda.w  a1,a0
        sub.w   d1,d3
        bra.s   .r4

.blk:   add.w   d2,d3               ; slot 0: err += 2|dy|, that is all
        bpl.s   .st0
.r1:    add.w   d2,d3               ; slot 1
        bpl.s   .st1
.r2:    add.w   d2,d3               ; slot 2
        bpl.s   .st2
.r3:    add.w   d2,d3               ; slot 3
        bpl.s   .st3
.r4:    add.w   d2,d3               ; slot 4
        bpl.s   .st4
.r5:    add.w   d2,d3               ; slot 5
        bpl.s   .st5
.r6:    add.w   d2,d3               ; slot 6
        bpl.s   .st6
.r7:    add.w   d2,d3               ; slot 7
        bpl.s   .st7
        or.w    d4,(a0)             ; no y-step left pending: one write
        moveq   #-1,d4              ; covers up to 8 white pixels
.bnx:   addq.l  #2,a0
.btst:  dbf     d5,.blk

        move.w  (sp)+,d5            ; --- tail: per-pixel body at p = 0
        move.w  #$8080,d4
        bra.s   .ttst
.tpx:   or.w    d4,(a0)
        add.w   d2,d3
        bmi.s   .tn
        adda.w  a1,a0
        sub.w   d1,d3
.tn:    ror.w   #1,d4
        bcc.s   .ttst
        addq.l  #2,a0
.ttst:  dbf     d5,.tpx
        rts

.st4:   move.w  d4,d0               ; y-step flushes, slots 4-7
        and.w   #$f8f8,d0
        or.w    d0,(a0)
        move.w  #$0707,d4
        adda.w  a1,a0
        sub.w   d1,d3
        bra.s   .r5
.st5:   move.w  d4,d0
        and.w   #$fcfc,d0
        or.w    d0,(a0)
        move.w  #$0303,d4
        adda.w  a1,a0
        sub.w   d1,d3
        bra.s   .r6
.st6:   move.w  d4,d0
        and.w   #$fefe,d0
        or.w    d0,(a0)
        move.w  #$0101,d4
        adda.w  a1,a0
        sub.w   d1,d3
        bra.s   .r7
.st7:   or.w    d4,(a0)             ; run end = whole pending: no and
        moveq   #-1,d4              ; next block opens a fresh run
        adda.w  a1,a0
        sub.w   d1,d3
        bra.s   .bnx                ; block's write already done
