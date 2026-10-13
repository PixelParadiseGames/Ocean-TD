--!strict
--[[
	Client-only Lego-style plant worker (Plot / Fish / Free cam).
	Dash beside coral → dig 3s with dust → coral rises from underground. Camera untouched.
]]

local KeyframeSequenceProvider = game:GetService("KeyframeSequenceProvider")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local Workspace = game:GetService("Workspace")

local ClientPlot = require(script.Parent:WaitForChild("ClientPlot"))

local ATTR_BUSY = "OceanTD_PlantWorkerBusy"
local ATTR_CAM = "OceanTD_CamCycleMode"

-- Travel a bit longer than the original 0.32s dash; legs animate separately (silly-fast).
local DASH_SEC = 0.95
local WORK_SEC = 3
local STAND_OFFSET = 1.15 -- slight offset from coral center (stand on/at the plant spot)
local DIG_CYCLE_SEC = 0.2 -- 5 full up/down cycles per second
local RUN_CYCLE_SEC = 0.14 -- short loop; played at RUN_PLAY_SPEED for cartoon legs
local RUN_PLAY_SPEED = 3.4
local DIG_ANIM_VERSION = 2 -- Action4 dig track primary again (Motor6D-only was overwritten by Animate)
local RUN_ANIM_VERSION = 1
local LAND_SQUASH_SEC = 0.14
local LAND_DIP_STUDS = 0.22
local RAY_UP = 60
local RAY_DOWN = 180
local CORAL_BURY_MIN = 2.8
local CORAL_BURY_PAD = 1.2
local DUST_TEXTURE = "rbxasset://textures/particles/smoke_main.dds"
local RUN_SOUND_ID = "rbxassetid://75773150278794"
local WORK_SOUND_ID = "rbxassetid://76312376951471"
local RUN_FADE_IN_SEC = 0.2
local WORK_FADE_OUT_SEC = 0.5
local RUN_VOL = 0.9
local WORK_VOL = 0.9

local PlantWorkerVfx = {}

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui") :: PlayerGui

local playToken = 0
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

export type PlayOpts = {
	coralPart: BasePart?,
	onDone: (() -> ())?,
}

local function isWorkerCam(): boolean
	local m = playerGui:GetAttribute(ATTR_CAM)
	return m == "plotcam" or m == "fishcam" or m == "dronecam"
end

local function setBusy(on: boolean)
	playerGui:SetAttribute(ATTR_BUSY, on == true)
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

-- Disable Animator entirely for dig — welds own the limbs (works Studio + live/mobile).
local function playDigFallback(token: number, hum: Humanoid)
	local character = player.Character
	if not character then
		return
	end
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

	-- Freeze arm motors so Animator / physics cannot fight dig welds.
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
	for _, d in ipairs(character:GetDescendants()) do
		if d:IsA("Motor6D") and d.Part1 and limbSet[d.Part1] then
			d.Enabled = false
			d.Transform = CFrame.new()
			table.insert(digDisabledMotors, d)
		end
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
		local phase = ((os.clock() - t0) / DIG_CYCLE_SEC) % 1
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
	fadeSoundTo(s, RUN_VOL, RUN_FADE_IN_SEC, false)
end

local function startWorkSound()
	stopWorkSound(false)
	local s = makeSfx("OceanTD_PlantWorkerWork", WORK_SOUND_ID, WORK_VOL)
	s.Looped = true
	workSound = s
	s:Play()
end

local function groundHipY(xzX: number, xzZ: number, hintY: number, hum: Humanoid): number
	local hip = if hum.HipHeight > 0.5 then hum.HipHeight else 2
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

-- Stand on top of the coral (rises with it while buried → final).
local function standOnCoralCF(part: BasePart, hum: Humanoid, lookAt: Vector3): CFrame
	local top = coralTopWorld(part)
	local hip = if hum.HipHeight > 0.5 then hum.HipHeight else 2
	local pos = Vector3.new(top.X, top.Y + hip, top.Z)
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
	local hip = if hum.HipHeight > 0.5 then hum.HipHeight else 2
	return standCF.Position - Vector3.new(0, hip * 0.92, 0)
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
	if hrp and hrp.Parent then
		hrp.Anchored = wasAnchored
	end
	setBusy(false)
	if onDone then
		task.defer(onDone)
	end
end

function PlantWorkerVfx.playAt(worldPos: Vector3, opts: PlayOpts?): boolean
	if typeof(worldPos) ~= "Vector3" then
		return false
	end
	if not isWorkerCam() then
		return false
	end
	local character, hum, hrp = getCharacterParts()
	if not character or not hum or not hrp then
		return false
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
	if runAnim then
		runAnim:Play(0.04, 1, RUN_PLAY_SPEED)
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
		if not isWorkerCam() then
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
			local u = math.clamp((now - phaseT0) / DASH_SEC, 0, 1)
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
				startWorkSound()
			end
			return
		end

		-- work: dig + dust + coral rise; avatar rides on top
		local workU = math.clamp((now - phaseT0) / WORK_SEC, 0, 1)
		if riseP and riseP.Parent and buriedCF and finalCF then
			setCoralRiseAlpha(riseP, buriedCF, finalCF, workU)
			base = standOnCoralCF(riseP, hum, lookAtPlant)
		end
		hrp.CFrame = base
		if dustHost and dustHost.Parent then
			dustHost.CFrame = CFrame.new(feetWorldPos(base, hum))
		end

		local bucket = math.floor((now - phaseT0) / (DIG_CYCLE_SEC * 0.5))
		if dustPe and bucket ~= lastDustBucket then
			lastDustBucket = bucket
			dustPe:Emit(8)
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

function PlantWorkerVfx.cancel()
	playToken += 1
	stopDigTrack()
	stopRunTrack()
	stopRunSound()
	stopWorkSound(true)
	pcall(function()
		RunService:UnbindFromRenderStep(DASH_BIND_NAME)
	end)
	restoreCoralRise()
	local cam = Workspace.CurrentCamera
	local folder = cam and cam:FindFirstChild("OceanTD_LocalFX")
	if folder then
		local dust = folder:FindFirstChild("OceanTD_PlantWorkerDust")
		if dust then
			dust:Destroy()
		end
	end
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
