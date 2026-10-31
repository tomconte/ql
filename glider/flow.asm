; flow.asm -- glider: the game flow's resets (Beta 1, spec 11.1): a new
; game, the next sector and the warp's trigger, a sector's entities, a
; craft's start, and the cleared screens play starts from. Everything
; the frame loop keeps between frames is set here, so a game can start
; again after the last one. Included by glider.asm.

; ------------------------------------------------------------------ game new
; game_new: a new game: score 0, ncraft craft, sector 1 (the first
; record, its own launch delay; test_sect's when set), no bonus to
; show, the shield full (so the first craft starts full whatever the
; sector's sd_gain).
; In:      none
; Out:     score, craft_n, sector_n, sect_i, dly_cut, bonus, shield
; Trashes: a0
game_new:
        lea     score(pc),a0
        clr.l   (a0)
        lea     shield(pc),a0
        move.w  #shield_max,(a0)
        lea     craft_n(pc),a0
        move.w  #ncraft,(a0)
        lea     sector_n(pc),a0     ; (packed BCD)
        move.w  #(((test_sect+1)/10)<<4)+(test_sect+1)-((test_sect+1)/10)*10,(a0)
        lea     sect_i(pc),a0
        move.w  #test_sect,(a0)
        lea     dly_cut(pc),a0
        clr.w   (a0)
        lea     bonus(pc),a0
        clr.l   (a0)
        rts

; -------------------------------------------------------------- sector next
; sector_next: the sector cleared (spec 6, 11.1): its bonus, 1000 times
; its number, scored and kept for the next card; the next sector -- past
; the last record, the loop's lap again (sect_loop on, levels.inc) with
; the launch delay cut by dly_step.
; In:      none
; Out:     score, hud_chg, bonus, sector_n, sect_i, dly_cut
; Trashes: d0, d1, a0
sector_next:
        moveq   #0,d0
        move.b  sector_n+1(pc),d0
        lsl.l   #8,d0
        lsl.l   #4,d0               ; n x 1000, packed BCD
        lea     bonus(pc),a0
        move.l  d0,(a0)
        bsr     score_add
        lea     sector_n+1(pc),a0   ; the number + 1 (BCD)
        move.b  (a0),d1
        moveq   #1,d0
        move.w  #0,ccr              ; X clear
        abcd    d0,d1
        move.b  d1,(a0)
        lea     sect_i(pc),a0
        cmp.w   #nsect-1,(a0)
        bhs.s   .last
        addq.w  #1,(a0)             ; the next record
        rts
.last:  move.w  #sect_loop,(a0)     ; the loop's lap again,
        lea     dly_cut(pc),a0      ;   with faster launches
        add.w   #dly_step,(a0)
        rts

; --------------------------------------------------------------- warp check
; warp_check: once a frame, after the generators: with all of them
; destroyed the warp is armed (warp_t = warp_b beats, while the last
; burst plays out and the craft is unhurt: shield_add), and when that
; has counted down by the loop's beats it is raised (ev_warp, warp_t
; -1). A sector without generators (a test table) never warps.
; In:      none
; Out:     warp_t, event
; Trashes: d0, a0, a1
warp_check:
        move.w  warp_t(pc),d0
        bne.s   .count
        lea     gens(pc),a0
        move.w  (a0)+,d0
        beq.s   .done
        subq.w  #1,d0
.g:     move.l  (a0)+,a1
        tst.w   e_flags(a1)
        bne.s   .done               ; one stands
        dbf     d0,.g
        lea     warp_t(pc),a0       ; all gone: armed
        move.w  #warp_b,(a0)
        rts
.count: bmi.s   .done               ; raised already
        sub.w   headroom+16(pc),d0  ; the beats simulated this loop
        bgt.s   .keep
        moveq   #-1,d0
        lea     event(pc),a0
        move.w  #ev_warp,(a0)
.keep:  lea     warp_t(pc),a0
        move.w  d0,(a0)
.done:  rts

; --------------------------------------------------------------- sector load
; sector_load: the sector's record in sec_dir (levels.inc): its table,
; its spawn point (or spawn_x/z/head when test_spawn), its launch delay
; less dly_cut (at least dly_min), its rules and caption (sd_own on,
; into sec_*);
; its static entities from the table into the pool (so everything
; destroyed in the last game is back), each crystal sec_ghp hits from
; destroyed (e_hp), the gliders' entities after them (free, each paired
; with its glider record), and the generators listed for gen_step
; (spec 6).
; In:      none
; Out:     lvl_ptr, spn_px, spn_pz, spn_h, gen_dly, sec_rules, entpool,
;          glpool's g_ent, gens
; Trashes: d0-d2, a0-a2
sector_load:
        lea     sec_dir(pc),a0
        move.w  sect_i(pc),d0
        mulu.w  #sd_size,d0
        adda.w  d0,a0               ; the sector's record
        lea     levels(pc),a1
        adda.w  sd_tab(a0),a1       ; its table
        lea     lvl_ptr(pc),a2
        move.l  a1,(a2)
        lea     spn_px(pc),a2       ; the spawn (spn_px, spn_pz, spn_h)
        ifne    test_spawn
        move.l  #(spawn_x&(sector-1))<<8,(a2)+
        move.l  #(spawn_z&(sector-1))<<8,(a2)+
        move.w  #spawn_head,(a2)
        else
        moveq   #0,d0
        move.w  sd_x(a0),d0
        and.w   #sector-1,d0
        lsl.l   #8,d0
        move.l  d0,(a2)+
        moveq   #0,d0
        move.w  sd_z(a0),d0
        and.w   #sector-1,d0
        lsl.l   #8,d0
        move.l  d0,(a2)+
        move.w  sd_head(a0),(a2)
        endc
        move.w  sd_dly(a0),d0       ; the launch delay
        sub.w   dly_cut(pc),d0
        cmp.w   #dly_min,d0
        bge.s   .dly
        move.w  #dly_min,d0
.dly:   lea     gen_dly(pc),a2
        move.w  d0,(a2)
        lea     sd_own(a0),a0       ; the rules
        lea     sec_rules(pc),a2
        moveq   #(sd_size-sd_own)/2-1,d0
.rul:   move.w  (a0)+,(a2)+
        dbf     d0,.rul
        move.l  a1,a0               ; static entities into the pool
        lea     entpool(pc),a1
.lvl:   move.w  (a0),d0
        move.l  (a0)+,(a1)+
        move.l  (a0)+,(a1)+
        move.l  (a0)+,(a1)+
        move.l  (a0)+,(a1)+
        tst.w   d0
        bpl.s   .lvl                ; copies the -1 terminator too
        lea     -e_size(a1),a1      ; then the gliders' entities over it,
        lea     glpool(pc),a0       ; free (e_flags 0), each paired with
        moveq   #ngl-1,d0           ; its glider record
.gle:   move.l  a1,g_ent(a0)
        move.w  #msh_dart,e_mesh(a1)
        clr.w   e_flags(a1)
        lea     e_size(a1),a1
        lea     g_size(a0),a0
        dbf     d0,.gle
        move.w  #-1,e_mesh(a1)      ; the pool's end
        lea     objdir+msh_gen*32(pc),a0    ; (32-byte entries)
        move.w  od_hp(a0),d2
        sub.w   sec_ghp(pc),d2      ; a crystal's hits taken to start with
        lea     entpool(pc),a0      ; the generators, listed for gen_step
        lea     gens+2(pc),a1
        moveq   #0,d1
.gsc:   move.w  e_mesh(a0),d0
        bmi.s   .gsd
        cmp.w   #msh_gen,d0
        bne.s   .gsn
        move.w  d2,e_hp(a0)         ; sec_ghp to go
        cmp.w   #ngen,d1
        bhs.s   .gsn                ; (more than ngen: the rest stay idle)
        move.l  a0,(a1)+
        addq.w  #1,d1
.gsn:   lea     e_size(a0),a0
        bra.s   .gsc
.gsd:   lea     gens(pc),a0
        move.w  d1,(a0)
        ifne    test_warp
        lea     entpool(pc),a0      ; unattended runs: the crystals gone
.tw:    move.w  e_mesh(a0),d0
        bmi.s   .twd
        cmp.w   #msh_gen,d0
        bne.s   .twn
        clr.w   e_flags(a0)
.twn:   lea     e_size(a0),a0
        bra.s   .tw
.twd:
        endc
        rts

; -------------------------------------------------------------- craft start
; craft_start: a craft's start (spec 6): the screens cleared (play_clear),
; the gliders, shots and explosions gone, the live generators' launch
; timers back to the level table's (so the craft is not met by the
; gliders that got the last one) and their fire timers to gen_fwait,
; the craft at the spawn, its shield what was left plus sec_gain, at
; most full (the warp into the sector refills that much: its record's
; sd_gain; a craft after one lost has none left and sec_gain is then
; shield_max) and its bar, the strip's readouts, no event or warp
; pending, the next simulation one beat. Destroyed entities stay
; destroyed. Screen 0 is shown: the loop starts with d7 = 1.
; In:      none
; Out:     the screens and lists (play_clear), glpool's gliders free,
;          gl_phase, gl_next, shots, eshots, nlive, nelive, fire_t,
;          booms, nbooms, the generators' e_tmr, gen_ft, craft, shield,
;          sec_gain, shield_chg, hurt_t, sight_col, event, warp_t,
;          sfx_want, headroom+16
; Trashes: d0-d5, a0-a3, a4, a5
craft_start:
        bsr     play_clear
        lea     glpool(pc),a0       ; the gliders gone
        moveq   #ngl-1,d0
.gl:    move.l  g_ent(a0),a1
        clr.w   e_flags(a1)
        lea     g_size(a0),a0
        dbf     d0,.gl
        lea     gl_phase(pc),a0
        move.w  #1,(a0)
        lea     gl_next(pc),a0
        clr.w   (a0)
        lea     shots(pc),a0        ; the shots, both sides' (adjacent)
        moveq   #nshots+neshots-1,d0
.sh:    clr.w   sh_life(a0)
        lea     sh_size(a0),a0
        dbf     d0,.sh
        lea     nlive(pc),a0
        clr.w   (a0)
        lea     nelive(pc),a0
        clr.w   (a0)
        lea     fire_t(pc),a0
        clr.w   (a0)
        lea     booms(pc),a0        ; the explosions
        moveq   #nboom-1,d0
.bm:    clr.w   bm_live(a0)
        lea     bm_size(a0),a0
        dbf     d0,.bm
        lea     nbooms(pc),a0
        clr.w   (a0)
        move.l  lvl_ptr(pc),a0      ; the live generators re-armed: pool
        lea     entpool(pc),a1      ; and level table run in step
.gen:   move.w  e_mesh(a0),d0
        bmi.s   .gend
        cmp.w   #msh_gen,d0
        bne.s   .gn
        tst.w   e_flags(a1)
        beq.s   .gn                 ; destroyed: stays so
        move.w  e_tmr(a0),e_tmr(a1)
.gn:    lea     e_size(a0),a0
        lea     e_size(a1),a1
        bra.s   .gen
.gend:  lea     gen_ft(pc),a0       ; and their guns (gens_fire)
        moveq   #ngen-1,d0
.ft:    move.w  #gen_fwait,(a0)+
        dbf     d0,.ft
        lea     event(pc),a0
        clr.w   (a0)
        lea     warp_t(pc),a0
        clr.w   (a0)
        lea     sfx_want(pc),a0
        clr.b   (a0)
        lea     shield_chg(pc),a0
        clr.w   (a0)
        lea     headroom+16(pc),a0  ; the first loop simulates one beat
        move.w  #1,(a0)
        bsr     craft_reset         ; at the spawn,
        move.w  shield(pc),d0       ; the shield: what is left (none
        bpl.s   .shl                ;   after a craft lost)
        moveq   #0,d0
.shl:   add.w   sec_gain(pc),d0     ; and the sector's gain,
        cmp.w   #shield_max,d0
        ble.s   .shm
        moveq   #shield_max,d0      ;   at most full
.shm:   lea     sec_gain(pc),a0     ; (the next craft here starts full)
        move.w  #shield_max,(a0)
        bsr     shield_set          ; its bar drawn,
        bsr     strip_draw          ; the score, crystals, spare craft
        ifne    test_gl
        bsr     gl_test             ; a dart, a wedge, a kite ahead
        endc
        rts

; --------------------------------------------------------------- play clear
; play_clear: both screens black with the strip's static parts in both
; (the radar's frame; the HUD band's separator in dev builds), the
; per-buffer lists empty (erase boxes, dots, the sight shown nowhere),
; near and close empty; screen 0 shown, a pending frame bit dropped.
; In:      none
; Out:     the screens, bbox0/1, dots0/1, sight_buf, sight_hit, near,
;          close
; Trashes: d0-d5, a0, a1, a4
play_clear:
        bsr     scr_clear
        lea     scr0,a4
        bsr     radar_frame
        lea     scr1,a4
        bsr     radar_frame
        ifne    dev
        lea     scr0+240*scr_llen,a0    ; the HUD band's separator
        lea     scr1+240*scr_llen,a1
        moveq   #-1,d1
        moveq   #32-1,d0
.sep:   move.l  d1,(a0)+
        move.l  d1,(a1)+
        dbf     d0,.sep
        endc
        lea     bbox0(pc),a0
        clr.w   (a0)
        lea     bbox1(pc),a0
        clr.w   (a0)
        lea     dots0(pc),a0
        clr.w   (a0)
        lea     dots1(pc),a0
        clr.w   (a0)
        lea     sight_buf(pc),a0
        clr.b   (a0)+
        clr.b   (a0)
        lea     sight_hit(pc),a0
        clr.b   (a0)+
        clr.b   (a0)
        lea     near(pc),a0
        clr.w   (a0)
        lea     close(pc),a0
        clr.w   (a0)
        move.b  #0,mc_stat          ; screen 0 shown
        move.b  #1<<pc__frame,pc_intr
        rts
