--!strict
--[[
	Updates Workspace … "Current Wave Sign" for the local player's plot.
	While waves run: "Wave N". Idle: all-time high from OceanTD_HighestWave.
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local Constants = require(oceanRoot:WaitForChild("Shared"):WaitForChild("Constants"))
local Remotes = require(oceanRoot:WaitForChild("Remotes"))

local ClientPlot = require(script.Parent:WaitForChild("ClientPlot"))
local WaveSim = require(script.Parent:WaitForChild("WaveSim"))

local WaveSign = {}

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local reportRemote = Remotes.get("ReportHighestWave")
local cachedHigh = 0
local lastReported = 0
local lastText = ""
local signCache: Instance? = nil
local signPlotId: string? = nil
local mounted = false
local localHidden = false
local guiEnabledRestore: { [Instance]: boolean } = {}
local introSignClone: Instance? = nil
-- Join-intro loading: keep Current Wave Sign invisible until fade-in.
local introSignLoadHidden = false
local introSignFading = false
local introFadeToken = 0

local function readHigh(): number
	local attr = player:GetAttribute(Constants.HIGHEST_WAVE_ATTR)
	if typeof(attr) == "number" and attr >= 0 then
		return math.floor(attr)
	end
	return math.max(0, cachedHigh)
end

local function reportHigh(wave: number)
	local w = math.max(0, math.floor(wave))
	if w <= 0 then
		return
	end
	if w > cachedHigh then
		cachedHigh = w
	end
	if w > lastReported then
		lastReported = w
		reportRemote:FireServer(w)
	end
	if w > readHigh() then
		player:SetAttribute(Constants.HIGHEST_WAVE_ATTR, w)
	end
end

local function findSignRoot(plotId: string): Instance?
	if signCache and signCache.Parent and signPlotId == plotId then
		return signCache
	end
	signCache = nil
	signPlotId = plotId
	local name = Constants.CURRENT_WAVE_SIGN_NAME
	if plotId == "Plot1" then
		local master = Workspace:FindFirstChild(Constants.MASTER_DECOR_NAME)
		local sign = master and master:FindFirstChild(name, true)
		if sign then
			signCache = sign
			return sign
		end
	end
	local n = tonumber(string.match(plotId, "%d+"))
	if n and n >= 2 then
		local root = Workspace:FindFirstChild(Constants.STATIC_PLOT_PREFIX .. tostring(n))
		local sign = root and root:FindFirstChild(name, true)
		if sign then
			signCache = sign
			return sign
		end
	end
	return nil
end

local function applyText(sign: Instance, text: string)
	if text == lastText and sign == signCache then
		return
	end
	lastText = text
	for _, d in ipairs(sign:GetDescendants()) do
		if d:IsA("TextLabel") or d:IsA("TextBox") then
			d.Text = text
		end
	end
	if sign:IsA("TextLabel") or sign:IsA("TextBox") then
		(sign :: TextLabel).Text = text
	end
end

local function applyLocalHidden(sign: Instance, hide: boolean)
	local function visit(inst: Instance)
		if inst:IsA("BasePart") then
			inst.LocalTransparencyModifier = if hide then 1 else 0
		elseif inst:IsA("Decal") or inst:IsA("Texture") then
			inst.LocalTransparencyModifier = if hide then 1 else 0
		elseif inst:IsA("BillboardGui") or inst:IsA("SurfaceGui") then
			if hide then
				if guiEnabledRestore[inst] == nil then
					guiEnabledRestore[inst] = (inst :: BillboardGui).Enabled
				end
				(inst :: BillboardGui).Enabled = false
			else
				local prev = guiEnabledRestore[inst]
				;(inst :: BillboardGui).Enabled = if prev == nil then true else prev
				guiEnabledRestore[inst] = nil
			end
		end
	end
	visit(sign)
	for _, d in ipairs(sign:GetDescendants()) do
		visit(d)
	end
	if not hide then
		table.clear(guiEnabledRestore)
	end
end

local function setLocalHidden(hide: boolean)
	if localHidden == hide then
		return
	end
	localHidden = hide
	local mirrored = ClientPlot.get()
	if not mirrored then
		return
	end
	local sign = findSignRoot(mirrored.plotId)
	if not sign then
		return
	end
	applyLocalHidden(sign, hide)
end

local function findMasterSign(): Instance?
	local master = Workspace:FindFirstChild(Constants.MASTER_DECOR_NAME)
	return master and master:FindFirstChild(Constants.CURRENT_WAVE_SIGN_NAME, true)
end

local function ensureSignVisible(sign: Instance)
	local function visit(inst: Instance)
		if inst:IsA("BasePart") then
			inst.LocalTransparencyModifier = 0
		elseif inst:IsA("Decal") or inst:IsA("Texture") then
			inst.LocalTransparencyModifier = 0
		elseif inst:IsA("BillboardGui") or inst:IsA("SurfaceGui") then
			(inst :: BillboardGui).Enabled = true
			guiEnabledRestore[inst] = nil
		elseif inst:IsA("TextLabel") or inst:IsA("TextBox") then
			(inst :: TextLabel).TextTransparency = 0
			(inst :: TextLabel).TextStrokeTransparency = math.min((inst :: TextLabel).TextStrokeTransparency, 0.5)
		end
	end
	visit(sign)
	for _, d in ipairs(sign:GetDescendants()) do
		visit(d)
	end
end

local function gatherIntroDisplaySigns(): { Instance }
	local signs: { Instance } = {}
	local seen: { [Instance]: boolean } = {}
	local function add(sign: Instance?)
		if sign and sign.Parent and not seen[sign] then
			seen[sign] = true
			table.insert(signs, sign)
		end
	end
	add(introSignClone)
	add(findMasterSign())
	local mirrored = ClientPlot.get()
	if mirrored then
		add(findSignRoot(mirrored.plotId))
	end
	return signs
end

local function applySignHiddenInstant(sign: Instance, hide: boolean)
	local function visit(inst: Instance)
		if inst:IsA("BasePart") then
			inst.LocalTransparencyModifier = if hide then 1 else 0
		elseif inst:IsA("Decal") or inst:IsA("Texture") then
			inst.LocalTransparencyModifier = if hide then 1 else 0
		elseif inst:IsA("BillboardGui") or inst:IsA("SurfaceGui") then
			if hide then
				if guiEnabledRestore[inst] == nil then
					guiEnabledRestore[inst] = (inst :: BillboardGui).Enabled
				end
				(inst :: BillboardGui).Enabled = false
			else
				local prev = guiEnabledRestore[inst]
				;(inst :: BillboardGui).Enabled = if prev == nil then true else prev
				guiEnabledRestore[inst] = nil
			end
		elseif inst:IsA("TextLabel") or inst:IsA("TextBox") then
			(inst :: TextLabel).TextTransparency = if hide then 1 else 0
		end
	end
	visit(sign)
	for _, d in ipairs(sign:GetDescendants()) do
		visit(d)
	end
end

local function masterSignWorldCf(master: Instance): CFrame?
	if master:IsA("Model") then
		return (master :: Model):GetPivot()
	end
	if master:IsA("BasePart") then
		return master.CFrame
	end
	local p = master:FindFirstChildWhichIsA("BasePart", true)
	return if p then p.CFrame else nil
end

local function refresh()
	local mirrored = ClientPlot.get()
	if not mirrored then
		return
	end
	if playerGui:GetAttribute("OceanTD_JoinIntroBusy") == true then
		local function touch(sign: Instance)
			applyText(sign, "Wave 100")
			if introSignLoadHidden then
				applySignHiddenInstant(sign, true)
			elseif not introSignFading then
				ensureSignVisible(sign)
			end
		end
		if introSignClone and introSignClone.Parent then
			touch(introSignClone)
		end
		local master = findMasterSign()
		if master then
			touch(master)
		end
		local sign = findSignRoot(mirrored.plotId)
		if sign then
			touch(sign)
		end
		return
	end
	local sign = findSignRoot(mirrored.plotId)
	if not sign then
		return
	end
	local snap = WaveSim.getHudSnapshot()
	if snap.running and snap.wave > 0 and not WaveSim.isJoinIntroDemo() then
		applyText(sign, "Wave " .. tostring(snap.wave))
		reportHigh(snap.wave)
	elseif snap.running and snap.wave > 0 and WaveSim.isJoinIntroDemo() then
		applyText(sign, "Wave " .. tostring(snap.wave))
	else
		applyText(sign, "Wave " .. tostring(readHigh()))
	end
	if localHidden then
		applyLocalHidden(sign, true)
	end
end

function WaveSign.beginJoinIntroDisplay(keepHidden: boolean?)
	lastText = ""
	localHidden = false
	if keepHidden == true then
		introSignLoadHidden = true
	end
	local function afterSetup(sign: Instance?)
		if not sign then
			return
		end
		applyText(sign, "Wave 100")
		if introSignLoadHidden then
			applySignHiddenInstant(sign, true)
		else
			ensureSignVisible(sign)
		end
	end
	local master = findMasterSign()
	afterSetup(master)
	local mirrored = ClientPlot.get()
	if not mirrored then
		-- Retry once ClientPlot / MasterPlotDecor stream in.
		task.spawn(function()
			local deadline = os.clock() + 4
			while os.clock() < deadline do
				if playerGui:GetAttribute("OceanTD_JoinIntroBusy") ~= true then
					return
				end
				if introSignClone and introSignClone.Parent then
					return
				end
				if ClientPlot.get() and findMasterSign() then
					WaveSign.beginJoinIntroDisplay(introSignLoadHidden)
					return
				end
				task.wait(0.15)
			end
		end)
		return
	end
	if mirrored.plotId == "Plot1" then
		signCache = master
		signPlotId = "Plot1"
		if not master then
			task.spawn(function()
				local deadline = os.clock() + 4
				while os.clock() < deadline do
					if playerGui:GetAttribute("OceanTD_JoinIntroBusy") ~= true then
						return
					end
					local found = findMasterSign()
					if found then
						afterSetup(found)
						signCache = found
						signPlotId = "Plot1"
						return
					end
					task.wait(0.15)
				end
			end)
		end
		return
	end
	if introSignClone and introSignClone.Parent then
		afterSetup(introSignClone)
		signCache = introSignClone
		signPlotId = mirrored.plotId
		return
	end
	if not master then
		task.spawn(function()
			local deadline = os.clock() + 4
			while os.clock() < deadline do
				if playerGui:GetAttribute("OceanTD_JoinIntroBusy") ~= true then
					return
				end
				if introSignClone and introSignClone.Parent then
					return
				end
				if findMasterSign() then
					WaveSign.beginJoinIntroDisplay(introSignLoadHidden)
					return
				end
				task.wait(0.15)
			end
		end)
		return
	end
	local masterCf = masterSignWorldCf(master)
	if not masterCf then
		return
	end
	local clone = master:Clone()
	clone.Name = "OceanTD_JoinIntroWaveSign"
	for _, d in ipairs(clone:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
		elseif d:IsA("Script") or d:IsA("LocalScript") or d:IsA("ModuleScript") then
			d:Destroy()
		end
	end
	local targetCf = ClientPlot.remapCFrameFromPlot1(masterCf)
	if clone:IsA("Model") then
		(clone :: Model):PivotTo(targetCf)
	elseif clone:IsA("BasePart") then
		clone.Anchored = true
		clone.CanCollide = false
		clone.CFrame = targetCf
	end
	local folder = Workspace:FindFirstChild("OceanTD_JoinIntroSign")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "OceanTD_JoinIntroSign"
		folder.Parent = Workspace
	end
	clone.Parent = folder
	introSignClone = clone
	afterSetup(clone)
	signCache = clone
	signPlotId = mirrored.plotId
end

function WaveSign.setJoinIntroSignHidden(hidden: boolean)
	introSignLoadHidden = hidden
	if hidden then
		introSignFading = false
		introFadeToken += 1
	end
	for _, sign in ipairs(gatherIntroDisplaySigns()) do
		applySignHiddenInstant(sign, hidden)
	end
end

function WaveSign.fadeInJoinIntroSign(durationSec: number?)
	local dur = if typeof(durationSec) == "number" then math.max(0.05, durationSec) else 1
	introSignLoadHidden = false
	introFadeToken += 1
	local myToken = introFadeToken
	introSignFading = true

	local signs = gatherIntroDisplaySigns()
	-- Start fully hidden, then tween in.
	for _, sign in ipairs(signs) do
		applySignHiddenInstant(sign, true)
		-- Re-enable Surface/Billboard so text can fade with the mesh.
		local function enableGuis(inst: Instance)
			if inst:IsA("BillboardGui") or inst:IsA("SurfaceGui") then
				(inst :: BillboardGui).Enabled = true
				guiEnabledRestore[inst] = nil
			end
		end
		enableGuis(sign)
		for _, d in ipairs(sign:GetDescendants()) do
			enableGuis(d)
		end
	end

	local info = TweenInfo.new(dur, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local tweens: { Tween } = {}
	for _, sign in ipairs(signs) do
		local function consider(inst: Instance)
			if inst:IsA("BasePart") then
				inst.LocalTransparencyModifier = 1
				table.insert(tweens, TweenService:Create(inst, info, { LocalTransparencyModifier = 0 }))
			elseif inst:IsA("Decal") or inst:IsA("Texture") then
				(inst :: Decal).LocalTransparencyModifier = 1
				table.insert(tweens, TweenService:Create(inst, info, { LocalTransparencyModifier = 0 }))
			elseif inst:IsA("TextLabel") or inst:IsA("TextBox") then
				(inst :: TextLabel).TextTransparency = 1
				table.insert(tweens, TweenService:Create(inst, info, { TextTransparency = 0 }))
			end
		end
		consider(sign)
		for _, d in ipairs(sign:GetDescendants()) do
			consider(d)
		end
	end
	for _, tw in ipairs(tweens) do
		tw:Play()
	end
	task.delay(dur, function()
		if myToken ~= introFadeToken then
			return
		end
		introSignFading = false
		if introSignLoadHidden then
			return
		end
		for _, sign in ipairs(gatherIntroDisplaySigns()) do
			ensureSignVisible(sign)
		end
	end)
end

function WaveSign.endJoinIntroDisplay()
	introSignLoadHidden = false
	introSignFading = false
	introFadeToken += 1
	if introSignClone then
		introSignClone:Destroy()
		introSignClone = nil
	end
	local folder = Workspace:FindFirstChild("OceanTD_JoinIntroSign")
	if folder then
		folder:Destroy()
	end
	signCache = nil
	signPlotId = nil
	lastText = ""
	refresh()
end

function WaveSign.mount()
	if mounted then
		refresh()
		return
	end
	mounted = true
	cachedHigh = readHigh()
	lastReported = cachedHigh
	player:GetAttributeChangedSignal(Constants.HIGHEST_WAVE_ATTR):Connect(function()
		cachedHigh = math.max(cachedHigh, readHigh())
		if not WaveSim.isRunning() then
			refresh()
		end
	end)
	WaveSim.onHud(function(_snap)
		refresh()
	end)
	WaveSim.onStopped(function(summary)
		reportHigh(summary.waveReached)
		refresh()
	end)
	ClientPlot.onChanged(function()
		signCache = nil
		signPlotId = nil
		lastText = ""
		table.clear(guiEnabledRestore)
		refresh()
		if localHidden then
			local mirrored = ClientPlot.get()
			local sign = mirrored and findSignRoot(mirrored.plotId)
			if sign then
				applyLocalHidden(sign, true)
			end
		end
	end)
	local function syncIntroCamHide()
		local busy = playerGui:GetAttribute("OceanTD_SharkCamBusy") == true
			or playerGui:GetAttribute("OceanTD_UrchinCamBusy") == true
			or playerGui:GetAttribute("OceanTD_TangCamBusy") == true
		setLocalHidden(busy)
	end
	playerGui:GetAttributeChangedSignal("OceanTD_SharkCamBusy"):Connect(syncIntroCamHide)
	playerGui:GetAttributeChangedSignal("OceanTD_UrchinCamBusy"):Connect(syncIntroCamHide)
	playerGui:GetAttributeChangedSignal("OceanTD_TangCamBusy"):Connect(syncIntroCamHide)
	playerGui:GetAttributeChangedSignal("OceanTD_JoinIntroBusy"):Connect(function()
		refresh()
	end)
	syncIntroCamHide()
	task.defer(refresh)
end

function WaveSign.getFocusWorldPos(): Vector3?
	if introSignClone and introSignClone.Parent then
		if introSignClone:IsA("BasePart") then
			return introSignClone.Position
		end
		if introSignClone:IsA("Model") then
			return (introSignClone :: Model):GetPivot().Position
		end
		local part = introSignClone:FindFirstChildWhichIsA("BasePart", true)
		if part then
			return part.Position
		end
	end
	local mirrored = ClientPlot.get()
	if not mirrored then
		return nil
	end
	local sign = findSignRoot(mirrored.plotId)
	if not sign then
		local master = findMasterSign()
		local cf = master and masterSignWorldCf(master)
		return if cf then ClientPlot.remapCFrameFromPlot1(cf).Position else nil
	end
	if sign:IsA("BasePart") then
		return sign.Position
	end
	if sign:IsA("Model") then
		return (sign :: Model):GetPivot().Position
	end
	local part = sign:FindFirstChildWhichIsA("BasePart", true)
	return if part then part.Position else nil
end

return WaveSign
