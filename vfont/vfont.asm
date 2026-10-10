; vfont.asm -- rig for the vector font: lib/draw_text.asm, lib/vfont.inc
;
; Takes the machine over (docs/takeover.md), clears screen 0 and draws
; what the STARQLIDER beta will write: a mock-up of the title screen in
; strokes (draw_text: the title white at k = 2, the rest green at
; k = 1), the whole character set at k = 1, and the HUD digits along
; the top (draw_bcd). Then it idles: make shot reads the screen.
; Nothing moves and nothing reads the keyboard; the font itself is
; edited in tools/genfont.py (make preview: its own rendering).
;
; Assemble: make (vasmm68k_mot -m68008 -Fbin -o vfont_bin vfont.asm)

mc_stat     equ     $18063          ; ZX8301 display control (write-only)
pc_intr     equ     $18021          ; ZX8302 interrupt register
pc__frame   equ     3               ; bit 3 = 50/60 Hz frame interrupt
scr0        equ     $20000          ; screen 0
scr_llen    equ     128             ; bytes per scan line

; ---------------------------------------------------------------- job header
start:
        bra.s   main
        dc.l    0
        dc.w    $4afb               ; "job name follows" flag
        dc.w    jobname_e-jobname
jobname:
        dc.b    'VFont'
jobname_e:
        even

; ---------------------------------------------------------------------- main
main:
        trap    #0                  ; QDOS: enter supervisor mode
        move.w  #$2700,sr           ; mask all interrupts -- QDOS is gone
        lea     sv_stack_top(pc),sp
        move.b  #0,mc_stat          ; mode 4, screen 0 displayed
        lea     scr0,a0
        move.w  #$8000/4-1,d0
        moveq   #0,d1
.clr:   move.l  d1,(a0)+
        dbf     d0,.clr

; The texts go one character at a time, polling the frame interrupt
; between characters (each takes well under a 20 ms frame), so frames
; counts the frames the drawing took: make shot PEEK="frames:w*2"
; (the title line, then everything).
        lea     scr0,a4             ; the text lines (texts below)
        lea     texts(pc),a2
        move.b  #1<<pc__frame,pc_intr   ; drop a pending frame bit
.ln:    move.w  (a2)+,d0            ; x (-1 ends the list)
        bmi.s   .hud
        lea     line(pc),a3
        move.w  d0,(a3)+            ; x
        move.w  (a2)+,(a3)+         ; y
        move.w  (a2)+,(a3)+         ; x unit
        move.w  (a2)+,(a3)+         ; y unit
        move.w  (a2)+,(a3)+         ; colour
.chr:   lea     chbuf(pc),a0
        move.b  (a2)+,(a0)          ; one character, then the 0 of chbuf
        beq.s   .eol
        lea     line(pc),a3
        movem.w (a3),d0-d4
        bsr     draw_text
        lea     line(pc),a3
        move.w  4(a3),d0            ; the next cell
        mulu.w  #vf_adv,d0
        add.w   d0,(a3)
        btst    #pc__frame,pc_intr
        beq.s   .chr
        move.b  #1<<pc__frame,pc_intr
        lea     frames+2(pc),a3
        addq.w  #1,(a3)
        bra.s   .chr
.eol:   lea     frames(pc),a3       ; the title's frames, once
        tst.w   (a3)
        bne.s   .al
        move.w  2(a3),(a3)
        addq.w  #1,(a3)             ; (+1: nonzero even when none)
.al:    move.l  a2,d0               ; to the next even address
        addq.l  #1,d0
        and.b   #$fe,d0
        move.l  d0,a2
        bra.s   .ln

.hud:   lea     scr0+8*scr_llen+16/4,a0 ; HUD digits at x 16, row 8
        lea     bcd_all(pc),a1
        moveq   #5,d0
        bsr     draw_bcd
        lea     scr0+8*scr_llen+400/4,a0 ; a score with leading zeros
        lea     bcd_score(pc),a1        ; blank, at x 400 (spec 5.4:
        moveq   #3,d0                   ; top right)
        bsr     draw_bcd
.idle:  bra.s   .idle

; ---------------------------------------------------------------- the texts
; Each line: x, y, x unit, y unit, colour, then the string.

; txt: a centred line's header -- data only, so no register contract:
; \1 = characters, \2 = px per grid unit across (rows: 2/3 of it), \3 =
; y, \4 = colour. x centres the string: 256 - (n*vf_adv - 2)*unit/2.
txt     macro
        dc.w    256-((\1)*vf_adv-2)*(\2)/2,\3,\2,(\2)*2/3,\4
        endm

texts:  txt     10,6,36,col_white
        dc.b    'STARQLIDER',0
        even
        txt     6,3,72,col_green
        dc.b    'BETA 1',0
        even
        txt     26,3,100,col_green
        dc.b    'DESTROY ALL WHITE CRYSTALS',0
        even
        txt     25,3,120,col_green
        dc.b    'ARROWS STEER  SPACE FIRES',0
        even
        txt     11,3,148,col_green
        dc.b    'PRESS SPACE',0
        even
        txt     9,3,176,col_green
        dc.b    'HI 012500',0
        even
        txt     26,3,204,col_green
        dc.b    'ABCDEFGHIJKLMNOPQRSTUVWXYZ',0
        even
        txt     15,3,226,col_green
        dc.b    '0123456789 -.:/',0
        even
        dc.w    -1

line:   ds.w    5                   ; the line being drawn: x, y, units, colour
frames: dc.w    0,0                 ; frames drawing the title (+1), all
chbuf:  dc.b    0,0                 ; one character for draw_text
bcd_all:
        dc.b    $01,$23,$45,$67,$89 ; 0123456789
bcd_score:
        dc.b    $00,$25,$00         ; "  2500"
        even

; ----------------------------------------------------------------- the stack
sv_stack:
        ds.b    256
sv_stack_top:

        include "../lib/draw_text.asm"
        include "../lib/vfont.inc"
        include "../lib/draw_line_w.asm"
        include "../lib/draw_line.asm"
