-- config_gfx.lua
local bit = require("bit")
local ConfigGfx = {}

ConfigGfx.win = { w = 1280, h = 720 }
ConfigGfx.sys = { idle = 0, boot = 1, kill = 2 }

-- Input Maps
ConfigGfx.key = { space = 32, num1 = 49, num2 = 50, num3 = 51, esc = 256, f5 = 294 }

-- Vulkan Pipeline Settings
ConfigGfx.vk = {
    api_version = 4206592,
    frame_slots = 10,
    pc_size = 96
}

ConfigGfx.mode = { dual = 0, geom = 1, points = 2 }

return ConfigGfx
