; flip8.asm -- MODE 8 double-buffered takeover demo: 10 sprites + melody
;
; The mode 8 port of flip/flip.asm. Architecture identical: full takeover,
; two screens ($20000/$28000, the latter over the dead QDOS sysvars),
; erase-two-frames-ago bookkeeping, VBL-synced page flip, IPC melody.
; What changes is the pixel format only (manual section 10.2):
;
;   256x256, 4 bits/pixel, still 128 bytes/line and 32 KB per screen.
;   A 2-byte group holds 4 pixels, two interleaved bits per pixel:
;       even byte:  G3 F3 G2 F2 G1 F1 G0 F0    (green, flash)
;       odd  byte:  R3 B3 R2 B2 R1 B1 R0 B0    (red, blue)
;   G/R/B give 8 fixed colours; F is the hardware flash toggle (kept 0).
;
; A solid colour is two per-plane byte patterns: green byte G*%10101010,
; red byte R*%10101010 | B*%01010101. Because each pixel owns two adjacent
; mask bits, the edge-mask trick from flip carries over: b = (x&3)*2,
; first-group mask $FF>>b, last-group mask its complement -- an 8-pixel
; sprite spans three groups exactly like a 16-pixel sprite did in mode 4.
; Mode 8 pixels are twice as wide on screen, so 8x16 sprites are square.
;
; The mode bit (bit 3 of $18063) rides along in EVERY register write --
; the register is write-only, so the flip value is $08 or $88, never $00.
;
; Assemble: vasmm68k_mot -m68008 -Fbin -o flip8_bin flip8.asm

; hardware (pc_ipcwr/pc_ipcrd come from ipc_sound_takeover.asm)
mc_stat     equ     $18063          ; ZX8301 display control (write-only)
mc__m256    equ     %1000           ; bit 3: 256-pixel / 8-colour mode
pc_intr     equ     $18021          ; ZX8302 interrupt register
pc__frame   equ     3               ; bit 3 = 50/60 Hz frame interrupt

scr0        equ     $20000          ; screen 0 (displayed at boot)
scr1        equ     $28000          ; screen 1 (ex-QDOS sysvars, now ours)
scr_llen    equ     128             ; bytes per scan line

; sprites: 8x16 solid blocks (visually square: mode 8 pixels are 2:1)
spr_w       equ     8
spr_h       equ     16
sx_max      equ     256-spr_w       ; bounce limits (top-left position)
sy_max      equ     256-spr_h

; sprite record layout
spr_x       equ     0               ; position
spr_y       equ     2
spr_dx      equ     4               ; velocity, pixels/frame
spr_dy      equ     6
spr_col     equ     8               ; +8 green-byte pattern, +9 red-byte
spr_px      equ     10              ; previous position per buffer:
                                    ;   +0/+2 buffer 0, +4/+6 buffer 1
spr_size    equ     18

nspr        equ     10

; colour plane patterns (F bits kept 0 -- no hardware flash)
pat_g       equ     %10101010       ; green bits set, 4 pixels
pat_r       equ     %10101010       ; red bits set
pat_b       equ     %01010101       ; blue bits set

; sprite <x>,<y>,<dx>,<dy>,<gpat>,<rpat> -- one sprite record
sprite      macro
        dc.w    \1,\2,\3,\4
        dc.b    \5,\6
        dc.w    0,0,0,0             ; prev positions, set at runtime
        endm

; note pitches, stored as BASIC pitch + 1 (freq ~ 11447/(10.6+pitch) Hz)
n_g3        equ     49
n_c4        equ     34
n_d4        equ     29
n_e4        equ     25
n_f4        equ     23
n_g4        equ     20
n_a4        equ     16

qn          equ     25              ; quarter note = half a second

; note <frames>,<pitch+1> -- one melody event, IPC-timed articulation
note        macro
        dc.w    \1
        dc.b    \2,\2,0,0
        dc.b    (\1*250)&$ff,((\1*250)>>8)&$ff
        dc.b    0,0
        endm

; rest <frames> -- silence (pitch1 = 0 makes the player call snd_kill)
rest        macro
        dc.w    \1
        dc.b    0,0,0,0,0,0,0,0
        endm

; ---------------------------------------------------------------- job header
start:
        bra.s   main
        dc.l    0
        dc.w    $4afb               ; "job name follows" flag
        dc.w    jobname_e-jobname
jobname:
        dc.b    'Flip8'
jobname_e:
        even

; ----------------------------------------------------------------- take over
main:
        trap    #0                  ; QDOS: enter supervisor mode
        move.w  #$2700,sr           ; mask all interrupts -- QDOS is gone now
        lea     sv_stack_top(pc),sp ; run on our own supervisor stack

        move.b  #mc__m256,mc_stat   ; mode 8, screen 0 displayed

        lea     scr0,a0             ; clear BOTH screens ($20000-$2FFFF)
        move.w  #$10000/4-1,d0
        moveq   #0,d1
.clr:   move.l  d1,(a0)+
        dbf     d0,.clr

        lea     sprites(pc),a5      ; prev positions (both buffers) = start
        moveq   #nspr-1,d6          ; positions: first erases are no-ops
.pinit: move.w  spr_x(a5),d0
        move.w  spr_y(a5),d1
        move.w  d0,spr_px+0(a5)
        move.w  d1,spr_px+2(a5)
        move.w  d0,spr_px+4(a5)
        move.w  d1,spr_px+6(a5)
        lea     spr_size(a5),a5
        dbf     d6,.pinit

        lea     mel_state(pc),a2    ; arm the melody player
        move.w  #1,(a2)
        lea     melody(pc),a3
        move.l  a3,2(a2)

        moveq   #1,d7               ; back buffer index: screen 1

; ---------------------------------------------------------------- frame loop
frame_loop:
        lea     scr0,a4             ; a4 = back buffer base
        tst.w   d7
        beq.s   .bb0
        lea     scr1,a4
.bb0:
        lea     sprites(pc),a5      ; pass 1: erase every sprite from the
        moveq   #nspr-1,d6          ; back buffer (positions of 2 frames ago)
.erase: bsr     spr_erase
        lea     spr_size(a5),a5
        dbf     d6,.erase

        lea     sprites(pc),a5      ; pass 2: move, draw, remember position
        moveq   #nspr-1,d6
.step:  bsr     spr_move
        bsr     spr_draw
        move.w  d7,d0               ; prev[back] = new position
        add.w   d0,d0
        add.w   d0,d0
        lea     spr_px(a5),a1
        adda.w  d0,a1
        move.w  spr_x(a5),(a1)+
        move.w  spr_y(a5),(a1)
        lea     spr_size(a5),a5
        dbf     d6,.step

        bsr     mel_tick            ; advance the melody (usually a no-op)

        move.b  #1<<pc__frame,pc_intr   ; ack frame interrupt
.wait:  btst    #pc__frame,pc_intr     ; ...and wait for the next VBL
        beq.s   .wait

        move.w  d7,d0               ; flip: display the buffer just drawn
        ror.b   #1,d0               ; 0 -> $00, 1 -> $80
        or.b    #mc__m256,d0        ; the mode bit rides along every write
        move.b  d0,mc_stat
        eori.w  #1,d7               ; other buffer becomes the back buffer
        bra     frame_loop

; ------------------------------------------------------------- melody player
mel_tick:
        lea     mel_state(pc),a2
        move.w  (a2),d0             ; frames left on current event
        subq.w  #1,d0
        move.w  d0,(a2)
        bne.s   .done
        move.l  2(a2),a3            ; next event
        move.w  (a3)+,d0            ; its frame count...
        bne.s   .play
        lea     melody(pc),a3       ; ...0 = end of table: loop the melody
        move.w  (a3)+,d0
.play:  move.w  d0,(a2)
        tst.b   (a3)                ; pitch1 = 0 -> rest
        beq.s   .rest
        bsr     snd_beep            ; sends the block, advances a3 past it
        bra.s   .store
.rest:  bsr     snd_kill
        addq.l  #8,a3               ; skip the block by hand
.store: move.l  a3,2(a2)
.done:  rts

; ------------------------------------------------------------------- sprites
; An 8-pixel-wide sprite covers three 4-pixel groups. Each pixel owns two
; adjacent bits in both bytes of a group, so with b = (x&3)*2 the masks
; are exactly the mode 4 shapes: first group $FF>>b, middle full, last
; ~($FF>>b) -- and at b=0 the last mask is 0, a harmless no-op.

; spr_addr: d0=x, d1=y, a4=buffer -> a0 = group address,
;           d2 = first-group mask ($FF>>b), d3 = last-group mask (~d2)
spr_addr:
        move.w  d1,d2
        lsl.w   #7,d2               ; y * 128
        move.w  d0,d3
        lsr.w   #2,d3               ; 4-pixel group...
        add.w   d3,d3               ; ...2 bytes each
        add.w   d3,d2
        lea     (a4,d2.w),a0        ; max offset 30844, fits signed word
        and.w   #3,d0
        add.w   d0,d0               ; b = 2 bits per pixel
        move.b  #$ff,d2
        lsr.b   d0,d2
        move.b  d2,d3
        not.b   d3
        rts

; spr_draw: draw sprite (a5) into buffer a4 at its current position.
; Edge groups get (pattern AND mask) per plane; middle group the full
; pattern. Preserves d6 (the caller's sprite counter).
spr_draw:
        move.w  d6,-(sp)
        move.w  spr_x(a5),d0
        move.w  spr_y(a5),d1
        bsr     spr_addr
        move.b  spr_col(a5),d4      ; green-byte pattern
        move.b  spr_col+1(a5),d5    ; red-byte pattern
        move.b  d2,d0
        and.b   d4,d0               ; green, first group
        move.b  d3,d1
        and.b   d4,d1               ; green, last group
        and.b   d5,d2               ; red, first group
        and.b   d5,d3               ; red, last group
        moveq   #spr_h-1,d6
.row:   or.b    d0,(a0)             ; green plane
        or.b    d4,2(a0)
        or.b    d1,4(a0)
        or.b    d2,1(a0)            ; red plane
        or.b    d5,3(a0)
        or.b    d3,5(a0)
        lea     scr_llen(a0),a0
        dbf     d6,.row
        move.w  (sp)+,d6
        rts

; spr_erase: clear sprite (a5) from buffer a4 at prev[d7] (both planes)
spr_erase:
        move.w  d7,d1
        add.w   d1,d1
        add.w   d1,d1
        lea     spr_px(a5),a1
        adda.w  d1,a1
        move.w  (a1)+,d0            ; prev x
        move.w  (a1),d1             ; prev y
        bsr     spr_addr
        moveq   #spr_h-1,d5
.row:   and.b   d3,(a0)             ; first group: keep ~mask
        and.b   d3,1(a0)
        clr.b   2(a0)
        clr.b   3(a0)
        and.b   d2,4(a0)            ; last group: keep mask
        and.b   d2,5(a0)
        lea     scr_llen(a0),a0
        dbf     d5,.row
        rts

; spr_move: step sprite (a5), reflecting off the screen edges
spr_move:
        move.w  spr_x(a5),d0
        add.w   spr_dx(a5),d0
        bge.s   .x0
        neg.w   d0
        neg.w   spr_dx(a5)
.x0:    cmp.w   #sx_max,d0
        ble.s   .x1
        neg.w   d0
        add.w   #2*sx_max,d0
        neg.w   spr_dx(a5)
.x1:    move.w  d0,spr_x(a5)
        move.w  spr_y(a5),d0
        add.w   spr_dy(a5),d0
        bge.s   .y0
        neg.w   d0
        neg.w   spr_dy(a5)
.y0:    cmp.w   #sy_max,d0
        ble.s   .y1
        neg.w   d0
        add.w   #2*sy_max,d0
        neg.w   spr_dy(a5)
.y1:    move.w  d0,spr_y(a5)
        rts

; ---------------------------------------------------------------------- data
        even
mel_state:
        dc.w    0                   ; frames left (armed at runtime)
        dc.l    0                   ; pointer to next event (set at runtime)

; Frere Jacques, one voice, looping (quarter = 25 frames = 0.5 s)
melody:
        note    qn,n_c4             ; Fre-re Jac-ques
        note    qn,n_d4
        note    qn,n_e4
        note    qn,n_c4
        note    qn,n_c4
        note    qn,n_d4
        note    qn,n_e4
        note    qn,n_c4
        note    qn,n_e4             ; dor-mez vous
        note    qn,n_f4
        note    2*qn,n_g4
        note    qn,n_e4
        note    qn,n_f4
        note    2*qn,n_g4
        note    12,n_g4             ; son-nez les ma-ti-nes
        note    12,n_a4
        note    13,n_g4
        note    13,n_f4
        note    qn,n_e4
        note    qn,n_c4
        note    12,n_g4
        note    12,n_a4
        note    13,n_g4
        note    13,n_f4
        note    qn,n_e4
        note    qn,n_c4
        note    qn,n_c4             ; ding dang dong
        note    qn,n_g3
        note    2*qn,n_c4
        note    qn,n_c4
        note    qn,n_g3
        note    2*qn,n_c4
        rest    qn                  ; breathe, then loop
        dc.w    0                   ; end of melody: player restarts

; all seven visible mode 8 colours (and white twice, for ten sprites)
sprites:
        sprite  8,8,     2,1,   pat_g,pat_r|pat_b   ; white
        sprite  240,16,  -1,2,  pat_g,pat_r         ; yellow
        sprite  20,180,  3,-1,  pat_g,0             ; green
        sprite  150,60,  -2,-2, pat_g,pat_b         ; cyan
        sprite  100,120, 1,3,   0,pat_r             ; red
        sprite  60,220,  -3,1,  0,pat_r|pat_b       ; magenta
        sprite  210,200, 2,-3,  0,pat_b             ; blue
        sprite  130,30,  -1,-1, pat_g,pat_r|pat_b   ; white
        sprite  30,90,   3,2,   pat_g,pat_r         ; yellow
        sprite  175,150, -2,3,  0,pat_r|pat_b       ; magenta

        even
sv_stack:
        ds.b    64                  ; private supervisor stack
sv_stack_top:

; IPC sound, takeover variant (must be last: ends with an "end" directive)
        include "../lib/ipc_sound_takeover.asm"
