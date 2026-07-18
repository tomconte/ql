; takeover.asm -- full machine takeover demo for the Sinclair QL
;
; Starts life as a normal QDOS job (EXECable), then takes the machine away
; from QDOS: enters supervisor mode via TRAP #0, masks all interrupts, and
; from then on owns the hardware. Draws a 4x4 white dot bouncing around the
; mode 4 screen, moving one step per 50 Hz frame (VBL-synced by polling the
; ZX8302 frame-interrupt bit). There is no way back: reset (or close the
; emulator) to exit. Background and references: docs/takeover.md.
;
; Assemble: vasmm68k_mot -m68008 -Fbin -o takeover_bin takeover.asm

; hardware registers (values from the Minerva ROM sources, inc/mc and inc/pc)
mc_stat     equ     $18063          ; ZX8301 display control (write-only):
                                    ;   bit 1 blank, bit 3 mode (0=512px/4col),
                                    ;   bit 7 screen base; others must be 0
pc_intr     equ     $18021          ; ZX8302 interrupt register: read = pending
                                    ;   bits 4..0, write a set bit to clear it
pc__frame   equ     3               ; bit 3 = 50/60 Hz frame interrupt

scr_base    equ     $20000          ; mode 4 screen: 512x256, 2bpp, 32 KB
scr_llen    equ     128             ; bytes per scan line
scr_size    equ     $8000

dot_w       equ     4               ; dot size in pixels
dot_h       equ     4
x_max       equ     512-dot_w       ; bounce limits (top-left position)
y_max       equ     256-dot_h

; ---------------------------------------------------------------- job header
start:
        bra.s   main
        dc.l    0
        dc.w    $4afb               ; "job name follows" flag
        dc.w    jobname_e-jobname
jobname:
        dc.b    'Takeover'
jobname_e:
        even

; ----------------------------------------------------------------- take over
main:
        trap    #0                  ; QDOS: enter supervisor mode
        move.w  #$2700,sr           ; mask all interrupts -- QDOS is gone now
        lea     sv_stack_top(pc),sp ; run on our own supervisor stack

        move.b  #0,mc_stat          ; mode 4, screen at $20000, display on

        lea     scr_base,a0         ; clear the screen to black
        move.w  #scr_size/4-1,d0
        moveq   #0,d1
.clr:   move.l  d1,(a0)+
        dbf     d0,.clr

        moveq   #0,d4               ; x position
        moveq   #0,d5               ; y position
        moveq   #2,d6               ; x speed, pixels/frame (even: hits x_max)
        moveq   #1,d7               ; y speed, pixels/frame

; ---------------------------------------------------------------- frame loop
main_loop:
        move.b  #1<<pc__frame,pc_intr   ; ack frame interrupt
.wait:  btst    #pc__frame,pc_intr     ; ...and wait for the next one
        beq.s   .wait                   ; (test bit 3 only: bits 7..5 are
                                        ; clock/mdv/baud state, always moving)

        bsr     erase               ; remove dot at old position

        add.w   d6,d4               ; step and bounce horizontally
        tst.w   d4
        beq.s   .flipx
        cmp.w   #x_max,d4
        bne.s   .xok
.flipx: neg.w   d6
.xok:
        add.w   d7,d5               ; step and bounce vertically
        tst.w   d5
        beq.s   .flipy
        cmp.w   #y_max,d5
        bne.s   .yok
.flipy: neg.w   d7
.yok:
        bsr     draw                ; draw dot at new position
        bra.s   main_loop

; --------------------------------------------------------------- dot drawing
; The dot may straddle an 8-pixel word boundary, so build a 16-bit pixel
; mask and split it over two adjacent screen words. In mode 4 each word is
; [green byte][red byte]; setting both planes gives white.

; calcpos: d4/d5 (x/y) -> a0 = screen word address, d3.w = pixel mask
calcpos:
        move.w  d5,d0
        lsl.w   #7,d0               ; y * 128
        move.w  d4,d1
        lsr.w   #3,d1               ; 8-pixel group...
        add.w   d1,d1               ; ...2 bytes each
        add.w   d1,d0
        lea     scr_base,a0
        adda.w  d0,a0               ; max offset 32382, fits signed word
        move.w  #$f000,d3           ; dot_w pixels at the far left...
        move.w  d4,d2
        and.w   #7,d2
        lsr.w   d2,d3               ; ...shifted to x within the two words
        rts

draw:                               ; OR the mask into both colour planes
        bsr     calcpos
        move.w  d3,d2
        lsr.w   #8,d2               ; d2 = mask for first word, d3 = second
        moveq   #dot_h-1,d0
.row:   or.b    d2,(a0)             ; green plane, first word
        or.b    d2,1(a0)            ; red plane -> white
        or.b    d3,2(a0)            ; green plane, second word
        or.b    d3,3(a0)            ; red plane
        lea     scr_llen(a0),a0
        dbf     d0,.row
        rts

erase:                              ; AND the inverted mask: back to black
        bsr     calcpos
        not.w   d3
        move.w  d3,d2
        lsr.w   #8,d2
        moveq   #dot_h-1,d0
.row:   and.b   d2,(a0)
        and.b   d2,1(a0)
        and.b   d3,2(a0)
        and.b   d3,3(a0)
        lea     scr_llen(a0),a0
        dbf     d0,.row
        rts

; ---------------------------------------------------------------------- data
        even
sv_stack:
        ds.b    64                  ; private supervisor stack
sv_stack_top:
