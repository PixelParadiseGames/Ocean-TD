# Meta Trace — Blender addon (N-panel "Tracer")
# Install: Preferences → Add-ons → Install → zip this folder, or symlink into scripts/addons.
# Dev: use the panel's "Reload Addon" after editing Python.

bl_info = {
    "name": "Meta Trace",
    "author": "Ocean TD",
    "version": (1, 1, 0),
    "blender": (3, 6, 0),
    "location": "View3D > Sidebar > Tracer",
    "description": "MetaGrid live sculpt + Trace scan/build for Image Empty → metaballs",
    "category": "Object",
}

import importlib
import sys
import os

# Sibling scan/build modules live one directory up (Blender Addons/Coral Gen/)
_ADDON_DIR = os.path.dirname(os.path.abspath(__file__))
_ROOT = os.path.dirname(_ADDON_DIR)
if _ROOT not in sys.path:
    sys.path.insert(0, _ROOT)

from . import properties
from . import operators
from . import ui


MODULES = (properties, operators, ui)


def register():
    for mod in MODULES:
        importlib.reload(mod)
        mod.register()


def unregister():
    for mod in reversed(MODULES):
        mod.unregister()


if __name__ == "__main__":
    register()
