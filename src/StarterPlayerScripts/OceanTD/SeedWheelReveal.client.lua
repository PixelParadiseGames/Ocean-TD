--!strict
--[[
	Prize-wheel seed reveal (top-center, 33% width):
	1) Spin coral icon → winner stays center; name scales up below.
	2) Spin paint color behind coral → winner stays center.
	3) 10–20 mini color circles firework out of the big circle.
	4) Bundle slides to Quickbar Slot4.
]]

local Players = game:GetService("Players")
local ContentProvider = game:GetService("ContentProvider")
local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local Remotes = require(oceanRoot:WaitForChild("Remotes"))
local SeedWheel = require(oceanRoot:WaitForChild("Shared"):WaitForChild("SeedWheel"))
local HueRarity = require(oceanRoot:WaitForChild("Shared"):WaitForChild("HueRarity"))
local ItemCatalog = require(oceanRoot:WaitForChild("Shared"):WaitForChild("ItemCatalog"))
local UiTheme = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiTheme"))
local UiPopupScale = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiPopupScale"))
local UiHaptics = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiHaptics"))
local UiViewportTags = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiViewportTags"))
local InventoryState = require(script.Parent:WaitForChild("InventoryState"))
local CoralColorUnlockState = require(script.Parent:WaitForChild("CoralColorUnlockState"))
local SeedWheelAutoRollState = require(script.Parent:WaitForChild("SeedWheelAutoRollState"))
local SeedWheelRevealApi = require(script.Parent:WaitForChild("SeedWheelRevealApi"))
local JoinIntroGate = require(script.Parent:WaitForChild("JoinIntroGate"))

local BASE_COLOR_PX = 65
-- Hue circles are sized off the coral image: center 10% smaller, neighbors 20%, farther ones 30%.
local HUE_CENTER_OF_CORAL = 0.9
local HUE_NEAR_OF_CORAL = 0.8
local HUE_FAR_OF_CORAL = 0.7
local HUE_CENTER_SHIFT_FRAC = 1.05 -- of the middle hue circle width, to the right of the coral
local PAINTBRUSH_ICON = "rbxassetid://81636797566300"
local BASE_CORAL_FINAL_PX = 52
local BAND_WIDTH_FRAC = 0.33
local BAND_TOP_FRAC = 0.03 -- fallback when Slot4 screen pos unavailable
-- 720p wheels are 3× and share the backpack button's height, so the top of the spinner sits off screen.
local WIDE_WHEEL_TOP_OFFSET_FRAC = 0.3
local BASE_STEP_PX = 70
local SPIN_SEC = 4.992 -- hue/color spin max duration
local CORAL_SPIN_SEC = SPIN_SEC * 1.2 / 0.8 -- coral type max (~20% longer than hue)
local SPIN_FASTER_MAX = 1.0 -- each spin may finish up to this many seconds sooner
local tutorialFullCoralSpinUsed = false
local tutorialFullHueSpinUsed = false

local function isFingerTutorialActive(): boolean
	if playerGui:GetAttribute("OceanTD_FingerTutorialSkipped") == true then
		return false
	end
	if playerGui:GetAttribute("OceanTD_FingerTutorialLock") == true then
		return true
	end
	local hint = playerGui:GetAttribute("OceanTD_RollFingerHint")
	return typeof(hint) == "string" and hint ~= "" and hint ~= "false"
end

-- Randomize in [base - SPIN_FASTER_MAX, base]. Finger-tutorial first coral / first hue keep max for VO.
local function pickSpinSec(baseSec: number, isCoral: boolean): number
	if isFingerTutorialActive() then
		if isCoral and not tutorialFullCoralSpinUsed then
			tutorialFullCoralSpinUsed = true
			return baseSec
		end
		if not isCoral and not tutorialFullHueSpinUsed then
			tutorialFullHueSpinUsed = true
			return baseSec
		end
	end
	local faster = math.random() * SPIN_FASTER_MAX
	return math.max(0.5, baseSec - faster)
end
local FLY_SEC = 1.001
local FIREWORK_MIN = 10
local FIREWORK_MAX = 20
local FIREWORK_SEC = 0.72
local FIREWORK_DIST_MIN = 44
local FIREWORK_DIST_MAX = 118
local FIREWORK_LOCKED_SIZE_MIN = 1.2
local FIREWORK_LOCKED_SIZE_MAX = 1.8
local FIREWORK_LOCK_SHRINK_SEC = 0.22
local FIREWORK_LOCK_START_SCALE = 2.4
local BASE_NAME_BELOW_PX = 14
local BASE_LABEL_H = 18
local BASE_LABEL_W_MIN = 84
local BASE_LABEL_CHAR_W = 7
local BASE_LABEL_FLY_W = 34
local BASE_LABEL_FLY_H = 19
local CORAL_POP_SQUASH = 0.8
local CORAL_POP_OVERSHOOT = 1.3
local CORAL_POP_LEAD_SEC = 1
local BASE_STROKE_CLIP_PAD = 4 -- UIStroke extends past bounds; hide before edge bleed
local TICK_SOUND_ID = "rbxassetid://128707491647978"
local TICK_VOLUME = 0.3
local COLOR_BURST_SOUND_ID = "rbxassetid://138571475125488"
local COLOR_BURST_VOLUME = 0.85
local MIN_STEPS = 16
local EXTRA_STEPS_MAX = 10
local Z_COLOR = 10
local Z_CORAL = 30
local OUTER_PEEK_SCALE_COLOR = 0.7
local OUTER_PEEK_SCALE_CORAL = 0.8
local COLLAPSE_SEC = 0.55
local EXPAND_SEC = 0.55

local tickTemplate = Instance.new("Sound")
tickTemplate.Name = "OceanTD_SeedWheelTick"
tickTemplate.SoundId = TICK_SOUND_ID
tickTemplate.Volume = TICK_VOLUME
tickTemplate.RollOffMode = Enum.RollOffMode.InverseTapered
tickTemplate.Parent = SoundService

local colorBurstTemplate = Instance.new("Sound")
colorBurstTemplate.Name = "OceanTD_SeedWheelColorBurst"
colorBurstTemplate.SoundId = COLOR_BURST_SOUND_ID
colorBurstTemplate.Volume = COLOR_BURST_VOLUME
colorBurstTemplate.RollOffMode = Enum.RollOffMode.InverseTapered
colorBurstTemplate.Parent = SoundService

local overlay: ScreenGui? = nil
local band: Frame? = nil
local busy = false
local busySince = 0
local BUSY_WATCHDOG_SEC = 20
local pitchCursor = 0.92
type Queued = {
	itemId: string,
	token: number,
	amount: number,
	colorIndex: number,
	colorWasUnlocked: boolean,
	manual: boolean?,
}
local queued: Queued? = nil
local activeConns: { RBXScriptConnection } = {}
local abortRequested = false
local currentClaim: { itemId: string, token: number, colorIndex: number }? = nil
local savedBandSize: Vector2? = nil
local wheelIconsReady = false
local wheelIconsPreloading = false

local abortActiveReveal: (boolean) -> ()

local function collectWheelIconAssets(): { string }
	local assets: { string } = {}
	local seen: { [string]: boolean } = {}
	for _, itemId in ipairs(SeedWheel.pool()) do
		local icon = SeedWheel.iconFor(itemId)
		if typeof(icon) == "string" and icon ~= "" and not seen[icon] then
			seen[icon] = true
			table.insert(assets, icon)
		end
	end
	return assets
end

local function preloadWheelIcons()
	if wheelIconsReady then
		return
	end
	while wheelIconsPreloading do
		task.wait()
	end
	if wheelIconsReady then
		return
	end
	wheelIconsPreloading = true
	local assets = collectWheelIconAssets()
	if #assets > 0 then
		local ok, err = pcall(function()
			ContentProvider:PreloadAsync(assets)
		end)
		if not ok then
			warn("[SEEDWHEEL] Coral icon preload failed:", err)
		end
	end
	wheelIconsReady = true
	wheelIconsPreloading = false
end

local function wheelPx(n: number, viewport: Vector2?): number
	return math.floor(n * UiViewportTags.wideUiScale(viewport) + 0.5)
end

local function trackConn(conn: RBXScriptConnection)
	table.insert(activeConns, conn)
end

local function disconnectAll()
	for _, conn in ipairs(activeConns) do
		if conn.Connected then
			conn:Disconnect()
		end
	end
	table.clear(activeConns)
end

local function leftHudScreenCenter(obj: GuiObject): Vector2
	local inset = GuiService:GetGuiInset()
	local c = obj.AbsolutePosition + obj.AbsoluteSize * 0.5
	return Vector2.new(c.X + inset.X, c.Y + inset.Y)
end

local function easeOutQuint(t: number): number
	local u = 1 - math.clamp(t, 0, 1)
	return 1 - u * u * u * u * u
end

local playReveal: (string, number, number, number, boolean, boolean?) -> ()

local function claim(itemId: string, token: number)
	local ok, err = pcall(function()
		Remotes.get("SeedWheelClaim"):FireServer(itemId, token)
	end)
	if not ok then
		warn("[SEEDWHEEL] Claim failed", err)
	end
end

local function finishBusy()
	local awardedId = if currentClaim then currentClaim.itemId else nil
	local awardedColorIndex = if currentClaim then currentClaim.colorIndex else nil
	busy = false
	busySince = 0
	currentClaim = nil
	local q = queued
	queued = nil
	-- Replay a one-shot even when auto-roll is off. Auto chain only continues while enabled.
	local continuing = q ~= nil and (q.manual == true or SeedWheelAutoRollState.isEnabled())
	if continuing and q then
		task.defer(playReveal, q.itemId, q.token, q.amount, q.colorIndex, q.colorWasUnlocked, q.manual)
		return
	end
	if typeof(awardedId) == "string" and awardedId ~= "" then
		SeedWheelRevealApi.lastAwardedItemId = awardedId
	end
	if typeof(awardedColorIndex) == "number" then
		SeedWheelRevealApi.lastAwardedColorIndex = math.clamp(math.floor(awardedColorIndex), 1, 14)
		playerGui:SetAttribute("OceanTD_TutorialHueIndex", SeedWheelRevealApi.lastAwardedColorIndex)
	end
	SeedWheelRevealApi.fireCycleFinished()
end

local function watchdogRecoverIfStuck()
	if not busy or busySince <= 0 then
		return
	end
	if os.clock() - busySince < BUSY_WATCHDOG_SEC then
		return
	end
	warn("[SEEDWHEEL] Watchdog: reveal stuck — recovering (claim + clear busy)")
	abortActiveReveal(true)
end

local function playTick()
	local s = tickTemplate:Clone()
	s.Volume = TICK_VOLUME
	pitchCursor += 0.035
	if pitchCursor > 1.18 then
		pitchCursor = 0.88
	end
	s.PlaybackSpeed = pitchCursor + (math.random() - 0.5) * 0.06
	s.Parent = SoundService
	s:Play()
	s.Ended:Once(function()
		s:Destroy()
	end)
	task.delay(2, function()
		if s.Parent then
			s:Destroy()
		end
	end)
end

local function playColorBurstSound(playbackSpeed: number?)
	local s = colorBurstTemplate:Clone()
	s.Volume = COLOR_BURST_VOLUME
	s.PlaybackSpeed = if typeof(playbackSpeed) == "number" then playbackSpeed else 1
	s.Parent = SoundService
	s:Play()
	s.Ended:Once(function()
		s:Destroy()
	end)
	task.delay(4, function()
		if s.Parent then
			s:Destroy()
		end
	end)
end

local function applySeedWheelDisplayOrder(gui: ScreenGui)
	-- Under reef report / store / skills while those are open; else under left HUD.
	local report = playerGui:FindFirstChild("OceanTD_ReefReport")
	if playerGui:GetAttribute("OceanTD_ReefReportOpen") == true and report and report:IsA("ScreenGui") then
		gui.DisplayOrder = math.max(0, report.DisplayOrder - 1)
		return
	end
	local store = playerGui:FindFirstChild("OceanTD_Store")
	if playerGui:GetAttribute("OceanTD_StoreOpen") == true and store and store:IsA("ScreenGui") then
		gui.DisplayOrder = math.max(0, store.DisplayOrder - 1)
		return
	end
	local skills = playerGui:FindFirstChild("MobileSkillsA")
	if playerGui:GetAttribute("OceanTD_SkillsBubblesOpen") == true and skills and skills:IsA("ScreenGui") then
		gui.DisplayOrder = math.max(0, skills.DisplayOrder - 1)
		return
	end
	local left = playerGui:FindFirstChild("MobileLeftUI")
	if left and left:IsA("ScreenGui") then
		gui.DisplayOrder = left.DisplayOrder - 1
	else
		gui.DisplayOrder = 49
	end
end

local function backpackOverlayCenter(): Vector2?
	local c = InventoryState.getBackpackButtonScreenCenter()
	if not c then
		return nil
	end
	local inset = GuiService:GetGuiInset()
	return Vector2.new(c.X + inset.X, c.Y + inset.Y)
end

local function wideWheelTopOffset(viewport: Vector2): number
	if not UiViewportTags.is720p(viewport) then
		return 0
	end
	return math.floor(wheelPx(BASE_CORAL_FINAL_PX, viewport) * WIDE_WHEEL_TOP_OFFSET_FRAC + 0.5)
end

local function positionBandAtSlot4Height(host: Frame, viewport: Vector2)
	local slotCenter = backpackOverlayCenter()
	local drop = wideWheelTopOffset(viewport)
	if slotCenter then
		host.AnchorPoint = Vector2.new(0.5, 0.5)
		host.Position = UDim2.fromOffset(viewport.X * 0.5, slotCenter.Y + drop)
	else
		host.AnchorPoint = Vector2.new(0.5, 0)
		host.Position = UDim2.new(0.5, 0, BAND_TOP_FRAC, drop)
	end
end

local function overlayScreenPoint(guiObj: GuiObject): Vector2
	local inset = GuiService:GetGuiInset()
	local c = guiObj.AbsolutePosition + guiObj.AbsoluteSize * 0.5
	return Vector2.new(c.X, c.Y + inset.Y)
end

local function clearOverlayExtras(gui: ScreenGui)
	for _, ch in ipairs(gui:GetChildren()) do
		if ch:IsA("GuiObject") and ch.Name ~= "Band" then
			ch:Destroy()
		end
	end
end

local function clearBandChildren(host: Frame)
	for _, ch in ipairs(host:GetChildren()) do
		if ch:IsA("GuiObject") then
			ch:Destroy()
		end
	end
end

local function ensureOverlay(): (ScreenGui, Frame)
	if overlay and overlay.Parent and band and band.Parent then
		applySeedWheelDisplayOrder(overlay)
		-- Stay hidden while Hide UI is active (logic keeps running).
		if playerGui:GetAttribute("OceanTD_HideUiActive") == true then
			overlay.Enabled = false
		end
		return overlay, band
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = "OceanTD_SeedWheel"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	applySeedWheelDisplayOrder(gui)
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	if playerGui:GetAttribute("OceanTD_HideUiActive") == true then
		gui.Enabled = false
	end
	gui.Parent = playerGui
	overlay = gui

	local host = Instance.new("Frame")
	host.Name = "Band"
	host.AnchorPoint = Vector2.new(0.5, 0)
	host.Position = UDim2.fromScale(0.5, BAND_TOP_FRAC)
	host.Size = UDim2.fromOffset(200, wheelPx(BASE_COLOR_PX) + 8)
	host.BackgroundTransparency = 1
	host.ClipsDescendants = true
	host.Parent = gui
	band = host
	host.Visible = false
	return gui, host
end

local function layoutBandForReveal(host: Frame, vp: Vector2): number
	local colorPx = wheelPx(BASE_COLOR_PX, vp)
	local stepPx = wheelPx(BASE_STEP_PX, vp)
	local minBandW = 2 * (2 * stepPx + colorPx * 0.5)
	local bandW = math.max(vp.X * BAND_WIDTH_FRAC, minBandW)
	host.Size = UDim2.new(0, bandW, 0, colorPx + 8)
	savedBandSize = Vector2.new(bandW, colorPx + 8)
	positionBandAtSlot4Height(host, vp)
	host.Visible = true
	return bandW * 0.5
end

local function hideWheel()
	disconnectAll()
	local gui, host = ensureOverlay()
	clearOverlayExtras(gui)
	clearBandChildren(host)
	host.Visible = false
	busy = false
	currentClaim = nil
	queued = nil
	abortRequested = false
end

local function tweenWheelTo(target: GuiObject, shrink: boolean, onDone: () -> ())
	local gui, host = ensureOverlay()
	if not host.Visible and shrink then
		onDone()
		return
	end
	local fromCenter = overlayScreenPoint(host)
	local toCenter = leftHudScreenCenter(target)
	local baseSize = savedBandSize or Vector2.new(host.Size.X.Offset, host.Size.Y.Offset)
	host.AnchorPoint = Vector2.new(0.5, 0.5)
	host.Position = UDim2.fromOffset(fromCenter.X, fromCenter.Y)
	local extras: { GuiObject } = {}
	for _, ch in ipairs(gui:GetChildren()) do
		if ch:IsA("GuiObject") and ch.Name ~= "Band" then
			table.insert(extras, ch)
		end
	end
	local t0 = os.clock()
	local dur = if shrink then COLLAPSE_SEC else EXPAND_SEC
	local conn: RBXScriptConnection? = nil
	conn = RunService.RenderStepped:Connect(function()
		local u = math.clamp((os.clock() - t0) / dur, 0, 1)
		local e = u * u * (3 - 2 * u)
		local x = if shrink then fromCenter.X + (toCenter.X - fromCenter.X) * e else toCenter.X + (fromCenter.X - toCenter.X) * e
		local y = if shrink then fromCenter.Y + (toCenter.Y - fromCenter.Y) * e else toCenter.Y + (fromCenter.Y - toCenter.Y) * e
		local s = if shrink then 1 - e * 0.92 else e
		host.Position = UDim2.fromOffset(x, y)
		host.Size = UDim2.fromOffset(math.max(4, baseSize.X * s), math.max(4, baseSize.Y * s))
		for _, extra in ipairs(extras) do
			if extra.Parent then
				extra.Position = UDim2.fromOffset(x, y + (if shrink then wheelPx(BASE_LABEL_H) else 0))
			end
		end
		if u >= 1 then
			if conn then
				conn:Disconnect()
			end
			if shrink then
				hideWheel()
			end
			onDone()
		end
	end)
	trackConn(conn)
end

local function roundCorner(parent: Instance)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = parent
end

local function brightenHue(color: Color3, amount: number): Color3
	local h, s, v = color:ToHSV()
	-- Keep hue; lift value and ease saturation so the rim reads as a bright tint of the fill.
	local nv = math.clamp(v + (1 - v) * amount + 0.12, 0, 1)
	local ns = math.clamp(s * (1 - amount * 0.35), 0, 1)
	return Color3.fromHSV(h, ns, nv)
end

local function makeColorCircle(
	parent: Instance,
	color: Color3,
	z: number,
	sizePx: number,
	itemId: string?,
	colorIndex: number?
): Frame
	local f = Instance.new("Frame")
	f.Name = "ColorCircle"
	f.BackgroundColor3 = color
	f.BackgroundTransparency = 0
	f.BorderSizePixel = 0
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.Position = UDim2.new(0.5, 0, 0.5, 0)
	f.Size = UDim2.fromOffset(sizePx, sizePx)
	f.ZIndex = z
	f.Parent = parent
	roundCorner(f)
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.Color = brightenHue(color, 0.55)
	stroke.Transparency = 0.15
	stroke.Parent = f
	if itemId and typeof(colorIndex) == "number" and not CoralColorUnlockState.isUnlocked(itemId, colorIndex) then
		CoralColorUnlockState.createLockOverlay(f, z + 2)
	end
	return f
end

local function addInnerWhiteStroke(parent: GuiObject, z: number)
	local ring = Instance.new("Frame")
	ring.Name = "InnerRing"
	ring.BackgroundTransparency = 1
	ring.BorderSizePixel = 0
	ring.AnchorPoint = Vector2.new(0.5, 0.5)
	ring.Position = UDim2.fromScale(0.5, 0.5)
	ring.Size = UDim2.new(1, -3, 1, -3)
	ring.ZIndex = z + 1
	ring.Active = false
	roundCorner(ring)
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.new(1, 1, 1)
	stroke.Transparency = 0.5
	stroke.Thickness = UiViewportTags.coralSpinnerStrokeThickness()
	stroke.LineJoinMode = Enum.LineJoinMode.Round
	stroke.Parent = ring
	ring.Parent = parent
end

local function makeCoralCircle(parent: Instance, icon: string, z: number, sizePx: number): ImageLabel
	local img = Instance.new("ImageLabel")
	img.Name = "SeedCircle"
	img.BackgroundColor3 = Color3.fromRGB(20, 40, 55)
	img.BackgroundTransparency = 1
	img.BorderSizePixel = 0
	img.AnchorPoint = Vector2.new(0.5, 0.5)
	img.Position = UDim2.new(0.5, 0, 0.5, 0)
	img.Size = UDim2.fromOffset(sizePx, sizePx)
	img.Image = icon
	img.ScaleType = Enum.ScaleType.Fit
	img.ZIndex = z
	img.Parent = parent
	roundCorner(img)
	addInnerWhiteStroke(img, z)
	return img
end

local function coralDisplayName(itemId: string): string
	local def = ItemCatalog.get(itemId)
	return if def then def.displayName else itemId
end

local function spawnCoralNameLabel(gui: ScreenGui, host: Frame): TextLabel
	local center = overlayScreenPoint(host)
	local fullNamePx = wheelPx(BASE_LABEL_H)
	local below = wheelPx(BASE_COLOR_PX) * 0.5 + wheelPx(BASE_NAME_BELOW_PX)
	local lbl = Instance.new("TextLabel")
	lbl.Name = "CoralName"
	lbl.BackgroundTransparency = 1
	lbl.AnchorPoint = Vector2.new(0.5, 0.5)
	lbl.Position = UDim2.fromOffset(center.X, center.Y + below)
	lbl.Size = UDim2.fromOffset(wheelPx(BASE_LABEL_W_MIN), math.floor(fullNamePx * 1.35 + 0.5))
	lbl.Font = UiTheme.Font
	lbl.Text = ""
	lbl.TextColor3 = Color3.new(1, 1, 1)
	lbl.TextScaled = false
	lbl.TextSize = fullNamePx
	lbl.TextTransparency = 0
	lbl.ZIndex = Z_CORAL + 25
	lbl.Parent = gui

	local nameStroke = Instance.new("UIStroke")
	nameStroke.Name = "NameOutline"
	nameStroke.Color = Color3.fromRGB(52, 52, 58)
	nameStroke.Thickness = 1
	nameStroke.Transparency = 0
	nameStroke.LineJoinMode = Enum.LineJoinMode.Round
	nameStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	nameStroke.Parent = lbl

	local scale = Instance.new("UIScale")
	scale.Name = "RiseScale"
	scale.Scale = 1
	scale.Parent = lbl

	return lbl
end

-- Squash → overshoot → settle (cartoony "pop" when the coral lands).
-- Outer stroke stays on for the whole pop and the hue spin after it.
local function playCoralLandPop(coral: ImageLabel)
	local pop = coral:FindFirstChild("PopScale")
	if not pop or not pop:IsA("UIScale") then
		pop = Instance.new("UIScale")
		pop.Name = "PopScale"
		pop.Parent = coral
	end
	pop.Scale = 1

	local squashInfo = TweenInfo.new(0.07, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local overshootInfo = TweenInfo.new(0.12, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	local settleInfo = TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

	local squash = TweenService:Create(pop, squashInfo, { Scale = CORAL_POP_SQUASH })
	squash:Play()
	squash.Completed:Once(function()
		if not coral.Parent or pop.Parent ~= coral then
			return
		end
		local overshoot = TweenService:Create(pop, overshootInfo, { Scale = CORAL_POP_OVERSHOOT })
		overshoot:Play()
		overshoot.Completed:Once(function()
			if not coral.Parent or pop.Parent ~= coral then
				return
			end
			TweenService:Create(pop, settleInfo, { Scale = 1 }):Play()
		end)
	end)
end

local function circleScaleAtOffset(offsetX: number, outerMinScale: number?, stepPx: number): number
	local stepDist = math.abs(offsetX) / stepPx
	local outerMin = if typeof(outerMinScale) == "number" then outerMinScale else OUTER_PEEK_SCALE_COLOR
	return if stepDist <= 1 then 1 - stepDist * 0.1 else math.max(outerMin, 0.9 - (stepDist - 1) * (0.9 - outerMin))
end

-- Nearest wheel slot, so center / neighbors / outer hues stay three different sizes while spinning.
local function hueFracOfCoral(offsetX: number, stepPx: number): number
	local stepDist = math.abs(offsetX) / math.max(stepPx, 1)
	local slot = math.floor(stepDist + 0.5)
	if slot <= 0 then
		return HUE_CENTER_OF_CORAL
	elseif slot == 1 then
		return HUE_NEAR_OF_CORAL
	end
	return HUE_FAR_OF_CORAL
end

local function hueDiameterPx(offsetX: number, coralSize: number, stepPx: number): number
	return math.max(8, math.floor(coralSize * hueFracOfCoral(offsetX, stepPx) + 0.5))
end

local function styleByOffset(guiObj: GuiObject, offsetX: number, _halfW: number, baseSize: number, outerMinScale: number?, stepPx: number, hueOfCoral: boolean?)
	local scale = if hueOfCoral then hueFracOfCoral(offsetX, stepPx) else circleScaleAtOffset(offsetX, outerMinScale, stepPx)
	local stepDist = math.abs(offsetX) / stepPx
	local trans = if stepDist <= 1 then stepDist * 0.26 else 0.26 + (stepDist - 1) * 0.42
	local px = if hueOfCoral then hueDiameterPx(offsetX, baseSize, stepPx) else baseSize * scale
	guiObj.Size = UDim2.fromOffset(px, px)
	if guiObj:IsA("ImageLabel") then
		guiObj.ImageTransparency = trans
		guiObj.BackgroundTransparency = 1
		local ring = guiObj:FindFirstChild("InnerRing")
		if ring then
			local innerStroke = ring:FindFirstChildWhichIsA("UIStroke")
			if innerStroke then
				innerStroke.Transparency = 0.5 + trans * 0.5
			end
		end
	elseif guiObj:IsA("Frame") then
		guiObj.BackgroundTransparency = trans
		local lock = guiObj:FindFirstChild("_OceanTD_ColorLock")
		if lock and lock:IsA("ImageLabel") then
			lock.ImageTransparency = trans * 0.85
		end
	end
	local stroke = guiObj:FindFirstChildWhichIsA("UIStroke")
	if stroke then
		stroke.Transparency = 0.15 + trans * 0.75
	end
end

local function pickDifferentIds(pool: { string }, avoid: string): string
	if #pool <= 1 then
		return pool[1] or avoid
	end
	local pick = pool[math.random(1, #pool)]
	local tries = 0
	while pick == avoid and tries < 12 do
		pick = pool[math.random(1, #pool)]
		tries += 1
	end
	if pick == avoid then
		for _, id in ipairs(pool) do
			if id ~= avoid then
				return id
			end
		end
	end
	return pick
end

local function pickDifferentIndex(pool: { number }, avoid: number): number
	if #pool <= 1 then
		return pool[1] or avoid
	end
	local pick = pool[math.random(1, #pool)]
	local tries = 0
	while pick == avoid and tries < 12 do
		pick = pool[math.random(1, #pool)]
		tries += 1
	end
	if pick == avoid then
		for _, id in ipairs(pool) do
			if id ~= avoid then
				return id
			end
		end
	end
	return pick
end

-- Fillers → winner → two peeks on the right (no adjacent duplicates).
local function buildIdSequence(winnerId: string): { string }
	local pool = SeedWheel.pool()
	local steps = MIN_STEPS + math.random(0, EXTRA_STEPS_MAX)
	local seq: { string } = {}
	local last = ""
	for _ = 1, steps - 1 do
		local pick = pickDifferentIds(pool, last)
		table.insert(seq, pick)
		last = pick
	end
	if last == winnerId and #seq > 0 then
		seq[#seq] = pickDifferentIds(pool, winnerId)
	end
	local peek1 = pickDifferentIds(pool, winnerId)
	table.insert(seq, winnerId)
	table.insert(seq, peek1)
	table.insert(seq, pickDifferentIds(pool, peek1))
	return seq
end

local function buildColorSequence(winnerIndex: number, colorPool: { number }?): { number }
	local pool = if colorPool and #colorPool > 0 then colorPool else SeedWheel.colorIndices()
	local steps = MIN_STEPS + math.random(0, EXTRA_STEPS_MAX)
	local seq: { number } = {}
	local last = -1
	for _ = 1, steps - 1 do
		local pick = pickDifferentIndex(pool, last)
		table.insert(seq, pick)
		last = pick
	end
	if last == winnerIndex and #seq > 0 then
		seq[#seq] = pickDifferentIndex(pool, winnerIndex)
	end
	local peek1 = pickDifferentIndex(pool, winnerIndex)
	table.insert(seq, winnerIndex)
	table.insert(seq, peek1)
	table.insert(seq, pickDifferentIndex(pool, peek1))
	return seq
end

local function runSpin(
	host: Frame,
	halfW: number,
	icons: { GuiObject },
	winnerIndex0: number,
	baseSize: number,
	spinSec: number,
	onDone: () -> (),
	outerMinScale: number?,
	stepPx: number,
	earlyLeadSec: number?,
	onEarlyDone: (() -> ())?,
	centerBiasX: number?,
	hueOfCoral: boolean?,
	onCenterSlot: ((slot: number) -> ())?,
	vertical: boolean?
)
	local totalSteps = winnerIndex0
	local t0 = os.clock()
	local lastFloor = -1
	local lastOddsSlot = -1
	local earlyDone = false
	local conn: RBXScriptConnection? = nil

	local function layoutIcons(centerIndex: number)
		local clipPad = wheelPx(BASE_STROKE_CLIP_PAD)
		local bias = centerBiasX or 0
		local spinUp = vertical == true
		local heldSlot = if spinUp then math.floor(centerIndex + 1e-4) else 0
		local riseU = if spinUp then math.clamp(centerIndex - heldSlot, 0, 1) else 0
		for i, img in ipairs(icons) do
			if spinUp then
				local slot = i - 1
				local bias = centerBiasX or 0
				if slot == heldSlot then
					img.Position = UDim2.new(0.5, bias, 0.5, 0)
					img.Visible = true
					img.ZIndex = 12
					styleByOffset(img, 0, halfW, baseSize, outerMinScale, stepPx, hueOfCoral)
				elseif slot == heldSlot + 1 and riseU > 0.001 then
					local y = stepPx * (1 - riseU)
					img.Position = UDim2.new(0.5, bias, 0.5, y)
					img.Visible = true
					img.ZIndex = 24
					styleByOffset(img, 0, halfW, baseSize, outerMinScale, stepPx, hueOfCoral)
					local fade = (1 - riseU) * 0.88
					if img:IsA("Frame") then
						img.BackgroundTransparency = fade
						local edge = img:FindFirstChildWhichIsA("UIStroke")
						if edge then
							edge.Transparency = 0.15 + fade * 0.85
						end
						local lock = img:FindFirstChild("_OceanTD_ColorLock")
						if lock and lock:IsA("ImageLabel") then
							lock.ImageTransparency = fade
						end
					elseif img:IsA("ImageLabel") then
						img.ImageTransparency = fade
					end
				else
					img.Visible = false
				end
				continue
			end
			local along = (centerIndex - (i - 1)) * stepPx
			local diameter = if hueOfCoral then hueDiameterPx(along, baseSize, stepPx) else baseSize * circleScaleAtOffset(along, outerMinScale, stepPx)
			img.Size = UDim2.fromOffset(diameter, diameter)
			local radius = diameter * 0.5
			local drawX = along + bias
			local drawY = 0
			img.Position = UDim2.new(0.5, drawX, 0.5, drawY)
			local draw = drawX
			local halfExtent = halfW
			-- Hide once the circle would leave the reel window.
			if draw - radius - clipPad < -halfExtent or draw + radius + clipPad > halfExtent then
				img.Visible = false
			else
				img.Visible = true
				styleByOffset(img, along, halfW, baseSize, outerMinScale, stepPx, hueOfCoral)
			end
		end
	end

	layoutIcons(0)

	conn = RunService.RenderStepped:Connect(function()
		if abortRequested then
			if conn then
				conn:Disconnect()
			end
			return
		end
		local raw = math.clamp((os.clock() - t0) / spinSec, 0, 1)
		local eased = easeOutQuint(raw)
		local progress = eased * totalSteps
		local centerIndex = progress

		if math.floor(progress + 1e-4) > lastFloor then
			local floored = math.floor(progress + 1e-4)
			while lastFloor < floored do
				lastFloor += 1
				playTick()
			end
		end
		-- Odds follow the color moving into the center, not the one that just landed.
		local oddsSlot = math.floor(progress + 0.5 + 1e-4)
		if onCenterSlot and oddsSlot > lastOddsSlot then
			lastOddsSlot = oddsSlot
			onCenterSlot(oddsSlot)
		end

		layoutIcons(centerIndex)

		local elapsed = os.clock() - t0
		if onEarlyDone and earlyLeadSec and earlyLeadSec > 0 and not earlyDone and elapsed >= spinSec - earlyLeadSec then
			earlyDone = true
			onEarlyDone()
		end

		if raw >= 1 then
			if conn then
				conn:Disconnect()
			end
			if abortRequested then
				return
			end
			-- Do not bail on host.Visible — Hide UI (or similar) can hide the band and
			-- would leave busy=true forever while the server timeout still grants seeds.
			onDone()
		end
	end)
	trackConn(conn :: RBXScriptConnection)
end

local function screenCenterWithInset(guiObj: GuiObject): Vector2
	return overlayScreenPoint(guiObj)
end

local function runColorFirework(
	gui: ScreenGui,
	center: Vector2,
	color: Color3,
	itemId: string,
	colorIndex: number,
	onDone: () -> (),
	colorWasUnlocked: boolean
)
	playColorBurstSound()
	local isLocked = not CoralColorUnlockState.isUnlocked(itemId, colorIndex)
	local count = math.random(FIREWORK_MIN, FIREWORK_MAX)
	if colorWasUnlocked then
		count = math.max(1, math.floor(count * 0.7 + 0.5))
	end
	type Particle = {
		frame: Frame,
		dir: Vector2,
		dist: number,
		sizePx: number,
		delay: number,
		lock: ImageLabel?,
		lockScale: UIScale?,
	}
	local particles: { Particle } = {}
	for _ = 1, count do
		local sizeFrac = 0.1 + math.random() * 0.3
		if isLocked then
			sizeFrac *= FIREWORK_LOCKED_SIZE_MIN + math.random() * (FIREWORK_LOCKED_SIZE_MAX - FIREWORK_LOCKED_SIZE_MIN)
		elseif colorWasUnlocked then
			sizeFrac *= 0.5
		end
		local sizePx = wheelPx(BASE_COLOR_PX) * sizeFrac
		local angle = math.random() * math.pi * 2
		local dir = Vector2.new(math.cos(angle), math.sin(angle))
		local dist = FIREWORK_DIST_MIN + math.random() * (FIREWORK_DIST_MAX - FIREWORK_DIST_MIN)
		local f = makeColorCircle(gui, color, 45, sizePx, nil, nil)
		f.Position = UDim2.fromOffset(center.X, center.Y)
		f.BackgroundTransparency = 0
		local stroke = f:FindFirstChildWhichIsA("UIStroke")
		if stroke then
			stroke.Transparency = 0.15
		end
		local lock: ImageLabel? = nil
		local lockScale: UIScale? = nil
		if isLocked then
			lock = CoralColorUnlockState.createLockOverlay(f, 47)
			lockScale = Instance.new("UIScale")
			lockScale.Name = "ShrinkScale"
			lockScale.Scale = FIREWORK_LOCK_START_SCALE
			lockScale.Parent = lock
		end
		table.insert(particles, {
			frame = f,
			dir = dir,
			dist = dist,
			sizePx = sizePx,
			delay = math.random() * 0.06,
			lock = lock,
			lockScale = lockScale,
		})
	end

	local t0 = os.clock()
	local conn: RBXScriptConnection? = nil
	conn = RunService.RenderStepped:Connect(function()
		if abortRequested then
			if conn then
				conn:Disconnect()
			end
			for _, p in ipairs(particles) do
				p.frame:Destroy()
			end
			return
		end
		local elapsed = os.clock() - t0
		local allDone = true
		for _, p in ipairs(particles) do
			local u = math.clamp((elapsed - p.delay) / FIREWORK_SEC, 0, 1)
			if u < 1 then
				allDone = false
			end
			local e = u * u * (3 - 2 * u)
			local pos = center + p.dir * (p.dist * e)
			p.frame.Position = UDim2.fromOffset(pos.X, pos.Y)
			local fade = math.clamp((u - 0.35) / 0.65, 0, 1)
			p.frame.BackgroundTransparency = fade * 0.95
			local stroke = p.frame:FindFirstChildWhichIsA("UIStroke")
			if stroke then
				stroke.Transparency = 0.15 + fade * 0.85
			end
			local shrink = 1 - fade * 0.35
			p.frame.Size = UDim2.fromOffset(p.sizePx * shrink, p.sizePx * shrink)
			if p.lock and p.lockScale then
				local lockElapsed = math.max(0, elapsed - p.delay)
				local lockU = math.clamp(lockElapsed / FIREWORK_LOCK_SHRINK_SEC, 0, 1)
				local lockEase = 1 - (1 - lockU) * (1 - lockU)
				p.lockScale.Scale = FIREWORK_LOCK_START_SCALE + (1 - FIREWORK_LOCK_START_SCALE) * lockEase
				p.lock.ImageTransparency = fade * 0.95
			end
		end
		if allDone then
			if conn then
				conn:Disconnect()
			end
			for _, p in ipairs(particles) do
				p.frame:Destroy()
			end
			onDone()
		end
	end)
	trackConn(conn :: RBXScriptConnection)
end

local function applyFlyAmountLabel(nameLabel: TextLabel, amount: number)
	nameLabel.Text = "+" .. tostring(amount)
	nameLabel.Size = UDim2.fromOffset(wheelPx(BASE_LABEL_FLY_W), wheelPx(BASE_LABEL_FLY_H))
	nameLabel.TextTransparency = 0
	local nameStroke = nameLabel:FindFirstChild("NameOutline")
	if nameStroke and nameStroke:IsA("UIStroke") then
		nameStroke.Transparency = 0
	end
	local riseScale = nameLabel:FindFirstChild("RiseScale")
	if riseScale and riseScale:IsA("UIScale") then
		riseScale.Scale = 1.2
		TweenService:Create(riseScale, TweenInfo.new(0.14, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
	end
end

local function flyBundle(
	colorCircle: Frame,
	coralCircle: ImageLabel,
	coralStart: Vector2,
	colorCenter: Vector2,
	itemId: string,
	token: number,
	amount: number,
	nameLabel: TextLabel?,
	coralPx: number,
	colorPx: number
)
	-- Unlock backpack as soon as the coral circle begins flying to Slot4.
	SeedWheelRevealApi.fireSlideToBackpackStarted()

	local target = backpackOverlayCenter()
	if not target then
		local cam = workspace.CurrentCamera
		local vp = if cam then cam.ViewportSize else Vector2.new(1280, 720)
		target = Vector2.new(vp.X * 0.92, vp.Y * 0.12)
	end

	local gui = overlay
	if not gui then
		claim(itemId, token)
		colorCircle:Destroy()
		coralCircle:Destroy()
		finishBusy()
		return
	end

	UiHaptics.rampSmallToMed(FLY_SEC)

	if SeedWheelAutoRollState.isEnabled() then
		SeedWheelAutoRollState.beginFlyRemainingTick()
	end

	-- Above MainHUD Quickbar so the slide passes in front of Auto Plant OFF / BUILD.
	gui.DisplayOrder = UiViewportTags.RIGHT_HUD_DISPLAY_ORDER + 5

	local function restoreFlyLayer()
		if gui.Parent then
			applySeedWheelDisplayOrder(gui)
		end
	end

	local function placeCircle(circle: GuiObject, point: Vector2, sizePx: number, z: number)
		circle.Parent = gui
		circle.AnchorPoint = Vector2.new(0.5, 0.5)
		circle.Position = UDim2.fromOffset(point.X, point.Y)
		circle.Size = UDim2.fromOffset(sizePx, sizePx)
		circle.ZIndex = z
		circle.Visible = true
		local pop = circle:FindFirstChild("PopScale")
		if pop and pop:IsA("UIScale") then
			pop.Scale = 1
		end
	end

	placeCircle(colorCircle, colorCenter, colorPx, 50)
	placeCircle(coralCircle, coralStart, coralPx, 60)

	-- Coral slides through the color circle's center on its way to the backpack.
	-- The color circle stays put until that crossing, then both share the rest.
	local leg1 = (colorCenter - coralStart).Magnitude
	local leg2 = (target - colorCenter).Magnitude
	local pathLen = math.max(1, leg1 + leg2)
	local crossEase = math.clamp(leg1 / pathLen, 0, 0.98)

	local t0 = os.clock()
	local labelBelowOffset = coralPx * 0.5 + wheelPx(BASE_NAME_BELOW_PX)
	local nameLbl = nameLabel
	if nameLbl and nameLbl:IsA("TextLabel") then
		nameLbl.Parent = gui
		nameLbl.ZIndex = 70
		applyFlyAmountLabel(nameLbl, amount)
		nameLbl.Position = UDim2.fromOffset(coralStart.X, coralStart.Y + labelBelowOffset)
	end
	local conn: RBXScriptConnection? = nil
	conn = RunService.RenderStepped:Connect(function()
		if abortRequested then
			if conn then
				conn:Disconnect()
			end
			UiHaptics.cancel()
			if nameLbl and nameLbl.Parent then
				nameLbl:Destroy()
			end
			colorCircle:Destroy()
			coralCircle:Destroy()
			restoreFlyLayer()
			if currentClaim then
				claim(currentClaim.itemId, currentClaim.token)
			end
			finishBusy()
			return
		end
		local u = math.clamp((os.clock() - t0) / FLY_SEC, 0, 1)
		local e = u * u * (3 - 2 * u)
		local coralPos: Vector2
		if e >= crossEase then
			local along = if crossEase >= 0.98 then 1 else (e - crossEase) / (1 - crossEase)
			coralPos = colorCenter:Lerp(target, along)
		else
			local along = if crossEase <= 0 then 1 else e / crossEase
			coralPos = coralStart:Lerp(colorCenter, along)
		end
		local coralScale = 1 - e * 0.6
		coralCircle.Position = UDim2.fromOffset(coralPos.X, coralPos.Y)
		coralCircle.Size = UDim2.fromOffset(coralPx * coralScale, coralPx * coralScale)
		if e >= crossEase then
			colorCircle.Position = UDim2.fromOffset(coralPos.X, coralPos.Y)
		else
			colorCircle.Position = UDim2.fromOffset(colorCenter.X, colorCenter.Y)
		end
		colorCircle.Size = UDim2.fromOffset(colorPx, colorPx)
		if nameLbl and nameLbl.Parent then
			local labelY = coralPos.Y + labelBelowOffset * (1 - e)
			nameLbl.Position = UDim2.fromOffset(coralPos.X, labelY)
			local riseScale = nameLbl:FindFirstChild("RiseScale")
			if riseScale and riseScale:IsA("UIScale") then
				riseScale.Scale = math.max(0.75, 1 - e * 0.25)
			end
		end
		if u >= 1 then
			if conn then
				conn:Disconnect()
			end
			if nameLbl and nameLbl.Parent then
				nameLbl:Destroy()
			end
			colorCircle:Destroy()
			coralCircle:Destroy()
			restoreFlyLayer()
			SeedWheelRevealApi.fireSlideToBackpackLanded()
			claim(itemId, token)
			finishBusy()
		end
	end)
	trackConn(conn :: RBXScriptConnection)
end

local function expandFromTarget(target: GuiObject, onDone: () -> ())
	disconnectAll()
	abortRequested = false
	local gui, host = ensureOverlay()
	applySeedWheelDisplayOrder(gui)
	clearOverlayExtras(gui)
	clearBandChildren(host)
	host.ClipsDescendants = true
	local cam = workspace.CurrentCamera
	local vp = if cam then cam.ViewportSize else Vector2.new(1280, 720)
	local colorPx = wheelPx(BASE_COLOR_PX, vp)
	local stepPx = wheelPx(BASE_STEP_PX, vp)
	local minBandW = 2 * (2 * stepPx + colorPx * 0.5)
	local bandW = math.max(vp.X * BAND_WIDTH_FRAC, minBandW)
	local bandH = colorPx + 8
	savedBandSize = Vector2.new(bandW, bandH)
	host.Size = UDim2.new(0, bandW, 0, bandH)
	positionBandAtSlot4Height(host, vp)
	local toCenter = overlayScreenPoint(host)
	local fromCenter = leftHudScreenCenter(target)
	host.AnchorPoint = Vector2.new(0.5, 0.5)
	host.Visible = true
	host.Position = UDim2.fromOffset(fromCenter.X, fromCenter.Y)
	host.Size = UDim2.fromOffset(8, 8)
	local t0 = os.clock()
	local conn: RBXScriptConnection? = nil
	conn = RunService.RenderStepped:Connect(function()
		local u = math.clamp((os.clock() - t0) / EXPAND_SEC, 0, 1)
		local e = u * u * (3 - 2 * u)
		local x = fromCenter.X + (toCenter.X - fromCenter.X) * e
		local y = fromCenter.Y + (toCenter.Y - fromCenter.Y) * e
		local s = e
		host.Position = UDim2.fromOffset(x, y)
		host.Size = UDim2.fromOffset(math.max(8, bandW * s), math.max(8, bandH * s))
		if u >= 1 then
			if conn then
				conn:Disconnect()
			end
			host.Size = UDim2.new(0, bandW, 0, bandH)
			host.Position = UDim2.fromOffset(toCenter.X, toCenter.Y)
			onDone()
		end
	end)
	trackConn(conn :: RBXScriptConnection)
end

abortActiveReveal = function(claimPending: boolean)
	abortRequested = true
	disconnectAll()
	queued = nil
	if claimPending and currentClaim then
		claim(currentClaim.itemId, currentClaim.token)
	end
	currentClaim = nil
	busy = false
	busySince = 0
	abortRequested = false
end

playReveal = function(
	itemId: string,
	token: number,
	amount: number,
	colorIndex: number,
	colorWasUnlocked: boolean,
	manual: boolean?
)
	if manual ~= true and not SeedWheelAutoRollState.isEnabled() then
		return
	end
	if busy then
		queued = {
			itemId = itemId,
			token = token,
			amount = amount,
			colorIndex = colorIndex,
			colorWasUnlocked = colorWasUnlocked,
			manual = manual,
		}
		return
	end
	if not SeedWheel.isWheelItem(itemId) then
		warn("[SEEDWHEEL] Bad item", itemId)
		claim(itemId, token)
		finishBusy()
		return
	end
	busy = true
	busySince = os.clock()
	currentClaim = { itemId = itemId, token = token, colorIndex = colorIndex }
	-- Tutorial can target this hue as soon as the award starts.
	SeedWheelRevealApi.lastAwardedItemId = itemId
	SeedWheelRevealApi.lastAwardedColorIndex = math.clamp(math.floor(colorIndex), 1, 14)
	playerGui:SetAttribute("OceanTD_TutorialHueIndex", SeedWheelRevealApi.lastAwardedColorIndex)
	disconnectAll()
	abortRequested = false
	preloadWheelIcons()
	local gui, host = ensureOverlay()
	applySeedWheelDisplayOrder(gui)
	clearOverlayExtras(gui)
	clearBandChildren(host)
	host.ClipsDescendants = true

	local cam = workspace.CurrentCamera
	local vp = if cam then cam.ViewportSize else Vector2.new(1280, 720)
	local halfW = layoutBandForReveal(host, vp)
	local coralPx = wheelPx(BASE_CORAL_FINAL_PX, vp)
	local huePx = math.max(8, math.floor(coralPx * HUE_CENTER_OF_CORAL + 0.5))
	local hueBias = math.floor(huePx * HUE_CENTER_SHIFT_FRAC + 0.5)
	local stepPx = wheelPx(BASE_STEP_PX, vp)
	local hueBrush: ImageLabel? = nil
	local hueRing: Frame? = nil
	local hueOdds: Frame? = nil

	local function clearHueBrush()
		if hueBrush then
			hueBrush:Destroy()
			hueBrush = nil
		end
		if hueRing then
			hueRing:Destroy()
			hueRing = nil
		end
		if hueOdds then
			hueOdds:Destroy()
			hueOdds = nil
		end
	end

	local function bundleAndFly(colorWinner: Frame, coralWinner: ImageLabel, nameLabel: TextLabel?, amount: number)
		local coralStart = overlayScreenPoint(coralWinner)
		local colorCenter = overlayScreenPoint(colorWinner)
		clearHueBrush()
		flyBundle(colorWinner, coralWinner, coralStart, colorCenter, itemId, token, amount, nameLabel, coralPx, huePx)
	end

	-- 1) Coral spin first.
	local coralSeq = buildIdSequence(itemId)
	local coralWinner0 = #coralSeq - 3
	local coralIcons: { GuiObject } = {}
	for i, id in ipairs(coralSeq) do
		local icon = SeedWheel.iconFor(id) or ""
		local img = makeCoralCircle(host, icon, Z_CORAL + i, coralPx)
		img.Visible = false
		table.insert(coralIcons, img)
	end

	local coralPopStarted = false
	local function beginCoralLandPop()
		if coralPopStarted then
			return
		end
		local earlyWinner = coralIcons[coralWinner0 + 1] :: ImageLabel?
		if not earlyWinner or not earlyWinner.Parent then
			return
		end
		coralPopStarted = true
		earlyWinner.ZIndex = Z_CORAL + 20
		-- With the land pop (starts CORAL_POP_LEAD_SEC before spin end), not spin onDone.
		playColorBurstSound(0.72)
		playCoralLandPop(earlyWinner)
	end

	local nameLabel = spawnCoralNameLabel(gui, host)
	local fullNamePx = wheelPx(BASE_LABEL_H)
	local namePop: Tween? = nil
	local shownCoralId = ""
	local function showCoralName(slot: number)
		local id = coralSeq[slot + 1]
		if typeof(id) ~= "string" or id == "" or id == shownCoralId or not nameLabel.Parent then
			return
		end
		shownCoralId = id
		local display = coralDisplayName(id)
		nameLabel.Text = display
		nameLabel.Size = UDim2.fromOffset(
			math.max(wheelPx(BASE_LABEL_W_MIN), math.ceil(#display * fullNamePx * 0.62)),
			math.floor(fullNamePx * 1.35 + 0.5)
		)
		if namePop then
			namePop:Cancel()
			namePop = nil
		end
		nameLabel.TextSize = math.max(1, math.floor(fullNamePx * 0.35 + 0.5))
		local pop = TweenService:Create(nameLabel, TweenInfo.new(0.12, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
			TextSize = fullNamePx,
		})
		namePop = pop
		pop:Play()
	end
	showCoralName(0)

	runSpin(host, halfW, coralIcons, coralWinner0, coralPx, pickSpinSec(CORAL_SPIN_SEC, true), function()
		local coralWinner = coralIcons[coralWinner0 + 1] :: ImageLabel?
		local coralPeek1 = coralIcons[coralWinner0 + 2]
		local coralPeek2 = coralIcons[coralWinner0 + 3]
		for i, img in ipairs(coralIcons) do
			if img ~= coralWinner and img ~= coralPeek1 and img ~= coralPeek2 then
				img:Destroy()
			end
		end
		if coralPeek1 then
			coralPeek1:Destroy()
		end
		if coralPeek2 then
			coralPeek2:Destroy()
		end
		if not coralWinner or not coralWinner.Parent then
			claim(itemId, token)
			finishBusy()
			return
		end

		coralWinner.Position = UDim2.new(0.5, 0, 0.5, 0)
		coralWinner.Size = UDim2.fromOffset(coralPx, coralPx)
		local coralPop = coralWinner:FindFirstChild("PopScale")
		if coralPop and coralPop:IsA("UIScale") then
			coralPop.Scale = 1
		end
		coralWinner.ImageTransparency = 0
		coralWinner.BackgroundTransparency = 1
		coralWinner.ZIndex = Z_CORAL + 20

		if not coralPopStarted then
			playColorBurstSound(0.72)
			playCoralLandPop(coralWinner)
		end
		if shownCoralId ~= itemId then
			showCoralName(coralWinner0)
		end

		-- 2) Hue spin, shifted right so it sits beside the parked coral.
		local colorPool = HueRarity.indices(itemId)
		local colorSeq = buildColorSequence(colorIndex, colorPool)
		local colorWinner0 = #colorSeq - 3
		local colorIcons: { GuiObject } = {}
		for i, idx in ipairs(colorSeq) do
			local f = makeColorCircle(host, SeedWheel.colorForIndex(idx), Z_COLOR + i, huePx, itemId, idx)
			f.Visible = false
			table.insert(colorIcons, f)
		end

		local brush = Instance.new("ImageLabel")
		brush.Name = "HuePaintbrush"
		brush.BackgroundTransparency = 1
		brush.BorderSizePixel = 0
		brush.Image = PAINTBRUSH_ICON
		brush.ScaleType = Enum.ScaleType.Fit
		brush.AnchorPoint = Vector2.new(0.5, 0.5)
		local brushPx = math.floor(huePx * 0.72 + 0.5)
		brush.Size = UDim2.fromOffset(brushPx, brushPx)
		brush.Position = UDim2.new(0.5, hueBias, 0.5, 0)
		brush.ZIndex = Z_CORAL + 17
		brush.Active = false
		brush.Parent = host
		hueBrush = brush

		-- Fixed white outline on the center hue slot. It does not travel with the spin.
		local ring = Instance.new("Frame")
		ring.Name = "HueCenterStroke"
		ring.BackgroundTransparency = 1
		ring.BorderSizePixel = 0
		ring.AnchorPoint = Vector2.new(0.5, 0.5)
		ring.Position = UDim2.new(0.5, hueBias, 0.5, 0)
		ring.Size = UDim2.fromOffset(huePx, huePx)
		ring.ZIndex = Z_CORAL + 14
		ring.Active = false
		ring.Parent = host
		roundCorner(ring)
		local ringStroke = Instance.new("UIStroke")
		ringStroke.Color = Color3.new(1, 1, 1)
		ringStroke.Transparency = 0
		ringStroke.Thickness = UiViewportTags.coralSpinnerStrokeThickness() + 2
		ringStroke.LineJoinMode = Enum.LineJoinMode.Round
		ringStroke.BorderStrokePosition = Enum.BorderStrokePosition.Outer
		ringStroke.Parent = ring
		hueRing = ring

		-- Rarity name to the right of the center hue circle. Odds sit under that title.
		local hudScale = UiPopupScale.getHud(vp)
		local titlePx = math.max(8, math.floor(34 * hudScale + 0.5))
		local oddsInPx = math.max(8, math.floor(titlePx * 0.55 + 0.5))
		local fullNumPx = math.max(8, math.floor(titlePx * 0.72 + 0.5))
		local hueCenter = overlayScreenPoint(host)
		local column = Instance.new("Frame")
		column.Name = "HueRarityReadout"
		column.BackgroundTransparency = 1
		column.BorderSizePixel = 0
		column.AnchorPoint = Vector2.new(0, 0.5)
		column.AutomaticSize = Enum.AutomaticSize.XY
		column.Position = UDim2.fromOffset(
			hueCenter.X + hueBias + math.floor(huePx * 0.5 + wheelPx(14) + 0.5),
			hueCenter.Y
		)
		column.ZIndex = Z_CORAL + 18
		column.Active = false
		column.Parent = gui
		hueOdds = column
		local columnLayout = Instance.new("UIListLayout")
		columnLayout.FillDirection = Enum.FillDirection.Vertical
		columnLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
		columnLayout.SortOrder = Enum.SortOrder.LayoutOrder
		columnLayout.Padding = UDim.new(0, math.max(0, wheelPx(2)))
		columnLayout.Parent = column

		local function makeReadoutLine(name: string, textPx: number, order: number, color: Color3, strokeColor: Color3, strokePx: number): TextLabel
			local lbl = Instance.new("TextLabel")
			lbl.Name = name
			lbl.BackgroundTransparency = 1
			lbl.BorderSizePixel = 0
			lbl.AutomaticSize = Enum.AutomaticSize.XY
			lbl.Size = UDim2.fromOffset(0, 0)
			lbl.Font = UiTheme.Font
			lbl.Text = ""
			lbl.TextColor3 = color
			lbl.TextSize = textPx
			lbl.TextScaled = false
			lbl.TextWrapped = false
			lbl.TextXAlignment = Enum.TextXAlignment.Center
			lbl.TextYAlignment = Enum.TextYAlignment.Center
			lbl.LayoutOrder = order
			lbl.ZIndex = Z_CORAL + 18
			lbl.Active = false
			lbl.Parent = column
			local textStroke = Instance.new("UIStroke")
			textStroke.Color = strokeColor
			textStroke.Thickness = strokePx
			textStroke.Transparency = 0
			textStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
			textStroke.LineJoinMode = Enum.LineJoinMode.Round
			textStroke.Parent = lbl
			return lbl
		end

		local classLabel = makeReadoutLine(
			"RarityClass",
			titlePx,
			1,
			Color3.fromRGB(240, 255, 245),
			Color3.fromRGB(0, 40, 20),
			math.max(1, 1.8 * hudScale)
		)
		local oddsRow = Instance.new("Frame")
		oddsRow.Name = "OddsRow"
		oddsRow.BackgroundTransparency = 1
		oddsRow.BorderSizePixel = 0
		oddsRow.AutomaticSize = Enum.AutomaticSize.XY
		oddsRow.Size = UDim2.fromOffset(0, 0)
		oddsRow.LayoutOrder = 2
		oddsRow.ZIndex = Z_CORAL + 18
		oddsRow.Active = false
		oddsRow.Parent = column
		local oddsRowLayout = Instance.new("UIListLayout")
		oddsRowLayout.FillDirection = Enum.FillDirection.Horizontal
		oddsRowLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
		oddsRowLayout.VerticalAlignment = Enum.VerticalAlignment.Center
		oddsRowLayout.Padding = UDim.new(0, math.max(2, wheelPx(4)))
		oddsRowLayout.SortOrder = Enum.SortOrder.LayoutOrder
		oddsRowLayout.Parent = oddsRow
		local inLabel = makeReadoutLine("OddsIn", oddsInPx, 1, Color3.new(1, 1, 1), Color3.new(0, 0, 0), math.max(1, hudScale))
		inLabel.Parent = oddsRow
		inLabel.TextXAlignment = Enum.TextXAlignment.Left
		inLabel.Text = "1 in"
		local numLabel = makeReadoutLine("OddsN", fullNumPx, 2, Color3.new(1, 1, 1), Color3.new(0, 0, 0), math.max(1, hudScale))
		numLabel.TextXAlignment = Enum.TextXAlignment.Left
		numLabel.Parent = oddsRow
		local oddsPop: Tween? = nil
		local shownIdx: number? = nil

		local function showCenterOdds(slot: number)
			local idx = colorSeq[slot + 1]
			if typeof(idx) ~= "number" or not numLabel.Parent or idx == shownIdx then
				return
			end
			shownIdx = idx
			classLabel.Text = HueRarity.className(itemId, idx) or ""
			local n = HueRarity.oneIn(itemId, idx)
			numLabel.Text = if n then tostring(n) else ""
			if oddsPop then
				oddsPop:Cancel()
				oddsPop = nil
			end
			numLabel.TextSize = math.max(1, math.floor(fullNumPx * 0.35 + 0.5))
			local pop = TweenService:Create(numLabel, TweenInfo.new(0.12, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
				TextSize = fullNumPx,
			})
			oddsPop = pop
			pop:Play()
		end

		showCenterOdds(0)
		host.ClipsDescendants = false

		runSpin(host, halfW, colorIcons, colorWinner0, coralPx, pickSpinSec(SPIN_SEC, false), function()
			local colorWinner = colorIcons[colorWinner0 + 1] :: Frame?
			local colorLeft1 = if colorWinner0 >= 1 then colorIcons[colorWinner0] else nil
			local colorLeft2 = if colorWinner0 >= 2 then colorIcons[colorWinner0 - 1] else nil
			local colorPeek1 = colorIcons[colorWinner0 + 2]
			local colorPeek2 = colorIcons[colorWinner0 + 3]
			for i, img in ipairs(colorIcons) do
				if img ~= colorWinner and img ~= colorLeft1 and img ~= colorLeft2 and img ~= colorPeek1 and img ~= colorPeek2 then
					img:Destroy()
				end
			end
			if not colorWinner then
				clearHueBrush()
				claim(itemId, token)
				finishBusy()
				return
			end

			UiHaptics.pulseTiny()

			colorWinner.Position = UDim2.new(0.5, hueBias, 0.5, 0)
			colorWinner.Visible = true
			styleByOffset(colorWinner, 0, halfW, coralPx, OUTER_PEEK_SCALE_COLOR, stepPx, true)
			colorWinner.ZIndex = Z_COLOR
			local stroke = colorWinner:FindFirstChildWhichIsA("UIStroke")
			if stroke then
				stroke.Transparency = 0.15
			end
			local function hideExtra(extra: any)
				if typeof(extra) == "Instance" and extra:IsA("GuiObject") then
					extra.Visible = false
				end
			end
			hideExtra(colorLeft1)
			hideExtra(colorLeft2)
			hideExtra(colorPeek1)
			hideExtra(colorPeek2)

			coralWinner.ZIndex = Z_CORAL + 20

			-- 3) Mini circles firework out, then slide to Slot4.
			local winColor = colorWinner.BackgroundColor3
			local burstCenter = screenCenterWithInset(colorWinner)
			runColorFirework(gui, burstCenter, winColor, itemId, colorIndex, function()
				if colorLeft1 then
					colorLeft1:Destroy()
				end
				if colorLeft2 then
					colorLeft2:Destroy()
				end
				if colorPeek1 then
					colorPeek1:Destroy()
				end
				if colorPeek2 then
					colorPeek2:Destroy()
				end
				bundleAndFly(colorWinner, coralWinner, nameLabel, amount)
			end, colorWasUnlocked)
		end, OUTER_PEEK_SCALE_COLOR, stepPx, nil, nil, hueBias, true, showCenterOdds, true)
	end, OUTER_PEEK_SCALE_CORAL, stepPx, CORAL_POP_LEAD_SEC, beginCoralLandPop, nil, false, showCoralName)
end

Remotes.get("SeedWheelAutoRollSync").OnClientEvent:Connect(function(enabled: any, remaining: any)
	SeedWheelAutoRollState.applySync(enabled, remaining)
end)

Remotes.get("SeedWheelReveal").OnClientEvent:Connect(function(itemId: any, token: any, amount: any, colorIndex: any)
	local manual = SeedWheelAutoRollState.consumeManual()
	if not manual and not SeedWheelAutoRollState.isEnabled() then
		return
	end
	if typeof(itemId) ~= "string" or typeof(token) ~= "number" then
		return
	end
	watchdogRecoverIfStuck()
	local add = math.max(1, math.floor(tonumber(amount) or 1))
	local cidx = math.clamp(math.floor(tonumber(colorIndex) or SeedWheel.pickRandomColorIndex(nil, itemId)), 1, 14)
	local colorWasUnlocked = false
	if typeof(itemId) == "string" and itemId ~= "" then
		colorWasUnlocked = CoralColorUnlockState.isUnlocked(itemId, cidx)
		CoralColorUnlockState.markUnlocked(itemId, cidx)
	end
	task.spawn(playReveal, itemId, token, add, cidx, colorWasUnlocked, manual)
end)

SeedWheelRevealApi.collapseToTarget = function(target: GuiObject, onDone: () -> ())
	abortActiveReveal(true)
	tweenWheelTo(target, true, onDone)
end

SeedWheelRevealApi.expandFromTarget = function(target: GuiObject, onDone: () -> ())
	expandFromTarget(target, onDone)
end

SeedWheelRevealApi.abortActiveReveal = abortActiveReveal

SeedWheelRevealApi.isBusy = function(): boolean
	return busy
end

do
	local published = false
	RunService.Heartbeat:Connect(function()
		if busy == published then
			return
		end
		published = busy
		playerGui:SetAttribute("OceanTD_SeedWheelBusy", busy)
	end)
end

playerGui:GetAttributeChangedSignal("OceanTD_SkillsBubblesOpen"):Connect(function()
	local overlay = playerGui:FindFirstChild("OceanTD_SeedWheel")
	if overlay and overlay:IsA("ScreenGui") then
		applySeedWheelDisplayOrder(overlay)
	end
end)

playerGui:GetAttributeChangedSignal("OceanTD_ReefReportOpen"):Connect(function()
	local overlay = playerGui:FindFirstChild("OceanTD_SeedWheel")
	if overlay and overlay:IsA("ScreenGui") then
		applySeedWheelDisplayOrder(overlay)
	end
end)

playerGui:GetAttributeChangedSignal("OceanTD_StoreOpen"):Connect(function()
	local overlay = playerGui:FindFirstChild("OceanTD_SeedWheel")
	if overlay and overlay:IsA("ScreenGui") then
		applySeedWheelDisplayOrder(overlay)
	end
end)

task.spawn(function()
	JoinIntroGate.waitUntilIdle(120)
	preloadWheelIcons()
end)

print("[SEEDWHEEL] Ready")
