-- Shared tunables. Change here; all systems read these.
-- Keep PLOT_COUNT in sync with the Studio plot-stamp plugin.

local Constants = {
	CELL_SIZE = 4,
	PLOT_COUNT = 6,
	MAX_PLOTS = 6,

	-- Legacy folder fallback only
	PLOT_FOLDER_NAME = "Plots",
	ARENA_FOLDER_NAME = "Arena",
	CENTER_FOLDER_NAME = "Center",
	BOUNDS_NAME = "Bounds",
	SPAWN_NAME = "Spawn",
	-- Plot1 authored start; remapped into each assigned plot's local frame.
	PLOT1_START_POINT_NAME = "Plot 1 Start Point",

	-- Plugin contract: place MasterTerrainBox → Spawn/Update Previews
	MASTER_TERRAIN_NAME = "MasterTerrainBox",
	MASTER_DECOR_NAME = "MasterPlotDecor",
	STATIC_PLOT_PREFIX = "StaticPlot_", -- StaticPlot_2 .. StaticPlot_6 (no StaticPlot_1)
	TERRAIN_PREVIEWS_FOLDER = "TerrainPreviews", -- PreviewBox_* live here; Hide moves folder to ServerStorage
	-- PreviewBox_1 .. PreviewBox_5 are the other five plots (NOT PreviewBox_2..6)
	PREVIEW_BOX_PREFIX = "PreviewBox_",

	DATASTORE_NAME = "OceanTD_Player_v1",
	PROFILE_VERSION = 3,

	AUTOSAVE_INTERVAL_SEC = 60,

	HIGHEST_WAVE_ATTR = "OceanTD_HighestWave",
	CURRENT_WAVE_SIGN_NAME = "Current Wave Sign",
	-- Replicated on Player: which plot they own ("Plot1" …).
	PLOT_ID_ATTR = "OceanTD_PlotId",

	-- Four named plot presets; autosave writes the active slot.
	PLOT_SAVE_SLOT_COUNT = 4,
	-- New players start with this many BrainCoral seeds in inventory (not on plot).
	STARTING_BRAIN_CORAL_SEEDS = 50,
}

return Constants
