--!strict
--[[
	Client feed-wave simulation. Fish stay local. Visitors rebuild them from the shared wave seed.
	Path/flight math lives in WaveSimPath; coverage/stock in WaveSimCoralBuckets.
	Ammo/shots/lane feed → Feed table; hunger billboards → HungerUi.
	Quiet requires → WaveSimLibs (keeps module under Luau's 200 top-level locals).
	FEED_MODE: "lane_stock" (Option 2, static nest food, no fire) | "volleys" | "path_fields".
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local L = require(script.Parent:WaitForChild("WaveSimLibs"))
local ClientPlot = require(script.Parent:WaitForChild("ClientPlot"))
local WaveEntityPool = require(script.Parent:WaitForChild("WaveEntityPool"))
local WaveCrab = require(script.Parent:WaitForChild("WaveCrab"))
local WaveUrchin = require(script.Parent:WaitForChild("WaveUrchin"))
local WaveShark = require(script.Parent:WaitForChild("WaveShark"))

local WaveSim = {}

local WaveSimConsts = require(script.Parent:WaitForChild("WaveSimConsts"))
local Path = require(script.Parent:WaitForChild("WaveSimPath"))
local CoralBuckets = require(script.Parent:WaitForChild("WaveSimCoralBuckets"))
local HandOrb = require(script.Parent:WaitForChild("HandOrb"))
local C = WaveSimConsts

local feedSound = Instance.new("Sound")
feedSound.Name = "OceanTD_FeedHit"
feedSound.SoundId = C.FEED_SOUND_ID
feedSound.Volume = 0.85
feedSound.Parent = L.SoundService

local tapFeedFireSound = Instance.new("Sound")
tapFeedFireSound.Name = "OceanTD_TapFeedFire"
tapFeedFireSound.SoundId = C.TAP_FEED_FIRE_SOUND_ID or "rbxassetid://5852470908"
tapFeedFireSound.Volume = 0.9
tapFeedFireSound.Parent = L.SoundService

task.defer(function()
	pcall(function()
		L.ContentProvider:PreloadAsync({ feedSound, tapFeedFireSound })
	end)
end)


export type Summary = {
	waveReached: number,
	fishFed: number,
	elapsedSec: number,
	defeated: boolean?,
	defeatOrigin: Vector3?,
}

export type HudSnapshot = {
	wave: number,
	reefHealth: number,
	reefMax: number,
	elapsedSec: number,
	running: boolean,
	feedProgress: number, -- 0..1 hunger filled this wave
	feedComplete: boolean, -- no hungry agents left on field; NEXT WAVE / early finish available
	hungerDanger: boolean, -- any hungry fish bar flashing red near route end
	hungryMissToken: number, -- bumps when a hungry fish reaches the end (broken heart)
	fishFull: number, -- fully-fed fish this wave (alive + finished happy)
	fishTotal: number, -- fish expected this wave
	crabTotal: number, -- crabs rolled for this wave
	urchinTotal: number, -- urchins on ×5 waves
	sharkTotal: number, -- sharks on ×10 waves (0 or 1)
	speedMult: number,
}

type PathSegment = Path.PathSegment
type PathData = Path.PathData

type FishAgent = {
	id: number,
	root: BasePart,
	model: Instance,
	dist: number,
	lateral: number,
	vert: number,
	bobAmp: number,
	bobFreq: number,
	bobPhase: number,
	wanderAmp: number,
	wanderFreq: number,
	wanderPhase: number,
	speedPhase: number,
	speedFreq: number,
	hunger: number,
	maxHunger: number,
	finished: boolean,
	billboard: BillboardGui,
	fill: Frame,
	barFrame: Frame,
	forkLabel: TextLabel,
	happyLabel: TextLabel,
	remainLabel: TextLabel,
	barScale: UIScale,
	barStroke: UIStroke?,
	pulseToken: number,
	dangerToken: number,
	dangerActive: boolean,
	tapStrokeToken: number,
	smoothTang: Vector3,
	lastWorld: Vector3,
	incomingFood: number, -- pending fill units from in-flight food orbs
	payoutDone: boolean, -- $D already reported for this fill
	fedCounted: boolean, -- counted toward this wave's feed bar / early-finish
	isCrab: boolean?,
	isUrchin: boolean?,
	isShark: boolean?,
	groundPath: WaveCrab.PathData?, -- GroundA or GroundB for crabs/urchins
	swimPath: PathData?, -- Tang: A or A2 (nil = primary pathData / A)
	crabAnim: any?,
	shellHitbox: BasePart?,
	-- Root-local offsets so ShellHitbox / mesh stay glued when RootPart teleports.
	shellLocalCf: CFrame?,
	bodyLocalCf: CFrame?,
	pauseUntil: number?,
	pauseDur: number?,
	stunSkullPart: BasePart?,
	crabSprint: any?,
	swayPhase: number?,
	tapDebugPart: BasePart?, -- TAP_FEED_DEBUG radius ball
	spawnClock: number?, -- shared-clock origin for closed-form distance
	bornAt: number?, -- os.clock when this critter appeared; feeding waits 1.5s
	visitSlot: number?, -- index in the shared spawn plan
}

type CoralAgent = {
	part: BasePart,
	color: Color3,
	reloadSec: number,
	foodFill: number,
	foodCount: number,
	range: number,
	rangeSq: number,
	defenseSec: number,
	diameter: number,
	-- Lifetime session stats (used by CoralInspectPanel while this client is running).
	fedTotal: number,
	wavesTotal: number,
	readyAt: number,
	ammo: BasePart?,
	ammoSlots: { BasePart },
	ammoSizeMult: number, -- 0.70..0.99 — each neon food is 1–30% smaller
	-- Cached local ammo nest offsets (rebuilt on create / size change, not every frame).
	ammoLocalOffs: { Vector3 }?,
	bubblePhase: { number }?, -- nest bubble stagger per ammo slot
	bubbleWasNear: boolean?, -- camera LOD for bubbles
	growing: boolean,
	growT0: number,
	-- Dirty visual flags: syncCorals only parks/looks when set (not every coral at 10 Hz).
	needsPark: boolean,
	needsLook: boolean,
	busy: boolean, -- projectile in flight
	shotsOut: number,
	pathDist: number, -- nearest distance along WaveRoute A
	pathSideDist: number, -- world distance from that path point
	pathBuckets: { number }, -- alias of routeBuckets[ROUTE_A] (Tang targeting)
	routeBuckets: { { number } }, -- C-stamp: buckets per route (A/A2/Shark/Ground)
	routeNearDist: { number }, -- nearest stamped sample dist per route
	combatScore: number, -- scratch: distance-to-front rank for fire budget
	combatGen: number, -- scratch: which collect pass marked this coral active
	stunned: boolean, -- crab ShellHitbox hit; white, no food until next wave
	lanePulseReady: boolean?, -- lane_stock: restocked; fire one food visual when a fish drinks
	rateShare: number?, -- path_fields: this nest's food/sec summed across slices
	ammoArmPending: boolean?, -- wave-start staggered nest arm; blocks syncCorals auto-create
}

type FoodShot = {
	part: BasePart?, -- nil = logic-only flight (8b sparse VFX)
	target: FishAgent?,
	fill: number,
	coral: CoralAgent?,
	alive: boolean,
	age: number,
	duration: number,
	startPos: Vector3,
	meetPos: Vector3,
	swayPhase: number,
	visualOnly: boolean?, -- lane_stock feedback: fly to fish, no hunger / nest consume
	playerTap: boolean?, -- manual click feed (no coral credit)
}


local running = false
local token = 0
local folder: Folder? = nil
local pathData: PathData? = nil
local pathDataA2: PathData? = nil
local pathDataGroundA: WaveCrab.PathData? = nil
local pathDataGroundB: WaveCrab.PathData? = nil
local pathDataShark: WaveCrab.PathData? = nil
-- Pre-assigned GroundA/B for this wave's crabs/urchins (unique set + spawn queue).
local hostilePreviewPaths: { WaveCrab.PathData } = {}
local hostilePathQueue: { WaveCrab.PathData } = {}
local hostileDisplayIndex = 1
local fishList: { FishAgent } = {}
local fishA2Remaining = 0
local waveUsesFishA2 = false
local critterHungerBarsVisible = true
local hideUiSuppressesCritterUi = false
-- Highest wave index reached this client session (build-mode path previews).
local sessionHighestWaveReached = 0
local coralList: { CoralAgent } = {}
-- XZ hash of non-stunned corals for crab/urchin stun (rebuilt when dirty).
local coralSpatial: WaveCrab.SpatialHash = {}
local coralSpatialDirty = true
local coralByRouteBucket = CoralBuckets.newRouteIndices()
local coralBucketsDirty = true
local routePaths: CoralBuckets.RoutePaths = {}
local combatCollectGen = 0
local lastOrbPrewarmSlots = 0
type CoralStats = {
	fed: number, -- fish fully fed (credited when they hit max hunger)
	waves: number, -- waves completed while this coral existed (session-only)
}
local coralStatsByPlaceId: { [string]: CoralStats } = {}
local fishPathBuckets: { { FishAgent } } = {}
local activeShots: { FoodShot } = {}
local visibleShotCount = 0 -- concurrent flying food Parts (≤ FOOD_VISIBLE_MAX)
-- Cached for food-visual cull gate (hot path); refreshed on PlacedCoralIndex changes.
local placedCoralCount = 0
-- Ammo / shots / lane feed + hunger UI live on tables so WaveSim stays under Luau's 200 locals.
local Feed = {}
local HungerUi = {}
-- Scratch for nest-ammo rise pulses (BulkMoveTo); stored on Feed to avoid extra module locals.
Feed._risePulses = {} :: { [any]: { t0: number, riseDur: number, holdDur: number } }
Feed._riseParts = {} :: { BasePart }
Feed._riseCFs = {} :: { CFrame }
Feed._riseDone = {} :: { any }
Feed._ammoArmQueue = {} :: { { coral: any, at: number } }
Feed._ammoFade = {} :: { [any]: { t0: number, dur: number } }
Feed._ammoFadeDone = {} :: { any }
Feed._orphanAmmoFades = {} :: { { parts: { BasePart }, t0: number, dur: number } }
Feed._orphanAmmoFadeConn = nil :: RBXScriptConnection?
Feed._orphanCritterFades = {} :: {
	{
		model: Instance,
		kind: string,
		parts: { BasePart },
		t0: number,
		dur: number,
	}
}
local JOIN_INTRO_AMMO_FADE_SEC = 1.5
local JOIN_INTRO_AMMO_FADE_SPREAD = 1.5
Feed._pathStampIndex = 0 -- 0 = idle; else next coralList index to stamp
-- Reused each combat tick for budgeted targeting (avoid alloc).
local combatReady: { CoralAgent } = {}
local combatFireCursor = 1
local spawnQueue = 0
local spawnDelay = 0
local crabSpawnQueue = 0
local crabSpawnDelay = 0
local urchinSpawnQueue = 0
local urchinSpawnDelay = 0
local waveIndex = 0
local reefMaxHealth = C.REEF_START_HEALTH
local reefHealth = C.REEF_START_HEALTH
-- Join-intro Wave-100 showcase (no reef damage, no summary, custom coral list).
local joinIntroDemo = false
-- Session one-shots for tutorial VO (ids live on WaveSimLibs).
local firstVoPlayed = { reefEmpty = false, urchin = false, crab = false, shark = false }
-- Session one-shots for train teach cams (wave-3 fish / crab focus / urchin+shark path tours).
local firstCamTeach = {
	wave3FishCam = false,
	crabFocus = false,
	urchinPathTour = false,
	sharkPathTour = false,
}

local function trainingCamTeachEnabled(): boolean
	if joinIntroDemo then
		return false
	end
	local pg = Players.LocalPlayer and Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if pg and pg:GetAttribute("OceanTD_FingerTutorialSkipped") == true then
		return false
	end
	return true
end
-- Wave-2 tutorial grant of Reload Speed stage 8 (session once; ends when wave 2 ends).
local wave2FullAutoTrialOffered = false
local wave2FullAutoTrialActive = false
local demoCoralParts: { BasePart }? = nil
-- Green fish-train before the player's first Start Waves this session (finger tutorial planning).
local hasStartedWavesThisSession = false
-- Counts real Start Waves presses; round-start SFX skips the first (explainer VO).
local wavesStartCount = 0
-- Retry/Continue: don't ForceFishCam / TangCam — restore the player's prior cam instead.
local suppressWaveStartCamForce = false
local planningArrows = false
local planningArrowConn: RBXScriptConnection? = nil

-- Sharks linger after wave clear and never gate wave completion.
local function isWaveLingerer(f: FishAgent): boolean
	return f.isShark == true
end

local function reefMaxFromSkills(): number
	return L.SkillStages.reefHealthAtStage(L.SkillPowerUpUI.getStage("RHealth"))
end

local fishFed = 0
local waveFishExpected = 0
local waveFishSpawned = 0 -- successfully spawned this wave (denominator once spawning ends)
local waveFishFullyFed = 0 -- fish that reached full hunger this wave (alive or finished happy)
local lastCoralWaveAwarded = 0
local startedAt = 0
local simClock = 0 -- advances with dt * speedMult (ammo/combat); HUD clock freezes while paused
local speedMult = 1 -- 1 | 1.5 | 2 | 0 (pause); session-only, player-controlled
local pauseWallT0: number? = nil -- wall clock when speed-pause began
local pausedWallAccum = 0 -- total wall time spent paused this run
local cinematicResumeSpeed: number? = nil -- speed to restore after intro cinematic pause
local PATH_TOUR_PLAY_SEC = 3 -- let the wave run before pausing into the path cam tour
local waveSpawning = false
local moveConn: RBXScriptConnection? = nil
local combatAcc = 0
local nextFishId = 1
local hudListeners: { (HudSnapshot) -> () } = {}
local stopListeners: { (Summary) -> () } = {}
local fishRng = Random.new()
local feedPitchCursor = C.FEED_PITCH_MIN
local stingReportAt: { [number]: number } = {}
local reportUrchinSting = L.Remotes.get("ReportUrchinSting")
local defeatBusy = false
local lastStopDefeated = false
local lastDefeatOrigin: Vector3? = nil

-- Indices 1–3 are play speeds; index 4 (0) is pause (stage 4 Wave Speed only).
local SPEED_STEPS = { 1, 1.5, 2, 0 }

local function wallElapsedSec(): number
	if not running then
		return 0
	end
	if pauseWallT0 then
		return math.max(0, pauseWallT0 - startedAt - pausedWallAccum)
	end
	return math.max(0, os.clock() - startedAt - pausedWallAccum)
end

local function applySpeedPauseState(nowPaused: boolean)
	if nowPaused then
		if not pauseWallT0 then
			pauseWallT0 = os.clock()
		end
		return
	end
	if pauseWallT0 then
		local dt = os.clock() - pauseWallT0
		pausedWallAccum += dt
		-- Fight timers use wall clock; shift so they don't expire during pause.
		for _, agent in ipairs(fishList) do
			local untilT = agent.pauseUntil
			if untilT then
				agent.pauseUntil = untilT + dt
			end
		end
		pauseWallT0 = nil
	end
end

local function resetSpeedState()
	speedMult = 1
	pauseWallT0 = nil
	pausedWallAccum = 0
	cinematicResumeSpeed = nil
end

-- Skip / next-wave while paused → resume at 1x.
local function resumeNormalSpeedIfPaused()
	if speedMult > 1e-6 then
		return
	end
	applySpeedPauseState(false)
	speedMult = 1
end

local hudDirty = false
local lastHudWave = -1
local lastHudReef = -1
local lastHudSec = -1
local lastHudFeed = -1
local lastHudFeedDone = false
local lastHudDanger = false
local lastHudMissToken = 0
local hungryMissToken = 0
local lastHudFishFull = -1

local function notifyHud()
	hudDirty = true
end

local function anyHungerDanger(): boolean
	for _, f in ipairs(fishList) do
		if not f.finished and f.dangerActive then
			return true
		end
	end
	return false
end

local function markCoralSpatialDirty()
	coralSpatialDirty = true
end

local function markCoralBucketsDirty()
	coralBucketsDirty = true
end

local function refreshRoutePaths()
	routePaths[CoralBuckets.ROUTE_A] = pathData
	routePaths[CoralBuckets.ROUTE_A2] = pathDataA2
	routePaths[CoralBuckets.ROUTE_SHARK] = pathDataShark
	routePaths[CoralBuckets.ROUTE_GROUND_A] = pathDataGroundA
	routePaths[CoralBuckets.ROUTE_GROUND_B] = pathDataGroundB
end

local function assignCoralPathBuckets(coral: CoralAgent)
	-- Build mode edits a lot of coral, then closes. Stamp once on close.
	if Feed._deferBucketRebuild then
		return
	end
	if not joinIntroDemo and L.InventoryState.isOpen() then
		Feed._deferBucketRebuild = true
		Feed._bucketsReady = false
		return
	end
	refreshRoutePaths()
	local path = pathData
	if path then
		local pd, side = Path.projectPointOntoPath(path, coral.part.Position)
		coral.pathDist = pd
		coral.pathSideDist = side
	else
		coral.pathDist = 0
		coral.pathSideDist = 0
	end
	local rb, rn = CoralBuckets.assignAllRoutes(coral.part.Position, coral.range, routePaths)
	coral.routeBuckets = rb
	coral.routeNearDist = rn
	coral.pathBuckets = rb[CoralBuckets.ROUTE_A] or {}
	markCoralBucketsDirty()
end

local function ensureCoralSpatialHash()
	if not coralSpatialDirty then
		return
	end
	coralSpatialDirty = false
	WaveCrab.spatialClear(coralSpatial)
	local cell = C.HASH_CELL
	for _, coral in ipairs(coralList) do
		if coral.stunned or not coral.part.Parent then
			continue
		end
		local p = coral.part.Position
		WaveCrab.spatialInsert(coralSpatial, cell, p.X, p.Z, coral)
	end
end

local function ensureCoralPathBucketIndex()
	if not coralBucketsDirty then
		return
	end
	coralBucketsDirty = false
	refreshRoutePaths()
	CoralBuckets.rebuildAllIndices(coralByRouteBucket, coralList, routePaths)
	if C.FEED_MODE == "path_fields" then
		Feed.applyRateGlow()
	end
end

local function resolveFeedRoute(f: FishAgent): number?
	if f.isShark then
		return CoralBuckets.ROUTE_SHARK
	end
	if Path.isGroundCritter(f) then
		if f.groundPath and pathDataGroundB and f.groundPath == pathDataGroundB then
			return CoralBuckets.ROUTE_GROUND_B
		end
		return CoralBuckets.ROUTE_GROUND_A
	end
	if f.swimPath and pathData and f.swimPath ~= pathData then
		return CoralBuckets.ROUTE_A2
	end
	return CoralBuckets.ROUTE_A
end

local function isOffSwimHungry(f: FishAgent): boolean
	return f.isShark == true or Path.isGroundCritter(f)
end

local function maybePrewarmOrbs(liveCount: number, force: boolean)
	-- path_fields: no nest orbs. lane_stock: static nest ammo only. volleys: ammo + flying food.
	if C.FEED_MODE == "path_fields" then
		return
	end
	local estSlots = liveCount * 4 -- catalog max food/nest
	if not force and estSlots <= lastOrbPrewarmSlots then
		return
	end
	lastOrbPrewarmSlots = math.max(lastOrbPrewarmSlots, estSlots)
	local foodCap = if C.FEED_MODE == "volleys"
		then math.min(WaveEntityPool.foodPoolCap(), math.max(64, liveCount))
		else 0
	WaveEntityPool.prewarmOrbs(
		math.min(WaveEntityPool.ammoPoolCap(), estSlots + 64),
		foodCap,
		C.FOOD_RADIUS
	)
end

local LifeStats = {}
do
	local remote: RemoteEvent? = nil
	local flushAt = 0
	local dirty = false

	local function readAttr(part: BasePart, name: string): number
		local a = part:GetAttribute(name)
		if typeof(a) == "number" then
			return math.max(0, math.floor(a))
		end
		if typeof(a) == "string" then
			return math.max(0, math.floor(tonumber(a) or 0))
		end
		return 0
	end

	function LifeStats.syncAttrs(part: BasePart, fed: number, waves: number)
		part:SetAttribute("OceanTD_CoralFedTotal", fed)
		part:SetAttribute("OceanTD_CoralWavesTotal", waves)
	end

	function LifeStats.readAttr(part: BasePart, name: string): number
		return readAttr(part, name)
	end

	function LifeStats.flush(force: boolean?)
		if not dirty and not force then
			return
		end
		local now = os.clock()
		if not force and now < flushAt then
			return
		end
		flushAt = now + 2.5
		dirty = false
		if not remote then
			local ok, ev = pcall(function()
				return L.Remotes.get("ReportCoralLifeStats")
			end)
			if ok and ev then
				remote = ev
			end
		end
		if not remote then
			return
		end
		local payload: { [string]: { fed: number, waves: number } } = {}
		local n = 0
		for pid, st in pairs(coralStatsByPlaceId) do
			payload[pid] = { fed = st.fed, waves = st.waves }
			n += 1
			if n >= 80 then
				break
			end
		end
		if n > 0 then
			remote:FireServer(payload)
		end
	end

	function LifeStats.bump(placeId: string, part: BasePart?, fedDelta: number, waveDelta: number)
		local st = coralStatsByPlaceId[placeId]
		if not st then
			st = { fed = 0, waves = 0 }
			coralStatsByPlaceId[placeId] = st
		end
		if fedDelta ~= 0 then
			st.fed = math.max(0, st.fed + fedDelta)
		end
		if waveDelta ~= 0 then
			st.waves = math.max(0, st.waves + waveDelta)
		end
		if part and part.Parent then
			LifeStats.syncAttrs(part, st.fed, st.waves)
		end
		dirty = true
		LifeStats.flush(false)
	end
end

local function creditCoralFeed(coral: CoralAgent?)
	if joinIntroDemo then
		return
	end
	if not coral or not coral.part.Parent then
		return
	end
	local pid = coral.part:GetAttribute("OceanTD_PlaceId")
	if typeof(pid) ~= "string" or pid == "" then
		return
	end
	LifeStats.bump(pid, coral.part, 1, 0)
	coral.fedTotal = coralStatsByPlaceId[pid].fed
end

local function markFishFullyFed(agent: FishAgent, fedBy: CoralAgent?)
	if agent.fedCounted then
		return
	end
	agent.fedCounted = true
	-- Sharks don't count toward wave feed progress (they don't gate waves).
	if not agent.isShark then
		waveFishFullyFed += 1
	end
	-- Fed counter is credited per successful feed delivery (creditCoralFeed), not only
	-- on the finishing fill — fedBy is unused for LifeStats.
	notifyHud()
end

local function awardCoralWaveCompleted(waveNum: number)
	-- Prevent double-awards when multiple "wave complete" paths converge.
	if waveNum <= lastCoralWaveAwarded then
		return
	end
	if joinIntroDemo then
		lastCoralWaveAwarded = waveNum
		return
	end
	lastCoralWaveAwarded = waveNum

	for _, coral in ipairs(coralList) do
		local part = coral.part
		if part.Parent then
			local pid = part:GetAttribute("OceanTD_PlaceId")
			if typeof(pid) == "string" and pid ~= "" then
				LifeStats.bump(pid, part, 0, 1)
				coral.wavesTotal = coralStatsByPlaceId[pid].waves
			end
		end
	end
	LifeStats.flush(true)
end

local function waveFishDenominator(): number
	-- After spawning finishes, use actual spawns so a failed acquire can't soft-lock the bar.
	if (not waveSpawning) and spawnQueue <= 0 then
		return math.max(1, waveFishSpawned)
	end
	return math.max(1, waveFishExpected)
end

local function waveProgressDenominator(): number
	local n = waveFishDenominator()
	if WaveCrab.shouldSpawn(waveIndex) and WaveCrab.anyGroundPath(pathDataGroundA, pathDataGroundB) then
		if (not waveSpawning) and spawnQueue <= 0 and crabSpawnQueue <= 0 and urchinSpawnQueue <= 0 then
			n += WaveCrab.spawnedCount()
		else
			n += WaveCrab.expectedCount()
		end
	end
	if WaveUrchin.shouldSpawn(waveIndex) and WaveCrab.anyGroundPath(pathDataGroundA, pathDataGroundB) then
		if (not waveSpawning) and spawnQueue <= 0 and crabSpawnQueue <= 0 and urchinSpawnQueue <= 0 then
			n += WaveUrchin.spawnedCount()
		else
			n += WaveUrchin.expectedCount()
		end
	end
	return math.max(1, n)
end

local function getFishFullCounts(): (number, number)
	return waveFishFullyFed, waveFishDenominator()
end

local function getFeedProgress(): (number, boolean)
	if not running or waveFishExpected <= 0 then
		return 0, false
	end
	local total = waveProgressDenominator()
	local filled = 0
	local anyHungryAlive = false
	local countedFull = 0
	for _, f in ipairs(fishList) do
		if f.finished then
			continue
		end
		-- A hungry shark blocks NEXT. A full shark may keep swimming.
		if f.isShark then
			if not f.fedCounted and f.hunger < f.maxHunger then
				anyHungryAlive = true
			end
			continue
		end
		local effective = f.hunger + f.incomingFood
		if f.hunger >= f.maxHunger or f.fedCounted then
			countedFull += 1
			filled += 1
			continue
		end
		anyHungryAlive = true
		-- Partial credit (incl. in-flight orbs) so the bar moves before a critter is fully fed.
		if f.maxHunger > 0 then
			filled += math.clamp(effective / f.maxHunger, 0, 0.999)
		end
	end
	-- Also count fully-fed critters that already left the list (fedCounted before destroy).
	if waveFishFullyFed > countedFull then
		filled += (waveFishFullyFed - countedFull)
	end
	local progress = math.clamp(filled / total, 0, 1)
	local spawningDone = (not waveSpawning)
		and spawnQueue <= 0
		and crabSpawnQueue <= 0
		and urchinSpawnQueue <= 0
		and L.WaveVisitPlan.remaining("host") <= 0
	local unitsSpawned = waveFishSpawned + WaveCrab.spawnedCount() + WaveUrchin.spawnedCount()
	-- NEXT WAVE when nothing hungry remains, including a shark that is not full yet.
	-- Hungry finishers already cost reef health — don't wait for a full urchin/crab
	-- to walk the rest of a long path, and don't require 100% feed bar.
	local complete = spawningDone and unitsSpawned > 0 and (not anyHungryAlive)
	return progress, complete
end

local function flushHud()
	local elapsed = wallElapsedSec()
	local sec = math.floor(elapsed)
	local feedProg, feedDone = getFeedProgress()
	local danger = anyHungerDanger()
	local fishFull, fishTotal = getFishFullCounts()
	local secTick = running and sec ~= lastHudSec
	if not hudDirty and not secTick then
		return
	end
	hudDirty = false
	if not secTick
		and running
		and waveIndex == lastHudWave
		and reefHealth == lastHudReef
		and math.abs(feedProg - lastHudFeed) < 0.002
		and feedDone == lastHudFeedDone
		and danger == lastHudDanger
		and hungryMissToken == lastHudMissToken
		and fishFull == lastHudFishFull
	then
		return
	end
	lastHudWave = waveIndex
	lastHudReef = reefHealth
	lastHudSec = sec
	lastHudFeed = feedProg
	lastHudFeedDone = feedDone
	lastHudDanger = danger
	lastHudMissToken = hungryMissToken
	lastHudFishFull = fishFull
	local snap: HudSnapshot = {
		wave = waveIndex,
		reefHealth = reefHealth,
		reefMax = reefMaxHealth,
		elapsedSec = elapsed,
		running = running,
		feedProgress = feedProg,
		feedComplete = feedDone,
		hungerDanger = danger,
		hungryMissToken = hungryMissToken,
		fishFull = fishFull,
		fishTotal = fishTotal,
		crabTotal = WaveCrab.expectedCount(),
		urchinTotal = WaveUrchin.expectedCount(),
		sharkTotal = WaveShark.countForWave(waveIndex),
		speedMult = speedMult,
	}
	for _, cb in ipairs(hudListeners) do
		cb(snap)
	end
end

-- Grow max (and current) when Reef Health skill stages up. Safe while idle too.
function WaveSim.applyReefHealthStage(stage: number)
	local newMax = L.SkillStages.reefHealthAtStage(stage)
	local delta = newMax - reefMaxHealth
	reefMaxHealth = newMax
	if delta > 0 then
		reefHealth = math.min(reefMaxHealth, reefHealth + delta)
	else
		reefHealth = math.min(reefHealth, reefMaxHealth)
	end
	if running then
		notifyHud()
		flushHud()
	end
end

local function fireStopped(summary: Summary)
	for _, cb in ipairs(stopListeners) do
		cb(summary)
	end
end

local function ensureFolder(): Folder
	if folder and folder.Parent then
		-- Drop any leftover stand-on blockers from older builds.
		for _, ch in ipairs(folder:GetChildren()) do
			if ch.Name == "OceanTD_UrchinBlocker" then
				ch:Destroy()
			end
		end
		return folder
	end
	local f = Instance.new("Folder")
	f.Name = "OceanTD_LocalWaves"
	f.Parent = Workspace
	folder = f
	return f
end

L.WaveEndVfx.bind(ensureFolder)

local function fishSwimPath(agent: FishAgent): PathData?
	return agent.swimPath or pathData
end

local function listFishPaths(): { PathData }
	local out: { PathData } = {}
	if pathData then
		table.insert(out, pathData)
	end
	if pathDataA2 and waveUsesFishA2 then
		table.insert(out, pathDataA2)
	end
	return out
end

local function pickFishSwimPath(): PathData?
	local primary = pathData
	if not primary then
		return nil
	end
	local alt = pathDataA2
	if not alt or fishA2Remaining <= 0 or spawnQueue <= 0 then
		return primary
	end
	-- Exact remaining quota over remaining spawns (including this fish).
	if fishRng:NextNumber() < (fishA2Remaining / spawnQueue) then
		fishA2Remaining -= 1
		return alt
	end
	return primary
end

L.WaveArrowPreview.bind({
	ensureFolder = function()
		return ensureFolder()
	end,
	getFishPath = function()
		return pathData
	end,
	getFishPaths = function()
		-- Arrow trains: WaveRoute.A only (never A2).
		local out: { PathData } = {}
		if pathData then
			table.insert(out, pathData)
		end
		return out
	end,
	getGroundPaths = function()
		return WaveCrab.listGroundPaths(pathDataGroundA, pathDataGroundB)
	end,
	getSharkPath = function()
		return pathDataShark
	end,
	getWaveIndex = function()
		return waveIndex
	end,
	sampleFishPath = function(path, dist)
		return Path.samplePath(path, dist)
	end,
})

-- Always-on green friendly path ribbon (route A only).
-- Prefer pathData from rebuildRouteForPlotSize(stage) so the line matches the moved heart
-- even before SkillPowerUpUI stage mirrors (join-intro MAX path falls back to live stage).
-- Red GroundA/B ribbons while the live wave includes crabs or urchins.
L.WavePathLines.bind({
	getFishPath = function()
		if joinIntroDemo then
			-- Showcase uses the full MAX plot route; don't reuse that after intro.
			return Path.buildPath(L.SkillStages.MAX_STAGE)
		end
		return pathData or Path.buildPath()
	end,
	sampleFishPath = function(path, dist)
		return Path.samplePath(path, dist)
	end,
	getPlotSizeStage = function()
		return L.SkillPowerUpUI.getStage("PlotSize")
	end,
	getGroundPaths = function()
		if #hostilePreviewPaths > 0 then
			return hostilePreviewPaths
		end
		return WaveCrab.listGroundPaths(pathDataGroundA, pathDataGroundB)
	end,
	getHostileDisplayPath = function()
		if #hostilePreviewPaths == 0 then
			return nil
		end
		local idx = math.clamp(hostileDisplayIndex, 1, #hostilePreviewPaths)
		return hostilePreviewPaths[idx]
	end,
	sampleGroundPath = function(path, dist)
		return WaveCrab.sample(path, dist)
	end,
	waveShowsHostilePaths = function()
		if joinIntroDemo then
			return false
		end
		-- Wave-bar eye also gates crab/urchin ribbons (build + waves).
		if not critterHungerBarsVisible or hideUiSuppressesCritterUi then
			return false
		end
		if running then
			if #hostilePreviewPaths == 0 then
				return false
			end
			return WaveCrab.expectedCount() > 0
				or WaveUrchin.expectedCount() > 0
				or WaveCrab.spawnedCount() > 0
				or WaveUrchin.spawnedCount() > 0
		end
		-- Build mode: backpack open, eye not hiding pick circles, past wave 4 this session.
		local InventoryState = require(script.Parent:WaitForChild("InventoryState"))
		if not InventoryState.isOpen() then
			return false
		end
		local RelocatePickHover = require(script.Parent:WaitForChild("RelocatePickHover"))
		if not RelocatePickHover.isPickDebugVisible() then
			return false
		end
		return sessionHighestWaveReached > 4
	end,
	getSharkPath = function()
		return pathDataShark
	end,
	sampleSharkPath = function(path, dist)
		return WaveShark.sample(path, dist)
	end,
	waveShowsSharkPath = function()
		if joinIntroDemo then
			return false
		end
		if not critterHungerBarsVisible or hideUiSuppressesCritterUi then
			return false
		end
		if running then
			-- Only while a shark is alive — shouldSpawn stays true all ×10 wave after it finishes.
			return WaveShark.liveCount() > 0
		end
		-- Build mode: backpack open, eye not hiding pick circles, wave 10+ this session.
		local InventoryState = require(script.Parent:WaitForChild("InventoryState"))
		if not InventoryState.isOpen() then
			return false
		end
		local RelocatePickHover = require(script.Parent:WaitForChild("RelocatePickHover"))
		if not RelocatePickHover.isPickDebugVisible() then
			return false
		end
		return sessionHighestWaveReached >= 10
	end,
})

-- Build preview paths follow backpack open/close (not only wave start/stop).
task.defer(function()
	local InventoryState = require(script.Parent:WaitForChild("InventoryState"))
	InventoryState.onOpenChanged(function()
		L.WavePathLines.syncHostilePaths()
	end)
end)

local function pathAlreadyInList(list: { WaveCrab.PathData }, path: WaveCrab.PathData): boolean
	for _, p in ipairs(list) do
		if p == path then
			return true
		end
	end
	return false
end

local function planHostilePathsForWave()
	table.clear(hostilePreviewPaths)
	table.clear(hostilePathQueue)
	hostileDisplayIndex = 1
	local n = WaveCrab.expectedCount() + WaveUrchin.expectedCount()
	if n <= 0 then
		return
	end
	local available = WaveCrab.listGroundPaths(pathDataGroundA, pathDataGroundB)
	if #available == 0 then
		return
	end
	for _ = 1, n do
		local path = WaveCrab.pickGroundPath(pathDataGroundA, pathDataGroundB, fishRng)
		if path then
			table.insert(hostilePathQueue, path)
			if not pathAlreadyInList(hostilePreviewPaths, path) then
				table.insert(hostilePreviewPaths, path)
			end
		end
	end
end

local function takePlannedGroundPath(): WaveCrab.PathData?
	if #hostilePathQueue > 0 then
		return table.remove(hostilePathQueue, 1)
	end
	return WaveCrab.pickGroundPath(pathDataGroundA, pathDataGroundB, fishRng)
end

-- UrchinMesh is a MeshPart container with RootPart + ShellHitbox children. WeldConstraints
-- don't reliably follow Anchored RootPart teleports, so snap body/shell from stored locals.
local function syncUrchinRig(agent: FishAgent)
	local rootCf = agent.root.CFrame
	local shell = agent.shellHitbox
	local shellLocal = agent.shellLocalCf
	if shell and shell.Parent and shellLocal then
		shell.Anchored = true
		shell.CFrame = rootCf * shellLocal
	end
	local bodyLocal = agent.bodyLocalCf
	local model = agent.model
	if bodyLocal and model:IsA("BasePart") and model ~= agent.root then
		model.Anchored = true
		model.CFrame = rootCf * bodyLocal
	end
	if agent.root.Parent then
		agent.root.Anchored = true
	end
end

local function captureUrchinRigLocals(agent: FishAgent)
	local root = agent.root
	local shell = agent.shellHitbox
	if shell and shell.Parent then
		agent.shellLocalCf = root.CFrame:ToObjectSpace(shell.CFrame)
	end
	local model = agent.model
	if model:IsA("BasePart") and model ~= root then
		agent.bodyLocalCf = root.CFrame:ToObjectSpace(model.CFrame)
	end
end

local function setFishCFrame(agent: FishAgent, pos: Vector3, swimTang: Vector3, dt: number)
	agent.lastWorld = pos
	local move = if swimTang.Magnitude > 1e-5 then swimTang.Unit else Vector3.new(0, 0, -1)

	-- Same as GreenArrows: look along swim dir, then fixed authored yaw/pitch/roll.
	local desired = if Path.isGroundCritter(agent)
		then WaveCrab.facingCFrame(pos, move)
		else CFrame.lookAt(pos, pos + move, Vector3.yAxis) * CFrame.Angles(C.TANG_PITCH, C.TANG_YAW, C.TANG_ROLL)

	if agent.isCrab then
		WaveCrab.applyPose(agent.root, desired)
		local anim = agent.crabAnim
		if anim then
			WaveCrab.stepAnim(anim, dt, pos)
		end
		return
	end
	if agent.isUrchin then
		WaveCrab.applyPose(agent.root, desired)
		syncUrchinRig(agent)
		return
	end
	if agent.isShark then
		local sway = agent.swayPhase or 0
		local sharkCf = WaveShark.facingCFrame(pos, move, sway, simClock)
		WaveShark.applyPose(agent.model, agent.root, sharkCf)
		return
	end

	local model = agent.model
	if model:IsA("Model") then
		model:PivotTo(desired)
	elseif model:IsA("BasePart") then
		model.CFrame = desired
	else
		local oldRoot = agent.root.CFrame
		agent.root.CFrame = desired
		local delta = desired * oldRoot:Inverse()
		for _, d in ipairs(model:GetDescendants()) do
			if d:IsA("BasePart") and d ~= agent.root then
				d.CFrame = delta * d.CFrame
			end
		end
	end
end

function HungerUi.makeHungerBillboard(adornee: BasePart, hungryGlyphs: string?): (BillboardGui, Frame, Frame, TextLabel, TextLabel, TextLabel, UIScale)
	local glyphs = hungryGlyphs or "🍴"
	local glyphN = utf8.len(glyphs) or 1
	-- BillboardGui is not inside the 720p ScreenGui, so it does not inherit BUILD's size.
	-- Phone stays at 1. Larger screens use the same factor as the BUILD button.
	local hud = L.UiPopupScale.getHud()
	local function px(n: number): number
		return math.max(1, math.floor(n * hud + 0.5))
	end
	local emojiSize = px(C.HUNGER_EMOJI_SIZE)
	local emojiW = emojiSize * glyphN
	local remainW = px(C.HUNGER_REMAIN_W)
	local remainGap = px(C.HUNGER_REMAIN_GAP)
	local barGap = px(C.HUNGER_BAR_GAP)
	local barW = px(C.HUNGER_BAR_PX_W)
	local barH = px(C.HUNGER_BAR_PX_H)
	local remainText = px(C.HUNGER_REMAIN_TEXT_SIZE)
	-- [fork] [N] [bar]
	local totalW = emojiW + remainGap + remainW + barGap + barW
	local bb = Instance.new("BillboardGui")
	bb.Name = "HungerBar"
	bb.Size = UDim2.fromOffset(totalW, barH)
	bb.StudsOffset = Vector3.new(0, C.HUNGER_BAR_HEIGHT, 0)
	bb.AlwaysOnTop = true
	bb.MaxDistance = C.HUNGER_BAR_MAX_DIST
	bb.Adornee = adornee
	bb.Parent = adornee

	local barHost = Instance.new("Frame")
	barHost.Name = "BarHost"
	barHost.BackgroundTransparency = 1
	barHost.AnchorPoint = Vector2.new(1, 0.5)
	barHost.Position = UDim2.new(1, 0, 0.5, 0)
	barHost.Size = UDim2.fromOffset(barW, px(C.HUNGER_BAR_STRIP_H))
	barHost.ZIndex = 1
	barHost.Parent = bb

	local scale = Instance.new("UIScale")
	scale.Name = "BarScale"
	scale.Scale = 1
	scale.Parent = barHost

	local bg = Instance.new("Frame")
	bg.Name = "Bg"
	bg.BackgroundColor3 = Color3.new(0, 0, 0)
	bg.BackgroundTransparency = 0.5
	bg.BorderSizePixel = 0
	bg.Size = UDim2.fromScale(1, 1)
	bg.Parent = barHost
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 4)
	corner.Parent = bg
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.new(1, 1, 1)
	stroke.Thickness = math.max(1, hud)
	stroke.Parent = bg

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.BackgroundColor3 = Color3.fromRGB(40, 255, 90)
	fill.BackgroundTransparency = 0
	fill.BorderSizePixel = 0
	fill.Size = UDim2.fromScale(0, 1)
	fill.ZIndex = 1
	fill.Parent = bg
	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(0, 4)
	fillCorner.Parent = fill

	local fork = Instance.new("TextLabel")
	fork.Name = "Fork"
	fork.BackgroundTransparency = 1
	fork.AnchorPoint = Vector2.new(0, 0.5)
	fork.Position = UDim2.new(0, 0, 0.5, 0)
	fork.Size = UDim2.fromOffset(emojiW, emojiSize)
	fork.Font = Enum.Font.SourceSansBold
	fork.Text = glyphs
	fork.TextSize = emojiSize
	fork.TextScaled = false
	fork.TextXAlignment = Enum.TextXAlignment.Left
	fork.ZIndex = 4
	fork.Parent = bb

	local happy = Instance.new("TextLabel")
	happy.Name = "Happy"
	happy.BackgroundTransparency = 1
	happy.AnchorPoint = Vector2.new(0, 0.5)
	happy.Position = UDim2.new(0, emojiW - emojiSize, 0.5, 0)
	happy.Size = UDim2.fromOffset(emojiSize, emojiSize)
	happy.Font = Enum.Font.SourceSansBold
	happy.Text = "😊"
	happy.TextSize = emojiSize
	happy.TextScaled = false
	happy.Visible = false
	happy.ZIndex = 5
	happy.Parent = bb

	local remain = Instance.new("TextLabel")
	remain.Name = "Remain"
	remain.BackgroundTransparency = 1
	remain.AnchorPoint = Vector2.new(0, 0.5)
	remain.Position = UDim2.new(0, emojiW + remainGap, 0.5, 0)
	remain.Size = UDim2.fromOffset(remainW, remainText + px(2))
	remain.Font = Enum.Font.FredokaOne
	remain.Text = ""
	remain.TextColor3 = Color3.new(1, 1, 1)
	remain.TextSize = remainText
	remain.TextScaled = false
	remain.TextXAlignment = Enum.TextXAlignment.Center
	remain.TextYAlignment = Enum.TextYAlignment.Center
	remain.ZIndex = 6
	remain.Parent = bb
	local remainStroke = Instance.new("UIStroke")
	remainStroke.Color = Color3.fromRGB(48, 48, 48)
	remainStroke.Thickness = 1.35 * hud
	remainStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	remainStroke.Parent = remain

	return bb, fill, barHost, fork, happy, remain, scale
end

function HungerUi.setDangerFlash(agent: FishAgent, enable: boolean)
	if agent.dangerActive == enable then
		return
	end
	agent.dangerActive = enable
	agent.dangerToken += 1
	notifyHud()
	if agent.billboard and agent.billboard.Parent then
		-- Keep red-flashing bars visible when zoomed far out (skip LOD hide).
		agent.billboard.MaxDistance = if enable then C.HUNGER_BAR_DANGER_MAX_DIST else C.HUNGER_BAR_MAX_DIST
	end
	if not enable then
		if agent.hunger < agent.maxHunger and agent.fill.Parent then
			agent.fill.BackgroundColor3 = C.FILL_GREEN
			if agent.barStroke then
				agent.barStroke.Color = Color3.new(1, 1, 1)
			end
		end
		return
	end
	local my = agent.dangerToken
	task.spawn(function()
		while agent.dangerToken == my
			and not agent.finished
			and agent.hunger < agent.maxHunger
			and agent.model.Parent
		do
			agent.fill.BackgroundColor3 = C.DANGER_RED
			if agent.barStroke then
				agent.barStroke.Color = C.DANGER_RED
			end
			task.wait(0.28)
			if agent.dangerToken ~= my or agent.finished then
				return
			end
			agent.fill.BackgroundColor3 = C.FILL_GREEN
			if agent.barStroke then
				agent.barStroke.Color = Color3.new(1, 1, 1)
			end
			task.wait(0.28)
		end
	end)
end

-- Player tap-feed: brief green outer stroke on the hunger bar.
-- Always flash from / restore to base thickness so rapid auto-fire can't stack thick strokes.
local HUNGER_STROKE_BASE = 1
local HUNGER_STROKE_FLASH = 2
function HungerUi.flashTapStroke(agent: FishAgent)
	local stroke = agent.barStroke
	if not stroke or not stroke.Parent or agent.finished then
		return
	end
	agent.tapStrokeToken += 1
	local my = agent.tapStrokeToken
	stroke.Color = C.FILL_GREEN
	stroke.Thickness = HUNGER_STROKE_FLASH
	task.delay(0.2, function()
		if agent.tapStrokeToken ~= my or not stroke.Parent then
			return
		end
		stroke.Thickness = HUNGER_STROKE_BASE
		if agent.dangerActive then
			-- Danger loop will recolor on its next tick.
			return
		end
		if agent.hunger < agent.maxHunger then
			stroke.Color = Color3.new(1, 1, 1)
		end
	end)
end

function HungerUi.playFeedSound()
	if joinIntroDemo then
		return
	end
	-- Always the coral-food hit asset (not coin / not next-wave).
	feedSound.SoundId = C.FEED_SOUND_ID
	local pitch = feedPitchCursor
	feedPitchCursor += C.FEED_PITCH_STEP
	if feedPitchCursor > C.FEED_PITCH_MAX then
		feedPitchCursor = C.FEED_PITCH_MIN
	end
	WaveEntityPool.playSound("feed", feedSound, pitch, 0.85)
end

function HungerUi.startHappyFlash(agent: FishAgent)
	agent.pulseToken += 1
	agent.dangerToken += 1
	agent.dangerActive = false
	local my = agent.pulseToken
	agent.happyLabel.Text = C.HAPPY_EMOJIS[fishRng:NextInteger(1, #C.HAPPY_EMOJIS)]
	task.spawn(function()
		while agent.pulseToken == my and not agent.finished and agent.model.Parent do
			agent.happyLabel.Visible = true
			task.wait(C.HAPPY_FLASH_ON)
			if agent.pulseToken ~= my or agent.finished then
				return
			end
			agent.happyLabel.Visible = false
			task.wait(C.HAPPY_FLASH_OFF)
		end
	end)
end

function HungerUi.updateHungerVisual(agent: FishAgent)
	local u = agent.hunger / agent.maxHunger
	agent.fill.Size = UDim2.fromScale(math.clamp(u, 0, 1), 1)
	local left = math.max(0, math.ceil(agent.maxHunger - agent.hunger))
	if agent.remainLabel then
		if left > 0 then
			agent.remainLabel.Text = tostring(left)
			agent.remainLabel.Visible = true
		else
			agent.remainLabel.Text = ""
			agent.remainLabel.Visible = false
		end
	end
	if agent.hunger >= agent.maxHunger then
		markFishFullyFed(agent, nil)
		agent.barFrame.Visible = false
		agent.forkLabel.Visible = false
		if agent.remainLabel then
			agent.remainLabel.Visible = false
		end
		HungerUi.setDangerFlash(agent, false)
		HungerUi.startHappyFlash(agent)
	else
		agent.pulseToken += 1
		agent.barFrame.Visible = true
		agent.forkLabel.Visible = true
		agent.happyLabel.Visible = false
		if not agent.dangerActive then
			agent.fill.BackgroundColor3 = C.FILL_GREEN
		end
	end
	notifyHud()
end


function HungerUi.critterWorldUiEnabled(): boolean
	return critterHungerBarsVisible and not hideUiSuppressesCritterUi and not joinIntroDemo
end

function HungerUi.applyCritterHungerBarsVisible()
	for _, agent in ipairs(fishList) do
		if agent.billboard then
			agent.billboard.Enabled = HungerUi.critterWorldUiEnabled()
		end
	end
	L.WaveEndVfx.setHappyExitVisible(HungerUi.critterWorldUiEnabled())
end

local function applySizeStats(coral: CoralAgent)
	local _d, class = L.CoralSize.readFromPart(coral.part)
	local speciesId = coral.part:GetAttribute("OceanTD_SpeciesId")
	local sid = if typeof(speciesId) == "string" then speciesId else nil
	local st = L.CoralSize.statsFor(class, sid)
	-- Join intro: half the nest orbs (fewer Parts / park / fade) — one branch, no extra systems.
	local food = st.food
	if joinIntroDemo then
		food = math.max(1, food // 2)
	end
	coral.foodCount = food
	coral.range = st.range
	coral.rangeSq = st.range * st.range
	coral.defenseSec = st.defense
	coral.reloadSec = st.reload
	-- Lane stock / volleys: size food count is the hunger deposited per restock (not visual-only).
	local fill = math.max(1, food)
	if coral.foodFill ~= fill then
		coral.foodFill = fill
		markCoralBucketsDirty()
	else
		coral.foodFill = fill
	end
end

function Feed.destroyAmmo(coral: CoralAgent)
	Feed.clearNestRise(coral)
	Feed._ammoFade[coral] = nil
	for _, p in ipairs(coral.ammoSlots) do
		p.Transparency = 0
		WaveEntityPool.releaseAmmo(p)
	end
	table.clear(coral.ammoSlots)
	coral.ammo = nil
	coral.ammoLocalOffs = nil
	coral.bubblePhase = nil
	coral.bubbleWasNear = false
	coral.ammoArmPending = false
	-- Do not clear coral.growing here — createAmmo calls this while starting a grow.
end

function Feed.detachAmmoWithoutRelease(coral: CoralAgent)
	Feed.clearNestRise(coral)
	Feed._ammoFade[coral] = nil
	table.clear(coral.ammoSlots)
	coral.ammo = nil
	coral.ammoLocalOffs = nil
	coral.bubblePhase = nil
	coral.bubbleWasNear = false
	coral.ammoArmPending = false
end

function Feed.rollAmmoSizeMult(): number
	-- 1%–30% smaller than base AMMO_RADIUS.
	return 1 - (0.01 + math.random() * 0.29)
end

function Feed.ammoFullDiameter(coral: CoralAgent): number
	applySizeStats(coral)
	return C.AMMO_RADIUS * 2 * coral.ammoSizeMult * L.CoralSize.ammoSizeScale(coral.foodCount)
end

function Feed.rebuildAmmoLocalOffs(coral: CoralAgent)
	applySizeStats(coral)
	local r = L.CoralSize.ammoAnchorRadius(coral.part)
	local ammoR = C.AMMO_RADIUS * coral.ammoSizeMult * L.CoralSize.ammoSizeScale(coral.foodCount)
	local nVis = #coral.ammoSlots
	if nVis < 1 then
		nVis = coral.foodCount
	end
	local speciesId = coral.part:GetAttribute("OceanTD_SpeciesId")
	local sid = if typeof(speciesId) == "string" then speciesId else nil
	if L.BrainStack.isBrainId(sid) then
		-- Prefer link neighbors only; gather brains once (not every GetAttribute on whole plot twice).
		local brains: { BasePart } = {}
		local mir = ClientPlot.get()
		if mir then
			for _, p in ipairs(L.PlacedCoralIndex.getParts(mir.plotId)) do
				local oid = p:GetAttribute("OceanTD_SpeciesId")
				if L.BrainStack.isBrainId(oid) then
					table.insert(brains, p)
				end
			end
		end
		local neighbors = L.BrainStack.collectLinkNeighbors(coral.part, brains)
		coral.ammoLocalOffs = L.BrainStack.ammoLocalOffsets(coral.part, nVis, ammoR, neighbors)
	else
		coral.ammoLocalOffs = L.CoralSize.ammoLocalOffsets(nVis, r, ammoR, sid, coral.part.Size, coral.part)
	end
end

function Feed.ammoWorldPos(coral: CoralAgent, slot: number?): Vector3
	local offs = coral.ammoLocalOffs
	if not offs or #offs < 1 then
		Feed.rebuildAmmoLocalOffs(coral)
		offs = coral.ammoLocalOffs
	end
	if not offs or #offs < 1 then
		return coral.part.Position
	end
	local i = math.clamp(slot or 1, 1, #offs)
	return coral.part.CFrame:PointToWorldSpace(offs[i])
end

function Feed.parkAmmo(coral: CoralAgent)
	if not coral.ammoLocalOffs or #coral.ammoLocalOffs < 1 then
		Feed.rebuildAmmoLocalOffs(coral)
	end
	for i, p in ipairs(coral.ammoSlots) do
		if p.Parent then
			p.CFrame = CFrame.new(Feed.ammoWorldPos(coral, i))
		end
	end
	coral.needsPark = false
end

function Feed.refreshCoralLook(coral: CoralAgent)
	-- Prefer rest look for shot color (ignore transient hover/relocate neon wash).
	local _, restColor = L.CoralVisual.readRestLook(coral.part)
	coral.color = restColor
	coral.diameter = math.max(coral.part.Size.X, coral.part.Size.Y, coral.part.Size.Z)
	applySizeStats(coral)
	Feed.parkAmmo(coral)
	coral.needsLook = false
end

function Feed.shareTransparency(coral: CoralAgent): number
	if C.FEED_MODE ~= "path_fields" then
		return 0
	end
	local maxShare = Feed._maxRateShare or 0
	local share = coral.rateShare or 0
	local u = if maxShare > 0 then math.clamp(share / maxShare, 0, 1) else 0
	-- Busy nests stay bright. A coral off the path fades out.
	return 0.82 - 0.67 * u
end

function Feed.applyCoralShareLook(coral: CoralAgent)
	if Feed._risePulses[coral] or Feed._ammoFade[coral] then
		return
	end
	local t = Feed.shareTransparency(coral)
	for _, p in ipairs(coral.ammoSlots) do
		if p.Parent then
			p.Transparency = t
		end
	end
end

function Feed.applyRateGlow()
	local maxShare = 0
	for _, coral in ipairs(coralList) do
		local share = coral.rateShare or 0
		if share > maxShare then
			maxShare = share
		end
	end
	Feed._maxRateShare = maxShare
	for _, coral in ipairs(coralList) do
		local u = if maxShare > 0 then math.clamp((coral.rateShare or 0) / maxShare, 0, 1) else 0
		if coral.part.Parent then
			coral.part:SetAttribute("OceanTD_FeedShare", u)
		end
		Feed.applyCoralShareLook(coral)
	end
end

function Feed.createAmmo(coral: CoralAgent, scale: number)
	-- Show parked nest food. Brightness follows path-rate share after the fade-in.
	if coral.stunned then
		return
	end
	Feed.destroyAmmo(coral)
	local clamped = math.clamp(scale, 0.08, 1)
	-- New orb (grow start or instant full): pick a random 1–30% smaller size.
	if clamped <= 0.08 or clamped >= 1 then
		coral.ammoSizeMult = Feed.rollAmmoSizeMult()
	end
	applySizeStats(coral)
	local s = Feed.ammoFullDiameter(coral) * clamped
	local n = coral.foodCount
	-- Intro showcase: half the nest food (less ammo Parts + lighter feeding).
	if joinIntroDemo then
		n = math.max(1, math.floor(n * 0.5 + 0.5))
	end
	for _ = 1, n do
		local p = WaveEntityPool.acquireAmmo(ensureFolder(), coral.color, s)
		table.insert(coral.ammoSlots, p)
	end
	Feed.rebuildAmmoLocalOffs(coral)
	Feed.parkAmmo(coral)
	coral.ammo = coral.ammoSlots[1]
	coral.ammoArmPending = false
	-- Full-size spawn: fade in (cheaper than scaling Size every frame).
	if clamped >= 1 then
		for _, p in ipairs(coral.ammoSlots) do
			p.Transparency = 1
		end
		Feed._ammoFade[coral] = {
			t0 = simClock,
			dur = math.max(0.05, C.AMMO_FADE_IN_SEC),
		}
	end
	-- Spread first restock so nests don't all arm on the same frame.
	local reload = math.max(0.05, coral.reloadSec)
	coral.readyAt = simClock + fishRng:NextNumber(0, reload)
end

function Feed.clearAllAmmoFades()
	table.clear(Feed._ammoFade)
end

local function stopOrphanAmmoFadeLoop()
	if Feed._orphanAmmoFadeConn then
		Feed._orphanAmmoFadeConn:Disconnect()
		Feed._orphanAmmoFadeConn = nil
	end
end

function Feed.stopOrphanAmmoFade()
	stopOrphanAmmoFadeLoop()
	for _, job in ipairs(Feed._orphanAmmoFades) do
		for _, p in ipairs(job.parts) do
			if p.Parent then
				p.Transparency = 0
				WaveEntityPool.releaseAmmo(p)
			end
		end
	end
	table.clear(Feed._orphanAmmoFades)
	for _, job in ipairs(Feed._orphanCritterFades) do
		for _, p in ipairs(job.parts) do
			if p.Parent then
				p.LocalTransparencyModifier = 0
				p.Transparency = 0
			end
		end
		if job.model.Parent then
			WaveEntityPool.releaseFish(job.kind, job.model)
		end
	end
	table.clear(Feed._orphanCritterFades)
end

function Feed.tickOrphanAmmoFade(now: number)
	local jobs = Feed._orphanAmmoFades
	local critters = Feed._orphanCritterFades
	if #jobs < 1 and #critters < 1 then
		stopOrphanAmmoFadeLoop()
		return
	end
	local remaining: { { parts: { BasePart }, t0: number, dur: number } } = {}
	for _, job in ipairs(jobs) do
		local u = (now - job.t0) / job.dur
		if u >= 1 then
			for _, p in ipairs(job.parts) do
				if p.Parent then
					p.Transparency = 1
					WaveEntityPool.releaseAmmo(p)
				end
			end
		else
			if u > 0 then
				local t = math.clamp(u, 0, 1)
				for _, p in ipairs(job.parts) do
					if p.Parent then
						p.Transparency = t
					end
				end
			end
			table.insert(remaining, job)
		end
	end
	Feed._orphanAmmoFades = remaining

	local critRemain: {
		{
			model: Instance,
			kind: string,
			parts: { BasePart },
			t0: number,
			dur: number,
		}
	} = {}
	for _, job in ipairs(critters) do
		local u = (now - job.t0) / job.dur
		if u >= 1 then
			for _, p in ipairs(job.parts) do
				if p.Parent then
					p.LocalTransparencyModifier = 1
					p.Transparency = 1
				end
			end
			if job.model.Parent then
				WaveEntityPool.releaseFish(job.kind, job.model)
			end
		else
			if u > 0 then
				local t = math.clamp(u, 0, 1)
				for _, p in ipairs(job.parts) do
					if p.Parent then
						p.LocalTransparencyModifier = t
						p.Transparency = math.max(p.Transparency, t)
					end
				end
			end
			table.insert(critRemain, job)
		end
	end
	Feed._orphanCritterFades = critRemain

	if #Feed._orphanAmmoFades < 1 and #Feed._orphanCritterFades < 1 then
		stopOrphanAmmoFadeLoop()
	end
end

function Feed.startOrphanAmmoFadeLoop()
	if Feed._orphanAmmoFadeConn then
		return
	end
	Feed._orphanAmmoFadeConn = L.RunService.RenderStepped:Connect(function()
		Feed.tickOrphanAmmoFade(os.clock())
	end)
end

-- Join-intro end: stagger nest-food fade-out instead of one-frame cleanup.
function Feed.scheduleOrphanAmmoFadeOut(dur: number, spread: number): number
	Feed.stopOrphanAmmoFade()
	local tBase = os.clock()
	local maxEnd = 0
	for _, coral in ipairs(coralList) do
		local slots = coral.ammoSlots
		if slots and #slots > 0 then
			-- Copy refs — detachAmmoWithoutRelease clears coral.ammoSlots in place.
			local parts: { BasePart } = table.create(#slots)
			for i, p in ipairs(slots) do
				parts[i] = p
			end
			local offset = fishRng:NextNumber(0, spread)
			table.insert(Feed._orphanAmmoFades, {
				parts = parts,
				t0 = tBase + offset,
				dur = dur,
			})
			maxEnd = math.max(maxEnd, offset + dur)
		end
	end
	if #Feed._orphanAmmoFades > 0 then
		Feed.startOrphanAmmoFadeLoop()
	end
	return maxEnd
end

-- Join-intro end: fade critters with the same stagger window as nest food.
function Feed.scheduleOrphanCritterFadeOut(dur: number, spread: number): number
	local tBase = os.clock()
	local maxEnd = 0
	for _, agent in ipairs(fishList) do
		local model = agent.model
		if not model or not model.Parent then
			continue
		end
		agent.finished = true
		agent.pulseToken += 1
		agent.dangerToken += 1
		agent.dangerActive = false
		if agent.billboard and agent.billboard.Parent then
			agent.billboard.Enabled = false
		end
		if agent.isCrab then
			WaveCrab.resetAnim(agent.crabAnim)
		elseif agent.isShark then
			WaveShark.onDespawned()
		end
		local parts: { BasePart } = {}
		if model:IsA("BasePart") then
			table.insert(parts, model)
		end
		for _, d in ipairs(model:GetDescendants()) do
			if d:IsA("BasePart") then
				table.insert(parts, d)
			end
		end
		if #parts < 1 then
			continue
		end
		local kind = if agent.isCrab
			then WaveEntityPool.FISH_CRAB
			elseif agent.isUrchin then WaveEntityPool.FISH_URCHIN
			elseif agent.isShark then WaveEntityPool.FISH_SHARK
			else WaveEntityPool.FISH_TANG
		local offset = fishRng:NextNumber(0, spread)
		table.insert(Feed._orphanCritterFades, {
			model = model,
			kind = kind,
			parts = parts,
			t0 = tBase + offset,
			dur = dur,
		})
		maxEnd = math.max(maxEnd, offset + dur)
	end
	if #Feed._orphanCritterFades > 0 then
		Feed.startOrphanAmmoFadeLoop()
	end
	return maxEnd
end

function Feed.tickAmmoFade(now: number)
	local fades = Feed._ammoFade
	local done = Feed._ammoFadeDone
	table.clear(done)
	for coral, fade in pairs(fades) do
		local slots = coral.ammoSlots
		if not slots or #slots < 1 or not coral.part or not coral.part.Parent then
			table.insert(done, coral)
			continue
		end
		local u = (now - fade.t0) / fade.dur
		if u >= 1 then
			table.insert(done, coral)
		else
			local t = 1 - math.clamp(u, 0, 1)
			for _, p in ipairs(slots) do
				if p.Parent then
					p.Transparency = t
				end
			end
		end
	end
	for _, coral in ipairs(done) do
		fades[coral] = nil
		Feed.applyCoralShareLook(coral)
	end
end

function Feed.clearAmmoArmQueue()
	for _, job in ipairs(Feed._ammoArmQueue) do
		local c = job.coral :: CoralAgent?
		if c then
			c.ammoArmPending = false
		end
	end
	table.clear(Feed._ammoArmQueue)
end

-- Wave start: delay then randomly stagger nest orbs across AMMO_ARM_SPREAD_SEC.
function Feed.scheduleWaveStartAmmoArm(coral: CoralAgent)
	if coral.stunned then
		return
	end
	if coral.ammoArmPending then
		return
	end
	local q = Feed._ammoArmQueue
	for _, job in ipairs(q) do
		if job.coral == coral then
			coral.ammoArmPending = true
			return
		end
	end
	local delay = C.AMMO_ARM_DELAY_SEC + fishRng:NextNumber(0, C.AMMO_ARM_SPREAD_SEC)
	local at = simClock + delay
	table.insert(q, { coral = coral, at = at })
	coral.ammoArmPending = true
	-- Hold restock until the nest orb appears (avoids a restock stampede before visuals).
	coral.readyAt = at
end

function Feed.tickAmmoArm(now: number)
	local q = Feed._ammoArmQueue
	if #q < 1 then
		return
	end
	local budget = C.AMMO_ARM_PER_FRAME
	local i = 1
	while i <= #q and budget > 0 do
		local job = q[i]
		if now < job.at then
			i += 1
			continue
		end
		table.remove(q, i)
		budget -= 1
		local coral = job.coral :: CoralAgent
		coral.ammoArmPending = false
		if not coral.part.Parent or coral.stunned or coral.growing or #coral.ammoSlots > 0 then
			continue
		end
		Feed.createAmmo(coral, 1)
		coral.busy = false
		coral.growing = false
	end
end

function Feed.requestPathStampAll()
	Feed._pathStampIndex = 1
end

function Feed.clearPathStamp()
	Feed._pathStampIndex = 0
end

-- Spread coral→path bucket stamps across Heartbeats (session-start hitch otherwise).
function Feed.tickPathStamp()
	local i = Feed._pathStampIndex
	if i < 1 then
		return
	end
	local budget = C.PATH_STAMP_PER_FRAME
	local n = #coralList
	while budget > 0 and i <= n do
		assignCoralPathBuckets(coralList[i])
		i += 1
		budget -= 1
	end
	if i > n then
		Feed._pathStampIndex = 0
		markCoralBucketsDirty()
		Feed._bucketsReady = true
	else
		Feed._pathStampIndex = i
	end
end

function Feed.startAmmoGrow(coral: CoralAgent)
	if coral.stunned or coral.growing or #coral.ammoSlots > 0 then
		return
	end
	Feed.createAmmo(coral, 0.08)
	coral.growing = true
	coral.growT0 = simClock
	coral.readyAt = math.huge
end

function Feed.tickAmmoGrow(now: number)
	-- Reload is timer-only: nest stays at seed Size until ready, then snaps full.
	-- Avoids O(corals × slots) Size/CFrame writes every Heartbeat while feeding.
	for _, coral in ipairs(coralList) do
		if coral.stunned or not coral.growing then
			continue
		end
		local reload = math.max(0.05, coral.reloadSec)
		if (now - coral.growT0) < reload then
			continue
		end
		coral.growing = false
		coral.readyAt = now
		if #coral.ammoSlots > 0 then
			local s = Feed.ammoFullDiameter(coral)
			for i, p in ipairs(coral.ammoSlots) do
				if p.Parent then
					p.Size = Vector3.new(s, s, s)
					p.CFrame = CFrame.new(Feed.ammoWorldPos(coral, i))
				end
			end
		else
			Feed.createAmmo(coral, 1)
		end
	end
end

function Feed.acquireFoodPart(): BasePart
	return WaveEntityPool.acquireFood(ensureFolder(), C.FOOD_RADIUS)
end

function Feed.acquireTapFoodPart(): BasePart
	local r = (C.FOOD_RADIUS or 0.52) * (C.TAP_FEED_SIZE_MULT or 2.6)
	return WaveEntityPool.acquireFood(ensureFolder(), r)
end

function Feed.releaseFoodPart(p: BasePart)
	WaveEntityPool.releaseFood(p)
end

function Feed.releaseShotVisual(shot: FoodShot)
	local p = shot.part
	if not p then
		return
	end
	shot.part = nil
	visibleShotCount = math.max(0, visibleShotCount - 1)
	Feed.releaseFoodPart(p)
end

function Feed.shotWantsVisual(start: Vector3, meet: Vector3): boolean
	-- Under/at gate: always show flying food. Over gate: cap + camera distance cull.
	if placedCoralCount <= (C.FOOD_CULL_MIN_CORALS or 100) then
		return true
	end
	if visibleShotCount >= C.FOOD_VISIBLE_MAX then
		return false
	end
	local cam = Workspace.CurrentCamera
	if not cam then
		return true
	end
	local focus = cam.CFrame.Position
	local mid = start:Lerp(meet, 0.45)
	local maxDist = C.FOOD_VISIBLE_DIST
	return (start - focus).Magnitude <= maxDist
		or (meet - focus).Magnitude <= maxDist
		or (mid - focus).Magnitude <= maxDist
end

local function makeCoralAgent(part: BasePart): CoralAgent?
	if typeof(part:GetAttribute("OceanTD_GhostBaseR")) == "number" then
		return nil
	end
	local itemId = part:GetAttribute("OceanTD_ItemId")
	local speciesId = part:GetAttribute("OceanTD_SpeciesId")
	local id = if typeof(itemId) == "string" and itemId ~= "" then itemId
		elseif typeof(speciesId) == "string" and speciesId ~= "" then speciesId
		elseif part.Name ~= "" and L.ItemCatalog.get(part.Name) then part.Name
		else nil
	if not id then
		return nil
	end
	local item = L.ItemCatalog.get(id)
	local species = L.SpeciesCatalog.get(if typeof(speciesId) == "string" then speciesId else id)
		or (if item then L.SpeciesCatalog.get(item.speciesId) else nil)
	local reload = C.DEFAULT_RELOAD
	local fillAmt = C.DEFAULT_FOOD_FILL
	local diameter = math.max(part.Size.X, part.Size.Y, part.Size.Z)
	if species then
		reload = species.reloadSec or C.DEFAULT_RELOAD
		fillAmt = species.foodFill or C.DEFAULT_FOOD_FILL
	end
	local pid = part:GetAttribute("OceanTD_PlaceId")
	local initFed = 0
	local initWaves = 0
	if typeof(pid) == "string" and pid ~= "" then
		local st = coralStatsByPlaceId[pid] or { fed = 0, waves = 0 }
		-- Merge part attrs (hydrated from save / prior wave) into session totals.
		st.fed = math.max(st.fed, LifeStats.readAttr(part, "OceanTD_CoralFedTotal"))
		st.waves = math.max(st.waves, LifeStats.readAttr(part, "OceanTD_CoralWavesTotal"))
		coralStatsByPlaceId[pid] = st
		initFed = st.fed
		initWaves = st.waves
	end
	local rb, rn = CoralBuckets.newRouteBuckets()
	local agent: CoralAgent = {
		part = part,
		color = select(2, L.CoralVisual.readRestLook(part)),
		reloadSec = reload,
		foodFill = fillAmt,
		foodCount = 1,
		range = C.TARGET_RANGE,
		rangeSq = C.TARGET_RANGE_SQ,
		defenseSec = 2,
		diameter = diameter,
		readyAt = 0,
		ammo = nil,
		ammoSlots = {},
		ammoSizeMult = 1,
		ammoLocalOffs = nil,
		bubblePhase = nil,
		bubbleWasNear = false,
		growing = false,
		growT0 = 0,
		needsPark = false,
		needsLook = false,
		busy = false,
		shotsOut = 0,
		pathDist = 0,
		pathSideDist = 0,
		pathBuckets = {},
		routeBuckets = rb,
		routeNearDist = rn,
		combatScore = 0,
		combatGen = 0,
		stunned = false,
		lanePulseReady = false,
		ammoArmPending = false,
		fedTotal = initFed,
		wavesTotal = initWaves,
	}
	applySizeStats(agent)
	-- Expose lifetime counters on the part for the inspect UI.
	if typeof(pid) == "string" and pid ~= "" then
		LifeStats.syncAttrs(part, initFed, initWaves)
	end
	part:GetPropertyChangedSignal("Size"):Connect(function()
		agent.diameter = math.max(part.Size.X, part.Size.Y, part.Size.Z)
		applySizeStats(agent)
		agent.ammoLocalOffs = nil
		Feed.parkAmmo(agent)
		assignCoralPathBuckets(agent)
	end)
	-- Relocate / nudge: park nests on next sync tick instead of every coral every 10 Hz.
	part:GetPropertyChangedSignal("CFrame"):Connect(function()
		agent.needsPark = true
		markCoralSpatialDirty()
		assignCoralPathBuckets(agent)
	end)
	return agent
end

local function gatherPlotCoralParts(): { BasePart }
	if demoCoralParts then
		local parts: { BasePart } = {}
		for _, inst in ipairs(demoCoralParts) do
			if not inst.Parent then
				continue
			end
			-- Skip Accent/Web/Food — only stem/main parts feed (child or leftover sibling).
			local lower = string.lower(inst.Name)
			if lower == "accent" or lower == "web" or lower == "seafanweb" or lower == "fanweb"
				or string.find(lower, "accent", 1, true) ~= nil
				or (string.find(lower, "web", 1, true) ~= nil and string.find(lower, "webbed", 1, true) == nil)
				or string.sub(lower, 1, 4) == "food"
			then
				continue
			end
			if inst.Parent:IsA("BasePart") then
				continue
			end
			table.insert(parts, inst)
		end
		return parts
	end
	local mirrored = ClientPlot.get()
	if not mirrored then
		return {}
	end
	local indexed = L.PlacedCoralIndex.getParts(mirrored.plotId)
	local parts: { BasePart } = {}
	for _, inst in ipairs(indexed) do
		if inst.Parent then
			table.insert(parts, inst)
		end
	end
	return parts
end

local function refreshCoralPathProjections()
	if not pathData then
		return
	end
	for _, c in ipairs(coralList) do
		assignCoralPathBuckets(c)
	end
	markCoralBucketsDirty()
end

-- Keep coral reload/ammo state across waves. Only arm new places; remove destroyed.
local function syncCorals(sessionStart: boolean)
	local liveParts = gatherPlotCoralParts()
	-- Do not prewarm while wave-start arm is pending (prewarm Instant.new's the whole pool).
	if not sessionStart and #Feed._ammoArmQueue == 0 then
		maybePrewarmOrbs(#liveParts, false)
	end

	local liveSet: { [BasePart]: boolean } = {}
	for _, p in ipairs(liveParts) do
		liveSet[p] = true
	end

	local listChanged = false
	for i = #coralList, 1, -1 do
		local c = coralList[i]
		if not c.part.Parent or not liveSet[c.part] then
			c.growing = false
			c.busy = false
			Feed.destroyAmmo(c)
			table.remove(coralList, i)
			listChanged = true
		end
	end

	local known: { [BasePart]: boolean } = {}
	for _, c in ipairs(coralList) do
		known[c.part] = true
	end

	for _, part in ipairs(liveParts) do
		if not known[part] then
			local c = makeCoralAgent(part)
			if c then
				table.insert(coralList, c)
				listChanged = true
				if sessionStart then
					Feed.scheduleWaveStartAmmoArm(c)
					-- A close-build rebuild already stamped the rest. Stamp only coral added since.
					if Feed._bucketsReady then
						assignCoralPathBuckets(c)
					end
				else
					-- Mid-wave place: spawn food immediately. Build-close sync is not running, so no ammo yet.
					if running then
						Feed.createAmmo(c, 1)
						c.busy = false
						c.growing = false
					end
					assignCoralPathBuckets(c)
				end
			end
		elseif sessionStart then
			-- First wave only: ensure existing corals have a full ammo orb if idle.
			local c: CoralAgent? = nil
			for _, existing in ipairs(coralList) do
				if existing.part == part then
					c = existing
					break
				end
			end
			if c and not c.stunned and not c.busy and not c.growing and not c.ammoArmPending then
				Feed.scheduleWaveStartAmmoArm(c)
			end
		end
	end

	for _, c in ipairs(coralList) do
		if sessionStart or c.needsLook then
			Feed.refreshCoralLook(c)
		elseif c.needsPark then
			Feed.parkAmmo(c)
		end
		-- Volleys: reload grow when empty. Lane stock: keep static full nest food (no fire).
		-- Skip while wave-start arm is pending — otherwise combat syncCorals(false) arms all nests at once.
		if c.ammoArmPending then
			continue
		end
		if not c.stunned and not c.growing and #c.ammoSlots == 0 and c.shotsOut <= 0 then
			if sessionStart then
				Feed.scheduleWaveStartAmmoArm(c)
			elseif C.FEED_MODE == "volleys" then
				Feed.startAmmoGrow(c)
			elseif C.FEED_MODE == "lane_stock" or C.FEED_MODE == "path_fields" then
				Feed.createAmmo(c, 1)
			end
		end
	end
	-- Session start: stamp coral→path over many frames (was a full O(n) stall here).
	-- Skipped when build-close already stamped this layout.
	if sessionStart and not Feed._bucketsReady then
		Feed.requestPathStampAll()
	end
	if listChanged or sessionStart then
		markCoralSpatialDirty()
		markCoralBucketsDirty()
	end
end

local function countAliveWaveBlockers(): number
	-- Sharks linger after the wave advances; they must not gate the next wave.
	-- Urchins block until finished (fed exit or path-end leak).
	local n = 0
	for _, f in ipairs(fishList) do
		if f.finished then
			continue
		end
		if f.isShark then
			if not f.fedCounted and f.hunger < f.maxHunger then
				n += 1
			end
		elseif not isWaveLingerer(f) then
			n += 1
		end
	end
	return n
end

local function syncGroundPathHearts()
	local ends: { [string]: Vector3 } = {}
	local scales: { [string]: number } = {}
	for _, f in ipairs(fishList) do
		if (f.isCrab or f.isUrchin) and not f.finished and f.groundPath then
			local e = f.groundPath.endPos
			local key = string.format("%.0f_%.0f_%.0f", e.X, e.Y, e.Z)
			ends[key] = e
		elseif f.isShark and not f.finished and pathDataShark then
			local e = pathDataShark.endPos
			local key = "shark_" .. string.format("%.0f_%.0f_%.0f", e.X, e.Y, e.Z)
			ends[key] = e
			scales[key] = L.WaveEndVfx.SHARK_HEART_SCALE or (1 / 3)
		end
	end
	L.WaveEndVfx.syncGroundPathHearts(ends, scales)
end

local function destroyFish(agent: FishAgent)
	local wasPathHeart = agent.isCrab or agent.isUrchin or agent.isShark
	agent.finished = true
	agent.pulseToken += 1
	agent.dangerToken += 1
	agent.dangerActive = false
	local tapDbg = agent.tapDebugPart
	if tapDbg then
		agent.tapDebugPart = nil
		tapDbg:Destroy()
	end
	if agent.isCrab then
		WaveCrab.resetAnim(agent.crabAnim)
		WaveEntityPool.releaseFish(WaveEntityPool.FISH_CRAB, agent.model)
	elseif agent.isUrchin then
		WaveEntityPool.releaseFish(WaveEntityPool.FISH_URCHIN, agent.model)
	elseif agent.isShark then
		WaveShark.onDespawned()
		WaveEntityPool.releaseFish(WaveEntityPool.FISH_SHARK, agent.model)
		-- Drop the orange shark ribbon as soon as the shark (and reef heart) leave.
		L.WavePathLines.syncHostilePaths()
	else
		WaveEntityPool.releaseFish(WaveEntityPool.FISH_TANG, agent.model)
	end
	if wasPathHeart then
		syncGroundPathHearts()
	end
end

-- Drop finished agents (models already released) so the next wave won't share refs.
local function pruneFinishedFish()
	local kept: { FishAgent } = {}
	for _, f in ipairs(fishList) do
		if not f.finished then
			table.insert(kept, f)
		end
	end
	fishList = kept
end

local function attachTapFeedDebug(agent: FishAgent)
	local existing = agent.tapDebugPart
	if not C.TAP_FEED_DEBUG then
		if existing then
			agent.tapDebugPart = nil
			existing:Destroy()
		end
		return
	end
	if existing and existing.Parent then
		return
	end
	local root = agent.root
	local baseR = C.TAP_FEED_RADIUS or 10
	local mult = if waveIndex <= 10
		then (C.TAP_FEED_RADIUS_MULT_W1_10 or 1.716)
		elseif waveIndex <= 20 then (C.TAP_FEED_RADIUS_MULT_W11_20 or 1.32)
		elseif waveIndex <= 30 then (C.TAP_FEED_RADIUS_MULT_W21_30 or 1.1)
		else 1
	if agent.isShark then
		mult *= (C.TAP_FEED_RADIUS_MULT_SHARK or 2)
	end
	local diam = math.max(2, baseR * mult * 2)
	local ball = Instance.new("Part")
	ball.Name = "OceanTD_TapFeedDebug"
	ball.Shape = Enum.PartType.Ball
	ball.Size = Vector3.new(diam, diam, diam)
	ball.Transparency = 0.82
	ball.Color = Color3.fromRGB(40, 255, 200)
	ball.Material = Enum.Material.ForceField
	ball.CastShadow = false
	ball.CanCollide = false
	ball.CanQuery = false
	ball.CanTouch = false
	ball.Massless = true
	ball.Anchored = false
	ball.CFrame = root.CFrame
	ball.Parent = agent.model
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = root
	weld.Part1 = ball
	weld.Parent = ball
	agent.tapDebugPart = ball
end

local function finishFish(agent: FishAgent, skipHappyVfx: boolean?)
	if agent.finished then
		return
	end
	local empty = agent.maxHunger - agent.hunger
	if empty > 0 then
		if joinIntroDemo then
			-- Showcase: hungry arrivals never damage reef health.
			agent.finished = true
			destroyFish(agent)
			notifyHud()
			return
		end
		-- Whole hearts only (hunger is continuous; leftover can be a tiny float).
		local hearts = math.max(1, math.ceil(empty - 1e-6))
		local dealt = math.min(hearts, reefHealth)
		local wasAlive = reefHealth > 0
		reefHealth = math.max(0, reefHealth - hearts)
		local endPos = if pathData then pathData.endPos else nil
		if agent.isShark and pathDataShark then
			endPos = pathDataShark.endPos
		elseif not agent.isShark and not Path.isGroundCritter(agent) then
			local swim = fishSwimPath(agent)
			if swim then
				endPos = swim.endPos
			end
		elseif Path.isGroundCritter(agent) and agent.groundPath then
			endPos = agent.groundPath.endPos
		end
		L.WaveEndVfx.notifyUnderfedArrival()
		L.WaveEndVfx.playReefHealthTicks(dealt, endPos)
		hungryMissToken += 1
		if dealt > 0 then
			L.UiHaptics.pulseReef()
		end
		-- Final heart: pause, zoom to reef heart, then GAME OVER + Out Of Reef Health UI.
		if wasAlive and reefHealth <= 0 and not defeatBusy then
			defeatBusy = true
			agent.finished = true
			lastStopDefeated = true
			local heartPos = L.WaveEndVfx.getEndHeartWorldPos() or endPos or agent.lastWorld
			lastDefeatOrigin = heartPos
			if not firstVoPlayed.reefEmpty then
				firstVoPlayed.reefEmpty = true
				-- Round over: cut cam / wave explainer / any other narrator immediately.
				L.TutorialVo.playOverride(L.VO_REEF_EMPTY, "OceanTD_ReefEmpty")
			end
			if speedMult > 1e-6 then
				applySpeedPauseState(true)
				speedMult = 0
			end
			notifyHud()
			flushHud()
			local focusAgent = agent
			local lookDir = if heartPos and agent.lastWorld
				then (heartPos - agent.lastWorld)
				else agent.smoothTang
			local defeatFocus = heartPos or agent.lastWorld
			-- Partial-wave $D stream from HUD bar before defeat cam / GAME OVER.
			task.spawn(function()
				L.WaveFeedPayout.playWaveClearStreamAndWait()
				L.ReefDefeatCam.play(defeatFocus, lookDir, function()
					if focusAgent.model and focusAgent.model.Parent then
						destroyFish(focusAgent)
					end
					WaveSim.stop()
				end)
			end)
			return
		end
	else
		fishFed += 1
		markFishFullyFed(agent, nil)
		if not skipHappyVfx and not joinIntroDemo then
			local emoji = agent.happyLabel.Text
			if emoji == "" then
				emoji = C.HAPPY_EMOJIS[1]
			end
			local endPos = if pathData then pathData.endPos else nil
			if agent.isShark and pathDataShark then
				endPos = pathDataShark.endPos
			elseif not agent.isShark and not Path.isGroundCritter(agent) then
				local swim = fishSwimPath(agent)
				if swim then
					endPos = swim.endPos
				end
			end
			if not endPos then
				endPos = L.WaveEndVfx.getEndHeartWorldPos()
			end
			if endPos then
				L.WaveEndVfx.pulseHappyExit(emoji, endPos)
			end
		end
	end
	destroyFish(agent)
	notifyHud()
end

local function spawnOneFish(spawnIndex: number)
	local spec = L.WaveVisitPlan.consumeArmed("host")
	local path = if spec
		then (if spec.route == 2 then pathDataA2 else pathData)
		else pickFishSwimPath()
	if not path then
		return
	end
	local clone, root = WaveEntityPool.acquireFish(WaveEntityPool.FISH_TANG, "Tang_" .. tostring(nextFishId))
	if not clone or not root then
		return
	end
	clone.Parent = ensureFolder()
	-- Wide random school placement (no tight 5-lane file).
	local lateral = if spec then spec.lateral else fishRng:NextNumber(-C.LATERAL_SPREAD, C.LATERAL_SPREAD)
	local vert = if spec then spec.vert else fishRng:NextNumber(-C.VERT_SPREAD, C.VERT_SPREAD)
	local bobAmp = if spec then spec.bobAmp else fishRng:NextNumber(C.BOB_AMP_MIN, C.BOB_AMP_MAX)
	local bobFreq = if spec then spec.bobFreq else fishRng:NextNumber(0.012, 0.032) -- slow vertical jitter
	local bobPhase = if spec then spec.bobPhase else fishRng:NextNumber(0, math.pi * 2)
	local wanderAmp = if spec then spec.wanderAmp else fishRng:NextNumber(C.WANDER_AMP_MIN, C.WANDER_AMP_MAX)
	local wanderFreq = if spec then spec.wanderFreq else fishRng:NextNumber(0.014, 0.038) -- slow side jitter
	local wanderPhase = if spec then spec.wanderPhase else fishRng:NextNumber(0, math.pi * 2)
	local speedPhase = if spec then spec.speedPhase else fishRng:NextNumber(0, math.pi * 2)
	local speedFreq = if spec then spec.speedFreq else fishRng:NextNumber(0.22, 0.55) -- slow surge/coast over the wave
	local pos, tang = Path.samplePath(path, 0)
	local agent: FishAgent = {
		id = nextFishId,
		root = root,
		model = clone,
		dist = 0,
		lateral = lateral,
		vert = vert,
		bobAmp = bobAmp,
		bobFreq = bobFreq,
		bobPhase = bobPhase,
		wanderAmp = wanderAmp,
		wanderFreq = wanderFreq,
		wanderPhase = wanderPhase,
		speedPhase = speedPhase,
		speedFreq = speedFreq,
		hunger = 0,
		maxHunger = C.tangHungerForWave(waveIndex),
		finished = false,
		billboard = nil :: any,
		fill = nil :: any,
		barFrame = nil :: any,
		forkLabel = nil :: any,
		happyLabel = nil :: any,
		remainLabel = nil :: any,
		barScale = nil :: any,
		barStroke = nil :: any,
		pulseToken = 0,
		dangerToken = 0,
		dangerActive = false,
		tapStrokeToken = 0,
		smoothTang = tang.Magnitude > 1e-5 and tang.Unit or Vector3.new(0, 0, -1),
		lastWorld = pos,
		incomingFood = 0,
		bornAt = os.clock(),
		payoutDone = false,
		fedCounted = false,
		isCrab = false,
		isUrchin = false,
		isShark = false,
		swimPath = path,
		crabAnim = nil,
		shellHitbox = nil,
		pauseUntil = nil,
		crabSprint = nil,
	}
	nextFishId += 1
	if spec then
		agent.spawnClock = spec.spawnAt
		agent.visitSlot = spec.slot
	end
	waveFishSpawned += 1
	notifyHud()
	local bb, fill, barFrame, forkLabel, happyLabel, remainLabel, barScale = HungerUi.makeHungerBillboard(root)
	agent.billboard = bb
	agent.fill = fill
	agent.barFrame = barFrame
	agent.forkLabel = forkLabel
	agent.happyLabel = happyLabel
	agent.remainLabel = remainLabel
	agent.barScale = barScale
	local bg = barFrame:FindFirstChild("Bg")
	if bg then
		local stroke = bg:FindFirstChildWhichIsA("UIStroke")
		if stroke then
			agent.barStroke = stroke
		end
	end
	if bb then
		bb.Enabled = HungerUi.critterWorldUiEnabled()
	end
	HungerUi.updateHungerVisual(agent)
	local world0 = Path.fishWorldOffset(agent, pos, tang)
	agent.lastWorld = world0
	setFishCFrame(agent, world0, tang, 1)
	table.insert(fishList, agent)
	attachTapFeedDebug(agent)
end

local function spawnOneCrab(startDist: number?)
	if not WaveCrab.shouldSpawn(waveIndex) then
		return
	end
	local spec = L.WaveVisitPlan.consumeArmed("host")
	local path = if spec
		then (if spec.route == 5 then pathDataGroundB else pathDataGroundA)
		else takePlannedGroundPath()
	if not path then
		return
	end
	local clone, root = WaveEntityPool.acquireFish(WaveEntityPool.FISH_CRAB, "Crab_" .. tostring(nextFishId))
	if not clone or not root then
		return
	end
	clone.Parent = ensureFolder()
	local dist0 = math.clamp(startDist or 0, 0, math.max(0, path.totalLen - 1))
	local pos, tang = WaveCrab.sample(path, dist0)
	local lateral = if spec then spec.lateral else fishRng:NextNumber(-C.CRAB_LATERAL_SPREAD, C.CRAB_LATERAL_SPREAD)
	local wanderAmp = if spec then spec.wanderAmp else fishRng:NextNumber(C.CRAB_WANDER_AMP_MIN, C.CRAB_WANDER_AMP_MAX)
	local wanderFreq = if spec then spec.wanderFreq else fishRng:NextNumber(0.08, 0.18)
	local wanderPhase = if spec then spec.wanderPhase else fishRng:NextNumber(0, math.pi * 2)
	-- Apply lateral before ground snap so spawn matches move loop.
	do
		local side = Vector3.new(-tang.Z, 0, tang.X)
		if side.Magnitude > 1e-4 then
			side = side.Unit
			pos = pos + side * lateral
		end
	end
	pos = WaveCrab.worldOnGround(pos, nil, 1)
	local anim = WaveCrab.bindAnim(clone, root)
	local agent: FishAgent = {
		id = nextFishId,
		root = root,
		model = clone,
		dist = dist0,
		lateral = lateral,
		vert = 0,
		bobAmp = 0,
		bobFreq = 1,
		bobPhase = 0,
		wanderAmp = wanderAmp,
		wanderFreq = wanderFreq,
		wanderPhase = wanderPhase,
		speedPhase = 0,
		speedFreq = 1,
		hunger = 0,
		maxHunger = WaveCrab.hungerForWave(waveIndex),
		finished = false,
		billboard = nil :: any,
		fill = nil :: any,
		barFrame = nil :: any,
		forkLabel = nil :: any,
		happyLabel = nil :: any,
		remainLabel = nil :: any,
		barScale = nil :: any,
		barStroke = nil :: any,
		pulseToken = 0,
		dangerToken = 0,
		dangerActive = false,
		tapStrokeToken = 0,
		smoothTang = tang.Magnitude > 1e-5 and tang.Unit or Vector3.new(0, 0, -1),
		lastWorld = pos,
		incomingFood = 0,
		bornAt = os.clock(),
		payoutDone = false,
		fedCounted = false,
		isCrab = true,
		isUrchin = false,
		isShark = false,
		groundPath = path,
		crabAnim = anim,
		shellHitbox = WaveCrab.findShell(clone),
		pauseUntil = nil,
		stunSkullPart = nil,
		crabSprint = WaveCrab.newSprint(),
	}
	nextFishId += 1
	if spec then
		agent.spawnClock = spec.spawnAt
		agent.visitSlot = spec.slot
	end
	WaveCrab.markSpawned()
	notifyHud()
	local bb, fill, barFrame, forkLabel, happyLabel, remainLabel, barScale = HungerUi.makeHungerBillboard(root, "⚡🍴")
	agent.billboard = bb
	agent.fill = fill
	agent.barFrame = barFrame
	agent.forkLabel = forkLabel
	agent.happyLabel = happyLabel
	agent.remainLabel = remainLabel
	agent.barScale = barScale
	local bg = barFrame:FindFirstChild("Bg")
	if bg then
		local stroke = bg:FindFirstChildWhichIsA("UIStroke")
		if stroke then
			agent.barStroke = stroke
		end
	end
	if bb then
		bb.Enabled = HungerUi.critterWorldUiEnabled()
	end
	HungerUi.updateHungerVisual(agent)
	agent.lastWorld = pos
	setFishCFrame(agent, pos, tang, 1)
	table.insert(fishList, agent)
	attachTapFeedDebug(agent)
	syncGroundPathHearts()
	if not joinIntroDemo and not firstVoPlayed.crab then
		firstVoPlayed.crab = true
		L.TutorialVo.play(L.VO_FIRST_CRAB, "OceanTD_FirstCrab", {
			volume = 4,
			onStart = function()
				L.WaveArrowPreview.fadeOutStartSound(0.45)
			end,
		})
	end

	-- First crab in training only: focus zoom → Plot Cam (never on retries / later waves).
	if trainingCamTeachEnabled()
		and not firstCamTeach.crabFocus
		and waveIndex == C.CRAB_FIRST_WAVE
		and WaveCrab.spawnedCount() == 1
	then
		firstCamTeach.crabFocus = true
		local crabId = agent.id
		task.spawn(function()
			local waitT0 = os.clock()
			while (L.UrchinCam.isBusy() or L.SharkCam.isBusy()) and (os.clock() - waitT0) < 12 do
				task.wait(0.1)
			end
			if not running then
				return
			end
			-- Focus crab, then seat Plot Cam (not Fish Cam / prior seat).
			L.UrchinCam.play(function(): (Vector3?, Vector3?)
				for _, f in ipairs(fishList) do
					if f.id == crabId and not f.finished then
						return f.lastWorld, f.smoothTang
					end
				end
				return nil, nil
			end, {
				resumeMode = "plotcam",
				skipZoomOut = true,
			})
		end)
	end
end

local function spawnOneUrchin(startDist: number?)
	if not WaveUrchin.shouldSpawn(waveIndex) then
		return
	end
	local spec = L.WaveVisitPlan.consumeArmed("host")
	local path = if spec
		then (if spec.route == 5 then pathDataGroundB else pathDataGroundA)
		else takePlannedGroundPath()
	if not path then
		return
	end
	local clone, root = WaveEntityPool.acquireFish(WaveEntityPool.FISH_URCHIN, "Urchin_" .. tostring(nextFishId))
	if not clone or not root then
		return
	end
	clone.Parent = ensureFolder()
	local dist0 = math.clamp(startDist or 0, 0, math.max(0, path.totalLen - 1))
	local pos, tang = WaveUrchin.sample(path, dist0)
	local lateral = if spec then spec.lateral else fishRng:NextNumber(-C.CRAB_LATERAL_SPREAD, C.CRAB_LATERAL_SPREAD)
	local wanderAmp = if spec then spec.wanderAmp else fishRng:NextNumber(C.CRAB_WANDER_AMP_MIN, C.CRAB_WANDER_AMP_MAX)
	local wanderFreq = if spec then spec.wanderFreq else fishRng:NextNumber(0.08, 0.18)
	local wanderPhase = if spec then spec.wanderPhase else fishRng:NextNumber(0, math.pi * 2)
	do
		local side = Vector3.new(-tang.Z, 0, tang.X)
		if side.Magnitude > 1e-4 then
			side = side.Unit
			pos = pos + side * lateral
		end
	end
	pos = WaveUrchin.worldOnGround(pos, nil, 1)
	local agent: FishAgent = {
		id = nextFishId,
		root = root,
		model = clone,
		dist = dist0,
		lateral = lateral,
		vert = 0,
		bobAmp = 0,
		bobFreq = 1,
		bobPhase = 0,
		wanderAmp = wanderAmp,
		wanderFreq = wanderFreq,
		wanderPhase = wanderPhase,
		speedPhase = if spec then spec.speedPhase else WaveUrchin.rollSpeedMult(fishRng), -- walk-speed mult (urchins)
		speedFreq = 1,
		hunger = 0,
		maxHunger = WaveUrchin.hungerForWave(waveIndex),
		finished = false,
		billboard = nil :: any,
		fill = nil :: any,
		barFrame = nil :: any,
		forkLabel = nil :: any,
		happyLabel = nil :: any,
		remainLabel = nil :: any,
		barScale = nil :: any,
		barStroke = nil :: any,
		pulseToken = 0,
		dangerToken = 0,
		dangerActive = false,
		tapStrokeToken = 0,
		smoothTang = tang.Magnitude > 1e-5 and tang.Unit or Vector3.new(0, 0, -1),
		lastWorld = pos,
		incomingFood = 0,
		bornAt = os.clock(),
		payoutDone = false,
		fedCounted = false,
		isCrab = false,
		isUrchin = true,
		isShark = false,
		groundPath = path,
		crabAnim = nil,
		shellHitbox = WaveUrchin.findShell(clone),
		shellLocalCf = nil,
		bodyLocalCf = nil,
		pauseUntil = nil,
		stunSkullPart = nil,
		crabSprint = nil,
	}
	nextFishId += 1
	if spec then
		agent.spawnClock = spec.spawnAt
		agent.visitSlot = spec.slot
	end
	WaveUrchin.markSpawned()
	notifyHud()
	captureUrchinRigLocals(agent)
	local bb, fill, barFrame, forkLabel, happyLabel, remainLabel, barScale = HungerUi.makeHungerBillboard(root, "✴🍴")
	agent.billboard = bb
	agent.fill = fill
	agent.barFrame = barFrame
	agent.forkLabel = forkLabel
	agent.happyLabel = happyLabel
	agent.remainLabel = remainLabel
	agent.barScale = barScale
	local bg = barFrame:FindFirstChild("Bg")
	if bg then
		local stroke = bg:FindFirstChildWhichIsA("UIStroke")
		if stroke then
			agent.barStroke = stroke
		end
	end
	if bb then
		bb.Enabled = HungerUi.critterWorldUiEnabled()
	end
	HungerUi.updateHungerVisual(agent)
	agent.lastWorld = pos
	setFishCFrame(agent, pos, tang, 1)
	-- Re-capture after first pose so locals match the grounded spawn orientation.
	captureUrchinRigLocals(agent)
	table.insert(fishList, agent)
	attachTapFeedDebug(agent)
	syncGroundPathHearts()
	if not joinIntroDemo and not firstVoPlayed.urchin then
		firstVoPlayed.urchin = true
		L.TutorialVo.play(L.VO_FIRST_URCHIN, "OceanTD_FirstUrchin", {
			volume = 4,
			onStart = function()
				L.WaveArrowPreview.fadeOutStartSound(0.45)
			end,
		})
	end

	-- First urchin in training only: focus → path POV tour (never on retries / later waves).
	if trainingCamTeachEnabled()
		and not firstCamTeach.urchinPathTour
		and waveIndex == C.URCHIN_FIRST_WAVE
		and WaveUrchin.spawnedCount() == 1
	then
		firstCamTeach.urchinPathTour = true
		local urchinId = agent.id
		local tourPath = path
		task.defer(function()
			local t0 = os.clock()
			while running and (os.clock() - t0) < PATH_TOUR_PLAY_SEC do
				task.wait()
			end
			-- Wait out first-urchin VO so the path explainer can start with the tour.
			local voDeadline = os.clock() + 45
			while running and L.TutorialVo.isPlaying() and os.clock() < voDeadline do
				task.wait()
			end
			if not running or L.UrchinCam.isBusy() or not tourPath then
				return
			end
			-- Skip W1–W2 and the final waypoint: ride W3 → penultimate.
			local wps = tourPath.waypointDists
			local startDist = if typeof(wps) == "table" and #wps >= 3 then wps[3] else (if typeof(wps) == "table" and #wps >= 2 then wps[2] else 0)
			local endDist = if typeof(wps) == "table" and #wps >= 4
				then wps[#wps - 1]
				else math.max(startDist + 1, tourPath.totalLen * 0.85)
			if endDist <= startDist + 1 then
				endDist = math.max(startDist + 1, tourPath.totalLen * 0.85)
			end
			WaveSim.setCinematicPaused(true)
			L.TutorialVo.play(L.VO_URCHIN_PATH, "OceanTD_UrchinPathExplainer", { volume = 4 })
			L.UrchinCam.playPathTour({
				sample = function(dist: number): (Vector3, Vector3)
					return WaveUrchin.sample(tourPath, dist)
				end,
				startDist = startDist,
				endDist = endDist,
				getFocusPose = function(): (Vector3?, Vector3?)
					for _, f in ipairs(fishList) do
						if f.id == urchinId and not f.finished then
							return f.lastWorld, f.smoothTang
						end
					end
					return nil, nil
				end,
				onEnd = function()
					WaveSim.setCinematicPaused(false, 1)
				end,
			})
		end)
	end
end

local function spawnOneShark()
	if not WaveShark.shouldSpawn(waveIndex) then
		return
	end
	local spec = L.WaveVisitPlan.consumeArmed("host")
	-- At most one live shark: quietly clear any lingerer from a prior ×10 wave.
	for _, f in ipairs(fishList) do
		if f.isShark and not f.finished then
			destroyFish(f)
		end
	end
	notifyHud()
	local path = pathDataShark
	if not path then
		return
	end
	local clone, root = WaveEntityPool.acquireFish(WaveEntityPool.FISH_SHARK, "Shark_" .. tostring(nextFishId))
	if not clone or not root then
		return
	end
	clone.Parent = ensureFolder()
	local pos, tang = WaveShark.sample(path, 0)
	local swayPhase = if spec then spec.bobPhase else fishRng:NextNumber(0, math.pi * 2)
	local agent: FishAgent = {
		id = nextFishId,
		root = root,
		model = clone,
		dist = 0,
		lateral = 0,
		vert = 0,
		bobAmp = 0,
		bobFreq = 1,
		bobPhase = 0,
		wanderAmp = 0,
		wanderFreq = 1,
		wanderPhase = 0,
		speedPhase = 0,
		speedFreq = 1,
		hunger = 0,
		maxHunger = WaveShark.hungerForWave(waveIndex),
		finished = false,
		billboard = nil :: any,
		fill = nil :: any,
		barFrame = nil :: any,
		forkLabel = nil :: any,
		happyLabel = nil :: any,
		remainLabel = nil :: any,
		barScale = nil :: any,
		barStroke = nil :: any,
		pulseToken = 0,
		dangerToken = 0,
		dangerActive = false,
		tapStrokeToken = 0,
		smoothTang = tang.Magnitude > 1e-5 and tang.Unit or Vector3.new(0, 0, -1),
		lastWorld = pos,
		incomingFood = 0,
		bornAt = os.clock(),
		payoutDone = false,
		fedCounted = false,
		isCrab = false,
		isUrchin = false,
		isShark = true,
		crabAnim = nil,
		shellHitbox = nil,
		shellLocalCf = nil,
		bodyLocalCf = nil,
		pauseUntil = nil,
		stunSkullPart = nil,
		crabSprint = nil,
		swayPhase = swayPhase,
	}
	nextFishId += 1
	if spec then
		agent.spawnClock = spec.spawnAt
		agent.visitSlot = spec.slot
	end
	WaveShark.onSpawned(joinIntroDemo)
	notifyHud()
	local bb, fill, barFrame, forkLabel, happyLabel, remainLabel, barScale = HungerUi.makeHungerBillboard(root, "🍴")
	agent.billboard = bb
	agent.fill = fill
	agent.barFrame = barFrame
	agent.forkLabel = forkLabel
	agent.happyLabel = happyLabel
	agent.remainLabel = remainLabel
	agent.barScale = barScale
	local bg = barFrame:FindFirstChild("Bg")
	if bg then
		local stroke = bg:FindFirstChildWhichIsA("UIStroke")
		if stroke then
			agent.barStroke = stroke
		end
	end
	if bb then
		bb.Enabled = HungerUi.critterWorldUiEnabled()
	end
	HungerUi.updateHungerVisual(agent)
	agent.lastWorld = pos
	setFishCFrame(agent, pos, tang, 1)
	table.insert(fishList, agent)
	attachTapFeedDebug(agent)
	syncGroundPathHearts()
	if not joinIntroDemo and not firstVoPlayed.shark then
		firstVoPlayed.shark = true
		L.TutorialVo.play(L.VO_FIRST_SHARK, "OceanTD_FirstShark", {
			volume = 4,
			onStart = function()
				L.WaveArrowPreview.fadeOutStartSound(0.45)
			end,
		})
	end

	-- First shark in training only: zoom to shark as soon as appear VO starts, then path tour.
	if trainingCamTeachEnabled()
		and not firstCamTeach.sharkPathTour
		and waveIndex == C.SHARK_FIRST_WAVE
	then
		firstCamTeach.sharkPathTour = true
		local sharkId = agent.id
		local tourPath = path
		task.defer(function()
			-- Don't wait out the appear VO — focus must steal Plot Cam while it speaks.
			task.wait(0.2)
			local waitT0 = os.clock()
			while (L.UrchinCam.isBusy() or L.SharkCam.isBusy()) and (os.clock() - waitT0) < 12 do
				task.wait(0.1)
			end
			if not running or not tourPath then
				return
			end
			L.WavePathLines.syncHostilePaths()
			local wps = tourPath.waypointDists
			local startDist = if typeof(wps) == "table" and #wps >= 2 then wps[2] else 0
			-- Ride through the final waypoint (don't cut the last WN out of the tour).
			local endDist = if typeof(wps) == "table" and #wps >= 1
				then wps[#wps]
				else tourPath.totalLen
			if endDist <= startDist + 1 then
				endDist = math.max(startDist + 1, tourPath.totalLen)
			end
			WaveSim.setCinematicPaused(true)
			local pg = Players.LocalPlayer and Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
			-- SharkCamBusy + UrchinCamBusy so Plot/Fish FreeCam fully yields for the focus beat.
			if pg then
				pg:SetAttribute("OceanTD_SharkCamBusy", true)
			end
			L.UrchinCam.playPathTour({
				sample = function(dist: number): (Vector3, Vector3)
					return WaveShark.sample(tourPath, dist)
				end,
				startDist = startDist,
				endDist = endDist,
				-- Shark route drops hard early — look at the next WN so pitch follows the hill.
				lookNextWaypoint = true,
				waypointDists = tourPath.waypointDists,
				pathHeight = 2,
				-- Match SharkCam framing (behind + wider) so the focus beat reads.
				focusFromBehind = true,
				focusDist = C.SHARK_CAM_DIST,
				focusHeight = C.SHARK_CAM_HEIGHT,
				focusLookY = 2,
				getFocusPose = function(): (Vector3?, Vector3?)
					for _, f in ipairs(fishList) do
						if f.id == sharkId and not f.finished then
							return f.lastWorld, f.smoothTang
						end
					end
					return nil, nil
				end,
				-- Path explainer after appear VO; focus runs under the first-shark line.
				onPathBegin = function()
					L.TutorialVo.playWhenIdle(L.VO_SHARK_PATH, "OceanTD_SharkPathExplainer", { volume = 4 })
				end,
				onEnd = function()
					if pg and pg.Parent then
						pg:SetAttribute("OceanTD_SharkCamBusy", false)
					end
					WaveSim.setCinematicPaused(false, 1)
				end,
			})
		end)
	end
end

local function waveFishCount(wave: number): number
	-- Half the prior spawn curve (perf); tang hunger was doubled to keep demand similar.
	local full = C.WAVE1_COUNT + (wave - 1) * C.WAVE_COUNT_STEP
	return math.max(1, math.floor(full * 0.5 + 0.5))
end

local function spawnGapForWave(wave: number): number
	local w = math.max(1, math.floor(wave))
	local gap = C.STAGGER_SEC * (C.STAGGER_PER_WAVE_MULT ^ (w - 1))
	return math.max(C.STAGGER_MIN_SEC, gap)
end

local function restoreStunnedCorals(fade: boolean, armAmmo: boolean?)
	local any = false
	local shouldArm = if armAmmo == nil then true else armAmmo
	for _, c in ipairs(coralList) do
		if not c.stunned then
			continue
		end
		any = true
		c.stunned = false
		c.busy = false
		c.growing = false
		if c.part.Parent then
			WaveCrab.clearCoralStun(c.part, fade)
		end
		if shouldArm and running then
			Feed.createAmmo(c, 1) -- also rolls desynced readyAt
		else
			local reload = math.max(0.05, c.reloadSec)
			c.readyAt = simClock + fishRng:NextNumber(0, reload)
		end
	end
	if any then
		markCoralSpatialDirty()
		markCoralBucketsDirty()
	end
end

local function endWave2FullAutoTrial()
	if not wave2FullAutoTrialActive then
		return
	end
	wave2FullAutoTrialActive = false
	L.SkillPowerUpUI.endReloadFullAutoTrial()
end

local function tryOfferWave2FullAutoTrial()
	if wave2FullAutoTrialOffered or joinIntroDemo then
		return
	end
	local pg = Players.LocalPlayer and Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if pg and pg:GetAttribute("OceanTD_FingerTutorialSkipped") == true then
		return
	end
	wave2FullAutoTrialOffered = true
	-- 1 minute of full-auto (HUD countdown); ends on timer or when the run stops.
	if L.SkillPowerUpUI.beginReloadFullAutoTrial(60) then
		wave2FullAutoTrialActive = true
		L.TutorialVo.playWhenIdle(L.VO_TRY_FULL_AUTO_RELOAD, "OceanTD_TryFullAutoReload")
	end
end

local function beginWave(wave: number)
	-- Retry keeps the same wave index. Drop the latched path lead or the
	-- hunger-bar emoji stays stuck at the right edge.
	WaveSim._pathLead = nil
	WaveSim._pathLeadWave = nil
	pruneFinishedFish()
	waveIndex = wave
	if not joinIntroDemo then
		sessionHighestWaveReached = math.max(sessionHighestWaveReached, wave)
	end
	waveFishExpected = waveFishCount(wave)
	waveFishSpawned = 0
	waveFishFullyFed = 0
	L.WaveFeedPayout.onWaveBegin()
	CoralBuckets.clearServingStock()
	-- Join intro: fish + shark only (no crabs / urchins). Live waves share one seed
	-- so visitors can rebuild the same school without a per-fish snapshot.
	if joinIntroDemo then
		L.WaveVisitPlan.clear("host")
		WaveCrab.beginWave(0)
		WaveUrchin.beginWave(0)
	else
		local spawnHold = 0
		if typeof(WaveSim._spawnHold) == "number" and WaveSim._spawnHold > 0 then
			spawnHold = WaveSim._spawnHold
			WaveSim._spawnHold = nil
		end
		L.WaveVisitPlan.begin("host", {
			wave = wave,
			t0 = simClock + spawnHold,
			hasA2 = pathDataA2 ~= nil,
			hasGroundA = pathDataGroundA ~= nil,
			hasGroundB = pathDataGroundB ~= nil,
			hasShark = pathDataShark ~= nil,
		})
		WaveCrab.beginWave(L.WaveVisitPlan.crabCount("host"))
		WaveUrchin.beginWave(L.WaveVisitPlan.urchinCount("host"))
	end
	planHostilePathsForWave()
	-- Red GroundA/B path ribbons when this wave includes crabs/urchins.
	L.WavePathLines.syncHostilePaths()
	restoreStunnedCorals(wave > 1)
	if wave == 2 then
		tryOfferWave2FullAutoTrial()
	end
	-- Wave 3 (first time in training only): pause until cam tap → Fish Cam POV.
	if not joinIntroDemo then
		local pg = Players.LocalPlayer and Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
		if pg then
			local teachWave3 = trainingCamTeachEnabled()
				and not firstCamTeach.wave3FishCam
				and wave == 3
			if teachWave3 then
				firstCamTeach.wave3FishCam = true
				pg:SetAttribute("OceanTD_TutorialGateCam", false)
				-- Re-run LeftHud gate + FreeCam hit raise even if GateCam was already false.
				pg:SetAttribute("OceanTD_RefreshLeftHudGate", os.clock())
				pg:SetAttribute("OceanTD_Wave3FishCamHint", true)
				pg:SetAttribute("OceanTD_Wave3CamHoldPause", true)
				pg:SetAttribute("OceanTD_RollFingerHint", "cam")
				pg:SetAttribute("OceanTD_RefreshCamCycleHits", os.clock())
				WaveSim.setCinematicPaused(true)
			else
				if pg:GetAttribute("OceanTD_Wave3FishCamHint") == true then
					pg:SetAttribute("OceanTD_Wave3FishCamHint", nil)
					if pg:GetAttribute("OceanTD_RollFingerHint") == "cam" then
						pg:SetAttribute("OceanTD_RollFingerHint", false)
					end
				end
				if pg:GetAttribute("OceanTD_Wave3CamHoldPause") == true then
					pg:SetAttribute("OceanTD_Wave3CamHoldPause", nil)
					WaveSim.setCinematicPaused(false)
				end
			end
		end
	end
	-- After W10: roll 20–40% of this wave's Tang onto A2.
	fishA2Remaining = 0
	waveUsesFishA2 = false
	if L.WaveVisitPlan.active("host") then
		fishA2Remaining = L.WaveVisitPlan.a2Remaining("host")
		waveUsesFishA2 = fishA2Remaining > 0
	elseif wave > C.FISH_A2_AFTER_WAVE and pathDataA2 then
		local n = waveFishExpected
		local frac = fishRng:NextNumber(C.FISH_A2_FRAC_MIN, C.FISH_A2_FRAC_MAX)
		fishA2Remaining = math.clamp(math.floor(n * frac + 0.5), 0, n)
		waveUsesFishA2 = fishA2Remaining > 0
	end
	-- Path preview: GreenArrows race the full route; red crab/urchin trains cycle GroundA/B.
	if not joinIntroDemo then
		if wave <= 1 then
			-- Round-start sting only on 2nd+ Start Waves (first overlaps explainer VO).
			L.WaveArrowPreview.start({ playSound = wavesStartCount > 1 })
		else
			L.WaveArrowPreview.start({ playSound = false })
			L.WaveArrowPreview.playWaveAdvanceSound()
		end
		if #hostilePreviewPaths > 0 then
			L.WaveArrowPreview.startRed({
				playSound = false,
				hostilePaths = hostilePreviewPaths,
				onHostileDisplayIndex = function(index: number)
					hostileDisplayIndex = math.max(1, math.floor(index))
					L.WavePathLines.syncHostilePaths()
				end,
			})
		end
	end
	-- Waves 1–2: always Plot Cam (no Fish Cam / Tang overview), including Retry.
	-- Frame W1 → Plot Size stage-2 heart (W4) for every plot size so zoom/seat
	-- matches the stage-2 look instead of pulling out to a far late-stage heart.
	if wave <= 2 and not joinIntroDemo then
		local pg = Players.LocalPlayer and Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
		if pg then
			pg:SetAttribute("OceanTD_ForceCamMode", "plotcam")
			pg:SetAttribute("OceanTD_ForceCamStamp", os.clock())
		end
		local pathForFrame = pathData
		task.defer(function()
			for _ = 1, 12 do
				if L.PlotCam2.isActive() then
					break
				end
				task.wait()
			end
			if not L.PlotCam2.isActive() or not pathForFrame then
				return
			end
			local w1 = Path.samplePath(pathForFrame, 0)
			-- Stage 2 ends at the same waypoint as stage 1 (W4); use that for framing.
			local frameEndWp = L.SkillStages.plotSizeFinalWaypoint(2)
			local heart = pathForFrame.endPos
			local dists = pathForFrame.waypointDists
			if typeof(dists) == "table" and #dists >= frameEndWp then
				local at = dists[frameEndWp]
				if typeof(at) == "number" then
					heart = Path.samplePath(pathForFrame, at)
				end
			end
			if typeof(w1) ~= "Vector3" or typeof(heart) ~= "Vector3" then
				return
			end
			L.PlotCam2.frameWorldPoints({ w1, heart }, 1.05)
			-- Two DistOff notches out from the edge fit (same as wheel zoom-out ×2).
			for _ = 1, 2 do
				L.PlotCam2.nudge("distOffset", L.PlotCam2.distOffsetZoomStep())
			end
			-- Then pan left two notches (same step size as DistOff).
			L.PlotCam2.panFocusBySteps(-2)
		end)
	end
	waveSpawning = true
	spawnQueue = waveFishCount(wave)
	spawnDelay = (if wave == 1 then C.WAVE1_SPAWN_LEAD_SEC else C.ARROW_LEAD_SEC)
		+ (if typeof(WaveSim._spawnHold) == "number" then WaveSim._spawnHold else 0)
	local nUrchin = if joinIntroDemo then 0 else WaveUrchin.expectedCount()
	urchinSpawnQueue = nUrchin
	-- Wave 1: also hold urchins until after the nest-arm window.
	urchinSpawnDelay = if nUrchin > 0
		then (if wave == 1 then C.WAVE1_SPAWN_LEAD_SEC else WaveUrchin.rollFirstDelay(fishRng))
		else 0
	crabSpawnQueue = 0
	crabSpawnDelay = 0
	if L.WaveVisitPlan.active("host") then
		-- Plan owns spawn times. Queues stay empty so the old RNG parade does not double-spawn.
		-- waveSpawning stays true until those future spawns actually happen, or an empty
		-- field counts as a cleared wave and the counter runs away.
		spawnQueue = 0
		urchinSpawnQueue = 0
		crabSpawnQueue = 0
		L.WaveVisitPlan.drain("host", simClock, function(spec)
			L.WaveVisitPlan.arm("host", spec)
			if spec.kind == "tang" then
				spawnOneFish(0)
			elseif spec.kind == "crab" then
				spawnOneCrab(0)
			elseif spec.kind == "urchin" then
				spawnOneUrchin(0)
			else
				spawnOneShark()
			end
		end)
		waveSpawning = L.WaveVisitPlan.remaining("host") > 0
	elseif WaveShark.shouldSpawn(wave) then
		spawnOneShark()
	end
	-- Session start: arm all corals (staggered nest orbs). Later waves: keep reload state; only pick up new places.
	if wave == 1 then
		Feed.clearAmmoArmQueue()
		Feed.clearPathStamp()
	end
	syncCorals(wave == 1)
	local path = pathData
	if path and #path.segments > 0 and not joinIntroDemo then
		L.WaveStartVfx.play(wave, path.segments[1].w0, {
			fish = waveFishExpected,
			crabs = WaveCrab.expectedCount(),
			urchins = WaveUrchin.expectedCount(),
			sharks = WaveShark.countForWave(wave),
		})
	end
	if wave == 1 and not joinIntroDemo then
		L.Wave1LeadArrow.start(function()
			local fish = WaveSim.getFurthestLiveFish()
			return if fish then fish.position else nil
		end)
	else
		L.Wave1LeadArrow.stop()
	end
	notifyHud()
end

function Feed.rebuildFishPathBuckets()
	for i = 1, #fishPathBuckets do
		table.clear(fishPathBuckets[i])
	end
	local path = pathData
	if not path or path.totalLen < 1 then
		return
	end
	local maxBi = math.max(1, math.ceil(path.totalLen / C.PATH_BUCKET_SIZE) + 1)
	while #fishPathBuckets < maxBi do
		table.insert(fishPathBuckets, {})
	end
	for _, f in ipairs(fishList) do
		-- Skip if already full or in-flight food will fill them.
		if f.finished or Path.isGroundCritter(f) or f.isShark or f.hunger + f.incomingFood >= f.maxHunger then
			continue
		end
		-- A2 fish aren't on the A path-distance axis — target via world fallback.
		if f.swimPath and pathData and f.swimPath ~= pathData then
			continue
		end
		local bi = math.clamp(math.floor(f.dist / C.PATH_BUCKET_SIZE) + 1, 1, maxBi)
		table.insert(fishPathBuckets[bi], f)
	end
end

function Feed.fishNeedsFood(f: FishAgent, fill: number): boolean
	return (not f.finished) and (f.hunger + f.incomingFood + fill <= f.maxHunger)
end

function Feed.findClosestHungryFish(coral: CoralAgent): FishAgent?
	local path = pathData
	if not path then
		return nil
	end
	local fill = coral.foodFill
	local cd = coral.pathDist
	local lead = math.max(C.PATH_TARGET_LEAD_MAX, coral.range)
	local d0 = math.max(0, cd - lead)
	local d1 = math.min(path.totalLen, cd + C.PATH_TARGET_PAST)
	local b0 = math.floor(d0 / C.PATH_BUCKET_SIZE) + 1
	local b1 = math.floor(d1 / C.PATH_BUCKET_SIZE) + 1
	local origin = coral.part.Position
	local best: FishAgent? = nil
	local bestScore = coral.rangeSq
	local laneOk = coral.pathSideDist <= coral.range + C.LATERAL_SPREAD

	local function consider(f: FishAgent)
		if not Feed.fishNeedsFood(f, fill) then
			return
		end
		local fp = f.root.Position
		local dx = fp.X - origin.X
		local dy = fp.Y - origin.Y
		local dz = fp.Z - origin.Z
		local d2 = dx * dx + dy * dy + dz * dz
		if d2 > coral.rangeSq then
			return
		end
		local score = d2
		-- Mild Tang preference only — old 0.4x made mid-range fish beat adjacent urchins.
		-- Ground critters use raw distance so a nest next to an urchin will feed it.
		if f.isShark then
			score *= 1.05
		elseif not Path.isGroundCritter(f) then
			if f.dist >= cd - 1 then
				score *= 0.7
			elseif f.dist < cd then
				score *= 0.85
			end
		end
		if score < bestScore then
			bestScore = score
			best = f
		end
	end

	if laneOk then
		for bi = b0, b1 do
			local bucket = fishPathBuckets[bi]
			if bucket then
				for _, f in ipairs(bucket) do
					consider(f)
				end
			end
		end
		if not best then
			for _, f in ipairs(fishList) do
				if not Path.isGroundCritter(f) and not f.isShark then
					consider(f)
				end
			end
		elseif pathDataA2 and waveUsesFishA2 then
			for _, f in ipairs(fishList) do
				if f.swimPath and pathData and f.swimPath ~= pathData then
					consider(f)
				end
			end
		end
	else
		-- Off swim-lane (common near Ground routes): still allow Tang in world range.
		for _, f in ipairs(fishList) do
			if not Path.isGroundCritter(f) and not f.isShark then
				consider(f)
			end
		end
	end
	-- Always score sharks / urchins / crabs (do not wait until no fish — hairpins often
	-- leave a Tang in range while an urchin is sitting on the nest).
	for _, f in ipairs(fishList) do
		if f.isShark then
			consider(f)
		end
	end
	for _, f in ipairs(fishList) do
		if f.isUrchin then
			consider(f)
		end
	end
	for _, f in ipairs(fishList) do
		if f.isCrab then
			consider(f)
		end
	end
	return best
end

function Feed.fireShot(coral: CoralAgent, target: FishAgent)
	if WaveSim.tooYoungToFeed(target) then
		return
	end
	local orb = coral.ammoSlots[1]
	local start = if orb then orb.Position else Feed.ammoWorldPos(coral, 1)
	if orb then
		WaveEntityPool.releaseAmmo(orb)
		table.remove(coral.ammoSlots, 1)
		coral.ammo = coral.ammoSlots[1]
		Feed.parkAmmo(coral)
	end
	local fp = target.root.Position
	local flatX = fp.X - start.X
	local flatZ = fp.Z - start.Z
	local flat = math.sqrt(flatX * flatX + flatZ * flatZ)
	-- Estimate duration from distance; prediction uses the fish's live speed curve.
	local speedNow = (if target.isUrchin
		then WaveUrchin.speedNow() * target.speedPhase
		elseif target.isCrab then WaveCrab.speedNow(target.crabSprint, simClock)
		elseif target.isShark then WaveShark.speed()
		else C.FISH_SPEED) * math.max(0.55, Path.fishSpeedFactorAt(target, simClock))
	local duration = math.clamp(flat / speedNow + C.FOOD_FIRE_LEAD_SEC, C.FOOD_RISE_MIN, C.FOOD_RISE_MAX)
	local meet = Path.predictFishMeetPos(target, duration, simClock, pathDataShark, pathDataGroundA, pathDataGroundB, fishSwimPath(target))
	-- Near route end (or bad predict): still fire at the live mouth — don't let them ghost past.
	if not meet then
		meet = Path.fishMouthWorld(target)
		duration = math.clamp(duration * 0.65, C.FOOD_RISE_MIN * 0.75, C.FOOD_RISE_MAX)
	end

	coral.shotsOut += 1
	target.incomingFood += coral.foodFill
	local part: BasePart? = nil
	if Feed.shotWantsVisual(start, meet) then
		part = Feed.acquireFoodPart()
		part.Color = coral.color
		part.Transparency = 0
		part.CFrame = CFrame.new(start)
		visibleShotCount += 1
	end
	local shot: FoodShot = {
		part = part,
		target = target,
		fill = coral.foodFill,
		coral = coral,
		alive = true,
		age = 0,
		duration = duration,
		startPos = start,
		meetPos = meet,
		swayPhase = fishRng:NextNumber(0, math.pi * 2),
	}
	table.insert(activeShots, shot)
end

function Feed.clearShotTarget(shot: FoodShot)
	local target = shot.target
	if target then
		target.incomingFood = math.max(0, target.incomingFood - shot.fill)
		shot.target = nil
	end
end

function Feed.finishShot(shot: FoodShot, fed: boolean)
	shot.alive = false
	if shot.visualOnly then
		if fed then
			HungerUi.playFeedSound()
		end
		Feed.releaseShotVisual(shot)
		return
	end
	if shot.playerTap then
		local target = shot.target
		Feed.clearShotTarget(shot)
		if fed and target and not target.finished and shot.fill > 0 and target.hunger < target.maxHunger then
			target.hunger = math.min(target.maxHunger, target.hunger + shot.fill)
			if (not target.payoutDone) and target.hunger >= target.maxHunger then
				target.payoutDone = true
				L.WaveFeedPayout.noteFilled(target.root.Position)
			end
			if target.hunger >= target.maxHunger then
				markFishFullyFed(target, nil)
			end
			HungerUi.updateHungerVisual(target)
			HungerUi.playFeedSound()
		end
		Feed.releaseShotVisual(shot)
		return
	end
	local coral = shot.coral
	if not coral then
		Feed.clearShotTarget(shot)
		Feed.releaseShotVisual(shot)
		return
	end
	coral.shotsOut = math.max(0, coral.shotsOut - 1)
	if coral.shotsOut <= 0 and #coral.ammoSlots == 0 then
		coral.busy = false
		Feed.startAmmoGrow(coral)
	end
	local target = shot.target
	Feed.clearShotTarget(shot)
	if fed and target and not target.finished and target.hunger < target.maxHunger then
		target.hunger = math.min(target.maxHunger, target.hunger + shot.fill)
		-- Every successful food hit counts as a Fed for this coral (not only the finishing fill).
		creditCoralFeed(coral)
		if (not target.payoutDone) and target.hunger >= target.maxHunger then
			target.payoutDone = true
			L.WaveFeedPayout.noteFilled(target.root.Position)
		end
		if target.hunger >= target.maxHunger then
			markFishFullyFed(target, coral)
		end
		HungerUi.updateHungerVisual(target)
		HungerUi.playFeedSound()
	end
	Feed.releaseShotVisual(shot)
end

-- Player click/tap: food orb from camera → fish (2× coral orb speed).
function Feed.firePlayerTap(target: FishAgent, start: Vector3): boolean
	if target.finished or not target.model.Parent or WaveSim.tooYoungToFeed(target) then
		return false
	end
	local hungry = target.hunger < target.maxHunger
	local fill = if hungry then C.DEFAULT_FOOD_FILL else 0
	local visualOnly = not hungry
	local fp = target.root.Position
	local flatX = fp.X - start.X
	local flatZ = fp.Z - start.Z
	local flat = math.sqrt(flatX * flatX + flatZ * flatZ)
	local speedNow = (if target.isUrchin
		then WaveUrchin.speedNow() * target.speedPhase
		elseif target.isCrab then WaveCrab.speedNow(target.crabSprint, simClock)
		elseif target.isShark then WaveShark.speed()
		else C.FISH_SPEED) * math.max(0.55, Path.fishSpeedFactorAt(target, simClock))
	local flightMult = C.TAP_FEED_FLIGHT_MULT or 0.5
	local duration = math.clamp(flat / speedNow + C.FOOD_FIRE_LEAD_SEC, C.FOOD_RISE_MIN, C.FOOD_RISE_MAX) * flightMult
	local meet = Path.predictFishMeetPos(target, duration, simClock, pathDataShark, pathDataGroundA, pathDataGroundB, fishSwimPath(target))
	if not meet then
		meet = Path.fishMouthWorld(target)
		duration = math.clamp(duration * 0.65, (C.FOOD_RISE_MIN * 0.75) * flightMult, C.FOOD_RISE_MAX * flightMult)
	end
	if hungry then
		target.incomingFood += fill
	end
	local part: BasePart? = nil
	-- Always try to show player taps (feedback); fall back to logic-only at cap.
	if Feed.shotWantsVisual(start, meet) or visibleShotCount < C.FOOD_VISIBLE_MAX then
		part = Feed.acquireTapFoodPart()
		part.Color = Color3.fromHSV(fishRng:NextNumber(), 0.9, 1)
		part.Transparency = 0
		part.CFrame = CFrame.new(start)
		visibleShotCount += 1
	end
	table.insert(activeShots, {
		part = part,
		target = target,
		fill = fill,
		coral = nil,
		alive = true,
		age = 0,
		duration = duration,
		startPos = start,
		meetPos = meet,
		swayPhase = fishRng:NextNumber(0, math.pi * 2),
		visualOnly = visualOnly,
		playerTap = true,
	})
	if not joinIntroDemo then
		local pitch = fishRng:NextNumber(C.TAP_FEED_FIRE_PITCH_MIN or 0.85, C.TAP_FEED_FIRE_PITCH_MAX or 1.2)
		WaveEntityPool.playSound("tapFeedFire", tapFeedFireSound, pitch, 0.9)
	end
	return true
end

-- lane_stock: nest ammo stays parked; a copy flies to the fish that just drank this coral's stock.
function Feed.fireLaneFeedVisual(coral: CoralAgent, target: FishAgent)
	local start = Feed.ammoWorldPos(coral, 1)
	local fp = target.root.Position
	local flatX = fp.X - start.X
	local flatZ = fp.Z - start.Z
	local flat = math.sqrt(flatX * flatX + flatZ * flatZ)
	local speedNow = (if target.isUrchin
		then WaveUrchin.speedNow() * target.speedPhase
		elseif target.isCrab then WaveCrab.speedNow(target.crabSprint, simClock)
		elseif target.isShark then WaveShark.speed()
		else C.FISH_SPEED) * math.max(0.55, Path.fishSpeedFactorAt(target, simClock))
	local duration = math.clamp(flat / speedNow + C.FOOD_FIRE_LEAD_SEC, C.FOOD_RISE_MIN, C.FOOD_RISE_MAX)
	local meet = Path.predictFishMeetPos(target, duration, simClock, pathDataShark, pathDataGroundA, pathDataGroundB, fishSwimPath(target))
	if not meet then
		meet = Path.fishMouthWorld(target)
		duration = math.clamp(duration * 0.65, C.FOOD_RISE_MIN * 0.75, C.FOOD_RISE_MAX)
	end
	local part = Feed.acquireFoodPart()
	part.Color = coral.color
	part.Transparency = 0
	part.CFrame = CFrame.new(start)
	visibleShotCount += 1
	table.insert(activeShots, {
		part = part,
		target = target,
		fill = 0,
		coral = coral,
		alive = true,
		age = 0,
		duration = duration,
		startPos = start,
		meetPos = meet,
		swayPhase = fishRng:NextNumber(0, math.pi * 2),
		visualOnly = true,
	})
end

-- Cheap feedback: lift this nest's existing ammo orbs together (no new Parts).
function Feed.pulseNestRise(coral: CoralAgent)
	if coral.stunned or #coral.ammoSlots < 1 then
		return
	end
	Feed._ammoFade[coral] = nil -- nest rise owns Transparency
	Feed._risePulses[coral] = {
		t0 = simClock,
		riseDur = math.max(0.5, C.LANE_NEST_RISE_SEC or 2.2),
		holdDur = math.max(0.05, C.LANE_NEST_HOLD_SEC or 0.4),
	}
end

function Feed.clearNestRise(coral: CoralAgent)
	if Feed._risePulses[coral] then
		Feed._risePulses[coral] = nil
		for _, part in ipairs(coral.ammoSlots) do
			if part.Parent then
				part.Transparency = 0
			end
		end
		Feed.parkAmmo(coral)
	end
end

function Feed.clearAllNestRises()
	for coral in pairs(Feed._risePulses) do
		Feed._risePulses[coral] = nil
		if coral.part and coral.part.Parent then
			for _, part in ipairs(coral.ammoSlots) do
				if part.Parent then
					part.Transparency = 0
				end
			end
			Feed.parkAmmo(coral)
		end
	end
	table.clear(Feed._risePulses)
end

function Feed.tickNestRisePulses()
	local pulses = Feed._risePulses
	local any = false
	for _ in pairs(pulses) do
		any = true
		break
	end
	if not any then
		return
	end
	local riseH = math.max(8, C.LANE_NEST_RISE_STUDS or 72)
	local fadeStart = math.clamp(C.LANE_NEST_FADE_START or 0.55, 0, 0.95)
	local fadeEnd = math.clamp(C.LANE_NEST_FADE_END or 0.92, fadeStart + 0.05, 1)
	local slotGap = math.max(0, C.LANE_NEST_SLOT_STAGGER or 0.28)
	local parts = Feed._riseParts
	local cfs = Feed._riseCFs
	local done = Feed._riseDone
	table.clear(parts)
	table.clear(cfs)
	table.clear(done)
	local now = simClock
	for coral, pulse in pairs(pulses) do
		if coral.stunned or not coral.part.Parent or #coral.ammoSlots < 1 then
			table.insert(done, coral)
			continue
		end
		local n = #coral.ammoSlots
		local age = now - pulse.t0
		local riseDur = pulse.riseDur
		local holdDur = pulse.holdDur
		-- Last slot starts at (n-1)*gap; pulse ends when that slot finishes hold.
		local total = riseDur + holdDur + slotGap * math.max(0, n - 1)
		if age >= total then
			table.insert(done, coral)
			continue
		end
		-- Same rise speed per slot; start times staggered for a cascade look.
		for si, part in ipairs(coral.ammoSlots) do
			if not part.Parent then
				continue
			end
			local slotAge = age - slotGap * (si - 1)
			local home = Feed.ammoWorldPos(coral, si)
			local y = 0
			local fade = 0
			if slotAge <= 0 then
				-- waiting to launch
			elseif slotAge < riseDur then
				local u = slotAge / riseDur
				y = riseH * u
				if u <= fadeStart then
					fade = 0
				elseif u >= fadeEnd then
					fade = 1
				else
					fade = (u - fadeStart) / (fadeEnd - fadeStart)
				end
			elseif slotAge < riseDur + holdDur then
				y = riseH
				fade = 1
			else
				-- this slot finished — leave parked until coral pulse ends
				part.Transparency = 0
				table.insert(parts, part)
				table.insert(cfs, CFrame.new(home))
				continue
			end
			part.Transparency = fade * 0.98
			table.insert(parts, part)
			table.insert(cfs, CFrame.new(home.X, home.Y + y, home.Z))
		end
	end
	for _, coral in ipairs(done) do
		pulses[coral] = nil
		Feed.parkAmmo(coral)
		Feed.applyCoralShareLook(coral)
	end
	if #parts > 0 then
		Workspace:BulkMoveTo(parts, cfs, Enum.BulkMoveMode.FireCFrameChanged)
	end
end

-- Rise share ramps wave LANE_RISE_RAMP_START → END (all fish-aim → 50/50).
-- Under FOOD_CULL_MIN_CORALS: always tween food to the fish (no nest-rise substitute).
function Feed.triggerLaneFeedVisual(coral: CoralAgent, target: FishAgent)
	if placedCoralCount <= (C.FOOD_CULL_MIN_CORALS or 100) then
		Feed.fireLaneFeedVisual(coral, target)
		return
	end
	local w0 = C.LANE_RISE_RAMP_START or 20
	local w1 = math.max(w0 + 1, C.LANE_RISE_RAMP_END or 50)
	local fishEnd = math.clamp(C.LANE_FISH_AIM_FRAC_END or 0.5, 0, 1)
	local fishFrac = 1
	if waveIndex >= w0 then
		if waveIndex >= w1 then
			fishFrac = fishEnd
		else
			local t = (waveIndex - w0) / (w1 - w0)
			fishFrac = 1 + (fishEnd - 1) * t
		end
	end
	if fishRng:NextNumber() < fishFrac then
		Feed.fireLaneFeedVisual(coral, target)
	else
		Feed.pulseNestRise(coral)
	end
end

function Feed.coralCoversFishLane(coral: CoralAgent, agent: FishAgent, route: number): boolean
	if coral.stunned or not coral.part.Parent then
		return false
	end
	local origin = coral.part.Position
	local fp = agent.root.Position
	local dx = fp.X - origin.X
	local dy = fp.Y - origin.Y
	local dz = fp.Z - origin.Z
	if dx * dx + dy * dy + dz * dz > coral.rangeSq then
		return false
	end
	local buckets = coral.routeBuckets and coral.routeBuckets[route]
	if not buckets or #buckets < 1 then
		return true -- range-only fallback
	end
	local path = routePaths[route]
	local maxBi = if path then math.max(1, math.ceil(path.totalLen / C.PATH_BUCKET_SIZE) + 1) else 1
	local bi = math.clamp(math.floor(math.max(0, agent.dist) / C.PATH_BUCKET_SIZE) + 1, 1, maxBi)
	for _, b in ipairs(buckets) do
		if math.abs(b - bi) <= 1 then
			return true
		end
	end
	return false
end

function Feed.findLanePulseCoral(agent: FishAgent, route: number): CoralAgent?
	local bestReady: CoralAgent? = nil
	local bestReadyD2 = math.huge
	local bestAny: CoralAgent? = nil
	local bestAnyD2 = math.huge
	local fp = agent.root.Position
	for _, coral in ipairs(coralList) do
		if not Feed.coralCoversFishLane(coral, agent, route) then
			continue
		end
		local origin = coral.part.Position
		local dx = fp.X - origin.X
		local dy = fp.Y - origin.Y
		local dz = fp.Z - origin.Z
		local d2 = dx * dx + dy * dy + dz * dz
		if coral.lanePulseReady and d2 < bestReadyD2 then
			bestReadyD2 = d2
			bestReady = coral
		end
		if d2 < bestAnyD2 then
			bestAnyD2 = d2
			bestAny = coral
		end
	end
	-- Prefer a nest that just restocked (for the food visual); else nearest covering coral.
	return bestReady or bestAny
end

-- Option 2: corals restock capped lane stock on reload; fish drink front-first.
function Feed.tickLaneStock(dt: number)
	ensureCoralPathBucketIndex()
	refreshRoutePaths()
	local now = simClock
	-- Restock: each ready nest deposits foodFill at its nearest covered sample.
	for _, coral in ipairs(coralList) do
		if coral.stunned or not coral.part.Parent then
			continue
		end
		if now < coral.readyAt then
			continue
		end
		if CoralBuckets.restockFromCoral(coral) then
			coral.lanePulseReady = true
		end
		local reload = math.max(0.05, coral.reloadSec)
		-- Desync reloads so nests don't all restock/reload on the same beat.
		coral.readyAt = now + reload * fishRng:NextNumber(0.65, 1.35)
	end

	CoralBuckets.clearHungryScratch(routePaths)
	for _, f in ipairs(fishList) do
		if f.finished or f.hunger >= f.maxHunger then
			continue
		end
		if WaveSim.tooYoungToFeed(f) then
			continue
		end
		local route = resolveFeedRoute(f)
		if route then
			CoralBuckets.noteHungry(route, f.dist, f)
		end
	end

	local drinkCap = C.LANE_DRINK_PER_SEC * dt
	if joinIntroDemo then
		drinkCap *= 0.5
	end
	local fedSound = false
	CoralBuckets.eachHungryFrontFirst(function(f: any, route: number)
		local agent = f :: FishAgent
		if agent.finished or agent.hunger >= agent.maxHunger then
			return
		end
		local need = agent.maxHunger - agent.hunger
		local want = math.min(need, drinkCap)
		local got = CoralBuckets.drinkStock(route, agent.dist, want)
		if got <= 0 then
			return
		end
		agent.hunger = math.min(agent.maxHunger, agent.hunger + got)
		local pulseCoral = Feed.findLanePulseCoral(agent, route)
		if (not agent.payoutDone) and agent.hunger >= agent.maxHunger then
			agent.payoutDone = true
			L.WaveFeedPayout.noteFilled(agent.root.Position)
		end
		if agent.hunger >= agent.maxHunger then
			markFishFullyFed(agent, pulseCoral)
		end
		HungerUi.updateHungerVisual(agent)
		fedSound = true
		-- Lane stock sips every frame; only count a Fed when a nest fires its food visual
		-- (one credit per restock → drink pairing), not per continuous sip tick.
		if pulseCoral and pulseCoral.lanePulseReady then
			pulseCoral.lanePulseReady = false
			creditCoralFeed(pulseCoral)
			Feed.triggerLaneFeedVisual(pulseCoral, agent)
		end
	end)
	if fedSound and fishRng:NextNumber() < 0.05 then
		HungerUi.playFeedSound()
	end
end

function Feed.tickCombat()
	if C.FEED_MODE ~= "volleys" then
		return
	end
	local now = simClock
	local anyHungry = false
	for _, f in ipairs(fishList) do
		if not f.finished and f.hunger < f.maxHunger then
			anyHungry = true
			break
		end
	end
	if not anyHungry then
		return
	end
	Feed.rebuildFishPathBuckets()
	ensureCoralPathBucketIndex()
	ensureCoralSpatialHash()

	-- Empty-nest recovery for everyone (cheap); combat candidates come from stamps.
	for _, coral in ipairs(coralList) do
		if coral.stunned or coral.growing then
			continue
		end
		if now < coral.readyAt then
			continue
		end
		if #coral.ammoSlots == 0 then
			if coral.shotsOut <= 0 then
				coral.busy = false
				Feed.startAmmoGrow(coral)
			end
		end
	end

	combatCollectGen += 1
	local gen = combatCollectGen
	-- Option 1 wake: multi-route path stamps + spatial hash for Shark/Ground wander.
	CoralBuckets.wakeFromHungry(
		coralByRouteBucket,
		coralSpatial,
		C.HASH_CELL,
		fishList,
		gen,
		resolveFeedRoute,
		isOffSwimHungry
	)

	table.clear(combatReady)
	for _, coral in ipairs(coralList) do
		if coral.combatGen ~= gen then
			continue
		end
		if coral.stunned or coral.growing then
			continue
		end
		if now < coral.readyAt or #coral.ammoSlots == 0 then
			continue
		end
		table.insert(combatReady, coral)
	end

	local nReady = #combatReady
	if nReady < 1 then
		return
	end
	table.sort(combatReady, function(a: CoralAgent, b: CoralAgent)
		return a.combatScore < b.combatScore
	end)

	local budget = C.COMBAT_FIRE_BUDGET
	local poolN = math.min(nReady, math.max(budget, budget * 2))
	if nReady <= budget then
		for i = 1, nReady do
			local coral = combatReady[i]
			local target = Feed.findClosestHungryFish(coral)
			if target then
				Feed.fireShot(coral, target)
			end
		end
		return
	end

	local start = combatFireCursor
	if start < 1 or start > poolN then
		start = 1
	end
	local attempts = 0
	for offset = 0, poolN - 1 do
		if attempts >= budget then
			break
		end
		local coral = combatReady[((start - 1 + offset) % poolN) + 1]
		attempts += 1
		local target = Feed.findClosestHungryFish(coral)
		if target then
			Feed.fireShot(coral, target)
		end
	end
	combatFireCursor = (start + budget - 1) % poolN + 1
end

function Feed.tickShots(dt: number)
	local i = 1
	while i <= #activeShots do
		local shot = activeShots[i]
		if not shot.alive then
			table.remove(activeShots, i)
			continue
		end
		local target = shot.target
		-- Miss / aim visuals: fly start → meetPos for duration, then fade out (many can be airborne).
		if not target then
			shot.age += dt
			local flightDur = math.max(0.05, shot.duration)
			local fadeDur = math.max(0.05, C.TAP_FEED_MISS_FADE_SEC or 0.45)
			local u = shot.age / flightDur
			local foodPos = Path.foodFlightPos(shot, math.min(u, 1), shot.meetPos)
			local vis = shot.part
			if vis then
				vis.CFrame = CFrame.new(foodPos)
				if shot.age > flightDur then
					vis.Transparency = math.clamp((shot.age - flightDur) / fadeDur, 0, 1)
				end
			end
			if shot.age >= flightDur + fadeDur then
				Feed.finishShot(shot, false)
				table.remove(activeShots, i)
			else
				i += 1
			end
			continue
		end
		if target.finished or not target.model.Parent then
			Feed.finishShot(shot, false)
			table.remove(activeShots, i)
			continue
		end

		shot.age += dt
		local u = shot.age / math.max(0.05, shot.duration)
		local mouth = Path.fishMouthWorld(target)
		local meet = shot.meetPos
		local homeStart = C.FOOD_HOME_START_U
		if u > homeStart then
			local homeT = math.clamp((u - homeStart) / math.max(1e-3, 1 - homeStart), 0, 1)
			homeT = homeT * homeT
			meet = shot.meetPos:Lerp(mouth, homeT)
		end
		local foodPos = Path.foodFlightPos(shot, math.min(u, 1), meet)
		local vis = shot.part
		if vis then
			vis.CFrame = CFrame.new(foodPos)
		end

		if Path.fishCanEatFood(foodPos, mouth) or Path.fishCanEatFood(foodPos, target.root.Position) then
			Feed.finishShot(shot, true)
			table.remove(activeShots, i)
			continue
		end

		if u >= 1 then
			local fed = Path.fishCanEatFood(foodPos, mouth, C.FOOD_END_GRACE_RADIUS_SQ, C.FOOD_END_GRACE_Y)
				or Path.fishCanEatFood(foodPos, target.root.Position, C.FOOD_END_GRACE_RADIUS_SQ, C.FOOD_END_GRACE_Y)
			-- Player taps are intentional help-feeds: always credit once the orb finishes its flight.
			if shot.playerTap then
				fed = true
			end
			Feed.finishShot(shot, fed)
			table.remove(activeShots, i)
			continue
		end
		i += 1
	end
end

local function findCoralByPart(part: BasePart): CoralAgent?
	for _, c in ipairs(coralList) do
		if c.part == part then
			return c
		end
	end
	return nil
end

local function reviveCoralFromAttack(coral: CoralAgent)
	if not coral.stunned then
		return
	end
	coral.stunned = false
	coral.busy = false
	coral.growing = false
	markCoralSpatialDirty()
	markCoralBucketsDirty()
	if coral.part.Parent then
		WaveCrab.clearCoralStun(coral.part, true)
	end
	if running then
		Feed.createAmmo(coral, 1) -- also rolls desynced readyAt
	else
		local reload = math.max(0.05, coral.reloadSec)
		coral.readyAt = simClock + fishRng:NextNumber(0, reload)
	end
end

local function abortCrabCoralKill(agent: FishAgent)
	local part = agent.stunSkullPart
	agent.stunSkullPart = nil
	agent.pauseUntil = nil
	if part then
		local coral = findCoralByPart(part)
		if coral then
			reviveCoralFromAttack(coral)
		elseif part.Parent then
			WaveCrab.clearCoralStun(part, true)
		end
	end
end

local function stunCoralFromCrab(coral: CoralAgent)
	if coral.stunned then
		return
	end
	coral.stunned = true
	coral.growing = false
	coral.busy = false
	markCoralSpatialDirty()
	markCoralBucketsDirty()
	coral.readyAt = math.huge
	Feed.destroyAmmo(coral)
	if coral.part.Parent then
		WaveCrab.stunCoralPart(coral.part)
	end
	for _, shot in ipairs(activeShots) do
		if shot.alive and shot.coral == coral then
			Feed.finishShot(shot, false)
		end
	end
end

local function tickFish(dt: number)
	local sharkPath = pathDataShark
	for _, agent in ipairs(fishList) do
		if agent.finished then
			continue
		end
		if agent.isShark then
			if not sharkPath then
				finishFish(agent)
				continue
			end
			agent.dist = if agent.spawnClock
				then L.WaveVisitPlan.closedDist(agent, simClock)
				else agent.dist + WaveShark.speed() * dt
			if agent.dist >= sharkPath.totalLen then
				-- Snap to path end so defeat cam focuses the shark, not a stale mid-route pose.
				local endPos, endTang = WaveShark.sample(sharkPath, sharkPath.totalLen)
				local swimTang = Path.stepSwimTang(agent, endTang, dt)
				setFishCFrame(agent, endPos, swimTang, dt)
				finishFish(agent)
				continue
			end
			local pos, tang = WaveShark.sample(sharkPath, agent.dist)
			local swimTang = Path.stepSwimTang(agent, tang, dt)
			setFishCFrame(agent, pos, swimTang, dt)
			local hungry = agent.hunger < agent.maxHunger
			HungerUi.setDangerFlash(agent, hungry and Path.isNearPathEnd(sharkPath.totalLen, agent.dist))
			continue
		end
		if Path.isGroundCritter(agent) then
			local ground = agent.groundPath
			if not ground then
				finishFish(agent)
				continue
			end
			local isCrab = agent.isCrab == true
			local wasFighting = agent.pauseUntil ~= nil
			local paused = wasFighting and os.clock() < (agent.pauseUntil :: number)
			-- Fed mid-fight: drop the attack, restore the coral, keep walking.
			if paused and agent.hunger >= agent.maxHunger then
				abortCrabCoralKill(agent)
				paused = false
				wasFighting = false
			end
			if not paused then
				if wasFighting then
					local skullPart = agent.stunSkullPart
					agent.stunSkullPart = nil
					if skullPart and agent.hunger < agent.maxHunger then
						WaveCrab.playDeathSkullFromCoral(skullPart)
					elseif skullPart then
						local coral = findCoralByPart(skullPart)
						if coral then
							reviveCoralFromAttack(coral)
						elseif skullPart.Parent then
							WaveCrab.clearCoralStun(skullPart, true)
						end
					end
				end
				agent.pauseUntil = nil
				if isCrab then
					local sprint = agent.crabSprint
					if sprint then
						WaveCrab.tickSprint(sprint, simClock)
					end
					agent.dist += WaveCrab.speedNow(sprint, simClock) * dt
				else
					agent.dist += WaveUrchin.speedNow() * agent.speedPhase * dt
				end
			end
			if agent.dist >= ground.totalLen then
				finishFish(agent)
				continue
			end
			local pathPos, tang = WaveCrab.sample(ground, agent.dist)
			local swimTang = Path.stepSwimTang(agent, tang, dt)
			local offset = Path.fishWorldOffset(agent, pathPos, swimTang, agent.dist)
			local pos = WaveCrab.worldOnGround(offset, agent.lastWorld.Y, dt)
			if paused then
				agent.lastWorld = pos
				WaveCrab.applyFightPose(
					agent.root,
					agent.crabAnim,
					pos,
					swimTang,
					dt,
					WaveCrab.pauseElapsed(agent.pauseUntil, agent.pauseDur),
					agent.id,
					agent.pauseDur
				)
				if agent.isUrchin then
					syncUrchinRig(agent)
				end
			else
				setFishCFrame(agent, pos, swimTang, dt)
			end
			local hungry = agent.hunger < agent.maxHunger
			HungerUi.setDangerFlash(agent, hungry and Path.isNearPathEnd(ground.totalLen, agent.dist))
			-- Only hungry ground critters fight; a full one walks through without stunning the coral.
			if hungry and not paused then
				local shell = agent.shellHitbox
				-- Fallback: root-centered box if shell never resolved (shouldn't happen).
				local hitPart = shell or agent.root
				if hitPart then
					ensureCoralSpatialHash()
					local cell = C.HASH_CELL
					local queryR = WaveCrab.stunQueryRadius(hitPart)
					WaveCrab.spatialForEachNear(coralSpatial, cell, hitPart.Position, queryR, function(item)
						local coral = item :: CoralAgent
						if coral.stunned or not coral.part.Parent then
							return false
						end
						if not WaveCrab.shellOverlapsCoral(hitPart, coral.part) then
							return false
						end
						stunCoralFromCrab(coral)
						local pauseSec = if isCrab
							then coral.defenseSec
							else WaveUrchin.coralPauseSec(coral.defenseSec)
						agent.pauseDur = pauseSec
						agent.pauseUntil = os.clock() + pauseSec
						agent.stunSkullPart = coral.part
						local follow = agent
						WaveCrab.playZapBurst(
							ensureFolder(),
							function()
								if follow.finished or not follow.root.Parent then
									return pos
								end
								local shellNow = follow.shellHitbox
								if shellNow and shellNow.Parent then
									return shellNow.Position
								end
								return follow.root.Position
							end,
							pauseSec,
							function()
								local untilT = follow.pauseUntil
								return untilT ~= nil and os.clock() < untilT
							end
						)
						return true
					end)
				end
			end
			continue
		end
		local path = fishSwimPath(agent)
		if not path then
			continue
		end
		agent.dist = if agent.spawnClock
			then L.WaveVisitPlan.closedDist(agent, simClock)
			else agent.dist + C.FISH_SPEED * (1 + C.FISH_SPEED_VAR * math.sin(simClock * agent.speedFreq + agent.speedPhase)) * dt
		if agent.dist >= path.totalLen then
			finishFish(agent)
			continue
		end
		local pos, tang = Path.samplePath(path, agent.dist)
		local swimTang = Path.stepSwimTang(agent, tang, dt)
		local world = Path.fishWorldOffset(agent, pos, swimTang)
		setFishCFrame(agent, world, swimTang, dt)
		local hungry = agent.hunger < agent.maxHunger
		HungerUi.setDangerFlash(agent, hungry and Path.isNearPathEnd(path.totalLen, agent.dist))
	end
end

local function compactFishList()
	pruneFinishedFish()
	local kept: { FishAgent } = {}
	for _, f in ipairs(fishList) do
		if f.model.Parent then
			table.insert(kept, f)
		else
			-- Orphaned visual (should be rare with pool in-use tracking) — drop without re-release.
			f.finished = true
		end
	end
	fishList = kept
end

local function tickUrchinPlayerStings()
	local now = os.clock()
	local cooldown = C.URCHIN_STING_COOLDOWN_SEC
	local hitR = C.URCHIN_STING_HIT_RADIUS
	local hitY = C.URCHIN_STING_HIT_Y
	local localPlayer = Players.LocalPlayer
	for _, agent in ipairs(fishList) do
		if agent.finished or not agent.isUrchin then
			continue
		end
		local uPos = agent.lastWorld
		for _, plr in ipairs(Players:GetPlayers()) do
			local uid = plr.UserId
			local last = stingReportAt[uid]
			if last and now - last < cooldown then
				continue
			end
			local char = plr.Character
			local hrp = char and char:FindFirstChild("HumanoidRootPart")
			if not (hrp and hrp:IsA("BasePart")) then
				continue
			end
			local p = hrp.Position
			local dx = p.X - uPos.X
			local dz = p.Z - uPos.Z
			if dx * dx + dz * dz > hitR * hitR then
				continue
			end
			if math.abs(p.Y - uPos.Y) > hitY then
				continue
			end
			stingReportAt[uid] = now
			if plr == localPlayer then
				L.UrchinStingEffects.playLocal(uPos)
			end
			reportUrchinSting:FireServer(uid, uPos.X, uPos.Y, uPos.Z)
		end
	end
end

local function makeSummary(): Summary
	return {
		waveReached = math.max(1, waveIndex),
		fishFed = fishFed,
		elapsedSec = wallElapsedSec(),
		defeated = lastStopDefeated,
		defeatOrigin = lastDefeatOrigin,
	}
end

local function hardCleanup(preserveAmmoFade: boolean?, preserveCritterFade: boolean?)
	if not preserveAmmoFade and not preserveCritterFade then
		Feed.stopOrphanAmmoFade()
	end
	for _, shot in ipairs(activeShots) do
		Feed.releaseShotVisual(shot)
		shot.alive = false
		local coral = shot.coral
		if coral then
			coral.busy = false
		end
		Feed.clearShotTarget(shot)
	end
	table.clear(activeShots)
	visibleShotCount = 0
	Feed.clearAllNestRises()
	Feed.clearAllAmmoFades()
	Feed.clearAmmoArmQueue()
	Feed.clearPathStamp()
	if preserveCritterFade then
		-- Models owned by orphan fade jobs; just drop agent list.
		table.clear(fishList)
	else
		for _, f in ipairs(fishList) do
			destroyFish(f)
		end
		table.clear(fishList)
	end
	L.WaveEndVfx.clearGroundPathHearts()
	do
		local pg = Players.LocalPlayer and Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
		if pg then
			if pg:GetAttribute("OceanTD_Wave3FishCamHint") == true then
				pg:SetAttribute("OceanTD_Wave3FishCamHint", nil)
				if pg:GetAttribute("OceanTD_RollFingerHint") == "cam" then
					pg:SetAttribute("OceanTD_RollFingerHint", false)
				end
			end
			if pg:GetAttribute("OceanTD_Wave3CamHoldPause") == true then
				pg:SetAttribute("OceanTD_Wave3CamHoldPause", nil)
			end
			pg:SetAttribute("OceanTD_CinematicSpeedPause", nil)
			pg:SetAttribute("OceanTD_PathTourPending", nil)
		end
		WaveSim.setCinematicPaused(false, 1)
	end
	table.clear(stingReportAt)
	restoreStunnedCorals(false, false)
	for _, c in ipairs(coralList) do
		c.growing = false
		c.busy = false
		c.shotsOut = 0
		if preserveAmmoFade and c.ammoSlots and #c.ammoSlots > 0 then
			Feed.detachAmmoWithoutRelease(c)
		else
			Feed.destroyAmmo(c)
		end
	end
	-- Keep coral agents so build-mode edits can stamp once on backpack close.
	-- The next wave reuses routeBuckets instead of resampling every place/move.
	WaveCrab.spatialClear(coralSpatial)
	coralSpatialDirty = true
	for r = 1, CoralBuckets.ROUTE_COUNT do
		local index = coralByRouteBucket[r]
		if index then
			for i = 1, #index do
				table.clear(index[i])
			end
		end
	end
	CoralBuckets.clearFeedFields()
	coralBucketsDirty = true
	spawnQueue = 0
	crabSpawnQueue = 0
	crabSpawnDelay = 0
	urchinSpawnQueue = 0
	urchinSpawnDelay = 0
	waveSpawning = false
	L.WaveArrowPreview.destroy()
	L.WaveStartVfx.cancel()
	L.Wave1LeadArrow.stop()
	WaveShark.resetAudio()
	L.SharkCam.stopImmediate()
	L.UrchinCam.stopImmediate()
	L.TangCam.stopImmediate()
end

-- Wipe fish/crabs/urchins for the next wave; trailing sharks keep swimming.
function Feed.forceFeedWaveLingerers()
	-- Skip / wave advance must not leave a hungry shark that can still drain reef health.
	for _, f in ipairs(fishList) do
		if f.finished or not isWaveLingerer(f) then
			continue
		end
		f.incomingFood = 0
		if f.hunger < f.maxHunger then
			f.hunger = f.maxHunger
		end
		markFishFullyFed(f, nil)
		HungerUi.updateHungerVisual(f)
		HungerUi.setDangerFlash(f, false)
	end
end

function Feed.clearActiveWaveEntities()
	for _, shot in ipairs(activeShots) do
		Feed.releaseShotVisual(shot)
		shot.alive = false
		Feed.clearShotTarget(shot)
	end
	table.clear(activeShots)
	visibleShotCount = 0
	Feed.clearAllNestRises()
	-- Cancelled shots never call finishShot — reset counters or corals stay empty forever
	-- (shotsOut stays > 0, so the next reload never starts after the next volley lands).
	for _, coral in ipairs(coralList) do
		coral.busy = false
		coral.shotsOut = 0
		if not coral.stunned and not coral.growing and #coral.ammoSlots == 0 then
			Feed.startAmmoGrow(coral)
		end
	end
	Feed.forceFeedWaveLingerers()
	local kept: { FishAgent } = {}
	for _, f in ipairs(fishList) do
		if isWaveLingerer(f) and not f.finished then
			table.insert(kept, f)
		else
			destroyFish(f)
		end
	end
	fishList = kept
	spawnQueue = 0
	crabSpawnQueue = 0
	crabSpawnDelay = 0
	urchinSpawnQueue = 0
	urchinSpawnDelay = 0
	waveSpawning = false
	L.WaveArrowPreview.destroy()
end

local function disconnectMove()
	if moveConn then
		moveConn:Disconnect()
		moveConn = nil
	end
end

function WaveSim.getCoralLifeStats(placeId: string): (number, number)
	local st = coralStatsByPlaceId[placeId]
	if st then
		return st.fed, st.waves
	end
	return 0, 0
end

-- Merge hydrated part attrs into the session map (inspect before/without an active wave).
function WaveSim.noteCoralPart(part: BasePart)
	local pid = part:GetAttribute("OceanTD_PlaceId")
	if typeof(pid) ~= "string" or pid == "" then
		return
	end
	local st = coralStatsByPlaceId[pid] or { fed = 0, waves = 0 }
	st.fed = math.max(st.fed, LifeStats.readAttr(part, "OceanTD_CoralFedTotal"))
	st.waves = math.max(st.waves, LifeStats.readAttr(part, "OceanTD_CoralWavesTotal"))
	coralStatsByPlaceId[pid] = st
	LifeStats.syncAttrs(part, st.fed, st.waves)
end

function WaveSim.isRunning(): boolean
	return running
end

local lastPlayerTapAt = 0

local function isPlayerCamFeed(): boolean
	local pg = Players.LocalPlayer and Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if not pg then
		return false
	end
	local m = pg:GetAttribute("OceanTD_CamCycleMode")
	-- Player Cam is mode "off" (default when unset).
	return m == nil or m == "off"
end

local function tapFeedStartFromCamera(cam: Camera, targetPos: Vector3): Vector3
	local vp = cam.ViewportSize
	local sy = math.clamp(C.TAP_FEED_SCREEN_Y or 0.08, 0.02, 0.9) * vp.Y
	local ray = cam:ViewportPointToRay(vp.X * 0.5, sy)
	local toTarget = (targetPos - cam.CFrame.Position).Magnitude
	-- Keep the orb in-frame immediately (esp. FishCam): not under the HUD, not past the fish.
	local depth = math.clamp(
		toTarget * 0.28,
		C.TAP_FEED_START_DEPTH_MIN or 10,
		C.TAP_FEED_START_DEPTH_MAX or 20
	)
	return ray.Origin + ray.Direction.Unit * depth
end

-- Player Cam: lob from the right-hand food orb; other cams keep screen-top spawn.
local function tapFeedStartPos(cam: Camera, targetPos: Vector3): Vector3
	if isPlayerCamFeed() then
		local hand = HandOrb.getHoldWorldPos()
		if hand then
			return hand
		end
		local char = Players.LocalPlayer and Players.LocalPlayer.Character
		if char then
			local rh = char:FindFirstChild("RightHand") or char:FindFirstChild("Right Arm")
			if rh and rh:IsA("BasePart") then
				return rh.Position
			end
		end
	end
	return tapFeedStartFromCamera(cam, targetPos)
end

local function playPlayerCamThrow()
	if isPlayerCamFeed() then
		HandOrb.playFeedThrow()
	end
end

-- Terrain / plot under the finger (FishCam-safe). Falls back to a long ray if nothing hits.
local function tapFeedTerrainFromScreen(cam: Camera, screenPos: Vector2): Vector3
	local ray = cam:ViewportPointToRay(screenPos.X, screenPos.Y)
	local dir = ray.Direction.Unit
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local exclude: { Instance } = {}
	local char = Players.LocalPlayer.Character
	if char then
		table.insert(exclude, char)
	end
	if folder then
		table.insert(exclude, folder)
	end
	params.FilterDescendantsInstances = exclude
	local hit = Workspace:Raycast(ray.Origin, dir * 1200, params)
	if hit then
		return hit.Position
	end
	local plot = ClientPlot.get()
	if plot then
		local dy = dir.Y
		if math.abs(dy) > 1e-4 then
			local t = (plot.cframe.Position.Y - ray.Origin.Y) / dy
			if t > 0 then
				return ray.Origin + dir * t
			end
		end
	end
	return ray.Origin + dir * 120
end

-- Miss / empty tap: lob a large orb from top-center toward terrain under the finger.
-- Skipped when coral cull is active and the shot wouldn't get a visual slot.
function Feed.fireMissTapVisual(meet: Vector3)
	local cam = Workspace.CurrentCamera
	if not cam then
		return
	end
	local start = tapFeedStartPos(cam, meet)
	local allow = placedCoralCount <= (C.FOOD_CULL_MIN_CORALS or 100)
		or Feed.shotWantsVisual(start, meet)
	if not allow then
		return
	end
	local flatX = meet.X - start.X
	local flatZ = meet.Z - start.Z
	local flat = math.sqrt(flatX * flatX + flatZ * flatZ)
	-- Match hit-food timing (or snappier): distance / fish speed × miss flight mult.
	local flightMult = C.TAP_FEED_MISS_FLIGHT_MULT or C.TAP_FEED_FLIGHT_MULT or 0.4
	local duration = math.clamp(
		flat / math.max(1, C.FISH_SPEED) + (C.FOOD_FIRE_LEAD_SEC or 0.55),
		C.FOOD_RISE_MIN or 1.35,
		C.FOOD_RISE_MAX or 1.85
	) * flightMult
	local part = Feed.acquireTapFoodPart()
	part.Color = Color3.fromHSV(fishRng:NextNumber(), 0.9, 1)
	part.Transparency = 0
	part.CFrame = CFrame.new(start)
	visibleShotCount += 1
	table.insert(activeShots, {
		part = part,
		target = nil,
		fill = 0,
		coral = nil,
		alive = true,
		age = 0,
		duration = duration,
		startPos = start,
		meetPos = meet,
		swayPhase = fishRng:NextNumber(0, math.pi * 2),
		visualOnly = true,
		playerTap = true,
	})
	playPlayerCamThrow()
	-- Miss SFX is the fail sound in WaveTapFeed (not the hit fire whoosh).
end

export type TapFeedResult = "hit" | "cooldown" | "miss" | "full" | "blocked"

-- remainingSec, totalSec (both 0 when ready / no timed reload).
function WaveSim.getTapFeedCooldown(): (number, number)
	local reloadStage = L.SkillPowerUpUI.getStage("ReloadSpeed")
	local cd = L.SkillStages.reloadSpeedCooldownSec(reloadStage)
	if cd <= 1e-4 then
		return 0, 0
	end
	local rem = math.max(0, cd - (os.clock() - lastPlayerTapAt))
	return rem, cd
end

-- Click/tap help-feed: screen-space pick vs fish root (matches WorldToViewportPoint /
-- GetMouseLocation — same space as the debug ball). Avoids GuiInset ray offsets.
function WaveSim.tryTapFeedAtScreen(screenPos: Vector2): TapFeedResult
	if not running or speedMult <= 1e-6 then
		return "blocked"
	end
	local now = os.clock()
	local reloadStage = L.SkillPowerUpUI.getStage("ReloadSpeed")
	local cd = L.SkillStages.reloadSpeedCooldownSec(reloadStage)
	if cd > 0 and now - lastPlayerTapAt < cd then
		return "cooldown"
	end
	local cam = Workspace.CurrentCamera
	if not cam then
		return "blocked"
	end
	local baseRadius = C.TAP_FEED_RADIUS or 5
	local radiusMult = if waveIndex <= 10
		then (C.TAP_FEED_RADIUS_MULT_W1_10 or 1.716)
		elseif waveIndex <= 20 then (C.TAP_FEED_RADIUS_MULT_W11_20 or 1.32)
		elseif waveIndex <= 30 then (C.TAP_FEED_RADIUS_MULT_W21_30 or 1.1)
		else 1
	local radius = baseRadius * radiusMult
	local sharkRadius = radius * (C.TAP_FEED_RADIUS_MULT_SHARK or 2)
	local right = cam.CFrame.RightVector
	local bestHungry: FishAgent? = nil
	local bestHungryScore = math.huge
	local bestFull: FishAgent? = nil
	local bestFullScore = math.huge
	for _, f in ipairs(fishList) do
		if f.finished or not f.model.Parent or WaveSim.tooYoungToFeed(f) then
			continue
		end
		local sp, _onScreen = cam:WorldToViewportPoint(f.root.Position)
		if sp.Z <= 0 then
			continue
		end
		local fishScreen = Vector2.new(sp.X, sp.Y)
		local dPx = (fishScreen - screenPos).Magnitude
		local useR = if f.isShark then sharkRadius else radius
		local edgeSp = cam:WorldToViewportPoint(f.root.Position + right * useR)
		local rPx = (Vector2.new(edgeSp.X, edgeSp.Y) - fishScreen).Magnitude
		if rPx < 6 then
			rPx = 6
		end
		if dPx > rPx then
			continue
		end
		local hungry = f.hunger < f.maxHunger
		if hungry then
			if dPx < bestHungryScore then
				bestHungryScore = dPx
				bestHungry = f
			end
		elseif dPx < bestFullScore then
			bestFullScore = dPx
			bestFull = f
		end
	end
	if bestHungry then
		local start = tapFeedStartPos(cam, bestHungry.root.Position)
		if not Feed.firePlayerTap(bestHungry, start) then
			return "miss"
		end
		playPlayerCamThrow()
		HungerUi.flashTapStroke(bestHungry)
		lastPlayerTapAt = now
		return "hit"
	end
	if bestFull then
		return "full"
	end
	-- Miss: lob food at the terrain under the finger (cull-gated when many corals are out).
	Feed.fireMissTapVisual(tapFeedTerrainFromScreen(cam, screenPos))
	lastPlayerTapAt = now
	return "miss"
end

-- Legacy ray entry (unused by WaveTapFeed; kept for callers).
function WaveSim.tryTapFeed(origin: Vector3, direction: Vector3, _startPos: Vector3?): boolean
	local cam = Workspace.CurrentCamera
	if not cam then
		return false
	end
	-- Approximate screen from ray hit of a plane in front of camera — prefer tryTapFeedAtScreen.
	local dirLen = direction.Magnitude
	if dirLen < 1e-4 then
		return false
	end
	local dir = direction / dirLen
	local probe = origin + dir * 40
	local sp = cam:WorldToViewportPoint(probe)
	return WaveSim.tryTapFeedAtScreen(Vector2.new(sp.X, sp.Y)) == "hit"
end

-- Visitor shot. Does not spend the host's reload. $D still lands on this plot when the fish fills.
function WaveSim.applyVisitorTap(fishId: number): boolean
	if not running or joinIntroDemo or speedMult <= 1e-6 then
		return false
	end
	local slot = math.floor(fishId)
	local target: FishAgent? = nil
	for _, f in ipairs(fishList) do
		if f.visitSlot == slot and not f.finished and f.model.Parent then
			target = f
			break
		end
	end
	if not target or target.hunger >= target.maxHunger then
		return false
	end
	local start = target.root.Position + Vector3.new(0, 8, 0)
	return Feed.firePlayerTap(target, start)
end

function WaveSim.tooYoungToFeed(agent: { bornAt: number? }): boolean
	local born = agent.bornAt
	return typeof(born) == "number" and os.clock() - born < 1.5
end

function WaveSim.getWaveIndex(): number
	return waveIndex
end

function WaveSim.getHungryLeft(): (number, number, number, number)
	local fish, crab, urchin, shark = 0, 0, 0, 0
	if L.WaveVisitPlan.active("host") then
		fish, crab, urchin, shark = L.WaveVisitPlan.unspawnedByKind("host")
	else
		fish = math.max(0, waveFishExpected - waveFishSpawned)
		crab = math.max(0, WaveCrab.expectedCount() - WaveCrab.spawnedCount())
		urchin = math.max(0, WaveUrchin.expectedCount() - WaveUrchin.spawnedCount())
		shark = 0
	end
	for _, f in ipairs(fishList) do
		if f.finished then
			continue
		end
		if f.fedCounted or (f.maxHunger > 0 and f.hunger >= f.maxHunger) then
			continue
		end
		if f.isShark then
			shark += 1
		elseif f.isUrchin then
			urchin += 1
		elseif f.isCrab then
			crab += 1
		else
			fish += 1
		end
	end
	return fish, crab, urchin, shark
end

function WaveSim.onNaturalWavePrepare(cb: () -> ())
	local list = WaveSim._naturalPrepare
	if typeof(list) ~= "table" then
		list = {}
		WaveSim._naturalPrepare = list
	end
	table.insert(list :: { () -> () }, cb)
end

function WaveSim.setAutoNext(on: boolean)
	WaveSim._autoNext = on == true
end

function WaveSim.fireNaturalWavePrepare()
	local list = WaveSim._naturalPrepare
	if typeof(list) ~= "table" then
		return
	end
	for _, cb in ipairs(list :: { () -> () }) do
		cb()
	end
end

function WaveSim.onNaturalWaveAdvance(cb: () -> ())
	local list = WaveSim._naturalAdvance
	if typeof(list) ~= "table" then
		list = {}
		WaveSim._naturalAdvance = list
	end
	table.insert(list :: { () -> () }, cb)
end

function WaveSim.fireNaturalWaveAdvance()
	local list = WaveSim._naturalAdvance
	if typeof(list) ~= "table" then
		return
	end
	for _, cb in ipairs(list :: { () -> () }) do
		cb()
	end
end

-- Counts for the wave that just began, plus the min/max that wave could roll.
function WaveSim.getCritterReveal(): { { glyph: string, count: number, lo: number, hi: number } }
	local wave = waveIndex
	local out: { { glyph: string, count: number, lo: number, hi: number } } = {}
	local fishN = waveFishCount(wave)
	table.insert(out, { glyph = "🐟", count = fishN, lo = fishN, hi = fishN })
	local crabLo, crabHi = C.crabCountRangeForWave(wave)
	local crabN = L.WaveVisitPlan.crabCount("host")
	if crabHi > 0 or crabN > 0 then
		if crabLo > crabN then
			crabLo = crabN
		end
		if crabHi < crabN then
			crabHi = crabN
		end
		table.insert(out, { glyph = "🦀", count = crabN, lo = crabLo, hi = crabHi })
	end
	local urchinLo, urchinHi = C.urchinCountRangeForWave(wave)
	local urchinN = L.WaveVisitPlan.urchinCount("host")
	if urchinHi > 0 or urchinN > 0 then
		if urchinLo > urchinN then
			urchinLo = urchinN
		end
		if urchinHi < urchinN then
			urchinHi = urchinN
		end
		table.insert(out, { glyph = "✴", count = urchinN, lo = urchinLo, hi = urchinHi })
	end
	local sharkN = WaveShark.countForWave(wave)
	if sharkN > 0 then
		table.insert(out, { glyph = "🦈", count = sharkN, lo = sharkN, hi = sharkN })
	end
	return out
end

-- 0–1 along the path toward the reef heart. Latches forward so the bar emoji
-- does not jump back when the lead critter leaves.
function WaveSim.getCritterPathFracs(): (number, number, number, number)
	local lead = WaveSim._pathLead
	if typeof(lead) ~= "table" or WaveSim._pathLeadWave ~= waveIndex then
		lead = { fish = 0, crab = 0, urchin = 0, shark = 0 }
		WaveSim._pathLead = lead
		WaveSim._pathLeadWave = waveIndex
	end
	for _, f in ipairs(fishList) do
		local total = 0
		local kind = "fish"
		if f.isShark then
			kind = "shark"
			total = if pathDataShark then pathDataShark.totalLen else 0
		elseif f.isUrchin then
			kind = "urchin"
			total = if f.groundPath then f.groundPath.totalLen else 0
		elseif f.isCrab then
			kind = "crab"
			total = if f.groundPath then f.groundPath.totalLen else 0
		else
			local swim = f.swimPath or pathData
			total = if swim then swim.totalLen else 0
		end
		if total >= 1 then
			local u = math.clamp(f.dist / total, 0, 1)
			if u > lead[kind] then
				lead[kind] = u
			end
		end
	end
	return lead.fish, lead.crab, lead.urchin, lead.shark
end

-- Viewport screen position of a hungry Tang in the last `lastFrac` of its path (wave 1 tap tutorial).
function WaveSim.getWave1TapFeedFingerScreen(lastFrac: number): Vector2?
	if not running or joinIntroDemo or waveIndex ~= C.TANG_FIRST_WAVE then
		return nil
	end
	local frac = math.clamp(lastFrac, 0.05, 0.95)
	local cam = Workspace.CurrentCamera
	if not cam then
		return nil
	end
	local best: FishAgent? = nil
	local bestProg = -1
	for _, f in ipairs(fishList) do
		if f.finished or f.isCrab or f.isUrchin or f.isShark then
			continue
		end
		if f.hunger >= f.maxHunger then
			continue
		end
		local path = fishSwimPath(f)
		if not path or path.totalLen < 1 then
			continue
		end
		local prog = f.dist / path.totalLen
		if prog < (1 - frac) then
			continue
		end
		if prog > bestProg then
			bestProg = prog
			best = f
		end
	end
	if not best then
		return nil
	end
	local sp, onScreen = cam:WorldToViewportPoint(best.root.Position)
	if not onScreen or sp.Z <= 0 then
		return nil
	end
	return Vector2.new(sp.X, sp.Y)
end

function WaveSim.areCritterHungerBarsVisible(): boolean
	return critterHungerBarsVisible
end

function WaveSim.setCritterHungerBarsVisible(visible: boolean)
	if critterHungerBarsVisible == visible then
		return
	end
	critterHungerBarsVisible = visible
	HungerUi.applyCritterHungerBarsVisible()
	-- Eye also toggles crab/urchin/shark path ribbons (waves + build preview).
	L.WavePathLines.syncHostilePaths()
end

function WaveSim.toggleCritterHungerBarsVisible(): boolean
	critterHungerBarsVisible = not critterHungerBarsVisible
	HungerUi.applyCritterHungerBarsVisible()
	L.WavePathLines.syncHostilePaths()
	return critterHungerBarsVisible
end

function WaveSim.setHideUiSuppressesCritterUi(suppress: boolean)
	if hideUiSuppressesCritterUi == suppress then
		return
	end
	hideUiSuppressesCritterUi = suppress
	HungerUi.applyCritterHungerBarsVisible()
	-- Path ribbons count as HUD chrome — hide with Hide UI.
	L.WavePathLines.setVisible(not suppress)
	if not suppress then
		L.WavePathLines.syncHostilePaths()
	end
end

function WaveSim.healReef(amount: number): boolean
	if not running or amount <= 0 then
		return false
	end
	if reefHealth >= reefMaxHealth then
		return false
	end
	local before = reefHealth
	reefHealth = math.clamp(reefHealth + amount, 0, reefMaxHealth)
	if reefHealth == before then
		return false
	end
	notifyHud()
	flushHud()
	return true
end

function WaveSim.getHudSnapshot(): HudSnapshot
	local feedProg, feedDone = getFeedProgress()
	local fishFull, fishTotal = getFishFullCounts()
	return {
		wave = waveIndex,
		reefHealth = reefHealth,
		reefMax = reefMaxHealth,
		elapsedSec = wallElapsedSec(),
		running = running,
		feedProgress = feedProg,
		feedComplete = feedDone,
		hungerDanger = anyHungerDanger(),
		hungryMissToken = hungryMissToken,
		fishFull = fishFull,
		fishTotal = fishTotal,
		crabTotal = WaveCrab.expectedCount(),
		urchinTotal = WaveUrchin.expectedCount(),
		sharkTotal = WaveShark.countForWave(waveIndex),
		speedMult = speedMult,
	}
end

function WaveSim.getSimClock(): number
	return simClock
end

-- Packed hunger + path distance for visitors. One byte of hunger, two of distance.
function WaveSim.packVisitState(): string
	local n = L.WaveVisitPlan.count("host")
	if n < 1 or joinIntroDemo then
		return ""
	end
	local hungerBy = table.create(n, 0)
	local distBy = table.create(n, 0)
	for i = 1, n do
		if L.WaveVisitPlan.isDue("host", i, simClock) then
			hungerBy[i] = 254
		end
	end
	for _, f in ipairs(fishList) do
		local slot = f.visitSlot
		if slot and slot >= 1 and slot <= n and not f.finished and f.model.Parent then
			if f.hunger >= f.maxHunger then
				hungerBy[slot] = 255
			else
				local u = f.hunger / math.max(1, f.maxHunger)
				-- 1 = empty but spawned. 0 is reserved for "not in the wave yet".
				hungerBy[slot] = math.clamp(math.floor(u * 251 + 1.5), 1, 252)
			end
			distBy[slot] = math.clamp(math.floor(f.dist * 4 + 0.5), 0, 65535)
		end
	end
	local parts = table.create(n)
	for i = 1, n do
		local d = distBy[i]
		parts[i] = string.char(hungerBy[i], d % 256, math.floor(d / 256))
	end
	return table.concat(parts)
end

function WaveSim.getVisitSync(): { seed: number, planT0: number, simClock: number, blob: string }
	return {
		seed = L.WaveVisitPlan.seed("host"),
		planT0 = L.WaveVisitPlan.t0("host"),
		simClock = simClock,
		blob = WaveSim.packVisitState(),
	}
end

-- Furthest hungry critter for Fish Cam POV:
-- Tang school first; once all fish are fed → shark → crabs/urchins.
-- `dist` = progress along the swim path (for path-locked POV).
function WaveSim.getFurthestUnfedFish(): { id: number, position: Vector3, dist: number }?
	local bestShark: FishAgent? = nil
	local bestFish: FishAgent? = nil
	local bestGround: FishAgent? = nil
	for _, f in ipairs(fishList) do
		if f.finished or f.hunger >= f.maxHunger or not f.root.Parent then
			continue
		end
		if f.isShark then
			if not bestShark or f.dist > bestShark.dist then
				bestShark = f
			end
		elseif Path.isGroundCritter(f) then
			if not bestGround or f.dist > bestGround.dist then
				bestGround = f
			end
		elseif not bestFish or f.dist > bestFish.dist then
			bestFish = f
		end
	end
	local best = bestFish or bestShark or bestGround
	if not best then
		return nil
	end
	return { id = best.id, position = best.root.Position, dist = best.dist }
end

-- Furthest along the route among fish still swimming (fed or hungry).
function WaveSim.getFurthestLiveFish(): { id: number, position: Vector3, dist: number }?
	local best: FishAgent? = nil
	for _, f in ipairs(fishList) do
		if f.finished or Path.isGroundCritter(f) or not f.root.Parent then
			continue
		end
		if not best or f.dist > best.dist then
			best = f
		end
	end
	if not best then
		return nil
	end
	return { id = best.id, position = best.root.Position, dist = best.dist }
end

-- Live world pose for a fish still on the path (fed or hungry).
function WaveSim.getFishPosition(id: number): Vector3?
	for _, f in ipairs(fishList) do
		if f.id == id and not f.finished and f.root.Parent then
			return f.root.Position
		end
	end
	return nil
end

function WaveSim.getFishPathDist(id: number): number?
	for _, f in ipairs(fishList) do
		if f.id == id and not f.finished and f.root.Parent then
			return f.dist
		end
	end
	return nil
end

-- Facing for Fish Cam POV (coaster view along the swim).
function WaveSim.getFishLookVector(id: number): Vector3?
	for _, f in ipairs(fishList) do
		if f.id == id and not f.finished and f.root.Parent then
			local look = f.root.CFrame.LookVector
			if look.Magnitude > 1e-3 then
				return look.Unit
			end
			return nil
		end
	end
	return nil
end

-- Happy emojis on fully-fed fish still in the wave (for finish firework).
function WaveSim.getFinishEmojis(): { string }
	local out: { string } = {}
	for _, f in ipairs(fishList) do
		if not f.finished and f.hunger >= f.maxHunger then
			local e = f.happyLabel.Text
			if e == "" then
				e = C.HAPPY_EMOJIS[((f.id - 1) % #C.HAPPY_EMOJIS) + 1]
			end
			table.insert(out, e)
		end
	end
	if #out == 0 then
		for i = 1, math.min(8, #C.HAPPY_EMOJIS) do
			table.insert(out, C.HAPPY_EMOJIS[i])
		end
	end
	return out
end

-- When every fish this wave is fully fed, clear the rest with full credit and start next wave.
function WaveSim.finishWaveEarly(): boolean
	if not running then
		return false
	end
	local _, complete = getFeedProgress()
	if not complete then
		return false
	end
	-- Happy firework already played when NEXT WAVE unlocked (WaveSlot).
	-- Credit remaining full fish/crabs/urchins; sharks keep their route.
	for _, f in ipairs(fishList) do
		if not f.finished and not isWaveLingerer(f) and f.hunger >= f.maxHunger then
			finishFish(f, true)
		end
	end
	awardCoralWaveCompleted(waveIndex)
	Feed.clearActiveWaveEntities()
	L.UiHaptics.pulseTriple()
	resumeNormalSpeedIfPaused()
	L.WaveFeedPayout.playWaveClearStream()
	-- Let the next-wave scrollers play before the new school spawns.
	WaveSim._spawnHold = 2
	beginWave(waveIndex + 1)
	notifyHud()
	flushHud()
	return true
end

function WaveSim.skipToNextWave(): boolean
	if not running then
		return false
	end
	awardCoralWaveCompleted(waveIndex)
	Feed.clearActiveWaveEntities()
	L.UiHaptics.pulseTriple()
	resumeNormalSpeedIfPaused()
	L.WaveFeedPayout.playWaveClearStream()
	beginWave(waveIndex + 1)
	notifyHud()
	flushHud()
	return true
end

-- TEMP debug: jump to a specific wave while a run is active.
function WaveSim.skipToWave(wave: number): boolean
	if not running then
		return false
	end
	local w = math.max(1, math.floor(wave))
	if w == waveIndex then
		return true
	end
	Feed.clearActiveWaveEntities()
	L.UiHaptics.pulseTriple()
	resumeNormalSpeedIfPaused()
	beginWave(w)
	notifyHud()
	flushHud()
	return true
end

function WaveSim.onHud(cb: (HudSnapshot) -> ()): () -> ()
	table.insert(hudListeners, cb)
	return function()
		local i = table.find(hudListeners, cb)
		if i then
			table.remove(hudListeners, i)
		end
	end
end

function WaveSim.onStopped(cb: (Summary) -> ()): () -> ()
	table.insert(stopListeners, cb)
	return function()
		local i = table.find(stopListeners, cb)
		if i then
			table.remove(stopListeners, i)
		end
	end
end

function WaveSim.stop(opts: { silent: boolean?, preserveAmmoFade: boolean?, preserveCritterFade: boolean? }?): Summary
	if not running then
		return makeSummary()
	end
	if not joinIntroDemo then
		L.WaveFeedPayout.playWaveClearStream()
	end
	local silent = opts ~= nil and opts.silent == true
	local preserveAmmoFade = opts ~= nil and opts.preserveAmmoFade == true
	local preserveCritterFade = opts ~= nil and opts.preserveCritterFade == true
	endWave2FullAutoTrial()
	if not joinIntroDemo then
		LifeStats.flush(true)
	end
	token += 1
	local summary = makeSummary()
	running = false
	CoralBuckets.clearBucketFoodDebug()
	L.WaveVisitPlan.clear("host")
	defeatBusy = false
	L.ReefDefeatCam.stopImmediate()
	disconnectMove()
	-- Clear defeat flags after snapshot so the next run starts clean.
	lastStopDefeated = false
	lastDefeatOrigin = nil
	-- Keep eye preference so build-mode path previews stay hidden if they toggled off.
	L.WaveEndVfx.setHappyExitVisible(true)
	resetSpeedState()
	hardCleanup(preserveAmmoFade, preserveCritterFade)
	table.clear(hostilePreviewPaths)
	table.clear(hostilePathQueue)
	hostileDisplayIndex = 1
	-- Wave ribbons clear; build-mode crab/urchin/shark previews may paint next.
	L.WavePathLines.syncHostilePaths()
	L.WaveEndVfx.clearGroundPathHearts()
	demoCoralParts = nil
	joinIntroDemo = false
	lastHudWave = -1
	lastHudReef = -1
	lastHudSec = -1
	lastHudFeed = -1
	lastHudFeedDone = false
	lastHudDanger = false
	notifyHud()
	flushHud()
	if not silent then
		fireStopped(summary)
	end
	return summary
end

local function snapFishToDist(agent: FishAgent, dist: number)
	agent.dist = math.max(0, dist)
	if agent.isShark then
		local path = pathDataShark
		if not path then
			return
		end
		local pos, tang = WaveShark.sample(path, agent.dist)
		agent.lastWorld = pos
		agent.smoothTang = if tang.Magnitude > 1e-5 then tang.Unit else agent.smoothTang
		setFishCFrame(agent, pos, agent.smoothTang, 1)
		return
	end
	if Path.isGroundCritter(agent) and agent.groundPath then
		local pos, tang = WaveCrab.sample(agent.groundPath, agent.dist)
		if agent.isCrab then
			local side = Vector3.new(-tang.Z, 0, tang.X)
			if side.Magnitude > 1e-4 then
				pos = pos + side.Unit * agent.lateral
			end
			pos = WaveCrab.worldOnGround(pos, nil, 1)
		end
		agent.lastWorld = pos
		agent.smoothTang = if tang.Magnitude > 1e-5 then tang.Unit else agent.smoothTang
		setFishCFrame(agent, pos, agent.smoothTang, 1)
		return
	end
	local path = fishSwimPath(agent) or pathData
	if not path then
		return
	end
	local pos, tang = Path.samplePath(path, agent.dist)
	local world = Path.fishWorldOffset(agent, pos, tang)
	agent.lastWorld = world
	agent.smoothTang = if tang.Magnitude > 1e-5 then tang.Unit else agent.smoothTang
	setFishCFrame(agent, world, agent.smoothTang, 1)
end

local function seedJoinIntroHalfway()
	-- Instantly dump the whole Tang school (no spawn stagger). No crabs/urchins in intro.
	local nFish = spawnQueue
	spawnDelay = 0
	while spawnQueue > 0 do
		local idx = nFish - spawnQueue + 1
		spawnOneFish(idx)
		spawnQueue -= 1
	end
	waveSpawning = false
	crabSpawnQueue = 0
	urchinSpawnQueue = 0
	urchinSpawnDelay = 0

	local tangs: { FishAgent } = {}
	for _, f in ipairs(fishList) do
		if f.finished then
			continue
		end
		local pathLen = 0
		if f.isShark and pathDataShark then
			pathLen = pathDataShark.totalLen
		elseif Path.isGroundCritter(f) and f.groundPath then
			pathLen = f.groundPath.totalLen
		else
			local swim = fishSwimPath(f) or pathData
			pathLen = if swim then swim.totalLen else 0
		end
		-- ~35% along the path (showcase starts early-mid wave).
		local mid = pathLen * fishRng:NextNumber(0.30, 0.40)
		snapFishToDist(f, mid)
		if not f.isShark and not Path.isGroundCritter(f) then
			table.insert(tangs, f)
		end
	end

	-- ~Half the Tang school already fully fed (happy), rest still eating.
	local feedCount = math.floor(#tangs * 0.5 + 0.5)
	for i, f in ipairs(tangs) do
		if i <= feedCount then
			f.hunger = f.maxHunger
			f.payoutDone = true
			markFishFullyFed(f, nil)
			HungerUi.updateHungerVisual(f)
		else
			f.hunger = f.maxHunger * fishRng:NextNumber(0.2, 0.55)
			HungerUi.updateHungerVisual(f)
		end
	end
	notifyHud()
	flushHud()
end

local function attachSimLoop(myToken: number)
	disconnectMove()
	moveConn = L.RunService.Heartbeat:Connect(function(dt)
		if myToken ~= token or not running then
			return
		end
		-- Speed pause: freeze fish, crabs, food, ammo, combat, spawns; HUD clock holds.
		-- Urchin sting still runs so players can walk into paused urchins.
		if speedMult <= 1e-6 then
			tickUrchinPlayerStings()
			flushHud()
			return
		end
		local simDt = dt * speedMult
		simClock += simDt
		if L.WaveVisitPlan.active("host") then
			L.WaveVisitPlan.drain("host", simClock, function(spec)
				L.WaveVisitPlan.arm("host", spec)
				if spec.kind == "tang" then
					spawnOneFish(0)
				elseif spec.kind == "crab" then
					spawnOneCrab(0)
				elseif spec.kind == "urchin" then
					spawnOneUrchin(0)
				else
					spawnOneShark()
				end
			end)
			if L.WaveVisitPlan.remaining("host") <= 0 then
				waveSpawning = false
			end
		else
		-- Urchins spawn before the fish school (waves 10/20/30…).
		if urchinSpawnQueue > 0 then
			urchinSpawnDelay -= simDt
			if urchinSpawnDelay <= 0 then
				spawnOneUrchin(0)
				urchinSpawnQueue -= 1
				urchinSpawnDelay = if urchinSpawnQueue > 0
					then WaveUrchin.rollSpawnGap(fishRng)
					else 0
			end
		end
		-- Spawning (first fish waits C.ARROW_LEAD_SEC after GreenArrows start)
		if waveSpawning and spawnQueue > 0 then
			spawnDelay -= simDt
			if spawnDelay <= 0 then
				local idx = waveFishCount(waveIndex) - spawnQueue + 1
				spawnOneFish(idx)
				if idx == 1 then
					local nCrab = WaveCrab.expectedCount()
					if nCrab > 0 then
						crabSpawnQueue = nCrab
						crabSpawnDelay = fishRng:NextNumber(C.CRAB_FIRST_DELAY_MIN, C.CRAB_FIRST_DELAY_MAX)
					end
				end
				spawnQueue -= 1
				-- Slight random gap so the school reads as a parade, not a metronome.
				spawnDelay = spawnGapForWave(waveIndex) * fishRng:NextNumber(0.7, 1.35)
				if spawnQueue <= 0 then
					waveSpawning = false
				end
			end
		end

		if crabSpawnQueue > 0 then
			crabSpawnDelay -= simDt
			if crabSpawnDelay <= 0 then
				spawnOneCrab(0)
				crabSpawnQueue -= 1
				crabSpawnDelay = if crabSpawnQueue > 0
					then fishRng:NextNumber(C.CRAB_STAGGER_MIN, C.CRAB_STAGGER_MAX)
					else 0
			end
		end
		end

		L.WaveArrowPreview.tick(simDt)
		-- Wave 1: keep green path trains looping until the round ends.
		if not joinIntroDemo
			and waveIndex == C.TANG_FIRST_WAVE
			and not L.WaveArrowPreview.hasActiveGreenTrains()
		then
			L.WaveArrowPreview.startGreen({ playSound = false })
		end
		-- Crab/urchin: cycle red trains across planned GroundA/B paths.
		if not joinIntroDemo
			and #hostilePreviewPaths > 0
			and not L.WaveArrowPreview.hasActiveRedCrabTrains()
		then
			L.WaveArrowPreview.advanceHostileCycle()
		end
		Feed.tickPathStamp()
		Feed.tickAmmoArm(simClock)
		Feed.tickAmmoFade(simClock)
		local mode = C.FEED_MODE
		tickFish(simDt)
		tickUrchinPlayerStings()
		if mode == "lane_stock" then
			Feed.tickLaneStock(simDt)
			Feed.tickNestRisePulses()
			Feed.tickShots(simDt)
		elseif mode == "path_fields" then
			ensureCoralPathBucketIndex()
			CoralBuckets.tickServingDeposits(coralList, simClock)
			CoralBuckets.refreshBucketOverlaps(routePaths)
			local drinkCap = C.LANE_DRINK_PER_SEC * simDt
			if joinIntroDemo then
				drinkCap *= 0.5
			end
			CoralBuckets.clearHungryScratch(routePaths)
			for _, f in ipairs(fishList) do
				if not f.finished and f.hunger < f.maxHunger and not WaveSim.tooYoungToFeed(f) then
					local route = resolveFeedRoute(f)
					if route then
						CoralBuckets.noteHungry(route, f.dist, f)
					end
				end
			end
			local anyDrink = false
			CoralBuckets.eachHungryFrontFirst(function(f: any, route: number)
				local agent = f :: FishAgent
				if agent.finished or agent.hunger >= agent.maxHunger or WaveSim.tooYoungToFeed(agent) then
					return
				end
				local need = agent.maxHunger - agent.hunger
				local got = CoralBuckets.drinkStock(route, agent.dist, math.min(need, drinkCap))
				if got <= 0 then
					return
				end
				anyDrink = true
				agent.hunger = math.min(agent.maxHunger, agent.hunger + got)
				local pulse = CoralBuckets.takeServingCoral(route, agent.dist)
				if pulse then
					creditCoralFeed(pulse :: CoralAgent)
					Feed.triggerLaneFeedVisual(pulse :: CoralAgent, agent)
				end
				if (not agent.payoutDone) and agent.hunger >= agent.maxHunger then
					agent.payoutDone = true
					L.WaveFeedPayout.noteFilled(agent.root.Position)
				end
				if agent.hunger >= agent.maxHunger then
					markFishFullyFed(agent, nil)
				end
				HungerUi.updateHungerVisual(agent)
			end)
			Feed.tickNestRisePulses()
			Feed.tickShots(simDt)
			if anyDrink and fishRng:NextNumber() < 0.06 then
				HungerUi.playFeedSound()
			end
			CoralBuckets.tickBucketFoodDebug(routePaths)
		else
			Feed.tickShots(simDt)
			Feed.tickAmmoGrow(simClock)
		end

		-- Pick up newly placed corals; volley combat at ~10 Hz.
		combatAcc += simDt
		if combatAcc >= C.COMBAT_DT then
			combatAcc -= C.COMBAT_DT
			syncCorals(false)
			if mode == "volleys" then
				Feed.tickCombat()
			end
		end

		-- Compact finished fish occasionally
		if math.random() < 0.02 then
			compactFishList()
		end

		flushHud()

		-- Final-heart kill owns stop via L.ReefDefeatCam callback — don't cancel the zoom here.
		if reefHealth <= 0 and not defeatBusy then
			WaveSim.stop()
			return
		end

		-- Wave complete → next wave immediately (sharks may still be swimming).
		if WaveSim._autoNext == true
			and not joinIntroDemo
			and not waveSpawning
			and spawnQueue <= 0
			and crabSpawnQueue <= 0
			and urchinSpawnQueue <= 0
			and L.WaveVisitPlan.remaining("host") <= 0
			and countAliveWaveBlockers() == 0
		then
			awardCoralWaveCompleted(waveIndex)
			L.UiHaptics.pulseTriple()
			resumeNormalSpeedIfPaused()
			L.WaveFeedPayout.playWaveClearStream()
			WaveSim.fireNaturalWavePrepare()
			WaveSim._spawnHold = 2
			beginWave(waveIndex + 1)
			WaveSim.fireNaturalWaveAdvance()
		end
	end)
end

-- After defeat / stop summary: set reef hearts and resume (keeps run stats).
-- retrySameWave: defeat RETRY replays the failed wave; otherwise advance to the next.
function WaveSim.continueWithHearts(hearts: number, retrySameWave: boolean?): boolean
	if running then
		return false
	end
	pathData = Path.buildPath()
	pathDataA2 = Path.buildNamedPath(C.FISH_ROUTE_A2_NAME)
	pathDataGroundA, pathDataGroundB = WaveCrab.buildBothLocal()
	pathDataShark = WaveShark.buildLocal()
	if not pathData then
		return false
	end
	L.WavePathLines.rebuild()
	if not WaveEntityPool.hasFishKind(WaveEntityPool.FISH_TANG) then
		warn("[WAVE] L.ReplicatedStorage.HungryFish missing")
		return false
	end
	token += 1
	local myToken = token
	running = true
	reefMaxHealth = reefMaxFromSkills()
	reefHealth = math.clamp(math.floor(hearts + 0.5), 1, reefMaxHealth)
	resetSpeedState()
	ensureFolder()
	L.WaveEndVfx.refreshLocalEndHeart()
	local w = math.max(1, waveIndex)
	suppressWaveStartCamForce = true
	WaveSim.fireNaturalWavePrepare()
	beginWave(if retrySameWave then w else w + 1)
	WaveSim.fireNaturalWaveAdvance()
	suppressWaveStartCamForce = false
	notifyHud()
	flushHud()
	attachSimLoop(myToken)
	return true
end

local function stopPlanningArrowLoop()
	planningArrows = false
	if planningArrowConn then
		planningArrowConn:Disconnect()
		planningArrowConn = nil
	end
end

local function syncPlanningLegendVisible(want: boolean)
	-- Hide DANGEROUS/FRIENDLY legend after the player places their first coral.
	if want and L.PlacedCoralIndex.countLocal() > 0 then
		want = false
	end
	L.WaveArrowPreview.setPlanningLegendVisible(want)
end

function WaveSim.stopPlanningArrowPreview()
	stopPlanningArrowLoop()
	syncPlanningLegendVisible(false)
	L.WaveArrowPreview.setTickSpeedMult(1)
	if not running then
		L.WaveArrowPreview.destroy()
	end
end

local function introStillBusy(): boolean
	local pg = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
	return pg ~= nil and pg:GetAttribute("OceanTD_JoinIntroBusy") == true
end

-- Green (and route) arrow trains before the first Start Waves of a session.
-- Only after intro is over and the player has control; loops until Start Waves.
function WaveSim.startPlanningArrowPreview(): boolean
	if hasStartedWavesThisSession or running or joinIntroDemo then
		return false
	end
	if introStillBusy() then
		return false
	end
	if not ClientPlot.get() then
		return false
	end
	pathData = Path.buildPath()
	pathDataA2 = Path.buildNamedPath(C.FISH_ROUTE_A2_NAME)
	pathDataGroundA, pathDataGroundB = WaveCrab.buildBothLocal()
	pathDataShark = WaveShark.buildLocal()
	if not pathData then
		return false
	end
	waveIndex = math.max(1, waveIndex)
	ensureFolder()
	planningArrows = true
	local planningOpts = {
		playSound = false,
		includeShark = false,
		forceGroundTrains = false,
		greenLabelText = "FISH PATH",
	}
	L.WaveArrowPreview.setTickSpeedMult(0.5)
	-- Friendly green trains only — no red dangerous-critter arrows.
	L.WaveArrowPreview.startGreen(planningOpts)
	-- Ink once after intro; pathData is already the current Plot Size trim.
	L.WavePathLines.ensureInkReveal()
	syncPlanningLegendVisible(true)
	if not planningArrowConn then
		planningArrowConn = L.RunService.Heartbeat:Connect(function(dt)
			if not planningArrows or running or hasStartedWavesThisSession then
				return
			end
			if introStillBusy() then
				return
			end
			L.WaveArrowPreview.tick(dt)
			if not L.WaveArrowPreview.hasActiveGreenTrains() then
				L.WaveArrowPreview.startGreen(planningOpts)
			end
		end)
	end
	return true
end

function WaveSim.isPlanningArrowPreview(): boolean
	return planningArrows == true
end

local function tryStartPlanningAfterIntro()
	if hasStartedWavesThisSession or running or joinIntroDemo or introStillBusy() then
		return
	end
	if not ClientPlot.get() then
		return
	end
	WaveSim.startPlanningArrowPreview()
end

function WaveSim.getWavesStartCount(): number
	return wavesStartCount
end

function WaveSim.start(): boolean
	if running then
		return false
	end
	-- Real waves replace the pre-start planning train.
	hasStartedWavesThisSession = true
	wavesStartCount += 1
	WaveSim.stopPlanningArrowPreview()
	pathData = Path.buildPath()
	pathDataA2 = Path.buildNamedPath(C.FISH_ROUTE_A2_NAME)
	pathDataGroundA, pathDataGroundB = WaveCrab.buildBothLocal()
	pathDataShark = WaveShark.buildLocal()
	if not pathData then
		return false
	end
	if not WaveEntityPool.hasFishKind(WaveEntityPool.FISH_TANG) then
		warn("[WAVE] L.ReplicatedStorage.HungryFish missing")
		return false
	end
	-- Remember cam before Wave-1 FishCam force — restore on Finish (not Retry/Continue).
	local pg = Players.LocalPlayer and Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if pg then
		local cur = pg:GetAttribute("OceanTD_CamCycleMode")
		if cur == "off" or cur == "plotcam" or cur == "fishcam" or cur == "dronecam" then
			pg:SetAttribute("OceanTD_WaveResumeCamMode", cur)
		end
	end
	token += 1
	local myToken = token
	running = true
	waveIndex = 0
	reefMaxHealth = reefMaxFromSkills()
	reefHealth = reefMaxHealth
	fishFed = 0
	L.WaveEndVfx.resetStreak()
	feedPitchCursor = C.FEED_PITCH_MIN
	startedAt = os.clock()
	simClock = 0
	resetSpeedState()
	combatAcc = 0
	nextFishId = 1
	ensureFolder()
	hardCleanup()
	L.WavePathLines.rebuild()
	L.WaveEndVfx.refreshLocalEndHeart()
	WaveSim.fireNaturalWavePrepare()
	beginWave(1)
	WaveSim.fireNaturalWaveAdvance()
	notifyHud()
	flushHud()
	attachSimLoop(myToken)
	return true
end

function WaveSim.isJoinIntroDemo(): boolean
	return joinIntroDemo
end

function WaveSim.startJoinIntroDemo(coralParts: { BasePart }, wave: number?): boolean
	if running then
		WaveSim.stop({ silent = true })
	end
	WaveSim.stopPlanningArrowPreview()
	local w = math.max(1, math.floor(tonumber(wave) or 100))
	demoCoralParts = coralParts
	joinIntroDemo = true
	-- Plot1 remap + HungryFish often stream a beat after join on device.
	do
		local deadline = os.clock() + 3
		while os.clock() < deadline do
			if ClientPlot.get() and ClientPlot.getPlot1CFrame() and WaveEntityPool.hasFishKind(WaveEntityPool.FISH_TANG) then
				break
			end
			task.wait(0.1)
		end
	end
	pathData = Path.buildPath(L.SkillStages.MAX_STAGE)
	pathDataA2 = Path.buildNamedPath(C.FISH_ROUTE_A2_NAME, L.SkillStages.MAX_STAGE)
	-- Intro has no crabs/urchins — skip ground-route build.
	pathDataGroundA, pathDataGroundB = nil, nil
	pathDataShark = WaveShark.buildLocal()
	if not pathData then
		demoCoralParts = nil
		joinIntroDemo = false
		warn("[WAVE] JoinIntro demo: path build failed")
		return false
	end
	if not WaveEntityPool.hasFishKind(WaveEntityPool.FISH_TANG) then
		demoCoralParts = nil
		joinIntroDemo = false
		warn("[WAVE] JoinIntro demo: HungryFish missing")
		return false
	end
	token += 1
	local myToken = token
	running = true
	waveIndex = 0
	reefMaxHealth = math.max(reefMaxFromSkills(), C.REEF_START_HEALTH)
	reefHealth = reefMaxHealth
	fishFed = 0
	L.WaveEndVfx.resetStreak()
	feedPitchCursor = C.FEED_PITCH_MIN
	startedAt = os.clock()
	simClock = 0
	resetSpeedState()
	combatAcc = 0
	nextFishId = 1
	ensureFolder()
	hardCleanup()
	demoCoralParts = coralParts
	joinIntroDemo = true
	-- Don't paint the MAX-stage ribbon during the showcase; ink draws the real route after handoff.
	L.WavePathLines.destroy()
	L.WaveEndVfx.refreshLocalEndHeart()
	L.WaveEndVfx.setHappyExitVisible(false)
	HungerUi.applyCritterHungerBarsVisible()
	beginWave(w)
	seedJoinIntroHalfway()
	HungerUi.applyCritterHungerBarsVisible()
	notifyHud()
	flushHud()
	attachSimLoop(myToken)
	return true
end

function WaveSim.stopJoinIntroDemo()
	if not joinIntroDemo and not running then
		demoCoralParts = nil
		return
	end
	local preserveAmmoFade = false
	local preserveCritterFade = false
	if joinIntroDemo and running then
		-- Schedule critters before ammo so stopOrphanAmmoFade inside ammo schedule
		-- doesn't wipe a prior critter list — ammo schedule clears both; call ammo first
		-- then critters, or combine. scheduleOrphanAmmoFadeOut calls stopOrphanAmmoFade
		-- which would clear critters — so schedule critters AFTER ammo.
		preserveAmmoFade = Feed.scheduleOrphanAmmoFadeOut(JOIN_INTRO_AMMO_FADE_SEC, JOIN_INTRO_AMMO_FADE_SPREAD) > 0
		preserveCritterFade = Feed.scheduleOrphanCritterFadeOut(JOIN_INTRO_AMMO_FADE_SEC, JOIN_INTRO_AMMO_FADE_SPREAD) > 0
	end
	WaveSim.stop({
		silent = true,
		preserveAmmoFade = preserveAmmoFade,
		preserveCritterFade = preserveCritterFade,
	})
	-- Replace MAX-stage intro path with the player's current Plot Size route (no ribbon flash).
	pathData = Path.buildPath()
	pathDataA2 = Path.buildNamedPath(C.FISH_ROUTE_A2_NAME)
	pathDataGroundA, pathDataGroundB = WaveCrab.buildBothLocal()
	pathDataShark = WaveShark.buildLocal()
	L.WavePathLines.destroy()
	-- Intro stamps used the showcase path. The next real wave must stamp again.
	Feed._bucketsReady = false
	Feed._deferBucketRebuild = false
end

function WaveSim.rebuildRouteForPlotSize(plotSizeStage: number?, opts: { skipPathLines: boolean? }?): boolean
	local p = Path.buildPath(plotSizeStage)
	if not p then
		return false
	end
	pathData = p
	pathDataA2 = Path.buildNamedPath(C.FISH_ROUTE_A2_NAME, plotSizeStage)
	pathDataGroundA, pathDataGroundB = WaveCrab.buildBothLocal()
	pathDataShark = WaveShark.buildLocal()
	if not (opts and opts.skipPathLines) and not L.WavePathLines.isRevealing() then
		L.WavePathLines.rebuild()
	end
	-- Fish already past the new end finish there; others keep swimming on the longer/shorter route.
	for _, agent in ipairs(fishList) do
		if agent.isCrab or agent.isUrchin or agent.isShark then
			continue
		end
		if not agent.finished and agent.dist >= p.totalLen then
			finishFish(agent)
		end
	end
	if running then
		refreshCoralPathProjections()
		Feed._bucketsReady = true
		notifyHud()
		flushHud()
	elseif not joinIntroDemo and L.InventoryState.isOpen() then
		Feed._bucketsReady = false
		Feed._deferBucketRebuild = true
	else
		refreshCoralPathProjections()
		ensureCoralPathBucketIndex()
		Feed._bucketsReady = pathData ~= nil
	end
	if not running and planningArrows then
		local planningOpts = {
			playSound = false,
			includeShark = false,
			forceGroundTrains = false,
			greenLabelText = "FISH PATH",
		}
		L.WaveArrowPreview.setTickSpeedMult(0.5)
		if not L.WaveArrowPreview.hasActiveGreenTrains() then
			L.WaveArrowPreview.startGreen(planningOpts)
		end
		-- Do not re-trigger FISH PATH cinematic on route rebuild.
	end
	return true
end

function WaveSim.getSpeedMult(): number
	return speedMult
end

function WaveSim.isSpeedPaused(): boolean
	return speedMult <= 1e-6
end

local function setCinematicSpeedPauseAttr(on: boolean)
	local pg = Players.LocalPlayer and Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if pg then
		pg:SetAttribute("OceanTD_CinematicSpeedPause", if on then true else nil)
	end
end

-- Intro cinematics (urchin/shark path tours): pause without requiring Wave Speed stage 4.
-- resumeMult (optional): speed to restore on unpause (path tours pass 1 for normal play).
function WaveSim.setCinematicPaused(paused: boolean, resumeMult: number?)
	if paused then
		if speedMult > 1e-6 then
			cinematicResumeSpeed = speedMult
			applySpeedPauseState(true)
			speedMult = 0
			setCinematicSpeedPauseAttr(true)
			notifyHud()
		elseif cinematicResumeSpeed == nil then
			cinematicResumeSpeed = 1
			setCinematicSpeedPauseAttr(true)
			notifyHud()
		else
			setCinematicSpeedPauseAttr(true)
		end
		return
	end
	local resume = if typeof(resumeMult) == "number" and (resumeMult :: number) > 1e-6
		then (resumeMult :: number)
		else (cinematicResumeSpeed or 1)
	cinematicResumeSpeed = nil
	setCinematicSpeedPauseAttr(false)
	if speedMult <= 1e-6 then
		applySpeedPauseState(false)
		speedMult = if resume > 1e-6 then resume else 1
		notifyHud()
	end
end

function WaveSim.isCinematicSpeedPaused(): boolean
	local pg = Players.LocalPlayer and Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
	return pg ~= nil and pg:GetAttribute("OceanTD_CinematicSpeedPause") == true
end

-- Cycle within unlocked steps: 1 → 1.5 → 2 → (pause if stage 4) → 1.
function WaveSim.cycleSpeed(maxStep: number?): number
	local cap = math.clamp(math.floor(tonumber(maxStep) or 3), 1, #SPEED_STEPS)
	local n = if cap >= 4 then 4 else math.min(cap, 3)
	local idx = 1
	local found = false
	for i = 1, n do
		if math.abs(speedMult - SPEED_STEPS[i]) < 1e-4 then
			idx = i
			found = true
			break
		end
	end
	if not found then
		-- Paused without unlock, or unknown mult → start from normal.
		if speedMult <= 1e-6 and n < 4 then
			idx = n -- will wrap to 1
		else
			idx = 1
		end
	end
	idx = idx % n + 1
	local wasPaused = speedMult <= 1e-6
	speedMult = SPEED_STEPS[idx]
	local nowPaused = speedMult <= 1e-6
	if wasPaused ~= nowPaused then
		applySpeedPauseState(nowPaused)
	end
	notifyHud()
	return speedMult
end

function WaveSim.clampSpeedToMaxStep(maxStep: number)
	local cap = math.clamp(math.floor(tonumber(maxStep) or 3), 1, #SPEED_STEPS)
	if speedMult <= 1e-6 then
		if cap < 4 then
			applySpeedPauseState(false)
			speedMult = 1
			notifyHud()
		end
		return
	end
	local maxPlay = math.min(cap, 3)
	local allowed = SPEED_STEPS[maxPlay]
	if speedMult > allowed + 1e-4 then
		speedMult = allowed
		notifyHud()
	end
end

function WaveSim.formatClock(sec: number): string
	local s = math.max(0, math.floor(sec + 0.5))
	local h = s // 3600
	local m = (s % 3600) // 60
	local r = s % 60
	return string.format("%02d:%02d:%02d", h, m, r)
end

-- After intro ends (player in control): show planning trains until Start Waves.
do
	local pg = Players.LocalPlayer:WaitForChild("PlayerGui") :: PlayerGui
	local function onIntroBusyChanged()
		if pg:GetAttribute("OceanTD_JoinIntroBusy") == true then
			-- Intro claimed control — never show planning trains during it.
			WaveSim.stopPlanningArrowPreview()
			return
		end
		-- Busy cleared: finishCam / freeze unlock settle, then spawn trains.
		task.defer(function()
			task.wait(0.2)
			tryStartPlanningAfterIntro()
		end)
	end
	pg:GetAttributeChangedSignal("OceanTD_JoinIntroBusy"):Connect(onIntroBusyChanged)
	-- Give JoinIntro a moment to set Busy=true; only auto-start if intro never claims it.
	task.defer(function()
		task.wait(1)
		if pg:GetAttribute("OceanTD_JoinIntroBusy") == true then
			return
		end
		tryStartPlanningAfterIntro()
	end)
end

L.InventoryState.onOpenChanged(function(isOpen: boolean)
	if isOpen or joinIntroDemo or not Feed._deferBucketRebuild then
		return
	end
	if not pathData then
		pathData = Path.buildPath()
		pathDataA2 = Path.buildNamedPath(C.FISH_ROUTE_A2_NAME)
		pathDataGroundA, pathDataGroundB = WaveCrab.buildBothLocal()
		pathDataShark = WaveShark.buildLocal()
	end
	-- Membership first, while stamps are still deferred, then one pass for the whole plot.
	syncCorals(false)
	Feed._deferBucketRebuild = false
	refreshCoralPathProjections()
	ensureCoralPathBucketIndex()
	Feed._bucketsReady = pathData ~= nil
end)

ClientPlot.onChanged(function()
	if planningArrows or introStillBusy() then
		return
	end
	task.defer(tryStartPlanningAfterIntro)
end)

task.defer(function()
	L.PlacedCoralIndex.ensure()
	placedCoralCount = L.PlacedCoralIndex.countLocal()
	L.PlacedCoralIndex.onChanged(function()
		placedCoralCount = L.PlacedCoralIndex.countLocal()
		if placedCoralCount > 0 then
			L.WaveArrowPreview.setPlanningLegendVisible(false)
		elseif planningArrows then
			-- Plot cleared while still in pre-wave planning — replay FISH PATH.
			syncPlanningLegendVisible(true)
		end
	end)
end)

return WaveSim
