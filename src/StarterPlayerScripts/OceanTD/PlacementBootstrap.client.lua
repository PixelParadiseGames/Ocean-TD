--!strict
-- Boots placement + relocate controllers after join intro finishes (showcase is frozen anyway).

local JoinIntroGate = require(script.Parent:WaitForChild("JoinIntroGate"))

JoinIntroGate.waitUntilIdle(120)

require(script.Parent:WaitForChild("PlacementController"))
require(script.Parent:WaitForChild("RelocateController"))
require(script.Parent:WaitForChild("CoralTrampoline"))
