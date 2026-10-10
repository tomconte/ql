; glider.asm -- the hovercraft raid, M2 world (docs/engine-spec.md)
;
; First-person, yaw-only camera at a fixed height over a flat world:
; an IPC keyboard read on alternate frames (row 1: arrows + Enter), the
; section-4 flight model (ramped turn, thrust, drag = drift, brake then
; reverse), a world-aligned lattice of red ground dots, the fixed
; horizon, a reticle and HUD readouts (M1, the flight rig), and now
; wireframe objects on the lattice (M2): a static entity table (towers,
; blocks, mines from meshes.inc), the camera transform, four-level
; culling (world box, bounding sphere against the frustum, faces by
; their planes with the eye in the mesh's frame, edges by outcodes),
; near-plane and 2D clipping for the edges the line drawers cannot
; take, and one erase box per drawn object. The flight constants (the
; equ block below) were tuned by feel in M1.
;
; Scaffold from shapes/shapes.asm: MODE 4 takeover, double buffer with
; VBL flip, beat-scaled simulation (1|2 beats per loop), live headroom
; bar + averaged decimal meters (lib/draw_dec.asm). The lattice replaces
; the mesh pipeline; the erase is a per-buffer dot list instead of the
; bounding-box movem clear. The lattice is a wedge scan: per world row
; the four visibility tests bound the cell range analytically, and the
; dots project through two tables (row offset, reciprocal) built into
; the job's dataspace at startup -- the first version walked all 361
; cells and divided twice per dot, at 20 ms a frame.
;
; Assemble: make (vasmm68k_mot -m68008 -Fbin -Dds_avail=<DATASPACE>
; -o glider_bin glider.asm)
;
; Sources: this file is the manifest of one assembly unit, and the
; include order below IS the memory layout (flat PC-relative binary):
;   equates.inc  hardware, tuning knobs, profiling flags, records
;   macros.inc   wbound, beat_poll
;   this file    job header, takeover, frame loop
;   flight.asm   flight_step, craft_reset
;   combat.asm   the craft's collisions and shield, the player's shots
;   enemy.asm    the enemy gliders: AI, flight, bumps, launches; their
;                shots
;   boom.asm     explosions: dot sparks from precomputed bursts
;   lattice.asm  the lattice stage, wedge records
;   objects.asm  the object stage
;   render.asm   list selectors, the erase stages, erase-box extend,
;                projection, clipping
;   hud.asm      readouts, meters, meter window, headroom bar, sound
;   strip.asm    the sight, the radar (the top strip)
;   flow.asm     the game flow's resets: game, sector, craft, screens
;   screens.asm  title, sector card, game over, pause; text helpers
;   vars.inc     variables and scratch
;   level.inc    static entity table
;   types.inc    the enemy glider types
;   sounds.inc   the sound effects
;   texts.inc    the words of the screens around play
;   then meshes.inc, sparks.inc and sin.inc (generated), the supervisor
;   stack, the
;   lib/ routines, and ds_base LAST: QDOS appends the dataspace there.
; Code lives in .asm files, everything else (equates, macros, data)
; in .inc files. Every routine and macro carries a register contract
; (In / Out / Trashes above its label, the lists complete: CLAUDE.md),
; checked by tools/regcheck.py before every assembly.

        include "equates.inc"
        include "macros.inc"

; ---------------------------------------------------------------- job header
start:
        bra.s   main
        dc.l    0
        dc.w    $4afb               ; "job name follows" flag
        dc.w    jobname_e-jobname
jobname:
        dc.b    'Glider'
jobname_e:
        even

; ----------------------------------------------------------------- take over
main:
        trap    #0                  ; QDOS: enter supervisor mode
        move.w  #$2700,sr           ; mask all interrupts -- QDOS is gone
        lea     sv_stack_top(pc),sp ; run on our own supervisor stack

        move.b  #0,mc_stat          ; mode 4, screen 0 displayed
        bsr     scr_clear           ; both screens black

; ----- projection tables into the dataspace (QDOS appends it to the
; code, see ds_base): rowoff[zi] = (horizon + cam_h*yfocal/zi)*128 + 1
; = the red byte of column 0 on the row where ground depth zi lands;
; invtab[zi] = xfocal*4096/zi, so sx = 256 + (xi*invtab[zi]) >> 12.
; Exact per integer depth, so no banding (a zc>>4 table would band the
; near rows), and both divides leave the per-dot path.
        lea     ds_base(pc),a0
        lea     invtab(a0),a1
        move.w  #znear,d2
.tab:   move.w  d2,d1
        add.w   d1,d1               ; word index
        move.l  #cam_h*yfocal,d0
        divu.w  d2,d0
        add.w   #horizon,d0
        lsl.w   #7,d0
        addq.w  #1,d0
        move.w  d0,(a0,d1.w)
        move.l  #xfocal<<12,d0
        divu.w  d2,d0
        move.w  d0,(a1,d1.w)
        addq.w  #1,d2
        cmp.w   #ztab,d2
        blt.s   .tab

        lea     scr0,a4             ; the sweep's pixel lists, once: they
        bsr     radar_frame         ; leave out the radar frame's pixels,
        bsr     radar_tabs          ; tested on screen 0

; ----- the game flow (Beta 1, spec 11.1): the title until Space, a new
; game, each sector's card, each craft's start, then the frame loop
; until an event (after the flip, below): the craft lost -> the next
; one, or game over -> the title; Esc -> pause. The resets are in
; flow.asm, the screens in screens.asm.
go_title:
        bsr     title_screen
        bsr     game_new
go_sector:
        bsr     sector_load
        bsr     sector_card
go_craft:
        bsr     craft_start         ; screens, lists, the craft at the spawn
        moveq   #1,d7               ; back buffer index: screen 1

; ---------------------------------------------------------------- frame loop
; Loop-wide registers, live across every stage and every call:
;   d7 = back buffer index (0 = screen 0, 1 = screen 1)
;   a4 = back buffer base (set from d7 at the top of each loop)
; No routine called from the loop may trash them (regcheck enforces it);
; a stage that needs one parks it (the lattice pushes d7). The stages
; (erase, lattice, objects) are once-per-frame routines; the other
; registers carry values only locally: within a stage, plus d5 = held
; keys from the input into the flight steps and d6 = extra beats across
; the keyboard read.
frame_loop:
        lea     scr0,a4             ; a4 = back buffer base
        tst.w   d7
        beq.s   .bb0
        lea     scr1,a4
.bb0:   lea     xbeats(pc),a0
        clr.w   (a0)                ; frame edges consumed during the work

; ----- erase what this buffer held two frames ago: every erase runs
; before any draw, so overlapping boxes cost nothing
        bsr     erase_boxes         ; (polls the frame edge per box)
        bsr     erase_dots
        bsr     sight_erase         ; when its colour changes this frame
        bsr     dots_open           ; this frame's dot list, empty
        beat_poll

; ----- input: the row-1 bits read at the end of the previous loop (the
; IPC read sits between the work and the VBL wait, see there)
        lea     kbd_prev(pc),a2
        move.b  kbd_cur-kbd_prev(a2),d0
        move.b  (a2),d3             ; previous frame's bits (edge detect)
        move.b  d0,(a2)
        move.b  d0,d5               ; d5 = held keys through the sim
        ifne    test_keys
        or.b    #test_keys,d5       ; forced keys (unattended test runs)
        endc
        not.b   d3
        and.b   d0,d3               ; d3 = newly pressed
        btst    #k1__esc,d3
        beq.s   .nesc
        lea     event(pc),a0        ; Esc: pause, after the flip
        move.w  #ev_pause,(a0)
.nesc:
        ifne    dev
        btst    #k1__enter,d3
        beq.s   .nrst
        bsr     craft_reset         ; Enter (dev builds): back to the
        bsr     shield_reset        ; spawn point, the shield full
.nrst:
        endc

; ----- simulation: one step per beat of the previous loop (1..3), so
; everything stays defined per 20 ms whatever the frame rate (spec 2.1):
; the flight model, the craft's collisions, the shots, the enemy
; gliders and their shots; then what a changed shield means
        move.w  headroom+16(pc),d6
        subq.w  #1,d6
.beat:  lea     craft(pc),a0
        lea     sintab(pc),a1
        bsr     flight_step
        bsr     craft_hit           ; walls, mines, the shield (spec 7)
        bsr     shots_step          ; fire, move, hit (spec 7)
        ifeq    no_gls
        bsr     gliders_step        ; AI, flight, bumps (spec 6)
        bsr     eshots_step         ; their shots (spec 7)
        endc
        beat_poll
        dbf     d6,.beat
        bsr     shield_check        ; the bar, or the next craft at zero
        ifeq    no_gls
        bsr     gen_step            ; the generators turn and launch
        endc

        ifeq    no_lat
        bsr     lattice             ; ground dots (spec 5.3)
        endc
        beat_poll

; ----- horizon (hz_line): full-width red line with a 16-px gap at the
; centre, every frame (nothing moves it, but erase boxes cut it). Red
; like the lattice since M2: a white line through the red mine sitting
; on it (hover height) read badly; off by default since the same day.
        ifne    hz_line
        lea     horizon*scr_llen(a4),a0
        move.l  #$00ff00ff,d0       ; red plane = the odd bytes
        moveq   #32-1,d1
.hz:    move.l  d0,(a0)+
        dbf     d1,.hz
        clr.l   horizon*scr_llen+62(a4)         ; gap: x 248..263
        endc

; ----- objects: cull, transform, clip, draw, erase boxes (spec 5.2)
        ifeq    no_obj
        bsr     objects
        bsr     shots_draw          ; needs the object stage's ocam
        beat_poll
        endc

; ----- sight: the four-corner bracket around the aim point (256,
; horizon), over the objects (spec 5.4). With yaw only, everything dead
; ahead projects to x = 256 at any range and height: the stalks are the
; line of fire.
        bsr     sight_draw

; ----- explosions: dot sparks, after the sight so that erasing them
; never eats it (spec 5.6; they need the object stage's ocam)
        ifeq    no_obj
        bsr     boom_draw
        beat_poll
        endc

; ----- top strip: the radar's sweep (its frame is static; the blips
; come from the object stage)
        ifeq    no_rad
        bsr     radar
        endc

; ----- HUD readouts, headroom bar, meters, then VBL sync + flip. The
; frame edges consumed during the work (beat_poll at the stage
; boundaries -- every stretch between two polls must stay under a beat,
; or an edge is lost and the game runs slow -- plus one last poll here)
; are the loop's extra beats;
; then wait for the next real edge (flips stay VBL-aligned) and consume
; that too so the next loop's count is honest.
        ifne    dev                 ; the HUD band: dev builds only
        ifeq    no_hud
        bsr     draw_hud
        endc
        bsr     draw_hbar
        bsr     draw_meters
        endc
        beat_poll
        move.w  xbeats(pc),d6       ; d6 = extra beats of this loop (0..2)
; ----- keyboard: one IPC round trip for row 1, after the work and its
; beat classification, before the wait. At the top of the loop it
; wrecked the meters on Q-emuLator (47% spurious 2-beat loops, min idle
; 1 spin, average work unchanged): the emulated 8049's reply is tied to
; the frame clock, so a read can stall to a tick and drag the frame
; across the beat. Here a stall only eats idle time. On real hardware
; the read costs its ~0.5 ms wherever it sits; input latency is the
; same either way (the next loop uses it). Read every loop since M3
; (2026-09-29): M1/M2 read on buffer-1 loops only, to keep the buffer-0
; spins a pure headroom readout, but at the 3-beat budget that samples
; fire and turn every 120 ms.
        ifeq    no_kbd
        moveq   #key_row1,d0
        bsr     kbd_row             ; d0.b = key bits, 1 = held
        lea     kbd_cur(pc),a2
        move.b  d0,(a2)
        endc
        ifeq    no_snd
        bsr     sfx_play            ; the frame's sound, if any (spec 8)
        endc
        move.w  d6,d1
        moveq   #0,d0
.wait:  addq.l  #1,d0               ; count idle spins = headroom
        btst    #pc__frame,pc_intr
        beq.s   .wait
        move.b  #1<<pc__frame,pc_intr   ; consume the terminal edge
        bsr     meter_acc           ; d0 = spins, d1 = extra beats

; ----- flip: display the buffer just drawn
        move.w  d7,d0
        ror.b   #1,d0               ; 0 -> $00, 1 -> $80
        move.b  d0,mc_stat
        eori.w  #1,d7               ; other buffer becomes the back one

; ----- events, raised during the frame and acted on here, with the
; frame shown: Esc pauses (PAUSED over the view until Esc again), the
; craft lost goes to the next craft, or after the last to game over and
; the title (spec 11.1).
        move.w  event(pc),d0
        bne.s   .ev
        bra     frame_loop
.ev:    lea     event(pc),a0
        clr.w   (a0)
        cmp.w   #ev_pause,d0
        bne.s   .lost
        bsr     pause
        bra     frame_loop
.lost:  lea     craft_n(pc),a0      ; the craft lost
        subq.w  #1,(a0)
        bgt     go_craft            ; the next one
        bsr     over_screen
        bra     go_title

        include "flight.asm"
        include "combat.asm"
        include "enemy.asm"
        include "boom.asm"
        include "lattice.asm"
        include "objects.asm"
        include "render.asm"
        include "hud.asm"
        include "strip.asm"
        include "flow.asm"
        include "screens.asm"
        include "vars.inc"
        include "level.inc"
        include "types.inc"
        include "sounds.inc"
        include "texts.inc"

        include "meshes.inc"
        include "sparks.inc"
        include "sin.inc"

; The supervisor stack: the deepest path in M2 was ~30 bytes (the
; object stage into draw_line and its pushes, or the keyboard read into
; the IPC routines); 256 leaves room for M3's call levels. Nothing
; checks the depth at run time -- an overflow runs into the sine table.
        even
sv_stack:
        ds.b    256                 ; private supervisor stack
sv_stack_top:

        include "../lib/ipc_sound_takeover.asm"
        include "../lib/ipc_keys_takeover.asm"
        include "../lib/draw_line_w.asm"
        include "../lib/draw_line.asm"
        include "../lib/draw_dec.asm"
        include "../lib/draw_text.asm"
        include "../lib/vfont.inc"

; ---------------------------------------------------------------- dataspace
; QDOS places the job's dataspace right after the code, so ds_base (the
; end of this file) addresses it: the projection tables live there,
; built at startup, and the file stays small. DATASPACE in the Makefile
; (passed in as ds_avail) must cover ds_size.
rowoff      equ     0               ; word[ztab]: row*128+1 per depth
invtab      equ     ztab*2          ; word[ztab]: xfocal*4096/depth
radtab      equ     ztab*4          ; rad_nang sweep lists (radar_tabs)
ds_size     equ     radtab+rad_nang*rad_stride
        if      ds_size>ds_avail
        fail    "DATASPACE in the Makefile is smaller than ds_size"
        endc
        even
ds_base:
