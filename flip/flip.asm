; flip.asm -- double-buffered takeover demo: 10 sprites + IPC melody
;
; Full machine takeover (docs/takeover.md), then true double buffering
; using the ZX8301's second screen: bit 7 of $18063 switches the display
; between $20000 (screen 0) and $28000 (screen 1). Screen 1 sits on top
; of the QDOS system variables -- which is fine, QDOS is dead, but it is
; why this project includes ipc_sound_takeover.asm: the snd_clrint helper
; that read the sysvar mask byte at $28035 is gone (its only purpose was
; QDOS cohabitation).
;
; Per frame: erase the sprites from the BACK buffer at the positions they
; had when that buffer was last drawn (two frames ago -- each buffer keeps
; its own previous-position slots), move all sprites, draw them into the
; back buffer, tick the melody, wait for VBL, flip. The scene costs a few
; milliseconds of drawing -- way past the vertical blanking window, so on
; a single screen this would tear/flicker; flipping shows only complete
; frames.
;
; $18063 is write-only: the displayed-buffer state lives in d7 (the back
; buffer index) and the register value is derived from it at flip time.
;
; Assemble: vasmm68k_mot -m68008 -Fbin -o flip_bin flip.asm

; hardware (pc_ipcwr/pc_ipcrd come from ipc_sound_takeover.asm)
mc_stat     equ     $18063          ; ZX8301 display control (write-only):
                                    ;   bit 3 mode (0=512px), bit 7 screen base
pc_intr     equ     $18021          ; ZX8302 interrupt register
pc__frame   equ     3               ; bit 3 = 50/60 Hz frame interrupt

scr0        equ     $20000          ; screen 0 (displayed at boot)
scr1        equ     $28000          ; screen 1 (ex-QDOS sysvars, now ours)
scr_llen    equ     128             ; bytes per scan line

; sprites: 16x16 solid squares, mode 4
spr_w       equ     16
spr_h       equ     16
sx_max      equ     512-spr_w       ; bounce limits (top-left position)
sy_max      equ     256-spr_h

; sprite record layout
spr_x       equ     0               ; position
spr_y       equ     2
spr_dx      equ     4               ; velocity, pixels/frame
spr_dy      equ     6
spr_col     equ     8               ; bit 0 = green plane, bit 1 = red plane
spr_px      equ     10              ; previous position per buffer:
                                    ;   +0/+2 buffer 0, +4/+6 buffer 1
spr_size    equ     18

nspr        equ     10

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
        dc.b    'Flip'
jobname_e:
        even

; ----------------------------------------------------------------- take over
main:
        trap    #0                  ; QDOS: enter supervisor mode
        move.w  #$2700,sr           ; mask all interrupts -- QDOS is gone now
        lea     sv_stack_top(pc),sp ; run on our own supervisor stack

        move.b  #0,mc_stat          ; mode 4, screen 0 displayed

        lea     scr0,a0             ; clear BOTH screens ($20000-$2FFFF):
        move.w  #$10000/4-1,d0      ; 64 KB, sysvars included -- point of
        moveq   #0,d1               ; no return
.clr:   move.l  d1,(a0)+
        dbf     d0,.clr

        lea     sprites(pc),a5      ; prev positions (both buffers) = start
        moveq   #nspr-1,d6          ; positions, so the first erases are
.pinit: move.w  spr_x(a5),d0        ; harmless no-ops on black screens
        move.w  spr_y(a5),d1
        move.w  d0,spr_px+0(a5)
        move.w  d1,spr_px+2(a5)
        move.w  d0,spr_px+4(a5)
        move.w  d1,spr_px+6(a5)
        lea     spr_size(a5),a5
        dbf     d6,.pinit

        lea     mel_state(pc),a2    ; arm the melody player (pointer must be
        move.w  #1,(a2)             ; set at runtime: flat PIC binary)
        lea     melody(pc),a3
        move.l  a3,2(a2)

        moveq   #1,d7               ; back buffer index: screen 1
                                    ; (screen 0 is on display)

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
        beq.s   .wait                   ; (bit 3 only: bits 7..5 always move)

        move.w  d7,d0               ; flip: display the buffer just drawn
        ror.b   #1,d0               ; 0 -> $00, 1 -> $80 (mode 4 bits stay 0)
        move.b  d0,mc_stat
        eori.w  #1,d7               ; other buffer becomes the back buffer
        bra     frame_loop

; ------------------------------------------------------------- melody player
; Once per frame: count down, and when the current event expires send the
; next one to the IPC (~2 ms of bit-banging, comfortably inside one frame).
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
; A 16-pixel-wide sprite at arbitrary x covers three 8-pixel groups (two
; bytes each: green plane, red plane). Masks: first group $FF>>b, middle
; group all 8 pixels, last group ~($FF>>b) -- at b=0 the last mask is 0,
; making the OR/AND there a harmless no-op, so no special case is needed.

; spr_addr: d0=x, d1=y, a4=buffer -> a0 = group address,
;           d2 = first-group mask ($FF>>b), d3 = last-group mask (~d2)
spr_addr:
        move.w  d1,d2
        lsl.w   #7,d2               ; y * 128
        move.w  d0,d3
        lsr.w   #3,d3               ; 8-pixel group...
        add.w   d3,d3               ; ...2 bytes each
        add.w   d3,d2
        lea     (a4,d2.w),a0        ; max offset 30844, fits signed word
        and.w   #7,d0               ; b = x within the first group
        move.b  #$ff,d2
        lsr.b   d0,d2
        move.b  d2,d3
        not.b   d3
        rts

; spr_draw: draw sprite (a5) into buffer a4 at its current position
spr_draw:
        move.w  spr_x(a5),d0
        move.w  spr_y(a5),d1
        bsr     spr_addr
        move.w  spr_col(a5),d4
        moveq   #spr_h-1,d5
.row:   btst    #0,d4               ; green plane
        beq.s   .nog
        or.b    d2,(a0)
        move.b  #$ff,2(a0)
        or.b    d3,4(a0)
.nog:   btst    #1,d4               ; red plane
        beq.s   .nor
        or.b    d2,1(a0)
        move.b  #$ff,3(a0)
        or.b    d3,5(a0)
.nor:   lea     scr_llen(a0),a0
        dbf     d5,.row
        rts

; spr_erase: clear sprite (a5) from buffer a4 at prev[d7] (both planes --
; pass 1 erases everything before pass 2 redraws, so overlaps survive)
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
.row:   and.b   d3,(a0)             ; first group: keep ~mask (= d3)
        and.b   d3,1(a0)
        clr.b   2(a0)
        clr.b   3(a0)
        and.b   d2,4(a0)            ; last group: keep ~lastmask (= d2)
        and.b   d2,5(a0)
        lea     scr_llen(a0),a0
        dbf     d5,.row
        rts

; spr_move: step sprite (a5), reflecting off the screen edges (positions
; are clamped by mirroring, so any speed works, not just divisors)
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

; x, y, dx, dy, colour (1 green / 2 red / 3 white), prev positions x4
sprites:
        dc.w    8,8,     2,1,   3,  0,0,0,0
        dc.w    480,16,  -1,2,  2,  0,0,0,0
        dc.w    40,180,  3,-1,  1,  0,0,0,0
        dc.w    300,60,  -2,-2, 3,  0,0,0,0
        dc.w    200,120, 1,3,   2,  0,0,0,0
        dc.w    120,220, -3,1,  1,  0,0,0,0
        dc.w    420,200, 2,-3,  3,  0,0,0,0
        dc.w    260,30,  -1,-1, 2,  0,0,0,0
        dc.w    60,90,   3,2,   1,  0,0,0,0
        dc.w    350,150, -2,3,  3,  0,0,0,0

        even
sv_stack:
        ds.b    64                  ; private supervisor stack
sv_stack_top:

; IPC sound, takeover variant (must be last: ends with an "end" directive)
        include "ipc_sound_takeover.asm"
