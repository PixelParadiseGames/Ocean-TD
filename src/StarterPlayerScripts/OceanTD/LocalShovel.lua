--!strict
-- Client-only backpack shovel (left hand). Other players never see it.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local LEFT_HAND_GRIP = CFrame.Angles(math.rad(-45), 0, 0)

local LocalShovel = {}

local player = Players.LocalPlayer
local held: Model? = nil
local followConn: RBXScriptConnection? = nil

local function fxFolder(): Folder
	local cam = Workspace.CurrentCamera
	local folder = cam and cam:FindFirstChild("OceanTD_LocalFX")
	if folder and folder:IsA("Folder") then
		return folder
	end
	local f = Instance.new("Folder")
	f.Name = "OceanTD_LocalFX"
	f.Parent = cam or Workspace
	return f
end

local function leftHand(): BasePart?
	local character = player.Character
	if not character then
		return nil
	end
	local hand = character:FindFirstChild("LeftHand") or character:FindFirstChild("Left Arm")
	if hand and hand:IsA("BasePart") then
		return hand
	end
	return nil
end

local function stopFollow()
	if followConn then
		followConn:Disconnect()
		followConn = nil
	end
end

function LocalShovel.unequip()
	stopFollow()
	if held then
		held:Destroy()
		held = nil
	end
end

local function toModel(template: Instance): Model?
	if template:IsA("Model") then
		return template:Clone()
	end
	if template:IsA("Tool") then
		local model = Instance.new("Model")
		model.Name = "Shovel"
		local clone = template:Clone()
		for _, child in ipairs(clone:GetChildren()) do
			if not child:IsA("Script") and not child:IsA("LocalScript") then
				child.Parent = model
			end
		end
		clone:Destroy()
		return model
	end
	if template:IsA("BasePart") then
		local model = Instance.new("Model")
		model.Name = "Shovel"
		local p = template:Clone()
		p.Parent = model
		model.PrimaryPart = p
		return model
	end
	return nil
end

function LocalShovel.equip()
	LocalShovel.unequip()
	local template = ReplicatedStorage:FindFirstChild("Shovel")
	if not template then
		warn("[INV] ReplicatedStorage.Shovel missing (local)")
		return
	end
	local model = toModel(template)
	if not model then
		warn("[INV] Shovel unsupported class:", template.ClassName)
		return
	end
	model.Name = "Shovel"

	local root = model.PrimaryPart
		or model:FindFirstChild("Handle", true)
		or model:FindFirstChildWhichIsA("BasePart", true)
	if not root or not root:IsA("BasePart") then
		model:Destroy()
		return
	end
	model.PrimaryPart = root
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanTouch = false
			d.CanQuery = false
			d.Massless = true
			d.CastShadow = false
		end
	end
	model.Parent = fxFolder()
	held = model

	followConn = RunService.RenderStepped:Connect(function()
		if not held or not held.Parent then
			return
		end
		local hand = leftHand()
		if hand then
			held:PivotTo(hand.CFrame * LEFT_HAND_GRIP)
		end
	end)
end

player.CharacterRemoving:Connect(function()
	LocalShovel.unequip()
end)

return LocalShovel
