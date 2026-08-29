--!strict
-- Bind remotes to UrchinStingEffects (separate name so Rojo does not collide with the module).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local Remotes = require(oceanRoot:WaitForChild("Remotes"))
local UrchinStingEffects = require(script.Parent:WaitForChild("UrchinStingEffects"))

Remotes.get("UrchinSting").OnClientEvent:Connect(function(payload)
	UrchinStingEffects.applyServerPayload(payload)
end)

Remotes.get("UrchinSandOrbPicked").OnClientEvent:Connect(function(pos: any, amount: any)
	local p = if typeof(pos) == "Vector3" then pos else Vector3.zero
	local n = math.max(1, math.floor(tonumber(amount) or 1))
	UrchinStingEffects.playOrbPickup(p, n)
end)
