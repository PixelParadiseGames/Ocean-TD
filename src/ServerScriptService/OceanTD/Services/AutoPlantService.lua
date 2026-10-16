--!strict
--[[
	Auto-plant: place rolled seeds onto authored spots; shuffle in-bounds corals.
	Spots authored on Workspace.MasterPlotDecor.AutoPlantLocations.Plot1 (Attachments).
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")

local oceanShared = ReplicatedStorage:WaitForChild("OceanTD"):WaitForChild("Shared")
local Constants = require(oceanShared:WaitForChild("Constants"))
local AutoPlantSpots = require(oceanShared:WaitForChild("AutoPlantSpots"))
local GridMath = require(oceanShared:WaitForChild("GridMath"))
local PlotOutlineColors = require(oceanShared:WaitForChild("PlotOutlineColors"))
local HueSeeds = require(oceanShared:WaitForChild("HueSeeds"))
local SkillStages = require(oceanShared:WaitForChild("SkillStages"))
local Remotes = require(ReplicatedStorage:WaitForChild("OceanTD"):WaitForChild("Remotes"))

local PlotService = require(script.Parent:WaitForChild("PlotService"))
local GridService = require(script.Parent:WaitForChild("GridService"))
local PlayerSession = require(script.Parent:WaitForChild("PlayerSession"))
local PersistenceService = require(script.Parent:WaitForChild("PersistenceService"))
local PlacementService = require(script.Parent:WaitForChild("PlacementService"))
local UndoService = require(script.Parent:WaitForChild("UndoService"))

local AutoPlantService = {}

type MasterSpot = AutoPlantSpots.Spot

local masterSpots: { MasterSpot } = {}
local masterLoaded = false
local shuffleCooldownUntil: { [number]: number } = {}

local function log(...: any)
	print("[AUTOPLANT]", ...)
end

local function warnAuto(...: any)
	warn("[AUTOPLANT]", ...)
end

local function loadMasterSpots()
	if masterLoaded then
		return
	end
	masterLoaded = true
	masterSpots = {}
	local decor = Workspace:FindFirstChild(Constants.MASTER_DECOR_NAME)
	if not decor then
		warnAuto(Constants.MASTER_DECOR_NAME, "missing — no auto-plant spots")
		return
	end
	local folder = decor:FindFirstChild(AutoPlantSpots.GUIDE_FOLDER)
	local guide = if folder then folder:FindFirstChild(AutoPlantSpots.GUIDE_PART) else nil
	if not guide or not guide:IsA("BasePart") then
		warnAuto("Guide part missing at", AutoPlantSpots.GUIDE_FOLDER .. "." .. AutoPlantSpots.GUIDE_PART)
		return
	end
	-- Ring pose is stable across Plot Size stages (active cframe is the size template).
	local plot1 = PlotService.getSlotByIndex(1)
	local basisCf = if plot1 then plot1.ringCFrame else guide.CFrame
	for _, child in ipairs(guide:GetChildren()) do
		if not child:IsA("Attachment") then
			continue
		end
		local xIndex, zIndex = AutoPlantSpots.parseAttachmentName(child.Name)
		if typeof(xIndex) ~= "number" or typeof(zIndex) ~= "number" then
			continue
		end
		local world = child.WorldPosition
		local localPos = basisCf:PointToObjectSpace(world)
		table.insert(masterSpots, {
			name = child.Name,
			xIndex = xIndex,
			zIndex = zIndex,
			localPos = localPos,
		})
	end
	table.sort(masterSpots, function(a, b)
		if a.zIndex == b.zIndex then
			return a.xIndex < b.xIndex
		end
		return a.zIndex < b.zIndex
	end)
	log("Loaded", #masterSpots, "master spots")
end

local function worldSpotsForPlayer(player: Player): { Vector3 }
	loadMasterSpots()
	local plotId = PlotService.getOwnerPlotId(player)
	local slot = if plotId then PlotService.getSlot(plotId) else nil
	if not slot then
		return {}
	end
	local stage = PersistenceService.getSkillStage(player, "PlotSize")
	local out: { Vector3 } = {}
	for _, spot in ipairs(masterSpots) do
		if AutoPlantSpots.isXInStage(spot.xIndex, stage) then
			local world = slot.ringCFrame:PointToWorldSpace(spot.localPos)
			-- Must sit inside the live Plot Size bounds (place/move reject otherwise).
			if PlotService.isInsideOwnerPlot(player, world) then
				table.insert(out, world)
			end
		end
	end
	return out
end

local function collectOccupiedWorld(plotId: string): { Vector3 }
	local occupied: { Vector3 } = {}
	local slot = PlotService.getSlot(plotId)
	if not slot then
		return occupied
	end
	GridService.forEachCell(plotId, function(cell)
		table.insert(occupied, GridMath.plotLocalToWorld(Vector3.new(cell.lx, cell.ly, cell.lz), slot.cframe))
	end)
	return occupied
end

local function isSpotFree(plotId: string, worldPos: Vector3, radius: number): boolean
	local slot = PlotService.getSlot(plotId)
	if not slot then
		return false
	end
	local localPos = GridMath.worldToPlotLocal(worldPos, slot.cframe)
	local gx, gy, gz = GridMath.worldToGrid(localPos, Vector3.zero)
	if GridService.getCellAtGrid(plotId, gx, gy, gz) then
		return false
	end
	-- Soft radius check vs other cell centers (XZ).
	local free = true
	GridService.forEachCell(plotId, function(cell)
		if not free then
			return
		end
		local other = GridMath.plotLocalToWorld(Vector3.new(cell.lx, cell.ly, cell.lz), slot.cframe)
		local d = (Vector3.new(worldPos.X, 0, worldPos.Z) - Vector3.new(other.X, 0, other.Z)).Magnitude
		if d < radius then
			free = false
		end
	end)
	return free
end

local function plotCoralCount(player: Player): number
	local plotId = PlotService.getOwnerPlotId(player)
	if not plotId then
		return 0
	end
	return GridService.getPlotCount(plotId)
end

function AutoPlantService.isUnlocked(player: Player): boolean
	local need = AutoPlantSpots.MANUAL_UNLOCK_COUNT
	local onPlot = plotCoralCount(player)
	-- Latch lifetime unlock once earned so clear / empty load doesn't re-lock ADD MAX.
	if onPlot >= need then
		PersistenceService.ensureAutoPlantUnlocked(player, need)
	end
	return onPlot >= need or PersistenceService.getManualPlantCount(player) >= need
end

-- Unique empty grid seats among authored auto-plant spots (no soft radius).
-- Radius filtering under-counted seats and left "add again for 39 / 1" leftovers;
-- place() only cares about the grid cell being free.
local function collectFreeGridSpots(player: Player): { Vector3 }
	local plotId = PlotService.getOwnerPlotId(player)
	local slot = if plotId then PlotService.getSlot(plotId) else nil
	if not plotId or not slot then
		return {}
	end
	local seen: { [string]: boolean } = {}
	local free: { Vector3 } = {}
	for _, worldPos in ipairs(worldSpotsForPlayer(player)) do
		local localPos = GridMath.worldToPlotLocal(worldPos, slot.cframe)
		local gx, gy, gz = GridMath.worldToGrid(localPos, Vector3.zero)
		local key = string.format("%d:%d:%d", gx, gy, gz)
		if seen[key] then
			continue
		end
		seen[key] = true
		if GridService.getCellAtGrid(plotId, gx, gy, gz) then
			continue
		end
		table.insert(free, worldPos)
	end
	return free
end

local function backpackSeedTotal(player: Player): number
	local payload = PersistenceService.getInventoryPayload(player)
	local sum = 0
	for itemId, bucket in pairs(payload) do
		if typeof(itemId) == "string" and typeof(bucket) == "table" then
			sum += HueSeeds.getSpeciesTotal(payload, itemId)
		end
	end
	return sum
end

local function placeCapRoom(player: Player): number
	local plotId = PlotService.getOwnerPlotId(player)
	if not plotId then
		return 0
	end
	local stage = PersistenceService.getSkillStage(player, "PlaceMore")
	local placeMax = SkillStages.placeMoreMaxAtStage(stage)
	return math.max(0, placeMax - GridService.getPlotCount(plotId))
end

function AutoPlantService.getAddMaxCapacity(player: Player): number
	return math.min(backpackSeedTotal(player), #collectFreeGridSpots(player), placeCapRoom(player))
end

function AutoPlantService.syncToClient(player: Player)
	local unlocked = AutoPlantService.isUnlocked(player)
	if not unlocked and PersistenceService.isAutoPlantEnabled(player) then
		-- Dropped below 3 on-plot corals — toggle turns off until they qualify again.
		PersistenceService.setAutoPlantEnabled(player, false)
	end
	local enabled = unlocked and PersistenceService.isAutoPlantEnabled(player)
	local cdLeft = 0
	local untilT = shuffleCooldownUntil[player.UserId]
	if typeof(untilT) == "number" then
		cdLeft = math.max(0, untilT - os.clock())
	end
	local onPlot = plotCoralCount(player)
	local seeds = backpackSeedTotal(player)
	local freeSpots = #collectFreeGridSpots(player)
	local capRoom = placeCapRoom(player)
	Remotes.get("AutoPlantSync"):FireClient(player, {
		unlocked = unlocked,
		enabled = enabled,
		plotCoralCount = onPlot,
		manualPlantCount = onPlot, -- UI hint: corals currently on plot
		shuffleCooldownSec = cdLeft,
		backpackSeedCount = seeds,
		freeSpotCount = freeSpots,
		placeCapRoom = capRoom,
		addMaxCapacity = math.min(seeds, freeSpots, capRoom),
	})
end

function AutoPlantService.setEnabled(player: Player, enabled: boolean): { ok: boolean, errorCode: string?, enabled: boolean?, unlocked: boolean? }
	local unlocked = AutoPlantService.isUnlocked(player)
	if not unlocked then
		return { ok = false, errorCode = "Locked", unlocked = false, enabled = false }
	end
	PersistenceService.setAutoPlantEnabled(player, enabled == true)
	AutoPlantService.syncToClient(player)
	return {
		ok = true,
		unlocked = true,
		enabled = PersistenceService.isAutoPlantEnabled(player),
	}
end

-- After a seed grant would go to inventory: try place on a spaced empty spot.
-- Returns true if the seed was consumed by a successful place.
function AutoPlantService.tryPlaceGrantedSeed(player: Player, itemId: string, colorIndex: number): boolean
	if not PersistenceService.isAutoPlantEnabled(player) then
		return false
	end
	if not AutoPlantService.isUnlocked(player) then
		return false
	end
	if not PlayerSession.canSave(player) then
		return false
	end
	local plotId = PlotService.getOwnerPlotId(player)
	if not plotId then
		return false
	end
	local spots = worldSpotsForPlayer(player)
	if #spots == 0 then
		return false
	end
	local free: { Vector3 } = {}
	for _, worldPos in ipairs(spots) do
		if isSpotFree(plotId, worldPos, 2.5) then
			table.insert(free, worldPos)
		end
	end
	if #free == 0 then
		return false
	end
	local occupied = collectOccupiedWorld(plotId)
	local pick = AutoPlantSpots.pickSpacedWorld(free, occupied)
	if not pick then
		return false
	end
	local hue = PlotOutlineColors.clampCoralIndex(colorIndex)
	-- Seed must exist in inventory for place() debit — caller credits first.
	local result = PlacementService.place(player, itemId, pick, true, {
		placementHue = hue,
	})
	if result.ok then
		-- Apply the granted hue as paint (seedHue alone leaves species-default look).
		local placeId = result.placeId
		if typeof(placeId) == "string" and placeId ~= "" then
			PlacementService.setCoralColor(player, placeId, hue, nil, nil, nil, nil, nil, nil, nil, true)
		end
		log("Auto-placed", itemId, "hue", hue, "for", player.Name)
		Remotes.get("AutoPlantPlaced"):FireClient(player, {
			itemId = itemId,
			colorIndex = hue,
			worldPos = pick,
			placeId = placeId,
		})
		AutoPlantService.syncToClient(player)
		return true
	end
	return false
end

export type ShuffleMove = {
	placeId: string,
	itemId: string,
	fromWorldPos: Vector3,
	toWorldPos: Vector3,
	fromFacingYaw: number?,
	toFacingYaw: number?,
}

function AutoPlantService.shuffle(player: Player): {
	ok: boolean,
	errorCode: string?,
	moved: number?,
	cooldownSec: number?,
}
	if not PlayerSession.canSave(player) then
		return { ok = false, errorCode = "Busy" }
	end
	if PlacementService.isShuffleVisualBusy(player) then
		return { ok = false, errorCode = "Busy" }
	end
	local now = os.clock()
	local untilT = shuffleCooldownUntil[player.UserId]
	if typeof(untilT) == "number" and untilT > now then
		return { ok = false, errorCode = "Cooldown", cooldownSec = untilT - now }
	end
	local plotId = PlotService.getOwnerPlotId(player)
	local slot = if plotId then PlotService.getSlot(plotId) else nil
	if not plotId or not slot then
		return { ok = false, errorCode = "NoPlot" }
	end
	if not PlayerSession.tryBeginPlotOp(player, "shuffling") then
		return { ok = false, errorCode = "Busy" }
	end

	local spots = worldSpotsForPlayer(player)
	local corals: { { placeId: string, itemId: string, worldPos: Vector3, cell: any } } = {}
	GridService.forEachCell(plotId, function(cell)
		if cell.ownerUserId ~= player.UserId then
			return
		end
		local pid = cell.placeId
		if typeof(pid) ~= "string" or pid == "" then
			return
		end
		local world = GridMath.plotLocalToWorld(Vector3.new(cell.lx, cell.ly, cell.lz), slot.cframe)
		table.insert(corals, {
			placeId = pid,
			itemId = cell.id,
			worldPos = world,
			cell = cell,
		})
	end)

	if #corals == 0 then
		PlayerSession.endPlotOp(player)
		return { ok = false, errorCode = "Empty" }
	end
	if #spots == 0 then
		PlayerSession.endPlotOp(player)
		return { ok = false, errorCode = "NoSpots" }
	end

	local rng = Random.new()
	-- Fisher–Yates shuffle corals; first min(n,spots) get new homes.
	for i = #corals, 2, -1 do
		local j = rng:NextInteger(1, i)
		corals[i], corals[j] = corals[j], corals[i]
	end
	local moveCount = math.min(#corals, #spots)
	local destPool: { Vector3 } = {}
	for _, p in ipairs(spots) do
		table.insert(destPool, p)
	end
	for i = #destPool, 2, -1 do
		local j = rng:NextInteger(1, i)
		destPool[i], destPool[j] = destPool[j], destPool[i]
	end

	-- Spaced assignment into destPool[1..moveCount]
	local assigned: { Vector3 } = {}
	local targets: { Vector3 } = {}
	for i = 1, moveCount do
		local remaining: { Vector3 } = {}
		local remIndex: { number } = {}
		for k = i, #destPool do
			table.insert(remaining, destPool[k])
			table.insert(remIndex, k)
		end
		local pick = AutoPlantSpots.pickSpacedWorld(remaining, assigned, rng) or remaining[1]
		local pickK = i
		for ri, k in ipairs(remIndex) do
			if remaining[ri] == pick then
				pickK = k
				break
			end
		end
		destPool[i], destPool[pickK] = destPool[pickK], destPool[i]
		table.insert(assigned, destPool[i])
		targets[i] = destPool[i]
	end

	-- Plan moves first, then tell the client immediately so tweens start while we apply grid.
	local planned: { ShuffleMove } = {}
	for i = 1, moveCount do
		local coral = corals[i]
		local toPos = targets[i]
		local cellYaw = coral.cell.facingYaw
		local fromYaw = if typeof(cellYaw) == "number" and cellYaw == cellYaw then cellYaw else 0
		local toYaw = rng:NextNumber(0, math.pi * 2)
		-- Always include: even a near-same spot still gets a new facing.
		table.insert(planned, {
			placeId = coral.placeId,
			itemId = coral.itemId,
			fromWorldPos = coral.worldPos,
			toWorldPos = toPos,
			fromFacingYaw = fromYaw,
			toFacingYaw = toYaw,
		})
	end

	local cd = AutoPlantSpots.SHUFFLE_COOLDOWN_SEC
	shuffleCooldownUntil[player.UserId] = os.clock() + cd
	PlacementService.markShuffleVisualBusy(player)
	Remotes.get("AutoPlantShuffleApplied"):FireClient(player, {
		moves = planned,
		cooldownSec = cd,
	})
	AutoPlantService.syncToClient(player)

	-- Vacate-all then occupy — avoids SpotTaken mid-permutation.
	local moves, failedMoves = PlacementService.applyShuffleMoveBatch(player, planned)
	local moved = #moves
	if #failedMoves > 0 then
		log("Shuffle partial", player.Name, "failed=", #failedMoves)
	end

	if moved > 0 then
		UndoService.push(player, {
			kind = "shuffle",
			placeId = "shuffle",
			itemId = "shuffle",
			shuffleMoves = moves,
		})
		-- Grid already has new seats — snapshot from cells (not visual CFrame) so leave/save
		-- persist the shuffle. Defer visual snap so the client stagger tween can play first.
		local settlePlotId = plotId
		local settleMoves = moves
		task.delay(2.8, function()
			for _, mv in ipairs(settleMoves) do
				PlacementService.snapVisualWorld(settlePlotId, mv.placeId, mv.toWorldPos)
			end
		end)
		task.spawn(function()
			if not player.Parent then
				return
			end
			local layout = PlacementService.snapshotLayout(settlePlotId)
			PersistenceService.save(player, layout)
		end)
	end

	PlayerSession.endPlotOp(player)
	log("Shuffle", player.Name, "moved=", moved, "/", moveCount)
	-- Remaining time only — full duration was already sent on AutoPlantShuffleApplied.
	-- Returning the full CD here re-starts the client timer after a long grid apply.
	local cdLeft = 0
	local untilT = shuffleCooldownUntil[player.UserId]
	if typeof(untilT) == "number" then
		cdLeft = math.max(0, untilT - os.clock())
	end
	return { ok = true, moved = moved, cooldownSec = cdLeft, moves = moves }
end

export type AddMaxPlacement = {
	placeId: string,
	itemId: string,
	colorIndex: number,
	worldPos: Vector3,
}

-- Build N species picks with roughly equal counts across species that have seeds.
local function planEqualSpeciesPicks(
	inv: HueSeeds.HueInventory,
	count: number,
	rng: Random
): { { itemId: string, hue: number } }
	local picks: { { itemId: string, hue: number } } = {}
	if count <= 0 then
		return picks
	end
	-- Working counts per species → hue.
	type HueBag = { [number]: number }
	local bySpecies: { [string]: HueBag } = {}
	local speciesList: { string } = {}
	local remainingBySpecies: { [string]: number } = {}
	for itemId, bucket in pairs(inv) do
		if typeof(itemId) ~= "string" or typeof(bucket) ~= "table" then
			continue
		end
		local total = HueSeeds.getSpeciesTotal(inv, itemId)
		if total <= 0 then
			continue
		end
		local hues: HueBag = {}
		for k, v in pairs(bucket) do
			local idx = tonumber(k)
			local n = tonumber(v)
			if typeof(idx) == "number" and typeof(n) == "number" and n > 0 then
				hues[PlotOutlineColors.clampCoralIndex(idx)] = math.floor(n)
			end
		end
		if next(hues) then
			bySpecies[itemId] = hues
			remainingBySpecies[itemId] = total
			table.insert(speciesList, itemId)
		end
	end
	if #speciesList == 0 then
		return picks
	end
	table.sort(speciesList)

	local function pickHue(itemId: string): number?
		local hues = bySpecies[itemId]
		if not hues then
			return nil
		end
		local options: { number } = {}
		for hue, n in pairs(hues) do
			if n > 0 then
				table.insert(options, hue)
			end
		end
		if #options == 0 then
			return nil
		end
		local hue = options[rng:NextInteger(1, #options)]
		hues[hue] = (hues[hue] or 0) - 1
		remainingBySpecies[itemId] = math.max(0, (remainingBySpecies[itemId] or 0) - 1)
		return hue
	end

	-- Round-robin across species that still have seeds until N picks.
	local cursor = rng:NextInteger(1, #speciesList)
	local guard = 0
	while #picks < count and guard < count * (#speciesList + 2) do
		guard += 1
		local made = false
		for offset = 0, #speciesList - 1 do
			local idx = ((cursor - 1 + offset) % #speciesList) + 1
			local itemId = speciesList[idx]
			if (remainingBySpecies[itemId] or 0) > 0 then
				local hue = pickHue(itemId)
				if hue then
					table.insert(picks, { itemId = itemId, hue = hue })
					cursor = idx % #speciesList + 1
					made = true
					break
				end
			end
		end
		if not made then
			break
		end
	end
	return picks
end

function AutoPlantService.addMax(player: Player, requested: number): {
	ok: boolean,
	errorCode: string?,
	placed: number?,
	placements: { AddMaxPlacement }?,
	addMaxCapacity: number?,
}
	if not AutoPlantService.isUnlocked(player) then
		return { ok = false, errorCode = "Locked" }
	end
	PersistenceService.ensureAutoPlantUnlocked(player, AutoPlantSpots.MANUAL_UNLOCK_COUNT)
	if not PlayerSession.canSave(player) then
		return { ok = false, errorCode = "Busy" }
	end
	if PlacementService.isShuffleVisualBusy(player) then
		return { ok = false, errorCode = "Busy" }
	end
	local plotId = PlotService.getOwnerPlotId(player)
	if not plotId then
		return { ok = false, errorCode = "NoPlot" }
	end

	local free = collectFreeGridSpots(player)
	local seeds = backpackSeedTotal(player)
	local room = placeCapRoom(player)
	local capacity = math.min(seeds, #free, room)
	local want = math.floor(tonumber(requested) or 0)
	if want ~= want or want < 1 then
		return { ok = false, errorCode = "BadCount", addMaxCapacity = capacity }
	end
	local n = math.min(want, capacity)
	if n < 1 or #free == 0 then
		return { ok = false, errorCode = "Empty", addMaxCapacity = capacity }
	end

	local invPayload = PersistenceService.getInventoryPayload(player)
	-- Deep-ish working copy for planning (HueSeeds mutates tables in place).
	local working: HueSeeds.HueInventory = HueSeeds.sanitize(invPayload, false)
	local rng = Random.new()
	local planned = planEqualSpeciesPicks(working, n, rng)
	if #planned == 0 then
		return { ok = false, errorCode = "Empty", addMaxCapacity = capacity }
	end

	-- Assign seats first, notify client to hide+start orbs, THEN place (fast path).
	-- Client must learn placeIds before parts replicate or corals flash into view.
	local occupied = collectOccupiedWorld(plotId)
	local freeLeft: { Vector3 } = {}
	for _, p in ipairs(free) do
		table.insert(freeLeft, p)
	end

	local plannedPlacements: { AddMaxPlacement } = {}
	-- TEMP: placeIds whose planned hue was missing/invalid → teal default.
	local hueDefaultedPlaceIds: { [string]: boolean } = {}
	for _, pick in ipairs(planned) do
		if #freeLeft == 0 or #plannedPlacements >= n then
			break
		end
		local dest = AutoPlantSpots.pickSpacedWorld(freeLeft, occupied, rng) or freeLeft[1]
		for i = #freeLeft, 1, -1 do
			if freeLeft[i] == dest then
				table.remove(freeLeft, i)
				break
			end
		end
		local rawHue = pick.hue
		local hue = PlotOutlineColors.clampCoralIndex(rawHue)
		local placeId = HttpService:GenerateGUID(false)
		if PlotOutlineColors.isMissingCoralIndex(rawHue) then
			hueDefaultedPlaceIds[placeId] = true
		end
		table.insert(plannedPlacements, {
			placeId = placeId,
			itemId = pick.itemId,
			colorIndex = hue,
			worldPos = dest,
		})
		table.insert(occupied, dest)
	end
	if #plannedPlacements == 0 then
		return { ok = false, errorCode = "NoSpots", addMaxCapacity = capacity }
	end

	local vfxLock = math.clamp(1.4 + #plannedPlacements * 0.09 + 3.2, 4, 16)
	PlacementService.markShuffleVisualBusy(player, vfxLock)
	-- Hide watcher + staggered orbs start before any coral replicates.
	Remotes.get("AutoPlantAddMaxApplied"):FireClient(player, {
		placements = plannedPlacements,
	})

	PlacementService.setSuppressUndo(true)
	local undoEntries: { any } = {}
	local placements: { AddMaxPlacement } = {}
	for _, pl in ipairs(plannedPlacements) do
		local result = PlacementService.place(player, pl.itemId, pl.worldPos, true, {
			placementHue = pl.colorIndex,
			placeId = pl.placeId,
			hideAwaitOrb = true,
		})
		if result.ok then
			PlacementService.paintPlacedHueFast(player, pl.placeId, pl.colorIndex)
			-- TEMP: red-dot if planning collapsed a missing/invalid hue to teal.
			if hueDefaultedPlaceIds[pl.placeId] then
				PlacementService.tagHueDefaultedByPlaceId(plotId, pl.placeId, "addMax.plan")
			end
			-- Re-hide after paint (mesh accents / web parts may appear during color apply).
			PlacementService.hideVisualAwaitOrb(plotId, pl.placeId)
			table.insert(placements, pl)
			table.insert(undoEntries, {
				placeId = pl.placeId,
				itemId = pl.itemId,
				worldPos = pl.worldPos,
				seedHue = pl.colorIndex,
			})
		end
	end
	PlacementService.setSuppressUndo(false)

	local placed = #placements
	if placed == 0 then
		local remaining = AutoPlantService.getAddMaxCapacity(player)
		AutoPlantService.syncToClient(player)
		return { ok = false, errorCode = "PlaceFail", placed = 0, addMaxCapacity = remaining }
	end

	UndoService.push(player, {
		kind = "addMax",
		placeId = "addMax",
		itemId = "addMax",
		entries = undoEntries,
	})

	task.spawn(function()
		if not player.Parent then
			return
		end
		local layout = PlacementService.snapshotLayout(plotId)
		PersistenceService.save(player, layout)
	end)

	local remaining = AutoPlantService.getAddMaxCapacity(player)
	AutoPlantService.syncToClient(player)
	log("AddMax", player.Name, "placed=", placed, "/", #plannedPlacements, "left=", remaining)
	return {
		ok = true,
		placed = placed,
		placements = placements,
		addMaxCapacity = remaining,
	}
end

function AutoPlantService.init()
	loadMasterSpots()
end

return AutoPlantService
