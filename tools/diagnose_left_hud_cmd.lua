-- Studio Command Bar paste (Play must be running). Prints left HUD status once.
local Players=game:GetService("Players")
local p=Players.LocalPlayer or Players:GetPlayers()[1]
if not p then warn("[LeftHudDiag] No player — start Play first") return end
local pg=p:FindFirstChild("PlayerGui")
if not pg then warn("[LeftHudDiag] No PlayerGui") return end
local function flag(c,m) print(c and ("  !!  "..m) or ("  ok  "..m)) end
local function gui(label,g)
	if not (g and g:IsA("GuiObject")) then print(string.format("  %-12s MISSING",label)) return end
	local u=g:FindFirstChildOfClass("UIScale")
	local sc=u and string.format("%.3f",u.Scale) or "—"
	print(string.format("  %-12s Vis=%s Active=%s Z=%d Scale=%s Abs=%.0fx%.0f Pos=%s",
		label,tostring(g.Visible),tostring(g.Active),g.ZIndex,sc,g.AbsoluteSize.X,g.AbsoluteSize.Y,tostring(g.Position)))
end
print("========== LEFT HUD DIAG "..os.date("%H:%M:%S").." ==========")
print("Player:",p.Name)
print("-- attrs --")
for _,n in ipairs({"OceanTD_SkillsBubblesOpen","OceanTD_ForceCloseSkills","OceanTD_ForceOpenSkills","OceanTD_SkillsUiRestore"}) do
	print(" ",n,"=",pg:GetAttribute(n))
end
flag(pg:GetAttribute("OceanTD_SkillsBubblesOpen")==true,"SkillsBubblesOpen=true (cam suppressed)")
local left=pg:FindFirstChild("MobileLeftUI")
if not left then print("MobileLeftUI MISSING") print("========== END ==========") return end
if left:IsA("ScreenGui") then print("MobileLeftUI.Enabled =",left.Enabled) flag(not left.Enabled,"MobileLeftUI.Enabled=false") end
local dPad=left:FindFirstChild("dPad")
if not dPad then print("dPad MISSING") print("========== END ==========") return end
print("-- dPad --")
for _,n in ipairs({"FreeCam","FishCam","OffCam","Skills","Settings","dPadIcon"}) do gui(n,dPad:FindFirstChild(n)) end
local free,fish,off=dPad:FindFirstChild("FreeCam"),dPad:FindFirstChild("FishCam"),dPad:FindFirstChild("OffCam")
print("-- carousel --")
if free and fish and off and free:IsA("GuiObject") and fish:IsA("GuiObject") and off:IsA("GuiObject") then
	local function sc(g) local u=g:FindFirstChildOfClass("UIScale") return u and u.Scale or 1 end
	local big=0
	for _,g in ipairs({free,fish,off}) do if g.Visible and sc(g)>0.2 then big+=1 end end
	print(string.format("  scales Free=%.3f Fish=%.3f Off=%.3f",sc(free),sc(fish),sc(off)))
	print("  samePos =",free.Position==fish.Position and fish.Position==off.Position)
	flag(big>=3,"All 3 cam icons big+Visible — collapse stuck")
	flag(big>=2 and not (free.Position==fish.Position),"Still in triangle layout")
end
local skills=dPad:FindFirstChild("Skills")
if skills then
	gui("SkillsHit",skills:FindFirstChild("_OceanTD_SkillsHit"))
	flag(skills:IsA("GuiObject") and not skills.Visible,"Skills Visible=false")
end
local ps=p:FindFirstChild("PlayerScripts")
local ocean=ps and ps:FindFirstChild("OceanTD")
print("-- scripts --")
if ocean then
	for _,ch in ipairs(ocean:GetChildren()) do
		if ch:IsA("LocalScript") and (ch.Name:find("FreeCam") or ch.Name:find("MobileSkills") or ch.Name:find("InventoryUI") or ch.Name:find("LeftHud") or ch.Name:find("Settings")) then
			print(" ",ch.Name,"Disabled=",ch.Disabled) flag(ch.Disabled,"Disabled: "..ch.Name)
		end
	end
else print("  PlayerScripts.OceanTD missing") end
print("========== END LEFT HUD DIAG ==========")
