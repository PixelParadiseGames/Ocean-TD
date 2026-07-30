# Systems Index

Read [PROJECT_OVERVIEW.md](PROJECT_OVERVIEW.md) first. Then open only the owner + helpers for one system.

Update this file in the **same change** when you add or rename a system. If index and code disagree, fix the index.

| System | Status | Owner | Helpers | Notes |
|--------|--------|-------|---------|-------|
| Bootstrap (server) | Live | `src/ServerScriptService/OceanTD/Bootstrap.server.lua` | wires services below | Join → load → assign → hydrate → ready; leave → snapshot → save → free |
| Bootstrap (client) | Live | `src/StarterPlayerScripts/OceanTD/Bootstrap.client.lua` | `ClientPlot.lua` | Phase 1: mirrors plot bounds only |
| PlotService | Live | `.../Services/PlotService.lua` | `Shared/Constants`, `Shared/GridMath`, `Shared/RingMath` | Master + PreviewBox_1..5; `getDecorFolder`; Bounds fallback |
| DecorReplicator | Live | `.../Services/DecorReplicator.lua` | PlotService poses | Boot: `MasterPlotDecor` → `StaticPlot_2..N` rigid remap |
| RingMath | Live | `src/ReplicatedStorage/OceanTD/Shared/RingMath.lua` | — | Matches ArenaGeneratorPlugin preview formula |
| GridService | Live | `.../Services/GridService.lua` | `Shared/GridMath`, `Shared/PlotTypes` | In-memory cells; hydrate/snapshot only in Phase 1 |
| PersistenceService | Live | `.../Services/PersistenceService.lua` | `Shared/PlotTypes`, `Shared/Constants` | DataStore `OceanTD_Player_v1`; anti-wipe |
| PlayerSession | Live | `.../Services/PlayerSession.lua` | — | `layoutLoaded` gate for saves |
| Remotes | Live | `src/ReplicatedStorage/OceanTD/Remotes.lua` | `RemoteEvents` folder (not named Remotes — avoids ModuleScript name clash) | `PlotAssigned`, `PlotCleared`, `SessionReady` |
| GridMath | Live | `src/ReplicatedStorage/OceanTD/Shared/GridMath.lua` | `Constants` | Cell size 4; plot-local helpers |
| Place / remove coral | Planned | — | — | Server validates; client preview |
| Inventory / backpack | Planned | — | — | Persist counts; UI mirrors server |
| Feed waves | Planned | — | — | Private per plot; satiety end-of-route |
| RNG coral rolls | Planned | — | — | Common → rare weights |
| Shop / Robux | Planned | — | — | Server grant only |
| Skill tree | Planned | — | — | Persist unlocks; server enforces caps |
| Arena Center coop/PvP | Planned | — | — | `Workspace.Arena.Center` |

## Log tags
Stable prefixes for verification: `[PLOT]`, `[GRID]`, `[PERSIST]`, `[DECOR]`.
