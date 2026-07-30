--[[
  EMERGENCY FALLBACK ONLY — prefer the Studio plot-stamp plugin.

  Primary workflow: author MasterTerrainBox + Arena.Center, run the plugin
  (green master + N−1 red previews → stamp → StaticPlot décor clones).
  See docs/STUDIO_CONTRACT.md.

  This snippet only creates legacy Workspace.Plots.PlotN.Bounds if you cannot
  use the plugin. It does NOT stamp terrain or clone décor.
]]

local Workspace = game:GetService("Workspace")

local function ensureFolder(parent, name)
	local f = parent:FindFirstChild(name)
	if f then
		return f
	end
	f = Instance.new("Folder")
	f.Name = name
	f.Parent = parent
	return f
end

warn("[PLOT] Using legacy Bounds scaffold — prefer MasterTerrainBox plugin workflow.")

local plots = ensureFolder(Workspace, "Plots")
local arena = ensureFolder(Workspace, "Arena")
local centerFolder = ensureFolder(arena, "Center")
if not centerFolder:FindFirstChildWhichIsA("BasePart") then
	local c = Instance.new("Part")
	c.Name = "Origin"
	c.Anchored = true
	c.CanCollide = false
	c.Transparency = 1
	c.Size = Vector3.new(4, 4, 4)
	c.Position = Vector3.new(0, 0, 0)
	c.Parent = centerFolder
end

local radius = 400
for i = 1, 6 do
	local name = "Plot" .. i
	local folder = plots:FindFirstChild(name)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = name
		folder.Parent = plots
	end

	local bounds = folder:FindFirstChild("Bounds")
	if not bounds then
		bounds = Instance.new("Part")
		bounds.Name = "Bounds"
		bounds.Anchored = true
		bounds.CanCollide = false
		bounds.Transparency = 0.7
		bounds.Color = Color3.fromRGB(0, 200, 255)
		bounds.Size = Vector3.new(230, 80, 200)
		bounds.Parent = folder
	end

	local angle = (i - 1) * (math.pi * 2 / 6)
	bounds.CFrame = CFrame.new(math.cos(angle) * radius, 40, math.sin(angle) * radius)
		* CFrame.Angles(0, -angle, 0)
end

print("[PLOT] Legacy Plots.Plot1..6 Bounds scaffolded.")
