"""
Export Leather Coral for Roblox — one FBX per size with Main + Accent aligned.

Base = MainColor mesh. All other collection meshes join into Accent.
Separate Main/Accent FBX imports are re-centered by Roblox and will NOT line up.

Run in Blender Scripting:
    exec(open(r"C:\\Game Dev\\Ocean TD\\Models\\Leather Coral\\export_leather_coral_fbx.py").read())
"""

from __future__ import annotations

import os

import bpy
from mathutils import Vector

ROOT = r"C:\Game Dev\Ocean TD\Models\Leather Coral"
if "__file__" in dir() and __file__:  # noqa: F821
    try:
        ROOT = os.path.dirname(os.path.abspath(__file__))  # type: ignore[name-defined]
    except Exception:
        pass

SIZES = [
    ("Leather Small", "LeatherSmall"),
    ("Leather Medium", "LeatherMed"),
    ("Leather Large", "LeatherLarge"),
]


def _is_template_polyp(name: str) -> bool:
    if name.startswith("LeatherPolyp"):
        return False
    if name in ("Polyp", "Polpy"):
        return True
    return name.startswith("Polyp.") or name.startswith("Polpy.")


def _meshes_in(col_name: str, kind: str) -> list:
    col = bpy.data.collections.get(col_name)
    if not col:
        raise RuntimeError(f"Missing collection: {col_name}")
    out = []
    for obj in col.objects:
        if obj.type != "MESH":
            continue
        if _is_template_polyp(obj.name):
            continue
        if kind == "main" and obj.name == "Base":
            out.append(obj)
        elif kind == "accent" and obj.name != "Base":
            out.append(obj)
    if not out:
        raise RuntimeError(f"No {kind} meshes in {col_name}")
    return out


def _join_copies(objs: list, name: str):
    if bpy.context.mode != "OBJECT":
        bpy.ops.object.mode_set(mode="OBJECT")
    bpy.ops.object.select_all(action="DESELECT")
    copies = []
    for src in objs:
        dup = src.copy()
        dup.data = src.data.copy()
        bpy.context.collection.objects.link(dup)
        copies.append(dup)
        dup.select_set(True)
    bpy.context.view_layer.objects.active = copies[0]
    if len(copies) > 1:
        bpy.ops.object.join()
    obj = bpy.context.view_layer.objects.active
    obj.name = name
    return obj


def _world_bbox(objs: list):
    mn = Vector((1e18, 1e18, 1e18))
    mx = Vector((-1e18, -1e18, -1e18))
    for obj in objs:
        for c in obj.bound_box:
            w = obj.matrix_world @ Vector(c)
            mn.x = min(mn.x, w.x)
            mn.y = min(mn.y, w.y)
            mn.z = min(mn.z, w.z)
            mx.x = max(mx.x, w.x)
            mx.y = max(mx.y, w.y)
            mx.z = max(mx.z, w.z)
    return mn, mx


def _origin_geometry(obj):
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.origin_set(type="ORIGIN_GEOMETRY", center="BOUNDS")


def export_all():
    for col_name, fname in SIZES:
        main_src = _meshes_in(col_name, "main")
        accent_src = _meshes_in(col_name, "accent")
        print(f"{col_name}: Main=Base ({len(main_src)}), Accent={len(accent_src)} meshes")

        main = _join_copies(main_src, "Main")
        accent = _join_copies(accent_src, "Accent")

        for obj in (main, accent):
            bpy.ops.object.select_all(action="DESELECT")
            obj.select_set(True)
            bpy.context.view_layer.objects.active = obj
            bpy.ops.object.transform_apply(location=False, rotation=True, scale=True)

        _origin_geometry(main)
        _origin_geometry(accent)

        mn, mx = _world_bbox([main, accent])
        pivot = (mn + mx) / 2
        main.location = main.matrix_world.translation - pivot
        accent.location = accent.matrix_world.translation - pivot
        bpy.context.view_layer.update()

        rel = main.matrix_world.inverted() @ accent.matrix_world
        print(f"{fname}: Accent offset from Main = {tuple(round(c, 3) for c in rel.translation)}")

        path = os.path.join(ROOT, f"{fname}.fbx")
        bpy.ops.object.select_all(action="DESELECT")
        main.select_set(True)
        accent.select_set(True)
        bpy.context.view_layer.objects.active = main
        bpy.ops.export_scene.fbx(
            filepath=path,
            use_selection=True,
            object_types={"MESH"},
            apply_scale_options="FBX_SCALE_ALL",
            bake_space_transform=True,
            axis_forward="-Z",
            axis_up="Y",
            add_leaf_bones=False,
            bake_anim=False,
        )
        print(f"  wrote {path}")

        bpy.data.objects.remove(main, do_unlink=True)
        bpy.data.objects.remove(accent, do_unlink=True)

    print("Done — import under ReplicatedStorage.Coral.LeatherCoral")


export_all()
