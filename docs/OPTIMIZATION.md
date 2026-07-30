# Optimization Reference

Design for the worst client first. High-end gets extras — not the baseline.

## Three budgets
Track separately: **server CPU**, **client FPS**, **network KB/s**. Solo Studio success ≠ full-server success.

## Remotes
- Never fire remotes every frame.
- Coalesce to events, ≤10 Hz, or state-change only.
- One popular per-frame remote can dominate bandwidth.

## Authority split
- **Client:** previews, camera, cosmetics, local FX.
- **Server:** place, pay, persist, scores, wave outcomes.

## Instances & replication
- Moving replicated parts are expensive; idle recv often tracks movers, not triangles.
- Instance count beats clever meshes on mobile.
- Property/attribute churn replicates — no per-frame Size/CFrame/Color/SetAttribute on widely visible instances; dirty-set + cadence + LOD.
- Streaming is a cost; keep hot spaces compact.

## Simulation
- Batch and throttle; chunk per tick; stagger players; slow/fast loops.
- Spatial partition: O(nearby), not O(everything) — chunks, radii, owner filters.
- Bound Heartbeat work; early-out inactive systems; avoid chatty `FireAllClients`.
- Connect RenderStepped only while needed.

## Population
- Other players’ characters dominate idle net. Compare solo vs full 6.
- Distant plots are low priority vs the plot you stand on.
- Center arena (future) must not force all clients to simulate all combat at full rate.

## DataStores
- Join / leave / autosave only. Stagger. Never save mid-load.

## Feature review checklist
For each feature ask: instances? updates/sec? remotes/sec? who receives them? worst-phone-at-peak?

## LOD
Far = cheaper. Low device = stable FPS over density.
