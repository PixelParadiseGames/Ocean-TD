--!strict
--[[
	Server place authority.
	Order: validate session/plot → CanPlace (in bounds, empty cell) → grid occupy → visual.
	No inventory debit yet (infinite test mode).
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

local PlacementService = {}

local ROOT_NAME = "OceanTD_Placed"

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
}

function PlacementService.place(player: Player, itemId: string, worldPos: Vector3): PlaceResult
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

	-- Snap visual to ray hit pos (client sends terrain hit); occupancy uses plot-local grid.
	local occupied, occupyErr = GridService.tryOccupy(plotId, player.UserId, itemId, localPos.X, localPos.Y, localPos.Z)
	if not occupied then
		return { ok = false, errorCode = occupyErr or "SpotTaken" }
	end

	local visual = PlacementService.spawnVisual(plotId, species.speciesId, worldPos, nil)
	if not visual then
		warnPlace("Visual spawn failed after occupy — layout still has cell")
		return { ok = false, errorCode = "VisualFail" }
	end

	log("Placed", itemId, "for", player.Name, "at", worldPos)
	return {
		ok = true,
		worldPos = worldPos,
		speciesId = species.speciesId,
		itemId = itemId,
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

	log("Recycled", creditedId, "for", player.Name, "seeds=", seedCount)
	return {
		ok = true,
		itemId = creditedId,
		placeId = placeId,
		seedCount = seedCount,
	}
end

function PlacementService.init()
	getPlacedRoot()
	log("Init")
end

return PlacementService
