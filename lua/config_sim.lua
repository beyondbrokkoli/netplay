local ConfigSim = {}

ConfigSim.net = {
    MAX_PLAYERS = 2,
    TICK_RATE = 60,
    HISTORY_LEN = 120,
    RING_SIZE = 512,
    MATCHMAKER_URL = "http://138.199.152.240:80",
    STUN_SERVER = "138.199.152.240",
    STUN_PORT = 3478,
    RELAY_IP = "138.199.152.240",
    RELAY_PORT = 49152
}

ConfigSim.world = {
    map_width = 256,
    map_height = 256,
    spacing = 20.0,
    grid_cells = 262144
}

-- [RESTORED] Lockstep state flags for C-header export
ConfigSim.net_state = {
    empty = 0,
    predicted = 1,
    confirmed = 2
}

ConfigSim.world.offset_x = (ConfigSim.world.map_width * ConfigSim.world.spacing) / 2.0
ConfigSim.world.offset_z = (ConfigSim.world.map_height * ConfigSim.world.spacing) / 2.0

return ConfigSim
