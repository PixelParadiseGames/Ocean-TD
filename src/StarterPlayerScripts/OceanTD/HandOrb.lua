--!strict
-- Client-only right-hand orb. Other players never see it.
-- Plant: arm → neon seed in hand; disarm → scale out; place → fly to plant.
-- Wave Player Cam: feed hold → food orb in hand; throw → arm toss + orb leave/return.

local KeyframeSequenceProvider = game:GetService("KeyframeSequenceProvider")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local REST_SIZE = 1.15 * 1.3 -- 30% larger while armed
local HAND_OFFSET = CFrame.new(0, -0.15, -0.35)
local SCALE_IN_SEC = 0.28
local SCALE_OUT_SEC = 0.2
local FLY_FADE_SEC = 1
local FEED_COLOR = Color3.fromRGB(40, 255, 90)
-- Overhand baseball lob: wind-up behind head → whip over top → follow-through.
local THROW_SEC = 0.58
local THROW_ORB_OUT_SEC = 0.06
local THROW_ORB_BACK_SEC = 0.2
local THROW_ORB_GAP_SEC = 0.18 -- leave hand near release (~55% of THROW_SEC)
local THROW_BIND_NAME = "OceanTD_FeedThrow"
-- Bump when throw KeyframeSequence poses change (invalidates cached Register id).
local THROW_ANIM_VERSION = 2

local HandOrb = {}

local player = Players.LocalPlayer
local orb: Part? = nil
local followConn: RBXScriptConnection? = nil
local animToken = 0
local attached = false
local flying = false
local activeColor: Color3 = Color3.fromRGB(255, 220, 80)
local armed = false -- plant seed
local feedHold = false -- wave Player Cam food
local throwToken = 0
local throwBound = false
local throwAnimId: string? = nil
local throwAnimVersionRegistered: number? = nil
local throwTrack: AnimationTrack? = nil
local throwTrackAnimator: Animator? = nil

local ensureVisibleOrb: (Color3) -> ()
local stopThrowPose: () -> ()

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

local function rightHand(): BasePart?
	local character = player.Character
	if not character then
		return nil
	end
	local hand = character:FindFirstChild("RightHand") or character:FindFirstChild("Right Arm")
	if hand and hand:IsA("BasePart") then
		return hand
	end
	return nil
end

local function findMotor(name: string): Motor6D?
	local character = player.Character
	if not character then
		return nil
	end
	local m = character:FindFirstChild(name, true)
	if m and m:IsA("Motor6D") then
		return m
	end
	return nil
end

local function throwWeights(u: number): (number, number, number)
	local t = math.clamp(u, 0, 1)
	local wind = if t < 0.32 then (t / 0.32) elseif t < 0.45 then 1 - (t - 0.32) / 0.13 else 0
	local whip = if t < 0.32 then 0 elseif t < 0.58 then (t - 0.32) / 0.26 else 1 - math.clamp((t - 0.58) / 0.2, 0, 1) * 0.35
	local follow = if t < 0.58 then 0 else (t - 0.58) / 0.42
	wind = wind * wind * (3 - 2 * wind)
	whip = math.clamp(whip, 0, 1)
	whip = whip * whip * (3 - 2 * whip)
	follow = follow * follow * (3 - 2 * follow)
	return wind, whip, follow
end

local function getAnimator(): Animator?
	local character = player.Character
	if not character then
		return nil
	end
	local hum = character:FindFirstChildOfClass("Humanoid")
	if not hum then
		return nil
	end
	local animator = hum:FindFirstChildOfClass("Animator")
	if animator then
		return animator
	end
	local created = Instance.new("Animator")
	created.Parent = hum
	return created
end

-- Local KeyframeSequence → AnimationTrack (no uploaded asset). R15 pose tree.
local function buildThrowSequence(): KeyframeSequence
	local seq = Instance.new("KeyframeSequence")
	seq.Loop = false
	seq.Priority = Enum.AnimationPriority.Action4

	local function addKey(
		t: number,
		upperArm: CFrame,
		lowerArm: CFrame,
		hand: CFrame,
		torsoYaw: number
	)
		local kf = Instance.new("Keyframe")
		kf.Time = t
		local root = Instance.new("Pose")
		root.Name = "HumanoidRootPart"
		local lower = Instance.new("Pose")
		lower.Name = "LowerTorso"
		local upper = Instance.new("Pose")
		upper.Name = "UpperTorso"
		upper.CFrame = CFrame.Angles(0, torsoYaw, 0)
		local rua = Instance.new("Pose")
		rua.Name = "RightUpperArm"
		rua.CFrame = upperArm
		local rla = Instance.new("Pose")
		rla.Name = "RightLowerArm"
		rla.CFrame = lowerArm
		local rh = Instance.new("Pose")
		rh.Name = "RightHand"
		rh.CFrame = hand
		rh.Parent = rla
		rla.Parent = rua
		rua.Parent = upper
		upper.Parent = lower
		lower.Parent = root
		root.Parent = kf
		kf.Parent = seq
	end

	local rest = CFrame.new()
	-- Hand stays identity — wrist Euler flips were spinning the palm during raise.
	-- Shoulder roll stays continuous so interp doesn't corkscrew the arm.
	addKey(0, rest, rest, rest, 0)
	-- Wind-up: cock up/back, elbow bent (modest roll).
	addKey(
		0.16,
		CFrame.Angles(math.rad(-125), math.rad(-35), math.rad(55)),
		CFrame.Angles(math.rad(-95), 0, 0),
		rest,
		math.rad(-16)
	)
	-- Mid raise → still cocked (bridge key so roll doesn't jump).
	addKey(
		0.26,
		CFrame.Angles(math.rad(-70), math.rad(5), math.rad(70)),
		CFrame.Angles(math.rad(-55), 0, 0),
		rest,
		math.rad(2)
	)
	-- Release: whip over the top, arm extending forward-high.
	addKey(
		0.34,
		CFrame.Angles(math.rad(-15), math.rad(35), math.rad(85)),
		CFrame.Angles(math.rad(-20), 0, 0),
		rest,
		math.rad(18)
	)
	-- Follow-through: across / down (roll eases down with pitch).
	addKey(
		0.48,
		CFrame.Angles(math.rad(40), math.rad(40), math.rad(50)),
		CFrame.Angles(math.rad(-12), 0, 0),
		rest,
		math.rad(8)
	)
	addKey(THROW_SEC, rest, rest, rest, 0)
	return seq
end

local function ensureThrowTrack(): AnimationTrack?
	local animator = getAnimator()
	if not animator then
		return nil
	end
	if throwAnimVersionRegistered ~= THROW_ANIM_VERSION then
		throwAnimId = nil
		throwTrack = nil
		throwTrackAnimator = nil
		throwAnimVersionRegistered = THROW_ANIM_VERSION
	end
	if throwTrack and throwTrackAnimator == animator then
		return throwTrack
	end
	if not throwAnimId then
		local ok, idOrErr = pcall(function()
			return KeyframeSequenceProvider:RegisterKeyframeSequence(buildThrowSequence())
		end)
		if not ok or typeof(idOrErr) ~= "string" then
			return nil
		end
		throwAnimId = idOrErr
	end
	local anim = Instance.new("Animation")
	anim.AnimationId = throwAnimId :: string
	local okLoad, trackOrErr = pcall(function()
		return animator:LoadAnimation(anim)
	end)
	if not okLoad or typeof(trackOrErr) ~= "Instance" then
		return nil
	end
	local track = trackOrErr :: AnimationTrack
	track.Priority = Enum.AnimationPriority.Action4
	track.Looped = false
	throwTrack = track
	throwTrackAnimator = animator
	return track
end

local function stopFollow()
	if followConn then
		followConn:Disconnect()
		followConn = nil
	end
end

local function destroyOrb()
	stopFollow()
	if orb then
		orb:Destroy()
		orb = nil
	end
	attached = false
end

local function makeOrb(color: Color3, size: number): Part
	local p = Instance.new("Part")
	p.Name = "OceanTD_HandOrb"
	p.Shape = Enum.PartType.Ball
	p.Material = Enum.Material.Neon
	p.Color = color
	p.Size = Vector3.new(size, size, size)
	p.Anchored = true
	p.CanCollide = false
	p.CanTouch = false
	p.CanQuery = false
	p.CastShadow = false
	p.Massless = true
	p.Transparency = 0
	p.Parent = fxFolder()
	return p
end

local function startFollow(part: Part)
	stopFollow()
	attached = true
	followConn = RunService.RenderStepped:Connect(function()
		if not attached or not part.Parent then
			return
		end
		local hand = rightHand()
		if hand then
			part.CFrame = hand.CFrame * HAND_OFFSET
		end
	end)
end

local function tweenSize(part: Part, from: number, to: number, sec: number, token: number): () -> boolean
	local t0 = os.clock()
	local done = false
	local conn: RBXScriptConnection
	conn = RunService.RenderStepped:Connect(function()
		if token ~= animToken or not part.Parent then
			conn:Disconnect()
			done = true
			return
		end
		local u = if sec <= 0 then 1 else math.clamp((os.clock() - t0) / sec, 0, 1)
		local a = 1 - (1 - u) * (1 - u)
		local s = from + (to - from) * a
		part.Size = Vector3.new(s, s, s)
		if u >= 1 then
			part.Size = Vector3.new(to, to, to)
			conn:Disconnect()
			done = true
		end
	end)
	return function()
		return done
	end
end

ensureVisibleOrb = function(color: Color3)
	activeColor = color
	if flying then
		return
	end
	animToken += 1
	local token = animToken
	if orb and orb.Parent and attached then
		orb.Color = color
		orb.Transparency = 0
		local from = orb.Size.X
		tweenSize(orb, from, REST_SIZE, SCALE_IN_SEC, token)
		return
	end
	destroyOrb()
	orb = makeOrb(color, 0.05)
	startFollow(orb)
	tweenSize(orb, 0.05, REST_SIZE, SCALE_IN_SEC, token)
end

local function restoreAfterPlant()
	if armed or flying then
		return
	end
	if feedHold then
		ensureVisibleOrb(FEED_COLOR)
	else
		destroyOrb()
	end
end

stopThrowPose = function()
	throwToken += 1
	if throwBound then
		throwBound = false
		pcall(function()
			RunService:UnbindFromRenderStep(THROW_BIND_NAME)
		end)
	end
	local track = throwTrack
	if track then
		pcall(function()
			track:Stop(0.08)
		end)
	end
end

-- Fallback: force Motor6D.Transform after Animate (if KeyframeSequence fails).
local function playThrowPoseFallback()
	local shoulder = findMotor("RightShoulder") or findMotor("Right Shoulder")
	local elbow = findMotor("RightElbow")
	local wrist = findMotor("RightWrist")
	local waist = findMotor("Waist")
	if not shoulder then
		return
	end
	local my = throwToken
	local t0 = os.clock()
	throwBound = true
	RunService:BindToRenderStep(THROW_BIND_NAME, Enum.RenderPriority.Last.Value, function()
		if my ~= throwToken then
			return
		end
		if not shoulder.Parent then
			stopThrowPose()
			return
		end
		local u = math.clamp((os.clock() - t0) / THROW_SEC, 0, 1)
		local wind, whip, follow = throwWeights(u)
		shoulder.Transform = CFrame.Angles(
			math.rad(-120) * wind + math.rad(-15) * whip + math.rad(70) * follow,
			math.rad(-60) * wind + math.rad(45) * whip + math.rad(55) * follow,
			math.rad(80) * wind + math.rad(110) * whip + math.rad(35) * follow
		)
		if elbow then
			elbow.Transform = CFrame.Angles(
				math.rad(-105) * wind + math.rad(-20) * whip + math.rad(-10) * follow,
				0,
				0
			)
		end
		if wrist then
			-- Keep wrist locked; rotating it made the held orb/hand spin on raise.
			wrist.Transform = CFrame.new()
		end
		if waist then
			waist.Transform = CFrame.Angles(
				0,
				math.rad(-20) * wind + math.rad(25) * whip + math.rad(10) * follow,
				0
			)
		end
		if u >= 1 then
			throwBound = false
			pcall(function()
				RunService:UnbindFromRenderStep(THROW_BIND_NAME)
			end)
		end
	end)
end

-- Prefer a real Action4 AnimationTrack (overhand baseball); fall back to Transform.
local function playThrowPose()
	stopThrowPose()
	local track = ensureThrowTrack()
	if track then
		track:Play(0.05, 1, 1.05)
		return
	end
	playThrowPoseFallback()
end

function HandOrb.isArmed(): boolean
	return armed
end

function HandOrb.isFeedHold(): boolean
	return feedHold
end

function HandOrb.getHoldWorldPos(): Vector3?
	local hand = rightHand()
	if not hand then
		return nil
	end
	return (hand.CFrame * HAND_OFFSET).Position
end

-- Wave Player Cam: keep a food orb in-hand (plant seed still wins while armed).
function HandOrb.setFeedHold(on: boolean)
	if feedHold == on then
		if on and not armed and not flying then
			ensureVisibleOrb(FEED_COLOR)
		end
		return
	end
	feedHold = on
	if armed or flying then
		return
	end
	if on then
		ensureVisibleOrb(FEED_COLOR)
	else
		stopThrowPose()
		animToken += 1
		destroyOrb()
	end
end

-- Lob pose + hand orb leaves briefly, then a fresh food returns (feed hold only).
function HandOrb.playFeedThrow()
	if not feedHold or armed then
		return
	end
	playThrowPose()
	if flying then
		return
	end
	animToken += 1
	local token = animToken
	local part = orb
	if part and part.Parent and attached then
		local from = part.Size.X
		task.spawn(function()
			local isDone = tweenSize(part, from, 0.05, THROW_ORB_OUT_SEC, token)
			while not isDone() do
				RunService.RenderStepped:Wait()
			end
			if token ~= animToken then
				return
			end
			destroyOrb()
			task.wait(THROW_ORB_GAP_SEC)
			if token ~= animToken or not feedHold or armed then
				return
			end
			animToken += 1
			local backToken = animToken
			local fresh = makeOrb(FEED_COLOR, 0.05)
			orb = fresh
			startFollow(fresh)
			tweenSize(fresh, 0.05, REST_SIZE, THROW_ORB_BACK_SEC, backToken)
		end)
	elseif feedHold and not armed then
		task.delay(THROW_ORB_OUT_SEC + THROW_ORB_GAP_SEC, function()
			if not feedHold or armed or flying then
				return
			end
			ensureVisibleOrb(FEED_COLOR)
		end)
	end
end

function HandOrb.arm(color: Color3)
	armed = true
	activeColor = color
	-- Successful plant-fly owns the orb until it returns; don't interrupt it.
	if flying then
		return
	end
	stopThrowPose()
	ensureVisibleOrb(color)
end

function HandOrb.disarm(durationSec: number?)
	armed = false
	flying = false
	animToken += 1
	local token = animToken
	local part = orb
	if not part or not part.Parent then
		restoreAfterPlant()
		return
	end
	local from = part.Size.X
	local sec = if typeof(durationSec) == "number" and durationSec > 0 then durationSec else SCALE_OUT_SEC
	task.spawn(function()
		local isDone = tweenSize(part, from, 0.05, sec, token)
		while not isDone() do
			RunService.RenderStepped:Wait()
		end
		if token ~= animToken then
			return
		end
		destroyOrb()
		restoreAfterPlant()
	end)
end

function HandOrb.flyToPlant(worldPos: Vector3)
	if not armed then
		return
	end
	animToken += 1
	local token = animToken
	local part = orb
	local color = activeColor
	flying = true
	stopThrowPose()

	if not part or not part.Parent then
		task.delay(FLY_FADE_SEC, function()
			flying = false
			if token ~= animToken or not armed then
				restoreAfterPlant()
				return
			end
			HandOrb.arm(color)
		end)
		return
	end

	stopFollow()
	attached = false
	orb = nil
	part.Transparency = 0
	local startCF = part.CFrame
	local startSize = part.Size.X
	local t0 = os.clock()

	local conn: RBXScriptConnection
	conn = RunService.RenderStepped:Connect(function()
		if token ~= animToken or not part.Parent then
			conn:Disconnect()
			flying = false
			if part.Parent then
				part:Destroy()
			end
			return
		end
		local u = math.clamp((os.clock() - t0) / FLY_FADE_SEC, 0, 1)
		local a = 1 - (1 - u) * (1 - u)
		local pos = startCF.Position:Lerp(worldPos, a)
		part.CFrame = CFrame.new(pos)
		part.Transparency = a
		local s = startSize * (1 - 0.5 * a)
		part.Size = Vector3.new(s, s, s)
		if u >= 1 then
			conn:Disconnect()
			part:Destroy()
			flying = false
			if token == animToken and armed then
				local fresh = makeOrb(color, 0.05)
				orb = fresh
				startFollow(fresh)
				tweenSize(fresh, 0.05, REST_SIZE, SCALE_IN_SEC, token)
			elseif token == animToken then
				restoreAfterPlant()
			end
		end
	end)
end

function HandOrb.clear()
	armed = false
	flying = false
	stopThrowPose()
	animToken += 1
	destroyOrb()
	if feedHold then
		ensureVisibleOrb(FEED_COLOR)
	end
end

player.CharacterRemoving:Connect(function()
	feedHold = false
	stopThrowPose()
	throwTrack = nil
	throwTrackAnimator = nil
	armed = false
	flying = false
	animToken += 1
	destroyOrb()
end)

player.CharacterAdded:Connect(function()
	throwTrack = nil
	throwTrackAnimator = nil
	if feedHold and not armed then
		task.defer(function()
			if feedHold and not armed then
				ensureVisibleOrb(FEED_COLOR)
			end
		end)
	end
end)

return HandOrb
