local ConfigGfx = {}

ConfigGfx.win = { w = 1280, h = 720 }
ConfigGfx.sys = { idle = 0, boot = 1, kill = 2 }
ConfigGfx.key = { space = 32, num1 = 49, num2 = 50, num3 = 51, esc = 256, f5 = 294 }

ConfigGfx.vk = {
    api_version = 4206592,
    frame_slots = 10,
    pc_size = 96
}

-- [RESTORED] Match your historical engine passes
ConfigGfx.mode = {
    dual = 0,
    geom = 1,
    points = 2,
    point_cloud_pass = 88
}

return ConfigGfx
