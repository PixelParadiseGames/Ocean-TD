# Coral Gen / Meta Trace — Blender addons

Home for procedural coral and metaball tracing tools.

**Path:** `C:\Game Dev\Ocean TD\Blender Addons\Coral Gen`

Fire Coral mesh exports (FBX) live in `Models\Fire Coral\Exports\` — not here.

## Enable Coral Gen (procedural L-system)

In Blender Scripting:

```python
exec(open(r"C:\Game Dev\Ocean TD\Blender Addons\Coral Gen\enable_coral_gen.py").read())
```

Then: **3D View → N → Procedural Coral**.

Workflow: Growth/Shape knobs → **Generate Preview** → **Finalize to Mesh** → **Clear**.

## Enable Meta Trace (Image Empty → metaballs)

```python
exec(open(r"C:\Game Dev\Ocean TD\Blender Addons\Coral Gen\enable_meta_tracer.py").read())
```

Then: **3D View → N → Tracer**.

## Layout

| File / folder | Role |
|---|---|
| `coral_gen.py` | Procedural Coral Gen addon |
| `enable_coral_gen.py` | Session register + install Coral Gen |
| `meta_tracer/` | Meta Trace N-panel addon |
| `enable_meta_tracer.py` | Session register Meta Trace |
| `meta_grid.py`, `scan_shape.py`, `build_metaballs.py`, … | Trace/scan helpers used by Meta Trace |
| `Traces/` | Debug / scan preview images |
