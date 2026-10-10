; texts.inc -- glider: the words on the screens around play (Beta 1,
; spec 11.1), for lib/draw_text.asm: ' '..'Z', a 0 ends each. Lines
; with numbers in them are put together in txtbuf (str_put, bcd_put).

; --------------------------------------------------------------------- texts
tx_title:
        dc.b    'STARQLIDER',0
tx_beta:
        dc.b    'BETA 1',0
tx_goal:
        dc.b    'DESTROY ALL WHITE CRYSTALS',0
tx_keys:
        dc.b    'ARROWS STEER  SPACE FIRES',0
tx_press:
        dc.b    'PRESS SPACE',0
tx_hi:  dc.b    'HI ',0
tx_last:
        dc.b    '   LAST ',0
tx_sector:
        dc.b    'SECTOR ',0
tx_over:
        dc.b    'GAME OVER',0
tx_score:
        dc.b    'SCORE ',0
tx_paused:
        dc.b    'PAUSED',0
tx_bonus:
        dc.b    'BONUS ',0
        even
