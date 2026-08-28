"""
Register Coral Gen for this Blender session AND install it so it survives restarts.

In Blender Scripting workspace:
    exec(open(r"C:\\Game Dev\\Ocean TD\\Blender Addons\\Coral Gen\\enable_coral_gen.py").read())

After this, enable "Coral Gen" under Edit → Preferences → Add-ons if needed.
N-Panel tab: View3D → Sidebar (N) → Procedural Coral
"""

from __future__ import annotations

import importlib
import os
import shutil
import sys

import bpy

ROOT = r"C:\Game Dev\Ocean TD\Blender Addons\Coral Gen"
if "__file__" in dir() and __file__:  # noqa: F821
    try:
        ROOT = os.path.dirname(os.path.abspath(__file__))  # type: ignore[name-defined]
    except Exception:
        pass

SRC = os.path.join(ROOT, "coral_gen.py")
if not os.path.isfile(SRC):
    raise FileNotFoundError(f"coral_gen.py not found at {SRC}")

if ROOT not in sys.path:
    sys.path.insert(0, ROOT)

# --- Session reload ---
if "coral_gen" in sys.modules:
    try:
        import coral_gen as cg

        cg.unregister()
    except Exception as e:
        print(f"[Coral Gen] unregister (ignored): {e}")
    del sys.modules["coral_gen"]

import coral_gen

importlib.reload(coral_gen)
coral_gen.register()
print("[Coral Gen] Registered for this session.")
print(f"[Coral Gen] Root: {ROOT}")

# --- Persist into Blender user addons ---
addons_dir = bpy.utils.user_resource("SCRIPTS", path="addons", create=True)
dest = os.path.join(addons_dir, "coral_gen.py")
try:
    shutil.copy2(SRC, dest)
    print(f"[Coral Gen] Installed → {dest}")
except Exception as e:
    print(f"[Coral Gen] Install copy failed: {e}")
else:
    try:
        bpy.ops.preferences.addon_enable(module="coral_gen")
        print("[Coral Gen] Addon enabled in Preferences.")
    except Exception as e:
        print(f"[Coral Gen] addon_enable (ignored): {e}")
    try:
        bpy.ops.wm.save_userpref()
        print("[Coral Gen] User preferences saved.")
    except Exception as e:
        print(f"[Coral Gen] save_userpref (ignored): {e}")

print("[Coral Gen] Open View3D sidebar (N) → tab 'Procedural Coral'.")
