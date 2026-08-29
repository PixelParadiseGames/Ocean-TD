--!strict
--[[
	Prize-wheel seed reveal (top-center, 33% width):
	1) Spin paint color (72×72) → winner stays center (behind).
	2) Spin coral icon above color (smaller) → both slide to Quickbar Slot4.
]]

local Players = game:GetService("Players")
local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local Remotes = require(oceanRoot:WaitForChild("Remotes"))
local SeedWheel = require(oceanRoot:WaitForChild("Shared"):WaitForChild("SeedWheel"))
local InventoryState = require(script.Parent:WaitForChild("InventoryState"))

local COLOR_PX = 72
local CORAL_FINAL_PX = 58
local BAND_WIDTH_FRAC = 0.33
local BAND_TOP_FRAC = 0.06
local STEP_PX = 78
local SPIN_SEC = 3.2
local FLY_SEC = 0.55
local TICK_SOUND_ID = "rbxassetid://128707491647978"
local TICK_VOLUME = 0.3
local MIN_STEPS = 16
local EXTRA_STEPS_MAX = 10
local Z_COLOR = 10
local Z_CORAL = 30

local tickTemplate = Instance.new("Sound")
tickTemplate.Name = "OceanTD_SeedWheelTick"
tickTemplate.SoundId = TICK_SOUND_ID
tickTemplate.Volume = TICK_VOLUME
tickTemplate.RollOffMode = Enum.RollOffMode.InverseTapered
tickTemplate.Parent = SoundService

local overlay: ScreenGui? = nil
local band: Frame? = nil
local busy = false
local pitchCursor = 0.92
type Queued = { itemId: string, token: number, amount: number, colorIndex: number }
local queued: Queued? = nil

local function easeOutQuint(t: number): number
	local u = 1 - math.clamp(t, 0, 1)
	return 1 - u * u * u * u * u
end

local playReveal: (string, number, number, number) -> ()

local function claim(itemId: string, token: number)
	local ok, err = pcall(function()
		Remotes.get("SeedWheelClaim"):FireServer(itemId, token)
	end)
	if not ok then
		warn("[SEEDWHEEL] Claim failed", err)
	end
end

local function finishBusy()
	busy = false
	local q = queued
	queued = nil
	if q then
		task.defer(playReveal, q.itemId, q.token, q.amount, q.colorIndex)
	end
end

local function playTick()
	local s = tickTemplate:Clone()
	s.Volume = TICK_VOLUME
	pitchCursor += 0.035
	if pitchCursor > 1.18 then
		pitchCursor = 0.88
	end
	s.PlaybackSpeed = pitchCursor + (math.random() - 0.5) * 0.06
	s.Parent = SoundService
	s:Play()
	s.Ended:Once(function()
		s:Destroy()
	end)
	task.delay(2, function()
		if s.Parent then
			s:Destroy()
		end
	end)
end

local function ensureOverlay(): (ScreenGui, Frame)
	if overlay and overlay.Parent and band and band.Parent then
		return overlay, band
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = "OceanTD_SeedWheel"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 120
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = playerGui
	overlay = gui

	local host = Instance.new("Frame")
	host.Name = "Band"
	host.AnchorPoint = Vector2.new(0.5, 0)
	host.Position = UDim2.fromScale(0.5, BAND_TOP_FRAC)
	host.Size = UDim2.fromOffset(200, COLOR_PX + 8)
	host.BackgroundTransparency = 1
	host.ClipsDescendants = true
	host.Parent = gui
	band = host
	return gui, host
end

local function clearBandChildren(host: Frame)
	for _, ch in ipairs(host:GetChildren()) do
		if ch:IsA("GuiObject") then
			ch:Destroy()
		end
	end
end

local function roundCorner(parent: Instance)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = parent
end

local function brightenHue(color: Color3, amount: number): Color3
	local h, s, v = color:ToHSV()
	-- Keep hue; lift value and ease saturation so the rim reads as a bright tint of the fill.
	local nv = math.clamp(v + (1 - v) * amount + 0.12, 0, 1)
	local ns = math.clamp(s * (1 - amount * 0.35), 0, 1)
	return Color3.fromHSV(h, ns, nv)
end

local function makeColorCircle(parent: Instance, color: Color3, z: number, sizePx: number): Frame
	local f = Instance.new("Frame")
	f.Name = "ColorCircle"
	f.BackgroundColor3 = color
	f.BackgroundTransparency = 0
	f.BorderSizePixel = 0
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.Size = UDim2.fromOffset(sizePx, sizePx)
	f.ZIndex = z
	f.Parent = parent
	roundCorner(f)
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.Color = brightenHue(color, 0.55)
	stroke.Transparency = 0.15
	stroke.Parent = f
	return f
end

local function makeCoralCircle(parent: Instance, icon: string, z: number, sizePx: number): ImageLabel
	local img = Instance.new("ImageLabel")
	img.Name = "SeedCircle"
	img.BackgroundColor3 = Color3.fromRGB(20, 40, 55)
	img.BackgroundTransparency = 1
	img.BorderSizePixel = 0
	img.AnchorPoint = Vector2.new(0.5, 0.5)
	img.Size = UDim2.fromOffset(sizePx, sizePx)
	img.Image = icon
	img.ScaleType = Enum.ScaleType.Fit
	img.ZIndex = z
	img.Parent = parent
	roundCorner(img)
	return img
end

local function styleByOffset(guiObj: GuiObject, offsetX: number, halfW: number, baseSize: number)
	local u = math.clamp(math.abs(offsetX) / math.max(halfW, 1), 0, 1)
	local scale = 1 - u * 0.55
	local trans = u * 0.92
	guiObj.Size = UDim2.fromOffset(baseSize * scale, baseSize * scale)
	if guiObj:IsA("ImageLabel") then
		guiObj.ImageTransparency = trans
		guiObj.BackgroundTransparency = 1
	elseif guiObj:IsA("Frame") then
		guiObj.BackgroundTransparency = trans
	end
	local stroke = guiObj:FindFirstChildWhichIsA("UIStroke")
	if stroke then
		stroke.Transparency = 0.15 + trans * 0.75
	end
end

local function pickDifferentIds(pool: { string }, avoid: string): string
	if #pool <= 1 then
		return pool[1] or avoid
	end
	local pick = pool[math.random(1, #pool)]
	local tries = 0
	while pick == avoid and tries < 12 do
		pick = pool[math.random(1, #pool)]
		tries += 1
	end
	if pick == avoid then
		for _, id in ipairs(pool) do
			if id ~= avoid then
				return id
			end
		end
	end
	return pick
end

local function pickDifferentIndex(pool: { number }, avoid: number): number
	if #pool <= 1 then
		return pool[1] or avoid
	end
	local pick = pool[math.random(1, #pool)]
	local tries = 0
	while pick == avoid and tries < 12 do
		pick = pool[math.random(1, #pool)]
		tries += 1
	end
	if pick == avoid then
		for _, id in ipairs(pool) do
			if id ~= avoid then
				return id
			end
		end
	end
	return pick
end

-- Fillers → winner → peek (no adjacent duplicates).
local function buildIdSequence(winnerId: string): { string }
	local pool = SeedWheel.pool()
	local steps = MIN_STEPS + math.random(0, EXTRA_STEPS_MAX)
	local seq: { string } = {}
	local last = ""
	for _ = 1, steps - 1 do
		local pick = pickDifferentIds(pool, last)
		table.insert(seq, pick)
		last = pick
	end
	if last == winnerId and #seq > 0 then
		seq[#seq] = pickDifferentIds(pool, winnerId)
	end
	table.insert(seq, winnerId)
	table.insert(seq, pickDifferentIds(pool, winnerId))
	return seq
end

local function buildColorSequence(winnerIndex: number): { number }
	local pool = SeedWheel.colorIndices()
	local steps = MIN_STEPS + math.random(0, EXTRA_STEPS_MAX)
	local seq: { number } = {}
	local last = -1
	for _ = 1, steps - 1 do
		local pick = pickDifferentIndex(pool, last)
		table.insert(seq, pick)
		last = pick
	end
	if last == winnerIndex and #seq > 0 then
		seq[#seq] = pickDifferentIndex(pool, winnerIndex)
	end
	table.insert(seq, winnerIndex)
	table.insert(seq, pickDifferentIndex(pool, winnerIndex))
	return seq
end

local function runSpin(
	host: Frame,
	halfW: number,
	icons: { GuiObject },
	winnerIndex0: number,
	baseSize: number,
	onDone: () -> ()
)
	local totalSteps = winnerIndex0
	local t0 = os.clock()
	local lastFloor = -1
	local conn: RBXScriptConnection? = nil
	conn = RunService.RenderStepped:Connect(function()
		local raw = math.clamp((os.clock() - t0) / SPIN_SEC, 0, 1)
		local eased = easeOutQuint(raw)
		local progress = eased * totalSteps
		local centerIndex = progress

		if math.floor(progress + 1e-4) > lastFloor then
			local floored = math.floor(progress + 1e-4)
			while lastFloor < floored do
				lastFloor += 1
				playTick()
			end
		end

		for i, img in ipairs(icons) do
			local ox = ((i - 1) - centerIndex) * STEP_PX
			if math.abs(ox) > halfW + baseSize then
				img.Visible = false
			else
				img.Visible = true
				img.Position = UDim2.new(0.5, ox, 0.5, 0)
				styleByOffset(img, ox, halfW, baseSize)
			end
		end

		if raw >= 1 then
			if conn then
				conn:Disconnect()
			end
			onDone()
		end
	end)
end

local function flyBundle(holder: Frame, start: Vector2, itemId: string, token: number)
	local target = InventoryState.getBackpackButtonScreenCenter()
	if not target then
		local cam = workspace.CurrentCamera
		local vp = if cam then cam.ViewportSize else Vector2.new(1280, 720)
		target = Vector2.new(vp.X * 0.92, vp.Y * 0.12)
	else
		-- Slot4 lives under inset-aware HUD; our overlay is IgnoreGuiInset.
		local inset = GuiService:GetGuiInset()
		target = Vector2.new(target.X + inset.X, target.Y + inset.Y)
	end

	local gui = overlay
	if not gui then
		claim(itemId, token)
		holder:Destroy()
		finishBusy()
		return
	end

	holder.Parent = gui
	holder.AnchorPoint = Vector2.new(0.5, 0.5)
	holder.Position = UDim2.fromOffset(start.X, start.Y)
	holder.Size = UDim2.fromOffset(COLOR_PX, COLOR_PX)
	holder.ZIndex = 50

	local t0 = os.clock()
	local conn: RBXScriptConnection? = nil
	conn = RunService.RenderStepped:Connect(function()
		local u = math.clamp((os.clock() - t0) / FLY_SEC, 0, 1)
		local e = u * u * (3 - 2 * u)
		local x = start.X + (target.X - start.X) * e
		local y = start.Y + (target.Y - start.Y) * e
		local s = 1 - e * 0.45
		holder.Position = UDim2.fromOffset(x, y)
		holder.Size = UDim2.fromOffset(COLOR_PX * s, COLOR_PX * s)
		if u >= 1 then
			if conn then
				conn:Disconnect()
			end
			holder:Destroy()
			claim(itemId, token)
			finishBusy()
		end
	end)
end

playReveal = function(itemId: string, token: number, _amount: number, colorIndex: number)
	if busy then
		queued = { itemId = itemId, token = token, amount = _amount, colorIndex = colorIndex }
		return
	end
	if not SeedWheel.isWheelItem(itemId) then
		warn("[SEEDWHEEL] Bad item", itemId)
		claim(itemId, token)
		finishBusy()
		return
	end
	busy = true
	local gui, host = ensureOverlay()
	clearBandChildren(host)

	local cam = workspace.CurrentCamera
	local vp = if cam then cam.ViewportSize else Vector2.new(1280, 720)
	local bandW = vp.X * BAND_WIDTH_FRAC
	host.Size = UDim2.new(0, bandW, 0, COLOR_PX + 8)
	local halfW = bandW * 0.5

	local colorSeq = buildColorSequence(colorIndex)
	local colorWinner0 = #colorSeq - 2
	local colorIcons: { GuiObject } = {}
	for i, idx in ipairs(colorSeq) do
		local f = makeColorCircle(host, SeedWheel.colorForIndex(idx), Z_COLOR + i, COLOR_PX)
		f.Visible = false
		table.insert(colorIcons, f)
	end

	runSpin(host, halfW, colorIcons, colorWinner0, COLOR_PX, function()
		local colorWinner = colorIcons[colorWinner0 + 1]
		local colorPeek = colorIcons[colorWinner0 + 2]
		for i, img in ipairs(colorIcons) do
			if img ~= colorWinner and img ~= colorPeek then
				img:Destroy()
			end
		end
		if colorPeek then
			colorPeek:Destroy()
		end
		if not colorWinner then
			claim(itemId, token)
			finishBusy()
			return
		end
		colorWinner.Position = UDim2.new(0.5, 0, 0.5, 0)
		colorWinner.Size = UDim2.fromOffset(COLOR_PX, COLOR_PX)
		colorWinner.BackgroundTransparency = 0
		colorWinner.ZIndex = Z_COLOR
		local stroke = colorWinner:FindFirstChildWhichIsA("UIStroke")
		if stroke then
			stroke.Transparency = 0.15
		end

		-- Coral spin above the parked color circle.
		local coralSeq = buildIdSequence(itemId)
		local coralWinner0 = #coralSeq - 2
		local coralIcons: { GuiObject } = {}
		for i, id in ipairs(coralSeq) do
			local icon = SeedWheel.iconFor(id) or ""
			local img = makeCoralCircle(host, icon, Z_CORAL + i, CORAL_FINAL_PX)
			img.Visible = false
			table.insert(coralIcons, img)
		end

		runSpin(host, halfW, coralIcons, coralWinner0, CORAL_FINAL_PX, function()
			local coralWinner = coralIcons[coralWinner0 + 1] :: ImageLabel?
			local coralPeek = coralIcons[coralWinner0 + 2]
			for i, img in ipairs(coralIcons) do
				if img ~= coralWinner and img ~= coralPeek then
					img:Destroy()
				end
			end
			if not coralWinner then
				claim(itemId, token)
				finishBusy()
				return
			end

			-- Lock center pose (no size pulse / snap).
			coralWinner.Position = UDim2.new(0.5, 0, 0.5, 0)
			coralWinner.Size = UDim2.fromOffset(CORAL_FINAL_PX, CORAL_FINAL_PX)
			coralWinner.ImageTransparency = 0
			coralWinner.BackgroundTransparency = 1
			coralWinner.ZIndex = Z_CORAL + 20

			if coralPeek and coralPeek:IsA("ImageLabel") then
				local peekScale = 0.62
				coralPeek.Position = UDim2.new(0.5, STEP_PX * 0.85, 0.5, 0)
				coralPeek.Size = UDim2.fromOffset(CORAL_FINAL_PX * peekScale, CORAL_FINAL_PX * peekScale)
				coralPeek.ImageTransparency = 0.55
				coralPeek.BackgroundTransparency = 1
				coralPeek.Visible = true
				coralPeek.ZIndex = Z_CORAL + 5
			end

			-- AbsolutePosition is content-origin (no top-bar inset). Overlay is
			-- IgnoreGuiInset, so add inset or the bundle snaps upward on reparent.
			local inset = GuiService:GetGuiInset()
			local absCenter = colorWinner.AbsolutePosition + colorWinner.AbsoluteSize * 0.5
			local start = Vector2.new(absCenter.X + inset.X, absCenter.Y + inset.Y)

			-- Hide winners in-band before reparent so one frame can't flash a jump.
			colorWinner.Visible = false
			coralWinner.Visible = false
			if coralPeek then
				coralPeek:Destroy()
			end

			local holder = Instance.new("Frame")
			holder.Name = "SeedWheelBundle"
			holder.BackgroundTransparency = 1
			holder.AnchorPoint = Vector2.new(0.5, 0.5)
			holder.Size = UDim2.fromOffset(COLOR_PX, COLOR_PX)
			holder.Position = UDim2.fromOffset(start.X, start.Y)
			holder.ZIndex = 50
			holder.Visible = false
			holder.Parent = gui

			colorWinner.Parent = holder
			colorWinner.Position = UDim2.fromScale(0.5, 0.5)
			colorWinner.Size = UDim2.fromScale(1, 1)
			colorWinner.ZIndex = 1
			colorWinner.Visible = true

			coralWinner.Parent = holder
			coralWinner.Position = UDim2.fromScale(0.5, 0.5)
			coralWinner.Size = UDim2.fromScale(CORAL_FINAL_PX / COLOR_PX, CORAL_FINAL_PX / COLOR_PX)
			coralWinner.ZIndex = 2
			coralWinner.Visible = true

			holder.Visible = true
			flyBundle(holder, start, itemId, token)
		end)
	end)
end

Remotes.get("SeedWheelReveal").OnClientEvent:Connect(function(itemId: any, token: any, amount: any, colorIndex: any)
	if typeof(itemId) ~= "string" or typeof(token) ~= "number" then
		return
	end
	local add = math.max(1, math.floor(tonumber(amount) or 1))
	local cidx = math.clamp(math.floor(tonumber(colorIndex) or SeedWheel.pickRandomColorIndex()), 1, 14)
	task.spawn(playReveal, itemId, token, add, cidx)
end)

print("[SEEDWHEEL] Ready")
