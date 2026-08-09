--!strict
--[[
	Toggle MobileSkillsB from the left dPad Skills button.
	StarterGui.MobileLeftUI.dPad.Skills → show/hide StarterGui.MobileSkillsB
]]

local Players = game:GetService("Players")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local CLOSE_NAMES = {
	Close = true,
	close = true,
	X = true,
	Exit = true,
	Hide = true,
	Back = true,
	Dismiss = true,
}

local function ancestorScreenGui(inst: Instance): ScreenGui?
	if inst:IsA("ScreenGui") then
		return inst
	end
	return inst:FindFirstAncestorOfClass("ScreenGui")
end

-- Full-size hit target on Skills (don't reuse nested Studio buttons — they may be tiny/inactive).
local function ensureHitOverlay(host: GuiObject): GuiButton
	local existing = host:FindFirstChild("_OceanTD_SkillsHit")
	if existing and existing:IsA("GuiButton") then
		existing:Destroy()
	end
	local made = Instance.new("TextButton")
	made.Name = "_OceanTD_SkillsHit"
	made.Text = ""
	made.BackgroundTransparency = 1
	made.BorderSizePixel = 0
	made.Size = UDim2.fromScale(1, 1)
	made.Position = UDim2.fromScale(0, 0)
	made.ZIndex = host.ZIndex + 20
	made.Active = true
	made.AutoButtonColor = false
	made.Parent = host
	return made
end

task.spawn(function()
	local left = playerGui:WaitForChild("MobileLeftUI", 60)
	if not left then
		warn("[Skills] PlayerGui.MobileLeftUI missing")
		return
	end
	local dPad = left:WaitForChild("dPad", 30)
	if not dPad then
		warn("[Skills] MobileLeftUI.dPad missing")
		return
	end
	local skillsBtn = dPad:WaitForChild("Skills", 30)
	if not skillsBtn or not skillsBtn:IsA("GuiObject") then
		warn("[Skills] MobileLeftUI.dPad.Skills missing")
		return
	end

	local panel = playerGui:WaitForChild("MobileSkillsB", 60)
	if not panel or not (panel:IsA("ScreenGui") or panel:IsA("GuiObject")) then
		warn("[Skills] PlayerGui.MobileSkillsB missing")
		return
	end

	local leftGui = ancestorScreenGui(left)
	local panelGui: ScreenGui? = if panel:IsA("ScreenGui") then panel else ancestorScreenGui(panel)
	local leftOrderBase = if leftGui then leftGui.DisplayOrder else 0

	local open = false
	local lastToggleAt = 0
	local TOGGLE_DEBOUNCE = 0.15

	local function applyOpen(want: boolean)
		open = want
		if panel:IsA("ScreenGui") then
			(panel :: ScreenGui).Enabled = want
		else
			(panel :: GuiObject).Visible = want
		end
		if leftGui and panelGui then
			if want then
				leftGui.DisplayOrder = math.max(leftOrderBase, panelGui.DisplayOrder + 10)
			else
				leftGui.DisplayOrder = leftOrderBase
			end
		end
	end

	local function toggle()
		local now = os.clock()
		if now - lastToggleAt < TOGGLE_DEBOUNCE then
			return
		end
		lastToggleAt = now
		applyOpen(not open)
		print("[Skills] toggle →", open)
	end

	local function closeOnly()
		local now = os.clock()
		if now - lastToggleAt < TOGGLE_DEBOUNCE then
			return
		end
		lastToggleAt = now
		applyOpen(false)
	end

	applyOpen(false)

	local hit = ensureHitOverlay(skillsBtn)
	hit.Activated:Connect(toggle)

	local function wireClose(btn: GuiButton)
		if btn:GetAttribute("_OceanTD_SkillsCloseBound") == true then
			return
		end
		btn:SetAttribute("_OceanTD_SkillsCloseBound", true)
		btn.Active = true
		btn.Activated:Connect(closeOnly)
	end

	for _, desc in ipairs(panel:GetDescendants()) do
		if desc:IsA("GuiButton") and CLOSE_NAMES[desc.Name] then
			wireClose(desc)
		end
	end
	panel.DescendantAdded:Connect(function(desc)
		if desc:IsA("GuiButton") and CLOSE_NAMES[desc.Name] then
			wireClose(desc)
		end
	end)

	print("[Skills] Ready — hit overlay on dPad.Skills")
end)
