--!strict
--[[
	Passenger seats on crabs / sharks: ProximityPrompt (E) to ride.
	Client-local wave models break Seat:Sit, so we pin HumanoidRootPart
	(Anchored + Seated) to the seat each frame. Jump to dismount.
	Driver / VehicleSeat stay non-drivable.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local WaveCritterSeats = {}

local ATTR_READY = "OceanTD_PassengerSeatReady"
-- Sit a bit above the seat part so the avatar clears the mesh.
local SIT_OFFSET = CFrame.new(0, 1.35, 0)

local rideSeat: BasePart? = nil
local ridePrompt: ProximityPrompt? = nil
local rideHum: Humanoid? = nil
local rideHrp: BasePart? = nil
local rideConn: RBXScriptConnection? = nil
local jumpConn: RBXScriptConnection? = nil
local diedConn: RBXScriptConnection? = nil
local ancestryConn: RBXScriptConnection? = nil

local function isPassengerSeat(seat: Seat | VehicleSeat): boolean
	local n = string.lower(seat.Name)
	return string.find(n, "passenger", 1, true) ~= nil
end

local function isDriverSeat(seat: Seat | VehicleSeat): boolean
	local n = string.lower(seat.Name)
	return string.find(n, "driver", 1, true) ~= nil
		or seat:IsA("VehicleSeat")
end

local function clearRideConns()
	if rideConn then
		rideConn:Disconnect()
		rideConn = nil
	end
	if jumpConn then
		jumpConn:Disconnect()
		jumpConn = nil
	end
	if diedConn then
		diedConn:Disconnect()
		diedConn = nil
	end
	if ancestryConn then
		ancestryConn:Disconnect()
		ancestryConn = nil
	end
end

local function seatStillInWorld(seat: BasePart): boolean
	-- Pool release sets model.Parent = nil but seat.Parent stays the model — check Workspace.
	return seat:IsDescendantOf(Workspace)
end

function WaveCritterSeats.stopRide()
	local hum = rideHum
	local hrp = rideHrp
	local prompt = ridePrompt
	clearRideConns()
	rideSeat = nil
	ridePrompt = nil
	rideHum = nil
	rideHrp = nil
	if hum and hum.Parent then
		pcall(function()
			hum:SetStateEnabled(Enum.HumanoidStateType.Freefall, true)
			hum:SetStateEnabled(Enum.HumanoidStateType.FallingDown, true)
			hum:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)
		end)
		hum.Sit = false
		hum.PlatformStand = false
		hum.AutoRotate = true
		pcall(function()
			hum:ChangeState(Enum.HumanoidStateType.GettingUp)
		end)
		task.defer(function()
			if hum.Parent and hum.Health > 0 then
				hum.PlatformStand = false
				hum.Sit = false
				hum:ChangeState(Enum.HumanoidStateType.Running)
			end
		end)
	end
	if hrp and hrp.Parent then
		hrp.Anchored = false
		hrp.AssemblyLinearVelocity = Vector3.zero
		hrp.AssemblyAngularVelocity = Vector3.zero
	end
	if prompt and prompt.Parent then
		prompt.Enabled = true
	end
end

-- Call before pooling/destroying a crab or shark so riders aren't left stuck mid-ride.
function WaveCritterSeats.ejectIfRidingModel(model: Instance)
	local seat = rideSeat
	if not seat then
		return
	end
	if seat == model or seat:IsDescendantOf(model) then
		WaveCritterSeats.stopRide()
	end
end

local function startRide(seat: BasePart, prompt: ProximityPrompt)
	local plr = Players.LocalPlayer
	local char = plr and plr.Character
	if not char then
		return
	end
	local hum = char:FindFirstChildOfClass("Humanoid")
	local hrp = char:FindFirstChild("HumanoidRootPart")
	if not (hum and hrp and hrp:IsA("BasePart")) then
		return
	end
	if hum.Health <= 0 then
		return
	end

	-- Already on this seat — ignore.
	if rideSeat == seat and rideHrp == hrp then
		return
	end

	WaveCritterSeats.stopRide()

	rideSeat = seat
	ridePrompt = prompt
	rideHum = hum
	rideHrp = hrp

	prompt.Enabled = false
	-- Anchor + Seated: no freefall anim (PlatformStand looked like constant falling).
	hum.PlatformStand = false
	hum.AutoRotate = false
	hum.Sit = true
	pcall(function()
		hum:SetStateEnabled(Enum.HumanoidStateType.Freefall, false)
		hum:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
		hum:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
		hum:ChangeState(Enum.HumanoidStateType.Seated)
	end)
	hrp.Anchored = true
	hrp.AssemblyLinearVelocity = Vector3.zero
	hrp.AssemblyAngularVelocity = Vector3.zero

	rideConn = RunService.RenderStepped:Connect(function()
		local s = rideSeat
		local root = rideHrp
		local humanoid = rideHum
		if not s or not seatStillInWorld(s) or not root or not root.Parent or not humanoid or humanoid.Health <= 0 then
			WaveCritterSeats.stopRide()
			return
		end
		root.Anchored = true
		root.CFrame = s.CFrame * SIT_OFFSET
		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero
		-- Hold Seated so the default sit pose stays (engine may try Freefall mid-air).
		if humanoid:GetState() ~= Enum.HumanoidStateType.Seated then
			humanoid.Sit = true
			pcall(function()
				humanoid:ChangeState(Enum.HumanoidStateType.Seated)
			end)
		end
	end)

	jumpConn = UserInputService.JumpRequest:Connect(function()
		WaveCritterSeats.stopRide()
	end)

	diedConn = hum.Died:Connect(function()
		WaveCritterSeats.stopRide()
	end)

	ancestryConn = seat.AncestryChanged:Connect(function()
		if not seatStillInWorld(seat) then
			WaveCritterSeats.stopRide()
		end
	end)
end

local function paintSeatInvisible(seat: Seat | VehicleSeat)
	seat.Transparency = 1
	seat.LocalTransparencyModifier = 0
	seat.CastShadow = false
	seat.CanCollide = false
	seat.Massless = true
	-- Block physics Sit — client-local PivotTo models eject Occupant instantly.
	if seat:IsA("VehicleSeat") then
		seat.Disabled = true
		seat.ThrottleFloat = 0
		seat.SteerFloat = 0
	elseif seat:IsA("Seat") then
		-- Seat.Disabled prevents touch-sit; we only use the prompt.
		(seat :: Seat).Disabled = true
	end
end

local function ensurePassengerPrompt(seat: Seat | VehicleSeat)
	paintSeatInvisible(seat)
	seat.CanTouch = false
	seat.CanQuery = true

	if seat:GetAttribute(ATTR_READY) == true then
		local existing = seat:FindFirstChild("OceanTD_RidePrompt")
		if existing and existing:IsA("ProximityPrompt") then
			existing.Enabled = rideSeat ~= seat
			return
		end
	end
	seat:SetAttribute(ATTR_READY, true)

	local existing = seat:FindFirstChild("OceanTD_RidePrompt")
	if existing and not existing:IsA("ProximityPrompt") then
		existing:Destroy()
		existing = nil
	end

	local prompt: ProximityPrompt
	if existing and existing:IsA("ProximityPrompt") then
		prompt = existing
	else
		prompt = Instance.new("ProximityPrompt")
		prompt.Name = "OceanTD_RidePrompt"
		prompt.Parent = seat
		prompt.Triggered:Connect(function(who)
			if who ~= Players.LocalPlayer then
				return
			end
			if rideSeat == seat then
				return
			end
			startRide(seat, prompt)
		end)
	end

	prompt.ActionText = "Ride"
	prompt.ObjectText = "Passenger"
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.GamepadKeyCode = Enum.KeyCode.ButtonX
	prompt.RequiresLineOfSight = false
	prompt.MaxActivationDistance = 14
	prompt.HoldDuration = 0
	prompt.Style = Enum.ProximityPromptStyle.Default
	prompt.Enabled = rideSeat ~= seat
end

local function disableDriveSeat(seat: Seat | VehicleSeat)
	paintSeatInvisible(seat)
	seat.CanTouch = false
	seat.CanQuery = false
	local prompt = seat:FindFirstChild("OceanTD_RidePrompt")
	if prompt then
		prompt:Destroy()
	end
end

-- Keep passenger seats usable; block driving seats.
function WaveCritterSeats.prepareModel(inst: Instance)
	for _, d in ipairs(inst:GetDescendants()) do
		if d:IsA("VehicleSeat") then
			if isPassengerSeat(d) then
				ensurePassengerPrompt(d)
			else
				disableDriveSeat(d)
			end
		elseif d:IsA("Seat") then
			if isPassengerSeat(d) then
				ensurePassengerPrompt(d)
			elseif isDriverSeat(d) then
				disableDriveSeat(d)
			else
				ensurePassengerPrompt(d)
			end
		end
	end
end

function WaveCritterSeats.isRiding(): boolean
	return rideSeat ~= nil
end

return WaveCritterSeats
