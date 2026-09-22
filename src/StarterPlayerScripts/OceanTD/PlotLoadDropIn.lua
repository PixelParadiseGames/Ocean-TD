--!strict
--[[
	Staggered sky drop-in for plot corals (Save Plot LOAD + Join Intro handoff).
	Parts stay invisible until their drop starts, then fade in while falling.
]]

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ItemCatalog = require(ReplicatedStorage:WaitForChild("OceanTD"):WaitForChild("Shared"):WaitForChild("ItemCatalog"))

local ClientPlot = require(script.Parent:WaitForChild("ClientPlot"))

local PlotLoadDropIn = {}

local LOAD_DROP_HEIGHT = 70
local LOAD_DROP_TWEEN = TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local FADE_IN_TWEEN = TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local function collectVisualParts(root: BasePart): { BasePart }
	local parts: { BasePart } = { root }
	local seen: { [BasePart]: boolean } = { [root] = true }
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("BasePart") and not seen[d] then
			seen[d] = true
			table.insert(parts, d)
		end
	end
	return parts
end

function PlotLoadDropIn.setPartHiddenLocal(part: BasePart, hidden: boolean)
	local mod = if hidden then 1 else 0
	for _, p in ipairs(collectVisualParts(part)) do
		p.LocalTransparencyModifier = mod
	end
end

function PlotLoadDropIn.gatherOwnedPlotParts(): { BasePart }
	local parts: { BasePart } = {}
	local seen: { [BasePart]: boolean } = {}
	local function consider(inst: Instance)
		if not inst:IsA("BasePart") or seen[inst] then
			return
		end
		if typeof(inst:GetAttribute("OceanTD_GhostBaseR")) == "number" then
			return
		end
		local hasId = typeof(inst:GetAttribute("OceanTD_ItemId")) == "string"
			or typeof(inst:GetAttribute("OceanTD_SpeciesId")) == "string"
			or typeof(inst:GetAttribute("OceanTD_PlaceId")) == "string"
		local named = inst.Name ~= "" and ItemCatalog.get(inst.Name) ~= nil
		if not hasId and not named then
			return
		end
		seen[inst] = true
		table.insert(parts, inst)
	end

	local root = Workspace:FindFirstChild("OceanTD_Placed")
	if not root then
		return parts
	end
	local mirrored = ClientPlot.get()
	local folder = if mirrored then root:FindFirstChild(mirrored.plotId) else nil
	if folder then
		for _, inst in ipairs(folder:GetDescendants()) do
			consider(inst)
		end
	end
	if #parts == 0 then
		for _, inst in ipairs(root:GetDescendants()) do
			consider(inst)
		end
	end
	return parts
end

-- spanSec: total window for random start delays (e.g. 1–3).
function PlotLoadDropIn.play(expectedCount: number?, spanSec: number?)
	task.spawn(function()
		local want = if typeof(expectedCount) == "number" then math.max(0, math.floor(expectedCount)) else nil
		local span = if typeof(spanSec) == "number" then math.max(0.25, spanSec) else 3
		local parts: { BasePart } = {}
		local deadline = os.clock() + 0.75
		while os.clock() < deadline do
			parts = PlotLoadDropIn.gatherOwnedPlotParts()
			if want == nil then
				break
			end
			if want == 0 then
				return
			end
			if #parts >= want then
				break
			end
			RunService.Heartbeat:Wait()
		end
		if #parts == 0 then
			return
		end
		local rng = Random.new()
		for _, part in ipairs(parts) do
			if not part.Parent then
				continue
			end
			local visuals = collectVisualParts(part)
			-- Invisible first so the sky park is never seen.
			for _, p in ipairs(visuals) do
				p.LocalTransparencyModifier = 1
			end
			local finalCF = part.CFrame
			local lift = LOAD_DROP_HEIGHT + part.Size.Y * 0.5
			part.CFrame = finalCF + Vector3.new(0, lift, 0)
			local delaySec = rng:NextNumber(0, span)
			task.delay(delaySec, function()
				if not part.Parent then
					return
				end
				for _, p in ipairs(visuals) do
					if p.Parent then
						TweenService:Create(p, FADE_IN_TWEEN, { LocalTransparencyModifier = 0 }):Play()
					end
				end
				TweenService:Create(part, LOAD_DROP_TWEEN, { CFrame = finalCF }):Play()
			end)
		end
	end)
end

return PlotLoadDropIn
