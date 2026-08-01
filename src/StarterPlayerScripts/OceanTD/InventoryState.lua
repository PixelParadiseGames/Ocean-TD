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

return InventoryState
