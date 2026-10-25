--!strict
--[[
	Batches "hunger bar filled" events from WaveSim → server ReportFishFed.
	Server decides $D (EarnMore stage). Client only reports fish count.
	Juice: the sand-dollar circle flies fish → $DCount.
	Also: end-of-wave stream from Wave HUD bar → $DCount (1 badge per $D earned).
]]

local Players = game:GetService("Players")
local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local Remotes = require(oceanRoot:WaitForChild("Remotes"))
local Constants = require(oceanRoot:WaitForChild("Shared"):WaitForChild("Constants"))
local LeftHudLayout = require(oceanRoot:WaitForChild("Shared"):WaitForChild("LeftHudLayout"))
local SkillStages = require(oceanRoot:WaitForChild("Shared"):WaitForChild("SkillStages"))
local UiPopupScale = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiPopupScale"))
local UiTheme = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiTheme"))
local WaveSimConsts = require(script.Parent:WaitForChild("WaveSimConsts"))

local WaveFeedPayout = {}

local FLY_SEC = 0.55
local FLY_CIRCLE = 52
local FLY_CIRCLE_IMAGE = "rbxassetid://74290598144610"
local FLY_CIRCLE_BG = Color3.fromRGB(6, 90, 38)
local COUNT_NAME = Constants.SAND_DOLLARS_COUNT_NAME
-- Wave-clear burst: clustered multi-flies (not single-file), short max when many.
local STREAM_MIN_SEC = 0.55
local STREAM_MAX_SEC = 3.2
local STREAM_PER_D_SEC = 0.045
local STREAM_FLY_SEC = 1.24 -- half prior speed (was 0.62)
local STREAM_FLY_RATE_MIN = 0.82 -- per-$D duration mult (higher = slower)
local STREAM_FLY_RATE_MAX = 1.18
local STREAM_BATCH = 5 -- how many launch nearly together
local STREAM_ARC_SPREAD = 0.55 -- vary arc side/strength so paths don't stack
-- Audible gap between coin pitches (visuals stay clustered; audio is one-per-$D).
local STREAM_COIN_PITCH_MIN = 0.78
local STREAM_COIN_PITCH_MAX = 1.45
local STREAM_COIN_PITCH_STEP = 0.1
-- Cap overlap so pitched hits stay distinct (coin asset is short; don't cut too early).
local STREAM_COIN_PLINK_SEC = 0.28
-- Per-fish $D fly (world → counter). Off: only wave-HUD stream shows flies.
local SHOW_FISH_FLY = false

local pending = 0
local flushQueued = false
local remote: RemoteEvent? = nil
local gainListener: ((number) -> ())? = nil
local dollarOriginFn: (() -> Vector2?)? = nil
local overlay: ScreenGui? = nil
local cachedCount: GuiObject? = nil
local waveDollarsEarned = 0
local streamPlayedThisWave = false
local streamToken = 0
local streamPitchCursor = STREAM_COIN_PITCH_MIN

local coinSound = Instance.new("Sound")
coinSound.Name = "OceanTD_SandDollarCoin"
-- Coin only — never FEED_SOUND_ID or WAVE_ADVANCE_SOUND_ID.
coinSound.SoundId = WaveSimConsts.SAND_DOLLAR_COIN_SOUND_ID
coinSound.Volume = 0.95
coinSound.Parent = SoundService

task.defer(function()
	pcall(function()
		game:GetService("ContentProvider"):PreloadAsync({ coinSound })
	end)
end)

local player = Players.LocalPlayer

local function playStreamCoinSound()
	local pitch = streamPitchCursor
	streamPitchCursor += STREAM_COIN_PITCH_STEP
	if streamPitchCursor > STREAM_COIN_PITCH_MAX then
		streamPitchCursor = STREAM_COIN_PITCH_MIN
	end
	-- Force coin asset every hit (never feed / never next-wave).
	coinSound.SoundId = WaveSimConsts.SAND_DOLLAR_COIN_SOUND_ID
	local snd = coinSound:Clone()
	snd.Name = "OceanTD_SandDollarCoinHit"
	snd.SoundId = WaveSimConsts.SAND_DOLLAR_COIN_SOUND_ID
	snd.PlaybackSpeed = pitch
	snd.Volume = 0.95
	snd.Parent = SoundService
	snd:Play()
	local len = if snd.TimeLength > 0.05 then snd.TimeLength else STREAM_COIN_PLINK_SEC
	local ttl = math.min(STREAM_COIN_PLINK_SEC, len) / math.max(0.2, pitch) + 0.05
	task.delay(ttl, function()
		pcall(function()
			snd:Stop()
			snd:Destroy()
		end)
	end)
end

local function dollarsPerFish(): number
	local stage = 1
	local ok, SkillPowerUpUI = pcall(function()
		return require(script.Parent:WaitForChild("SkillPowerUpUI"))
	end)
	if ok and SkillPowerUpUI and typeof(SkillPowerUpUI.getStage) == "function" then
		stage = SkillPowerUpUI.getStage("EarnMore")
	end
	return math.max(1, SkillStages.earnMorePerFish(stage))
end

local function getRemote(): RemoteEvent
	if remote then
		return remote
	end
	remote = Remotes.get("ReportFishFed")
	return remote
end

local function flushCount(n: number)
	flushQueued = false
	if n <= 0 then
		return
	end
	-- Total HUD should tick up quietly. The +1 already played on the wave circle.
	player:SetAttribute("OceanTD_DollarQuietGain", true)
	local speed = 1
	pcall(function()
		local WaveSim = require(script.Parent:WaitForChild("WaveSim"))
		if typeof(WaveSim.getSpeedMult) == "function" then
			speed = WaveSim.getSpeedMult()
		end
	end)
	local ok, err = pcall(function()
		getRemote():FireServer(n, speed)
	end)
	if not ok then
		warn("[ECONOMY] ReportFishFed failed", err)
	end
end

function WaveFeedPayout.setGainListener(fn: (number) -> ())
	gainListener = fn
end

function WaveFeedPayout.setDollarOrigin(fn: () -> Vector2?)
	dollarOriginFn = fn
end

local function getOverlay(): ScreenGui
	if overlay and overlay.Parent then
		return overlay
	end
	local pg = player:WaitForChild("PlayerGui")
	local existing = pg:FindFirstChild("OceanTD_SandDollarFly")
	if existing and existing:IsA("ScreenGui") then
		existing.DisplayOrder = 400
		overlay = existing
		return existing
	end
	local sg = Instance.new("ScreenGui")
	sg.Name = "OceanTD_SandDollarFly"
	sg.ResetOnSpawn = false
	sg.IgnoreGuiInset = true
	sg.DisplayOrder = 400 -- in front of the right HUD (250), under the wave-title overlays
	sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	sg.Parent = pg
	overlay = sg
	return sg
end

local function getCountGui(): GuiObject?
	if cachedCount and cachedCount.Parent then
		return cachedCount
	end
	local pg = player:FindFirstChild("PlayerGui")
	if not pg then
		return nil
	end
	local left = pg:FindFirstChild("MobileLeftUI")
	if not left then
		return nil
	end
	local count = LeftHudLayout.findDCount(left)
	if count then
		cachedCount = count
		return count
	end
	return nil
end

local function worldToScreen(worldPos: Vector3): Vector2?
	local cam = Workspace.CurrentCamera
	if not cam then
		return nil
	end
	local v, onScreen = cam:WorldToViewportPoint(worldPos)
	if v.Z <= 0 then
		return nil
	end
	local vp = cam.ViewportSize
	local x = v.X
	local y = v.Y
	if not onScreen then
		x = math.clamp(x, 24, vp.X - 24)
		y = math.clamp(y, 24, vp.Y - 24)
	end
	return Vector2.new(x, y)
end

local function countScreenCenter(): Vector2?
	local count = getCountGui()
	if not count or count.AbsoluteSize.X < 2 then
		cachedCount = nil
		count = getCountGui()
	end
	if not count or count.AbsoluteSize.X < 2 then
		return nil
	end
	return count.AbsolutePosition + count.AbsoluteSize * 0.5
end

local function flyHost(): ScreenGui?
	local count = getCountGui()
	local host = count and count:FindFirstAncestorOfClass("ScreenGui")
	if host then
		return host
	end
	return getOverlay()
end

-- Same space as the +1 fed fly: parent to the count's ScreenGui and subtract its origin.
local function toHostLocal(host: ScreenGui, abs: Vector2): Vector2
	local origin = host.AbsolutePosition
	return Vector2.new(abs.X - origin.X, abs.Y - origin.Y)
end

local function punchCount()
	local count = getCountGui()
	if not count then
		return
	end
	local scale = count:FindFirstChild(LeftHudLayout.PUNCH_SCALE_NAME)
	if not scale or not scale:IsA("UIScale") then
		scale = Instance.new("UIScale")
		scale.Name = LeftHudLayout.PUNCH_SCALE_NAME
		scale.Scale = 1
		scale.Parent = count
	end
	scale.Scale = 1.18
	TweenService:Create(scale, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Scale = 1 }):Play()
end

local function flyDollarFromScreen(start: Vector2, flySec: number?, onLand: (() -> ())?, arcBias: number?, playCoin: boolean?)
	local destAbs = countScreenCenter()
	if not destAbs then
		if onLand then
			onLand()
		end
		return
	end
	local host = flyHost()
	local from = toHostLocal(host, start)
	local dest = toHostLocal(host, destAbs)
	local mid = (from + dest) * 0.5
	local delta = dest - from
	-- Mild upward arc; endpoint stays locked to $DCount center.
	-- arcBias (-1..1) fans control points so clustered flies don't share one path.
	local bias = if typeof(arcBias) == "number" then math.clamp(arcBias, -1, 1) else 0
	local len = math.max(40, delta.Magnitude)
	local arc = Vector2.new(-delta.Y, delta.X)
	if arc.Magnitude > 1e-3 then
		arc = arc.Unit * math.clamp(len * (0.18 + 0.12 * math.abs(bias)), 20, 100)
		-- Blend side-shift so neighbors peel apart without scattering wide.
		local along = delta.Unit
		arc = arc + along * (bias * len * 0.08) + Vector2.new(-along.Y, along.X) * (bias * 18)
	else
		arc = Vector2.new(bias * 28, -36)
	end
	if arc.Y > 0 then
		arc = Vector2.new(arc.X, -math.abs(arc.Y))
	end
	local ctrl = mid + arc
	local dur = if typeof(flySec) == "number" then math.max(0.25, flySec) else FLY_SEC
	local wantCoin = playCoin == true

	local sg = host
	local disc = Instance.new("Frame")
	disc.Name = "FlyD"
	disc.BackgroundColor3 = FLY_CIRCLE_BG
	disc.BorderSizePixel = 0
	disc.AnchorPoint = Vector2.new(0.5, 0.5)
	disc.Position = UDim2.fromOffset(from.X, from.Y)
	local side = math.floor(FLY_CIRCLE * (0.9 + math.random() * 0.2) + 0.5)
	disc.Size = UDim2.fromOffset(side, side)
	disc.ZIndex = 200
	disc.Parent = sg
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = disc
	local img = Instance.new("ImageLabel")
	img.Name = "SandDollar"
	img.BackgroundTransparency = 1
	img.Size = UDim2.fromScale(1, 1)
	img.Image = FLY_CIRCLE_IMAGE
	img.ScaleType = Enum.ScaleType.Fit
	img.ZIndex = 6
	img.Parent = disc
	local shrinkScale = Instance.new("UIScale")
	shrinkScale.Scale = 1
	shrinkScale.Parent = disc

	local t0 = os.clock()
	local conn: RBXScriptConnection? = nil
	conn = RunService.RenderStepped:Connect(function()
		if not disc.Parent then
			if conn then
				conn:Disconnect()
			end
			return
		end
		local liveAbs = countScreenCenter()
		if liveAbs then
			dest = toHostLocal(host, liveAbs)
			-- Keep control point relative to the live endpoint so the arc doesn't drift.
			mid = (from + dest) * 0.5
			delta = dest - from
			len = math.max(40, delta.Magnitude)
			arc = Vector2.new(-delta.Y, delta.X)
			if arc.Magnitude > 1e-3 then
				arc = arc.Unit * math.clamp(len * (0.18 + 0.12 * math.abs(bias)), 20, 100)
				local along = delta.Unit
				arc = arc + along * (bias * len * 0.08) + Vector2.new(-along.Y, along.X) * (bias * 18)
			else
				arc = Vector2.new(bias * 28, -36)
			end
			if arc.Y > 0 then
				arc = Vector2.new(arc.X, -math.abs(arc.Y))
			end
			ctrl = mid + arc
		end
		local u = math.clamp((os.clock() - t0) / dur, 0, 1)
		local e = u * u * (3 - 2 * u) -- smoothstep
		local omt = 1 - e
		local p = omt * omt * from + 2 * omt * e * ctrl + e * e * dest
		disc.Position = UDim2.fromOffset(p.X, p.Y)
		shrinkScale.Scale = 1 - 0.23 * e
		if u >= 1 then
			if conn then
				conn:Disconnect()
			end
			-- Snap exactly onto the counter before destroy.
			local finalAbs = countScreenCenter()
			if finalAbs then
				local final = toHostLocal(host, finalAbs)
				disc.Position = UDim2.fromOffset(final.X, final.Y)
			end
			punchCount()
			-- Coin plink when this $D reaches the counter (not on launch, not food-hit).
			if wantCoin then
				playStreamCoinSound()
			end
			disc:Destroy()
			if onLand then
				onLand()
			end
		end
	end)
end

local function flyDollar(worldPos: Vector3)
	local start = worldToScreen(worldPos)
	if not start then
		return
	end
	flyDollarFromScreen(start, FLY_SEC, nil)
end

local function waveBarScreenCenter(): Vector2?
	local pg = player:FindFirstChild("PlayerGui")
	if not pg then
		return nil
	end
	local hud = pg:FindFirstChild("OceanTD_WaveHud", true)
	local bar = if hud then hud:FindFirstChild("WaveProgress", true) else nil
	if not (bar and bar:IsA("GuiObject")) then
		return nil
	end
	local pos = bar.AbsolutePosition + bar.AbsoluteSize * 0.5
	return pos
end

function WaveFeedPayout.onWaveBegin()
	waveDollarsEarned = 0
	streamPlayedThisWave = false
	-- Do not bump streamToken here — that was cancelling in-flight HUD coin SFX / flies
	-- when the player tapped NEXT WAVE mid-stream.
end

function WaveFeedPayout.getWaveDollarsEarned(): number
	return waveDollarsEarned
end

-- Streams one "$D" per sand dollar earned this wave from the wave HUD bar → counter.
-- Safe to call multiple times; only plays once per wave until onWaveBegin.
function WaveFeedPayout.playWaveClearStreamAndWait(): boolean
	if streamPlayedThisWave then
		return false
	end
	local n = math.floor(waveDollarsEarned)
	local reportN = pending
	pending = 0
	streamPlayedThisWave = true
	waveDollarsEarned = 0
	if n <= 0 then
		flushCount(reportN)
		return false
	end
	streamPitchCursor = STREAM_COIN_PITCH_MIN
	-- Only cancel a previous stream when starting a new one (not on wave begin).
	streamToken += 1
	local my = streamToken
	local start: Vector2? = nil
	if dollarOriginFn then
		local okOrigin, pos = pcall(dollarOriginFn)
		if okOrigin and typeof(pos) == "Vector2" then
			start = pos
		end
	end
	if not start then
		start = waveBarScreenCenter()
	end
	if not start then
		-- Fallback: still punch counter so the beat isn't silent.
		punchCount()
		flushCount(reportN)
		return false
	end
	-- Clustered visual batches; coin plink fires when each $D lands on the counter.
	local duration = math.clamp(n * STREAM_PER_D_SEC, STREAM_MIN_SEC, STREAM_MAX_SEC)
	local batches = math.max(1, math.ceil(n / STREAM_BATCH))
	local batchGap = if batches > 1 then duration / (batches - 1) else 0
	local remaining = n
	local launched = 0
	local slowestFly = STREAM_FLY_SEC * STREAM_FLY_RATE_MAX
	for b = 1, batches do
		local batchStart = (b - 1) * batchGap
		local inBatch = math.min(STREAM_BATCH, n - launched)
		for j = 1, inBatch do
			launched += 1
			local i = launched
			local slot = j - 1
			-- Stagger enough that clipped plinks read as separate pitches.
			local intra = slot * 0.075
			-- Slight per-$D speed variance so they don't lock-step.
			local rate = STREAM_FLY_RATE_MIN
				+ (STREAM_FLY_RATE_MAX - STREAM_FLY_RATE_MIN)
					* (0.5 + 0.5 * math.sin(i * 2.17 + slot * 0.91))
			local flySec = STREAM_FLY_SEC * rate
			task.delay(batchStart + intra, function()
				if my ~= streamToken then
					remaining = 0
					return
				end
				local from = start
				if dollarOriginFn then
					local okLive, live = pcall(dollarOriginFn)
					if okLive and typeof(live) == "Vector2" then
						from = live
					end
				end
				local bias = ((slot / math.max(1, inBatch - 1)) * 2 - 1) * STREAM_ARC_SPREAD
				flyDollarFromScreen(from, flySec, function()
					remaining -= 1
				end, bias, true)
			end)
		end
	end
	local deadline = os.clock() + duration + slowestFly + 1.25
	while remaining > 0 and my == streamToken and os.clock() < deadline do
		task.wait()
	end
	flushCount(reportN)
	return true
end

function WaveFeedPayout.playWaveClearStream()
	if streamPlayedThisWave then
		return
	end
	-- Snapshot on this thread so the next beginWave cannot drop the payout.
	local n = math.floor(waveDollarsEarned)
	local reportN = pending
	pending = 0
	streamPlayedThisWave = true
	waveDollarsEarned = 0
	if n <= 0 then
		flushCount(reportN)
		return
	end
	local start: Vector2? = nil
	if dollarOriginFn then
		local okOrigin, pos = pcall(dollarOriginFn)
		if okOrigin and typeof(pos) == "Vector2" then
			start = pos
		end
	end
	if not start then
		start = waveBarScreenCenter()
	end
	streamPitchCursor = STREAM_COIN_PITCH_MIN
	streamToken += 1
	local my = streamToken
	task.spawn(function()
		if not start then
			flushCount(reportN)
			return
		end
		local duration = math.clamp(n * STREAM_PER_D_SEC, STREAM_MIN_SEC, STREAM_MAX_SEC)
		local batches = math.max(1, math.ceil(n / STREAM_BATCH))
		local batchGap = if batches > 1 then duration / (batches - 1) else 0
		local launched = 0
		for b = 1, batches do
			local batchStart = (b - 1) * batchGap
			local inBatch = math.min(STREAM_BATCH, n - launched)
			for j = 1, inBatch do
				launched += 1
				local i = launched
				local slot = j - 1
				local intra = slot * 0.075
				local rate = STREAM_FLY_RATE_MIN
					+ (STREAM_FLY_RATE_MAX - STREAM_FLY_RATE_MIN)
						* (0.5 + 0.5 * math.sin(i * 2.17 + slot * 0.91))
				local flySec = STREAM_FLY_SEC * rate
				task.delay(batchStart + intra, function()
					if my ~= streamToken or not start then
						return
					end
					local from = start
					if dollarOriginFn then
						local okLive, live = pcall(dollarOriginFn)
						if okLive and typeof(live) == "Vector2" then
							from = live
						end
					end
					local bias = ((slot / math.max(1, inBatch - 1)) * 2 - 1) * STREAM_ARC_SPREAD
					flyDollarFromScreen(from, flySec, nil, bias, true)
				end)
			end
		end
		local slowestFly = STREAM_FLY_SEC * STREAM_FLY_RATE_MAX
		task.wait(duration + slowestFly + 0.15)
		flushCount(reportN)
	end)
end

function WaveFeedPayout.noteFilled(worldPos: Vector3?)
	-- Join Wave-100 showcase must not grant $D or fire ReportFishFed.
	local ok, WaveSim = pcall(function()
		return require(script.Parent:WaitForChild("WaveSim"))
	end)
	if ok and WaveSim and typeof(WaveSim.isJoinIntroDemo) == "function" and WaveSim.isJoinIntroDemo() then
		return
	end
	pending += 1
	local gain = dollarsPerFish()
	waveDollarsEarned += gain
	if gainListener then
		gainListener(gain)
	end
	-- Hold the server grant until the wave-end fly reaches the total.
	if SHOW_FISH_FLY and typeof(worldPos) == "Vector3" then
		flyDollar(worldPos)
	end
end

-- —— Join-intro rating demo: 10× "$D" → bottom-left counter to $1,000 (visual only) ——

local INTRO_FLY_COUNT = 10
local INTRO_TARGET_DOLLARS = 1000
local INTRO_FLY_SEC = 0.55 -- match gameplay fly so the path reads clearly
local INTRO_SPAWN_GAP = 0.045
local INTRO_SLIDE_SEC = 0.55
local INTRO_TEXT = Color3.fromRGB(90, 255, 120) -- bright green
local INTRO_STROKE = Color3.fromRGB(0, 170, 0) -- green stroke (#00aa00, same as gameplay $D fly)
local INTRO_HUD_PAD = 28
-- Sit clearly above Skip Intro / Skip Training (those use bottom-left ~28px pad + ~28px tall).
local INTRO_HUD_BOTTOM_PAD = 120
local INTRO_HUD_DISPLAY_ORDER = 8700 -- above Skip Training (8600) / Skip Intro
local INTRO_ROW_PADDING = 10

local introHudGui: ScreenGui? = nil
local introHudHost: Frame? = nil
local introCountGui: GuiObject? = nil -- punch / fly dest (cloned $DCount)
local introCountText: (TextLabel | TextButton)? = nil
local introAmount = 0
local introHiddenReal: { { gui: GuiObject, wasVisible: boolean } } = {}

local function bez2(a: Vector2, c: Vector2, b: Vector2, t: number): Vector2
	local omt = 1 - t
	return Vector2.new(
		omt * omt * a.X + 2 * omt * t * c.X + t * t * b.X,
		omt * omt * a.Y + 2 * omt * t * c.Y + t * t * b.Y
	)
end

local function formatIntroCount(n: number): string
	local v = math.max(0, math.floor(n + 0.5))
	local s = tostring(v)
	local out = s
	while true do
		local nextS, nRepl = string.gsub(out, "^(-?%d+)(%d%d%d)", "%1,%2")
		out = nextS
		if nRepl == 0 then
			break
		end
	end
	return out
end

local function setIntroCount(amount: number)
	introAmount = math.clamp(amount, 0, INTRO_TARGET_DOLLARS)
	if introCountText then
		introCountText.Text = formatIntroCount(introAmount)
	end
end

local function introHudDest(): Vector2
	-- Only the temp intro counter — never the real in-game $DCount.
	if introCountGui and introCountGui.Parent then
		local pos = introCountGui.AbsolutePosition + introCountGui.AbsoluteSize * 0.5
		if pos.X > 4 and pos.Y > 4 then
			return pos
		end
	end
	if introHudHost and introHudHost.Parent then
		local pos = introHudHost.AbsolutePosition + introHudHost.AbsoluteSize * 0.5
		if pos.X > 4 and pos.Y > 4 then
			return pos
		end
	end
	local cam = Workspace.CurrentCamera
	local vp = if cam then cam.ViewportSize else Vector2.new(1280, 720)
	return Vector2.new(INTRO_HUD_PAD + 70, vp.Y - INTRO_HUD_BOTTOM_PAD - 18)
end

local function looksLikeGlyphText(text: string): boolean
	local t = string.gsub(text, "%s+", "")
	return t == "$D" or t == "D$"
end

-- Prefer the numeric count label; Studio sometimes nests a "$D" glyph inside $DCount.
local function findCountTextTarget(countHost: GuiObject): (TextLabel | TextButton)?
	if countHost:IsA("TextLabel") or countHost:IsA("TextButton") then
		if not looksLikeGlyphText(countHost.Text) then
			return countHost
		end
	end
	local fallback: (TextLabel | TextButton)? = nil
	for _, d in ipairs(countHost:GetDescendants()) do
		if d:IsA("TextLabel") or d:IsA("TextButton") then
			if not looksLikeGlyphText(d.Text) then
				return d
			end
			if not fallback then
				fallback = d
			end
		end
	end
	if countHost:IsA("TextLabel") or countHost:IsA("TextButton") then
		return countHost
	end
	return fallback
end

local function hideRealSandDollarChrome(left: Instance)
	-- Already suppressing from a prior begin — keep original wasVisible, just force-hide.
	if #introHiddenReal > 0 then
		for _, entry in ipairs(introHiddenReal) do
			if entry.gui.Parent then
				entry.gui.Visible = false
			end
		end
		return
	end
	local targets: { GuiObject } = {}
	local dCount = LeftHudLayout.findDCount(left)
	local dLabel = LeftHudLayout.findDLabel(left)
	local row = left:FindFirstChild(LeftHudLayout.ROW_NAME)
	if dCount then
		table.insert(targets, dCount)
	end
	if dLabel then
		table.insert(targets, dLabel)
	end
	if row and row:IsA("GuiObject") then
		table.insert(targets, row)
	end
	for _, gui in ipairs(targets) do
		table.insert(introHiddenReal, { gui = gui, wasVisible = gui.Visible })
		gui.Visible = false
	end
end

local function restoreRealSandDollarChrome()
	for _, entry in ipairs(introHiddenReal) do
		if entry.gui.Parent then
			entry.gui.Visible = entry.wasVisible
		end
	end
	table.clear(introHiddenReal)
end

local function stripCloneInteractives(root: Instance)
	for _, d in ipairs(root:GetDescendants()) do
		if d.Name == "_OceanTD_DollarHit" or d.Name == "_OceanTD_DollarGain" then
			d:Destroy()
		elseif d:IsA("GuiButton") then
			d.Active = false
			pcall(function()
				(d :: any).Interactable = false
			end)
		end
	end
	if root:IsA("GuiButton") then
		root.Active = false
		pcall(function()
			(root :: any).Interactable = false
		end)
	end
end

local function prepCloneWidget(widget: GuiObject, order: number)
	widget.LayoutOrder = order
	widget.AnchorPoint = Vector2.new(0, 0.5)
	widget.Position = UDim2.fromOffset(0, 0)
	widget.Visible = true
	widget.ClipsDescendants = false
	stripCloneInteractives(widget)
end

local function destroyIntroHudOnly()
	introAmount = 0
	introCountGui = nil
	introCountText = nil
	introHudHost = nil
	if introHudGui then
		introHudGui:Destroy()
		introHudGui = nil
	end
end

function WaveFeedPayout.clearIntroDemo()
	destroyIntroHudOnly()
	restoreRealSandDollarChrome()
end

-- Raised temp $D + count (visual clone of real HUD; does not grant sand dollars).
function WaveFeedPayout.beginIntroDemo()
	-- Tear down prior temp HUD without flashing the real chrome back on.
	destroyIntroHudOnly()
	local pg = player:FindFirstChildOfClass("PlayerGui")
	if not pg then
		restoreRealSandDollarChrome()
		return
	end

	local left = pg:FindFirstChild("MobileLeftUI")
	local realLabel: GuiObject? = nil
	local realCount: GuiObject? = nil
	if left then
		realLabel = LeftHudLayout.findDLabel(left)
		realCount = LeftHudLayout.findDCount(left)
		-- Real chrome must stay hidden; only the temp clones are shown.
		hideRealSandDollarChrome(left)
	end

	local sg = Instance.new("ScreenGui")
	sg.Name = "OceanTD_InkIntroSandDollar"
	sg.IgnoreGuiInset = true
	sg.ResetOnSpawn = false
	sg.DisplayOrder = INTRO_HUD_DISPLAY_ORDER
	sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	sg.Parent = pg
	introHudGui = sg

	local host = Instance.new("Frame")
	host.Name = "Host"
	host.BackgroundTransparency = 1
	host.BorderSizePixel = 0
	host.AnchorPoint = Vector2.new(0, 1)
	-- Left side, raised above the skip button so label/count stay readable.
	host.Position = UDim2.new(0, INTRO_HUD_PAD, 1, -INTRO_HUD_BOTTOM_PAD)
	host.AutomaticSize = Enum.AutomaticSize.XY
	host.Size = UDim2.fromOffset(0, 0)
	host.ZIndex = 10
	host.Parent = sg
	introHudHost = host

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Left
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Padding = UDim.new(0, INTRO_ROW_PADDING)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = host

	-- Match 720p left-HUD scale so clones match in-game size.
	local hudScale = Instance.new("UIScale")
	hudScale.Name = LeftHudLayout.VIEWPORT_SCALE_NAME
	hudScale.Scale = UiPopupScale.getHud()
	hudScale.Parent = host

	if realLabel then
		local glyph = realLabel:Clone()
		glyph.Name = "Intro$D"
		prepCloneWidget(glyph, 1)
		glyph.Parent = host
	else
		local glyph = Instance.new("TextLabel")
		glyph.Name = "Intro$D"
		glyph.BackgroundTransparency = 1
		glyph.Size = UDim2.fromOffset(48, 40)
		glyph.Font = UiTheme.Font
		glyph.Text = "$D"
		glyph.TextSize = 28
		glyph.TextColor3 = Color3.new(1, 1, 1)
		glyph.TextXAlignment = Enum.TextXAlignment.Left
		glyph.ZIndex = 11
		prepCloneWidget(glyph, 1)
		glyph.Parent = host
	end

	local countGui: GuiObject
	if realCount then
		countGui = realCount:Clone()
		countGui.Name = "Intro$DCount"
		prepCloneWidget(countGui, 2)
		countGui.Parent = host
	else
		local count = Instance.new("TextLabel")
		count.Name = "Intro$DCount"
		count.BackgroundTransparency = 1
		count.Size = UDim2.fromOffset(120, 40)
		count.Font = UiTheme.Font
		count.Text = "0"
		count.TextSize = 28
		count.TextColor3 = Color3.new(1, 1, 1)
		count.TextXAlignment = Enum.TextXAlignment.Left
		count.ZIndex = 11
		prepCloneWidget(count, 2)
		count.Parent = host
		countGui = count
	end
	introCountGui = countGui
	introCountText = findCountTextTarget(countGui)
	setIntroCount(0)

	-- Keep real chrome suppressed while the demo is up (LeftHudViewport / reveal paths).
	task.spawn(function()
		while introHudGui and introHudGui.Parent do
			if left and left.Parent then
				local dCount = LeftHudLayout.findDCount(left)
				local dLabel = LeftHudLayout.findDLabel(left)
				local row = left:FindFirstChild(LeftHudLayout.ROW_NAME)
				if dCount and dCount.Visible then
					dCount.Visible = false
				end
				if dLabel and dLabel.Visible then
					dLabel.Visible = false
				end
				if row and row:IsA("GuiObject") and row.Visible then
					row.Visible = false
				end
			end
			RunService.Heartbeat:Wait()
		end
	end)
end

local function flyIntroDollar(worldPos: Vector3, onLand: (() -> ())?)
	local sg = introHudGui
	if not sg or not sg.Parent then
		if onLand then
			onLand()
		end
		return
	end
	-- Prefer heart on-screen; if WorldToViewport fails (behind cam), aim from center.
	local start = worldToScreen(worldPos)
	if not start then
		local cam = Workspace.CurrentCamera
		local vp = if cam then cam.ViewportSize else Vector2.new(1280, 720)
		start = Vector2.new(vp.X * 0.5, vp.Y * 0.42)
	end
	-- Let AbsolutePosition settle so dest isn't (0,0).
	RunService.RenderStepped:Wait()
	RunService.RenderStepped:Wait()
	local dest = introHudDest()

	local lbl = Instance.new("TextLabel")
	lbl.Name = "IntroFlyD"
	lbl.BackgroundTransparency = 1
	lbl.AnchorPoint = Vector2.new(0.5, 0.5)
	lbl.Position = UDim2.fromOffset(start.X, start.Y)
	lbl.Size = UDim2.fromOffset(64, 36)
	lbl.Font = UiTheme.Font
	lbl.Text = "$D"
	lbl.TextSize = 32
	lbl.TextColor3 = INTRO_TEXT
	lbl.TextStrokeTransparency = 1
	lbl.ZIndex = 50
	lbl.Parent = sg
	local stroke = Instance.new("UIStroke")
	stroke.Color = INTRO_STROKE
	stroke.Thickness = 1.6
	stroke.LineJoinMode = Enum.LineJoinMode.Round
	stroke.Parent = lbl

	local t0 = os.clock()
	while lbl.Parent do
		local u = math.clamp((os.clock() - t0) / INTRO_FLY_SEC, 0, 1)
		local e = u * u * (3 - 2 * u)
		-- Refresh dest in case the HUD slid / laid out mid-flight.
		dest = introHudDest()
		local delta = dest - start
		local len = math.max(80, delta.Magnitude)
		local arc = Vector2.new(-delta.Y, delta.X)
		if arc.Magnitude > 1e-3 then
			arc = arc.Unit * math.clamp(len * 0.22, 28, 90)
		else
			arc = Vector2.new(0, -40)
		end
		if arc.Y > 0 then
			arc = -arc
		end
		local ctrl = (start + dest) * 0.5 + arc
		local p = bez2(start, ctrl, dest, e)
		lbl.Position = UDim2.fromOffset(p.X, p.Y)
		lbl.TextSize = 32 - 8 * e
		if u >= 1 then
			break
		end
		RunService.RenderStepped:Wait()
	end
	if lbl.Parent then
		local final = introHudDest()
		lbl.Position = UDim2.fromOffset(final.X, final.Y)
		local punchTarget: GuiObject? = introCountGui or introHudHost
		if punchTarget then
			local scale = punchTarget:FindFirstChild(LeftHudLayout.PUNCH_SCALE_NAME)
			if not scale or not scale:IsA("UIScale") then
				scale = Instance.new("UIScale")
				scale.Name = LeftHudLayout.PUNCH_SCALE_NAME
				scale.Scale = 1
				scale.Parent = punchTarget
			end
			scale.Scale = 1.18
			TweenService:Create(scale, TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Scale = 1 }):Play()
		end
		lbl:Destroy()
	end
	if onLand then
		onLand()
	end
end

-- Yields until all 10 flies have landed and the counter shows 1,000.
function WaveFeedPayout.playIntroHappyBurstAndWait(worldPos: Vector3)
	if not introHudGui then
		WaveFeedPayout.beginIntroDemo()
	end
	-- Layout pass so AbsolutePosition is valid before the first fly.
	RunService.RenderStepped:Wait()
	RunService.RenderStepped:Wait()

	local landed = 0
	local done = false
	local countT0 = os.clock()
	local countDur = (INTRO_FLY_COUNT - 1) * INTRO_SPAWN_GAP + INTRO_FLY_SEC
	local countConn: RBXScriptConnection? = RunService.RenderStepped:Connect(function()
		local u = math.clamp((os.clock() - countT0) / math.max(0.05, countDur), 0, 1)
		local e = u * u * (3 - 2 * u)
		setIntroCount(INTRO_TARGET_DOLLARS * e)
	end)

	-- Staggered parallel flies; each runs its own yield-tween (not a shared RenderStepped).
	for i = 1, INTRO_FLY_COUNT do
		local delaySec = (i - 1) * INTRO_SPAWN_GAP
		task.delay(delaySec, function()
			task.spawn(function()
				flyIntroDollar(worldPos, function()
					landed += 1
					setIntroCount((landed / INTRO_FLY_COUNT) * INTRO_TARGET_DOLLARS)
					if landed >= INTRO_FLY_COUNT then
						done = true
					end
				end)
			end)
		end)
	end

	local deadline = os.clock() + countDur + 2.5
	while not done and os.clock() < deadline do
		RunService.RenderStepped:Wait()
	end
	if countConn then
		countConn:Disconnect()
	end
	setIntroCount(INTRO_TARGET_DOLLARS)
end

function WaveFeedPayout.slideOutIntroDemoAndWait()
	local host = introHudHost
	local sg = introHudGui
	if not host or not sg or not sg.Parent then
		WaveFeedPayout.clearIntroDemo()
		return
	end
	local startPos = host.Position
	-- Slide past the bottom edge (host AnchorPoint is bottom-left).
	local endPos = UDim2.new(startPos.X.Scale, startPos.X.Offset, 1, host.AbsoluteSize.Y + 24)
	local t0 = os.clock()
	while host.Parent do
		local u = math.clamp((os.clock() - t0) / INTRO_SLIDE_SEC, 0, 1)
		local e = u * u * (3 - 2 * u)
		host.Position = startPos:Lerp(endPos, e)
		if u >= 1 then
			break
		end
		RunService.RenderStepped:Wait()
	end
	WaveFeedPayout.clearIntroDemo()
end

return WaveFeedPayout
