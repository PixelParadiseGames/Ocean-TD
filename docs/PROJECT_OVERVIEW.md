# Ocean TD — Project Overview

Underwater tower defense with an inverse loop: you **feed** waves of ocean life by rebuilding a barren coral reef, not destroy enemies.

## Fantasy
Each player owns a bleached reef plot. Place corals, sponges, and reef critters so passing fish leave **satisfied**. Satisfied routes keep waves going; hungry routes stall progress. Build symbiotic density, not kill corridors.

## Arena
- **6 plots** in a ring around a shared center.
- Soft-shared multiplayer: private layout, waves, and economy per plot. Neighbors are visible; no stealing Phase 1 systems.
- **`Workspace.Arena.Center`** reserved for future coop / PvP (not built yet).

## Currencies
| Name | Role |
|------|------|
| **$D Sand Dollars** | Common currency (persistent; Robux packs; HUD `MobileLeftUI.dPad.$DCount`) |
| **Gold** | Rare currency |
| **Robux** | Shop / packs (later) |

## Persistence
Inventory, currencies, skill tree stubs, and **plot-local layout** survive across sessions. See [PERSISTENCE_CONTRACT.md](PERSISTENCE_CONTRACT.md).

## How to work in this repo
1. Read this overview.
2. Open [SYSTEMS_INDEX.md](SYSTEMS_INDEX.md) for the system you need.
3. Open only the 2–4 scripts listed there.
4. Do not broad-scan the tree unless the index is missing or wrong — then fix the index.

Seeing Studio vs Rojo limits: [STUDIO_VISIBILITY.md](STUDIO_VISIBILITY.md).

Prior-game placement hints (non-authoritative): [AI_HINTS_GRID_PLOT_PERSISTENCE.md](AI_HINTS_GRID_PLOT_PERSISTENCE.md).

## Tooling
- Place file: `Ocean TD.rbxl` (map art lives here; not overwritten by Rojo).
- Code: Rojo via `default.project.json` → `rojo serve` into Studio with the Rojo plugin.
- Install toolchain: `aftman install` then `rojo serve`.

## Studio setup (required once)
See [STUDIO_CONTRACT.md](STUDIO_CONTRACT.md) — place **`MasterTerrainBox`**, run plugin Spawn/Update Previews (`PreviewBox_1..5`), stamp, then Hide (keep instances). No Arena.Center.  
Décor: `MasterPlotDecor` (plot 1) + `StaticPlot_2..6`. Mapping: Master→Plot1, PreviewBox_i→Plot_(i+1).  
Smoke: [SMOKE_TEST.md](SMOKE_TEST.md).

## Phase
**Phase 3 (current):** client feed-wave prototype on Slot5; Phase 1–2 groundwork + place/inventory largely live.
Later phases: [ROADMAP.md](ROADMAP.md).
