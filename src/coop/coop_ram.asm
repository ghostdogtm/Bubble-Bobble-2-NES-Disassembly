; Co-op variables. They live in PRG-RAM ($6000-$7FFF, 8 KB, enabled by CoopReset).
; Segment COOP_BSS is mapped to the WRAM memory area in config_us; CoopReset zeroes all of it at reset.

.segment "COOP_BSS"

coopMode:       .res 1          ; 0 = normal 1-player game, 1 = co-op active (nothing reads it yet)
coopResident:   .res 1          ; which player's state is in the main game variables: 0 = P1, 1 = P2
coopCanary:     .res 4          ; "COOP" written at reset; shows PRG-RAM is mapped and writable
ctxOther:       .res 64         ; placeholder: swapped-out player context (Phase 2 sizes it)
