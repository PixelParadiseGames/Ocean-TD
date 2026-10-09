--!strict
--[[
	Join Wave-100 showcase:
	1) Loading buffer (sky-up cam + pill bar) so IntroElements / décor can stream
	2) Pan down to CamStartFocus; avatar visible at IntroPosition
	3) Live mid–wave-100 sim; CamStart→CamEnd over 9s; hold through bleach
	4) Bleach + plot-size tween, drop-in, teleport to plot spawn, return follow cam
]]

local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Set false to skip the Wave-100 join showcase.
local INTRO_ENABLED = true

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local ATTR_BUSY = "OceanTD_JoinIntroBusy"
local ATTR_CAM_POS = "OceanTD_JoinIntroCamPos"
local ATTR_ROLL_FINGER = "OceanTD_RollFingerHint"
local ATTR_FORCE_CAM = "OceanTD_ForceCamMode"
local FREEZE_ACTION = "OceanTD_JoinIntroFreeze"
local SKIP_ACTION = "OceanTD_JoinIntroSkip"

local WHITE = Color3.new(1, 1, 1)
local SKIP_GREEN = Color3.fromRGB(55, 200, 90)
local SKIP_STROKE_BRIGHT = Color3.fromRGB(90, 255, 110)
local SKIP_BTN_SIZE = Vector2.new(70, 26) -- half of prior 140×52
local LOAD_BAR_BG = Color3.fromRGB(28, 36, 48)
local LOAD_BAR_FILL = Color3.fromRGB(70, 200, 255)
local LOAD_WAVE_EMOJI = "🌊"
local LOAD_WAVE_EMOJI_PX = 110
local LOAD_WAVE_EMOJI_GAP = 18 -- space between emoji bottom and bar top
local LOAD_TIP_GAP = 22 -- space between bar bottom and tip top
local LOAD_TIP_DOT_SEC = 0.45
local ATTR_LOAD_TIP_ORDER = "OceanTD_LoadTipOrder"
local ATTR_LOAD_TIP_CURSOR = "OceanTD_LoadTipCursor"
-- Phrases without trailing dots; addLoadTip animates "." / ".." / "..."
local LOAD_TIPS = {
	"Filling the ocean with water",
	"Preparing the underwater buffet",
	"Deflating the pufferfish",
	"Teaching the crabs how to walk forwards",
	"Stocking the kelp bar",
	"Scrubbing the algae off the live rock",
	"Convincing the dolphins to stay on Earth",
	"Humbling the starfish",
	"Chopping the chum",
	"Stacking live rock",
	"Waiting for the fishes school to get out",
	"Re-hydrating the water",
	"Splitting the anemones",
	"Blowing bubbles",
	"Counting octopus hearts",
	"Inflating the swim bladders",
	"Spawning a billion tiny krill you cant see",
	"Polishing the pearls",
	"Measuring the salinity",
	"Herding the seahorses",
	"Popping bubble algae",
	"Convincing the parrotfish not to eat the scenery",
	"Vacuuming cyanobacteria from the ocean floor",
	"Telling the mantis shrimp to stop punching things",
	"Figuring out how old an immortal jellyfish is",
	"Sharpening the sea urchins",
	"Painting on the clownfish stripes",
	"Charging the electric eels",
	"Fluffing the sea sponges",
	"Sorting the seashells by shape and size",
	"Stockpiling calcium for the coral",
	"Adjusting the buoyancy of the user interface",
	"Checking the underwater zoning laws",
	"Convincing the clams to open up",
	"Balancing the nitrogen cycle",
	"Turning on the bioluminescence",
	"Scraping coralline off the glass",
	"Checking the pH levels",
	"Upgrading hermit crabs shells",
	"Topping off the evaporated water",
	"Getting the gobies out of their caves",
	"Emptying the protein skimmer",
	"Acclimating the new arrivals",
	"Giving the cuttlefish a new color palette",
	"Getting the remoras to detach",
	"Teaching the archerfish how to aim",
	"Synchronizing the coral spawning to the moon",
	"Siphoning the sand bed",
	"Dialing in the light spectrum",
	"Removing the aiptasia",
	"Waiting for the snails to arrive",
}
local CAM_DOWN_SEC = 9
local LOAD_BAR_FILL_SEC = 4 -- player-facing fill: always a full 4s from empty, never less
local INTRO_EXPLAINER_SOUND_ID = "rbxassetid://75344299140384"
local CAM_HANDOFF_SEC = 1.05
local CAM_HANDOFF_SKIP_SEC = 0.45
local PAN_DOWN_SEC = 1.15
-- Bleach: hard cap total wait; tight stagger + high starts/frame = fewer stragglers.
local BLEACH_TOTAL_MAX_SEC = 2.5
local COLOR_WINDOW_SEC = 0.85
local FALL_Y = -100
local CLONE_BATCH = 24
local INTRO_WAVE = 100
local BLEACH_STARTS_PER_FRAME = 64
local BLEACH_FALL_SEC = 1.0 * 0.7
local BLEACH_HOLD_WHITE_SEC = 0.2 * 0.7
local BLEACH_FADE_SEC = 0.55 -- half the reef fades instead of bleach+fall (cheaper)
local BLEACH_WAIT_PAD_SEC = 0.12
local BLEACH_WAIT_MIN_SEC = 1.5

-- While true, avatar stays visible at IntroPosition (not hidden by early hold).
local introAvatarShown = false
local introStandCf: CFrame? = nil

-- Load bar is shown ASAP (before OceanTD modules / SessionReady) so device joins
-- aren't a blank sky wait while ReplicatedStorage streams in.
local earlyLoadGui: ScreenGui? = nil
local earlyLoadFill: Frame? = nil
local loadBarStartedAt = 0
local loadBarFillDone = false
local loadBarAnimating = false
local loadBarAnimGen = 0 -- bump to cancel any in-flight fill (bootstrap vs final)
local loadTipToken = 0
local TutorialVo = require(script.Parent:WaitForChild("TutorialVo"))

local function stopIntroExplainerSound()
	TutorialVo.stop()
end

local function playIntroExplainerSound()
	TutorialVo.play(INTRO_EXPLAINER_SOUND_ID, "OceanTD_JoinIntroExplainer")
end

local function setLoadFillProgress(fill: Frame, u: number)
	-- Linear only — never ease/snap; scale-based so first layout frames stay continuous.
	u = math.clamp(u, 0, 1)
	if u <= 0 then
		fill.Size = UDim2.new(0, 0, 1, -8)
	else
		fill.Size = UDim2.new(u, -8, 1, -8)
	end
end

-- Wait until the track has a real width so progress doesn't jump when layout resolves.
local function waitLoadTrackLaidOut(fill: Frame, sg: ScreenGui): boolean
	local track = fill.Parent
	if not (track and track:IsA("GuiObject")) then
		return false
	end
	local deadline = os.clock() + 2
	while sg.Parent and fill.Parent and track.AbsoluteSize.X < 1 and os.clock() < deadline do
		RunService.RenderStepped:Wait()
	end
	return sg.Parent ~= nil and fill.Parent ~= nil
end

local function addLoadWaveEmoji(sg: ScreenGui, track: Frame)
	local wave = Instance.new("TextLabel")
	wave.Name = "WaveEmoji"
	wave.BackgroundTransparency = 1
	wave.AnchorPoint = Vector2.new(0.5, 1)
	wave.Position = UDim2.new(
		track.Position.X.Scale,
		track.Position.X.Offset,
		track.Position.Y.Scale,
		track.Position.Y.Offset - math.floor(track.Size.Y.Offset * 0.5 + 0.5) - LOAD_WAVE_EMOJI_GAP
	)
	wave.Size = UDim2.fromOffset(LOAD_WAVE_EMOJI_PX, LOAD_WAVE_EMOJI_PX)
	wave.Font = Enum.Font.GothamBold
	wave.Text = LOAD_WAVE_EMOJI
	wave.TextScaled = true
	wave.TextColor3 = WHITE
	wave.ZIndex = track.ZIndex + 1
	wave.Parent = sg
end

-- Shuffled deck via player attrs: every tip once, then reshuffle (no random repeats mid-cycle).
local function nextLoadTip(): string
	local n = #LOAD_TIPS
	if n < 1 then
		return "Loading"
	end
	local orderStr = playerGui:GetAttribute(ATTR_LOAD_TIP_ORDER)
	local cursor = tonumber(playerGui:GetAttribute(ATTR_LOAD_TIP_CURSOR)) or 0
	local order: { number } = {}
	if typeof(orderStr) == "string" and orderStr ~= "" then
		for part in string.gmatch(orderStr, "%d+") do
			local v = tonumber(part)
			if v then
				table.insert(order, v)
			end
		end
	end
	if #order ~= n then
		order = table.create(n)
		for i = 1, n do
			order[i] = i
		end
		for i = n, 2, -1 do
			local j = math.random(1, i)
			order[i], order[j] = order[j], order[i]
		end
		cursor = 0
		playerGui:SetAttribute(ATTR_LOAD_TIP_ORDER, table.concat(order, ","))
	end
	cursor = math.clamp(cursor, 0, n - 1)
	local tipIdx = order[cursor + 1]
	local nextCursor = cursor + 1
	if nextCursor >= n then
		playerGui:SetAttribute(ATTR_LOAD_TIP_ORDER, "")
		playerGui:SetAttribute(ATTR_LOAD_TIP_CURSOR, 0)
	else
		playerGui:SetAttribute(ATTR_LOAD_TIP_CURSOR, nextCursor)
	end
	return LOAD_TIPS[tipIdx] or LOAD_TIPS[1]
end

local function addLoadTip(sg: ScreenGui, track: Frame)
	-- Two phrases: first half of the 4s fill beat, second half (+ any post-fill wait).
	-- Clock starts when runLoadingBar sets loadBarStartedAt — not when the empty pill appears.
	local phraseA = nextLoadTip()
	local phraseB = nextLoadTip()
	local tip = Instance.new("TextLabel")
	tip.Name = "LoadTip"
	tip.BackgroundTransparency = 1
	tip.AnchorPoint = Vector2.new(0.5, 0)
	tip.Position = UDim2.new(
		track.Position.X.Scale,
		track.Position.X.Offset,
		track.Position.Y.Scale,
		track.Position.Y.Offset + math.floor(track.Size.Y.Offset * 0.5 + 0.5) + LOAD_TIP_GAP
	)
	tip.Size = UDim2.new(0.85, 0, 0, 36)
	tip.Font = Enum.Font.GothamMedium
	tip.TextSize = 22
	tip.TextColor3 = Color3.fromRGB(210, 230, 245)
	tip.TextTransparency = 0.05
	tip.TextXAlignment = Enum.TextXAlignment.Center
	tip.TextYAlignment = Enum.TextYAlignment.Top
	tip.TextWrapped = true
	tip.Text = phraseA .. "."
	tip.ZIndex = track.ZIndex + 1
	tip.Parent = sg

	loadTipToken += 1
	local my = loadTipToken
	local halfSec = LOAD_BAR_FILL_SEC * 0.5
	task.spawn(function()
		local dots = 1
		local lastBase = phraseA
		while my == loadTipToken and tip.Parent and sg.Parent do
			local base = phraseA
			local started = loadBarStartedAt
			if typeof(started) == "number" and started > 0 then
				base = if (os.clock() - started) < halfSec then phraseA else phraseB
			end
			if base ~= lastBase then
				dots = 1
				lastBase = base
			end
			tip.Text = base .. string.rep(".", dots)
			dots = if dots >= 3 then 1 else dots + 1
			task.wait(LOAD_TIP_DOT_SEC)
		end
	end)
end

local function adornLoadBarChrome(sg: ScreenGui, track: Frame)
	addLoadWaveEmoji(sg, track)
	addLoadTip(sg, track)
end

local function bootstrapImmediateLoadBar()
	if not INTRO_ENABLED then
		return
	end
	playerGui:SetAttribute(ATTR_BUSY, true)
	playerGui:SetAttribute(ATTR_FORCE_CAM, "off")
	local cam = Workspace.CurrentCamera
	if cam then
		cam.CameraType = Enum.CameraType.Scriptable
		local pos = cam.CFrame.Position
		cam.CFrame = CFrame.lookAt(pos, pos + Vector3.new(0, 200, 0))
		playerGui:SetAttribute(ATTR_CAM_POS, pos)
	end

	local sg = Instance.new("ScreenGui")
	sg.Name = "OceanTD_JoinIntroLoad"
	sg.IgnoreGuiInset = true
	sg.ResetOnSpawn = false
	sg.DisplayOrder = 2000
	sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	sg.Parent = playerGui

	local track = Instance.new("Frame")
	track.Name = "LoadTrack"
	track.AnchorPoint = Vector2.new(0.5, 0.5)
	track.Position = UDim2.fromScale(0.5, 0.5)
	track.Size = UDim2.new(0.55, 0, 0, 36)
	track.BackgroundColor3 = LOAD_BAR_BG
	track.BorderSizePixel = 0
	track.Parent = sg
	local trackCorner = Instance.new("UICorner")
	trackCorner.CornerRadius = UDim.new(1, 0)
	trackCorner.Parent = track
	local trackAspect = Instance.new("UISizeConstraint")
	trackAspect.MinSize = Vector2.new(220, 28)
	trackAspect.MaxSize = Vector2.new(720, 44)
	trackAspect.Parent = track
	adornLoadBarChrome(sg, track)

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.AnchorPoint = Vector2.new(0, 0.5)
	fill.Position = UDim2.new(0, 4, 0.5, 0)
	fill.Size = UDim2.new(0, 0, 1, -8)
	fill.BackgroundColor3 = LOAD_BAR_FILL
	fill.BorderSizePixel = 0
	fill.Parent = track
	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(1, 0)
	fillCorner.Parent = fill

	-- Show empty pill + tips immediately. Do NOT burn the 4s fill here — module
	-- WaitForChild can take longer than LOAD_BAR_FILL_SEC, which made the bar
	-- already-full by the time intro waited, then flash-dismiss.
	earlyLoadGui = sg
	earlyLoadFill = fill
	loadBarStartedAt = 0
	loadBarFillDone = false
	loadBarAnimating = false
	setLoadFillProgress(fill, 0)
end

bootstrapImmediateLoadBar()

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local Remotes = require(oceanRoot:WaitForChild("Remotes"))
local SkillStages = require(oceanRoot:WaitForChild("Shared"):WaitForChild("SkillStages"))
local UiTheme = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiTheme"))

local ClientPlot = require(script.Parent:WaitForChild("ClientPlot"))
local PlotLoadDropIn = require(script.Parent:WaitForChild("PlotLoadDropIn"))
local PlotSizeCinematic = require(script.Parent:WaitForChild("PlotSizeCinematic"))
local SkillPowerUpUI = require(script.Parent:WaitForChild("SkillPowerUpUI"))
local WaveSign = require(script.Parent:WaitForChild("WaveSign"))
local WaveSim = require(script.Parent:WaitForChild("WaveSim"))

local syncPayload: { hasSeenJoinIntro: boolean, introSourceCFrame: CFrame }? = nil
local syncEvent = Instance.new("BindableEvent")
local running = false
local skipRequested = false
local markSeenRf = Remotes.getFunction("RequestMarkJoinIntroSeen")
local getIntroRf = Remotes.getFunction("RequestGetJoinIntro")

Remotes.get("JoinIntroSync").OnClientEvent:Connect(function(payload: any)
	if typeof(payload) ~= "table" then
		return
	end
	local source = payload.introSourceCFrame
	local prev = syncPayload
	syncPayload = {
		hasSeenJoinIntro = payload.hasSeenJoinIntro == true,
		introSourceCFrame = if typeof(source) == "CFrame"
			then source
			elseif prev then prev.introSourceCFrame
			else CFrame.identity,
	}
	syncEvent:Fire()
end)

local function waitForSync(timeoutSec: number): typeof(syncPayload)
	local deadline = os.clock() + timeoutSec
	while not syncPayload and os.clock() < deadline do
		task.wait(0.05)
	end
	if syncPayload then
		return syncPayload
	end
	local ok, result = pcall(function()
		return getIntroRf:InvokeServer()
	end)
	if ok and typeof(result) == "table" then
		local source = result.introSourceCFrame
		syncPayload = {
			hasSeenJoinIntro = result.hasSeenJoinIntro == true,
			introSourceCFrame = if typeof(source) == "CFrame" then source else CFrame.identity,
		}
	end
	return syncPayload
end

local function hideIntroTemplatePart(part: BasePart)
	part.LocalTransparencyModifier = 1
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
end

local function hideIntroTemplate()
	local plots = Workspace:FindFirstChild("Plots")
	local intro = plots and plots:FindFirstChild("Intro")
	if not intro then
		return
	end
	for _, d in ipairs(intro:GetDescendants()) do
		if d:IsA("BasePart") then
			hideIntroTemplatePart(d)
		end
	end
end

local function watchHideIntroTemplate()
	task.spawn(function()
		local plots = Workspace:WaitForChild("Plots", 60)
		if not plots then
			return
		end
		local intro = plots:WaitForChild("Intro", 60)
		if not intro then
			return
		end
		hideIntroTemplate()
		intro.DescendantAdded:Connect(function(d)
			if d:IsA("BasePart") then
				hideIntroTemplatePart(d)
			end
		end)
	end)
end

-- Placed dual-mesh corals rename the stem (Zoas / TreeCoral / LeatherCoral / SeaFan);
-- Studio templates keep Main/Stem + Accent/Web as siblings.
local INTRO_PRIMARY_EXACT: { [string]: boolean } = {
	main = true,
	stem = true,
	seafanstem = true,
	zoas = true,
	treecoral = true,
	leathercoral = true,
	seafan = true,
}

local function isIntroAccentOrWebName(name: string): boolean
	local lower = string.lower(name)
	if lower == "accent" or lower == "web" or lower == "seafanweb" or lower == "fanweb" then
		return true
	end
	if string.find(lower, "accent", 1, true) ~= nil then
		return true
	end
	if string.find(lower, "web", 1, true) ~= nil and string.find(lower, "webbed", 1, true) == nil then
		return true
	end
	return false
end

local function isIntroPrimaryName(name: string): boolean
	local lower = string.lower(name)
	if INTRO_PRIMARY_EXACT[lower] then
		return true
	end
	if string.sub(lower, 1, 4) == "main" then
		return true
	end
	if string.sub(lower, 1, 4) == "stem" and string.find(lower, "system", 1, true) == nil then
		return true
	end
	return false
end

local function isIntroAttachedPartName(name: string): boolean
	if isIntroAccentOrWebName(name) then
		return true
	end
	local lower = string.lower(name)
	if string.sub(lower, 1, 4) == "food" then
		return true
	end
	if string.find(lower, "collider", 1, true) ~= nil then
		return true
	end
	return false
end

local function isIntroPrimaryPart(part: BasePart): boolean
	if isIntroPrimaryName(part.Name) then
		return true
	end
	local speciesId = part:GetAttribute("OceanTD_SpeciesId")
	if typeof(speciesId) == "string" and speciesId ~= "" then
		if speciesId == "Zoas" or speciesId == "TreeCoral" or speciesId == "LeatherCoral" or speciesId == "SeaFan" then
			return true
		end
	end
	return false
end

local function nestIntroAttachedUnderPrimaries(root: Instance)
	local function processParent(parent: Instance)
		local primaries: { BasePart } = {}
		local attached: { BasePart } = {}
		for _, ch in ipairs(parent:GetChildren()) do
			if ch:IsA("BasePart") then
				if isIntroPrimaryPart(ch) then
					table.insert(primaries, ch)
				elseif isIntroAttachedPartName(ch.Name) then
					table.insert(attached, ch)
				end
			end
		end
		if #attached < 1 or #primaries < 1 then
			return
		end
		for _, a in ipairs(attached) do
			local best: BasePart? = nil
			local bestDist = math.huge
			if #primaries == 1 then
				best = primaries[1]
			else
				for _, p in ipairs(primaries) do
					local d = (p.Position - a.Position).Magnitude
					if d < bestDist then
						best = p
						bestDist = d
					end
				end
			end
			if best and a.Parent ~= best then
				local rel = best.CFrame:ToObjectSpace(a.CFrame)
				a.Anchored = true
				a.CanCollide = false
				a.Parent = best
				a.CFrame = best.CFrame * rel
			end
		end
	end
	if root:IsA("BasePart") then
		return
	end
	processParent(root)
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("Model") or d:IsA("Folder") then
			processParent(d)
		end
	end
end

-- Intro corals stream in over time on device — snapshot only after part count goes quiet.
local function countIntroParts(intro: Instance): number
	local n = 0
	for _, d in ipairs(intro:GetDescendants()) do
		if d:IsA("BasePart") then
			n += 1
		end
	end
	return n
end

local function waitIntroStreamStable(intro: Instance, quietSec: number, timeoutSec: number): number
	local deadline = os.clock() + timeoutSec
	local lastCount = -1
	local quietSince = os.clock()
	while os.clock() < deadline do
		local n = countIntroParts(intro)
		if n ~= lastCount then
			lastCount = n
			quietSince = os.clock()
		elseif n > 0 and (os.clock() - quietSince) >= quietSec then
			return n
		end
		task.wait(0.08)
	end
	return math.max(0, lastCount)
end

local function waitHungryFishReady(timeoutSec: number): boolean
	local deadline = os.clock() + timeoutSec
	while os.clock() < deadline do
		local folder = ReplicatedStorage:FindFirstChild("HungryFish")
		if folder then
			for _, d in ipairs(folder:GetDescendants()) do
				if d:IsA("BasePart") or d:IsA("MeshPart") then
					return true
				end
			end
		end
		task.wait(0.1)
	end
	return false
end

local function waitJoinIntroPackage(timeoutSec: number): Instance?
	local deadline = os.clock() + timeoutSec
	while os.clock() < deadline do
		if oceanRoot:GetAttribute("JoinIntroPackageReady") == true then
			local package = oceanRoot:FindFirstChild("JoinIntroPackage")
			local introSrc = package and (package:FindFirstChild("Intro") or package)
			if introSrc then
				return introSrc
			end
		end
		task.wait(0.05)
	end
	-- Fallback: live Workspace.Plots.Intro (may still be streaming).
	local plots = Workspace:FindFirstChild("Plots")
	return plots and plots:FindFirstChild("Intro")
end

local function sanitizeVisual(inst: Instance)
	for _, d in ipairs(inst:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
			d.CastShadow = false
		end
		if d:IsA("Script") or d:IsA("LocalScript") or d:IsA("ModuleScript") then
			d:Destroy()
		end
	end
	if inst:IsA("BasePart") then
		inst.Anchored = true
		inst.CanCollide = false
		inst.CanQuery = false
		inst.CanTouch = false
		inst.CastShadow = false
	end
end

local function gatherParts(root: Instance): { BasePart }
	local parts: { BasePart } = {}
	if root:IsA("BasePart") then
		table.insert(parts, root)
	end
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("BasePart") then
			table.insert(parts, d)
		end
	end
	return parts
end

local function setOwnedPlotHidden(hidden: boolean)
	for _, part in ipairs(PlotLoadDropIn.gatherOwnedPlotParts()) do
		PlotLoadDropIn.setPartHiddenLocal(part, hidden)
	end
end

local function smoothstep(u: number): number
	u = math.clamp(u, 0, 1)
	return u * u * (3 - 2 * u)
end

local hiddenHud: { { gui: GuiObject, wasVisible: boolean } } = {}
local hiddenHudSet: { [GuiObject]: boolean } = {}
local hiddenScreens: { [ScreenGui]: boolean } = {}
local hudSuppressConn: RBXScriptConnection? = nil
local hudChildConn: RBXScriptConnection? = nil
local leftHudOrderSaved: number? = nil
-- Above OceanTD_JoinIntroLoad (2000) so ♪ stays clickable over the loading chrome.
local INTRO_SETTINGS_DISPLAY_ORDER = 2500

local HUD_SKIP_NAMES = {
	OceanTD_JoinIntro = true,
	OceanTD_JoinIntroLoad = true,
	OceanTD_HideUiFly = true,
	TouchGui = true,
	-- Sound settings button (♪) + volume modal stay available during loading / intro.
	MobileLeftUI = true,
	OceanTD_Settings = true,
}

local function shouldKeepScreenGui(sg: ScreenGui): boolean
	return HUD_SKIP_NAMES[sg.Name] == true
end

local function suppressScreenGui(sg: ScreenGui)
	if shouldKeepScreenGui(sg) then
		return
	end
	if hiddenScreens[sg] == nil then
		hiddenScreens[sg] = sg.Enabled
	end
	if sg.Enabled then
		sg.Enabled = false
	end
end

local function rememberHideGui(gui: GuiObject)
	if hiddenHudSet[gui] then
		gui.Visible = false
		return
	end
	hiddenHudSet[gui] = true
	table.insert(hiddenHud, { gui = gui, wasVisible = gui.Visible })
	gui.Visible = false
end

-- Keep only MobileLeftUI.dPad.Settings visible; hide the rest of the left HUD.
local function pinSettingsButtonVisible()
	local left = playerGui:FindFirstChild("MobileLeftUI")
	if not (left and left:IsA("ScreenGui")) then
		return
	end
	left.Enabled = true
	if leftHudOrderSaved == nil then
		leftHudOrderSaved = left.DisplayOrder
	end
	left.DisplayOrder = math.max(left.DisplayOrder, INTRO_SETTINGS_DISPLAY_ORDER)
	left.IgnoreGuiInset = true
	pcall(function()
		(left :: any).ClipToDeviceSafeArea = false
	end)

	local dPad = left:FindFirstChild("dPad")
	if dPad and dPad:IsA("GuiObject") then
		dPad.Visible = true
		for _, ch in ipairs(dPad:GetChildren()) do
			if ch:IsA("GuiObject") then
				if ch.Name == "Settings" then
					ch.Visible = true
					ch.Active = true
				else
					-- Include dPadIcon — only ♪ Settings stays during load/intro.
					rememberHideGui(ch)
				end
			end
		end
	end
	for _, ch in ipairs(left:GetChildren()) do
		if ch:IsA("GuiObject") and ch.Name ~= "dPad" then
			rememberHideGui(ch)
		end
	end
end

local function hideHud()
	for _, ch in ipairs(playerGui:GetChildren()) do
		if ch:IsA("ScreenGui") then
			suppressScreenGui(ch)
		end
	end
	pinSettingsButtonVisible()
end

local function startHudSuppress()
	hideHud()
	if not hudChildConn then
		hudChildConn = playerGui.ChildAdded:Connect(function(ch)
			if playerGui:GetAttribute(ATTR_BUSY) ~= true then
				return
			end
			if ch:IsA("ScreenGui") then
				task.defer(function()
					if playerGui:GetAttribute(ATTR_BUSY) == true and ch.Parent then
						suppressScreenGui(ch)
						pinSettingsButtonVisible()
					end
				end)
			end
		end)
	end
	if not hudSuppressConn then
		-- InventoryUI / remotes often re-enable MainHUD after our first pass.
		hudSuppressConn = RunService.Heartbeat:Connect(function()
			if playerGui:GetAttribute(ATTR_BUSY) ~= true then
				return
			end
			for _, ch in ipairs(playerGui:GetChildren()) do
				if ch:IsA("ScreenGui") and not shouldKeepScreenGui(ch) and ch.Enabled then
					suppressScreenGui(ch)
				end
			end
			pinSettingsButtonVisible()
		end)
	end
end

local function stopHudSuppress()
	if hudSuppressConn then
		hudSuppressConn:Disconnect()
		hudSuppressConn = nil
	end
	if hudChildConn then
		hudChildConn:Disconnect()
		hudChildConn = nil
	end
end

local function restoreHud()
	stopHudSuppress()
	for sg, wasEnabled in pairs(hiddenScreens) do
		if sg.Parent then
			sg.Enabled = wasEnabled
		end
	end
	table.clear(hiddenScreens)
	for _, entry in ipairs(hiddenHud) do
		if entry.gui.Parent then
			entry.gui.Visible = entry.wasVisible
		end
	end
	table.clear(hiddenHud)
	table.clear(hiddenHudSet)
	local left = playerGui:FindFirstChild("MobileLeftUI")
	if left and left:IsA("ScreenGui") and leftHudOrderSaved ~= nil then
		left.DisplayOrder = leftHudOrderSaved
	end
	leftHudOrderSaved = nil
end

-- Load bar already up from bootstrapImmediateLoadBar — pin ♪ above it now, not only at beginEarlyIntroHold.
if playerGui:GetAttribute(ATTR_BUSY) == true then
	startHudSuppress()
end

local DEFAULT_WALK_SPEED = 16
local DEFAULT_JUMP_HEIGHT = 10.8
local savedWalkSpeed = DEFAULT_WALK_SPEED
local savedJumpHeight = DEFAULT_JUMP_HEIGHT
local freezeSaved = false

local function bindFreeze(on: boolean)
	ContextActionService:UnbindAction(FREEZE_ACTION)
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if on then
		ContextActionService:BindActionAtPriority(FREEZE_ACTION, function()
			return Enum.ContextActionResult.Sink
		end, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.W, Enum.KeyCode.A, Enum.KeyCode.S, Enum.KeyCode.D, Enum.KeyCode.Space)
		if hum then
			if not freezeSaved then
				if hum.WalkSpeed > 0 then
					savedWalkSpeed = hum.WalkSpeed
				end
				if hum.JumpHeight > 0 then
					savedJumpHeight = hum.JumpHeight
				end
				freezeSaved = true
			end
			hum.WalkSpeed = 0
			hum.JumpPower = 0
			hum.JumpHeight = 0
		end
		return
	end
	if hum then
		hum.WalkSpeed = if savedWalkSpeed > 0 then savedWalkSpeed else DEFAULT_WALK_SPEED
		hum.JumpHeight = if savedJumpHeight > 0 then savedJumpHeight else DEFAULT_JUMP_HEIGHT
	end
	freezeSaved = false
end

local function makeUi(): (ScreenGui, TextButton)
	local sg = Instance.new("ScreenGui")
	sg.Name = "OceanTD_JoinIntro"
	sg.IgnoreGuiInset = true
	sg.ResetOnSpawn = false
	sg.DisplayOrder = 120
	sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	sg.Parent = playerGui

	local btn = Instance.new("TextButton")
	btn.Name = "Skip"
	btn.AnchorPoint = Vector2.new(1, 1)
	btn.Position = UDim2.new(1, -28, 1, -28)
	btn.Size = UDim2.fromOffset(SKIP_BTN_SIZE.X, SKIP_BTN_SIZE.Y)
	btn.BackgroundColor3 = SKIP_GREEN
	btn.Font = UiTheme.Font
	btn.Text = "SKIP"
	btn.TextColor3 = Color3.new(1, 1, 1)
	btn.TextScaled = true
	btn.AutoButtonColor = true
	btn.Selectable = true
	btn.Active = true
	btn.ZIndex = 3
	btn.Parent = sg
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = btn
	local stroke = Instance.new("UIStroke")
	stroke.Name = "_OceanTD_SkipStroke"
	stroke.Color = SKIP_STROKE_BRIGHT
	stroke.Thickness = 2.5
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = btn
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0.08, 0)
	pad.PaddingBottom = UDim.new(0.08, 0)
	pad.PaddingLeft = UDim.new(0.1, 0)
	pad.PaddingRight = UDim.new(0.1, 0)
	pad.Parent = btn

	return sg, btn
end

local skipFlashToken = 0
local function flashSkipButton(btn: TextButton)
	local stroke = btn:FindFirstChild("_OceanTD_SkipStroke")
	skipFlashToken += 1
	local token = skipFlashToken
	local restoreBg = SKIP_GREEN
	btn.BackgroundColor3 = SKIP_STROKE_BRIGHT
	if stroke and stroke:IsA("UIStroke") then
		stroke.Color = Color3.new(1, 1, 1)
	end
	task.delay(0.12, function()
		if token ~= skipFlashToken or not btn.Parent then
			return
		end
		TweenService:Create(btn, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			BackgroundColor3 = restoreBg,
		}):Play()
		if stroke and stroke:IsA("UIStroke") and stroke.Parent then
			TweenService:Create(stroke, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				Color = SKIP_STROKE_BRIGHT,
			}):Play()
		end
	end)
end

local function makeLoadingUi(): (ScreenGui, Frame)
	local sg = Instance.new("ScreenGui")
	sg.Name = "OceanTD_JoinIntroLoad"
	sg.IgnoreGuiInset = true
	sg.ResetOnSpawn = false
	sg.DisplayOrder = 2000
	sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	sg.Parent = playerGui

	local track = Instance.new("Frame")
	track.Name = "LoadTrack"
	track.AnchorPoint = Vector2.new(0.5, 0.5)
	track.Position = UDim2.fromScale(0.5, 0.5)
	track.Size = UDim2.new(0.55, 0, 0, 36)
	track.BackgroundColor3 = LOAD_BAR_BG
	track.BorderSizePixel = 0
	track.Parent = sg
	local trackCorner = Instance.new("UICorner")
	trackCorner.CornerRadius = UDim.new(1, 0)
	trackCorner.Parent = track
	local trackAspect = Instance.new("UISizeConstraint")
	trackAspect.MinSize = Vector2.new(220, 28)
	trackAspect.MaxSize = Vector2.new(720, 44)
	trackAspect.Parent = track
	adornLoadBarChrome(sg, track)

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.AnchorPoint = Vector2.new(0, 0.5)
	fill.Position = UDim2.new(0, 4, 0.5, 0)
	fill.Size = UDim2.new(0, 0, 1, -8)
	fill.BackgroundColor3 = LOAD_BAR_FILL
	fill.BorderSizePixel = 0
	fill.Parent = track
	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(1, 0)
	fillCorner.Parent = fill

	return sg, fill
end

-- Smooth linear fill over exactly durationSec. Never jumps to full; only stops if cancelled/gui gone.
local function runLoadingBar(fill: Frame, sg: ScreenGui, durationSec: number, gen: number): boolean
	if not waitLoadTrackLaidOut(fill, sg) or earlyLoadGui ~= sg or gen ~= loadBarAnimGen then
		return false
	end
	local t0 = os.clock()
	loadBarStartedAt = t0
	while earlyLoadGui == sg and sg.Parent and fill.Parent and gen == loadBarAnimGen and (os.clock() - t0) < durationSec do
		local u = math.clamp((os.clock() - t0) / durationSec, 0, 1)
		setLoadFillProgress(fill, u)
		RunService.RenderStepped:Wait()
	end
	if earlyLoadGui == sg and sg.Parent and fill.Parent and gen == loadBarAnimGen then
		setLoadFillProgress(fill, 1)
		return true
	end
	return false
end

local function destroyEarlyLoadBar()
	loadBarAnimGen += 1
	loadBarFillDone = true
	loadBarAnimating = false
	loadTipToken += 1
	if earlyLoadGui and earlyLoadGui.Parent then
		earlyLoadGui:Destroy()
	end
	earlyLoadGui = nil
	earlyLoadFill = nil
end

local function showEarlyLoadBar()
	-- bootstrapImmediateLoadBar may have already created this before modules loaded.
	if earlyLoadGui and earlyLoadGui.Parent then
		return
	end
	local sg, fill = makeLoadingUi()
	earlyLoadGui = sg
	earlyLoadFill = fill
	loadBarStartedAt = 0
	loadBarFillDone = false
	loadBarAnimating = false
	setLoadFillProgress(fill, 0)
end

-- Guaranteed player-facing beat: always fill 0→1 over LOAD_BAR_FILL_SEC on this thread.
-- Never returns early because a prior bootstrap fill already finished.
local function waitEarlyLoadBarMin()
	showEarlyLoadBar()
	local sg = earlyLoadGui
	local fill = earlyLoadFill
	if not (sg and sg.Parent and fill and fill.Parent) then
		return
	end
	loadBarAnimGen += 1
	local gen = loadBarAnimGen
	loadBarAnimating = true
	loadBarFillDone = false
	setLoadFillProgress(fill, 0)
	local ok = runLoadingBar(fill, sg, LOAD_BAR_FILL_SEC, gen)
	if gen == loadBarAnimGen then
		loadBarFillDone = ok
		loadBarAnimating = false
		if ok then
			playIntroExplainerSound()
		end
	end
end

local function bleachPartLook(part: BasePart)
	-- Instant white (no per-part TweenService Color tweens — those dominated CPU).
	if part:IsA("MeshPart") then
		(part :: MeshPart).TextureID = ""
	end
	for _, ch in ipairs(part:GetChildren()) do
		if ch:IsA("SurfaceAppearance") or ch:IsA("Texture") or ch:IsA("Decal") then
			ch:Destroy()
		end
	end
	part.Material = Enum.Material.SmoothPlastic
	part.Color = WHITE
end

local function bleachAndFall(parts: { BasePart }, token: { cancelled: boolean }): number
	-- One job per Model (or loose part) so accents leave with the coral.
	type Job = { parts: { BasePart }, drive: BasePart | Model, fadeOnly: boolean }
	local jobs: { Job } = {}
	local seenModel: { [Model]: boolean } = {}
	local seenLoose: { [BasePart]: boolean } = {}

	for _, part in ipairs(parts) do
		if not part.Parent then
			continue
		end
		local model = part:FindFirstAncestorOfClass("Model")
		local underShowcase = false
		if model then
			local p: Instance? = model.Parent
			while p and p ~= Workspace do
				if p.Name == "OceanTD_JoinIntroShowcase" then
					underShowcase = true
					break
				end
				p = p.Parent
			end
		end
		if model and underShowcase then
			if seenModel[model] then
				continue
			end
			seenModel[model] = true
			local bundle: { BasePart } = {}
			for _, d in ipairs(model:GetDescendants()) do
				if d:IsA("BasePart") then
					table.insert(bundle, d)
				end
			end
			if #bundle > 0 then
				table.insert(jobs, { parts = bundle, drive = model, fadeOnly = false })
			end
		else
			if seenLoose[part] then
				continue
			end
			-- Skip Accent/Web/Food already parented under a stem — they leave with it.
			if part.Parent and part.Parent:IsA("BasePart") then
				continue
			end
			seenLoose[part] = true
			local bundle: { BasePart } = { part }
			for _, d in ipairs(part:GetDescendants()) do
				if d:IsA("BasePart") then
					seenLoose[d] = true
					table.insert(bundle, d)
				end
			end
			table.insert(jobs, { parts = bundle, drive = part, fadeOnly = false })
		end
	end

	local rng = Random.new()
	local n = #jobs
	-- Half bleach+fall, half fade-out (no white paint / no fall tweens — big CPU save).
	for i = n, 2, -1 do
		local j = rng:NextInteger(1, i)
		jobs[i], jobs[j] = jobs[j], jobs[i]
	end
	local fadeCount = n // 2
	for i = 1, fadeCount do
		jobs[i].fadeOnly = true
	end

	local queueDrainSec = (n / math.max(1, BLEACH_STARTS_PER_FRAME)) * (1 / 60)
	local fixedTail = math.max(BLEACH_HOLD_WHITE_SEC + BLEACH_FALL_SEC, BLEACH_FADE_SEC) + BLEACH_WAIT_PAD_SEC
	local colorWindow = math.min(
		COLOR_WINDOW_SEC,
		math.max(0.2, BLEACH_TOTAL_MAX_SEC - fixedTail - queueDrainSec)
	)
	local maxEnd = math.min(BLEACH_TOTAL_MAX_SEC, colorWindow + queueDrainSec + fixedTail)

	local delays: { number } = table.create(n)
	for i = 1, n do
		delays[i] = rng:NextNumber(0, colorWindow)
	end

	local fadeInfo = TweenInfo.new(BLEACH_FADE_SEC, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

	task.spawn(function()
		local qi = 1
		while qi <= n and not token.cancelled do
			local started = 0
			while started < BLEACH_STARTS_PER_FRAME and qi <= n do
				if token.cancelled then
					return
				end
				local job = jobs[qi]
				local delaySec = delays[qi]
				qi += 1
				started += 1
				task.delay(delaySec, function()
					if token.cancelled then
						return
					end
					if job.fadeOnly then
						local anyAlive = false
						for _, p in ipairs(job.parts) do
							if p.Parent then
								anyAlive = true
								TweenService:Create(p, fadeInfo, { LocalTransparencyModifier = 1 }):Play()
							end
						end
						if not anyAlive then
							return
						end
						task.delay(BLEACH_FADE_SEC, function()
							if token.cancelled then
								return
							end
							local drive = job.drive
							if drive.Parent then
								drive:Destroy()
							end
						end)
						return
					end

					local anyAlive = false
					for _, p in ipairs(job.parts) do
						if p.Parent then
							bleachPartLook(p)
							anyAlive = true
						end
					end
					if not anyAlive then
						return
					end
					task.delay(BLEACH_HOLD_WHITE_SEC, function()
						if token.cancelled then
							return
						end
						local drive = job.drive
						if not drive.Parent then
							return
						end
						if drive:IsA("Model") then
							local startPivot = drive:GetPivot()
							local target = CFrame.new(startPivot.Position.X, FALL_Y, startPivot.Position.Z)
								* (startPivot - startPivot.Position)
							local t0 = os.clock()
							while os.clock() - t0 < BLEACH_FALL_SEC do
								if token.cancelled or not drive.Parent then
									return
								end
								local u = math.clamp((os.clock() - t0) / BLEACH_FALL_SEC, 0, 1)
								local e = u * u
								drive:PivotTo(startPivot:Lerp(target, e))
								RunService.Heartbeat:Wait()
							end
							if drive.Parent then
								drive:Destroy()
							end
						elseif drive:IsA("BasePart") then
							local startCF = drive.CFrame
							local target = CFrame.new(startCF.Position.X, FALL_Y, startCF.Position.Z)
								* (startCF - startCF.Position)
							TweenService:Create(drive, TweenInfo.new(BLEACH_FALL_SEC, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
								CFrame = target,
							}):Play()
							task.delay(BLEACH_FALL_SEC, function()
								if drive.Parent then
									drive:Destroy()
								end
							end)
						end
					end)
				end)
			end
			RunService.Heartbeat:Wait()
		end
	end)

	return maxEnd
end

local function destroyFolder(folder: Folder?)
	if folder and folder.Parent then
		folder:Destroy()
	end
end

local function finishCamToFollow()
	-- Default seat after intro: Plot Cam (not avatar follow / Off).
	playerGui:SetAttribute(ATTR_CAM_POS, nil)
	playerGui:SetAttribute(ATTR_BUSY, false)
	playerGui:SetAttribute(ATTR_FORCE_CAM, "plotcam")
end

local function followHandoffCFrame(hrp: BasePart): CFrame
	local cam = Workspace.CurrentCamera
	local dist = 12.5
	if cam then
		local d = (cam.CFrame.Position - hrp.Position).Magnitude
		if d > 2 then
			dist = math.clamp(d, 8, 20)
		end
	end
	local back = -hrp.CFrame.LookVector * dist
	local camPos = hrp.Position + Vector3.new(0, 2, 0) + back
	local lookAt = hrp.Position + Vector3.new(0, 1.5, 0)
	return CFrame.lookAt(camPos, lookAt)
end

local function tweenCamToFollowHandoff(durationSec: number)
	local cam = Workspace.CurrentCamera
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not (cam and hrp and hrp:IsA("BasePart") and hum) then
		finishCamToFollow()
		return
	end
	cam.CameraType = Enum.CameraType.Scriptable
	local startCf = cam.CFrame
	local t0 = os.clock()
	while os.clock() - t0 < durationSec and player.Parent do
		local u = smoothstep((os.clock() - t0) / durationSec)
		local goal = followHandoffCFrame(hrp)
		cam.CFrame = startCf:Lerp(goal, u)
		playerGui:SetAttribute(ATTR_CAM_POS, cam.CFrame.Position)
		RunService.RenderStepped:Wait()
	end
	finishCamToFollow()
end

local function markSeen()
	pcall(function()
		markSeenRf:InvokeServer()
	end)
end

local function worldCFrameOf(inst: Instance): CFrame?
	if inst:IsA("BasePart") then
		return inst.CFrame
	end
	if inst:IsA("Model") then
		return (inst :: Model):GetPivot()
	end
	local part = inst:FindFirstChildWhichIsA("BasePart", true)
	return if part then part.CFrame else nil
end

local function findIntroElementChild(folder: Instance, name: string): Instance?
	local direct = folder:FindFirstChild(name)
	if direct then
		return direct
	end
	return folder:FindFirstChild(name, true)
end

export type IntroCamPose = {
	camStart: CFrame,
	camEnd: CFrame,
	focusStart: CFrame,
	focusEnd: CFrame,
	introPos: CFrame?,
}

local function waitIntroElements(timeoutSec: number): IntroCamPose?
	local deadline = os.clock() + timeoutSec
	local plots = Workspace:FindFirstChild("Plots")
	if not plots then
		plots = Workspace:WaitForChild("Plots", timeoutSec)
	end
	if not plots then
		return nil
	end
	local remain = math.max(0.05, deadline - os.clock())
	local folder = plots:FindFirstChild("IntroElements")
	if not folder then
		folder = plots:WaitForChild("IntroElements", remain)
	end
	if not folder then
		return nil
	end

	local function waitChild(name: string): Instance?
		local found = findIntroElementChild(folder, name)
		if found then
			return found
		end
		local left = deadline - os.clock()
		if left <= 0 then
			return nil
		end
		return folder:WaitForChild(name, left)
	end

	local camStartInst = waitChild("CamStart")
	local camEndInst = waitChild("CamEnd")
	local focusStartInst = waitChild("CamStartFocus")
	local focusEndInst = waitChild("CamEndFocus")
	local introPosInst = findIntroElementChild(folder, "IntroPosition") or waitChild("IntroPosition")

	local camStart = if camStartInst then worldCFrameOf(camStartInst) else nil
	local camEnd = if camEndInst then worldCFrameOf(camEndInst) else nil
	local focusStart = if focusStartInst then worldCFrameOf(focusStartInst) else nil
	local focusEnd = if focusEndInst then worldCFrameOf(focusEndInst) else nil
	local introPos = if introPosInst then worldCFrameOf(introPosInst) else nil
	if not camStart or not camEnd or not focusStart or not focusEnd then
		return nil
	end
	return {
		camStart = camStart,
		camEnd = camEnd,
		focusStart = focusStart,
		focusEnd = focusEnd,
		introPos = introPos,
	}
end

local function hideCharacterLocal(hidden: boolean)
	local char = player.Character
	if not char then
		return
	end
	for _, d in ipairs(char:GetDescendants()) do
		if d:IsA("BasePart") then
			d.LocalTransparencyModifier = if hidden then 1 else 0
		elseif d:IsA("Decal") then
			d.LocalTransparencyModifier = if hidden then 1 else 0
		end
	end
end

local function standAtCFrame(cf: CFrame, faceWorldPos: Vector3?)
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not (hrp and hrp:IsA("BasePart")) then
		return
	end
	local hip = if hum then math.max(2.5, hum.HipHeight + 1.5) else 3
	local pos = cf.Position + Vector3.new(0, hip, 0)
	local flatLook: Vector3
	if faceWorldPos then
		flatLook = Vector3.new(faceWorldPos.X - pos.X, 0, faceWorldPos.Z - pos.Z)
	else
		flatLook = Vector3.new(cf.LookVector.X, 0, cf.LookVector.Z)
	end
	if flatLook.Magnitude < 1e-3 then
		flatLook = Vector3.new(0, 0, -1)
	else
		flatLook = flatLook.Unit
	end
	hrp.CFrame = CFrame.lookAt(pos, pos + flatLook, Vector3.yAxis)
	hrp.AssemblyLinearVelocity = Vector3.zero
	hrp.AssemblyAngularVelocity = Vector3.zero
end

local function standAtIntroFacingCam()
	if not introStandCf then
		return
	end
	local cam = Workspace.CurrentCamera
	standAtCFrame(introStandCf, if cam then cam.CFrame.Position else nil)
end

local function teleportToPlotSpawn()
	local plot = ClientPlot.get()
	local spawnCf = plot and plot.spawnCFrame
	if spawnCf then
		standAtCFrame(spawnCf)
	end
end

local function applyIntroCam(pos: Vector3, lookAt: Vector3)
	playerGui:SetAttribute(ATTR_CAM_POS, pos)
	local cam = Workspace.CurrentCamera
	if not cam then
		return
	end
	cam.CameraType = Enum.CameraType.Scriptable
	if (lookAt - pos).Magnitude < 0.05 then
		cam.CFrame = CFrame.new(pos)
	else
		cam.CFrame = CFrame.lookAt(pos, lookAt)
	end
end

local earlyCamConn: RBXScriptConnection? = nil
local earlyCamStart: Vector3? = nil

local function stopEarlyCamHold()
	if earlyCamConn then
		earlyCamConn:Disconnect()
		earlyCamConn = nil
	end
end

local function peekIntroElementPos(name: string): Vector3?
	local plots = Workspace:FindFirstChild("Plots")
	local folder = plots and plots:FindFirstChild("IntroElements")
	local inst = folder and (folder:FindFirstChild(name) or folder:FindFirstChild(name, true))
	if not inst then
		return nil
	end
	local cf = worldCFrameOf(inst)
	return if cf then ClientPlot.remapCFrameFromPlot1(cf).Position else nil
end

-- Claim Scriptable cam + hide reef/avatar before SessionReady so join spawn isn't seen.
-- Loading buffer looks straight up at the sky from CamStart (when available).
local function beginEarlyIntroHold()
	playerGui:SetAttribute(ATTR_BUSY, true)
	playerGui:SetAttribute(ATTR_FORCE_CAM, "off")
	playerGui:SetAttribute("OceanTD_ForceCloseFreeCam", os.clock())
	startHudSuppress()
	-- Show the pill bar immediately — SessionReady / DataStore can take seconds on device.
	showEarlyLoadBar()
	bindFreeze(true)
	hideCharacterLocal(true)
	setOwnedPlotHidden(true)
	stopEarlyCamHold()
	earlyCamConn = RunService.RenderStepped:Connect(function()
		setOwnedPlotHidden(true)
		if introStandCf then
			standAtIntroFacingCam()
		end
		if not introAvatarShown then
			hideCharacterLocal(true)
		else
			hideCharacterLocal(false)
		end
		if not earlyCamStart then
			earlyCamStart = peekIntroElementPos("CamStart")
		end
		local pos = earlyCamStart
		if not pos then
			local cam = Workspace.CurrentCamera
			pos = if cam then cam.CFrame.Position else Vector3.new(0, 40, 0)
		end
		-- Straight up at the sky until the loading buffer finishes.
		applyIntroCam(pos, pos + Vector3.new(0, 200, 0))
	end)
	task.spawn(function()
		local root = Workspace:WaitForChild("OceanTD_Placed", 45)
		if not root then
			return
		end
		local function hideIfBusy(inst: Instance)
			if playerGui:GetAttribute(ATTR_BUSY) ~= true then
				return
			end
			if inst:IsA("BasePart") then
				inst.LocalTransparencyModifier = 1
			end
		end
		for _, d in ipairs(root:GetDescendants()) do
			hideIfBusy(d)
		end
		root.DescendantAdded:Connect(hideIfBusy)
	end)
end

local function notifyIntroComplete()
	pcall(function()
		Remotes.get("JoinIntroComplete"):FireServer()
	end)
end

local function restorePlotMirror(saved: ClientPlot.MirroredPlot)
	ClientPlot.set({
		plotId = saved.plotId,
		cframe = saved.cframe,
		size = saved.size,
		spawnCFrame = saved.spawnCFrame,
		plot1CFrame = saved.plot1CFrame,
		ringCFrame = saved.ringCFrame,
	})
	local realStage = SkillPowerUpUI.getStage("PlotSize")
	local WaveEndVfx = require(script.Parent:WaitForChild("WaveEndVfx"))
	WaveEndVfx.syncToPlotSizeStage(realStage)
end

local function runIntro()
	if running then
		return
	end
	running = true
	skipRequested = false
	local finishedNotified = false
	local savedPlot: ClientPlot.MirroredPlot? = nil
	local realPlotSizeStage = 1
	local finished = false
	local function finishAndNotify()
		if finishedNotified then
			return
		end
		finishedNotified = true
		stopEarlyCamHold()
		notifyIntroComplete()
	end

	local function abortIntro()
		if finished then
			return
		end
		finished = true
		introAvatarShown = false
		introStandCf = nil
		stopIntroExplainerSound()
		stopEarlyCamHold()
		pcall(function()
			WaveSim.stopJoinIntroDemo()
		end)
		WaveSign.endJoinIntroDisplay()
		if savedPlot then
			restorePlotMirror(savedPlot)
			PlotSizeCinematic.applyStageLocal(realPlotSizeStage)
		end
		setOwnedPlotHidden(false)
		hideCharacterLocal(false)
		bindFreeze(false)
		ContextActionService:UnbindAction(SKIP_ACTION)
		for _, name in ipairs({ "OceanTD_JoinIntro", "OceanTD_JoinIntroLoad" }) do
			local leftover = playerGui:FindFirstChild(name)
			if leftover then
				leftover:Destroy()
			end
		end
		destroyEarlyLoadBar()
		restoreHud()
		finishCamToFollow()
		running = false
		finishAndNotify()
	end

	hideIntroTemplate()

	-- PlotAssigned (early, before DataStore) is enough for cam remap — don't wait SessionReady.
	if not ClientPlot.get() then
		local readyDeadline = os.clock() + 15
		while not ClientPlot.get() and os.clock() < readyDeadline do
			task.wait(0.05)
		end
	end
	local plot = ClientPlot.get()
	if not plot then
		abortIntro()
		return
	end
	savedPlot = {
		plotId = plot.plotId,
		cframe = plot.cframe,
		size = plot.size,
		spawnCFrame = plot.spawnCFrame,
		plot1CFrame = plot.plot1CFrame,
		ringCFrame = plot.ringCFrame,
	}
	realPlotSizeStage = SkillPowerUpUI.getStage("PlotSize")

	local function ensureIntroMaxPlotSize()
		if PlotSizeCinematic.applyStageLocal(SkillStages.MAX_STAGE) then
			return true
		end
		return false
	end

	local function waitWavePathReady(timeoutSec: number): boolean
		local deadline = os.clock() + timeoutSec
		while os.clock() < deadline and not finished do
			ensureIntroMaxPlotSize()
			if ClientPlot.get() and ClientPlot.getPlot1CFrame() then
				local root = Workspace:FindFirstChild("WaveRoute")
				local route = root and root:FindFirstChild("A")
				local wp = route and route:FindFirstChild("Waypoints")
				if wp and wp:FindFirstChild("W1") and wp:FindFirstChild("W2") then
					return true
				end
			end
			task.wait(0.1)
		end
		return false
	end

	-- ============================================================
	-- Serialized join intro (no parallel preload races):
	-- A) plot assign  B) Intro ready  C) clone  D) HungryFish+path
	-- E) pan  F) wave demo
	-- ============================================================

	-- (A) Plot assign — already waited above; force max footprint for showcase.
	ensureIntroMaxPlotSize()
	task.spawn(function()
		local deadline = os.clock() + 8
		while not finished and os.clock() < deadline do
			if ensureIntroMaxPlotSize() then
				return
			end
			task.wait(0.15)
		end
	end)
	WaveSign.beginJoinIntroDisplay(true)

	local token = { cancelled = false }
	local showcase: Folder? = nil
	local camConn: RBXScriptConnection? = nil
	local camState = { tweenDone = false, hold = true }
	local skipConns: { RBXScriptConnection } = {}
	local sg: ScreenGui? = nil
	local skipBtn: TextButton? = nil

	local function cleanupSkipUi()
		ContextActionService:UnbindAction(SKIP_ACTION)
		for _, c in ipairs(skipConns) do
			c:Disconnect()
		end
		table.clear(skipConns)
		if skipBtn and GuiService.SelectedObject == skipBtn then
			GuiService.SelectedObject = nil
		end
		if sg and sg.Parent then
			sg:Destroy()
		end
		sg = nil
		skipBtn = nil
		destroyEarlyLoadBar()
	end

	local function finishIntro(skipped: boolean)
		if finished then
			return
		end
		finished = true
		token.cancelled = true
		camState.tweenDone = true
		camState.hold = false
		introAvatarShown = false
		introStandCf = nil
		if skipped then
			stopIntroExplainerSound()
		end

		pcall(function()
			WaveSim.stopJoinIntroDemo()
		end)
		destroyFolder(showcase)
		WaveSign.endJoinIntroDisplay()
		if savedPlot then
			restorePlotMirror(savedPlot)
		end
		realPlotSizeStage = SkillPowerUpUI.getStage("PlotSize")
		PlotSizeCinematic.applyStageLocal(realPlotSizeStage)

		if not ClientPlot.isReady() then
			local hydrateDeadline = os.clock() + 20
			while not ClientPlot.isReady() and os.clock() < hydrateDeadline and player.Parent do
				task.wait(0.05)
			end
		end

		local owned = PlotLoadDropIn.gatherOwnedPlotParts()
		if skipped then
			for _, part in ipairs(owned) do
				PlotLoadDropIn.setPartHiddenLocal(part, false)
			end
		else
			for _, part in ipairs(owned) do
				PlotLoadDropIn.setPartHiddenLocal(part, true)
			end
			local span = if #owned >= 400 then 3 elseif #owned >= 80 then 2 else 1
			PlotLoadDropIn.play(#owned, span)
			task.wait(math.min(span + 0.5, 3.2))
		end

		-- Server owns the one spawn seat (JoinIntroComplete). Wait for it, fallback local snap.
		finishAndNotify()
		do
			local plotNow = ClientPlot.get()
			local spawnCf = plotNow and plotNow.spawnCFrame
			local deadline = os.clock() + 0.9
			local near = false
			while os.clock() < deadline and player.Parent do
				local char = player.Character
				local hrp = char and char:FindFirstChild("HumanoidRootPart")
				local hum = char and char:FindFirstChildOfClass("Humanoid")
				if spawnCf and hrp and hrp:IsA("BasePart") then
					local hip = if hum then math.max(2.5, hum.HipHeight + 1.5) else 3
					local target = spawnCf.Position + Vector3.new(0, hip, 0)
					if (hrp.Position - target).Magnitude < 16 then
						hrp.AssemblyLinearVelocity = Vector3.zero
						hrp.AssemblyAngularVelocity = Vector3.zero
						near = true
						break
					end
				end
				task.wait()
			end
			if not near then
				teleportToPlotSpawn()
			end
		end
		hideCharacterLocal(false)
		if camConn and camConn.Connected then
			camConn:Disconnect()
		end
		stopEarlyCamHold()
		tweenCamToFollowHandoff(if skipped then CAM_HANDOFF_SKIP_SEC else CAM_HANDOFF_SEC)
		bindFreeze(false)
		cleanupSkipUi()
		restoreHud()
		markSeen()
		running = false
		-- Player can walk — nudge them to roll for corals.
		playerGui:SetAttribute(ATTR_ROLL_FINGER, "roll")
		playerGui:SetAttribute("OceanTD_TutorialFreeUpgrade", true)
		-- Tutorial gates: waves unlock after first place; left HUD after first wave session ends.
		-- Backpack stays gated until first roll (unless they already rolled this session).
		if playerGui:GetAttribute("OceanTD_HasRolledThisSession") ~= true then
			playerGui:SetAttribute("OceanTD_TutorialGateBackpack", true)
		end
		playerGui:SetAttribute("OceanTD_TutorialGateWaves", true)
		playerGui:SetAttribute("OceanTD_TutorialGateLeftHud", true)
		-- Cam cycle locked until they close build mode after the first coral hue.
		playerGui:SetAttribute("OceanTD_TutorialGateCam", true)
		playerGui:SetAttribute("OceanTD_TutorialWavesSlotReady", false)
		-- Planning arrow trains start from WaveSim when JoinIntroBusy clears (player in control).
	end

	local function requestSkip()
		if skipRequested or finished then
			return
		end
		skipRequested = true
		if skipBtn then
			flashSkipButton(skipBtn)
		end
		task.delay(0.1, function()
			finishIntro(true)
		end)
	end

	local payload: typeof(syncPayload) = nil
	local pose: IntroCamPose? = nil
	local showcaseParts: { BasePart } = {}
	local demoStarted = false

	-- (B) Intro package ready: sync + frozen package + cam markers.
	-- Keep the load UI up (tips visible) while assets stream; the 4s fill plays
	-- immediately before dismiss so it never flash-completes early.
	payload = waitForSync(12)
	if finished then
		return
	end
	if not payload then
		warn("[JoinIntro] JoinIntroSync missing — skip showcase")
		abortIntro()
		return
	end
	local introInst = waitJoinIntroPackage(45)
	if finished then
		return
	end
	if not introInst then
		warn("[JoinIntro] JoinIntroPackage / Plots.Intro missing — skip showcase")
		abortIntro()
		return
	end
	local poseResult = waitIntroElements(12)
	if finished then
		return
	end
	if not poseResult then
		warn("[JoinIntro] IntroElements missing — skip showcase")
		abortIntro()
		return
	end
	pose = poseResult
	if poseResult.introPos and ClientPlot.get() then
		introStandCf = ClientPlot.remapCFrameFromPlot1(poseResult.introPos)
		standAtIntroFacingCam()
	end
	-- Package is server-frozen; no client stream-stable wait needed.
	local partCount = countIntroParts(introInst)
	if partCount < 1 then
		warn("[JoinIntro] Intro package has 0 parts — showcase empty")
	end

	-- (C) Clone entire Intro package once — preserves Main+Accent hierarchy exactly.
	-- Root-by-root collection previously dropped Accent/Web when naming/sibling rules missed.
	local folder = Instance.new("Folder")
	folder.Name = "OceanTD_JoinIntroShowcase"
	folder.Parent = Workspace
	showcase = folder
	local sourceCf = payload.introSourceCFrame
	local reef = introInst:Clone()
	reef.Name = "IntroReef"
	sanitizeVisual(reef)
	local rawParts = gatherParts(reef)
	local accentInPackage = 0
	for i, part in ipairs(rawParts) do
		if token.cancelled or finished then
			break
		end
		if isIntroAccentOrWebName(part.Name) then
			accentInPackage += 1
		end
		part.CFrame = ClientPlot.remapCFrameFromSource(sourceCf, part.CFrame)
		part.LocalTransparencyModifier = 1
		if i % CLONE_BATCH == 0 then
			RunService.Heartbeat:Wait()
		end
	end
	if not token.cancelled and not finished then
		nestIntroAttachedUnderPrimaries(reef)
		reef.Parent = folder
		table.clear(showcaseParts)
		for _, part in ipairs(gatherParts(reef)) do
			part.LocalTransparencyModifier = 1
			table.insert(showcaseParts, part)
		end
		local accentInShowcase = 0
		for _, part in ipairs(showcaseParts) do
			if isIntroAccentOrWebName(part.Name) then
				accentInShowcase += 1
			end
		end
		print(
			"[JoinIntro] showcase parts=",
			#showcaseParts,
			"accents in package=",
			accentInPackage,
			"accents nested=",
			accentInShowcase
		)
		if accentInPackage < 1 then
			warn("[JoinIntro] Intro package has 0 Accent/Web parts — authored reef may be stem-only")
		end
	end
	if finished then
		return
	end

	-- (D) HungryFish + wave path ready before any camera beat / demo.
	ensureIntroMaxPlotSize()
	if not waitHungryFishReady(8) then
		warn("[JoinIntro] HungryFish not ready in time")
	end
	if not waitWavePathReady(8) then
		warn("[JoinIntro] WaveRoute path not ready in time")
	end
	if finished then
		return
	end

	-- Always a full 4s 0→1 fill the player can watch, then dismiss.
	waitEarlyLoadBarMin()
	if finished then
		return
	end
	destroyEarlyLoadBar()
	WaveSign.beginJoinIntroDisplay(true)

	local camStart = ClientPlot.remapCFrameFromPlot1(pose.camStart).Position
	local camEnd = ClientPlot.remapCFrameFromPlot1(pose.camEnd).Position
	local focusStart = ClientPlot.remapCFrameFromPlot1(pose.focusStart).Position
	local focusEnd = ClientPlot.remapCFrameFromPlot1(pose.focusEnd).Position
	local introWorldCf = if pose.introPos then ClientPlot.remapCFrameFromPlot1(pose.introPos) else nil
	if introWorldCf then
		introStandCf = introWorldCf
		standAtIntroFacingCam()
	end

	for _, part in ipairs(showcaseParts) do
		if part.Parent then
			part.LocalTransparencyModifier = 0
			-- Accents authored at Transparency=1 (or rest attr) must still read as coral color.
			if isIntroAccentOrWebName(part.Name) then
				local stem = part.Parent
				local restT = if stem and stem:IsA("BasePart") then stem:GetAttribute("OceanTD_WebRestTransparency") else nil
				if typeof(restT) == "number" then
					part.Transparency = restT
				elseif part.Transparency >= 0.99 then
					part.Transparency = 0
				end
			end
		end
	end

	-- (E) Pan down.
	WaveSign.fadeInJoinIntroSign(1)
	introAvatarShown = true
	hideCharacterLocal(false)
	stopEarlyCamHold()
	playerGui:SetAttribute(ATTR_FORCE_CAM, "off")
	local skyLook = camStart + Vector3.new(0, 200, 0)
	applyIntroCam(camStart, skyLook)
	local panHoldConn = RunService.RenderStepped:Connect(function()
		standAtIntroFacingCam()
	end)
	local panT0 = os.clock()
	while os.clock() - panT0 < PAN_DOWN_SEC do
		if finished or token.cancelled then
			break
		end
		local u = smoothstep((os.clock() - panT0) / PAN_DOWN_SEC)
		applyIntroCam(camStart, skyLook:Lerp(focusStart, u))
		RunService.RenderStepped:Wait()
	end
	if panHoldConn.Connected then
		panHoldConn:Disconnect()
	end
	if finished then
		return
	end
	applyIntroCam(camStart, focusStart)
	if introWorldCf then
		introStandCf = introWorldCf
		standAtIntroFacingCam()
	end
	introAvatarShown = true
	hideCharacterLocal(false)

	local skipSg, skip = makeUi()
	sg = skipSg
	skipBtn = skip
	table.insert(skipConns, skip.Activated:Connect(requestSkip))
	table.insert(skipConns, skip.MouseButton1Click:Connect(requestSkip))
	GuiService.SelectedObject = skip
	ContextActionService:BindActionAtPriority(SKIP_ACTION, function(_name, state)
		if state == Enum.UserInputState.Begin then
			requestSkip()
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.ButtonA)
	table.insert(skipConns, UserInputService.InputBegan:Connect(function(input, gp)
		if gp then
			return
		end
		if input.KeyCode == Enum.KeyCode.ButtonA then
			requestSkip()
		end
	end))

	local camT0 = os.clock()
	camState.tweenDone = false
	camState.hold = true
	camConn = RunService.RenderStepped:Connect(function()
		if not camState.hold then
			return
		end
		if introAvatarShown then
			standAtIntroFacingCam()
		end
		local u = if camState.tweenDone then 1 else smoothstep((os.clock() - camT0) / CAM_DOWN_SEC)
		if u >= 1 then
			camState.tweenDone = true
			u = 1
		end
		applyIntroCam(camStart:Lerp(camEnd, u), focusStart:Lerp(focusEnd, u))
	end)

	-- (F) Wave demo only after A–E prerequisites.
	if not demoStarted and not token.cancelled and #showcaseParts > 0 then
		ensureIntroMaxPlotSize()
		local okDemo = false
		for _ = 1, 5 do
			if finished or token.cancelled then
				break
			end
			okDemo = WaveSim.startJoinIntroDemo(showcaseParts, INTRO_WAVE)
			if okDemo then
				break
			end
			task.wait(0.35)
		end
		if okDemo then
			demoStarted = true
			WaveSign.beginJoinIntroDisplay(false)
		else
			warn("[JoinIntro] WaveSim demo failed to start after retries")
		end
	elseif #showcaseParts < 1 then
		warn("[JoinIntro] No showcase parts — skipping wave demo")
	end

	if finished then
		return
	end

	local waitUntil = os.clock() + CAM_DOWN_SEC
	while os.clock() < waitUntil and not token.cancelled and not finished do
		task.wait(0.05)
	end
	if finished then
		return
	end
	camState.tweenDone = true

	WaveSim.stopJoinIntroDemo()

	local fallWindow = 0
	if not token.cancelled and #showcaseParts > 0 then
		fallWindow = bleachAndFall(showcaseParts, token)
		task.spawn(function()
			PlotSizeCinematic.tweenStagesLocal(SkillStages.MAX_STAGE, realPlotSizeStage, {
				duration = BLEACH_TOTAL_MAX_SEC,
				cancelled = function()
					return token.cancelled or finished
				end,
			})
		end)
	elseif savedPlot then
		restorePlotMirror(savedPlot)
	end

	local bleachWait = os.clock() + math.max(fallWindow, BLEACH_WAIT_MIN_SEC)
	while os.clock() < bleachWait and not token.cancelled and not finished do
		task.wait(0.05)
	end
	if finished then
		return
	end

	finishIntro(false)
end

task.spawn(function()
	watchHideIntroTemplate()

	if not INTRO_ENABLED then
		destroyEarlyLoadBar()
		playerGui:SetAttribute(ATTR_BUSY, false)
		notifyIntroComplete()
		-- Planning trains: WaveSim listens for JoinIntroBusy clear.
		return
	end

	beginEarlyIntroHold()
	player.CharacterAdded:Connect(function()
		if playerGui:GetAttribute(ATTR_BUSY) ~= true then
			return
		end
		task.defer(function()
			bindFreeze(true)
			if introAvatarShown then
				if introStandCf then
					standAtIntroFacingCam()
				end
				hideCharacterLocal(false)
			else
				hideCharacterLocal(true)
			end
		end)
	end)

	-- Start as soon as the seat is assigned (fires before DataStore load on server).
	-- Waiting on SessionReady kept the full load bar up for 10–20s on device.
	local deadline = os.clock() + 20
	while not ClientPlot.get() and os.clock() < deadline do
		task.wait(0.05)
	end
	task.wait(0.05)
	local ok, err = pcall(runIntro)
	if not ok then
		warn("[JoinIntro] failed:", err)
		pcall(function()
			WaveSim.stopJoinIntroDemo()
		end)
		stopEarlyCamHold()
		destroyEarlyLoadBar()
		hideCharacterLocal(false)
		playerGui:SetAttribute(ATTR_BUSY, false)
		playerGui:SetAttribute(ATTR_CAM_POS, nil)
		bindFreeze(false)
		ContextActionService:UnbindAction(SKIP_ACTION)
		restoreHud()
		finishCamToFollow()
		running = false
		notifyIntroComplete()
		-- Planning trains: WaveSim listens for JoinIntroBusy clear.
	end
end)
