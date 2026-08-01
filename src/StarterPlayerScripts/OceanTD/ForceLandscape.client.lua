--!strict
-- Force landscape (widescreen). Portrait / vertical mobile is not supported.

local Players = game:GetService("Players")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local function apply()
	-- Landscape only; may flip left/right with device rotation.
	playerGui.ScreenOrientation = Enum.ScreenOrientation.LandscapeSensor
end

apply()
playerGui:GetPropertyChangedSignal("ScreenOrientation"):Connect(function()
	if playerGui.ScreenOrientation ~= Enum.ScreenOrientation.LandscapeSensor
		and playerGui.ScreenOrientation ~= Enum.ScreenOrientation.LandscapeLeft
		and playerGui.ScreenOrientation ~= Enum.ScreenOrientation.LandscapeRight
	then
		apply()
	end
end)

print("[UI] ScreenOrientation locked to landscape")
