rule("archive")
    set_extensions(".archive")
    -- on_build_file(function (target, sourcefile, opt)
    --     os.cp(sourcefile, path.join(target:targetdir(), path.basename(sourcefile) .. ".archive"))
    -- end)
    on_install(function (target)
        print("on_install")
        for _, sourcebatch in pairs(target:sourcebatches()) do
            local sourcekind = sourcebatch.rulename
            if sourcekind == "archive" then
                for _, sourcefile in ipairs(sourcebatch.sourcefiles) do
                    os.cp(sourcefile, path.join(target:installdir("launcher"), "mod", "assets", "Archives", path.basename(sourcefile) .. ".archive"))
                end
            end
        end
    end)

target("Archives")
    if is_mode("debug") then
        add_defines("TP_ARCHIVES_LOCATION=\"../../../../code/assets/Archives/packed/archive/pc/mod/\"", {public = true})
    else 
        add_defines("TP_ARCHIVES_LOCATION=\"assets/Archives\"", {public = true})
    end 
    set_kind("headeronly")
    set_group("Assets")
    add_rules("archive")
    add_files("packed/archive/pc/mod/CyberpunkMP.archive")

    -- The campaign guest start. Guests must not run quests of their own (the host's game
    -- runs the story), and a running quest cannot be stopped, only kept from starting.
    -- This replaces ep1\quest\ep1_standalone.gamedef - the "Phantom Liberty" start - with
    -- Night City Online's clean start (nco 9e1832f, proven in game): base Night City with
    -- the prologue skipped, the EP1 world without its story, the preorder Quadra; spawn
    -- #q000_spwn_start. The campaign lobby sends guests through that start and the host
    -- through the normal one. Source: source/archive/ep1/quest/ep1_standalone.gamedef.
    add_files("packed/archive/pc/mod/zz_CampaignCoop_GuestStart.archive")