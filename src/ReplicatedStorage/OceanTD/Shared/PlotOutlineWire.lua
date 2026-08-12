--!strict
--[[
	Build a 12-edge Neon OBB wireframe under a folder from plot CFrame + Size.
]]

local PlotOutlineWire = {}

local EDGE_PAIRS = {
	-- bottom
	{ 1, 2 },
	{ 2, 4 },
	{ 4, 3 },
	{ 3, 1 },
	-- top
	{ 5, 6 },
	{ 6, 8 },
	{ 8, 7 },
	{ 7, 5 },
	-- vertical
	{ 1, 5 },
	{ 2, 6 },
	{ 3, 7 },
	{ 4, 8 },
}

local function corners(cf: CFrame, size: Vector3): { Vector3 }
	local hx, hy, hz = size.X * 0.5, size.Y * 0.5, size.Z * 0.5
	-- Index order matches EDGE_PAIRS (x-,y-,z-) … (x+,y+,z+)
	return {
		cf:PointToWorldSpace(Vector3.new(-hx, -hy, -hz)),
		cf:PointToWorldSpace(Vector3.new(hx, -hy, -hz)),
		cf:PointToWorldSpace(Vector3.new(-hx, -hy, hz)),
		cf:PointToWorldSpace(Vector3.new(hx, -hy, hz)),
		cf:PointToWorldSpace(Vector3.new(-hx, hy, -hz)),
		cf:PointToWorldSpace(Vector3.new(hx, hy, -hz)),
		cf:PointToWorldSpace(Vector3.new(-hx, hy, hz)),
		cf:PointToWorldSpace(Vector3.new(hx, hy, hz)),
	}
end

local function makeEdgePart(parent: Instance, name: string, a: Vector3, b: Vector3, thickness: number): BasePart
	local mid = (a + b) * 0.5
	local delta = b - a
	local len = delta.Magnitude
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.Neon
	p.Size = Vector3.new(thickness, thickness, math.max(len, 0.05))
	if len > 1e-4 then
		p.CFrame = CFrame.lookAt(mid, mid + delta)
	else
		p.CFrame = CFrame.new(mid)
	end
	p.Parent = parent
	return p
end

export type BuildOpts = {
	thickness: number,
	tagOwn: boolean?, -- IsPlayerPlotOutline
	color: Color3?,
	transparency: number?,
	namePrefix: string?,
}

function PlotOutlineWire.clear(folder: Instance)
	folder:ClearAllChildren()
end

function PlotOutlineWire.rebuild(folder: Instance, cf: CFrame, size: Vector3, opts: BuildOpts)
	PlotOutlineWire.clear(folder)
	local thickness = math.max(opts.thickness, 0.05)
	local prefix = opts.namePrefix or "Edge"
	local c = corners(cf, size)
	local color = opts.color or Color3.new(1, 1, 1)
	local trans = if opts.transparency ~= nil then opts.transparency else 0
	local tagOwn = opts.tagOwn == true

	for i, pair in ipairs(EDGE_PAIRS) do
		local part = makeEdgePart(folder, prefix .. tostring(i), c[pair[1]], c[pair[2]], thickness)
		part.Color = color
		part.Transparency = trans
		if tagOwn then
			part:SetAttribute("IsPlayerPlotOutline", true)
		end
	end
end

-- Approximate distance from a world point to the OBB surface (0 if inside).
function PlotOutlineWire.distanceToSurface(worldPos: Vector3, cf: CFrame, size: Vector3): number
	local localPos = cf:PointToObjectSpace(worldPos)
	local hx, hy, hz = size.X * 0.5, size.Y * 0.5, size.Z * 0.5
	local dx = math.max(math.abs(localPos.X) - hx, 0)
	local dy = math.max(math.abs(localPos.Y) - hy, 0)
	local dz = math.max(math.abs(localPos.Z) - hz, 0)
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

return PlotOutlineWire
