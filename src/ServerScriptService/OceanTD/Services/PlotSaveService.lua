--!strict
--[[
	Named plot-save slots (1–4). Autosave writes the active slot.
	LOAD / NEW switches active slot, credits live corals, applies stored layout, wipes undo.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local oceanShared = ReplicatedStorage:WaitForChild("OceanTD"):WaitForChild("Shared")
local Constants = require(oceanShared:WaitForChild("Constants"))
local ItemCatalog = require(oceanShared:WaitForChild("ItemCatalog"))
local PlotTypes = require(oceanShared:WaitForChild("PlotTypes"))
local LayoutRestore = require(oceanShared:WaitForChild("LayoutRestore"))

local PlotService = require(script.Parent:WaitForChild("PlotService"))
local GridService = require(script.Parent:WaitForChild("GridService"))
local PlayerSession = require(script.Parent:WaitForChild("PlayerSession"))
local PersistenceService = require(script.Parent:WaitForChild("PersistenceService"))
local PlacementService = require(script.Parent:WaitForChild("PlacementService"))
local UndoService = require(script.Parent:WaitForChild("UndoService"))

type LayoutObject = PlotTypes.LayoutObject

local PlotSaveService = {}

local function log(...: any)
	print("[PLOTSAVE]", ...)
end

local function cloneLayout(layout: { LayoutObject }): { LayoutObject }
	local out: { LayoutObject } = {}
	for _, obj in ipairs(layout) do
		table.insert(out, {
			id = obj.id,
			lx = obj.lx,
			ly = obj.ly,
			lz = obj.lz,
			gx = obj.gx,
			gy = obj.gy,
			gz = obj.gz,
			diameter = obj.diameter,
			sizeTier = obj.sizeTier,
			sizeClass = obj.sizeClass,
			colorIndex = obj.colorIndex,
			colorR = obj.colorR,
			colorG = obj.colorG,
			colorB = obj.colorB,
			variantIndex = obj.variantIndex,
			scaleMult = obj.scaleMult,
			scaleWidth = obj.scaleWidth,
			scaleHeight = obj.scaleHeight,
			facingYaw = obj.facingYaw,
			webColorR = obj.webColorR,
			webColorG = obj.webColorG,
			webColorB = obj.webColorB,
			placeId = obj.placeId,
			parentPlaceId = obj.parentPlaceId,
		})
	end
	return out
end

local function countLayout(layout: { LayoutObject }): { [string]: number }
	local tallies: { [string]: number } = {}
	for _, obj in ipairs(layout) do
		tallies[obj.id] = (tallies[obj.id] or 0) + 1
	end
	return tallies
end

local function countsToRows(tallies: { [string]: number }): { { itemId: string, count: number, displayName: string } }
	local rows = {}
	for itemId, count in pairs(tallies) do
		local def = ItemCatalog.get(itemId)
		table.insert(rows, {
			itemId = itemId,
			count = count,
			displayName = if def then def.displayName else itemId,
		})
	end
	table.sort(rows, function(a, b)
		if a.count == b.count then
			return a.displayName < b.displayName
		end
		return a.count > b.count
	end)
	return rows
end

local function clampSlot(index: number): number?
	local idx = math.floor(tonumber(index) or 0)
	if idx < 1 or idx > Constants.PLOT_SAVE_SLOT_COUNT then
		return nil
	end
	return idx
end

local function prepareLayoutForLoad(
	layout: { LayoutObject },
	ringSlot: any,
	savedPlotSizeStage: number?,
	currentPlotSizeStage: number
): { LayoutObject }
	local savedStage = if typeof(savedPlotSizeStage) == "number" then math.floor(savedPlotSizeStage) else nil
	if savedStage and savedStage ~= currentPlotSizeStage then
		local oldCf, _ = PlotService.getStageWorldPose(ringSlot, savedStage)
		local newCf, _ = PlotService.getStageWorldPose(ringSlot, currentPlotSizeStage)
		if oldCf and newCf and oldCf ~= newCf then
			return LayoutRestore.reframeLayout(layout, oldCf, newCf)
		end
	end
	return layout
end

local function persistNow(player: Player, reason: string): boolean
	local plotId = PlotService.getOwnerPlotId(player)
	if not plotId then
		return false
	end
	PlayerSession.setSaving(player, true)
	local layout = PlacementService.snapshotLayout(plotId)
	local ok = PersistenceService.save(player, layout)
	PlayerSession.setSaving(player, false)
	log("Persist", reason, "ok=", ok, player.Name)
	return ok
end

function PlotSaveService.getClientState(player: Player): any
	if not PlayerSession.canSave(player) then
		return { ok = false, errorCode = "NotReady" }
	end
	local saves = PersistenceService.getPlotSaves(player)
	if not saves then
		return { ok = false, errorCode = "NoProfile" }
	end
	local slots = {}
	for i, slot in ipairs(saves.slots) do
		table.insert(slots, {
			index = i,
			name = slot.name,
			saved = slot.saved == true,
			counts = countsToRows(countLayout(slot.layout)),
		})
	end
	-- Live grid tallies (placements since last save) for overwrite / active-slot UI.
	local liveCounts = {}
	local plotId = PlotService.getOwnerPlotId(player)
	if plotId then
		liveCounts = countsToRows(countLayout(GridService.snapshot(plotId)))
	end
	return {
		ok = true,
		activeIndex = saves.activeIndex,
		slots = slots,
		liveCounts = liveCounts,
	}
end

-- Write live plot into slotIndex. Does not change active index unless writing the active slot.
function PlotSaveService.saveSlot(player: Player, slotIndex: number): any
	if not PlayerSession.canSave(player) then
		return { ok = false, errorCode = "NotReady" }
	end
	local idx = clampSlot(slotIndex)
	if not idx then
		return { ok = false, errorCode = "BadSlot" }
	end
	local plotId = PlotService.getOwnerPlotId(player)
	if not plotId then
		return { ok = false, errorCode = "NoPlot" }
	end

	local layout = PlacementService.snapshotLayout(plotId)
	-- Empty saves are allowed; mark intentional so anti-wipe won't block later persist of empty active.
	if #layout == 0 then
		PersistenceService.allowIntentionalClear(player.UserId)
	end

	PersistenceService.writeSlotLayout(player, idx, layout, true)

	-- Keep active slot / profile.layout in sync when saving the live slot.
	if idx == PersistenceService.getActiveSlotIndex(player) then
		persistNow(player, "manual-save-active")
	else
		-- Persist other slots without changing live layout snapshot ownership.
		PlayerSession.setSaving(player, true)
		local activeLayout = PlacementService.snapshotLayout(plotId)
		local ok = PersistenceService.save(player, activeLayout)
		PlayerSession.setSaving(player, false)
		if not ok then
			return { ok = false, errorCode = "SaveFail" }
		end
	end

	log("Saved slot", idx, "for", player.Name, "objects=", #layout)
	return PlotSaveService.getClientState(player)
end

-- LOAD saved slot or NEW empty slot: switch active, credit live corals, apply layout, wipe undo.
function PlotSaveService.loadSlot(player: Player, slotIndex: number): any
	if not PlayerSession.canMutatePlot(player) then
		return { ok = false, errorCode = "NotReady" }
	end
	local idx = clampSlot(slotIndex)
	if not idx then
		return { ok = false, errorCode = "BadSlot" }
	end
	local saves = PersistenceService.getPlotSaves(player)
	if not saves then
		return { ok = false, errorCode = "NoProfile" }
	end
	local target = saves.slots[idx]
	if not target then
		return { ok = false, errorCode = "BadSlot" }
	end

	local plotId = PlotService.getOwnerPlotId(player)
	if not plotId then
		return { ok = false, errorCode = "NoPlot" }
	end

	PlayerSession.setPlotLoading(player, true)

	-- Capture destination layout FIRST — never clobber a saved slot with live before apply.
	local layoutToApply: { LayoutObject }
	local ringSlot = PlotService.getSlot(plotId)
	local currentPlotSizeStage = PersistenceService.getSkillStage(player, "PlotSize")
	if target.saved then
		layoutToApply = prepareLayoutForLoad(cloneLayout(target.layout), ringSlot, target.plotSizeStage, currentPlotSizeStage)
	else
		layoutToApply = {}
	end

	local currentActive = saves.activeIndex
	local leavingSnapshot: { LayoutObject }? = nil
	-- Only auto-save the slot we're leaving. Reloading the same slot must keep its saved meta.
	if currentActive ~= idx then
		leavingSnapshot = PlacementService.snapshotLayout(plotId)
		PersistenceService.writeSlotLayout(player, currentActive, leavingSnapshot, true)
	end
	if not target.saved then
		PersistenceService.writeSlotLayout(player, idx, {}, true)
	end

	local applied = PlacementService.applyLayout(player, layoutToApply)
	if not applied.ok then
		PlayerSession.setPlotLoading(player, false)
		return { ok = false, errorCode = applied.errorCode or "LoadFail" }
	end

	PersistenceService.setActiveSlotIndex(player, idx)
	-- Canonical post-apply snapshot (grid + visuals aligned). Skip if partial restore would wipe saves.
	local persistLayout: { LayoutObject }
	if applied.placed == #layoutToApply then
		persistLayout = PlacementService.snapshotLayout(plotId)
	else
		warn("[PLOTSAVE] Partial layout restore", applied.placed, "/", #layoutToApply, "for", player.Name)
		persistLayout = layoutToApply
	end
	PersistenceService.writeSlotLayout(player, idx, persistLayout, true)
	if #layoutToApply == 0 then
		PersistenceService.allowIntentionalClear(player.UserId)
	end

	UndoService.clear(player)
	PlacementService.clearPendingColorSave(player)
	PlayerSession.setSaving(player, true)
	local ok = PersistenceService.save(player, persistLayout)
	PlayerSession.setSaving(player, false)
	PlayerSession.setPlotLoading(player, false)
	log("Persist load-slot-" .. tostring(idx), "ok=", ok, player.Name)

	log("Loaded slot", idx, "for", player.Name, "placed=", applied.placed, "wasSaved=", target.saved)
	local state = PlotSaveService.getClientState(player)
	state.loadedIndex = idx
	state.placed = applied.placed
	return state
end

function PlotSaveService.renameSlot(player: Player, slotIndex: number, name: string): any
	if not PlayerSession.canSave(player) then
		return { ok = false, errorCode = "NotReady" }
	end
	local idx = clampSlot(slotIndex)
	if not idx then
		return { ok = false, errorCode = "BadSlot" }
	end
	if typeof(name) ~= "string" then
		return { ok = false, errorCode = "BadName" }
	end
	if not PersistenceService.renameSlot(player, idx, name) then
		return { ok = false, errorCode = "NoProfile" }
	end
	-- Persist name without requiring a layout change.
	local plotId = PlotService.getOwnerPlotId(player)
	if plotId then
		PlayerSession.setSaving(player, true)
		PersistenceService.save(player, PlacementService.snapshotLayout(plotId))
		PlayerSession.setSaving(player, false)
	end
	return PlotSaveService.getClientState(player)
end

function PlotSaveService.init()
	log("Init")
end

return PlotSaveService
