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
	diameter: number?,
	sizeTier: number?,
	sizeClass: number?,
	colorIndex: number?,
	colorR: number?,
	colorG: number?,
	colorB: number?,
	variantIndex: number?,
	scaleMult: number?,
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
	gz: number?,
	diameter: number?,
	sizeTier: number?,
	sizeClass: number?,
	colorIndex: number?,
	colorR: number?,
	colorG: number?,
	colorB: number?,
	variantIndex: number?,
	scaleMult: number?
): (boolean, string?)
	local rx, ry, rz, key = resolveGridKey(plotId, lx, ly, lz, gx, gy, gz)
	if cells[key] then
		return false, "SpotTaken"
	end
	local cr = if typeof(colorR) == "number" and colorR == colorR then math.clamp(colorR, 0, 1) else nil
	local cg = if typeof(colorG) == "number" and colorG == colorG then math.clamp(colorG, 0, 1) else nil
	local cb = if typeof(colorB) == "number" and colorB == colorB then math.clamp(colorB, 0, 1) else nil
	local vi = tonumber(variantIndex)
	local sm = tonumber(scaleMult)
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
		diameter = if typeof(diameter) == "number" and diameter > 0 then diameter else nil,
		sizeTier = if typeof(sizeTier) == "number" then math.clamp(math.floor(sizeTier), 1, 3) else nil,
		sizeClass = if typeof(sizeClass) == "number" then math.clamp(math.floor(sizeClass), 1, 3) else nil,
		colorIndex = if typeof(colorIndex) == "number" then math.clamp(math.floor(colorIndex), 1, 14) else nil,
		colorR = cr,
		colorG = cg,
		colorB = cb,
		variantIndex = if vi and vi == vi then math.clamp(math.floor(vi), 1, 5) else nil,
		scaleMult = if sm and sm == sm and sm > 0 then math.clamp(sm, 0.7, 1.35) else nil,
	}
	plotObjectCounts[plotId] = (plotObjectCounts[plotId] or 0) + 1
	return true, nil
end

function GridService.setSizeAtGrid(
	plotId: PlotId,
	gx: number,
	gy: number,
	gz: number,
	diameter: number,
	sizeTier: number,
	sizeClass: number,
	variantIndex: number?,
	scaleMult: number?
): boolean
	local cell = GridService.getCellAtGrid(plotId, gx, gy, gz)
	if not cell then
		return false
	end
	cell.diameter = diameter
	cell.sizeTier = sizeTier
	cell.sizeClass = sizeClass
	if typeof(variantIndex) == "number" then
		cell.variantIndex = math.clamp(math.floor(variantIndex), 1, 5)
	end
	if typeof(scaleMult) == "number" and scaleMult > 0 then
		cell.scaleMult = math.clamp(scaleMult, 0.7, 1.35)
	end
	return true
end

function GridService.setColorAtGrid(
	plotId: PlotId,
	gx: number,
	gy: number,
	gz: number,
	colorIndex: number,
	colorR: number?,
	colorG: number?,
	colorB: number?
): boolean
	local cell = GridService.getCellAtGrid(plotId, gx, gy, gz)
	if not cell then
		return false
	end
	cell.colorIndex = math.clamp(math.floor(colorIndex), 1, 14)
	if typeof(colorR) == "number" and typeof(colorG) == "number" and typeof(colorB) == "number" then
		cell.colorR = math.clamp(colorR, 0, 1)
		cell.colorG = math.clamp(colorG, 0, 1)
		cell.colorB = math.clamp(colorB, 0, 1)
	else
		cell.colorR = nil
		cell.colorG = nil
		cell.colorB = nil
	end
	return true
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
			local diameter = tonumber(obj.diameter)
			local sizeTier = tonumber(obj.sizeTier)
			local sizeClass = tonumber(obj.sizeClass)
			local colorIndex = tonumber(obj.colorIndex)
			local colorR = tonumber(obj.colorR)
			local colorG = tonumber(obj.colorG)
			local colorB = tonumber(obj.colorB)
			local variantIndex = tonumber(obj.variantIndex)
			local scaleMult = tonumber(obj.scaleMult)
			local ok = GridService.tryOccupy(
				plotId,
				ownerUserId,
				obj.id,
				lx,
				ly,
				lz,
				gx,
				gy,
				gz,
				diameter,
				sizeTier,
				sizeClass,
				colorIndex,
				colorR,
				colorG,
				colorB,
				variantIndex,
				scaleMult
			)
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
				diameter = cell.diameter,
				sizeTier = cell.sizeTier,
				sizeClass = cell.sizeClass,
				colorIndex = cell.colorIndex,
				colorR = cell.colorR,
				colorG = cell.colorG,
				colorB = cell.colorB,
				variantIndex = cell.variantIndex,
				scaleMult = cell.scaleMult,
			})
		end
	end
	log("Snapshot", plotId, "objects=", #layout)
	return layout
end

-- Keep world positions when plot bounds CFrame changes (Plot Size stage).
function GridService.reframe(plotId: PlotId, oldCf: CFrame, newCf: CFrame): number
	if oldCf == newCf then
		return 0
	end
	local moved = 0
	local pending: { CellData } = {}
	for key, cell in pairs(cells) do
		if cell.plotId == plotId then
			cells[key] = nil
			table.insert(pending, cell)
		end
	end
	plotObjectCounts[plotId] = 0
	for _, cell in ipairs(pending) do
		local world = oldCf * Vector3.new(cell.lx, cell.ly, cell.lz)
		local localPos = newCf:PointToObjectSpace(world)
		local lx, ly, lz = localPos.X, localPos.Y, localPos.Z
		local gx, gy, gz = GridMath.worldToGrid(localPos, Vector3.zero)
		GridService.tryOccupy(
			plotId,
			cell.ownerUserId,
			cell.id,
			lx,
			ly,
			lz,
			gx,
			gy,
			gz,
			cell.diameter,
			cell.sizeTier,
			cell.sizeClass,
			cell.colorIndex,
			cell.colorR,
			cell.colorG,
			cell.colorB,
			cell.variantIndex,
			cell.scaleMult
		)
		moved += 1
	end
	log("Reframe", plotId, "objects=", moved)
	return moved
end

function GridService.debugCellCount(): number
	local n = 0
	for _ in pairs(cells) do
		n += 1
	end
	return n
end

return GridService
