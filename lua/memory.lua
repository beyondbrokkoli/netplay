-- lua/memory.lua
local ffi = require("ffi")

local is_windows = (jit.os == "Windows")
if is_windows then
    ffi.cdef[[
        void* _aligned_malloc(size_t size, size_t alignment);
        void _aligned_free(void* ptr);
    ]]
else
    ffi.cdef[[
        void* aligned_alloc(size_t alignment, size_t size);
        void free(void* ptr);
    ]]
end

local function platform_aligned_alloc(alignment, size)
    if is_windows then return ffi.C._aligned_malloc(size, alignment)
    else return ffi.C.aligned_alloc(alignment, size) end
end

local function platform_aligned_free(ptr)
    if is_windows then ffi.C._aligned_free(ptr)
    else ffi.C.free(ptr) end
end

local Memory = {
    AVX_Arrays = {}
}

-- The Lego Brick for deterministic CPU arrays
function Memory.AllocateSoA(type_str, count, names)
    local base_type = string.gsub(type_str, "%[.-%]", "")
    local byte_size = ffi.sizeof(base_type) * count
    local align_bytes = 32 -- AVX2/AVX-512 friendly alignment

    for i = 1, #names do
        local raw_ptr = platform_aligned_alloc(align_bytes, byte_size)
        assert(raw_ptr ~= nil, "FATAL: C-Allocator failed to provide aligned memory!")
        Memory.AVX_Arrays[names[i]] = ffi.cast(base_type .. "*", raw_ptr)
        print(string.format("[MEMORY] Allocated Fast CPU RAM: %s (%.2f MB)", names[i], byte_size / (1024*1024)))
    end
end

function Memory.FreeSoA(names)
    for i = 1, #names do
        local ptr = Memory.AVX_Arrays[names[i]]
        if ptr then
            platform_aligned_free(ptr)
            Memory.AVX_Arrays[names[i]] = nil
        end
    end
end

return Memory
