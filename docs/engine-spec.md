# Game engine spec -- ground-skimmer raid (working title)

Draft v0.1, 2026-09-06. Assembled from the control-scheme brainstorm.
Everything marked **decided** came out of that discussion; open points
are collected in section 12. The engine builds on `shapes/` (reference
3D engine) and the `lib/` routines; nothing here contradicts
`docs/takeover.md`, `docs/vector-perf.md` or the CLAUDE.md rules.

## 1. Concept

- **Setting**: an entirely artificial, flat world. Candidates: an
  occupied moon turned into a base, the hull of a vast ship, or a
  planet terraformed flat and built over. Flatness is a design fact
  the engine exploits (fixed horizon, dot lattice), so the fiction
  should own it: everything the player sees was built.
- **Player**: a fragile hovercraft, first-person cockpit view, the
  craft itself is never drawn (**decided**).
- **Sortie loop**: launch from the carrier, weave between towers,
  ambush patrols, destroy shield generators, pick up stranded
  personnel, return to the carrier. Missions are sorties; the carrier
  is home, refit and score-in.
- **Aesthetic**: Starglider 1 / arcade Star Wars wireframe with
  backface culling, no filled polygons, mode 4 colours with fixed
  meaning (section 5.5).

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
  is defined per beat and multiplied by the beats the previous loop
  took (1, 2 or 3), exactly as the parade steps its rotation. The
  design budget is a 2-beat frame (25 Hz, ~300 000 CPU cycles); light
  scenes run at 50 Hz for free and heavy ones degrade to 3 beats
  without changing speed.

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
| Enter | scanner overlay toggle | non-essential |
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

## 5. Rendering

Frame order in the back buffer `a4`:

1. Erase: every object's bounding box from two frames ago (existing
   movem clear, per buffer), then the dot list (section 5.3).
2. Input, simulation, AI (sections 3, 4, 6, 7).
3. Camera setup: sin/cos of `head`, lattice basis vectors.
4. Ground lattice dots.
5. Objects: world cull, frustum cull, transform, project, clip, face
   cull, draw.
6. Projectiles and effects.
7. HUD: horizon line, reticle, meters.
8. VBL wait, flip, beat count.

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
at `cam_h` 128); objects use their own near plane.

### 5.2 Culling and clipping

Four levels, cheapest first:

- **World range**: an object is active only inside a square of side
  `2*R_active` around the camera (two compares, no multiplies).
- **Frustum**: on the object centre in camera space with the mesh
  radius `r`: reject if `zc < znear - r` or `|xc| > zc + r`; the
  vertical test uses `|yc| > zc*3/4 + r` (approximation of the 170
  focal against half-height 120).
- **Backface**: the existing per-face cross-product test and edge
  masks, unchanged.
- **Edge clipping** (new): needed because near objects and the
  carrier overflow the screen and the line drawer has no clipping.
  Fast path: if all projected vertices fall inside the play area,
  draw as today. Otherwise per edge: a vertex with `zc < znear` is
  flagged; both flagged skips the edge, one flagged clips the edge
  against `z = znear` in camera space (parametric, one divide) before
  projection; then the 2D segment is clipped to the play rectangle
  (0..511, 0..239) with outcode tests. Only objects that fail the fast
  path pay.

The `SHOW_RADIUS` 84 bound in `tools/genmesh.py` was for the parade's
fixed-depth projection and stops being a limit once edges are clipped;
the surviving limits are 16 vertices and 16 faces per mesh, and any
larger structure (the carrier) is assembled from several meshes.

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

### 5.4 Horizon and HUD

- **Horizon**: one full-width line at row `horizon`, redrawn each
  frame (one 128-byte fill) because erase boxes may cut it. It never
  moves: no pitch, no roll. A 16-px gap at the centre frames the aim
  point.
- **Aim point**: in a yaw-only world every target at hover height
  projects onto the horizon row whatever its distance, so the sight is
  on the horizon (M1: green ticks around the gap, not a cross on the
  line). Consequence to keep in mind: the horizon line runs through
  every hostile; if that reads badly with meshes, try a dotted line.
- **Play area**: rows 0..239. **HUD band**: rows 240..255, never
  touched by erases. Static cockpit lines drawn once into both buffers
  at start; live readouts via `lib/draw_dec.asm` (shield, speed or
  fuel, rescued crew, score) at the rows the parade meters use.
- **Reticle**: a small cross at `(256, horizon)`, redrawn each frame
  (four short lines).
- **Scanner** (Enter): an overlay in a corner of the play area showing
  generators, patrols, personnel and the carrier bearing relative to
  the heading. Essential in a yaw-only world where the player cannot
  climb to look around; design open (section 12).

### 5.5 Colour semantics

`lib/draw_line.asm` codes: white 3, green 2, red 1. Fixed meaning:

| Colour | Used for |
|---|---|
| white | structures (towers, generators), horizon |
| red | ground lattice; hostiles: patrols, fighters, mines, their shots, damage flashes |
| green | HUD, reticle, personnel beacons, the carrier, player shots |

Single-plane colours are slightly cheaper than white per pixel
(`docs/vector-perf.md`), so the most numerous moving things are red or
green.

## 6. World and entities

- **World**: a bounded square of `W x W` cells (64 initially) with the
  carrier near one edge. Leaving the square is soft-blocked (velocity
  reflected, warning tone); exact rule open.
- **Entity record** (16 bytes, pool of 64): type, flags/state, x, z
  (16-bit integer world units, the fractional part only matters for
  the player), heading, hp, timer, mesh directory index, AI data.
  Static entities (towers, generators, personnel, carrier parts) come
  from a level table; dynamic ones (patrols, shots, explosions) are
  allocated from the pool.
- **Types and meshes** (`tools/genmesh.py` gains a `ybase`, collision
  radius and mesh radius per entry in the directory):
  - tower: existing hexagonal tower, white, obstacle.
  - shield generator: new low mesh (dome or pyramid on a base), white,
    3 hp, mission target.
  - patrol tank / walker: new low-poly mesh, red, ground AI.
  - fighter: existing `fighter` or `dart`, red, flies at hover height
    so it can be hit from level flight (**decided**: nothing the player
    must shoot leaves hover height).
  - mine: existing octahedron, red, static hazard.
  - personnel beacon: small green marker (tetrahedron), pickup.
  - carrier: several white/green meshes on the lattice, landing pad
    marked; the only "large" object.
  - shots: short line segments along their velocity, no mesh.
- **AI**: patrols follow waypoint loops along lattice lines. Within
  detect range and inside a front cone they turn toward the player at
  a fixed rate and fire when aligned within a small cone. Generators
  are static; hitting one raises an alert that redirects nearby
  patrols. Personnel are picked up when the craft has been at rest
  within `pickup_r` for `pickup_beats` (Down doubles as the interact
  key, **decided**). Landing on the carrier = at rest within its pad
  radius: ends the sortie, banks rescues, restores shield.
- **Objectives** per level: destroy all generators, rescue at least M
  personnel, return. Score for kills, rescues, and time.

## 7. Combat and collisions

Everything lives on one plane, so every test is 2D.

- **Collision test**: squared distance `dx*dx + dz*dz < r*r` (two
  multiplies), preceded by a box reject. Player vs tower/generator/
  carrier = crash damage plus bounce (velocity reflected and halved);
  player vs mine = heavy damage, mine destroyed.
- **Player shots**: launched from the camera along `head`, speed
  `shot_v`, life `shot_life` beats, at most 4 in flight, one every
  `fire_cd` beats while Space is held. Drawn green. Each beat, test
  against active entities within range.
- **Aim assist**: at launch, if a hostile is inside a narrow cone
  ahead, nudge the shot heading toward it by at most `assist_max`
  brads. Hides the coarseness of digital aiming; the cone is tunable.
- **Enemy shots**: same pool, red, hit the player inside `craft_r` of
  the camera.
- **Damage**: `shield` decrements; zero = craft destroyed, sortie
  lost. Damage flashes the horizon red for a frame.
- **Explosions**: the victim's mesh drawn scaled up and jittered for a
  few frames, then removed (cheap, uses the existing draw path).

## 8. Sound

`lib/ipc_sound_takeover.asm` (include first, keys lib after it):
`snd_beep` effect blocks for fire, hit, explosion (random + fuzz),
pickup chime, damage, carrier landing. One beep transfer costs about
2 ms, so at most one sound trigger per frame, with a priority order
(explosion > damage > pickup > fire). A sustained engine tone is free
per frame but warbles when the keyboard is read; try it, drop it if it
annoys.

## 9. Budgets

Cycle estimates per 2-beat frame (300 000 cycles), all to be replaced
by meter readings; the parade's per-object costs are measured, the
rest are estimates:

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

Memory: code + tables well under 64 KB; meshes a few KB; two dot lists
of 128 x 4 bytes; entity pool 64 x 16 bytes; level tables a few KB.
Meters stay in the build (`no_erase`/`no_draw` style flags) until the
budget is confirmed on Q-emuLator and one FPGA core.

## 10. Build and files

New top-level directory copied from `shapes/` (name to pick with the
game's title): `<name>.asm`, `meshes.inc` (genmesh with the game
meshes and the extended directory), `sin.inc`, `boot`, `.QCF`,
`Makefile` with `NAME`, `DATASPACE`, `run`, `mdv`, `runmdv` targets.
Include order: `../lib/ipc_sound_takeover.asm`,
`../lib/ipc_keys_takeover.asm`, `../lib/draw_line_w.asm`,
`../lib/draw_line.asm`, `../lib/draw_dec.asm`. Level tables start as
hand-written `dc.w` blocks; a `tools/genlevel.py` follows once the
format settles. Absolute pointers in data are forbidden (flat PIC):
initialise with `lea label(pc)` at runtime.

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
3. **M3 combat**: shots, collisions, damage, explosions, patrol AI,
   sound.
4. **M4 mission**: generators, personnel, carrier, sortie loop, score,
   title and end screens.
5. **M5 polish**: scanner overlay, difficulty ramp, `.mdv` release,
   checks on MiSTer / Next / real hardware.

## 12. Decisions and open questions

**Decided**: first-person, craft never drawn; yaw only, no pitch, roll
or banking; fixed camera height; lattice ground and fixed horizon;
tank controls with inertia and drift; joystick parity on arrows +
Space; brake then reverse after a full stop; pickup by stopping; every
mission-critical target at hover height; wireframe with the section
5.5 colour meaning; beat-scaled simulation with a 25 Hz design budget.

**Open**:

- Setting and title (moon base, ship hull, terraformed planet).
- World bounds rule (soft bounce vs wall of towers vs wrap).
- `horizon` row, `D`, `cam_h`, `z_far`: M1 picked 80 / 256 / 128 /
  2048 (2026-09-10) after 120 / 512 / 40 / 4096 read as a flat
  strip; still tunable in `glider/glider.asm`.
- Drift constants; turn rate coupled to speed or not.
- Scanner design (radar disc vs bearing arrows vs off-screen markers).
- Explosion style beyond scale-and-jitter.
- Whether the carrier is a landing pad or a hangar mouth flown into.
