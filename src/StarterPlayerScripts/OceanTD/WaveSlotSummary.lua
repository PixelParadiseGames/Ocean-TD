--!strict
--[[
	Out-of-reef / stop summary panel (scale-in, confetti, gamepad nav).
	Lives here so WaveSlot.lua stays under Luau's 200-local limit.
]]

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local UiHaptics = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiHaptics"))
local UiPopupScale = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiPopupScale"))

local WaveSim = require(script.Parent:WaitForChild("WaveSim"))
local WaveSummaryUi = require(script.Parent:WaitForChild("WaveSummaryUi"))
local WaveEndVfx = require(script.Parent:WaitForChild("WaveEndVfx"))
local ReefDefeatCam = require(script.Parent:WaitForChild("ReefDefeatCam"))
local HideUiController = require(script.Parent:WaitForChild("HideUiController"))
local InventoryState = require(script.Parent:WaitForChild("InventoryState"))

local WaveSlotSummary = {}

local CONTINUE_HEARTS = 5
local CONFETTI_COUNT = 40
local CONFETTI_LIFE = 2.4
local SUMMARY_SCALE_IN = TweenInfo.new(0.32, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local SUMMARY_SCALE_IN_DEFEAT = TweenInfo.new(1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local SUMMARY_SCALE_OUT = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local SUMMARY_CORNER = 32
local SUMMARY_STROKE_THICKNESS = 3.5
local SUMMARY_STROKE_INSET = SUMMARY_STROKE_THICKNESS
local SUMMARY_PANEL_W = 540
local SUMMARY_PANEL_H = 380
local SUMMARY_RGB_HUE_PER_SEC = 1 / 12
local TITLE_STROKE_BRIGHT = Color3.fromRGB(255, 70, 70)
local TITLE_STROKE_DARK = Color3.fromRGB(95, 12, 18)
local TITLE_STROKE_PERIOD_SEC = 4

export type Host = {
	playerGui: PlayerGui,
	log: (...any) -> (),
	getReefBar: () -> Frame?,
	setHudVisible: (boolean) -> (),
	applyIcon: (boolean) -> (),
	clearWaveCameraOffset: () -> (),
}

local host: Host? = nil
local summaryGui: ScreenGui? = nil
local summaryOpen = false
local summaryPausedForSkills = false
local summaryIsDefeat = false
local finishBtn: TextButton? = nil
local continueBtn: TextButton? = nil
local prevGuiSelected: GuiObject? = nil
local summarySelectableRestore: { [GuiObject]: boolean } = {}
local confettiConn: RBXScriptConnection? = nil
local confettiToken = 0
local summaryStroke: UIStroke? = nil
local summaryTitleStroke: UIStroke? = nil
local summaryStrokeConn: RBXScriptConnection? = nil
local summaryScaleToken = 0

local function isUsingGamepad(): boolean
	local t = UserInputService:GetLastInputType()
	return t == Enum.UserInputType.Gamepad1
		or t == Enum.UserInputType.Gamepad2
		or t == Enum.UserInputType.Gamepad3
		or t == Enum.UserInputType.Gamepad4
end

local function destroyConfettiLayers()
	local g = summaryGui
	if not g then
		return
	end
	local panel = g:FindFirstChild("Panel")
	if panel then
		for _, ch in ipairs(panel:GetChildren()) do
			if ch.Name == "Confetti" then
				ch:Destroy()
			end
		end
	end
	-- Belt-and-suspenders: any stray confetti under the ScreenGui.
	for _, ch in ipairs(g:GetChildren()) do
		if ch.Name == "Confetti" then
			ch:Destroy()
		end
	end
end

local function stopConfetti()
	confettiToken += 1
	if confettiConn then
		confettiConn:Disconnect()
		confettiConn = nil
	end
	destroyConfettiLayers()
end

local function playConfetti(parent: Frame)
	stopConfetti()
	local my = confettiToken
	local layer = Instance.new("Frame")
	layer.Name = "Confetti"
	layer.BackgroundTransparency = 1
	layer.Size = UDim2.fromScale(1, 1)
	layer.ZIndex = 50
	layer.Active = false
	layer.Parent = parent

	type P = { f: Frame, x: number, y: number, vx: number, vy: number, life: number }
	local parts: { P } = {}
	local rng = Random.new()
	local colors = {
		Color3.fromRGB(255, 80, 80),
		Color3.fromRGB(255, 180, 40),
		Color3.fromRGB(80, 220, 100),
		Color3.fromRGB(60, 160, 255),
		Color3.fromRGB(220, 100, 255),
		Color3.fromRGB(255, 255, 80),
		Color3.fromRGB(255, 120, 200),
		Color3.fromRGB(100, 255, 220),
	}
	-- Panel-local coords (parent AbsoluteSize), not raw viewport — avoids orphaned off-panel circles.
	local pw = math.max(1, parent.AbsoluteSize.X)
	local ph = math.max(1, parent.AbsoluteSize.Y)
	if pw < 80 or ph < 80 then
		pw = SUMMARY_PANEL_W
		ph = SUMMARY_PANEL_H
	end
	for i = 1, CONFETTI_COUNT do
		local sz = rng:NextNumber(6, 18)
		local f = Instance.new("Frame")
		f.BackgroundColor3 = colors[((i - 1) % #colors) + 1]
		f.BorderSizePixel = 0
		f.Size = UDim2.fromOffset(sz, sz)
		f.AnchorPoint = Vector2.new(0.5, 0.5)
		f.ZIndex = 51
		f.Active = false
		f.Parent = layer
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(1, 0)
		corner.Parent = f
		local x = rng:NextNumber(pw * 0.12, pw * 0.88)
		local y = ph + rng:NextNumber(4, 40)
		f.Position = UDim2.fromOffset(x, y)
		table.insert(parts, {
			f = f,
			x = x,
			y = y,
			vx = rng:NextNumber(-90, 90),
			vy = rng:NextNumber(-520, -280),
			life = CONFETTI_LIFE + rng:NextNumber(-0.3, 0.4),
		})
	end

	local t0 = os.clock()
	local grav = 520
	confettiConn = RunService.RenderStepped:Connect(function(dt)
		if my ~= confettiToken then
			return
		end
		local age = os.clock() - t0
		local alive = false
		for _, p in ipairs(parts) do
			if not p.f.Parent then
				continue
			end
			if age > p.life then
				p.f:Destroy()
				continue
			end
			alive = true
			p.vy += grav * dt
			p.x += p.vx * dt
			p.y += p.vy * dt
			p.f.Position = UDim2.fromOffset(p.x, p.y)
			local fade = math.clamp(1 - (age / p.life), 0, 1)
			p.f.BackgroundTransparency = 1 - fade
		end
		if not alive or age > CONFETTI_LIFE + 1 then
			if confettiConn then
				confettiConn:Disconnect()
				confettiConn = nil
			end
			if layer.Parent then
				layer:Destroy()
			end
		end
	end)
end

local function styleSummaryEdge(edge: UIStroke)
	edge.Name = "SummaryEdge"
	edge.Thickness = SUMMARY_STROKE_THICKNESS
	edge.BorderOffset = UDim.new(0, SUMMARY_STROKE_INSET)
	edge.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	edge.LineJoinMode = Enum.LineJoinMode.Round
end

local function stopSummaryStrokeCycle()
	if summaryStrokeConn then
		summaryStrokeConn:Disconnect()
		summaryStrokeConn = nil
	end
end

local function endSummaryGamepadNav()
	for obj, _ in pairs(summarySelectableRestore) do
		if obj.Parent then
			obj.Selectable = true
		end
	end
	table.clear(summarySelectableRestore)
	if continueBtn then
		continueBtn.NextSelectionUp = nil
		continueBtn.NextSelectionDown = nil
		continueBtn.NextSelectionLeft = nil
		continueBtn.NextSelectionRight = nil
	end
	if finishBtn then
		finishBtn.NextSelectionUp = nil
		finishBtn.NextSelectionDown = nil
		finishBtn.NextSelectionLeft = nil
		finishBtn.NextSelectionRight = nil
	end
end

local function beginSummaryGamepadNav()
	endSummaryGamepadNav()
	local h = host
	if not continueBtn or not finishBtn or not h then
		return
	end
	GuiService.AutoSelectGuiEnabled = true
	for _, layer in ipairs(h.playerGui:GetChildren()) do
		if not layer:IsA("LayerCollector") then
			continue
		end
		local function consider(obj: Instance)
			if obj:IsA("GuiObject") and obj.Selectable then
				if obj ~= continueBtn and obj ~= finishBtn then
					summarySelectableRestore[obj] = true
					obj.Selectable = false
				end
			end
		end
		consider(layer)
		for _, d in ipairs(layer:GetDescendants()) do
			consider(d)
		end
	end
	continueBtn.Selectable = true
	finishBtn.Selectable = true
	continueBtn.NextSelectionUp = finishBtn
	continueBtn.NextSelectionDown = finishBtn
	continueBtn.NextSelectionLeft = finishBtn
	continueBtn.NextSelectionRight = finishBtn
	finishBtn.NextSelectionUp = continueBtn
	finishBtn.NextSelectionDown = continueBtn
	finishBtn.NextSelectionLeft = continueBtn
	finishBtn.NextSelectionRight = continueBtn
	GuiService.SelectedObject = continueBtn
end

local function startSummaryStrokeCycle()
	stopSummaryStrokeCycle()
	if not summaryStroke and not summaryTitleStroke then
		return
	end
	local t0 = os.clock()
	summaryStrokeConn = RunService.RenderStepped:Connect(function()
		if not summaryOpen then
			return
		end
		if summaryStroke then
			local hue = ((os.clock() - t0) * SUMMARY_RGB_HUE_PER_SEC) % 1
			summaryStroke.Color = Color3.fromHSV(hue, 1, 1)
		end
		if summaryTitleStroke and summaryTitleStroke.Parent then
			local phase = ((os.clock() - t0) / TITLE_STROKE_PERIOD_SEC) * math.pi * 2
			local a = (math.sin(phase) + 1) * 0.5
			summaryTitleStroke.Color = TITLE_STROKE_BRIGHT:Lerp(TITLE_STROKE_DARK, a)
		end
	end)
end

local function reefBarScreenCenter(): Vector2?
	local h = host
	local bar = if h then h.getReefBar() else nil
	if not (bar and bar.Parent) then
		return nil
	end
	local p = bar.AbsolutePosition
	local s = bar.AbsoluteSize
	if s.X < 1 or s.Y < 1 then
		return nil
	end
	return Vector2.new(p.X + s.X * 0.5, p.Y + s.Y * 0.5)
end

local function worldToScreen(worldPos: Vector3): Vector2?
	local cam = Workspace.CurrentCamera
	if not cam then
		return nil
	end
	local v, onScreen = cam:WorldToViewportPoint(worldPos)
	if v.Z < 0 then
		return nil
	end
	if not onScreen then
		local vp = cam.ViewportSize
		return Vector2.new(math.clamp(v.X, 0, vp.X), math.clamp(v.Y, 0, vp.Y))
	end
	return Vector2.new(v.X, v.Y)
end

local function summaryScaleOrigin(summary: WaveSim.Summary): Vector2?
	if summary.defeated then
		local world = summary.defeatOrigin
		if typeof(world) == "Vector3" then
			local fromWorld = worldToScreen(world)
			if fromWorld then
				return fromWorld
			end
		end
		local heart = WaveEndVfx.getEndHeartWorldPos()
		if heart then
			local fromHeart = worldToScreen(heart)
			if fromHeart then
				return fromHeart
			end
		end
	end
	return reefBarScreenCenter()
end

function WaveSlotSummary.isOpen(): boolean
	return summaryOpen
end

-- Drop Scriptable defeat zoom; optionally ask FreeCam to re-enter FishCam/PlotCam.
local function releaseDefeatCam(resumeCycle: boolean)
	local h = host
	ReefDefeatCam.releaseHeldPose()
	if h then
		h.clearWaveCameraOffset()
		if resumeCycle then
			h.playerGui:SetAttribute("OceanTD_ResumeDefeatCam", os.clock())
		else
			h.playerGui:SetAttribute("OceanTD_ClearDefeatCamStash", os.clock())
		end
	end
end

local function closeSummaryPanelUi()
	if not summaryOpen and not (summaryGui and summaryGui.Enabled) and not summaryPausedForSkills then
		return false
	end
	summaryOpen = false
	summaryPausedForSkills = false
	summaryIsDefeat = false
	stopConfetti()
	stopSummaryStrokeCycle()
	endSummaryGamepadNav()
	summaryScaleToken += 1
	local my = summaryScaleToken
	local sel = GuiService.SelectedObject
	if (finishBtn and sel == finishBtn) or (continueBtn and sel == continueBtn) then
		GuiService.SelectedObject = prevGuiSelected
	end
	prevGuiSelected = nil

	local g = summaryGui
	local panel = g and g:FindFirstChild("Panel")
	local dim = g and g:FindFirstChild("Dim")
	if dim and dim:IsA("GuiObject") then
		dim.Visible = false
	end
	if panel and panel:IsA("Frame") and panel.Visible and g and g.Enabled then
		local cam = Workspace.CurrentCamera
		local vp = if cam then cam.ViewportSize else Vector2.new(1920, 1080)
		local origin = reefBarScreenCenter()
		local endX = if origin then origin.X / vp.X else 0.92
		local endY = if origin then origin.Y / vp.Y else 0.55
		local tw = TweenService:Create(panel, SUMMARY_SCALE_OUT, {
			Position = UDim2.fromScale(endX, endY),
			Size = UDim2.fromOffset(48, 28),
		})
		tw:Play()
		tw.Completed:Connect(function()
			if my ~= summaryScaleToken then
				return
			end
			if panel then
				panel.Visible = false
			end
			if g then
				g.Enabled = false
			end
		end)
	elseif g then
		g.Enabled = false
		if panel and panel:IsA("Frame") then
			panel.Visible = false
		end
	end
	return true
end

function WaveSlotSummary.hide()
	if not closeSummaryPanelUi() then
		return
	end
	-- Finish / dismiss: restore follow cam, do not re-enter FishCam.
	releaseDefeatCam(false)
	-- Join-intro: skills finger starts on Finish, not when waves stop.
	local pg = Players.LocalPlayer:FindFirstChild("PlayerGui")
	if pg and pg:IsA("PlayerGui") then
		pg:SetAttribute("OceanTD_TutorialSummaryFinished", os.clock())
	end
end

function WaveSlotSummary.pauseForSkills()
	if not summaryOpen or summaryPausedForSkills then
		return
	end
	summaryPausedForSkills = true
	endSummaryGamepadNav()
	stopConfetti()
	stopSummaryStrokeCycle()
	local g = summaryGui
	if g then
		g.Enabled = false
	end
end

function WaveSlotSummary.resumeAfterSkills()
	if not summaryPausedForSkills then
		return
	end
	summaryPausedForSkills = false
	if not summaryOpen then
		return
	end
	local g = summaryGui
	if not g then
		return
	end
	g.Enabled = true
	local dim = g:FindFirstChild("Dim")
	if dim and dim:IsA("GuiObject") then
		dim.Visible = true
	end
	local panel = g:FindFirstChild("Panel")
	if panel and panel:IsA("Frame") then
		panel.ClipsDescendants = false
		panel.Visible = true
		panel.Position = UDim2.fromScale(0.5, 0.5)
		panel.Size = UDim2.fromOffset(SUMMARY_PANEL_W, SUMMARY_PANEL_H)
		local edge = panel:FindFirstChild("SummaryEdge")
		if edge and edge:IsA("UIStroke") then
			styleSummaryEdge(edge)
			summaryStroke = edge
		end
		startSummaryStrokeCycle()
	end
	if isUsingGamepad() and continueBtn and finishBtn then
		prevGuiSelected = GuiService.SelectedObject
		beginSummaryGamepadNav()
	end
end

local function openReefHealthFromSummary()
	local h = host
	if not summaryOpen or summaryPausedForSkills or not h then
		return
	end
	UiHaptics.pulseShort()
	WaveSlotSummary.pauseForSkills()
	h.playerGui:SetAttribute("OceanTD_ForceOpenSkillId", "RHealth")
	h.playerGui:SetAttribute("OceanTD_ForceOpenSkills", os.clock())
	h.log("Summary — opened Skills / Reef Health")
end

local function continueFromSummary()
	local h = host
	if not summaryOpen or not h then
		return
	end
	local retrySame = summaryIsDefeat
	closeSummaryPanelUi()
	ReefDefeatCam.releaseHeldPose()
	h.clearWaveCameraOffset()
	if WaveSim.continueWithHearts(CONTINUE_HEARTS, retrySame) then
		-- Re-enter FishCam/PlotCam after the wave is running again.
		h.playerGui:SetAttribute("OceanTD_ResumeDefeatCam", os.clock())
		h.applyIcon(true)
		h.setHudVisible(true)
		h.clearWaveCameraOffset()
		if retrySame then
			h.log("Wave retried (+" .. tostring(CONTINUE_HEARTS) .. " hearts)")
		else
			h.log("Waves continued (+" .. tostring(CONTINUE_HEARTS) .. " hearts)")
		end
	else
		h.playerGui:SetAttribute("OceanTD_ClearDefeatCamStash", os.clock())
	end
end

function WaveSlotSummary.continueFromSummary()
	continueFromSummary()
end

function WaveSlotSummary.handlePrimaryConfirm(): boolean
	if not summaryOpen then
		return false
	end
	local sel = GuiService.SelectedObject
	if sel == finishBtn then
		WaveSlotSummary.hide()
		return true
	end
	continueFromSummary()
	return true
end

local function ensureSummaryPanelContent(panel: Frame)
	local c, f, titleStroke = WaveSummaryUi.ensurePanelContent(
		panel,
		continueFromSummary,
		WaveSlotSummary.hide,
		openReefHealthFromSummary,
		summaryIsDefeat
	)
	continueBtn = c
	finishBtn = f
	summaryTitleStroke = titleStroke
end

function WaveSlotSummary.show(summary: WaveSim.Summary)
	local h = host
	if not h then
		return
	end
	-- Hide-UI would swallow this popup (and keep the player blind to Continue/Retry).
	HideUiController.forceShow()
	-- Out of reef health (or any summary): leave backpack / build so the popup isn't buried.
	if InventoryState.isOpen() then
		InventoryState.setOpen(false)
	end
	pcall(function()
		require(script.Parent:WaitForChild("PlacementController")).forceExit()
	end)
	summaryOpen = true
	summaryIsDefeat = summary.defeated == true
	local origin = summaryScaleOrigin(summary)
	local scaleInfo = if summary.defeated then SUMMARY_SCALE_IN_DEFEAT else SUMMARY_SCALE_IN
	h.setHudVisible(false)
	h.applyIcon(false)

	local records = WaveSummaryUi.reportAndReadRecords(summary)

	if not summaryGui then
		local g = Instance.new("ScreenGui")
		g.Name = "OceanTD_WaveSummary"
		g.ResetOnSpawn = false
		g.IgnoreGuiInset = true
		g.ClipToDeviceSafeArea = false
		g.DisplayOrder = 13000
		g.Parent = h.playerGui
		summaryGui = g

		local dim = Instance.new("Frame")
		dim.Name = "Dim"
		dim.BackgroundColor3 = Color3.new(0, 0, 0)
		dim.BackgroundTransparency = 0.4
		dim.Size = UDim2.fromScale(1, 1)
		dim.BorderSizePixel = 0
		dim.ZIndex = 1
		dim.Parent = g

		local panel = Instance.new("Frame")
		panel.Name = "Panel"
		panel.AnchorPoint = Vector2.new(0.5, 0.5)
		panel.Position = UDim2.fromScale(0.5, 0.5)
		panel.Size = UDim2.fromOffset(SUMMARY_PANEL_W, SUMMARY_PANEL_H)
		panel.BackgroundColor3 = Color3.fromRGB(16, 26, 38)
		panel.BorderSizePixel = 0
		panel.ClipsDescendants = false
		panel.ZIndex = 2
		panel.Parent = g
		UiPopupScale.attach(panel)
		local pc = Instance.new("UICorner")
		pc.CornerRadius = UDim.new(0, SUMMARY_CORNER)
		pc.Parent = panel
		local edge = Instance.new("UIStroke")
		styleSummaryEdge(edge)
		edge.Color = Color3.fromHSV(0, 1, 1)
		edge.Parent = panel
		summaryStroke = edge

		ensureSummaryPanelContent(panel)
	end

	local g = summaryGui :: ScreenGui
	g.Enabled = true
	g.ClipToDeviceSafeArea = false
	local dim = g:FindFirstChild("Dim")
	if dim and dim:IsA("GuiObject") then
		dim.Visible = true
	end
	local panel = g:FindFirstChild("Panel")
	if panel and panel:IsA("Frame") then
		panel.ClipsDescendants = false
		UiPopupScale.attach(panel)
		local corner = panel:FindFirstChildOfClass("UICorner")
		if corner then
			corner.CornerRadius = UDim.new(0, SUMMARY_CORNER)
		end
		local edge = panel:FindFirstChild("SummaryEdge")
		if edge and edge:IsA("UIStroke") then
			styleSummaryEdge(edge)
			summaryStroke = edge
		elseif not summaryStroke then
			local stroke = Instance.new("UIStroke")
			styleSummaryEdge(stroke)
			stroke.Color = Color3.fromHSV(0, 1, 1)
			stroke.Parent = panel
			summaryStroke = stroke
		end
		ensureSummaryPanelContent(panel)
		WaveSummaryUi.fillStats(panel, summary, records, openReefHealthFromSummary)
		panel.Visible = true
		summaryScaleToken += 1
		local cam = Workspace.CurrentCamera
		local vp = if cam then cam.ViewportSize else Vector2.new(1920, 1080)
		local startX = if origin then origin.X / vp.X else 0.92
		local startY = if origin then origin.Y / vp.Y else 0.55
		panel.Position = UDim2.fromScale(startX, startY)
		panel.Size = UDim2.fromOffset(48, 28)
		TweenService:Create(panel, scaleInfo, {
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(SUMMARY_PANEL_W, SUMMARY_PANEL_H),
		}):Play()
		-- Celebration only — defeat "Out Of Reef Health" should not leave confetti circles.
		if not summary.defeated then
			playConfetti(panel)
		else
			stopConfetti()
		end
		startSummaryStrokeCycle()
	end

	if isUsingGamepad() and continueBtn and finishBtn then
		prevGuiSelected = GuiService.SelectedObject
		beginSummaryGamepadNav()
	end
end

function WaveSlotSummary.bind(h: Host)
	host = h
end

return WaveSlotSummary
