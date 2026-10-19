--!strict
--[[
	Always-on green path ribbon for the friendly fish route (WaveRoute.A).
	Length follows the current Plot Size stage (ends at the reef heart waypoint).
	Hidden while Hide UI is active.
	During waves with crabs/urchins: red GroundA/B ribbons (same beam style).
	Build mode: after session wave > 4 show crab/urchin paths; ≥10 also shark (wave-bar eye hides).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local C = require(script.Parent:WaitForChild("WaveSimConsts"))
local FreeCamConfig = require(script.Parent:WaitForChild("FreeCamConfig"))
local WaveEndVfx = require(script.Parent:WaitForChild("WaveEndVfx"))
local JoinIntroExampleCorals = require(script.Parent:WaitForChild("JoinIntroExampleCorals"))
local GameOverTitle = require(script.Parent:WaitForChild("GameOverTitle"))
local TutorialVo = require(script.Parent:WaitForChild("TutorialVo"))
local WaveFeedPayout = require(script.Parent:WaitForChild("WaveFeedPayout"))
local SkillStages = require(ReplicatedStorage:WaitForChild("OceanTD"):WaitForChild("Shared"):WaitForChild("SkillStages"))
local UiTheme = require(ReplicatedStorage:WaitForChild("OceanTD"):WaitForChild("Shared"):WaitForChild("UiTheme"))
local ReefHealthBarFx = require(ReplicatedStorage:WaitForChild("OceanTD"):WaitForChild("Shared"):WaitForChild("ReefHealthBarFx"))

-- Join-intro narrator beats tied to the green path + GAME OVER.
local INK_PATH_VO_ID = "rbxassetid://112823944631846"
local INK_AFTER_PATH_VO_ID = "rbxassetid://71519622401797" -- "fully fed" follow-up after path clip
local IF_YOU_DONT_VO_ID = "rbxassetid://84988895831598" -- after fully fed, before GAME OVER SFX
local ROLL_FOR_CORAL_VO_ID = "rbxassetid://123894814717945"

local WavePathLines = {}

export type PathLike = {
	totalLen: number,
	segments: { any },
	endPos: Vector3?,
	waypointDists: { number }?,
}

export type Host = {
	-- Primary friendly fish path only (already trimmed to current Plot Size / heart).
	getFishPath: () -> PathLike?,
	sampleFishPath: (PathLike, number) -> (Vector3, Vector3),
	getPlotSizeStage: (() -> number)?,
	-- Crab/urchin GroundA/B routes (red ribbons while those critters are in the wave).
	getGroundPaths: (() -> { PathLike })?,
	-- Single path currently shown when multiple GroundA/B are cycling.
	getHostileDisplayPath: (() -> PathLike?)?,
	sampleGroundPath: ((PathLike, number) -> (Vector3, Vector3))?,
	waveShowsHostilePaths: (() -> boolean)?,
	-- Shark route ribbon while a shark wave is live.
	getSharkPath: (() -> PathLike?)?,
	sampleSharkPath: ((PathLike, number) -> (Vector3, Vector3))?,
	waveShowsSharkPath: (() -> boolean)?,
}

local FOLDER_NAME = "OceanTD_PathLines"
local SAMPLE_STEP = 5 -- studs along path between beam joints
local BEAM_WIDTH = 1.75
local BEAM_TRANSPARENCY = 0.28
local GREEN = C.FILL_GREEN or Color3.fromRGB(40, 255, 90)
local RED = C.CRAB_ARROW_COLOR or C.DANGER_RED or Color3.fromRGB(230, 45, 55)
local SHARK_ORANGE = Color3.fromRGB(255, 140, 40)
local GROUND_Y_LIFT = C.CRAB_ARROW_Y_LIFT or 1.35 -- seafloor paths need a little height
local SHARK_Y_LIFT = 0.35 -- shark route already swims above the floor
local TIP_GREEN = Color3.fromRGB(165, 255, 195)
local TIP_HEAD_STUDS = 14
local TIP_WIDTH = 2.55
local TIP_TRANSPARENCY = 0.04
local TIP_EMISSION = 1
local INK_DUR_MIN = 5
local INK_DUR_MAX = 7
local HEART_POP_SEC = 0.48

local FISH_EMOJI = "🐟"
local FORK_EMOJI = "🍴"
local THUMBS_UP_EMOJI = "👍"
local THUMBS_DOWN_EMOJI = "👎"
local HAPPY_BURST_EMOJIS = { "😊", "😄", "😁", "🥰", "😍" }
local SAD_BURST_EMOJIS = { "💔", "☠️", "💔", "☠️", "💔", "☠️", "💔", "☠️", "💔", "☠️" }
local TIP_FISH_STUDS = 26 -- 50% of prior oversized tip fish
local TIP_SCALE_DOWN_START = 0.6 -- last 40% of fish travel → scale to 0
local TIP_FISH_TRAIL_LAG_SEC = 2.5 -- second emoji fish lags the lead
local TIP_TRAIL_FILL_AT_HEART = 0.5 -- trail hunger only half-full when it arrives
local TIP_LEAD_FULL_AT_U = 0.75 -- lead hunger bar full by 75% of path
local TIP_HUNGER_STUDS_W = 22 -- oversized bar above tip fish
local TIP_HUNGER_STUDS_H = 5.2
local FISH_TRAVEL_MIN = 4
local FISH_TRAVEL_MAX = 6
local END_RATING_IN_FORK_SEC = 0.38
local END_RATING_IN_THUMBS_SEC = 0.42
local END_RATING_THUMB_STAGGER_SEC = 1 -- thumbs up + happy spray before down can arm
local END_RATING_AFTER_HAPPY_PAUSE_SEC = 2 -- extra beat after happy/$D ready, before thumbs down (+1s)
local END_RATING_OUT_SEC = 0.5
local END_RATING_WIDTH_STUDS = 56
local END_RATING_HEIGHT_STUDS = 22
local END_RATING_PEAK = 1.45
local THUMB_BURST_COUNT = 10 -- was 5
-- Different sizes (studs) — 30% of prior large set.
local THUMB_BURST_SIZES = { 28 * 0.3, 36 * 0.3, 44 * 0.3, 52 * 0.3, 62 * 0.3, 32 * 0.3, 40 * 0.3, 48 * 0.3, 56 * 0.3, 60 * 0.3 }
local THUMB_BURST_LIFE = 1.35 * 2 -- fly out over twice as long
local THUMB_BURST_SPAWN_GAP = 0.03 * 2 -- stagger emission across the longer burst
local THUMB_BURST_SIDE_STUDS = 10 -- start offset from heart toward each thumb
local THUMB_BURST_SPEED_MIN = 38 * 2 -- 2× travel distance from spawn
local THUMB_BURST_SPEED_MAX = 72 * 2
local INTRO_REEF_MAX = 10
local INTRO_REEF_BAR_W = 260
local INTRO_REEF_BAR_H = 26
local INTRO_REEF_SLIDE_SEC = 0.55
local INTRO_REEF_BG = Color3.fromRGB(0x00, 0x03, 0x29)

local host: Host? = nil
local linesFolder: Folder? = nil
local hiddenByUi = false
local introReefGui: ScreenGui? = nil
local introReefHost: Frame? = nil
local introReefFill: Frame? = nil
local introReefTrail: Frame? = nil
local introReefTrailState = ReefHealthBarFx.makeState(1)
local introReefLabel: TextLabel? = nil
local introReefHp = INTRO_REEF_MAX

-- Cached samples for in-cinematic grow/shrink (avoid ClearAllChildren every frame).
local livePath: PathLike? = nil
local livePoints: { Vector3 } = {}
local liveAtts: { Attachment } = {}
local liveBeams: { Beam } = {}
local liveBeamMids: { Vector3 } = {}
local liveBeamLastT: { number } = {}
local liveAnchors: BasePart? = nil

-- Red GroundA/B ribbons (independent of green ink / live cache).
local groundContainers: { Folder } = {}
local groundBeams: { Beam } = {}

-- Shark / urchin (hostile) ribbon caches for path-tour POV near-cam fade.
local sharkPoints: { Vector3 } = {}
local sharkBeams: { Beam } = {}
local sharkBeamMids: { Vector3 } = {}
local sharkBeamLastT: { number } = {}
local hostilePoints: { Vector3 } = {}
local hostileBeams: { Beam } = {}
local hostileBeamMids: { Vector3 } = {}
local hostileBeamLastT: { number } = {}

-- Fish Cam POV: invisible near cam → default green far (smoothstep 10→90).
local POV_NEAR_CLEAR_STUDS = 10 -- ≤ this: 100% transparent (gone)
local POV_FAR_DEFAULT_STUDS = 90 -- ≥ this: default visible green
-- Shark/urchin path-tour POV: same look, but ribbon becomes visible a bit closer.
local TOUR_POV_NEAR_CLEAR_STUDS = 4
local TOUR_POV_FAR_DEFAULT_STUDS = 70
local POV_T_EPS = 0.01
local povFadeConn: RBXScriptConnection? = nil
local povFadeOn = false
local tourPovFadeOn = false

local inkToken = 0
local inkActive = false
local inkCompleted = false
-- Skip Intro snapped to end-of-cinematic; never start a fresh ink draw until destroy().
local inkSkipSettled = false
-- Set when the "if you don't…" VO ends — GAME OVER SFX/title wait on this (not isPlaying gaps).
local inkIfYouDontVoDone = false
local inkDrawLen = 0
local tipAtt0: Attachment? = nil
local tipAtt1: Attachment? = nil
local tipBeam: Beam? = nil

type TipFishEmoji = {
	anchor: BasePart,
	fishScale: UIScale,
	hungerBb: BillboardGui,
	hungerFill: Frame,
	hungerStroke: UIStroke,
	hungerScale: UIScale,
}

local tipLeadFish: TipFishEmoji? = nil
local tipTrailFish: TipFishEmoji? = nil
local endRatingAnchor: BasePart? = nil
local revealDoneEvent = Instance.new("BindableEvent")
local paintFullPathIfPossible: () -> boolean
local applyBeamEnabled: (boolean) -> ()
local syncPovFadeFromAttr: () -> ()

function WavePathLines.bind(h: Host)
	host = h
	local plr = Players.LocalPlayer
	local pg = plr and plr:FindFirstChildOfClass("PlayerGui")
	if pg then
		if pg:GetAttribute(FreeCamConfig.ATTR_FISH_CAM_POV) == nil then
			pg:SetAttribute(FreeCamConfig.ATTR_FISH_CAM_POV, false)
		end
		if pg:GetAttribute(FreeCamConfig.ATTR_PATH_TOUR_POV) == nil then
			pg:SetAttribute(FreeCamConfig.ATTR_PATH_TOUR_POV, false)
		end
		pg:GetAttributeChangedSignal(FreeCamConfig.ATTR_FISH_CAM_POV):Connect(function()
			syncPovFadeFromAttr()
		end)
		pg:GetAttributeChangedSignal(FreeCamConfig.ATTR_PATH_TOUR_POV):Connect(function()
			syncPovFadeFromAttr()
		end)
		-- Defer until locals below are assigned (bind can run mid-module init).
		task.defer(function()
			syncPovFadeFromAttr()
		end)
	end
end

local function ensureFolder(): Folder
	if linesFolder and linesFolder.Parent then
		return linesFolder
	end
	local existing = Workspace:FindFirstChild(FOLDER_NAME)
	if existing and existing:IsA("Folder") then
		linesFolder = existing
		return existing
	end
	local f = Instance.new("Folder")
	f.Name = FOLDER_NAME
	f.Parent = Workspace
	linesFolder = f
	return f
end

local function destroyTipHead()
	if tipBeam then
		tipBeam:Destroy()
		tipBeam = nil
	end
	if tipAtt0 then
		tipAtt0:Destroy()
		tipAtt0 = nil
	end
	if tipAtt1 then
		tipAtt1:Destroy()
		tipAtt1 = nil
	end
end

local function destroyTipFishEmojis()
	if tipLeadFish then
		tipLeadFish.anchor:Destroy()
		tipLeadFish = nil
	end
	if tipTrailFish then
		tipTrailFish.anchor:Destroy()
		tipTrailFish = nil
	end
end

local function destroyInkEmojis()
	destroyTipFishEmojis()
	if endRatingAnchor then
		endRatingAnchor:Destroy()
		endRatingAnchor = nil
	end
	pcall(function()
		GameOverTitle.cancel()
	end)
	pcall(function()
		WaveFeedPayout.clearIntroDemo()
	end)
	if introReefGui then
		introReefGui:Destroy()
		introReefGui = nil
	end
	introReefHost = nil
	introReefFill = nil
	introReefTrail = nil
	introReefTrailState = ReefHealthBarFx.makeState(1)
	introReefLabel = nil
	introReefHp = INTRO_REEF_MAX
end

local function brokenHeartBurstDuration(): number
	-- Last spawn delay + max lifetime variance.
	return (THUMB_BURST_COUNT - 1) * THUMB_BURST_SPAWN_GAP + 0.04 + THUMB_BURST_LIFE * 1.15
end

local function setIntroReefHealth(cur: number)
	introReefHp = math.clamp(math.floor(cur + 0.5), 0, INTRO_REEF_MAX)
	local frac = introReefHp / INTRO_REEF_MAX
	if introReefLabel then
		introReefLabel.Text = ("🤍 Reef Health %d/%d"):format(introReefHp, INTRO_REEF_MAX)
	end
	if introReefFill then
		local bar = introReefHost
		ReefHealthBarFx.applyWithFly(introReefFill, introReefTrail, bar, frac, introReefTrailState, function()
			local ok, WaveEndVfx = pcall(function()
				return require(script.Parent:WaitForChild("WaveEndVfx"))
			end)
			if ok and WaveEndVfx and WaveEndVfx.getEndHeartWorldPos then
				return WaveEndVfx.getEndHeartWorldPos()
			end
			return nil
		end)
	end
end

local function destroyIntroReefBar()
	if introReefGui then
		introReefGui:Destroy()
		introReefGui = nil
	end
	introReefHost = nil
	introReefFill = nil
	introReefTrail = nil
	introReefTrailState = ReefHealthBarFx.makeState(1)
	introReefLabel = nil
	introReefHp = INTRO_REEF_MAX
end

local function showIntroReefBarFull()
	local lp = Players.LocalPlayer
	local pg = lp and lp:FindFirstChildOfClass("PlayerGui")
	if not pg then
		return
	end
	destroyIntroReefBar()

	local sg = Instance.new("ScreenGui")
	sg.Name = "OceanTD_InkIntroReefBar"
	sg.IgnoreGuiInset = true
	sg.ResetOnSpawn = false
	sg.DisplayOrder = 5100
	sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	sg.Parent = pg
	introReefGui = sg

	local hostFr = Instance.new("Frame")
	hostFr.Name = "Host"
	hostFr.BackgroundTransparency = 1
	hostFr.AnchorPoint = Vector2.new(0.5, 1)
	hostFr.Position = UDim2.new(0.5, 0, 1, -10)
	hostFr.Size = UDim2.fromOffset(INTRO_REEF_BAR_W, INTRO_REEF_BAR_H)
	hostFr.Parent = sg
	introReefHost = hostFr

	local reefBar = Instance.new("Frame")
	reefBar.Name = "ReefProgress"
	reefBar.BackgroundColor3 = INTRO_REEF_BG
	reefBar.BackgroundTransparency = 0.5
	reefBar.BorderSizePixel = 0
	reefBar.Size = UDim2.fromScale(1, 1)
	reefBar.ClipsDescendants = false
	reefBar.Parent = hostFr
	local reefCorner = Instance.new("UICorner")
	reefCorner.CornerRadius = UDim.new(1, 0)
	reefCorner.Parent = reefBar
	local reefStroke = Instance.new("UIStroke")
	reefStroke.Color = Color3.new(1, 1, 1)
	reefStroke.Thickness = 1.5
	reefStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	reefStroke.Parent = reefBar

	introReefTrail = ReefHealthBarFx.ensureTrail(reefBar, 2)
	introReefTrailState = ReefHealthBarFx.makeState(1)

	local reefFill = Instance.new("Frame")
	reefFill.Name = "Fill"
	reefFill.BackgroundColor3 = ReefHealthBarFx.colorForFrac(1)
	reefFill.BorderSizePixel = 0
	reefFill.Size = UDim2.fromScale(1, 1)
	reefFill.ZIndex = 3
	reefFill.Parent = reefBar
	local reefFillCorner = Instance.new("UICorner")
	reefFillCorner.CornerRadius = UDim.new(1, 0)
	reefFillCorner.Parent = reefFill
	introReefFill = reefFill

	local reefLabel = Instance.new("TextLabel")
	reefLabel.Name = "ReefLabel"
	reefLabel.BackgroundTransparency = 1
	reefLabel.Size = UDim2.fromScale(1, 1)
	reefLabel.Font = UiTheme.Font
	reefLabel.TextSize = 19
	reefLabel.TextColor3 = Color3.new(1, 1, 1)
	reefLabel.TextStrokeTransparency = 0.35
	reefLabel.TextStrokeColor3 = Color3.new(0, 0, 0)
	reefLabel.TextXAlignment = Enum.TextXAlignment.Center
	reefLabel.TextYAlignment = Enum.TextYAlignment.Center
	reefLabel.ZIndex = 4
	reefLabel.Parent = reefBar
	introReefLabel = reefLabel

	setIntroReefHealth(INTRO_REEF_MAX)
end

local function slideOutIntroReefBar(myToken: number)
	local hostFr = introReefHost
	local sg = introReefGui
	if not hostFr or not sg or not sg.Parent then
		destroyIntroReefBar()
		return
	end
	local startPos = hostFr.Position
	local endPos = UDim2.new(startPos.X.Scale, startPos.X.Offset, 1, INTRO_REEF_BAR_H + 40)
	local t0 = os.clock()
	while myToken == inkToken and hostFr.Parent do
		local u = math.clamp((os.clock() - t0) / INTRO_REEF_SLIDE_SEC, 0, 1)
		local e = u * u * (3 - 2 * u)
		hostFr.Position = startPos:Lerp(endPos, e)
		if u >= 1 then
			break
		end
		RunService.RenderStepped:Wait()
	end
	destroyIntroReefBar()
end

local function playGameOverTitle(fromWorld: Vector3, myToken: number)
	if myToken ~= inkToken or hiddenByUi then
		return
	end
	GameOverTitle.playAndWait(fromWorld, function()
		return myToken ~= inkToken or hiddenByUi
	end)
end

local function makeEmojiLabel(parent: Instance, text: string, z: number): TextLabel
	local lbl = Instance.new("TextLabel")
	lbl.BackgroundTransparency = 1
	lbl.Size = UDim2.fromScale(1, 1)
	lbl.Font = Enum.Font.SourceSansBold
	lbl.Text = text
	lbl.TextScaled = true
	lbl.TextStrokeTransparency = 0.35
	lbl.TextStrokeColor3 = Color3.fromRGB(10, 20, 30)
	lbl.ZIndex = z
	lbl.Parent = parent
	return lbl
end

local TIP_HUNGER_DANGER_FLASH_SEC = 0.28

local function makeTipHungerBillboard(adornee: BasePart): (BillboardGui, Frame, UIStroke, UIScale)
	local bb = Instance.new("BillboardGui")
	bb.Name = "TipHunger"
	bb.Adornee = adornee
	bb.AlwaysOnTop = true
	bb.LightInfluence = 0
	bb.MaxDistance = 4000
	bb.Size = UDim2.fromScale(TIP_HUNGER_STUDS_W, TIP_HUNGER_STUDS_H)
	bb.StudsOffset = Vector3.new(0, TIP_FISH_STUDS * 0.55 + TIP_HUNGER_STUDS_H * 0.55, 0)
	bb.Parent = adornee
	local hungerScale = Instance.new("UIScale")
	hungerScale.Scale = 1
	hungerScale.Parent = bb

	local fork = Instance.new("TextLabel")
	fork.Name = "Fork"
	fork.BackgroundTransparency = 1
	fork.AnchorPoint = Vector2.new(0, 0.5)
	fork.Position = UDim2.new(0, 0, 0.5, 0)
	fork.Size = UDim2.fromScale(0.18, 1)
	fork.Font = Enum.Font.SourceSansBold
	fork.Text = FORK_EMOJI
	fork.TextScaled = true
	fork.ZIndex = 3
	fork.Parent = bb

	local bar = Instance.new("Frame")
	bar.Name = "Bg"
	bar.BackgroundColor3 = Color3.new(0, 0, 0)
	bar.BackgroundTransparency = 0.45
	bar.BorderSizePixel = 0
	bar.AnchorPoint = Vector2.new(0, 0.5)
	bar.Position = UDim2.new(0.2, 0, 0.5, 0)
	bar.Size = UDim2.fromScale(0.78, 0.42)
	bar.ZIndex = 1
	bar.Parent = bb
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.35, 0)
	corner.Parent = bar
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.new(1, 1, 1)
	stroke.Thickness = 2.5
	stroke.Parent = bar

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.BackgroundColor3 = GREEN
	fill.BackgroundTransparency = 0
	fill.BorderSizePixel = 0
	fill.Size = UDim2.fromScale(0, 1)
	fill.ZIndex = 2
	fill.Parent = bar
	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(0.35, 0)
	fillCorner.Parent = fill

	return bb, fill, stroke, hungerScale
end

local function createTipFishEmoji(name: string): TipFishEmoji
	local folder = ensureFolder()
	local anchor = Instance.new("Part")
	anchor.Name = name
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.CastShadow = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(0.2, 0.2, 0.2)
	anchor.CFrame = CFrame.new()
	anchor.Parent = folder

	local fishBb = Instance.new("BillboardGui")
	fishBb.Name = "TipFish"
	fishBb.Adornee = anchor
	fishBb.AlwaysOnTop = true
	fishBb.LightInfluence = 0
	fishBb.MaxDistance = 4000
	fishBb.Size = UDim2.fromScale(TIP_FISH_STUDS, TIP_FISH_STUDS)
	fishBb.StudsOffset = Vector3.new(0, TIP_FISH_STUDS * 0.12, 0)
	fishBb.Parent = anchor
	makeEmojiLabel(fishBb, FISH_EMOJI, 2)
	local fishScale = Instance.new("UIScale")
	fishScale.Scale = 1
	fishScale.Parent = fishBb

	local hungerBb, hungerFill, hungerStroke, hungerScale = makeTipHungerBillboard(anchor)
	return {
		anchor = anchor,
		fishScale = fishScale,
		hungerBb = hungerBb,
		hungerFill = hungerFill,
		hungerStroke = hungerStroke,
		hungerScale = hungerScale,
	}
end

local function ensureTipFishEmojis()
	-- Anchors may be temporarily unparented while hidden — do not recreate (that wiped the trail).
	if tipLeadFish and tipLeadFish.anchor and tipTrailFish and tipTrailFish.anchor then
		return
	end
	-- Only clear the tip fish — never the end-rating 🍴 / GAME OVER stage.
	destroyTipFishEmojis()
	tipLeadFish = createTipFishEmoji("InkTipFishLead")
	tipTrailFish = createTipFishEmoji("InkTipFishTrail")
end

local function updateOneTipFish(
	fish: TipFishEmoji,
	worldPos: Vector3,
	tweenU: number,
	fill01: number,
	visible: boolean,
	flashDanger: boolean
)
	local anchor = fish.anchor
	if not visible or hiddenByUi then
		if anchor.Parent then
			anchor.Parent = nil
		end
		return
	end
	if not anchor.Parent then
		anchor.Parent = ensureFolder()
	end
	anchor.CFrame = CFrame.new(worldPos)
	-- Last 40% of this fish's own travel: oversized → 0.
	local scale = 1
	if tweenU >= TIP_SCALE_DOWN_START then
		local t = math.clamp((tweenU - TIP_SCALE_DOWN_START) / (1 - TIP_SCALE_DOWN_START), 0, 1)
		scale = 1 - t
	end
	fish.fishScale.Scale = scale
	fish.hungerScale.Scale = scale
	fish.hungerFill.Size = UDim2.fromScale(math.clamp(fill01, 0, 1), 1)
	-- Trail only: flash red on last 40%. Lead stays green (full by 75%).
	if flashDanger and tweenU >= TIP_SCALE_DOWN_START then
		local onRed = (math.floor(os.clock() / TIP_HUNGER_DANGER_FLASH_SEC) % 2) == 0
		local dangerRed = C.DANGER_RED or Color3.fromRGB(255, 45, 55)
		fish.hungerFill.BackgroundColor3 = if onRed then dangerRed else GREEN
		fish.hungerStroke.Color = if onRed then dangerRed else Color3.new(1, 1, 1)
	else
		fish.hungerFill.BackgroundColor3 = GREEN
		fish.hungerStroke.Color = Color3.new(1, 1, 1)
	end
	local show = scale > 0.01
	for _, ch in ipairs(anchor:GetChildren()) do
		if ch:IsA("BillboardGui") then
			ch.Enabled = show
		end
	end
end

local function updateTipFishEmojis(
	leadPos: Vector3,
	leadU: number,
	leadFill: number,
	trailPos: Vector3,
	trailU: number,
	trailFill: number,
	trailVisible: boolean
)
	if hiddenByUi then
		if tipLeadFish and tipLeadFish.anchor.Parent then
			tipLeadFish.anchor.Parent = nil
		end
		if tipTrailFish and tipTrailFish.anchor.Parent then
			tipTrailFish.anchor.Parent = nil
		end
		return
	end
	ensureTipFishEmojis()
	if tipLeadFish then
		-- Lead scales out on its last 40%; hide only after it finishes (trail keeps going).
		updateOneTipFish(tipLeadFish, leadPos, leadU, leadFill, leadU < 1, false)
	end
	if tipTrailFish then
		-- Trail appears only once it starts moving; stays until its own path scale-out at the heart.
		updateOneTipFish(tipTrailFish, trailPos, trailU, trailFill, trailVisible and trailU < 1, true)
	end
end

-- Directional firework burst from a world origin (sideDir should be unit-ish).
local function burstThumbSideEmojis(
	origin: Vector3,
	sideDir: Vector3,
	emojis: { string },
	myToken: number,
	hostFolder: Folder,
	onSpawn: ((index: number) -> ())?
)
	local flat = Vector3.new(sideDir.X, 0, sideDir.Z)
	if flat.Magnitude < 1e-3 then
		flat = Vector3.new(1, 0, 0)
	else
		flat = flat.Unit
	end
	local rng = Random.new()
	-- Shuffle size slots so each burst looks unique.
	local sizes = table.clone(THUMB_BURST_SIZES)
	for i = #sizes, 2, -1 do
		local j = rng:NextInteger(1, i)
		sizes[i], sizes[j] = sizes[j], sizes[i]
	end
	for i = 1, THUMB_BURST_COUNT do
		local emoji = emojis[((i - 1) % #emojis) + 1]
		local sizeStuds = sizes[((i - 1) % #sizes) + 1]
		local delaySec = (i - 1) * THUMB_BURST_SPAWN_GAP + rng:NextNumber(0, 0.04)
		task.delay(delaySec, function()
			if myToken ~= inkToken or hiddenByUi then
				return
			end
			if onSpawn then
				pcall(onSpawn, i)
			end
			local part = Instance.new("Part")
			part.Name = "InkThumbBurst"
			part.Anchored = true
			part.CanCollide = false
			part.CanQuery = false
			part.CanTouch = false
			part.CastShadow = false
			part.Transparency = 1
			part.Size = Vector3.new(0.3, 0.3, 0.3)
			part.CFrame = CFrame.new(origin)
			part.Parent = hostFolder

			local gui = Instance.new("BillboardGui")
			gui.Name = "BurstEmoji"
			gui.Adornee = part
			gui.AlwaysOnTop = true
			gui.LightInfluence = 0
			gui.MaxDistance = 4000
			gui.Size = UDim2.fromScale(sizeStuds, sizeStuds)
			gui.Parent = part

			local scale = Instance.new("UIScale")
			scale.Scale = 0.08
			scale.Parent = gui
			makeEmojiLabel(gui, emoji, 5)

			-- Mostly out the side, with a fan + upward lift.
			local yawJitter = rng:NextNumber(-0.55, 0.55)
			local upAmt = rng:NextNumber(0.35, 1.15)
			local side = (CFrame.Angles(0, yawJitter, 0)):VectorToWorldSpace(flat)
			local dir = (side * 1.15 + Vector3.new(0, upAmt, 0)).Unit
			local speed = rng:NextNumber(THUMB_BURST_SPEED_MIN, THUMB_BURST_SPEED_MAX)
			local vel = dir * speed
			local grav = rng:NextNumber(42, 78)
			local life = THUMB_BURST_LIFE * rng:NextNumber(0.85, 1.15)
			local peak = rng:NextNumber(0.95, 1.35)
			local popAt = rng:NextNumber(0.12, 0.28)
			local pos = origin
			local t0 = os.clock()
			task.spawn(function()
				while part.Parent and myToken == inkToken do
					local age = os.clock() - t0
					if age >= life then
						break
					end
					local dt = RunService.RenderStepped:Wait()
					vel += Vector3.new(0, -grav, 0) * dt
					vel *= (1 - 0.32 * dt)
					pos += vel * dt
					part.CFrame = CFrame.new(pos)
					if age < popAt then
						scale.Scale = 0.08 + (peak - 0.08) * (age / popAt)
					else
						local fadeU = math.clamp((age - popAt) / math.max(0.05, life - popAt), 0, 1)
						scale.Scale = peak * (1 - 0.25 * fadeU)
						local lbl = gui:FindFirstChildOfClass("TextLabel")
						if lbl then
							lbl.TextTransparency = fadeU
							lbl.TextStrokeTransparency = 0.35 + 0.65 * fadeU
						end
					end
				end
				if part.Parent then
					part:Destroy()
				end
			end)
		end)
	end
end

local function playEndRatingEmojis(at: Vector3, myToken: number)
	-- Do NOT destroy tip fish here — it must finish traveling to the heart.
	if hiddenByUi or myToken ~= inkToken then
		return
	end
	if endRatingAnchor and endRatingAnchor.Parent then
		endRatingAnchor:Destroy()
		endRatingAnchor = nil
	end
	local folder = ensureFolder()
	local anchor = Instance.new("Part")
	anchor.Name = "InkEndRating"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.CastShadow = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(0.2, 0.2, 0.2)
	anchor.CFrame = CFrame.new(at)
	anchor.Parent = folder
	endRatingAnchor = anchor

	local bb = Instance.new("BillboardGui")
	bb.Name = "EndRating"
	bb.Adornee = anchor
	bb.AlwaysOnTop = true
	bb.LightInfluence = 0
	bb.MaxDistance = 4000
	bb.Size = UDim2.fromScale(END_RATING_WIDTH_STUDS, END_RATING_HEIGHT_STUDS)
	bb.StudsOffset = Vector3.new(0, END_RATING_HEIGHT_STUDS * 0.35, 0)
	bb.Parent = anchor

	local stage = Instance.new("Frame")
	stage.Name = "Stage"
	stage.BackgroundTransparency = 1
	stage.Size = UDim2.fromScale(1, 1)
	stage.Parent = bb

	-- Absolute layout so thumbs can fly out from / collapse into the fork center.
	local function makeEmoji(text: string, z: number): (Frame, UIScale)
		local f = Instance.new("Frame")
		f.BackgroundTransparency = 1
		f.AnchorPoint = Vector2.new(0.5, 0.5)
		f.Position = UDim2.fromScale(0.5, 0.5) -- fork center
		f.Size = UDim2.fromScale(0.28, 0.95)
		f.ZIndex = z
		f.Parent = stage
		makeEmojiLabel(f, text, z)
		local sc = Instance.new("UIScale")
		sc.Scale = 0
		sc.Parent = f
		return f, sc
	end

	local forkFrame, forkScale = makeEmoji(FORK_EMOJI, 3)
	local upFrame, upScale = makeEmoji(THUMBS_UP_EMOJI, 2)
	local downFrame, downScale = makeEmoji(THUMBS_DOWN_EMOJI, 2)

	local forkPos = UDim2.fromScale(0.5, 0.5)
	local upPos = UDim2.fromScale(0.22, 0.5)
	local downPos = UDim2.fromScale(0.78, 0.5)

	local function easeOutCubic(u: number): number
		return 1 - (1 - u) ^ 3
	end
	local function easeOutBack(u: number): number
		local t = u - 1
		return 1 + t * t * (2.70158 * t + 1.70158)
	end
	local function overscaleIn(u: number): number
		-- 0 → peak → 1
		if u < 0.65 then
			return END_RATING_PEAK * easeOutCubic(u / 0.65)
		end
		local v = (u - 0.65) / 0.35
		return END_RATING_PEAK + (1 - END_RATING_PEAK) * easeOutCubic(v)
	end
	local function overscaleOut(u: number): number
		-- 1 → peak → 0
		if u < 0.35 then
			return 1 + (END_RATING_PEAK - 1) * easeOutCubic(u / 0.35)
		end
		local v = (u - 0.35) / 0.65
		return END_RATING_PEAK * (1 - easeOutCubic(v))
	end

	-- 1) Fork overscales in at center.
	do
		local t0 = os.clock()
		while myToken == inkToken and anchor.Parent do
			local u = (os.clock() - t0) / END_RATING_IN_FORK_SEC
			if u >= 1 then
				break
			end
			forkScale.Scale = overscaleIn(math.clamp(u, 0, 1))
			forkFrame.Position = forkPos
			RunService.RenderStepped:Wait()
		end
		forkScale.Scale = 1
		forkFrame.Position = forkPos
	end
	if myToken ~= inkToken or not anchor.Parent then
		return
	end

	-- Camera-relative left/right so bursts leave each thumb's outer side.
	local cam = Workspace.CurrentCamera
	local right = if cam then Vector3.new(cam.CFrame.RightVector.X, 0, cam.CFrame.RightVector.Z) else Vector3.new(1, 0, 0)
	if right.Magnitude < 1e-3 then
		right = Vector3.new(1, 0, 0)
	else
		right = right.Unit
	end
	local burstY = at + Vector3.new(0, END_RATING_HEIGHT_STUDS * 0.35, 0)
	local upBurstOrigin = burstY - right * THUMB_BURST_SIDE_STUDS
	local downBurstOrigin = burstY + right * THUMB_BURST_SIDE_STUDS
	-- 2) Thumbs up + happy burst + $D flies → then thumbs down + skulls / broken hearts.
	local thumbStart = os.clock()
	local downStarted = false
	local downBurstAt: number? = nil
	local downReadyAt: number? = nil -- armed once happy/$D gates clear; then +pause
	local payoutDone = false
	showIntroReefBarFull()
	pcall(function()
		WaveFeedPayout.beginIntroDemo()
	end)
	burstThumbSideEmojis(upBurstOrigin, -right, HAPPY_BURST_EMOJIS, myToken, folder, function(_i: number)
		WaveEndVfx.playHappyExitSoundOnce()
	end)
	-- $D flies from heart → bottom-left; must finish before broken hearts.
	task.spawn(function()
		pcall(function()
			WaveFeedPayout.playIntroHappyBurstAndWait(at)
		end)
		payoutDone = true
	end)
	do
		while myToken == inkToken and anchor.Parent do
			local now = os.clock()
			local upU = math.clamp((now - thumbStart) / END_RATING_IN_THUMBS_SEC, 0, 1)
			local upE = easeOutBack(upU)
			upScale.Scale = overscaleIn(upU)
			upFrame.Position = forkPos:Lerp(upPos, math.clamp(upE, 0, 1))

			-- Arm thumbs down only after stagger + $D done, then wait the extra pause.
			-- (VO chain is independent — do not retarget narrator timing here.)
			if not downReadyAt and payoutDone and (now - thumbStart) >= END_RATING_THUMB_STAGGER_SEC then
				downReadyAt = now + END_RATING_AFTER_HAPPY_PAUSE_SEC
			end
			if not downStarted and downReadyAt and now >= downReadyAt then
				downStarted = true
				downBurstAt = now
				pcall(function()
					WaveEndVfx.resetStreak()
				end)
				burstThumbSideEmojis(downBurstOrigin, right, SAD_BURST_EMOJIS, myToken, folder, function(i: number)
					setIntroReefHealth(INTRO_REEF_MAX - i)
					WaveEndVfx.playReefTickSoundOnce()
				end)
			end
			if downStarted and downBurstAt then
				local downU = math.clamp((now - downBurstAt) / END_RATING_IN_THUMBS_SEC, 0, 1)
				local downE = easeOutBack(downU)
				downScale.Scale = overscaleIn(downU)
				downFrame.Position = forkPos:Lerp(downPos, math.clamp(downE, 0, 1))
				if downU >= 1 and upU >= 1 then
					break
				end
			end
			RunService.RenderStepped:Wait()
		end
		upScale.Scale = 1
		upFrame.Position = upPos
		if downStarted then
			downScale.Scale = 1
			downFrame.Position = downPos
		end
	end
	if myToken ~= inkToken or not anchor.Parent then
		return
	end

	-- GAME OVER SFX/title fire exactly when "if you don't…" VO ends (not after hearts,
	-- and not on TutorialVo.isPlaying() which dips false between chained clips).
	while not inkIfYouDontVoDone and myToken == inkToken do
		RunService.RenderStepped:Wait()
	end
	if myToken ~= inkToken then
		return
	end
	playGameOverTitle(downBurstOrigin, myToken)
	if myToken ~= inkToken then
		return
	end
	-- GAME OVER fully off-screen → "roll for coral" narrator.
	pcall(function()
		TutorialVo.play(ROLL_FOR_CORAL_VO_ID, "OceanTD_JoinIntroRollCoral")
	end)
	-- Unblock JoinIntro immediately so HUD / roll finger appear with the VO (not after it).
	inkCompleted = true
	revealDoneEvent:Fire()
	-- Slide reef bar + $D HUD down together.
	local reefDone = false
	local sdDone = false
	task.spawn(function()
		slideOutIntroReefBar(myToken)
		reefDone = true
	end)
	task.spawn(function()
		pcall(function()
			WaveFeedPayout.slideOutIntroDemoAndWait()
		end)
		sdDone = true
	end)
	while (not reefDone or not sdDone) and myToken == inkToken do
		RunService.RenderStepped:Wait()
	end
	if myToken ~= inkToken or not anchor.Parent then
		return
	end

	-- 3) All three overscale out collapsing into the fork center.
	do
		local t0 = os.clock()
		while myToken == inkToken and anchor.Parent do
			local u = math.clamp((os.clock() - t0) / END_RATING_OUT_SEC, 0, 1)
			local e = easeOutCubic(u)
			local sc = overscaleOut(u)
			forkScale.Scale = sc
			upScale.Scale = sc
			downScale.Scale = sc
			forkFrame.Position = forkPos
			upFrame.Position = upPos:Lerp(forkPos, e)
			downFrame.Position = downPos:Lerp(forkPos, e)
			if u >= 1 then
				break
			end
			RunService.RenderStepped:Wait()
		end
	end
	if endRatingAnchor == anchor then
		endRatingAnchor = nil
	end
	if anchor.Parent then
		anchor:Destroy()
	end
end

local function cancelInkReveal()
	local wasActive = inkActive
	inkToken += 1
	inkActive = false
	inkDrawLen = 0
	destroyTipHead()
	destroyInkEmojis()
	pcall(function()
		require(script.Parent:WaitForChild("IntroCamPunch")).cancel()
	end)
	pcall(function()
		JoinIntroExampleCorals.clear()
	end)
	if wasActive then
		pcall(function()
			WaveEndVfx.restoreHeartAfterInkCancel()
		end)
		-- Do NOT fire revealDone here — that unblocks JoinIntro's wait and was starting
		-- the roll-finger (training) handoff while the intro cinematic was still the intent.
	end
end

--[[
	Skip Intro: abort the remaining intro cinematic (ink / fish / fork / GAME OVER),
	paint the finished green path + heart, and unblock waitRevealComplete.
	This is still the END OF INTRO — caller starts roll-finger training after this returns.
]]
function WavePathLines.finishIntroCinematicSkipped()
	-- Bump token first so any in-flight rebuildForPath (half-draw) aborts before trim.
	inkToken += 1
	inkActive = false
	destroyTipHead()
	destroyInkEmojis()
	pcall(function()
		require(script.Parent:WaitForChild("IntroCamPunch")).cancel()
	end)
	pcall(function()
		TutorialVo.stop()
	end)
	pcall(function()
		JoinIntroExampleCorals.clear()
	end)

	hiddenByUi = false
	inkSkipSettled = true
	inkCompleted = true
	inkIfYouDontVoDone = true
	-- rebuildForPath blocks while JoinIntroBusy unless inkActive — paint directly.
	local painted = paintFullPathIfPossible()
	if not painted and livePath and livePath.totalLen > 0.5 and #liveBeams > 0 then
		-- Fallback: expand the in-progress ribbon to full length (no busy/inkActive gate).
		local fullLen = livePath.totalLen
		inkDrawLen = fullLen
		local n = #liveAtts
		for i = 1, n do
			liveAtts[i].Position = livePoints[i]
		end
		for _, beam in ipairs(liveBeams) do
			beam.Enabled = true
		end
		painted = true
	end

	inkActive = false
	inkCompleted = true
	inkSkipSettled = true
	-- Full-size heart + see-through orb (fast; do not stack long waits here).
	pcall(function()
		WaveEndVfx.settleHeartAfterIntroSkip()
	end)
	revealDoneEvent:Fire()
	return painted
end

-- Call before training handoff so Skip always leaves a full W1→heart ribbon.
-- Path only — heart settle belongs in finishIntroCinematicSkipped (avoid multi-second stacks).
function WavePathLines.ensureFinishedPathVisible(timeoutSec: number?): boolean
	hiddenByUi = false
	inkSkipSettled = true
	inkCompleted = true
	inkActive = false
	local deadline = os.clock() + (if typeof(timeoutSec) == "number" then timeoutSec else 0.6)
	while os.clock() < deadline do
		if paintFullPathIfPossible() and WavePathLines.hasRibbon() then
			applyBeamEnabled(true)
			return true
		end
		task.wait()
	end
	local ok = paintFullPathIfPossible()
	applyBeamEnabled(WavePathLines.hasRibbon())
	return ok
end

local function clearLiveCache()
	destroyTipHead()
	destroyInkEmojis()
	livePath = nil
	table.clear(livePoints)
	table.clear(liveAtts)
	table.clear(liveBeams)
	table.clear(liveBeamMids)
	table.clear(liveBeamLastT)
	liveAnchors = nil
end

local function povBlendU(dist: number, nearClear: number, farDefault: number): number
	-- 0 at/near cam, 1 at far default band.
	if dist <= nearClear then
		return 0
	end
	if dist >= farDefault then
		return 1
	end
	local u = (dist - nearClear) / (farDefault - nearClear)
	u = math.clamp(u, 0, 1)
	return u * u * (3 - 2 * u) -- smoothstep
end

local function transparencyForPovDist(dist: number, nearClear: number, farDefault: number): number
	-- Close = fully invisible (1); far = default ribbon (BEAM_TRANSPARENCY).
	local u = povBlendU(dist, nearClear, farDefault)
	return 1 + (BEAM_TRANSPARENCY - 1) * u
end

local function widthForPovDist(dist: number, nearClear: number, farDefault: number): number
	local u = povBlendU(dist, nearClear, farDefault)
	-- Collapse near segments so they can't glow through.
	return 0.01 + (BEAM_WIDTH - 0.01) * u
end

local function emissionForPovDist(dist: number, nearClear: number, farDefault: number): number
	local u = povBlendU(dist, nearClear, farDefault)
	return 0 + 0.55 * u
end

local function isFishCamPovAttrOn(): boolean
	local plr = Players.LocalPlayer
	local pg = plr and plr:FindFirstChildOfClass("PlayerGui")
	return pg ~= nil and pg:GetAttribute(FreeCamConfig.ATTR_FISH_CAM_POV) == true
end

local function isPathTourPovAttrOn(): boolean
	local plr = Players.LocalPlayer
	local pg = plr and plr:FindFirstChildOfClass("PlayerGui")
	return pg ~= nil and pg:GetAttribute(FreeCamConfig.ATTR_PATH_TOUR_POV) == true
end

local function restoreBeamDefaultTransparency()
	for i, beam in ipairs(liveBeams) do
		if beam.Parent then
			beam.Transparency = NumberSequence.new(BEAM_TRANSPARENCY)
			beam.Width0 = BEAM_WIDTH
			beam.Width1 = BEAM_WIDTH
			beam.LightEmission = 0.55
			beam.Segments = 1
			if not hiddenByUi then
				beam.Enabled = true
			end
		end
		liveBeamLastT[i] = BEAM_TRANSPARENCY
	end
end

local function restoreRibbonBeamDefaults(beams: { Beam }, lastT: { number })
	for i, beam in ipairs(beams) do
		if beam.Parent then
			beam.Transparency = NumberSequence.new(BEAM_TRANSPARENCY)
			beam.Width0 = BEAM_WIDTH
			beam.Width1 = BEAM_WIDTH
			beam.LightEmission = 0.55
			beam.Segments = 1
			if not hiddenByUi then
				beam.Enabled = true
			end
		end
		lastT[i] = BEAM_TRANSPARENCY
	end
end

local function restoreSharkBeamDefaultTransparency()
	restoreRibbonBeamDefaults(sharkBeams, sharkBeamLastT)
end

local function restoreHostileBeamDefaultTransparency()
	restoreRibbonBeamDefaults(hostileBeams, hostileBeamLastT)
end

local function applyPovFadeToBeamList(
	beams: { Beam },
	points: { Vector3 },
	mids: { Vector3 },
	lastT: { number },
	nearClear: number,
	farDefault: number
)
	local cam = Workspace.CurrentCamera
	if not cam or #beams == 0 then
		return
	end
	local camPos = cam.CFrame.Position
	for i, beam in ipairs(beams) do
		if not beam.Parent then
			continue
		end
		-- Beams are built between points[i] → points[i+1].
		local p0 = points[i]
		local p1 = points[i + 1]
		local d0: number
		local d1: number
		if typeof(p0) == "Vector3" and typeof(p1) == "Vector3" then
			d0 = (p0 - camPos).Magnitude
			d1 = (p1 - camPos).Magnitude
		elseif mids[i] then
			d0 = (mids[i] - camPos).Magnitude
			d1 = d0
		else
			continue
		end
		local t0 = transparencyForPovDist(d0, nearClear, farDefault)
		local t1 = transparencyForPovDist(d1, nearClear, farDefault)
		local midT = (t0 + t1) * 0.5
		local prev = lastT[i]
		if typeof(prev) == "number" and math.abs(midT - prev) < POV_T_EPS then
			continue
		end
		beam.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, t0),
			NumberSequenceKeypoint.new(1, t1),
		})
		beam.Width0 = widthForPovDist(d0, nearClear, farDefault)
		beam.Width1 = widthForPovDist(d1, nearClear, farDefault)
		beam.LightEmission = emissionForPovDist((d0 + d1) * 0.5, nearClear, farDefault)
		beam.Segments = 6
		-- Fully hide segments that are essentially invisible.
		if not hiddenByUi then
			beam.Enabled = midT < 0.97
		end
		lastT[i] = midT
	end
end

local function applyPovFadeToBeams()
	-- Fish Cam POV: keep the original 10→90 band.
	applyPovFadeToBeamList(liveBeams, livePoints, liveBeamMids, liveBeamLastT, POV_NEAR_CLEAR_STUDS, POV_FAR_DEFAULT_STUDS)
end

local function applyPovFadeToTourRibbons()
	-- Shark + urchin tours: same fade curve, visible a little closer to cam.
	applyPovFadeToBeamList(
		sharkBeams,
		sharkPoints,
		sharkBeamMids,
		sharkBeamLastT,
		TOUR_POV_NEAR_CLEAR_STUDS,
		TOUR_POV_FAR_DEFAULT_STUDS
	)
	applyPovFadeToBeamList(
		hostileBeams,
		hostilePoints,
		hostileBeamMids,
		hostileBeamLastT,
		TOUR_POV_NEAR_CLEAR_STUDS,
		TOUR_POV_FAR_DEFAULT_STUDS
	)
end

local function ensurePovFadeWatcher()
	if povFadeConn then
		return
	end
	-- Always watch: attr can flip while the ribbon already exists.
	povFadeConn = RunService.RenderStepped:Connect(function()
		local wantFish = isFishCamPovAttrOn()
		if wantFish then
			povFadeOn = true
			applyPovFadeToBeams()
		elseif povFadeOn then
			povFadeOn = false
			restoreBeamDefaultTransparency()
		end
		local wantTour = isPathTourPovAttrOn()
		if wantTour then
			tourPovFadeOn = true
			applyPovFadeToTourRibbons()
		elseif tourPovFadeOn then
			tourPovFadeOn = false
			restoreSharkBeamDefaultTransparency()
			restoreHostileBeamDefaultTransparency()
		end
	end)
end

local function setPovFadeActive(on: boolean)
	ensurePovFadeWatcher()
	local want = on == true
	if want then
		povFadeOn = true
		applyPovFadeToBeams()
	elseif povFadeOn then
		povFadeOn = false
		restoreBeamDefaultTransparency()
	end
end

local function setTourPovFadeActive(on: boolean)
	ensurePovFadeWatcher()
	local want = on == true
	if want then
		tourPovFadeOn = true
		applyPovFadeToTourRibbons()
	elseif tourPovFadeOn then
		tourPovFadeOn = false
		restoreSharkBeamDefaultTransparency()
		restoreHostileBeamDefaultTransparency()
	end
end

syncPovFadeFromAttr = function()
	ensurePovFadeWatcher()
	setPovFadeActive(isFishCamPovAttrOn())
	setTourPovFadeActive(isPathTourPovAttrOn())
end

local function clearSharkPovCache()
	table.clear(sharkPoints)
	table.clear(sharkBeams)
	table.clear(sharkBeamMids)
	table.clear(sharkBeamLastT)
end

local function clearHostilePovCache()
	table.clear(hostilePoints)
	table.clear(hostileBeams)
	table.clear(hostileBeamMids)
	table.clear(hostileBeamLastT)
end

local function clearTourRibbonCaches()
	clearSharkPovCache()
	clearHostilePovCache()
	tourPovFadeOn = false
end

local function clearGroundRibbons()
	for _, container in ipairs(groundContainers) do
		if container.Parent then
			container:Destroy()
		end
	end
	table.clear(groundContainers)
	table.clear(groundBeams)
	clearTourRibbonCaches()
end

function WavePathLines.destroy()
	cancelInkReveal()
	inkCompleted = false
	inkSkipSettled = false
	povFadeOn = false
	tourPovFadeOn = false
	if povFadeConn then
		povFadeConn:Disconnect()
		povFadeConn = nil
	end
	restoreBeamDefaultTransparency()
	restoreSharkBeamDefaultTransparency()
	restoreHostileBeamDefaultTransparency()
	clearTourRibbonCaches()
	clearLiveCache()
	clearGroundRibbons()
	if linesFolder and linesFolder.Parent then
		linesFolder:Destroy()
	end
	linesFolder = nil
	local orphan = Workspace:FindFirstChild(FOLDER_NAME)
	if orphan then
		orphan:Destroy()
	end
end

local function durationForStage(minSec: number, maxSec: number): number
	local stage = 1
	local h = host
	if h and h.getPlotSizeStage then
		stage = h.getPlotSizeStage()
	end
	local s = SkillStages.clampStage(stage)
	local minS = SkillStages.MIN_STAGE
	local maxS = SkillStages.MAX_STAGE
	if maxS <= minS then
		return minSec
	end
	return minSec + (s - minS) / (maxS - minS) * (maxSec - minSec)
end

local function inkDurationForStage(): number
	return durationForStage(INK_DUR_MIN, INK_DUR_MAX)
end

local function fishTravelDurationForStage(): number
	return durationForStage(FISH_TRAVEL_MIN, FISH_TRAVEL_MAX)
end

local function joinIntroBusy(): boolean
	local lp = Players.LocalPlayer
	local pg = lp and lp:FindFirstChildOfClass("PlayerGui")
	return pg ~= nil and pg:GetAttribute("OceanTD_JoinIntroBusy") == true
end

local function ensureTipHead(anchors: BasePart)
	if tipBeam and tipBeam.Parent and tipAtt0 and tipAtt0.Parent and tipAtt1 and tipAtt1.Parent then
		return
	end
	destroyTipHead()
	local a0 = Instance.new("Attachment")
	a0.Name = "InkTip0"
	a0.Parent = anchors
	local a1 = Instance.new("Attachment")
	a1.Name = "InkTip1"
	a1.Parent = anchors
	local beam = Instance.new("Beam")
	beam.Name = "InkTipHead"
	beam.Attachment0 = a0
	beam.Attachment1 = a1
	beam.Color = ColorSequence.new(TIP_GREEN)
	beam.Width0 = TIP_WIDTH * 0.5
	beam.Width1 = TIP_WIDTH
	beam.FaceCamera = true
	beam.Segments = 1
	beam.LightEmission = TIP_EMISSION
	beam.LightInfluence = 0
	beam.Transparency = NumberSequence.new(TIP_TRANSPARENCY)
	beam.Enabled = false
	beam.Parent = anchors
	tipAtt0 = a0
	tipAtt1 = a1
	tipBeam = beam
end

local function updateTipHead(path: PathLike, len: number, h: Host)
	local anchors = liveAnchors
	if not anchors or not anchors.Parent or len < 0.5 or hiddenByUi then
		if tipBeam then
			tipBeam.Enabled = false
		end
		return
	end
	ensureTipHead(anchors)
	local a0 = tipAtt0
	local a1 = tipAtt1
	local beam = tipBeam
	if not a0 or not a1 or not beam then
		return
	end
	local headStart = math.max(0, len - TIP_HEAD_STUDS)
	local p0 = h.sampleFishPath(path, headStart)
	local p1 = h.sampleFishPath(path, len)
	a0.Position = p0
	a1.Position = p1
	beam.Enabled = true
end

local function samplePolyline(
	totalLen: number,
	sampleAt: (number) -> Vector3
): { Vector3 }
	local points: { Vector3 } = {}
	if totalLen < 0.5 then
		return points
	end
	local n = math.max(2, math.ceil(totalLen / SAMPLE_STEP) + 1)
	for i = 0, n - 1 do
		local d = (i / (n - 1)) * totalLen
		-- sampleFishPath returns (pos, tangent); parens keep only pos for insert.
		table.insert(points, (sampleAt(d)))
	end
	return points
end

applyBeamEnabled = function(enabled: boolean)
	local folder = linesFolder
	if not folder or not folder.Parent then
		return
	end
	for _, child in ipairs(folder:GetDescendants()) do
		if child:IsA("Beam") then
			child.Enabled = enabled
		end
	end
end

local function buildPolylineFromPoints(points: { Vector3 }, path: PathLike?)
	local folder = ensureFolder()
	-- Keep HostileGround* ribbons; only replace the green fish container.
	local priorFriendly = folder:FindFirstChild("FriendlyFish")
	if priorFriendly then
		priorFriendly:Destroy()
	end
	clearLiveCache()
	if #points < 2 then
		return
	end

	local container = Instance.new("Folder")
	container.Name = "FriendlyFish"
	container.Parent = folder

	local anchors = Instance.new("Part")
	anchors.Name = "Anchors"
	anchors.Anchored = true
	anchors.CanCollide = false
	anchors.CanQuery = false
	anchors.CanTouch = false
	anchors.CastShadow = false
	anchors.Transparency = 1
	anchors.Size = Vector3.new(0.05, 0.05, 0.05)
	anchors.CFrame = CFrame.new()
	anchors.Parent = container
	liveAnchors = anchors
	livePath = path

	local prevAtt: Attachment? = nil
	local prevPos: Vector3? = nil
	for i, worldPos in ipairs(points) do
		local att = Instance.new("Attachment")
		att.Name = "P" .. tostring(i)
		att.Position = worldPos
		att.Parent = anchors
		table.insert(livePoints, worldPos)
		table.insert(liveAtts, att)
		if prevAtt and prevPos then
			local beam = Instance.new("Beam")
			beam.Name = "Seg" .. tostring(i - 1)
			beam.Attachment0 = prevAtt
			beam.Attachment1 = att
			beam.Color = ColorSequence.new(GREEN)
			beam.Width0 = BEAM_WIDTH
			beam.Width1 = BEAM_WIDTH
			beam.FaceCamera = true
			beam.Segments = 1
			beam.LightEmission = 0.55
			beam.LightInfluence = 0
			beam.Transparency = NumberSequence.new(BEAM_TRANSPARENCY)
			beam.Enabled = not hiddenByUi
			beam.Parent = anchors
			table.insert(liveBeams, beam)
			table.insert(liveBeamMids, (prevPos + worldPos) * 0.5)
			table.insert(liveBeamLastT, BEAM_TRANSPARENCY)
		end
		prevAtt = att
		prevPos = worldPos
	end
	-- Path may rebuild while POV is already on — re-sync attr and apply fade.
	syncPovFadeFromAttr()
	if povFadeOn then
		applyPovFadeToBeams()
	end
end

local function buildGroundRibbonFromPoints(points: { Vector3 }, name: string, color: Color3?, yLift: number?)
	if #points < 2 then
		return
	end
	local folder = ensureFolder()
	local container = Instance.new("Folder")
	container.Name = name
	container.Parent = folder
	table.insert(groundContainers, container)

	local anchors = Instance.new("Part")
	anchors.Name = "Anchors"
	anchors.Anchored = true
	anchors.CanCollide = false
	anchors.CanQuery = false
	anchors.CanTouch = false
	anchors.CastShadow = false
	anchors.Transparency = 1
	anchors.Size = Vector3.new(0.05, 0.05, 0.05)
	anchors.CFrame = CFrame.new()
	anchors.Parent = container

	local lift = Vector3.new(0, if typeof(yLift) == "number" then yLift :: number else GROUND_Y_LIFT, 0)
	local beamColor = color or RED
	local trackShark = name == "SharkRoute"
	local trackHostile = name == "HostileGround" or string.sub(name, 1, 14) == "HostileGround_"
	if trackShark then
		clearSharkPovCache()
	elseif name == "HostileGround" then
		-- Single live-wave ribbon. Build-mode HostileGround_N appends without wiping peers.
		clearHostilePovCache()
	end
	local prevAtt: Attachment? = nil
	local prevPos: Vector3? = nil
	for i, worldPos in ipairs(points) do
		local lifted = worldPos + lift
		local att = Instance.new("Attachment")
		att.Name = "P" .. tostring(i)
		att.Position = lifted
		att.Parent = anchors
		if trackShark then
			table.insert(sharkPoints, lifted)
		elseif trackHostile then
			table.insert(hostilePoints, lifted)
		end
		if prevAtt and prevPos then
			local beam = Instance.new("Beam")
			beam.Name = "Seg" .. tostring(i - 1)
			beam.Attachment0 = prevAtt
			beam.Attachment1 = att
			beam.Color = ColorSequence.new(beamColor)
			beam.Width0 = BEAM_WIDTH
			beam.Width1 = BEAM_WIDTH
			beam.FaceCamera = true
			beam.Segments = 1
			beam.LightEmission = 0.55
			beam.LightInfluence = 0
			beam.Transparency = NumberSequence.new(BEAM_TRANSPARENCY)
			beam.Enabled = not hiddenByUi
			beam.Parent = anchors
			table.insert(groundBeams, beam)
			if trackShark then
				table.insert(sharkBeams, beam)
				table.insert(sharkBeamMids, (prevPos + lifted) * 0.5)
				table.insert(sharkBeamLastT, BEAM_TRANSPARENCY)
			elseif trackHostile then
				table.insert(hostileBeams, beam)
				table.insert(hostileBeamMids, (prevPos + lifted) * 0.5)
				table.insert(hostileBeamLastT, BEAM_TRANSPARENCY)
			end
		end
		prevAtt = att
		prevPos = lifted
	end
	if (trackShark or trackHostile) and (tourPovFadeOn or isPathTourPovAttrOn()) then
		tourPovFadeOn = true
		applyPovFadeToTourRibbons()
	end
end

--[[
	Show/hide red GroundA/B ribbons for waves that include crabs or urchins,
	plus the shark route ribbon on shark waves.
	One ground ribbon at a time when multiple routes are cycling (getHostileDisplayPath).
]]
function WavePathLines.syncHostilePaths()
	clearGroundRibbons()
	if hiddenByUi or joinIntroBusy() then
		return
	end
	local h = host
	if not h then
		return
	end
	if h.waveShowsHostilePaths and h.waveShowsHostilePaths() == true then
		local sampleFn = h.sampleGroundPath or h.sampleFishPath
		-- Live wave: one cycling display path. Build preview: all GroundA/B routes.
		local display = if h.getHostileDisplayPath then h.getHostileDisplayPath() else nil
		if display and display.totalLen > 0.5 then
			local points = samplePolyline(display.totalLen, function(d)
				return sampleFn(display, d)
			end)
			buildGroundRibbonFromPoints(points, "HostileGround", RED, GROUND_Y_LIFT)
		elseif h.getGroundPaths then
			local paths = h.getGroundPaths()
			if typeof(paths) == "table" then
				for i, path in ipairs(paths) do
					if path and path.totalLen > 0.5 then
						local points = samplePolyline(path.totalLen, function(d)
							return sampleFn(path, d)
						end)
						buildGroundRibbonFromPoints(points, "HostileGround_" .. tostring(i), RED, GROUND_Y_LIFT)
					end
				end
			end
		end
	end
	if h.waveShowsSharkPath and h.waveShowsSharkPath() == true and h.getSharkPath and h.sampleSharkPath then
		local sharkPath = h.getSharkPath()
		if sharkPath and sharkPath.totalLen > 0.5 then
			local sampleFn = h.sampleSharkPath
			local points = samplePolyline(sharkPath.totalLen, function(d)
				local pos = sampleFn(sharkPath, d)
				return pos
			end)
			buildGroundRibbonFromPoints(points, "SharkRoute", SHARK_ORANGE, SHARK_Y_LIFT)
		end
	end
end

paintFullPathIfPossible = function(): boolean
	local h = host
	local path = h and h.getFishPath()
	if not path or path.totalLen <= 0.5 then
		return false
	end
	local points = samplePolyline(path.totalLen, function(d)
		return h.sampleFishPath(path, d)
	end)
	buildPolylineFromPoints(points, path)
	inkDrawLen = path.totalLen
	return true
end

function WavePathLines.rebuild()
	-- Never abort a live ink reveal (HUD restore / SkillPowerUp route rebuild used to
	-- cancel mid-draw and leave the heart/orb stuck shrunk or skipped).
	if inkActive then
		return
	end
	-- Skip already snapped the finished intro path — always refresh full ribbon (never keep a half-draw).
	if inkSkipSettled then
		paintFullPathIfPossible()
		applyBeamEnabled(not hiddenByUi)
		WavePathLines.syncHostilePaths()
		return
	end
	cancelInkReveal()
	-- Intro owns first paint via ink reveal after the plot-cam handoff.
	if joinIntroBusy() then
		WavePathLines.destroy()
		return
	end
	local h = host
	if not h then
		return
	end
	local path = h.getFishPath()
	if not path or path.totalLen <= 0.5 then
		local folder = ensureFolder()
		local priorFriendly = folder:FindFirstChild("FriendlyFish")
		if priorFriendly then
			priorFriendly:Destroy()
		end
		clearLiveCache()
		WavePathLines.syncHostilePaths()
		return
	end
	local points = samplePolyline(path.totalLen, function(d)
		local pos = h.sampleFishPath(path, d)
		return pos
	end)
	buildPolylineFromPoints(points, path)
	inkCompleted = true
	WavePathLines.syncHostilePaths()
end

function WavePathLines.isRevealing(): boolean
	return inkActive
end

function WavePathLines.hasRibbon(): boolean
	return liveAnchors ~= nil and liveAnchors.Parent ~= nil and #liveBeams > 0
end

--[[
	Draw-on / ink trail: tip advances W1 → heart; finished stretch stays solid green;
	tip carries a short bright head. Cancels any prior reveal.
]]
function WavePathLines.playInkReveal(durationSec: number?)
	-- Don't restart a live draw (JoinIntro + planning both call this).
	if inkActive then
		return
	end
	-- Skip Intro (or a prior complete): never re-run the cinematic draw — keep/repair full ribbon.
	if inkSkipSettled or inkCompleted then
		paintFullPathIfPossible()
		applyBeamEnabled(not hiddenByUi)
		pcall(function()
			WaveEndVfx.ensureHeartVisibleAfterInk()
		end)
		revealDoneEvent:Fire()
		return
	end

	local h = host
	if not h then
		return
	end
	local path = h.getFishPath()
	if not path or path.totalLen <= 0.5 then
		pcall(function()
			WaveEndVfx.ensureHeartVisibleAfterInk()
		end)
		return
	end

	inkToken += 1
	local my = inkToken
	inkActive = true
	inkCompleted = false
	inkSkipSettled = false
	inkIfYouDontVoDone = false
	inkDrawLen = 0

	local fullLen = path.totalLen
	local dur = if typeof(durationSec) == "number" and durationSec > 0
		then durationSec
		else inkDurationForStage()

	-- Heart stays gone until after the line finishes drawing.
	pcall(function()
		WaveEndVfx.prepareHeartShrunkForInkReveal()
	end)

	-- Full polyline structure, tip at start (nothing visible yet).
	WavePathLines.rebuildForPath(path, 0)
	destroyTipHead()
	destroyInkEmojis()

	task.spawn(function()
		-- Narrator: green-line clip when ink starts; next clip when that VO ends.
		pcall(function()
			TutorialVo.play(INK_PATH_VO_ID, "OceanTD_JoinIntroInkPath", {
				onEnded = function()
					if my ~= inkToken then
						return
					end
					TutorialVo.play(INK_AFTER_PATH_VO_ID, "OceanTD_JoinIntroInkAfter", {
						onEnded = function()
							if my ~= inkToken then
								return
							end
							TutorialVo.play(IF_YOU_DONT_VO_ID, "OceanTD_JoinIntroIfYouDont", {
								onEnded = function()
									if my == inkToken then
										inkIfYouDontVoDone = true
									end
								end,
							})
						end,
					})
				end,
			})
		end)

		-- 1) Introduce the path — green ink only (no fish yet).
		local t0 = os.clock()
		while my == inkToken do
			local u = (os.clock() - t0) / dur
			if u >= 1 then
				break
			end
			local e = 1 - (1 - u) ^ 3
			local len = fullLen * e
			inkDrawLen = len
			WavePathLines.rebuildForPath(path, len)
			updateTipHead(path, len, h)
			RunService.RenderStepped:Wait()
		end
		if my ~= inkToken then
			return
		end
		inkDrawLen = fullLen
		WavePathLines.rebuildForPath(path, fullLen)
		updateTipHead(path, fullLen, h)
		local endPos = path.endPos or h.sampleFishPath(path, fullLen)

		-- 2) Introduce the heart — scale-up + both heartbeat sounds must finish.
		local heartOk = false
		pcall(function()
			heartOk = WaveEndVfx.playHeartScaleInFromInkAndWait(HEART_POP_SEC) == true
		end)
		if my ~= inkToken then
			return
		end
		if not heartOk then
			pcall(function()
				WaveEndVfx.ensureHeartVisibleAfterInk()
			end)
		end

		-- 3) Introduce the fish — example corals feed it the whole travel.
		pcall(function()
			JoinIntroExampleCorals.beginFeeding()
		end)
		local travelDur = fishTravelDurationForStage()
		local tFish = os.clock()
		-- 🍴 rating scale-up starts 1s before the lead fish arrives; trail finishes 2.5s later.
		local ratingLeadSec = 1
		local ratingFinished = false
		local fishCamStarted = false
		local startPos = h.sampleFishPath(path, 0)
		local latestFishTip = startPos
		task.spawn(function()
			local wakeAt = tFish + math.max(0, travelDur - ratingLeadSec)
			while os.clock() < wakeAt and my == inkToken do
				task.wait()
			end
			if my ~= inkToken then
				ratingFinished = true
				return
			end
			-- Rating starts while trail fish still walks; examples stay until trail finishes.
			playEndRatingEmojis(endPos, my)
			ratingFinished = true
		end)
		local fishPhaseDur = travelDur + TIP_FISH_TRAIL_LAG_SEC
		while my == inkToken do
			local elapsed = os.clock() - tFish
			if elapsed >= fishPhaseDur then
				break
			end
			local uLead = math.clamp(elapsed / travelDur, 0, 1)
			-- Trail only appears once it starts moving (2.5s behind the lead) — never parked at W1.
			local uTrail = math.clamp((elapsed - TIP_FISH_TRAIL_LAG_SEC) / travelDur, 0, 1)
			local trailVisible = elapsed >= TIP_FISH_TRAIL_LAG_SEC
			-- Linear along path length so speed stays even (waypoints are uneven in world space).
			local tipPos = h.sampleFishPath(path, fullLen * uLead)
			local trailPos = if trailVisible then h.sampleFishPath(path, fullLen * uTrail) else startPos
			latestFishTip = tipPos
			-- Lead full by 75% of path; trail half-full at heart (and flashes red last 40%).
			updateTipFishEmojis(
				tipPos,
				uLead,
				math.clamp(uLead / TIP_LEAD_FULL_AT_U, 0, 1),
				trailPos,
				uTrail,
				uTrail * TIP_TRAIL_FILL_AT_HEART,
				trailVisible
			)
			if not fishCamStarted then
				fishCamStarted = true
				-- Zoom into the sample reef / coral while food orbs fly to the fish emoji.
				pcall(function()
					local ClientPlot = require(script.Parent:WaitForChild("ClientPlot"))
					local plot = ClientPlot.get()
					local focus = if plot then plot.cframe.Position else tipPos
					local IntroCamPunch = require(script.Parent:WaitForChild("IntroCamPunch"))
					local punch = IntroCamPunch.beginHold(focus, 0.38, 0.4, { freezeFocus = true })
					if punch then
						task.delay(2.2 + 0.4, function()
							punch.release(0.5)
						end)
					end
				end)
			end
			-- Example corals keep shooting orbs at the lead while it travels.
			if uLead < 1 then
				pcall(function()
					JoinIntroExampleCorals.feedToward(tipPos)
				end)
			end
			RunService.RenderStepped:Wait()
		end
		if my ~= inkToken then
			pcall(function()
				JoinIntroExampleCorals.clear()
			end)
			return
		end
		-- Trail fish reached the heart — fade examples now (not when rating started).
		task.spawn(function()
			pcall(function()
				JoinIntroExampleCorals.scaleOutAndClear()
			end)
		end)
		updateTipFishEmojis(endPos, 1, 1, endPos, 1, TIP_TRAIL_FILL_AT_HEART, false)
		destroyTipFishEmojis()
		-- Rating / GAME OVER / roll VO: revealDone already fired when roll VO started.
		while not ratingFinished and my == inkToken do
			RunService.RenderStepped:Wait()
		end
		if my ~= inkToken then
			return
		end
		destroyTipHead()
		destroyInkEmojis()
		inkActive = false
		inkCompleted = true
		pcall(function()
			WaveEndVfx.ensureHeartVisibleAfterInk()
		end)
		task.delay(0.6, function()
			if my ~= inkToken then
				return
			end
			pcall(function()
				WaveEndVfx.ensureHeartVisibleAfterInk()
			end)
		end)
	end)
end

-- JoinIntro waits on this before dropping the player's real reef + roll finger.
function WavePathLines.waitRevealComplete(timeoutSec: number?): boolean
	if inkCompleted and not inkActive then
		return true
	end
	local timeout = if typeof(timeoutSec) == "number" then timeoutSec else 120
	local done = false
	local conn = revealDoneEvent.Event:Connect(function()
		done = true
	end)
	local deadline = os.clock() + timeout
	while not done and os.clock() < deadline do
		if inkCompleted and not inkActive then
			done = true
			break
		end
		task.wait(0.05)
	end
	conn:Disconnect()
	return done
end

-- First paint after intro / planning: ink once; later callers leave the ribbon alone.
function WavePathLines.ensureInkReveal(durationSec: number?)
	if inkActive then
		return
	end
	-- After Skip Intro / completed reveal: keep the finished ribbon; never animate again.
	if inkSkipSettled or inkCompleted then
		paintFullPathIfPossible()
		applyBeamEnabled(not hiddenByUi)
		pcall(function()
			WaveEndVfx.ensureHeartVisibleAfterInk()
		end)
		revealDoneEvent:Fire()
		return
	end
	WavePathLines.playInkReveal(durationSec)
end

--[[
	Draw `path` only up to `drawLen` (studs along route). Builds the full path once,
	then trims beam visibility + tip each frame so the ribbon tracks a tweening heart.
]]
function WavePathLines.rebuildForPath(path: PathLike?, drawLen: number?)
	-- Allow in-flight ink after Busy clears; block other draws while intro is up.
	if inkSkipSettled then
		return
	end
	if joinIntroBusy() and not inkActive then
		return
	end
	local tokenAtStart = inkToken
	local h = host
	if not h or not path or path.totalLen <= 0.5 then
		return
	end
	local fullLen = path.totalLen
	local len = math.clamp(if typeof(drawLen) == "number" then drawLen else fullLen, 0, fullLen)

	-- First call (or path changed): sample the entire route so we can grow into it.
	if livePath ~= path or not liveAnchors or not liveAnchors.Parent or #liveAtts < 2 then
		local points = samplePolyline(fullLen, function(d)
			local pos = h.sampleFishPath(path, d)
			return pos
		end)
		buildPolylineFromPoints(points, path)
	end

	-- Skip / cancel may have replaced the ribbon while we were sampling — don't re-trim it.
	if tokenAtStart ~= inkToken or inkSkipSettled or (joinIntroBusy() and not inkActive) then
		return
	end

	local n = #liveAtts
	if n < 2 or #liveBeams < 1 then
		return
	end
	if len < 0.5 then
		for _, beam in ipairs(liveBeams) do
			beam.Enabled = false
		end
		return
	end

	-- Map drawLen → attachment index; put the tip exactly at sample(drawLen).
	local tipIdx = math.max(2, math.floor((len / fullLen) * (n - 1) + 1.5))
	tipIdx = math.clamp(tipIdx, 2, n)
	local tipPos = h.sampleFishPath(path, len)
	-- Restore joints behind the tip to authored samples, then park the tip.
	for i = 1, tipIdx - 1 do
		liveAtts[i].Position = livePoints[i]
	end
	liveAtts[tipIdx].Position = tipPos
	for i = tipIdx + 1, n do
		liveAtts[i].Position = tipPos
	end
	for i, beam in ipairs(liveBeams) do
		beam.Enabled = (not hiddenByUi) and (i < tipIdx)
	end
end

-- Hide UI: false = show ribbons (default). true = hide.
function WavePathLines.setVisible(visible: boolean)
	hiddenByUi = visible ~= true
	local function finishHostileVisibility()
		if hiddenByUi then
			clearGroundRibbons()
		else
			WavePathLines.syncHostilePaths()
		end
	end
	local folder = linesFolder
	if not folder or not folder.Parent then
		if visible and not hiddenByUi then
			if inkSkipSettled or inkCompleted then
				paintFullPathIfPossible()
				applyBeamEnabled(true)
			else
				WavePathLines.ensureInkReveal()
			end
		end
		finishHostileVisibility()
		return
	end
	-- Skip settled: never re-apply a partial ink trim when toggling visibility.
	if inkSkipSettled then
		if visible and not hiddenByUi and not WavePathLines.hasRibbon() then
			paintFullPathIfPossible()
		end
		applyBeamEnabled(not hiddenByUi)
		finishHostileVisibility()
		return
	end
	if inkActive and livePath then
		local h = host
		WavePathLines.rebuildForPath(livePath, inkDrawLen)
		if h then
			updateTipHead(livePath, inkDrawLen, h)
		end
		finishHostileVisibility()
		return
	end
	applyBeamEnabled(not hiddenByUi)
	if hiddenByUi and tipBeam then
		tipBeam.Enabled = false
	end
	finishHostileVisibility()
end

function WavePathLines.isHiddenByUi(): boolean
	return hiddenByUi
end

return WavePathLines
