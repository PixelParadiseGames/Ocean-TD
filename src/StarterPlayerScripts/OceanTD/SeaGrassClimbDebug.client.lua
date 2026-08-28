--!strict
--[[
	TEMP debug: SeaGrass climb TrussPart vs mesh (visuals only).
	GREEN = climb TrussPart (OceanTD_Climb), CYAN = SeaGrass mesh (non-collide).
	Toggle: F8, or player attribute OceanTD_SeaGrassClimbDebug.
	Tree Coral stand debug: TreeCoralStandDebug.client.lua (F9).
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer

local ATTR = "OceanTD_SeaGrassClimbDebug"
player:SetAttribute(ATTR, false)

local TRUSS_COLOR = Color3.fromRGB(40, 255, 90)
local TRUSS_NEAR = Color3.fromRGB(255, 90, 40)
local MESH_COLOR = Color3.fromRGB(80, 180, 255)

type TrussOverlay = { box: SelectionBox, fill: BoxHandleAdornment, meshBox: SelectionBox? }

local trussOverlays: { [TrussPart]: TrussOverlay } = {}
local folder: Folder? = nil

local function enabled(): boolean
	return player:GetAttribute(ATTR) == true
end

local function ensureFolder(): Folder
	local f = folder
	if f and f.Parent then
		return f
	end
	f = Instance.new("Folder")
	f.Name = "OceanTD_SeaGrassClimbDebug"
	f.Parent = Workspace
	folder = f
	return f
end

local function clearAll()
	for _, pack in pairs(trussOverlays) do
		pack.box:Destroy()
		pack.fill:Destroy()
		if pack.meshBox then
			pack.meshBox:Destroy()
		end
	end
	table.clear(trussOverlays)
	if folder then
		folder:Destroy()
		folder = nil
	end
end

local function collectClimbTrusses(): { TrussPart }
	local list: { TrussPart } = {}
	local root = Workspace:FindFirstChild("OceanTD_Placed")
	if not root then
		return list
	end
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("TrussPart") and d.Name == "OceanTD_Climb" then
			table.insert(list, d)
		end
	end
	return list
end

local function ensureTrussOverlay(truss: TrussPart)
	if trussOverlays[truss] then
		return
	end
	local box = Instance.new("SelectionBox")
	box.Name = "ClimbTrussBox"
	box.Adornee = truss
	box.Color3 = TRUSS_COLOR
	box.LineThickness = 0.05
	box.SurfaceTransparency = 0.85
	box.SurfaceColor3 = TRUSS_COLOR
	box.Parent = ensureFolder()

	local fill = Instance.new("BoxHandleAdornment")
	fill.Name = "ClimbTrussFill"
	fill.Adornee = truss
	fill.Size = truss.Size
	fill.Color3 = TRUSS_COLOR
	fill.Transparency = 0.72
	fill.AlwaysOnTop = false
	fill.ZIndex = 1
	fill.Parent = ensureFolder()

	local meshBox: SelectionBox? = nil
	local parent = truss.Parent
	if parent and parent:IsA("BasePart") then
		local mb = Instance.new("SelectionBox")
		mb.Name = "SeaGrassMeshBox"
		mb.Adornee = parent
		mb.Color3 = MESH_COLOR
		mb.LineThickness = 0.03
		mb.SurfaceTransparency = 0.92
		mb.SurfaceColor3 = MESH_COLOR
		mb.Parent = ensureFolder()
		meshBox = mb
	end

	trussOverlays[truss] = { box = box, fill = fill, meshBox = meshBox }
end

local function closestPointOnAabb(worldPos: Vector3, cf: CFrame, size: Vector3): Vector3
	local localPos = cf:PointToObjectSpace(worldPos)
	local half = size * 0.5
	local clamped = Vector3.new(
		math.clamp(localPos.X, -half.X, half.X),
		math.clamp(localPos.Y, -half.Y, half.Y),
		math.clamp(localPos.Z, -half.Z, half.Z)
	)
	return cf:PointToWorldSpace(clamped)
end

local function distToPart(worldPos: Vector3, part: BasePart): number
	local pt = closestPointOnAabb(worldPos, part.CFrame, part.Size)
	return (pt - worldPos).Magnitude
end

local function tickDebug()
	if not enabled() then
		clearAll()
		return
	end

	local trusses = collectClimbTrusses()
	local liveTruss: { [TrussPart]: boolean } = {}
	for _, truss in ipairs(trusses) do
		liveTruss[truss] = true
		ensureTrussOverlay(truss)
		local mesh = truss.Parent
		if mesh and mesh:IsA("BasePart") and mesh.CanCollide then
			mesh.CanCollide = false
		end
		if truss.CanCollide ~= true then
			truss.CanCollide = true
		end
		local pack = trussOverlays[truss]
		if pack then
			pack.fill.Size = truss.Size
		end
	end
	for truss, pack in pairs(trussOverlays) do
		if not liveTruss[truss] or not truss.Parent then
			pack.box:Destroy()
			pack.fill:Destroy()
			if pack.meshBox then
				pack.meshBox:Destroy()
			end
			trussOverlays[truss] = nil
		end
	end

	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not (hrp and hrp:IsA("BasePart")) then
		return
	end

	local bestTruss: TrussPart? = nil
	local bestDist = math.huge
	for _, truss in ipairs(trusses) do
		local d = distToPart(hrp.Position, truss)
		if d < bestDist then
			bestDist = d
			bestTruss = truss
		end
	end
	for truss, pack in pairs(trussOverlays) do
		local near = truss == bestTruss and bestDist <= 4
		local color = if near then TRUSS_NEAR else TRUSS_COLOR
		pack.box.Color3 = color
		pack.box.LineThickness = if near then 0.08 else 0.05
		pack.fill.Color3 = color
		pack.fill.Transparency = if near then 0.55 else 0.72
	end
end

RunService.RenderStepped:Connect(tickDebug)

UserInputService.InputBegan:Connect(function(input, gp)
	if gp then
		return
	end
	if input.KeyCode == Enum.KeyCode.F8 then
		player:SetAttribute(ATTR, not enabled())
	end
end)
