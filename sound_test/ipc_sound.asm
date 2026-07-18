; ============================================================================
; Direct IPC sound access for the Sinclair QL - no QDOS traps
; ----------------------------------------------------------------------------
; Protocol verified against:
;   - Minerva 1.98 sources: inc/ipcmd, inc/pc, ip/int.asm, bp/beep.asm
;   - JS ROM disassembly:   L02F6E / L02F7C / L02F8E (send), L02F96 (receive)
;   - IPC 8049 disassembly: IPCOM $A "set sound" at $0300, kill at $031F
;
; HOW THE LINK WORKS
;   Send:    write %11d0 to $18003 (d = data bit, MSB first), then poll
;            bit 6 of $18020 until it drops = 8049 has taken the bit.
;   Receive: write %1110 to $18003 (must assert 1 to read), poll bit 6
;            of $18020, then bit 7 of $18020 is the data bit. MSB first.
;   A command starts with a 4-bit command nibble, followed by however
;   many parameter bits that command requires. Get the count wrong and
;   the 8049 hangs until reset - there is no error recovery.
;
; SOUND COMMAND ($A) PARAMETER STREAM - exactly 64 bits after the nibble:
;   byte  pitch1          (BASIC pitch + 1)
;   byte  pitch2          (BASIC pitch2 + 1)
;   word  step interval   LSB BYTE FIRST
;   word  duration        LSB BYTE FIRST, 0 = play forever
;   nib   pitch gradient  (signed 4-bit step)
;   nib   wrap
;   nib   random          (none unless msb set)
;   nib   fuzz            (none unless msb set)
;   The 8049 then plays the sound AUTONOMOUSLY - no further CPU needed.
;
; RULES
;   - Interrupts MUST be masked around every transaction: the QDOS 50Hz
;     polling interrupt also talks to the IPC (keyboard) and interleaved
;     transfers corrupt the link.
;   - If QDOS is still running, clear the IPC interrupt at $18021 after
;     each transfer (see snd_clrint). If you have taken over the machine
;     with level-2 interrupts masked, you can skip it - but then you must
;     also read the keyboard yourself via IPC command 9 (keyrow).
;   - Budget: ~68 bit transactions for a full beep = on the order of a
;     couple of milliseconds. Send at most one per frame; per-event is
;     the normal pattern. Kill is only 4 bits - essentially free.
; ============================================================================

pc_ipcwr equ    $18003          ; W: bit1=COMDATA, bits 2,3=1, bit0=0
pc_ipcrd equ    $18020          ; R: bit6=busy, bit7=data from IPC
pc_intr  equ    $18021          ; W: bit1 (+mask bits 7..5) clears IPC int
sv_pcint equ    $35             ; sysvar offset: interrupt mask byte

inso_cmd equ    10              ; start sound
kiso_cmd equ    11              ; kill sound
stat_cmd equ    1               ; read status (bit1 = sound playing)

; ----------------------------------------------------------------------------
; snd_beep - start a sound. The 8049 keeps playing it on its own.
; In:  a3 -> 8-byte parameter block:
;        +0  pitch1 (already +1)
;        +1  pitch2 (already +1)
;        +2  interval low byte    +3  interval high byte
;        +4  duration low byte    +5  duration high byte
;        +6  gradient<<4 | wrap
;        +7  random<<4  | fuzz
; Trashes d0-d2. Call with a3 pointing at one of your note/effect tables.
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
        bsr.s   snd_clrint      ; remove if you own the whole machine
        move    (sp)+,sr
        rts

; ----------------------------------------------------------------------------
; snd_kill - stop sound immediately. 4 bit transactions only.
; ----------------------------------------------------------------------------
snd_kill
        move    sr,-(sp)
        ori     #$0700,sr
        moveq   #kiso_cmd,d0
        bsr.s   ipc_nib
        bsr.s   snd_clrint
        move    (sp)+,sr
        rts

; ----------------------------------------------------------------------------
; snd_stat - read IPC status byte. Returns d0.b, bit1 set = still playing.
; Costs a full round trip (~12 bit transactions); counting frames against
; the duration you sent is usually cheaper in a game loop.
; ----------------------------------------------------------------------------
snd_stat
        move    sr,-(sp)
        ori     #$0700,sr
        moveq   #stat_cmd,d0
        bsr.s   ipc_nib
        moveq   #0,d0
        moveq   #8-1,d2
.rd     move.b  #%1110,pc_ipcwr ; assert 1 so the IPC can pull the line
.wait   btst    #6,pc_ipcrd
        bne.s   .wait
        move.b  pc_ipcrd,d1
        add.b   d1,d1           ; bit7 -> X
        addx.b  d0,d0           ; shift into result, MSB first
        dbf     d2,.rd
        bsr.s   snd_clrint
        move    (sp)+,sr
        rts

; ----------------------------------------------------------------------------
; ipc_byte - send d0.b to the IPC, MSB first (as two nibbles)
; ipc_nib  - send low nibble of d0.b to the IPC
; Interrupts must already be masked. Trashes d0/d1.
; Bit pattern per JS ROM L02F7C: shift nibble to bits 7..4, OR in bit 3
; as an end marker, then shift bits out until only the marker is left.
; ----------------------------------------------------------------------------
ipc_byte
        move.b  d0,-(sp)
        lsr.b   #4,d0
        bsr.s   ipc_nib         ; high nibble
        move.b  (sp)+,d0        ; low nibble falls through
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

; ----------------------------------------------------------------------------
; snd_clrint - clear the level-2 interrupt raised by talking to the IPC.
; Only needed while QDOS is alive and level-2 interrupts are in use.
; a6 must hold the system variables base ($28000) as usual in supervisor
; mode, or hard-code it if calling from your own environment.
; ----------------------------------------------------------------------------
snd_clrint
        moveq   #%10,d1         ; pc.intri
        or.b    sv_pcint(a6),d1 ; keep the enable mask bits 7..5
        move.b  d1,pc_intr
        rts

; ----------------------------------------------------------------------------
; Example note/effect tables
; interval and duration are in IPC time units (same as SuperBASIC BEEP);
; duration 0 = sustain until snd_kill or next snd_beep.
; ----------------------------------------------------------------------------
sfx_laser
        dc.b    5,80            ; pitch1+1, pitch2+1 (fast sweep pair)
        dc.b    2,0             ; interval = 2 (lo,hi)
        dc.b    $00,$04         ; duration = $0400 (lo,hi)
        dc.b    $10             ; gradient=1, wrap=0
        dc.b    $00             ; random=0, fuzz=0

note_a4
        dc.b    26,26           ; steady tone: pitch1 = pitch2
        dc.b    0,0             ; no stepping
        dc.b    $88,$13         ; duration $1388 = 5000 units
        dc.b    $00
        dc.b    $00

; Melody idea: table of 8-byte blocks + frame counts; in your VBlank
; handler decrement the count and snd_beep the next block when it hits 0.
; That is one ~2ms transfer every N frames - negligible.

        end
