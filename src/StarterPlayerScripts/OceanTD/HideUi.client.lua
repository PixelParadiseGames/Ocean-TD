--!strict
--[[ Binds MobileLeftUI.dPad.HideUI — see HideUiController. ]]

local HideUiController = require(script.Parent:WaitForChild("HideUiController"))
local HideUiState = require(script.Parent:WaitForChild("HideUiState"))

HideUiController.init()

print("[HideUI] Ready — unlocked=", HideUiState.isUnlocked())
