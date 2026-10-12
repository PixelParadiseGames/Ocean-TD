--!strict
--[[
	White grow/shrink ring around a coral / ghost so players can see the interact target.
]]

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local oceanShared = ReplicatedStorage:WaitForChild("OceanTD"):WaitForChild("Shared")
local CoralVisual = require(oceanShared:WaitForChild("CoralVisual"))
local UiCircles = require(oceanShared:WaitForChild("UiCircles"))

local SelectRing = {}

local RING_HZ = 3.2
-- Slightly generous so the pulsing ring is easy to grab for drag.
local HIT_SLOP = 1.08

export type Handle = {
	bb: BillboardGui?,
	frame: Frame?,
	stroke: UIStroke?,
	adornee: BasePart?,
}

-- Same plant-point as the green pick disc (terrain contact), not mesh mid-body.
local function plantWorld(adornee: BasePart): Vector3
	return CoralVisual.readGridAnchor(adornee) or adornee.Position
end

local function applyLayout(bb: BillboardGui, adornee: BasePart)
	-- Footprint only — height would grow the ring and float it with tall med/large meshes.
	local diam = math.max(adornee.Size.X, adornee.Size.Z)
	local studs = math.clamp(diam * 1.55, 2.2, 10)
	bb.Size = UDim2.new(studs, 0, studs, 0)
	bb.StudsOffset = Vector3.zero
	bb.StudsOffsetWorldSpace = plantWorld(adornee) - adornee.Position
end

function SelectRing.new(): Handle
	return {
		bb = nil,
		frame = nil,
		stroke = nil,
		adornee = nil,
	}
end

function SelectRing.destroy(h: Handle)
	if h.bb then
		h.bb:Destroy()
	end
	h.bb = nil
	h.frame = nil
	h.stroke = nil
	h.adornee = nil
end

function SelectRing.getAdornee(h: Handle): BasePart?
	return h.adornee
end

function SelectRing.ensure(h: Handle, adornee: BasePart, parentGui: Instance?)
	-- Never keep a Billboard on a destroyed mesh — that is the classic upgrade spin/vanish.
	if not adornee.Parent then
		SelectRing.destroy(h)
		return
	end
	if h.bb and h.bb.Parent and h.adornee == adornee and h.adornee.Parent then
		applyLayout(h.bb, adornee)
		return
	end
	SelectRing.destroy(h)
	local bb = Instance.new("BillboardGui")
	bb.Name = "OceanTD_SelectRing"
	bb.AlwaysOnTop = true
	bb.Active = false
	bb.LightInfluence = 0
	bb.MaxDistance = 2000
	bb.Adornee = adornee
	applyLayout(bb, adornee)
	local guiParent = parentGui
	if not guiParent then
		local pg = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
		guiParent = pg or adornee
	end
	bb.Parent = guiParent

	local frame = Instance.new("Frame")
	frame.Name = "Ring"
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromScale(0.5, 0.5)
	frame.Size = UDim2.fromScale(1, 1)
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0
	frame.Parent = bb
	UiCircles.ensure(frame)
	local stroke = Instance.new("UIStroke")
	stroke.Name = "RingStroke"
	stroke.Color = Color3.new(1, 1, 1)
	stroke.Thickness = 3
	stroke.Transparency = 0.05
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = frame

	h.bb = bb
	h.frame = frame
	h.stroke = stroke
	h.adornee = adornee
end

function SelectRing.pulse(h: Handle)
	if not h.adornee or not h.adornee.Parent then
		SelectRing.destroy(h)
		return
	end
	if not h.frame or not h.stroke then
		return
	end
	-- Keep glued to plant point while mesh center drifts on size swaps.
	if h.bb then
		applyLayout(h.bb, h.adornee)
	end
	local wave = (math.sin(os.clock() * RING_HZ) + 1) * 0.5
	local scale = 0.78 + wave * 0.42
	h.frame.Size = UDim2.fromScale(scale, scale)
	h.stroke.Thickness = 2.2 + wave * 2.8
	h.stroke.Transparency = 0.02 + wave * 0.28
end

-- White pick ring is Active=false (no GUI swallow) — screen disc test for drag grab.
function SelectRing.isOver(h: Handle, screenPos: Vector2): boolean
	local bb = h.bb
	local frame = h.frame
	if not bb or not bb.Parent or not frame or not frame.Visible then
		return false
	end
	local function inside(x: number, y: number): boolean
		local p = frame.AbsolutePosition
		local s = frame.AbsoluteSize
		if s.X < 2 or s.Y < 2 then
			return false
		end
		local cx = p.X + s.X * 0.5
		local cy = p.Y + s.Y * 0.5
		local r = math.min(s.X, s.Y) * 0.5 * HIT_SLOP
		local dx = x - cx
		local dy = y - cy
		return dx * dx + dy * dy <= r * r
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

return SelectRing
