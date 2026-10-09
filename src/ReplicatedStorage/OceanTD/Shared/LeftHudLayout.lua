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

local LABEL_ALIASES: { [string]: boolean } = {
	[LeftHudLayout.LABEL_NAME] = true,
	["D"] = true,
	["$DLabel"] = true,
	["DLabel"] = true,
	["SandDollar"] = true,
	["SandDollarLabel"] = true,
	["Dollar"] = true,
	["$DIcon"] = true,
	["DIcon"] = true,
}

local function looksLikeDLabel(gui: GuiObject): boolean
	if LABEL_ALIASES[gui.Name] then
		return true
	end
	if gui:IsA("TextLabel") or gui:IsA("TextButton") then
		local t = string.gsub(gui.Text, "%s+", "")
		return t == "$D" or t == "D$"
	end
	return false
end

function LeftHudLayout.findDLabel(left: Instance): GuiObject?
	local row = left:FindFirstChild(LeftHudLayout.ROW_NAME)
	if row then
		for _, ch in ipairs(row:GetChildren()) do
			if ch:IsA("GuiObject") and ch.Name ~= LeftHudLayout.COUNT_NAME and looksLikeDLabel(ch) then
				return ch
			end
		end
	end
	local direct = left:FindFirstChild(LeftHudLayout.LABEL_NAME)
	if direct and direct:IsA("GuiObject") then
		return direct
	end
	local dPad = left:FindFirstChild("dPad")
	local searchRoots: { Instance } = { left }
	if dPad then
		table.insert(searchRoots, dPad)
	end
	for _, root in ipairs(searchRoots) do
		local under = root:FindFirstChild(LeftHudLayout.LABEL_NAME, true)
		if under and under:IsA("GuiObject") then
			-- Prefer a sibling label beside $DCount, not a nested duplicate inside it.
			local count = LeftHudLayout.findDCount(left)
			if not count or not under:IsDescendantOf(count) then
				return under
			end
		end
	end
	-- Sibling of $DCount (Studio often parks the glyph next to the count).
	local count = LeftHudLayout.findDCount(left)
	if count and count.Parent then
		for _, ch in ipairs(count.Parent:GetChildren()) do
			if ch:IsA("GuiObject") and ch ~= count and looksLikeDLabel(ch) then
				return ch
			end
		end
	end
	if dPad then
		local nested: GuiObject? = nil
		for _, d in ipairs(dPad:GetDescendants()) do
			if d:IsA("GuiObject") and d.Name ~= LeftHudLayout.COUNT_NAME and looksLikeDLabel(d) then
				local countNow = count or LeftHudLayout.findDCount(left)
				if not countNow or not d:IsDescendantOf(countNow) then
					return d
				end
				nested = d
			end
		end
		-- Last resort: "$D" authored inside $DCount (keep visible; SandDollarHud won't hide it alone).
		if nested then
			return nested
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
	if n == LeftHudLayout.COUNT_NAME or n == LeftHudLayout.LABEL_NAME or n == LeftHudLayout.ROW_NAME then
		return true
	end
	if LABEL_ALIASES[n] then
		return true
	end
	if gui:IsA("GuiObject") and looksLikeDLabel(gui) then
		return true
	end
	return false
end

-- Keep $D glyph + count visible (skills / power-up HUD hide paths).
function LeftHudLayout.revealSandDollarChrome(left: Instance)
	local dCount = LeftHudLayout.findDCount(left)
	local dLabel = LeftHudLayout.findDLabel(left)
	local row = left:FindFirstChild(LeftHudLayout.ROW_NAME)
	local targets: { GuiObject } = {}
	if dCount then
		table.insert(targets, dCount)
	end
	if dLabel then
		table.insert(targets, dLabel)
	end
	if row and row:IsA("GuiObject") then
		table.insert(targets, row)
	end
	for _, gui in ipairs(targets) do
		gui.Visible = true
		local p = gui.Parent
		while p and p ~= left and p:IsA("GuiObject") do
			-- Don't force-show the whole dPad icon strip — only wrappers for the cash row.
			if p.Name == "dPad" then
				break
			end
			p.Visible = true
			p = p.Parent
		end
	end
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
