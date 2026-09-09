--!strict
--[[
	GroundA/GroundB hungry urchins on waves 5, 10, 15… (count scales; +extra past W100); 50/50 route.
	Template: ReplicatedStorage.Fish.Urchin.UrchinMesh (RootPart + ShellHitbox).
	Coral pause = defenseSec / 3.
]]

local WaveCrab = require(script.Parent:WaitForChild("WaveCrab"))
local WaveEntityPool = require(script.Parent:WaitForChild("WaveEntityPool"))
local C = require(script.Parent:WaitForChild("WaveSimConsts"))

local WaveUrchin = {}

local spawnedThisWave = 0
local expectedThisWave = 0
local countRng = Random.new()

function WaveUrchin.shouldSpawn(wave: number): boolean
	local w = math.max(1, math.floor(wave))
	return w >= C.URCHIN_FIRST_WAVE
		and w % C.URCHIN_EVERY_WAVES == 0
		and WaveEntityPool.hasFishKind(WaveEntityPool.FISH_URCHIN)
end

-- Formula max for this ×5 wave (before the −0%…−40% roll).
function WaveUrchin.countForWave(wave: number): number
	if not WaveUrchin.shouldSpawn(wave) then
		return 0
	end
	return C.urchinCountForWave(wave)
end

function WaveUrchin.countRangeForWave(wave: number): (number, number)
	if not WaveUrchin.shouldSpawn(wave) then
		return 0, 0
	end
	return C.urchinCountRangeForWave(wave)
end

-- Uniform roll between max and ~40% fewer (inclusive).
function WaveUrchin.rollCount(wave: number): number
	local lo, hi = WaveUrchin.countRangeForWave(wave)
	if hi <= 0 then
		return 0
	end
	return countRng:NextInteger(lo, hi)
end

function WaveUrchin.hungerForWave(wave: number): number
	return C.crabHungerForWave(wave)
end

function WaveUrchin.speedNow(): number
	return WaveCrab.baseSpeed() * C.URCHIN_SPEED_MULT
end

-- First urchin delay after wave start (seconds).
function WaveUrchin.rollFirstDelay(rng: Random): number
	return rng:NextNumber(C.URCHIN_FIRST_DELAY_MIN, C.URCHIN_FIRST_DELAY_MAX)
end

-- Gap before the next urchin. Mostly wide/random; sometimes a short cluster gap.
function WaveUrchin.rollSpawnGap(rng: Random): number
	local lo = C.URCHIN_STAGGER_MIN
	local hi = C.URCHIN_STAGGER_MAX
	if rng:NextNumber() < C.URCHIN_CLUSTER_CHANCE then
		hi = lo + (hi - lo) * C.URCHIN_CLUSTER_SPAN
	end
	return rng:NextNumber(lo, hi)
end

-- Per-urchin walk mult so equally-timed spawns still drift apart.
function WaveUrchin.rollSpeedMult(rng: Random): number
	local v = C.URCHIN_SPEED_VAR
	return 1 + rng:NextNumber(-v, v)
end

function WaveUrchin.coralPauseSec(defenseSec: number): number
	return math.max(defenseSec / 3, 1e-3)
end

function WaveUrchin.beginWave(expected: number?)
	spawnedThisWave = 0
	expectedThisWave = math.max(0, math.floor(expected or 0))
end

function WaveUrchin.expectedCount(): number
	return expectedThisWave
end

function WaveUrchin.markSpawned()
	spawnedThisWave += 1
end

function WaveUrchin.spawnedCount(): number
	return spawnedThisWave
end

-- Path + combat VFX (shared with crabs on GroundA/GroundB).
WaveUrchin.buildLocal = WaveCrab.buildLocal
WaveUrchin.buildOn = WaveCrab.buildOn
WaveUrchin.sample = WaveCrab.sample
WaveUrchin.worldOnGround = WaveCrab.worldOnGround
WaveUrchin.facingCFrame = WaveCrab.facingCFrame
WaveUrchin.findShell = WaveCrab.findShell
WaveUrchin.shellOverlapsCoral = WaveCrab.shellOverlapsCoral
WaveUrchin.stunCoralPart = WaveCrab.stunCoralPart
WaveUrchin.clearCoralStun = WaveCrab.clearCoralStun
WaveUrchin.playZapBurst = WaveCrab.playZapBurst
WaveUrchin.playDeathSkullFromCoral = WaveCrab.playDeathSkullFromCoral
WaveUrchin.applyFightPose = WaveCrab.applyFightPose
WaveUrchin.pauseElapsed = WaveCrab.pauseElapsed
WaveUrchin.applyPose = WaveCrab.applyPose

return WaveUrchin
