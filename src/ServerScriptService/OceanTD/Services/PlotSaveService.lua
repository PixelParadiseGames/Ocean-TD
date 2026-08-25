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
	if not PlayerSession.canSave(player) then
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

	-- Snapshot current work into the current active slot before switching.
	local currentLayout = GridService.snapshot(plotId)
	local currentActive = saves.activeIndex
	PersistenceService.writeSlotLayout(player, currentActive, currentLayout, true)

	local layoutToApply: { LayoutObject }
	if target.saved then
		layoutToApply = cloneLayout(target.layout)
	else
		-- NEW: claim empty preset.
		layoutToApply = {}
		PersistenceService.writeSlotLayout(player, idx, {}, true)
	end

	local applied = PlacementService.applyLayout(player, layoutToApply)
	if not applied.ok then
		return { ok = false, errorCode = applied.errorCode or "LoadFail" }
	end

	PersistenceService.setActiveSlotIndex(player, idx)
	-- Re-write active layout from what actually applied (grid truth).
	local live = GridService.snapshot(plotId)
	PersistenceService.writeSlotLayout(player, idx, live, true)
	if #live == 0 then
		PersistenceService.allowIntentionalClear(player.UserId)
	end

	UndoService.clear(player)
	persistNow(player, "load-slot-" .. tostring(idx))

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
