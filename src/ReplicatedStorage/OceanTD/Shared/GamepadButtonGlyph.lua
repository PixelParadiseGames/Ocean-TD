--!strict
--[[
	Joypad tooltip icons.

	PlayStation pad → ReplicatedStorage["PlayStation Buttons Sheet"]
	Xbox and other PC pads → ReplicatedStorage["Xbox One Buttons Sheet"]
	Keyboard / touch → the label's letter stays.

	Both sheets are the same 4×4 grid (left to right, top to bottom):
	  A/Cross, X/Square, Y/Triangle, B/Circle
	  L1, R1, L2, R2
	  D-pad down, left, right, up
	  D-pad, L3, R3, Select
	One cell is shown by scaling the sheet to 4× the badge. That does not
	depend on the image's pixel size (a too-small ImageRect was clipping
	every icon down to its top-left quarter).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local UiPopupScale = require(script.Parent:WaitForChild("UiPopupScale"))

local GamepadButtonGlyph = {}

type Host = TextLabel | TextButton

local CELLS: { [string]: Vector2 } = {
	A = Vector2.new(0, 0),
	X = Vector2.new(1, 0),
	Y = Vector2.new(2, 0),
	B = Vector2.new(3, 0),
	L1 = Vector2.new(0, 1),
	R1 = Vector2.new(1, 1),
	L2 = Vector2.new(2, 1),
	R2 = Vector2.new(3, 1),
	DDown = Vector2.new(0, 2),
	DLeft = Vector2.new(1, 2),
	DRight = Vector2.new(2, 2),
	DUp = Vector2.new(3, 2),
	["D-Pad"] = Vector2.new(0, 3),
	DPad = Vector2.new(0, 3),
	L3 = Vector2.new(1, 3),
	R3 = Vector2.new(2, 3),
	Select = Vector2.new(3, 3),
}

local SHEET_INFO = {
	playstation = {
		instanceName = "PlayStation Buttons Sheet",
		fallback = "rbxassetid://14969992119",
	},
	xbox = {
		instanceName = "Xbox One Buttons Sheet",
		-- 399586231 is the Decal. Its texture image is the button sheet.
		fallback = "rbxassetid://399586227",
	},
}

local PAD_ICON_SCALE = 1.1

local watched: { [Host]: boolean } = {}
local uriCache: { [string]: string } = {}

local function isGamepad(): boolean
	local t = UserInputService:GetLastInputType()
	return t == Enum.UserInputType.Gamepad1
		or t == Enum.UserInputType.Gamepad2
		or t == Enum.UserInputType.Gamepad3
		or t == Enum.UserInputType.Gamepad4
end

local function sheetKind(): "playstation" | "xbox" | nil
	if not isGamepad() then
		return nil
	end
	local ok, name = pcall(function()
		return UserInputService:GetStringForKeyCode(Enum.KeyCode.ButtonA)
	end)
	if ok and (
		name == "ButtonCross"
		or name == "ButtonCircle"
		or name == "ButtonSquare"
		or name == "ButtonTriangle"
	) then
		return "playstation"
	end
	return "xbox"
end

local function normalizeUri(uri: string): string
	local id = string.match(uri, "%d+")
	if id == "399586231" then
		return "rbxassetid://399586227"
	end
	if id and string.find(uri, "rbxassetid://", 1, true) == nil then
		return "rbxassetid://" .. id
	end
	return uri
end

local function readInstanceImage(inst: Instance): string?
	if inst:IsA("Decal") or inst:IsA("Texture") then
		if inst.Texture ~= "" then
			return normalizeUri(inst.Texture)
		end
	elseif inst:IsA("ImageLabel") or inst:IsA("ImageButton") then
		if inst.Image ~= "" then
			return normalizeUri(inst.Image)
		end
	end
	for _, child in ipairs(inst:GetChildren()) do
		local found = readInstanceImage(child)
		if found then
			return found
		end
	end
	return nil
end

local function sheetUri(kind: "playstation" | "xbox"): string
	local cached = uriCache[kind]
	if cached then
		return cached
	end
	local info = SHEET_INFO[kind]
	local ocean = ReplicatedStorage:FindFirstChild("OceanTD")
	local root: Instance = if ocean then ocean else ReplicatedStorage
	local inst = ReplicatedStorage:FindFirstChild(info.instanceName) or root:FindFirstChild(info.instanceName, true)
	local uri = if inst then readInstanceImage(inst) else nil
	if not uri or uri == "" then
		uri = info.fallback
	end
	uriCache[kind] = uri
	return uri
end

local function windowScale(window: Frame): number
	local saved = window:GetAttribute("_OceanTD_PadIconScale")
	if typeof(saved) == "number" and saved > 0 then
		return saved
	end
	return PAD_ICON_SCALE
end

local function layoutWindow(host: Host, window: Frame)
	local abs = host.AbsoluteSize
	local short = math.min(abs.X, abs.Y)
	local scale = windowScale(window)
	if short < 2 then
		window.Size = UDim2.fromScale(scale, scale)
		window.AnchorPoint = Vector2.new(0.5, 0.5)
		window.Position = UDim2.fromScale(0.5, 0.5)
		return
	end
	-- AbsoluteSize already includes ancestor UIScale. Offset children are in
	-- pre-scale space, so dividing keeps the sheet the same size as the badge.
	-- Phone ancestor scale is 1, so those icons stay put.
	local anc = UiPopupScale.ancestorScale(host)
	if anc < 0.001 then
		anc = 1
	end
	local side = math.floor(short * scale / anc + 0.5)
	window.Size = UDim2.fromOffset(side, side)
	local wide = abs.X > abs.Y * 1.4
	local align = if host:IsA("TextLabel") then host.TextXAlignment else Enum.TextXAlignment.Center
	if wide and align == Enum.TextXAlignment.Right then
		window.AnchorPoint = Vector2.new(1, 0.5)
		window.Position = UDim2.new(1, 0, 0.5, 0)
	elseif wide and align == Enum.TextXAlignment.Left then
		window.AnchorPoint = Vector2.new(0, 0.5)
		window.Position = UDim2.new(0, 0, 0.5, 0)
	else
		window.AnchorPoint = Vector2.new(0.5, 0.5)
		window.Position = UDim2.fromScale(0.5, 0.5)
	end
end

local function ensureIcon(host: Host): Frame
	local existing = host:FindFirstChild("_OceanTD_PadIcon")
	if existing and existing:IsA("Frame") and existing:FindFirstChild("Sheet") then
		return existing
	end
	if existing then
		existing:Destroy()
	end
	local window = Instance.new("Frame")
	window.Name = "_OceanTD_PadIcon"
	window.BackgroundTransparency = 1
	window.BorderSizePixel = 0
	window.ClipsDescendants = true
	window.AnchorPoint = Vector2.new(0.5, 0.5)
	window.Position = UDim2.fromScale(0.5, 0.5)
	window.Size = UDim2.fromScale(PAD_ICON_SCALE, PAD_ICON_SCALE)
	window.Active = false
	window.Visible = false
	window.ZIndex = host.ZIndex + 2
	window.Parent = host
	local sheet = Instance.new("ImageLabel")
	sheet.Name = "Sheet"
	sheet.BackgroundTransparency = 1
	sheet.BorderSizePixel = 0
	sheet.AnchorPoint = Vector2.new(0, 0)
	sheet.ScaleType = Enum.ScaleType.Stretch
	sheet.Size = UDim2.fromScale(4, 4)
	sheet.Active = false
	sheet.ZIndex = window.ZIndex
	sheet.Parent = window
	if host:GetAttribute("_OceanTD_PadLayout") ~= true then
		host:SetAttribute("_OceanTD_PadLayout", true)
		host:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
			if window.Parent then
				layoutWindow(host, window)
			end
		end)
	end
	layoutWindow(host, window)
	return window
end

local function remember(host: Host)
	if host:GetAttribute("_OceanTD_PadSaved") == true then
		return
	end
	host:SetAttribute("_OceanTD_PadSaved", true)
	host:SetAttribute("_OceanTD_PadTextT", host.TextTransparency)
	host:SetAttribute("_OceanTD_PadBgT", host.BackgroundTransparency)
	host:SetAttribute("_OceanTD_PadStrokeT", host.TextStrokeTransparency)
	local stroke = host:FindFirstChildOfClass("UIStroke")
	if stroke then
		host:SetAttribute("_OceanTD_PadStrokeOn", stroke.Enabled)
	end
end

local function showLetter(host: Host)
	local icon = host:FindFirstChild("_OceanTD_PadIcon")
	if icon and icon:IsA("GuiObject") then
		icon.Visible = false
	end
	if host:GetAttribute("_OceanTD_PadShown") ~= true then
		return
	end
	host:SetAttribute("_OceanTD_PadShown", false)
	local textT = host:GetAttribute("_OceanTD_PadTextT")
	local bgT = host:GetAttribute("_OceanTD_PadBgT")
	local strokeT = host:GetAttribute("_OceanTD_PadStrokeT")
	if typeof(textT) == "number" then
		host.TextTransparency = textT
	end
	if host:GetAttribute("_OceanTD_PadKeepBg") ~= true and typeof(bgT) == "number" then
		host.BackgroundTransparency = bgT
	end
	if typeof(strokeT) == "number" then
		host.TextStrokeTransparency = strokeT
	end
	local strokeOn = host:GetAttribute("_OceanTD_PadStrokeOn")
	local stroke = host:FindFirstChildOfClass("UIStroke")
	if stroke and typeof(strokeOn) == "boolean" then
		stroke.Enabled = strokeOn
	end
end

-- Xbox L3/R3 use the PlayStation art. Other Xbox cells stay on the Xbox sheet.
local function imageKindFor(kind: "playstation" | "xbox", cell: Vector2): "playstation" | "xbox"
	if kind == "xbox" and cell.Y == 3 and (cell.X == 1 or cell.X == 2) then
		return "playstation"
	end
	return kind
end

-- PlayStation bumper row and D-pad down sit high in the cell, so the next row peeks in.
local function cellYNudge(kind: "playstation" | "xbox", cell: Vector2): number
	if kind == "playstation" and cell.Y == 1 then
		return 0.12
	end
	if kind == "playstation" and cell.X == 0 and cell.Y == 2 then
		return 0.12
	end
	return 0
end

-- L2/R2 read larger than the other face icons at the shared 10% scale.
local function iconScaleFor(cell: Vector2): number
	-- L2/R2: under the shared size, then 15%, then another 10% (zoom − / +).
	if cell.Y == 1 and (cell.X == 2 or cell.X == 3) then
		return PAD_ICON_SCALE * 0.9 * 0.85 * 0.9
	end
	-- Cross (X) and Circle sit a little large in the cell.
	if cell.Y == 0 and (cell.X == 0 or cell.X == 3) then
		return PAD_ICON_SCALE * 0.9
	end
	return PAD_ICON_SCALE
end

function GamepadButtonGlyph.placeCell(sheet: ImageLabel, token: string)
	local cell = CELLS[token]
	if not cell then
		return
	end
	local kind = sheetKind() or "xbox"
	local imageKind = imageKindFor(kind, cell)
	sheet.Image = sheetUri(imageKind)
	sheet.ImageRectSize = Vector2.zero
	sheet.ImageRectOffset = Vector2.zero
	sheet.ScaleType = Enum.ScaleType.Stretch
	sheet.Size = UDim2.fromScale(4, 4)
	sheet.AnchorPoint = Vector2.new(0, 0)
	sheet.Position = UDim2.fromScale(-cell.X, -cell.Y + cellYNudge(imageKind, cell))
end

local function showIcon(host: Host, kind: "playstation" | "xbox", cell: Vector2)
	remember(host)
	local window = ensureIcon(host)
	local forced = host:GetAttribute("_OceanTD_PadScaleMul")
	local scale = if typeof(forced) == "number" and forced > 0 then forced else iconScaleFor(cell)
	window:SetAttribute("_OceanTD_PadIconScale", scale)
	layoutWindow(host, window)
	host.ClipsDescendants = false
	local sheet = window:FindFirstChild("Sheet")
	if sheet and sheet:IsA("ImageLabel") then
		local imageKind = imageKindFor(kind, cell)
		sheet.Image = sheetUri(imageKind)
		sheet.ImageRectSize = Vector2.zero
		sheet.ImageRectOffset = Vector2.zero
		sheet.Position = UDim2.fromScale(-cell.X, -cell.Y + cellYNudge(imageKind, cell))
	end
	window.Visible = true
	host:SetAttribute("_OceanTD_PadShown", true)
	host.TextTransparency = 1
	host.TextStrokeTransparency = 1
	if host:GetAttribute("_OceanTD_PadKeepBg") ~= true then
		host.BackgroundTransparency = 1
		local stroke = host:FindFirstChildOfClass("UIStroke")
		if stroke then
			stroke.Enabled = false
		end
	end
end

local function render(host: Host)
	if not host.Parent then
		watched[host] = nil
		return
	end
	local token = host.Text
	-- Backpack and hue prompts keep the old d-pad graphic. The teach pulse draws the sheet itself.
	if token == "D-Pad" or token == "DPad" then
		showLetter(host)
		return
	end
	local cell = CELLS[token]
	local kind = if cell then sheetKind() else nil
	if not cell or not kind then
		showLetter(host)
		return
	end
	showIcon(host, kind, cell)
end

function GamepadButtonGlyph.isPlayStation(): boolean
	return sheetKind() == "playstation"
end

function GamepadButtonGlyph.watch(host: Host, keepBackground: boolean?)
	if keepBackground ~= nil then
		host:SetAttribute("_OceanTD_PadKeepBg", keepBackground == true)
	end
	if watched[host] then
		render(host)
		return
	end
	watched[host] = true
	host:GetPropertyChangedSignal("Text"):Connect(function()
		if watched[host] then
			render(host)
		end
	end)
	host.Destroying:Connect(function()
		watched[host] = nil
	end)
	render(host)
end

function GamepadButtonGlyph.apply(host: Host, keepBackground: boolean?)
	GamepadButtonGlyph.watch(host, keepBackground)
end

function GamepadButtonGlyph.refresh()
	for host in pairs(watched) do
		if host.Parent then
			render(host)
		else
			watched[host] = nil
		end
	end
end

UserInputService.LastInputTypeChanged:Connect(function()
	GamepadButtonGlyph.refresh()
end)
UserInputService.GamepadConnected:Connect(function()
	uriCache = {}
	GamepadButtonGlyph.refresh()
end)
UserInputService.GamepadDisconnected:Connect(function()
	uriCache = {}
	GamepadButtonGlyph.refresh()
end)

return GamepadButtonGlyph
