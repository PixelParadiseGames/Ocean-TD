--!strict
-- In-memory occupancy for plot layouts.
-- Cells store exact plot-local VisualPos (lx,ly,lz) plus rounded grid keys (gx,gy,gz).

local PlotTypes = require(game:GetService("ReplicatedStorage"):WaitForChild("OceanTD"):WaitForChild("Shared"):WaitForChild("PlotTypes"))
local GridMath = require(game:GetService("ReplicatedStorage"):WaitForChild("OceanTD"):WaitForChild("Shared"):WaitForChild("GridMath"))
local LayoutRestore = require(game:GetService("ReplicatedStorage"):WaitForChild("OceanTD"):WaitForChild("Shared"):WaitForChild("LayoutRestore"))
local BrainStack = require(game:GetService("ReplicatedStorage"):WaitForChild("OceanTD"):WaitForChild("Shared"):WaitForChild("BrainStack"))

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
	scaleWidth: number?,
	scaleHeight: number?,
	facingYaw: number?,
	webColorR: number?,
	webColorG: number?,
	webColorB: number?,
	placeId: string?,
	parentPlaceId: string?,
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

function GridService.findCellByPlaceId(plotId: PlotId, placeId: string): CellData?
	if placeId == "" then
		return nil
	end
	for _, cell in pairs(cells) do
		if cell.plotId == plotId and cell.placeId == placeId then
			return cell
		end
	end
	return nil
end

-- Prefer exact VisualPos match (stacked brains often sit off their rounded grid key).
function GridService.findCellByLocalPos(plotId: PlotId, lx: number, ly: number, lz: number, tol: number?): CellData?
	local t = if typeof(tol) == "number" then tol else 0.08
	local best: CellData? = nil
	local bestDist = math.huge
	for _, cell in pairs(cells) do
		if cell.plotId == plotId then
			local dx = cell.lx - lx
			local dy = cell.ly - ly
			local dz = cell.lz - lz
			local d = dx * dx + dy * dy + dz * dz
			if d < bestDist and d <= t * t then
				bestDist = d
				best = cell
			end
		end
	end
	return best
end

function GridService.setPlaceMeta(plotId: PlotId, gx: number, gy: number, gz: number, placeId: string?, parentPlaceId: string?): boolean
	local cell = GridService.getCellAtGrid(plotId, gx, gy, gz)
	if not cell then
		return false
	end
	if typeof(placeId) == "string" and placeId ~= "" then
		cell.placeId = placeId
	end
	if typeof(parentPlaceId) == "string" and parentPlaceId ~= "" then
		cell.parentPlaceId = parentPlaceId
	else
		cell.parentPlaceId = nil
	end
	return true
end

function GridService.setParentPlaceId(cell: CellData, parentPlaceId: string?)
	if typeof(parentPlaceId) == "string" and parentPlaceId ~= "" then
		cell.parentPlaceId = parentPlaceId
	else
		cell.parentPlaceId = nil
	end
end

-- Move a cell to a new VisualPos; preserves identity fields; re-keys grid occupancy.
function GridService.relocateCellLocal(cell: CellData, lx: number, ly: number, lz: number): boolean
	local oldKey = compoundKey(cell.plotId, cell.gx, cell.gy, cell.gz)
	if cells[oldKey] ~= cell then
		-- Key drift — find by identity.
		for key, c in pairs(cells) do
			if c == cell then
				cells[key] = nil
				break
			end
		end
	else
		cells[oldKey] = nil
	end
	local gx, gy, gz = GridMath.worldToGrid(Vector3.new(lx, ly, lz), Vector3.zero)
	-- Keep unique gy if target key occupied by someone else.
	local key = compoundKey(cell.plotId, gx, gy, gz)
	if cells[key] and cells[key] ~= cell then
		gy = GridService.nextFreeGyInColumn(cell.plotId, gx, gz, gy)
		key = compoundKey(cell.plotId, gx, gy, gz)
	end
	if cells[key] and cells[key] ~= cell then
		return false
	end
	cell.lx = lx
	cell.ly = ly
	cell.lz = lz
	cell.gx = math.round(gx)
	cell.gy = math.round(gy)
	cell.gz = math.round(gz)
	cells[key] = cell
	return true
end

function GridService.isOccupied(plotId: PlotId, lx: number, ly: number, lz: number): boolean
	return GridService.getCell(plotId, lx, ly, lz) ~= nil
end

-- Tallest BrainCoral in the same XZ grid column (any gy).
function GridService.findTopBrainInColumn(plotId: PlotId, gx: number, gz: number): CellData?
	local rx = math.round(gx)
	local rz = math.round(gz)
	local best: CellData? = nil
	for _, cell in pairs(cells) do
		if cell.plotId == plotId and cell.id == "BrainCoral" and cell.gx == rx and cell.gz == rz then
			if not best or cell.ly > best.ly or (cell.ly == best.ly and cell.gy > best.gy) then
				best = cell
			end
		end
	end
	return best
end

-- Closest BrainCoral host for offset stacking (by XZ distance to cell center).
function GridService.countBrainChildren(
	plotId: PlotId,
	host: CellData,
	ignoreGx: number?,
	ignoreGy: number?,
	ignoreGz: number?
): number
	local hostId = host.placeId
	local n = 0
	for _, cell in pairs(cells) do
		if cell.plotId == plotId and cell.id == "BrainCoral" and cell ~= host then
			if ignoreGx == cell.gx and ignoreGy == cell.gy and ignoreGz == cell.gz then
				continue
			end
			local linked = typeof(hostId) == "string" and hostId ~= "" and cell.parentPlaceId == hostId
			if linked then
				n += 1
			end
		end
	end
	return n
end

local function brainRootCell(plotId: PlotId, host: CellData, ignoreGx: number?, ignoreGy: number?, ignoreGz: number?): CellData
	local byId: { [string]: CellData } = {}
	for _, cell in pairs(cells) do
		if cell.plotId == plotId and cell.id == "BrainCoral" then
			if ignoreGx == cell.gx and ignoreGy == cell.gy and ignoreGz == cell.gz then
				continue
			end
			if typeof(cell.placeId) == "string" and cell.placeId ~= "" then
				byId[cell.placeId] = cell
			end
		end
	end
	local cur = host
	local guard = 0
	while guard < 64 do
		guard += 1
		local pid = cur.parentPlaceId
		if typeof(pid) == "string" and pid ~= "" and byId[pid] then
			cur = byId[pid]
		else
			break
		end
	end
	return cur
end

function GridService.countBrainStackSize(
	plotId: PlotId,
	host: CellData,
	ignoreGx: number?,
	ignoreGy: number?,
	ignoreGz: number?
): number
	local root = brainRootCell(plotId, host, ignoreGx, ignoreGy, ignoreGz)
	local rootId = root.placeId
	local byId: { [string]: CellData } = {}
	local list: { CellData } = {}
	for _, cell in pairs(cells) do
		if cell.plotId == plotId and cell.id == "BrainCoral" then
			if ignoreGx == cell.gx and ignoreGy == cell.gy and ignoreGz == cell.gz then
				continue
			end
			table.insert(list, cell)
			if typeof(cell.placeId) == "string" and cell.placeId ~= "" then
				byId[cell.placeId] = cell
			end
		end
	end
	local n = 0
	for _, cell in ipairs(list) do
		local cur = cell
		local inTree = cur == root
		local guard = 0
		while not inTree and guard < 64 do
			guard += 1
			local pid = cur.parentPlaceId
			if typeof(pid) ~= "string" or pid == "" or not byId[pid] then
				break
			end
			cur = byId[pid]
			if cur == root or (typeof(rootId) == "string" and cur.placeId == rootId) then
				inTree = true
				break
			end
		end
		if inTree then
			n += 1
		end
	end
	return n
end

function GridService.brainHasFreeSlot(
	plotId: PlotId,
	host: CellData,
	ignoreGx: number?,
	ignoreGy: number?,
	ignoreGz: number?
): boolean
	if GridService.countBrainStackSize(plotId, host, ignoreGx, ignoreGy, ignoreGz) >= BrainStack.MAX_STACK_SIZE then
		return false
	end
	local class = if typeof(host.sizeClass) == "number" then host.sizeClass else BrainStack.classFromDiameter(
		if typeof(host.diameter) == "number" and host.diameter > 0 then host.diameter else 4
	)
	local maxKids = BrainStack.maxChildrenForClass(class)
	return GridService.countBrainChildren(plotId, host, ignoreGx, ignoreGy, ignoreGz) < maxKids
end

function GridService.findNearestBrainHost(
	plotId: PlotId,
	localPos: Vector3,
	ignoreGx: number?,
	ignoreGy: number?,
	ignoreGz: number?
): CellData?
	local best: CellData? = nil
	local bestDist = math.huge
	for _, cell in pairs(cells) do
		if cell.plotId == plotId and cell.id == "BrainCoral" then
			if ignoreGx == cell.gx and ignoreGy == cell.gy and ignoreGz == cell.gz then
				continue
			end
			if not GridService.brainHasFreeSlot(plotId, cell, ignoreGx, ignoreGy, ignoreGz) then
				continue
			end
			local d0 = if typeof(cell.diameter) == "number" and cell.diameter > 0 then cell.diameter else 4
			local hostPos = Vector3.new(cell.lx, cell.ly, cell.lz)
			local dx = localPos.X - hostPos.X
			local dz = localPos.Z - hostPos.Z
			local horiz = math.sqrt(dx * dx + dz * dz)
			local engage = d0 * 0.5 + 1.25 + d0 * 0.35
			if horiz <= engage and horiz < bestDist then
				bestDist = horiz
				best = cell
			end
		end
	end
	return best
end

function GridService.nextFreeGyInColumn(plotId: PlotId, gx: number, gz: number, startGy: number): number
	local rx = math.round(gx)
	local rz = math.round(gz)
	local gy = math.round(startGy)
	while GridService.getCellAtGrid(plotId, rx, gy, rz) do
		gy += 1
	end
	return gy
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

function GridService.copySeaFanExtras(from: CellData, to: CellData)
	to.scaleWidth = from.scaleWidth
	to.scaleHeight = from.scaleHeight
	to.facingYaw = from.facingYaw
	to.webColorR = from.webColorR
	to.webColorG = from.webColorG
	to.webColorB = from.webColorB
end

-- placeId / parentPlaceId / mesh extras survive plot-size reframe.
function GridService.copyCellMeta(from: CellData, to: CellData)
	if typeof(from.placeId) == "string" and from.placeId ~= "" then
		to.placeId = from.placeId
	end
	if typeof(from.parentPlaceId) == "string" and from.parentPlaceId ~= "" then
		to.parentPlaceId = from.parentPlaceId
	end
	GridService.copySeaFanExtras(from, to)
end

function GridService.setSeaFanExtras(
	plotId: PlotId,
	gx: number,
	gy: number,
	gz: number,
	scaleWidth: number?,
	scaleHeight: number?,
	facingYaw: number?,
	webColorR: number?,
	webColorG: number?,
	webColorB: number?
): boolean
	local cell = GridService.getCellAtGrid(plotId, gx, gy, gz)
	if not cell then
		return false
	end
	if typeof(scaleWidth) == "number" and scaleWidth > 0 then
		cell.scaleWidth = math.clamp(scaleWidth, 0.7, 1.35)
	end
	if typeof(scaleHeight) == "number" and scaleHeight > 0 then
		cell.scaleHeight = math.clamp(scaleHeight, 0.7, 1.35)
	end
	if typeof(facingYaw) == "number" and facingYaw == facingYaw then
		cell.facingYaw = facingYaw
	end
	if typeof(webColorR) == "number" and typeof(webColorG) == "number" and typeof(webColorB) == "number" then
		cell.webColorR = math.clamp(webColorR, 0, 1)
		cell.webColorG = math.clamp(webColorG, 0, 1)
		cell.webColorB = math.clamp(webColorB, 0, 1)
	end
	return true
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
	scaleMult: number?,
	scaleWidth: number?,
	scaleHeight: number?
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
	if typeof(scaleWidth) == "number" and scaleWidth > 0 then
		cell.scaleWidth = math.clamp(scaleWidth, 0.7, 1.35)
	end
	if typeof(scaleHeight) == "number" and scaleHeight > 0 then
		cell.scaleHeight = math.clamp(scaleHeight, 0.7, 1.35)
	end
	return true
end

function GridService.setColorAtGrid(
	plotId: PlotId,
	gx: number,
	gy: number,
	gz: number,
	colorIndex: number?,
	colorR: number?,
	colorG: number?,
	colorB: number?
): boolean
	local cell = GridService.getCellAtGrid(plotId, gx, gy, gz)
	if not cell then
		return false
	end
	if typeof(colorIndex) == "number" then
		cell.colorIndex = math.clamp(math.floor(colorIndex), 1, 14)
	end
	if typeof(colorR) == "number" and typeof(colorG) == "number" and typeof(colorB) == "number" then
		cell.colorR = math.clamp(colorR, 0, 1)
		cell.colorG = math.clamp(colorG, 0, 1)
		cell.colorB = math.clamp(colorB, 0, 1)
	elseif typeof(colorIndex) == "number" then
		-- Palette set without RGB — clear stale channels.
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
		-- Stacked brains often use a bumped gy that doesn't match worldToGrid(VisualPos).
		cell = GridService.findCellByLocalPos(plotId, lx, ly, lz, 0.35)
		if cell then
			key = compoundKey(cell.plotId, cell.gx, cell.gy, cell.gz)
		end
	end
	if not cell then
		return false, nil
	end
	if cells[key] == cell then
		cells[key] = nil
	else
		for k, c in pairs(cells) do
			if c == cell then
				cells[k] = nil
				break
			end
		end
	end
	plotObjectCounts[plotId] = math.max(0, (plotObjectCounts[plotId] or 0) - 1)
	return true, cell
end

function GridService.vacateCell(cell: CellData): boolean
	local key = compoundKey(cell.plotId, cell.gx, cell.gy, cell.gz)
	if cells[key] == cell then
		cells[key] = nil
	else
		local found = false
		for k, c in pairs(cells) do
			if c == cell then
				cells[k] = nil
				found = true
				break
			end
		end
		if not found then
			return false
		end
	end
	plotObjectCounts[cell.plotId] = math.max(0, (plotObjectCounts[cell.plotId] or 0) - 1)
	return true
end

function GridService.hydrate(plotId: PlotId, ownerUserId: number, layout: { LayoutObject }, _boundsCFrame: CFrame)
	GridService.clearPlot(plotId)

	local count = 0
	for _, obj in ipairs(layout) do
		if typeof(obj) == "table" and typeof(obj.id) == "string" then
			local visualLocal = LayoutRestore.resolveVisualLocal(obj, _boundsCFrame)
			local lx = visualLocal.X
			local ly = visualLocal.Y
			local lz = visualLocal.Z
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
				nil,
				nil,
				nil,
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
				local cell = GridService.getCell(plotId, lx, ly, lz)
				if cell then
					GridService.setSeaFanExtras(
						plotId,
						cell.gx,
						cell.gy,
						cell.gz,
						tonumber(obj.scaleWidth),
						tonumber(obj.scaleHeight),
						tonumber(obj.facingYaw),
						tonumber(obj.webColorR),
						tonumber(obj.webColorG),
						tonumber(obj.webColorB)
					)
					if typeof(obj.placeId) == "string" and obj.placeId ~= "" then
						cell.placeId = obj.placeId
					end
					if typeof(obj.parentPlaceId) == "string" and obj.parentPlaceId ~= "" then
						cell.parentPlaceId = obj.parentPlaceId
					end
				end
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
			local yaw = cell.facingYaw
			-- SeaFan always persists an explicit yaw (never omit — load treats missing as 0).
			if cell.id == "SeaFan" and (typeof(yaw) ~= "number" or yaw ~= yaw) then
				yaw = 0
			end
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
				scaleWidth = cell.scaleWidth,
				scaleHeight = cell.scaleHeight,
				facingYaw = yaw,
				webColorR = cell.webColorR,
				webColorG = cell.webColorG,
				webColorB = cell.webColorB,
				placeId = cell.placeId,
				parentPlaceId = cell.parentPlaceId,
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
		local newCell = GridService.getCell(plotId, lx, ly, lz)
		if newCell then
			GridService.copyCellMeta(cell, newCell)
		end
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
