--!strict
-- In-memory occupancy for plot layouts. Phase 1: hydrate/snapshot only (no place API).

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

-- Global live grid: key -> cell (world-agnostic plot-local keys scoped per plot via compound key)
local cells: { [string]: CellData } = {}
local plotObjectCounts: { [string]: number } = {} -- plotId -> count

local function log(...: any)
	print("[GRID]", ...)
end

local function compoundKey(plotId: string, gx: number, gy: number, gz: number): string
	return plotId .. ":" .. GridMath.key(gx, gy, gz)
end

local function layoutToGridKey(plotId: string, obj: LayoutObject): string
	local gx, gy, gz = GridMath.worldToGrid(Vector3.new(obj.lx, obj.ly, obj.lz), Vector3.zero)
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

-- Hydrate from durable plot-local layout. Empty layout is valid.
function GridService.hydrate(plotId: PlotId, ownerUserId: number, layout: { LayoutObject }, boundsCFrame: CFrame)
	GridService.clearPlot(plotId)

	local count = 0
	for _, obj in ipairs(layout) do
		if typeof(obj) == "table" and typeof(obj.id) == "string" then
			local lx = tonumber(obj.lx) or 0
			local ly = tonumber(obj.ly) or 0
			local lz = tonumber(obj.lz) or 0
			local normalized: LayoutObject = {
				id = obj.id,
				lx = lx,
				ly = ly,
				lz = lz,
			}
			local key = layoutToGridKey(plotId, normalized)
			cells[key] = {
				id = normalized.id,
				lx = lx,
				ly = ly,
				lz = lz,
				ownerUserId = ownerUserId,
				plotId = plotId,
			}
			count += 1
			-- Phase 1: no visual spawn. World position available for later phases:
			-- GridMath.plotLocalToWorld(Vector3.new(lx, ly, lz), boundsCFrame)
			local _ = boundsCFrame
		end
	end
	plotObjectCounts[plotId] = count
	log("Hydrated", plotId, "objects=", count)
end

-- Snapshot plot-local durable objects for persistence.
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
