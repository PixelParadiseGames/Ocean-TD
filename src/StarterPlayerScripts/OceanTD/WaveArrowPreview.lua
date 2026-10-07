--!strict
--[[
	Green fish-route + red crab/urchin GroundA/B + red shark-route arrow trains.
	Extracted from WaveSim so it stays under Luau's 200-local limit.
	Trains emerge from each path start (negative lead spacing), not pre-filled.
]]

local ContentProvider = game:GetService("ContentProvider")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local UiTheme = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiTheme"))

local WaveEntityPool = require(script.Parent:WaitForChild("WaveEntityPool"))
local WaveCrab = require(script.Parent:WaitForChild("WaveCrab"))
local WaveUrchin = require(script.Parent:WaitForChild("WaveUrchin"))
local WaveShark = require(script.Parent:WaitForChild("WaveShark"))
local C = require(script.Parent:WaitForChild("WaveSimConsts"))

local WaveArrowPreview = {}

export type PathLike = {
	totalLen: number,
	segments: { any },
	endPos: Vector3?,
	waypointDists: { number }?,
}

export type Host = {
	ensureFolder: () -> Folder,
	getFishPath: () -> PathLike?,
	getFishPaths: (() -> { PathLike })?,
	getGroundPaths: () -> { WaveCrab.PathData },
	getSharkPath: () -> WaveCrab.PathData?,
	getWaveIndex: () -> number,
	sampleFishPath: (PathLike, number) -> (Vector3, Vector3),
}

export type StartOpts = {
	playSound: boolean?,
	includeShark: boolean?,
	-- When true, show crab GroundA/B trains even if this wave expects 0 crabs/urchins.
	forceGroundTrains: boolean?,
	-- Override path billboard text (planning: "Friendly Fish" / "Dangerous Critters").
	greenLabelText: string?,
	redLabelText: string?,
}

type ArrowPreview = {
	model: Instance,
	dist: number,
	spin: number,
	alive: boolean,
	path: WaveCrab.PathData?, -- set for ground (A/B) red arrows + multi fish routes
	visible: boolean?,
}

type WavePathLabel = {
	part: BasePart,
	dist: number,
	alive: boolean,
	path: PathLike?,
	groundPath: WaveCrab.PathData?,
	visible: boolean?,
}

local host: Host? = nil
local greenArrowsTemplate: Instance? = nil
local arrowsWarned = false
local startGeneration = 0
local redSpawnPending = false
local tickSpeedMult = 1
local arrowPreviews: { ArrowPreview } = {}
local crabArrowPreviews: { ArrowPreview } = {}
local sharkArrowPreviews: { ArrowPreview } = {}
local wavePathLabels: { WavePathLabel } = {}
local crabPathLabels: { WavePathLabel } = {}

local arrowSound = Instance.new("Sound")
arrowSound.Name = "OceanTD_WaveArrows"
arrowSound.SoundId = C.ARROW_SOUND_ID
arrowSound.Volume = 0.9
arrowSound.Parent = SoundService

task.defer(function()
	pcall(function()
		ContentProvider:PreloadAsync({ arrowSound })
	end)
end)

function WaveArrowPreview.bind(h: Host)
	host = h
end

local function getGreenArrowsTemplate(): Instance?
	if greenArrowsTemplate and greenArrowsTemplate.Parent then
		return greenArrowsTemplate
	end
	local arrows = ReplicatedStorage:FindFirstChild("GreenArrows")
	if not arrows then
		if not arrowsWarned then
			arrowsWarned = true
			warn("[WAVE] ReplicatedStorage.GreenArrows missing")
		end
		return nil
	end
	greenArrowsTemplate = arrows
	return arrows
end

local function setArrowCFrame(model: Instance, pos: Vector3, tang: Vector3, spin: number)
	local move = if tang.Magnitude > 1e-5 then tang.Unit else Vector3.new(0, 0, -1)
	local look = CFrame.lookAt(pos, pos + move, Vector3.yAxis)
	local desired = look * CFrame.Angles(0, C.ARROW_YAW, C.ARROW_ROLL + spin)
	if model:IsA("Model") then
		model:PivotTo(desired)
	elseif model:IsA("BasePart") then
		model.CFrame = desired
	else
		local root = WaveEntityPool.findPrimary(model)
		if root then
			local old = root.CFrame
			root.CFrame = desired
			local delta = desired * old:Inverse()
			for _, d in ipairs(model:GetDescendants()) do
				if d:IsA("BasePart") and d ~= root then
					d.CFrame = delta * d.CFrame
				end
			end
		end
	end
end

local function setModelHidden(model: Instance, hidden: boolean)
	local mod = if hidden then 1 else 0
	if model:IsA("BasePart") then
		model.LocalTransparencyModifier = mod
		return
	end
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			d.LocalTransparencyModifier = mod
		end
	end
end

local function clearGreenTrains()
	for _, preview in ipairs(arrowPreviews) do
		WaveEntityPool.releaseArrows(preview.model)
	end
	table.clear(arrowPreviews)
	for _, label in ipairs(wavePathLabels) do
		if label.part.Parent then
			label.part:Destroy()
		end
	end
	table.clear(wavePathLabels)
end

local function clearCrabPathLabels()
	for _, label in ipairs(crabPathLabels) do
		if label.part.Parent then
			label.part:Destroy()
		end
	end
	table.clear(crabPathLabels)
end

local function clearRedTrains()
	startGeneration += 1
	redSpawnPending = false
	for _, preview in ipairs(crabArrowPreviews) do
		WaveEntityPool.releaseRedArrows(preview.model)
	end
	table.clear(crabArrowPreviews)
	for _, preview in ipairs(sharkArrowPreviews) do
		WaveEntityPool.releaseRedArrows(preview.model)
	end
	table.clear(sharkArrowPreviews)
	clearCrabPathLabels()
end

function WaveArrowPreview.destroy()
	clearGreenTrains()
	clearRedTrains()
	WaveArrowPreview.setPlanningLegendVisible(false)
end

function WaveArrowPreview.hasActiveTrains(): boolean
	return #arrowPreviews > 0 or #crabArrowPreviews > 0 or #sharkArrowPreviews > 0
end

function WaveArrowPreview.hasActiveGreenTrains(): boolean
	return #arrowPreviews > 0
end

function WaveArrowPreview.hasActiveRedTrains(): boolean
	return redSpawnPending or #crabArrowPreviews > 0 or #sharkArrowPreviews > 0
end

local planningLegendSg: ScreenGui? = nil

local function ensurePlanningLegend(): ScreenGui
	if planningLegendSg and planningLegendSg.Parent then
		return planningLegendSg
	end
	local Players = game:GetService("Players")
	local pg = Players.LocalPlayer:WaitForChild("PlayerGui") :: PlayerGui
	local sg = Instance.new("ScreenGui")
	sg.Name = "OceanTD_PlanningCritterLegend"
	sg.ResetOnSpawn = false
	sg.IgnoreGuiInset = true
	sg.DisplayOrder = 43
	sg.Enabled = false
	sg.Parent = pg

	local row = Instance.new("Frame")
	row.Name = "Row"
	row.AnchorPoint = Vector2.new(0.5, 1)
	row.Position = UDim2.new(0.5, 0, 1, -36)
	row.Size = UDim2.fromOffset(0, 36)
	row.AutomaticSize = Enum.AutomaticSize.X
	row.BackgroundTransparency = 1
	row.Parent = sg

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 0)
	layout.Parent = row

	local function makePart(name: string, text: string, color: Color3, order: number): TextLabel
		local lbl = Instance.new("TextLabel")
		lbl.Name = name
		lbl.LayoutOrder = order
		lbl.BackgroundTransparency = 1
		lbl.AutomaticSize = Enum.AutomaticSize.X
		lbl.Size = UDim2.fromOffset(0, 36)
		lbl.Font = UiTheme.Font
		lbl.TextSize = 28
		lbl.Text = text
		lbl.TextColor3 = color
		lbl.TextStrokeTransparency = 0.35
		lbl.TextStrokeColor3 = Color3.new(0, 0, 0)
		lbl.Parent = row
		return lbl
	end

	makePart("Dangerous", "DANGEROUS", Color3.fromRGB(230, 45, 55), 1)
	makePart("Slash", "/", Color3.new(1, 1, 1), 2)
	makePart("Friendly", "FRIENDLY", Color3.fromRGB(40, 255, 120), 3)
	makePart("Critters", " CRITTERS PATHS", Color3.new(1, 1, 1), 4)

	planningLegendSg = sg
	return sg
end

function WaveArrowPreview.setPlanningLegendVisible(visible: boolean)
	local sg = ensurePlanningLegend()
	sg.Enabled = visible == true
end

function WaveArrowPreview.setTickSpeedMult(mult: number)
	tickSpeedMult = math.max(0.05, mult)
end

local function playArrowStartSound()
	WaveEntityPool.playSound("arrow", arrowSound, 1, 0.9, true)
end

-- Fade the wave-start arrow sting (used while wave-explainer VO is speaking on wave 1).
function WaveArrowPreview.fadeOutStartSound(fadeSec: number?)
	WaveEntityPool.fadeLiveSound("arrow", fadeSec or 0.45)
end

local function createWavePathLabel(text: string, pos: Vector3, parent: Instance, color: Color3?, stroke: Color3?): BasePart
	local part = Instance.new("Part")
	part.Name = "OceanTD_WaveLabel"
	part.Size = Vector3.new(0.4, 0.4, 0.4)
	part.Transparency = 1
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.CFrame = CFrame.new(pos)
	part.Parent = parent

	local bb = Instance.new("BillboardGui")
	bb.Name = "Label"
	bb.Adornee = part
	bb.AlwaysOnTop = true
	bb.LightInfluence = 0
	bb.MaxDistance = 2000
	bb.Size = UDim2.fromScale(C.WAVE_LABEL_SCALE.X, C.WAVE_LABEL_SCALE.Y)
	bb.StudsOffset = Vector3.new(0, C.WAVE_LABEL_HEIGHT, 0)
	bb.Parent = part

	local textColor = color or Color3.fromRGB(40, 255, 120)
	local lbl = Instance.new("TextLabel")
	lbl.BackgroundTransparency = 1
	lbl.Size = UDim2.fromScale(1, 1)
	lbl.Font = UiTheme.Font
	lbl.Text = text
	lbl.TextColor3 = textColor
	lbl.TextScaled = true
	lbl.TextStrokeTransparency = 0.25
	lbl.TextStrokeColor3 = stroke or Color3.fromRGB(0, 40, 15)
	lbl.Parent = bb

	return part
end

local function startCrabArrowPreview(forceGround: boolean, redLabelText: string?)
	local h = host
	if not h then
		return
	end
	for _, preview in ipairs(crabArrowPreviews) do
		WaveEntityPool.releaseRedArrows(preview.model)
	end
	table.clear(crabArrowPreviews)
	clearCrabPathLabels()
	local paths = h.getGroundPaths()
	if #paths == 0 then
		return
	end
	if not forceGround and WaveCrab.expectedCount() <= 0 and WaveUrchin.expectedCount() <= 0 then
		return
	end
	local folderFx = h.ensureFolder()
	local lift = Vector3.new(0, C.CRAB_ARROW_Y_LIFT, 0)
	local arrowI = 0
	for _, path in ipairs(paths) do
		-- Leader at dist 0; followers queue behind the start and emerge one by one.
		for i = 1, C.CRAB_ARROW_COUNT do
			arrowI += 1
			local d = -(i - 1) * C.CRAB_ARROW_PATH_SPACING
			local clone = WaveEntityPool.acquireRedArrows(
				"OceanTD_RedArrows_" .. tostring(arrowI),
				folderFx,
				C.CRAB_ARROW_COLOR
			)
			if not clone then
				break
			end
			local spin0 = (arrowI - 1) * 0.55
			local sampleD = math.max(0, d)
			local pos, tang = WaveCrab.sample(path, sampleD)
			setArrowCFrame(clone, pos + lift, tang, spin0)
			local visible = d >= 0
			if not visible then
				setModelHidden(clone, true)
			end
			table.insert(crabArrowPreviews, {
				model = clone,
				dist = d,
				spin = spin0,
				alive = true,
				path = path,
				visible = visible,
			})
			if redLabelText and i % C.ARROW_LABEL_EVERY == 0 then
				local part = createWavePathLabel(
					redLabelText,
					pos + lift,
					folderFx,
					C.CRAB_ARROW_COLOR,
					Color3.fromRGB(40, 0, 0)
				)
				if not visible then
					local bb = part:FindFirstChild("Label")
					if bb and bb:IsA("BillboardGui") then
						bb.Enabled = false
					end
				end
				table.insert(crabPathLabels, {
					part = part,
					dist = d,
					alive = true,
					groundPath = path,
					visible = visible,
				})
			end
		end
	end
end

local function startSharkArrowPreview()
	local h = host
	if not h then
		return
	end
	for _, preview in ipairs(sharkArrowPreviews) do
		WaveEntityPool.releaseRedArrows(preview.model)
	end
	table.clear(sharkArrowPreviews)
	local path = h.getSharkPath()
	local waveIndex = h.getWaveIndex()
	if not path or not WaveShark.shouldSpawn(waveIndex) then
		return
	end
	local folderFx = h.ensureFolder()
	for i = 1, C.CRAB_ARROW_COUNT do
		local d = -(i - 1) * C.CRAB_ARROW_PATH_SPACING
		local clone = WaveEntityPool.acquireRedArrows(
			"OceanTD_SharkRedArrows_" .. tostring(i),
			folderFx,
			C.CRAB_ARROW_COLOR
		)
		if not clone then
			break
		end
		local spin0 = (i - 1) * 0.55
		local sampleD = math.max(0, d)
		local pos, tang = WaveShark.sample(path, sampleD)
		setArrowCFrame(clone, pos, tang, spin0)
		local visible = d >= 0
		if not visible then
			setModelHidden(clone, true)
		end
		table.insert(sharkArrowPreviews, {
			model = clone,
			dist = d,
			spin = spin0,
			alive = true,
			visible = visible,
		})
	end
end

function WaveArrowPreview.startGreen(opts: StartOpts?)
	local h = host
	if not h then
		return
	end
	local playSound = if opts and opts.playSound ~= nil then opts.playSound else true

	clearGreenTrains()
	local paths: { PathLike } = {}
	if h.getFishPaths then
		paths = h.getFishPaths()
	else
		local one = h.getFishPath()
		if one then
			paths = { one }
		end
	end
	local tmpl = getGreenArrowsTemplate()
	if #paths == 0 or not tmpl then
		return
	end
	if playSound then
		playArrowStartSound()
	end
	local folderFx = h.ensureFolder()
	local labelText = if opts and opts.greenLabelText then opts.greenLabelText else ("Wave " .. tostring(math.max(1, h.getWaveIndex())))
	local arrowI = 0
	for _, path in ipairs(paths) do
		-- Train queues behind the start; only the leader begins on-path.
		for i = 1, C.ARROW_TRAIN_COUNT do
			arrowI += 1
			local d = -(i - 1) * C.ARROW_PATH_SPACING
			local clone = WaveEntityPool.acquireArrows("OceanTD_GreenArrows_" .. tostring(arrowI), folderFx)
			if not clone then
				break
			end
			local spin0 = (arrowI - 1) * 0.55
			local sampleD = math.max(0, d)
			local pos, tang = h.sampleFishPath(path, sampleD)
			setArrowCFrame(clone, pos, tang, spin0)
			local visible = d >= 0
			if not visible then
				setModelHidden(clone, true)
			end
			table.insert(arrowPreviews, {
				model = clone,
				dist = d,
				spin = spin0,
				alive = true,
				path = path :: any,
				visible = visible,
			})
			if i % C.ARROW_LABEL_EVERY == 0 then
				local part = createWavePathLabel(labelText, pos, folderFx)
				if not visible then
					local bb = part:FindFirstChild("Label")
					if bb and bb:IsA("BillboardGui") then
						bb.Enabled = false
					end
				end
				table.insert(wavePathLabels, {
					part = part,
					dist = d,
					alive = true,
					path = path,
					visible = visible,
				})
			end
		end
	end
end

function WaveArrowPreview.startRed(opts: StartOpts?)
	if WaveArrowPreview.hasActiveRedTrains() then
		return
	end
	local includeShark = if opts and opts.includeShark ~= nil then opts.includeShark else true
	local forceGround = if opts and opts.forceGroundTrains ~= nil then opts.forceGroundTrains else false
	local redLabelText = if opts then opts.redLabelText else nil
	redSpawnPending = true
	startGeneration += 1
	local gen = startGeneration
	task.defer(function()
		if gen ~= startGeneration then
			return
		end
		startCrabArrowPreview(forceGround, redLabelText)
		if includeShark then
			startSharkArrowPreview()
		end
		if gen == startGeneration then
			redSpawnPending = false
		end
	end)
end

function WaveArrowPreview.start(opts: StartOpts?)
	clearGreenTrains()
	clearRedTrains()
	WaveArrowPreview.startGreen(opts)
	WaveArrowPreview.startRed(opts)
end

function WaveArrowPreview.tick(dt: number)
	local h = host
	if not h then
		return
	end
	local fallbackPath = h.getFishPath()
	local speed = C.FISH_SPEED * C.ARROW_SPEED_MULT * tickSpeedMult
	if fallbackPath or #arrowPreviews > 0 then
		for i = #arrowPreviews, 1, -1 do
			local preview = arrowPreviews[i]
			local path = (preview.path :: any) or fallbackPath
			if not preview.alive or not preview.model.Parent or not path then
				WaveEntityPool.releaseArrows(preview.model)
				table.remove(arrowPreviews, i)
				continue
			end
			preview.dist += speed * dt
			preview.spin += C.ARROW_SPIN_RAD_PER_SEC * dt
			if preview.dist < 0 then
				continue
			end
			if preview.visible ~= true then
				preview.visible = true
				setModelHidden(preview.model, false)
			end
			if preview.dist >= path.totalLen then
				preview.alive = false
				WaveEntityPool.releaseArrows(preview.model)
				table.remove(arrowPreviews, i)
				continue
			end
			local pos, tang = h.sampleFishPath(path, preview.dist)
			setArrowCFrame(preview.model, pos, tang, preview.spin)
		end

		for i = #wavePathLabels, 1, -1 do
			local label = wavePathLabels[i]
			local path = label.path or fallbackPath
			if not label.alive or not label.part.Parent or not path then
				if label.part.Parent then
					label.part:Destroy()
				end
				table.remove(wavePathLabels, i)
				continue
			end
			label.dist += speed * dt
			if label.dist < 0 then
				continue
			end
			if label.visible ~= true then
				label.visible = true
				local bb = label.part:FindFirstChild("Label")
				if bb and bb:IsA("BillboardGui") then
					bb.Enabled = true
				end
			end
			if label.dist >= path.totalLen then
				label.alive = false
				label.part:Destroy()
				table.remove(wavePathLabels, i)
				continue
			end
			local pos = h.sampleFishPath(path, label.dist)
			label.part.CFrame = CFrame.new(pos)
		end
	end

	local groundPaths = h.getGroundPaths()
	if #groundPaths > 0 then
		local crabSpeed = C.FISH_SPEED * C.CRAB_SPEED_MULT * C.ARROW_SPEED_MULT * tickSpeedMult
		local lift = Vector3.new(0, C.CRAB_ARROW_Y_LIFT, 0)
		for i = #crabArrowPreviews, 1, -1 do
			local preview = crabArrowPreviews[i]
			local ground = preview.path
			if not preview.alive or not preview.model.Parent or not ground then
				WaveEntityPool.releaseRedArrows(preview.model)
				table.remove(crabArrowPreviews, i)
				continue
			end
			preview.dist += crabSpeed * dt
			preview.spin += C.ARROW_SPIN_RAD_PER_SEC * dt
			if preview.dist < 0 then
				continue
			end
			if preview.visible ~= true then
				preview.visible = true
				setModelHidden(preview.model, false)
			end
			if preview.dist >= ground.totalLen then
				preview.alive = false
				WaveEntityPool.releaseRedArrows(preview.model)
				table.remove(crabArrowPreviews, i)
				continue
			end
			local pos, tang = WaveCrab.sample(ground, preview.dist)
			setArrowCFrame(preview.model, pos + lift, tang, preview.spin)
		end
		for i = #crabPathLabels, 1, -1 do
			local label = crabPathLabels[i]
			local ground = label.groundPath
			if not label.alive or not label.part.Parent or not ground then
				if label.part.Parent then
					label.part:Destroy()
				end
				table.remove(crabPathLabels, i)
				continue
			end
			label.dist += crabSpeed * dt
			if label.dist < 0 then
				continue
			end
			if label.visible ~= true then
				label.visible = true
				local bb = label.part:FindFirstChild("Label")
				if bb and bb:IsA("BillboardGui") then
					bb.Enabled = true
				end
			end
			if label.dist >= ground.totalLen then
				label.alive = false
				label.part:Destroy()
				table.remove(crabPathLabels, i)
				continue
			end
			local pos = WaveCrab.sample(ground, label.dist)
			label.part.CFrame = CFrame.new(pos + lift)
		end
	elseif #crabArrowPreviews > 0 or #crabPathLabels > 0 then
		for _, preview in ipairs(crabArrowPreviews) do
			WaveEntityPool.releaseRedArrows(preview.model)
		end
		table.clear(crabArrowPreviews)
		clearCrabPathLabels()
	end

	local sharkPath = h.getSharkPath()
	if sharkPath then
		local sharkSpeed = WaveShark.speed() * C.ARROW_SPEED_MULT * tickSpeedMult
		for i = #sharkArrowPreviews, 1, -1 do
			local preview = sharkArrowPreviews[i]
			if not preview.alive or not preview.model.Parent then
				WaveEntityPool.releaseRedArrows(preview.model)
				table.remove(sharkArrowPreviews, i)
				continue
			end
			preview.dist += sharkSpeed * dt
			preview.spin += C.ARROW_SPIN_RAD_PER_SEC * dt
			if preview.dist < 0 then
				continue
			end
			if preview.visible ~= true then
				preview.visible = true
				setModelHidden(preview.model, false)
			end
			if preview.dist >= sharkPath.totalLen then
				preview.alive = false
				WaveEntityPool.releaseRedArrows(preview.model)
				table.remove(sharkArrowPreviews, i)
				continue
			end
			local pos, tang = WaveShark.sample(sharkPath, preview.dist)
			setArrowCFrame(preview.model, pos, tang, preview.spin)
		end
	elseif #sharkArrowPreviews > 0 then
		for _, preview in ipairs(sharkArrowPreviews) do
			WaveEntityPool.releaseRedArrows(preview.model)
		end
		table.clear(sharkArrowPreviews)
	end
end

return WaveArrowPreview
