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

## Verify quickly
Search output for `[PERSIST]` load/save counts and `[PLOT] Assigned` / `Freed`.
