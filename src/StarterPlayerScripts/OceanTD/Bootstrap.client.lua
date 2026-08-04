--!strict
-- Phase 1 client: mirror own plot bounds for future placement previews.

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local Remotes = require(oceanRoot:WaitForChild("Remotes"))
local ClientPlot = require(script.Parent:WaitForChild("ClientPlot"))
local InventoryState = require(script.Parent:WaitForChild("InventoryState"))

-- Scroll / pinch zoom-out: further than place default (was 1.25×; now 1.75×).
-- Pinch + mousewheel both clamp to CameraMaxZoomDistance (ZoomController listens).
local ZOOM_MULT = 1.75
local DEFAULT_GAMEPAD_STOPS = { 0, 10, 20 } -- Roblox BaseCamera defaults
local R3_ZOOM_ACTION = "OceanTD_GamepadZoom"
-- Above CameraInput's RbxCameraGamepadZoom (Default) so we own R3 snaps.
local R3_ZOOM_PRIORITY = Enum.ContextActionPriority.High.Value

do
	local base = player.CameraMaxZoomDistance
	if base <= 0 or base ~= base then
		base = 128
	end
	-- If we already applied a prior multiplier this session, don't compound forever.
	local attr = player:GetAttribute("OceanTD_ZoomBase")
	if typeof(attr) == "number" and attr > 0 then
		base = attr
	else
		player:SetAttribute("OceanTD_ZoomBase", base)
	end
	player.CameraMaxZoomDistance = base * ZOOM_MULT
end

-- R3 only cycles {0,10,20} in PlayerModule; add 2 far snaps up to scroll/pinch max.
do
	local forcingZoom = false

	local function maxZoom(): number
		return player.CameraMaxZoomDistance
	end

	local function minZoom(): number
		return player.CameraMinZoomDistance
	end

	local function snapLevels(): { number }
		local maxZ = maxZoom()
		local lastDefault = DEFAULT_GAMEPAD_STOPS[#DEFAULT_GAMEPAD_STOPS]
		local levels = table.clone(DEFAULT_GAMEPAD_STOPS)
		if maxZ > lastDefault + 1 then
			-- Two stops in the far range; last matches mousewheel / pinch max.
			table.insert(levels, lastDefault + (maxZ - lastDefault) / 2)
			table.insert(levels, maxZ)
		end
		return levels
	end

	local function currentDistance(): number
		local cam = Workspace.CurrentCamera
		if not cam then
			return DEFAULT_GAMEPAD_STOPS[2]
		end
		return (cam.CFrame.Position - cam.Focus.Position).Magnitude
	end

	-- Force subject distance without forking PlayerModule (API is sealed).
	local function forceSubjectDistance(target: number)
		if forcingZoom then
			return
		end
		local minZ = minZoom()
		local maxZ = maxZoom()
		target = math.clamp(target, minZ, maxZ)
		forcingZoom = true
		player.CameraMinZoomDistance = target
		player.CameraMaxZoomDistance = target
		RunService.Heartbeat:Wait()
		player.CameraMinZoomDistance = minZ
		player.CameraMaxZoomDistance = maxZ
		forcingZoom = false
	end

	-- Same cycle logic as BaseCamera:GamepadZoomPress, with our extended levels.
	local function cycleGamepadZoom()
		local levels = snapLevels()
		local dist = currentDistance()
		local ceiling = maxZoom()

		for i = #levels, 1, -1 do
			local zoom = levels[i]
			if ceiling < zoom then
				continue
			end
			if zoom < minZoom() then
				zoom = minZoom()
				if ceiling == zoom then
					break
				end
			end
			if dist > zoom + (ceiling - zoom) / 2 then
				forceSubjectDistance(zoom)
				return
			end
			ceiling = zoom
		end

		forceSubjectDistance(levels[#levels])
	end

	ContextActionService:BindActionAtPriority(R3_ZOOM_ACTION, function(_name, state, _input)
		if state ~= Enum.UserInputState.Begin then
			return Enum.ContextActionResult.Pass
		end
		-- Backpack uses R3 for Clear Plot — block default zoom, don't snap.
		if InventoryState.isOpen() then
			return Enum.ContextActionResult.Sink
		end
		task.spawn(cycleGamepadZoom)
		return Enum.ContextActionResult.Sink
	end, false, R3_ZOOM_PRIORITY, Enum.KeyCode.ButtonR3)
end

local plotAssigned = Remotes.get("PlotAssigned")
local plotCleared = Remotes.get("PlotCleared")
local sessionReady = Remotes.get("SessionReady")

local function log(...: any)
	print("[PLOT]", ...)
end

plotAssigned.OnClientEvent:Connect(function(payload)
	ClientPlot.set(payload)
	log("Assigned", payload.plotId, "size=", payload.size)
end)

plotCleared.OnClientEvent:Connect(function()
	ClientPlot.clear()
	log("Cleared local plot mirror")
end)

sessionReady.OnClientEvent:Connect(function()
	ClientPlot.markReady()
	log("SessionReady")
end)

log("Client bootstrap running for", player.Name)
