--!strict
-- Client mirror of the local player's plot bounds.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local GridMath = require(ReplicatedStorage:WaitForChild("OceanTD"):WaitForChild("Shared"):WaitForChild("GridMath"))

export type MirroredPlot = {
	plotId: string,
	cframe: CFrame,
	size: Vector3,
	spawnCFrame: CFrame?,
}

local ClientPlot = {}

local mirrored: MirroredPlot? = nil
local ready = false

function ClientPlot.set(payload: MirroredPlot)
	mirrored = payload
end

function ClientPlot.clear()
	mirrored = nil
	ready = false
end

function ClientPlot.markReady()
	ready = true
end

function ClientPlot.get(): MirroredPlot?
	return mirrored
end

function ClientPlot.isReady(): boolean
	return ready
end

function ClientPlot.isInside(worldPos: Vector3): boolean
	if not mirrored then
		return false
	end
	return GridMath.isInsidePlotXZ(worldPos, mirrored.cframe, mirrored.size)
end

return ClientPlot
