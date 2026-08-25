--!strict
--[[
	Confirm/cancel (+ optional SeaFan rotate) hit testing for PlacementController.
	Extracted so PlacementController stays under Luau's 200-local limit.
]]

local GuiService = game:GetService("GuiService")
local UserInputService = game:GetService("UserInputService")

local PlaceConfirmHitTest = {}

function PlaceConfirmHitTest.pointerScreenPos(input: InputObject?): Vector2
	-- Touch Input.Position is GUI space; ScreenPointToRay / GetMouseLocation are inset-inclusive.
	-- Mouse Input.Position already matches GetMouseLocation — adding inset parks the coral below the cursor.
	if input and input.UserInputType == Enum.UserInputType.Touch then
		local inset = GuiService:GetGuiInset()
		return Vector2.new(input.Position.X + inset.X, input.Position.Y + inset.Y)
	end
	return UserInputService:GetMouseLocation()
end

local function btnCenter(btn: GuiObject): (number, number, number)
	local p = btn.AbsolutePosition
	local s = btn.AbsoluteSize
	return p.X + s.X * 0.5, p.Y + s.Y * 0.5, math.max(s.X, s.Y) * 0.5
end

local function discHit(btn: GuiObject?, screenPos: Vector2): boolean
	if not btn or not btn.Visible then
		return false
	end
	local s = btn.AbsoluteSize
	if s.X < 1 or s.Y < 1 then
		return false
	end
	local cx, cy, r = btnCenter(btn)
	local r2 = r * r
	local function inside(x: number, y: number): boolean
		local dx = x - cx
		local dy = y - cy
		return dx * dx + dy * dy <= r2
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

local function twoRowMidY(checkBtn: GuiObject?, rotLeftBtn: GuiObject?): number?
	if not checkBtn or not checkBtn.Visible or not rotLeftBtn or not rotLeftBtn.Visible then
		return nil
	end
	if checkBtn.AbsoluteSize.Y < 1 or rotLeftBtn.AbsoluteSize.Y < 1 then
		return nil
	end
	local _, checkCy = btnCenter(checkBtn)
	local _, rotCy = btnCenter(rotLeftBtn)
	return (checkCy + rotCy) * 0.5
end

function PlaceConfirmHitTest.resolveTarget(
	screenPos: Vector2,
	checkBtn: GuiObject?,
	cancelBtn: GuiObject?,
	playerGui: PlayerGui,
	rotLeftBtn: GuiObject?,
	rotRightBtn: GuiObject?
): string?
	local y = screenPos.Y
	local inset = GuiService:GetGuiInset()
	local yAlt = y - inset.Y

	-- Two-row chrome: hard split by Y so rot never steals Confirm/Cancel.
	local midY = twoRowMidY(checkBtn, rotLeftBtn)
	if midY then
		local onTop = y < midY or yAlt < midY
		if onTop then
			if discHit(checkBtn, screenPos) then
				return "check"
			end
			if discHit(cancelBtn, screenPos) then
				return "cancel"
			end
			-- Pointer in top band but outside discs: still not rot.
			return nil
		end
		-- Bottom band: only rotate.
		if discHit(rotLeftBtn, screenPos) then
			return "rotLeft"
		end
		if discHit(rotRightBtn, screenPos) then
			return "rotRight"
		end
		return nil
	end

	-- Single row (or Close-only + rot sides).
	if discHit(checkBtn, screenPos) then
		return "check"
	end
	if discHit(cancelBtn, screenPos) then
		return "cancel"
	end
	if discHit(rotLeftBtn, screenPos) then
		return "rotLeft"
	end
	if discHit(rotRightBtn, screenPos) then
		return "rotRight"
	end

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
	if inset.X ~= 0 or inset.Y ~= 0 then
		return underChrome(screenPos.X - inset.X, screenPos.Y - inset.Y)
	end
	return nil
end

function PlaceConfirmHitTest.isOverGui(screenPos: Vector2, gui: GuiObject?): boolean
	if not gui or not gui.Visible then
		return false
	end
	return discHit(gui, screenPos)
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
