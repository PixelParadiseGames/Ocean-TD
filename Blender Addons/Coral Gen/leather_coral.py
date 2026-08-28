# SPDX-License-Identifier: MIT
"""
Leather Coral — scatter Polyp template on selected Base faces (Poisson disk).

Requires Polyp mesh vertex group "Tip" (face-contact end). Live preview optional.
"""

from __future__ import annotations

bl_info = {
    "name": "Leather Coral Polyp Scatter",
    "author": "Ocean TD",
    "version": (1, 0, 0),
    "blender": (3, 6, 0),
    "location": "View3D > Sidebar > Procedural Coral > Leather Coral",
    "description": "Scatter Polyp triangles on upward Base faces with jitter sliders",
    "category": "Object",
}

import math
import random
from typing import Iterable

import bmesh
import bpy
from bpy.props import (
    BoolProperty,
    FloatProperty,
    FloatVectorProperty,
    IntProperty,
    PointerProperty,
    StringProperty,
)
from bpy.types import Object, Operator, Panel, PropertyGroup, Scene
from mathutils import Matrix, Quaternion, Vector

GENERATED_PREFIX = "LeatherPolyp_"
TIP_GROUP = "Tip"
BASE_GROUP = "Base"
DEFAULT_MAX_POLYPS = 500
LIVE_PREVIEW_MIN_SPACING = 0.12
_AUTO = False
_TIMER = None


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _wrap(text: str, width: int = 40) -> list[str]:
    if not text:
        return [""]
    words = str(text).split()
    lines: list[str] = []
    cur = ""
    for w in words:
        trial = f"{cur} {w}".strip()
        if len(trial) <= width:
            cur = trial
        else:
            if cur:
                lines.append(cur)
            cur = w
    if cur:
        lines.append(cur)
    return lines or [""]



def _pivot_local(obj: Object) -> tuple[Vector, str]:
    """Contact pivot in mesh local space — defaults to object origin."""
    mesh = obj.data
    vg = obj.vertex_groups.get(TIP_GROUP)
    if vg:
        idxs = [
            i
            for i, v in enumerate(mesh.vertices)
            if any(g.group == vg.index and g.weight > 0.5 for g in v.groups)
        ]
        if idxs:
            acc = Vector((0.0, 0.0, 0.0))
            for i in idxs:
                acc += mesh.vertices[i].co
            return acc / len(idxs), "Tip vertex group"

    return Vector((0.0, 0.0, 0.0)), "Object origin (Set Origin to contact end)"


# Legacy alias used in a few internal names / RNA props.
_tip_local = _pivot_local


def _axis_local(obj: Object, pivot: Vector) -> Vector:
    """Grow axis: from pivot toward the open ring (wide end faces outward)."""
    mesh = obj.data
    vg_base = obj.vertex_groups.get(BASE_GROUP)
    if vg_base:
        idxs = [
            i
            for i, v in enumerate(mesh.vertices)
            if any(g.group == vg_base.index and g.weight > 0.5 for g in v.groups)
        ]
        if idxs:
            base = sum((mesh.vertices[i].co for i in idxs), Vector()) / len(idxs)
            axis = base - pivot
            if axis.length > 1e-6:
                return axis.normalized()

    # From pivot toward the farthest geometry (open ring when origin = contact end).
    far = max(mesh.vertices, key=lambda v: (v.co - pivot).length_squared)
    axis = far.co - pivot
    if axis.length > 1e-6:
        return axis.normalized()
    return Vector((0.0, 0.0, 1.0))


def _apply_rotation_jitter(
    rot_q: Quaternion,
    amount_x: float,
    amount_y: float,
    amount_z: float,
    rng: random.Random,
) -> Quaternion:
    """Random XYZ rotation in local space; amount 0–1 scales up to ±180° per axis."""
    if amount_x < 1e-6 and amount_y < 1e-6 and amount_z < 1e-6:
        return rot_q
    rx = rng.uniform(-amount_x, amount_x) * math.pi
    ry = rng.uniform(-amount_y, amount_y) * math.pi
    rz = rng.uniform(-amount_z, amount_z) * math.pi
    jitter_q = (
        Quaternion((1.0, 0.0, 0.0), rx)
        @ Quaternion((0.0, 1.0, 0.0), ry)
        @ Quaternion((0.0, 0.0, 1.0), rz)
    )
    return rot_q @ jitter_q



def _nearest_face_normal(base: Object, world_point: Vector) -> Vector:
    """World-space normal of the Base face nearest to world_point."""
    bm = bmesh.new()
    bm.from_mesh(base.data)
    bm.normal_update()
    mw = base.matrix_world
    inv = mw.inverted()
    local_p = inv @ world_point
    best = min(bm.faces, key=lambda f: (f.calc_center_median() - local_p).length_squared)
    normal = (mw.to_3x3() @ best.normal).normalized()
    bm.free()
    return normal


def _surface_normal_at(base: Object, world_point: Vector) -> Vector:
    """World-space normal of the Base face closest to world_point."""
    from mathutils.bvhtree import BVHTree

    bm = bmesh.new()
    bm.from_mesh(base.data)
    bm.transform(base.matrix_world)
    bvh = BVHTree.FromBMesh(bm)
    _loc, normal, _idx, _dist = bvh.find_nearest(world_point)
    bm.free()
    if normal.length > 1e-6:
        return normal.normalized()
    return _nearest_face_normal(base, world_point)


def _template_pose(template: Object) -> tuple[Vector, Vector, Quaternion, Vector, str]:
    """Pivot, grow axis (mesh local), rotation, object scale, note."""
    pivot_local, pivot_note = _pivot_local(template)
    axis_local = _axis_local(template, pivot_local)
    _loc, rot_q, scl = template.matrix_world.decompose()
    scale_vec = Vector((max(1e-6, scl.x), max(1e-6, scl.y), max(1e-6, scl.z)))
    return pivot_local, axis_local, rot_q, scale_vec, pivot_note


def _capture_pose_from_template(settings: "LeatherCoralSettings") -> str:
    template = settings.polyp_object
    base = settings.base_object
    if not template or template.type != "MESH":
        raise RuntimeError("Assign Polyp template first")
    if not base or base.type != "MESH":
        raise RuntimeError("Assign Base mesh to capture surface reference")
    pivot_local, axis_local, rot_q, scale_vec, pivot_note = _template_pose(template)
    pivot_world = template.matrix_world @ pivot_local
    ref_normal = _surface_normal_at(base, pivot_world)
    grow = (rot_q @ axis_local).normalized()
    settings.pose_tip_local = pivot_local
    settings.pose_axis_local = axis_local
    settings.pose_rotation = rot_q
    settings.pose_ref_normal = ref_normal
    settings.pose_scale = scale_vec
    settings.pose_captured = True
    return f"Captured pose from '{template.name}'. {pivot_note} Clones copy template rotation."


def _resolve_pose(
    settings: "LeatherCoralSettings", template: Object, base: Object
) -> tuple[Vector, Vector, Quaternion, Vector, Vector, bool, str]:
    _, _, _, live_scale, _ = _template_pose(template)
    if settings.pose_captured:
        pivot_local = Vector(settings.pose_tip_local)
        axis_local = Vector(settings.pose_axis_local)
        rot_q = settings.pose_rotation.copy()
        ref_normal = Vector(settings.pose_ref_normal).normalized()
        return (
            pivot_local,
            axis_local,
            rot_q,
            live_scale,
            ref_normal,
            True,
            "Using locked captured pose",
        )
    pivot_local, axis_local, rot_q, scale_vec, pivot_note = _template_pose(template)
    pivot_world = template.matrix_world @ pivot_local
    ref_normal = _surface_normal_at(base, pivot_world)
    return pivot_local, axis_local, rot_q, scale_vec, ref_normal, False, pivot_note


def _face_frame(world_center: Vector, world_normal: Vector) -> tuple[Vector, Vector, Vector]:
    n = world_normal.normalized()
    ref = Vector((0.0, 0.0, 1.0))
    if abs(n.dot(ref)) > 0.95:
        ref = Vector((0.0, 1.0, 0.0))
    u = ref.cross(n).normalized()
    v = n.cross(u).normalized()
    return world_center, u, v


def _point_in_poly_2d(poly: list[tuple[float, float]], px: float, py: float) -> bool:
    inside = False
    n = len(poly)
    for i in range(n):
        x1, y1 = poly[i]
        x2, y2 = poly[(i + 1) % n]
        if ((y1 > py) != (y2 > py)) and (px < (x2 - x1) * (py - y1) / ((y2 - y1) + 1e-12) + x1):
            inside = not inside
    return inside


def _face_samples_poisson(
    world_verts: list[Vector],
    face_center: Vector,
    face_normal: Vector,
    rng: random.Random,
    spacing: float,
    spacing_random: float,
    position_jitter: float,
    coverage: float,
    coverage_random: float,
    k: int = 30,
    max_points: int | None = None,
) -> list[tuple[Vector, Vector]]:
    """Return list of (world_point, world_normal)."""
    normal = face_normal.normalized()
    origin, u, v = _face_frame(face_center, normal)

    us = [(c - origin).dot(u) for c in world_verts]
    vs = [(c - origin).dot(v) for c in world_verts]
    poly2d = list(zip(us, vs))
    min_u, max_u = min(us), max(us)
    min_v, max_v = min(vs), max(vs)
    cell = max(spacing, 1e-4)
    w = max_u - min_u
    h = max_v - min_v
    if w < cell * 0.25 or h < cell * 0.25:
        return []

    local_coverage = max(0.05, min(1.0, coverage + rng.uniform(-coverage_random, coverage_random)))

    grid: dict[tuple[int, int], list[tuple[float, float]]] = {}
    active: list[tuple[float, float]] = []
    samples: list[tuple[float, float]] = []

    def grid_key(pu: float, pv: float) -> tuple[int, int]:
        return (int((pu - min_u) / cell), int((pv - min_v) / cell))

    def far_enough(pu: float, pv: float, min_dist: float) -> bool:
        gi, gj = grid_key(pu, pv)
        for di in range(-2, 3):
            for dj in range(-2, 3):
                for ou, ov in grid.get((gi + di, gj + dj), []):
                    if math.hypot(pu - ou, pv - ov) < min_dist:
                        return False
        return True

    def add_point(pu: float, pv: float) -> None:
        samples.append((pu, pv))
        active.append((pu, pv))
        grid.setdefault(grid_key(pu, pv), []).append((pu, pv))

    for _ in range(32):
        pu = rng.uniform(min_u, max_u)
        pv = rng.uniform(min_v, max_v)
        if not _point_in_poly_2d(poly2d, pu, pv):
            continue
        min_d = spacing * (1.0 + rng.uniform(-spacing_random, spacing_random))
        add_point(pu, pv)
        break
    else:
        return []

    while active:
        if max_points is not None and len(samples) >= max_points:
            break
        ax, ay = active[rng.randint(0, len(active) - 1)]
        found = False
        for _ in range(k):
            ang = rng.uniform(0.0, math.tau)
            rad = rng.uniform(cell, cell * 2.0)
            pu = ax + math.cos(ang) * rad
            pv = ay + math.sin(ang) * rad
            if pu < min_u or pu > max_u or pv < min_v or pv > max_v:
                continue
            if not _point_in_poly_2d(poly2d, pu, pv):
                continue
            min_d = spacing * (1.0 + rng.uniform(-spacing_random, spacing_random))
            if not far_enough(pu, pv, min_d):
                continue
            add_point(pu, pv)
            found = True
            break
        if not found:
            active.remove((ax, ay))

    out: list[tuple[Vector, Vector]] = []
    for pu, pv in samples:
        if max_points is not None and len(out) >= max_points:
            break
        if rng.random() > local_coverage:
            continue
        ju = rng.uniform(-position_jitter, position_jitter)
        jv = rng.uniform(-position_jitter, position_jitter)
        pu2, pv2 = pu + ju, pv + jv
        if not _point_in_poly_2d(poly2d, pu2, pv2):
            pu2, pv2 = pu, pv
        pw = origin + u * pu2 + v * pv2
        out.append((pw, normal))
    return out


def _matrix_at_point(
    pivot_world: Vector,
    face_normal: Vector,
    pivot_local: Vector,
    template_rot: Quaternion,
    template_scale: Vector,
    rot_jitter_x: float,
    rot_jitter_y: float,
    rot_jitter_z: float,
    polyp_scale: float,
    size_jitter: float,
    height_offset: float,
    rng: random.Random,
) -> tuple[Matrix, Vector, Vector]:
    """Place template: exact template rotation, origin on face (+ optional normal offset)."""
    jitter = 1.0 + rng.uniform(-size_jitter, size_jitter)
    scale = template_scale * polyp_scale * jitter

    n = face_normal.normalized()
    pivot_world = pivot_world + n * height_offset

    rot_q = template_rot.copy()
    rot_q = _apply_rotation_jitter(rot_q, rot_jitter_x, rot_jitter_y, rot_jitter_z, rng)

    rot_m = rot_q.to_matrix().to_4x4()
    scaled_pivot = Vector(
        (scale.x * pivot_local.x, scale.y * pivot_local.y, scale.z * pivot_local.z)
    )
    return rot_m, scale, pivot_world - rot_q @ scaled_pivot


def _apply_transform(obj: Object, rot_m: Matrix, scale: Vector, location: Vector) -> None:
    obj.rotation_mode = "QUATERNION"
    obj.rotation_quaternion = rot_m.to_quaternion()
    obj.scale = scale
    obj.location = location


def _clear_generated() -> int:
    n = 0
    for obj in list(bpy.data.objects):
        if obj.name.startswith(GENERATED_PREFIX):
            bpy.data.objects.remove(obj, do_unlink=True)
            n += 1
    return n


def _gather_scatter_faces(
    settings: "LeatherCoralSettings",
    base: Object,
    *,
    require_selection: bool = False,
) -> tuple[bmesh.types.BMesh | None, list | None]:
    """Use current face selection, else last cached indices from a prior scatter."""
    bm = bmesh.new()
    bm.from_mesh(base.data)
    bm.faces.ensure_lookup_table()
    bm.normal_update()

    selected = [f for f in bm.faces if f.select]
    if selected:
        settings.scatter_face_indices = ",".join(str(f.index) for f in selected)
        return bm, selected

    cached = [
        int(part)
        for part in settings.scatter_face_indices.split(",")
        if part.strip().isdigit()
    ]
    if cached:
        faces = [bm.faces[i] for i in cached if i < len(bm.faces)]
        if faces:
            return bm, faces

    bm.free()
    if require_selection:
        raise RuntimeError("Select faces on Base, then Scatter Polyps")
    return None, None


def scatter_polyps(
    settings: "LeatherCoralSettings", *, require_face_selection: bool = False
) -> tuple[int, str | None]:
    base = settings.base_object
    template = settings.polyp_object
    if not base or base.type != "MESH":
        raise RuntimeError("Assign a Base mesh object")
    if not template or template.type != "MESH":
        raise RuntimeError("Assign a Polyp template mesh")

    max_polyps = max(1, int(settings.max_polyps))
    pivot_local, axis_local, template_rot, template_scale, _ref_normal, pose_locked, pose_note = (
        _resolve_pose(settings, template, base)
    )

    bm, faces = _gather_scatter_faces(settings, base, require_selection=require_face_selection)
    if bm is None or faces is None:
        return 0, None

    world = base.matrix_world

    rng = random.Random(settings.seed)
    points: list[tuple[Vector, Vector]] = []
    face_count = len(faces)
    truncated = False
    try:
        for f in faces:
            if len(points) >= max_polyps:
                truncated = True
                break
            n = (world.to_3x3() @ f.normal).normalized()
            wverts = [world @ v.co for v in f.verts]
            center = world @ f.calc_center_median()
            remaining = max_polyps - len(points)
            batch = _face_samples_poisson(
                wverts,
                center,
                n,
                rng,
                settings.spacing,
                settings.spacing_random,
                settings.position_jitter,
                settings.coverage,
                settings.coverage_random,
                max_points=remaining,
            )
            points.extend(batch)
            if len(points) >= max_polyps:
                truncated = True
                break
    finally:
        bm.free()

    if not points:
        raise RuntimeError("No scatter points on selection — lower Spacing or raise Coverage")

    _clear_generated()
    col = settings.target_collection
    created = 0
    for i, (pt, nrm) in enumerate(points[:max_polyps]):
        rot_m, scale, location = _matrix_at_point(
            pt,
            nrm,
            pivot_local,
            template_rot,
            template_scale,
            settings.rot_jitter_x,
            settings.rot_jitter_y,
            settings.rot_jitter_z,
            settings.polyp_scale,
            settings.size_jitter,
            settings.height_offset,
            rng,
        )
        dup = template.copy()
        dup.data = template.data.copy()
        dup.name = f"{GENERATED_PREFIX}{i + 1:04d}"
        if col:
            col.objects.link(dup)
        else:
            bpy.context.scene.collection.objects.link(dup)
        _apply_transform(dup, rot_m, scale, location)
        created += 1

    note = f"{created} polyps on {face_count} selected face(s). {pose_note}"
    if truncated:
        note += f" (capped at {max_polyps} — raise Max Polyps or spacing)"
    return created, note


def _live_preview_allowed(settings: "LeatherCoralSettings") -> tuple[bool, str]:
    if not settings.auto_update:
        return False, ""
    if settings.spacing < LIVE_PREVIEW_MIN_SPACING:
        return (
            False,
            f"Live preview paused: spacing < {LIVE_PREVIEW_MIN_SPACING}. "
            "Click Scatter Polyps or raise spacing.",
        )
    return True, ""


def _schedule_update(settings: "LeatherCoralSettings") -> None:
    global _TIMER
    ok, msg = _live_preview_allowed(settings)
    if not ok:
        if msg:
            settings.status = msg
        return

    def _run():
        global _TIMER, _AUTO
        _TIMER = None
        try:
            _AUTO = True
            count, note = scatter_polyps(settings)
            if note is not None:
                settings.status = note
        except Exception as e:
            settings.status = str(e)
        finally:
            _AUTO = False
        return None

    if _TIMER is not None:
        try:
            bpy.app.timers.unregister(_TIMER)
        except Exception:
            pass
    _TIMER = bpy.app.timers.register(_run, first_interval=0.15)


def _slider_update(self, context):
    global _AUTO
    if _AUTO:
        return
    _schedule_update(self)


# ---------------------------------------------------------------------------
# Properties
# ---------------------------------------------------------------------------


class LeatherCoralSettings(PropertyGroup):
    base_object: PointerProperty(
        name="Base",
        type=Object,
        poll=lambda self, obj: obj.type == "MESH",
        description="Coral base mesh",
    )
    polyp_object: PointerProperty(
        name="Polyp Template",
        type=Object,
        poll=lambda self, obj: obj.type == "MESH",
        description="Triangle template (vertex group Tip = face contact)",
    )
    target_collection: PointerProperty(
        name="Collection",
        type=bpy.types.Collection,
        description="Where generated polyps are placed",
    )

    seed: IntProperty(name="Seed", default=1, min=0, update=_slider_update)
    spacing: FloatProperty(
        name="Spacing",
        default=0.35,
        min=0.08,
        max=5.0,
        description="Minimum distance between polyp tips. Very low values create thousands of meshes",
        update=_slider_update,
    )
    spacing_random: FloatProperty(
        name="Spacing Random",
        default=0.0,
        min=0.0,
        max=1.0,
        subtype="FACTOR",
        description="Random variation in spacing (organic gaps)",
        update=_slider_update,
    )
    position_jitter: FloatProperty(
        name="Position Jitter",
        default=0.0,
        min=0.0,
        max=0.5,
        description="Slide tips along the face tangent plane",
        update=_slider_update,
    )
    rot_jitter_x: FloatProperty(
        name="Rotation Amount X",
        default=0.0,
        min=0.0,
        max=2.0,
        description="Local X spin amount (0=none; higher adds more random rotation)",
        update=_slider_update,
    )
    rot_jitter_y: FloatProperty(
        name="Rotation Amount Y",
        default=0.0,
        min=0.0,
        max=2.0,
        description="Local Y spin amount (0=none; higher adds more random rotation)",
        update=_slider_update,
    )
    rot_jitter_z: FloatProperty(
        name="Rotation Amount Z",
        default=0.0,
        min=0.0,
        max=2.0,
        description="Local Z spin / twist amount (0=none; higher adds more)",
        update=_slider_update,
    )
    size_jitter: FloatProperty(
        name="Size Jitter",
        default=0.0,
        min=0.0,
        max=0.75,
        subtype="FACTOR",
        description="Random scale variation around Polyp Scale",
        update=_slider_update,
    )
    polyp_scale: FloatProperty(
        name="Polyp Scale",
        default=1.0,
        min=0.01,
        max=10.0,
        description="Uniform size multiplier (1 = same size as Polyp template in the scene)",
        update=_slider_update,
    )
    height_offset: FloatProperty(
        name="Height Offset",
        default=0.0,
        min=-2.0,
        max=2.0,
        description="Shift along face normal — negative sinks into Base, positive lifts off",
        update=_slider_update,
    )
    coverage: FloatProperty(
        name="Coverage",
        default=0.92,
        min=0.05,
        max=1.0,
        subtype="FACTOR",
        description="Chance each Poisson site spawns a polyp",
        update=_slider_update,
    )
    coverage_random: FloatProperty(
        name="Coverage Patchiness",
        default=0.0,
        min=0.0,
        max=1.0,
        subtype="FACTOR",
        description="Extra local density variation (reserved)",
        update=_slider_update,
    )
    max_polyps: IntProperty(
        name="Max Polyps",
        default=DEFAULT_MAX_POLYPS,
        min=10,
        max=5000,
        description="Hard cap so Blender does not freeze (each polyp is its own mesh)",
        update=_slider_update,
    )
    auto_update: BoolProperty(
        name="Live Preview",
        default=True,
        description="Rebuild scatter when sliders change (auto-pauses below safe spacing)",
    )
    pose_captured: BoolProperty(
        name="Pose Locked",
        default=False,
        description="Scatter uses captured pose instead of live Polyp transform",
    )
    pose_tip_local: FloatVectorProperty(
        name="Captured Tip Local",
        size=3,
        default=(0.0, 0.0, 0.0),
        options={"HIDDEN"},
    )
    pose_axis_local: FloatVectorProperty(
        name="Captured Axis Local",
        size=3,
        default=(0.0, 0.0, 1.0),
        options={"HIDDEN"},
    )
    pose_rotation: FloatVectorProperty(
        name="Captured Rotation",
        size=4,
        subtype="QUATERNION",
        default=(1.0, 0.0, 0.0, 0.0),
        options={"HIDDEN"},
    )
    pose_ref_normal: FloatVectorProperty(
        name="Captured Surface Normal",
        size=3,
        default=(0.0, 0.0, 1.0),
        options={"HIDDEN"},
    )
    pose_scale: FloatVectorProperty(
        name="Captured Scale",
        size=3,
        default=(1.0, 1.0, 1.0),
        options={"HIDDEN"},
    )
    scatter_face_indices: StringProperty(
        name="Cached Face Indices",
        default="",
        options={"HIDDEN"},
        description="Face indices from last scatter (used by live preview)",
    )
    status: StringProperty(name="Status", default="Ready")


# ---------------------------------------------------------------------------
# Operators
# ---------------------------------------------------------------------------


class LEATHERCORAL_OT_scatter(Operator):
    bl_idname = "leather_coral.scatter"
    bl_label = "Scatter Polyps"
    bl_description = "Scatter on selected Base faces (select faces in Edit Mode first)"
    bl_options = {"REGISTER", "UNDO"}

    def execute(self, context):
        s = context.scene.leather_coral
        try:
            _capture_pose_from_template(s)
            n, note = scatter_polyps(s, require_face_selection=True)
            s.status = note or f"Created {n} polyps"
            self.report({"INFO"}, f"Created {n} polyps")
        except Exception as e:
            s.status = str(e)
            self.report({"ERROR"}, str(e))
            return {"CANCELLED"}
        return {"FINISHED"}


class LEATHERCORAL_OT_clear(Operator):
    bl_idname = "leather_coral.clear"
    bl_label = "Clear Generated"
    bl_options = {"REGISTER", "UNDO"}

    def execute(self, context):
        n = _clear_generated()
        context.scene.leather_coral.status = f"Cleared {n} generated polyps"
        return {"FINISHED"}


class LEATHERCORAL_OT_pick_defaults(Operator):
    bl_idname = "leather_coral.pick_defaults"
    bl_label = "Pick Base / Polyp from Scene"
    bl_options = {"REGISTER", "UNDO"}

    def execute(self, context):
        s = context.scene.leather_coral
        base = bpy.data.objects.get("Base")
        polyp = bpy.data.objects.get("Polyp")
        col = bpy.data.collections.get("Leather Coral")
        if base:
            s.base_object = base
        if polyp:
            s.polyp_object = polyp
        if col:
            s.target_collection = col
        s.status = "Picked Base, Polyp, Leather Coral collection"
        return {"FINISHED"}


class LEATHERCORAL_OT_capture_pose(Operator):
    bl_idname = "leather_coral.capture_pose"
    bl_label = "Capture Pose from Polyp"
    bl_description = (
        "Lock rotation/scale from the current Polyp template (place it once, then capture)"
    )
    bl_options = {"REGISTER", "UNDO"}

    def execute(self, context):
        s = context.scene.leather_coral
        try:
            msg = _capture_pose_from_template(s)
            s.status = msg
            self.report({"INFO"}, "Pose captured")
            if s.auto_update:
                n, note = scatter_polyps(s)
                if note is not None:
                    s.status = note
        except Exception as e:
            s.status = str(e)
            self.report({"ERROR"}, str(e))
            return {"CANCELLED"}
        return {"FINISHED"}


class LEATHERCORAL_OT_clear_pose(Operator):
    bl_idname = "leather_coral.clear_pose"
    bl_label = "Clear Captured Pose"
    bl_description = "Use live Polyp object transform again"
    bl_options = {"REGISTER", "UNDO"}

    def execute(self, context):
        s = context.scene.leather_coral
        s.pose_captured = False
        s.status = "Captured pose cleared — using live Polyp transform"
        self.report({"INFO"}, s.status)
        return {"FINISHED"}


# ---------------------------------------------------------------------------
# UI
# ---------------------------------------------------------------------------


class LEATHERCORAL_PT_main(Panel):
    bl_label = "Leather Coral"
    bl_idname = "LEATHERCORAL_PT_main"
    bl_space_type = "VIEW_3D"
    bl_region_type = "UI"
    bl_category = "Procedural Coral"
    bl_options = {"DEFAULT_CLOSED"}

    def draw(self, context):
        layout = self.layout
        s = context.scene.leather_coral

        layout.operator("leather_coral.pick_defaults", icon="EYEDROPPER")
        layout.prop(s, "base_object")
        layout.prop(s, "polyp_object")
        layout.prop(s, "target_collection")

        pose = layout.box()
        pose.label(text="Template Pose", icon="ORIENTATION_LOCAL")
        row = pose.row(align=True)
        row.operator("leather_coral.capture_pose", icon="PIVOT_ACTIVE")
        row.operator("leather_coral.clear_pose", icon="UNLOCKED")
        if s.pose_captured:
            pose.label(text="Pose locked — re-capture if you move Polyp", icon="LOCKED")
        else:
            pose.label(text="Place Polyp on Base, then Capture Pose", icon="INFO")

        top = layout.box()
        top.prop(s, "auto_update", toggle=True, icon="FILE_REFRESH")
        if s.auto_update and s.spacing < LIVE_PREVIEW_MIN_SPACING:
            top.label(text="Live preview paused (spacing too tight)", icon="ERROR")
        top.label(text="Select Base faces once, then Scatter (cached for preview)", icon="INFO")
        row = top.row(align=True)
        row.operator("leather_coral.scatter", icon="OUTLINER_OB_GROUP_INSTANCE")
        row.operator("leather_coral.clear", icon="TRASH")

        box = layout.box()
        box.label(text="Distribution", icon="MOD_PARTICLES")
        box.prop(s, "seed")
        box.prop(s, "spacing")
        box.prop(s, "spacing_random")
        box.prop(s, "position_jitter")
        box.prop(s, "coverage")
        box.prop(s, "coverage_random")
        box.prop(s, "max_polyps")

        box = layout.box()
        box.label(text="Variation", icon="ORIENTATION_GIMBAL")
        box.prop(s, "polyp_scale")
        box.prop(s, "height_offset")
        col = box.column(align=True)
        col.label(text="Rotation Amount (local XYZ):")
        col.prop(s, "rot_jitter_x")
        col.prop(s, "rot_jitter_y")
        col.prop(s, "rot_jitter_z")
        box.prop(s, "size_jitter")

        layout.separator()
        layout.label(text="Status:")
        for line in _wrap(s.status):
            layout.label(text=line)
        layout.label(text="Set Origin on Polyp = contact end on face", icon="INFO")
        layout.label(text=f'Optional "{TIP_GROUP}" vgroup overrides origin', icon="BLANK1")
        layout.label(text=f'Optional "{BASE_GROUP}" vgroup = open ring end', icon="BLANK1")


CLASSES = (
    LeatherCoralSettings,
    LEATHERCORAL_OT_scatter,
    LEATHERCORAL_OT_clear,
    LEATHERCORAL_OT_pick_defaults,
    LEATHERCORAL_OT_capture_pose,
    LEATHERCORAL_OT_clear_pose,
    LEATHERCORAL_PT_main,
)


def register():
    for cls in CLASSES:
        bpy.utils.register_class(cls)
    Scene.leather_coral = PointerProperty(type=LeatherCoralSettings)


def unregister():
    if hasattr(Scene, "leather_coral"):
        del Scene.leather_coral
    for cls in reversed(CLASSES):
        bpy.utils.unregister_class(cls)


if __name__ == "__main__":
    register()
