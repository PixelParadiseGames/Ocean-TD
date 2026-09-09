--!strict
--[[
	Green fish-route + red crab/urchin GroundA/B + red shark-route arrow trains.
	Extracted from WaveSim so it stays under Luau's 200-local limit.
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

type ArrowPreview = {
	model: Instance,
	dist: number,
	spin: number,
	alive: boolean,
	path: WaveCrab.PathData?, -- set for ground (A/B) red arrows + multi fish routes
}

type WavePathLabel = {
	part: BasePart,
	dist: number,
	alive: boolean,
	path: PathLike?,
}

local host: Host? = nil
local greenArrowsTemplate: Instance? = nil
local arrowsWarned = false
local arrowPreviews: { ArrowPreview } = {}
local crabArrowPreviews: { ArrowPreview } = {}
local sharkArrowPreviews: { ArrowPreview } = {}
local wavePathLabels: { WavePathLabel } = {}

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

function WaveArrowPreview.destroy()
	for _, preview in ipairs(arrowPreviews) do
		WaveEntityPool.releaseArrows(preview.model)
	end
	table.clear(arrowPreviews)
	for _, preview in ipairs(crabArrowPreviews) do
		WaveEntityPool.releaseRedArrows(preview.model)
	end
	table.clear(crabArrowPreviews)
	for _, preview in ipairs(sharkArrowPreviews) do
		WaveEntityPool.releaseRedArrows(preview.model)
	end
	table.clear(sharkArrowPreviews)
	for _, label in ipairs(wavePathLabels) do
		if label.part.Parent then
			label.part:Destroy()
		end
	end
	table.clear(wavePathLabels)
end

local function playArrowStartSound()
	WaveEntityPool.playSound("arrow", arrowSound, 1, 0.9, true)
end

local function createWavePathLabel(text: string, pos: Vector3, parent: Instance): BasePart
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

	local lbl = Instance.new("TextLabel")
	lbl.BackgroundTransparency = 1
	lbl.Size = UDim2.fromScale(1, 1)
	lbl.Font = UiTheme.Font
	lbl.Text = text
	lbl.TextColor3 = Color3.fromRGB(40, 255, 120)
	lbl.TextScaled = true
	lbl.TextStrokeTransparency = 0.25
	lbl.TextStrokeColor3 = Color3.fromRGB(0, 40, 15)
	lbl.Parent = bb

	return part
end

local function startCrabArrowPreview()
	local h = host
	if not h then
		return
	end
	for _, preview in ipairs(crabArrowPreviews) do
		WaveEntityPool.releaseRedArrows(preview.model)
	end
	table.clear(crabArrowPreviews)
	local paths = h.getGroundPaths()
	if #paths == 0 or (WaveCrab.expectedCount() <= 0 and WaveUrchin.expectedCount() <= 0) then
		return
	end
	local folderFx = h.ensureFolder()
	local lift = Vector3.new(0, C.CRAB_ARROW_Y_LIFT, 0)
	local arrowI = 0
	for _, path in ipairs(paths) do
		local d = 0
		for _ = 1, C.CRAB_ARROW_COUNT do
			if d >= path.totalLen - 0.05 then
				break
			end
			arrowI += 1
			local clone = WaveEntityPool.acquireRedArrows(
				"OceanTD_RedArrows_" .. tostring(arrowI),
				folderFx,
				C.CRAB_ARROW_COLOR
			)
			if not clone then
				break
			end
			local spin0 = (arrowI - 1) * 0.55
			local pos, tang = WaveCrab.sample(path, d)
			setArrowCFrame(clone, pos + lift, tang, spin0)
			table.insert(crabArrowPreviews, {
				model = clone,
				dist = d,
				spin = spin0,
				alive = true,
				path = path,
			})
			d += C.CRAB_ARROW_PATH_SPACING
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
	local d = 0
	for i = 1, C.CRAB_ARROW_COUNT do
		if d >= path.totalLen - 0.05 then
			break
		end
		local clone = WaveEntityPool.acquireRedArrows(
			"OceanTD_SharkRedArrows_" .. tostring(i),
			folderFx,
			C.CRAB_ARROW_COLOR
		)
		if not clone then
			break
		end
		local spin0 = (i - 1) * 0.55
		local pos, tang = WaveShark.sample(path, d)
		setArrowCFrame(clone, pos, tang, spin0)
		table.insert(sharkArrowPreviews, {
			model = clone,
			dist = d,
			spin = spin0,
			alive = true,
		})
		d += C.CRAB_ARROW_PATH_SPACING
	end
end

function WaveArrowPreview.start()
	local h = host
	if not h then
		return
	end
	WaveArrowPreview.destroy()
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
	if #paths > 0 and tmpl then
		playArrowStartSound()
		local folderFx = h.ensureFolder()
		local waveText = "Wave " .. tostring(math.max(1, h.getWaveIndex()))
		local arrowI = 0
		for _, path in ipairs(paths) do
			local d = 0
			local i = 0
			while d < path.totalLen - 0.05 do
				i += 1
				arrowI += 1
				local clone = WaveEntityPool.acquireArrows("OceanTD_GreenArrows_" .. tostring(arrowI), folderFx)
				if not clone then
					break
				end
				local spin0 = (arrowI - 1) * 0.55
				local pos, tang = h.sampleFishPath(path, d)
				setArrowCFrame(clone, pos, tang, spin0)
				table.insert(arrowPreviews, {
					model = clone,
					dist = d,
					spin = spin0,
					alive = true,
					path = path :: any,
				})
				if i % C.ARROW_LABEL_EVERY == 0 then
					local part = createWavePathLabel(waveText, pos, folderFx)
					table.insert(wavePathLabels, {
						part = part,
						dist = d,
						alive = true,
						path = path,
					})
				end
				d += C.ARROW_PATH_SPACING
			end
		end
	end
	-- Crab/shark trains next frame so green fish arrows don't share one hitch spike.
	task.defer(function()
		startCrabArrowPreview()
		startSharkArrowPreview()
	end)
end

function WaveArrowPreview.tick(dt: number)
	local h = host
	if not h then
		return
	end
	local fallbackPath = h.getFishPath()
	if not fallbackPath and #arrowPreviews == 0 then
		WaveArrowPreview.destroy()
		return
	end
	local speed = C.FISH_SPEED * C.ARROW_SPEED_MULT
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
		if label.dist >= path.totalLen then
			label.alive = false
			label.part:Destroy()
			table.remove(wavePathLabels, i)
			continue
		end
		local pos = h.sampleFishPath(path, label.dist)
		label.part.CFrame = CFrame.new(pos)
	end

	local groundPaths = h.getGroundPaths()
	if #groundPaths > 0 then
		local crabSpeed = C.FISH_SPEED * C.CRAB_SPEED_MULT * C.ARROW_SPEED_MULT
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
			if preview.dist >= ground.totalLen then
				preview.alive = false
				WaveEntityPool.releaseRedArrows(preview.model)
				table.remove(crabArrowPreviews, i)
				continue
			end
			local pos, tang = WaveCrab.sample(ground, preview.dist)
			setArrowCFrame(preview.model, pos + lift, tang, preview.spin)
		end
	elseif #crabArrowPreviews > 0 then
		for _, preview in ipairs(crabArrowPreviews) do
			WaveEntityPool.releaseRedArrows(preview.model)
		end
		table.clear(crabArrowPreviews)
	end

	local sharkPath = h.getSharkPath()
	if sharkPath then
		local sharkSpeed = WaveShark.speed() * C.ARROW_SPEED_MULT
		for i = #sharkArrowPreviews, 1, -1 do
			local preview = sharkArrowPreviews[i]
			if not preview.alive or not preview.model.Parent then
				WaveEntityPool.releaseRedArrows(preview.model)
				table.remove(sharkArrowPreviews, i)
				continue
			end
			preview.dist += sharkSpeed * dt
			preview.spin += C.ARROW_SPIN_RAD_PER_SEC * dt
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
