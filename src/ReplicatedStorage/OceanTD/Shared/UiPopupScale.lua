--!strict
--[[
	Scales AI-built modal/popup panels so 720p-class screens match mobile visual size.

	Mobile class (see UiViewportTags.is720p): scale = 1.
	720p class: scale = shortEdge / 720 (clamped), via UIScale on the panel root.
]]

local Workspace = game:GetService("Workspace")

local UiViewportTags = require(script.Parent:WaitForChild("UiViewportTags"))

local UiPopupScale = {}

local SCALE_NAME = "_OceanTD_PopupScale"
local MAX_SCALE = 2.25
local watched: { [UIScale]: boolean } = {}
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

local function refreshAll()
	local s = UiPopupScale.get()
	for scaleObj in pairs(watched) do
		if scaleObj.Parent then
			scaleObj.Scale = s
		else
			watched[scaleObj] = nil
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
	return scaleObj
end

return UiPopupScale
