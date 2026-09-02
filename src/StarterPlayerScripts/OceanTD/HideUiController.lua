--!strict
--[[
	Studio anchor: PlayerGui.MobileLeftUI.dPad.HideUI
	Locked: lock icon + red transparent bg → unlock confirm (10 $D).
	Unlocked: eye icon + black bg → toggles HUD visibility (green/red flash).
]]

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local Constants = require(oceanRoot:WaitForChild("Shared"):WaitForChild("Constants"))
local HideUiUnlock = require(oceanRoot:WaitForChild("Shared"):WaitForChild("HideUiUnlock"))
local LeftHudLayout = require(oceanRoot:WaitForChild("Shared"):WaitForChild("LeftHudLayout"))
local Remotes = require(oceanRoot:WaitForChild("Remotes"))
local UiHaptics = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiHaptics"))
local UiTheme = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiTheme"))

local HideUiState = require(script.Parent:WaitForChild("HideUiState"))
local InventoryState = require(script.Parent:WaitForChild("InventoryState"))
local WaveSim = require(script.Parent:WaitForChild("WaveSim"))

local HideUiController = {}

local STUDIO_ANCHOR_NAME = "HideUI"
local CONFIRM_GUI_NAME = "OceanTD_HideUiConfirm"
local EYE_GLYPH_NAME = "_OceanTD_HideUiEye"
local BG_DISK_NAME = "_OceanTD_HideUiBg"
local LEGACY_LOCK_NAME = "_OceanTD_HideUiLock"
local RUNTIME_CHILD_NAMES = {
	_OceanTD_HideUiHit = true,
	[LEGACY_LOCK_NAME] = true,
	[EYE_GLYPH_NAME] = true,
	[BG_DISK_NAME] = true,
}
local EYE_SIZE_SCALE = 0.504 -- 30% smaller than 0.72
local GREEN_HOLD_SEC = 2
local BG_FADE_SEC = 4
local HUD_ANIM_SEC = 0.55
local ANIM_SCALE_NAME = "_OceanTD_HideUiAnimScale"
local KEEP_DPAD_NAMES = {
	[STUDIO_ANCHOR_NAME] = true,
	dPadIcon = true,
}

local PANEL_BG = Color3.fromRGB(18, 28, 40)
local GREEN = Color3.fromRGB(40, 180, 80)
local PULSE_GREEN = Color3.fromRGB(110, 255, 150)
local RED = Color3.fromRGB(200, 45, 55)
local STROKE_DARK = Color3.fromRGB(24, 36, 52)
local BLACK = Color3.fromRGB(0, 0, 0)
local WHITE = Color3.new(1, 1, 1)
local EYE_GLYPH = "👁"

local hideAnchor: GuiObject? = nil
local hideHitBtn: GuiButton? = nil
local bgDisk: Frame? = nil
local eyeGlyph: TextLabel? = nil
local lockedHostImage: string? = nil
local lockedHostImageTransparency: number? = nil
local lockedBgColor: Color3? = nil
local lockedBgTransparency: number? = nil
local bgTween: Tween? = nil

local confirmGui: ScreenGui? = nil
local confirmStrokeConn: RBXScriptConnection? = nil
local toastGui: ScreenGui? = nil

type AnimEntry = {
	gui: GuiObject,
	wasVisible: boolean,
	absCenter: Vector2,
	absSize: Vector2,
	flyClone: GuiObject?,
}

type ScreenGuiEntry = {
	gui: ScreenGui,
	wasEnabled: boolean,
}

local FLY_OVERLAY_NAME = "OceanTD_HideUiFly"
-- Ephemeral / must-not-disable ScreenGuis (never reparent children; never turn Enabled off).
local SKIP_SCREEN_GUI = {
	[FLY_OVERLAY_NAME] = true,
	[CONFIRM_GUI_NAME] = true,
	OceanTD_HideUiToast = true,
	OceanTD_SandDollarFly = true, -- WaveFeedPayout $D fly glyphs (Parent locks on Destroy)
	OceanTD_CoralSizeToast = true,
	OceanTD_CoralColorConfirm = true,
	OceanTD_CoralSizeConfirm = true,
	OceanTD_SkillUnlockConfirm = true,
	-- Skip clone/reparent of spinning Band; still disabled via screenGuis list below.
	OceanTD_SeedWheel = true,
}
-- SKIP entries that must remain Enabled while HUD is hidden.
local KEEP_ENABLED_WHILE_HIDDEN = {
	[FLY_OVERLAY_NAME] = true,
}
local animEntries: { AnimEntry } = {}
local hiddenScreenGuis: { ScreenGuiEntry } = {}
local animBusy = false
local activeAnimConns: { RBXScriptConnection } = {}
local activeAnimTweens: { Tween } = {}
local flyOverlay: ScreenGui? = nil

local unlockRf = Remotes.getFunction("RequestUnlockHideUi")

local function isGamepad(): boolean
	local t = UserInputService:GetLastInputType()
	return t == Enum.UserInputType.Gamepad1
		or t == Enum.UserInputType.Gamepad2
		or t == Enum.UserInputType.Gamepad3
		or t == Enum.UserInputType.Gamepad4
end

local function applyUnlockStroke(btn: GuiObject)
	local stroke = btn:FindFirstChild("_OceanTD_UnlockStroke")
	if not (stroke and stroke:IsA("UIStroke")) then
		stroke = Instance.new("UIStroke")
		stroke.Name = "_OceanTD_UnlockStroke"
		stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		stroke.LineJoinMode = Enum.LineJoinMode.Round
		stroke.Parent = btn
	end
	stroke.Thickness = 2
	stroke.Color = PULSE_GREEN
	stroke.Enabled = true
end

local function linkTwoWay(a: GuiButton, b: GuiButton)
	a.NextSelectionUp = b
	a.NextSelectionDown = b
	a.NextSelectionLeft = b
	a.NextSelectionRight = b
	b.NextSelectionUp = a
	b.NextSelectionDown = a
	b.NextSelectionLeft = a
	b.NextSelectionRight = a
end

local function cancelBgTween()
	if bgTween then
		bgTween:Cancel()
		bgTween = nil
	end
end

local function ensureBgDisk(host: GuiObject): Frame
	local existing = host:FindFirstChild(BG_DISK_NAME)
	if existing and existing:IsA("Frame") then
		return existing
	end
	if existing then
		existing:Destroy()
	end
	local disk = Instance.new("Frame")
	disk.Name = BG_DISK_NAME
	disk.AnchorPoint = Vector2.new(0.5, 0.5)
	disk.Position = UDim2.fromScale(0.5, 0.5)
	disk.Size = UDim2.fromScale(1, 1)
	disk.BackgroundColor3 = BLACK
	disk.BackgroundTransparency = 0
	disk.BorderSizePixel = 0
	disk.ZIndex = host.ZIndex
	disk.Active = false
	local hostCorner = host:FindFirstChildOfClass("UICorner")
	if hostCorner then
		local corner = Instance.new("UICorner")
		corner.CornerRadius = hostCorner.CornerRadius
		corner.Parent = disk
	end
	disk.Parent = host
	return disk
end

local function snapshotHostLockImage(host: GuiObject)
	if lockedHostImage ~= nil then
		return
	end
	if host:IsA("ImageButton") or host:IsA("ImageLabel") then
		lockedHostImage = host.Image
		lockedHostImageTransparency = host.ImageTransparency
	end
end

local function setLockGraphicsVisible(visible: boolean)
	local host = hideAnchor
	if not host then
		return
	end
	snapshotHostLockImage(host)
	if host:IsA("ImageButton") or host:IsA("ImageLabel") then
		if visible then
			if lockedHostImage ~= nil then
				host.Image = lockedHostImage
			end
			if lockedHostImageTransparency ~= nil then
				host.ImageTransparency = lockedHostImageTransparency
			end
		else
			host.Image = ""
			host.ImageTransparency = 1
		end
	end
	for _, ch in ipairs(host:GetChildren()) do
		if ch:IsA("GuiObject") and not RUNTIME_CHILD_NAMES[ch.Name] then
			if ch:IsA("ImageLabel") or ch:IsA("ImageButton") then
				ch.Visible = visible
			end
		end
	end
end

local function ensureEyeGlyph(host: GuiObject): TextLabel
	local existing = host:FindFirstChild(EYE_GLYPH_NAME)
	if existing and existing:IsA("TextLabel") then
		return existing
	end
	if existing then
		existing:Destroy()
	end
	local lbl = Instance.new("TextLabel")
	lbl.Name = EYE_GLYPH_NAME
	lbl.BackgroundTransparency = 1
	lbl.AnchorPoint = Vector2.new(0.5, 0.5)
	lbl.Position = UDim2.fromScale(0.5, 0.5)
	lbl.Size = UDim2.fromScale(EYE_SIZE_SCALE, EYE_SIZE_SCALE)
	lbl.Font = UiTheme.Font
	lbl.Text = EYE_GLYPH
	lbl.TextScaled = true
	lbl.TextColor3 = WHITE
	lbl.ZIndex = host.ZIndex + 2
	lbl.Active = false
	lbl.Parent = host
	return lbl
end

local function ensureHideHit(host: GuiObject): GuiButton
	host.Active = true
	if host:IsA("GuiButton") then
		return host
	end
	local existing = host:FindFirstChild("_OceanTD_HideUiHit")
	if existing and existing:IsA("GuiButton") then
		return existing
	end
	if existing then
		existing:Destroy()
	end
	local hit = Instance.new("TextButton")
	hit.Name = "_OceanTD_HideUiHit"
	hit.BackgroundTransparency = 1
	hit.BorderSizePixel = 0
	hit.Size = UDim2.fromScale(1, 1)
	hit.Text = ""
	hit.ZIndex = host.ZIndex + 5
	hit.Parent = host
	return hit
end

local function snapshotLockedStyle(host: GuiObject)
	if lockedBgColor == nil then
		lockedBgColor = host.BackgroundColor3
	end
	if lockedBgTransparency == nil then
		lockedBgTransparency = host.BackgroundTransparency
	end
end

local function applyLockedVisual()
	local host = hideAnchor
	if not host then
		return
	end
	snapshotLockedStyle(host)
	if lockedBgColor then
		host.BackgroundColor3 = lockedBgColor
	end
	if lockedBgTransparency ~= nil then
		host.BackgroundTransparency = lockedBgTransparency
	end
	if bgDisk then
		bgDisk.Visible = false
	end
	setLockGraphicsVisible(true)
	if eyeGlyph then
		eyeGlyph.Visible = false
	end
end

local function applyUnlockedIdleVisual()
	local host = hideAnchor
	if not host then
		return
	end
	cancelBgTween()
	if host:IsA("GuiButton") then
		host.AutoButtonColor = false
	end
	host.BackgroundTransparency = 1
	if bgDisk then
		bgDisk.Visible = true
		bgDisk.BackgroundColor3 = BLACK
		bgDisk.BackgroundTransparency = 0
	end
	setLockGraphicsVisible(false)
	if eyeGlyph then
		eyeGlyph.Visible = true
	end
end

local function refreshButtonVisual()
	if HideUiState.isUnlocked() then
		applyUnlockedIdleVisual()
	else
		applyLockedVisual()
	end
end

local function flashButtonBg(color: Color3, holdSec: number, fadeSec: number)
	local host = hideAnchor
	local disk = bgDisk
	if not host or not disk then
		return
	end
	cancelBgTween()
	if host:IsA("GuiButton") then
		host.AutoButtonColor = false
	end
	host.BackgroundTransparency = 1
	disk.Visible = true
	disk.BackgroundColor3 = color
	disk.BackgroundTransparency = 0
	setLockGraphicsVisible(false)
	if eyeGlyph then
		eyeGlyph.Visible = true
	end
	task.delay(holdSec, function()
		if hideAnchor ~= host or bgDisk ~= disk or not HideUiState.isUnlocked() then
			return
		end
		bgTween = TweenService:Create(disk, TweenInfo.new(fadeSec, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			BackgroundColor3 = BLACK,
			BackgroundTransparency = 0,
		})
		bgTween:Play()
	end)
end

local function showToast(msg: string)
	if toastGui then
		toastGui:Destroy()
	end
	local sg = Instance.new("ScreenGui")
	sg.Name = "OceanTD_HideUiToast"
	sg.ResetOnSpawn = false
	sg.IgnoreGuiInset = true
	sg.DisplayOrder = 25020
	sg.Parent = playerGui
	toastGui = sg
	local lbl = Instance.new("TextLabel")
	lbl.AnchorPoint = Vector2.new(0.5, 1)
	lbl.Position = UDim2.new(0.5, 0, 1, -48)
	lbl.Size = UDim2.fromOffset(360, 44)
	lbl.BackgroundColor3 = PANEL_BG
	lbl.BackgroundTransparency = 0.1
	lbl.BorderSizePixel = 0
	lbl.Font = UiTheme.Font
	lbl.TextSize = 20
	lbl.TextColor3 = Color3.fromRGB(255, 230, 200)
	lbl.Text = msg
	lbl.Parent = sg
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 10)
	c.Parent = lbl
	task.delay(2.2, function()
		if toastGui == sg then
			sg:Destroy()
			toastGui = nil
		end
	end)
end

local function disconnectAnimConns()
	for _, conn in ipairs(activeAnimConns) do
		if conn.Connected then
			conn:Disconnect()
		end
	end
	table.clear(activeAnimConns)
	for _, tw in ipairs(activeAnimTweens) do
		pcall(function()
			tw:Cancel()
		end)
	end
	table.clear(activeAnimTweens)
end

local function destroyFlyOverlay()
	if flyOverlay then
		flyOverlay:Destroy()
		flyOverlay = nil
	end
end

local function ensureFlyOverlay(): ScreenGui
	if flyOverlay and flyOverlay.Parent then
		return flyOverlay
	end
	destroyFlyOverlay()
	local sg = Instance.new("ScreenGui")
	sg.Name = FLY_OVERLAY_NAME
	sg.ResetOnSpawn = false
	sg.IgnoreGuiInset = true
	sg.DisplayOrder = 24990
	sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	sg.Parent = playerGui
	flyOverlay = sg
	return sg
end

-- AbsolutePosition → Position on an IgnoreGuiInset=true ScreenGui.
-- Same convention as SeedWheelReveal.leftHudScreenCenter (always add GuiInset).
local function toOverlayCenter(gui: GuiObject): Vector2
	local inset = GuiService:GetGuiInset()
	local c = gui.AbsolutePosition + gui.AbsoluteSize * 0.5
	return Vector2.new(c.X + inset.X, c.Y + inset.Y)
end

local function getHideUiScreenCenter(): Vector2
	local anchor = hideAnchor
	if not anchor or not anchor:IsDescendantOf(playerGui) then
		local cam = workspace.CurrentCamera
		local vp = if cam then cam.ViewportSize else Vector2.new(1280, 720)
		local inset = GuiService:GetGuiInset()
		return Vector2.new(vp.X * 0.5 + inset.X, vp.Y * 0.5 + inset.Y)
	end
	return toOverlayCenter(anchor)
end

local function isAliveGui(gui: Instance?): boolean
	return gui ~= nil and gui.Parent ~= nil and gui:IsDescendantOf(game)
end

local function prepareAnimEntry(gui: GuiObject): AnimEntry?
	if not isAliveGui(gui) then
		return nil
	end
	local sg = gui:FindFirstAncestorOfClass("ScreenGui")
	if sg and SKIP_SCREEN_GUI[sg.Name] then
		return nil
	end
	return {
		gui = gui,
		wasVisible = gui.Visible,
		absCenter = toOverlayCenter(gui),
		absSize = gui.AbsoluteSize,
		flyClone = nil,
	}
end

local function makeFlyClone(entry: AnimEntry, atCenter: Vector2, startScale: number): (GuiObject?, UIScale?)
	if not isAliveGui(entry.gui) then
		return nil, nil
	end
	local ok, cloneOrErr = pcall(function()
		return entry.gui:Clone()
	end)
	if not ok or typeof(cloneOrErr) ~= "Instance" or not cloneOrErr:IsA("GuiObject") then
		return nil, nil
	end
	local clone = cloneOrErr :: GuiObject
	-- AbsoluteSize already includes every UIScale in the original tree.
	-- Strip scales on the clone so we don't double-size.
	for _, d in ipairs(clone:GetDescendants()) do
		if d:IsA("UIScale") then
			d:Destroy()
		elseif d:IsA("GuiButton") then
			d.Active = false
			d.AutoButtonColor = false
		end
	end
	for _, ch in ipairs(clone:GetChildren()) do
		if ch:IsA("UIScale") then
			ch:Destroy()
		end
	end
	if clone:IsA("GuiButton") then
		clone.Active = false
		clone.AutoButtonColor = false
	end
	local scale = Instance.new("UIScale")
	scale.Name = ANIM_SCALE_NAME
	scale.Scale = startScale
	scale.Parent = clone
	clone.AnchorPoint = Vector2.new(0.5, 0.5)
	clone.Size = UDim2.fromOffset(math.max(1, entry.absSize.X), math.max(1, entry.absSize.Y))
	clone.Position = UDim2.fromOffset(atCenter.X, atCenter.Y)
	clone.Visible = true
	clone.Parent = ensureFlyOverlay()
	return clone, scale
end

local function tweenFlyClone(
	clone: GuiObject,
	scale: UIScale,
	toCenter: Vector2,
	toScale: number,
	duration: number,
	destroyWhenDone: boolean,
	onDone: () -> ()
)
	local info = TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local posTw = TweenService:Create(clone, info, {
		Position = UDim2.fromOffset(toCenter.X, toCenter.Y),
	})
	local scaleTw = TweenService:Create(scale, info, {
		Scale = math.max(0.001, toScale),
	})
	table.insert(activeAnimTweens, posTw)
	table.insert(activeAnimTweens, scaleTw)
	local finished = false
	local function finish()
		if finished then
			return
		end
		finished = true
		if destroyWhenDone and clone.Parent then
			clone:Destroy()
		end
		onDone()
	end
	scaleTw.Completed:Connect(finish)
	posTw:Play()
	scaleTw:Play()
end

local function runCollapseAnims(entries: { AnimEntry }, onAllDone: () -> ())
	if #entries == 0 then
		onAllDone()
		return
	end
	local targetAbs = getHideUiScreenCenter()
	local remaining = #entries
	for _, entry in ipairs(entries) do
		local function oneDone()
			remaining -= 1
			if remaining <= 0 then
				onAllDone()
			end
		end
		if isAliveGui(entry.gui) then
			entry.gui.Visible = false
		end
		local clone, scale = makeFlyClone(entry, entry.absCenter, 1)
		if not clone or not scale then
			oneDone()
		else
			tweenFlyClone(clone, scale, targetAbs, 0.001, HUD_ANIM_SEC, true, oneDone)
		end
	end
end

local function handoffExpandClones(entries: { AnimEntry })
	-- Re-enable real HUD under the clones, let layout settle, snap clones onto the
	-- live AbsolutePositions, then reveal originals and drop clones in one frame.
	for _, sgEntry in ipairs(hiddenScreenGuis) do
		if sgEntry.gui.Parent then
			sgEntry.gui.Enabled = sgEntry.wasEnabled
		end
	end
	for _, entry in ipairs(entries) do
		if isAliveGui(entry.gui) then
			entry.gui.Visible = false
		end
	end
	RunService.Heartbeat:Wait()
	RunService.Heartbeat:Wait()
	for _, entry in ipairs(entries) do
		local clone = entry.flyClone
		if clone and clone.Parent and isAliveGui(entry.gui) then
			local live = toOverlayCenter(entry.gui)
			local liveSize = entry.gui.AbsoluteSize
			if liveSize.X >= 1 and liveSize.Y >= 1 then
				clone.Size = UDim2.fromOffset(liveSize.X, liveSize.Y)
			end
			clone.Position = UDim2.fromOffset(live.X, live.Y)
			local sc = clone:FindFirstChild(ANIM_SCALE_NAME)
			if sc and sc:IsA("UIScale") then
				sc.Scale = 1
			end
		end
	end
	for _, entry in ipairs(entries) do
		if isAliveGui(entry.gui) then
			entry.gui.Visible = entry.wasVisible
		end
		entry.flyClone = nil
	end
	destroyFlyOverlay()
end

local function runExpandAnims(entries: { AnimEntry }, onAllDone: () -> ())
	if #entries == 0 then
		onAllDone()
		return
	end
	local targetAbs = getHideUiScreenCenter()
	local remaining = #entries
	for _, entry in ipairs(entries) do
		local function oneDone()
			remaining -= 1
			if remaining <= 0 then
				handoffExpandClones(entries)
				onAllDone()
			end
		end
		if not isAliveGui(entry.gui) then
			oneDone()
		else
			entry.gui.Visible = false
			local clone, scale = makeFlyClone(entry, targetAbs, 0.001)
			if not clone or not scale then
				oneDone()
			else
				entry.flyClone = clone
				tweenFlyClone(clone, scale, entry.absCenter, 1, HUD_ANIM_SEC, false, oneDone)
			end
		end
	end
end

local function collectHudHideTargets(): ({ AnimEntry }, { ScreenGuiEntry })
	local animTargets: { AnimEntry } = {}
	local screenGuis: { ScreenGuiEntry } = {}
	for _, ch in ipairs(playerGui:GetChildren()) do
		if ch:IsA("ScreenGui") and ch.Name ~= "MobileLeftUI" and ch.Enabled then
			if SKIP_SCREEN_GUI[ch.Name] then
				if not KEEP_ENABLED_WHILE_HIDDEN[ch.Name] then
					table.insert(screenGuis, { gui = ch, wasEnabled = ch.Enabled })
				end
			else
				table.insert(screenGuis, { gui = ch, wasEnabled = ch.Enabled })
				for _, child in ipairs(ch:GetChildren()) do
					if child:IsA("GuiObject") and child.Visible then
						local entry = prepareAnimEntry(child)
						if entry then
							table.insert(animTargets, entry)
						end
					end
				end
			end
		end
	end
	local left = playerGui:FindFirstChild("MobileLeftUI")
	if left and left:IsA("ScreenGui") then
		for _, ch in ipairs(left:GetChildren()) do
			if ch:IsA("GuiObject") and ch.Name ~= "dPad" and ch.Visible then
				local entry = prepareAnimEntry(ch)
				if entry then
					table.insert(animTargets, entry)
				end
			end
		end
		local dPad = left:FindFirstChild("dPad")
		if dPad then
			for _, ch in ipairs(dPad:GetChildren()) do
				if ch:IsA("GuiObject") and not KEEP_DPAD_NAMES[ch.Name] and ch.Visible then
					local entry = prepareAnimEntry(ch)
					if entry then
						table.insert(animTargets, entry)
					end
				end
			end
		end
	end
	return animTargets, screenGuis
end

local function closeTransientUi()
	pcall(function()
		local settings = require(script.Parent:WaitForChild("SettingsUI"))
		if settings.isOpen and settings.isOpen() then
			settings.close()
		end
	end)
end

local function resyncSubsystemsAfterShow()
	task.defer(function()
		if InventoryState.isOpen() then
			local left = playerGui:FindFirstChild("MobileLeftUI")
			if left then
				local dPad = left:FindFirstChild("dPad")
				if dPad then
					for _, ch in ipairs(dPad:GetChildren()) do
						if ch:IsA("GuiObject") and ch.Name ~= "dPadIcon" and not LeftHudLayout.isSandDollarChrome(ch) then
							ch.Visible = false
						end
					end
				end
				for _, ch in ipairs(left:GetChildren()) do
					if ch:IsA("GuiObject") and ch.Name ~= "dPad" and not LeftHudLayout.isSandDollarChrome(ch) then
						ch.Visible = false
					end
				end
			end
		end
		if playerGui:GetAttribute("OceanTD_SkillsBubblesOpen") == true then
			local left = playerGui:FindFirstChild("MobileLeftUI")
			if left then
				local dPad = left:FindFirstChild("dPad")
				if dPad then
					for _, ch in ipairs(dPad:GetChildren()) do
						if
							ch:IsA("GuiObject")
							and ch.Name ~= "Skills"
							and ch.Name ~= "dPadIcon"
							and not LeftHudLayout.isSandDollarChrome(ch)
						then
							ch.Visible = false
						end
					end
				end
				for _, ch in ipairs(left:GetChildren()) do
					if ch:IsA("GuiObject") and ch.Name ~= "dPad" and not LeftHudLayout.isSandDollarChrome(ch) then
						ch.Visible = false
					end
				end
			end
		end
	end)
end

local function finalizeHudHidden()
	disconnectAnimConns()
	for _, entry in ipairs(animEntries) do
		if isAliveGui(entry.gui) and entry.wasVisible then
			entry.gui.Visible = false
		end
	end
	for _, sgEntry in ipairs(hiddenScreenGuis) do
		if sgEntry.gui.Parent then
			sgEntry.gui.Enabled = false
		end
	end
	destroyFlyOverlay()
end

local function applyHudHiddenInstant(hidden: boolean)
	disconnectAnimConns()
	animBusy = false
	destroyFlyOverlay()
	if hidden then
		if #animEntries > 0 then
			return
		end
		closeTransientUi()
		WaveSim.setHideUiSuppressesCritterUi(true)
		local targets, sgs = collectHudHideTargets()
		animEntries = targets
		hiddenScreenGuis = sgs
		finalizeHudHidden()
	else
		WaveSim.setHideUiSuppressesCritterUi(false)
		for _, sgEntry in ipairs(hiddenScreenGuis) do
			if sgEntry.gui.Parent then
				sgEntry.gui.Enabled = sgEntry.wasEnabled
			end
		end
		for _, entry in ipairs(animEntries) do
			if isAliveGui(entry.gui) then
				entry.gui.Visible = entry.wasVisible
			end
		end
		table.clear(animEntries)
		table.clear(hiddenScreenGuis)
		resyncSubsystemsAfterShow()
	end
	HideUiState.setActive(hidden)
end

local function applyHudHidden(hidden: boolean, animated: boolean?)
	if animBusy then
		return
	end
	if animated == false then
		applyHudHiddenInstant(hidden)
		return
	end
	if hidden then
		if #animEntries > 0 then
			return
		end
		closeTransientUi()
		WaveSim.setHideUiSuppressesCritterUi(true)
		local targets, sgs = collectHudHideTargets()
		animEntries = targets
		hiddenScreenGuis = sgs
		if #animEntries == 0 then
			finalizeHudHidden()
			HideUiState.setActive(true)
			return
		end
		animBusy = true
		HideUiState.setActive(true)
		runCollapseAnims(animEntries, function()
			finalizeHudHidden()
			animBusy = false
		end)
	else
		if #animEntries == 0 then
			HideUiState.setActive(false)
			WaveSim.setHideUiSuppressesCritterUi(false)
			return
		end
		WaveSim.setHideUiSuppressesCritterUi(false)
		-- Keep ScreenGuis disabled while clones fly out (prevents Wave HUD + clone double-draw).
		for _, entry in ipairs(animEntries) do
			if isAliveGui(entry.gui) then
				entry.gui.Visible = false
			end
		end
		animBusy = true
		runExpandAnims(animEntries, function()
			-- handoffExpandClones already re-enabled ScreenGuis, showed originals, destroyed overlay.
			table.clear(animEntries)
			table.clear(hiddenScreenGuis)
			animBusy = false
			HideUiState.setActive(false)
			resyncSubsystemsAfterShow()
		end)
	end
end

local function hideConfirm()
	if confirmStrokeConn then
		confirmStrokeConn:Disconnect()
		confirmStrokeConn = nil
	end
	if confirmGui then
		confirmGui:Destroy()
		confirmGui = nil
	end
	GuiService.SelectedObject = nil
end

local function tryUnlockConfirm()
	local cash = tonumber(player:GetAttribute(Constants.SAND_DOLLARS_ATTR)) or 0
	if cash < HideUiUnlock.UNLOCK_COST then
		showToast("Collect More $D")
		return
	end
	local ok, result = pcall(function()
		return unlockRf:InvokeServer()
	end)
	if not ok or typeof(result) ~= "table" then
		showToast("Unlock failed")
		return
	end
	if result.ok ~= true then
		if result.errorCode == "CantAfford" then
			showToast("Collect More $D")
		else
			showToast("Unlock failed")
		end
		return
	end
	HideUiState.setUnlocked(true)
	hideConfirm()
	refreshButtonVisual()
end

local function showConfirmUnlock()
	hideConfirm()
	local sg = Instance.new("ScreenGui")
	sg.Name = CONFIRM_GUI_NAME
	sg.ResetOnSpawn = false
	sg.IgnoreGuiInset = true
	sg.DisplayOrder = 25000
	sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	sg.Parent = playerGui
	confirmGui = sg

	local dim = Instance.new("TextButton")
	dim.Text = ""
	dim.AutoButtonColor = false
	dim.BackgroundColor3 = Color3.fromRGB(0, 8, 16)
	dim.BackgroundTransparency = 0.4
	dim.Size = UDim2.fromScale(1, 1)
	dim.Selectable = false
	dim.ZIndex = 1
	dim.Parent = sg
	dim.Activated:Connect(hideConfirm)

	local panel = Instance.new("Frame")
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromOffset(320, 240)
	panel.BackgroundColor3 = PANEL_BG
	panel.BorderSizePixel = 0
	panel.ZIndex = 2
	panel.Selectable = false
	panel.Parent = sg
	local pc = Instance.new("UICorner")
	pc.CornerRadius = UDim.new(0, 14)
	pc.Parent = panel
	local panelStroke = Instance.new("UIStroke")
	panelStroke.Name = "_OceanTD_UnlockStroke"
	panelStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	panelStroke.LineJoinMode = Enum.LineJoinMode.Round
	panelStroke.Thickness = 3
	panelStroke.Color = STROKE_DARK
	panelStroke.Parent = panel

	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Size = UDim2.new(1, -24, 0, 44)
	title.Position = UDim2.fromOffset(12, 16)
	title.Font = UiTheme.Font
	title.TextSize = 24
	title.TextColor3 = Color3.fromRGB(240, 248, 255)
	title.Text = "Unlock Hide UI"
	title.ZIndex = 3
	title.Parent = panel

	local costLbl = Instance.new("TextLabel")
	costLbl.BackgroundTransparency = 1
	costLbl.Size = UDim2.new(1, -24, 0, 28)
	costLbl.Position = UDim2.fromOffset(12, 58)
	costLbl.Font = UiTheme.Font
	costLbl.TextSize = 22
	costLbl.TextColor3 = Color3.fromRGB(255, 220, 120)
	costLbl.Text = tostring(HideUiUnlock.UNLOCK_COST) .. " $D"
	costLbl.ZIndex = 3
	costLbl.Parent = panel

	local unlock = Instance.new("TextButton")
	unlock.Name = "UNLOCK"
	unlock.Text = "UNLOCK"
	unlock.Font = UiTheme.Font
	unlock.TextSize = 20
	unlock.TextColor3 = WHITE
	unlock.BackgroundColor3 = GREEN
	unlock.BorderSizePixel = 0
	unlock.Size = UDim2.fromOffset(200, 48)
	unlock.AnchorPoint = Vector2.new(0.5, 0)
	unlock.Position = UDim2.new(0.5, 0, 0, 100)
	unlock.ZIndex = 3
	unlock.Parent = panel
	local uc = Instance.new("UICorner")
	uc.CornerRadius = UDim.new(0, 10)
	uc.Parent = unlock
	applyUnlockStroke(unlock)
	if confirmStrokeConn then
		confirmStrokeConn:Disconnect()
	end
	confirmStrokeConn = RunService.Heartbeat:Connect(function()
		if confirmGui ~= sg then
			return
		end
		local u = (math.sin(os.clock() * math.pi * 1.35) + 1) * 0.5
		local c = STROKE_DARK:Lerp(PULSE_GREEN, u)
		panelStroke.Color = c
		local unlockStroke = unlock:FindFirstChild("_OceanTD_UnlockStroke")
		if unlockStroke and unlockStroke:IsA("UIStroke") then
			unlockStroke.Color = c
			unlockStroke.Thickness = 2 + u * 2
		end
		panelStroke.Thickness = 3 + u * 2
	end)
	unlock.Activated:Connect(tryUnlockConfirm)

	local cancel = Instance.new("TextButton")
	cancel.Name = "CANCEL"
	cancel.Text = "CANCEL"
	cancel.Font = UiTheme.Font
	cancel.TextSize = 18
	cancel.TextColor3 = WHITE
	cancel.BackgroundColor3 = RED
	cancel.BorderSizePixel = 0
	cancel.Size = UDim2.fromOffset(200, 44)
	cancel.AnchorPoint = Vector2.new(0.5, 0)
	cancel.Position = UDim2.new(0.5, 0, 0, 160)
	cancel.ZIndex = 3
	cancel.Parent = panel
	local cc = Instance.new("UICorner")
	cc.CornerRadius = UDim.new(0, 10)
	cc.Parent = cancel
	cancel.Activated:Connect(hideConfirm)

	if isGamepad() then
		unlock.Selectable = true
		cancel.Selectable = true
		linkTwoWay(unlock, cancel)
		GuiService.AutoSelectGuiEnabled = true
		GuiService.SelectedObject = unlock
	else
		local tipT0 = os.clock()
		local tipConn: RBXScriptConnection? = nil
		tipConn = RunService.Heartbeat:Connect(function()
			if confirmGui ~= sg then
				if tipConn then
					tipConn:Disconnect()
				end
				return
			end
			local showTip = (math.floor((os.clock() - tipT0) / 1) % 2) == 1
			unlock.Text = if showTip then "Enter" else "UNLOCK"
			cancel.Text = if showTip then "Backspace" else "CANCEL"
		end)
	end
end

local function onHideUiPressed()
	if confirmGui or animBusy then
		return
	end
	UiHaptics.pulseShort()
	if not HideUiState.isUnlocked() then
		showConfirmUnlock()
		return
	end
	local nextHidden = not HideUiState.isActive()
	if nextHidden then
		flashButtonBg(RED, GREEN_HOLD_SEC, BG_FADE_SEC)
	else
		flashButtonBg(GREEN, 0, BG_FADE_SEC)
	end
	applyHudHidden(nextHidden)
end

local function wireStudioHideUiButton(leftOpt: Instance?)
	local left = leftOpt or playerGui:FindFirstChild("MobileLeftUI") or playerGui:WaitForChild("MobileLeftUI", 60)
	if not left then
		warn("[HideUI] PlayerGui.MobileLeftUI missing")
		return
	end
	LeftHudLayout.hardenScreenGui(left)
	local dPad = left:FindFirstChild("dPad") or left:WaitForChild("dPad", 30)
	if not dPad then
		warn("[HideUI] MobileLeftUI.dPad missing")
		return
	end
	local anchor = dPad:FindFirstChild(STUDIO_ANCHOR_NAME) or dPad:WaitForChild(STUDIO_ANCHOR_NAME, 30)
	if not anchor or not anchor:IsA("GuiObject") then
		warn("[HideUI] MobileLeftUI.dPad.HideUI missing — add anchor in Studio")
		return
	end
	if hideAnchor == anchor and hideHitBtn and hideHitBtn.Parent then
		return
	end
	lockedHostImage = nil
	lockedHostImageTransparency = nil
	hideAnchor = anchor
	if anchor:IsA("GuiButton") then
		anchor.AutoButtonColor = false
	end
	snapshotLockedStyle(anchor)
	snapshotHostLockImage(anchor)
	local legacyLock = anchor:FindFirstChild(LEGACY_LOCK_NAME)
	if legacyLock then
		legacyLock:Destroy()
	end
	bgDisk = ensureBgDisk(anchor)
	eyeGlyph = ensureEyeGlyph(anchor)
	if eyeGlyph then
		eyeGlyph.Size = UDim2.fromScale(EYE_SIZE_SCALE, EYE_SIZE_SCALE)
	end
	local hit = ensureHideHit(anchor)
	hideHitBtn = hit
	refreshButtonVisual()
	if not hit:GetAttribute("_OceanTD_HideUiWired") then
		hit:SetAttribute("_OceanTD_HideUiWired", true)
		hit.Activated:Connect(onHideUiPressed)
	end
end

function HideUiController.init()
	LeftHudLayout.watchMobileLeftUi(playerGui, wireStudioHideUiButton)
	local lastUnlocked = HideUiState.isUnlocked()
	HideUiState.onChanged(function()
		if not HideUiState.isUnlocked() and HideUiState.isActive() then
			applyHudHidden(false, false)
		end
		local unlockedNow = HideUiState.isUnlocked()
		if unlockedNow ~= lastUnlocked then
			lastUnlocked = unlockedNow
			refreshButtonVisual()
		end
	end)
	playerGui.ChildAdded:Connect(function(ch)
		if not HideUiState.isActive() or animBusy then
			return
		end
		if ch:IsA("ScreenGui") and SKIP_SCREEN_GUI[ch.Name] and not KEEP_ENABLED_WHILE_HIDDEN[ch.Name] then
			task.defer(function()
				if not HideUiState.isActive() or ch.Parent ~= playerGui then
					return
				end
				if ch:IsA("ScreenGui") and ch.Enabled then
					table.insert(hiddenScreenGuis, { gui = ch, wasEnabled = true })
					ch.Enabled = false
				end
			end)
			return
		end
		if ch:IsA("ScreenGui") and ch.Name ~= "MobileLeftUI" and not SKIP_SCREEN_GUI[ch.Name] then
			task.defer(function()
				if not HideUiState.isActive() or animBusy or ch.Parent ~= playerGui then
					return
				end
				if not ch:IsA("ScreenGui") or not ch.Enabled then
					return
				end
				table.insert(hiddenScreenGuis, { gui = ch, wasEnabled = ch.Enabled })
				local newTargets: { AnimEntry } = {}
				for _, child in ipairs(ch:GetChildren()) do
					if child:IsA("GuiObject") and child.Visible then
						local entry = prepareAnimEntry(child)
						if entry then
							table.insert(animEntries, entry)
							table.insert(newTargets, entry)
						end
					end
				end
				if #newTargets > 0 then
					runCollapseAnims(newTargets, function()
						for _, entry in ipairs(newTargets) do
							if isAliveGui(entry.gui) and entry.wasVisible then
								entry.gui.Visible = false
							end
						end
						if ch.Parent then
							ch.Enabled = false
						end
					end)
				else
					ch.Enabled = false
				end
			end)
		end
	end)
	task.spawn(function()
		while true do
			task.wait(2)
			if not hideHitBtn or not hideHitBtn.Parent then
				wireStudioHideUiButton(nil)
			end
		end
	end)
end

function HideUiController.isActive(): boolean
	return HideUiState.isActive()
end

function HideUiController.handleConfirmInput(input: InputObject, gameProcessed: boolean): boolean
	if not confirmGui then
		return false
	end
	if input.KeyCode == Enum.KeyCode.ButtonB then
		hideConfirm()
		return true
	end
	if input.KeyCode == Enum.KeyCode.ButtonA then
		tryUnlockConfirm()
		return true
	end
	if input.UserInputType ~= Enum.UserInputType.Keyboard then
		return false
	end
	if gameProcessed then
		return false
	end
	local key = input.KeyCode
	if key == Enum.KeyCode.Return or key == Enum.KeyCode.KeypadEnter then
		tryUnlockConfirm()
		return true
	end
	if key == Enum.KeyCode.Backspace or key == Enum.KeyCode.Escape then
		hideConfirm()
		return true
	end
	return false
end

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	HideUiController.handleConfirmInput(input, gameProcessed)
end)

return HideUiController
