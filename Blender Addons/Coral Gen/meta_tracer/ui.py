"""N-panel UI: View3D → Sidebar → Tracer."""

from __future__ import annotations

import bpy
from bpy.types import Panel


class METATRACER_PT_main(Panel):
    bl_label = "Meta Trace"
    bl_idname = "METATRACER_PT_main"
    bl_space_type = "VIEW_3D"
    bl_region_type = "UI"
    bl_category = "Tracer"

    def draw(self, context):
        layout = self.layout
        s = context.scene.meta_tracer
        obj = context.view_layer.objects.active

        box = layout.box()
        if obj and obj.type == "EMPTY" and obj.data:
            box.label(text=f"Active: {obj.name}", icon="IMAGE_DATA")
        elif s.grid_source_empty and bpy.data.objects.get(s.grid_source_empty):
            box.label(text=f"Grid source: {s.grid_source_empty}", icon="IMAGE_DATA")
        elif obj and obj.type == "EMPTY":
            box.label(text=f"{obj.name} (no image)", icon="ERROR")
        else:
            box.label(text="Select an Image Empty", icon="INFO")

        layout.prop(s, "tool_mode", expand=True)
        layout.separator()

        if s.tool_mode == "METAGRID":
            self._draw_metagrid(layout, s)
        else:
            self._draw_trace(layout, s)

        layout.separator()
        layout.label(text="Status:")
        for line in _wrap(s.status, 42):
            layout.label(text=line)

        layout.separator()
        layout.operator("meta_tracer.reload_addon", icon="FILE_REFRESH")

    def _draw_metagrid(self, layout, s):
        col = layout.column(align=True)
        col.scale_y = 1.15
        col.operator("meta_tracer.metagrid_refresh", icon="FILE_REFRESH")
        row = col.row(align=True)
        row.operator("meta_tracer.metagrid_cull", icon="FILTER")
        row.operator("meta_tracer.clear_meta", icon="TRASH")

        layout.separator()
        layout.label(text="Grid layout")
        row = layout.row(align=True)
        row.prop(s, "grid_count_x")
        row.prop(s, "grid_count_y")
        layout.prop(s, "grid_density_x", slider=True)
        layout.prop(s, "grid_density_y", slider=True)

        layout.separator()
        layout.label(text="Element mix (fills Wide×Tall)")
        row = layout.row(align=True)
        row.prop(s, "grid_n_ball")
        row.prop(s, "grid_n_ellipsoid")
        row.prop(s, "grid_n_capsule")
        layout.operator("meta_tracer.metagrid_fill_types", icon="UV_SYNC_SELECT")

        layout.separator()
        layout.prop(s, "grid_element_size", slider=True)

        layout.separator()
        layout.prop(s, "grid_cull_white")
        if s.grid_cull_white:
            layout.prop(s, "grid_white_cutoff", slider=True)
        layout.prop(s, "grid_show_rings")

        layout.prop(s, "show_advanced", icon="TRIA_DOWN" if s.show_advanced else "TRIA_RIGHT", emboss=False)
        if s.show_advanced:
            adv = layout.box()
            adv.prop(s, "threshold", slider=True)
            adv.prop(s, "stiffness", slider=True)
            adv.prop(s, "resolution", slider=True)
            adv.prop(s, "depth_local")

    def _draw_trace(self, layout, s):
        col = layout.column(align=True)
        col.scale_y = 1.2
        col.operator("meta_tracer.scan_build", icon="PLAY")

        row = layout.row(align=True)
        row.operator("meta_tracer.clear_meta", icon="TRASH")
        row.operator("meta_tracer.open_preview", icon="IMAGE")

        row = layout.row(align=True)
        row.operator("meta_tracer.open_preview_folder", icon="FILE_FOLDER")

        layout.separator()
        layout.prop(s, "grid_density", slider=True)
        layout.prop(s, "thickness_mult", slider=True)

        layout.prop(s, "show_advanced", icon="TRIA_DOWN" if s.show_advanced else "TRIA_RIGHT", emboss=False)
        if s.show_advanced:
            adv = layout.box()
            adv.prop(s, "line_art")
            adv.prop(s, "mask_luminance", slider=True)
            adv.prop(s, "threshold", slider=True)
            adv.prop(s, "stiffness", slider=True)
            adv.prop(s, "resolution", slider=True)
            adv.prop(s, "r_tip")
            adv.prop(s, "r_trunk")
            adv.prop(s, "depth_local")
            adv.prop(s, "mask_step")
            adv.prop(s, "min_blob_px")
            adv.prop(s, "keep_components")
            adv.prop(s, "auto_open_preview")


def _wrap(text: str, width: int) -> list[str]:
    if not text:
        return [""]
    words = text.split()
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


CLASSES = (METATRACER_PT_main,)


def register():
    for cls in CLASSES:
        bpy.utils.register_class(cls)


def unregister():
    for cls in reversed(CLASSES):
        bpy.utils.unregister_class(cls)
