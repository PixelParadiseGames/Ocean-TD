--!strict
--[[
	Wave summary panel content (title, stats columns, Continue/Finish).
	Extracted so WaveSlot stays under Luau's 200-local limit.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local Constants = require(oceanRoot:WaitForChild("Shared"):WaitForChild("Constants"))
local Remotes = require(oceanRoot:WaitForChild("Remotes"))
local UiTheme = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiTheme"))
local UiCircles = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiCircles"))

local WaveSim = require(script.Parent:WaitForChild("WaveSim"))

local WaveSummaryUi = {}

local FINISH_RED = Color3.fromRGB(200, 45, 50)
local FINISH_STROKE = Color3.fromRGB(255, 55, 60)
local CONTINUE_GREEN = Color3.fromRGB(40, 180, 80)
local CONTINUE_STROKE = Color3.fromRGB(70, 255, 110)
local REEF_PLUS_GREEN = Color3.fromRGB(50, 230, 100)
local REEF_PLUS_STROKE = Color3.fromRGB(12, 70, 28)

local SUMMARY_BTN_W = 200
local SUMMARY_BTN_H = 44
local SUMMARY_BTN_BOTTOM = 18
local SUMMARY_CAPTION_SIZE = 22
local SUMMARY_CAPTION_GAP = 4
local SUMMARY_COL_HEADER_SIZE = 23
local SUMMARY_TITLE_SIZE = 30
local SUMMARY_TITLE_TOP = 12
local SUMMARY_STATS_TOP = SUMMARY_TITLE_TOP + SUMMARY_TITLE_SIZE + 14
local SUMMARY_REEF_PLUS_SIZE = 28
local TITLE_STROKE_BRIGHT = Color3.fromRGB(255, 70, 70)

local reportWaveRecordsRemote = Remotes.get("ReportWaveRecords")

export type Records = { wave: number, fishFed: number, elapsedSec: number }

function WaveSummaryUi.titleStrokeBright(): Color3
	return TITLE_STROKE_BRIGHT
end

local function styleSummaryButton(btn: TextButton, fill: Color3, strokeColor: Color3)
	btn.BackgroundColor3 = fill
	btn.TextColor3 = Color3.new(1, 1, 1)
	local corner = btn:FindFirstChildOfClass("UICorner")
	if not corner then
		corner = Instance.new("UICorner")
		corner.Parent = btn
	end
	corner.CornerRadius = UDim.new(0, 10)
	local stroke = btn:FindFirstChildOfClass("UIStroke")
	if not stroke then
		stroke = Instance.new("UIStroke")
		stroke.Parent = btn
	end
	stroke.Name = "BtnEdge"
	stroke.Thickness = 2.5
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Color = strokeColor
end

function WaveSummaryUi.ensureButtons(
	panel: Frame,
	onContinue: () -> (),
	onFinish: () -> ()
): (TextButton, TextButton)
	local btnY = -(SUMMARY_BTN_BOTTOM)
	local captionY = -(SUMMARY_BTN_BOTTOM + SUMMARY_BTN_H + SUMMARY_CAPTION_GAP)
	local captionH = SUMMARY_CAPTION_SIZE + 6

	local function ensureCaption(name: string, text: string, xScale: number)
		local existing = panel:FindFirstChild(name)
		local lbl: TextLabel
		if existing and existing:IsA("TextLabel") then
			lbl = existing
		else
			if existing then
				existing:Destroy()
			end
			lbl = Instance.new("TextLabel")
			lbl.Name = name
			lbl.BackgroundTransparency = 1
			lbl.Font = UiTheme.Font
			lbl.TextColor3 = Color3.new(1, 1, 1)
			lbl.TextXAlignment = Enum.TextXAlignment.Center
			lbl.TextStrokeTransparency = 0.55
			lbl.TextStrokeColor3 = Color3.new(0, 0, 0)
			lbl.ZIndex = 4
			lbl.Parent = panel
		end
		lbl.Text = text
		lbl.TextSize = SUMMARY_CAPTION_SIZE
		lbl.AnchorPoint = Vector2.new(0.5, 1)
		lbl.Position = UDim2.new(xScale, 0, 1, captionY)
		lbl.Size = UDim2.fromOffset(SUMMARY_BTN_W + 24, captionH)
	end

	ensureCaption("WatchAdCaption", "Watch Ad:", 0.27)
	ensureCaption("EndSessionCaption", "End Session:", 0.73)

	local continue = panel:FindFirstChild("Continue")
	if not (continue and continue:IsA("TextButton")) then
		if continue then
			continue:Destroy()
		end
		local btn = Instance.new("TextButton")
		btn.Name = "Continue"
		btn.AnchorPoint = Vector2.new(0.5, 1)
		btn.Position = UDim2.new(0.27, 0, 1, btnY)
		btn.Size = UDim2.fromOffset(SUMMARY_BTN_W, SUMMARY_BTN_H)
		btn.Font = UiTheme.Font
		btn.Text = "CONTINUE"
		btn.TextSize = 22
		btn.AutoButtonColor = true
		btn.Selectable = true
		btn.ZIndex = 4
		btn.Parent = panel
		btn.Activated:Connect(onContinue)
		continue = btn
	else
		continue.AnchorPoint = Vector2.new(0.5, 1)
		continue.Position = UDim2.new(0.27, 0, 1, btnY)
		continue.Size = UDim2.fromOffset(SUMMARY_BTN_W, SUMMARY_BTN_H)
		continue.Text = "CONTINUE"
	end
	local continueBtn = continue :: TextButton
	styleSummaryButton(continueBtn, CONTINUE_GREEN, CONTINUE_STROKE)

	local finish = panel:FindFirstChild("Finish")
	if not (finish and finish:IsA("TextButton")) then
		if finish then
			finish:Destroy()
		end
		local btn = Instance.new("TextButton")
		btn.Name = "Finish"
		btn.AnchorPoint = Vector2.new(0.5, 1)
		btn.Position = UDim2.new(0.73, 0, 1, btnY)
		btn.Size = UDim2.fromOffset(SUMMARY_BTN_W, SUMMARY_BTN_H)
		btn.Font = UiTheme.Font
		btn.Text = "FINISH"
		btn.TextSize = 22
		btn.AutoButtonColor = true
		btn.Selectable = true
		btn.ZIndex = 4
		btn.Parent = panel
		btn.Activated:Connect(onFinish)
		finish = btn
	else
		finish.AnchorPoint = Vector2.new(0.5, 1)
		finish.Position = UDim2.new(0.73, 0, 1, btnY)
		finish.Size = UDim2.fromOffset(SUMMARY_BTN_W, SUMMARY_BTN_H)
		finish.Text = "FINISH"
		finish.BackgroundColor3 = FINISH_RED
	end
	local finishBtn = finish :: TextButton
	styleSummaryButton(finishBtn, FINISH_RED, FINISH_STROKE)
	return continueBtn, finishBtn
end

local function readAttrInt(name: string): number
	local attr = Players.LocalPlayer:GetAttribute(name)
	if typeof(attr) == "number" and attr >= 0 then
		return math.floor(attr)
	end
	return 0
end

function WaveSummaryUi.reportAndReadRecords(summary: WaveSim.Summary): Records
	local wave = math.max(0, math.floor(summary.waveReached))
	local fed = math.max(0, math.floor(summary.fishFed))
	local sec = math.max(0, math.floor(summary.elapsedSec + 0.5))
	local bestWave = math.max(readAttrInt(Constants.HIGHEST_WAVE_ATTR), wave)
	local bestFed = math.max(readAttrInt(Constants.HIGHEST_FISH_FED_ATTR), fed)
	local bestSec = math.max(readAttrInt(Constants.LONGEST_WAVE_SEC_ATTR), sec)
	Players.LocalPlayer:SetAttribute(Constants.HIGHEST_WAVE_ATTR, bestWave)
	Players.LocalPlayer:SetAttribute(Constants.HIGHEST_FISH_FED_ATTR, bestFed)
	Players.LocalPlayer:SetAttribute(Constants.LONGEST_WAVE_SEC_ATTR, bestSec)
	pcall(function()
		reportWaveRecordsRemote:FireServer(wave, fed, sec)
	end)
	return { wave = bestWave, fishFed = bestFed, elapsedSec = bestSec }
end

local function makeSummaryStatLabel(parent: Instance, name: string, y: number, textSize: number): TextLabel
	local lbl = Instance.new("TextLabel")
	lbl.Name = name
	lbl.BackgroundTransparency = 1
	lbl.Position = UDim2.fromOffset(0, y)
	lbl.Size = UDim2.new(1, 0, 0, textSize + 8)
	lbl.Font = UiTheme.Font
	lbl.TextSize = textSize
	lbl.TextColor3 = Color3.new(1, 1, 1)
	lbl.TextXAlignment = Enum.TextXAlignment.Center
	lbl.TextTruncate = Enum.TextTruncate.AtEnd
	lbl.ZIndex = 3
	lbl.Parent = parent
	return lbl
end

local function makeSummaryColHeader(parent: Instance, name: string, text: string): TextLabel
	local hdr = Instance.new("TextLabel")
	hdr.Name = name
	hdr.BackgroundTransparency = 1
	hdr.Position = UDim2.fromOffset(0, 0)
	hdr.Size = UDim2.new(1, 0, 0, SUMMARY_COL_HEADER_SIZE + 8)
	hdr.Font = UiTheme.Font
	hdr.TextSize = SUMMARY_COL_HEADER_SIZE
	hdr.TextColor3 = Color3.fromRGB(255, 220, 90)
	hdr.TextXAlignment = Enum.TextXAlignment.Center
	hdr.Text = text
	hdr.ZIndex = 3
	hdr.Parent = parent
	return hdr
end

function WaveSummaryUi.ensureTitle(panel: Frame, onReefPlus: (() -> ())?): UIStroke?
	-- Migrate old full-width title into a centered [text][+] row.
	local oldTitle = panel:FindFirstChild("OutOfReefTitle")
	if oldTitle and not panel:FindFirstChild("OutOfReefTitleRow") then
		oldTitle:Destroy()
	end

	local row = panel:FindFirstChild("OutOfReefTitleRow")
	local host: Frame
	if row and row:IsA("Frame") then
		host = row
	else
		if row then
			row:Destroy()
		end
		host = Instance.new("Frame")
		host.Name = "OutOfReefTitleRow"
		host.BackgroundTransparency = 1
		host.ZIndex = 3
		host.Parent = panel
		local lay = Instance.new("UIListLayout")
		lay.FillDirection = Enum.FillDirection.Horizontal
		lay.HorizontalAlignment = Enum.HorizontalAlignment.Center
		lay.VerticalAlignment = Enum.VerticalAlignment.Center
		lay.SortOrder = Enum.SortOrder.LayoutOrder
		lay.Padding = UDim.new(0, 10)
		lay.Parent = host
	end
	host.AnchorPoint = Vector2.new(0.5, 0)
	host.Position = UDim2.new(0.5, 0, 0, SUMMARY_TITLE_TOP)
	host.Size = UDim2.new(1, -24, 0, SUMMARY_TITLE_SIZE + 8)

	local title = host:FindFirstChild("OutOfReefTitle")
	local lbl: TextLabel
	if title and title:IsA("TextLabel") then
		lbl = title
	else
		if title then
			title:Destroy()
		end
		lbl = Instance.new("TextLabel")
		lbl.Name = "OutOfReefTitle"
		lbl.BackgroundTransparency = 1
		lbl.Font = UiTheme.Font
		lbl.Text = "Out Of Reef Health"
		lbl.TextColor3 = Color3.new(1, 1, 1)
		lbl.TextXAlignment = Enum.TextXAlignment.Center
		lbl.TextYAlignment = Enum.TextYAlignment.Center
		lbl.AutomaticSize = Enum.AutomaticSize.X
		lbl.LayoutOrder = 1
		lbl.ZIndex = 3
		lbl.Parent = host
		local outline = Instance.new("UIStroke")
		outline.Name = "RedOutline"
		outline.Color = TITLE_STROKE_BRIGHT
		outline.Thickness = 1.25
		outline.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
		outline.Parent = lbl
	end
	lbl.Size = UDim2.fromOffset(0, SUMMARY_TITLE_SIZE + 8)
	lbl.TextSize = SUMMARY_TITLE_SIZE
	lbl.Text = "Out Of Reef Health"
	local stroke = lbl:FindFirstChild("RedOutline")
	if stroke and stroke:IsA("UIStroke") then
		stroke.Thickness = 1.25
		stroke.Color = TITLE_STROKE_BRIGHT
	end

	local plus = host:FindFirstChild("ReefHealthPlus")
	local plusBtn: TextButton
	if plus and plus:IsA("TextButton") then
		plusBtn = plus
	else
		if plus then
			plus:Destroy()
		end
		plusBtn = Instance.new("TextButton")
		plusBtn.Name = "ReefHealthPlus"
		plusBtn.BackgroundColor3 = REEF_PLUS_GREEN
		plusBtn.BackgroundTransparency = 0
		plusBtn.BorderSizePixel = 0
		plusBtn.Text = "+"
		plusBtn.Font = Enum.Font.SourceSansBold
		plusBtn.TextColor3 = Color3.new(1, 1, 1)
		plusBtn.TextStrokeColor3 = REEF_PLUS_STROKE
		plusBtn.TextStrokeTransparency = 0
		plusBtn.AutoButtonColor = true
		plusBtn.LayoutOrder = 2
		plusBtn.ZIndex = 4
		plusBtn.Parent = host
		UiCircles.ensure(plusBtn)
		local plusStroke = Instance.new("UIStroke")
		plusStroke.Color = REEF_PLUS_STROKE
		plusStroke.Thickness = 1.5
		plusStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		plusStroke.Parent = plusBtn
	end
	if onReefPlus and plusBtn:GetAttribute("_OceanTD_ReefPlusBound") ~= true then
		plusBtn:SetAttribute("_OceanTD_ReefPlusBound", true)
		plusBtn.Activated:Connect(onReefPlus)
	end
	plusBtn.Size = UDim2.fromOffset(SUMMARY_REEF_PLUS_SIZE, SUMMARY_REEF_PLUS_SIZE)
	plusBtn.TextSize = math.floor(SUMMARY_REEF_PLUS_SIZE * 0.78)

	if stroke and stroke:IsA("UIStroke") then
		return stroke
	end
	return nil
end

local function ensureSummaryStats(panel: Frame, onReefPlus: (() -> ())?): Frame
	WaveSummaryUi.ensureTitle(panel, onReefPlus)
	local root = panel:FindFirstChild("StatsRoot")
	if root and root:IsA("Frame") then
		local left = root:FindFirstChild("ThisRun")
		if not (left and left:FindFirstChild("ThisTimeHeader")) then
			root:Destroy()
			root = nil
		elseif left then
			local hdr = left:FindFirstChild("ThisTimeHeader")
			if hdr and hdr:IsA("TextLabel") and hdr.Text ~= "This Session" then
				hdr.Text = "This Session"
			end
		end
	end
	if root and root:IsA("Frame") then
		root.Position = UDim2.fromOffset(20, SUMMARY_STATS_TOP)
		local left = root:FindFirstChild("ThisRun")
		local right = root:FindFirstChild("Record")
		for _, col in ipairs({ left, right }) do
			if col then
				for _, ch in ipairs(col:GetChildren()) do
					if ch:IsA("TextLabel") then
						ch.TextXAlignment = Enum.TextXAlignment.Center
						if ch.Name == "ThisTimeHeader" or ch.Name == "RecordHeader" then
							ch.TextSize = SUMMARY_COL_HEADER_SIZE
							ch.Size = UDim2.new(1, 0, 0, SUMMARY_COL_HEADER_SIZE + 8)
							if ch.Name == "RecordHeader" then
								ch.Text = "Your Best"
							elseif ch.Name == "ThisTimeHeader" and ch.Text ~= "This Session" then
								ch.Text = "This Session"
							end
						end
					end
				end
			end
		end
		return root
	end
	for _, name in ipairs({ "WaveReached", "FishFed", "Lasted", "StatsRoot" }) do
		local old = panel:FindFirstChild(name)
		if old then
			old:Destroy()
		end
	end

	root = Instance.new("Frame")
	root.Name = "StatsRoot"
	root.BackgroundTransparency = 1
	root.Position = UDim2.fromOffset(20, SUMMARY_STATS_TOP)
	root.Size = UDim2.new(1, -40, 0, 160)
	root.ZIndex = 3
	root.Parent = panel

	local left = Instance.new("Frame")
	left.Name = "ThisRun"
	left.BackgroundTransparency = 1
	left.Position = UDim2.fromScale(0, 0)
	left.Size = UDim2.new(0.5, -8, 1, 0)
	left.ZIndex = 3
	left.Parent = root

	local right = Instance.new("Frame")
	right.Name = "Record"
	right.BackgroundTransparency = 1
	right.Position = UDim2.new(0.5, 8, 0, 0)
	right.Size = UDim2.new(0.5, -8, 1, 0)
	right.ZIndex = 3
	right.Parent = root

	makeSummaryColHeader(left, "ThisTimeHeader", "This Session")
	makeSummaryColHeader(right, "RecordHeader", "Your Best")

	local row0 = SUMMARY_COL_HEADER_SIZE + 10
	makeSummaryStatLabel(left, "Wave", row0, 22)
	makeSummaryStatLabel(left, "FishFed", row0 + 40, 20)
	makeSummaryStatLabel(left, "Lasted", row0 + 78, 20)

	makeSummaryStatLabel(right, "Wave", row0, 22)
	makeSummaryStatLabel(right, "FishFed", row0 + 40, 20)
	makeSummaryStatLabel(right, "Lasted", row0 + 78, 20)

	return root
end

function WaveSummaryUi.fillStats(panel: Frame, summary: WaveSim.Summary, records: Records, onReefPlus: (() -> ())?)
	local root = ensureSummaryStats(panel, onReefPlus)
	local left = root:FindFirstChild("ThisRun")
	local right = root:FindFirstChild("Record")
	local function setCol(col: Instance?, wave: number, fed: number, sec: number)
		if not col then
			return
		end
		local w = col:FindFirstChild("Wave")
		local f = col:FindFirstChild("FishFed")
		local t = col:FindFirstChild("Lasted")
		if w and w:IsA("TextLabel") then
			w.Text = "🌊 Wave " .. tostring(wave)
		end
		if f and f:IsA("TextLabel") then
			f.Text = "🐟 Fish Fed: " .. tostring(fed)
		end
		if t and t:IsA("TextLabel") then
			t.Text = "⏱️ " .. WaveSim.formatClock(sec)
		end
	end
	setCol(left, summary.waveReached, summary.fishFed, summary.elapsedSec)
	setCol(right, records.wave, records.fishFed, records.elapsedSec)
end

function WaveSummaryUi.ensurePanelContent(
	panel: Frame,
	onContinue: () -> (),
	onFinish: () -> (),
	onReefPlus: (() -> ())?
): (TextButton, TextButton, UIStroke?)
	ensureSummaryStats(panel, onReefPlus)
	local c, f = WaveSummaryUi.ensureButtons(panel, onContinue, onFinish)
	local titleStroke = WaveSummaryUi.ensureTitle(panel, onReefPlus)
	return c, f, titleStroke
end

return WaveSummaryUi
