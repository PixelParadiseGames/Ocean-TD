--!strict
--[[
	Coral path coverage for WaveSim feeding.

	FEED_MODE:
	  lane_stock  — Option 2: capped food stock per path bucket; corals restock on
	                reload; fish drink front-first (contested). Nest ammo stays parked;
	                WaveSim fires uncapped visual-only orbs when restock feeds a fish.
	  volleys     — Option 1: stamp wake + discrete fireShot / sparse orbs.
	  path_fields — one serving per reload, spread across the covered stretch and shared by the fish there.
]]

local Path = require(script.Parent:WaitForChild("WaveSimPath"))
local C = require(script.Parent:WaitForChild("WaveSimConsts"))
local WaveCrab = require(script.Parent:WaitForChild("WaveCrab"))
local PlaceConfirmHitTest = require(script.Parent:WaitForChild("PlaceConfirmHitTest"))
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local WaveSimCoralBuckets = {}

export type PathData = Path.PathData

WaveSimCoralBuckets.ROUTE_A = 1
WaveSimCoralBuckets.ROUTE_A2 = 2
WaveSimCoralBuckets.ROUTE_SHARK = 3
WaveSimCoralBuckets.ROUTE_GROUND_A = 4
WaveSimCoralBuckets.ROUTE_GROUND_B = 5
WaveSimCoralBuckets.ROUTE_COUNT = 5

export type BucketCoral = {
	part: BasePart,
	range: number,
	rangeSq: number,
	foodFill: number,
	reloadSec: number,
	pathDist: number,
	pathSideDist: number,
	pathBuckets: { number },
	routeBuckets: { { number } },
	routeNearDist: { number },
	combatScore: number,
	combatGen: number,
	stunned: boolean,
	rateShare: number?,
	readyAt: number?,
	lanePulseReady: boolean?,
}

export type RoutePaths = {
	[number]: PathData?,
}

-- System C continuous rates.
local feedFields: { { number } } = {}
-- Coral that add rate to each slice, so a shot can pick one without scanning all nests.
local sliceCoral: { { { BucketCoral } } } = {}
-- Option 2 contested stock + capacity.
local stockFields: { { number } } = {}
local capFields: { { number } } = {}
-- Scratch: hungry fish listed per route bucket (front-first drink).
local hungryScratch: { { { any } } } = {}

for i = 1, WaveSimCoralBuckets.ROUTE_COUNT do
	feedFields[i] = {}
	sliceCoral[i] = {}
	stockFields[i] = {}
	capFields[i] = {}
	hungryScratch[i] = {}
end

local function emptyBucketLists(): { { number } }
	local t: { { number } } = {}
	for i = 1, WaveSimCoralBuckets.ROUTE_COUNT do
		t[i] = {}
	end
	return t
end

local function emptyNearDists(): { number }
	local t: { number } = {}
	for i = 1, WaveSimCoralBuckets.ROUTE_COUNT do
		t[i] = 0
	end
	return t
end

function WaveSimCoralBuckets.newRouteBuckets(): ({ { number } }, { number })
	return emptyBucketLists(), emptyNearDists()
end

local function ensureRouteArraySize(arr: { number }, path: PathData)
	local maxBi = math.max(1, math.ceil(path.totalLen / C.PATH_BUCKET_SIZE) + 1)
	while #arr < maxBi do
		table.insert(arr, 0)
	end
	for i = 1, maxBi do
		arr[i] = arr[i] or 0
	end
	-- Trim not required; leave extra zeros.
	return maxBi
end

local function bucketIndex(dist: number, maxBi: number): number
	return math.clamp(math.floor(math.max(0, dist) / C.PATH_BUCKET_SIZE) + 1, 1, math.max(1, maxBi))
end

--[[
	Stamp one route: every path sample within range+lateral → bucket index.
	Also records nearest in-range sample distance for priority scoring.
]]
function WaveSimCoralBuckets.assignBuckets(coralPos: Vector3, range: number, path: PathData): ({ number }, number, number)
	local pad = range + C.LATERAL_SPREAD
	local rangeSq = pad * pad
	local step = C.PATH_BUCKET_SIZE
	local buckets: { number } = {}
	local seen: { [number]: boolean } = {}
	local bestDist = 0
	local bestSide = pad
	local bestD2 = math.huge
	local d = 0
	local total = path.totalLen
	while d <= total do
		local p = Path.samplePath(path, d)
		local dx = p.X - coralPos.X
		local dy = p.Y - coralPos.Y
		local dz = p.Z - coralPos.Z
		local d2 = dx * dx + dy * dy + dz * dz
		if d2 <= rangeSq then
			local bi = math.floor(d / step) + 1
			if not seen[bi] then
				seen[bi] = true
				table.insert(buckets, bi)
			end
			if d2 < bestD2 then
				bestD2 = d2
				bestDist = d
				bestSide = math.sqrt(d2)
			end
		end
		d += step
	end
	if total > 0 then
		local p = Path.samplePath(path, total)
		local dx = p.X - coralPos.X
		local dy = p.Y - coralPos.Y
		local dz = p.Z - coralPos.Z
		local d2 = dx * dx + dy * dy + dz * dz
		if d2 <= rangeSq then
			local bi = math.floor(total / step) + 1
			if not seen[bi] then
				table.insert(buckets, bi)
			end
			if d2 < bestD2 then
				bestD2 = d2
				bestDist = total
				bestSide = math.sqrt(d2)
			end
		end
	end
	return buckets, bestDist, bestSide
end

function WaveSimCoralBuckets.assignAllRoutes(
	coralPos: Vector3,
	range: number,
	paths: RoutePaths
): ({ { number } }, { number })
	local routeBuckets = emptyBucketLists()
	local routeNear = emptyNearDists()
	for route = 1, WaveSimCoralBuckets.ROUTE_COUNT do
		local path = paths[route]
		if path and path.totalLen >= 1 then
			local buckets, nearDist = WaveSimCoralBuckets.assignBuckets(coralPos, range, path)
			routeBuckets[route] = buckets
			routeNear[route] = nearDist
		end
	end
	return routeBuckets, routeNear
end

function WaveSimCoralBuckets.ensureIndexSize(index: { { BucketCoral } }, path: PathData): number
	local maxBi = math.max(1, math.ceil(path.totalLen / C.PATH_BUCKET_SIZE) + 1)
	while #index < maxBi do
		table.insert(index, {})
	end
	for i = 1, #index do
		table.clear(index[i])
	end
	return maxBi
end

function WaveSimCoralBuckets.newRouteIndices(): { { { BucketCoral } } }
	local t: { { { BucketCoral } } } = {}
	for i = 1, WaveSimCoralBuckets.ROUTE_COUNT do
		t[i] = {}
	end
	return t
end

function WaveSimCoralBuckets.rebuildAllIndices(
	indices: { { { BucketCoral } } },
	corals: { BucketCoral },
	paths: RoutePaths
)
	local mode = C.FEED_MODE
	if mode == "path_fields" then
		WaveSimCoralBuckets.rebuildFeedFields(corals, paths)
		WaveSimCoralBuckets.rebuildServingCaps(corals, paths)
		return
	end
	if mode == "lane_stock" then
		WaveSimCoralBuckets.rebuildLaneCaps(corals, paths)
		return
	end
	-- volleys: coral→bucket wake lists
	for route = 1, WaveSimCoralBuckets.ROUTE_COUNT do
		local index = indices[route]
		local path = paths[route]
		if not path or path.totalLen < 1 then
			for i = 1, #index do
				table.clear(index[i])
			end
			continue
		end
		WaveSimCoralBuckets.ensureIndexSize(index, path)
		for _, coral in ipairs(corals) do
			if coral.stunned or not coral.part.Parent then
				continue
			end
			local buckets = coral.routeBuckets and coral.routeBuckets[route]
			if not buckets then
				continue
			end
			for _, bi in ipairs(buckets) do
				local bucket = index[bi]
				if bucket then
					table.insert(bucket, coral)
				end
			end
		end
	end
end

--[[
	Option 2: capacity per bucket = sum of foodFill of covering nests.
	Stock is clamped to the new cap (kept across rebuilds when possible).
]]
function WaveSimCoralBuckets.rebuildLaneCaps(corals: { BucketCoral }, paths: RoutePaths)
	for route = 1, WaveSimCoralBuckets.ROUTE_COUNT do
		local caps = capFields[route]
		local stock = stockFields[route]
		local path = paths[route]
		table.clear(caps)
		if not path or path.totalLen < 1 then
			table.clear(stock)
			continue
		end
		local maxBi = ensureRouteArraySize(caps, path)
		ensureRouteArraySize(stock, path)
		for i = 1, maxBi do
			caps[i] = 0
		end
		-- Preserve existing stock values already in `stock` (sized above).
	end
	for _, coral in ipairs(corals) do
		if coral.stunned or not coral.part.Parent then
			continue
		end
		local fill = coral.foodFill or C.DEFAULT_FOOD_FILL
		if fill <= 0 then
			continue
		end
		local routeBuckets = coral.routeBuckets
		if not routeBuckets then
			continue
		end
		for route = 1, WaveSimCoralBuckets.ROUTE_COUNT do
			local caps = capFields[route]
			local buckets = routeBuckets[route]
			if not buckets or #caps < 1 then
				continue
			end
			for _, bi in ipairs(buckets) do
				if caps[bi] ~= nil then
					caps[bi] += fill
				end
			end
		end
	end
	for route = 1, WaveSimCoralBuckets.ROUTE_COUNT do
		local caps = capFields[route]
		local stock = stockFields[route]
		for i = 1, #caps do
			local cap = caps[i] or 0
			local s = stock[i] or 0
			if s > cap then
				stock[i] = cap
			elseif stock[i] == nil then
				stock[i] = 0
			end
		end
	end
end

-- Deposit foodFill into the nearest stamped bucket on each covered route.
-- Returns true if any stock was actually added (under cap).
function WaveSimCoralBuckets.restockFromCoral(coral: BucketCoral): boolean
	local fill = coral.foodFill or C.DEFAULT_FOOD_FILL
	if fill <= 0 or coral.stunned then
		return false
	end
	local routeBuckets = coral.routeBuckets
	local routeNear = coral.routeNearDist
	if not routeBuckets then
		return false
	end
	local any = false
	for route = 1, WaveSimCoralBuckets.ROUTE_COUNT do
		local buckets = routeBuckets[route]
		if not buckets or #buckets < 1 then
			continue
		end
		local stock = stockFields[route]
		local caps = capFields[route]
		if #stock < 1 then
			continue
		end
		local near = if routeNear then routeNear[route] else 0
		local bi = bucketIndex(near, #stock)
		local bestBi = bi
		local bestErr = math.huge
		for _, b in ipairs(buckets) do
			local err = math.abs(b - bi)
			if err < bestErr then
				bestErr = err
				bestBi = b
			end
		end
		local cap = caps[bestBi] or 0
		local cur = stock[bestBi] or 0
		if cur < cap then
			local nextStock = math.min(cap, cur + fill)
			if nextStock > cur then
				stock[bestBi] = nextStock
				any = true
			end
		end
	end
	return any
end

-- Debug boxes are 22 wide and 22 tall. Two slices share food when those volumes touch.
local OVERLAP_TOUCH_XZ = 22
local OVERLAP_TOUCH_Y = 22
local overlapReady = false
local overlapPathRef: { any } = {}
local overlapPathLen: { number } = {}
local overlapNeighbors: { { { { route: number, bi: number } } } } = {}
for i = 1, WaveSimCoralBuckets.ROUTE_COUNT do
	overlapNeighbors[i] = {}
	overlapPathLen[i] = -1
end

local function closestOnSegments(p1: Vector3, q1: Vector3, p2: Vector3, q2: Vector3): (Vector3, Vector3)
	local d1 = q1 - p1
	local d2 = q2 - p2
	local r = p1 - p2
	local a = d1:Dot(d1)
	local e = d2:Dot(d2)
	local f = d2:Dot(r)
	local s = 0
	local t = 0
	if a <= 1e-6 and e <= 1e-6 then
		return p1, p2
	end
	if a <= 1e-6 then
		t = math.clamp(f / e, 0, 1)
	elseif e <= 1e-6 then
		s = math.clamp(-d1:Dot(r) / a, 0, 1)
	else
		local b = d1:Dot(d2)
		local c = d1:Dot(r)
		local denom = a * e - b * b
		if denom ~= 0 then
			s = math.clamp((b * f - c * e) / denom, 0, 1)
		end
		t = (b * s + f) / e
		if t < 0 then
			t = 0
			s = math.clamp(-c / a, 0, 1)
		elseif t > 1 then
			t = 1
			s = math.clamp((b - c) / a, 0, 1)
		end
	end
	return p1 + d1 * s, p2 + d2 * t
end

local function bucketChord(path: PathData, bi: number): (Vector3, Vector3)
	local step = C.PATH_BUCKET_SIZE
	local d0 = (bi - 1) * step
	local d1 = math.min(path.totalLen, bi * step)
	if d1 < d0 then
		d1 = d0
	end
	local p0 = Path.samplePath(path, d0)
	local p1 = Path.samplePath(path, d1)
	return p0, p1
end

local function chordsTouch(a0: Vector3, a1: Vector3, b0: Vector3, b1: Vector3): boolean
	local ca, cb = closestOnSegments(a0, a1, b0, b1)
	local dx = ca.X - cb.X
	local dy = ca.Y - cb.Y
	local dz = ca.Z - cb.Z
	local horiz = math.sqrt(dx * dx + dz * dz)
	return horiz <= OVERLAP_TOUCH_XZ and math.abs(dy) <= OVERLAP_TOUCH_Y
end

function WaveSimCoralBuckets.refreshBucketOverlaps(paths: RoutePaths)
	local same = overlapReady
	if same then
		for route = 1, WaveSimCoralBuckets.ROUTE_COUNT do
			local path = paths[route]
			if path ~= overlapPathRef[route] or (path and path.totalLen or -1) ~= overlapPathLen[route] then
				same = false
				break
			end
		end
	end
	if same then
		return
	end
	overlapReady = true
	local step = C.PATH_BUCKET_SIZE
	local chords: { { Vector3 } } = {}
	local counts: { number } = {}
	for route = 1, WaveSimCoralBuckets.ROUTE_COUNT do
		local path = paths[route]
		overlapPathRef[route] = path
		overlapPathLen[route] = if path then path.totalLen else -1
		local row = overlapNeighbors[route]
		local n = 0
		if path and path.totalLen >= 1 then
			n = math.max(1, math.ceil(path.totalLen / step) + 1)
		end
		counts[route] = n
		while #row < n do
			table.insert(row, {})
		end
		for i = 1, #row do
			local list = row[i]
			if list then
				table.clear(list)
			end
		end
		local routeChords: { Vector3 } = {}
		chords[route] = routeChords
		if path and n > 0 then
			for bi = 1, n do
				local p0, p1 = bucketChord(path, bi)
				routeChords[bi * 2 - 1] = p0
				routeChords[bi * 2] = p1
			end
		end
	end
	for routeA = 1, WaveSimCoralBuckets.ROUTE_COUNT do
		local nA = counts[routeA]
		local chordsA = chords[routeA]
		for routeB = routeA + 1, WaveSimCoralBuckets.ROUTE_COUNT do
			local nB = counts[routeB]
			local chordsB = chords[routeB]
			for bi = 1, nA do
				local a0 = chordsA[bi * 2 - 1]
				local a1 = chordsA[bi * 2]
				for bj = 1, nB do
					local b0 = chordsB[bj * 2 - 1]
					local b1 = chordsB[bj * 2]
					if a0 and a1 and b0 and b1 and chordsTouch(a0, a1, b0, b1) then
						table.insert(overlapNeighbors[routeA][bi], { route = routeB, bi = bj })
						table.insert(overlapNeighbors[routeB][bj], { route = routeA, bi = bi })
					end
				end
			end
		end
	end
end

function WaveSimCoralBuckets.drinkStock(routeId: number, dist: number, want: number): number
	if want <= 0 then
		return 0
	end
	local stock = stockFields[routeId]
	if not stock or #stock < 1 then
		return 0
	end
	local bi = bucketIndex(dist, #stock)
	local have = stock[bi] or 0
	local take = math.min(want, have)
	if take > 0 then
		stock[bi] = have - take
	end
	local got = take
	local remain = want - got
	if remain <= 1e-6 then
		return got
	end
	-- Crossing paths keep separate piles. A short bucket may take from a touching
	-- pile on another route, up to half of what that pile holds right now.
	local neighbors = overlapNeighbors[routeId] and overlapNeighbors[routeId][bi]
	if not neighbors then
		return got
	end
	for _, nb in ipairs(neighbors) do
		if remain <= 1e-6 then
			break
		end
		local other = stockFields[nb.route]
		local oHave = other and other[nb.bi] or 0
		if oHave > 1e-4 then
			local pull = math.min(remain, oHave * 0.5)
			if pull > 0 then
				other[nb.bi] = oHave - pull
				got += pull
				remain -= pull
			end
		end
	end
	return got
end

-- One serving per coral, spread across every slice it covers. Longer range covers more path, not a bigger meal.
function WaveSimCoralBuckets.rebuildServingCaps(corals: { BucketCoral }, paths: RoutePaths)
	for route = 1, WaveSimCoralBuckets.ROUTE_COUNT do
		local caps = capFields[route]
		local stock = stockFields[route]
		local path = paths[route]
		table.clear(caps)
		if not path or path.totalLen < 1 then
			table.clear(stock)
			continue
		end
		local maxBi = ensureRouteArraySize(caps, path)
		ensureRouteArraySize(stock, path)
		for i = 1, maxBi do
			caps[i] = 0
		end
	end
	for _, coral in ipairs(corals) do
		if coral.stunned or not coral.part.Parent then
			continue
		end
		local fill = coral.foodFill or C.DEFAULT_FOOD_FILL
		local bucketsByRoute = coral.routeBuckets
		if fill <= 0 or not bucketsByRoute then
			continue
		end
		local n = 0
		for route = 1, WaveSimCoralBuckets.ROUTE_COUNT do
			local buckets = bucketsByRoute[route]
			if buckets then
				n += #buckets
			end
		end
		if n < 1 then
			continue
		end
		local share = fill / n
		for route = 1, WaveSimCoralBuckets.ROUTE_COUNT do
			local caps = capFields[route]
			local buckets = bucketsByRoute[route]
			if buckets and #caps > 0 then
				for _, bi in ipairs(buckets) do
					if caps[bi] ~= nil then
						caps[bi] += share
					end
				end
			end
		end
	end
	for route = 1, WaveSimCoralBuckets.ROUTE_COUNT do
		local caps = capFields[route]
		local stock = stockFields[route]
		for i = 1, #caps do
			local cap = caps[i] or 0
			local s = stock[i] or 0
			if s > cap then
				stock[i] = cap
			elseif stock[i] == nil then
				stock[i] = 0
			end
		end
	end
end

function WaveSimCoralBuckets.clearServingStock()
	for route = 1, WaveSimCoralBuckets.ROUTE_COUNT do
		local stock = stockFields[route]
		for i = 1, #stock do
			stock[i] = 0
		end
	end
end

-- Tops each covered slice up to one waiting serving. Returns true if any food was added.
function WaveSimCoralBuckets.depositServing(coral: BucketCoral): boolean
	local fill = coral.foodFill or C.DEFAULT_FOOD_FILL
	local bucketsByRoute = coral.routeBuckets
	if fill <= 0 or coral.stunned or not bucketsByRoute then
		return false
	end
	local n = 0
	for route = 1, WaveSimCoralBuckets.ROUTE_COUNT do
		local buckets = bucketsByRoute[route]
		if buckets then
			n += #buckets
		end
	end
	if n < 1 then
		return false
	end
	local share = fill / n
	local any = false
	for route = 1, WaveSimCoralBuckets.ROUTE_COUNT do
		local buckets = bucketsByRoute[route]
		local stock = stockFields[route]
		local caps = capFields[route]
		if not buckets or #stock < 1 then
			continue
		end
		for _, bi in ipairs(buckets) do
			local cap = caps[bi]
			local cur = stock[bi]
			if cap and cur and cur < cap - 1e-4 then
				stock[bi] = math.min(cap, cur + share)
				any = true
			end
		end
	end
	return any
end

function WaveSimCoralBuckets.tickServingDeposits(corals: { BucketCoral }, now: number)
	for _, coral in ipairs(corals) do
		if coral.stunned or not coral.part.Parent then
			continue
		end
		if now < (coral.readyAt or 0) then
			continue
		end
		if WaveSimCoralBuckets.depositServing(coral) then
			coral.lanePulseReady = true
		end
		local reload = math.max(0.05, coral.reloadSec or C.DEFAULT_RELOAD)
		coral.readyAt = now + reload * (0.65 + math.random() * 0.7)
	end
end

-- One orb per deposit: the coral on this slice that just restocked.
function WaveSimCoralBuckets.takeServingCoral(routeId: number, dist: number): BucketCoral?
	local lists = sliceCoral[routeId]
	if not lists or #lists < 1 then
		return nil
	end
	local bi = math.clamp(math.floor(math.max(0, dist) / C.PATH_BUCKET_SIZE) + 1, 1, #lists)
	local list = lists[bi]
	if not list then
		return nil
	end
	for _, coral in ipairs(list) do
		if coral.lanePulseReady and not coral.stunned and coral.part.Parent then
			coral.lanePulseReady = false
			return coral
		end
	end
	return nil
end

-- Reef-report ice button shows these. Off until that toggle is on.
local debugVisible = false
local debugFolder: Folder? = nil
local debugCells: { { { part: BasePart, label: TextLabel, glow: Highlight, outline: SelectionBox } } } = {}
local DEBUG_LIFT = { 4, 7, 10, 2.5, 5.5 }
local DEBUG_COLOR = {
	Color3.fromRGB(70, 210, 255),
	Color3.fromRGB(255, 214, 70),
	Color3.fromRGB(255, 96, 96),
	Color3.fromRGB(255, 150, 64),
	Color3.fromRGB(186, 120, 255),
}
local selectedRoute = 0
local selectedBi = 0
local coralHighlights: { Highlight } = {}
local highlightAt = 0
for i = 1, WaveSimCoralBuckets.ROUTE_COUNT do
	debugCells[i] = {}
end

local function clearCoralHighlights()
	for _, h in ipairs(coralHighlights) do
		h:Destroy()
	end
	table.clear(coralHighlights)
end

local function coralHighlightAdornee(part: BasePart): Instance
	local model = part:FindFirstAncestorOfClass("Model")
	if not model or model == Workspace then
		return part
	end
	local n = 0
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			n += 1
			if n > 24 then
				return part
			end
		end
	end
	if n < 1 then
		return part
	end
	return model
end

local function applyCoralHighlights(route: number, bi: number)
	clearCoralHighlights()
	local lists = sliceCoral[route]
	local list = lists and lists[bi]
	if not list then
		return
	end
	local seen: { [Instance]: boolean } = {}
	for _, coral in ipairs(list) do
		local part = coral.part
		if part and part.Parent then
			local adorn = coralHighlightAdornee(part)
			if not seen[adorn] then
				seen[adorn] = true
				local h = Instance.new("Highlight")
				h.Name = "OceanTD_BucketCoralHighlight"
				h.Adornee = adorn
				h.FillColor = Color3.fromRGB(255, 244, 160)
				h.OutlineColor = Color3.fromRGB(255, 220, 60)
				h.FillTransparency = 0.4
				h.OutlineTransparency = 0
				h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
				h.Parent = adorn
				table.insert(coralHighlights, h)
			end
		end
	end
	highlightAt = os.clock()
end

local function clearBucketSelection()
	selectedRoute = 0
	selectedBi = 0
	clearCoralHighlights()
end

local function ensureBucketDebugFolder(): Folder
	local folder = debugFolder
	if folder and folder.Parent then
		return folder
	end
	folder = Instance.new("Folder")
	folder.Name = "OceanTD_BucketFoodDebug"
	folder.Parent = Workspace
	debugFolder = folder
	return folder
end

local function makeBucketDebugCell(route: number, folder: Folder): { part: BasePart, label: TextLabel, glow: Highlight, outline: SelectionBox }
	local part = Instance.new("Part")
	part.Name = "Bucket"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = true
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.ForceField
	part.Color = DEBUG_COLOR[route]
	part.Transparency = 0.56
	part.Size = Vector3.new(22, 22, 4)
	part.Parent = folder

	local glow = Instance.new("Highlight")
	glow.Name = "SelectGlow"
	glow.Adornee = part
	glow.FillTransparency = 1
	glow.OutlineColor = Color3.new(1, 1, 1)
	glow.OutlineTransparency = 0
	glow.FillColor = Color3.new(1, 1, 1)
	glow.Enabled = false
	glow.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	glow.Parent = part

	local outline = Instance.new("SelectionBox")
	outline.Name = "SelectOutline"
	outline.Adornee = part
	outline.Color3 = Color3.new(1, 1, 1)
	outline.LineThickness = 0.08
	outline.SurfaceTransparency = 1
	outline.Visible = false
	outline.Parent = part

	local bb = Instance.new("BillboardGui")
	bb.Name = "Food"
	bb.AlwaysOnTop = true
	bb.LightInfluence = 0
	bb.MaxDistance = 500
	bb.Size = UDim2.fromOffset(72, 26)
	bb.StudsOffset = Vector3.new(0, DEBUG_LIFT[route], 0)
	bb.Parent = part

	local label = Instance.new("TextLabel")
	label.BackgroundColor3 = DEBUG_COLOR[route]
	label.BackgroundTransparency = 0.2
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.GothamBold
	label.TextSize = 16
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextStrokeTransparency = 0.35
	label.Text = "0"
	label.Parent = bb

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 4)
	corner.Parent = label

	return { part = part, label = label, glow = glow, outline = outline }
end

function WaveSimCoralBuckets.clearBucketFoodDebug()
	clearBucketSelection()
	if debugFolder then
		debugFolder:Destroy()
		debugFolder = nil
	end
	for route = 1, WaveSimCoralBuckets.ROUTE_COUNT do
		local cells = debugCells[route]
		for _, cell in ipairs(cells) do
			if cell.part.Parent == nil then
				cell.part:Destroy()
			end
		end
		table.clear(cells)
	end
end

function WaveSimCoralBuckets.isBucketDebugVisible(): boolean
	return debugVisible
end

function WaveSimCoralBuckets.setBucketDebugVisible(on: boolean)
	if debugVisible == on then
		return
	end
	debugVisible = on
	if not on then
		WaveSimCoralBuckets.clearBucketFoodDebug()
	end
end

function WaveSimCoralBuckets.tickBucketFoodDebug(paths: RoutePaths)
	if not debugVisible then
		return
	end
	local folder = ensureBucketDebugFolder()
	local step = C.PATH_BUCKET_SIZE
	local sawSelected = false
	for route = 1, WaveSimCoralBuckets.ROUTE_COUNT do
		local path = paths[route]
		local caps = capFields[route]
		local stock = stockFields[route]
		local cells = debugCells[route]
		local shown = 0
		if path and path.totalLen >= 1 then
			for bi = 1, #caps do
				if (caps[bi] or 0) > 1e-4 then
					shown += 1
					local cell = cells[shown]
					if not cell then
						cell = makeBucketDebugCell(route, folder)
						cells[shown] = cell
					elseif cell.part.Parent ~= folder then
						cell.part.Parent = folder
					end
					local d0 = (bi - 1) * step
					local d1 = math.min(path.totalLen, bi * step)
					local p0 = Path.samplePath(path, d0)
					local p1 = Path.samplePath(path, d1)
					local delta = p1 - p0
					local len = delta.Magnitude
					if len < 0.4 then
						len = 0.4
						delta = Vector3.new(0, 0, 1)
					end
					local mid = (p0 + p1) * 0.5 + Vector3.new(0, (route - 1) * 2.2, 0)
					cell.part.Size = Vector3.new(22, 22, len)
					cell.part.CFrame = CFrame.lookAt(mid, mid + delta)
					cell.part:SetAttribute("OceanTD_BucketRoute", route)
					cell.part:SetAttribute("OceanTD_BucketIndex", bi)
					local picked = route == selectedRoute and bi == selectedBi
					if picked then
						sawSelected = true
					end
					cell.part.Transparency = if picked then 0.25 else 0.56
					cell.glow.Enabled = picked
					cell.outline.Visible = picked
					local base = DEBUG_COLOR[route]
					if picked then
						cell.label.BackgroundColor3 = Color3.new(1 - base.R, 1 - base.G, 1 - base.B)
						cell.label.TextColor3 = Color3.new(0, 0, 0)
						cell.label.TextStrokeColor3 = Color3.new(1, 1, 1)
					else
						cell.label.BackgroundColor3 = base
						cell.label.TextColor3 = Color3.new(1, 1, 1)
						cell.label.TextStrokeColor3 = Color3.new(0, 0, 0)
					end
					local food = stock[bi] or 0
					cell.label.Text = string.format("%.2f", food)
					cell.label.BackgroundTransparency = if food > 0.05 then 0.12 else 0.55
				end
			end
		end
		for i = shown + 1, #cells do
			local cell = cells[i]
			if cell.part.Parent then
				cell.part.Parent = nil
			end
		end
	end
	if selectedRoute > 0 and not sawSelected then
		clearBucketSelection()
	elseif selectedRoute > 0 and os.clock() - highlightAt > 0.4 then
		applyCoralHighlights(selectedRoute, selectedBi)
	end
end

UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
	if not debugVisible or gameProcessed then
		return
	end
	if input.UserInputType ~= Enum.UserInputType.MouseButton1
		and input.UserInputType ~= Enum.UserInputType.Touch
	then
		return
	end
	local folder = debugFolder
	local cam = Workspace.CurrentCamera
	if not folder or not folder.Parent or not cam then
		clearBucketSelection()
		return
	end
	local screen = PlaceConfirmHitTest.pointerScreenPos(input)
	local ray = cam:ViewportPointToRay(screen.X, screen.Y)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { folder }
	local hit = Workspace:Raycast(ray.Origin, ray.Direction * 4000, params)
	local part = hit and hit.Instance
	local route = part and part:GetAttribute("OceanTD_BucketRoute")
	local bi = part and part:GetAttribute("OceanTD_BucketIndex")
	if typeof(route) ~= "number" or typeof(bi) ~= "number" then
		clearBucketSelection()
		return
	end
	if route == selectedRoute and bi == selectedBi then
		clearBucketSelection()
		return
	end
	selectedRoute = route
	selectedBi = bi
	applyCoralHighlights(route, bi)
end)

function WaveSimCoralBuckets.clearHungryScratch(paths: RoutePaths)
	for route = 1, WaveSimCoralBuckets.ROUTE_COUNT do
		local scratch = hungryScratch[route]
		local path = paths[route]
		if not path or path.totalLen < 1 then
			for i = 1, #scratch do
				table.clear(scratch[i])
			end
			continue
		end
		local maxBi = math.max(1, math.ceil(path.totalLen / C.PATH_BUCKET_SIZE) + 1)
		while #scratch < maxBi do
			table.insert(scratch, {})
		end
		for i = 1, maxBi do
			table.clear(scratch[i])
		end
	end
end

function WaveSimCoralBuckets.noteHungry(routeId: number, dist: number, fish: any)
	local scratch = hungryScratch[routeId]
	if not scratch or #scratch < 1 then
		return
	end
	local bi = bucketIndex(dist, #scratch)
	local list = scratch[bi]
	if list then
		table.insert(list, fish)
	end
end

-- Lead fish first: high pathDist buckets before low.
function WaveSimCoralBuckets.eachHungryFrontFirst(fn: (any, number) -> ())
	for route = 1, WaveSimCoralBuckets.ROUTE_COUNT do
		local scratch = hungryScratch[route]
		for bi = #scratch, 1, -1 do
			local list = scratch[bi]
			if list then
				for _, fish in ipairs(list) do
					fn(fish, route)
				end
			end
		end
	end
end

--[[
	System C: each nest adds foodFill/reloadSec into every stamped bucket on each route.
]]
function WaveSimCoralBuckets.rebuildFeedFields(corals: { BucketCoral }, paths: RoutePaths)
	local step = C.PATH_BUCKET_SIZE
	for route = 1, WaveSimCoralBuckets.ROUTE_COUNT do
		local lists = sliceCoral[route]
		for i = 1, #lists do
			local list = lists[i]
			if list then
				table.clear(list)
			end
		end
	end
	for route = 1, WaveSimCoralBuckets.ROUTE_COUNT do
		local field = feedFields[route]
		table.clear(field)
		local path = paths[route]
		if not path or path.totalLen < 1 then
			continue
		end
		local maxBi = math.max(1, math.ceil(path.totalLen / step) + 1)
		for i = 1, maxBi do
			field[i] = 0
		end
		local lists = sliceCoral[route]
		while #lists < maxBi do
			table.insert(lists, {})
		end
	end
	for _, coral in ipairs(corals) do
		coral.rateShare = 0
		if coral.stunned or not coral.part.Parent then
			continue
		end
		local reload = math.max(0.05, coral.reloadSec or C.DEFAULT_RELOAD)
		local fill = coral.foodFill or C.DEFAULT_FOOD_FILL
		local rate = fill / reload
		if rate <= 0 then
			continue
		end
		local routeBuckets = coral.routeBuckets
		if not routeBuckets then
			continue
		end
		for route = 1, WaveSimCoralBuckets.ROUTE_COUNT do
			local field = feedFields[route]
			local buckets = routeBuckets[route]
			local lists = sliceCoral[route]
			if not buckets or #field < 1 then
				continue
			end
			for _, bi in ipairs(buckets) do
				if field[bi] ~= nil then
					field[bi] += rate
					local list = lists[bi]
					if list then
						table.insert(list, coral)
					end
				end
			end
		end
	end
	-- Fraction of each slice this nest owns. Alone on a stretch stays bright.
	-- Buried in a crowd, or off the path, stays dim. Faster reload raises the fraction.
	for _, coral in ipairs(corals) do
		local reload = math.max(0.05, coral.reloadSec or C.DEFAULT_RELOAD)
		local fill = coral.foodFill or C.DEFAULT_FOOD_FILL
		local rate = if fill > 0 then fill / reload else 0
		local buckets = coral.routeBuckets
		if coral.stunned or not coral.part.Parent or rate <= 0 or not buckets then
			coral.rateShare = 0
			continue
		end
		local sum = 0
		local n = 0
		for route = 1, WaveSimCoralBuckets.ROUTE_COUNT do
			local field = feedFields[route]
			local stamped = buckets[route]
			if stamped and #field > 0 then
				for _, bi in ipairs(stamped) do
					local total = field[bi]
					if typeof(total) == "number" and total > 0 then
						sum += rate / total
						n += 1
					end
				end
			end
		end
		coral.rateShare = if n > 0 then sum / n else 0
	end
end

function WaveSimCoralBuckets.clearFeedFields()
	for route = 1, WaveSimCoralBuckets.ROUTE_COUNT do
		table.clear(feedFields[route])
		table.clear(stockFields[route])
		table.clear(capFields[route])
	end
end

-- Food/sec at path distance (lerp between adjacent buckets). System C only.
function WaveSimCoralBuckets.feedRateAt(routeId: number, dist: number): number
	local field = feedFields[routeId]
	if not field or #field < 1 then
		return 0
	end
	local step = C.PATH_BUCKET_SIZE
	local u = math.max(0, dist) / step
	local i0 = math.clamp(math.floor(u) + 1, 1, #field)
	local i1 = math.min(#field, i0 + 1)
	local frac = u - math.floor(u)
	local a = field[i0] or 0
	local b = field[i1] or 0
	return a + (b - a) * frac
end

-- Legacy single-route rebuild (swim A).
function WaveSimCoralBuckets.rebuildIndex(index: { { BucketCoral } }, corals: { BucketCoral }, path: PathData?)
	if not path or path.totalLen < 1 then
		for i = 1, #index do
			table.clear(index[i])
		end
		return
	end
	WaveSimCoralBuckets.ensureIndexSize(index, path)
	for _, coral in ipairs(corals) do
		if coral.stunned or not coral.part.Parent then
			continue
		end
		local buckets = coral.pathBuckets
		if not buckets then
			continue
		end
		for _, bi in ipairs(buckets) do
			local bucket = index[bi]
			if bucket then
				table.insert(bucket, coral)
			end
		end
	end
end

-- System C helper: apply continuous field drink (WaveSim stays under 200 locals).
function WaveSimCoralBuckets.applyPathFieldDrink(
	fishList: { any },
	dt: number,
	resolveRoute: (any) -> number?,
	onGain: (any, number) -> ()
): boolean
	local any = false
	for _, f in ipairs(fishList) do
		if f.finished or f.hunger >= f.maxHunger or (typeof(f.bornAt) == "number" and os.clock() - f.bornAt < 1.5) then
			continue
		end
		local route = resolveRoute(f)
		if not route then
			continue
		end
		local rate = WaveSimCoralBuckets.feedRateAt(route, f.dist)
		if rate <= 0 then
			continue
		end
		local add = rate * dt
		local before = f.hunger
		f.hunger = math.min(f.maxHunger, f.hunger + add)
		if f.hunger > before then
			onGain(f, f.hunger - before)
			any = true
		end
	end
	return any
end

local RATE_SHOT_DT = 0.25
local RATE_SHOTS = 6
local rateShotAcc = 0
local bestFish: { any } = {}
local bestRoute: { number } = {}
local bestDist: { number } = {}

local function coralRate(coral: BucketCoral): number
	local reload = math.max(0.05, coral.reloadSec or C.DEFAULT_RELOAD)
	local fill = coral.foodFill or C.DEFAULT_FOOD_FILL
	if fill <= 0 then
		return 0
	end
	return fill / reload
end

function WaveSimCoralBuckets.pickRateCoral(routeId: number, dist: number): BucketCoral?
	local lists = sliceCoral[routeId]
	if not lists or #lists < 1 then
		return nil
	end
	local bi = math.clamp(math.floor(math.max(0, dist) / C.PATH_BUCKET_SIZE) + 1, 1, #lists)
	local list = lists[bi]
	if not list or #list < 1 then
		return nil
	end
	local total = 0
	for _, coral in ipairs(list) do
		if not coral.stunned and coral.part.Parent then
			total += coralRate(coral)
		end
	end
	if total <= 0 then
		return nil
	end
	local roll = math.random() * total
	local acc = 0
	for _, coral in ipairs(list) do
		if coral.stunned or not coral.part.Parent then
			continue
		end
		acc += coralRate(coral)
		if roll <= acc then
			return coral
		end
	end
	return list[#list]
end

-- A few shots per second from the fish furthest along, weighted by nest rate.
function WaveSimCoralBuckets.tickRateShots(
	dt: number,
	fishList: { any },
	resolveRoute: (any) -> number?,
	onShot: (BucketCoral, any) -> ()
)
	rateShotAcc += dt
	if rateShotAcc < RATE_SHOT_DT then
		return
	end
	rateShotAcc -= RATE_SHOT_DT
	local nBest = 0
	for _, f in ipairs(fishList) do
		if f.finished or f.hunger >= f.maxHunger or (typeof(f.bornAt) == "number" and os.clock() - f.bornAt < 1.5) then
			continue
		end
		local route = resolveRoute(f)
		if not route then
			continue
		end
		if WaveSimCoralBuckets.feedRateAt(route, f.dist) <= 0 then
			continue
		end
		local dist = f.dist
		if nBest < RATE_SHOTS then
			nBest += 1
			bestFish[nBest] = f
			bestRoute[nBest] = route
			bestDist[nBest] = dist
		else
			local low = 1
			for i = 2, nBest do
				if bestDist[i] < bestDist[low] then
					low = i
				end
			end
			if dist > bestDist[low] then
				bestFish[low] = f
				bestRoute[low] = route
				bestDist[low] = dist
			end
		end
	end
	for i = 1, nBest do
		local coral = WaveSimCoralBuckets.pickRateCoral(bestRoute[i], bestDist[i])
		if coral then
			onShot(coral, bestFish[i])
		end
	end
end

function WaveSimCoralBuckets.leadBucketCount(): number
	return math.max(1, math.ceil(C.PATH_TARGET_LEAD_MAX / C.PATH_BUCKET_SIZE))
end

function WaveSimCoralBuckets.pastBucketCount(): number
	return math.max(1, math.ceil(C.PATH_TARGET_PAST / C.PATH_BUCKET_SIZE))
end

local function markCoral(coral: BucketCoral, gen: number, score: number)
	if coral.combatGen ~= gen then
		coral.combatGen = gen
		coral.combatScore = score
	elseif score < coral.combatScore then
		coral.combatScore = score
	end
end

function WaveSimCoralBuckets.markAroundDist(
	index: { { BucketCoral } },
	fishDist: number,
	gen: number,
	leadBuckets: number,
	pastBuckets: number,
	routeId: number
): number
	local maxBi = #index
	if maxBi < 1 then
		return 0
	end
	local bi = math.clamp(math.floor(fishDist / C.PATH_BUCKET_SIZE) + 1, 1, maxBi)
	local lo = math.max(1, bi - leadBuckets)
	local hi = math.min(maxBi, bi + pastBuckets)
	local marked = 0
	for i = lo, hi do
		local bucket = index[i]
		if not bucket then
			continue
		end
		for _, coral in ipairs(bucket) do
			if coral.stunned or not coral.part.Parent then
				continue
			end
			local near = 0
			if coral.routeNearDist then
				near = coral.routeNearDist[routeId] or 0
			end
			local along = math.abs(near - fishDist)
			local score = along
			-- Swim-A laterals use pathSideDist; other routes only have along-axis stamps.
			if routeId == WaveSimCoralBuckets.ROUTE_A then
				local side = coral.pathSideDist
				local laneOk = side <= coral.range + C.LATERAL_SPREAD
				score = along + (if laneOk then side * 0.25 else side * 2 + 80)
			end
			local was = coral.combatGen
			markCoral(coral, gen, score)
			if was ~= gen then
				marked += 1
			end
		end
	end
	return marked
end

--[[
	Wake nests covering hungry agents on each route, then hash-assist Shark/Ground.
	Returns how many corals were newly marked this generation.
]]
function WaveSimCoralBuckets.wakeFromHungry(
	indices: { { { BucketCoral } } },
	spatial: WaveCrab.SpatialHash?,
	spatialCell: number,
	fishList: { any },
	gen: number,
	resolveRoute: (any) -> number?,
	isOffSwim: (any) -> boolean
): number
	local lead = WaveSimCoralBuckets.leadBucketCount()
	local past = WaveSimCoralBuckets.pastBucketCount()
	local marked = 0
	for _, f in ipairs(fishList) do
		if f.finished or f.hunger >= f.maxHunger then
			continue
		end
		local route = resolveRoute(f)
		if not route then
			continue
		end
		local index = indices[route]
		if not index then
			continue
		end
		marked += WaveSimCoralBuckets.markAroundDist(index, f.dist, gen, lead, past, route)
	end

	-- B: spatial hash for off-swim bodies (few agents; catches lateral wander).
	if spatial then
		local cell = spatialCell
		for _, f in ipairs(fishList) do
			if f.finished or f.hunger >= f.maxHunger or not isOffSwim(f) then
				continue
			end
			local root = f.root
			if not (root and root:IsA("BasePart")) then
				continue
			end
			local fp = root.Position
			local queryR = C.GROUND_FEED_ACTIVATE_RANGE
			WaveCrab.spatialForEachNear(spatial, cell, fp, queryR, function(item: any): boolean?
				local coral = item :: BucketCoral
				if coral.stunned or not coral.part.Parent then
					return nil
				end
				local origin = coral.part.Position
				local dx = fp.X - origin.X
				local dy = fp.Y - origin.Y
				local dz = fp.Z - origin.Z
				local d2 = dx * dx + dy * dy + dz * dz
				if d2 > coral.rangeSq then
					return nil
				end
				local was = coral.combatGen
				markCoral(coral, gen, math.sqrt(d2))
				if was ~= gen then
					marked += 1
				end
				return nil
			end)
		end
	end

	return marked
end

-- Legacy API (includeAllCorridor = A2 blanket).
function WaveSimCoralBuckets.markActiveFromFish(
	index: { { BucketCoral } },
	corals: { BucketCoral },
	fishBuckets: { { any } },
	gen: number,
	leadBuckets: number,
	pastBuckets: number,
	includeAllCorridor: boolean
): number
	local marked = 0
	if includeAllCorridor then
		for _, coral in ipairs(corals) do
			if coral.stunned or not coral.part.Parent then
				continue
			end
			if coral.pathBuckets and #coral.pathBuckets > 0 and coral.combatGen ~= gen then
				coral.combatGen = gen
				coral.combatScore = coral.pathSideDist
				marked += 1
			end
		end
		return marked
	end

	local maxBi = #index
	local occupied: { [number]: boolean } = {}
	for bi, bucket in ipairs(fishBuckets) do
		if bucket and #bucket > 0 then
			local lo = math.max(1, bi - leadBuckets)
			local hi = math.min(maxBi, bi + pastBuckets)
			for i = lo, hi do
				occupied[i] = true
			end
		end
	end
	for bi, on in pairs(occupied) do
		if not on then
			continue
		end
		local bucket = index[bi]
		if not bucket then
			continue
		end
		for _, coral in ipairs(bucket) do
			if coral.combatGen ~= gen and not coral.stunned and coral.part.Parent then
				coral.combatGen = gen
				marked += 1
			end
		end
	end
	return marked
end

return WaveSimCoralBuckets
