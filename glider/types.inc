; types.inc -- glider: the enemy glider types (spec 6), gt_* records:
; the section-4 flight model's constants per type (the player's are
; thrust 384, turn 64..320 by 8) and the AI's parameters (enemy.asm,
; glider_think). First values (2026-10-04) from the scratchpad model.

; ------------------------------------------------------------------- types
;  mesh, thrust, turn min/ramp/max, hold, swerve/aimoff, fire range,
;  cooldown, burst, burst gap, think, orbit
gltypes:
gt_dart:                            ; the charger: always thrusting, fast
        dc.w    msh_dart,512        ; (terminal 32 units a beat), fires on
        dc.w    64,16,320           ; the way in, swerves past the player
        dc.w    0,700,128           ; 128 to its side, loops round
        dc.w    1400,30,1,0,2,0
gt_wedge:                           ; the strafer: coasts inside 1000,
        dc.w    msh_wedge,384       ; orbits there with the player abeam,
        dc.w    64,8,320            ; then turns in to fire (orbit_b,
        dc.w    1000,0,0            ; attack_b)
        dc.w    1300,20,1,0,2,1
gt_kite:                            ; the gunship: slow (20 units a beat),
        dc.w    msh_kite,320        ; stands off at 1100, bursts of three
        dc.w    64,6,256
        dc.w    1100,0,0
        dc.w    1500,90,3,6,2,0
gltypes_e:
