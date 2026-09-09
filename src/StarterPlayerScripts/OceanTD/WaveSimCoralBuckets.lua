--!strict
--[[
	Coral path coverage for WaveSim feeding.

	FEED_MODE:
	  lane_stock  — Option 2: capped food stock per path bucket; corals restock on
	                reload; fish drink front-first (contested). Nest ammo stays parked;
	                WaveSim fires uncapped visual-only orbs when restock feeds a fish.
	  volleys     — Option 1: stamp wake + discrete fireShot / sparse orbs.
	  path_fields — System C: continuous food/sec fields (autofill; A/B only).
]]

local Path = require(script.Parent:WaitForChild("WaveSimPath"))
local C = require(script.Parent:WaitForChild("WaveSimConsts"))
local WaveCrab = require(script.Parent:WaitForChild("WaveCrab"))

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
}

export type RoutePaths = {
	[number]: PathData?,
}

-- System C continuous rates.
local feedFields: { { number } } = {}
-- Option 2 contested stock + capacity.
local stockFields: { { number } } = {}
local capFields: { { number } } = {}
-- Scratch: hungry fish listed per route bucket (front-first drink).
local hungryScratch: { { { any } } } = {}

for i = 1, WaveSimCoralBuckets.ROUTE_COUNT do
	feedFields[i] = {}
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
	if have <= 0 then
		return 0
	end
	local take = math.min(want, have)
	stock[bi] = have - take
	return take
end

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
	end
	for _, coral in ipairs(corals) do
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
			if not buckets or #field < 1 then
				continue
			end
			for _, bi in ipairs(buckets) do
				if field[bi] ~= nil then
					field[bi] += rate
				end
			end
		end
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
		if f.finished or f.hunger >= f.maxHunger then
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
