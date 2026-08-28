"""
JSON schema helpers for meta shape traces.

Trace file: Traces/<name>_trace.json
Preview:    Traces/<name>_preview.png
"""

from __future__ import annotations

import json
import os
from typing import Any

TRACE_VERSION = 1

# Default meta / scan knobs (overridable per scan)
DEFAULTS = {
    "threshold": 2.1,
    "stiffness": 2.0,
    "resolution": 0.13,
    "r_tip": 0.05,
    "r_trunk": 0.85,
    "depth_local": 0.0,
    "min_blob_px": 40,
    "keep_components": 1,
    "mask_step": 2,
    # Line-art / density / thickness (UI-facing)
    "line_art": True,
    "mask_luminance": 0.88,
    "grid_density": 1.0,
    "thickness_mult": 1.0,
}


def package_dir() -> str:
    return os.path.dirname(os.path.abspath(__file__))


def traces_dir() -> str:
    d = os.path.join(package_dir(), "Traces")
    os.makedirs(d, exist_ok=True)
    return d


def trace_json_path(name: str) -> str:
    return os.path.join(traces_dir(), f"{name}_trace.json")


def preview_png_path(name: str) -> str:
    return os.path.join(traces_dir(), f"{name}_preview.png")


def empty_trace(
    source: str,
    plane_width: float,
    plane_height: float,
    meta_defaults: dict[str, float] | None = None,
) -> dict[str, Any]:
    md = dict(DEFAULTS)
    if meta_defaults:
        md.update(meta_defaults)
    return {
        "version": TRACE_VERSION,
        "source": source,
        "plane": {"width": float(plane_width), "height": float(plane_height)},
        "meta_defaults": {
            "threshold": float(md["threshold"]),
            "stiffness": float(md["stiffness"]),
            "resolution": float(md["resolution"]),
            "r_tip": float(md["r_tip"]),
            "r_trunk": float(md["r_trunk"]),
            "depth_local": float(md["depth_local"]),
            "line_art": bool(md.get("line_art", True)),
            "mask_luminance": float(md.get("mask_luminance", 0.88)),
            "grid_density": float(md.get("grid_density", 1.0)),
            "thickness_mult": float(md.get("thickness_mult", 1.0)),
        },
        "elements": [],
        "forbidden_pairs": [],
    }


def validate_trace(data: Any) -> dict[str, Any]:
    if not isinstance(data, dict):
        raise ValueError("Trace must be a JSON object")
    if int(data.get("version", 0)) != TRACE_VERSION:
        raise ValueError(f"Unsupported trace version: {data.get('version')}")
    if not isinstance(data.get("source"), str) or not data["source"]:
        raise ValueError("Trace missing source name")
    plane = data.get("plane")
    if not isinstance(plane, dict):
        raise ValueError("Trace missing plane")
    if "width" not in plane or "height" not in plane:
        raise ValueError("Trace plane needs width and height")
    elems = data.get("elements")
    if not isinstance(elems, list):
        raise ValueError("Trace elements must be a list")
    for i, el in enumerate(elems):
        if not isinstance(el, dict):
            raise ValueError(f"Element {i} must be an object")
        typ = el.get("type")
        if typ not in ("BALL", "CAPSULE", "ELLIPSOID"):
            raise ValueError(f"Element {i} bad type: {typ}")
        for key in ("u", "v", "radius"):
            if key not in el:
                raise ValueError(f"Element {i} missing {key}")
        if typ == "CAPSULE" and "length" not in el and "angle" not in el:
            # length + angle preferred; allow size_x
            if "size_x" not in el:
                raise ValueError(f"CAPSULE {i} needs length+angle or size_x")
    data.setdefault("forbidden_pairs", [])
    data.setdefault("meta_defaults", dict(DEFAULTS))
    return data


def write_trace(name: str, data: dict[str, Any]) -> str:
    validate_trace(data)
    path = trace_json_path(name)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    return path


def read_trace(name: str) -> dict[str, Any]:
    path = trace_json_path(name)
    if not os.path.isfile(path):
        raise FileNotFoundError(f"No trace JSON at {path} — run scan first")
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
    return validate_trace(data)
