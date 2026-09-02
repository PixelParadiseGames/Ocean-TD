--!strict
-- Client inventory / backpack selection state. Placement systems subscribe later.

local ItemCatalog = require(game:GetService("ReplicatedStorage"):WaitForChild("OceanTD"):WaitForChild("Shared"):WaitForChild("ItemCatalog"))
local PlotOutlineColors = require(game:GetService("ReplicatedStorage"):WaitForChild("OceanTD"):WaitForChild("Shared"):WaitForChild("PlotOutlineColors"))
local HueSeeds = require(game:GetService("ReplicatedStorage"):WaitForChild("OceanTD"):WaitForChild("Shared"):WaitForChild("HueSeeds"))
local Remotes = require(game:GetService("ReplicatedStorage"):WaitForChild("OceanTD"):WaitForChild("Remotes"))

local InventoryState = {}

local open = false
local selectedId: string? = nil
local openChanged: BindableEvent = Instance.new("BindableEvent")
local selectionChanged: BindableEvent = Instance.new("BindableEvent")
local countsChanged: BindableEvent = Instance.new("BindableEvent")
local itemSlotScreenPosProvider: ((string) -> Vector2?)? = nil
local hueCounts: HueSeeds.HueInventory = {}
local placementHueByItem: { [string]: number } = {}

function InventoryState.isOpen(): boolean
	return open
end

function InventoryState.getSelectedId(): string?
	return selectedId
end

function InventoryState.getSelectedDef()
	if not selectedId then
		return nil
	end
	return ItemCatalog.get(selectedId)
end

function InventoryState.getHueSeedCount(itemId: string, colorIndex: number): number
	return HueSeeds.getCount(hueCounts, itemId, colorIndex)
end

function InventoryState.getSeedCount(itemId: string): number
	return HueSeeds.getSpeciesTotal(hueCounts, itemId)
end

function InventoryState.getOwnedHueIndices(itemId: string): { number }
	return HueSeeds.ownedHueIndices(hueCounts, itemId)
end

function InventoryState.getPlacementHue(itemId: string): number?
	local stored = placementHueByItem[itemId]
	if typeof(stored) == "number" then
		if InventoryState.getHueSeedCount(itemId, stored) > 0 then
			return PlotOutlineColors.clampCoralIndex(stored)
		end
	end
	local first = HueSeeds.pickFirstOwnedHue(hueCounts, itemId)
	if first then
		placementHueByItem[itemId] = first
	end
	return first
end

function InventoryState.cyclePlacementHue(itemId: string, delta: number): number?
	local owned = InventoryState.getOwnedHueIndices(itemId)
	if #owned == 0 then
		placementHueByItem[itemId] = nil
		return nil
	end
	local current = InventoryState.getPlacementHue(itemId) or owned[1]
	local idx = 1
	for i, hue in ipairs(owned) do
		if hue == current then
			idx = i
			break
		end
	end
	local nextIdx = idx + delta
	if nextIdx < 1 then
		nextIdx = #owned
	elseif nextIdx > #owned then
		nextIdx = 1
	end
	local nextHue = owned[nextIdx]
	placementHueByItem[itemId] = nextHue
	countsChanged:Fire()
	return nextHue
end

function InventoryState.formatSeedCount(itemId: string): string
	local n = InventoryState.getSeedCount(itemId)
	if n >= 1000000 then
		local s = string.format("%.1fM", n / 1000000)
		return (string.gsub(s, "%.0M", "M"))
	end
	if n >= 10000 then
		local s = string.format("%.1fk", n / 1000)
		return (string.gsub(s, "%.0k", "k"))
	end
	return tostring(n)
end

function InventoryState.setSeedCounts(raw: any)
	hueCounts = HueSeeds.sanitize(raw, false)
	-- Drop stale placement hues when counts hit zero.
	for itemId, hue in pairs(placementHueByItem) do
		if InventoryState.getHueSeedCount(itemId, hue) <= 0 then
			placementHueByItem[itemId] = nil
		end
	end
	countsChanged:Fire()
end

function InventoryState.onCountsChanged(cb: () -> ()): RBXScriptConnection
	return countsChanged.Event:Connect(cb)
end

function InventoryState.setOpen(value: boolean)
	if open == value then
		return
	end
	open = value
	-- Closing backpack clears selection; PlacementController cancels place on close.
	if not open and selectedId ~= nil then
		selectedId = nil
		selectionChanged:Fire(nil)
	end
	openChanged:Fire(open)
end

function InventoryState.clearSelection()
	if selectedId == nil then
		return
	end
	selectedId = nil
	selectionChanged:Fire(nil)
end

function InventoryState.toggleOpen(): boolean
	InventoryState.setOpen(not open)
	return open
end

-- force=true re-fires even when id is unchanged (TEMP grid: many cells share one catalog id).
function InventoryState.setSelected(id: string?, force: boolean?)
	if id ~= nil and ItemCatalog.get(id) == nil then
		warn("[INV] Unknown item id", id)
		return
	end
	if selectedId == id and not force then
		return
	end
	selectedId = id
	if typeof(id) == "string" then
		InventoryState.getPlacementHue(id)
	end
	selectionChanged:Fire(selectedId)
end

function InventoryState.onOpenChanged(cb: (boolean) -> ()): RBXScriptConnection
	return openChanged.Event:Connect(cb)
end

function InventoryState.onSelectionChanged(cb: (string?) -> ()): RBXScriptConnection
	return selectionChanged.Event:Connect(cb)
end

-- InventoryUI registers this so placement can tween cancel FX into the item cell.
function InventoryState.setItemSlotScreenPosProvider(provider: (string) -> Vector2?)
	itemSlotScreenPosProvider = provider
end

function InventoryState.getItemSlotScreenCenter(itemId: string): Vector2?
	if itemSlotScreenPosProvider then
		return itemSlotScreenPosProvider(itemId)
	end
	return nil
end

-- Center of the open backpack scroll list (Clear Plot orb fly target).
local scrollCenterProvider: (() -> Vector2?)? = nil

function InventoryState.setScrollCenterProvider(provider: () -> Vector2?)
	scrollCenterProvider = provider
end

function InventoryState.getScrollCenter(): Vector2?
	if scrollCenterProvider then
		return scrollCenterProvider()
	end
	return nil
end

-- Quickbar Slot4 (closed backpack button) — seed-wheel fly target.
local backpackButtonScreenPosProvider: (() -> Vector2?)? = nil

function InventoryState.setBackpackButtonScreenPosProvider(provider: () -> Vector2?)
	backpackButtonScreenPosProvider = provider
end

function InventoryState.getBackpackButtonScreenCenter(): Vector2?
	if backpackButtonScreenPosProvider then
		return backpackButtonScreenPosProvider()
	end
	return nil
end

-- Slot2 clear-plot confirm / VFX gates place + relocate.
local clearPlotConfirming = false
local clearPlotBusy = false
local savePlotsOpen = false
local savePlotsBusy = false
local settingsOpen = false

function InventoryState.setClearPlotConfirming(value: boolean)
	clearPlotConfirming = value == true
end

function InventoryState.isClearPlotConfirming(): boolean
	return clearPlotConfirming
end

function InventoryState.setClearPlotBusy(value: boolean)
	clearPlotBusy = value == true
end

function InventoryState.isClearPlotBusy(): boolean
	return clearPlotBusy
end

function InventoryState.isClearPlotBlocking(): boolean
	return clearPlotConfirming or clearPlotBusy
end

function InventoryState.setSavePlotsOpen(value: boolean)
	savePlotsOpen = value == true
end

function InventoryState.isSavePlotsOpen(): boolean
	return savePlotsOpen
end

function InventoryState.setSavePlotsBusy(value: boolean)
	savePlotsBusy = value == true
end

function InventoryState.isSavePlotsBusy(): boolean
	return savePlotsBusy
end

function InventoryState.isSavePlotsBlocking(): boolean
	return savePlotsOpen or savePlotsBusy
end

function InventoryState.setSettingsOpen(value: boolean)
	settingsOpen = value == true
end

function InventoryState.isSettingsOpen(): boolean
	return settingsOpen
end

-- Clear-plot, save-plots, or settings modal — blocks place / relocate / gamepad arm.
function InventoryState.isBuildModalBlocking(): boolean
	return InventoryState.isClearPlotBlocking() or InventoryState.isSavePlotsBlocking() or settingsOpen
end

-- True when the pointer is over the open backpack panel (scroll list / chrome).
local backpackHitTest: ((Vector2) -> boolean)? = nil

function InventoryState.setBackpackHitTest(provider: (Vector2) -> boolean)
	backpackHitTest = provider
end

function InventoryState.isPointerOverBackpack(screenPos: Vector2): boolean
	if not open or not backpackHitTest then
		return false
	end
	return backpackHitTest(screenPos)
end

task.spawn(function()
	local sync = Remotes.get("InventorySync")
	sync.OnClientEvent:Connect(function(payload)
		InventoryState.setSeedCounts(payload)
	end)
end)

return InventoryState
