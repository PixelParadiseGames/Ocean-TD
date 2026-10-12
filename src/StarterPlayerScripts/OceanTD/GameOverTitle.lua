--!strict
--[[
	Arcade "GAME OVER" title: sound + scale up to center, hold, fall off bottom.
	Used by join-intro rating and wave defeat (before Out Of Reef Health).
]]

local ContentProvider = game:GetService("ContentProvider")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local Workspace = game:GetService("Workspace")

local AudioSettings = require(ReplicatedStorage:WaitForChild("OceanTD"):WaitForChild("Shared"):WaitForChild("AudioSettings"))

local GameOverTitle = {}

local SCALE_SEC = 0.65
local HOLD_SEC = 1
local FALL_SEC = 0.75
local SOUND_ID = "rbxassetid://92418907642592"

local activeGui: ScreenGui? = nil
local token = 0

task.defer(function()
	pcall(function()
		local warm = Instance.new("Sound")
		warm.SoundId = SOUND_ID
		AudioSettings.markNoSoundGroup(warm)
		warm.Parent = SoundService
		ContentProvider:PreloadAsync({ warm })
		warm:Destroy()
	end)
end)

local function cancelled(my: number, isCancelled: (() -> boolean)?): boolean
	if my ~= token then
		return true
	end
	if isCancelled and isCancelled() then
		return true
	end
	return false
end

function GameOverTitle.cancel()
	token += 1
	if activeGui then
		activeGui:Destroy()
		activeGui = nil
	end
end

local function playGameOverSound(my: number)
	local snd = Instance.new("Sound")
	snd.Name = "OceanTD_GameOverTitle"
	snd.SoundId = SOUND_ID
	snd.Volume = 1.35 -- 10% quieter than prior 1.5
	AudioSettings.markNoSoundGroup(snd)
	snd.Parent = SoundService
	task.defer(function()
		if snd.Parent then
			AudioSettings.markNoSoundGroup(snd)
		end
	end)
	task.spawn(function()
		if my ~= token or not snd.Parent then
			return
		end
		if not snd.IsLoaded then
			pcall(function()
				ContentProvider:PreloadAsync({ snd })
			end)
		end
		if not snd.IsLoaded and snd.Parent then
			pcall(function()
				snd.Loaded:Wait()
			end)
		end
		if my ~= token or not snd.Parent then
			if snd.Parent then
				snd:Destroy()
			end
			return
		end
		AudioSettings.markNoSoundGroup(snd)
		snd:Play()
		-- Also fire a detached one-shot — some clients drop Instance:Play under heavy VO.
		pcall(function()
			SoundService:PlayLocalSound(snd)
		end)
		local len = snd.TimeLength
		local ttl = if typeof(len) == "number" and len > 0.05 then len + 0.5 else 8
		task.wait(ttl)
		if snd.Parent then
			snd:Destroy()
		end
	end)
end

-- Yields until scale + hold + fall finish (or cancel).
function GameOverTitle.playAndWait(fromWorld: Vector3?, isCancelled: (() -> boolean)?)
	token += 1
	local my = token
	local lp = Players.LocalPlayer
	local pg = lp and lp:FindFirstChildOfClass("PlayerGui")
	if not pg then
		return
	end
	if activeGui then
		activeGui:Destroy()
		activeGui = nil
	end

	local cam = Workspace.CurrentCamera
	local startScale = UDim2.fromScale(0.5, 0.5)
	local startOnScreen = false
	if cam and typeof(fromWorld) == "Vector3" then
		local sp, onScreen = cam:WorldToViewportPoint(fromWorld)
		if onScreen and sp.Z > 0 then
			local vs = cam.ViewportSize
			startScale = UDim2.fromScale(sp.X / math.max(vs.X, 1), sp.Y / math.max(vs.Y, 1))
			startOnScreen = true
		end
	end

	local sg = Instance.new("ScreenGui")
	sg.Name = "OceanTD_GameOverTitle"
	sg.IgnoreGuiInset = true
	sg.ResetOnSpawn = false
	sg.DisplayOrder = 14000
	sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	sg.Parent = pg
	activeGui = sg

	local lbl = Instance.new("TextLabel")
	lbl.Name = "GameOver"
	lbl.BackgroundTransparency = 1
	lbl.AnchorPoint = Vector2.new(0.5, 0.5)
	lbl.Position = if startOnScreen then startScale else UDim2.fromScale(0.5, 0.5)
	lbl.Size = UDim2.fromScale(0.96, 0.22)
	lbl.Font = Enum.Font.Arcade
	lbl.Text = "GAME OVER"
	lbl.TextColor3 = Color3.new(1, 1, 1)
	lbl.TextStrokeColor3 = Color3.new(0, 0, 0)
	lbl.TextStrokeTransparency = 0.25
	lbl.TextScaled = true
	lbl.ZIndex = 10
	lbl.Parent = sg

	local scale = Instance.new("UIScale")
	scale.Scale = 0.04
	scale.Parent = lbl

	playGameOverSound(my)

	local t0 = os.clock()
	while not cancelled(my, isCancelled) and sg.Parent do
		local u = math.clamp((os.clock() - t0) / SCALE_SEC, 0, 1)
		local e = 1 - (1 - u) ^ 3
		scale.Scale = 0.04 + (1 - 0.04) * e
		lbl.Position = startScale:Lerp(UDim2.fromScale(0.5, 0.5), e)
		if u >= 1 then
			break
		end
		RunService.RenderStepped:Wait()
	end
	if cancelled(my, isCancelled) or not sg.Parent then
		if activeGui == sg then
			activeGui = nil
		end
		if sg.Parent then
			sg:Destroy()
		end
		return
	end
	scale.Scale = 1
	lbl.Position = UDim2.fromScale(0.5, 0.5)

	local holdUntil = os.clock() + HOLD_SEC
	while os.clock() < holdUntil and not cancelled(my, isCancelled) and sg.Parent do
		RunService.RenderStepped:Wait()
	end
	if cancelled(my, isCancelled) or not sg.Parent then
		if activeGui == sg then
			activeGui = nil
		end
		if sg.Parent then
			sg:Destroy()
		end
		return
	end

	local centerPos = UDim2.fromScale(0.5, 0.5)
	local fallPos = UDim2.fromScale(0.5, 1.35)
	local fallT0 = os.clock()
	while not cancelled(my, isCancelled) and sg.Parent do
		local u = math.clamp((os.clock() - fallT0) / FALL_SEC, 0, 1)
		local e = u * u
		lbl.Position = centerPos:Lerp(fallPos, e)
		if u >= 1 then
			break
		end
		RunService.RenderStepped:Wait()
	end
	if activeGui == sg then
		activeGui = nil
	end
	if sg.Parent then
		sg:Destroy()
	end
end

return GameOverTitle
