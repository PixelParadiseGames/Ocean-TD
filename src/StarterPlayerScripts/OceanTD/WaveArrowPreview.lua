--!strict
--[[
	Green fish-route + red crab/urchin GroundA/B + red shark-route arrow trains.
	Extracted from WaveSim so it stays under Luau's 200-local limit.
	Trains emerge from each path start (negative lead spacing), not pre-filled.
]]

local ContentProvider = game:GetService("ContentProvider")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local Workspace = game:GetService("Workspace")

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
	-- Override path billboard text (planning: "FISH PATH").
	greenLabelText: string?,
	redLabelText: string?,
	-- Unique GroundA/B paths planned for this wave (cycle when more than one).
	hostilePaths: { WaveCrab.PathData }?,
	onHostileDisplayIndex: ((number) -> ())?,
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
local hostileCyclePaths: { WaveCrab.PathData } = {}
local hostileCycleIndex = 1
local hostileCycleCb: ((number) -> ())? = nil
local hostileCycleArmed = false

local arrowSound = Instance.new("Sound")
arrowSound.Name = "OceanTD_WaveArrows"
arrowSound.SoundId = C.ARROW_SOUND_ID
arrowSound.Volume = C.ARROW_ROUND_START_VOLUME or 0.45
arrowSound.Parent = SoundService

local waveAdvanceSound = Instance.new("Sound")
waveAdvanceSound.Name = "OceanTD_WaveAdvance"
waveAdvanceSound.SoundId = C.WAVE_ADVANCE_SOUND_ID or "rbxassetid://78266353371882"
waveAdvanceSound.Volume = C.WAVE_ADVANCE_VOLUME or 1
waveAdvanceSound.Parent = SoundService

task.defer(function()
	pcall(function()
		ContentProvider:PreloadAsync({ arrowSound, waveAdvanceSound })
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
	hostileCycleArmed = false
	table.clear(hostileCyclePaths)
	hostileCycleIndex = 1
	hostileCycleCb = nil
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

function WaveArrowPreview.hasActiveRedCrabTrains(): boolean
	return redSpawnPending or #crabArrowPreviews > 0
end

local planningLegendSg: ScreenGui? = nil
local planningLegendRow: Frame? = nil
local planningLegendLabel: TextLabel? = nil
local legendAnimToken = 0
local legendAnimConn: RBXScriptConnection? = nil
local legendCinematicActive = false
local legendCinematicPlayed = false -- one hold+path run per show cycle (until hidden)

local LEGEND_HOLD_SEC = 3
local LEGEND_APPROACH_SEC = 1.05 -- bottom-center → path start (smooth, no snap)
local LEGEND_FOLLOW_SEC = 6
local LEGEND_HOLD_TEXT_SIZE = 42
local LEGEND_FOLLOW_TEXT_SIZE = 34
local LEGEND_HOLD_Y = -36
local LEGEND_PATH_Y_LIFT = 2.4

local function smoothstep(t: number): number
	local u = math.clamp(t, 0, 1)
	return u * u * (3 - 2 * u)
end

local function pathScreenPoint(h: Host, path: PathLike, dist: number, cam: Camera): (Vector2?, boolean)
	local worldPos = h.sampleFishPath(path, math.clamp(dist, 0, path.totalLen))
	local sp, onScreen = cam:WorldToViewportPoint(worldPos + Vector3.new(0, LEGEND_PATH_Y_LIFT, 0))
	if sp.Z <= 0 then
		return nil, false
	end
	return Vector2.new(sp.X, sp.Y), onScreen == true
end

local function stopPlanningLegendAnim()
	legendAnimToken += 1
	legendCinematicActive = false
	if legendAnimConn then
		legendAnimConn:Disconnect()
		legendAnimConn = nil
	end
end

local function resetPlanningLegendHoldLayout()
	local row = planningLegendRow
	local lbl = planningLegendLabel
	if row then
		row.AnchorPoint = Vector2.new(0.5, 1)
		row.Position = UDim2.new(0.5, 0, 1, LEGEND_HOLD_Y)
	end
	if lbl then
		lbl.TextSize = LEGEND_HOLD_TEXT_SIZE
		lbl.TextTransparency = 0
		lbl.TextStrokeTransparency = 0.35
		lbl.Visible = true
	end
end

local function ensurePlanningLegend(): ScreenGui
	if planningLegendSg and planningLegendSg.Parent and planningLegendLabel and planningLegendRow then
		return planningLegendSg
	end
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
	row.Position = UDim2.new(0.5, 0, 1, LEGEND_HOLD_Y)
	row.Size = UDim2.fromOffset(0, 48)
	row.AutomaticSize = Enum.AutomaticSize.X
	row.BackgroundTransparency = 1
	row.Parent = sg

	-- Red / dangerous trains are off — legend is friendly-only.
	local lbl = Instance.new("TextLabel")
	lbl.Name = "Friendly"
	lbl.BackgroundTransparency = 1
	lbl.AutomaticSize = Enum.AutomaticSize.XY
	lbl.Size = UDim2.fromOffset(0, 48)
	lbl.Font = UiTheme.Font
	lbl.TextSize = LEGEND_HOLD_TEXT_SIZE
	lbl.Text = "FISH PATH"
	lbl.TextColor3 = Color3.fromRGB(40, 255, 120)
	lbl.TextStrokeTransparency = 0.35
	lbl.TextStrokeColor3 = Color3.new(0, 0, 0)
	lbl.Parent = row

	planningLegendSg = sg
	planningLegendRow = row
	planningLegendLabel = lbl
	return sg
end

local function startPlanningLegendPathCinematic()
	-- Don't restart if already running or finished this empty-plot show cycle.
	if legendCinematicActive or legendCinematicPlayed then
		return
	end
	stopPlanningLegendAnim()
	local sg = ensurePlanningLegend()
	local row = planningLegendRow
	local lbl = planningLegendLabel
	if not row or not lbl then
		return
	end
	sg.Enabled = true
	legendCinematicActive = true
	legendCinematicPlayed = false
	resetPlanningLegendHoldLayout()

	local my = legendAnimToken
	local t0 = os.clock()
	local holdScreen: Vector2? = nil -- captured at end of hold for smooth approach
	legendAnimConn = RunService.RenderStepped:Connect(function()
		if my ~= legendAnimToken then
			return
		end
		local rowNow = planningLegendRow
		local lblNow = planningLegendLabel
		if not rowNow or not lblNow or not sg.Parent then
			stopPlanningLegendAnim()
			return
		end

		local elapsed = os.clock() - t0
		local h = host
		local path = if h then h.getFishPath() else nil
		local cam = Workspace.CurrentCamera

		if elapsed < LEGEND_HOLD_SEC then
			-- Large bottom-center hold.
			rowNow.AnchorPoint = Vector2.new(0.5, 1)
			rowNow.Position = UDim2.new(0.5, 0, 1, LEGEND_HOLD_Y)
			rowNow.Visible = true
			lblNow.TextSize = LEGEND_HOLD_TEXT_SIZE
			lblNow.TextTransparency = 0
			lblNow.TextStrokeTransparency = 0.35
			local ap = rowNow.AbsolutePosition
			local asz = rowNow.AbsoluteSize
			if asz.X > 1 and asz.Y > 1 then
				holdScreen = Vector2.new(ap.X + asz.X * 0.5, ap.Y + asz.Y * 0.5)
			end
			return
		end

		local afterHold = elapsed - LEGEND_HOLD_SEC
		local approachEnd = LEGEND_APPROACH_SEC
		local followEnd = approachEnd + LEGEND_FOLLOW_SEC

		-- Phase 2: ease from bottom-center to path start (W1 / dist 0).
		if afterHold < approachEnd then
			local a = smoothstep(afterHold / math.max(1e-3, approachEnd))
			rowNow.AnchorPoint = Vector2.new(0.5, 0.5)
			lblNow.TextTransparency = 0
			lblNow.TextStrokeTransparency = 0.35
			lblNow.TextSize = LEGEND_HOLD_TEXT_SIZE + (LEGEND_FOLLOW_TEXT_SIZE - LEGEND_HOLD_TEXT_SIZE) * a * 0.35
			local from = holdScreen
			if not from then
				local vp = if cam then cam.ViewportSize else Vector2.new(1280, 720)
				from = Vector2.new(vp.X * 0.5, vp.Y + LEGEND_HOLD_Y)
			end
			local to = from
			if h and path and path.totalLen > 0.5 and cam then
				local startPt = pathScreenPoint(h, path, 0, cam)
				if startPt then
					to = startPt
				end
			end
			local x = from.X + (to.X - from.X) * a
			local y = from.Y + (to.Y - from.Y) * a
			rowNow.Visible = true
			rowNow.Position = UDim2.fromOffset(x, y)
			return
		end

		-- Phase 3: travel start → end along the path while fading.
		local u = math.clamp((afterHold - approachEnd) / LEGEND_FOLLOW_SEC, 0, 1)
		local eu = smoothstep(u)
		if h and path and path.totalLen > 0.5 and cam then
			local dist = eu * path.totalLen
			local pt, onScreen = pathScreenPoint(h, path, dist, cam)
			rowNow.AnchorPoint = Vector2.new(0.5, 0.5)
			if pt and onScreen then
				rowNow.Visible = true
				rowNow.Position = UDim2.fromOffset(pt.X, pt.Y)
			elseif pt then
				rowNow.Visible = false
			else
				rowNow.Visible = false
			end
		else
			rowNow.AnchorPoint = Vector2.new(0.5, 1)
			rowNow.Position = UDim2.new(0.5, 0, 1, LEGEND_HOLD_Y)
			rowNow.Visible = true
		end

		lblNow.TextSize = LEGEND_HOLD_TEXT_SIZE + (LEGEND_FOLLOW_TEXT_SIZE - LEGEND_HOLD_TEXT_SIZE) * (0.35 + 0.65 * u)
		lblNow.TextTransparency = u
		lblNow.TextStrokeTransparency = 0.35 + 0.65 * u

		if afterHold >= followEnd or u >= 1 then
			legendCinematicPlayed = true
			stopPlanningLegendAnim()
			sg.Enabled = false
			resetPlanningLegendHoldLayout()
			if rowNow then
				rowNow.Visible = true
			end
		end
	end)
end

function WaveArrowPreview.setPlanningLegendVisible(visible: boolean)
	local sg = ensurePlanningLegend()
	if visible == true then
		startPlanningLegendPathCinematic()
	else
		stopPlanningLegendAnim()
		legendCinematicPlayed = false -- allow one fresh run next time it is shown
		sg.Enabled = false
		resetPlanningLegendHoldLayout()
		if planningLegendRow then
			planningLegendRow.Visible = true
		end
	end
end

function WaveArrowPreview.isPlanningLegendVisible(): boolean
	local sg = planningLegendSg
	return sg ~= nil and sg.Parent ~= nil and sg.Enabled == true
end

function WaveArrowPreview.setTickSpeedMult(mult: number)
	tickSpeedMult = math.max(0.05, mult)
end

local function playArrowStartSound()
	local vol = C.ARROW_ROUND_START_VOLUME or 0.45
	WaveEntityPool.playSound("arrow", arrowSound, 1, vol, true)
end

-- Wave 2+: next-wave sting at full volume (not the half-vol round-start arrow).
function WaveArrowPreview.playWaveAdvanceSound()
	-- Keep SoundId live so consts edits apply without module reload mixups.
	waveAdvanceSound.SoundId = C.WAVE_ADVANCE_SOUND_ID or "rbxassetid://117570443671176"
	local vol = C.WAVE_ADVANCE_VOLUME or 1
	WaveEntityPool.playSound("waveAdvance", waveAdvanceSound, 1, vol, true)
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

local function startCrabArrowPreviewOnPath(path: WaveCrab.PathData, redLabelText: string?)
	local h = host
	if not h or path.totalLen <= 0.5 then
		return
	end
	for _, preview in ipairs(crabArrowPreviews) do
		WaveEntityPool.releaseRedArrows(preview.model)
	end
	table.clear(crabArrowPreviews)
	clearCrabPathLabels()
	local folderFx = h.ensureFolder()
	local lift = Vector3.new(0, C.CRAB_ARROW_Y_LIFT, 0)
	-- Leader at dist 0; followers queue behind the start and emerge one by one.
	for i = 1, C.CRAB_ARROW_COUNT do
		local d = -(i - 1) * C.CRAB_ARROW_PATH_SPACING
		local clone = WaveEntityPool.acquireRedArrows(
			"OceanTD_RedArrows_" .. tostring(i),
			folderFx,
			C.CRAB_ARROW_COLOR
		)
		if not clone then
			break
		end
		local spin0 = (i - 1) * 0.55
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

local function notifyHostileDisplayIndex()
	local cb = hostileCycleCb
	if cb then
		cb(hostileCycleIndex)
	end
end

local function startCrabArrowPreview(forceGround: boolean, redLabelText: string?)
	local h = host
	if not h then
		return
	end
	local paths = if #hostileCyclePaths > 0 then hostileCyclePaths else h.getGroundPaths()
	if #paths == 0 then
		return
	end
	if not forceGround and WaveCrab.expectedCount() <= 0 and WaveUrchin.expectedCount() <= 0 then
		return
	end
	hostileCycleIndex = math.clamp(hostileCycleIndex, 1, #paths)
	startCrabArrowPreviewOnPath(paths[hostileCycleIndex], redLabelText)
	notifyHostileDisplayIndex()
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
	startGeneration += 1
	redSpawnPending = false
	clearRedTrains()
	table.clear(hostileCyclePaths)
	hostileCycleIndex = 1
	hostileCycleCb = if opts then opts.onHostileDisplayIndex else nil
	hostileCycleArmed = false
	local paths = if opts and opts.hostilePaths then opts.hostilePaths else nil
	if paths and #paths > 0 then
		for _, p in ipairs(paths) do
			table.insert(hostileCyclePaths, p)
		end
	end
	local force = opts ~= nil and opts.forceGroundTrains == true
	local label = if opts then opts.redLabelText else nil
	if #hostileCyclePaths == 0 and not force then
		if WaveCrab.expectedCount() <= 0 and WaveUrchin.expectedCount() <= 0 then
			return
		end
	end
	if #hostileCyclePaths == 0 then
		local h = host
		if h then
			for _, p in ipairs(h.getGroundPaths()) do
				table.insert(hostileCyclePaths, p)
			end
		end
	end
	if #hostileCyclePaths == 0 then
		return
	end
	hostileCycleArmed = true
	startCrabArrowPreview(force, label)
	if opts and opts.includeShark == true then
		startSharkArrowPreview()
	end
end

function WaveArrowPreview.advanceHostileCycle()
	if not hostileCycleArmed or #hostileCyclePaths == 0 then
		return
	end
	if #crabArrowPreviews > 0 or redSpawnPending then
		return
	end
	if #hostileCyclePaths > 1 then
		hostileCycleIndex = (hostileCycleIndex % #hostileCyclePaths) + 1
	end
	startCrabArrowPreviewOnPath(hostileCyclePaths[hostileCycleIndex], nil)
	notifyHostileDisplayIndex()
end

function WaveArrowPreview.start(opts: StartOpts?)
	clearGreenTrains()
	clearRedTrains()
	WaveArrowPreview.startGreen(opts)
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
