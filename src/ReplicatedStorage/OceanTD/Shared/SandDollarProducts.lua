--!strict
--[[
	Robux developer products that grant $D (sand dollars).

	Paste product IDs from Creator Dashboard → Monetization → Developer Products.
	productId 0 = not configured (will not prompt / will not grant).

	Server ProcessReceipt is the only grant path. Client never adds $D.
]]

export type Pack = {
	id: string,
	name: string,
	sandDollars: number,
	productId: number,
}

local PACKS: { Pack } = {
	{ id = "d100", name = "100 $D", sandDollars = 100, productId = 0 },
	{ id = "d500", name = "500 $D", sandDollars = 500, productId = 0 },
	{ id = "d1200", name = "1,200 $D", sandDollars = 1200, productId = 0 },
	{ id = "d3000", name = "3,000 $D", sandDollars = 3000, productId = 0 },
}

local BY_PRODUCT: { [number]: Pack } = {}
for _, pack in ipairs(PACKS) do
	if pack.productId > 0 then
		BY_PRODUCT[pack.productId] = pack
	end
end

local SandDollarProducts = {}

function SandDollarProducts.all(): { Pack }
	return PACKS
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

return SandDollarProducts
