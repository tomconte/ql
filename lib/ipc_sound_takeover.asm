; ============================================================================
; Direct IPC sound access for the Sinclair QL -- TAKEOVER VARIANT
; ----------------------------------------------------------------------------
; Derived from sound_test/ipc_sound.asm (which keeps the original,
; QDOS-cohabiting version). This variant assumes the machine has been fully
; taken over with all interrupts masked, so snd_clrint -- whose only job was
; to clear the IPC level-2 interrupt for QDOS's handler, using QDOS's mask
; shadow at sysvar $35(a6) -- is gone, along with the a6 requirement. That
; matters because the double-buffered demos reuse the sysvars area ($28000)
; as screen 1. The example note/effect tables are dropped too; melodies
; live in the including file. Shared by the flip/flip8/game8 projects
; (include with "../lib/ipc_sound_takeover.asm"). Unlike the original this
; file does NOT end with an "end" directive, so other lib files may be
; included after it -- lib/ipc_keys_takeover.asm depends on the ipc_nib
; and ipc_rdbyte routines below and must come AFTER this file.
;
; Protocol notes (see the original for the full story):
;   Send:    write %11d0 to $18003 (d = data bit, MSB first), then poll
;            bit 6 of $18020 until it drops = 8049 has taken the bit.
;   Receive: write %1110 to $18003 (must assert 1 to read), poll bit 6
;            of $18020, then bit 7 of $18020 is the data bit. MSB first.
;   Sound command ($A) takes exactly 64 bits after the command nibble;
;   get the count wrong and the 8049 hangs until reset.
;   Budget: a full beep is ~68 bit transactions, on the order of 2 ms.
; ============================================================================

pc_ipcwr equ    $18003          ; W: bit1=COMDATA, bits 2,3=1, bit0=0
pc_ipcrd equ    $18020          ; R: bit6=busy, bit7=data from IPC

inso_cmd equ    10              ; start sound
kiso_cmd equ    11              ; kill sound
stat_cmd equ    1               ; read status (bit1 = sound playing)

; ----------------------------------------------------------------------------
; snd_beep - start a sound. The 8049 keeps playing it on its own.
; In:      a3 -> 8-byte parameter block (one of your note/effect tables):
;            +0  pitch1 (already +1)
;            +1  pitch2 (already +1)
;            +2  interval low byte    +3  interval high byte
;            +4  duration low byte    +5  duration high byte
;            +6  gradient<<4 | wrap
;            +7  random<<4  | fuzz
; Out:     a3 = past the block (+8)
; Trashes: d0-d2
; ----------------------------------------------------------------------------
snd_beep
        move    sr,-(sp)
        ori     #$0700,sr       ; own the link exclusively
        moveq   #inso_cmd,d0
        bsr.s   ipc_nib         ; command nibble $A
        moveq   #6-1,d2
.bytes  move.b  (a3)+,d0
        bsr.s   ipc_byte        ; pitch1,pitch2,int_lo,int_hi,dur_lo,dur_hi
        dbf     d2,.bytes
        move.b  (a3)+,d0        ; gradient / wrap
        bsr.s   ipc_byte        ;   (two nibbles = one byte send)
        move.b  (a3)+,d0        ; random / fuzz
        bsr.s   ipc_byte
        move    (sp)+,sr
        rts

; ----------------------------------------------------------------------------
; snd_kill - stop sound immediately. 4 bit transactions only.
; In:      none
; Out:     none
; Trashes: d0, d1
; ----------------------------------------------------------------------------
snd_kill
        move    sr,-(sp)
        ori     #$0700,sr
        moveq   #kiso_cmd,d0
        bsr.s   ipc_nib
        move    (sp)+,sr
        rts

; ----------------------------------------------------------------------------
; snd_stat - read the IPC status byte. Costs a full round trip (~12 bit
; transactions); counting frames against the duration you sent is
; usually cheaper in a game loop.
; In:      none
; Out:     d0.b = status, bit 1 set = sound still playing
; Trashes: d1, d2
; ----------------------------------------------------------------------------
snd_stat
        move    sr,-(sp)
        ori     #$0700,sr
        moveq   #stat_cmd,d0
        bsr.s   ipc_nib
        bsr.s   ipc_rdbyte
        move    (sp)+,sr
        rts

; ----------------------------------------------------------------------------
; ipc_rdbyte - read one byte from the IPC, MSB first. Interrupts must
; already be masked.
; In:      none
; Out:     d0.b = the byte (d0.l = 0..255)
; Trashes: d1, d2
; ----------------------------------------------------------------------------
ipc_rdbyte
        moveq   #0,d0
        moveq   #8-1,d2
.rd     move.b  #%1110,pc_ipcwr ; assert 1 so the IPC can pull the line
.wait   btst    #6,pc_ipcrd
        bne.s   .wait
        move.b  pc_ipcrd,d1
        add.b   d1,d1           ; bit7 -> X
        addx.b  d0,d0           ; shift into result, MSB first
        dbf     d2,.rd
        rts

; ----------------------------------------------------------------------------
; ipc_byte - send d0.b to the IPC, MSB first (as two nibbles, the low one
; by falling into ipc_nib). Interrupts must already be masked.
; In:      d0.b = the byte
; Out:     none
; Trashes: d0, d1
; ----------------------------------------------------------------------------
ipc_byte
        move.b  d0,-(sp)
        lsr.b   #4,d0
        bsr.s   ipc_nib         ; high nibble
        move.b  (sp)+,d0        ; low nibble falls through
; ipc_nib - send the low nibble of d0.b to the IPC. Interrupts must
; already be masked. Bit pattern per JS ROM L02F7C: shift nibble to bits
; 7..4, OR in bit 3 as an end marker, then shift bits out until only the
; marker is left.
; In:      d0.b = the nibble (low 4 bits)
; Out:     none
; Trashes: d0, d1
ipc_nib
        lsl.b   #4,d0           ; nibble to bits 7..4 (junk above discarded)
        ori.b   #%00001000,d0   ; end marker in bit 3
.bit    lsl.b   #1,d0           ; next data bit -> X
        beq.s   .done           ; only the marker was left: all 4 bits sent
        moveq   #%11,d1
        roxl.b  #1,d1           ; %011d
        lsl.b   #1,d1           ; %11d0
        move.b  d1,pc_ipcwr
.wait   btst    #6,pc_ipcrd     ; wait for the 8049 to take the bit
        bne.s   .wait
        bra.s   .bit
.done   rts
