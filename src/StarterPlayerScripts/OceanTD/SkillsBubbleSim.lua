--!strict
--[[
	Soft lava-lamp bubble physics for MobileSkillsA skill ImageButtons.
	Heartbeat only while open. Does not touch placement / other HUD systems.
	Bubble size + label placement use per-stage Studio templates (SkillStages);
	only PlotSize / EarnMore / PlaceMore / RHealth / Skip BTNs are playable bubbles.

	Coords: physics + hits use GuiObject.AbsolutePosition space.
	Pointer→abs is calibrated per grab (raw vs inset-subtracted) so we never guess
	IgnoreGuiInset wrong and snap above/below the cursor. Bounds = bubble layer AbsoluteSize.
	Bob = visual offset only. Pop-in / pop-out starts instantly; short stagger (~0.35s).
	BackgroundGradient (Studio) fades in/out over the same window.
]]
local GuiService = game:GetService("GuiService")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local oceanShared = ReplicatedStorage:WaitForChild("OceanTD"):WaitForChild("Shared")
local SkillStages = require(oceanShared:WaitForChild("SkillStages"))
local UiPopupScale = require(oceanShared:WaitForChild("UiPopupScale"))

local SkillsBubbleSim = {}

local MAX_BUBBLES = 40
local PHYS_DT = 1 / 30
local BOB_AMP = 3.0
local BOB_FREQ = 0.16
local DAMPING = 0.972
local SEPARATION = 0.48
local DRAG_SMOOTH = 1 -- 1 = lock under pointer (no lag snap); was 0.55
local RELEASE_VEL_SCALE = 0.88
local MAX_SPEED = 380
-- 30% faster than old 2s; stagger is short so motion starts instantly.
local POP_IN_WINDOW = 0.35
local POP_OUT_WINDOW = 0.35
local POP_OUT_SEC = 0.2
local POP_OVERSHOOT = 1.12
-- After Plot Size leads, other bubbles pop in at random times in this window (seconds).
local OTHER_POP_IN_DELAY_MIN = 0.22
local OTHER_POP_IN_DELAY_MAX = 0.82
local UNLOCK_SETTLE_SEC = 1
local UNLOCK_SETTLE_INFO = TweenInfo.new(UNLOCK_SETTLE_SEC, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
-- Extra label size on 720p+ (on top of HUD scale baked into bubble Size).
local HUD_BUBBLE_TEXT_BOOST = 1.5

type Bubble = {
	btn: GuiButton,
	scale: UIScale,
	radius: number,
	mass: number,
	x: number,
	y: number,
	vx: number,
	vy: number,
	phase: number,
	origParent: Instance,
	origPos: UDim2,
	origSize: UDim2,
	origAnchor: Vector2,
	origZ: number,
	settledScale: number, -- UIScale at the player's unlocked stage layout
	maxPopScale: number, -- pop-in peaks here (max stage), then settles to settledScale
}

type LabelLayoutSnap = {
	position: UDim2,
	size: UDim2,
	anchor: Vector2,
	textScaled: boolean,
	textSize: number,
	textX: Enum.TextXAlignment,
	textY: Enum.TextYAlignment,
}

-- Studio Icon under larger stage templates (WaveSpeedBTN / RollSpeedBTN / PlotSizeBTN / LuckBTN).
type IconLayoutSnap = {
	position: UDim2,
	size: UDim2,
	anchor: Vector2,
	zIndex: number,
	imageTransparency: number,
	scaleType: Enum.ScaleType,
}

type BubbleLayoutSnap = {
	sizeOffset: Vector2,
	sizeUdim: UDim2,
	labels: { LabelLayoutSnap },
	icon: IconLayoutSnap?,
}

type Drag = {
	bubble: Bubble,
	input: InputObject,
	grabX: number,
	grabY: number,
	subInset: boolean, -- pointer space chosen at grab (must match updates)
	startX: number,
	startY: number,
	moved: boolean,
}

-- Studio BackgroundGradient: GuiObject and/or UIGradient under MobileSkillsA.
type BgFade = {
	gui: GuiObject?,
	gradient: UIGradient?,
	bgTrans: number,
	imgTrans: number?,
	gradTrans: NumberSequence?,
}

local bubbles: { Bubble } = {}
local drags: { [InputObject]: Drag } = {}
local dragged: { [Bubble]: boolean } = {}
local mouseDragInput: InputObject? = nil
local running = false
local suppressed = false
local closing = false
local conn: RBXScriptConnection? = nil
local inputConns: { RBXScriptConnection } = {}
local layer: Frame? = nil
local hostGui: ScreenGui? = nil
local hostPanel: Instance? = nil
local cachedLayoutSnaps: { [number]: BubbleLayoutSnap }? = nil
local physAcc = 0
local bobTime = 0
local stopToken = 0
local bgFade: BgFade? = nil
local bgFades: { BgFade } = {}
local bgFadeAlpha = 0
local bgTweenConn: RBXScriptConnection? = nil
local gamepadFocus = 0 -- 1-based; 0 = none
local focusStroke: UIStroke? = nil
local onBubbleActivated: ((buttonName: string) -> ())? = nil
local readSkillStage: (string) -> number
local rejectFxToken = 0

-- Orbit locks on EarnMore / PlaceMore until Plot Size stage 2.
local LOCK_IMAGE = "rbxassetid://105420423737825"
local LOCK_SIZE_PX = 30
local LOCK_ORBIT_SPEED = 1.35 -- rad/sec
local LOCK_ORBIT_FRAC = 0.62 -- of bubble radius

type OrbitLock = {
	bubble: Bubble,
	icon: ImageLabel,
	angle: number,
}

local orbitLocks: { OrbitLock } = {}

-- Purchase progress (gates / lock icons). Active stage can be dialed below this.
-- Must be defined before syncOrbitLocks (local function scope).
local function readUnlockedStage(skillId: string): number
	local ok, ui = pcall(function()
		return require(script.Parent:WaitForChild("SkillPowerUpUI"))
	end)
	if ok and typeof(ui) == "table" then
		local getUnlocked = (ui :: any).getUnlockedStage
		if typeof(getUnlocked) == "function" then
			return SkillStages.clampStageFor(skillId, getUnlocked(skillId))
		end
		if typeof((ui :: any).getStage) == "function" then
			return SkillStages.clampStageFor(skillId, (ui :: any).getStage(skillId))
		end
	end
	return SkillStages.MIN_STAGE
end

local function unlockedStagesMap(): { [string]: number }
	return {
		PlotSize = readUnlockedStage("PlotSize"),
		PlaceMore = readUnlockedStage("PlaceMore"),
		EarnMore = readUnlockedStage("EarnMore"),
		RHealth = readUnlockedStage("RHealth"),
		Skip = readUnlockedStage("Skip"),
		WaveSpeed = readUnlockedStage("WaveSpeed"),
	}
end

local function clearOrbitLocks()
	for _, o in ipairs(orbitLocks) do
		if o.icon.Parent then
			o.icon:Destroy()
		end
	end
	table.clear(orbitLocks)
end

local function skillIdForBubble(b: Bubble): string?
	local def = SkillStages.fromButtonName(b.btn.Name)
	return if def then def.id else nil
end

local function syncOrbitLocks()
	clearOrbitLocks()
	if not running then
		return
	end
	local stages = unlockedStagesMap()
	local rng = Random.new()
	for _, b in ipairs(bubbles) do
		local id = skillIdForBubble(b)
		if id and SkillStages.isSkillLocked(id, stages) and b.btn.Parent then
			local old = b.btn:FindFirstChild("OceanTD_SkillGateLock")
			if old then
				old:Destroy()
			end
			local icon = Instance.new("ImageLabel")
			icon.Name = "OceanTD_SkillGateLock"
			icon.BackgroundTransparency = 1
			icon.Image = LOCK_IMAGE
			icon.Size = UDim2.fromOffset(LOCK_SIZE_PX, LOCK_SIZE_PX)
			icon.AnchorPoint = Vector2.new(0.5, 0.5)
			icon.Position = UDim2.fromScale(0.5, 0.5)
			icon.ZIndex = math.max(b.btn.ZIndex + 8, 90)
			icon.Active = false
			icon.Parent = b.btn
			table.insert(orbitLocks, {
				bubble = b,
				icon = icon,
				angle = rng:NextNumber(0, math.pi * 2),
			})
		end
	end
end

local function updateOrbitLocks(dt: number)
	for _, o in ipairs(orbitLocks) do
		if not o.icon.Parent or not o.bubble.btn.Parent then
			continue
		end
		o.angle += LOCK_ORBIT_SPEED * dt
		local r = math.max(14, o.bubble.radius * LOCK_ORBIT_FRAC)
		local ox = math.cos(o.angle) * r
		local oy = math.sin(o.angle) * r
		o.icon.Position = UDim2.new(0.5, ox, 0.5, oy)
	end
end

local function clearGamepadFocusVisual()
	if focusStroke then
		focusStroke:Destroy()
		focusStroke = nil
	end
end

local POP_IN_INFO = TweenInfo.new(0.32, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local POP_SETTLE_INFO = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local POP_OUT_INFO = TweenInfo.new(POP_OUT_SEC, Enum.EasingStyle.Back, Enum.EasingDirection.In)
local BG_FADE_IN_INFO = TweenInfo.new(POP_IN_WINDOW, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local BG_FADE_OUT_INFO = TweenInfo.new(POP_OUT_WINDOW, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

-- Window pointer → AbsolutePosition candidates (InventoryUI: mouse is inset-inclusive; Abs often is not).
local function pointerCandidates(wx: number, wy: number): { Vector2 }
	local inset = GuiService:GetGuiInset()
	local list = { Vector2.new(wx, wy) }
	if inset.X ~= 0 or inset.Y ~= 0 then
		table.insert(list, Vector2.new(wx - inset.X, wy - inset.Y))
	end
	return list
end

local function applyPointerSpace(wx: number, wy: number, subInset: boolean): (number, number)
	if not subInset then
		return wx, wy
	end
	local inset = GuiService:GetGuiInset()
	return wx - inset.X, wy - inset.Y
end

-- Pick the pointer mapping closest to a known AbsolutePosition point (e.g. bubble center).
local function calibratePointer(wx: number, wy: number, nearX: number, nearY: number): (number, number, boolean)
	local inset = GuiService:GetGuiInset()
	local rawDist = (wx - nearX) * (wx - nearX) + (wy - nearY) * (wy - nearY)
	local sx, sy = wx - inset.X, wy - inset.Y
	local subDist = (sx - nearX) * (sx - nearX) + (sy - nearY) * (sy - nearY)
	if subDist < rawDist then
		return sx, sy, true
	end
	return wx, wy, false
end

local function screenSize(): Vector2
	if layer then
		local s = layer.AbsoluteSize
		if s.X > 1 and s.Y > 1 then
			return s
		end
	end
	local cam = Workspace.CurrentCamera
	local vp = if cam then cam.ViewportSize else Vector2.new(1280, 720)
	local inset = GuiService:GetGuiInset()
	-- Prefer usable GUI area; layer AbsoluteSize is authoritative once laid out.
	return Vector2.new(math.max(1, vp.X - inset.X), math.max(1, vp.Y - inset.Y))
end

local function playOrigin(): (number, number)
	if layer then
		local p = layer.AbsolutePosition
		return p.X, p.Y
	end
	return 0, 0
end

-- Global ZIndex: ImageButton art draws at btn.ZIndex; children with lower Z sit behind it.
local function setBubbleZ(btn: GuiButton, z: number)
	btn.ZIndex = z
	for _, d in ipairs(btn:GetDescendants()) do
		if not d:IsA("GuiObject") then
			continue
		end
		if d:IsA("TextLabel") then
			d.ZIndex = z + 40
			d.Visible = true
			d.Active = false
			d.TextTransparency = 0
		elseif d:IsA("TextButton") then
			d.ZIndex = z + 40
			d.Visible = true
			d.Active = false
			d.TextTransparency = 0
		else
			d.ZIndex = z + 1
		end
	end
end

local function absCenter(btn: GuiObject): (number, number, number)
	local abs = btn.AbsolutePosition
	local sz = btn.AbsoluteSize
	local cx = abs.X + sz.X * 0.5
	local cy = abs.Y + sz.Y * 0.5
	local r = math.max(sz.X, sz.Y) * 0.5
	return cx, cy, r
end

local function collectImageButtons(root: Instance, allowPowerUpCopies: boolean?): { GuiButton }
	local powerUp = root:FindFirstChild("PowerUpTemplate", true)
	local list: { GuiButton } = {}
	local seenIds: { [string]: boolean } = {}
	for _, d in ipairs(root:GetDescendants()) do
		if not d:IsA("GuiButton") then
			continue
		end
		if not SkillStages.isSkillButtonName(d.Name) then
			continue
		end
		if layer and d:IsDescendantOf(layer) then
			continue
		end
		-- Prefer outer dPad icons; ignore decorative copies under the popup template.
		if not allowPowerUpCopies and powerUp and d:IsDescendantOf(powerUp) then
			continue
		end
		local def = SkillStages.fromButtonName(d.Name)
		local id = if def then def.id else d.Name
		if seenIds[id] then
			continue
		end
		seenIds[id] = true
		table.insert(list, d)
		if #list >= MAX_BUBBLES then
			break
		end
	end
	if #list == 0 and not allowPowerUpCopies then
		return collectImageButtons(root, true)
	end
	return list
end

local function skillButtonHome(panel: Instance): Instance
	local dPad = panel:FindFirstChild("dPad") or panel:FindFirstChild("dPad", true)
	return if dPad then dPad else panel
end

-- Skill BTNs left on the bubble layer (crashed close / stop race) must move home before layer:Destroy().
local function recoverSkillButtonsFromLayer(panel: Instance, sg: ScreenGui?): number
	local layerInst: Instance? = layer
	if not layerInst and sg then
		layerInst = sg:FindFirstChild("_OceanTD_BubbleLayer")
	end
	if not layerInst then
		return 0
	end
	local home = skillButtonHome(panel)
	local n = 0
	for _, d in ipairs(layerInst:GetDescendants()) do
		if d:IsA("GuiButton") and SkillStages.isSkillButtonName(d.Name) then
			d.Parent = home
			d.Visible = true
			n += 1
		end
	end
	return n
end

local function waitForSkillButtons(panel: Instance, token: number, maxSec: number): { GuiButton }
	local deadline = os.clock() + maxSec
	while true do
		local buttons = collectImageButtons(panel)
		if #buttons > 0 then
			return buttons
		end
		if token ~= stopToken then
			return {}
		end
		if os.clock() >= deadline then
			break
		end
		RunService.Heartbeat:Wait()
	end
	return collectImageButtons(panel)
end

local function findNamedButton(root: Instance, name: string): GuiButton?
	local powerUp = root:FindFirstChild("PowerUpTemplate", true)
	local lower = string.lower(name)
	for _, d in ipairs(root:GetDescendants()) do
		if not d:IsA("GuiButton") then
			continue
		end
		if string.lower(d.Name) ~= lower then
			continue
		end
		if layer and d:IsDescendantOf(layer) then
			continue
		end
		if powerUp and d:IsDescendantOf(powerUp) then
			continue
		end
		return d
	end
	return nil
end

local function collectBubbleLabels(root: GuiButton): { TextLabel }
	local list: { TextLabel } = {}
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("TextLabel") and not string.find(d.Name, "_OceanTD_", 1, true) then
			table.insert(list, d)
		end
	end
	return list
end

local function findBubbleIcon(root: GuiButton): ImageLabel?
	local direct = root:FindFirstChild("Icon")
	if direct and direct:IsA("ImageLabel") then
		return direct
	end
	-- Case-insensitive fallback (Studio may use "icon").
	for _, d in ipairs(root:GetChildren()) do
		if d:IsA("ImageLabel") and string.lower(d.Name) == "icon" then
			return d
		end
	end
	return nil
end

local function ensureBubbleIcon(btn: GuiButton): ImageLabel
	local existing = findBubbleIcon(btn)
	if existing then
		return existing
	end
	local icon = Instance.new("ImageLabel")
	icon.Name = "Icon"
	icon.BackgroundTransparency = 1
	icon.BorderSizePixel = 0
	icon.AnchorPoint = Vector2.new(0.5, 0.5)
	icon.Position = UDim2.fromScale(0.5, 0.5)
	icon.Size = UDim2.fromScale(0.45, 0.45)
	icon.ScaleType = Enum.ScaleType.Fit
	icon.Visible = false
	icon.Active = false
	icon.ZIndex = btn.ZIndex + 2
	icon.Parent = btn
	return icon
end

-- Product of ancestor UIScales (skips pop-in bubble scale). AbsoluteSize includes this.
local function ancestorHudScale(inst: Instance): number
	local product = 1
	local cur: Instance? = inst
	while cur and not cur:IsA("LayerCollector") do
		for _, ch in ipairs(cur:GetChildren()) do
			if ch:IsA("UIScale") and ch.Name ~= "_OceanTD_BubbleScale" then
				product *= ch.Scale
			end
		end
		cur = cur.Parent
	end
	if product < 0.001 then
		return 1
	end
	return product
end

local function snapshotBubbleLayout(btn: GuiButton): BubbleLayoutSnap
	-- Do NOT force Visible=true — that flashes layout templates / skill BTNs at Studio
	-- positions for a frame (or many frames while snapping all stages).
	local hudScale = ancestorHudScale(btn)
	local abs = btn.AbsoluteSize
	local sizeOffset: Vector2
	if btn.Visible and abs.X >= 1 and abs.Y >= 1 then
		sizeOffset = Vector2.new(abs.X / hudScale, abs.Y / hudScale)
	else
		sizeOffset = Vector2.new(math.max(btn.Size.X.Offset, 64), math.max(btn.Size.Y.Offset, 64))
	end
	local labels: { LabelLayoutSnap } = {}
	for _, lbl in ipairs(collectBubbleLabels(btn)) do
		table.insert(labels, {
			position = lbl.Position,
			size = lbl.Size,
			anchor = lbl.AnchorPoint,
			textScaled = lbl.TextScaled,
			textSize = lbl.TextSize,
			textX = lbl.TextXAlignment,
			textY = lbl.TextYAlignment,
		})
	end
	local iconSnap: IconLayoutSnap? = nil
	local iconLbl = findBubbleIcon(btn)
	if iconLbl and iconLbl.Visible ~= false then
		iconSnap = {
			position = iconLbl.Position,
			size = iconLbl.Size,
			anchor = iconLbl.AnchorPoint,
			zIndex = iconLbl.ZIndex,
			imageTransparency = iconLbl.ImageTransparency,
			scaleType = iconLbl.ScaleType,
		}
	end
	return {
		sizeOffset = sizeOffset,
		sizeUdim = btn.Size,
		labels = labels,
		icon = iconSnap,
	}
end

local function scaleSnapUdim(u: UDim2, hud: number): UDim2
	local xOff = if u.X.Scale == 0 then math.floor(u.X.Offset * hud + 0.5) else u.X.Offset
	local yOff = if u.Y.Scale == 0 then math.floor(u.Y.Offset * hud + 0.5) else u.Y.Offset
	return UDim2.new(u.X.Scale, xOff, u.Y.Scale, yOff)
end

local function applyBubbleLayoutSnap(btn: GuiButton, snap: BubbleLayoutSnap, skillId: string?)
	local hud = UiPopupScale.getHud()
	local w = snap.sizeOffset.X
	local h = snap.sizeOffset.Y
	if hud > 1.01 then
		w = math.max(1, math.floor(w * hud + 0.5))
		h = math.max(1, math.floor(h * hud + 0.5))
	end
	btn.Size = UDim2.fromOffset(w, h)
	local dstLabels = collectBubbleLabels(btn)
	for i, dst in ipairs(dstLabels) do
		local src = snap.labels[i]
		if not src then
			break
		end
		if hud > 1.01 then
			dst.Position = scaleSnapUdim(src.position, hud)
			dst.Size = scaleSnapUdim(src.size, hud)
			dst.AnchorPoint = src.anchor
			dst.TextScaled = true
			dst.TextSize = math.max(8, math.floor(src.textSize * hud * HUD_BUBBLE_TEXT_BOOST + 0.5))
			dst.TextXAlignment = src.textX
			dst.TextYAlignment = src.textY
		else
			dst.Position = src.position
			dst.Size = src.size
			dst.AnchorPoint = src.anchor
			dst.TextScaled = src.textScaled
			dst.TextSize = src.textSize
			dst.TextXAlignment = src.textX
			dst.TextYAlignment = src.textY
		end
	end

	-- Larger stage templates (5–8) include Icon; smaller stages hide it.
	local iconSnap = snap.icon
	local iconImage = if skillId then SkillStages.iconImageFor(skillId) else nil
	if iconSnap and iconImage then
		local icon = ensureBubbleIcon(btn)
		if hud > 1.01 then
			icon.Position = scaleSnapUdim(iconSnap.position, hud)
			icon.Size = scaleSnapUdim(iconSnap.size, hud)
		else
			icon.Position = iconSnap.position
			icon.Size = iconSnap.size
		end
		icon.AnchorPoint = iconSnap.anchor
		icon.ZIndex = math.max(btn.ZIndex + 2, iconSnap.zIndex)
		icon.ImageTransparency = iconSnap.imageTransparency
		icon.ScaleType = iconSnap.scaleType
		icon.Image = iconImage
		icon.Visible = true
	else
		local existing = findBubbleIcon(btn)
		if existing then
			existing.Visible = false
			existing.Image = ""
		end
	end
end

readSkillStage = function(skillId: string): number
	local ok, ui = pcall(function()
		return require(script.Parent:WaitForChild("SkillPowerUpUI"))
	end)
	if ok and typeof(ui) == "table" and typeof((ui :: any).getStage) == "function" then
		return SkillStages.clampStageFor(skillId, (ui :: any).getStage(skillId))
	end
	return SkillStages.MIN_STAGE
end

local function hideLayoutOnlyButtons(root: Instance)
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("GuiButton") and SkillStages.isBubbleLayoutOnlyButtonName(d.Name) then
			d.Visible = false
		end
	end
end

local cachedLayoutHudScale: number? = nil

local function ensureLayoutSnaps(panel: Instance): { [number]: BubbleLayoutSnap }
	local hud = UiPopupScale.getHud()
	if cachedLayoutSnaps and cachedLayoutHudScale == hud then
		return cachedLayoutSnaps
	end
	local snaps: { [number]: BubbleLayoutSnap } = {}
	for stage = SkillStages.MIN_STAGE, SkillStages.MAX_STAGE do
		local layoutName = SkillStages.bubbleLayoutButtonName(stage)
		local layoutBtn = findNamedButton(panel, layoutName)
		if layoutBtn then
			snaps[stage] = snapshotBubbleLayout(layoutBtn)
		else
			warn("[SkillsBubbles] Missing stage layout BTN", layoutName, "for stage", stage)
		end
	end
	cachedLayoutSnaps = snaps
	cachedLayoutHudScale = hud
	return snaps
end

local function applyStageLayoutsToSkillButtons(panel: Instance, buttons: { GuiButton })
	local snapsByStage = ensureLayoutSnaps(panel)
	for _, btn in ipairs(buttons) do
		local def = SkillStages.fromButtonName(btn.Name)
		if not def then
			continue
		end
		local layoutStage = SkillStages.bubbleLayoutStageFor(def.id, readSkillStage(def.id))
		local snap = snapsByStage[layoutStage]
		if snap then
			applyBubbleLayoutSnap(btn, snap, def.id)
		end
	end
	hideLayoutOnlyButtons(panel)
end

local function popScaleMaxOverUnlocked(unlockedSnap: BubbleLayoutSnap?, maxSnap: BubbleLayoutSnap?): number
	if not unlockedSnap or not maxSnap then
		return 1
	end
	local uw = math.max(unlockedSnap.sizeOffset.X, 1)
	local uh = math.max(unlockedSnap.sizeOffset.Y, 1)
	local mw = maxSnap.sizeOffset.X
	local mh = maxSnap.sizeOffset.Y
	return math.max(mw / uw, mh / uh, 1)
end

local function maxPopScaleForButton(panel: Instance, btn: GuiButton): number
	local def = SkillStages.fromButtonName(btn.Name)
	if not def then
		return 1
	end
	local snaps = ensureLayoutSnaps(panel)
	local unlocked = snaps[SkillStages.bubbleLayoutStageFor(def.id, readSkillStage(def.id))]
	local maxSnap = snaps[SkillStages.bubbleLayoutStageFor(def.id, SkillStages.maxStageFor(def.id))]
	return popScaleMaxOverUnlocked(unlocked, maxSnap)
end

local function waitForGuiLayout(token: number): boolean
	-- One frame so the bubble layer has AbsoluteSize; keep skill BTNs hidden.
	RunService.Heartbeat:Wait()
	return token == stopToken
end

local function readButtonAbs(btn: GuiButton): (Vector2, Vector2)
	local absPos = btn.AbsolutePosition
	local absSize = btn.AbsoluteSize
	if absSize.X >= 1 and absSize.Y >= 1 then
		return absPos, absSize
	end
	local sz = btn.Size
	absSize = Vector2.new(math.max(sz.X.Offset, 64), math.max(sz.Y.Offset, 64))
	local parentGui = btn.Parent
	if parentGui and parentGui:IsA("GuiObject") then
		local pAbs = parentGui.AbsolutePosition
		absPos = Vector2.new(
			pAbs.X + parentGui.AbsoluteSize.X * btn.Position.X.Scale + btn.Position.X.Offset,
			pAbs.Y + parentGui.AbsoluteSize.Y * btn.Position.Y.Scale + btn.Position.Y.Offset
		)
	end
	return absPos, absSize
end

local function clampBubble(b: Bubble, ox: number, oy: number, sw: number, sh: number)
	local r = b.radius
	local minX, maxX = ox + r, ox + sw - r
	local minY, maxY = oy + r, oy + sh - r
	if minX > maxX then
		b.x = ox + sw * 0.5
	else
		if b.x < minX then
			b.x = minX
			b.vx = math.abs(b.vx) * 0.28
		elseif b.x > maxX then
			b.x = maxX
			b.vx = -math.abs(b.vx) * 0.28
		end
	end
	if minY > maxY then
		b.y = oy + sh * 0.5
	else
		if b.y < minY then
			b.y = minY
			b.vy = math.abs(b.vy) * 0.28
		elseif b.y > maxY then
			b.y = maxY
			b.vy = -math.abs(b.vy) * 0.28
		end
	end
end

local function refreshBubbleRadii(forLayout: boolean?)
	for _, b in ipairs(bubbles) do
		if not b.btn.Parent then
			continue
		end
		local sz = b.btn.Size
		local w = math.max(sz.X.Offset, 1)
		local h = math.max(sz.Y.Offset, 1)
		local pop = if forLayout then 1 elseif b.scale then math.max(b.scale.Scale, 0.01) else 1
		local r = math.max(w, h) * 0.5 * pop
		b.radius = math.max(8, r)
		b.mass = b.radius
	end
end

local function bubbleInsideView(b: Bubble, ox: number, oy: number, sw: number, sh: number, pad: number): boolean
	local r = b.radius
	return b.x - r >= ox + pad
		and b.x + r <= ox + sw - pad
		and b.y - r >= oy + pad
		and b.y + r <= oy + sh - pad
end

local function needsScreenLayout(): boolean
	if UiPopupScale.getHud() > 1.01 then
		return true
	end
	if #bubbles < 2 then
		return false
	end
	local minX, maxX = bubbles[1].x, bubbles[1].x
	local minY, maxY = bubbles[1].y, bubbles[1].y
	for i = 2, #bubbles do
		local b = bubbles[i]
		minX = math.min(minX, b.x)
		maxX = math.max(maxX, b.x)
		minY = math.min(minY, b.y)
		maxY = math.max(maxY, b.y)
	end
	if (maxX - minX) <= 48 and (maxY - minY) <= 48 then
		return true
	end
	local ox, oy = playOrigin()
	local sw, sh = screenSize().X, screenSize().Y
	for _, b in ipairs(bubbles) do
		if not bubbleInsideView(b, ox, oy, sw, sh, 4) then
			return true
		end
	end
	return false
end

-- Plot Size at screen center; other skill bubbles on a ring around it (all viewports).
local function layoutBubblesOnScreen()
	if #bubbles == 0 then
		return
	end
	local ox, oy = playOrigin()
	local sw, sh = screenSize().X, screenSize().Y
	local cx = ox + sw * 0.5
	local cy = oy + sh * 0.5

	local centerBubble: Bubble? = nil
	local ring: { Bubble } = {}
	for _, b in ipairs(bubbles) do
		if skillIdForBubble(b) == "PlotSize" then
			centerBubble = b
		else
			table.insert(ring, b)
		end
	end
	-- Fallback: if Plot Size is missing, keep previous even-ring layout.
	if not centerBubble then
		centerBubble = bubbles[1]
		table.clear(ring)
		for i = 2, #bubbles do
			table.insert(ring, bubbles[i])
		end
	end

	local centerR = centerBubble.radius
	local maxOuterR = centerR
	for _, b in ipairs(ring) do
		maxOuterR = math.max(maxOuterR, b.radius)
	end

	centerBubble.x = cx
	centerBubble.y = cy
	centerBubble.vx = 0
	centerBubble.vy = 0

	local n = #ring
	if n == 0 then
		clampBubble(centerBubble, ox, oy, sw, sh)
		return
	end

	-- Keep outer bubbles clear of the center bubble and each other, within the view.
	local gap = 18
	local minRing = centerR + maxOuterR + gap
	local minChord = maxOuterR * 2 + 14
	local chordRing = if n > 1 then (n * minChord) / (2 * math.pi) else minRing
	local margin = maxOuterR + 20
	local maxRing = math.max(minRing, math.min(sw, sh) * 0.5 - margin)
	local spread = math.clamp(math.max(minRing, chordRing), minRing, maxRing)

	for i, b in ipairs(ring) do
		-- Start at top and go clockwise so the ring reads evenly around Plot Size.
		local a = ((i - 1) / n) * math.pi * 2 - math.pi * 0.5
		b.x = cx + math.cos(a) * spread
		b.y = cy + math.sin(a) * spread
		b.vx = 0
		b.vy = 0
		clampBubble(b, ox, oy, sw, sh)
	end
	clampBubble(centerBubble, ox, oy, sw, sh)
end

local function ensureLayer(sg: ScreenGui): Frame
	local existing = sg:FindFirstChild("_OceanTD_BubbleLayer")
	local f: Frame
	if existing and existing:IsA("Frame") then
		f = existing
	else
		if existing then
			existing:Destroy()
		end
		f = Instance.new("Frame")
		f.Name = "_OceanTD_BubbleLayer"
		f.BackgroundTransparency = 1
		f.BorderSizePixel = 0
		f.Size = UDim2.fromScale(1, 1)
		f.Position = UDim2.fromScale(0, 0)
		f.ZIndex = 10 -- PowerUp host sits above (Global ZIndex)
		f.Active = false
		f.Parent = sg
	end
	local layerHud = f:FindFirstChild("_OceanTD_PopupScale")
	if layerHud then
		layerHud:Destroy()
	end
	return f
end

local function ensureScale(btn: GuiButton): UIScale
	local s = btn:FindFirstChild("_OceanTD_BubbleScale")
	if s and s:IsA("UIScale") then
		return s
	end
	local n = Instance.new("UIScale")
	n.Name = "_OceanTD_BubbleScale"
	n.Scale = 0
	n.Parent = btn
	return n
end

local function stopBgTween()
	if bgTweenConn then
		bgTweenConn:Disconnect()
		bgTweenConn = nil
	end
end

local function normalizeBgName(name: string): string
	return (string.gsub(string.lower(name), "[%s_%-]", ""))
end

local function buildBgFade(gui: GuiObject?, gradient: UIGradient?): BgFade?
	if not gui and not gradient then
		return nil
	end
	local imgTrans: number? = nil
	if gui and (gui:IsA("ImageLabel") or gui:IsA("ImageButton")) then
		imgTrans = (gui :: ImageLabel).ImageTransparency
	end
	return {
		gui = gui,
		gradient = gradient,
		bgTrans = if gui then gui.BackgroundTransparency else 1,
		imgTrans = imgTrans,
		gradTrans = if gradient then gradient.Transparency else nil,
	}
end

local function findBackgroundFades(panel: Instance): { BgFade }
	local out: { BgFade } = {}
	local seenGui: { [GuiObject]: boolean } = {}

	local function tryAdd(gui: GuiObject?, gradient: UIGradient?)
		local fade = buildBgFade(gui, gradient)
		if fade and fade.gui and not seenGui[fade.gui] then
			seenGui[fade.gui] = true
			table.insert(out, fade)
		end
	end

	for _, d in ipairs(panel:GetDescendants()) do
		local nn = normalizeBgName(d.Name)
		if nn == "backgroundgradient" then
			if d:IsA("UIGradient") then
				local parent = d.Parent
				tryAdd(if parent and parent:IsA("GuiObject") then parent else nil, d)
			elseif d:IsA("GuiObject") then
				tryAdd(d, d:FindFirstChildWhichIsA("UIGradient", true))
			end
		elseif nn == "background" and d:IsA("GuiObject") then
			local g = d:FindFirstChildWhichIsA("UIGradient", true)
			if g then
				tryAdd(d, g)
			end
		end
	end

	if #out == 0 then
		for _, d in ipairs(panel:GetDescendants()) do
			if d:IsA("UIGradient") then
				local parent = d.Parent
				if parent and parent:IsA("GuiObject") then
					local g = parent :: GuiObject
					if g.Size.X.Scale >= 0.85 and g.Size.Y.Scale >= 0.85 then
						tryAdd(g, d)
					end
				end
			end
		end
	end
	return out
end

local function findBackgroundGradient(panel: Instance): BgFade?
	local fades = findBackgroundFades(panel)
	bgFades = fades
	bgFade = fades[1]
	return bgFade
end

local function resolveBgFades(): { BgFade }
	if #bgFades > 0 then
		for _, fade in ipairs(bgFades) do
			if fade.gui and fade.gui.Parent then
				return bgFades
			end
		end
	end
	if hostPanel then
		findBackgroundGradient(hostPanel)
	end
	return bgFades
end

local function setBgFadesVisible(visible: boolean)
	for _, fade in ipairs(bgFades) do
		if fade.gui and fade.gui.Parent then
			fade.gui.Visible = visible
		end
	end
end

local function applyBgFade(fade: BgFade, alpha: number)
	-- alpha 0 = fully hidden, 1 = studio look
	local a = math.clamp(alpha, 0, 1)
	local inv = 1 - a
	if fade.gui then
		if a <= 0.001 then
			fade.gui.BackgroundTransparency = 1
			if fade.imgTrans ~= nil and (fade.gui:IsA("ImageLabel") or fade.gui:IsA("ImageButton")) then
				(fade.gui :: ImageLabel).ImageTransparency = 1
			end
		else
			fade.gui.BackgroundTransparency = fade.bgTrans + (1 - fade.bgTrans) * inv
			if fade.imgTrans ~= nil and (fade.gui:IsA("ImageLabel") or fade.gui:IsA("ImageButton")) then
				(fade.gui :: ImageLabel).ImageTransparency = fade.imgTrans + (1 - fade.imgTrans) * inv
			end
		end
	end
	if fade.gradient then
		-- Uniform veil over Studio sequence while fading; restore exact sequence at full.
		if a >= 0.999 and fade.gradTrans then
			fade.gradient.Transparency = fade.gradTrans
		elseif a <= 0.001 then
			fade.gradient.Transparency = NumberSequence.new(1)
		else
			local base = 0
			if fade.gradTrans then
				local k = fade.gradTrans.Keypoints
				if #k > 0 then
					base = k[1].Value
				end
			end
			fade.gradient.Transparency = NumberSequence.new(base + (1 - base) * inv)
		end
	end
end

local function applyBgFadeAll(alpha: number)
	bgFadeAlpha = math.clamp(alpha, 0, 1)
	for _, fade in ipairs(bgFades) do
		applyBgFade(fade, bgFadeAlpha)
	end
end

local function tweenBgFadeAll(
	fromAlpha: number,
	toAlpha: number,
	info: TweenInfo,
	token: number,
	onComplete: (() -> ())?
)
	local fades = resolveBgFades()
	if #fades == 0 then
		if onComplete then
			onComplete()
		end
		return
	end
	stopBgTween()
	applyBgFadeAll(fromAlpha)
	local proxy = Instance.new("NumberValue")
	proxy.Value = fromAlpha
	local tw = TweenService:Create(proxy, info, { Value = toAlpha })
	bgTweenConn = proxy:GetPropertyChangedSignal("Value"):Connect(function()
		if token ~= stopToken then
			return
		end
		applyBgFadeAll(proxy.Value)
	end)
	tw.Completed:Once(function()
		if token == stopToken then
			applyBgFadeAll(toAlpha)
			if toAlpha <= 0.001 then
				setBgFadesVisible(false)
			end
		end
		stopBgTween()
		proxy:Destroy()
		if token == stopToken and onComplete then
			onComplete()
		end
	end)
	tw:Play()
end

local function tweenBgFade(fade: BgFade, fromAlpha: number, toAlpha: number, info: TweenInfo, token: number)
	if fade.gui and not table.find(bgFades, fade) then
		table.insert(bgFades, fade)
		bgFade = bgFades[1]
	end
	tweenBgFadeAll(fromAlpha, toAlpha, info, token, nil)
end

local function clearBgFadeKeepHidden(): { BgFade }
	stopBgTween()
	local saved = table.clone(bgFades)
	bgFade = nil
	table.clear(bgFades)
	return saved
end

local function restoreBgFadeStudio(fades: { BgFade })
	for _, fade in ipairs(fades) do
		if fade.gui then
			fade.gui.Visible = true
		end
		applyBgFade(fade, 1)
	end
	bgFadeAlpha = 1
end

-- Pre-hide icons + background before the panel is shown (avoids one-frame flash).
-- Use Visible (not UIScale) so AbsoluteSize stays valid for spawn.
function SkillsBubbleSim.preHide(panel: Instance)
	for _, d in ipairs(panel:GetDescendants()) do
		if d:IsA("GuiButton") and SkillStages.isSkillButtonName(d.Name) then
			d.Visible = false
		elseif d:IsA("GuiButton") and SkillStages.isBubbleLayoutOnlyButtonName(d.Name) then
			d.Visible = false
		end
	end
	findBackgroundGradient(panel)
	if #bgFades > 0 then
		applyBgFadeAll(0)
	end
end

local function writeBubble(b: Bubble)
	local parent = b.btn.Parent
	if not parent or not parent:IsA("GuiObject") then
		return
	end
	local bobX = 0
	local bobY = 0
	if not dragged[b] then
		bobX = math.sin(bobTime * BOB_FREQ * math.pi * 2 + b.phase) * BOB_AMP
		bobY = math.cos(bobTime * BOB_FREQ * 0.91 * math.pi * 2 + b.phase * 1.17) * BOB_AMP
	end
	local cx = b.x + bobX
	local cy = b.y + bobY
	local pAbs = parent.AbsolutePosition
	b.btn.AnchorPoint = Vector2.new(0.5, 0.5)
	b.btn.Position = UDim2.fromOffset(cx - pAbs.X, cy - pAbs.Y)
end

local function softSeparate(a: Bubble, b: Bubble)
	local aHeld = dragged[a] == true
	local bHeld = dragged[b] == true
	if aHeld and bHeld then
		return
	end
	local dx = b.x - a.x
	local dy = b.y - a.y
	local distSq = dx * dx + dy * dy
	local minDist = a.radius + b.radius
	if distSq >= minDist * minDist or distSq < 1e-6 then
		return
	end
	local dist = math.sqrt(distSq)
	local overlap = minDist - dist
	local nx = dx / dist
	local ny = dy / dist
	local strength = SEPARATION * overlap * (0.32 + overlap * 0.015)
	-- Held bubble is kinematic: only the free one moves (avoids grab snap from neighbors).
	if aHeld then
		b.x += nx * strength
		b.y += ny * strength
		return
	end
	if bHeld then
		a.x -= nx * strength
		a.y -= ny * strength
		return
	end
	local invA = 1 / a.mass
	local invB = 1 / b.mass
	local sum = invA + invB
	local pushA = strength * (invA / sum)
	local pushB = strength * (invB / sum)
	a.x -= nx * pushA
	a.y -= ny * pushA
	b.x += nx * pushB
	b.y += ny * pushB
	local vn = (b.vx - a.vx) * nx + (b.vy - a.vy) * ny
	if vn < 0 then
		local damp = vn * 0.1
		a.vx += nx * damp * (invA / sum)
		a.vy += ny * damp * (invA / sum)
		b.vx -= nx * damp * (invB / sum)
		b.vy -= ny * damp * (invB / sum)
	end
end

local function clampSpeed(b: Bubble)
	local sp = math.sqrt(b.vx * b.vx + b.vy * b.vy)
	if sp > MAX_SPEED then
		local s = MAX_SPEED / sp
		b.vx *= s
		b.vy *= s
	end
end

local function physStep(dt: number)
	local sw = screenSize()
	local ox, oy = playOrigin()
	local w, h = sw.X, sw.Y
	bobTime += dt

	for _, b in ipairs(bubbles) do
		if dragged[b] then
			continue
		end
		b.vx *= DAMPING
		b.vy *= DAMPING
		clampSpeed(b)
		b.x += b.vx * dt
		b.y += b.vy * dt
	end

	local n = #bubbles
	for i = 1, n - 1 do
		local a = bubbles[i]
		for j = i + 1, n do
			softSeparate(a, bubbles[j])
		end
	end

	for _, b in ipairs(bubbles) do
		if not dragged[b] then
			clampBubble(b, ox, oy, w, h)
		end
		writeBubble(b)
	end
end

local function findBubbleAtAbs(absX: number, absY: number): Bubble?
	for i = #bubbles, 1, -1 do
		local b = bubbles[i]
		local cx, cy, r = absCenter(b.btn)
		local dx = absX - cx
		local dy = absY - cy
		if dx * dx + dy * dy <= r * r then
			return b
		end
	end
	return nil
end

local function finishDrag(input: InputObject)
	local d = drags[input]
	if not d then
		return
	end
	drags[input] = nil
	dragged[d.bubble] = nil
	d.bubble.vx *= RELEASE_VEL_SCALE
	d.bubble.vy *= RELEASE_VEL_SCALE
	clampSpeed(d.bubble)
	-- Drag steals GuiButton Activated on many clients — treat a tap as skill open.
	if not d.moved and not closing and not suppressed and onBubbleActivated then
		onBubbleActivated(d.bubble.btn.Name)
	end
end

local function beginDrag(b: Bubble, input: InputObject, wx: number, wy: number)
	if suppressed or dragged[b] or closing then
		return
	end
	-- Sync to true drawn center (AbsolutePosition) — no bob jump.
	local cx, cy = absCenter(b.btn)
	b.x = cx
	b.y = cy
	-- Calibrate pointer space against this center so grab never snaps above/below cursor.
	local ax, ay, subInset = calibratePointer(wx, wy, cx, cy)
	drags[input] = {
		bubble = b,
		input = input,
		grabX = ax - cx,
		grabY = ay - cy,
		subInset = subInset,
		startX = ax,
		startY = ay,
		moved = false,
	}
	dragged[b] = true
	b.vx = 0
	b.vy = 0
	setBubbleZ(b.btn, 80)
	writeBubble(b)
end

local function updateDrag(input: InputObject, wx: number, wy: number)
	local d = drags[input]
	if not d then
		return
	end
	local b = d.bubble
	local ax, ay = applyPointerSpace(wx, wy, d.subInset)
	local movedDist = math.sqrt((ax - d.startX) * (ax - d.startX) + (ay - d.startY) * (ay - d.startY))
	if movedDist > 14 then
		d.moved = true
	end
	local targetX = ax - d.grabX
	local targetY = ay - d.grabY
	local nx = b.x + (targetX - b.x) * DRAG_SMOOTH
	local ny = b.y + (targetY - b.y) * DRAG_SMOOTH
	b.vx = (nx - b.x) / PHYS_DT
	b.vy = (ny - b.y) / PHYS_DT
	b.x = nx
	b.y = ny
	local sw = screenSize()
	local ox, oy = playOrigin()
	local r = b.radius
	b.x = math.clamp(b.x, ox + r, ox + sw.X - r)
	b.y = math.clamp(b.y, oy + r, oy + sw.Y - r)
	writeBubble(b)
end

local function findBubbleAtWindow(wx: number, wy: number): Bubble?
	for _, cand in ipairs(pointerCandidates(wx, wy)) do
		local hit = findBubbleAtAbs(cand.X, cand.Y)
		if hit then
			return hit
		end
	end
	return nil
end

local function clearSimState()
	table.clear(drags)
	table.clear(dragged)
	mouseDragInput = nil
	physAcc = 0
	bobTime = 0
	gamepadFocus = 0
	clearGamepadFocusVisual()
end

local function disconnectInputs()
	for _, c in ipairs(inputConns) do
		c:Disconnect()
	end
	table.clear(inputConns)
end

local function restoreBubbles()
	for _, b in ipairs(bubbles) do
		local btn = b.btn
		local sc = btn:FindFirstChild("_OceanTD_BubbleScale")
		if sc then
			sc:Destroy()
		end
		local lock = btn:FindFirstChild("OceanTD_SkillGateLock")
		if lock then
			lock:Destroy()
		end
		if btn.Parent then
			btn.Visible = true
			btn.Parent = b.origParent
			btn.Position = b.origPos
			btn.Size = b.origSize
			btn.AnchorPoint = b.origAnchor
			setBubbleZ(btn, b.origZ)
		end
	end
	clearOrbitLocks()
	table.clear(bubbles)
end

local function playUnlockSettle(token: number)
	for _, b in ipairs(bubbles) do
		if token ~= stopToken or not running or closing or not b.btn.Parent then
			return
		end
		if b.maxPopScale <= 1.001 then
			continue
		end
		local tw = TweenService:Create(b.scale, UNLOCK_SETTLE_INFO, { Scale = b.settledScale })
		tw:Play()
	end
end

local function playPopInOneBubble(b: Bubble, delay: number, token: number, onDone: () -> ())
	b.scale.Scale = 0
	local peak = math.max(b.maxPopScale, b.settledScale)
	local overshoot = POP_OVERSHOOT * peak
	task.delay(delay, function()
		if token ~= stopToken or not running or closing or not b.btn.Parent then
			onDone()
			return
		end
		local tw = TweenService:Create(b.scale, POP_IN_INFO, { Scale = overshoot })
		tw:Play()
		tw.Completed:Once(function()
			if token ~= stopToken or not running or closing or not b.btn.Parent then
				onDone()
				return
			end
			local settleTw = TweenService:Create(b.scale, POP_SETTLE_INFO, { Scale = peak })
			settleTw:Play()
			settleTw.Completed:Once(onDone)
		end)
	end)
end

local function playPopIn()
	local token = stopToken
	if #bgFades > 0 then
		setBgFadesVisible(true)
		tweenBgFadeAll(0, 1, BG_FADE_IN_INFO, token, nil)
	end
	local rng = Random.new()
	local popInTotal = #bubbles
	local popInDone = 0
	local settleStarted = false
	local function tryStartUnlockSettle()
		if settleStarted or popInDone < popInTotal then
			return
		end
		settleStarted = true
		playUnlockSettle(token)
	end
	local function onPopInBubbleDone()
		popInDone += 1
		tryStartUnlockSettle()
	end
	if popInTotal == 0 then
		return
	end

	local plotSizeBubble: Bubble? = nil
	local others: { Bubble } = {}
	for _, b in ipairs(bubbles) do
		if skillIdForBubble(b) == "PlotSize" then
			plotSizeBubble = b
		else
			table.insert(others, b)
		end
	end

	-- Plot Size always leads; remaining bubbles enter on random delays.
	if plotSizeBubble then
		playPopInOneBubble(plotSizeBubble, 0, token, onPopInBubbleDone)
	else
		-- Fallback if Plot Size is missing from the layer.
		playPopInOneBubble(bubbles[1], 0, token, onPopInBubbleDone)
		for i = 2, #bubbles do
			local delay = rng:NextNumber(OTHER_POP_IN_DELAY_MIN, OTHER_POP_IN_DELAY_MAX)
			playPopInOneBubble(bubbles[i], delay, token, onPopInBubbleDone)
		end
		tryStartUnlockSettle()
		return
	end

	for _, b in ipairs(others) do
		local delay = rng:NextNumber(OTHER_POP_IN_DELAY_MIN, OTHER_POP_IN_DELAY_MAX)
		playPopInOneBubble(b, delay, token, onPopInBubbleDone)
	end
	tryStartUnlockSettle()
end

local function playPopOut(done: () -> ())
	closing = true
	local token = stopToken
	if #bgFades > 0 then
		tweenBgFadeAll(1, 0, BG_FADE_OUT_INFO, token, nil)
	end
	local left = #bubbles
	if left == 0 then
		done()
		return
	end
	local reported = false
	local finished = 0
	local function oneDone()
		finished += 1
		if finished >= left and not reported then
			reported = true
			done()
		end
	end
	local rng = Random.new()
	for i, b in ipairs(bubbles) do
		-- First bubble scales out immediately (no 1s+ dead wait).
		local delay = if i == 1 then 0 else rng:NextNumber(0, POP_OUT_WINDOW)
		task.delay(delay, function()
			if token ~= stopToken then
				oneDone()
				return
			end
			if not b.btn.Parent then
				oneDone()
				return
			end
			local tw = TweenService:Create(b.scale, POP_OUT_INFO, { Scale = 0 })
			tw:Play()
			tw.Completed:Once(oneDone)
		end)
	end
	task.delay(POP_OUT_WINDOW + POP_OUT_SEC + 0.2, function()
		if token == stopToken and not reported then
			reported = true
			done()
		end
	end)
end

function SkillsBubbleSim.stop(onDone: (() -> ())?)
	stopToken += 1
	rejectFxToken += 1
	suppressed = false
	local my = stopToken
	local function finish()
		if my ~= stopToken then
			return
		end
		running = false
		closing = false
		if conn then
			conn:Disconnect()
			conn = nil
		end
		disconnectInputs()
		clearSimState()
		restoreBubbles()
		local faded = clearBgFadeKeepHidden()
		if layer then
			layer:Destroy()
			layer = nil
		end
		hostGui = nil
		hostPanel = nil
		if onDone then
			onDone()
		end
		-- Restore Studio transparencies after the panel is hidden (no end-of-close flash).
		restoreBgFadeStudio(faded)
	end

	if not running and #bubbles == 0 then
		finish()
		return
	end

	running = false
	if conn then
		conn:Disconnect()
		conn = nil
	end
	disconnectInputs()
	clearSimState()
	playPopOut(finish)
end

function SkillsBubbleSim.start(panel: Instance)
	stopToken += 1
	suppressed = false
	running = false
	closing = false
	if conn then
		conn:Disconnect()
		conn = nil
	end
	disconnectInputs()
	clearSimState()
	restoreBubbles()
	-- restoreBubbles forces Visible=true; hide again before any layout wait (prevents flash).
	SkillsBubbleSim.preHide(panel)
	-- Keep bgFade from preHide (already at alpha 0); re-resolve if missing.
	if #bgFades == 0 then
		findBackgroundGradient(panel)
		if #bgFades > 0 then
			applyBgFadeAll(0)
		end
	end
	local sg: ScreenGui? = if panel:IsA("ScreenGui") then panel else panel:FindFirstAncestorOfClass("ScreenGui")
	if not sg then
		warn("[SkillsBubbles] No ScreenGui for bubble layer")
		return
	end
	-- Recover skill BTNs stuck on the bubble layer before Destroy (stop race / ForceClose).
	local recovered = recoverSkillButtonsFromLayer(panel, sg)
	if layer then
		layer:Destroy()
		layer = nil
	end
	local staleLayer = sg:FindFirstChild("_OceanTD_BubbleLayer")
	if staleLayer and staleLayer:IsA("Frame") then
		staleLayer:Destroy()
	end

	hostGui = sg
	hostPanel = panel
	-- Do NOT toggle IgnoreGuiInset — keeps AbsolutePosition consistent with other UI
	-- and avoids fighting PlacementController / HUD inset assumptions.
	sg.DisplayOrder = math.max(sg.DisplayOrder, 50)

	local bubbleLayer = ensureLayer(sg)
	layer = bubbleLayer

	local myStart = stopToken
	local buttons = waitForSkillButtons(panel, myStart, 2)
	if #buttons == 0 then
		local hasDPad = panel:FindFirstChild("dPad", true) ~= nil
		warn(
			"[SkillsBubbles] No skill ImageButtons under MobileSkillsA",
			"(dPad=",
			hasDPad,
			"recovered=",
			recovered,
			") — add PlotSizeBTN / EarnMoreBTN / … under dPad"
		)
		return
	end

	-- Stage → Studio template size/label placement (skill text stays on the skill BTN).
	-- Stay Visible=false until reparented at scale 0 (avoids half-second flash at Studio positions).
	applyStageLayoutsToSkillButtons(panel, buttons)
	for _, btn in ipairs(buttons) do
		btn.Visible = false
		ensureScale(btn).Scale = 0
	end

	-- Layer AbsoluteSize only — keep skill buttons hidden during this wait.
	if not waitForGuiLayout(myStart) then
		return
	end

	local ox, oy = playOrigin()
	local sw, sh = screenSize().X, screenSize().Y
	local seedX = ox + sw * 0.5
	local seedY = oy + sh * 0.5

	for i, btn in ipairs(buttons) do
		local parent = btn.Parent
		if not parent then
			continue
		end
		-- Prefer Size offsets from stage layout (AbsoluteSize is 0 while Visible=false / Scale=0).
		local sz = btn.Size
		local w = math.max(sz.X.Offset, 1)
		local h = math.max(sz.Y.Offset, 1)
		if w < 2 and h < 2 then
			local _, absSize = readButtonAbs(btn)
			w = math.max(absSize.X, 64)
			h = math.max(absSize.Y, 64)
		end
		local r = math.max(w, h) * 0.5
		local scale = ensureScale(btn)
		scale.Scale = 0
		local maxPopScale = maxPopScaleForButton(panel, btn)
		local b: Bubble = {
			btn = btn,
			scale = scale,
			radius = math.max(8, r),
			mass = math.max(8, r),
			x = seedX,
			y = seedY,
			vx = 0,
			vy = 0,
			phase = (i * 1.6180339887) % (math.pi * 2),
			origParent = parent,
			origPos = btn.Position,
			origSize = btn.Size,
			origAnchor = btn.AnchorPoint,
			origZ = btn.ZIndex,
			settledScale = 1,
			maxPopScale = maxPopScale,
		}
		-- Keep stage-layout Size (unscaled). Layer UIScale matches former parent HUD scale.
		-- Do not bake AbsoluteSize into Size — that double-scales circles vs TextSize.
		-- Drop per-button HUD UIScale so only the layer scale applies (avoids double scale).
		local btnHudScale = btn:FindFirstChild("_OceanTD_PopupScale")
		if btnHudScale then
			btnHudScale:Destroy()
		end
		btn.Parent = bubbleLayer
		btn.Visible = false -- still hidden until centered + scale 0
		btn.AutoButtonColor = false
		btn.Active = true
		btn.Selectable = false -- custom gamepad focus; GuiService highlight steals the stick
		setBubbleZ(btn, 20 + i)
		-- Gamepad A press proxy (clients without GuiButton:Activate).
		local press = btn:FindFirstChild("_OceanTD_SkillPress")
		if not (press and press:IsA("BindableEvent")) then
			if press then
				press:Destroy()
			end
			local be = Instance.new("BindableEvent")
			be.Name = "_OceanTD_SkillPress"
			be.Parent = btn
			press = be
		end
		local skillName = btn.Name
		-- Prefer tap-on-release (finishDrag) — Activated often doesn't fire after drag capture.
		-- Keep BindableEvent for gamepad A (clients without GuiButton:Activate).
		local pressEv = press :: BindableEvent
		if pressEv:GetAttribute("_OceanTD_SkillPressBound") ~= true then
			pressEv:SetAttribute("_OceanTD_SkillPressBound", true)
			pressEv.Event:Connect(function()
				if onBubbleActivated then
					onBubbleActivated(skillName)
				end
			end)
		end
		table.insert(bubbles, b)
		writeBubble(b)
	end

	if #bubbles == 0 then
		warn("[SkillsBubbles] No laid-out ImageButtons (zero AbsoluteSize)")
		return
	end
	refreshBubbleRadii(true)
	-- Always center Plot Size with others around it (all viewport widths).
	layoutBubblesOnScreen()
	for _, b in ipairs(bubbles) do
		b.scale.Scale = 0
		writeBubble(b)
		-- Reveal only after correct position + scale 0 (pop-in grows from here).
		b.btn.Visible = true
	end

	table.insert(
		inputConns,
		UserInputService.InputBegan:Connect(function(input, _gameProcessed)
			-- Do not gate on gameProcessed: bubbles are GuiButtons, so clicks are
			-- always "processed" and that blocked open. Suppression covers power-up.
			if not running or closing or suppressed then
				return
			end
			local isTouch = input.UserInputType == Enum.UserInputType.Touch
			local isMouse = input.UserInputType == Enum.UserInputType.MouseButton1
			if not isTouch and not isMouse then
				return
			end
			local wx: number
			local wy: number
			if isMouse then
				local m = UserInputService:GetMouseLocation()
				wx, wy = m.X, m.Y
			else
				wx, wy = input.Position.X, input.Position.Y
			end
			local b = findBubbleAtWindow(wx, wy)
			if not b then
				return
			end
			beginDrag(b, input, wx, wy)
			if isMouse then
				mouseDragInput = input
			end
		end)
	)
	table.insert(
		inputConns,
		UserInputService.InputChanged:Connect(function(input, _gp)
			if not running or closing or suppressed then
				return
			end
			if input.UserInputType == Enum.UserInputType.Touch then
				if drags[input] then
					updateDrag(input, input.Position.X, input.Position.Y)
				end
			elseif input.UserInputType == Enum.UserInputType.MouseMovement and mouseDragInput then
				local m = UserInputService:GetMouseLocation()
				updateDrag(mouseDragInput, m.X, m.Y)
			end
		end)
	)
	table.insert(
		inputConns,
		UserInputService.InputEnded:Connect(function(input, _gp)
			if input.UserInputType == Enum.UserInputType.MouseButton1 then
				if mouseDragInput and drags[mouseDragInput] then
					finishDrag(mouseDragInput)
				end
				mouseDragInput = nil
			elseif drags[input] then
				finishDrag(input)
			end
		end)
	)

	running = true
	closing = false
	physAcc = 0
	bobTime = 0
	conn = RunService.Heartbeat:Connect(function(dt)
		if not running then
			return
		end
		physAcc += dt
		if physAcc > 0.1 then
			physAcc = PHYS_DT
		end
		while physAcc >= PHYS_DT do
			physAcc -= PHYS_DT
			physStep(PHYS_DT)
		end
		updateOrbitLocks(dt)
	end)

	syncOrbitLocks()
	playPopIn()
	print("[SkillsBubbles] Started", #bubbles, "bubbles")
end

function SkillsBubbleSim.isRunning(): boolean
	return running
end

function SkillsBubbleSim.setSuppressed(value: boolean, opts: { deferBackgroundHide: boolean? }?)
	suppressed = value == true
	if suppressed then
		-- Cancel in-flight drags without firing bubble activate (was stealing Close/UNLOCK clicks).
		for input, d in pairs(drags) do
			dragged[d.bubble] = nil
			drags[input] = nil
		end
		mouseDragInput = nil
		SkillsBubbleSim.clearGamepadFocus()
		for _, b in ipairs(bubbles) do
			if b.btn.Parent then
				b.btn.Active = false
			end
		end
	else
		for _, b in ipairs(bubbles) do
			if b.btn.Parent then
				b.btn.Active = true
			end
		end
	end
	if layer and layer.Parent then
		layer.Visible = not suppressed
	end
	if not (opts and opts.deferBackgroundHide) then
		if suppressed then
			stopBgTween()
			setBgFadesVisible(false)
		else
			setBgFadesVisible(true)
		end
	end
end

function SkillsBubbleSim.fadeBackgroundOut(): boolean
	local fades = resolveBgFades()
	if #fades == 0 then
		return false
	end
	setBgFadesVisible(true)
	local fromAlpha = if bgFadeAlpha > 0.05 then bgFadeAlpha else 1
	tweenBgFadeAll(fromAlpha, 0, BG_FADE_OUT_INFO, stopToken, function()
		applyBgFadeAll(0)
		setBgFadesVisible(false)
	end)
	return true
end

function SkillsBubbleSim.fadeBackgroundIn()
	local fades = resolveBgFades()
	if #fades == 0 then
		return
	end
	setBgFadesVisible(true)
	applyBgFadeAll(0)
	tweenBgFadeAll(0, 1, BG_FADE_IN_INFO, stopToken, nil)
end

function SkillsBubbleSim.isSuppressed(): boolean
	return suppressed
end

-- Re-apply stage template size/label layout while bubbles are live (after unlock).
function SkillsBubbleSim.refreshStageLayouts()
	if not running or #bubbles == 0 then
		return
	end
	local panel = hostPanel
	if not panel or not panel.Parent then
		return
	end
	local buttons: { GuiButton } = {}
	for _, b in ipairs(bubbles) do
		if b.btn.Parent then
			table.insert(buttons, b.btn)
		end
	end
	if #buttons == 0 then
		return
	end
	-- Snapshot templates from Studio tree (layout-only + skill BTNs still under panel parents
	-- may be gone — templates stay under MobileSkillsA; skill bubbles are on the layer).
	applyStageLayoutsToSkillButtons(panel, buttons)
	for _, b in ipairs(bubbles) do
		local sz = b.btn.Size
		local r = math.max(8, math.max(sz.X.Offset, sz.Y.Offset) * 0.5)
		b.radius = r
		b.mass = r
		writeBubble(b)
	end
	syncOrbitLocks()
end

local function applyGamepadFocusVisual()
	clearGamepadFocusVisual()
	if gamepadFocus < 1 or gamepadFocus > #bubbles then
		return
	end
	local b = bubbles[gamepadFocus]
	if not b.btn.Parent then
		return
	end
	local stroke = Instance.new("UIStroke")
	stroke.Name = "_OceanTD_GamepadFocus"
	stroke.Thickness = 4
	stroke.Color = Color3.fromRGB(255, 255, 255)
	stroke.Transparency = 0.05
	stroke.Parent = b.btn
	focusStroke = stroke
	setBubbleZ(b.btn, 90)
end

function SkillsBubbleSim.clearGamepadFocus()
	gamepadFocus = 0
	clearGamepadFocusVisual()
end

function SkillsBubbleSim.setGamepadFocus(index: number)
	if not running or closing or #bubbles == 0 then
		SkillsBubbleSim.clearGamepadFocus()
		return
	end
	local i = math.clamp(math.floor(index), 1, #bubbles)
	gamepadFocus = i
	applyGamepadFocusVisual()
end

function SkillsBubbleSim.getGamepadFocus(): number
	return gamepadFocus
end

function SkillsBubbleSim.getBubbleCount(): number
	return #bubbles
end

-- Move highlight toward stick/dir in screen space (nearest bubble in that direction).
function SkillsBubbleSim.moveGamepadFocus(dirX: number, dirY: number)
	if not running or closing or #bubbles == 0 then
		return
	end
	local mag = math.sqrt(dirX * dirX + dirY * dirY)
	if mag < 0.2 then
		return
	end
	local nx, ny = dirX / mag, dirY / mag
	if gamepadFocus < 1 or gamepadFocus > #bubbles then
		SkillsBubbleSim.setGamepadFocus(1)
		return
	end
	local cur = bubbles[gamepadFocus]
	local cx, cy = absCenter(cur.btn)
	local bestI = gamepadFocus
	local bestScore = math.huge
	for i, b in ipairs(bubbles) do
		if i == gamepadFocus then
			continue
		end
		local bx, by = absCenter(b.btn)
		local dx, dy = bx - cx, by - cy
		local dist = math.sqrt(dx * dx + dy * dy)
		if dist < 8 then
			continue
		end
		local ux, uy = dx / dist, dy / dist
		local dot = ux * nx + uy * ny
		if dot < 0.2 then
			continue
		end
		local score = dist / math.max(dot, 0.15)
		if score < bestScore then
			bestScore = score
			bestI = i
		end
	end
	if bestI ~= gamepadFocus then
		SkillsBubbleSim.setGamepadFocus(bestI)
	end
end

function SkillsBubbleSim.setOnBubbleActivated(cb: ((buttonName: string) -> ())?)
	onBubbleActivated = cb
end

-- Locked skill tap: flash that bubble's labels red; unlocked bubbles grow then shrink over 2s.
local REJECT_FX_SEC = 2
local REJECT_RED = Color3.fromRGB(255, 45, 50)
local REJECT_GROW_SCALE = 2 -- 2× current size (skipped if skill is already max stage)
local REJECT_HALF_SEC = REJECT_FX_SEC * 0.5
local REJECT_UP_INFO = TweenInfo.new(REJECT_HALF_SEC, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local REJECT_DOWN_INFO = TweenInfo.new(REJECT_HALF_SEC, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

function SkillsBubbleSim.playLockedRejectFx(skillId: string)
	if not running or closing or suppressed or #bubbles == 0 then
		return
	end
	rejectFxToken += 1
	local token = rejectFxToken
	local stages = unlockedStagesMap()

	local locked: Bubble? = nil
	local growTargets: { Bubble } = {}
	for _, b in ipairs(bubbles) do
		if not b.btn.Parent then
			continue
		end
		local id = skillIdForBubble(b)
		if not id then
			continue
		end
		if id == skillId then
			locked = b
		elseif not SkillStages.isSkillLocked(id, stages) then
			-- Already at max stage layout — don't enlarge the circle further.
			if readUnlockedStage(id) < SkillStages.maxStageFor(id) then
				table.insert(growTargets, b)
			end
		end
	end

	type SavedColor = { lbl: TextLabel, color: Color3 }
	local saved: { SavedColor } = {}
	if locked then
		for _, lbl in ipairs(collectBubbleLabels(locked.btn)) do
			table.insert(saved, { lbl = lbl, color = lbl.TextColor3 })
		end
	end

	for _, b in ipairs(growTargets) do
		if b.scale.Parent then
			b.scale.Scale = b.settledScale
			local scaleObj = b.scale
			local up = TweenService:Create(scaleObj, REJECT_UP_INFO, { Scale = REJECT_GROW_SCALE * b.settledScale })
			up:Play()
			up.Completed:Connect(function()
				if token ~= rejectFxToken or not scaleObj.Parent then
					return
				end
				TweenService:Create(scaleObj, REJECT_DOWN_INFO, { Scale = b.settledScale }):Play()
			end)
		end
	end

	local t0 = os.clock()
	task.spawn(function()
		while token == rejectFxToken and (os.clock() - t0) < REJECT_FX_SEC do
			if not running or closing or suppressed then
				break
			end
			local elapsed = os.clock() - t0
			-- ~2.5 flashes/sec between original and bright red.
			local flash = (math.sin(elapsed * math.pi * 5) + 1) * 0.5
			for _, s in ipairs(saved) do
				if s.lbl.Parent then
					s.lbl.TextColor3 = s.color:Lerp(REJECT_RED, 0.25 + flash * 0.75)
				end
			end
			task.wait()
		end
		if token ~= rejectFxToken then
			return
		end
		for _, s in ipairs(saved) do
			if s.lbl.Parent then
				s.lbl.TextColor3 = s.color
			end
		end
		for _, b in ipairs(growTargets) do
			if b.scale.Parent then
				b.scale.Scale = b.settledScale
			end
		end
	end)
end

function SkillsBubbleSim.activateGamepadFocus(): boolean
	if not running or closing or suppressed then
		return false
	end
	if gamepadFocus < 1 or gamepadFocus > #bubbles then
		return false
	end
	local btn = bubbles[gamepadFocus].btn
	if not btn.Parent then
		return false
	end
	local name = btn.Name
	if onBubbleActivated then
		onBubbleActivated(name)
		return true
	end
	local proxy = btn:FindFirstChild("_OceanTD_SkillPress")
	if proxy and proxy:IsA("BindableEvent") then
		(proxy :: BindableEvent):Fire()
		return true
	end
	return false
end

return SkillsBubbleSim
