--!strict
--[[
	Join-intro showcase: 2× Medium default-hue of each species, spaced on the plot.
	Drops in instead of the player's real reef; stagger-upgrades to Large; feeds the
	path fish emoji; then scales away before the player's saved corals drop in.
]]

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local ContentProvider = game:GetService("ContentProvider")
local Players = game:GetService("Players")

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local SpeciesCatalog = require(oceanRoot:WaitForChild("Shared"):WaitForChild("SpeciesCatalog"))
local CoralVisual = require(oceanRoot:WaitForChild("Shared"):WaitForChild("CoralVisual"))
local CoralSize = require(oceanRoot:WaitForChild("Shared"):WaitForChild("CoralSize"))

local ClientPlot = require(script.Parent:WaitForChild("ClientPlot"))
local CoralInspectPanelConsts = require(script.Parent:WaitForChild("CoralInspectPanelConsts"))

local JoinIntroExampleCorals = {}

local groundRayParams: RaycastParams? = nil

local FOLDER_NAME = "OceanTD_JoinIntroExamples"
local SPECIES_ORDER = {
	"BrainCoral",
	"Sponge",
	"SeaGrass",
	"FireCoral",
	"Zoas",
	"TreeCoral",
	"LeatherCoral",
	"SeaFan",
}

local PER_SPECIES = 2
local DROP_HEIGHT = 70
local DROP_TWEEN = TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local FOOD_DIAM = 3.6 -- oversized vs nest ammo (~1.2)
local FOOD_FLIGHT_SEC = 0.38
local FOOD_INTERVAL = 0.56 -- half the prior fire rate
local DESPAWN_SEC = 0.55
local PLOT_PLACE_INSET = 0.78 -- fraction of plot XZ used for the even grid
local UPGRADE_START_SEC = 1.05
local UPGRADE_STAGGER_SEC = 0.11
local UPGRADE_GROW_SEC = CoralInspectPanelConsts.CINE_GROW_SEC or 0.68
local PLACE_SOUND_ID = "rbxassetid://139911414972673"

local placeSoundTemplate = Instance.new("Sound")
placeSoundTemplate.Name = "OceanTD_JoinIntroPlaceCoral"
placeSoundTemplate.SoundId = PLACE_SOUND_ID
placeSoundTemplate.Volume = 0.85
placeSoundTemplate.Parent = SoundService
task.defer(function()
	pcall(function()
		ContentProvider:PreloadAsync({ placeSoundTemplate })
	end)
end)

type Entry = {
	root: BasePart,
	model: Model,
	parts: { BasePart },
	nativeScale: number,
	surfacePos: Vector3,
	speciesId: string,
	nextFireAt: number,
}

local folder: Folder? = nil
local entries: { Entry } = {}
local feeding = false
local feedToken = 0
local upgradeToken = 0
local activeFood: { BasePart } = {}
-- Live fish tip — food homes here each frame so shots don't land on a passed waypoint.
local feedTarget: Vector3? = nil

local function ensureFolder(): Folder
	if folder and folder.Parent then
		return folder
	end
	local existing = Workspace:FindFirstChild(FOLDER_NAME)
	if existing and existing:IsA("Folder") then
		folder = existing
		return existing
	end
	local f = Instance.new("Folder")
	f.Name = FOLDER_NAME
	f.Parent = Workspace
	folder = f
	return f
end

local function collectParts(root: BasePart): { BasePart }
	local parts: { BasePart } = { root }
	local seen: { [BasePart]: boolean } = { [root] = true }
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("BasePart") and not seen[d] then
			seen[d] = true
			table.insert(parts, d)
		end
	end
	return parts
end

local function setTreeHidden(parts: { BasePart }, hidden: boolean)
	local mod = if hidden then 1 else 0
	for _, p in ipairs(parts) do
		p.LocalTransparencyModifier = mod
	end
end

-- Keep authored mesh / catalog spawn colors (not palette defaultColorIndex paint).
local function keepTemplateLook(root: BasePart)
	root:SetAttribute("OceanTD_ColorIndex", nil)
	root:SetAttribute("OceanTD_WebColorIndex", nil)
	CoralVisual.snapshotDefaultRestLook(root)
	CoralVisual.clearPalettePaint(root)
end

local function playPlaceSound(worldPos: Vector3)
	local parent: Instance = Workspace.CurrentCamera or Workspace
	local holder = Instance.new("Part")
	holder.Name = "OceanTD_JoinIntroPlaceSound"
	holder.Anchored = true
	holder.CanCollide = false
	holder.CanTouch = false
	holder.CanQuery = false
	holder.CastShadow = false
	holder.Transparency = 1
	holder.Size = Vector3.new(0.2, 0.2, 0.2)
	holder.CFrame = CFrame.new(worldPos)
	holder.Parent = parent
	local sound = placeSoundTemplate:Clone()
	sound.PlaybackSpeed = 0.85 + math.random() * 0.35
	sound.Parent = holder
	sound:Play()
	sound.Ended:Once(function()
		if holder.Parent then
			holder:Destroy()
		end
	end)
	task.delay(4, function()
		if holder.Parent then
			holder:Destroy()
		end
	end)
end

local function easeQuadOut(u: number): number
	return 1 - (1 - u) * (1 - u)
end

local function tweenMeshGrow(part: BasePart, fullSize: Vector3, surface: Vector3, fromMult: number, toMult: number, sec: number)
	local dual = CoralVisual.isDualColorMesh(part:GetAttribute("OceanTD_SpeciesId"))
	if dual then
		CoralVisual.applySeaFanScaleMult(part, fullSize, fromMult, surface)
	else
		part.Size = fullSize * fromMult
		CoralVisual.alignMeshToSurface(part, surface, nil, part.CFrame)
	end
	local t0 = os.clock()
	while part.Parent do
		local u = math.clamp((os.clock() - t0) / sec, 0, 1)
		local mult = fromMult + (toMult - fromMult) * easeQuadOut(u)
		if dual then
			CoralVisual.applySeaFanScaleMult(part, fullSize, mult, surface)
		else
			part.Size = fullSize * mult
			CoralVisual.alignMeshToSurface(part, surface, nil, part.CFrame)
		end
		if u >= 1 then
			break
		end
		RunService.RenderStepped:Wait()
	end
	if not part.Parent then
		return
	end
	if dual then
		CoralVisual.applySeaFanScaleMult(part, fullSize, toMult, surface)
	else
		part.Size = fullSize * toMult
		CoralVisual.alignMeshToSurface(part, surface, nil, part.CFrame)
	end
end

local function tweenBallGrow(part: BasePart, fromD: number, toD: number, surface: Vector3, sec: number)
	local rot = part.CFrame - part.CFrame.Position
	part.Size = Vector3.new(fromD, fromD, fromD)
	part.CFrame = CFrame.new(surface) * rot
	local t0 = os.clock()
	while part.Parent do
		local u = math.clamp((os.clock() - t0) / sec, 0, 1)
		local d = fromD + (toD - fromD) * easeQuadOut(u)
		part.Size = Vector3.new(d, d, d)
		part.CFrame = CFrame.new(surface) * rot
		if u >= 1 then
			break
		end
		RunService.RenderStepped:Wait()
	end
	if part.Parent then
		part.Size = Vector3.new(toD, toD, toD)
		part.CFrame = CFrame.new(surface) * rot
	end
end

local function clearFood()
	for _, p in ipairs(activeFood) do
		if p.Parent then
			p:Destroy()
		end
	end
	table.clear(activeFood)
end

function JoinIntroExampleCorals.clear()
	feedToken += 1
	upgradeToken += 1
	feeding = false
	feedTarget = nil
	clearFood()
	for _, e in ipairs(entries) do
		if e.model.Parent then
			e.model:Destroy()
		elseif e.root.Parent then
			e.root:Destroy()
		end
	end
	table.clear(entries)
	if folder and folder.Parent then
		folder:ClearAllChildren()
	end
end

-- Match normal place raycasts so corals sit on the real sand top, not the plot AABB floor.
local function surfaceAtXZ(xz: Vector3): Vector3
	local plot = ClientPlot.get()
	local originY = if plot then plot.cframe.Position.Y + math.max(plot.size.Y, 40) else xz.Y + 80
	local origin = Vector3.new(xz.X, originY, xz.Z)
	if not groundRayParams then
		groundRayParams = RaycastParams.new()
		groundRayParams.FilterType = Enum.RaycastFilterType.Exclude
	end
	local exclude: { Instance } = {}
	local placed = Workspace:FindFirstChild("OceanTD_Placed")
	if placed then
		table.insert(exclude, placed)
	end
	local host = folder or Workspace:FindFirstChild(FOLDER_NAME)
	if host then
		table.insert(exclude, host)
	end
	local lp = Players.LocalPlayer
	local char = lp and lp.Character
	if char then
		table.insert(exclude, char)
	end
	groundRayParams.FilterDescendantsInstances = exclude
	-- Prefer a mostly-upward hit (sand top); skip walls / thin props.
	local best: RaycastResult? = nil
	local cursor = origin
	for _ = 1, 6 do
		local hit = Workspace:Raycast(cursor, Vector3.new(0, -400, 0), groundRayParams)
		if not hit then
			break
		end
		if hit.Normal.Y >= 0.55 then
			best = hit
			break
		end
		-- Nudge past non-floor hits and keep searching downward.
		cursor = hit.Position - Vector3.new(0, 0.15, 0)
	end
	if best then
		return best.Position
	end
	if plot then
		local localP = plot.cframe:PointToObjectSpace(xz)
		local half = plot.size * 0.5
		-- Match geometric plot floor (same plane normal place falls back to).
		local floorLocal = Vector3.new(
			math.clamp(localP.X, -half.X + 2, half.X - 2),
			-half.Y,
			math.clamp(localP.Z, -half.Z + 2, half.Z - 2)
		)
		return plot.cframe:PointToWorldSpace(floorLocal)
	end
	return xz
end

local TALL_BACK_SPECIES: { [string]: boolean } = {
	SeaGrass = true,
	TreeCoral = true,
	Sponge = true,
}

local function camLookFlat(): (Vector3, Vector3)
	local cam = Workspace.CurrentCamera
	local origin = if cam then cam.CFrame.Position else Vector3.zero
	local look = if cam then cam.CFrame.LookVector else Vector3.new(0, 0, -1)
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude < 1e-3 then
		flat = Vector3.new(0, 0, -1)
	else
		flat = flat.Unit
	end
	return origin, flat
end

-- Depth along camera look (larger = further from camera / more "into" the scene).
local function depthFromCamera(worldPos: Vector3): number
	local origin, flat = camLookFlat()
	return (worldPos - origin):Dot(flat)
end

-- Even grid across the plot. Tall species get the furthest cells from the camera.
local function placePositionsForSpecies(speciesIds: { string }): { Vector3 }
	local count = #speciesIds
	local positions: { Vector3 } = table.create(count)
	if count <= 0 then
		return positions
	end
	local plot = ClientPlot.get()
	if not plot then
		for i = 1, count do
			positions[i] = Vector3.zero
		end
		return positions
	end
	local cols = math.max(1, math.ceil(math.sqrt(count)))
	local rows = math.max(1, math.ceil(count / cols))
	while cols * rows < count do
		if cols <= rows then
			cols += 1
		else
			rows += 1
		end
	end
	local candidates: { Vector3 } = {}
	local spanX = plot.size.X * PLOT_PLACE_INSET
	local spanZ = plot.size.Z * PLOT_PLACE_INSET
	for r = 1, rows do
		for c = 1, cols do
			local u = if cols <= 1 then 0.5 else (c - 0.5) / cols
			local v = if rows <= 1 then 0.5 else (r - 0.5) / rows
			local localP = Vector3.new((u - 0.5) * spanX, 0, (v - 0.5) * spanZ)
			table.insert(candidates, surfaceAtXZ(plot.cframe:PointToWorldSpace(localP)))
		end
	end
	-- Furthest from camera first.
	table.sort(candidates, function(a, b)
		return depthFromCamera(a) > depthFromCamera(b)
	end)
	local tallIdx: { number } = {}
	local shortIdx: { number } = {}
	for i, sid in ipairs(speciesIds) do
		if TALL_BACK_SPECIES[sid] then
			table.insert(tallIdx, i)
		else
			table.insert(shortIdx, i)
		end
	end
	local rng = Random.new()
	local function shuffleInPlace(list: { number })
		for i = #list, 2, -1 do
			local j = rng:NextInteger(1, i)
			list[i], list[j] = list[j], list[i]
		end
	end
	shuffleInPlace(tallIdx)
	shuffleInPlace(shortIdx)
	-- Assign furthest slots to tall species, nearer slots to the rest.
	local order: { number } = {}
	for _, i in ipairs(tallIdx) do
		table.insert(order, i)
	end
	for _, i in ipairs(shortIdx) do
		table.insert(order, i)
	end
	local used = 0
	for _, speciesIndex in ipairs(order) do
		used += 1
		positions[speciesIndex] = candidates[used] or surfaceAtXZ(plot.cframe.Position)
	end
	return positions
end

local function plantOnSurface(root: BasePart, surface: Vector3, speciesId: string)
	local plot = ClientPlot.get()
	if CoralVisual.isMeshSpecies(speciesId) then
		local yaw = root:GetAttribute("OceanTD_FacingYaw")
		CoralVisual.alignMeshToSurface(
			root,
			surface,
			if typeof(yaw) == "number" then yaw else 0,
			nil,
			if plot then plot.cframe else nil
		)
	else
		local rot = root.CFrame - root.CFrame.Position
		root.CFrame = CFrame.new(surface) * rot
	end
end

local function dropPart(root: BasePart, parts: { BasePart }, surface: Vector3, speciesId: string, delaySec: number)
	setTreeHidden(parts, true)
	plantOnSurface(root, surface, speciesId)
	local finalCF = root.CFrame
	root.CFrame = finalCF + Vector3.new(0, DROP_HEIGHT + root.Size.Y * 0.5, 0)
	task.delay(delaySec, function()
		if not root.Parent then
			return
		end
		setTreeHidden(parts, false)
		playPlaceSound(surface)
		local tw = TweenService:Create(root, DROP_TWEEN, { CFrame = finalCF })
		tw:Play()
		tw.Completed:Once(function()
			if not root.Parent then
				return
			end
			-- Re-plant after the drop tween so mesh pivot/CFrame matches normal place height.
			plantOnSurface(root, surface, speciesId)
		end)
	end)
end

local function bindEntry(model: Model, root: BasePart, speciesId: string, surfacePos: Vector3, nextFireAt: number): Entry
	local parts = collectParts(root)
	local entry: Entry = {
		root = root,
		model = model,
		parts = parts,
		nativeScale = model:GetScale(),
		surfacePos = surfacePos,
		speciesId = speciesId,
		nextFireAt = nextFireAt,
	}
	table.insert(entries, entry)
	return entry
end

local function upgradeEntryToLarge(e: Entry)
	if not e.root.Parent or not e.model.Parent then
		return
	end
	local sid = e.speciesId
	local surface = CoralVisual.readGridAnchor(e.root) or e.surfacePos
	e.surfacePos = surface

	if CoralVisual.isMeshSpecies(sid) then
		local variant = CoralVisual.randomMeshVariant(sid)
		local scale: number?
		local scaleWidth: number? = nil
		local scaleHeight: number? = nil
		if CoralVisual.isSeaFan(sid) then
			scale, scaleWidth, scaleHeight = CoralVisual.randomSeaFanScales()
		else
			scale = CoralVisual.randomMeshScale(sid, CoralSize.LARGE)
		end
		local newPart = CoralVisual.restyleMesh(e.root, CoralSize.LARGE, variant, scale, surface, scaleWidth, scaleHeight)
		if not newPart then
			return
		end
		e.root = newPart
		if newPart.Parent ~= e.model then
			newPart.Parent = e.model
		end
		e.model.PrimaryPart = newPart
		newPart:SetAttribute("OceanTD_JoinIntroExample", true)
		newPart:SetAttribute("OceanTD_SpeciesId", sid)
		newPart:SetAttribute("OceanTD_ItemId", sid)
		newPart.Anchored = true
		newPart.CanCollide = false
		newPart.CanQuery = false
		newPart.CanTouch = false
		keepTemplateLook(newPart)
		local fullSize = newPart.Size
		-- Restyle lands at full Large — shrink then tween up (same feel as inspect upgrade).
		tweenMeshGrow(newPart, fullSize, surface, 0.05, 1, UPGRADE_GROW_SEC)
		plantOnSurface(newPart, surface, sid)
		keepTemplateLook(newPart)
		e.parts = collectParts(newPart)
		e.nativeScale = e.model:GetScale()
		return
	end

	local fromD = math.max(e.root.Size.X, e.root.Size.Y, e.root.Size.Z)
	local toD = CoralSize.randomDiameter(CoralSize.LARGE)
	CoralSize.applyToPart(e.root, toD, CoralSize.LARGE, CoralSize.LARGE)
	tweenBallGrow(e.root, fromD, toD, surface, UPGRADE_GROW_SEC)
	keepTemplateLook(e.root)
	e.parts = collectParts(e.root)
end

local function scheduleUpgrades(rng: Random)
	local order = table.clone(entries)
	-- Shuffle so upgrades don't ripple strictly along the path.
	for i = #order, 2, -1 do
		local j = rng:NextInteger(1, i)
		order[i], order[j] = order[j], order[i]
	end
	upgradeToken += 1
	local my = upgradeToken
	for i, e in ipairs(order) do
		local delaySec = UPGRADE_START_SEC + (i - 1) * UPGRADE_STAGGER_SEC + rng:NextNumber(0, 0.06)
		task.delay(delaySec, function()
			if my ~= upgradeToken then
				return
			end
			upgradeEntryToLarge(e)
		end)
	end
end

function JoinIntroExampleCorals.spawnAndDrop(): number
	JoinIntroExampleCorals.clear()
	local host = ensureFolder()
	local plot = ClientPlot.get()
	local ids: { string } = {}
	for _, sid in ipairs(SPECIES_ORDER) do
		if SpeciesCatalog.get(sid) then
			for _ = 1, PER_SPECIES do
				table.insert(ids, sid)
			end
		end
	end
	local spots = placePositionsForSpecies(ids)
	local rng = Random.new()
	for i, sid in ipairs(ids) do
		local worldPos = spots[i] or (plot and plot.cframe.Position or Vector3.zero)
		local diam = CoralSize.randomDiameter(CoralSize.MEDIUM)
		local scaleMult = if CoralVisual.isMeshSpecies(sid)
			then CoralVisual.randomMeshScale(sid, CoralSize.MEDIUM)
			else 1
		local part = CoralVisual.create(sid, worldPos, {
			diameter = diam,
			sizeClass = CoralSize.MEDIUM,
			scaleMult = scaleMult,
			plotCFrame = if plot then plot.cframe else nil,
			facingYaw = if CoralVisual.needsFacingYaw(sid) then CoralVisual.randomFacingYaw() else nil,
		})
		if not part then
			continue
		end
		part.Name = "Example_" .. sid
		part:SetAttribute("OceanTD_JoinIntroExample", true)
		part:SetAttribute("OceanTD_SpeciesId", sid)
		part:SetAttribute("OceanTD_ItemId", sid)
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		local model = Instance.new("Model")
		model.Name = "Example_" .. sid
		part.Parent = model
		model.PrimaryPart = part
		model.Parent = host
		CoralSize.applyToPart(part, diam, CoralSize.MEDIUM, CoralSize.MEDIUM)
		plantOnSurface(part, worldPos, sid)
		keepTemplateLook(part)
		local entry = bindEntry(model, part, sid, worldPos, os.clock() + rng:NextNumber(0, FOOD_INTERVAL))
		dropPart(part, entry.parts, worldPos, sid, rng:NextNumber(0, 0.85))
	end
	scheduleUpgrades(rng)
	return #entries
end

local function shootFood(from: Vector3, color: Color3)
	local host = ensureFolder()
	local food = Instance.new("Part")
	food.Name = "ExampleFood"
	food.Shape = Enum.PartType.Ball
	food.Material = Enum.Material.Neon
	food.Color = color
	food.Anchored = true
	food.CanCollide = false
	food.CanQuery = false
	food.CanTouch = false
	food.CastShadow = false
	food.Size = Vector3.new(FOOD_DIAM, FOOD_DIAM, FOOD_DIAM)
	food.CFrame = CFrame.new(from)
	food.Parent = host
	table.insert(activeFood, food)
	local t0 = os.clock()
	local pos = from
	task.spawn(function()
		while food.Parent do
			local u = (os.clock() - t0) / FOOD_FLIGHT_SEC
			if u >= 1 then
				break
			end
			local e = 1 - (1 - u) ^ 2
			-- Home on the live fish tip (not a frozen past waypoint).
			local to = feedTarget or pos
			pos = from:Lerp(to, e)
			food.CFrame = CFrame.new(pos + Vector3.new(0, math.sin(e * math.pi) * 4, 0))
			RunService.RenderStepped:Wait()
		end
		if food.Parent then
			local fadeT0 = os.clock()
			while food.Parent and os.clock() - fadeT0 < 0.2 do
				local f = (os.clock() - fadeT0) / 0.2
				food.Transparency = f
				food.Size = Vector3.new(FOOD_DIAM, FOOD_DIAM, FOOD_DIAM) * (1 - 0.5 * f)
				RunService.RenderStepped:Wait()
			end
			food:Destroy()
		end
		local idx = table.find(activeFood, food)
		if idx then
			table.remove(activeFood, idx)
		end
	end)
end

function JoinIntroExampleCorals.beginFeeding()
	feeding = true
	feedToken += 1
end

function JoinIntroExampleCorals.feedToward(worldPos: Vector3)
	-- Always refresh aim point while the fish is moving.
	feedTarget = worldPos
	if not feeding or #entries == 0 then
		return
	end
	local now = os.clock()
	for _, e in ipairs(entries) do
		if not e.root.Parent then
			continue
		end
		if now < e.nextFireAt then
			continue
		end
		e.nextFireAt = now + FOOD_INTERVAL + (math.random() * 0.2)
		local from = e.root.Position + Vector3.new(0, e.root.Size.Y * 0.35, 0)
		shootFood(from, e.root.Color)
	end
end

function JoinIntroExampleCorals.stopFeeding()
	feeding = false
	feedToken += 1
	feedTarget = nil
end

function JoinIntroExampleCorals.scaleOutAndClear()
	JoinIntroExampleCorals.stopFeeding()
	upgradeToken += 1
	clearFood()
	local snapshot = table.clone(entries)
	table.clear(entries)
	local t0 = os.clock()
	while os.clock() - t0 < DESPAWN_SEC do
		local u = math.clamp((os.clock() - t0) / DESPAWN_SEC, 0, 1)
		local s = math.max(0.02, 1 - u)
		for _, e in ipairs(snapshot) do
			if e.model.Parent then
				pcall(function()
					e.model:ScaleTo(e.nativeScale * s)
				end)
				for _, p in ipairs(e.parts) do
					if p.Parent then
						p.LocalTransparencyModifier = u
					end
				end
			end
		end
		RunService.RenderStepped:Wait()
	end
	for _, e in ipairs(snapshot) do
		if e.model.Parent then
			e.model:Destroy()
		end
	end
	if folder and folder.Parent then
		folder:ClearAllChildren()
	end
end

function JoinIntroExampleCorals.count(): number
	return #entries
end

return JoinIntroExampleCorals
