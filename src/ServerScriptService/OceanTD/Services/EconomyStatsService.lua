--!strict
--[[
	Lifetime wave-economy telemetry (per-player on profile + global aggregate DataStore).
	UI: RequestGetSandDollarStats → getPayload().
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")

local oceanShared = game:GetService("ReplicatedStorage"):WaitForChild("OceanTD"):WaitForChild("Shared")
local EconomyStats = require(oceanShared:WaitForChild("EconomyStats"))
local SkillStages = require(oceanShared:WaitForChild("SkillStages"))

type PlayerEconomy = EconomyStats.PlayerEconomy
type SpeedBuckets = EconomyStats.SpeedBuckets
type WaveTimeAgg = EconomyStats.WaveTimeAgg

local EconomyStatsService = {}

local globalStore: DataStore? = nil
local publishQueued: { [Player]: boolean } = {}
local waveEarnThisWave: { [Player]: number } = {}
local wavePlayThisWave: { [Player]: number } = {}
local pendingWaveCompletes: { { wave: number, sec: number } } = {}
local waveTimesFlushQueued = false
local cachedPayload: { at: number, data: any }? = nil
local CACHE_TTL = 15

-- Lazy require to avoid PersistenceService ↔ EconomyStatsService cycles.
local function Persist()
	return require(script.Parent:WaitForChild("PersistenceService"))
end

local function getGlobalStore(): DataStore
	if globalStore then
		return globalStore
	end
	globalStore = DataStoreService:GetDataStore(EconomyStats.GLOBAL_STORE_NAME)
	return globalStore :: DataStore
end

local function emptySpeed(): SpeedBuckets
	return { s1 = 0, s15 = 0, s2 = 0 }
end

type GlobalAgg = {
	version: number,
	snapshots: { [string]: PlayerEconomy },
	introPadUserIds: { [string]: boolean },
	waveTimes: { [string]: WaveTimeAgg },
}

local function defaultGlobal(): GlobalAgg
	return {
		version = 1,
		snapshots = {},
		introPadUserIds = {},
		waveTimes = {},
	}
end

local function sanitizeGlobal(raw: any): GlobalAgg
	local g = defaultGlobal()
	if typeof(raw) ~= "table" then
		return g
	end
	if typeof(raw.snapshots) == "table" then
		local n = 0
		for uid, snap in pairs(raw.snapshots) do
			if typeof(uid) == "string" and n < EconomyStats.MAX_TRACKED_PLAYERS then
				g.snapshots[uid] = EconomyStats.sanitizePlayer(snap)
				n += 1
			end
		end
	end
	if typeof(raw.introPadUserIds) == "table" then
		for uid, flag in pairs(raw.introPadUserIds) do
			if typeof(uid) == "string" and flag == true then
				g.introPadUserIds[uid] = true
			end
		end
	end
	g.waveTimes = EconomyStats.sanitizeWaveTimesMap(raw.waveTimes)
	return g
end

local function ensurePlayerEcon(profile: any): PlayerEconomy
	if typeof(profile.economyStats) ~= "table" then
		profile.economyStats = EconomyStats.defaultPlayer()
	else
		profile.economyStats = EconomyStats.sanitizePlayer(profile.economyStats)
	end
	return profile.economyStats
end

local function addSpeed(dst: SpeedBuckets, key: string, amount: number)
	local a = math.max(0, amount)
	if key == "s15" then
		dst.s15 += a
	elseif key == "s2" then
		dst.s2 += a
	else
		dst.s1 += a
	end
end

function EconomyStatsService.noteFeed(player: Player, granted: number, fishCount: number, speedMult: number?)
	local profile = Persist().getProfile(player)
	if not profile then
		return
	end
	local econ = ensurePlayerEcon(profile)
	local grant = math.max(0, math.floor(tonumber(granted) or 0))
	local fish = math.max(0, math.floor(tonumber(fishCount) or 0))
	if grant <= 0 and fish <= 0 then
		return
	end
	econ.waveEarned += grant
	econ.fishFed += fish
	local key = EconomyStats.speedKey(tonumber(speedMult) or 1)
	addSpeed(econ.speedEarned, key, grant)
	waveEarnThisWave[player] = (waveEarnThisWave[player] or 0) + grant
end

function EconomyStatsService.noteWavePlay(player: Player, playBySpeed: any, waveEnded: boolean?)
	local profile = Persist().getProfile(player)
	if not profile then
		return
	end
	local econ = ensurePlayerEcon(profile)
	if typeof(playBySpeed) ~= "table" then
		return
	end
	local added = 0
	for _, key in ipairs({ "s1", "s15", "s2" }) do
		local sec = math.max(0, tonumber(playBySpeed[key]) or 0)
		-- Cap per flush (anti-exploit): 30s
		sec = math.min(sec, 30)
		if sec > 0 then
			addSpeed(econ.speedPlaySec, key, sec)
			econ.wavePlaySec += sec
			added += sec
		end
	end
	if added > 0 then
		wavePlayThisWave[player] = (wavePlayThisWave[player] or 0) + added
	end
	if waveEnded == true then
		local earned = waveEarnThisWave[player] or 0
		local played = wavePlayThisWave[player] or 0
		if earned <= 0 and played > 0.5 then
			econ.deadWavePlaySec += played
			econ.deadWaveCount += 1
		end
		waveEarnThisWave[player] = 0
		wavePlayThisWave[player] = 0
	end
end

local function flushPendingWaveTimes()
	waveTimesFlushQueued = false
	local batch = pendingWaveCompletes
	pendingWaveCompletes = {}
	if #batch < 1 then
		return
	end
	local ok, err = pcall(function()
		getGlobalStore():UpdateAsync(EconomyStats.GLOBAL_KEY, function(old)
			local g = sanitizeGlobal(old)
			for _, entry in ipairs(batch) do
				local key = tostring(entry.wave)
				local prev = g.waveTimes[key] or EconomyStats.defaultWaveTime()
				g.waveTimes[key] = EconomyStats.applyWaveSample(prev, entry.sec)
			end
			return g
		end)
	end)
	if not ok then
		warn("[EconomyStats] waveTimes flush failed", err)
	end
	cachedPayload = nil
end

-- Completed wave duration (unpaused wall clock). Batched into the global aggregate.
function EconomyStatsService.noteWaveDuration(_player: Player, wave: any, durationSec: any)
	local w = math.floor(tonumber(wave) or 0)
	local sec = tonumber(durationSec) or 0
	if w < 1 or w > EconomyStats.WAVE_TIME_TRACK_MAX then
		return
	end
	if typeof(sec) ~= "number" or sec ~= sec or sec < 0.5 then
		return
	end
	sec = math.min(sec, 3600)
	table.insert(pendingWaveCompletes, { wave = w, sec = sec })
	if waveTimesFlushQueued then
		return
	end
	waveTimesFlushQueued = true
	task.delay(3, flushPendingWaveTimes)
end

function EconomyStatsService.noteIntroPadFreeBuy(player: Player)
	local profile = Persist().getProfile(player)
	if not profile then
		return
	end
	local econ = ensurePlayerEcon(profile)
	econ.introPadFreeBuys += 1
	econ.usedIntroPad = true
end

function EconomyStatsService.noteSkillStagesChanged(player: Player)
	local profile = Persist().getProfile(player)
	if not profile then
		return
	end
	local econ = ensurePlayerEcon(profile)
	local stages = SkillStages.sanitizeMap(profile.skillStages)
	-- Prefer wave playtime for "how long to max while progressing".
	local clock = econ.wavePlaySec
	if clock < 1 then
		clock = math.max(0, tonumber(profile.lifetimePlaySec) or 0)
	end
	if clock < 1 then
		return
	end
	if econ.playSecToFirstSkillMax == nil and EconomyStats.anySkillMaxed(stages) then
		econ.playSecToFirstSkillMax = clock
	end
	if econ.playSecToAllSkillsMax == nil and EconomyStats.allSkillsMaxed(stages) then
		econ.playSecToAllSkillsMax = clock
	end
end

local function buildRates(g: GlobalAgg): { number }
	local rates: { number } = {}
	for _, snap in pairs(g.snapshots) do
		local r = EconomyStats.waveDollarsPerMin(snap)
		if r > 0 and snap.wavePlaySec >= 30 then
			table.insert(rates, r)
		end
	end
	table.sort(rates)
	return rates
end

local function sumSpeed(snaps: { [string]: PlayerEconomy }, field: "speedPlaySec" | "speedEarned"): SpeedBuckets
	local out = emptySpeed()
	for _, snap in pairs(snaps) do
		local b = (snap :: any)[field] :: SpeedBuckets
		out.s1 += b.s1
		out.s15 += b.s15
		out.s2 += b.s2
	end
	return out
end

local function publishSnapshot(player: Player)
	local profile = Persist().getProfile(player)
	if not profile then
		return
	end
	local econ = EconomyStats.clonePlayer(ensurePlayerEcon(profile))
	local uid = tostring(player.UserId)
	local ok, err = pcall(function()
		getGlobalStore():UpdateAsync(EconomyStats.GLOBAL_KEY, function(old)
			local g = sanitizeGlobal(old)
			g.snapshots[uid] = econ
			if econ.usedIntroPad then
				g.introPadUserIds[uid] = true
			end
			-- Cap map size (drop oldest-looking zero-rate entries first).
			local count = 0
			for _ in pairs(g.snapshots) do
				count += 1
			end
			if count > EconomyStats.MAX_TRACKED_PLAYERS then
				for id, snap in pairs(g.snapshots) do
					if id ~= uid and snap.wavePlaySec < 1 then
						g.snapshots[id] = nil
						count -= 1
						if count <= EconomyStats.MAX_TRACKED_PLAYERS then
							break
						end
					end
				end
			end
			return g
		end)
	end)
	if not ok then
		warn("[EconomyStats] publish failed", player.Name, err)
	end
end

function EconomyStatsService.queuePublish(player: Player)
	if publishQueued[player] then
		return
	end
	publishQueued[player] = true
	task.delay(2, function()
		publishQueued[player] = nil
		if player.Parent then
			publishSnapshot(player)
		end
	end)
end

function EconomyStatsService.flushPublish(player: Player)
	publishQueued[player] = nil
	publishSnapshot(player)
end

function EconomyStatsService.onPlayerLeaving(player: Player)
	waveEarnThisWave[player] = nil
	wavePlayThisWave[player] = nil
	publishQueued[player] = nil
	publishSnapshot(player)
end

local function computeGlobalPayload(g: GlobalAgg): any
	local rates = buildRates(g)
	local n = 0
	local sumPlay = 0
	local sumEarn = 0
	local sumFish = 0
	local sumDeadPlay = 0
	local sumDeadCount = 0
	local firstMaxN, firstMaxSum = 0, 0
	local allMaxN, allMaxSum = 0, 0
	for _uid, snap in pairs(g.snapshots) do
		n += 1
		sumPlay += snap.wavePlaySec
		sumEarn += snap.waveEarned
		sumFish += snap.fishFed
		sumDeadPlay += snap.deadWavePlaySec
		sumDeadCount += snap.deadWaveCount
		if typeof(snap.playSecToFirstSkillMax) == "number" then
			firstMaxN += 1
			firstMaxSum += snap.playSecToFirstSkillMax
		end
		if typeof(snap.playSecToAllSkillsMax) == "number" then
			allMaxN += 1
			allMaxSum += snap.playSecToAllSkillsMax
		end
	end
	local introN = 0
	for _ in pairs(g.introPadUserIds) do
		introN += 1
	end
	local speedPlay = sumSpeed(g.snapshots, "speedPlaySec")
	local speedEarn = sumSpeed(g.snapshots, "speedEarned")
	local function rateFor(key: string): number
		local p = (speedPlay :: any)[key]
		local e = (speedEarn :: any)[key]
		if typeof(p) ~= "number" or p < 1 then
			return 0
		end
		return (e / p) * 60
	end
	local avgRate = EconomyStats.mean(rates)
	local low = EconomyStats.percentile(rates, 0.10)
	local mid = EconomyStats.percentile(rates, 0.50)
	local high = EconomyStats.percentile(rates, 0.90)
	local pooledRate = if sumPlay >= 1 then (sumEarn / sumPlay) * 60 else 0
	local perFish = if sumFish >= 1 then sumEarn / sumFish else 0
	local baseRate = rateFor("s1")
	local r15 = rateFor("s15")
	local r2 = rateFor("s2")
	local perWave: { [number]: { avg: number, fast: number, slow: number, samples: number } } = {}
	for i = 1, EconomyStats.WAVE_TIME_TRACK_MAX do
		local agg = g.waveTimes[tostring(i)]
		if agg and agg.count > 0 then
			perWave[i] = {
				avg = agg.sumSec / agg.count,
				fast = agg.minSec,
				slow = agg.maxSec,
				samples = agg.count,
			}
		end
	end
	return {
		playersTracked = n,
		playersWithRate = #rates,
		waveDollarsPerMin = {
			avg = avgRate,
			median = mid,
			low = low,
			high = high,
			pooled = pooledRate,
		},
		dollarsPerFish = perFish,
		totalWavePlaySec = sumPlay,
		totalWaveEarned = sumEarn,
		totalFishFed = sumFish,
		minutesToMaxOneSkill = if firstMaxN > 0 then (firstMaxSum / firstMaxN) / 60 else nil,
		minutesToMaxAllSkills = if allMaxN > 0 then (allMaxSum / allMaxN) / 60 else nil,
		skillMaxOnePlayers = firstMaxN,
		skillMaxAllPlayers = allMaxN,
		waveSpeed = {
			rate1 = baseRate,
			rate15 = r15,
			rate2 = r2,
			inflate15 = if baseRate > 0.01 then r15 / baseRate else 0,
			inflate2 = if baseRate > 0.01 then r2 / baseRate else 0,
			playSec1 = speedPlay.s1,
			playSec15 = speedPlay.s15,
			playSec2 = speedPlay.s2,
			earned1 = speedEarn.s1,
			earned15 = speedEarn.s15,
			earned2 = speedEarn.s2,
		},
		deadWavePlaySec = sumDeadPlay,
		deadWaveCount = sumDeadCount,
		introPadPlayers = introN,
		perWave = perWave,
	}
end

function EconomyStatsService.getPayload(player: Player): any
	local now = os.clock()
	local globalData: any = nil
	if cachedPayload and (now - cachedPayload.at) < CACHE_TTL then
		globalData = cachedPayload.data
	else
		local ok, raw = pcall(function()
			return getGlobalStore():GetAsync(EconomyStats.GLOBAL_KEY)
		end)
		local g = sanitizeGlobal(if ok then raw else nil)
		-- Include this player's latest in-memory stats so Studio solo tests look live.
		local profile = Persist().getProfile(player)
		if profile then
			g.snapshots[tostring(player.UserId)] = EconomyStats.clonePlayer(ensurePlayerEcon(profile))
			if ensurePlayerEcon(profile).usedIntroPad then
				g.introPadUserIds[tostring(player.UserId)] = true
			end
		end
		globalData = computeGlobalPayload(g)
		cachedPayload = { at = now, data = globalData }
	end

	local profile = Persist().getProfile(player)
	local you: any = nil
	if profile then
		local econ = ensurePlayerEcon(profile)
		you = {
			wavePlaySec = econ.wavePlaySec,
			waveEarned = econ.waveEarned,
			fishFed = econ.fishFed,
			waveDollarsPerMin = EconomyStats.waveDollarsPerMin(econ),
			dollarsPerFish = EconomyStats.dollarsPerFish(econ),
			deadWavePlaySec = econ.deadWavePlaySec,
			deadWaveCount = econ.deadWaveCount,
			usedIntroPad = econ.usedIntroPad,
			introPadFreeBuys = econ.introPadFreeBuys,
			playSecToFirstSkillMax = econ.playSecToFirstSkillMax,
			playSecToAllSkillsMax = econ.playSecToAllSkillsMax,
			speed = {
				rate1 = EconomyStats.speedDollarsPerMin(econ, "s1"),
				rate15 = EconomyStats.speedDollarsPerMin(econ, "s15"),
				rate2 = EconomyStats.speedDollarsPerMin(econ, "s2"),
			},
			earnMoreStage = Persist().getSkillStage(player, "EarnMore"),
			balance = Persist().getSandDollars(player),
		}
	end

	return {
		global = globalData,
		you = you,
		updatedAt = os.time(),
	}
end

Players.PlayerRemoving:Connect(function(player)
	EconomyStatsService.onPlayerLeaving(player)
end)

return EconomyStatsService
