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
