; Co-op (2-player simultaneous) constants. Constants only: no code, no data.
; Included from main.asm after defines.inc, US build only (.ifndef REGION_JP).

OSLOT_P2        = 39            ; object slot reserved for player 2 (see docs/coop_notes.md)

; Canary written to coopCanary at reset; proves PRG-RAM ($6000-$7FFF) is mapped and writable
COOP_CANARY0    = $43           ; 'C'
COOP_CANARY1    = $4F           ; 'O'
COOP_CANARY2    = $4F           ; 'O'
COOP_CANARY3    = $50           ; 'P'
