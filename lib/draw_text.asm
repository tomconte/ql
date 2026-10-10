; draw_text -- vector text and HUD digits (mode 4), from lib/vfont.inc
;
; One font, two forms (tools/genfont.py, docs/engine-spec.md 5.7):
;   draw_text: strings in strokes -- every character a few polylines on a
;     4 x 6 grid, drawn with draw_line at any size (include
;     lib/draw_line.asm and lib/draw_line_w.asm too). A grid unit is d2
;     px across by d3 rows down: (3k, 2k) keeps the letters' shape on
;     mode 4's pixels, which are 1.5x taller than wide. A character cell
;     is vf_adv units across (the letter's 4 and a gap of 2), so n
;     characters span (n*vf_adv - 2)*d2 px, and 6*d3 rows plus one unit
;     for Q's tail. No clipping: the text must lie on screen. ~0.6 ms a
;     stroke at k = 1..2 (measured in vfont/): for static screens.
;     draw_textc centres a string on x 256.
;   draw_bcd: packed BCD numbers in the HUD digits, the digits' strokes
;     rasterized offline at 6 px by vf_dh rows, one byte per row,
;     written into the green plane like lib/draw_dec.asm (self-erasing,
;     a fraction of a ms) -- for readouts that change in play.
;
; Include lib/vfont.inc with it. No "end" directive -- meant to be
; included.

dtx_x       equ     0               ; dtx_ws: the cell's x,
dtx_y       equ     2               ;   its top row,
dtx_xu      equ     4               ;   px per grid unit across,
dtx_yu      equ     6               ;   rows per grid unit down,
dtx_col     equ     8               ;   the colour

; draw_text: a string in vector strokes, left to right from (d0, d1).
; In:      a0 = the string (bytes ' '..'Z', 0 ends it; the others print
;          as a space), d0.w = x, d1.w = y (top left of the first cell),
;          d2.w = px per grid unit across, d3.w = rows per grid unit
;          down, d4.w = colour (draw_line: 1 red, 2 green, 3 white),
;          a4 = screen base
; Out:     none
; Trashes: d0-d5, a0, a1, dtx_ws
draw_text:
        movem.l d6-d7/a2-a3/a5,-(sp)
        lea     dtx_ws(pc),a5
        movem.w d0-d4,(a5)          ; x, y, units, colour
        move.l  a0,a2               ; a2 = the string
.ch:    moveq   #0,d0
        move.b  (a2)+,d0
        beq.s   .done
        sub.w   #vf_first,d0
        bcs.s   .adv                ; a control code: a space
        cmp.w   #vf_n,d0
        bhs.s   .adv                ; past 'Z': a space
        add.w   d0,d0
        lea     vf_tab(pc),a3
        adda.w  (a3,d0.w),a3        ; a3 = the character's polylines
.poly:  moveq   #0,d7
        move.b  (a3)+,d7            ; its points (0: the character's end)
        beq.s   .adv
        subq.w  #1,d7
        moveq   #-1,d6              ; no point yet
.pt:    moveq   #0,d2
        move.b  (a3)+,d2            ; x << 4 | y
        moveq   #15,d3
        and.w   d2,d3               ; y
        lsr.w   #4,d2               ; x
        mulu.w  dtx_xu(a5),d2
        add.w   dtx_x(a5),d2        ; screen x
        mulu.w  dtx_yu(a5),d3
        add.w   dtx_y(a5),d3        ; screen y
        move.l  d6,d0               ; the previous point, x : y (-1: none)
        move.w  d2,d6
        swap    d6
        move.w  d3,d6               ; this one, for the next stroke
        tst.l   d0
        bmi.s   .first
        move.w  d0,d1
        swap    d0
        move.w  dtx_col(a5),d4
        bsr     draw_line           ; (d0, d1) -> (d2, d3)
.first: dbf     d7,.pt
        bra.s   .poly
.adv:   move.w  dtx_xu(a5),d0       ; the next cell
        mulu.w  #vf_adv,d0
        add.w   d0,dtx_x(a5)
        bra.s   .ch
.done:  movem.l (sp)+,d6-d7/a2-a3/a5
        rts

; draw_textc: draw_text centred on x 256 -- n characters start at
; 256 - (n*vf_adv - 2)*d2/2.
; In:      a0 = the string, d1.w = y, d2.w = px per grid unit across,
;          d3.w = rows per grid unit down, d4.w = colour, a4 = screen
;          base
; Out:     none
; Trashes: d0-d5, a0, a1, dtx_ws
draw_textc:
        move.l  a0,a1
.len:   tst.b   (a1)+
        bne.s   .len
        move.l  a1,d0
        sub.l   a0,d0
        subq.w  #1,d0               ; n
        mulu.w  #vf_adv,d0
        subq.w  #2,d0
        mulu.w  d2,d0
        lsr.w   #1,d0
        neg.w   d0
        add.w   #256,d0             ; x
        bra     draw_text           ; tail call

; draw_bcd: a packed BCD number in the HUD digits (vf_dig), one digit
; per 8-px screen group, green plane only; leading zeros blank (the
; last digit always shows). Every cell is rewritten, so the readout
; erases what it showed before.
; In:      a0 = the first cell's top-left green byte (even), a1 = the
;          BCD bytes (two digits each, high nibble first), d0.w = the
;          number of bytes (1..)
; Out:     a0 = the green byte of the cell after the last, a1 = past
;          the BCD bytes
; Trashes: d0-d3, a2
draw_bcd:
        add.w   d0,d0
        subq.w  #1,d0               ; digits - 1: odd = a high nibble
        moveq   #0,d3               ; nonzero once a digit has shown
.dig:   moveq   #0,d1
        move.b  (a1),d1
        btst    #0,d0
        beq.s   .lo
        lsr.b   #4,d1               ; the high nibble
        bra.s   .got
.lo:    and.b   #15,d1              ; the low one: the byte is done
        addq.l  #1,a1
.got:   or.w    d1,d3
        bne.s   .show
        tst.w   d0
        beq.s   .show               ; the last digit: even a 0
        moveq   #vf_blank,d1        ; a leading zero
.show:  mulu.w  #vf_dh,d1
        lea     vf_dig(pc),a2
        adda.w  d1,a2
        moveq   #vf_dh-1,d2
.row:   move.b  (a2)+,(a0)
        lea     128(a0),a0
        dbf     d2,.row
        lea     2-vf_dh*128(a0),a0  ; the next group's green byte
        dbf     d0,.dig
        rts

        even
dtx_ws: ds.w    5                   ; draw_text's dtx_* fields
