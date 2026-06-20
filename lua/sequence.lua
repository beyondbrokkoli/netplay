-- lua/sequence.lua
local ffi = require("ffi")

local cfg = require("config_engine")
local reg = require("registry_vk")
local manifest = require("pipeline_manifest")

local seq = {}

seq.boot = {
    {
        name = "Vulkan Instance",
        action = function(ctx)
            local vulkan = require("vulkan_core")
            ctx.vk_runtime = vulkan.create_instance(reg.vk_reqs.instance_ext)
            ffi.cdef("void vx_sys_publish_instance(void* instance);")
            ffi.C.vx_sys_publish_instance(ctx.vk_runtime.instance)
        end
    },
    {
        name = "GLFW Window Boot",
        action = function(ctx)
            print("[WEAVER] Ordering C-Core to Boot GLFW Window...")
            ffi.C.vx_sys_set_cmd(cfg.sys.boot, cfg.win.w, cfg.win.h)
            return "AWAIT_SURFACE" -- Yields back to main.lua until the C-Core creates the window
        end
    },
    {
        name = "Vulkan Logical Device",
        action = function(ctx)
            local vulkan = require("vulkan_core")
            local surface_ptr = ffi.C.vx_sys_get_surface()
            vulkan.finalize_device_and_swapchain(ctx.vk_runtime, surface_ptr, reg.vk_reqs.device_ext)
        end
    },
    {
        name = "Memory Arenas Allocation",
        action = function(ctx)
            local memory = require("memory")
            local cfg_sim = require("config_sim") -- Only needed to know how big the grid is

            memory.InitTransferSubsystem(ctx.vk_runtime)

            -- EXPLICIT Domain B Memory Allocation. No arena_manager.lua.
            local grid_bytes = cfg_sim.world.grid_cells * 16 -- sizeof(RtsTileInstance)
            local gpu_bytes = math.floor(grid_bytes * 8 * 1.1) -- 8 Dimensions + Margin

            -- Usage: 32 (Transfer Src) | 128 (Storage) | 256 (Transfer Dst)
            memory.CreateHostVisibleBuffer("MASTER_GPU_BLOCK", "uint8_t", gpu_bytes, 416, ctx.vk_runtime)

            -- Usage: 64 (Index Buffer) | 256 (Transfer Dst)
            memory.CreateHostVisibleBuffer("MASTER_INDEX_BLOCK", "uint32_t", cfg_sim.world.grid_cells * 6, 320, ctx.vk_runtime)

            print("[WEAVER] Strict VRAM Mapping Complete.")
        end
    },
    {
        name = "Swapchain Initialization",
        action = function(ctx)
            local swapchain = require("swapchain")
            ctx.sc_state = swapchain.Init(ctx.vk_runtime.vk, ctx.vk_runtime, cfg.win.w, cfg.win.h, ctx.old_swapchain)
        end
    },
    {
        name = "Descriptors Matrix",
        action = function(ctx)
            local descriptors = require("descriptors")
            local memory = require("memory")
            -- Pulling the hardware pointers we just created in Step 4
            local master_gpu_buffer = memory.Buffers["MASTER_GPU_BLOCK"]
            local palette_haven_buffer = memory.Buffers["PALETTE_HAVEN"]
            ctx.desc_state = descriptors.Init(ctx.vk_runtime.vk, ctx.vk_runtime.device, master_gpu_buffer, palette_haven_buffer)
        end
    },
    {
        name = "Compute Graph Pipelines",
        action = function(ctx)
            local compute = require("compute_pipeline")
            local layout = ctx.desc_state.pipelineLayout
            -- Wrap in pcall in case the compute shaders aren't moved over yet
            local status, comp = pcall(compute.Init, ctx.vk_runtime.vk, ctx.vk_runtime.device, layout, manifest.compute)
            if status then ctx.comp_state = comp end
        end
    },
    {
        name = "Graphics Pipelines & Depth Buffer",
        action = function(ctx)
            local graphics = require("graphics_pipeline")
            local layout = ctx.desc_state.pipelineLayout
            local colorFormat = ctx.sc_state.format
            ctx.gfx_state = graphics.Init(
                ctx.vk_runtime.vk, ctx.vk_runtime, cfg.win.w, cfg.win.h,
                layout, colorFormat, manifest.graphics
            )
        end
    },
    {
        name = "Renderer Synchronization",
        action = function(ctx)
            local renderer = require("renderer")
            ctx.sync_state = renderer.InitSync(ctx.vk_runtime.vk, ctx.vk_runtime.device, cfg.cfg.frame_slots)
        end
    },
    {
        name = "Async Overlord Handoff",
        action = function(ctx)
            print("[WEAVER] Packing C-Core Mailbox and firing Render Thread...")
            local vk, dev = ctx.vk_runtime.vk, ctx.vk_runtime.device
            local sc, sync = ctx.sc_state, ctx.sync_state

            local wsi = ffi.new("RenderThreadInit")
            wsi.device = dev
            wsi.queue = ctx.vk_runtime.queue
            wsi.transfer_queue = ctx.vk_runtime.transferQueue
            wsi.swapchain = sc.handle

            for i = 0, sc.imageCount - 1 do
                wsi.swapchain_images[i] = ffi.cast("uint64_t", sc.images[i])
                wsi.swapchain_views[i]  = ffi.cast("uint64_t", sc.imageViews[i])
            end

            for i = 0, cfg.cfg.frame_slots - 1 do
                wsi.image_available[i] = sync.imageAvailable[i]
                wsi.render_finished[i] = sync.renderFinished[i]
                wsi.in_flight[i]       = sync.inFlight[i]
            end

            wsi.vkWaitForFences         = ffi.cast("void*", vk.vkGetDeviceProcAddr(dev, "vkWaitForFences"))
            wsi.vkAcquireNextImageKHR = ffi.cast("void*", vk.vkGetDeviceProcAddr(dev, "vkAcquireNextImageKHR"))
            wsi.vkResetFences           = ffi.cast("void*", vk.vkGetDeviceProcAddr(dev, "vkResetFences"))
            wsi.vkQueueSubmit           = ffi.cast("void*", vk.vkGetDeviceProcAddr(dev, "vkQueueSubmit"))
            wsi.vkQueuePresentKHR       = ffi.cast("void*", vk.vkGetDeviceProcAddr(dev, "vkQueuePresentKHR"))
            wsi.pfnBegin                = ffi.cast("void*", vk.vkGetDeviceProcAddr(dev, "vkCmdBeginRenderingKHR"))
            wsi.pfnEnd                  = ffi.cast("void*", vk.vkGetDeviceProcAddr(dev, "vkCmdEndRenderingKHR"))
            wsi.pfnSetCullMode          = vk.vkGetDeviceProcAddr(dev, "vkCmdSetCullModeEXT")
            wsi.pfnSetFrontFace         = vk.vkGetDeviceProcAddr(dev, "vkCmdSetFrontFaceEXT")
            wsi.pfnSetPrimitiveTopology = vk.vkGetDeviceProcAddr(dev, "vkCmdSetPrimitiveTopologyEXT")
            wsi.pfnSetDepthTestEnable   = vk.vkGetDeviceProcAddr(dev, "vkCmdSetDepthTestEnableEXT")
            wsi.pfnSetDepthWriteEnable  = vk.vkGetDeviceProcAddr(dev, "vkCmdSetDepthWriteEnableEXT")
            wsi.pfnSetDepthCompareOp    = vk.vkGetDeviceProcAddr(dev, "vkCmdSetDepthCompareOpEXT")

            ffi.cdef[[
                void vx_stream_init(RenderThreadInit* wsi);
                void vx_thread_start();
                void vx_transfer_setup(uint32_t q_family_index);
                int vx_transfer_request(uint64_t src, uint64_t dst, uint64_t size, uint64_t t_sem, uint64_t sig_val);
            ]]

            ffi.C.vx_transfer_setup(ctx.vk_runtime.tIndex)
            ffi.C.vx_stream_init(wsi)
            ffi.C.vx_thread_start()
            print("[WEAVER] Engine Initialization Complete. Async Overlord is LIVE.")
        end
    }
}

-- Resize hook (bypassing the memory allocation steps, just refreshing graphics)
seq.resize = { seq.boot[5], seq.boot[8], seq.boot[9] }

return seq
