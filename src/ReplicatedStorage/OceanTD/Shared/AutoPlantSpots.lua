--!strict
--[[
	Auto-plant spot helpers (shared).
	Attachment names: AutoPlant_<X>_<Z> (1-based indices from the Studio grid).
	Plot Size stage gates which X columns are in-bounds.
]]

local SkillStages = require(script.Parent:WaitForChild("SkillStages"))

local AutoPlantSpots = {}

AutoPlantSpots.PREFIX = "AutoPlant_"
AutoPlantSpots.GUIDE_FOLDER = "AutoPlantLocations"
AutoPlantSpots.GUIDE_PART = "Plot1"
-- Unlock toggle after this many successful manual places.
AutoPlantSpots.MANUAL_UNLOCK_COUNT = 3
AutoPlantSpots.SHUFFLE_COOLDOWN_SEC = 10
-- Spaced pick: sample this many empties and keep the farthest from occupied.
AutoPlantSpots.SPACE_SAMPLES = 10

export type Spot = {
	name: string,
	xIndex: number,
	zIndex: number,
	-- Plot1-local position (PointToObjectSpace of baked world on master).
	localPos: Vector3,
}

function AutoPlantSpots.maxXIndexForPlotSizeStage(stage: number): number
	local s = SkillStages.clampStageFor("PlotSize", stage)
	if s <= 3 then
		return 19
	elseif s == 4 then
		return 27
	end
	-- Stages 5–8: full authored grid.
	return math.huge
end

function AutoPlantSpots.parseAttachmentName(name: string): (number?, number?)
	if typeof(name) ~= "string" then
		return nil, nil
	end
	local xs, zs = string.match(name, "^AutoPlant_(%d+)_(%d+)$")
	if not xs then
		return nil, nil
	end
	return tonumber(xs), tonumber(zs)
end

function AutoPlantSpots.isXInStage(xIndex: number, plotSizeStage: number): boolean
	local maxX = AutoPlantSpots.maxXIndexForPlotSizeStage(plotSizeStage)
	if maxX == math.huge then
		return xIndex >= 1
	end
	return xIndex >= 1 and xIndex <= maxX
end

-- Pick among candidates the spot maximizing distance to the nearest occupied world point.
function AutoPlantSpots.pickSpacedWorld(
	candidates: { Vector3 },
	occupied: { Vector3 },
	rng: Random?
): Vector3?
	if #candidates == 0 then
		return nil
	end
	local r = rng or Random.new()
	local samples = math.min(AutoPlantSpots.SPACE_SAMPLES, #candidates)
	local best: Vector3? = nil
	local bestMinDist = -1
	for _ = 1, samples do
		local idx = r:NextInteger(1, #candidates)
		local p = candidates[idx]
		local minDist = math.huge
		for _, o in ipairs(occupied) do
			local d = (Vector3.new(p.X, 0, p.Z) - Vector3.new(o.X, 0, o.Z)).Magnitude
			if d < minDist then
				minDist = d
			end
		end
		if #occupied == 0 then
			minDist = 1e9
		end
		if minDist > bestMinDist then
			bestMinDist = minDist
			best = p
		end
	end
	return best or candidates[r:NextInteger(1, #candidates)]
end

return AutoPlantSpots
