--!strict
--[[
	During a live wave: click/tap near a critter to lob a free food orb
	from screen-center-bottom → fish (+1 hunger, 1s cooldown).
	TAP_FEED_DEBUG draws a translucent ball = clickable world radius.

	Hit test uses screen-space (WorldToViewportPoint vs GetMouseLocation) so it
	lines up with the debug ball — same inset rules as place/relocate picks,
	without changing placement hit testing.
]]

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local WaveSim = require(script.Parent:WaitForChild("WaveSim"))
local WaveSimConsts = require(script.Parent:WaitForChild("WaveSimConsts"))
local InventoryState = require(script.Parent:WaitForChild("InventoryState"))
local PlacementController = require(script.Parent:WaitForChild("PlacementController"))
local RelocateController = require(script.Parent:WaitForChild("RelocateController"))
local PlaceConfirmHitTest = require(script.Parent:WaitForChild("PlaceConfirmHitTest"))

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui") :: PlayerGui

local function screenBlocked(screenPos: Vector2): boolean
	local inset = GuiService:GetGuiInset()
	local guiPos = screenPos - Vector2.new(inset.X, inset.Y)
	local ok, hits = pcall(function()
		return playerGui:GetGuiObjectsAtPosition(guiPos.X, guiPos.Y)
	end)
	if not ok or typeof(hits) ~= "table" then
		return false
	end
	for _, gui in ipairs(hits) do
		-- Only real buttons/text boxes swallow the tap (frames/labels stay pass-through).
		if gui:IsA("GuiButton") or gui:IsA("TextBox") then
			if gui.Visible and gui.Active then
				return true
			end
		end
	end
	return false
end

local function tryFeedAtScreen(screenPos: Vector2): boolean
	if not WaveSim.isRunning() then
		return false
	end
	if InventoryState.isOpen() or PlacementController.isActive() or RelocateController.isActive() then
		return false
	end
	if screenBlocked(screenPos) then
		return false
	end
	return WaveSim.tryTapFeedAtScreen(screenPos)
end

local function onInput(input: InputObject, gameProcessed: boolean)
	if gameProcessed then
		return
	end
	if input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch
	then
		-- Same pointer space as place/relocate (touch +inset → GetMouseLocation space).
		local screenPos = PlaceConfirmHitTest.pointerScreenPos(input)
		tryFeedAtScreen(screenPos)
	end
end

UserInputService.InputBegan:Connect(onInput)

-- Debug radii are attached by WaveSim when TAP_FEED_DEBUG is true.
if WaveSimConsts.TAP_FEED_DEBUG then
	print("[WaveTapFeed] debug radii ON — cyan ForceField balls = tap radius (", WaveSimConsts.TAP_FEED_RADIUS, "studs)")
end
