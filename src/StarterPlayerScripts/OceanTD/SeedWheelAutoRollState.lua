--!strict
--[[ Client mirror of seed-wheel auto-roll enabled + remaining budget (server authoritative). ]]

local SeedWheelAutoRollState = {}

local enabled = false
local remaining: number? = nil -- math.huge = unlimited
local manualArmed = false
local changed = Instance.new("BindableEvent")
local remainingChanged = Instance.new("BindableEvent")
local flyRemaining = Instance.new("BindableEvent")

function SeedWheelAutoRollState.armManual()
	manualArmed = true
end

function SeedWheelAutoRollState.consumeManual(): boolean
	if not manualArmed then
		return false
	end
	manualArmed = false
	return true
end

function SeedWheelAutoRollState.isEnabled(): boolean
	return enabled
end

function SeedWheelAutoRollState.getRemaining(): number?
	return remaining
end

function SeedWheelAutoRollState._setRemaining(value: number?)
	local next: number? = nil
	if typeof(value) == "number" then
		if value < 0 or value == math.huge then
			next = math.huge
		else
			next = math.max(0, math.floor(value))
		end
	end
	if remaining == next then
		return
	end
	remaining = next
	remainingChanged:Fire(remaining)
end

function SeedWheelAutoRollState._setEnabled(value: boolean)
	local next = value == true
	if enabled == next then
		return
	end
	enabled = next
	if not enabled then
		SeedWheelAutoRollState._setRemaining(nil)
	end
	changed:Fire(enabled)
end

-- Apply sync payload: enabled + optional remaining (-1 = unlimited on the wire).
function SeedWheelAutoRollState.applySync(enabledValue: any, remainingValue: any)
	local on = enabledValue == true
	if on then
		local rem: number? = nil
		if typeof(remainingValue) == "number" then
			if remainingValue < 0 then
				rem = math.huge
			else
				rem = math.max(0, math.floor(remainingValue))
			end
		end
		-- Set remaining before enabled so UI can read budget when onChanged fires.
		if rem ~= nil then
			remaining = rem
			remainingChanged:Fire(remaining)
		elseif remaining == nil then
			-- Keep prior optimistic remaining if server omitted it.
		end
		if not enabled then
			enabled = true
			changed:Fire(true)
		end
	else
		SeedWheelAutoRollState._setEnabled(false)
	end
end

-- During backpack slide: fire once with (before, after?). after=nil → ∞ only.
-- UI owns the long slide-in/out countdown timing.
function SeedWheelAutoRollState.beginFlyRemainingTick()
	if not enabled then
		return
	end
	local before = remaining
	if before == nil then
		return
	end
	local after: number? = nil
	if before ~= math.huge then
		after = math.max(0, before - 1)
	end
	flyRemaining:Fire(before, after)
end

function SeedWheelAutoRollState.onChanged(fn: (boolean) -> ()): RBXScriptConnection
	return changed.Event:Connect(fn)
end

function SeedWheelAutoRollState.onRemainingChanged(fn: (number?) -> ()): RBXScriptConnection
	return remainingChanged.Event:Connect(fn)
end

-- before count, optional after count (nil = unlimited / show ∞ only).
function SeedWheelAutoRollState.onFlyRemaining(fn: (before: number, after: number?) -> ()): RBXScriptConnection
	return flyRemaining.Event:Connect(fn)
end

return SeedWheelAutoRollState
