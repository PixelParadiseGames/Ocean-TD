--!strict
--[[
	Fullscreen lifetime $D economy dashboard (Reef Report style).
	Opened from Reef Report title-row "$D" button — for you + testers.
]]

local Players = game:GetService("Players")
local GuiService = game:GetService("GuiService")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local oceanRoot = game:GetService("ReplicatedStorage"):WaitForChild("OceanTD")
local Remotes = require(oceanRoot:WaitForChild("Remotes"))
local UiTheme = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiTheme"))
local WaveEconomyPlanner = require(script.Parent:WaitForChild("WaveEconomyPlanner"))

local SandDollarReportUI = {}

local GUI_NAME = "OceanTD_SandDollarReport"
local OPEN_ATTR = "OceanTD_SandDollarReportOpen"
local LAYOUT_VER = 5
-- Above Reef Report (120) and left HUD while report is open (120+80).
local DISPLAY_ORDER = 320
local TITLE_TOP = 8
local TITLE_HEIGHT = 44
local SIDE_PAD = 0.10 -- 10% each side
local EDGE_MARGIN = 16
local SCROLL_TOP = TITLE_TOP + TITLE_HEIGHT + 8
local CARD_BG = Color3.fromRGB(10, 24, 36)
local CARD_STROKE = Color3.fromRGB(40, 120, 140)
local ACCENT = Color3.fromRGB(70, 255, 110)
local ACCENT_DIM = Color3.fromRGB(40, 180, 100)
local WARN = Color3.fromRGB(255, 190, 90)
local MUTED = Color3.fromRGB(150, 175, 195)
local WHITE = Color3.fromRGB(240, 248, 255)

local open = false
local gui: ScreenGui? = nil
local listHost: Frame? = nil
local heroSlot: Frame? = nil
local waveSlot: Frame? = nil
local statsSlot: Frame? = nil
local statsScroll: ScrollingFrame? = nil
local waveStrip: ScrollingFrame? = nil
local writeHost: Frame? = nil
local waveStripBuilt = false
local refreshConn: RBXScriptConnection? = nil
local lastFetchAt = 0
local layoutOrder = 0

local function currentHost(): Frame?
	return writeHost or listHost
end

local function hardenFullBleed(sg: ScreenGui)
	sg.IgnoreGuiInset = true
	sg.ClipToDeviceSafeArea = false
	pcall(function()
		(sg :: any).ScreenInsets = Enum.ScreenInsets.None
	end)
end

local function nextOrder(): number
	layoutOrder += 1
	return layoutOrder
end

local function fmtSec(sec: number): string
	local s = math.max(0, math.floor(sec + 0.5))
	local h = math.floor(s / 3600)
	local m = math.floor((s % 3600) / 60)
	local r = s % 60
	if h > 0 then
		return string.format("%dh %02dm", h, m)
	end
	if m > 0 then
		return string.format("%dm %02ds", m, r)
	end
	return string.format("%ds", r)
end

local function fmtNum(n: number): string
	local v = math.floor(n + 0.5)
	local s = tostring(v)
	local out = s
	while true do
		local nextS, k = string.gsub(out, "^(-?%d+)(%d%d%d)", "%1,%2")
		out = nextS
		if k == 0 then
			break
		end
	end
	return out
end

local function fmtRate(n: number): string
	if typeof(n) ~= "number" or n ~= n or n <= 0 then
		return "—"
	end
	if n >= 100 then
		return string.format("%.0f", n)
	end
	if n >= 10 then
		return string.format("%.1f", n)
	end
	return string.format("%.2f", n)
end

local function fmtMin(n: number?): string
	if typeof(n) ~= "number" or n ~= n or n <= 0 then
		return "—"
	end
	if n >= 60 then
		return string.format("%.1fh", n / 60)
	end
	return string.format("%.1f min", n)
end

local function clearSlot(slot: Frame?)
	if not slot then
		return
	end
	for _, ch in ipairs(slot:GetChildren()) do
		if not ch:IsA("UIListLayout") and not ch:IsA("UIPadding") then
			ch:Destroy()
		end
	end
end

local function addCaption(text: string)
	local host = currentHost()
	if not host then
		return
	end
	local lab = Instance.new("TextLabel")
	lab.BackgroundTransparency = 1
	lab.Size = UDim2.new(1, 0, 0, 26)
	lab.Font = UiTheme.Font
	lab.Text = text
	lab.TextColor3 = MUTED
	lab.TextXAlignment = Enum.TextXAlignment.Left
	lab.TextSize = 17
	lab.LayoutOrder = nextOrder()
	lab.ZIndex = 3
	lab.Parent = host
end

local function addSection(title: string)
	local host = currentHost()
	if not host then
		return
	end
	local lab = Instance.new("TextLabel")
	lab.BackgroundTransparency = 1
	lab.Size = UDim2.new(1, 0, 0, 34)
	lab.Font = UiTheme.Font
	lab.Text = title
	lab.TextXAlignment = Enum.TextXAlignment.Left
	lab.TextColor3 = Color3.fromRGB(170, 220, 240)
	lab.TextSize = 22
	lab.LayoutOrder = nextOrder()
	lab.ZIndex = 3
	lab.Parent = host
end

local function makeCard(): Frame
	local host = currentHost() :: Frame
	local card = Instance.new("Frame")
	card.BackgroundColor3 = CARD_BG
	card.BackgroundTransparency = 0.12
	card.BorderSizePixel = 0
	card.Size = UDim2.new(1, 0, 0, 0)
	card.AutomaticSize = Enum.AutomaticSize.Y
	card.LayoutOrder = nextOrder()
	card.ZIndex = 3
	card.Parent = host
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 14)
	corner.Parent = card
	local stroke = Instance.new("UIStroke")
	stroke.Color = CARD_STROKE
	stroke.Thickness = 1.5
	stroke.Transparency = 0.35
	stroke.Parent = card
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 14)
	pad.PaddingBottom = UDim.new(0, 14)
	pad.PaddingLeft = UDim.new(0, 16)
	pad.PaddingRight = UDim.new(0, 16)
	pad.Parent = card
	local lay = Instance.new("UIListLayout")
	lay.FillDirection = Enum.FillDirection.Vertical
	lay.SortOrder = Enum.SortOrder.LayoutOrder
	lay.Padding = UDim.new(0, 10)
	lay.Parent = card
	return card
end

local function addHeroTriplet(avg: number, low: number, high: number, playersN: number)
	local card = makeCard()
	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Size = UDim2.new(1, 0, 0, 24)
	title.Font = UiTheme.Font
	title.Text = "Wave $D / minute  ·  lifetime"
	title.TextColor3 = MUTED
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextSize = 18
	title.LayoutOrder = 1
	title.ZIndex = 4
	title.Parent = card

	local row = Instance.new("Frame")
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, 0, 86)
	row.LayoutOrder = 2
	row.ZIndex = 4
	row.Parent = card
	local rowLay = Instance.new("UIListLayout")
	rowLay.FillDirection = Enum.FillDirection.Horizontal
	rowLay.HorizontalAlignment = Enum.HorizontalAlignment.Center
	rowLay.VerticalAlignment = Enum.VerticalAlignment.Center
	rowLay.Padding = UDim.new(0, 8)
	rowLay.Parent = row

	local function heroCell(label: string, value: string, color: Color3, order: number)
		local cell = Instance.new("Frame")
		cell.BackgroundTransparency = 1
		cell.Size = UDim2.new(1 / 3, -6, 1, 0)
		cell.LayoutOrder = order
		cell.ZIndex = 5
		cell.Parent = row
		local v = Instance.new("TextLabel")
		v.BackgroundTransparency = 1
		v.Size = UDim2.new(1, 0, 0, 48)
		v.Position = UDim2.fromOffset(0, 4)
		v.Font = Enum.Font.GothamBold
		v.Text = value
		v.TextColor3 = color
		v.TextScaled = true
		v.ZIndex = 6
		v.Parent = cell
		local vc = Instance.new("UITextSizeConstraint")
		vc.MaxTextSize = 38
		vc.MinTextSize = 20
		vc.Parent = v
		local l = Instance.new("TextLabel")
		l.BackgroundTransparency = 1
		l.Size = UDim2.new(1, 0, 0, 22)
		l.Position = UDim2.fromOffset(0, 56)
		l.Font = UiTheme.Font
		l.Text = label
		l.TextColor3 = MUTED
		l.TextSize = 16
		l.ZIndex = 6
		l.Parent = cell
	end

	heroCell("Low p10", fmtRate(low), WARN, 1)
	heroCell("Average", fmtRate(avg), ACCENT, 2)
	heroCell("High p90", fmtRate(high), ACCENT_DIM, 3)

	local foot = Instance.new("TextLabel")
	foot.BackgroundTransparency = 1
	foot.Size = UDim2.new(1, 0, 0, 20)
	foot.Font = UiTheme.Font
	foot.Text = string.format(
		"%s players with 30s+ wave time  ·  unpaused wave play only",
		fmtNum(playersN)
	)
	foot.TextColor3 = MUTED
	foot.TextXAlignment = Enum.TextXAlignment.Left
	foot.TextSize = 15
	foot.LayoutOrder = 3
	foot.ZIndex = 4
	foot.Parent = card
end

local COL_W = 132
local COL_H = 118
local WAVE_STRIP_H = 148

local function applyWaveTimes(perWave: any)
	local strip = waveStrip
	if not strip then
		return
	end
	local row = strip:FindFirstChild("Columns")
	if not row then
		return
	end
	local liveMap = if typeof(perWave) == "table" then perWave else nil
	local waves = WaveEconomyPlanner.all(WaveEconomyPlanner.WAVE_COUNT)
	for _, col in ipairs(waves) do
		local cell = row:FindFirstChild("Wave" .. tostring(col.wave))
		if not (cell and cell:IsA("Frame")) then
			continue
		end
		local live = if liveMap then liveMap[col.wave] or liveMap[tostring(col.wave)] else nil
		local avgSec = col.avgSec
		local fastSec = col.fastSec
		local slowSec = col.slowSec
		local liveOk = false
		if typeof(live) == "table" then
			local samples = tonumber(live.samples) or 0
			local a = tonumber(live.avg)
			local f = tonumber(live.fast)
			local s = tonumber(live.slow)
			if samples > 0 and a and a > 0 then
				avgSec = a
				fastSec = if f and f > 0 then f else a
				slowSec = if s and s > 0 then s else a
				liveOk = true
			end
		end
		local avgLab = cell:FindFirstChild("Avg")
		if avgLab and avgLab:IsA("TextLabel") then
			avgLab.Text = "Avg " .. fmtSec(avgSec) .. (if liveOk then "" else " · sim")
			avgLab.TextColor3 = if liveOk then ACCENT else WARN
		end
		local rangeLab = cell:FindFirstChild("Range")
		if rangeLab and rangeLab:IsA("TextLabel") then
			rangeLab.Text = string.format("%s – %s", fmtSec(fastSec), fmtSec(slowSec))
		end
	end
	local caption = if waveSlot then waveSlot:FindFirstChild("WaveCaption") else nil
	if caption and caption:IsA("TextLabel") then
		caption.Text =
			"Times = live player avg when tracked; otherwise 1× sim est. $D = Earn More 1–8 × spawn min/max."
	end
end

local function ensureWaveColumns()
	if waveStripBuilt and waveSlot and waveSlot:FindFirstChild("WaveCard") then
		return
	end
	local slot = waveSlot
	if not slot then
		return
	end
	clearSlot(slot)
	writeHost = slot
	layoutOrder = 0
	addSection("Waves 1–50")
	local cap = Instance.new("TextLabel")
	cap.Name = "WaveCaption"
	cap.BackgroundTransparency = 1
	cap.Size = UDim2.new(1, 0, 0, 26)
	cap.Font = UiTheme.Font
	cap.Text = "Times = live player avg when tracked; otherwise 1× sim est. $D = Earn More 1–8 × spawn min/max."
	cap.TextColor3 = MUTED
	cap.TextXAlignment = Enum.TextXAlignment.Left
	cap.TextSize = 17
	cap.LayoutOrder = nextOrder()
	cap.ZIndex = 3
	cap.Parent = slot

	local card = makeCard()
	card.Name = "WaveCard"
	local strip = Instance.new("ScrollingFrame")
	strip.Name = "WaveStrip"
	strip.BackgroundTransparency = 1
	strip.BorderSizePixel = 0
	strip.Size = UDim2.new(1, 0, 0, WAVE_STRIP_H)
	strip.CanvasSize = UDim2.new(0, 0, 0, 0)
	strip.AutomaticCanvasSize = Enum.AutomaticSize.X
	strip.ScrollingDirection = Enum.ScrollingDirection.X
	strip.ScrollBarThickness = 6
	strip.ScrollBarImageColor3 = Color3.fromRGB(140, 180, 210)
	strip.ClipsDescendants = true
	strip.LayoutOrder = 1
	strip.ZIndex = 4
	strip.Active = true
	strip.Parent = card
	waveStrip = strip

	local row = Instance.new("Frame")
	row.Name = "Columns"
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(0, 0, 1, -10)
	row.AutomaticSize = Enum.AutomaticSize.X
	row.ZIndex = 5
	row.Parent = strip
	local rowLay = Instance.new("UIListLayout")
	rowLay.FillDirection = Enum.FillDirection.Horizontal
	rowLay.SortOrder = Enum.SortOrder.LayoutOrder
	rowLay.Padding = UDim.new(0, 8)
	rowLay.VerticalAlignment = Enum.VerticalAlignment.Top
	rowLay.Parent = row
	local rowPad = Instance.new("UIPadding")
	rowPad.PaddingTop = UDim.new(0, 2)
	rowPad.PaddingBottom = UDim.new(0, 4)
	rowPad.PaddingLeft = UDim.new(0, 2)
	rowPad.PaddingRight = UDim.new(0, 8)
	rowPad.Parent = row

	local waves = WaveEconomyPlanner.all(WaveEconomyPlanner.WAVE_COUNT)
	for _, col in ipairs(waves) do
		local cell = Instance.new("Frame")
		cell.Name = "Wave" .. tostring(col.wave)
		cell.BackgroundColor3 = Color3.fromRGB(8, 20, 30)
		cell.BackgroundTransparency = 0.2
		cell.BorderSizePixel = 0
		cell.Size = UDim2.fromOffset(COL_W, COL_H)
		cell.LayoutOrder = col.wave
		cell.ZIndex = 6
		cell.Parent = row
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 10)
		corner.Parent = cell
		local stroke = Instance.new("UIStroke")
		stroke.Color = CARD_STROKE
		stroke.Thickness = 1
		stroke.Transparency = 0.45
		stroke.Parent = cell
		local pad = Instance.new("UIPadding")
		pad.PaddingTop = UDim.new(0, 8)
		pad.PaddingBottom = UDim.new(0, 6)
		pad.PaddingLeft = UDim.new(0, 8)
		pad.PaddingRight = UDim.new(0, 8)
		pad.Parent = cell
		local lay = Instance.new("UIListLayout")
		lay.FillDirection = Enum.FillDirection.Vertical
		lay.SortOrder = Enum.SortOrder.LayoutOrder
		lay.Padding = UDim.new(0, 3)
		lay.Parent = cell

		local function line(name: string, text: string, color: Color3, size: number, order: number, bold: boolean?)
			local lab = Instance.new("TextLabel")
			lab.Name = name
			lab.BackgroundTransparency = 1
			lab.Size = UDim2.new(1, 0, 0, size + 4)
			lab.Font = if bold then Enum.Font.GothamBold else UiTheme.Font
			lab.Text = text
			lab.TextColor3 = color
			lab.TextXAlignment = Enum.TextXAlignment.Left
			lab.TextSize = size
			lab.TextTruncate = Enum.TextTruncate.AtEnd
			lab.LayoutOrder = order
			lab.ZIndex = 7
			lab.Parent = cell
		end

		line("Title", string.format("Wave %d", col.wave), WHITE, 16, 1, true)
		line("Avg", "Avg " .. fmtSec(col.avgSec) .. " · sim", WARN, 14, 2, false)
		line("Range", string.format("%s – %s", fmtSec(col.fastSec), fmtSec(col.slowSec)), MUTED, 12, 3, false)
		line("Dollars", string.format("$D %s – %s", fmtNum(col.dollarsMin), fmtNum(col.dollarsMax)), ACCENT_DIM, 13, 4, true)
	end
	writeHost = nil
	waveStripBuilt = true
end

type StatRow = { label: string, value: string, emphasize: boolean? }

local function addStatGrid(rows: { StatRow })
	local card = makeCard()
	for i, pair in ipairs(rows) do
		local row = Instance.new("Frame")
		row.BackgroundTransparency = 1
		row.Size = UDim2.new(1, 0, 0, 34)
		row.LayoutOrder = i
		row.ZIndex = 4
		row.Parent = card
		local lay = Instance.new("UIListLayout")
		lay.FillDirection = Enum.FillDirection.Horizontal
		lay.HorizontalAlignment = Enum.HorizontalAlignment.Center
		lay.VerticalAlignment = Enum.VerticalAlignment.Center
		lay.SortOrder = Enum.SortOrder.LayoutOrder
		lay.Padding = UDim.new(0, 12)
		lay.Parent = row

		local value = Instance.new("TextLabel")
		value.BackgroundTransparency = 1
		value.AutomaticSize = Enum.AutomaticSize.X
		value.Size = UDim2.new(0, 0, 1, 0)
		value.Font = Enum.Font.GothamBold
		value.Text = pair.value
		value.TextColor3 = if pair.emphasize then ACCENT else WHITE
		value.TextXAlignment = Enum.TextXAlignment.Right
		value.TextYAlignment = Enum.TextYAlignment.Center
		value.TextSize = 19
		value.LayoutOrder = 1
		value.ZIndex = 5
		value.Parent = row

		local label = Instance.new("TextLabel")
		label.BackgroundTransparency = 1
		label.AutomaticSize = Enum.AutomaticSize.X
		label.Size = UDim2.new(0, 0, 1, 0)
		label.Font = UiTheme.Font
		label.Text = pair.label
		label.TextColor3 = Color3.fromRGB(200, 220, 235)
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.TextYAlignment = Enum.TextYAlignment.Center
		label.TextSize = 19
		label.LayoutOrder = 2
		label.ZIndex = 5
		label.Parent = row
	end
end

local function render(payload: any)
	local mainScroll = statsScroll
	local savedMainY = if mainScroll then mainScroll.CanvasPosition.Y else 0
	local savedWaveX = if waveStrip then waveStrip.CanvasPosition.X else 0

	clearSlot(heroSlot)
	clearSlot(statsSlot)

	if typeof(payload) ~= "table" or typeof(payload.global) ~= "table" then
		writeHost = statsSlot
		layoutOrder = 0
		addCaption("Waiting for economy data…")
		writeHost = nil
		ensureWaveColumns()
		return
	end
	local g = payload.global
	local you = payload.you
	local rates = g.waveDollarsPerMin or {}
	local speed = g.waveSpeed or {}

	writeHost = heroSlot
	layoutOrder = 0
	addHeroTriplet(
		tonumber(rates.avg) or 0,
		tonumber(rates.low) or 0,
		tonumber(rates.high) or 0,
		tonumber(g.playersWithRate) or 0
	)
	writeHost = nil

	ensureWaveColumns()
	applyWaveTimes(g.perWave)

	writeHost = statsSlot
	layoutOrder = 0
	addSection("Lifetime pool")
	addStatGrid({
		{ label = "Players tracked", value = fmtNum(tonumber(g.playersTracked) or 0), emphasize = true },
		{ label = "$D / fish (after Earn More)", value = fmtRate(tonumber(g.dollarsPerFish) or 0), emphasize = true },
		{ label = "Total wave $D earned", value = fmtNum(tonumber(g.totalWaveEarned) or 0) },
		{ label = "Total wave playtime", value = fmtSec(tonumber(g.totalWavePlaySec) or 0) },
		{ label = "Median wave $/min (p50)", value = fmtRate(tonumber(rates.median) or 0) },
		{ label = "Pooled wave $/min", value = fmtRate(tonumber(rates.pooled) or 0) },
	})

	addSection("Skill pacing")
	addStatGrid({
		{ label = "Avg time to max one skill", value = fmtMin(g.minutesToMaxOneSkill), emphasize = true },
		{ label = "Players who maxed one", value = fmtNum(tonumber(g.skillMaxOnePlayers) or 0) },
		{ label = "Avg time to max all skills", value = fmtMin(g.minutesToMaxAllSkills), emphasize = true },
		{ label = "Players who maxed all", value = fmtNum(tonumber(g.skillMaxAllPlayers) or 0) },
	})
	addCaption("Clock = lifetime unpaused wave play when they first hit the milestone.")

	addSection("Wave Speed inflate")
	local inf15 = tonumber(speed.inflate15) or 0
	local inf2 = tonumber(speed.inflate2) or 0
	addStatGrid({
		{ label = "1x $/min", value = fmtRate(tonumber(speed.rate1) or 0), emphasize = true },
		{ label = "1.5x $/min", value = fmtRate(tonumber(speed.rate15) or 0) },
		{ label = "2x $/min", value = fmtRate(tonumber(speed.rate2) or 0) },
		{
			label = "1.5x vs 1x",
			value = if inf15 > 0 then string.format("%.2fx", inf15) else "—",
			emphasize = true,
		},
		{
			label = "2x vs 1x",
			value = if inf2 > 0 then string.format("%.2fx", inf2) else "—",
			emphasize = true,
		},
		{ label = "Play @ 1x", value = fmtSec(tonumber(speed.playSec1) or 0) },
		{ label = "Play @ 1.5x", value = fmtSec(tonumber(speed.playSec15) or 0) },
		{ label = "Play @ 2x", value = fmtSec(tonumber(speed.playSec2) or 0) },
	})
	addCaption("If inflate ~ speed multiplier, earn scales with sim speed (expected). Much higher = tuning leak.")

	addSection("Dead waves & intro pad")
	addStatGrid({
		{ label = "Dead wave playtime", value = fmtSec(tonumber(g.deadWavePlaySec) or 0), emphasize = true },
		{ label = "Dead waves (0 $D)", value = fmtNum(tonumber(g.deadWaveCount) or 0) },
		{ label = "Players using intro pad", value = fmtNum(tonumber(g.introPadPlayers) or 0), emphasize = true },
	})
	addCaption("Dead = finished a wave with unpaused playtime but $0 earned.")

	if typeof(you) == "table" then
		addSection("You (lifetime)")
		local ys = you.speed or {}
		addStatGrid({
			{ label = "Your wave $/min", value = fmtRate(tonumber(you.waveDollarsPerMin) or 0), emphasize = true },
			{ label = "Your $D / fish", value = fmtRate(tonumber(you.dollarsPerFish) or 0) },
			{ label = "Wave $D earned", value = fmtNum(tonumber(you.waveEarned) or 0) },
			{ label = "Wave playtime", value = fmtSec(tonumber(you.wavePlaySec) or 0) },
			{ label = "Fish fed", value = fmtNum(tonumber(you.fishFed) or 0) },
			{ label = "Earn More stage", value = tostring(math.floor(tonumber(you.earnMoreStage) or 1)) },
			{ label = "Balance", value = fmtNum(tonumber(you.balance) or 0) },
			{ label = "Your 1x $/min", value = fmtRate(tonumber(ys.rate1) or 0) },
			{ label = "Your 1.5x $/min", value = fmtRate(tonumber(ys.rate15) or 0) },
			{ label = "Your 2x $/min", value = fmtRate(tonumber(ys.rate2) or 0) },
			{ label = "Dead wave time", value = fmtSec(tonumber(you.deadWavePlaySec) or 0) },
			{ label = "Intro pad free buys", value = fmtNum(tonumber(you.introPadFreeBuys) or 0) },
		})
	end
	writeHost = nil

	-- Restore scrolls after layout (refresh must not yank the wave strip back to 0).
	task.defer(function()
		if mainScroll and mainScroll.Parent then
			mainScroll.CanvasPosition = Vector2.new(mainScroll.CanvasPosition.X, savedMainY)
		end
		if waveStrip and waveStrip.Parent then
			waveStrip.CanvasPosition = Vector2.new(savedWaveX, waveStrip.CanvasPosition.Y)
		end
	end)
end

local function fetchAndRender()
	local ok, stats = pcall(function()
		return Remotes.getFunction("RequestGetSandDollarStats"):InvokeServer()
	end)
	if ok then
		render(stats)
	else
		render(nil)
	end
end

local function stopRefresh()
	if refreshConn then
		refreshConn:Disconnect()
		refreshConn = nil
	end
end

local function startRefresh()
	stopRefresh()
	fetchAndRender()
	refreshConn = RunService.Heartbeat:Connect(function()
		if not open then
			return
		end
		local now = os.clock()
		if now - lastFetchAt < 2.5 then
			return
		end
		lastFetchAt = now
		fetchAndRender()
	end)
end

local function ensureGui(): ScreenGui
	if gui and gui.Parent then
		if gui:GetAttribute("_OceanTD_LayoutVer") == LAYOUT_VER then
			hardenFullBleed(gui)
			return gui
		end
		gui:Destroy()
		gui = nil
		listHost = nil
		heroSlot = nil
		waveSlot = nil
		statsSlot = nil
		statsScroll = nil
		waveStrip = nil
		waveStripBuilt = false
	end
	local sg = Instance.new("ScreenGui")
	sg.Name = GUI_NAME
	sg.ResetOnSpawn = false
	hardenFullBleed(sg)
	sg.DisplayOrder = DISPLAY_ORDER
	sg.Enabled = false
	sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	sg:SetAttribute("_OceanTD_LayoutVer", LAYOUT_VER)
	sg.Parent = playerGui
	gui = sg
	waveStripBuilt = false
	waveStrip = nil

	local dim = Instance.new("Frame")
	dim.Name = "Dim"
	dim.BackgroundColor3 = Color3.fromRGB(4, 10, 18)
	dim.BackgroundTransparency = 0.18
	dim.BorderSizePixel = 0
	dim.Size = UDim2.fromScale(1, 1)
	dim.ZIndex = 1
	dim.Active = false
	dim.Parent = sg

	local root = Instance.new("Frame")
	root.Name = "Root"
	root.BackgroundTransparency = 1
	root.Size = UDim2.fromScale(1, 1)
	root.ZIndex = 2
	root.Active = false
	root.Parent = sg

	-- Title centered in the padded content band.
	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.BackgroundTransparency = 1
	title.AnchorPoint = Vector2.new(0.5, 0)
	title.Position = UDim2.new(0.5, 0, 0, TITLE_TOP)
	title.Size = UDim2.new(1 - SIDE_PAD * 2, -56, 0, TITLE_HEIGHT)
	title.Font = UiTheme.Font
	title.Text = "$D Economy"
	title.TextColor3 = WHITE
	title.TextScaled = true
	title.ZIndex = 3
	title.Parent = root
	local titleSize = Instance.new("UITextSizeConstraint")
	titleSize.MaxTextSize = 36
	titleSize.MinTextSize = 20
	titleSize.Parent = title

	local sc = Instance.new("ScrollingFrame")
	sc.Name = "StatsScroll"
	sc.BackgroundTransparency = 1
	sc.BorderSizePixel = 0
	sc.Position = UDim2.new(SIDE_PAD, 0, 0, SCROLL_TOP)
	sc.Size = UDim2.new(1 - SIDE_PAD * 2, 0, 1, -(SCROLL_TOP + EDGE_MARGIN))
	sc.ScrollBarThickness = 8
	sc.ScrollBarImageColor3 = Color3.fromRGB(140, 180, 210)
	sc.ScrollingDirection = Enum.ScrollingDirection.Y
	sc.CanvasSize = UDim2.new(0, 0, 0, 0)
	sc.AutomaticCanvasSize = Enum.AutomaticSize.Y
	sc.ClipsDescendants = true
	sc.ZIndex = 2
	sc.Active = true
	sc.Parent = root
	statsScroll = sc

	-- Close on ScreenGui (not Root/scroll) so nothing steals hits; always above content.
	local closeBtn = Instance.new("TextButton")
	closeBtn.Name = "Close"
	closeBtn.Text = "X"
	closeBtn.Font = Enum.Font.GothamBold
	closeBtn.TextScaled = true
	closeBtn.TextColor3 = WHITE
	closeBtn.BackgroundColor3 = Color3.fromRGB(220, 45, 55)
	closeBtn.BackgroundTransparency = 0
	closeBtn.BorderSizePixel = 0
	closeBtn.AutoButtonColor = true
	closeBtn.Active = true
	closeBtn.Selectable = true
	closeBtn.AnchorPoint = Vector2.new(1, 0)
	closeBtn.Position = UDim2.new(1 - SIDE_PAD, 0, 0, TITLE_TOP)
	closeBtn.Size = UDim2.fromOffset(44, 44)
	closeBtn.ZIndex = 100
	closeBtn.Parent = sg
	local closeCorner = Instance.new("UICorner")
	closeCorner.CornerRadius = UDim.new(1, 0)
	closeCorner.Parent = closeBtn
	local closeStroke = Instance.new("UIStroke")
	closeStroke.Thickness = 2
	closeStroke.Color = Color3.fromRGB(255, 255, 255)
	closeStroke.Transparency = 0.2
	closeStroke.Parent = closeBtn
	local closePad = Instance.new("UIPadding")
	closePad.PaddingTop = UDim.new(0.16, 0)
	closePad.PaddingBottom = UDim.new(0.16, 0)
	closePad.PaddingLeft = UDim.new(0.16, 0)
	closePad.PaddingRight = UDim.new(0.16, 0)
	closePad.Parent = closeBtn
	local function onClose()
		SandDollarReportUI.close()
	end
	closeBtn.Activated:Connect(onClose)
	closeBtn.MouseButton1Click:Connect(onClose)

	local host = Instance.new("Frame")
	host.Name = "List"
	host.BackgroundTransparency = 1
	host.Size = UDim2.new(1, 0, 0, 0)
	host.AutomaticSize = Enum.AutomaticSize.Y
	host.Parent = sc
	listHost = host
	local hostLay = Instance.new("UIListLayout")
	hostLay.FillDirection = Enum.FillDirection.Vertical
	hostLay.SortOrder = Enum.SortOrder.LayoutOrder
	hostLay.Padding = UDim.new(0, 12)
	hostLay.Parent = host
	local hostPad = Instance.new("UIPadding")
	hostPad.PaddingTop = UDim.new(0, 4)
	hostPad.PaddingBottom = UDim.new(0, 20)
	hostPad.Parent = host

	local function makeSlot(name: string, order: number): Frame
		local slot = Instance.new("Frame")
		slot.Name = name
		slot.BackgroundTransparency = 1
		slot.Size = UDim2.new(1, 0, 0, 0)
		slot.AutomaticSize = Enum.AutomaticSize.Y
		slot.LayoutOrder = order
		slot.ZIndex = 3
		slot.Parent = host
		local lay = Instance.new("UIListLayout")
		lay.FillDirection = Enum.FillDirection.Vertical
		lay.SortOrder = Enum.SortOrder.LayoutOrder
		lay.Padding = UDim.new(0, 12)
		lay.Parent = slot
		return slot
	end
	heroSlot = makeSlot("HeroSlot", 1)
	waveSlot = makeSlot("WaveSlot", 2)
	statsSlot = makeSlot("StatsSlot", 3)

	return sg
end

function SandDollarReportUI.isOpen(): boolean
	return open
end

function SandDollarReportUI.open()
	local ok, err = pcall(function()
		local sg = ensureGui()
		sg.DisplayOrder = DISPLAY_ORDER
		hardenFullBleed(sg)
		open = true
		playerGui:SetAttribute(OPEN_ATTR, true)
		sg.Enabled = true
		lastFetchAt = 0
		-- Defer network fetch so the shell paints even if InvokeServer is slow.
		task.defer(function()
			if open then
				startRefresh()
			end
		end)
	end)
	if not ok then
		warn("[SandDollarReport] open failed:", err)
	end
end

function SandDollarReportUI.close()
	if not open then
		return
	end
	open = false
	playerGui:SetAttribute(OPEN_ATTR, false)
	stopRefresh()
	if gui then
		gui.Enabled = false
	end
	if GuiService.SelectedObject and gui and GuiService.SelectedObject:IsDescendantOf(gui) then
		GuiService.SelectedObject = nil
	end
end

function SandDollarReportUI.toggle()
	if open then
		SandDollarReportUI.close()
	else
		SandDollarReportUI.open()
	end
end

playerGui:SetAttribute(OPEN_ATTR, false)

return SandDollarReportUI
