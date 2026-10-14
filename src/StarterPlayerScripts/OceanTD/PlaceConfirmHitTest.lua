--!strict
--[[
	Confirm / cancel / rotate hit testing for place + relocate chrome.
	Engine GetGuiObjectsAtPosition first, then circular disc (buttons are round —
	AABB falsely claims Cancel when dragging a coral near the X).
	If another HUD button is under the pointer (PlotCam zoom +/-), skip the
	AbsolutePosition disc fallback so placement doesn't steal those presses.
]]

local GuiService = game:GetService("GuiService")
local UserInputService = game:GetService("UserInputService")

local PlaceConfirmHitTest = {}

-- Keep disc hits tight so "near Cancel" can still drag the coral.
local DISC_SLOP_PX = 2

function PlaceConfirmHitTest.pointerScreenPos(input: InputObject?): Vector2
	-- Touch Input.Position is GUI space; GetMouseLocation is inset-inclusive.
	if input and input.UserInputType == Enum.UserInputType.Touch then
		local inset = GuiService:GetGuiInset()
		return Vector2.new(input.Position.X + inset.X, input.Position.Y + inset.Y)
	end
	return UserInputService:GetMouseLocation()
end

local function circleHit(btn: GuiObject?, screenPos: Vector2, slop: number): boolean
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
	local r = math.min(s.X, s.Y) * 0.5 + slop
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

function PlaceConfirmHitTest.isOverDisc(screenPos: Vector2, btn: GuiObject?, slop: number?): boolean
	return circleHit(btn, screenPos, if typeof(slop) == "number" then slop else DISC_SLOP_PX)
end

-- PlotCam/FishCam zoom pads, backpack, etc. Placement ignores gameProcessed, so
-- AbsolutePosition disc fallback must not steal those presses as Cancel/Rotate.
local function pointerAbsorber(obj: GuiObject): GuiObject?
	local cur: Instance? = obj
	while cur and cur:IsA("GuiObject") do
		local g = cur :: GuiObject
		if g:IsA("GuiButton") or g:IsA("TextBox") then
			if g.Active and g.Visible then
				return g
			end
			return nil
		end
		cur = cur.Parent
	end
	return nil
end

local function isChromeBtn(obj: GuiObject, btn: GuiObject?): boolean
	return btn ~= nil and btn.Visible and (obj == btn or obj:IsDescendantOf(btn))
end

function PlaceConfirmHitTest.resolveTarget(
	screenPos: Vector2,
	checkBtn: GuiObject?,
	cancelBtn: GuiObject?,
	playerGui: PlayerGui,
	rotLeftBtn: GuiObject?,
	rotRightBtn: GuiObject?
): string?
	-- otherHud: non-chrome button under the pointer (zoom +/-, yaw, …).
	-- When set, skip Billboard AbsolutePosition disc fallback — it is often wrong
	-- and was mapping PlotCam zoom presses onto Cancel / Rotate.
	local otherHud = false

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
			if not obj:IsA("GuiObject") then
				continue
			end
			local g = obj :: GuiObject
			if isChromeBtn(g, checkBtn) then
				sawCheck = true
			elseif isChromeBtn(g, cancelBtn) then
				sawCancel = true
			elseif isChromeBtn(g, rotLeftBtn) then
				sawRotL = true
			elseif isChromeBtn(g, rotRightBtn) then
				sawRotR = true
			else
				local absorber = pointerAbsorber(g)
				if absorber
					and not isChromeBtn(absorber, checkBtn)
					and not isChromeBtn(absorber, cancelBtn)
					and not isChromeBtn(absorber, rotLeftBtn)
					and not isChromeBtn(absorber, rotRightBtn)
				then
					otherHud = true
				end
			end
		end
		-- Confirm wins when overlapping Cancel. Disc check rejects square corner false hits.
		if sawCheck and circleHit(checkBtn, screenPos, DISC_SLOP_PX) then
			return "check"
		end
		if sawCancel and circleHit(cancelBtn, screenPos, DISC_SLOP_PX) then
			return "cancel"
		end
		if sawRotL and circleHit(rotLeftBtn, screenPos, DISC_SLOP_PX) then
			return "rotLeft"
		end
		if sawRotR and circleHit(rotRightBtn, screenPos, DISC_SLOP_PX) then
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

	if otherHud then
		return nil
	end

	-- Disc fallback (ScreenGui AbsolutePosition). Confirm first.
	if circleHit(checkBtn, screenPos, DISC_SLOP_PX) then
		return "check"
	end
	if circleHit(cancelBtn, screenPos, DISC_SLOP_PX) then
		return "cancel"
	end
	if circleHit(rotLeftBtn, screenPos, DISC_SLOP_PX) then
		return "rotLeft"
	end
	if circleHit(rotRightBtn, screenPos, DISC_SLOP_PX) then
		return "rotRight"
	end
	return nil
end

-- True when a non-chrome GuiButton/TextBox is under the pointer (PlotCam zoom, etc.).
function PlaceConfirmHitTest.isOverForeignButton(
	screenPos: Vector2,
	playerGui: PlayerGui,
	checkBtn: GuiObject?,
	cancelBtn: GuiObject?,
	rotLeftBtn: GuiObject?,
	rotRightBtn: GuiObject?
): boolean
	local function probe(x: number, yPos: number): boolean
		local ok, objs = pcall(function()
			return playerGui:GetGuiObjectsAtPosition(x, yPos)
		end)
		if not ok or typeof(objs) ~= "table" then
			return false
		end
		for _, obj in ipairs(objs) do
			if obj:IsA("GuiObject") then
				local absorber = pointerAbsorber(obj :: GuiObject)
				if absorber
					and not isChromeBtn(absorber, checkBtn)
					and not isChromeBtn(absorber, cancelBtn)
					and not isChromeBtn(absorber, rotLeftBtn)
					and not isChromeBtn(absorber, rotRightBtn)
				then
					return true
				end
			end
		end
		return false
	end
	if probe(screenPos.X, screenPos.Y) then
		return true
	end
	local inset = GuiService:GetGuiInset()
	if inset.X ~= 0 or inset.Y ~= 0 then
		return probe(screenPos.X - inset.X, screenPos.Y - inset.Y)
	end
	return false
end

function PlaceConfirmHitTest.isOverGui(screenPos: Vector2, gui: GuiObject?): boolean
	-- Move icon stays rectangular; chrome discs use isOverDisc.
	if not gui or not gui.Visible then
		return false
	end
	local p = gui.AbsolutePosition
	local s = gui.AbsoluteSize
	if s.X < 1 or s.Y < 1 then
		return false
	end
	local pad = 4
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

-- Billboard AbsolutePosition is often wrong — also probe GetGuiObjectsAtPosition (same as Relocate).
-- Chrome GuiButtons share the move Billboard; only the move icon (and non-button BB chrome) counts.
function PlaceConfirmHitTest.isOverMoveHandle(
	screenPos: Vector2,
	playerGui: PlayerGui,
	moveIcon: GuiObject?,
	moveBillboard: BillboardGui?,
	checkBtn: GuiObject?,
	cancelBtn: GuiObject?,
	rotLeftBtn: GuiObject?,
	rotRightBtn: GuiObject?
): boolean
	if moveBillboard and not moveBillboard.Enabled then
		return false
	end
	if not moveIcon or not moveIcon.Visible then
		return false
	end
	if PlaceConfirmHitTest.isOverGui(screenPos, moveIcon) then
		return true
	end
	local function isChrome(obj: Instance): boolean
		return (checkBtn ~= nil and (obj == checkBtn or obj:IsDescendantOf(checkBtn)))
			or (cancelBtn ~= nil and (obj == cancelBtn or obj:IsDescendantOf(cancelBtn)))
			or (rotLeftBtn ~= nil and (obj == rotLeftBtn or obj:IsDescendantOf(rotLeftBtn)))
			or (rotRightBtn ~= nil and (obj == rotRightBtn or obj:IsDescendantOf(rotRightBtn)))
	end
	local function probe(x: number, y: number): boolean
		local ok, objs = pcall(function()
			return playerGui:GetGuiObjectsAtPosition(x, y)
		end)
		if not ok or typeof(objs) ~= "table" then
			return false
		end
		-- Prefer move disc when both move + PLANT/rot sit under the pointer
		-- (Billboard AbsolutePosition often stacks them; chrome-first blocked soft-plant drag).
		for _, obj in ipairs(objs) do
			if obj == moveIcon or obj:IsDescendantOf(moveIcon) then
				return true
			end
		end
		return false
	end
	if probe(screenPos.X, screenPos.Y) then
		return true
	end
	local inset = GuiService:GetGuiInset()
	if inset.X ~= 0 or inset.Y ~= 0 then
		return probe(screenPos.X - inset.X, screenPos.Y - inset.Y)
	end
	return false
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
