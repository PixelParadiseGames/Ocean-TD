--[[
	LEFT HUD DIAGNOSTIC — run while the bug is live (Play Solo / live client).

	Studio (easiest while stuck):
	1. Keep Play running with the broken HUD.
	2. Open Command Bar (View → Command Bar).
	3. Paste EVERYTHING below the dashed line into the command bar and press Enter.
	   (This injects a one-shot LocalScript so it runs on the CLIENT.)

	Or: Developer Console (F9) → Client tab → paste the INNER function body only
	(everything inside run()).

	Look for lines tagged  !!  — those are the likely failure signals.
]]

-- ===================== PASTE FROM HERE =====================
do
	local Players = game:GetService("Players")
	local GuiService = game:GetService("GuiService")
	local StarterPlayer = game:GetService("StarterPlayer")

	local src = [==[
local Players = game:GetService("Players")
local GuiService = game:GetService("GuiService")
local UserInputService = game:GetService("UserInputService")
local ScriptContext = game:GetService("ScriptContext")

local player = Players.LocalPlayer
local pg = player and player:WaitForChild("PlayerGui", 5)
if not pg then
	warn("[LeftHudDiag] No PlayerGui")
	return
end

local function line(msg: string)
	print(msg)
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
		"  %-14s  Vis=%s Active=%s Interact=%s Z=%d Scale=%s Abs=%.0fx%.0f Pos=%s Parent=%s",
		label,
		tostring(g.Visible),
		tostring(g.Active),
		interact,
		g.ZIndex,
		sc,
		abs.X,
		abs.Y,
		tostring(g.Position),
		g.Parent and g.Parent.Name or "?"
	))
end

print("========== LEFT HUD DIAG " .. os.date("%H:%M:%S") .. " ==========")
print("Player:", player.Name, "UserId:", player.UserId)

-- PlayerGui attributes that gate FreeCam / Skills
local attrs = {
	"OceanTD_SkillsBubblesOpen",
	"OceanTD_ForceCloseSkills",
	"OceanTD_ForceOpenSkills",
	"OceanTD_ForceOpenSkillId",
	"OceanTD_SkillsUiRestore",
}
print("-- PlayerGui attrs --")
for _, name in ipairs(attrs) do
	local v = pg:GetAttribute(name)
	print("  ", name, "=", v)
end
flag(pg:GetAttribute("OceanTD_SkillsBubblesOpen") == true, "SkillsBubblesOpen=true (FreeCam icons suppressed; Skills owns left HUD)")

-- Inventory / modal
print("-- GuiService / input --")
print("  SelectedObject =", GuiService.SelectedObject and GuiService.SelectedObject:GetFullName() or "nil")
print("  MenuIsOpen =", GuiService.MenuIsOpen)
print("  TouchEnabled =", UserInputService.TouchEnabled, "GamepadEnabled =", UserInputService.GamepadEnabled)

-- Scripts alive?
print("-- Client scripts (Disabled?) --")
local ps = player:FindFirstChild("PlayerScripts")
local ocean = ps and ps:FindFirstChild("OceanTD")
if ocean then
	for _, name in ipairs({ "FreeCam", "MobileSkillsA", "InventoryUI", "LeftHudViewport", "SettingsBootstrap", "SandDollarHud" }) do
		local s = ocean:FindFirstChild(name) or ocean:FindFirstChild(name .. ".client")
		-- Rojo names often end with .client.lua → instance name without .lua
		if not s then
			for _, ch in ipairs(ocean:GetChildren()) do
				if ch.Name == name or ch.Name:match("^" .. name) then
					s = ch
					break
				end
			end
		end
		if s and (s:IsA("LocalScript") or s:IsA("Script")) then
			print(string.format("  %-22s Disabled=%s Class=%s", s.Name, tostring(s.Disabled), s.ClassName))
			flag(s.Disabled == true, s.Name .. " is Disabled")
		else
			print(string.format("  %-22s NOT FOUND under PlayerScripts.OceanTD", name))
		end
	end
else
	print("  PlayerScripts.OceanTD missing")
end

-- Try InventoryState via require
print("-- InventoryState --")
local invOpen = "?"
pcall(function()
	local rs = game:GetService("ReplicatedStorage")
	local oceanRoot = rs:FindFirstChild("OceanTD")
	-- InventoryState lives under PlayerScripts, not RS
	local invMod = ocean and ocean:FindFirstChild("InventoryState")
	if invMod then
		local inv = require(invMod)
		invOpen = tostring(inv.isOpen())
		print("  isOpen() =", invOpen)
		flag(inv.isOpen() == true, "Backpack InventoryState.isOpen() — left HUD chrome may stay hidden")
	else
		print("  InventoryState module not found")
	end
end)

local left = pg:FindFirstChild("MobileLeftUI")
print("-- MobileLeftUI --")
if not left then
	print("  MISSING MobileLeftUI")
	print("========== END ==========")
	return
end
print("  Enabled =", left:IsA("ScreenGui") and (left :: ScreenGui).Enabled, "Name =", left.Name)
if left:IsA("ScreenGui") then
	flag((left :: ScreenGui).Enabled ~= true, "MobileLeftUI.Enabled=false — entire left HUD dead")
end

local dPad = left:FindFirstChild("dPad")
print("-- dPad children --")
if not dPad then
	print("  MISSING dPad")
	print("========== END ==========")
	return
end

local names = { "FreeCam", "FishCam", "OffCam", "Skills", "Settings", "dPadIcon", "CloseBTN" }
for _, n in ipairs(names) do
	guiLine(n, dPad:FindFirstChild(n))
end

-- Collapse check: tucked icons should share active position + Scale ≈ 0.08
local free = dPad:FindFirstChild("FreeCam")
local fish = dPad:FindFirstChild("FishCam")
local off = dPad:FindFirstChild("OffCam")
print("-- Cam carousel layout --")
if free and fish and off and free:IsA("GuiObject") and fish:IsA("GuiObject") and off:IsA("GuiObject") then
	local function sc(g: GuiObject): number
		local u = g:FindFirstChildOfClass("UIScale")
		return if u then u.Scale else 1
	end
	local sf, sfi, so = sc(free), sc(fish), sc(off)
	local visCount = 0
	for _, g in ipairs({ free, fish, off }) do
		if g.Visible and sc(g) > 0.2 then
			visCount += 1
		end
	end
	print(string.format("  scales Free=%.3f Fish=%.3f Off=%.3f", sf, sfi, so))
	print(string.format("  positions Free=%s", tostring(free.Position)))
	print(string.format("             Fish=%s", tostring(fish.Position)))
	print(string.format("             Off =%s", tostring(off.Position)))
	flag(visCount >= 3, "All 3 cam icons Visible with Scale>0.2 — collapse stuck (should tuck 2 at ~0.08)")
	flag(visCount == 0 and pg:GetAttribute("OceanTD_SkillsBubblesOpen") ~= true, "All cam icons hidden but SkillsBubblesOpen is not true")
	local samePos = free.Position == fish.Position and fish.Position == off.Position
	print("  samePosition =", samePos, "(collapsed stack should share Position)")
	flag(not samePos and visCount >= 2, "Cam icons still in triangle layout (not collapsed)")
end

-- Skills hit overlay
local skills = dPad:FindFirstChild("Skills")
if skills then
	local hit = skills:FindFirstChild("_OceanTD_SkillsHit")
	guiLine("SkillsHit", hit)
	flag(skills:IsA("GuiObject") and not (skills :: GuiObject).Visible, "Skills button Visible=false")
	flag(hit == nil, "Skills missing _OceanTD_SkillsHit overlay (clicks may not bind)")
end

-- Full-screen blockers over left HUD
print("-- Possible full-screen blockers (Active GuiObjects covering left) --")
local leftAbs = if left:IsA("GuiObject") then (left :: GuiObject).AbsolutePosition else Vector2.zero
local blockers = 0
for _, d in ipairs(pg:GetDescendants()) do
	if d:IsA("GuiObject") and d.Visible and d.Active and d.AbsoluteSize.X >= 200 and d.AbsoluteSize.Y >= 200 then
		local p = d.AbsolutePosition
		local s = d.AbsoluteSize
		-- Covers roughly bottom-left where dPad lives
		if p.X < 120 and p.Y + s.Y > 200 and d:IsDescendantOf(left) == false then
			-- skip known HUD roots
			local n = d.Name
			if n ~= "MobileLeftUI" and not string.find(n, "RightHUD", 1, true) then
				blockers += 1
				if blockers <= 12 then
					print(string.format("  %s AbsPos=(%.0f,%.0f) AbsSize=%.0fx%.0f Z=%d", d:GetFullName(), p.X, p.Y, s.X, s.Y, d.ZIndex))
				end
			end
		end
	end
end
if blockers == 0 then
	print("  (none obvious)")
else
	flag(true, string.format("%d large Active GUIs may be eating left-HUD clicks", blockers))
end

-- Skills bubble layer
print("-- Skills bubble layer --")
local bubbleLayer = pg:FindFirstChild("OceanTD_SkillsBubbleLayer")
	or pg:FindFirstChild("OceanTD_SkillsBubbles")
	or pg:FindFirstChild("_OceanTD_SkillsBubbleLayer")
if not bubbleLayer then
	for _, ch in ipairs(pg:GetChildren()) do
		if string.find(string.lower(ch.Name), "skill", 1, true) and string.find(string.lower(ch.Name), "bubble", 1, true) then
			bubbleLayer = ch
			break
		end
	end
end
if bubbleLayer and bubbleLayer:IsA("GuiObject") then
	guiLine("BubbleLayer", bubbleLayer)
else
	print("  (no bubble layer ScreenGui found by name — ok if skills closed)")
end

print("-- Recent ScriptContext errors (subscribe 2s) --")
local errConn
errConn = ScriptContext.Error:Connect(function(message, stack, script)
	print("  !! SCRIPT ERROR:", message)
	print("     script:", script and script:GetFullName() or "?")
	print("     stack:", stack)
end)
task.delay(2, function()
	if errConn then
		errConn:Disconnect()
	end
	print("========== END LEFT HUD DIAG ==========")
	print("Paste the full Output dump back into chat.")
end)
]==]

	local plr = Players.LocalPlayer
	if plr then
		-- Already on client (e.g. F9 Client console)
		local fn, err = loadstring(src)
		if not fn then
			warn("[LeftHudDiag] loadstring failed:", err)
			return
		end
		fn()
		return
	end

	-- Command Bar is usually server — inject a one-shot LocalScript
	plr = Players:GetPlayers()[1]
	if not plr then
		warn("[LeftHudDiag] No players — start Play first")
		return
	end
	local ps = plr:FindFirstChild("PlayerScripts")
	if not ps then
		warn("[LeftHudDiag] PlayerScripts missing")
		return
	end
	local existing = ps:FindFirstChild("_OceanTD_LeftHudDiag")
	if existing then
		existing:Destroy()
	end
	local ls = Instance.new("LocalScript")
	ls.Name = "_OceanTD_LeftHudDiag"
	ls.Source = src
	ls.Parent = ps
	print("[LeftHudDiag] Injected LocalScript into", plr.Name, "— check CLIENT Output")
end
-- ===================== PASTE UNTIL HERE =====================
