--!strict
--[[
	TEMP debug: red dot above any coral tagged OceanTD_DebugHueDefaulted
	(missing/invalid color index collapsed to teal default).

	On by default. Turn off: player:SetAttribute("OceanTD_HueDefaultDebug", false)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
local oceanShared = ReplicatedStorage:WaitForChild("OceanTD"):WaitForChild("Shared")
local PlotOutlineColors = require(oceanShared:WaitForChild("PlotOutlineColors"))
local HueDefaultDebug = require(script.Parent:WaitForChild("HueDefaultDebug"))

local ATTR = PlotOutlineColors.ATTR_DEBUG_HUE_DEFAULTED
local TOGGLE_ATTR = "OceanTD_HueDefaultDebug"
player:SetAttribute(TOGGLE_ATTR, false)

local function enabled(): boolean
	return player:GetAttribute(TOGGLE_ATTR) == true
end

local function consider(inst: Instance)
	if not inst:IsA("BasePart") then
		return
	end
	if inst:GetAttribute(ATTR) == true then
		HueDefaultDebug.attachDot(inst)
	else
		HueDefaultDebug.destroyDot(inst)
	end
end

local function scanAll()
	for _, inst in ipairs(Workspace:GetDescendants()) do
		consider(inst)
	end
end

Workspace.DescendantAdded:Connect(function(inst)
	if not enabled() then
		return
	end
	consider(inst)
	if inst:IsA("BasePart") then
		inst:GetAttributeChangedSignal(ATTR):Connect(function()
			if enabled() then
				consider(inst)
			end
		end)
	end
end)

Workspace.DescendantRemoving:Connect(function(inst)
	if inst:IsA("BasePart") then
		HueDefaultDebug.destroyDot(inst)
	end
end)

player:GetAttributeChangedSignal(TOGGLE_ATTR):Connect(function()
	local on = enabled()
	HueDefaultDebug.setActive(on)
	if on then
		scanAll()
	end
end)

HueDefaultDebug.setActive(enabled())
task.defer(function()
	if enabled() then
		scanAll()
	end
end)

-- Debug off (no red neon markers).
