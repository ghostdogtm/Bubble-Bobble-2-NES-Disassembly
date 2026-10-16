; Co-op variables. They live in PRG-RAM ($6000-$7FFF, 8 KB, enabled by CoopReset).
; Segment COOP_BSS is mapped to the WRAM memory area in config_us; CoopReset zeroes all of it at reset.
; (Phase 9.0) The data area is $6000-$6FFF (4 KB); $7000-$7FFF holds the co-op code copied at power-on (COOP_WRAM_CODE).

.segment "COOP_BSS"

coopMode:       .res 1          ; 0 = normal 1-player game, 1 = co-op active (R2: the title menu's SELECT toggles it;
                                ; cleared at reset and at every title setup, bank 5 @advance)
coopResident:   .res 1          ; which player's state is in the main game variables: 0 = P1, 1 = P2
coopCanary:     .res 4          ; "COOP" written at reset; shows PRG-RAM is mapped and writable

; ctxOther: the non-resident player's context. One shadow byte per COOP_CTX_SCALARS entry (generated from
; the list in coop.inc, named ctxOther_<symbol>) plus one for the per-player bits of powerUps.
; The per-object arrays need no shadow: the non-resident player's object lives in slot OSLOT_P2.
.macro COOP_CTX_SHADOW name, mode
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

; Phase 5: collisions and owner-aware capture.
coopShotSwapped: .res 1         ; 1 = the shot bytes (shooting, shootInitialSlot, shootQueuedBubbles, shootTrigger,
                                ; shootSlot) are exchanged with their ctxOther copies: set by CoopCaptureOther when the
                                ; non-resident player's bubble caught an enemy, undone before any swap (CoopShotRestore)
coopP2SkipSlot: .res 1          ; bubble index CoopP2Shoot updated this tick ($FF = none): no P2 touch on it this tick

; Phase 6a: enemy target selection (see docs/coop_notes.md, Phase 6a).
targetX:        .res 1          ; X of the player the current enemy aims at (enemy AI reads this instead of objX)
targetY:        .res 1          ; Y of that player (instead of objY)
coopTarget:     .res 1          ; 0 = P1 (slot 0 / native vars), 1 = P2 (slot OSLOT_P2 / ctxOther_*); kept when no
                                ; player is targetable. Set per even tick (P2 not active) or per enemy (P2 active).
coopPos:        .res 2          ; CoopNearest input: X, Y of the enemy / projectile looking for a player
coopDist:       .res 3          ; CoopNearest temporaries: slot 0's |dx|+|dy| (9 bits: lo, hi), slot OSLOT_P2's |dx|

; Phase 6b: world -> player interactions (see docs/coop_notes.md, Phase 6b).
coopDrinkElig:  .res 1          ; CoopDrinkGate result: bit 0 = the resident player (P1) may drink, bit 1 = P2 may
coopItemNoOther: .res 1         ; non-zero while CoopDrinkTouch runs and the other player may not drink: CoopItemOther
                                ; (tail of CODE_078BC5) then skips its test
coopPopDir:     .res BUBBLE_SLOTS ; per bubble index: $80 | P2's playerDir when P2's touch pass popped this special
                                ; bubble; consumed (cleared) by CoopPopDir in the same tick's UpdateBubbles

; Phase 7a: death, out, game over / continue, score attribution (see docs/coop_notes.md, Phase 7a).
coopRoles:      .res 1          ; 1 = the physical players are exchanged: the resident (slot 0, native vars) is P2 and
                                ; ctxOther holds P1 (set when P1 is out while P2 plays on). currentPlayer =
                                ; coopResident ^ coopRoles = the physical id of the resident player.
coopBubOwner:   .res BUBBLE_SLOTS ; per bubble index: physical id of the player who popped it (touch, or chain from his
                                ; popped bubble); $FF = unknown (credited to currentPlayer)
coopKiller:     .res 10         ; per enemy index: physical id of the player who killed it (bubble pop, hazard, holy cup,
                                ; shot hit); $FF = unknown (credited to currentPlayer); consumed by CODE_0B9B2F
coopKills:      .res 2          ; enemy-bubble kills since the last multi-kill award, by physical player (ram_051A = sum)
coopHazOwner:   .res 1          ; owner of the special bubble whose effect HazardCheckEnemies is testing
coopTmp:        .res 3          ; CoopKillSplit (+0 total, +1 the other share), CoopAddScoreAs (+2 saved currentPlayer)

; Phase 7b-1: 8x8 HUD (see docs/coop_notes.md, Phase 7b-1). Variant A: the original HUD job code (CODE_099BE7) runs
; unchanged; CoopHudBuild builds the new row here and CoopHudUpload (head of CODE_0FE93B) uploads it instead of mapBuffer.
hudJob:         .res 1          ; 1 = hudBuf holds the row of the HUD job queued this tick; cleared by every CoopHudUpload
hudTarget:      .res 2          ; PPU address of the row (lo, hi): row 2 or 3, column 2 of the HUD's nametable
hudDummy:       .res 2          ; mapTargetAdr the original job left (lo, hi): the upload replaces only that job
hudBuf:         .res HUD_ROW_TILES ; the row's tiles, columns 2-29
hudLabel:       .res 1          ; block inputs (HudPlayerData): label glyph ('1' / '2'), lives, hearts,
hudLives:       .res 1          ;   index of the score digits (0 = scoreDigits, HUD_TOTAL_DIGITS = scoreDigitsP2)
hudHearts:      .res 1
hudScoreIdx:    .res 1
hudCnt:         .res 1          ; temporary (digit loop; then the tile half $00/$80 in the final pass)
hudIconY:       .res 1          ; CoopDrawObjects: objY of the HUD icon, put back after DrawObjects
hudTmpA:        .res 1          ; CoopDrawObjects: DrawObjects' A; CoopHudBuild: glyph shift (bonus screen)
hudStamp:       .res 1          ; globalTimer of the tick that queued hudBuf: a row is uploaded only in the next full NMI

; Phase 7b-3: team bonus.
coopTeamDigits: .res SCORE_TOTAL_DIGITS ; CoopAddScoreTeam: scoreAdditionDigits kept for the second player's award

; Phase 8: round 20 camera with both players in the round.
coopCamHold:    .res 1          ; CoopCamera, on a tick it scrolled: bit 0 = the player then in slot 0 (the tick's resident),
                                ; bit 1 = the one in OSLOT_P2 pushed the camera; his X step is not taken (CODE_0594EB), as the
                                ; 1P camera does for P1. Read only while wideScrollDir != 0.
coopCamWant:    .res 2          ; CoopCamera: push direction (0, DIR_LEFT, DIR_RIGHT) of the slot-0 and the OSLOT_P2 player
coopCamTmp:     .res 1          ; CoopRuckusWrap: camera move (even) of a fall through the floor

; Phase 9.1: both players' sprites from one CHR KB (CoopDrawPair; see docs/coop_notes.md, Phase 9.1).
coopPairOn:     .res 1          ; (unused since 9.2) CoopDrawPair, this DrawObjects call: bit 0 = chrBankC := coopPairBank after it; bit 1 / 2 = P1's /
                                ; P2's objImgOfs points at his coopImgBuf (put back from coopPairSave+2/3 / +4/5)
coopMemoKey:    .res 7          ; CoopDrawPair: the inputs of the last computed result (objChrBank, objImgOfs, objImgOfsHI of P1 / P2, sprPrgBank)
coopMemoOn:     .res 1          ; its result: 0 = no pair; bit 0 = pair bank, bit 1 / 2 = P1's / P2's image redirected (9.2)
coopPairSave:   .res 6          ; (unused since 9.2) +2/3: P1's objImgOfs / HI, +4/5: P2's (+0/1 unused)
coopPairFor:    .res 1          ; bit 0 / 1: CoopForeignSlot moved P1 / P2 to another sprite CHR slot for this call
coopForSlot:    .res 1          ; sprite slot 1-3 lent to a player by CoopForeignSlot in the last call (0 = none)
coopForOld:     .res 1          ; its chrBankD-F value before, and the bank the player wrote there
coopForVal:     .res 1
coopMuteSave:   .res 2          ; objChrBank of P1 / P2 while CoopForeignSlot draws him without a bank (no slot free)
coopPairA:      .res 1          ; DrawObjects' A across the restore
coopPairBank:   .res 1          ; the pair bank of this call
coopPairPt:     .res 2          ; per player (0 = slot 0, 1 = OSLOT_P2): frame point 0-39 (coop_pairtab.inc)
coopPairBlk:    .res 2          ; per player: home block of the frame (0-3 = A B C D)
coopPairPos:    .res 2          ; per player: block position of the frame in the pair bank
coopImgKeyLo:   .res 2          ; per player: objImgOfs, objImgOfsHI, sprPrgBank and tile shift of the image in coopImgBuf
coopImgKeyHi:   .res 2          ;   (coopImgKeyDelta 0 = buffer empty: a shift is never 0)
coopImgKeyBank: .res 2
coopImgKeyDelta: .res 2
coopImgEnt:     .res 4          ; per player: pointer to his coopImgBuf (the "image table entry" objImgOfs points to)
coopImgBuf:     .res 2*COOP_IMG_BUF ; per player: copy of the image with the tile numbers shifted

; Phase 9.2: co-op performance.
coopTouchSkip:  .res 1          ; (9.2) CoopP2BubbleTouch: the last bubble whose CODE_098932 call was skipped ($FF = none since the last call)

; Phase 9.3: OAM order.
coopDrawSave:   .res 1          ; (9.3) CoopDrawBodyC / CoopP2ObjHide: objState of the player drawn first, hidden for the body's scan

; Phase 9.5: respawn spots, borrowing a life.
coopP2StartX:   .res 1          ; physical P2's spot X of this round: the X CoopSpawnP2 gave slot OSLOT_P2 (the mirror of the
                                ; resident's start), or COOP_P2_START_X when the round started with the other player out
coopBorrowReq:  .res 1          ; 1..3: the out player pressed A+B; CoopBorrowTick lends him a life when slot OSLOT_P2 is
                                ; free (the request is dropped when a condition fails, and at every CoopDespawnAll);
                                ; COOP_BORROW_UNARMED ($40): out, but A and B not yet released since; 0: armed, no request
