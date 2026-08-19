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

return CoralSize
