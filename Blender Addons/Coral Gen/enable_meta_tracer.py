"""
One-shot: register Meta Trace from this repo path (no Preferences install needed for this session).

In Blender Scripting:
    exec(open(r"C:\\Game Dev\\Ocean TD\\Blender Addons\\Coral Gen\\enable_meta_tracer.py").read())
"""

from __future__ import annotations

import importlib
import os
import sys

# Works both as imported module and via exec(open(...).read())
ROOT = r"C:\Game Dev\Ocean TD\Blender Addons\Coral Gen"
if "__file__" in dir() and __file__:  # noqa: F821
    try:
        ROOT = os.path.dirname(os.path.abspath(__file__))  # type: ignore[name-defined]
    except Exception:
        pass

if ROOT not in sys.path:
    sys.path.insert(0, ROOT)

if "meta_tracer" in sys.modules:
    try:
        import meta_tracer as mt

        mt.unregister()
    except Exception:
        pass
    for key in list(sys.modules):
        if key == "meta_tracer" or key.startswith("meta_tracer."):
            del sys.modules[key]

import meta_tracer

meta_tracer.register()
print("[Meta Trace] Registered. Open View3D sidebar → Tracer tab.")
print(f"[Meta Trace] Root: {ROOT}")
