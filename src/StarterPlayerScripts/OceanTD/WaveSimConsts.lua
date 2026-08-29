--!strict
--[[
	Tunables for WaveSim — kept in a table so WaveSim.lua stays under Luau's 200-local limit.
]]

local FISH_SPEED = 16 -- 20 * 0.8
local FOOD_RISE_MAX = 2.65 -- was 1.65 (+ lead)
local TARGET_RANGE = 50 -- was 30; +20 studs
local COMBAT_HZ = 10
local HUNGER_BAR_STRIP_H = 6 * 0.8
local HUNGER_EMOJI_SIZE = HUNGER_BAR_STRIP_H * 3 -- outside & in front of the bar

local C = {
	FISH_SPEED = FISH_SPEED,
	FISH_SPEED_VAR = 0.15, -- ±15% smooth speed variation
	-- Idea B: predict fish path-offset meet; food eases there (current sway). O(1)/shot.
	FOOD_FIRE_LEAD_SEC = 1, -- release this much earlier so the float can be slower
	FOOD_RISE_MIN = 2.15, -- was 1.15 (+ lead)
	FOOD_RISE_MAX = FOOD_RISE_MAX,
	FOOD_FRONT_LEAD = 2.4, -- meet at mouth, ahead along path tangent
	FOOD_EAT_RADIUS_SQ = 81, -- 9^2 — was 7^2; covers speed-surge + school wander miss
	FOOD_EAT_Y = 7.0, -- was 5.5
	FOOD_SWAY_AMP = 1.0, -- was 1.6; less mid-flight drift away from mouth
	FOOD_HOME_START_U = 0.35, -- blend flight toward live mouth after this fraction
	FOOD_END_GRACE_RADIUS_SQ = 144, -- 12^2 last-chance eat when flight ends
	FOOD_END_GRACE_Y = 9.0,
	-- Seeds lobbed at crabs: peak height = clamp(flatDist * frac, min, max).
	FOOD_CRAB_ARC_FRAC = 0.42,
	FOOD_CRAB_ARC_MIN = 5,
	FOOD_CRAB_ARC_MAX = 16,
	DEFAULT_RELOAD = 6, -- matches BrainCoral (half as fast as previous 3s)
	TARGET_RANGE = TARGET_RANGE,
	TARGET_RANGE_SQ = TARGET_RANGE * TARGET_RANGE,
	-- Path-bucket targeting: corals only see fish in an arrival window along the route.
	PATH_BUCKET_SIZE = 10, -- studs of path length per bucket
	PATH_TARGET_LEAD_MAX = FISH_SPEED * FOOD_RISE_MAX + 12, -- fish this far before coral
	PATH_TARGET_PAST = 32, -- was 8; fish that slip past still get fed
	PATH_PROJECT_STEP = 4, -- studs between samples when projecting coral→path
	-- School stay readable: clamp dive below the path sample (studs).
	FISH_MIN_PATH_Y = -8.5, -- allow deeper swim lanes
	COMBAT_HZ = COMBAT_HZ,
	COMBAT_DT = 1 / COMBAT_HZ,
	PATH_SAMPLE_STEP = 1.5,
	STAGGER_SEC = 0.4,
	STAGGER_MIN_SEC = 0.16, -- cap so late waves still read as separate fish
	STAGGER_PER_WAVE_MULT = 0.985, -- each wave spawns ~1.5% faster
	LATERAL_SPREAD = 7.5, -- base left/right spread across the school
	VERT_SPREAD = 9.5, -- base height spread across the school
	BOB_AMP_MIN = 2.5,
	BOB_AMP_MAX = 9.0, -- slow vertical wander
	WANDER_AMP_MIN = 3.5,
	WANDER_AMP_MAX = 7.25,
	HASH_CELL = 30,
	DEFAULT_FOOD_FILL = 1,
	WAVE1_COUNT = 3,
	WAVE_COUNT_STEP = 2,
	REEF_START_HEALTH = 10,
	TANG_HUNGER_BASE = 2, -- waves 1–10
	HUNGER_EVERY_WAVES = 10,
	HUNGER_PER_TIER = 2, -- +2 food to fill the bar every 10 waves
	FOOD_RADIUS = 0.52, -- was 0.65 (−20%)
	AMMO_RADIUS = 0.6, -- was 0.75 (−20%)
	HUNGER_BAR_PX_W = 28 * 0.8, -- fill strip (was 40 * 0.8)
	HUNGER_BAR_STRIP_H = HUNGER_BAR_STRIP_H,
	HUNGER_EMOJI_SIZE = HUNGER_EMOJI_SIZE,
	HUNGER_BAR_GAP = 3 * 0.8,
	HUNGER_BAR_PX_H = HUNGER_EMOJI_SIZE,
	HUNGER_REMAIN_W = 20, -- "N" between fork emoji and bar
	HUNGER_REMAIN_GAP = 2,
	HUNGER_REMAIN_TEXT_SIZE = HUNGER_EMOJI_SIZE - 1, -- one size under the fork
	HUNGER_BAR_HEIGHT = 2.85 * 0.8, -- studs above fish
	HUNGER_BAR_MAX_DIST = 0, -- 0 = always show hungry bars (was 220; hidden “ghost” fish)
	HUNGER_BAR_DANGER_MAX_DIST = 0, -- 0 = no distance cull while flashing red
	DANGER_NEAR_END_STUDS = 100, -- hungry bars flash red within this many studs of route end
	HAPPY_EMOJIS = { "😊", "😄", "😁", "😆", "🥰", "😍", "💖", "🤩" },
	HAPPY_FLASH_ON = 2,
	HAPPY_FLASH_OFF = 3,
	FILL_GREEN = Color3.fromRGB(40, 255, 90),
	DANGER_RED = Color3.fromRGB(255, 45, 55),
	FEED_SOUND_ID = "rbxassetid://139487580236703",
	FEED_PITCH_MIN = 0.82,
	FEED_PITCH_MAX = 1.28,
	FEED_PITCH_STEP = 0.06,
	ARROW_SPEED_MULT = 4, -- GreenArrows travel this × fish speed
	ARROW_LEAD_SEC = 1, -- fish spawn this long after arrows start
	ARROW_SOUND_ID = "rbxassetid://1845466760",
	ARROW_PATH_SPACING = 16, -- studs along path between arrow sets (full route)
	ARROW_LABEL_EVERY = 4, -- "Wave N" on every Nth arrow set
	ARROW_SPIN_RAD_PER_SEC = 2.2, -- slow corkscrew roll
	-- Crab GroundA preview: red arrows; fixed short train.
	CRAB_ARROW_COUNT = 8,
	CRAB_ARROW_PATH_SPACING = 32, -- studs between crab arrow sets
	CRAB_ARROW_COLOR = Color3.fromRGB(230, 45, 55),
	CRAB_ARROW_Y_LIFT = 1.35, -- keep red arrows readable above the seafloor
	-- Flat carpet was backwards; yaw 180 fixes facing. Roll 90 stands it up like a fence
	-- (pitch ±90 was tipping the tips straight down).
	ARROW_YAW = math.rad(180),
	ARROW_ROLL = math.rad(90),
	WAVE_LABEL_SCALE = Vector2.new(14 * 1.15, 5 * 1.15), -- studs; +15% vs original
	WAVE_LABEL_HEIGHT = 4,
	-- Tang facing: lookAt + fixed yaw (same idea as GreenArrows). +90° had the wrong face leading.
	TANG_YAW = math.rad(-90),
	TANG_PITCH = 0,
	TANG_ROLL = 0,
	-- Hungry crabs on WaveRoute.GroundA (wave 5+).
	CRAB_FIRST_WAVE = 5,
	CRAB_HUNGER_MULT = 10, -- max hunger = fish hunger × this
	CRAB_SPEED_MULT = 0.75, -- 25% slower than Tang (between sprints)
	CRAB_SPRINT_MULT_MIN = 1.55,
	CRAB_SPRINT_MULT_MAX = 2.7,
	CRAB_SPRINT_DUR_MIN = 0.4,
	CRAB_SPRINT_DUR_MAX = 1.9,
	CRAB_SPRINT_REST_MIN = 0.3,
	CRAB_SPRINT_REST_MAX = 1.25,
	CRAB_ROUTE_NAME = "GroundA",
	-- Sideways scuttle: mesh forward (eyes/claws) faces across the path, not along it.
	CRAB_YAW = math.rad(90),
	CRAB_PITCH = 0,
	CRAB_ROLL = 0,
	CRAB_GROUND_CLEARANCE = 1.85, -- Root above seafloor (not glued to waypoint Y)
	CRAB_GROUND_FOLLOW = 7, -- smooth Y so voxel stairs don't pop
	CRAB_RAY_UP = 28,
	CRAB_RAY_DOWN = 90,
	CRAB_ANIM_PHASE_RATE = 1.5,
	CRAB_ANIM_LIFT = 0.3,
	CRAB_ANIM_MIN_SPEED = 0.5,
	CRAB_ANIM_FADE_SPEED = 2,
	CRAB_STAGGER_MIN = 0.75, -- extra crabs spawn this many seconds after the previous
	CRAB_STAGGER_MAX = 4.5,
	CRAB_FIRST_DELAY_MIN = 0.15, -- first crab after the first fish
	CRAB_FIRST_DELAY_MAX = 1.8,
	CRAB_CORAL_PAUSE_SEC = 3, -- ShellHitbox touch: sit still while zap VFX plays
	CRAB_LATERAL_SPREAD = 5, -- left/right path deviation (studs)
	CRAB_WANDER_AMP_MIN = 1.2,
	CRAB_WANDER_AMP_MAX = 2.8,
	CRAB_ZAP_COUNT = 30,
	CRAB_ZAP_EMOJI = "💥⚡",
	CRAB_ZAP_LIFE_MIN = 1,
	CRAB_ZAP_LIFE_MAX = 3,
	CRAB_ZAP_START_STUDS = 0.2,
	CRAB_ZAP_START_STUDS_MAX = 1.2,
	CRAB_ZAP_END_STUDS = 1.2,
	CRAB_ZAP_END_STUDS_MAX = 6.5,
	CRAB_ZAP_TRANS_MIN = 0,
	CRAB_ZAP_TRANS_MAX = 0.5,
	CRAB_ZAP_BUBBLE_COUNT = 16,
	CRAB_ZAP_BUBBLE_SIZE_MIN = 0.2,
	CRAB_ZAP_BUBBLE_SIZE_MAX = 3.40, -- 2× previous 1.70
	CRAB_ZAP_BUBBLE_LIFE = 8,
	CRAB_ZAP_BUBBLE_RISE_MIN = 40.5, -- 3× previous 13.5
	CRAB_ZAP_BUBBLE_RISE_SPAN = 31.5, -- 3× previous 10.5
	CRAB_ZAP_BUBBLE_TRANS_MIN = 0.05, -- less transparent than before (was 0.2)
	CRAB_ZAP_BUBBLE_TRANS_MAX = 0.5,
	CRAB_ZAP_BUBBLE_COLOR = Color3.fromRGB(125, 200, 255), -- light blue
	CRAB_SKULL_EMOJI = "💀",
	CRAB_SKULL_SEC = 2.4,
	CRAB_SKULL_START_STUDS = 0.35,
	CRAB_SKULL_END_STUDS = 9.18, -- 70% larger than 5.4
	CRAB_SKULL_RISE = 8.1, -- was 6.2
	CRAB_STUN_FADE_SEC = 0.75,
	CRAB_FIGHT_RADIUS = 0.9,
	CRAB_FIGHT_HOP = 0.62,
	CRAB_FIGHT_SPIN = math.rad(155), -- rad/sec while zapping a coral
	CRAB_FIGHT_YAW_WOBBLE = math.rad(32),
	CRAB_FIGHT_PITCH = math.rad(14),
	-- Urchins: waves 10/20/30… count = wave/10; spawn before fish; half crab base speed.
	URCHIN_FIRST_WAVE = 10,
	URCHIN_EVERY_WAVES = 10,
	URCHIN_SPEED_MULT = 0.5, -- × crab base (crab base = FISH_SPEED × CRAB_SPEED_MULT)
	URCHIN_STAGGER_MIN = 0.45,
	URCHIN_STAGGER_MAX = 2.8,
	URCHIN_FIRST_DELAY_MIN = 0.08,
	URCHIN_FIRST_DELAY_MAX = 0.65,
	-- Player sting: knockback + red flash + $D steal/orbs.
	URCHIN_STING_COOLDOWN_SEC = 3,
	URCHIN_STING_STEAL_MAX = 30,
	URCHIN_STING_HIT_RADIUS = 5.5, -- flat XZ + sphere stand-on radius
	URCHIN_STING_HIT_Y = 8,
	URCHIN_STING_REPORT_RADIUS = 120,
	URCHIN_STING_VICTIM_RADIUS = 22,
	URCHIN_STING_KB_SPEED = 58, -- horizontal impulse (~10–30 studs travel)
	URCHIN_STING_KB_UP = 32,
	URCHIN_STING_SOUND_STAB = "rbxassetid://2900321088",
	URCHIN_STING_SOUND_OOF = "rbxasset://sounds/uuhhh.mp3",
	URCHIN_ORB_LIFETIME_SEC = 20,
	URCHIN_ORB_SETTLE_SEC = 1.1, -- half as fast as prior 0.55s settle
	URCHIN_ORB_SPREAD_MIN = 3.3, -- 50% further than 2.2
	URCHIN_ORB_SPREAD_SPAN = 5.1, -- 50% further than 3.4
	URCHIN_ORB_COLOR = Color3.fromRGB(40, 255, 90),
	URCHIN_ORB_PICKUP_SOUND = "rbxassetid://139487580236703", -- reuse feed ping (valid Sound)
	TURN_RATE = 14, -- legacy; fish facing uses PATH_TANG_SMOOTH_RATE
	-- Smooth path heading so school lateral offsets don't snap at waypoint joins.
	PATH_TANG_SMOOTH_RATE = 11,
	-- Soften G1 breaks between independent quadratic segments (lateral offset snaps without this).
	TANGENT_BLEND_STUDS = 8,
}

function C.tangHungerForWave(wave: number): number
	local w = math.max(1, math.floor(wave))
	local tier = math.floor((w - 1) / C.HUNGER_EVERY_WAVES)
	return C.TANG_HUNGER_BASE + tier * C.HUNGER_PER_TIER
end

function C.crabHungerForWave(wave: number): number
	return C.tangHungerForWave(wave) * C.CRAB_HUNGER_MULT
end

-- Inclusive min/max crabs rolled for this wave.
function C.crabCountRangeForWave(wave: number): (number, number)
	local w = math.max(1, math.floor(wave))
	if w < C.CRAB_FIRST_WAVE then
		return 0, 0
	end
	if w <= 10 then
		return 0, 1
	end
	if w <= 20 then
		return 1, 3
	end
	if w <= 40 then
		return 2, 4
	end
	return 3, 6 -- 41+
end

function C.crabSlotForWave(wave: number): number
	local _, hi = C.crabCountRangeForWave(wave)
	return hi
end

return C
