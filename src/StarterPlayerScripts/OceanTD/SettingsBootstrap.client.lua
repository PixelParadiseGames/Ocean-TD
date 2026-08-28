--!strict
-- Boots audio settings UI + background music on join.

local BgmController = require(script.Parent:WaitForChild("BgmController"))
local SettingsUI = require(script.Parent:WaitForChild("SettingsUI"))

SettingsUI.init()
BgmController.start()
