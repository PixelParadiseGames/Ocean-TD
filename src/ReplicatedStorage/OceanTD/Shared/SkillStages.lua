--!strict
--[[
	Skill stage catalog (UI + persist). Gameplay effects come later.
	Most skills: stages 1..8. Wave Speed: stages 1..4. All skills start at 1.
]]

local SkillStages = {}

SkillStages.MAX_STAGE = 8
SkillStages.MIN_STAGE = 1

export type SkillId = string

export type SkillDef = {
	id: SkillId,
	displayName: string,
	buttonName: string, -- Studio ImageButton under MobileSkillsA.dPad
}

local DEFS: { SkillDef } = {
	{ id = "PlotSize", displayName = "Plot Size", buttonName = "PlotSizeBTN" },
	{ id = "EarnMore", displayName = "Earn More", buttonName = "EarnMoreBTN" },
	{ id = "PlaceMore", displayName = "Place More", buttonName = "PlaceMoreBTN" },
	{ id = "RHealth", displayName = "Reef Health", buttonName = "RHealthBTN" },
	{ id = "Skip", displayName = "Skip Wave", buttonName = "SkipBTN" },
	{ id = "WaveSpeed", displayName = "Wave Speed", buttonName = "WaveSpeedBTN" },
}

local BY_ID: { [string]: SkillDef } = {}
local BY_BUTTON: { [string]: SkillDef } = {}
for _, def in ipairs(DEFS) do
	BY_ID[def.id] = def
	BY_BUTTON[def.buttonName] = def
end

-- Studio ImageButtons used only for bubble size + label placement per stage.
-- Label *text* stays skill-authored; geometry comes from these templates.
local BUBBLE_LAYOUT_BTN_BY_STAGE: { [number]: string } = {
	[1] = "PlaceMoreBTN",
	[2] = "RHealthBTN",
	[3] = "SkipBTN",
	[4] = "EarnMoreBTN",
	[5] = "RollSpeedBTN",
	[6] = "LuckBTN",
	[7] = "WaveSpeedBTN",
	[8] = "PlotSizeBTN",
}

function SkillStages.bubbleLayoutButtonName(stage: number): string
	local s = SkillStages.clampStage(stage)
	return BUBBLE_LAYOUT_BTN_BY_STAGE[s] or BUBBLE_LAYOUT_BTN_BY_STAGE[1]
end

function SkillStages.isBubbleLayoutButtonName(name: string): boolean
	local lower = string.lower(name)
	for _, n in pairs(BUBBLE_LAYOUT_BTN_BY_STAGE) do
		if lower == string.lower(n) then
			return true
		end
	end
	return false
end

-- Layout-only Studio buttons (not playable skill bubbles).
function SkillStages.isBubbleLayoutOnlyButtonName(name: string): boolean
	return SkillStages.isBubbleLayoutButtonName(name) and not SkillStages.isSkillButtonName(name)
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

-- Per-skill stage cap (Wave Speed is 1–3; others use MAX_STAGE).
function SkillStages.maxStageFor(skillId: string): number
	if skillId == "WaveSpeed" then
		return 4
	end
	return SkillStages.MAX_STAGE
end

function SkillStages.clampStageFor(skillId: string, n: any): number
	local v = math.floor(tonumber(n) or SkillStages.MIN_STAGE)
	return math.clamp(v, SkillStages.MIN_STAGE, SkillStages.maxStageFor(skillId))
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
		m[def.id] = SkillStages.clampStageFor(def.id, raw[def.id])
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

function SkillStages.nextStageFor(skillId: string, current: number): number?
	local maxS = SkillStages.maxStageFor(skillId)
	local c = SkillStages.clampStageFor(skillId, current)
	if c >= maxS then
		return nil
	end
	return c + 1
end

-- Wave Speed button: stage 1 = 1x only (locked UI); 2 = up to 1.5x; 3 = up to 2x; 4 = + pause.
function SkillStages.waveSpeedMaxStep(stage: number): number
	return SkillStages.clampStageFor("WaveSpeed", stage)
end

function SkillStages.waveSpeedLocked(stage: number): boolean
	return SkillStages.clampStageFor("WaveSpeed", stage) <= 1
end

function SkillStages.waveSpeedPauseUnlocked(stage: number): boolean
	return SkillStages.clampStageFor("WaveSpeed", stage) >= 4
end

-- Place More max placed coral by stage. Stages 1–4 ramp gently; 5–8 ramp hard to 1000 cap.
SkillStages.PLACE_MORE_BASE_MAX = 30
SkillStages.PLACE_MORE_MAX_STAGE = 1000

local PLACE_MORE_MAX_BY_STAGE: { [number]: number } = {
	[1] = 30,
	[2] = 50,
	[3] = 90,
	[4] = 150,
	[5] = 280,
	[6] = 450,
	[7] = 700,
	[8] = 1000,
}

function SkillStages.placeMoreMaxAtStage(stage: number): number
	local s = SkillStages.clampStage(stage)
	return PLACE_MORE_MAX_BY_STAGE[s] or PLACE_MORE_MAX_BY_STAGE[1]
end

function SkillStages.placeMoreIncrementAtStage(stage: number): number
	local s = SkillStages.clampStage(stage)
	if s <= 1 then
		return 0
	end
	return SkillStages.placeMoreMaxAtStage(s) - SkillStages.placeMoreMaxAtStage(s - 1)
end

-- $D granted each time a fish hunger bar fills. Stage 1 = 1, stage 2 = 2×, …
function SkillStages.earnMorePerFish(stage: number): number
	return SkillStages.clampStage(stage)
end

-- Final WaveRoute waypoint index (W#) for this Plot Size stage.
-- Stages 1–2 end at W4; larger plots extend toward W8.
local PLOT_SIZE_FINAL_WAYPOINT: { [number]: number } = {
	[1] = 4,
	[2] = 4,
	[3] = 6,
	[4] = 6,
	[5] = 7,
	[6] = 8,
	[7] = 8,
	[8] = 8,
}

function SkillStages.plotSizeFinalWaypoint(stage: number): number
	local s = SkillStages.clampStage(stage)
	return PLOT_SIZE_FINAL_WAYPOINT[s] or PLOT_SIZE_FINAL_WAYPOINT[1]
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
		if SkillStages.nextStage(s) == nil then
			return "Max: " .. tostring(SkillStages.placeMoreMaxAtStage(s))
		end
		local inc = SkillStages.placeMoreIncrementAtStage(s)
		local newMax = SkillStages.placeMoreMaxAtStage(s)
		return "+" .. tostring(inc) .. "  New Max: " .. tostring(newMax)
	end
	if skillId == "EarnMore" then
		if s <= 1 then
			return "+1 $D every time a fish's hunger bar is filled."
		end
		return "Get " .. tostring(s) .. "x per fish fed"
	end
	if skillId == "RHealth" then
		if SkillStages.nextStage(s) == nil then
			return "Max: " .. tostring(SkillStages.reefHealthAtStage(s))
		end
		local inc = SkillStages.reefHealthIncrementAtStage(s)
		local newMax = SkillStages.reefHealthAtStage(s)
		return "+" .. tostring(inc) .. "  New Max: " .. tostring(newMax)
	end
	if skillId == "Skip" then
		if SkillStages.isSkipUnlimited(s) or SkillStages.nextStage(s) == nil then
			return "Unlimited Skips"
		end
		local uses = SkillStages.skipUsesAtStage(s)
		if uses <= 0 then
			return "Unlock stage 2 for 1 skip per wave session"
		end
		local inc = SkillStages.skipUsesIncrementAtStage(s)
		return "+" .. tostring(inc) .. "  New Max: " .. tostring(uses) .. " per session"
	end
	if skillId == "WaveSpeed" then
		if s <= 1 then
			return "Normal wave speed"
		end
		if s == 2 then
			return "Unlock 1.5x wave speed"
		end
		if s == 3 then
			return "Unlock 2x wave speed"
		end
		if s == 4 then
			return "Unlock wave pause"
		end
		return "All wave speeds unlocked"
	end
	return ""
end

-- Earn More / Place More stay gated until Plot Size reaches this stage.
SkillStages.PLOT_SIZE_GATE_STAGE = 2

function SkillStages.isGatedByPlotSize(skillId: string): boolean
	return skillId == "EarnMore" or skillId == "PlaceMore"
end

function SkillStages.isLockedUntilPlotSize(skillId: string, plotSizeStage: number): boolean
	if not SkillStages.isGatedByPlotSize(skillId) then
		return false
	end
	return SkillStages.clampStage(plotSizeStage) < SkillStages.PLOT_SIZE_GATE_STAGE
end

-- Reef Health stays gated until Place More reaches this stage (stage 2 purchased).
SkillStages.PLACE_MORE_GATE_STAGE = 2
SkillStages.REEF_HEALTH_BASE = 10
SkillStages.REEF_HEALTH_PER_STAGE = 10

function SkillStages.reefHealthAtStage(stage: number): number
	local s = SkillStages.clampStage(stage)
	return SkillStages.REEF_HEALTH_BASE + SkillStages.REEF_HEALTH_PER_STAGE * (s - 1)
end

function SkillStages.reefHealthIncrementAtStage(stage: number): number
	local s = SkillStages.clampStage(stage)
	if s <= 1 then
		return 0
	end
	return SkillStages.REEF_HEALTH_PER_STAGE
end

function SkillStages.isGatedByPlaceMore(skillId: string): boolean
	return skillId == "RHealth"
end

function SkillStages.isLockedUntilPlaceMore(skillId: string, placeMoreStage: number): boolean
	if not SkillStages.isGatedByPlaceMore(skillId) then
		return false
	end
	return SkillStages.clampStage(placeMoreStage) < SkillStages.PLACE_MORE_GATE_STAGE
end

function SkillStages.isSkillLocked(skillId: string, stages: { [string]: number }): boolean
	local plot = if typeof(stages) == "table" then stages.PlotSize else 1
	local place = if typeof(stages) == "table" then stages.PlaceMore else 1
	return SkillStages.isLockedUntilPlotSize(skillId, plot)
		or SkillStages.isLockedUntilPlaceMore(skillId, place)
end

-- Skip Wave: stage 1 = 0 uses; stage 2 = 1 use/session; each further stage +1.
-- Max stage = unlimited skips. Session = WaveSim.start() until stop.
function SkillStages.isSkipUnlimited(stage: number): boolean
	return SkillStages.clampStage(stage) >= SkillStages.MAX_STAGE
end

function SkillStages.skipUsesAtStage(stage: number): number
	local s = SkillStages.clampStage(stage)
	if SkillStages.isSkipUnlimited(s) then
		return math.huge
	end
	return math.max(0, s - 1)
end

function SkillStages.skipUsesIncrementAtStage(stage: number): number
	local s = SkillStages.clampStage(stage)
	if s <= 1 then
		return 0
	end
	if SkillStages.isSkipUnlimited(s) then
		return 0
	end
	return 1
end

return SkillStages
