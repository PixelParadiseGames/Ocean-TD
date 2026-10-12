--!strict
--[[
	Standard Roblox pinch / pointer zoom input for Scriptable cams.

	Uses UserInputService.TouchPinch (touch) and PointerAction (unified
	wheel/trackpad pinch) — the same APIs PlayerModule / BaseCamera use.
	Does not invent a custom gesture recognizer.

	TouchPinch `scale` is relative to gesture start (1 at Begin), matching
	BaseCamera: newDistance = beginDistance / clamp(scale).
]]

local UserInputService = game:GetService("UserInputService")

export type PinchPhase = "begin" | "change" | "end"
export type PinchHandler = (phase: PinchPhase, scale: number) -> ()
export type DeltaHandler = (pinchDelta: number) -> ()

local CamPinchZoom = {}

local pinchHandler: PinchHandler? = nil
local deltaHandler: DeltaHandler? = nil

function CamPinchZoom.bind(handlers: { onPinch: PinchHandler?, onDelta: DeltaHandler? }?)
	pinchHandler = if handlers then handlers.onPinch else nil
	deltaHandler = if handlers then handlers.onDelta else nil
end

function CamPinchZoom.unbind()
	pinchHandler = nil
	deltaHandler = nil
end

UserInputService.TouchPinch:Connect(function(
	_touchPositions: { any },
	scale: number,
	_velocity: number,
	state: Enum.UserInputState,
	gameProcessed: boolean
)
	if gameProcessed then
		return
	end
	local fn = pinchHandler
	if not fn then
		return
	end
	if typeof(scale) ~= "number" or scale ~= scale or scale <= 0 then
		return
	end
	if state == Enum.UserInputState.Begin then
		fn("begin", 1)
	elseif state == Enum.UserInputState.Change then
		fn("change", scale)
	elseif state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
		fn("end", scale)
	end
end)

-- Trackpad / unified pointer pinch (same backend as modern camera scripts).
UserInputService.PointerAction:Connect(function(
	_wheel: number,
	_pan: Vector2,
	pinch: number,
	gameProcessed: boolean
)
	if gameProcessed then
		return
	end
	if typeof(pinch) ~= "number" or pinch ~= pinch or pinch == 0 then
		return
	end
	local fn = deltaHandler
	if fn then
		fn(pinch)
	end
end)

return CamPinchZoom
