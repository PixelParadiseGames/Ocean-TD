--!strict
--[[
	Client gate so non-essential join work can wait until the Wave-100 showcase finishes.
	JoinIntro sets PlayerGui.OceanTD_JoinIntroBusy while the intro (or load bar) is active.
]]

local Players = game:GetService("Players")

local ATTR = "OceanTD_JoinIntroBusy"

local JoinIntroGate = {}

local function playerGui(): PlayerGui
	return Players.LocalPlayer:WaitForChild("PlayerGui") :: PlayerGui
end

function JoinIntroGate.isBusy(): boolean
	return playerGui():GetAttribute(ATTR) == true
end

-- Blocks until intro busy clears (or timeout). Safe if intro never ran.
function JoinIntroGate.waitUntilIdle(timeoutSec: number?)
	local pg = playerGui()
	if pg:GetAttribute(ATTR) ~= true then
		return
	end
	local deadline = os.clock() + (if typeof(timeoutSec) == "number" then math.max(0, timeoutSec) else 120)
	while pg:GetAttribute(ATTR) == true and os.clock() < deadline do
		task.wait(0.1)
	end
end

return JoinIntroGate
