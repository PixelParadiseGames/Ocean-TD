-- Shared type aliases (documentation for Luau; runtime is plain tables).

export type PlotId = string -- "Plot1" .. "Plot6"

export type PlotBoundsPayload = {
	plotId: PlotId,
	cframe: CFrame,
	size: Vector3,
	spawnCFrame: CFrame?,
	-- Plot1 / MasterTerrainBox pose (for remapping WaveRoute etc. onto other plots).
	plot1CFrame: CFrame?,
}

export type LayoutObject = {
	id: string,
	-- Plot-local VisualPos (exact). Restore via plot.CFrame:PointToWorldSpace — never re-raycast.
	lx: number,
	ly: number,
	lz: number,
	-- Optional rounded grid keys (preferred for occupancy). Fallback: WorldToGrid(VisualPos).
	gx: number?,
	gy: number?,
	gz: number?,
}

export type PlotSaveSlot = {
	name: string,
	saved: boolean, -- false → UI shows NEW instead of LOAD
	layout: { LayoutObject },
}

export type PlotSaves = {
	activeIndex: number, -- 1 .. PLOT_SAVE_SLOT_COUNT
	slots: { PlotSaveSlot },
}

export type PlayerProfile = {
	version: number,
	currencies: {
		sandDollars: number,
		gold: number,
	},
	inventory: { [string]: any },
	skillTree: { [string]: any },
	layout: { LayoutObject }, -- mirror of active plot-save slot (compat + hydrate)
	plotSaves: PlotSaves,
	highestWave: number, -- all-time best wave reached (permanent)
}

local Constants = require(script.Parent.Constants)

local PlotTypes = {}

function PlotTypes.defaultSlotName(index: number): string
	return "Present " .. tostring(index)
end

function PlotTypes.defaultPlotSaves(): PlotSaves
	local slots: { PlotSaveSlot } = {}
	for i = 1, Constants.PLOT_SAVE_SLOT_COUNT do
		table.insert(slots, {
			name = PlotTypes.defaultSlotName(i),
			-- Slot 1 is the live default preset from the start.
			saved = i == 1,
			layout = {},
		})
	end
	return {
		activeIndex = 1,
		slots = slots,
	}
end

function PlotTypes.defaultProfile(): PlayerProfile
	return {
		version = Constants.PROFILE_VERSION,
		currencies = {
			sandDollars = 0,
			gold = 0,
		},
		inventory = {
			BrainCoral = Constants.STARTING_BRAIN_CORAL_SEEDS,
		},
		skillTree = {},
		layout = {},
		plotSaves = PlotTypes.defaultPlotSaves(),
		highestWave = 0,
	}
end

return PlotTypes
