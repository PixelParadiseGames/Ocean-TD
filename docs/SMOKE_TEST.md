# Studio smoke checklist (Phase 1)

Run after Rojo is synced and the **plot-stamp plugin** has authored the ring ([STUDIO_CONTRACT.md](STUDIO_CONTRACT.md)).

1. `MasterTerrainBox` exists (Workspace or ServerStorage after Hide).
2. Prefer `TerrainPreviews.PreviewBox_1..5` (same places after Hide).
3. Optional: `MasterPlotDecor` + `StaticPlot_2..6`.
4. `rojo serve` connected; Studio DataStore API enabled for persist tests.

## Solo
1. Play Solo (Hide Previews is fine — boxes may be in ServerStorage).
2. `[PLOT] Init from Master + PreviewBoxes` **or** RingMath fallback.
3. Six `Registered` lines (Plot1 ← Master, Plot2 ← PreviewBox_1, …).
4. Assign / persist / leave as before.

See also [STUDIO_VISIBILITY.md](STUDIO_VISIBILITY.md).

## Two players
1. Start Server + 2 Players.
2. Different plot ids (e.g. Plot1 + Plot2 from Master vs PreviewBox_1).
3. Leave one → slot frees.

## Anti-wipe / empty layout
1. New player leave with empty layout — save OK (`layout=0`).
2. (Phase 2+) Non-empty layout + empty snapshot without intentional clear → `Anti-wipe blocked`.

## Failure signals
- `Need MasterTerrainBox` → spawn previews once so master exists.
- `No free plot` / kick → 7th joiner; expected when full.

## Rojo build check (CLI)
```
rojo build -o OceanTD_CodeBuild.rbxlx
```
Map art still lives in `Ocean TD.rbxl`.
