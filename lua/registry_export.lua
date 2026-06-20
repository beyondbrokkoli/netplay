-- lua/registry_export.lua
local structs_mod = require("structs")
local cfg = nil
pcall(function() cfg = require("config_gfx") end)

local reg = nil
pcall(function() reg = require("registry_vk") end)

local function get_sorted_keys(t)
    local keys = {}
    for k in pairs(t) do table.insert(keys, k) end
    table.sort(keys)
    return keys
end

local function map_glsl_type(type_str)
    if type_str == "float" then return "float" end
    if string.find(type_str, "mat4") then return "mat4" end
    return "uint" -- Default primitive integer mapping
end

local function generate_ssot(glsl_path, c_header_path)
    local glsl = io.open(glsl_path, "w")
    local c_hdr = io.open(c_header_path, "w")

    -- 1. HEADERS
    glsl:write("// AUTO-GENERATED SSoT - DO NOT MODIFY\n")
    glsl:write("#ifndef REGISTRY_GLSL\n#define REGISTRY_GLSL\n\n")
    c_hdr:write("// AUTO-GENERATED SSoT - DO NOT MODIFY\n")
    c_hdr:write("#pragma once\n#include <stdint.h>\n\n")

    -- 2. CONSTANTS
    if cfg then
        glsl:write("// --- CONSTANTS ---\n")
        c_hdr:write("// --- ENGINE CONSTANTS ---\n")

        if cfg.mode then
            for _, k in ipairs(get_sorted_keys(cfg.mode)) do
                glsl:write(string.format("const uint MODE_%s = %dU;\n", string.upper(k), cfg.mode[k]))
                c_hdr:write(string.format("#define MODE_%s %d\n", string.upper(k), cfg.mode[k]))
            end
        end
        if cfg.net_state then
            for _, k in ipairs(get_sorted_keys(cfg.net_state)) do
                c_hdr:write(string.format("#define FRAME_STATE_%s %d\n", string.upper(k), cfg.net_state[k]))
            end
        end

        if cfg.world then
            for _, k in ipairs(get_sorted_keys(cfg.world)) do
                local val = cfg.world[k]
                if type(val) == "number" then
                    if math.floor(val) == val then
                        glsl:write(string.format("const uint WORLD_%s = %dU;\n", string.upper(k), val))
                        c_hdr:write(string.format("#define WORLD_%s %d\n", string.upper(k), val))
                    else
                        glsl:write(string.format("const float WORLD_%s = %.1f;\n", string.upper(k), val))
                        c_hdr:write(string.format("#define WORLD_%s %.1ff\n", string.upper(k), val))
                    end
                end
            end
        end
        c_hdr:write("\n")
    end

    -- 3. INTERLOCKING ALIGNMENT REGISTRY
    local dynamic_sizes = {
        float = 4, uint32_t = 4, int32_t = 4,
        uint64_t = 8, int64_t = 8,
        uint16_t = 2, int16_t = 2,
        uint8_t = 1, int8_t = 1
    }

    local function resolve_member_size(type_str)
        if dynamic_sizes[type_str] then return dynamic_sizes[type_str] end
        if string.find(type_str, "*") then return 8 end
        if string.find(type_str, "64") then return 8 end
        if string.find(type_str, "32") or type_str == "float" then return 4 end
        if string.find(type_str, "16") then return 2 end
        if string.find(type_str, "8") then return 1 end
        return dynamic_sizes[type_str] or 64
    end

    glsl:write("\n// --- std430 SSBO DEFINITIONS ---\n")
    c_hdr:write("// --- ENGINE MEMORY STRUCTURES ---\n")

    for _, struct in ipairs(structs_mod.specs) do
        local is_glsl = not struct.c_only and not struct.wire_format

        -- C-Side Declaration
        if struct.wire_format then
            c_hdr:write("#pragma pack(push, 1)\n")
            c_hdr:write(string.format("typedef struct {\n"))
        else
            local attr = struct.force_align and "__attribute__((packed, aligned("..struct.align..")))" or "__attribute__((packed))"
            c_hdr:write(string.format("typedef struct %s {\n", attr))
        end

        -- GLSL-Side Declaration
        if is_glsl then
            glsl:write(string.format("struct %s {\n", struct.name))
        end

        local offset = 0
        local pad_id = 0

        for _, m in ipairs(struct.members) do
            local m_size = resolve_member_size(m.type)

            -- C-Side Padding for std140/std430 sync (Only if not a network wire format)
            if not struct.wire_format then
                local rem = offset % m_size
                if rem ~= 0 then
                    local pad_bytes = m_size - rem
                    c_hdr:write(string.format("    uint8_t _pad_auto_%d[%d];\n", pad_id, pad_bytes))
                    if is_glsl then
                        glsl:write(string.format("    // Engine injected %d pad bytes for std430\n", pad_bytes))
                    end
                    offset = offset + pad_bytes
                    pad_id = pad_id + 1
                end
            end

            -- Array Processing
            local arr_str = ""
            local element_count = 1
            if type(m.count) == "table" then
                for _, dim in ipairs(m.count) do
                    arr_str = arr_str .. string.format("[%d]", dim)
                    element_count = element_count * dim
                end
            elseif m.count then
                arr_str = string.format("[%d]", m.count)
                element_count = m.count
            end

            -- Member Write
            c_hdr:write(string.format("    %s %s%s;\n", m.type, m.name, arr_str))

            if is_glsl then
                local glsl_type = map_glsl_type(m.type)
                glsl:write(string.format("    %s %s%s;\n", glsl_type, m.name, arr_str))
            end

            local real_size = m_size * element_count
            if dynamic_sizes[m.type] then
                 real_size = dynamic_sizes[m.type] * element_count
            end
            offset = offset + real_size
        end

        -- Tail Processing
        if not struct.wire_format then
            local tail_rem = offset % struct.align
            if tail_rem ~= 0 then
                local tail_pad = struct.align - tail_rem
                c_hdr:write(string.format("    uint8_t _pad_tail[%d];\n", tail_pad))
                if is_glsl then
                    glsl:write(string.format("    // Tail padded by %d bytes\n", tail_pad))
                end
                offset = offset + tail_pad
            end
            c_hdr:write("} " .. struct.name .. ";\n\n")
        else
            c_hdr:write("} " .. struct.name .. ";\n")
            c_hdr:write("#pragma pack(pop)\n\n")
        end

        if is_glsl then
            glsl:write("};\n\n")
        end

        dynamic_sizes[struct.name] = offset
    end

    -- 4. VULKAN HOST INTERFACES INJECTION
    if reg and reg.c_vk_structs then
        c_hdr:write("#ifdef VX_ENABLE_VULKAN_STRUCTS\n")
        c_hdr:write(reg.c_vk_structs)
        c_hdr:write("\n#endif // VX_ENABLE_VULKAN_STRUCTS\n")
    end

    glsl:write("#endif // REGISTRY_GLSL\n")
    glsl:close()
    c_hdr:close()

    print("[LUA SSOT] V2 Core & Network SSoT Generated (C & GLSL synced).")
end

return { generate = generate_ssot }
