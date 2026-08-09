--!strict
-- In-memory occupancy for plot layouts.
-- Cells store exact plot-local VisualPos (lx,ly,lz) plus rounded grid keys (gx,gy,gz).

local PlotTypes = require(game:GetService("ReplicatedStorage"):WaitForChild("OceanTD"):WaitForChild("Shared"):WaitForChild("PlotTypes"))
local GridMath = require(game:GetService("ReplicatedStorage"):WaitForChild("OceanTD"):WaitForChild("Shared"):WaitForChild("GridMath"))

type LayoutObject = PlotTypes.LayoutObject
type PlotId = PlotTypes.PlotId

export type CellData = {
	id: string,
	lx: number, -- VisualPos plot-local
	ly: number,
	lz: number,
	gx: number,
	gy: number,
	gz: number,
	ownerUserId: number,
	plotId: PlotId,
}

local GridService = {}

local cells: { [string]: CellData } = {}
local plotObjectCounts: { [string]: number } = {}

local function log(...: any)
	print("[GRID]", ...)
end

local function compoundKey(plotId: string, gx: number, gy: number, gz: number): string
	return plotId .. ":" .. GridMath.key(gx, gy, gz)
end

local function resolveGridKey(
	plotId: string,
	lx: number,
	ly: number,
	lz: number,
	gx: number?,
	gy: number?,
	gz: number?
): (number, number, number, string)
	local rx: number
	local ry: number
	local rz: number
	if typeof(gx) == "number" and typeof(gy) == "number" and typeof(gz) == "number" then
		rx = math.round(gx)
		ry = math.round(gy)
		rz = math.round(gz)
	else
		rx, ry, rz = GridMath.worldToGrid(Vector3.new(lx, ly, lz), Vector3.zero)
	end
	return rx, ry, rz, compoundKey(plotId, rx, ry, rz)
end

function GridService.clearPlot(plotId: PlotId)
	local removed = 0
	for key, cell in pairs(cells) do
		if cell.plotId == plotId then
			cells[key] = nil
			removed += 1
		end
	end
	plotObjectCounts[plotId] = 0
	log("Cleared plot", plotId, "removed=", removed)
end

function GridService.getPlotCount(plotId: PlotId): number
	return plotObjectCounts[plotId] or 0
end

function GridService.getCell(plotId: PlotId, lx: number, ly: number, lz: number): CellData?
	local _, _, _, key = resolveGridKey(plotId, lx, ly, lz, nil, nil, nil)
	return cells[key]
end

function GridService.getCellAtGrid(plotId: PlotId, gx: number, gy: number, gz: number): CellData?
	return cells[compoundKey(plotId, math.round(gx), math.round(gy), math.round(gz))]
end

function GridService.isOccupied(plotId: PlotId, lx: number, ly: number, lz: number): boolean
	return GridService.getCell(plotId, lx, ly, lz) ~= nil
end

function GridService.tryOccupy(
	plotId: PlotId,
	ownerUserId: number,
	itemId: string,
	lx: number,
	ly: number,
	lz: number,
	gx: number?,
	gy: number?,
	gz: number?
): (boolean, string?)
	local rx, ry, rz, key = resolveGridKey(plotId, lx, ly, lz, gx, gy, gz)
	if cells[key] then
		return false, "SpotTaken"
	end
	cells[key] = {
		id = itemId,
		lx = lx,
		ly = ly,
		lz = lz,
		gx = rx,
		gy = ry,
		gz = rz,
		ownerUserId = ownerUserId,
		plotId = plotId,
	}
	plotObjectCounts[plotId] = (plotObjectCounts[plotId] or 0) + 1
	return true, nil
end

function GridService.vacate(
	plotId: PlotId,
	lx: number,
	ly: number,
	lz: number,
	gx: number?,
	gy: number?,
	gz: number?
): (boolean, CellData?)
	local _, _, _, key = resolveGridKey(plotId, lx, ly, lz, gx, gy, gz)
	local cell = cells[key]
	if not cell then
		return false, nil
	end
	cells[key] = nil
	plotObjectCounts[plotId] = math.max(0, (plotObjectCounts[plotId] or 0) - 1)
	return true, cell
end

function GridService.hydrate(plotId: PlotId, ownerUserId: number, layout: { LayoutObject }, _boundsCFrame: CFrame)
	GridService.clearPlot(plotId)

	local count = 0
	for _, obj in ipairs(layout) do
		if typeof(obj) == "table" and typeof(obj.id) == "string" then
			local lx = tonumber(obj.lx) or 0
			local ly = tonumber(obj.ly) or 0
			local lz = tonumber(obj.lz) or 0
			local gx = tonumber(obj.gx)
			local gy = tonumber(obj.gy)
			local gz = tonumber(obj.gz)
			local ok = GridService.tryOccupy(plotId, ownerUserId, obj.id, lx, ly, lz, gx, gy, gz)
			if ok then
				count += 1
			end
		end
	end
	plotObjectCounts[plotId] = count
	log("Hydrated", plotId, "objects=", count)
end

function GridService.forEachCell(plotId: PlotId, fn: (CellData) -> ())
	for _, cell in pairs(cells) do
		if cell.plotId == plotId then
			fn(cell)
		end
	end
end

function GridService.snapshot(plotId: PlotId): { LayoutObject }
	local layout: { LayoutObject } = {}
	for _, cell in pairs(cells) do
		if cell.plotId == plotId then
			table.insert(layout, {
				id = cell.id,
				lx = cell.lx,
				ly = cell.ly,
				lz = cell.lz,
				gx = cell.gx,
				gy = cell.gy,
				gz = cell.gz,
			})
		end
	end
	log("Snapshot", plotId, "objects=", #layout)
	return layout
end

function GridService.debugCellCount(): number
	local n = 0
	for _ in pairs(cells) do
		n += 1
	end
	return n
end

return GridService
