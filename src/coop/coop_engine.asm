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
; Content: P2 player update (CODE_058E83, run exactly as RoundUpdate runs it); on odd RoundUpdate ticks
; also P2's shot (CoopP2Shoot, Phase 4). Later phases add bubble touch, enemy collision... inside CoopP2Window.
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
	;P2's shot (RoundUpdate odd ticks only: HandleShooting runs there, and the round intro has none)
	LDA globalTimer
	LSR
	BCC @noshoot					;even tick
	LDA bankedSubRetBank
	CMP #.BANK(RoundUpdate)
	BNE @noshoot					;intro window
	JSR CoopP2Shoot
@noshoot:
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
; CoopP2Shoot (Phase 4): P2 resident, bank 9 mapped at $8000 (odd RoundUpdate tick, inside the window).
; HandleShooting consumes P2's shootTrigger (spawns P2's emerging bubble at P2's position, bubble
; index shootSlot). P2's emerging bubble is then updated here, with P2's globals (shootDir, candy,
; bubbleVariant, shootQueuedBubbles), exactly as UpdateBubbles does for P1's: X = bubble index.
; UpdateBubbles skips that slot while P1 is resident. terrainResult needs no pre-clear: the first
; thing BubbleEmergingUpdate does (BubbleEmergingCheckTerrain) is to store it. Clobbers A/X/Y.
; ---------------------------------------------------------------------------------------------
CoopP2Shoot:
	JSR HandleShooting
	LDA shooting
	BEQ @done
	LDX shootSlot
	JSR BubbleEmergingUpdate
@done:
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
; Clobbers A only.
; ---------------------------------------------------------------------------------------------
CoopP2Deactivate:
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
