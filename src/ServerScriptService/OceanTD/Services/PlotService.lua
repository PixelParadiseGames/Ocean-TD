--!strict
--[[
	Plot assignment from ArenaGeneratorPlugin contract.

	Hide Previews moves MasterTerrainBox + TerrainPreviews into ServerStorage
	(not Destroy). Runtime must read Workspace OR ServerStorage.

	Plot1 = MasterTerrainBox
	Plot2 = TerrainPreviews.PreviewBox_1
	…
	PlotN = TerrainPreviews.PreviewBox_(N-1)

	If boxes are missing, fall back to RingMath matching the plugin formula.
]]

local Workspace = game:GetService("Workspace")
local ServerStorage = game:GetService("ServerStorage")

local oceanShared = game:GetService("ReplicatedStorage"):WaitForChild("OceanTD"):WaitForChild("Shared")
local Constants = require(oceanShared:WaitForChild("Constants"))
local GridMath = require(oceanShared:WaitForChild("GridMath"))
local RingMath = require(oceanShared:WaitForChild("RingMath"))
local PlotTypes = require(oceanShared:WaitForChild("PlotTypes"))

type PlotBoundsPayload = PlotTypes.PlotBoundsPayload
type PlotId = PlotTypes.PlotId

export type PlotSlot = {
	plotId: PlotId,
	plotIndex: number,
	cframe: CFrame,
	size: Vector3,
	spawnCFrame: CFrame,
	owner: Player?,
	sourceName: string,
}

local PlotService = {}

local slotsById: { [string]: PlotSlot } = {}
local ownerToPlot: { [Player]: PlotId } = {}
local masterPlotCf: CFrame? = nil
local ringCenter: Vector3? = nil
local initialized = false

local function log(...: any)
	print("[PLOT]", ...)
end

local function warnPlot(...: any)
	warn("[PLOT]", ...)
end

local function plotIdFromIndex(i: number): PlotId
	return "Plot" .. tostring(i)
end

local function findBasePart(parent: Instance?, name: string): BasePart?
	if not parent then
		return nil
	end
	local inst = parent:FindFirstChild(name, true)
	if inst and inst:IsA("BasePart") then
		return inst
	end
	return nil
end

-- Plugin stashes master/previews in ServerStorage when "Hide Previews" is used.
local function findInWorkspaceOrStorage(name: string): Instance?
	local inst = Workspace:FindFirstChild(name)
	if inst then
		return inst
	end
	return ServerStorage:FindFirstChild(name)
end

function PlotService.getMasterTerrain(): BasePart?
	local master = findInWorkspaceOrStorage(Constants.MASTER_TERRAIN_NAME)
	if master and master:IsA("BasePart") then
		return master
	end
	return nil
end

local function getTerrainPreviewsFolder(): Folder?
	local folder = findInWorkspaceOrStorage(Constants.TERRAIN_PREVIEWS_FOLDER)
	if folder and folder:IsA("Folder") then
		return folder
	end
	return nil
end

local function findPreviewBox(previewIndex: number): BasePart?
	local name = Constants.PREVIEW_BOX_PREFIX .. tostring(previewIndex)
	local folder = getTerrainPreviewsFolder()
	if folder then
		local box = folder:FindFirstChild(name)
		if box and box:IsA("BasePart") then
			return box
		end
	end
	-- Loose search (older layouts)
	local loose = findInWorkspaceOrStorage(name)
	if loose and loose:IsA("BasePart") then
		return loose
	end
	return nil
end

function PlotService.getDecorFolder(plotIndex: number): Instance?
	if plotIndex == 1 then
		return Workspace:FindFirstChild(Constants.MASTER_DECOR_NAME)
	end
	return Workspace:FindFirstChild(Constants.STATIC_PLOT_PREFIX .. tostring(plotIndex))
end

function PlotService.getRingCenter(): Vector3?
	return ringCenter
end

local function resolveSpawnCFrame(plotCf: CFrame, size: Vector3): CFrame
	local fallback = plotCf * CFrame.new(0, size.Y * 0.5 + 3, 0)
	if not masterPlotCf then
		return fallback
	end

	local masterDecor = Workspace:FindFirstChild(Constants.MASTER_DECOR_NAME)
	local spawnPart = findBasePart(masterDecor, Constants.SPAWN_NAME)
	if not spawnPart then
		spawnPart = findBasePart(masterDecor, "Plot1 Spawn Point")
	end
	if not spawnPart then
		local master = PlotService.getMasterTerrain()
		spawnPart = findBasePart(master, Constants.SPAWN_NAME)
	end
	if not spawnPart then
		return fallback
	end

	return RingMath.remapFromMaster(spawnPart.CFrame, masterPlotCf, plotCf)
end

local function registerLogicalSlot(plotIndex: number, cf: CFrame, size: Vector3, sourceName: string)
	local plotId = plotIdFromIndex(plotIndex)
	local spawnCf = resolveSpawnCFrame(cf, size)
	slotsById[plotId] = {
		plotId = plotId,
		plotIndex = plotIndex,
		cframe = cf,
		size = size,
		spawnCFrame = spawnCf,
		owner = nil,
		sourceName = sourceName,
	}
	log("Registered", plotId, "<-", sourceName, "size=", size)
end

local function expansionFromMaster(master: BasePart): number
	local attr = master:GetAttribute("ExpansionOffset")
	if typeof(attr) == "number" then
		return attr
	end
	return 0
end

-- Primary: read Master + PreviewBoxes (Workspace or ServerStorage after Hide).
local function initFromMasterAndPreviews(): boolean
	local master = PlotService.getMasterTerrain()
	if not master then
		return false
	end

	local previewCount = Constants.MAX_PLOTS - 1
	local previews: { BasePart } = {}
	local missing: { string } = {}
	for i = 1, previewCount do
		local box = findPreviewBox(i)
		if box then
			table.insert(previews, box)
		else
			table.insert(missing, Constants.PREVIEW_BOX_PREFIX .. tostring(i))
		end
	end

	masterPlotCf = master.CFrame
	local size = master.Size

	if #missing > 0 then
		-- Compute poses with the same formula as ArenaGeneratorPlugin.
		warnPlot(
			"Preview boxes missing (",
			table.concat(missing, ", "),
			") — computing from MasterTerrainBox via plugin RingMath. Parent=",
			master:GetFullName()
		)
		local expansion = expansionFromMaster(master)
		local centerCf = RingMath.pluginCenterCFrame(master.CFrame, size, Constants.MAX_PLOTS, expansion)
		ringCenter = centerCf.Position
		registerLogicalSlot(1, master.CFrame, size, master:GetFullName())
		for i = 1, previewCount do
			local cf = RingMath.pluginPreviewCFrame(i, Constants.MAX_PLOTS, master.CFrame, size, expansion)
			registerLogicalSlot(i + 1, cf, size, "RingMath.PreviewBox_" .. tostring(i))
		end
		log("Init from MasterTerrainBox + RingMath fallback; ringCenter≈", ringCenter)
		return true
	end

	local sum = master.Position
	for _, box in ipairs(previews) do
		sum += box.Position
	end
	ringCenter = sum / (1 + #previews)

	local masterParent = if master.Parent == ServerStorage then "ServerStorage" else "Workspace"
	registerLogicalSlot(1, master.CFrame, master.Size, masterParent .. "." .. Constants.MASTER_TERRAIN_NAME)
	for i, box in ipairs(previews) do
		registerLogicalSlot(i + 1, box.CFrame, box.Size, box:GetFullName())
	end

	log("Init from Master + PreviewBoxes (incl. ServerStorage stash); ringCenter≈", ringCenter)
	return true
end

local function initFromPlotsFolder(): boolean
	local plotsFolder = Workspace:FindFirstChild(Constants.PLOT_FOLDER_NAME)
	if not plotsFolder then
		return false
	end

	local any = false
	for i = 1, Constants.MAX_PLOTS do
		local plotId = plotIdFromIndex(i)
		local folder = plotsFolder:FindFirstChild(plotId)
		if not folder then
			warnPlot("Missing", plotId, "under Workspace.Plots — slot unavailable.")
			continue
		end
		local bounds = folder:FindFirstChild(Constants.BOUNDS_NAME, true)
		if not bounds or not bounds:IsA("BasePart") then
			warnPlot(plotId, "missing Bounds BasePart — slot unavailable.")
			continue
		end
		if i == 1 then
			masterPlotCf = bounds.CFrame
		end
		registerLogicalSlot(i, bounds.CFrame, bounds.Size, plotId .. ".Bounds")
		any = true
	end
	if any then
		log("Init from Workspace.Plots.Bounds fallback")
	end
	return any
end

function PlotService.init()
	if initialized then
		return
	end
	initialized = true

	local ok = initFromMasterAndPreviews()
	if not ok then
		ok = initFromPlotsFolder()
	end
	if not ok then
		warnPlot(
			"Need MasterTerrainBox (Workspace or ServerStorage after Hide) — assignment disabled. See docs/STUDIO_CONTRACT.md"
		)
		return
	end

	local count = 0
	for _ in pairs(slotsById) do
		count += 1
	end
	log("Init complete; available slots=", count)
end

function PlotService.getSlot(plotId: PlotId): PlotSlot?
	return slotsById[plotId]
end

function PlotService.getSlotByIndex(plotIndex: number): PlotSlot?
	return slotsById[plotIdFromIndex(plotIndex)]
end

function PlotService.getPlotCount(): number
	local n = 0
	for _ in pairs(slotsById) do
		n += 1
	end
	return n
end

function PlotService.getPlotIndex(plotId: PlotId): number?
	local slot = slotsById[plotId]
	return if slot then slot.plotIndex else nil
end

function PlotService.getOwnerPlotId(player: Player): PlotId?
	return ownerToPlot[player]
end

local function buildPayload(slot: PlotSlot): PlotBoundsPayload
	return {
		plotId = slot.plotId,
		cframe = slot.cframe,
		size = slot.size,
		spawnCFrame = slot.spawnCFrame,
	}
end

function PlotService.getBoundsPayload(player: Player): PlotBoundsPayload?
	local plotId = ownerToPlot[player]
	if not plotId then
		return nil
	end
	local slot = slotsById[plotId]
	if not slot then
		return nil
	end
	return buildPayload(slot)
end

function PlotService.isInsideOwnerPlot(player: Player, worldPos: Vector3): boolean
	local plotId = ownerToPlot[player]
	if not plotId then
		return false
	end
	local slot = slotsById[plotId]
	if not slot then
		return false
	end
	return GridMath.isInsidePlotXZ(worldPos, slot.cframe, slot.size)
end

function PlotService.assign(player: Player): PlotBoundsPayload?
	if ownerToPlot[player] then
		return PlotService.getBoundsPayload(player)
	end

	for i = 1, Constants.MAX_PLOTS do
		local plotId = plotIdFromIndex(i)
		local slot = slotsById[plotId]
		if slot and slot.owner == nil then
			slot.owner = player
			ownerToPlot[player] = plotId
			local decor = PlotService.getDecorFolder(i)
			log(
				"Assigned",
				player.Name,
				"->",
				plotId,
				"source=",
				slot.sourceName,
				"decor=",
				if decor then decor.Name else "none"
			)
			return buildPayload(slot)
		end
	end

	warnPlot("No free plot for", player.Name, "(server full)")
	return nil
end

function PlotService.teleportToPlot(player: Player)
	local payload = PlotService.getBoundsPayload(player)
	if not payload or not payload.spawnCFrame then
		return
	end
	local character = player.Character
	if not character then
		return
	end
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if hrp and hrp:IsA("BasePart") then
		hrp.CFrame = payload.spawnCFrame :: CFrame
	end
end

function PlotService.free(player: Player)
	local plotId = ownerToPlot[player]
	if not plotId then
		return
	end
	local slot = slotsById[plotId]
	if slot and slot.owner == player then
		slot.owner = nil
	end
	ownerToPlot[player] = nil
	log("Freed", plotId, "from", player.Name)
end

function PlotService.getAvailableCount(): number
	local n = 0
	for _, slot in pairs(slotsById) do
		if slot.owner == nil then
			n += 1
		end
	end
	return n
end

return PlotService
