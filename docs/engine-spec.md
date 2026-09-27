# Game engine spec -- ground-skimmer raid (working title)

Draft v0.2, 2026-09-24. v0.1 (2026-09-06) came out of the
control-scheme brainstorm; v0.2 folds in the design pass of
2026-09-23/24: the carrier is dropped (for now), and Atari's
Battlezone (1980) joins Starglider as an inspiration -- ideas taken
one by one (four-corner sight, radar strip, wraparound field,
windshield crack), not a clone (no lock-on, no tanks, no lone enemy,
no single shell). Everything marked **decided** came out of those
discussions; open points are collected in section 12. The engine
builds on `shapes/` (reference 3D engine) and the `lib/` routines;
nothing here contradicts `docs/takeover.md`, `docs/vector-perf.md` or
the CLAUDE.md rules.

## 1. Concept

- **Setting**: an entirely artificial, flat world. Candidates: an
  occupied moon turned into a base, the hull of a vast ship, or a
  planet terraformed flat and built over. Flatness is a design fact
  the engine exploits (fixed horizon, dot lattice), so the fiction
  should own it: everything the player sees was built.
- **Player**: a fragile hover-glider, first-person cockpit view, the
  craft itself is never drawn (**decided**).
- **Sector loop** (**decided** 2026-09-24): each sector is a wrapping
  map (section 6) guarded by shield generators, which launch enemy
  gliders. Destroy every generator and the craft warps to the next
  sector (the next map), harder than the last. Energy packs flown
  into refill the shield; three craft per game. The carrier, the
  stranded personnel and pickup-by-stopping are gone.
- **Aesthetic**: Starglider 1 / arcade Star Wars wireframe with
  backface culling, no filled polygons, mode 4 colours with fixed
  meaning (section 5.5). Stark and dark (**decided**): black sky,
  nothing on the horizon, the red lattice dots the only ground.

## 2. Targets and constraints

- Sinclair QL, 68008 at 7.5 MHz, mode 4 (512x256, black/red/green/
  white), 128 KB base machine. Screen 0 at `$20000`, screen 1 at
  `$28000` (both claimed after takeover), program + data in the 64 KB
  at `$30000`..`$3FFFF`. Nothing above 128 KB is assumed.
- Runs on: real QL, Q-emuLator, MiSTer QL core, Spectrum Next QL core,
  sQLux. Delivered as `.qlpak` and `.mdv` (`tools/mkqlpak.ps1`,
  `tools/mkmdv.py`), boot script via `EXEC mdv1_...`.
- Full takeover per `docs/takeover.md`: TRAP #0, `move.w #$2700,sr`,
  private supervisor stack, poll `$18021` bit 3 for VBL, no QDOS after.
- Frame discipline: draw into the back buffer, wait for VBL, flip.
  No core workarounds (CLAUDE.md rule 12).
- **Time base**: the beat (one 20 ms VBL). Every simulated quantity
  is defined per beat, and the simulation runs one step per beat the
  previous loop took (the flight model already does: `flight_step`
  once per beat), so the game plays the same at any frame rate. The
  design budget is a 3-beat frame (**decided** 2026-09-24: 16.7 Hz,
  60 ms, about Battlezone's own 15.6 Hz update); light scenes run at
  25 or 50 Hz for free.
- **Faster machines**: 3 beats is the stock QL's budget, not a lock.
  The loop counts the beats its work took and waits for the next VBL,
  so a faster CPU drops it to 2 or 1 beat (25 or 50 Hz) with the game
  unchanged; 50 Hz is the ceiling, since flips wait for the VBL.
  Section 2.1 has the rules that keep this true and the platform
  notes.

### 2.1 Faster machines

Rules that keep the engine speed-independent:

- **Step everything per beat.** AI, shots, collisions and sparks
  follow the flight model: one step per elapsed beat, never one
  scaled step per loop. Outcomes are then identical at 16.7 and
  50 Hz, and a shot cannot tunnel through a glider on a 3-beat loop
  (it would move 3 x `shot_v` between tests).
- **No self-modifying code.** A 68020 or later (Super Gold Card,
  Q40/Q60) caches instructions and does not see data writes to code,
  so a patched instruction can run stale. The erase's remainder burst
  patches its movem mask per box (`glider.asm`, `.erm`): to be
  replaced by eight prebuilt variants of the row loop (same speed, no
  patching) at the next engine pass. Flushing the cache instead is
  not an option: `movec` does not exist on the 68008.
- **Timing by handshake or VBL only.** The IPC routines wait on the
  8049's busy bit (no calibrated delay loops) and the frame timing
  polls `$18021`, so neither depends on CPU speed. The idle-spin
  meters do: at full host speed their word fields overflow (dev
  readout only).
- **Spare time stays idle.** Past 50 Hz nothing is gained. If extra
  detail is ever scaled to the measured headroom, it must be cosmetic
  only (lattice depth, spark count), never gameplay (enemy count), so
  difficulty does not depend on the machine.

Platforms (2026-09-24; speed figures are estimates until measured):

- **Emulators and cores running fast** (Q-emuLator `Speed=Full`,
  sQLux at full speed, turbo cores): everything scales, screen writes
  included, so the loop reaches 50 Hz. `Speed=Full` in
  `glider/glider.QCF` is the quick test.
- **RAM expansion on a real QL**: QDOS loads the job above 128 KB,
  out of the video chip's contention, so the code runs faster with no
  accelerator (Q-emuLator does not model this, `docs/qemulator.md`).
- **Gold Card (68000, 16 MHz) and Super Gold Card (68020, 24 MHz)**:
  the maths speeds up about 4x and 12x, but the screen stays in the
  QL's own RAM: the card shadows the display in its fast RAM (per its
  description), yet every write must still cross the 8-bit
  motherboard bus to reach the video chip. Pixel and
  erase writes are roughly a fifth of our frame, so expect about
  25 Hz on a Gold Card and close to 50 Hz on a Super Gold Card. To
  verify on a real card: that writes to screen 1 (`$28000`) reach the
  display (Minerva's dual-screen boot mode is offered on Gold Card
  systems, which suggests so), and the SMC fix above.
- **Q68** (FPGA, 68000-compatible at 40 MHz): not a drop-in.
  `$28000` is ordinary RAM there (its second screen is a separate
  4 MB area at `$FE800000`), and the keyboard is PS/2 and the sound
  sampled, with no 8049 IPC. It would need a small port layer: flip,
  keyboard, sound.
- A 60 Hz frame interrupt (an NTSC QL) would run the game 20% fast;
  not a target.

## 3. Input

One IPC keyboard read per frame, row 1, via `kbd_row` in
`lib/ipc_keys_takeover.asm` (arrows, Space, Enter, Esc; bits in that
file). Held keys are read level-triggered; Enter and Esc get edge
detection (previous-frame copy) so they toggle.

| Input | Action | Notes |
|---|---|---|
| Left / Right | turn (yaw) | rate ramps while held, section 4 |
| Up | thrust forward | |
| Down | brake, then reverse | reverse only after a full stop, section 4 |
| Space | fire | autofire while held, cooldown in beats |
| Enter | unassigned (rig: craft reset) | the radar is permanent (section 5.4) |
| Esc | pause | non-essential |

**Joystick parity (decided)**: core play uses arrows + Space only, so a
CTL1 joystick (wired into the same matrix row) plays the whole game on
real hardware, Q-emuLator, MiSTer and sQLux with no extra code. Enter
and Esc never carry anything the player needs mid-fight. Chords on
this row are reliable (single matrix row, no ghosting) and are
reserved for later extras, e.g. Left+Right together as an emergency
stop.

## 4. Flight model (hovercraft with inertia)

Conventions match `shapes/`: x right, y DOWN, z away, angles in 8.8
brads (256 brads per turn, integer brad indexes `sintab`, sin/cos are
8.8 with 256 = 1.0). World positions are 16.8 fixed point in a long
(integer part = world units, 16 bits signed); velocities 8.8 in a
word, units per beat.

State: `px, pz` (position), `head` (heading, 8.8 brads, word wrap),
`vx, vz` (velocity vector), `turn` (current turn rate), `shield`,
`stopped` (beats at rest).

Per beat, scaled by elapsed beats:

- **Heading**: forward vector is `(sin head, cos head)` in world
  (x, z). `head` = 0 looks along +z; Right increases `head`.
- **Turn ramp**: while Left or Right is held, `turn` climbs from
  `turn_min` to `turn_max` by `turn_ramp` per beat; on release it
  resets (or decays, to be tried). `head += turn` in the held
  direction.
- **Thrust**: Up adds `thrust` times the forward vector to `(vx, vz)`.
- **Drag**: every beat `v -= v >> drag_shift`. This is what makes the
  craft drift: velocity lags heading, so turning at speed slides the
  craft sideways past a tower. Drift is the character of the game
  (**decided**) and `drag_shift` is the main feel knob.
- **Speed cap**: if `vx*vx + vz*vz > vmax*vmax`, scale v down (4
  multiplies, only when over the cap).
- **Brake / reverse**: Down while moving applies strong drag
  (`v -= v >> brake_shift`). When speed falls under `v_rest`, count
  `stopped` beats; after `rev_delay` beats with Down still held, apply
  reverse thrust along `-forward` with cap `rev_max` (about half of
  `vmax`). Releasing Down clears the sequence.
- **Camera**: at `(px, -cam_h, pz)` looking along `head`. Height is
  constant, no pitch, no roll, no banking (**decided**).

Initial values, to be tuned in the flight rig (M1): `thrust` 1.5,
`drag_shift` 4, `vmax` 48 units/beat, `brake_shift` 2, `rev_max` 20,
`turn_min` 1 brad/beat, `turn_max` 3, `turn_ramp` 0.25, `cam_h` 128
(M1, 2026-09-10: 40 read as flat; note the parade tower is 110 tall,
so meshes get rescaled in M2 to stand above the camera). Later option:
couple `turn_max` to speed so fast means wide arcs and slow means
pivoting on the spot.

Enemy gliders (section 6) fly this same model: their AI produces the
held-key bits the keyboard would, with per-type constants.

## 5. Rendering

Frame order in the back buffer `a4`:

1. Erase: every object's bounding box from two frames ago (a list of
   up to 16 boxes per buffer; rows cleared by 32-byte movem bursts of
   eight zeroed registers through a computed jump, plus a remainder
   burst -- today with a patched mask, to become prebuilt variants,
   section 2.1), then the dot list (section 5.3), which also carries
   the sparks and the radar's sweep and blips, then the sight if this
   buffer last showed it (section 5.4).
2. Input, simulation, AI (sections 3, 4, 6, 7), one step per beat.
3. Camera setup: sin/cos of `head`, lattice basis vectors.
4. Ground lattice dots.
5. Objects: world cull, frustum cull, transform, project, clip, face
   cull, draw.
6. Shots, sparks and fragments (sections 5.6, 7).
7. HUD: the sight unless it is blinked off, the radar sweep and
   blips, strip readouts when they change, meters.
8. VBL wait, flip, beat count. The frame bit cannot count two missed
   edges, so the work polls it at stage boundaries (after the lattice,
   after each drawn object; every stage is under a beat) and the
   loop's beats are 1 + the edges consumed, up to 3.

All erases run before any draw, so overlapping boxes cost nothing.

### 5.1 Camera transform and projection

For a world point relative to the camera `dx = wx - px`,
`dz = wz - pz` (integer parts), with `s = sin head`, `c = cos head`:

```
xc = (dx*c - dz*s) >> 8
zc = (dz*c + dx*s) >> 8
yc = wy + cam_h              ; ground plane is wy = 0, camera above it
```

An object with its own heading `phi` rotates its local vertices by the
single combined angle `a = phi - head` using the parade's yaw formula
(`x' = (x*ca + z*sa) >> 8`, `z' = (z*ca - x*sa) >> 8`), then adds the
object centre's camera-space `(xc, zc)`. Four multiplies per vertex.
Objects stand on the ground: centre `wy = -ybase` where `ybase` is the
mesh's largest y (distance from centre to its lowest point), emitted
per mesh by genmesh. Flying objects carry an altitude instead.

Projection uses the parade's constants with true depth in place of the
fixed `Z0`:

```
sx = 256 + xc*256/zc
sy = horizon + yc*170/zc      ; horizon = 80 (M1), tunable
```

Two `divs` per vertex, as today. Horizontal field of view is 90
degrees (a point at `xc = zc` lands on the screen edge); the vertical
extent follows from the 170 focal. The viewport is shifted: the
horizon sits at row 80 so the view is two thirds ground, and the
projection stays linear (no pitch). `znear` for the lattice is derived
from `cam_h` so the nearest dot lands on the last play row (138 units
at `cam_h` 128); objects use their own near plane, `znear_o` = 32
(M2), so a tower drifted past keeps its near edges until the last
moment.

### 5.2 Culling and clipping

Four levels, cheapest first:

- **World range**: an object is active only inside a square of side
  `2*R_active` around the camera (two compares, no multiplies).
- **Frustum**: on the object centre in camera space with the mesh
  radius `r`, in forms that never reject a sphere touching the view
  volume (checked exhaustively in the M2 fixed-point model,
  2026-09-10): reject if `zc + r < znear_o`, if `|xc| - zc > 1.5r`
  (the 45-degree side planes need `r*sqrt2`), if `yc - zc > 2r`
  (below) or `yc + zc/2 + 2r < 0` (above; the shifted viewport's top
  and bottom slopes are 0.47 and 0.935; the top strip of section 5.4
  lowers the top slope to 0.31, and the 0.47 form stays
  conservative). The first draft here,
  `|xc| > zc + r`, rejected visible spheres whose centre sits behind
  the camera.
- **Backface**: a plane test in the mesh's own frame (M2), replacing
  the parade's projected cross product, which needs valid projections
  for all three vertices and near-clipped vertices have none. genmesh
  emits per face an outward normal scaled to length 1024 and the plane
  constant `d = n.v0`; per object the eye is rotated into the mesh
  frame once (`ex = (zc*sa - xc*ca) >> 8`, `ez = -((zc*ca + xc*sa) >>
  8)`, `ey = -yc`, 4 multiplies) and a face is visible iff `n.e > d`
  (3 multiplies, a long compare). Exact whatever the clipping does;
  the meshes must be convex (genmesh asserts it). Edge masks are
  unchanged. The model showed the two tests agree on every pose with
  the whole mesh in front of the near plane.
- **Edge clipping**: needed because near objects overflow the screen
  and the line drawer has no clipping. Per vertex
  an outcode (1 left, 2 right, 4 above, 8 below, $10 at or behind
  `znear_o`); when the OR over the mesh is 0 the edges go straight to
  `draw_line`. Otherwise per edge: both outcodes ANDed nonzero skips
  it; a near endpoint is moved along the edge to `z = znear_o`
  (parametric `t` in 0.15 fixed point: one `divs`, two `muls`; 8.8
  would jitter by ~13 px at the near plane) and projected; then
  Cohen-Sutherland against the play rectangle (0..511, 0..239 in M2;
  28..239 with the top strip, section 5.4), one
  `muls` + `divs` per boundary crossed. Integer endpoints displace
  shallow segments a few pixels along their own direction at a
  boundary, never off it.

The `SHOW_RADIUS` 84 bound in `tools/genmesh.py` was for the parade's
fixed-depth projection and stops being a limit once edges are clipped;
the surviving limits are 16 vertices and 16 faces per mesh; a larger
structure would be assembled from several meshes.

### 5.3 Ground lattice

The ground is a world-aligned lattice of points with spacing `D` (256
units; 512 read as flat in M1), the same lattice structures stand on.
Rendered as
single red pixels (one plane; **decided** 2026-09-10: white dots would
blur into the mostly-white structures); this is the player's only cue
for speed, drift and heading, so it is required, not decoration
(**decided**).

Algorithm:

- Per frame: compute the camera-space position of one lattice corner
  and the two rotated step vectors `ux = (D*c, D*s)`, `uz = (-D*s,
  D*c)` (camera x, camera z per world step). Eight multiplies total.
- Walk a `(2N+1)^2` window of cells around the camera cell (`N =
  z_far / D`), reaching every point by adding step vectors: no
  multiplies per point. Reject `zc < znear`, `zc > z_far`, `|xc| >
  zc`.
- Project by table: `row = rowtab[zc >> 4]` (screen row for the
  ground depth, from `horizon + cam_h*170/zc`) and `sx = 256 +
  (xc * xscale[zc >> 4]) >> 8` where `xscale = 65536/zc` fits a word
  for `zc >= 64`. One multiply per dot.
- Plot: `a4 + row*128 + (sx>>3)*2 + 1` (the red, odd byte), mask
  `$80 >> (sx & 7)`, ORed in with a byte op. Record `(offset.w,
  mask.b)` in this buffer's dot list; erase next time round by ANDing
  the inverse.
- `z_far` = 2048 (M1): with `cam_h` 128 that is ten rows under the
  horizon, where dots start to merge anyway (Starglider faded them out
  for the same reason). Around 60 dots per frame; the window scan is
  the larger cost and can move to a wedge scan if the meters say so.
  M1 projects with two divides per dot instead of the tables above: a
  `zc>>4` table quantizes depth in 16-unit buckets, which is a
  20-row band at the near edge, and the dots would hop between rails.

Reverse motion needs nothing special: the dots flow toward the
horizon, which is the reverse indicator.

### 5.4 Screen layout and HUD

Layout (**decided** 2026-09-24, Battlezone's arrangement):

- **Top strip**, rows 0..27: the game HUD. The play area's clip
  rectangle starts at row 28, so no erase box ever reaches the strip,
  and its static parts are drawn once into both buffers at start.
- **Play area**, rows 28..239, horizon at row 80 (52 rows of sky).
  Near towers are cut by the strip's edge.
- **Bottom band**, rows 240..255: the development meters, as in M1/M2,
  until M5 decides between cockpit readouts and more view.

Elements:

- **Horizon**: none (**decided**: stark and dark). `hz_line` stays in
  the source for tests: one full-width red line at row `horizon`,
  redrawn each frame because erase boxes cut it. A skyline is on the
  back burner; if it ever comes, vector triangle mountains, not a
  raster strip (a `draw_line` silhouette across the screen would cost
  ~10 ms a frame).
- **Sight** (**decided**): the four-corner bracket sight, 32 px wide,
  green, centred on `(256, horizon)`: bars at rows +-11 with 4-row
  legs at their ends, and a stalk above and below out to rows +-26.
  No lock state. The stalks are the line of fire: with yaw only,
  everything dead ahead projects to x = 256 at any range and height,
  so a glider skimming below the eye sits on the lower stalk. It
  blinks (6 beats on, 6 off, about 4 Hz) while any player shot is in
  flight, so continuously under autofire, and shows red for 6 beats
  when the craft is hit (the damage flash the horizon line used to
  carry). Drawn by an unrolled sequence of `or.b` immediates after the
  objects; the matching `and.b` sequence clears it in the erase stage
  whenever the buffer last showed it, before anything is drawn under
  it (~0.4 ms each).
- **Radar** (**decided**), centre of the strip: heading-up, centre
  `(256, 13)`, radius 18 px by 12 rows, range 4096 units (about a
  whole sector, section 6; 1 px is ~228 units). Static frame: four
  compass ticks and the 90-degree view wedge, drawn once. A sweep
  line turns about every 1.4 s, from a precomputed pixel list per
  angle (the frame's pixels left out, so erasing the sweep never eats
  them). Blips: enemy gliders and mines red, generators white, energy
  packs green; obstacles are not shown. Entities inside the world box
  already have camera-space x/z from the culling, so their blips cost
  a shift and a table lookup; far ones are rotated round-robin, two
  per frame. Sweep and blips go through the dot list. ~1 ms a frame.
- **Shield bar**, top left: 8 segments, green, red at 2 or less, the
  spare craft as small icons under it. **Score** (6 digits,
  `draw_dec`) and **generators left** (a crystal icon and the count),
  top right. All redrawn only when they change, into both buffers.
- **No text messages** (**decided**: no ENEMY TO LEFT and the like).
- **Windshield crack** (**decided**): when the shield reaches zero
  the view freezes, and eight precomputed crack groups (white) appear
  one per frame over the play area, then hold before the next craft.

### 5.5 Colour semantics

`lib/draw_line.asm` codes: white 3, green 2, red 1. Fixed meaning:

| Colour | Used for |
|---|---|
| white | structures (towers, blocks), generators and their blips, the windshield crack |
| red | ground lattice; hostiles: enemy gliders, mines, their shots and blips; the low-shield bar and the sight's hit flash; the horizon line when on |
| green | HUD, sight, radar frame and sweep, energy packs and their blips, player shots |

Sparks take the colour of what exploded (section 5.6). Single-plane
colours are slightly cheaper than white per pixel
(`docs/vector-perf.md`), so the most numerous moving things are red or
green.

### 5.6 Explosions

**Decided** 2026-09-24: dot sparks, replacing the v0.1 plan (the
victim redrawn scaled and jittered for a few frames), which costs a
whole object per frame (~13 ms, section 9).

- 16 sparks per glider (32 for a generator, 4 per non-fatal hit on
  one), in the victim's colour, flying out from its centre with random
  velocities and an upward bias, under gravity, bouncing on the ground
  at a third of their speed, living 12..20 beats.
- Cheap path: the offsets live in camera-aligned axes around the
  victim's centre and are projected with the centre's depth: `sx =
  csx + ox*kx`, `sy = csy + oy*ky`, with `kx = xfocal/zc` and `ky =
  yfocal/zc` (8.8, two divides per explosion per frame). Two
  multiplies per spark and no rotation: a burst is isotropic, so not
  rotating its offsets when the player turns is invisible, and the
  shared depth keeps its size right as the player closes in. Plotted
  and erased through the dot list like the lattice dots: ~2 ms per
  exploding object per frame (estimate).
- Option: four short edge fragments tumbling out with the sparks,
  ~0.25 ms each as clipped 3D segments.

## 6. World and entities

- **Sector** (**decided** 2026-09-24): a 32 x 32-cell square (8192
  units) that wraps both ways, as Battlezone's field does. No walls
  and no bounds rule. Camera-relative offsets wrap with a shift pair
  on the 16-bit difference (`lsl.w #3` then `asr.w #3`: the 13-bit
  difference, sign-extended), so every entity is seen at its nearest
  image, and positions only need to be right modulo 8192 (the craft's
  integer position can simply wrap as a word). The lattice stays
  seamless because 8192 is a multiple of `latd`. The free 16-bit wrap
  would give 256 cells, far too sparse at our scale.
- **Entity record** (16 bytes, pool of 64, as built in M2): mesh
  directory index (-1 ends the pool), flags (0 = inactive), x, z
  (16-bit integer world units, the fractional part only matters for
  the player), centre height above the ground (`yb_<mesh>` for
  standing meshes, `cam_h` for the mine), heading (8.8 brads), two
  words for hp, timers and AI state (M3). Static entities (towers,
  blocks, generators, mines, energy packs) come from the sector's
  level table, copied into the pool at start; dynamic ones (gliders,
  shots, explosions) are allocated from the pool.
- **Mesh directory** (`tools/genmesh.py --game`, 32 bytes per mesh):
  counts, colour, vertex/face/edge/plane table offsets, ybase,
  bounding radius, collision radius; edge tables index the engine's
  12-byte vertex scratch records directly. The parade's default
  output is untouched.
- **Types and meshes** (all convex; genmesh asserts it):
  - tower: hex prism, vertex radius 48, 384 tall (top 256 above the
    eye; M2), white, obstacle; stops shots.
  - block: 192 cube bunker, top below the eye (M2 scenery), white,
    obstacle; stops shots.
  - generator: a white crystal (a tall bipyramid, 384 tall, radius
    96, standing on its lower tip), turning slowly; 5 hits; the
    sector's targets. Launches the enemy gliders (below).
  - enemy gliders (**decided**): abstract, red, 4..6 vertices, which
    should cost roughly half a tower each (estimate), so 3..4 can
    share the screen. Everything is seen nearly edge-on from 128
    units up, so the shapes carry height (a fin, a wedge), not flat
    wings. Nothing the player must shoot leaves the ground plane: they
    skim it like the player, hull centre ~72 units up, just under the
    eye.
    - dart (4 vertices: the flat tetrahedron with a dorsal point):
      fast, 1 hit, charges and fires on the pass;
    - wedge (5: a pyramid lying on its side, nose forward): 2 hits,
      holds its range and strafes;
    - kite (6: a bipyramid on a kite outline): 3 hits, fires bursts.
  - mine (**kept**): the red octahedron at hover height, static
    hazard; 1 hit destroys it (score), contact costs 2 shield.
  - energy pack: a small green octahedron floating ~44 units up,
    spinning; flying over it collects it (+2 shield, capped at 8).
  - shots: short line segments along their velocity, no mesh.
- **AI** (M3): gliders fly the player's flight model (section 4) with
  AI-made key bits: turn toward a target bearing, thrust or brake to
  hold the type's preferred range, fire when the player is inside a
  small cone and in range. They drift through turns just as the
  player does.
- **Generators launch the gliders** (**decided**): each keeps up to
  two of its own alive, relaunching after a delay, under a global cap
  on active gliders (4 to start: the budget knob). Hitting a generator
  alerts the gliders near it. A destroyed generator stops launching,
  so the enemy count, and the CPU load, falls as the player
  progresses.
- **Energy packs**: fixed spots in the level table, plus an
  occasional drop where a glider dies.
- **Objectives and lives** (**decided**): destroy every generator.
  The last one triggers the warp: controls lock, the craft
  accelerates (the lattice streams past), black, the sector number,
  the next map. Each sector adds generators and enemy speed and
  removes packs. Three craft per game: at zero shield the windshield
  cracks (section 5.4), then the next craft restarts the sector at
  its spawn with a full shield, destroyed generators staying
  destroyed; game over after the third. Score for gliders, mines and
  generators, plus a sector bonus.

## 7. Combat and collisions

Everything lives on one plane, so every test is 2D, and every test
runs once per beat (section 2.1).

- **Collision test**: squared distance `dx*dx + dz*dz < r*r` (two
  multiplies), preceded by a box reject. Player vs tower, block or
  generator = 1 shield and a bounce (velocity reflected and halved);
  player vs glider = 1 shield and a bounce for both; player vs mine
  = 2 shield, mine destroyed; player over an energy pack = +2 shield.
- **Player shots** (**decided**: several in flight, arcade): up to 4,
  one every `fire_cd` beats while Space is held, speed `shot_v`, life
  `shot_life` beats. Launched alternately from two gun ports (44 units
  either side, 48 below the eye), parallel to the heading, so the
  bolts converge on the aim point; a shot launched from the eye would
  sit on the vanishing point as a single dot. Drawn green, ~0.4 ms
  each (estimate). Each beat, tested against gliders, generators,
  mines and obstacles in range; towers and blocks stop them.
- **Aim assist**: dropped with the lock (2026-09-24); it can return in
  M3 if digital aiming proves too coarse.
- **Enemy shots**: a pool of 4, red, fired along the glider's heading,
  slow enough to see and slide out of (the drift is the dodge); they
  hit the player inside `craft_r` and are stopped by obstacles.
- **Damage**: `shield` holds 8. A hit turns the sight red (section
  5.4) and plays the damage sound; zero = craft destroyed, windshield
  crack, next craft (section 6).
- **Explosions**: dot sparks (section 5.6).

## 8. Sound

`lib/ipc_sound_takeover.asm` (include first, keys lib after it):
`snd_beep` effect blocks for fire, hit, explosion (random + fuzz),
the energy-pack chime, damage, the warp. One beep transfer costs about
2 ms, so at most one sound trigger per frame, with a priority order
(explosion > damage > pickup > fire). Beeps are IPC transfers like the
KEYROW read, so they go where it goes: after the work, before the VBL
wait (CLAUDE.md rule 13). A sustained engine tone is free per frame
but warbles when the keyboard is read; try it, drop it if it annoys.

## 9. Budgets

**Design budget v0.2 (2026-09-24)**: 3 beats, 60 ms of effective time
on a stock QL. A busy frame, from the measurements below plus
estimates (marked ~):

| Stage | ms |
|---|---|
| lattice, erase, input, flight, dev readouts (M1, flying) | 19.4 |
| top strip: sight, radar sweep and blips | ~1.5 |
| 2 gliders (4..6 vertices, about half a tower each) | ~12 |
| 1 tower or generator | ~13 |
| 6 shots in flight at ~0.4 ms | ~2.5 |
| one explosion (16 sparks) | ~2 |
| **total** | **~50** |

That leaves ~10 ms for a third glider or a heavier pose; sectors are
laid out for at most ~4 meshes in the frustum. The M2 levers below
still apply if a sector's worst pose spills past 3 beats.

The v0.1 estimates, kept for the record -- cycles per 2-beat frame
(300 000 cycles), all to be replaced by meter readings; the parade's
per-object costs are measured, the rest are estimates:

| Stage | Estimate |
|---|---|
| erase (boxes + dots) | 15 000 |
| input, flight, AI, collisions | 10 000 |
| lattice (scan + ~60 dots) | 25 000 |
| objects, 4 to 6 visible at 15 000..25 000 each | 60 000..150 000 |
| shots, effects, HUD, horizon | 10 000 |
| headroom | the rest |

**Measured, M1 rig (Q-emuLator, 2026-09-10)**: 128/128 loops at 2
beats and 675 average idle spins, i.e. **26.5 ms of work per frame**
with only the lattice and the HUD on screen. Calibration rule
(consistent with the lines/cube figures in `docs/vector-perf.md`):
effective time is about **1.8x the 68008 count** (8 cycles per word
fetch), roughly 3.5x a 68000 table count; the estimates above were
68000-table numbers and are 3-4x optimistic. Where the 26.5 ms went:
lattice scan of 361 cells ~8 ms, ~60 dots at ~850 68008 cycles each
(two divides plus bookkeeping) ~12 ms, five `draw_dec` fields plus the
bar ~4 ms, erase + KEYROW + flight + horizon ~2.5 ms. The object row
is optimistic by the same factor: the parade measured 11-17 ms per
screen-filling object, and a distant tower with ~20-px edges is still
several ms. Same day, after the wedge scan (per lattice row the four
visibility tests bound the cell range analytically; 111 cells walked
instead of 361), the table-driven dot path (row-offset and reciprocal
tables per integer depth in the job's dataspace, no divides per dot)
and cheaper instrumentation: **16.3 ms average, 18.3 ms worst** at
rest, 2 spills in 128 = locked 50 Hz. While flying: 19.4 ms average
and 91 spills in 128, because the spawn view is a light pose (49 dots)
and other poses reach 72 dots at ~127 us each plus more wedge boundary
cells; so 50 Hz at light poses, 25 Hz at heavy ones. Next lattice cut
if wanted (~3.5 ms): no per-cell tests inside the bounded range (the
bounds are conservative by two cells, the interior is visible by
construction), a mask table and a register-held near plane with the
row start moved to memory, no screen-edge clip at the 90-degree FOV.
Caveat found on the way: the KEYROW read must sit after the work,
before the VBL wait, or Q-emuLator's frame timing goes erratic
(CLAUDE.md rule 13).

**Measured, M2 (Q-emuLator, 2026-09-10)**, spawn pose at rest: 9
objects drawn (6 towers at 640..2176 units, 2 blocks, 1 mine; a near
tower is ~520 px of edges, a far one ~156) on top of the lattice: 831
extra beats in 128 loops (6.5 average), idle 602 spins average, 27
min, 1265 max. The min/max pair says the work sits at a multiple of
20 ms with +-2 ms of jitter (the KEYROW read on alternate loops: 668
vs 536 spins), so the loop alternates 7 and 8 beats: **~140 ms of
work, about 13 ms per object including its erase box**, in line with
the 1.8x rule applied to the estimates above (the 15 000..25 000 row
is 50 000..90 000 effective cycles = 7..12 ms). Drawing is right
(screen readings: no through-edges, clean clipping through towers and
mines, HUD untouched). Levers, largest first: scene density (the M2
level shows six towers at once; the game should keep 2..4 in the
frustum, and a far cull at `z_far` drops the slivers), a far level of
detail for towers (most objects are far, and their cost is per-vertex
overhead, not pixels: a 4-vertex silhouette cuts it 3x), the lattice's
`zfar` (16 ms today), a reciprocal table for the two projection
divides per vertex (~0.5 ms per object), and a 3-beat design budget
(60 ms: lattice + HUD + 3..4 objects) instead of the 2-beat one.

Memory: code + tables well under 64 KB; meshes a few KB; two dot lists
of 128 x 4 bytes; entity pool 64 x 16 bytes; level tables a few KB.
Meters stay in the build (`no_erase`/`no_draw` style flags) until the
budget is confirmed on Q-emuLator and one FPGA core.

## 10. Build and files

The game lives in `glider/`, copied from `shapes/` (renamed if the
title calls for it). `glider.asm` is the manifest of one assembly
unit (its include order is the memory layout) plus the job header,
takeover and frame loop; routines live in `flight.asm`,
`render.asm`, `hud.asm`, and the non-code in `equates.inc` (tuning
knobs, record offsets), `macros.inc`, `vars.inc`, `level.inc`,
`meshes.inc` (`tools/genmesh.py --game`: world-scale meshes, face
planes, extended directory) and `sin.inc`; then `boot`, `.QCF`,
`Makefile` with `NAME`, `DATASPACE`, `run`, `mdv`, `runmdv` targets.
Include order: `../lib/ipc_sound_takeover.asm`,
`../lib/ipc_keys_takeover.asm`, `../lib/draw_line_w.asm`,
`../lib/draw_line.asm`, `../lib/draw_dec.asm`. Level tables start as
hand-written `dc.w` blocks; a `tools/genlevel.py` follows once the
format settles. Absolute pointers in data are forbidden (flat PIC):
initialise with `lea label(pc)` at runtime. No self-modifying code
(section 2.1).

## 11. Milestones

1. **M1 flight rig**: input, flight model, lattice, horizon, reticle,
   meters showing speed and heading. Answers "does digital steering
   with drift feel good" and fixes the section 4 constants.
   **Done 2026-09-10** (`glider/`): feel approved with the section 4
   values as noted there; lattice ~14 ms worst case after the wedge
   scan and tables (section 9); decision: no further lattice work
   until objects are on top, dot density (`latd`, `zfar`) is the big
   lever if playability suffers.
2. **M2 world**: entity table, camera transform, four-level culling,
   near and 2D clipping, multi-object erase. Drive around towers.
   **Built 2026-09-10** (`glider/`, meshes rescaled first: tower R48
   H384, block 192, mine as is): the pipeline of sections 5.1/5.2 as
   now written, a fixed-point model of every step checked against
   float references before the assembly, a 24-entity level (tower
   avenue, flank blocks, centreline mines). **Done the same day**:
   screen readings clean (no through-edges from any angle, clean
   near/2D clipping through towers and mines, HUD untouched); the
   near-plane stretching when flying through a mine is accepted, and
   the horizon went red because a white line through the red mine
   sitting on it read badly. Budget: ~13 ms per object (section 9),
   so the work before M3 is budget, not features.
3. **M3 combat**: first the v0.2 groundwork -- the top strip (clip
   top at row 28, the sight, the radar), the erase without
   self-modifying code, the wrapping sector -- then shots (per beat,
   gun ports, the sight's blink), collisions, shield and hit flash,
   sparks, enemy gliders and their AI, generators launching them,
   mines, sound.
4. **M4 sectors**: level tables (`tools/genlevel.py`), energy packs,
   the warp, three craft and the windshield crack, score, title and
   end screens.
5. **M5 polish**: difficulty ramp, the bottom band's fate, `.mdv`
   release, checks on MiSTer / Next / real hardware, and on a faster
   machine (`Speed=Full`; a Gold Card if one is at hand).

## 12. Decisions and open questions

**Decided** (v0.1): first-person, craft never drawn; yaw only, no
pitch, roll or banking; fixed camera height; lattice ground and fixed
horizon; tank controls with inertia and drift; joystick parity on
arrows + Space; brake then reverse after a full stop; wireframe with
the section 5.5 colour meaning; beat-scaled simulation.

**Decided** (v0.2, 2026-09-23/24): carrier, personnel and
pickup-by-stopping dropped; the sector loop (destroy every generator,
warp to the next map); 32 x 32-cell wrapping sectors; generators
launch the enemy gliders; abstract enemy gliders (dart, wedge, kite),
a few at a time; mines kept; energy packs refill the shield; an
8-unit shield with a bar; three craft; the windshield crack; several
player shots with autofire from two gun ports; the four-corner sight,
32 px, no lock, blinking while shots fly; the radar strip at the top,
no text messages; dot-spark explosions; the stark black look with no
horizon line or skyline; a 3-beat design budget with the game the
same at any frame rate; no self-modifying code.

**Open**:

- Setting and title (moon base, ship hull, terraformed planet).
- `horizon` row, `D`, `cam_h`, `z_far`: M1 picked 80 / 256 / 128 /
  2048 (2026-09-10) after 120 / 512 / 40 / 4096 read as a flat
  strip; still tunable in `glider/equates.inc`.
- Drift constants; turn rate coupled to speed or not.
- Radar scale: 4096 units over 18 px bunches the nearby blips; if it
  reads badly, a 2048 range with out-of-range generators pinned to
  the rim at their bearing.
- Score values, extra craft (at score thresholds or not), the
  difficulty curve per sector.
- The warp effect's details; what the bottom band becomes (M5).
- Skyline (back burner): vector triangle mountains, if ever.
