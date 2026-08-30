--!strict
--[[ Populated by SeedWheelReveal.client.lua for StopAutoRoll + other callers. ]]

export type CollapseTarget = GuiObject

local Api = {}

Api.collapseToTarget = nil :: ((target: CollapseTarget, onDone: () -> ()) -> ())?
Api.expandFromTarget = nil :: ((target: CollapseTarget, onDone: () -> ()) -> ())?
Api.abortActiveReveal = nil :: ((claimPending: boolean) -> ())?
Api.isBusy = nil :: (() -> boolean)?

return Api
