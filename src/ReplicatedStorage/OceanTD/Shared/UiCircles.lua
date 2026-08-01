-- Force square ImageLabels into circles via UICorner (no mask image).

local UiCircles = {}

local FULL = UDim.new(1, 0)

function UiCircles.ensure(gui: GuiObject): UICorner
	local corner = gui:FindFirstChildOfClass("UICorner")
	if not corner then
		corner = Instance.new("UICorner")
		corner.Parent = gui
	end
	corner.CornerRadius = FULL
	return corner
end

-- Touch templates often ship rounded-rect corners; force circles on slot descendants.
function UiCircles.forceOnDescendants(root: Instance)
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("UICorner") then
			d.CornerRadius = FULL
		end
	end
	if root:IsA("GuiObject") and root:FindFirstChild("Circle") then
		local circle = root:FindFirstChild("Circle")
		if circle and circle:IsA("GuiObject") then
			UiCircles.ensure(circle)
		end
	end
end

return UiCircles
