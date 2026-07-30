-- World <-> grid conversion. Every client and the server must use the same CELL_SIZE.

local Constants = require(script.Parent.Constants)

local GridMath = {}

GridMath.CELL_SIZE = Constants.CELL_SIZE

function GridMath.worldToGrid(worldPos: Vector3, origin: Vector3): (number, number, number)
	local rel = worldPos - origin
	local cs = GridMath.CELL_SIZE
	return math.round(rel.X / cs), math.round(rel.Y / cs), math.round(rel.Z / cs)
end

function GridMath.gridToWorld(gx: number, gy: number, gz: number, origin: Vector3): Vector3
	local cs = GridMath.CELL_SIZE
	return origin + Vector3.new(gx * cs, gy * cs, gz * cs)
end

function GridMath.key(gx: number, gy: number, gz: number): string
	return string.format("%d,%d,%d", gx, gy, gz)
end

function GridMath.parseKey(key: string): (number?, number?, number?)
	local x, y, z = string.match(key, "^(-?%d+),(-?%d+),(-?%d+)$")
	if not x then
		return nil, nil, nil
	end
	return tonumber(x), tonumber(y), tonumber(z)
end

-- Plot-local <-> world using Bounds CFrame (position + rotation).
function GridMath.worldToPlotLocal(worldPos: Vector3, boundsCFrame: CFrame): Vector3
	return boundsCFrame:PointToObjectSpace(worldPos)
end

function GridMath.plotLocalToWorld(localPos: Vector3, boundsCFrame: CFrame): Vector3
	return boundsCFrame:PointToWorldSpace(localPos)
end

-- XZ footprint test in plot-local space (Y ignored for ownership).
function GridMath.isInsidePlotXZ(worldPos: Vector3, boundsCFrame: CFrame, boundsSize: Vector3): boolean
	local localPos = boundsCFrame:PointToObjectSpace(worldPos)
	local hx = boundsSize.X * 0.5
	local hz = boundsSize.Z * 0.5
	return math.abs(localPos.X) <= hx and math.abs(localPos.Z) <= hz
end

return GridMath
