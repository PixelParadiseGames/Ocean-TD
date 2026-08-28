"""
Metaball tracer for Blender image empties (flat shape drawings).

Modes:
  "capsules" — oriented CAPSULE limbs along skeleton (thin connected lines, default)
  "lines"    — BALL chain along skeleton
  "fill"     — dense BALL grid inside silhouette (solid blob)

Usage:
    import trace_shape_metaballs as tsm
    tsm.trace_image_empty("FireCoral", "FireCoral_Meta")
    tsm.trace_image_empty("FireCoral", "FireCoral_Meta", mode="capsules")
    tsm.trace_image_empty("MyArt", "MyArt_Meta", mode="lines", step_factor=0.50)

Tune:
  step_factor  — lower = denser nodes / shorter capsules
  ball_radius — limb thickness (None = keep current element average)
"""

from __future__ import annotations

import bpy
from mathutils import Vector, Quaternion

LINE_STEP_FACTOR = 0.55
FILL_STEP_FACTOR = 0.40
# Capsule taper: trunk vs tip radius (photo thickness drives blend).
R_TRUNK = 0.18
R_TIP = 0.05


def sample_is_shape(r: float, g: float, b: float) -> bool:
    lum = (r + g + b) / 3.0
    if lum > 0.90:
        return False
    if r > 0.22 and r >= g * 0.95 and r > b * 0.8:
        return True
    if lum < 0.58 and r >= g:
        return True
    return False


def plane_size_from_empty(empty) -> tuple[float, float]:
    img = empty.data
    w, h = int(img.size[0]), int(img.size[1])
    aspect = w / float(h)
    size = float(empty.empty_display_size)
    if aspect >= 1.0:
        return size, size / aspect
    return size * aspect, size


def _build_mask(img, sample_fn, mask_step: int):
    w, h = int(img.size[0]), int(img.size[1])
    pixels = list(img.pixels)
    mw, mh = max(1, w // mask_step), max(1, h // mask_step)

    def sample(ix: int, iy: int):
        ix = max(0, min(w - 1, ix))
        iy = max(0, min(h - 1, iy))
        i = (iy * w + ix) * 4
        return pixels[i], pixels[i + 1], pixels[i + 2]

    mask = [
        [
            sample_fn(*sample(x * mask_step + mask_step // 2, y * mask_step + mask_step // 2))
            for x in range(mw)
        ]
        for y in range(mh)
    ]
    return mask, mw, mh, w, h, pixels


def _distance_transform(mask, mw, mh):
    big = 1e6
    dist = [[0.0] * mw for _ in range(mh)]
    for y in range(mh):
        for x in range(mw):
            dist[y][x] = 0.0 if not mask[y][x] else big
    for y in range(mh):
        for x in range(mw):
            if dist[y][x] == 0:
                continue
            if x > 0:
                dist[y][x] = min(dist[y][x], dist[y][x - 1] + 1)
            if y > 0:
                dist[y][x] = min(dist[y][x], dist[y - 1][x] + 1)
    for y in range(mh - 1, -1, -1):
        for x in range(mw - 1, -1, -1):
            if dist[y][x] == 0:
                continue
            if x + 1 < mw:
                dist[y][x] = min(dist[y][x], dist[y][x + 1] + 1)
            if y + 1 < mh:
                dist[y][x] = min(dist[y][x], dist[y + 1][x] + 1)
    return dist


def _skeleton_points(mask, dist, mw, mh):
    points = []
    for y in range(mh):
        for x in range(mw):
            if not mask[y][x]:
                continue
            d = dist[y][x]
            if d < 0.8:
                continue
            is_ridge = True
            for dy in (-1, 0, 1):
                for dx in (-1, 0, 1):
                    if dx == 0 and dy == 0:
                        continue
                    xx, yy = x + dx, y + dy
                    if 0 <= xx < mw and 0 <= yy < mh and mask[yy][xx]:
                        if dist[yy][xx] > d + 0.05:
                            is_ridge = False
            if is_ridge:
                points.append((d, x, y))

    for y in range(mh):
        for x in range(mw):
            if not mask[y][x]:
                continue
            n = sum(
                1
                for dy in (-1, 0, 1)
                for dx in (-1, 0, 1)
                if not (dx == 0 and dy == 0)
                and 0 <= x + dx < mw
                and 0 <= y + dy < mh
                and mask[y + dy][x + dx]
            )
            if n <= 4:
                points.append((dist[y][x] * 0.4, x, y))

    seen = set()
    unique = []
    for score, x, y in sorted(points, reverse=True):
        if (x, y) in seen:
            continue
        seen.add((x, y))
        unique.append((score, x, y))
    return unique


def _cell_world(empty, plane_w, plane_h, mw, mh, cx, cy, depth_local):
    u = (cx + 0.5) / mw
    v = (cy + 0.5) / mh
    local = Vector(((u - 0.5) * plane_w, (v - 0.5) * plane_h, depth_local))
    return empty.matrix_world @ local


def _orient_capsule_along(direction: Vector) -> Quaternion:
    d = Vector(direction)
    if d.length < 1e-6:
        return Quaternion()
    return d.normalized().to_track_quat("X", "Z")


def _poisson_nodes(skeleton, empty, plane_w, plane_h, mw, mh, depth_local, min_sep):
    nodes = []
    for score, x, y in sorted(skeleton, reverse=True):
        pos = _cell_world(empty, plane_w, plane_h, mw, mh, x, y, depth_local)
        if all((pos - p).length >= min_sep for _, _, p in nodes):
            nodes.append((x, y, pos))
    return nodes


def _mst_edges(nodes, mw, mid_x, link_dist):
    adj = {i: [] for i in range(len(nodes))}
    for i in range(len(nodes)):
        for j in range(i + 1, len(nodes)):
            d = (nodes[i][2] - nodes[j][2]).length
            if d <= link_dist:
                adj[i].append((j, d))
                adj[j].append((i, d))

    base_y = min(n[1] for n in nodes)
    seed = min(range(len(nodes)), key=lambda i: (nodes[i][1] - base_y) ** 2 + (nodes[i][0] - mid_x) ** 2 * 0.3)

    in_tree = {seed}
    edges = []
    candidates = [(d, seed, j) for j, d in adj[seed]]

    while candidates and len(in_tree) < len(nodes):
        candidates.sort()
        found = False
        while candidates:
            d, a, b = candidates.pop(0)
            if b in in_tree or a not in in_tree:
                continue
            edges.append((a, b, d))
            in_tree.add(b)
            for k, dk in adj[b]:
                if k not in in_tree:
                    candidates.append((dk, b, k))
            found = True
            break
        if not found:
            break
    return edges, in_tree


def _trace_capsules(empty, plane_w, plane_h, mask, dist, mw, mh, ball_radius, depth_local, step_factor):
    """Oriented capsules along skeleton with tip→trunk radius taper."""
    factor = step_factor if step_factor is not None else LINE_STEP_FACTOR
    skeleton = _skeleton_points(mask, dist, mw, mh)
    max_thick = max((dist[y][x] for y in range(mh) for x in range(mw) if mask[y][x]), default=1.0)

    def radius_from_thick(thick: float) -> float:
        t = min(1.0, max(0.0, (thick - 0.8) / max(1.0, max_thick * 0.4)))
        t = t * t
        return R_TIP + (R_TRUNK - R_TIP) * t

    # Nodes: (x, y, world, radius) — denser spacing on thin tips
    nodes = []
    for score, x, y in sorted(skeleton, reverse=True):
        thick = dist[y][x]
        radius = radius_from_thick(thick)
        min_sep = radius * (1.35 if radius < 0.09 else 1.6) * factor / LINE_STEP_FACTOR
        pos = _cell_world(empty, plane_w, plane_h, mw, mh, x, y, depth_local)
        if all((pos - p).length >= min(min_sep, r * 1.2) for _, _, p, r in nodes):
            nodes.append((x, y, pos, radius))

    if not nodes:
        return [], R_TIP

    # Graph with radius-aware link distance
    adj = {i: [] for i in range(len(nodes))}
    for i in range(len(nodes)):
        for j in range(i + 1, len(nodes)):
            d = (nodes[i][2] - nodes[j][2]).length
            if d <= (nodes[i][3] + nodes[j][3]) * 3.2:
                adj[i].append((j, d))
                adj[j].append((i, d))

    mid_x = mw // 2
    base_y = min(n[1] for n in nodes)
    seed = min(range(len(nodes)), key=lambda i: (nodes[i][1] - base_y) ** 2 + (nodes[i][0] - mid_x) ** 2 * 0.3)
    in_tree = {seed}
    edges = []
    candidates = [(d, seed, j) for j, d in adj[seed]]
    while candidates and len(in_tree) < len(nodes):
        candidates.sort()
        found = False
        while candidates:
            d, a, b = candidates.pop(0)
            if b in in_tree or a not in in_tree:
                continue
            edges.append((a, b, d))
            in_tree.add(b)
            for k, dk in adj[b]:
                if k not in in_tree:
                    candidates.append((dk, b, k))
            found = True
            break
        if not found:
            break

    specs = []
    for a, b, _ in edges:
        pa, pb = nodes[a][2], nodes[b][2]
        ra, rb = nodes[a][3], nodes[b][3]
        direction = pb - pa
        length = direction.length
        if length < 1e-4:
            continue
        specs.append(
            (
                "CAPSULE",
                (pa + pb) * 0.5,
                min(ra, rb),  # tip-end thickness wins
                max(0.04, length * 0.5),
                _orient_capsule_along(direction),
            )
        )

    degree = {i: 0 for i in range(len(nodes))}
    for a, b, _ in edges:
        degree[a] += 1
        degree[b] += 1
    # Tip balls only (no fat junction balls)
    for i, deg in degree.items():
        if i in in_tree and deg == 1:
            specs.append(("BALL", nodes[i][2], nodes[i][3] * 0.7, 1.0, Quaternion()))

    return specs, R_TIP


def _trace_lines(empty, plane_w, plane_h, mask, dist, mw, mh, ball_radius, threshold, depth_local, step_factor):
    factor = step_factor if step_factor is not None else LINE_STEP_FACTOR
    min_sep = ball_radius * factor / max(threshold * 0.38, 0.55)
    skeleton = _skeleton_points(mask, dist, mw, mh)
    selected = []
    for score, x, y in sorted(skeleton, reverse=True):
        pos = _cell_world(empty, plane_w, plane_h, mw, mh, x, y, depth_local)
        if all((pos - p).length >= min_sep for p in selected):
            selected.append(pos)

    max_gap = min_sep * 1.75
    bridged = list(selected)
    for i, a in enumerate(list(bridged)):
        for j in range(i + 1, min(i + 8, len(bridged))):
            b = bridged[j]
            gap = (a - b).length
            if min_sep < gap <= max_gap:
                mid = a.lerp(b, 0.5)
                if all((mid - p).length >= min_sep * 0.85 for p in bridged):
                    bridged.append(mid)

    specs = [("BALL", p, ball_radius, 1.0, Quaternion()) for p in bridged]
    return specs, min_sep


def _trace_fill(empty, plane_w, plane_h, w, h, pixels, ball_radius, depth_local, step_factor, sample_fn):
    factor = step_factor if step_factor is not None else FILL_STEP_FACTOR
    grid_step = ball_radius * factor

    def sample_px(px: float, py: float):
        px = max(0, min(w - 1, int(px)))
        py = max(0, min(h - 1, int(py)))
        i = (py * w + px) * 4
        return pixels[i], pixels[i + 1], pixels[i + 2]

    def local_hits_shape(lx: float, ly: float) -> bool:
        half = grid_step * 0.4
        for ox, oy in ((0, 0), (half, 0), (-half, 0), (0, half), (0, -half)):
            u = (lx + ox) / plane_w + 0.5
            v = (ly + oy) / plane_h + 0.5
            if u < 0 or u > 1 or v < 0 or v > 1:
                continue
            if sample_fn(*sample_px(u * (w - 1), v * (h - 1))):
                return True
        return False

    nx = max(1, int(plane_w / grid_step) + 1)
    ny = max(1, int(plane_h / grid_step) + 1)
    occupied = {}
    for iy in range(ny):
        ly = -plane_h * 0.5 + iy * grid_step
        for ix in range(nx):
            lx = -plane_w * 0.5 + ix * grid_step
            if local_hits_shape(lx, ly):
                occupied[(ix, iy)] = Vector((lx, ly, depth_local))

    mid_ix = nx // 2
    seed = min(occupied.keys(), key=lambda k: (k[1], abs(k[0] - mid_ix)))
    connected = set()
    stack = [seed]
    while stack:
        c = stack.pop()
        if c in connected or c not in occupied:
            continue
        connected.add(c)
        ix, iy = c
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                if dx == 0 and dy == 0:
                    continue
                n = (ix + dx, iy + dy)
                if n in occupied and n not in connected:
                    stack.append(n)

    specs = [("BALL", empty.matrix_world @ occupied[k], ball_radius, 1.0, Quaternion()) for k in sorted(connected)]
    return specs, grid_step


def _apply_specs(mb, specs):
    while len(mb.elements) > 0:
        mb.elements.remove(mb.elements[0])
    for typ, co, radius, size_x, rotation in specs:
        el = mb.elements.new(type=typ)
        el.co = co
        el.radius = radius
        el.stiffness = 2.0
        if typ == "CAPSULE":
            el.size_x = size_x
            el.size_y = 1.0
            el.size_z = 1.0
            el.rotation = rotation


def trace_image_empty(
    empty_name: str = "FireCoral",
    meta_object_name: str = "FireCoral_Meta",
    depth_local: float = 0.0,
    ball_radius: float | None = None,
    step_factor: float | None = None,
    mode: str = "capsules",
    sample_fn=sample_is_shape,
    mask_step: int = 5,
) -> int:
    empty = bpy.data.objects.get(empty_name)
    meta_obj = bpy.data.objects.get(meta_object_name)
    if not empty or empty.type != "EMPTY" or not empty.data:
        raise ValueError(f"Image empty '{empty_name}' not found or has no image")
    if not meta_obj or meta_obj.type != "META":
        raise ValueError(f"Metaball object '{meta_object_name}' not found")

    mb = meta_obj.data
    plane_w, plane_h = plane_size_from_empty(empty)
    mask, mw, mh, w, h, pixels = _build_mask(empty.data, sample_fn, mask_step)
    dist = _distance_transform(mask, mw, mh)

    if ball_radius is None:
        # Prefer thin radii; ignore huge outlier capsules from manual edits
        radii = [e.radius for e in mb.elements if e.radius < 1.0]
        ball_radius = (sum(radii) / len(radii)) if radii else 0.34

    if mode == "fill":
        specs, spacing = _trace_fill(
            empty, plane_w, plane_h, w, h, pixels, ball_radius, depth_local, step_factor, sample_fn
        )
    elif mode == "lines":
        specs, spacing = _trace_lines(
            empty, plane_w, plane_h, mask, dist, mw, mh, ball_radius, mb.threshold, depth_local, step_factor
        )
    else:
        specs, spacing = _trace_capsules(
            empty, plane_w, plane_h, mask, dist, mw, mh, ball_radius, depth_local, step_factor
        )

    if not specs:
        raise RuntimeError(f"No trace points for '{empty_name}'")

    _apply_specs(mb, specs)

    bpy.context.view_layer.update()
    if bpy.context.mode != "OBJECT":
        bpy.ops.object.mode_set(mode="OBJECT")
    for o in bpy.context.view_layer.objects:
        o.select_set(False)
    meta_obj.hide_set(False)
    meta_obj.select_set(True)
    bpy.context.view_layer.objects.active = meta_obj

    n_cap = sum(1 for s in specs if s[0] == "CAPSULE")
    n_ball = sum(1 for s in specs if s[0] == "BALL")
    print(
        f"[trace_shape_metaballs] {empty_name} mode={mode} → "
        f"{n_cap} capsules + {n_ball} balls "
        f"(spacing≈{spacing:.3f}, radius={ball_radius:.3f}, threshold={mb.threshold:.3f})"
    )
    return len(mb.elements)


if __name__ == "__main__":
    trace_image_empty(mode="capsules")
