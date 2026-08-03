--!strict
--[[
	Session-only undo stack for build ops (place / move / recycle / clearPlot).
	Max 10 steps. Cleared on leave — never persisted.
]]

local UndoService = {}

export type ClearPlotEntry = {
	placeId: string,
	itemId: string,
	worldPos: Vector3,
}

export type UndoStep = {
	kind: string, -- "place" | "move" | "recycle" | "clearPlot"
	placeId: string,
	itemId: string,
	worldPos: Vector3?, -- place / recycle position
	fromWorldPos: Vector3?, -- move origin
	toWorldPos: Vector3?, -- move destination
	entries: { ClearPlotEntry }?, -- clearPlot compound
}

local MAX_STEPS = 10
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

function UndoService.push(player: Player, step: UndoStep)
	if typeof(step.kind) ~= "string" then
		return
	end
	if step.kind == "clearPlot" then
		if typeof(step.entries) ~= "table" or #step.entries == 0 then
			return
		end
	elseif typeof(step.itemId) ~= "string" then
		return
	end
	local s = getStack(player)
	table.insert(s, step)
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

return UndoService
