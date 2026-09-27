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
;   render.asm   list selectors, erase box, projection, clipping, wedges
;   hud.asm      readouts, meters, headroom bar
;   vars.inc     variables and scratch
;   level.inc    static entity table
;   then meshes.inc and sin.inc (generated), the supervisor stack, the
;   lib/ routines, and ds_base LAST: QDOS appends the dataspace there.
; Code lives in .asm files, everything else (equates, macros, data)
; in .inc files. Every routine and macro carries a register contract
; (In / Out / Trashes above its label, the lists complete: CLAUDE.md).

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

        lea     scr0,a0             ; clear BOTH screens ($20000-$2FFFF)
        move.w  #$10000/4-1,d0
        moveq   #0,d1
.clr:   move.l  d1,(a0)+
        dbf     d0,.clr

        lea     scr0+240*scr_llen,a0    ; static HUD separator, both buffers
        lea     scr1+240*scr_llen,a1
        moveq   #-1,d1
        moveq   #32-1,d0
.sep:   move.l  d1,(a0)+
        move.l  d1,(a1)+
        dbf     d0,.sep

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
        cmp.w   #zfar,d2
        blt.s   .tab

        lea     level(pc),a0        ; static entities into the pool
        lea     entpool(pc),a1
.lvl:   move.w  (a0),d0
        move.l  (a0)+,(a1)+
        move.l  (a0)+,(a1)+
        move.l  (a0)+,(a1)+
        move.l  (a0)+,(a1)+
        tst.w   d0
        bpl.s   .lvl                ; copies the -1 terminator too

        bsr     craft_reset         ; spawn in the open field
        move.b  #1<<pc__frame,pc_intr   ; discard any pending frame bit
        moveq   #1,d7               ; back buffer index: screen 1

; ---------------------------------------------------------------- frame loop
; Loop-wide registers, live across every stage and every call:
;   d7 = back buffer index (0 = screen 0, 1 = screen 1)
;   a4 = back buffer base (set from d7 at the top of each loop)
; No routine called from the loop may trash them (check its Trashes);
; a stage that needs one parks it (the lattice pushes d7). The other
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

; ----- erase the object boxes this buffer held two frames ago (parade
; format: miny, nrows, end-of-span offset, L longs per row). Per row
; eight zeroed registers go out in movem bursts of 32 bytes: the full
; bursts via a computed jump, the remainder through a mask patched per
; box (emtab); L reaches 32 for a screen-wide object.
        bsr     bbox_sel            ; a6 = this buffer's box list
        move.w  (a6)+,d0
        beq.s   .noeb
        lsl.w   #3,d0
        lea     (a6,d0.w),a0
        move.l  a0,-(sp)            ; end of the records
.ebox:  move.w  (a6)+,d1            ; miny
        move.w  (a6)+,d2            ; nrows
        move.w  (a6)+,d3            ; end-of-span offset
        move.w  (a6)+,d4            ; L
        lsl.w   #7,d1
        add.w   d3,d1
        lea     (a4,d1.w),a0        ; end of the first row's span
        move.w  d4,d5
        lsr.w   #3,d5               ; full bursts
        neg.w   d5
        addq.w  #4,d5
        lsl.w   #2,d5               ; jump offset: skip 4 - full bursts
        move.w  d4,d0
        and.w   #7,d0
        add.w   d0,d0
        lea     emtab(pc),a1
        move.w  (a1,d0.w),d0        ; remainder mask
        lea     .erm+2(pc),a1
        move.w  d0,(a1)
        lsl.w   #2,d4
        add.w   #scr_llen,d4        ; row stride = 128 + 4L
        moveq   #0,d0               ; eight zeros for the bursts
        moveq   #0,d1
        moveq   #0,d3
        moveq   #0,d6
        suba.l  a1,a1
        suba.l  a2,a2
        suba.l  a3,a3
        suba.l  a5,a5
.erow:  jmp     .ej(pc,d5.w)
.ej:    movem.l d0-d1/d3/d6/a1-a3/a5,-(a0)
        movem.l d0-d1/d3/d6/a1-a3/a5,-(a0)
        movem.l d0-d1/d3/d6/a1-a3/a5,-(a0)
        movem.l d0-d1/d3/d6/a1-a3/a5,-(a0)
.erm:   movem.l d0-d1/d3/d6/a1-a3/a5,-(a0)   ; mask patched above
        adda.w  d4,a0
        subq.w  #1,d2
        bne.s   .erow
        cmpa.l  (sp),a6
        blo.s   .ebox
        addq.l  #4,sp
.noeb:

; ----- erase the dots this buffer held two frames ago (red byte AND)
        bsr     dots_sel            ; a1 = this buffer's dot list
        move.w  (a1)+,d0            ; count
        beq.s   .noer
        subq.w  #1,d0
.er:    move.w  (a1)+,d1            ; offset of the red byte
        move.w  (a1)+,d2            ; inverse mask (low byte)
        and.b   d2,(a4,d1.w)
        dbf     d0,.er
.noer:

; ----- input: the row-1 bits read at the end of the previous loop (the
; IPC read sits between the work and the VBL wait, see there)
        lea     kbd_prev(pc),a2
        move.b  kbd_cur-kbd_prev(a2),d0
        move.b  (a2),d3             ; previous frame's bits (edge detect)
        move.b  d0,(a2)
        move.b  d0,d5               ; d5 = held keys through the sim
        not.b   d3
        and.b   d0,d3               ; d3 = newly pressed
        btst    #k1__enter,d3
        beq.s   .nrst
        bsr     craft_reset         ; Enter: back to the spawn point
.nrst:

; ----- flight: one beat step per beat of the previous loop (1|2), so
; thrust/drag/turn stay defined per 20 ms whatever the frame rate
        move.w  headroom+16(pc),d6
        subq.w  #1,d6
        lea     craft(pc),a0
        lea     sintab(pc),a1
.beat:  bsr     flight_step
        dbf     d6,.beat

        ifeq    no_lat
; ----- lattice: camera-space corner of the cell window and the two
; world step vectors, all 16.16 so the walk below is exact. The window
; is (2*nwin+1)^2 cells around the camera cell; the corner is at
; (-nwin*latd - rx, -nwin*latd - rz) relative to the camera, rx/rz the
; camera's offset within its cell. Camera transform (spec 5.1):
;   xc = dx*c - dz*s,  zc = dz*c + dx*s      (8.8 trig, 256 = 1.0)
        lea     craft(pc),a0
        move.w  c_s(a0),d2          ; s
        move.w  c_c(a0),d3          ; c
        move.l  c_px(a0),d0
        asr.l   #8,d0               ; integer x
        and.w   #latd-1,d0          ; rx
        neg.w   d0
        sub.w   #nwin*latd,d0       ; dx0
        move.l  c_pz(a0),d1
        asr.l   #8,d1
        and.w   #latd-1,d1
        neg.w   d1
        sub.w   #nwin*latd,d1       ; dz0
        move.w  d0,d4
        muls.w  d3,d4               ; dx0*c
        move.w  d1,d5
        muls.w  d2,d5               ; dz0*s
        sub.l   d5,d4
        asl.l   #8,d4               ; xc0, 16.16
        move.l  d4,a2               ; a2 = row start xc
        move.w  d1,d4
        muls.w  d3,d4               ; dz0*c
        move.w  d0,d5
        muls.w  d2,d5               ; dx0*s
        add.l   d5,d4
        asl.l   #8,d4               ; zc0, 16.16
        move.l  d4,a3               ; a3 = row start zc
        move.w  d2,d4
        muls.w  #latd,d4
        asl.l   #8,d4               ; latd*s, 16.16
        move.w  d3,d5
        muls.w  #latd,d5
        asl.l   #8,d5               ; latd*c, 16.16
        lea     lat_uz(pc),a0       ; uz (one world z step) = (-latd*s, latd*c)
        move.l  d4,d0
        neg.l   d0
        move.l  d0,(a0)+
        move.l  d5,(a0)
        move.l  d5,d2               ; ux (one world x step) = (latd*c, latd*s)
        move.l  d4,d3
        bsr     dots_sel            ; a1 = dot list (count word first)
        lea     2+maxdots*4(a1),a0
        lea     lst_max(pc),a6
        move.l  a0,(a6)             ; row-granular overflow check below
        addq.l  #2,a1               ; a1 = first record
        lea     ds_base(pc),a5      ; a5 = rowoff table
        lea     invtab(a5),a6       ; a6 = reciprocal table
; wedge prep: each of the four half-plane tests f = a*x + b*z + c >= 0
; is linear along a row, f(t) = F + t*DF with DF = a*Ux + b*Uz. Since
; Ux = latd*(c, s) and Uz = latd*(-s, c), every DF is latd times a trig
; sum w, which wdg_put expands into the record wbound reads:
;   0 behind   (z - ZN):       w = s
;   1 beyond   (ZF-1 - z):     w = -s
;   2 right    (z - x - 1.0):  w = s - c
;   3 left     (z + x - 1.0):  w = s + c
        lea     wdg(pc),a0
        move.w  craft+c_s(pc),d0
        bsr     wdg_put
        move.w  craft+c_s(pc),d0
        neg.w   d0
        bsr     wdg_put
        move.w  craft+c_s(pc),d0
        sub.w   craft+c_c(pc),d0
        bsr     wdg_put
        move.w  craft+c_s(pc),d0
        add.w   craft+c_c(pc),d0
        bsr     wdg_put
; rows: d7 = rows left (the buffer index is parked on the stack), a2/a3
; = row start (x, z), d2/d3 = Ux. Per row the four tests narrow the
; cell range [d4,d5]; only that range is walked, with the exact
; per-cell tests. Rows behind the camera fall out at the first test.
        move.l  d7,-(sp)
        move.w  #2*nwin+1,d7
.lrow:  moveq   #0,d4               ; lo
        moveq   #2*nwin,d5          ; hi
        lea     wdg(pc),a0
        move.l  a3,d0
        sub.l   #znear<<16,d0       ; f = z - ZN
        wbound  .rnext
        move.l  #(zfar<<16)-1,d0
        sub.l   a3,d0               ; f = ZF-1 - z
        wbound  .rnext
        move.l  a3,d0
        sub.l   a2,d0
        sub.l   #1<<16,d0           ; f = z - x - 1.0
        wbound  .rnext
        move.l  a3,d0
        add.l   a2,d0
        sub.l   #1<<16,d0           ; f = z + x - 1.0
        wbound  .rnext
        cmp.w   d4,d5
        blt.s   .rnext              ; empty range
        move.l  a2,d0               ; walk start = row start + lo*Ux
        move.l  a3,d1
        move.w  d4,d6
        beq.s   .wk
        subq.w  #1,d6
.skp:   add.l   d2,d0
        add.l   d3,d1
        dbf     d6,.skp
.wk:    sub.w   d4,d5
        move.w  d5,d6               ; cells to walk - 1
; cell: exact tests (behind, beyond zfar, outside the 90-degree FOV with
; the 1-unit margin that keeps the floored xi below zi), then the
; table-driven plot of one red pixel (odd byte of the screen word),
; recorded for the erase.
.lcol:  cmp.l   #znear<<16,d1
        blt.s   .lnext
        cmp.l   #zfar<<16,d1
        bge.s   .lnext
        move.l  d0,d4
        bpl.s   .lpos
        neg.l   d4
.lpos:  add.l   #1<<16,d4
        cmp.l   d1,d4
        bgt.s   .lnext
        move.l  d1,d5
        swap    d5                  ; zi (znear..zfar-1)
        add.w   d5,d5               ; word index
        move.w  (a5,d5.w),a0        ; a0 = row*128 + 1
        move.l  d0,d4
        swap    d4                  ; xi (signed, floor)
        muls.w  (a6,d5.w),d4        ; xi * xfocal*4096/zi
        asr.l   #8,d4
        asr.w   #4,d4               ; sx - 256: -256..255 at xfocal 256
        add.w   #256,d4             ; sx
        cmp.w   #511,d4
        bhi.s   .lnext              ; off-screen (narrower FOV than 90)
        move.w  d4,d5
        lsr.w   #3,d5
        add.w   d5,d5               ; (sx>>3)*2: screen word
        add.w   d5,a0               ; a0 = offset of the red byte
        and.w   #7,d4
        move.w  #$80,d5
        lsr.w   d4,d5               ; pixel mask
        or.b    d5,(a4,a0.w)
        move.w  a0,(a1)+            ; record: offset,
        not.b   d5
        move.w  d5,(a1)+            ;   inverse mask
.lnext: add.l   d2,d0               ; next cell: one world x step
        add.l   d3,d1
        dbf     d6,.lcol
.rnext: adda.l  lat_uz(pc),a2       ; next row: one world z step
        adda.l  lat_uz+4(pc),a3
        cmpa.l  lst_max(pc),a1
        bhs.s   .ldone              ; list full: stop (a row of slack)
        subq.w  #1,d7
        bne     .lrow
.ldone: move.l  (sp)+,d7
        move.l  a1,d0               ; store the count for the erase
        bsr     dots_sel
        sub.l   a1,d0
        subq.l  #2,d0
        lsr.l   #2,d0
        move.w  d0,(a1)
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

; ----- objects: every active entity through the four-level cull (world
; box, bounding sphere against the frustum, faces by their planes with
; the eye in the mesh's frame, edges by outcodes), then its vertices
; into camera space and on screen, and its edges drawn: straight to
; draw_line when every vertex is on screen, else through clip_edge.
; Across the stage a4 = back buffer, a5 = entity, d7 = buffer index;
; draw_line trashes a0/a1, so a1 (cur) is reloaded after every line.
        ifeq    no_obj
        lea     craft(pc),a0
        lea     ocam(pc),a1
        move.l  c_px(a0),d0
        asr.l   #8,d0
        move.l  d0,oc_px(a1)        ; camera position, integer units
        move.l  c_pz(a0),d0
        asr.l   #8,d0
        move.l  d0,oc_pz(a1)
        move.w  c_s(a0),oc_s(a1)
        move.w  c_c(a0),oc_c(a1)
        clr.w   oc_n(a1)
        bsr     bbox_sel
        clr.w   (a6)                ; this buffer's box list starts empty
        lea     entpool(pc),a5
.ent:   tst.w   e_mesh(a5)
        bmi     .edone              ; end of the pool
        tst.w   e_flags(a5)
        beq     .enext              ; inactive
; --- world box: |dx|, |dz| < r_active, as longs (the lattice is unbounded)
        move.w  e_x(a5),d0
        ext.l   d0
        sub.l   ocam+oc_px(pc),d0   ; dx
        move.l  d0,d1
        bpl.s   .bx
        neg.l   d1
.bx:    cmp.l   #r_active,d1
        bge     .enext
        move.w  e_z(a5),d2
        ext.l   d2
        sub.l   ocam+oc_pz(pc),d2   ; dz
        move.l  d2,d1
        bpl.s   .bz
        neg.l   d1
.bz:    cmp.l   #r_active,d1
        bge     .enext
; --- centre into camera space (spec 5.1):
;   xc = (dx*c - dz*s) >> 8,  zc = (dz*c + dx*s) >> 8,  yc = cam_h - e_y
        move.w  ocam+oc_s(pc),d3
        move.w  ocam+oc_c(pc),d4
        move.w  d0,d1
        muls.w  d4,d1               ; dx*c
        move.w  d2,d5
        muls.w  d3,d5               ; dz*s
        sub.l   d5,d1
        asr.l   #8,d1               ; xc
        muls.w  d4,d2               ; dz*c
        muls.w  d3,d0               ; dx*s
        add.l   d0,d2
        asr.l   #8,d2               ; zc
        move.w  #cam_h,d3
        sub.w   e_y(a5),d3          ; yc (y down: the eye is above the ground)
; --- frustum on the bounding sphere. Conservative forms (never reject
; a sphere touching the view volume, checked in the M2 model): the side
; planes at 1.5r (> r*sqrt2 for 45-degree planes), the top and bottom
; planes at 2r against the 0.47/0.935 slopes of the shifted viewport.
        move.w  e_mesh(a5),d0
        lsl.w   #5,d0
        lea     objdir(pc),a0
        adda.w  d0,a0               ; a0 = directory entry
        move.w  od_rad(a0),d4       ; r
        move.w  d2,d0
        add.w   d4,d0
        cmp.w   #znear_o,d0
        blt     .enext              ; wholly behind the near plane
        move.w  d1,d0
        bpl.s   .fx
        neg.w   d0
.fx:    sub.w   d2,d0               ; |xc| - zc
        move.w  d4,d5
        asr.w   #1,d5
        add.w   d4,d5               ; 1.5 r
        cmp.w   d5,d0
        bgt     .enext              ; wholly outside the 90-degree FOV
        move.w  d4,d5
        add.w   d5,d5               ; 2r
        move.w  d3,d0
        sub.w   d2,d0               ; yc - zc
        cmp.w   d5,d0
        bgt     .enext              ; wholly below the play area
        move.w  d2,d0
        asr.w   #1,d0
        add.w   d3,d0
        add.w   d5,d0               ; yc + zc/2 + 2r
        bmi     .enext              ; wholly above it
        bsr     bbox_sel
        cmp.w   #maxobj,(a6)
        bge     .enext              ; no erase box left: not drawn
; --- cache the object: tables, counts, colour, centre, and the angle
; a = object heading - camera heading (the yaw the mesh is drawn at)
        lea     cur(pc),a1
        move.w  d1,cu_xc(a1)
        move.w  d2,cu_zc(a1)
        move.w  d3,cu_yc(a1)
        move.w  od_nv(a0),cu_nv(a1)
        move.w  od_nf(a0),cu_nf(a1)
        move.w  od_ne(a0),cu_ne(a1)
        move.w  od_col(a0),cu_col(a1)
        lea     meshes(pc),a2
        move.l  a2,d0
        moveq   #0,d5
        move.w  od_v(a0),d5
        add.l   d0,d5
        move.l  d5,cu_v(a1)
        moveq   #0,d5
        move.w  od_e(a0),d5
        add.l   d0,d5
        move.l  d5,cu_e(a1)
        moveq   #0,d5
        move.w  od_n(a0),d5
        add.l   d0,d5
        move.l  d5,cu_n(a1)
        move.w  e_head(a5),d0
        sub.w   craft+c_head(pc),d0
        lsr.w   #8,d0               ; integer brad
        add.w   d0,d0
        lea     sintab(pc),a2
        move.w  (a2,d0.w),d5        ; sa
        move.w  d5,cu_sa(a1)
        add.w   #128,d0             ; cos = sin(a + 64)
        and.w   #511,d0
        move.w  (a2,d0.w),d6        ; ca
        move.w  d6,cu_ca(a1)
        clr.w   cu_oc(a1)
        move.w  #511,cu_minx(a1)    ; empty box: minx > maxx
        clr.w   cu_maxx(a1)
        move.w  #playbot,cu_miny(a1)
        clr.w   cu_maxy(a1)
; --- the eye in the mesh's frame: the inverse of the vertex transform
; below applied to the camera origin,
;   ex = (zc*sa - xc*ca) >> 8,  ez = -((zc*ca + xc*sa) >> 8),  ey = -yc
        move.w  d2,d0
        muls.w  d5,d0               ; zc*sa
        move.w  d1,d4
        muls.w  d6,d4               ; xc*ca
        sub.l   d4,d0
        asr.l   #8,d0               ; ex
        move.w  d2,d4
        muls.w  d6,d4               ; zc*ca
        muls.w  d5,d1               ; xc*sa
        add.l   d1,d4
        asr.l   #8,d4
        neg.w   d4                  ; ez
        neg.w   d3                  ; ey
; --- faces: bit f of the visibility mask when the eye is on the outer
; side of face f's plane, n.e > d. Records are last-face-first, so the
; dbf counter is the bit number (as in the parade's cross test).
        move.l  cu_n(a1),a0
        move.w  cu_nf(a1),d6
        moveq   #0,d5
.face:  move.w  (a0)+,d1
        muls.w  d0,d1               ; nx*ex
        move.w  (a0)+,d2
        muls.w  d3,d2               ; ny*ey
        add.l   d2,d1
        move.w  (a0)+,d2
        muls.w  d4,d2               ; nz*ez
        add.l   d2,d1
        cmp.l   (a0)+,d1            ; against d
        ble.s   .hid
        bset    d6,d5
.hid:   dbf     d6,.face
        move.w  d5,cu_vis(a1)
; --- vertices into camera space (the parade's yaw formula plus the
; centre), projected with outcodes into vscr; a vertex at or behind
; the near plane gets outcode $10 and no projection
;   x' = (x*ca + z*sa) >> 8 + xc,  z' = (z*ca - x*sa) >> 8 + zc,  y' = y + yc
        move.l  cu_v(a1),a0
        lea     vscr(pc),a2
        move.w  cu_nv(a1),d6
        move.w  cu_sa(a1),d4
        move.w  cu_ca(a1),d5
.vtx:   move.w  (a0)+,d0            ; x
        move.w  (a0)+,d1            ; y
        move.w  (a0)+,d2            ; z
        move.w  d0,d3
        muls.w  d5,d3               ; x*ca
        muls.w  d4,d0               ; x*sa
        move.w  d2,a3               ; park z
        muls.w  d4,d2               ; z*sa
        add.l   d2,d3
        asr.l   #8,d3
        add.w   cu_xc(a1),d3        ; x'
        move.w  a3,d2
        muls.w  d5,d2               ; z*ca
        sub.l   d0,d2
        asr.l   #8,d2
        add.w   cu_zc(a1),d2        ; z'
        add.w   cu_yc(a1),d1        ; y'
        move.w  d3,(a2)+
        move.w  d1,(a2)+
        move.w  d2,(a2)+
        cmp.w   #znear_o+1,d2
        blt.s   .vnear
        move.w  d3,d0
        bsr     proj_oc             ; d0 = sx, d1 = sy, d3 = outcode
        move.w  d0,(a2)+
        move.w  d1,(a2)+
        move.w  d3,(a2)+
        or.w    d3,cu_oc(a1)
        dbf     d6,.vtx
        bra.s   .vdone
.vnear: addq.l  #4,a2               ; no projection
        move.w  #$10,(a2)+
        or.w    #$10,cu_oc(a1)
        dbf     d6,.vtx
.vdone:
; --- edges whose two faces are not both hidden. a6 parks the
; visibility mask (draw_line leaves a2, a3, a5, a6, d6, d7 alone).
        move.l  cu_e(a1),a2
        lea     vscr(pc),a3
        move.w  cu_vis(a1),a6
        move.w  cu_ne(a1),cu_cnt(a1)
        tst.w   cu_oc(a1)
        bne.s   .cedge              ; some vertex off screen: clip path
.edge:  move.w  a6,d0
        and.w   2(a2),d0            ; edge's two-face mask vs visibility
        beq.s   .eskip
        moveq   #0,d0
        move.b  (a2),d0             ; vertex offsets (pre-multiplied by 12)
        moveq   #0,d2
        move.b  1(a2),d2
        move.w  vs_sy(a3,d0.w),d1
        move.w  vs_sx(a3,d0.w),d0
        move.w  vs_sy(a3,d2.w),d3
        move.w  vs_sx(a3,d2.w),d2
        bsr     bb_ext
        move.w  cu_col(a1),d4
        bsr     draw_line
        lea     cur(pc),a1
.eskip: addq.l  #4,a2
        subq.w  #1,cu_cnt(a1)
        bge.s   .edge
        bra     .box
.cedge: move.w  a6,d0
        and.w   2(a2),d0
        beq     .cskip
        moveq   #0,d0
        move.b  (a2),d0
        moveq   #0,d2
        move.b  1(a2),d2
        move.w  vs_oc(a3,d0.w),d4
        move.w  vs_oc(a3,d2.w),d5
        move.w  d4,d1
        or.w    d5,d1
        beq.s   .cin                ; both on screen: straight draw
        and.w   d5,d4
        bne     .cskip              ; both past one edge, or both behind
        lea     cwrk(pc),a0         ; copy both records for clip_edge
        lea     (a3,d0.w),a1
        move.l  (a1)+,(a0)+
        move.l  (a1)+,(a0)+
        move.l  (a1)+,(a0)+
        lea     (a3,d2.w),a1
        move.l  (a1)+,(a0)+
        move.l  (a1)+,(a0)+
        move.l  (a1)+,(a0)+
        bsr     clip_edge           ; d0-d3 = segment, d4 = 0 if none
        lea     cur(pc),a1
        tst.w   d4
        beq.s   .cskip
        bra.s   .cdrw
.cin:   move.w  vs_sy(a3,d0.w),d1
        move.w  vs_sx(a3,d0.w),d0
        move.w  vs_sy(a3,d2.w),d3
        move.w  vs_sx(a3,d2.w),d2
.cdrw:  bsr     bb_ext
        move.w  cu_col(a1),d4
        bsr     draw_line
        lea     cur(pc),a1
.cskip: addq.l  #4,a2
        subq.w  #1,cu_cnt(a1)
        bge     .cedge
; --- the erase box for this buffer's next pass (parade format) when
; anything was drawn; count the object; poll the frame edge
.box:   move.w  cu_minx(a1),d0
        move.w  cu_maxx(a1),d1
        cmp.w   d1,d0
        bgt     .enext              ; nothing drawn
        move.w  cu_miny(a1),d2
        move.w  cu_maxy(a1),d3
        bsr     bbox_sel            ; a6 = box list
        move.w  (a6),d4
        addq.w  #1,(a6)
        lsl.w   #3,d4
        lea     2(a6,d4.w),a0       ; the new record
        move.w  d2,(a0)+            ; miny
        sub.w   d2,d3
        addq.w  #1,d3
        move.w  d3,(a0)+            ; nrows
        lsr.w   #5,d0               ; 32-px (8-byte) units
        lsr.w   #5,d1
        sub.w   d0,d1               ; units spanned - 1
        lsl.w   #3,d0               ; byte offset of the first unit
        add.w   d1,d1
        addq.w  #2,d1               ; L = 2 longs per unit, <= 32
        move.w  d1,d4
        lsl.w   #2,d4               ; 4L bytes per row
        add.w   d4,d0
        move.w  d0,(a0)+            ; end-of-span offset
        move.w  d1,(a0)             ; L
        lea     ocam(pc),a0
        addq.w  #1,oc_n(a0)
        beat_poll
.enext: lea     e_size(a5),a5
        bra     .ent
.edone:
        endc

; ----- reticle: green gunsight around the aim point (256, horizon).
; Every target at hover height projects onto the horizon row whatever
; its distance (yaw-only world), so the sight lives there; the gap in
; the line and the four ticks keep the two apart.
        or.b    #$3c,horizon*scr_llen+62(a4)    ; left tick, x 250..253
        or.b    #$1e,horizon*scr_llen+64(a4)    ; right tick, x 259..262
        moveq   #4-1,d1
        lea     (horizon-6)*scr_llen+64(a4),a0  ; upper tick, 4 rows
        lea     (horizon+3)*scr_llen+64(a4),a1  ; lower tick
.ret:   or.b    #$80,(a0)
        or.b    #$80,(a1)
        lea     scr_llen(a0),a0
        lea     scr_llen(a1),a1
        dbf     d1,.ret

; ----- HUD readouts, headroom bar, meters, then VBL sync + flip. The
; frame edges consumed during the work (beat_poll at the stage
; boundaries, plus one last poll here) are the loop's extra beats;
; then wait for the next real edge (flips stay VBL-aligned) and consume
; that too so the next loop's count is honest.
        ifeq    no_hud
        bsr     draw_hud
        endc
        bsr     draw_hbar
        bsr     draw_meters
        beat_poll
        move.w  xbeats(pc),d6       ; d6 = extra beats of this loop (0..2)
; ----- keyboard: one IPC round trip for row 1, after the work and its
; beat classification, before the wait. At the top of the loop it
; wrecked the meters on Q-emuLator (47% spurious 2-beat loops, min idle
; 1 spin, average work unchanged): the emulated 8049's reply is tied to
; the frame clock, so a read can stall to a tick and drag the frame
; across the beat. Here a stall only eats idle time. On real hardware
; the read costs its ~0.5 ms wherever it sits; input latency is the
; same either way (the next loop uses it). Read on buffer-1 loops
; only, so the buffer-0 spins stay a pure headroom readout and the
; buffer-1 spins show the read's cost.
        ifeq    no_kbd
        tst.w   d7
        beq.s   .nokb
        moveq   #key_row1,d0
        bsr     kbd_row             ; d0.b = key bits, 1 = held
        lea     kbd_cur(pc),a2
        move.b  d0,(a2)
.nokb:
        endc
        move.w  d6,d1
        moveq   #0,d0
.wait:  addq.l  #1,d0               ; count idle spins = headroom
        btst    #pc__frame,pc_intr
        beq.s   .wait
        move.b  #1<<pc__frame,pc_intr   ; consume the terminal edge
        lea     headroom(pc),a2
        move.l  d0,(a2)
        add.l   d0,4(a2)            ; window accumulators: spins,
        add.w   d1,8(a2)            ; 2-beat loops,
        tst.w   d7                  ; spins per back buffer (64 loops
        bne.s   .b1                 ; each in a window),
        add.l   d0,20(a2)
        bra.s   .b2
.b1:    add.l   d0,24(a2)
.b2:    cmp.w   28(a2),d0           ; min and max spins
        bhs.s   .nmin
        move.w  d0,28(a2)
.nmin:  cmp.w   30(a2),d0
        bls.s   .nmax
        move.w  d0,30(a2)
.nmax:  addq.w  #1,d1
        move.w  d1,16(a2)           ; beats for the next sim step
        subq.w  #1,10(a2)           ; loops left in the window
        bne     .flip
        move.w  #mwin,10(a2)
        move.l  4(a2),d0            ; latch: avg spins/loop,
        lsr.l   #mshift,d0
        move.w  d0,12(a2)
        move.w  8(a2),14(a2)        ; 2-beat count of the window,
        move.l  20(a2),d0           ; avg spins on buffer-0 loops,
        lsr.l   #mshift-1,d0
        move.w  d0,32(a2)
        move.l  24(a2),d0           ; on buffer-1 loops,
        lsr.l   #mshift-1,d0
        move.w  d0,34(a2)
        move.w  28(a2),36(a2)       ; min, max
        move.w  30(a2),38(a2)
        move.w  #2,18(a2)           ; draw the meters into both buffers
        clr.l   4(a2)
        clr.w   8(a2)
        clr.l   20(a2)
        clr.l   24(a2)
        move.w  #$7fff,28(a2)
        clr.w   30(a2)
.flip:
        move.w  d7,d0               ; flip: display the buffer just drawn
        ror.b   #1,d0               ; 0 -> $00, 1 -> $80
        move.b  d0,mc_stat
        eori.w  #1,d7               ; other buffer becomes the back one
        bra     frame_loop

        include "flight.asm"
        include "render.asm"
        include "hud.asm"
        include "vars.inc"
        include "level.inc"

        include "meshes.inc"
        include "sin.inc"

        even
sv_stack:
        ds.b    64                  ; private supervisor stack
sv_stack_top:

        include "../lib/ipc_sound_takeover.asm"
        include "../lib/ipc_keys_takeover.asm"
        include "../lib/draw_line_w.asm"
        include "../lib/draw_line.asm"
        include "../lib/draw_dec.asm"

; ---------------------------------------------------------------- dataspace
; QDOS places the job's dataspace right after the code, so ds_base (the
; end of this file) addresses it: the projection tables live there,
; built at startup, and the file stays small. DATASPACE in the Makefile
; (passed in as ds_avail) must cover ds_size.
rowoff      equ     0               ; word[zfar]: row*128+1 per depth
invtab      equ     zfar*2          ; word[zfar]: xfocal*4096/depth
ds_size     equ     zfar*4
        if      ds_size>ds_avail
        fail    "DATASPACE in the Makefile is smaller than ds_size"
        endc
        even
ds_base:
