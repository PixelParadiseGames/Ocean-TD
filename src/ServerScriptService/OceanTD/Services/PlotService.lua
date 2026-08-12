--!strict
--[[
	Plot assignment — old-game stable pattern.

	Runtime poses are a deterministic function of MasterTerrainBox only
	(RingMath + ExpansionOffset). PreviewBox_* are Studio stamp helpers;
	they are NOT read for live plot CFrames (avoids box↔terrain drift and
	per-boot TerrainPlotAlign sliding saved locals).

	Hide Previews stashes Master (+ previews) in ServerStorage — runtime
	reads Master from Workspace OR ServerStorage.

	Plot1 = Master.CFrame
	Plot2..N = RingMath.plotCFrame(i, …) matching ArenaGeneratorPlugin.
]]

local Workspace = game:GetService("Workspace")
local ServerStorage = game:GetService("ServerStorage")

local oceanShared = game:GetService("ReplicatedStorage"):WaitForChild("OceanTD"):WaitForChild("Shared")
local Constants = require(oceanShared:WaitForChild("Constants"))
local GridMath = require(oceanShared:WaitForChild("GridMath"))
local RingMath = require(oceanShared:WaitForChild("RingMath"))
local PlotFrameContract = require(oceanShared:WaitForChild("PlotFrameContract"))
local PlotTypes = require(oceanShared:WaitForChild("PlotTypes"))
local SkillStages = require(oceanShared:WaitForChild("SkillStages"))

type PlotBoundsPayload = PlotTypes.PlotBoundsPayload
type PlotId = PlotTypes.PlotId

export type PlotSlot = {
	plotId: PlotId,
	plotIndex: number,
	ringCFrame: CFrame, -- RingMath / Master pose (stable)
	cframe: CFrame, -- active bounds (Plot Size template)
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

	-- Prefer Workspace "Plot 1 Start Point"; remap into this plot's frame (not the raw Plot1 spot).
	local spawnPart: BasePart? = nil
	local wsStart = Workspace:FindFirstChild(Constants.PLOT1_START_POINT_NAME)
	if wsStart and wsStart:IsA("BasePart") then
		spawnPart = wsStart
	end
	if not spawnPart then
		local masterDecor = Workspace:FindFirstChild(Constants.MASTER_DECOR_NAME)
		spawnPart = findBasePart(masterDecor, Constants.SPAWN_NAME)
			or findBasePart(masterDecor, "Plot1 Spawn Point")
			or findBasePart(masterDecor, Constants.PLOT1_START_POINT_NAME)
	end
	if not spawnPart then
		local master = PlotService.getMasterTerrain()
		spawnPart = findBasePart(master, Constants.SPAWN_NAME)
			or findBasePart(master, Constants.PLOT1_START_POINT_NAME)
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
		ringCFrame = cf,
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

-- Primary: MasterTerrainBox + deterministic RingMath (no PreviewBox / no voxel align).
local function initFromMasterAndRing(): boolean
	local master = PlotService.getMasterTerrain()
	if not master then
		return false
	end

	masterPlotCf = master.CFrame
	local size = master.Size
	local expansion = expansionFromMaster(master)
	local masterParent = if master.Parent == ServerStorage then "ServerStorage" else "Workspace"
	local plotCount = Constants.MAX_PLOTS

	local sum = Vector3.zero
	for i = 1, plotCount do
		local cf = RingMath.plotCFrame(i, plotCount, master.CFrame, size, expansion)
		local source = if i == 1
			then (masterParent .. "." .. Constants.MASTER_TERRAIN_NAME)
			else string.format("RingMath.Plot%d (ExpansionOffset=%.2f)", i, expansion)
		registerLogicalSlot(i, cf, size, source)
		sum += cf.Position
	end
	ringCenter = sum / plotCount

	-- Contract guard: every slot must still match RingMath (catches accidental calibrate).
	local driftCount = 0
	for i = 1, plotCount do
		local slot = slotsById[plotIdFromIndex(i)]
		if slot then
			local expected = PlotFrameContract.expectedCFrame(i, plotCount, master.CFrame, size, expansion)
			if not PlotFrameContract.passes(slot.cframe, expected) then
				driftCount += 1
				warnPlot(
					"PlotFrameContract VIOLATION",
					slot.plotId,
					string.format("drift=%.2f studs — do not runtime-calibrate plot CFrames", PlotFrameContract.poseDrift(slot.cframe, expected))
				)
			end
		end
	end

	log(
		"Init from Master + RingMath (stable; no TerrainPlotAlign); ExpansionOffset=",
		expansion,
		"ringCenter≈",
		ringCenter,
		"contractOk=",
		driftCount == 0
	)
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

	local ok = initFromMasterAndRing()
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

local function resolvePlot1CFrame(): CFrame?
	if masterPlotCf then
		return masterPlotCf
	end
	local plot1 = slotsById["Plot1"]
	if plot1 then
		-- Ring pose, not the active Plot Size template (templates are offsets from Master).
		return plot1.ringCFrame
	end
	return nil
end

local function buildPayload(slot: PlotSlot): PlotBoundsPayload
	return {
		plotId = slot.plotId,
		cframe = slot.cframe,
		size = slot.size,
		spawnCFrame = slot.spawnCFrame,
		plot1CFrame = resolvePlot1CFrame(),
		ringCFrame = slot.ringCFrame,
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

function PlotService.getPlotOwner(plotId: PlotId): Player?
	local slot = slotsById[plotId]
	return if slot then slot.owner else nil
end

function PlotService.getRosterPayload(): { { plotId: string, cframe: CFrame, size: Vector3, ownerUserId: number } }
	local out = {}
	for i = 1, Constants.MAX_PLOTS do
		local plotId = plotIdFromIndex(i)
		local slot = slotsById[plotId]
		if slot then
			table.insert(out, {
				plotId = plotId,
				cframe = slot.cframe,
				size = slot.size,
				ownerUserId = if slot.owner then slot.owner.UserId else 0,
			})
		end
	end
	return out
end

local function wrapPlotIndex(i: number): number
	local n = Constants.MAX_PLOTS
	local r = ((i - 1) % n) + 1
	if r < 1 then
		r += n
	end
	return r
end

local function shuffleInPlace(list: { number })
	for i = #list, 2, -1 do
		local j = math.random(1, i)
		list[i], list[j] = list[j], list[i]
	end
end

local function claimSlot(player: Player, plotIndex: number): PlotBoundsPayload?
	local plotId = plotIdFromIndex(plotIndex)
	local slot = slotsById[plotId]
	if not slot or slot.owner ~= nil then
		return nil
	end
	slot.owner = player
	ownerToPlot[player] = plotId
	player:SetAttribute(Constants.PLOT_ID_ATTR, plotId)
	local decor = PlotService.getDecorFolder(plotIndex)
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

-- First player: random free plot. Later joins: seat beside an occupied plot (random side).
local function pickAssignPlotIndex(): number?
	local free: { number } = {}
	local occupied: { number } = {}
	for i = 1, Constants.MAX_PLOTS do
		local slot = slotsById[plotIdFromIndex(i)]
		if slot then
			if slot.owner then
				table.insert(occupied, i)
			else
				table.insert(free, i)
			end
		end
	end
	if #free == 0 then
		return nil
	end
	if #occupied == 0 then
		return free[math.random(1, #free)]
	end

	-- Try each occupied plot (shuffled) and a random neighbor side first.
	shuffleInPlace(occupied)
	for _, anchor in ipairs(occupied) do
		local sides = { -1, 1 }
		if math.random(1, 2) == 2 then
			sides[1], sides[2] = sides[2], sides[1]
		end
		for _, delta in ipairs(sides) do
			local neighbor = wrapPlotIndex(anchor + delta)
			local slot = slotsById[plotIdFromIndex(neighbor)]
			if slot and slot.owner == nil then
				return neighbor
			end
		end
	end

	-- No free adjacent seat — any free slot (shuffled).
	shuffleInPlace(free)
	return free[1]
end

function PlotService.assign(player: Player): PlotBoundsPayload?
	if ownerToPlot[player] then
		return PlotService.getBoundsPayload(player)
	end

	local plotIndex = pickAssignPlotIndex()
	if not plotIndex then
		warnPlot("No free plot for", player.Name, "(server full)")
		return nil
	end
	local payload = claimSlot(player, plotIndex)
	if not payload then
		warnPlot("Failed to claim plot index", plotIndex, "for", player.Name)
		return nil
	end
	return payload
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
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not (hrp and hrp:IsA("BasePart")) then
		return
	end
	local spawnCf = payload.spawnCFrame :: CFrame
	-- Start point parts are often laid flat; keep position + yaw only so the avatar stands upright.
	local flatLook = Vector3.new(spawnCf.LookVector.X, 0, spawnCf.LookVector.Z)
	if flatLook.Magnitude < 1e-3 then
		local flatRight = Vector3.new(spawnCf.RightVector.X, 0, spawnCf.RightVector.Z)
		if flatRight.Magnitude > 1e-3 then
			flatLook = Vector3.new(-flatRight.Z, 0, flatRight.X)
		else
			flatLook = Vector3.new(0, 0, -1)
		end
	else
		flatLook = flatLook.Unit
	end
	local hip = if humanoid then math.max(2.5, humanoid.HipHeight + 1.5) else 3
	local pos = spawnCf.Position + Vector3.new(0, hip, 0)
	hrp.CFrame = CFrame.lookAt(pos, pos + flatLook, Vector3.yAxis)
	hrp.AssemblyLinearVelocity = Vector3.zero
	hrp.AssemblyAngularVelocity = Vector3.zero
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
	player:SetAttribute(Constants.PLOT_ID_ATTR, nil)
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

local function findPlotSizesFolder(): Instance?
	local decor = Workspace:FindFirstChild(Constants.MASTER_DECOR_NAME)
	if not decor then
		return nil
	end
	return decor:FindFirstChild(SkillStages.PLOT_SIZES_FOLDER)
end

function PlotService.getPlotSizeTemplate(stage: number): BasePart?
	local folder = findPlotSizesFolder()
	if not folder then
		return nil
	end
	local name = SkillStages.plotSizePartName(stage)
	local part = folder:FindFirstChild(name)
	if part and part:IsA("BasePart") then
		return part
	end
	return nil
end

function PlotService.getSizeForStage(stage: number): Vector3?
	local part = PlotService.getPlotSizeTemplate(stage)
	if part then
		return part.Size
	end
	-- Fallback: master terrain size for stage 1.
	local master = PlotService.getMasterTerrain()
	if master and SkillStages.clampStage(stage) <= 1 then
		return master.Size
	end
	return nil
end

-- World pose of a PlotSizes template on this slot (Studio CFrame + Size, remapped via ring).
function PlotService.getStageWorldPose(slot: PlotSlot, stage: number): (CFrame?, Vector3?)
	local template = PlotService.getPlotSizeTemplate(stage)
	if not template then
		return nil, nil
	end
	local p1 = resolvePlot1CFrame()
	if not p1 then
		return template.CFrame, template.Size
	end
	local ring = slot.ringCFrame
	local worldCf = ring * p1:ToObjectSpace(template.CFrame)
	return worldCf, template.Size
end

-- Apply Studio PlotSizes box (CFrame + Size) for this player's stage.
function PlotService.setOwnerPlotSize(player: Player, size: Vector3, boundsCf: CFrame?): PlotBoundsPayload?
	local plotId = ownerToPlot[player]
	if not plotId then
		return nil
	end
	local slot = slotsById[plotId]
	if not slot or slot.owner ~= player then
		return nil
	end
	local sx = math.max(4, size.X)
	local sy = math.max(1, size.Y)
	local sz = math.max(4, size.Z)
	local newSize = Vector3.new(sx, sy, sz)
	local newCf = boundsCf or slot.cframe
	local oldCf = slot.cframe
	slot.size = newSize
	slot.cframe = newCf
	-- Keep spawn remapped from ring (avatar start), not the size-box center.
	slot.spawnCFrame = resolveSpawnCFrame(slot.ringCFrame, newSize)
	log("Plot size →", plotId, "size=", slot.size, "pos=", slot.cframe.Position, "for", player.Name)

	if oldCf ~= newCf then
		local GridService = require(script.Parent:WaitForChild("GridService"))
		local PlacementService = require(script.Parent:WaitForChild("PlacementService"))
		GridService.reframe(plotId, oldCf, newCf)
		PlacementService.hydrateVisuals(plotId, newCf)
	end
	return buildPayload(slot)
end

function PlotService.applyOwnerPlotSizeStage(player: Player, stage: number): PlotBoundsPayload?
	local plotId = ownerToPlot[player]
	if not plotId then
		return nil
	end
	local slot = slotsById[plotId]
	if not slot then
		return nil
	end
	local worldCf, size = PlotService.getStageWorldPose(slot, stage)
	if not worldCf or not size then
		warnPlot("PlotSizes template missing for stage", stage)
		return PlotService.getBoundsPayload(player)
	end
	return PlotService.setOwnerPlotSize(player, size, worldCf)
end

return PlotService
