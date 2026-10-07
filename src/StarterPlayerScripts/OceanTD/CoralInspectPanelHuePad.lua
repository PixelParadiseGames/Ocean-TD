--!strict
--[[
	Joystick hue-row chrome for CoralInspectPanel (split out for Luau 200-local limit):
	RGB focus stroke, Dice/A cycle, and D-Pad tip for the first few hue changes.
]]

local RunService = game:GetService("RunService")

local oceanRoot = game:GetService("ReplicatedStorage"):WaitForChild("OceanTD")
local UiTheme = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiTheme"))

local Consts = require(script.Parent:WaitForChild("CoralInspectPanelConsts"))

local MOVE_ICON_IMAGE = "rbxassetid://345081302"
local HUE_DPAD_PROMPT_MAX = 3

export type Env = {
	getRoot: () -> Frame?,
	getFocusIndex: () -> number,
	getActiveIndex: () -> number?,
	getSwatchBtns: () -> { [number]: GuiButton },
	getSwatchStrokes: () -> { [number]: UIStroke },
	getSwatchCounts: () -> { [number]: TextLabel },
	getDice: () -> ImageButton?,
	isGamepad: () -> boolean,
	isHueTutorialHint: () -> boolean,
	getDefaultStrokeFlashUntil: () -> number,
}

local HuePad = {}

local env: Env? = nil
local colorFocusA: TextLabel? = nil
local hueDpadPrompt: Frame? = nil
local hueDpadPromptArmed = false
local hueDpadChangeCount = 0
local colorFocusConn: RBXScriptConnection? = nil

function HuePad.bind(e: Env)
	env = e
end

function HuePad.rgbCycleColor(): Color3
	return Color3.fromHSV((os.clock() * 0.75) % 1, 1, 1)
end

local function ensureColorFocusA(): TextLabel
	local existing = colorFocusA
	if existing and existing.Parent then
		return existing
	end
	local a = Instance.new("TextLabel")
	a.Name = "_OceanTD_HueFocusA"
	a.BackgroundTransparency = 1
	a.AnchorPoint = Vector2.new(0.5, 0.5)
	a.Position = UDim2.fromScale(0.5, 0.5)
	a.Size = UDim2.fromScale(0.62, 0.62)
	a.Font = UiTheme.Font
	a.Text = "A"
	a.TextColor3 = Color3.new(1, 1, 1)
	a.TextScaled = true
	a.ZIndex = 8
	a.Visible = false
	a.Active = false
	local edge = Instance.new("UIStroke")
	edge.Name = "Outline"
	edge.Color = Color3.new(0, 0, 0)
	edge.Thickness = 2
	edge.Parent = a
	colorFocusA = a
	return a
end

local function ensureHueDpadPrompt(): Frame
	local existing = hueDpadPrompt
	if existing and existing.Parent then
		return existing
	end
	local rootF = Instance.new("Frame")
	rootF.Name = "_OceanTD_HueDpadPrompt"
	rootF.BackgroundTransparency = 1
	rootF.AnchorPoint = Vector2.new(0.5, 0.5)
	rootF.Position = UDim2.fromScale(0.5, 0.5)
	rootF.Size = UDim2.fromScale(0.92, 0.92)
	rootF.ZIndex = 12
	rootF.Visible = false
	rootF.Active = false

	local move = Instance.new("ImageLabel")
	move.Name = "MoveIcon"
	move.BackgroundTransparency = 1
	move.AnchorPoint = Vector2.new(0.5, 0.5)
	move.Position = UDim2.fromScale(0.5, 0.42)
	move.Size = UDim2.fromScale(0.85, 0.85)
	move.Image = MOVE_ICON_IMAGE
	move.ScaleType = Enum.ScaleType.Fit
	move.ZIndex = rootF.ZIndex
	move.Parent = rootF

	local glyph = Instance.new("TextLabel")
	glyph.Name = "Glyph"
	glyph.BackgroundTransparency = 1
	glyph.AnchorPoint = Vector2.new(0.5, 0.5)
	glyph.Position = UDim2.fromScale(0.5, 0.88)
	glyph.Size = UDim2.fromScale(0.95, 0.28)
	glyph.Font = UiTheme.Font
	glyph.Text = "D-Pad"
	glyph.TextColor3 = Color3.new(0, 0, 0)
	glyph.TextScaled = true
	glyph.ZIndex = rootF.ZIndex + 1
	glyph.Parent = rootF

	hueDpadPrompt = rootF
	return rootF
end

function HuePad.hideDpadPrompt()
	hueDpadPromptArmed = false
	if hueDpadPrompt then
		hueDpadPrompt.Visible = false
	end
end

function HuePad.armDpadPrompt()
	hueDpadPromptArmed = true
	hueDpadChangeCount = 0
end

function HuePad.noteFocusChanged()
	if not hueDpadPromptArmed then
		return
	end
	local e = env
	if not e or not e.isGamepad() or not e.isHueTutorialHint() then
		return
	end
	hueDpadChangeCount += 1
	if hueDpadChangeCount >= HUE_DPAD_PROMPT_MAX then
		HuePad.hideDpadPrompt()
	end
end

function HuePad.syncOverlays()
	local e = env
	if not e then
		return
	end
	local dice = e.getDice()
	local aLbl = ensureColorFocusA()
	local focusIdx = e.getFocusIndex()
	local activeIdx = e.getActiveIndex()
	local btns = e.getSwatchBtns()
	local counts = e.getSwatchCounts()
	local focusBtn = btns[focusIdx]
	local activeBtn = if activeIdx ~= nil then btns[activeIdx] else nil
	local focusCount = counts[focusIdx]
	local gamepad = e.isGamepad()
	-- Focus chrome (RGB stroke / A tip) is joystick-only — never during touch hue tutorial.
	local showFocus = gamepad

	-- Dice always lives on the painted/current hue — never follows D-pad focus.
	if dice then
		if activeBtn then
			dice.Parent = activeBtn
		else
			dice.Visible = false
		end
	end

	local prompt = ensureHueDpadPrompt()
	local dpadArmed = hueDpadPromptArmed
		and gamepad
		and e.isHueTutorialHint()
		and focusBtn ~= nil
		and hueDpadChangeCount < HUE_DPAD_PROMPT_MAX
	-- Before first move: D-Pad only. After 1–2 moves: alternate D-Pad ↔ A. After 3: A only.
	local flashPhaseA = (os.clock() % 2) < 1
	local showDpad = dpadArmed and (hueDpadChangeCount == 0 or not flashPhaseA)

	if showDpad and focusBtn then
		prompt.Parent = focusBtn
		prompt.Visible = true
		aLbl.Visible = false
		-- Keep dice on current hue; hide A / seed flash on focus while D-Pad tip is up.
		if dice and activeBtn then
			dice.Visible = true
		end
		if focusCount and (activeIdx == nil or focusIdx ~= activeIdx) then
			focusCount.Visible = true
		end
		return
	end
	prompt.Visible = false

	if not (gamepad and showFocus and focusBtn) then
		aLbl.Visible = false
		if dice and activeBtn then
			dice.Visible = true
		end
		return
	end

	-- Focus tip: A ↔ seed N, or A ↔ Dice when the focused swatch is the current color.
	-- While D-Pad tip is still armed (moves 1–2), this branch is the "A" half of the alternate.
	local showA = if dpadArmed then true else flashPhaseA
	local focusIsCurrent = activeIdx ~= nil and focusIdx == activeIdx
	aLbl.Parent = focusBtn
	aLbl.Visible = showA

	if focusIsCurrent then
		if dice then
			dice.Visible = not showA
		end
		if focusCount then
			focusCount.Visible = false
		end
	else
		if dice and activeBtn then
			dice.Visible = true
		end
		if focusCount then
			-- Alternate A with the seed count on non-current hues (after D-Pad tip is done).
			focusCount.Visible = not showA
		end
	end
end

local function updateFocusedHueStrokeColor()
	local e = env
	if not e then
		return
	end
	local root = e.getRoot()
	if not root or not root.Visible then
		return
	end
	if not e.isGamepad() then
		return
	end
	local idx = e.getFocusIndex()
	local stroke = e.getSwatchStrokes()[idx]
	if not stroke or not stroke.Enabled then
		HuePad.syncOverlays()
		return
	end
	local activeIdx = e.getActiveIndex()
	if activeIdx ~= nil and idx == activeIdx and idx ~= Consts.DEFAULT_PALETTE_SWATCH then
		HuePad.syncOverlays()
		return
	end
	if idx == Consts.DEFAULT_PALETTE_SWATCH and os.clock() < e.getDefaultStrokeFlashUntil() then
		HuePad.syncOverlays()
		return
	end
	stroke.Color = HuePad.rgbCycleColor()
	HuePad.syncOverlays()
end

function HuePad.ensureCycle()
	if colorFocusConn then
		return
	end
	colorFocusConn = RunService.Heartbeat:Connect(updateFocusedHueStrokeColor)
end

function HuePad.applyNonGamepadDice(activeBtn: GuiButton?)
	local dice = if env then env.getDice() else nil
	if dice then
		if activeBtn then
			dice.Visible = true
			dice.Parent = activeBtn
		else
			dice.Visible = false
		end
	end
	if colorFocusA then
		colorFocusA.Visible = false
	end
	if hueDpadPrompt then
		hueDpadPrompt.Visible = false
	end
end

return HuePad
