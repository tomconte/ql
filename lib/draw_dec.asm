; draw_dec -- decimal readout, 3x5 green digits (mode 4)
;
; Replaces binary cell meters: prints an unsigned word as a 6-digit
; right-aligned decimal field, leading zeros blanked (contract above
; the label).
;
; Layout: 3x5 glyphs at 4-px pitch, two glyph nibbles per green byte --
; 3 byte columns (24 px) by 5 rows. Only the green plane is written
; (the red bytes stay zero from the takeover screen clear), and every
; byte of the field is rewritten each call, so the readout self-erases
; as the value changes.
;
; Digit split is the classic repeated divu #10: quotient stays in the
; low word, the remainder (= next digit, least significant first) drops
; out of the high word.
;
; No "end" directive -- meant to be included.

ddc_llen    equ     128             ; bytes per scan line

; In:      d0.w = value (unsigned, 0..65535), a0 = screen address of
;          the field's top-left GREEN byte (even)
; Out:     none
; Trashes: d0-d4, a0-a3
draw_dec:
        lea     ddc_digs+6(pc),a1
        and.l   #$ffff,d0
        moveq   #6-1,d1
.dv:    divu.w  #10,d0              ; low = quotient, high = remainder
        swap    d0
        move.b  d0,-(a1)            ; remainder = next digit
        clr.w   d0
        swap    d0                  ; quotient back, high word clear
        dbf     d1,.dv
        moveq   #6-2,d1             ; blank leading zeros (the last
.bl:    tst.b   (a1)                ;  digit always shows)
        bne.s   .rd
        move.b  #10,(a1)+           ; glyph 10 = blank
        dbf     d1,.bl
.rd:    lea     ddc_digs(pc),a1
        moveq   #3-1,d4             ; three green byte columns
.col:   moveq   #0,d0
        move.b  (a1)+,d0            ; left digit -> glyph = font + d*5
        move.w  d0,d1
        lsl.w   #2,d1
        add.w   d1,d0
        lea     ddc_font(pc),a2
        adda.w  d0,a2
        moveq   #0,d0
        move.b  (a1)+,d0            ; right digit
        move.w  d0,d1
        lsl.w   #2,d1
        add.w   d1,d0
        lea     ddc_font(pc),a3
        adda.w  d0,a3
        moveq   #0,d3               ; row offset within the column
        moveq   #5-1,d2
.row:   move.b  (a3)+,d1            ; right glyph -> low nibble
        lsr.b   #4,d1
        or.b    (a2)+,d1            ; left glyph sits in the high nibble
        move.b  d1,(a0,d3.w)
        add.w   #ddc_llen,d3
        dbf     d2,.row
        addq.l  #2,a0               ; next green byte (skip the red one)
        dbf     d4,.col
        rts

ddc_digs:
        ds.b    6                   ; digit indices, most significant first

; 3x5 glyphs, one row per byte, pattern in the high nibble (bit 7 =
; leftmost pixel, bit 4 always clear = the inter-digit gap)
ddc_font:
        dc.b    $e0,$a0,$a0,$a0,$e0 ; 0
        dc.b    $40,$c0,$40,$40,$e0 ; 1
        dc.b    $e0,$20,$e0,$80,$e0 ; 2
        dc.b    $e0,$20,$e0,$20,$e0 ; 3
        dc.b    $a0,$a0,$e0,$20,$20 ; 4
        dc.b    $e0,$80,$e0,$20,$e0 ; 5
        dc.b    $e0,$80,$e0,$a0,$e0 ; 6
        dc.b    $e0,$20,$20,$40,$40 ; 7
        dc.b    $e0,$a0,$e0,$a0,$e0 ; 8
        dc.b    $e0,$a0,$e0,$20,$e0 ; 9
        dc.b    $00,$00,$00,$00,$00 ; 10 = blank
        even
