# Studio smoke checklist (Phase 1)

Run after Rojo is synced and the **plot-stamp plugin** has authored the ring ([STUDIO_CONTRACT.md](STUDIO_CONTRACT.md)).

1. `MasterTerrainBox` exists (Workspace or ServerStorage after Hide) with `ExpansionOffset` from last Spawn/Update Previews.
2. Optional: `MasterPlotDecor` + `StaticPlot_2..6`.
3. `rojo serve` connected; Studio DataStore API enabled for persist tests.

## Solo
1. Play Solo (Hide Previews is fine — Master may be in ServerStorage).
2. `[PLOT] Init from Master + RingMath (stable; no TerrainPlotAlign)`.
3. Six `Registered` lines (Plot1 ← Master, Plot2..N ← RingMath).
4. Place coral → leave → rejoin: same world spot (no radial slide). Path remap should match.

See also [STUDIO_VISIBILITY.md](STUDIO_VISIBILITY.md).

## Two players
1. Start Server + 2 Players.
2. Different plot ids (e.g. Plot1 + Plot2).
3. Leave one → slot frees.

## Anti-wipe / empty layout
1. New player leave with empty layout — save OK (`layout=0`).
2. (Phase 2+) Non-empty layout + empty snapshot without intentional clear → `Anti-wipe blocked`.

## Place Brain Coral (Phase 2)
1. Slot4 → backpack → tap Brain Coral (or drag out on mobile).
2. Avatar/camera freeze; green/red ghost; “Out Of Plot” / “Spot Taken” when invalid.
3. Click/tap world → ✓ / X confirm; ✓ places yellow–orange pebble ball (half buried, no shadow).
4. Esc or X (from aim) exits; leave → `[PERSIST]` save; rejoin → visuals hydrate under `OceanTD_Placed`.
5. TEMP: `TEMP_BRAIN_CORAL_SLOT_COUNT` in InventoryUI — set `0` for single catalog row.

## Failure signals
- `Need MasterTerrainBox` → spawn previews once so master exists.
- `No free plot` / kick → 7th joiner; expected when full.

## Rojo build check (CLI)
```
rojo build -o OceanTD_CodeBuild.rbxlx
```
Map art still lives in `Ocean TD.rbxl`.
