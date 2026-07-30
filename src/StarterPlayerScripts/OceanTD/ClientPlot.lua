--!strict
-- Client mirror of the local player's plot bounds. Phase 1 read-only.

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

return ClientPlot
