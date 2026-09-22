--!strict
--[[
	Active camera mode name label (to the right of the active cam icon).
	Extracted from FreeCam.client.lua for register budget.
]]

local TweenService = game:GetService("TweenService")

local FreeCamConfig = require(script.Parent:WaitForChild("FreeCamConfig"))

export type CamMode = FreeCamConfig.CamMode

export type ModeIcon = {
	mode: CamMode,
	root: GuiObject,
	hit: GuiButton,
	stroke: UIStroke,
	scale: UIScale,
	brand: Color3,
}

local FreeCamModeLabel = {}

local modeLabel: TextLabel? = nil
local modeLabelStroke: UIStroke? = nil
local modeLabelToken = 0

function FreeCamModeLabel.hide()
	modeLabelToken += 1
	if modeLabel then
		modeLabel.Visible = false
	end
end

-- Place label to the right of the fixed "active" diamond slot (not mid-carousel icon positions).
function FreeCamModeLabel.show(
	camMode: CamMode,
	camIcons: { ModeIcon },
	currentMode: CamMode,
	activeSlot: UDim2,
	suppressed: boolean,
	carouselReady: boolean
)
	if suppressed or not carouselReady then
		return
	end
	local icon: ModeIcon? = nil
	for _, it in ipairs(camIcons) do
		if it.mode == currentMode then
			icon = it
			break
		end
	end
	if not icon then
		return
	end
	local parent = icon.root.Parent
	if not (parent and parent:IsA("GuiObject")) then
		return
	end
	modeLabelToken += 1
	local my = modeLabelToken
	local label = modeLabel
	local stroke = modeLabelStroke
	if not (label and label.Parent) then
		local existing = parent:FindFirstChild(FreeCamConfig.MODE_LABEL_NAME)
		if existing and existing:IsA("TextLabel") then
			label = existing
		else
			local t = Instance.new("TextLabel")
			t.Name = FreeCamConfig.MODE_LABEL_NAME
			t.BackgroundTransparency = 1
			t.AnchorPoint = Vector2.new(0, 0.5)
			t.Size = UDim2.fromOffset(160, 28)
			t.Font = Enum.Font.GothamBold
			t.TextSize = 16
			t.TextColor3 = Color3.new(1, 1, 1)
			t.TextXAlignment = Enum.TextXAlignment.Left
			t.TextYAlignment = Enum.TextYAlignment.Center
			t.TextStrokeTransparency = 1
			t.ZIndex = 60
			t.Parent = parent
			label = t
		end
		modeLabel = label
		local st = label:FindFirstChildOfClass("UIStroke")
		if not st then
			st = Instance.new("UIStroke")
			st.Thickness = 1.25
			st.Color = FreeCamConfig.MODE_LABEL_STROKE
			st.Transparency = 0
			st.Parent = label
		end
		modeLabelStroke = st
		stroke = st
	end
	-- Prefer AbsoluteSize of the active icon; fall back when layout hasn't measured yet.
	local halfW = math.max(18, icon.root.AbsoluteSize.X * 0.5)
	if halfW < 2 then
		halfW = 22
	end
	label.Visible = true
	label.Text = FreeCamConfig.MODE_LABELS[camMode] or ""
	label.TextTransparency = 0
	label.ZIndex = math.max(icon.root.ZIndex + 5, 60)
	-- Always unlock to the top/active diamond slot, never the icon's mid-revolve position.
	label.Position = UDim2.new(
		activeSlot.X.Scale,
		activeSlot.X.Offset + halfW + 10,
		activeSlot.Y.Scale,
		activeSlot.Y.Offset
	)
	if stroke then
		stroke.Color = FreeCamConfig.MODE_LABEL_STROKE
		stroke.Thickness = 1.25
		stroke.Transparency = 0
	end
	task.delay(FreeCamConfig.MODE_LABEL_FADE_SEC, function()
		if my ~= modeLabelToken or not label or not label.Parent then
			return
		end
		local tw = TweenService:Create(label, FreeCamConfig.MODE_LABEL_FADE_OUT, { TextTransparency = 1 })
		tw:Play()
		if stroke then
			TweenService:Create(stroke, FreeCamConfig.MODE_LABEL_FADE_OUT, { Transparency = 1 }):Play()
		end
		tw.Completed:Once(function()
			if my == modeLabelToken and label then
				label.Visible = false
			end
		end)
	end)
end

return FreeCamModeLabel
