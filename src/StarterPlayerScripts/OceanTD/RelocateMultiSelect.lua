--!strict
--[[
	Shift multi-select for RelocateController (chunked for Luau local-register limit).
]]

local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local oceanShared = ReplicatedStorage:WaitForChild("OceanTD"):WaitForChild("Shared")
local CoralVisual = require(oceanShared:WaitForChild("CoralVisual"))
local CoralSize = require(oceanShared:WaitForChild("CoralSize"))
local UiHaptics = require(oceanShared:WaitForChild("UiHaptics"))
local UiTheme = require(oceanShared:WaitForChild("UiTheme"))
local SpeciesCatalog = require(oceanShared:WaitForChild("SpeciesCatalog"))
local ItemCatalog = require(oceanShared:WaitForChild("ItemCatalog"))
local SelectRing = require(script.Parent:WaitForChild("SelectRing"))

local RelocateMultiSelect = {}

export type Look = { material: Enum.Material, color: Color3 }

export type Host = {
	getPrimary: () -> BasePart?,
	promotePrimary: (BasePart) -> (),
	isActive: () -> boolean,
	isBusy: () -> boolean,
	getRecyclePending: () -> boolean,
	getHasMoved: () -> boolean,
	getHasRotated: () -> boolean,
	beginCoral: (BasePart) -> (),
	cancelCoral: (boolean?) -> (),
	applySelectionSnapshot: (ids: { string }) -> boolean,
	clearHover: () -> (),
	restorePartLook: (BasePart?) -> (),
	findByPlaceId: (string) -> BasePart?,
	playerGui: PlayerGui,
	getSelectRing: () -> SelectRing.Handle,
	fireActiveChanged: (BasePart) -> (),
}

local host: Host? = nil
local parts: { BasePart } = {}
local set: { [BasePart]: boolean } = {}
local rings: { [BasePart]: SelectRing.Handle } = {}
local looks: { [BasePart]: Look } = {}
local paintSolid: { [BasePart]: boolean } = {}
local undoStack: { { string } } = {}
local MAX_SELECTION_UNDO = 32
local pendingClear = false
local pendingShift: BasePart? = nil
local pendingShiftScreen: Vector2? = nil

local summaryGui: ScreenGui? = nil
local summaryLabel: TextLabel? = nil

local function speciesDisplayName(speciesId: string?, itemId: string?): string
	if typeof(speciesId) == "string" then
		local def = SpeciesCatalog.get(speciesId)
		if def and typeof(def.displayName) == "string" and def.displayName ~= "" then
			return def.displayName
		end
	end
	if typeof(itemId) == "string" then
		local def = ItemCatalog.get(itemId)
		if def and typeof(def.displayName) == "string" and def.displayName ~= "" then
			return def.displayName
		end
		return itemId
	end
	if typeof(speciesId) == "string" then
		return speciesId
	end
	return "Coral"
end

type SpeciesSummary = {
	total: number,
	s: number,
	m: number,
	l: number,
}

local function sizeClassOf(part: BasePart): number
	local _d, class = CoralSize.readFromPart(part)
	return CoralSize.clampTier(class)
end

local function formatSpeciesLine(name: string, bucket: SpeciesSummary): string
	return string.format(
		"%d %s (S:%d M:%d L:%d)",
		bucket.total,
		name,
		bucket.s,
		bucket.m,
		bucket.l
	)
end

local function ensureSummaryGui()
	local h = host
	if not h then
		return
	end
	if summaryGui and summaryGui.Parent and summaryLabel and summaryLabel.Parent then
		return
	end
	local sg = Instance.new("ScreenGui")
	sg.Name = "OceanTD_MultiSelectSummary"
	sg.ResetOnSpawn = false
	sg.IgnoreGuiInset = true
	sg.DisplayOrder = 80
	sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	sg.Enabled = false
	sg.Parent = h.playerGui

	local lbl = Instance.new("TextLabel")
	lbl.Name = "Summary"
	lbl.BackgroundTransparency = 1
	lbl.AnchorPoint = Vector2.new(0, 0)
	lbl.Position = UDim2.fromOffset(18, 90)
	lbl.Size = UDim2.fromOffset(520, 280)
	lbl.Font = UiTheme.Font
	lbl.TextSize = 36
	lbl.TextColor3 = Color3.new(1, 1, 1)
	lbl.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	lbl.TextStrokeTransparency = 0.15
	lbl.TextXAlignment = Enum.TextXAlignment.Left
	lbl.TextYAlignment = Enum.TextYAlignment.Top
	lbl.TextWrapped = false
	lbl.RichText = false
	lbl.Text = ""
	lbl.Parent = sg

	summaryGui = sg
	summaryLabel = lbl
end

local function refreshSummary()
	ensureSummaryGui()
	local gui = summaryGui
	local lbl = summaryLabel
	if not gui or not lbl then
		return
	end
	if #parts <= 1 then
		gui.Enabled = false
		lbl.Text = ""
		return
	end
	local buckets: { [string]: SpeciesSummary } = {}
	local order: { string } = {}
	for _, p in ipairs(parts) do
		if not p.Parent then
			continue
		end
		local speciesId = p:GetAttribute("OceanTD_SpeciesId")
		local itemId = p:GetAttribute("OceanTD_ItemId")
		local name = speciesDisplayName(
			if typeof(speciesId) == "string" then speciesId else nil,
			if typeof(itemId) == "string" then itemId else nil
		)
		local bucket = buckets[name]
		if not bucket then
			bucket = { total = 0, s = 0, m = 0, l = 0 }
			buckets[name] = bucket
			table.insert(order, name)
		end
		bucket.total += 1
		local class = sizeClassOf(p)
		if class == CoralSize.MEDIUM then
			bucket.m += 1
		elseif class == CoralSize.LARGE then
			bucket.l += 1
		else
			bucket.s += 1
		end
	end
	if #order == 0 then
		gui.Enabled = false
		lbl.Text = ""
		return
	end
	table.sort(order)
	local lines: { string } = {}
	for _, name in ipairs(order) do
		local bucket = buckets[name]
		if bucket then
			table.insert(lines, formatSpeciesLine(name, bucket))
		end
	end
	lbl.Text = table.concat(lines, "\n")
	gui.Enabled = true
end

function RelocateMultiSelect.mount(h: Host)
	host = h
end

function RelocateMultiSelect.refreshSummary()
	refreshSummary()
end

function RelocateMultiSelect.isShiftHeld(): boolean
	return UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
		or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
end

function RelocateMultiSelect.getLook(p: BasePart): Look?
	return looks[p]
end

function RelocateMultiSelect.noteLook(p: BasePart)
	local h = host
	if not h then
		return
	end
	if not set[p] and p ~= h.getPrimary() then
		return
	end
	local restMat, restColor = CoralVisual.readRestLook(p)
	looks[p] = { material = restMat, color = restColor }
end

function RelocateMultiSelect.setPaintSolid(p: BasePart, on: boolean)
	if on then
		paintSolid[p] = true
	else
		paintSolid[p] = nil
	end
end

function RelocateMultiSelect.isPaintSolid(p: BasePart): boolean
	return paintSolid[p] == true
end

function RelocateMultiSelect.clearPendingInput()
	pendingClear = false
	pendingShift = nil
	pendingShiftScreen = nil
end

function RelocateMultiSelect.setPendingClear(on: boolean)
	pendingClear = on
end

function RelocateMultiSelect.getPendingClear(): boolean
	return pendingClear
end

function RelocateMultiSelect.setPendingShift(target: BasePart?, screen: Vector2?)
	pendingShift = target
	pendingShiftScreen = screen
end

function RelocateMultiSelect.getPendingShift(): (BasePart?, Vector2?)
	return pendingShift, pendingShiftScreen
end

local function destroyRing(p: BasePart)
	local ring = rings[p]
	if ring then
		SelectRing.destroy(ring)
		rings[p] = nil
	end
end

function RelocateMultiSelect.clear(restoreLooks: boolean)
	local h = host
	if not h then
		table.clear(parts)
		table.clear(set)
		table.clear(rings)
		table.clear(looks)
		table.clear(paintSolid)
		refreshSummary()
		return
	end
	for _, p in ipairs(parts) do
		if restoreLooks then
			h.restorePartLook(p)
		end
		destroyRing(p)
	end
	table.clear(parts)
	table.clear(set)
	table.clear(rings)
	table.clear(looks)
	table.clear(paintSolid)
	refreshSummary()
end

local function snapshotSelectionIds(): { string }
	local h = host
	local seen: { [string]: boolean } = {}
	local ids: { string } = {}
	local function add(p: BasePart)
		if not p.Parent then
			return
		end
		local pid = p:GetAttribute("OceanTD_PlaceId")
		if typeof(pid) == "string" and pid ~= "" and not seen[pid] then
			seen[pid] = true
			table.insert(ids, pid)
		end
	end
	if h then
		local primary = h.getPrimary()
		if primary then
			add(primary)
		end
	end
	for _, p in ipairs(parts) do
		add(p)
	end
	return ids
end

local function cloneIds(ids: { string }): { string }
	local copy: { string } = {}
	for _, id in ipairs(ids) do
		table.insert(copy, id)
	end
	return copy
end

local function idsEqual(a: { string }, b: { string }): boolean
	if #a ~= #b then
		return false
	end
	local seen: { [string]: boolean } = {}
	for _, id in ipairs(a) do
		if seen[id] then
			return false
		end
		seen[id] = true
	end
	for _, id in ipairs(b) do
		if not seen[id] then
			return false
		end
	end
	return true
end

function RelocateMultiSelect.pushUndo()
	local ids = snapshotSelectionIds()
	if #ids == 0 then
		return
	end
	local top = undoStack[#undoStack]
	if top and idsEqual(top, ids) then
		return
	end
	table.insert(undoStack, cloneIds(ids))
	if #undoStack > MAX_SELECTION_UNDO then
		table.remove(undoStack, 1)
	end
end

function RelocateMultiSelect.ensureMembership(p: BasePart, restMat: Enum.Material?, restColor: Color3?)
	local h = host
	if not h or set[p] then
		return
	end
	set[p] = true
	table.insert(parts, p)
	paintSolid[p] = nil
	local mat = restMat
	local col = restColor
	if not mat or not col then
		local m, c = CoralVisual.readRestLook(p)
		mat = m
		col = c
	end
	looks[p] = { material = mat :: Enum.Material, color = col :: Color3 }
	if p ~= h.getPrimary() then
		local ring = SelectRing.new()
		SelectRing.ensure(ring, p, h.playerGui)
		rings[p] = ring
		p.Material = Enum.Material.Neon
	end
	refreshSummary()
end

function RelocateMultiSelect.rebindPart(oldPart: BasePart, newPart: BasePart)
	if oldPart == newPart then
		return
	end
	local h = host
	if not h then
		return
	end
	if not set[oldPart] and oldPart ~= h.getPrimary() then
		return
	end
	set[oldPart] = nil
	set[newPart] = true
	for i, q in ipairs(parts) do
		if q == oldPart then
			parts[i] = newPart
			break
		end
	end
	local ring = rings[oldPart]
	if ring then
		rings[oldPart] = nil
		rings[newPart] = ring
		if newPart.Parent then
			SelectRing.ensure(ring, newPart, h.playerGui)
		end
	end
	local look = looks[oldPart]
	if look then
		looks[oldPart] = nil
		looks[newPart] = look
	end
	if paintSolid[oldPart] then
		paintSolid[oldPart] = nil
		paintSolid[newPart] = true
	end
end

function RelocateMultiSelect.resyncFromParts(primary: BasePart?, found: { BasePart })
	local h = host
	if not h then
		return
	end
	local paintByPlaceId: { [string]: boolean } = {}
	for p, on in pairs(paintSolid) do
		if on then
			local pid = p:GetAttribute("OceanTD_PlaceId")
			if typeof(pid) == "string" and pid ~= "" then
				paintByPlaceId[pid] = true
			end
		end
	end
	for _, ring in pairs(rings) do
		SelectRing.destroy(ring)
	end
	table.clear(parts)
	table.clear(set)
	table.clear(rings)
	table.clear(looks)
	table.clear(paintSolid)
	for _, p in ipairs(found) do
		if not p.Parent then
			continue
		end
		set[p] = true
		table.insert(parts, p)
		local m, c = CoralVisual.readRestLook(p)
		looks[p] = { material = m, color = c }
		local pid = p:GetAttribute("OceanTD_PlaceId")
		if typeof(pid) == "string" and paintByPlaceId[pid] then
			paintSolid[p] = true
		end
		if p ~= primary then
			local ring = SelectRing.new()
			SelectRing.ensure(ring, p, h.playerGui)
			rings[p] = ring
			if paintSolid[p] then
				p.Material = m
				p.Color = c
			else
				p.Material = Enum.Material.Neon
			end
		end
	end
	refreshSummary()
end

function RelocateMultiSelect.removeMembership(p: BasePart)
	local h = host
	if not h or not set[p] then
		return
	end
	set[p] = nil
	for i, q in ipairs(parts) do
		if q == p then
			table.remove(parts, i)
			break
		end
	end
	h.restorePartLook(p)
	destroyRing(p)
	looks[p] = nil
	paintSolid[p] = nil
	refreshSummary()
end

function RelocateMultiSelect.pulse()
	local h = host
	if not h then
		return
	end
	local primary = h.getPrimary()
	for p, ring in pairs(rings) do
		if p.Parent then
			SelectRing.ensure(ring, p, h.playerGui)
			SelectRing.pulse(ring)
			local look = looks[p]
			if paintSolid[p] and look then
				p.Material = look.material
				p.Color = look.color
			elseif look and p ~= primary then
				p.Material = Enum.Material.Neon
				local pulse = 0.5 + 0.5 * math.sin(os.clock() * 9)
				p.Color = look.color:Lerp(Color3.new(1, 1, 1), 0.12 + 0.28 * pulse)
			end
		end
	end
end

function RelocateMultiSelect.getParts(primary: BasePart?): { BasePart }
	local out: { BasePart } = {}
	for _, p in ipairs(parts) do
		if p.Parent then
			table.insert(out, p)
		end
	end
	if #out == 0 and primary and primary.Parent then
		table.insert(out, primary)
	end
	return out
end

function RelocateMultiSelect.isMulti(): boolean
	return #parts > 1
end

function RelocateMultiSelect.isSelected(p: BasePart, primary: BasePart?): boolean
	return set[p] == true or p == primary
end

local function tryRemoveLastSelection(): boolean
	local h = host
	if not h or not h.isActive() then
		return false
	end
	if #parts <= 1 then
		return false
	end
	local primary = h.getPrimary()
	local last = parts[#parts]
	if not last or not last.Parent then
		return false
	end
	if last == primary then
		RelocateMultiSelect.removeMembership(primary)
		local nextPart = parts[1]
		if nextPart then
			h.promotePrimary(nextPart)
			return true
		end
		return false
	end
	RelocateMultiSelect.removeMembership(last)
	return true
end

function RelocateMultiSelect.tryRestoreUndo(): boolean
	local h = host
	if not h then
		return false
	end
	if #undoStack == 0 then
		return tryRemoveLastSelection()
	end
	local ids = table.remove(undoStack)
	if typeof(ids) ~= "table" or #ids == 0 then
		return false
	end
	return h.applySelectionSnapshot(ids)
end

function RelocateMultiSelect.stripSecondaryRing(p: BasePart)
	destroyRing(p)
end

function RelocateMultiSelect.toggle(target: BasePart)
	local h = host
	if not h or not target.Parent then
		return
	end
	if h.isBusy() or h.getRecyclePending() or h.getHasMoved() or h.getHasRotated() then
		return
	end
	if not h.isActive() then
		h.beginCoral(target)
		return
	end
	local primary = h.getPrimary()
	if set[target] or target == primary then
		if #parts <= 1 then
			h.cancelCoral(true)
			return
		end
		RelocateMultiSelect.pushUndo()
		RelocateMultiSelect.removeMembership(target)
		if target == primary then
			local nextPart = parts[1]
			if nextPart then
				h.promotePrimary(nextPart)
			else
				h.cancelCoral(true)
			end
		end
		return
	end
	h.clearHover()
	RelocateMultiSelect.pushUndo()
	CoralVisual.applyRestLook(target)
	local m, c = CoralVisual.readRestLook(target)
	RelocateMultiSelect.ensureMembership(target, m, c)
	UiHaptics.pulseShort()
end

return RelocateMultiSelect
