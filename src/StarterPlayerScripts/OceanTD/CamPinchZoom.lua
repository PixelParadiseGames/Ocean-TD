--!strict
--[[
	Standard Roblox pinch / pointer zoom input for Scriptable cams.

	Uses UserInputService.TouchPinch (touch) and PointerAction (unified
	wheel/trackpad pinch) — the same APIs PlayerModule / BaseCamera use.
	Does not invent a custom gesture recognizer.

	TouchPinch `scale` is relative to gesture start (1 at Begin), matching
	BaseCamera: newDistance = beginDistance / clamp(scale).

	Also tracks active touch pointers (GetTouches is not available on all
	clients) so place/relocate can abort on multi-touch without that API.
]]

local UserInputService = game:GetService("UserInputService")

export type PinchPhase = "begin" | "change" | "end"
export type PinchHandler = (phase: PinchPhase, scale: number) -> ()
export type DeltaHandler = (pinchDelta: number) -> ()

local CamPinchZoom = {}

local pinchHandler: PinchHandler? = nil
local deltaHandler: DeltaHandler? = nil
local pinchActive = false
-- InputObject → true while that touch is down (no GetTouches dependency).
local activeTouches: { [InputObject]: boolean } = {}
local activeTouchCount = 0

local function noteTouchBegan(input: InputObject)
	if activeTouches[input] then
		return
	end
	activeTouches[input] = true
	activeTouchCount += 1
end

local function noteTouchEnded(input: InputObject)
	if not activeTouches[input] then
		return
	end
	activeTouches[input] = nil
	activeTouchCount = math.max(0, activeTouchCount - 1)
	if activeTouchCount < 2 then
		pinchActive = false
	end
end

function CamPinchZoom.bind(handlers: { onPinch: PinchHandler?, onDelta: DeltaHandler? }?)
	pinchHandler = if handlers then handlers.onPinch else nil
	deltaHandler = if handlers then handlers.onDelta else nil
end

function CamPinchZoom.unbind()
	pinchHandler = nil
	deltaHandler = nil
end

-- True while a touch pinch gesture is in progress (Begin→End/Cancel).
function CamPinchZoom.isActive(): boolean
	return pinchActive
end

function CamPinchZoom.touchCount(): number
	return activeTouchCount
end

-- Pinch gesture or two+ fingers down (place/relocate abort).
function CamPinchZoom.isPinchOrMultiTouch(): boolean
	return pinchActive or activeTouchCount >= 2
end

UserInputService.InputBegan:Connect(function(input: InputObject, _gameProcessed: boolean)
	if input.UserInputType == Enum.UserInputType.Touch then
		noteTouchBegan(input)
	end
end)

UserInputService.InputEnded:Connect(function(input: InputObject, _gameProcessed: boolean)
	if input.UserInputType == Enum.UserInputType.Touch then
		noteTouchEnded(input)
	end
end)

UserInputService.TouchPinch:Connect(function(
	_touchPositions: { any },
	scale: number,
	_velocity: number,
	state: Enum.UserInputState,
	gameProcessed: boolean
)
	-- Track active even when gameProcessed so relocate can abort while UI eats the event.
	if state == Enum.UserInputState.Begin then
		pinchActive = true
	elseif state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
		pinchActive = false
	end
	-- Some devices skip End/Cancel — clear when only one finger remains.
	if activeTouchCount < 2 then
		pinchActive = false
	end
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
