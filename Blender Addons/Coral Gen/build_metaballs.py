"""
Builder: Traces/<name>_trace.json → metaball object on Image Empty plane.

Does NOT re-scan. Tune scan knobs and re-scan separately if the plan is wrong.
"""

from __future__ import annotations

import math

import bpy
from mathutils import Vector, Quaternion

from shape_trace_io import read_trace


def _orient_along_angle(angle: float) -> Quaternion:
    """Capsule/ellipsoid local X along angle in empty local XY plane."""
    # Direction in empty local space (XY image plane)
    direction = Vector((math.cos(angle), math.sin(angle), 0.0))
    return direction.to_track_quat("X", "Z")


def _uv_to_world(empty, u: float, v: float, plane_w: float, plane_h: float, depth_local: float) -> Vector:
    local = Vector(((u - 0.5) * plane_w, (v - 0.5) * plane_h, depth_local))
    return empty.matrix_world @ local


def _empty_xy_scale(empty) -> float:
    """
    Object scale applied to the image plane.

    Scan radii/lengths are in empty-local display units; element.co is world-space
    via matrix_world. Radius must be multiplied by this scale or thick middles stay hollow.
    """
    m = empty.matrix_world.to_3x3()
    sx = (m @ Vector((1.0, 0.0, 0.0))).length
    sy = (m @ Vector((0.0, 1.0, 0.0))).length
    return max(1e-6, 0.5 * (sx + sy))


def _ensure_meta(name: str):
    obj = bpy.data.objects.get(name)
    if obj and obj.type == "META":
        return obj
    # Remove stale non-meta with same name
    if obj:
        bpy.data.objects.remove(obj, do_unlink=True)
    mb = bpy.data.metaballs.new(name)
    obj = bpy.data.objects.new(name, mb)
    bpy.context.collection.objects.link(obj)
    obj.location = (0.0, 0.0, 0.0)
    return obj


def build(
    empty_name: str = "FireCoral",
    meta_object_name: str | None = None,
    *,
    threshold: float | None = None,
    resolution: float | None = None,
    clear: bool = True,
) -> int:
    """
    Place meta elements from Traces/<empty_name>_trace.json onto the Image Empty plane.
    Returns element count.
    """
    trace = read_trace(empty_name)
    empty = bpy.data.objects.get(empty_name)
    if not empty or empty.type != "EMPTY":
        raise ValueError(f"Image empty '{empty_name}' not found — builder needs it for plane pose")

    meta_name = meta_object_name or f"{empty_name}_Meta"
    meta_obj = _ensure_meta(meta_name)
    mb = meta_obj.data

    md = trace.get("meta_defaults", {})
    thresh = float(threshold if threshold is not None else md.get("threshold", 2.1))
    res = float(resolution if resolution is not None else md.get("resolution", 0.13))
    depth = float(md.get("depth_local", 0.0))
    stiff = float(md.get("stiffness", 2.0))

    mb.threshold = thresh
    mb.resolution = res
    mb.render_resolution = max(0.05, res * 0.85)

    plane_w = float(trace["plane"]["width"])
    plane_h = float(trace["plane"]["height"])
    xy_scale = _empty_xy_scale(empty)

    if clear:
        while len(mb.elements) > 0:
            mb.elements.remove(mb.elements[0])

    count = 0
    for el in trace["elements"]:
        typ = el["type"]
        u, v = float(el["u"]), float(el["v"])
        radius = float(el["radius"]) * xy_scale
        world = _uv_to_world(empty, u, v, plane_w, plane_h, depth)

        if typ == "BALL":
            e = mb.elements.new(type="BALL")
            e.co = world
            e.radius = radius
            e.stiffness = stiff
        elif typ == "CAPSULE":
            e = mb.elements.new(type="CAPSULE")
            e.co = world
            e.radius = radius
            e.stiffness = stiff
            size_x = float(el.get("size_x", max(0.04, float(el.get("length", 0.2)) * 0.5)))
            e.size_x = size_x * xy_scale
            e.size_y = 1.0
            e.size_z = 1.0
            angle = float(el.get("angle", 0.0))
            # Rotate direction into empty's world orientation
            local_q = _orient_along_angle(angle)
            world_q = empty.matrix_world.to_quaternion() @ local_q
            e.rotation = world_q
        elif typ == "ELLIPSOID":
            e = mb.elements.new(type="ELLIPSOID")
            e.co = world
            e.radius = radius
            e.stiffness = stiff
            # size_* are relative multipliers for ellipsoids — do not scale
            e.size_x = float(el.get("size_x", 1.0))
            e.size_y = float(el.get("size_y", 1.0))
            e.size_z = float(el.get("size_z", 0.55))
            angle = float(el.get("angle", 0.0))
            local_q = _orient_along_angle(angle)
            e.rotation = empty.matrix_world.to_quaternion() @ local_q
        else:
            continue
        count += 1

    bpy.context.view_layer.update()
    if bpy.context.mode != "OBJECT":
        bpy.ops.object.mode_set(mode="OBJECT")
    for o in bpy.context.view_layer.objects:
        o.select_set(False)
    meta_obj.hide_set(False)
    meta_obj.select_set(True)
    bpy.context.view_layer.objects.active = meta_obj

    print(
        f"[build_metaballs] {meta_name}: {count} elements "
        f"(threshold={thresh}, resolution={res}, xy_scale={xy_scale:.3f}) "
        f"from {empty_name}_trace.json"
    )
    return count


if __name__ == "__main__":
    build("FireCoral")
