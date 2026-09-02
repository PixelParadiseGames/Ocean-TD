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
local LayoutRestore = require(oceanShared:WaitForChild("LayoutRestore"))
local SpeciesCatalog = require(oceanShared:WaitForChild("SpeciesCatalog"))
local CoralVisual = require(oceanShared:WaitForChild("CoralVisual"))
local CoralSize = require(oceanShared:WaitForChild("CoralSize"))
local ItemCatalog = require(oceanShared:WaitForChild("ItemCatalog"))
local SkillStages = require(oceanShared:WaitForChild("SkillStages"))
local PlotOutlineColors = require(oceanShared:WaitForChild("PlotOutlineColors"))
local BrainStack = require(oceanShared:WaitForChild("BrainStack"))

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
	scaleWidth: number?,
	scaleHeight: number?,
	facingYaw: number?,
	webColorR: number?,
	webColorG: number?,
	webColorB: number?,
}

export type PlaceOpts = {
	diameter: number?,
	variantIndex: number?,
	scaleMult: number?,
	sizeClass: number?,
	scaleWidth: number?,
	scaleHeight: number?,
	facingYaw: number?,
	-- Opt-in brain stack: only nest when client snapped to a host.
	parentPlaceId: string?,
	-- Hue stack to debit when placing (client shuffle selection).
	placementHue: number?,
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
	facingYaw: number?,
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
		PersistenceService.save(player, PlacementService.snapshotLayout(plotId))
		log("Color save (debounced)", player.Name)
	end)
end

function PlacementService.clearPendingColorSave(player: Player)
	colorSaveTokenByUser[player.UserId] = nil
end

-- Write paint onto a grid cell (by placeId preferred).
local function writeCellColor(
	plotId: string,
	placeId: string?,
	gx: number?,
	gy: number?,
	gz: number?,
	colorIndex: number?,
	colorR: number?,
	colorG: number?,
	colorB: number?,
	webR: number?,
	webG: number?,
	webB: number?
): boolean
	local cell: any = nil
	if typeof(placeId) == "string" and placeId ~= "" then
		cell = GridService.findCellByPlaceId(plotId, placeId)
	end
	if not cell and typeof(gx) == "number" and typeof(gy) == "number" and typeof(gz) == "number" then
		cell = GridService.getCellAtGrid(plotId, gx, gy, gz)
	end
	if not cell then
		return false
	end
	local ok = GridService.setColorAtGrid(plotId, cell.gx, cell.gy, cell.gz, colorIndex, colorR, colorG, colorB)
	if ok and typeof(webR) == "number" and typeof(webG) == "number" and typeof(webB) == "number" then
		GridService.setSeaFanExtras(plotId, cell.gx, cell.gy, cell.gz, nil, nil, nil, webR, webG, webB)
	end
	return ok
end

-- Pull color attrs from a live visual when the grid cell has no saved paint yet.
local function enrichLayoutObjFromVisual(obj: any, visual: BasePart)
	local hasCellPaint = typeof(obj.colorIndex) == "number"
		or (typeof(obj.colorR) == "number" and typeof(obj.colorG) == "number" and typeof(obj.colorB) == "number")
	if hasCellPaint then
		return
	end
	local idxAttr = visual:GetAttribute("OceanTD_ColorIndex")
	if typeof(idxAttr) == "number" then
		obj.colorIndex = PlotOutlineColors.clampCoralIndex(idxAttr)
	end
	local r = visual:GetAttribute("OceanTD_RestR")
	local g = visual:GetAttribute("OceanTD_RestG")
	local b = visual:GetAttribute("OceanTD_RestB")
	if typeof(r) == "number" and typeof(g) == "number" and typeof(b) == "number" then
		obj.colorR = math.clamp(r, 0, 1)
		obj.colorG = math.clamp(g, 0, 1)
		obj.colorB = math.clamp(b, 0, 1)
	else
		obj.colorR = math.clamp(visual.Color.R, 0, 1)
		obj.colorG = math.clamp(visual.Color.G, 0, 1)
		obj.colorB = math.clamp(visual.Color.B, 0, 1)
	end
	local wr = visual:GetAttribute("OceanTD_WebRestR")
	local wg = visual:GetAttribute("OceanTD_WebRestG")
	local wb = visual:GetAttribute("OceanTD_WebRestB")
	if typeof(wr) ~= "number" then
		wr = visual:GetAttribute("OceanTD_WebR")
		wg = visual:GetAttribute("OceanTD_WebG")
		wb = visual:GetAttribute("OceanTD_WebB")
	end
	if typeof(wr) == "number" and typeof(wg) == "number" and typeof(wb) == "number" then
		obj.webColorR = math.clamp(wr, 0, 1)
		obj.webColorG = math.clamp(wg, 0, 1)
		obj.webColorB = math.clamp(wb, 0, 1)
	end
end

-- After a fresh place, persist species-default RGB on the cell (no palette index until recolor).
local function syncDefaultVisualPaintToCell(plotId: string, gx: number, gy: number, gz: number, visual: BasePart)
	local cell = GridService.getCellAtGrid(plotId, gx, gy, gz)
	if not cell then
		return
	end
	local idxAttr = visual:GetAttribute("OceanTD_ColorIndex")
	if typeof(idxAttr) == "number" then
		cell.colorIndex = PlotOutlineColors.clampCoralIndex(idxAttr)
	end
	local _, color = CoralVisual.readRestLook(visual)
	cell.colorR = color.R
	cell.colorG = color.G
	cell.colorB = color.B
	local wr = visual:GetAttribute("OceanTD_WebRestR")
	local wg = visual:GetAttribute("OceanTD_WebRestG")
	local wb = visual:GetAttribute("OceanTD_WebRestB")
	if typeof(wr) == "number" and typeof(wg) == "number" and typeof(wb) == "number" then
		cell.webColorR = wr
		cell.webColorG = wg
		cell.webColorB = wb
	end
	if typeof(cell.colorIndex) ~= "number" then
		CoralVisual.snapshotDefaultRestLook(visual)
	end
end

local function resolveRecycleHue(visual: BasePart?, cell: any?): number
	if visual then
		local colorAttr = visual:GetAttribute("OceanTD_ColorIndex")
		if typeof(colorAttr) == "number" then
			return PlotOutlineColors.clampCoralIndex(colorAttr)
		end
		local seedAttr = visual:GetAttribute("OceanTD_SeedHue")
		if typeof(seedAttr) == "number" then
			return PlotOutlineColors.clampCoralIndex(seedAttr)
		end
	end
	if cell then
		if typeof(cell.colorIndex) == "number" then
			return PlotOutlineColors.clampCoralIndex(cell.colorIndex)
		end
		if typeof(cell.seedHue) == "number" then
			return PlotOutlineColors.clampCoralIndex(cell.seedHue)
		end
	end
	return PlotOutlineColors.DEFAULT_INDEX
end

local function countHuePaintedOnPlot(
	plotId: string,
	itemId: string,
	hue: number,
	excludePlaceId: string?
): number
	local painted = 0
	GridService.forEachCell(plotId, function(cell)
		if cell.id ~= itemId then
			return
		end
		if excludePlaceId and cell.placeId == excludePlaceId then
			return
		end
		if typeof(cell.colorIndex) == "number" and PlotOutlineColors.clampCoralIndex(cell.colorIndex) == PlotOutlineColors.clampCoralIndex(hue) then
			painted += 1
		end
	end)
	return painted
end

local function countHueGenericOnPlot(
	plotId: string,
	itemId: string,
	hue: number,
	excludePlaceId: string?
): number
	local generic = 0
	GridService.forEachCell(plotId, function(cell)
		if cell.id ~= itemId then
			return
		end
		if excludePlaceId and cell.placeId == excludePlaceId then
			return
		end
		if typeof(cell.colorIndex) == "number" then
			return
		end
		if typeof(cell.seedHue) == "number" and PlotOutlineColors.clampCoralIndex(cell.seedHue) == PlotOutlineColors.clampCoralIndex(hue) then
			generic += 1
		end
	end)
	return generic
end

local function countHueSeedBackedPainted(
	plotId: string,
	itemId: string,
	hue: number,
	excludePlaceId: string?
): number
	local backed = 0
	GridService.forEachCell(plotId, function(cell)
		if cell.id ~= itemId then
			return
		end
		if excludePlaceId and cell.placeId == excludePlaceId then
			return
		end
		if typeof(cell.colorIndex) ~= "number" then
			return
		end
		if PlotOutlineColors.clampCoralIndex(cell.colorIndex) ~= PlotOutlineColors.clampCoralIndex(hue) then
			return
		end
		if typeof(cell.seedHue) == "number" and PlotOutlineColors.clampCoralIndex(cell.seedHue) == PlotOutlineColors.clampCoralIndex(hue) then
			backed += 1
		end
	end)
	return backed
end

local function canAssignHue(
	player: Player,
	plotId: string,
	itemId: string,
	placeId: string,
	newHue: number,
	cell: any
): boolean
	local hue = PlotOutlineColors.clampCoralIndex(newHue)
	local currentHue: number? = nil
	if typeof(cell.colorIndex) == "number" then
		currentHue = PlotOutlineColors.clampCoralIndex(cell.colorIndex)
	elseif typeof(cell) == "table" then
		local attr = cell.colorIndex
		if typeof(attr) == "number" then
			currentHue = PlotOutlineColors.clampCoralIndex(attr)
		end
	end
	if currentHue == hue then
		return true
	end
	-- Coral placed with this hue seed can be painted without spending another slot.
	if typeof(cell.colorIndex) ~= "number" and typeof(cell.seedHue) == "number" and PlotOutlineColors.clampCoralIndex(cell.seedHue) == hue then
		return true
	end
	local owned = PersistenceService.getHueSeedCount(player, itemId, hue)
	local paintedExcl = countHuePaintedOnPlot(plotId, itemId, hue, placeId)
	local genericTotal = countHueGenericOnPlot(plotId, itemId, hue, nil)
	local backedExcl = countHueSeedBackedPainted(plotId, itemId, hue, placeId)
	return paintedExcl + 1 <= owned + genericTotal + backedExcl
end

local function stampSeedHue(plotId: string, gx: number, gy: number, gz: number, visual: BasePart, seedHue: number)
	local cell = GridService.getCellAtGrid(plotId, gx, gy, gz)
	local hue = PlotOutlineColors.clampCoralIndex(seedHue)
	if cell then
		cell.seedHue = hue
	end
	visual:SetAttribute("OceanTD_SeedHue", hue)
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

function PlacementService.validateWorldPos(player: Player, worldPos: Vector3, allowBrainStack: boolean?): (boolean, string?, string?)
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
		if allowBrainStack then
			local host = GridService.findNearestBrainHost(plotId, localPos, nil, nil, nil)
			if host then
				return true, nil, plotId
			end
			local gx, _, gz = GridMath.worldToGrid(localPos, Vector3.zero)
			local top = GridService.findTopBrainInColumn(plotId, gx, gz)
			if top then
				return true, nil, plotId
			end
		end
		return false, "SpotTaken", plotId
	end
	-- Empty cell but may still be stacking onto a nearby offset brain.
	if allowBrainStack then
		local host = GridService.findNearestBrainHost(plotId, localPos, nil, nil, nil)
		if host then
			return true, nil, plotId
		end
	end
	return true, nil, plotId
end

-- Server Brain stack: only nests when client opts in with parentPlaceId (dot snap).
local function resolveBrainStackLocal(
	plotId: string,
	localPos: Vector3,
	newDiam: number,
	ignoreGx: number?,
	ignoreGy: number?,
	ignoreGz: number?,
	parentPlaceId: string?
): (Vector3, number, number, number, any?)
	local gx, gy, gz = GridMath.worldToGrid(localPos, Vector3.zero)
	if typeof(parentPlaceId) ~= "string" or parentPlaceId == "" then
		return localPos, gx, gy, gz, nil
	end
	local host = GridService.findCellByPlaceId(plotId, parentPlaceId)
	if not host or host.id ~= "BrainCoral" then
		return localPos, gx, gy, gz, nil
	end
	if ignoreGx == host.gx and ignoreGy == host.gy and ignoreGz == host.gz then
		return localPos, gx, gy, gz, nil
	end
	if not GridService.brainHasFreeSlot(plotId, host, ignoreGx, ignoreGy, ignoreGz) then
		return localPos, gx, gy, gz, nil
	end
	local d0 = if typeof(host.diameter) == "number" and host.diameter > 0 then host.diameter else 4
	local hostPos = Vector3.new(host.lx, host.ly, host.lz)
	local ox = localPos.X - host.lx
	local oz = localPos.Z - host.lz
	local horiz = math.sqrt(ox * ox + oz * oz)
	local maxSide = d0 * 0.5 + newDiam * 0.45
	local stacked: Vector3
	if localPos.Y > host.ly + 0.15 and horiz <= maxSide + 0.35 then
		stacked = localPos
	else
		stacked = BrainStack.topNestCenter(hostPos, d0, newDiam, ox, oz)
	end
	local drift = BrainStack.horizontalDist(Vector3.new(host.lx, 0, host.lz), Vector3.new(stacked.X, 0, stacked.Z))
	if drift > BrainStack.MAX_ROOT_DRIFT then
		local scale = BrainStack.MAX_ROOT_DRIFT / drift
		stacked = Vector3.new(
			host.lx + (stacked.X - host.lx) * scale,
			stacked.Y,
			host.lz + (stacked.Z - host.lz) * scale
		)
	end
	local sgx, _, sgz = GridMath.worldToGrid(stacked, Vector3.zero)
	local freeGy = GridService.nextFreeGyInColumn(plotId, sgx, sgz, math.max(host.gy + 1, 0))
	return stacked, sgx, freeGy, sgz, host
end

function PlacementService.spawnVisual(
	plotId: string,
	speciesId: string,
	worldPos: Vector3,
	color: Color3?,
	diameter: number?,
	sizeClass: number?,
	variantIndex: number?,
	scaleMult: number?,
	scaleWidth: number?,
	scaleHeight: number?,
	facingYaw: number?,
	webColor: Color3?
): BasePart?
	local slot = PlotService.getSlot(plotId)
	local part = CoralVisual.create(speciesId, worldPos, {
		ghost = false,
		color = color,
		webColor = webColor,
		diameter = diameter,
		sizeClass = sizeClass,
		variantIndex = variantIndex,
		scaleMult = scaleMult,
		scaleWidth = scaleWidth,
		scaleHeight = scaleHeight,
		facingYaw = facingYaw,
		plotCFrame = if slot then slot.cframe else nil,
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
			-- Mesh species (SeaGrass/SeaFan) sit above the plant point — use grid anchor.
			local sample = CoralVisual.readGridAnchor(inst) or inst.Position
			local lp = GridMath.worldToPlotLocal(sample, slot.cframe)
			local ax, ay, az = GridMath.worldToGrid(lp, Vector3.zero)
			if ax == gx and ay == gy and az == gz then
				return inst
			end
		end
	end
	return nil
end

-- Snapshot live grid. SeaFan facingYaw lives on the cell (set at place/move) — do not
-- re-derive from mesh LookVector (that corrupted saves; FBX fronts ≠ Angles yaw).
function PlacementService.snapshotLayout(plotId: string): { any }
	local layout = GridService.snapshot(plotId)
	-- Cell color can lag the visual (legacy places / failed grid writes). Live paint is source of truth.
	for _, obj in ipairs(layout) do
		local pid = obj.placeId
		if typeof(pid) == "string" and pid ~= "" then
			local visual = findVisualByPlaceId(plotId, pid)
			if visual then
				enrichLayoutObjFromVisual(obj, visual)
				-- Backfill grid cells that still lack paint after legacy places.
				if typeof(obj.colorR) == "number" and typeof(obj.colorG) == "number" and typeof(obj.colorB) == "number" then
					writeCellColor(
						plotId,
						pid,
						obj.gx,
						obj.gy,
						obj.gz,
						obj.colorIndex,
						obj.colorR,
						obj.colorG,
						obj.colorB,
						obj.webColorR,
						obj.webColorG,
						obj.webColorB
					)
				end
			end
		end
	end
	return layout
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
		local webColor: Color3? = nil
		if typeof(cell.webColorR) == "number" and typeof(cell.webColorG) == "number" and typeof(cell.webColorB) == "number" then
			webColor = Color3.new(cell.webColorR, cell.webColorG, cell.webColorB)
		end
		local paintIdx: number? = if typeof(cell.colorIndex) == "number"
			then PlotOutlineColors.clampCoralIndex(cell.colorIndex)
			else nil
		local paint: Color3? = nil
		if paintIdx then
			paint = PlotOutlineColors.resolveCoralPaint(paintIdx, cell.colorR, cell.colorG, cell.colorB)
		elseif typeof(cell.colorR) == "number" and typeof(cell.colorG) == "number" and typeof(cell.colorB) == "number" then
			paint = Color3.new(cell.colorR, cell.colorG, cell.colorB)
		end
		local visual = PlacementService.spawnVisual(
			plotId,
			species.speciesId,
			world,
			paint,
			cell.diameter,
			cell.sizeClass,
			cell.variantIndex,
			cell.scaleMult,
			cell.scaleWidth,
			cell.scaleHeight,
			cell.facingYaw,
			webColor
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
			if typeof(cell.scaleWidth) == "number" then
				visual:SetAttribute("OceanTD_ScaleWidth", cell.scaleWidth)
			end
			if typeof(cell.scaleHeight) == "number" then
				visual:SetAttribute("OceanTD_ScaleHeight", cell.scaleHeight)
			end
			-- Always re-apply saved yaw (plot-local) so load matches plant on any plot.
			if CoralVisual.needsFacingYaw(species.speciesId) then
				local yaw = if typeof(cell.facingYaw) == "number" and cell.facingYaw == cell.facingYaw
					then cell.facingYaw
					else CoralVisual.readFacingYaw(visual)
				visual:SetAttribute("OceanTD_FacingYaw", yaw)
				CoralVisual.alignMeshToSurface(visual, world, yaw, nil, boundsCFrame)
			elseif typeof(cell.facingYaw) == "number" then
				visual:SetAttribute("OceanTD_FacingYaw", cell.facingYaw)
				CoralVisual.alignMeshToSurface(visual, world, cell.facingYaw, nil, boundsCFrame)
			end
			if paint then
				if paintIdx then
					visual:SetAttribute("OceanTD_ColorIndex", paintIdx)
				end
				CoralVisual.setRestColor(visual, paint, webColor)
				if paintIdx then
					cell.colorIndex = paintIdx
				end
				cell.colorR = paint.R
				cell.colorG = paint.G
				cell.colorB = paint.B
			end
			-- Stable stack identity.
			if typeof(cell.placeId) == "string" and cell.placeId ~= "" then
				visual:SetAttribute("OceanTD_PlaceId", cell.placeId)
			else
				local pid = visual:GetAttribute("OceanTD_PlaceId")
				if typeof(pid) == "string" then
					cell.placeId = pid
				end
			end
			if typeof(cell.parentPlaceId) == "string" and cell.parentPlaceId ~= "" then
				visual:SetAttribute("OceanTD_ParentPlaceId", cell.parentPlaceId)
			end
			local seedHue: number? = if typeof(cell.seedHue) == "number"
				then PlotOutlineColors.clampCoralIndex(cell.seedHue)
				else nil
			if not seedHue and paintIdx then
				-- Legacy saves: painted corals consumed a seed at placement before seedHue was persisted.
				seedHue = paintIdx
				cell.seedHue = paintIdx
			end
			if seedHue then
				stampSeedHue(plotId, cell.gx, cell.gy, cell.gz, visual, seedHue)
			end
		end
	end)
	PlacementService.rebuildBrainParentLinks(plotId)
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
	scaleMult: number?,
	seaFanExtras: {
		scaleWidth: number?,
		scaleHeight: number?,
		facingYaw: number?,
		webColorR: number?,
		webColorG: number?,
		webColorB: number?,
	}?,
	stackMeta: {
		placeId: string?,
		parentPlaceId: string?,
	}?
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
	if not PlayerSession.canMutatePlot(player) then
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

	local debitHueForSave: number? = nil
	if shouldConsume then
		debitHueForSave = if typeof(colorIndex) == "number"
			then PlotOutlineColors.clampCoralIndex(colorIndex)
			else PlotOutlineColors.DEFAULT_INDEX
		local debited = select(1, PersistenceService.tryDebitHueSeed(player, itemId, debitHueForSave, 1))
		if not debited then
			return { ok = false, errorCode = "NoSeeds" }
		end
	end

	-- exactPos = plot.CFrame:PointToWorldSpace(VisualPos) — never re-snap to terrain/grid center.
	local worldPos = GridMath.plotLocalToWorld(visualLocal, slot.cframe)
	local paintIdx = if typeof(colorIndex) == "number"
		then PlotOutlineColors.clampCoralIndex(colorIndex)
		else nil
	local paintColor = if paintIdx
		then PlotOutlineColors.resolveCoralPaint(paintIdx, colorR, colorG, colorB)
		elseif typeof(colorR) == "number" and typeof(colorG) == "number" and typeof(colorB) == "number"
		then Color3.new(colorR, colorG, colorB)
		else nil
	local extras = seaFanExtras or {}
	local class = if typeof(sizeClass) == "number"
		then CoralSize.clampTier(sizeClass)
		elseif typeof(diameter) == "number" and diameter > 0
		then CoralSize.classFromDiameter(diameter)
		else 1
	local variant = if CoralVisual.isMeshSpecies(species.speciesId)
		then CoralVisual.clampMeshVariant(variantIndex, species.speciesId)
		else nil
	local scale: number? = nil
	local scaleWidth: number? = nil
	local scaleHeight: number? = nil
	local facingYaw: number? = nil
	local webColor: Color3? = nil
	if CoralVisual.isSeaFan(species.speciesId) then
		scale = CoralVisual.sanitizeSeaFanAxis(scaleMult)
		scaleWidth = CoralVisual.sanitizeSeaFanAxis(extras.scaleWidth)
		scaleHeight = CoralVisual.sanitizeSeaFanAxis(extras.scaleHeight)
		facingYaw = if typeof(extras.facingYaw) == "number" then extras.facingYaw else CoralVisual.randomFacingYaw()
		if typeof(extras.webColorR) == "number" and typeof(extras.webColorG) == "number" and typeof(extras.webColorB) == "number" then
			webColor = Color3.new(extras.webColorR, extras.webColorG, extras.webColorB)
		end
	elseif CoralVisual.isMeshSpecies(species.speciesId) then
		scale = CoralVisual.sanitizeMeshScale(scaleMult, species.speciesId)
		if CoralVisual.needsFacingYaw(species.speciesId) then
			facingYaw = if typeof(extras.facingYaw) == "number" then extras.facingYaw else CoralVisual.randomFacingYaw()
		end
		if CoralVisual.isMainAccentMesh(species.speciesId)
			and typeof(extras.webColorR) == "number"
			and typeof(extras.webColorG) == "number"
			and typeof(extras.webColorB) == "number"
		then
			webColor = Color3.new(extras.webColorR, extras.webColorG, extras.webColorB)
		end
	end
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
		CoralSize.clampTier(sizeTier or class),
		class,
		paintIdx,
		if paintColor then paintColor.R else nil,
		if paintColor then paintColor.G else nil,
		if paintColor then paintColor.B else nil,
		variant,
		scale
	)
	if not occupied then
		if shouldConsume and debitHueForSave then
			PersistenceService.creditHueSeed(player, itemId, debitHueForSave, 1)
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
		scale,
		scaleWidth,
		scaleHeight,
		facingYaw,
		webColor
	)
	if not visual then
		GridService.vacate(plotId, visualLocal.X, visualLocal.Y, visualLocal.Z, gx, gy, gz)
		if shouldConsume and debitHueForSave then
			PersistenceService.creditHueSeed(player, itemId, debitHueForSave, 1)
		end
		return { ok = false, errorCode = "VisualFail" }
	end

	if CoralVisual.isSeaFan(species.speciesId) then
		local rx: number
		local ry: number
		local rz: number
		if typeof(gx) == "number" and typeof(gy) == "number" and typeof(gz) == "number" then
			rx, ry, rz = math.round(gx), math.round(gy), math.round(gz)
		else
			rx, ry, rz = GridMath.worldToGrid(visualLocal, Vector3.zero)
		end
		GridService.setSeaFanExtras(
			plotId,
			rx,
			ry,
			rz,
			scaleWidth,
			scaleHeight,
			facingYaw,
			if webColor then webColor.R else nil,
			if webColor then webColor.G else nil,
			if webColor then webColor.B else nil
		)
		if typeof(facingYaw) == "number" then
			visual:SetAttribute("OceanTD_FacingYaw", facingYaw)
			CoralVisual.alignMeshToSurface(visual, worldPos, facingYaw, nil, slot.cframe)
		end
		if paintColor and webColor then
			CoralVisual.setRestColor(visual, paintColor, webColor)
		end
	elseif CoralVisual.isMainAccentMesh(species.speciesId) then
		local rx: number
		local ry: number
		local rz: number
		if typeof(gx) == "number" and typeof(gy) == "number" and typeof(gz) == "number" then
			rx, ry, rz = math.round(gx), math.round(gy), math.round(gz)
		else
			rx, ry, rz = GridMath.worldToGrid(visualLocal, Vector3.zero)
		end
		GridService.setSeaFanExtras(
			plotId,
			rx,
			ry,
			rz,
			nil,
			nil,
			facingYaw,
			if webColor then webColor.R else nil,
			if webColor then webColor.G else nil,
			if webColor then webColor.B else nil
		)
		if typeof(facingYaw) == "number" then
			visual:SetAttribute("OceanTD_FacingYaw", facingYaw)
			CoralVisual.alignMeshToSurface(visual, worldPos, facingYaw, nil, slot.cframe)
		end
		if paintColor then
			CoralVisual.setRestColor(visual, paintColor, webColor)
		end
	elseif CoralVisual.needsFacingYaw(species.speciesId) and typeof(facingYaw) == "number" then
		local rx: number
		local ry: number
		local rz: number
		if typeof(gx) == "number" and typeof(gy) == "number" and typeof(gz) == "number" then
			rx, ry, rz = math.round(gx), math.round(gy), math.round(gz)
		else
			rx, ry, rz = GridMath.worldToGrid(visualLocal, Vector3.zero)
		end
		GridService.setSeaFanExtras(plotId, rx, ry, rz, nil, nil, facingYaw, nil, nil, nil)
		visual:SetAttribute("OceanTD_FacingYaw", facingYaw)
		CoralVisual.alignMeshToSurface(visual, worldPos, facingYaw, nil, slot.cframe)
	end

	local placeIdAttr = visual:GetAttribute("OceanTD_PlaceId")
	local savedPlaceId = if stackMeta and typeof(stackMeta.placeId) == "string" and stackMeta.placeId ~= ""
		then stackMeta.placeId
		else nil
	local placeId = savedPlaceId
		or (if typeof(placeIdAttr) == "string" then placeIdAttr else HttpService:GenerateGUID(false))
	visual:SetAttribute("OceanTD_PlaceId", placeId)
	visual:SetAttribute("OceanTD_ItemId", itemId)
	visual:SetAttribute("OceanTD_SpeciesId", species.speciesId)
	local savedParent = if stackMeta and typeof(stackMeta.parentPlaceId) == "string" and stackMeta.parentPlaceId ~= ""
		then stackMeta.parentPlaceId
		else nil
	if savedParent then
		visual:SetAttribute("OceanTD_ParentPlaceId", savedParent)
	end
	if paintIdx then
		visual:SetAttribute("OceanTD_ColorIndex", paintIdx)
		if paintColor then
			CoralVisual.setRestColor(visual, paintColor, webColor)
		end
	end
	local tier = CoralSize.clampTier(sizeTier or class)
	CoralSize.applyToPart(visual, diameter or visual.Size.Y, class, tier)
	-- Re-apply yaw after attrs/size so load matches the saved facing.
	if CoralVisual.needsFacingYaw(species.speciesId) and typeof(facingYaw) == "number" then
		visual:SetAttribute("OceanTD_FacingYaw", facingYaw)
		CoralVisual.alignMeshToSurface(visual, worldPos, facingYaw, nil, slot.cframe)
	end

	local rx: number
	local ry: number
	local rz: number
	if typeof(gx) == "number" and typeof(gy) == "number" and typeof(gz) == "number" then
		rx, ry, rz = math.round(gx), math.round(gy), math.round(gz)
	else
		rx, ry, rz = GridMath.worldToGrid(visualLocal, Vector3.zero)
	end
	GridService.setPlaceMeta(plotId, rx, ry, rz, placeId, savedParent)
	-- Ensure grid cell keeps full visual meta (snapshot/load must not drop upgrades/colors).
	local cell = GridService.getCellAtGrid(plotId, rx, ry, rz)
	if cell then
		local dAttr = visual:GetAttribute("OceanTD_Diameter")
		local resolvedDiam = if typeof(dAttr) == "number" and dAttr > 0
			then dAttr
			elseif typeof(diameter) == "number" and diameter > 0
			then diameter
			else math.max(visual.Size.X, visual.Size.Y, visual.Size.Z)
		cell.diameter = resolvedDiam
		cell.sizeClass = class
		cell.sizeTier = tier
		if paintIdx then
			cell.colorIndex = paintIdx
		end
		if paintColor then
			cell.colorR = paintColor.R
			cell.colorG = paintColor.G
			cell.colorB = paintColor.B
		end
		if webColor then
			cell.webColorR = webColor.R
			cell.webColorG = webColor.G
			cell.webColorB = webColor.B
		end
		if typeof(variant) == "number" then
			cell.variantIndex = variant
		end
		if typeof(scale) == "number" then
			cell.scaleMult = scale
		end
		if typeof(debitHueForSave) == "number" then
			cell.seedHue = debitHueForSave
		end
	end
	if typeof(debitHueForSave) == "number" then
		stampSeedHue(plotId, rx, ry, rz, visual, debitHueForSave)
	end
	if not paintIdx then
		CoralVisual.snapshotDefaultRestLook(visual)
	end

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
		local parentId = raw.parentPlaceId
		return {
			diameter = tonumber(raw.diameter),
			variantIndex = tonumber(raw.variantIndex),
			scaleMult = tonumber(raw.scaleMult),
			sizeClass = tonumber(raw.sizeClass),
			scaleWidth = tonumber(raw.scaleWidth),
			scaleHeight = tonumber(raw.scaleHeight),
			facingYaw = tonumber(raw.facingYaw),
			parentPlaceId = if typeof(parentId) == "string" and parentId ~= "" then parentId else nil,
			placementHue = if typeof(raw.placementHue) == "number" then raw.placementHue else nil,
		}
	end
	return {}
end

-- consumeSeed: player places debit inventory. Internal hydrate/load can pass false.
-- placeOpts: legacy number diameter, or { diameter, variantIndex, scaleMult, sizeClass, ... }.
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

	local isBrain = BrainStack.isBrainId(species.speciesId) or BrainStack.isBrainId(itemId)
	local ok, err, plotId = PlacementService.validateWorldPos(player, worldPos, isBrain)
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

	local seedHue: number? = nil
	if shouldConsume then
		seedHue = if typeof(opts.placementHue) == "number"
			then PlotOutlineColors.clampCoralIndex(opts.placementHue)
			else nil
		if not seedHue then
			return { ok = false, errorCode = "NoSeeds" }
		end
		local debited = select(1, PersistenceService.tryDebitHueSeed(player, itemId, seedHue, 1))
		if not debited then
			return { ok = false, errorCode = "NoSeeds" }
		end
	end

	-- Snap visual to ray hit pos (client sends terrain hit); store exact VisualPos + rounded grid key.
	local diameter: number? = nil
	local sizeClass = 1
	local variant: number? = nil
	local scale: number? = nil
	local scaleWidth: number? = nil
	local scaleHeight: number? = nil
	local facingYaw: number? = nil
	local gx: number
	local gy: number
	local gz: number
	local brainHostCell: any = nil
	if isBrain then
		-- Prefer client ghost size so preview matches the placed coral.
		diameter = CoralVisual.sanitizeBrainDiameter(opts.diameter)
		local stackedLocal
		stackedLocal, gx, gy, gz, brainHostCell =
			resolveBrainStackLocal(plotId, localPos, diameter, nil, nil, nil, opts.parentPlaceId)
		localPos = stackedLocal
		local slot = PlotService.getSlot(plotId)
		if slot then
			worldPos = GridMath.plotLocalToWorld(localPos, slot.cframe)
		end
		-- Empty ground: still reject if a non-brain (or conflicting) cell sits here.
		if GridService.getCellAtGrid(plotId, gx, gy, gz) then
			if shouldConsume and seedHue then
				PersistenceService.creditHueSeed(player, itemId, seedHue, 1)
			end
			return { ok = false, errorCode = "SpotTaken" }
		end
	elseif CoralVisual.isMeshSpecies(species.speciesId) then
		sizeClass = CoralSize.clampTier(opts.sizeClass or 1)
		variant = CoralVisual.clampMeshVariant(opts.variantIndex, species.speciesId)
		if CoralVisual.isSeaFan(species.speciesId) then
			scale = CoralVisual.sanitizeSeaFanAxis(opts.scaleMult)
			scaleWidth = CoralVisual.sanitizeSeaFanAxis(opts.scaleWidth)
			scaleHeight = CoralVisual.sanitizeSeaFanAxis(opts.scaleHeight)
			facingYaw = if typeof(opts.facingYaw) == "number" and opts.facingYaw == opts.facingYaw
				then opts.facingYaw
				else CoralVisual.randomFacingYaw()
		else
			scale = CoralVisual.sanitizeMeshScale(opts.scaleMult, species.speciesId)
			if CoralVisual.needsFacingYaw(species.speciesId) then
				facingYaw = if typeof(opts.facingYaw) == "number" and opts.facingYaw == opts.facingYaw
					then opts.facingYaw
					else CoralVisual.randomFacingYaw()
			end
		end
		gx, gy, gz = GridMath.worldToGrid(localPos, Vector3.zero)
	else
		gx, gy, gz = GridMath.worldToGrid(localPos, Vector3.zero)
	end
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
		if shouldConsume and seedHue then
			PersistenceService.creditHueSeed(player, itemId, seedHue, 1)
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
		scale,
		scaleWidth,
		scaleHeight,
		facingYaw,
		nil
	)
	if not visual then
		warnPlace("Visual spawn failed after occupy — rolling back cell")
		GridService.vacate(plotId, localPos.X, localPos.Y, localPos.Z, gx, gy, gz)
		if shouldConsume and seedHue then
			PersistenceService.creditHueSeed(player, itemId, seedHue, 1)
		end
		return { ok = false, errorCode = "VisualFail" }
	end

	-- Persist resolved height for mesh species (Size.Y after scale jitter).
	if CoralVisual.isMeshSpecies(species.speciesId) then
		diameter = visual.Size.Y
		local cell = GridService.getCellAtGrid(plotId, gx, gy, gz)
		if cell then
			cell.diameter = diameter
		end
		if CoralVisual.isSeaFan(species.speciesId) then
			GridService.setSeaFanExtras(
				plotId,
				gx,
				gy,
				gz,
				scaleWidth,
				scaleHeight,
				facingYaw,
				nil,
				nil,
				nil
			)
			local slotCf = PlotService.getSlot(plotId)
			local pcf = if slotCf then slotCf.cframe else nil
			if typeof(facingYaw) == "number" then
				visual:SetAttribute("OceanTD_FacingYaw", facingYaw)
				CoralVisual.alignMeshToSurface(visual, worldPos, facingYaw, nil, pcf)
			end
		elseif CoralVisual.needsFacingYaw(species.speciesId) and typeof(facingYaw) == "number" then
			GridService.setSeaFanExtras(plotId, gx, gy, gz, nil, nil, facingYaw, nil, nil, nil)
			local slotCf = PlotService.getSlot(plotId)
			local pcf = if slotCf then slotCf.cframe else nil
			visual:SetAttribute("OceanTD_FacingYaw", facingYaw)
			CoralVisual.alignMeshToSurface(visual, worldPos, facingYaw, nil, pcf)
		end
	end

	local placeIdAttr = visual:GetAttribute("OceanTD_PlaceId")
	local placeId = if typeof(placeIdAttr) == "string" then placeIdAttr else HttpService:GenerateGUID(false)
	visual:SetAttribute("OceanTD_PlaceId", placeId)
	visual:SetAttribute("OceanTD_ItemId", itemId)
	visual:SetAttribute("OceanTD_SpeciesId", species.speciesId)
	syncDefaultVisualPaintToCell(plotId, gx, gy, gz, visual)
	if seedHue then
		stampSeedHue(plotId, gx, gy, gz, visual, seedHue)
	end
	if brainHostCell then
		local slot = PlotService.getSlot(plotId)
		local hostVis: BasePart? = nil
		if typeof(brainHostCell.placeId) == "string" and brainHostCell.placeId ~= "" then
			hostVis = findVisualByPlaceId(plotId, brainHostCell.placeId)
		end
		if not hostVis and slot then
			for _, inst in ipairs(getPlotFolder(plotId):GetChildren()) do
				if inst:IsA("BasePart") and BrainStack.isBrainId(inst:GetAttribute("OceanTD_SpeciesId")) then
					local lp = GridMath.worldToPlotLocal(inst.Position, slot.cframe)
					if math.abs(lp.X - brainHostCell.lx) < 0.05
						and math.abs(lp.Y - brainHostCell.ly) < 0.05
						and math.abs(lp.Z - brainHostCell.lz) < 0.05
					then
						hostVis = inst
						break
					end
				end
			end
		end
		if hostVis then
			local parentId = hostVis:GetAttribute("OceanTD_PlaceId")
			if typeof(parentId) == "string" and parentId ~= "" then
				visual:SetAttribute("OceanTD_ParentPlaceId", parentId)
				if typeof(brainHostCell.placeId) ~= "string" or brainHostCell.placeId == "" then
					brainHostCell.placeId = parentId
				end
			end
		end
	end
	CoralSize.applyToPart(visual, diameter or visual.Size.X, sizeClass, 1)
	GridService.setPlaceMeta(
		plotId,
		gx,
		gy,
		gz,
		placeId,
		if typeof(visual:GetAttribute("OceanTD_ParentPlaceId")) == "string"
			then (visual:GetAttribute("OceanTD_ParentPlaceId") :: string)
			else nil
	)
	if CoralVisual.needsFacingYaw(species.speciesId) and typeof(facingYaw) == "number" then
		local slotCf = PlotService.getSlot(plotId)
		visual:SetAttribute("OceanTD_FacingYaw", facingYaw)
		CoralVisual.alignMeshToSurface(visual, worldPos, facingYaw, nil, if slotCf then slotCf.cframe else nil)
	end

	if not suppressUndoRecord then
		UndoService.push(player, {
			kind = "place",
			placeId = placeId,
			itemId = itemId,
			worldPos = worldPos,
			seedHue = seedHue,
		})
	end

	log("Placed", itemId, "for", player.Name, "at", worldPos, "consume=", shouldConsume, "yaw=", facingYaw)
	-- Persist facing yaw immediately — don't wait for autosave / leave.
	if CoralVisual.needsFacingYaw(species.speciesId) then
		PersistenceService.save(player, PlacementService.snapshotLayout(plotId))
	end
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
		facingYaw = facingYaw,
	}
end

export type MoveResult = {
	ok: boolean,
	errorCode: string?,
	worldPos: Vector3?,
	speciesId: string?,
	itemId: string?,
	placeId: string?,
	facingYaw: number?,
}

-- Move an existing placed coral from one plot cell to another.
function PlacementService.move(
	player: Player,
	placeId: string,
	fromWorldPos: Vector3,
	toWorldPos: Vector3,
	facingYaw: number?,
	parentPlaceId: string?
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
	local fromAnchor = if visualForFrom then (visualForFrom.Position) else nil
	fromAnchor = fromAnchor or fromWorldPos

	local fromLocal = worldToPlotLocal(plotId, fromAnchor)
	local toLocal = worldToPlotLocal(plotId, toWorldPos)
	if not fromLocal or not toLocal then
		return { ok = false, errorCode = "BadPlot" }
	end

	-- Prefer placeId (stacked brains bump gy; worldToGrid(VisualPos) often misses).
	local fromCell = GridService.findCellByPlaceId(plotId, placeId)
		or GridService.findCellByLocalPos(plotId, fromLocal.X, fromLocal.Y, fromLocal.Z, 0.5)
		or GridService.getCell(plotId, fromLocal.X, fromLocal.Y, fromLocal.Z)
	if not fromCell then
		return { ok = false, errorCode = "NotFound" }
	end
	if fromCell.ownerUserId ~= player.UserId then
		return { ok = false, errorCode = "NotOwner" }
	end
	-- Use authoritative stored VisualPos for vacate / same-cell checks.
	fromLocal = Vector3.new(fromCell.lx, fromCell.ly, fromCell.lz)

	local resolvedPlaceId = placeId
	if resolvedPlaceId == "" then
		resolvedPlaceId = HttpService:GenerateGUID(false)
	end
	if typeof(fromCell.placeId) ~= "string" or fromCell.placeId == "" then
		fromCell.placeId = resolvedPlaceId
	else
		resolvedPlaceId = fromCell.placeId
	end

	local visual = findVisualByPlaceId(plotId, placeId)
		or findVisualByPlaceId(plotId, resolvedPlaceId)
		or findVisualAtGrid(plotId, toWorldPos)
		or findVisualAtGrid(plotId, fromWorldPos)
	if not visual then
		return { ok = false, errorCode = "NotFound" }
	end
	visual:SetAttribute("OceanTD_PlaceId", resolvedPlaceId)

	local yawToApply: number? = nil
	if typeof(facingYaw) == "number" and facingYaw == facingYaw then
		yawToApply = facingYaw
	end

	local function applyFacing(cellGx: number, cellGy: number, cellGz: number)
		if yawToApply == nil then
			return
		end
		local sid = visual:GetAttribute("OceanTD_SpeciesId")
		if CoralVisual.needsFacingYaw(sid) or CoralVisual.needsFacingYaw(fromCell.id) then
			visual:SetAttribute("OceanTD_FacingYaw", yawToApply)
			GridService.setSeaFanExtras(plotId, cellGx, cellGy, cellGz, nil, nil, yawToApply, nil, nil, nil)
		end
	end

	local fgx, fgy, fgz = fromCell.gx, fromCell.gy, fromCell.gz
	local tgx, tgy, tgz = GridMath.worldToGrid(toLocal, Vector3.zero)
	if fgx == tgx and fgy == tgy and fgz == tgz then
		applyFacing(fgx, fgy, fgz)
		local yaw = yawToApply
		if typeof(yaw) ~= "number" then
			local attr = visual:GetAttribute("OceanTD_FacingYaw")
			yaw = if typeof(attr) == "number" then attr else nil
		end
		if CoralVisual.isMeshSpecies(fromCell.id) or CoralVisual.isMeshSpecies(visual:GetAttribute("OceanTD_SpeciesId")) then
			local slotCf = PlotService.getSlot(plotId)
			CoralVisual.alignMeshToSurface(visual, toWorldPos, yaw, nil, if slotCf then slotCf.cframe else nil)
		else
			visual.CFrame = CFrame.new(toWorldPos)
		end
		-- Keep cell VisualPos in sync when sliding within the same key.
		fromCell.lx = toLocal.X
		fromCell.ly = toLocal.Y
		fromCell.lz = toLocal.Z
		local returnedYaw = yawToApply
		if typeof(returnedYaw) ~= "number" then
			local attr = visual:GetAttribute("OceanTD_FacingYaw")
			returnedYaw = if typeof(attr) == "number" then attr else nil
		end
		scheduleCoralColorSave(player, plotId)
		if CoralVisual.needsFacingYaw(visual:GetAttribute("OceanTD_SpeciesId")) or CoralVisual.needsFacingYaw(fromCell.id) then
			PersistenceService.save(player, PlacementService.snapshotLayout(plotId))
		end
		log("Moved (same cell) yaw=", returnedYaw, "for", player.Name)
		return {
			ok = true,
			worldPos = toWorldPos,
			itemId = fromCell.id,
			placeId = resolvedPlaceId,
			facingYaw = returnedYaw,
		}
	end

	-- Brain → Brain stack only when client snapped to a host (parentPlaceId).
	if BrainStack.isBrainId(fromCell.id) then
		local diam = if typeof(fromCell.diameter) == "number" and fromCell.diameter > 0
			then fromCell.diameter
			else CoralVisual.sanitizeBrainDiameter(nil)
		local wantedParent = if typeof(parentPlaceId) == "string" and parentPlaceId ~= "" then parentPlaceId else nil
		local stackedLocal, sgx, sgy, sgz, hostCell =
			resolveBrainStackLocal(plotId, toLocal, diam, fgx, fgy, fgz, wantedParent)
		if hostCell then
			toLocal = stackedLocal
			tgx, tgy, tgz = sgx, sgy, sgz
			local slot = PlotService.getSlot(plotId)
			if slot then
				toWorldPos = GridMath.plotLocalToWorld(toLocal, slot.cframe)
			end
			if visual then
				local hostVis: BasePart? = nil
				if typeof(hostCell.placeId) == "string" and hostCell.placeId ~= "" then
					hostVis = findVisualByPlaceId(plotId, hostCell.placeId)
				end
				if not hostVis and slot then
					for _, inst in ipairs(getPlotFolder(plotId):GetChildren()) do
						if inst:IsA("BasePart")
							and inst ~= visual
							and BrainStack.isBrainId(inst:GetAttribute("OceanTD_SpeciesId"))
						then
							local lp = GridMath.worldToPlotLocal(inst.Position, slot.cframe)
							if math.abs(lp.X - hostCell.lx) < 0.05
								and math.abs(lp.Y - hostCell.ly) < 0.05
								and math.abs(lp.Z - hostCell.lz) < 0.05
							then
								hostVis = inst
								break
							end
						end
					end
				end
				if hostVis then
					local parentId = hostVis:GetAttribute("OceanTD_PlaceId")
					if typeof(parentId) == "string" and parentId ~= "" then
						visual:SetAttribute("OceanTD_ParentPlaceId", parentId)
					end
				else
					visual:SetAttribute("OceanTD_ParentPlaceId", nil)
				end
			end
		else
			if visual then
				visual:SetAttribute("OceanTD_ParentPlaceId", nil)
			end
		end
	end

	if GridService.getCellAtGrid(plotId, tgx, tgy, tgz) then
		return { ok = false, errorCode = "SpotTaken" }
	end

	if not GridService.vacateCell(fromCell) then
		return { ok = false, errorCode = "NotFound" }
	end
	local cell = fromCell

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
		local rolled = GridService.getCellAtGrid(plotId, fgx, fgy, fgz)
		if rolled then
			rolled.placeId = cell.placeId
			rolled.parentPlaceId = cell.parentPlaceId
			GridService.copySeaFanExtras(cell, rolled)
		end
		return { ok = false, errorCode = occupyErr or "SpotTaken" }
	end

	local newCell = GridService.getCellAtGrid(plotId, tgx, tgy, tgz)
	if newCell then
		GridService.copySeaFanExtras(cell, newCell)
		newCell.placeId = resolvedPlaceId
		local parentAttr = visual:GetAttribute("OceanTD_ParentPlaceId")
		if typeof(parentAttr) == "string" and parentAttr ~= "" then
			newCell.parentPlaceId = parentAttr
		else
			newCell.parentPlaceId = nil
		end
	end
	applyFacing(tgx, tgy, tgz)

	local species = SpeciesCatalog.getByItemId(cell.id)
	local yaw = yawToApply
	if typeof(yaw) ~= "number" then
		local attr = visual:GetAttribute("OceanTD_FacingYaw")
		yaw = if typeof(attr) == "number" then attr else nil
	end
	if species and CoralVisual.isMeshSpecies(species.speciesId) then
		local slotCf = PlotService.getSlot(plotId)
		CoralVisual.alignMeshToSurface(visual, toWorldPos, yaw, nil, if slotCf then slotCf.cframe else nil)
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

	log("Moved", cell.id, "for", player.Name, "→", toWorldPos, "yaw=", yaw)
	if CoralVisual.needsFacingYaw(if species then species.speciesId else nil) or CoralVisual.needsFacingYaw(cell.id) then
		PersistenceService.save(player, PlacementService.snapshotLayout(plotId))
	end
	return {
		ok = true,
		worldPos = toWorldPos,
		speciesId = if species then species.speciesId else nil,
		itemId = cell.id,
		placeId = resolvedPlaceId,
		facingYaw = yaw,
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
	local recycleHue = resolveRecycleHue(visual, vacatedCell)
	visual:Destroy()
	local seedCount = PersistenceService.creditHueSeed(player, creditedId, recycleHue, 1)

	if not suppressUndoRecord then
		UndoService.push(player, {
			kind = "recycle",
			placeId = placeId,
			itemId = creditedId,
			worldPos = worldPos,
			seedHue = recycleHue,
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
	if not PlayerSession.canMutatePlot(player) then
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
		-- Orphan mesh visuals (SeaGrass/SeaFan) can remain if grid was already empty.
		PlacementService.clearPlotVisuals(plotId)
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
		local recycleHue = resolveRecycleHue(visual, vacatedCell)
		PersistenceService.creditHueSeed(player, creditedId, recycleHue, 1)
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

	-- Mesh species can miss per-cell visual lookup (center ≠ plant grid); wipe leftovers.
	PlacementService.clearPlotVisuals(plotId)

	-- Credit + remove any grid cells that failed per-entry vacate (avoids permanent Occupied).
	local leftovers: { any } = {}
	GridService.forEachCell(plotId, function(cell)
		if cell.ownerUserId == player.UserId then
			table.insert(leftovers, cell)
		end
	end)
	for _, cell in ipairs(leftovers) do
		local recycleHue = resolveRecycleHue(nil, cell)
		if GridService.vacateCell(cell) then
			PersistenceService.creditHueSeed(player, cell.id, recycleHue, 1)
			credits[cell.id] = (credits[cell.id] or 0) + 1
		end
	end
	if GridService.getPlotCount(plotId) > 0 then
		GridService.clearPlot(plotId)
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
	if not PlayerSession.canMutatePlot(player) then
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
		local visualLocal = LayoutRestore.resolveVisualLocal(obj, slot.cframe)
		-- fromSave: world-anchored VisualPos — never re-raycast; ignore stale grid keys.
		local result = PlacementService.placeFromSave(
			player,
			obj.id,
			visualLocal,
			nil,
			nil,
			nil,
			true,
			obj.diameter,
			obj.sizeTier,
			obj.sizeClass,
			obj.colorIndex,
			obj.colorR,
			obj.colorG,
			obj.colorB,
			obj.variantIndex,
			obj.scaleMult,
			{
				scaleWidth = obj.scaleWidth,
				scaleHeight = obj.scaleHeight,
				facingYaw = obj.facingYaw,
				webColorR = obj.webColorR,
				webColorG = obj.webColorG,
				webColorB = obj.webColorB,
			},
			{
				placeId = obj.placeId,
				parentPlaceId = obj.parentPlaceId,
			}
		)
		if result.ok then
			placed += 1
		else
			warnPlace("applyLayout placeFromSave failed", obj.id, result.errorCode)
		end
	end
	suppressUndoRecord = false
	PlacementService.rebuildBrainParentLinks(plotId)

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
	local recycleHue = resolveRecycleHue(visual, vacatedCell)
	PersistenceService.creditHueSeed(player, creditedId, recycleHue, 1)
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
			local placeOpts: PlaceOpts = {}
			if typeof(step.seedHue) == "number" then
				placeOpts.placementHue = step.seedHue
			end
			local result = PlacementService.place(player, step.itemId, worldPos, true, placeOpts)
			ok = result.ok == true
			err = result.errorCode
		else
			err = "BadStep"
		end
	elseif step.kind == "color" then
		if typeof(step.fromColorIndex) == "number" then
			local result = PlacementService.setCoralColor(
				player,
				step.placeId,
				step.fromColorIndex,
				nil,
				nil,
				nil,
				nil,
				nil,
				nil,
				nil,
				true
			)
			ok = result.ok == true
			err = result.errorCode
		else
			local result = PlacementService.clearCoralHue(player, step.placeId, true)
			ok = result.ok == true
			err = result.errorCode
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

function PlacementService.rebuildBrainParentLinks(plotId: string)
	local brains: { any } = {}
	GridService.forEachCell(plotId, function(cell)
		if BrainStack.isBrainId(cell.id) then
			if typeof(cell.placeId) ~= "string" or cell.placeId == "" then
				cell.placeId = HttpService:GenerateGUID(false)
			end
			table.insert(brains, cell)
		end
	end)
	table.sort(brains, function(a, b)
		return a.ly < b.ly
	end)
	for _, cell in ipairs(brains) do
		if typeof(cell.parentPlaceId) == "string" and cell.parentPlaceId ~= "" then
			local parent = GridService.findCellByPlaceId(plotId, cell.parentPlaceId)
			if parent then
				continue
			end
			cell.parentPlaceId = nil
		end
		local best: any = nil
		local bestScore = math.huge
		local d1 = if typeof(cell.diameter) == "number" and cell.diameter > 0 then cell.diameter else 4
		for _, other in ipairs(brains) do
			if other ~= cell and other.ly < cell.ly - 0.05 then
				local d0 = if typeof(other.diameter) == "number" and other.diameter > 0 then other.diameter else 4
				local dx = cell.lx - other.lx
				local dz = cell.lz - other.lz
				local horiz = math.sqrt(dx * dx + dz * dz)
				local maxDist = (d0 + d1) * 0.55
				if horiz <= maxDist then
					local score = (cell.ly - other.ly) + horiz * 0.35
					if score < bestScore then
						bestScore = score
						best = other
					end
				end
			end
		end
		if best and typeof(best.placeId) == "string" then
			cell.parentPlaceId = best.placeId
		end
	end
	-- Mirror onto visuals.
	local slot = PlotService.getSlot(plotId)
	if not slot then
		return
	end
	for _, inst in ipairs(getPlotFolder(plotId):GetChildren()) do
		if inst:IsA("BasePart") and BrainStack.isBrainId(inst:GetAttribute("OceanTD_SpeciesId")) then
			local pid = inst:GetAttribute("OceanTD_PlaceId")
			if typeof(pid) == "string" then
				local cell = GridService.findCellByPlaceId(plotId, pid)
				if cell then
					if typeof(cell.parentPlaceId) == "string" and cell.parentPlaceId ~= "" then
						inst:SetAttribute("OceanTD_ParentPlaceId", cell.parentPlaceId)
					else
						inst:SetAttribute("OceanTD_ParentPlaceId", nil)
					end
				end
			end
		end
	end
end

export type StackMove = {
	placeId: string,
	worldPos: Vector3,
	stackParentPlaceId: string?,
}

-- After a brain changes diameter: lift it (vs parent/ground) and slide descendants up.
local function reflowBrainStackAfterSize(
	plotId: string,
	changedPlaceId: string,
	oldDiam: number,
	newDiam: number
): { StackMove }
	local moves: { StackMove } = {}
	local slot = PlotService.getSlot(plotId)
	if not slot then
		return moves
	end
	local byId: { [string]: any } = {}
	GridService.forEachCell(plotId, function(cell)
		if BrainStack.isBrainId(cell.id) and typeof(cell.placeId) == "string" then
			byId[cell.placeId] = cell
		end
	end)
	local changed = byId[changedPlaceId]
	if not changed then
		return moves
	end

	-- Capture child lists + offsets before moving.
	type Off = { ox: number, oz: number, yRel: number, oldParentDiam: number }
	local offsets: { [string]: Off } = {}
	local childrenOf: { [string]: { string } } = {}
	for id, cell in pairs(byId) do
		local pid = cell.parentPlaceId
		if typeof(pid) == "string" and byId[pid] then
			childrenOf[pid] = childrenOf[pid] or {}
			table.insert(childrenOf[pid], id)
			local parent = byId[pid]
			local pd = if typeof(parent.diameter) == "number" and parent.diameter > 0 then parent.diameter else 4
			-- For the changed node, parent still has its diameter; changed has newDiam already applied.
			if id == changedPlaceId then
				pd = if typeof(parent.diameter) == "number" and parent.diameter > 0 then parent.diameter else 4
			end
			offsets[id] = {
				ox = cell.lx - parent.lx,
				oz = cell.lz - parent.lz,
				yRel = cell.ly - parent.ly,
				oldParentDiam = if id == changedPlaceId or pid == changedPlaceId
					then (if pid == changedPlaceId then oldDiam else pd)
					else pd,
			}
			if pid == changedPlaceId then
				offsets[id].oldParentDiam = oldDiam
			end
		end
	end

	local function applyMove(cell: any)
		local world = GridMath.plotLocalToWorld(Vector3.new(cell.lx, cell.ly, cell.lz), slot.cframe)
		local vis = findVisualByPlaceId(plotId, cell.placeId)
		if vis then
			vis.CFrame = CFrame.new(world)
			if typeof(cell.parentPlaceId) == "string" and cell.parentPlaceId ~= "" then
				vis:SetAttribute("OceanTD_ParentPlaceId", cell.parentPlaceId)
			else
				vis:SetAttribute("OceanTD_ParentPlaceId", nil)
			end
		end
		table.insert(moves, {
			placeId = cell.placeId,
			worldPos = world,
			stackParentPlaceId = cell.parentPlaceId,
		})
	end

	-- 1) Move the upgraded coral.
	local parentId = changed.parentPlaceId
	if typeof(parentId) == "string" and byId[parentId] then
		local parent = byId[parentId]
		local pd = if typeof(parent.diameter) == "number" and parent.diameter > 0 then parent.diameter else 4
		local off = offsets[changedPlaceId]
		local ox = if off then off.ox else 0
		local oz = if off then off.oz else 0
		local yRel = if off then off.yRel * (pd / math.max(off.oldParentDiam, 0.1)) else nil
		local pos = BrainStack.restackChildCenter(
			Vector3.new(parent.lx, parent.ly, parent.lz),
			pd,
			newDiam,
			ox,
			oz,
			yRel
		)
		GridService.relocateCellLocal(changed, pos.X, pos.Y, pos.Z)
		changed.diameter = newDiam
		applyMove(changed)
	else
		-- Ground root: lift so bottom stays planted.
		local newY = BrainStack.liftRootCenter(changed.ly, oldDiam, newDiam)
		GridService.relocateCellLocal(changed, changed.lx, newY, changed.lz)
		changed.diameter = newDiam
		applyMove(changed)
	end

	-- 2) BFS descendants — parents before children.
	local queue: { string } = { changedPlaceId }
	local qi = 1
	while qi <= #queue do
		local pid = queue[qi]
		qi += 1
		local kids = childrenOf[pid]
		if not kids then
			continue
		end
		local parent = byId[pid]
		if not parent then
			continue
		end
		local pd = if typeof(parent.diameter) == "number" and parent.diameter > 0 then parent.diameter else 4
		for _, cid in ipairs(kids) do
			local child = byId[cid]
			if not child then
				continue
			end
			local cd = if typeof(child.diameter) == "number" and child.diameter > 0 then child.diameter else 4
			local off = offsets[cid]
			local ox = if off then off.ox else (child.lx - parent.lx)
			local oz = if off then off.oz else (child.lz - parent.lz)
			local scale = pd / math.max(if off then off.oldParentDiam else pd, 0.1)
			local yRel = if off then off.yRel * scale else nil
			local pos = BrainStack.restackChildCenter(
				Vector3.new(parent.lx, parent.ly, parent.lz),
				pd,
				cd,
				ox,
				oz,
				yRel
			)
			GridService.relocateCellLocal(child, pos.X, pos.Y, pos.Z)
			applyMove(child)
			table.insert(queue, cid)
		end
	end

	return moves
end

function PlacementService.setCoralSize(
	player: Player,
	placeId: string,
	targetClass: number,
	unlockNext: boolean,
	opts: { skipSpend: boolean?, skipSave: boolean? }?
): {
	ok: boolean,
	errorCode: string?,
	diameter: number?,
	sizeClass: number?,
	sizeTier: number?,
	variantIndex: number?,
	scaleMult: number?,
	stackMoves: { StackMove }?,
	placeId: string?,
}
	local skipSpend = opts ~= nil and opts.skipSpend == true
	local skipSave = opts ~= nil and opts.skipSave == true
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
	local curD, _curClass, tier = CoralSize.readFromPart(visual)
	local want = CoralSize.clampTier(targetClass)
	local newTier = tier
	local unlockCost = 0
	if unlockNext then
		local nxt = CoralSize.nextUnlock(tier)
		if not nxt then
			return { ok = false, errorCode = "Maxed", placeId = placeId }
		end
		if want < nxt then
			want = nxt
		end
		if want <= tier then
			return { ok = true, sizeClass = tier, sizeTier = tier, placeId = placeId, diameter = curD }
		end
		unlockCost = CoralSize.unlockCostRange(tier, want)
		if not skipSpend and unlockCost > PersistenceService.getSandDollars(player) then
			return { ok = false, errorCode = "CantAfford" }
		end
		newTier = want
	elseif want > tier then
		return { ok = false, errorCode = "Locked" }
	end

	local speciesId = visual:GetAttribute("OceanTD_SpeciesId")
	local newDiam: number
	local variant: number? = nil
	local scale: number? = nil
	local slot = PlotService.getSlot(plotId)
	if not slot then
		return { ok = false, errorCode = "BadPlot" }
	end

	-- Resolve grid cell by placeId first (stacked brains often miss rounded-key lookup).
	local cell = GridService.findCellByPlaceId(plotId, placeId)
	if not cell then
		local savedAnchor = CoralVisual.readGridAnchor(visual) or visual.Position
		local localPos = GridMath.worldToPlotLocal(savedAnchor, slot.cframe)
		local gx, gy, gz = GridMath.worldToGrid(localPos, Vector3.zero)
		cell = GridService.getCellAtGrid(plotId, gx, gy, gz)
			or GridService.findCellByLocalPos(plotId, localPos.X, localPos.Y, localPos.Z, 0.35)
	end
	if not cell then
		return { ok = false, errorCode = "Missing" }
	end
	if typeof(cell.placeId) ~= "string" or cell.placeId == "" then
		cell.placeId = placeId
	end

	local oldDiam = if typeof(cell.diameter) == "number" and cell.diameter > 0 then cell.diameter else curD
	local gx, gy, gz = cell.gx, cell.gy, cell.gz
	local savedAnchor = CoralVisual.readGridAnchor(visual) or visual.Position

	if CoralVisual.isMeshSpecies(speciesId) then
		variant = CoralVisual.randomMeshVariant(if typeof(speciesId) == "string" then speciesId else nil)
		local scaleWidth: number? = nil
		local scaleHeight: number? = nil
		if CoralVisual.isSeaFan(speciesId) then
			scale, scaleWidth, scaleHeight = CoralVisual.randomSeaFanScales()
		else
			scale = CoralVisual.randomMeshScale(if typeof(speciesId) == "string" then speciesId else nil, want)
		end
		local newPart, height, vOut, sOut = CoralVisual.restyleMesh(
			visual,
			want,
			variant,
			scale,
			savedAnchor,
			scaleWidth,
			scaleHeight
		)
		if newPart then
			visual = newPart
			newDiam = height or newPart.Size.Y
			variant = vOut or variant
			scale = sOut or scale
		else
			newDiam = visual.Size.Y
		end
		visual:SetAttribute("OceanTD_SizeTier", newTier)
		if typeof(scaleWidth) == "number" then
			visual:SetAttribute("OceanTD_ScaleWidth", scaleWidth)
		end
		if typeof(scaleHeight) == "number" then
			visual:SetAttribute("OceanTD_ScaleHeight", scaleHeight)
		end
		if not GridService.setSizeAtGrid(plotId, gx, gy, gz, newDiam, newTier, want, variant, scale, scaleWidth, scaleHeight) then
			return { ok = false, errorCode = "Missing" }
		end
	else
		newDiam = CoralSize.randomDiameter(want)
		if not GridService.setSizeAtGrid(plotId, gx, gy, gz, newDiam, newTier, want, variant, scale) then
			return { ok = false, errorCode = "Missing" }
		end
	end

	visual:SetAttribute("OceanTD_Diameter", newDiam)
	visual:SetAttribute("OceanTD_SizeClass", want)
	visual:SetAttribute("OceanTD_SizeTier", newTier)
	if typeof(variant) == "number" then
		visual:SetAttribute("OceanTD_VariantIndex", variant)
	end
	if typeof(scale) == "number" then
		visual:SetAttribute("OceanTD_ScaleMult", scale)
	end

	local stackMoves: { StackMove }? = nil
	if BrainStack.isBrainId(speciesId) or BrainStack.isBrainId(cell.id) then
		-- Ensure parent links exist before reflow (covers older stacks).
		PlacementService.rebuildBrainParentLinks(plotId)
		stackMoves = reflowBrainStackAfterSize(plotId, placeId, oldDiam, newDiam)
	end

	if unlockCost > 0 and not skipSpend then
		local spent, _balance, spendErr = PersistenceService.trySpendSandDollars(player, unlockCost)
		if not spent then
			return { ok = false, errorCode = spendErr or "CantAfford" }
		end
	end
	if not skipSave then
		PersistenceService.save(player, PlacementService.snapshotLayout(plotId))
	end
	log("Size", placeId, "class", want, "tier", newTier, "d", newDiam, "moves", if stackMoves then #stackMoves else 0)
	return {
		ok = true,
		diameter = newDiam,
		sizeClass = want,
		sizeTier = newTier,
		variantIndex = variant,
		scaleMult = scale,
		stackMoves = stackMoves,
		placeId = placeId,
	}
end

type BulkSizeJob = { placeId: string, tier: number, cost: number }

function PlacementService.setCoralSizeBulk(
	player: Player,
	placeIds: { string },
	targetClass: number,
	unlockNext: boolean
): {
	ok: boolean,
	errorCode: string?,
	upgraded: { any },
	partial: boolean?,
	upgradedCount: number?,
	neededCount: number?,
	totalCost: number?,
	sandDollars: number?,
}
	if typeof(placeIds) ~= "table" or #placeIds == 0 then
		return { ok = false, errorCode = "BadRequest", upgraded = {} }
	end
	if not PlayerSession.canSave(player) then
		return { ok = false, errorCode = "NotReady", upgraded = {} }
	end
	local plotId = PlotService.getOwnerPlotId(player)
	if not plotId then
		return { ok = false, errorCode = "NoPlot", upgraded = {} }
	end
	local want = CoralSize.clampTier(targetClass)
	local jobs: { BulkSizeJob } = {}
	local seen: { [string]: boolean } = {}
	for _, rawId in ipairs(placeIds) do
		if typeof(rawId) ~= "string" or rawId == "" or seen[rawId] then
			continue
		end
		seen[rawId] = true
		local visual = findVisualByPlaceId(plotId, rawId)
		if not visual then
			continue
		end
		local _d, _c, tier = CoralSize.readFromPart(visual)
		if unlockNext then
			if tier < want then
				table.insert(jobs, {
					placeId = rawId,
					tier = tier,
					cost = CoralSize.unlockCostRange(tier, want),
				})
			end
		elseif want <= tier then
			table.insert(jobs, { placeId = rawId, tier = tier, cost = 0 })
		end
	end
	table.sort(jobs, function(a, b)
		if a.cost == b.cost then
			return a.placeId < b.placeId
		end
		return a.cost < b.cost
	end)
	local cash = PersistenceService.getSandDollars(player)
	local chosen: { BulkSizeJob } = {}
	local spent = 0
	for _, j in ipairs(jobs) do
		if spent + j.cost <= cash then
			spent += j.cost
			table.insert(chosen, j)
		end
	end
	if #jobs > 0 and #chosen == 0 and unlockNext then
		return {
			ok = false,
			errorCode = "CantAfford",
			upgraded = {},
			neededCount = #jobs,
			totalCost = jobs[1].cost,
			sandDollars = cash,
		}
	end
	if spent > 0 then
		local okSpend, _bal, spendErr = PersistenceService.trySpendSandDollars(player, spent)
		if not okSpend then
			return { ok = false, errorCode = spendErr or "CantAfford", upgraded = {}, sandDollars = cash }
		end
	end
	local upgraded: { any } = {}
	for _, j in ipairs(chosen) do
		local result = PlacementService.setCoralSize(player, j.placeId, want, unlockNext, {
			skipSpend = true,
			skipSave = true,
		})
		if result.ok then
			table.insert(upgraded, result)
		end
	end
	PersistenceService.save(player, PlacementService.snapshotLayout(plotId))
	local partial = #chosen < #jobs
	log("SizeBulk", #upgraded, "/", #jobs, "cost", spent, "partial", partial)
	return {
		ok = true,
		upgraded = upgraded,
		partial = partial,
		upgradedCount = #upgraded,
		neededCount = #jobs,
		totalCost = spent,
		sandDollars = PersistenceService.getSandDollars(player),
	}
end

function PlacementService.clearCoralHue(player: Player, placeId: string, skipCapCheck: boolean?): {
	ok: boolean,
	errorCode: string?,
}
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
	local cell = GridService.findCellByPlaceId(plotId, placeId)
	if not cell then
		return { ok = false, errorCode = "Missing" }
	end
	local prevAttr = visual:GetAttribute("OceanTD_ColorIndex")
	local prevIdx = if typeof(prevAttr) == "number" then PlotOutlineColors.clampCoralIndex(prevAttr) else nil
	local itemId = visual:GetAttribute("OceanTD_ItemId")
	local defaultColor = CoralVisual.clearPalettePaint(visual)
	cell.colorIndex = nil
	cell.colorR = defaultColor.R
	cell.colorG = defaultColor.G
	cell.colorB = defaultColor.B
	local wr = visual:GetAttribute("OceanTD_WebRestR")
	local wg = visual:GetAttribute("OceanTD_WebRestG")
	local wb = visual:GetAttribute("OceanTD_WebRestB")
	if typeof(wr) == "number" and typeof(wg) == "number" and typeof(wb) == "number" then
		cell.webColorR = wr
		cell.webColorG = wg
		cell.webColorB = wb
	else
		cell.webColorR = nil
		cell.webColorG = nil
		cell.webColorB = nil
	end
	if not skipCapCheck and not suppressUndoRecord and prevIdx ~= nil then
		UndoService.push(player, {
			kind = "color",
			placeId = placeId,
			itemId = if typeof(itemId) == "string" then itemId else "",
			fromColorIndex = prevIdx,
			toColorIndex = nil,
		})
	end
	scheduleCoralColorSave(player, plotId)
	return { ok = true, colorR = defaultColor.R, colorG = defaultColor.G, colorB = defaultColor.B }
end

function PlacementService.setCoralColor(
	player: Player,
	placeId: string,
	colorIndex: number,
	colorR: number?,
	colorG: number?,
	colorB: number?,
	webColorIndex: number?,
	webColorR: number?,
	webColorG: number?,
	webColorB: number?,
	skipCapCheck: boolean?
): {
	ok: boolean,
	errorCode: string?,
	colorIndex: number?,
	colorR: number?,
	colorG: number?,
	colorB: number?,
	webColorIndex: number?,
	webColorR: number?,
	webColorG: number?,
	webColorB: number?,
}
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
	local itemId = visual:GetAttribute("OceanTD_ItemId")
	local prevAttr = visual:GetAttribute("OceanTD_ColorIndex")
	local prevIdx = if typeof(prevAttr) == "number" then PlotOutlineColors.clampCoralIndex(prevAttr) else nil
	-- Resolve cell by placeId (stacked brains sit off worldToGrid of the mesh center).
	local cell = GridService.findCellByPlaceId(plotId, placeId)
	if not cell then
		local slot = PlotService.getSlot(plotId)
		if not slot then
			return { ok = false, errorCode = "BadPlot" }
		end
		local anchorPos = CoralVisual.readGridAnchor(visual) or visual.Position
		local localPos = GridMath.worldToPlotLocal(anchorPos, slot.cframe)
		local gx, gy, gz = GridMath.worldToGrid(localPos, Vector3.zero)
		cell = GridService.getCellAtGrid(plotId, gx, gy, gz)
	end
	if not cell then
		return { ok = false, errorCode = "Missing" }
	end
	if prevIdx == nil and typeof(visual:GetAttribute("OceanTD_DefaultRestR")) ~= "number" then
		CoralVisual.snapshotDefaultRestLook(visual)
	end
	if skipCapCheck ~= true and typeof(itemId) == "string" and itemId ~= "" then
		if prevIdx ~= idx and not canAssignHue(player, plotId, itemId, placeId, idx, cell) then
			if PersistenceService.getHueSeedCount(player, itemId, idx) <= 0 then
				return { ok = false, errorCode = "ColorLocked" }
			end
			return { ok = false, errorCode = "HueCap" }
		end
	end
	local gx, gy, gz = cell.gx, cell.gy, cell.gz
	if not GridService.setColorAtGrid(plotId, gx, gy, gz, idx, paint.R, paint.G, paint.B) then
		return { ok = false, errorCode = "Missing" }
	end
	visual:SetAttribute("OceanTD_ColorIndex", idx)
	local webPaint: Color3? = nil
	local webIdx: number? = nil
	if CoralVisual.isSeaFan(visual:GetAttribute("OceanTD_SpeciesId")) then
		-- Web always shares the stem swatch hue; shade may differ.
		webIdx = idx
		local base = PlotOutlineColors.coralColor(idx)
		webPaint = PlotOutlineColors.randomHueVariant(webIdx)
		if typeof(webColorR) == "number" and typeof(webColorG) == "number" and typeof(webColorB) == "number" then
			local candidate = Color3.new(
				math.clamp(webColorR, 0, 1),
				math.clamp(webColorG, 0, 1),
				math.clamp(webColorB, 0, 1)
			)
			local h1, s1 = candidate:ToHSV()
			local h2, s2 = base:ToHSV()
			local dh = math.abs(h1 - h2)
			if dh > 0.5 then
				dh = 1 - dh
			end
			-- Accept client shade only when it's still in the selected swatch family.
			local sameFamily = (s2 < 0.12 and s1 < 0.22) or dh <= 0.08
			if sameFamily then
				webPaint = candidate
			end
		end
		CoralVisual.setRestColor(visual, paint, webPaint, webIdx)
		GridService.setSeaFanExtras(plotId, gx, gy, gz, nil, nil, nil, webPaint.R, webPaint.G, webPaint.B)
	elseif CoralVisual.isMainAccentMesh(visual:GetAttribute("OceanTD_SpeciesId")) then
		webPaint = PlotOutlineColors.randomBrightAccent()
		if typeof(webColorR) == "number" and typeof(webColorG) == "number" and typeof(webColorB) == "number" then
			local candidate = Color3.new(
				math.clamp(webColorR, 0, 1),
				math.clamp(webColorG, 0, 1),
				math.clamp(webColorB, 0, 1)
			)
			local _, s, v = candidate:ToHSV()
			if s >= 0.45 and v >= 0.5 then
				webPaint = candidate
			end
		end
		CoralVisual.setRestColor(visual, paint, webPaint, nil)
		GridService.setSeaFanExtras(plotId, gx, gy, gz, nil, nil, nil, webPaint.R, webPaint.G, webPaint.B)
	else
		CoralVisual.setRestColor(visual, paint)
	end
	if skipCapCheck ~= true and not suppressUndoRecord and prevIdx ~= idx then
		UndoService.push(player, {
			kind = "color",
			placeId = placeId,
			itemId = if typeof(itemId) == "string" then itemId else "",
			fromColorIndex = prevIdx,
			toColorIndex = idx,
		})
	end
	-- Live grid/visual now; DataStore after 5s idle so rapid dice rolls don't thrash saves.
	scheduleCoralColorSave(player, plotId)
	log("Color", placeId, "index", idx)
	return {
		ok = true,
		colorIndex = idx,
		colorR = paint.R,
		colorG = paint.G,
		colorB = paint.B,
		webColorIndex = webIdx,
		webColorR = if webPaint then webPaint.R else nil,
		webColorG = if webPaint then webPaint.G else nil,
		webColorB = if webPaint then webPaint.B else nil,
	}
end

function PlacementService.init()
	getPlacedRoot()
	log("Init")
end

return PlacementService
