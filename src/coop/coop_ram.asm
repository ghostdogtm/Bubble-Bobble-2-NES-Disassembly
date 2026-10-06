; Co-op variables. They live in PRG-RAM ($6000-$7FFF, 8 KB, enabled by CoopReset).
; Segment COOP_BSS is mapped to the WRAM memory area in config_us; CoopReset zeroes all of it at reset.

.segment "COOP_BSS"

coopMode:       .res 1          ; 0 = normal 1-player game, 1 = co-op active
coopResident:   .res 1          ; which player's state is in the main game variables: 0 = P1, 1 = P2
coopCanary:     .res 4          ; "COOP" written at reset; shows PRG-RAM is mapped and writable

; ctxOther: the non-resident player's context. One shadow byte per COOP_CTX_SCALARS entry (generated from
; the list in coop.inc, named ctxOther_<symbol>) plus one for the per-player bits of powerUps.
; The per-object arrays need no shadow: the non-resident player's object lives in slot OSLOT_P2.
.macro COOP_CTX_SHADOW name
.if .xmatch(name, playerLives)
coopP2Lives:                    ; harness hook: a label (not an equate) so that it reaches labels.txt;
.endif                          ; the harness keeps it topped up in co-op scenarios (P1 is resident at tick start)
.ident(.concat("ctxOther_", .string(name))): .res 1
.endmacro

ctxOther:
	COOP_CTX_SCALARS COOP_CTX_SHADOW
ctxOther_powerUps:  .res 1      ; only bits COOP_POWERUP_MASK are used (the shared powerUps bits stay in place)
CTX_OTHER_SIZE = * - ctxOther   ; = scalar count + 1

; Phase 3: P2 presence and the bubble slot budget.
coopP2Active:   .res 1          ; $80 = P2 is in the round (object in OSLOT_P2, P2 window runs), 0 = not
                                ; (bit 7 so that the bank hooks can gate with BIT / BPL and keep A/X/Y)
bubbleSlotEnd:  .res 1          ; bubble slot loop end (relative to OSLOT_BUBBLE): 20, or 19 while P2 owns slot 39
bubbleSlotLast: .res 1          ; bubbleSlotEnd - 1: outer-loop end of BubblesTravelUpdate (19, or 18)
coopP2SavedState: .res 1        ; objState+OSLOT_P2 saved across DrawObjects (invincibility blink)
