## ⚙️ Runtime Controls

| Key | Action | Description |
| :--- | :--- | :--- |
| **`F11`** | 🖥️ Fullscreen | Toggles between windowed and fullscreen display modes. |
| **`F10`** | 🖱️ Edge Scroll | Toggles mouse clamping to the screen edge and activates edge-based view scrolling. |
| **`F5`**  | 🔄 Hot-Reload | Rebuilds and applies shader pipelines instantly. |
| **`1`** / **`2`** / **`3`** | 🎯 Render Modes | Toggles between Dual, Geometry, and Point rendering modes. |
| **`ESC`** | 🛑 Teardown | Initiates a graceful, memory-safe engine shutdown. |

---

> **A deterministic, zero-allocation lockstep rollback netcode engine built on a C/LuaJIT FFI boundary.**

Weaver is a high-performance, Vulkan-backed engine designed for uncompromising multiplayer parity, fluid developer iteration, and absolute simulation consistency.

## 🛠️ Build System & Developer Experience

The Weaver build pipeline is engineered for zero-friction development. By eliminating runtime bottlenecks and providing instant feedback loops, the user experience remains uninterrupted during both compilation and execution.

*   **⚡ Zero-Allocation 60Hz Loop:** The network and simulation loops perform strictly zero heap allocations. This entirely prevents LuaJIT garbage collection pauses, ensuring a buttery-smooth development and testing experience without micro-stutters.
*   **🔄 Coroutine-Driven Boot Sequence:** The "Weaver" initialization pipeline utilizes non-blocking coroutines, allowing the C-Core surface to initialize asynchronously without stalling the main thread.
*   **🔥 Zero-Downtime Hot-Reloading:** Press **`F5`** to instantly hot-swap graphics and compute shaders. The engine dynamically recompiles and rebinds pipelines on the fly, eliminating the need to restart the simulation during visual tuning.
*   **📐 Dynamic "Mini-Weaver" Rebuilding:** Window resizing no longer requires a full context tear-down. The engine triggers an automated "Mini-Weaver" sequence that safely rebuilds the swapchain and render targets while preserving the active simulation state.
*   **📦 Asynchronous VRAM Staging:** Memory transfers (such as palette and geometry uploads) are handled via non-blocking asynchronous queues, ensuring the render loop never stalls during asset loading.

---

## 🛡️ Anti-Desync & Networking Architecture

Weaver guarantees absolute simulation parity across all nodes through a multi-layered, cryptographically verified deterministic lockstep architecture.

### 🌐 Single-Broadcast Topology
*   **$O(1)$ Network Scaling:** The engine uses a single-broadcast topology to avoid $O(N^2)$ packet scaling. Each hardware frame generates exactly one MTU-sized packet containing **120 ticks of input history** and an **8-player ACK array**.
*   **60Hz Simulation & Lookahead:** The simulation runs at a strict 60Hz with a 60-tick lookahead. The massive 120-tick history buffer ensures that slow peers receive missing frames without ever stalling the global simulation.

### 🎯 Deterministic Lockstep & Rollback
*   **Fixed-Timestep Simulation:** The engine strictly enforces a `FIXED_DT` accumulator, ensuring physics and logic evaluate at exact, uniform intervals regardless of frame rate fluctuations.
*   **Ring-Buffered Rollback Arena:** Input latency is masked via a robust `RollbackBuffer`. The engine seamlessly rewinds state, re-simulates divergent frames, and fast-forwards to the present tick without visual stuttering.

### 🔐 Cryptographic State Parity
*   **Dual-Checksum Validation:** Every simulated frame generates a local `state_checksum` which is continuously compared against the `remote_checksum` received from peers. 
*   **Instant Drift Correction:** If a checksum mismatch is detected, the engine immediately flags the desync, isolates the faulty frame, and triggers a localized rollback to the last confirmed synchronized state.

### 📡 Advanced NAT Traversal
*   **Bidirectional Handshake:** Requires a two-way PING/PONG exchange before upgrading a route to P2P, ensuring true mutual connectivity.
*   **LAN Loopback Bypass:** Detects shared public IPs to bypass router NAT loopback failures, forcing local peers to communicate directly over the local network switch.
*   **Socket Isolation:** The relay uses a dedicated internal socket to prevent stateful NAT collisions, ensuring robust WAN fallback.

---

## 🧠 Memory & Performance Engineering

To maintain the zero-allocation guarantee, Weaver employs aggressive memory management strategies at the FFI boundary:

*   **Pre-allocated Static Ring Buffers:** Network and rollback buffers are allocated once at startup and recycled continuously.
*   **Raw Pointer Casting:** Deserialization bypasses Lua tables entirely, using raw `uint64_t*` pointer casting for contiguous, cache-friendly memory access.

---

## 🎮 Game Integration Interface

The engine is entirely independent of game logic. It synchronizes an 8-byte `PlayerCommand` struct and manages the simulation loop, allowing you to plug in any game rules.

### Input Structure
Players submit raw intents via a packed 8-byte C struct:

```c
typedef struct __attribute__((packed)) {
    uint8_t  opcode;     // Action ID
    uint8_t  flags;      // Modifiers
    uint16_t target_id;  // Entity ID
    uint32_t target_pos; // Grid index or coordinates
} PlayerCommand;
```

### Game State API (`game_state.lua`)
Implement the `Game` table with the following four functions to integrate your logic:

```lua
local Game = {}

-- 1. State Allocation
-- Return the FFI C-struct representing the game state.
function Game.InitState(session_token) ... end
function Game.GetStateSize() ... end

-- 2. Simulation
-- Execute game rules using the synchronized commands for the current tick.
function Game.SimulateTick(state, commands_array, tick)
    for p = 0, MAX_PLAYERS - 1 do
        local cmd = commands_array[p][0]
        if cmd.opcode == OPCODE_MOVE then
            -- Update state deterministically
        end
    end
end

-- 3. State Verification
-- Return a hash of the state for desync detection.
function Game.HashState(state) ... end

return Game
```

### Submitting Inputs
Submit local player or bot inputs to the engine's pending frame buffer. This runs outside the deterministic simulation loop:

```lua
Engine.SubmitCommand(ctx, OPCODE_RAISE_TILE, 0, 0, target_grid_index)
```

---

🧮 Deterministic Math & Simulation Core
To guarantee absolute parity across all hardware, the simulation layer eliminates all sources of non-determinism at the foundational level.

📐 Fixed-Point Arithmetic: All core simulation math utilizes a custom fixed-point library (SCALE = 1024). By replacing IEEE 754 floating-point operations with integer math, the engine guarantees identical calculations across different CPU architectures, compilers, and operating systems.
🔄 Rollback FSM & Consensus: The FSM module drives the lockstep loop by calculating a true_consensus and safe_horizon based on peer ACKs. If a late-arriving input alters a past tick, the FSM seamlessly triggers a rollback, restores the state from the snapshot ring, and re-simulates forward without breaking the render loop.
🔐 Native State Hashing: Game state verification is offloaded to a high-performance C-level hash function (vx_net_hash_state). This provides rapid, mathematically verified parity checks with zero Lua allocation overhead.

🎨 Zero-Copy Rendering Pipeline
The rendering architecture is designed to feed the GPU with minimal CPU intervention, maintaining the strict 60Hz budget while visualizing the deterministic state.

🧠 Direct VRAM Mapping: The render queue bypasses traditional API staging for vertex updates. It writes directly to mapped GPU memory (MASTER_GPU_BLOCK) via raw FFI pointers, achieving true zero-copy data transfer.
📦 Dynamic Multi-Pass Packing: Draw commands are packed into contiguous memory blocks (RenderPacket). The engine dynamically constructs multi-pass queues (Geometry, Point Cloud, or Dual) based on runtime toggles, updating push constants and pipeline states on the fly.
⚖️ Deterministic Elevation: Terrain elevation is converted from fixed-point simulation space to float space at the exact moment of GPU upload. This guarantees that the visual representation perfectly mirrors the deterministic simulation state without introducing floating-point drift.

📡 Network Pump & State Synchronization
The networking layer is built for extreme resilience, ensuring the simulation never stalls due to packet loss, NAT quirks, or latency spikes.

📜 History Broadcasting: The net_pump constructs massive MTU-sized packets containing up to 120 ticks of input history. This "shotgun" approach ensures that even peers with severe packet loss eventually receive the necessary inputs to advance the simulation.
🤝 ACK-Driven Consensus: The engine tracks peer_acks and peer_ack_of_me to dynamically adjust the safe_horizon. This prevents the simulation from outpacing the network, ensuring inputs are globally locked before execution.
⚡ Native C Sockets: All socket operations, STUN traversal, and packet routing are handled by a native C shared library (vx_net). This completely bypasses Lua's garbage collector and OS-level networking overhead, ensuring the network thread never causes micro-stutters.

📷 Spatial Control & Camera System
The viewport system provides fluid, RTS-style navigation while remaining entirely decoupled from the deterministic simulation loop to prevent input latency.

🖱️ Orthographic Edge Scrolling: The camera features an integrated edge-scrolling mechanic (toggled via F10), allowing seamless map navigation by clamping the cursor to the screen boundaries and translating it into world-space panning.
🔭 Dynamic Zoom & Matrix Math: Utilizing a custom vmath library, the camera calculates orthographic projection and view matrices in real-time. It supports exponential zooming while maintaining strict aspect ratio corrections and precise raycasting for tile selection.

