--!strict
--[[
	Frozen join-intro coral package (option 2, light):
	1) Wait until Workspace.Plots.Intro is fully present on the server
	2) Clone → ServerStorage.OceanTD_IntroSnapshot (server-only cache)
	3) Publish one copy → ReplicatedStorage.OceanTD.JoinIntroPackage for clients
	Clients clone from the package only after JoinIntroPackageReady is set —
	never from the live streaming Intro tree.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local JoinIntroPackageService = {}

local ATTR_READY = "JoinIntroPackageReady"
local ATTR_PART_COUNT = "JoinIntroPackagePartCount"
local SNAPSHOT_NAME = "OceanTD_IntroSnapshot"
local PACKAGE_NAME = "JoinIntroPackage"

local built = false

local function log(...: any)
	print("[JoinIntroPackage]", ...)
end

local function warnPkg(...: any)
	warn("[JoinIntroPackage]", ...)
end

local function oceanRoot(): Instance
	return ReplicatedStorage:WaitForChild("OceanTD")
end

local function countParts(root: Instance): number
	local n = 0
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("BasePart") then
			n += 1
		end
	end
	return n
end

local function waitIntroStable(intro: Instance, quietSec: number, timeoutSec: number): number
	local deadline = os.clock() + timeoutSec
	local lastCount = -1
	local quietSince = os.clock()
	while os.clock() < deadline do
		local n = countParts(intro)
		if n ~= lastCount then
			lastCount = n
			quietSince = os.clock()
		elseif n > 0 and (os.clock() - quietSince) >= quietSec then
			return n
		end
		task.wait(0.1)
	end
	return math.max(0, lastCount)
end

local function ensureSnapshotFolder(): Folder
	local existing = ServerStorage:FindFirstChild(SNAPSHOT_NAME)
	if existing and existing:IsA("Folder") then
		return existing
	end
	if existing then
		existing:Destroy()
	end
	local folder = Instance.new("Folder")
	folder.Name = SNAPSHOT_NAME
	folder.Parent = ServerStorage
	return folder
end

local function clearChildren(parent: Instance)
	for _, ch in ipairs(parent:GetChildren()) do
		ch:Destroy()
	end
end

function JoinIntroPackageService.isReady(): boolean
	local root = ReplicatedStorage:FindFirstChild("OceanTD")
	return root ~= nil and root:GetAttribute(ATTR_READY) == true
end

function JoinIntroPackageService.getPartCount(): number
	local root = ReplicatedStorage:FindFirstChild("OceanTD")
	local n = root and root:GetAttribute(ATTR_PART_COUNT)
	return if typeof(n) == "number" then n else 0
end

-- Build ServerStorage snapshot + publish ReplicatedStorage package. Idempotent.
function JoinIntroPackageService.build(): boolean
	if built and JoinIntroPackageService.isReady() then
		return true
	end

	local root = oceanRoot()
	root:SetAttribute(ATTR_READY, false)

	local plots = Workspace:FindFirstChild("Plots") or Workspace:WaitForChild("Plots", 30)
	if not plots then
		warnPkg("Workspace.Plots missing — cannot build package")
		return false
	end
	local intro = plots:FindFirstChild("Intro") or plots:WaitForChild("Intro", 60)
	if not intro then
		warnPkg("Workspace.Plots.Intro missing — cannot build package")
		return false
	end

	local partCount = waitIntroStable(intro, 0.5, 45)
	if partCount < 1 then
		warnPkg("Intro has 0 parts after wait — package empty")
	else
		log("Intro stable parts=", partCount)
	end

	-- 1) Frozen server-only snapshot (rebuild each boot).
	local snapFolder = ensureSnapshotFolder()
	clearChildren(snapFolder)
	local snapIntro = intro:Clone()
	snapIntro.Name = "Intro"
	snapIntro.Parent = snapFolder
	log("ServerStorage snapshot ready parts=", countParts(snapIntro))

	-- 2) Client-facing package (single published copy from the snapshot).
	local existingPkg = root:FindFirstChild(PACKAGE_NAME)
	if existingPkg then
		existingPkg:Destroy()
	end
	local package = Instance.new("Folder")
	package.Name = PACKAGE_NAME
	local pubIntro = snapIntro:Clone()
	pubIntro.Name = "Intro"
	pubIntro.Parent = package
	package.Parent = root

	local publishedParts = countParts(pubIntro)
	root:SetAttribute(ATTR_PART_COUNT, publishedParts)
	root:SetAttribute(ATTR_READY, true)
	built = true
	log("Published ReplicatedStorage.OceanTD.JoinIntroPackage parts=", publishedParts)
	return true
end

function JoinIntroPackageService.init()
	task.spawn(function()
		local ok, err = pcall(function()
			JoinIntroPackageService.build()
		end)
		if not ok then
			warnPkg("build failed:", err)
			local root = ReplicatedStorage:FindFirstChild("OceanTD")
			if root then
				root:SetAttribute(ATTR_READY, false)
			end
		end
	end)
end

return JoinIntroPackageService
