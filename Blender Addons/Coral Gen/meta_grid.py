"""
MetaGrid: live uniform metaball grid over an Image Empty.

Sculpt with sliders → optional white-background cull → fused meta shape.
No JSON scan step required.
"""

from __future__ import annotations

import math
from typing import Literal

import bpy
from mathutils import Vector, Quaternion

ElementType = Literal["BALL", "ELLIPSOID", "CAPSULE"]

_UPDATING = False


def plane_size_from_empty(empty) -> tuple[float, float]:
    img = empty.data
    w, h = int(img.size[0]), int(img.size[1])
    aspect = w / float(max(h, 1))
    size = float(empty.empty_display_size)
    if aspect >= 1.0:
        return size, size / aspect
    return size * aspect, size


def empty_xy_scale(empty) -> float:
    m = empty.matrix_world.to_3x3()
    sx = (m @ Vector((1.0, 0.0, 0.0))).length
    sy = (m @ Vector((0.0, 1.0, 0.0))).length
    return max(1e-6, 0.5 * (sx + sy))


def uv_to_world(empty, u: float, v: float, plane_w: float, plane_h: float, depth: float) -> Vector:
    local = Vector(((u - 0.5) * plane_w, (v - 0.5) * plane_h, depth))
    return empty.matrix_world @ local


def orient_along_angle(angle: float) -> Quaternion:
    direction = Vector((math.cos(angle), math.sin(angle), 0.0))
    return direction.to_track_quat("X", "Z")


def ensure_meta(name: str):
    obj = bpy.data.objects.get(name)
    if obj and obj.type == "META":
        return obj
    if obj:
        bpy.data.objects.remove(obj, do_unlink=True)
    mb = bpy.data.metaballs.new(name)
    obj = bpy.data.objects.new(name, mb)
    bpy.context.collection.objects.link(obj)
    obj.location = (0.0, 0.0, 0.0)
    return obj


def _read_pixels(img) -> tuple[int, int, list[float]]:
    w, h = int(img.size[0]), int(img.size[1])
    return w, h, list(img.pixels)


def sample_luminance(pixels: list[float], w: int, h: int, u: float, v: float) -> float:
    """UV (0–1), v=0 at bottom (Blender image pixels)."""
    x = int(max(0, min(w - 1, int(u * w))))
    y = int(max(0, min(h - 1, int(v * h))))
    i = (y * w + x) * 4
    return (pixels[i] + pixels[i + 1] + pixels[i + 2]) / 3.0


def build_type_list(n_ball: int, n_ellipsoid: int, n_capsule: int, slots: int) -> list[ElementType]:
    """Fill grid slots from type counts (truncate / pad with BALL)."""
    types: list[ElementType] = (
        ["BALL"] * max(0, int(n_ball))
        + ["ELLIPSOID"] * max(0, int(n_ellipsoid))
        + ["CAPSULE"] * max(0, int(n_capsule))
    )
    if len(types) < slots:
        types.extend(["BALL"] * (slots - len(types)))
    return types[:slots]


def grid_slots(
    count_x: int,
    count_y: int,
    density_x: float,
    density_y: float,
    hex_stagger: bool = True,
) -> list[tuple[float, float, float, float]]:
    """
    Return list of (u, v, spacing_u, spacing_v) for each cell.

    Density >= 1 packs cells tighter (centered on the image).
    Density is clamped to >= 1 so it never opens gaps larger than a full even span.
    Odd rows are offset by half a step (hex) to break rectangular striping.
    """
    count_x = max(1, int(count_x))
    count_y = max(1, int(count_y))
    dx = max(1.0, float(density_x))
    dy = max(1.0, float(density_y))

    step_u = (1.0 / count_x) / dx
    step_v = (1.0 / count_y) / dy
    span_u = step_u * count_x
    span_v = step_v * count_y
    origin_u = 0.5 - 0.5 * span_u
    origin_v = 0.5 - 0.5 * span_v

    slots: list[tuple[float, float, float, float]] = []
    for j in range(count_y):
        row_shift = 0.5 * step_u if (hex_stagger and (j % 2 == 1)) else 0.0
        for i in range(count_x):
            u = origin_u + (i + 0.5) * step_u + row_shift
            v = origin_v + (j + 0.5) * step_v
            # Keep UV in-range; drop cells pushed off the plane by stagger
            if u < 0.0 or u > 1.0 or v < 0.0 or v > 1.0:
                continue
            slots.append((u, v, step_u, step_v))
    return slots


def cell_hits_ink(
    pixels: list[float],
    w: int,
    h: int,
    u: float,
    v: float,
    step_u: float,
    step_v: float,
    white_cut: float,
) -> bool:
    """True if center or near-center samples see non-white ink (fills thick areas better)."""
    offsets = (
        (0.0, 0.0),
        (-0.35, 0.0),
        (0.35, 0.0),
        (0.0, -0.35),
        (0.0, 0.35),
        (-0.25, -0.25),
        (0.25, 0.25),
        (-0.25, 0.25),
        (0.25, -0.25),
    )
    for du, dv in offsets:
        uu = min(0.999, max(0.001, u + du * step_u))
        vv = min(0.999, max(0.001, v + dv * step_v))
        if sample_luminance(pixels, w, h, uu, vv) < white_cut:
            return True
    return False


def compute_layout(settings, empty) -> tuple[list[dict], float, float]:
    """
    Build element dicts in empty-local radius units (builder applies world scale).
    Honors cull_white when enabled.
    """
    plane_w, plane_h = plane_size_from_empty(empty)
    count_x = int(settings.grid_count_x)
    count_y = int(settings.grid_count_y)
    slots_uv = grid_slots(count_x, count_y, settings.grid_density_x, settings.grid_density_y)
    types = build_type_list(
        settings.grid_n_ball,
        settings.grid_n_ellipsoid,
        settings.grid_n_capsule,
        len(slots_uv),
    )

    size_mult = float(settings.grid_element_size)
    depth = float(settings.depth_local)
    pixels = None
    iw = ih = 0
    if settings.grid_cull_white:
        iw, ih, pixels = _read_pixels(empty.data)
    white_cut = float(settings.grid_white_cutoff)

    elements: list[dict] = []
    for (u, v, step_u, step_v), typ in zip(slots_uv, types):
        if pixels is not None:
            if not cell_hits_ink(pixels, iw, ih, u, v, step_u, step_v, white_cut):
                continue
        spacing_u = step_u * plane_w
        spacing_v = step_v * plane_h
        # Size to the *larger* cell axis so anisotropic grids still fuse (no stripe gaps)
        spacing_local = max(spacing_u, spacing_v)
        radius = max(0.01, 0.55 * spacing_local * size_mult)
        el: dict = {
            "type": typ,
            "u": u,
            "v": v,
            "radius": radius,
            "depth": depth,
        }
        if typ == "CAPSULE":
            el["angle"] = math.pi * 0.5
            el["size_x"] = max(radius * 0.35, min(spacing_u, spacing_v) * 0.35 * size_mult)
        elif typ == "ELLIPSOID":
            el["angle"] = math.pi * 0.5
            el["size_x"] = 1.15
            el["size_y"] = 0.85
            el["size_z"] = 0.55
        elements.append(el)
    return elements, plane_w, plane_h


def apply_elements_to_meta(
    empty,
    elements: list[dict],
    plane_w: float,
    plane_h: float,
    *,
    threshold: float,
    resolution: float,
    stiffness: float,
    show_rings: bool,
) -> int:
    meta_name = f"{empty.name}_Meta"
    meta_obj = ensure_meta(meta_name)
    mb = meta_obj.data
    mb.threshold = float(threshold)
    mb.resolution = float(resolution)
    mb.render_resolution = max(0.05, float(resolution) * 0.85)

    xy_scale = empty_xy_scale(empty)
    world_q = empty.matrix_world.to_quaternion()

    # Clear existing
    while len(mb.elements) > 0:
        mb.elements.remove(mb.elements[0])

    for el in elements:
        typ = el["type"]
        radius = float(el["radius"]) * xy_scale
        depth = float(el.get("depth", 0.0))
        world = uv_to_world(empty, float(el["u"]), float(el["v"]), plane_w, plane_h, depth)

        if typ == "BALL":
            e = mb.elements.new(type="BALL")
            e.co = world
            e.radius = radius
            e.stiffness = stiffness
        elif typ == "CAPSULE":
            e = mb.elements.new(type="CAPSULE")
            e.co = world
            e.radius = radius
            e.stiffness = stiffness
            e.size_x = float(el.get("size_x", radius * 0.5)) * xy_scale
            e.size_y = 1.0
            e.size_z = 1.0
            angle = float(el.get("angle", math.pi * 0.5))
            e.rotation = world_q @ orient_along_angle(angle)
        elif typ == "ELLIPSOID":
            e = mb.elements.new(type="ELLIPSOID")
            e.co = world
            e.radius = radius
            e.stiffness = stiffness
            e.size_x = float(el.get("size_x", 1.0))
            e.size_y = float(el.get("size_y", 1.0))
            e.size_z = float(el.get("size_z", 0.55))
            angle = float(el.get("angle", math.pi * 0.5))
            e.rotation = world_q @ orient_along_angle(angle)
        else:
            continue

    # Select meta; optionally Edit Mode for size rings
    for o in bpy.context.view_layer.objects:
        o.select_set(False)
    meta_obj.hide_set(False)
    meta_obj.select_set(True)
    bpy.context.view_layer.objects.active = meta_obj
    bpy.context.view_layer.update()

    if show_rings:
        try:
            if bpy.context.mode != "EDIT_META" and bpy.context.mode != "EDIT_METABALL":
                # Blender uses 'EDIT' when meta is active
                if bpy.context.mode != "OBJECT":
                    bpy.ops.object.mode_set(mode="OBJECT")
                bpy.ops.object.mode_set(mode="EDIT")
        except Exception:
            pass
    else:
        try:
            if bpy.context.mode != "OBJECT":
                bpy.ops.object.mode_set(mode="OBJECT")
        except Exception:
            pass

    return len(mb.elements)


def live_update(context) -> str:
    """Rebuild MetaGrid from current scene settings. Safe for property updates."""
    global _UPDATING
    if _UPDATING:
        return ""
    s = context.scene.meta_tracer
    if s.tool_mode != "METAGRID":
        return ""
    obj = context.view_layer.objects.active
    # Prefer stored empty name if active object is the meta we just selected
    empty = None
    if obj and obj.type == "EMPTY" and obj.data and hasattr(obj.data, "size"):
        empty = obj
        s.grid_source_empty = obj.name
    elif s.grid_source_empty:
        empty = bpy.data.objects.get(s.grid_source_empty)
        if not empty or empty.type != "EMPTY" or not empty.data:
            empty = None

    if not empty:
        return "Select an Image Empty to sculpt MetaGrid"

    _UPDATING = True
    try:
        elements, plane_w, plane_h = compute_layout(s, empty)
        n = apply_elements_to_meta(
            empty,
            elements,
            plane_w,
            plane_h,
            threshold=s.threshold,
            resolution=s.resolution,
            stiffness=s.stiffness,
            show_rings=s.grid_show_rings,
        )
        culled = ""
        if s.grid_cull_white:
            total = int(s.grid_count_x) * int(s.grid_count_y)
            culled = f" | kept {n}/{total} (white culled)"
        msg = (
            f"MetaGrid {s.grid_count_x}×{s.grid_count_y} → {n} elems "
            f"(B{s.grid_n_ball}/E{s.grid_n_ellipsoid}/C{s.grid_n_capsule}) "
            f"size {s.grid_element_size:.2f}{culled}"
        )
        s.status = msg
        return msg
    except Exception as e:
        s.status = f"MetaGrid failed: {e}"
        return s.status
    finally:
        _UPDATING = False


def metagrid_update(_self, context):
    """Property update callback — live rebuild."""
    try:
        live_update(context)
    except Exception:
        pass
