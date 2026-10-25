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
local touchGraceUntil = 0 -- ignore synthesized mouse briefly after last touch ends
-- Studio's gamepad emulator fires InputChanged and often leaves GetGamepadState at zero.
-- This is the same Thumbstick position that used to pan the plot camera.
local liveStick1 = Vector2.zero
local liveStick2 = Vector2.zero

UserInputService.InputChanged:Connect(function(input)
	if input.KeyCode == Enum.KeyCode.Thumbstick1 then
		liveStick1 = Vector2.new(input.Position.X, input.Position.Y)
	elseif input.KeyCode == Enum.KeyCode.Thumbstick2 then
		liveStick2 = Vector2.new(input.Position.X, input.Position.Y)
	end
end)

function PlaceAimScreen.trackTouch(input: InputObject, ended: boolean)
	if input.UserInputType ~= Enum.UserInputType.Touch then
		return
	end
	if ended then
		touchHeld = math.max(0, touchHeld - 1)
		-- Emulated MouseButton1 often fires after Touch ends; keep filtering it briefly.
		touchGraceUntil = os.clock() + 0.2
	else
		touchHeld += 1
	end
end

function PlaceAimScreen.touchHeld(): boolean
	return touchHeld > 0
end

-- Roblox synthesizes MouseButton1 / MouseMovement while a finger is down (and right after).
function PlaceAimScreen.isEmulatedMouse(input: InputObject): boolean
	local t = input.UserInputType
	if t ~= Enum.UserInputType.MouseButton1 and t ~= Enum.UserInputType.MouseMovement then
		return false
	end
	return touchHeld > 0 or os.clock() < touchGraceUntil
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
	-- Live finger only.
	if touchHeld > 0 then
		return true
	end
	-- Release-park grace: only while LastInputType is still Touch (never sticky after mouse).
	return raiseForTouch == true and UserInputService:GetLastInputType() == Enum.UserInputType.Touch
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

local function strongestStick(code: Enum.KeyCode, cached: Vector2): Vector2
	local bestX, bestY = cached.X, cached.Y
	local bestMag = cached.Magnitude
	local pads: { Enum.UserInputType } = { Enum.UserInputType.Gamepad1 }
	local okPads, connected = pcall(function()
		return UserInputService:GetConnectedGamepads()
	end)
	if okPads and typeof(connected) == "table" and #connected > 0 then
		pads = connected
	end
	for _, pad in pads do
		local ok, states = pcall(function()
			return UserInputService:GetGamepadState(pad)
		end)
		if ok and typeof(states) == "table" then
			for _, input in ipairs(states :: { InputObject }) do
				if input.KeyCode == code then
					local mag = Vector2.new(input.Position.X, input.Position.Y).Magnitude
					if mag > bestMag then
						bestX = input.Position.X
						bestY = input.Position.Y
						bestMag = mag
					end
				end
			end
		end
	end
	return Vector2.new(bestX, bestY)
end

-- Raw stick from InputChanged (Y+ is up). Used when GetGamepadState stays at zero.
function PlaceAimScreen.liveStick1(): Vector2
	return liveStick1
end

function PlaceAimScreen.liveStick2(): Vector2
	return liveStick2
end

-- Hardware state only. Near-zero while the Studio emulator is the thing actually moving.
function PlaceAimScreen.stateStick(code: Enum.KeyCode): Vector2
	return strongestStick(code, Vector2.zero)
end

function PlaceAimScreen.readThumbstick2(): Vector2
	return strongestStick(Enum.KeyCode.Thumbstick2, liveStick2)
end

function PlaceAimScreen.readThumbstick1(): Vector2
	-- Y+ on the stick is up; screen Y+ is down.
	local stick = strongestStick(Enum.KeyCode.Thumbstick1, liveStick1)
	return Vector2.new(stick.X, -stick.Y)
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
