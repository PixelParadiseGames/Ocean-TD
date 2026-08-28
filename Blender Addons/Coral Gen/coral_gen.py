# SPDX-License-Identifier: MIT
"""
Coral Gen — Procedural branching coral (Phase 1).

N-Panel: View3D → Sidebar → Procedural Coral
Workflow: Generate Preview (metaballs) → Finalize to Mesh (Remesh + Decimate).
"""

from __future__ import annotations

bl_info = {
    "name": "Coral Gen",
    "author": "Ocean TD",
    "version": (1, 0, 6),
    "blender": (3, 6, 0),
    "location": "View3D > Sidebar > Procedural Coral",
    "description": "Procedural branching coral via L-system metaballs (Preview → Finalize)",
    "category": "Object",
}

import math
import random
from dataclasses import dataclass

import bpy
from bpy.props import (
    BoolProperty,
    EnumProperty,
    FloatProperty,
    IntProperty,
    PointerProperty,
    StringProperty,
)
from bpy.types import Operator, Panel, PropertyGroup, Scene
from mathutils import Matrix, Quaternion, Vector


PREVIEW_NAME = "CoralGen_Preview"
MESH_NAME = "CoralGen_Mesh"
MAX_SEGMENTS = 4000
MAX_SAMPLES = 12000

_AUTO_UPDATING = False
# Preserved across growth rebuilds when user tuned MetaBall data in Properties
_PRESERVED_RENDER_RESOLUTION = None


def _sync_meta_surface_from_live(settings: "CoralGenSettings") -> None:
    """Copy viewport resolution / threshold / stiffness from the live preview meta."""
    global _AUTO_UPDATING, _PRESERVED_RENDER_RESOLUTION
    preview = bpy.data.objects.get(PREVIEW_NAME)
    if not preview or preview.type != "META" or not preview.data:
        return
    mb = preview.data
    _PRESERVED_RENDER_RESOLUTION = float(mb.render_resolution)
    was = _AUTO_UPDATING
    _AUTO_UPDATING = True
    try:
        settings.preview_resolution = float(mb.resolution)
        settings.meta_threshold = float(mb.threshold)
        if len(mb.elements) > 0:
            settings.meta_stiffness = float(mb.elements[0].stiffness)
    finally:
        _AUTO_UPDATING = was


def _preview_slider_update(self, context):
    """Rebuild on growth/shape slider drag; keep live meta resolution/threshold."""
    _auto_regenerate(self, context, sync_meta_from_live=True)


def _meta_surface_slider_update(self, context):
    """Apply Smooth Fusing / Resolution / Stiffness; rebuild only if Auto Preview is on."""
    global _AUTO_UPDATING, _PRESERVED_RENDER_RESOLUTION
    if _AUTO_UPDATING:
        return
    _PRESERVED_RENDER_RESOLUTION = None
    preview = bpy.data.objects.get(PREVIEW_NAME)
    if preview and preview.type == "META" and preview.data:
        mb = preview.data
        mb.resolution = float(self.preview_resolution)
        mb.threshold = float(self.meta_threshold)
        mb.render_resolution = max(0.05, float(self.preview_resolution) * 0.85)
        stiff = float(self.meta_stiffness)
        for e in mb.elements:
            e.stiffness = stiff
    _auto_regenerate(self, context, sync_meta_from_live=False)


def _auto_regenerate(settings, context, *, sync_meta_from_live: bool):
    global _AUTO_UPDATING
    if _AUTO_UPDATING:
        return
    if not getattr(settings, "auto_preview_update", False):
        return
    _AUTO_UPDATING = True
    try:
        regenerate_preview(context, settings, sync_meta_from_live=sync_meta_from_live)
    except Exception as e:
        settings.status = f"Auto preview failed: {e}"
    finally:
        _AUTO_UPDATING = False


def regenerate_preview(
    context,
    settings: "CoralGenSettings",
    *,
    sync_meta_from_live: bool = False,
) -> int:
    """Grow + place preview metaballs. Returns sample count."""
    if sync_meta_from_live:
        _sync_meta_surface_from_live(settings)
    samples = grow_coral(
        seed=settings.seed,
        iterations=settings.iterations,
        branch_length=settings.branch_length,
        split_angle_deg=settings.split_angle,
        branch_prob=settings.branch_probability,
        sunlight=settings.sunlight_pull,
        base_radius=settings.base_radius,
        tip_taper=settings.tip_taper,
        growth_mode=settings.growth_mode,
    )
    if not samples:
        raise RuntimeError("Growth produced no samples — raise Branch Length / Iterations")
    obj = build_preview_meta(samples, settings, _cursor_matrix(context))
    for o in context.view_layer.objects:
        o.select_set(False)
    obj.select_set(True)
    context.view_layer.objects.active = obj
    mode = "2D" if settings.growth_mode == "FLAT" else "3D"
    settings.status = (
        f"Preview ({mode}): {len(samples)} samples, seed {settings.seed}, iter {settings.iterations}"
        + (" (auto)" if settings.auto_preview_update else "")
    )
    return len(samples)


# ---------------------------------------------------------------------------
# L-system growth
# ---------------------------------------------------------------------------


@dataclass
class Sample:
    co: Vector
    radius: float


def _orthonormal_basis(direction: Vector) -> tuple[Vector, Vector]:
    d = direction.normalized()
    up = Vector((0.0, 0.0, 1.0))
    if abs(d.dot(up)) > 0.92:
        up = Vector((0.0, 1.0, 0.0))
    side = d.cross(up).normalized()
    binormal = d.cross(side).normalized()
    return side, binormal


def grow_coral(
    *,
    seed: int,
    iterations: int,
    branch_length: float,
    split_angle_deg: float,
    branch_prob: float,
    sunlight: float,
    base_radius: float,
    tip_taper: float,
    growth_mode: str = "VOLUME",
) -> list[Sample]:
    """
    Recursive turtle growth → metaball samples.

    growth_mode:
      VOLUME — full 3D bush (default)
      FLAT — planar fan in XZ (sea-fan / 2D silhouette style)
    """
    rng = random.Random(int(seed))
    iterations = max(1, min(16, int(iterations)))
    branch_prob = max(0.0, min(1.0, float(branch_prob)))
    sunlight = max(0.0, min(2.0, float(sunlight)))
    tip_taper = max(0.0, min(1.0, float(tip_taper)))
    split_rad = math.radians(float(split_angle_deg))
    sun_dir = Vector((0.0, 0.0, 1.0))
    flat = growth_mode == "FLAT"
    # Fixed plane normal for 2D mode (fan lies in world XZ)
    plane_normal = Vector((0.0, 1.0, 0.0))

    samples: list[Sample] = []
    segment_count = 0

    def radius_at_depth(depth: int) -> float:
        t = depth / max(iterations, 1)
        scale = 1.0 - tip_taper * (0.15 + 0.85 * t)
        return max(0.01, float(base_radius) * scale)

    def length_at_depth(depth: int) -> float:
        t = depth / max(iterations, 1)
        return max(0.04, float(branch_length) * (1.0 - 0.45 * t))

    def place_segment(a: Vector, b: Vector, ra: float, rb: float) -> None:
        nonlocal segment_count
        if segment_count >= MAX_SEGMENTS or len(samples) >= MAX_SAMPLES:
            return
        segment_count += 1
        delta = b - a
        dist = delta.length
        if dist < 1e-6:
            samples.append(Sample(a.copy(), ra))
            return
        avg_r = 0.5 * (ra + rb)
        step = max(avg_r * 0.55, dist / 8.0)
        n = max(1, int(math.ceil(dist / step)))
        for i in range(n + 1):
            if len(samples) >= MAX_SAMPLES:
                break
            t = i / n
            co = a.lerp(b, t)
            r = ra * (1.0 - t) + rb * t
            samples.append(Sample(co, r))

    def rotate_around(direction: Vector, axis: Vector, angle: float) -> Vector:
        return (Quaternion(axis.normalized(), angle) @ direction).normalized()

    def project_to_plane(direction: Vector) -> Vector:
        """Keep direction in the XZ fan plane."""
        d = direction - plane_normal * direction.dot(plane_normal)
        if d.length < 1e-6:
            return Vector((0.0, 0.0, 1.0))
        return d.normalized()

    def grow(pos: Vector, direction: Vector, depth: int) -> None:
        if depth >= iterations or segment_count >= MAX_SEGMENTS or len(samples) >= MAX_SAMPLES:
            return

        direction = direction.normalized()
        if flat:
            direction = project_to_plane(direction)

        if sunlight > 1e-6:
            pull = min(sunlight, 1.25) * (0.35 if flat else 0.22)
            blended = (direction + sun_dir * pull).normalized()
            if blended.length > 1e-6:
                direction = project_to_plane(blended) if flat else blended

        seg_len = length_at_depth(depth)
        ra = radius_at_depth(depth)
        rb = radius_at_depth(depth + 1)
        end = pos + direction * seg_len
        if flat:
            end = Vector((end.x, 0.0, end.z))
        place_segment(pos, end, ra, rb)

        if depth + 1 >= iterations:
            return

        do_split = rng.random() < branch_prob
        side, binormal = _orthonormal_basis(direction)

        if flat:
            # Always bend around plane normal → stay in XZ
            bend_axis = plane_normal
            if do_split:
                for sign in (-1.0, 1.0):
                    ang = split_rad * (0.85 + 0.3 * rng.random()) * sign
                    child_dir = rotate_around(direction, bend_axis, ang)
                    child_dir = project_to_plane(child_dir)
                    if sunlight > 1e-6:
                        child_dir = project_to_plane(
                            (child_dir + sun_dir * sunlight * 0.15).normalized()
                        )
                    grow(end, child_dir, depth + 1)
                if rng.random() < 0.35:
                    mid = project_to_plane(
                        rotate_around(direction, bend_axis, (rng.random() - 0.5) * 0.2)
                    )
                    grow(end, mid, depth + 1)
            else:
                jitter = (rng.random() - 0.5) * 0.35
                grow(end, rotate_around(direction, bend_axis, jitter), depth + 1)
            return

        # --- 3D volume mode ---
        if do_split:
            twist = rng.random() * math.tau
            axis_b = direction.cross(
                (side * math.cos(twist) + binormal * math.sin(twist)).normalized()
            )
            if axis_b.length > 1e-6:
                axis_b.normalize()
            else:
                axis_b = binormal

            child_count = 2 if rng.random() < 0.55 else 3
            for i in range(child_count):
                az = twist + (math.tau * i / child_count) + (rng.random() - 0.5) * 0.35
                bend_axis = (side * math.cos(az) + binormal * math.sin(az)).normalized()
                ang = split_rad * (0.75 + 0.5 * rng.random())
                child_dir = rotate_around(direction, bend_axis, ang)
                child_dir = rotate_around(child_dir, direction, (rng.random() - 0.5) * 0.6)
                if sunlight > 1e-6:
                    child_dir = (child_dir + sun_dir * sunlight * 0.12).normalized()
                grow(end, child_dir, depth + 1)

            if rng.random() < 0.4:
                mid = rotate_around(direction, axis_b, (rng.random() - 0.5) * 0.25)
                grow(end, mid, depth + 1)
        else:
            j1 = (rng.random() - 0.5) * 0.45
            j2 = (rng.random() - 0.5) * 0.45
            nxt = rotate_around(direction, side, j1)
            nxt = rotate_around(nxt, binormal, j2)
            grow(end, nxt, depth + 1)

    root = Vector((0.0, 0.0, 0.0))
    samples.append(Sample(root.copy(), radius_at_depth(0) * 1.15))
    if flat:
        lean = Vector(((rng.random() - 0.5) * 0.3, 0.0, 1.0)).normalized()
    else:
        lean = Vector((rng.random() - 0.5, rng.random() - 0.5, 1.0)).normalized()
    grow(root, lean, 0)
    return samples


# ---------------------------------------------------------------------------
# Scene helpers
# ---------------------------------------------------------------------------


def _settings(context) -> "CoralGenSettings":
    return context.scene.coral_gen


def _delete_by_prefix(prefix: str) -> int:
    removed = 0
    for obj in list(bpy.data.objects):
        if obj.name == prefix or obj.name.startswith(prefix + "."):
            data = obj.data
            is_meta = obj.type == "META"
            is_mesh = obj.type == "MESH"
            bpy.data.objects.remove(obj, do_unlink=True)
            if data is not None and data.users == 0:
                if is_meta:
                    try:
                        bpy.data.metaballs.remove(data)
                    except Exception:
                        pass
                elif is_mesh:
                    try:
                        bpy.data.meshes.remove(data)
                    except Exception:
                        pass
            removed += 1
    for mb in list(bpy.data.metaballs):
        if (mb.name == prefix or mb.name.startswith(prefix + ".")) and mb.users == 0:
            bpy.data.metaballs.remove(mb)
    return removed


def _unique_name(datablock_collection, base: str) -> str:
    """Return base or base.001, base.002, … without renaming existing datablocks."""
    if base not in datablock_collection:
        return base
    i = 1
    while True:
        candidate = f"{base}.{i:03d}"
        if candidate not in datablock_collection:
            return candidate
        i += 1


def _cursor_matrix(context) -> Matrix:
    return context.scene.cursor.matrix.copy()


def _ensure_object_mode():
    try:
        if bpy.context.mode != "OBJECT":
            bpy.ops.object.mode_set(mode="OBJECT")
    except Exception:
        pass


def build_preview_meta(samples: list[Sample], settings: "CoralGenSettings", world_matrix: Matrix) -> bpy.types.Object:
    global _PRESERVED_RENDER_RESOLUTION
    _ensure_object_mode()
    _delete_by_prefix(PREVIEW_NAME)

    mb = bpy.data.metaballs.new(PREVIEW_NAME)
    obj = bpy.data.objects.new(PREVIEW_NAME, mb)
    bpy.context.collection.objects.link(obj)

    mb.threshold = float(settings.meta_threshold)
    mb.resolution = float(settings.preview_resolution)
    if _PRESERVED_RENDER_RESOLUTION is not None:
        mb.render_resolution = float(_PRESERVED_RENDER_RESOLUTION)
        _PRESERVED_RENDER_RESOLUTION = None
    else:
        mb.render_resolution = max(0.05, float(settings.preview_resolution) * 0.85)

    stiff = float(settings.meta_stiffness)
    for s in samples:
        e = mb.elements.new(type="BALL")
        e.co = world_matrix @ s.co
        e.radius = max(0.01, float(s.radius))
        e.stiffness = stiff

    obj.matrix_world = Matrix.Identity(4)
    return obj


def _delete_loose_islands(mesh_obj: bpy.types.Object) -> int:
    """
    Delete every disconnected mesh component except the largest (by face count).
    Returns how many islands were removed (floating balls / unfused blobs).
    """
    import bmesh

    me = mesh_obj.data
    if me is None or len(me.vertices) == 0:
        return 0

    bm = bmesh.new()
    bm.from_mesh(me)
    bm.verts.ensure_lookup_table()

    visited: set[int] = set()
    islands: list[list] = []
    for start in bm.verts:
        if start.index in visited:
            continue
        stack = [start]
        island = []
        visited.add(start.index)
        while stack:
            v = stack.pop()
            island.append(v)
            for e in v.link_edges:
                other = e.other_vert(v)
                if other.index not in visited:
                    visited.add(other.index)
                    stack.append(other)
        islands.append(island)

    if len(islands) <= 1:
        bm.free()
        return 0

    def face_count(verts) -> int:
        faces = set()
        for v in verts:
            for f in v.link_faces:
                faces.add(f.index)
        return len(faces)

    islands.sort(key=face_count, reverse=True)
    to_delete = []
    for island in islands[1:]:
        to_delete.extend(island)

    bmesh.ops.delete(bm, geom=to_delete, context="VERTS")
    bm.to_mesh(me)
    bm.free()
    me.update()
    return len(islands) - 1


def finalize_mesh(context, settings: "CoralGenSettings") -> tuple[bpy.types.Object, int]:
    """
    Convert preview meta → mesh, then Decimate to target faces.

    Voxel Remesh is optional and OFF by default — it re-samples onto a grid and
    eats thin branches smaller than the voxel size (the usual 'preview good,
    mesh blobby + still high poly' failure mode).
    """
    _ensure_object_mode()
    preview = bpy.data.objects.get(PREVIEW_NAME)
    if not preview or preview.type != "META":
        samples = grow_coral(
            seed=settings.seed,
            iterations=settings.iterations,
            branch_length=settings.branch_length,
            split_angle_deg=settings.split_angle,
            branch_prob=settings.branch_probability,
            sunlight=settings.sunlight_pull,
            base_radius=settings.base_radius,
            tip_taper=settings.tip_taper,
            growth_mode=settings.growth_mode,
        )
        preview = build_preview_meta(samples, settings, _cursor_matrix(context))

    mb = preview.data
    # Bake at the resolution the user is actually seeing (never coarsen).
    old_res = float(mb.resolution)
    old_render = float(mb.render_resolution)
    old_threshold = float(mb.threshold)
    bake_res = min(float(settings.preview_resolution), old_res)
    mb.resolution = bake_res
    mb.render_resolution = bake_res
    mb.threshold = float(settings.meta_threshold)
    context.view_layer.update()

    for o in context.view_layer.objects:
        o.select_set(False)
    preview.select_set(True)
    context.view_layer.objects.active = preview

    try:
        bpy.ops.object.convert(target="MESH", keep_original=True)
    finally:
        mb.resolution = old_res
        mb.render_resolution = old_render
        mb.threshold = old_threshold

    mesh_obj = context.view_layer.objects.active
    if mesh_obj is None or mesh_obj.type != "MESH":
        mesh_obj = None
        for obj in bpy.data.objects:
            if obj.type == "MESH" and obj.name.startswith(PREVIEW_NAME):
                mesh_obj = obj
                break
        if mesh_obj is None:
            raise RuntimeError("Meta → mesh conversion failed")

    mesh_name = _unique_name(bpy.data.objects, MESH_NAME)
    mesh_obj.name = mesh_name
    if mesh_obj.data:
        mesh_obj.data.name = _unique_name(bpy.data.meshes, MESH_NAME)

    # Drop convert leftovers still named like the preview
    for obj in list(bpy.data.objects):
        if obj.type == "MESH" and obj.name.startswith(PREVIEW_NAME) and obj != mesh_obj:
            me = obj.data
            bpy.data.objects.remove(obj, do_unlink=True)
            if me and me.users == 0:
                bpy.data.meshes.remove(me)

    for o in context.view_layer.objects:
        o.select_set(False)
    mesh_obj.select_set(True)
    context.view_layer.objects.active = mesh_obj

    # Light cleanup on the meta tessellation (keeps shape, merges micro-verts)
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.mesh.remove_doubles(threshold=0.0005)
    bpy.ops.object.mode_set(mode="OBJECT")

    loose_removed = 0
    if settings.remove_loose_balls:
        loose_removed = _delete_loose_islands(mesh_obj)

    while mesh_obj.modifiers:
        mesh_obj.modifiers.remove(mesh_obj.modifiers[0])

    target = max(100, min(10000, int(settings.target_faces)))
    base_faces = len(mesh_obj.data.polygons) if mesh_obj.data else 0

    if settings.use_voxel_remesh:
        remesh = mesh_obj.modifiers.new(name="CoralGen_Remesh", type="REMESH")
        remesh.mode = "VOXEL"
        remesh.voxel_size = max(0.01, float(settings.voxel_size))
        remesh.use_smooth_shade = True
        depsgraph = context.evaluated_depsgraph_get()
        eval_obj = mesh_obj.evaluated_get(depsgraph)
        eval_mesh = eval_obj.to_mesh()
        remesh_faces = len(eval_mesh.polygons) if eval_mesh else 0
        eval_obj.to_mesh_clear()
        source_faces = remesh_faces
    else:
        source_faces = base_faces

    dec = mesh_obj.modifiers.new(name="CoralGen_Decimate", type="DECIMATE")
    dec.decimate_type = "COLLAPSE"
    dec.use_collapse_triangulate = True
    if source_faces <= target or source_faces < 50:
        dec.ratio = 1.0
        face_count = source_faces
    else:
        dec.ratio = max(0.01, min(1.0, target / float(source_faces)))
        depsgraph = context.evaluated_depsgraph_get()
        eval_obj = mesh_obj.evaluated_get(depsgraph)
        eval_mesh = eval_obj.to_mesh()
        face_count = len(eval_mesh.polygons) if eval_mesh else source_faces
        eval_obj.to_mesh_clear()
        if face_count > 50 and abs(face_count - target) / max(target, 1) > 0.35:
            dec.ratio = max(0.01, min(1.0, dec.ratio * (target / max(face_count, 1))))
            depsgraph = context.evaluated_depsgraph_get()
            eval_obj = mesh_obj.evaluated_get(depsgraph)
            eval_mesh = eval_obj.to_mesh()
            face_count = len(eval_mesh.polygons) if eval_mesh else face_count
            eval_obj.to_mesh_clear()

    # Apply so the datablock IS the game mesh (matches target count)
    if settings.use_voxel_remesh:
        bpy.ops.object.modifier_apply(modifier="CoralGen_Remesh")
    bpy.ops.object.modifier_apply(modifier="CoralGen_Decimate")
    try:
        bpy.ops.object.shade_smooth()
    except Exception:
        pass

    face_count = len(mesh_obj.data.polygons) if mesh_obj.data else face_count
    for o in context.view_layer.objects:
        o.select_set(False)
    mesh_obj.select_set(True)
    context.view_layer.objects.active = mesh_obj
    # Stash island count on the object for status reporting
    mesh_obj["coral_gen_loose_removed"] = loose_removed
    return mesh_obj, face_count


# ---------------------------------------------------------------------------
# Properties
# ---------------------------------------------------------------------------


class CoralGenSettings(PropertyGroup):
    status: StringProperty(
        name="Status",
        default="Set growth knobs, then Generate Preview",
    )
    auto_preview_update: BoolProperty(
        name="Auto Preview Update",
        description="When enabled, dragging Growth/Shape/fusing sliders regenerates the metaball preview",
        default=False,
    )
    growth_mode: EnumProperty(
        name="Growth",
        description="2D = planar sea-fan in XZ. 3D = full volume bush",
        items=(
            ("FLAT", "2D", "Planar fan (XZ) — silhouette / sea-fan style"),
            ("VOLUME", "3D", "Full 3D branching bush"),
        ),
        default="VOLUME",
        update=_preview_slider_update,
    )

    # Growth
    seed: IntProperty(
        name="Seed",
        description="Random seed for reproducible growth",
        default=42,
        min=0,
        max=2_147_483_647,
        update=_preview_slider_update,
    )
    iterations: IntProperty(
        name="Iterations",
        description="How many times branches deepen (1–16). High values get denser — use Auto Preview carefully",
        default=4,
        min=1,
        max=16,
        update=_preview_slider_update,
    )
    branch_length: FloatProperty(
        name="Branch Length",
        description="Length scale of each growth segment",
        default=0.55,
        min=0.05,
        max=3.0,
        soft_min=0.2,
        soft_max=1.5,
        update=_preview_slider_update,
    )
    split_angle: FloatProperty(
        name="Split Angle",
        description="Degrees child branches diverge from the parent",
        default=35.0,
        min=5.0,
        max=90.0,
        soft_min=15.0,
        soft_max=60.0,
        update=_preview_slider_update,
    )
    branch_probability: FloatProperty(
        name="Branching Probability",
        description="Chance a tip splits into child branches",
        default=0.72,
        min=0.0,
        max=1.0,
        update=_preview_slider_update,
    )
    sunlight_pull: FloatProperty(
        name="Sunlight Pull",
        description="Bias growth upward along +Z",
        default=0.65,
        min=0.0,
        max=2.0,
        soft_min=0.0,
        soft_max=1.5,
        update=_preview_slider_update,
    )

    # Shape
    base_radius: FloatProperty(
        name="Base Radius",
        description="Metaball radius at the root",
        default=0.22,
        min=0.02,
        max=1.5,
        soft_min=0.08,
        soft_max=0.5,
        update=_preview_slider_update,
    )
    tip_taper: FloatProperty(
        name="Tip Taper",
        description="How much radius shrinks toward tips (0=none, 1=strong)",
        default=0.7,
        min=0.0,
        max=1.0,
        update=_preview_slider_update,
    )

    # Finalize / meta
    meta_threshold: FloatProperty(
        name="Smooth Fusing",
        description="Metaball Influence Threshold (lower = thicker fused surface)",
        default=0.1,
        min=0.01,
        max=3.0,
        soft_min=0.05,
        soft_max=1.5,
        update=_meta_surface_slider_update,
    )
    meta_stiffness: FloatProperty(
        name="Stiffness",
        description="Metaball element stiffness",
        default=2.0,
        min=0.5,
        max=5.0,
        update=_meta_surface_slider_update,
    )
    preview_resolution: FloatProperty(
        name="Preview Resolution",
        description="Metaball viewport resolution (lower = finer). Finalize bakes at this quality",
        default=0.05,
        min=0.01,
        max=0.5,
        soft_min=0.05,
        soft_max=0.3,
        update=_meta_surface_slider_update,
    )
    use_voxel_remesh: BoolProperty(
        name="Voxel Remesh",
        description=(
            "OFF (recommended): Decimate the meta convert so thin branches survive. "
            "ON: Voxel Remesh first — cleaner topo but eats tips smaller than Voxel Size"
        ),
        default=False,
    )
    remove_loose_balls: BoolProperty(
        name="Remove Loose Balls",
        description=(
            "On finalize, delete disconnected floating blobs (unfused metaballs) "
            "and keep only the largest connected coral piece"
        ),
        default=True,
    )
    voxel_size: FloatProperty(
        name="Voxel Size",
        description="Only used if Voxel Remesh is on. Must be smaller than tip thickness or detail vanishes",
        default=0.04,
        min=0.01,
        max=0.5,
        soft_min=0.02,
        soft_max=0.15,
    )
    target_faces: IntProperty(
        name="Target Faces",
        description="Decimate toward this face count after convert (100–10000). Main poly budget control",
        default=4000,
        min=100,
        max=10000,
    )


# ---------------------------------------------------------------------------
# Operators
# ---------------------------------------------------------------------------


class CORALGEN_OT_generate_preview(Operator):
    bl_idname = "coral_gen.generate_preview"
    bl_label = "Generate Preview"
    bl_description = "Grow coral L-system into metaballs (replaces previous preview)"
    bl_options = {"REGISTER", "UNDO"}

    def execute(self, context):
        s = _settings(context)
        try:
            regenerate_preview(context, s, sync_meta_from_live=True)
            self.report({"INFO"}, s.status)
            return {"FINISHED"}
        except Exception as e:
            s.status = f"Preview failed: {e}"
            self.report({"ERROR"}, str(e))
            return {"CANCELLED"}


class CORALGEN_OT_finalize(Operator):
    bl_idname = "coral_gen.finalize"
    bl_label = "Finalize to Mesh"
    bl_description = "Convert preview to a new mesh (keeps previous finalized meshes). Remesh + Decimate (100–10k faces)"
    bl_options = {"REGISTER", "UNDO"}

    def execute(self, context):
        s = _settings(context)
        try:
            mesh_obj, faces = finalize_mesh(context, s)
            mode = "remesh+decimate" if s.use_voxel_remesh else "decimate"
            loose = int(mesh_obj.get("coral_gen_loose_removed", 0))
            loose_txt = f", dropped {loose} loose" if loose else ""
            s.status = (
                f"Finalized {mesh_obj.name}: {faces} faces "
                f"(target {s.target_faces}, {mode}{loose_txt})"
            )
            self.report({"INFO"}, s.status)
            return {"FINISHED"}
        except Exception as e:
            s.status = f"Finalize failed: {e}"
            self.report({"ERROR"}, str(e))
            return {"CANCELLED"}


class CORALGEN_OT_clear(Operator):
    bl_idname = "coral_gen.clear"
    bl_label = "Clear"
    bl_description = "Remove Coral Gen preview metaballs and all finalized CoralGen_Mesh objects"
    bl_options = {"REGISTER", "UNDO"}

    def execute(self, context):
        s = _settings(context)
        try:
            _ensure_object_mode()
            n_prev = _delete_by_prefix(PREVIEW_NAME)
            n_mesh = _delete_by_prefix(MESH_NAME)
            s.status = f"Cleared preview×{n_prev}, mesh×{n_mesh}"
            self.report({"INFO"}, s.status)
            return {"FINISHED"}
        except Exception as e:
            s.status = f"Clear failed: {e}"
            self.report({"ERROR"}, str(e))
            return {"CANCELLED"}


# ---------------------------------------------------------------------------
# UI
# ---------------------------------------------------------------------------


class CORALGEN_PT_main(Panel):
    bl_label = "Coral Gen"
    bl_idname = "CORALGEN_PT_main"
    bl_space_type = "VIEW_3D"
    bl_region_type = "UI"
    bl_category = "Procedural Coral"

    def draw(self, context):
        layout = self.layout
        s = context.scene.coral_gen

        top = layout.box()
        top.prop(s, "auto_preview_update", toggle=True, icon="FILE_REFRESH")
        if s.auto_preview_update:
            top.label(text="Sliders rebuild preview live", icon="INFO")
        else:
            top.label(text="Use Generate Preview after edits", icon="INFO")
        top.prop(s, "growth_mode", expand=True)

        col = layout.column(align=True)
        col.scale_y = 1.2
        col.operator("coral_gen.generate_preview", icon="OUTLINER_OB_META")
        col.operator("coral_gen.finalize", icon="MESH_DATA")
        col.operator("coral_gen.clear", icon="TRASH")

        box = layout.box()
        box.label(text="Growth & Structure")
        box.prop(s, "seed")
        box.prop(s, "iterations")
        box.prop(s, "branch_length")
        box.prop(s, "split_angle")
        box.prop(s, "branch_probability", slider=True)
        box.prop(s, "sunlight_pull", slider=True)

        box = layout.box()
        box.label(text="Shape")
        box.prop(s, "base_radius")
        box.prop(s, "tip_taper", slider=True)

        box = layout.box()
        box.label(text="Finalize")
        box.prop(s, "meta_threshold", slider=True)
        box.prop(s, "meta_stiffness")
        box.prop(s, "preview_resolution")
        box.prop(s, "target_faces")
        box.prop(s, "remove_loose_balls", toggle=True)
        box.prop(s, "use_voxel_remesh", toggle=True)
        if s.use_voxel_remesh:
            box.prop(s, "voxel_size")
            box.label(text="Voxel eats tips thinner than size", icon="ERROR")
        else:
            box.label(text="Decimate-only keeps meta silhouette", icon="INFO")

        layout.separator()
        layout.label(text="Status:")
        for line in _wrap(s.status, 40):
            layout.label(text=line)


def _wrap(text: str, width: int) -> list[str]:
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


# ---------------------------------------------------------------------------
# Register
# ---------------------------------------------------------------------------

CLASSES = (
    CoralGenSettings,
    CORALGEN_OT_generate_preview,
    CORALGEN_OT_finalize,
    CORALGEN_OT_clear,
    CORALGEN_PT_main,
)


def register():
    for cls in CLASSES:
        bpy.utils.register_class(cls)
    Scene.coral_gen = PointerProperty(type=CoralGenSettings)


def unregister():
    if hasattr(Scene, "coral_gen"):
        del Scene.coral_gen
    for cls in reversed(CLASSES):
        bpy.utils.unregister_class(cls)


if __name__ == "__main__":
    register()
