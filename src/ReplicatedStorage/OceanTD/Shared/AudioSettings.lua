--!strict
--[[
	Client audio mixers: SoundGroups for SFX + BGM, volume prefs on the local player.
	New sounds parented under SoundService auto-route to OceanTD_SFX unless marked BGM.
]]

local Players = game:GetService("Players")
local SoundService = game:GetService("SoundService")

local AudioSettings = {}

local ATTR_SFX = "OceanTD_SfxVolume"
local ATTR_BGM = "OceanTD_BgmVolume"
local ATTR_SHUFFLE = "OceanTD_BgmShuffle"

local sfxGroup: SoundGroup? = nil
local bgmGroup: SoundGroup? = nil
local initialized = false

local function clamp01(v: number): number
	return math.clamp(v, 0, 1)
end

local function readAttr(name: string, default: number): number
	local player = Players.LocalPlayer
	if not player then
		return default
	end
	local v = player:GetAttribute(name)
	if typeof(v) == "number" and v == v then
		return clamp01(v)
	end
	return default
end

local function isBgmSound(sound: Sound): boolean
	if sound:GetAttribute("OceanTD_BgmTrack") == true then
		return true
	end
	local g = bgmGroup
	return g ~= nil and sound.SoundGroup == g
end

local function routeSound(sound: Sound)
	if isBgmSound(sound) then
		return
	end
	local g = sfxGroup
	if g then
		sound.SoundGroup = g
	end
end

function AudioSettings.init()
	if initialized then
		return
	end
	initialized = true

	local existingSfx = SoundService:FindFirstChild("OceanTD_SFX")
	if existingSfx and existingSfx:IsA("SoundGroup") then
		sfxGroup = existingSfx
	else
		local g = Instance.new("SoundGroup")
		g.Name = "OceanTD_SFX"
		g.Parent = SoundService
		sfxGroup = g
	end

	local existingBgm = SoundService:FindFirstChild("OceanTD_BGM")
	if existingBgm and existingBgm:IsA("SoundGroup") then
		bgmGroup = existingBgm
	else
		local g = Instance.new("SoundGroup")
		g.Name = "OceanTD_BGM"
		g.Parent = SoundService
		bgmGroup = g
	end

	sfxGroup.Volume = readAttr(ATTR_SFX, 1)
	bgmGroup.Volume = readAttr(ATTR_BGM, 0.7)

	for _, d in ipairs(SoundService:GetDescendants()) do
		if d:IsA("Sound") then
			routeSound(d)
		end
	end
	SoundService.DescendantAdded:Connect(function(d)
		if d:IsA("Sound") then
			task.defer(routeSound, d)
		end
	end)
end

function AudioSettings.getSfxGroup(): SoundGroup?
	return sfxGroup
end

function AudioSettings.getBgmGroup(): SoundGroup?
	return bgmGroup
end

function AudioSettings.getSfxVolume(): number
	return if sfxGroup then sfxGroup.Volume else readAttr(ATTR_SFX, 1)
end

function AudioSettings.getBgmVolume(): number
	return if bgmGroup then bgmGroup.Volume else readAttr(ATTR_BGM, 0.7)
end

function AudioSettings.getBgmShuffle(): boolean
	local player = Players.LocalPlayer
	if not player then
		return false
	end
	return player:GetAttribute(ATTR_SHUFFLE) == true
end

function AudioSettings.setSfxVolume(v: number)
	local n = clamp01(v)
	if sfxGroup then
		sfxGroup.Volume = n
	end
	local player = Players.LocalPlayer
	if player then
		player:SetAttribute(ATTR_SFX, n)
	end
end

function AudioSettings.setBgmVolume(v: number)
	local n = clamp01(v)
	if bgmGroup then
		bgmGroup.Volume = n
	end
	local player = Players.LocalPlayer
	if player then
		player:SetAttribute(ATTR_BGM, n)
	end
end

function AudioSettings.setBgmShuffle(on: boolean)
	local player = Players.LocalPlayer
	if player then
		player:SetAttribute(ATTR_SHUFFLE, on == true)
	end
end

function AudioSettings.markBgmSound(sound: Sound)
	sound:SetAttribute("OceanTD_BgmTrack", true)
	local g = bgmGroup
	if g then
		sound.SoundGroup = g
	end
end

return AudioSettings
