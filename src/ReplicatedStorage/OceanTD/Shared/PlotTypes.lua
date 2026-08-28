-- Shared type aliases (documentation for Luau; runtime is plain tables).

export type PlotId = string -- "Plot1" .. "Plot6"

export type PlotBoundsPayload = {
	plotId: PlotId,
	cframe: CFrame,
	size: Vector3,
	spawnCFrame: CFrame?,
	-- Plot1 / MasterTerrainBox pose (for remapping WaveRoute etc. onto other plots).
	plot1CFrame: CFrame?,
	-- RingMath pose (stable). Active `cframe` may be a Plot Size template offset.
	ringCFrame: CFrame?,
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
	-- Optional visual diameter (BrainCoral size bands). Missing → species default.
	diameter: number?,
	-- Max unlocked size band 1=S 2=M 3=L. Missing → inferred from diameter.
	sizeTier: number?,
	-- Current size band (may be smaller than sizeTier if player switched down).
	sizeClass: number?,
	-- PlotOutlineColors index 1–14 (coral paint). Missing → species random on place.
	colorIndex: number?,
	-- Optional exact paint (0–1). Missing → palette base for colorIndex.
	colorR: number?,
	colorG: number?,
	colorB: number?,
	-- Mesh species (Sponge, SeaGrass): which SmallN/MediumN/LargeN was rolled. Missing → random on hydrate.
	variantIndex: number?,
	-- Mesh species: random size jitter applied to template Size. Missing → 1 / re-roll.
	scaleMult: number?,
	-- SeaFan: independent width/height jitter (±15%) and yaw (radians, Y-up).
	scaleWidth: number?,
	scaleHeight: number?,
	facingYaw: number?, -- SeaFan: plot-local Y yaw (radians)
	-- SeaFan web paint (0–1). Stem uses colorR/G/B.
	webColorR: number?,
	webColorG: number?,
	webColorB: number?,
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

export type ProcessedReceipt = {
	amount: number,
	productId: number,
}

export type PlayerProfile = {
	version: number,
	currencies: {
		sandDollars: number,
		gold: number,
	},
	-- Robux $D grants keyed by Marketplace PurchaseId (idempotent ProcessReceipt).
	processedReceipts: { [string]: ProcessedReceipt },
	inventory: { [string]: any },
	skillTree: { [string]: any },
	layout: { LayoutObject }, -- mirror of active plot-save slot (compat + hydrate)
	plotSaves: PlotSaves,
	highestWave: number, -- all-time best wave reached (permanent)
	highestFishFed: number, -- all-time most fish fed in one run
	longestWaveSec: number, -- all-time longest run duration (seconds)
	plotOutlineColorIndex: number, -- 1–15 (15 = no stroke); see PlotOutlineColors
	skillStages: { [string]: number }, -- skillId → highest unlocked stage 1..8
	skillActiveStages: { [string]: number }, -- skillId → currently enabled stage (≤ unlocked)
}

local Constants = require(script.Parent.Constants)
local SkillStages = require(script.Parent.SkillStages)

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
		processedReceipts = {},
		inventory = {
			BrainCoral = Constants.STARTING_BRAIN_CORAL_SEEDS,
			Sponge = Constants.STARTING_SPONGE_SEEDS,
			SeaGrass = Constants.STARTING_SEA_GRASS_SEEDS,
			FireCoral = Constants.STARTING_FIRE_CORAL_SEEDS,
			Zoas = Constants.STARTING_ZOAS_SEEDS,
			SeaFan = Constants.STARTING_SEA_FAN_SEEDS,
		},
		skillTree = {},
		layout = {},
		plotSaves = PlotTypes.defaultPlotSaves(),
		highestWave = 0,
		highestFishFed = 0,
		longestWaveSec = 0,
		plotOutlineColorIndex = 2, -- teal
		skillStages = SkillStages.defaultMap(),
		skillActiveStages = SkillStages.defaultMap(),
	}
end

return PlotTypes
