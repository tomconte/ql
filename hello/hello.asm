; hello.asm -- "Hello, World!" job for Sinclair QDOS
;
; Opens its own console window, prints a message, waits for a key,
; then removes itself. Runs as a proper QDOS job via EXEC/EXEC_W.
;
; Assemble: vasmm68k_mot -m68008 -Fbin -o hello_bin hello.asm
; The file then needs a QDOS executable header (file type 1) with a
; dataspace value -- see mkqlpak.ps1.

; QDOS trap keys (values from the Minerva ROM sources, inc/io and inc/sd)
mt_frjob    equ     $05             ; trap #1: force-remove job
io_open     equ     $01             ; trap #2: open channel
io_old      equ     $00             ;   d3 open mode: old (exclusive)
io_fbyte    equ     $01             ; trap #3: fetch one byte
io_sstrg    equ     $07             ; trap #3: send string of bytes
sd_bordr    equ     $0c             ; trap #3: set window border
sd_clear    equ     $20             ; trap #3: clear window
sd_setpa    equ     $27             ; trap #3: set paper colour
sd_setin    equ     $29             ; trap #3: set ink colour

forever     equ     -1              ; trap #3 timeout: wait indefinitely

; ---------------------------------------------------------------- job header
start:
        bra.s   main
        dc.l    0
        dc.w    $4afb               ; "job name follows" flag
        dc.w    jobname_e-jobname
jobname:
        dc.b    'Hello'
jobname_e:
        even

; ------------------------------------------------------------------- program
main:
        lea     conname(pc),a0      ; open our console window
        moveq   #io_open,d0
        moveq   #-1,d1              ; owner: this job
        moveq   #io_old,d3
        trap    #2
        tst.l   d0
        bne.s   done                ; no window, no fun -- just exit
                                    ; a0 = channel id from here on

        moveq   #sd_bordr,d0        ; red border, 1 pixel wide
        moveq   #2,d1
        moveq   #1,d2
        moveq   #forever,d3
        trap    #3

        moveq   #sd_setpa,d0        ; black paper...
        moveq   #0,d1
        moveq   #forever,d3
        trap    #3
        moveq   #sd_clear,d0        ; ...clear the window to it...
        moveq   #forever,d3
        trap    #3
        moveq   #sd_setin,d0        ; ...and white ink
        moveq   #7,d1
        moveq   #forever,d3
        trap    #3

        lea     msg(pc),a1          ; print the message
        move.w  (a1)+,d2            ; leading word = byte count
        moveq   #io_sstrg,d0
        moveq   #forever,d3
        trap    #3

        moveq   #io_fbyte,d0        ; wait for any key
        moveq   #forever,d3
        trap    #3

done:
        moveq   #mt_frjob,d0        ; remove this job
        moveq   #-1,d1
        moveq   #0,d3               ; error code 0
        trap    #1

; ---------------------------------------------------------------------- data
conname:
        dc.w    conname_e-conname-2
        dc.b    'con_320x120a96x60'
conname_e:
        even
msg:
        dc.w    msg_e-msg-2
        dc.b    'Hello, World!',10
        dc.b    10
        dc.b    'Press any key to exit.'
msg_e:
        even
