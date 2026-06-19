local bit = require("bit")

local KB = 1024
local MB = 1024 * KB

local config = {
    -- Input & OS System States
    sys = { idle = 0, boot = 1, kill = 2 },
    win = { w = 1280, h = 720, min_w = 640, min_h = 360 },
    move  = { fwd = 1, back = 2, left = 4, right = 8, up = 16, down = 32 },
    mouse = { left = 0, right = 1 },
    key   = { space = 32, num1 = 49, num2 = 50, num3 = 51, num4 = 52, esc = 256, f11 = 290, f5 = 294, enter = 257 },

    -- Engine Rendering & Memory Constants
    cfg = {
        use_validation = 0,
        vk_api_version = 4206592,
        pcount = 1000000,
        grid_cells = 262144,
        pc_size = 96,
        frame_slots = 10,
        swap_slots = 10,
        swarm_states = 7,
        rollback_buffer_size = 128
    },

    -- Graphics Modes
    mode = {
        dual = 0,
        geom = 1,
        points = 2,
        point_cloud_pass = 88
    },

    -- Dimensional Manifesto SSoT
    world = {
        map_width = 256,   -- Restored full Multiverse width
        map_height = 256,  -- Restored full Multiverse height
        spacing = 20.0,
    },

    -- Lockstep Network States
    net_state = {
        empty = 0,
        predicted = 1,
        confirmed = 2
    },
}

-- Calculate dynamic memory bounds based on the true world size
local bytes_per_tile = 16 -- ffi.sizeof("RtsTileInstance")
local single_dimension_bytes = config.cfg.grid_cells * bytes_per_tile

-- [MULTIVERSE] Allocate enough VRAM for all 8 dimensions natively + a 10% safety margin
local required_gpu_memory = math.floor(single_dimension_bytes * 8 * 1.1)

config.memory_arenas = {
    -- Scale the Index block to actually hold the max grid (6 indices per quad)
    { name = "MASTER_INDEX_BLOCK", cdef_type = "uint32_t", count = config.cfg.grid_cells * 6, usage = bit.bor(64, 256) },

    -- The Dynamic Master Block
    { name = "MASTER_GPU_BLOCK", cdef_type = "uint8_t", count = required_gpu_memory, usage = bit.bor(32, 128, 256) }
}

-- Pre-calculate dimensional offsets for the Matrix Raycast and Shader centering
config.world.offset_x = (config.world.map_width * config.world.spacing) / 2.0
config.world.offset_z = (config.world.map_height * config.world.spacing) / 2.0

return config
