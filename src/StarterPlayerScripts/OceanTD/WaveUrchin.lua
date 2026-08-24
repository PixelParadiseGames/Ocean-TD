--!strict
--[[
	GroundA hungry urchins on waves 10, 20, 30… (count = wave / 10).
	Template: ReplicatedStorage.Fish.Urchin.UrchinMesh (RootPart + ShellHitbox).
	Coral pause = defenseSec / 3.
]]

local WaveCrab = require(script.Parent:WaitForChild("WaveCrab"))
local WaveEntityPool = require(script.Parent:WaitForChild("WaveEntityPool"))
local C = require(script.Parent:WaitForChild("WaveSimConsts"))

local WaveUrchin = {}

local spawnedThisWave = 0
local expectedThisWave = 0

function WaveUrchin.shouldSpawn(wave: number): boolean
	local w = math.max(1, math.floor(wave))
	return w >= C.URCHIN_FIRST_WAVE
		and w % C.URCHIN_EVERY_WAVES == 0
		and WaveEntityPool.hasFishKind(WaveEntityPool.FISH_URCHIN)
end

function WaveUrchin.countForWave(wave: number): number
	if not WaveUrchin.shouldSpawn(wave) then
		return 0
	end
	return math.floor(wave / C.URCHIN_EVERY_WAVES)
end

function WaveUrchin.rollCount(wave: number): number
	return WaveUrchin.countForWave(wave)
end

function WaveUrchin.hungerForWave(wave: number): number
	return C.crabHungerForWave(wave)
end

function WaveUrchin.speedNow(): number
	return WaveCrab.baseSpeed() * C.URCHIN_SPEED_MULT
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

-- Path + combat VFX (shared with crabs on GroundA).
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
