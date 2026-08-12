--!strict
--[[
	Skill stage catalog (UI + persist). Gameplay effects come later.
	Stages 1..8; all skills start at 1 unlocked.
]]

local SkillStages = {}

SkillStages.MAX_STAGE = 8
SkillStages.MIN_STAGE = 1

export type SkillId = string

export type SkillDef = {
	id: SkillId,
	displayName: string,
	buttonName: string, -- Studio ImageButton under MobileSkillsB.dPad
}

local DEFS: { SkillDef } = {
	{ id = "PlotSize", displayName = "Plot Size", buttonName = "PlotSizeBTN" },
	{ id = "EarnMore", displayName = "Earn More", buttonName = "EarnMoreBTN" },
	{ id = "PlaceMore", displayName = "Place More", buttonName = "PlaceMoreBTN" },
}

local BY_ID: { [string]: SkillDef } = {}
local BY_BUTTON: { [string]: SkillDef } = {}
for _, def in ipairs(DEFS) do
	BY_ID[def.id] = def
	BY_BUTTON[def.buttonName] = def
end

function SkillStages.all(): { SkillDef }
	return DEFS
end

function SkillStages.get(id: string): SkillDef?
	return BY_ID[id]
end

function SkillStages.fromButtonName(name: string): SkillDef?
	local direct = BY_BUTTON[name]
	if direct then
		return direct
	end
	local lower = string.lower(name)
	for _, def in ipairs(DEFS) do
		if lower == string.lower(def.buttonName) then
			return def
		end
		if lower == string.lower(def.id) then
			return def
		end
		if lower == string.lower(def.id) .. "btn" then
			return def
		end
		-- e.g. "Plot Size BTN" / "plotsize_btn"
		local compact = string.gsub(lower, "[^%w]", "")
		local idCompact = string.gsub(string.lower(def.id), "[^%w]", "")
		if compact == idCompact or compact == idCompact .. "btn" then
			return def
		end
	end
	return nil
end

function SkillStages.isSkillButtonName(name: string): boolean
	return SkillStages.fromButtonName(name) ~= nil
end

function SkillStages.clampStage(n: any): number
	local v = math.floor(tonumber(n) or SkillStages.MIN_STAGE)
	return math.clamp(v, SkillStages.MIN_STAGE, SkillStages.MAX_STAGE)
end

function SkillStages.defaultMap(): { [string]: number }
	local m: { [string]: number } = {}
	for _, def in ipairs(DEFS) do
		m[def.id] = SkillStages.MIN_STAGE
	end
	return m
end

function SkillStages.sanitizeMap(raw: any): { [string]: number }
	local m = SkillStages.defaultMap()
	if typeof(raw) ~= "table" then
		return m
	end
	for _, def in ipairs(DEFS) do
		m[def.id] = SkillStages.clampStage(raw[def.id])
	end
	return m
end

-- $D cost to unlock `stage` (the stage being purchased). 0 for testing.
function SkillStages.stageCost(_skillId: string, _stage: number): number
	return 0
end

function SkillStages.nextStage(current: number): number?
	local c = SkillStages.clampStage(current)
	if c >= SkillStages.MAX_STAGE then
		return nil
	end
	return c + 1
end

-- Place More: stage 1 = 100 max coral; +20 max per stage.
SkillStages.PLACE_MORE_BASE_MAX = 100
SkillStages.PLACE_MORE_PER_STAGE = 20

function SkillStages.placeMoreMaxAtStage(stage: number): number
	local s = SkillStages.clampStage(stage)
	return SkillStages.PLACE_MORE_BASE_MAX + (s - 1) * SkillStages.PLACE_MORE_PER_STAGE
end

-- $D granted each time a fish hunger bar fills. Stage 1 = 1, stage 2 = 2×, …
function SkillStages.earnMorePerFish(stage: number): number
	return SkillStages.clampStage(stage)
end

-- Studio: MasterPlotDecor.PlotSizes.MasterTerrainBoxSTART / 2..7 / MAX
local PLOT_SIZE_PART_BY_STAGE: { [number]: string } = {
	[1] = "MasterTerrainBoxSTART",
	[2] = "MasterTerrainBox2",
	[3] = "MasterTerrainBox3",
	[4] = "MasterTerrainBox4",
	[5] = "MasterTerrainBox5",
	[6] = "MasterTerrainBox6",
	[7] = "MasterTerrainBox7",
	[8] = "MasterTerrainBoxMAX",
}

SkillStages.PLOT_SIZES_FOLDER = "PlotSizes"
SkillStages.CHANGE_SIZE_CAM = "ChangeSizeCam"
SkillStages.CHANGE_SIZE_CAM_FOCUS = "ChangeSizeCamFocus"

function SkillStages.plotSizePartName(stage: number): string
	local s = SkillStages.clampStage(stage)
	return PLOT_SIZE_PART_BY_STAGE[s] or PLOT_SIZE_PART_BY_STAGE[1]
end

function SkillStages.plotSizePartNames(): { [number]: string }
	return PLOT_SIZE_PART_BY_STAGE
end

--[[
	UnlockDesc copy for a skill at `stage` (usually the next unlock; if maxed, current).
]]
function SkillStages.unlockDesc(skillId: string, stage: number): string
	local s = SkillStages.clampStage(stage)
	if skillId == "PlotSize" then
		return "Bigger area you can plant coral"
	end
	if skillId == "PlaceMore" then
		local newMax = SkillStages.placeMoreMaxAtStage(s)
		return "+20  New Max: " .. tostring(newMax)
	end
	if skillId == "EarnMore" then
		if s <= 1 then
			return "+1 $D every time a fish's hunger bar is filled."
		end
		return "Get " .. tostring(s) .. "x per fish fed"
	end
	return ""
end

return SkillStages
