--!strict
--[[
	Placed-coral pick + idle hover highlight (chunked for Luau local-register limit).
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local CoralVisual = require(oceanRoot:WaitForChild("Shared"):WaitForChild("CoralVisual"))
local UiCircles = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiCircles"))
local UiTheme = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiTheme"))

local ClientPlot = require(script.Parent:WaitForChild("ClientPlot"))
local InventoryState = require(script.Parent:WaitForChild("InventoryState"))
local PlacementController = require(script.Parent:WaitForChild("PlacementController"))
local SelectRing = require(script.Parent:WaitForChild("SelectRing"))
local RelocateConsts = require(script.Parent:WaitForChild("RelocateConsts"))

local RelocatePickHover = {}

local C = RelocateConsts
local player = Players.LocalPlayer

export type Host = {
	getPrimary: () -> BasePart?,
	getBlockPart: () -> BasePart?,
	getSelectRing: () -> SelectRing.Handle,
	isActive: () -> boolean,
	isBusy: () -> boolean,
	playerGui: PlayerGui,
}

local host: Host? = nil
local hoverPart: BasePart? = nil
local hoverBaseMaterial: Enum.Material? = nil
local hoverBaseColor: Color3? = nil
local hoverHintBb: BillboardGui? = nil
local hoverHintBadge: Frame? = nil
local hoverHintMove: Frame? = nil
local hoverHintT0 = 0
local hoverConn: RBXScriptConnection? = nil

function RelocatePickHover.mount(h: Host)
	host = h
end

local function isUsingGamepad(): boolean
	local t = UserInputService:GetLastInputType()
	return t == Enum.UserInputType.Gamepad1
		or t == Enum.UserInputType.Gamepad2
		or t == Enum.UserInputType.Gamepad3
		or t == Enum.UserInputType.Gamepad4
end

local function hoverPickScreenPos(): Vector2
	if isUsingGamepad() then
		local cam = Workspace.CurrentCamera
		if cam then
			local vp = cam.ViewportSize
			return Vector2.new(vp.X * 0.5, vp.Y * 0.5)
		end
	end
	return UserInputService:GetMouseLocation()
end

local function viewportRay(cam: Camera, vp: Vector2): Ray
	return cam:ViewportPointToRay(vp.X, vp.Y)
end

local function worldToViewport(cam: Camera, world: Vector3): (Vector2?, boolean)
	local sp, onScreen = cam:WorldToViewportPoint(world)
	if not onScreen or sp.Z <= 0 then
		return nil, false
	end
	return Vector2.new(sp.X, sp.Y), true
end

local function isPlacedCoralPart(inst: Instance): BasePart?
	if not inst:IsA("BasePart") then
		return nil
	end
	local n = inst.Name
	if n == "OceanTD_CoralAmmo" or n == "OceanTD_FoodOrb" or string.find(n, "Tang_", 1, true) == 1 then
		return nil
	end
	if typeof(inst:GetAttribute("OceanTD_GhostBaseR")) == "number" then
		return nil
	end
	if typeof(inst:GetAttribute("OceanTD_ItemId")) == "string" or typeof(inst:GetAttribute("OceanTD_SpeciesId")) == "string" then
		return inst
	end
	return nil
end

local function getPlotFolder(): Folder?
	local plot = ClientPlot.get()
	if not plot then
		return nil
	end
	local root = Workspace:FindFirstChild("OceanTD_Placed")
	local folder = root and root:FindFirstChild(plot.plotId)
	if folder and folder:IsA("Folder") then
		return folder
	end
	return nil
end

function RelocatePickHover.findByPlaceId(placeIdWant: string): BasePart?
	local placedRoot = Workspace:FindFirstChild("OceanTD_Placed")
	if not placedRoot then
		return nil
	end

	local function coralFrom(inst: Instance): BasePart?
		if inst:IsA("BasePart") and inst:GetAttribute("OceanTD_PlaceId") == placeIdWant then
			return isPlacedCoralPart(inst)
		end
		return nil
	end

	local plotFolder = getPlotFolder()
	if plotFolder then
		for _, d in ipairs(plotFolder:GetDescendants()) do
			local coral = coralFrom(d)
			if coral then
				return coral
			end
		end
	end

	for _, folder in ipairs(placedRoot:GetChildren()) do
		if folder:IsA("Folder") then
			for _, d in ipairs(folder:GetDescendants()) do
				local coral = coralFrom(d)
				if coral then
					return coral
				end
			end
		end
	end
	return nil
end

function RelocatePickHover.pick(screenPos: Vector2): BasePart?
	local h = host
	local folder = getPlotFolder()
	local cam = Workspace.CurrentCamera
	if not folder or not cam then
		return nil
	end
	local primary = if h then h.getPrimary() else nil

	local exclude: { Instance } = {}
	if player.Character then
		table.insert(exclude, player.Character)
	end
	if primary then
		table.insert(exclude, primary)
	end

	local worldParams = RaycastParams.new()
	worldParams.FilterType = Enum.RaycastFilterType.Exclude
	worldParams.FilterDescendantsInstances = exclude

	local function coralFromHit(inst: Instance): BasePart?
		local cur: Instance? = inst
		while cur and cur ~= folder.Parent do
			if cur == folder then
				break
			end
			if cur:IsA("BasePart") and cur:IsDescendantOf(folder) then
				local coral = isPlacedCoralPart(cur)
				if coral then
					return coral
				end
			end
			cur = cur.Parent
		end
		return nil
	end

	local ray = viewportRay(cam, screenPos)
	local result = Workspace:Raycast(ray.Origin, ray.Direction * 800, worldParams)
	if result then
		local hit = coralFromHit(result.Instance)
		if hit then
			return hit
		end
	end

	local losParams = RaycastParams.new()
	losParams.FilterType = Enum.RaycastFilterType.Exclude

	local function hasLineOfSight(coral: BasePart): boolean
		local origin = cam.CFrame.Position
		local target = coral.Position
		local delta = target - origin
		local dist = delta.Magnitude
		if dist < 0.25 then
			return true
		end
		local list: { Instance } = { coral }
		if player.Character then
			table.insert(list, player.Character)
		end
		losParams.FilterDescendantsInstances = list
		local losHit = Workspace:Raycast(origin, delta.Unit * dist, losParams)
		if not losHit then
			return true
		end
		return losHit.Distance >= dist - 0.35
	end

	local radius = if isUsingGamepad() then math.max(C.PICK_SCREEN_PX, 72) else C.PICK_SCREEN_PX
	local c1: BasePart? = nil
	local c2: BasePart? = nil
	local c3: BasePart? = nil
	local d1, d2, d3 = radius + 1, radius + 1, radius + 1
	for _, inst in ipairs(folder:GetChildren()) do
		local coral = isPlacedCoralPart(inst)
		if coral and coral ~= primary then
			local sp = worldToViewport(cam, coral.Position)
			if sp then
				local d = (sp - screenPos).Magnitude
				if d <= radius then
					if d < d1 then
						c3, d3 = c2, d2
						c2, d2 = c1, d1
						c1, d1 = coral, d
					elseif d < d2 then
						c3, d3 = c2, d2
						c2, d2 = coral, d
					elseif d < d3 then
						c3, d3 = coral, d
					end
				end
			end
		end
	end

	if c1 and hasLineOfSight(c1) then
		return c1
	end
	if c2 and hasLineOfSight(c2) then
		return c2
	end
	if c3 and hasLineOfSight(c3) then
		return c3
	end
	return nil
end

function RelocatePickHover.pointerHitsSelected(screenPos: Vector2): boolean
	local h = host
	local primary = if h then h.getPrimary() else nil
	if not primary or not primary.Parent then
		return false
	end
	local cam = Workspace.CurrentCamera
	if not cam then
		return false
	end
	local ray = viewportRay(cam, screenPos)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local exclude: { Instance } = {}
	if player.Character then
		table.insert(exclude, player.Character)
	end
	params.FilterDescendantsInstances = exclude
	local result = Workspace:Raycast(ray.Origin, ray.Direction * 800, params)
	if result then
		local cur: Instance? = result.Instance
		while cur do
			if cur == primary then
				return true
			end
			cur = cur.Parent
		end
	end
	local sp = worldToViewport(cam, primary.Position)
	if sp then
		local radius = if isUsingGamepad() then math.max(C.PICK_SCREEN_PX, 72) else C.PICK_SCREEN_PX
		if (sp - screenPos).Magnitude <= radius then
			return true
		end
	end
	return false
end

local function destroyHoverHint()
	if hoverHintBb then
		hoverHintBb:Destroy()
		hoverHintBb = nil
	end
	hoverHintBadge = nil
	hoverHintMove = nil
end

local function ensureHoverHint(adornee: BasePart, playerGui: PlayerGui)
	if hoverHintBb and hoverHintBb.Parent and hoverHintBb.Adornee == adornee then
		return
	end
	destroyHoverHint()
	local bb = Instance.new("BillboardGui")
	bb.Name = "OceanTD_RelocateHoverHint"
	bb.AlwaysOnTop = true
	bb.Active = false
	bb.LightInfluence = 0
	bb.Size = UDim2.fromOffset(C.HOVER_HINT_SIZE, C.HOVER_HINT_SIZE)
	bb.StudsOffset = Vector3.new(0, 2.6, 0)
	bb.MaxDistance = 2000
	bb.Adornee = adornee
	bb.Parent = playerGui

	local badge = Instance.new("Frame")
	badge.Name = "R1Badge"
	badge.BackgroundColor3 = Color3.new(0, 0, 0)
	badge.BackgroundTransparency = 0.15
	badge.BorderSizePixel = 0
	badge.Size = UDim2.fromScale(1, 1)
	badge.Parent = bb
	UiCircles.ensure(badge)
	local lbl = Instance.new("TextLabel")
	lbl.BackgroundTransparency = 1
	lbl.Size = UDim2.fromScale(1, 1)
	lbl.Font = UiTheme.Font
	lbl.Text = "R1"
	lbl.TextColor3 = Color3.new(1, 1, 1)
	lbl.TextScaled = true
	lbl.Parent = badge

	local moveBg = Instance.new("Frame")
	moveBg.Name = "MoveHint"
	moveBg.BackgroundColor3 = Color3.new(0, 0, 0)
	moveBg.BackgroundTransparency = 0.15
	moveBg.BorderSizePixel = 0
	moveBg.Size = UDim2.fromScale(1, 1)
	moveBg.Visible = false
	moveBg.Parent = bb
	UiCircles.ensure(moveBg)
	local move = Instance.new("ImageLabel")
	move.BackgroundTransparency = 1
	move.AnchorPoint = Vector2.new(0.5, 0.5)
	move.Position = UDim2.fromScale(0.5, 0.5)
	move.Size = UDim2.fromScale(0.7, 0.7)
	move.Image = C.MOVE_ICON_IMAGE
	move.ScaleType = Enum.ScaleType.Fit
	move.Parent = moveBg

	hoverHintBb = bb
	hoverHintBadge = badge
	hoverHintMove = moveBg
	hoverHintT0 = os.clock()
end

local function updateHoverHint(playerGui: PlayerGui)
	if not isUsingGamepad() or not hoverPart or not hoverPart.Parent then
		destroyHoverHint()
		return
	end
	ensureHoverHint(hoverPart, playerGui)
	local showMove = (math.floor((os.clock() - hoverHintT0) / C.HOVER_HINT_PERIOD) % 2) == 1
	if hoverHintBadge then
		hoverHintBadge.Visible = not showMove
	end
	if hoverHintMove then
		hoverHintMove.Visible = showMove
	end
end

function RelocatePickHover.getHoverPart(): BasePart?
	return hoverPart
end

function RelocatePickHover.clearHover()
	local h = host
	local ring = if h then h.getSelectRing() else nil
	destroyHoverHint()
	if ring and SelectRing.getAdornee(ring) == hoverPart then
		SelectRing.destroy(ring)
	end
	if hoverPart and hoverPart.Parent then
		if hoverBaseMaterial and hoverBaseColor then
			hoverPart.Material = hoverBaseMaterial
			hoverPart.Color = hoverBaseColor
		else
			CoralVisual.applyRestLook(hoverPart)
		end
	elseif hoverPart and ring then
		SelectRing.destroy(ring)
	end
	hoverPart = nil
	hoverBaseMaterial = nil
	hoverBaseColor = nil
end

local function setHover(target: BasePart?)
	local h = host
	if not h then
		return
	end
	if hoverPart == target then
		return
	end
	RelocatePickHover.clearHover()
	if not target or not target.Parent then
		return
	end
	if h.getBlockPart() == target then
		return
	end
	if not isPlacedCoralPart(target) then
		return
	end
	hoverPart = target
	local restMat, restColor = CoralVisual.readRestLook(target)
	hoverBaseMaterial = restMat
	hoverBaseColor = restColor
	target.Material = Enum.Material.Neon
	SelectRing.ensure(h.getSelectRing(), target, h.playerGui)
end

local function updateHoverFlash()
	local h = host
	if not hoverPart or not hoverPart.Parent or not hoverBaseColor or not h then
		return
	end
	local pulse = 0.5 + 0.5 * math.sin(os.clock() * 9)
	hoverPart.Material = Enum.Material.Neon
	hoverPart.Color = hoverBaseColor:Lerp(Color3.new(1, 1, 1), 0.12 + 0.28 * pulse)
	SelectRing.pulse(h.getSelectRing())
end

function RelocatePickHover.stopLoop()
	if hoverConn then
		hoverConn:Disconnect()
		hoverConn = nil
	end
	RelocatePickHover.clearHover()
end

function RelocatePickHover.startLoop()
	local h = host
	if hoverConn or not h then
		return
	end
	hoverConn = RunService.RenderStepped:Connect(function()
		if h.isActive() or h.isBusy() or not InventoryState.isOpen() or PlacementController.isActive()
			or InventoryState.isBuildModalBlocking()
		then
			RelocatePickHover.clearHover()
			return
		end
		local screenPos = hoverPickScreenPos()
		if not isUsingGamepad() and InventoryState.isPointerOverBackpack(screenPos) then
			RelocatePickHover.clearHover()
			return
		end
		local hit = RelocatePickHover.pick(screenPos)
		if hit then
			setHover(hit)
			updateHoverFlash()
			updateHoverHint(h.playerGui)
		else
			RelocatePickHover.clearHover()
		end
	end)
end

return RelocatePickHover
