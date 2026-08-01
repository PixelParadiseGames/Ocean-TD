# Roadmap

Ordered. Do not invent parallel data paths when a later phase lands — extend the owner in [SYSTEMS_INDEX.md](SYSTEMS_INDEX.md).

## Phase 1 — Groundwork (current)
- Rojo scaffold into existing `Ocean TD.rbxl`
- Docs + Cursor rules
- 6-slot plot assign + client bounds mirror
- Empty layout persistence + anti-wipe

## Phase 2 — Place + inventory
- Backpack UI (Slot4) + ItemCatalog — **live**
- Confirm-ghost place (✓/X) + server validate/occupy/visual — **live** (infinite Brain Coral, no debit)
- Remove coral / backpack counts (replicated mirrors)
- Max placed cap stub (skill tree later)

## Phase 3 — Feed waves
- Player-triggered waves on **own** plot only
- Path through reef; satiety from nearby coral/sponge/critter nutrition
- Full at route end → success / continue; hungry → fail pressure
- Reward $D; no per-frame remotes for agents (batch / owner-only)

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
