# Persistence Contract

Sacred and tiny. Species, UI, and shop do **not** belong here.

## Stores
- DataStore name: `OceanTD_Player_v1` (see `Shared/Constants.lua`).
- Key: `u:<userId>`.
- Writes: `UpdateAsync` only for profile saves.

## Profile shape
```lua
{
  version = 1,
  currencies = { sandDollars = 0, gold = 0 },
  inventory = {},
  skillTree = {},
  layout = { -- array of plot-local durable objects; {} OK for new players
    { id = "CoralCommon_A", lx = 0, ly = 0, lz = 0 },
  },
}
```
Session-only flags (`layoutLoaded`) are **never** stored.

## Grid keys
- Cell size: `4` studs (`GridMath.CELL_SIZE`).
- Logical key: `"x,y,z"` from rounded plot-local position / cellSize.
- Live server map scopes by plot: `PlotN:x,y,z`.

## Plot-local layout
- Persist `lx,ly,lz` in **Bounds object space**, not world space.
- On assign: local → world via current plot `Bounds.CFrame`.
- Changing ring slots must not break layouts.

## Hydration order (join)
1. `PersistenceService.load`
2. `PlotService.assign`
3. `GridService.hydrate` (empty layout valid)
4. `PlayerSession.markReady` (`layoutLoaded = true`)
5. Tell client plot bounds

**Never save until step 4.**

## When saves run
- Player leave
- Autosave (~60s), ready sessions only
- `BindToClose`

## Anti-wipe
Refuse to overwrite a **non-empty** stored `layout` with an empty snapshot unless `PersistenceService.allowIntentionalClear(userId)` was set for that write.

## Ephemeral vs durable
| Durable | Ephemeral (Phase 1+) |
|---------|----------------------|
| layout objects, currencies, inventory, skill unlocks | live wave agents, previews, session remotes |

## Logs
`[PERSIST] Load/Save ... layout=N` — trust counts over guesswork.
