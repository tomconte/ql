; draw_line -- mode 4 line drawer with colour (red, green, white)
;
; Colour entry in front of two drawers:
;   draw_line_w (lib/draw_line_w.asm, include it too): white, word ops
;     hitting both colour planes at once -- unchanged, the fast path.
;   draw_line_p (below): ONE plane, byte ops. a4 = plane base. The green
;     plane is the even (high) byte of every screen word, red the odd
;     (low) byte, and byte ops have no alignment constraint: red is the
;     green drawer with the screen base offset by one byte.
; No colour masking in the hot loops, so each colour costs what its
; drawer costs; the dispatch is ~60 cycles per line.
;
; draw_line: d0 = x1, d1 = y1, d2 = x2, d3 = y2 (words, on-screen,
;            no clipping), d4.w = colour, a4 = screen base
;   trashes d0-d5, a0, a1; preserves d6, d7, a2, a3, a4, a5.
; Colour codes are the mode 4 pixel bits (G = bit 1, R = bit 0):
col_red     equ     1
col_green   equ     2
col_white   equ     3
; Colour 0 is not a drawer (erasing is the caller's business).
;
; No "end" directive -- meant to be included.

draw_line:
        cmp.w   #col_white,d4
        beq     draw_line_w         ; white: both planes, tail call
        move.l  a4,-(sp)            ; single plane: base = green byte...
        btst    #1,d4
        bne.s   .pl
        addq.l  #1,a4               ; ...or the red (odd) byte of the word
.pl:    bsr.s   draw_line_p
        move.l  (sp)+,a4
        rts

; ----------------------------------------------------------------------
; draw_line_p -- single-plane drawer: draw_line_w with byte ops.
;   d0 = x1, d1 = y1, d2 = x2, d3 = y2, a4 = PLANE base (screen base for
;   green, screen base + 1 for red); trashes d0-d5, a0, a1.
; Same dispatch, loops and pixel placement as draw_line_w; every mask is
; the single-byte form ($80, $ff, $7f, ...) and the x step is ror.b --
; $01 rotates to $80 with carry, advancing to the next screen word (+2 =
; the same plane's next byte).

dlp_llen    equ     128             ; bytes per scan line

draw_line_p:
        sub.w   d0,d2               ; d2 = dx
        sub.w   d1,d3               ; d3 = dy
        move.w  d2,d4
        bge.s   .adx
        neg.w   d4                  ; d4 = |dx|
.adx:   move.w  d3,d5
        bge.s   .ady
        neg.w   d5                  ; d5 = |dy|
.ady:   cmp.w   d4,d5
        bgt     dlp_ymaj            ; |dy| > |dx| (ties go x-major)

; ----- x-major: normalize to left->right, minor y step sign in a1
        tst.w   d2
        bge.s   .nsw
        add.w   d2,d0               ; swap endpoints: start at the left
        add.w   d3,d1
        neg.w   d3                  ; dy flips with the swap
.nsw:   move.w  #dlp_llen,a1        ; minor step: down...
        tst.w   d3
        bge.s   .sdn
        move.w  #-dlp_llen,a1       ; ...or up
.sdn:   move.w  d5,d2               ; shallow (|dx| >= 2|dy|)? fast path
        add.w   d2,d2
        cmp.w   d2,d4
        bge     dlp_xfast
        lsl.w   #7,d1               ; y*128
        move.w  d0,d2
        lsr.w   #3,d2
        add.w   d2,d2               ; (x>>3)*2: screen word offset
        add.w   d2,d1
        lea     (a4,d1.w),a0
        and.w   #7,d0
        move.b  #$80,d2
        lsr.b   d0,d2               ; d2 = pixel mask
        move.w  d4,d0               ; d0 = loop count (|dx| -> |dx|+1 px)
        move.w  d4,d1
        add.w   d1,d1               ; d1 = 2|dx| (error decrement)
        move.w  d4,d3
        neg.w   d3                  ; d3 = error, starts at -|dx|
        move.b  d2,d4               ; d4 = mask
        move.w  d5,d2
        add.w   d2,d2               ; d2 = 2|dy| (error increment)
.xl:    or.b    d4,(a0)             ; plot
        add.w   d2,d3               ; err += 2|dy|
        bmi.s   .ny
        adda.w  a1,a0               ; y minor step (+-128)
        sub.w   d1,d3               ; err -= 2|dx|
.ny:    ror.b   #1,d4               ; x step right; $01 wraps -> carry
        bcc.s   .nx
        addq.l  #2,a0               ; next screen word
.nx:    dbf     d0,.xl
        rts

; ----- y-major: normalize to top->bottom, then split on x direction
dlp_ymaj:
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
        move.b  #$80,d3
        lsr.b   d0,d3               ; d3 = pixel mask (parked)
        move.w  d5,d0               ; d0 = loop count (|dy| -> |dy|+1 px)
        move.w  d5,d1
        add.w   d1,d1               ; d1 = 2|dy| (error decrement)
        neg.w   d5                  ; d5 = error, starts at -|dy|
        tst.w   d2                  ; which way does x step?
        bmi.s   dlp_ymajl
        add.w   d2,d2               ; d2 = 2|dx| (error increment)
        move.b  d3,d4               ; d4 = mask
        move.w  d5,d3               ; d3 = error
.yr:    or.b    d4,(a0)             ; plot
        add.w   d2,d3               ; err += 2|dx|
        bmi.s   .nx
        ror.b   #1,d4               ; x minor step right
        bcc.s   .nc
        addq.l  #2,a0
.nc:    sub.w   d1,d3               ; err -= 2|dy|
.nx:    lea     dlp_llen(a0),a0     ; y major step, unconditional
        dbf     d0,.yr
        rts

dlp_ymajl:
        neg.w   d2
        add.w   d2,d2               ; d2 = 2|dx| (error increment)
        move.b  d3,d4               ; d4 = mask
        move.w  d5,d3               ; d3 = error
.yl:    or.b    d4,(a0)             ; plot
        add.w   d2,d3               ; err += 2|dx|
        bmi.s   .nx
        rol.b   #1,d4               ; x minor step left; $80 -> $01
        bcc.s   .nc
        subq.l  #2,a0
.nc:    sub.w   d1,d3               ; err -= 2|dy|
.nx:    lea     dlp_llen(a0),a0     ; y major step, unconditional
        dbf     d0,.yl
        rts

; ----- x-major fast path: shallow lines (|dx| >= 2|dy|), byte writes.
; Pending-run mask in d4 ($ff = full byte); common path per pixel is
; the error add + an untaken bpl. See lines/lines.asm for the
; annotated original.
dlp_xfast:
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
        move.b  #$80,d4
        lsr.b   d0,d4               ; d4 = pixel mask at p
        move.w  (sp)+,d5            ; --- lead-in: per-pixel body
        bra.s   .ltst
.lpx:   or.b    d4,(a0)
        add.w   d2,d3
        bmi.s   .ln
        adda.w  a1,a0
        sub.w   d1,d3
.ln:    ror.b   #1,d4
        bcc.s   .ltst
        addq.l  #2,a0
.ltst:  dbf     d5,.lpx

        move.w  (sp)+,d5            ; --- middle: unrolled byte blocks
        moveq   #-1,d4              ; pending run opens at slot 0
        bra.s   .btst

.st0:   move.b  d4,d0               ; y-step flushes, slots 0-3
        and.b   #$80,d0             ; pending & run-end-at-slot mask
        or.b    d0,(a0)             ; write the run to the leaving row
        moveq   #$7f,d4             ; pending reopens at the next slot
        adda.w  a1,a0
        sub.w   d1,d3
        bra.s   .r1
.st1:   move.b  d4,d0
        and.b   #$c0,d0
        or.b    d0,(a0)
        moveq   #$3f,d4
        adda.w  a1,a0
        sub.w   d1,d3
        bra.s   .r2
.st2:   move.b  d4,d0
        and.b   #$e0,d0
        or.b    d0,(a0)
        moveq   #$1f,d4
        adda.w  a1,a0
        sub.w   d1,d3
        bra.s   .r3
.st3:   move.b  d4,d0
        and.b   #$f0,d0
        or.b    d0,(a0)
        moveq   #$0f,d4
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
        or.b    d4,(a0)             ; no y-step left pending: one write
        moveq   #-1,d4              ; covers up to 8 pixels
.bnx:   addq.l  #2,a0
.btst:  dbf     d5,.blk

        move.w  (sp)+,d5            ; --- tail: per-pixel body at p = 0
        moveq   #-128,d4            ; bit 7 mask ($80)
        bra.s   .ttst
.tpx:   or.b    d4,(a0)
        add.w   d2,d3
        bmi.s   .tn
        adda.w  a1,a0
        sub.w   d1,d3
.tn:    ror.b   #1,d4
        bcc.s   .ttst
        addq.l  #2,a0
.ttst:  dbf     d5,.tpx
        rts

.st4:   move.b  d4,d0               ; y-step flushes, slots 4-7
        and.b   #$f8,d0
        or.b    d0,(a0)
        moveq   #$07,d4
        adda.w  a1,a0
        sub.w   d1,d3
        bra.s   .r5
.st5:   move.b  d4,d0
        and.b   #$fc,d0
        or.b    d0,(a0)
        moveq   #$03,d4
        adda.w  a1,a0
        sub.w   d1,d3
        bra.s   .r6
.st6:   move.b  d4,d0
        and.b   #$fe,d0
        or.b    d0,(a0)
        moveq   #$01,d4
        adda.w  a1,a0
        sub.w   d1,d3
        bra.s   .r7
.st7:   or.b    d4,(a0)             ; run end = whole pending: no and
        moveq   #-1,d4              ; next block opens a fresh run
        adda.w  a1,a0
        sub.w   d1,d3
        bra.s   .bnx                ; block's write already done
