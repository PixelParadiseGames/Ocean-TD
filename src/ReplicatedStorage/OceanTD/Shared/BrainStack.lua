--!strict
--[[
	Brain coral stacking: offset nests, center snap dots, class child caps, drift clamp.
]]

local BrainStack = {}

BrainStack.SPECIES_ID = "BrainCoral"
BrainStack.ITEM_ID = "BrainCoral"

-- Horizontal offset as a fraction of host radius (lump lean on the host sphere surface).
BrainStack.OFFSET_MIN_FRAC = 0.18
BrainStack.OFFSET_MAX_FRAC = 0.42
-- Fixed lean for multi-seat hosts (Option A discrete seats). Single seat uses top (0).
BrainStack.SEAT_LEAN_FRAC = 0.32
-- Keep nests on the upper hemisphere (child center on host sphere, Y >= this * hostR).
BrainStack.TOP_HEIGHT_FRAC = 0.55
-- Center snap-dot diameter (studs).
BrainStack.SNAP_DOT_DIAM = 0.5
-- Finger/cursor must be within this many studs of the seat dot to snap.
BrainStack.SNAP_DOT_HIT_STUDS = 1.55
-- Screen-space fallback when projecting the seat (px).
BrainStack.SNAP_DOT_HIT_PX = 56
-- How far aim can be from a host (XZ) to show the host as a candidate.
BrainStack.ENGAGE_PAD = 1.25
-- Total XZ wander from stack root.
BrainStack.MAX_ROOT_DRIFT = 10
-- Orbit step when rotating a snapped child around its parent (legacy continuous).
BrainStack.ORBIT_ROT_STEP = math.rad(15)
BrainStack.MIN_REROLL_ANGLE = math.rad(55)
-- Max children / seat count by parent size class (S/M/L).
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

function BrainStack.seatCountForPart(part: BasePart): number
	return BrainStack.maxChildrenForPart(part)
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

-- Stable seat ring orientation from placeId (doesn't spin when the ball yaws).
function BrainStack.seatBaseYaw(placeId: string?): number
	if typeof(placeId) ~= "string" or placeId == "" then
		return 0
	end
	local h = 0
	for i = 1, #placeId do
		h = (h * 31 + string.byte(placeId, i)) % 997
	end
	return (h / 997) * math.pi * 2
end

function BrainStack.seatAngle(seatIndex: number, seatCount: number, baseYaw: number): number
	local n = math.max(1, math.floor(seatCount))
	local i = ((math.floor(seatIndex) - 1) % n) + 1
	return baseYaw + (i - 1) * (math.pi * 2 / n)
end

function BrainStack.seatLeanFrac(seatCount: number): number
	if seatCount <= 1 then
		return 0 -- pure top nest for S
	end
	return BrainStack.SEAT_LEAN_FRAC
end

-- Discrete seat on host sphere (child center on host radius).
function BrainStack.seatWorldPos(
	hostPos: Vector3,
	hostDiam: number,
	newDiam: number,
	seatIndex: number,
	seatCount: number,
	baseYaw: number
): (Vector3, number, number)
	local lean = BrainStack.seatLeanFrac(seatCount)
	local angle = BrainStack.seatAngle(seatIndex, seatCount, baseYaw)
	local dist = hostDiam * 0.5 * lean
	local ox = math.cos(angle) * dist
	local oz = math.sin(angle) * dist
	local world = BrainStack.topNestCenter(hostPos, hostDiam, newDiam, ox, oz)
	return world, angle, lean
end

function BrainStack.nearestSeatIndex(
	hostPos: Vector3,
	hostDiam: number,
	newDiam: number,
	seatCount: number,
	baseYaw: number,
	worldPos: Vector3
): number
	local n = math.max(1, math.floor(seatCount))
	local best = 1
	local bestDist = math.huge
	for i = 1, n do
		local seatPos = BrainStack.seatWorldPos(hostPos, hostDiam, newDiam, i, n, baseYaw)
		local d = (seatPos - worldPos).Magnitude
		if d < bestDist then
			bestDist = d
			best = i
		end
	end
	return best
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

-- Radial distance from host center → child center = host radius (child center on host surface).
-- That sinks ~50% of the child into the parent along the nest axis, for any size pair.
function BrainStack.surfaceNestDistance(hostDiam: number, _newDiam: number): number
	return hostDiam * 0.5
end

-- Legacy alias: overlap depth along the nest axis ≈ child radius when using surface nesting.
function BrainStack.sinkAmount(belowDiam: number, newDiam: number): number
	return math.min(belowDiam, newDiam) * 0.5
end

function BrainStack.stackCenterY(belowY: number, belowDiam: number, _newDiam: number): number
	-- Pure top nest (no XZ lean): child center on host north pole.
	return belowY + belowDiam * 0.5
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

-- Nest on host: child CENTER lies on the host sphere (≈50% sunk). XZ lean keeps upper hemisphere.
function BrainStack.topNestCenter(
	hostPos: Vector3,
	hostDiam: number,
	_newDiam: number,
	offsetX: number,
	offsetZ: number
): Vector3
	local hostR = hostDiam * 0.5
	-- Stay on upper hemisphere so lumps read as a mound, not under-hangs.
	local minYLocal = hostR * BrainStack.TOP_HEIGHT_FRAC
	local maxHoriz = math.sqrt(math.max(0, hostR * hostR - minYLocal * minYLocal))
	local maxOff = math.min(hostR * BrainStack.OFFSET_MAX_FRAC * 1.15, maxHoriz * 0.98)
	local ox = offsetX
	local oz = offsetZ
	local len = math.sqrt(ox * ox + oz * oz)
	if len > maxOff and len > 1e-4 then
		local s = maxOff / len
		ox *= s
		oz *= s
		len = maxOff
	end
	local yOff = math.sqrt(math.max(0, hostR * hostR - ox * ox - oz * oz))
	return Vector3.new(hostPos.X + ox, hostPos.Y + yOff, hostPos.Z + oz)
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

-- Side nest when host already has a top child — still on host sphere, just further around.
function BrainStack.sideBranchCenter(
	hostPos: Vector3,
	hostDiam: number,
	newDiam: number,
	angle: number,
	frac: number?
): Vector3
	local f = if typeof(frac) == "number" then frac else (BrainStack.OFFSET_MIN_FRAC + BrainStack.OFFSET_MAX_FRAC) * 0.5
	-- Wider lean than top-nest, still clamped onto the sphere surface by topNestCenter.
	local lean = math.clamp(f + 0.28, 0.40, 0.72)
	local hostR = hostDiam * 0.5
	local ox = math.cos(angle) * hostR * lean
	local oz = math.sin(angle) * hostR * lean
	return BrainStack.topNestCenter(hostPos, hostDiam, newDiam, ox, oz)
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

-- Keep XZ lean from parent; re-seat child center on the parent sphere after a size change.
function BrainStack.restackChildCenter(
	parentPos: Vector3,
	parentDiam: number,
	childDiam: number,
	offsetX: number,
	offsetZ: number,
	_oldYRel: number?
): Vector3
	return BrainStack.topNestCenter(parentPos, parentDiam, childDiam, offsetX, offsetZ)
end

-- Ground root: keep bottom on the plot floor when diameter changes.
function BrainStack.liftRootCenter(oldCenterY: number, oldDiam: number, newDiam: number): number
	return oldCenterY + (newDiam - oldDiam) * 0.5
end

return BrainStack
