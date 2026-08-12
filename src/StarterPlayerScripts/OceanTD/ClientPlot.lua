--!strict
-- Client mirror of the local player's plot bounds.

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local oceanShared = ReplicatedStorage:WaitForChild("OceanTD"):WaitForChild("Shared")
local Constants = require(oceanShared:WaitForChild("Constants"))
local GridMath = require(oceanShared:WaitForChild("GridMath"))

export type MirroredPlot = {
	plotId: string,
	cframe: CFrame,
	size: Vector3,
	spawnCFrame: CFrame?,
	plot1CFrame: CFrame?,
	ringCFrame: CFrame?,
}

local ClientPlot = {}

local mirrored: MirroredPlot? = nil
local ready = false
local changed = Instance.new("BindableEvent")
local plot1CfCache: CFrame? = nil
local plot1CfFromServer: CFrame? = nil

-- Local-only hollow red plastic outline (floor + 4 walls) — visible from inside the plot.
local flashFolder: Folder? = nil
local flashParts: { BasePart } = {}
local flashConn: RBXScriptConnection? = nil
local flashActive = false

local WALL_THICK = 1.2
local FLOOR_THICK = 1.0
local FLASH_RED = Color3.fromRGB(255, 45, 45)

local function destroyOutOfPlotFlash()
	flashActive = false
	if flashConn then
		flashConn:Disconnect()
		flashConn = nil
	end
	if flashFolder then
		flashFolder:Destroy()
		flashFolder = nil
	end
	table.clear(flashParts)
end

local function makeFlashPanel(name: string, parent: Instance): BasePart
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.Plastic
	p.Color = FLASH_RED
	p.Transparency = 0.5
	p.Parent = parent
	return p
end

-- Hollow shell so faces read from inside the plot (a solid box only shows outer faces).
local function layoutFlashParts(cf: CFrame, size: Vector3)
	local sx, sy, sz = size.X, size.Y, size.Z
	local wallH = math.max(sy, 4)
	local floorY = -sy * 0.5 + FLOOR_THICK * 0.5

	-- Floor footprint
	local floor = flashParts[1]
	if floor then
		floor.Size = Vector3.new(sx, FLOOR_THICK, sz)
		floor.CFrame = cf * CFrame.new(0, floorY, 0)
	end

	-- +Z / -Z walls (span X)
	local wallZ = flashParts[2]
	if wallZ then
		wallZ.Size = Vector3.new(sx, wallH, WALL_THICK)
		wallZ.CFrame = cf * CFrame.new(0, 0, sz * 0.5 - WALL_THICK * 0.5)
	end
	local wallZn = flashParts[3]
	if wallZn then
		wallZn.Size = Vector3.new(sx, wallH, WALL_THICK)
		wallZn.CFrame = cf * CFrame.new(0, 0, -sz * 0.5 + WALL_THICK * 0.5)
	end

	-- +X / -X walls (span Z, inset so corners don't double-stack)
	local innerZ = math.max(sz - WALL_THICK * 2, 1)
	local wallX = flashParts[4]
	if wallX then
		wallX.Size = Vector3.new(WALL_THICK, wallH, innerZ)
		wallX.CFrame = cf * CFrame.new(sx * 0.5 - WALL_THICK * 0.5, 0, 0)
	end
	local wallXn = flashParts[5]
	if wallXn then
		wallXn.Size = Vector3.new(WALL_THICK, wallH, innerZ)
		wallXn.CFrame = cf * CFrame.new(-sx * 0.5 + WALL_THICK * 0.5, 0, 0)
	end
end

local function ensureOutOfPlotFlash(): boolean
	if not mirrored then
		return false
	end
	if flashFolder and flashFolder.Parent and #flashParts >= 5 then
		layoutFlashParts(mirrored.cframe, mirrored.size)
		return true
	end
	destroyOutOfPlotFlash()
	flashActive = true

	local folder = Instance.new("Folder")
	folder.Name = "OceanTD_PlotBoundsFlash"
	local cam = Workspace.CurrentCamera
	folder.Parent = cam or Workspace
	flashFolder = folder

	table.insert(flashParts, makeFlashPanel("Floor", folder))
	table.insert(flashParts, makeFlashPanel("WallZ", folder))
	table.insert(flashParts, makeFlashPanel("WallZn", folder))
	table.insert(flashParts, makeFlashPanel("WallX", folder))
	table.insert(flashParts, makeFlashPanel("WallXn", folder))
	layoutFlashParts(mirrored.cframe, mirrored.size)
	return true
end

function ClientPlot.set(payload: MirroredPlot)
	mirrored = payload
	if payload.plot1CFrame then
		plot1CfFromServer = payload.plot1CFrame
		plot1CfCache = payload.plot1CFrame
	elseif payload.plotId == "Plot1" then
		plot1CfFromServer = payload.cframe
		plot1CfCache = payload.cframe
	end
	if flashActive then
		ensureOutOfPlotFlash()
	end
	changed:Fire(mirrored)
end

function ClientPlot.clear()
	mirrored = nil
	ready = false
	plot1CfFromServer = nil
	plot1CfCache = nil
	destroyOutOfPlotFlash()
	changed:Fire(nil)
end

function ClientPlot.markReady()
	ready = true
end

function ClientPlot.get(): MirroredPlot?
	return mirrored
end

function ClientPlot.isReady(): boolean
	return ready
end

-- Plot1 authored space (WaveRoute, EndPoint heart, etc.).
-- Prefer server-sent MasterTerrainBox pose — clients often cannot see it after Hide Previews.
function ClientPlot.getPlot1CFrame(): CFrame?
	if plot1CfCache then
		return plot1CfCache
	end
	if plot1CfFromServer then
		plot1CfCache = plot1CfFromServer
		return plot1CfCache
	end
	if mirrored and mirrored.plot1CFrame then
		plot1CfCache = mirrored.plot1CFrame
		return plot1CfCache
	end
	local master = Workspace:FindFirstChild(Constants.MASTER_TERRAIN_NAME)
	if master and master:IsA("BasePart") then
		plot1CfCache = master.CFrame
		return plot1CfCache
	end
	local plots = Workspace:FindFirstChild(Constants.PLOT_FOLDER_NAME)
	local p1 = plots and plots:FindFirstChild("Plot1")
	local bounds = p1 and p1:FindFirstChild(Constants.BOUNDS_NAME)
	if bounds and bounds:IsA("BasePart") then
		plot1CfCache = bounds.CFrame
		return plot1CfCache
	end
	if mirrored and mirrored.plotId == "Plot1" then
		plot1CfCache = mirrored.cframe
		return plot1CfCache
	end
	return nil
end

-- Map a Plot1-authored world point onto the local player's plot (rigid).
-- Server plot CFrames are Master + RingMath — same family as place/save/décor.
function ClientPlot.remapFromPlot1(worldPos: Vector3): Vector3
	local localPlot = mirrored
	if not localPlot then
		return worldPos
	end
	local p1 = ClientPlot.getPlot1CFrame()
	if not p1 then
		warn("[PLOT] remapFromPlot1: missing Plot1 CFrame; leaving point on Plot1 (", localPlot.plotId, ")")
		return worldPos
	end
	local base = localPlot.ringCFrame or localPlot.cframe
	return base * p1:PointToObjectSpace(worldPos)
end

-- Map a Plot1-authored CFrame onto the local player's plot (preserves orientation).
function ClientPlot.remapCFrameFromPlot1(worldCf: CFrame): CFrame
	local localPlot = mirrored
	if not localPlot then
		return worldCf
	end
	local p1 = ClientPlot.getPlot1CFrame()
	if not p1 then
		warn("[PLOT] remapCFrameFromPlot1: missing Plot1 CFrame; leaving on Plot1 (", localPlot.plotId, ")")
		return worldCf
	end
	local base = localPlot.ringCFrame or localPlot.cframe
	return base * p1:ToObjectSpace(worldCf)
end

-- Remap into an arbitrary plot (spectate / ghost waves).
function ClientPlot.remapFromPlot1To(worldPos: Vector3, _targetPlotId: string, targetCf: CFrame, _targetSize: Vector3): Vector3
	local p1 = ClientPlot.getPlot1CFrame()
	if not p1 then
		return worldPos
	end
	return targetCf * p1:PointToObjectSpace(worldPos)
end

function ClientPlot.onChanged(cb: (MirroredPlot?) -> ()): RBXScriptConnection
	return changed.Event:Connect(cb)
end

function ClientPlot.isInside(worldPos: Vector3): boolean
	if not mirrored then
		return false
	end
	return GridMath.isInsidePlotXZ(worldPos, mirrored.cframe, mirrored.size)
end

-- Show / hide a flashing ~0.5-transparent red plastic plot outline (visible while standing inside).
function ClientPlot.setOutOfPlotFlash(enabled: boolean)
	if not enabled or not mirrored then
		destroyOutOfPlotFlash()
		return
	end
	flashActive = true
	if not ensureOutOfPlotFlash() then
		destroyOutOfPlotFlash()
		return
	end
	if flashConn then
		return
	end
	flashConn = RunService.RenderStepped:Connect(function()
		if not flashActive or not flashFolder or not flashFolder.Parent then
			return
		end
		if mirrored then
			layoutFlashParts(mirrored.cframe, mirrored.size)
		end
		local wave = (math.sin(os.clock() * 7) + 1) * 0.5
		local t = 0.35 + wave * 0.3
		local color = FLASH_RED:Lerp(Color3.fromRGB(255, 120, 120), wave * 0.35)
		for _, p in ipairs(flashParts) do
			p.Transparency = t
			p.Color = color
		end
	end)
end

return ClientPlot
