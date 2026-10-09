--!strict
--[[
	One-shot tutorial voice-over clips: Narrator SoundGroup + soft-duck BGM/SFX until Ended/Stop.
	VO uses OceanTD_Narrator (Settings → Narrator), not the SFX slider.
	playWhenIdle queues behind the current clip (e.g. wave explainer after "how many waves").
]]

local ContentProvider = game:GetService("ContentProvider")
local SoundService = game:GetService("SoundService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AudioSettings = require(ReplicatedStorage:WaitForChild("OceanTD"):WaitForChild("Shared"):WaitForChild("AudioSettings"))
local BgmController = require(script.Parent:WaitForChild("BgmController"))

local TutorialVo = {}

export type PlayOpts = {
	onStart: (() -> ())?,
	onEnded: (() -> ())?,
	-- Optional louder/quieter than default (some source clips are mastered quieter).
	volume: number?,
}

-- Roblox Sound.Volume allows >1; keep dialogue above ducked BGM even if masters are quiet.
local VO_VOLUME = 2.5
local BGM_FACTOR = 0.08
local SFX_FACTOR = 0.12 -- feed hits / taps / arrows under VO
local BGM_FADE_SEC = 0.35
local LOAD_TIMEOUT_SEC = 8
local DEFAULT_MAX_SEC = 45

type Pending = {
	soundId: string,
	name: string?,
	opts: PlayOpts?,
}

local active: Sound? = nil
local ducking = false
local pending: Pending? = nil
local playGen = 0

local playNow: (string, string?, PlayOpts?) -> ()

local function clearDuck()
	if not ducking then
		return
	end
	ducking = false
	BgmController.clearBgmFactor(BGM_FADE_SEC)
	AudioSettings.clearSfxFactor(BGM_FADE_SEC)
end

playNow = function(soundId: string, name: string?, opts: PlayOpts?)
	AudioSettings.init()
	playGen += 1
	local my = playGen
	ducking = true
	BgmController.fadeBgmToFactor(BGM_FACTOR, BGM_FADE_SEC)
	AudioSettings.fadeSfxToFactor(SFX_FACTOR, BGM_FADE_SEC)
	local vol = VO_VOLUME
	if opts and typeof(opts.volume) == "number" and (opts.volume :: number) == (opts.volume :: number) then
		vol = math.clamp(opts.volume :: number, 0.1, 10)
	end
	local s = Instance.new("Sound")
	s.Name = name or "OceanTD_TutorialVo"
	s.SoundId = soundId
	s.Volume = vol
	s.Looped = false
	AudioSettings.markVoSound(s)
	s.Parent = SoundService
	AudioSettings.markVoSound(s)
	s.Volume = vol
	active = s
	if opts and opts.onStart then
		task.defer(opts.onStart)
	end

	local finished = false
	local function complete()
		if finished then
			return
		end
		finished = true
		-- Only the current generation owns duck/pending. Always fire onEnded so
		-- listeners (e.g. try-waves-again) still run if this clip was interrupted.
		local isCurrent = my == playGen
		if isCurrent then
			if active == s then
				active = nil
			end
			clearDuck()
		end
		if s.Parent then
			pcall(function()
				s:Stop()
				s:Destroy()
			end)
		end
		if opts and opts.onEnded then
			task.defer(opts.onEnded)
		end
		if not isCurrent then
			return
		end
		local nextVo = pending
		pending = nil
		if nextVo then
			playNow(nextVo.soundId, nextVo.name, nextVo.opts)
		end
	end

	s.Ended:Once(complete)
	s.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			complete()
		end
	end)

	task.spawn(function()
		if not s.IsLoaded then
			pcall(function()
				ContentProvider:PreloadAsync({ s })
			end)
		end
		local tLoad = os.clock()
		while my == playGen and s.Parent and not s.IsLoaded and (os.clock() - tLoad) < LOAD_TIMEOUT_SEC do
			task.wait()
		end
		if my ~= playGen or not s.Parent then
			return
		end
		if not s.IsLoaded then
			-- Failed to load — unduck so music isn't left buried with no VO.
			complete()
			return
		end
		s.Volume = vol
		s:Play()
		local len = s.TimeLength
		local maxSec = if len > 0.05 then len / math.max(0.2, s.PlaybackSpeed) + 1.5 else DEFAULT_MAX_SEC
		task.delay(maxSec, complete)
	end)
end

function TutorialVo.isPlaying(): boolean
	local s = active
	return s ~= nil and s.Parent ~= nil
end

function TutorialVo.stop()
	pending = nil
	playGen += 1
	local s = active
	active = nil
	clearDuck()
	if not s then
		return
	end
	pcall(function()
		s:Stop()
		s:Destroy()
	end)
end

function TutorialVo.play(soundId: string, name: string?, opts: PlayOpts?)
	pending = nil
	-- Invalidate prior Ended/Ancestry callbacks so they can't unduck the new clip.
	playGen += 1
	local s = active
	active = nil
	if s then
		pcall(function()
			s:Stop()
			s:Destroy()
		end)
	end
	-- Keep BGM ducked across a hard VO swap; playNow refreshes the factor.
	playNow(soundId, name, opts)
end

-- If a clip is already playing, run this after it ends (does not cut the current VO).
function TutorialVo.playWhenIdle(soundId: string, name: string?, opts: PlayOpts?)
	if TutorialVo.isPlaying() then
		pending = { soundId = soundId, name = name, opts = opts }
		return
	end
	pending = nil
	playNow(soundId, name, opts)
end

return TutorialVo
