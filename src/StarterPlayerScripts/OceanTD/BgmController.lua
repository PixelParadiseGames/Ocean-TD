--!strict
--[[
	Background music playlist from Workspace.Audio["BG Music"].
	Shuffle, skip, play/pause; loudness via AudioSettings BGM SoundGroup.
	Sound.Volume stays at NOMINAL (1) except during shark overlay / VO soft-duck.
]]

local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local Workspace = game:GetService("Workspace")

local oceanRoot = game:GetService("ReplicatedStorage"):WaitForChild("OceanTD")
local AudioSettings = require(oceanRoot:WaitForChild("Shared"):WaitForChild("AudioSettings"))

local BgmController = {}

local BG_FOLDER_PATH = { "Audio", "BG Music" }
local FADE_SEC = 0.35
-- Playlist Sound.Volume baseline. Soft-duck / overlay temporarily lower this;
-- the Settings BGM slider only drives SoundGroup.Volume, so a stuck Sound.Volume
-- makes music stay quiet no matter how high the slider goes.
local NOMINAL_BGM_SOUND_VOLUME = 1

local bgmSound: Sound? = nil
local overlaySound: Sound? = nil
local trackIds: { string } = {}
local playOrder: { number } = {}
local orderIndex = 1
local shuffleOn = false
local started = false
local paused = false
local overlayToken = 0
local duckActive = false
local savedBgmVolume = NOMINAL_BGM_SOUND_VOLUME
local savedBgmTime = 0
local overlayEndedConn: RBXScriptConnection? = nil

-- Soft duck: fade BGM Sound.Volume to a fraction during tutorial VO, then restore.
local softDuckToken = 0
local softDuckActive = false
local softDuckBaseVolume = NOMINAL_BGM_SOUND_VOLUME
local softDuckPendingFactor: number? = nil -- applied when BGM starts mid-VO

local stateChanged = Instance.new("BindableEvent")
BgmController.StateChanged = stateChanged.Event

local function sanitizeSoundVolume(v: number): number
	if typeof(v) ~= "number" or v ~= v or v <= 0.05 then
		return NOMINAL_BGM_SOUND_VOLUME
	end
	return math.clamp(v, 0.05, 1)
end

local function fireState()
	stateChanged:Fire()
end

local function findBgFolder(): Instance?
	local node: Instance = Workspace
	for _, name in ipairs(BG_FOLDER_PATH) do
		local child = node:FindFirstChild(name)
		if not child then
			return nil
		end
		node = child
	end
	return node
end

local function collectTrackIds(folder: Instance): { string }
	local ids: { string } = {}
	local seen: { [string]: boolean } = {}
	for _, d in ipairs(folder:GetDescendants()) do
		if d:IsA("Sound") and d.SoundId ~= "" and not seen[d.SoundId] then
			seen[d.SoundId] = true
			table.insert(ids, d.SoundId)
		end
	end
	table.sort(ids)
	return ids
end

local function rebuildPlayOrder()
	table.clear(playOrder)
	for i = 1, #trackIds do
		playOrder[i] = i
	end
	if shuffleOn and #playOrder > 1 then
		for i = #playOrder, 2, -1 do
			local j = math.random(1, i)
			playOrder[i], playOrder[j] = playOrder[j], playOrder[i]
		end
		orderIndex = 1
	elseif #playOrder > 1 then
		-- Sequential playlist, but start on a random track each session.
		orderIndex = math.random(1, #playOrder)
	else
		orderIndex = 1
	end
end

local function ensureSound(): Sound
	if bgmSound then
		return bgmSound
	end
	AudioSettings.init()
	local s = Instance.new("Sound")
	s.Name = "OceanTD_BgmPlayer"
	s.Looped = false
	s.Volume = NOMINAL_BGM_SOUND_VOLUME
	s.RollOffMaxDistance = 10000
	s.Parent = SoundService
	AudioSettings.markBgmSound(s)
	bgmSound = s
	s.Ended:Connect(function()
		if paused then
			return
		end
		BgmController.skip()
	end)
	return s
end

local function currentTrackId(): string?
	if #trackIds == 0 then
		return nil
	end
	local idx = playOrder[orderIndex]
	if not idx then
		return nil
	end
	return trackIds[idx]
end

local function applySoftDuckToSound(bgm: Sound)
	if not softDuckActive then
		return
	end
	local factor = softDuckPendingFactor
	if typeof(factor) ~= "number" then
		return
	end
	local target = softDuckBaseVolume * math.clamp(factor, 0, 1)
	bgm.Volume = target
end

local function applyTrack(soundId: string)
	local s = ensureSound()
	s:Stop()
	s.SoundId = soundId
	s.TimePosition = 0
	-- Keep VO duck if dialogue is already playing when a track starts / skips.
	if softDuckActive then
		applySoftDuckToSound(s)
	elseif not duckActive then
		s.Volume = NOMINAL_BGM_SOUND_VOLUME
	end
	s:Play()
	paused = false
	fireState()
end

function BgmController.refreshTracks()
	local folder = findBgFolder()
	if not folder then
		trackIds = {}
		table.clear(playOrder)
		fireState()
		return
	end
	trackIds = collectTrackIds(folder)
	rebuildPlayOrder()
	fireState()
end

function BgmController.start()
	if started then
		return
	end
	started = true
	shuffleOn = AudioSettings.getBgmShuffle()
	BgmController.refreshTracks()
	if #trackIds == 0 then
		task.spawn(function()
			local folder = Workspace:WaitForChild(BG_FOLDER_PATH[1], 60)
			if folder then
				folder:WaitForChild(BG_FOLDER_PATH[2], 60)
			end
			BgmController.refreshTracks()
			if #trackIds > 0 then
				BgmController.play()
			end
		end)
		return
	end
	BgmController.play()
end

function BgmController.play()
	if #trackIds == 0 then
		return
	end
	local id = currentTrackId()
	if not id then
		rebuildPlayOrder()
		id = currentTrackId()
	end
	if id then
		applyTrack(id)
	end
end

function BgmController.pause()
	local s = bgmSound
	if not s or not s.IsPlaying then
		return
	end
	s:Pause()
	paused = true
	fireState()
end

function BgmController.resume()
	local s = bgmSound
	if not s then
		BgmController.play()
		return
	end
	-- Heal stuck soft-duck volume from a VO that ended while BGM was paused.
	if not duckActive and not softDuckActive and s.Volume + 1e-3 < NOMINAL_BGM_SOUND_VOLUME then
		s.Volume = NOMINAL_BGM_SOUND_VOLUME
	elseif softDuckActive and not duckActive then
		applySoftDuckToSound(s)
	end
	if s.IsPlaying then
		paused = false
		fireState()
		return
	end
	if s.IsPaused then
		s:Resume()
	else
		s:Play()
	end
	paused = false
	fireState()
end

function BgmController.togglePlayPause()
	if BgmController.isPlaying() then
		BgmController.pause()
	else
		BgmController.resume()
	end
end

function BgmController.skip()
	if #trackIds == 0 then
		return
	end
	orderIndex += 1
	if orderIndex > #playOrder then
		rebuildPlayOrder()
	end
	BgmController.play()
end

function BgmController.setShuffle(on: boolean)
	shuffleOn = on == true
	AudioSettings.setBgmShuffle(shuffleOn)
	local currentId = currentTrackId()
	rebuildPlayOrder()
	if currentId then
		for i, trackIdx in ipairs(playOrder) do
			if trackIds[trackIdx] == currentId then
				orderIndex = i
				break
			end
		end
	end
	fireState()
end

function BgmController.isShuffle(): boolean
	return shuffleOn
end

function BgmController.isPlaying(): boolean
	local s = bgmSound
	if not s or paused then
		return false
	end
	return s.IsPlaying
end

function BgmController.isPaused(): boolean
	return paused
end

function BgmController.getTrackCount(): number
	return #trackIds
end

function BgmController.getCurrentTrackLabel(): string
	if #trackIds == 0 then
		return "No tracks"
	end
	return string.format("Track %d / %d", orderIndex, math.max(1, #playOrder))
end

function BgmController.getFadeSeconds(): number
	return FADE_SEC
end

local function tweenVolume(sound: Sound, toVol: number, fadeSec: number, token: number, onDone: (() -> ())?)
	local from = sound.Volume
	if fadeSec <= 0 or math.abs(from - toVol) < 1e-4 then
		sound.Volume = toVol
		if onDone then
			onDone()
		end
		return
	end
	local t0 = os.clock()
	local conn: RBXScriptConnection? = nil
	conn = RunService.Heartbeat:Connect(function()
		if token ~= overlayToken then
			if conn then
				conn:Disconnect()
			end
			return
		end
		if not sound.Parent then
			if conn then
				conn:Disconnect()
			end
			if onDone then
				onDone()
			end
			return
		end
		local u = math.clamp((os.clock() - t0) / fadeSec, 0, 1)
		sound.Volume = from + (toVol - from) * u
		if u >= 1 then
			if conn then
				conn:Disconnect()
			end
			if onDone then
				onDone()
			end
		end
	end)
end

local function ensureOverlay(): Sound
	local existing = overlaySound
	if existing and existing.Parent then
		return existing
	end
	AudioSettings.init()
	local s = Instance.new("Sound")
	s.Name = "OceanTD_SharkTheme"
	s.Looped = false
	s.Volume = 0
	s.RollOffMaxDistance = 10000
	s.Parent = SoundService
	AudioSettings.markBgmSound(s)
	overlaySound = s
	return s
end

-- Fade BGM out and play a one-shot overlay at the same mixer volume.
-- No-op when BGM is paused in settings. onEnded fires when the overlay finishes naturally.
function BgmController.playOverlay(soundId: string, fadeSec: number?, onEnded: (() -> ())?)
	if paused or BgmController.isPaused() then
		return
	end
	local fade = if typeof(fadeSec) == "number" then math.max(0, fadeSec) else FADE_SEC
	overlayToken += 1
	local my = overlayToken

	if overlayEndedConn then
		overlayEndedConn:Disconnect()
		overlayEndedConn = nil
	end

	local bgm = bgmSound
	if bgm then
		if not duckActive then
			-- Don't bake a VO soft-duck level into the overlay restore target.
			if softDuckActive then
				savedBgmVolume = sanitizeSoundVolume(softDuckBaseVolume)
			else
				savedBgmVolume = sanitizeSoundVolume(bgm.Volume)
			end
			savedBgmTime = bgm.TimePosition
		end
		duckActive = true
		tweenVolume(bgm, 0, fade, my, function()
			if my ~= overlayToken then
				return
			end
			if bgm.IsPlaying then
				bgm:Pause()
			end
		end)
	else
		duckActive = true
		savedBgmVolume = sanitizeSoundVolume(savedBgmVolume)
		savedBgmTime = 0
	end

	local ov = ensureOverlay()
	ov:Stop()
	ov.SoundId = soundId
	ov.TimePosition = 0
	ov.Volume = 0
	ov:Play()
	tweenVolume(ov, 1, fade, my, nil)

	overlayEndedConn = ov.Ended:Connect(function()
		if my ~= overlayToken then
			return
		end
		if onEnded then
			onEnded()
		end
	end)
end

-- Fade overlay out and resume the same BGM track/position (if it was ducked).
function BgmController.stopOverlay(fadeSec: number?)
	local fade = if typeof(fadeSec) == "number" then math.max(0, fadeSec) else FADE_SEC
	overlayToken += 1
	local my = overlayToken

	if overlayEndedConn then
		overlayEndedConn:Disconnect()
		overlayEndedConn = nil
	end

	local ov = overlaySound
	if ov and ov.Parent then
		tweenVolume(ov, 0, fade, my, function()
			if my ~= overlayToken then
				return
			end
			if ov.Parent then
				ov:Stop()
			end
		end)
	end

	if not duckActive then
		return
	end
	duckActive = false

	local bgm = bgmSound
	local restore = sanitizeSoundVolume(savedBgmVolume)
	if softDuckActive then
		local factor = if typeof(softDuckPendingFactor) == "number" then softDuckPendingFactor :: number else 0.08
		restore = softDuckBaseVolume * math.clamp(factor, 0, 1)
	end

	-- Respect player pause: don't force BGM back on, but always restore Sound.Volume
	-- so Play / the Settings slider aren't stuck on a muted Sound.
	if paused then
		if bgm then
			bgm.Volume = restore
		end
		return
	end

	if not bgm then
		return
	end
	if bgm.SoundId == "" then
		return
	end
	bgm.Volume = 0
	if bgm.IsPaused or not bgm.IsPlaying then
		-- Resume same track from saved position when possible.
		local ok = pcall(function()
			bgm.TimePosition = savedBgmTime
		end)
		if not ok then
			bgm.TimePosition = 0
		end
		bgm:Play()
	end
	tweenVolume(bgm, restore, fade, my, nil)
end

local function tweenBgmSoft(toVol: number, fadeSec: number, token: number, onDone: (() -> ())?)
	local sound = bgmSound
	if not sound then
		if onDone then
			onDone()
		end
		return
	end
	local from = sound.Volume
	if fadeSec <= 0 or math.abs(from - toVol) < 1e-4 then
		sound.Volume = toVol
		if onDone then
			onDone()
		end
		return
	end
	local t0 = os.clock()
	local conn: RBXScriptConnection? = nil
	conn = RunService.Heartbeat:Connect(function()
		if token ~= softDuckToken then
			if conn then
				conn:Disconnect()
			end
			return
		end
		if not sound.Parent then
			if conn then
				conn:Disconnect()
			end
			if onDone then
				onDone()
			end
			return
		end
		local u = math.clamp((os.clock() - t0) / fadeSec, 0, 1)
		sound.Volume = from + (toVol - from) * u
		if u >= 1 then
			if conn then
				conn:Disconnect()
			end
			if onDone then
				onDone()
			end
		end
	end)
end

function BgmController.fadeBgmToFactor(factor: number, fadeSec: number?)
	if paused then
		return
	end
	local fade = if typeof(fadeSec) == "number" then math.max(0, fadeSec) else FADE_SEC
	local clamped = math.clamp(factor, 0, 1)
	softDuckPendingFactor = clamped
	softDuckToken += 1
	local my = softDuckToken
	local bgm = bgmSound
	if not softDuckActive then
		-- Always restore toward nominal Sound.Volume — never capture a mid-duck level
		-- (that permanently "locks" music quiet; Settings only adjusts SoundGroup).
		if duckActive then
			softDuckBaseVolume = sanitizeSoundVolume(savedBgmVolume)
		else
			softDuckBaseVolume = NOMINAL_BGM_SOUND_VOLUME
		end
		softDuckActive = true
	end
	if not bgm then
		-- VO often starts before BGM; duck applies when play()/applyTrack runs.
		return
	end
	if duckActive then
		-- Overlay owns audible BGM; remember base so clear restores correctly later.
		return
	end
	local target = softDuckBaseVolume * clamped
	tweenBgmSoft(target, fade, my, nil)
end

function BgmController.clearBgmFactor(fadeSec: number?)
	if not softDuckActive then
		return
	end
	local fade = if typeof(fadeSec) == "number" then math.max(0, fadeSec) else FADE_SEC
	softDuckToken += 1
	local my = softDuckToken
	local base = sanitizeSoundVolume(softDuckBaseVolume)
	softDuckActive = false
	softDuckPendingFactor = nil
	softDuckBaseVolume = NOMINAL_BGM_SOUND_VOLUME
	if duckActive then
		-- Overlay still owns playback; hand the unducked base to stopOverlay.
		savedBgmVolume = base
		return
	end
	local bgm = bgmSound
	if not bgm then
		return
	end
	-- Always put Sound.Volume back even if paused — otherwise resume stays quiet
	-- and the Settings BGM slider (SoundGroup only) cannot fix it.
	if paused or fade <= 0 then
		bgm.Volume = base
		return
	end
	tweenBgmSoft(base, fade, my, nil)
end

-- Called when the Settings BGM slider moves. Heals a stuck soft-duck Sound.Volume
-- so mixer changes become audible again.
function BgmController.notifyMixerVolumeChanged()
	local bgm = bgmSound
	if not bgm then
		return
	end
	if duckActive then
		return
	end
	if softDuckActive then
		applySoftDuckToSound(bgm)
		return
	end
	if bgm.Volume + 1e-3 < NOMINAL_BGM_SOUND_VOLUME then
		bgm.Volume = NOMINAL_BGM_SOUND_VOLUME
	end
end

return BgmController
