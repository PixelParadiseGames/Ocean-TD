"""
Scanner: Image Empty → Traces/<name>_trace.json + preview PNG.

Does NOT place metaballs. Run build_metaballs after inspecting the preview.
"""

from __future__ import annotations

import math
from typing import Callable

import bpy

from shape_trace_io import (
    DEFAULTS,
    empty_trace,
    preview_png_path,
    write_trace,
)


SampleFn = Callable[[float, float, float], bool]


def sample_is_shape(r: float, g: float, b: float) -> bool:
    """Filled silhouette: non-white reddish / dark (legacy Fire Coral style)."""
    lum = (r + g + b) / 3.0
    if lum > 0.90:
        return False
    if r > 0.22 and r >= g * 0.95 and r > b * 0.8:
        return True
    if lum < 0.58 and r >= g:
        return True
    return False


def sample_is_line_art(r: float, g: float, b: float, lum_cutoff: float = 0.88) -> bool:
    """Simple line art on light background: any pixel darker than cutoff is stroke."""
    lum = (r + g + b) / 3.0
    return lum < lum_cutoff


def fusion_span(ra: float, rb: float, threshold: float, stiffness: float = 2.0) -> float:
    """Max center distance for two meta elements to fuse."""
    avg_r = 0.5 * (ra + rb)
    # Higher threshold → shorter span; floor keeps tip chains from exploding midpoints
    span = avg_r * (2.0 * stiffness / max(threshold, 0.2)) * 0.72
    return max(span, avg_r * 1.05)


def plane_size_from_empty(empty) -> tuple[float, float]:
    img = empty.data
    w, h = int(img.size[0]), int(img.size[1])
    aspect = w / float(h)
    size = float(empty.empty_display_size)
    if aspect >= 1.0:
        return size, size / aspect
    return size * aspect, size


def _read_pixels(img) -> tuple[int, int, list[float]]:
    w, h = int(img.size[0]), int(img.size[1])
    return w, h, list(img.pixels)


def _build_mask(
    pixels: list[float],
    w: int,
    h: int,
    sample_fn: SampleFn,
    mask_step: int,
) -> tuple[list[list[bool]], int, int]:
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
    return mask, mw, mh


def _label_components(mask: list[list[bool]], mw: int, mh: int) -> tuple[list[list[int]], dict[int, int]]:
    labels = [[0] * mw for _ in range(mh)]
    sizes: dict[int, int] = {}
    cur = 0
    for y in range(mh):
        for x in range(mw):
            if not mask[y][x] or labels[y][x]:
                continue
            cur += 1
            stack = [(x, y)]
            labels[y][x] = cur
            count = 0
            while stack:
                cx, cy = stack.pop()
                count += 1
                for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    nx, ny = cx + dx, cy + dy
                    if 0 <= nx < mw and 0 <= ny < mh and mask[ny][nx] and labels[ny][nx] == 0:
                        labels[ny][nx] = cur
                        stack.append((nx, ny))
            sizes[cur] = count
    return labels, sizes


def _cleanup_mask(
    mask: list[list[bool]],
    mw: int,
    mh: int,
    min_blob_px: int,
    keep_components: int,
) -> list[list[bool]]:
    labels, sizes = _label_components(mask, mw, mh)
    if not sizes:
        return mask
    ranked = sorted(sizes.items(), key=lambda kv: kv[1], reverse=True)
    keep_ids = set()
    for lid, sz in ranked:
        if sz < min_blob_px:
            continue
        keep_ids.add(lid)
        if len(keep_ids) >= keep_components:
            break
    if not keep_ids and ranked:
        keep_ids.add(ranked[0][0])
    out = [[False] * mw for _ in range(mh)]
    for y in range(mh):
        for x in range(mw):
            if labels[y][x] in keep_ids:
                out[y][x] = True
    return out


def _fill_mask_holes(mask: list[list[bool]], mw: int, mh: int, max_hole_px: int = 12) -> list[list[bool]]:
    """
    Fill only tiny enclosed speckles inside the stroke.

    Large enclosed gaps (coral loops / between fingers) must stay open — filling
    them forces Zhang–Suen into ring skeletons that hug thick-limb edges.
    """
    from collections import deque

    outside = [[False] * mw for _ in range(mh)]
    q: deque[tuple[int, int]] = deque()
    for x in range(mw):
        for y in (0, mh - 1):
            if not mask[y][x] and not outside[y][x]:
                outside[y][x] = True
                q.append((x, y))
    for y in range(mh):
        for x in (0, mw - 1):
            if not mask[y][x] and not outside[y][x]:
                outside[y][x] = True
                q.append((x, y))
    while q:
        x, y = q.popleft()
        for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            xx, yy = x + dx, y + dy
            if 0 <= xx < mw and 0 <= yy < mh and not mask[yy][xx] and not outside[yy][xx]:
                outside[yy][xx] = True
                q.append((xx, yy))

    visited = [[False] * mw for _ in range(mh)]
    out = [row[:] for row in mask]
    for y in range(mh):
        for x in range(mw):
            if mask[y][x] or outside[y][x] or visited[y][x]:
                continue
            stack = [(x, y)]
            visited[y][x] = True
            cells = [(x, y)]
            while stack:
                cx, cy = stack.pop()
                for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    xx, yy = cx + dx, cy + dy
                    if 0 <= xx < mw and 0 <= yy < mh and not mask[yy][xx] and not outside[yy][xx] and not visited[yy][xx]:
                        visited[yy][xx] = True
                        stack.append((xx, yy))
                        cells.append((xx, yy))
            if len(cells) <= max_hole_px:
                for hx, hy in cells:
                    out[hy][hx] = True
    return out


def _distance_transform(mask: list[list[bool]], mw: int, mh: int) -> list[list[float]]:
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
            if x > 0 and y > 0:
                dist[y][x] = min(dist[y][x], dist[y - 1][x - 1] + 1.414)
            if x + 1 < mw and y > 0:
                dist[y][x] = min(dist[y][x], dist[y - 1][x + 1] + 1.414)
    for y in range(mh - 1, -1, -1):
        for x in range(mw - 1, -1, -1):
            if dist[y][x] == 0:
                continue
            if x + 1 < mw:
                dist[y][x] = min(dist[y][x], dist[y][x + 1] + 1)
            if y + 1 < mh:
                dist[y][x] = min(dist[y][x], dist[y + 1][x] + 1)
            if x + 1 < mw and y + 1 < mh:
                dist[y][x] = min(dist[y][x], dist[y + 1][x + 1] + 1.414)
            if x > 0 and y + 1 < mh:
                dist[y][x] = min(dist[y][x], dist[y + 1][x - 1] + 1.414)
    return dist


def _zhang_suen_thin(mask: list[list[bool]], mw: int, mh: int) -> list[list[bool]]:
    """1-pixel-wide centerline through thick strokes (not outline)."""
    img = [[1 if mask[y][x] else 0 for x in range(mw)] for y in range(mh)]

    def neighbors(x: int, y: int):
        # P2..P9 clockwise from north
        pts = [
            (x, y - 1),
            (x + 1, y - 1),
            (x + 1, y),
            (x + 1, y + 1),
            (x, y + 1),
            (x - 1, y + 1),
            (x - 1, y),
            (x - 1, y - 1),
        ]
        vals = []
        for nx, ny in pts:
            if 0 <= nx < mw and 0 <= ny < mh:
                vals.append(img[ny][nx])
            else:
                vals.append(0)
        return vals

    def transitions(vals):
        seq = vals + [vals[0]]
        return sum(1 for i in range(8) if seq[i] == 0 and seq[i + 1] == 1)

    changed = True
    guard = 0
    while changed and guard < 200:
        guard += 1
        changed = False
        for step in (0, 1):
            to_remove: list[tuple[int, int]] = []
            for y in range(1, mh - 1):
                for x in range(1, mw - 1):
                    if img[y][x] != 1:
                        continue
                    p = neighbors(x, y)
                    b = sum(p)
                    if b < 2 or b > 6:
                        continue
                    if transitions(p) != 1:
                        continue
                    if step == 0:
                        if p[0] * p[2] * p[4] != 0:
                            continue
                        if p[2] * p[4] * p[6] != 0:
                            continue
                    else:
                        if p[0] * p[2] * p[6] != 0:
                            continue
                        if p[0] * p[4] * p[6] != 0:
                            continue
                    to_remove.append((x, y))
            if to_remove:
                changed = True
                for x, y in to_remove:
                    img[y][x] = 0

    return [[img[y][x] == 1 for x in range(mw)] for y in range(mh)]


def _prune_skeleton_spurs(skel: list[list[bool]], mw: int, mh: int, max_spur: int = 6) -> list[list[bool]]:
    """Remove short dead-end branches that cause zigzags."""
    out = [row[:] for row in skel]

    def degree(x: int, y: int) -> int:
        n = 0
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                if dx == 0 and dy == 0:
                    continue
                xx, yy = x + dx, y + dy
                if 0 <= xx < mw and 0 <= yy < mh and out[yy][xx]:
                    n += 1
        return n

    changed = True
    while changed:
        changed = False
        tips = [(x, y) for y in range(mh) for x in range(mw) if out[y][x] and degree(x, y) == 1]
        for sx, sy in tips:
            path = [(sx, sy)]
            cx, cy = sx, sy
            prev = None
            for _ in range(max_spur + 1):
                nxt = None
                for dy in (-1, 0, 1):
                    for dx in (-1, 0, 1):
                        if dx == 0 and dy == 0:
                            continue
                        xx, yy = cx + dx, cy + dy
                        if 0 <= xx < mw and 0 <= yy < mh and out[yy][xx] and (xx, yy) != prev:
                            nxt = (xx, yy)
                            break
                    if nxt:
                        break
                if not nxt:
                    break
                d = degree(*nxt)
                path.append(nxt)
                if d != 2:
                    break
                prev, cx, cy = (cx, cy), nxt[0], nxt[1]
            if len(path) <= max_spur and path:
                end = path[-1]
                if degree(*end) != 1 or len(path) > 1:
                    # Only prune if ended at junction or short tip
                    if degree(*end) >= 3 or (degree(*end) == 1 and len(path) <= max_spur):
                        for px, py in path[:-1] if degree(*end) >= 3 else path:
                            if out[py][px]:
                                out[py][px] = False
                                changed = True
    return out


def _prune_parallel_edge_tracks(
    skel: list[list[bool]],
    dist: list[list[float]],
    mw: int,
    mh: int,
    frac: float = 0.48,
    win: int | None = None,
    min_local: float = 10.0,
) -> list[list[bool]]:
    """
    Drop skeleton pixels that sit clearly on the *side* of a thick limb.

    Only removes pixels that are both a large absolute drop from the local
    distance peak and below `frac` of that peak — keeps the real centerline
    and thin tips intact.
    """
    max_d = max((dist[y][x] for y in range(mh) for x in range(mw)), default=1.0)
    radius = win if win is not None else max(40, int(max_d * 0.9))
    out = [row[:] for row in skel]
    for y in range(mh):
        for x in range(mw):
            if not out[y][x]:
                continue
            local_max = 0.0
            y0, y1 = max(0, y - radius), min(mh, y + radius + 1)
            x0, x1 = max(0, x - radius), min(mw, x + radius + 1)
            for yy in range(y0, y1):
                row = dist[yy]
                for xx in range(x0, x1):
                    if row[xx] > local_max:
                        local_max = row[xx]
            d = dist[y][x]
            # Must be clearly a side-track: far below peak in both relative and absolute terms
            if local_max >= min_local and d < frac * local_max and (local_max - d) >= 12.0:
                out[y][x] = False
    return out


def _skeleton_points(
    mask: list[list[bool]],
    dist: list[list[float]],
    mw: int,
    mh: int,
) -> list[tuple[float, int, int]]:
    """
    1-pixel centerline through strokes (Zhang–Suen only).
    Do NOT add distance-plateau maxima — those create parallel edge tracks in thick areas.
    """
    thin = _zhang_suen_thin(mask, mw, mh)
    thin = _prune_skeleton_spurs(thin, mw, mh, max_spur=12)
    thin = _prune_parallel_edge_tracks(thin, dist, mw, mh)
    thin = _prune_skeleton_spurs(thin, mw, mh, max_spur=16)

    points: list[tuple[float, int, int]] = []
    for y in range(mh):
        for x in range(mw):
            if not thin[y][x]:
                continue
            # Thickness from distance field at the centerline pixel
            d = dist[y][x] if mask[y][x] else 0.5
            points.append((max(d, 0.5), x, y))

    if not points:
        # Fallback: morphological peaks only if thinning emptied (rare)
        for y in range(1, mh - 1):
            for x in range(1, mw - 1):
                if not mask[y][x]:
                    continue
                d = dist[y][x]
                if d < 1.0:
                    continue
                if all(d + 1e-6 >= dist[y + dy][x + dx] for dy in (-1, 0, 1) for dx in (-1, 0, 1)):
                    points.append((d, x, y))

    return points


def _smooth_chain_uv(
    work_nodes: list[tuple[int, int, float, float, float]],
    chain: list[int],
    passes: int = 3,
) -> None:
    """Laplacian UV smooth on a node index chain (keeps endpoints). Mutates work_nodes u,v."""
    if len(chain) < 3:
        return
    for _ in range(passes):
        new_uv = []
        for i, idx in enumerate(chain):
            if i == 0 or i == len(chain) - 1:
                new_uv.append((work_nodes[idx][2], work_nodes[idx][3]))
                continue
            prev = work_nodes[chain[i - 1]]
            cur = work_nodes[idx]
            nxt = work_nodes[chain[i + 1]]
            u = 0.25 * prev[2] + 0.5 * cur[2] + 0.25 * nxt[2]
            v = 0.25 * prev[3] + 0.5 * cur[3] + 0.25 * nxt[3]
            new_uv.append((u, v))
        for i, idx in enumerate(chain):
            x, y, _, _, r = work_nodes[idx]
            u, v = new_uv[i]
            work_nodes[idx] = (x, y, u, v, r)


def _snap_uv_to_ridge(
    u: float,
    v: float,
    dist: list[list[float]],
    mask: list[list[bool]],
    mw: int,
    mh: int,
    search: int = 2,
) -> tuple[float, float]:
    """Nudge UV toward thicker nearby pixels without jumping into adjacent limbs."""
    x0 = int(max(0, min(mw - 1, int(u * mw))))
    y0 = int(max(0, min(mh - 1, int(v * mh))))
    best_score = -1e9
    best_x, best_y = x0, y0
    for dy in range(-search, search + 1):
        for dx in range(-search, search + 1):
            x, y = x0 + dx, y0 + dy
            if 0 <= x < mw and 0 <= y < mh and mask[y][x]:
                # Prefer thicker, but penalize large jumps (keeps tips from diving into trunks)
                score = dist[y][x] - 0.55 * math.hypot(dx, dy)
                if score > best_score:
                    best_score = score
                    best_x, best_y = x, y
    return _cell_to_uv(best_x, best_y, mw, mh)


def _radius_from_thick(
    thick: float,
    max_thick: float,
    r_tip: float,
    r_trunk: float,
    cell_world: float,
) -> float:
    # Half-width of the stroke in empty-local units — slight oversize so fused tube fills solid
    half_width = max(thick, 0.5) * cell_world * 1.08
    return max(r_tip, min(r_trunk, half_width))


def _mst_edges(
    n_nodes: int,
    edges: list[tuple[int, int, float]],
) -> list[tuple[int, int, float]]:
    """Kruskal MST — drops skeleton loops that look like edge rings around holes."""
    parent = list(range(n_nodes))
    rank = [0] * n_nodes

    def find(i: int) -> int:
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    def union(a: int, b: int) -> bool:
        ra, rb = find(a), find(b)
        if ra == rb:
            return False
        if rank[ra] < rank[rb]:
            parent[ra] = rb
        elif rank[ra] > rank[rb]:
            parent[rb] = ra
        else:
            parent[rb] = ra
            rank[ra] += 1
        return True

    kept: list[tuple[int, int, float]] = []
    for a, b, length in sorted(edges, key=lambda e: e[2]):
        if union(a, b):
            kept.append((a, b, length))
    return kept


def _rdp_simplify_samples(
    samples: list[tuple],
    epsilon: float,
) -> list[tuple]:
    """Simplify UV polyline (indices 2,3 = u,v). Keeps endpoints."""
    if len(samples) < 3:
        return samples

    def perp_dist(p, a, b) -> float:
        ax, ay = a[2], a[3]
        bx, by = b[2], b[3]
        px, py = p[2], p[3]
        dx, dy = bx - ax, by - ay
        denom = dx * dx + dy * dy
        if denom < 1e-16:
            return math.hypot(px - ax, py - ay)
        t = max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / denom))
        qx, qy = ax + t * dx, ay + t * dy
        return math.hypot(px - qx, py - qy)

    def rec(pts: list) -> list:
        if len(pts) < 3:
            return pts
        a, b = pts[0], pts[-1]
        max_d, max_i = -1.0, 0
        for i in range(1, len(pts) - 1):
            d = perp_dist(pts[i], a, b)
            if d > max_d:
                max_d, max_i = d, i
        if max_d > epsilon:
            left = rec(pts[: max_i + 1])
            right = rec(pts[max_i:])
            return left[:-1] + right
        return [a, b]

    return rec(samples)


def _merge_close_nodes(
    work_nodes: list[tuple[int, int, float, float, float]],
    work_edges: list[tuple[int, int, float]],
    plane_w: float,
    plane_h: float,
    depth: float,
    cell_world: float,
) -> tuple[list[tuple[int, int, float, float, float]], list[tuple[int, int, float]]]:
    """
    Collapse only micro-edge duplicates (not transitive chain merges).
    """
    n = len(work_nodes)
    parent = list(range(n))

    def find(i: int) -> int:
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    def union(a: int, b: int) -> None:
        ra, rb = find(a), find(b)
        if ra == rb:
            return
        if work_nodes[ra][4] >= work_nodes[rb][4]:
            parent[rb] = ra
        else:
            parent[ra] = rb

    for a, b, length in work_edges:
        # Only collapse true duplicates / micro-edges — not long bead-chains via transitive merge
        lim = max(cell_world * 3.5, 0.18 * min(work_nodes[a][4], work_nodes[b][4]))
        if length <= lim:
            union(a, b)

    root_of = [find(i) for i in range(n)]
    kept_roots = sorted(set(root_of))
    new_index = {r: k for k, r in enumerate(kept_roots)}
    new_nodes = [work_nodes[r] for r in kept_roots]

    edge_map: dict[tuple[int, int], float] = {}
    for a, b, _ in work_edges:
        na, nb = new_index[root_of[a]], new_index[root_of[b]]
        if na == nb:
            continue
        key = (na, nb) if na < nb else (nb, na)
        lxa, lya, _ = _uv_to_local(new_nodes[na][2], new_nodes[na][3], plane_w, plane_h, depth)
        lxb, lyb, _ = _uv_to_local(new_nodes[nb][2], new_nodes[nb][3], plane_w, plane_h, depth)
        length = math.hypot(lxa - lxb, lya - lyb)
        if key not in edge_map or length < edge_map[key]:
            edge_map[key] = length
    new_edges = [(a, b, length) for (a, b), length in edge_map.items()]
    new_edges = _mst_edges(len(new_nodes), new_edges)
    return new_nodes, new_edges


def _line_clear(
    mask: list[list[bool]],
    mw: int,
    mh: int,
    x0: int,
    y0: int,
    x1: int,
    y1: int,
) -> bool:
    """True if the line segment stays on shape (no background gap / false bridge)."""
    steps = max(abs(x1 - x0), abs(y1 - y0), 1)
    for i in range(steps + 1):
        t = i / steps
        x = int(round(x0 + (x1 - x0) * t))
        y = int(round(y0 + (y1 - y0) * t))
        x = max(0, min(mw - 1, x))
        y = max(0, min(mh - 1, y))
        if not mask[y][x]:
            return False
    return True


def _cell_to_uv(x: int, y: int, mw: int, mh: int) -> tuple[float, float]:
    return (x + 0.5) / mw, (y + 0.5) / mh


def _uv_to_local(u: float, v: float, plane_w: float, plane_h: float, depth: float) -> tuple[float, float, float]:
    return (u - 0.5) * plane_w, (v - 0.5) * plane_h, depth


def _save_preview_png(
    path: str,
    mask: list[list[bool]],
    dist: list[list[float]],
    mw: int,
    mh: int,
    nodes: list[tuple[int, int]],
    edges: list[tuple[int, int]],
    elements: list[dict],
) -> None:
    """RGBA preview via Blender image API (no Pillow)."""
    # Upscale for readability
    scale = max(1, min(4, 800 // max(mw, mh)))
    pw, ph = mw * scale, mh * scale
    pixels = [0.0] * (pw * ph * 4)

    max_d = max((dist[y][x] for y in range(mh) for x in range(mw) if mask[y][x]), default=1.0)

    def set_px(px: int, py: int, r: float, g: float, b: float, a: float = 1.0):
        if 0 <= px < pw and 0 <= py < ph:
            i = (py * pw + px) * 4
            pixels[i : i + 4] = [r, g, b, a]

    for y in range(mh):
        for x in range(mw):
            if mask[y][x]:
                t = dist[y][x] / max_d
                col = (0.15 + 0.55 * t, 0.05, 0.05)
            else:
                col = (0.95, 0.95, 0.95)
            for oy in range(scale):
                for ox in range(scale):
                    set_px(x * scale + ox, y * scale + oy, *col)

    # Skeleton nodes (cyan)
    for x, y in nodes:
        for oy in range(-1, 2):
            for ox in range(-1, 2):
                set_px(x * scale + scale // 2 + ox, y * scale + scale // 2 + oy, 0.1, 0.85, 0.9)

    # Edges (green)
    for ia, ib in edges:
        x0, y0 = nodes[ia]
        x1, y1 = nodes[ib]
        steps = max(abs(x1 - x0), abs(y1 - y0), 1)
        for i in range(steps + 1):
            t = i / steps
            x = int(round(x0 + (x1 - x0) * t))
            y = int(round(y0 + (y1 - y0) * t))
            set_px(x * scale + scale // 2, y * scale + scale // 2, 0.15, 0.75, 0.2)

    # Planned elements — small markers at centers (not radius disks; those look like edge rings)
    for el in elements:
        u, v = float(el["u"]), float(el["v"])
        px = int(u * (pw - 1))
        py = int(v * (ph - 1))
        rad = max(2, scale)
        for oy in range(-rad, rad + 1):
            for ox in range(-rad, rad + 1):
                if ox * ox + oy * oy <= rad * rad:
                    set_px(px + ox, py + oy, 1.0, 0.55, 0.05)

    name = f"_TracePreview_{pw}x{ph}"
    old = bpy.data.images.get(name)
    if old:
        bpy.data.images.remove(old)
    img = bpy.data.images.new(name, width=pw, height=ph, alpha=True)
    img.pixels = pixels
    img.filepath_raw = path
    img.file_format = "PNG"
    img.save()
    print(f"[scan_shape] preview → {path}")


# Filled by scan for preview radius drawing (world units per mask cell, approximate)
_PREVIEW_CELL = 0.05


def plane_hint_cell(mw: int) -> float:
    return _PREVIEW_CELL


def scan(
    empty_name: str = "FireCoral",
    *,
    sample_fn: SampleFn | None = None,
    threshold: float | None = None,
    stiffness: float | None = None,
    resolution: float | None = None,
    r_tip: float | None = None,
    r_trunk: float | None = None,
    depth_local: float | None = None,
    min_blob_px: int | None = None,
    keep_components: int | None = None,
    mask_step: int | None = None,
    line_art: bool | None = None,
    mask_luminance: float | None = None,
    grid_density: float | None = None,
    thickness_mult: float | None = None,
    write_preview: bool = True,
) -> str:
    """
    Scan Image Empty (line art by default) → Traces/<name>_trace.json (+ preview PNG).
    Returns path to JSON.
    """
    empty = bpy.data.objects.get(empty_name)
    if not empty or empty.type != "EMPTY" or not empty.data:
        raise ValueError(f"Image empty '{empty_name}' not found or has no image")

    cfg = dict(DEFAULTS)
    if threshold is not None:
        cfg["threshold"] = threshold
    if stiffness is not None:
        cfg["stiffness"] = stiffness
    if resolution is not None:
        cfg["resolution"] = resolution
    if r_tip is not None:
        cfg["r_tip"] = r_tip
    if r_trunk is not None:
        cfg["r_trunk"] = r_trunk
    if depth_local is not None:
        cfg["depth_local"] = depth_local
    if min_blob_px is not None:
        cfg["min_blob_px"] = min_blob_px
    if keep_components is not None:
        cfg["keep_components"] = keep_components
    if mask_step is not None:
        cfg["mask_step"] = mask_step
    if line_art is not None:
        cfg["line_art"] = bool(line_art)
    if mask_luminance is not None:
        cfg["mask_luminance"] = float(mask_luminance)
    if grid_density is not None:
        cfg["grid_density"] = max(0.25, min(4.0, float(grid_density)))
    if thickness_mult is not None:
        cfg["thickness_mult"] = max(0.1, min(4.0, float(thickness_mult)))

    if sample_fn is None:
        if cfg.get("line_art", True):
            cut = float(cfg["mask_luminance"])

            def sample_fn(r, g, b, _c=cut):
                return sample_is_line_art(r, g, b, _c)
        else:
            sample_fn = sample_is_shape

    plane_w, plane_h = plane_size_from_empty(empty)
    w, h, pixels = _read_pixels(empty.data)
    mask, mw, mh = _build_mask(pixels, w, h, sample_fn, int(cfg["mask_step"]))
    mask = _cleanup_mask(mask, mw, mh, int(cfg["min_blob_px"]), int(cfg["keep_components"]))
    # Only plug tiny speckles — filling large enclosed gaps (common in coral art)
    # creates ring medial-axes that hug thick-limb edges.
    mask = _fill_mask_holes(mask, mw, mh, max_hole_px=12)
    dist = _distance_transform(mask, mw, mh)

    cell_world = 0.5 * (plane_w / mw + plane_h / mh)
    global _PREVIEW_CELL
    _PREVIEW_CELL = cell_world

    density = float(cfg["grid_density"])
    thick_mult = float(cfg["thickness_mult"])
    # Higher density → smaller spacing between nodes
    dens_sep_scale = 1.0 / density

    max_thick = max((dist[y][x] for y in range(mh) for x in range(mw) if mask[y][x]), default=1.0)
    skeleton = _skeleton_points(mask, dist, mw, mh)
    if not skeleton:
        raise RuntimeError(f"No skeleton found on '{empty_name}' — check mask / line-art luminance")

    # Build 8-connected graph on ALL centerline pixels, then resample chains
    skel_pix = [(x, y) for _score, x, y in skeleton]
    skel_set = set(skel_pix)
    skel_adj: dict[tuple[int, int], list[tuple[int, int]]] = {p: [] for p in skel_pix}
    for x, y in skel_pix:
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                if dx == 0 and dy == 0:
                    continue
                n = (x + dx, y + dy)
                if n in skel_set:
                    skel_adj[(x, y)].append(n)

    def skel_degree(p: tuple[int, int]) -> int:
        return len(skel_adj.get(p, []))

    junctions = {p for p in skel_pix if skel_degree(p) != 2}
    tips = {p for p in skel_pix if skel_degree(p) == 1}
    anchors = junctions | tips
    if not anchors and skel_pix:
        anchors = {skel_pix[0]}

    def walk_skel(start: tuple[int, int], nxt: tuple[int, int]) -> list[tuple[int, int]]:
        path = [start, nxt]
        prev, cur = start, nxt
        while skel_degree(cur) == 2:
            opts = [q for q in skel_adj[cur] if q != prev]
            if not opts:
                break
            prev, cur = cur, opts[0]
            path.append(cur)
            if cur in anchors and cur != start:
                break
        return path

    used: set[tuple[tuple[int, int], tuple[int, int]]] = set()
    raw_chains: list[list[tuple[int, int]]] = []
    for a in anchors:
        for b in skel_adj.get(a, []):
            key = (a, b) if a <= b else (b, a)
            # undirected start edge mark via frozenset of first step
            e0 = (min(a, b), max(a, b))
            if e0 in used:
                continue
            chain = walk_skel(a, b)
            for p, q in zip(chain, chain[1:]):
                used.add((min(p, q), max(p, q)))
            if len(chain) >= 2:
                raw_chains.append(chain)

    # Resample each chain into work_nodes / work_edges (share junction pixels)
    work_nodes: list[tuple[int, int, float, float, float]] = []
    work_edges: list[tuple[int, int, float]] = []
    node_at: dict[tuple[int, int], int] = {}
    thresh = float(cfg["threshold"])
    stiff = float(cfg["stiffness"])

    def ensure_node(x: int, y: int, radius: float, u: float, v: float) -> int:
        key = (x, y)
        if key in node_at:
            # Keep larger radius if revisited (thick junction)
            idx = node_at[key]
            ox, oy, ou, ov, orad = work_nodes[idx]
            if radius > orad:
                work_nodes[idx] = (ox, oy, ou, ov, radius)
            return idx
        work_nodes.append((x, y, u, v, radius))
        node_at[key] = len(work_nodes) - 1
        return node_at[key]

    for chain in raw_chains:
        pts = []
        for x, y in chain:
            u, v = _cell_to_uv(x, y, mw, mh)
            lx, ly, _ = _uv_to_local(u, v, plane_w, plane_h, cfg["depth_local"])
            thick = dist[y][x] if mask[y][x] else 0.5
            radius = _radius_from_thick(thick, max_thick, cfg["r_tip"], cfg["r_trunk"], cell_world) * thick_mult
            pts.append((x, y, u, v, lx, ly, radius))

        avg_r = sum(p[6] for p in pts) / len(pts)
        # Wider spacing on thick limbs → fewer zigzags; tips stay denser via smaller avg_r
        step = max(fusion_span(avg_r, avg_r, thresh, stiff) * 1.15, avg_r * 1.8) * dens_sep_scale
        step = max(step, cell_world * 4.5)

        samples = [pts[0]]
        acc = 0.0
        for i in range(1, len(pts)):
            dseg = math.hypot(pts[i][4] - pts[i - 1][4], pts[i][5] - pts[i - 1][5])
            acc += dseg
            if acc >= step or i == len(pts) - 1:
                samples.append(pts[i])
                acc = 0.0
        if samples[-1] != pts[-1]:
            samples.append(pts[-1])

        # Ramer–Douglas–Peucker simplify in UV to kill stair-step zigzags
        if len(samples) >= 4:
            samples = _rdp_simplify_samples(samples, epsilon=max(0.012, 8.0 / max(mw, mh)))

        if len(samples) >= 3:
            for _ in range(6):
                sm = [samples[0]]
                for i in range(1, len(samples) - 1):
                    u = 0.25 * samples[i - 1][2] + 0.5 * samples[i][2] + 0.25 * samples[i + 1][2]
                    v = 0.25 * samples[i - 1][3] + 0.5 * samples[i][3] + 0.25 * samples[i + 1][3]
                    u, v = _snap_uv_to_ridge(u, v, dist, mask, mw, mh, search=2)
                    x = int(max(0, min(mw - 1, int(u * mw))))
                    y = int(max(0, min(mh - 1, int(v * mh))))
                    lx, ly, _ = _uv_to_local(u, v, plane_w, plane_h, cfg["depth_local"])
                    thick = dist[y][x] if mask[y][x] else samples[i][6] / max(cell_world, 1e-6)
                    radius = _radius_from_thick(thick, max_thick, cfg["r_tip"], cfg["r_trunk"], cell_world) * thick_mult
                    sm.append((x, y, u, v, lx, ly, radius))
                sm.append(samples[-1])
                samples = sm

        idxs = []
        for x, y, u, v, lx, ly, radius in samples:
            idxs.append(ensure_node(x, y, radius, u, v))
        for a, b in zip(idxs, idxs[1:]):
            if a == b:
                continue
            lxa, lya, _ = _uv_to_local(work_nodes[a][2], work_nodes[a][3], plane_w, plane_h, cfg["depth_local"])
            lxb, lyb, _ = _uv_to_local(work_nodes[b][2], work_nodes[b][3], plane_w, plane_h, cfg["depth_local"])
            work_edges.append((a, b, math.hypot(lxa - lxb, lya - lyb)))

    if not work_nodes or not work_edges:
        raise RuntimeError("No centerline chains found — check line-art mask")

    # Drop loop edges (hole rings / duplicate tracks) so thick trunks stay one spine
    work_edges = _mst_edges(len(work_nodes), work_edges)
    in_tree = set(range(len(work_nodes)))
    edges = list(work_edges)
    nodes = list(work_nodes)

    # Smooth MST chains to kill zigzags on thick limbs
    adj_chain: dict[int, list[int]] = {i: [] for i in range(len(work_nodes))}
    for a, b, _ in work_edges:
        adj_chain[a].append(b)
        adj_chain[b].append(a)
    degree0 = {i: len(adj_chain[i]) for i in adj_chain}
    visited_e: set[tuple[int, int]] = set()

    def walk_chain(start: int, nxt: int) -> list[int]:
        chain = [start, nxt]
        prev, cur = start, nxt
        while degree0.get(cur, 0) == 2:
            opts = [n for n in adj_chain[cur] if n != prev]
            if not opts:
                break
            prev, cur = cur, opts[0]
            chain.append(cur)
        return chain

    for i, nbrs in adj_chain.items():
        if degree0.get(i, 0) == 0:
            continue
        if degree0[i] != 2:
            for n in nbrs:
                ekey = (min(i, n), max(i, n))
                if ekey in visited_e:
                    continue
                chain = walk_chain(i, n)
                for a, b in zip(chain, chain[1:]):
                    visited_e.add((min(a, b), max(a, b)))
                _smooth_chain_uv(work_nodes, chain, passes=8)
                # Re-snap interiors onto distance ridge + refresh radius
                for idx in chain[1:-1]:
                    x, y, u, v, r = work_nodes[idx]
                    u2, v2 = _snap_uv_to_ridge(u, v, dist, mask, mw, mh, search=2)
                    x2 = int(max(0, min(mw - 1, int(u2 * mw))))
                    y2 = int(max(0, min(mh - 1, int(v2 * mh))))
                    thick = dist[y2][x2] if mask[y2][x2] else 0.5
                    r2 = _radius_from_thick(thick, max_thick, cfg["r_tip"], cfg["r_trunk"], cell_world) * thick_mult
                    work_nodes[idx] = (x2, y2, u2, v2, max(r, r2))

    # Deduplicate edges then MST (keep short edges for connectivity)
    cleaned_edges: list[tuple[int, int, float]] = []
    seen_e: set[tuple[int, int]] = set()
    for a, b, length in work_edges:
        if a == b:
            continue
        key = (a, b) if a < b else (b, a)
        if key in seen_e:
            continue
        seen_e.add(key)
        cleaned_edges.append((a, b, length))
    work_edges = _mst_edges(len(work_nodes), cleaned_edges) if cleaned_edges else []

    # Degree for tips / junctions
    degree = {i: 0 for i in range(len(work_nodes))}
    for a, b, _ in work_edges:
        degree[a] += 1
        degree[b] += 1

    elements: list[dict] = []
    for a, b, _ in work_edges:
        ua, va, ra = work_nodes[a][2], work_nodes[a][3], work_nodes[a][4]
        ub, vb, rb = work_nodes[b][2], work_nodes[b][3], work_nodes[b][4]
        lxa, lya, _ = _uv_to_local(ua, va, plane_w, plane_h, cfg["depth_local"])
        lxb, lyb, _ = _uv_to_local(ub, vb, plane_w, plane_h, cfg["depth_local"])
        dx, dy = lxb - lxa, lyb - lya
        length = math.hypot(dx, dy)
        if length < 1e-5:
            continue
        angle = math.atan2(dy, dx)
        u = 0.5 * (ua + ub)
        v = 0.5 * (va + vb)
        radius = 0.5 * (ra + rb)  # use mean so thick centerline fills the stroke width
        # Trunk ellipsoid if short fat segment
        if radius > cfg["r_trunk"] * 0.75 and length < radius * 1.4:
            elements.append(
                {
                    "type": "ELLIPSOID",
                    "u": u,
                    "v": v,
                    "radius": radius,
                    "size_x": max(0.5, length / max(radius, 1e-4) * 0.5),
                    "size_y": 1.0,
                    "size_z": 0.55,
                    "angle": angle,
                }
            )
        else:
            elements.append(
                {
                    "type": "CAPSULE",
                    "u": u,
                    "v": v,
                    "radius": radius,
                    "length": length,
                    "angle": angle,
                    # Keep capsules long enough to read as tubes, not micro-beads
                    "size_x": max(radius * 0.45, length * 0.5),
                }
            )

    # Tip balls only
    for i, deg in degree.items():
        if deg == 1:
            _, _, u, v, radius = work_nodes[i]
            elements.append({"type": "BALL", "u": u, "v": v, "radius": radius * 0.7})

    # Thick-interior fill: primary way to solid-fill fat middles (skeleton alone leaves troughs)
    existing = []
    for e in elements:
        u, v, r = float(e["u"]), float(e["v"]), float(e["radius"])
        lx, ly, _ = _uv_to_local(u, v, plane_w, plane_h, cfg["depth_local"])
        x = int(max(0, min(mw - 1, int(u * mw))))
        y = int(max(0, min(mh - 1, int(v * mh))))
        existing.append((lx, ly, r, dist[y][x] if mask[y][x] else 0.0))

    fill_step = max(2, int(round(4.5 / max(density, 0.25))))
    n_fill = 0
    for y in range(fill_step // 2, mh, fill_step):
        for x in range(fill_step // 2, mw, fill_step):
            if not mask[y][x]:
                continue
            d = dist[y][x]
            if d < 7.0:
                continue
            peak = d
            for dy in range(-5, 6):
                for dx in range(-5, 6):
                    xx, yy = x + dx, y + dy
                    if 0 <= xx < mw and 0 <= yy < mh and mask[yy][xx]:
                        peak = max(peak, dist[yy][xx])
            if d < peak - 4.0:
                continue
            u, v = _cell_to_uv(x, y, mw, mh)
            radius = _radius_from_thick(d, max_thick, cfg["r_tip"], cfg["r_trunk"], cell_world) * thick_mult
            lx, ly, _ = _uv_to_local(u, v, plane_w, plane_h, cfg["depth_local"])
            too_close = False
            for ex, ey, er, ed in existing:
                # Only treat as covered if a *thick enough* seed already sits nearby
                if ed < d * 0.7:
                    continue
                if math.hypot(lx - ex, ly - ey) < max(radius, er) * 0.55:
                    too_close = True
                    break
            if too_close:
                continue
            elements.append({"type": "BALL", "u": u, "v": v, "radius": radius})
            existing.append((lx, ly, radius, d))
            n_fill += 1

    # Forbidden pairs: non-edge close nodes across a gap that would still fuse
    edge_set = set()
    for a, b, _ in work_edges:
        edge_set.add((min(a, b), max(a, b)))
    forbidden: list[list[int]] = []
    for i in range(len(work_nodes)):
        for j in range(i + 1, len(work_nodes)):
            if (i, j) in edge_set:
                continue
            xi, yi = work_nodes[i][0], work_nodes[i][1]
            xj, yj = work_nodes[j][0], work_nodes[j][1]
            if xi < 0 or xj < 0:
                continue
            ui, vi, ri = work_nodes[i][2], work_nodes[i][3], work_nodes[i][4]
            uj, vj, rj = work_nodes[j][2], work_nodes[j][3], work_nodes[j][4]
            lxi, lyi, _ = _uv_to_local(ui, vi, plane_w, plane_h, cfg["depth_local"])
            lxj, lyj, _ = _uv_to_local(uj, vj, plane_w, plane_h, cfg["depth_local"])
            d = math.hypot(lxi - lxj, lyi - lyj)
            if d > fusion_span(ri, rj, thresh, stiff):
                continue
            if not _line_clear(mask, mw, mh, xi, yi, xj, yj):
                forbidden.append([i, j])

    trace = empty_trace(empty_name, plane_w, plane_h, cfg)
    trace["elements"] = elements
    trace["forbidden_pairs"] = forbidden
    trace["scan_stats"] = {
        "mask": [mw, mh],
        "skeleton": len(skeleton),
        "nodes": len(work_nodes),
        "mst_edges": len(work_edges),
        "elements": len(elements),
        "fill_balls": n_fill,
        "forbidden": len(forbidden),
        "connected_nodes": len(in_tree),
    }

    path = write_trace(empty_name, trace)
    print(
        f"[scan_shape] {empty_name} → {len(elements)} elements "
        f"(nodes={len(work_nodes)}, edges={len(work_edges)}, forbidden={len(forbidden)})"
    )
    print(f"[scan_shape] json → {path}")

    if write_preview:
        _save_preview_png(
            preview_png_path(empty_name),
            mask,
            dist,
            mw,
            mh,
            [(n[0], n[1]) for n in work_nodes],
            [(a, b) for a, b, _ in work_edges],
            elements,
        )

    return path


if __name__ == "__main__":
    scan("FireCoral")
