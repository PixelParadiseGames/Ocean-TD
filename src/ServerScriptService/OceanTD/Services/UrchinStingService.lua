--!strict
--[[
	Urchin player sting: cooldown, steal up to 30 $D, spawn 2× neon orbs, FireClient VFX.
	Wave host (or any nearby client) reports; server validates distances.
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local Remotes = require(oceanRoot:WaitForChild("Remotes"))
local PersistenceService = require(script.Parent:WaitForChild("PersistenceService"))

local UrchinStingService = {}

local COOLDOWN_SEC = 3
local STEAL_MAX = 30
local VICTIM_RADIUS = 28
local REPORTER_RADIUS = 140
local ORB_LIFETIME = 20
local ORB_SETTLE = 1.35 -- fountain flight duration (slow arc)
local ORB_SPREAD_MIN = 3.3
local ORB_SPREAD_SPAN = 5.1
local ORB_COLOR = Color3.fromRGB(40, 255, 90)
local FOLDER_NAME = "OceanTD_UrchinSandDrops"
local ATTR_READY = "OceanTD_ReadyPickup"
local ATTR_ORB = "OceanTD_UrchinOrb"

local lastStingAt: { [number]: number } = {}
local orbBusy: { [BasePart]: boolean } = {}
local folder: Folder? = nil
local nextOrbId = 1

local function ensureFolder(): Folder
	local f = folder
	if f and f.Parent then
		return f
	end
	local existing = Workspace:FindFirstChild(FOLDER_NAME)
	if existing and existing:IsA("Folder") then
		folder = existing
		return existing
	end
	if existing then
		existing:Destroy()
	end
	local created = Instance.new("Folder")
	created.Name = FOLDER_NAME
	created.Parent = Workspace
	folder = created
	return created
end

local function rootPos(player: Player): Vector3?
	local char = player.Character
	if not char then
		return nil
	end
	local hrp = char:FindFirstChild("HumanoidRootPart")
	if hrp and hrp:IsA("BasePart") then
		return hrp.Position
	end
	return nil
end

local function destroyOrb(orb: BasePart)
	orbBusy[orb] = nil
	if orb.Parent then
		orb:Destroy()
	end
end

local function fadeAndDestroy(orb: BasePart)
	if not orb.Parent then
		return
	end
	orb:SetAttribute(ATTR_READY, false)
	local tw = TweenService:Create(orb, TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
		Transparency = 1,
		Size = orb.Size * 0.2,
	})
	tw:Play()
	tw.Completed:Connect(function()
		destroyOrb(orb)
	end)
	task.delay(0.5, function()
		if orb.Parent then
			destroyOrb(orb)
		end
	end)
end

local function onOrbTouched(orb: BasePart, hit: BasePart)
	if orb:GetAttribute(ATTR_READY) ~= true then
		return
	end
	if orbBusy[orb] then
		return
	end
	local char = hit:FindFirstAncestorOfClass("Model")
	if not char then
		return
	end
	local plr = Players:GetPlayerFromCharacter(char)
	if not plr then
		return
	end
	orbBusy[orb] = true
	orb:SetAttribute(ATTR_READY, false)
	local ok, granted = PersistenceService.creditSandDollars(plr, 1)
	if ok and granted > 0 then
		Remotes.get("UrchinSandOrbPicked"):FireClient(plr, orb.Position, granted)
	end
	destroyOrb(orb)
end

local function spawnOrb(origin: Vector3, index: number, total: number)
	local parent = ensureFolder()
	local yaw = (index / math.max(total, 1)) * math.pi * 2 + math.random() * 0.55
	local dist = ORB_SPREAD_MIN + math.random() * ORB_SPREAD_SPAN
	local dir = Vector3.new(math.cos(yaw), 0, math.sin(yaw))
	local start = origin + Vector3.new(0, 1.1 + math.random() * 0.4, 0)
	-- Control point high above / slightly out — classic fountain spray then fall.
	local peak = origin + dir * (dist * 0.28) + Vector3.new(0, 6.5 + math.random() * 3.5, 0)
	local land = origin + dir * dist + Vector3.new(0, 0.3 + math.random() * 0.7, 0)

	local orb = Instance.new("Part")
	orb.Name = "UrchinSandOrb_" .. tostring(nextOrbId)
	nextOrbId += 1
	orb.Shape = Enum.PartType.Ball
	orb.Material = Enum.Material.Neon
	orb.Color = ORB_COLOR
	orb.Size = Vector3.new(0.2, 0.2, 0.2)
	orb.Anchored = true
	orb.CanCollide = false
	orb.CanQuery = false
	orb.CanTouch = true
	orb.CastShadow = false
	orb.Transparency = 0
	orb.CFrame = CFrame.new(start)
	orb:SetAttribute(ATTR_ORB, true)
	orb:SetAttribute(ATTR_READY, false)
	orb.Parent = parent

	if index % 2 == 1 then
		local light = Instance.new("PointLight")
		light.Color = ORB_COLOR
		light.Brightness = 1.4
		light.Range = 8
		light.Parent = orb
	end

	local bb = Instance.new("BillboardGui")
	bb.Name = "Dollar"
	bb.Size = UDim2.fromScale(2.4, 1.2)
	bb.StudsOffset = Vector3.new(0, 1.1, 0)
	bb.AlwaysOnTop = true
	bb.MaxDistance = 120
	bb.Parent = orb
	local lbl = Instance.new("TextLabel")
	lbl.BackgroundTransparency = 1
	lbl.Size = UDim2.fromScale(1, 1)
	lbl.Font = Enum.Font.FredokaOne
	lbl.Text = "$D"
	lbl.TextColor3 = ORB_COLOR
	lbl.TextScaled = true
	lbl.TextStrokeTransparency = 0.3
	lbl.TextStrokeColor3 = Color3.fromRGB(0, 40, 15)
	lbl.Parent = bb

	local shell = Instance.new("Part")
	shell.Name = "PickupShell"
	shell.Shape = Enum.PartType.Ball
	shell.Transparency = 1
	shell.Size = Vector3.new(4.4, 4.4, 4.4)
	shell.Anchored = true
	shell.CanCollide = false
	shell.CanQuery = false
	shell.CanTouch = true
	shell.Massless = true
	shell.CFrame = orb.CFrame
	shell.Parent = orb

	local flight = ORB_SETTLE * (0.9 + math.random() * 0.35)
	local t0 = os.clock()
	local conn: RBXScriptConnection? = nil
	conn = RunService.Heartbeat:Connect(function()
		if not orb.Parent then
			if conn then
				conn:Disconnect()
			end
			return
		end
		local u = math.clamp((os.clock() - t0) / flight, 0, 1)
		-- Ease out on the way up, ease in on the fall (quadratic bezier param).
		local e = u * u * (3 - 2 * u)
		local ou = 1 - e
		local pos = start * (ou * ou) + peak * (2 * ou * e) + land * (e * e)
		local sz = 0.2 + 0.95 * math.min(1, u * 1.35)
		orb.Size = Vector3.new(sz, sz, sz)
		orb.CFrame = CFrame.new(pos)
		shell.CFrame = orb.CFrame
		if u >= 1 then
			if conn then
				conn:Disconnect()
			end
			orb:SetAttribute(ATTR_READY, true)
		end
	end)

	shell.Touched:Connect(function(hit)
		if hit and hit:IsA("BasePart") then
			onOrbTouched(orb, hit)
		end
	end)
	orb.Touched:Connect(function(hit)
		if hit and hit:IsA("BasePart") then
			onOrbTouched(orb, hit)
		end
	end)

	task.delay(ORB_LIFETIME, function()
		if orb.Parent then
			fadeAndDestroy(orb)
		end
	end)
end

local function spawnOrbBurst(urchinPos: Vector3, stolen: number)
	local count = math.max(0, stolen * 2)
	if count <= 0 then
		return
	end
	for i = 1, count do
		spawnOrb(urchinPos, i, count)
	end
end

local function knockVelocity(victimPos: Vector3, urchinPos: Vector3): Vector3
	local flat = Vector3.new(victimPos.X - urchinPos.X, 0, victimPos.Z - urchinPos.Z)
	if flat.Magnitude < 0.15 then
		local a = math.random() * math.pi * 2
		flat = Vector3.new(math.cos(a), 0, math.sin(a))
	else
		flat = flat.Unit
	end
	return flat * 58 + Vector3.new(0, 32, 0)
end

function UrchinStingService.handleReport(reporter: Player, victimUserId: any, xAny: any, yAny: any, zAny: any)
	local victimId = math.floor(tonumber(victimUserId) or 0)
	if victimId <= 0 then
		return
	end
	local victim = Players:GetPlayerByUserId(victimId)
	if not victim then
		return
	end
	local x = tonumber(xAny)
	local y = tonumber(yAny)
	local z = tonumber(zAny)
	-- Legacy: second arg was a Vector3.
	local urchinPos: Vector3? = nil
	if typeof(xAny) == "Vector3" then
		urchinPos = xAny
	elseif x and y and z then
		urchinPos = Vector3.new(x, y, z)
	end
	if not urchinPos then
		return
	end

	local now = os.clock()
	local last = lastStingAt[victimId]
	if last and now - last < COOLDOWN_SEC then
		return
	end

	local vPos = rootPos(victim)
	if not vPos then
		return
	end
	if (vPos - urchinPos).Magnitude > VICTIM_RADIUS then
		return
	end
	local rPos = rootPos(reporter)
	if not rPos or (rPos - urchinPos).Magnitude > REPORTER_RADIUS then
		return
	end

	lastStingAt[victimId] = now
	local stolen = select(1, PersistenceService.stealSandDollars(victim, STEAL_MAX))
	local vel = knockVelocity(vPos, urchinPos)
	Remotes.get("UrchinSting"):FireClient(victim, {
		velX = vel.X,
		velY = vel.Y,
		velZ = vel.Z,
		stolen = stolen,
		urchinX = urchinPos.X,
		urchinY = urchinPos.Y,
		urchinZ = urchinPos.Z,
	})
	if stolen > 0 then
		spawnOrbBurst(urchinPos, stolen)
	end
end

function UrchinStingService.init()
	ensureFolder()
	Remotes.get("ReportUrchinSting").OnServerEvent:Connect(function(player, victimUserId, x, y, z)
		UrchinStingService.handleReport(player, victimUserId, x, y, z)
	end)
	Players.PlayerRemoving:Connect(function(player)
		lastStingAt[player.UserId] = nil
	end)
end

return UrchinStingService
