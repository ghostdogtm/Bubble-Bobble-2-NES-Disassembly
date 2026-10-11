; Co-op (2-player simultaneous) constants. Constants only: no code, no data.
; Included from main.asm after defines.inc, US build only.

OSLOT_P2        = 39            ; object slot reserved for player 2 (see docs/coop_notes.md)
BUBBLE_SLOTS    = 20            ; bubble slots OSLOT_BUBBLE..39 in the original game (19 while P2 owns slot 39)
COOP_P2_ACTIVE  = $80           ; coopP2Active value while P2 is in the round (bit 7: BIT/BPL gates)

; Canary written to coopCanary at reset; proves PRG-RAM ($6000-$7FFF) is mapped and writable
COOP_CANARY0    = $43           ; 'C'
COOP_CANARY1    = $4F           ; 'O'
COOP_CANARY2    = $4F           ; 'O'
COOP_CANARY3    = $50           ; 'P'

; ---------------------------------------------------------------------------------------------
; Player context swap list: the SINGLE source of truth (see docs/coop_notes.md, Phase 2).
; Adding a per-player variable = add one line to COOP_CTX_SCALARS. coop_ram.asm generates the
; shadow byte ctxOther_<name> and coop_engine.asm generates the exchange code from it.
; Macros only: nothing is emitted here.
; ---------------------------------------------------------------------------------------------
; Per-player scalars (zero-page or absolute, the assembler picks the addressing mode)
; (9.2) An entry with a second argument (", eq") is exchanged only when the two values differ (CoopSwap compares
; first): for bytes that are equal in most swaps (measured with tmp/coop_scripts/p92/swapstat.py: compare 10-11 cycles
; when equal, 20-22 when not, against 14-16 for the plain exchange). The result is the same either way.
; (shootCounter, $0546, is NOT here since Phase 6b: it is rewardsEaten+7, the shared "bubbles blown" statistic that
; spawns the candy item, like the other rewardsEaten entries; see docs/coop_notes.md, Phase 6b)
.macro COOP_CTX_SCALARS M
	M ram_0062
	M playerHeld
	M playerPressed, eq
	M playerState, eq
	M ram_0076
	M playerDir
	M ram_0078
	M hBlocked
	M ram_007A, eq
	M ram_007B, eq
	M playerDmgType, eq
	M ram_007D, eq
	M playerHazardTrigger, eq
	M playerHazardSlot, eq
	M playerInvFrames, eq
	M playerHearts, eq
	M playerLives
	M ram_047A, eq
	M ram_047B
	M inflateTime, eq
	M extraBubbles, eq
	M ram_047E
	M shootSlot
	M shootDir
	M shootTrigger, eq
	M shootQueuedBubbles, eq
	M shooting
	M shootInitialSlot
	M bubbleVariant, eq
	M ram_077B, eq
.endmacro

; Per-object arrays: slot 0 (P1) is exchanged with slot OSLOT_P2 (P2). No shadow storage needed. (", eq": as above)
; (9.2) COOP_CTX_ARRAYS_DRAW: arrays that no code running inside a P2 window reads or writes for slot 0 / OSLOT_P2:
; objImgOfs / objImgOfsHI / objChrBank are written only by the animation engine (bank F AnimateObjects /
; AnimateNonBubbles / AnimateObjectsFromX) and the title setup, objChrSlot / objAttr by the cutscene ops, the round setup
; (CODE_0880C8), the announcement / bubble spawners (other slots) and the title setup; all of them are read only by
; DrawObjects (and the co-op draw code). So the window's two swaps leave them in place: CoopSwap exchanges them first, and
; CoopP2Window enters after them, at CoopSwap + COOP_SWAP_WIN_OFS. Every other CoopSwap call exchanges them as before.
; (Checked dynamically by tmp/coop_scripts/p92/windowchk.py: no access inside any window.)
.macro COOP_CTX_ARRAYS_DRAW M
	M objImgOfs
	M objChrBank
	M objImgOfsHI, eq
	M objChrSlot, eq
	M objAttr, eq
.endmacro

.macro COOP_CTX_ARRAYS M
	M objState, eq
	M objY
	M objX
	M objAnim
	M objAnimTimer
	M objAnimProgress
	M objAnimHI, eq
.endmacro

; Bits of powerUps that are per player (cleared on death); the other bits are shared.
COOP_POWERUP_MASK = POWERUP_CANDY | POWERUP_SHOE

; ---------------------------------------------------------------------------------------------
; Phase 7b-1: 8x8 HUD (see docs/coop_notes.md, Phase 7b-1). Rows 2-3, columns 2-29 of the round's nametable;
; one 14-column block per player (P1 columns 2-15, P2 columns 16-29). Glyphs live in tiles $66-$7D of the HUD
; CHR bank's font KB (src/chr/HudFont.chr); the tile is the glyph id ORed with $80 when the HUD uses the upper
; half of the pattern table (vNametable = 1).
; ---------------------------------------------------------------------------------------------
HUD_ROW_TILES   = 28            ; tiles per HUD row (columns 2-29)
HUD_BLOCK       = 14            ; tiles per player block
HUD_ROW_TOP     = $42           ; low byte of the PPU address of row 2, column 2 (lives, hearts)
HUD_ROW_BOTTOM  = $62           ; low byte of the PPU address of row 3, column 2 (score)
HUD_G_DIGIT0    = $66           ; digits 0-9 = $66-$6F
HUD_G_HEART     = $70
HUD_G_X         = $71           ; 'x' before the lives
HUD_G_P         = $72           ; 'P' of the "1P" / "2P" label
HUD_G_BLANK     = $7F           ; the original HUD blank (unchanged)
HUD_MAX_HEARTS  = 5
HUD_BONUS_DIGIT0 = $40          ; bonus-game screen (D-7b-11): the glyphs $66-$72 are at $40-$4C of chrBonusHud_B_ID
HUD_ICON_HIDE_Y = $F8           ; objY of the HUD icon (slot OSLOT_ICON) while DrawObjects runs: its sprites get
                                ; Y = $F0 (image offset -8), off screen, as the unused OAM entries
.assert chrBonusHud_A_ID = (chrFans_AA_ID | $80), error, "NMI CHR remap: chrBonusHud_A_ID must be chrFans_AA_ID | $80"

; ---------------------------------------------------------------------------------------------
; Phase 8: round 20 (the only wide round) with both players in the round (see docs/coop_notes.md, Phase 8).
; ---------------------------------------------------------------------------------------------
COOP_EDGE_L     = 16            ; screen edges of a player object (X = sprite centre) while both players are in round 20:
COOP_EDGE_R     = 240           ;   an X step past them is not taken, and the camera never pushes a player past them
COOP_CAM_STEP   = 2             ; wideHScroll step per tick (WideScrollLeft / WideScrollRight)
COOP_CAM_LZONE  = 80            ; CODE_0788CC: holding LEFT at X < 80 pushes the camera left,
COOP_CAM_RZONE  = 176           ;   holding RIGHT at X >= 176 pushes it right
COOP_RESPAWN_XMID = 128         ; in-place respawn X in round 20 while the camera is not at the round start

; ---------------------------------------------------------------------------------------------
; Phase 9.0: co-op code in PRG-RAM. PRG-RAM $6000-$6FFF = data (COOP_BSS), $7000-$7FFF = code (COOP_WRAM_CODE).
; The code image is linked at $A000 of bank $10 (MEM_X10, page-aligned) to run at $7000; CoopBoot (bank $10, $B000)
; copies all COOP_WRAM_CODE_PAGES pages once at power-on (from Begin, NMI off). Nothing else may write $7000-$7FFF
; (the perf harness flags any such write). Code there runs from any bank without bank switching.
; ---------------------------------------------------------------------------------------------
COOP_WRAM_CODE_RUN   = $7000    ; run address of COOP_WRAM_CODE (config_us WRAMCODE)
COOP_WRAM_CODE_IMG   = $A000    ; the image in bank $10 (COOP_WRAM_CODE is the first segment of MEM_X10)
COOP_WRAM_CODE_PAGES = 16       ; always the whole 4 KB area: a constant copy time (CoopBoot's delay is fixed)

COOP_IMG_BUF    = 25            ; Phase 9.1: image copy size (size byte + 6 sprites x 4); player images have <= 6 sprites
