--!strict
-- Brain Coral trampoline: landing/jumping on a coral bounces you up. Stacks to 4.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer

-- Bounce apex heights (studs). Stack 1..4; default jump is ~7.2.
local HEIGHTS = { 14, 26, 42, 62 }
local STACK_RESET_SEC = 1.6
local BOUNCE_LOCK_SEC = 0.18

local stack = 0
local lastCoralBounceAt = 0
local bounceLockUntil = 0
local charConns: { RBXScriptConnection } = {}

local function isFx(inst: Instance): boolean
	local n = inst.Name
	return n == "OceanTD_CoralAmmo" or n == "OceanTD_FoodOrb" or string.find(n, "Tang_", 1, true) == 1
end

local function isBrainCoral(inst: Instance): boolean
	if not inst:IsA("BasePart") then
		return false
	end
	if inst:GetAttribute("OceanTD_GhostBaseR") ~= nil then
		return false
	end
	return inst:GetAttribute("OceanTD_SpeciesId") == "BrainCoral"
end

local function floorCoral(hrp: BasePart): BasePart?
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local char = hrp.Parent
	params.FilterDescendantsInstances = if char then { char } else {}
	local origin = hrp.Position
	local dir = Vector3.new(0, -10, 0)
	for _ = 1, 6 do
		local hit = Workspace:Raycast(origin, dir, params)
		if not hit then
			return nil
		end
		local inst = hit.Instance
		if isFx(inst) then
			origin = hit.Position + Vector3.new(0, -0.08, 0)
			continue
		end
		if isBrainCoral(inst) then
			return inst
		end
		return nil
	end
	return nil
end

local function bounceSpeed(n: number): number
	local h = HEIGHTS[math.clamp(n, 1, 4)]
	return math.sqrt(2 * Workspace.Gravity * h)
end

local function tryBounce(hum: Humanoid, hrp: BasePart, fromAir: boolean)
	local now = os.clock()
	if now < bounceLockUntil then
		return
	end
	if hum.WalkSpeed <= 0 then
		return
	end
	if not floorCoral(hrp) then
		if fromAir then
			stack = 0
		end
		return
	end
	if now - lastCoralBounceAt > STACK_RESET_SEC then
		stack = 0
	end
	stack = math.clamp(stack + 1, 1, 4)
	lastCoralBounceAt = now
	bounceLockUntil = now + BOUNCE_LOCK_SEC
	local vel = hrp.AssemblyLinearVelocity
	hrp.AssemblyLinearVelocity = Vector3.new(vel.X, bounceSpeed(stack), vel.Z)
	hum:ChangeState(Enum.HumanoidStateType.Jumping)
end

local function bindHumanoid(hum: Humanoid, hrp: BasePart)
	table.insert(
		charConns,
		hum.StateChanged:Connect(function(old, new)
			if new == Enum.HumanoidStateType.Landed then
				if old == Enum.HumanoidStateType.Freefall or old == Enum.HumanoidStateType.Jumping then
					tryBounce(hum, hrp, true)
				end
			elseif new == Enum.HumanoidStateType.Jumping then
				tryBounce(hum, hrp, false)
			elseif new == Enum.HumanoidStateType.Landed or new == Enum.HumanoidStateType.Running then
				if os.clock() >= bounceLockUntil and not floorCoral(hrp) then
					stack = 0
				end
			end
		end)
	)
end

local function clearCharConns()
	for _, c in ipairs(charConns) do
		c:Disconnect()
	end
	table.clear(charConns)
	stack = 0
end

local function onCharacter(char: Model)
	clearCharConns()
	local hum = char:WaitForChild("Humanoid", 8)
	local hrp = char:WaitForChild("HumanoidRootPart", 8)
	if not (hum and hum:IsA("Humanoid") and hrp and hrp:IsA("BasePart")) then
		return
	end
	bindHumanoid(hum, hrp)
end

if player.Character then
	task.spawn(onCharacter, player.Character)
end
player.CharacterAdded:Connect(onCharacter)

-- Keep stack fresh while chaining corals in the air (don't reset mid-arc).
RunService.Heartbeat:Connect(function()
	if stack <= 0 then
		return
	end
	if os.clock() - lastCoralBounceAt > STACK_RESET_SEC then
		stack = 0
	end
end)

return {}
