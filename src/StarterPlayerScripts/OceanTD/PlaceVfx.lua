--!strict
--[[
	Local-only placement VFX (sound + bubbles + color flash).
	Created on the client under CurrentCamera — never replicates to other players.
	One burst at a time; starting a new one clears the previous.
	Success sound plays on ✓ (preloaded); visuals after server accept.
]]

local ContentProvider = game:GetService("ContentProvider")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local PlaceVfx = {}

local CANCEL_SOUND_ID = "rbxassetid://123373842476302"
local SUCCESS_SOUND_ID = "rbxassetid://123147660118306"
local PARK_SOUND_ID = "rbxassetid://139911414972673"
local SUCCESS_TRIM_END = 0.2 -- don't play the last N seconds
local BUBBLE_COUNT = 10
local BUBBLE_DURATION = 5
local LIGHT_DURATION = 4
local BUBBLE_COLOR = Color3.fromRGB(170, 220, 255)
local BUBBLE_TRANSPARENCY = 0.3
local BUBBLE_SIZE_MIN = 0.18
-- Was max 0.60; 200% bigger max → 1.80 (min unchanged for a wider range).
local BUBBLE_SIZE_MAX = 1.80
local LIGHT_BRIGHTNESS = 3.5
local LIGHT_RANGE = 14

local activeFolder: Folder? = nil
local activeToken = 0

local function makeTemplate(name: string, soundId: string): Sound
	local s = Instance.new("Sound")
	s.Name = name
	s.SoundId = soundId
	s.Volume = 0.85
	s.RollOffMode = Enum.RollOffMode.InverseTapered
	s.RollOffMaxDistance = 80
	s.Parent = SoundService
	return s
end

local successTemplate = makeTemplate("OceanTD_PlaceSuccessSound", SUCCESS_SOUND_ID)
local parkTemplate = makeTemplate("OceanTD_PlaceParkSound", PARK_SOUND_ID)
local cancelTemplate = makeTemplate("OceanTD_PlaceCancelSound", CANCEL_SOUND_ID)
task.defer(function()
	pcall(function()
		ContentProvider:PreloadAsync({ successTemplate, parkTemplate, cancelTemplate })
	end)
end)

local function clearActive()
	if activeFolder then
		activeFolder:Destroy()
		activeFolder = nil
	end
end

local function makeVfxPart(name: string, size: number, color: Color3, transparency: number, material: Enum.Material): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Shape = Enum.PartType.Ball
	p.Size = Vector3.new(size, size, size)
	p.Color = color
	p.Transparency = transparency
	p.Material = material
	p.Anchored = true
	p.Massless = true
	p.CanCollide = false
	p.CanTouch = false
	p.CanQuery = false
	p.CastShadow = false
	return p
end

local function playOneShot(template: Sound, worldPos: Vector3, trimEndSeconds: number?)
	local parent: Instance = Workspace.CurrentCamera or Workspace
	local holder = Instance.new("Part")
	holder.Name = "OceanTD_PlaceSound"
	holder.Anchored = true
	holder.CanCollide = false
	holder.CanTouch = false
	holder.CanQuery = false
	holder.CastShadow = false
	holder.Transparency = 1
	holder.Size = Vector3.new(0.2, 0.2, 0.2)
	holder.CFrame = CFrame.new(worldPos)
	holder.Parent = parent

	local sound = template:Clone()
	sound.PlaybackSpeed = 0.85 + math.random() * 0.35
	sound.Parent = holder

	local cleaned = false
	local function cleanup()
		if cleaned then
			return
		end
		cleaned = true
		if holder.Parent then
			holder:Destroy()
		end
	end

	local function scheduleTrimStop()
		local trim = trimEndSeconds or 0
		if trim <= 0 then
			sound.Ended:Once(cleanup)
			return
		end
		local len = sound.TimeLength
		if len > trim then
			-- Stop before the last trim seconds (account for PlaybackSpeed).
			local playFor = (len - trim) / math.max(sound.PlaybackSpeed, 0.05)
			task.delay(playFor, function()
				if sound.Parent then
					sound:Stop()
				end
				cleanup()
			end)
		else
			sound.Ended:Once(cleanup)
		end
	end

	sound:Play()
	if (trimEndSeconds or 0) > 0 and sound.TimeLength <= 0 then
		local conn: RBXScriptConnection? = nil
		conn = sound:GetPropertyChangedSignal("TimeLength"):Connect(function()
			if sound.TimeLength > 0 then
				if conn then
					conn:Disconnect()
				end
				scheduleTrimStop()
			end
		end)
	else
		scheduleTrimStop()
	end

	task.delay(6, cleanup)
end

--- Fire as soon as ✓ is pressed (before server round-trip).
function PlaceVfx.playSound(worldPos: Vector3)
	playOneShot(successTemplate, worldPos, SUCCESS_TRIM_END)
end

--- Fire when the ghost is parked / dropped into confirm.
function PlaceVfx.playParkSound(worldPos: Vector3)
	playOneShot(parkTemplate, worldPos, nil)
end

--- Fire when the red X cancels / disarms coral.
function PlaceVfx.playCancelSound(worldPos: Vector3)
	playOneShot(cancelTemplate, worldPos, nil)
end

--- Bubbles + color flash after a successful place.
function PlaceVfx.playVisuals(worldPos: Vector3, coralColor: Color3)
	clearActive()
	activeToken += 1
	local token = activeToken

	local parent: Instance = Workspace.CurrentCamera or Workspace
	local folder = Instance.new("Folder")
	folder.Name = "OceanTD_PlaceVfx"
	folder.Parent = parent
	activeFolder = folder

	local anchor = makeVfxPart("Anchor", 0.2, coralColor, 1, Enum.Material.SmoothPlastic)
	anchor.CFrame = CFrame.new(worldPos)
	anchor.Parent = folder

	local light = Instance.new("PointLight")
	light.Name = "PlaceFlash"
	light.Color = coralColor
	light.Brightness = LIGHT_BRIGHTNESS
	light.Range = LIGHT_RANGE
	light.Shadows = false
	light.Parent = anchor
	TweenService:Create(light, TweenInfo.new(LIGHT_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Brightness = 0,
		Range = LIGHT_RANGE * 0.35,
	}):Play()

	local sizeSpan = BUBBLE_SIZE_MAX - BUBBLE_SIZE_MIN
	local bubbleInfo = TweenInfo.new(BUBBLE_DURATION, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
	for _ = 1, BUBBLE_COUNT do
		local size = BUBBLE_SIZE_MIN + math.random() * sizeSpan
		local bubble = makeVfxPart("Bubble", size, BUBBLE_COLOR, BUBBLE_TRANSPARENCY, Enum.Material.Glass)
		local spawnOffset = Vector3.new((math.random() - 0.5) * 1.2, math.random() * 0.35, (math.random() - 0.5) * 1.2)
		local startPos = worldPos + spawnOffset
		bubble.CFrame = CFrame.new(startPos)
		bubble.Parent = folder

		local rise = 4.5 + math.random() * 3.5
		local drift = Vector3.new((math.random() - 0.5) * 2.2, rise, (math.random() - 0.5) * 2.2)
		TweenService:Create(bubble, bubbleInfo, {
			CFrame = CFrame.new(startPos + drift),
			Transparency = 1,
		}):Play()
	end

	task.delay(BUBBLE_DURATION + 0.15, function()
		if token ~= activeToken then
			return
		end
		if activeFolder == folder then
			clearActive()
		end
	end)
end

return PlaceVfx
