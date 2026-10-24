--!strict
--[[
	Robux → $D. MarketplaceService.ProcessReceipt is the only grant path.
	Unknown products are NotProcessedYet (Roblox refunds after retries).
	The same pack can be bought any number of times. Each purchase has its own
	PurchaseId and grants $D again. A retried receipt for one purchase does not.
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

local function ensureIdFolder(): Folder
	local folder = oceanRoot:FindFirstChild(SandDollarProducts.RESOLVED_FOLDER)
	if folder and folder:IsA("Folder") then
		return folder
	end
	if folder then
		folder:Destroy()
	end
	local made = Instance.new("Folder")
	made.Name = SandDollarProducts.RESOLVED_FOLDER
	made.Parent = oceanRoot
	return made
end

local function listDeveloperProducts(): { { productId: number, price: number, name: string } }
	local out: { { productId: number, price: number, name: string } } = {}
	local ok, pagesOrErr = pcall(function()
		return MarketplaceService:GetDeveloperProductsAsync()
	end)
	if not ok or pagesOrErr == nil then
		warn("[ECONOMY] Could not list Developer Products", pagesOrErr)
		return out
	end
	local pages = pagesOrErr
	while true do
		for _, info in ipairs(pages:GetCurrentPage()) do
			local productId = math.floor(tonumber(info.ProductId) or 0)
			local price = math.floor(tonumber(info.PriceInRobux) or 0)
			if productId > 0 and price > 0 then
				table.insert(out, {
					productId = productId,
					price = price,
					name = tostring(info.Name or ""),
				})
			end
		end
		if pages.IsFinished then
			break
		end
		local advanced = pcall(function()
			pages:AdvanceToNextPageAsync()
		end)
		if not advanced then
			break
		end
	end
	return out
end

local function resolveProductIds(folder: Folder)
	local listed = listDeveloperProducts()
	for _, pack in ipairs(SandDollarProducts.all()) do
		local chosen = if pack.productId > 0 then pack.productId else 0
		if chosen <= 0 then
			local matches: { { productId: number, price: number, name: string } } = {}
			for _, info in ipairs(listed) do
				if info.price == pack.robux then
					table.insert(matches, info)
				end
			end
			if #matches == 1 then
				chosen = matches[1].productId
			elseif #matches > 1 then
				local amount = tostring(pack.sandDollars)
				for _, info in ipairs(matches) do
					if string.find(info.name, amount, 1, true) then
						chosen = info.productId
						break
					end
				end
				if chosen <= 0 then
					chosen = matches[1].productId
					warn("[ECONOMY] Several", pack.robux, "Robux products — using", chosen, "for", pack.id)
				end
			end
		end
		if chosen > 0 then
			SandDollarProducts.assignProductId(pack.id, chosen)
			folder:SetAttribute(pack.id, chosen)
			log("Pack", pack.id, pack.sandDollars, "$D ← product", chosen, "(", pack.robux, "Robux)")
		else
			folder:SetAttribute(pack.id, 0)
			warn(
				"[ECONOMY] No Developer Product for",
				pack.robux,
				"Robux (",
				pack.sandDollars,
				"$D). Create one, or set productId on",
				pack.id,
				"in SandDollarProducts.lua"
			)
		end
	end
	folder:SetAttribute("Ready", true)
end

function EconomyService.init()
	MarketplaceService.ProcessReceipt = processReceipt
	local folder = ensureIdFolder()
	folder:SetAttribute("Ready", false)
	for _, pack in ipairs(SandDollarProducts.all()) do
		if folder:GetAttribute(pack.id) == nil then
			folder:SetAttribute(pack.id, 0)
		end
	end
	task.spawn(function()
		resolveProductIds(folder)
	end)
	log("ProcessReceipt armed — $D packs", #SandDollarProducts.all())
end

return EconomyService
