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
	DEFAULT_RELOAD = 3, -- matches BrainCoral (50% slower than original 2s)
	TARGET_RANGE = TARGET_RANGE,
	TARGET_RANGE_SQ = TARGET_RANGE * TARGET_RANGE,
	-- Path-bucket targeting: corals only see fish in an arrival window along the route.
	PATH_BUCKET_SIZE = 10, -- studs of path length per bucket
	PATH_TARGET_LEAD_MAX = FISH_SPEED * FOOD_RISE_MAX + 12, -- fish this far before coral
	PATH_TARGET_PAST = 32, -- was 8; fish that slip past still get fed
	PATH_PROJECT_STEP = 4, -- studs between samples when projecting coral→path
	-- School stay readable: clamp dive below the path sample (studs).
	FISH_MIN_PATH_Y = -1.25,
	COMBAT_HZ = COMBAT_HZ,
	COMBAT_DT = 1 / COMBAT_HZ,
	PATH_SAMPLE_STEP = 1.5,
	STAGGER_SEC = 0.4,
	STAGGER_MIN_SEC = 0.16, -- cap so late waves still read as separate fish
	STAGGER_PER_WAVE_MULT = 0.985, -- each wave spawns ~1.5% faster
	LATERAL_SPREAD = 7.5, -- base left/right spread across the school
	VERT_SPREAD = 2.8, -- base height spread
	BOB_AMP_MIN = 2.5,
	BOB_AMP_MAX = 5.0, -- slow vertical wander
	WANDER_AMP_MIN = 3.5,
	WANDER_AMP_MAX = 7.25,
	HASH_CELL = 30,
	DEFAULT_FOOD_FILL = 1,
	WAVE1_COUNT = 3,
	WAVE_COUNT_STEP = 4,
	REEF_START_HEALTH = 10,
	TANG_HUNGER_BASE = 2, -- waves 1–10
	HUNGER_EVERY_WAVES = 10,
	HUNGER_PER_TIER = 2, -- +2 food to fill the bar every 10 waves
	FOOD_RADIUS = 0.65,
	AMMO_RADIUS = 0.75,
	HUNGER_BAR_PX_W = 40 * 0.8,
	HUNGER_BAR_STRIP_H = HUNGER_BAR_STRIP_H,
	HUNGER_EMOJI_SIZE = HUNGER_EMOJI_SIZE,
	HUNGER_BAR_GAP = 3 * 0.8,
	HUNGER_BAR_PX_H = HUNGER_EMOJI_SIZE,
	HUNGER_BAR_HEIGHT = 2.85 * 0.8, -- studs above fish
	HUNGER_BAR_MAX_DIST = 0, -- 0 = always show hungry bars (was 220; hidden “ghost” fish)
	HUNGER_BAR_DANGER_MAX_DIST = 0, -- 0 = no distance cull while flashing red
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
	TURN_RATE = 14, -- higher = snappier yaw toward path tangent
	-- Soften G1 breaks between independent quadratic segments (lateral offset snaps without this).
	TANGENT_BLEND_STUDS = 5,
}

function C.tangHungerForWave(wave: number): number
	local w = math.max(1, math.floor(wave))
	local tier = math.floor((w - 1) / C.HUNGER_EVERY_WAVES)
	return C.TANG_HUNGER_BASE + tier * C.HUNGER_PER_TIER
end

return C
