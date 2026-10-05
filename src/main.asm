.feature force_range

.include "defines.inc"

.ifndef REGION_JP
.include "coop/coop.inc"
.endif

.include "prg.asm"
.include "chr.asm"

.ifndef REGION_JP
.include "coop/coop_ram.asm"
.include "coop/coop_engine.asm"
.endif
