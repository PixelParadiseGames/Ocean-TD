"""Scene properties for the Tracer N-panel."""

from __future__ import annotations

import bpy
from bpy.props import (
    BoolProperty,
    EnumProperty,
    FloatProperty,
    IntProperty,
    StringProperty,
    PointerProperty,
)
from bpy.types import PropertyGroup, Scene


def _metagrid_update(self, context):
    try:
        import meta_grid

        meta_grid.metagrid_update(self, context)
    except Exception:
        pass


def _grid_count_update(self, context):
    # Keep an all-balls grid in sync with Wide×Tall when mix is balls-only
    if int(self.grid_n_ellipsoid) == 0 and int(self.grid_n_capsule) == 0:
        slots = max(1, int(self.grid_count_x) * int(self.grid_count_y))
        if int(self.grid_n_ball) != slots:
            self.grid_n_ball = slots
            return  # ball update will refresh
    _metagrid_update(self, context)


def _mode_update(self, context):
    if self.tool_mode == "METAGRID":
        _metagrid_update(self, context)


class MetaTracerSettings(PropertyGroup):
    status: StringProperty(
        name="Status",
        description="Last action result",
        default="Select an Image Empty",
    )

    tool_mode: EnumProperty(
        name="Mode",
        description="Trace = centerline scan. MetaGrid = live sculptable element grid",
        items=(
            ("TRACE", "Trace", "Skeleton scan along line art, then build metas"),
            ("METAGRID", "MetaGrid", "Live grid of balls/ellipsoids/capsules — sculpt with sliders"),
        ),
        default="METAGRID",
        update=_mode_update,
    )

    # --- Trace mode (legacy centerline) ---
    grid_density: FloatProperty(
        name="Grid Density",
        description="Higher = more meta elements along strokes",
        default=1.0,
        min=0.25,
        max=4.0,
        soft_min=0.5,
        soft_max=2.5,
        step=5,
    )
    thickness_mult: FloatProperty(
        name="Thickness",
        description="Scales all planned radii (limb thickness)",
        default=1.0,
        min=0.15,
        max=4.0,
        soft_min=0.4,
        soft_max=2.0,
        step=5,
    )
    show_advanced: BoolProperty(
        name="Advanced",
        description="Show fine-tune knobs",
        default=False,
    )

    line_art: BoolProperty(
        name="Line Art Mode",
        description="Treat drawing as strokes on a light background",
        default=True,
    )
    mask_luminance: FloatProperty(
        name="Ink Cutoff",
        description="Pixels darker than this count as ink",
        default=0.88,
        min=0.4,
        max=0.98,
    )
    threshold: FloatProperty(
        name="Meta Threshold",
        description="Metaball threshold (lower = fatter fusion)",
        default=1.5,
        min=0.2,
        max=5.0,
        update=_metagrid_update,
    )
    stiffness: FloatProperty(
        name="Stiffness",
        description="Meta stiffness",
        default=2.0,
        min=0.5,
        max=5.0,
        update=_metagrid_update,
    )
    resolution: FloatProperty(
        name="Resolution",
        description="Metaball viewport resolution",
        default=0.13,
        min=0.04,
        max=0.5,
        update=_metagrid_update,
    )
    r_tip: FloatProperty(
        name="Tip Radius",
        description="Minimum radius for thin stroke tips (Trace mode)",
        default=0.05,
        min=0.01,
        max=0.5,
    )
    r_trunk: FloatProperty(
        name="Trunk Radius",
        description="Maximum radius for thick strokes (Trace mode)",
        default=0.85,
        min=0.02,
        max=2.0,
    )
    depth_local: FloatProperty(
        name="Depth",
        description="Local Z on the image plane",
        default=0.0,
        min=-2.0,
        max=2.0,
        update=_metagrid_update,
    )
    mask_step: IntProperty(
        name="Mask Step",
        description="Pixel downsample for Trace scanning",
        default=2,
        min=1,
        max=8,
    )
    min_blob_px: IntProperty(
        name="Min Speckle",
        description="Drop mask islands smaller than this",
        default=40,
        min=1,
        max=2000,
    )
    keep_components: IntProperty(
        name="Keep Islands",
        description="Keep largest N connected ink islands",
        default=1,
        min=1,
        max=20,
    )
    auto_open_preview: BoolProperty(
        name="Auto-Open Preview",
        description="Open Trace preview PNG after Scan+Build",
        default=True,
    )

    # --- MetaGrid mode ---
    grid_source_empty: StringProperty(
        name="Source Empty",
        description="Image Empty used for MetaGrid (set when you select one)",
        default="",
    )
    grid_count_x: IntProperty(
        name="Elements Wide",
        description="Number of meta elements across the image",
        default=12,
        min=1,
        max=64,
        update=_grid_count_update,
    )
    grid_count_y: IntProperty(
        name="Elements Tall",
        description="Number of meta elements up the image",
        default=12,
        min=1,
        max=64,
        update=_grid_count_update,
    )
    grid_density_x: FloatProperty(
        name="Density X",
        description="Packing along width. 1=even full span, higher=tighter toward center (min 1 — lower values caused striping)",
        default=1.0,
        min=1.0,
        max=4.0,
        soft_min=1.0,
        soft_max=2.5,
        step=5,
        update=_metagrid_update,
    )
    grid_density_y: FloatProperty(
        name="Density Y",
        description="Packing along height. 1=even full span, higher=tighter toward center (min 1 — lower values caused striping)",
        default=1.0,
        min=1.0,
        max=4.0,
        soft_min=1.0,
        soft_max=2.5,
        step=5,
        update=_metagrid_update,
    )
    grid_n_ball: IntProperty(
        name="Balls",
        description="How many BALL elements in the grid (filled first). Pad/truncate to Wide×Tall",
        default=144,
        min=0,
        max=4096,
        update=_metagrid_update,
    )
    grid_n_ellipsoid: IntProperty(
        name="Ellipsoids",
        description="How many ELLIPSOID elements (after balls)",
        default=0,
        min=0,
        max=4096,
        update=_metagrid_update,
    )
    grid_n_capsule: IntProperty(
        name="Capsules",
        description="How many CAPSULE elements (after ellipsoids)",
        default=0,
        min=0,
        max=4096,
        update=_metagrid_update,
    )
    grid_element_size: FloatProperty(
        name="Element Size",
        description="Collective size. 1.0 ≈ neighbors just touch; raise to fuse into a solid",
        default=1.15,
        min=0.05,
        max=4.0,
        soft_min=0.3,
        soft_max=2.5,
        step=5,
        update=_metagrid_update,
    )
    grid_cull_white: BoolProperty(
        name="Cull White",
        description="Hide/drop elements whose image pixel is near-white (live while sculpting)",
        default=False,
        update=_metagrid_update,
    )
    grid_white_cutoff: FloatProperty(
        name="White Cutoff",
        description="Luminance ≥ this counts as background white",
        default=0.92,
        min=0.5,
        max=0.995,
        update=_metagrid_update,
    )
    grid_show_rings: BoolProperty(
        name="Show Size Rings",
        description="Keep Meta in Edit Mode so influence rings update as you sculpt",
        default=True,
        update=_metagrid_update,
    )


CLASSES = (MetaTracerSettings,)


def register():
    for cls in CLASSES:
        bpy.utils.register_class(cls)
    Scene.meta_tracer = PointerProperty(type=MetaTracerSettings)


def unregister():
    del Scene.meta_tracer
    for cls in reversed(CLASSES):
        bpy.utils.unregister_class(cls)
