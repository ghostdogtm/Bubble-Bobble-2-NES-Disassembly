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
