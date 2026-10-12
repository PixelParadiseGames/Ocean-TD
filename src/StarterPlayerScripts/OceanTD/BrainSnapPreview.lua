--!strict
--[[
	Client brain-stack snap — Option A discrete seats.
	Each host shows free seat dots on its upper sphere (1/2/3 by S/M/L).
	Aim a seat to snap; rot cycles free seats on that host.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local BrainStack = require(oceanRoot:WaitForChild("Shared"):WaitForChild("BrainStack"))

local ClientPlot = require(script.Parent:WaitForChild("ClientPlot"))
local PlacedCoralIndex = require(script.Parent:WaitForChild("PlacedCoralIndex"))

local BrainSnapPreview = {}

local COLOR_IDLE = Color3.fromRGB(255, 255, 255)
local COLOR_SNAPPED = Color3.fromRGB(80, 220, 110)
local DOT_PX = 16
local DOT_FAR_START_STUDS = 50
local DOT_SCALE_NEAR = 1
local DOT_SCALE_FAR_MIN = 0.8
local DOT_SCALE_FAR_MAX = 0.6
local HOST_CACHE_SEC = 0.12
local HOST_CACHE_MOVE_STUDS = 4

export type ActiveSnap = {
	host: BasePart,
	hostPlaceId: string?,
	offsetX: number,
	offsetZ: number,
	angle: number,
	frac: number,
	worldPos: Vector3,
	sideBranch: boolean,
	valid: boolean,
	seatIndex: number,
	seatCount: number,
}

type SeatMarker = {
	bb: BillboardGui,
	seatIndex: number,
}

local markers: { [BasePart]: { [number]: SeatMarker } } = {}
local active: ActiveSnap? = nil
local lastHost: BasePart? = nil
local lastSeatIndex: number? = nil
local visible = false
local lastActiveKey: string? = nil

local cachedHosts: { BasePart } = {}
local cacheAim = Vector3.zero
local cacheAt = -1e9
local cachePlotId: string? = nil
local cacheIgnore: BasePart? = nil

local function playerGui(): PlayerGui?
	local plr = Players.LocalPlayer
	if not plr then
		return nil
	end
	return plr:FindFirstChildOfClass("PlayerGui") :: PlayerGui?
end

local function makeMarker(): BillboardGui?
	local gui = playerGui()
	if not gui then
		return nil
	end
	local bb = Instance.new("BillboardGui")
	bb.Name = "OceanTD_BrainSeatDot"
	bb.AlwaysOnTop = true
	bb.LightInfluence = 0
	bb.Size = UDim2.fromOffset(DOT_PX, DOT_PX)
	bb.StudsOffset = Vector3.zero
	bb.MaxDistance = 400
	bb.Parent = gui
	local disc = Instance.new("Frame")
	disc.Name = "Disc"
	disc.BackgroundColor3 = COLOR_IDLE
	disc.BackgroundTransparency = 0
	disc.BorderSizePixel = 0
	disc.Size = UDim2.fromScale(1, 1)
	disc.Parent = bb
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = disc
	return bb
end

local function setMarkerColor(bb: BillboardGui, col: Color3)
	local disc = bb:FindFirstChild("Disc")
	if disc and disc:IsA("Frame") then
		disc.BackgroundColor3 = col
	end
end

local function dotScaleForDist(dist: number): number
	if dist <= DOT_FAR_START_STUDS then
		return DOT_SCALE_NEAR
	end
	local farEnd = BrainStack.SNAP_DOT_SHOW_STUDS
	local t = math.clamp((dist - DOT_FAR_START_STUDS) / math.max(1e-3, farEnd - DOT_FAR_START_STUDS), 0, 1)
	return DOT_SCALE_FAR_MIN + (DOT_SCALE_FAR_MAX - DOT_SCALE_FAR_MIN) * t
end

local function setMarkerSize(bb: BillboardGui, scale: number)
	local px = math.max(1, math.floor(DOT_PX * scale + 0.5))
	if bb.Size.X.Offset ~= px then
		bb.Size = UDim2.fromOffset(px, px)
	end
end

local function invalidateHostCache()
	table.clear(cachedHosts)
	cacheAt = -1e9
	cachePlotId = nil
	cacheIgnore = nil
end

function BrainSnapPreview.clearMarkers()
	for host, bySeat in pairs(markers) do
		for _, sm in pairs(bySeat) do
			if sm.bb.Parent then
				sm.bb:Destroy()
			end
		end
		markers[host] = nil
	end
	lastActiveKey = nil
end

function BrainSnapPreview.hide()
	visible = false
	active = nil
	lastHost = nil
	lastSeatIndex = nil
	invalidateHostCache()
	BrainSnapPreview.clearMarkers()
end

function BrainSnapPreview.getActive(): ActiveSnap?
	return active
end

function BrainSnapPreview.isSnapped(): boolean
	return active ~= nil and active.valid == true
end

local function findRootPos(host: BasePart, ignore: BasePart?): Vector3
	local plot = ClientPlot.get()
	if not plot then
		return host.Position
	end
	local root = PlacedCoralIndex.getBrainRoot(plot.plotId, host, ignore)
	return root.Position
end

local function findPartByPlaceId(plotId: string, placeId: string): BasePart?
	for _, p in ipairs(PlacedCoralIndex.getParts(plotId)) do
		if p.Parent and BrainStack.readPlaceId(p) == placeId then
			return p
		end
	end
	return nil
end

local function clampToRootDrift(world: Vector3, rootPos: Vector3): Vector3
	if BrainStack.withinRootDrift(rootPos, world) then
		return world
	end
	local dx = world.X - rootPos.X
	local dz = world.Z - rootPos.Z
	local dist = math.sqrt(dx * dx + dz * dz)
	if dist <= 1e-4 then
		return world
	end
	local scale = BrainStack.MAX_ROOT_DRIFT / dist
	return Vector3.new(rootPos.X + dx * scale, world.Y, rootPos.Z + dz * scale)
end

local function getCachedHosts(plotId: string, aimPos: Vector3, ignore: BasePart?): { BasePart }
	local now = os.clock()
	local moved = (aimPos - cacheAim).Magnitude
	local same =
		cachePlotId == plotId
		and cacheIgnore == ignore
		and (now - cacheAt) < HOST_CACHE_SEC
		and moved < HOST_CACHE_MOVE_STUDS
	if same then
		local alive = true
		for _, h in ipairs(cachedHosts) do
			if not h.Parent then
				alive = false
				break
			end
		end
		if alive then
			return cachedHosts
		end
	end
	cachedHosts = PlacedCoralIndex.getBrainHostsWithFreeSlotsNear(
		plotId,
		aimPos,
		BrainStack.SNAP_DOT_SHOW_STUDS,
		ignore
	)
	cacheAim = aimPos
	cacheAt = now
	cachePlotId = plotId
	cacheIgnore = ignore
	return cachedHosts
end

local function hostSeatInfo(host: BasePart, newDiam: number): (number, number, number)
	local seatCount = BrainStack.seatCountForPart(host)
	local baseYaw = BrainStack.seatBaseYaw(BrainStack.readPlaceId(host))
	local hostDiam = BrainStack.diameterOfPart(host)
	return seatCount, baseYaw, hostDiam
end

-- Seats already claimed by existing children (greedy nearest). ignore's seat stays free.
local function occupiedSeats(
	plotId: string,
	host: BasePart,
	newDiam: number,
	ignore: BasePart?
): { [number]: boolean }
	local seatCount, baseYaw, hostDiam = hostSeatInfo(host, newDiam)
	local taken: { [number]: boolean } = {}
	local kids = PlacedCoralIndex.getBrainChildren(plotId, host, ignore)
	-- Farthest-from-host first so inner kids don't steal outer seats incorrectly — use nearest greedy in order of placement.
	table.sort(kids, function(a, b)
		return (a.Position - host.Position).Magnitude < (b.Position - host.Position).Magnitude
	end)
	for _, kid in ipairs(kids) do
		local idx = BrainStack.nearestSeatIndex(host.Position, hostDiam, newDiam, seatCount, baseYaw, kid.Position)
		-- If already taken, find next free (shouldn't happen often).
		if taken[idx] then
			for i = 1, seatCount do
				local j = ((idx + i - 2) % seatCount) + 1
				if not taken[j] then
					idx = j
					break
				end
			end
		end
		taken[idx] = true
	end
	return taken
end

local function freeSeatList(
	plotId: string,
	host: BasePart,
	newDiam: number,
	ignore: BasePart?
): { number }
	local seatCount = BrainStack.seatCountForPart(host)
	local taken = occupiedSeats(plotId, host, newDiam, ignore)
	local free: { number } = {}
	for i = 1, seatCount do
		if not taken[i] then
			table.insert(free, i)
		end
	end
	return free
end

local function applySeat(
	host: BasePart,
	newDiam: number,
	seatIndex: number,
	ignore: BasePart?
): ActiveSnap?
	local seatCount, baseYaw, hostDiam = hostSeatInfo(host, newDiam)
	local world, angle, frac = BrainStack.seatWorldPos(host.Position, hostDiam, newDiam, seatIndex, seatCount, baseYaw)
	world = clampToRootDrift(world, findRootPos(host, ignore))
	local ox = world.X - host.Position.X
	local oz = world.Z - host.Position.Z
	return {
		host = host,
		hostPlaceId = BrainStack.readPlaceId(host),
		offsetX = ox,
		offsetZ = oz,
		angle = angle,
		frac = frac,
		worldPos = world,
		sideBranch = false,
		valid = true,
		seatIndex = ((math.floor(seatIndex) - 1) % math.max(1, seatCount)) + 1,
		seatCount = seatCount,
	}
end

local function pointerHitsSeat(screenPos: Vector2?, aimPos: Vector3, seatWorld: Vector3): boolean
	return BrainStack.pointerHitsDot(screenPos, aimPos, seatWorld)
end

local function pointerHitsSeatRelaxed(screenPos: Vector2?, aimPos: Vector3, seatWorld: Vector3): boolean
	local hitPx = BrainStack.SNAP_DOT_HIT_PX * 1.75
	local hitStuds = BrainStack.SNAP_DOT_HIT_STUDS * 2.0
	local cam = Workspace.CurrentCamera
	if screenPos and cam then
		local sp, onScreen = cam:WorldToViewportPoint(seatWorld)
		if onScreen and sp.Z > 0 then
			local px = (Vector2.new(sp.X, sp.Y) - screenPos).Magnitude
			if px <= hitPx then
				return true
			end
		end
	end
	return BrainStack.horizontalDist(aimPos, seatWorld) <= hitStuds
		or (aimPos - seatWorld).Magnitude <= hitStuds * 1.15
end

local function seatScore(screenPos: Vector2?, aimPos: Vector3, seatWorld: Vector3): number
	local cam = Workspace.CurrentCamera
	if screenPos and cam then
		local sp, onScreen = cam:WorldToViewportPoint(seatWorld)
		if onScreen and sp.Z > 0 then
			return (Vector2.new(sp.X, sp.Y) - screenPos).Magnitude
		end
	end
	return (aimPos - seatWorld).Magnitude
end

local function syncSeatMarkers(
	plotId: string,
	hosts: { BasePart },
	newDiam: number,
	aimPos: Vector3,
	ignore: BasePart?,
	activeHost: BasePart?,
	activeSeat: number?
)
	if not visible then
		return
	end
	local keepHosts: { [BasePart]: boolean } = {}
	local activeKey = if activeHost and activeSeat then `{BrainStack.readPlaceId(activeHost) or ""}:{activeSeat}` else nil

	for _, host in ipairs(hosts) do
		keepHosts[host] = true
		local seatCount, baseYaw, hostDiam = hostSeatInfo(host, newDiam)
		local free = freeSeatList(plotId, host, newDiam, ignore)
		local freeSet: { [number]: boolean } = {}
		for _, idx in ipairs(free) do
			freeSet[idx] = true
		end
		local bySeat = markers[host]
		if not bySeat then
			bySeat = {}
			markers[host] = bySeat
		end
		local keepSeats: { [number]: boolean } = {}
		for i = 1, seatCount do
			if freeSet[i] then
				keepSeats[i] = true
				local world = BrainStack.seatWorldPos(host.Position, hostDiam, newDiam, i, seatCount, baseYaw)
				local sm = bySeat[i]
				if not sm or not sm.bb.Parent then
					local bb = makeMarker()
					if bb then
						sm = { bb = bb, seatIndex = i }
						bySeat[i] = sm
					end
				end
				if sm then
					sm.bb.Adornee = host
					sm.bb.StudsOffset = host.CFrame:PointToObjectSpace(world)
					if not activeHost then
						setMarkerSize(sm.bb, dotScaleForDist((world - aimPos).Magnitude))
					end
					local isActive = activeHost == host and activeSeat == i
					setMarkerColor(sm.bb, if isActive then COLOR_SNAPPED else COLOR_IDLE)
				end
			end
		end
		for idx, sm in pairs(bySeat) do
			if not keepSeats[idx] then
				if sm.bb.Parent then
					sm.bb:Destroy()
				end
				bySeat[idx] = nil
			end
		end
	end

	for host, bySeat in pairs(markers) do
		if not keepHosts[host] then
			for _, sm in pairs(bySeat) do
				if sm.bb.Parent then
					sm.bb:Destroy()
				end
			end
			markers[host] = nil
		end
	end
	lastActiveKey = activeKey
end

local function bindChildToSeat(host: BasePart, child: BasePart, parentId: string, newDiam: number?): boolean
	local plot = ClientPlot.get()
	if not plot then
		return false
	end
	local diam = if typeof(newDiam) == "number" then newDiam else BrainStack.diameterOfPart(child)
	local seatCount, baseYaw, hostDiam = hostSeatInfo(host, diam)
	local free = freeSeatList(plot.plotId, host, diam, child)
	local prefer = BrainStack.nearestSeatIndex(host.Position, hostDiam, diam, seatCount, baseYaw, child.Position)
	local seatIndex = prefer
	local freeSet: { [number]: boolean } = {}
	for _, idx in ipairs(free) do
		freeSet[idx] = true
	end
	-- Child keeps its nearest seat even if occupancy map marks it taken (it is the occupant).
	if not freeSet[prefer] then
		table.insert(free, prefer)
		table.sort(free)
		freeSet[prefer] = true
	end
	if not freeSet[seatIndex] and #free > 0 then
		seatIndex = free[1]
	end
	local snap = applySeat(host, diam, seatIndex, child)
	if not snap then
		return false
	end
	snap.hostPlaceId = parentId
	active = snap
	lastHost = host
	lastSeatIndex = seatIndex
	return true
end

-- Adopt seat snap for a parented child — rot cycles free seats.
function BrainSnapPreview.ensureOrbitForChild(child: BasePart): boolean
	if not child.Parent or not BrainStack.isBrainId(child:GetAttribute("OceanTD_SpeciesId")) then
		return false
	end
	local parentId = BrainStack.readParentPlaceId(child)
	if not parentId then
		return BrainSnapPreview.isSnapped()
	end
	local plot = ClientPlot.get()
	if not plot then
		return false
	end
	if active and active.valid and active.host.Parent and BrainStack.readPlaceId(active.host) == parentId then
		if typeof(active.seatIndex) == "number" then
			return true
		end
	end
	local host = findPartByPlaceId(plot.plotId, parentId)
	if not host or not host.Parent then
		return false
	end
	return bindChildToSeat(host, child, parentId, nil)
end

function BrainSnapPreview.nudgeOrbit(dir: number, newDiam: number, ignore: BasePart?): boolean
	if ignore then
		BrainSnapPreview.ensureOrbitForChild(ignore)
	end
	if not active or not active.valid then
		return false
	end
	local host = active.host
	if not host.Parent then
		return false
	end
	local plot = ClientPlot.get()
	if not plot then
		return false
	end
	-- First rot on a parented child: seat onto the nearest slot if still offset, then later presses cycle.
	if ignore and (ignore.Position - active.worldPos).Magnitude > 0.4 then
		local snap = applySeat(host, newDiam, active.seatIndex, ignore)
		if snap then
			active = snap
			lastHost = host
			lastSeatIndex = active.seatIndex
			return true
		end
	end
	local free = freeSeatList(plot.plotId, host, newDiam, ignore)
	if ignore then
		local has = false
		for _, idx in ipairs(free) do
			if idx == active.seatIndex then
				has = true
				break
			end
		end
		if not has then
			table.insert(free, active.seatIndex)
			table.sort(free)
		end
	end
	if #free == 0 then
		return false
	end
	local cur = 1
	for i, idx in ipairs(free) do
		if idx == active.seatIndex then
			cur = i
			break
		end
	end
	local nextI = ((cur - 1 + (if dir >= 0 then 1 else -1)) % #free) + 1
	local seatIndex = free[nextI]
	local snap = applySeat(host, newDiam, seatIndex, ignore)
	if not snap then
		return false
	end
	active = snap
	lastHost = host
	lastSeatIndex = seatIndex
	return true
end

function BrainSnapPreview.resolve(
	aimPos: Vector3,
	newDiam: number,
	ignore: BasePart?,
	screenPos: Vector2?
): (Vector3, ActiveSnap?)
	local plot = ClientPlot.get()
	if not plot then
		active = nil
		return aimPos, nil
	end

	local hosts = getCachedHosts(plot.plotId, aimPos, ignore)

	local bestHost: BasePart? = nil
	local bestSeat: number? = nil
	local bestScore = math.huge

	for _, host in ipairs(hosts) do
		local seatCount, baseYaw, hostDiam = hostSeatInfo(host, newDiam)
		local free = freeSeatList(plot.plotId, host, newDiam, ignore)
		for _, seatIndex in ipairs(free) do
			local seatWorld = BrainStack.seatWorldPos(host.Position, hostDiam, newDiam, seatIndex, seatCount, baseYaw)
			if pointerHitsSeat(screenPos, aimPos, seatWorld) then
				local score = seatScore(screenPos, aimPos, seatWorld)
				if score < bestScore then
					bestScore = score
					bestHost = host
					bestSeat = seatIndex
				end
			end
		end
	end

	-- Sticky: stay on current seat until aim clearly leaves it.
	if not bestHost and active and active.valid and active.host.Parent then
		local seatCount, baseYaw, hostDiam = hostSeatInfo(active.host, newDiam)
		local seatWorld = BrainStack.seatWorldPos(
			active.host.Position,
			hostDiam,
			newDiam,
			active.seatIndex,
			seatCount,
			baseYaw
		)
		if pointerHitsSeatRelaxed(screenPos, aimPos, seatWorld) then
			-- Seat still free (or owned by ignore)?
			local free = freeSeatList(plot.plotId, active.host, newDiam, ignore)
			local ok = false
			for _, idx in ipairs(free) do
				if idx == active.seatIndex then
					ok = true
					break
				end
			end
			if ok then
				bestHost = active.host
				bestSeat = active.seatIndex
			end
		end
	end

	syncSeatMarkers(plot.plotId, hosts, newDiam, aimPos, ignore, bestHost, bestSeat)

	if not bestHost or not bestSeat then
		if active then
			lastHost = active.host
			lastSeatIndex = active.seatIndex
		end
		active = nil
		return aimPos, nil
	end

	local snap = applySeat(bestHost, newDiam, bestSeat, ignore)
	if not snap then
		active = nil
		return aimPos, nil
	end
	active = snap
	lastHost = bestHost
	lastSeatIndex = bestSeat
	return active.worldPos, active
end

function BrainSnapPreview.setVisible(on: boolean)
	visible = on
	if not on then
		BrainSnapPreview.hide()
	end
end

function BrainSnapPreview.breakSnap()
	if active then
		lastHost = active.host
		lastSeatIndex = active.seatIndex
	end
	active = nil
	lastActiveKey = nil
end

return BrainSnapPreview
