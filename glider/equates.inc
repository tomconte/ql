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
                                    ; (the sweep takes up to rad_swmax)
spk_dots    equ     96              ; explosion sparks per buffer (a
                                    ; generator's 32 and two gliders' 16)
dl_recs     equ     maxdots+2*nwin+1+rad_dots+spk_dots ; dot list records

; ----- objects (spec sections 5.1, 5.2, 6). The near plane for meshes
; is closer than the lattice's: their edges are clipped, the dots are
; not. r_active bounds every camera-space coordinate to a word (the
; frustum and the eye-in-mesh-frame products need that). Meshes,
; planes and the directory come from meshes.inc (genmesh --game).
znear_o     equ     32              ; object near plane (z' <= it: clipped)
sector_sh   equ     13              ; the sector wraps every 2^13 units
sector      equ     1<<sector_sh    ; (spec 6: 32 x 32 cells of latd 256)
        if      sector&(latd-1)
        fail    "sector must be a multiple of latd: the lattice must tile"
        endc
r_active    equ     2560            ; world box half-side: zfar + radius + slack
maxobj      equ     16              ; erase boxes per buffer = objects drawn
nent        equ     64              ; entity pool

; ----- top strip (rows 0..playtop-1, spec 5.4): nothing but the HUD is
; drawn there (edges are clipped at playtop). The radar: heading-up,
; centre (rad_x, rad_y), radius rad_rx px by rad_ry rows (a circle on a
; 4:3 screen), the sweep turning once in ~1.4 s. Range rad_range units:
; 128 units a pixel, 192 a row, so the blips come from the object
; stage's camera-space centres by a shift and a multiply (the range
; stays inside the world box, r_active). The spec's 4096 cost ~0.4 ms
; a blip on the 68008 (a transform for every far entity).
sight_x0    equ     240             ; the sight's extent (sight_ops):
sight_x1    equ     272             ; x 240..272, rows horizon +-26
sight_dy    equ     26
rad_x       equ     256
rad_y       equ     13
rad_rx      equ     18
rad_ry      equ     12
rad_xsh     equ     7               ; x: 128 units a pixel
rad_ymul    equ     65536/192       ; y: (zc*rad_ymul) >> 16 = zc/192
rad_range   equ     rad_rx<<rad_xsh ; 2304 units
        if      rad_range>=r_active
        fail    "the radar's range must stay inside the world box"
        endc
rad_sweep   equ     936             ; sweep turn per beat, 8.8 brads
                                    ; (256 brads in 70 beats)
rad_nang    equ     64              ; sweep pixel lists (4 brads apart)
rad_swmax   equ     (rad_rx+1)/2    ; sweep dots: every other one of <= rad_rx
                                    ; steps (max(|dx|, |dy|), rad_rx >= rad_ry)
rad_stride  equ     2+rad_swmax*4   ; one list: count, records

; ----- the craft's collisions and shield (spec 7): the craft is a circle
; of craft_r; entities within r_close (two frames of flight plus the
; largest contact distance, 136 + 32) are listed by the object stage for
; craft_hit. Bumping an obstacle at bump_v or more costs 1 shield, at
; most once in hurt_b beats; any loss turns the sight red for flash_b
; beats. First values
; (2026-09-30), to be tuned by feel.
craft_r     equ     32
r_close     equ     512
shield_max  equ     8
shield_low  equ     2               ; the bar turns red at this or less
bump_v      equ     6               ; units/beat along the normal: a bump
hurt_b      equ     25
flash_b     equ     6
sb_x        equ     16              ; the shield bar: x (a multiple of 8),
sb_y        equ     8               ; first row (6 rows)

; ----- explosions (spec 5.6): up to nboom at once, each a burst from
; sparks.inc (tools/gensparks.py: up to spk_n sparks for spk_life beats)
nboom       equ     6               ; (the puffs of hits take them too)

; ----- player shots (spec 7): up to nshots in flight, one every fire_cd
; beats while Space is held, shot_v units a beat for shot_life beats
; (range 2000, inside zfar), launched alternately from the gun ports
; gun_dx either side of the eye and gun_dy below it, drawn as shot_len-
; unit green segments. First values (2026-09-29), to be tuned by feel.
nshots      equ     4
fire_cd     equ     7
shot_v      equ     80
shot_life   equ     25
shot_len    equ     64
gun_dx      equ     44
gun_dy      equ     48
shot_ym     equ     gun_dy*yfocal*16/xfocal ; sy = horizon + (invtab*it)>>16

; ----- enemy gliders (spec 6): up to ngl at once (the global cap: the
; budget knob), their entities in the pool after the level's. Each flies
; the section-4 model with its type's constants and an AI that thinks
; every gt_think beats (types.inc); the hull's centre skims at gl_y,
; the gun ports' height, so their shots leave from it. First values
; (2026-10-04), from a scratchpad model of the AI against a scripted
; player: a static player is hit by most shots, a weaving one by few.
ngl         equ     4
gl_y        equ     cam_h-gun_dy    ; 80 over the ground
gl_wait     equ     50              ; beats before a new glider's first shot
deadw       equ     16              ; steering deadband: aim error across
firew       equ     40              ; fire when the player is this close
                                    ; across the nose (craft_r 32 + slack)
orbit_b     equ     50              ; the wedge: beats orbiting at its range,
attack_b    equ     110             ;   then beats turning in to fire
orbit_m     equ     200             ; the orbit holds inside hold + this
alert_r     equ     1800            ; a patrolling glider attacks inside this
lose_r      equ     3500            ; an attacking one gives up beyond this
patrol_r    equ     600             ; the patrol wheels round inside this
; generators (spec 6): each launches up to gen_own gliders of its own
; (under the ngl cap), one every gen_delay beats, the types in turn; it
; turns gen_spin a beat. At most ngen per sector.
ngen        equ     8
gen_own     equ     2
gen_delay   equ     500             ; 10 s
gen_spin    equ     64              ; 0.25 brad a beat: a turn in 20 s
; enemy shots (spec 7): up to neshots in flight, eshot_v units a beat for
; eshot_life beats (range 1800), launched eshot_nose ahead of the hull
; centre; slow enough to see and slide out of
neshots     equ     4
eshot_v     equ     40
eshot_life  equ     45
eshot_nose  equ     64
eshot_len   equ     48              ; drawn length

; ----- sound effects (spec 8, sounds.inc): the number is the priority;
; the highest asked for in a frame is played at its end (sfx_play)
sfx_fire    equ     1               ; the player's shot
sfx_efire   equ     2               ; an enemy shot
sfx_hit     equ     3               ; a hit that did not destroy
sfx_dmg     equ     4               ; the craft loses shield
sfx_boom    equ     5               ; an explosion
sfx_big     equ     6               ; a generator's

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
no_rad      equ     0               ; skip the radar's sweep and blips
no_gls      equ     0               ; skip the gliders' and their shots'
                                    ; beats (the gliders freeze)
no_gld      equ     0               ; skip the moving entities (gliders) in
                                    ; the object stage (not drawn, no blip)
no_snd      equ     0               ; skip the sound effects
; the spawn point (M4: per sector): between four lattice points, looking
; along +z. Moved for unattended tests, e.g. in front of a tower.
spawn_x     equ     latd/2
spawn_z     equ     latd/2
spawn_head  equ     0               ; 8.8 brads
; test_keys: row-1 bits held down on every loop, for unattended runs
; under make shot (qlshot cannot press keys): e.g. 1<<k1__right pivots
; the craft so every object sweeps across the screen. 0 in a real build.
test_keys   equ     0
; test_gl: launch a dart, a wedge and a kite ahead of the spawn at start
; (gl_test in enemy.asm), until the generators launch them
test_gl     equ     0

; craft state record offsets
c_px        equ     0               ; long, 16.8 world x, 0..sector-1
c_pz        equ     4               ; long, 16.8 world z (both wrapped)
c_head      equ     8               ; word, 8.8 brads (0 = looking +z)
c_turn      equ     10              ; word, current turn rate (0 = released)
c_vx        equ     12              ; word, 8.8 units/beat
c_vz        equ     14
c_stop      equ     16              ; word, beats at rest with Down held
c_rev       equ     18              ; word, 1 = reversing
c_s         equ     20              ; word, sin head (8.8)
c_c         equ     22              ; word, cos head (8.8)
c_ox        equ     24              ; long, the position before the last
c_oz        equ     28              ;   move (flight_step, for craft_hit)
c_size      equ     32

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

; player shot record (shots)
sh_life     equ     0               ; word, beats left, 0 = free
sh_x        equ     2               ; word, head, world units (wraps)
sh_z        equ     4
sh_vx       equ     6               ; word, units per beat
sh_vz       equ     8
sh_s        equ     10              ; word, direction sin, cos (8.8)
sh_c        equ     12
sh_tx       equ     14              ; word, head to tail, world units
sh_tz       equ     16
sh_hit      equ     18              ; word, the life at which it hits sh_tgt
                                    ; (shot_cast), 0 = nothing on its path
sh_tgt      equ     20              ; long, the entity it will hit
sh_v        equ     24              ; word, its speed (shot_v, eshot_v)
sh_col      equ     26              ; word, draw_line colour
sh_size     equ     28

; enemy glider record (glpool; the flight state is the section-4 model's,
; the position kept 16.16 so its integer part is a word)
g_x         equ     0               ; long, 16.16 world x (integer word
g_z         equ     4               ;   first), wrapped into the sector
g_head      equ     8               ; word, 8.8 brads
g_turn      equ     10              ; word, current turn rate (0 = released)
g_vx        equ     12              ; word, 8.8 units/beat
g_vz        equ     14
g_s         equ     16              ; word, sin head (8.8)
g_c         equ     18              ; word, cos head
g_tx        equ     20              ; word, the thrust vector (8.8), kept
g_tz        equ     22              ;   with the heading
g_ent       equ     24              ; long, its entity (e_flags 0: free)
g_type      equ     28              ; long, its type record (gt_*)
g_gen       equ     32              ; long, the generator that launched it
g_dir       equ     36              ; word, the AI's turn: -1 left, 0, +1 right
g_thr       equ     38              ; word, nonzero: thrust
g_think     equ     40              ; word, beats to the next think
g_fire      equ     42              ; word, beats to the next shot
g_mode      equ     44              ; word, the orbit/attack phase clock
g_burst     equ     46              ; word, shots left in the burst
g_crad      equ     48              ; word, its collision radius (od_crad)
g_alert     equ     50              ; word, nonzero: attacking (else on
                                    ; patrol round its generator)
g_size      equ     52

; enemy glider type record (types.inc)
gt_mesh     equ     0               ; word, mesh directory index
gt_thrust   equ     2               ; word, 8.8 units/beat per beat
gt_tmin     equ     4               ; word, turn rate when a turn starts,
gt_tramp    equ     6               ;   its rise per beat held, its cap
gt_tmax     equ     8               ;   (8.8 brads/beat)
gt_hold     equ     10              ; word, range inside which it coasts
                                    ; (0 = always thrust)
gt_swerve   equ     12              ; word, range inside which it aims
gt_aimoff   equ     14              ;   gt_aimoff beside the player
gt_frange   equ     16              ; word, range it fires from
gt_fcd      equ     18              ; word, beats between shots (bursts)
gt_burst    equ     20              ; word, shots per burst
gt_bgap     equ     22              ; word, beats between a burst's shots
gt_think    equ     24              ; word, beats between thinks
gt_orbit    equ     26              ; word, nonzero: orbit at the hold range
gt_size     equ     28

; explosion record (booms)
bm_live     equ     0               ; word, beats left, 0 = free
bm_x        equ     2               ; word, centre, world units
bm_z        equ     4
bm_y        equ     6               ; word, centre height over the ground
bm_col      equ     8               ; word, colour (od_col: 1 red, 2 green,
                                    ; 3 white)
bm_mir      equ     10              ; word, nonzero: the burst mirrored
bm_pat      equ     12              ; long, the burst (sparks.inc)
bm_size     equ     16

; spark pattern header (sparks.inc, tools/gensparks.py)
spx_xm      equ     0               ; word, the burst's largest |x|,
spx_y0      equ     2               ;   smallest y, largest y (stored
spx_y1      equ     4               ;   units of spk_scale, y down)
spx_rows    equ     6               ; word[spk_life]: each age's row, as
                                    ; an offset from the pattern

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
od_hp       equ     24              ; hits to destroy (0 = an obstacle)
od_touch    equ     26              ; contact: 0 = an obstacle (bounce),
                                    ; else consumed, shield += it (mine -2)
od_move     equ     28              ; 1 = moves (an enemy glider): not in
                                    ; the static lists (near, close)
od_spk      equ     30              ; its explosion burst, from sparks

; camera block for the object stage (ocam)
oc_px       equ     0               ; word, camera x, integer units (0..sector-1)
oc_pz       equ     2               ; word
oc_s        equ     4               ; word, sin head
oc_c        equ     6               ; word, cos head
oc_n        equ     8               ; word, objects drawn this frame

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
