-- lua/sequence_headless.lua
local seq = {}

seq.boot = {
    {
        name = "Memory Allocator Check",
        action = function(ctx)
            local memory = require("memory")
            -- Verify our custom C-allocator is bound and functional
            memory.AllocateSoA("uint8_t", 1024, {"test_block"})
            memory.FreeSoA({"test_block"})
            print("[WEAVER] Aligned CPU Memory subsystem initialized.")
        end
    },
    {
        name = "Network Backend Bind",
        action = function(ctx)
            local net = require("network")
            -- Force a library load check before entering the FSM
            assert(net.HashState ~= nil, "Network backend hash function missing!")
            print("[WEAVER] C-Core Networking Pipe established.")
        end
    },
    {
        name = "Multiverse Grid Forging",
        action = function(ctx)
            local ffi = require("ffi")
            -- Create the raw memory block for the state machine
            ctx.rollback_arena = ffi.new("RollbackBuffer")
            print("[WEAVER] Rollback Arena instantiated directly in Lua memory.")
        end
    }
}

return seq
