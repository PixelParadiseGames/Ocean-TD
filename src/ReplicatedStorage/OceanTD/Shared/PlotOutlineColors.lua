--!strict
--[[
	Plot outline palette (indices 1–15).
	15 = NO_STROKE (hide edges via Transparency = 1).
]]

local PlotOutlineColors = {}

PlotOutlineColors.NO_STROKE = 15
PlotOutlineColors.DEFAULT_INDEX = 2 -- teal
PlotOutlineColors.MIN_INDEX = 1
PlotOutlineColors.MAX_INDEX = 15

export type Swatch = {
	index: number,
	name: string,
	color: Color3?, -- nil for no-stroke
	noStroke: boolean,
}

local SWATCHES: { Swatch } = {
	{ index = 1, name = "pink", color = Color3.fromHex("ff409f"), noStroke = false },
	{ index = 2, name = "teal", color = Color3.fromHex("03fcec"), noStroke = false },
	{ index = 3, name = "blue", color = Color3.fromHex("033dfc"), noStroke = false },
	{ index = 4, name = "navy", color = Color3.fromHex("002f8c"), noStroke = false },
	{ index = 5, name = "purple", color = Color3.fromHex("9650dc"), noStroke = false },
	{ index = 6, name = "red", color = Color3.fromHex("dc3737"), noStroke = false },
	{ index = 7, name = "pumpkin", color = Color3.fromHex("ff5900"), noStroke = false },
	{ index = 8, name = "orange", color = Color3.fromHex("ff9100"), noStroke = false },
	{ index = 9, name = "yellow", color = Color3.fromHex("ffd737"), noStroke = false },
	{ index = 10, name = "toxic green", color = Color3.fromHex("94fc03"), noStroke = false },
	{ index = 11, name = "green", color = Color3.fromHex("37c34b"), noStroke = false },
	{ index = 12, name = "grey", color = Color3.fromHex("828282"), noStroke = false },
	{ index = 13, name = "black", color = Color3.fromHex("000000"), noStroke = false },
	{ index = 14, name = "white", color = Color3.fromHex("ffffff"), noStroke = false },
	{ index = 15, name = "no stroke", color = nil, noStroke = true },
}

function PlotOutlineColors.clampIndex(n: any): number
	local v = math.floor(tonumber(n) or PlotOutlineColors.DEFAULT_INDEX)
	return math.clamp(v, PlotOutlineColors.MIN_INDEX, PlotOutlineColors.MAX_INDEX)
end

function PlotOutlineColors.get(index: number): Swatch
	local i = PlotOutlineColors.clampIndex(index)
	return SWATCHES[i]
end

function PlotOutlineColors.all(): { Swatch }
	return SWATCHES
end

function PlotOutlineColors.isNoStroke(index: number): boolean
	return PlotOutlineColors.clampIndex(index) == PlotOutlineColors.NO_STROKE
end

-- Coral paint uses solid swatches only (excludes no-stroke).
PlotOutlineColors.CORAL_MAX_INDEX = 14

function PlotOutlineColors.clampCoralIndex(n: any): number
	local v = math.floor(tonumber(n) or PlotOutlineColors.DEFAULT_INDEX)
	return math.clamp(v, PlotOutlineColors.MIN_INDEX, PlotOutlineColors.CORAL_MAX_INDEX)
end

function PlotOutlineColors.coralSwatches(): { Swatch }
	local out: { Swatch } = {}
	for i = PlotOutlineColors.MIN_INDEX, PlotOutlineColors.CORAL_MAX_INDEX do
		table.insert(out, SWATCHES[i])
	end
	return out
end

function PlotOutlineColors.coralColor(index: number): Color3
	local sw = PlotOutlineColors.get(PlotOutlineColors.clampCoralIndex(index))
	return sw.color or Color3.new(1, 1, 1)
end

-- Clamp optional 0–1 channel; nil if invalid.
function PlotOutlineColors.sanitizeChannel(raw: any): number?
	local n = tonumber(raw)
	if typeof(n) ~= "number" or n ~= n then
		return nil
	end
	return math.clamp(n, 0, 1)
end

-- Prefer saved RGB when present; otherwise palette base for the index.
function PlotOutlineColors.resolveCoralPaint(index: number, r: any, g: any, b: any): Color3
	local cr = PlotOutlineColors.sanitizeChannel(r)
	local cg = PlotOutlineColors.sanitizeChannel(g)
	local cb = PlotOutlineColors.sanitizeChannel(b)
	if cr and cg and cb then
		return Color3.new(cr, cg, cb)
	end
	return PlotOutlineColors.coralColor(index)
end

--[[
	Same hue family as the swatch, random saturation + brightness.
	Grey / black / white: vary value (and a little sat) instead of hue.
]]
function PlotOutlineColors.randomHueVariant(index: number): Color3
	local idx = PlotOutlineColors.clampCoralIndex(index)
	local base = PlotOutlineColors.coralColor(idx)
	local h, s, v = base:ToHSV()

	if idx == 13 then
		-- Black family: near-black → dark charcoal.
		return Color3.fromHSV(h, math.clamp(s + math.random() * 0.2, 0, 0.35), 0.02 + math.random() * 0.28)
	end
	if idx == 14 then
		-- White family: bright near-white with optional soft tint of neighboring hues.
		local tintH = if math.random() < 0.55 then h else math.random()
		return Color3.fromHSV(tintH, math.random() * 0.12, 0.82 + math.random() * 0.18)
	end
	if idx == 12 then
		-- Grey family: low sat, wide brightness.
		return Color3.fromHSV(h, math.random() * 0.08, 0.18 + math.random() * 0.72)
	end

	-- Chromatic: lock hue, scatter sat + value widely for hundreds of shades.
	local newS = math.clamp(s * (0.25 + math.random() * 1.1) + (math.random() - 0.5) * 0.35, 0.12, 1)
	local newV = math.clamp(v * (0.35 + math.random() * 0.9) + (math.random() - 0.5) * 0.25, 0.16, 1)
	return Color3.fromHSV(h, newS, newV)
end

--[[
	Bright saturated accent for dual-part corals (Zoas). Any hue; always vivid.
]]
function PlotOutlineColors.randomBrightAccent(): Color3
	local h = math.random()
	local s = 0.62 + math.random() * 0.38
	local v = 0.72 + math.random() * 0.28
	return Color3.fromHSV(h, s, v)
end

-- Tint Neon edge parts in a folder. Index 15 → Transparency 1 (hidden).
function PlotOutlineColors.applyToFolder(folder: Instance, index: number, visibleTransparency: number?)
	local sw = PlotOutlineColors.get(index)
	local shown = if visibleTransparency ~= nil then visibleTransparency else 0
	local hide = sw.noStroke
	local color = sw.color or Color3.new(1, 1, 1)
	for _, d in ipairs(folder:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Color = color
			d.Transparency = if hide then 1 else shown
		end
	end
end

return PlotOutlineColors
