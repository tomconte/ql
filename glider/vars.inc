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

; entity pool (e_* offsets), filled from the level table at start
entpool:
        ds.b    (nent+1)*e_size
