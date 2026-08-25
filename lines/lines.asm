; lines.asm -- line-drawing throughput benchmark (vector graphics, step 1)
;
; How many line-pixels can the 68008 draw per 20 ms frame? First stone on
; the road to 3D: this rig draws lines *continuously* from a fixed table
; (a fan from screen centre to points walked along the border -- every
; octant, plus exact horizontal/vertical/diagonal cases) and counts what
; fits between VBLs. No tuning loop: the rig self-throttles.
;
; MODE 4 (512x256), full takeover, single screen, no erase: lines OR into
; the green plane only (one RMW per pixel -- white would double the
; writes) and the fan is idempotent, so screen 0 alone suffices.
;
; Readout (green blocks at the bottom, below the fan area):
;   rows 244-246: PIXELS per frame  } 16-bit binary, MSB on the left,
;   rows 250-253: LINES  per frame  } one 8-px cell per bit, lit = 1;
;                                     the dashed ruler under each value
;                                     marks the 16 cell positions
; Both values are averages over a 256-frame (~5 s) window, so the display
; is steady and partial-line jitter at the VBL edge is smoothed out.
;
; The line drawer is the BASELINE: classic Bresenham, correctness first
; but idiomatic -- endpoints swapped so x-major lines always step right
; and y-major lines always step down (3 inner loops), screen address and
; bit mask kept incrementally, never recomputed per pixel. Optimized
; variants (fixed-point slope, byte-combining, unrolling) come later and
; are measured against this same rig.
;
; Assemble: vasmm68k_mot -m68008 -Fbin -o lines_bin lines.asm

; hardware
mc_stat     equ     $18063          ; ZX8301 display control (write-only)
pc_intr     equ     $18021          ; ZX8302 interrupt register
pc__frame   equ     3               ; bit 3 = 50/60 Hz frame interrupt

scr0        equ     $20000          ; screen 0 (the only one we use)
scr_llen    equ     128             ; bytes per scan line

; fan geometry: centre -> border points, border walked in steps of 16.
; The bottom border stops at y=239 so the fan never touches the readout.
cx          equ     256             ; fan centre
cy          equ     120
fan_bot     equ     239             ; fan's bottom border line

; readout layout (green plane): 16 cells x 8 px = 128 px, centred
ro_x        equ     (192/8)*2                   ; byte offset of x=192
ro_pix      equ     244*scr_llen+ro_x           ; pixels/frame counter
ro_lin      equ     250*scr_llen+ro_x           ; lines/frame counter
ro_cell     equ     %11111100                   ; 6 px block + 2 px gap

avg_frames  equ     256             ; readout averaging window (power of 2).
avg_shift   equ     8               ; 256 frames ~ 5 s per update: a window
                                    ; spans ~12 full fan cycles, so the
                                    ; changing fan phase between windows
                                    ; (which made a 32-frame average
                                    ; visibly wander) washes out

; ---------------------------------------------------------------- job header
start:
        bra.s   main
        dc.l    0
        dc.w    $4afb               ; "job name follows" flag
        dc.w    jobname_e-jobname
jobname:
        dc.b    'Lines'
jobname_e:
        even

; ----------------------------------------------------------------- take over
main:
        trap    #0                  ; QDOS: enter supervisor mode
        move.w  #$2700,sr           ; mask all interrupts -- QDOS is gone now
        lea     sv_stack_top(pc),sp ; run on our own supervisor stack

        move.b  #0,mc_stat          ; mode 4, screen 0 displayed

        lea     scr0,a0             ; clear both screens ($20000-$2FFFF);
        move.w  #$10000/4-1,d0      ; screen 1 is unused but the sysvars
        moveq   #0,d1               ; under it are dead weight anyway
.clr:   move.l  d1,(a0)+
        dbf     d0,.clr

        lea     scr0,a4             ; a4 = screen base for everything
        lea     fan(pc),a3          ; a3 = current line, round-robin
        lea     fan_end(pc),a5      ; a5 = table sentinel
        moveq   #0,d6               ; d6 = pixel count, this window
        moveq   #0,d7               ; d7 = line count, this window
        move.b  #1<<pc__frame,pc_intr   ; discard any pending frame bit

; ---------------------------------------------------------------- bench loop
; Draw lines forever; the frame bit is tested between lines only (a
; per-pixel test would wreck the inner loops), so counts jitter by up to
; one line per frame -- the 32-frame average absorbs that.
bench:
.line:  bsr     draw_line           ; draws *a3, advances a3, d6 += pixels
        addq.w  #1,d7
        cmpa.l  a5,a3
        blo.s   .nf
        lea     fan(pc),a3          ; wrap the table
.nf:    btst    #pc__frame,pc_intr  ; VBL yet?
        beq.s   .line

        move.b  #1<<pc__frame,pc_intr   ; ack at once: next frame is timing
        lea     wnd_cnt(pc),a0
        subq.w  #1,(a0)
        bne.s   .line               ; window still open: keep drawing
        move.w  #avg_frames,(a0)

        move.l  d6,d0               ; latch window averages
        lsr.l   #avg_shift,d0       ; d0 = pixels/frame
        move.w  d7,d3
        lsr.w   #avg_shift,d3       ; d3 = lines/frame
        moveq   #0,d6
        moveq   #0,d7
        lea     ro_pix(a4),a0
        bsr     draw_readout
        move.w  d3,d0
        lea     ro_lin(a4),a0
        bsr     draw_readout
        bra     .line

; --------------------------------------------------------- baseline Bresenham
; draw_line: draw the green-plane line described at (a3) into screen a4,
; advance a3 past the record, add the pixel count to d6.
; Record: dc.w x1,y1,x2,y2. Preserves d6 (accumulates), d7, a3-a5.
;
; Endpoint normalization leaves three inner loops:
;   x-major             always steps right; y minor step = +-128 via a1
;   y-major, x right    always steps down;  ror mask, carry -> next word
;   y-major, x left     always steps down;  rol mask, carry -> prev word
; The screen address (a0) and single-bit mask (d4) advance incrementally:
;   green byte = base + y*128 + (x>>3)*2, bit 7-(x&7)
; Each loop plots first, then steps, so the extra step after the final
; pixel touches registers only -- never memory.
draw_line:
        move.w  (a3)+,d0            ; x1
        move.w  (a3)+,d1            ; y1
        move.w  (a3)+,d2            ; x2
        move.w  (a3)+,d3            ; y2
        sub.w   d0,d2               ; d2 = dx
        sub.w   d1,d3               ; d3 = dy
        move.w  d2,d4
        bge.s   .adx
        neg.w   d4                  ; d4 = |dx|
.adx:   move.w  d3,d5
        bge.s   .ady
        neg.w   d5                  ; d5 = |dy|
.ady:   cmp.w   d4,d5
        bgt     ymajor              ; |dy| > |dx| (ties go x-major)

; ----- x-major: normalize to left->right, minor y step sign in a1
        tst.w   d2
        bge.s   .nsw
        add.w   d2,d0               ; swap endpoints: start at the left one
        add.w   d3,d1
        neg.w   d3                  ; dy flips with the swap
.nsw:   move.w  #scr_llen,a1        ; minor step: down...
        tst.w   d3
        bge.s   .sdn
        move.w  #-scr_llen,a1       ; ...or up
.sdn:   lsl.w   #7,d1               ; y*128 (max 239*128, fits signed)
        move.w  d0,d2
        lsr.w   #3,d2
        add.w   d2,d2               ; (x>>3)*2: green byte offset
        add.w   d2,d1
        lea     (a4,d1.w),a0        ; max offset 30640, fits signed word
        and.w   #7,d0
        move.b  #$80,d2
        lsr.b   d0,d2               ; d2 = bit mask, bit 7-(x&7)
        move.w  d4,d0               ; d0 = loop count (|dx| -> |dx|+1 px)
        move.w  d4,d1
        add.w   d1,d1               ; d1 = 2|dx| (error decrement)
        move.w  d4,d3
        neg.w   d3                  ; d3 = error, starts at -|dx|
        move.b  d2,d4               ; d4 = mask
        move.w  d5,d2
        add.w   d2,d2               ; d2 = 2|dy| (error increment)
        moveq   #0,d5               ; account |dx|+1 pixels
        move.w  d0,d5
        addq.l  #1,d5
        add.l   d5,d6
.xl:    or.b    d4,(a0)             ; plot
        add.w   d2,d3               ; err += 2|dy|
        bmi.s   .ny
        adda.w  a1,a0               ; y minor step (+-128)
        sub.w   d1,d3               ; err -= 2|dx|
.ny:    ror.b   #1,d4               ; x step right; bit 0 wraps -> carry
        bcc.s   .nx
        addq.l  #2,a0               ; next word's green byte
.nx:    dbf     d0,.xl
        rts

; ----- y-major: normalize to top->bottom, then split on x direction
ymajor: tst.w   d3
        bge.s   .nsw
        add.w   d2,d0               ; swap endpoints: start at the top one
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
        lsr.b   d0,d3               ; d3 = bit mask (parked)
        move.w  d5,d0               ; d0 = loop count (|dy| -> |dy|+1 px)
        move.w  d5,d1
        add.w   d1,d1               ; d1 = 2|dy| (error decrement)
        neg.w   d5                  ; d5 = error, starts at -|dy|
        tst.w   d2                  ; which way does x step?
        bmi.s   ymajl
        add.w   d2,d2               ; d2 = 2|dx| (error increment)
        move.b  d3,d4               ; d4 = mask
        move.w  d5,d3               ; d3 = error
        moveq   #0,d5               ; account |dy|+1 pixels
        move.w  d0,d5
        addq.l  #1,d5
        add.l   d5,d6
.yr:    or.b    d4,(a0)             ; plot
        add.w   d2,d3               ; err += 2|dx|
        bmi.s   .nx
        ror.b   #1,d4               ; x minor step right
        bcc.s   .nc
        addq.l  #2,a0
.nc:    sub.w   d1,d3               ; err -= 2|dy|
.nx:    lea     scr_llen(a0),a0     ; y major step, unconditional
        dbf     d0,.yr
        rts

ymajl:  neg.w   d2
        add.w   d2,d2               ; d2 = 2|dx| (error increment)
        move.b  d3,d4               ; d4 = mask
        move.w  d5,d3               ; d3 = error
        moveq   #0,d5               ; account |dy|+1 pixels
        move.w  d0,d5
        addq.l  #1,d5
        add.l   d5,d6
.yl:    or.b    d4,(a0)             ; plot
        add.w   d2,d3               ; err += 2|dx|
        bmi.s   .nx
        rol.b   #1,d4               ; x minor step left
        bcc.s   .nc
        subq.l  #2,a0
.nc:    sub.w   d1,d3               ; err -= 2|dy|
.nx:    lea     scr_llen(a0),a0     ; y major step, unconditional
        dbf     d0,.yl
        rts

; ------------------------------------------------------------ binary readout
; draw_readout: value d0.w as 16 cells at green-plane address a0, MSB
; first; two value rows, then a dashed ruler row marking the cells.
; Trashes d0-d2, a0. Unlit cells are written black, so it self-erases.
draw_readout:
        moveq   #16-1,d2
.cell:  moveq   #0,d1
        add.w   d0,d0               ; MSB out into carry
        bcc.s   .un
        move.b  #ro_cell,d1         ; lit cell pattern
.un:    move.b  d1,(a0)
        move.b  d1,scr_llen(a0)
        move.b  #ro_cell,2*scr_llen(a0)
        addq.l  #2,a0               ; next cell (skip the red byte)
        dbf     d2,.cell
        rts

; ---------------------------------------------------------------------- data
        even
wnd_cnt:
        dc.w    avg_frames          ; frames left in the averaging window

; fan table, generated at assembly time: centre -> border points.
; Top and bottom borders x = 0,16,..,496; left and right borders
; y = 16,32,..,224 (corners already covered). 92 lines, dc.w x1,y1,x2,y2.
fan:
_fx     set     0
        rept    32
        dc.w    cx,cy,_fx,0         ; to the top border
        dc.w    cx,cy,_fx,fan_bot   ; to the bottom border
_fx     set     _fx+16
        endr
_fy     set     16
        rept    14
        dc.w    cx,cy,0,_fy         ; to the left border
        dc.w    cx,cy,511,_fy       ; to the right border
_fy     set     _fy+16
        endr
fan_end:

        even
sv_stack:
        ds.b    64                  ; private supervisor stack
sv_stack_top:
