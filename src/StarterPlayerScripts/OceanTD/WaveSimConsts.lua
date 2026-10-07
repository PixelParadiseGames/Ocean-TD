--!strict
--[[
	Tunables for WaveSim — kept in a table so WaveSim.lua stays under Luau's 200-local limit.
]]

local FISH_SPEED = 16 -- 20 * 0.8
local FOOD_RISE_MAX = 1.85 -- was 2.65; snappier coral / tap orbs
local TARGET_RANGE = 50 -- was 30; +20 studs
local COMBAT_HZ = 10
local HUNGER_BAR_STRIP_H = 6 * 0.8
local HUNGER_EMOJI_SIZE = HUNGER_BAR_STRIP_H * 3 -- outside & in front of the bar

local C = {
	FISH_SPEED = FISH_SPEED,
	FISH_SPEED_VAR = 0.15, -- ±15% smooth speed variation
	-- Idea B: predict fish path-offset meet; food eases there (current sway). O(1)/shot.
	FOOD_FIRE_LEAD_SEC = 0.55, -- was 1; release closer to impact for faster shots
	FOOD_RISE_MIN = 1.35, -- was 2.15
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
	DEFAULT_RELOAD = 3, -- was 6; corals restock / shoot twice as often
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
	-- Max corals that call findClosestHungryFish / fireShot per combat tick (10 Hz).
	-- Prefer corals near the hungry fish front; rotate within the near-front pool for fairness.
	COMBAT_FIRE_BUDGET = 96,
	-- Feed mode: "volleys" | "lane_stock" | "path_fields"
	-- lane_stock = Option 2 contested path capacity (perf + lane pressure).
	FEED_MODE = "lane_stock",
	-- Wave-start nest food: wait, then spawn orbs randomly across this window (avoids one-frame hitch).
	AMMO_ARM_DELAY_SEC = 2,
	AMMO_ARM_SPREAD_SEC = 3,
	AMMO_ARM_PER_FRAME = 6,
	AMMO_FADE_IN_SEC = 0.35, -- transparency fade when nest orbs appear (lighter than scale)
	-- Session-start coral→path stamps spread across frames (main CPU hitch otherwise).
	PATH_STAMP_PER_FRAME = 10,
	-- Wave 1: wait until nest arm window finishes before first fish (smooth boot).
	WAVE1_SPAWN_LEAD_SEC = 5,
	-- Option 2: max food a fish drinks per second while stock lasts.
	LANE_DRINK_PER_SEC = 7, -- was 5; keep pace with faster reload
	-- Nest food stays parked; on feed pulse a copy may fly to the fish.
	-- Rise share ramps from wave LANE_RISE_RAMP_START → LANE_RISE_RAMP_END (50/50 at end).
	LANE_RISE_RAMP_START = 20,
	LANE_RISE_RAMP_END = 50,
	LANE_FISH_AIM_FRAC_END = 0.5, -- fish-aim share at/after ramp end (rest = nest rise)
	LANE_NEST_RISE_STUDS = 40,
	LANE_NEST_RISE_SEC = 2,
	LANE_NEST_HOLD_SEC = 0.08, -- 60% shorter (was 0.2)
	LANE_NEST_SLOT_STAGGER = 0.28, -- delay between slots starting (visual stagger)
	LANE_NEST_FADE_START = 0.28, -- fade ~twice as early (was 0.55)
	LANE_NEST_FADE_END = 0.48, -- fully faded mid-rise (was 0.92)
	-- 4b: wake corals near hungry crabs/urchins/sharks using each coral's feed range.
	GROUND_FEED_ACTIVATE_RANGE = 100, -- legacy pad; wake uses coral.rangeSq
	-- 8b: keep nest ammo Parts; only this many flying food Parts at once (near camera preferred).
	FOOD_VISIBLE_MAX = 48,
	FOOD_VISIBLE_DIST = 220, -- studs from camera to start / mid / meet
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
	WAVE1_COUNT = 3, -- base before /2 in waveFishCount
	WAVE_COUNT_STEP = 2,
	REEF_START_HEALTH = 10,
	TANG_HUNGER_BASE = 4, -- doubled (was 2); half as many tangs, same total hunger demand
	HUNGER_EVERY_WAVES = 5, -- +6 food every 5 waves
	HUNGER_PER_TIER = 6,
	FOOD_RADIUS = 0.52, -- was 0.65 (−20%)
	-- Player tap-to-feed: click/tap near a critter → food orb from screen-bottom.
	TAP_FEED_RADIUS = 5, -- was 10; tighter click/tap hit radius
	TAP_FEED_COOLDOWN_SEC = 1,
	TAP_FEED_DEBUG = false, -- translucent ball showing tap radius (dev)
	-- Screen Y (0 top → 1 bottom) for tap-orb spawn; keep above HUD / fish-cam horizon.
	TAP_FEED_SCREEN_Y = 0.5, -- food orb starts mid-screen (was lower ~0.72)
	TAP_FEED_START_DEPTH_MIN = 10,
	TAP_FEED_START_DEPTH_MAX = 20,
	TAP_FEED_FLIGHT_MULT = 0.5, -- half duration = 2× travel speed vs coral orbs
	TAP_FEED_FIRE_SOUND_ID = "rbxassetid://5852470908",
	TAP_FEED_FIRE_PITCH_MIN = 0.85,
	TAP_FEED_FIRE_PITCH_MAX = 1.2,
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
	ARROW_PATH_SPACING = 16, -- studs along path between arrow sets in the train
	ARROW_TRAIN_COUNT = 12, -- green fish train length (emerge from path start)
	ARROW_LABEL_EVERY = 4, -- "Wave N" on every Nth arrow set
	ARROW_SPIN_RAD_PER_SEC = 2.2, -- slow corkscrew roll
	-- Crab GroundA/B preview: red arrows; fixed short train.
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
	-- After wave 20: random 20–40% of Tang use WaveRoute.A2 instead of A.
	FISH_A2_AFTER_WAVE = 20,
	FISH_A2_FRAC_MIN = 0.20,
	FISH_A2_FRAC_MAX = 0.40,
	FISH_ROUTE_A2_NAME = "A2",
	-- Hungry crabs on WaveRoute.GroundA / GroundB (wave 5+); 50/50 per crab.
	CRAB_FIRST_WAVE = 7,
	CRAB_HUNGER_MULT = 0.84, -- × tang hunger (crabs + urchins); −50% from 1.68
	CRAB_SPEED_MULT = 0.75, -- 25% slower than Tang (between sprints)
	CRAB_SPRINT_MULT_MIN = 1.55,
	CRAB_SPRINT_MULT_MAX = 2.7,
	CRAB_SPRINT_DUR_MIN = 0.4,
	CRAB_SPRINT_DUR_MAX = 1.9,
	CRAB_SPRINT_REST_MIN = 0.3,
	CRAB_SPRINT_REST_MAX = 1.25,
	CRAB_ROUTE_NAME = "GroundA",
	CRAB_ROUTE_B_NAME = "GroundB",
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
	CRAB_ZAP_BUBBLE_COUNT = 8, -- was 16; hard max rising glass spheres per zap (incl. stream)
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
	-- Shark: waves 10/20/30… only; 1 per wave; swim route WaveRoute.Shark.
	SHARK_FIRST_WAVE = 10,
	SHARK_EVERY_WAVES = 10,
	SHARK_ROUTE_NAME = "Shark",
	SHARK_SPEED_MULT = 1.2, -- bit faster than Tang
	SHARK_HUNGER_BASE = 50, -- first shark tier hunger
	SHARK_HUNGER_PER_TIER = 10, -- +10 each ×10 wave
	SHARK_YAW = 0, -- was -90 (left flank led); +90° so nose leads
	SHARK_PITCH = 0,
	SHARK_ROLL = 0,
	SHARK_SWAY_YAW = math.rad(5.5), -- light client swim sway
	SHARK_SWAY_FREQ = 1.35,
	SHARK_MUSIC_ID = "rbxassetid://131430400979893",
	SHARK_MUSIC_FADE_SEC = 2,
	SHARK_CAM_ZOOM_IN_SEC = 1,
	SHARK_CAM_HOLD_SEC = 3,
	SHARK_CAM_ZOOM_OUT_SEC = 3,
	SHARK_CAM_DIST = 42,
	SHARK_CAM_HEIGHT = 14,
	TANG_FIRST_WAVE = 1, -- overview cam: full path + heart until fish fed
	TANG_CAM_OVERVIEW_ZOOM_SEC = 1.6,
	TANG_CAM_OVERVIEW_RESTORE_SEC = 1.4,
	TANG_CAM_OVERVIEW_SAMPLE_STEP = 16, -- match arrow spacing-ish along path
	TANG_CAM_OVERVIEW_PAD = 1.35,
	TANG_CAM_OVERVIEW_MIN_DIST = 80,
	TANG_CAM_OVERVIEW_HEIGHT = 42,
	TANG_CAM_OVERVIEW_FISH_ZOOM_SEC = 1.6,
	-- Start fish-focus cam this many seconds before first spawn.
	TANG_CAM_FISH_TRANSITION_LEAD_SEC = 1,
	TANG_CAM_OVERVIEW_FISH_PAD_MULT = 1.28,
	TANG_CAM_OVERVIEW_FISH_HEIGHT_MULT = 1.22,
	TANG_CAM_FISH_FOCUS_MIN_DIST = 36,
	TANG_CAM_FISH_FOCUS_MIN_HOLD_SEC = 3, -- extra hold on fish after they are fed, before restore
	TANG_CAM_FISH_FOCUS_HEIGHT = 18,
	TANG_CAM_FISH_FOCUS_BACK_MIN = 22,
	TANG_CAM_FISH_FOCUS_BACK_MAX = 70,
	TANG_CAM_FISH_FOCUS_LOOK_BLEND = 0.04, -- keep look on fish so they sit mid-frame (not bottom)
	TANG_CAM_FISH_FOCUS_LOOK_Y = -1.2, -- aim slightly below fish → fish higher toward mid-screen
	TANG_CAM_FISH_FOCUS_FOLLOW_RATE = 3.2, -- softer track; reduces fight/shake with moving school

	-- Urchins: waves 5/10/15…; count = W/5 (doubles growth past wave 100); half crab base speed.
	URCHIN_FIRST_WAVE = 5,
	URCHIN_EVERY_WAVES = 5,
	URCHIN_SPEED_MULT = 0.6, -- × crab base; +20% from 0.5
	-- Spawn gaps ~2× prior; wide range so packs clump or stretch naturally.
	URCHIN_STAGGER_MIN = 0.9,
	URCHIN_STAGGER_MAX = 5.6,
	URCHIN_FIRST_DELAY_MIN = 0.16,
	URCHIN_FIRST_DELAY_MAX = 1.3,
	URCHIN_SPEED_VAR = 0.16, -- ±16% walk speed so they don't lock in a band
	URCHIN_CLUSTER_CHANCE = 0.28, -- roll a short gap (near neighbor) this often
	URCHIN_CLUSTER_SPAN = 0.22, -- cluster gaps use this fraction of the stagger range
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
	-- Rolled count: uniform from max down to 40% fewer (min fraction of max).
	URCHIN_COUNT_MIN_FRAC = 0.6,
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

-- Wave 10 → 50, 20 → 60, 30 → 70…
function C.sharkHungerForWave(wave: number): number
	local w = math.max(1, math.floor(wave))
	local tier = math.max(1, math.floor(w / C.SHARK_EVERY_WAVES))
	return C.SHARK_HUNGER_BASE + (tier - 1) * (C.SHARK_HUNGER_PER_TIER or 10)
end

function C.sharkSpeed(): number
	return C.FISH_SPEED * C.SHARK_SPEED_MULT
end

-- Inclusive min/max crabs rolled for this wave.
-- Brackets: ≤10 → 0–1; 20–40 → 1–3; 41–60 → 2–4; 61–80 → 3–5; 81–100 → 4–6; then +1/+1 per +20 waves.
-- Waves 11–19 stay at 0–1 until the wave-20 band.
function C.crabCountRangeForWave(wave: number): (number, number)
	local w = math.max(1, math.floor(wave))
	if w < C.CRAB_FIRST_WAVE then
		return 0, 0
	end
	if w < 20 then
		return 0, 1
	end
	local band = if w <= 40 then 0 else math.ceil((w - 40) / 20)
	return 1 + band, 3 + band
end

-- Urchins on ×5 waves: floor(W/5) through wave 100; past 100 growth doubles (+1 per extra ×5 wave).
-- This is the max; actual spawn rolls down toward 40% fewer (see urchinCountRangeForWave).
function C.urchinCountForWave(wave: number): number
	local w = math.max(1, math.floor(wave))
	if w < C.URCHIN_FIRST_WAVE or w % C.URCHIN_EVERY_WAVES ~= 0 then
		return 0
	end
	local n = math.floor(w / C.URCHIN_EVERY_WAVES)
	if w > 100 then
		n += math.floor((w - 100) / C.URCHIN_EVERY_WAVES)
	end
	return n
end

-- Inclusive min/max urchins rolled for this wave (hi = formula max, lo ≈ 60% of max).
function C.urchinCountRangeForWave(wave: number): (number, number)
	local hi = C.urchinCountForWave(wave)
	if hi <= 0 then
		return 0, 0
	end
	local lo = math.max(1, math.floor(hi * C.URCHIN_COUNT_MIN_FRAC))
	if lo > hi then
		lo = hi
	end
	return lo, hi
end

function C.crabSlotForWave(wave: number): number
	local _, hi = C.crabCountRangeForWave(wave)
	return hi
end

return C
