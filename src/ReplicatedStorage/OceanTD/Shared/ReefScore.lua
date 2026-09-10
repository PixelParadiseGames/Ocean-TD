--!strict
--[[
	Reef Report score (N):
	  abundance = 1 point per currently placed coral (cap 1000)
	  + species mix bonus (even spread across all backpack species)
	  + per-species hue mix bonus (even across all paint hues + unpainted bucket)
	  + per-species size mix bonus (ideal ~1/3 S / M / L)

	Only corals currently on the plot count (recycle/remove drops them).
]]

local ItemCatalog = require(script.Parent:WaitForChild("ItemCatalog"))
local PlotOutlineColors = require(script.Parent:WaitForChild("PlotOutlineColors"))
local CoralSize = require(script.Parent:WaitForChild("CoralSize"))
local SkillStages = require(script.Parent:WaitForChild("SkillStages"))

local ReefScore = {}

ReefScore.ABUNDANCE_CAP = SkillStages.PLACE_MORE_MAX_STAGE -- 1000
-- Equal-ish bonus pillars on top of abundance (Option A style).
ReefScore.SPECIES_BONUS_MAX = 250
ReefScore.HUE_BONUS_PER_SPECIES = 40
ReefScore.SIZE_BONUS_PER_SPECIES = 40

local PAINT_HUE_COUNT = PlotOutlineColors.CORAL_MAX_INDEX -- 14
-- Bucket PAINT_HUE_COUNT+1 = unpainted / default (no OceanTD_ColorIndex).
local HUE_BUCKETS = PAINT_HUE_COUNT + 1
local UNPAINTED_BUCKET = HUE_BUCKETS

local COLOR_RED = Color3.fromRGB(220, 55, 55)
local COLOR_ORANGE = Color3.fromRGB(240, 140, 40)
local COLOR_LIME = Color3.fromRGB(170, 230, 55) -- was yellow; between orange and green
local COLOR_GREEN = Color3.fromRGB(55, 200, 90)

export type Breakdown = {
	total: number,
	abundance: number,
	speciesBonus: number,
	hueBonus: number,
	sizeBonus: number,
	placed: number,
	maxTotal: number,
	quality: number, -- 0–1 vs maxTotal
}

local function catalogDefs(): { ItemCatalog.ItemDef }
	return ItemCatalog.all()
end

local function distributionBalance(counts: { number }, nBuckets: number): number
	if nBuckets <= 1 then
		return 1
	end
	local total = 0
	for i = 1, nBuckets do
		total += counts[i] or 0
	end
	if total <= 0 then
		return 0
	end
	local ideal = 1 / nBuckets
	local mad = 0
	for i = 1, nBuckets do
		mad += math.abs(((counts[i] or 0) / total) - ideal)
	end
	-- Perfect → 0; all mass in one bucket → 2*(1-ideal)
	local maxMad = 2 * (1 - ideal)
	if maxMad <= 0 then
		return 1
	end
	return math.clamp(1 - mad / maxMad, 0, 1)
end

-- 0 = at edges (0% or 100%), 1 = exactly at ideal share (e.g. 1/3).
-- Tight Gaussian so ~half-share / near-full bars are not green.
function ReefScore.shareBalanceQuality(share: number, ideal: number): number
	local s = math.clamp(share, 0, 1)
	local target = math.clamp(ideal, 0, 1)
	local dist = math.abs(s - target)
	local sigma = 0.09
	return math.exp(-(dist / sigma) * (dist / sigma))
end

-- Red (edges) → orange → lime → green (at ideal / middle).
-- Used for the title N score quality meter.
function ReefScore.meterColor(quality: number): Color3
	local q = math.clamp(quality, 0, 1)
	if q <= 0.35 then
		local u = q / 0.35
		return COLOR_RED:Lerp(COLOR_ORANGE, u)
	elseif q <= 0.65 then
		local u = (q - 0.35) / 0.30
		return COLOR_ORANGE:Lerp(COLOR_LIME, u)
	else
		local u = (q - 0.65) / 0.35
		return COLOR_LIME:Lerp(COLOR_GREEN, u)
	end
end

--[[
	S/M/L bar color from fill height (ideal 1/3 share = half-full = 0.5):
	  middle 25%           → green   [0.375, 0.625]
	  next 12.5% each side → lime    [0.25, 0.375) / (0.625, 0.75]
	  next 12.5% each side → orange  [0.125, 0.25) / (0.75, 0.875]
	  tip 12.5% each side  → red     [0, 0.125) / (0.875, 1]
]]
function ReefScore.sizeBarColorFromFill(fillFrac: number): Color3
	local f = math.clamp(fillFrac, 0, 1)
	if f >= 0.375 and f <= 0.625 then
		return COLOR_GREEN
	elseif (f >= 0.25 and f < 0.375) or (f > 0.625 and f <= 0.75) then
		return COLOR_LIME
	elseif (f >= 0.125 and f < 0.25) or (f > 0.75 and f <= 0.875) then
		return COLOR_ORANGE
	end
	return COLOR_RED
end

function ReefScore.sizeBarColor(count: number, total: number): Color3
	if total <= 0 then
		return COLOR_RED
	end
	local fill = ReefScore.sizeBarFillFrac(count, total, 0)
	return ReefScore.sizeBarColorFromFill(fill)
end

-- Map share so ideal 1/3 reads as half-full; empty→0, monopoly→full.
function ReefScore.sizeBarFillFrac(count: number, total: number, minFrac: number): number
	local minF = math.clamp(minFrac, 0, 0.2)
	if total <= 0 then
		return minF
	end
	local share = math.clamp(count / total, 0, 1)
	local ideal = 1 / 3
	local frac: number
	if share <= ideal then
		frac = (share / ideal) * 0.5
	else
		frac = 0.5 + ((share - ideal) / (1 - ideal)) * 0.5
	end
	if count > 0 then
		frac = math.max(frac, minF)
	else
		frac = minF
	end
	return math.clamp(frac, 0, 1)
end

local function hueBucketOfPart(part: BasePart): number
	local painted = part:GetAttribute("OceanTD_ColorIndex")
	if typeof(painted) == "number" then
		return PlotOutlineColors.clampCoralIndex(painted)
	end
	return UNPAINTED_BUCKET
end

function ReefScore.maxTotal(): number
	local nSpecies = #catalogDefs()
	return ReefScore.ABUNDANCE_CAP
		+ ReefScore.SPECIES_BONUS_MAX
		+ ReefScore.HUE_BONUS_PER_SPECIES * nSpecies
		+ ReefScore.SIZE_BONUS_PER_SPECIES * nSpecies
end

function ReefScore.compute(plotId: string?, parts: { BasePart }): Breakdown
	local defs = catalogDefs()
	local nSpecies = #defs
	local maxTotal = ReefScore.maxTotal()

	local empty: Breakdown = {
		total = 0,
		abundance = 0,
		speciesBonus = 0,
		hueBonus = 0,
		sizeBonus = 0,
		placed = 0,
		maxTotal = maxTotal,
		quality = 0,
	}
	if typeof(plotId) ~= "string" or plotId == "" or nSpecies == 0 then
		return empty
	end

	local speciesIndex: { [string]: number } = {}
	local speciesCounts: { number } = table.create(nSpecies)
	local hueCountsBySpecies: { { number } } = table.create(nSpecies)
	local sizeCountsBySpecies: { { number } } = table.create(nSpecies)
	for i, def in ipairs(defs) do
		speciesIndex[def.id] = i
		speciesCounts[i] = 0
		local hues = table.create(HUE_BUCKETS)
		for h = 1, HUE_BUCKETS do
			hues[h] = 0
		end
		hueCountsBySpecies[i] = hues
		sizeCountsBySpecies[i] = { [1] = 0, [2] = 0, [3] = 0 }
	end

	local placed = 0
	for _, part in ipairs(parts) do
		if not part.Parent then
			continue
		end
		local itemId = part:GetAttribute("OceanTD_ItemId")
		if typeof(itemId) ~= "string" then
			continue
		end
		local si = speciesIndex[itemId]
		if not si then
			continue
		end
		placed += 1
		speciesCounts[si] += 1
		local hb = hueBucketOfPart(part)
		hueCountsBySpecies[si][hb] += 1
		local _, class = CoralSize.readFromPart(part)
		local c = CoralSize.clampTier(class)
		sizeCountsBySpecies[si][c] += 1
	end

	local abundance = math.min(placed, ReefScore.ABUNDANCE_CAP)
	local speciesBonus = 0
	local hueBonus = 0
	local sizeBonus = 0
	if placed > 0 then
		speciesBonus = ReefScore.SPECIES_BONUS_MAX * distributionBalance(speciesCounts, nSpecies)
		for i = 1, nSpecies do
			if speciesCounts[i] <= 0 then
				continue
			end
			hueBonus += ReefScore.HUE_BONUS_PER_SPECIES * distributionBalance(hueCountsBySpecies[i], HUE_BUCKETS)
			sizeBonus += ReefScore.SIZE_BONUS_PER_SPECIES * distributionBalance(sizeCountsBySpecies[i], 3)
		end
	end

	-- Round to whole points for the title N.
	abundance = math.floor(abundance + 0.5)
	speciesBonus = math.floor(speciesBonus + 0.5)
	hueBonus = math.floor(hueBonus + 0.5)
	sizeBonus = math.floor(sizeBonus + 0.5)
	local total = abundance + speciesBonus + hueBonus + sizeBonus
	local quality = if maxTotal > 0 then math.clamp(total / maxTotal, 0, 1) else 0

	return {
		total = total,
		abundance = abundance,
		speciesBonus = speciesBonus,
		hueBonus = hueBonus,
		sizeBonus = sizeBonus,
		placed = placed,
		maxTotal = maxTotal,
		quality = quality,
	}
end

return ReefScore
