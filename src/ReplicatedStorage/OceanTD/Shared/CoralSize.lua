--!strict
-- Coral size bands (studs) and per-coral unlock tier (1=S, 2=M, 3=L).
-- Combat stats are per-species; BrainCoral keeps the original table.

local CoralSize = {}

CoralSize.SMALL = 1
CoralSize.MEDIUM = 2
CoralSize.LARGE = 3

CoralSize.RANGES = {
	[1] = { min = 1.5, max = 4 },
	[2] = { min = 4, max = 6 },
	[3] = { min = 6, max = 9 },
}

function CoralSize.clampTier(raw: any): number
	local n = math.floor(tonumber(raw) or 1)
	return math.clamp(n, 1, 3)
end

function CoralSize.classFromDiameter(d: number): number
	if d <= 4 then
		return 1
	end
	if d <= 6 then
		return 2
	end
	return 3
end

function CoralSize.randomDiameter(tier: number): number
	local t = CoralSize.clampTier(tier)
	local r = CoralSize.RANGES[t]
	return r.min + math.random() * (r.max - r.min)
end

function CoralSize.sanitizeDiameter(raw: any, tier: number?): number
	local t = CoralSize.clampTier(tier or 1)
	local n = tonumber(raw)
	if typeof(n) ~= "number" or n ~= n then
		return CoralSize.randomDiameter(t)
	end
	return math.clamp(n, CoralSize.RANGES[1].min, CoralSize.RANGES[3].max)
end

function CoralSize.readFromPart(part: BasePart): (number, number, number)
	local dAttr = part:GetAttribute("OceanTD_Diameter")
	local d = if typeof(dAttr) == "number" then dAttr else math.max(part.Size.X, part.Size.Y, part.Size.Z)
	local classAttr = part:GetAttribute("OceanTD_SizeClass")
	local class = if typeof(classAttr) == "number" then CoralSize.clampTier(classAttr) else CoralSize.classFromDiameter(d)
	local tierAttr = part:GetAttribute("OceanTD_SizeTier")
	local tier = if typeof(tierAttr) == "number" then CoralSize.clampTier(tierAttr) else class
	if class > tier then
		tier = class
	end
	return d, class, tier
end

function CoralSize.applyToPart(part: BasePart, diameter: number, class: number, tier: number)
	local c = CoralSize.clampTier(class)
	local t = math.max(CoralSize.clampTier(tier), c)
	local speciesId = part:GetAttribute("OceanTD_SpeciesId")
	-- Mesh species keep authored Size; diameter is a persisted height/scale cue only.
	if speciesId ~= "Sponge" then
		local d = CoralSize.sanitizeDiameter(diameter, class)
		part.Size = Vector3.new(d, d, d)
		part:SetAttribute("OceanTD_Diameter", d)
	else
		local d = tonumber(diameter)
		if typeof(d) == "number" and d == d and d > 0 then
			part:SetAttribute("OceanTD_Diameter", d)
		else
			part:SetAttribute("OceanTD_Diameter", part.Size.Y)
		end
	end
	part:SetAttribute("OceanTD_SizeClass", c)
	part:SetAttribute("OceanTD_SizeTier", t)
end

function CoralSize.nextUnlock(tier: number): number?
	local t = CoralSize.clampTier(tier)
	if t >= 3 then
		return nil
	end
	return t + 1
end

function CoralSize.labelFor(tier: number): string
	if tier == 2 then
		return "Medium"
	end
	if tier == 3 then
		return "Large"
	end
	return "Small"
end

export type SizeStats = {
	range: number,
	reload: number,
	food: number,
	defense: number,
}

-- Default / BrainCoral
CoralSize.STATS = {
	[1] = { range = 30, reload = 6, food = 1, defense = 2 },
	[2] = { range = 60, reload = 4, food = 2, defense = 3 },
	[3] = { range = 80, reload = 2, food = 3, defense = 4 },
}

CoralSize.STATS_BY_SPECIES = {
	BrainCoral = CoralSize.STATS,
	Sponge = {
		[1] = { range = 40, reload = 6, food = 1, defense = 1 },
		[2] = { range = 70, reload = 4, food = 2, defense = 2 },
		[3] = { range = 90, reload = 2, food = 3, defense = 3 },
	},
}

function CoralSize.statsFor(class: number, speciesId: string?): SizeStats
	local tableFor = CoralSize.STATS
	if typeof(speciesId) == "string" and CoralSize.STATS_BY_SPECIES[speciesId] then
		tableFor = CoralSize.STATS_BY_SPECIES[speciesId]
	end
	return tableFor[CoralSize.clampTier(class)]
end

function CoralSize.ammoSizeScale(foodCount: number): number
	if foodCount >= 2 then
		return 0.8
	end
	return 1
end

-- Radius used for ammo Y offset from part.Position.
-- Ball corals: half diameter from center. Sponge meshes: half height (pivot at AABB center).
function CoralSize.ammoAnchorRadius(part: BasePart): number
	local speciesId = part:GetAttribute("OceanTD_SpeciesId")
	if speciesId == "Sponge" then
		return math.max(part.Size.Y * 0.5, 0.5)
	end
	return math.max(part.Size.X, part.Size.Y, part.Size.Z) * 0.5
end

-- Visual center for range rings / FX (not always part.Position).
function CoralSize.visualCenter(part: BasePart): Vector3
	return part.Position
end

-- Local offsets from coral center (Y up). 2 = side by side; 3 = triangle, same height.
function CoralSize.ammoLocalOffsets(foodCount: number, coralRadius: number, ammoRadius: number): { Vector3 }
	local y = coralRadius + ammoRadius
	local n = math.clamp(math.floor(foodCount), 1, 3)
	if n <= 1 then
		return { Vector3.new(0, y, 0) }
	end
	if n == 2 then
		local s = ammoRadius * 1.2
		return {
			Vector3.new(-s, y, 0),
			Vector3.new(s, y, 0),
		}
	end
	local s = ammoRadius * 2.05
	return {
		Vector3.new(0, y, s),
		Vector3.new(-s * 0.866, y, -s * 0.5),
		Vector3.new(s * 0.866, y, -s * 0.5),
	}
end

return CoralSize
