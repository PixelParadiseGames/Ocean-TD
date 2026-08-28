--!strict
--[[
	Tree Coral stand / collision debug (visuals only).
	GREEN  = CanCollide (player can stand on this volume)
	RED    = no collision (visual only — player passes through)
	YELLOW = part your character is standing on right now
	Toggle: F9, or player attribute OceanTD_TreeCoralStandDebug.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer

local ATTR = "OceanTD_TreeCoralStandDebug"
player:SetAttribute(ATTR, false)

local COLOR_STAND = Color3.fromRGB(55, 255, 100)
local COLOR_NO_COLLIDE = Color3.fromRGB(255, 70, 70)
local COLOR_UNDERFOOT = Color3.fromRGB(255, 230, 50)

type PartOverlay = { box: SelectionBox, fill: BoxHandleAdornment }

local overlays: { [BasePart]: PartOverlay } = {}
local folder: Folder? = nil
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude

local function enabled(): boolean
	return player:GetAttribute(ATTR) == true
end

local function ensureFolder(): Folder
	local f = folder
	if f and f.Parent then
		return f
	end
	f = Instance.new("Folder")
	f.Name = "OceanTD_TreeCoralStandDebug"
	f.Parent = Workspace
	folder = f
	return f
end

local function clearAll()
	for _, pack in pairs(overlays) do
		pack.box:Destroy()
		pack.fill:Destroy()
	end
	table.clear(overlays)
	if folder then
		folder:Destroy()
		folder = nil
	end
end

local function isTreeCoralPart(part: BasePart): boolean
	local stem = part
	while stem and stem ~= Workspace do
		if stem:IsA("BasePart") and stem:GetAttribute("OceanTD_SpeciesId") == "TreeCoral" and stem.Name == "TreeCoral" then
			return true
		end
		stem = stem.Parent :: Instance
	end
	return false
end

local function collectTreeCoralParts(): { BasePart }
	local list: { BasePart } = {}
	local root = Workspace:FindFirstChild("OceanTD_Placed")
	if not root then
		return list
	end
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("BasePart") and d:GetAttribute("OceanTD_SpeciesId") == "TreeCoral" and d.Name == "TreeCoral" then
			table.insert(list, d)
			for _, ch in ipairs(d:GetDescendants()) do
				if ch:IsA("BasePart") then
					table.insert(list, ch)
				end
			end
		end
	end
	return list
end

local function ensureOverlay(part: BasePart)
	if overlays[part] then
		return
	end
	local box = Instance.new("SelectionBox")
	box.Name = "StandBox"
	box.Adornee = part
	box.LineThickness = 0.05
	box.SurfaceTransparency = 0.82
	box.Parent = ensureFolder()

	local fill = Instance.new("BoxHandleAdornment")
	fill.Name = "StandFill"
	fill.Adornee = part
	fill.Size = part.Size
	fill.AlwaysOnTop = false
	fill.ZIndex = 1
	fill.Parent = ensureFolder()

	overlays[part] = { box = box, fill = fill }
end

local function applyOverlayColors(part: BasePart, underfoot: boolean)
	local pack = overlays[part]
	if not pack then
		return
	end
	pack.fill.Size = part.Size
	local canStand = part.CanCollide
	local color = if underfoot
		then COLOR_UNDERFOOT
		elseif canStand then COLOR_STAND
		else COLOR_NO_COLLIDE
	pack.box.Color3 = color
	pack.box.SurfaceColor3 = color
	pack.box.LineThickness = if underfoot then 0.09 else 0.05
	pack.fill.Color3 = color
	pack.fill.Transparency = if underfoot then 0.45 elseif canStand then 0.68 else 0.78
end

local function findStandPart(): BasePart?
	local char = player.Character
	if not char then
		return nil
	end
	local hrp = char:FindFirstChild("HumanoidRootPart")
	if not hrp or not hrp:IsA("BasePart") then
		return nil
	end
	rayParams.FilterDescendantsInstances = { char, ensureFolder() }
	local origin = hrp.Position + Vector3.new(0, 1.2, 0)
	local hit = Workspace:Raycast(origin, Vector3.new(0, -12, 0), rayParams)
	if hit and hit.Instance:IsA("BasePart") and isTreeCoralPart(hit.Instance) then
		return hit.Instance
	end
	return nil
end

local function tickDebug()
	if not enabled() then
		clearAll()
		return
	end

	local parts = collectTreeCoralParts()
	local live: { [BasePart]: boolean } = {}
	for _, part in ipairs(parts) do
		live[part] = true
		ensureOverlay(part)
	end
	for part, pack in pairs(overlays) do
		if not live[part] or not part.Parent then
			pack.box:Destroy()
			pack.fill:Destroy()
			overlays[part] = nil
		end
	end

	local underfoot = findStandPart()
	for part, _ in pairs(overlays) do
		applyOverlayColors(part, part == underfoot)
	end
end

RunService.RenderStepped:Connect(tickDebug)

UserInputService.InputBegan:Connect(function(input, gp)
	if gp then
		return
	end
	if input.KeyCode == Enum.KeyCode.F9 then
		player:SetAttribute(ATTR, not enabled())
	end
end)
