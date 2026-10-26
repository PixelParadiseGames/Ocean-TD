--!strict
--[[
	Local-only common-area coral. After join intro, plant one visual per frame
	on a jittered 4-stud grid ahead of the player (not on any plot).
	Forward range is 20–400 studs while the follow camera is on. Once that band
	cannot take another coral, planting also fills behind the player out to 200 studs.
	Plot Cam instead rings the live plot: 50–150 studs outside the current edge,
	then 100-stud steps outward until the pool is full, then it pauses.
	Growing the plot removes common corals that fall inside the new footprint.
	Gap is 5.6 studs, 2.8 on terrain Limestone. Terrain painted Rock is skipped.

	Pool cap 2000. Farthest / outside-radius corals return to the pool.
	No seeds, no save, no replication. Pauses for backpack, skills, waves,
	placement/relocate, and any camera that isn't follow-cam.
	If FPS stays under 24, a once-per-second check recycles corals and skips planting.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local Remotes = require(oceanRoot:WaitForChild("Remotes"))
local GridMath = require(oceanRoot:WaitForChild("Shared"):WaitForChild("GridMath"))
local ItemCatalog = require(oceanRoot:WaitForChild("Shared"):WaitForChild("ItemCatalog"))
local CoralVisual = require(oceanRoot:WaitForChild("Shared"):WaitForChild("CoralVisual"))
local PlotOutlineColors = require(oceanRoot:WaitForChild("Shared"):WaitForChild("PlotOutlineColors"))
local HueRarity = require(oceanRoot:WaitForChild("Shared"):WaitForChild("HueRarity"))

local ClientPlot = require(script.Parent:WaitForChild("ClientPlot"))
local InventoryState = require(script.Parent:WaitForChild("InventoryState"))
local PlacementController = require(script.Parent:WaitForChild("PlacementController"))
local RelocateController = require(script.Parent:WaitForChild("RelocateController"))
local WaveSim = require(script.Parent:WaitForChild("WaveSim"))
local JoinIntroGate = require(script.Parent:WaitForChild("JoinIntroGate"))
local HandOrb = require(script.Parent:WaitForChild("HandOrb"))

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local DIST_MIN = 20
local DIST_MAX = 400
local BEHIND_MAX = 200
local BEHIND_MIN = 12
local RECT_HALF_WIDTH = 70
-- Keep corals inside the forward band (400 ahead, 70 to the side).
local RADIUS = 420
-- 30% tighter than the old 8-stud gap. Limestone packs at half of that so reefs fill in.
local MIN_SEP = 5.6
local LIMESTONE_SEP = 2.8
local POOL_MAX = 2000
local CELL = GridMath.CELL_SIZE
local JITTER = 1.25
local RAY_UP = 20
local RAY_LENGTH = 70
local FLOOR_ABOVE = 12
local FLOOR_BELOW = 32
local MIN_NORMAL_Y = 0.4
local FPS_MIN = 24
local FPS_RECYCLE_BATCH = 24
local OUTSIDE_RECYCLE_BATCH = 4
local RISE_SEC = TweenInfo.new(1.7, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local PLOT_RISE_SEC = TweenInfo.new(5.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
-- Plot Cam ring, measured from the current plot edge (not the center).
local PLOT_EDGE_MIN = 50
local PLOT_BAND = 100
local PLOT_MISS_EXPAND = 12

type PlotBounds = { cframe: CFrame, size: Vector3 }
type Plant = { part: BasePart, pos: Vector3, key: string, index: number }

local rng = Random.new()
local plants: { Plant } = {}
local byKey: { [string]: Plant } = {}
local plotBounds: { PlotBounds } = {}
local speciesIds: { string } = {}
local frameCount = 0
local fpsWindowStart = os.clock()
local lastFps = 60
local commonOrbArmed = false
local plotOuter = PLOT_EDGE_MIN + PLOT_BAND
local plotMisses = 0
local seenPlotSpan = 0
local growthEnabled = true

local folder = Instance.new("Folder")
folder.Name = "OceanTD_CommonGrow"
folder.Parent = Workspace

for _, def in ipairs(ItemCatalog.all()) do
	if typeof(def.speciesId) == "string" and def.speciesId ~= "" then
		table.insert(speciesIds, def.speciesId)
	end
end

-- One increment per frame. Read only from the 1s planter loop.
RunService.Heartbeat:Connect(function()
	frameCount += 1
end)

local function xzKey(gx: number, gz: number): string
	return string.format("%d,%d", gx, gz)
end

local function tooClose(x: number, z: number, minSep: number): boolean
	local minSq = minSep * minSep
	for _, plant in ipairs(plants) do
		local dx = plant.pos.X - x
		local dz = plant.pos.Z - z
		if dx * dx + dz * dz < minSq then
			return true
		end
	end
	return false
end

local function jitteredXZ(gx: number, gz: number): (number, number)
	local seed = math.abs(gx * 73856093 + gz * 19349663) % 2147483646
	local jr = Random.new(seed + 1)
	local x = gx * CELL + jr:NextNumber(-JITTER, JITTER)
	local z = gz * CELL + jr:NextNumber(-JITTER, JITTER)
	return x, z
end

local function rememberRoster(payload: any)
	if typeof(payload) ~= "table" then
		return
	end
	table.clear(plotBounds)
	for _, entry in ipairs(payload) do
		if typeof(entry) == "table" and typeof(entry.cframe) == "CFrame" and typeof(entry.size) == "Vector3" then
			table.insert(plotBounds, { cframe = entry.cframe, size = entry.size })
		end
	end
end

local function insideAnyPlot(worldPos: Vector3): boolean
	local own = ClientPlot.get()
	if own and GridMath.isInsidePlotXZ(worldPos, own.cframe, own.size) then
		return true
	end
	for _, bounds in ipairs(plotBounds) do
		if GridMath.isInsidePlotXZ(worldPos, bounds.cframe, bounds.size) then
			return true
		end
	end
	return false
end

local function stripVisual(part: BasePart)
	-- Root stays anchored. Welded children stay unanchored so the rise tween pulls them along.
	-- Collision stays off until the coral has cleared the ground.
	local function quiet(p: BasePart, isRoot: boolean)
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
		p.Massless = true
		if isRoot then
			p.Anchored = true
		end
	end
	quiet(part, true)
	for _, d in ipairs(part:GetDescendants()) do
		if d:IsA("BasePart") then
			quiet(d, false)
		end
	end
	part:SetAttribute("OceanTD_CommonGrow", true)
end

local function enableCollision(part: BasePart)
	local function solid(p: BasePart)
		p.CanCollide = true
		p.CanQuery = true
	end
	solid(part)
	for _, d in ipairs(part:GetDescendants()) do
		if d:IsA("BasePart") then
			solid(d)
		end
	end
end

local function destroyPlant(plant: Plant)
	byKey[plant.key] = nil
	local last = plants[#plants]
	local index = plant.index
	plants[index] = last
	plants[#plants] = nil
	if last and last ~= plant then
		last.index = index
	end
	if plant.part.Parent then
		plant.part:Destroy()
	end
end

local function recycleFarthest(origin: Vector3, count: number, outsideOnly: boolean)
	for _ = 1, count do
		if #plants == 0 then
			return
		end
		local best: Plant? = nil
		local bestD = -1
		for _, plant in ipairs(plants) do
			local d = (plant.pos - origin).Magnitude
			if outsideOnly and d <= RADIUS then
				continue
			end
			if d > bestD then
				bestD = d
				best = plant
			end
		end
		if not best then
			return
		end
		destroyPlant(best)
	end
end

local function facingFlat(): Vector3?
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if hum then
		local move = hum.MoveDirection
		local flat = Vector3.new(move.X, 0, move.Z)
		if flat.Magnitude > 0.2 then
			return flat.Unit
		end
	end
	local hrp = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if hrp then
		local look = hrp.CFrame.LookVector
		local flat = Vector3.new(look.X, 0, look.Z)
		if flat.Magnitude > 0.2 then
			return flat.Unit
		end
	end
	local cam = Workspace.CurrentCamera
	if cam then
		local look = cam.CFrame.LookVector
		local flat = Vector3.new(look.X, 0, look.Z)
		if flat.Magnitude > 0.2 then
			return flat.Unit
		end
	end
	return nil
end

local function commonPaused(): boolean
	if JoinIntroGate.isBusy() then
		return true
	end
	if playerGui:GetAttribute("OceanTD_SkillsBubblesOpen") == true then
		return true
	end
	if WaveSim.isRunning() then
		return true
	end
	-- Backpack / build, plus place and relocate.
	if InventoryState.isOpen() or InventoryState.isBuildModalBlocking() then
		return true
	end
	if PlacementController.isActive() or RelocateController.isActive() then
		return true
	end
	return false
end

local function isPlotView(): boolean
	return playerGui:GetAttribute("OceanTD_CamCycleMode") == "plotcam"
end

local function canPlant(): boolean
	if commonPaused() then
		return false
	end
	local camMode = playerGui:GetAttribute("OceanTD_CamCycleMode")
	if camMode ~= nil and camMode ~= "off" and camMode ~= "" then
		return false
	end
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not hum or hum.Health <= 0 then
		return false
	end
	return true
end

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = true
rayParams.RespectCanCollide = false

local function rayFilter(): { Instance }
	local list: { Instance } = { folder }
	local char = player.Character
	if char then
		table.insert(list, char)
	end
	local placed = Workspace:FindFirstChild("OceanTD_Placed")
	if placed then
		table.insert(list, placed)
	end
	return list
end

local function isCameraVolume(inst: Instance): boolean
	local name = string.lower(inst.Name)
	return name == "skycam" or name == "skycamfocus" or string.find(name, "skycam", 1, true) ~= nil
end

-- Start 20 studs up and step through ceilings until the floor under this XZ.
-- Terrain painted Rock is never a plant spot. The material is returned so
-- Limestone can use the tighter gap.
local function floorAt(x: number, z: number, playerY: number): (Vector3?, Enum.Material?)
	rayParams.FilterDescendantsInstances = rayFilter()
	local y = playerY + RAY_UP
	local remaining = RAY_LENGTH
	for _ = 1, 8 do
		if remaining < 1 then
			return nil, nil
		end
		local hit = Workspace:Raycast(Vector3.new(x, y, z), Vector3.new(0, -remaining, 0), rayParams)
		if not hit then
			return nil, nil
		end
		local inst = hit.Instance
		local skip = inst:IsA("BasePart") and isCameraVolume(inst)
		local dy = hit.Position.Y - playerY
		if not skip and hit.Normal.Y >= MIN_NORMAL_Y and dy <= FLOOR_ABOVE and dy >= -FLOOR_BELOW then
			if inst == Workspace.Terrain and hit.Material == Enum.Material.Rock then
				return nil, nil
			end
			if not insideAnyPlot(hit.Position) then
				return hit.Position, if inst == Workspace.Terrain then hit.Material else nil
			end
		end
		local step = math.max(0.4, y - hit.Position.Y)
		y = hit.Position.Y - 0.4
		remaining -= step
	end
	return nil, nil
end

local function claimFloor(x: number, z: number, surfaceY: number, key: string): (Vector3?, string?)
	if insideAnyPlot(Vector3.new(x, surfaceY, z)) or tooClose(x, z, LIMESTONE_SEP) then
		return nil, nil
	end
	local hitPos, floorMat = floorAt(x, z, surfaceY)
	local gap = if floorMat == Enum.Material.Limestone then LIMESTONE_SEP else MIN_SEP
	if not hitPos or insideAnyPlot(hitPos) or tooClose(hitPos.X, hitPos.Z, gap) then
		return nil, nil
	end
	return hitPos, key
end

local function sampleBand(
	playerPos: Vector3,
	flat: Vector3,
	forwardMin: number,
	forwardMax: number,
	tries: number
): (Vector3?, string?)
	local right = Vector3.new(-flat.Z, 0, flat.X)
	for _ = 1, tries do
		local forward = rng:NextNumber(forwardMin, forwardMax)
		local side = rng:NextNumber(-RECT_HALF_WIDTH, RECT_HALF_WIDTH)
		local world = playerPos + flat * forward + right * side
		if insideAnyPlot(world) then
			continue
		end
		local gx = math.round(world.X / CELL)
		local gz = math.round(world.Z / CELL)
		local key = xzKey(gx, gz)
		if byKey[key] then
			continue
		end
		local x, z = jitteredXZ(gx, gz)
		local hitPos, hitKey = claimFloor(x, z, playerPos.Y, key)
		if hitPos and hitKey then
			return hitPos, hitKey
		end
	end
	return nil, nil
end

local function findSpot(playerPos: Vector3, flat: Vector3): (Vector3?, string?)
	local hitPos, key = sampleBand(playerPos, flat, DIST_MIN, DIST_MAX, 40)
	if hitPos and key then
		return hitPos, key
	end
	-- Front 20–400 is full. Fill in behind.
	return sampleBand(playerPos, flat, -BEHIND_MAX, -BEHIND_MIN, 16)
end

local function edgeDist(localX: number, localZ: number, halfX: number, halfZ: number): number
	local dx = math.max(math.abs(localX) - halfX, 0)
	local dz = math.max(math.abs(localZ) - halfZ, 0)
	return math.sqrt(dx * dx + dz * dz)
end

local function notePlotSpan(size: Vector3)
	local span = math.max(size.X, size.Z)
	if span > seenPlotSpan + 1 then
		seenPlotSpan = span
		plotOuter = PLOT_EDGE_MIN + PLOT_BAND
		plotMisses = 0
	end
end

local function clearCommonsInsideOwnPlot()
	local own = ClientPlot.get()
	if not own then
		return
	end
	notePlotSpan(own.size)
	local i = #plants
	while i >= 1 do
		local plant = plants[i]
		if plant and GridMath.isInsidePlotXZ(plant.pos, own.cframe, own.size) then
			destroyPlant(plant)
			if i > #plants then
				i = #plants
			end
		else
			i -= 1
		end
	end
end

local function playerPos(): Vector3?
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		return nil
	end
	return hrp.Position
end

-- Ring outside the live plot edge. Inner band is 50–150, then +100 each time it fills.
local function findPlotSpot(): (Vector3?, string?)
	local own = ClientPlot.get()
	local pos = playerPos()
	if not own or not pos then
		return nil, nil
	end
	local halfX = own.size.X * 0.5
	local halfZ = own.size.Z * 0.5
	local inner = math.max(PLOT_EDGE_MIN, plotOuter - PLOT_BAND)
	local outer = plotOuter
	local reachX = halfX + outer
	local reachZ = halfZ + outer
	for _ = 1, 36 do
		local lx = rng:NextNumber(-reachX, reachX)
		local lz = rng:NextNumber(-reachZ, reachZ)
		local dist = edgeDist(lx, lz, halfX, halfZ)
		if dist < inner or dist > outer then
			continue
		end
		local world = own.cframe:PointToWorldSpace(Vector3.new(lx, 0, lz))
		if insideAnyPlot(world) then
			continue
		end
		local gx = math.round(world.X / CELL)
		local gz = math.round(world.Z / CELL)
		local key = xzKey(gx, gz)
		if byKey[key] then
			continue
		end
		local x, z = jitteredXZ(gx, gz)
		local hitPos, hitKey = claimFloor(x, z, pos.Y, key)
		if hitPos and hitKey then
			return hitPos, hitKey
		end
	end
	return nil, nil
end

local function plantOne(playerPos: Vector3, flat: Vector3, flyOrb: boolean, presetHit: Vector3?, presetKey: string?): boolean
	if #speciesIds == 0 then
		return false
	end
	local hitPos = presetHit
	local key = presetKey
	if not hitPos or not key then
		hitPos, key = findSpot(playerPos, flat)
	end
	if not hitPos or not key or byKey[key] then
		return false
	end
	local speciesId = speciesIds[rng:NextInteger(1, #speciesIds)]
	local roll = rng:NextNumber()
	-- 50% small, 35% medium, 15% large.
	local sizeClass = if roll < 0.5 then 1 elseif roll < 0.85 then 2 else 3
	local hue = HueRarity.roll(speciesId, rng)
	local hue2 = HueRarity.roll(speciesId, rng)
	local opts: CoralVisual.VisualOptions = {
		color = PlotOutlineColors.randomHueVariant(hue),
		webColor = PlotOutlineColors.randomHueVariant(hue2),
		sizeClass = sizeClass,
		variantIndex = CoralVisual.randomMeshVariant(speciesId),
		scaleMult = CoralVisual.randomMeshScale(speciesId, sizeClass),
		facingYaw = rng:NextNumber(0, math.pi * 2),
	}
	if speciesId == "SeaFan" then
		local scale, width, height = CoralVisual.randomSeaFanScales()
		opts.scaleMult = scale
		opts.scaleWidth = width
		opts.scaleHeight = height
	elseif speciesId == "BrainCoral" then
		opts.diameter = CoralVisual.randomBrainDiameter()
	end
	local part = CoralVisual.create(speciesId, hitPos, opts)
	if not part then
		return false
	end
	stripVisual(part)
	local finalCF = part.CFrame
	local bury = part.Size.Y
	for _, d in ipairs(part:GetDescendants()) do
		if d:IsA("BasePart") then
			bury = math.max(bury, d.Size.Y)
		end
	end
	local buryVec = Vector3.new(0, -(bury + 1.5), 0)
	part.CFrame = finalCF + buryVec
	for _, d in ipairs(part:GetDescendants()) do
		if d:IsA("BasePart") then
			d.CFrame += buryVec
		end
	end
	part.Parent = folder
	local riseInfo = if isPlotView() then PLOT_RISE_SEC else RISE_SEC
	local rise = TweenService:Create(part, riseInfo, { CFrame = finalCF })
	rise.Completed:Connect(function()
		if part.Parent then
			enableCollision(part)
		end
	end)
	rise:Play()

	local plant: Plant = { part = part, pos = hitPos, key = key, index = #plants + 1 }
	plants[plant.index] = plant
	byKey[key] = plant

	if flyOrb then
		commonOrbArmed = true
		HandOrb.playPlantFly(opts.color :: Color3, hitPos)
	end
	return true
end

local function releaseCommonOrb()
	if not commonOrbArmed then
		return
	end
	if PlacementController.isActive() or RelocateController.isActive() then
		commonOrbArmed = false
		return
	end
	commonOrbArmed = false
	HandOrb.disarm(0.15)
end

local function sampleFps(): number
	local now = os.clock()
	local dt = now - fpsWindowStart
	if dt < 0.25 then
		return lastFps
	end
	lastFps = frameCount / dt
	frameCount = 0
	fpsWindowStart = now
	return lastFps
end

local GRID_GAP = 10

local function clearSessionCommons()
	while #plants > 0 do
		destroyPlant(plants[#plants])
	end
end

local function registerResting(part: BasePart, hitPos: Vector3, key: string)
	stripVisual(part)
	part.Parent = folder
	enableCollision(part)
	local plant: Plant = { part = part, pos = hitPos, key = key, index = #plants + 1 }
	plants[plant.index] = plant
	byKey[key] = plant
end

-- One row per species, 10 studs apart. Closest coral is the species default, then hue 1..14.
local function spawnHueGrid()
	local pos = playerPos()
	local flat = facingFlat()
	if not pos or not flat or #speciesIds == 0 then
		return
	end
	local right = Vector3.new(-flat.Z, 0, flat.X)
	local nRows = #speciesIds
	local dist = 20
	for _ = 1, 80 do
		local blocked = false
		for row = 1, nRows do
			local side = (row - 1 - (nRows - 1) / 2) * GRID_GAP
			local world = pos + flat * dist + right * side
			if insideAnyPlot(Vector3.new(world.X, pos.Y, world.Z)) then
				blocked = true
				break
			end
		end
		if not blocked then
			break
		end
		dist += GRID_GAP
	end
	for row = 1, nRows do
		local speciesId = speciesIds[row]
		local side = (row - 1 - (nRows - 1) / 2) * GRID_GAP
		for col = 0, PlotOutlineColors.CORAL_MAX_INDEX do
			local world = pos + flat * (dist + col * GRID_GAP) + right * side
			local probe = Vector3.new(world.X, pos.Y, world.Z)
			if insideAnyPlot(probe) then
				continue
			end
			local hitPos = floorAt(world.X, world.Z, pos.Y)
			local placePos = hitPos or probe
			if insideAnyPlot(placePos) then
				continue
			end
			local key = string.format("grid:%s:%d", speciesId, col)
			local old = byKey[key]
			if old then
				destroyPlant(old)
			end
			local opts: CoralVisual.VisualOptions = {
				sizeClass = 2,
				variantIndex = 1,
				scaleMult = 1,
				facingYaw = 0,
			}
			if speciesId == "BrainCoral" then
				opts.diameter = 4
			elseif speciesId == "SeaFan" then
				opts.scaleWidth = 1
				opts.scaleHeight = 1
			end
			if col > 0 then
				local hue = PlotOutlineColors.coralColor(col)
				opts.color = hue
				opts.webColor = hue
			end
			local part = CoralVisual.create(speciesId, placePos, opts)
			if part then
				registerResting(part, placePos, key)
			end
		end
	end
end

local function isPlayerCam(): boolean
	local camMode = playerGui:GetAttribute("OceanTD_CamCycleMode")
	return camMode == nil or camMode == "off" or camMode == ""
end

local function mountTempTools()
	local gui = Instance.new("ScreenGui")
	gui.Name = "OceanTD_CommonGrowTemp"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 90
	gui.Parent = playerGui

	local stack = Instance.new("Frame")
	stack.Name = "Stack"
	stack.AnchorPoint = Vector2.new(0, 0.5)
	stack.Position = UDim2.new(0, 12, 0.55, 0)
	stack.Size = UDim2.fromOffset(168, 132)
	stack.BackgroundTransparency = 1
	stack.Parent = gui

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.Padding = UDim.new(0, 6)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = stack

	local function makeButton(text: string, order: number): TextButton
		local button = Instance.new("TextButton")
		button.Name = text
		button.LayoutOrder = order
		button.Size = UDim2.new(1, 0, 0, 40)
		button.BackgroundColor3 = Color3.fromRGB(28, 40, 52)
		button.BorderSizePixel = 0
		button.Font = Enum.Font.GothamBold
		button.TextSize = 15
		button.TextColor3 = Color3.new(1, 1, 1)
		button.Text = text
		button.AutoButtonColor = true
		button.Parent = stack
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 8)
		corner.Parent = button
		return button
	end

	local growthButton = makeButton("Coral Growth: On", 1)
	growthButton.BackgroundColor3 = Color3.fromRGB(20, 110, 70)
	local function refreshGrowthButton()
		growthButton.Text = if growthEnabled then "Coral Growth: On" else "Coral Growth: Off"
		growthButton.BackgroundColor3 = if growthEnabled
			then Color3.fromRGB(20, 110, 70)
			else Color3.fromRGB(120, 48, 42)
	end
	growthButton.Activated:Connect(function()
		growthEnabled = not growthEnabled
		refreshGrowthButton()
	end)

	local deleteButton = makeButton("Del Temp Coral", 2)
	deleteButton.Activated:Connect(clearSessionCommons)

	local gridButton = makeButton("Grid All", 3)
	gridButton.Activated:Connect(spawnHueGrid)

	RunService.Heartbeat:Connect(function()
		gui.Enabled = isPlayerCam() and not commonPaused()
	end)
end

mountTempTools()

Remotes.get("PlotRoster").OnClientEvent:Connect(rememberRoster)

task.spawn(function()
	-- Intro claims OceanTD_JoinIntroBusy shortly after boot. Wait for that, then until it clears.
	local deadline = os.clock() + 3
	while playerGui:GetAttribute("OceanTD_JoinIntroBusy") ~= true and os.clock() < deadline do
		task.wait(0.1)
	end
	JoinIntroGate.waitUntilIdle(180)

	local requestRoster = Remotes.getFunction("RequestPlotRoster")
	local ok, payload = pcall(function()
		return requestRoster:InvokeServer()
	end)
	if ok then
		rememberRoster(payload)
	end

	local nextUpkeep = os.clock()
	RunService.Heartbeat:Connect(function()
		local pos = playerPos()
		local fps = sampleFps()
		local now = os.clock()
		if now >= nextUpkeep then
			nextUpkeep = now + 1
			if fps < FPS_MIN then
				releaseCommonOrb()
				if pos and not isPlotView() then
					recycleFarthest(pos, FPS_RECYCLE_BATCH, false)
				end
			elseif pos and canPlant() and growthEnabled then
				recycleFarthest(pos, OUTSIDE_RECYCLE_BATCH, true)
			end
		end
		if fps < FPS_MIN or not pos then
			releaseCommonOrb()
			return
		end
		if not growthEnabled then
			if isPlotView() then
				clearCommonsInsideOwnPlot()
			end
			releaseCommonOrb()
			return
		end
		if isPlotView() then
			clearCommonsInsideOwnPlot()
			if commonPaused() or #plants >= POOL_MAX then
				releaseCommonOrb()
				return
			end
			local own = ClientPlot.get()
			if not own then
				return
			end
			local hitPos, key = findPlotSpot()
			if hitPos and key then
				plotMisses = 0
				plantOne(pos, Vector3.zAxis, false, hitPos, key)
			else
				plotMisses += 1
				if plotMisses >= PLOT_MISS_EXPAND then
					plotMisses = 0
					plotOuter += PLOT_BAND
				end
			end
			return
		end
		clearCommonsInsideOwnPlot()
		if not canPlant() then
			releaseCommonOrb()
			return
		end
		if #plants >= POOL_MAX then
			recycleFarthest(pos, 1, false)
		end
		local flat = facingFlat()
		if flat then
			plantOne(pos, flat, false)
		end
	end)
end)
