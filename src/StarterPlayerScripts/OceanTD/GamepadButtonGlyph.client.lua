--!strict
--[[
	Swaps joypad letter badges for the PlayStation or Xbox button sheet.
	Keyboard letters stay text. See GamepadButtonGlyph.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local GamepadButtonGlyph = require(oceanRoot:WaitForChild("Shared"):WaitForChild("GamepadButtonGlyph"))

local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

local KEEP_BG_BUTTONS = {
	Close = true,
	RecycleCancel = true,
	ZoomOut = true,
	ZoomIn = true,
	DistOffMinus = true,
	DistOffPlus = true,
}

local function consider(inst: Instance)
	if inst:IsA("TextButton") then
		if KEEP_BG_BUTTONS[inst.Name] then
			GamepadButtonGlyph.watch(inst, true)
		end
		return
	end
	if not inst:IsA("TextLabel") then
		return
	end
	local name = inst.Name
	local parent = inst.Parent
	local tip = name == "_OceanTD_HelpLetter"
		or name == "_OceanTD_CloseX"
		or name == "_OceanTD_HueFocusA"
		or name == "_OceanTD_AutoPlantX"
		or name == "_OceanTD_RefundX"
		or name == "ATip"
		or name == "L1"
		or name == "Glyph"
		or string.find(name, "Glyph", 1, true) ~= nil
		or name == "FinishHint"
		or (parent ~= nil and parent.Name == "R1Badge")
	if tip then
		GamepadButtonGlyph.watch(inst, false)
	end
end

for _, desc in ipairs(playerGui:GetDescendants()) do
	consider(desc)
end
playerGui.DescendantAdded:Connect(consider)
