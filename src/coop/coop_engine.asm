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
;   - every COOP_CTX_ARRAYS_DRAW and COOP_CTX_ARRAYS array: slot 0 <-> slot OSLOT_P2
;     (9.2: the P2 window enters at CoopSwap + COOP_SWAP_WIN_OFS, after the DRAW arrays, which stay in place for it)
;   - powerUps: only the bits in COOP_POWERUP_MASK are exchanged with ctxOther_powerUps
;   - coopResident ^= 1; currentPlayer = coopResident ^ coopRoles (the physical id of the new resident;
;     coopRoles = 1 after P1 went out and P2 became the resident player, Phase 7a)
; CoopSwapCtx (Phase 7a) is the same without the object arrays (for flows where the objects do not matter:
; continue, new game, game over). Clobbers A and X; preserves Y; flags undefined. Unrolled (lists in coop.inc).
; (9.2) Entries marked ", eq" in the lists, and the powerUps bits, are compared first and exchanged only when they differ.
; ---------------------------------------------------------------------------------------------
.macro COOP_SWAP_SCALAR name, mode
.ifblank mode
	LDA name
	LDX .ident(.concat("ctxOther_", .string(name)))
	STX name
	STA .ident(.concat("ctxOther_", .string(name)))
.else
	LDA name								;(9.2) usually equal: exchange only when they differ
	CMP .ident(.concat("ctxOther_", .string(name)))
	BEQ :+
	LDX .ident(.concat("ctxOther_", .string(name)))
	STX name
	STA .ident(.concat("ctxOther_", .string(name)))
:
.endif
.endmacro

.macro COOP_SWAP_ARRAY name, mode
.ifblank mode
	LDA name
	LDX name+OSLOT_P2
	STX name
	STA name+OSLOT_P2
.else
	LDA name
	CMP name+OSLOT_P2
	BEQ :+
	LDX name+OSLOT_P2
	STX name
	STA name+OSLOT_P2
:
.endif
.endmacro

CoopSwap:
	COOP_CTX_ARRAYS_DRAW COOP_SWAP_ARRAY
@win:								;(9.2) the P2 window's swaps start here (see COOP_CTX_ARRAYS_DRAW in coop.inc)
	COOP_CTX_ARRAYS COOP_SWAP_ARRAY
COOP_SWAP_WIN_OFS = @win - CoopSwap
CoopSwapCtx:
	COOP_CTX_SCALARS COOP_SWAP_SCALAR

	;powerUps: x = (powerUps ^ shadow) & mask; both bytes ^= x  (bits outside the mask are untouched;
	;the shadow only ever holds mask bits, since it starts at 0 and only gets x bits flipped)
	LDA powerUps
	EOR ctxOther_powerUps
	AND #COOP_POWERUP_MASK
	BEQ :+							;(9.2) x = 0 (most swaps): nothing changes
	TAX
	EOR powerUps
	STA powerUps
	TXA
	EOR ctxOther_powerUps
	STA ctxOther_powerUps
:

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
	LDA coopShotSwapped				;shot bytes back with their owners before the swap (Phase 5; CoopShotRestore inline)
	BEQ :+
	JSR CoopShotExchange
:
	LDA prgBankB					;the caller's $A000 bank, restored below
	PHA
	JSR CoopSwap+COOP_SWAP_WIN_OFS	;P2 resident: context, slot 0 <-> OSLOT_P2 (9.2: not the DRAW arrays), currentPlayer = 1
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
	JSR CoopSwapOut					;(9.5) the swap back; A = COOP_P2_OUT: P2 may borrow a life from P1 (CoopBorrowTick)
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
	JSR CoopSwap+COOP_SWAP_WIN_OFS	;P1 resident again (coopResident = 0, currentPlayer = 0)
@restore:
CoopBankRestore:					;(9.5) also the end of CoopBorrowTick: $A000 := the bank on the stack (A = it)
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
	DEX
	STX coopTouchSkip				;(9.2) $FF: no bubble skipped since the last CODE_098932 call
	INX
@slot:
	LDA objState+OSLOT_BUBBLE,X
	BEQ @next
	CMP #BUBBLE_POWER+1
	BCS @next						;states >= 6 (and $80+) do not reach CODE_098149
	CPX coopP2SkipSlot
	BEQ @next
	;(9.2) CODE_098932 returns at once when |player X - bubble X| >= 16 (90 % of the calls), after it has set
	;scratch2/3/6/7 only: that test is made here and the call skipped; the scratch bytes of the last bubble tested
	;are rebuilt after the loop (@skipped), so the end state is the same as with every call made.
	LDA objX						;P2's X (resident)
	SEC
	SBC objX+OSLOT_BUBBLE,X
	BCS :+
	EOR #$FF
	ADC #$01						;(C = 0 here)
:	CMP #$10
	BCC @call
	STX coopTouchSkip
	BCS @next						;(always)
@call:
	LDA #$FF
	STA coopTouchSkip
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
	CPX #BUBBLE_SLOTS-1				;(9.2) = bubbleSlotEnd while P2 is in the round (the only time this runs)
	BNE @slot
	LDX coopTouchSkip
	BPL @skipped
	RTS
@skipped:
	;the last bubble tested was skipped: scratch2-7 as CODE_098149 / CODE_098932 leave them on that early return
	LDA objX+OSLOT_BUBBLE,X
	STA scratch4
	LDA objY+OSLOT_BUBBLE,X
	STA scratch5
	LDA objY
	CLC
	ADC #$02
	STA scratch3
	LDA objX
	STA scratch2
	LDY #$01						;scratch6 = 1, + 1 when player X >= bubble X
	CMP scratch4
	BCC :+
	INY
:	STY scratch6
	LDA #$00
	STA scratch7
	LDX #BUBBLE_SLOTS-1				;X as the loop leaves it
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
	LDA ctxOther_shooting			;(9.2) the most frequent exit first (the three tests only decide "return")
	BEQ @rts
	LDA ram_00CA
	BEQ @rts						;as CODE_0FF9E8: state 0 is never tested
	BMI @rts						;already flagged (the native shot hit, or bit 7 was set before)
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
	LDA ctxOther_playerLives		;(7a) the other player is out (no lives left): not spawned; (9.5) he may borrow a
	BNE :+							;life from the resident in this round: coopP2Active = COOP_P2_OUT, request unarmed,
	LDA #COOP_P2_START_X			;and physical P2's spot is the default (he did not start this round)
	STA coopP2StartX
	LDA #COOP_P2_OUT
	STA coopP2Active
	STA coopBorrowReq
	RTS
:	LDA #.BANK(CODE_0884AB)			;the caller's bank stays at $8000
	JSR CoopInitOther				;(9.5) moved to PRG-RAM (shared with the rejoin)
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
	STA coopP2StartX				;(9.5) physical P2's spot (with exchanged roles the resident is P2 and also started at
	LDA #.LOBYTE(anPlayerL_ID)		;$1F, so the value is the mirror of P1's start either way)
; CoopSpawnAt (9.5): the rest of the spawn, also used by a rejoin (CoopBorrowTick). A = objAnim (anPlayerL_ID or
; anPlayerR_ID), objX / objY of OSLOT_P2 already set. Clobbers A/X/Y.
CoopSpawnAt:
	STA objAnim+OSLOT_P2
	LDA #$01
	STA objState+OSLOT_P2
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
	JMP CoopAnimateP2				;load the first frame of objAnim
.assert .HIBYTE(anPlayerL_ID) = 0 && .HIBYTE(anPlayerR_ID) = 0, error, "CoopSpawnAt: player anims need high byte 0"

; (9.5) CoopSwapOut: the P2 window's swap back when P2 is out (A = COOP_P2_OUT for CoopP2Deactivate). CoopP2DeactOut: the
; same for CoopResidentOut's role exchange. Clobber A/X (as CoopSwap / CoopP2Deactivate).
CoopSwapOut:
	JSR CoopSwap+COOP_SWAP_WIN_OFS
	LDA #COOP_P2_OUT
	RTS
CoopP2DeactOut:
	LDA #COOP_P2_OUT
	BNE CoopP2Deactivate
.assert COOP_P2_OUT = COOP_BORROW_UNARMED, error, "CoopP2Deactivate stores one value into coopP2Active and coopBorrowReq"
; (9.5) layout: the routines from CoopNewGame on keep their p94c addresses (page crossings of the hot co-op code)
COOP_95_PAD = 194 - (* - CoopRoundStartP2) - 54		;54 = CoopDespawnAll + CoopP2Deactivate (asserted at CoopNewGame)
.assert COOP_95_PAD >= 0, error, "CoopRoundStartP2 .. CoopP2Deactivate grew past its p94c length"
	.res COOP_95_PAD, $FF

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
CoopP2Deactivate:					;(9.5) A = the new coopP2Active and coopBorrowReq: 0 (CoopDespawnAll falls in with A = 0),
	STA coopP2Active				;or COOP_P2_OUT = COOP_BORROW_UNARMED (CoopSwapOut / CoopP2DeactOut: out, may borrow)
	STA coopBorrowReq
	JSR CoopShotRestore
	JSR CoopForRestore				;(9.1) a sprite slot lent for the last DrawObjects call gets its bank back
	LDA #$00
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
.assert * - CoopRoundStartP2 = 194, error, "(9.5) CoopNewGame must keep its p94c offset from CoopRoundStartP2"
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

; CoopDrawCoop (9.2): RoundUpdate's draw while P2 is in the round (bank 9, instead of CoopP2BlinkHide / DrawObjects /
; CoopP2BlinkRestore): P2's invincibility blink hides slot OSLOT_P2 for the call when ctxOther_playerInvFrames & 2
; (RoundUpdate does the same for slot 0 with playerInvFrames), then CoopDrawPair, then objState of OSLOT_P2 back.
; Clobbers A/X/Y and the flags (RoundUpdate reloads A right after). In bank E, not PRG-RAM: it writes objState of
; OSLOT_P2, and the Phase 6 checker accepts that only from the bank-E co-op code (as for CoopP2BlinkHide before).
CoopDrawCoop:
	LDA objState+OSLOT_P2
	STA coopP2SavedState
	LDA ctxOther_playerInvFrames
	AND #$02
	BEQ :+
	LDA #$00
	STA objState+OSLOT_P2
:	JSR CoopDrawPair
	LDA coopP2SavedState
	STA objState+OSLOT_P2
	RTS

; CoopP2ObjHide / CoopP2ObjShow (9.3): slot OSLOT_P2's objState to 0 and back around DrawObjectsBody's even scan after
; CoopDrawBodyC has drawn P2 first (here in bank E: the Phase 6 checker accepts slot-39 objState writes only from the
; bank-E co-op code). Clobber A.
CoopP2ObjHide:
	LDA objState+OSLOT_P2
	STA coopDrawSave
	LDA #$00
	STA objState+OSLOT_P2
	RTS
CoopP2ObjShow:
	LDA coopDrawSave
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
; X = enemy index (kept), Y kept. (9.2) CoopNearest's rule inline (same result: |dx| + |dy| from the enemy, 9 bits, P2
; only if strictly nearer; a dying player is not targetable; neither: coopTarget kept), without Y, coopPos or a JSR.
CoopSelectTarget:
	LDA playerState
	CMP #PLAYER_STATE_DEAD
	BEQ @p1out
	LDA ctxOther_playerState
	CMP #PLAYER_STATE_DEAD
	BEQ @t0							;P1 only
	LDA objX+OSLOT_ENEMY,X			;both: slot 0's distance (9 bits) in coopDist / coopDist+1
	SEC
	SBC objX
	BCS :+
	EOR #$FF
	ADC #$01						;(C = 0 here)
:	STA coopDist
	LDA objY+OSLOT_ENEMY,X
	SEC
	SBC objY
	BCS :+
	EOR #$FF
	ADC #$01
:	CLC
	ADC coopDist
	STA coopDist
	LDA #$00
	ROL A
	STA coopDist+1
	LDA objX+OSLOT_ENEMY,X			;slot OSLOT_P2's: lo in coopDist+2, hi in A
	SEC
	SBC objX+OSLOT_P2
	BCS :+
	EOR #$FF
	ADC #$01
:	STA coopDist+2
	LDA objY+OSLOT_ENEMY,X
	SEC
	SBC objY+OSLOT_P2
	BCS :+
	EOR #$FF
	ADC #$01
:	CLC
	ADC coopDist+2
	STA coopDist+2
	LDA #$00
	ROL A
	CMP coopDist+1
	BCC @t1							;hi below
	BNE @t0							;hi above
	LDA coopDist+2
	CMP coopDist
	BCC @t1							;lo below (equal: slot 0)
@t0:
	LDA #$00
	STA coopTarget
	LDA objX
	STA targetX
	LDA objY
	STA targetY
	RTS
@p1out:
	LDA ctxOther_playerState
	CMP #PLAYER_STATE_DEAD
	BNE @t1							;P2 only
	LDA coopTarget					;nobody targetable: keep the previous target
	BEQ @t0
@t1:
	LDA #$01
	STA coopTarget
	LDA objX+OSLOT_P2
	STA targetX
	LDA objY+OSLOT_P2
	STA targetY
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
	JSR CoopP2DeactOut				;the out player (now in ctxOther / slot OSLOT_P2) leaves the round; (9.5) he may borrow
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
; (9.5) CoopTickOther: the RoundUpdate hook (LDA coopP2Active / BEQ / JSR, N = bit 7 of coopP2Active on entry):
; $80 -> CoopExtraLifeOther, COOP_P2_OUT -> CoopBorrowTick (PRG-RAM).
CoopTickOther:
	BPL CoopTickBorrow
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
CoopTickBorrow:
	JMP CoopBorrowTick

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
; Space: the block helpers are at the end of bank 9 (src/bank_09.asm); CoopHudBuild / CoopHudUpload / CoopDrawObjects run
; from PRG-RAM since 9.2 (COOP_WRAM_CODE, with the Phase 9.1 / 9.2 draw code).
; =============================================================================================
; =============================================================================================
; Phase 7b-3: either pad continues, team bonuses (COOP_CODE2).
; =============================================================================================
.segment "COOP_CODE2"

; CoopPadsPressed (bank 5, game-over / continue screen CODE_058C9D and CODE_058CB3; replaces LDA pressedP1): A =
; pressedP1, or pressedP1 | pressedP2 in co-op (either player may continue). X/Y kept; the caller ANDs next.
CoopPadsPressed:
	LDA coopMode
	BEQ :+
	LDA pressedP2
:	ORA pressedP1
	RTS

; CoopAddScoreTeam (replaces JSR AddScore at the three team-bonus sites: boss defeated, bank 8 CODE_08928E; round-clear
; bonus, bank B CODE_0B82D0; boss bonus-game prize BONUS 100000, bank 7 CODE_079C10): in co-op every player who is not
; out gets the full award (the resident via AddScore for currentPlayer, the other one via CoopAddScoreAs; each one's
; extra-life accumulator counts it). "Not out" = the other player's lives byte (ctxOther_playerLives, whichever
; physical player that is) is non-zero: it also covers the bonus game, where P2 is not spawned (coopP2Active = 0) but
; still in the game. 1P (coopMode 0) and a game with the other player out: plain AddScore. Clobbers A/X/Y; the stack
; use is that of AddScore (the caller's return address is the only extra frame).
CoopAddScoreTeam:
	LDA coopMode
	BEQ @one
	LDA ctxOther_playerLives
	BEQ @one
	LDX #SCORE_TOTAL_DIGITS-1
:	LDA scoreAdditionDigits,X
	STA coopTeamDigits,X
	DEX
	BPL :-
	JSR AddScore					;the resident (currentPlayer); clears scoreAdditionDigits
	LDX #SCORE_TOTAL_DIGITS-1
:	LDA coopTeamDigits,X
	STA scoreAdditionDigits,X
	DEX
	BPL :-
	LDA currentPlayer				;and the other player
	EOR #$01
	JMP CoopAddScoreAs
@one:
	JMP AddScore

; =============================================================================================
; Phase 8: round 20 (the only wide round: wideRound, camera CODE_0788CC, IRQ effect 5) with both players in the round.
; See docs/coop_notes.md, Phase 8. Every routine here runs only while coopP2Active (the hooks gate with BIT / BPL);
; 1P and a game with one player out keep the original code.
;   camera     CoopCamera (from CODE_0788CC, before P1's update): either player pushes the camera (the 1P rule per
;              player: LEFT at X < 80, RIGHT at X >= 176). Opposite pushes: no scroll. A scroll is made only if the
;              player(s) who do not push stay within [COOP_EDGE_L, COOP_EDGE_R] after it (the leash). The pusher holds
;              still on screen (CODE_0594EB / CoopMoveX, as P1 in 1P); the other player moves with the world, exactly
;              COOP_CAM_STEP px per scrolled tick (the even-tick object shifter CODE_0FFD89 skips P2's slot).
;   edges      CoopMoveX (bank 5): an X step past the screen edges is not taken.
;   Ruckus     CoopRuckusWrap (CODE_08882A): both players get the top clamp and the fall-through exit.
;   respawn    CODE_0595C1 / CoopRespawnX (bank 5): no camera reset; X relative to the camera.
; (Phase 9.0) CoopCamera / CoopCamWant / CoopCamLeash (were bank 5, reached through the nested bank call CoopRunB5, now
; removed) and CoopRuckusWrap (was bank F) run from PRG-RAM: segment COOP_WRAM_CODE, see coop.inc and CoopBoot.
; =============================================================================================
.segment "COOP_WRAM_CODE"

; CoopCamera: JMP from CODE_0788CC (bank 7; every RoundUpdate tick of round 20, P1 resident). Inputs are the
; players' playerHeld of their last update (as for the 1P camera). Writes wideScrollDir, wideHScroll, coopCamHold,
; coopCamWant and the X of a player who does not push. Clobbers A/X/Y.
CoopCamera:
	LDA #$00
	STA wideScrollDir
	STA coopCamHold
	LDA playerHeld
	LDX objX
	LDY playerState
	JSR CoopCamWant
	STA coopCamWant
	LDA ctxOther_playerHeld
	LDX objX+OSLOT_P2
	LDY ctxOther_playerState
	JSR CoopCamWant
	STA coopCamWant+1
	ORA coopCamWant
	BEQ @rts						;nobody pushes
	CMP #DIR_LEFT|DIR_RIGHT
	BEQ @rts						;opposite pushes: the camera stalls
	TAY								;Y = direction
	LDA coopCamWant					;the leash: a player who does not push must stay on screen
	BNE :+
	LDX objX
	JSR CoopCamLeash
	BCS @rts
:	LDA coopCamWant+1
	BNE :+
	LDX objX+OSLOT_P2
	JSR CoopCamLeash
	BCS @rts
:	LDA wideHScroll
	CPY #DIR_LEFT
	BNE @right
	CMP #$01						;as WideScrollLeft: the left end
	BEQ @rts
	SBC #COOP_CAM_STEP				;(C = 1)
	LDX #COOP_CAM_STEP				;the world moves right on screen
	BNE @scroll
@right:
	CMP #$FF						;as WideScrollRight: the right end
	BEQ @rts
	ADC #COOP_CAM_STEP				;(C = 0)
	LDX #<(-COOP_CAM_STEP)
@scroll:
	STA wideHScroll
	STY wideScrollDir
	STX coopCamTmp					;the shift of a player who does not push
	LDA coopCamWant
	BEQ :+
	INC coopCamHold					;bit 0: the slot-0 player pushed (holds still)
	BNE @p2
:	LDA objX
	CLC
	ADC coopCamTmp
	STA objX
@p2:
	LDA coopCamWant+1
	BEQ :+
	LDA coopCamHold
	ORA #$02						;bit 1: the OSLOT_P2 player pushed
	STA coopCamHold
	RTS
:	LDA objX+OSLOT_P2
	CLC
	ADC coopCamTmp
	STA objX+OSLOT_P2
@rts:
	RTS

; CoopCamWant: A = playerHeld, X = screen X, Y = playerState of one player. Out: A = DIR_LEFT / DIR_RIGHT if he pushes
; the camera (the 1P rule of CODE_0788CC; a dying player does not push), else 0.
CoopCamWant:
	CPY #PLAYER_STATE_DEAD
	BEQ @no
	AND #KEY_LEFT|KEY_RIGHT
	BEQ @rts
	CMP #KEY_RIGHT
	BEQ @r
	CPX #COOP_CAM_LZONE				;LEFT (or both, as CODE_0788CC)
	BCS @no
	LDA #DIR_LEFT
	RTS
@r:	CPX #COOP_CAM_RZONE
	BCC @no
	LDA #DIR_RIGHT
	RTS
@no:
	LDA #$00
@rts:
	RTS

; CoopCamLeash: X = screen X of a player who does not push, Y = scroll direction. Out: C = 1 if the scroll would move
; him past a screen edge (left scroll: X + step > COOP_EDGE_R; right scroll: X - step < COOP_EDGE_L).
CoopCamLeash:
	CPY #DIR_LEFT
	BNE @r
	CPX #COOP_EDGE_R-COOP_CAM_STEP+1
	RTS
@r:	TXA
	EOR #$FF						;X <= COOP_EDGE_L+step-1  <=>  ~X >= 256-(COOP_EDGE_L+step)
	CMP #<(256-(COOP_EDGE_L+COOP_CAM_STEP))
	RTS

; ---------------------------------------------------------------------------------------------
; CoopRuckusWrap (COOP_WRAM_CODE since Phase 9.0): JMP from CODE_08882A (Ruckus, round 20 boss; enemy AI, even tick, bank 8 at $8000, P1 resident) while
; both players are in the round; the 1P code there clamps P1 at the top (Y < 8 -> 8) and sends a P1 who fell through
; the floor (Y >= $E8) to the exit: Y 0, X $A0, camera $FF (the right end), bubbles and item to Y 0 (CODE_088AA2).
; Here each player (slot 0, then OSLOT_P2) gets the same: the top clamp, and on a fall the exit, with the camera moved
; right only as far as the partner stays on screen (partner X - move >= COOP_EDGE_L; the partner moves with the world)
; and the faller at the exit's screen X ($A0 + $FF - camera), at most COOP_EDGE_R. A dying faller does not move the
; camera. CODE_088AA2 runs when the camera moved, with P2's Y kept (it clears slots 18 and 20-39, 39 = P2).
; Keeps X (the enemy index); continues at CODE_088857.
; ---------------------------------------------------------------------------------------------
CoopRuckusWrap:
	TXA
	PHA
	LDX #$00
	JSR @one
	LDX #OSLOT_P2
	JSR @one
	PLA
	TAX
	JMP CODE_088857
@one:
	LDA objY,X
	CMP #$08
	BCS :+
	LDA #$08
	STA objY,X
:	CMP #$E8
	BCC @rts
	LDA #$00						;fell through the floor
	STA objY,X
	LDY #OSLOT_P2					;Y = the partner's slot, A = the faller's state
	LDA playerState
	CPX #$00
	BEQ :+
	LDY #$00
	LDA ctxOther_playerState
:	CMP #PLAYER_STATE_DEAD
	BEQ @land						;a dying player does not move the camera
	LDA objX,Y						;move = min($FF - camera, partner X - COOP_EDGE_L), even
	SEC
	SBC #COOP_EDGE_L
	BCC @land
	STA coopCamTmp
	LDA #$FF
	SBC wideHScroll					;(C = 1)
	CMP coopCamTmp
	BCS :+
	STA coopCamTmp
:	LDA coopCamTmp
	AND #$FE						;(wideHScroll stays odd)
	BEQ @land
	STA coopCamTmp
	CLC
	ADC wideHScroll
	STA wideHScroll
	LDA objX,Y						;the partner keeps his place in the world
	SEC
	SBC coopCamTmp
	STA objX,Y
	LDA objY+OSLOT_P2
	PHA
	JSR CODE_088AA2					;bubbles and the item to Y 0, as in 1P (keeps X and Y)
	PLA
	STA objY+OSLOT_P2				;but not P2
@land:
	LDA #$FF						;X = $A0 + ($FF - camera), at most COOP_EDGE_R
	SEC
	SBC wideHScroll
	CLC
	ADC #$A0
	BCS :+
	CMP #COOP_EDGE_R+1
	BCC :++
:	LDA #COOP_EDGE_R
:	STA objX,X
@rts:
	RTS

; CoopHudBuild (9.2: runs from PRG-RAM, was COOP_CODE2): A free; X and Y are kept (the caller's RTS path follows). Writes only WRAM (and the stack).
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
	TYA
	BNE @shiftpass					;(9.2) bonus-game screen only: glyph shift
	LDA hudCnt
	BEQ @queue						;(9.2) no shift and the lower tile half: the tiles are final
	LDX #HUD_ROW_TILES-1
:	LDA hudBuf,X					;(9.2) no shift: every tile (blank too) gets the half bit only
	ORA hudCnt
	STA hudBuf,X
	DEX
	BPL :-
	BMI @queue						;(always)
@shiftpass:
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

; CoopHudUpload (9.2: runs from PRG-RAM, was COOP_CODE; the row copy is unrolled): JMP from the head of CODE_0FE93B (NMI,
; hudJob != 0). Uploads hudBuf if the queued HUD job is the one CODE_0FE93B is about to upload (mapTargetAdr unchanged
; since CoopHudBuild, first full NMI after that tick), then does what the original does after its rows: mapTargetAdr +=
; $20 and CODE_0FE980 (attribute part: ram_03AE is 0 for HUD jobs; ColorBufferToVRAM; NMISubRet). Otherwise the
; original upload runs. hudJob is cleared on both paths. (Ends with X = HUD_ROW_TILES, as the loop it replaces.)
CoopHudUploadOrig:
	JMP HudUploadOrig
CoopHudUpload:
	LDA #$00
	STA hudJob
	LDA mapTargetAdr
	CMP hudDummy
	BNE CoopHudUploadOrig
	LDA mapTargetAdr+1
	CMP hudDummy+1
	BNE CoopHudUploadOrig
	LDA globalTimer
	CMP hudStamp
	BNE CoopHudUploadOrig
	LDA PPUSTATUS
	LDA hudTarget+1
	STA PPUADDR
	LDA hudTarget
	STA PPUADDR
.repeat HUD_ROW_TILES, I
	LDA hudBuf+I
	STA PPUDATA
.endrepeat
	LDX #HUD_ROW_TILES
	LDA mapTargetAdr
	CLC
	ADC #$20
	STA mapTargetAdr
	BCC :+
	INC mapTargetAdr+1
:	JMP CODE_0FE980

; =============================================================================================
; Phase 9.1: both players' sprites from one CHR KB (COOP_WRAM_CODE; docs/coop_notes.md, Phase 9.1).
; Both players use sprite CHR slot 0 (chrBankC), whose bank DrawObjects takes from the last drawn object, so a player
; whose frame bank differs from the other's was drawn with the other's tiles. A player frame = (objChrBank $40-$4F,
; image block A/B/C/D: 12 tiles at $00/$06/$20/$26). The pair banks (src/chr/CoopPairs.chr, ids $80-$97, $9A-$FF) hold
; the bubbles plus 4 frames each, one per block position; every two of the 40 frames (points of PG(3,3)) share one bank
; (coop_pairtab.inc; banks $40-$43 are 4 of them). CoopDrawPair gives both players that bank for this DrawObjects call
; and, for a player whose frame is not at its home block there, an image copy with the tile numbers shifted (the
; "image table entry" objImgOfs points to is in WRAM: $A000 + objImgOfs wraps to coopImgEnt). The players' objChrBank /
; objImgOfs are put back after DrawObjects. 1P and P2 out: not reached (CoopDrawObjects tests coopP2Active).
; Uses scratch0-5, 8, 9 only (DrawObjects clobbers them anyway; bank 9 keeps scratch6 across DrawObjects).
; (9.2) Same results, cheaper: no wrapper when no pair bank is needed (tail jump), the restore needs no PHP/PLP (every
; DrawObjectsBody exit leaves X = 0, Z = 1, N = 0, C = 1, so LDX / STX and a final LDX #0 rebuild it exactly; A and Y are
; DrawObjects' own), the redirected objImgOfs are put back from the memo key (= their values at entry), the frame point
; lookup is inline, and CoopPairShift only refreshes the image copy (the redirect is written in one place, CoopDrawPairResult).
; =============================================================================================

; CoopDrawObjects: JMP from the head of DrawObjects (every caller but RoundUpdate, which calls CoopDrawCoop /
; CoopDrawObjects1P itself since 9.2). With P2 in the round CoopDrawPair, else CoopDrawObjects1P.
CoopDrawObjects:
	BIT coopP2Active
	BMI CoopDrawPair
; CoopDrawObjects1P (7b-1): while the HUD icon (slot OSLOT_ICON, animation anJrDoll, set up by CODE_059DFB) is active, it
; is drawn with objY = HUD_ICON_HIDE_Y: its OAM entries keep their place, tile, attributes and X, only Y is off screen.
; objY is put back after DrawObjectsBody; A, X, Y and the flags are DrawObjects' own (X = 0, Z = 1, N = 0, C = 1 on every
; exit of DrawObjectsBody, so LDX / STX / LDX #0 keep them; V is not read by anything).
CoopDrawObjects1P:
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
	LDX hudIconY
	STX objY+OSLOT_ICON
	LDX #$00
	RTS
@plain:
	JMP DrawObjectsBody

; CoopForRestore: a sprite slot lent by CoopForeignSlot in the last DrawObjects call gets its bank back (unless the game
; rewrote it since). From CoopDrawPair and CoopP2Deactivate. Keeps X/Y.
CoopForRestore:
	LDA coopForSlot
	BEQ @rts
	TXA
	PHA
	LDX coopForSlot
	LDA chrBankC,X
	CMP coopForVal
	BNE :+
	LDA coopForOld
	STA chrBankC,X
:	LDA #$00
	STA coopForSlot
	PLA
	TAX
@rts:
	RTS

; CoopDrawPair: DrawObjects with P2 in the round. Memo: if the 7 inputs (both objChrBank, objImgOfs, objImgOfsHI, and
; sprPrgBank) equal the last computed call's, its result coopMemoOn is reused: 0 = no pair bank (draw as is), else
; bit 0 = chrBankC := coopPairBank after DrawObjects, bit 1 / 2 = P1's / P2's objImgOfs points at his coopImgBuf (the
; image copy is still valid: it only changes in CoopPairShift).
CoopDrawPlain:							;(trampolines within branch range of CoopDrawPair's tests)
	JMP CoopDrawObjectsC
CoopDrawMiss:
	JMP CoopDrawPairMiss
CoopDrawPair:
	LDA coopForSlot
	BEQ :+
	JSR CoopForRestore
:	LDA objState						;both players drawn? (blink hides set objState 0 here)
	BEQ CoopDrawPlain
	LDA objState+OSLOT_P2
	BEQ CoopDrawPlain
	LDA objChrBank
	CMP objChrBank+OSLOT_P2
	BEQ CoopDrawPlain							;one bank: both frames are in it
	CMP coopMemoKey
	BNE CoopDrawMiss
	LDA objChrBank+OSLOT_P2
	CMP coopMemoKey+1
	BNE CoopDrawMiss
	LDA objImgOfs
	CMP coopMemoKey+2
	BNE CoopDrawMiss
	LDA objImgOfs+OSLOT_P2
	CMP coopMemoKey+3
	BNE CoopDrawMiss
	LDA objImgOfsHI
	CMP coopMemoKey+4
	BNE CoopDrawMiss
	LDA objImgOfsHI+OSLOT_P2
	CMP coopMemoKey+5
	BNE CoopDrawMiss
	LDA sprPrgBank
	CMP coopMemoKey+6
	BNE CoopDrawMiss
CoopDrawPairResult:
	LDA coopMemoOn
	BEQ @plain
	LSR
	BEQ @bank							;1: both frames at their home block in the pair bank
	LSR
	BCC :+
	LDX #<coopImgEnt					;P1's image from his coopImgBuf (DrawObjects reads $A000 + objImgOfs)
	STX objImgOfs
	LDX #>(coopImgEnt-$A000)
	STX objImgOfsHI
:	LSR
	BCC :+
	LDX #<(coopImgEnt+2)				;P2's
	STX objImgOfs+OSLOT_P2
	LDX #>(coopImgEnt+2-$A000)
	STX objImgOfsHI+OSLOT_P2
:	JSR CoopDrawObjectsC
	LDX coopPairBank					;both players' frames are in this KB; the bubbles are in every player KB
	STX chrBankC
	LDX coopMemoKey+2					;objImgOfs / HI back (the memo key holds their values at entry)
	STX objImgOfs
	LDX coopMemoKey+4
	STX objImgOfsHI
	LDX coopMemoKey+3
	STX objImgOfs+OSLOT_P2
	LDX coopMemoKey+5
	STX objImgOfsHI+OSLOT_P2
	LDX #$00							;DrawObjects' exit: X = 0, Z = 1, N = 0 (C = 1 untouched)
	RTS
@bank:
	JSR CoopDrawObjectsC
	LDX coopPairBank
	STX chrBankC
	LDX #$00
	RTS
@plain:
	JMP CoopDrawObjectsC

; CoopDrawPairMiss: the memo did not match: compute the pair bank, the positions and the image copies, then the common
; draw (CoopDrawPairResult).
CoopDrawPairMiss:
	LDA objChrBank						;both banks $40-$4F: the pair banks
	SEC
	SBC #chrPlayer_A_ID
	CMP #$10
	BCS @foreign
	ASL
	ASL
	STA scratch0						;P1: (bank - $40) * 4
	LDA objChrBank+OSLOT_P2
	SEC
	SBC #chrPlayer_A_ID
	CMP #$10
	BCS @foreign
	ASL
	ASL
	STA scratch1						;P2
	LDA objChrBank
	STA coopMemoKey
	LDA objChrBank+OSLOT_P2
	STA coopMemoKey+1
	LDA objImgOfs
	STA coopMemoKey+2
	LDA objImgOfs+OSLOT_P2
	STA coopMemoKey+3
	LDA objImgOfsHI
	STA coopMemoKey+4
	LDA objImgOfsHI+OSLOT_P2
	STA coopMemoKey+5
	LDA sprPrgBank
	STA coopMemoKey+6
	LDA #$00
	STA coopMemoOn
	BEQ @p1							;(always)
@foreign:
	JMP CoopDrawForeign
@plain:
	JMP CoopDrawObjectsC
@p1:
	;frame point of P1 (slot 0): CHR slot 0, image block from objImgOfs, point from (bank, block)
	LDA objChrSlot
	BNE @plain
	LDA objImgOfsHI
	BNE @p1slow
	LDA objImgOfs
	CMP #$20
	BCS @p1slow
	LSR
	TAY
	LDA CoopImgBlk,Y
	BMI @plain
@p1blk:
	STA coopPairBlk
	ORA scratch0
	TAY
	LDA CoopFrmIdx,Y
	CMP #40
	BCS @plain
	STA coopPairPt
	;frame point of P2 (slot OSLOT_P2)
	LDA objChrSlot+OSLOT_P2
	BNE @plain
	LDA objImgOfsHI+OSLOT_P2
	BNE @p2slow
	LDA objImgOfs+OSLOT_P2
	CMP #$20
	BCS @p2slow
	LSR
	TAY
	LDA CoopImgBlk,Y
	BMI @plain
@p2blk:
	STA coopPairBlk+1
	ORA scratch1
	TAY
	LDA CoopFrmIdx,Y
	CMP #40
	BCS @plain
	STA coopPairPt+1
	CMP coopPairPt
	BNE @pair
	TAX									;same frame content (47C = 40D): its home
	LDA CoopPtBank,X
	STA coopPairBank
	LDA CoopPtPos,X
	STA coopPairPos
	STA coopPairPos+1
	JMP @apply
@p1slow:
	LDX #$00
	JSR CoopImgBlkSlow
	BCC @p1blk
	JMP @plain
@p2slow:
	LDX #OSLOT_P2
	JSR CoopImgBlkSlow
	BCC @p2blk
	JMP @plain
@pair:
	LDX coopPairPt						;X = the higher point, Y = the lower one (C = 1: P2's point is the higher)
	LDY coopPairPt+1
	BCC :+
	LDX coopPairPt+1
	LDY coopPairPt
:	CLC
	LDA CoopTriLo,X
	ADC #<CoopPairBank
	STA scratch0
	LDA CoopTriHi,X
	ADC #>CoopPairBank
	STA scratch1
	LDA (scratch0),Y
	STA coopPairBank
	LDA scratch0						;the same entry of CoopPairPos
	CLC
	ADC #<(CoopPairPos-CoopPairBank)
	STA scratch0
	LDA scratch1
	ADC #>(CoopPairPos-CoopPairBank)
	STA scratch1
	LDA (scratch0),Y					;bits 0-1: position of the lower point, bits 2-3: of the higher one
	CPX coopPairPt
	BEQ :+
	TAX									;P1 has the lower point
	AND #$03
	STA coopPairPos
	TXA
	LSR
	LSR
	STA coopPairPos+1
	JMP @apply
:	TAX									;P1 has the higher point
	AND #$03
	STA coopPairPos+1
	TXA
	LSR
	LSR
	STA coopPairPos
@apply:
	LDA #$01							;bit 0: the pair bank goes to chrBankC after DrawObjects
	STA coopMemoOn
	LDX coopPairPos						;P1: tile shift = position base - home base (0: at home, the bank alone)
	LDA CoopBlkBase,X
	LDX coopPairBlk
	SEC
	SBC CoopBlkBase,X
	BEQ :+
	LDX #$00
	LDY #$00
	JSR CoopPairShift
:	LDX coopPairPos+1					;P2
	LDA CoopBlkBase,X
	LDX coopPairBlk+1
	SEC
	SBC CoopBlkBase,X
	BEQ :+
	LDX #OSLOT_P2
	LDY #$01
	JSR CoopPairShift
:	JMP CoopDrawPairResult

; CoopDrawForeign: a player bank outside $40-$4F (see CoopForeignSlot).
CoopDrawForeign:
	LDA #$00							;a player shown from another bank (bank $5B, anim $A5 while stuck): drawn
	STA coopPairFor						;from a sprite slot 1-3 that holds it or is free, else without a bank
	LDX #$00
	JSR CoopForeignSlot
	LDX #OSLOT_P2
	JSR CoopForeignSlot
	JSR CoopDrawObjectsC
	PHP
	STA coopPairA
	LDA coopPairFor
	BEQ @ret
	LSR
	BCC :+
	LDA #$00
	STA objChrSlot
:	LDA coopPairFor
	AND #$02
	BEQ :+
	LDA #$00
	STA objChrSlot+OSLOT_P2
:	LDA coopPairFor
	AND #$04
	BEQ :+
	LDA coopMuteSave
	STA objChrBank
:	LDA coopPairFor
	AND #$08
	BEQ @ret
	LDA coopMuteSave+1
	STA objChrBank+OSLOT_P2
@ret:
	LDA coopPairA
	PLP
	RTS

; CoopForeignSlot: X = slot (0 / OSLOT_P2). A player in CHR slot 0 with a bank outside $40-$4F that one of the sprite
; slots 1-3 already holds (chrBankD-F) is drawn from that slot (objChrSlot, put back to 0 after DrawObjects; bit 0 / 1
; of coopPairFor). If no slot holds it, a slot 1-3 that no other drawn object uses is lent for this call: DrawObjects
; writes the bank to its chrBankD-F (shown by the next NMI); CoopForRestore puts the old value back at the next call
; (coopForSlot / coopForOld / coopForVal). Clobbers A, Y, scratch4/5.
CoopForeignSlot:
	LDA objChrSlot,X
	BNE @rts
	LDA objChrBank,X
	BEQ @rts
	SEC
	SBC #chrPlayer_A_ID
	CMP #$10
	BCC @rts
	LDA objChrBank,X
	LDY #$03
@slot:
	CMP chrBankC,Y
	BEQ @hit
	DEY
	BNE @slot
	LDA coopForSlot						;no slot holds it: lend a slot that no other drawn object uses (once per call)
	BNE @mute
	STX scratch4
	LDA #$0E							;bits 1-3: slots 1-3 still free
	STA scratch5
	LDY #39
@obj:
	CPY scratch4
	BEQ @next							;the player himself
	CPY #OSLOT_ICON
	BEQ @next							;the HUD icon is drawn off screen
	LDA objState,Y
	BEQ @next
	LDX objChrSlot,Y
	LDA CoopSlotBit,X
	EOR #$FF
	AND scratch5
	STA scratch5
@next:
	DEY
	BPL @obj
	LDX scratch4
	LDY #$03
@free:
	LDA CoopSlotBit,Y
	AND scratch5
	BNE @lend
	DEY
	BNE @free
@mute:
	LDA objChrBank,X						;no slot at all: he is drawn without setting chrBankC (objChrBank 0, put back
	CPX #$00							;after DrawObjects; bit 2 / 3 of coopPairFor), so the other player's frame
	BNE :+								;is always right (this one shows the other's bank, as in the original)
	STA coopMuteSave
	LDA #$04
	BNE :++
:	STA coopMuteSave+1
	LDA #$08
:	ORA coopPairFor
	STA coopPairFor
	LDA #$00
	STA objChrBank,X
@rts:
	RTS
@lend:
	STY coopForSlot
	LDA chrBankC,Y
	STA coopForOld
	LDA objChrBank,X
	STA coopForVal
@hit:
	TYA
	STA objChrSlot,X
	TXA
	BEQ :+
	LDA #$02
	BNE :++
:	LDA #$01
:	ORA coopPairFor
	STA coopPairFor
	RTS

; CoopImgBlkSlow: X = slot whose objImgOfsHI != 0 or objImgOfs >= $20. C = 0: A = image block (0-3) of a player image;
; C = 1: not a player image (CoopDrawPair then draws without a pair bank).
CoopImgBlkSlow:
	LDA objImgOfsHI,X
	BEQ @hi
	CMP #$01
	BNE @none
	LDA objImgOfs,X						;$12C-$132: imgPlayerSmallWalk* (table 2), block A
	SEC
	SBC #$2C
	CMP #$08
	BCS @none
	LDA #$00
	CLC
	RTS
@hi:
	LDA objImgOfs,X
	CMP #$B2							;imgPlayerRotateR_2 / imgPlayerRotateL_2: block D
	BEQ :+
	CMP #$B4
	BNE @none
:	LDA #$03
	CLC
	RTS
@none:
	SEC
	RTS

; CoopPairShift: A = tile shift (position base - home base, never 0), X = slot, Y = player. Makes the player's coopImgBuf
; hold his image with every tile number + shift and sets bit 1 / 2 of coopMemoOn (CoopDrawPairResult points his objImgOfs at it).
; The copy is redone only when the image, the image bank or the shift changed (coopImgKey*).
CoopPairShift:
	STA scratch5
	STX scratch4
	STY scratch9
	LDA objImgOfs,X
	CMP coopImgKeyLo,Y
	BNE @copy
	LDA objImgOfsHI,X
	CMP coopImgKeyHi,Y
	BNE @copy
	LDA sprPrgBank
	CMP coopImgKeyBank,Y
	BNE @copy
	LDA scratch5
	CMP coopImgKeyDelta,Y
	BNE @copy
	LDA CoopMemoBit,Y					;the buffer is current
	ORA coopMemoOn
	STA coopMemoOn
	RTS
@copy:
	LDA #$00
	STA coopImgKeyDelta,Y				;buffer invalid until the copy is complete
	LDA #$07							;the image table bank, Rule 9 order (as DrawObjectsBody does next)
	STA $8000
	LDA sprPrgBank
	STA prgBankB
	STA $8001
	LDA objImgOfs,X
	STA scratch0
	LDA objImgOfsHI,X
	CLC
	ADC #$A0
	STA scratch1
	LDY #$00
	LDA (scratch0),Y
	STA scratch2
	INY
	LDA (scratch0),Y
	STA scratch3						;scratch2/3 = the image (size byte, then Y, tile, attr, X per sprite)
	LDX scratch9
	LDA CoopImgBufLo,X
	STA scratch0
	LDA CoopImgBufHi,X
	STA scratch1
	DEY
	LDA (scratch2),Y
	CMP #COOP_IMG_BUF
	BCS @rts							;(never: player images have <= 6 sprites) leave the image unshifted
	STA (scratch0),Y
	STA scratch8
	INY
@spr:
	LDA (scratch2),Y					;Y offset
	STA (scratch0),Y
	INY
	LDA (scratch2),Y					;tile
	CLC
	ADC scratch5
	STA (scratch0),Y
	INY
	LDA (scratch2),Y					;attributes
	STA (scratch0),Y
	INY
	LDA (scratch2),Y					;X offset
	STA (scratch0),Y
	INY
	CPY scratch8
	BCC @spr
	LDY scratch9
	LDX scratch4
	LDA objImgOfs,X
	STA coopImgKeyLo,Y
	LDA objImgOfsHI,X
	STA coopImgKeyHi,Y
	LDA sprPrgBank
	STA coopImgKeyBank,Y
	LDA scratch5
	STA coopImgKeyDelta,Y
	TYA									;coopImgEnt + 2 * player = the address of the player's coopImgBuf
	ASL
	TAX
	LDA CoopImgBufLo,Y
	STA coopImgEnt,X
	LDA CoopImgBufHi,Y
	STA coopImgEnt+1,X
@point:
	LDA CoopMemoBit,Y
	ORA coopMemoOn
	STA coopMemoOn
@rts:
	RTS

; =============================================================================================
; Phase 9.3: OAM order with both players in the round. DrawObjectsBody alternates the slot order (even ticks 0..39, odd
; ticks 39..0), so one player is first in OAM and the other last; with more than 8 sprites on his lines the last one
; loses them, and on a lag frame (NMIShort does no OAM DMA) the PPU shows that tick's OAM a second time: a player could
; be invisible for 2 frames in a row (p93/flick.py). Here both players come first: the one the body would draw last is
; drawn before the body (CoopDrawSlot at OAM 0) and hidden for the body's scan, so the order is
; even: P2, P1, 1..38 / odd: P1, P2, 38..1 (the other objects keep the original alternation behind the players).
; The pre-drawn player's chrBank write is made after the body, where the original order made it (last).
; CoopDrawObjectsC: CoopDrawObjects1P (HUD icon hide) around CoopDrawBodyC; every CoopDrawPair path draws through it.
; =============================================================================================
CoopDrawObjectsC:
	LDA objState+OSLOT_ICON
	BEQ CoopDrawBodyC
	LDA objAnim+OSLOT_ICON
	CMP #.LOBYTE(anJrDoll_ID)
	BNE CoopDrawBodyC
	LDA objAnimHI+OSLOT_ICON
	CMP #.HIBYTE(anJrDoll_ID)
	BNE CoopDrawBodyC
	LDA objY+OSLOT_ICON
	STA hudIconY
	LDA #HUD_ICON_HIDE_Y
	STA objY+OSLOT_ICON
	JSR CoopDrawBodyC
	LDX hudIconY
	STX objY+OSLOT_ICON
	LDX #$00
	RTS

; CoopDrawBodyC: DrawObjectsBody with both players first (see above). The original order when ram_0475 is set (pause,
; announcements: slots >= ram_0475 skipped) or when the player who would be last is not drawn (objState 0: blink, ...).
; Exit as DrawObjectsBody's (X = 0, Z = 1, N = 0, C = 1); A and Y are the body's or the bank write's (no caller reads them).
CoopDrawBodyC:
	LDA ram_0475
	BNE @orig
	LDA globalTimer
	LSR
	BCS @odd
	LDA objState+OSLOT_P2				;even tick: the body draws 0..39, P2 last
	BEQ @orig
	JSR CoopDrawMap
	LDY #OSLOT_P2
	JSR CoopDrawSlot
	JSR CoopP2ObjHide					;bank E: slot-39 objState writes stay in the bank-E co-op code (Phase 6 checker)
	LDY #$00
	JSR DrawObjects_EvenScan			;the body's even scan from slot 0 (its bank map and oamBufferPos = 0 skipped)
	JSR CoopP2ObjShow
	LDX objChrSlot+OSLOT_P2				;P2's chrBank write, last as in the original order
	LDA objChrBank+OSLOT_P2
	BEQ :+
	STA chrBankC,X
:	LDX #$00
	RTS
@odd:
	LDA objState						;odd tick: the body draws 39..0, P1 last
	BEQ @orig
	JSR CoopDrawMap
	LDY #$00
	JSR CoopDrawSlot
	LDA objState
	STA coopDrawSave
	LDA #$00
	STA objState
	LDY #$27
	JSR DrawObjects_OddScan				;the body's odd scan from slot 39 (ram_0475 = 0)
	LDX coopDrawSave
	STX objState
	LDX objChrSlot						;P1's chrBank write, last as in the original order
	LDA objChrBank
	BEQ :+
	STA chrBankC,X
:	LDX #$00
	RTS
@orig:
	JMP DrawObjectsBody

; CoopDrawMap: what DrawObjectsBody does before its scans: the image bank at $A000 (Rule 9 order) and oamBufferPos = 0.
CoopDrawMap:
	LDA #$07
	STA $8000
	LDA sprPrgBank
	STA prgBankB
	STA $8001
	LDA #$00
	STA oamBufferPos
	RTS

; CoopDrawSlot: Y = slot: one step of DrawObjectsBody's slot loop (same OAM bytes) at oamBufferPos, without the chrBank
; write. At most 8 sprites at OAM 0: the buffer cannot fill. Uses scratch0-3, 5, 8, 9, sprAttr (as the body; not 6/7).
CoopDrawSlot:
	LDA objAttr,Y
	STA sprAttr
	LDA objY,Y
	STA scratch2
	LDA objX,Y
	STA scratch3
	LDA objImgOfs,Y
	STA scratch0
	LDA objImgOfsHI,Y
	CLC
	ADC #$A0
	STA scratch1
	LDX objChrSlot,Y
	LDY #$00
	LDA (scratch0),Y
	STA scratch8
	INY
	LDA (scratch0),Y
	STA scratch9
	DEY
	LDA (scratch8),Y					;size of the sprite struct
	CLC
	ADC #$01
	STA scratch1
	LDA SprBaseTiles,X
	STA scratch5
	LDX oamBufferPos
	LDY #$01
@spr:
	LDA (scratch8),Y					;Y
	CLC
	ADC scratch2
	STA OAMBuffer,X
	INX
	INY
	LDA (scratch8),Y					;tile
	CLC
	ADC scratch5
	STA OAMBuffer,X
	INX
	INY
	LDA (scratch8),Y					;attributes
	ORA sprAttr
	STA OAMBuffer,X
	INX
	INY
	LDA (scratch8),Y					;X
	CLC
	ADC scratch3
	STA OAMBuffer,X
	INX
	INY
	CPY scratch1
	BNE @spr
	STX oamBufferPos
	RTS

; =============================================================================================
; Phase 9.3: round-50 missile tractor (CODE_078462 -> CODE_078549, bank 7, run by CODE_078247 before P1's update, so
; P1 is resident: slot 0 = P1, OSLOT_P2 = P2). CODE_078549 is the tractor's only player read: in the states 0-2 / 5 / 6
; (openingCounter) it reads slot 0's objX / objY once: on the floor (Y $C4) on the side the tractor moves to (state 1:
; X <= tractor, state 2: X > tractor) it speeds up (state +2, sound, openingCycle $20); high (Y < $60) within $30 px it
; stops and fires (state 6, openingCycle 1). The fast states 3/4 test the tractor's own position instead (no player).
; CoopTractor: CODE_078549 while both players are in the round (BIT coopP2Active / BMI, bank 7 mapped at $8000).
; Rule: the first player who triggers it, P1 first: the original code runs for P1; if it left openingCounter as it was
; (no trigger) and the tractor is not in state 3/4, the same test runs again from CODE_078549_pos with P2's position
; (scratch3 = tractor X is still set). A re-trigger of state 6 by P1 (6 -> 6, only openingCycle changes) also runs P2's
; test: in state 6 P2 can only re-trigger the same way (6, cycle 1), so the result is the same as "P1 first".
; Clobbers A and the flags, as CODE_078549 does (X / Y untouched).
; =============================================================================================
CoopTractor:
	LDA openingCounter
	PHA
	JSR CODE_078549_1p
	PLA
	CMP openingCounter
	BNE @rts						;P1 triggered it
	CMP #$03
	BEQ @rts						;fast states: no player test
	CMP #$04
	BEQ @rts
	LDA objX+OSLOT_P2
	STA scratch1
	LDA objY+OSLOT_P2
	JMP CODE_078549_pos				;the original test with P2's position; returns to CODE_0784CA's caller
@rts:
	RTS

CoopMemoBit:							;by player: his redirect bit in coopMemoOn
	.byte $02, $04
CoopSlotBit:
	.byte $01, $02, $04, $08
CoopImgBufLo:
	.byte <coopImgBuf, <(coopImgBuf+COOP_IMG_BUF)
CoopImgBufHi:
	.byte >coopImgBuf, >(coopImgBuf+COOP_IMG_BUF)
CoopBlkBase:							;first tile of block A B C D
	.byte $00, $06, $20, $26
CoopImgBlk:								;player image offset / 2 (< $20) -> block (tables 1 and 2; $12/$14 = SmallL/R, table 2)
	.byte $FF, $00, $01, $02, $00, $01, $02, $03, $03, $00, $00, $FF, $FF, $FF, $FF, $FF
.include "coop/coop_pairtab.inc"

; =============================================================================================
; Phase 9.5: respawn spots, borrowing a life (PRG-RAM; see docs/coop_notes.md, Phase 9.5).
; =============================================================================================

; CoopSpot: the spot of an in-place respawn (CoopRespawnX, bank 5) or of a rejoin (CoopBorrowTick), per PHYSICAL player.
; A = physical player (0 / 1), C = 1 if the partner is in the round. Round 20 with the partner in the round and the camera
; not at the round start (wideHScroll != 1): the screen centre COOP_RESPAWN_XMID, facing right (Phase 8). Else the
; player's own spot: P1 X 31 facing right (the original respawn), P2 coopP2StartX facing left (his start of the round).
; Out: A = X, Y = facing (COOP_DIR_L / COOP_DIR_R = anPlayerL_ID / anPlayerR_ID). X clobbered.
CoopSpot:
	BCC @own
	LDX wideRound
	BEQ @own
	LDX wideHScroll
	DEX
	BEQ @own
	LDA #COOP_RESPAWN_XMID
	BNE @right
@own:
	TAX
	BNE @p2
	LDA #COOP_P1_SPOT_X
@right:
	LDY #COOP_DIR_R
	RTS
@p2:
	LDA coopP2StartX
	LDY #COOP_DIR_L
	RTS
.assert COOP_DIR_L = anPlayerL_ID && COOP_DIR_R = anPlayerR_ID, error, "CoopSpot: facing = playerDir = player anim id"

; CoopInitOther: the other player's per-life init by the code P1's uses (CODE_08812A, bank 8, run with the other
; player swapped in; was inline in CoopRoundStartP2). CODE_08812A also writes two shared bytes (wideScrollDir = 0,
; roundFlags &= 7); they are saved and restored. A = the bank the caller has at $8000 (RunBankedSub maps it back).
; Clobbers A/X/Y.
CoopInitOther:
	STA bankedSubRetBank
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
	JSR RunBankedSub
	JSR CoopSwap
	PLA
	STA wideScrollDir
	PLA
	STA roundFlags
	RTS

; CoopBorrowTick: RoundUpdate end (CoopTickOther) while coopP2Active = COOP_P2_OUT: co-op, the other player (ctxOther,
; physical currentPlayer ^ 1) is out and the resident plays alone. Bank 9 at $8000 (RoundUpdate).
;   request: A and B both held on the out player's own pad (pad 2 for physical P2, pad 1 for physical P1) and one of them
;            pressed this tick (a new A+B press) -> coopBorrowReq. Only once armed: coopBorrowReq = COOP_BORROW_UNARMED
;            from the moment he is out (or a round starts with him out) until a tick with A and B both released, so an
;            A+B held or mashed from the play before his last death does not borrow.
;   a request is dropped unless: normal play (roundFlags & $3F = 0: no round clear, prize drop, bonus game or round
;            change pending), the resident is not dying (playerState != PLAYER_STATE_DEAD) and has a spare life
;            (playerLives >= COOP_LEND_MIN); it waits while slot OSLOT_P2 still holds a bubble.
;   borrow:  resident lives - 1, the other player lives 1 and 1 heart, his per-life init (CoopInitOther), spawned at his
;            spot (CoopSpot with the partner in the round; CoopSpawnAt: coopP2Active = $80, bubble budget 19) with the
;            respawn's 120 i-frames; HUD redraw (both blocks), the extra-life sound.
; The caller's $A000 bank (prgBankB) is mapped back (CoopSpawnAt maps AnimTable). Clobbers A/X/Y.
CoopBorrowTick:
	LDX #heldP2-heldP1				;the out player's pad
	LDA currentPlayer
	BEQ :+
	LDX #$00
:	LDA heldP1,X
	AND #KEY_A|KEY_B
	BNE @held
	BIT coopBorrowReq				;A and B released: arm (A = 0)
	BVC @req
	STA coopBorrowReq
	BEQ @req						;(A = 0: no request)
@held:
	CMP #KEY_A|KEY_B
	BNE @req
	AND pressedP1,X
	BEQ @req
	BIT coopBorrowReq
	BVS @rts						;not armed yet
	STA coopBorrowReq				;request (1..3)
@req:
	LDA coopBorrowReq
	AND #KEY_A|KEY_B				;0 or COOP_BORROW_UNARMED: no request
	BEQ @rts
	LDA roundFlags
	AND #$3F
	BNE @drop
	LDA playerState
	CMP #PLAYER_STATE_DEAD
	BEQ @drop
	LDA playerLives
	CMP #COOP_LEND_MIN
	BCC @drop
	LDA objState+OSLOT_P2
	BNE @rts						;slot OSLOT_P2 still a bubble: wait
	DEC playerLives
	LDA #$01
	STA ctxOther_playerLives
	STA ctxOther_playerHearts
	LDA prgBankB
	PHA
	LDA #.BANK(RoundUpdate)
	JSR CoopInitOther
	LDA #COOP_RESPAWN_Y
	STA objY+OSLOT_P2
	LDA currentPlayer
	EOR #$01
	SEC
	JSR CoopSpot
	STA objX+OSLOT_P2
	STY ctxOther_playerDir
	TYA
	JSR CoopSpawnAt
	LDA #COOP_RESPAWN_INV
	STA ctxOther_playerInvFrames
	LDA livesCurrentPos
	ORA #$03
	STA livesCurrentPos
	LDA #snExtraLife_ID
	STA soundTrigger
	LDA #$00
	STA coopBorrowReq
	JMP CoopBankRestore				;$A000 back to the caller's bank (pushed above), race-free order (Rule 9)
@drop:
	LDA #$00
	STA coopBorrowReq
@rts:
	RTS


; =============================================================================================
; Phase 9.0: CoopBoot (bank $10, $B000; COOP_BOOT segment). Called once from Begin with bank $10 mapped at $A000 (Rule 9
; order, through SwapPrgBankB), NMI and IRQ off, stack set. It replaces Begin's original power-on delay loop and takes
; exactly as many cycles, so the rest of the reset path (vblank waits, MemInit, CoopReset, ...) is cycle-identical:
;   1. PRG-RAM enable ($A001 = $80; CoopReset writes it again later, nothing ever writes another value),
;   2. copy COOP_WRAM_CODE_PAGES pages $A000.. -> $7000.. (the COOP_WRAM_CODE image; the rest of the 4 KB is $FF fill),
;   3. wait out the rest of the original delay (two exact loops + padding computed below).
; Uses scratch0-3 (MemInit clears the zero page after this). Leaves X = Y = 0, as the original loop did.
; =============================================================================================
COOP_BOOT_TOTAL = 2+2+256*(255*9+8+2+3)-1	;Begin's original LDY #0 / LDX #0 / NOP NOP DEX BNE / DEY BNE (590851)
COOP_BOOT_CALL  = 2+3+6+22+6+6			;Begin: LDA # / STA zp / JSR SwapPrgBankB (its body + RTS 22) / JSR CoopBoot; RTS
COOP_BOOT_SETUP = 2+4+4*(2+3)+2+2			;CoopBoot up to @page
COOP_BOOT_COPY  = COOP_WRAM_CODE_PAGES*(256*16-1+5+5+2+3)-1	;@page loop (no page crossing: both bases are page-aligned)
COOP_BOOT_REST  = COOP_BOOT_TOTAL-COOP_BOOT_CALL-COOP_BOOT_SETUP-COOP_BOOT_COPY
COOP_BOOT_N     = COOP_BOOT_REST/2308			;@outer: 2 + N*2308 - 1 cycles (X = 0 on entry)
COOP_BOOT_R2    = COOP_BOOT_REST-(COOP_BOOT_N*2308+1)
COOP_BOOT_M0    = (COOP_BOOT_R2-1)/5			;@fine: 2 + M*5 - 1 cycles
.if COOP_BOOT_R2-1-COOP_BOOT_M0*5 = 1
COOP_BOOT_M     = COOP_BOOT_M0-1				;(a 1-cycle remainder cannot be padded: 6 instead)
.else
COOP_BOOT_M     = COOP_BOOT_M0
.endif
COOP_BOOT_PAD   = COOP_BOOT_R2-1-COOP_BOOT_M*5	;0, 2..6 cycles of NOP (2) / JMP (3) padding
.assert COOP_BOOT_N >= 1 && COOP_BOOT_N <= 255, error, "CoopBoot: outer delay count out of range"
.assert COOP_BOOT_M >= 1 && COOP_BOOT_M <= 255, error, "CoopBoot: fine delay count out of range"
.assert COOP_BOOT_PAD <> 1 && COOP_BOOT_PAD <= 6, error, "CoopBoot: padding out of range"

.segment "COOP_BOOT"

CoopBoot:
	LDA #$80						;MMC3 $A001: PRG-RAM enable, writes allowed
	STA $A001
	LDA #<COOP_WRAM_CODE_IMG
	STA scratch0
	LDA #>COOP_WRAM_CODE_IMG
	STA scratch1
	LDA #<COOP_WRAM_CODE_RUN
	STA scratch2
	LDA #>COOP_WRAM_CODE_RUN
	STA scratch3
	LDY #$00
	LDX #COOP_WRAM_CODE_PAGES
@page:
	LDA (scratch0),Y
	STA (scratch2),Y
	INY
	BNE @page
	INC scratch1
	INC scratch3
	DEX
	BNE @page
	LDY #COOP_BOOT_N				;X = 0, Y = 0 here
@outer:
	NOP
	NOP
	DEX
	BNE @outer
	DEY
	BNE @outer
	LDX #COOP_BOOT_M
@fine:
	DEX
	BNE @fine
.if (COOP_BOOT_PAD = 3) || (COOP_BOOT_PAD = 5)
	JMP :+
:
	.repeat (COOP_BOOT_PAD-3)/2
	NOP
	.endrepeat
.else
	.repeat COOP_BOOT_PAD/2
	NOP
	.endrepeat
.endif
	RTS
CoopBootEnd:
.assert >CoopBoot = >(CoopBootEnd-1), error, "CoopBoot must not cross a page (branch timing)"
.assert <COOP_WRAM_CODE_IMG = 0 && <COOP_WRAM_CODE_RUN = 0, error, "CoopBoot: the copy bases must be page-aligned"
.import __COOP_WRAM_CODE_LOAD__, __COOP_WRAM_CODE_RUN__
.assert __COOP_WRAM_CODE_LOAD__ = COOP_WRAM_CODE_IMG, lderror, "COOP_WRAM_CODE image is not at COOP_WRAM_CODE_IMG"
.assert __COOP_WRAM_CODE_RUN__ = COOP_WRAM_CODE_RUN, lderror, "COOP_WRAM_CODE does not run at COOP_WRAM_CODE_RUN"
.assert .bank(CoopBoot) = .bank(CoopCamera), lderror, "CoopBoot must be in the bank of the WRAM code image"
