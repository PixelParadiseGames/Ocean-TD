--!strict
--[[
	Shark swim on WaveRoute.Shark every 10 waves (1 shark).
	Feedable; does not gate wave completion. Light client yaw sway.
]]

local WaveCrab = require(script.Parent:WaitForChild("WaveCrab"))
local WaveEntityPool = require(script.Parent:WaitForChild("WaveEntityPool"))
local C = require(script.Parent:WaitForChild("WaveSimConsts"))
local BgmController = require(script.Parent:WaitForChild("BgmController"))

local WaveShark = {}

local liveCount = 0
local musicToken = 0

function WaveShark.shouldSpawn(wave: number): boolean
	local w = math.max(1, math.floor(wave))
	return w >= C.SHARK_FIRST_WAVE
		and w % C.SHARK_EVERY_WAVES == 0
		and WaveEntityPool.hasFishKind(WaveEntityPool.FISH_SHARK)
end

function WaveShark.countForWave(wave: number): number
	return if WaveShark.shouldSpawn(wave) then 1 else 0
end

function WaveShark.hungerForWave(wave: number): number
	return C.sharkHungerForWave(wave)
end

function WaveShark.speed(): number
	return C.sharkSpeed()
end

function WaveShark.buildLocal(): WaveCrab.PathData?
	return WaveCrab.buildNamedLocal(C.SHARK_ROUTE_NAME)
end

function WaveShark.buildOn(
	targetPlotId: string,
	targetCf: CFrame,
	targetSize: Vector3,
	targetRingCf: CFrame?
): WaveCrab.PathData?
	return WaveCrab.buildNamedOn(C.SHARK_ROUTE_NAME, targetPlotId, targetCf, targetSize, targetRingCf)
end

WaveShark.sample = WaveCrab.sample

function WaveShark.facingCFrame(pos: Vector3, move: Vector3, swayPhase: number, clock: number): CFrame
	local look = if move.Magnitude > 1e-5 then move.Unit else Vector3.new(0, 0, -1)
	local sway = math.sin(clock * C.SHARK_SWAY_FREQ + swayPhase) * C.SHARK_SWAY_YAW
	return CFrame.lookAt(pos, pos + look, Vector3.yAxis)
		* CFrame.Angles(C.SHARK_PITCH, C.SHARK_YAW + sway, C.SHARK_ROLL)
end

function WaveShark.applyPose(model: Instance, root: BasePart, desired: CFrame)
	if model:IsA("Model") then
		if not model.PrimaryPart then
			model.PrimaryPart = root
		end
		model:PivotTo(desired)
	elseif model:IsA("BasePart") then
		model.CFrame = desired
	else
		root.CFrame = desired
	end
end

local function stopMusic(fadeSec: number?)
	musicToken += 1
	BgmController.stopOverlay(fadeSec or C.SHARK_MUSIC_FADE_SEC)
end

local function startMusic()
	musicToken += 1
	local my = musicToken
	BgmController.playOverlay(C.SHARK_MUSIC_ID, C.SHARK_MUSIC_FADE_SEC, function()
		-- Song finished first — restore BGM even if the shark is still swimming.
		if my == musicToken then
			BgmController.stopOverlay(C.SHARK_MUSIC_FADE_SEC)
		end
	end)
end

function WaveShark.onSpawned(skipMusic: boolean?)
	liveCount += 1
	if skipMusic ~= true then
		startMusic()
	end
end

function WaveShark.onDespawned()
	liveCount = math.max(0, liveCount - 1)
	if liveCount <= 0 then
		liveCount = 0
		stopMusic(C.SHARK_MUSIC_FADE_SEC)
	end
end

function WaveShark.resetAudio()
	liveCount = 0
	stopMusic(0)
end

function WaveShark.liveCount(): number
	return liveCount
end

return WaveShark
