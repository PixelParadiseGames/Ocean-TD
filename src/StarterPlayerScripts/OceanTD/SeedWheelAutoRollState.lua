--!strict
--[[ Client mirror of seed-wheel auto-roll enabled (server authoritative). ]]

local SeedWheelAutoRollState = {}

local enabled = true
local changed = Instance.new("BindableEvent")

function SeedWheelAutoRollState.isEnabled(): boolean
	return enabled
end

function SeedWheelAutoRollState._setEnabled(value: boolean)
	local next = value == true
	if enabled == next then
		return
	end
	enabled = next
	changed:Fire(enabled)
end

function SeedWheelAutoRollState.onChanged(fn: (boolean) -> ()): RBXScriptConnection
	return changed.Event:Connect(fn)
end

return SeedWheelAutoRollState
