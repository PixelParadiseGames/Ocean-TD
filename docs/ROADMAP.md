# Roadmap

Ordered. Do not invent parallel data paths when a later phase lands — extend the owner in [SYSTEMS_INDEX.md](SYSTEMS_INDEX.md).

## Phase 1 — Groundwork ✅
- Rojo scaffold into existing `Ocean TD.rbxl`
- Docs + Cursor rules
- 6-slot plot assign + client bounds mirror
- Empty layout persistence + anti-wipe

## Phase 2 — Place + inventory ✅ (mostly)
- Backpack UI (Slot4) + ItemCatalog — **live**
- Confirm-ghost place (✓/X) + server validate/occupy/visual — **live** (place debits seeds)
- Remove coral / backpack counts (replicated mirrors) — recycle + session undo (Slot3 / Z / L2) **live**; clear plot (Slot2 / C / R3, full seed refund, one undo step) **live**; save plots (Slot1 / V / L3, 4 presets, active-slot autosave) **live**; client inventory count mirrors still open
- Max placed cap stub (skill tree later)

## Phase 3 — Feed waves ← **current**
- **Live (client prototype):** Slot5 start/stop, `WaveRoute.A` Tang waves, local coral food, reef health, summary UI
- Player-triggered waves on **own** plot only (solo client sim; server authority later)
- Path through reef; satiety from nearby coral nutrition; empty bars at exit damage reef
- Reward $D later; no per-frame remotes for agents (batch / owner-only)

## Phase 4 — RNG rolls
- Roll / autoroll for common → rare coral types
- Costs $D or tickets; server RNG; inventory grants

## Phase 5 — Shop / Robux
- Gold + Robux products: packs, powerups, critters
- Server grant only; receipt validation

## Phase 6 — Skill tree
- Permanent unlocks: luck, plot size, income, coral tiers, max placed
- Persist in `skillTree`; enforce on server

## Phase 7 — Arena center coop / PvP
- Use `Workspace.Arena.Center`
- Shared activity without merging private plot economies by default

## Explicit non-goals until scheduled
Trading between plots, cross-plot wave griefing, rewriting persistence keys without a migration plan.
