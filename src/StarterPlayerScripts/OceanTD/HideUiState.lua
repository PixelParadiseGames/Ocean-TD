--!strict
--[[ Client mirror of profile.hideUiUnlocked + active hide toggle. ]]

local Players = game:GetService("Players")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local Constants = require(oceanRoot:WaitForChild("Shared"):WaitForChild("Constants"))
local Remotes = require(oceanRoot:WaitForChild("Remotes"))

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local HideUiState = {}

local unlocked = false
local active = false
local changed: BindableEvent = Instance.new("BindableEvent")

local function syncAttributes()
	player:SetAttribute(Constants.HIDE_UI_UNLOCKED_ATTR, unlocked)
	playerGui:SetAttribute(Constants.HIDE_UI_ACTIVE_ATTR, active)
end

function HideUiState.isUnlocked(): boolean
	return unlocked
end

function HideUiState.isActive(): boolean
	return active
end

function HideUiState.setUnlocked(value: boolean)
	local next = value == true
	if unlocked == next then
		return
	end
	unlocked = next
	syncAttributes()
	changed:Fire()
end

function HideUiState.setActive(value: boolean)
	local next = value == true
	if active == next then
		return
	end
	active = next
	syncAttributes()
	changed:Fire()
end

function HideUiState.onChanged(fn: () -> ()): RBXScriptConnection
	return changed.Event:Connect(fn)
end

Remotes.get("HideUiSync").OnClientEvent:Connect(function(payload: any)
	HideUiState.setUnlocked(payload == true)
end)

local attr = player:GetAttribute(Constants.HIDE_UI_UNLOCKED_ATTR)
if attr == true then
	unlocked = true
end
syncAttributes()

return HideUiState
