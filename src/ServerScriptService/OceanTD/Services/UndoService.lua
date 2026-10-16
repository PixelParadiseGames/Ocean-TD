--!strict
--[[
	Session-only undo stack for build ops (place / move / recycle / clearPlot / color / shuffle / addMax).
	Max 20 steps (hue browsing). At most 3 shuffle and 3 addMax compounds kept (scale-safe).
	Cleared on leave — never persisted.
]]

local UndoService = {}

export type ClearPlotEntry = {
	placeId: string,
	itemId: string,
	worldPos: Vector3,
}

export type ShuffleMoveEntry = {
	placeId: string,
	itemId: string,
	fromWorldPos: Vector3,
	toWorldPos: Vector3,
	fromFacingYaw: number?,
	toFacingYaw: number?,
}

export type AddMaxEntry = {
	placeId: string,
	itemId: string,
	worldPos: Vector3,
	seedHue: number?,
}

export type UndoStep = {
	kind: string, -- "place" | "move" | "recycle" | "clearPlot" | "color" | "shuffle" | "addMax"
	placeId: string,
	itemId: string,
	worldPos: Vector3?, -- place / recycle position
	fromWorldPos: Vector3?, -- move origin
	toWorldPos: Vector3?, -- move destination
	entries: { ClearPlotEntry | AddMaxEntry }?, -- clearPlot / addMax compound
	shuffleMoves: { ShuffleMoveEntry }?, -- auto-plant shuffle compound
	seedHue: number?, -- hue stack debited / credited
	fromColorIndex: number?, -- color undo (nil = was default / unpainted)
	toColorIndex: number?,
	-- Exact shade before the paint (so dice reshades + hue swaps restore faithfully).
	fromColorR: number?,
	fromColorG: number?,
	fromColorB: number?,
	fromWebColorIndex: number?,
	fromWebColorR: number?,
	fromWebColorG: number?,
	fromWebColorB: number?,
}

local MAX_STEPS = 20
-- Cap nested move payloads: 3 shuffles × hundreds of corals is fine per player.
local MAX_SHUFFLE_STEPS = 3
local MAX_ADD_MAX_STEPS = 3
local stacks: { [Player]: { UndoStep } } = {}

local function log(...: any)
	print("[UNDO]", ...)
end

local function getStack(player: Player): { UndoStep }
	local s = stacks[player]
	if not s then
		s = {}
		stacks[player] = s
	end
	return s
end

local function pruneOldByKind(s: { UndoStep }, kind: string, maxKeep: number)
	local idxs: { number } = {}
	for i, st in ipairs(s) do
		if st.kind == kind then
			table.insert(idxs, i)
		end
	end
	local excess = #idxs - maxKeep
	if excess <= 0 then
		return
	end
	for k = excess, 1, -1 do
		table.remove(s, idxs[k])
	end
end

function UndoService.push(player: Player, step: UndoStep)
	if typeof(step.kind) ~= "string" then
		return
	end
	if step.kind == "clearPlot" or step.kind == "addMax" then
		if typeof(step.entries) ~= "table" or #step.entries == 0 then
			return
		end
	elseif step.kind == "shuffle" then
		if typeof(step.shuffleMoves) ~= "table" or #step.shuffleMoves == 0 then
			return
		end
	elseif typeof(step.itemId) ~= "string" then
		return
	end
	local s = getStack(player)
	table.insert(s, step)
	if step.kind == "shuffle" then
		pruneOldByKind(s, "shuffle", MAX_SHUFFLE_STEPS)
	elseif step.kind == "addMax" then
		pruneOldByKind(s, "addMax", MAX_ADD_MAX_STEPS)
	end
	while #s > MAX_STEPS do
		table.remove(s, 1)
	end
	log("Push", step.kind, player.Name, "depth=", #s)
end

function UndoService.pop(player: Player): UndoStep?
	local s = stacks[player]
	if not s or #s == 0 then
		return nil
	end
	local step = table.remove(s)
	log("Pop", step.kind, player.Name, "depth=", #s)
	return step
end

function UndoService.count(player: Player): number
	local s = stacks[player]
	return if s then #s else 0
end

function UndoService.clear(player: Player)
	stacks[player] = nil
	log("Clear", player.Name)
end

function UndoService.maxSteps(): number
	return MAX_STEPS
end

function UndoService.maxShuffleSteps(): number
	return MAX_SHUFFLE_STEPS
end

return UndoService
