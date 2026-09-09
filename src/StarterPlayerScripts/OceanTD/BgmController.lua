--!strict
--[[
	Background music playlist from Workspace.Audio["BG Music"].
	Shuffle, skip, play/pause; volume via AudioSettings BGM group.
]]

local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local Workspace = game:GetService("Workspace")

local oceanRoot = game:GetService("ReplicatedStorage"):WaitForChild("OceanTD")
local AudioSettings = require(oceanRoot:WaitForChild("Shared"):WaitForChild("AudioSettings"))

local BgmController = {}

local BG_FOLDER_PATH = { "Audio", "BG Music" }
local FADE_SEC = 0.35

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
local savedBgmVolume = 1
local savedBgmTime = 0
local overlayEndedConn: RBXScriptConnection? = nil

local stateChanged = Instance.new("BindableEvent")
BgmController.StateChanged = stateChanged.Event

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
	s.Volume = 1
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

local function applyTrack(soundId: string)
	local s = ensureSound()
	s:Stop()
	s.SoundId = soundId
	s.TimePosition = 0
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
			savedBgmVolume = bgm.Volume
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
		if savedBgmVolume <= 0 then
			savedBgmVolume = 1
		end
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

	-- Respect player pause: don't force BGM back on.
	if paused then
		return
	end

	local bgm = bgmSound
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
	tweenVolume(bgm, savedBgmVolume > 0 and savedBgmVolume or 1, fade, my, nil)
end

return BgmController
