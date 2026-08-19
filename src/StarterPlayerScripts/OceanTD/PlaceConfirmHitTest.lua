--!strict
--[[
	Confirm/cancel hit testing for PlacementController.
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

function PlaceConfirmHitTest.resolveTarget(
	screenPos: Vector2,
	checkBtn: GuiObject?,
	cancelBtn: GuiObject?,
	playerGui: PlayerGui
): string?
	-- Round chrome: hit the disc, not a padded square. Extra inset probes used to
	-- treat plot clicks near X as Cancel on PC.
	local function hit(btn: GuiObject?): boolean
		if not btn or not btn.Visible then
			return false
		end
		local p = btn.AbsolutePosition
		local s = btn.AbsoluteSize
		if s.X < 1 or s.Y < 1 then
			return false
		end
		local cx = p.X + s.X * 0.5
		local cy = p.Y + s.Y * 0.5
		local r = math.max(s.X, s.Y) * 0.5
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
	end
	return nil
end

function PlaceConfirmHitTest.isOverGui(screenPos: Vector2, obj: GuiObject?): boolean
	if not obj or not obj.Visible then
		return false
	end
	local p = obj.AbsolutePosition
	local s = obj.AbsoluteSize
	if s.X < 1 or s.Y < 1 then
		return false
	end
	local function inside(x: number, y: number): boolean
		return x >= p.X and x <= p.X + s.X and y >= p.Y and y <= p.Y + s.Y
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
