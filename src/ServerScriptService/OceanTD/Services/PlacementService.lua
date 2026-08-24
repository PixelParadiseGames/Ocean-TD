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
local CoralSize = require(oceanShared:WaitForChild("CoralSize"))
local ItemCatalog = require(oceanShared:WaitForChild("ItemCatalog"))
local SkillStages = require(oceanShared:WaitForChild("SkillStages"))
local PlotOutlineColors = require(oceanShared:WaitForChild("PlotOutlineColors"))

local PlotService = require(script.Parent:WaitForChild("PlotService"))
local GridService = require(script.Parent:WaitForChild("GridService"))
local PlayerSession = require(script.Parent:WaitForChild("PlayerSession"))
local PersistenceService = require(script.Parent:WaitForChild("PersistenceService"))
local UndoService = require(script.Parent:WaitForChild("UndoService"))

local COLOR_SAVE_DEBOUNCE_SEC = 5

type LayoutObject = {
	id: string,
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
	scaleMult: number?,
}

export type PlaceOpts = {
	diameter: number?,
	variantIndex: number?,
	scaleMult: number?,
	sizeClass: number?,
}

export type PlaceResult = {
	ok: boolean,
	errorCode: string?,
	worldPos: Vector3?,
	speciesId: string?,
	itemId: string?,
	placeId: string?,
	diameter: number?,
	variantIndex: number?,
	scaleMult: number?,
	sizeClass: number?,
}

local PlacementService = {}

local ROOT_NAME = "OceanTD_Placed"
-- While true, successful ops don't push undo (used during undo itself).
local suppressUndoRecord = false
-- Debounce DataStore writes while players spam dice rolls (grid/visual still update live).
local colorSaveTokenByUser: { [number]: number } = {}

local function log(...: any)
	print("[PLACE]", ...)
end

local function scheduleCoralColorSave(player: Player, plotId: string)
	local userId = player.UserId
	local token = (colorSaveTokenByUser[userId] or 0) + 1
	colorSaveTokenByUser[userId] = token
	task.delay(COLOR_SAVE_DEBOUNCE_SEC, function()
		if colorSaveTokenByUser[userId] ~= token then
			return
		end
		colorSaveTokenByUser[userId] = nil
		if not player.Parent or not PlayerSession.canSave(player) then
			return
		end
		-- Fresh snapshot so later place/move/size ops aren't overwritten by a stale layout.
		PersistenceService.save(player, GridService.snapshot(plotId))
		log("Color save (debounced)", player.Name)
	end)
end

function PlacementService.clearPendingColorSave(player: Player)
	colorSaveTokenByUser[player.UserId] = nil
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

function PlacementService.spawnVisual(
	plotId: string,
	speciesId: string,
	worldPos: Vector3,
	color: Color3?,
	diameter: number?,
	sizeClass: number?,
	variantIndex: number?,
	scaleMult: number?
): BasePart?
	local part = CoralVisual.create(speciesId, worldPos, {
		ghost = false,
		color = color,
		diameter = diameter,
		sizeClass = sizeClass,
		variantIndex = variantIndex,
		scaleMult = scaleMult,
	})
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
		-- Same anchor as save — PointToWorldSpace(VisualPos). Never re-raycast / grid-center.
		local world = GridMath.plotLocalToWorld(Vector3.new(cell.lx, cell.ly, cell.lz), boundsCFrame)
		local visual = PlacementService.spawnVisual(
			plotId,
			species.speciesId,
			world,
			nil,
			cell.diameter,
			cell.sizeClass,
			cell.variantIndex,
			cell.scaleMult
		)
		if visual then
			visual:SetAttribute("OceanTD_ItemId", cell.id)
			visual:SetAttribute("OceanTD_SpeciesId", species.speciesId)
			local class = CoralSize.clampTier(cell.sizeClass or CoralSize.classFromDiameter(cell.diameter or 4))
			local tier = CoralSize.clampTier(cell.sizeTier or class)
			CoralSize.applyToPart(visual, cell.diameter or visual.Size.X, class, tier)
			if typeof(cell.variantIndex) == "number" then
				visual:SetAttribute("OceanTD_VariantIndex", cell.variantIndex)
			end
			if typeof(cell.scaleMult) == "number" then
				visual:SetAttribute("OceanTD_ScaleMult", cell.scaleMult)
			end
			if typeof(cell.colorIndex) == "number" then
				local idx = PlotOutlineColors.clampCoralIndex(cell.colorIndex)
				visual:SetAttribute("OceanTD_ColorIndex", idx)
				CoralVisual.setRestColor(visual, PlotOutlineColors.resolveCoralPaint(idx, cell.colorR, cell.colorG, cell.colorB))
			end
		end
	end)
	log("Hydrated visuals", plotId)
end

-- Restore from plot-local VisualPos. Skips surface ray / normal place gates.
-- Prefer saved gx,gy,gz for occupancy; fall back to WorldToGrid(VisualPos).
-- Same anchor as save — avoids FindSurfaceInCell random offset skewing restore.
function PlacementService.placeFromSave(
	player: Player,
	itemId: string,
	visualLocal: Vector3,
	gx: number?,
	gy: number?,
	gz: number?,
	consumeSeed: boolean?,
	diameter: number?,
	sizeTier: number?,
	sizeClass: number?,
	colorIndex: number?,
	colorR: number?,
	colorG: number?,
	colorB: number?,
	variantIndex: number?,
	scaleMult: number?
): PlaceResult
	local shouldConsume = consumeSeed == true
	local item = ItemCatalog.get(itemId)
	if not item then
		return { ok = false, errorCode = "UnknownItem" }
	end
	local species = SpeciesCatalog.getByItemId(itemId)
	if not species then
		return { ok = false, errorCode = "UnknownSpecies" }
	end
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

	if shouldConsume then
		local debited = select(1, PersistenceService.tryDebitItem(player, itemId, 1))
		if not debited then
			return { ok = false, errorCode = "NoSeeds" }
		end
	end

	-- exactPos = plot.CFrame:PointToWorldSpace(VisualPos) — never re-snap to terrain/grid center.
	local worldPos = GridMath.plotLocalToWorld(visualLocal, slot.cframe)
	local paintIdx = if typeof(colorIndex) == "number" then PlotOutlineColors.clampCoralIndex(colorIndex) else nil
	local paintColor = if paintIdx
		then PlotOutlineColors.resolveCoralPaint(paintIdx, colorR, colorG, colorB)
		else nil
	local class = CoralSize.clampTier(sizeClass or 1)
	local variant = if species.speciesId == "Sponge"
		then CoralVisual.clampSpongeVariant(variantIndex)
		else nil
	local scale = if species.speciesId == "Sponge"
		then CoralVisual.sanitizeSpongeScale(scaleMult)
		else nil
	local occupied, occupyErr = GridService.tryOccupy(
		plotId,
		player.UserId,
		itemId,
		visualLocal.X,
		visualLocal.Y,
		visualLocal.Z,
		gx,
		gy,
		gz,
		diameter,
		sizeTier,
		class,
		paintIdx,
		if paintColor then paintColor.R else nil,
		if paintColor then paintColor.G else nil,
		if paintColor then paintColor.B else nil,
		variant,
		scale
	)
	if not occupied then
		if shouldConsume then
			PersistenceService.creditItem(player, itemId, 1)
		end
		return { ok = false, errorCode = occupyErr or "SpotTaken" }
	end

	local visual = PlacementService.spawnVisual(
		plotId,
		species.speciesId,
		worldPos,
		paintColor,
		diameter,
		class,
		variant,
		scale
	)
	if not visual then
		GridService.vacate(plotId, visualLocal.X, visualLocal.Y, visualLocal.Z, gx, gy, gz)
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
	if paintIdx then
		visual:SetAttribute("OceanTD_ColorIndex", paintIdx)
	end
	local tier = CoralSize.clampTier(sizeTier or class)
	CoralSize.applyToPart(visual, diameter or visual.Size.Y, class, tier)

	return {
		ok = true,
		worldPos = worldPos,
		speciesId = species.speciesId,
		itemId = itemId,
		placeId = placeId,
	}
end

local function parsePlaceOpts(raw: any): PlaceOpts
	if typeof(raw) == "number" then
		return { diameter = raw }
	end
	if typeof(raw) == "table" then
		return {
			diameter = tonumber(raw.diameter),
			variantIndex = tonumber(raw.variantIndex),
			scaleMult = tonumber(raw.scaleMult),
			sizeClass = tonumber(raw.sizeClass),
		}
	end
	return {}
end

-- consumeSeed: player places debit inventory. Internal hydrate/load can pass false.
-- placeOpts: legacy number diameter, or { diameter, variantIndex, scaleMult, sizeClass }.
function PlacementService.place(
	player: Player,
	itemId: string,
	worldPos: Vector3,
	consumeSeed: boolean?,
	placeOpts: any
): PlaceResult
	local shouldConsume = consumeSeed ~= false
	local opts = parsePlaceOpts(placeOpts)
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

	local placeMoreStage = PersistenceService.getSkillStage(player, "PlaceMore")
	local placeMax = SkillStages.placeMoreMaxAtStage(placeMoreStage)
	if GridService.getPlotCount(plotId) >= placeMax then
		return { ok = false, errorCode = "PlaceCap" }
	end

	if shouldConsume then
		local debited = select(1, PersistenceService.tryDebitItem(player, itemId, 1))
		if not debited then
			return { ok = false, errorCode = "NoSeeds" }
		end
	end

	-- Snap visual to ray hit pos (client sends terrain hit); store exact VisualPos + rounded grid key.
	local diameter: number? = nil
	local sizeClass = 1
	local variant: number? = nil
	local scale: number? = nil
	if species.speciesId == "BrainCoral" or itemId == "BrainCoral" then
		-- Prefer client ghost size so preview matches the placed coral.
		diameter = CoralVisual.sanitizeBrainDiameter(opts.diameter)
	elseif species.speciesId == "Sponge" or itemId == "Sponge" then
		sizeClass = CoralSize.clampTier(opts.sizeClass or 1)
		variant = CoralVisual.clampSpongeVariant(opts.variantIndex)
		scale = CoralVisual.sanitizeSpongeScale(opts.scaleMult)
	end
	local gx, gy, gz = GridMath.worldToGrid(localPos, Vector3.zero)
	local occupied, occupyErr = GridService.tryOccupy(
		plotId,
		player.UserId,
		itemId,
		localPos.X,
		localPos.Y,
		localPos.Z,
		gx,
		gy,
		gz,
		diameter,
		1,
		sizeClass,
		nil,
		nil,
		nil,
		nil,
		variant,
		scale
	)
	if not occupied then
		if shouldConsume then
			PersistenceService.creditItem(player, itemId, 1)
		end
		return { ok = false, errorCode = occupyErr or "SpotTaken" }
	end

	local visual = PlacementService.spawnVisual(
		plotId,
		species.speciesId,
		worldPos,
		nil,
		diameter,
		sizeClass,
		variant,
		scale
	)
	if not visual then
		warnPlace("Visual spawn failed after occupy — rolling back cell")
		GridService.vacate(plotId, localPos.X, localPos.Y, localPos.Z, gx, gy, gz)
		if shouldConsume then
			PersistenceService.creditItem(player, itemId, 1)
		end
		return { ok = false, errorCode = "VisualFail" }
	end

	-- Persist resolved height for sponge (mesh Size.Y after scale jitter).
	if species.speciesId == "Sponge" then
		diameter = visual.Size.Y
		local cell = GridService.getCellAtGrid(plotId, gx, gy, gz)
		if cell then
			cell.diameter = diameter
		end
	end

	local placeIdAttr = visual:GetAttribute("OceanTD_PlaceId")
	local placeId = if typeof(placeIdAttr) == "string" then placeIdAttr else HttpService:GenerateGUID(false)
	visual:SetAttribute("OceanTD_PlaceId", placeId)
	visual:SetAttribute("OceanTD_ItemId", itemId)
	visual:SetAttribute("OceanTD_SpeciesId", species.speciesId)
	CoralSize.applyToPart(visual, diameter or visual.Size.X, sizeClass, 1)

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
		diameter = diameter,
		variantIndex = variant,
		scaleMult = scale,
		sizeClass = sizeClass,
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

	local visualForFrom = findVisualByPlaceId(plotId, placeId)
	local fromAnchor = if visualForFrom then CoralVisual.readGridAnchor(visualForFrom) else nil
	fromAnchor = fromAnchor or fromWorldPos

	local fromLocal = worldToPlotLocal(plotId, fromAnchor)
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
		if fromCell.id == "Sponge" or visual:GetAttribute("OceanTD_SpeciesId") == "Sponge" then
			CoralVisual.alignSpongeToSurface(visual, toWorldPos)
		else
			visual.CFrame = CFrame.new(toWorldPos)
		end
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

	local vacated, cell = GridService.vacate(plotId, fromLocal.X, fromLocal.Y, fromLocal.Z, fgx, fgy, fgz)
	if not vacated or not cell then
		return { ok = false, errorCode = "NotFound" }
	end

	local occupied, occupyErr = GridService.tryOccupy(
		plotId,
		player.UserId,
		cell.id,
		toLocal.X,
		toLocal.Y,
		toLocal.Z,
		tgx,
		tgy,
		tgz,
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
	if not occupied then
		-- Roll back vacate so the coral isn't lost from the grid.
		GridService.tryOccupy(
			plotId,
			player.UserId,
			cell.id,
			fromLocal.X,
			fromLocal.Y,
			fromLocal.Z,
			fgx,
			fgy,
			fgz,
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
		return { ok = false, errorCode = occupyErr or "SpotTaken" }
	end

	local species = SpeciesCatalog.getByItemId(cell.id)
	if species and species.speciesId == "Sponge" then
		CoralVisual.alignSpongeToSurface(visual, toWorldPos)
	else
		visual.CFrame = CFrame.new(toWorldPos)
	end

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

	local visual = findVisualByPlaceId(plotId, placeId) or findVisualAtGrid(plotId, worldPos)
	if not visual then
		return { ok = false, errorCode = "NotFound" }
	end
	local anchorPos = CoralVisual.readGridAnchor(visual) or worldPos
	local localPos = worldToPlotLocal(plotId, anchorPos)
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
	lx: number?,
	ly: number?,
	lz: number?,
	gx: number?,
	gy: number?,
	gz: number?,
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
			lx = cell.lx,
			ly = cell.ly,
			lz = cell.lz,
			gx = cell.gx,
			gy = cell.gy,
			gz = cell.gz,
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
		local lx = entry.lx
		local ly = entry.ly
		local lz = entry.lz
		if typeof(lx) ~= "number" or typeof(ly) ~= "number" or typeof(lz) ~= "number" then
			local localPos = worldToPlotLocal(plotId, entry.worldPos)
			if not localPos then
				continue
			end
			lx, ly, lz = localPos.X, localPos.Y, localPos.Z
		end
		local visual = findVisualByPlaceId(plotId, entry.placeId) or findVisualAtGrid(plotId, entry.worldPos)
		local vacated, vacatedCell = GridService.vacate(plotId, lx, ly, lz, entry.gx, entry.gy, entry.gz)
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
		-- fromSave: exact VisualPos + saved grid keys — never re-raycast / cell-center snap.
		local result = PlacementService.placeFromSave(
			player,
			obj.id,
			Vector3.new(obj.lx, obj.ly, obj.lz),
			obj.gx,
			obj.gy,
			obj.gz,
			true,
			obj.diameter,
			obj.sizeTier,
			obj.sizeClass,
			obj.colorIndex,
			obj.colorR,
			obj.colorG,
			obj.colorB,
			obj.variantIndex,
			obj.scaleMult
		)
		if result.ok then
			placed += 1
		else
			warnPlace("applyLayout placeFromSave failed", obj.id, result.errorCode)
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

function PlacementService.setCoralSize(
	player: Player,
	placeId: string,
	targetClass: number,
	unlockNext: boolean
): { ok: boolean, errorCode: string?, diameter: number?, sizeClass: number?, sizeTier: number?, variantIndex: number?, scaleMult: number? }
	if typeof(placeId) ~= "string" or placeId == "" then
		return { ok = false, errorCode = "BadRequest" }
	end
	if not PlayerSession.canSave(player) then
		return { ok = false, errorCode = "NotReady" }
	end
	local plotId = PlotService.getOwnerPlotId(player)
	if not plotId then
		return { ok = false, errorCode = "NoPlot" }
	end
	local visual = findVisualByPlaceId(plotId, placeId)
	if not visual then
		return { ok = false, errorCode = "Missing" }
	end
	local _curD, _curClass, tier = CoralSize.readFromPart(visual)
	local want = CoralSize.clampTier(targetClass)
	local newTier = tier
	if unlockNext then
		local nxt = CoralSize.nextUnlock(tier)
		if not nxt then
			return { ok = false, errorCode = "Maxed" }
		end
		if want ~= nxt then
			want = nxt
		end
		newTier = nxt
	elseif want > tier then
		return { ok = false, errorCode = "Locked" }
	end

	local speciesId = visual:GetAttribute("OceanTD_SpeciesId")
	local newDiam: number
	local variant: number? = nil
	local scale: number? = nil
	if speciesId == "Sponge" then
		-- New random mesh + scale jitter each size change / unlock.
		variant = CoralVisual.randomSpongeVariant()
		scale = CoralVisual.randomSpongeScale()
		local newPart, height, vOut, sOut = CoralVisual.restyleSponge(visual, want, variant, scale)
		if newPart then
			visual = newPart
			newDiam = height or newPart.Size.Y
			variant = vOut or variant
			scale = sOut or scale
		else
			newDiam = visual.Size.Y
		end
		visual:SetAttribute("OceanTD_SizeTier", newTier)
	else
		newDiam = CoralSize.randomDiameter(want)
	end

	local slot = PlotService.getSlot(plotId)
	if not slot then
		return { ok = false, errorCode = "BadPlot" }
	end
	local anchorWorld = CoralVisual.readGridAnchor(visual) or visual.Position
	local localPos = GridMath.worldToPlotLocal(anchorWorld, slot.cframe)
	local gx, gy, gz = GridMath.worldToGrid(localPos, Vector3.zero)
	if not GridService.setSizeAtGrid(plotId, gx, gy, gz, newDiam, newTier, want, variant, scale) then
		return { ok = false, errorCode = "Missing" }
	end
	-- Client plays the scale cinematic; persist attributes now so a leave/rejoin matches.
	visual:SetAttribute("OceanTD_Diameter", newDiam)
	visual:SetAttribute("OceanTD_SizeClass", want)
	visual:SetAttribute("OceanTD_SizeTier", newTier)
	if typeof(variant) == "number" then
		visual:SetAttribute("OceanTD_VariantIndex", variant)
	end
	if typeof(scale) == "number" then
		visual:SetAttribute("OceanTD_ScaleMult", scale)
	end
	PersistenceService.save(player, GridService.snapshot(plotId))
	log("Size", placeId, "class", want, "tier", newTier, "d", newDiam)
	return {
		ok = true,
		diameter = newDiam,
		sizeClass = want,
		sizeTier = newTier,
		variantIndex = variant,
		scaleMult = scale,
	}
end

function PlacementService.setCoralColor(
	player: Player,
	placeId: string,
	colorIndex: number,
	colorR: number?,
	colorG: number?,
	colorB: number?
): { ok: boolean, errorCode: string?, colorIndex: number?, colorR: number?, colorG: number?, colorB: number? }
	if typeof(placeId) ~= "string" or placeId == "" then
		return { ok = false, errorCode = "BadRequest" }
	end
	if not PlayerSession.canSave(player) then
		return { ok = false, errorCode = "NotReady" }
	end
	local plotId = PlotService.getOwnerPlotId(player)
	if not plotId then
		return { ok = false, errorCode = "NoPlot" }
	end
	local visual = findVisualByPlaceId(plotId, placeId)
	if not visual then
		return { ok = false, errorCode = "Missing" }
	end
	local idx = PlotOutlineColors.clampCoralIndex(colorIndex)
	local paint = PlotOutlineColors.resolveCoralPaint(idx, colorR, colorG, colorB)
	local slot = PlotService.getSlot(plotId)
	if not slot then
		return { ok = false, errorCode = "BadPlot" }
	end
	local localPos = GridMath.worldToPlotLocal(visual.Position, slot.cframe)
	local gx, gy, gz = GridMath.worldToGrid(localPos, Vector3.zero)
	if not GridService.setColorAtGrid(plotId, gx, gy, gz, idx, paint.R, paint.G, paint.B) then
		return { ok = false, errorCode = "Missing" }
	end
	visual:SetAttribute("OceanTD_ColorIndex", idx)
	CoralVisual.setRestColor(visual, paint)
	-- Live grid/visual now; DataStore after 5s idle so rapid dice rolls don't thrash saves.
	scheduleCoralColorSave(player, plotId)
	log("Color", placeId, "index", idx)
	return { ok = true, colorIndex = idx, colorR = paint.R, colorG = paint.G, colorB = paint.B }
end

function PlacementService.init()
	getPlacedRoot()
	log("Init")
end

return PlacementService
