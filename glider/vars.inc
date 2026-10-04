; vars.inc -- glider: variables, per-buffer lists and scratch. They are
; part of the binary; the big tables live in the dataspace (ds_base,
; end of glider.asm).

; ---------------------------------------------------------------------- data
        even
craft:  ds.b    c_size              ; see the c_* offsets (craft_reset inits)
kbd_prev:
        dc.b    0                   ; row-1 bits the last sim step used
kbd_cur:
        dc.b    0                   ; row-1 bits from the latest IPC read
        even
lat_uz: dc.l    0,0                 ; world z step in camera space, 16.16
wdg:    ds.b    4*12                ; wedge test records (wdg_put)
lst_max:
        dc.l    0                   ; the lattice's dot limit
dl_base:
        dc.l    0                   ; this frame's dot list (dots_open):
dl_next:
        dc.l    0                   ;   its count word, the next record,
dl_end:
        dc.l    0                   ;   the limit before the sweep's room
hud_tick:
        dc.w    0                   ; readout refresh phase
xbeats: dc.w    0                   ; frame edges consumed during the work
ocam:   ds.b    16                  ; object-stage camera block (oc_*)
sweep:  dc.w    0                   ; radar sweep angle, 8.8 brads
; sight colours (0 off, 1 red, 2 green): wanted (set by the simulation),
; this frame's (latched at the erase), shown per buffer; per buffer, its
; erase boxes overlap the sight; redraw it this frame. Adjacent: the
; strip routines reach them from one base.
sight_col:
        dc.b    2
sight_now:
        dc.b    0
sight_buf:
        dc.b    0,0
sight_hit:
        dc.b    0,0
sight_rd:
        dc.b    0
        even
cur:    ds.b    cu_size             ; current object (cu_*)

headroom:
        dc.l    0                   ; idle spins in last loop's VBL wait
        dc.l    0                   ; +4  window: spins accumulator
        dc.w    0                   ; +8  window: extra beats
        dc.w    mwin                ; +10 loops left in the window
        dc.w    0                   ; +12 latched avg spins (meter A)
        dc.w    0                   ; +14 latched extra beats (meter B)
        dc.w    1                   ; +16 beats of the last loop (1..3)
        dc.w    0                   ; +18 frames left to draw the meters
        dc.l    0                   ; +20 window: spins on buffer-0 loops
        dc.l    0                   ; +24 window: spins on buffer-1 loops
        dc.w    $7fff               ; +28 window: min spins
        dc.w    0                   ; +30 window: max spins
        dc.w    0,0,0,0             ; +32 latched avg0, avg1, min, max
        dc.l    0                   ; +40 beats since the start (tests:
                                    ;   against the wall clock)

; per-buffer dot lists: count, then (byte offset, inverse mask) records:
; the lattice's (maxdots, checked per row, so a row of slack follows),
; then the radar's (rad_dots)
dots0:  dc.w    0
        ds.w    dl_recs*2
dots1:  dc.w    0
        ds.w    dl_recs*2

; object scratch: transformed vertices, the clip work area, and the
; per-buffer erase-box lists (count, then maxobj parade-format records)
vscr:   ds.b    16*12
cwrk:   ds.b    2*cw_size
bbox0:  dc.w    0
        ds.w    maxobj*4
bbox1:  dc.w    0
        ds.w    maxobj*4

; player shots (sh_* offsets), then the enemy shots right after them
; (shots_draw walks both), the shots in flight, the autofire cooldown,
; the gun port toggle
shots:  ds.b    nshots*sh_size
eshots: ds.b    neshots*sh_size
nlive:  dc.w    0                   ; player shots in flight
nelive: dc.w    0                   ; enemy shots in flight
fire_t: dc.w    0
gun_lr: dc.w    0
; enemy gliders (g_* offsets), each paired at startup with an entity
; after the level's in entpool; the think phase of the next launch (1 or
; 2, alternating, so gliders launched together think on different beats)
glpool: ds.b    ngl*g_size
gl_phase:
        dc.w    1
gl_next:
        dc.w    0                   ; the type the next launch takes
; the generators (their entities), listed at startup: count, pointers
gens:   dc.w    0
        ds.l    ngen
; near: the entities inside the world box (the object stage, each
; frame), for the shots' hit tests; close: those within r_close, for
; the craft's; each a count, then pointers
near:   dc.w    0
        ds.l    nent
close:  dc.w    0
        ds.l    nent
; explosions (bm_* offsets), how many are live, the mirror toggle
booms:  ds.b    nboom*bm_size
nbooms: dc.w    0
boom_mir:
        dc.w    0
sfx_want:
        dc.b    0                   ; the sound asked for this frame (0: none)
        even
shield: dc.w    shield_max
shield_chg:
        dc.w    0                   ; nonzero: the shield changed this frame
hurt_t: dc.w    0                   ; beats since a hit, counting down

; entity pool (e_* offsets), filled from the level table at start
entpool:
        ds.b    (nent+1)*e_size
