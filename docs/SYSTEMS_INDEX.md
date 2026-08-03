# Systems Index

Read [PROJECT_OVERVIEW.md](PROJECT_OVERVIEW.md) first. Then open only the owner + helpers for one system.

Update this file in the **same change** when you add or rename a system. If index and code disagree, fix the index.

| System | Status | Owner | Helpers | Notes |
|--------|--------|-------|---------|-------|
| Bootstrap (server) | Live | `src/ServerScriptService/OceanTD/Bootstrap.server.lua` | wires services below | Join → load → assign → hydrate → ready; leave → snapshot → save → free |
| Bootstrap (client) | Live | `src/StarterPlayerScripts/OceanTD/Bootstrap.client.lua` | `ClientPlot.lua` | Mirrors plot bounds; SessionReady |
| PlotService | Live | `.../Services/PlotService.lua` | `Shared/Constants`, `Shared/GridMath`, `Shared/RingMath` | Master + PreviewBox_1..5; `getDecorFolder`; Bounds fallback |
| DecorReplicator | Live | `.../Services/DecorReplicator.lua` | PlotService poses | Boot: `MasterPlotDecor` → `StaticPlot_2..N` rigid remap |
| RingMath | Live | `src/ReplicatedStorage/OceanTD/Shared/RingMath.lua` | — | Matches ArenaGeneratorPlugin preview formula |
| GridService | Live | `.../Services/GridService.lua` | `Shared/GridMath`, `Shared/PlotTypes` | In-memory cells; `tryOccupy` / hydrate / snapshot |
| PersistenceService | Live | `.../Services/PersistenceService.lua` | `Shared/PlotTypes`, `Shared/Constants` | DataStore `OceanTD_Player_v1`; anti-wipe; `plotSaves` 1–4 + activeIndex |
| PlotSaveService | Live | `.../Services/PlotSaveService.lua` | Persistence, Placement, Undo, Grid | Manual save/load/NEW/rename; load wipes undo; autosave targets active slot |
| PlayerSession | Live | `.../Services/PlayerSession.lua` | — | `layoutLoaded` gate for saves |
| Remotes | Live | `src/ReplicatedStorage/OceanTD/Remotes.lua` | `RemoteEvents` folder (not named Remotes — avoids ModuleScript name clash) | `PlotAssigned`, `PlotCleared`, `SessionReady`, `RequestPlace` / `RequestMove` / `RequestRecycle` / `RequestUndo` / `RequestClearPlot` / `RequestGetPlotSaves` / `RequestSavePlotSlot` / `RequestLoadPlotSlot` / `RequestRenamePlotSave` (RF) |
| GridMath | Live | `src/ReplicatedStorage/OceanTD/Shared/GridMath.lua` | `Constants` | Cell size 4; plot-local helpers |
| InventoryUI | Live | `src/StarterPlayerScripts/OceanTD/InventoryUI.client.lua` | `InventoryState`, `PlacementController`, `SavePlotSlot`, `ClearPlotSlot`, `UndoSlot`, `WaveSlot`, ItemCatalog, UiCircles | Slot4 backpack; mounts Slot1–3 + Slot5 waves; drag-scroll; drag-out place |
| SavePlotSlot | Live | `src/StarterPlayerScripts/OceanTD/SavePlotSlot.lua` | InventoryState, Remotes | Slot1 save UI / 2×2 presets / L3·V; blue `#0073ed` help |
| ClearPlotSlot | Live | `src/StarterPlayerScripts/OceanTD/ClearPlotSlot.lua` | ClearPlotVfx, InventoryState | Slot2 clear-plot UI / confirm / shortcuts |
| UndoSlot | Live | `src/StarterPlayerScripts/OceanTD/UndoSlot.lua` | Remotes RequestUndo | Slot3 undo UI / cycle / Z/L2 |
| WaveSlot | Live | `src/StarterPlayerScripts/OceanTD/WaveSlot.lua` | WaveSim | Slot5 start/stop waves; R/ButtonX; green help; summary + confetti |
| WaveSim | Live | `src/StarterPlayerScripts/OceanTD/WaveSim.lua` | ClientPlot, SpeciesCatalog | Client-only feed waves; bezier route; coral food; reef health |
| InventoryState | Live | `src/StarterPlayerScripts/OceanTD/InventoryState.lua` | ItemCatalog | Open + selected; clear-plot + save-plots modal gates |
| ItemCatalog | Live | `src/ReplicatedStorage/OceanTD/Shared/ItemCatalog.lua` | SpeciesCatalog via `speciesId` | BrainCoral first; register new items here |
| SpeciesCatalog | Live | `src/ReplicatedStorage/OceanTD/Shared/SpeciesCatalog.lua` | — | Visual/place rules (diameter, color range, material) |
| CoralVisual | Live | `src/ReplicatedStorage/OceanTD/Shared/CoralVisual.lua` | SpeciesCatalog | Ball factory; ghost tint; no shadow |
| PlacementService | Live | `.../Services/PlacementService.lua` | GridService, PlotService, CoralVisual, UndoService | Server place (debit) / move / recycle / clearPlot / applyLayout; hydrate; undoLast |
| UndoService | Live | `.../Services/UndoService.lua` | PlacementService (via push) | Session-only stack (max 10); cleared on leave and on plot-save load |
| PlacementController | Live | `src/StarterPlayerScripts/OceanTD/PlacementController.lua` | ClientPlot, CoralVisual, InventoryState | Confirm-ghost ✓/X; freeze avatar/camera |
| ClearPlotVfx | Live | `src/StarterPlayerScripts/OceanTD/ClearPlotVfx.lua` | InventoryState scroll center | Local clear FX: light, green wave, hand +N, fly to backpack |
| PlacementBootstrap | Live | `src/StarterPlayerScripts/OceanTD/PlacementBootstrap.client.lua` | PlacementController | Requires controller on client boot |
| UiTheme | Live | `src/ReplicatedStorage/OceanTD/Shared/UiTheme.lua` | — | Default font FredokaOne for generated UI text |
| ForceLandscape | Live | `src/StarterPlayerScripts/OceanTD/ForceLandscape.client.lua` | — | Landscape only; no portrait mobile |
| Remove coral | Live | PlacementService.recycle + RelocateController | GridService, UndoService | Recycle credits seed; Slot3/Z/L2 undoes |
| Clear plot | Live | PlacementService.clearPlot + InventoryUI Slot2 | ClearPlotVfx, UndoService | Full seed refund; Slot2/C/R3 + ✓/X; one undo step |
| Save plots | Live | PlotSaveService + SavePlotSlot | Persistence plotSaves | 4 presets; active slot autosave; SAVE overwrite confirm; LOAD/NEW; wipe undo on load |
| Feed waves | Live | WaveSlot + WaveSim | WaveRoute.A, ReplicatedStorage.Fish.Tang | Client-only solo; Slot5; Tang waves; brain food; reef health |
| RNG coral rolls | Planned | — | — | Common → rare weights |
| Shop / Robux | Planned | — | — | Server grant only |
| Skill tree | Planned | — | — | Persist unlocks; server enforces caps |
| Arena Center coop/PvP | Planned | — | — | `Workspace.Arena.Center` |

## Log tags
Stable prefixes for verification: `[PLOT]`, `[GRID]`, `[PERSIST]`, `[DECOR]`, `[INV]`, `[PLACE]`, `[UI]`.
