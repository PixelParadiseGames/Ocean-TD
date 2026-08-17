--!strict
--[[
	Plot Size unlock cinematic:
	1) Close skills bubbles
	2) Camera → ChangeSizeCam looking at ChangeSizeCamFocus, hold 1s
	3) Tween translucent plot footprint old→new size (reef heart moves with it)
	4) Camera restore over 1s

	Also hides Studio PlotSizes template boxes (keep cams).
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local Constants = require(oceanRoot:WaitForChild("Shared"):WaitForChild("Constants"))
local SkillStages = require(oceanRoot:WaitForChild("Shared"):WaitForChild("SkillStages"))
local Remotes = require(oceanRoot:WaitForChild("Remotes"))

local ClientPlot = require(script.Parent:WaitForChild("ClientPlot"))

local PlotSizeCinematic = {}

local HOLD_SEC = 1.0
local CAM_IN_SEC = 0.55
local CAM_OUT_SEC = 1.0
local GROW_SEC = 1.15
local GROW_COLOR = Color3.fromRGB(80, 220, 160)

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local busy = false
local token = 0

local function forceCloseSkills()
	playerGui:SetAttribute("OceanTD_ForceCloseSkills", os.clock())
end

local function forceCloseFreeCam()
	-- FreeCam RenderStepped owns Scriptable cam — must release before cinematic tweens.
	playerGui:SetAttribute("OceanTD_ForceCloseFreeCam", os.clock())
end

local function getPlotSizesFolder(): Instance?
	local plot = ClientPlot.get()
	if not plot then
		return nil
	end
	-- Prefer local plot décor clone; fall back to master + remap.
	if plot.plotId ~= "Plot1" then
		local idx = tonumber(string.match(plot.plotId, "%d+"))
		if idx then
			local static = Workspace:FindFirstChild(Constants.STATIC_PLOT_PREFIX .. tostring(idx))
			local folder = static and static:FindFirstChild(SkillStages.PLOT_SIZES_FOLDER)
			if folder then
				return folder
			end
		end
	end
	local master = Workspace:FindFirstChild(Constants.MASTER_DECOR_NAME)
	return master and master:FindFirstChild(SkillStages.PLOT_SIZES_FOLDER)
end

local function findSizePart(folder: Instance, stage: number): BasePart?
	local name = SkillStages.plotSizePartName(stage)
	local p = folder:FindFirstChild(name)
	if p and p:IsA("BasePart") then
		return p
	end
	return nil
end

local function hideTemplateBoxes(folder: Instance)
	for _, name in pairs(SkillStages.plotSizePartNames()) do
		local p = folder:FindFirstChild(name)
		if p and p:IsA("BasePart") then
			p.Transparency = 1
			p.CanCollide = false
			p.CanQuery = false
			p.CanTouch = false
			p.CastShadow = false
		end
	end
end

local function resolveCamParts(folder: Instance): (BasePart?, BasePart?)
	local cam = folder:FindFirstChild(SkillStages.CHANGE_SIZE_CAM)
	local focus = folder:FindFirstChild(SkillStages.CHANGE_SIZE_CAM_FOCUS)
	local camPart = if cam and cam:IsA("BasePart") then cam else nil
	local focusPart = if focus and focus:IsA("BasePart") then focus else nil
	return camPart, focusPart
end

local function camGoalCFrame(camPart: BasePart, focusPart: BasePart): CFrame
	local plot = ClientPlot.get()
	local camPos = camPart.Position
	local focusPos = focusPart.Position
	if plot and plot.plotId ~= "Plot1" then
		local folder = camPart.Parent
		local masterDecor = Workspace:FindFirstChild(Constants.MASTER_DECOR_NAME)
		local onMaster = masterDecor and folder and folder:IsDescendantOf(masterDecor)
		if onMaster then
			camPos = ClientPlot.remapFromPlot1(camPos)
			focusPos = ClientPlot.remapFromPlot1(focusPos)
		end
	end
	return CFrame.lookAt(camPos, focusPos)
end

local function tweenCameraTo(goal: CFrame, duration: number, my: number): boolean
	local cam = Workspace.CurrentCamera
	if not cam then
		return false
	end
	local start = cam.CFrame
	local t0 = os.clock()
	while os.clock() - t0 < duration do
		if my ~= token then
			return false
		end
		local u = math.clamp((os.clock() - t0) / duration, 0, 1)
		local e = u * u * (3 - 2 * u)
		cam.CFrame = start:Lerp(goal, e)
		RunService.RenderStepped:Wait()
	end
	if my == token then
		cam.CFrame = goal
	end
	return my == token
end

local function makeGrowBox(cf: CFrame, size: Vector3): BasePart
	local p = Instance.new("Part")
	p.Name = "OceanTD_PlotGrowViz"
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.ForceField
	p.Color = GROW_COLOR
	p.Transparency = 0.45
	p.Size = size
	p.CFrame = cf
	p.Parent = Workspace
	return p
end

local function templateWorldPose(part: BasePart): CFrame
	local plot = ClientPlot.get()
	if not plot then
		return part.CFrame
	end
	-- StaticPlot clones are already remapped; MasterPlotDecor needs remap on Plot2+.
	local masterDecor = Workspace:FindFirstChild(Constants.MASTER_DECOR_NAME)
	local onMaster = masterDecor ~= nil and part:IsDescendantOf(masterDecor)
	if onMaster and plot.plotId ~= "Plot1" then
		return ClientPlot.remapCFrameFromPlot1(part.CFrame)
	end
	return part.CFrame
end

local function tweenGrowBox(
	part: BasePart,
	fromSize: Vector3,
	toSize: Vector3,
	fromCf: CFrame,
	toCf: CFrame,
	duration: number,
	my: number,
	heartFrom: Vector3?,
	heartTo: Vector3?
)
	local WaveEndVfx = require(script.Parent:WaitForChild("WaveEndVfx"))
	if heartFrom then
		WaveEndVfx.setRouteEndWorldPos(heartFrom)
	end
	local t0 = os.clock()
	while os.clock() - t0 < duration do
		if my ~= token or not part.Parent then
			return
		end
		local u = math.clamp((os.clock() - t0) / duration, 0, 1)
		local e = 1 - (1 - u) * (1 - u)
		part.Size = fromSize:Lerp(toSize, e)
		part.CFrame = fromCf:Lerp(toCf, e)
		if heartFrom and heartTo then
			WaveEndVfx.setRouteEndWorldPos(heartFrom:Lerp(heartTo, e))
		end
		local plot = ClientPlot.get()
		if plot then
			ClientPlot.set({
				plotId = plot.plotId,
				cframe = part.CFrame,
				size = part.Size,
				spawnCFrame = plot.spawnCFrame,
				plot1CFrame = plot.plot1CFrame,
				ringCFrame = plot.ringCFrame,
			})
		end
		RunService.RenderStepped:Wait()
	end
	if part.Parent and my == token then
		part.Size = toSize
		part.CFrame = toCf
		if heartTo then
			WaveEndVfx.setRouteEndWorldPos(heartTo)
		end
	end
end

function PlotSizeCinematic.isBusy(): boolean
	return busy
end

export type PlayPoses = {
	prevCFrame: CFrame?,
	prevSize: Vector3?,
	cframe: CFrame?,
	size: Vector3?,
	ringCFrame: CFrame?,
	plot1CFrame: CFrame?,
	spawnCFrame: CFrame?,
	plotId: string?,
}

function PlotSizeCinematic.play(prevStage: number, newStage: number, opts: { skipCamera: boolean?, poses: PlayPoses? }?)
	if busy then
		return
	end
	busy = true
	token += 1
	local my = token
	local skipCam = opts ~= nil and opts.skipCamera == true
	local poses = if opts then opts.poses else nil

	local WaveEndVfx = require(script.Parent:WaitForChild("WaveEndVfx"))
	WaveEndVfx.setRouteHeartDriveLocked(true)
	local parkFrom = WaveEndVfx.getRouteEndWorldPosForStage(prevStage)
	if parkFrom then
		WaveEndVfx.setRouteEndWorldPos(parkFrom)
	end

	playerGui:SetAttribute("OceanTD_PlotSizeCinematicBusy", true)
	forceCloseSkills()
	forceCloseFreeCam()
	task.wait(0.05)

	local folder = getPlotSizesFolder()
	if folder then
		hideTemplateBoxes(folder)
	end

	local fromPart = if folder then findSizePart(folder, prevStage) else nil
	local toPart = if folder then findSizePart(folder, newStage) else nil
	local plot = ClientPlot.get()

	-- Prefer server-authored poses; fall back to Studio template parts.
	local fromSize = (poses and poses.prevSize)
		or (if fromPart then fromPart.Size elseif plot then plot.size else Vector3.new(64, 20, 64))
	local toSize = (poses and poses.size)
		or (if toPart then toPart.Size elseif plot then plot.size else fromSize)
	local fromCf = (poses and poses.prevCFrame)
		or (if fromPart then templateWorldPose(fromPart) elseif plot then plot.cframe else CFrame.new())
	local toCf = (poses and poses.cframe)
		or (if toPart then templateWorldPose(toPart) elseif plot then plot.cframe else fromCf)

	-- Keep the CURRENT (old) outline through the camera move — do not snap to new size yet.
	if plot then
		ClientPlot.set({
			plotId = plot.plotId,
			cframe = fromCf,
			size = fromSize,
			spawnCFrame = (poses and poses.spawnCFrame) or plot.spawnCFrame,
			plot1CFrame = (poses and poses.plot1CFrame) or plot.plot1CFrame,
			ringCFrame = (poses and poses.ringCFrame) or plot.ringCFrame,
		})
	end

	local cam = Workspace.CurrentCamera
	local savedType: Enum.CameraType? = nil
	local savedCf: CFrame? = nil
	local savedSubject: Instance? = nil
	local function restorePlayerCamera(tweenBack: boolean)
		if skipCam then
			return
		end
		cam = Workspace.CurrentCamera
		if not cam then
			return
		end
		local char = player.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		-- Always re-seat on the avatar — Scriptable cinematic can leave focus feeling "stuck".
		if hum then
			cam.CameraSubject = hum
		elseif savedSubject then
			cam.CameraSubject = savedSubject
		end
		if tweenBack and savedCf and my == token then
			tweenCameraTo(savedCf, CAM_OUT_SEC, my)
		end
		local restore = savedType or Enum.CameraType.Custom
		if restore == Enum.CameraType.Scriptable then
			restore = Enum.CameraType.Custom
		end
		cam.CameraType = restore
		-- Wave session uses Humanoid.CameraOffset; re-assert follow after Scriptable.
		playerGui:SetAttribute("OceanTD_RestoreWaveCam", os.clock())
	end

	local function finishCinematic(okCommit: boolean)
		local WaveEndVfx = require(script.Parent:WaitForChild("WaveEndVfx"))
		-- Unlock then snap to final stage end (tween already parked there on success).
		WaveEndVfx.setRouteHeartDriveLocked(false)
		WaveEndVfx.syncToPlotSizeStage(newStage)
		local WaveSim = require(script.Parent:WaitForChild("WaveSim"))
		if WaveSim.isRunning() then
			WaveSim.rebuildRouteForPlotSize(newStage)
		end
		if okCommit then
			pcall(function()
				Remotes.get("ReportPlotSizeCinematicDone"):FireServer(newStage)
			end)
		end
		if my == token then
			busy = false
		end
		playerGui:SetAttribute("OceanTD_PlotSizeCinematicBusy", false)
		playerGui:SetAttribute("OceanTD_SkillsUiRestore", os.clock())
	end

	if cam and not skipCam then
		savedType = cam.CameraType
		savedCf = cam.CFrame
		savedSubject = cam.CameraSubject
		cam.CameraType = Enum.CameraType.Scriptable
	end

	local camPart: BasePart? = nil
	local focusPart: BasePart? = nil
	if folder then
		camPart, focusPart = resolveCamParts(folder)
	end
	if cam and camPart and focusPart and not skipCam then
		local goal = camGoalCFrame(camPart, focusPart)
		if not tweenCameraTo(goal, CAM_IN_SEC, my) then
			restorePlayerCamera(false)
			finishCinematic(true)
			return
		end
		local holdUntil = os.clock() + HOLD_SEC
		while os.clock() < holdUntil do
			if my ~= token then
				restorePlayerCamera(false)
				finishCinematic(false)
				return
			end
			cam.CFrame = goal
			RunService.RenderStepped:Wait()
		end
	elseif not skipCam then
		warn("[PLOT] ChangeSizeCam / Focus missing under PlotSizes")
		task.wait(HOLD_SEC)
	end

	if my ~= token then
		restorePlayerCamera(false)
		finishCinematic(false)
		return
	end

	-- Grow tween is the first time the outline leaves the old stage size.
	-- Move the reef heart old→new route end in lockstep with the footprint.
	local WaveEndVfx = require(script.Parent:WaitForChild("WaveEndVfx"))
	local heartFrom = WaveEndVfx.getRouteEndWorldPosForStage(prevStage)
	local heartTo = WaveEndVfx.getRouteEndWorldPosForStage(newStage)
	local box = makeGrowBox(fromCf, fromSize)
	tweenGrowBox(box, fromSize, toSize, fromCf, toCf, GROW_SEC, my, heartFrom, heartTo)
	if box.Parent then
		local fade = TweenService:Create(box, TweenInfo.new(0.35), { Transparency = 1 })
		fade:Play()
		fade.Completed:Wait()
		box:Destroy()
	end

	plot = ClientPlot.get()
	if plot then
		ClientPlot.set({
			plotId = (poses and poses.plotId) or plot.plotId,
			cframe = toCf,
			size = toSize,
			spawnCFrame = (poses and poses.spawnCFrame) or plot.spawnCFrame,
			plot1CFrame = (poses and poses.plot1CFrame) or plot.plot1CFrame,
			ringCFrame = (poses and poses.ringCFrame) or plot.ringCFrame,
		})
	end

	if my == token then
		restorePlayerCamera(true)
		finishCinematic(true)
	else
		restorePlayerCamera(false)
		finishCinematic(false)
	end
end

-- Hide templates once décor is available.
task.spawn(function()
	for _ = 1, 40 do
		local master = Workspace:FindFirstChild(Constants.MASTER_DECOR_NAME)
		local masterFolder = master and master:FindFirstChild(SkillStages.PLOT_SIZES_FOLDER)
		if masterFolder then
			hideTemplateBoxes(masterFolder)
		end
		local folder = getPlotSizesFolder()
		if folder and folder ~= masterFolder then
			hideTemplateBoxes(folder)
		end
		if masterFolder or folder then
			break
		end
		task.wait(0.5)
	end
	Workspace.ChildAdded:Connect(function(ch)
		if string.sub(ch.Name, 1, #Constants.STATIC_PLOT_PREFIX) == Constants.STATIC_PLOT_PREFIX then
			task.defer(function()
				local folder = ch:FindFirstChild(SkillStages.PLOT_SIZES_FOLDER)
				if folder then
					hideTemplateBoxes(folder)
				end
			end)
		end
	end)
end)

Remotes.get("PlotSizeChanged").OnClientEvent:Connect(function(payload: any)
	if typeof(payload) ~= "table" then
		return
	end
	local prev = SkillStages.clampStage(payload.prevStage)
	local stage = SkillStages.clampStage(payload.stage)
	if payload.reset == true then
		local plot = ClientPlot.get()
		if plot and typeof(payload.size) == "Vector3" then
			ClientPlot.set({
				plotId = plot.plotId,
				cframe = if typeof(payload.cframe) == "CFrame" then payload.cframe else plot.cframe,
				size = payload.size,
				spawnCFrame = plot.spawnCFrame,
				plot1CFrame = plot.plot1CFrame,
				ringCFrame = if typeof(payload.ringCFrame) == "CFrame" then payload.ringCFrame else plot.ringCFrame,
			})
		end
		return
	end
	if stage <= prev then
		return
	end
	task.spawn(function()
		PlotSizeCinematic.play(prev, stage, {
			poses = {
				prevCFrame = if typeof(payload.prevCFrame) == "CFrame" then payload.prevCFrame else nil,
				prevSize = if typeof(payload.prevSize) == "Vector3" then payload.prevSize else nil,
				cframe = if typeof(payload.cframe) == "CFrame" then payload.cframe else nil,
				size = if typeof(payload.size) == "Vector3" then payload.size else nil,
				ringCFrame = if typeof(payload.ringCFrame) == "CFrame" then payload.ringCFrame else nil,
				plot1CFrame = if typeof(payload.plot1CFrame) == "CFrame" then payload.plot1CFrame else nil,
				spawnCFrame = if typeof(payload.spawnCFrame) == "CFrame" then payload.spawnCFrame else nil,
				plotId = if typeof(payload.plotId) == "string" then payload.plotId else nil,
			},
		})
	end)
end)

return PlotSizeCinematic
