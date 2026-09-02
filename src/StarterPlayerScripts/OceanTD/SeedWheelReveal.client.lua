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
local ItemCatalog = require(oceanRoot:WaitForChild("Shared"):WaitForChild("ItemCatalog"))
local UiTheme = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiTheme"))
local UiViewportTags = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiViewportTags"))
local InventoryState = require(script.Parent:WaitForChild("InventoryState"))
local CoralColorUnlockState = require(script.Parent:WaitForChild("CoralColorUnlockState"))
local SeedWheelAutoRollState = require(script.Parent:WaitForChild("SeedWheelAutoRollState"))
local SeedWheelRevealApi = require(script.Parent:WaitForChild("SeedWheelRevealApi"))

local BASE_COLOR_PX = 65
local BASE_CORAL_FINAL_PX = 52
local BAND_WIDTH_FRAC = 0.33
local BAND_TOP_FRAC = 0.03 -- fallback when Slot4 screen pos unavailable
local BASE_STEP_PX = 70
local SPIN_SEC = 4.992
local CORAL_SPIN_SEC = SPIN_SEC * 1.2 / 0.8 -- 20% longer, 20% slower than color spin
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
local NAME_RISE_SEC = 0.48
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

local overlay: ScreenGui? = nil
local band: Frame? = nil
local busy = false
local busySince = 0
local BUSY_WATCHDOG_SEC = 20
local pitchCursor = 0.92
type Queued = { itemId: string, token: number, amount: number, colorIndex: number, colorWasUnlocked: boolean }
local queued: Queued? = nil
local activeConns: { RBXScriptConnection } = {}
local abortRequested = false
local currentClaim: { itemId: string, token: number }? = nil
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

local playReveal: (string, number, number, number, boolean) -> ()

local function claim(itemId: string, token: number)
	local ok, err = pcall(function()
		Remotes.get("SeedWheelClaim"):FireServer(itemId, token)
	end)
	if not ok then
		warn("[SEEDWHEEL] Claim failed", err)
	end
end

local function finishBusy()
	busy = false
	busySince = 0
	currentClaim = nil
	local q = queued
	queued = nil
	if q and SeedWheelAutoRollState.isEnabled() then
		task.defer(playReveal, q.itemId, q.token, q.amount, q.colorIndex, q.colorWasUnlocked)
	end
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

local function applySeedWheelDisplayOrder(gui: ScreenGui)
	-- Under skills bubbles while open; otherwise under MobileLeftUI (♪ / dPad).
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

local function positionBandAtSlot4Height(host: Frame, viewport: Vector2)
	local slotCenter = backpackOverlayCenter()
	if slotCenter then
		host.AnchorPoint = Vector2.new(0.5, 0.5)
		host.Position = UDim2.fromOffset(viewport.X * 0.5, slotCenter.Y)
	else
		host.AnchorPoint = Vector2.new(0.5, 0)
		host.Position = UDim2.fromScale(0.5, BAND_TOP_FRAC)
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

local function spawnCoralNameLabel(gui: ScreenGui, host: Frame, displayName: string): TextLabel
	local center = overlayScreenPoint(host)
	local lbl = Instance.new("TextLabel")
	lbl.Name = "CoralName"
	lbl.BackgroundTransparency = 1
	lbl.AnchorPoint = Vector2.new(0.5, 0.5)
	lbl.Position = UDim2.fromOffset(center.X, center.Y)
	lbl.Size = UDim2.fromOffset(math.max(wheelPx(BASE_LABEL_W_MIN), #displayName * wheelPx(BASE_LABEL_CHAR_W)), wheelPx(BASE_LABEL_H))
	lbl.Font = UiTheme.Font
	lbl.Text = displayName
	lbl.TextColor3 = Color3.new(1, 1, 1)
	lbl.TextScaled = true
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
	scale.Scale = 0
	scale.Parent = lbl

	local riseInfo = TweenInfo.new(NAME_RISE_SEC, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	TweenService:Create(scale, riseInfo, { Scale = 1 }):Play()
	TweenService:Create(lbl, riseInfo, {
		Position = UDim2.fromOffset(center.X, center.Y + (wheelPx(BASE_COLOR_PX) * 0.5 + wheelPx(BASE_NAME_BELOW_PX))),
	}):Play()

	return lbl
end

-- Squash → overshoot → settle (cartoony "pop" when the coral lands).
local function hideCoralOuterStroke(coral: ImageLabel)
	local ring = coral:FindFirstChild("InnerRing")
	if ring then
		ring:Destroy()
	end
end

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
		hideCoralOuterStroke(coral)
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

local function styleByOffset(guiObj: GuiObject, offsetX: number, _halfW: number, baseSize: number, outerMinScale: number?, stepPx: number)
	local scale = circleScaleAtOffset(offsetX, outerMinScale, stepPx)
	local stepDist = math.abs(offsetX) / stepPx
	local trans = if stepDist <= 1 then stepDist * 0.26 else 0.26 + (stepDist - 1) * 0.42
	guiObj.Size = UDim2.fromOffset(baseSize * scale, baseSize * scale)
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

local function buildColorSequence(winnerIndex: number): { number }
	local pool = SeedWheel.colorIndices()
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
	onEarlyDone: (() -> ())?
)
	local totalSteps = winnerIndex0
	local t0 = os.clock()
	local lastFloor = -1
	local earlyDone = false
	local conn: RBXScriptConnection? = nil

	local function layoutIcons(centerIndex: number)
		local clipPad = wheelPx(BASE_STROKE_CLIP_PAD)
		for i, img in ipairs(icons) do
			local ox = (centerIndex - (i - 1)) * stepPx
			img.Position = UDim2.new(0.5, ox, 0.5, 0)
			local scale = circleScaleAtOffset(ox, outerMinScale, stepPx)
			local radius = baseSize * scale * 0.5
			-- Hide once circle + UIStroke would extend past the band (prevents edge slivers).
			if ox - radius - clipPad < -halfW or ox + radius + clipPad > halfW then
				img.Visible = false
			else
				img.Visible = true
				styleByOffset(img, ox, halfW, baseSize, outerMinScale, stepPx)
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
	holder: Frame,
	start: Vector2,
	itemId: string,
	token: number,
	amount: number,
	nameLabel: TextLabel?,
	colorPx: number
)
	local target = backpackOverlayCenter()
	if not target then
		local cam = workspace.CurrentCamera
		local vp = if cam then cam.ViewportSize else Vector2.new(1280, 720)
		target = Vector2.new(vp.X * 0.92, vp.Y * 0.12)
	end

	local gui = overlay
	if not gui then
		claim(itemId, token)
		holder:Destroy()
		finishBusy()
		return
	end

	holder.Parent = gui
	holder.AnchorPoint = Vector2.new(0.5, 0.5)
	holder.Position = UDim2.fromOffset(start.X, start.Y)
	holder.Size = UDim2.fromOffset(colorPx, colorPx)
	holder.ZIndex = 50

	local t0 = os.clock()
	local labelBelowOffset = colorPx * 0.5 + wheelPx(BASE_NAME_BELOW_PX)
	local nameLbl = nameLabel
	if nameLbl and nameLbl:IsA("TextLabel") then
		nameLbl.Parent = gui
		nameLbl.ZIndex = holder.ZIndex + 5
		applyFlyAmountLabel(nameLbl, amount)
		local hc = overlayScreenPoint(holder)
		nameLbl.Position = UDim2.fromOffset(hc.X, hc.Y + labelBelowOffset)
	end
	local conn: RBXScriptConnection? = nil
	conn = RunService.RenderStepped:Connect(function()
		if abortRequested then
			if conn then
				conn:Disconnect()
			end
			if nameLbl and nameLbl.Parent then
				nameLbl:Destroy()
			end
			holder:Destroy()
			if currentClaim then
				claim(currentClaim.itemId, currentClaim.token)
			end
			finishBusy()
			return
		end
		local u = math.clamp((os.clock() - t0) / FLY_SEC, 0, 1)
		local e = u * u * (3 - 2 * u)
		local x = start.X + (target.X - start.X) * e
		local y = start.Y + (target.Y - start.Y) * e
		local s = 1 - e * 0.45
		holder.Position = UDim2.fromOffset(x, y)
		holder.Size = UDim2.fromOffset(colorPx * s, colorPx * s)
		if nameLbl and nameLbl.Parent then
			local hc = overlayScreenPoint(holder)
			-- Ease from below the circle up to centered on it while flying right.
			local labelY = hc.Y + labelBelowOffset * (1 - e)
			nameLbl.Position = UDim2.fromOffset(hc.X, labelY)
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
			holder:Destroy()
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

playReveal = function(itemId: string, token: number, amount: number, colorIndex: number, colorWasUnlocked: boolean)
	if not SeedWheelAutoRollState.isEnabled() then
		return
	end
	if busy then
		queued = {
			itemId = itemId,
			token = token,
			amount = amount,
			colorIndex = colorIndex,
			colorWasUnlocked = colorWasUnlocked,
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
	currentClaim = { itemId = itemId, token = token }
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
	local colorPx = wheelPx(BASE_COLOR_PX, vp)
	local coralPx = wheelPx(BASE_CORAL_FINAL_PX, vp)
	local stepPx = wheelPx(BASE_STEP_PX, vp)

	local function bundleAndFly(colorWinner: Frame, coralWinner: ImageLabel, nameLabel: TextLabel?, amount: number)
		local start = overlayScreenPoint(colorWinner)

		colorWinner.Visible = false
		coralWinner.Visible = false

		local holder = Instance.new("Frame")
		holder.Name = "SeedWheelBundle"
		holder.BackgroundTransparency = 1
		holder.AnchorPoint = Vector2.new(0.5, 0.5)
		holder.Size = UDim2.fromOffset(colorPx, colorPx)
		holder.Position = UDim2.fromOffset(start.X, start.Y)
		holder.ZIndex = 50
		holder.Parent = gui

		colorWinner.Parent = holder
		colorWinner.Position = UDim2.fromScale(0.5, 0.5)
		colorWinner.Size = UDim2.fromScale(1, 1)
		colorWinner.ZIndex = 1
		colorWinner.Visible = true

		coralWinner.Parent = holder
		coralWinner.Position = UDim2.fromScale(0.5, 0.5)
		coralWinner.Size = UDim2.fromScale(coralPx / colorPx, coralPx / colorPx)
		coralWinner.ZIndex = 2
		coralWinner.Visible = true

		flyBundle(holder, start, itemId, token, amount, nameLabel, colorPx)
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
		playCoralLandPop(earlyWinner)
	end

	runSpin(host, halfW, coralIcons, coralWinner0, coralPx, CORAL_SPIN_SEC, function()
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
		coralWinner.ImageTransparency = 0
		coralWinner.BackgroundTransparency = 1
		coralWinner.ZIndex = Z_CORAL + 20

		if not coralPopStarted then
			playCoralLandPop(coralWinner)
		end
		local nameLabel = spawnCoralNameLabel(gui, host, coralDisplayName(itemId))

		-- 2) Color spin behind the parked coral.
		local colorSeq = buildColorSequence(colorIndex)
		local colorWinner0 = #colorSeq - 3
		local colorIcons: { GuiObject } = {}
		for i, idx in ipairs(colorSeq) do
			local f = makeColorCircle(host, SeedWheel.colorForIndex(idx), Z_COLOR + i, colorPx, itemId, idx)
			f.Visible = false
			table.insert(colorIcons, f)
		end

		runSpin(host, halfW, colorIcons, colorWinner0, colorPx, SPIN_SEC, function()
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
				claim(itemId, token)
				finishBusy()
				return
			end

			colorWinner.Position = UDim2.new(0.5, 0, 0.5, 0)
			colorWinner.Visible = true
			styleByOffset(colorWinner, 0, halfW, colorPx, OUTER_PEEK_SCALE_COLOR, stepPx)
			colorWinner.ZIndex = Z_COLOR
			local stroke = colorWinner:FindFirstChildWhichIsA("UIStroke")
			if stroke then
				stroke.Transparency = 0.15
			end
			if colorLeft2 and colorLeft2:IsA("Frame") then
				colorLeft2.Position = UDim2.new(0.5, -stepPx * 2, 0.5, 0)
				colorLeft2.Visible = true
				styleByOffset(colorLeft2, -stepPx * 2, halfW, colorPx, OUTER_PEEK_SCALE_COLOR, stepPx)
				colorLeft2.ZIndex = Z_COLOR + 4
			end
			if colorLeft1 and colorLeft1:IsA("Frame") then
				colorLeft1.Position = UDim2.new(0.5, -stepPx, 0.5, 0)
				colorLeft1.Visible = true
				styleByOffset(colorLeft1, -stepPx, halfW, colorPx, OUTER_PEEK_SCALE_COLOR, stepPx)
				colorLeft1.ZIndex = Z_COLOR + 5
			end
			if colorPeek1 and colorPeek1:IsA("Frame") then
				colorPeek1.Position = UDim2.new(0.5, stepPx, 0.5, 0)
				colorPeek1.Visible = true
				styleByOffset(colorPeek1, stepPx, halfW, colorPx, OUTER_PEEK_SCALE_COLOR, stepPx)
				colorPeek1.ZIndex = Z_COLOR + 5
			end
			if colorPeek2 and colorPeek2:IsA("Frame") then
				colorPeek2.Position = UDim2.new(0.5, stepPx * 2, 0.5, 0)
				colorPeek2.Visible = true
				styleByOffset(colorPeek2, stepPx * 2, halfW, colorPx, OUTER_PEEK_SCALE_COLOR, stepPx)
				colorPeek2.ZIndex = Z_COLOR + 4
			end

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
		end, OUTER_PEEK_SCALE_COLOR, stepPx)
	end, OUTER_PEEK_SCALE_CORAL, stepPx, CORAL_POP_LEAD_SEC, beginCoralLandPop)
end

Remotes.get("SeedWheelAutoRollSync").OnClientEvent:Connect(function(enabled: any)
	SeedWheelAutoRollState._setEnabled(enabled == true)
end)

Remotes.get("SeedWheelReveal").OnClientEvent:Connect(function(itemId: any, token: any, amount: any, colorIndex: any)
	if not SeedWheelAutoRollState.isEnabled() then
		return
	end
	if typeof(itemId) ~= "string" or typeof(token) ~= "number" then
		return
	end
	watchdogRecoverIfStuck()
	local add = math.max(1, math.floor(tonumber(amount) or 1))
	local cidx = math.clamp(math.floor(tonumber(colorIndex) or SeedWheel.pickRandomColorIndex()), 1, 14)
	local colorWasUnlocked = false
	if typeof(itemId) == "string" and itemId ~= "" then
		colorWasUnlocked = CoralColorUnlockState.isUnlocked(itemId, cidx)
		CoralColorUnlockState.markUnlocked(itemId, cidx)
	end
	task.spawn(playReveal, itemId, token, add, cidx, colorWasUnlocked)
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

playerGui:GetAttributeChangedSignal("OceanTD_SkillsBubblesOpen"):Connect(function()
	local overlay = playerGui:FindFirstChild("OceanTD_SeedWheel")
	if overlay and overlay:IsA("ScreenGui") then
		applySeedWheelDisplayOrder(overlay)
	end
end)

task.spawn(preloadWheelIcons)

print("[SEEDWHEEL] Ready")
