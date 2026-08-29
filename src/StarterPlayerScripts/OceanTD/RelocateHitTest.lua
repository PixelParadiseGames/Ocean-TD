--!strict
--[[
	Relocate chrome / move-icon hit tests (chunked out for Luau local-register limit).
]]

local GuiService = game:GetService("GuiService")

local PlaceConfirmHitTest = require(script.Parent:WaitForChild("PlaceConfirmHitTest"))

local RelocateHitTest = {}

export type ChromeRefs = {
	playerGui: PlayerGui,
	checkBtn: TextButton?,
	cancelBtn: TextButton?,
	rotLeftBtn: ImageButton?,
	rotRightBtn: ImageButton?,
	recycleBtn: TextButton?,
	moveIcon: ImageLabel?,
	moveBillboard: BillboardGui?,
	chromeBtnDown: boolean,
}

function RelocateHitTest.guiObjectHit(obj: GuiObject?, screenPos: Vector2, pad: number): boolean
	if not obj or not obj.Visible then
		return false
	end
	local p = obj.AbsolutePosition
	local s = obj.AbsoluteSize
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

function RelocateHitTest.isOverMoveIcon(refs: ChromeRefs, screenPos: Vector2): boolean
	local moveBillboard = refs.moveBillboard
	local moveIcon = refs.moveIcon
	if moveBillboard and not moveBillboard.Enabled then
		return false
	end
	if RelocateHitTest.guiObjectHit(moveIcon, screenPos, 10) then
		return true
	end
	local playerGui = refs.playerGui
	local function probe(x: number, y: number): boolean
		local ok, objs = pcall(function()
			return playerGui:GetGuiObjectsAtPosition(x, y)
		end)
		if not ok or typeof(objs) ~= "table" then
			return false
		end
		for _, obj in ipairs(objs) do
			if obj == moveIcon then
				return true
			end
			if moveBillboard and (obj == moveBillboard or obj:IsDescendantOf(moveBillboard)) then
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

function RelocateHitTest.isOverChrome(refs: ChromeRefs, screenPos: Vector2): boolean
	if refs.chromeBtnDown then
		return true
	end
	if PlaceConfirmHitTest.resolveTarget(
			screenPos,
			refs.checkBtn,
			refs.cancelBtn,
			refs.playerGui,
			refs.rotLeftBtn,
			refs.rotRightBtn
		) ~= nil
	then
		return true
	end
	return RelocateHitTest.guiObjectHit(refs.recycleBtn, screenPos, 12)
end

function RelocateHitTest.resolveChrome(refs: ChromeRefs, screenPos: Vector2): string?
	local t = PlaceConfirmHitTest.resolveTarget(
		screenPos,
		refs.checkBtn,
		refs.cancelBtn,
		refs.playerGui,
		refs.rotLeftBtn,
		refs.rotRightBtn
	)
	if t then
		return t
	end
	if RelocateHitTest.guiObjectHit(refs.recycleBtn, screenPos, 12) then
		return "recycle"
	end
	return nil
end

return RelocateHitTest
