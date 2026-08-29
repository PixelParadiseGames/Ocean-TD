--!strict
--[[
	One-shot left HUD diagnostic. Run while the bug is LIVE (do not stop Play).

	HOW (Studio, mid-session):
	1. Explorer → Players → [YourName] → PlayerScripts
	2. + → LocalScript  (name it LeftHudDiag)
	3. Paste THIS ENTIRE FILE into the LocalScript Source
	4. It runs once and prints to the CLIENT Output window
	5. Copy the dump starting at "LEFT HUD DIAG" and send it

	Signals marked "!!" are the important ones.
]]

local Players = game:GetService("Players")
local GuiService = game:GetService("GuiService")
local UserInputService = game:GetService("UserInputService")
local ScriptContext = game:GetService("ScriptContext")

local player = Players.LocalPlayer
local pg = player:WaitForChild("PlayerGui", 5)
if not pg then
	warn("[LeftHudDiag] No PlayerGui")
	return
end

local function flag(cond: boolean, msg: string)
	if cond then
		print("  !!  " .. msg)
	else
		print("  ok  " .. msg)
	end
end

local function guiLine(label: string, g: Instance?)
	if not g or not g:IsA("GuiObject") then
		print(string.format("  %-14s  MISSING", label))
		return
	end
	local scale = g:FindFirstChildOfClass("UIScale")
	local sc = if scale then string.format("%.3f", scale.Scale) else "—"
	local interact = "?"
	pcall(function()
		interact = tostring((g :: any).Interactable)
	end)
	local abs = g.AbsoluteSize
	print(string.format(
		"  %-14s  Vis=%s Active=%s Interact=%s Z=%d Scale=%s Abs=%.0fx%.0f Pos=%s",
		label,
		tostring(g.Visible),
		tostring(g.Active),
		interact,
		g.ZIndex,
		sc,
		abs.X,
		abs.Y,
		tostring(g.Position)
	))
end

print("========== LEFT HUD DIAG " .. os.date("%H:%M:%S") .. " ==========")
print("Player:", player.Name)

local attrs = {
	"OceanTD_SkillsBubblesOpen",
	"OceanTD_ForceCloseSkills",
	"OceanTD_ForceOpenSkills",
	"OceanTD_ForceOpenSkillId",
	"OceanTD_SkillsUiRestore",
}
print("-- PlayerGui attrs --")
for _, name in ipairs(attrs) do
	print("  ", name, "=", pg:GetAttribute(name))
end
flag(pg:GetAttribute("OceanTD_SkillsBubblesOpen") == true, "SkillsBubblesOpen=true (cam icons suppressed)")

print("-- GuiService --")
print("  SelectedObject =", GuiService.SelectedObject and GuiService.SelectedObject:GetFullName() or "nil")
print("  MenuIsOpen =", GuiService.MenuIsOpen)
print("  LastInputType =", tostring(UserInputService:GetLastInputType()))

print("-- Client scripts --")
local ps = player:FindFirstChild("PlayerScripts")
local ocean = ps and ps:FindFirstChild("OceanTD")
if ocean then
	for _, ch in ipairs(ocean:GetChildren()) do
		if ch:IsA("LocalScript") then
			local n = ch.Name
			if string.find(n, "FreeCam", 1, true)
				or string.find(n, "MobileSkills", 1, true)
				or string.find(n, "InventoryUI", 1, true)
				or string.find(n, "LeftHud", 1, true)
				or string.find(n, "Settings", 1, true)
			then
				print(string.format("  %-28s Disabled=%s", n, tostring(ch.Disabled)))
				flag(ch.Disabled == true, n .. " is Disabled")
			end
		end
	end
else
	print("  PlayerScripts.OceanTD missing")
end

print("-- InventoryState --")
pcall(function()
	local invMod = ocean and ocean:FindFirstChild("InventoryState")
	if invMod then
		local inv = require(invMod)
		print("  isOpen() =", inv.isOpen())
		flag(inv.isOpen() == true, "Backpack still open in InventoryState")
	end
end)

local left = pg:FindFirstChild("MobileLeftUI")
print("-- MobileLeftUI --")
if not left then
	print("  MISSING")
	print("========== END ==========")
	return
end
if left:IsA("ScreenGui") then
	print("  Enabled =", (left :: ScreenGui).Enabled)
	flag((left :: ScreenGui).Enabled ~= true, "MobileLeftUI.Enabled=false")
end

local dPad = left:FindFirstChild("dPad")
print("-- dPad --")
if not dPad then
	print("  MISSING dPad")
	print("========== END ==========")
	return
end

for _, n in ipairs({ "FreeCam", "FishCam", "OffCam", "Skills", "Settings", "dPadIcon" }) do
	guiLine(n, dPad:FindFirstChild(n))
end

local free = dPad:FindFirstChild("FreeCam")
local fish = dPad:FindFirstChild("FishCam")
local off = dPad:FindFirstChild("OffCam")
print("-- Cam carousel --")
if free and fish and off and free:IsA("GuiObject") and fish:IsA("GuiObject") and off:IsA("GuiObject") then
	local function sc(g: GuiObject): number
		local u = g:FindFirstChildOfClass("UIScale")
		return if u then u.Scale else 1
	end
	local sf, sfi, so = sc(free), sc(fish), sc(off)
	local bigVisible = 0
	for _, g in ipairs({ free :: GuiObject, fish :: GuiObject, off :: GuiObject }) do
		if g.Visible and sc(g) > 0.2 then
			bigVisible += 1
		end
	end
	print(string.format("  scales Free=%.3f Fish=%.3f Off=%.3f", sf, sfi, so))
	print("  Free Pos", free.Position)
	print("  Fish Pos", fish.Position)
	print("  Off  Pos", off.Position)
	local samePos = free.Position == fish.Position and fish.Position == off.Position
	print("  samePosition =", samePos)
	flag(bigVisible >= 3, "All 3 cam icons big+Visible — collapse stuck")
	flag(not samePos and bigVisible >= 2, "Still in triangle (not collapsed stack)")
	flag(bigVisible == 0 and pg:GetAttribute("OceanTD_SkillsBubblesOpen") ~= true, "Cam icons all tucked/hidden but SkillsBubblesOpen is false")
end

local skills = dPad:FindFirstChild("Skills")
if skills then
	guiLine("SkillsHit", skills:FindFirstChild("_OceanTD_SkillsHit"))
	flag(skills:IsA("GuiObject") and not (skills :: GuiObject).Visible, "Skills Visible=false")
end

print("-- Large Active GUIs that may block left clicks --")
local blockers = 0
for _, d in ipairs(pg:GetDescendants()) do
	if d:IsA("GuiObject") and d.Visible and d.Active then
		local s = d.AbsoluteSize
		local p = d.AbsolutePosition
		if s.X >= 250 and s.Y >= 250 and p.X < 150 and not d:IsDescendantOf(left) then
			local n = d.Name
			if not string.find(n, "RightHUD", 1, true) and n ~= "MainHUD" then
				blockers += 1
				if blockers <= 10 then
					print(string.format("  %s  Abs=(%.0f,%.0f) Size=%.0fx%.0f Z=%d", d:GetFullName(), p.X, p.Y, s.X, s.Y, d.ZIndex))
				end
			end
		end
	end
end
if blockers == 0 then
	print("  (none)")
else
	flag(true, blockers .. " possible click blockers")
end

print("-- Listening 2s for ScriptContext.Error --")
local conn = ScriptContext.Error:Connect(function(message, stack, scriptInst)
	print("  !! SCRIPT ERROR:", message)
	print("     ", scriptInst and scriptInst:GetFullName() or "?")
	print("     ", stack)
end)
task.delay(2, function()
	conn:Disconnect()
	print("========== END LEFT HUD DIAG ==========")
	-- Remove self so re-paste is clean next time
	if script.Parent and script.Name == "LeftHudDiag" then
		script:Destroy()
	end
end)
