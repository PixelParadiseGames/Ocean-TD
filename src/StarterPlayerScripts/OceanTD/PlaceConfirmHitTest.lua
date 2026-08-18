--!strict
--[[
	Confirm/cancel hit testing for PlacementController.
	Extracted so PlacementController stays under Luau's 200-local limit.
]]

local GuiService = game:GetService("GuiService")
local UserInputService = game:GetService("UserInputService")

local PlaceConfirmHitTest = {}

function PlaceConfirmHitTest.pointerScreenPos(input: InputObject?): Vector2
	-- GetMouseLocation stays on the backpack tap during a follow-up touch, so ✓ never parked.
	-- Touch / mouse Input.Position is GUI space; ScreenPointToRay wants inset-inclusive.
	if input then
		local t = input.UserInputType
		if t == Enum.UserInputType.Touch
			or t == Enum.UserInputType.MouseButton1
			or t == Enum.UserInputType.MouseMovement
		then
			local inset = GuiService:GetGuiInset()
			return Vector2.new(input.Position.X + inset.X, input.Position.Y + inset.Y)
		end
	end
	return UserInputService:GetMouseLocation()
end

function PlaceConfirmHitTest.resolveTarget(
	screenPos: Vector2,
	checkBtn: GuiObject?,
	cancelBtn: GuiObject?,
	playerGui: PlayerGui
): string?
	local function hit(btn: GuiObject?): boolean
		if not btn or not btn.Visible then
			return false
		end
		local p = btn.AbsolutePosition
		local s = btn.AbsoluteSize
		local pad = 18
		local inset = GuiService:GetGuiInset()
		local x = screenPos.X - inset.X
		local y = screenPos.Y - inset.Y
		if x >= p.X - pad and x <= p.X + s.X + pad and y >= p.Y - pad and y <= p.Y + s.Y + pad then
			return true
		end
		return screenPos.X >= p.X - pad
			and screenPos.X <= p.X + s.X + pad
			and screenPos.Y >= p.Y - pad
			and screenPos.Y <= p.Y + s.Y + pad
	end
	if hit(checkBtn) then
		return "check"
	end
	if hit(cancelBtn) then
		return "cancel"
	end
	local function underChrome(x: number, y: number): string?
		local ok, objs = pcall(function()
			return playerGui:GetGuiObjectsAtPosition(x, y)
		end)
		if not ok or typeof(objs) ~= "table" then
			return nil
		end
		for _, obj in ipairs(objs) do
			if checkBtn and checkBtn.Visible and (obj == checkBtn or obj:IsDescendantOf(checkBtn)) then
				return "check"
			end
			if cancelBtn and (obj == cancelBtn or obj:IsDescendantOf(cancelBtn)) then
				return "cancel"
			end
		end
		return nil
	end
	local hitTarget = underChrome(screenPos.X, screenPos.Y)
	if hitTarget then
		return hitTarget
	end
	local inset = GuiService:GetGuiInset()
	if inset.X ~= 0 or inset.Y ~= 0 then
		hitTarget = underChrome(screenPos.X - inset.X, screenPos.Y - inset.Y)
		if hitTarget then
			return hitTarget
		end
		hitTarget = underChrome(screenPos.X + inset.X, screenPos.Y + inset.Y)
		if hitTarget then
			return hitTarget
		end
	end
	return nil
end

function PlaceConfirmHitTest.isOver(
	screenPos: Vector2,
	chromeBtnPointerDown: boolean,
	checkBtn: GuiObject?,
	cancelBtn: GuiObject?,
	playerGui: PlayerGui
): boolean
	if chromeBtnPointerDown then
		return true
	end
	return PlaceConfirmHitTest.resolveTarget(screenPos, checkBtn, cancelBtn, playerGui) ~= nil
end

return PlaceConfirmHitTest
