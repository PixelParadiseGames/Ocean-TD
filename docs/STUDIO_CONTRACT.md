# Studio Contract — Master Plot Plugin

Map art stays in `Ocean TD.rbxl`. Rojo does **not** sync Workspace. Plots come from **Arena Generator** plugin — place the master; the plugin spawns the rest. **No manual Arena.Center.**

How Cursor sees Studio: [STUDIO_VISIBILITY.md](STUDIO_VISIBILITY.md). Plugin source: `plugins/ArenaGeneratorPlugin.lua`.

## North star
Author once on the master wedge; stamp terrain and remap décor around the ring; treat **six equal logical plots**, but look up world content via **master (plot 1)** vs **`StaticPlot_N`**.

## Plugin flow (authoring)
1. Place / sculpt **one** `MasterTerrainBox` (green).
2. **1. Spawn/Update Previews** → folder `TerrainPreviews` with `PreviewBox_1` … `PreviewBox_5`. Ring center is derived in plugin math from the master (apothem + Z/2 + expansion) — no Center part.
3. **2. Stamp Terrain** — local-space voxel copy into each preview region.
4. **3. Hide Previews** — moves `MasterTerrainBox` + `TerrainPreviews` into **ServerStorage** (not Destroy). Show brings them back.

## Logical mapping (runtime)
| Logical plot | Runtime pose |
|--------------|--------------|
| Plot1 | `MasterTerrainBox.CFrame` |
| Plot2..N | `RingMath.plotCFrame` from Master + `ExpansionOffset` (same formula as plugin previews) |

`PreviewBox_*` are **Studio stamp helpers only** — not read for live plot CFrames. Spawning previews writes `MasterTerrainBox.ExpansionOffset` so runtime RingMath matches the stamp.

**No runtime terrain calibrate.** If islands disagree with the ring (waves/décor off corals), fix in Studio: Show Previews → Stamp Terrain → Hide, then restart. Do not reintroduce per-boot XZ nudges — they break leave/rejoin VisualPos restore.

## Décor cloning (runtime)
Author props only under **`Workspace.MasterPlotDecor`** (plot 1). At server boot, `DecorReplicator` clones them to **`StaticPlot_2` … `StaticPlot_N`** with a rigid remap from plot 1’s CFrame. There is no `StaticPlot_1`.

Expect `[DECOR] Cloned … -> StaticPlot_N` in Output. Do not hand-duplicate décor onto every wedge.

## Required for assign
- `MasterTerrainBox` in Workspace **or** ServerStorage (after Hide), with `ExpansionOffset` matching the last Spawn/Update Previews.

Optional: `MasterPlotDecor` (required for décor clones).  
`Workspace.Arena` optional for future mid-arena coop/PvP only.

## UI templates (Workspace, not Rojo)
| Path / asset | Used by |
|--------------|---------|
| `rbxassetid://345081302` | Placement confirm move hint (under coral) |

Optional Studio reference: `Workspace.UI["Move Icon"]` — code uses the asset id directly.

## Reject
- Six masters; `StaticPlot_1`; Master paths for every player; `PreviewBox_i == Plot_i`; requiring a hand-placed Arena.Center; assuming Hide deletes boxes.

## After plugin
Expect `[PLOT] Init from Master + RingMath (stable; no TerrainPlotAlign)` then `[DECOR]` clone lines. Smoke: [SMOKE_TEST.md](SMOKE_TEST.md).
