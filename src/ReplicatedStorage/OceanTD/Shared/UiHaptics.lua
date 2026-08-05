--!strict
--[[
	Gamepad haptic helpers. No-ops when no supported motor is available.
]]

local HapticService = game:GetService("HapticService")
local UserInputService = game:GetService("UserInputService")

local UiHaptics = {}

local gen = 0

local function activeGamepad(): Enum.UserInputType?
	local last = UserInputService:GetLastInputType()
	if last == Enum.UserInputType.Gamepad1
		or last == Enum.UserInputType.Gamepad2
		or last == Enum.UserInputType.Gamepad3
		or last == Enum.UserInputType.Gamepad4
	then
		return last
	end
	-- Prefer any connected pad if last input wasn't gamepad.
	for _, t in ipairs({
		Enum.UserInputType.Gamepad1,
		Enum.UserInputType.Gamepad2,
		Enum.UserInputType.Gamepad3,
		Enum.UserInputType.Gamepad4,
	}) do
		if UserInputService:GetGamepadConnected(t) then
			return t
		end
	end
	return nil
end

local function setMotor(pad: Enum.UserInputType, intensity: number)
	local v = math.clamp(intensity, 0, 1)
	pcall(function()
		if HapticService:IsMotorSupported(pad, Enum.VibrationMotor.Large) then
			HapticService:SetMotor(pad, Enum.VibrationMotor.Large, v)
		elseif HapticService:IsMotorSupported(pad, Enum.VibrationMotor.Small) then
			HapticService:SetMotor(pad, Enum.VibrationMotor.Small, v)
		end
	end)
end

local function stopAll(pad: Enum.UserInputType)
	pcall(function()
		if HapticService:IsMotorSupported(pad, Enum.VibrationMotor.Large) then
			HapticService:SetMotor(pad, Enum.VibrationMotor.Large, 0)
		end
		if HapticService:IsMotorSupported(pad, Enum.VibrationMotor.Small) then
			HapticService:SetMotor(pad, Enum.VibrationMotor.Small, 0)
		end
	end)
end

local function bump(pad: Enum.UserInputType, intensity: number, onSec: number, my: number)
	if my ~= gen then
		return
	end
	setMotor(pad, intensity)
	task.wait(onSec)
	if my ~= gen then
		return
	end
	stopAll(pad)
end

function UiHaptics.cancel()
	gen += 1
	local pad = activeGamepad()
	if pad then
		stopAll(pad)
	end
end

function UiHaptics.pulseShort()
	local pad = activeGamepad()
	if not pad then
		return
	end
	gen += 1
	local my = gen
	task.spawn(function()
		bump(pad, 0.55, 0.1, my)
	end)
end

function UiHaptics.pulseReef()
	local pad = activeGamepad()
	if not pad then
		return
	end
	gen += 1
	local my = gen
	task.spawn(function()
		bump(pad, 0.75, 0.08, my)
	end)
end

function UiHaptics.pulseTriple()
	local pad = activeGamepad()
	if not pad then
		return
	end
	gen += 1
	local my = gen
	task.spawn(function()
		for i = 1, 3 do
			if my ~= gen then
				return
			end
			bump(pad, 0.65, 0.12, my)
			if i < 3 then
				task.wait(0.1)
			end
		end
	end)
end

function UiHaptics.rampOpen(durationSec: number?)
	local pad = activeGamepad()
	if not pad then
		return
	end
	local dur = durationSec or 1
	gen += 1
	local my = gen
	task.spawn(function()
		local t0 = os.clock()
		while my == gen do
			local u = (os.clock() - t0) / dur
			if u >= 1 then
				setMotor(pad, 1)
				task.wait(0.05)
				if my == gen then
					stopAll(pad)
				end
				return
			end
			setMotor(pad, u)
			task.wait(0.03)
		end
	end)
end

function UiHaptics.rampClose(durationSec: number?)
	local pad = activeGamepad()
	if not pad then
		return
	end
	local dur = durationSec or 1
	gen += 1
	local my = gen
	task.spawn(function()
		local t0 = os.clock()
		while my == gen do
			local u = (os.clock() - t0) / dur
			if u >= 1 then
				stopAll(pad)
				return
			end
			setMotor(pad, 1 - u)
			task.wait(0.03)
		end
	end)
end

return UiHaptics
