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

	RTS								;(R2) COOP_FORCE now pre-selects the co-op line at the title (bank 5 @advance)

; ---------------------------------------------------------------------------------------------
; CoopSwap: exchange the resident player with the one stored in ctxOther / object slot OSLOT_P2.
;   - every COOP_CTX_SCALARS entry <-> its shadow byte ctxOther_<name>
;   - every COOP_CTX_ARRAYS array: slot 0 <-> slot OSLOT_P2
;   - powerUps: only the bits in COOP_POWERUP_MASK are exchanged with ctxOther_powerUps
;   - coopResident ^= 1; currentPlayer = coopResident ^ coopRoles (the physical id of the new resident;
;     coopRoles = 1 after P1 went out and P2 became the resident player, Phase 7a)
; CoopSwapCtx (Phase 7a) is the same without the object arrays (for flows where the objects do not matter:
; continue, new game, game over). Clobbers A and X; preserves Y; flags undefined. Unrolled (lists in coop.inc).
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
	COOP_CTX_ARRAYS COOP_SWAP_ARRAY
CoopSwapCtx:
	COOP_CTX_SCALARS COOP_SWAP_SCALAR

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
	EOR coopRoles
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
	;Phase 7a: P2's last death has just ended (lives 0 and no longer dying: PlayerHandlerDead set state 0 and
	;skipped the respawn). P2 is out: swap back and leave the round (slot OSLOT_P2 back to the bubbles).
	LDA playerLives
	BNE @in
	LDA playerState
	CMP #PLAYER_STATE_DEAD
	BEQ @in
	JSR CoopSwap
	JSR CoopP2Deactivate
	JMP @restore
@in:
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
@restore:
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
	;Phase 6b: P2 popped a special bubble whose effect has a direction (thunder, water, wind): record P2's
	;facing. The same tick's UpdateBubbles reaches this POPPING bubble and CODE_0981F8 (objAnimHI != 0)
	;reads it through CoopPopDir instead of P1's playerDir (and clears the mark).
	LDA objState+OSLOT_BUBBLE,X
	CMP #BUBBLE_POPPING
	BNE @next
	LDA objAnimHI+OSLOT_BUBBLE,X
	BEQ @next						;normal bubble: CODE_0981F8 is not reached
	LDA roundBubbleVariant
	AND #$7F
	TAY
	LDA DATA_0981E5,Y
	BEQ @next						;no directed effect: CODE_0981F8 does not read playerDir
	LDA playerDir					;P2's (resident)
	ORA #$80
	STA coopPopDir,X
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
	LDA ctxOther_playerLives		;(7a) the other player is out (no lives left): he stays out until a continue
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
; Phase 7a: also called in the middle of a round when the non-resident player is out (P2's last death in
; its window, or after the role exchange in CoopResidentOut); the caller then frees slot OSLOT_P2.
; CoopDespawnAll (the CODE_0FE36B hook) also forgets the score-owner tags of the round.
; ---------------------------------------------------------------------------------------------
CoopDespawnAll:
	LDA #$FF
	LDX #BUBBLE_SLOTS-1
:	STA coopBubOwner,X
	DEX
	BPL :-
	LDX #10-1
:	STA coopKiller,X
	DEX
	BPL :-
	LDA #$00
	STA coopKills
	STA coopKills+1
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
; shadow context starts clean, then ResetLivesAndScore runs for P2 (3 lives, 1 heart, score 0).
; Clobbers A/X/Y.
; ---------------------------------------------------------------------------------------------
CoopNewGame:
	LDA #$00
	STA coopRoles					;(7a) physical P1 resident again (currentPlayer = 0 was set by the caller)
	LDA coopMode
	BEQ @done
	LDX #CTX_OTHER_SIZE-1
	LDA #$00
@clear:
	STA ctxOther,X
	DEX
	BPL @clear
	;(7a) P2's lives, hearts and score digits as ResetLivesAndScore sets P1's (bank 5 is mapped)
	JMP CoopResetOther
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

; =============================================================================================
; Phase 6a: enemy target selection (COOP_CODE2). The enemy AI (CODE_0B81B6, even tick) always runs
; with P1 resident: P1 = slot 0 + native player vars, P2 = slot OSLOT_P2 + ctxOther_*. Enemy code reads
; targetX / targetY instead of slot 0's objX / objY, and routes direct damage through CoopDamageTarget.
;   P2 not in the round (1P, coopMode = 0): CoopTargetTick copies slot 0 once per even tick (coopTarget = 0),
;     so every converted read sees exactly the value it read before.
;   P2 in the round: CoopSelectTarget runs per enemy, before its behaviour, and picks the nearest
;     targetable player by |dx| + |dy| (ties: P1). Targetable = playerState != PLAYER_STATE_DEAD (the only
;     death/respawn state: the respawn sets state 0 in place). Neither targetable: coopTarget is kept and
;     targetX/targetY are refreshed from that player.
; =============================================================================================

; CoopTargetTick: top of the enemy loop (CODE_0B81E3, bank B). Clobbers A.
CoopTargetTick:
	BIT coopP2Active
	BMI @rts						;P2 in the round: CoopSelectTarget per enemy
	LDA #$00
	STA coopTarget
	LDA objX
	STA targetX
	LDA objY
	STA targetY
@rts:
	RTS

; CoopSelectTarget: enemy loop, per live enemy before its behaviour (bank B, gated by coopP2Active).
; X = enemy index (kept), Y kept.
CoopSelectTarget:
	TYA
	PHA
	LDA objX+OSLOT_ENEMY,X
	STA coopPos
	LDA objY+OSLOT_ENEMY,X
	STA coopPos+1
	JSR CoopNearest					;A = 0 / 1 / $FF (flags from A)
	BPL :+
	LDA coopTarget					;nobody targetable: keep the previous target
:	STA coopTarget
	BNE @p2
	LDA objX
	STA targetX
	LDA objY
	STA targetY
	PLA
	TAY
	RTS
@p2:
	LDA objX+OSLOT_P2
	STA targetX
	LDA objY+OSLOT_P2
	STA targetY
	PLA
	TAY
	RTS

; CoopProjTarget: projectile ops that aim at "the player" (bank 9: HomingPlayer, GetPlayerDist,
; GetPlayerSide). X = projectile index (kept). Out: Y = slot of the nearest targetable player (0, or
; OSLOT_P2; neither targetable: 0) and targetX/targetY = its position. Slot 0 is the resident player
; (P2 while a projectile that touched P2 runs its ops), so the rule is symmetric. P2 not in the round: slot 0.
CoopProjTarget:
	LDY #$00
	BIT coopP2Active
	BPL @set
	LDA objX+OSLOT_PROJ,X
	STA coopPos
	LDA objY+OSLOT_PROJ,X
	STA coopPos+1
	JSR CoopNearest
	LDY #$00
	CMP #$01
	BNE @set
	LDY #OSLOT_P2
@set:
	LDA objX,Y
	STA targetX
	LDA objY,Y
	STA targetY
	RTS

; CoopNearest: nearest targetable player to (coopPos, coopPos+1). Candidates: slot 0 with the native
; playerState, slot OSLOT_P2 with ctxOther_playerState (the caller has checked that P2 is in the round).
; Out: A = 0 (slot 0), 1 (slot OSLOT_P2), $FF (neither targetable); N/Z from A. Keeps X, clobbers Y.
.macro COOP_ABSDIFF m1, m2			;A = |m1 - m2| (8 bits), C undefined
	LDA m1
	SEC
	SBC m2
	BCS :+
	EOR #$FF
	ADC #$01						;(C = 0 here)
:
.endmacro

CoopNearest:
	LDY #$00						;Y = 1 (slot 0 targetable) + 2 (slot OSLOT_P2 targetable)
	LDA playerState
	CMP #PLAYER_STATE_DEAD
	BEQ :+
	INY
:	LDA ctxOther_playerState
	CMP #PLAYER_STATE_DEAD
	BEQ :+
	INY
	INY
:	CPY #$03
	BEQ @both
	DEY								;1 -> 0, 2 -> 1, 0 -> $FF
	TYA
	RTS
@both:
	COOP_ABSDIFF coopPos, objX
	STA coopDist
	COOP_ABSDIFF coopPos+1, objY
	CLC
	ADC coopDist
	STA coopDist
	LDA #$00
	ROL A
	STA coopDist+1					;slot 0: 9-bit distance
	COOP_ABSDIFF coopPos, objX+OSLOT_P2
	STA coopDist+2
	COOP_ABSDIFF coopPos+1, objY+OSLOT_P2
	CLC
	ADC coopDist+2
	TAY								;slot OSLOT_P2: lo in Y, hi from C
	LDA #$00
	ROL A
	CMP coopDist+1
	BCC @other						;hi below
	BNE @first						;hi above
	CPY coopDist
	BCC @other						;lo below (equal: slot 0)
@first:
	LDA #$00
	RTS
@other:
	LDA #$01
	RTS

; CoopDamageTarget: replaces STA playerDmgType in enemy code (Snagger). A = damage (kept, N/Z from A),
; X/Y kept. P2's damage goes to its shadow byte and is consumed by P2's next player update.
CoopDamageTarget:
	PHA
	LDA coopTarget
	BNE @p2
	PLA
	STA playerDmgType
	RTS
@p2:
	PLA
	STA ctxOther_playerDmgType
	RTS

; CoopSetTargetY: replaces STA objY in enemy code that moves the targeted player (Needler, US-only
; block, never reached in the original). A = new Y (kept), X/Y kept.
CoopSetTargetY:
	STA targetY
	PHA
	LDA coopTarget
	BNE @p2
	PLA
	STA objY
	RTS
@p2:
	PLA
	STA objY+OSLOT_P2
	RTS

; CoopSetP1Y / CoopSetP1X: replace STA objY / STA objX in enemy code that moves P1 itself (Ruckus's
; round-20 wrap of the player, not aiming): the write stays on slot 0, and targetX/targetY follow it while
; P1 is the target, so later reads in the same enemy loop see the new position as before. A/X/Y kept.
CoopSetP1Y:
	STA objY
	PHA
	LDA coopTarget
	BNE :+
	PLA
	STA targetY
	RTS
:	PLA
	RTS

CoopSetP1X:
	STA objX
	PHA
	LDA coopTarget
	BNE :+
	PLA
	STA targetX
	RTS
:	PLA
	RTS

; =============================================================================================
; Phase 6b: world -> player interactions (COOP_CODE2). See docs/coop_notes.md, Phase 6b.
; =============================================================================================

; ---------------------------------------------------------------------------------------------
; Items (CODE_078916, bank 7, even tick, P1 resident). Every collect test goes through CODE_078BC5, which
; tests the resident player (slot 0, playerState) against the item in slot scratch4 (box scratch2/scratch3)
; and sets bit 7 of the item's objState on a touch; the caller then applies the effect to the resident
; player's variables (hearts, candy/shoe bits, bubbleVariant, lives; AddScore via currentPlayer) and the
; shared ones (roundFlags, continues, crystals, the clock...).
; CoopItemOther is the tail of CODE_078BC5 on a miss: the same test for the other player (slot OSLOT_P2,
; ctxOther_playerState). On a touch it sets bit 7 and swaps the other player in (CoopSwap), so the caller's
; unchanged effect code credits the collector. Later tests in the same CODE_078916 run test the (new)
; resident first, then the other one. CoopItemEnd (CODE_078A67, on every exit of CODE_078916) swaps P1 back.
; X kept (CODE_078D5C's reward index), scratch0/1 untouched (CODE_078D2D counts in scratch0), Y = item slot.
; ---------------------------------------------------------------------------------------------
CoopItemOther:
	BIT coopP2Active
	BPL @no							;1P / P2 not in the round
	LDA coopItemNoOther
	BEQ CoopItemOtherTest			;(non-zero: drink, the other player may not drink)
@no:
	RTS
CoopItemOtherTest:
	LDA ctxOther_playerState
	CMP #PLAYER_STATE_DEAD
	BEQ @rts
	LDY scratch4
	LDA objX+OSLOT_P2				;|X - item X| <= scratch2
	SEC
	SBC objX,Y
	BCS :+
	EOR #$FF
	ADC #$01						;(C = 0)
:	CMP scratch2
	BEQ :+
	BCS @rts
:	LDA objY+OSLOT_P2				;|Y - item Y| <= scratch3
	SEC
	SBC objY,Y
	BCS :+
	EOR #$FF
	ADC #$01
:	CMP scratch3
	BEQ :+
	BCS @rts
:	LDA objState,Y
	ORA #$80
	STA objState,Y
	JSR CoopShotRestore				;(every CoopSwap on unexchanged shot bytes; A only)
	TXA
	PHA
	JSR CoopSwap					;the collector is resident for the effect (keeps Y)
	PLA
	TAX
@rts:
	RTS

CoopItemEnd:						;replaces LDA ram_0550 at CODE_078A67, which every exit of CODE_078916 passes;
	LDA coopResident				;out: A = ram_0550, N/Z from it. Clobbers X (not live there).
	BEQ @done
	JSR CoopSwap					;P1 resident again (before CODE_078EBE's palette, which uses currentPlayer)
@done:
	LDA ram_0550
	RTS

; CoopDrinkGate: replaces "bubbleVariant != 0 or playerLives = 0 -> no drink" (CODE_078982). A player may
; drink while his bubbleVariant is 0 and he has lives. Out: A = coopDrinkElig (bit 0 the resident P1,
; bit 1 P2), Z = 1 when nobody may drink (then the drink is neither spawned nor tested, as in 1P).
CoopDrinkGate:
	LDA #$00
	STA coopDrinkElig
	LDA bubbleVariant
	BNE @p2
	LDA playerLives
	BEQ @p2
	INC coopDrinkElig
@p2:
	BIT coopP2Active
	BPL @done
	LDA ctxOther_bubbleVariant
	BNE @done
	LDA ctxOther_playerLives
	BEQ @done
	LDA coopDrinkElig
	ORA #$02
	STA coopDrinkElig
@done:
	LDA coopDrinkElig
	RTS

; CoopDrinkTouch: replaces JSR CODE_078BC5 for the drink: only the players CoopDrinkGate allowed can take it.
CoopDrinkTouch:
	LDA coopDrinkElig
	AND #$02
	EOR #$02
	STA coopItemNoOther				;0 = P2 may drink
	LDA coopDrinkElig
	LSR A
	BCC @p2only
	JSR CODE_078BC5					;P1, then (tail) P2 if allowed
	JMP @done
@p2only:
	JSR CoopItemOtherTest			;only reached in co-op (bit 1 needs coopP2Active)
@done:
	LDA #$00
	STA coopItemNoOther
	RTS

; ---------------------------------------------------------------------------------------------
; Rising water (CODE_078682 -> CODE_0786B8, bank 7, every tick before the player updates, P1 resident).
; Tail of P1's test: P2 below the water line gets the same trigger ($F8) in its shadow byte; P2's next
; player update sees it, as P1's does (P2's touch pass clears it on odd ticks, as UpdateBubbles does P1's).
; ---------------------------------------------------------------------------------------------
CoopWaterP2:
	BIT coopP2Active
	BPL @rts
	LDA irqLatch
	SEC
	SBC #12							;the US water line, as CODE_0786B8
	CMP objY+OSLOT_P2
	BCS @rts
	LDA #$F8
	STA ctxOther_playerHazardTrigger
@rts:
	RTS

; ---------------------------------------------------------------------------------------------
; CoopPopDir: replaces LDA playerDir in CODE_0981F8 (UpdateBubbles, P1 resident). X = bubble index (kept),
; Y kept. A = P2's playerDir if P2's touch pass popped this bubble (mark cleared), else P1's playerDir.
; ---------------------------------------------------------------------------------------------
CoopPopDir:
	LDA coopPopDir,X
	BPL @p1
	AND #$7F
	PHA
	LDA #$00
	STA coopPopDir,X
	PLA
	RTS
@p1:
	LDA playerDir
	RTS

; ---------------------------------------------------------------------------------------------
; SuperRedSkull landing quake (bank 8, enemy AI, P1 resident).
; CoopQuakeReady replaces LDA playerState / CMP #$0A in CODE_0895F3: no new jump while a player is stunned.
; Out: Z = 1 if P1 or (P2 in the round) P2 is in state $0A. X/Y kept.
; CoopQuakeStunP2 (CODE_08981A, landing): P2 gets the stun by P1's rule (no i-frames, ram_0078 bit 7).
; A only.
; ---------------------------------------------------------------------------------------------
COOP_STATE_STUN = PLAYER_STATE_UNKA	;$0A, set by the quake

CoopQuakeReady:
	LDA playerState
	CMP #COOP_STATE_STUN
	BEQ @rts
	LDA coopP2Active
	BPL @no
	LDA ctxOther_playerState
	CMP #COOP_STATE_STUN
	RTS
@no:
	LDA #$01						;Z = 0
@rts:
	RTS

CoopQuakeStunP2:
	BIT coopP2Active
	BPL @rts
	LDA ctxOther_playerInvFrames
	BNE @rts
	LDA ctxOther_ram_0078
	CMP #$80
	BCC @rts
	LDA #COOP_STATE_STUN
	STA ctxOther_playerState
	LDA #$00
	STA ctxOther_ram_0076
@rts:
	RTS

; =============================================================================================
; Phase 7a: death and game flow (COOP_CODE2). See docs/coop_notes.md, Phase 7a.
;   - a player whose last death ends is OUT. P2 out (its window sees lives 0, not dying): P2 leaves the round.
;     P1 out (RoundUpdate end, CoopResidentOut) while P2 is in the round: P2 becomes the resident player for good
;     (role exchange, coopRoles = 1) and the game goes on as P2's 1-player game. Both out: the original game
;     over (roles put back first); continue (CoopContinue) restarts both.
;   - an out player is not spawned at round starts (CoopRoundStartP2) until a continue / new game.
; =============================================================================================

; ---------------------------------------------------------------------------------------------
; CoopResidentOut: end of RoundUpdate (bank 9) when the resident player has no lives left and is not dying
; (his last death just ended: PlayerHandlerDead set state 0 and skipped the respawn).
;   partner in the round: the partner becomes the resident player (CoopSwap, then coopResident = 0 and
;     coopRoles ^= 1, so currentPlayer keeps naming him), the out player's slot OSLOT_P2 goes back to the
;     bubbles. Out: C = 1 (RoundUpdate skips the rest of its end checks this tick).
;   no partner: the original game over follows (C = 0). Exchanged roles are put back first (contexts only; the
;     game-over flow despawns every object), so game over and continue see physical P1 resident.
; Clobbers A/X/Y.
; ---------------------------------------------------------------------------------------------
CoopResidentOut:
	BIT coopP2Active
	BPL @nopartner
	JSR CoopShotRestore
	JSR CoopSwap					;partner resident (coopResident = 1)
	LDA #$00
	STA coopResident
	LDA coopRoles
	EOR #$01
	STA coopRoles
	STA currentPlayer				;= coopResident (0) ^ coopRoles: still the partner's id
	JSR CoopP2Deactivate			;the out player (now in ctxOther / slot OSLOT_P2) leaves the round
	LDA livesCurrentPos				;HUD refresh (score, lives, hearts) for the new resident player
	ORA #$03
	STA livesCurrentPos
	SEC
	RTS
@nopartner:
	LDA coopRoles
	BEQ @gameover
	JSR CoopSwapCtx					;physical P1's context native again (coopResident 1, currentPlayer 0)
	LDA #$00
	STA coopResident
	STA coopRoles
	STA currentPlayer
@gameover:
	CLC
	RTS

; ---------------------------------------------------------------------------------------------
; CoopContinue: continue chosen (CODE_058DB2, bank 5: after ResetLivesAndScore for P1, before CODE_05962D, the
; round restart).
; Co-op: P2 gets the same fresh start; CoopRoundStartP2 then spawns both players again.
; CoopResetOther: ResetLivesAndScore for the other player's context (3 lives, 1 heart, his score and extra-life
; accumulator 0; currentPlayer = 1 while it runs). Objects untouched. Bank 5 must be mapped. Clobbers A/X/Y.
; ---------------------------------------------------------------------------------------------
CoopContinue:
	LDA coopMode
	BEQ CoopFlowRts
CoopResetOther:
	JSR CoopSwapCtx
	JSR ResetLivesAndScore
	JMP CoopSwapCtx

; (R2) CoopMultiplayer (the 7a gate of the alternating-2P death switch) is gone with the alternating mode.
CoopFlowRts:
	RTS

; CoopP2Dead (bank B: CODE_0B9CB3 calms angry enemies and CODE_0B9D63 resets the hurry-up while a player is
; dying; only called while P2 is in the round): Z = 1 if P2 is dying. A clobbered, X/Y kept.
CoopP2Dead:
	LDA ctxOther_playerState
	CMP #PLAYER_STATE_DEAD
	RTS

; CoopBossCandy (bank 8, CODE_088664, a boss round is cleared): the candy is taken from both players (the
; original clears the resident's only). Replaces LDA/AND/ORA/STA powerUps. A clobbered.
CoopBossCandy:
	LDA powerUps
	AND #<~POWERUP_CANDY
	ORA #POWERUP_BOSS_BONUS
	STA powerUps
	LDA ctxOther_powerUps
	AND #<~POWERUP_CANDY
	STA ctxOther_powerUps
	RTS

; CoopDoorOther (bank 7, CollectSecretDoor, tail): the other player's pending damage is cleared as well before
; the bonus round (the collector's is cleared by the original code). A = 0 on entry.
CoopDoorOther:
	STA ctxOther_ram_007B
	STA ctxOther_playerDmgType
	RTS

; ---------------------------------------------------------------------------------------------
; CoopExtraLifeOther (RoundUpdate end, after the resident's check CODE_099D3B, while P2 is in the round): the
; same check for the other player's score. His lives are exchanged with the native byte and currentPlayer names
; him while CODE_099D3B runs (it indexes the extra-life accumulator by currentPlayer and increments playerLives;
; bubblesLifespanLevel and the HUD flag livesCurrentPos are shared). Bank 9 is mapped. Clobbers A/X/Y.
; ---------------------------------------------------------------------------------------------
CoopExtraLifeOther:
	JSR @xchg
	JSR CODE_099D3B
@xchg:
	LDA playerLives
	LDX ctxOther_playerLives
	STX playerLives
	STA ctxOther_playerLives
	LDA currentPlayer
	EOR #$01
	STA currentPlayer
	RTS

; =============================================================================================
; Phase 7a: score attribution (COOP_CODE). Scores granted by code that runs with P1 resident go to the player
; who earned them. Owners are physical player ids (currentPlayer of the player who acted); $FF = unknown,
; credited to currentPlayer as in the original. In 1P every owner is currentPlayer, so the credit is unchanged.
;   coopBubOwner[bubble]: the popper (touch pop, CoopTouchPop) or, for a chain pop, the owner of the popped
;                         bubble that touched it (CoopChainOwner); copied to water-flood pieces (CoopFloodCopy)
;   coopKiller[enemy]:    set at the kill: enemy bubble popped (CoopCountKill: bubble owner), special-bubble
;                         effect (CoopHazKill: effect owner), holy cup (CoopHolyKill: collector), shot hit
;                         (CoopShotHit: shot owner). Read by CODE_0B8446 / CODE_0B9B2F (CoopKillScore/End).
;   coopKills[player]:    enemy-bubble kills since the last multi-kill award (ram_051A = their sum);
;                         CoopKillSplit gives each player his own award.
; =============================================================================================
.segment "COOP_CODE"

; CoopAddScoreAs: AddScore credited to physical player A (0/1; negative = currentPlayer). Clobbers A/X/Y.
CoopAddScoreAs:
	BMI @cur
	LDX currentPlayer
	STX coopTmp+2
	STA currentPlayer
	JSR AddScore
	LDA coopTmp+2
	STA currentPlayer
	RTS
@cur:
	JMP AddScore

; CoopTouchPop (bank 9 CODE_0989BD; replaces STX scratch1 / JSR PopBubble): the resident player pops bubble X
; by touching it and owns the pop.
CoopTouchPop:
	LDA currentPlayer
	STA coopBubOwner,X
	STX scratch1
	JMP PopBubble

; CoopChainOwner (bank 9 BubblesTravelUpdate; the popped bubble scratch0 pops bubble X): X gets its owner.
; A clobbered, X/Y kept.
CoopChainOwner:
	TYA
	PHA
	LDY scratch0
	LDA coopBubOwner,Y
	STA coopBubOwner,X
	PLA
	TAY
	RTS

; CoopFloodCopy (bank 9 CODE_0988EC; replaces LDA/STA bubbleProgress): the new water-flood piece Y belongs to
; the owner of the water bubble X.
CoopFloodCopy:
	LDA coopBubOwner,X
	STA coopBubOwner,Y
	LDA bubbleProgress,X
	STA bubbleProgress,Y
	RTS

; CoopCountKill (bank F PopBubble, an enemy bubble is popped; replaces INC ram_051A): X = enemy index,
; scratch1 = bubble index. The bubble's owner killed the enemy and gets the kill counted.
; Clobbers A/X/Y (PopBubble reloads X from scratch1 next).
CoopCountKill:
	INC ram_051A
	LDY scratch1
	LDA coopBubOwner,Y
	BPL :+
	LDA currentPlayer
:	STA coopKiller,X
	TAX
	INC coopKills,X
	RTS

; CoopKillSplit (bank 9 BubblesTravelUpdate, multi-kill award; bank 4 at $A000; Y = ram_051A != 0): the kills
; of the player who is not currentPlayer get their own award (same rule and table), credited to him. Returns
; Y = the current player's share, Z from Y (the original code awards it to currentPlayer). Counts cleared.
CoopKillSplit:
	STY coopTmp
	LDA currentPlayer
	EOR #$01
	TAX
	LDA coopKills,X
	BEQ @rest
	CMP coopTmp
	BCC :+
	LDA coopTmp						;(never more than the total)
:	STA coopTmp+1
	TXA
	PHA
	LDY coopTmp+1
	JSR CoopMultiAward
	PLA
	JSR CoopAddScoreAs
	LDA coopTmp
	SEC
	SBC coopTmp+1
	STA coopTmp
@rest:
	LDA #$00
	STA coopKills
	STA coopKills+1
	LDY coopTmp
	RTS

; CoopMultiAward: the original award for Y kills (Y >= 1): bonus reward flags for 3+, score digits from the
; bank-4 tables (mapped at $A000). AddScore is left to the caller.
CoopMultiAward:
	CPY #$03
	BCC @tab
	LDA #$01
	STA bonusRewardEarned
	LDA roundSkelDelay
	BEQ @tab
	LDA roundFlags
	ORA #RFLAG_MULTI_REWARD
	STA roundFlags
@tab:
	LDX DATA_04BF6D,Y
	LDA DATA_04BF64,Y
	STA scoreAdditionDigits,X
	LDX DATA_04BF7F,Y
	LDA DATA_04BF76,Y
	STA scoreAdditionDigits,X
	RTS

; CoopHazEnter (bank 9 HazardCheckEnemies entry; replaces TXA): X = the special bubble whose effect is tested;
; its owner is the owner of every kill of this test. Out: A = X.
CoopHazEnter:
	LDA coopBubOwner,X
	STA coopHazOwner
	TXA
	RTS

; CoopHazKill (HazardCheckEnemies; replaces ORA #$C0 / STA objState+OSLOT_ENEMY,X): the effect hits enemy X.
CoopHazKill:
	ORA #$C0
	STA objState+OSLOT_ENEMY,X
	LDA coopHazOwner
	STA coopKiller,X
	RTS

; CoopHolyKill (bank 7 CollectHolyCup; replaces ORA #$E0 / STA objState+OSLOT_ENEMY,X): the collector
; (resident during the item code) kills enemy X.
CoopHolyKill:
	ORA #$E0
	STA objState+OSLOT_ENEMY,X
	LDA currentPlayer
	STA coopKiller,X
	RTS

; CoopShotHit (bank B CODE_0B9AA9, an emerging bubble hits enemy X; replaces LDY shootQueuedBubbles): the shot
; owner is the resident, or the other player while his shot bytes are exchanged in (coopShotSwapped, Phase 5).
CoopShotHit:
	LDA currentPlayer
	EOR coopShotSwapped
	STA coopKiller,X
	LDY shootQueuedBubbles
	RTS

; CoopKillScore (bank B CODE_0B8446, effect / holy-cup kill; replaces JSR AddScore): credited to the killer.
; CoopKillScoreEnd (bank B CODE_0B9B2F, the enemy is removed with a score): the same, and the record is cleared.
; X = enemy index. Clobbers A/X/Y (the callers restore X).
CoopKillScore:
	LDA coopKiller,X
	JMP CoopAddScoreAs
CoopKillScoreEnd:
	LDA coopKiller,X
	PHA
	LDA #$FF
	STA coopKiller,X
	PLA
	JMP CoopAddScoreAs

; =============================================================================================
; Phase 7b-1: 8x8 HUD, engine variant A (see docs/coop_notes.md, Phase 7b-1).
; The original HUD job code (CODE_099BE7: countdown livesCurrentPos 3 -> 2 -> 1 -> 0, one job per tick, mapBuffer,
; mapTargetAdr, livesDigits, ram_03AA/AB/AE) runs unchanged, so all internal RAM stays as in the original game.
;   CoopHudBuild    (bank 9 CODE_099C48, before DEC livesCurrentPos): builds the new row for this job in hudBuf
;                   (jobs 3 and 2 = top row: label, lives, hearts; job 1 = bottom row: score) and queues it.
;                   On the bonus-game screen (D-7b-11) the glyphs are shifted to $40-$4C (the NMI maps the HUD bank
;                   copy chrBonusHud_A_ID there, bank F; the score panel keeps the original 8x16 digits $6A-$7D).
;   CoopHudUpload   (head of CODE_0FE93B, NMI): uploads hudBuf instead of mapBuffer when the queued job is still the
;                   pending one (mapTargetAdr = hudDummy, globalTimer = hudStamp: the first full NMI after that tick);
;                   else the original upload.
;   CoopDrawObjects (head of DrawObjects): the HUD icon (slot OSLOT_ICON) is drawn with objY = HUD_ICON_HIDE_Y, so its
;                   OAM entries get an off-screen Y in place; objY is put back right after DrawObjects.
; Player block (14 tiles at hudBuf + b, b = 0 for P1, HUD_BLOCK for P2):
;   top:    blank blank label 'P' blank 'x' tens units blank heart x5 (blank where no heart)
;   bottom: blank x5, the 7 score digits, blank x2
; 1P: the P2 block is blank. Co-op (7b-2): both blocks, each from its PHYSICAL player's data (native variables if he
; is resident = currentPlayer, else ctxOther_*; his own score digit set), so the blocks stay put after a role exchange.
; A player with 0 lives shows "00" and no hearts (co-op only). Any player's change sets the shared livesCurrentPos
; (not part of the swapped context), and every job redraws its row for both players, so the countdown is unchanged.
; Space: CoopHudBuild is in COOP_CODE2, CoopHudUpload / CoopDrawObjects in COOP_CODE, the block helpers at the end of
; bank 9 (src/bank_09.asm).
; =============================================================================================
.segment "COOP_CODE2"

; CoopHudBuild: A free; X and Y are kept (the caller's RTS path follows). Writes only WRAM (and the stack).
; Bank 9 is mapped (the only caller is CODE_099C48): the block helpers HudPlayerData / HudTop / HudBottom are in bank 9.
CoopHudBuild:
	TXA
	PHA
	TYA
	PHA
	LDX #HUD_ROW_TILES-1
	LDA #HUD_G_BLANK
:	STA hudBuf,X
	DEX
	BPL :-
	LDA mapTargetAdr+1				;the job's high byte already follows the nametable / round-20 rule
	STA hudDummy+1
	STA hudTarget+1
	LDA mapTargetAdr
	STA hudDummy
	LDA globalTimer
	STA hudStamp
	LDA livesCurrentPos				;job: 3 lives, 2 hearts -> top row; 1 score -> bottom row
	CMP #$02
	LDA #HUD_ROW_BOTTOM
	BCC :+
	LDA #HUD_ROW_TOP
:	STA hudTarget
	LDX #$00						;physical P1's block
	TXA
	JSR HudBlock
	LDA coopMode					;(7b-2) co-op: physical P2's block (1P: blank)
	BEQ @tiles
	LDX #HUD_BLOCK
	LDA #$01
	JSR HudBlock
@tiles:
	LDA vNametable					;HUD bank in chrBankB (as DATA_099C54): tiles + $80
	LSR A
	LDA #$00
	ROR A
	STA hudCnt						;tile half
	LDY #$00						;glyph shift
	LDX vNametable
	LDA chrBankA,X					;bonus-game screen (the same test as the NMI's CHR remap, bank F): the
	CMP #chrFans_AA_ID				;HUD bank is mapped as chrBonusHud_A_ID, whose glyphs are at $40-$4C
	BNE @shift
	TXA
	EOR #$01
	TAX
	LDA chrBankA,X
	CMP #chrBonusRoom_A_ID
	BNE @shift
	LDY #HUD_G_DIGIT0-HUD_BONUS_DIGIT0
@shift:
	STY hudTmpA
	LDX #HUD_ROW_TILES-1
@tile:
	LDA hudBuf,X
	CMP #HUD_G_BLANK
	BEQ :+
	SEC
	SBC hudTmpA
:	ORA hudCnt
	STA hudBuf,X
	DEX
	BPL @tile
@queue:
	LDA #$01
	STA hudJob
	PLA
	TAY
	PLA
	TAX
	RTS

.segment "COOP_CODE"

; CoopHudUpload: JMP from the head of CODE_0FE93B (NMI, hudJob != 0). Uploads hudBuf if the queued HUD job is the one
; CODE_0FE93B is about to upload (mapTargetAdr unchanged since CoopHudBuild, first full NMI after that tick), then
; does what the original does after its rows: mapTargetAdr += $20 and CODE_0FE980 (attribute part: ram_03AE is 0 for
; HUD jobs; ColorBufferToVRAM; NMISubRet). Otherwise the original upload runs. hudJob is cleared on both paths.
CoopHudUpload:
	LDA #$00
	STA hudJob
	LDA mapTargetAdr
	CMP hudDummy
	BNE @orig
	LDA mapTargetAdr+1
	CMP hudDummy+1
	BNE @orig
	LDA globalTimer
	CMP hudStamp
	BNE @orig
	LDA PPUSTATUS
	LDA hudTarget+1
	STA PPUADDR
	LDA hudTarget
	STA PPUADDR
	LDX #$00
:	LDA hudBuf,X
	STA PPUDATA
	INX
	CPX #HUD_ROW_TILES
	BNE :-
	LDA mapTargetAdr
	CLC
	ADC #$20
	STA mapTargetAdr
	BCC :+
	INC mapTargetAdr+1
:	JMP CODE_0FE980
@orig:
	JMP HudUploadOrig

; CoopDrawObjects: JMP from the head of DrawObjects. While the HUD icon (slot OSLOT_ICON, animation anJrDoll, set up by
; CODE_059DFB) is active, it is drawn with objY = HUD_ICON_HIDE_Y: its OAM entries keep their place, tile, attributes
; and X, only Y is off screen. objY is put back after DrawObjects; A, X, Y and the flags are DrawObjects' own.
CoopDrawObjects:
	LDA objState+OSLOT_ICON
	BEQ @plain
	LDA objAnim+OSLOT_ICON
	CMP #.LOBYTE(anJrDoll_ID)
	BNE @plain
	LDA objAnimHI+OSLOT_ICON
	CMP #.HIBYTE(anJrDoll_ID)
	BNE @plain
	LDA objY+OSLOT_ICON
	STA hudIconY
	LDA #HUD_ICON_HIDE_Y
	STA objY+OSLOT_ICON
	JSR DrawObjectsBody
	PHP
	STA hudTmpA
	LDA hudIconY
	STA objY+OSLOT_ICON
	LDA hudTmpA
	PLP
	RTS
@plain:
	JMP DrawObjectsBody
