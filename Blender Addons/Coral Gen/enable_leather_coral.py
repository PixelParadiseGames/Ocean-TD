"""
Register Leather Coral scatter addon for this Blender session.

    exec(open(r"C:\Game Dev\Ocean TD\Blender Addons\Coral Gen\enable_leather_coral.py").read())

Sidebar: View3D → N → Procedural Coral → Leather Coral
"""

from __future__ import annotations

import importlib
import os
import sys

import bpy

ROOT = r"C:\Game Dev\Ocean TD\Blender Addons\Coral Gen"
if "__file__" in dir() and __file__:
    try:
        ROOT = os.path.dirname(os.path.abspath(__file__))
    except Exception:
        pass

if ROOT not in sys.path:
    sys.path.insert(0, ROOT)

# Safe unregister
if "leather_coral" in sys.modules:
    try:
        import leather_coral as lc

        lc.unregister()
    except Exception as e:
        print(f"[Leather Coral] unregister (ignored): {e}")
    del sys.modules["leather_coral"]

import leather_coral

importlib.reload(leather_coral)
leather_coral.register()

# Optional cleanup after crash (thousands of LeatherPolyp_* objects)
removed = 0
for obj in list(bpy.data.objects):
    if obj.name.startswith("LeatherPolyp_"):
        bpy.data.objects.remove(obj, do_unlink=True)
        removed += 1
if removed:
    print(f"[Leather Coral] Removed {removed} leftover generated polyps")

s = bpy.context.scene.leather_coral
base = bpy.data.objects.get("Base")
polyp = bpy.data.objects.get("Polyp") or bpy.data.objects.get("Polpy")
col = bpy.data.collections.get("Leather Coral")
if base:
    s.base_object = base
if polyp:
    s.polyp_object = polyp
if col:
    s.target_collection = col
if s.spacing < 0.12:
    s.spacing = 0.35
s.max_polyps = min(getattr(s, "max_polyps", 500) or 500, 500)
# Reset variation sliders to neutral (user adds jitter as needed).
s.spacing_random = 0.0
s.position_jitter = 0.0
s.rot_jitter_x = 0.0
s.rot_jitter_y = 0.0
s.rot_jitter_z = 0.0
s.size_jitter = 0.0
s.coverage_random = 0.0
s.polyp_scale = 1.0

print("[Leather Coral] Registered. N-panel → Procedural Coral → Leather Coral")
