-- main_headless.lua
local ffi = require("ffi")
local cfg_sim = require("config_sim")
local net = require("network")
local FSM = require("fsm_core")
local Pump = require("net_pump")
local Game = require("game_state")

-- 1. Explicit CPU Memory Allocation (No Vulkan, No Arena Manager)
local total_tiles = cfg_sim.world.grid_cells
local rts_grid = {
    terrain = ffi.new("uint16_t[?]", total_tiles),
    elevation = ffi.new("uint16_t[?]", total_tiles)
}

local rollback_arena = ffi.new("RollbackBuffer")
local snapshot_ring = ffi.new(string.format("%s[%d]", Game.GetStateName(), cfg_sim.net.RING_SIZE))

-- 2. The Headless FSM Loop
local FIXED_DT = 1.0 / cfg_sim.net.TICK_RATE
local accumulator = 0.0

while true do
    -- [1] Network Drain
    Pump.intercept_network(rollback_arena, sim_tick_count)

    -- [2] Fixed-Timestep CPU Simulation
    while accumulator >= FIXED_DT do
        FSM.tick_playing_state(rts_grid, rollback_arena)
        Pump.send_dynamic_history(rollback_arena)

        sim_tick_count = sim_tick_count + 1
        accumulator = accumulator - FIXED_DT
    end
end
