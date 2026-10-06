; Co-op engine code, placed in bank E (fixed at $C000-$DFFF) in the space freed from the unused filler blobs.
; COOP_CODE follows PRG_BANK_E and must end by $D300 (where PRG_BANK_E_TRACKS starts), otherwise ld65 fails.

.import __COOP_BSS_RUN__, __COOP_BSS_SIZE__

.segment "COOP_CODE"

CoopReset:							;called once from Begin; NMI disabled; A/X/Y free
	LDA #$80						;MMC3 $A001: PRG-RAM enable, writes allowed
	STA $A001

	;Zero the whole COOP_BSS segment (works for sizes up to 8 KB)
	LDA #<__COOP_BSS_RUN__
	STA scratch0
	LDA #>__COOP_BSS_RUN__
	STA scratch1
	LDA #$00
	TAY
	LDX #>__COOP_BSS_SIZE__			;number of full pages
	BEQ @tail
@page:
	STA (scratch0),Y
	INY
	BNE @page
	INC scratch1
	DEX
	BNE @page
@tail:
	LDX #<__COOP_BSS_SIZE__			;remaining bytes (Y is 0 here)
	BEQ @done
@byte:
	STA (scratch0),Y
	INY
	DEX
	BNE @byte
@done:
	STA scratch0					;leave the scratch bytes as MemInit left them (A = 0)
	STA scratch1

	LDA #COOP_CANARY0
	STA coopCanary
	LDA #COOP_CANARY1
	STA coopCanary+1
	LDA #COOP_CANARY2
	STA coopCanary+2
	LDA #COOP_CANARY3
	STA coopCanary+3

	LDA #BUBBLE_SLOTS				;full bubble budget until P2 spawns (coopP2Active = 0 from the clear)
	STA bubbleSlotEnd
	LDA #BUBBLE_SLOTS-1
	STA bubbleSlotLast

.ifdef COOP_FORCE
	LDA #$01						;manual-test build: co-op always on
	STA coopMode
.endif
	RTS

; ---------------------------------------------------------------------------------------------
; CoopSwap: exchange the resident player with the one stored in ctxOther / object slot OSLOT_P2.
;   - every COOP_CTX_SCALARS entry <-> its shadow byte ctxOther_<name>
;   - every COOP_CTX_ARRAYS array: slot 0 <-> slot OSLOT_P2
;   - powerUps: only the bits in COOP_POWERUP_MASK are exchanged with ctxOther_powerUps
;   - coopResident ^= 1; currentPlayer = coopResident
; Clobbers A and X; preserves Y; flags undefined. Unrolled (the lists live in coop.inc).
; Nothing calls it in a normal build yet (Phase 2: only the COOP_SWAPTEST hook in RoundUpdate).
; ---------------------------------------------------------------------------------------------
.macro COOP_SWAP_SCALAR name
	LDA name
	LDX .ident(.concat("ctxOther_", .string(name)))
	STX name
	STA .ident(.concat("ctxOther_", .string(name)))
.endmacro

.macro COOP_SWAP_ARRAY name
	LDA name
	LDX name+OSLOT_P2
	STX name
	STA name+OSLOT_P2
.endmacro

CoopSwap:
	COOP_CTX_SCALARS COOP_SWAP_SCALAR
	COOP_CTX_ARRAYS COOP_SWAP_ARRAY

	;powerUps: x = (powerUps ^ shadow) & mask; both bytes ^= x  (bits outside the mask are untouched;
	;the shadow only ever holds mask bits, since it starts at 0 and only gets x bits flipped)
	LDA powerUps
	EOR ctxOther_powerUps
	AND #COOP_POWERUP_MASK
	TAX
	EOR powerUps
	STA powerUps
	TXA
	EOR ctxOther_powerUps
	STA ctxOther_powerUps

	LDA coopResident
	EOR #$01
	STA coopResident
	STA currentPlayer
	RTS

; =============================================================================================
; Phase 3: dual player update, P2 spawn, P2 blink (COOP_CODE2, bank E $D903+)
; =============================================================================================
.segment "COOP_CODE2"

COOP_P2_XMIN = $18					;clamp of P2's spawn X (object X is the sprite centre; the side walls
COOP_P2_XMAX = $E8					;cover X < 16 and X >= 240)

; ---------------------------------------------------------------------------------------------
; P2 windows. P1 stays resident for the whole tick; once per tick P2 is swapped in, P2's work runs,
; and P1 is swapped back. Called only while coopP2Active (the callers gate with BIT/BPL).
;   CoopP2WindowOdd   RoundUpdate, odd tick:  after HandleShooting(P1), before UpdateBubbles
;   CoopP2WindowEven  RoundUpdate, even tick: after the CODE_078916 banked sub, before AnimateNonBubbles
;   CoopP2WindowIntro CODE_0B8196 (round intro, enemies sliding in): after P1's player update
; Content: P2 player update (CODE_058E83, run exactly as RoundUpdate runs it); then, RoundUpdate windows only:
;   odd tick:  P2's shot (CoopP2Shoot, Phase 4/5) and P2's bubble touch (CoopP2BubbleTouch, Phase 5)
;   even tick: P2 vs enemies/food (PlayerCheckEnemyCollision, Phase 5)
; Before the swap, shot bytes exchanged by an enemy capture (CoopCaptureOther) are put back (CoopShotRestore).
; The window is transparent for the banks: $8000 = the caller's bank again (RunBankedSub restores
; bankedSubRetBank) and $A000 = the bank the caller had there (prgBankB is saved on entry and
; re-mapped on exit if P2's work changed it, race-free order). Clobbers A/X/Y.
; ---------------------------------------------------------------------------------------------
CoopP2WindowOdd:
CoopP2WindowEven:
	LDA #.BANK(RoundUpdate)			;return bank: RoundUpdate's bank must be at $8000 again
CoopP2Window:
	;A = bank that must be mapped at $8000 when control returns to the (banked) caller
	STA bankedSubRetBank			;CoopSwap does not touch it
	JSR CoopShotRestore				;shot bytes back with their owners before the swap (Phase 5)
	LDA prgBankB					;the caller's $A000 bank, restored below
	PHA
	JSR CoopSwap					;P2 resident: context, slot 0 <-> OSLOT_P2, currentPlayer = 1
	LDA #.LOBYTE(CODE_058E83)		;player update (reads pad 2 via currentPlayer)
	STA bankedSub
	LDA #.HIBYTE(CODE_058E83)
	STA bankedSub+1
	LDA #.BANK(CODE_058E83)
	STA bankedSubBank
	JSR RunBankedSub
	;The round intro runs the player update only (as for P1 there). Bank 9 is at $8000 again here.
	LDA bankedSubRetBank
	CMP #.BANK(RoundUpdate)
	BNE @swapback					;intro window
	LDA globalTimer
	LSR
	BCC @even
	JSR CoopP2Shoot					;odd: P2's shot (HandleShooting runs on odd ticks), emerging/caught bubble
	JSR CoopP2BubbleTouch			;odd: P2 touches bubbles (UpdateBubbles' player part)
	JMP @swapback
@even:
	JSR PlayerCheckEnemyCollision	;even: P2 vs enemies/food, exactly as RoundUpdate runs it for P1
@swapback:
	JSR CoopSwap					;P1 resident again (coopResident = 0, currentPlayer = 0)
	PLA
	CMP prgBankB					;$A000 always holds prgBankB (Rule 9), so equal = nothing to do
	BEQ @banksok
	LDX #$07						;race-free: selector, then prgBankB, then $8001
	STX $8000
	STA prgBankB
	STA $8001
@banksok:
	RTS

; ---------------------------------------------------------------------------------------------
; CoopP2Shoot (Phase 4/5): P2 resident, bank 9 mapped at $8000 (odd RoundUpdate tick, inside the window).
; HandleShooting consumes P2's shootTrigger (spawns P2's emerging bubble at P2's position, bubble
; index shootSlot). P2's shot bubble is then handled here, with P2's globals, as UpdateBubbles' ladder
; handles P1's (X = bubble index; while shooting, shootSlot = shootInitialSlot):
;   $80 emerging      -> BubbleEmergingUpdate (shootDir, candy, bubbleVariant, shootQueuedBubbles)
;   $88/$89 caught    -> CODE_0FFAB9 (enemy bubble / burst; clears P2's shooting, shootQueuedBubbles)
; UpdateBubbles skips P2's emerging slot while P1 is resident, and never sees P2's $88/$89 (they are
; converted here first: captures happen in the enemy AI on even ticks). terrainResult needs no pre-clear:
; BubbleEmergingCheckTerrain stores it first. The slot handled here is not touched by P2 this tick
; (coopP2SkipSlot), as UpdateBubbles' $80/$88 handlers skip the touch. Clobbers A/X/Y.
; ---------------------------------------------------------------------------------------------
CoopP2Shoot:
	LDA #$FF
	STA coopP2SkipSlot
	JSR HandleShooting
	LDA shooting
	BEQ @done
	LDX shootSlot
	LDA objState+OSLOT_BUBBLE,X
	CMP #BUBBLE_EMERGING
	BNE @caught
	STX coopP2SkipSlot
	JMP BubbleEmergingUpdate
@caught:
	LDX shootInitialSlot
	LDA objState+OSLOT_BUBBLE,X
	CMP #$88						;the capture states set by CODE_0FFAA3 ($88) / CODE_0FFB0C ($89)
	BCC @done
	CMP #$8A
	BCS @done
	STX coopP2SkipSlot
	JMP CODE_0FFAB9					;X = bubble index (it reads objState,X; writes via shootInitialSlot)
@done:
	RTS

; ---------------------------------------------------------------------------------------------
; CoopP2BubbleTouch (Phase 5): P2 resident, bank 9 at $8000, odd RoundUpdate tick, after CoopP2Shoot.
; The player part of UpdateBubbles for P2: clear P2's touch/hazard bytes as UpdateBubbles does at its
; start, then for every bubble whose state reaches CODE_098149 in UpdateBubbles' (US) ladder
; (RISING 1, EXPIRING 2, ENEMY 3, ENEMY_EXPIRING 4, POWER 5) set up what CODE_098149 sets up
; (scratch4/5 = bubble X/Y, X = bubble index) and run the player<->bubble part CODE_098932 (bounce with A
; held -> ram_007D bit 7, push -> bubbleDir + bit 6, else PopBubble with scratch1 = X). CODE_098258 (the
; bubble's own drift/movement) is not run: UpdateBubbles does that. Hazard effects of popped special
; bubbles reach P2 through HazardCheckPlayer (CoopHazardCheckP2). Clobbers A/X/Y, scratch1-7.
; ---------------------------------------------------------------------------------------------
CoopP2BubbleTouch:
	LDX #$00
	STX playerHazardTrigger
	STX ram_007D
	STX playerHazardSlot
@slot:
	LDA objState+OSLOT_BUBBLE,X
	BEQ @next
	CMP #BUBBLE_POWER+1
	BCS @next						;states >= 6 (and $80+) do not reach CODE_098149
	CPX coopP2SkipSlot
	BEQ @next
	LDA objX+OSLOT_BUBBLE,X
	STA scratch4
	LDA objY+OSLOT_BUBBLE,X
	STA scratch5
	JSR CODE_098932					;keeps X (PopBubble reloads it from scratch1)
@next:
	INX
	CPX bubbleSlotEnd
	BNE @slot
	RTS

; ---------------------------------------------------------------------------------------------
; Enemy capture by either player's emerging bubble (Phase 5). The enemy AI (even tick, P1 resident)
; tests "the" shot through CODE_0FF9E8 and then uses shooting / shootInitialSlot / shootQueuedBubbles /
; shootTrigger directly (CODE_0FFAA3, CODE_0FFB0C, bank B CODE_0B9630 and CODE_0B9AA9, bank 8 boss code).
; CODE_0FF9E8 tests the shot in the native bytes; its exit jumps here (co-op only): if that did not flag
; the enemy, the shot in ctxOther gets the same test, and on a hit the five shot bytes are exchanged
; with their ctxOther copies (coopShotSwapped ^= 1), so the follow-up code works on the catching
; player's shot. The exchange stays until CoopShotRestore (window start, P2 deactivation); nothing
; between the enemy AI and the even window reads these bytes. A later enemy in the same tick again
; tests the native shot first, then the other one (a hit exchanges back).
; ---------------------------------------------------------------------------------------------
.macro COOP_SHOT_XCHG name
	LDA name
	PHA
	LDA .ident(.concat("ctxOther_", .string(name)))
	STA name
	PLA
	STA .ident(.concat("ctxOther_", .string(name)))
.endmacro

CoopShotRestore:					;A only
	LDA coopShotSwapped
	BEQ CoopShotDone
CoopShotExchange:					;A only (X/Y kept)
	COOP_SHOT_XCHG shooting
	COOP_SHOT_XCHG shootInitialSlot
	COOP_SHOT_XCHG shootQueuedBubbles
	COOP_SHOT_XCHG shootTrigger
	COOP_SHOT_XCHG shootSlot
	LDA coopShotSwapped
	EOR #$01
	STA coopShotSwapped
CoopShotDone:
	RTS

; From CODE_0FFA55 (bank F, end of CODE_0FF9E8), co-op only. X = enemy index, ram_00CA = enemy state.
; Same test as CODE_0FF9E8 (US) on the ctxOther shot; no scratch bytes used. Keeps X and Y.
CoopCaptureOther:
	LDA ram_00CA
	BEQ @rts						;as CODE_0FF9E8: state 0 is never tested
	BMI @rts						;already flagged (the native shot hit, or bit 7 was set before)
	LDA ctxOther_shooting
	BEQ @rts
	TYA
	PHA
	LDY ctxOther_shootInitialSlot
	LDA objState+OSLOT_BUBBLE,Y
	CMP #BUBBLE_EMERGING
	BNE @done
	LDY ctxOther_shootQueuedBubbles	;box = DATA_0FFA56[queued] + enemy W/H, as CODE_0FF9E8
	LDA DATA_0FFA56,Y
	LDY enemyType,X
	CLC
	ADC DATA_0FFA59,Y
	STA collW
	LDY ctxOther_shootQueuedBubbles
	LDA DATA_0FFA56,Y
	LDY enemyType,X
	CLC
	ADC DATA_0FFA7E,Y
	STA collH
	LDY ctxOther_shootInitialSlot
	LDA objX+OSLOT_BUBBLE,Y			;|bubble X - enemy X| <= collW
	SEC
	SBC objX+OSLOT_ENEMY,X
	BCS :+
	EOR #$FF
	ADC #$01						;(C = 0)
:	CMP collW
	BEQ :+
	BCS @done
:	LDA objY+OSLOT_BUBBLE,Y			;|bubble Y - enemy Y| <= collH
	SEC
	SBC objY+OSLOT_ENEMY,X
	BCS :+
	EOR #$FF
	ADC #$01
:	CMP collH
	BEQ :+
	BCS @done
:	LDA ram_00CA
	ORA #$80
	STA ram_00CA
	JSR CoopShotExchange			;the follow-up code now works on the catching player's shot
@done:
	PLA
	TAY
@rts:
	RTS

; ---------------------------------------------------------------------------------------------
; Projectiles vs P2 (Phase 5). UpdateProjectiles (even tick, P1 resident) runs PlayerCheckProjCollision
; (P1) for each projectile, then the projectile's script, whose ops act on "the player" (HurtPlayer and
; CatchPlayer write playerDmgType; CopyPlayerState reads playerState; PlayerState writes playerState,
; inflateTime, extraBubbles, ram_0076 and slot 0's animation; Heart writes playerHearts and calls
; AddScore; the homing/distance/side ops read slot 0's position).
; CoopProjCheckP2: if P1 was not hit, the same test against P2 (slot OSLOT_P2, ctxOther_playerInvFrames);
; on a hit P2 is swapped in (coopResident = 1) and PROJ_HIT is set, so the script runs exactly as for P1
; but on P2's state. CoopProjSwapBack (at the script's end, @trymove) puts P1 back. A swap pair costs
; ~1.4k cycles but only on a P2 hit (i-frames follow). X = projectile index (kept); collW/collH = size.
; ---------------------------------------------------------------------------------------------
CoopProjCheckP2:
	LDA objState+OSLOT_PROJ,X
	BMI @done						;PROJ_HIT: P1 was hit (P1 has priority)
	LDA ctxOther_playerInvFrames
	BNE @done
	LDA objX+OSLOT_PROJ,X			;|proj X - P2 X| <= collW
	SEC
	SBC objX+OSLOT_P2
	BCS :+
	EOR #$FF
	ADC #$01						;(C = 0)
:	CMP collW
	BEQ :+
	BCS @done
:	LDA objY+OSLOT_PROJ,X			;|proj Y - P2 Y| <= collH
	SEC
	SBC objY+OSLOT_P2
	BCS :+
	EOR #$FF
	ADC #$01
:	CMP collH
	BEQ :+
	BCS @done
:	JSR CoopShotRestore				;(keeps every CoopSwap on unexchanged shot bytes; A only)
	TXA
	PHA
	JSR CoopSwap					;P2 resident for this projectile's ops
	PLA
	TAX
	LDA objState+OSLOT_PROJ,X
	ORA #PROJ_HIT
	STA objState+OSLOT_PROJ,X
@done:
	RTS

CoopProjSwapBack:
	TXA
	PHA
	JSR CoopSwap					;P1 resident again
	PLA
	TAX
	RTS

; ---------------------------------------------------------------------------------------------
; CoopHazardCheckP2 (Phase 5): tail of HazardCheckPlayer (bank 9), co-op only. HazardCheckPlayer tests
; slot 0 (P1, resident in UpdateBubbles) against a popped special bubble's effect box (collW/collH and
; scratch4/5 = centre, computed there); the same box is tested against P2 (slot OSLOT_P2) and a hit sets
; P2's shadow playerHazardTrigger / playerHazardSlot. Keeps X and Y.
; ---------------------------------------------------------------------------------------------
CoopHazardCheckP2:
	LDA objX+OSLOT_P2
	CMP scratch4
	BCC @xless
	SBC scratch4
	JMP @checkwidth
@xless:
	LDA scratch4
	SEC
	SBC objX+OSLOT_P2
@checkwidth:
	CMP collW
	BCS @end
	LDA objY+OSLOT_P2
	CMP scratch5
	BCC @yless
	SBC scratch5
	JMP @checkheight
@yless:
	LDA scratch5
	SEC
	SBC objY+OSLOT_P2
@checkheight:
	CMP collH
	BCS @end
	LDA #$F0
	ORA roundBubbleVariant
	STA ctxOther_playerHazardTrigger
	STX ctxOther_playerHazardSlot
@end:
	RTS

CoopP2WindowIntro:
	LDA #.BANK(CODE_0B8196)
	JSR CoopP2Window
	;AnimateObjects (slots 20-39) does not run during the intro: animate P2 on odd ticks
	;(P1 is animated by AnimateNonBubbles on even ticks there, same cadence as in RoundUpdate).
	;CoopAnimateP2 leaves AnimTable's bank at $A000; DrawObjects, next in CODE_0B8196, maps its own.
	LDA globalTimer
	AND #$01
	BNE CoopAnimateP2
	RTS

; ---------------------------------------------------------------------------------------------
; CoopAnimateP2: run AnimateObjects' per-slot body for OSLOT_P2 only (it ends at X = 40).
; Maps AnimTable at $A000 exactly as AnimateObjects does (race-free order, prgBankB before $8001;
; SwapPrgBankB would do the same through newPrgBank). Clobbers A/X/Y.
; ---------------------------------------------------------------------------------------------
CoopAnimateP2:
	LDA #$07
	STA $8000
	LDA #.BANK(AnimTable)
	STA prgBankB
	STA $8001
	LDX #OSLOT_P2
	JMP AnimateObjectsFromX

; ---------------------------------------------------------------------------------------------
; CoopRoundStartP2: called from CODE_0884CF (bank 8) on the tick P1 reaches the start position (once
; per round start: that block replaces nmiBankedSub). In co-op: P2's per-life context is initialised
; by the same code as P1's (CODE_08812A, run with P2 swapped in), then P2 is spawned. CODE_08812A also
; writes two shared bytes (wideScrollDir = 0, roundFlags &= 7); they are saved and restored so that
; P2's init cannot change them. Clobbers A/X/Y.
; ---------------------------------------------------------------------------------------------
CoopRoundStartP2:
	LDA coopMode
	BEQ @done
	LDA roundFlags
	PHA
	LDA wideScrollDir
	PHA
	JSR CoopSwap
	LDA #.LOBYTE(CODE_08812A)
	STA bankedSub
	LDA #.HIBYTE(CODE_08812A)
	STA bankedSub+1
	LDA #.BANK(CODE_08812A)
	STA bankedSubBank
	LDA #.BANK(CODE_0884AB)			;the caller's bank stays at $8000
	STA bankedSubRetBank
	JSR RunBankedSub
	JSR CoopSwap
	PLA
	STA wideScrollDir
	PLA
	STA roundFlags
	JMP CoopSpawnP2
@done:
	RTS

; ---------------------------------------------------------------------------------------------
; CoopSpawnP2: put P2 into the round (from CoopRoundStartP2, after P2's per-life init).
; P2: P1's position mirrored horizontally (X' = 256 - X, clamped), facing left (CODE_08812A left
; playerDir = 1 = left), object slot OSLOT_P2 set up like CODE_0880C8 sets slot 0.
; Then the bubble budget shrinks to 19 slots and the P2 windows start. Clobbers A/X/Y.
; ---------------------------------------------------------------------------------------------
CoopSpawnP2:
	LDA objY
	STA objY+OSLOT_P2
	LDA #$00
	SEC
	SBC objX
	CMP #COOP_P2_XMIN
	BCS :+
	LDA #COOP_P2_XMIN
:	CMP #COOP_P2_XMAX+1
	BCC :+
	LDA #COOP_P2_XMAX
:	STA objX+OSLOT_P2
	LDA #$01
	STA objState+OSLOT_P2
	LDA #.LOBYTE(anPlayerL_ID)
	STA objAnim+OSLOT_P2
	LDA #.HIBYTE(anPlayerL_ID)
	STA objAnimHI+OSLOT_P2
	STA objChrSlot+OSLOT_P2			;(A = 0) CHR slot 0, palette 0 (see coop_notes Phase 3)
	STA objAttr+OSLOT_P2
	STA objAnimProgress+OSLOT_P2
	STA objAnimTimer+OSLOT_P2
	LDA objChrBank					;until the first animation step: P1's image (same CHR bank)
	STA objChrBank+OSLOT_P2
	LDA objImgOfs
	STA objImgOfs+OSLOT_P2
	LDA objImgOfsHI
	STA objImgOfsHI+OSLOT_P2
	LDA #COOP_P2_ACTIVE
	STA coopP2Active
	LDA #BUBBLE_SLOTS-1
	STA bubbleSlotEnd
	LDA #BUBBLE_SLOTS-2
	STA bubbleSlotLast
	JMP CoopAnimateP2				;load the first frame of anPlayerL

; ---------------------------------------------------------------------------------------------
; CoopP2Deactivate: P2 leaves the round. Called from CODE_0FE36B (bank F), the routine that despawns
; all 40 objects: title, new game, continue, ending, every round setup (CODE_088000, also after a
; P1 death), bonus round start. Hides slot OSLOT_P2 and gives the slot back to the bubbles. The
; caller clears objState of slot 39 right after, so with coopMode = 0 this changes no console RAM.
; Shot bytes still exchanged by a capture are put back first (Phase 5). Clobbers A only.
; ---------------------------------------------------------------------------------------------
CoopP2Deactivate:
	JSR CoopShotRestore
	LDA #$00
	STA coopP2Active
	STA objState+OSLOT_P2
	LDA #BUBBLE_SLOTS
	STA bubbleSlotEnd
	LDA #BUBBLE_SLOTS-1
	STA bubbleSlotLast
	RTS

; ---------------------------------------------------------------------------------------------
; CoopNewGame: after ResetLivesAndScore at a new game (CODE_0582BE, bank 5). In co-op, P2's
; shadow context starts clean with P1's starting lives and hearts. Clobbers A/X.
; ---------------------------------------------------------------------------------------------
CoopNewGame:
	LDA coopMode
	BEQ @done
	LDX #CTX_OTHER_SIZE-1
	LDA #$00
@clear:
	STA ctxOther,X
	DEX
	BPL @clear
	LDA playerLives
	STA ctxOther_playerLives
	LDA playerHearts
	STA ctxOther_playerHearts
@done:
	RTS

; ---------------------------------------------------------------------------------------------
; Invincibility blink for P2 (RoundUpdate hides slot 0 during DrawObjects when playerInvFrames & 2).
; CoopP2BlinkHide before DrawObjects, CoopP2BlinkRestore after it. Preserve X/Y.
; ---------------------------------------------------------------------------------------------
CoopP2BlinkHide:
	LDA objState+OSLOT_P2
	STA coopP2SavedState
	LDA ctxOther_playerInvFrames
	AND #$02
	BEQ :+
	LDA #$00
	STA objState+OSLOT_P2
:	RTS

CoopP2BlinkRestore:
	LDA coopP2SavedState
	STA objState+OSLOT_P2
	RTS
