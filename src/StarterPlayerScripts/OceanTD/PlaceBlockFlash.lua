--!strict
--[[
	"Spot taken" neon flash on placed coral during aim.
	Extracted so PlacementController stays under Luau's 200-local limit.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local CoralVisual = require(oceanRoot:WaitForChild("Shared"):WaitForChild("CoralVisual"))

local PlaceBlockFlash = {}

local blockFlashPart: BasePart? = nil
local blockFlashBaseMaterial: Enum.Material? = nil
local blockFlashBaseColor: Color3? = nil

function PlaceBlockFlash.clear()
	if blockFlashPart and blockFlashPart.Parent then
		if blockFlashBaseMaterial then
			blockFlashPart.Material = blockFlashBaseMaterial
		end
		if blockFlashBaseColor then
			blockFlashPart.Color = blockFlashBaseColor
		end
	end
	blockFlashPart = nil
	blockFlashBaseMaterial = nil
	blockFlashBaseColor = nil
end

function PlaceBlockFlash.set(target: BasePart?)
	if blockFlashPart == target then
		return
	end
	PlaceBlockFlash.clear()
	if not target or not target.Parent then
		return
	end
	pcall(function()
		local Relocate = require(script.Parent:WaitForChild("RelocateController"))
		if typeof(Relocate.clearHoverHighlight) == "function" then
			Relocate.clearHoverHighlight()
		end
	end)
	local restMat, restColor = CoralVisual.readRestLook(target)
	CoralVisual.applyRestLook(target)
	blockFlashPart = target
	blockFlashBaseMaterial = restMat
	blockFlashBaseColor = restColor
	target.Material = Enum.Material.Neon
end

function PlaceBlockFlash.update()
	if not blockFlashPart or not blockFlashPart.Parent then
		if blockFlashPart then
			PlaceBlockFlash.clear()
		end
		return
	end
	local pulse = (math.sin(os.clock() * 12) + 1) * 0.5
	blockFlashPart.Material = Enum.Material.Neon
	blockFlashPart.Color = Color3.new(1, 1, 1):Lerp(Color3.fromRGB(255, 45, 45), pulse)
end

function PlaceBlockFlash.syncForAim(
	worldPos: Vector3?,
	aimPinnedToHand: boolean,
	validSpot: boolean,
	rejectReason: string?,
	blockingPart: BasePart?
)
	if aimPinnedToHand or not worldPos or validSpot or rejectReason ~= "Spot Taken" then
		PlaceBlockFlash.clear()
		return
	end
	PlaceBlockFlash.set(blockingPart)
end

return PlaceBlockFlash
