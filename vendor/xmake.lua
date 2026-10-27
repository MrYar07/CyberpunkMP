target("RED4ext.SDK")
    set_kind("static")
    set_group("vendor")
    add_files("RED4ext.SDK/src/**.cpp")
    add_headerfiles("RED4ext.SDK/include/**.hpp")
    add_includedirs("RED4ext.SDK/include/", { public = true })
    -- The upstream SDK carries D3D12MemAlloc.h for its GpuApi sources (its CMake adds this path).
    add_includedirs("RED4ext.SDK/vendor/D3D12MemAlloc/", { public = true })
    on_install(function() end)
