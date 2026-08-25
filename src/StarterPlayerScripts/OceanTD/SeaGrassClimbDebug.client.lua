--!strict
--[[
	TEMP debug: SeaGrass climb TrussPart vs mesh + local Humanoid climb state.
	Toggle: F8, or set player attribute OceanTD_SeaGrassClimbDebug = false.
	Remove when climb feel is settled.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local ATTR = "OceanTD_SeaGrassClimbDebug"
-- Off by default (F8 still toggles for later).
player:SetAttribute(ATTR, false)

local overlays: { [TrussPart]: { box: SelectionBox, fill: BoxHandleAdornment, meshBox: SelectionBox? } } = {}
local folder: Folder? = nil
local hudLabel: TextLabel? = nil
local nearestMarker: Part? = nil
local conn: RBXScriptConnection? = nil
local inputConn: RBXScriptConnection? = nil

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

local function ensureHud(): TextLabel
	local existing = hudLabel
	if existing and existing.Parent then
		return existing
	end
	local sg = Instance.new("ScreenGui")
	sg.Name = "OceanTD_SeaGrassClimbDebugHud"
	sg.ResetOnSpawn = false
	sg.IgnoreGuiInset = true
	sg.DisplayOrder = 200
	sg.Parent = playerGui

	local lbl = Instance.new("TextLabel")
	lbl.Name = "Status"
	lbl.BackgroundColor3 = Color3.fromRGB(10, 14, 20)
	lbl.BackgroundTransparency = 0.25
	lbl.BorderSizePixel = 0
	lbl.AnchorPoint = Vector2.new(0, 0)
	lbl.Position = UDim2.fromOffset(12, 80)
	lbl.Size = UDim2.fromOffset(420, 160)
	lbl.Font = Enum.Font.Code
	lbl.TextSize = 14
	lbl.TextXAlignment = Enum.TextXAlignment.Left
	lbl.TextYAlignment = Enum.TextYAlignment.Top
	lbl.TextColor3 = Color3.fromRGB(220, 255, 220)
	lbl.Text = "SeaGrass climb debug (F8 toggle)"
	lbl.Parent = sg
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 8)
	pad.PaddingTop = UDim.new(0, 6)
	pad.Parent = lbl
	hudLabel = lbl
	return lbl
end

local function clearOverlays()
	for truss, pack in pairs(overlays) do
		pack.box:Destroy()
		pack.fill:Destroy()
		if pack.meshBox then
			pack.meshBox:Destroy()
		end
		overlays[truss] = nil
	end
	if nearestMarker then
		nearestMarker:Destroy()
		nearestMarker = nil
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

local function ensureOverlay(truss: TrussPart)
	if overlays[truss] then
		return
	end
	local box = Instance.new("SelectionBox")
	box.Name = "ClimbTrussBox"
	box.Adornee = truss
	box.Color3 = Color3.fromRGB(40, 255, 90)
	box.LineThickness = 0.05
	box.SurfaceTransparency = 0.85
	box.SurfaceColor3 = Color3.fromRGB(40, 255, 90)
	box.Parent = ensureFolder()

	local fill = Instance.new("BoxHandleAdornment")
	fill.Name = "ClimbTrussFill"
	fill.Adornee = truss
	fill.Size = truss.Size
	fill.Color3 = Color3.fromRGB(40, 255, 90)
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
		mb.Color3 = Color3.fromRGB(80, 180, 255)
		mb.LineThickness = 0.03
		mb.SurfaceTransparency = 0.92
		mb.SurfaceColor3 = Color3.fromRGB(80, 180, 255)
		mb.Parent = ensureFolder()
		meshBox = mb
	end

	overlays[truss] = { box = box, fill = fill, meshBox = meshBox }
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

local function pointInsideAabb(worldPos: Vector3, cf: CFrame, size: Vector3, pad: number): boolean
	local localPos = cf:PointToObjectSpace(worldPos)
	local half = size * 0.5 + Vector3.new(pad, pad, pad)
	return math.abs(localPos.X) <= half.X
		and math.abs(localPos.Y) <= half.Y
		and math.abs(localPos.Z) <= half.Z
end

local function ensureNearestMarker(): Part
	local m = nearestMarker
	if m and m.Parent then
		return m
	end
	m = Instance.new("Part")
	m.Name = "NearestClimbPoint"
	m.Shape = Enum.PartType.Ball
	m.Size = Vector3.new(0.55, 0.55, 0.55)
	m.Color = Color3.fromRGB(255, 220, 40)
	m.Material = Enum.Material.Neon
	m.Anchored = true
	m.CanCollide = false
	m.CanQuery = false
	m.CanTouch = false
	m.CastShadow = false
	m.Parent = ensureFolder()
	nearestMarker = m
	return m
end

local function setVisible(on: boolean)
	local hud = ensureHud()
	hud.Visible = on
	hud.Parent.Enabled = on
	if not on then
		clearOverlays()
		if folder then
			folder:Destroy()
			folder = nil
		end
	end
end

local function tickDebug()
	if not enabled() then
		setVisible(false)
		return
	end
	setVisible(true)

	local trusses = collectClimbTrusses()
	local live: { [TrussPart]: boolean } = {}
	for _, truss in ipairs(trusses) do
		live[truss] = true
		ensureOverlay(truss)
		-- Live-session fix: older SeaGrass may still have mesh collide on.
		local mesh = truss.Parent
		if mesh and mesh:IsA("BasePart") and mesh.CanCollide then
			mesh.CanCollide = false
		end
		if truss.CanCollide ~= true then
			truss.CanCollide = true
		end
		local pack = overlays[truss]
		if pack then
			pack.fill.Size = truss.Size
			pack.fill.Visible = true
			pack.box.Visible = true
			if pack.meshBox then
				pack.meshBox.Visible = true
			end
		end
	end
	for truss, pack in pairs(overlays) do
		if not live[truss] or not truss.Parent then
			pack.box:Destroy()
			pack.fill:Destroy()
			if pack.meshBox then
				pack.meshBox:Destroy()
			end
			overlays[truss] = nil
		end
	end

	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local lines = {
		"SeaGrass climb debug  [F8 toggle]",
		"GREEN = climb TrussPart   CYAN = SeaGrass mesh",
		"YELLOW = closest point on nearest truss",
		string.format("trusses nearby/world: %d", #trusses),
	}

	if not (hrp and hrp:IsA("BasePart") and hum) then
		table.insert(lines, "no character")
		ensureHud().Text = table.concat(lines, "\n")
		return
	end

	local best: TrussPart? = nil
	local bestDist = math.huge
	local bestPt = hrp.Position
	for _, truss in ipairs(trusses) do
		local pt = closestPointOnAabb(hrp.Position, truss.CFrame, truss.Size)
		local d = (pt - hrp.Position).Magnitude
		if d < bestDist then
			bestDist = d
			best = truss
			bestPt = pt
		end
	end

	for truss, pack in pairs(overlays) do
		local isNear = truss == best
		pack.box.Color3 = if isNear then Color3.fromRGB(255, 90, 40) else Color3.fromRGB(40, 255, 90)
		pack.box.LineThickness = if isNear then 0.08 else 0.05
		pack.fill.Color3 = if isNear then Color3.fromRGB(255, 120, 40) else Color3.fromRGB(40, 255, 90)
		pack.fill.Transparency = if isNear then 0.55 else 0.72
	end

	local marker = ensureNearestMarker()
	if best then
		marker.CFrame = CFrame.new(bestPt)
		marker.Transparency = 0
	else
		marker.Transparency = 1
	end

	local state = hum:GetState()
	local floor = hum.FloorMaterial
	local jumping = hum.Jump == true
	local inside = best ~= nil and pointInsideAabb(hrp.Position, best.CFrame, best.Size, 0.35)
	local meshParent = best and best.Parent
	local meshCollide = if meshParent and meshParent:IsA("BasePart") then meshParent.CanCollide else nil
	local trussSize = if best then best.Size else Vector3.zero

	-- Soft "would grab" heuristic: within 2.5 studs of truss surface + roughly overlapping height.
	local grabLikely = best ~= nil and bestDist <= 2.5 and inside

	table.insert(lines, string.format("state=%s  floor=%s  jump=%s", tostring(state), tostring(floor), tostring(jumping)))
	table.insert(lines, string.format("nearestDist=%.2f  insideTruss(+0.35)=%s  grabLikely=%s", bestDist, tostring(inside), tostring(grabLikely)))
	if best then
		table.insert(lines, string.format("trussSize=%.1f×%.1f×%.1f  collide=%s", trussSize.X, trussSize.Y, trussSize.Z, tostring(best.CanCollide)))
		table.insert(lines, string.format("meshCanCollide=%s  trussTransparency=%.2f", tostring(meshCollide), best.Transparency))
		local ok = state == Enum.HumanoidStateType.Climbing
		table.insert(lines, if ok then ">>> CLIMBING" else ">>> not climbing (need touch Truss while rising/near)")
	else
		table.insert(lines, "no OceanTD_Climb truss found under OceanTD_Placed")
	end

	ensureHud().Text = table.concat(lines, "\n")
	ensureHud().TextColor3 = if state == Enum.HumanoidStateType.Climbing
		then Color3.fromRGB(120, 255, 160)
		elseif grabLikely then Color3.fromRGB(255, 230, 120)
		else Color3.fromRGB(220, 255, 220)
end

if not conn then
	conn = RunService.RenderStepped:Connect(tickDebug)
end

inputConn = UserInputService.InputBegan:Connect(function(input, gp)
	if gp then
		return
	end
	if input.KeyCode == Enum.KeyCode.F8 then
		player:SetAttribute(ATTR, not enabled())
	end
end)
