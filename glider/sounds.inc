; sounds.inc -- glider: the sound effects (spec 8), 8-byte IPC blocks
; for snd_beep (lib/ipc_sound_takeover.asm), in sfx_* order: pitch1+1,
; pitch2+1 (higher = lower), interval (lo, hi; 72 us units), duration
; (lo, hi), gradient<<4 | wrap, random<<4 | fuzz -- the SuperBASIC BEEP
; parameters. First guesses (2026-10-04), to be tuned by ear.

; ------------------------------------------------------------------ sounds
sfx_tab:
        dc.b    5,80,2,0,$00,$03,$10,$00    ; fire: game8's zap, 55 ms
        dc.b    30,140,3,0,$00,$05,$10,$00  ; efire: lower, slower, 92 ms
        dc.b    12,20,1,0,$80,$01,$20,$00   ; hit: a high blip, 28 ms
        dc.b    180,200,8,0,$00,$0c,$10,$8c ; dmg: a buzz, 220 ms
        dc.b    100,220,30,0,$00,$18,$10,$ff ; boom: noise, 440 ms
        dc.b    140,250,60,0,$00,$30,$10,$ff ; big: deeper, 0.9 s
