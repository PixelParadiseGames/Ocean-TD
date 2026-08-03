--!strict
--[[
	Server place authority.
	Order: validate session/plot → seed debit → CanPlace → grid occupy → visual.
	Clear / recycle credit seeds back; load swaps credit then debit for the new layout.
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")

local oceanShared = ReplicatedStorage:WaitForChild("OceanTD"):WaitForChild("Shared")
local GridMath = require(oceanShared:WaitForChild("GridMath"))
local SpeciesCatalog = require(oceanShared:WaitForChild("SpeciesCatalog"))
local CoralVisual = require(oceanShared:WaitForChild("CoralVisual"))
local ItemCatalog = require(oceanShared:WaitForChild("ItemCatalog"))

local PlotService = require(script.Parent:WaitForChild("PlotService"))
local GridService = require(script.Parent:WaitForChild("GridService"))
local PlayerSession = require(script.Parent:WaitForChild("PlayerSession"))
local PersistenceService = require(script.Parent:WaitForChild("PersistenceService"))
local UndoService = require(script.Parent:WaitForChild("UndoService"))

type LayoutObject = {
	id: string,
	lx: number,
	ly: number,
	lz: number,
}

local PlacementService = {}

local ROOT_NAME = "OceanTD_Placed"
-- While true, successful ops don't push undo (used during undo itself).
local suppressUndoRecord = false

local function log(...: any)
	print("[PLACE]", ...)
end

local function warnPlace(...: any)
	warn("[PLACE]", ...)
end

local function getPlacedRoot(): Folder
	local root = Workspace:FindFirstChild(ROOT_NAME)
	if root and root:IsA("Folder") then
		return root
	end
	root = Instance.new("Folder")
	root.Name = ROOT_NAME
	root.Parent = Workspace
	return root
end

local function getPlotFolder(plotId: string): Folder
	local root = getPlacedRoot()
	local folder = root:FindFirstChild(plotId)
	if folder and folder:IsA("Folder") then
		return folder
	end
	folder = Instance.new("Folder")
	folder.Name = plotId
	folder.Parent = root
	return folder
end

function PlacementService.clearPlotVisuals(plotId: string)
	local root = Workspace:FindFirstChild(ROOT_NAME)
	if not root then
		return
	end
	local folder = root:FindFirstChild(plotId)
	if folder then
		folder:ClearAllChildren()
	end
end

local function worldToPlotLocal(plotId: string, worldPos: Vector3): Vector3?
	local slot = PlotService.getSlot(plotId)
	if not slot then
		return nil
	end
	return GridMath.worldToPlotLocal(worldPos, slot.cframe)
end

function PlacementService.validateWorldPos(player: Player, worldPos: Vector3): (boolean, string?, string?)
	if typeof(worldPos) ~= "Vector3" then
		return false, "BadPosition", nil
	end
	if not PlayerSession.canSave(player) then
		return false, "NotReady", nil
	end
	local plotId = PlotService.getOwnerPlotId(player)
	if not plotId then
		return false, "NoPlot", nil
	end
	if not PlotService.isInsideOwnerPlot(player, worldPos) then
		return false, "OutOfPlot", plotId
	end
	local localPos = worldToPlotLocal(plotId, worldPos)
	if not localPos then
		return false, "BadPlot", plotId
	end
	if GridService.isOccupied(plotId, localPos.X, localPos.Y, localPos.Z) then
		return false, "SpotTaken", plotId
	end
	return true, nil, plotId
end

function PlacementService.spawnVisual(plotId: string, speciesId: string, worldPos: Vector3, color: Color3?): BasePart?
	local part = CoralVisual.create(speciesId, worldPos, { ghost = false, color = color })
	if not part then
		return nil
	end
	part:SetAttribute("OceanTD_PlaceId", HttpService:GenerateGUID(false))
	part.Parent = getPlotFolder(plotId)
	return part
end

local function findVisualByPlaceId(plotId: string, placeId: string): BasePart?
	local folder = getPlotFolder(plotId)
	for _, inst in ipairs(folder:GetChildren()) do
		if inst:IsA("BasePart") and inst:GetAttribute("OceanTD_PlaceId") == placeId then
			return inst
		end
	end
	return nil
end

local function findVisualAtGrid(plotId: string, worldPos: Vector3): BasePart?
	local slot = PlotService.getSlot(plotId)
	if not slot then
		return nil
	end
	local localPos = GridMath.worldToPlotLocal(worldPos, slot.cframe)
	local gx, gy, gz = GridMath.worldToGrid(localPos, Vector3.zero)
	local folder = getPlotFolder(plotId)
	for _, inst in ipairs(folder:GetChildren()) do
		if inst:IsA("BasePart") then
			local lp = GridMath.worldToPlotLocal(inst.Position, slot.cframe)
			local ax, ay, az = GridMath.worldToGrid(lp, Vector3.zero)
			if ax == gx and ay == gy and az == gz then
				return inst
			end
		end
	end
	return nil
end

function PlacementService.hydrateVisuals(plotId: string, boundsCFrame: CFrame)
	PlacementService.clearPlotVisuals(plotId)
	GridService.forEachCell(plotId, function(cell)
		local species = SpeciesCatalog.getByItemId(cell.id) or SpeciesCatalog.get(cell.id)
		if not species then
			return
		end
		local world = GridMath.plotLocalToWorld(Vector3.new(cell.lx, cell.ly, cell.lz), boundsCFrame)
		PlacementService.spawnVisual(plotId, species.speciesId, world, nil)
	end)
	log("Hydrated visuals", plotId)
end

export type PlaceResult = {
	ok: boolean,
	errorCode: string?,
	worldPos: Vector3?,
	speciesId: string?,
	itemId: string?,
	placeId: string?,
}

-- consumeSeed: player places debit inventory. Internal hydrate/load can pass false.
function PlacementService.place(player: Player, itemId: string, worldPos: Vector3, consumeSeed: boolean?): PlaceResult
	local shouldConsume = consumeSeed ~= false
	local item = ItemCatalog.get(itemId)
	if not item then
		return { ok = false, errorCode = "UnknownItem" }
	end
	local species = SpeciesCatalog.getByItemId(itemId)
	if not species then
		return { ok = false, errorCode = "UnknownSpecies" }
	end

	local ok, err, plotId = PlacementService.validateWorldPos(player, worldPos)
	if not ok or not plotId then
		return { ok = false, errorCode = err or "Reject" }
	end

	local localPos = worldToPlotLocal(plotId, worldPos)
	if not localPos then
		return { ok = false, errorCode = "BadPlot" }
	end

	if shouldConsume then
		local debited = select(1, PersistenceService.tryDebitItem(player, itemId, 1))
		if not debited then
			return { ok = false, errorCode = "NoSeeds" }
		end
	end

	-- Snap visual to ray hit pos (client sends terrain hit); occupancy uses plot-local grid.
	local occupied, occupyErr = GridService.tryOccupy(plotId, player.UserId, itemId, localPos.X, localPos.Y, localPos.Z)
	if not occupied then
		if shouldConsume then
			PersistenceService.creditItem(player, itemId, 1)
		end
		return { ok = false, errorCode = occupyErr or "SpotTaken" }
	end

	local visual = PlacementService.spawnVisual(plotId, species.speciesId, worldPos, nil)
	if not visual then
		warnPlace("Visual spawn failed after occupy — rolling back cell")
		GridService.vacate(plotId, localPos.X, localPos.Y, localPos.Z)
		if shouldConsume then
			PersistenceService.creditItem(player, itemId, 1)
		end
		return { ok = false, errorCode = "VisualFail" }
	end

	local placeIdAttr = visual:GetAttribute("OceanTD_PlaceId")
	local placeId = if typeof(placeIdAttr) == "string" then placeIdAttr else HttpService:GenerateGUID(false)
	visual:SetAttribute("OceanTD_PlaceId", placeId)
	visual:SetAttribute("OceanTD_ItemId", itemId)
	visual:SetAttribute("OceanTD_SpeciesId", species.speciesId)

	if not suppressUndoRecord then
		UndoService.push(player, {
			kind = "place",
			placeId = placeId,
			itemId = itemId,
			worldPos = worldPos,
		})
	end

	log("Placed", itemId, "for", player.Name, "at", worldPos, "consume=", shouldConsume)
	return {
		ok = true,
		worldPos = worldPos,
		speciesId = species.speciesId,
		itemId = itemId,
		placeId = placeId,
	}
end

export type MoveResult = {
	ok: boolean,
	errorCode: string?,
	worldPos: Vector3?,
	speciesId: string?,
	itemId: string?,
	placeId: string?,
}

-- Move an existing placed coral from one plot cell to another.
function PlacementService.move(
	player: Player,
	placeId: string,
	fromWorldPos: Vector3,
	toWorldPos: Vector3
): MoveResult
	if typeof(placeId) ~= "string" or placeId == "" then
		return { ok = false, errorCode = "BadRequest" }
	end
	if typeof(fromWorldPos) ~= "Vector3" or typeof(toWorldPos) ~= "Vector3" then
		return { ok = false, errorCode = "BadPosition" }
	end
	if not PlayerSession.canSave(player) then
		return { ok = false, errorCode = "NotReady" }
	end
	local plotId = PlotService.getOwnerPlotId(player)
	if not plotId then
		return { ok = false, errorCode = "NoPlot" }
	end
	if not PlotService.isInsideOwnerPlot(player, fromWorldPos) then
		return { ok = false, errorCode = "OutOfPlot" }
	end
	if not PlotService.isInsideOwnerPlot(player, toWorldPos) then
		return { ok = false, errorCode = "OutOfPlot" }
	end

	local fromLocal = worldToPlotLocal(plotId, fromWorldPos)
	local toLocal = worldToPlotLocal(plotId, toWorldPos)
	if not fromLocal or not toLocal then
		return { ok = false, errorCode = "BadPlot" }
	end

	local fromCell = GridService.getCell(plotId, fromLocal.X, fromLocal.Y, fromLocal.Z)
	if not fromCell then
		return { ok = false, errorCode = "NotFound" }
	end
	if fromCell.ownerUserId ~= player.UserId then
		return { ok = false, errorCode = "NotOwner" }
	end

	local resolvedPlaceId = placeId
	if resolvedPlaceId == "" then
		resolvedPlaceId = HttpService:GenerateGUID(false)
	end

	local visual = findVisualByPlaceId(plotId, placeId)
		or findVisualAtGrid(plotId, toWorldPos)
		or findVisualAtGrid(plotId, fromWorldPos)
	if not visual then
		return { ok = false, errorCode = "NotFound" }
	end
	visual:SetAttribute("OceanTD_PlaceId", resolvedPlaceId)

	local fgx, fgy, fgz = GridMath.worldToGrid(fromLocal, Vector3.zero)
	local tgx, tgy, tgz = GridMath.worldToGrid(toLocal, Vector3.zero)
	if fgx == tgx and fgy == tgy and fgz == tgz then
		visual.CFrame = CFrame.new(toWorldPos)
		return {
			ok = true,
			worldPos = toWorldPos,
			itemId = fromCell.id,
			placeId = resolvedPlaceId,
		}
	end

	if GridService.isOccupied(plotId, toLocal.X, toLocal.Y, toLocal.Z) then
		return { ok = false, errorCode = "SpotTaken" }
	end

	local vacated, cell = GridService.vacate(plotId, fromLocal.X, fromLocal.Y, fromLocal.Z)
	if not vacated or not cell then
		return { ok = false, errorCode = "NotFound" }
	end

	local occupied, occupyErr = GridService.tryOccupy(plotId, player.UserId, cell.id, toLocal.X, toLocal.Y, toLocal.Z)
	if not occupied then
		-- Roll back vacate so the coral isn't lost from the grid.
		GridService.tryOccupy(plotId, player.UserId, cell.id, fromLocal.X, fromLocal.Y, fromLocal.Z)
		return { ok = false, errorCode = occupyErr or "SpotTaken" }
	end

	visual.CFrame = CFrame.new(toWorldPos)

	local species = SpeciesCatalog.getByItemId(cell.id)
	if not suppressUndoRecord then
		UndoService.push(player, {
			kind = "move",
			placeId = resolvedPlaceId,
			itemId = cell.id,
			fromWorldPos = fromWorldPos,
			toWorldPos = toWorldPos,
		})
	end

	log("Moved", cell.id, "for", player.Name, "→", toWorldPos)
	return {
		ok = true,
		worldPos = toWorldPos,
		speciesId = if species then species.speciesId else nil,
		itemId = cell.id,
		placeId = resolvedPlaceId,
	}
end

export type RecycleResult = {
	ok: boolean,
	errorCode: string?,
	itemId: string?,
	placeId: string?,
	seedCount: number?,
}

-- Remove a placed coral and credit one seed back to the player's inventory.
function PlacementService.recycle(player: Player, placeId: string, worldPos: Vector3): RecycleResult
	if typeof(placeId) ~= "string" then
		return { ok = false, errorCode = "BadRequest" }
	end
	if typeof(worldPos) ~= "Vector3" then
		return { ok = false, errorCode = "BadPosition" }
	end
	if not PlayerSession.canSave(player) then
		return { ok = false, errorCode = "NotReady" }
	end
	local plotId = PlotService.getOwnerPlotId(player)
	if not plotId then
		return { ok = false, errorCode = "NoPlot" }
	end
	if not PlotService.isInsideOwnerPlot(player, worldPos) then
		return { ok = false, errorCode = "OutOfPlot" }
	end

	local localPos = worldToPlotLocal(plotId, worldPos)
	if not localPos then
		return { ok = false, errorCode = "BadPlot" }
	end

	local cell = GridService.getCell(plotId, localPos.X, localPos.Y, localPos.Z)
	if not cell then
		return { ok = false, errorCode = "NotFound" }
	end
	if cell.ownerUserId ~= player.UserId then
		return { ok = false, errorCode = "NotOwner" }
	end

	local visual = findVisualByPlaceId(plotId, placeId) or findVisualAtGrid(plotId, worldPos)
	if not visual then
		return { ok = false, errorCode = "NotFound" }
	end

	local vacated, vacatedCell = GridService.vacate(plotId, localPos.X, localPos.Y, localPos.Z)
	if not vacated or not vacatedCell then
		return { ok = false, errorCode = "NotFound" }
	end

	local creditedId = vacatedCell.id
	visual:Destroy()
	local seedCount = PersistenceService.creditItem(player, creditedId, 1)

	if not suppressUndoRecord then
		UndoService.push(player, {
			kind = "recycle",
			placeId = placeId,
			itemId = creditedId,
			worldPos = worldPos,
		})
	end

	log("Recycled", creditedId, "for", player.Name, "seeds=", seedCount)
	return {
		ok = true,
		itemId = creditedId,
		placeId = placeId,
		seedCount = seedCount,
	}
end

export type ClearPlotEntry = {
	placeId: string,
	itemId: string,
	worldPos: Vector3,
}

export type ClearPlotResult = {
	ok: boolean,
	errorCode: string?,
	count: number?,
	entries: { ClearPlotEntry }?,
	credits: { [string]: number }?,
}

-- Remove every placed coral on the owner's plot and credit seeds back (full refund).
-- allowEmpty: success with count=0 (used by plot-save load/NEW).
-- recordUndo: false for load swaps (undo stack is wiped instead).
function PlacementService.clearPlot(player: Player, allowEmpty: boolean?, recordUndo: boolean?): ClearPlotResult
	local shouldRecordUndo = recordUndo ~= false
	if not PlayerSession.canSave(player) then
		return { ok = false, errorCode = "NotReady" }
	end
	local plotId = PlotService.getOwnerPlotId(player)
	if not plotId then
		return { ok = false, errorCode = "NoPlot" }
	end
	local slot = PlotService.getSlot(plotId)
	if not slot then
		return { ok = false, errorCode = "BadPlot" }
	end

	local pending: { ClearPlotEntry } = {}
	GridService.forEachCell(plotId, function(cell)
		if cell.ownerUserId ~= player.UserId then
			return
		end
		local worldPos = GridMath.plotLocalToWorld(Vector3.new(cell.lx, cell.ly, cell.lz), slot.cframe)
		local visual = findVisualAtGrid(plotId, worldPos)
		local placeIdAttr = if visual then visual:GetAttribute("OceanTD_PlaceId") else nil
		local placeId = if typeof(placeIdAttr) == "string" then placeIdAttr else HttpService:GenerateGUID(false)
		-- Prefer live visual position for VFX / undo restore accuracy.
		if visual then
			worldPos = visual.Position
		end
		table.insert(pending, {
			placeId = placeId,
			itemId = cell.id,
			worldPos = worldPos,
		})
	end)

	if #pending == 0 then
		if allowEmpty then
			PersistenceService.allowIntentionalClear(player.UserId)
			return { ok = true, count = 0, entries = {}, credits = {} }
		end
		return { ok = false, errorCode = "Empty" }
	end

	PersistenceService.allowIntentionalClear(player.UserId)

	local entries: { ClearPlotEntry } = {}
	local credits: { [string]: number } = {}
	for _, entry in ipairs(pending) do
		local localPos = worldToPlotLocal(plotId, entry.worldPos)
		if not localPos then
			continue
		end
		local visual = findVisualByPlaceId(plotId, entry.placeId) or findVisualAtGrid(plotId, entry.worldPos)
		local vacated, vacatedCell = GridService.vacate(plotId, localPos.X, localPos.Y, localPos.Z)
		if not vacated or not vacatedCell then
			continue
		end
		if visual then
			visual:Destroy()
		end
		local creditedId = vacatedCell.id
		PersistenceService.creditItem(player, creditedId, 1)
		credits[creditedId] = (credits[creditedId] or 0) + 1
		table.insert(entries, {
			placeId = entry.placeId,
			itemId = creditedId,
			worldPos = entry.worldPos,
		})
	end

	if #entries == 0 then
		if allowEmpty then
			return { ok = true, count = 0, entries = {}, credits = {} }
		end
		return { ok = false, errorCode = "Empty" }
	end

	if shouldRecordUndo and not suppressUndoRecord then
		UndoService.push(player, {
			kind = "clearPlot",
			placeId = "clearPlot",
			itemId = "clearPlot",
			entries = entries,
		})
	end

	log("Cleared plot", plotId, "for", player.Name, "count=", #entries)
	return {
		ok = true,
		count = #entries,
		entries = entries,
		credits = credits,
	}
end

export type ApplyLayoutResult = {
	ok: boolean,
	errorCode: string?,
	placed: number?,
}

-- Wipe live plot (credit seeds, no undo) then place layout objects (debit seeds).
function PlacementService.applyLayout(player: Player, layout: { LayoutObject }): ApplyLayoutResult
	if not PlayerSession.canSave(player) then
		return { ok = false, errorCode = "NotReady" }
	end
	local plotId = PlotService.getOwnerPlotId(player)
	if not plotId then
		return { ok = false, errorCode = "NoPlot" }
	end
	local slot = PlotService.getSlot(plotId)
	if not slot then
		return { ok = false, errorCode = "BadPlot" }
	end

	local cleared = PlacementService.clearPlot(player, true, false)
	if not cleared.ok then
		return { ok = false, errorCode = cleared.errorCode or "ClearFail" }
	end

	suppressUndoRecord = true
	local placed = 0
	for _, obj in ipairs(layout) do
		if typeof(obj) ~= "table" or typeof(obj.id) ~= "string" then
			continue
		end
		local worldPos = GridMath.plotLocalToWorld(Vector3.new(obj.lx, obj.ly, obj.lz), slot.cframe)
		local result = PlacementService.place(player, obj.id, worldPos, true)
		if result.ok then
			placed += 1
		else
			warnPlace("applyLayout place failed", obj.id, result.errorCode)
		end
	end
	suppressUndoRecord = false

	log("Applied layout for", player.Name, "placed=", placed, "/", #layout)
	return { ok = true, placed = placed }
end

export type UndoResult = {
	ok: boolean,
	errorCode: string?,
	kind: string?,
}

local function removePlacedAndCredit(player: Player, placeId: string, itemId: string, worldPos: Vector3): boolean
	local plotId = PlotService.getOwnerPlotId(player)
	if not plotId then
		return false
	end
	local localPos = worldToPlotLocal(plotId, worldPos)
	if not localPos then
		return false
	end
	local visual = findVisualByPlaceId(plotId, placeId) or findVisualAtGrid(plotId, worldPos)
	local vacated, vacatedCell = GridService.vacate(plotId, localPos.X, localPos.Y, localPos.Z)
	if not vacated then
		if visual then
			visual:Destroy()
		end
		return false
	end
	if visual then
		visual:Destroy()
	end
	local creditedId = if vacatedCell then vacatedCell.id else itemId
	PersistenceService.creditItem(player, creditedId, 1)
	return true
end

-- Undo last place / move / recycle / clearPlot for this session (does not push a new undo step).
function PlacementService.undoLast(player: Player): UndoResult
	if not PlayerSession.canSave(player) then
		return { ok = false, errorCode = "NotReady" }
	end
	local step = UndoService.pop(player)
	if not step then
		return { ok = false, errorCode = "NothingToUndo" }
	end

	suppressUndoRecord = true
	local ok = false
	local err: string? = nil

	if step.kind == "place" then
		local worldPos = step.worldPos
		if typeof(worldPos) == "Vector3" then
			ok = removePlacedAndCredit(player, step.placeId, step.itemId, worldPos)
			if not ok then
				err = "NotFound"
			end
		else
			err = "BadStep"
		end
	elseif step.kind == "move" then
		local fromPos = step.fromWorldPos
		local toPos = step.toWorldPos
		if typeof(fromPos) == "Vector3" and typeof(toPos) == "Vector3" then
			local result = PlacementService.move(player, step.placeId, toPos, fromPos)
			ok = result.ok == true
			err = result.errorCode
		else
			err = "BadStep"
		end
	elseif step.kind == "recycle" then
		-- Recycle credited a seed; place consumes it again.
		local worldPos = step.worldPos
		if typeof(worldPos) == "Vector3" then
			local result = PlacementService.place(player, step.itemId, worldPos, true)
			ok = result.ok == true
			err = result.errorCode
		else
			err = "BadStep"
		end
	elseif step.kind == "clearPlot" then
		local entries = step.entries
		if typeof(entries) ~= "table" or #entries == 0 then
			err = "BadStep"
		else
			local restored = 0
			local remaining: { ClearPlotEntry } = {}
			for _, entry in ipairs(entries) do
				if typeof(entry.itemId) ~= "string" or typeof(entry.worldPos) ~= "Vector3" then
					table.insert(remaining, entry)
					continue
				end
				local result = PlacementService.place(player, entry.itemId, entry.worldPos, true)
				if result.ok then
					restored += 1
				else
					table.insert(remaining, entry)
				end
			end
			if restored > 0 then
				ok = true
				-- Partial restore: push leftover entries so another undo can finish.
				if #remaining > 0 then
					UndoService.push(player, {
						kind = "clearPlot",
						placeId = "clearPlot",
						itemId = "clearPlot",
						entries = remaining,
					})
				end
			else
				err = "UndoFail"
			end
		end
	else
		err = "BadStep"
	end

	suppressUndoRecord = false

	if ok then
		log("Undid", step.kind, "for", player.Name, "remaining=", UndoService.count(player))
		return { ok = true, kind = step.kind }
	end

	UndoService.push(player, step)
	warnPlace("Undo failed", step.kind, err, "for", player.Name)
	return { ok = false, errorCode = err or "UndoFail", kind = step.kind }
end

function PlacementService.init()
	getPlacedRoot()
	log("Init")
end

return PlacementService
