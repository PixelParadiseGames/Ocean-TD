--!strict
--[[
	White grow/shrink ring around a coral / ghost so players can see the interact target.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local UiCircles = require(ReplicatedStorage:WaitForChild("OceanTD"):WaitForChild("Shared"):WaitForChild("UiCircles"))

local SelectRing = {}

local RING_HZ = 3.2

export type Handle = {
	bb: BillboardGui?,
	frame: Frame?,
	stroke: UIStroke?,
	adornee: BasePart?,
}

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
	local diam = math.max(adornee.Size.X, adornee.Size.Y, adornee.Size.Z)
	local studs = math.clamp(diam * 1.55, 2.2, 10)
	if h.bb and h.bb.Parent and h.adornee == adornee then
		h.bb.Size = UDim2.new(studs, 0, studs, 0)
		return
	end
	SelectRing.destroy(h)
	local bb = Instance.new("BillboardGui")
	bb.Name = "OceanTD_SelectRing"
	bb.AlwaysOnTop = true
	bb.Active = false
	bb.LightInfluence = 0
	bb.Size = UDim2.new(studs, 0, studs, 0)
	bb.StudsOffset = Vector3.zero
	bb.MaxDistance = 2000
	bb.Adornee = adornee
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
	if not h.frame or not h.stroke or not h.adornee or not h.adornee.Parent then
		return
	end
	local wave = (math.sin(os.clock() * RING_HZ) + 1) * 0.5
	local scale = 0.78 + wave * 0.42
	h.frame.Size = UDim2.fromScale(scale, scale)
	h.stroke.Thickness = 2.2 + wave * 2.8
	h.stroke.Transparency = 0.02 + wave * 0.28
end

return SelectRing
