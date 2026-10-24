--!strict
--[[
	Robux developer products that grant $D (sand dollars).

	productId 0 = look up a Developer Product with the same Robux price
	(Creator Dashboard → Monetization → Developer Products).
	Paste an id here to force that product instead of the price lookup.

	Server ProcessReceipt is the only grant path. Client never adds $D.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

export type Pack = {
	id: string,
	name: string,
	sandDollars: number,
	robux: number,
	productId: number,
}

local PACKS: { Pack } = {
	{ id = "d500", name = "500 $D", sandDollars = 500, robux = 100, productId = 3721708618 },
	{ id = "d3000", name = "3,000 $D", sandDollars = 3000, robux = 500, productId = 3721708784 },
	{ id = "d7000", name = "7,000 $D", sandDollars = 7000, robux = 1000, productId = 3721708899 },
}

local BY_ID: { [string]: Pack } = {}
local BY_PRODUCT: { [number]: Pack } = {}

local function indexPacks()
	table.clear(BY_ID)
	table.clear(BY_PRODUCT)
	for _, pack in ipairs(PACKS) do
		BY_ID[pack.id] = pack
		if pack.productId > 0 then
			BY_PRODUCT[pack.productId] = pack
		end
	end
end

indexPacks()

local SandDollarProducts = {}

SandDollarProducts.RESOLVED_FOLDER = "SandDollarProductIds"

function SandDollarProducts.all(): { Pack }
	return PACKS
end

function SandDollarProducts.fromId(packId: string): Pack?
	return BY_ID[packId]
end

function SandDollarProducts.configured(): { Pack }
	local out: { Pack } = {}
	for _, pack in ipairs(PACKS) do
		if pack.productId > 0 and pack.sandDollars > 0 then
			table.insert(out, pack)
		end
	end
	return out
end

function SandDollarProducts.fromProductId(productId: number): Pack?
	local id = math.floor(tonumber(productId) or 0)
	if id <= 0 then
		return nil
	end
	return BY_PRODUCT[id]
end

function SandDollarProducts.hasConfigured(): boolean
	return #SandDollarProducts.configured() > 0
end

-- Server-only. Registers the Developer Product that grants this pack.
function SandDollarProducts.assignProductId(packId: string, productId: number)
	local pack = BY_ID[packId]
	local id = math.floor(tonumber(productId) or 0)
	if not pack or id <= 0 then
		return
	end
	if pack.productId > 0 and pack.productId ~= id then
		BY_PRODUCT[pack.productId] = nil
	end
	pack.productId = id
	BY_PRODUCT[id] = pack
end

-- Id the client should prompt. Folder attributes win (filled by the server lookup).
function SandDollarProducts.liveProductId(packId: string): number
	local ocean = ReplicatedStorage:FindFirstChild("OceanTD")
	local folder = ocean and ocean:FindFirstChild(SandDollarProducts.RESOLVED_FOLDER)
	local live = folder and folder:GetAttribute(packId)
	if typeof(live) == "number" and live > 0 then
		return math.floor(live)
	end
	local pack = BY_ID[packId]
	if pack and pack.productId > 0 then
		return pack.productId
	end
	return 0
end

return SandDollarProducts
