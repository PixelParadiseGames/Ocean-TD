--!strict
--[[
	RelocateController magic numbers (chunked out to stay under Luau's 200-local limit).
]]

local RelocateConsts = {
	BTN_SIZE = 60,
	REC_BTN_SIZE = 40,
	REC_GAP_PX = 6,
	MOVE_ICON_SIZE = 48,
	MOVE_ICON_IMAGE = "rbxassetid://345081302",
	RECYCLE_ICON_IMAGE = "rbxassetid://75091344292202",
	GHOST_INVALID_COLOR = Color3.fromRGB(220, 70, 70),
	-- Raycast above the cursor so the coral center (+ move icon) sits under the mouse.
	AIM_VISUAL_CENTER_OFFSET_Y = 17, -- was 56; 70% less
	REC_GREEN = Color3.fromRGB(48, 145, 70),
	REC_GREEN_DIM = Color3.fromRGB(28, 88, 44),
	REC_FLASH_HZ = 1.5,
	REC_LABEL_PERIOD = 1,
	REC_SLIDE_SEC = 0.3,
	REC_FLY_SEC = 0.55,
	INTRO_SEC = 0.35,
	REVERT_SEC = 0.4,
	IDLE_CLOSE_DELAY_SEC = 3,
	DRAG_PX = 28,
	GHOST_SCREEN_OFFSET_Y = 32, -- was 105; 70% less raise above finger
	FREEZE_ACTION = "OceanTD_RelocateFreeze",
	HOVER_HINT_PERIOD = 1,
	HOVER_HINT_SIZE = 32,
	GAMEPAD_STICK_DEADZONE = 0.22,
	GAMEPAD_AIM_SPEED = 343,
	SEA_FAN_ROT_STEP = math.rad(10),
	PICK_TAP_PX = 48,
	PICK_SCREEN_PX = 42,
	DEFAULT_WALK_SPEED = 16,
	DEFAULT_JUMP_POWER = 75,
	DEFAULT_JUMP_HEIGHT = 10.8,
}

return RelocateConsts
