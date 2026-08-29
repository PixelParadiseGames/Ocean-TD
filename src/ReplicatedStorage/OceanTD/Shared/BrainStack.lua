--!strict
--[[
	Brain coral stacking: place on top of another Brain with a slight sink/overlap.
	Grid cells stay unique (gy bumped); visual Y nests into the coral below.
]]

local BrainStack = {}

BrainStack.SPECIES_ID = "BrainCoral"
BrainStack.ITEM_ID = "BrainCoral"

function BrainStack.isBrainId(id: any): boolean
	return id == BrainStack.SPECIES_ID or id == BrainStack.ITEM_ID
end

function BrainStack.diameterOfPart(part: BasePart): number
	return math.max(part.Size.X, part.Size.Y, part.Size.Z)
end

-- How far the new ball center sinks into the lower ball (overlap).
function BrainStack.sinkAmount(belowDiam: number, newDiam: number): number
	return math.clamp(math.min(belowDiam, newDiam) * 0.22, 0.4, 0.9)
end

function BrainStack.stackCenterY(belowY: number, belowDiam: number, newDiam: number): number
	return belowY + (belowDiam + newDiam) * 0.5 - BrainStack.sinkAmount(belowDiam, newDiam)
end

return BrainStack
