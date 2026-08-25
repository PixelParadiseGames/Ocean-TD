--!strict
--[[
	Mid-air SeaGrass transfers: jump from one climb truss to another and latch at
	your current height instead of falling to the base and reclimbing.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer

-- How close (XZ) to a climb truss before we snap on while airborne.
local GRAB_XZ = 3.4
-- Must be within this many studs of the truss volume vertically (beyond its half-height).
local GRAB_Y_PAD = 1.25
-- After leaving a truss, ignore that same one briefly so jump-off works.
local SAME_TRUSS_COOLDOWN = 0.4
-- Don't re-snap every frame while already latched.
local LATCH_COOLDOWN = 0.22

local lastLeftTruss: TrussPart? = nil
local leftTrussAt = 0
local lastLatchAt = 0
local wasClimbing = false
local climbingTruss: TrussPart? = nil
local charConns: { RBXScriptConnection } = {}

local function collectClimbTrusses(): { TrussPart }
	local list: { TrussPart } = {}
	local root = Workspace:FindFirstChild("OceanTD_Placed")
	if not root then
		return list
	end
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("TrussPart") and d.Name == "OceanTD_Climb" and d.CanCollide then
			table.insert(list, d)
		end
	end
	return list
end

local function findTouchingClimbTruss(hrp: BasePart): TrussPart?
	-- Prefer overlap; fall back to nearest within a tight radius.
	local best: TrussPart? = nil
	local bestDist = math.huge
	for _, truss in ipairs(collectClimbTrusses()) do
		local localPos = truss.CFrame:PointToObjectSpace(hrp.Position)
		local half = truss.Size * 0.5
		local xz = Vector3.new(localPos.X, 0, localPos.Z).Magnitude
		local inY = math.abs(localPos.Y) <= half.Y + 2
		if inY and xz < bestDist then
			bestDist = xz
			best = truss
		end
	end
	if best and bestDist <= math.max(best.Size.X, best.Size.Z) * 0.65 + 1.2 then
		return best
	end
	return nil
end

local function canGrabTruss(hrp: BasePart, truss: TrussPart, now: number): boolean
	if lastLeftTruss == truss and (now - leftTrussAt) < SAME_TRUSS_COOLDOWN then
		return false
	end
	local localPos = truss.CFrame:PointToObjectSpace(hrp.Position)
	local half = truss.Size * 0.5
	if math.abs(localPos.Y) > half.Y + GRAB_Y_PAD then
		return false
	end
	local xz = Vector3.new(localPos.X, 0, localPos.Z).Magnitude
	return xz <= GRAB_XZ
end

local function latchOnto(hum: Humanoid, hrp: BasePart, truss: TrussPart)
	local localPos = truss.CFrame:PointToObjectSpace(hrp.Position)
	local half = truss.Size * 0.5
	-- Keep current height on this stalk; park near column center so Humanoid can climb.
	local y = math.clamp(localPos.Y, -half.Y + 0.75, half.Y - 0.75)
	local world = truss.CFrame:PointToWorldSpace(Vector3.new(0, y, 0))
	local look = hrp.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude < 1e-3 then
		flat = Vector3.new(0, 0, -1)
	else
		flat = flat.Unit
	end
	-- Face toward / along approach; keep feet roughly under HRP for climb.
	hrp.AssemblyLinearVelocity = Vector3.zero
	hrp.AssemblyAngularVelocity = Vector3.zero
	hrp.CFrame = CFrame.lookAt(world, world + flat, Vector3.yAxis)
	hum:ChangeState(Enum.HumanoidStateType.Climbing)
	climbingTruss = truss
	lastLatchAt = os.clock()
end

local function tryAirGrab(hum: Humanoid, hrp: BasePart)
	local state = hum:GetState()
	if state ~= Enum.HumanoidStateType.Jumping and state ~= Enum.HumanoidStateType.Freefall then
		return
	end
	local now = os.clock()
	if now - lastLatchAt < LATCH_COOLDOWN then
		return
	end

	local best: TrussPart? = nil
	local bestScore = math.huge
	for _, truss in ipairs(collectClimbTrusses()) do
		if not canGrabTruss(hrp, truss, now) then
			continue
		end
		local localPos = truss.CFrame:PointToObjectSpace(hrp.Position)
		local xz = Vector3.new(localPos.X, 0, localPos.Z).Magnitude
		-- Prefer the stalk whose height band best matches our Y (already gated), then closest XZ.
		local score = xz
		if score < bestScore then
			bestScore = score
			best = truss
		end
	end
	if best then
		latchOnto(hum, hrp, best)
	end
end

local function onHeartbeat(_dt: number)
	local char = player.Character
	if not char then
		return
	end
	local hum = char:FindFirstChildOfClass("Humanoid")
	local hrp = char:FindFirstChild("HumanoidRootPart")
	if not (hum and hrp and hrp:IsA("BasePart")) then
		return
	end
	if hum.Health <= 0 or hum.WalkSpeed <= 0 then
		return
	end

	local state = hum:GetState()
	local climbing = state == Enum.HumanoidStateType.Climbing
	if climbing then
		local touching = findTouchingClimbTruss(hrp)
		if touching then
			climbingTruss = touching
		end
		wasClimbing = true
		return
	end

	if wasClimbing then
		wasClimbing = false
		if climbingTruss then
			lastLeftTruss = climbingTruss
			leftTrussAt = os.clock()
			climbingTruss = nil
		end
	end

	tryAirGrab(hum, hrp)
end

local function bindCharacter(char: Model)
	for _, c in ipairs(charConns) do
		c:Disconnect()
	end
	table.clear(charConns)
	wasClimbing = false
	climbingTruss = nil
	lastLeftTruss = nil

	local hum = char:WaitForChild("Humanoid", 8)
	if not hum or not hum:IsA("Humanoid") then
		return
	end
	table.insert(charConns, hum.StateChanged:Connect(function(old, new)
		if old == Enum.HumanoidStateType.Climbing and new ~= Enum.HumanoidStateType.Climbing then
			wasClimbing = false
			if climbingTruss then
				lastLeftTruss = climbingTruss
				leftTrussAt = os.clock()
				climbingTruss = nil
			end
		elseif new == Enum.HumanoidStateType.Climbing then
			wasClimbing = true
			local hrp = char:FindFirstChild("HumanoidRootPart")
			if hrp and hrp:IsA("BasePart") then
				climbingTruss = findTouchingClimbTruss(hrp)
			end
		end
	end))
end

if player.Character then
	task.defer(bindCharacter, player.Character)
end
player.CharacterAdded:Connect(bindCharacter)

RunService.Heartbeat:Connect(onHeartbeat)
