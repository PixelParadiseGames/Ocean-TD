-- Shared type aliases (documentation for Luau; runtime is plain tables).

export type PlotId = string -- "Plot1" .. "Plot6"

export type PlotBoundsPayload = {
	plotId: PlotId,
	cframe: CFrame,
	size: Vector3,
	spawnCFrame: CFrame?,
}

export type LayoutObject = {
	id: string,
	lx: number,
	ly: number,
	lz: number,
}

export type PlayerProfile = {
	version: number,
	currencies: {
		sandDollars: number,
		gold: number,
	},
	inventory: { [string]: any },
	skillTree: { [string]: any },
	layout: { LayoutObject },
}

local Constants = require(script.Parent.Constants)

local PlotTypes = {}

function PlotTypes.defaultProfile(): PlayerProfile
	return {
		version = Constants.PROFILE_VERSION,
		currencies = {
			sandDollars = 0,
			gold = 0,
		},
		inventory = {},
		skillTree = {},
		layout = {},
	}
end

return PlotTypes
