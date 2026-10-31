# glider — STARQLIDER, a wireframe hovercraft raid

STARQLIDER 1.0 (Halloween 2026) was developed for the Sinclair QL game
jam of the Retro Programmers United for Obsolete Systems (RPUFOS):
<https://itch.io/jam/rpufos-sinclair-ql>.

A first-person raid over a flat, entirely artificial world, flown in a
fragile hover-glider with tank controls and drift. Starglider 1 is the
look, and Battlezone supplies a few ideas. It runs on a stock QL
(68008, 128K) in mode 4 with the machine fully taken over,
double-buffered at the VBL. The design, budgets and milestones are in
[docs/engine-spec.md](../docs/engine-spec.md).

**Status: 1.0.** You fly a wrapping 8192-unit sector of towers, blocks
and mines, with the four-corner sight, a heading-up radar, the shield
bar, the score, the crystals left and the spare craft in the top strip.
White generator crystals launch enemy gliders (darts, wedges and
kites, up to four at once) that patrol round them until you come close
or shoot their crystal, then attack and fire red bolts you can slide
out of; from sector 2 the crystals fire too, from further than your
guns reach. Destroying every crystal warps you to the next sector: a
ladder of eight, each adding one thing that its card names, then a
harder lap on a loop (engine spec section 11.2, `tools/genlevel.py`).
Three craft per game, a windshield crack when one is lost, a title
screen, a pause, all text in vector letters (`lib/draw_text.asm`).
Busy scenes take 4 to 5 beats (12.5 to 10 Hz) against a design budget
of 3 (engine spec, section 9). The build is the release's by default:
`dev` in `equates.inc` brings back the development band. The note for
players, shipped in the release as `README.txt`, is
[PLAYERS.txt](PLAYERS.txt).

## Build and run

```
make          # check the register contracts, assemble, package glider.qlpak
make run      # launch Q-emuLator (close it before rebuilding)
make mdv      # glider.mdv, a Microdrive image for real hardware and FPGA cores
make release  # the 1.0 release: release/starqlider-1.0.zip (.qlpak, .mdv,
              # PLAYERS.txt as README.txt, LICENSE.txt)
make runmdv   # boot the .mdv in Q-emuLator
make check    # the register-contract check alone
```

The toolchain is described in the [root README](../README.md). On the
MiSTer QL core the wireframes flicker; that's a core bug, see
[docs/mister-flip-latch-issue.md](../docs/mister-flip-latch-issue.md).

## Controls and screen

Space starts a game from the title screen. Arrows: Left/Right turn,
Up thrusts, Down brakes, and holding Down at a standstill engages
reverse. Space fires (held: autofire). Esc pauses (Esc again goes
on). In a `dev` build, Enter puts the craft back at the spawn point
with a full shield.

The strip at the top holds the shield bar on the left (8 slots, red at
2 or less; a bump or an enemy bolt costs 1, a mine 2; at zero the
craft is lost, and the third one ends the game; a delta under it per
spare craft), the radar in the middle (the view wedge, a sweep, a red
blip for every mine and glider and a white one for every crystal
within 2304 units -- the ones further away sit on the rim, in their
direction), and at the right the crystals left and the score (mine
50, dart 100, wedge 200, kite 300, crystal 1000). The sight flashes
red when you lose shield; when it runs out, the windshield cracks. A
dart dies to 1 hit, a wedge 2, a kite 3, a crystal 5 to 10 (the
sector's rule).

In a `dev` build the band at the bottom shows speed and drift (tenths
of a unit per beat), heading and the number of objects drawn. The
second group of readouts and the bar along the bottom edge are
performance meters measuring idle time per frame; `hud.asm` explains
each field. The release build leaves the band black but still counts the
meters (`make shot PEEK="headroom+12:w headroom+14:w"`).

Unattended test runs (`make shot` cannot press keys): `test_keys`
holds keys down in play, `test_auto` presses Space on the title (and
Esc in a pause) after that many frames, `test_shield` starts every
craft with that shield, `test_gl` puts three gliders ahead at the
start, `test_warp` starts every sector with its crystals destroyed (it
warps through them), `test_spawn` uses `spawn_x/z/head` instead of the
sector's spawn, `test_sect` starts a game at that sector (its index
from 0).

## Where things are

`glider.asm` is the only file vasm is given. It includes the rest, and
the include order is the memory layout.

| File | Contents |
|---|---|
| `glider.asm` | file map, job header, takeover, the frame loop |
| `equates.inc` | hardware addresses, the tuning knobs, record layouts |
| `flight.asm` | flight model (one step per 20 ms beat), craft reset |
| `combat.asm` | the craft's collisions and shield, the player's shots |
| `enemy.asm` | the enemy gliders (AI, flight, bumps), the generators, enemy shots |
| `boom.asm` | explosions: dot sparks from precomputed bursts |
| `lattice.asm` | the ground-dot stage (wedge scan, table projection) |
| `objects.asm` | the object stage: cull, transform, clip, draw, erase boxes |
| `render.asm` | the erase stages, projection, clipping, list helpers |
| `hud.asm` | readouts, meters, headroom bar, the frame's sound effect |
| `flow.asm` | the game flow's resets: a new game, a sector, a craft, the screens |
| `screens.asm` | title, sector card, game over, pause; text helpers |
| `strip.asm` | the sight and the top strip's radar |
| `macros.inc`, `vars.inc` | loop macros, variables |
| `levels.inc` | the sectors (generated by `tools/genlevel.py`) |
| `strip.inc`, `crack.inc` | the strip's tables and icons; the windshield crack (`tools/gencrack.py`) |
| `types.inc`, `sounds.inc` | the glider types' constants, the sound effects |
| `texts.inc` | the words on the screens around play |
| `meshes.inc`, `sparks.inc`, `sin.inc` | generated by `tools/genmesh.py --game`, `tools/gensparks.py` and `tools/gensin.py` |

The line drawers, the decimal readout and the IPC keyboard and sound
routines come from [`lib/`](../lib). Every routine carries a register
contract that `tools/regcheck.py` checks on each build; the rules and
the project's other conventions are in [CLAUDE.md](../CLAUDE.md).
