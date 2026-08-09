--!strict
--[[
	Clones WaveRoute.A.EndPoint onto every non-Plot1 slot at boot.
	Same rigid remap as DecorReplicator: offset = plot1:ToObjectSpace(partCF)
	world = targetPlot * offset (per BasePart so Folder/Model hierarchies stay correct).
	Plot1 keeps the authored EndPoint under WaveRoute.
]]

local Workspace = game:GetService("Workspace")

local oceanShared = game:GetService("ReplicatedStorage"):WaitForChild("OceanTD"):WaitForChild("Shared")
local Constants = require(oceanShared:WaitForChild("Constants"))

local WaveHeartReplicator = {}

local FOLDER_NAME = "OceanTD_PlotHearts"

export type PlotPose = {
	plotIndex: number,
	cframe: CFrame,
	size: Vector3?,
}

local function log(...: any)
	print("[WAVEHEART]", ...)
end

local function warnHeart(...: any)
	warn("[WAVEHEART]", ...)
end

local function findAuthoredEndPoint(): Instance?
	local route = Workspace:FindFirstChild("WaveRoute")
	local a = route and route:FindFirstChild("A")
	return a and a:FindFirstChild("EndPoint")
end

local function prepareClone(inst: Instance)
	for _, d in ipairs(inst:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
		elseif d:IsA("WeldConstraint") or d:IsA("Weld") or d:IsA("Motor6D") then
			d:Destroy()
		end
	end
	if inst:IsA("BasePart") then
		inst.Anchored = true
		inst.CanCollide = false
	end
end

local function remapPartsToPlot(inst: Instance, plot1Cf: CFrame, targetPlotCf: CFrame)
	local function remapPart(p: BasePart)
		local offset = plot1Cf:ToObjectSpace(p.CFrame)
		p.CFrame = targetPlotCf * offset
	end
	if inst:IsA("BasePart") then
		remapPart(inst)
	end
	for _, d in ipairs(inst:GetDescendants()) do
		if d:IsA("BasePart") then
			remapPart(d)
		end
	end
end

function WaveHeartReplicator.replicate(plotPoses: { PlotPose }): boolean
	local ep = findAuthoredEndPoint()
	if not ep then
		warnHeart("WaveRoute.A.EndPoint missing — skip heart clone")
		return false
	end
	local plot1 = plotPoses[1]
	if not plot1 then
		warnHeart("no plot 1 pose — skip heart clone")
		return false
	end

	local existing = Workspace:FindFirstChild(FOLDER_NAME)
	if existing then
		existing:Destroy()
	end
	local root = Instance.new("Folder")
	root.Name = FOLDER_NAME
	root.Parent = Workspace

	local cloned = 0
	for i = 2, Constants.MAX_PLOTS do
		local pose = plotPoses[i]
		if not pose then
			continue
		end
		local clone = ep:Clone()
		clone.Name = "Plot" .. tostring(pose.plotIndex)
		prepareClone(clone)
		remapPartsToPlot(clone, plot1.cframe, pose.cframe)
		clone.Parent = root
		cloned += 1
		log("Cloned EndPoint ->", clone.Name)
	end

	Workspace:SetAttribute("WaveHeartReplicationReady", true)
	log("Done; hearts=", cloned)
	return cloned > 0
end

return WaveHeartReplicator
