# Failure Modes

Document bugs we must not rediscover. Add a row when a nasty one ships.

| Failure | Cause | Guard |
|---------|-------|-------|
| Wiped plot on rejoin | Autosave/leave-save ran while plot still empty mid-load | `PlayerSession.layoutLoaded` gate; no save until hydrate finishes |
| Empty clobber of good DataStore | Snapshot `{}` wrote over non-empty layout | `UpdateAsync` anti-wipe in `PersistenceService` |
| Missing PreviewBoxes at play | Hide moved them to ServerStorage; code only looked in Workspace | `PlotService` reads WS **or** SS; RingMath fallback from master |
| Wrong plot for PreviewBox_i | Assumed PreviewBox_1 = Plot1 | Master=Plot1, PreviewBox_i=Plot_(i+1) under `TerrainPreviews` |
| Wrong décor for player | Used MasterPlotDecor for every plot id | `getDecorFolder`: plot1=Master, else StaticPlot_N |
| Décor path miss on StaticPlot | Assumed `StaticPlot_N.Tut` mirrors Master folders | Rigid remap; wrappers often missing — search from StaticPlot root |
| Ring desync after resize | Plugin stamp math ≠ `RingMath` / `MAX_PLOTS` | Keep plugin + Constants in sync; re-stamp |
| Six masters / StaticPlot_1 | Misunderstood authoring | One MasterTerrainBox; no StaticPlot_1 |
| Layout appears on wrong reef | Saved world coords from old slot | Plot-local `lx,ly,lz` only |
| Seventh player softlocks | No free ring slot | Kick with clear message; no partial session |
| Studio “data lost” panic | API services off in Studio | Enable Studio DataStore access; logs still show load/save path |
| Double-assign same plot | Race on PlayerAdded | Single `PlotService.assign`; slot.owner check |
| Save during save | Overlapping autosave + leave | `session.saving` flag in `PlayerSession` |
| Coral + wave path slide radially on rejoin | Runtime `TerrainPlotAlign` / PreviewBox pose ≠ save-time `slot.cframe` | **PlotFrameContract**: Master+RingMath only; no voxel calibrate; boot logs `contractOk=` |
| PreviewBox used as live pose | Boxes drifted vs stamp / ExpansionOffset | Runtime ignores PreviewBoxes; stamp helpers only ([STUDIO_CONTRACT.md](STUDIO_CONTRACT.md)) |
| Shared Studio outline for all players | One mesh tinted globally | Client builds OBB edges from `ClientPlot` / roster; never one global outline model |
| Food flies into school but fish stay hungry | Aim used constant `FISH_SPEED` while fish surge ±15%; sway + tight eat radius → miss, no credit | Predict with live speed curve; late-flight home to mouth; larger eat / end grace (`WaveSim`) |
| Hungry fish slip past ready corals / feel “invisible” | Targeting preferred *approaching* fish; `PATH_TARGET_PAST` too tight; dive bob buried fish; hunger bars LOD-hid | Prefer at/past stragglers; wider past window; world-range fallback; clamp dive; always-on hunger bars |
| Skills PowerUpTemplate sucked into bubble sim | Collected every ImageButton under MobileSkillsB | Only `PlotSizeBTN` / `EarnMoreBTN` / `PlaceMoreBTN` become bubbles (`SkillStages`) |
| Lost / double $D after Robux | Client-trusted balance, or ProcessReceipt grant then failed save, or session save clobbering a receipt applied on another server | Server-only integer wallet; `PurchaseId` ledger; `NotProcessedYet` until persist; save merges unknown receipts; load-fail blocks save |

## Verify quickly
Search output for `[PERSIST]` load/save counts and `[PLOT] Assigned` / `Freed`.
Expect `[PLOT] Init from Master + RingMath … contractOk= true`.
Expect `[PLOT_OUTLINE] Ready` and attribute `PlotOutlineColorIndex` after session ready.
