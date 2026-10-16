--!strict
--[[
	TEMP: shared helpers for missing→teal red-dot debug.
	Client script HueDefaultDebug.client.lua drives Workspace watchers.
]]

local Workspace = game:GetService("Workspace")

local HueDefaultDebug = {}

local RED = Color3.fromRGB(255, 40, 40)
local dots: { [BasePart]: BasePart } = {}
local folder: Folder? = nil
local active = true

local function ensureFolder(): Folder
	local f = folder
	if f and f.Parent then
		return f
	end
	f = Instance.new("Folder")
	f.Name = "OceanTD_HueDefaultDebug"
	f.Parent = Workspace
	folder = f
	return f
end

local function topY(part: BasePart): number
	local cf = part.CFrame
	local size = part.Size
	return (cf * CFrame.new(0, size.Y * 0.5, 0)).Position.Y
end

function HueDefaultDebug.setActive(on: boolean)
	active = on == true
	if not active then
		HueDefaultDebug.clearAll()
	end
end

function HueDefaultDebug.isActive(): boolean
	return active
end

function HueDefaultDebug.destroyDot(coral: BasePart)
	local d = dots[coral]
	if d then
		d:Destroy()
		dots[coral] = nil
	end
end

function HueDefaultDebug.clearAll()
	for coral in pairs(dots) do
		HueDefaultDebug.destroyDot(coral)
	end
	if folder then
		folder:Destroy()
		folder = nil
	end
end

function HueDefaultDebug.attachDot(coral: BasePart)
	if not active or not coral.Parent then
		return
	end
	if dots[coral] and dots[coral].Parent then
		return
	end
	local f = ensureFolder()
	local dot = Instance.new("Part")
	dot.Name = "HueDefaultDot"
	dot.Shape = Enum.PartType.Ball
	dot.Anchored = true
	dot.CanCollide = false
	dot.CanQuery = false
	dot.CanTouch = false
	dot.CastShadow = false
	dot.Material = Enum.Material.Neon
	dot.Color = RED
	dot.Size = Vector3.new(1.1, 1.1, 1.1)
	dot.Transparency = 0
	local y = topY(coral) + 2.2
	dot.CFrame = CFrame.new(coral.Position.X, y, coral.Position.Z)
	dot.Parent = f
	dots[coral] = dot

	task.spawn(function()
		while dot.Parent and coral.Parent and active do
			local yy = topY(coral) + 2.2
			dot.CFrame = CFrame.new(coral.Position.X, yy, coral.Position.Z)
			dot.Transparency = 0
			task.wait(0.05)
		end
		HueDefaultDebug.destroyDot(coral)
	end)
end

return HueDefaultDebug
