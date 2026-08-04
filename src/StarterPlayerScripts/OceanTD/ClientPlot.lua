--!strict
-- Client mirror of the local player's plot bounds.

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local GridMath = require(ReplicatedStorage:WaitForChild("OceanTD"):WaitForChild("Shared"):WaitForChild("GridMath"))

export type MirroredPlot = {
	plotId: string,
	cframe: CFrame,
	size: Vector3,
	spawnCFrame: CFrame?,
}

local ClientPlot = {}

local mirrored: MirroredPlot? = nil
local ready = false
local changed = Instance.new("BindableEvent")

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
	if flashActive then
		ensureOutOfPlotFlash()
	end
	changed:Fire(mirrored)
end

function ClientPlot.clear()
	mirrored = nil
	ready = false
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
