"""
Local Meta Shape Tracer — scan → preview → build (no AI required).

Usage in Blender Scripting (Text Editor), with this folder on sys.path:

    import sys
    sys.path.insert(0, r"C:\\Game Dev\\Ocean TD\\Blender Addons\\Coral Gen")

    import trace_shape as ts
    ts.scan("FireCoral")    # writes Traces/FireCoral_trace.json + preview.png
    ts.build("FireCoral")   # places FireCoral_Meta from JSON only
    # or:
    ts.run("FireCoral")     # scan then build

Inspect Traces/FireCoral_preview.png before/after tweaking knobs.
"""

from __future__ import annotations

import os
import sys

_DIR = os.path.dirname(os.path.abspath(__file__))
if _DIR not in sys.path:
    sys.path.insert(0, _DIR)

from scan_shape import scan as _scan
from build_metaballs import build as _build
from shape_trace_io import preview_png_path, trace_json_path, DEFAULTS


def scan(empty_name: str = "FireCoral", **kwargs) -> str:
    """Scan Image Empty → JSON + preview. Does not place metas."""
    return _scan(empty_name, **kwargs)


def build(empty_name: str = "FireCoral", meta_object_name: str | None = None, **kwargs) -> int:
    """Build metas from existing JSON only."""
    return _build(empty_name, meta_object_name=meta_object_name, **kwargs)


def run(empty_name: str = "FireCoral", **kwargs) -> tuple[str, int]:
    """Scan then build. Extra kwargs go to scan (threshold, r_tip, …)."""
    build_keys = {"threshold", "resolution", "clear", "meta_object_name"}
    scan_kw = {k: v for k, v in kwargs.items() if k not in build_keys}
    build_kw = {k: v for k, v in kwargs.items() if k in build_keys}
    path = scan(empty_name, **scan_kw)
    n = build(empty_name, **build_kw)
    return path, n


def paths(empty_name: str = "FireCoral") -> dict[str, str]:
    return {
        "json": trace_json_path(empty_name),
        "preview": preview_png_path(empty_name),
        "defaults": str(DEFAULTS),
    }


if __name__ == "__main__":
    run("FireCoral")
