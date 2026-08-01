--!strict
--[[
	Server place authority.
	Order: validate session/plot → CanPlace (in bounds, empty cell) → grid occupy → visual.
	No inventory debit yet (infinite test mode).
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local oceanShared = ReplicatedStorage:WaitForChild("OceanTD"):WaitForChild("Shared")
local GridMath = require(oceanShared:WaitForChild("GridMath"))
local SpeciesCatalog = require(oceanShared:WaitForChild("SpeciesCatalog"))
local CoralVisual = require(oceanShared:WaitForChild("CoralVisual"))
local ItemCatalog = require(oceanShared:WaitForChild("ItemCatalog"))

local PlotService = require(script.Parent:WaitForChild("PlotService"))
local GridService = require(script.Parent:WaitForChild("GridService"))
local PlayerSession = require(script.Parent:WaitForChild("PlayerSession"))

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
	part.Parent = getPlotFolder(plotId)
	return part
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

function PlacementService.init()
	getPlacedRoot()
	log("Init")
end

return PlacementService
