# AI Hints: Grid, Plots, and Persistence

High-level patterns from a working Roblox placeable system. Use these as **hints**, not a required architecture. Species, planting UX, inventory UI, store, and quickslots will differ—design those for the new game.

---

## Grid

- World space is quantized into cells with a fixed **cell size** and a shared **origin**. Every client and the server must use the same constants or aim and validation will disagree.
- Each cell has a stable string key, typically `"x,y,z"` from rounded integer coordinates.
- Convert with something like:
  - world → grid: round `((world - origin) / cellSize)` per axis
  - grid → world: `origin + grid * cellSize` (ideal cell center)
- The **logical** occupancy/state lives in a server-side map (`key → cell data`). Visuals are derived from that map, not the other way around.
- Placement often stores both:
  - grid coords (for occupancy / lookups)
  - a **visual / surface position** (where the object actually sits on terrain)
- Prefer checking ownership and “is this on my plot?” against the **visual position**, not only the ideal grid center—especially if plots are wedges, circles, or otherwise non-axis-aligned boxes.
- Keep placement rules (empty cell, spacing, caps) on the **server**. The client can preview; the server decides.

---

## Plots

- Each player gets a **plot**: a transform (`CFrame`) + footprint (`Size` or equivalent bounds).
- “Inside plot” is usually an XZ test in plot-local space (`PointToObjectSpace`), ignoring Y or handling height separately.
- Ownership of a planted object = “its position falls in this player’s plot,” not necessarily an Owner attribute on every instance.
- On join: assign (or reclaim) a plot → load that player’s layout into the shared grid inside those bounds → tell the client their plot bounds for previews.
- On leave / server close: snapshot what’s on their plot → clear those cells from the live grid → free the plot for someone else.
- If players can be assigned a **different** plot slot later, persist positions in **plot-local** space so the layout moves with the plot, not absolute world coords from an old session.

---

## Persistence

- Split data if both exist:
  - **Wallet / inventory counts** (seeds, currency, unlocks)
  - **Plot layout** (what’s planted where)
- Layout save shape (conceptually): for each non-ephemeral object on the player’s plot, store enough to rebuild it—at least local position, type/id, and growth or variant state.
- Decide explicitly what is **ephemeral** (never saved; respawns or is temporary) vs **durable**.
- Save when it matters: periodic autosave, on leave, and after bulk layout changes. Don’t invent extra stores without a reason.
- **Load before save:** don’t write a layout snapshot while the player’s plot is still empty mid-load, or you can wipe real data with `{}`.
- **Anti-wipe:** refuse to overwrite a non-empty stored layout with an empty snapshot unless the operation intentionally cleared the plot.
- On load: local → world via current plot `CFrame` → place into the grid with a “from save” path that skips normal player placement gates if needed → restore stage/variant fields after place.
- Prefer `UpdateAsync` (or equivalent compare-and-swap) for layout writes so concurrent/stale empties don’t clobber good data.
- Log before/after counts by type when debugging persistence; it’s cheaper than guessing.

---

## Server vs client (keep this boundary)

- Client: aim, preview/ghost, input, UI that **mirrors** server state.
- Server: validate place, mutate grid, debit costs, persist.
- Replicated counts (e.g. IntValues) should be the only long-lived truth for “how many X the player has.” UIs subscribe; they don’t invent parallel counters.

---

## Flexible on purpose

You are free to change:

- How planting feels (tap, drag, confirm UI, tools, etc.)
- Species / item definitions and IDs
- Store, inventory, and all HUD/quickslot layout
- Whether anything is harvested, traded, or removed another way
- Folder/script names and module split—as long as grid math, plot bounds, and safe load/save stay coherent

When in doubt: **shared grid math, plot-local durable layout, hydration + no accidental empty overwrite** are the parts worth keeping.
