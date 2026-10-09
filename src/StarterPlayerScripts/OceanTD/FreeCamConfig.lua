--!strict
--[[
	Constants for FreeCam.client.lua (keeps that chunk under Luau's 200-local limit).
]]

export type CamMode = "off" | "plotcam" | "fishcam" | "dronecam"

local FreeCamConfig = {}

FreeCamConfig.RED = Color3.fromRGB(255, 40, 40)
FreeCamConfig.GREEN = Color3.fromRGB(40, 255, 70)
FreeCamConfig.FISH_CYAN = Color3.fromRGB(40, 200, 220)
FreeCamConfig.DRONE_AMBER = Color3.fromRGB(255, 190, 60)
FreeCamConfig.STROKE_NAME = "_OceanTD_FreeCamStroke"
FreeCamConfig.STROKE_THICK = 3
FreeCamConfig.MOVE_SPEED = 48 * 1.3 -- +30%
FreeCamConfig.TOUCH_STICK_RADIUS = 90
FreeCamConfig.SINK_ACTION = "OceanTD_FreeCamSink"
FreeCamConfig.DPAD_ACTION = "OceanTD_FreeCamDPad"
FreeCamConfig.MARGIN = 0.75
-- Focus / body follow. Small errors track tightly; large waypoint jerks ease in.
FreeCamConfig.FISH_DAMP_RATE = 1.35 -- snappy when already on the fish
FreeCamConfig.FISH_DAMP_RATE_SOFT = 0.4 -- when focus error is large (corner / lateral whip)
FreeCamConfig.FISH_DAMP_SOFT_STUDS = 3.25 -- start blending toward soft rate above this error
FreeCamConfig.FISH_CAM_RATE = 1.25
FreeCamConfig.FISH_LOOK_RATE = 0.7 -- look-at lags focus so corner jerks don't whip yaw/pitch
FreeCamConfig.FISH_FOCUS_MAX_SPEED = 24 -- studs/sec cap (above fish ~18 so chase isn't starved)
FreeCamConfig.FISH_SWITCH_SEC = 3.5
FreeCamConfig.FISH_CHASE_DIST = 31.2
FreeCamConfig.FISH_CHASE_HEIGHT = 12
FreeCamConfig.FISH_ORBIT_SEC = 120
FreeCamConfig.FISH_DIST_BREATHE_SEC = 60
FreeCamConfig.FISH_DIST_BREATHE_MAX = 2.5
FreeCamConfig.FISH_ORBIT_SLOW_MAX = 3
FreeCamConfig.LOOK_SENS_MOUSE = 0.006
FreeCamConfig.LOOK_SENS_STICK = 2.4
FreeCamConfig.LOOK_SENS_TOUCH = 0.008
FreeCamConfig.LOOK_SENS_KEYS = 1.8
FreeCamConfig.ATTR_MODE = "OceanTD_CamCycleMode"
FreeCamConfig.ATTR_CINEMATIC_RESUME_MODE = "OceanTD_CinematicResumeMode"

-- PlotCam cycle: 1 = legacy SkyCam free-fly (Plot Cam 1), 2 = locked RTS god-cam (Plot Cam 2).
FreeCamConfig.PLOT_CAM_VARIANT = 2

FreeCamConfig.MODE_ORDER = { "off", "plotcam", "fishcam", "dronecam" } :: { CamMode }

FreeCamConfig.MODE_GRAPHICS = {
	off = "rbxassetid://134790293447492",
	plotcam = "rbxassetid://94733908820021",
	fishcam = "rbxassetid://116935661186483",
	dronecam = "rbxassetid://130482731463043",
} :: { [CamMode]: string }

FreeCamConfig.MODE_LABELS = {
	off = "Player Cam",
	plotcam = "Plot Cam",
	fishcam = "Fish Cam",
	dronecam = "Free Cam",
} :: { [CamMode]: string }

FreeCamConfig.MODE_LABEL_NAME = "_OceanTD_CamModeLabel"
-- True after inactive cam icons finish collapsing (Plot Cam quick pad waits on this).
FreeCamConfig.ATTR_CAROUSEL_COLLAPSED = "OceanTD_CamCarouselCollapsed"
FreeCamConfig.MODE_LABEL_FADE_SEC = 5
FreeCamConfig.MODE_LABEL_FADE_OUT = TweenInfo.new(0.55, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
FreeCamConfig.MODE_LABEL_STROKE = Color3.fromRGB(12, 72, 28)
FreeCamConfig.HOVER_GREY = Color3.fromRGB(58, 58, 62)
FreeCamConfig.ICON_SCALE_IN = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
FreeCamConfig.ICON_SCALE_OUT = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
FreeCamConfig.DPAD_GLOW_SEC = 0.5
FreeCamConfig.DPAD_GLOW_INFO = TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
FreeCamConfig.REVOLVE_INFO = TweenInfo.new(1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
FreeCamConfig.EXPAND_INFO = TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
FreeCamConfig.COLLAPSE_INFO = TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
FreeCamConfig.COLLAPSE_WAIT_SEC = 2
FreeCamConfig.ACTIVE_SCALE = 1
FreeCamConfig.NEXT_SCALE = 0.82
FreeCamConfig.BOTTOM_SCALE = 0.76
FreeCamConfig.LAST_SCALE = 0.68
FreeCamConfig.COLLAPSED_SCALE = 0.08
FreeCamConfig.ROUTE_PATROL_SEC = 9

return FreeCamConfig
