--!strict
--[[
	Clones Workspace.MasterPlotDecor onto StaticPlot_2..N at server boot.

	Rigid remap: offset = plot1.CFrame:ToObjectSpace(objectCFrame)
	             world  = targetPlot.CFrame * offset

	Plot 1 keeps MasterPlotDecor (no StaticPlot_1). Hierarchy under Master is
	mirrored on each StaticPlot. Models clone as wholes; loose BaseParts clone
	individually. Re-run clears existing StaticPlot_* first.
]]

local Workspace = game:GetService("Workspace")

local oceanShared = game:GetService("ReplicatedStorage"):WaitForChild("OceanTD"):WaitForChild("Shared")
local Constants = require(oceanShared:WaitForChild("Constants"))

local DecorReplicator = {}

local DECOR_MASTER_REL_PATH_ATTR = "DecorMasterRelPath"
local ready = false

local function log(...: any)
	print("[DECOR]", ...)
end

local function warnDecor(...: any)
	warn("[DECOR]", ...)
end

local function relativeDecorPathFromMaster(masterFolder: Instance, inst: Instance): string
	local segs: { string } = {}
	local cur: Instance? = inst
	while cur and cur ~= masterFolder do
		table.insert(segs, 1, cur.Name)
		cur = cur.Parent
	end
	return table.concat(segs, "/")
end

local function depthBelowMaster(masterFolder: Instance, inst: Instance): number
	local n = 0
	local cur: Instance? = inst
	while cur and cur ~= masterFolder do
		n += 1
		cur = cur.Parent
	end
	return n
end

local function ancestorChainFromMaster(masterFolder: Instance, node: Instance): { Instance }
	local chain: { Instance } = {}
	local cur: Instance? = node
	while cur and cur ~= masterFolder do
		table.insert(chain, 1, cur)
		cur = cur.Parent
	end
	return chain
end

local function hasModelAncestorBelowMaster(masterFolder: Instance, inst: Instance): boolean
	local cur: Instance? = inst.Parent
	while cur and cur ~= masterFolder do
		if cur:IsA("Model") then
			return true
		end
		cur = cur.Parent
	end
	return false
end

local function resolveMirrorParent(
	plotRoot: Instance,
	chain: { Instance },
	modelCloneMap: { [Model]: Model },
	partCloneMap: { [BasePart]: BasePart }
): Instance
	local current: Instance = plotRoot
	for _, seg in ipairs(chain) do
		if seg:IsA("Model") then
			local mapped = modelCloneMap[seg]
			if not mapped then
				warnDecor("missing Model clone for", seg:GetFullName(), "— parenting to plot root")
				return plotRoot
			end
			current = mapped
		elseif seg:IsA("BasePart") then
			local pc = partCloneMap[seg]
			if not pc then
				warnDecor("missing BasePart clone for", seg:GetFullName(), "— parenting to plot root")
				return plotRoot
			end
			current = pc
		elseif seg:IsA("Folder") then
			local existing = current:FindFirstChild(seg.Name)
			if existing and existing:IsA("Folder") then
				current = existing
			else
				if existing then
					existing:Destroy()
				end
				local folder = Instance.new("Folder")
				folder.Name = seg.Name
				folder.Parent = current
				current = folder
			end
		else
			local existing = current:FindFirstChild(seg.Name)
			if existing and existing:IsA("Folder") then
				current = existing
			else
				local folder = Instance.new("Folder")
				folder.Name = seg.Name
				folder.Parent = current
				current = folder
			end
		end
	end
	return current
end

export type PlotPose = {
	plotIndex: number,
	cframe: CFrame,
}

function DecorReplicator.isReady(): boolean
	return ready
end

-- plotPoses: index 1 = master plot pose; 2..N = other plots (must match PlotService slots).
function DecorReplicator.replicate(plotPoses: { PlotPose }): boolean
	ready = false

	local masterFolder = Workspace:FindFirstChild(Constants.MASTER_DECOR_NAME)
	if not masterFolder then
		warnDecor(Constants.MASTER_DECOR_NAME, "not found — skip décor clone")
		return false
	end

	local plot1 = plotPoses[1]
	if not plot1 then
		warnDecor("no plot 1 pose — skip décor clone")
		return false
	end

	for _, descendant in ipairs(masterFolder:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant:SetAttribute(DECOR_MASTER_REL_PATH_ATTR, relativeDecorPathFromMaster(masterFolder, descendant))
		end
	end

	-- Clear prior StaticPlot_* so re-init / hot reload does not stack clones.
	for i = 2, Constants.MAX_PLOTS do
		local existing = Workspace:FindFirstChild(Constants.STATIC_PLOT_PREFIX .. tostring(i))
		if existing then
			existing:Destroy()
		end
	end

	local plotFolders: { [number]: Folder } = {}
	for i = 2, #plotPoses do
		local pose = plotPoses[i]
		if pose then
			local folder = Instance.new("Folder")
			folder.Name = Constants.STATIC_PLOT_PREFIX .. tostring(pose.plotIndex)
			folder.Parent = Workspace
			plotFolders[pose.plotIndex] = folder
		end
	end

	local replicateRoots: { Instance } = {}
	for _, obj in ipairs(masterFolder:GetDescendants()) do
		local isModel = obj:IsA("Model")
		local isPart = obj:IsA("BasePart")
		if isPart and obj.Parent and obj.Parent:IsA("Model") then
			continue
		end
		if isModel or isPart then
			if hasModelAncestorBelowMaster(masterFolder, obj) then
				continue
			end
			table.insert(replicateRoots, obj)
		end
	end

	table.sort(replicateRoots, function(a, b)
		return depthBelowMaster(masterFolder, a) < depthBelowMaster(masterFolder, b)
	end)

	local clonedPlots = 0
	for i = 2, #plotPoses do
		local targetPlot = plotPoses[i]
		local targetFolder = plotFolders[targetPlot.plotIndex]
		if not targetFolder then
			continue
		end

		local modelCloneMap: { [Model]: Model } = {}
		local partCloneMap: { [BasePart]: BasePart } = {}
		local count = 0

		for _, obj in ipairs(replicateRoots) do
			local isModel = obj:IsA("Model")
			local baseCFrame = if isModel then (obj :: Model):GetPivot() else (obj :: BasePart).CFrame
			local offsetCFrame = plot1.cframe:ToObjectSpace(baseCFrame)

			local parentInst = obj.Parent
			local chain = if parentInst then ancestorChainFromMaster(masterFolder, parentInst) else {}
			local parentForClone = resolveMirrorParent(targetFolder, chain, modelCloneMap, partCloneMap)

			local clone = obj:Clone()
			local targetCFrame = targetPlot.cframe * offsetCFrame
			if isModel then
				(clone :: Model):PivotTo(targetCFrame)
				modelCloneMap[obj :: Model] = clone :: Model
			else
				local bp = clone :: BasePart
				bp.CFrame = targetCFrame
				bp.Anchored = true
				partCloneMap[obj :: BasePart] = bp
			end

			clone.Parent = parentForClone
			count += 1
		end

		clonedPlots += 1
		log("Cloned", count, "roots ->", targetFolder.Name)
	end

	ready = true
	Workspace:SetAttribute("DecorEnvReplicationReady", true)
	log("Done; StaticPlot folders=", clonedPlots, "roots=", #replicateRoots)
	return true
end

return DecorReplicator
