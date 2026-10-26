--!strict
--[[
	Client-only plant dig VFX.
	Worker cams (Plot / Fish / Free): dash beside coral → dig 3s → coral rises; dig cam zoom.
	Player Cam: same dust / bubbles / hearts / coral rise at the plant — avatar stays under player control.
]]

local KeyframeSequenceProvider = game:GetService("KeyframeSequenceProvider")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local Workspace = game:GetService("Workspace")

local ClientPlot = require(script.Parent:WaitForChild("ClientPlot"))
local InventoryState = require(script.Parent:WaitForChild("InventoryState"))
local LocalShovel = require(script.Parent:WaitForChild("LocalShovel"))
local PlotCam2 = require(script.Parent:WaitForChild("PlotCam2"))

local ATTR_BUSY = "OceanTD_PlantWorkerBusy"
local ATTR_DIG_CAM = "OceanTD_PlantDigCamBusy"
local ATTR_CAM = "OceanTD_CamCycleMode"

-- Travel a bit longer than the original 0.32s dash; legs animate separately (silly-fast).
local DASH_SEC = 0.95
local WORK_SEC = 3
local DIG_CAM_IN_SEC = 0.55 -- ease into dig close-up during dash → dig
local DIG_CAM_OUT_SEC = 0.675 -- restore prior view after dig (50% slower than 0.45)
local DIG_CAM_OUT_HOLD_SEC = 1 -- linger on dig close-up before restore tween
-- Another 10% farther than the prior close-up (less aggressive zoom).
local DIG_CAM_DIST = 11.314
local DIG_CAM_HEIGHT = 4.0
local DIG_CAM_LOOK_Y = 1.35
local STAND_OFFSET = 1.15 -- slight offset from coral center (stand on/at the plant spot)
local HIP_PAD = 0.35 -- keep soles above sand (HipHeight alone sinks R15 a bit)
local HEART_FIREWORK_MIN = 5
local HEART_FIREWORK_MAX = 10
local HEART_EMOJI = "❤️"
local DIG_CYCLE_SEC = 0.2 -- 5 full up/down cycles per second
local RUN_CYCLE_SEC = 0.14 -- short loop; played at RUN_PLAY_SPEED for cartoon legs
local RUN_PLAY_SPEED = 3.4
local DIG_ANIM_VERSION = 2 -- Action4 dig track primary again (Motor6D-only was overwritten by Animate)
local RUN_ANIM_VERSION = 1
local LAND_SQUASH_SEC = 0.14
local LAND_DIP_STUDS = 0.22
-- Dig torso: upright ↔ lean forward while arms keep flailing.
local DIG_BEND_DEG = 22
local DIG_BEND_CYCLE_SEC = 1.15
local RAY_UP = 60
local RAY_DOWN = 180
local CORAL_BURY_MIN = 2.8
local CORAL_BURY_PAD = 1.2
local DUST_TEXTURE = "rbxasset://textures/particles/smoke_main.dds"
local ICE_BUBBLE_COLOR = Color3.fromRGB(170, 220, 255)
local ICE_BUBBLE_TRANS = 0.5
local ICE_BUBBLE_LIFE_MIN = 2.8
local ICE_BUBBLE_LIFE_MAX = 4.5
-- Discrete S / M / L / XL glass spheres (stud diameter).
local ICE_BUBBLE_SIZES = { 0.55, 1.05, 1.7, 2.5 } :: { number }
local ICE_BUBBLE_SCATTER = 3.2 -- horizontal scatter radius (studs)
local ICE_BUBBLE_RISE = 1.495 -- base studs/sec (+30%); each bubble still rolls +30%–+110% on top
local ICE_BUBBLE_DASH_BLAST = 10 -- radial burst when dash lands
local ICE_BUBBLE_BLAST_SPEED_MIN = 6.5
local ICE_BUBBLE_BLAST_SPEED_MAX = 11
local RUN_SOUND_ID = "rbxassetid://75773150278794"
local WORK_SOUND_ID = "rbxassetid://76312376951471"
local WOW_SOUND_ID = "rbxassetid://109783075001296"
local RUN_FADE_IN_SEC = 0.2
local WORK_FADE_OUT_SEC = 0.5
local RUN_VOL = 0.9
local WORK_VOL = 0.9
local WOW_VOL = 0.95

local PlantWorkerVfx = {}

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui") :: PlayerGui

local playToken = 0
-- Concurrent plant-only digs (ADD MAX batch); avatar dig still uses playToken.
local plantOnlySerial = 0
local plantOnlyBusy = 0
-- Batch VFX budgets (ADD MAX). wowLeft < 0 means unlimited.
local batchBubbleScale = 1
local batchBubblesPerCoral: number? = nil -- hard cap total ice bubbles per dig (e.g. 3 when N>40)
local batchHeartsPerCoral: number? = nil -- fixed heart count per dig (e.g. 5 when N>40)
local batchWowLeft = -1
local batchDustChance = 1 -- fraction of digs that spawn dust hosts
local batchWorkVolScale = 1 -- dig/run loop volume multiplier
local batchWorkSecScale = 1 -- plant-only dig duration multiplier (ADD MAX speed)
local digAnimId: string? = nil
local digAnimVersionRegistered: number? = nil
local digTrack: AnimationTrack? = nil
local digTrackAnimator: Animator? = nil
local runAnimId: string? = nil
local runAnimVersionRegistered: number? = nil
local runTrack: AnimationTrack? = nil
local runTrackAnimator: Animator? = nil
local digBindName = "OceanTD_PlantWorkerDig"
local digBound = false
local digPreRenderConn: RBXScriptConnection? = nil
local digHeartbeatConn: RBXScriptConnection? = nil
local digAnimateScript: Instance? = nil
local digAnimateWasDisabled: boolean? = nil
local digWelds: { Weld } = {}
local digDisabledMotors: { Motor6D } = {}
local DASH_BIND_NAME = "OceanTD_PlantWorkerDash"

-- Active coral rise (restored on cancel/finish).
local risePart: BasePart? = nil
local riseFinalCF: CFrame? = nil
local runSound: Sound? = nil
local workSound: Sound? = nil

-- Dig close-up: stash FreeCam / PlotCam view, Scriptable zoom on avatar, restore after.
local digCamToken = 0
local digCamSavedCf: CFrame? = nil
local digCamSavedType: Enum.CameraType? = nil
local digCamSavedFov: number? = nil
local digCamFollowConn: RBXScriptConnection? = nil
local digCamPlantPos: Vector3? = nil
local digHeldShovel = false

export type PlayOpts = {
	coralPart: BasePart?,
	onDone: (() -> ())?,
	-- Force plant-only VFX (no avatar dash). Default: auto when not in a worker cam.
	skipAvatar: boolean?,
	-- Join-intro: dash/dig even when not in Plot/Fish/Drone cam.
	forceAvatar: boolean?,
	-- Join-intro: cinematic owns the lens — no dig close-up steal.
	skipDigCam: boolean?,
	-- Override dash / dig durations (intro sped-up timeline).
	dashSec: number?,
	workSec: number?,
	-- Multiply ice-bubble emission (ADD MAX uses 0.5 when planting >40).
	bubbleScale: number?,
	-- When false, skip the build-complete "wow" SFX (hearts still play).
	playWow: boolean?,
}

-- ADD MAX batch budgets: bubbles / hearts / wow SFX / dust / dig duration / volume.
function PlantWorkerVfx.beginBatchVfx(opts: {
	bubbleScale: number?,
	bubblesPerCoral: number?,
	heartsPerCoral: number?,
	wowCap: number?,
	dustChance: number?,
	workVolScale: number?,
	workSecScale: number?,
})
	local scale = tonumber(opts and opts.bubbleScale)
	batchBubbleScale = if typeof(scale) == "number" and scale > 0 then scale else 1
	local bpc = tonumber(opts and opts.bubblesPerCoral)
	batchBubblesPerCoral = if typeof(bpc) == "number" and bpc >= 0 then math.floor(bpc) else nil
	local hpc = tonumber(opts and opts.heartsPerCoral)
	batchHeartsPerCoral = if typeof(hpc) == "number" and hpc >= 0 then math.floor(hpc) else nil
	local wowCap = tonumber(opts and opts.wowCap)
	batchWowLeft = if typeof(wowCap) == "number" and wowCap >= 0 then math.floor(wowCap) else -1
	local dust = tonumber(opts and opts.dustChance)
	batchDustChance = if typeof(dust) == "number" then math.clamp(dust, 0, 1) else 1
	local workVol = tonumber(opts and opts.workVolScale)
	batchWorkVolScale = if typeof(workVol) == "number" and workVol >= 0 then math.clamp(workVol, 0, 1) else 1
	local workSec = tonumber(opts and opts.workSecScale)
	batchWorkSecScale = if typeof(workSec) == "number" and workSec > 0 then math.clamp(workSec, 0.25, 1) else 1
end

function PlantWorkerVfx.endBatchVfx()
	batchBubbleScale = 1
	batchBubblesPerCoral = nil
	batchHeartsPerCoral = nil
	batchWowLeft = -1
	batchDustChance = 1
	batchWorkVolScale = 1
	batchWorkSecScale = 1
end

local function isWorkerCam(): boolean
	local m = playerGui:GetAttribute(ATTR_CAM)
	return m == "plotcam" or m == "fishcam" or m == "dronecam"
end

local function shouldSkipAvatar(opts: PlayOpts?): boolean
	if opts and opts.skipAvatar == true then
		return true
	end
	if opts and opts.forceAvatar == true then
		return false
	end
	return not isWorkerCam()
end

-- Auto Plant during a live wave: avatar still dashes/digs, but PlotCam stays player-owned.
local function shouldSkipDigCam(opts: PlayOpts?): boolean
	if opts and opts.skipDigCam == true then
		return true
	end
	local apOk, AutoPlantUI = pcall(function()
		return require(script.Parent:WaitForChild("AutoPlantUI"))
	end)
	if not (apOk and AutoPlantUI and AutoPlantUI.isEnabled and AutoPlantUI.isEnabled()) then
		return false
	end
	local wsOk, WaveSim = pcall(function()
		return require(script.Parent:WaitForChild("WaveSim"))
	end)
	return wsOk and WaveSim and WaveSim.isRunning and WaveSim.isRunning() == true
end

local function setBusy(on: boolean)
	playerGui:SetAttribute(ATTR_BUSY, on == true)
end

local function ensureDigShovel()
	LocalShovel.equip()
	digHeldShovel = true
end

local function releaseDigShovel()
	if not digHeldShovel then
		return
	end
	digHeldShovel = false
	-- Keep shovel if backpack is still open (its own equip owns the prop).
	if InventoryState.isOpen() then
		return
	end
	LocalShovel.unequip()
end

local function setDigCamBusy(on: boolean)
	playerGui:SetAttribute(ATTR_DIG_CAM, on == true)
end

local function digCamGoalCf(hrp: BasePart, plantPos: Vector3, fromCf: CFrame): CFrame
	local focus = hrp.Position + Vector3.new(0, DIG_CAM_LOOK_Y, 0)
	local flat = Vector3.new(fromCf.Position.X - focus.X, 0, fromCf.Position.Z - focus.Z)
	if flat.Magnitude < 0.4 then
		flat = Vector3.new(fromCf.LookVector.X, 0, fromCf.LookVector.Z)
	end
	if flat.Magnitude < 0.1 then
		local away = Vector3.new(hrp.Position.X - plantPos.X, 0, hrp.Position.Z - plantPos.Z)
		flat = if away.Magnitude > 0.1 then away else Vector3.new(0, 0, 1)
	end
	flat = flat.Unit
	local eye = focus + flat * DIG_CAM_DIST + Vector3.new(0, DIG_CAM_HEIGHT, 0)
	return CFrame.lookAt(eye, focus)
end

local function stopDigCamFollow()
	if digCamFollowConn then
		digCamFollowConn:Disconnect()
		digCamFollowConn = nil
	end
end

local function restoreDigCamImmediate()
	stopDigCamFollow()
	setDigCamBusy(false)
	local cam = Workspace.CurrentCamera
	local savedCf = digCamSavedCf
	local savedType = digCamSavedType
	local savedFov = digCamSavedFov
	digCamSavedCf = nil
	digCamSavedType = nil
	digCamSavedFov = nil
	digCamPlantPos = nil
	if not cam then
		return
	end
	if savedCf then
		cam.CFrame = savedCf
	end
	if typeof(savedFov) == "number" then
		cam.FieldOfView = savedFov
	end
	if savedType then
		cam.CameraType = savedType
	end
end

local function endDigCamZoom(token: number)
	if token ~= digCamToken then
		return
	end
	stopDigCamFollow()
	local cam = Workspace.CurrentCamera
	local savedCf = digCamSavedCf
	if not cam or not savedCf then
		restoreDigCamImmediate()
		return
	end
	cam.CameraType = Enum.CameraType.Scriptable
	local fromCf = cam.CFrame
	local t0 = os.clock()
	digCamFollowConn = RunService.RenderStepped:Connect(function()
		if token ~= digCamToken then
			return
		end
		local u = math.clamp((os.clock() - t0) / DIG_CAM_OUT_SEC, 0, 1)
		local a = u * u * (3 - 2 * u)
		cam.CFrame = fromCf:Lerp(savedCf, a)
		if u >= 1 then
			restoreDigCamImmediate()
		end
	end)
end

local function beginDigCamZoom(hrp: BasePart, plantPos: Vector3)
	local cam = Workspace.CurrentCamera
	if not cam then
		return
	end
	digCamToken += 1
	local token = digCamToken
	stopDigCamFollow()
	-- Prefer pre-place PlotCam seat (not the coral place-zoom close-up) so dig-out
	-- tweens to the player's previous view instead of snapping after a coral flash.
	local plotRestore = PlotCam2.claimPlaceZoomRestoreCf()
	digCamSavedCf = plotRestore or cam.CFrame
	digCamSavedType = cam.CameraType
	digCamSavedFov = cam.FieldOfView
	digCamPlantPos = plantPos
	cam.CameraType = Enum.CameraType.Scriptable
	setDigCamBusy(true)

	local t0 = os.clock()
	local fromCf = cam.CFrame
	digCamFollowConn = RunService.RenderStepped:Connect(function()
		if token ~= digCamToken or not hrp.Parent then
			return
		end
		local goal = digCamGoalCf(hrp, plantPos, fromCf)
		local u = math.clamp((os.clock() - t0) / DIG_CAM_IN_SEC, 0, 1)
		local a = u * u * (3 - 2 * u)
		cam.CFrame = fromCf:Lerp(goal, a)
		if u >= 1 then
			-- Keep framed on the digger while they work.
			cam.CFrame = digCamGoalCf(hrp, plantPos, fromCf)
		end
	end)
end

local function getCharacterParts(): (Model?, Humanoid?, BasePart?)
	local character = player.Character
	if not character then
		return nil, nil, nil
	end
	local hum = character:FindFirstChildOfClass("Humanoid")
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if not (hum and hum:IsA("Humanoid") and hrp and hrp:IsA("BasePart")) then
		return nil, nil, nil
	end
	return character, hum, hrp
end

local function getAnimator(hum: Humanoid): Animator
	local animator = hum:FindFirstChildOfClass("Animator")
	if animator then
		return animator
	end
	local created = Instance.new("Animator")
	created.Parent = hum
	return created
end

local function restoreDigAnimate()
	local scriptInst = digAnimateScript
	local wasDisabled = digAnimateWasDisabled
	digAnimateScript = nil
	digAnimateWasDisabled = nil
	if scriptInst and scriptInst.Parent and typeof(wasDisabled) == "boolean" then
		pcall(function()
			(scriptInst :: any).Disabled = wasDisabled
		end)
	end
end

local function clearDigWeldsAndMotors()
	for _, w in ipairs(digWelds) do
		if w.Parent then
			w:Destroy()
		end
	end
	table.clear(digWelds)
	for _, m in ipairs(digDisabledMotors) do
		if m.Parent then
			pcall(function()
				m.Enabled = true
				m.Transform = CFrame.new()
			end)
		end
	end
	table.clear(digDisabledMotors)
end

local function stopDigFallback()
	if digPreRenderConn then
		digPreRenderConn:Disconnect()
		digPreRenderConn = nil
	end
	if digHeartbeatConn then
		digHeartbeatConn:Disconnect()
		digHeartbeatConn = nil
	end
	if digBound then
		digBound = false
		pcall(function()
			RunService:UnbindFromRenderStep(digBindName)
		end)
	end
	clearDigWeldsAndMotors()
	restoreDigAnimate()
end

local function stopDigTrack()
	local track = digTrack
	if track then
		pcall(function()
			track:Stop(0)
		end)
	end
	stopDigFallback()
end

local function stopRunTrack()
	local track = runTrack
	if track then
		pcall(function()
			track:Stop(0.06)
		end)
	end
end

local function restoreCoralRise()
	local part = risePart
	local cf = riseFinalCF
	risePart = nil
	riseFinalCF = nil
	if part and part.Parent and cf then
		part.CFrame = cf
	end
end

local function buryDepthFor(part: BasePart): number
	local h = part.Size.Y
	local model = part:FindFirstAncestorOfClass("Model")
	if model then
		local ok, _cf, size = pcall(function()
			return model:GetBoundingBox()
		end)
		if ok and typeof(size) == "Vector3" then
			h = math.max(h, (size :: Vector3).Y)
		end
	end
	return math.max(CORAL_BURY_MIN, h + CORAL_BURY_PAD)
end

local function beginCoralRise(part: BasePart?): (BasePart?, CFrame?, CFrame?)
	if not part or not part.Parent then
		return nil, nil, nil
	end
	restoreCoralRise()
	local finalCF = part.CFrame
	local buriedCF = finalCF - Vector3.new(0, buryDepthFor(part), 0)
	part.CFrame = buriedCF
	risePart = part
	riseFinalCF = finalCF
	return part, buriedCF, finalCF
end

local function setCoralRiseAlpha(part: BasePart, buriedCF: CFrame, finalCF: CFrame, u: number)
	local a = 1 - (1 - math.clamp(u, 0, 1)) ^ 2 -- ease-out
	part.CFrame = buriedCF:Lerp(finalCF, a)
end

local function findBodyPart(character: Model, names: { string }): BasePart?
	for _, name in ipairs(names) do
		local p = character:FindFirstChild(name)
		if p and p:IsA("BasePart") then
			return p
		end
	end
	return nil
end

-- Smooth 0→1→0 over DIG_BEND_CYCLE_SEC (upright ↔ lean forward).
local function digBendAlpha(elapsed: number): number
	local u = (elapsed / DIG_BEND_CYCLE_SEC) % 1
	local tri = if u < 0.5 then u * 2 else 2 - u * 2
	return tri * tri * (3 - 2 * tri)
end

-- Disable Animator entirely for dig — welds own the limbs (works Studio + live/mobile).
local function playDigFallback(token: number, hum: Humanoid)
	local character = player.Character
	if not character then
		return
	end
	local lowerTorso = findBodyPart(character, { "LowerTorso" })
	local torso = findBodyPart(character, { "UpperTorso", "Torso" })
	local rUpper = findBodyPart(character, { "RightUpperArm", "Right Arm" })
	local lUpper = findBodyPart(character, { "LeftUpperArm", "Left Arm" })
	local rLower = findBodyPart(character, { "RightLowerArm" })
	local lLower = findBodyPart(character, { "LeftLowerArm" })
	if not torso or (not rUpper and not lUpper) then
		return
	end

	stopDigFallback()
	stopRunTrack()

	local animate = character:FindFirstChild("Animate")
	if animate and (animate:IsA("LocalScript") or animate:IsA("Script")) then
		digAnimateScript = animate
		digAnimateWasDisabled = (animate :: any).Disabled == true
		pcall(function()
			(animate :: any).Disabled = true
		end)
	end

	local animator = getAnimator(hum)
	for _, t in ipairs(animator:GetPlayingAnimationTracks()) do
		pcall(function()
			t:Stop(0)
		end)
	end
	if digTrack then
		pcall(function()
			digTrack:Stop(0)
		end)
	end

	-- Freeze arm (+ waist) motors so Animator / physics cannot fight dig welds.
	local limbSet: { [BasePart]: boolean } = {}
	if rUpper then
		limbSet[rUpper] = true
	end
	if lUpper then
		limbSet[lUpper] = true
	end
	if rLower then
		limbSet[rLower] = true
	end
	if lLower then
		limbSet[lLower] = true
	end
	if lowerTorso and torso.Name == "UpperTorso" then
		limbSet[torso] = true
	end
	for _, d in ipairs(character:GetDescendants()) do
		if d:IsA("Motor6D") and d.Part1 and limbSet[d.Part1] then
			d.Enabled = false
			d.Transform = CFrame.new()
			table.insert(digDisabledMotors, d)
		end
	end

	-- R15: weld UpperTorso → LowerTorso so we can pitch the chest forward.
	local wWaist: Weld? = nil
	local restWaist = CFrame.new()
	if lowerTorso and torso.Name == "UpperTorso" then
		local w = Instance.new("Weld")
		w.Name = "OceanTD_PlantDigWeldWaist"
		w.Part0 = lowerTorso
		w.Part1 = torso
		w.C0 = lowerTorso.CFrame:ToObjectSpace(torso.CFrame)
		w.C1 = CFrame.new()
		w.Parent = lowerTorso
		table.insert(digWelds, w)
		wWaist = w
		restWaist = w.C0
	end

	local function makeWeld(part: BasePart): Weld
		local w = Instance.new("Weld")
		w.Name = "OceanTD_PlantDigWeld"
		w.Part0 = torso
		w.Part1 = part
		w.C0 = torso.CFrame:ToObjectSpace(part.CFrame)
		w.C1 = CFrame.new()
		w.Parent = torso
		table.insert(digWelds, w)
		return w
	end

	local wRight = if rUpper then makeWeld(rUpper) else nil
	local wLeft = if lUpper then makeWeld(lUpper) else nil
	-- Lower arms: weld to upper so elbows bend with shovel motion.
	local wRightLower: Weld? = nil
	local wLeftLower: Weld? = nil
	if rLower and rUpper then
		-- Temporarily parent weld to upper arm
		local w = Instance.new("Weld")
		w.Name = "OceanTD_PlantDigWeldLower"
		w.Part0 = rUpper
		w.Part1 = rLower
		w.C0 = rUpper.CFrame:ToObjectSpace(rLower.CFrame)
		w.C1 = CFrame.new()
		w.Parent = rUpper
		table.insert(digWelds, w)
		wRightLower = w
	end
	if lLower and lUpper then
		local w = Instance.new("Weld")
		w.Name = "OceanTD_PlantDigWeldLower"
		w.Part0 = lUpper
		w.Part1 = lLower
		w.C0 = lUpper.CFrame:ToObjectSpace(lLower.CFrame)
		w.C1 = CFrame.new()
		w.Parent = lUpper
		table.insert(digWelds, w)
		wLeftLower = w
	end

	-- Rest pose relative to torso (captured once).
	local restRight = if wRight then wRight.C0 else CFrame.new()
	local restLeft = if wLeft then wLeft.C0 else CFrame.new()
	local restRightLower = if wRightLower then wRightLower.C0 else CFrame.new()
	local restLeftLower = if wLeftLower then wLeftLower.C0 else CFrame.new()

	local t0 = os.clock()
	digBound = true

	local function applyDigPose()
		if token ~= playToken then
			stopDigFallback()
			return
		end
		if not torso.Parent then
			stopDigFallback()
			return
		end
		local elapsed = os.clock() - t0
		local bendRad = math.rad(DIG_BEND_DEG) * digBendAlpha(elapsed)
		-- Negative pitch = lean forward (shovel into the sand).
		if wWaist and wWaist.Parent then
			wWaist.C0 = restWaist * CFrame.Angles(-bendRad, 0, 0)
		end
		local phase = (elapsed / DIG_CYCLE_SEC) % 1
		local rightUp = 0.5 + 0.5 * math.cos(phase * math.pi * 2)
		local leftUp = 0.5 + 0.5 * math.cos((phase + 0.5) * math.pi * 2)
		if wRight and wRight.Parent then
			wRight.C0 = restRight
				* CFrame.Angles(math.rad(-40 - 150 * rightUp), math.rad(-20), math.rad(40))
		end
		if wLeft and wLeft.Parent then
			wLeft.C0 = restLeft
				* CFrame.Angles(math.rad(-40 - 150 * leftUp), math.rad(20), math.rad(-40))
		end
		if wRightLower and wRightLower.Parent then
			wRightLower.C0 = restRightLower * CFrame.Angles(math.rad(-30 - 50 * rightUp), 0, 0)
		end
		if wLeftLower and wLeftLower.Parent then
			wLeftLower.C0 = restLeftLower * CFrame.Angles(math.rad(-30 - 50 * leftUp), 0, 0)
		end
	end

	-- Multiple hooks — mobile can skip one render path.
	digHeartbeatConn = RunService.Heartbeat:Connect(applyDigPose)
	local preRender = (RunService :: any).PreRender
	if typeof(preRender) == "RBXScriptSignal" then
		digPreRenderConn = preRender:Connect(applyDigPose)
	end
	RunService:BindToRenderStep(digBindName, Enum.RenderPriority.Last.Value + 1, applyDigPose)
end

local function buildDigSequence(): KeyframeSequence
	local seq = Instance.new("KeyframeSequence")
	seq.Loop = true
	seq.Priority = Enum.AnimationPriority.Action4

	local function addKey(
		t: number,
		torsoPitch: number,
		rightUpper: CFrame,
		rightLower: CFrame,
		leftUpper: CFrame,
		leftLower: CFrame
	)
		local kf = Instance.new("Keyframe")
		kf.Time = t
		local root = Instance.new("Pose")
		root.Name = "HumanoidRootPart"
		local lower = Instance.new("Pose")
		lower.Name = "LowerTorso"
		local upper = Instance.new("Pose")
		upper.Name = "UpperTorso"
		upper.CFrame = CFrame.Angles(torsoPitch, 0, 0)

		local rua = Instance.new("Pose")
		rua.Name = "RightUpperArm"
		rua.CFrame = rightUpper
		local rla = Instance.new("Pose")
		rla.Name = "RightLowerArm"
		rla.CFrame = rightLower
		local rh = Instance.new("Pose")
		rh.Name = "RightHand"
		rh.CFrame = CFrame.new()

		local lua = Instance.new("Pose")
		lua.Name = "LeftUpperArm"
		lua.CFrame = leftUpper
		local lla = Instance.new("Pose")
		lla.Name = "LeftLowerArm"
		lla.CFrame = leftLower
		local lh = Instance.new("Pose")
		lh.Name = "LeftHand"
		lh.CFrame = CFrame.new()

		rh.Parent = rla
		rla.Parent = rua
		rua.Parent = upper
		lh.Parent = lla
		lla.Parent = lua
		lua.Parent = upper
		upper.Parent = lower
		lower.Parent = root
		root.Parent = kf
		kf.Parent = seq
	end

	local upR = CFrame.Angles(math.rad(-150), math.rad(-15), math.rad(40))
	local upL = CFrame.Angles(math.rad(-150), math.rad(15), math.rad(-40))
	local downR = CFrame.Angles(math.rad(-25), math.rad(-10), math.rad(20))
	local downL = CFrame.Angles(math.rad(-25), math.rad(10), math.rad(-20))
	local bend = CFrame.Angles(math.rad(-55), 0, 0)
	local soft = CFrame.Angles(math.rad(-20), 0, 0)

	addKey(0, math.rad(8), upR, bend, downL, soft)
	addKey(DIG_CYCLE_SEC * 0.5, math.rad(-6), downR, soft, upL, bend)
	addKey(DIG_CYCLE_SEC, math.rad(8), upR, bend, downL, soft)
	return seq
end

-- Cartoon run: exaggerated opposite legs + arm swing (played at RUN_PLAY_SPEED).
local function buildRunSequence(): KeyframeSequence
	local seq = Instance.new("KeyframeSequence")
	seq.Loop = true
	seq.Priority = Enum.AnimationPriority.Action4

	local function addKey(
		t: number,
		torsoPitch: number,
		rArmU: CFrame,
		rArmL: CFrame,
		lArmU: CFrame,
		lArmL: CFrame,
		rLegU: CFrame,
		rLegL: CFrame,
		lLegU: CFrame,
		lLegL: CFrame
	)
		local kf = Instance.new("Keyframe")
		kf.Time = t
		local root = Instance.new("Pose")
		root.Name = "HumanoidRootPart"
		local lower = Instance.new("Pose")
		lower.Name = "LowerTorso"
		local upper = Instance.new("Pose")
		upper.Name = "UpperTorso"
		upper.CFrame = CFrame.Angles(torsoPitch, 0, 0)

		local rua = Instance.new("Pose")
		rua.Name = "RightUpperArm"
		rua.CFrame = rArmU
		local rla = Instance.new("Pose")
		rla.Name = "RightLowerArm"
		rla.CFrame = rArmL
		local rh = Instance.new("Pose")
		rh.Name = "RightHand"
		rh.CFrame = CFrame.new()

		local lua = Instance.new("Pose")
		lua.Name = "LeftUpperArm"
		lua.CFrame = lArmU
		local lla = Instance.new("Pose")
		lla.Name = "LeftLowerArm"
		lla.CFrame = lArmL
		local lh = Instance.new("Pose")
		lh.Name = "LeftHand"
		lh.CFrame = CFrame.new()

		local rul = Instance.new("Pose")
		rul.Name = "RightUpperLeg"
		rul.CFrame = rLegU
		local rll = Instance.new("Pose")
		rll.Name = "RightLowerLeg"
		rll.CFrame = rLegL
		local rf = Instance.new("Pose")
		rf.Name = "RightFoot"
		rf.CFrame = CFrame.new()

		local lul = Instance.new("Pose")
		lul.Name = "LeftUpperLeg"
		lul.CFrame = lLegU
		local lll = Instance.new("Pose")
		lll.Name = "LeftLowerLeg"
		lll.CFrame = lLegL
		local lf = Instance.new("Pose")
		lf.Name = "LeftFoot"
		lf.CFrame = CFrame.new()

		rh.Parent = rla
		rla.Parent = rua
		rua.Parent = upper
		lh.Parent = lla
		lla.Parent = lua
		lua.Parent = upper
		rf.Parent = rll
		rll.Parent = rul
		rul.Parent = lower
		lf.Parent = lll
		lll.Parent = lul
		lul.Parent = lower
		upper.Parent = lower
		lower.Parent = root
		root.Parent = kf
		kf.Parent = seq
	end

	local armFwd = CFrame.Angles(math.rad(55), 0, math.rad(10))
	local armBack = CFrame.Angles(math.rad(-55), 0, math.rad(-10))
	local armBend = CFrame.Angles(math.rad(-35), 0, 0)
	local legFwd = CFrame.Angles(math.rad(-70), 0, 0)
	local legBack = CFrame.Angles(math.rad(55), 0, 0)
	local kneeFwd = CFrame.Angles(math.rad(70), 0, 0)
	local kneeBack = CFrame.Angles(math.rad(25), 0, 0)

	-- Right leg forward / left back, then swap (arms opposite).
	addKey(
		0,
		math.rad(10),
		armBack,
		armBend,
		armFwd,
		armBend,
		legFwd,
		kneeFwd,
		legBack,
		kneeBack
	)
	addKey(
		RUN_CYCLE_SEC * 0.5,
		math.rad(6),
		armFwd,
		armBend,
		armBack,
		armBend,
		legBack,
		kneeBack,
		legFwd,
		kneeFwd
	)
	addKey(
		RUN_CYCLE_SEC,
		math.rad(10),
		armBack,
		armBend,
		armFwd,
		armBend,
		legFwd,
		kneeFwd,
		legBack,
		kneeBack
	)
	return seq
end

local function loadLoopTrack(
	hum: Humanoid,
	build: () -> KeyframeSequence,
	cachedId: string?,
	cachedTrack: AnimationTrack?,
	cachedAnimator: Animator?,
	version: number,
	registeredVersion: number?
): (string?, AnimationTrack?, Animator?, number)
	local animator = getAnimator(hum)
	local id = cachedId
	local track = cachedTrack
	local trackAnim = cachedAnimator
	local reg = registeredVersion
	if reg ~= version then
		id = nil
		track = nil
		trackAnim = nil
		reg = version
	end
	if track and trackAnim == animator then
		return id, track, trackAnim, reg :: number
	end
	if not id then
		local ok, idOrErr = pcall(function()
			return KeyframeSequenceProvider:RegisterKeyframeSequence(build())
		end)
		if not ok or typeof(idOrErr) ~= "string" then
			return id, nil, trackAnim, reg :: number
		end
		id = idOrErr
	end
	local anim = Instance.new("Animation")
	anim.AnimationId = id :: string
	local okLoad, trackOrErr = pcall(function()
		return animator:LoadAnimation(anim)
	end)
	if not okLoad or typeof(trackOrErr) ~= "Instance" then
		return id, nil, trackAnim, reg :: number
	end
	local loaded = trackOrErr :: AnimationTrack
	loaded.Priority = Enum.AnimationPriority.Action4
	loaded.Looped = true
	return id, loaded, animator, reg :: number
end

local function ensureDigTrack(hum: Humanoid): AnimationTrack?
	local id, track, anim, reg = loadLoopTrack(
		hum,
		buildDigSequence,
		digAnimId,
		digTrack,
		digTrackAnimator,
		DIG_ANIM_VERSION,
		digAnimVersionRegistered
	)
	digAnimId = id
	digTrack = track
	digTrackAnimator = anim
	digAnimVersionRegistered = reg
	return track
end

local function ensureRunTrack(hum: Humanoid): AnimationTrack?
	local id, track, anim, reg = loadLoopTrack(
		hum,
		buildRunSequence,
		runAnimId,
		runTrack,
		runTrackAnimator,
		RUN_ANIM_VERSION,
		runAnimVersionRegistered
	)
	runAnimId = id
	runTrack = track
	runTrackAnimator = anim
	runAnimVersionRegistered = reg
	return track
end

-- Same dig path everywhere (Studio + published): weld limbs, motors off.
-- KS / Transform / C0 alone were silent on live mobile while Studio KS looked fine.
local function startDig(hum: Humanoid, token: number)
	stopDigFallback()
	playDigFallback(token, hum)
end

local function fxFolder(): Folder
	local cam = Workspace.CurrentCamera
	local folder = cam and cam:FindFirstChild("OceanTD_LocalFX")
	if folder and folder:IsA("Folder") then
		return folder
	end
	local f = Instance.new("Folder")
	f.Name = "OceanTD_LocalFX"
	f.Parent = cam or Workspace
	return f
end

-- World-space host (not on the avatar) so Plot/Fish cam can actually see the dust.
local function makeDustHost(feetPos: Vector3): (BasePart, ParticleEmitter)
	local host = Instance.new("Part")
	host.Name = "OceanTD_PlantWorkerDust"
	host.Anchored = true
	host.CanCollide = false
	host.CanQuery = false
	host.CanTouch = false
	host.CastShadow = false
	host.Massless = true
	host.Transparency = 1
	host.Size = Vector3.new(0.4, 0.4, 0.4)
	host.CFrame = CFrame.new(feetPos)
	host.Parent = fxFolder()

	local pe = Instance.new("ParticleEmitter")
	pe.Name = "Dust"
	pe.Texture = DUST_TEXTURE
	pe.Enabled = true
	pe.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(220, 200, 155)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(145, 125, 90)),
	})
	pe.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 2.4),
		NumberSequenceKeypoint.new(0.4, 5.6),
		NumberSequenceKeypoint.new(1, 8.0),
	})
	pe.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.15),
		NumberSequenceKeypoint.new(0.5, 0.45),
		NumberSequenceKeypoint.new(1, 1),
	})
	pe.Lifetime = NumberRange.new(0.5, 0.85)
	pe.Speed = NumberRange.new(2, 5)
	pe.SpreadAngle = Vector2.new(70, 70)
	pe.Acceleration = Vector3.new(0, 6, 0)
	pe.Drag = 1.8
	pe.Rotation = NumberRange.new(0, 360)
	pe.RotSpeed = NumberRange.new(-90, 90)
	pe.Rate = 28 -- steady puff while digging (Emit alone was easy to miss from cam)
	pe.LightEmission = 0.08
	pe.LightInfluence = 0.35
	pe.LockedToPart = false
	pe.ZOffset = 1
	pe.Parent = host
	return host, pe
end

local function makeIceBubblePart(size: number, at: Vector3): BasePart
	local ball = Instance.new("Part")
	ball.Name = "OceanTD_DigIceBubble"
	ball.Shape = Enum.PartType.Ball
	ball.Material = Enum.Material.Glass
	ball.Color = ICE_BUBBLE_COLOR
	ball.Transparency = ICE_BUBBLE_TRANS
	ball.Reflectance = 0.15
	ball.Anchored = true
	ball.CanCollide = false
	ball.CanQuery = false
	ball.CanTouch = false
	ball.CastShadow = false
	ball.Massless = true
	ball.Size = Vector3.new(size, size, size)
	ball.CFrame = CFrame.new(at)
	ball.Parent = fxFolder()
	return ball
end

local function animateIceBubble(ball: BasePart, start: Vector3, drift: Vector3, life: number)
	task.spawn(function()
		local t0 = os.clock()
		while ball.Parent do
			local elapsed = os.clock() - t0
			local u = elapsed / life
			if u >= 1 then
				break
			end
			if u > 0.72 then
				ball.Transparency = ICE_BUBBLE_TRANS + (1 - ICE_BUBBLE_TRANS) * ((u - 0.72) / 0.28)
			end
			ball.CFrame = CFrame.new(start + drift * elapsed)
			task.wait()
		end
		if ball.Parent then
			ball:Destroy()
		end
	end)
end

-- Light-blue glass spheres that scatter out and slowly float upward.
local function spawnIceBubbles(origin: Vector3, count: number)
	for _ = 1, count do
		local size = ICE_BUBBLE_SIZES[math.random(1, #ICE_BUBBLE_SIZES)]
		local angle = math.random() * math.pi * 2
		local rad = math.random() * ICE_BUBBLE_SCATTER
		local start = origin + Vector3.new(math.cos(angle) * rad, (math.random() - 0.25) * 1.1, math.sin(angle) * rad)
		local life = ICE_BUBBLE_LIFE_MIN + math.random() * (ICE_BUBBLE_LIFE_MAX - ICE_BUBBLE_LIFE_MIN)
		-- Each bubble: +30% to +110% rise speed (independent roll).
		local rise = ICE_BUBBLE_RISE * (1.3 + math.random() * 0.8)
		local drift = Vector3.new((math.random() - 0.5) * 0.85, rise, (math.random() - 0.5) * 0.85)
		animateIceBubble(makeIceBubblePart(size, start), start, drift, life)
	end
end

-- Radial burst in all directions (dash land).
local function blastIceBubbles(origin: Vector3, count: number)
	for _ = 1, count do
		local size = ICE_BUBBLE_SIZES[math.random(1, #ICE_BUBBLE_SIZES)]
		-- Uniform-ish random direction on a sphere.
		local yaw = math.random() * math.pi * 2
		local pitch = math.acos(2 * math.random() - 1) - math.pi * 0.5
		local dir = Vector3.new(
			math.cos(pitch) * math.cos(yaw),
			math.sin(pitch),
			math.cos(pitch) * math.sin(yaw)
		)
		if dir.Magnitude < 1e-4 then
			dir = Vector3.yAxis
		else
			dir = dir.Unit
		end
		local speed = ICE_BUBBLE_BLAST_SPEED_MIN
			+ math.random() * (ICE_BUBBLE_BLAST_SPEED_MAX - ICE_BUBBLE_BLAST_SPEED_MIN)
		local rise = ICE_BUBBLE_RISE * (1.3 + math.random() * 0.8)
		-- Blast outward, then keep a gentle upward float mixed in.
		local drift = dir * speed + Vector3.new(0, rise * 0.45, 0)
		local life = ICE_BUBBLE_LIFE_MIN + math.random() * (ICE_BUBBLE_LIFE_MAX - ICE_BUBBLE_LIFE_MIN)
		animateIceBubble(makeIceBubblePart(size, origin), origin, drift, life)
	end
end

local function clearIceBubbles()
	local folder = fxFolder()
	for _, child in ipairs(folder:GetChildren()) do
		if child.Name == "OceanTD_DigIceBubble" then
			child:Destroy()
		end
	end
end

local function destroyDust(host: BasePart?)
	if host and host.Parent then
		host:Destroy()
	end
end

local function makeSfx(name: string, soundId: string, vol: number): Sound
	local s = Instance.new("Sound")
	s.Name = name
	s.SoundId = soundId
	s.Volume = vol
	s.RollOffMode = Enum.RollOffMode.InverseTapered
	s.Parent = SoundService
	return s
end

local function fadeSoundTo(sound: Sound, targetVol: number, sec: number, destroyWhenDone: boolean)
	local gen = (sound:GetAttribute("OceanTD_FadeGen") :: number?) or 0
	gen += 1
	sound:SetAttribute("OceanTD_FadeGen", gen)
	local from = sound.Volume
	local t0 = os.clock()
	task.spawn(function()
		while sound.Parent and sound:GetAttribute("OceanTD_FadeGen") == gen do
			local u = if sec <= 0 then 1 else math.clamp((os.clock() - t0) / sec, 0, 1)
			sound.Volume = from + (targetVol - from) * u
			if u >= 1 then
				break
			end
			RunService.Heartbeat:Wait()
		end
		if destroyWhenDone and sound.Parent and sound:GetAttribute("OceanTD_FadeGen") == gen then
			sound:Stop()
			sound:Destroy()
		end
	end)
end

local function stopRunSound()
	local s = runSound
	runSound = nil
	if s and s.Parent then
		s:Stop()
		s:Destroy()
	end
end

local function stopWorkSound(fadeOut: boolean)
	local s = workSound
	workSound = nil
	if not s or not s.Parent then
		return
	end
	if fadeOut then
		fadeSoundTo(s, 0, WORK_FADE_OUT_SEC, true)
	else
		s:Stop()
		s:Destroy()
	end
end

local function startRunSound()
	stopRunSound()
	local s = makeSfx("OceanTD_PlantWorkerRun", RUN_SOUND_ID, 0)
	s.Looped = true
	runSound = s
	s:Play()
	fadeSoundTo(s, RUN_VOL * batchWorkVolScale, RUN_FADE_IN_SEC, false)
end

local function startWorkSound()
	stopWorkSound(false)
	local s = makeSfx("OceanTD_PlantWorkerWork", WORK_SOUND_ID, WORK_VOL * batchWorkVolScale)
	s.Looped = true
	workSound = s
	s:Play()
end

local function hipStandOffset(hum: Humanoid): number
	local hip = if hum.HipHeight > 0.5 then hum.HipHeight else 2
	return hip + HIP_PAD
end

local function groundHipY(xzX: number, xzZ: number, hintY: number, hum: Humanoid): number
	local hip = hipStandOffset(hum)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local exclude: { Instance } = {}
	local character = player.Character
	if character then
		table.insert(exclude, character)
	end
	local cam = Workspace.CurrentCamera
	local fx = cam and cam:FindFirstChild("OceanTD_LocalFX")
	if fx then
		table.insert(exclude, fx)
	end
	-- Exclude placed corals so a buried soft-plant mesh doesn't become the "ground".
	local placed = Workspace:FindFirstChild("OceanTD_Placed")
	if placed then
		table.insert(exclude, placed)
	end
	params.FilterDescendantsInstances = exclude

	local origin = Vector3.new(xzX, hintY + RAY_UP, xzZ)
	local hit = Workspace:Raycast(origin, Vector3.new(0, -RAY_DOWN, 0), params)
	if hit then
		return hit.Position.Y + hip
	end
	local plot = ClientPlot.get()
	if plot then
		local top = plot.cframe.Position.Y + plot.size.Y * 0.5
		return top + hip
	end
	return hintY + hip
end

-- Horizon-locked look (avoids CFrame:Lerp spin when start/goal face different ways).
local function lookFlat(pos: Vector3, lookAt: Vector3, fallbackLook: Vector3?): CFrame
	local target = Vector3.new(lookAt.X, pos.Y, lookAt.Z)
	local delta = target - pos
	if delta.Magnitude < 0.08 then
		local fb = fallbackLook or Vector3.new(0, 0, -1)
		target = pos + Vector3.new(fb.X, 0, fb.Z)
		if (target - pos).Magnitude < 0.08 then
			return CFrame.new(pos)
		end
	end
	return CFrame.lookAt(pos, target)
end

local function coralTopWorld(part: BasePart): Vector3
	local model = part:FindFirstAncestorOfClass("Model")
	if model then
		local ok, cf, size = pcall(function()
			return model:GetBoundingBox()
		end)
		if ok and typeof(cf) == "CFrame" and typeof(size) == "Vector3" then
			local c = cf :: CFrame
			local s = size :: Vector3
			return c.Position + Vector3.new(0, s.Y * 0.5, 0)
		end
	end
	return part.Position + Vector3.new(0, part.Size.Y * 0.5, 0)
end

-- Stand on top of the coral (rises with it). Never sink below terrain while buried.
local function standOnCoralCF(part: BasePart, hum: Humanoid, lookAt: Vector3): CFrame
	local top = coralTopWorld(part)
	local hip = hipStandOffset(hum)
	local groundY = groundHipY(top.X, top.Z, top.Y, hum)
	local y = math.max(top.Y + hip, groundY)
	local pos = Vector3.new(top.X, y, top.Z)
	return lookFlat(pos, lookAt, nil)
end

-- Stand on the plant spot; if coral given, stand on its current top.
local function standCFrame(
	fromPos: Vector3,
	plantPos: Vector3,
	hum: Humanoid,
	coral: BasePart?
): (CFrame, CFrame)
	local hintY = plantPos.Y
	local startY = groundHipY(fromPos.X, fromPos.Z, hintY, hum)
	local start = Vector3.new(fromPos.X, startY, fromPos.Z)
	local lookPlant = Vector3.new(plantPos.X, startY, plantPos.Z)
	local goalCF: CFrame
	if coral and coral.Parent then
		goalCF = standOnCoralCF(coral, hum, lookPlant)
	else
		local flat = Vector3.new(fromPos.X - plantPos.X, 0, fromPos.Z - plantPos.Z)
		if flat.Magnitude < 0.15 then
			flat = Vector3.new(0, 0, -1)
		else
			flat = flat.Unit
		end
		local standY = groundHipY(plantPos.X, plantPos.Z, hintY, hum)
		local stand = Vector3.new(
			plantPos.X + flat.X * STAND_OFFSET,
			standY,
			plantPos.Z + flat.Z * STAND_OFFSET
		)
		lookPlant = Vector3.new(plantPos.X, standY, plantPos.Z)
		goalCF = lookFlat(stand, lookPlant, -flat)
	end
	local startCF = lookFlat(start, goalCF.Position, goalCF.LookVector)
	return startCF, goalCF
end

local function easeOutQuad(u: number): number
	local t = 1 - math.clamp(u, 0, 1)
	return 1 - t * t
end

local function feetWorldPos(standCF: CFrame, hum: Humanoid): Vector3
	local hip = hipStandOffset(hum)
	return standCF.Position - Vector3.new(0, hip * 0.92, 0)
end

local function playWowSound()
	if batchWowLeft >= 0 then
		if batchWowLeft <= 0 then
			return
		end
		batchWowLeft -= 1
	end
	local s = makeSfx("OceanTD_PlantWorkerWow", WOW_SOUND_ID, WOW_VOL)
	s.Looped = false
	s:Play()
	s.Ended:Once(function()
		if s.Parent then
			s:Destroy()
		end
	end)
	-- Safety cleanup if Ended never fires (load fail / muted).
	task.delay(8, function()
		if s.Parent then
			s:Destroy()
		end
	end)
end

local function burstHeartFirework(at: Vector3, playWow: boolean?)
	local cam = Workspace.CurrentCamera
	if not cam then
		return
	end
	if playWow ~= false then
		playWowSound()
	end
	local folder = cam:FindFirstChild("OceanTD_LocalFX")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "OceanTD_LocalFX"
		folder.Parent = cam
	end
	local origin = at + Vector3.new(0, 2.2, 0)
	local rng = Random.new()
	local count = if typeof(batchHeartsPerCoral) == "number"
		then batchHeartsPerCoral
		else rng:NextInteger(HEART_FIREWORK_MIN, HEART_FIREWORK_MAX)
	for i = 1, count do
		local delaySec = rng:NextNumber(0, 0.1)
		task.delay(delaySec, function()
			local anchor = Instance.new("Part")
			anchor.Name = "OceanTD_PlantHeartSpark"
			anchor.Anchored = true
			anchor.CanCollide = false
			anchor.CanQuery = false
			anchor.CanTouch = false
			anchor.CastShadow = false
			anchor.Transparency = 1
			anchor.Size = Vector3.new(0.35, 0.35, 0.35)
			anchor.CFrame = CFrame.new(origin)
			anchor.Parent = folder

			local sizeStuds = rng:NextNumber(1.6, 2.8)
			local bb = Instance.new("BillboardGui")
			bb.Name = "HeartSpark"
			bb.Adornee = anchor
			bb.AlwaysOnTop = true
			bb.LightInfluence = 0
			bb.MaxDistance = 2000
			bb.Size = UDim2.fromScale(sizeStuds, sizeStuds)
			bb.Parent = anchor

			local scale = Instance.new("UIScale")
			scale.Scale = 0.15
			scale.Parent = bb

			local lbl = Instance.new("TextLabel")
			lbl.BackgroundTransparency = 1
			lbl.Size = UDim2.fromScale(1, 1)
			lbl.Font = Enum.Font.SourceSansBold
			lbl.Text = HEART_EMOJI
			lbl.TextScaled = true
			lbl.TextStrokeTransparency = 0.4
			lbl.TextStrokeColor3 = Color3.fromRGB(80, 20, 40)
			lbl.Parent = bb

			local yaw = rng:NextNumber(0, math.pi * 2)
			local pitch = rng:NextNumber(-0.2, 1.25)
			local dir = Vector3.new(
				math.cos(yaw) * math.cos(pitch),
				math.sin(pitch),
				math.sin(yaw) * math.cos(pitch)
			).Unit
			local vel = dir * rng:NextNumber(14, 28)
			local grav = rng:NextNumber(18, 32)
			local life = rng:NextNumber(0.85, 1.35)
			local peak = rng:NextNumber(0.95, 1.4)
			local popAt = rng:NextNumber(0.08, 0.2)
			local pos = origin
			local t0 = os.clock()
			local conn: RBXScriptConnection
			conn = RunService.RenderStepped:Connect(function(dt)
				local age = os.clock() - t0
				if age >= life or not anchor.Parent then
					conn:Disconnect()
					if anchor.Parent then
						anchor:Destroy()
					end
					return
				end
				vel = vel + Vector3.new(0, -grav, 0) * dt
				pos = pos + vel * dt
				anchor.CFrame = CFrame.new(pos)
				if age < popAt then
					scale.Scale = 0.15 + (peak - 0.15) * (age / popAt)
				else
					local u = math.clamp((age - popAt) / math.max(0.05, life - popAt), 0, 1)
					scale.Scale = peak * (1 - 0.35 * u)
					lbl.TextTransparency = math.clamp((u - 0.45) / 0.55, 0, 1)
				end
			end)
		end)
	end
end

local function finish(
	token: number,
	hrp: BasePart?,
	wasAnchored: boolean,
	dustHost: BasePart?,
	onDone: (() -> ())?
)
	if token ~= playToken then
		return
	end
	stopDigTrack()
	stopRunTrack()
	stopRunSound()
	stopWorkSound(true) -- fade out 0.5s when work ends / cuts short
	destroyDust(dustHost)
	restoreCoralRise()
	releaseDigShovel()
	if hrp and hrp.Parent then
		hrp.Anchored = wasAnchored
		burstHeartFirework(hrp.Position)
	elseif digCamPlantPos then
		burstHeartFirework(digCamPlantPos)
	end
	local digTok = digCamToken
	-- Hold on the dig close-up, then tween back to the prior view.
	task.delay(DIG_CAM_OUT_HOLD_SEC, function()
		if token ~= playToken or digTok ~= digCamToken then
			return
		end
		endDigCamZoom(digTok)
	end)
	-- Hold busy through linger + restore so FreeCam / next place don't fight the zoom-out.
	task.delay(DIG_CAM_OUT_HOLD_SEC + DIG_CAM_OUT_SEC + 0.05, function()
		if token ~= playToken then
			return
		end
		setBusy(false)
		if onDone then
			onDone()
		end
	end)
end

-- Player Cam / skipAvatar: dig FX at the plant without taking the avatar.
-- Plant-side dig only (no avatar). Safe to run many at once (ADD MAX).
local function playAtPlantOnly(worldPos: Vector3, opts: PlayOpts?): boolean
	plantOnlySerial += 1
	local myId = plantOnlySerial
	local bindName = "OceanTD_PlantOnly_" .. tostring(myId)
	local coralPart = if opts then opts.coralPart else nil
	local onDone = if opts then opts.onDone else nil
	local optBubble = if opts then tonumber(opts.bubbleScale) else nil
	local bubbleScale = if typeof(optBubble) == "number" and optBubble > 0
		then optBubble
		else batchBubbleScale
	local playWow = if opts and opts.playWow == false then false else true
	local hardBubbleCap = batchBubblesPerCoral
	local function bubbles(n: number): number
		return math.max(1, math.floor(n * bubbleScale + 0.5))
	end

	local riseP: BasePart? = nil
	local buriedCF: CFrame? = nil
	local finalCF: CFrame? = nil
	if coralPart and coralPart.Parent then
		coralPart.LocalTransparencyModifier = 0
		finalCF = coralPart.CFrame
		buriedCF = finalCF - Vector3.new(0, buryDepthFor(coralPart), 0)
		coralPart.CFrame = buriedCF
		riseP = coralPart
	end

	plantOnlyBusy += 1
	if plantOnlyBusy == 1 then
		setBusy(true)
	end

	-- Hard per-coral bubble budget (ADD MAX >40): one blast, no periodic extras.
	if typeof(hardBubbleCap) == "number" then
		if hardBubbleCap > 0 then
			blastIceBubbles(worldPos, hardBubbleCap)
		end
	else
		blastIceBubbles(worldPos, bubbles(ICE_BUBBLE_DASH_BLAST))
	end
	local useDust = batchDustChance >= 1 or math.random() <= batchDustChance
	local dustHost: BasePart? = nil
	local dustPe: ParticleEmitter? = nil
	if useDust then
		local host, pe = makeDustHost(worldPos)
		dustHost = host
		dustPe = pe
		pe:Emit(if typeof(hardBubbleCap) == "number" then 1 else bubbles(12))
	end
	if typeof(hardBubbleCap) ~= "number" then
		spawnIceBubbles(worldPos, bubbles(6))
	end
	-- One shared work loop sound while any plant-only dig is active.
	if plantOnlyBusy == 1 then
		startWorkSound()
	end

	local workSec = WORK_SEC * batchWorkSecScale
	local phaseT0 = os.clock()
	local lastDustBucket = -1
	local finished = false
	local function finishOne()
		if finished then
			return
		end
		finished = true
		pcall(function()
			RunService:UnbindFromRenderStep(bindName)
		end)
		destroyDust(dustHost)
		if riseP and riseP.Parent and finalCF then
			riseP.CFrame = finalCF
		end
		burstHeartFirework(worldPos, playWow)
		plantOnlyBusy = math.max(0, plantOnlyBusy - 1)
		if plantOnlyBusy == 0 then
			stopWorkSound(true)
			setBusy(false)
		end
		if onDone then
			onDone()
		end
	end

	RunService:BindToRenderStep(bindName, Enum.RenderPriority.Last.Value, function()
		local now = os.clock()
		local workU = math.clamp((now - phaseT0) / workSec, 0, 1)
		if riseP and riseP.Parent and buriedCF and finalCF then
			setCoralRiseAlpha(riseP, buriedCF, finalCF, workU)
		end
		if dustHost and dustHost.Parent then
			dustHost.CFrame = CFrame.new(worldPos)
		end
		local bucket = math.floor((now - phaseT0) / (DIG_CYCLE_SEC * 0.5))
		if dustPe and bucket ~= lastDustBucket then
			lastDustBucket = bucket
			dustPe:Emit(if typeof(hardBubbleCap) == "number" then 1 else bubbles(8))
			if typeof(hardBubbleCap) ~= "number" then
				spawnIceBubbles(worldPos, bubbles(3))
			end
		elseif not dustPe and bucket ~= lastDustBucket then
			lastDustBucket = bucket
			if typeof(hardBubbleCap) ~= "number" then
				spawnIceBubbles(worldPos, bubbles(3))
			end
		end
		if workU >= 1 then
			finishOne()
		end
	end)
	return true
end

function PlantWorkerVfx.playAt(worldPos: Vector3, opts: PlayOpts?): boolean
	if typeof(worldPos) ~= "Vector3" then
		return false
	end
	if shouldSkipAvatar(opts) then
		return playAtPlantOnly(worldPos, opts)
	end
	local character, hum, hrp = getCharacterParts()
	if not character or not hum or not hrp then
		-- No avatar available — still play plant-side dig FX.
		return playAtPlantOnly(worldPos, opts)
	end

	playToken += 1
	local token = playToken
	stopDigTrack()
	stopRunTrack()
	pcall(function()
		RunService:UnbindFromRenderStep(DASH_BIND_NAME)
	end)
	restoreCoralRise()

	local wasAnchored = hrp.Anchored
	hrp.Anchored = true
	hrp.AssemblyLinearVelocity = Vector3.zero
	hrp.AssemblyAngularVelocity = Vector3.zero
	hum.WalkSpeed = 0
	hum.JumpPower = 0
	hum.JumpHeight = 0
	hum.AutoRotate = false
	setBusy(true)
	ensureDigShovel()

	local coralPart = if opts then opts.coralPart else nil
	local onDone = if opts then opts.onDone else nil
	local riseP, buriedCF, finalCF = beginCoralRise(coralPart)

	local startCF, goalCF = standCFrame(hrp.Position, worldPos, hum, riseP)
	hrp.CFrame = startCF
	local base = goalCF
	local lookAtPlant = Vector3.new(worldPos.X, goalCF.Position.Y, worldPos.Z)
	local phase = "dash"
	local phaseT0 = os.clock()
	local dustHost: BasePart? = nil
	local dustPe: ParticleEmitter? = nil
	local lastDustBucket = -1
	startRunSound()
	local runAnim = ensureRunTrack(hum)
	local runSpeed = RUN_PLAY_SPEED
	local dashSec = DASH_SEC
	local workSec = WORK_SEC
	local forceAvatar = opts ~= nil and opts.forceAvatar == true
	local skipDigCam = shouldSkipDigCam(opts)
	if opts and typeof(opts.dashSec) == "number" and opts.dashSec > 0 then
		dashSec = opts.dashSec
		runSpeed = RUN_PLAY_SPEED * math.clamp(DASH_SEC / dashSec, 1, 4)
	end
	if opts and typeof(opts.workSec) == "number" and opts.workSec > 0 then
		workSec = opts.workSec
	end
	if runAnim then
		runAnim:Play(0.04, 1, runSpeed)
	end
	-- Zoom in on the digger; FreeCam yields while OceanTD_PlantDigCamBusy is set.
	-- Skipped when Auto Plant is on during a wave so PlotCam lookaround stays free.
	if not skipDigCam then
		beginDigCamZoom(hrp, worldPos)
	end

	RunService:BindToRenderStep(DASH_BIND_NAME, Enum.RenderPriority.Last.Value, function()
		if token ~= playToken then
			pcall(function()
				RunService:UnbindFromRenderStep(DASH_BIND_NAME)
			end)
			return
		end
		if not hrp.Parent then
			pcall(function()
				RunService:UnbindFromRenderStep(DASH_BIND_NAME)
			end)
			finish(token, hrp, wasAnchored, dustHost, onDone)
			return
		end
		if not forceAvatar and not isWorkerCam() then
			pcall(function()
				RunService:UnbindFromRenderStep(DASH_BIND_NAME)
			end)
			finish(token, hrp, wasAnchored, dustHost, onDone)
			return
		end

		local now = os.clock()
		if phase == "dash" then
			-- Keep goal glued to coral top while running (coral already buried).
			if riseP and riseP.Parent then
				goalCF = standOnCoralCF(riseP, hum, lookAtPlant)
			end
			local u = math.clamp((now - phaseT0) / dashSec, 0, 1)
			local a = easeOutQuad(u)
			local pos = startCF.Position:Lerp(goalCF.Position, a)
			hrp.CFrame = lookFlat(pos, goalCF.Position, goalCF.LookVector)
			if u >= 1 then
				phase = "land"
				phaseT0 = now
				base = goalCF
				hrp.CFrame = base
				stopRunSound()
				stopRunTrack()
				blastIceBubbles(feetWorldPos(base, hum), ICE_BUBBLE_DASH_BLAST)
			end
			return
		end

		if phase == "land" then
			if riseP and riseP.Parent then
				base = standOnCoralCF(riseP, hum, lookAtPlant)
			end
			local u = math.clamp((now - phaseT0) / LAND_SQUASH_SEC, 0, 1)
			local dip = math.sin(u * math.pi) * LAND_DIP_STUDS
			hrp.CFrame = base + Vector3.new(0, -dip, 0)
			if u >= 1 then
				hrp.CFrame = base
				phase = "work"
				phaseT0 = now
				startDig(hum, token)
				local host, pe = makeDustHost(feetWorldPos(base, hum))
				dustHost = host
				dustPe = pe
				pe:Emit(12)
				spawnIceBubbles(feetWorldPos(base, hum), 6)
				startWorkSound()
			end
			return
		end

		-- work: dig + dust + coral rise; avatar rides on top
		local workU = math.clamp((now - phaseT0) / workSec, 0, 1)
		if riseP and riseP.Parent and buriedCF and finalCF then
			setCoralRiseAlpha(riseP, buriedCF, finalCF, workU)
			base = standOnCoralCF(riseP, hum, lookAtPlant)
		end
		-- R6 (no waist weld): lean the whole root. R15 waist bend runs in dig pose.
		local hasUpper = hrp.Parent and hrp.Parent:FindFirstChild("UpperTorso") ~= nil
		local bendRad = if hasUpper then 0 else math.rad(DIG_BEND_DEG) * digBendAlpha(now - phaseT0)
		local standCF = if bendRad > 1e-4 then base * CFrame.Angles(-bendRad, 0, 0) else base
		hrp.CFrame = standCF
		if dustHost and dustHost.Parent then
			dustHost.CFrame = CFrame.new(feetWorldPos(standCF, hum))
		end

		local bucket = math.floor((now - phaseT0) / (DIG_CYCLE_SEC * 0.5))
		if dustPe and bucket ~= lastDustBucket then
			lastDustBucket = bucket
			dustPe:Emit(8)
			spawnIceBubbles(feetWorldPos(standCF, hum), 3)
		end

		if workU >= 1 then
			pcall(function()
				RunService:UnbindFromRenderStep(DASH_BIND_NAME)
			end)
			finish(token, hrp, wasAnchored, dustHost, onDone)
		end
	end)
	return true
end

local harvestDustHost: BasePart? = nil
local harvestDustConn: RBXScriptConnection? = nil
local tripRestore: (() -> ())? = nil

local function stopHarvestDust()
	if harvestDustConn then
		harvestDustConn:Disconnect()
		harvestDustConn = nil
	end
	destroyDust(harvestDustHost)
	harvestDustHost = nil
end

-- Dig in place. No dash and no camera change. Dust puffs at the feet. Caller owns the hold timer.
function PlantWorkerVfx.beginInPlaceDig(): boolean
	if playerGui:GetAttribute(ATTR_BUSY) == true or playerGui:GetAttribute(ATTR_DIG_CAM) == true then
		return false
	end
	local _, hum, root = getCharacterParts()
	if not hum or not root then
		return false
	end
	playToken += 1
	ensureDigShovel()
	startDig(hum, playToken)
	stopHarvestDust()
	local host, pe = makeDustHost(feetWorldPos(root.CFrame, hum))
	harvestDustHost = host
	pe:Emit(12)
	local lastBucket = -1
	harvestDustConn = RunService.Heartbeat:Connect(function()
		if not root.Parent or not hum.Parent then
			return
		end
		host.CFrame = CFrame.new(feetWorldPos(root.CFrame, hum))
		local bucket = math.floor(os.clock() / (DIG_CYCLE_SEC * 0.5))
		if bucket ~= lastBucket then
			lastBucket = bucket
			pe:Emit(8)
		end
	end)
	startWorkSound()
	return true
end

function PlantWorkerVfx.endInPlaceDig()
	playToken += 1
	stopDigTrack()
	stopHarvestDust()
	stopWorkSound(true)
	releaseDigShovel()
end

-- Free cam: dash to the coral, dig (with dust), then dash back to the saved pose. No camera steal.
function PlantWorkerVfx.playHarvestTrip(
	worldPos: Vector3,
	workSec: number,
	onDigAlpha: (number) -> (),
	onDone: () -> ()
): boolean
	if playerGui:GetAttribute(ATTR_BUSY) == true or playerGui:GetAttribute(ATTR_DIG_CAM) == true then
		return false
	end
	local _, hum, root = getCharacterParts()
	if not hum or not root or typeof(worldPos) ~= "Vector3" then
		return false
	end
	playToken += 1
	local token = playToken
	stopDigTrack()
	stopRunTrack()
	stopHarvestDust()
	local home = root.CFrame
	local wasAnchored = root.Anchored
	local savedWalk = hum.WalkSpeed
	local savedJump = hum.JumpHeight
	root.Anchored = true
	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero
	hum.WalkSpeed = 0
	hum.JumpHeight = 0
	hum.AutoRotate = false
	ensureDigShovel()
	local startCF, goalCF = standCFrame(root.Position, worldPos, hum, nil)
	root.CFrame = startCF
	local phase = "dash"
	local phaseT0 = os.clock()
	local dustHost: BasePart? = nil
	local dustPe: ParticleEmitter? = nil
	local lastBucket = -1
	startRunSound()
	local runAnim = ensureRunTrack(hum)
	if runAnim then
		runAnim:Play(0.04, 1, RUN_PLAY_SPEED)
	end
	local digSec = if workSec > 0 then workSec else WORK_SEC

	local function restoreBody()
		tripRestore = nil
		stopDigTrack()
		stopRunTrack()
		stopRunSound()
		stopWorkSound(true)
		destroyDust(dustHost)
		dustHost = nil
		releaseDigShovel()
		if hum.Parent then
			hum.WalkSpeed = savedWalk
			hum.JumpHeight = savedJump
			hum.AutoRotate = true
		end
		if root.Parent then
			root.CFrame = home
			root.Anchored = wasAnchored
			root.AssemblyLinearVelocity = Vector3.zero
			root.AssemblyAngularVelocity = Vector3.zero
		end
	end
	tripRestore = restoreBody

	RunService:BindToRenderStep(DASH_BIND_NAME, Enum.RenderPriority.Last.Value, function()
		if token ~= playToken or not root.Parent or not hum.Parent then
			pcall(function()
				RunService:UnbindFromRenderStep(DASH_BIND_NAME)
			end)
			if token == playToken then
				restoreBody()
			end
			return
		end
		local now = os.clock()
		if phase == "dash" then
			local u = math.clamp((now - phaseT0) / DASH_SEC, 0, 1)
			local a = easeOutQuad(u)
			local pos = startCF.Position:Lerp(goalCF.Position, a)
			root.CFrame = lookFlat(pos, goalCF.Position, goalCF.LookVector)
			if u >= 1 then
				root.CFrame = goalCF
				stopRunSound()
				stopRunTrack()
				phase = "dig"
				phaseT0 = now
				startDig(hum, token)
				local host, pe = makeDustHost(feetWorldPos(goalCF, hum))
				dustHost = host
				dustPe = pe
				pe:Emit(12)
				startWorkSound()
			end
			return
		end
		if phase == "dig" then
			local u = math.clamp((now - phaseT0) / digSec, 0, 1)
			if dustHost and dustHost.Parent then
				dustHost.CFrame = CFrame.new(feetWorldPos(goalCF, hum))
			end
			local bucket = math.floor((now - phaseT0) / (DIG_CYCLE_SEC * 0.5))
			if dustPe and bucket ~= lastBucket then
				lastBucket = bucket
				dustPe:Emit(8)
			end
			onDigAlpha(u)
			if u >= 1 then
				stopDigTrack()
				stopWorkSound(true)
				destroyDust(dustHost)
				dustHost = nil
				phase = "return"
				phaseT0 = now
				startRunSound()
				local backRun = ensureRunTrack(hum)
				if backRun then
					backRun:Play(0.04, 1, RUN_PLAY_SPEED)
				end
			end
			return
		end
		local u = math.clamp((now - phaseT0) / DASH_SEC, 0, 1)
		local a = easeOutQuad(u)
		local pos = goalCF.Position:Lerp(home.Position, a)
		root.CFrame = lookFlat(pos, home.Position, home.LookVector)
		if u >= 1 then
			root.CFrame = home
			pcall(function()
				RunService:UnbindFromRenderStep(DASH_BIND_NAME)
			end)
			restoreBody()
			onDone()
		end
	end)
	return true
end

function PlantWorkerVfx.cancelHarvestTrip()
	playToken += 1
	pcall(function()
		RunService:UnbindFromRenderStep(DASH_BIND_NAME)
	end)
	local restore = tripRestore
	tripRestore = nil
	if restore then
		restore()
		return
	end
	stopDigTrack()
	stopRunTrack()
	stopRunSound()
	stopWorkSound(true)
	stopHarvestDust()
	releaseDigShovel()
end

function PlantWorkerVfx.cancel()
	playToken += 1
	pcall(function()
		RunService:UnbindFromRenderStep(DASH_BIND_NAME)
	end)
	local restore = tripRestore
	tripRestore = nil
	if restore then
		restore()
	end
	stopDigTrack()
	stopRunTrack()
	stopRunSound()
	stopWorkSound(true)
	pcall(function()
		RunService:UnbindFromRenderStep(DASH_BIND_NAME)
	end)
	restoreCoralRise()
	restoreDigCamImmediate()
	releaseDigShovel()
	local cam = Workspace.CurrentCamera
	local folder = cam and cam:FindFirstChild("OceanTD_LocalFX")
	if folder then
		local dust = folder:FindFirstChild("OceanTD_PlantWorkerDust")
		if dust then
			dust:Destroy()
		end
	end
	clearIceBubbles()
	local _c, _h, hrp = getCharacterParts()
	if hrp then
		hrp.Anchored = false
	end
	setBusy(false)
end

player.CharacterRemoving:Connect(function()
	PlantWorkerVfx.cancel()
	digTrack = nil
	digTrackAnimator = nil
	runTrack = nil
	runTrackAnimator = nil
end)

player.CharacterAdded:Connect(function()
	digTrack = nil
	digTrackAnimator = nil
	runTrack = nil
	runTrackAnimator = nil
end)

return PlantWorkerVfx
