--!strict
--[[ Apply server stackMoves (size reflow / recycle reparent) to local placed brains. ]]

local TweenService = game:GetService("TweenService")

local PlacedCoralIndex = require(script.Parent:WaitForChild("PlacedCoralIndex"))
local ClientPlot = require(script.Parent:WaitForChild("ClientPlot"))

local BrainStackClient = {}

function BrainStackClient.applyStackMoves(stackMoves: any, tweenSec: number?)
	if typeof(stackMoves) ~= "table" then
		return
	end
	local plot = ClientPlot.get()
	if not plot then
		return
	end
	local RelocateController = require(script.Parent:WaitForChild("RelocateController"))
	local byId: { [string]: BasePart } = {}
	for _, p in ipairs(PlacedCoralIndex.getParts(plot.plotId)) do
		local id = p:GetAttribute("OceanTD_PlaceId")
		if typeof(id) == "string" then
			byId[id] = p
		end
	end
	local dur = if typeof(tweenSec) == "number" then tweenSec else 0.28
	local selected = RelocateController.getSelectedPart and RelocateController.getSelectedPart()
	for _, sm in ipairs(stackMoves) do
		if typeof(sm) == "table" and typeof(sm.placeId) == "string" and typeof(sm.worldPos) == "Vector3" then
			local part = byId[sm.placeId]
			if part and part.Parent then
				if typeof(sm.stackParentPlaceId) == "string" and sm.stackParentPlaceId ~= "" then
					part:SetAttribute("OceanTD_ParentPlaceId", sm.stackParentPlaceId)
				else
					part:SetAttribute("OceanTD_ParentPlaceId", nil)
				end
				local goal = CFrame.new(sm.worldPos)
				if dur > 0.02 then
					TweenService:Create(part, TweenInfo.new(dur, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
						CFrame = goal,
					}):Play()
				else
					part.CFrame = goal
				end
				PlacedCoralIndex.reindex(part)
			end
		end
	end
	-- After reflow, relocate "home" must be the lifted pose or ✓/aim will snap back down.
	local function syncHomes()
		for _, sm in ipairs(stackMoves) do
			if typeof(sm) == "table" and typeof(sm.placeId) == "string" and typeof(sm.worldPos) == "Vector3" then
				local part = byId[sm.placeId]
				if part and part.Parent then
					part.CFrame = CFrame.new(sm.worldPos)
					PlacedCoralIndex.reindex(part)
					if selected and part == selected then
						RelocateController.syncHomeToPart(part)
					end
				end
			end
		end
		if selected and selected.Parent then
			RelocateController.syncHomeToPart(selected)
		end
	end
	if dur > 0.02 then
		task.delay(dur + 0.02, syncHomes)
	else
		syncHomes()
	end
end

return BrainStackClient
