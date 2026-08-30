--!strict
--[[
	Client brain-stack snap: center dots on hosts with free slots.
	Snap when finger/cursor hits a dot; nest on a Y-fixed horizontal orbit facing approach.
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
-- Beyond this distance from aim, dots shrink (20% at FAR_START → 40% at show range).
local DOT_FAR_START_STUDS = 50
local DOT_SCALE_NEAR = 1
local DOT_SCALE_FAR_MIN = 0.8 -- 20% smaller at 50 studs
local DOT_SCALE_FAR_MAX = 0.6 -- 40% smaller at SNAP_DOT_SHOW_STUDS
-- Refresh free-slot host list at most this often (drag was calling O(n²) work every frame).
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
}

local markers: { [BasePart]: BillboardGui } = {}
local active: ActiveSnap? = nil
local lastHost: BasePart? = nil
local lastAngle: number? = nil
local visible = false
local lastMarkerActiveHost: BasePart? = nil

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

local function makeMarker(host: BasePart): BillboardGui?
	local gui = playerGui()
	if not gui then
		return nil
	end
	local bb = Instance.new("BillboardGui")
	bb.Name = "OceanTD_BrainSnapDot"
	bb.AlwaysOnTop = true
	bb.LightInfluence = 0
	bb.Size = UDim2.fromOffset(DOT_PX, DOT_PX)
	bb.StudsOffset = Vector3.zero
	bb.MaxDistance = 400
	bb.Adornee = host
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

local function dotWorldPos(host: BasePart): Vector3
	return host.Position
end

local function invalidateHostCache()
	table.clear(cachedHosts)
	cacheAt = -1e9
	cachePlotId = nil
	cacheIgnore = nil
end

function BrainSnapPreview.clearMarkers()
	for host, m in pairs(markers) do
		if m.Parent then
			m:Destroy()
		end
		markers[host] = nil
	end
	lastMarkerActiveHost = nil
end

function BrainSnapPreview.hide()
	visible = false
	active = nil
	lastHost = nil
	lastAngle = nil
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

local function hostWantsSideBranch(plotId: string, host: BasePart): boolean
	return PlacedCoralIndex.brainHasChild(plotId, host)
end

local function computeSnapWorld(
	host: BasePart,
	hostDiam: number,
	newDiam: number,
	angle: number,
	frac: number,
	sideBranch: boolean
): (Vector3, number, number)
	if sideBranch then
		local world = BrainStack.sideBranchCenter(host.Position, hostDiam, newDiam, angle, frac)
		return world, world.X - host.Position.X, world.Z - host.Position.Z
	end
	local world = BrainStack.orbitNestCenter(host.Position, hostDiam, newDiam, angle, frac)
	return world, world.X - host.Position.X, world.Z - host.Position.Z
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
	if same and #cachedHosts >= 0 then
		-- Drop destroyed hosts without a full rebuild.
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

local function syncMarkers(hosts: { BasePart }, activeHost: BasePart?, aimPos: Vector3)
	if not visible then
		return
	end
	local keep: { [BasePart]: boolean } = {}
	for _, host in ipairs(hosts) do
		keep[host] = true
		local m = markers[host]
		if not m or not m.Parent or m.Adornee ~= host then
			if m and m.Parent then
				m:Destroy()
			end
			m = makeMarker(host)
			if m then
				markers[host] = m
			end
		end
		if m then
			local dist = (host.Position - aimPos).Magnitude
			setMarkerSize(m, dotScaleForDist(dist))
		end
	end
	for host, m in pairs(markers) do
		if not keep[host] then
			if m.Parent then
				m:Destroy()
			end
			markers[host] = nil
		end
	end
	-- Recolor only when the snapped host changes (was every frame before).
	if activeHost ~= lastMarkerActiveHost then
		for host, m in pairs(markers) do
			setMarkerColor(m, if host == activeHost then COLOR_SNAPPED else COLOR_IDLE)
		end
		lastMarkerActiveHost = activeHost
	end
end

function BrainSnapPreview.nudgeOrbit(dir: number, newDiam: number, ignore: BasePart?): boolean
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
	local d0 = BrainStack.diameterOfPart(host)
	local sideBranch = hostWantsSideBranch(plot.plotId, host)
	active.angle += dir * BrainStack.ORBIT_ROT_STEP
	local world, ox, oz = computeSnapWorld(host, d0, newDiam, active.angle, active.frac, sideBranch)
	local rootPos = findRootPos(host, ignore)
	world = clampToRootDrift(world, rootPos)
	ox = world.X - host.Position.X
	oz = world.Z - host.Position.Z
	active.worldPos = world
	active.offsetX = ox
	active.offsetZ = oz
	active.sideBranch = sideBranch
	lastHost = host
	lastAngle = active.angle
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

	local best: BasePart? = nil
	local bestScore = math.huge
	for _, host in ipairs(hosts) do
		local tip = dotWorldPos(host)
		if BrainStack.pointerHitsDot(screenPos, aimPos, tip) then
			local score: number
			if screenPos then
				local cam = Workspace.CurrentCamera
				local sp, onScreen = if cam then cam:WorldToViewportPoint(tip) else Vector3.zero, false
				if onScreen and sp.Z > 0 then
					score = (Vector2.new(sp.X, sp.Y) - screenPos).Magnitude
				else
					score = (aimPos - tip).Magnitude
				end
			else
				score = (aimPos - tip).Magnitude
			end
			if score < bestScore then
				bestScore = score
				best = host
			end
		end
	end

	syncMarkers(hosts, if best then best else nil, aimPos)

	if not best then
		if active then
			lastHost = active.host
			lastAngle = active.angle
		end
		active = nil
		return aimPos, nil
	end

	local d0 = BrainStack.diameterOfPart(best)
	-- Don't recount children every frame while staying on the same host.
	local sideBranch = if active and active.host == best
		then active.sideBranch
		else hostWantsSideBranch(plot.plotId, best)
	local needNew = active == nil or active.host ~= best or active.sideBranch ~= sideBranch
	if needNew then
		local hostR = d0 * 0.5
		local dx = aimPos.X - best.Position.X
		local dz = aimPos.Z - best.Position.Z
		local aimHoriz = math.sqrt(dx * dx + dz * dz)
		local picked = BrainStack.pickSnapOffset(d0, lastAngle)
		local angle: number
		local frac: number
		-- Aim clearly off-center → lean that way; on-dot → random overhang (not a snowman).
		if aimHoriz > hostR * 0.35 then
			angle = BrainStack.approachAngle(aimPos, best.Position)
			if lastHost == best and typeof(lastAngle) == "number" then
				local delta = math.abs(angle - lastAngle)
				delta = math.min(delta, math.pi * 2 - delta)
				if delta < BrainStack.MIN_REROLL_ANGLE then
					angle = lastAngle + BrainStack.MIN_REROLL_ANGLE
				end
			end
			frac = BrainStack.OFFSET_MIN_FRAC
				+ (BrainStack.OFFSET_MAX_FRAC - BrainStack.OFFSET_MIN_FRAC) * 0.75
		else
			angle = picked.angle
			frac = picked.frac
		end
		-- Nesting on a tip that is already stacked: push outward so towers lean.
		if not sideBranch and BrainStack.readParentPlaceId(best) then
			frac = math.max(frac, BrainStack.OFFSET_MIN_FRAC * 0.35 + BrainStack.OFFSET_MAX_FRAC * 0.65)
		end
		local world, ox, oz = computeSnapWorld(best, d0, newDiam, angle, frac, sideBranch)
		local rootPos = findRootPos(best, ignore)
		world = clampToRootDrift(world, rootPos)
		ox = world.X - best.Position.X
		oz = world.Z - best.Position.Z
		active = {
			host = best,
			hostPlaceId = BrainStack.readPlaceId(best),
			offsetX = ox,
			offsetZ = oz,
			angle = angle,
			frac = frac,
			worldPos = world,
			sideBranch = sideBranch,
			valid = true,
		}
		lastHost = best
		lastAngle = angle
	elseif active then
		local world, ox, oz = computeSnapWorld(best, d0, newDiam, active.angle, active.frac, sideBranch)
		local rootPos = findRootPos(best, ignore)
		world = clampToRootDrift(world, rootPos)
		ox = world.X - best.Position.X
		oz = world.Z - best.Position.Z
		active.worldPos = world
		active.offsetX = ox
		active.offsetZ = oz
		active.sideBranch = sideBranch
		active.valid = true
	end

	if not active then
		return aimPos, nil
	end
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
		lastAngle = active.angle
	end
	active = nil
	lastMarkerActiveHost = nil
end

return BrainSnapPreview
