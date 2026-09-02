--!strict
-- Client mirror of profile.coralColorUnlocks + lock overlay helper.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local Remotes = require(oceanRoot:WaitForChild("Remotes"))
local ColorUnlocks = require(oceanRoot:WaitForChild("Shared"):WaitForChild("ColorUnlocks"))

local CoralColorUnlockState = {}

local unlocks: ColorUnlocks.UnlockMap = {}
local changed: BindableEvent = Instance.new("BindableEvent")

function CoralColorUnlockState.setAll(raw: any)
	unlocks = ColorUnlocks.sanitize(raw)
	changed:Fire()
end

function CoralColorUnlockState.isUnlocked(itemId: string, colorIndex: number): boolean
	local InventoryState = require(script.Parent:WaitForChild("InventoryState"))
	return InventoryState.getHueSeedCount(itemId, colorIndex) > 0
end

function CoralColorUnlockState.markUnlocked(itemId: string, colorIndex: number)
	-- Inventory sync is authoritative after $D seed purchase.
	if typeof(itemId) ~= "string" or itemId == "" then
		return
	end
	changed:Fire()
end

function CoralColorUnlockState.onChanged(cb: () -> ()): RBXScriptConnection
	return changed.Event:Connect(cb)
end

function CoralColorUnlockState.createLockOverlay(parent: Instance, zIndex: number): ImageLabel
	local img = Instance.new("ImageLabel")
	img.Name = "_OceanTD_ColorLock"
	img.BackgroundTransparency = 1
	img.AnchorPoint = Vector2.new(0.5, 0.5)
	img.Position = UDim2.fromScale(0.5, 0.5)
	img.Size = UDim2.fromScale(0.62, 0.62)
	img.Image = ColorUnlocks.LOCK_ICON
	img.ScaleType = Enum.ScaleType.Fit
	img.ZIndex = zIndex
	img.Active = false
	img.Parent = parent
	return img
end

function CoralColorUnlockState.setLockVisible(lock: ImageLabel?, visible: boolean, fade: number?)
	if not lock then
		return
	end
	lock.Visible = visible
	if visible and typeof(fade) == "number" then
		lock.ImageTransparency = math.clamp(fade, 0, 1)
	else
		lock.ImageTransparency = 0
	end
end

Remotes.get("CoralColorUnlocksSync").OnClientEvent:Connect(function(payload: any)
	CoralColorUnlockState.setAll(payload)
end)

return CoralColorUnlockState
