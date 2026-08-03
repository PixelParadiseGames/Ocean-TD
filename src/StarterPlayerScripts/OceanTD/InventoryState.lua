--!strict
-- Client inventory / backpack selection state. Placement systems subscribe later.

local ItemCatalog = require(game:GetService("ReplicatedStorage"):WaitForChild("OceanTD"):WaitForChild("Shared"):WaitForChild("ItemCatalog"))

local InventoryState = {}

local open = false
local selectedId: string? = nil
local openChanged: BindableEvent = Instance.new("BindableEvent")
local selectionChanged: BindableEvent = Instance.new("BindableEvent")
local itemSlotScreenPosProvider: ((string) -> Vector2?)? = nil

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

-- Slot2 clear-plot confirm / VFX gates place + relocate.
local clearPlotConfirming = false
local clearPlotBusy = false
local savePlotsOpen = false
local savePlotsBusy = false

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

-- Clear-plot or save-plots modal — blocks place / relocate / gamepad arm.
function InventoryState.isBuildModalBlocking(): boolean
	return InventoryState.isClearPlotBlocking() or InventoryState.isSavePlotsBlocking()
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

return InventoryState
