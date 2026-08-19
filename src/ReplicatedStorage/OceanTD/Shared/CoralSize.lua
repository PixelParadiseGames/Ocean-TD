--!strict
-- Brain Coral size bands (studs) and per-coral unlock tier (1=S, 2=M, 3=L).

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
	local d = CoralSize.sanitizeDiameter(diameter, class)
	local c = CoralSize.clampTier(class)
	local t = math.max(CoralSize.clampTier(tier), c)
	part.Size = Vector3.new(d, d, d)
	part:SetAttribute("OceanTD_Diameter", d)
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

CoralSize.STATS = {
	[1] = { range = 30, reload = 6, food = 1, defense = 2 },
	[2] = { range = 60, reload = 4, food = 2, defense = 3 },
	[3] = { range = 80, reload = 2, food = 3, defense = 4 },
}

function CoralSize.statsFor(class: number): SizeStats
	return CoralSize.STATS[CoralSize.clampTier(class)]
end

function CoralSize.ammoSizeScale(foodCount: number): number
	if foodCount >= 2 then
		return 0.8
	end
	return 1
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
