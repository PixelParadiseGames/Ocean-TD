--!strict
--[[
	Theoretical per-wave economy bounds for the $D Economy report.
	$D = fed units × Earn More stage (1–8). Spawn ranges from WaveSimConsts.
	Times are 1× sim-clock estimates: fastest = early-finish after last spawn;
	slowest = last unit clears its path (max plot / slow speeds / max spawns).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SkillStages = require(ReplicatedStorage:WaitForChild("OceanTD"):WaitForChild("Shared"):WaitForChild("SkillStages"))
local C = require(script.Parent:WaitForChild("WaveSimConsts"))

local WaveEconomyPlanner = {}

WaveEconomyPlanner.WAVE_COUNT = 50

-- Reference path lengths (studs) at Plot Size stage 1 (ends ~W4). Scaled by waypoint ratio.
local REF_FISH_PATH = 280
local REF_GROUND_PATH = 240
local EARLY_FEED_BUFFER = 0.45 -- seconds after last spawn before early-finish is realistic

export type WaveColumn = {
	wave: number,
	fish: number,
	crabMin: number,
	crabMax: number,
	urchinMin: number,
	urchinMax: number,
	shark: number,
	unitsMin: number,
	unitsMax: number,
	dollarsMin: number,
	dollarsMax: number,
	avgSec: number,
	fastSec: number,
	slowSec: number,
}

local function fishCount(wave: number): number
	local full = C.WAVE1_COUNT + (wave - 1) * C.WAVE_COUNT_STEP
	return math.max(1, math.floor(full * 0.5 + 0.5))
end

local function spawnGap(wave: number): number
	local w = math.max(1, math.floor(wave))
	local gap = C.STAGGER_SEC * (C.STAGGER_PER_WAVE_MULT ^ (w - 1))
	return math.max(C.STAGGER_MIN_SEC, gap)
end

local function sharkCount(wave: number): number
	local w = math.max(1, math.floor(wave))
	if w >= C.SHARK_FIRST_WAVE and w % C.SHARK_EVERY_WAVES == 0 then
		return 1
	end
	return 0
end

local function plotPathMult(stage: number): number
	local wp = SkillStages.plotSizeFinalWaypoint(stage)
	return math.max(0.75, wp / 4)
end

local function fishTravel(pathLen: number, slow: boolean): number
	local var = C.FISH_SPEED_VAR
	local speed = C.FISH_SPEED * (if slow then (1 - var) else (1 + var))
	return pathLen / math.max(1e-3, speed)
end

local function crabTravel(pathLen: number, slow: boolean): number
	-- Bound sprint duty cycle roughly: rest vs sprint midpoints.
	local base = C.FISH_SPEED * C.CRAB_SPEED_MULT
	local sprint = if slow then C.CRAB_SPRINT_MULT_MIN else C.CRAB_SPRINT_MULT_MAX
	local dur = if slow then C.CRAB_SPRINT_DUR_MIN else C.CRAB_SPRINT_DUR_MAX
	local rest = if slow then C.CRAB_SPRINT_REST_MAX else C.CRAB_SPRINT_REST_MIN
	local cycle = dur + rest
	local avgMult = if cycle > 1e-3 then (1 * rest + sprint * dur) / cycle else 1
	return pathLen / math.max(1e-3, base * avgMult)
end

local function urchinTravel(pathLen: number, slow: boolean): number
	local base = C.FISH_SPEED * C.CRAB_SPEED_MULT * C.URCHIN_SPEED_MULT
	local var = C.URCHIN_SPEED_VAR
	local speed = base * (if slow then (1 - var) else (1 + var))
	return pathLen / math.max(1e-3, speed)
end

-- Last spawn time for n fish (n>=1). gapMult in [0.7, 1.35] matches WaveSim jitter.
local function lastFishSpawn(wave: number, n: number, gapMult: number): number
	if n <= 0 then
		return 0
	end
	local lead = if wave == 1 then C.WAVE1_SPAWN_LEAD_SEC else C.ARROW_LEAD_SEC
	local gap = spawnGap(wave) * gapMult
	return lead + (n - 1) * gap
end

local function lastCrabSpawn(firstFishAt: number, n: number, firstDelay: number, stagger: number): number
	if n <= 0 then
		return 0
	end
	return firstFishAt + firstDelay + (n - 1) * stagger
end

local function lastUrchinSpawn(wave: number, n: number, firstDelay: number, stagger: number): number
	if n <= 0 then
		return 0
	end
	local lead = if wave == 1 then C.WAVE1_SPAWN_LEAD_SEC else firstDelay
	return lead + (n - 1) * stagger
end

local function estimateTimes(wave: number, fish: number, crabLo: number, crabHi: number, urchinLo: number, urchinHi: number): (number, number, number)
	local fishLead = if wave == 1 then C.WAVE1_SPAWN_LEAD_SEC else C.ARROW_LEAD_SEC

	-- Fastest: min spawns, min gaps, early-finish once last gating unit can be fed.
	local firstFishFast = fishLead
	local lastFishFast = lastFishSpawn(wave, fish, 0.7)
	local lastCrabFast = lastCrabSpawn(firstFishFast, crabLo, C.CRAB_FIRST_DELAY_MIN, C.CRAB_STAGGER_MIN)
	local lastUrchinFast = lastUrchinSpawn(wave, urchinLo, C.URCHIN_FIRST_DELAY_MIN, C.URCHIN_STAGGER_MIN)
	local fastSec = math.max(lastFishFast, lastCrabFast, lastUrchinFast) + EARLY_FEED_BUFFER

	-- Slowest: max spawns, max gaps, max plot path, slow speeds, full clear (no early finish).
	local pathFish = REF_FISH_PATH * plotPathMult(SkillStages.MAX_STAGE)
	local pathGround = REF_GROUND_PATH * plotPathMult(SkillStages.MAX_STAGE)
	local firstFishSlow = fishLead
	local lastFishSlow = lastFishSpawn(wave, fish, 1.35)
	local lastCrabSlow = lastCrabSpawn(firstFishSlow, crabHi, C.CRAB_FIRST_DELAY_MAX, C.CRAB_STAGGER_MAX)
	local lastUrchinSlow = lastUrchinSpawn(wave, urchinHi, C.URCHIN_FIRST_DELAY_MAX, C.URCHIN_STAGGER_MAX)
	local fishArrive = lastFishSlow + fishTravel(pathFish, true)
	local crabArrive = if crabHi > 0 then lastCrabSlow + crabTravel(pathGround, true) else 0
	local urchinArrive = if urchinHi > 0 then lastUrchinSlow + urchinTravel(pathGround, true) else 0
	local slowSec = math.max(fishArrive, crabArrive, urchinArrive, fastSec)

	-- Mid: expected spawn counts, mid gaps, mid plot, travel clear (typical no early-finish).
	local crabMid = math.floor((crabLo + crabHi) * 0.5 + 0.5)
	local urchinMid = math.floor((urchinLo + urchinHi) * 0.5 + 0.5)
	local pathFishMid = REF_FISH_PATH * plotPathMult(math.ceil(SkillStages.MAX_STAGE * 0.5))
	local pathGroundMid = REF_GROUND_PATH * plotPathMult(math.ceil(SkillStages.MAX_STAGE * 0.5))
	local lastFishMid = lastFishSpawn(wave, fish, 1.0)
	local lastCrabMid = lastCrabSpawn(fishLead, crabMid, (C.CRAB_FIRST_DELAY_MIN + C.CRAB_FIRST_DELAY_MAX) * 0.5, (C.CRAB_STAGGER_MIN + C.CRAB_STAGGER_MAX) * 0.5)
	local lastUrchinMid = lastUrchinSpawn(
		wave,
		urchinMid,
		(C.URCHIN_FIRST_DELAY_MIN + C.URCHIN_FIRST_DELAY_MAX) * 0.5,
		(C.URCHIN_STAGGER_MIN + C.URCHIN_STAGGER_MAX) * 0.5
	)
	local midFish = lastFishMid + fishTravel(pathFishMid, false) * 0.55 + fishTravel(pathFishMid, true) * 0.45
	local midCrab = if crabMid > 0 then lastCrabMid + crabTravel(pathGroundMid, false) * 0.5 + crabTravel(pathGroundMid, true) * 0.5 else 0
	local midUrchin = if urchinMid > 0
		then lastUrchinMid + urchinTravel(pathGroundMid, false) * 0.5 + urchinTravel(pathGroundMid, true) * 0.5
		else 0
	local avgSec = math.max(midFish, midCrab, midUrchin, fastSec)
	-- Blend toward (fast+slow)/2 so the column reads as a true mid, not only full-clear.
	avgSec = avgSec * 0.55 + (fastSec + slowSec) * 0.225

	return avgSec, fastSec, slowSec
end

function WaveEconomyPlanner.forWave(wave: number): WaveColumn
	local w = math.clamp(math.floor(wave), 1, WaveEconomyPlanner.WAVE_COUNT)
	local fish = fishCount(w)
	local crabLo, crabHi = C.crabCountRangeForWave(w)
	local urchinLo, urchinHi = C.urchinCountRangeForWave(w)
	local shark = sharkCount(w)
	local unitsMin = fish + crabLo + urchinLo + shark
	local unitsMax = fish + crabHi + urchinHi + shark
	local dMin = unitsMin * SkillStages.earnMorePerFish(SkillStages.MIN_STAGE)
	local dMax = unitsMax * SkillStages.earnMorePerFish(SkillStages.MAX_STAGE)
	local avgSec, fastSec, slowSec = estimateTimes(w, fish, crabLo, crabHi, urchinLo, urchinHi)
	return {
		wave = w,
		fish = fish,
		crabMin = crabLo,
		crabMax = crabHi,
		urchinMin = urchinLo,
		urchinMax = urchinHi,
		shark = shark,
		unitsMin = unitsMin,
		unitsMax = unitsMax,
		dollarsMin = dMin,
		dollarsMax = dMax,
		avgSec = avgSec,
		fastSec = fastSec,
		slowSec = slowSec,
	}
end

function WaveEconomyPlanner.all(n: number?): { WaveColumn }
	local count = math.clamp(math.floor(n or WaveEconomyPlanner.WAVE_COUNT), 1, 200)
	local out: { WaveColumn } = table.create(count)
	for i = 1, count do
		out[i] = WaveEconomyPlanner.forWave(i)
	end
	return out
end

return WaveEconomyPlanner
