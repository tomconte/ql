; game8.asm -- proto-game skeleton: keyboard player + shot + sprites + music
;
; Everything so far in one program, MODE 8: full takeover, double buffering
; on the two hardware screens, IPC melody -- plus keyboard input read
; directly from the 8049 (IPC command 9, lib/ipc_keys_takeover.asm).
;
; Controls (KEYROW row 1: arrows/space are in ONE matrix row, and they are
; layout-independent -- see the lib header for the AZERTY story):
;   arrows      move the white player block (held keys, 2 px/frame)
;   space       fire: launches the cyan bolt upward with a laser sweep
;               that briefly takes over the sound channel from the melody
;
; The bolt "rides" hidden inside the player when idle (drawn after it,
; white ORs over cyan), launches from there on an edge-triggered space
; press, and returns to riding when it leaves the top of the screen.
;
; Sprite records grew a height field (spr_hgt, stores rows-1) so the bolt
; can be 8x6 while player/bouncers are 8x16.
;
; Assemble: vasmm68k_mot -m68008 -Fbin -o game8_bin game8.asm

; hardware (pc_ipcwr/pc_ipcrd come from the included libs)
mc_stat     equ     $18063          ; ZX8301 display control (write-only)
mc__m256    equ     %1000           ; bit 3: 256-pixel / 8-colour mode
pc_intr     equ     $18021          ; ZX8302 interrupt register
pc__frame   equ     3               ; bit 3 = 50/60 Hz frame interrupt

scr0        equ     $20000          ; screen 0 (displayed at boot)
scr1        equ     $28000          ; screen 1 (ex-QDOS sysvars, now ours)
scr_llen    equ     128             ; bytes per scan line

spr_w       equ     8               ; all sprites 8 mode 8 pixels wide
sx_max      equ     256-spr_w       ; bounce/clamp limits (top-left position)
sy_max      equ     256-16          ; for the 16-row sprites

; sprite record layout
spr_x       equ     0               ; position
spr_y       equ     2
spr_dx      equ     4               ; velocity (player: unused; bolt: dy<0 =
spr_dy      equ     6               ;   flying, dy=0 = riding the player)
spr_col     equ     8               ; +8 green-byte pattern, +9 red-byte
spr_px      equ     10              ; previous position per buffer:
                                    ;   +0/+2 buffer 0, +4/+6 buffer 1
spr_hgt     equ     18              ; height in rows, stored as rows-1
spr_size    equ     20

nspr        equ     8               ; 0 player, 1 bolt, 2..7 bouncers

pl_speed    equ     2               ; player pixels/frame per held arrow
bolt_speed  equ     6               ; bolt pixels/frame upward

; headroom bar: the VBL wait loop counts its idle spins (one spin is a
; fixed slice of unused frame budget) and a green bar at the bottom of
; the screen shows last frame's count. Bar shrinking toward zero = frame
; nearly over budget (the music slows at the same moment). Tune hb_shift
; so the bar is near full width with the scene at rest.
hb_y        equ     252             ; bar top line (2 rows tall)
hb_shift    equ     4               ; idle count -> bar groups (max 64);
                                    ; calibrated: a fully idle frame spins
                                    ; ~1000x (video contention roughly
                                    ; doubles the naive cycle estimate),
                                    ; showing ~62 of 64 groups
no_sprites  equ     0               ; 1 = skip sprite erase/draw entirely:
                                    ; gauge calibration (input, melody and
                                    ; the bar itself keep running)
no_music    equ     0               ; 1 = skip the melody player. Measured
                                    ; (Q-emuLator): sustained notes add no
                                    ; per-frame cost -- music's only cost is
                                    ; the ~2 ms beep transfer per note, a
                                    ; visible one-frame dip of the bar (try
                                    ; space-fire). Real HW may differ (the
                                    ; 8049 also synthesizes the tone).

; colour plane patterns (F bits kept 0 -- no hardware flash)
pat_g       equ     %10101010
pat_r       equ     %10101010
pat_b       equ     %01010101

; sprite <x>,<y>,<dx>,<dy>,<gpat>,<rpat>,<height> -- one sprite record
sprite      macro
        dc.w    \1,\2,\3,\4
        dc.b    \5,\6
        dc.w    0,0,0,0             ; prev positions, set at runtime
        dc.w    \7-1                ; height as rows-1 (dbf count)
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
        dc.b    'Game8'
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
        ifeq    no_sprites
        lea     sprites(pc),a5      ; pass 1: erase every sprite from the
        moveq   #nspr-1,d6          ; back buffer (positions of 2 frames ago)
.erase: bsr     spr_erase
        lea     spr_size(a5),a5
        dbf     d6,.erase
        endc

; ----- input: one IPC round trip for arrows + space
        moveq   #key_row1,d0
        bsr     kbd_row             ; d0.b = row-1 key bits
        lea     kbd_prev(pc),a2
        move.b  (a2),d3             ; previous frame's bits (edge detect)
        move.b  d0,(a2)

; ----- player (record 0): held arrows move, clamped to the screen
        lea     sprites(pc),a5
        move.w  spr_x(a5),d2
        btst    #k1__left,d0
        beq.s   .nl
        subq.w  #pl_speed,d2
.nl:    btst    #k1__right,d0
        beq.s   .nr
        addq.w  #pl_speed,d2
.nr:    tst.w   d2
        bge.s   .ncl
        moveq   #0,d2
.ncl:   cmp.w   #sx_max,d2
        ble.s   .ncr
        move.w  #sx_max,d2
.ncr:   move.w  d2,spr_x(a5)
        move.w  spr_y(a5),d2
        btst    #k1__up,d0
        beq.s   .nu
        subq.w  #pl_speed,d2
.nu:    btst    #k1__down,d0
        beq.s   .nd
        addq.w  #pl_speed,d2
.nd:    tst.w   d2
        bge.s   .nct
        moveq   #0,d2
.nct:   cmp.w   #sy_max,d2
        ble.s   .ncb
        move.w  #sy_max,d2
.ncb:   move.w  d2,spr_y(a5)

; ----- bolt (record 1): rides the player until fired, then flies up
        lea     spr_size(a5),a1
        tst.w   spr_dy(a1)
        bne.s   .flying
        move.w  spr_x(a5),spr_x(a1) ; idle: hidden inside the player
        move.w  spr_y(a5),spr_y(a1) ; (drawn after it -- white ORs over cyan)
        btst    #k1__spc,d0         ; fire on space edge (now, not before)
        beq.s   .boltdone
        btst    #k1__spc,d3
        bne.s   .boltdone
        move.w  #-bolt_speed,spr_dy(a1)
        lea     sfx_laser(pc),a3    ; zap -- borrows the sound channel;
        bsr     snd_beep            ; melody resumes at its next event
        bra.s   .boltdone
.flying:
        move.w  spr_y(a1),d0
        add.w   spr_dy(a1),d0
        bge.s   .fly
        clr.w   spr_dy(a1)          ; left the top: back to riding
        bra.s   .boltdone
.fly:   move.w  d0,spr_y(a1)
.boltdone:

; ----- bouncers (records 2..10)
        lea     sprites+2*spr_size(pc),a5
        moveq   #nspr-3,d6
.bounce:
        bsr     spr_move
        lea     spr_size(a5),a5
        dbf     d6,.bounce

; ----- draw everything into the back buffer, remember positions
        bsr     draw_hbar           ; headroom bar first, sprites over it
        ifeq    no_sprites
        lea     sprites(pc),a5
        moveq   #nspr-1,d6
.draw:  bsr     spr_draw
        move.w  d7,d0               ; prev[back] = position just drawn
        add.w   d0,d0
        add.w   d0,d0
        lea     spr_px(a5),a1
        adda.w  d0,a1
        move.w  spr_x(a5),(a1)+
        move.w  spr_y(a5),(a1)
        lea     spr_size(a5),a5
        dbf     d6,.draw
        endc

        ifeq    no_music
        bsr     mel_tick            ; advance the melody (usually a no-op)
        endc

; ----- sync: honest headroom accounting. If the frame bit is ALREADY
; pending, a VBL fired during processing: we overran. Report zero and
; carry on immediately (waiting for yet another edge would halve the
; frame rate); otherwise count idle spins until the edge arrives.
        moveq   #0,d0
        btst    #pc__frame,pc_intr
        bne.s   .late               ; missed the VBL: zero headroom
.wait:  addq.l  #1,d0               ; count the idle spin = headroom
        btst    #pc__frame,pc_intr
        beq.s   .wait
.late:  lea     headroom(pc),a2
        move.l  d0,(a2)
        move.b  #1<<pc__frame,pc_intr   ; ack, arming the next frame's test

        move.w  d7,d0               ; flip: display the buffer just drawn
        ror.b   #1,d0
        or.b    #mc__m256,d0        ; the mode bit rides along every write
        move.b  d0,mc_stat
        eori.w  #1,d7               ; other buffer becomes the back buffer
        bra     frame_loop

; -------------------------------------------------------------- headroom bar
; Draw last frame's idle count as a green bar into the back buffer (a4):
; two rows at hb_y, scaled by hb_shift, clamped to the full 64 groups.
; The unlit remainder is written black, so the bar self-erases.
draw_hbar:
        lea     headroom(pc),a1
        move.l  (a1),d0
        lsr.l   #hb_shift,d0
        cmp.w   #64,d0
        bls.s   .clip
        moveq   #64,d0
.clip:  lea     hb_y*scr_llen(a4),a0
        moveq   #2-1,d3
.row:   move.w  d0,d1               ; lit groups
        moveq   #64,d2
        sub.w   d0,d2               ; dark groups
        tst.w   d1
        beq.s   .dark
        subq.w  #1,d1
.lit:   move.b  #pat_g,(a0)+        ; green
        clr.b   (a0)+
        dbf     d1,.lit
.dark:  tst.w   d2
        beq.s   .next
        subq.w  #1,d2
.drk:   clr.b   (a0)+
        clr.b   (a0)+
        dbf     d2,.drk
.next:  dbf     d3,.row             ; 128 bytes written = already next line
        rts

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
; Same mode 8 pipeline as flip8, with the row count taken from the record
; (spr_hgt) instead of a constant. See flip8/flip8.asm for the mask maths.

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

; spr_draw: draw sprite (a5) into buffer a4. Preserves d6.
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
        move.w  spr_hgt(a5),d6
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
        move.w  spr_hgt(a5),d5
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
kbd_prev:
        dc.b    0                   ; row-1 bits from the previous frame
        even
headroom:
        dc.l    0                   ; idle spins in last frame's VBL wait
mel_state:
        dc.w    0                   ; frames left (armed at runtime)
        dc.l    0                   ; pointer to next event (set at runtime)

sfx_laser:                          ; descending zap for the bolt launch
        dc.b    5,80                ; fast sweep pitch pair
        dc.b    2,0                 ; interval = 2 (lo,hi)
        dc.b    $00,$04             ; duration = $0400 (lo,hi) ~ 74 ms
        dc.b    $10                 ; gradient = 1, wrap = 0
        dc.b    $00                 ; random = 0, fuzz = 0

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

; player, bolt, then six bouncers -- with the white player that covers
; all seven visible colours (black is the background; on-black
; OR-blitting cannot show a black sprite, and that is fine)
sprites:
        sprite  124,224, 0,0,   pat_g,pat_r|pat_b, 16  ; player, white
        sprite  124,224, 0,0,   pat_g,pat_b,       6   ; bolt, cyan
        sprite  240,16,  -1,2,  pat_g,pat_r,       16  ; yellow
        sprite  20,180,  3,-1,  pat_g,0,           16  ; green
        sprite  150,60,  -2,-2, pat_g,pat_b,       16  ; cyan
        sprite  100,120, 1,3,   0,pat_r,           16  ; red
        sprite  60,200,  -3,1,  0,pat_r|pat_b,     16  ; magenta
        sprite  210,190, 2,-3,  0,pat_b,           16  ; blue

        even
sv_stack:
        ds.b    64                  ; private supervisor stack
sv_stack_top:

; libs: sound first (keys uses its ipc_nib/ipc_rdbyte)
        include "../lib/ipc_sound_takeover.asm"
        include "../lib/ipc_keys_takeover.asm"
