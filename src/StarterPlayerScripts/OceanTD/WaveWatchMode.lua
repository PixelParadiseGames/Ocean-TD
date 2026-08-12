--!strict
--[[
	Shared visitor watch state for Slot5–7 chrome + HUD mirror.
]]

export type WatchSnap = {
	wave: number,
	reefHealth: number,
	reefMax: number,
	elapsedSec: number,
	running: boolean,
	feedProgress: number,
	feedComplete: boolean,
	hungerDanger: boolean,
	hungryMissToken: number,
	fishFull: number,
	fishTotal: number,
	speedMult: number,
	plotId: string,
	hostUserId: number,
	coralEpoch: number?,
	kind: string?,
	plotSizeStage: number?,
}

local WaveWatchMode = {}

local watching = false
local snap: WatchSnap? = nil
local changed = Instance.new("BindableEvent")

function WaveWatchMode.isWatching(): boolean
	return watching
end

function WaveWatchMode.getSnap(): WatchSnap?
	return snap
end

function WaveWatchMode.set(active: boolean, hudSnap: WatchSnap?)
	local prev = snap
	local was = watching
	watching = active
	snap = if active then hudSnap else nil

	local changedState = was ~= watching
	local changedHud = false
	if watching and snap and prev then
		changedHud = snap.wave ~= prev.wave
			or snap.running ~= prev.running
			or math.abs(snap.feedProgress - prev.feedProgress) >= 0.01
			or snap.reefHealth ~= prev.reefHealth
			or math.abs(snap.speedMult - prev.speedMult) >= 1e-4
			or snap.plotId ~= prev.plotId
			or snap.feedComplete ~= prev.feedComplete
			or snap.hungryMissToken ~= prev.hungryMissToken
			or snap.fishFull ~= prev.fishFull
			or math.floor(snap.elapsedSec) ~= math.floor(prev.elapsedSec)
	elseif watching and snap and not prev then
		changedHud = true
	end

	if changedState or changedHud then
		changed:Fire(watching, snap)
	end
end

function WaveWatchMode.onChanged(cb: (boolean, WatchSnap?) -> ()): RBXScriptConnection
	return changed.Event:Connect(cb)
end

return WaveWatchMode
