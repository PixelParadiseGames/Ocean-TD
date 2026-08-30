--!strict
--[[
	Aim screen-space helpers for PlacementController (register budget).
]]

local GuiService = game:GetService("GuiService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local PlaceAimScreen = {}

local GHOST_SCREEN_OFFSET_Y = 32 -- was 105; 70% less raise above finger
local touchHeld = 0

function PlaceAimScreen.trackTouch(input: InputObject, ended: boolean)
	if input.UserInputType ~= Enum.UserInputType.Touch then
		return
	end
	if ended then
		touchHeld = math.max(0, touchHeld - 1)
	else
		touchHeld += 1
	end
end

function PlaceAimScreen.touchHeld(): boolean
	return touchHeld > 0
end

-- Roblox synthesizes MouseButton1 / MouseMovement while a finger is down.
function PlaceAimScreen.isEmulatedMouse(input: InputObject): boolean
	if touchHeld <= 0 then
		return false
	end
	local t = input.UserInputType
	return t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.MouseMovement
end

function PlaceAimScreen.notePointer(input: InputObject, state: { raiseForTouch: boolean, gamepadPlacement: boolean })
	if PlaceAimScreen.isEmulatedMouse(input) then
		return
	end
	if input.UserInputType == Enum.UserInputType.Touch then
		state.raiseForTouch = true
	elseif input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.MouseButton2
		or input.UserInputType == Enum.UserInputType.MouseMovement
		or input.UserInputType == Enum.UserInputType.MouseWheel
	then
		state.raiseForTouch = false
	elseif input.UserInputType == Enum.UserInputType.Gamepad1 or input.KeyCode == Enum.KeyCode.Thumbstick1 then
		state.raiseForTouch = false
	end
end

function PlaceAimScreen.shouldRaiseGhost(raiseForTouch: boolean, gamepadPlacement: boolean): boolean
	if gamepadPlacement then
		return false
	end
	-- Live finger only — never treat sticky LastInputType Touch as touch aim on PC mouse.
	if touchHeld > 0 then
		return true
	end
	-- Touch release frame: aimRaiseForTouch still set before InputEnded clears it.
	return raiseForTouch
end

function PlaceAimScreen.raiseIfTouch(pos: Vector2, raiseForTouch: boolean, gamepadPlacement: boolean): Vector2
	if PlaceAimScreen.shouldRaiseGhost(raiseForTouch, gamepadPlacement) then
		return Vector2.new(pos.X, pos.Y - GHOST_SCREEN_OFFSET_Y)
	end
	return pos
end

function PlaceAimScreen.isTouchAim(raiseForTouch: boolean, gamepadPlacement: boolean): boolean
	if gamepadPlacement then
		return false
	end
	-- Billboard + raised raycasts only while a finger is actually down.
	return touchHeld > 0
end

function PlaceAimScreen.getAimPos(gamepadPlacement: boolean, gamepadCursor: Vector2?, aimPinnedToCenter: boolean): Vector2
	if gamepadPlacement and gamepadCursor then
		return gamepadCursor
	end
	if aimPinnedToCenter then
		local cam = Workspace.CurrentCamera
		if cam then
			local inset = GuiService:GetGuiInset()
			local vp = cam.ViewportSize
			return Vector2.new(vp.X * 0.5 + inset.X, vp.Y * 0.5 + inset.Y)
		end
	end
	return UserInputService:GetMouseLocation()
end

function PlaceAimScreen.getPlaceAimPos(
	gamepadPlacement: boolean,
	gamepadCursor: Vector2?,
	aimPinnedToCenter: boolean,
	raiseForTouch: boolean
): Vector2
	local finger = PlaceAimScreen.getAimPos(gamepadPlacement, gamepadCursor, aimPinnedToCenter)
	if gamepadPlacement then
		return finger
	end
	-- Touch only: raise so the ghost isn't covered by the finger.
	-- Mouse / pen / keyboard: exact cursor (never the touch raise).
	if PlaceAimScreen.shouldRaiseGhost(raiseForTouch, gamepadPlacement) then
		return Vector2.new(finger.X, finger.Y - GHOST_SCREEN_OFFSET_Y)
	end
	return finger
end

function PlaceAimScreen.resetGamepadCursor(): Vector2
	local cam = Workspace.CurrentCamera
	if cam then
		local inset = GuiService:GetGuiInset()
		local vp = cam.ViewportSize
		return Vector2.new(vp.X * 0.5 + inset.X, vp.Y * 0.5 + inset.Y)
	end
	return UserInputService:GetMouseLocation()
end

function PlaceAimScreen.readThumbstick1(): Vector2
	local ok, states = pcall(function()
		return UserInputService:GetGamepadState(Enum.UserInputType.Gamepad1)
	end)
	if not ok or typeof(states) ~= "table" then
		return Vector2.zero
	end
	for _, input in ipairs(states :: { InputObject }) do
		if input.KeyCode == Enum.KeyCode.Thumbstick1 then
			return Vector2.new(input.Position.X, -input.Position.Y)
		end
	end
	return Vector2.zero
end

function PlaceAimScreen.clampGamepadCursor(pos: Vector2): Vector2
	local cam = Workspace.CurrentCamera
	if not cam then
		return pos
	end
	local inset = GuiService:GetGuiInset()
	local vp = cam.ViewportSize
	local minX = inset.X + 8
	local maxX = inset.X + vp.X - 8
	local minY = inset.Y + 8
	local maxY = inset.Y + vp.Y - 8
	return Vector2.new(math.clamp(pos.X, minX, maxX), math.clamp(pos.Y, minY, maxY))
end

return PlaceAimScreen
