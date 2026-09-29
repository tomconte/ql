; equates.inc -- glider: hardware addresses, the tuning knobs (flight
; model, camera, lattice, objects, HUD), profiling flags and record
; offsets. No code or data; glider.asm includes it first, since the
; if blocks test these flags.

; hardware
mc_stat     equ     $18063          ; ZX8301 display control (write-only)
pc_intr     equ     $18021          ; ZX8302 interrupt register
pc__frame   equ     3               ; bit 3 = 50/60 Hz frame interrupt

scr0        equ     $20000          ; screen 0 (displayed at boot)
scr1        equ     $28000          ; screen 1 (ex-QDOS sysvars, now ours)
scr_llen    equ     128             ; bytes per scan line

; ----- flight model (spec section 4) -- THE tuning knobs.
; Velocities are 8.8 world units per beat (20 ms), angles 8.8 brads
; (256 brads per turn; word wrap is the modulo). Terminal speed under
; drag alone is thrust << drag_shift = 24 units/beat with these values,
; below vmax: top speed is set by thrust/drag, the cap only bites in
; reverse (rev_max 20 < 24).
thrust      equ     384             ; 1.5 units/beat per beat
drag_shift  equ     4               ; v -= v >> 4 per beat (drift feel)
vmax        equ     48              ; forward speed cap, units/beat
brake_shift equ     2               ; Down: v -= v >> 2 per beat
rev_max     equ     20              ; reverse speed cap, units/beat
v_rest      equ     128             ; 0.5 units/beat: "at rest" threshold
rev_delay   equ     25              ; beats at rest before reverse engages
; Turn rates in 8.8 brads/beat: 256 = 1 brad/beat = 70 degrees/s. The
; spec's 1..3 (70..211 deg/s) strobed the near dots and outran the drag
; time constant (16 beats) so far that every turn became a sideways
; slide; 0.25..1.25 (17..88 deg/s) ramped over 0.6 s is the second try.
turn_min    equ     64              ; 0.25 brad/beat when a turn starts
turn_max    equ     320             ; 1.25 brads/beat
turn_ramp   equ     8               ; +1/32 brad/beat per beat held

; ----- camera and lattice (spec sections 5.1, 5.3). The viewport is
; shifted: the horizon sits in the upper part of the screen so the view
; is mostly ground (hovering over a plane); the projection stays linear
; (sy = horizon + y*yfocal/z), no pitch involved. Camera height and
; lattice spacing set how fast successive dot rows spread down the
; screen: 40/512 read as flat (rows 133,126,124,123...), 128/256 give
; 165,122,108,101,97,94. znear is derived so the nearest dot lands on
; the last play row.
cam_h       equ     128             ; camera height over the ground
horizon     equ     80              ; screen row of the horizon
hz_line     equ     0               ; 1 = draw the horizon line, 0 = none
                                    ; (Starglider 1 look, 2026-09-10: the
                                    ; reticle alone marks the aim row)
xfocal      equ     256             ; sx = 256 + x*xfocal/z: 256 = 90-deg
                                    ; horizontal FOV, 384 = 67 deg
yfocal      equ     170             ; sy = horizon + y*yfocal/z; keep
                                    ; yfocal = xfocal*2/3 (mode 4 pixels
                                    ; are 1.5x taller than wide on 4:3)
playtop     equ     28              ; first play-area row (top strip above)
playbot     equ     239             ; last play-area row (HUD from 240)
znear       equ     cam_h*yfocal/(playbot-horizon)+1 ; nearest depth drawn
zfar        equ     2048            ; farthest: 10 rows under the horizon
latd        equ     256             ; lattice spacing, MUST be 2^n
nwin        equ     zfar/latd+1     ; half-window in cells (+1: the
                                    ; in-cell offset eats up to a cell)
maxdots     equ     128             ; lattice dots per buffer (checked per
                                    ; row: a row of slack follows)
rad_dots    equ     64              ; radar sweep + blip dots per buffer
                                    ; (the sweep takes up to rad_rx)
dl_recs     equ     maxdots+2*nwin+1+rad_dots   ; dot list records

; ----- objects (spec sections 5.1, 5.2, 6). The near plane for meshes
; is closer than the lattice's: their edges are clipped, the dots are
; not. r_active bounds every camera-space coordinate to a word (the
; frustum and the eye-in-mesh-frame products need that). Meshes,
; planes and the directory come from meshes.inc (genmesh --game).
znear_o     equ     32              ; object near plane (z' <= it: clipped)
r_active    equ     2560            ; world box half-side: zfar + radius + slack
maxobj      equ     16              ; erase boxes per buffer = objects drawn
nent        equ     64              ; entity pool

; ----- top strip (rows 0..playtop-1, spec 5.4): nothing but the HUD is
; drawn there (edges are clipped at playtop). The radar: heading-up,
; centre (rad_x, rad_y), radius rad_rx px by rad_ry rows (a circle on a
; 4:3 screen), range 4096 units (the circle a wrapped sector fits in),
; the sweep turning once in ~1.4 s.
rad_x       equ     256
rad_y       equ     13
rad_rx      equ     18
rad_ry      equ     12
rad_sweep   equ     936             ; sweep turn per beat, 8.8 brads
                                    ; (256 brads in 70 beats)
rad_nang    equ     64              ; sweep pixel lists (4 brads apart)
rad_stride  equ     2+rad_rx*4      ; one list: count, <= rad_rx records
                                    ; (steps = max(|dx|, |dy|), rad_rx >= rad_ry)

; ----- HUD band (rows 240-255): separator 240, readouts 242-246 and
; 248-252, headroom bar 254-255
hb_y        equ     254             ; bar top line (2 rows tall)
hb_shift    equ     4
mwin        equ     128             ; meter window, loops (power of 2)
mshift      equ     7

; profiling flags: skip a stage to measure its cost as the meter delta
no_kbd      equ     0               ; skip the IPC keyboard read
no_lat      equ     0               ; skip the lattice (erase still runs)
no_hud      equ     0               ; skip the flight readouts
no_obj      equ     0               ; skip the objects (box erase still runs)
no_rad      equ     0               ; skip the radar's sweep
; test_keys: row-1 bits held down on every loop, for unattended runs
; under make shot (qlshot cannot press keys): e.g. 1<<k1__right pivots
; the craft so every object sweeps across the screen. 0 in a real build.
test_keys   equ     0

; craft state record offsets
c_px        equ     0               ; long, 16.8 world x
c_pz        equ     4               ; long, 16.8 world z
c_head      equ     8               ; word, 8.8 brads (0 = looking +z)
c_turn      equ     10              ; word, current turn rate (0 = released)
c_vx        equ     12              ; word, 8.8 units/beat
c_vz        equ     14
c_stop      equ     16              ; word, beats at rest with Down held
c_rev       equ     18              ; word, 1 = reversing
c_s         equ     20              ; word, sin head (8.8)
c_c         equ     22              ; word, cos head (8.8)
c_size      equ     24

; entity record (entpool, 16 bytes; the level table has the same shape)
e_mesh      equ     0               ; word, directory index; -1 ends the pool
e_flags     equ     2               ; word, 0 = inactive
e_x         equ     4               ; word, world x (integer units)
e_z         equ     6               ; word, world z
e_y         equ     8               ; word, centre height over the ground
e_head      equ     10              ; word, 8.8 brads
e_hp        equ     12              ; reserved (M3)
e_tmr       equ     14              ; reserved (M3)
e_size      equ     16

; mesh directory entry (objdir in meshes.inc, 32 bytes)
od_nv       equ     0               ; nvtx-1
od_nf       equ     2               ; nfaces-1
od_ne       equ     4               ; nedges-1
od_col      equ     6               ; draw_line colour
od_v        equ     8               ; table offsets from meshes
od_f        equ     10
od_e        equ     12
od_n        equ     14              ; face planes
od_yb       equ     16              ; ybase
od_rad      equ     18              ; bounding radius
od_crad     equ     20              ; collision radius (M3)
od_blip     equ     22              ; radar blip colour (0 = not shown)

; camera block for the object stage (ocam)
oc_px       equ     0               ; long, camera x, integer units
oc_pz       equ     4               ; long
oc_s        equ     8               ; word, sin head
oc_c        equ     10              ; word, cos head
oc_n        equ     12              ; word, objects drawn this frame

; current object (cur)
cu_v        equ     0               ; long, vertex table
cu_e        equ     4               ; long, edge table
cu_n        equ     8               ; long, plane table
cu_nv       equ     12              ; nvtx-1
cu_nf       equ     14              ; nfaces-1
cu_ne       equ     16              ; nedges-1
cu_col      equ     18              ; colour
cu_xc       equ     20              ; centre in camera space
cu_zc       equ     22
cu_yc       equ     24
cu_sa       equ     26              ; sin, cos of (object - camera) heading
cu_ca       equ     28
cu_vis      equ     30              ; face visibility mask
cu_oc       equ     32              ; OR of the vertex outcodes
cu_cnt      equ     34              ; loop counter
cu_minx     equ     36              ; erase box accumulators
cu_maxx     equ     38
cu_miny     equ     40
cu_maxy     equ     42
cu_size     equ     44

; vertex scratch record (vscr, 12 bytes; edge tables index by i*12)
vs_x        equ     0               ; camera space x', y', z'
vs_y        equ     2
vs_z        equ     4
vs_sx       equ     6               ; projected
vs_sy       equ     8
vs_oc       equ     10              ; outcode: 1 left, 2 right, 4 above,
                                    ; 8 below, $10 behind the near plane
; clip work area (cwrk): two vs records, A then B
cw_x        equ     vs_x
cw_y        equ     vs_y
cw_z        equ     vs_z
cw_sx       equ     vs_sx
cw_sy       equ     vs_sy
cw_oc       equ     vs_oc
cw_size     equ     12
