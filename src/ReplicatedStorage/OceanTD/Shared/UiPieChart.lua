--!strict
--[[
	Radial pie chart for GuiObjects (no wedge assets).

	Uses a CanvasGroup host so spoke Rotation is composited into a texture first.
	Plain Frames under ClipsDescendants ancestors only show the unrotated AABB
	(right half or top half) — that is why older spoke pies looked half-empty.

	Optional Slice.id is stored per spoke for hit-testing (e.g. hue index) without
	changing how the pie is drawn.
]]

local UiCircles = require(script.Parent:WaitForChild("UiCircles"))

local UiPieChart = {}

export type Slice = {
	color: Color3,
	weight: number,
	id: number?,
}

local HOST_NAME = "OceanTD_PieChart"
local SPOKE_COUNT = 72
local pendingColors: { [CanvasGroup]: { Color3 } } = {}
local pendingIds: { [CanvasGroup]: { number? } } = {}
local sizeConns: { [CanvasGroup]: RBXScriptConnection } = {}

local function clearSpokes(host: CanvasGroup)
	for _, ch in ipairs(host:GetChildren()) do
		if ch.Name == "SpokeRotor" then
			ch:Destroy()
		end
	end
end

local function buildSpokeData(slices: { Slice }, emptyColor: Color3): ({ Color3 }, { number? })
	local total = 0
	for _, s in ipairs(slices) do
		if s.weight > 0 then
			total += s.weight
		end
	end
	local colors: { Color3 } = table.create(SPOKE_COUNT)
	local ids: { number? } = table.create(SPOKE_COUNT)
	if total <= 0 then
		for i = 1, SPOKE_COUNT do
			colors[i] = emptyColor
			ids[i] = nil
		end
		return colors, ids
	end
	local cursor = 0
	for _, s in ipairs(slices) do
		if s.weight <= 0 then
			continue
		end
		local n = math.max(1, math.floor((s.weight / total) * SPOKE_COUNT + 0.5))
		for _ = 1, n do
			if cursor >= SPOKE_COUNT then
				break
			end
			cursor += 1
			colors[cursor] = s.color
			ids[cursor] = s.id
		end
	end
	local lastId = slices[#slices] and slices[#slices].id or nil
	local lastColor = slices[#slices] and slices[#slices].color or emptyColor
	while cursor < SPOKE_COUNT do
		cursor += 1
		colors[cursor] = lastColor
		ids[cursor] = lastId
	end
	return colors, ids
end

local function paintSpokes(host: CanvasGroup, colors: { Color3 }, force: boolean)
	local side = math.min(host.AbsoluteSize.X, host.AbsoluteSize.Y)
	if side < 4 then
		return
	end
	local prev = host:GetAttribute("_OceanTD_PieSide")
	if
		not force
		and typeof(prev) == "number"
		and math.abs((prev :: number) - side) < 0.5
		and host:FindFirstChild("SpokeRotor") ~= nil
	then
		return
	end
	host:SetAttribute("_OceanTD_PieSide", side)
	clearSpokes(host)

	local radius = side * 0.5
	local thickness = math.max(3, (2 * math.pi * radius) / SPOKE_COUNT * 1.35)
	for i = 1, SPOKE_COUNT do
		-- Full-size rotor: Rotation spins around chart center; spoke is top radius.
		local rotor = Instance.new("Frame")
		rotor.Name = "SpokeRotor"
		rotor.BackgroundTransparency = 1
		rotor.BorderSizePixel = 0
		rotor.AnchorPoint = Vector2.new(0.5, 0.5)
		rotor.Position = UDim2.fromScale(0.5, 0.5)
		rotor.Size = UDim2.fromOffset(side, side)
		rotor.Rotation = (i - 0.5) * (360 / SPOKE_COUNT)
		rotor.ZIndex = host.ZIndex
		rotor.Active = false
		rotor.Parent = host

		local spoke = Instance.new("Frame")
		spoke.Name = "Spoke"
		spoke.BackgroundColor3 = colors[i]
		spoke.BackgroundTransparency = 0
		spoke.BorderSizePixel = 0
		spoke.AnchorPoint = Vector2.new(0.5, 1)
		spoke.Position = UDim2.new(0.5, 0, 0.5, 0)
		spoke.Size = UDim2.fromOffset(thickness, radius)
		spoke.ZIndex = host.ZIndex
		spoke.Active = false
		spoke.Parent = rotor
	end
end

function UiPieChart.ensure(parent: GuiObject, zIndex: number?): CanvasGroup
	local existing = parent:FindFirstChild(HOST_NAME)
	if existing and existing:IsA("CanvasGroup") then
		if typeof(zIndex) == "number" then
			existing.ZIndex = zIndex
		end
		return existing
	end
	if existing then
		existing:Destroy()
	end
	local host = Instance.new("CanvasGroup")
	host.Name = HOST_NAME
	host.BackgroundColor3 = Color3.fromRGB(12, 18, 28)
	host.BackgroundTransparency = 0.35
	host.BorderSizePixel = 0
	host.AnchorPoint = Vector2.new(0.5, 0.5)
	host.Position = UDim2.fromScale(0.5, 0.5)
	host.Size = UDim2.fromScale(1, 1)
	host.ZIndex = zIndex or math.max(1, (parent :: any).ZIndex - 1)
	host.Active = false
	host.ClipsDescendants = true
	host.Parent = parent
	UiCircles.ensure(host)
	local aspect = Instance.new("UIAspectRatioConstraint")
	aspect.AspectRatio = 1
	aspect.DominantAxis = Enum.DominantAxis.Width
	aspect.Parent = host
	return host
end

function UiPieChart.setSlices(host: CanvasGroup, slices: { Slice }, emptyColor: Color3?)
	local empty = emptyColor or Color3.fromRGB(40, 52, 68)
	local colors, ids = buildSpokeData(slices, empty)
	pendingColors[host] = colors
	pendingIds[host] = ids
	paintSpokes(host, colors, true)

	if not sizeConns[host] then
		sizeConns[host] = host:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
			if not host.Parent then
				local c = sizeConns[host]
				if c then
					c:Disconnect()
					sizeConns[host] = nil
				end
				pendingColors[host] = nil
				pendingIds[host] = nil
				return
			end
			local cols = pendingColors[host]
			if cols then
				paintSpokes(host, cols, false)
			end
		end)
		host.Destroying:Connect(function()
			local c = sizeConns[host]
			if c then
				c:Disconnect()
				sizeConns[host] = nil
			end
			pendingColors[host] = nil
			pendingIds[host] = nil
		end)
	end
end

-- Map a screen point to Slice.id. Full disk is clickable (photo sits on top visually
-- but angle still selects the wedge — avoids “dead” center after a mono-color recolor).
function UiPieChart.hitTestId(host: CanvasGroup, screenPos: Vector2): number?
	local ids = pendingIds[host]
	if not ids then
		return nil
	end
	local ap = host.AbsolutePosition
	local as = host.AbsoluteSize
	local side = math.min(as.X, as.Y)
	if side < 4 then
		return nil
	end
	local cx = ap.X + as.X * 0.5
	local cy = ap.Y + as.Y * 0.5
	local dx = screenPos.X - cx
	local dy = screenPos.Y - cy
	local dist = math.sqrt(dx * dx + dy * dy)
	local outer = side * 0.5
	-- Allow a little padding past the circle so inset/coord mismatch still hits.
	if dist > outer * 1.08 then
		return nil
	end
	-- Spokes: unrotated points UP; Rotation increases clockwise — match atan2(dx, -dy).
	local ang = math.deg(math.atan2(dx, -dy))
	if ang < 0 then
		ang += 360
	end
	local idx = math.clamp(math.floor(ang / (360 / SPOKE_COUNT)) + 1, 1, SPOKE_COUNT)
	return ids[idx]
end

-- Resolve id using a caller-owned spoke-id table and a hit gui's AbsoluteRect.
function UiPieChart.hitTestIdOnGui(hitGui: GuiObject, spokeIds: { number? }, screenPos: Vector2): number?
	if #spokeIds < SPOKE_COUNT then
		return nil
	end
	local ap = hitGui.AbsolutePosition
	local as = hitGui.AbsoluteSize
	local side = math.min(as.X, as.Y)
	if side < 4 then
		return nil
	end
	local cx = ap.X + as.X * 0.5
	local cy = ap.Y + as.Y * 0.5
	local dx = screenPos.X - cx
	local dy = screenPos.Y - cy
	local dist = math.sqrt(dx * dx + dy * dy)
	if dist > side * 0.54 then
		return nil
	end
	local ang = math.deg(math.atan2(dx, -dy))
	if ang < 0 then
		ang += 360
	end
	local idx = math.clamp(math.floor(ang / (360 / SPOKE_COUNT)) + 1, 1, SPOKE_COUNT)
	return spokeIds[idx]
end

function UiPieChart.spokeCount(): number
	return SPOKE_COUNT
end

function UiPieChart.syncBehindCircle(host: CanvasGroup, circle: GuiObject, radiusMult: number?)
	local mult = radiusMult or 1.28
	local parent = host.Parent
	if not parent or not parent:IsA("GuiObject") then
		return
	end
	local cs = circle.AbsoluteSize
	local side = math.max(cs.X, cs.Y)
	if side < 2 then
		return
	end
	local pieSide = math.floor(side * mult + 0.5)
	local cAbs = circle.AbsolutePosition
	local pAbs = parent.AbsolutePosition
	local cx = cAbs.X + cs.X * 0.5 - pAbs.X
	local cy = cAbs.Y + cs.Y * 0.5 - pAbs.Y
	host.AnchorPoint = Vector2.new(0.5, 0.5)
	host.Position = UDim2.fromOffset(math.floor(cx + 0.5), math.floor(cy + 0.5))
	host.Size = UDim2.fromOffset(pieSide, pieSide)
	host.ZIndex = math.max(1, circle.ZIndex - 1)
end

return UiPieChart
