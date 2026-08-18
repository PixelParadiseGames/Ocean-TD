--!strict
--[[
	Wave 1 only: 3D arrow that always points at the lead hungry fish and slowly
	slides back and forth between in front of the player and that fish.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local AssetService = game:GetService("AssetService")

local Wave1LeadArrow = {}

export type LeadPosFn = () -> Vector3?

local ARROW_MESH_ID = "rbxassetid://16616461249"
local FRONT_STUDS = 5
local HEIGHT = 2.5
local FISH_LIFT = 4
local SLIDE_PERIOD = 6.5 -- full round-trip seconds
-- Far end of the slide stays this fraction of the player→fish gap away from the fish.
local FISH_KEEP_AWAY = 0.5
local AVATAR_SIZE_STUDS = 5 -- longest axis; about a default character

local token = 0
local conn: RBXScriptConnection? = nil
local arrow: BasePart? = nil
local getLeadPos: LeadPosFn? = nil

local function getHrp(): BasePart?
	local char = Players.LocalPlayer.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if hrp and hrp:IsA("BasePart") then
		return hrp
	end
	return nil
end

local function avatarTargetSize(): number
	local char = Players.LocalPlayer.Character
	if char then
		local ok, size = pcall(function()
			return char:GetExtentsSize()
		end)
		if ok and typeof(size) == "Vector3" then
			local longest = math.max(size.X, size.Y, size.Z)
			if longest > 1 then
				return longest
			end
		end
	end
	return AVATAR_SIZE_STUDS
end

local function applyArrowPhysics(p: BasePart)
	p.Name = "OceanTD_Wave1LeadArrow"
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Massless = true
	p.Material = Enum.Material.Neon
	p.Color = Color3.new(1, 1, 1)
	if p:IsA("MeshPart") then
		p.TextureID = ""
	end
end

local function scalePartToAvatar(p: BasePart)
	local target = avatarTargetSize()
	local longest = math.max(p.Size.X, p.Size.Y, p.Size.Z)
	if longest < 1e-3 then
		return
	end
	p.Size = p.Size * (target / longest)
end

local function makeMeshPart(): BasePart?
	local as = AssetService :: any
	local ok, mp = pcall(function()
		return as:CreateMeshPartAsync(ARROW_MESH_ID)
	end)
	if not (ok and typeof(mp) == "Instance" and mp:IsA("MeshPart")) then
		ok, mp = pcall(function()
			local Content = (game :: any).Content
			if Content and Content.fromUri then
				return as:CreateMeshPartAsync(Content.fromUri(ARROW_MESH_ID))
			end
			return nil
		end)
	end
	if ok and typeof(mp) == "Instance" and mp:IsA("MeshPart") then
		applyArrowPhysics(mp)
		scalePartToAvatar(mp)
		mp.Parent = Workspace
		return mp
	end
	return nil
end

local function makeSpecialMeshFallback(): BasePart
	local p = Instance.new("Part")
	applyArrowPhysics(p)
	p.Size = Vector3.new(0.2, 0.2, 0.2)
	p.Transparency = 0
	local mesh = Instance.new("SpecialMesh")
	mesh.Name = "ArrowMesh"
	mesh.MeshType = Enum.MeshType.FileMesh
	mesh.MeshId = ARROW_MESH_ID
	mesh.TextureId = ""
	mesh.VertexColor = Vector3.new(1, 1, 1)
	-- Authored mesh is huge; Scale 2.2 was larger than the plot. Fit to avatar.
	local s = avatarTargetSize() / 125
	mesh.Scale = Vector3.new(s, s, s)
	mesh.Parent = p
	p.Parent = Workspace
	return p
end

local function playerFront(): Vector3?
	local hrp = getHrp()
	if not hrp then
		return nil
	end
	return hrp.Position + hrp.CFrame.LookVector * FRONT_STUDS + Vector3.yAxis * HEIGHT
end

local function leadTarget(): Vector3?
	local fn = getLeadPos
	if not fn then
		return nil
	end
	local pos = fn()
	if pos then
		return pos + Vector3.yAxis * FISH_LIFT
	end
	return nil
end

local function destroyArrow()
	if conn then
		conn:Disconnect()
		conn = nil
	end
	if arrow then
		arrow:Destroy()
		arrow = nil
	end
end

local function ensureArrow(): BasePart
	local p = arrow
	if p and p.Parent then
		return p
	end
	p = makeMeshPart() or makeSpecialMeshFallback()
	arrow = p
	return p
end

local function setArrowVisible(p: BasePart, on: boolean)
	p.Transparency = if on then 0 else 1
	p.LocalTransparencyModifier = 0
end

local function slidePos(from: Vector3, dest: Vector3, u: number): Vector3
	local delta = dest - from
	local dist = delta.Magnitude
	if dist < 0.05 then
		return from
	end
	-- Closest allowed: halfway from you to the fish, and at least an avatar-length off the fish.
	local keepAway = math.max(dist * FISH_KEEP_AWAY, avatarTargetSize())
	local maxTravel = math.max(0, dist - keepAway)
	return from + delta.Unit * (maxTravel * math.clamp(u, 0, 1))
end

local function pointAt(from: Vector3, at: Vector3): CFrame
	local delta = at - from
	local lookTo = at
	if delta.Magnitude < 0.35 then
		local hrp = getHrp()
		local fwd = if hrp then hrp.CFrame.LookVector else Vector3.new(0, 0, -1)
		lookTo = from + fwd
	end
	-- Mesh tip is along -X ( +90° aimed the tail at the fish / tip at the player ).
	return CFrame.lookAt(from, lookTo) * CFrame.Angles(0, math.rad(-90), 0)
end

function Wave1LeadArrow.stop()
	token += 1
	getLeadPos = nil
	destroyArrow()
end

function Wave1LeadArrow.start(leadFn: LeadPosFn)
	token += 1
	local my = token
	getLeadPos = leadFn
	destroyArrow()
	local part = ensureArrow()
	local t0 = os.clock()

	conn = RunService.RenderStepped:Connect(function()
		if my ~= token then
			return
		end
		local from = playerFront()
		if not from then
			return
		end
		local dest = leadTarget()
		if not dest then
			setArrowVisible(part, false)
			return
		end
		setArrowVisible(part, true)
		local u = 0.5 - 0.5 * math.cos(((os.clock() - t0) / SLIDE_PERIOD) * math.pi * 2)
		local pos = slidePos(from, dest, u)
		part.CFrame = pointAt(pos, dest)
	end)
end

return Wave1LeadArrow
