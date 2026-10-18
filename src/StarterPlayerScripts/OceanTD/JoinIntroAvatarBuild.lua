--!strict
--[[
	Join-intro: sped-up avatar dash→dig timeline chasing sample corals as they land.
	Intro camera owns the lens (no dig close-up).
]]

local PlantWorkerVfx = require(script.Parent:WaitForChild("PlantWorkerVfx"))

local JoinIntroAvatarBuild = {}

type Job = {
	worldPos: Vector3,
	coralPart: BasePart?,
}

local queue: { Job } = {}
local running = false
local active = false
local cancelled = false
-- After ADD MAX orbs finish: remaining digs run at 2× the already-fast intro pace.
local rush = false

local function dashWorkSecs(): (number, number)
	if rush then
		return 0.07, 0.105
	end
	return 0.14, 0.21
end

local function pump()
	if running or not active or cancelled then
		return
	end
	local job = table.remove(queue, 1)
	if not job then
		return
	end
	running = true
	local dashSec, workSec = dashWorkSecs()
	local ok = PlantWorkerVfx.playAt(job.worldPos, {
		coralPart = job.coralPart,
		forceAvatar = true,
		skipDigCam = true,
		dashSec = dashSec,
		workSec = workSec,
		playWow = false,
		onDone = function()
			running = false
			if active and not cancelled then
				task.defer(pump)
			end
		end,
	})
	if not ok then
		running = false
		task.defer(pump)
	end
end

function JoinIntroAvatarBuild.begin()
	cancelled = false
	active = true
	rush = false
	table.clear(queue)
	running = false
end

function JoinIntroAvatarBuild.enqueue(worldPos: Vector3, coralPart: BasePart?)
	if not active or cancelled then
		return
	end
	if typeof(worldPos) ~= "Vector3" then
		return
	end
	-- Cap backlog so fill bursts don't queue minutes of digs.
	if #queue >= 48 then
		return
	end
	table.insert(queue, { worldPos = worldPos, coralPart = coralPart })
	pump()
end

-- 2× remaining digs so the demo can advance ~1s sooner after ADD MAX.
function JoinIntroAvatarBuild.rushRemaining()
	if not active or cancelled then
		return
	end
	rush = true
	if running then
		pcall(function()
			PlantWorkerVfx.cancel()
		end)
		running = false
		task.defer(pump)
	end
end

function JoinIntroAvatarBuild.waitDrain(timeoutSec: number?)
	local timeout = if typeof(timeoutSec) == "number" then math.max(0.05, timeoutSec) else 2.5
	local deadline = os.clock() + timeout
	while active and not cancelled and (running or #queue > 0) and os.clock() < deadline do
		task.wait(0.04)
	end
end

function JoinIntroAvatarBuild.finish()
	cancelled = true
	active = false
	rush = false
	table.clear(queue)
	running = false
	pcall(function()
		PlantWorkerVfx.cancel()
	end)
end

return JoinIntroAvatarBuild
