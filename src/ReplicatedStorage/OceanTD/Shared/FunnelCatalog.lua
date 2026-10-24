--!strict
-- Step lists for AnalyticsService funnels. Roblox allows 100 steps per funnel.

local FunnelCatalog = {}

FunnelCatalog.JOIN_NAME = "join_to_training"
FunnelCatalog.PLAY_NAME = "play_time"

-- 1 min, 3 min, 5 min, ... through step 90 (179 min). Under the 100-step cap.
FunnelCatalog.PLAY_STEP_COUNT = 90

FunnelCatalog.JOIN_STEPS = {
	"load_bar_shown",
	"load_bar_filled",
	"showcase_started",
	"showcase_exit",
	"plot_landed",
	"training_ready",
	"first_roll",
	"start_waves",
	"clear_wave_1",
	"end_waves",
	"skills",
	"manual_roll",
	"move_coral",
	"place_new_coral",
	"upgrade_coral",
	"hue_change",
	"close_backpack",
	"free_cam",
	"start_waves_again",
	"reach_wave_3",
	"reach_wave_5",
	"reach_wave_8",
	"reach_wave_10",
	"reach_wave_11",
}

local JOIN_INDEX: { [string]: number } = {}
for i, id in ipairs(FunnelCatalog.JOIN_STEPS) do
	JOIN_INDEX[id] = i
end

function FunnelCatalog.joinIndex(stepId: string): number?
	return JOIN_INDEX[stepId]
end

function FunnelCatalog.playMinutes(step: number): number
	return 1 + (step - 1) * 2
end

function FunnelCatalog.playStepName(step: number): string
	return string.format("%d min", FunnelCatalog.playMinutes(step))
end

return FunnelCatalog
