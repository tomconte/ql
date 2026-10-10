; strip.inc -- glider: the top strip's data (spec 5.4): the radar's
; rim, the bearing table for the out-of-range crystals, the readouts'
; icons. Included by glider.asm.

; ---------------------------------------------------------------- the rim
; rad_rim: the radar circle's half-height in rows at |ox| = 0..18 px:
; round(12 * sqrt(1 - (ox/18)^2)) (objects' blips, rim_blips)
rad_rim:
        dc.b    12,12,12,12,12,12,11,11,11,10,10,9,9,8,8,7,5,4,0
        even

; ------------------------------------------------------------- bearings
; brg_tab: the bearing in 64ths of a turn (the radar's sweep lists are
; 4 brads apart) of a direction whose smaller to larger component ratio
; is i/32, i = 0..32: round(atan(i/32) * 32/pi), 0..8 (45 degrees).
brg_tab:
        dc.b    0,0,1,1,1,2,2,2,2,3,3,3,4,4,4,4,5,5,5,5,6,6,6,6,7,7,7,7,7,7
        dc.b    8,8,8
        even

; ------------------------------------------------------------------ icons
; 8-px bitmaps, a byte a row, bit 7 = the left pixel, drawn like the HUD
; digits (lib/vfont.inc): a crystal -- a tall diamond with its equator,
; as the white meshes look -- beside the count of those left, and a
; craft (a delta) for each spare one under the shield bar.
ic_crystal:
        dc.b    $10,$28,$28,$7c,$28,$28,$10     ; 7 rows
ic_craft:
        dc.b    $10,$28,$44,$fe                 ; 4 rows
        even
