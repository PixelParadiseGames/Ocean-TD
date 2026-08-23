--!strict
--[[
	Studio contract: PlayerGui.MobileLeftUI.dPad.$DCount shows persistent $D.
	Server attribute OceanTD_SandDollars is the only source of truth.
	Tap / click opens Robux pack prompt when product IDs are configured.
]]

local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local Constants = require(oceanRoot:WaitForChild("Shared"):WaitForChild("Constants"))
local LeftHudLayout = require(oceanRoot:WaitForChild("Shared"):WaitForChild("LeftHudLayout"))
local SandDollarProducts = require(oceanRoot:WaitForChild("Shared"):WaitForChild("SandDollarProducts"))
local UiTheme = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiTheme"))
local UiHaptics = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiHaptics"))

local ATTR = Constants.SAND_DOLLARS_ATTR
local LABEL_NAME = Constants.SAND_DOLLARS_LABEL_NAME

local host: GuiObject? = nil
local textTarget: TextLabel | TextButton | nil = nil
local shopGui: ScreenGui? = nil
local lastShown = 0
local discoverConn: RBXScriptConnection? = nil

local function formatCount(n: number): string
	local v = math.max(0, math.floor(n))
	local s = tostring(v)
	local out = s
	while true do
		local nextS, nRepl = string.gsub(out, "^(-?%d+)(%d%d%d)", "%1,%2")
		out = nextS
		if nRepl == 0 then
			break
		end
	end
	return out
end

local function readBalance(): number
	local raw = player:GetAttribute(ATTR)
	local n = tonumber(raw)
	if typeof(n) ~= "number" or n ~= n or n < 0 then
		return 0
	end
	return math.floor(n)
end

local function flashGain(delta: number)
	if not host or delta <= 0 then
		return
	end
	local lbl = Instance.new("TextLabel")
	lbl.Name = "_OceanTD_DollarGain"
	lbl.BackgroundTransparency = 1
	lbl.AnchorPoint = Vector2.new(0.5, 1)
	lbl.Position = UDim2.fromScale(0.5, 0)
	lbl.Size = UDim2.fromOffset(80, 22)
	lbl.Font = UiTheme.Font
	lbl.TextSize = 18
	lbl.TextColor3 = Color3.fromRGB(80, 255, 120)
	lbl.TextStrokeTransparency = 0.4
	lbl.Text = "+" .. formatCount(delta)
	lbl.ZIndex = host.ZIndex + 8
	lbl.Parent = host
	TweenService:Create(lbl, TweenInfo.new(0.7, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Position = UDim2.new(0.5, 0, 0, -18),
		TextTransparency = 1,
		TextStrokeTransparency = 1,
	}):Play()
	task.delay(0.75, function()
		lbl:Destroy()
	end)
end

local function applyText(amount: number)
	if not textTarget then
		return
	end
	textTarget.Text = formatCount(amount)
	if amount > lastShown then
		flashGain(amount - lastShown)
	end
	lastShown = amount
end

local function hideInnerDLabel(countHost: GuiObject)
	for _, d in ipairs(countHost:GetDescendants()) do
		if (d:IsA("TextLabel") or d:IsA("TextButton")) and d.Name == LABEL_NAME then
			d.Visible = false
		end
	end
end

local function findTextTarget(root: GuiObject): TextLabel | TextButton | nil
	local named = root:FindFirstChild("Count")
		or root:FindFirstChild("Amount")
		or root:FindFirstChild("Label")
		or root:FindFirstChild("Text")
	if named and (named:IsA("TextLabel") or named:IsA("TextButton")) then
		return named
	end
	if root:IsA("TextLabel") or root:IsA("TextButton") then
		return root
	end
	for _, d in ipairs(root:GetDescendants()) do
		if (d:IsA("TextLabel") or d:IsA("TextButton")) and d.Name ~= LABEL_NAME then
			return d
		end
	end
	return nil
end

local function closeShop()
	if shopGui then
		shopGui:Destroy()
		shopGui = nil
	end
end

local function promptPack(productId: number)
	if productId <= 0 then
		return
	end
	UiHaptics.pulseShort()
	local ok, err = pcall(function()
		MarketplaceService:PromptProductPurchase(player, productId)
	end)
	if not ok then
		warn("[ECONOMY] PromptProductPurchase failed", productId, err)
	end
end

local function openShop()
	if shopGui then
		closeShop()
		return
	end
	local packs = SandDollarProducts.configured()
	if #packs == 0 then
		print("[ECONOMY] No Robux $D packs configured — set productId in SandDollarProducts.lua")
		return
	end
	UiHaptics.pulseShort()

	local sg = Instance.new("ScreenGui")
	sg.Name = "OceanTD_SandDollarShop"
	sg.ResetOnSpawn = false
	sg.IgnoreGuiInset = true
	sg.DisplayOrder = 80
	sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	sg.Parent = playerGui
	shopGui = sg

	local dim = Instance.new("TextButton")
	dim.Name = "Dim"
	dim.Text = ""
	dim.AutoButtonColor = false
	dim.BackgroundColor3 = Color3.new(0, 0, 0)
	dim.BackgroundTransparency = 0.45
	dim.Size = UDim2.fromScale(1, 1)
	dim.ZIndex = 1
	dim.Parent = sg
	dim.Activated:Connect(closeShop)

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromOffset(320, 72 + #packs * 56)
	panel.BackgroundColor3 = Color3.fromRGB(12, 28, 36)
	panel.BorderSizePixel = 0
	panel.ZIndex = 2
	panel.Parent = sg
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 14)
	corner.Parent = panel

	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Size = UDim2.new(1, -20, 0, 40)
	title.Position = UDim2.fromOffset(10, 8)
	title.Font = UiTheme.Font
	title.TextSize = 22
	title.TextColor3 = Color3.fromRGB(255, 230, 200)
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Text = "Buy $D  ·  " .. formatCount(readBalance())
	title.ZIndex = 3
	title.Parent = panel

	for i, pack in ipairs(packs) do
		local btn = Instance.new("TextButton")
		btn.Name = pack.id
		btn.AutoButtonColor = true
		btn.Size = UDim2.new(1, -24, 0, 44)
		btn.Position = UDim2.fromOffset(12, 20 + i * 52)
		btn.BackgroundColor3 = Color3.fromRGB(40, 170, 70)
		btn.BorderSizePixel = 0
		btn.Font = UiTheme.Font
		btn.TextSize = 20
		btn.TextColor3 = Color3.new(1, 1, 1)
		btn.Text = pack.name
		btn.ZIndex = 3
		btn.Parent = panel
		local bc = Instance.new("UICorner")
		bc.CornerRadius = UDim.new(0, 10)
		bc.Parent = btn
		local pid = pack.productId
		btn.Activated:Connect(function()
			closeShop()
			promptPack(pid)
		end)
	end

	local scale = Instance.new("UIScale")
	scale.Scale = 0.85
	scale.Parent = panel
	TweenService:Create(scale, TweenInfo.new(0.2, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
end

local function stopDiscover()
	if discoverConn then
		discoverConn:Disconnect()
		discoverConn = nil
	end
end

local function wireHost(obj: GuiObject)
	host = obj
	hideInnerDLabel(obj)
	lastShown = readBalance()
	textTarget = findTextTarget(obj)
	if not textTarget then
		local lbl = Instance.new("TextLabel")
		lbl.Name = "Amount"
		lbl.BackgroundTransparency = 1
		lbl.Size = UDim2.fromScale(1, 1)
		lbl.Font = UiTheme.Font
		lbl.TextScaled = true
		lbl.TextColor3 = Color3.new(1, 1, 1)
		lbl.Text = "0"
		lbl.Parent = obj
		textTarget = lbl
	end
	applyText(readBalance())

	if obj:IsA("GuiButton") then
		if obj:GetAttribute("_OceanTD_DollarBound") ~= true then
			obj:SetAttribute("_OceanTD_DollarBound", true)
			obj.Activated:Connect(openShop)
		end
	else
		local existing = obj:FindFirstChild("_OceanTD_DollarHit")
		if existing then
			existing:Destroy()
		end
		local hit = Instance.new("TextButton")
		hit.Name = "_OceanTD_DollarHit"
		hit.Text = ""
		hit.BackgroundTransparency = 1
		hit.BorderSizePixel = 0
		hit.Size = UDim2.fromScale(1, 1)
		hit.ZIndex = obj.ZIndex + 5
		hit.Parent = obj
		hit.Activated:Connect(openShop)
	end
end

local function tryBindHost(): boolean
	local left = playerGui:FindFirstChild("MobileLeftUI")
	if not left then
		return false
	end
	local count = LeftHudLayout.findDCount(left)
	if not count or not count:IsA("GuiObject") then
		return false
	end
	if host == count and textTarget then
		return true
	end
	wireHost(count)
	return true
end

task.spawn(function()
	local left = playerGui:WaitForChild("MobileLeftUI", 60)
	if not left then
		warn("[ECONOMY] PlayerGui.MobileLeftUI missing")
		return
	end

	player:GetAttributeChangedSignal(ATTR):Connect(function()
		applyText(readBalance())
	end)

	if not tryBindHost() then
		discoverConn = left.DescendantAdded:Connect(function()
			if tryBindHost() then
				stopDiscover()
			end
		end)
		task.delay(2, function()
			if tryBindHost() then
				stopDiscover()
			else
				warn("[ECONOMY] MobileLeftUI $DCount missing")
			end
		end)
	else
		stopDiscover()
	end

	print("[ECONOMY] $DCount ready — balance", readBalance())
end)
