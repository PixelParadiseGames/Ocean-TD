--!strict
--[[
	Slot3 Undo UI — extracted from InventoryUI to stay under Luau's 200-local limit.
]]

local ContentProvider = game:GetService("ContentProvider")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local UiCircles = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiCircles"))
local UiTheme = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiTheme"))
local UiIdleCycle = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiIdleCycle"))
local Remotes = require(oceanRoot:WaitForChild("Remotes"))

local InventoryState = require(script.Parent:WaitForChild("InventoryState"))
local RelocateController = require(script.Parent:WaitForChild("RelocateController"))

local UndoSlot = {}

local SLIDE_PX = 88
local SLIDE_IN = TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local SLIDE_OUT = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local UNDO_SOUND_ID = "rbxassetid://17612245730"
local UNDO_STREAK_WINDOW = 3
local UNDO_PITCH_MIN = 0.9
local UNDO_PITCH_MAX = 1.55
local UNDO_PITCH_STEP = 0.07
local UNDO_FLASH_HOLD = 1
local UNDO_FLASH_FADE = 0.35
local UNDO_GLOW = Color3.fromRGB(255, 140, 40)
local ORANGE = Color3.fromRGB(230, 120, 40)

export type Deps = {
	mainHUD: ScreenGui,
	ensureButton: (GuiObject) -> GuiButton,
	passthroughDecor: (GuiObject, GuiButton) -> (),
	ensureCircle: (GuiObject) -> GuiObject,
	ensureStroke: (GuiObject, string, Color3, number) -> UIStroke,
	getShortcutMode: () -> string,
	getIdlePeriod: () -> number,
	log: (...any) -> (),
}

local deps: Deps
local slot3: GuiObject? = nil
local slot3Button: GuiButton? = nil
local slot3Circle: GuiObject? = nil
local slot3Stroke: UIStroke? = nil
local slot3UndoLabel: TextLabel? = nil
local slot3IdleStop: UiIdleCycle.StopFn? = nil
local slot3OriginalImage = ""
local slot3OriginalBg = Color3.fromRGB(20, 30, 45)
local slot3OriginalBgTrans = 0.15
local slot3HomePos: UDim2? = nil
local helpSlot3: GuiObject? = nil
local helpSlot3Letter: TextLabel? = nil
local helpSlot3HomePos: UDim2? = nil
local slot3SlideToken = 0
local slot3PressToken = 0
local undoBusy = false
local undoLastPressAt = 0
local undoPitchStreak = 0

local undoSoundTemplate = Instance.new("Sound")
undoSoundTemplate.Name = "OceanTD_UndoSound"
undoSoundTemplate.SoundId = UNDO_SOUND_ID
undoSoundTemplate.Volume = 0.9
undoSoundTemplate.Parent = SoundService
task.defer(function()
	pcall(function()
		ContentProvider:PreloadAsync({ undoSoundTemplate })
	end)
end)

local function stopSlot3IdleCycle()
	if slot3IdleStop then
		slot3IdleStop()
		slot3IdleStop = nil
	end
	if slot3UndoLabel then
		slot3UndoLabel.Visible = false
	end
end

local function applySlot3IdleFrame(showUndoText: boolean)
	if not slot3Circle then
		return
	end
	if showUndoText then
		if slot3Circle:IsA("ImageLabel") or slot3Circle:IsA("ImageButton") then
			(slot3Circle :: any).Image = ""
		end
		slot3Circle.BackgroundColor3 = Color3.new(0, 0, 0)
		slot3Circle.BackgroundTransparency = 0
		if slot3UndoLabel then
			slot3UndoLabel.Visible = true
		end
	else
		if slot3Circle:IsA("ImageLabel") or slot3Circle:IsA("ImageButton") then
			(slot3Circle :: any).Image = slot3OriginalImage
		end
		slot3Circle.BackgroundColor3 = slot3OriginalBg
		slot3Circle.BackgroundTransparency = slot3OriginalBgTrans
		if slot3UndoLabel then
			slot3UndoLabel.Visible = false
		end
	end
end

local function startSlot3IdleCycle()
	if not slot3 or not slot3Circle then
		return
	end
	stopSlot3IdleCycle()
	if slot3Stroke then
		slot3Stroke.Enabled = true
		slot3Stroke.Color = Color3.new(1, 1, 1)
		slot3Stroke.Thickness = 2
	end
	UiCircles.ensure(slot3Circle)
	slot3IdleStop = UiIdleCycle.subscribeSharedToggle(deps.getIdlePeriod(), applySlot3IdleFrame, function()
		return InventoryState.isOpen() and slot3 ~= nil and slot3.Visible
	end)
end

local function styleSlot3HelpBadge(): boolean
	if not helpSlot3 or not helpSlot3Letter then
		return false
	end
	local mode = deps.getShortcutMode()
	if mode == "touch" then
		return false
	end
	if helpSlot3:IsA("ImageLabel") or helpSlot3:IsA("ImageButton") then
		(helpSlot3 :: any).Image = ""
	end
	helpSlot3.BackgroundColor3 = ORANGE
	helpSlot3.BackgroundTransparency = 0
	helpSlot3.Active = false
	UiCircles.ensure(helpSlot3)
	helpSlot3Letter.Text = if mode == "gamepad" then "L2" else "Z"
	helpSlot3Letter.TextColor3 = Color3.new(1, 1, 1)
	helpSlot3Letter.Visible = true
	return true
end

local function slot3HiddenPos(home: UDim2): UDim2
	return home + UDim2.fromOffset(SLIDE_PX, 0)
end

local function playUndoSound()
	local now = os.clock()
	if now - undoLastPressAt <= UNDO_STREAK_WINDOW then
		undoPitchStreak += 1
	else
		undoPitchStreak = 0
	end
	undoLastPressAt = now

	local base = UNDO_PITCH_MIN + math.random() * (1.15 - UNDO_PITCH_MIN)
	local pitch = math.clamp(base + undoPitchStreak * UNDO_PITCH_STEP, UNDO_PITCH_MIN, UNDO_PITCH_MAX)

	local sound = undoSoundTemplate:Clone()
	sound.PlaybackSpeed = pitch
	sound.Parent = SoundService
	sound:Play()
	sound.Ended:Once(function()
		sound:Destroy()
	end)
	task.delay(4, function()
		if sound.Parent then
			sound:Destroy()
		end
	end)
end

local function playSlot3UndoPressFeedback()
	if not slot3Circle then
		return
	end
	slot3PressToken += 1
	local token = slot3PressToken
	stopSlot3IdleCycle()

	if slot3Circle:IsA("ImageLabel") or slot3Circle:IsA("ImageButton") then
		(slot3Circle :: any).Image = ""
	end
	slot3Circle.BackgroundColor3 = UNDO_GLOW
	slot3Circle.BackgroundTransparency = 0
	if slot3UndoLabel then
		slot3UndoLabel.TextColor3 = Color3.new(1, 1, 1)
		slot3UndoLabel.Visible = true
	end

	task.delay(UNDO_FLASH_HOLD, function()
		if token ~= slot3PressToken or not slot3Circle then
			return
		end
		local fade = TweenService:Create(slot3Circle, TweenInfo.new(UNDO_FLASH_FADE, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			BackgroundColor3 = Color3.new(0, 0, 0),
		})
		fade:Play()
		fade.Completed:Wait()
		if token ~= slot3PressToken then
			return
		end
		if InventoryState.isOpen() and slot3 and slot3.Visible then
			startSlot3IdleCycle()
		end
	end)
end

function UndoSlot.refreshHelpBadge()
	if not helpSlot3 or not helpSlot3.Visible then
		return
	end
	if not styleSlot3HelpBadge() then
		helpSlot3.Visible = false
	end
end

function UndoSlot.requestUndo()
	if not InventoryState.isOpen() then
		return
	end
	if InventoryState.isSavePlotsBlocking() or InventoryState.isClearPlotBlocking() then
		return
	end
	playUndoSound()
	playSlot3UndoPressFeedback()
	if undoBusy then
		return
	end
	undoBusy = true
	if RelocateController.isActive() then
		RelocateController.cancel(true)
	end
	local ok, result = pcall(function()
		return Remotes.getFunction("RequestUndo"):InvokeServer()
	end)
	undoBusy = false
	if ok and typeof(result) == "table" and result.ok then
		deps.log("Undo", result.kind)
	else
		local code = if ok and typeof(result) == "table" then result.errorCode else "Fail"
		deps.log("Undo rejected", code)
	end
end

function UndoSlot.playReveal()
	if not slot3 or not slot3HomePos then
		return
	end
	slot3SlideToken += 1
	local token = slot3SlideToken
	local home = slot3HomePos
	local hidden = slot3HiddenPos(home)

	slot3.Position = hidden
	slot3.Visible = true
	if slot3Stroke then
		slot3Stroke.Enabled = true
		slot3Stroke.Color = Color3.new(1, 1, 1)
		slot3Stroke.Thickness = 2
	end
	startSlot3IdleCycle()

	local showHelp = styleSlot3HelpBadge()
	if showHelp and helpSlot3 and helpSlot3HomePos then
		helpSlot3.Position = slot3HiddenPos(helpSlot3HomePos)
		helpSlot3.Visible = true
		TweenService:Create(helpSlot3, SLIDE_IN, { Position = helpSlot3HomePos }):Play()
	elseif helpSlot3 then
		helpSlot3.Visible = false
	end

	local tw = TweenService:Create(slot3, SLIDE_IN, { Position = home })
	tw:Play()
	tw.Completed:Wait()
	if token ~= slot3SlideToken then
		return
	end
	slot3.Position = home
	if showHelp and helpSlot3 and helpSlot3HomePos then
		helpSlot3.Position = helpSlot3HomePos
	end
end

function UndoSlot.playHide()
	if not slot3 or not slot3HomePos then
		return
	end
	slot3SlideToken += 1
	local token = slot3SlideToken
	local home = slot3HomePos
	local hidden = slot3HiddenPos(home)

	stopSlot3IdleCycle()
	slot3PressToken += 1
	if not slot3.Visible then
		if helpSlot3 then
			helpSlot3.Visible = false
			if helpSlot3HomePos then
				helpSlot3.Position = helpSlot3HomePos
			end
		end
		slot3.Position = home
		if slot3Stroke then
			slot3Stroke.Enabled = false
		end
		return
	end

	slot3.Position = home
	local tw = TweenService:Create(slot3, SLIDE_OUT, { Position = hidden })
	tw:Play()
	if helpSlot3 and helpSlot3.Visible and helpSlot3HomePos then
		helpSlot3.Position = helpSlot3HomePos
		TweenService:Create(helpSlot3, SLIDE_OUT, { Position = slot3HiddenPos(helpSlot3HomePos) }):Play()
	end
	tw.Completed:Wait()
	if token ~= slot3SlideToken then
		return
	end
	slot3.Visible = false
	slot3.Position = home
	if slot3Stroke then
		slot3Stroke.Enabled = false
	end
	if helpSlot3 then
		helpSlot3.Visible = false
		if helpSlot3HomePos then
			helpSlot3.Position = helpSlot3HomePos
		end
	end
end

function UndoSlot.syncVisibility()
	if InventoryState.isOpen() then
		if slot3 and slot3HomePos then
			slot3.Position = slot3HomePos
			slot3.Visible = true
			startSlot3IdleCycle()
		end
		if styleSlot3HelpBadge() and helpSlot3 and helpSlot3HomePos then
			helpSlot3.Position = helpSlot3HomePos
			helpSlot3.Visible = true
		elseif helpSlot3 then
			helpSlot3.Visible = false
		end
	else
		stopSlot3IdleCycle()
		if slot3 and slot3HomePos then
			slot3.Visible = false
			slot3.Position = slot3HomePos
		end
		if slot3Stroke then
			slot3Stroke.Enabled = false
		end
		if helpSlot3 then
			helpSlot3.Visible = false
			if helpSlot3HomePos then
				helpSlot3.Position = helpSlot3HomePos
			end
		end
	end
end

function UndoSlot.mount(d: Deps)
	deps = d
	local quickbar = d.mainHUD:FindFirstChild("Quickbar")
	local found = if quickbar then quickbar:FindFirstChild("Slot3") else nil
	if found and found:IsA("GuiObject") then
		slot3 = found
		slot3HomePos = slot3.Position
		slot3Button = d.ensureButton(slot3)
		d.passthroughDecor(slot3, slot3Button)
		slot3Circle = d.ensureCircle(slot3)
		UiCircles.forceOnDescendants(slot3)
		if slot3Circle:IsA("ImageLabel") or slot3Circle:IsA("ImageButton") then
			slot3OriginalImage = (slot3Circle :: any).Image
		end
		slot3OriginalBg = slot3Circle.BackgroundColor3
		slot3OriginalBgTrans = slot3Circle.BackgroundTransparency
		slot3Stroke = d.ensureStroke(slot3Circle, "_OceanTD_UndoRing", Color3.new(1, 1, 1), 2)
		slot3Stroke.Enabled = false

		local existingUndo = slot3Circle:FindFirstChild("_OceanTD_UndoLabel")
		if existingUndo and existingUndo:IsA("TextLabel") then
			slot3UndoLabel = existingUndo
		else
			if existingUndo then
				existingUndo:Destroy()
			end
			local lbl = Instance.new("TextLabel")
			lbl.Name = "_OceanTD_UndoLabel"
			lbl.BackgroundTransparency = 1
			lbl.Size = UDim2.fromScale(1, 1)
			lbl.Font = UiTheme.Font
			lbl.Text = "UNDO"
			lbl.TextColor3 = Color3.new(1, 1, 1)
			lbl.TextScaled = true
			lbl.Visible = false
			lbl.ZIndex = slot3Circle.ZIndex + 2
			lbl.Active = false
			lbl.Parent = slot3Circle
			local pad = Instance.new("UIPadding")
			pad.PaddingTop = UDim.new(0.22, 0)
			pad.PaddingBottom = UDim.new(0.22, 0)
			pad.PaddingLeft = UDim.new(0.08, 0)
			pad.PaddingRight = UDim.new(0.08, 0)
			pad.Parent = lbl
			slot3UndoLabel = lbl
		end
		slot3.Visible = false
		d.log("Slot3 undo button ready")
	else
		warn("[INV] MainHUD.Quickbar.Slot3 missing — undo button unavailable")
	end

	local quickbarHelp = d.mainHUD:FindFirstChild("QuickbarHelp")
	if quickbarHelp then
		local hs3 = quickbarHelp:FindFirstChild("Slot3")
		if hs3 and hs3:IsA("GuiObject") then
			helpSlot3 = hs3
			helpSlot3.Active = false
			helpSlot3.Visible = false
			for _, desc in ipairs(helpSlot3:GetDescendants()) do
				if desc:IsA("GuiObject") then
					desc.Active = false
				end
			end
			local existingLetter = helpSlot3:FindFirstChild("_OceanTD_HelpLetter")
			if existingLetter and existingLetter:IsA("TextLabel") then
				helpSlot3Letter = existingLetter
			else
				if existingLetter then
					existingLetter:Destroy()
				end
				local letter = Instance.new("TextLabel")
				letter.Name = "_OceanTD_HelpLetter"
				letter.BackgroundTransparency = 1
				letter.Size = UDim2.fromScale(1, 1)
				letter.Font = UiTheme.Font
				letter.Text = "Z"
				letter.TextColor3 = Color3.new(1, 1, 1)
				letter.TextScaled = true
				letter.Active = false
				letter.ZIndex = helpSlot3.ZIndex + 5
				letter.Parent = helpSlot3
				local pad = Instance.new("UIPadding")
				pad.PaddingTop = UDim.new(0.15, 0)
				pad.PaddingBottom = UDim.new(0.15, 0)
				pad.PaddingLeft = UDim.new(0.15, 0)
				pad.PaddingRight = UDim.new(0.15, 0)
				pad.Parent = letter
				helpSlot3Letter = letter
			end
			UiCircles.ensure(helpSlot3)
			helpSlot3HomePos = helpSlot3.Position
		end
	end

	if slot3Button then
		slot3Button.Activated:Connect(function()
			UndoSlot.requestUndo()
		end)
	end
end

return UndoSlot
