io.stdout:setvbuf("no")
package.path = "./lua/?.lua;" .. package.path

local ffi = require("ffi")
local bit = require("bit")
local structs = require("structs")
local math = require("math")
local vmath = require("vmath")
local seq = require("sequence")

-- New Netcode Architecture
local net = require("network")
local cfg = require("config_engine")
local cfg_net = require("config_net")
local FSM = require("fsm_core")
local Pump = require("net_pump")
local Game = require("game_state")

-- Old Vulkan/Render Modules
local json_util = require("json_util")
local reg_vk = require("registry_vk")
local manifest = require("pipeline_manifest")

local render_queue = require("render_queue")


-- FFI CDEF BOUNDARY (Preserved from old main.lua)
ffi.cdef[[
    void* vx_sys_get_surface();
    void vx_sys_set_cmd(int cmd, int w, int h);
    void Sleep(uint32_t dwMilliseconds);
    int usleep(uint32_t usec);
    int vx_core_is_running();
    void vx_core_shutdown();
    void vx_core_mark_finished();
    int QueryPerformanceCounter(int64_t *lpPerformanceCount);
    int QueryPerformanceFrequency(int64_t *lpFrequency);
    typedef struct { long tv_sec; long tv_nsec; } timespec;
    int clock_gettime(int clk_id, timespec *tp);
    int vx_input_last_key();
    uint32_t vx_input_wasd();
    float vx_input_mouse_dx();
    float vx_input_mouse_dy();
    float vx_input_mouse_x();
    float vx_input_mouse_y();
    float vx_input_click_x();
    float vx_input_click_y();
    int vx_input_is_captured();
    int vx_sys_resize_flag();
    void vx_sys_window_size(int* w, int* h);
    int vx_input_mouse_btn(int btn);
    int vx_input_spacebar();
    int vx_stream_acquire();
    RenderPacket* vx_stream_packet(int idx);
    void vx_stream_commit(int idx);
    void vx_thread_kill();
    typedef struct __attribute__((aligned(16))) { float x, y, z, w; } vec4_t;
]]

-- ============================================================================
-- SYSTEM HELPERS & RAYCAST (Preserved)
-- ============================================================================
local function sys_sleep(ms)
    if jit.os == "Windows" then ffi.C.Sleep(ms) else ffi.C.usleep(ms * 1000) end
end

local get_time_hires
if jit.os == "Windows" then
    local kernel32 = ffi.load("kernel32")
    local freq = ffi.new("int64_t[1]")
    kernel32.QueryPerformanceFrequency(freq)
    local inv_freq = 1.0 / tonumber(freq[0])
    get_time_hires = function()
        local count = ffi.new("int64_t[1]")
        kernel32.QueryPerformanceCounter(count)
        return tonumber(count[0]) * inv_freq
    end
else
    get_time_hires = function()
        local ts = ffi.new("timespec")
        ffi.C.clock_gettime(1, ts) -- CLOCK_MONOTONIC
        return tonumber(ts.tv_sec) + (tonumber(ts.tv_nsec) * 1e-9)
    end
end

-- [Preserved matrix_raycast_terrain exactly as you wrote it]
local temp_vec_near = ffi.new("vec4_t")
local temp_vec_far = ffi.new("vec4_t")
local MAX_TILE_HEIGHT = 120.0
local RAY_CEILING = MAX_TILE_HEIGHT + 5.0
local MAX_RAY_STEPS = 1000
local function matrix_raycast_terrain(mouse_x, mouse_y, screen_w, screen_h, viewProj_inv, grid)
    local nx = (mouse_x / screen_w) * 2.0 - 1.0
    local ny = (mouse_y / screen_h) * 2.0 - 1.0
    vmath.multiply_mat4_vec4(viewProj_inv, nx, ny, 0.0, 1.0, temp_vec_near)
    vmath.multiply_mat4_vec4(viewProj_inv, nx, ny, 1.0, 1.0, temp_vec_far)
    local near_w = 1.0 / temp_vec_near.w
    local ox, oy, oz = temp_vec_near.x * near_w, temp_vec_near.y * near_w, temp_vec_near.z * near_w
    local far_w = 1.0 / temp_vec_far.w
    local fx, fy, fz = temp_vec_far.x * far_w, temp_vec_far.y * far_w, temp_vec_far.z * far_w
    local dx, dy, dz = fx - ox, fy - oy, fz - oz
    local inv_mag = 1.0 / math.sqrt(dx^2 + dy^2 + dz^2)
    dx, dy, dz = dx * inv_mag, dy * inv_mag, dz * inv_mag
    local t = 0.0
    if dy < 0.0 then
        local dist_to_ceiling = (RAY_CEILING - oy) / dy
        if dist_to_ceiling > 0.0 then t = dist_to_ceiling end
    end
    for i = 1, MAX_RAY_STEPS do
        local px = ox + dx * t
        local py = oy + dy * t
        local pz = oz + dz * t
        local grid_x = math.floor((px + cfg.world.offset_x) / cfg.world.spacing + 0.5)
        local grid_z = math.floor((pz + cfg.world.offset_z) / cfg.world.spacing + 0.5)
        if grid_x >= 0 and grid_x < cfg.world.map_width and grid_z >= 0 and grid_z < cfg.world.map_height then
            local idx = grid_z * cfg.world.map_width + grid_x
            local stack_elevation = 0.0
            for p = 0, 7 do stack_elevation = stack_elevation + grid.elevation[p][idx] end
            if py <= stack_elevation + 0.1 then return idx end
        end
        t = t + (cfg.world.spacing * 0.1)
    end
    return -1
end

-- Engine Input Submission Bridge
local Engine = {}
function Engine.SubmitCommand(ctx, opcode, flags, target_id, target_pos)
    local c_idx = bit.band(ctx.sim_tick_count, cfg_net.RING_MASK)
    local pending_frame = ctx.rollback_arena.frames[c_idx]
    local cmds = pending_frame.commands[ctx.net_identity]

    if cmds[0].opcode == 0 then
        cmds[0].opcode = opcode; cmds[0].flags = flags
        cmds[0].target_id = target_id; cmds[0].target_pos = target_pos
    elseif cmds[1].opcode == 0 then
        cmds[1].opcode = opcode; cmds[1].flags = flags
        cmds[1].target_id = target_id; cmds[1].target_pos = target_pos
    else
        print("[WARNING] Engine Command Buffer saturated for tick " .. ctx.sim_tick_count)
    end
end

local function http_post(url, json_payload)
    local payload_path = "matchmaker_payload.json"
    local f = assert(io.open(payload_path, "w"), "Failed to open temp file")
    f:write(json_payload)
    f:close()
    local cmd = string.format('curl -s -X POST -H "Content-Type: application/json" -d "@%s" %s', payload_path, url)
    local pf = io.popen(cmd)
    local res = pf:read("*a")
    pf:close()
    os.remove(payload_path)
    return res
end

local function http_get(url)
    local cmd = string.format('curl -s "%s"', url)
    local f = io.popen(cmd)
    if not f then return "" end
    local res = f:read("*a")
    f:close()
    return res
end

local function get_local_ip()
    local cmd = ""
    if jit.os == "Windows" then
        cmd = 'powershell -Command "(Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike \'127.*\' -and $_.IPAddress -notlike \'169.254.*\' } | Select-Object -First 1).IPAddress"'
    else
        cmd = "ip route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i==\"src\") print $(i+1)}'"
    end
    local f = io.popen(cmd)
    if not f then return "127.0.0.1" end
    local res = f:read("*a")
    f:close()
    res = res:gsub("%s+", "")
    if not res:match("^%d+%.%d+%.%d+%.%d+$") then return "127.0.0.1" end
    return res
end

local function extract_true_64bit_token(json_string)
    local token_digits = json_string:match('"session_token"%s*:%s*(%d+)')
    assert(token_digits, "FATAL: Could not locate session_token digits in JSON payload")
    local val = ffi.cast("uint64_t", 0)
    for i = 1, #token_digits do
        local byte = string.byte(token_digits, i)
        if byte >= 48 and byte <= 57 then
            val = (val * 10) + (byte - 48)
        else
            break
        end
    end
    return val
end
local function BootstrapNetworkTopology(local_port, my_local_ip)
    print(string.format("[STUN] Querying external NAT edges at %s:%d...", cfg_net.STUN_SERVER, cfg_net.STUN_PORT))
    local stun_ok, my_pub_ip, my_pub_port = net.StunPunch(cfg_net.STUN_SERVER, cfg_net.STUN_PORT)

    if not stun_ok then
        print("[WARNING] STUN negotiation failed. Operating via local loopbacks.")
        my_pub_ip = my_local_ip
        my_pub_port = local_port
    else
        print(string.format("[STUN] Discovery successful. External mapped endpoint: %s:%d", my_pub_ip, my_pub_port))
    end

    print("\n[MATCHMAKING] Select Mode: (H)ost New Game or (J)oin Existing Lobby")
    io.write("> ")
    local mode_input = io.read("*l"):upper()

    local lobby_id = ""
    local session_token = nil
    local initial_payload = json.encode({
        public_ip = my_pub_ip, public_port = my_pub_port,
        local_ip = my_local_ip, local_port = local_port
    })

    if mode_input == "H" then
        print("[MATCHMAKER] Requesting new lobby...")
        local response = http_post(cfg_net.MATCHMAKER_URL .. "/host", initial_payload)
        session_token = extract_true_64bit_token(response)
        lobby_id = json.decode(response).lobby_id
        print("[MATCHMAKER] Hosted Lobby, holding room: " .. lobby_id)
    else
        if mode_input == "J" then
            print("Enter Target 4-Character Lobby ID:")
            io.write("> ")
            lobby_id = io.read("*l"):upper()
        else
            lobby_id = mode_input:upper()
        end
        print("[MATCHMAKER] Joining Lobby: " .. lobby_id)
        local response = http_post(cfg_net.MATCHMAKER_URL .. "/join/" .. lobby_id, initial_payload)
        session_token = extract_true_64bit_token(response)
    end

    print("[MATCHMAKER] Polling quorum status. Waiting for 'locked'...")
    local status_data = nil
    while true do
        local raw_res = http_get(cfg_net.MATCHMAKER_URL .. "/status/" .. lobby_id)
        if raw_res and raw_res ~= "" then
            status_data = json.decode(raw_res)
            if status_data.status == "locked" then
                print(string.format("[MATCHMAKER] Quorum reached (%d/%d). Lobby is LOCKED.", status_data.player_count, cfg_net.MAX_PLAYERS))
                break
            end
        end
        sys_sleep(500)
    end

    local local_id = 0
    for i, p in ipairs(status_data.players) do
        if p.ip == my_pub_ip and tonumber(p.port) == my_pub_port and p.local_ip == my_local_ip and p.local_port == local_port then
            local_id = i - 1; break
        end
    end

    net.SetPlayerId(local_id)
    net.SetSession(session_token)
    print(string.format("[SYSTEM] Assigning Identity: Node %d. Meshing topology...", local_id))

    local p2p_established = {}
    local active_peers = {}

    for i, p in ipairs(status_data.players) do
        local peer_id = i - 1
        if peer_id ~= local_id then
            active_peers[peer_id] = true
            if p.ip == my_pub_ip or p.ip == "127.0.0.1" or my_pub_ip == "127.0.0.1" then
                local target_ip = (p.local_ip == my_local_ip) and "127.0.0.1" or p.local_ip
                net.Connect(peer_id, target_ip, tonumber(p.local_port))
                p2p_established[peer_id] = true
                print(string.format("[ROUTING] Node %d clamped to LAN (%s:%d). Hairpin bypassed.", peer_id, target_ip, p.local_port))
            else
                net.Connect(peer_id, p.ip, tonumber(p.port))
                print(string.format("[ROUTING] Node %d is WAN. Staging for ICE...", peer_id))
            end
        end
    end

    local real_time_remaining = status_data.start_time - status_data.server_time
    local sync_start_time = get_time_hires()

    if real_time_remaining > 0 then
        print(string.format("[ICE] Quorum locked. Initiating Mutual Handshake for %.2f seconds...", real_time_remaining))
        local handshake_buffer = ffi.new("LockstepPacket[32]")
        local p2p_heard = {}

        while (get_time_hires() - sync_start_time) < real_time_remaining do
            for peer_id, active in pairs(active_peers) do
                if active and not p2p_established[peer_id] then
                    local ping_pkt = ffi.new("LockstepPacket")
                    ping_pkt.session_token = session_token
                    ping_pkt.player_id = local_id
                    ping_pkt.frame_tick = p2p_heard[peer_id] and 1 or 0
                    net.SendTo(ping_pkt, peer_id)
                end
            end

            local count = net.RecvAll(handshake_buffer, 32)
            for i = 0, count - 1 do
                local pkt = handshake_buffer[i]
                if pkt.session_token == session_token then
                    local sender = pkt.player_id
                    p2p_heard[sender] = true
                    if pkt.frame_tick >= 1 and not p2p_established[sender] then
                        p2p_established[sender] = true
                        print(string.format("[ICE] Mutual P2P Punch-Through SUCCESS for Node %d!", sender))
                    end
                end
            end
            sys_sleep(50)
        end
    end

    print("[ICE] Sync window closed. Evaluating routing topologies...")

    for peer_id, active in pairs(active_peers) do
        if active then
            if p2p_established[peer_id] then
                print(string.format("[ROUTING] Node %d -> P2P [DIRECT RESIDENTIAL]", peer_id))
            else
                print(string.format("[ROUTING] Node %d -> P2P [FAILED]. Tagged for Omnibus Relay.", peer_id))
                -- [!] FIX: Do NOT overwrite the peer_id socket with the Relay IP.
                -- Leave it mapped to the dead WAN IP. The net_pump will route
                -- this player's traffic through the MAX_PLAYERS socket instead.
            end
        end
    end

    -- Bind the Omnibus socket EXACTLY ONCE to Index 8.
    net.SetRelayIP(cfg_net.RELAY_IP)
    net.Connect(cfg_net.MAX_PLAYERS, cfg_net.RELAY_IP, cfg_net.RELAY_PORT)

    -- Force register our NAT mapping with the Relay so it knows where to route
    -- fallback packets, even if we are strictly P2P right now.
    local reg_pkt = ffi.new("LockstepPacket")
    reg_pkt.session_token = session_token
    reg_pkt.player_id = local_id
    reg_pkt.frame_tick = 0
    net.SendTo(reg_pkt, cfg_net.MAX_PLAYERS)

    print("[SYSTEM] All routes bound. Drop-in complete.")

    return session_token, local_id, p2p_established, active_peers, status_data
end
-- THE UNIFIED BOOT SEQUENCE
local function main()
    -- 1. DETECT HEADLESS MODE
    local is_headless = false
    for _, v in ipairs(arg) do
        if v == "--headless" or v == "--server" then is_headless = true end
    end

    print("========================================")
    print(" WEAVER ENGINE: 8-PLAYER MULTIVERSE ")
    print(" Mode: " .. (is_headless and "HEADLESS SERVER" or "VULKAN CLIENT"))
    print("========================================")

    -- 2. TERMINAL LOGIN & NETWORK TOPOLOGY
    print("Enter Node ID (0-7) OR Preferred Local Port (e.g., 50000): ")
    io.write("> ")
    local user_input = tonumber(io.read("*l")) or 50000

    local local_port = user_input
    if local_port < 1000 then
        local_port = 50000 + local_port
    end

    assert(net.Host(local_port), "FATAL: Failed to bind local socket port " .. local_port)
    local my_local_ip = get_local_ip()

    -- Execute your exact Bootstrap sequence
    local session_token, local_id, p2p_established, active_peers, status_data = BootstrapNetworkTopology(local_port, my_local_ip)

    -- 3. THE GLOBAL SYNC SLEEP (Your "Hanging Pawn" #1)
    local real_time_remaining = status_data.start_time - status_data.server_time
    if real_time_remaining > 0 then
        print(string.format("[SYSTEM] Topology Locked. Sleeping %.2f seconds for global sync...", real_time_remaining))
        sys_sleep(real_time_remaining * 1000)
    end

    -- 4. CONTEXT ALLOCATION
    local ctx = {
        session_token = session_token,
        net_identity = local_id,
        sim_tick_count = 1,
        accumulator = 0.0,
        total_tiles = cfg.world.map_width * cfg.world.map_height,
        last_bot_tick = 0,
        p2p_established = p2p_established,
        peer_active = ffi.new(string.format("bool[%d]", cfg_net.MAX_PLAYERS)),
        peer_highest_tick = ffi.new(string.format("uint32_t[%d]", cfg_net.MAX_PLAYERS)),
        peer_ack_of_me = ffi.new(string.format("uint32_t[%d]", cfg_net.MAX_PLAYERS)),

        -- Black Box allocations
        rts_grid = Game.InitState(session_token),
        rollback_arena = ffi.new("RollbackBuffer"),
        snapshot_ring = ffi.new(string.format("%s[%d]", Game.GetStateName(), cfg_net.RING_SIZE)),

        -- Extracted from old ctx for the Render loop
        prev_mouse_left = 0,
        total_time = 0.0,
    }

    -- 5. PRISTINE FRAME 0 INITIALIZATION (Your "Hanging Pawn" #2)
    local f0 = ctx.rollback_arena.frames[0]
    f0.tick = 0
    for p = 0, cfg_net.MAX_PLAYERS - 1 do
        f0.commands[p][0].opcode = 0
        f0.commands[p][1].opcode = 0
    end

    ctx.rollback_arena.head_tick = 0
    ctx.rollback_arena.confirmed_tick = 0

    for p = 0, cfg_net.MAX_PLAYERS - 1 do
        -- Dynamically set active state based on the STUN/Matchmaker phase
        if active_peers[p] then
            ctx.peer_active[p] = true
        else
            ctx.peer_active[p] = false
        end
    end

    -- The crucial initial snapshot and hash!
    ffi.copy(ctx.snapshot_ring[0], ctx.rts_grid, Game.GetStateSize())
    f0.state_checksum = Game.HashState(ctx.rts_grid)

    -- 6. BOOTSTRAP VULKAN (If Client)
    local vram_template, render_queues, pc, cam, inv_vp, master_ptr, memory, active_render_mode
    if not is_headless then
        print("[LUA IO] Instructing C-Core to Boot GLFW Window...")
        ffi.C.vx_sys_set_cmd(1, 1280, 720) -- CMD_BOOT_WINDOW

        -- Start Weaver Coroutine to sync with C-Core surface
        local co = coroutine.create(function()
            local weaver_ctx = {}
            for i, stage in ipairs(seq.boot) do
                local signal = stage.action(weaver_ctx)
                if signal == "AWAIT_SURFACE" then
                    while ffi.C.vx_sys_get_surface() == nil do
                        sys_sleep(10)
                        coroutine.yield()
                    end
                end
            end
            return weaver_ctx
        end)

        local status, engine_ctx
        while coroutine.status(co) ~= "dead" do
            status, engine_ctx = coroutine.resume(co)
            if not status then error("Fatal Weaver Crash: " .. tostring(engine_ctx)) end
        end

        ctx.vk_rt = engine_ctx.vk_runtime
        ctx.sc_state = engine_ctx.sc_state
        ctx.desc_state = engine_ctx.desc_state
        ctx.gfx_state = engine_ctx.gfx_state
        ctx.sync_state = engine_ctx.sync_state

        -- Direct Vulkan DMA memory orchestration
        memory = require("memory")

        -- Direct FFI VRAM queue allocation (Replaces arena_manager!)
        render_queues = {}
        for i = 0, 3 do
            render_queues[i] = ffi.new("DrawCommand[1024]")
        end

        -- Init GPU VRAM Template
        vram_template = ffi.new("RtsTileInstance[?]", ctx.total_tiles)
        for z = 0, cfg.world.map_height - 1 do
            for x = 0, cfg.world.map_width - 1 do
                local i = z * cfg.world.map_width + x
                vram_template[i].px = (x * cfg.world.spacing) - cfg.world.offset_x
                vram_template[i].pz = (z * cfg.world.spacing) - cfg.world.offset_z
            end
        end

        pc = ffi.new("PushConstants")
        local camera_mod = require("camera")
        cam = camera_mod.new()
        inv_vp = ffi.new("mat4_t")
        master_ptr = ffi.cast("float*", memory.Mapped["MASTER_GPU_BLOCK"])
        active_render_mode = cfg.mode.dual
    end

    -- 7. THE MAIN LOOP
    local FIXED_DT = 1.0 / cfg_net.TICK_RATE
    local last_time = get_time_hires()
    local next_debug_print = last_time + 1.0

    print("[SYSTEM] Drop-in complete. Entering Bifurcated FSM loop.")

    while ffi.C.vx_core_is_running() == 1 do
        local current_time = get_time_hires()
        local frame_time = math.max(0.001, math.min(current_time - last_time, 0.25))
        last_time = current_time

        -- A. Ingest Network Packets
        Pump.intercept_network(ctx, ctx.sim_tick_count)

        ctx.accumulator = ctx.accumulator + frame_time

        -- B. Consume Fixed Timesteps (Deterministic Logic)
        while ctx.accumulator >= FIXED_DT do

            -- [CLIENT] Capture Mouse clicks and translate to Network Opcodes
            if not is_headless then
                local mouse_left = ffi.C.vx_input_mouse_btn(0)
                if mouse_left == 1 and ctx.prev_mouse_left == 0 then
                    local click_x = ffi.C.vx_input_click_x()
                    local click_y = ffi.C.vx_input_click_y()
                    local clicked_idx = matrix_raycast_terrain(click_x, click_y, ctx.sc_state.extent.width, ctx.sc_state.extent.height, inv_vp, ctx.rts_grid)

                    if clicked_idx ~= -1 then
                        Engine.SubmitCommand(ctx, 1, 0, 0, clicked_idx)
                    end
                end
                ctx.prev_mouse_left = mouse_left
            end

            -- Automated Bot Logic (from your Bleeding Edge code)
            if ctx.sim_tick_count % 120 == (ctx.net_identity * 10) then
                if ctx.last_bot_tick ~= ctx.sim_tick_count then
                    Engine.SubmitCommand(ctx, 1, 0, 0, math.random(0, ctx.total_tiles - 1))
                    ctx.last_bot_tick = ctx.sim_tick_count
                end
            end

            -- Execute the core Rollback state machine
            FSM.tick_playing_state(ctx, FIXED_DT)
            Pump.send_dynamic_history(ctx)

            -- Wipe the next frame in the Ring Buffer
            ctx.sim_tick_count = ctx.sim_tick_count + 1
            local n_idx = bit.band(ctx.sim_tick_count, cfg_net.RING_MASK)
            local next_frame = ctx.rollback_arena.frames[n_idx]
            next_frame.tick = ctx.sim_tick_count
            for p = 0, cfg_net.MAX_PLAYERS - 1 do
                next_frame.commands[p][0].opcode = 0
                next_frame.commands[p][1].opcode = 0
            end

            ctx.accumulator = ctx.accumulator - FIXED_DT
        end

        -- C. Vulkan Render Dispatch (Only if Client!)
        if not is_headless then
            ctx.total_time = ctx.total_time + frame_time
            pc.total_time = ctx.total_time

            local mouse_x = ffi.C.vx_input_mouse_x()
            local mouse_y = ffi.C.vx_input_mouse_y()

            require("camera").update(cam, frame_time, mouse_x, mouse_y, ctx.sc_state.extent.width, ctx.sc_state.extent.height)
            require("camera").get_matrices(cam, ctx.sc_state.extent.width, ctx.sc_state.extent.height, pc.viewProj, inv_vp)

            -- Format data for the WSI
            for i = 0, ctx.total_tiles - 1 do
                local composite_terrain_id = 0
                local stack_elevation = 0.0
                for p = 0, 7 do
                    local t_id = ctx.rts_grid.terrain[p][i]
                    if t_id ~= 0 then
                        composite_terrain_id = t_id
                        stack_elevation = stack_elevation + ctx.rts_grid.elevation[p][i]
                    end
                end
                vram_template[i].tile_data = bit.lshift(composite_terrain_id, 24)
                vram_template[i].py = stack_elevation
            end

            -- Thread-safe FFI push to C-Core Ring Buffer
            local write_idx = ffi.C.vx_stream_acquire()
            if write_idx ~= -1 then
                pc.dt = ctx.accumulator / FIXED_DT
                render_queue.PackFrame(write_idx, pc, ctx.rts_grid, vram_template, render_queues, active_render_mode, master_ptr, memory, ctx.gfx_state, ctx.desc_state, ctx.sc_state, ctx.total_tiles, ctx.net_identity)
                ffi.C.vx_stream_commit(write_idx)
            end
        end

        -- D. Diagnostic Heartbeat
        if current_time >= next_debug_print then
            local display_idx = bit.band(ctx.sim_tick_count - 1, cfg_net.RING_MASK)
            local display_checksum = ctx.rollback_arena.frames[display_idx].state_checksum or 0
            local missing_frames = ctx.sim_tick_count - ctx.rollback_arena.confirmed_tick

            local tracker_str = ""
            for p = 0, cfg_net.MAX_PLAYERS - 1 do
                if p ~= ctx.net_identity then
                    tracker_str = tracker_str .. string.format("P%d:%d ", p, ctx.peer_highest_tick[p])
                end
            end

            print(string.format("[HEARTBEAT] SimTick: %d | NetHead: %d | Missing: %d | Hash: 0x%08X",
                ctx.sim_tick_count, ctx.rollback_arena.head_tick, missing_frames, display_checksum))
            next_debug_print = current_time + 1.0
        end

        sys_sleep(1)
    end

    print("\n[LUA IO] Execution Terminated. Commencing Teardown...")
    ffi.C.vx_thread_kill()
    if not is_headless then
        ctx.vk_rt.vk.vkDeviceWaitIdle(ctx.vk_rt.device)
        require("graphics_pipeline").Destroy(ctx.vk_rt.vk, ctx.vk_rt, ctx.gfx_state)
        require("descriptors").Destroy(ctx.vk_rt.vk, ctx.vk_rt.device, ctx.desc_state)
        require("swapchain").Destroy(ctx.vk_rt.vk, ctx.vk_rt, ctx.sc_state)
        require("renderer").Destroy(ctx.vk_rt.vk, ctx.vk_rt.device, ctx.sync_state, cfg.cfg.frame_slots)
        memory.DestroyBuffer("MASTER_GPU_BLOCK", ctx.vk_rt)
        memory.DestroyBuffer("MASTER_INDEX_BLOCK", ctx.vk_rt)
        require("vulkan_core").Destroy(ctx.vk_rt)
    end
    net.Shutdown()
    print("[LUA IO] Teardown Complete. Safe Exit.")
end

main()
ffi.C.vx_core_mark_finished()
