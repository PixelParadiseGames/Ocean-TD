# Seeing Studio from Cursor

Rojo syncs **code** (`src/`) → Studio. It does **not** pull Workspace map art / plot boxes back into the repo.

## What works today
- **Plugin source in repo:** [`plugins/ArenaGeneratorPlugin.lua`](../plugins/ArenaGeneratorPlugin.lua) — read Hide/stamp/ring math anytime.
- **Place file on disk:** save `Ocean TD.rbxl` (or `.rbxlx`) in the project folder after map changes; Cursor can scan it.
- **Chat only when needed:** paste Output lines for a specific Part — avoid for routine work.

## Deferred
A Studio “dump to `studio-snapshots/`” plugin was considered and **held off** — not installed, not required.

## Plot contract (from ArenaGeneratorPlugin)
| Logical | Instance | After Hide |
|---------|----------|------------|
| Plot1 | `MasterTerrainBox` | `ServerStorage.MasterTerrainBox` |
| Plot2–6 | `TerrainPreviews.PreviewBox_1..5` | `ServerStorage.TerrainPreviews` |
