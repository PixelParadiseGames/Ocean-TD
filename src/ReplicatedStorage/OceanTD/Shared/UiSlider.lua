--!strict
--[[
	Horizontal 0–1 slider: touch drag, mouse click/drag, gamepad D-pad when selected.
]]

local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")

local UiTheme = require(script.Parent:WaitForChild("UiTheme"))

local UiSlider = {}

export type SliderOptions = {
	name: string?,
	layoutOrder: number?,
	height: number?,
	accentColor: Color3?,
	onChanged: ((value: number) -> ())?,
}

export type SliderHandle = {
	root: Frame,
	setValue: (number, boolean?) -> (),
	getValue: () -> number,
	destroy: () -> (),
}

local DRAG_SENS = Enum.UserInputType.MouseButton1
local TOUCH_SENS = Enum.UserInputType.Touch

local function pctLabel(v: number): string
	return string.format("%d%%", math.floor(v * 100 + 0.5))
end

function UiSlider.create(parent: Instance, opts: SliderOptions?): SliderHandle
	local accent = if opts and opts.accentColor then opts.accentColor else Color3.fromRGB(0, 115, 237)
	local rowH = if opts and opts.height then opts.height else 44

	local root = Instance.new("Frame")
	root.Name = if opts and opts.name then opts.name else "Slider"
	root.BackgroundTransparency = 1
	root.Size = UDim2.new(1, 0, 0, rowH)
	root.LayoutOrder = if opts and opts.layoutOrder then opts.layoutOrder else 0
	root.Parent = parent

	local pct = Instance.new("TextLabel")
	pct.Name = "Pct"
	pct.AnchorPoint = Vector2.new(1, 0.5)
	pct.Position = UDim2.new(1, 0, 0.5, 0)
	pct.Size = UDim2.fromOffset(52, rowH)
	pct.BackgroundTransparency = 1
	pct.Font = UiTheme.Font
	pct.Text = "100%"
	pct.TextColor3 = Color3.fromRGB(210, 220, 235)
	pct.TextSize = 18
	pct.TextXAlignment = Enum.TextXAlignment.Right
	pct.Parent = root

	local trackBtn = Instance.new("TextButton")
	trackBtn.Name = "Track"
	trackBtn.AnchorPoint = Vector2.new(0, 0.5)
	trackBtn.Position = UDim2.new(0, 0, 0.5, 0)
	trackBtn.Size = UDim2.new(1, -58, 0, 28)
	trackBtn.BackgroundColor3 = Color3.fromRGB(32, 44, 58)
	trackBtn.BorderSizePixel = 0
	trackBtn.Text = ""
	trackBtn.AutoButtonColor = false
	trackBtn.ClipsDescendants = true
	trackBtn.Selectable = true
	trackBtn.Parent = root
	local trackCorner = Instance.new("UICorner")
	trackCorner.CornerRadius = UDim.new(0, 8)
	trackCorner.Parent = trackBtn

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.BackgroundColor3 = accent
	fill.BorderSizePixel = 0
	fill.Size = UDim2.fromScale(1, 1)
	fill.Parent = trackBtn
	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(0, 8)
	fillCorner.Parent = fill

	local thumb = Instance.new("Frame")
	thumb.Name = "Thumb"
	thumb.AnchorPoint = Vector2.new(0.5, 0.5)
	thumb.Size = UDim2.fromOffset(22, 22)
	thumb.BackgroundColor3 = Color3.new(1, 1, 1)
	thumb.BorderSizePixel = 0
	thumb.ZIndex = 2
	thumb.Parent = trackBtn
	local thumbCorner = Instance.new("UICorner")
	thumbCorner.CornerRadius = UDim.new(1, 0)
	thumbCorner.Parent = thumb
	local thumbStroke = Instance.new("UIStroke")
	thumbStroke.Color = accent
	thumbStroke.Thickness = 2
	thumbStroke.Parent = thumb

	local value = 1
	local dragging = false
	local conns: { RBXScriptConnection } = {}

	local function applyVisual(n: number, fire: boolean)
		value = math.clamp(n, 0, 1)
		fill.Size = UDim2.new(value, 0, 1, 0)
		thumb.Position = UDim2.new(value, 0, 0.5, 0)
		pct.Text = pctLabel(value)
		if fire and opts and opts.onChanged then
			opts.onChanged(value)
		end
	end

	local function valueFromScreenX(screenX: number): number
		local ax = trackBtn.AbsolutePosition.X
		local w = trackBtn.AbsoluteSize.X
		if w <= 1 then
			return value
		end
		return math.clamp((screenX - ax) / w, 0, 1)
	end

	local function beginDrag(input: InputObject)
		if input.UserInputType ~= DRAG_SENS and input.UserInputType ~= TOUCH_SENS then
			return
		end
		dragging = true
		applyVisual(valueFromScreenX(input.Position.X), true)
	end

	table.insert(conns, trackBtn.InputBegan:Connect(beginDrag))
	table.insert(conns, UserInputService.InputChanged:Connect(function(input)
		if not dragging then
			return
		end
		if input.UserInputType ~= DRAG_SENS and input.UserInputType ~= TOUCH_SENS then
			return
		end
		applyVisual(valueFromScreenX(input.Position.X), true)
	end))
	table.insert(conns, UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType ~= DRAG_SENS and input.UserInputType ~= TOUCH_SENS then
			return
		end
		dragging = false
	end))

	local function nudge(delta: number)
		applyVisual(value + delta, true)
	end

	table.insert(conns, UserInputService.InputBegan:Connect(function(input, gp)
		if gp or dragging then
			return
		end
		if GuiService.SelectedObject ~= trackBtn then
			return
		end
		if input.KeyCode == Enum.KeyCode.DPadLeft or input.KeyCode == Enum.KeyCode.Left or input.KeyCode == Enum.KeyCode.ButtonD then
			nudge(-0.05)
		elseif input.KeyCode == Enum.KeyCode.DPadRight or input.KeyCode == Enum.KeyCode.Right or input.KeyCode == Enum.KeyCode.ButtonDP then
			nudge(0.05)
		end
	end))

	applyVisual(1, false)

	local handle: SliderHandle
	handle = {
		root = root,
		setValue = function(n: number, fire: boolean?)
			applyVisual(n, fire == true)
		end,
		getValue = function()
			return value
		end,
		destroy = function()
			for _, c in ipairs(conns) do
				c:Disconnect()
			end
			table.clear(conns)
			root:Destroy()
		end,
	}
	return handle
end

return UiSlider
