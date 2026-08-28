--!strict
--[[
	Background music playlist from Workspace.Audio["BG Music"].
	Shuffle, skip, play/pause; volume via AudioSettings BGM group.
]]

local SoundService = game:GetService("SoundService")
local Workspace = game:GetService("Workspace")

local oceanRoot = game:GetService("ReplicatedStorage"):WaitForChild("OceanTD")
local AudioSettings = require(oceanRoot:WaitForChild("Shared"):WaitForChild("AudioSettings"))

local BgmController = {}

local BG_FOLDER_PATH = { "Audio", "BG Music" }
local FADE_SEC = 0.35

local bgmSound: Sound? = nil
local trackIds: { string } = {}
local playOrder: { number } = {}
local orderIndex = 1
local shuffleOn = false
local started = false
local paused = false

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
	end
	orderIndex = 1
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

return BgmController
