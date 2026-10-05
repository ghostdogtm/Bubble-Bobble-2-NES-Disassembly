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
