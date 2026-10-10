; screens.asm -- glider: the screens around play (Beta 1, spec 11.1):
; the title, the sector card, game over, the pause; their timing and
; text helpers. All in vector text (lib/draw_text.asm, spec 5.7): the
; big words white, the rest green. Included by glider.asm.

; ---------------------------------------------------------------- scr clear
; scr_clear: both screens black ($20000-$2ffff).
; In:      none
; Out:     none
; Trashes: d0, d1, a0
scr_clear:
        lea     scr0,a0
        move.w  #$10000/4-1,d0
        moveq   #0,d1
.clr:   move.l  d1,(a0)+
        dbf     d0,.clr
        rts

; --------------------------------------------------------------- frame wait
; frame_wait: wait for the next frame edge and consume it.
; In:      none
; Out:     none
; Trashes: none
frame_wait:
.w:     btst    #pc__frame,pc_intr
        beq.s   .w
        move.b  #1<<pc__frame,pc_intr
        rts

; --------------------------------------------------------------------- hold
; hold: d0 frames with the screen as it is.
; In:      d0.w = frames (1..)
; Out:     none
; Trashes: d0
hold:
        subq.w  #1,d0
.f:     bsr.s   frame_wait
        dbf     d0,.f
        rts

; ----------------------------------------------------------------- key wait
; key_wait: wait, a frame at a time, for a fresh press of a row-1 key:
; released first if it is held (Space may still be down from play),
; then pressed.
; In:      d3.w = the key's bit (k1__*)
; Out:     none
; Trashes: d0-d2
key_wait:
        ifne    test_auto
        move.w  #test_auto,d0       ; unattended runs: as if pressed
        bra.s   hold                ;   after test_auto frames
        endc
.up:    bsr.s   frame_wait
        moveq   #key_row1,d0
        bsr     kbd_row
        btst    d3,d0
        bne.s   .up                 ; still held
.dn:    bsr.s   frame_wait
        moveq   #key_row1,d0
        bsr     kbd_row
        btst    d3,d0
        beq.s   .dn
        rts

; ------------------------------------------------------------------ str put
; str_put: a string copied to a0 with its 0, a0 left on the 0 (the next
; put goes over it).
; In:      a0 = destination, a1 = the string
; Out:     a0 = on the copy's 0, a1 = past the string
; Trashes: none
str_put:
.c:     move.b  (a1)+,(a0)+
        bne.s   .c
        subq.l  #1,a0
        rts

; ------------------------------------------------------------------ bcd put
; bcd_put: packed BCD bytes as ASCII digits at a0, then a 0 that a0 is
; left on; leading zeros left out when d1 is nonzero (the last digit
; always written).
; In:      a0 = destination, a1 = the BCD bytes (high nibble first),
;          d0.w = bytes (1..), d1.w = nonzero: no leading zeros
; Out:     a0 = on the 0, a1 = past the bytes
; Trashes: d0-d2
bcd_put:
        add.w   d0,d0
        subq.w  #1,d0               ; digits - 1: odd = a high nibble
.dig:   moveq   #0,d2
        move.b  (a1),d2
        btst    #0,d0
        beq.s   .lo
        lsr.b   #4,d2
        bra.s   .got
.lo:    and.b   #15,d2              ; the low nibble: the byte is done
        addq.l  #1,a1
.got:   tst.w   d1
        beq.s   .put
        tst.w   d0
        beq.s   .put                ; the last digit
        tst.b   d2
        beq.s   .skip               ; a leading zero
        moveq   #0,d1               ; every digit from here on
.put:   add.b   #'0',d2
        move.b  d2,(a0)+
.skip:  dbf     d0,.dig
        clr.b   (a0)
        rts

; -------------------------------------------------------------- title screen
; title_screen: the title on screen 0 (spec 11.1): STARQLIDER, BETA 1,
; the goal, the keys, PRESS SPACE, the session's best and the last
; game's scores; until Space is pressed afresh.
; In:      none
; Out:     txtbuf
; Trashes: d0-d5, a0-a2, a4, dtx_ws
title_screen:
        bsr     scr_clear
        move.b  #0,mc_stat          ; screen 0 shown
        lea     scr0,a4
        lea     tx_title(pc),a0
        moveq   #36,d1
        bsr     big_white
        lea     tx_beta(pc),a0
        moveq   #72,d1
        bsr     med_green
        lea     tx_goal(pc),a0
        moveq   #104,d1
        bsr     med_green
        lea     tx_keys(pc),a0
        move.w  #124,d1
        bsr     med_green
        lea     tx_press(pc),a0
        move.w  #160,d1
        bsr     med_green
        lea     txtbuf(pc),a0       ; HI 000000   LAST 000000
        lea     tx_hi(pc),a1
        bsr     str_put
        lea     hiscore+1(pc),a1
        moveq   #3,d0
        moveq   #0,d1
        bsr     bcd_put
        lea     tx_last(pc),a1
        bsr     str_put
        lea     lastscore+1(pc),a1
        moveq   #3,d0
        moveq   #0,d1
        bsr     bcd_put
        lea     txtbuf(pc),a0
        move.w  #204,d1
        bsr     med_green
        moveq   #k1__spc,d3
        bra     key_wait            ; tail call

; --------------------------------------------------------------- sector card
; sector_card: SECTOR n on a black screen 0 for card_f frames.
; In:      none
; Out:     txtbuf
; Trashes: d0-d5, a0-a2, a4, dtx_ws
sector_card:
        bsr     scr_clear
        move.b  #0,mc_stat
        lea     scr0,a4
        lea     txtbuf(pc),a0
        lea     tx_sector(pc),a1
        bsr     str_put
        lea     sector_n+1(pc),a1
        moveq   #1,d0
        moveq   #1,d1               ; SECTOR 1, not 01
        bsr     bcd_put
        lea     txtbuf(pc),a0
        moveq   #104,d1
        bsr     big_white
        move.w  #card_f,d0
        bra     hold                ; tail call

; --------------------------------------------------------------- over screen
; over_screen: the game's score kept (the last one, and the best if it
; beats it), then GAME OVER and the score on a black screen 0 for
; over_f frames.
; In:      none
; Out:     lastscore, hiscore, txtbuf
; Trashes: d0-d5, a0-a2, a4, dtx_ws
over_screen:
        move.l  score(pc),d0
        lea     lastscore(pc),a0
        move.l  d0,(a0)
        lea     hiscore(pc),a0
        cmp.l   (a0),d0             ; packed BCD compares as the number
        bls.s   .nhi
        move.l  d0,(a0)
.nhi:   bsr     scr_clear
        move.b  #0,mc_stat
        lea     scr0,a4
        lea     tx_over(pc),a0
        moveq   #90,d1
        bsr     big_white
        lea     txtbuf(pc),a0
        lea     tx_score(pc),a1
        bsr     str_put
        lea     score+1(pc),a1
        moveq   #3,d0
        moveq   #0,d1
        bsr     bcd_put
        lea     txtbuf(pc),a0
        move.w  #136,d1
        bsr     med_green
        move.w  #over_f,d0
        bra     hold                ; tail call

; -------------------------------------------------------------------- pause
; pause: PAUSED over the shown screen until Esc is pressed afresh, then
; its rows cleared there (that buffer's next erase sees to the rest).
; Called after the flip, so the shown buffer is the one d7 is not.
; In:      d7 = back buffer index
; Out:     none
; Trashes: d0-d5, a0-a2, a4, dtx_ws
pause:
        lea     scr0,a4             ; the shown one
        tst.w   d7
        bne.s   .s0
        lea     scr1,a4
.s0:    lea     tx_paused(pc),a0
        move.w  #pause_y,d1
        bsr     big_white
        moveq   #k1__esc,d3
        bsr     key_wait
        lea     pause_y*scr_llen(a4),a0
        move.w  #(6*(tx_big*2/3)+1)*32-1,d0 ; its rows (6 grid units and
        moveq   #0,d1                       ; the last), 32 longs each
.clr:   move.l  d1,(a0)+
        dbf     d0,.clr
        rts

; ---------------------------------------------------------------- crack run
; crack_run: the windshield cracks over the frozen view (spec 5.4): the
; shown screen gets crack.inc's groups of white segments crk_gap frames
; apart, from the impact outwards, mirrored on every other craft, with
; the crack's sound; then it holds crk_hold frames. Called after the
; flip, so the shown buffer is the one d7 is not.
; In:      d7 = back buffer index
; Out:     crk_mir, sfx_want (sent)
; Trashes: d0-d6, a0, a1, a3-a5
crack_run:
        lea     scr0,a4             ; the shown one
        tst.w   d7
        bne.s   .s0
        lea     scr1,a4
.s0:    lea     sfx_want(pc),a3     ; the sound
        move.b  #sfx_crack,(a3)
        bsr     sfx_play
        lea     crk_mir(pc),a0      ; every other one mirrored
        not.w   (a0)
        lea     crk_data(pc),a5
        move.w  #crk_groups-1,-(sp)
.grp:   move.w  (a5)+,d6            ; the group's segments
        bra.s   .sege
.seg:   movem.w (a5)+,d0-d3         ; x0, y0, x1, y1
        move.w  crk_mir(pc),d4
        beq.s   .nm
        neg.w   d0                  ; x -> 511 - x
        add.w   #511,d0
        neg.w   d2
        add.w   #511,d2
.nm:    moveq   #col_white,d4
        bsr     draw_line
.sege:  dbf     d6,.seg
        moveq   #crk_gap,d0
        bsr     hold
        subq.w  #1,(sp)
        bpl.s   .grp
        addq.l  #2,sp
        move.w  #crk_hold,d0
        bra     hold                ; tail call

; ------------------------------------------------------------- text helpers
; big_white: a string centred, in white big letters (tx_big).
; In:      a0 = the string, d1.w = y, a4 = screen base
; Out:     none
; Trashes: d0-d5, a0, a1, dtx_ws
big_white:
        moveq   #tx_big,d2
        moveq   #tx_big*2/3,d3
        moveq   #col_white,d4
        bra     draw_textc          ; tail call

; med_green: a string centred, in green letters (tx_med).
; In:      a0 = the string, d1.w = y, a4 = screen base
; Out:     none
; Trashes: d0-d5, a0, a1, dtx_ws
med_green:
        moveq   #tx_med,d2
        moveq   #tx_med*2/3,d3
        moveq   #col_green,d4
        bra     draw_textc          ; tail call
