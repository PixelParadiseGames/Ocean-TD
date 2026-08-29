--!strict
--[[
	Helpers for Studio MobileLeftUI (dPad + $D + $DCount).
	720p+ layout is applied client-side in LeftHudViewport.client.lua.
]]

local Constants = require(script.Parent:WaitForChild("Constants"))

local LeftHudLayout = {}

LeftHudLayout.LABEL_NAME = Constants.SAND_DOLLARS_LABEL_NAME
LeftHudLayout.COUNT_NAME = Constants.SAND_DOLLARS_COUNT_NAME
LeftHudLayout.ROW_NAME = "OceanTD_SandDollarRow"
LeftHudLayout.VIEWPORT_SCALE_NAME = "_OceanTD_LeftHudScale"
LeftHudLayout.PUNCH_SCALE_NAME = "_OceanTD_DCountPunch"
LeftHudLayout.BASE_TEXT_ATTR = "_OceanTD_BaseTextSize"
LeftHudLayout.BASE_SCALE_ATTR = "OceanTD_DCountBaseScale"

function LeftHudLayout.findDLabel(left: Instance): GuiObject?
	local row = left:FindFirstChild(LeftHudLayout.ROW_NAME)
	if row then
		local inRow = row:FindFirstChild(LeftHudLayout.LABEL_NAME)
		if inRow and inRow:IsA("GuiObject") then
			return inRow
		end
	end
	local direct = left:FindFirstChild(LeftHudLayout.LABEL_NAME)
	if direct and direct:IsA("GuiObject") then
		return direct
	end
	local dPad = left:FindFirstChild("dPad")
	if dPad then
		local under = dPad:FindFirstChild(LeftHudLayout.LABEL_NAME)
		if under and under:IsA("GuiObject") then
			return under
		end
		for _, d in ipairs(dPad:GetChildren()) do
			if d:IsA("GuiObject") and d.Name ~= LeftHudLayout.COUNT_NAME then
				if d.Name == LeftHudLayout.LABEL_NAME then
					return d
				end
				if d:IsA("TextLabel") and d.Text == LeftHudLayout.LABEL_NAME then
					return d
				end
			end
		end
	end
	return nil
end

function LeftHudLayout.findDCount(left: Instance): GuiObject?
	local direct = left:FindFirstChild(LeftHudLayout.COUNT_NAME)
	if direct and direct:IsA("GuiObject") then
		return direct
	end
	local dPad = left:FindFirstChild("dPad")
	if dPad then
		local under = dPad:FindFirstChild(LeftHudLayout.COUNT_NAME)
		if under and under:IsA("GuiObject") then
			return under
		end
	end
	local row = left:FindFirstChild(LeftHudLayout.ROW_NAME)
	if row then
		local under = row:FindFirstChild(LeftHudLayout.COUNT_NAME)
		if under and under:IsA("GuiObject") then
			return under
		end
	end
	return nil
end

function LeftHudLayout.isSandDollarChrome(gui: Instance): boolean
	local n = gui.Name
	return n == LeftHudLayout.COUNT_NAME
		or n == LeftHudLayout.LABEL_NAME
		or n == LeftHudLayout.ROW_NAME
end

function LeftHudLayout.isDCount(gui: Instance): boolean
	return gui.Name == LeftHudLayout.COUNT_NAME
end

-- Prevent Character respawn from wiping runtime wiring (SkillsHit, cam UIScales, etc.).
function LeftHudLayout.hardenScreenGui(gui: Instance?)
	if gui and gui:IsA("ScreenGui") then
		(gui :: ScreenGui).ResetOnSpawn = false
	end
end

-- Call `onBind` for the current MobileLeftUI and again whenever it is replaced.
function LeftHudLayout.watchMobileLeftUi(playerGui: PlayerGui, onBind: (Instance) -> ())
	local bound: Instance? = nil
	local function tryBind(left: Instance?)
		local gui = left or playerGui:FindFirstChild("MobileLeftUI")
		if not gui then
			return
		end
		LeftHudLayout.hardenScreenGui(gui)
		if gui == bound then
			return
		end
		bound = gui
		onBind(gui)
	end
	tryBind(playerGui:FindFirstChild("MobileLeftUI"))
	playerGui.ChildAdded:Connect(function(ch)
		if ch.Name == "MobileLeftUI" then
			task.defer(function()
				tryBind(ch)
			end)
		end
	end)
end

return LeftHudLayout
