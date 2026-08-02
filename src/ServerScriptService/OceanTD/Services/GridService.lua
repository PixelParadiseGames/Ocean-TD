--!strict
-- In-memory occupancy for plot layouts.

local PlotTypes = require(game:GetService("ReplicatedStorage"):WaitForChild("OceanTD"):WaitForChild("Shared"):WaitForChild("PlotTypes"))
local GridMath = require(game:GetService("ReplicatedStorage"):WaitForChild("OceanTD"):WaitForChild("Shared"):WaitForChild("GridMath"))

type LayoutObject = PlotTypes.LayoutObject
type PlotId = PlotTypes.PlotId

export type CellData = {
	id: string,
	lx: number,
	ly: number,
	lz: number,
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

local function localToKey(plotId: string, lx: number, ly: number, lz: number): string
	local gx, gy, gz = GridMath.worldToGrid(Vector3.new(lx, ly, lz), Vector3.zero)
	return compoundKey(plotId, gx, gy, gz)
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
	return cells[localToKey(plotId, lx, ly, lz)]
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
	lz: number
): (boolean, string?)
	local key = localToKey(plotId, lx, ly, lz)
	if cells[key] then
		return false, "SpotTaken"
	end
	cells[key] = {
		id = itemId,
		lx = lx,
		ly = ly,
		lz = lz,
		ownerUserId = ownerUserId,
		plotId = plotId,
	}
	plotObjectCounts[plotId] = (plotObjectCounts[plotId] or 0) + 1
	return true, nil
end

function GridService.vacate(plotId: PlotId, lx: number, ly: number, lz: number): (boolean, CellData?)
	local key = localToKey(plotId, lx, ly, lz)
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
			local ok = GridService.tryOccupy(plotId, ownerUserId, obj.id, lx, ly, lz)
			if ok then
				count += 1
			end
		end
	end
	-- tryOccupy increments; clearPlot zeroed — recount for accuracy
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
