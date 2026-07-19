; ============================================================================
; Direct IPC keyboard access for the Sinclair QL -- takeover only
; ----------------------------------------------------------------------------
; IPC command 9 (kbdr_cmd, "keyboard direct read") -- the KEYROW primitive:
; command nibble, one 4-bit parameter (row number), one byte reply with the
; raw state of that matrix row (1 = key held). Format verified against the
; QDOS/SMS Reference Guide sec. 13 and Minerva inc/ipcmd; matrix positions
; verified against the sQLux emulator key map (include/qlkeys.h).
;
; Requires lib/ipc_sound_takeover.asm to be included BEFORE this file
; (uses its ipc_nib and ipc_rdbyte).
;
; KEYROW reads the PHYSICAL matrix: letter positions differ on non-UK
; layouts (AZERTY swaps A/Q, W/Z...), but row 1 -- arrows, space, enter,
; esc -- is layout-independent, which is why the demos use it:
;
;   row 1 bits:  0=Enter 1=Left 2=Up 3=Esc 4=Right 5=\ 6=Space 7=Down
;
; Budget: ~16 bit transactions per row, well under a millisecond. Reading
; steals 8049 cycles from tone generation, so a slight warble on held
; notes is authentic hardware behaviour, not a bug.
; ============================================================================

kbdr_cmd    equ     9           ; read one keyboard row direct

key_row1    equ     1           ; the cursor/space/enter/esc row
k1__enter   equ     0           ; bit numbers within the row-1 reply
k1__left    equ     1
k1__up      equ     2
k1__esc     equ     3
k1__right   equ     4
k1__spc     equ     6
k1__down    equ     7

; ----------------------------------------------------------------------------
; kbd_row - read one keyboard matrix row.
; In:  d0.b = row number 0-7.  Out: d0.b = key bits, 1 = held.
; Trashes d1/d2.
; ----------------------------------------------------------------------------
kbd_row
        move    sr,-(sp)
        ori     #$0700,sr       ; own the link exclusively
        move.w  d0,-(sp)
        moveq   #kbdr_cmd,d0
        bsr     ipc_nib         ; command nibble
        move.w  (sp)+,d0
        bsr     ipc_nib         ; row-number nibble
        bsr     ipc_rdbyte      ; reply: key bits -> d0.b
        move    (sp)+,sr
        rts
