--!strict
--[[
	Brain coral stacking: offset nests, center snap dots, class child caps, drift clamp.
]]

local BrainStack = {}

BrainStack.SPECIES_ID = "BrainCoral"
BrainStack.ITEM_ID = "BrainCoral"

-- Horizontal offset as a fraction of host radius (top-nest overhang).
BrainStack.OFFSET_MIN_FRAC = 0.32
BrainStack.OFFSET_MAX_FRAC = 0.62
-- New center lands in the upper 40% of host sphere height.
BrainStack.TOP_HEIGHT_FRAC = 0.40
-- Center snap-dot diameter (studs).
BrainStack.SNAP_DOT_DIAM = 0.5
-- Finger/cursor must be within this many studs of the dot center to snap.
BrainStack.SNAP_DOT_HIT_STUDS = 1.35
-- Screen-space fallback when projecting the dot (px).
BrainStack.SNAP_DOT_HIT_PX = 48
-- How far aim can be from a host (XZ) to show the host as a candidate.
BrainStack.ENGAGE_PAD = 1.25
-- Total XZ wander from stack root.
BrainStack.MAX_ROOT_DRIFT = 10
-- Orbit step when rotating a snapped child around its parent.
BrainStack.ORBIT_ROT_STEP = math.rad(10)
BrainStack.MIN_REROLL_ANGLE = math.rad(55)
-- Max children by parent size class (S/M/L).
BrainStack.MAX_CHILDREN_BY_CLASS = {
	[1] = 1,
	[2] = 2,
	[3] = 3,
}
-- Hard cap on brains in one stack tree (root + all descendants).
BrainStack.MAX_STACK_SIZE = 30
-- Snap dots only show within this distance of aim (studs).
BrainStack.SNAP_DOT_SHOW_STUDS = 100

function BrainStack.isBrainId(id: any): boolean
	return id == BrainStack.SPECIES_ID or id == BrainStack.ITEM_ID
end

function BrainStack.diameterOfPart(part: BasePart): number
	local attr = part:GetAttribute("OceanTD_Diameter")
	if typeof(attr) == "number" and attr > 0 then
		return attr
	end
	return math.max(part.Size.X, part.Size.Y, part.Size.Z)
end

function BrainStack.readPlaceId(part: BasePart): string?
	local id = part:GetAttribute("OceanTD_PlaceId")
	return if typeof(id) == "string" and id ~= "" then id else nil
end

function BrainStack.readParentPlaceId(part: BasePart): string?
	local id = part:GetAttribute("OceanTD_ParentPlaceId")
	return if typeof(id) == "string" and id ~= "" then id else nil
end

function BrainStack.maxChildrenForClass(sizeClass: number): number
	local c = math.clamp(math.floor(sizeClass), 1, 3)
	return BrainStack.MAX_CHILDREN_BY_CLASS[c] or 1
end

function BrainStack.maxChildrenForPart(part: BasePart): number
	local attr = part:GetAttribute("OceanTD_SizeClass")
	local class = if typeof(attr) == "number" then attr else BrainStack.classFromDiameter(BrainStack.diameterOfPart(part))
	return BrainStack.maxChildrenForClass(class)
end

function BrainStack.classFromDiameter(d: number): number
	if d <= 4 then
		return 1
	end
	if d <= 6 then
		return 2
	end
	return 3
end

-- Orbit nest: Y from sink nest, XZ on a horizontal circle facing `angle`.
function BrainStack.orbitNestCenter(
	hostPos: Vector3,
	hostDiam: number,
	newDiam: number,
	angle: number,
	frac: number?
): Vector3
	local f = if typeof(frac) == "number" then frac else (BrainStack.OFFSET_MIN_FRAC + BrainStack.OFFSET_MAX_FRAC) * 0.5
	local dist = hostDiam * 0.5 * math.clamp(f, BrainStack.OFFSET_MIN_FRAC, BrainStack.OFFSET_MAX_FRAC)
	local ox = math.cos(angle) * dist
	local oz = math.sin(angle) * dist
	return BrainStack.topNestCenter(hostPos, hostDiam, newDiam, ox, oz)
end

function BrainStack.approachAngle(fromPos: Vector3, hostPos: Vector3): number
	local dx = fromPos.X - hostPos.X
	local dz = fromPos.Z - hostPos.Z
	if dx * dx + dz * dz < 1e-6 then
		return math.random() * math.pi * 2
	end
	return math.atan2(dz, dx)
end

-- How far the new ball center sinks into the lower ball (overlap).
function BrainStack.sinkAmount(belowDiam: number, newDiam: number): number
	-- Light kiss — enough nest to read as stacked, not buried.
	return math.clamp(math.min(belowDiam, newDiam) * 0.12, 0.22, 0.55)
end

function BrainStack.stackCenterY(belowY: number, belowDiam: number, newDiam: number): number
	local sink = BrainStack.sinkAmount(belowDiam, newDiam)
	if newDiam > belowDiam then
		-- Large on small: rest the child's bottom 5% on the host top nest (not child center).
		local hostTop = belowY + belowDiam * 0.5
		local bottomFrac = 0.05
		return hostTop - sink + newDiam * (0.5 - bottomFrac)
	end
	return belowY + (belowDiam + newDiam) * 0.5 - sink
end

function BrainStack.snapDotWorldPos(hostPos: Vector3, _hostDiam: number?): Vector3
	return hostPos
end

function BrainStack.horizontalDist(a: Vector3, b: Vector3): number
	local dx = a.X - b.X
	local dz = a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz)
end

function BrainStack.snapCircleWorldPos(hostPos: Vector3, hostDiam: number): Vector3
	return hostPos + Vector3.new(0, hostDiam * 0.5, 0)
end

function BrainStack.engageRadius(hostDiam: number): number
	return hostDiam * 0.5 + BrainStack.ENGAGE_PAD
end

function BrainStack.canEngageSnap(aimPos: Vector3, hostPos: Vector3, hostDiam: number): boolean
	local horiz = BrainStack.horizontalDist(aimPos, hostPos)
	return horiz <= BrainStack.engageRadius(hostDiam)
end

function BrainStack.pointerHitsDot(screenPos: Vector2?, aimPos: Vector3, hostPos: Vector3): boolean
	local cam = workspace.CurrentCamera
	if screenPos and cam then
		local sp, onScreen = cam:WorldToViewportPoint(hostPos)
		if onScreen and sp.Z > 0 then
			local px = (Vector2.new(sp.X, sp.Y) - screenPos).Magnitude
			if px <= BrainStack.SNAP_DOT_HIT_PX then
				return true
			end
		end
	end
	-- Aim is usually on the plot floor — use XZ distance to the ball center.
	return BrainStack.horizontalDist(aimPos, hostPos) <= BrainStack.SNAP_DOT_HIT_STUDS
end

function BrainStack.withinRootDrift(rootPos: Vector3, worldPos: Vector3): boolean
	return BrainStack.horizontalDist(rootPos, worldPos) <= BrainStack.MAX_ROOT_DRIFT + 1e-3
end

export type SnapOffset = { angle: number, frac: number }

function BrainStack.pickSnapOffset(hostDiam: number, avoidAngle: number?): SnapOffset
	local frac = BrainStack.OFFSET_MIN_FRAC
		+ math.random() * (BrainStack.OFFSET_MAX_FRAC - BrainStack.OFFSET_MIN_FRAC)
	local angle = math.random() * math.pi * 2
	if typeof(avoidAngle) == "number" then
		local tries = 0
		while tries < 10 do
			local delta = math.abs(angle - avoidAngle)
			delta = math.min(delta, math.pi * 2 - delta)
			if delta >= BrainStack.MIN_REROLL_ANGLE then
				break
			end
			angle = math.random() * math.pi * 2
			tries += 1
		end
	end
	return { angle = angle, frac = frac }
end

-- Nest on host top with XZ offset; Y uses sink overlap (center stays in upper host band).
function BrainStack.topNestCenter(
	hostPos: Vector3,
	hostDiam: number,
	newDiam: number,
	offsetX: number,
	offsetZ: number
): Vector3
	local hostR = hostDiam * 0.5
	-- Allow the authored offset range (plus a little slack for side-lean).
	local maxOff = hostR * BrainStack.OFFSET_MAX_FRAC * 1.25
	local ox = offsetX
	local oz = offsetZ
	local len = math.sqrt(ox * ox + oz * oz)
	if len > maxOff and len > 1e-4 then
		local s = maxOff / len
		ox *= s
		oz *= s
		len = maxOff
	end
	-- Keep contact in top 40% of host height: clamp radial offset vs height band.
	local minYLocal = hostR * (1 - BrainStack.TOP_HEIGHT_FRAC) -- 0.6R below top → 0.2R above center
	local maxSlice = math.sqrt(math.max(0, hostR * hostR - minYLocal * minYLocal))
	if len > maxSlice * 0.98 and len > 1e-4 then
		local s = (maxSlice * 0.98) / len
		ox *= s
		oz *= s
	end
	local y = BrainStack.stackCenterY(hostPos.Y, hostDiam, newDiam)
	return Vector3.new(hostPos.X + ox, y, hostPos.Z + oz)
end

function BrainStack.stackedCenterFromSnap(
	hostPos: Vector3,
	hostDiam: number,
	newDiam: number,
	snap: SnapOffset
): Vector3
	local dist = hostDiam * 0.5 * snap.frac
	local ox = math.cos(snap.angle) * dist
	local oz = math.sin(snap.angle) * dist
	return BrainStack.topNestCenter(hostPos, hostDiam, newDiam, ox, oz)
end

-- Side nest used when attaching to a host that already has a child on top.
function BrainStack.sideBranchCenter(
	hostPos: Vector3,
	hostDiam: number,
	newDiam: number,
	angle: number,
	frac: number?
): Vector3
	local hostR = hostDiam * 0.5
	local newR = newDiam * 0.5
	local f = if typeof(frac) == "number" then frac else (BrainStack.OFFSET_MIN_FRAC + BrainStack.OFFSET_MAX_FRAC) * 0.5
	-- Push further out than a top nest so it sits on the flank of the host.
	local radial = hostR * math.clamp(f + 0.35, 0.4, 0.85) + newR * 0.15
	local ox = math.cos(angle) * radial
	local oz = math.sin(angle) * radial
	-- Stable height in top 40% band from frac (no per-frame random).
	local yLocal = hostR * (0.25 + math.clamp(f, 0.15, 0.3) * 1.4)
	local y = hostPos.Y + yLocal
	local sink = BrainStack.sinkAmount(hostDiam, newDiam) * 0.55
	local toward = Vector3.new(ox, yLocal, oz)
	if toward.Magnitude > 1e-4 then
		toward = toward.Unit * sink
		return Vector3.new(hostPos.X + ox - toward.X, y - toward.Y * 0.35, hostPos.Z + oz - toward.Z)
	end
	return Vector3.new(hostPos.X + ox, y, hostPos.Z + oz)
end

-- True when no overlapping brain sits clearly above this one.
-- Fast path: parent link means buried under a stack parent.
function BrainStack.isTopExposed(part: BasePart, neighbors: { BasePart }): boolean
	if BrainStack.readParentPlaceId(part) then
		return false
	end
	local r = BrainStack.diameterOfPart(part) * 0.5
	for _, other in ipairs(neighbors) do
		if other ~= part and other.Parent then
			if other.Position.Y > part.Position.Y + 0.2 then
				local otherR = BrainStack.diameterOfPart(other) * 0.5
				if BrainStack.horizontalDist(part.Position, other.Position) <= (r + otherR) * 0.85 then
					return false
				end
			end
		end
	end
	return true
end

-- Parent + children + siblings only (not the whole plot).
function BrainStack.collectLinkNeighbors(part: BasePart, brains: { BasePart }): { BasePart }
	local myId = BrainStack.readPlaceId(part)
	local parentId = BrainStack.readParentPlaceId(part)
	local out: { BasePart } = {}
	for _, other in ipairs(brains) do
		if other ~= part and other.Parent then
			local oid = BrainStack.readPlaceId(other)
			local opid = BrainStack.readParentPlaceId(other)
			local isParent = parentId ~= nil and oid == parentId
			local isChild = myId ~= nil and opid == myId
			local isSibling = parentId ~= nil and opid == parentId
			if isParent or isChild or isSibling then
				table.insert(out, other)
			end
		end
	end
	return out
end

local function directionOpenness(part: BasePart, dir: Vector3, neighbors: { BasePart }): number
	local r = BrainStack.diameterOfPart(part) * 0.5
	local score = 1
	for _, other in ipairs(neighbors) do
		if other == part or not other.Parent then
			continue
		end
		local delta = other.Position - part.Position
		local horiz = Vector3.new(delta.X, 0, delta.Z)
		local otherR = BrainStack.diameterOfPart(other) * 0.5
		if horiz.Magnitude < 0.08 then
			if delta.Y > 0 then
				score -= 0.85
			end
			continue
		end
		local align = horiz.Unit:Dot(dir)
		if align > 0.15 then
			local gap = horiz.Magnitude - r - otherR
			local blocked = 1 - math.clamp(gap / math.max(r + otherR, 0.5), 0, 1)
			score -= align * blocked
		end
	end
	return score
end

-- Ammo nest points in part-local space. Top brains: above. Buried: open flanks.
function BrainStack.ammoLocalOffsets(
	part: BasePart,
	foodCount: number,
	ammoRadius: number,
	neighbors: { BasePart }
): { Vector3 }
	local n = math.clamp(math.floor(foodCount), 1, 4)
	local r = BrainStack.diameterOfPart(part) * 0.5
	if BrainStack.isTopExposed(part, neighbors) then
		local y = r + ammoRadius
		if n <= 1 then
			return { Vector3.new(0, y, 0) }
		end
		if n == 2 then
			local s = ammoRadius * 1.2
			return {
				Vector3.new(-s, y, 0),
				Vector3.new(s, y, 0),
			}
		end
		local s = ammoRadius * 2.05
		return {
			Vector3.new(0, y, s),
			Vector3.new(-s * 0.866, y, -s * 0.5),
			Vector3.new(s * 0.866, y, -s * 0.5),
		}
	end

	-- Side distribution: pick the most open equatorial directions.
	local candidates = 8
	local scored: { { ang: number, score: number } } = {}
	for i = 0, candidates - 1 do
		local ang = (i / candidates) * math.pi * 2
		local dir = Vector3.new(math.cos(ang), 0, math.sin(ang))
		table.insert(scored, { ang = ang, score = directionOpenness(part, dir, neighbors) })
	end
	table.sort(scored, function(a, b)
		return a.score > b.score
	end)

	local radial = r * 0.92 + ammoRadius * 0.35
	local ySide = r * 0.12
	local out: { Vector3 } = {}
	local used: { number } = {}
	for _, entry in ipairs(scored) do
		if #out >= n then
			break
		end
		local tooClose = false
		for _, ua in ipairs(used) do
			local d = math.abs(entry.ang - ua)
			d = math.min(d, math.pi * 2 - d)
			if d < math.rad(40) then
				tooClose = true
				break
			end
		end
		if not tooClose then
			table.insert(used, entry.ang)
			table.insert(out, Vector3.new(math.cos(entry.ang) * radial, ySide, math.sin(entry.ang) * radial))
		end
	end
	while #out < n do
		local ang = (#out / n) * math.pi * 2
		table.insert(out, Vector3.new(math.cos(ang) * radial, ySide, math.sin(ang) * radial))
	end
	return out
end

-- Keep XZ offset from parent; lift Y so balls don't bury after a size change.
function BrainStack.restackChildCenter(
	parentPos: Vector3,
	parentDiam: number,
	childDiam: number,
	offsetX: number,
	offsetZ: number,
	oldYRel: number?
): Vector3
	local hostR = parentDiam * 0.5
	local childR = childDiam * 0.5
	local ox = offsetX
	local oz = offsetZ
	local horiz = math.sqrt(ox * ox + oz * oz)
	local nestY = BrainStack.stackCenterY(parentPos.Y, parentDiam, childDiam)
	local y: number
	if horiz > hostR * BrainStack.OFFSET_MAX_FRAC * 1.25 and typeof(oldYRel) == "number" then
		-- Side nest: preserve relative height, then enforce clearance.
		y = parentPos.Y + oldYRel
		local minY = parentPos.Y + hostR * 0.15
		local maxY = nestY
		y = math.clamp(y, minY, maxY)
	else
		y = nestY
	end
	local pos = Vector3.new(parentPos.X + ox, y, parentPos.Z + oz)
	local delta = pos - parentPos
	local minDist = (hostR + childR) - BrainStack.sinkAmount(parentDiam, childDiam)
	if delta.Magnitude > 1e-4 and delta.Magnitude < minDist then
		pos = parentPos + delta.Unit * minDist
	end
	return pos
end

-- Ground root: keep bottom on the plot floor when diameter changes.
function BrainStack.liftRootCenter(oldCenterY: number, oldDiam: number, newDiam: number): number
	return oldCenterY + (newDiam - oldDiam) * 0.5
end

return BrainStack
