--!strict
--[[
	Robux → $D. MarketplaceService.ProcessReceipt is the only grant path.
	Unknown products are NotProcessedYet (Roblox refunds after retries).
	Duplicate PurchaseId → PurchaseGranted with no second credit.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local SandDollarProducts = require(oceanRoot:WaitForChild("Shared"):WaitForChild("SandDollarProducts"))

local PersistenceService = require(script.Parent:WaitForChild("PersistenceService"))

local EconomyService = {}

local function log(...: any)
	print("[ECONOMY]", ...)
end

local function processReceipt(info: any): Enum.ProductPurchaseDecision
	if typeof(info) ~= "table" then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	local productId = math.floor(tonumber(info.ProductId) or 0)
	local userId = math.floor(tonumber(info.PlayerId) or 0)
	local purchaseId = tostring(info.PurchaseId or "")
	if productId <= 0 or userId <= 0 or purchaseId == "" then
		warn("[ECONOMY] Bad receipt", productId, userId, purchaseId)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local pack = SandDollarProducts.fromProductId(productId)
	if not pack then
		warn("[ECONOMY] Unknown productId", productId, "userId=", userId, "— not granting")
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local status, balance = PersistenceService.grantSandDollarsFromReceipt(
		userId,
		purchaseId,
		productId,
		pack.sandDollars
	)
	if status == "granted" or status == "already" then
		log("PurchaseGranted", status, "userId=", userId, "pack=", pack.id, "+", pack.sandDollars, "balance=", balance)
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end
	warn("[ECONOMY] Grant failed; retry later userId=", userId, "purchaseId=", purchaseId)
	return Enum.ProductPurchaseDecision.NotProcessedYet
end

function EconomyService.init()
	MarketplaceService.ProcessReceipt = processReceipt
	log("ProcessReceipt armed — $D packs", #SandDollarProducts.configured(), "configured")
end

return EconomyService
