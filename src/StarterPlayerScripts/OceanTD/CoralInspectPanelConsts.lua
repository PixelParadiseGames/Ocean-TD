--!strict
-- Shared constants for CoralInspectPanel (keeps the panel under Luau's local register limit).

local CINE_TIME_SCALE = 0.75

return {
	GREEN = Color3.fromRGB(40, 170, 70),
	PULSE_GREEN = Color3.fromRGB(70, 255, 110),
	STROKE_DARK = Color3.fromRGB(16, 80, 32),
	ACTIVE_GREEN = Color3.fromRGB(40, 255, 90),
	WHITE = Color3.new(1, 1, 1),
	STAT_GREY = Color3.fromRGB(140, 140, 145),
	RED = Color3.fromRGB(220, 50, 55),
	PANEL_BG = Color3.fromRGB(12, 28, 36),
	-- Match RelocateController recycle chrome.
	REC_GREEN = Color3.fromRGB(48, 145, 70),
	DEFAULT_SWATCH_STROKE = Color3.fromRGB(220, 45, 45),
	COLOR_FOCUS = Color3.fromRGB(255, 220, 40),

	RECYCLE_ICON_IMAGE = "rbxassetid://75091344292202",
	GROW_SOUND_ID = "rbxassetid://134057288",
	DICE_SPIN_SOUND_ID = "rbxassetid://130406186928352",
	DEFAULT_PALETTE_SOUND_ID = "rbxassetid://130119587466421",
	PAINTBRUSH_ICON = "rbxassetid://139313922398517",
	DICE_ICON = "rbxassetid://77867192113507",

	-- Size-change cinematics: 25% faster than original 0.5s shrink / 0.9s grow.
	CINE_TIME_SCALE = CINE_TIME_SCALE,
	CINE_SHRINK_SEC = 0.5 * CINE_TIME_SCALE,
	CINE_GROW_SEC = 0.9 * CINE_TIME_SCALE,
	CINE_CAM_SEC = 0.5 * CINE_TIME_SCALE,
	CINE_CAM_BACK_SEC = 0.45 * CINE_TIME_SCALE,
	CINE_UNLOCK_GROW_SEC = 0.7 * CINE_TIME_SCALE,
	CINE_BRAIN_RESIZE_SEC = 0.28 * CINE_TIME_SCALE,

	DEFAULT_PALETTE_SWATCH = 0,
	LETTERS = { "S", "M", "L" },
	WORDS = { "Small", "Medium", "Large" },
}
