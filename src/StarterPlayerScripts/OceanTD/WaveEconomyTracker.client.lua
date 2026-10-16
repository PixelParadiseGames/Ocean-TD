--!strict
--[[
	Tracks unpaused wave playtime by Wave Speed bucket and flushes to the server
	for lifetime economy stats ($D / min, speed inflate, dead waves).
	Also reports per-wave durations when the wave index advances.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Remotes = require(ReplicatedStorage:WaitForChild("OceanTD"):WaitForChild("Remotes"))
local WaveSim = require(script.Parent:WaitForChild("WaveSim"))

local FLUSH_SEC = 4
local pending = { s1 = 0, s15 = 0, s2 = 0 }
local flushAcc = 0
local wasRunning = false
local trackedWave = 0
local waveDurationSec = 0
local remote: RemoteEvent? = nil

local function getRemote(): RemoteEvent
	if remote then
		return remote
	end
	remote = Remotes.get("ReportWaveEconomy")
	return remote
end

local function speedKey(mult: number): string
	if mult >= 1.75 then
		return "s2"
	end
	if mult >= 1.25 then
		return "s15"
	end
	return "s1"
end

local function hasPending(): boolean
	return pending.s1 > 0 or pending.s15 > 0 or pending.s2 > 0
end

local function flush(waveEnded: boolean, waveComplete: { wave: number, durationSec: number }?)
	if not hasPending() and not waveEnded and not waveComplete then
		return
	end
	local payload: any = {
		playBySpeed = {
			s1 = pending.s1,
			s15 = pending.s15,
			s2 = pending.s2,
		},
		waveEnded = waveEnded == true,
	}
	if waveComplete then
		payload.waveComplete = waveComplete
	end
	pending.s1 = 0
	pending.s15 = 0
	pending.s2 = 0
	flushAcc = 0
	pcall(function()
		getRemote():FireServer(payload)
	end)
end

local function reportWaveComplete(wave: number, durationSec: number)
	if wave < 1 or durationSec < 0.5 then
		return
	end
	flush(false, { wave = wave, durationSec = durationSec })
end

RunService.Heartbeat:Connect(function(dt)
	-- Join-intro demo must not pollute lifetime economy.
	local introDemo = false
	pcall(function()
		introDemo = WaveSim.isJoinIntroDemo() == true
	end)
	local running = WaveSim.isRunning() and not introDemo
	if wasRunning and not running then
		flush(true, nil)
		wasRunning = false
		trackedWave = 0
		waveDurationSec = 0
		return
	end
	if running and not wasRunning then
		trackedWave = WaveSim.getWaveIndex()
		waveDurationSec = 0
	end
	wasRunning = running
	if not running then
		return
	end

	local waveNow = WaveSim.getWaveIndex()
	if trackedWave > 0 and waveNow ~= trackedWave then
		reportWaveComplete(trackedWave, waveDurationSec)
		trackedWave = waveNow
		waveDurationSec = 0
	elseif trackedWave <= 0 then
		trackedWave = waveNow
		waveDurationSec = 0
	end

	if WaveSim.isSpeedPaused() then
		return
	end
	waveDurationSec += dt
	local key = speedKey(WaveSim.getSpeedMult())
	if key == "s15" then
		pending.s15 += dt
	elseif key == "s2" then
		pending.s2 += dt
	else
		pending.s1 += dt
	end
	flushAcc += dt
	if flushAcc >= FLUSH_SEC then
		flush(false, nil)
	end
end)
