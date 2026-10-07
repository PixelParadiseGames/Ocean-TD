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

-- Soft-duck SFX under tutorial VO (feed hits, taps, etc.) without changing the saved slider.
local sfxDuckToken = 0
local sfxDuckActive = false
local sfxDuckBase = 1
local sfxDuckFactor = 1

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

local function isVoSound(sound: Sound): boolean
	return sound:GetAttribute("OceanTD_VoTrack") == true
end

local function routeSound(sound: Sound)
	if isBgmSound(sound) or isVoSound(sound) then
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
	-- Prefer saved preference so the UI slider doesn't jump while VO is ducking SFX.
	if sfxDuckActive then
		return sfxDuckBase
	end
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
	local player = Players.LocalPlayer
	if player then
		player:SetAttribute(ATTR_SFX, n)
	end
	if sfxDuckActive then
		sfxDuckBase = n
		if sfxGroup then
			sfxGroup.Volume = n * sfxDuckFactor
		end
		return
	end
	if sfxGroup then
		sfxGroup.Volume = n
	end
end

local function tweenSfxGroup(toVol: number, fadeSec: number, token: number)
	local g = sfxGroup
	if not g then
		return
	end
	local from = g.Volume
	local fade = math.max(0, fadeSec)
	if fade <= 1e-4 then
		if sfxDuckToken == token and sfxGroup == g then
			g.Volume = toVol
		end
		return
	end
	local t0 = os.clock()
	task.spawn(function()
		while sfxGroup == g and sfxDuckToken == token do
			local u = math.clamp((os.clock() - t0) / fade, 0, 1)
			g.Volume = from + (toVol - from) * u
			if u >= 1 then
				break
			end
			task.wait()
		end
	end)
end

-- Soft-duck OceanTD_SFX (feeding, taps, arrows, …) under tutorial VO.
function AudioSettings.fadeSfxToFactor(factor: number, fadeSec: number?)
	AudioSettings.init()
	local g = sfxGroup
	if not g then
		return
	end
	local fade = if typeof(fadeSec) == "number" then math.max(0, fadeSec :: number) else 0.35
	local clamped = clamp01(factor)
	sfxDuckToken += 1
	local my = sfxDuckToken
	if not sfxDuckActive then
		sfxDuckBase = readAttr(ATTR_SFX, g.Volume)
		if sfxDuckBase <= 0 then
			sfxDuckBase = math.max(g.Volume, 0.01)
		end
		sfxDuckActive = true
	end
	sfxDuckFactor = clamped
	tweenSfxGroup(sfxDuckBase * clamped, fade, my)
end

function AudioSettings.clearSfxFactor(fadeSec: number?)
	if not sfxDuckActive then
		return
	end
	local fade = if typeof(fadeSec) == "number" then math.max(0, fadeSec :: number) else 0.35
	sfxDuckToken += 1
	local my = sfxDuckToken
	local base = sfxDuckBase
	sfxDuckActive = false
	sfxDuckFactor = 1
	tweenSfxGroup(base, fade, my)
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

-- Tutorial / explainer VO: skip SFX SoundGroup so the SFX slider doesn't bury dialogue.
function AudioSettings.markVoSound(sound: Sound)
	sound:SetAttribute("OceanTD_VoTrack", true)
	sound.SoundGroup = nil
end

return AudioSettings
