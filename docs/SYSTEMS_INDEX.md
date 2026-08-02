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
| PersistenceService | Live | `.../Services/PersistenceService.lua` | `Shared/PlotTypes`, `Shared/Constants` | DataStore `OceanTD_Player_v1`; anti-wipe |
| PlayerSession | Live | `.../Services/PlayerSession.lua` | — | `layoutLoaded` gate for saves |
| Remotes | Live | `src/ReplicatedStorage/OceanTD/Remotes.lua` | `RemoteEvents` folder (not named Remotes — avoids ModuleScript name clash) | `PlotAssigned`, `PlotCleared`, `SessionReady`, `RequestPlace` / `RequestMove` / `RequestRecycle` / `RequestUndo` (RF) |
| GridMath | Live | `src/ReplicatedStorage/OceanTD/Shared/GridMath.lua` | `Constants` | Cell size 4; plot-local helpers |
| InventoryUI | Live | `src/StarterPlayerScripts/OceanTD/InventoryUI.client.lua` | `InventoryState`, `PlacementController`, ItemCatalog, UiCircles | Slot4 backpack; Slot3 undo; drag-scroll; drag-out place |
| InventoryState | Live | `src/StarterPlayerScripts/OceanTD/InventoryState.lua` | ItemCatalog | Open + selected; close clears selection and ends place |
| ItemCatalog | Live | `src/ReplicatedStorage/OceanTD/Shared/ItemCatalog.lua` | SpeciesCatalog via `speciesId` | BrainCoral first; register new items here |
| SpeciesCatalog | Live | `src/ReplicatedStorage/OceanTD/Shared/SpeciesCatalog.lua` | — | Visual/place rules (diameter, color range, material) |
| CoralVisual | Live | `src/ReplicatedStorage/OceanTD/Shared/CoralVisual.lua` | SpeciesCatalog | Ball factory; ghost tint; no shadow |
| PlacementService | Live | `.../Services/PlacementService.lua` | GridService, PlotService, CoralVisual, UndoService | Server place/move/recycle; hydrate `OceanTD_Placed`; undoLast; no debit yet |
| UndoService | Live | `.../Services/UndoService.lua` | PlacementService (via push) | Session-only stack (max 10); place/move/recycle; cleared on leave |
| PlacementController | Live | `src/StarterPlayerScripts/OceanTD/PlacementController.lua` | ClientPlot, CoralVisual, InventoryState | Confirm-ghost ✓/X; freeze avatar/camera |
| PlacementBootstrap | Live | `src/StarterPlayerScripts/OceanTD/PlacementBootstrap.client.lua` | PlacementController | Requires controller on client boot |
| UiTheme | Live | `src/ReplicatedStorage/OceanTD/Shared/UiTheme.lua` | — | Default font FredokaOne for generated UI text |
| ForceLandscape | Live | `src/StarterPlayerScripts/OceanTD/ForceLandscape.client.lua` | — | Landscape only; no portrait mobile |
| Remove coral | Live | PlacementService.recycle + RelocateController | GridService, UndoService | Recycle credits seed; Slot3/Z/L2 undoes |
| Feed waves | Planned | — | — | Private per plot; satiety end-of-route |
| RNG coral rolls | Planned | — | — | Common → rare weights |
| Shop / Robux | Planned | — | — | Server grant only |
| Skill tree | Planned | — | — | Persist unlocks; server enforces caps |
| Arena Center coop/PvP | Planned | — | — | `Workspace.Arena.Center` |

## Log tags
Stable prefixes for verification: `[PLOT]`, `[GRID]`, `[PERSIST]`, `[DECOR]`, `[INV]`, `[PLACE]`, `[UI]`.
