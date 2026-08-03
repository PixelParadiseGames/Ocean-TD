--!strict
--[[
	Slot1 Save Plots UI — slides with backpack like Slot2/3.
	2x2 preset grid; SAVE / LOAD|NEW; overwrite confirm; L3 / V (no touch help).
]]

local GuiService = game:GetService("GuiService")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local UiCircles = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiCircles"))
local UiTheme = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiTheme"))
local ItemCatalog = require(oceanRoot:WaitForChild("Shared"):WaitForChild("ItemCatalog"))
local Remotes = require(oceanRoot:WaitForChild("Remotes"))

local InventoryState = require(script.Parent:WaitForChild("InventoryState"))
local PlacementController = require(script.Parent:WaitForChild("PlacementController"))
local RelocateController = require(script.Parent:WaitForChild("RelocateController"))
local ClientPlot = require(script.Parent:WaitForChild("ClientPlot"))

local SavePlotSlot = {}

local SLIDE_PX = 88
local SLIDE_IN = TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local SLIDE_OUT = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local SAVE_BLUE = Color3.fromRGB(0, 115, 237) -- #0073ed
local SAVE_RED = Color3.fromRGB(200, 45, 55)
local CONFIRM_GREEN = Color3.fromRGB(40, 180, 80)
local LOAD_ORANGE = Color3.fromRGB(230, 120, 40)
local SAVE_ICON = "rbxassetid://135557862832703"
local PANEL_W = 600
local PANEL_H = 440
local BTN_TEXT = Color3.new(1, 1, 1)

export type Deps = {
	mainHUD: ScreenGui,
	playerGui: PlayerGui,
	ensureButton: (GuiObject) -> GuiButton,
	passthroughDecor: (GuiObject, GuiButton) -> (),
	ensureCircle: (GuiObject) -> GuiObject,
	ensureStroke: (GuiObject, string, Color3, number) -> UIStroke,
	getShortcutMode: () -> string,
	getIdlePeriod: () -> number,
	onClosedWithGamepad: (() -> ())?,
	onOpenedWithGamepad: (() -> ())?,
	log: (...any) -> (),
}

type SlotCard = {
	root: Frame,
	nameBox: TextBox,
	saveBtn: TextButton,
	loadBtn: TextButton,
	list: ScrollingFrame,
	border: UIStroke,
	index: number,
}

local deps: Deps
local slot1: GuiObject? = nil
local slot1Button: GuiButton? = nil
local slot1Circle: GuiObject? = nil
local slot1Stroke: UIStroke? = nil
local slot1SaveLabel: TextLabel? = nil
local slot1IdleConn: RBXScriptConnection? = nil
local slot1OriginalImage = ""
local slot1OriginalBg = Color3.fromRGB(20, 30, 45)
local slot1OriginalBgTrans = 0.15
local slot1HomePos: UDim2? = nil
local helpSlot1: GuiObject? = nil
local helpSlot1Letter: TextLabel? = nil
local helpSlot1HomePos: UDim2? = nil
local helpSlot1Hit: GuiButton? = nil
local slot1SlideToken = 0

local uiOpen = false
local overwriteOpen = false
local busy = false
local saveGui: ScreenGui? = nil
local saveDim: Frame? = nil
local savePanel: Frame? = nil
local saveCloseBtn: TextButton? = nil
local saveCards: { SlotCard } = {}
local activeIndex = 1
local pulseConn: RBXScriptConnection? = nil
local nameFlashConn: RBXScriptConnection? = nil
local closeLabelConn: RBXScriptConnection? = nil
local openedAt = 0
local prevGuiSelected: GuiObject? = nil
local overwriteGui: Frame? = nil
local overwriteList: ScrollingFrame? = nil
local overwriteConfirm: TextButton? = nil
local overwriteCancel: TextButton? = nil
local overwriteTargetIndex = 1
local pendingCounts: { { itemId: string, count: number, displayName: string, icon: string } } = {}

local function stopSlot1IdleCycle()
	if slot1IdleConn then
		slot1IdleConn:Disconnect()
		slot1IdleConn = nil
	end
	if slot1SaveLabel then
		slot1SaveLabel.Visible = false
	end
end

local function applySlot1IdleFrame(showSaveText: boolean)
	if not slot1Circle then
		return
	end
	if showSaveText then
		if slot1Circle:IsA("ImageLabel") or slot1Circle:IsA("ImageButton") then
			(slot1Circle :: any).Image = ""
		end
		slot1Circle.BackgroundColor3 = Color3.new(0, 0, 0)
		slot1Circle.BackgroundTransparency = 0
		if slot1SaveLabel then
			slot1SaveLabel.Text = "SAVE\nLOAD"
			slot1SaveLabel.TextColor3 = Color3.new(1, 1, 1)
			slot1SaveLabel.Visible = true
		end
	else
		if slot1Circle:IsA("ImageLabel") or slot1Circle:IsA("ImageButton") then
			(slot1Circle :: any).Image = if slot1OriginalImage ~= "" then slot1OriginalImage else SAVE_ICON
		end
		slot1Circle.BackgroundColor3 = slot1OriginalBg
		slot1Circle.BackgroundTransparency = slot1OriginalBgTrans
		if slot1SaveLabel then
			slot1SaveLabel.Visible = false
		end
	end
end

local function startSlot1IdleCycle()
	if not slot1 or not slot1Circle then
		return
	end
	stopSlot1IdleCycle()
	if slot1Stroke then
		slot1Stroke.Enabled = true
		slot1Stroke.Color = Color3.new(1, 1, 1)
		slot1Stroke.Thickness = 2
	end
	UiCircles.ensure(slot1Circle)
	local t0 = os.clock()
	applySlot1IdleFrame(false)
	slot1IdleConn = RunService.Heartbeat:Connect(function()
		if not InventoryState.isOpen() or not slot1 or not slot1.Visible then
			return
		end
		if uiOpen or busy or InventoryState.isSavePlotsBusy() then
			return
		end
		local showSaveText = (math.floor((os.clock() - t0) / deps.getIdlePeriod()) % 2) == 1
		applySlot1IdleFrame(showSaveText)
	end)
end

local function styleSlot1HelpBadge(): boolean
	if not helpSlot1 or not helpSlot1Letter then
		return false
	end
	local mode = deps.getShortcutMode()
	if mode == "touch" then
		return false
	end
	if helpSlot1:IsA("ImageLabel") or helpSlot1:IsA("ImageButton") then
		(helpSlot1 :: any).Image = ""
	end
	helpSlot1.BackgroundColor3 = SAVE_BLUE
	helpSlot1.BackgroundTransparency = 0
	helpSlot1.Active = true
	UiCircles.ensure(helpSlot1)
	helpSlot1Letter.Text = if mode == "gamepad" then "L3" else "V"
	helpSlot1Letter.TextColor3 = Color3.new(1, 1, 1)
	helpSlot1Letter.Visible = true
	if helpSlot1Hit then
		helpSlot1Hit.Active = true
		helpSlot1Hit.Visible = true
	end
	return true
end

local function slot1HiddenPos(home: UDim2): UDim2
	return home + UDim2.fromOffset(SLIDE_PX, 0)
end

local function isUsingGamepad(): boolean
	local t = UserInputService:GetLastInputType()
	return t == Enum.UserInputType.Gamepad1
		or t == Enum.UserInputType.Gamepad2
		or t == Enum.UserInputType.Gamepad3
		or t == Enum.UserInputType.Gamepad4
end

local function stopPulse()
	if pulseConn then
		pulseConn:Disconnect()
		pulseConn = nil
	end
	if nameFlashConn then
		nameFlashConn:Disconnect()
		nameFlashConn = nil
	end
	if closeLabelConn then
		closeLabelConn:Disconnect()
		closeLabelConn = nil
	end
end

local function startCloseLabelCycle()
	if closeLabelConn then
		closeLabelConn:Disconnect()
		closeLabelConn = nil
	end
	if not saveCloseBtn then
		return
	end
	local t0 = os.clock()
	local tip = if deps.getShortcutMode() == "gamepad" then "B" else "X"
	saveCloseBtn.Text = tip
	closeLabelConn = RunService.Heartbeat:Connect(function()
		if not uiOpen or not saveCloseBtn then
			return
		end
		local letter = if deps.getShortcutMode() == "gamepad" then "B" else "X"
		local showClose = (math.floor(os.clock() - t0) % 2) == 1
		saveCloseBtn.Text = if showClose then "CLOSE" else letter
	end)
end

local selectableLock: { [GuiObject]: boolean } = {}
local wireGamepadSelection: () -> ()

local function unlockForeignSelectables()
	for obj, was in pairs(selectableLock) do
		if obj.Parent then
			obj.Selectable = was
		end
	end
	table.clear(selectableLock)
end

local function lockSelectionToSaveGui()
	unlockForeignSelectables()
	if not saveGui or not deps then
		return
	end
	local pg = deps.playerGui
	for _, layer in ipairs(pg:GetChildren()) do
		if layer ~= saveGui then
			local function consider(obj: Instance)
				if obj:IsA("GuiObject") and obj.Selectable then
					selectableLock[obj] = true
					obj.Selectable = false
				end
			end
			consider(layer)
			for _, d in ipairs(layer:GetDescendants()) do
				consider(d)
			end
		end
	end
	wireGamepadSelection()
end

local function focusDefaultGamepadButton()
	for _, card in ipairs(saveCards) do
		if card.saveBtn.Visible then
			GuiService.SelectedObject = card.saveBtn
			return
		end
	end
	if saveCloseBtn then
		GuiService.SelectedObject = saveCloseBtn
	end
end

wireGamepadSelection = function()
	if not saveCloseBtn then
		return
	end
	-- Prefer navigating among visible OVERWRITE/LOAD; close is reachable upward.
	local firstSave: TextButton? = nil
	for _, card in ipairs(saveCards) do
		card.saveBtn.Selectable = card.saveBtn.Visible
		card.loadBtn.Selectable = card.loadBtn.Visible
		card.nameBox.Selectable = false
		if card.saveBtn.Visible and not firstSave then
			firstSave = card.saveBtn
		end
	end
	saveCloseBtn.Selectable = true
	if firstSave then
		saveCloseBtn.NextSelectionDown = firstSave
		firstSave.NextSelectionUp = saveCloseBtn
	end
	if overwriteConfirm and overwriteCancel then
		overwriteConfirm.Selectable = true
		overwriteCancel.Selectable = true
	end
end

local function startActiveChrome()
	stopPulse()
	local t0 = os.clock()
	pulseConn = RunService.Heartbeat:Connect(function()
		if not uiOpen then
			return
		end
		local wave = (math.sin((os.clock() - t0) * 4) + 1) * 0.5
		for _, card in ipairs(saveCards) do
			local isActive = card.index == activeIndex
			if isActive then
				card.border.Enabled = true
				card.border.Color = Color3.fromRGB(40, 220, 100):Lerp(Color3.fromRGB(20, 120, 60), wave)
				card.border.Thickness = 2 + wave * 2
				card.nameBox.TextColor3 = Color3.new(1, 1, 1):Lerp(Color3.fromRGB(60, 255, 120), wave)
			else
				card.border.Enabled = true
				card.border.Color = Color3.fromRGB(50, 70, 90)
				card.border.Thickness = 1
				card.nameBox.TextColor3 = Color3.new(1, 1, 1)
			end
		end
	end)
end

local function clearList(list: ScrollingFrame)
	for _, child in ipairs(list:GetChildren()) do
		if child:IsA("GuiObject") and child.Name ~= "UIListLayout" and child.Name ~= "UIPadding" then
			child:Destroy()
		end
	end
end

local function gatherOwnedPlotParts(): { BasePart }
	local parts: { BasePart } = {}
	local seen: { [BasePart]: boolean } = {}
	local function consider(inst: Instance)
		if not inst:IsA("BasePart") or seen[inst] then
			return
		end
		if typeof(inst:GetAttribute("OceanTD_GhostBaseR")) == "number" then
			return
		end
		local hasId = typeof(inst:GetAttribute("OceanTD_ItemId")) == "string"
			or typeof(inst:GetAttribute("OceanTD_SpeciesId")) == "string"
			or typeof(inst:GetAttribute("OceanTD_PlaceId")) == "string"
		local named = inst.Name ~= "" and ItemCatalog.get(inst.Name) ~= nil
		if not hasId and not named then
			return
		end
		seen[inst] = true
		table.insert(parts, inst)
	end

	local root = Workspace:FindFirstChild("OceanTD_Placed")
	if not root then
		return parts
	end
	local mirrored = ClientPlot.get()
	local folder = if mirrored then root:FindFirstChild(mirrored.plotId) else nil
	if folder then
		for _, inst in ipairs(folder:GetDescendants()) do
			consider(inst)
		end
	end
	-- Always scan whole placed folder as well (streaming / plotId mismatch).
	if #parts == 0 then
		for _, inst in ipairs(root:GetDescendants()) do
			consider(inst)
		end
	end
	return parts
end

local function resolveItemId(part: BasePart): string
	local idAttr = part:GetAttribute("OceanTD_ItemId")
	if typeof(idAttr) == "string" and idAttr ~= "" then
		return idAttr
	end
	local speciesAttr = part:GetAttribute("OceanTD_SpeciesId")
	if typeof(speciesAttr) == "string" and speciesAttr ~= "" then
		local bySpecies = ItemCatalog.get(speciesAttr)
		if bySpecies then
			return bySpecies.id
		end
		return speciesAttr
	end
	if part.Name ~= "" and ItemCatalog.get(part.Name) then
		return part.Name
	end
	return "BrainCoral"
end

local function countLivePlotSeeds(): { { itemId: string, count: number, displayName: string, icon: string } }
	local tallies: { [string]: number } = {}
	for _, p in ipairs(gatherOwnedPlotParts()) do
		local id = resolveItemId(p)
		tallies[id] = (tallies[id] or 0) + 1
	end
	local rows = {}
	for itemId, count in pairs(tallies) do
		local def = ItemCatalog.get(itemId)
		table.insert(rows, {
			itemId = itemId,
			count = count,
			displayName = if def then def.displayName else itemId,
			icon = if def then def.icon else "",
		})
	end
	table.sort(rows, function(a, b)
		if a.count == b.count then
			return a.displayName < b.displayName
		end
		return a.count > b.count
	end)
	return rows
end

local function populateCounts(list: ScrollingFrame, counts: any)
	clearList(list)
	if typeof(counts) ~= "table" or #counts == 0 then
		local empty = Instance.new("TextLabel")
		empty.Name = "EmptyRow"
		empty.BackgroundTransparency = 1
		empty.Size = UDim2.new(1, -4, 0, 28)
		empty.Font = UiTheme.Font
		empty.Text = "Empty plot"
		empty.TextColor3 = Color3.fromRGB(150, 165, 180)
		empty.TextSize = 14
		empty.ZIndex = 6
		empty.Parent = list
		return
	end
	for i, row in ipairs(counts) do
		if typeof(row) ~= "table" then
			continue
		end
		local itemId = tostring(row.itemId or "")
		local count = tonumber(row.count) or 0
		local displayName = tostring(row.displayName or itemId)
		local def = ItemCatalog.get(itemId)
		local iconImg = if def then def.icon else ""

		local line = Instance.new("Frame")
		line.Name = "Seed_" .. itemId
		line.BackgroundTransparency = 1
		line.Size = UDim2.new(1, -4, 0, 26)
		line.LayoutOrder = i
		line.ZIndex = 6
		line.Parent = list

		local icon = Instance.new("ImageLabel")
		icon.BackgroundTransparency = 1
		icon.Size = UDim2.fromOffset(22, 22)
		icon.Position = UDim2.fromOffset(2, 2)
		icon.Image = iconImg
		icon.ScaleType = Enum.ScaleType.Fit
		icon.ZIndex = 7
		icon.Parent = line

		local name = Instance.new("TextLabel")
		name.BackgroundTransparency = 1
		name.Position = UDim2.fromOffset(28, 0)
		name.Size = UDim2.new(1, -70, 1, 0)
		name.Font = UiTheme.Font
		name.Text = displayName
		name.TextColor3 = Color3.new(1, 1, 1)
		name.TextXAlignment = Enum.TextXAlignment.Left
		name.TextSize = 14
		name.TextTruncate = Enum.TextTruncate.AtEnd
		name.ZIndex = 7
		name.Parent = line

		local qty = Instance.new("TextLabel")
		qty.BackgroundTransparency = 1
		qty.AnchorPoint = Vector2.new(1, 0)
		qty.Position = UDim2.new(1, -4, 0, 0)
		qty.Size = UDim2.fromOffset(36, 26)
		qty.Font = UiTheme.Font
		qty.Text = "x" .. tostring(count)
		qty.TextColor3 = Color3.fromRGB(180, 255, 200)
		qty.TextSize = 14
		qty.ZIndex = 7
		qty.Parent = line
	end
end

local function applyState(state: any)
	if typeof(state) ~= "table" or not state.ok then
		return
	end
	activeIndex = math.clamp(tonumber(state.activeIndex) or 1, 1, 4)
	local slots = state.slots
	if typeof(slots) ~= "table" then
		return
	end
	local liveCounts = countLivePlotSeeds()
	-- Prefer server live grid tallies when available (authoritative).
	if typeof(state.liveCounts) == "table" and #state.liveCounts > 0 then
		liveCounts = {}
		for _, row in ipairs(state.liveCounts) do
			if typeof(row) == "table" then
				local itemId = tostring(row.itemId or "")
				local def = ItemCatalog.get(itemId)
				table.insert(liveCounts, {
					itemId = itemId,
					count = tonumber(row.count) or 0,
					displayName = tostring(row.displayName or itemId),
					icon = if def then def.icon else "",
				})
			end
		end
	elseif typeof(state.liveCounts) == "table" then
		liveCounts = {}
	end
	for _, card in ipairs(saveCards) do
		local info = slots[card.index]
		if typeof(info) ~= "table" then
			continue
		end
		if not card.nameBox:IsFocused() then
			card.nameBox.Text = tostring(info.name or ("Present " .. tostring(card.index)))
		end
		local saved = info.saved == true
		card.loadBtn.Text = if saved then "LOAD" else "NEW"
		card.loadBtn.BackgroundColor3 = if saved then LOAD_ORANGE else Color3.fromRGB(70, 140, 220)
		card.loadBtn.TextColor3 = BTN_TEXT
		card.saveBtn.TextColor3 = BTN_TEXT
		-- Active slot shows live plot; others show last saved layout.
		-- Active preset: no SAVE/LOAD (autosave already targets it).
		local isActive = card.index == activeIndex
		card.saveBtn.Visible = not isActive
		card.loadBtn.Visible = not isActive
		if isActive then
			card.list.Position = UDim2.fromOffset(8, 40)
			card.list.Size = UDim2.new(1, -16, 1, -48)
			populateCounts(card.list, liveCounts)
		else
			card.list.Position = UDim2.fromOffset(8, 80)
			card.list.Size = UDim2.new(1, -16, 1, -88)
			populateCounts(card.list, info.counts)
		end
	end
	wireGamepadSelection()
end

local function fetchState()
	local ok, result = pcall(function()
		return Remotes.getFunction("RequestGetPlotSaves"):InvokeServer()
	end)
	if ok and typeof(result) == "table" then
		applyState(result)
	else
		deps.log("GetPlotSaves failed")
	end
end

local function hideOverwrite()
	overwriteOpen = false
	if overwriteGui then
		overwriteGui.Visible = false
	end
	if isUsingGamepad() and saveCards[1] then
		GuiService.SelectedObject = saveCards[1].saveBtn
	end
end

local function populateOverwriteList(rows: { { itemId: string, count: number, displayName: string, icon: string } })
	if not overwriteList then
		return
	end
	clearList(overwriteList)
	if #rows == 0 then
		local empty = Instance.new("TextLabel")
		empty.Name = "EmptyRow"
		empty.BackgroundTransparency = 1
		empty.Size = UDim2.new(1, -8, 0, 36)
		empty.Font = UiTheme.Font
		empty.Text = "Empty plot (allowed)"
		empty.TextColor3 = Color3.fromRGB(180, 190, 200)
		empty.TextSize = 16
		empty.Parent = overwriteList
		return
	end
	for i, row in ipairs(rows) do
		local line = Instance.new("Frame")
		line.BackgroundColor3 = Color3.fromRGB(24, 36, 52)
		line.BackgroundTransparency = 0.25
		line.BorderSizePixel = 0
		line.Size = UDim2.new(1, -8, 0, 44)
		line.LayoutOrder = i
		line.ZIndex = 42
		line.Parent = overwriteList
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 8)
		corner.Parent = line

		local icon = Instance.new("ImageLabel")
		icon.BackgroundTransparency = 1
		icon.Size = UDim2.fromOffset(36, 36)
		icon.Position = UDim2.fromOffset(6, 4)
		icon.Image = row.icon
		icon.ScaleType = Enum.ScaleType.Fit
		icon.ZIndex = 43
		icon.Parent = line

		local name = Instance.new("TextLabel")
		name.BackgroundTransparency = 1
		name.Position = UDim2.fromOffset(50, 0)
		name.Size = UDim2.new(1, -120, 1, 0)
		name.Font = UiTheme.Font
		name.Text = row.displayName
		name.TextColor3 = Color3.new(1, 1, 1)
		name.TextXAlignment = Enum.TextXAlignment.Left
		name.TextSize = 18
		name.ZIndex = 43
		name.Parent = line

		local qty = Instance.new("TextLabel")
		qty.BackgroundTransparency = 1
		qty.AnchorPoint = Vector2.new(1, 0.5)
		qty.Position = UDim2.new(1, -12, 0.5, 0)
		qty.Size = UDim2.fromOffset(60, 30)
		qty.Font = UiTheme.Font
		qty.Text = "x" .. tostring(row.count)
		qty.TextColor3 = Color3.fromRGB(180, 255, 200)
		qty.TextSize = 18
		qty.ZIndex = 43
		qty.Parent = line
	end
end

local ensureOverwriteUi: () -> ()

local function doSave(slotIndex: number)
	if busy then
		return
	end
	busy = true
	InventoryState.setSavePlotsBusy(true)
	local ok, result = pcall(function()
		return Remotes.getFunction("RequestSavePlotSlot"):InvokeServer(slotIndex)
	end)
	busy = false
	InventoryState.setSavePlotsBusy(false)
	if ok and typeof(result) == "table" and result.ok then
		applyState(result)
		deps.log("Saved plot slot", slotIndex)
	else
		local code = if ok and typeof(result) == "table" then result.errorCode else "Fail"
		deps.log("Save plot rejected", code)
	end
end

local function beginOverwriteConfirm(slotIndex: number)
	overwriteTargetIndex = slotIndex
	ensureOverwriteUi()
	-- Prefer live grid from server; fall back to client part scan.
	local rows = countLivePlotSeeds()
	local ok, result = pcall(function()
		return Remotes.getFunction("RequestGetPlotSaves"):InvokeServer()
	end)
	if ok and typeof(result) == "table" and typeof(result.liveCounts) == "table" then
		if #result.liveCounts > 0 or #rows == 0 then
			rows = {}
			for _, row in ipairs(result.liveCounts) do
				if typeof(row) == "table" then
					local itemId = tostring(row.itemId or "")
					local def = ItemCatalog.get(itemId)
					table.insert(rows, {
						itemId = itemId,
						count = tonumber(row.count) or 0,
						displayName = tostring(row.displayName or itemId),
						icon = if def then def.icon else "",
					})
				end
			end
		end
	end
	pendingCounts = rows
	populateOverwriteList(pendingCounts)
	if overwriteGui then
		overwriteGui.Visible = true
	end
	overwriteOpen = true
	if isUsingGamepad() and overwriteConfirm then
		GuiService.SelectedObject = overwriteConfirm
	end
	deps.log("Overwrite preview rows=", #pendingCounts)
end

local function requestSave(slotIndex: number)
	local card = saveCards[slotIndex]
	if not card then
		return
	end
	-- Overwrite confirm when target already has a saved preset.
	local needsConfirm = card.loadBtn.Text == "LOAD"
	if needsConfirm then
		beginOverwriteConfirm(slotIndex)
		return
	end
	doSave(slotIndex)
end

local function doLoad(slotIndex: number)
	if busy then
		return
	end
	busy = true
	InventoryState.setSavePlotsBusy(true)
	local ok, result = pcall(function()
		return Remotes.getFunction("RequestLoadPlotSlot"):InvokeServer(slotIndex)
	end)
	busy = false
	InventoryState.setSavePlotsBusy(false)
	if ok and typeof(result) == "table" and result.ok then
		applyState(result)
		deps.log("Loaded plot slot", slotIndex)
	else
		local code = if ok and typeof(result) == "table" then result.errorCode else "Fail"
		deps.log("Load plot rejected", code)
	end
end

local function renameSlot(slotIndex: number, name: string)
	task.spawn(function()
		local ok, result = pcall(function()
			return Remotes.getFunction("RequestRenamePlotSave"):InvokeServer(slotIndex, name)
		end)
		if ok and typeof(result) == "table" and result.ok then
			applyState(result)
		end
	end)
end

ensureOverwriteUi = function()
	if overwriteGui then
		return
	end
	if not saveGui then
		return
	end
	-- Centered card over the dim (not stretched across the save panel).
	local wrap = Instance.new("Frame")
	wrap.Name = "OverwriteConfirm"
	wrap.AnchorPoint = Vector2.new(0.5, 0.5)
	wrap.Position = UDim2.fromScale(0.5, 0.5)
	wrap.Size = UDim2.fromOffset(400, 340)
	wrap.BackgroundColor3 = Color3.fromRGB(14, 22, 32)
	wrap.BorderSizePixel = 0
	wrap.Visible = false
	wrap.ZIndex = 40
	wrap.SelectionGroup = true
	wrap.Parent = saveGui
	overwriteGui = wrap
	local sizeConstraint = Instance.new("UISizeConstraint")
	sizeConstraint.MinSize = Vector2.new(280, 260)
	sizeConstraint.MaxSize = Vector2.new(460, 400)
	sizeConstraint.Parent = wrap
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 14)
	corner.Parent = wrap
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(90, 110, 140)
	stroke.Thickness = 2
	stroke.Parent = wrap

	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Position = UDim2.fromOffset(16, 14)
	title.Size = UDim2.new(1, -32, 0, 30)
	title.Font = UiTheme.Font
	title.Text = "Overwrite save?"
	title.TextColor3 = Color3.new(1, 1, 1)
	title.TextSize = 22
	title.ZIndex = 41
	title.Parent = wrap

	local sub = Instance.new("TextLabel")
	sub.BackgroundTransparency = 1
	sub.Position = UDim2.fromOffset(16, 46)
	sub.Size = UDim2.new(1, -32, 0, 22)
	sub.Font = UiTheme.Font
	sub.Text = "This save will store:"
	sub.TextColor3 = Color3.fromRGB(180, 195, 210)
	sub.TextSize = 15
	sub.TextXAlignment = Enum.TextXAlignment.Left
	sub.ZIndex = 41
	sub.Parent = wrap

	local list = Instance.new("ScrollingFrame")
	list.Name = "SeedList"
	list.Position = UDim2.fromOffset(16, 76)
	list.Size = UDim2.new(1, -32, 1, -140)
	list.BackgroundTransparency = 1
	list.BorderSizePixel = 0
	list.ScrollBarThickness = 6
	list.CanvasSize = UDim2.new(0, 0, 0, 0)
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.ZIndex = 41
	list.Parent = wrap
	overwriteList = list
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 6)
	layout.Parent = list

	local btnRow = Instance.new("Frame")
	btnRow.Name = "Buttons"
	btnRow.AnchorPoint = Vector2.new(0.5, 1)
	btnRow.Position = UDim2.new(0.5, 0, 1, -16)
	btnRow.Size = UDim2.fromOffset(300, 44)
	btnRow.BackgroundTransparency = 1
	btnRow.ZIndex = 42
	btnRow.Parent = wrap

	local confirm = Instance.new("TextButton")
	confirm.Name = "Confirm"
	confirm.Position = UDim2.fromOffset(0, 0)
	confirm.Size = UDim2.new(0.5, -6, 1, 0)
	confirm.BackgroundColor3 = CONFIRM_GREEN
	confirm.Font = UiTheme.Font
	confirm.Text = "CONFIRM"
	confirm.TextColor3 = BTN_TEXT
	confirm.TextStrokeColor3 = Color3.fromRGB(12, 55, 25)
	confirm.TextStrokeTransparency = 0
	confirm.TextSize = 18
	confirm.AutoButtonColor = true
	confirm.ZIndex = 43
	confirm.Parent = btnRow
	overwriteConfirm = confirm
	local cc = Instance.new("UICorner")
	cc.CornerRadius = UDim.new(0, 10)
	cc.Parent = confirm

	local cancel = Instance.new("TextButton")
	cancel.Name = "Cancel"
	cancel.AnchorPoint = Vector2.new(1, 0)
	cancel.Position = UDim2.new(1, 0, 0, 0)
	cancel.Size = UDim2.new(0.5, -6, 1, 0)
	cancel.BackgroundColor3 = SAVE_RED
	cancel.Font = UiTheme.Font
	cancel.Text = "CANCEL"
	cancel.TextColor3 = BTN_TEXT
	cancel.TextStrokeColor3 = Color3.fromRGB(60, 15, 18)
	cancel.TextStrokeTransparency = 0
	cancel.TextSize = 18
	cancel.AutoButtonColor = true
	cancel.ZIndex = 43
	cancel.Parent = btnRow
	overwriteCancel = cancel
	local xc = Instance.new("UICorner")
	xc.CornerRadius = UDim.new(0, 10)
	xc.Parent = cancel

	confirm.NextSelectionRight = cancel
	cancel.NextSelectionLeft = confirm

	confirm.Activated:Connect(function()
		local idx = overwriteTargetIndex
		hideOverwrite()
		doSave(idx)
	end)
	cancel.Activated:Connect(function()
		hideOverwrite()
	end)
end

local function makeSlotCard(parent: Frame, index: number, order: number): SlotCard
	local root = Instance.new("Frame")
	root.Name = "SlotCard_" .. tostring(index)
	root.BackgroundColor3 = Color3.fromRGB(22, 34, 48)
	root.BorderSizePixel = 0
	root.Size = UDim2.new(0.5, -10, 0.5, -10)
	root.LayoutOrder = order
	root.ZIndex = 5
	root.Parent = parent
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 12)
	corner.Parent = root
	local border = Instance.new("UIStroke")
	border.Color = Color3.fromRGB(50, 70, 90)
	border.Thickness = 1
	border.Parent = root

	local nameBox = Instance.new("TextBox")
	nameBox.Name = "Name"
	nameBox.BackgroundTransparency = 1
	nameBox.Position = UDim2.fromOffset(10, 6)
	nameBox.Size = UDim2.new(1, -20, 0, 28)
	nameBox.Font = UiTheme.Font
	nameBox.Text = "Present " .. tostring(index)
	nameBox.PlaceholderText = "Present " .. tostring(index)
	nameBox.TextColor3 = Color3.new(1, 1, 1)
	nameBox.PlaceholderColor3 = Color3.fromRGB(140, 150, 160)
	nameBox.TextSize = 18
	nameBox.TextXAlignment = Enum.TextXAlignment.Center
	nameBox.ClearTextOnFocus = false
	nameBox.Selectable = false
	nameBox.ZIndex = 6
	nameBox.Parent = root

	local saveBtn = Instance.new("TextButton")
	saveBtn.Name = "Save"
	saveBtn.Position = UDim2.fromOffset(10, 38)
	saveBtn.Size = UDim2.new(0.5, -14, 0, 34)
	saveBtn.BackgroundColor3 = SAVE_RED
	saveBtn.Font = UiTheme.Font
	saveBtn.Text = "OVERWRITE"
	saveBtn.TextColor3 = BTN_TEXT
	saveBtn.TextSize = 16
	saveBtn.AutoButtonColor = true
	saveBtn.ZIndex = 6
	saveBtn.Selectable = true
	saveBtn.Parent = root
	local sc = Instance.new("UICorner")
	sc.CornerRadius = UDim.new(0, 8)
	sc.Parent = saveBtn

	local loadBtn = Instance.new("TextButton")
	loadBtn.Name = "Load"
	loadBtn.AnchorPoint = Vector2.new(1, 0)
	loadBtn.Position = UDim2.new(1, -10, 0, 38)
	loadBtn.Size = UDim2.new(0.5, -14, 0, 34)
	loadBtn.BackgroundColor3 = LOAD_ORANGE
	loadBtn.Font = UiTheme.Font
	loadBtn.Text = "NEW"
	loadBtn.TextColor3 = BTN_TEXT
	loadBtn.TextSize = 16
	loadBtn.AutoButtonColor = true
	loadBtn.ZIndex = 6
	loadBtn.Selectable = true
	loadBtn.Parent = root
	local lc = Instance.new("UICorner")
	lc.CornerRadius = UDim.new(0, 8)
	lc.Parent = loadBtn

	saveBtn.NextSelectionRight = loadBtn
	loadBtn.NextSelectionLeft = saveBtn

	local list = Instance.new("ScrollingFrame")
	list.Name = "Counts"
	list.Position = UDim2.fromOffset(8, 80)
	list.Size = UDim2.new(1, -16, 1, -88)
	list.BackgroundTransparency = 1
	list.BorderSizePixel = 0
	list.ScrollBarThickness = 4
	list.CanvasSize = UDim2.new(0, 0, 0, 0)
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.ZIndex = 6
	list.Parent = root
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 2)
	layout.Parent = list

	local card: SlotCard = {
		root = root,
		nameBox = nameBox,
		saveBtn = saveBtn,
		loadBtn = loadBtn,
		list = list,
		border = border,
		index = index,
	}

	saveBtn.Activated:Connect(function()
		requestSave(index)
	end)
	loadBtn.Activated:Connect(function()
		doLoad(index)
	end)
	nameBox.FocusLost:Connect(function(enter)
		local _ = enter
		renameSlot(index, nameBox.Text)
	end)

	return card
end

local function ensureSaveUi()
	if saveGui and savePanel and #saveCards == 4 then
		return
	end
	local g = Instance.new("ScreenGui")
	g.Name = "OceanTD_SavePlots"
	g.ResetOnSpawn = false
	g.IgnoreGuiInset = true
	g.DisplayOrder = 12060
	g.Enabled = false
	g.Parent = deps.playerGui
	saveGui = g

	local dim = Instance.new("Frame")
	dim.Name = "Dim"
	dim.BackgroundColor3 = Color3.new(0, 0, 0)
	dim.BackgroundTransparency = 0.45
	dim.BorderSizePixel = 0
	dim.Size = UDim2.fromScale(1, 1)
	dim.Active = true
	dim.ZIndex = 1
	dim.Parent = g
	saveDim = dim
	dim.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			if os.clock() - openedAt < 0.35 then
				return
			end
			if overwriteOpen then
				hideOverwrite()
				return
			end
			SavePlotSlot.hide()
		end
	end)

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromOffset(PANEL_W, PANEL_H)
	panel.BackgroundColor3 = Color3.fromRGB(18, 28, 40)
	panel.BorderSizePixel = 0
	panel.ZIndex = 2
	panel.Active = true
	panel.SelectionGroup = true
	panel.Parent = g
	savePanel = panel
	local sizeConstraint = Instance.new("UISizeConstraint")
	sizeConstraint.MinSize = Vector2.new(360, 300)
	sizeConstraint.MaxSize = Vector2.new(640, 480)
	sizeConstraint.Parent = panel
	panel.ClipsDescendants = true
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 14)
	corner.Parent = panel
	local stroke = Instance.new("UIStroke")
	stroke.Color = SAVE_BLUE
	stroke.Thickness = 2
	stroke.Parent = panel

	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Position = UDim2.fromOffset(16, 12)
	title.Size = UDim2.new(1, -96, 0, 28)
	title.Font = UiTheme.Font
	title.Text = "Save Plots"
	title.TextColor3 = Color3.new(1, 1, 1)
	title.TextSize = 24
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.ZIndex = 3
	title.Parent = panel

	local closeBtn = Instance.new("TextButton")
	closeBtn.Name = "Close"
	closeBtn.AnchorPoint = Vector2.new(1, 0)
	closeBtn.Position = UDim2.new(1, -10, 0, 8)
	closeBtn.Size = UDim2.fromOffset(78, 32)
	closeBtn.BackgroundColor3 = SAVE_RED
	closeBtn.Font = UiTheme.Font
	closeBtn.Text = "B"
	closeBtn.TextColor3 = BTN_TEXT
	closeBtn.TextSize = 16
	closeBtn.AutoButtonColor = true
	closeBtn.ZIndex = 4
	closeBtn.Selectable = true
	closeBtn.Parent = panel
	saveCloseBtn = closeBtn
	local closeCorner = Instance.new("UICorner")
	closeCorner.CornerRadius = UDim.new(0, 8)
	closeCorner.Parent = closeBtn
	closeBtn.Activated:Connect(function()
		SavePlotSlot.hide()
	end)

	local grid = Instance.new("Frame")
	grid.Name = "Grid"
	grid.Position = UDim2.fromOffset(16, 48)
	grid.Size = UDim2.new(1, -32, 1, -60)
	grid.BackgroundTransparency = 1
	grid.ZIndex = 3
	grid.Parent = panel
	local gridLayout = Instance.new("UIGridLayout")
	gridLayout.CellSize = UDim2.new(0.5, -8, 0.5, -8)
	gridLayout.CellPadding = UDim2.fromOffset(12, 12)
	gridLayout.SortOrder = Enum.SortOrder.LayoutOrder
	gridLayout.Parent = grid

	saveCards = {}
	for i = 1, 4 do
		local card = makeSlotCard(grid, i, i)
		-- UIGridLayout positions children; Size on card overridden by CellSize
		card.root.Size = UDim2.fromScale(1, 1)
		table.insert(saveCards, card)
	end

	-- Gamepad vertical links between rows
	saveCards[1].saveBtn.NextSelectionDown = saveCards[3].saveBtn
	saveCards[1].loadBtn.NextSelectionDown = saveCards[3].loadBtn
	saveCards[2].saveBtn.NextSelectionDown = saveCards[4].saveBtn
	saveCards[2].loadBtn.NextSelectionDown = saveCards[4].loadBtn
	saveCards[3].saveBtn.NextSelectionUp = saveCards[1].saveBtn
	saveCards[3].loadBtn.NextSelectionUp = saveCards[1].loadBtn
	saveCards[4].saveBtn.NextSelectionUp = saveCards[2].saveBtn
	saveCards[4].loadBtn.NextSelectionUp = saveCards[2].loadBtn
	saveCards[1].loadBtn.NextSelectionRight = saveCards[2].saveBtn
	saveCards[2].saveBtn.NextSelectionLeft = saveCards[1].loadBtn
	saveCards[3].loadBtn.NextSelectionRight = saveCards[4].saveBtn
	saveCards[4].saveBtn.NextSelectionLeft = saveCards[3].loadBtn

	ensureOverwriteUi()
end

local function fittedPanelSize(vp: Vector2): Vector2
	local maxW = math.min(PANEL_W, math.floor(vp.X * 0.88))
	local maxH = math.min(PANEL_H, math.floor(vp.Y * 0.82))
	return Vector2.new(math.max(360, maxW), math.max(300, maxH))
end

local function scaleFromSlotButton()
	if not savePanel or not slot1 then
		return
	end
	local btnPos = slot1.AbsolutePosition
	local btnSize = slot1.AbsoluteSize
	local Workspace = game:GetService("Workspace")
	local cam = Workspace.CurrentCamera
	local vp = if cam then cam.ViewportSize else Vector2.new(1920, 1080)
	local target = fittedPanelSize(vp)
	local startX = (btnPos.X + btnSize.X * 0.5) / vp.X
	local startY = (btnPos.Y + btnSize.Y * 0.5) / vp.Y
	savePanel.Position = UDim2.fromScale(startX, startY)
	savePanel.Size = UDim2.fromOffset(40, 40)
	TweenService:Create(savePanel, TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(target.X, target.Y),
	}):Play()
end

local SAVE_SCALE_OUT = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local saveCloseToken = 0

function SavePlotSlot.isOpen(): boolean
	return uiOpen
end

function SavePlotSlot.hide()
	if not uiOpen then
		return
	end
	hideOverwrite()
	uiOpen = false
	InventoryState.setSavePlotsOpen(false)
	stopPulse()
	unlockForeignSelectables()
	if prevGuiSelected ~= nil or isUsingGamepad() then
		GuiService.SelectedObject = nil
		prevGuiSelected = nil
		if deps.onClosedWithGamepad and isUsingGamepad() then
			deps.onClosedWithGamepad()
		end
	end
	if InventoryState.isOpen() and slot1 and slot1.Visible then
		startSlot1IdleCycle()
	end

	saveCloseToken += 1
	local token = saveCloseToken
	if savePanel and slot1 and saveGui and saveGui.Enabled then
		if saveDim then
			saveDim.Visible = false
		end
		local btnPos = slot1.AbsolutePosition
		local btnSize = slot1.AbsoluteSize
		local Workspace = game:GetService("Workspace")
		local cam = Workspace.CurrentCamera
		local vp = if cam then cam.ViewportSize else Vector2.new(1920, 1080)
		local endX = (btnPos.X + btnSize.X * 0.5) / vp.X
		local endY = (btnPos.Y + btnSize.Y * 0.5) / vp.Y
		local tw = TweenService:Create(savePanel, SAVE_SCALE_OUT, {
			Position = UDim2.fromScale(endX, endY),
			Size = UDim2.fromOffset(40, 40),
		})
		tw:Play()
		tw.Completed:Connect(function()
			if token ~= saveCloseToken then
				return
			end
			if saveGui then
				saveGui.Enabled = false
			end
			if saveDim then
				saveDim.Visible = true
			end
		end)
	elseif saveGui then
		saveGui.Enabled = false
	end
	deps.log("Save plots closed")
end

function SavePlotSlot.toggle()
	if uiOpen then
		SavePlotSlot.hide()
		return
	end
	SavePlotSlot.open()
end

function SavePlotSlot.open()
	if not InventoryState.isOpen() then
		return
	end
	if InventoryState.isClearPlotBlocking() then
		return
	end
	if PlacementController.isActive() or RelocateController.isActive() then
		return
	end
	if uiOpen then
		return
	end
	ensureSaveUi()
	fetchState()
	uiOpen = true
	InventoryState.setSavePlotsOpen(true)
	openedAt = os.clock()
	if saveGui then
		saveGui.Enabled = true
	end
	scaleFromSlotButton()
	startActiveChrome()
	startCloseLabelCycle()
	wireGamepadSelection()
	lockSelectionToSaveGui()
	task.defer(function()
		if uiOpen then
			lockSelectionToSaveGui()
			if isUsingGamepad() then
				focusDefaultGamepadButton()
			end
		end
	end)
	stopSlot1IdleCycle()
	if slot1Circle then
		if slot1Circle:IsA("ImageLabel") or slot1Circle:IsA("ImageButton") then
			(slot1Circle :: any).Image = if slot1OriginalImage ~= "" then slot1OriginalImage else SAVE_ICON
		end
	end
	if isUsingGamepad() then
		prevGuiSelected = GuiService.SelectedObject
		if deps.onOpenedWithGamepad then
			deps.onOpenedWithGamepad()
		end
		focusDefaultGamepadButton()
	end
	deps.log("Save plots opened")
end

function SavePlotSlot.refreshHelpBadge()
	if not helpSlot1 or not helpSlot1.Visible then
		return
	end
	if not styleSlot1HelpBadge() then
		helpSlot1.Visible = false
	end
end

function SavePlotSlot.handleConfirmInput(): boolean
	if not uiOpen then
		return false
	end
	if overwriteOpen then
		if overwriteConfirm then
			local idx = overwriteTargetIndex
			hideOverwrite()
			doSave(idx)
		end
		return true
	end
	return false
end

function SavePlotSlot.handleCancelInput(): boolean
	if not uiOpen then
		return false
	end
	if overwriteOpen then
		hideOverwrite()
		return true
	end
	SavePlotSlot.hide()
	return true
end

function SavePlotSlot.playReveal()
	if not slot1 or not slot1HomePos then
		return
	end
	slot1SlideToken += 1
	local token = slot1SlideToken
	local home = slot1HomePos
	local hidden = slot1HiddenPos(home)

	slot1.Position = hidden
	slot1.Visible = true
	if slot1Stroke then
		slot1Stroke.Enabled = true
		slot1Stroke.Color = Color3.new(1, 1, 1)
		slot1Stroke.Thickness = 2
	end
	startSlot1IdleCycle()

	local showHelp = styleSlot1HelpBadge()
	if showHelp and helpSlot1 and helpSlot1HomePos then
		helpSlot1.Position = slot1HiddenPos(helpSlot1HomePos)
		helpSlot1.Visible = true
		TweenService:Create(helpSlot1, SLIDE_IN, { Position = helpSlot1HomePos }):Play()
	elseif helpSlot1 then
		helpSlot1.Visible = false
	end

	local tw = TweenService:Create(slot1, SLIDE_IN, { Position = home })
	tw:Play()
	tw.Completed:Wait()
	if token ~= slot1SlideToken then
		return
	end
	slot1.Position = home
	if showHelp and helpSlot1 and helpSlot1HomePos then
		helpSlot1.Position = helpSlot1HomePos
	end
end

function SavePlotSlot.playHide()
	if not slot1 or not slot1HomePos then
		return
	end
	slot1SlideToken += 1
	local token = slot1SlideToken
	local home = slot1HomePos
	local hidden = slot1HiddenPos(home)

	SavePlotSlot.hide()
	stopSlot1IdleCycle()
	if not slot1.Visible then
		if helpSlot1 then
			helpSlot1.Visible = false
			if helpSlot1HomePos then
				helpSlot1.Position = helpSlot1HomePos
			end
		end
		slot1.Position = home
		if slot1Stroke then
			slot1Stroke.Enabled = false
		end
		return
	end

	slot1.Position = home
	local tw = TweenService:Create(slot1, SLIDE_OUT, { Position = hidden })
	tw:Play()
	if helpSlot1 and helpSlot1.Visible and helpSlot1HomePos then
		helpSlot1.Position = helpSlot1HomePos
		TweenService:Create(helpSlot1, SLIDE_OUT, { Position = slot1HiddenPos(helpSlot1HomePos) }):Play()
	end
	tw.Completed:Wait()
	if token ~= slot1SlideToken then
		return
	end
	slot1.Visible = false
	slot1.Position = home
	if slot1Stroke then
		slot1Stroke.Enabled = false
	end
	if helpSlot1 then
		helpSlot1.Visible = false
		if helpSlot1HomePos then
			helpSlot1.Position = helpSlot1HomePos
		end
	end
end

function SavePlotSlot.syncVisibility()
	if InventoryState.isOpen() then
		if slot1 and slot1HomePos then
			slot1.Position = slot1HomePos
			slot1.Visible = true
			startSlot1IdleCycle()
		end
		if styleSlot1HelpBadge() and helpSlot1 and helpSlot1HomePos then
			helpSlot1.Position = helpSlot1HomePos
			helpSlot1.Visible = true
		elseif helpSlot1 then
			helpSlot1.Visible = false
		end
	else
		SavePlotSlot.hide()
		if slot1 then
			slot1.Visible = false
			if slot1HomePos then
				slot1.Position = slot1HomePos
			end
		end
		if helpSlot1 then
			helpSlot1.Visible = false
		end
		stopSlot1IdleCycle()
		if slot1Stroke then
			slot1Stroke.Enabled = false
		end
	end
end

function SavePlotSlot.mount(d: Deps)
	deps = d
	local quickbar = d.mainHUD:FindFirstChild("Quickbar")
	local found = if quickbar then quickbar:FindFirstChild("Slot1") else nil
	if found and found:IsA("GuiObject") then
		slot1 = found
		slot1HomePos = slot1.Position
		slot1Button = d.ensureButton(slot1)
		d.passthroughDecor(slot1, slot1Button)
		slot1Circle = d.ensureCircle(slot1)
		UiCircles.forceOnDescendants(slot1)
		if slot1Circle:IsA("ImageLabel") or slot1Circle:IsA("ImageButton") then
			local img = (slot1Circle :: any).Image
			slot1OriginalImage = if typeof(img) == "string" and img ~= "" then img else SAVE_ICON
			;(slot1Circle :: any).Image = slot1OriginalImage
		end
		slot1OriginalBg = slot1Circle.BackgroundColor3
		slot1OriginalBgTrans = slot1Circle.BackgroundTransparency
		slot1Stroke = d.ensureStroke(slot1Circle, "_OceanTD_SaveRing", Color3.new(1, 1, 1), 2)
		slot1Stroke.Enabled = false

		local existing = slot1Circle:FindFirstChild("_OceanTD_SaveLabel")
		if existing and existing:IsA("TextLabel") then
			slot1SaveLabel = existing
		else
			if existing then
				existing:Destroy()
			end
			local lbl = Instance.new("TextLabel")
			lbl.Name = "_OceanTD_SaveLabel"
			lbl.BackgroundTransparency = 1
			lbl.Size = UDim2.fromScale(1, 1)
			lbl.Font = UiTheme.Font
			lbl.Text = "SAVE\nLOAD"
			lbl.TextColor3 = Color3.new(1, 1, 1)
			lbl.TextScaled = true
			lbl.TextWrapped = true
			lbl.Visible = false
			lbl.ZIndex = slot1Circle.ZIndex + 2
			lbl.Active = false
			lbl.Parent = slot1Circle
			local pad = Instance.new("UIPadding")
			pad.PaddingTop = UDim.new(0.18, 0)
			pad.PaddingBottom = UDim.new(0.18, 0)
			pad.PaddingLeft = UDim.new(0.1, 0)
			pad.PaddingRight = UDim.new(0.1, 0)
			pad.Parent = lbl
			slot1SaveLabel = lbl
		end
		slot1.Visible = false
		d.log("Slot1 save-plots button ready")
	else
		warn("[INV] MainHUD.Quickbar.Slot1 missing — save plots unavailable")
	end

	local quickbarHelp = d.mainHUD:FindFirstChild("QuickbarHelp")
	if quickbarHelp then
		local hs1 = quickbarHelp:FindFirstChild("Slot1")
		if hs1 and hs1:IsA("GuiObject") then
			helpSlot1 = hs1
			helpSlot1.Active = false
			helpSlot1.Visible = false
			for _, desc in ipairs(helpSlot1:GetDescendants()) do
				if desc:IsA("GuiObject") and desc.Name ~= "_OceanTD_HelpHit" then
					desc.Active = false
				end
			end
			local existingLetter = helpSlot1:FindFirstChild("_OceanTD_HelpLetter")
			if existingLetter and existingLetter:IsA("TextLabel") then
				helpSlot1Letter = existingLetter
			else
				if existingLetter then
					existingLetter:Destroy()
				end
				local letter = Instance.new("TextLabel")
				letter.Name = "_OceanTD_HelpLetter"
				letter.BackgroundTransparency = 1
				letter.Size = UDim2.fromScale(1, 1)
				letter.Font = UiTheme.Font
				letter.Text = "V"
				letter.TextColor3 = Color3.new(1, 1, 1)
				letter.TextScaled = true
				letter.Active = false
				letter.ZIndex = helpSlot1.ZIndex + 5
				letter.Parent = helpSlot1
				local pad = Instance.new("UIPadding")
				pad.PaddingTop = UDim.new(0.15, 0)
				pad.PaddingBottom = UDim.new(0.15, 0)
				pad.PaddingLeft = UDim.new(0.12, 0)
				pad.PaddingRight = UDim.new(0.12, 0)
				pad.Parent = letter
				helpSlot1Letter = letter
			end
			local existingHit = helpSlot1:FindFirstChild("_OceanTD_HelpHit")
			if existingHit and existingHit:IsA("GuiButton") then
				helpSlot1Hit = existingHit
			else
				if existingHit then
					existingHit:Destroy()
				end
				local hit = Instance.new("ImageButton")
				hit.Name = "_OceanTD_HelpHit"
				hit.BackgroundTransparency = 1
				hit.Image = ""
				hit.AutoButtonColor = false
				hit.Size = UDim2.fromScale(1, 1)
				hit.ZIndex = helpSlot1.ZIndex + 10
				hit.Parent = helpSlot1
				helpSlot1Hit = hit
			end
			UiCircles.ensure(helpSlot1)
			helpSlot1HomePos = helpSlot1.Position
		end
	end

	if slot1Button then
		slot1Button.Activated:Connect(function()
			SavePlotSlot.toggle()
		end)
	end
	if helpSlot1Hit then
		helpSlot1Hit.Activated:Connect(function()
			SavePlotSlot.toggle()
		end)
	end
end

return SavePlotSlot
