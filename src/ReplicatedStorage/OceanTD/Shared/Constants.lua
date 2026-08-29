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
	PROFILE_VERSION = 7,

	AUTOSAVE_INTERVAL_SEC = 60,

	HIGHEST_WAVE_ATTR = "OceanTD_HighestWave",
	HIGHEST_FISH_FED_ATTR = "OceanTD_HighestFishFed",
	LONGEST_WAVE_SEC_ATTR = "OceanTD_LongestWaveSec",
	CURRENT_WAVE_SIGN_NAME = "Current Wave Sign",
	-- Replicated on Player: which plot they own ("Plot1" …).
	PLOT_ID_ATTR = "OceanTD_PlotId",
	-- Replicated on Player: plot outline palette index 1–15 (see PlotOutlineColors).
	PLOT_OUTLINE_COLOR_ATTR = "PlotOutlineColorIndex",
	-- Replicated on Player: authoritative $D (sand dollars). Client never writes this.
	SAND_DOLLARS_ATTR = "OceanTD_SandDollars",
	-- Hard cap so wallet math stays a safe integer (below 2^53).
	SAND_DOLLARS_MAX = 1000000000000000, -- 1e15
	-- Studio left HUD: MobileLeftUI.dPad.$D + $DCount
	SAND_DOLLARS_LABEL_NAME = "$D",
	SAND_DOLLARS_COUNT_NAME = "$DCount",

	-- Four named plot presets; autosave writes the active slot.
	PLOT_SAVE_SLOT_COUNT = 4,
	-- New players start with this many BrainCoral seeds in inventory (not on plot).
	STARTING_BRAIN_CORAL_SEEDS = 50,
	-- Sponge seeds for new / empty-plot soft grant.
	STARTING_SPONGE_SEEDS = 50,
	-- Sea Grass seeds for new / empty-plot soft grant.
	STARTING_SEA_GRASS_SEEDS = 50,
	-- Fire Coral seeds for new / empty-plot soft grant.
	STARTING_FIRE_CORAL_SEEDS = 50,
	-- Zoas seeds for new / empty-plot soft grant.
	STARTING_ZOAS_SEEDS = 50,
	-- Tree Coral seeds for new / empty-plot soft grant.
	STARTING_TREE_CORAL_SEEDS = 50,
	-- Leather Coral seeds for new / empty-plot soft grant.
	STARTING_LEATHER_CORAL_SEEDS = 50,
	-- Sea Fan seeds for new / empty-plot soft grant (same rules as other corals).
	STARTING_SEA_FAN_SEEDS = 50,
	SEA_FAN_UNLIMITED_SEEDS = false,
}

return Constants
