--!strict
--[[ Populated by SeedWheelReveal.client.lua for StopAutoRoll + other callers. ]]

export type CollapseTarget = GuiObject

local Api = {}

Api.collapseToTarget = nil :: ((target: CollapseTarget, onDone: () -> ()) -> ())?
Api.expandFromTarget = nil :: ((target: CollapseTarget, onDone: () -> ()) -> ())?
Api.abortActiveReveal = nil :: ((claimPending: boolean) -> ())?
Api.isBusy = nil :: (() -> boolean)?
-- Fires when a spin has awarded the seed and the circle has finished sliding to the backpack,
-- and another spin is not starting immediately.
Api.onCycleFinished = nil :: (() -> ())?
-- Most recent seed awarded by the wheel (tutorial finger uses this).
Api.lastAwardedItemId = nil :: string?
Api.lastAwardedColorIndex = nil :: number?

local cycleFinishedEvent = Instance.new("BindableEvent")

-- Permanent listeners (tutorial finger, etc.) — always fired after the one-shot slot.
function Api.connectCycleFinished(cb: () -> ()): RBXScriptConnection
	return cycleFinishedEvent.Event:Connect(cb)
end

function Api.fireCycleFinished()
	local done = Api.onCycleFinished
	if done then
		Api.onCycleFinished = nil
		task.defer(done)
	end
	cycleFinishedEvent:Fire()
end

return Api
