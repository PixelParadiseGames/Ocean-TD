--!strict
--[[
	Lifetime wave-economy stats shapes + helpers (player profile + global aggregate).
	Rates are $D per minute of unpaused wave playtime.
]]

local SkillStages = require(script.Parent:WaitForChild("SkillStages"))

local EconomyStats = {}

EconomyStats.GLOBAL_STORE_NAME = "OceanTD_EconomyStats_v1"
EconomyStats.GLOBAL_KEY = "aggregate"
EconomyStats.MAX_TRACKED_PLAYERS = 4000
EconomyStats.WAVE_TIME_TRACK_MAX = 50

export type SpeedBuckets = {
	s1: number,
	s15: number,
	s2: number,
}

-- Global aggregate of completed-wave durations (unpaused wall clock).
export type WaveTimeAgg = {
	sumSec: number,
	count: number,
	minSec: number,
	maxSec: number,
}

export type PlayerEconomy = {
	wavePlaySec: number,
	waveEarned: number,
	fishFed: number,
	speedPlaySec: SpeedBuckets,
	speedEarned: SpeedBuckets,
	deadWavePlaySec: number,
	deadWaveCount: number,
	usedIntroPad: boolean,
	introPadFreeBuys: number,
	playSecToFirstSkillMax: number?,
	playSecToAllSkillsMax: number?,
}

local function emptySpeed(): SpeedBuckets
	return { s1 = 0, s15 = 0, s2 = 0 }
end

function EconomyStats.defaultPlayer(): PlayerEconomy
	return {
		wavePlaySec = 0,
		waveEarned = 0,
		fishFed = 0,
		speedPlaySec = emptySpeed(),
		speedEarned = emptySpeed(),
		deadWavePlaySec = 0,
		deadWaveCount = 0,
		usedIntroPad = false,
		introPadFreeBuys = 0,
		playSecToFirstSkillMax = nil,
		playSecToAllSkillsMax = nil,
	}
end

local function clampNonNeg(n: any): number
	local v = tonumber(n)
	if typeof(v) ~= "number" or v ~= v or v < 0 then
		return 0
	end
	return v
end

local function sanitizeSpeed(raw: any): SpeedBuckets
	local out = emptySpeed()
	if typeof(raw) ~= "table" then
		return out
	end
	out.s1 = clampNonNeg(raw.s1)
	out.s15 = clampNonNeg(raw.s15)
	out.s2 = clampNonNeg(raw.s2)
	return out
end

function EconomyStats.sanitizePlayer(raw: any): PlayerEconomy
	local d = EconomyStats.defaultPlayer()
	if typeof(raw) ~= "table" then
		return d
	end
	d.wavePlaySec = clampNonNeg(raw.wavePlaySec)
	d.waveEarned = math.floor(clampNonNeg(raw.waveEarned))
	d.fishFed = math.floor(clampNonNeg(raw.fishFed))
	d.speedPlaySec = sanitizeSpeed(raw.speedPlaySec)
	d.speedEarned = sanitizeSpeed(raw.speedEarned)
	d.deadWavePlaySec = clampNonNeg(raw.deadWavePlaySec)
	d.deadWaveCount = math.floor(clampNonNeg(raw.deadWaveCount))
	d.usedIntroPad = raw.usedIntroPad == true
	d.introPadFreeBuys = math.floor(clampNonNeg(raw.introPadFreeBuys))
	local firstMax = tonumber(raw.playSecToFirstSkillMax)
	if firstMax and firstMax > 0 then
		d.playSecToFirstSkillMax = firstMax
	end
	local allMax = tonumber(raw.playSecToAllSkillsMax)
	if allMax and allMax > 0 then
		d.playSecToAllSkillsMax = allMax
	end
	return d
end

function EconomyStats.clonePlayer(src: PlayerEconomy): PlayerEconomy
	return EconomyStats.sanitizePlayer(src)
end

function EconomyStats.speedKey(mult: number): string
	if mult >= 1.75 then
		return "s2"
	end
	if mult >= 1.25 then
		return "s15"
	end
	return "s1"
end

function EconomyStats.waveDollarsPerMin(econ: PlayerEconomy): number
	local sec = econ.wavePlaySec
	if sec < 1 then
		return 0
	end
	return (econ.waveEarned / sec) * 60
end

function EconomyStats.dollarsPerFish(econ: PlayerEconomy): number
	if econ.fishFed < 1 then
		return 0
	end
	return econ.waveEarned / econ.fishFed
end

function EconomyStats.speedDollarsPerMin(econ: PlayerEconomy, key: string): number
	local play = (econ.speedPlaySec :: any)[key]
	local earned = (econ.speedEarned :: any)[key]
	if typeof(play) ~= "number" or play < 1 then
		return 0
	end
	return ((tonumber(earned) or 0) / play) * 60
end

function EconomyStats.allSkillsMaxed(stages: { [string]: number }): boolean
	for _, def in ipairs(SkillStages.all()) do
		local s = SkillStages.clampStageFor(def.id, stages[def.id])
		if s < SkillStages.maxStageFor(def.id) then
			return false
		end
	end
	return true
end

function EconomyStats.anySkillMaxed(stages: { [string]: number }): boolean
	for _, def in ipairs(SkillStages.all()) do
		local s = SkillStages.clampStageFor(def.id, stages[def.id])
		if s >= SkillStages.maxStageFor(def.id) then
			return true
		end
	end
	return false
end

function EconomyStats.percentile(sortedAsc: { number }, p: number): number
	local n = #sortedAsc
	if n < 1 then
		return 0
	end
	local rank = math.clamp(math.ceil(n * math.clamp(p, 0, 1)), 1, n)
	return sortedAsc[rank]
end

function EconomyStats.mean(values: { number }): number
	local n = #values
	if n < 1 then
		return 0
	end
	local sum = 0
	for _, v in ipairs(values) do
		sum += v
	end
	return sum / n
end

function EconomyStats.defaultWaveTime(): WaveTimeAgg
	return {
		sumSec = 0,
		count = 0,
		minSec = 0,
		maxSec = 0,
	}
end

function EconomyStats.sanitizeWaveTime(raw: any): WaveTimeAgg
	local d = EconomyStats.defaultWaveTime()
	if typeof(raw) ~= "table" then
		return d
	end
	d.sumSec = clampNonNeg(raw.sumSec)
	d.count = math.floor(clampNonNeg(raw.count))
	d.minSec = clampNonNeg(raw.minSec)
	d.maxSec = clampNonNeg(raw.maxSec)
	if d.count < 1 then
		return EconomyStats.defaultWaveTime()
	end
	if d.minSec <= 0 then
		d.minSec = d.sumSec / d.count
	end
	if d.maxSec < d.minSec then
		d.maxSec = d.minSec
	end
	return d
end

function EconomyStats.applyWaveSample(agg: WaveTimeAgg, sec: number): WaveTimeAgg
	local s = clampNonNeg(sec)
	if s < 0.5 then
		return agg
	end
	-- Cap outliers (anti-exploit / AFK pause leaks).
	s = math.min(s, 3600)
	local out = {
		sumSec = agg.sumSec + s,
		count = agg.count + 1,
		minSec = if agg.count < 1 then s else math.min(agg.minSec, s),
		maxSec = if agg.count < 1 then s else math.max(agg.maxSec, s),
	}
	return out
end

function EconomyStats.sanitizeWaveTimesMap(raw: any): { [string]: WaveTimeAgg }
	local out: { [string]: WaveTimeAgg } = {}
	if typeof(raw) ~= "table" then
		return out
	end
	for key, val in pairs(raw) do
		local w = tonumber(key)
		if typeof(w) == "number" then
			local wi = math.floor(w)
			if wi >= 1 and wi <= EconomyStats.WAVE_TIME_TRACK_MAX then
				local agg = EconomyStats.sanitizeWaveTime(val)
				if agg.count > 0 then
					out[tostring(wi)] = agg
				end
			end
		end
	end
	return out
end

return EconomyStats
