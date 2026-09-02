--!strict
--[[
	Confirm / cancel / rotate hit testing for place + relocate chrome.
	Simple: engine GetGuiObjectsAtPosition first, then AABB AbsolutePosition.
]]

local GuiService = game:GetService("GuiService")
local UserInputService = game:GetService("UserInputService")

local PlaceConfirmHitTest = {}

function PlaceConfirmHitTest.pointerScreenPos(input: InputObject?): Vector2
	-- Touch Input.Position is GUI space; GetMouseLocation is inset-inclusive.
	if input and input.UserInputType == Enum.UserInputType.Touch then
		local inset = GuiService:GetGuiInset()
		return Vector2.new(input.Position.X + inset.X, input.Position.Y + inset.Y)
	end
	return UserInputService:GetMouseLocation()
end

local function rectHit(btn: GuiObject?, screenPos: Vector2, pad: number): boolean
	if not btn or not btn.Visible then
		return false
	end
	local p = btn.AbsolutePosition
	local s = btn.AbsoluteSize
	if s.X < 1 or s.Y < 1 then
		return false
	end
	local function inside(x: number, y: number): boolean
		return x >= p.X - pad
			and x <= p.X + s.X + pad
			and y >= p.Y - pad
			and y <= p.Y + s.Y + pad
	end
	if inside(screenPos.X, screenPos.Y) then
		return true
	end
	local inset = GuiService:GetGuiInset()
	if inset.X ~= 0 or inset.Y ~= 0 then
		return inside(screenPos.X - inset.X, screenPos.Y - inset.Y)
	end
	return false
end

function PlaceConfirmHitTest.resolveTarget(
	screenPos: Vector2,
	checkBtn: GuiObject?,
	cancelBtn: GuiObject?,
	playerGui: PlayerGui,
	rotLeftBtn: GuiObject?,
	rotRightBtn: GuiObject?
): string?
	local function underChrome(x: number, yPos: number): string?
		local ok, objs = pcall(function()
			return playerGui:GetGuiObjectsAtPosition(x, yPos)
		end)
		if not ok or typeof(objs) ~= "table" then
			return nil
		end
		local sawCheck = false
		local sawCancel = false
		local sawRotL = false
		local sawRotR = false
		for _, obj in ipairs(objs) do
			if checkBtn and checkBtn.Visible and (obj == checkBtn or obj:IsDescendantOf(checkBtn)) then
				sawCheck = true
			elseif cancelBtn and cancelBtn.Visible and (obj == cancelBtn or obj:IsDescendantOf(cancelBtn)) then
				sawCancel = true
			elseif rotLeftBtn and rotLeftBtn.Visible and (obj == rotLeftBtn or obj:IsDescendantOf(rotLeftBtn)) then
				sawRotL = true
			elseif rotRightBtn and rotRightBtn.Visible and (obj == rotRightBtn or obj:IsDescendantOf(rotRightBtn)) then
				sawRotR = true
			end
		end
		-- Confirm wins when overlapping Cancel.
		if sawCheck then
			return "check"
		end
		if sawCancel then
			return "cancel"
		end
		if sawRotL then
			return "rotLeft"
		end
		if sawRotR then
			return "rotRight"
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
	end

	-- AABB fallback (ScreenGui AbsolutePosition). Confirm first.
	if rectHit(checkBtn, screenPos, 6) then
		return "check"
	end
	if rectHit(cancelBtn, screenPos, 6) then
		return "cancel"
	end
	if rectHit(rotLeftBtn, screenPos, 6) then
		return "rotLeft"
	end
	if rectHit(rotRightBtn, screenPos, 6) then
		return "rotRight"
	end
	return nil
end

function PlaceConfirmHitTest.isOverGui(screenPos: Vector2, gui: GuiObject?): boolean
	return rectHit(gui, screenPos, 6)
end

function PlaceConfirmHitTest.isOverChrome(
	screenPos: Vector2,
	checkBtn: GuiObject?,
	cancelBtn: GuiObject?,
	playerGui: PlayerGui,
	rotLeftBtn: GuiObject?,
	rotRightBtn: GuiObject?
): boolean
	return PlaceConfirmHitTest.resolveTarget(screenPos, checkBtn, cancelBtn, playerGui, rotLeftBtn, rotRightBtn) ~= nil
end

return PlaceConfirmHitTest
