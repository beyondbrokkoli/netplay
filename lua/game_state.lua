local ffi = require("ffi")
local bit = require("bit")
local net = require("network")
local cfg = require("config_sim")
local cfg_net = require("config_net")
local Fixed = require("fixed_math")

local total_tiles = cfg.world.map_width * cfg.world.map_height

-- The monolithic Black Box State
ffi.cdef(string.format([[
    typedef struct {
        uint16_t terrain[8][%d];
        int32_t elevation[8][%d];
        uint32_t rng_state[1];
    } GameState;
]], total_tiles, total_tiles))

local Game = {}

function Game.GetStateName() return "GameState" end
function Game.GetStateSize() return ffi.sizeof("GameState") end

function Game.InitState(session_token)
    local state = ffi.new("GameState")

    -- 1. Deterministic RNG Seed
    local ptr = ffi.cast("uint32_t*", ffi.new("uint64_t[1]", session_token or 0))
    state.rng_state[0] = bit.bxor(ptr[0], ptr[1])
    if state.rng_state[0] == 0 then state.rng_state[0] = 0x811C9DC5 end

    -- 2. Initial World State Painting (Moved from main.lua)
    local cx = math.floor(cfg.world.map_width / 2)
    local cz = math.floor(cfg.world.map_height / 2)
    local w = cfg.world.map_width

    -- Paint the baseline map across all player layers
    for p = 0, cfg_net.MAX_PLAYERS - 1 do
        -- Paint the Crosshair
        state.terrain[p][cz * w + cx] = 10 -- CENTER (White)
        for x = cx + 1, cx + 5 do state.terrain[p][cz * w + x] = 11 end -- X-Axis (Red)
        for z = cz + 1, cz + 5 do state.terrain[p][z * w + cx] = 12 end -- Z-Axis (Blue)

        -- Paint the Bounding Box Corners
        state.terrain[p][(cz - 5) * w + (cx - 5)] = 13 -- Top Left
        state.terrain[p][(cz - 5) * w + (cx + 5)] = 13 -- Top Right
        state.terrain[p][(cz + 5) * w + (cx - 5)] = 13 -- Bottom Left
        state.terrain[p][(cz + 5) * w + (cx + 5)] = 13 -- Bottom Right
    end

    return state
end

function Game.SimulateTick(state, commands_array, tick)
    for p = 0, cfg_net.MAX_PLAYERS - 1 do
        for c = 0, 1 do
            local cmd = commands_array[p][c]
            if cmd.opcode == 1 then
                local idx = cmd.target_pos
                if idx < total_tiles then
                    if state.terrain[p][idx] == 0 then
                        state.terrain[p][idx] = p + 10
                        state.elevation[p][idx] = Fixed.from_float(15.0)
                    else
                        state.terrain[p][idx] = 0
                        state.elevation[p][idx] = Fixed.from_float(0.0)
                    end
                end
            end
        end
    end
end

function Game.HashState(state)
    local h1 = net.HashState(state.terrain, ffi.sizeof(state.terrain), 0)
    local h2 = net.HashState(state.elevation, ffi.sizeof(state.elevation), h1)
    return net.HashState(state.rng_state, 4, h2)
end

return Game
