# Systems Index

Read [PROJECT_OVERVIEW.md](PROJECT_OVERVIEW.md) first. Then open only the owner + helpers for one system.

Update this file in the **same change** when you add or rename a system. If index and code disagree, fix the index.

| System | Status | Owner | Helpers | Notes |
|--------|--------|-------|---------|-------|
| Bootstrap (server) | Live | `src/ServerScriptService/OceanTD/Bootstrap.server.lua` | wires services below | Join → load → assign → hydrate → ready; leave → snapshot → save → free |
| Bootstrap (client) | Live | `src/StarterPlayerScripts/OceanTD/Bootstrap.client.lua` | `ClientPlot.lua` | Mirrors plot bounds; SessionReady |
| PlotService | Live | `.../Services/PlotService.lua` | `Shared/Constants`, `Shared/GridMath`, `Shared/RingMath` | Master + RingMath poses (no PreviewBox / no voxel align); random first assign; later joins seat beside occupied |
| WaveHeartReplicator | Live | `.../Services/WaveHeartReplicator.lua` | PlotService poses, WaveRoute.A.EndPoint | Clones end heart onto Plot2..N via rigid Plot1→slot remap |
| DecorReplicator | Live | `.../Services/DecorReplicator.lua` | PlotService poses | Boot: `MasterPlotDecor` → `StaticPlot_2..N` via rigid Plot1→slot remap |
| TerrainPlotAlign | Deprecated | `src/ReplicatedStorage/OceanTD/Shared/TerrainPlotAlign.lua` | — | No-op stub; do not use for persistence (per-boot XZ nudge broke leave/rejoin) |
| RingMath | Live | `src/ReplicatedStorage/OceanTD/Shared/RingMath.lua` | — | Matches ArenaGeneratorPlugin preview formula; sole runtime Plot2..N pose source |
| GridService | Live | `.../Services/GridService.lua` | `Shared/GridMath`, `Shared/PlotTypes` | In-memory cells; `tryOccupy` / hydrate / snapshot |
| PersistenceService | Live | `.../Services/PersistenceService.lua` | `Shared/PlotTypes`, `Shared/Constants` | DataStore `OceanTD_Player_v1`; anti-wipe; `plotSaves` 1–4 + activeIndex; $D wallet + receipt merge |
| $D / sand dollars | Live | `SandDollarHud.client.lua` + `EconomyService.lua` | Persistence `currencies.sandDollars`, `processedReceipts`, `SandDollarProducts` | HUD `MobileLeftUI.dPad.$DCount`; Robux ProcessReceipt only; never client-grant |
| PlotSaveService | Live | `.../Services/PlotSaveService.lua` | Persistence, Placement, Undo, Grid | Manual save/load/NEW/rename; load wipes undo; autosave targets active slot |
| PlayerSession | Live | `.../Services/PlayerSession.lua` | — | `layoutLoaded` gate for saves |
| Remotes | Live | `src/ReplicatedStorage/OceanTD/Remotes.lua` | `RemoteEvents` folder (not named Remotes — avoids ModuleScript name clash) | Includes `RequestUnlockSkillStage`, `RequestGetSkillStages`, `SkillStagesSync` |
| Plot outline | Live | `PlotOutlineColor.client.lua` | `PlotOutlineColors`, `PlotOutlineWire`, ClientPlot, Persistence `plotOutlineColorIndex` | Neon OBB in `PlayerPlotPropertyLines`; bottom hint bar (3s + leave/return); `PlotOutlineColorPopup` ‹› + Done |
| Plot neighbor visuals | Live | `PlotNeighborVisuals.client.lua` | PlotRoster, PlotOutlineWire | Thinner white wireframes in `OtherPlayersPlotVisuals`; skips own plot |
| GridMath | Live | `src/ReplicatedStorage/OceanTD/Shared/GridMath.lua` | `Constants` | Cell size 4; plot-local helpers |
| InventoryUI | Live | `src/StarterPlayerScripts/OceanTD/InventoryUI.client.lua` | `InventoryState`, `PlacementController`, `SavePlotSlot`, `ClearPlotSlot`, `UndoSlot`, `WaveSlot`, `SkipWaveSlot`, ItemCatalog, UiCircles | Slot4 backpack; mounts Slot1–3 + Slot5–6 waves; drag-scroll; drag-out place |
| SavePlotSlot | Live | `src/StarterPlayerScripts/OceanTD/SavePlotSlot.lua` | InventoryState, Remotes | Slot1 save UI / 2×2 presets / L3·V; blue `#0073ed` help |
| ClearPlotSlot | Live | `src/StarterPlayerScripts/OceanTD/ClearPlotSlot.lua` | ClearPlotVfx, InventoryState | Slot2 clear-plot UI / confirm / shortcuts |
| UndoSlot | Live | `src/StarterPlayerScripts/OceanTD/UndoSlot.lua` | Remotes RequestUndo | Slot3 undo UI / cycle / Z/L2 while backpack open |
| WaveSlot | Live | `src/StarterPlayerScripts/OceanTD/WaveSlot.lua` | WaveSim, WaveWatchMode | Slot5 start/stop waves; R/ButtonX; green help; summary + confetti; red watch stroke |
| SkipWaveSlot | Live | `src/StarterPlayerScripts/OceanTD/SkipWaveSlot.lua` | WaveSim, InventoryState, WaveWatchMode | Slot6 skip (slides under Slot5); Z/L2 when backpack closed; confirm popup; watch chrome |
| WaveSpeedSlot | Live | `src/StarterPlayerScripts/OceanTD/WaveSpeedSlot.lua` | WaveSim, WaveWatchMode | Slot7 wave speed 1×/1.5×/2×; T/L2; watch chrome |
| WaveWatch | Live | WaveWatchHost/Visitor + WaveGhostSim + WaveWatchHud + WaveWatchService | WaveSim, PlotRoster, WaveWatchPush | Spectate host plot; own center HUD + slots; host strip bottom-right with name |
| WaveSign | Live | `src/StarterPlayerScripts/OceanTD/WaveSign.lua` | WaveSim, ClientPlot, Persistence highestWave | Plot “Current Wave Sign”: live Wave N / idle all-time high |
| InventoryState | Live | `src/StarterPlayerScripts/OceanTD/InventoryState.lua` | ItemCatalog | Open + selected; clear-plot + save-plots modal gates |
| ItemCatalog | Live | `src/ReplicatedStorage/OceanTD/Shared/ItemCatalog.lua` | SpeciesCatalog via `speciesId` | BrainCoral first; register new items here |
| SpeciesCatalog | Live | `src/ReplicatedStorage/OceanTD/Shared/SpeciesCatalog.lua` | — | Visual/place rules (diameter, color range, material) |
| CoralVisual | Live | `src/ReplicatedStorage/OceanTD/Shared/CoralVisual.lua` | SpeciesCatalog | Ball factory; ghost tint; no shadow |
| PlacementService | Live | `.../Services/PlacementService.lua` | GridService, PlotService, CoralVisual, UndoService | Server place (debit) / move / recycle / clearPlot / applyLayout; hydrate; undoLast |
| UndoService | Live | `.../Services/UndoService.lua` | PlacementService (via push) | Session-only stack (max 10); cleared on leave and on plot-save load |
| PlacementController | Live | `src/StarterPlayerScripts/OceanTD/PlacementController.lua` | ClientPlot, CoralVisual, InventoryState | Confirm-ghost ✓/X; freeze avatar/camera |
| ClearPlotVfx | Live | `src/StarterPlayerScripts/OceanTD/ClearPlotVfx.lua` | InventoryState scroll center | Local clear FX: light, green wave, hand +N, fly to backpack |
| PlacementBootstrap | Live | `src/StarterPlayerScripts/OceanTD/PlacementBootstrap.client.lua` | PlacementController | Requires controller on client boot |
| UiIdleCycle | Live | `src/ReplicatedStorage/OceanTD/Shared/UiIdleCycle.lua` | — | Shared delay+dirty idle toggles / sequences (slots, close label) |
| ForceLandscape | Live | `src/StarterPlayerScripts/OceanTD/ForceLandscape.client.lua` | — | Landscape only; no portrait mobile |
| MobileSkillsB | Live | `src/StarterPlayerScripts/OceanTD/MobileSkillsB.client.lua` | `SkillsBubbleSim`, `SkillPowerUpUI`, Studio `MobileLeftUI.dPad.Skills`, `MobileSkillsB` | Toggle skills; pulsing X/B close; gamepad focus; skill bubbles open power-up |
| Skill power-up stages | Live | `SkillPowerUpUI.lua` | `SkillStages`, Persistence `skillStages`, PowerUpTemplate | Per-skill stages 1–8; rebind template; $D unlock (0 for test); CloseBTN hides popup only |
| Plot Size grow | Live | `PlotSizeCinematic.lua` | `MasterPlotDecor.PlotSizes` templates, PlotService size | Unlock → cam ChangeSizeCam/Focus 1s → footprint tween → cam back 1s; join applies stage size |
| SkillsBubbleSim | Live | `src/StarterPlayerScripts/OceanTD/SkillsBubbleSim.lua` | MobileSkillsB, SkillStages | Soft bubbles for PlotSize/EarnMore/PlaceMore BTNs only |
| PlotFrameContract | Live | `src/ReplicatedStorage/OceanTD/Shared/PlotFrameContract.lua` | RingMath, PlotService | Forbids runtime plot CFrame calibrate; boot drift check |
| PlacedCoralIndex | Live | `src/StarterPlayerScripts/OceanTD/PlacedCoralIndex.lua` | ClientPlot, GridMath | Client grid index of `OceanTD_Placed`; place/relocate/wave gather |
| WaveEntityPool | Live | `src/StarterPlayerScripts/OceanTD/WaveEntityPool.lua` | `ReplicatedStorage.Fish.*`, GreenArrows | Typed acquire/release for Tang (+ future kinds), food, arrows, ammo, SFX |
| Remove coral | Live | PlacementService.recycle + RelocateController | GridService, UndoService | Recycle credits seed; Slot3/Z/L2 undoes |
| Clear plot | Live | PlacementService.clearPlot + InventoryUI Slot2 | ClearPlotVfx, UndoService | Full seed refund; Slot2/C/R3 + ✓/X; one undo step |
| Save plots | Live | PlotSaveService + SavePlotSlot | Persistence plotSaves | 4 presets; active slot autosave; SAVE overwrite confirm; LOAD/NEW; wipe undo on load |
| Feed waves | Live | WaveSlot + SkipWaveSlot + WaveSim + WaveWatch | WaveRoute.A, Tang, GreenArrows, PlotRoster, WaveFeedPayout | Solo client sim; hunger-full → `ReportFishFed` → $D (EarnMore ×); visitors get sparse ghost + HUD on host plot |
| RNG coral rolls | Planned | — | — | Common → rare weights |
| Shop / Robux | Live ($D packs) | `EconomyService.lua` | `SandDollarProducts`, Persistence receipts | Paste product IDs in `SandDollarProducts.lua`; ProcessReceipt grants $D |
| Skill tree | Planned | — | — | Persist unlocks; server enforces caps |
| Arena Center coop/PvP | Planned | — | — | `Workspace.Arena.Center` |

## Log tags
Stable prefixes for verification: `[PLOT]`, `[GRID]`, `[PERSIST]`, `[DECOR]`, `[INV]`, `[PLACE]`, `[UI]`.
