; Co-op (2-player simultaneous) constants. Constants only: no code, no data.
; Included from main.asm after defines.inc, US build only (.ifndef REGION_JP).

OSLOT_P2        = 39            ; object slot reserved for player 2 (see docs/coop_notes.md)

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
.macro COOP_CTX_SCALARS M
	M ram_0062
	M playerHeld
	M playerPressed
	M playerState
	M ram_0076
	M playerDir
	M ram_0078
	M hBlocked
	M ram_007A
	M ram_007B
	M playerDmgType
	M ram_007D
	M playerHazardTrigger
	M playerHazardSlot
	M playerInvFrames
	M playerHearts
	M playerLives
	M ram_047A
	M ram_047B
	M inflateTime
	M extraBubbles
	M ram_047E
	M shootSlot
	M shootDir
	M shootTrigger
	M shootQueuedBubbles
	M shooting
	M shootInitialSlot
	M bubbleVariant
	M shootCounter
	M ram_077B
.endmacro

; Per-object arrays: slot 0 (P1) is exchanged with slot OSLOT_P2 (P2). No shadow storage needed.
.macro COOP_CTX_ARRAYS M
	M objState
	M objY
	M objX
	M objImgOfs
	M objImgOfsHI
	M objChrSlot
	M objChrBank
	M objAnim
	M objAnimTimer
	M objAnimProgress
	M objAttr
	M objAnimHI
.endmacro

; Bits of powerUps that are per player (cleared on death); the other bits are shared.
COOP_POWERUP_MASK = POWERUP_CANDY | POWERUP_SHOE
