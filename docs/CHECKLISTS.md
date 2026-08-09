# Checklists

Follow these when doing repeating work. Do not invent a parallel data path.

## New persist field
1. Add field to `PlotTypes.defaultProfile` + `PersistenceService.sanitizeProfile` / save payload.
2. Document in [PERSISTENCE_CONTRACT.md](PERSISTENCE_CONTRACT.md) if it is durable contract.
3. Load before any feature reads it; never default-write mid-load.
4. Update [SYSTEMS_INDEX.md](SYSTEMS_INDEX.md) if a new owner appears.
5. Add a failure-mode row if misuse can wipe or clobber data.

## New backpack / catalog item (UI)
1. Add def to `Shared/ItemCatalog.lua` (`id`, `displayName`, `icon`, `category`, `sortOrder`, `speciesId`).
2. Add matching species to `Shared/SpeciesCatalog.lua` (diameter, colors, material, shadow/collide).
3. Icon shows in Slot4 backpack grid automatically on rebuild; placement uses `speciesId` → CoralVisual.
4. Update SYSTEMS_INDEX only if a new owner script appears.
5. Persist counts later via PersistenceService + checklist “New persist field”.

## New remote
1. Add name to `Remotes.lua` list.
2. Server fires ≤ event/cadence policy ([OPTIMIZATION.md](OPTIMIZATION.md)).
3. Client mirrors only — no parallel authority.
4. Note owner system in SYSTEMS_INDEX.

## New system
1. One owner script + named helpers.
2. Row in SYSTEMS_INDEX (same PR/change).
3. Log tag if it will be debugged often.
4. Ask before exploring unrelated systems.

## Change plot count / size
1. Update plugin stamp settings and `Constants.MAX_PLOTS` / `PLOT_COUNT` together.
2. Confirm `RingMath` matches plugin rotation (Y around `Arena.Center`).
3. Re-stamp terrain; refresh `StaticPlot_2..N` décor clones.
4. Recheck spawn offsets authored on plot 1.
5. Smoke-test assign on plot 1 and a non-1 slot.

## Change plot frame / placement math
1. Read `Shared/PlotFrameContract.lua` — do **not** reintroduce TerrainPlotAlign or PreviewBox live poses.
2. Runtime poses = Master + `RingMath` + `ExpansionOffset` only.
3. Layout stays plot-local VisualPos; restore = `PointToWorldSpace` (no re-raycast).
4. Boot must log `contractOk= true`; fix Studio stamp if islands disagree.
5. Add a FAILURE_MODES row if a new frame source can drift across boots.
