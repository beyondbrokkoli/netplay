# 🚀 Weaver Engine v2.0

> **A deterministic, zero-allocation lockstep rollback netcode engine built on a C/LuaJIT FFI boundary.**

Weaver is a high-performance, Vulkan-backed engine designed for uncompromising multiplayer parity, fluid developer iteration, and absolute simulation consistency.

---

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

## 🧪 Testing & Infrastructure

The repository includes a Python test harness for simulating multi-node environments. A centralized matchmaker and UDP relay are currently hosted online for testing. The harness is pre-configured to route signaling and game traffic through this infrastructure.

**To run an 8-player simulation:**
1. Execute `python harness_split.py` and select `(H)ost` to initialize Node 0 and Nodes 1-3.
2. On a second machine (or the same one), execute `python harness_split.py` and select `(J)oin` using the 4-character lobby code to initialize Nodes 4-7.

The nodes will automatically establish quorum and maintain deterministic consensus via the hosted relay.

---

## ⚙️ Runtime Controls

| Key | Action | Description |
| :--- | :--- | :--- |
| **`F5`** | 🔄 Hot-Reload | Rebuilds and applies shader pipelines instantly. |
| **`1`** / **`2`** / **`3`** | 🎯 Render Modes | Toggles between Dual, Geometry, and Point rendering modes. |
| **`ESC`** | 🛑 Teardown | Initiates a graceful, memory-safe engine shutdown. |

---
*Built with precision. Engineered for synchronization.*
