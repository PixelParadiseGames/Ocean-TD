--!strict
--[[
	Scales AI-built modal/popup panels so 720p-class screens match mobile visual size.

	Mobile class (see UiViewportTags.is720p): scale = 1.
	720p class popups: scale = shortEdge / 720 (clamped).

	HUD chrome (roll, bars, store, power-up, skip) uses getHud(). That matches the
	authored BUILD button: 720pRightHUD.Quickbar.Slot4 vs the phone Slot4. The
	seed-wheel 3× (UiViewportTags.wideUiScale) is the fallback when Slot4 can't
	be measured. Phone layouts stay at 1.
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local UiViewportTags = require(script.Parent:WaitForChild("UiViewportTags"))

local UiPopupScale = {}

local SCALE_NAME = "_OceanTD_PopupScale"
local MAX_SCALE = 2.25
local SIZE_CAP_ATTR = "_OceanTD_SizeCapBase"
-- Landscape phone used only to read a scale-based mobile Slot4. Offset sizes ignore this.
local PHONE_REF = Vector2.new(844, 390)
local watched: { [UIScale]: boolean } = {}
local hudWatched: { [UIScale]: boolean } = {}
local sizeConn: RBXScriptConnection? = nil
local camConn: RBXScriptConnection? = nil

function UiPopupScale.get(viewport: Vector2?): number
	local vp = viewport or UiViewportTags.readViewport()
	-- Keep mobile / phone layouts at 1 — including high-DPI phones.
	if not UiViewportTags.is720p(vp) then
		return 1
	end
	local short = math.min(vp.X, vp.Y)
	return math.clamp(short / UiViewportTags.HEIGHT_BREAKPOINT, 1, MAX_SCALE)
end

-- Load-screen bubbles already look right at this factor. Do not route them through getHud.
function UiPopupScale.getLoadBubble(viewport: Vector2?): number
	local vp = viewport or UiViewportTags.readViewport()
	if not UiViewportTags.is720p(vp) then
		return 1
	end
	local short = math.min(vp.X, vp.Y)
	return math.clamp(math.max(1.6, short / UiViewportTags.HEIGHT_BREAKPOINT), 1, MAX_SCALE)
end

local function slot4Of(hud: Instance?): GuiObject?
	if not hud then
		return nil
	end
	local quickbar = hud:FindFirstChild("Quickbar")
	local slot = quickbar and quickbar:FindFirstChild("Slot4")
	if slot and slot:IsA("GuiObject") then
		return slot
	end
	return nil
end

local function authoredPixels(gui: GuiObject, vp: Vector2): number
	local s = gui.Size
	local x = s.X.Scale * vp.X + s.X.Offset
	local y = s.Y.Scale * vp.Y + s.Y.Offset
	return math.max(x, y)
end

function UiPopupScale.getHud(viewport: Vector2?): number
	local vp = viewport or UiViewportTags.readViewport()
	if not UiViewportTags.is720p(vp) then
		return 1
	end
	local player = Players.LocalPlayer
	local pg = player and player:FindFirstChild("PlayerGui")
	if pg then
		local mobileSlot = slot4Of(pg:FindFirstChild(UiViewportTags.MOBILE_RIGHT_HUD))
		local wideSlot = slot4Of(pg:FindFirstChild(UiViewportTags.P720_RIGHT_HUD))
		if mobileSlot and wideSlot then
			local mobilePx = authoredPixels(mobileSlot, PHONE_REF)
			local widePx = authoredPixels(wideSlot, vp)
			if mobilePx >= 8 and widePx >= 8 then
				local ratio = widePx / mobilePx
				-- Same authored pixels on both HUDs means BUILD is not actually larger;
				-- use the 3× class that already matches the 720p seed wheel.
				if ratio >= 1.2 then
					return math.clamp(ratio, 1, 6)
				end
			end
		end
	end
	return UiViewportTags.wideUiScale(vp)
end

-- Product of UIScales from `start` up to (not including) the ScreenGui.
-- Position/Size offsets are in this space; AbsolutePosition is screen pixels.
function UiPopupScale.ancestorScale(start: Instance): number
	local product = 1
	local cur: Instance? = start
	while cur and not cur:IsA("LayerCollector") do
		if cur:IsA("GuiObject") then
			for _, ch in ipairs(cur:GetChildren()) do
				if ch:IsA("UIScale") then
					product *= math.max(ch.Scale, 0)
				end
			end
		end
		cur = cur.Parent
	end
	if product < 0.001 then
		return 1
	end
	return product
end

-- A UISizeConstraint capped at the phone pixel size swallows UIScale, so the
-- widget stays phone-sized on a large screen. Lift that cap with the HUD scale.
local function relaxSizeCap(root: GuiObject, scale: number)
	local cap = root:FindFirstChildOfClass("UISizeConstraint")
	if not cap then
		return
	end
	local base = cap:GetAttribute(SIZE_CAP_ATTR)
	if typeof(base) ~= "Vector2" then
		base = cap.MaxSize
		cap:SetAttribute(SIZE_CAP_ATTR, base)
	end
	local b = base :: Vector2
	local extra = root:GetAttribute("_OceanTD_SizeCapExtra")
	local mul = if typeof(extra) == "number" and extra > 0 then extra else 1
	if scale <= 1.01 then
		cap.MaxSize = Vector2.new(b.X * mul, b.Y * mul)
		return
	end
	cap.MaxSize = Vector2.new(b.X * scale * mul, b.Y * scale * mul)
end

local function refreshAll()
	local s = UiPopupScale.get()
	local hudS = UiPopupScale.getHud()
	for scaleObj in pairs(watched) do
		if scaleObj.Parent then
			scaleObj.Scale = s
			if scaleObj.Parent:IsA("GuiObject") then
				relaxSizeCap(scaleObj.Parent :: GuiObject, s)
			end
		else
			watched[scaleObj] = nil
		end
	end
	for scaleObj in pairs(hudWatched) do
		if scaleObj.Parent then
			scaleObj.Scale = hudS
			if scaleObj.Parent:IsA("GuiObject") then
				relaxSizeCap(scaleObj.Parent :: GuiObject, hudS)
			end
		else
			hudWatched[scaleObj] = nil
		end
	end
end

local function ensureWatch()
	if camConn then
		return
	end
	local function bind(cam: Camera?)
		if sizeConn then
			sizeConn:Disconnect()
			sizeConn = nil
		end
		if not cam then
			return
		end
		sizeConn = cam:GetPropertyChangedSignal("ViewportSize"):Connect(refreshAll)
		refreshAll()
	end
	bind(Workspace.CurrentCamera)
	camConn = Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		bind(Workspace.CurrentCamera)
	end)
	-- Device emulator often reports the real ViewportSize a beat after the first scale.
	task.delay(0.5, refreshAll)
	task.delay(1.5, refreshAll)
end

--[[
	Attach (or reuse) a UIScale on `root`. Returns the scale instance.
	Safe to call every open — refreshes Scale for the current viewport.
]]
function UiPopupScale.attach(root: GuiObject): UIScale
	ensureWatch()
	local existing = root:FindFirstChild(SCALE_NAME)
	local scaleObj: UIScale
	if existing and existing:IsA("UIScale") then
		scaleObj = existing
	else
		if existing then
			existing:Destroy()
		end
		scaleObj = Instance.new("UIScale")
		scaleObj.Name = SCALE_NAME
		scaleObj.Parent = root
	end
	watched[scaleObj] = true
	scaleObj.Scale = UiPopupScale.get()
	relaxSizeCap(root, scaleObj.Scale)
	return scaleObj
end

function UiPopupScale.attachHud(root: GuiObject): UIScale
	ensureWatch()
	local existing = root:FindFirstChild(SCALE_NAME)
	local scaleObj: UIScale
	if existing and existing:IsA("UIScale") then
		scaleObj = existing
	else
		if existing then
			existing:Destroy()
		end
		scaleObj = Instance.new("UIScale")
		scaleObj.Name = SCALE_NAME
		scaleObj.Parent = root
	end
	hudWatched[scaleObj] = true
	watched[scaleObj] = nil
	scaleObj.Scale = UiPopupScale.getHud()
	relaxSizeCap(root, scaleObj.Scale)
	return scaleObj
end

return UiPopupScale
