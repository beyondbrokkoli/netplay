-- config_sim.lua
local ConfigSim = {}

-- Temporal & Networking Logic
ConfigSim.net = {
    MAX_PLAYERS = 8, -- Scaling up for the 8-player lockstep goal
    TICK_RATE = 60,
    HISTORY_LEN = 120,
    RING_SIZE = 512,
    MATCHMAKER_URL = "http://138.199.152.240:80",
    STUN_SERVER = "138.199.152.240",
    STUN_PORT = 3478,
    RELAY_IP = "138.199.152.240",
    RELAY_PORT = 49152
}

-- Dimensional SSoT (Game State)
ConfigSim.world = {
    map_width = 256,
    map_height = 256,
    spacing = 20.0,
    grid_cells = 262144
}

ConfigSim.world.offset_x = (ConfigSim.world.map_width * ConfigSim.world.spacing) / 2.0
ConfigSim.world.offset_z = (ConfigSim.world.map_height * ConfigSim.world.spacing) / 2.0

return ConfigSim
