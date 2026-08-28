"""Operators for Tracer N-panel."""

from __future__ import annotations

import importlib
import json
import os
import sys
import webbrowser

import bpy
from bpy.types import Operator

_ADDON_DIR = os.path.dirname(os.path.abspath(__file__))
_ROOT = os.path.dirname(_ADDON_DIR)
if _ROOT not in sys.path:
    sys.path.insert(0, _ROOT)


def _settings(context):
    return context.scene.meta_tracer


def _require_image_empty(context):
    obj = context.view_layer.objects.active
    s = _settings(context)
    if obj and obj.type == "EMPTY" and obj.data and hasattr(obj.data, "size"):
        s.grid_source_empty = obj.name
        return obj
    if s.grid_source_empty:
        empty = bpy.data.objects.get(s.grid_source_empty)
        if empty and empty.type == "EMPTY" and empty.data and hasattr(empty.data, "size"):
            return empty
    if not obj or obj.type != "EMPTY":
        raise ValueError("Select an Image Empty first (active object)")
    if not obj.data or not hasattr(obj.data, "size"):
        raise ValueError(f"Active empty '{obj.name}' has no image assigned")
    return obj


def _scan_kwargs(s) -> dict:
    return {
        "threshold": s.threshold,
        "stiffness": s.stiffness,
        "resolution": s.resolution,
        "r_tip": s.r_tip,
        "r_trunk": s.r_trunk,
        "depth_local": s.depth_local,
        "min_blob_px": s.min_blob_px,
        "keep_components": s.keep_components,
        "mask_step": s.mask_step,
        "line_art": s.line_art,
        "mask_luminance": s.mask_luminance,
        "grid_density": s.grid_density,
        "thickness_mult": s.thickness_mult,
        "write_preview": True,
    }


def _reload_trace_modules():
    for name in ("shape_trace_io", "scan_shape", "build_metaballs", "trace_shape", "meta_grid"):
        if name in sys.modules:
            importlib.reload(sys.modules[name])
        else:
            try:
                __import__(name)
            except Exception:
                pass


def _open_preview_in_blender(path: str):
    if not os.path.isfile(path):
        return
    img_name = os.path.basename(path)
    existing = bpy.data.images.get(img_name)
    if existing:
        bpy.data.images.remove(existing)
    img = bpy.data.images.load(path, check_existing=False)
    img.name = img_name
    for window in bpy.context.window_manager.windows:
        for area in window.screen.areas:
            if area.type == "IMAGE_EDITOR":
                for space in area.spaces:
                    if space.type == "IMAGE_EDITOR":
                        space.image = img
                        area.tag_redraw()
                        return
    try:
        webbrowser.open(path)
    except Exception:
        pass


def _status_from_trace(name: str) -> str:
    from shape_trace_io import trace_json_path

    path = trace_json_path(name)
    if not os.path.isfile(path):
        return "No trace JSON yet"
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
    st = data.get("scan_stats", {})
    types = {}
    for el in data.get("elements", []):
        types[el["type"]] = types.get(el["type"], 0) + 1
    return (
        f"{st.get('elements', len(data.get('elements', [])))} elems "
        f"(cap {types.get('CAPSULE', 0)} / ball {types.get('BALL', 0)} / ell {types.get('ELLIPSOID', 0)}) | "
        f"forbidden {st.get('forbidden', len(data.get('forbidden_pairs', [])))}"
    )


class METATRACER_OT_scan_build(Operator):
    bl_idname = "meta_tracer.scan_build"
    bl_label = "Scan and Build"
    bl_description = "Trace mode: scan active Image Empty then build metas"
    bl_options = {"REGISTER", "UNDO"}

    def execute(self, context):
        s = _settings(context)
        try:
            empty = _require_image_empty(context)
            _reload_trace_modules()
            import scan_shape
            import build_metaballs
            from shape_trace_io import preview_png_path

            scan_shape.scan(empty.name, **_scan_kwargs(s))
            n = build_metaballs.build(
                empty.name,
                threshold=s.threshold,
                resolution=s.resolution,
                clear=True,
            )
            msg = _status_from_trace(empty.name)
            s.status = f"Scan+Build {empty.name}: {msg} → {n} placed"
            if s.auto_open_preview:
                _open_preview_in_blender(preview_png_path(empty.name))
            self.report({"INFO"}, s.status)
            return {"FINISHED"}
        except Exception as e:
            s.status = f"Scan+Build failed: {e}"
            self.report({"ERROR"}, str(e))
            return {"CANCELLED"}


class METATRACER_OT_metagrid_refresh(Operator):
    bl_idname = "meta_tracer.metagrid_refresh"
    bl_label = "Refresh Grid"
    bl_description = "Rebuild MetaGrid from current sliders (usually automatic)"
    bl_options = {"REGISTER", "UNDO"}

    def execute(self, context):
        s = _settings(context)
        try:
            empty = _require_image_empty(context)
            s.grid_source_empty = empty.name
            _reload_trace_modules()
            import meta_grid

            msg = meta_grid.live_update(context)
            self.report({"INFO"}, msg or s.status)
            return {"FINISHED"}
        except Exception as e:
            s.status = f"MetaGrid failed: {e}"
            self.report({"ERROR"}, str(e))
            return {"CANCELLED"}


class METATRACER_OT_metagrid_cull(Operator):
    bl_idname = "meta_tracer.metagrid_cull"
    bl_label = "Cull White Now"
    bl_description = "Enable white cull and rebuild — keeps only elements over non-white ink"
    bl_options = {"REGISTER", "UNDO"}

    def execute(self, context):
        s = _settings(context)
        try:
            empty = _require_image_empty(context)
            s.grid_source_empty = empty.name
            s.grid_cull_white = True
            _reload_trace_modules()
            import meta_grid

            msg = meta_grid.live_update(context)
            self.report({"INFO"}, msg or s.status)
            return {"FINISHED"}
        except Exception as e:
            s.status = f"Cull failed: {e}"
            self.report({"ERROR"}, str(e))
            return {"CANCELLED"}


class METATRACER_OT_metagrid_fill_types(Operator):
    bl_idname = "meta_tracer.metagrid_fill_types"
    bl_label = "Fill Types = Grid"
    bl_description = "Set Balls count to Wide×Tall and clear Ellipsoids/Capsules (all balls)"
    bl_options = {"REGISTER", "UNDO"}

    def execute(self, context):
        s = _settings(context)
        slots = max(1, int(s.grid_count_x) * int(s.grid_count_y))
        s.grid_n_ball = slots
        s.grid_n_ellipsoid = 0
        s.grid_n_capsule = 0
        s.status = f"Types set to {slots} balls"
        return {"FINISHED"}


class METATRACER_OT_clear_meta(Operator):
    bl_idname = "meta_tracer.clear_meta"
    bl_label = "Clear Meta"
    bl_description = "Remove the <EmptyName>_Meta object"
    bl_options = {"REGISTER", "UNDO"}

    def execute(self, context):
        s = _settings(context)
        try:
            empty = _require_image_empty(context)
            name = f"{empty.name}_Meta"
            obj = bpy.data.objects.get(name)
            if not obj:
                s.status = f"No object named {name}"
                self.report({"WARNING"}, s.status)
                return {"CANCELLED"}
            try:
                if bpy.context.mode != "OBJECT":
                    bpy.ops.object.mode_set(mode="OBJECT")
            except Exception:
                pass
            mb = obj.data if obj.type == "META" else None
            bpy.data.objects.remove(obj, do_unlink=True)
            if mb and mb.users == 0:
                bpy.data.metaballs.remove(mb)
            s.status = f"Cleared {name}"
            self.report({"INFO"}, s.status)
            return {"FINISHED"}
        except Exception as e:
            s.status = f"Clear failed: {e}"
            self.report({"ERROR"}, str(e))
            return {"CANCELLED"}


class METATRACER_OT_open_preview_folder(Operator):
    bl_idname = "meta_tracer.open_preview_folder"
    bl_label = "Open Preview Folder"
    bl_description = "Open the Traces folder in the system file browser"

    def execute(self, context):
        s = _settings(context)
        try:
            from shape_trace_io import traces_dir

            path = traces_dir()
            if sys.platform == "win32":
                os.startfile(path)  # type: ignore[attr-defined]
            elif sys.platform == "darwin":
                os.system(f'open "{path}"')
            else:
                os.system(f'xdg-open "{path}"')
            s.status = f"Opened {path}"
            return {"FINISHED"}
        except Exception as e:
            s.status = f"Open folder failed: {e}"
            self.report({"ERROR"}, str(e))
            return {"CANCELLED"}


class METATRACER_OT_open_preview(Operator):
    bl_idname = "meta_tracer.open_preview"
    bl_label = "Open Preview"
    bl_description = "Open Traces/<name>_preview.png (Trace mode)"

    def execute(self, context):
        s = _settings(context)
        try:
            empty = _require_image_empty(context)
            from shape_trace_io import preview_png_path

            path = preview_png_path(empty.name)
            if not os.path.isfile(path):
                raise FileNotFoundError(f"No preview yet — run Scan and Build first ({path})")
            _open_preview_in_blender(path)
            s.status = f"Opened preview {os.path.basename(path)}"
            return {"FINISHED"}
        except Exception as e:
            s.status = str(e)
            self.report({"ERROR"}, str(e))
            return {"CANCELLED"}


class METATRACER_OT_reload_addon(Operator):
    bl_idname = "meta_tracer.reload_addon"
    bl_label = "Reload Addon"
    bl_description = "Reload Meta Trace Python modules (after editing scripts)"

    def execute(self, context):
        s = _settings(context)
        try:
            _reload_trace_modules()
            import meta_tracer
            import meta_tracer.properties as props
            import meta_tracer.operators as ops
            import meta_tracer.ui as ui

            meta_tracer.unregister()
            importlib.reload(props)
            importlib.reload(ops)
            importlib.reload(ui)
            importlib.reload(meta_tracer)
            meta_tracer.register()
            s.status = "Addon reloaded"
            self.report({"INFO"}, "Meta Trace reloaded")
            return {"FINISHED"}
        except Exception as e:
            try:
                bpy.ops.preferences.addon_disable(module="meta_tracer")
                bpy.ops.preferences.addon_enable(module="meta_tracer")
                s.status = f"Addon toggled ({e})"
                return {"FINISHED"}
            except Exception as e2:
                s.status = f"Reload failed: {e2}"
                self.report({"ERROR"}, str(e2))
                return {"CANCELLED"}


CLASSES = (
    METATRACER_OT_scan_build,
    METATRACER_OT_metagrid_refresh,
    METATRACER_OT_metagrid_cull,
    METATRACER_OT_metagrid_fill_types,
    METATRACER_OT_clear_meta,
    METATRACER_OT_open_preview_folder,
    METATRACER_OT_open_preview,
    METATRACER_OT_reload_addon,
)


def register():
    for cls in CLASSES:
        bpy.utils.register_class(cls)


def unregister():
    for cls in reversed(CLASSES):
        bpy.utils.unregister_class(cls)
