--!strict
--[[
	Haptic helpers for phones + gamepads.
	Prefers HapticEffect (mobile + modern pads); falls back to HapticService motors.
]]

local HapticService = game:GetService("HapticService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local UiHaptics = {}

local gen = 0
local activeEffect: Instance? = nil
local hapticEffectOk: boolean? = nil

local function supportsHapticEffect(): boolean
	if hapticEffectOk ~= nil then
		return hapticEffectOk
	end
	local ok, inst = pcall(function()
		return Instance.new("HapticEffect")
	end)
	if ok and inst then
		inst:Destroy()
		hapticEffectOk = true
	else
		hapticEffectOk = false
	end
	return hapticEffectOk == true
end

local function key(tMs: number, intensity: number): any
	return FloatCurveKey.new(tMs, math.clamp(intensity, 0, 1), Enum.KeyInterpolationMode.Linear)
end

local function stopActiveEffect()
	local e = activeEffect
	activeEffect = nil
	if not e then
		return
	end
	pcall(function()
		(e :: any):Stop()
	end)
	pcall(function()
		e:Destroy()
	end)
end

local function playCustom(keys: { any }): boolean
	if not supportsHapticEffect() then
		return false
	end
	stopActiveEffect()
	local ok, effect = pcall(function()
		local e = Instance.new("HapticEffect")
		e.Type = Enum.HapticEffectType.Custom
		e.Looped = false
		e.Parent = Workspace
		;(e :: any):SetWaveformKeys(keys)
		return e
	end)
	if not ok or not effect then
		return false
	end
	activeEffect = effect
	local playOk = pcall(function()
		(effect :: any):Play()
	end)
	if not playOk then
		stopActiveEffect()
		return false
	end
	local ended = (effect :: any).Ended
	if typeof(ended) == "RBXScriptSignal" then
		ended:Once(function()
			if activeEffect == effect then
				activeEffect = nil
			end
			pcall(function()
				effect:Destroy()
			end)
		end)
	end
	return true
end

local function activeGamepad(): Enum.UserInputType?
	local last = UserInputService:GetLastInputType()
	if last == Enum.UserInputType.Gamepad1
		or last == Enum.UserInputType.Gamepad2
		or last == Enum.UserInputType.Gamepad3
		or last == Enum.UserInputType.Gamepad4
	then
		return last
	end
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

local function bumpPad(pad: Enum.UserInputType, intensity: number, onSec: number, my: number)
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

local function runPadPulse(fn: (Enum.UserInputType, number) -> ())
	local pad = activeGamepad()
	if not pad then
		return
	end
	local my = gen
	task.spawn(function()
		fn(pad, my)
	end)
end

function UiHaptics.cancel()
	gen += 1
	stopActiveEffect()
	local pad = activeGamepad()
	if pad then
		stopAll(pad)
	end
end

function UiHaptics.pulseShort()
	gen += 1
	if playCustom({
		key(0, 0.55),
		key(100, 0.55),
		key(110, 0),
	}) then
		return
	end
	runPadPulse(function(pad, my)
		bumpPad(pad, 0.55, 0.1, my)
	end)
end

-- Two quick taps (e.g. ROLL press).
function UiHaptics.pulseDouble()
	gen += 1
	if playCustom({
		key(0, 0.55),
		key(70, 0.55),
		key(80, 0),
		key(140, 0),
		key(150, 0.55),
		key(220, 0.55),
		key(230, 0),
	}) then
		return
	end
	runPadPulse(function(pad, my)
		for i = 1, 2 do
			if my ~= gen then
				return
			end
			bumpPad(pad, 0.5, 0.07, my)
			if i < 2 then
				task.wait(0.06)
			end
		end
	end)
end

-- Sustained buzz (e.g. ROLL hold → auto-roll).
function UiHaptics.pulseLong()
	gen += 1
	if playCustom({
		key(0, 0.7),
		key(420, 0.7),
		key(450, 0),
	}) then
		return
	end
	runPadPulse(function(pad, my)
		bumpPad(pad, 0.7, 0.42, my)
	end)
end

-- Soft single tick (e.g. wheel lands).
function UiHaptics.pulseTiny()
	gen += 1
	if playCustom({
		key(0, 0.28),
		key(60, 0.28),
		key(70, 0),
	}) then
		return
	end
	runPadPulse(function(pad, my)
		bumpPad(pad, 0.28, 0.06, my)
	end)
end

function UiHaptics.pulseReef()
	gen += 1
	if playCustom({
		key(0, 0.75),
		key(80, 0.75),
		key(90, 0),
	}) then
		return
	end
	runPadPulse(function(pad, my)
		bumpPad(pad, 0.75, 0.08, my)
	end)
end

function UiHaptics.pulseTriple()
	gen += 1
	if playCustom({
		key(0, 0.65),
		key(120, 0.65),
		key(130, 0),
		key(230, 0),
		key(240, 0.65),
		key(360, 0.65),
		key(370, 0),
		key(470, 0),
		key(480, 0.65),
		key(600, 0.65),
		key(610, 0),
	}) then
		return
	end
	runPadPulse(function(pad, my)
		for i = 1, 3 do
			if my ~= gen then
				return
			end
			bumpPad(pad, 0.65, 0.12, my)
			if i < 3 then
				task.wait(0.1)
			end
		end
	end)
end

-- Soft → medium rise (e.g. seed sliding to backpack).
function UiHaptics.rampSmallToMed(durationSec: number?)
	gen += 1
	local dur = math.max(0.05, durationSec or 1)
	local durMs = math.floor(dur * 1000 + 0.5)
	if playCustom({
		key(0, 0.22),
		key(durMs, 0.58),
		key(durMs + 40, 0),
	}) then
		return
	end
	local lo, hi = 0.22, 0.58
	runPadPulse(function(pad, my)
		local t0 = os.clock()
		while my == gen do
			local u = math.clamp((os.clock() - t0) / dur, 0, 1)
			setMotor(pad, lo + (hi - lo) * u)
			if u >= 1 then
				task.wait(0.04)
				if my == gen then
					stopAll(pad)
				end
				return
			end
			task.wait(0.03)
		end
	end)
end

function UiHaptics.rampOpen(durationSec: number?)
	gen += 1
	local dur = math.max(0.05, durationSec or 1)
	local durMs = math.floor(dur * 1000 + 0.5)
	if playCustom({
		key(0, 0),
		key(durMs, 1),
		key(durMs + 50, 0),
	}) then
		return
	end
	runPadPulse(function(pad, my)
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
	gen += 1
	local dur = math.max(0.05, durationSec or 1)
	local durMs = math.floor(dur * 1000 + 0.5)
	if playCustom({
		key(0, 1),
		key(durMs, 0),
	}) then
		return
	end
	runPadPulse(function(pad, my)
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
