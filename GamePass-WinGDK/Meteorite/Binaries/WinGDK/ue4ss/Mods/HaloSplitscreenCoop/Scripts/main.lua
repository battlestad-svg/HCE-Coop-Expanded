-- Halo: Campaign Evolved - Co-op Expanded
-- v1.11.0 development build
--
-- Adds a second local player to the PC build, so campaign co-op can be played
-- split-screen on one machine.
--
-- Based on the SplitScreenMod example bundled with RE-UE4SS (MIT, (c) 2022 Narknon).
-- Changes on top of that example are the two Meteorite-specific fixes below:
--   1. releasing the new player's viewport hold, and
--   2. building the new player's HUD through the game's own UI manager.
--
-- Side-by-side split, two-gamepad input routing, the original HUD scale correction
-- and HUD geometry diagnostic come from JoacoL999 (Nexus: joaqo455), used with
-- permission. The adaptive HUD strategy is informed by HCE Revival v0.6.1 by
-- bfixer117 (MIT): per-user HUDAnchoring=Edges + aspect-ratio ApplicationScale +
-- Halo UI invalidation and resolution-change reflow. HCE Revival v0.6.2 also
-- demonstrated the Halo-native FireteamHeader load-confirmation technique and the
-- one-controller bOffsetPlayerGamepadIds + UE5 device-id remap path used here.
-- The release keeps the project-owned xinput1_4.dll route and adds the
-- HCEXInputSteamBypass adaptive companion for Controllers=1. Both follow the
-- HaloSplitscreenCoop\settings.ini Controllers value resolved at startup.
-- See LICENSE.txt and HCE_REVIVAL_LICENSE.txt.
--
-- USAGE (order matters - see README.txt):
--   Co-op Campaign -> A on the P2 gamepad (Ctrl+Y fallback) -> start a NEW campaign save.
--   Frontend with P2 joined -> hold A on the P2 gamepad for about 2 seconds (Ctrl+U fallback) -> leave local co-op.

local UEHelpers = require("UEHelpers")

local GetGameplayStatics = UEHelpers.GetGameplayStatics
local GetGameMapsSettings = UEHelpers.GetGameMapsSettings
local GetKismetSystemLibrary = UEHelpers.GetKismetSystemLibrary

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------

-- How the two viewports are arranged.
--   "auto"       - side-by-side on 16:9 and ultrawide displays; top/bottom otherwise.
--   "sidebyside" - always left/right.
--   "stacked"    - always top/bottom.
-- Ctrl+O toggles this at runtime.
local SplitOrientation = "auto"

-- Ordinary 16:9 displays use left/right split automatically.
-- A tolerance is used because window borders and unusual resolutions rarely report
-- exactly 16/9. Ultrawide behavior remains the same as the original v1.1.0 mod.
local Auto16x9AspectMin = 1.65
local Auto16x9AspectMax = 1.90
local AutoSideBySideAspect = 2.0

-- How the physical controllers are handed out. The public setting is read from
-- HaloSplitscreenCoop\settings.ini at startup:
--   Controllers=2 (default) - gamepad 1 -> player 1, gamepad 2 -> player 2.
--                              Player 1 may still use keyboard/mouse.
--   Controllers=1           - keyboard/mouse -> player 1, first gamepad -> player 2.
--                              On Steam, the adaptive native router supports both
--                              native XInput and Steam Input virtual gamepads.
--
-- The setting is resolved once at startup into this boolean. No controller-count
-- detector is used for the public mode selection. Unreal calls the inverse of this
-- "Skip Assigning Gamepad to Player 1", which is why it is written to
-- bOffsetPlayerGamepadIds negated.
--
-- Verified Controllers=1 Steam paths for v1.10.0 include Xbox,
-- DualSense/PS5, 8BitDo Lite 2 and PS3-class controllers through Steam Input,
-- including wired/wireless use and connection both before and after Halo launch.
-- WinGDK/Game Pass intentionally supports Controllers=1 only through native Xbox/XInput.
local UseTwoGamepads = true


-- Side-by-side HUD trim. Placement is handled by Halo's own per-user
-- HUDAnchoring="Edges" setting; ApplicationScale now only compensates for the
-- output aspect ratio. 1.000 means use the automatic value unchanged.
--
-- Automatic scale = (window_width * 9 / 16) / window_height
--   1920x1080 -> 1.000
--   2560x1440 -> 1.000
--   3440x1440 -> 1.344
--   5120x1440 -> 2.000
--
-- The public build keeps the automatic scale at its neutral trim.
local HudScaleTaste = 1.000

-- ETwoPlayerSplitScreenType. The name refers to the DIVIDER, not the stacking:
-- Vertical means a vertical dividing line, i.e. players side by side.
local TwoPlayerSplitLayout = {
    Horizontal = 0,     -- top / bottom
    Vertical = 1,       -- left / right
}

local LogPrefix = "[CoopExpanded] "

local function Log(Format, ...)
    print(LogPrefix .. string.format(Format, ...) .. "\n")
end

-- ---------------------------------------------------------------------------
-- Meteorite-specific fixes
-- ---------------------------------------------------------------------------

-- Every LocalPlayer's viewport is gated behind UMeteoriteViewportHoldLocalPlayerSubsystem,
-- which holds an opaque overlay until that player's streaming reports ready. A player
-- created by the mod never satisfies that release condition, so its half of the screen
-- would otherwise sit on a frozen loading overlay. Per the cvar's own help text:
-- "If 0, viewport holds are no-ops; any active hold is released on the next tick."
local ViewportHoldCVar = "Meteorite.ViewportHold.Enabled"

-- Returns the live instance of a class, skipping the class default object.
local function FindLive(ClassName)
    local Found = FindAllOf(ClassName)
    if Found then
        for _, Obj in ipairs(Found) do
            if Obj:IsValid() and not string.find(Obj:GetFullName(), "Default__") then
                return Obj
            end
        end
    end
    return nil
end

function ProtectedObjectIsValid(Object)
    return Object:IsValid()
end

local function IsValidObject(Object)
    if not Object then
        return false
    end

    -- This guard is used throughout every hot path. A named protected target
    -- avoids creating a fresh closure for each validity check while retaining
    -- the exact same fail-closed UObject behavior.
    local Ok, Valid = pcall(ProtectedObjectIsValid, Object)
    return Ok and Valid
end

-- Event-only world classification used to keep frontend UI listeners out of
-- active campaign gameplay. This performs no polling and is only queried when a
-- frontend/squad widget construction event already fired.
local function CurrentWorldSessionKind()
    local WorldName = ""
    pcall(function()
        local World = UEHelpers.GetWorldContextObject()
        if IsValidObject(World) then WorldName = World:GetFullName() end
    end)
    local LowerWorld = string.lower(tostring(WorldName or ""))
    if string.find(LowerWorld, "/game/levels/halo1/solo/", 1, true) then return "campaign" end
    if string.find(LowerWorld, "/game/levels/test/seamlesstraveltest", 1, true) then return "transition" end
    if string.find(LowerWorld, "/game/levels/ui/frontend/", 1, true) then return "frontend" end
    if LowerWorld == "" then return "unknown" end
    return "other"
end

-- Use Halo's own fireteam header as a lightweight load confirmation.
-- HCE Revival v0.6.2 demonstrated that WBP_SquadWidget_C.FireteamHeader can be
-- safely replaced with a short FText once the frontend squad widget exists.
-- This is startup-only and adds no gameplay polling or HUD transform changes.
local StartupHeaderApplied = false

local function ApplyLoadedHeader(Attempt, Force)
    if StartupHeaderApplied and not Force then return end
    Attempt = Attempt or 1

    ExecuteInGameThreadWithDelay(0, function()
        if StartupHeaderApplied and not Force then return end

        -- WBP_SquadWidget_C can be reconstructed while a campaign is still
        -- active. Never run the frontend FindAllOf/header path in that world.
        local SessionKind = CurrentWorldSessionKind()
        if SessionKind == "campaign" or SessionKind == "transition" then return end

        local UpdatedHeaders = 0
        local Ok, Err = pcall(function()
            local TextLibrary = StaticFindObject("/Script/Engine.Default__KismetTextLibrary")
            if not IsValidObject(TextLibrary) then
                error("KismetTextLibrary unavailable")
            end

            local LoadedText = TextLibrary:Conv_StringToText("HCE CO-OP EXPANDED LOADED")
            local SquadWidgets = FindAllOf("WBP_SquadWidget_C") or {}
            for _, SquadWidget in ipairs(SquadWidgets) do
                if IsValidObject(SquadWidget) then
                    local Header = nil
                    pcall(function() Header = SquadWidget.FireteamHeader end)
                    if IsValidObject(Header) then
                        Header:SetText(LoadedText)
                        UpdatedHeaders = UpdatedHeaders + 1
                    end
                end
            end
        end)

        if not Ok then
            Log("Frontend load header failed: %s", tostring(Err))
            return
        end

        if UpdatedHeaders > 0 then
            StartupHeaderApplied = true
            if HandleFrontendRespawnBoundary ~= nil then
                pcall(function() HandleFrontendRespawnBoundary("fireteam header") end)
            end
            Log("Frontend load header applied to %d fireteam widget(s)", UpdatedHeaders)
            return
        end

        -- Fast-path retries cover cases where the squad widget is already being
        -- constructed. NotifyOnNewObject below handles arbitrarily slow first boots.
        if Attempt < 10 then
            ExecuteInGameThreadWithDelay(2000, function()
                ApplyLoadedHeader(Attempt + 1, Force)
            end)
        else
            Log("Frontend load header waiting for WBP_SquadWidget_C")
        end
    end)
end

local function RegisterLoadedHeader()
    local Ok, Err = pcall(function()
        NotifyOnNewObject(
            "/Game/UI/Shared/Widgets/Squad/WBP_SquadWidget.WBP_SquadWidget_C",
            function()
                ExecuteInGameThreadWithDelay(250, function()
                    ApplyLoadedHeader(1, true)
                end)
            end
        )
    end)

    if Ok then
        Log("Frontend load-header listener ready")
    else
        Log("Frontend load-header listener unavailable; startup retries only: %s", tostring(Err))
    end

    -- Also try immediately in case the widget existed before registration.
    ApplyLoadedHeader(1)
end

-- The game's own UI manager owns the per-player HUD layouts (PlayerHaloUILayouts).
-- Creating a player via GameplayStatics bypasses it, so player 2 gets a viewport but
-- no HUD at all. HaloUIManagerSubsystem::EnableSplitscreen() takes no parameters.
-- PERF: FindLive() performs a global object scan, so retain the live subsystem
-- while it remains valid instead of rediscovering it on every bounded HUD repair.
HaloUIManagerCache = nil
local function EnableHaloUISplitscreen()
    local Mgr = HaloUIManagerCache
    if not IsValidObject(Mgr) then
        Mgr = FindLive("HaloUIManagerSubsystem")
        if IsValidObject(Mgr) then HaloUIManagerCache = Mgr end
    end
    if not IsValidObject(Mgr) then
        HaloUIManagerCache = nil
        Log("HaloUIManagerSubsystem not found - cannot enable HUD splitscreen")
        return false
    end
    local Ok, Err = pcall(function() Mgr:EnableSplitscreen() end)
    if not Ok then HaloUIManagerCache = nil end
    Log("HaloUI EnableSplitscreen -> %s%s", tostring(Ok), Ok and "" or (" (" .. tostring(Err) .. ")"))
    return Ok
end

-- Menu-only local-P2 removal needs to return Halo UI to its one-player
-- layout. This is never polled in gameplay; it is called only after Ctrl+U.
local function DisableHaloUISplitscreen()
    local Mgr = HaloUIManagerCache
    if not IsValidObject(Mgr) then
        Mgr = FindLive("HaloUIManagerSubsystem")
        if IsValidObject(Mgr) then HaloUIManagerCache = Mgr end
    end
    if not IsValidObject(Mgr) then return false end
    local Ok = pcall(function() Mgr:DisableSplitscreen() end)
    if not Ok then HaloUIManagerCache = nil end
    return Ok
end

-- Two routes, because the game is a Shipping build and we cannot assume either is
-- callable. Both are wrapped so a failure never takes the mod down with it.
--
-- Note this reports DISPATCH, not effect: a cvar that does not exist dispatches
-- just as happily as one that does.
local function RunConsoleCommand(Command)
    local Ok = false
    local Route = "none"

    pcall(function()
        local KSL = GetKismetSystemLibrary()
        local Ctx = UEHelpers.GetWorldContextObject()
        if KSL:IsValid() and Ctx:IsValid() then
            KSL:ExecuteConsoleCommand(Ctx, Command, nil)
            Ok = true
            Route = "KismetSystemLibrary"
        end
    end)

    if not Ok then
        pcall(function()
            local PC = UEHelpers.GetPlayerController()
            if PC:IsValid() then
                PC:ConsoleCommand(Command, true)
                Ok = true
                Route = "PlayerController"
            end
        end)
    end

    Log("Console '%s' dispatched: %s (%s)", Command, tostring(Ok), Route)
    return Ok
end

-- ---------------------------------------------------------------------------
-- UMG helpers
-- ---------------------------------------------------------------------------

-- This library exists only as a class default object, so FindLive can never return
-- it - FindLive deliberately skips anything named Default__. Fetch it by path.
local function GetWidgetLayoutLibrary()
    return StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary")
end

-- UUserInterfaceSettings is a config class and likewise CDO-only. The FindAllOf pass
-- is a fallback in case this fork registers it under a different package.
local function GetUserInterfaceSettings()
    local Settings = StaticFindObject("/Script/Engine.Default__UserInterfaceSettings")
    if IsValidObject(Settings) then
        return Settings
    end

    local Found = FindAllOf("UserInterfaceSettings")
    if Found then
        for _, Candidate in ipairs(Found) do
            if IsValidObject(Candidate) then
                return Candidate
            end
        end
    end

    return nil
end

local function FormatVector2D(Vector)
    if not Vector then
        return "unavailable"
    end

    local Ok, Result = pcall(function()
        return string.format("%.1f x %.1f", Vector.X, Vector.Y)
    end)
    return Ok and Result or "unreadable"
end

-- Full game viewport, not a player's half.
local function GetViewportSize()
    local Library = GetWidgetLayoutLibrary()
    if not IsValidObject(Library) then
        return nil
    end

    local Size = nil
    pcall(function()
        Size = Library:GetViewportSize(UEHelpers.GetWorldContextObject())
    end)
    return Size
end

-- ---------------------------------------------------------------------------
-- Orientation
-- ---------------------------------------------------------------------------

-- Resolves "auto" against the live viewport. Falls back to stacked - the engine's
-- own default - if the viewport cannot be read, so an unreadable value never
-- silently changes the layout out from under a 16:9 player.
local function WantsSideBySide()
    if SplitOrientation == "sidebyside" then
        return true
    elseif SplitOrientation == "stacked" then
        return false
    end

    local Size = GetViewportSize()
    if not Size then
        Log("Viewport size unreadable; auto orientation falling back to top/bottom.")
        return false
    end

    local Aspect = nil
    pcall(function()
        if Size.Y > 0 then
            Aspect = Size.X / Size.Y
        end
    end)

    if not Aspect then
        return false
    end

    local Is16x9 = Aspect >= Auto16x9AspectMin and Aspect <= Auto16x9AspectMax
    local IsUltrawide = Aspect >= AutoSideBySideAspect
    local SideBySide = Is16x9 or IsUltrawide
    Log(
        "Auto orientation: viewport %s (%.2f:1, 16:9=%s, ultrawide=%s) -> %s",
        FormatVector2D(Size),
        Aspect,
        tostring(Is16x9),
        tostring(IsUltrawide),
        SideBySide and "left/right" or "top/bottom"
    )
    return SideBySide
end

-- ---------------------------------------------------------------------------
-- HUD scale + anchoring
--
-- Side-by-side viewports are tall and narrow. Halo's centered HUD anchoring pulls
-- widgets toward the middle of each half, which can look like a DPI/scaling bug.
-- The production HUD path separates anchoring from output-aspect compensation:
--   * each local user's Halo HUDAnchoring is temporarily forced to "Edges" while
--     side-by-side is active, then restored when leaving side-by-side;
--   * ApplicationScale only compensates for the full output aspect ratio using
--       (width * 9 / 16) / height
--     so 16:9 stays at 1.0 while 3440x1440 becomes about 1.344;
--   * HaloUIManagerSubsystem::InvalidateAllWidgets(false) is used after an actual
--     scale/anchoring change so the live HUD reflows without per-frame work.
--
-- This approach is event/boundary driven: join, mission HUD construction,
-- orientation change, cinematic enter/exit and menu removal. Nothing here adds a
-- new gameplay polling loop.
-- ---------------------------------------------------------------------------

-- ApplicationScale as it was before this mod touched it, captured on first write.
local OriginalApplicationScale = nil
local HudScaleApplied = false

-- Globals are intentional: this main chunk is close to Lua's local-variable limit.
SavedHudAnchoring = SavedHudAnchoring or {}

-- Resolution changes can rebuild the live UMG geometry after the initial
-- adaptive-HUD pass. Sample only once every 30 P1 ReceiveTicks and queue a
-- callback-independent relayout after fullscreen settings menus close. Globals
-- keep the main chunk below Lua's local-variable limit.
ActiveSideBySide = ActiveSideBySide or false
LastViewportW = LastViewportW or nil
LastViewportH = LastViewportH or nil
HudRelayoutTicks = HudRelayoutTicks or 0
HudRelayoutReason = HudRelayoutReason or ""
PauseCloseHookArmed = PauseCloseHookArmed or false

function ReadHudAnchoring(Settings)
    if not IsValidObject(Settings) then return "" end
    local Value = nil
    local Ok = pcall(function()
        Value = Settings:GetStringValueFromName(FName("HUDAnchoring"))
    end)
    if not Ok or Value == nil then return "" end
    if type(Value) == "string" then return Value end
    local Text = ""
    pcall(function() Text = Value:ToString() end)
    if type(Text) ~= "string" then return "" end
    if string.find(Text, "FString:", 1, true) then return "" end
    return Text
end

function ApplyHudAnchoring(WantEdges, Reason, ForceApply)
    local Changed = false
    local Applied = 0

    for PlayerIndex = 1, 2 do
        local Settings = nil
        if GetUserSettings ~= nil then
            pcall(function() Settings = select(1, GetUserSettings(PlayerIndex)) end)
        end

        if IsValidObject(Settings) then
            local Current = ReadHudAnchoring(Settings)
            local Target = nil

            if WantEdges then
                if SavedHudAnchoring[PlayerIndex] == nil and Current ~= "" then
                    SavedHudAnchoring[PlayerIndex] = Current
                    Log("HUD saved P%d anchoring=%s", PlayerIndex, Current)
                end
                Target = "Edges"
            else
                Target = SavedHudAnchoring[PlayerIndex]
            end

            if Target ~= nil and Target ~= "" and (Current ~= Target or ForceApply == true) then
                local Ok, Err = pcall(function()
                    Settings:SetStringValueFromName(FName("HUDAnchoring"), Target)
                    Settings:ApplyHaloUserSettings()
                end)
                if Ok then
                    Changed = true
                    Applied = Applied + 1
                    Log("HUD P%d anchoring -> %s (%s%s)", PlayerIndex, Target, tostring(Reason),
                        ForceApply == true and ", forced reapply" or "")
                else
                    Log("HUD P%d anchoring write failed: %s", PlayerIndex, tostring(Err))
                end
            end

            if not WantEdges then
                SavedHudAnchoring[PlayerIndex] = nil
            end
        elseif not WantEdges then
            -- Do not keep stale saved values across a local-player teardown.
            SavedHudAnchoring[PlayerIndex] = nil
        end
    end

    return Changed, Applied
end

function InvalidateHaloWidgets(Reason)
    local Mgr = HaloUIManagerCache
    if not IsValidObject(Mgr) then
        Mgr = FindLive("HaloUIManagerSubsystem")
        if IsValidObject(Mgr) then HaloUIManagerCache = Mgr end
    end
    if not IsValidObject(Mgr) then
        HaloUIManagerCache = nil
        return false
    end

    local Ok, Err = pcall(function() Mgr:InvalidateAllWidgets(false) end)
    if not Ok then
        HaloUIManagerCache = nil
        Log("HUD widget invalidation failed (%s): %s", tostring(Reason), tostring(Err))
        return false
    end

    -- The banner objects can be reconstructed/rebound by the UI manager. Drop our
    -- bounded cache so Limited Respawns reacquires only live widgets on demand.
    if ClearBannerCache ~= nil then
        pcall(function() ClearBannerCache("HUD invalidation") end)
    end
    Log("HUD widgets invalidated (%s)", tostring(Reason))
    return true
end

-- Assigned below; declared here so ScheduleHaloHUDRebuild can call it.
local ApplyHudScale
local RestoreHudScale

ApplyHudScale = function(Reason, ForceRelayout)
    local Settings = GetUserInterfaceSettings()
    if not Settings then
        Log("UserInterfaceSettings not found - cannot correct HUD scale")
        return false
    end

    if OriginalApplicationScale == nil then
        pcall(function() OriginalApplicationScale = Settings.ApplicationScale end)
        if type(OriginalApplicationScale) ~= "number" or OriginalApplicationScale <= 0 then
            OriginalApplicationScale = 1.0
        end
    end

    local AnchorChanged = false
    pcall(function() AnchorChanged = select(1, ApplyHudAnchoring(true, Reason or "side-by-side", ForceRelayout == true)) end)

    local Size = GetViewportSize()
    local W, H = nil, nil
    pcall(function()
        W = tonumber(Size.X)
        H = tonumber(Size.Y)
    end)
    if not W or not H or W <= 0 or H <= 0 then
        if AnchorChanged then InvalidateHaloWidgets("anchoring only; viewport unavailable") end
        HudScaleApplied = true
        Log("HUD viewport size unavailable; Edges anchoring retained")
        return AnchorChanged
    end

    local AutoScale = (W * 9.0 / 16.0) / H
    local Target = OriginalApplicationScale * AutoScale * HudScaleTaste
    Target = math.max(0.25, math.min(4.0, Target))

    local Current = nil
    pcall(function() Current = tonumber(Settings.ApplicationScale) end)
    local ScaleChanged = type(Current) ~= "number" or math.abs(Current - Target) >= 0.0005

    if ScaleChanged or ForceRelayout == true then
        -- HCE Revival found that a direct ApplicationScale write can leave already
        -- constructed widgets on their old geometry after a live resolution change.
        -- Bounce through a different value in the same game-thread call, then set the
        -- real target before invalidating Halo's widgets. No frame sees the temporary
        -- value, but UMG observes a real property transition.
        local Ok, Err = pcall(function()
            local Bounce = math.abs(Target - 1.0) < 0.0005 and 0.999 or 1.0
            Settings.ApplicationScale = Bounce
            Settings.ApplicationScale = Target
        end)
        if not Ok then
            Log("ApplicationScale is not writable: %s", tostring(Err))
            if AnchorChanged then InvalidateHaloWidgets("anchoring changed; scale write failed") end
            HudScaleApplied = true
            return AnchorChanged
        end
    end

    HudScaleApplied = true
    LastViewportW = W
    LastViewportH = H

    if ScaleChanged or AnchorChanged or ForceRelayout == true then
        InvalidateHaloWidgets(ForceRelayout == true
            and ("forced adaptive HUD reflow: " .. tostring(Reason or "unspecified"))
            or "side-by-side scale/anchoring change")
        Log("HUD side-by-side: viewport %.0fx%.0f aspect %.3f autoScale %.4f trim %.3f -> ApplicationScale %.4f (%s)",
            W, H, W / H, AutoScale, HudScaleTaste, Target, tostring(Reason or "normal"))
    end
    return true
end

RestoreHudScale = function()
    local AnchorChanged = false
    pcall(function() AnchorChanged = select(1, ApplyHudAnchoring(false, "leave side-by-side")) end)

    local ScaleChanged = false
    local Settings = GetUserInterfaceSettings()
    if Settings and OriginalApplicationScale ~= nil then
        local Current = nil
        pcall(function() Current = tonumber(Settings.ApplicationScale) end)
        if type(Current) ~= "number" or math.abs(Current - OriginalApplicationScale) >= 0.0005 then
            local Ok = pcall(function() Settings.ApplicationScale = OriginalApplicationScale end)
            if Ok then ScaleChanged = true end
        end
    end

    HudScaleApplied = false
    if ScaleChanged or AnchorChanged then
        InvalidateHaloWidgets("restore non-side-by-side HUD")
        if OriginalApplicationScale ~= nil then
            Log("HUD restored ApplicationScale %.3f and original anchoring", OriginalApplicationScale)
        else
            Log("HUD restored original anchoring")
        end
    end
end

-- ---------------------------------------------------------------------------
-- Player management
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Input routing
-- ---------------------------------------------------------------------------

-- Input-mode configuration ----------------------------------------------------
-- HCE Revival v0.6.2 demonstrates the two pieces needed for keyboard/mouse P1 +
-- one physical gamepad P2 in UE5: set bOffsetPlayerGamepadIds before the join,
-- and enable input.bRemapDeviceIdForOffsetPlayerGamepadIds. Co-op Expanded keeps
-- its existing local CreatePlayer/join lifecycle and only adds that input routing.
--
-- These input-mode symbols are globals on purpose: main.lua is close to Lua's
-- 200-local main-chunk limit, so adding more top-level locals can prevent the mod
-- from compiling. The descriptive names keep the global namespace readable.
ConfiguredControllerCount = 2
InputSettingsPath = ""
InputRemapCVar = "input.bRemapDeviceIdForOffsetPlayerGamepadIds"
InputRemapApplied = false
UseGamePassPlatformJoin = false

function GetModFilePath(FileName)
    local Source = ""
    pcall(function()
        Source = debug.getinfo(1, "S").source or ""
    end)
    if string.sub(Source, 1, 1) == "@" then
        Source = string.sub(Source, 2)
    end
    Source = string.gsub(Source, "/", "\\")
    local Root = string.match(Source, "^(.*)\\Scripts\\main%.lua$")
    if Root and Root ~= "" then
        return Root .. "\\" .. FileName
    end
    return "Mods\\HaloSplitscreenCoop\\" .. FileName
end

-- Perspective runtime toggle ---------------------------------------------------
-- The persistent campaign skull selection is never changed. The tested native
-- helper routes the two verified local-coop Perspective query contexts to
-- independent P1/P2 states while unrelated contexts fall through to vanilla.
-- Solo keeps the same live first/third-person gate.
PerspectiveNativeInit = nil
PerspectiveNativeToggleP1 = nil
PerspectiveNativeToggleP2 = nil
PerspectiveNativeToggleGlobal = nil
PerspectiveNativeReset = nil
PerspectiveNativeModeSolo = nil
PerspectiveNativeModeCoop = nil
PerspectiveNativeLoaded = false
PerspectiveNativeCoopMode = false
PerspectiveThirdPerson = { [1] = false, [2] = false }
PerspectiveContextShiftEnable = nil
PerspectiveContextShiftDisable = nil
PerspectiveContextShiftLoaded = false
PerspectiveContextShiftActive = false

function LoadPerspectiveNative()
    if type(package) ~= "table" or type(package.loadlib) ~= "function" then
        Log("PERSPECTIVE native companion unavailable: package.loadlib is not available")
        return false
    end

    local Path = GetModFilePath("HCEPerspectiveNative.dll")
    local InitFn, InitErr = package.loadlib(Path, "HCEPerspectiveInit")
    local ToggleP1Fn, ToggleP1Err = package.loadlib(Path, "HCEPerspectiveToggleP1")
    local ToggleP2Fn, ToggleP2Err = package.loadlib(Path, "HCEPerspectiveToggleP2")
    local ToggleGlobalFn, ToggleGlobalErr = package.loadlib(Path, "HCEPerspectiveToggle")
    local ResetFn, ResetErr = package.loadlib(Path, "HCEPerspectiveReset")
    local SoloFn, SoloErr = package.loadlib(Path, "HCEPerspectiveModeSolo")
    local CoopFn, CoopErr = package.loadlib(Path, "HCEPerspectiveModeCoop")
    if type(InitFn) ~= "function" or type(ToggleP1Fn) ~= "function" or type(ToggleP2Fn) ~= "function" or
       type(ToggleGlobalFn) ~= "function" or type(ResetFn) ~= "function" or
       type(SoloFn) ~= "function" or type(CoopFn) ~= "function" then
        Log("PERSPECTIVE native load failed: init=%s p1=%s p2=%s global=%s reset=%s solo=%s coop=%s",
            tostring(InitErr), tostring(ToggleP1Err), tostring(ToggleP2Err), tostring(ToggleGlobalErr),
            tostring(ResetErr), tostring(SoloErr), tostring(CoopErr))
        return false
    end

    PerspectiveNativeInit = InitFn
    PerspectiveNativeToggleP1 = ToggleP1Fn
    PerspectiveNativeToggleP2 = ToggleP2Fn
    PerspectiveNativeToggleGlobal = ToggleGlobalFn
    PerspectiveNativeReset = ResetFn
    PerspectiveNativeModeSolo = SoloFn
    PerspectiveNativeModeCoop = CoopFn
    local Ok, Err = pcall(PerspectiveNativeInit)
    if not Ok then
        Log("PERSPECTIVE native init failed: %s", tostring(Err))
        PerspectiveNativeInit = nil
        PerspectiveNativeToggleP1 = nil
        PerspectiveNativeToggleP2 = nil
        PerspectiveNativeToggleGlobal = nil
        PerspectiveNativeReset = nil
        PerspectiveNativeModeSolo = nil
        PerspectiveNativeModeCoop = nil
        return false
    end

    PerspectiveNativeLoaded = true
    PerspectiveNativeCoopMode = false
    PerspectiveThirdPerson[1] = false
    PerspectiveThirdPerson[2] = false
    Log("PERSPECTIVE native companion initialized; independent local-coop P1/P2 perspective routing ready")
    return true
end

function LoadPerspectiveContextShiftBridge()
    if type(package) ~= "table" or type(package.loadlib) ~= "function" then
        Log("PERSPECTIVE context-shift bridge unavailable: package.loadlib is not available")
        return false
    end

    local Path = GetModFilePath("HCEPerspectiveContextShift.dll")
    local EnableFn, EnableErr = package.loadlib(Path, "HCEPerspectiveContextShiftEnable")
    local DisableFn, DisableErr = package.loadlib(Path, "HCEPerspectiveContextShiftDisable")
    if type(EnableFn) ~= "function" or type(DisableFn) ~= "function" then
        Log("PERSPECTIVE context-shift bridge load failed: enable=%s disable=%s",
            tostring(EnableErr), tostring(DisableErr))
        return false
    end

    PerspectiveContextShiftEnable = EnableFn
    PerspectiveContextShiftDisable = DisableFn
    PerspectiveContextShiftLoaded = true
    PerspectiveContextShiftActive = false
    Log("PERSPECTIVE context-shift bridge loaded; normal 0/1 routing retained until network-client + local P2 is proven")
    return true
end

function LoadInputSettings()
    ConfiguredControllerCount = 2
    UseTwoGamepads = true
    InputRemapApplied = false
    InputSettingsPath = GetModFilePath("settings.ini")
    UseGamePassPlatformJoin = string.find(
        string.lower(tostring(InputSettingsPath or "")),
        "wingdk",
        1,
        true
    ) ~= nil
    Log("Runtime platform: %s", UseGamePassPlatformJoin and "WinGDK / Xbox App" or "Win64 / Steam")
    Log("Platform join mode: %s", UseGamePassPlatformJoin
        and "WinGDK Add/Login/Promote"
        or "standard CreatePlayer")

    local File = io.open(InputSettingsPath, "r")
    if not File then
        Log("Input settings unavailable; defaulting to Controllers=2")
        return
    end

    local Found = false
    local Invalid = nil
    for RawLine in File:lines() do
        local Clean = string.gsub(RawLine, "[;#].*$", "")
        local Value = string.match(Clean, "^%s*[Cc]ontrollers%s*=%s*([12])%s*$")
        if Value then
            ConfiguredControllerCount = tonumber(Value)
            Found = true
        else
            local Candidate = string.match(Clean, "^%s*[Cc]ontrollers%s*=%s*(%S+)%s*$")
            if Candidate then Invalid = Candidate end
        end
    end
    File:close()

    if Invalid and not Found then
        Log("Invalid Controllers=%s; using default Controllers=2", tostring(Invalid))
    elseif not Found then
        Log("Controllers setting not found; using default Controllers=2")
    end

    UseTwoGamepads = ConfiguredControllerCount == 2
    Log(
        "Input mode loaded: Controllers=%d (%s)",
        ConfiguredControllerCount,
        ConfiguredControllerCount == 1
            and "P1 keyboard/mouse + P2 first gamepad"
            or "P1 keyboard/mouse or gamepad 1 + P2 gamepad 2"
    )
    if ConfiguredControllerCount == 1 then
        Log("Controllers=1: adaptive input routing enabled; Steam supports native/Steam-virtual pads, WinGDK uses the native Xbox/XInput route")
    end
end

-- Adaptive one-controller input router ---------------------------------------
-- Production integration of the v0.7.4 native route. Steam uses both
-- native-XInput and Steam-virtual classification. WinGDK/GamePass uses only the
-- native-XInput side of the same project-owned proxy/cache correction path.
-- This runs only for Controllers=1. It preserves the existing local xinput1_4.dll mapping:
--   * native/System XInput present (Xbox-class): restore the original HCE proxy
--     XInputGetState entry so logical game slot 1 reads physical XInput slot 0;
--   * verified Steam XInput relay present (DualSense/Steam virtual), even before
--     its virtual slot is published: keep Steam translation and expose Steam
--     slot 0 as game slot 1 while game slot 0 reports disconnected.
-- The native companion writes only the local HCE xinput1_4.dll XInputGetState
-- entry. It does not write HaloCampaignEvolved.exe or Steam's overlay module.
XInputSteamRouterEnsureFn = XInputSteamRouterEnsureFn or nil
XInputSteamRouterBusy = XInputSteamRouterBusy or false
XInputSteamRouterReady = XInputSteamRouterReady or false
XInputSteamRouterLastKind = XInputSteamRouterLastKind or 0
XInputSteamRouterRetryGeneration = XInputSteamRouterRetryGeneration or 0
XInputSteamRouterWarmupTicks = XInputSteamRouterWarmupTicks or 0
XInputSteamRouterWarmupIntervalTicks = XInputSteamRouterWarmupIntervalTicks or 0
XInputSteamRouterWarmupAttempt = XInputSteamRouterWarmupAttempt or 0
XInputSteamRouterWarmupSource = XInputSteamRouterWarmupSource or ""
XInputSteamRouterSnapshotVersion = XInputSteamRouterSnapshotVersion or 0
XInputSteamRouterSystemSlot0Rc = XInputSteamRouterSystemSlot0Rc or 0xFFFFFFFF
XInputSteamRouterRelaySlot0Rc = XInputSteamRouterRelaySlot0Rc or 0xFFFFFFFF
XInputSteamRouterGameSlot0Rc = XInputSteamRouterGameSlot0Rc or 0xFFFFFFFF
XInputSteamRouterGameSlot1Rc = XInputSteamRouterGameSlot1Rc or 0xFFFFFFFF
XInputSteamRouterSlot1Connected = XInputSteamRouterSlot1Connected or false
XInputSteamRouterEntryKindBefore = XInputSteamRouterEntryKindBefore or 0
XInputSteamRouterRecoveredDeadNative = XInputSteamRouterRecoveredDeadNative or 0
XInputSteamRouterRelayAvailable = XInputSteamRouterRelayAvailable or 0
XInputSteamRouterJoinWaitActive = XInputSteamRouterJoinWaitActive or false
XInputSteamRouterJoinWaitTicks = XInputSteamRouterJoinWaitTicks or 0
XInputSteamRouterJoinWaitIntervalTicks = XInputSteamRouterJoinWaitIntervalTicks or 0
XInputSteamRouterJoinWaitAttempt = XInputSteamRouterJoinWaitAttempt or 0
XInputSteamRouterPostJoinTicks = XInputSteamRouterPostJoinTicks or 0
XInputSteamRouterPostJoinIntervalTicks = XInputSteamRouterPostJoinIntervalTicks or 0

function XInputSteamRouterReadU32LE(Data, ZeroOffset)
    local I = ZeroOffset + 1
    local B1 = string.byte(Data, I) or 0
    local B2 = string.byte(Data, I + 1) or 0
    local B3 = string.byte(Data, I + 2) or 0
    local B4 = string.byte(Data, I + 3) or 0
    return B1 + B2 * 0x100 + B3 * 0x10000 + B4 * 0x1000000
end

function XInputSteamRouterRcText(Rc)
    if Rc == 0 then return "ok" end
    if Rc == 1167 then return "disconnected" end
    if Rc == 0xFFFFFFFF then return "n/a" end
    return tostring(Rc)
end

function XInputSteamRouterEntryKindText(Kind)
    if Kind == 1 then return "steam-hook" end
    if Kind == 2 then return "original" end
    if Kind == 3 then return "shift" end
    return "unknown"
end

function EnsureAdaptiveSteamInputRouting(Reason, ForceCheck)
    if ConfiguredControllerCount ~= 1 then return true end
    if XInputSteamRouterReady and ForceCheck ~= true then return true end
    if XInputSteamRouterBusy then return false end
    XInputSteamRouterBusy = true

    local Ok = false
    if type(XInputSteamRouterEnsureFn) ~= "function" then
        if type(package) ~= "table" or type(package.loadlib) ~= "function" then
            Log("INPUT ROUTER unavailable: package.loadlib is not available")
            XInputSteamRouterBusy = false
            return false
        end
        local Path = GetModFilePath("HCEXInputSteamBypass.dll")
        local Fn, Err = package.loadlib(Path, "HCEXInputSteamBypassEnsure")
        if type(Fn) ~= "function" then
            Log("INPUT ROUTER native companion load failed: %s", tostring(Err))
            XInputSteamRouterBusy = false
            return false
        end
        XInputSteamRouterEnsureFn = Fn
    end

    if type(os) == "table" and type(os.remove) == "function" then
        pcall(function() os.remove("HCEXInputSteamBypass.snapshot") end)
    end

    local CallOk, CallErr = pcall(XInputSteamRouterEnsureFn)
    if not CallOk then
        Log("INPUT ROUTER native ensure failed (%s): %s", tostring(Reason or "unspecified"), tostring(CallErr))
    else
        local F = io.open("HCEXInputSteamBypass.snapshot", "rb")
        if F then
            local D = F:read("*a") or ""
            F:close()
            if #D == 384 and string.sub(D, 1, 8) == "HCEBYP71" then
                local SnapshotVersion = XInputSteamRouterReadU32LE(D, 0x08)
                local Action = XInputSteamRouterReadU32LE(D, 0x0C)
                local PatchLen = XInputSteamRouterReadU32LE(D, 0x44)
                local ModeAfter = XInputSteamRouterReadU32LE(D, 0x50)
                local InitAfter = XInputSteamRouterReadU32LE(D, 0x54)
                local Classifier = XInputSteamRouterReadU32LE(D, 0x64)
                local ActiveKind = math.floor(Classifier / 0x100) % 0x100
                local ModeForced = XInputSteamRouterReadU32LE(D, 0xCC)
                local ProxyLoadAttempt = XInputSteamRouterReadU32LE(D, 0xD0)
                local ProxyLoadAccepted = XInputSteamRouterReadU32LE(D, 0xD4)
                local SteamArmedBeforeDevice = XInputSteamRouterReadU32LE(D, 0xD8)
                local SystemSlot0Rc = XInputSteamRouterReadU32LE(D, 0x130)
                local RelaySlot0Rc = XInputSteamRouterReadU32LE(D, 0x134)
                local EntryKindBefore = XInputSteamRouterReadU32LE(D, 0x138)
                local RecoveredDeadNative = XInputSteamRouterReadU32LE(D, 0x13C)
                local SteamRuntimePresent = XInputSteamRouterReadU32LE(D, 0x140)
                local RelayAvailable = XInputSteamRouterReadU32LE(D, 0x144)
                local GameSlot0Rc = XInputSteamRouterReadU32LE(D, 0x148)
                local GameSlot1Rc = XInputSteamRouterReadU32LE(D, 0x14C)
                XInputSteamRouterSnapshotVersion = SnapshotVersion
                XInputSteamRouterSystemSlot0Rc = SystemSlot0Rc
                XInputSteamRouterRelaySlot0Rc = RelaySlot0Rc
                XInputSteamRouterGameSlot0Rc = GameSlot0Rc
                XInputSteamRouterGameSlot1Rc = GameSlot1Rc
                XInputSteamRouterSlot1Connected = GameSlot1Rc == 0
                XInputSteamRouterEntryKindBefore = EntryKindBefore
                XInputSteamRouterRecoveredDeadNative = RecoveredDeadNative
                XInputSteamRouterRelayAvailable = RelayAvailable
                local ValidAction = Action == 1 or Action == 4 or Action == 5 or Action == 6
                local KindAllowed = (ActiveKind == 1 or ActiveKind == 2)
                if UseGamePassPlatformJoin and ActiveKind ~= 1 then
                    KindAllowed = false
                end
                local Diagnostic = string.format(
                    "v=%d entry=%s sys0=%s relay0=%s game0=%s game1=%s relay_saved=%d steam_runtime=%d recovered_native=%d patch_len=%d",
                    SnapshotVersion, XInputSteamRouterEntryKindText(EntryKindBefore),
                    XInputSteamRouterRcText(SystemSlot0Rc), XInputSteamRouterRcText(RelaySlot0Rc),
                    XInputSteamRouterRcText(GameSlot0Rc), XInputSteamRouterRcText(GameSlot1Rc),
                    RelayAvailable, SteamRuntimePresent, RecoveredDeadNative, PatchLen)
                if ValidAction and ModeAfter == 1 and InitAfter == 2 and KindAllowed then
                    XInputSteamRouterReady = true
                    XInputSteamRouterLastKind = ActiveKind
                    Ok = true
                    local KindName = ActiveKind == 1 and "native XInput" or "Steam Input virtual gamepad"
                    local PlatformNote = UseGamePassPlatformJoin and "WinGDK native route" or "Steam route"
                    local LoadNote = ProxyLoadAccepted == 1 and " (local xinput1_4 proxy loaded on demand)" or ""
                    local SteamArmNote = SteamArmedBeforeDevice == 1 and " (Steam relay armed before virtual device became visible)" or ""
                    Log("INPUT ROUTER ready (%s): %s -> logical Player 2 slot [%s]%s%s%s; %s",
                        tostring(Reason or "unspecified"), KindName, PlatformNote,
                        ModeForced == 1 and " (proxy Controllers cache corrected 2->1)" or "", LoadNote, SteamArmNote, Diagnostic)
                    if RecoveredDeadNative == 1 then
                        Log("INPUT ROUTER recovered dead native route -> Steam virtual shift (%s); game1=%s",
                            tostring(Reason or "unspecified"), XInputSteamRouterRcText(GameSlot1Rc))
                    end
                elseif UseGamePassPlatformJoin and ValidAction and ModeAfter == 1 and InitAfter == 2 and ActiveKind ~= 1 then
                    XInputSteamRouterReady = false
                    XInputSteamRouterLastKind = 0
                    XInputSteamRouterSlot1Connected = false
                    Log("INPUT ROUTER WinGDK refused non-native route (%s): kind=%d; %s", tostring(Reason or "unspecified"), ActiveKind, Diagnostic)
                elseif Action == 8 then
                    XInputSteamRouterReady = false
                    XInputSteamRouterLastKind = 0
                    XInputSteamRouterSlot1Connected = false
                    Log("INPUT ROUTER waiting: no live XInput/Steam route at %s; %s", tostring(Reason or "unspecified"), Diagnostic)
                else
                    XInputSteamRouterReady = false
                    XInputSteamRouterSlot1Connected = false
                    Log("INPUT ROUTER validation failed (%s): action=%d mode=%d init=%d kind=%d proxy_load_attempt=%d proxy_load_accepted=%d; %s",
                        tostring(Reason or "unspecified"), Action, ModeAfter, InitAfter, ActiveKind, ProxyLoadAttempt, ProxyLoadAccepted, Diagnostic)
                end
            else
                Log("INPUT ROUTER snapshot invalid (%s): size=%d", tostring(Reason or "unspecified"), #D)
            end
        else
            Log("INPUT ROUTER snapshot missing after native ensure (%s)", tostring(Reason or "unspecified"))
        end
    end

    if type(os) == "table" and type(os.remove) == "function" then
        pcall(function() os.remove("HCEXInputSteamBypass.snapshot") end)
    end
    XInputSteamRouterBusy = false
    return Ok
end

function ScheduleAdaptiveInputRouterRetries(Source, ForceWindow)
    if ConfiguredControllerCount ~= 1 then return end
    if XInputSteamRouterReady and ForceWindow ~= true then return end

    -- UE4SS 3.0.1 can hold ExecuteInGameThreadWithDelay callbacks across the
    -- long initial frontend load and then release all delays in one frame. RC5's
    -- 120/400/1000/2500/5000 ms retries therefore collapsed into a single instant
    -- in the failing Steam logs. Use the already-owned 40 ms game-thread worker
    -- instead. The readiness window is bounded and stops immediately once a route
    -- is confirmed (or when P2 exists).
    XInputSteamRouterRetryGeneration = XInputSteamRouterRetryGeneration + 1
    XInputSteamRouterWarmupSource = tostring(Source or "router readiness")
    local IsSteamSettle = (not UseGamePassPlatformJoin) and string.find(XInputSteamRouterWarmupSource, "Steam frontend hook settle", 1, true) ~= nil
    XInputSteamRouterWarmupTicks = IsSteamSettle and 250 or 750 -- ~10 s Steam settle, otherwise at most ~30 s
    XInputSteamRouterWarmupIntervalTicks = 0
    XInputSteamRouterWarmupAttempt = 0
    Log("INPUT ROUTER bounded game-thread readiness window armed source=%s ticks=%d", XInputSteamRouterWarmupSource, XInputSteamRouterWarmupTicks)
end

-- Must be declared before AdaptiveInputRouterWarmupTick is defined. Lua resolves
-- locals lexically at function-definition time; declaring this later made that
-- function capture a nil global and abort MainStateTick before late A-join binding.
local PlayerControllerTable = {}

function AdaptiveInputRouterWarmupTick()
    if XInputSteamRouterWarmupTicks <= 0 then return end
    if ConfiguredControllerCount ~= 1 or ModTeardownGuard then
        XInputSteamRouterWarmupTicks = 0
        return
    end
    if IsValidObject(PlayerControllerTable[2]) then
        XInputSteamRouterWarmupTicks = 0
        return
    end

    XInputSteamRouterWarmupTicks = XInputSteamRouterWarmupTicks - 1
    XInputSteamRouterWarmupIntervalTicks = XInputSteamRouterWarmupIntervalTicks - 1
    if XInputSteamRouterWarmupIntervalTicks > 0 then return end
    XInputSteamRouterWarmupIntervalTicks = 10 -- ~400 ms, bounded startup/frontend only
    XInputSteamRouterWarmupAttempt = XInputSteamRouterWarmupAttempt + 1

    local CallOk, Ready = pcall(EnsureAdaptiveSteamInputRouting,
        XInputSteamRouterWarmupSource .. " worker retry " .. tostring(XInputSteamRouterWarmupAttempt), true)
    if CallOk and Ready == true then
        local KeepSteamSettle = (not UseGamePassPlatformJoin)
            and string.find(XInputSteamRouterWarmupSource, "Steam frontend hook settle", 1, true) ~= nil
            and XInputSteamRouterLastKind == 1
            and XInputSteamRouterWarmupTicks > 0
        if KeepSteamSettle then
            if XInputSteamRouterWarmupAttempt == 1 or (XInputSteamRouterWarmupAttempt % 5) == 0 then
                Log("INPUT ROUTER Steam settle: native route still live; continuing for late Steam relay attempt=%d game1=%s",
                    XInputSteamRouterWarmupAttempt, XInputSteamRouterRcText(XInputSteamRouterGameSlot1Rc))
            end
            return
        end
        XInputSteamRouterWarmupTicks = 0
        XInputSteamRouterRetryGeneration = XInputSteamRouterRetryGeneration + 1
        Log("INPUT ROUTER bounded readiness worker succeeded attempt=%d source=%s kind=%d game1=%s",
            XInputSteamRouterWarmupAttempt, XInputSteamRouterWarmupSource, XInputSteamRouterLastKind,
            XInputSteamRouterRcText(XInputSteamRouterGameSlot1Rc))
        return
    end

    if XInputSteamRouterWarmupTicks <= 0 then
        Log("INPUT ROUTER bounded readiness worker exhausted source=%s last_kind=%d game1=%s",
            XInputSteamRouterWarmupSource, XInputSteamRouterLastKind, XInputSteamRouterRcText(XInputSteamRouterGameSlot1Rc))
    end
end

function ApplyInputRoutingNow(Reason)
    local Offset = ConfiguredControllerCount == 1
    local SettingsOk, SettingsErr = pcall(function()
        local Settings = GetGameMapsSettings()
        if not IsValidObject(Settings) then
            error("GameMapsSettings unavailable")
        end
        Settings.bOffsetPlayerGamepadIds = Offset
        if Offset then
            -- HCE Revival applies split-screen support before the pending-player press
            -- in one-controller mode. With one LocalPlayer this does not split the
            -- viewport; it only keeps Halo's pending local-player path armed.
            Settings.bUseSplitscreen = true
        end
    end)

    local RemapOk = true
    local RemapValue = nil
    if Offset and not InputRemapApplied then
        RemapOk = RunConsoleCommand(InputRemapCVar .. " 1")
        pcall(function()
            local Library = GetKismetSystemLibrary()
            if IsValidObject(Library) then
                RemapValue = Library:GetConsoleVariableIntValue(InputRemapCVar)
            end
        end)
        if RemapValue ~= nil then
            RemapOk = RemapValue == 1
        end
        if RemapValue == 1 or (RemapOk and RemapValue == nil) then
            InputRemapApplied = true
        end
    end

    if SettingsOk then
        Log(
            "Input routing applied (%s): Controllers=%d OffsetPlayerGamepadIds=%s%s",
            tostring(Reason or "unspecified"),
            ConfiguredControllerCount,
            tostring(Offset),
            RemapValue ~= nil and (" remap_cvar=" .. tostring(RemapValue)) or ""
        )
    else
        Log("Input routing not ready (%s): %s", tostring(Reason or "unspecified"), tostring(SettingsErr))
    end

    return SettingsOk and (not Offset or InputRemapApplied)
end

function ScheduleInputRouting(Attempt, Reason)
    Attempt = tonumber(Attempt) or 1
    local DelayMs = Attempt == 1 and 250 or 1000
    ExecuteInGameThreadWithDelay(DelayMs, function()
        local Ready = ApplyInputRoutingNow(Reason or "startup")
        if not Ready and Attempt < 6 then
            ScheduleInputRouting(Attempt + 1, Reason or "startup retry")
        end
    end)
end

-- Resolve the explicit settings.ini input mode. No runtime controller detection is used.
local function WantsTwoGamepads()
    if UseTwoGamepads then
        return true, "Controllers=2"
    end
    return false, "Controllers=1"
end

NetworkControllerSkipLogged = false

local function CachePlayerControllers()
    PlayerControllerTable = {}
    local AllPlayerControllers = FindAllOf("PlayerController") or FindAllOf("Controller")
    for _, PlayerController in pairs(AllPlayerControllers) do
        local Player = nil
        local ControllerId = nil
        local CandidateOk = pcall(function()
            if PlayerController:IsValid()
                and not PlayerController:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) then
                Player = PlayerController.Player
                if Player and Player:IsValid() then
                    ControllerId = Player.ControllerId
                end
            end
        end)

        -- On a listen server FindAllOf("PlayerController") also returns remote
        -- network controllers. Their Player is a UNetConnection rather than a
        -- ULocalPlayer, and UE4SS exposes its ControllerId as a TrivialObject.
        -- Only numeric ControllerIds identify this machine's LocalPlayers.
        if CandidateOk and type(ControllerId) == "number" and ControllerId >= 0 then
            PlayerControllerTable[ControllerId + 1] = PlayerController
        elseif CandidateOk and Player ~= nil and not NetworkControllerSkipLogged then
            NetworkControllerSkipLogged = true
            local Name = "unreadable"
            pcall(function() Name = PlayerController:GetFullName() end)
            Log(
                "Controller cache: ignoring non-local/network controller %s (ControllerId type=%s)",
                tostring(Name),
                type(ControllerId)
            )
        end
    end
end

-- Static frontend join hint. Controller-family/count detection was removed after live
-- testing showed the hardware metadata was not reliable enough. Co-op Expanded now uses
-- concise Xbox-style button names consistently in all in-game help text.
-- This is event/startup driven only: no controller poller is added to gameplay.
-- NOTE: These prompt symbols are intentionally globals because main.lua is already
-- close to Lua's 200-local main-chunk limit.
FrontendJoinPromptAsset = "/Game/UI/Shared/Widgets/Squad/WBP_SquadSplitscreenListViewItem"
FrontendJoinPromptClass = FrontendJoinPromptAsset .. ".WBP_SquadSplitscreenListViewItem_C"
FrontendJoinPromptTextCache = nil

function FindOrLoadFrontendJoinPromptClass()
    local Class = StaticFindObject(FrontendJoinPromptClass)
    if IsValidObject(Class) then return Class end
    pcall(function() LoadAsset(FrontendJoinPromptAsset) end)
    Class = StaticFindObject(FrontendJoinPromptClass)
    return IsValidObject(Class) and Class or nil
end

function GetFrontendJoinPromptText()
    if FrontendJoinPromptTextCache then return FrontendJoinPromptTextCache end
    local TextLibrary = StaticFindObject("/Script/Engine.Default__KismetTextLibrary")
    if not IsValidObject(TextLibrary) then return nil end
    FrontendJoinPromptTextCache = TextLibrary:Conv_StringToText(
        "CONTROLLER (2) PRESS A\nTO PLAY SPLITSCREEN"
    )
    return FrontendJoinPromptTextCache
end

function SetFrontendJoinPromptWidget(Widget)
    if not IsValidObject(Widget) then return false end
    local Ok = pcall(function()
        Widget:SetVisibility(0)
        local Label = Widget.SplitscreenLabel
        if IsValidObject(Label) then
            local Text = GetFrontendJoinPromptText()
            if Text then Label:SetText(Text) end
        end
    end)
    return Ok
end

function RefreshFrontendJoinPromptWidgets()
    local Widgets = FindAllOf("WBP_SquadSplitscreenListViewItem_C") or {}
    for _, Widget in pairs(Widgets) do
        SetFrontendJoinPromptWidget(Widget)
    end
end

function ApplyStaticFrontendJoinPrompt(Attempt)
    Attempt = Attempt or 1
    ExecuteInGameThreadWithDelay(0, function()
        -- Campaign transitions can briefly construct/retain squad-lobby UI objects.
        -- They are not an actual return to Frontend. Never let those transient
        -- objects re-arm the join prompt or session state mid-campaign.
        local WorldName = ""
        pcall(function()
            local World = UEHelpers.GetWorldContextObject()
            if IsValidObject(World) then WorldName = World:GetFullName() end
        end)
        local LowerWorld = string.lower(WorldName or "")
        if string.find(LowerWorld, "/game/levels/halo1/solo/", 1, true) then
            return
        end
        if string.find(LowerWorld, "/game/levels/ui/frontend/", 1, true)
            and ArmorSkinArmFrontendTexturePrewarm ~= nil then
            pcall(function() ArmorSkinArmFrontendTexturePrewarm("frontend squad UI signal") end)
        end

        -- Rebind the leave gesture to the CURRENT frontend P2 controller. A
        -- campaign PlayerController can remain UObject-valid after returning to
        -- the menu, so validity alone is not enough to identify the live input target.
        if string.find(LowerWorld, "/game/levels/ui/frontend/", 1, true) and
           RefreshFrontendP2LeaveBinding ~= nil then
            pcall(RefreshFrontendP2LeaveBinding)
        end

        local DesiredClass = FindOrLoadFrontendJoinPromptClass()
        local Applied = false

        if DesiredClass then
            local Models = FindAllOf("MeteoriteSquadLobbyViewModel") or {}
            for _, Model in pairs(Models) do
                if IsValidObject(Model) then
                    local Ok = pcall(function()
                        Model:SetSplitscreenWidgetClass(DesiredClass)
                        Model.bOfferJoinSlots = true
                        Model.BackingDataChangedDelegate:Broadcast()
                    end)
                    Applied = Applied or Ok
                end
            end
        end

        if Applied then
            -- The frontend squad lobby is an authoritative end-of-campaign-session
            -- signal on builds where the frontend PlayerController does not emit the
            -- numeric/local ReceiveTick path. Keep this event-driven and idempotent.
            if HandleFrontendRespawnBoundary ~= nil then
                pcall(function() HandleFrontendRespawnBoundary("squad lobby prompt") end)
            end

            -- Force the currently visible squad widget to rebuild once so the native row
            -- appears immediately. This can reset FireteamHeader, so re-apply the
            -- load confirmation afterwards.
            local SquadWidgets = FindAllOf("WBP_SquadWidget_C") or {}
            for _, SquadWidget in pairs(SquadWidgets) do
                if IsValidObject(SquadWidget) then
                    pcall(function() SquadWidget:BackingDataChanged() end)
                end
            end

            ExecuteInGameThreadWithDelay(75, function()
                RefreshFrontendJoinPromptWidgets()
            end)
            ExecuteInGameThreadWithDelay(300, function()
                RefreshFrontendJoinPromptWidgets()
                ApplyLoadedHeader(1, true)
            end)
            Log("Frontend join prompt applied: PRESS A")
            return
        end

        if Attempt < 10 then
            ExecuteInGameThreadWithDelay(2000, function()
                ApplyStaticFrontendJoinPrompt(Attempt + 1)
            end)
        else
            Log("Frontend join prompt waiting for squad view-model")
        end
    end)
end

function RegisterStaticFrontendJoinPrompt()
    local SquadOk, SquadErr = pcall(function()
        NotifyOnNewObject(
            "/Game/UI/Shared/Widgets/Squad/WBP_SquadWidget.WBP_SquadWidget_C",
            function()
                ExecuteInGameThreadWithDelay(100, function()
                    ApplyStaticFrontendJoinPrompt(1)
                end)
            end
        )
    end)
    if not SquadOk then
        Log("Frontend squad-widget listener unavailable: %s", tostring(SquadErr))
    end

    local RowOk, RowErr = pcall(function()
        NotifyOnNewObject(FrontendJoinPromptClass, function(Widget)
            ExecuteInGameThreadWithDelay(50, function()
                SetFrontendJoinPromptWidget(Widget)
            end)
        end)
    end)
    if not RowOk then
        Log("Frontend join-row listener unavailable: %s", tostring(RowErr))
    end

    ApplyStaticFrontendJoinPrompt(1)
end

local function ApplyLocalMultiplayerSettings()
    local Settings = GetGameMapsSettings()
    local SideBySide = WantsSideBySide()
    ActiveSideBySide = SideBySide == true
    local RequestedLayout = SideBySide
        and TwoPlayerSplitLayout.Vertical
        or TwoPlayerSplitLayout.Horizontal

    CachePlayerControllers()
    local TwoGamepads, InputReason = WantsTwoGamepads()

    Settings.bUseSplitscreen = true
    Settings.bOffsetPlayerGamepadIds = not TwoGamepads
    if not TwoGamepads and not InputRemapApplied then
        if RunConsoleCommand(InputRemapCVar .. " 1") then
            InputRemapApplied = true
        end
    end

    -- TwoPlayerSplitscreenLayout is a TEnumAsByte in UE 5.5. UE4SS writes its
    -- numeric enum value through the reflected byte property. This is plain
    -- reflection on the same config object bUseSplitscreen lives on - no AOB
    -- signature involved, so a game patch cannot break it.
    local LayoutOk, LayoutErr = pcall(function()
        Settings.TwoPlayerSplitscreenLayout = RequestedLayout
    end)

    Log("UseSplitScreen: %s", tostring(Settings.bUseSplitscreen))
    Log(
        "Input mode: %s - %s (OffsetPlayerGamepadIds: %s)",
        TwoGamepads and "two gamepads" or "keyboard/mouse + gamepad",
        InputReason,
        tostring(Settings.bOffsetPlayerGamepadIds)
    )


    if LayoutOk then
        Log(
            "TwoPlayerSplitscreenLayout: %s (%s)",
            tostring(Settings.TwoPlayerSplitscreenLayout),
            SideBySide and "left/right" or "top/bottom"
        )
    else
        Log("Could not set TwoPlayerSplitscreenLayout: %s", tostring(LayoutErr))
    end

    return SideBySide
end

-- Changing the layout while two LocalPlayers already exist does not reliably rebuild
-- their live viewport rectangles. Toggling the engine override forces
-- UGameViewportClient to recalculate them. (JoacoL999)
local function RefreshSplitscreenLayout()
    local Ok, Err = pcall(function()
        local GameplayStatics = GetGameplayStatics()
        local WorldContext = UEHelpers.GetWorldContextObject()
        GameplayStatics:SetForceDisableSplitscreen(WorldContext, true)
        GameplayStatics:SetForceDisableSplitscreen(WorldContext, false)
    end)

    Log("Viewport layout refresh -> %s%s", tostring(Ok), Ok and "" or (" (" .. tostring(Err) .. ")"))
    return Ok
end

-- This path is intentionally event-driven. The only controller polling added for
-- local drop-out is one FaceButton_Bottom query while a real local P2 already
-- exists in the actual Frontend. Ctrl+U and the P2 hold gesture both call this
-- once after a successful menu-only local-P2 removal.
local function ApplySoloMenuState()
    ActiveSideBySide = false
    LastViewportW = nil
    LastViewportH = nil
    HudRelayoutTicks = 0
    local Settings = GetGameMapsSettings()
    if Settings then
        pcall(function() Settings.bUseSplitscreen = false end)
        pcall(function() Settings.bOffsetPlayerGamepadIds = (ConfiguredControllerCount == 1) end)
    end
    if ConfiguredControllerCount == 1 then
        ApplyInputRoutingNow("menu P2 removal")
    end
    RestoreHudScale()
    DisableHaloUISplitscreen()
    RunConsoleCommand(ViewportHoldCVar .. " 0")
    local GameOwnedFullscreen = false
    if IsSplitForceDisabled ~= nil then
        pcall(function() GameOwnedFullscreen = IsSplitForceDisabled() end)
    end
    if not GameOwnedFullscreen then
        RefreshSplitscreenLayout()
    end
end

-- Live-resolution repair ------------------------------------------------------
-- Resolution repair is event-driven. CloseWidgetFullscreen signals one delayed
-- adaptive HUD reflow after pause/video settings close; orientation and HUD rebuild
-- actions call ApplyHudScale directly. Settled gameplay has no viewport-size poll.
function QueueHudRelayout(Reason, DelayTicks)
    local Delay = tonumber(DelayTicks) or 15
    if Delay < 1 then Delay = 1 end
    HudRelayoutTicks = Delay
    HudRelayoutReason = tostring(Reason or "queued relayout")
end

function AdaptiveHudViewportTick()
    if CinematicActive == true or not ActiveSideBySide then return end

    -- No periodic GetViewportSize sampling occurs here. In settled side-by-side play
    -- this is a Lua-only early return unless an event explicitly queued a HUD
    -- relayout (currently fullscreen/pause/settings close).
    if HudRelayoutTicks <= 0 then return end
    if not IsValidObject(PlayerControllerTable[2]) then return end

    HudRelayoutTicks = HudRelayoutTicks - 1
    if HudRelayoutTicks <= 0 then
        local Reason = HudRelayoutReason ~= "" and HudRelayoutReason or "queued relayout"
        HudRelayoutReason = ""
        ApplyHudScale(Reason, true)
        EnableHaloUISplitscreen()
        Log("HUD queued relayout COMPLETE (%s)", tostring(Reason))
    end
end

function RegisterPauseCloseHudHook()
    if PauseCloseHookArmed then return true end
    local Ok, Err = pcall(function()
        RegisterHook(
            "/Script/HaloUI.HaloUIManagerSubsystem:CloseWidgetFullscreen",
            function(Context, ...) end,
            function(Context, ...)
                if ActiveSideBySide and IsValidObject(PlayerControllerTable[2]) then
                    QueueHudRelayout("fullscreen menu closed", 15)
                end
            end
        )
    end)
    if Ok then
        PauseCloseHookArmed = true
        Log("HUD fullscreen-menu close hook ready")
        return true
    end
    Log("HUD fullscreen-menu close hook unavailable: %s", tostring(Err))
    return false
end

-- Halo builds its PlayerHaloUILayouts from the live LocalPlayer rectangles, and
-- LayoutPlayers updates those rectangles during the viewport draw. Calling
-- EnableSplitscreen in the same callback that changed the orientation makes the HUD
-- cache the previous geometry, so rebuild on a later frame. (JoacoL999)
local ModTravelGeneration = 0
local ModTeardownGuard = false

local function ScheduleHaloHUDRebuild(DelayMs, Reason)
    local ScheduledGeneration = ModTravelGeneration
    ExecuteInGameThreadWithDelay(DelayMs, function()
            if ModTeardownGuard or ScheduledGeneration ~= ModTravelGeneration then
                return
            end
            -- Never rebuild per-player Halo UI while a cinematic owns the
            -- fullscreen viewport. Rebuilding here is a plausible cause of duplicated
            -- per-player cinematic layers. The cinematic exit path queues one clean
            -- split/HUD reapply from the existing P1 ReceiveTick hook.
            if CinematicActive == true or (IsSplitForceDisabled ~= nil and IsSplitForceDisabled()) then
                Log("CINEMATIC HUD rebuild skipped while fullscreen override is active (%s)", tostring(Reason))
                return
            end
            CachePlayerControllers()
            if #PlayerControllerTable < 2 then
                return
            end

            Log("Delayed HUD rebuild after %sms (%s)", DelayMs, Reason)
            -- Scale first, then rebuild, so the layouts are built at the right size.
            if WantsSideBySide() then
                ApplyHudScale()
            else
                RestoreHudScale()
            end
            EnableHaloUISplitscreen()
            ExecuteInGameThreadWithDelay(150, function()
                if ModTeardownGuard or ScheduledGeneration ~= ModTravelGeneration then
                    return
                end
                InvalidateHaloWidgets("HUD rebuild settle: " .. tostring(Reason))
            end)
    end)
end

local CreatePlayerInProgress = false
local PlayerTwoExpected = false
-- Verify a newly-created P2 once before applying the final split-screen activation pass.
-- Globals are intentional to avoid Lua main-chunk local variable limits.
JoinVerificationActive = false
JoinVerificationTicks = 0

-- Player 2 is created only from the frontend sign-in flow.
-- Armor switching uses the live customization data table/settings paths directly.

local function CreatePlayer()
    if ModTeardownGuard then
        Log("Player creation ignored during map teardown.")
        return
    end
    if CreatePlayerInProgress or JoinVerificationActive then
        Log("Player creation already in progress.")
        return
    end
    if XInputSteamRouterJoinWaitActive then
        Log("Player creation already waiting for logical Player 2 input slot to become live.")
        return
    end
    if ConfiguredControllerCount == 1 then
        local RouterCallOk, RouterReady = pcall(EnsureAdaptiveSteamInputRouting, "player 2 join preflight", true)
        if not RouterCallOk or RouterReady ~= true or XInputSteamRouterSlot1Connected ~= true then
            XInputSteamRouterJoinWaitActive = true
            XInputSteamRouterJoinWaitTicks = 250 -- ~10 seconds, only after an explicit A join request
            XInputSteamRouterJoinWaitIntervalTicks = 0
            XInputSteamRouterJoinWaitAttempt = 0
            Log("Player creation deferred: Controllers=1 logical P2 slot is not live yet; router_ready=%s kind=%d game1=%s entry=%s",
                tostring(RouterCallOk and RouterReady == true), XInputSteamRouterLastKind,
                XInputSteamRouterRcText(XInputSteamRouterGameSlot1Rc), XInputSteamRouterEntryKindText(XInputSteamRouterEntryKindBefore))
            return
        end
    end
    CreatePlayerInProgress = true
    Log("Creating player 2..")
    CachePlayerControllers()

    local FirstController = PlayerControllerTable[1]
    if (not IsValidObject(FirstController)) and ResolveCurrentFrontendPlayerOne ~= nil then
        FirstController = ResolveCurrentFrontendPlayerOne("CreatePlayer fallback")
    end
    if not IsValidObject(FirstController) then
        Log("Player could not be created because current frontend player 1 was not found.")
        CreatePlayerInProgress = false
        return
    end

    if IsValidObject(PlayerControllerTable[2]) then
        Log("Player 2 already exists; this mod supports 2 players only.")
        CreatePlayerInProgress = false
        return
    end

    ApplyLocalMultiplayerSettings()
    local FirstControllerId = nil
    pcall(function()
        if IsValidObject(FirstController.Player) then
            FirstControllerId = FirstController.Player.ControllerId
        end
    end)
    Log("Player 1 ControllerId: %s; requesting player 2 ControllerId: 1", tostring(FirstControllerId))

    ExecuteInGameThreadWithDelay(0, function()
        local Ok, Result = false, nil
        if UseGamePassPlatformJoin then
            local CallOk, Started = pcall(StartGamePassPlatformJoin)
            Ok = CallOk and Started == true
            Result = Started
            if not Ok then
                Log(
                    "GAMEPASS JOIN platform path failed; falling back to CreatePlayer: call_ok=%s result=%s",
                    tostring(CallOk),
                    tostring(Started)
                )
            end
        end
        if not Ok then
            Ok, Result = pcall(function()
                return GetGameplayStatics():CreatePlayer(FirstController, 1, true)
            end)
        end
        if not Ok then
            Log("CreatePlayer reflected return failed; verifying live ControllerId 1 instead: %s", tostring(Result))
        end

        -- Do not trust CreatePlayer's returned userdata. Verify from the live
        -- controller set, then do exactly ONE layout/UI refresh. A bounded one-shot
        -- verification chain also ensures frontend rejoin does not depend on
        -- the long-lived state worker surviving an earlier campaign session.
        CreatePlayerInProgress = false
        JoinVerificationActive = true
        JoinVerificationTicks = 0
        PlayerTwoExpected = true
        Log("Join verification armed; waiting for Player 2 ControllerId 1")
        if ScheduleJoinVerification ~= nil then
            ScheduleJoinVerification(1)
        end
    end)
end

local function EarlyFullName(Object)
    if not IsValidObject(Object) then return "" end
    local Value = ""
    pcall(function() Value = Object:GetFullName() end)
    return tostring(Value or "")
end

local function FindLocalPlayerController(ControllerId)
    local LocalPlayers = nil
    pcall(function() LocalPlayers = FindAllOf("LocalPlayer") end)
    for _, LocalPlayer in ipairs(LocalPlayers or {}) do
        if IsValidObject(LocalPlayer) then
            local Id, PC = nil, nil
            pcall(function() Id = LocalPlayer.ControllerId end)
            if Id == ControllerId then
                pcall(function() PC = LocalPlayer.PlayerController end)
                if IsValidObject(PC) then return PC end
            end
        end
    end
    return nil
end

-- WinGDK / Xbox App platform join ---------------------------------------------
-- Steam keeps the standard GameplayStatics CreatePlayer path. WinGDK uses the
-- proven manual-offline join sequence from the clean Game Pass baseline:
-- AddSplitscreenPlayerAndBroadcast -> LoginSplitScreenPlayer ->
-- PromoteSplitscreenPlayerToV2. Keep this path isolated from Steam.
GamePassPromoteGeneration = GamePassPromoteGeneration or 0

-- Controllers=1 WinGDK note: the physical gamepad may already appear mapped to
-- P1 in InputDeviceLibrary even though the native pending-player event carries
-- the correct P2 FPlatformUserId. Prefer that event user instead of guessing.
function ResolveGamePassPlatformUserByInternalId(TargetInternalId)
    TargetInternalId = tonumber(TargetInternalId)
    if TargetInternalId == nil then return nil, "invalid-target" end

    local InputLibrary = StaticFindObject("/Script/Engine.Default__InputDeviceLibrary")
    if not IsValidObject(InputLibrary) then return nil, "no-input-library" end

    local function Matches(User)
        local Id = nil
        local Ok = pcall(function() Id = User.InternalId end)
        return Ok and tonumber(Id) == TargetInternalId
    end

    local UnpairedOk, Unpaired = pcall(function()
        return InputLibrary:GetUserForUnpairedInputDevices()
    end)
    if UnpairedOk and Unpaired ~= nil and Matches(Unpaired) then
        return Unpaired, "unpaired"
    end

    local Users = {}
    local UsersOk = pcall(function() InputLibrary:GetAllActiveUsers(Users) end)
    if UsersOk then
        for _, WrappedUser in pairs(Users) do
            local UserOk, User = pcall(function() return WrappedUser:get() end)
            if UserOk and User ~= nil and Matches(User) then
                return User, "active-user"
            end
        end
    end

    local Devices = {}
    local DevicesOk = pcall(function() InputLibrary:GetAllConnectedInputDevices(Devices) end)
    if DevicesOk then
        for Index, WrappedDevice in pairs(Devices) do
            local DeviceOk, Device = pcall(function() return WrappedDevice:get() end)
            if DeviceOk and Device then
                local UserOk, User = pcall(function()
                    return InputLibrary:GetUserForInputDevice(Device)
                end)
                if UserOk and User ~= nil and Matches(User) then
                    return User, "device:" .. tostring(Index)
                end
            end
        end
    end

    return nil, "not-resolved"
end

function FindUnassignedGamePassPlatformUser()
    local InputLibrary = StaticFindObject("/Script/Engine.Default__InputDeviceLibrary")
    if not IsValidObject(InputLibrary) then
        Log("GAMEPASS JOIN InputDeviceLibrary was not found")
        return nil
    end

    -- UE4SS exposes GetAllConnectedInputDevices with an output-array parameter.
    -- The clean WinGDK baseline passes the table explicitly; calling it with no
    -- argument causes a reflected-signature mismatch on UE4SS 3.0.1.
    local Devices = {}
    local DevicesOk, DeviceCount = pcall(function()
        return InputLibrary:GetAllConnectedInputDevices(Devices)
    end)
    if not DevicesOk then
        Log("GAMEPASS JOIN GetAllConnectedInputDevices failed: %s", tostring(DeviceCount))
        return nil
    end

    for Index, WrappedDevice in pairs(Devices) do
        local DeviceOk, Device = pcall(function() return WrappedDevice:get() end)
        if DeviceOk and Device then
            local UserOk, User = pcall(function()
                return InputLibrary:GetUserForInputDevice(Device)
            end)
            local ControllerOk, MappedController = pcall(function()
                return InputLibrary:GetPlayerControllerFromInputDevice(Device)
            end)
            local HasController = ControllerOk and IsValidObject(MappedController)
            local ValidOk, ValidUser = pcall(function()
                return UserOk and InputLibrary:IsValidPlatformId(User)
            end)
            Log(
                "GAMEPASS JOIN device=%s user_valid=%s has_controller=%s",
                tostring(Index),
                ValidOk and tostring(ValidUser) or "false",
                tostring(HasController)
            )
            if UserOk and ValidOk and ValidUser
                and ((not HasController) or ConfiguredControllerCount == 1) then
                return User
            end
        end
    end

    Log("GAMEPASS JOIN no unassigned valid controller platform user was found")
    return nil
end

function StartGamePassPlatformJoinFromEvent(EventPlatformUserId, EventInternalId)
    if EventPlatformUserId == nil then
        Log("GAMEPASS EVENT JOIN refused: event PlatformUserId was nil")
        return false
    end
    if ConfiguredControllerCount == 1 then
        local RouterCallOk, RouterReady = pcall(EnsureAdaptiveSteamInputRouting, "GamePass event join preflight", true)
        if not RouterCallOk or RouterReady ~= true then
            Log("GAMEPASS EVENT JOIN refused: Controllers=1 input router is not ready; stock handler remains untouched")
            ScheduleAdaptiveInputRouterRetries("GamePass event join preflight")
            return false
        end
    end

    local Instances = FindAllOf("HaloOnlineGameInstance") or {}
    local GameInstance = nil
    for _, Candidate in pairs(Instances) do
        if IsValidObject(Candidate) then
            GameInstance = Candidate
            break
        end
    end
    if not IsValidObject(GameInstance) then
        Log("GAMEPASS EVENT JOIN HaloOnlineGameInstance was not found")
        return false
    end

    Log("GAMEPASS EVENT JOIN using native pending-player PlatformUserId=%s", tostring(EventInternalId))

    -- These two calls are synchronous reflected invocations, so use the exact
    -- FPlatformUserId supplied by Halo before the hook parameter is neutralized.
    local AddOk, AddResult = pcall(function()
        return GameInstance:AddSplitscreenPlayerAndBroadcast(EventPlatformUserId)
    end)
    Log("GAMEPASS EVENT JOIN AddSplitscreenPlayerAndBroadcast ok=%s result=%s",
        tostring(AddOk), tostring(AddResult))
    if not AddOk then return false end

    local LoginOk, LoginResult = pcall(function()
        return GameInstance:LoginSplitScreenPlayer(EventPlatformUserId)
    end)
    Log("GAMEPASS EVENT JOIN LoginSplitScreenPlayer ok=%s result=%s",
        tostring(LoginOk), tostring(LoginResult))
    if not LoginOk then return false end

    GamePassPromoteGeneration = (tonumber(GamePassPromoteGeneration) or 0) + 1
    local Generation = GamePassPromoteGeneration
    local function Promote(Attempt)
        if Generation ~= GamePassPromoteGeneration then return end
        if Attempt > 30 then
            Log("GAMEPASS EVENT JOIN PromoteSplitscreenPlayerToV2 gave up after 30 attempts")
            return
        end
        ExecuteInGameThreadWithDelay(500, function()
            if Generation ~= GamePassPromoteGeneration then return end
            if not IsValidObject(GameInstance) then
                Log("GAMEPASS EVENT JOIN game instance disappeared before promotion")
                return
            end

            -- The original UFunction parameter storage is short-lived. Resolve a
            -- fresh FPlatformUserId with the same InternalId for delayed promotion.
            local PromoteUser, ResolveSource = ResolveGamePassPlatformUserByInternalId(EventInternalId)
            if PromoteUser == nil then
                Log("GAMEPASS EVENT JOIN promote attempt=%d waiting for PlatformUserId=%s (%s)",
                    Attempt, tostring(EventInternalId), tostring(ResolveSource))
                Promote(Attempt + 1)
                return
            end

            local PromoteOk, PromoteResult = pcall(function()
                return GameInstance:PromoteSplitscreenPlayerToV2(PromoteUser)
            end)
            Log("GAMEPASS EVENT JOIN promote attempt=%d user=%s source=%s ok=%s result=%s",
                Attempt, tostring(EventInternalId), tostring(ResolveSource),
                tostring(PromoteOk), tostring(PromoteResult))
            if PromoteOk and PromoteResult == true then
                Log("GAMEPASS EVENT JOIN promotion succeeded for PlatformUserId=%s", tostring(EventInternalId))
                return
            end
            Promote(Attempt + 1)
        end)
    end
    Promote(1)
    return true
end

function StartGamePassPlatformJoin()
    local PlatformUserId = FindUnassignedGamePassPlatformUser()
    if PlatformUserId == nil then return false end

    local Instances = FindAllOf("HaloOnlineGameInstance") or {}
    local GameInstance = nil
    for _, Candidate in pairs(Instances) do
        if IsValidObject(Candidate) then
            GameInstance = Candidate
            break
        end
    end
    if not IsValidObject(GameInstance) then
        Log("GAMEPASS JOIN HaloOnlineGameInstance was not found")
        return false
    end

    local AddOk, AddResult = pcall(function()
        return GameInstance:AddSplitscreenPlayerAndBroadcast(PlatformUserId)
    end)
    Log(
        "GAMEPASS JOIN AddSplitscreenPlayerAndBroadcast ok=%s result=%s",
        tostring(AddOk),
        tostring(AddResult)
    )
    if not AddOk then return false end

    local LoginOk, LoginResult = pcall(function()
        return GameInstance:LoginSplitScreenPlayer(PlatformUserId)
    end)
    Log(
        "GAMEPASS JOIN LoginSplitScreenPlayer ok=%s result=%s",
        tostring(LoginOk),
        tostring(LoginResult)
    )

    GamePassPromoteGeneration = (tonumber(GamePassPromoteGeneration) or 0) + 1
    local Generation = GamePassPromoteGeneration
    local function Promote(Attempt)
        if Generation ~= GamePassPromoteGeneration then return end
        if Attempt > 15 then
            Log("GAMEPASS JOIN PromoteSplitscreenPlayerToV2 gave up after 15 attempts")
            return
        end
        ExecuteInGameThreadWithDelay(1000, function()
            if Generation ~= GamePassPromoteGeneration then return end
            if not IsValidObject(GameInstance) then
                Log("GAMEPASS JOIN game instance disappeared before promotion")
                return
            end
            local PromoteOk, PromoteResult = pcall(function()
                return GameInstance:PromoteSplitscreenPlayerToV2(PlatformUserId)
            end)
            Log(
                "GAMEPASS JOIN promote attempt=%d ok=%s result=%s",
                Attempt,
                tostring(PromoteOk),
                tostring(PromoteResult)
            )
            if PromoteOk and PromoteResult == true then
                Log("GAMEPASS JOIN promotion succeeded")
                return
            end
            Promote(Attempt + 1)
        end)
    end
    Promote(1)
    return true
end

function ResetGamePassPlatformJoinState(Reason)
    -- Invalidate delayed promotion callbacks when leaving a frontend/campaign
    -- session. The proven join keeps GameInstance/User references closure-local.
    GamePassPromoteGeneration = (tonumber(GamePassPromoteGeneration) or 0) + 1
    if UseGamePassPlatformJoin then
        Log("GAMEPASS JOIN promotion state reset: %s", tostring(Reason or "session boundary"))
    end
end

local function ResetRespawnSessionBoundary(Reason)
    ResetGamePassPlatformJoinState(Reason)
    -- These functions are defined later in the chunk but exist by the time a
    -- frontend/menu boundary can be observed. Keep the reset entirely off the
    -- gameplay hot path.
    if ResetMissionSelection ~= nil then
        pcall(function() ResetMissionSelection("menu/session boundary: " .. tostring(Reason)) end)
    end
    LivesMissionControllerName = ""
    MissionControllerObject = nil
    MissionCandidateName = ""
    MissionCandidateTicks = 0
    HudReadyTicks = 0
    LastDeathByPlayer = {}
    CurrentCampaignMapKey = ""
    TravelResetActive = false
    TravelRecoveryToken = (tonumber(TravelRecoveryToken) or 0) + 1
    TravelRecoveryRecoveredToken = -1
    if ClearPendingTravel ~= nil then pcall(ClearPendingTravel) end
    FrontendBoundarySeen = true
    LivesAuthorityResolved = false
    LivesAuthorityAllowed = true
    LivesNetworkClientBlocked = false
    LivesAuthorityNoticeShown = false
    if DisplayLivesBanner ~= nil then pcall(function() DisplayLivesBanner(" ") end) end
    if ClearBannerCache ~= nil then pcall(function() ClearBannerCache("fresh-session boundary") end) end
    if ResetWarthogColorState ~= nil then
        pcall(function() ResetWarthogColorState("frontend/session boundary: " .. tostring(Reason)) end)
    end
    if ResetScorpionColorState ~= nil then
        pcall(function() ResetScorpionColorState("frontend/session boundary: " .. tostring(Reason)) end)
    end
end

-- The frontend PlayerController can expose ControllerId=nil and its ReceiveTick is
-- not guaranteed to reach the mission lifecycle hook on every return to menu. The
-- native squad lobby UI is reconstructed reliably, so use that existing UI event as
-- a second, one-shot hard session boundary. No polling or global scan is added.
function HandleFrontendRespawnBoundary(Source)
    if FrontendBoundarySeen then return end

    -- A squad/fireteam widget is not proof of a frontend session: Halo can
    -- reconstruct those widgets during active campaign gameplay. Clearing VehNet
    -- capability state in that case is incorrect, so ignore the signal
    -- whenever the actual world is still campaign/seamless-transition.
    local SessionKind = CurrentWorldSessionKind()
    if SessionKind == "campaign" or SessionKind == "transition" then return end

    local HadMissionState = MissionReady or SetupActive or SelectionLocked or
        MissionLivesEnabled or GameOverPending or LivesMissionControllerName ~= "" or
        TravelPending or CurrentCampaignMapKey ~= ""

    if not HadMissionState then
        FrontendBoundarySeen = true
        return
    end

    ResetRespawnSessionBoundary("frontend UI signal: " .. tostring(Source or "unknown"))
    Log("LIVES frontend UI session boundary RESET; next campaign setup defaults to OFF")
end

local function DestroyPlayer(Source)
    -- P2 removal remains deliberately simple and menu-only. Resolve LocalPlayers
    -- only when an explicit leave action completes (Ctrl+U or the P2 A hold).
    local LeaveSource = tostring(Source or "Ctrl+U")
    local P1 = FindLocalPlayerController(0)
    local P2 = FindLocalPlayerController(1)
    if not IsValidObject(P2) then
        Log("P2MENU %s: no local P2 found", LeaveSource)
        return
    end

    local ContextName = string.lower(EarlyFullName(P1) .. " " .. EarlyFullName(P2))
    local InMenu = string.find(ContextName, "/game/levels/ui/frontend/", 1, true) ~= nil or
        string.find(ContextName, "/game/levels/test/seamlesstraveltest", 1, true) ~= nil
    if not InMenu then
        Log("P2MENU %s ignored during active campaign", LeaveSource)
        return
    end

    local TargetName = EarlyFullName(P2)
    local Ok, Err = pcall(function() GetGameplayStatics():RemovePlayer(P2, true) end)
    Log("P2MENU RemovePlayer source=%s result=%s target=%s%s", LeaveSource, tostring(Ok), tostring(TargetName),
        Ok and "" or (" error=" .. tostring(Err)))
    if not Ok then return end

    PlayerControllerTable[2] = nil
    PlayerTwoExpected = false
    CreatePlayerInProgress = false
    JoinVerificationActive = false
    JoinVerificationTicks = 0
    ResetPerspectiveNative(LeaveSource .. " local P2 removal")
    P2MenuLeaveController = nil
    P2MenuLeaveBindingName = ""
    P2MenuLeaveHoldTicks = 0
    P2MenuLeaveHoldLatched = false
    P2SpartanSessionName = ""
    P2SpartanRandomState = 0
    IdentityFrontendNameLastSignature = ""
    IdentityFrontendNamePublishToken = (tonumber(IdentityFrontendNamePublishToken) or 0) + 1
    ApplySoloMenuState()
    ResetRespawnSessionBoundary(LeaveSource .. " local P2 removal")
    Log("SESSION local P2 cleanup complete: mod-owned join verification/perspective state cleared; Halo fireteam/online-session state left to the game")
    if ApplyStaticFrontendJoinPrompt ~= nil then
        pcall(function() ApplyStaticFrontendJoinPrompt(1) end)
    end
end

-- Runtime orientation must not depend on UE4SS's EngineTick callback registry.
-- Some runs invalidate ExecuteInGameThread/ExecuteWithDelay refs with "Ref was not
-- function" while the stable campaign ReceiveTick hook keeps running. Queue the
-- request and perform both viewport mutation and the short HUD settle sequence from
-- P1 ReceiveTick instead.
OrientationToggleRequested = OrientationToggleRequested or false
OrientationReapplyRequested = OrientationReapplyRequested or false
OrientationToggleSource = OrientationToggleSource or ""
OrientationHudStage = OrientationHudStage or 0
OrientationHudRemaining = OrientationHudRemaining or 0.0

local function ReapplyViewportFixes()
    -- Called only from P1 BP_MeteoritePlayerController.ReceiveTick (game thread).
    -- Never clear a cinematic/menu fullscreen override. Leave the request
    -- queued until the game has left cinematic mode.
    if CinematicActive == true or (IsSplitForceDisabled ~= nil and IsSplitForceDisabled()) then
        OrientationReapplyRequested = true
        return false
    end
    ApplyLocalMultiplayerSettings()
    RunConsoleCommand(ViewportHoldCVar .. " 0")
    RefreshSplitscreenLayout()
    OrientationHudStage = 1
    OrientationHudRemaining = 0.10
    Log("SPLIT viewport reapplied; HUD settle queued on ReceiveTick")
end

-- Switches between left/right and top/bottom without restarting. The actual Unreal
-- work is deliberately deferred to P1 ReceiveTick so keyboard and controller requests
-- share one safe path and do not rely on ExecuteInGameThread.
local function ToggleSplitOrientation(Source)
    OrientationToggleRequested = true
    OrientationToggleSource = tostring(Source or "orientation shortcut")
end

function OrientationNeedsTick()
    return OrientationToggleRequested or OrientationReapplyRequested or OrientationHudStage ~= 0
end

function OrientationRuntimeTick(DeltaSeconds)
    -- Orientation requests may be made during a cinematic, but they are
    -- intentionally held until the fullscreen cinematic override is released.
    if CinematicActive == true or (IsSplitForceDisabled ~= nil and IsSplitForceDisabled()) then
        return
    end

    local Delta = tonumber(DeltaSeconds) or 0.0
    if Delta < 0.0 then Delta = 0.0 end
    if Delta > 0.25 then Delta = 0.25 end

    if OrientationToggleRequested then
        OrientationToggleRequested = false
        local Source = OrientationToggleSource
        OrientationToggleSource = ""
        local BeforeOrientation = WantsSideBySide() and "sidebyside" or "stacked"
        SplitOrientation = BeforeOrientation == "sidebyside" and "stacked" or "sidebyside"
        Log("SPLIT applying queued orientation source=%s", tostring(Source))
        Log("Switching to %s..", SplitOrientation == "sidebyside" and "left/right" or "top/bottom")
        local ControllerPlayer = string.match(tostring(Source), "^controller P(%d+)$")
        if ControllerPlayer ~= nil then
            Log("INPUT P%s SPLIT apply result from=%s to=%s",
                tostring(ControllerPlayer), tostring(BeforeOrientation), tostring(SplitOrientation))
        end
        ReapplyViewportFixes()
        return
    end

    if OrientationReapplyRequested then
        OrientationReapplyRequested = false
        Log("SPLIT applying queued viewport reapply")
        ReapplyViewportFixes()
        return
    end

    if OrientationHudStage == 0 then return end
    OrientationHudRemaining = OrientationHudRemaining - Delta
    if OrientationHudRemaining > 0.0 then return end

    if OrientationHudStage == 1 then
        -- The player rectangles have had at least one later frame to settle.
        if WantsSideBySide() then
            ApplyHudScale()
        else
            RestoreHudScale()
        end
        EnableHaloUISplitscreen()
        OrientationHudStage = 2
        OrientationHudRemaining = 0.15
        Log("SPLIT HUD rebuild stage 1 complete")
        return
    end

    if OrientationHudStage == 2 then
        InvalidateHaloWidgets("orientation settle")
        OrientationHudStage = 0
        OrientationHudRemaining = 0.0
        Log("SPLIT HUD rebuild COMPLETE")
    end
end

-- Returns a stable object name for lifecycle filtering and logging.
local function SafeFullName(Object)
    if not IsValidObject(Object) then
        return "invalid"
    end
    local Value = "unknown"
    pcall(function() Value = Object:GetFullName() end)
    return tostring(Value)
end


-- ---------------------------------------------------------------------------
-- Native split-screen sign-in join
-- ---------------------------------------------------------------------------
-- The sign-in hook feeds one debounced scheduler. A travel generation token and
-- teardown guard prevent delayed work from surviving campaign exit. The old
-- retry timer is intentionally removed to reduce teardown risk.
local PendingJoinScheduled = false
local JoinTravelGeneration = 0
local NativeJoinDelayMs = 750
-- HCE UE4SS compatibility builds can start Lua mods before these Blueprint
-- UFunctions have been constructed. Track readiness so the state worker can
-- bind them later without registering duplicate hooks.
local NativeJoinSigninHookReady = false
local NativeJoinSubsystemHookReady = false
NativeJoinHookRetryTicks = 0

local function CancelPendingNativeJoin(Reason)
    JoinTravelGeneration = JoinTravelGeneration + 1
    if PendingJoinScheduled then
        Log("Cancelled pending native join: %s", Reason or "state change")
    end
    PendingJoinScheduled = false
    JoinDelayTicksRemaining = 0
end

-- The fallback join debounce shares the long-lived state worker below instead of
-- creating another repeating timer.
JoinDelayTicksRemaining = 0
JoinScheduledGeneration = 0
local function ScheduleNativePlayerTwo(Source)
    if ModTeardownGuard then return end

    -- UE4SS can invalidate the persistent EngineTick callback used by the
    -- long-lived join state worker during a campaign session. Restart it on every native
    -- sign-in event before checking an older pending request. If an earlier request
    -- became stranded with that worker, a second A press can now re-arm the same
    -- guarded debounce instead of being ignored forever.
    if RestartJoinStateMachineWorker ~= nil then
        RestartJoinStateMachineWorker("native join event")
    end

    if PendingJoinScheduled then
        JoinScheduledGeneration = JoinTravelGeneration
        JoinDelayTicksRemaining = 19
        Log("Native join re-triggered by %s; pending request re-armed.", Source or "unknown")
        return
    end
    if CreatePlayerInProgress or JoinVerificationActive then return end

    CachePlayerControllers()
    if IsValidObject(PlayerControllerTable[2]) then return end

    -- The restarted state worker remains as one bounded path, but also arm one
    -- guarded delayed CreatePlayer callback so the first A press does not depend
    -- solely on the long-lived state worker surviving the previous session.
    PendingJoinScheduled = true
    JoinScheduledGeneration = JoinTravelGeneration
    JoinDelayTicksRemaining = 19 -- legacy worker path remains as an additional fallback
    Log("Native join requested by %s; guarded create in about %dms.", Source or "unknown", NativeJoinDelayMs)

    local ScheduledGeneration = JoinScheduledGeneration
    ExecuteInGameThreadWithDelay(NativeJoinDelayMs, function()
        if not PendingJoinScheduled then return end
        if ModTeardownGuard or ScheduledGeneration ~= JoinTravelGeneration then
            PendingJoinScheduled = false
            JoinDelayTicksRemaining = 0
            Log("Native join one-shot cancelled by travel/teardown.")
            return
        end

        CachePlayerControllers()
        if IsValidObject(PlayerControllerTable[2]) then
            PendingJoinScheduled = false
            JoinDelayTicksRemaining = 0
            return
        end

        Log("Native join guarded delay complete; creating player 2.")
        PendingJoinScheduled = false
        JoinDelayTicksRemaining = 0
        CreatePlayer()
    end)
end

local function TryRegisterNativeJoinHook(Path, Source, Quiet)
    local Ok, Result = pcall(function()
        RegisterHook(Path,
            function(Context, UserIndex, PlatformUserId, Input)
                -- UE4SS 3.0.1 passes a hook context wrapper here that does not
                -- expose UObject:IsValid(). The UFunction hook itself is enough
                -- to scope this to the splitscreen sign-in event.
                if ModTeardownGuard then return end
                CachePlayerControllers()
                if #PlayerControllerTable >= 2 then return end

                if UseGamePassPlatformJoin and Source == "signin-widget" then
                    local IncomingPlatformUser = nil
                    local IncomingPlatformInternalId = nil
                    local IncomingOk, IncomingErr = pcall(function()
                        IncomingPlatformUser = PlatformUserId:get()
                        if IncomingPlatformUser ~= nil then
                            IncomingPlatformInternalId = IncomingPlatformUser.InternalId
                        end
                    end)
                    Log("GAMEPASS EVENT JOIN captured source=%s user_index=%s platform_user=%s read_ok=%s",
                        tostring(Source),
                        tostring((function() local v=nil; pcall(function() v=UserIndex:get() end); return v end)()),
                        tostring(IncomingPlatformInternalId), tostring(IncomingOk))

                    local StartOk, Started = false, false
                    if IncomingOk and IncomingPlatformUser ~= nil and IncomingPlatformInternalId ~= nil then
                        StartOk, Started = pcall(function()
                            return StartGamePassPlatformJoinFromEvent(
                                IncomingPlatformUser, IncomingPlatformInternalId
                            )
                        end)
                    else
                        Log("GAMEPASS EVENT JOIN could not read native PlatformUserId: %s", tostring(IncomingErr))
                    end

                    if StartOk and Started == true then
                        -- The manual local-P2 path now owns the actual event user.
                        -- Feed P1 to the original widget handler so it does not race
                        -- us with a second-account Game Pass flow.
                        local Neutralized, NeutralizeError = pcall(function()
                            local PrimaryController = PlayerControllerTable[1]
                            if (not IsValidObject(PrimaryController))
                                and ResolveCurrentFrontendPlayerOne ~= nil then
                                PrimaryController = ResolveCurrentFrontendPlayerOne(
                                    "Game Pass event-user stock neutralization"
                                )
                            end
                            if not IsValidObject(PrimaryController) then
                                error("frontend P1 controller unavailable")
                            end
                            local PrimaryUser = PrimaryController:GetPlatformUserId()
                            PlatformUserId:set(PrimaryUser)
                        end)
                        Log("GAMEPASS EVENT JOIN stock handler neutralized=%s%s",
                            tostring(Neutralized),
                            Neutralized and "" or (" error=" .. tostring(NeutralizeError)))

                        JoinVerificationActive = true
                        JoinVerificationTicks = 0
                        PlayerTwoExpected = true
                        ScheduleJoinVerification(1)
                        Log("GAMEPASS EVENT JOIN started with exact native PlatformUserId; verification armed")
                        return
                    end

                    -- Fail open: if the exact-user path could not start, leave the
                    -- original PlatformUserId untouched and let Halo's stock event run.
                    Log("GAMEPASS EVENT JOIN exact-user start failed; leaving stock handler untouched ok=%s result=%s",
                        tostring(StartOk), tostring(Started))
                    return
                end

                Log("Native join event detected: %s", Source)
                ScheduleNativePlayerTwo(Source)
            end,
            function(Context, ...) end
        )
    end)

    if Ok then
        Log("Native join hook ready: %s", Source)
        return true
    end

    if not Quiet then
        Log("Native join hook unavailable (%s): %s", Source, tostring(Result))
    end
    return false
end

local function RegisterNativeSplitscreenJoinHook(Quiet)
    if not NativeJoinSigninHookReady then
        NativeJoinSigninHookReady = TryRegisterNativeJoinHook(
            "/Game/Blueprints/WBP_MeteoriteSplitscreenSignIn.WBP_MeteoriteSplitscreenSignIn_C:OnPendingPlayerButtonPressedEvent",
            "signin-widget", Quiet
        )
    end

    if not NativeJoinSubsystemHookReady then
        NativeJoinSubsystemHookReady = TryRegisterNativeJoinHook(
            "/Script/Meteorite.PendingPlayerSubsystem:OnPendingPlayerButtonPressed",
            "pending-player-subsystem", Quiet
        )
    end

    local Registered = NativeJoinSigninHookReady or NativeJoinSubsystemHookReady
    if not Quiet then
        if Registered then
            Log("Native A join ready; Ctrl+Y remains available as fallback.")
        else
            Log("Native A join unavailable; Ctrl+Y remains available.")
        end
    end
    return Registered
end


-- ---------------------------------------------------------------------------
-- Customization helpers used by the live armor browser
-- ---------------------------------------------------------------------------
local function TagToString(Tag)
    if Tag == nil then return "<nil>" end
    local Out = nil
    pcall(function() Out = Tag.TagName:ToString() end)
    return Out or "<unreadable-tag>"
end

local function TextToString(Text)
    if Text == nil then return "<nil>" end
    local Out = nil
    pcall(function() Out = Text:ToString() end)
    return Out or "<unreadable-text>"
end

local function FindCustomizationList()
    local All = nil
    pcall(function() All = FindAllOf("WBP_CustomizationList_C") end)
    if All then
        for _, Obj in ipairs(All) do
            if IsValidObject(Obj) then return Obj end
        end
    end
    return nil
end

local function FindLiveWrapperByEntry(TargetEntry, TargetSkin)
    local Wrappers = nil
    pcall(function() Wrappers = FindAllOf("BP_CustomizationListDataWrapper_C") end)
    if Wrappers == nil then return nil end
    local WantedEntry = string.lower(TargetEntry or "")
    local WantedSkin = string.lower(TargetSkin or "")
    for _, Wrapper in ipairs(Wrappers) do
        if IsValidObject(Wrapper) then
            local EntryName, SkinTag = nil, nil
            pcall(function() EntryName = Wrapper.EntryName end)
            pcall(function() SkinTag = Wrapper.SkinGameplayTag end)
            local Entry = string.lower(TextToString(EntryName))
            local Skin = string.lower(TagToString(SkinTag))
            if Entry == WantedEntry or (WantedSkin ~= "" and Skin == WantedSkin) then
                return Wrapper
            end
        end
    end
    return nil
end

local function SafeToString(Value)
    if Value == nil then return "<nil>" end
    local Current = Value
    for _ = 1, 5 do
        local OkText, Text = pcall(function() return Current:ToString() end)
        if OkText and Text ~= nil then
            local S = tostring(Text)
            if S ~= "" and not string.find(S, "RemoteUnrealParam:", 1, true) then return S end
        end
        local OkGet, Next = pcall(function() return Current:get() end)
        if not OkGet or Next == nil or Next == Current then break end
        Current = Next
    end
    return tostring(Current)
end

local function ArrayValues(Array)
    local Result = {}
    if Array == nil then return Result end
    local UsedForEach = false
    pcall(function()
        Array:ForEach(function(_, Param)
            UsedForEach = true
            local Value = Param
            for _ = 1, 5 do
                local OkGet, Next = pcall(function() return Value:get() end)
                if not OkGet or Next == nil or Next == Value then break end
                Value = Next
            end
            Result[#Result + 1] = Value
        end)
    end)
    if UsedForEach then return Result end

    local Num = 0
    pcall(function() Num = Array:GetArrayNum() end)
    if Num == 0 then pcall(function() Num = #Array end) end
    if Num > 0 then
        for I = 1, Num do
            local Value = nil
            pcall(function() Value = Array[I] end)
            if Value ~= nil then Result[#Result + 1] = Value end
        end
        return Result
    end
    pcall(function()
        for _, Value in pairs(Array) do Result[#Result + 1] = Value end
    end)
    return Result
end

local function FindDataTable(NamePart)
    local Tables = nil
    pcall(function() Tables = FindAllOf("DataTable") end)
    if Tables == nil then return nil end
    local Wanted = string.lower(NamePart or "")
    for _, Table in ipairs(Tables) do
        if IsValidObject(Table) then
            local Full = ""
            pcall(function() Full = Table:GetFullName() or "" end)
            if string.find(string.lower(Full), Wanted, 1, true) ~= nil then return Table end
        end
    end
    return nil
end

local function GetDataTableLibrary()
    local Lib = nil
    pcall(function() Lib = StaticFindObject("/Script/Engine.Default__DataTableFunctionLibrary") end)
    return Lib
end

local function SetTagName(TagStruct, Name)
    if TagStruct == nil then return false, "nil tag" end
    local Ok, Err = pcall(function()
        TagStruct.TagName = FName(Name)
    end)
    return Ok, Err
end

local function GetTagName(TagStruct)
    if TagStruct == nil then return "" end
    local Out = ""
    pcall(function() Out = TagStruct.TagName:ToString() end)
    return Out or ""
end

-- Weapon-skin switching is implemented alongside the gameplay input helpers below.

-- Armor browser - dual-player -----------------------------------------------
-- Both local players use the same edge-triggered armor input path.
-- Both players use the same combination on their own controller:
--   hold RB + tap D-pad LEFT/RIGHT.
-- P1 and P2 keep independent catalog positions.
--
-- Carrier/list note: HandleItemActivated is a method on the live
-- WBP_CustomizationList instance. The fallback discovers a live list and wrapper
-- only when the direct settings route fails. It never constructs synthetic UI UObjects,
-- which keeps the build on the safe path.
local ArmorCatalog = nil
local CatalogIndex = { [1] = 1, [2] = 1 }
local MainStatePollIntervalMs = 40
local ArmorCustomizationCarrier = nil
local ArmorCustomizationList = nil
-- Direct armor route: the game exposes one MeteoriteGameUserSettings object per local user.
-- Writing the selected customization there removes the old dependency on a live
-- frontend WBP_CustomizationList/widget. Globals are intentional: this file is
-- already close to Lua's 200-local main-chunk limit.
SettingsDefault = nil
IndexInitialized = { [1] = false, [2] = false }
ArmorTickHookArmed = false
ArmorTickBusy = false

-- Mission HUD repair: travel creates the Halo HUD well after the frontend join repair.
-- Track the live P1 mission controller and reapply the safe scale/UI rebuild at
-- three bounded points while the mission HUD finishes constructing. Globals are
-- intentional to avoid Lua's 200-local main-chunk limit.
HudControllerName = ""
HudRepairTicks = 0
HudRepairPass = 0
HudSoloRestored = false

-- Serialize native HandleItemActivated calls. P1 and P2 share one transient
-- wrapper/list carrier; calling it twice in the same frame can re-enter the
-- customization hook while the wrapper tags are temporarily mutated.
InternalApply = false
ApplyBusy = false
ApplyCooldownTicks = 0
PendingApply = { [1] = 0, [2] = 0 }
PendingTurn = 1

local function MakeKey(KeyName)
    return { KeyName = FName(KeyName) }
end

local KeyRightShoulder = MakeKey("Gamepad_RightShoulder")
local KeyDPadLeft = MakeKey("Gamepad_DPad_Left")
local KeyDPadRight = MakeKey("Gamepad_DPad_Right")
KeyFaceButtonLeft = MakeKey("Gamepad_FaceButton_Left")
KeyFaceButtonRight = MakeKey("Gamepad_FaceButton_Right")
KeyFaceButtonBottom = MakeKey("Gamepad_FaceButton_Bottom")
KeyFaceButtonTop = MakeKey("Gamepad_FaceButton_Top")
KeyLeftThumbstick = MakeKey("Gamepad_LeftThumbstick")
KeyRightThumbstick = MakeKey("Gamepad_RightThumbstick")
-- Globals on purpose: main.lua is close to Lua's 200-local main-chunk limit.
KeyDPadUp = MakeKey("Gamepad_DPad_Up")
KeyDPadDown = MakeKey("Gamepad_DPad_Down")
OrientationToggleCooldownTicks = OrientationToggleCooldownTicks or 0

local function ParseTagCell(Text)
    local S = tostring(Text or "")
    local Tag = string.match(S, 'TagName="([^"]*)"')
    if Tag ~= nil then return Tag end
    return S
end

local function GetColumnStrings(Lib, Table, Name)
    local Values = nil
    local Ok = pcall(function()
        Values = Lib:GetDataTableColumnAsString(Table, FName(Name))
    end)
    if not Ok or Values == nil then
        pcall(function() Values = Lib:GetDataTableColumnAsString(Table, Name) end)
    end
    local Result = {}
    for _, Value in ipairs(ArrayValues(Values)) do
        Result[#Result + 1] = SafeToString(Value)
    end
    return Result
end

local function BuildCatalog()
    local Lib = GetDataTableLibrary()
    local Table = FindDataTable("dt_masterchiefcustomization")
    if not IsValidObject(Table) then
        -- The table used to become available only after opening Customization.
        -- Load the asset explicitly so armor browsing also works in singleplayer
        -- and when the frontend armor page has never been visited.
        local Loaded = nil
        pcall(function()
            Loaded = LoadAsset("/Game/DataTables/DT_MasterChiefCustomization")
        end)
        if IsValidObject(Loaded) then Table = Loaded end
        if not IsValidObject(Table) then
            pcall(function()
                Table = StaticFindObject("/Game/DataTables/DT_MasterChiefCustomization.DT_MasterChiefCustomization")
            end)
        end
    end
    if not IsValidObject(Lib) or not IsValidObject(Table) then
        Log("ARMOR catalog unavailable after direct asset load")
        return false
    end
    local Skins = GetColumnStrings(Lib, Table, "CustomizationName")
    local Packages = GetColumnStrings(Lib, Table, "PackageName")
    local Models = GetColumnStrings(Lib, Table, "ModelVariantName")
    local Catalog = {}
    for I, SkinCell in ipairs(Skins) do
        local Skin = ParseTagCell(SkinCell)
        if Skin ~= nil and Skin ~= "" then
            local Package = ParseTagCell(Packages[I] or "")
            Catalog[#Catalog + 1] = {
                Skin = Skin,
                Package = Package or "",
                Model = tostring(Models[I] or ""),
                Short = string.match(Skin, "MasterChief%.(.+)$") or Skin,
            }
        end
    end
    ArmorCatalog = Catalog
    Log("ARMOR catalog built without frontend UI: %d Master Chief entries", #Catalog)
    return #Catalog > 0
end

function Unwrap(Value)
    local Result = Value
    for _ = 1, 4 do
        if Result == nil then break end
        local Ok, Next = pcall(function() return Result:get() end)
        if not Ok or Next == nil or Next == Result then break end
        Result = Next
    end
    return Result
end


-- Fullscreen campaign cinematics ---------------------------------------------
-- Unreal exposes a dedicated viewport flag for temporarily disabling split-screen
-- (menus/cinematics) plus PlayerController cinematic-mode UFunctions. Co-op Expanded
-- must not fight that state with a HUD/layout repair. Track cinematic entry/exit from
-- event hooks only; there is NO new per-frame scan or polling loop.
CinematicHooks = CinematicHooks or {}
CinematicSignals = CinematicSignals or {}
CinematicActive = CinematicActive or false
CinematicOverrideOwned = CinematicOverrideOwned or false
ShowAllWidgetsBeforeCinematic = ShowAllWidgetsBeforeCinematic

function CinematicBool(Value)
    local U = Unwrap(Value)
    if type(U) == "boolean" then return U end
    if type(U) == "number" then return U ~= 0 end
    if U == nil then return nil end
    local T = string.lower(tostring(U))
    if T == "true" then return true end
    if T == "false" then return false end
    local N = tonumber(string.match(T, "[-]?%d+"))
    if N ~= nil then return N ~= 0 end
    return nil
end

function IsSplitForceDisabled()
    local Viewport = nil
    local Disabled = nil
    pcall(function() Viewport = UEHelpers.GetGameViewportClient() end)
    if IsValidObject(Viewport) then
        pcall(function() Disabled = Viewport.bDisableSplitScreenOverride end)
    end
    return Disabled == true
end

function SetShowAllPlayerWidgets(Entering)
    local Settings = GetGameMapsSettings()
    if not Settings then return end
    if Entering then
        if ShowAllWidgetsBeforeCinematic == nil then
            pcall(function()
                ShowAllWidgetsBeforeCinematic = Settings.bShowAllPlayerWidgetsWhenSplitscreenDisabled
            end)
        end
        -- When split-screen is force-disabled we want exactly one player widget
        -- layer in the main viewport. This is wrapped because older game builds may
        -- not expose this standard UE setting through reflection.
        pcall(function() Settings.bShowAllPlayerWidgetsWhenSplitscreenDisabled = false end)
    else
        if ShowAllWidgetsBeforeCinematic ~= nil then
            pcall(function()
                Settings.bShowAllPlayerWidgetsWhenSplitscreenDisabled = ShowAllWidgetsBeforeCinematic
            end)
        end
        ShowAllWidgetsBeforeCinematic = nil
    end
end

function SetCinematicFullscreen(Active, Reason)
    Active = Active == true
    if Active == CinematicActive then return end
    CinematicActive = Active

    if Active then
        -- ApplicationScale is global. Never carry the side-by-side 2x HUD scale
        -- into a fullscreen cinematic/video layer; that can make it look cropped.
        RestoreHudScale()
        OrientationHudStage = 0
        OrientationHudRemaining = 0.0
        SetShowAllPlayerWidgets(true)

        local WasDisabled = IsSplitForceDisabled()
        if not WasDisabled then
            local Ok, Err = pcall(function()
                GetGameplayStatics():SetForceDisableSplitscreen(UEHelpers.GetWorldContextObject(), true)
            end)
            CinematicOverrideOwned = Ok
            Log("CINEMATIC ENTER fullscreen reason=%s forceDisabledBefore=%s applied=%s%s",
                tostring(Reason), tostring(WasDisabled), tostring(Ok), Ok and "" or (" (" .. tostring(Err) .. ")"))
        else
            CinematicOverrideOwned = false
            Log("CINEMATIC ENTER fullscreen reason=%s forceDisabledBefore=true (game already owns override)", tostring(Reason))
        end
        return
    end

    SetShowAllPlayerWidgets(false)
    if CinematicOverrideOwned then
        local Ok, Err = pcall(function()
            GetGameplayStatics():SetForceDisableSplitscreen(UEHelpers.GetWorldContextObject(), false)
        end)
        Log("CINEMATIC EXIT release-owned-override reason=%s result=%s%s",
            tostring(Reason), tostring(Ok), Ok and "" or (" (" .. tostring(Err) .. ")"))
    else
        Log("CINEMATIC EXIT reason=%s; waiting for game-owned fullscreen override to clear", tostring(Reason))
    end
    CinematicOverrideOwned = false

    -- Rebuild exactly once from the callback-independent P1 ReceiveTick path.
    -- If the game still owns bDisableSplitScreenOverride for another frame, the runtime
    -- defers this request instead of forcibly clearing it.
    if IsValidObject(PlayerControllerTable[2]) then
        OrientationReapplyRequested = true
    end
end

function RecomputeCinematicState(Reason)
    local Any = false
    for _, Value in pairs(CinematicSignals) do
        if Value == true then Any = true break end
    end
    SetCinematicFullscreen(Any, Reason)
end

function CinematicSignal(Label, Context, ...)
    local Args = {...}
    local Active = CinematicBool(Args[1])
    if Active == nil then
        Log("CINEMATIC signal unreadable label=%s firstArg=%s", tostring(Label), tostring(Unwrap(Args[1])))
        return
    end

    local Key = "level"
    if Label ~= "LevelScriptActor.SetCinematicMode" then
        local Controller = Unwrap(Context)
        local Id = nil
        if IsValidObject(Controller) then
            pcall(function()
                if IsValidObject(Controller.Player) then Id = Controller.Player.ControllerId end
            end)
        end
        -- Ignore remote/network PlayerControllers. Local split players in this mod
        -- use numeric ControllerId 0/1.
        if type(Id) ~= "number" or Id < 0 or Id > 1 then return end
        Key = "pc:" .. tostring(Id)
    end

    CinematicSignals[Key] = Active
    Log("CINEMATIC signal %s key=%s active=%s", tostring(Label), tostring(Key), tostring(Active))
    RecomputeCinematicState(Label)
end

function TryCinematicHook(Label, Path)
    if CinematicHooks[Label] then return true end
    local Ok, Err = pcall(function()
        RegisterHook(Path,
            function(Context, ...)
                local CallOk, CallErr = pcall(CinematicSignal, Label, Context, ...)
                if not CallOk then Log("CINEMATIC hook callback error %s: %s", Label, tostring(CallErr)) end
            end,
            function(Context, ...) end)
    end)
    if Ok then
        CinematicHooks[Label] = true
        Log("CINEMATIC hook ready: %s -> %s", Label, Path)
        return true
    end
    Log("CINEMATIC hook unavailable: %s -> %s | %s", Label, Path, tostring(Err))
    return false
end

function RegisterCinematicHooks()
    -- Standard UE UFunctions. Register once; no retries and no gameplay poller.
    TryCinematicHook("PlayerController.SetCinematicMode", "/Script/Engine.PlayerController:SetCinematicMode")
    TryCinematicHook("PlayerController.ClientSetCinematicMode", "/Script/Engine.PlayerController:ClientSetCinematicMode")
    TryCinematicHook("LevelScriptActor.SetCinematicMode", "/Script/Engine.LevelScriptActor:SetCinematicMode")
end

function GetUserSettings(PlayerIndex)
    if not IsValidObject(SettingsDefault) then
        pcall(function()
            SettingsDefault = StaticFindObject("/Script/Meteorite.Default__MeteoriteGameUserSettings")
        end)
    end
    if not IsValidObject(SettingsDefault) then
        return nil, "Default__MeteoriteGameUserSettings not found"
    end

    local Settings = nil
    local UserIndex = math.max(0, (tonumber(PlayerIndex) or 1) - 1)
    local Ok, Err = pcall(function()
        Settings = SettingsDefault:Get(UserIndex)
    end)
    Settings = Unwrap(Settings)
    if not Ok or not IsValidObject(Settings) then
        return nil, Ok and ("no settings for local user " .. tostring(UserIndex)) or tostring(Err)
    end
    return Settings, "local user " .. tostring(UserIndex)
end

-- ---------------------------------------------------------------------------
-- P2 settings + graphics profile inheritance
--
-- One-time inheritance only: when local P2 is created, copy P1's verified
-- per-user gameplay/video profile into P2, then apply once. There is no live
-- watcher after join. Do not clone the whole settings object: identity,
-- customization, accessibility/input profile state outside this whitelist stays
-- independent.
-- ---------------------------------------------------------------------------
local P2GraphicsSyncPropertyNames = {
    -- Per-view/per-user visual settings. Keep renderer/display ownership global.
    "ColorCorrectionBrightness",
    "bFlashingEffects",
    "bScreenShake",
    "bMotionBlur",
    "DamageScreenEffectsOpacity",

    -- Halo/Meteorite rendering profile fields that can differ for local P2.
    "Upscaler",
    "QualityPreset",
    "UpscalingQuality",
    "TextureQuality",
    "GeometryQuality",
    "ReflectionsQuality",
    "GlobalIlluminationQuality",
    "LightingQuality",
    "EffectsQuality",
    "AtmosphericsQuality",
    "PostprocessingQuality",
}

function SyncPlayerTwoSettingsFromP1(Reason)
    local P1Settings, P1Info = GetUserSettings(1)
    local P2Settings, P2Info = GetUserSettings(2)
    if not IsValidObject(P1Settings) or not IsValidObject(P2Settings) then
        Log("P2SETTINGS SYNC skipped reason=%s P1=%s valid=%s P2=%s valid=%s",
            tostring(Reason or "join"), tostring(P1Info), tostring(IsValidObject(P1Settings)),
            tostring(P2Info), tostring(IsValidObject(P2Settings)))
        return false
    end

    local HudAnchoring = ReadHudAnchoring(P1Settings)
    local WriteOk, WriteErr = pcall(function()
        -- Requested gameplay setting.
        P2Settings.ControllerWarthogDrivingMode = P1Settings.ControllerWarthogDrivingMode

        -- Per-user/per-view copy only. Frame Generation can produce P2-only
        -- split-screen ghosting even when both user settings match. Renderer/window
        -- controls are shared process/view state rather than useful P2 profile
        -- inheritance. Do NOT write bFrameGeneration, LowLatencyMode, framerate
        -- limits, fullscreen/window mode, resolution, VSync, dynamic resolution or
        -- HDR-output here.
        P2Settings.ColorCorrectionBrightness = P1Settings.ColorCorrectionBrightness
        P2Settings.bFlashingEffects = P1Settings.bFlashingEffects
        P2Settings.bScreenShake = P1Settings.bScreenShake
        P2Settings.bMotionBlur = P1Settings.bMotionBlur
        P2Settings.DamageScreenEffectsOpacity = P1Settings.DamageScreenEffectsOpacity

        P2Settings.Upscaler = P1Settings.Upscaler
        P2Settings.QualityPreset = P1Settings.QualityPreset
        P2Settings.UpscalingQuality = P1Settings.UpscalingQuality
        P2Settings.TextureQuality = P1Settings.TextureQuality
        P2Settings.GeometryQuality = P1Settings.GeometryQuality
        P2Settings.ReflectionsQuality = P1Settings.ReflectionsQuality
        P2Settings.GlobalIlluminationQuality = P1Settings.GlobalIlluminationQuality
        P2Settings.LightingQuality = P1Settings.LightingQuality
        P2Settings.EffectsQuality = P1Settings.EffectsQuality
        P2Settings.AtmosphericsQuality = P1Settings.AtmosphericsQuality
        P2Settings.PostprocessingQuality = P1Settings.PostprocessingQuality

        if HudAnchoring ~= "" then
            P2Settings:SetStringValueFromName(FName("HUDAnchoring"), HudAnchoring)
        end

        -- Exactly one apply after the complete join-time profile copy.
        P2Settings:ApplyHaloUserSettings()
    end)
    if not WriteOk then
        Log("P2SETTINGS GRAPHICS PROFILE SYNC write/apply failed: %s", tostring(WriteErr))
        return false
    end

    local Mismatches = {}
    local VerifyOk, VerifyErr = pcall(function()
        for _, Name in ipairs(P2GraphicsSyncPropertyNames) do
            local V1 = P1Settings:GetPropertyValue(Name)
            local V2 = P2Settings:GetPropertyValue(Name)
            if SafeToString(V1) ~= SafeToString(V2) then
                table.insert(Mismatches, string.format("%s:%s!=%s", Name, SafeToString(V1), SafeToString(V2)))
            end
        end
        if SafeToString(P1Settings.ControllerWarthogDrivingMode) ~= SafeToString(P2Settings.ControllerWarthogDrivingMode) then
            table.insert(Mismatches, "ControllerWarthogDrivingMode")
        end
        if HudAnchoring ~= "" and ReadHudAnchoring(P2Settings) ~= HudAnchoring then
            table.insert(Mismatches, "HUDAnchoring")
        end
    end)

    if not VerifyOk then
        Log("P2SETTINGS GRAPHICS PROFILE SYNC applied but readback failed: %s", tostring(VerifyErr))
        return true
    end

    if #Mismatches == 0 then
        Log("P2SETTINGS GRAPHICS PROFILE SYNC VERIFIED reason=%s properties=%d HUDAnchoring=%s Warthog=%s Upscaler=%s QualityPreset=%s",
            tostring(Reason or "join"), #P2GraphicsSyncPropertyNames,
            tostring(ReadHudAnchoring(P2Settings)), tostring(P2Settings.ControllerWarthogDrivingMode),
            tostring(P2Settings.Upscaler), tostring(P2Settings.QualityPreset))
    else
        Log("P2SETTINGS GRAPHICS PROFILE SYNC MISMATCH reason=%s count=%d details=%s",
            tostring(Reason or "join"), #Mismatches, table.concat(Mismatches, " | "))
    end
    return true
end

function MakeGameplayTag(TagName)
    return { TagName = FName(TagName) }
end

function FindMasterChiefSelection(Settings)
    if not IsValidObject(Settings) then return nil, "" end
    local Values = nil
    pcall(function() Values = Settings.ObjectCustomizationNames end)
    for _, Candidate in ipairs(ArrayValues(Values)) do
        local Tag = Unwrap(Candidate)
        local Name = GetTagName(Tag)
        if string.find(string.lower(Name or ""), "blam.customization.masterchief.", 1, true) then
            return Tag, Name
        end
    end
    return nil, ""
end

function SyncCatalogIndex(PlayerIndex, Settings)
    if IndexInitialized[PlayerIndex] or ArmorCatalog == nil then return end
    local _, CurrentName = FindMasterChiefSelection(Settings)
    if CurrentName ~= "" then
        for I, Entry in ipairs(ArmorCatalog) do
            if string.lower(Entry.Skin or "") == string.lower(CurrentName) then
                CatalogIndex[PlayerIndex] = I
                break
            end
        end
    end
    IndexInitialized[PlayerIndex] = true
    Log("ARMOR P%d initial selection=%s index=%d",
        PlayerIndex, CurrentName ~= "" and CurrentName or "unknown", CatalogIndex[PlayerIndex])
end

function ApplyDirect(PlayerIndex, Entry)
    local Settings, SettingsInfo = GetUserSettings(PlayerIndex)
    if not IsValidObject(Settings) then return false, SettingsInfo end

    SyncCatalogIndex(PlayerIndex, Settings)

    local NewTag = MakeGameplayTag(Entry.Skin)
    local CurrentTag = nil
    local CurrentName = ""
    local MatchOk, MatchErr = pcall(function()
        CurrentTag = Settings:FindCustomizationMatching(NewTag)
    end)
    CurrentTag = Unwrap(CurrentTag)
    if CurrentTag ~= nil then CurrentName = GetTagName(CurrentTag) end

    -- FindCustomizationMatching is the game's intended way to locate the old
    -- selection in ObjectCustomizationNames. Fall back to the explicit Master
    -- Chief entry only if this build returns an empty tag.
    if not MatchOk or CurrentTag == nil or CurrentName == "" or CurrentName == "None" then
        CurrentTag, CurrentName = FindMasterChiefSelection(Settings)
    end
    if CurrentTag == nil then
        -- Local P2 commonly starts with no Master Chief entry in its own settings
        -- array. AddOrReplaceCustomization is intentionally also the add API: use
        -- the new tag as the absent lookup key so the selection is appended.
        CurrentTag = NewTag
        CurrentName = "<none; add new local-user selection>"
    end

    local ApplyOk, ApplyErr = pcall(function()
        Settings:AddOrReplaceCustomization(CurrentTag, NewTag)
    end)
    if not ApplyOk then return false, tostring(ApplyErr) end

    -- Do not call BlamGameUserSettingsUpdated directly. UE4SS 3.0.1 exposes the
    -- inherited method as a TrivialObject and throws after the successful write.
    -- AddOrReplaceCustomization already propagates the visual change in-game.
    local _, AfterName = FindMasterChiefSelection(Settings)
    Log("ARMOR DIRECT P%d %s | %s -> %s | stored=%s | notify=implicit",
        PlayerIndex, SettingsInfo, CurrentName, Entry.Skin,
        AfterName ~= "" and AfterName or "unreadable")
    return true, AfterName
end

-- Resolve controllers only at lifecycle boundaries. P1 comes from UEHelpers'
-- current-world controller. P2 is selected only from the same PersistentLevel as P1,
-- avoiding stale frontend/campaign controllers that remain valid after travel.
function RefreshCachedControllers()
    -- Never use UEHelpers.GetPlayerController() as the actual P1 reference.
    -- In local co-op UEHelpers can resolve to ControllerId 1, which made both browser
    -- slots read the P2 pad. Use it only as a current-world anchor, then resolve BOTH
    -- players explicitly by LocalPlayer.ControllerId from the same PersistentLevel.
    local Anchor = nil
    pcall(function() Anchor = UEHelpers.GetPlayerController() end)
    local LevelPrefix = ""
    if IsValidObject(Anchor) then
        local AnchorName = SafeFullName(Anchor)
        LevelPrefix = string.match(AnchorName or "", "^(.-:PersistentLevel)") or ""
    end

    local All = nil
    pcall(function() All = FindAllOf("PlayerController") end)
    if not All then return false end

    local FoundP1 = nil
    local FoundP2 = nil
    for _, Candidate in ipairs(All) do
        if IsValidObject(Candidate) then
            local Id = nil
            pcall(function()
                if IsValidObject(Candidate.Player) then
                    Id = Candidate.Player.ControllerId
                end
            end)
            if Id == 0 or Id == 1 then
                local CandidateName = SafeFullName(Candidate)
                local SameLevel = (LevelPrefix == "") or string.find(CandidateName or "", LevelPrefix, 1, true)
                if SameLevel then
                    if Id == 0 and not FoundP1 then FoundP1 = Candidate end
                    if Id == 1 and not FoundP2 then FoundP2 = Candidate end
                end
            end
        end
    end

    if IsValidObject(FoundP1) then PlayerControllerTable[1] = FoundP1 end
    if PlayerTwoExpected then
        PlayerControllerTable[2] = IsValidObject(FoundP2) and FoundP2 or nil
    else
        PlayerControllerTable[2] = nil
    end

    if IsValidObject(PlayerControllerTable[1]) then
        local P1Id, P2Id = "?", "-"
        pcall(function() P1Id = PlayerControllerTable[1].Player.ControllerId end)
        if IsValidObject(PlayerControllerTable[2]) then
            pcall(function() P2Id = PlayerControllerTable[2].Player.ControllerId end)
        end
        Log("ARMOR controller map: P1 ControllerId=%s P2 ControllerId=%s", tostring(P1Id), tostring(P2Id))
        return true
    end
    return false
end

local function GetPlayer(PlayerIndex)
    -- HOT LOOP RULE: never scan GUObjectArray here.
    local P = PlayerControllerTable[PlayerIndex]
    if IsValidObject(P) then return P end
    return nil
end

local function ScreenMessage(PlayerIndex, Controller, Message)
    local Shown = false
    if IsValidObject(Controller) then
        Shown = pcall(function() Controller:ClientMessage(Message, FName("Event"), 2.0) end)
    end
    if not Shown then
        local P1 = PlayerControllerTable[1]
        if IsValidObject(P1) then
            pcall(function() P1:ClientMessage(Message, FName("Event"), 2.0) end)
        end
    end
end

-- Perspective runtime functions live here intentionally: GetPlayer and ScreenMessage
-- are local functions above, so defining the toggle earlier would bind those names
-- as globals and fail at runtime. Keep these definitions here so Lua binds the local functions correctly.
function SetPerspectiveNativeMode(CoOp, Reason)
    if not PerspectiveNativeLoaded then return false end
    local Wanted = CoOp == true
    if PerspectiveNativeCoopMode == Wanted then return true end
    local Fn = Wanted and PerspectiveNativeModeCoop or PerspectiveNativeModeSolo
    if type(Fn) ~= "function" then return false end
    local Ok, Err = pcall(Fn)
    if not Ok then
        Log("PERSPECTIVE native mode switch failed (%s): %s", tostring(Reason or "mode"), tostring(Err))
        return false
    end
    PerspectiveNativeCoopMode = Wanted
    Log("PERSPECTIVE native mode -> %s (%s)", Wanted and "LOCAL COOP independent P1/P2 routing" or "SOLO", tostring(Reason or "mode"))
    return true
end

function SetPerspectiveContextShift(Enabled, Reason)
    local Wanted = Enabled == true
    if PerspectiveContextShiftActive == Wanted then return true end
    if not PerspectiveContextShiftLoaded then
        if Wanted then
            Log("PERSPECTIVE network-client context remap unavailable: bridge not loaded")
        end
        return not Wanted
    end

    local Fn = Wanted and PerspectiveContextShiftEnable or PerspectiveContextShiftDisable
    if type(Fn) ~= "function" then return false end
    local Ok, Err = pcall(Fn)
    if not Ok then
        Log("PERSPECTIVE context-shift switch failed (%s): %s", tostring(Reason or "topology"), tostring(Err))
        return false
    end
    PerspectiveContextShiftActive = Wanted
    Log("PERSPECTIVE native context route -> %s (%s)",
        Wanted and "NETWORK CLIENT native contexts 1/2 active (context 0 vanilla)" or "NORMAL local contexts 0=P1 1=P2",
        tostring(Reason or "topology"))
    return true
end

function PerspectiveReadRole(Player)
    return Unwrap(Player.Role)
end

function PerspectiveShouldUseNetworkClientShift(Player, HasLocalP2)
    if HasLocalP2 ~= true or not IsValidObject(Player) then return false end

    -- Do not make Perspective routing wait for the Limited Respawns authority
    -- gate. On a network client the local P1 PlayerController is an
    -- AutonomousProxy (ROLE=2) as soon as the campaign controller exists, while
    -- the HUD/authority gate can settle several seconds later. That delay left a
    -- window where controller Perspective toggles targeted contexts 0/1 even
    -- though hybrid local+network play uses the separate context 1/2 route.
    if LivesNetworkClientBlocked == true then return true end

    -- Preserve the proven role check exactly, but avoid allocating a new protected
    -- call closure for it on every P1 ReceiveTick.
    local RoleOk, RoleValue = pcall(PerspectiveReadRole, Player)
    if not RoleOk then return false end
    local RoleNumber = tonumber(RoleValue)
    if RoleNumber == 2 then return true end
    local RoleText = string.lower(tostring(RoleValue or ""))
    return string.find(RoleText, "autonomousproxy", 1, true) ~= nil or
           string.find(RoleText, "autonomous proxy", 1, true) ~= nil
end

function TogglePerspectivePlayer(PlayerIndex, Source)
    if not PerspectiveNativeLoaded then
        Log("PERSPECTIVE P%d %s ignored: native companion unavailable", PlayerIndex, tostring(Source or "input"))
        return false
    end
    local Player = GetPlayer(PlayerIndex)
    if not MissionReady or not IsValidObject(Player) then
        Log("PERSPECTIVE P%d %s ignored: campaign controller not ready", PlayerIndex, tostring(Source or "input"))
        return false
    end

    local P2 = GetPlayer(2)
    local HasP2 = IsValidObject(P2)
    if PlayerIndex == 2 and not HasP2 then
        Log("PERSPECTIVE P2 %s ignored: no local P2", tostring(Source or "input"))
        return false
    end

    SetPerspectiveNativeMode(HasP2, string.format("P%d toggle", PlayerIndex))

    -- Network-client local split uses native contexts 1/2 instead of host/local
    -- contexts 0/1. The two PC runtimes expose those local contexts in different
    -- camera order: Steam keeps 1=P1, 2=P2, while WinGDK exposes 1=P2, 2=P1.
    -- Keep the previously validated native DLL byte-for-byte unchanged and
    -- compensate only the WinGDK logical player -> native state slot here.
    local ClientLocalP2 = PerspectiveShouldUseNetworkClientShift(GetPlayer(1), HasP2)
    SetPerspectiveContextShift(ClientLocalP2, string.format("P%d toggle topology", PlayerIndex))

    local NativePlayerIndex = PlayerIndex
    if ClientLocalP2 and UseGamePassPlatformJoin then
        NativePlayerIndex = PlayerIndex == 1 and 2 or 1
        Log("PERSPECTIVE WinGDK client slot remap: logical P%d -> native P%d",
            PlayerIndex, NativePlayerIndex)
    end
    local Fn = NativePlayerIndex == 2 and PerspectiveNativeToggleP2 or PerspectiveNativeToggleP1
    if type(Fn) ~= "function" then return false end

    local RequestedThird = not PerspectiveThirdPerson[PlayerIndex]
    local Ok, Err = pcall(Fn)
    if not Ok then
        Log("PERSPECTIVE P%d native toggle failed: %s", PlayerIndex, tostring(Err))
        return false
    end

    PerspectiveThirdPerson[PlayerIndex] = RequestedThird
    local Label = RequestedThird and "THIRD PERSON" or "FIRST PERSON"
    if HasP2 then
        Log("PERSPECTIVE P%d -> %s via %s; independent local-coop view",
            PlayerIndex, Label, tostring(Source or "input"))
        ScreenMessage(PlayerIndex, Player, string.format("P%d %s", PlayerIndex, Label))
    else
        Log("PERSPECTIVE P1 -> %s via %s; native call completed", Label, tostring(Source or "input"))
        ScreenMessage(1, Player, string.format("P1 %s", Label))
    end
    if not RequestedThird and type(ArmorSkinSchedulePerspectiveFirstPersonRebind) == "function" then
        ArmorSkinSchedulePerspectiveFirstPersonRebind(PlayerIndex,
            string.format("perspective P%d -> first person", PlayerIndex))
    elseif RequestedThird and ArmorSkinPerspectiveRebindToken ~= nil then
        ArmorSkinPerspectiveRebindToken[PlayerIndex] = (tonumber(ArmorSkinPerspectiveRebindToken[PlayerIndex]) or 0) + 1
    end
    return true
end

function TogglePerspectiveGlobal(Source)
    if not PerspectiveNativeLoaded or type(PerspectiveNativeToggleGlobal) ~= "function" then return false end
    local P1 = GetPlayer(1)
    if not MissionReady or not IsValidObject(P1) then return false end
    local P2 = GetPlayer(2)
    local HasP2 = IsValidObject(P2)
    SetPerspectiveNativeMode(HasP2, "global control")
    SetPerspectiveContextShift(PerspectiveShouldUseNetworkClientShift(P1, HasP2), "global control topology")
    local RequestedThird = not PerspectiveThirdPerson[1]
    local Ok, Err = pcall(PerspectiveNativeToggleGlobal)
    if not Ok then
        Log("PERSPECTIVE global native toggle failed: %s", tostring(Err))
        return false
    end
    PerspectiveThirdPerson[1] = RequestedThird
    if HasP2 then PerspectiveThirdPerson[2] = RequestedThird end
    local Label = RequestedThird and "THIRD PERSON" or "FIRST PERSON"
    if HasP2 then
        Log("PERSPECTIVE GLOBAL -> %s via %s; both local views set together", Label, tostring(Source or "input"))
        ScreenMessage(1, P1, string.format("P1+P2 %s - GLOBAL CONTROL", Label))
        ScreenMessage(2, P2, string.format("P1+P2 %s - GLOBAL CONTROL", Label))
    else
        Log("PERSPECTIVE P1 -> %s via %s", Label, tostring(Source or "input"))
        ScreenMessage(1, P1, string.format("P1 %s", Label))
    end
    return true
end

function ResetPerspectiveNative(Reason)
    SetPerspectiveContextShift(false, tostring(Reason or "reset"))
    PerspectiveThirdPerson[1] = false
    PerspectiveThirdPerson[2] = false
    PerspectiveNativeCoopMode = false
    if PerspectiveNativeLoaded and type(PerspectiveNativeReset) == "function" then
        local Ok, Err = pcall(PerspectiveNativeReset)
        if not Ok then
            Log("PERSPECTIVE native reset failed (%s): %s", tostring(Reason or "reset"), tostring(Err))
            return false
        end
    end
    Log("PERSPECTIVE reset to vanilla state; P1/P2 perspective states cleared: %s", tostring(Reason or "reset"))
    return true
end



-- Vehicle network identity helpers ------------------------------------------------
-- The stock-RPC color sync uses only reflected BlamObjectSynchronizationComponent
-- identifiers. Raw object datums/pointers are local to each machine; the stable
-- GameStateIdentifier is the cross-peer vehicle key; no native memory read is required.
function VehicleNetworkFindBlamObjectIds(Vehicle)
    local Components = {}
    local OkComponents = pcall(function() Components = WarthogGetActorComponents(Vehicle) or {} end)
    if not OkComponents then return nil, nil, nil, "components-read-failed" end

    for Index, Raw in ipairs(Components) do
        local Component = Unwrap(Raw)
        if IsValidObject(Component) then
            local Class = nil
            pcall(function() Class = Unwrap(Component:GetClass()) end)
            local ClassFull = string.lower(tostring(SafeFullName(Class) or SafeToString(Class) or ""))
            if string.find(ClassFull, "blamobjectsynchronizationcomponent", 1, true) ~= nil then
                local ObjectDatum, TagDatum, GameStateId = nil, nil, nil
                local O1 = pcall(function() ObjectDatum = tonumber(Unwrap(Component.BlamObjectIndex)) end)
                local O2 = pcall(function() TagDatum = tonumber(Unwrap(Component.BlamTagDefinitionIndex)) end)
                local O3 = pcall(function() GameStateId = tonumber(Unwrap(Component.BlamObjectGameStateIdentifier)) end)
                if O1 and O2 and O3 and ObjectDatum ~= nil and TagDatum ~= nil and GameStateId ~= nil then
                    return ObjectDatum, TagDatum, GameStateId, string.format("component#%d", Index)
                end
            end
        end
    end
    return nil, nil, nil, "blam-object-sync-not-found"
end

function VehicleNetworkHex32(Value)
    local N = tonumber(Value) or 0
    return string.format("0x%08X", N & 0xFFFFFFFF)
end

function VehicleNetworkIsAuthority(Vehicle)
    local Role = nil
    local Ok = pcall(function() Role = Unwrap(Vehicle.Role) end)
    if not Ok then return false, "role-read-failed" end
    local N = tonumber(Role)
    local Text = string.lower(tostring(SafeToString(Role) or Role or ""))
    if N == 3 or string.find(Text, "authority", 1, true) ~= nil then return true, tostring(Role) end
    return false, tostring(Role)
end

VehicleMessageProtocol = 3
VehicleMessageSequence = VehicleMessageSequence or 0
VehicleMessageClientHookReady = VehicleMessageClientHookReady or false
VehicleMessageClientHookPreId = VehicleMessageClientHookPreId
VehicleMessageClientHookPostId = VehicleMessageClientHookPostId
VehicleMessageRemoteColorIndexByGameStateId = VehicleMessageRemoteColorIndexByGameStateId or {}
VehicleMessageRemoteRepairScheduledByGameStateId = VehicleMessageRemoteRepairScheduledByGameStateId or {}
VehicleMessageRemoteScorpionSettleTokenByGameStateId = VehicleMessageRemoteScorpionSettleTokenByGameStateId or {}
VehicleMessageLastReceivedSequenceByVehicle = VehicleMessageLastReceivedSequenceByVehicle or {}
VehicleMessageServerHookReady = VehicleMessageServerHookReady or false
VehicleMessageServerHookPreId = VehicleMessageServerHookPreId
VehicleMessageServerHookPostId = VehicleMessageServerHookPostId
VehicleMessageHostCapabilitySeen = VehicleMessageHostCapabilitySeen or false
VehicleMessageHostCapabilityAckSent = VehicleMessageHostCapabilityAckSent or false
-- Client uplink must use the exact local PlayerController whose capability ACK
-- was observed by the server. Mixed network + local split-screen can have two
-- local PlayerControllers, and GetPlayer(1) is not necessarily the RPC-owning route.
VehicleMessageUplinkController = VehicleMessageUplinkController
VehicleMessageUplinkControllerName = VehicleMessageUplinkControllerName or ""
VehicleMessageUplinkReady = VehicleMessageUplinkReady or false
VehicleMessageCapabilityAttemptsByController = VehicleMessageCapabilityAttemptsByController or {}
VehicleMessageCapabilityAckByController = VehicleMessageCapabilityAckByController or {}
-- Vehicle capability discovery is lifecycle-driven, never ReceiveTick-driven.
-- The documented network join order has remote P1 connected before campaign starts, so
-- one bounded PlayerController discovery at stable mission start is sufficient. Remote
-- controller objects are then cached for HELLO and color traffic for the life of the world.
VehicleMessageCapabilityControllerByToken = VehicleMessageCapabilityControllerByToken or {}
VehicleMessageCapabilityMissionPrimed = VehicleMessageCapabilityMissionPrimed or false
VehicleMessageUplinkSequence = VehicleMessageUplinkSequence or 0
-- After the one bounded mission-start discovery proves there are no remote
-- PlayerControllers, network callbacks and vehicle-color network work become a
-- one-boolean fast return for the rest of that world. This keeps the proven hooks
-- registered (avoiding host/client handshake races) without doing network work in
-- standalone or local-only co-op.
VehicleMessageOfflineFastPath = VehicleMessageOfflineFastPath or false
-- A listen-server can reach the stable-mission gate before the remote client's
-- PlayerController has finished constructing. Keep discovery event-driven: when
-- a BP_MeteoritePlayerController appears later, validate that exact object and
-- add it to the capability cache without a global PlayerController scan.
VehicleMessageControllerConstructionListenerReady = VehicleMessageControllerConstructionListenerReady or false

-- Network-visible Limited Respawns status is presentation-only on clients. The
-- host remains the sole gameplay authority; clients only mirror the host banner.
LivesNetworkProtocol = LivesNetworkProtocol or 1
LivesRemoteHostSyncSeen = LivesRemoteHostSyncSeen or false
LivesRemoteHostState = LivesRemoteHostState or ""
LivesRemoteHostValue = LivesRemoteHostValue or 0
LivesRemoteHostStateRevision = LivesRemoteHostStateRevision or 0
LivesHostOnlyNoticeToken = LivesHostOnlyNoticeToken or 0
LivesRemoteOffDisplayToken = LivesRemoteOffDisplayToken or 0
LivesRemoteOffVisibleMs = 4000
LivesHostOnlyNoticeVisibleMs = 5500

function VehicleMessageResetCapabilityState(Reason)
    VehicleMessageHostCapabilitySeen = false
    VehicleMessageHostCapabilityAckSent = false
    VehicleMessageUplinkController = nil
    VehicleMessageUplinkControllerName = ""
    VehicleMessageUplinkReady = false
    VehicleMessageCapabilityAttemptsByController = {}
    VehicleMessageCapabilityAckByController = {}
    VehicleMessageCapabilityControllerByToken = {}
    VehicleMessageCapabilityMissionPrimed = false
    VehicleMessageOfflineFastPath = false
    VehicleMessageUplinkSequence = 0
    if Reason ~= nil and tostring(Reason) ~= "" then
        Log("VEHNET v1.9.0 capability state reset reason=%s", tostring(Reason))
    end
end

function LivesNetworkResetRemoteState(Reason)
    LivesRemoteHostSyncSeen = false
    LivesRemoteHostState = ""
    LivesRemoteHostValue = 0
    LivesRemoteHostStateRevision = (tonumber(LivesRemoteHostStateRevision) or 0) + 1
    LivesHostOnlyNoticeToken = (tonumber(LivesHostOnlyNoticeToken) or 0) + 1
    LivesRemoteOffDisplayToken = (tonumber(LivesRemoteOffDisplayToken) or 0) + 1
    if Reason ~= nil and tostring(Reason) ~= "" then
        Log("LIVESNET remote HUD state reset reason=%s", tostring(Reason))
    end
end

function LivesNetworkRemoteBannerText()
    local State = tostring(LivesRemoteHostState or "")
    local Value = math.max(0, math.floor(tonumber(LivesRemoteHostValue) or 0))
    if State == "L" then return string.format("LIVES: %d", Value) end
    if State == "R" then return string.format("REINFORCEMENTS: %d SEC", Value) end
    if State == "G" then return "NO LIVES - RESTARTING" end
    if State == "O" then return "RESPAWN LIMIT: OFF" end
    return "LIMITED RESPAWNS: NETWORK HOST ONLY"
end

-- Client presentation policy: active host states stay visible, but OFF is only
-- a short status acknowledgement. A network client cannot configure the mode,
-- so leaving RESPAWN OFF permanently on-screen adds noise without information.
-- This is presentation-only and uses a single delayed callback; no polling.
function LivesNetworkDisplayRemoteState(Reason)
    local State = tostring(LivesRemoteHostState or "")
    LivesRemoteOffDisplayToken = (tonumber(LivesRemoteOffDisplayToken) or 0) + 1
    local OffToken = LivesRemoteOffDisplayToken
    local RemoteRevision = LivesRemoteHostStateRevision
    local NoticeToken = LivesHostOnlyNoticeToken
    local MissionGeneration = LivesMissionGeneration
    local Displayed = DisplayLivesBanner(LivesNetworkRemoteBannerText()) == true

    if State == "O" then
        ExecuteInGameThreadWithDelay(LivesRemoteOffVisibleMs, function()
            if ModTeardownGuard or not MissionReady or not LivesNetworkClientBlocked then return end
            if OffToken ~= LivesRemoteOffDisplayToken then return end
            if RemoteRevision ~= LivesRemoteHostStateRevision then return end
            if NoticeToken ~= LivesHostOnlyNoticeToken then return end
            if MissionGeneration ~= LivesMissionGeneration then return end
            if LivesRemoteHostSyncSeen and tostring(LivesRemoteHostState or "") == "O" then
                DisplayLivesBanner(" ")
                Log("LIVES network-client OFF notice expired after %.1fs; banner cleared source=%s",
                    LivesRemoteOffVisibleMs / 1000.0, tostring(Reason or "host-state"))
            end
        end)
    end
    return Displayed
end

-- A validated modded host downlink (Lives or vehicle state) is itself proof that
-- this exact owning controller route is usable. If a local lifecycle reset ever
-- drops the ACK/READY flags while the host is still talking to us, recover the
-- route from that event instead of polling or waiting for a new mission.
function VehicleMessageRefreshClientRouteFromHostDownlink(Controller, Source)
    Controller = Unwrap(Controller)
    if not IsValidObject(Controller) then return false end
    local IsLocal = false
    pcall(function() IsLocal = Controller:IsLocalController() == true end)
    if not IsLocal then return false end

    local RouteName = SafeFullName(Controller) or tostring(Controller)
    if MissionReady and tostring(LivesMissionControllerName or "") ~= "" then
        local Prefix = string.match(tostring(LivesMissionControllerName), "^(.-:PersistentLevel)") or ""
        if Prefix ~= "" and string.find(RouteName, Prefix, 1, true) == nil then return false end
    end

    local AlreadyReady = VehicleMessageHostCapabilitySeen == true and
        VehicleMessageUplinkReady == true and
        VehicleMessageUplinkController == Controller and
        tostring(VehicleMessageUplinkControllerName or "") == tostring(RouteName)
    if AlreadyReady then return true end

    VehicleMessageHostCapabilitySeen = true
    VehicleMessageHostCapabilityAckSent = true
    VehicleMessageUplinkController = Controller
    VehicleMessageUplinkControllerName = RouteName
    VehicleMessageUplinkReady = true
    Log("VEHNET v1.9.0 UPLINK route refreshed from host downlink source=%s controller=%s",
        tostring(Source or "modded-host"), tostring(RouteName))
    return true
end

function LivesNetworkHandleMessage(Message, Controller)
    local Proto, State, Value = string.match(tostring(Message or ""), "^HCECELV|(%d+)|([OLRG])|(%d+)$")
    Proto = tonumber(Proto)
    Value = tonumber(Value)
    if Proto ~= LivesNetworkProtocol or Value == nil then
        Log("LIVESNET invalid/incompatible host state ignored message=%s", tostring(Message))
        return
    end
    VehicleMessageRefreshClientRouteFromHostDownlink(Controller, "lives-state")
    LivesRemoteHostSyncSeen = true
    LivesRemoteHostState = State
    LivesRemoteHostValue = Value
    LivesRemoteHostStateRevision = (tonumber(LivesRemoteHostStateRevision) or 0) + 1
    LivesHostOnlyNoticeToken = (tonumber(LivesHostOnlyNoticeToken) or 0) + 1
    local Displayed = false
    if LivesAuthorityResolved and LivesNetworkClientBlocked and MissionReady and DisplayLivesBanner ~= nil then
        Displayed = LivesNetworkDisplayRemoteState("host update") == true
    end
    Log("LIVESNET RX host state=%s value=%d displayed=%s", tostring(State), Value, tostring(Displayed))
end

function VehicleMessageValueToString(Value)
    local Raw = Unwrap(Value)
    if Raw == nil then return "" end
    if type(Raw) == "string" then return Raw end
    local Out = nil
    pcall(function() Out = Raw:ToString() end)
    if type(Out) == "string" then return Out end
    return tostring(Raw)
end

function VehicleMessageFindLocalWarthogByGameStateId(TargetId)
    local Wanted = tonumber(TargetId)
    if Wanted == nil then return nil, nil, nil end
    local Vehicles = nil
    pcall(function() Vehicles = FindAllOf("BP_WarthogVehicleActor_C") end)
    for _, Candidate in ipairs(Vehicles or {}) do
        if IsValidObject(Candidate) and
           not string.find(SafeFullName(Candidate) or "", "Default__", 1, true) then
            local ObjectDatum, TagDatum, GameStateId = VehicleNetworkFindBlamObjectIds(Candidate)
            if tonumber(GameStateId) == Wanted then
                return Candidate, ObjectDatum, TagDatum
            end
        end
    end
    return nil, nil, nil
end

function VehicleMessageFindLocalScorpionByGameStateId(TargetId)
    local Wanted = tonumber(TargetId)
    if Wanted == nil then return nil, nil, nil end
    local Vehicles = nil
    pcall(function() Vehicles = FindAllOf("BP_ScorpionVehicleActor_C") end)
    for _, Candidate in ipairs(Vehicles or {}) do
        if IsValidObject(Candidate) and
           not string.find(SafeFullName(Candidate) or "", "Default__", 1, true) then
            local IsScorpion = true
            if ScorpionIsScorpionActor ~= nil then
                local Ok, Result = pcall(ScorpionIsScorpionActor, Candidate)
                IsScorpion = Ok and Result == true
            end
            if IsScorpion then
                local ObjectDatum, TagDatum, GameStateId = VehicleNetworkFindBlamObjectIds(Candidate)
                if tonumber(GameStateId) == Wanted then
                    return Candidate, ObjectDatum, TagDatum
                end
            end
        end
    end
    return nil, nil, nil
end

function VehicleMessageScheduleRemoteWarthogRepair(GameStateId, Attempt)
    GameStateId = tonumber(GameStateId)
    Attempt = tonumber(Attempt) or 1
    if GameStateId == nil or Attempt > 6 then return end

    local ScheduleKey = tostring(GameStateId)
    if VehicleMessageRemoteRepairScheduledByGameStateId[ScheduleKey] then return end
    VehicleMessageRemoteRepairScheduledByGameStateId[ScheduleKey] = true
    local RuntimeGeneration = WarthogColorRuntimeGeneration
    local DelayMs = 250 + ((Attempt - 1) * 350)

    ExecuteInGameThreadWithDelay(DelayMs, function()
        VehicleMessageRemoteRepairScheduledByGameStateId[ScheduleKey] = nil
        if RuntimeGeneration ~= WarthogColorRuntimeGeneration or not MissionReady then return end

        local ColorIndex = tonumber(VehicleMessageRemoteColorIndexByGameStateId[ScheduleKey])
        if ColorIndex == nil or ColorIndex < 0 or ColorIndex > 18 then return end
        local Vehicle = select(1, VehicleMessageFindLocalWarthogByGameStateId(GameStateId))
        if not IsValidObject(Vehicle) then return end

        local Ok, Applied, Info, Pending = pcall(function()
            local PaintMIDs, MIDRoute = WarthogFindPaintMIDsForVehicle(Vehicle)
            if PaintMIDs == nil or #PaintMIDs == 0 then
                return false, 'no paint MIDs: ' .. tostring(MIDRoute), false
            end
            local Plan = WarthogPaintApplyPlanForVehicle(Vehicle, PaintMIDs)
            if Plan == nil or #Plan == 0 then return false, 'no paint plan', false end
            local IsOriginal = ColorIndex == 0
            local Color = IsOriginal and nil or WarthogCEColors[ColorIndex]
            if not IsOriginal and Color == nil then return false, 'missing color definition', false end
            local ApplyOk, ApplyInfo = WarthogApplyPaintPlan(Plan, Color, IsOriginal)
            local CacheEntry = WarthogPaintMIDCacheByVehicle[WarthogVehicleToken(Vehicle)]
            return ApplyOk == true, tostring(ApplyInfo), type(CacheEntry) == 'table' and CacheEntry.AccessoryPending == true
        end)
        if not Ok then
            Log('VEHNET v1.9.0 RX REPAIR failed safely gameStateId=%d attempt=%d error=%s', GameStateId, Attempt, tostring(Applied))
            return
        end
        if Applied then
            Log('VEHNET v1.9.0 RX REPAIR applied gameStateId=%d colorIndex=%d attempt=%d pending=%s info=%s',
                GameStateId, ColorIndex, Attempt, tostring(Pending == true), tostring(Info))
        else
            Log('VEHNET v1.9.0 RX REPAIR no-apply gameStateId=%d colorIndex=%d attempt=%d pending=%s info=%s',
                GameStateId, ColorIndex, Attempt, tostring(Pending == true), tostring(Info))
        end
        if Pending == true then VehicleMessageScheduleRemoteWarthogRepair(GameStateId, Attempt + 1) end
    end)
end

function VehicleMessageApplyRemoteWarthogColor(Vehicle, GameStateId, ColorIndex)
    Vehicle = Unwrap(Vehicle)
    GameStateId = tonumber(GameStateId)
    ColorIndex = tonumber(ColorIndex)
    if not IsValidObject(Vehicle) or GameStateId == nil or ColorIndex == nil or ColorIndex < 0 or ColorIndex > 18 then
        return false, 'invalid remote paint request'
    end

    local Ok, Applied, Info, Pending = pcall(function()
        local PaintMIDs, MIDRoute = WarthogFindPaintMIDsForVehicle(Vehicle)
        if PaintMIDs == nil or #PaintMIDs == 0 then
            return false, 'no paint MIDs: ' .. tostring(MIDRoute), false
        end
        local Plan = WarthogPaintApplyPlanForVehicle(Vehicle, PaintMIDs)
        if Plan == nil or #Plan == 0 then return false, 'no paint plan', false end
        local IsOriginal = ColorIndex == 0
        local Color = IsOriginal and nil or WarthogCEColors[ColorIndex]
        if not IsOriginal and Color == nil then return false, 'missing color definition', false end
        local ApplyOk, ApplyInfo = WarthogApplyPaintPlan(Plan, Color, IsOriginal)
        if ApplyOk == true then
            WarthogColorIndexByVehicle[WarthogVehicleToken(Vehicle)] = ColorIndex
            VehicleMessageRemoteColorIndexByGameStateId[tostring(GameStateId)] = ColorIndex
        end
        local CacheEntry = WarthogPaintMIDCacheByVehicle[WarthogVehicleToken(Vehicle)]
        return ApplyOk == true, tostring(ApplyInfo), type(CacheEntry) == 'table' and CacheEntry.AccessoryPending == true
    end)
    if not Ok then return false, 'remote paint exception: ' .. tostring(Applied) end
    if Applied and Pending == true then VehicleMessageScheduleRemoteWarthogRepair(GameStateId, 1) end
    return Applied == true, tostring(Info)
end

function VehicleMessageApplyRemoteScorpionColor(Vehicle, GameStateId, ColorIndex, SkipSettle)
    Vehicle = Unwrap(Vehicle)
    GameStateId = tonumber(GameStateId)
    ColorIndex = tonumber(ColorIndex)
    if not IsValidObject(Vehicle) or GameStateId == nil or ColorIndex == nil or ColorIndex < 0 or ColorIndex > 18 then
        return false, 'invalid remote Scorpion paint request'
    end

    local Ok, Applied, Info = pcall(function()
        local Plan = ScorpionDiscoverPaintPlan(Vehicle)
        if type(Plan) ~= 'table' or #Plan == 0 then return false, 'no Scorpion paint plan' end
        local IsOriginal = ColorIndex == 0
        local Color = IsOriginal and nil or ScorpionCEColors[ColorIndex]
        if not IsOriginal and Color == nil then return false, 'missing color definition' end
        local ApplyOk, AppliedMIDs, Failures = ScorpionApplyPaintPlan(Plan, Color, IsOriginal)
        if ApplyOk == true then
            local VehicleKey = ScorpionVehicleToken(Vehicle)
            ScorpionColorIndexByVehicle[VehicleKey] = ColorIndex
            if tonumber(ScorpionTurretRepairReadyByVehicle[VehicleKey]) ~= tonumber(ScorpionColorRuntimeGeneration) then
                ScorpionScheduleTurretRepair(0, VehicleKey, 1)
            end
        end
        return ApplyOk == true, string.format('plan=%d mids=%d failures=%d', #Plan, tonumber(AppliedMIDs) or 0, tonumber(Failures) or 0)
    end)
    if not Ok then return false, 'remote Scorpion paint exception: ' .. tostring(Applied) end
    if Applied == true and SkipSettle ~= true then VehicleMessageScheduleRemoteScorpionSettle(Vehicle, GameStateId, ColorIndex) end
    return Applied == true, tostring(Info)
end

-- Remote Scorpion paint can be overwritten shortly after a replicated vehicle or
-- turret material rebuild. A successful RX therefore gets one coalesced settle pass
-- after the burst. Newer RX colors invalidate older callbacks; local color input also
-- cancels a pending remote settle. This is event-driven and never polls ReceiveTick.
function VehicleMessageCancelRemoteScorpionSettle(GameStateId)
    local Key = tostring(tonumber(GameStateId) or GameStateId or "")
    if Key == "" then return end
    VehicleMessageRemoteScorpionSettleTokenByGameStateId[Key] =
        (tonumber(VehicleMessageRemoteScorpionSettleTokenByGameStateId[Key]) or 0) + 1
end

function VehicleMessageScheduleRemoteScorpionSettle(Vehicle, GameStateId, ColorIndex)
    Vehicle = Unwrap(Vehicle)
    GameStateId = tonumber(GameStateId)
    ColorIndex = tonumber(ColorIndex)
    if not IsValidObject(Vehicle) or GameStateId == nil or ColorIndex == nil then return end

    local Key = tostring(GameStateId)
    local Token = (tonumber(VehicleMessageRemoteScorpionSettleTokenByGameStateId[Key]) or 0) + 1
    VehicleMessageRemoteScorpionSettleTokenByGameStateId[Key] = Token
    local WarthogGeneration = WarthogColorRuntimeGeneration
    local ScorpionGeneration = ScorpionColorRuntimeGeneration

    ExecuteInGameThreadWithDelay(650, function()
        if VehicleMessageRemoteScorpionSettleTokenByGameStateId[Key] ~= Token then return end
        if WarthogGeneration ~= WarthogColorRuntimeGeneration or
           ScorpionGeneration ~= ScorpionColorRuntimeGeneration or
           ModTeardownGuard or not MissionReady then return end

        local CurrentVehicle = Vehicle
        if not IsValidObject(CurrentVehicle) then
            CurrentVehicle = select(1, VehicleMessageFindLocalScorpionByGameStateId(GameStateId))
        end
        if not IsValidObject(CurrentVehicle) then return end
        local _, _, CurrentId = VehicleNetworkFindBlamObjectIds(CurrentVehicle)
        if tonumber(CurrentId) ~= GameStateId then return end

        -- Force one fresh plan lookup so a valid-but-detached MID from the initial
        -- replication window cannot make the immediate apply a false visual success.
        local VehicleKey = ScorpionVehicleToken(CurrentVehicle)
        ScorpionPaintPlanCacheByVehicle[VehicleKey] = nil
        local Applied, Info = VehicleMessageApplyRemoteScorpionColor(CurrentVehicle, GameStateId, ColorIndex, true)
        Log("VEHNET v1.9.0 RX SCORPION SETTLE gameStateId=%d colorIndex=%d applied=%s info=%s",
            GameStateId, ColorIndex, tostring(Applied == true), tostring(Info))
    end)
end

function VehicleMessageKindName(KindCode)
    if KindCode == 'W' then return 'Warthog' end
    if KindCode == 'S' then return 'Scorpion' end
    return 'Unknown'
end

function VehicleMessageFindLocalVehicleByGameStateId(KindCode, GameStateId)
    if KindCode == 'W' then return VehicleMessageFindLocalWarthogByGameStateId(GameStateId) end
    if KindCode == 'S' then return VehicleMessageFindLocalScorpionByGameStateId(GameStateId) end
    return nil, nil, nil
end

function VehicleMessageApplyRemoteVehicleColor(KindCode, Vehicle, GameStateId, ColorIndex)
    if KindCode == 'W' then return VehicleMessageApplyRemoteWarthogColor(Vehicle, GameStateId, ColorIndex) end
    if KindCode == 'S' then return VehicleMessageApplyRemoteScorpionColor(Vehicle, GameStateId, ColorIndex) end
    return false, 'unsupported vehicle kind'
end

function VehicleMessageHandleClientMessage(Context, StringParam, TypeParam, LifeParam)
    local Message = VehicleMessageValueToString(StringParam)
    local IsColor = string.sub(Message, 1, 8) == "HCECEVC|"
    local IsCapability = string.sub(Message, 1, 9) == "HCECECAP|"
    local IsLives = string.sub(Message, 1, 8) == "HCECELV|"
    -- v1.11.0 native Classic12 cleanup: armor customization now uses cooked
    -- native rows and Halo's ordinary replication. The retired HCECEA* custom
    -- armor transport is deliberately not recognized here.
    if not IsColor and not IsCapability and not IsLives then return end

    local Controller = Unwrap(Context)
    local IsLocal = false
    if IsValidObject(Controller) then
        pcall(function() IsLocal = Controller:IsLocalController() == true end)
    end

    -- The same UFunction hook also observes the server-side RPC dispatch. Only
    -- an owning/local controller proves that this process actually RECEIVED it.
    if not IsLocal then
        Log("VEHNET v1.9.0 RPC DISPATCH observed on non-local controller; waiting for owning client receive message=%s", Message)
        return
    end

    if IsLives then
        LivesNetworkHandleMessage(Message, Controller)
        return
    end

    if IsCapability then
        local Proto, Command = string.match(Message, "^HCECECAP|(%d+)|([A-Z]+)$")
        Proto = tonumber(Proto)
        if Proto ~= VehicleMessageProtocol or (Command ~= "HELLO" and Command ~= "READY") then
            Log("VEHNET v1.9.0 CAP RX invalid/incompatible message ignored: %s", Message)
            return
        end
        VehicleMessageHostCapabilitySeen = true

        if Command == "READY" then
            -- End-to-end proof: READY can only be sent by the host after this exact
            -- remote controller's ACK arrived through ServerExecRPC. Cache the local
            -- controller that receives READY and use only it for future uplinks.
            VehicleMessageUplinkController = Controller
            VehicleMessageUplinkControllerName = SafeFullName(Controller) or tostring(Controller)
            VehicleMessageUplinkReady = true
            VehicleMessageHostCapabilityAckSent = true
            Log("VEHNET v1.9.0 CAP RX READY protocol=%d uplinkRouteProven=true controller=%s",
                Proto, tostring(VehicleMessageUplinkControllerName))
            return
        end

        Log("VEHNET v1.9.0 CAP RX HELLO protocol=%d hostModSeen=true controller=%s",
            Proto, SafeFullName(Controller))
        if IsValidObject(Controller) then
            local RouteName = SafeFullName(Controller) or tostring(Controller)
            -- RestartLevel resets the host-side capability table, but the owning
            -- client controller can survive that restart with its old READY cache.
            -- A fresh HELLO arriving on the exact already-proven route therefore
            -- means the host has re-armed and needs a new ACK. Re-ACK only that
            -- exact route; alternate local split controllers remain gated exactly
            -- as before. This is bounded by the host's HELLO retries, not polling.
            local ProvenRouteHello = VehicleMessageUplinkReady == true and
                tostring(VehicleMessageUplinkControllerName or "") == tostring(RouteName)
            local ShouldAckHello = (not VehicleMessageHostCapabilityAckSent) or ProvenRouteHello
            if ShouldAckHello then
                if ProvenRouteHello then
                    VehicleMessageUplinkReady = false
                    Log("VEHNET v1.9.0 CAP host rearm HELLO on proven route; re-ACK controller=%s",
                        tostring(RouteName))
                end
                local Ok, Err = pcall(function()
                    Controller:ServerExecRPC(string.format("HCECECAP|%d|ACK", VehicleMessageProtocol))
                end)
                if Ok then
                    -- Provisional route only. Color uplink remains blocked until READY
                    -- returns from the host and proves that this RPC actually crossed.
                    VehicleMessageHostCapabilityAckSent = true
                    VehicleMessageUplinkController = Controller
                    VehicleMessageUplinkControllerName = RouteName
                    VehicleMessageUplinkReady = false
                    Log("VEHNET v1.9.0 CAP TX ACK protocol=%d controller=%s transport=stock-ServerExecRPC awaiting=READY",
                        VehicleMessageProtocol, tostring(RouteName))

                    -- A local reflected RPC call can succeed even if it never reaches the
                    -- host. If READY does not come back, release the provisional lock so a
                    -- later bounded HELLO retry may test another local controller route.
                    local AckGeneration = WarthogColorRuntimeGeneration
                    ExecuteInGameThreadWithDelay(900, function()
                        if AckGeneration ~= WarthogColorRuntimeGeneration or VehicleMessageUplinkReady == true then return end
                        if tostring(VehicleMessageUplinkControllerName or "") ~= tostring(RouteName) then return end
                        VehicleMessageHostCapabilityAckSent = false
                        VehicleMessageUplinkController = nil
                        VehicleMessageUplinkControllerName = ""
                        Log("VEHNET v1.9.0 CAP ACK route timeout controller=%s action=allow-next-bounded-HELLO", tostring(RouteName))
                    end)
                else
                    Log("VEHNET v1.9.0 CAP TX ACK failed safely error=%s", tostring(Err))
                end
            end
        end
        return
    end

    local Proto, Seq, KindCode, GameStateId, ColorIndex =
        string.match(Message, "^HCECEVC|(%d+)|(%d+)|([A-Z]+)|(%d+)|(%d+)$")
    if Proto == nil then
        Log("VEHNET v1.9.0 RX malformed HCECE message ignored: %s", Message)
        return
    end
    Proto = tonumber(Proto)
    Seq = tonumber(Seq)
    GameStateId = tonumber(GameStateId)
    ColorIndex = tonumber(ColorIndex)
    if Proto ~= VehicleMessageProtocol then
        Log("VEHNET v1.9.0 RX incompatible protocol=%s expected=%d ignored", tostring(Proto), VehicleMessageProtocol)
        return
    end
    if (KindCode ~= "W" and KindCode ~= "S") or GameStateId == nil or ColorIndex == nil or ColorIndex < 0 or ColorIndex > 18 then
        Log("VEHNET v1.9.0 RX invalid payload ignored kind=%s gameStateId=%s colorIndex=%s",
            tostring(KindCode), tostring(GameStateId), tostring(ColorIndex))
        return
    end

    VehicleMessageRefreshClientRouteFromHostDownlink(Controller, "vehicle-color")
    local KindName = VehicleMessageKindName(KindCode)
    local SequenceKey = tostring(KindCode) .. ":" .. tostring(GameStateId)
    local LastSeq = tonumber(VehicleMessageLastReceivedSequenceByVehicle[SequenceKey])
    if Seq ~= nil and LastSeq ~= nil and Seq <= LastSeq then
        Log("VEHNET v1.9.0 RX duplicate/stale ignored protocol=%d seq=%d lastSeq=%d kind=%s gameStateId=%d",
            Proto, Seq, LastSeq, KindName, GameStateId)
        return
    end

    local Vehicle, ObjectDatum, TagDatum = VehicleMessageFindLocalVehicleByGameStateId(KindCode, GameStateId)
    if IsValidObject(Vehicle) then
        local Applied, ApplyInfo = VehicleMessageApplyRemoteVehicleColor(KindCode, Vehicle, GameStateId, ColorIndex)
        if Applied then
            if Seq ~= nil then VehicleMessageLastReceivedSequenceByVehicle[SequenceKey] = Seq end
            local ColorName = ColorIndex == 0 and "ORIGINAL" or tostring((WarthogCEColors[ColorIndex] or {}).Name or ColorIndex)
            Log("VEHNET v1.9.0 RX PAINT APPLIED protocol=%d seq=%d kind=%s gameStateId=%d colorIndex=%d color=%s actor=%s objectDatum=%s tagDatum=%s info=%s",
                Proto, Seq or -1, KindName, GameStateId, ColorIndex, ColorName, SafeFullName(Vehicle),
                VehicleNetworkHex32((tonumber(ObjectDatum) or 0) & 0xFFFFFFFF),
                VehicleNetworkHex32((tonumber(TagDatum) or 0) & 0xFFFFFFFF), tostring(ApplyInfo))
        else
            Log("VEHNET v1.9.0 RX PAINT FAILED-SAFE protocol=%d seq=%d kind=%s gameStateId=%d colorIndex=%d actor=%s action=stop-no-retry info=%s",
                Proto, Seq or -1, KindName, GameStateId, ColorIndex, SafeFullName(Vehicle), tostring(ApplyInfo))
        end
    else
        Log("VEHNET v1.9.0 RX NO-MATCH protocol=%d seq=%d kind=%s gameStateId=%d colorIndex=%d action=ignored-no-paint",
            Proto, Seq or -1, KindName, GameStateId, ColorIndex)
    end
end

function InstallVehicleMessageClientHook()
    if VehicleMessageClientHookReady then return true end
    local Ok, PreId, PostId = pcall(function()
        return RegisterHook("/Script/Engine.PlayerController:ClientMessage",
            function(Context, StringParam, TypeParam, LifeParam)
                if VehicleMessageOfflineFastPath then return end
                local HookOk, HookErr = pcall(VehicleMessageHandleClientMessage,
                    Context, StringParam, TypeParam, LifeParam)
                if not HookOk then
                    Log("VEHNET v1.9.0 ClientMessage hook callback failed safely: %s", tostring(HookErr))
                end
            end,
            function(Context, StringParam, TypeParam, LifeParam) end)
    end)
    if not Ok then
        Log("VEHNET v1.9.0 ClientMessage hook unavailable: %s", tostring(PreId))
        return false
    end
    VehicleMessageClientHookPreId = PreId
    VehicleMessageClientHookPostId = PostId
    VehicleMessageClientHookReady = true
    Log("VEHNET v1.9.0 ClientMessage receive hook ready; stock Client,Reliable host-downlink + capability HELLO; validated Warthog/Scorpion payloads apply existing local paint paths")
    return true
end

function VehicleMessageHandleServerExecRPC(Context, StringParam)
    local Message = VehicleMessageValueToString(StringParam)
    local IsCapability = string.sub(Message, 1, 9) == "HCECECAP|"
    local IsUplink = string.sub(Message, 1, 8) == "HCECEUP|"
    local IsIdentityNameUplink = string.sub(Message, 1, 8) == "HCECENM|"
    -- v1.11.0 native Classic12 cleanup: HCECEAC/AU/AR/PV belonged to the
    -- abandoned custom armor-sync transport and are no longer dispatched.
    if not IsCapability and not IsUplink and not IsIdentityNameUplink then return end

    local Controller = Unwrap(Context)
    local IsLocal = false
    if IsValidObject(Controller) then
        pcall(function() IsLocal = Controller:IsLocalController() == true end)
    end

    -- A client calling ServerExecRPC also hits this reflected function locally
    -- before the RPC is serialized. Only the non-local controller copy on the
    -- listen server proves that the message crossed the network.
    if IsLocal then
        Log("VEHNET v1.9.0 UPLINK local dispatch observed; waiting for server receive message=%s", Message)
        return
    end
    local ControllerToken = SafeFullName(Controller) or tostring(Controller)

    -- RC3_54: P2 identity is useful in the fireteam frontend before the mission
    -- authority/capability state machine exists. A client-side reflected call was
    -- already rejected above by IsLocal, so this non-local copy is the server-side
    -- RPC. Keep this early exception narrow: only the validated P2-name payload is
    -- allowed before the normal mission authority gate.
    if IsIdentityNameUplink then
        if IdentityNetworkHandleNameUplink ~= nil then
            IdentityNetworkHandleNameUplink(Message, Controller, ControllerToken)
        end
        return
    end

    if not LivesAuthorityResolved or not LivesAuthorityAllowed then
        Log("VEHNET v1.9.0 UPLINK ignored on non-authority process message=%s", Message)
        return
    end
    if IsCapability then
        local Proto, Command = string.match(Message, "^HCECECAP|(%d+)|([A-Z]+)$")
        Proto = tonumber(Proto)
        if Proto == VehicleMessageProtocol and Command == "ACK" then
            VehicleMessageCapabilityAckByController[ControllerToken] = true
            Log("VEHNET v1.9.0 CAP RX ACK protocol=%d client=%s moddedPeer=true", Proto, ControllerToken)

            -- Send a confirmation back to the exact remote controller that delivered
            -- ACK. The client will not send color uplinks until this READY returns,
            -- which turns the capability handshake into end-to-end route proof.
            local ReadyMessage = string.format("HCECECAP|%d|READY", VehicleMessageProtocol)
            local ReadyOk, ReadyErr = pcall(function()
                Controller:ClientMessage(ReadyMessage, FName("Event"), 0.10)
            end)
            if ReadyOk then
                Log("VEHNET v1.9.0 CAP TX READY protocol=%d target=%s transport=stock-ClientMessage",
                    VehicleMessageProtocol, ControllerToken)
                if LivesNetworkSendSnapshotToController ~= nil then
                    pcall(function() LivesNetworkSendSnapshotToController(Controller, "capability-ready") end)
                end
            else
                Log("VEHNET v1.9.0 CAP TX READY failed safely target=%s error=%s",
                    ControllerToken, tostring(ReadyErr))
            end
        else
            Log("VEHNET v1.9.0 CAP server ignored invalid message=%s client=%s", Message, ControllerToken)
        end
        return
    end

    local Proto, Seq, KindCode, GameStateId, ColorIndex =
        string.match(Message, "^HCECEUP|(%d+)|(%d+)|([A-Z]+)|(%d+)|(%d+)$")
    Proto = tonumber(Proto)
    Seq = tonumber(Seq)
    GameStateId = tonumber(GameStateId)
    ColorIndex = tonumber(ColorIndex)
    if Proto ~= VehicleMessageProtocol or (KindCode ~= "W" and KindCode ~= "S") or GameStateId == nil or
       ColorIndex == nil or ColorIndex < 0 or ColorIndex > 18 then
        Log("VEHNET v1.9.0 UPLINK invalid/incompatible payload ignored client=%s message=%s",
            ControllerToken, Message)
        return
    end

    -- Fail closed: a color uplink is accepted for the proof only after this
    -- exact remote controller has ACKed our capability HELLO.
    if VehicleMessageCapabilityAckByController[ControllerToken] ~= true then
        Log("VEHNET v1.9.0 UPLINK blocked client=%s reason=no-capability-ack seq=%d", ControllerToken, Seq or -1)
        return
    end

    local KindName = VehicleMessageKindName(KindCode)
    local Vehicle, ObjectDatum, TagDatum = VehicleMessageFindLocalVehicleByGameStateId(KindCode, GameStateId)
    if IsValidObject(Vehicle) then
        local Applied, ApplyInfo = VehicleMessageApplyRemoteVehicleColor(KindCode, Vehicle, GameStateId, ColorIndex)
        if Applied then
            local Relayed = VehicleMessageSendVehicleState(Vehicle, KindCode, ColorIndex)
            local ColorName = ColorIndex == 0 and "ORIGINAL" or tostring((WarthogCEColors[ColorIndex] or {}).Name or ColorIndex)
            Log("VEHNET v1.9.0 UPLINK APPLIED+RELAYED protocol=%d seq=%d kind=%s gameStateId=%d colorIndex=%d color=%s client=%s actor=%s objectDatum=%s tagDatum=%s relayed=%d info=%s",
                Proto, Seq or -1, KindName, GameStateId, ColorIndex, ColorName, ControllerToken, SafeFullName(Vehicle),
                VehicleNetworkHex32((tonumber(ObjectDatum) or 0) & 0xFFFFFFFF),
                VehicleNetworkHex32((tonumber(TagDatum) or 0) & 0xFFFFFFFF),
                tonumber(Relayed) or 0, tostring(ApplyInfo))
        else
            Log("VEHNET v1.9.0 UPLINK HOST-PAINT FAILED-SAFE protocol=%d seq=%d kind=%s gameStateId=%d colorIndex=%d client=%s actor=%s action=no-relay info=%s",
                Proto, Seq or -1, KindName, GameStateId, ColorIndex, ControllerToken, SafeFullName(Vehicle), tostring(ApplyInfo))
        end
    else
        Log("VEHNET v1.9.0 UPLINK NO-MATCH protocol=%d seq=%d kind=%s gameStateId=%d colorIndex=%d client=%s action=ignored",
            Proto, Seq or -1, KindName, GameStateId, ColorIndex, ControllerToken)
    end
end

function InstallVehicleMessageServerHook()
    if VehicleMessageServerHookReady then return true end
    local Ok, PreId, PostId = pcall(function()
        return RegisterHook("/Script/Engine.PlayerController:ServerExecRPC",
            function(Context, StringParam)
                if VehicleMessageOfflineFastPath then return end
                local HookOk, HookErr = pcall(VehicleMessageHandleServerExecRPC, Context, StringParam)
                if not HookOk then
                    Log("VEHNET v1.9.0 ServerExecRPC hook callback failed safely: %s", tostring(HookErr))
                end
            end,
            function(Context, StringParam) end)
    end)
    if not Ok then
        Log("VEHNET v1.9.0 ServerExecRPC hook unavailable: %s", tostring(PreId))
        return false
    end
    VehicleMessageServerHookPreId = PreId
    VehicleMessageServerHookPostId = PostId
    VehicleMessageServerHookReady = true
    Log("VEHNET v1.9.0 ServerExecRPC receive hook ready; stock Server,Reliable uplink armed")
    return true
end

function NetworkIdentityRemotePlayerName(Controller)
    if not IsValidObject(Controller) or not IsValidObject(Controller.PlayerState) then return "" end
    local Name = ""
    pcall(function() Name = Controller.PlayerState:GetPlayerName() end)
    return tostring(Name or "")
end

function NetworkIdentityRemotePlayerId(Controller)
    if not IsValidObject(Controller) or not IsValidObject(Controller.PlayerState) then return nil end
    local Value = nil
    pcall(function() Value = Unwrap(Controller.PlayerState.PlayerId) end)
    return tonumber(Value)
end

function NetworkIdentityRepairRemoteDuplicateNames(Targets)
    if not LivesAuthorityResolved or not LivesAuthorityAllowed then return 0 end
    local Groups = {}
    for _, Controller in ipairs(Targets or {}) do
        if IsValidObject(Controller) and IsValidObject(Controller.PlayerState) then
            local Name = NetworkIdentityRemotePlayerName(Controller)
            if Name ~= "" then
                Groups[Name] = Groups[Name] or {}
                Groups[Name][#Groups[Name] + 1] = Controller
            end
        end
    end

    local Changed = 0
    for BaseName, Group in pairs(Groups) do
        if #Group > 1 then
            table.sort(Group, function(A, B)
                local AId, BId = NetworkIdentityRemotePlayerId(A), NetworkIdentityRemotePlayerId(B)
                if AId ~= nil and BId ~= nil and AId ~= BId then return AId < BId end
                return tostring(SafeFullName(A) or A) < tostring(SafeFullName(B) or B)
            end)
            for Index = 2, #Group do
                local Controller = Group[Index]
                local TargetName = string.format("%s (%d)", BaseName, Index)
                local Before = NetworkIdentityRemotePlayerName(Controller)
                local WriteOk = pcall(function() Controller.PlayerState.PlayerNamePrivate = TargetName end)
                local RepOk = false
                if WriteOk then
                    RepOk = pcall(function() Controller.PlayerState:OnRep_PlayerName() end)
                    pcall(function() Controller.PlayerState:ForceNetUpdate() end)
                end
                local After = NetworkIdentityRemotePlayerName(Controller)
                if WriteOk and After == TargetName then Changed = Changed + 1 end
                Log("IDENTITY remote guest repair index=%d write=%s onrep=%s before='%s' target='%s' after='%s' controller=%s",
                    Index, tostring(WriteOk), tostring(RepOk), tostring(Before), tostring(TargetName), tostring(After),
                    tostring(SafeFullName(Controller) or Controller))
            end
        end
    end
    return Changed
end

function LivesNetworkBuildHostState()
    if GameOverPending then return "G", 0 end
    if ReinforcementActive and tonumber(SimulatedLives) == 0 then
        return "R", math.max(0, math.ceil(tonumber(ReinforcementRemaining) or 0))
    end
    if MissionLivesEnabled then
        return "L", math.max(0, math.floor(tonumber(SimulatedLives) or 0))
    end
    return "O", 0
end

-- The legacy ClientTeamMessage Say/TeamSay vanilla-HUD experiment was removed
-- in v1.10.0 after repeated negative visibility tests. Vanilla compatibility now
-- uses the proven hidden Halo/PlayFab TTS path only; modded peers keep LIVESNET.

function LivesNetworkSendStateToController(Controller, State, Value, Reason)
    if not LivesAuthorityResolved or not LivesAuthorityAllowed or not IsValidObject(Controller) then return false end
    local Token = SafeFullName(Controller) or tostring(Controller)
    if VehicleMessageCapabilityAckByController[Token] ~= true then return false end
    State = tostring(State or "O")
    Value = math.max(0, math.floor(tonumber(Value) or 0))
    local Message = string.format("HCECELV|%d|%s|%d", LivesNetworkProtocol, State, Value)
    local Ok, Err = pcall(function() Controller:ClientMessage(Message, FName("Event"), 0.10) end)
    if Ok then
        Log("LIVESNET TX state=%s value=%d target=%s reason=%s", State, Value, Token, tostring(Reason or "state"))
        return true
    end
    Log("LIVESNET TX failed safely target=%s reason=%s error=%s", Token, tostring(Reason or "state"), tostring(Err))
    return false
end

function LivesNetworkSendSnapshotToController(Controller, Reason)
    local State, Value = LivesNetworkBuildHostState()
    return LivesNetworkSendStateToController(Controller, State, Value, Reason or "snapshot")
end

function LivesNetworkBroadcastState(State, Value, Reason)
    if not LivesAuthorityResolved or not LivesAuthorityAllowed or VehicleMessageOfflineFastPath then return 0 end
    local Sent = 0
    for _, Controller in ipairs(VehicleMessageCachedRemoteControllerCandidates()) do
        local Token = SafeFullName(Controller) or tostring(Controller)
        if VehicleMessageCapabilityAckByController[Token] == true and
           LivesNetworkSendStateToController(Controller, State, Value, Reason) then
            Sent = Sent + 1
        end
    end
    return Sent
end

function LivesNetworkBroadcastSnapshot(Reason)
    local State, Value = LivesNetworkBuildHostState()
    return LivesNetworkBroadcastState(State, Value, Reason or "snapshot")
end

function VehicleMessageSendCapabilityHello(Controller, Token, Attempt)
    if not IsValidObject(Controller) then return false end
    Token = tostring(Token or SafeFullName(Controller) or Controller)
    if VehicleMessageCapabilityAckByController[Token] == true then return true end

    Attempt = math.max(1, math.floor(tonumber(Attempt) or 1))
    local Message = string.format("HCECECAP|%d|HELLO", VehicleMessageProtocol)
    local Ok, Err = pcall(function()
        Controller:ClientMessage(Message, FName("Event"), 0.10)
    end)
    if Ok then
        VehicleMessageCapabilityAttemptsByController[Token] = Attempt
        Log("VEHNET v1.9.0 CAP TX HELLO protocol=%d attempt=%d/3 target=%s transport=stock-ClientMessage",
            VehicleMessageProtocol, Attempt, Token)
        return true
    end
    Log("VEHNET v1.9.0 CAP TX HELLO failed safely target=%s error=%s", Token, tostring(Err))
    return false
end

function VehicleMessageScheduleCapabilityRetry(Controller, Token, Attempt, DelayMs, RuntimeGeneration)
    ExecuteInGameThreadWithDelay(DelayMs, function()
        if RuntimeGeneration ~= WarthogColorRuntimeGeneration or ModTeardownGuard or not MissionReady then return end
        if not LivesAuthorityResolved or not LivesAuthorityAllowed then return end
        if VehicleMessageCapabilityAckByController[Token] == true then return end
        if VehicleMessageCapabilityControllerByToken[Token] ~= Controller or not IsValidObject(Controller) then return end
        VehicleMessageSendCapabilityHello(Controller, Token, Attempt)
    end)
end

function VehicleMessageCapabilityPrimeMission()
    if VehicleMessageCapabilityMissionPrimed then return end
    if not MissionReady or not LivesAuthorityResolved or not LivesAuthorityAllowed then return end

    -- One bounded discovery at the lifecycle boundary. Periodic ReceiveTick
    -- discovery is intentionally absent because network discovery must not become
    -- steady-gameplay work.
    VehicleMessageCapabilityMissionPrimed = true
    VehicleMessageCapabilityControllerByToken = {}
    local Targets = VehicleMessageRemoteControllerCandidates()
    local RuntimeGeneration = WarthogColorRuntimeGeneration
    for _, Controller in ipairs(Targets or {}) do
        if IsValidObject(Controller) then
            local Token = SafeFullName(Controller) or tostring(Controller)
            VehicleMessageCapabilityControllerByToken[Token] = Controller
            VehicleMessageSendCapabilityHello(Controller, Token, 1)
            -- ClientMessage is Reliable; two bounded startup retries are retained only
            -- for cross-store/mod-load timing variance. There is no recurring scan.
            VehicleMessageScheduleCapabilityRetry(Controller, Token, 2, 1500, RuntimeGeneration)
            VehicleMessageScheduleCapabilityRetry(Controller, Token, 3, 4000, RuntimeGeneration)
        end
    end
    local TargetCount = #(Targets or {})
    if TargetCount > 0 then
        pcall(function() NetworkIdentityRepairRemoteDuplicateNames(Targets) end)
    end
    VehicleMessageOfflineFastPath = TargetCount == 0
    if VehicleMessageOfflineFastPath then
        Log("VEHNET v1.9.0 CAP mission discovery complete cached=0 network=dormant-local-only")
    else
        Log("VEHNET v1.9.0 CAP mission discovery complete cached=%d network=active", TargetCount)
    end
end

function VehicleMessageCachedRemoteControllerCandidates()
    local Out = {}
    for _, Controller in pairs(VehicleMessageCapabilityControllerByToken or {}) do
        if IsValidObject(Controller) then Out[#Out + 1] = Controller end
    end
    return Out
end

function VehicleMessageTryAdoptConstructedRemoteController(Controller, Source)
    Controller = Unwrap(Controller)
    if not IsValidObject(Controller) or ModTeardownGuard or not MissionReady then return false end
    if not LivesAuthorityResolved or not LivesAuthorityAllowed then return false end

    local Token = SafeFullName(Controller) or tostring(Controller)
    if Token == '' or string.find(Token, 'Default__', 1, true) then return false end

    -- Never let a stale controller from the prior world re-arm the current mission.
    local MissionPrefix = string.match(tostring(LivesMissionControllerName or ''), '^(.-:PersistentLevel)') or ''
    if MissionPrefix ~= '' and string.find(Token, MissionPrefix, 1, true) == nil then return false end

    local IsLocal = nil
    pcall(function() IsLocal = Controller:IsLocalController() == true end)
    local ControllerId = nil
    pcall(function()
        if IsValidObject(Controller.Player) then ControllerId = Controller.Player.ControllerId end
    end)
    -- Listen-server remote controllers are non-local and normally backed by a
    -- UNetConnection (no numeric local ControllerId). Require one of those proofs.
    if IsLocal ~= false and type(ControllerId) == 'number' then return false end

    if VehicleMessageCapabilityControllerByToken[Token] == Controller then return true end

    VehicleMessageCapabilityMissionPrimed = true
    VehicleMessageOfflineFastPath = false
    VehicleMessageCapabilityControllerByToken[Token] = Controller
    VehicleMessageCapabilityAttemptsByController[Token] = nil
    VehicleMessageCapabilityAckByController[Token] = nil

    local RuntimeGeneration = WarthogColorRuntimeGeneration
    Log('VEHNET v1.9.0 CAP late remote controller adopted source=%s target=%s network=active',
        tostring(Source or 'controller-construction'), tostring(Token))
    VehicleMessageSendCapabilityHello(Controller, Token, 1)
    VehicleMessageScheduleCapabilityRetry(Controller, Token, 2, 1500, RuntimeGeneration)
    VehicleMessageScheduleCapabilityRetry(Controller, Token, 3, 4000, RuntimeGeneration)

    -- Duplicate-name repair is bounded to the already cached remote controllers;
    -- no FindAllOf/global scan is introduced here.
    pcall(function() NetworkIdentityRepairRemoteDuplicateNames(VehicleMessageCachedRemoteControllerCandidates()) end)
    return true
end

function RegisterVehicleMessageControllerConstructionListener()
    if VehicleMessageControllerConstructionListenerReady then return true end
    local Ok, Err = pcall(function()
        NotifyOnNewObject(
            '/Game/Blueprints/BP_MeteoritePlayerController.BP_MeteoritePlayerController_C',
            function(Controller)
                local RuntimeGeneration = WarthogColorRuntimeGeneration
                -- Give ownership/Player fields a moment to settle after construction.
                ExecuteInGameThreadWithDelay(100, function()
                    if RuntimeGeneration ~= WarthogColorRuntimeGeneration or ModTeardownGuard then return end
                    if ObserveConstructedLocalP1ForLives ~= nil then
                        pcall(function() ObserveConstructedLocalP1ForLives(Controller) end)
                    end
                    if VehicleMessageTryAdoptConstructedRemoteController(Controller, 'controller construction') then return end
                    -- One bounded second chance covers the narrow race where the
                    -- controller constructs just before the stable-mission gate.
                    ExecuteInGameThreadWithDelay(2000, function()
                        if RuntimeGeneration ~= WarthogColorRuntimeGeneration or ModTeardownGuard then return end
                        VehicleMessageTryAdoptConstructedRemoteController(Controller, 'controller construction settle')
                    end)
                end)
            end
        )
    end)
    if Ok then
        VehicleMessageControllerConstructionListenerReady = true
        Log('VEHNET v1.9.0 remote PlayerController construction listener ready; late network peers are event-driven')
        return true
    end
    Log('VEHNET v1.9.0 remote PlayerController construction listener unavailable: %s', tostring(Err))
    return false
end

function VehicleMessageSendClientUplink(Vehicle, KindCode, ColorIndex)
    Vehicle = Unwrap(Vehicle)
    ColorIndex = tonumber(ColorIndex)
    if not IsValidObject(Vehicle) or (KindCode ~= "W" and KindCode ~= "S")
        or ColorIndex == nil or ColorIndex < 0 or ColorIndex > 18 then return false end
    if not LivesAuthorityResolved or not LivesNetworkClientBlocked then return false end
    if VehicleMessageHostCapabilitySeen ~= true then
        Log("VEHNET v1.9.0 UPLINK blocked reason=host-capability-not-seen kind=%s colorIndex=%d",
            VehicleMessageKindName(KindCode), ColorIndex)
        return false
    end
    if VehicleMessageUplinkReady ~= true or not IsValidObject(VehicleMessageUplinkController) then
        Log("VEHNET v1.9.0 UPLINK blocked reason=no-proven-controller-route kind=%s colorIndex=%d provisional=%s",
            VehicleMessageKindName(KindCode), ColorIndex, tostring(VehicleMessageUplinkControllerName or ""))
        return false
    end

    local _, _, GameStateId = VehicleNetworkFindBlamObjectIds(Vehicle)
    GameStateId = tonumber(GameStateId)
    if GameStateId == nil then
        Log("VEHNET v1.9.0 UPLINK blocked reason=missing-gameStateId kind=%s colorIndex=%d",
            VehicleMessageKindName(KindCode), ColorIndex)
        return false
    end
    local Controller = VehicleMessageUplinkController
    if not IsValidObject(Controller) then
        VehicleMessageUplinkReady = false
        VehicleMessageUplinkController = nil
        VehicleMessageUplinkControllerName = ""
        return false
    end

    VehicleMessageUplinkSequence = (tonumber(VehicleMessageUplinkSequence) or 0) + 1
    local Message = string.format("HCECEUP|%d|%d|%s|%d|%d",
        VehicleMessageProtocol, VehicleMessageUplinkSequence, KindCode, GameStateId, ColorIndex)
    local Ok, Err = pcall(function() Controller:ServerExecRPC(Message) end)
    if Ok then
        Log("VEHNET v1.9.0 UPLINK TX protocol=%d seq=%d kind=%s gameStateId=%d colorIndex=%d route=%s transport=stock-ServerExecRPC awaiting=host-receive",
            VehicleMessageProtocol, VehicleMessageUplinkSequence, VehicleMessageKindName(KindCode), GameStateId, ColorIndex,
            tostring(VehicleMessageUplinkControllerName or SafeFullName(Controller) or Controller))
        return true
    end
    Log("VEHNET v1.9.0 UPLINK TX failed safely seq=%d error=%s", VehicleMessageUplinkSequence, tostring(Err))
    return false
end

function VehicleMessageRemoteControllerCandidates()
    local Anchor = GetPlayer(1)
    if not IsValidObject(Anchor) then
        pcall(function() Anchor = UEHelpers.GetPlayerController() end)
    end
    local LevelPrefix = ""
    if IsValidObject(Anchor) then
        LevelPrefix = string.match(SafeFullName(Anchor) or "", "^(.-:PersistentLevel)") or ""
    end

    local All = nil
    pcall(function() All = FindAllOf("PlayerController") end)
    local Out = {}
    for _, Candidate in ipairs(All or {}) do
        if IsValidObject(Candidate) then
            local CandidateName = SafeFullName(Candidate) or ""
            local SameLevel = (LevelPrefix == "") or string.find(CandidateName, LevelPrefix, 1, true) ~= nil
            if SameLevel and not string.find(CandidateName, "Default__", 1, true) then
                local IsLocal = nil
                pcall(function() IsLocal = Candidate:IsLocalController() == true end)
                local ControllerId = nil
                pcall(function()
                    if IsValidObject(Candidate.Player) then ControllerId = Candidate.Player.ControllerId end
                end)
                -- On the listen server remote PlayerControllers use a UNetConnection,
                -- so ControllerId is non-numeric. IsLocalController=false is the preferred proof.
                if IsLocal == false or type(ControllerId) ~= "number" then
                    Out[#Out + 1] = Candidate
                end
            end
        end
    end
    return Out
end

function VehicleMessageSendVehicleState(Vehicle, KindCode, ColorIndex)
    Vehicle = Unwrap(Vehicle)
    if not IsValidObject(Vehicle) or (KindCode ~= "W" and KindCode ~= "S") then return 0 end
    if VehicleMessageOfflineFastPath then return 0 end

    local ObjectDatum, TagDatum, GameStateId, Source = VehicleNetworkFindBlamObjectIds(Vehicle)
    GameStateId = tonumber(GameStateId)
    ColorIndex = tonumber(ColorIndex)
    if GameStateId == nil or ColorIndex == nil or ColorIndex < 0 or ColorIndex > 18 then
        Log("VEHNET v1.9.0 TX blocked: missing/invalid %s identity or color gameStateId=%s colorIndex=%s source=%s",
            VehicleMessageKindName(KindCode), tostring(GameStateId), tostring(ColorIndex), tostring(Source))
        return 0
    end

    VehicleMessageSequence = (tonumber(VehicleMessageSequence) or 0) + 1
    local Message = string.format("HCECEVC|%d|%d|%s|%d|%d",
        VehicleMessageProtocol, VehicleMessageSequence, KindCode, GameStateId, ColorIndex)
    if not VehicleMessageCapabilityMissionPrimed then
        VehicleMessageCapabilityPrimeMission()
    end
    local Targets = VehicleMessageCachedRemoteControllerCandidates()
    if #Targets == 0 and LivesAuthorityResolved and LivesAuthorityAllowed and not VehicleMessageOfflineFastPath then
        VehicleMessageResetCapabilityState("explicit vehicle action found stale/empty remote cache")
        VehicleMessageCapabilityPrimeMission()
        Targets = VehicleMessageCachedRemoteControllerCandidates()
    end
    local Sent = 0
    local Eligible = 0
    for _, Controller in ipairs(Targets) do
        local Name = SafeFullName(Controller) or tostring(Controller)
        -- Fail closed: color payloads are sent only after this exact remote
        -- controller ACKed HCECECAP. Vanilla/older peers receive only the
        -- harmless stock capability HELLO attempts, never HCECEVC color traffic.
        if VehicleMessageCapabilityAckByController[Name] == true then
            Eligible = Eligible + 1
            local Ok, Err = pcall(function()
                Controller:ClientMessage(Message, FName("Event"), 0.10)
            end)
            if Ok then
                Sent = Sent + 1
                Log("VEHNET v1.9.0 TX stock ClientMessage seq=%d target=%s kind=%s gameStateId=%d colorIndex=%d",
                    VehicleMessageSequence, tostring(Name), VehicleMessageKindName(KindCode), GameStateId, ColorIndex)
            else
                Log("VEHNET v1.9.0 TX failed safely target=%s error=%s", tostring(Name), tostring(Err))
            end
        else
            Log("VEHNET v1.9.0 TX skipped unverified peer target=%s seq=%d", tostring(Name), VehicleMessageSequence)
        end
    end
    Log("VEHNET v1.9.0 TX RESULT seq=%d targets=%d eligible=%d sent=%d kind=%s gameStateId=%d colorIndex=%d transport=stock-ClientMessage",
        VehicleMessageSequence, #Targets, Eligible, Sent, VehicleMessageKindName(KindCode), GameStateId, ColorIndex)
    return Sent
end

function VehicleNetworkPostLocalPaint(Vehicle, Kind, State)
    Vehicle = Unwrap(Vehicle)
    if not IsValidObject(Vehicle) or VehicleMessageOfflineFastPath then return end

    local ActorAuthority, RoleText = VehicleNetworkIsAuthority(Vehicle)
    local SessionAuthority = LivesAuthorityResolved and LivesAuthorityAllowed == true
    local SessionClient = LivesAuthorityResolved and LivesNetworkClientBlocked == true
    Log("VEHNET v1.9.0 %s local-paint state=%s actorAuthority=%s role=%s sessionAuthority=%s sessionClient=%s transport=stock-rpc",
        tostring(Kind), tostring(State), tostring(ActorAuthority == true), tostring(RoleText),
        tostring(SessionAuthority), tostring(SessionClient))

    local KindCode = nil
    local ColorIndex = nil
    if Kind == "Warthog" then
        KindCode = "W"
        ColorIndex = tonumber(WarthogColorIndexByVehicle[WarthogVehicleToken(Vehicle)])
    elseif Kind == "Scorpion" then
        KindCode = "S"
        ColorIndex = tonumber(ScorpionColorIndexByVehicle[ScorpionVehicleToken(Vehicle)])
        local _, _, LocalGameStateId = VehicleNetworkFindBlamObjectIds(Vehicle)
        if tonumber(LocalGameStateId) ~= nil then
            VehicleMessageCancelRemoteScorpionSettle(LocalGameStateId)
        end
    else
        return
    end
    if ColorIndex == nil then return end

    if SessionAuthority then
        VehicleMessageSendVehicleState(Vehicle, KindCode, ColorIndex)
    elseif SessionClient then
        VehicleMessageSendClientUplink(Vehicle, KindCode, ColorIndex)
    end
end


-- Occupied-Warthog color cycling -------------------------------------------
-- Runtime vehicle paint is now proven: the GreenHull body material accepts
-- SetVectorParameterValueByInfo on the exact layer ParameterInfo entries
-- (association=0, index=1). Public input cycles the 18 original Halo:
-- Combat Evolved multiplayer armor colors, but only after the requesting
-- player's pawn can be positively proven to be in the DRIVER seat. Gunner,
-- passenger and on-foot input are rejected before any material scan. Direct
-- Hull attachments are separated by their seat socket / local side instead of
-- assuming every direct attachment is the driver. We never fall back to
-- nearest-vehicle targeting.
--
-- Controller: hold RB + click LS/RS for previous/next.
-- Keyboard:   Ctrl+PageUp/PageDown (P1) for previous/next.
--
-- Original HCE hard-coded armor colors (RGB/HEX) are sourced from the engine
-- documentation. Values are stored below as the original 8-bit sRGB triplets
-- and converted to FLinearColor before being sent to Unreal.
WarthogColorRuntimeGeneration = WarthogColorRuntimeGeneration or 0
WarthogColorIndexByVehicle = WarthogColorIndexByVehicle or {}
WarthogLastColorIndexByPlayer = WarthogLastColorIndexByPlayer or {}
WarthogCheckpointColorCarryByPlayer = WarthogCheckpointColorCarryByPlayer or {}
WarthogPaintMIDCacheByVehicle = WarthogPaintMIDCacheByVehicle or {}
WarthogPaintInfoCacheByParent = WarthogPaintInfoCacheByParent or {}
WarthogAccessoryInfoCacheByParent = WarthogAccessoryInfoCacheByParent or {}
WarthogPaintApplyPlanCacheByVehicle = WarthogPaintApplyPlanCacheByVehicle or {}
WarthogAccessoryRoleByMID = WarthogAccessoryRoleByMID or {}
WarthogAccessoryRepairScheduledByVehicle = WarthogAccessoryRepairScheduledByVehicle or {}
WarthogBodyPaintMIDIndexByVehicle = WarthogBodyPaintMIDIndexByVehicle or {}
WarthogBodyPaintMIDIndexBuilt = WarthogBodyPaintMIDIndexBuilt or false
WarthogDriverComponentIndexByPlayer = WarthogDriverComponentIndexByPlayer or {}
WarthogHybridDriverSnapshotGeneration = WarthogHybridDriverSnapshotGeneration or -1
WarthogHybridDriverAttemptGeneration = WarthogHybridDriverAttemptGeneration or -1
WarthogHybridDriverSnapshot = WarthogHybridDriverSnapshot or {}
WarthogHybridDriverVehicleP2 = WarthogHybridDriverVehicleP2 or nil
-- Authored paint values are logical/session data, not world-local UObject state.
-- Keep them across RestartLevel/checkpoint invalidation so a surviving recolored
-- MID can never redefine the meaning of ORIGINAL.
WarthogOriginalColorValueCache = WarthogOriginalColorValueCache or {}
KeyboardPendingVehicleColorDelta = KeyboardPendingVehicleColorDelta or 0
KeyboardPendingClassicSkinDelta = KeyboardPendingClassicSkinDelta or 0

function InvalidateWarthogColorRuntime(Reason, PreserveColorCarry)
    WarthogColorRuntimeGeneration = (tonumber(WarthogColorRuntimeGeneration) or 0) + 1
    if PreserveColorCarry then
        for PlayerIndex = 1, 2 do
            local Last = tonumber(WarthogLastColorIndexByPlayer[PlayerIndex])
            if Last ~= nil then WarthogCheckpointColorCarryByPlayer[PlayerIndex] = Last end
        end
    end

    -- UObject/MID references are world-local and must never survive a checkpoint,
    -- RestartLevel or travel. Logical color indexes deliberately survive here.
    WarthogPaintMIDCacheByVehicle = {}
    WarthogPaintApplyPlanCacheByVehicle = {}
    WarthogAccessoryRoleByMID = {}
    WarthogAccessoryRepairScheduledByVehicle = {}
    WarthogBodyPaintMIDIndexByVehicle = {}
    WarthogBodyPaintMIDIndexBuilt = false
    WarthogDriverComponentIndexByPlayer = {}
    WarthogHybridDriverSnapshotGeneration = -1
    WarthogHybridDriverAttemptGeneration = -1
    WarthogHybridDriverSnapshot = {}
    WarthogHybridDriverVehicleP2 = nil
    VehicleMessageRemoteRepairScheduledByGameStateId = {}
    VehicleMessageRemoteScorpionSettleTokenByGameStateId = {}
    VehicleMessageLastReceivedSequenceByVehicle = {}
    VehicleMessageHostCapabilitySeen = false
    VehicleMessageHostCapabilityAckSent = false
    VehicleMessageUplinkController = nil
    VehicleMessageUplinkControllerName = ""
    VehicleMessageUplinkReady = false
    VehicleMessageCapabilityAttemptsByController = {}
    VehicleMessageCapabilityAckByController = {}
    VehicleMessageCapabilityControllerByToken = {}
    VehicleMessageCapabilityMissionPrimed = false
    VehicleMessageOfflineFastPath = false
    VehicleMessageUplinkSequence = 0
    if ArmorSkinDropAllRuntimeRefs ~= nil then
        ArmorSkinDropAllRuntimeRefs("vehicle runtime invalidation: " .. tostring(Reason or "unknown"))
    end
    LivesNetworkResetRemoteState("vehicle runtime invalidation: " .. tostring(Reason or "unknown"))
    KeyboardPendingVehicleColorDelta = 0
end

function ResetWarthogColorState(Reason)
    WarthogColorRuntimeGeneration = (tonumber(WarthogColorRuntimeGeneration) or 0) + 1
    WarthogColorIndexByVehicle = {}
    WarthogLastColorIndexByPlayer = {}
    WarthogCheckpointColorCarryByPlayer = {}
    WarthogPaintMIDCacheByVehicle = {}
    WarthogPaintInfoCacheByParent = {}
    WarthogAccessoryInfoCacheByParent = {}
    WarthogPaintApplyPlanCacheByVehicle = {}
    WarthogAccessoryRoleByMID = {}
    WarthogAccessoryRepairScheduledByVehicle = {}
    WarthogBodyPaintMIDIndexByVehicle = {}
    WarthogBodyPaintMIDIndexBuilt = false
    WarthogDriverComponentIndexByPlayer = {}
    WarthogHybridDriverSnapshotGeneration = -1
    WarthogHybridDriverAttemptGeneration = -1
    WarthogHybridDriverSnapshot = {}
    WarthogHybridDriverVehicleP2 = nil
    WarthogOriginalColorValueCache = {}
    VehicleMessageRemoteColorIndexByGameStateId = {}
    VehicleMessageRemoteRepairScheduledByGameStateId = {}
    VehicleMessageRemoteScorpionSettleTokenByGameStateId = {}
    VehicleMessageLastReceivedSequenceByVehicle = {}
    VehicleMessageHostCapabilitySeen = false
    VehicleMessageHostCapabilityAckSent = false
    VehicleMessageUplinkController = nil
    VehicleMessageUplinkControllerName = ""
    VehicleMessageUplinkReady = false
    VehicleMessageCapabilityAttemptsByController = {}
    VehicleMessageCapabilityAckByController = {}
    VehicleMessageCapabilityControllerByToken = {}
    VehicleMessageCapabilityMissionPrimed = false
    VehicleMessageOfflineFastPath = false
    VehicleMessageUplinkSequence = 0
    if ArmorSkinResetSessionState ~= nil then
        ArmorSkinResetSessionState("vehicle/session reset: " .. tostring(Reason or "unknown"))
    end
    LivesNetworkResetRemoteState("vehicle/session reset: " .. tostring(Reason or "unknown"))
    KeyboardPendingVehicleColorDelta = 0
end

WarthogCEColors = {
    { Name="BLACK",  Hex="#000000", R=0,   G=0,   B=0   },
    { Name="RED",    Hex="#FE0000", R=254, G=0,   B=0   },
    { Name="BLUE",   Hex="#0201E3", R=2,   G=1,   B=227 },
    { Name="GRAY",   Hex="#808080", R=128, G=128, B=128 },
    { Name="YELLOW", Hex="#FFFF01", R=255, G=255, B=1   },
    { Name="GREEN",  Hex="#00FF01", R=0,   G=255, B=1   },
    { Name="PINK",   Hex="#FF56B9", R=255, G=86,  B=185 },
    { Name="PURPLE", Hex="#AB10F4", R=171, G=16,  B=244 },
    { Name="CYAN",   Hex="#01FFFF", R=1,   G=255, B=255 },
    { Name="COBALT", Hex="#6493ED", R=100, G=147, B=237 },
    { Name="ORANGE", Hex="#FF7F00", R=255, G=127, B=0   },
    { Name="TEAL",   Hex="#1ECC91", R=30,  G=204, B=145 },
    { Name="SAGE",   Hex="#006401", R=0,   G=100, B=1   },
    { Name="BROWN",  Hex="#603814", R=96,  G=56,  B=20  },
    { Name="TAN",    Hex="#C69C6C", R=198, G=156, B=108 },
    { Name="MAROON", Hex="#9D0B0E", R=157, G=11,  B=14  },
    { Name="SALMON", Hex="#F5999E", R=245, G=153, B=158 },
    { Name="WHITE",  Hex="#FFFFFF", R=255, G=255, B=255 },
}

ScorpionCEColors = {}
for Index, Color in ipairs(WarthogCEColors) do
    ScorpionCEColors[Index] = { Name=Color.Name, Hex=Color.Hex, R=Color.R, G=Color.G, B=Color.B }
end
-- Scorpion hull materials lean slightly olive with the same neutral gray used by
-- the Warthog, so give Scorpion its own cooler/lighter GRAY to better match the
-- Spartan classic gray armor in-game.
ScorpionCEColors[4] = { Name="GRAY", Hex="#A0A6B5", R=160, G=166, B=181 }

function WarthogRecolorClip(Value, Limit)
    local Text = tostring(Value or "")
    Text = string.gsub(Text, "[\r\n\t]+", " ")
    local Max = tonumber(Limit) or 900
    if #Text > Max then Text = string.sub(Text, 1, Max) .. "..." end
    return Text
end

function WarthogRecolorDescribe(Object)
    Object = Unwrap(Object)
    if not IsValidObject(Object) then return WarthogRecolorClip(SafeToString(Object), 900) end
    local Full = SafeFullName(Object) or SafeToString(Object)
    local ClassFull = ""
    pcall(function()
        local Class = Object:GetClass()
        if IsValidObject(Class) then ClassFull = SafeFullName(Class) or SafeToString(Class) end
    end)
    local Out = tostring(Full)
    if ClassFull ~= "" then Out = Out .. " | class=" .. tostring(ClassFull) end
    return WarthogRecolorClip(Out, 1200)
end

function WarthogRecolorParameterInfoFields(Entry)
    Entry = Unwrap(Entry)
    local Info = nil
    pcall(function() Info = Unwrap(Entry.ParameterInfo) end)
    if Info == nil then return nil, nil, nil, nil end

    local Name, Association, Index = nil, nil, nil
    pcall(function() Name = Unwrap(Info.Name) end)
    pcall(function() Association = Unwrap(Info.Association) end)
    pcall(function() Index = Unwrap(Info.Index) end)
    return Info, Name, Association, Index
end

function WarthogRecolorParameterName(Entry)
    local _, Name = WarthogRecolorParameterInfoFields(Entry)
    return tostring(SafeToString(Name))
end

function WarthogRecolorFindLayerInfo(Parent, ParameterName)
    local Values = nil
    local Ok, Err = pcall(function() Values = Parent.VectorParameterValues end)
    if not Ok then return nil end

    local Entries = ArrayValues(Values)
    for EntryIndex, RawEntry in ipairs(Entries) do
        local Entry = Unwrap(RawEntry)
        local Info, Name, Association, Index = WarthogRecolorParameterInfoFields(Entry)
        local NameText = tostring(SafeToString(Name))
        local AssociationNumber = tonumber(SafeToString(Association))
        local IndexNumber = tonumber(SafeToString(Index))
        if NameText == tostring(ParameterName) and AssociationNumber == 0 and IndexNumber == 1 then
            return Info, EntryIndex
        end
    end

    return nil
end

function WarthogColorSRGBByteToLinear(ByteValue)
    local C = math.max(0.0, math.min(255.0, tonumber(ByteValue) or 0.0)) / 255.0
    if C <= 0.04045 then return C / 12.92 end
    return ((C + 0.055) / 1.055) ^ 2.4
end

function WarthogColorLinear(Color)
    local DisplayBrightness = 0.85
    local DisplaySaturation = 0.90
    local R = tonumber(Color.R) or 0
    local G = tonumber(Color.G) or 0
    local B = tonumber(Color.B) or 0
    local Neutral = 0.299 * R + 0.587 * G + 0.114 * B
    local function DisplayByte(Value)
        return (Neutral + (Value - Neutral) * DisplaySaturation) * DisplayBrightness
    end
    return {
        R=WarthogColorSRGBByteToLinear(DisplayByte(R)),
        G=WarthogColorSRGBByteToLinear(DisplayByte(G)),
        B=WarthogColorSRGBByteToLinear(DisplayByte(B)),
        A=1.0,
    }
end

function WarthogIsWarthogActor(Object)
    Object = Unwrap(Object)
    if not IsValidObject(Object) then return false end
    local Class = nil
    pcall(function() Class = Unwrap(Object:GetClass()) end)
    local ClassText = string.lower(tostring(SafeFullName(Class) or SafeToString(Class) or ""))
    return string.find(ClassText, "bp_warthogvehicleactor_c", 1, true) ~= nil
end

function WarthogSameObject(A, B)
    A = Unwrap(A)
    B = Unwrap(B)
    if not IsValidObject(A) or not IsValidObject(B) then return false end
    if A == B then return true end
    local AF = tostring(SafeFullName(A) or "")
    local BF = tostring(SafeFullName(B) or "")
    return AF ~= "" and AF == BF
end


function WarthogObjectNameLower(Object)
    Object = Unwrap(Object)
    if Object == nil then return "" end
    return string.lower(tostring(SafeFullName(Object) or SafeToString(Object) or ""))
end

function WarthogSeatRoleFromObject(Object)
    Object = Unwrap(Object)
    if Object == nil then return nil, "seat object missing" end

    local Text = WarthogObjectNameLower(Object)
    if string.find(Text, "driver", 1, true) ~= nil then return true, "name contains driver" end
    if string.find(Text, "gunner", 1, true) ~= nil
        or string.find(Text, "passenger", 1, true) ~= nil
        or string.find(Text, "turretseat", 1, true) ~= nil then
        return false, "name identifies non-driver seat"
    end

    for _, Name in ipairs({"SeatIndex", "VehicleSeatIndex", "SeatId", "SeatID"}) do
        local Value = nil
        pcall(function() Value = Unwrap(Object[Name]) end)
        local Number = tonumber(SafeToString(Value))
        if Number ~= nil then
            if Number == 0 then return true, tostring(Name) .. "=0" end
            if Number > 0 then return false, tostring(Name) .. "=" .. tostring(Number) end
        end
    end

    for _, Name in ipairs({"SeatName", "SeatType", "Role", "SeatRole", "SocketName", "AttachSocketName"}) do
        local Value = nil
        pcall(function() Value = Unwrap(Object[Name]) end)
        local ValueText = string.lower(tostring(SafeToString(Value) or ""))
        if string.find(ValueText, "driver", 1, true) ~= nil then
            return true, tostring(Name) .. "=" .. ValueText
        end
        if string.find(ValueText, "gunner", 1, true) ~= nil
            or string.find(ValueText, "passenger", 1, true) ~= nil
            or string.find(ValueText, "turret", 1, true) ~= nil then
            return false, tostring(Name) .. "=" .. ValueText
        end
    end
    return nil, "seat role unavailable"
end

function WarthogSeatNameText(Value)
    if Value == nil then return "" end
    local Text = ""
    pcall(function() Text = SafeToString(Value) end)
    return string.lower(tostring(Text or ""))
end

function WarthogSeatVectorY(Value)
    if Value == nil then return nil end
    local Y = nil
    pcall(function() Y = tonumber(Value.Y) end)
    if Y == nil then pcall(function() Y = tonumber(SafeToString(Value.Y)) end) end
    return Y
end

function WarthogDirectHullSeatProof(Chain)
    local Count = #(Chain or {})
    if Count < 2 then return nil, "direct-Hull seat signature unavailable", "" end

    local Hull = Unwrap(Chain[Count])
    local SeatRoot = Unwrap(Chain[Count - 1])
    if not IsValidObject(Hull) or not IsValidObject(SeatRoot) then
        return nil, "direct-Hull seat objects invalid", ""
    end

    local SocketValue = nil
    pcall(function() SocketValue = SeatRoot:GetAttachSocketName() end)
    if SocketValue == nil then pcall(function() SocketValue = SeatRoot.AttachSocketName end) end
    local SocketText = WarthogSeatNameText(SocketValue)

    if SocketText ~= "" and SocketText ~= "none" and SocketText ~= "<nil>" then
        if string.find(SocketText, "driver", 1, true) ~= nil
            or string.find(SocketText, "pilot", 1, true) ~= nil then
            return true, "direct Hull socket identifies driver: " .. SocketText,
                "socket=" .. SocketText
        end
        if string.find(SocketText, "passenger", 1, true) ~= nil
            or string.find(SocketText, "gunner", 1, true) ~= nil
            or string.find(SocketText, "rider", 1, true) ~= nil then
            return false, "direct Hull socket identifies non-driver: " .. SocketText,
                "socket=" .. SocketText
        end
    end

    -- Driver and passenger are both direct children of the Hull in this game.
    -- Their mounted root/socket positions are on opposite sides. Unreal vehicle
    -- convention is +Y right, so the Warthog driver (left seat) is -Y and the
    -- passenger (right seat) is +Y. Prefer the child's relative Y when present.
    local RelativeLocation = nil
    pcall(function() RelativeLocation = SeatRoot.RelativeLocation end)
    local RelativeY = WarthogSeatVectorY(RelativeLocation)
    if RelativeY ~= nil and math.abs(RelativeY) > 2.0 then
        if RelativeY < 0 then
            return true, string.format("direct Hull left-seat relativeY=%.2f", RelativeY),
                string.format("socket=%s relativeY=%.2f", SocketText, RelativeY)
        end
        return false, string.format("direct Hull right-seat relativeY=%.2f", RelativeY),
            string.format("socket=%s relativeY=%.2f", SocketText, RelativeY)
    end

    -- With socket-attached components RelativeLocation is commonly zero. Ask
    -- the Hull for that socket in component space (RTS_Component = 2) and use
    -- the socket's local Y instead.
    local SocketY = nil
    if SocketValue ~= nil and SocketText ~= "" and SocketText ~= "none" and SocketText ~= "<nil>" then
        local SocketTransform = nil
        pcall(function() SocketTransform = Hull:GetSocketTransform(SocketValue, 2) end)
        if SocketTransform ~= nil then
            local Translation = nil
            pcall(function() Translation = SocketTransform.Translation end)
            if Translation == nil then pcall(function() Translation = SocketTransform.Location end) end
            SocketY = WarthogSeatVectorY(Translation)
        end
    end
    if SocketY ~= nil and math.abs(SocketY) > 2.0 then
        if SocketY < 0 then
            return true, string.format("direct Hull left-seat socketY=%.2f", SocketY),
                string.format("socket=%s relativeY=%s socketY=%.2f", SocketText, tostring(RelativeY), SocketY)
        end
        return false, string.format("direct Hull right-seat socketY=%.2f", SocketY),
            string.format("socket=%s relativeY=%s socketY=%.2f", SocketText, tostring(RelativeY), SocketY)
    end

    return nil, "direct Hull seat side unresolved",
        string.format("socket=%s relativeY=%s socketY=%s", SocketText, tostring(RelativeY), tostring(SocketY))
end

function WarthogTraceAttachmentChain(Component, Label)
    local Current = Unwrap(Component)
    local Chain = {}
    for Depth = 1, 10 do
        if not IsValidObject(Current) then break end
        Chain[#Chain + 1] = Current
        local Vehicle = WarthogResolveVehicleFromObject(Current)
        if IsValidObject(Vehicle) then
            return Vehicle, string.format("%s attach/owner depth %d", tostring(Label or "component"), Depth), Chain
        end
        local Parent = nil
        pcall(function() Parent = Unwrap(Current.AttachParent) end)
        if not IsValidObject(Parent) then pcall(function() Parent = Unwrap(Current:GetAttachParent()) end) end
        if not IsValidObject(Parent) then break end
        Current = Parent
    end
    return nil, tostring(Label or "component") .. " no Warthog attachment", Chain
end

function WarthogDriverPropertyProof(Vehicle, Pawn)
    if not IsValidObject(Vehicle) or not IsValidObject(Pawn) then return nil, "invalid vehicle/pawn" end

    for _, Name in ipairs({
        "Driver", "DriverPawn", "CurrentDriver", "CurrentDriverPawn",
        "VehicleDriver", "DriverCharacter", "DriverOccupant"
    }) do
        local Value = nil
        pcall(function() Value = Unwrap(Vehicle[Name]) end)
        if Value ~= nil then
            local Contains, Detail = WarthogSeatLikeValueContainsPawn(Value, Pawn)
            if Contains then return true, "Vehicle." .. tostring(Name) .. "." .. tostring(Detail) end
        end
    end

    for _, Name in ipairs({"DriverSeat", "DriverSeatComponent", "CurrentDriverSeat"}) do
        local Value = nil
        pcall(function() Value = Unwrap(Vehicle[Name]) end)
        if Value ~= nil then
            local Contains, Detail = WarthogSeatLikeValueContainsPawn(Value, Pawn)
            if Contains then return true, "Vehicle." .. tostring(Name) .. "." .. tostring(Detail) end
        end
    end

    -- Ordered seat containers are a useful fallback when the Blueprint does not
    -- expose Driver directly. Seat 0 / first seat is the driver; later seats are
    -- explicitly rejected. We do not make this assumption for generic Passengers.
    for _, Name in ipairs({"Seats", "SeatOccupants"}) do
        local Value = nil
        pcall(function() Value = Unwrap(Vehicle[Name]) end)
        local Entries = ArrayValues(Value)
        for I, RawEntry in ipairs(Entries) do
            if I > 8 then break end
            local Entry = Unwrap(RawEntry)
            local Contains, Detail = WarthogSeatLikeValueContainsPawn(Entry, Pawn)
            if Contains then
                local Role, RoleDetail = WarthogSeatRoleFromObject(Entry)
                if Role ~= nil then
                    return Role, string.format("Vehicle.%s[%d].%s (%s)", Name, I, tostring(Detail), tostring(RoleDetail))
                end
                return I == 1,
                    string.format("Vehicle.%s[%d].%s ordered-seat fallback", Name, I, tostring(Detail))
            end
        end
    end

    return nil, "vehicle exposes no positive driver property"
end

function WarthogDriverChainProof(Chain)
    local SawDriver = false
    local Details = {}
    local Count = 0
    local LastText = ""

    for I, RawObject in ipairs(Chain or {}) do
        local Object = Unwrap(RawObject)
        local Text = WarthogObjectNameLower(Object)
        Count = I
        LastText = Text
        Details[#Details + 1] = string.format("%d:%s", I, WarthogRecolorClip(Text, 220))

        -- The gunner path travels through the
        -- separate BP_WarthogChaingunVehicleActor/Chaingun attachment before it
        -- reaches the main Warthog Hull. Never allow that path to recolor.
        if string.find(Text, "gunner", 1, true) ~= nil
            or string.find(Text, "passenger", 1, true) ~= nil
            or string.find(Text, "turretseat", 1, true) ~= nil
            or string.find(Text, "warthogchaingunvehicleactor", 1, true) ~= nil
            or string.find(Text, "chaingun", 1, true) ~= nil then
            return false, "attachment chain identifies gunner/passenger path", table.concat(Details, " -> ")
        end

        if string.find(Text, "driver", 1, true) ~= nil then SawDriver = true end
        local Role, RoleDetail = WarthogSeatRoleFromObject(Object)
        if Role ~= nil then
            return Role, "attachment chain seat role: " .. tostring(RoleDetail), table.concat(Details, " -> ")
        end
    end

    if SawDriver then
        return true, "attachment chain contains driver", table.concat(Details, " -> ")
    end

    -- Driver and passenger are both direct Spartan -> Warthog Hull attachments
    -- (depth 4). Do not treat depth 4 alone as driver proof. Resolve the direct
    -- seat by socket/local side so passenger input is rejected too.
    local DirectHull = Count > 0 and Count <= 4
        and string.find(LastText, "bp_warthogvehicleactor", 1, true) ~= nil
        and string.find(LastText, ".hull", 1, true) ~= nil
    if DirectHull then
        local SeatDriver, SeatRoute, SeatDiagnostic = WarthogDirectHullSeatProof(Chain)
        if SeatDriver ~= nil then
            return SeatDriver, SeatRoute, table.concat(Details, " -> ") .. " | " .. tostring(SeatDiagnostic)
        end
        return nil, SeatRoute, table.concat(Details, " -> ") .. " | " .. tostring(SeatDiagnostic)
    end

    if Count > 4
        and string.find(LastText, "bp_warthogvehicleactor", 1, true) ~= nil
        and string.find(LastText, ".hull", 1, true) ~= nil then
        return false, "indirect Warthog Hull attachment is not driver signature", table.concat(Details, " -> ")
    end

    return nil, "attachment chain has no driver signature", table.concat(Details, " -> ")
end

function WarthogFindDriverVehicleFast(PlayerIndex, FastOnly)
    local Controller = GetPlayer(PlayerIndex)
    if not IsValidObject(Controller) then return nil, "controller unavailable", nil end
    local Pawn = nil
    pcall(function() Pawn = Unwrap(Controller.Pawn) end)
    if not IsValidObject(Pawn) then return nil, "pawn unavailable", nil end

    -- Strong, very cheap direct driver hints first.
    for _, SourceInfo in ipairs({{Controller, "Controller"}, {Pawn, "Pawn"}}) do
        local Source = SourceInfo[1]
        local Label = SourceInfo[2]
        for _, Name in ipairs({"DrivingVehicle", "DrivenVehicle"}) do
            local Value = nil
            pcall(function() Value = Unwrap(Source[Name]) end)
            local Vehicle = WarthogResolveVehicleFromObject(Value)
            if IsValidObject(Vehicle) then
                return Vehicle, tostring(Label) .. "." .. tostring(Name) .. " (driver-specific)", Pawn
            end
        end
    end

    local Components = WarthogGetActorComponents(Pawn)
    local SeenIndices = {}

    local function InspectComponent(I)
        I = tonumber(I)
        if I == nil or I < 1 or I > #Components or SeenIndices[I] then return nil end
        SeenIndices[I] = true
        local Component = Unwrap(Components[I])
        if not IsValidObject(Component) then return nil end

        local Vehicle, Route, Chain = WarthogTraceAttachmentChain(Component, string.format("Pawn.Component[%d]", I))
        if not IsValidObject(Vehicle) then return nil end

        local PropertyDriver, PropertyRoute = WarthogDriverPropertyProof(Vehicle, Pawn)
        if PropertyDriver ~= nil then
            if PropertyDriver then WarthogDriverComponentIndexByPlayer[PlayerIndex] = I end
            return {
                Vehicle = PropertyDriver and Vehicle or nil,
                Route = tostring(Route) .. "; driverProof=" .. tostring(PropertyRoute),
                Pawn = Pawn, OccupiedVehicle = Vehicle, DriverState = PropertyDriver,
            }
        end

        local ChainDriver, ChainRoute, ChainText = WarthogDriverChainProof(Chain)
        if ChainDriver ~= nil then
            if ChainDriver then WarthogDriverComponentIndexByPlayer[PlayerIndex] = I end
            return {
                Vehicle = ChainDriver and Vehicle or nil,
                Route = tostring(Route) .. "; driverProof=" .. tostring(ChainRoute),
                Pawn = Pawn, OccupiedVehicle = Vehicle, DriverState = ChainDriver,
            }
        end

        return {
            Vehicle = nil,
            Route = tostring(Route) .. "; driver seat not proven",
            Pawn = Pawn, OccupiedVehicle = Vehicle, DriverState = nil,
        }
    end

    -- Hot path: use the last successful component first, then the proven 35 +/-
    -- neighborhood. This keeps ordinary on-foot input very cheap.
    local CandidateIndices = {}
    local CachedIndex = tonumber(WarthogDriverComponentIndexByPlayer[PlayerIndex])
    if CachedIndex ~= nil then CandidateIndices[#CandidateIndices + 1] = CachedIndex end
    for _, I in ipairs({35,34,36,33,37,32,38,31,39,30,40,29,41,28,42}) do
        CandidateIndices[#CandidateIndices + 1] = I
    end
    local FirstOccupiedResult = nil
    for _, I in ipairs(CandidateIndices) do
        local Result = InspectComponent(I)
        if Result ~= nil then
            if Result.DriverState == true and IsValidObject(Result.Vehicle) then
                return Result.Vehicle, Result.Route, Result.Pawn, Result.OccupiedVehicle, Result.DriverState
            end
            if FirstOccupiedResult == nil and IsValidObject(Result.OccupiedVehicle) then
                FirstOccupiedResult = Result
            end
            -- v1.9.0: do not reject the whole pawn just because one attached
            -- component is ambiguous/non-driver. Steam and WinGDK can expose a
            -- different component ordering for the same physical driver seat.
        end
    end

    -- Internal callers may still request the hot-window-only path. Public v1.9.0
    -- color-cycle input passes FastOnly=false because both Steam and WinGDK
    -- have demonstrated valid driver attachments outside this neighborhood.
    if FastOnly and FirstOccupiedResult == nil then
        return nil, "driver gate: no Warthog attachment in fast seat window", Pawn
    end

    -- Checkpoint reloads and platform builds can rebuild the pawn with a different component ordering.
    -- Recover by checking the remaining pawn components only; unlike the old slow
    -- fallback this NEVER enumerates every Warthog or reverse-scans vehicle children.
    local RecoveryStarted = os.clock()
    local MaxComponents = math.min(#Components, 96)
    for I = 1, MaxComponents do
        if not SeenIndices[I] then
            local Result = InspectComponent(I)
            if Result ~= nil then
                if Result.DriverState == true and IsValidObject(Result.Vehicle) then
                    local RecoveryMs = (os.clock() - RecoveryStarted) * 1000.0
                    Result.Route = tostring(Result.Route) .. string.format("; bounded component recovery %.2fms", RecoveryMs)
                    Log("VEHNET v1.9.0 DRIVER RECOVERY success P%d component=%d route=%s",
                        PlayerIndex, I, tostring(Result.Route))
                    return Result.Vehicle, Result.Route, Result.Pawn, Result.OccupiedVehicle, Result.DriverState
                end
                if FirstOccupiedResult == nil and IsValidObject(Result.OccupiedVehicle) then
                    FirstOccupiedResult = Result
                end
            end
        end
    end

    local RecoveryMs = (os.clock() - RecoveryStarted) * 1000.0
    local Detail = FirstOccupiedResult and tostring(FirstOccupiedResult.Route) or "no Warthog attachment found"
    return nil, string.format("driver gate: no positive driver proof after %d pawn components (%.2fms); first=%s",
        MaxComponents, RecoveryMs, Detail), Pawn
end

function WarthogResolveVehicleFromObject(Object)
    local Current = Unwrap(Object)
    for _ = 1, 6 do
        if not IsValidObject(Current) then return nil end
        if WarthogIsWarthogActor(Current) then return Current end

        local Next = nil
        pcall(function() Next = Unwrap(Current:GetOwner()) end)
        if not IsValidObject(Next) then pcall(function() Next = Unwrap(Current.Owner) end) end
        if not IsValidObject(Next) then pcall(function() Next = Unwrap(Current.AttachParent) end) end
        if not IsValidObject(Next) then pcall(function() Next = Unwrap(Current:GetAttachParent()) end) end
        if not IsValidObject(Next) then return nil end
        Current = Next
    end
    return nil
end

function WarthogGetActorComponents(Actor)
    if not IsValidObject(Actor) then return {} end
    local ActorComponentClass = nil
    pcall(function() ActorComponentClass = StaticFindObject("/Script/Engine.ActorComponent") end)
    if not IsValidObject(ActorComponentClass) then return {} end
    local Components = nil
    local Ok = pcall(function() Components = Actor:K2_GetComponentsByClass(ActorComponentClass) end)
    if not Ok or Components == nil then
        pcall(function() Components = Actor:GetComponentsByClass(ActorComponentClass) end)
    end
    return ArrayValues(Components)
end

function WarthogSeatLikeValueContainsPawn(Value, Pawn)
    Value = Unwrap(Value)
    if Value == nil then return false end
    if IsValidObject(Value) and WarthogSameObject(Value, Pawn) then return true, "direct pawn" end

    for I, RawEntry in ipairs(ArrayValues(Value)) do
        if I > 16 then break end
        local Entry = Unwrap(RawEntry)
        if IsValidObject(Entry) and WarthogSameObject(Entry, Pawn) then
            return true, string.format("array[%d] pawn", I)
        end
        if Entry ~= nil then
            for _, Name in ipairs({"Pawn", "Character", "Occupant", "PlayerPawn", "Passenger", "Driver", "Gunner"}) do
                local Candidate = nil
                pcall(function() Candidate = Unwrap(Entry[Name]) end)
                if WarthogSameObject(Candidate, Pawn) then
                    return true, string.format("array[%d].%s", I, tostring(Name))
                end
            end
        end
    end

    for _, Name in ipairs({"Pawn", "Character", "Occupant", "PlayerPawn", "Passenger", "Driver", "Gunner"}) do
        local Candidate = nil
        pcall(function() Candidate = Unwrap(Value[Name]) end)
        if WarthogSameObject(Candidate, Pawn) then return true, tostring(Name) end
    end
    return false
end

function WarthogHybridRemotePeerAvailable()
    local Candidates = {}
    pcall(function() Candidates = VehicleMessageCachedRemoteControllerCandidates() or {} end)
    for I, Controller in ipairs(Candidates) do
        if I > 8 then break end
        if IsValidObject(Controller) then return true end
    end
    return false
end

function WarthogHybridPersistentLevelPrefix(Object)
    local Name = tostring(SafeFullName(Object) or "")
    return string.match(Name, "^(.-:PersistentLevel)") or ""
end

function WarthogHybridSamePersistentLevel(A, B)
    local APrefix = WarthogHybridPersistentLevelPrefix(A)
    local BPrefix = WarthogHybridPersistentLevelPrefix(B)
    return APrefix ~= "" and APrefix == BPrefix
end

function WarthogHybridComponentDriverProof(Component, Pawn, Controller)
    if not IsValidObject(Component) then return nil, "invalid component" end

    local ContainsPawn, PawnDetail = WarthogSeatLikeValueContainsPawn(Component, Pawn)
    local ContainsController = false
    local ControllerDetail = ""
    for _, Name in ipairs({"Controller", "PlayerController", "OwningController", "DriverController"}) do
        local Candidate = nil
        pcall(function() Candidate = Unwrap(Component[Name]) end)
        if WarthogSameObject(Candidate, Controller) then
            ContainsController = true
            ControllerDetail = tostring(Name)
            break
        end
    end

    if not ContainsPawn and not ContainsController then return nil, "component has no P2 reference" end
    local Role, RoleDetail = WarthogSeatRoleFromObject(Component)
    if Role ~= nil then
        return Role, string.format("%s; %s; %s",
            tostring(PawnDetail or ""), tostring(ControllerDetail), tostring(RoleDetail))
    end

    local Name = WarthogObjectNameLower(Component)
    if string.find(Name, "driver", 1, true) then
        return true, "component name identifies driver with exact P2 reference"
    end
    if string.find(Name, "gunner", 1, true) or string.find(Name, "passenger", 1, true) or
       string.find(Name, "turret", 1, true) then
        return false, "component name identifies non-driver seat"
    end
    return nil, "P2 reference found but component role unresolved"
end

function WarthogHybridProveDriverVehicle(Vehicle, Pawn, Controller)
    if not IsValidObject(Vehicle) or not IsValidObject(Pawn) or not IsValidObject(Controller) then
        return false, "invalid candidate/P2"
    end
    if not WarthogHybridSamePersistentLevel(Vehicle, Pawn) then
        return false, "different PersistentLevel"
    end

    local PropertyDriver, PropertyRoute = WarthogDriverPropertyProof(Vehicle, Pawn)
    if PropertyDriver == true then return true, "property: " .. tostring(PropertyRoute) end
    if PropertyDriver == false then return false, "property rejects: " .. tostring(PropertyRoute) end

    local Components = WarthogGetActorComponents(Vehicle)
    local MaxComponents = math.min(#Components, 128)
    for I = 1, MaxComponents do
        local Role, Detail = WarthogHybridComponentDriverProof(Unwrap(Components[I]), Pawn, Controller)
        if Role == true then
            return true, string.format("vehicle component[%d]: %s", I, tostring(Detail))
        end
        if Role == false then
            return false, string.format("vehicle component[%d] rejects P2: %s", I, tostring(Detail))
        end
    end
    return false, string.format("no positive P2 driver proof in %d vehicle components", MaxComponents)
end

function WarthogFindHybridDriverVehicleP2()
    local PlayerIndex = 2
    local Controller = GetPlayer(PlayerIndex)
    if not IsValidObject(Controller) then return nil, "P2 controller unavailable" end
    local Pawn = nil
    pcall(function() Pawn = Unwrap(Controller.Pawn) end)
    if not IsValidObject(Pawn) then return nil, "P2 pawn unavailable" end
    if not WarthogHybridRemotePeerAvailable() then
        return nil, "hybrid recovery ineligible: no cached valid remote peer"
    end

    -- A successful candidate stays cheap: re-prove it before every explicit use.
    if IsValidObject(WarthogHybridDriverVehicleP2) then
        local Proved, Route = WarthogHybridProveDriverVehicle(WarthogHybridDriverVehicleP2, Pawn, Controller)
        if Proved then return WarthogHybridDriverVehicleP2, "cached hybrid proof: " .. tostring(Route) end
        WarthogHybridDriverVehicleP2 = nil
    end

    local Generation = tonumber(WarthogColorRuntimeGeneration) or 0
    if WarthogHybridDriverAttemptGeneration == Generation then
        return nil, "hybrid recovery already attempted this runtime generation"
    end
    WarthogHybridDriverAttemptGeneration = Generation

    if WarthogHybridDriverSnapshotGeneration ~= Generation then
        WarthogHybridDriverSnapshotGeneration = Generation
        WarthogHybridDriverSnapshot = {}
        local Found = nil
        pcall(function() Found = FindAllOf("BP_WarthogVehicleActor_C") end)
        for _, RawVehicle in ipairs(Found or {}) do
            if #WarthogHybridDriverSnapshot >= 48 then break end
            local Vehicle = Unwrap(RawVehicle)
            if IsValidObject(Vehicle) then
                local Name = tostring(SafeFullName(Vehicle) or "")
                if not string.find(Name, "Default__", 1, true) and WarthogHybridSamePersistentLevel(Vehicle, Pawn) then
                    WarthogHybridDriverSnapshot[#WarthogHybridDriverSnapshot + 1] = Vehicle
                end
            end
        end
        Log("VEHNET v1.9.0 HYBRID DRIVER one-shot Warthog snapshot generation=%d candidates=%d",
            Generation, #WarthogHybridDriverSnapshot)
    end

    for I, Vehicle in ipairs(WarthogHybridDriverSnapshot) do
        if I > 48 then break end
        if IsValidObject(Vehicle) then
            local Proved, Route = WarthogHybridProveDriverVehicle(Vehicle, Pawn, Controller)
            if Proved then
                WarthogHybridDriverVehicleP2 = Vehicle
                Log("VEHNET v1.9.0 HYBRID DRIVER recovery success P2 route=%s", tostring(Route))
                return Vehicle, "hybrid snapshot: " .. tostring(Route)
            end
        end
    end

    return nil, "hybrid recovery found no positively-proven P2 driver vehicle"
end

function WarthogVehicleToken(Vehicle)
    local Text = tostring(SafeFullName(Vehicle) or SafeToString(Vehicle) or "")
    local Token = string.match(Text, "(BP_WarthogVehicleActor_C_[%w_%-]+)")
    if Token ~= nil and Token ~= "" then return Token end
    local FNameValue = nil
    pcall(function() FNameValue = Vehicle:GetFName():ToString() end)
    if FNameValue ~= nil and tostring(FNameValue) ~= "" then return tostring(FNameValue) end
    return Text
end

function WarthogMIDDamageMaskMatchesVehicle(MID, VehicleToken)
    local Values = nil
    pcall(function() Values = MID.TextureParameterValues end)
    local TokenLower = string.lower(tostring(VehicleToken or ""))
    if TokenLower == "" then return false end
    for _, RawEntry in ipairs(ArrayValues(Values)) do
        local Entry = Unwrap(RawEntry)
        local Value = nil
        pcall(function() Value = Unwrap(Entry.ParameterValue) end)
        local ValueText = string.lower(tostring(SafeFullName(Value) or SafeToString(Value) or ""))
        if string.find(ValueText, TokenLower, 1, true) ~= nil then
            return true, WarthogRecolorParameterName(Entry), ValueText
        end
    end
    return false
end

function WarthogPaintLayerInfoCount(Parent)
    if not IsValidObject(Parent) then return 0 end
    local Values = nil
    local Ok = pcall(function() Values = Parent.VectorParameterValues end)
    if not Ok or Values == nil then return 0 end
    local Found = { ["Color Top"]=false, ["Color Mid"]=false, ["Color Bottom"]=false }
    local Count = 0
    for _, RawEntry in ipairs(ArrayValues(Values)) do
        local Entry = Unwrap(RawEntry)
        local _, Name, Association, Index = WarthogRecolorParameterInfoFields(Entry)
        local NameText = tostring(SafeToString(Name))
        if Found[NameText] ~= nil
            and tonumber(SafeToString(Association)) == 0
            and tonumber(SafeToString(Index)) == 1
            and not Found[NameText] then
            Found[NameText] = true
            Count = Count + 1
        end
    end
    return Count
end

function WarthogDesiredPaintParentKind(Parent)
    local Lower = WarthogObjectNameLower(Parent)
    if string.find(Lower, "/mi_warthog_greenhull.mi_warthog_greenhull", 1, true) ~= nil then
        return "GreenHull"
    end
    if string.find(Lower, "/mip_warthog_default.mip_warthog_default", 1, true) ~= nil then
        return "DefaultPaint"
    end
    return nil
end

function WarthogIsDynamicMaterial(Object)
    Object = Unwrap(Object)
    if not IsValidObject(Object) then return false end
    local Class = nil
    pcall(function() Class = Unwrap(Object:GetClass()) end)
    local Text = string.lower(tostring(SafeFullName(Class) or SafeToString(Class) or ""))
    return string.find(Text, "materialinstancedynamic", 1, true) ~= nil
end

function WarthogMaterialParent(Material)
    Material = Unwrap(Material)
    if not IsValidObject(Material) then return nil end
    local Parent = nil
    pcall(function() Parent = Unwrap(Material.Parent) end)
    if IsValidObject(Parent) and not WarthogSameObject(Parent, Material) then return Parent end
    return nil
end

function WarthogPaintInfoSourceInChain(Material)
    local Current = Unwrap(Material)
    local Seen = {}
    local AnyWarthog = false
    local Chain = {}

    for _ = 1, 10 do
        if not IsValidObject(Current) then break end
        local Key = tostring(SafeFullName(Current) or SafeToString(Current) or "")
        if Seen[Key] then break end
        Seen[Key] = true
        local Lower = string.lower(Key)
        Chain[#Chain + 1] = Key

        if string.find(Lower, "warthog", 1, true) ~= nil then AnyWarthog = true end
        local Excluded = string.find(Lower, "warthog_tires", 1, true) ~= nil
            or string.find(Lower, "warthog_fender", 1, true) ~= nil
            or string.find(Lower, "warthog_subframe", 1, true) ~= nil
        if Excluded then
            return nil, nil, table.concat(Chain, " -> "), AnyWarthog, "excluded material family"
        end

        local Top = WarthogRecolorFindLayerInfo(Current, "Color Top")
        local Mid = WarthogRecolorFindLayerInfo(Current, "Color Mid")
        local Bottom = WarthogRecolorFindLayerInfo(Current, "Color Bottom")
        if Top ~= nil and Mid ~= nil and Bottom ~= nil then
            if AnyWarthog then
                return Current, { Top=Top, Mid=Mid, Bottom=Bottom }, table.concat(Chain, " -> "), true, "paint layer found"
            end
            return nil, nil, table.concat(Chain, " -> "), false, "paint layer is not Warthog-scoped"
        end

        Current = WarthogMaterialParent(Current)
    end
    return nil, nil, table.concat(Chain, " -> "), AnyWarthog, "no complete layer-1 paint set"
end

function WarthogComponentMaterialSlots(Component)
    local Output = {}
    if not IsValidObject(Component) then return Output end

    local Count = nil
    pcall(function() Count = tonumber(Component:GetNumMaterials()) end)
    if Count ~= nil and Count > 0 and Count < 64 then
        for Slot = 0, Count - 1 do
            local Material = nil
            pcall(function() Material = Unwrap(Component:GetMaterial(Slot)) end)
            if IsValidObject(Material) then
                Output[#Output + 1] = { Slot=Slot, Material=Material }
            end
        end
        return Output
    end

    local Materials = nil
    pcall(function() Materials = Component:GetMaterials() end)
    for I, RawMaterial in ipairs(ArrayValues(Materials)) do
        local Material = Unwrap(RawMaterial)
        if IsValidObject(Material) then
            Output[#Output + 1] = { Slot=I - 1, Material=Material }
        end
    end
    return Output
end

function WarthogCreateDynamicPaintMID(Component, Slot, SourceMaterial)
    if not IsValidObject(Component) or not IsValidObject(SourceMaterial) then
        return nil, "component/source invalid"
    end
    if WarthogIsDynamicMaterial(SourceMaterial) then return SourceMaterial, "already dynamic" end

    local MID = nil
    local Errors = {}
    local Ok, Err = pcall(function()
        MID = Unwrap(Component:CreateDynamicMaterialInstance(Slot, SourceMaterial, FName("WarthogColorMID")))
    end)
    if not Ok then Errors[#Errors + 1] = "CreateDynamicMaterialInstance(3): " .. tostring(Err) end

    if not IsValidObject(MID) then
        Ok, Err = pcall(function()
            MID = Unwrap(Component:CreateAndSetMaterialInstanceDynamicFromMaterial(Slot, SourceMaterial))
        end)
        if not Ok then Errors[#Errors + 1] = "CreateMIDFromMaterial: " .. tostring(Err) end
    end

    if not IsValidObject(MID) then
        Ok, Err = pcall(function()
            MID = Unwrap(Component:CreateAndSetMaterialInstanceDynamic(Slot))
        end)
        if not Ok then Errors[#Errors + 1] = "CreateMID: " .. tostring(Err) end
    end

    if IsValidObject(MID) then return MID, "created dynamic slot material" end
    return nil, table.concat(Errors, " | ")
end

function WarthogActorAttachedToVehicle(Actor, Vehicle)
    if not IsValidObject(Actor) or not IsValidObject(Vehicle) then return false end
    local ParentActor = nil
    pcall(function() ParentActor = Unwrap(Actor:GetAttachParentActor()) end)
    local Resolved = WarthogResolveVehicleFromObject(ParentActor)
    if IsValidObject(Resolved) and WarthogSameObject(Resolved, Vehicle) then return true end

    local Root = nil
    pcall(function() Root = Unwrap(Actor.RootComponent) end)
    local Found = nil
    pcall(function() Found = WarthogFindFromAttachChain(Root, "Accessory.RootComponent") end)
    return IsValidObject(Found) and WarthogSameObject(Found, Vehicle)
end

function WarthogComponentMeshAssetText(Component)
    Component = Unwrap(Component)
    if not IsValidObject(Component) then return "" end

    local Asset = nil
    pcall(function() Asset = Unwrap(Component:GetStaticMesh()) end)
    if not IsValidObject(Asset) then pcall(function() Asset = Unwrap(Component.StaticMesh) end) end
    if not IsValidObject(Asset) then pcall(function() Asset = Unwrap(Component:GetSkeletalMeshAsset()) end) end
    if not IsValidObject(Asset) then pcall(function() Asset = Unwrap(Component.SkeletalMesh) end) end
    if not IsValidObject(Asset) then return "" end
    return tostring(SafeFullName(Asset) or SafeToString(Asset) or "")
end

function WarthogComponentHasTireMaterial(Component)
    if not IsValidObject(Component) then return false end
    for _, Entry in ipairs(WarthogComponentMaterialSlots(Component)) do
        local Material = Unwrap(Entry.Material)
        if IsValidObject(Material) then
            -- Restart Mission can preserve the slot's dynamic MID while our
            -- world-local role cache is intentionally cleared. Inspect the
            -- authored parent so a wheel assembly is still recognizable.
            local NameMaterial = Material
            if WarthogIsDynamicMaterial(Material) then
                local Parent = WarthogMaterialParent(Material)
                if IsValidObject(Parent) then NameMaterial = Parent end
            end
            local Lower = string.lower(tostring(SafeFullName(NameMaterial) or SafeToString(NameMaterial) or ""))
            if string.find(Lower, "mi_warthog_tires", 1, true) ~= nil
                or string.find(Lower, "mid_mi_warthog_tires", 1, true) ~= nil then
                return true
            end
        end
    end
    return false
end

function WarthogAccessoryMaterialRole(ScopeLabel, Component, Material)
    -- Checkpoint/restart may preserve an already-created dynamic MID while the
    -- world-local role map is cleared. Classify such MIDs by their authored
    -- parent so turret and wheel/interior paint roles can be rebuilt safely.
    local RoleMaterial = Unwrap(Material)
    if IsValidObject(RoleMaterial) and WarthogIsDynamicMaterial(RoleMaterial) then
        local Parent = WarthogMaterialParent(RoleMaterial)
        if IsValidObject(Parent) then RoleMaterial = Parent end
    end
    local MaterialText = tostring(SafeFullName(RoleMaterial) or SafeToString(RoleMaterial) or "")
    local Lower = string.lower(MaterialText)
    local MeshText = ""
    local MeshLower = ""
    local MeshLoaded = false
    local function EnsureMesh()
        if not MeshLoaded then
            MeshText = WarthogComponentMeshAssetText(Component)
            MeshLower = string.lower(MeshText)
            MeshLoaded = true
        end
    end

    if tostring(ScopeLabel) == "chaingun" then
        -- Release mapping verified in-game:
        --   * Shield Panel layer 2: paint
        --   * Mount_Barrel layer 2: paint (large lower cylinder)
        --   * actual gun barrel layer 2: paint (tip + small rings only)
        --   * main Shield mesh: hardware/rear assembly in this asset, do not paint
        --   * Mount: handles/feed/pivot hardware, do not paint
        --   * default skeletal turret core: do not paint
        if string.find(Lower, "mi_warthogturret_barrel", 1, true) ~= nil then
            return "TurretBarrelRingPaint", "paint actual gun barrel layer 2 only (tip/rings)", MeshText
        end

        if string.find(Lower, "mi_warthogturret_shield", 1, true) ~= nil then
            EnsureMesh()
            if string.find(MeshLower, "sm_warthog_chaingun_shield_panel", 1, true) ~= nil then
                return "TurretShieldPanel", "paint mesh: shield panel layer 2", MeshText
            end
            if string.find(MeshLower, "sm_warthog_chaingun_shield", 1, true) ~= nil then
                return nil, "excluded rear/main shield assembly proven hardware", MeshText
            end
            return nil, "shield material on unknown mesh", MeshText
        end

        if string.find(Lower, "mi_warthogturret_mount", 1, true) ~= nil then
            EnsureMesh()
            if string.find(MeshLower, "sm_warthog_chaingun_mount_barrel", 1, true) ~= nil then
                return "TurretMountBarrelPaint", "paint mesh: mount barrel layer 2", MeshText
            end
            if string.find(MeshLower, "sm_warthog_chaingun_mount", 1, true) ~= nil then
                return nil, "excluded mount handles/feed/pivot-cylinder hardware", MeshText
            end
            return nil, "mount material on unknown mesh", MeshText
        end

        if string.find(Lower, "mip_warthogturret_default", 1, true) ~= nil then
            return nil, "excluded skeletal/default turret core hardware", MeshText
        end
        return nil, "not a selected turret paint family", MeshText
    end

    if tostring(ScopeLabel) == "vehicle" then
        -- Inner wheel/rim olive insert. This material is also named for shocks,
        -- so only accept it on a component that also owns the proven tire slot.
        -- That scopes the recolor to actual wheel assemblies instead of every
        -- InteriorWheelsShocks occurrence on the vehicle.
        if string.find(Lower, "mi_warthog_interiorwheelsshocks", 1, true) ~= nil then
            EnsureMesh()
            if WarthogComponentHasTireMaterial(Component) then
                return "WheelInteriorPaint", "wheel interior material paired with tire slot", MeshText
            end
            -- This same family also owns the remaining olive interior piece
            -- behind the steering wheel. Recolor only its olive
            -- Color Top/Mid/Bottom entries, never the tire material itself.
            return "VehicleInteriorPaint", "proven olive interior piece behind steering wheel", MeshText
        end

        -- Keep the side-can route conservative. It is not part of this mapping
        -- pass, but exact fuel/jerry-can mesh names are safe to accept if found.
        if string.find(Lower, "mi_warthog_enginelightshardware", 1, true) == nil then
            return nil, "not selected vehicle accessory hardware", MeshText
        end
        EnsureMesh()
        local IsCan =
            string.find(MeshLower, "jerry", 1, true) ~= nil or
            string.find(MeshLower, "fuelcan", 1, true) ~= nil or
            string.find(MeshLower, "fuel_can", 1, true) ~= nil or
            string.find(MeshLower, "gascan", 1, true) ~= nil or
            string.find(MeshLower, "gas_can", 1, true) ~= nil or
            string.find(MeshLower, "canister", 1, true) ~= nil
        if IsCan then return "SideCan", "exact mesh-name side-can match", MeshText end
        return nil, "EngineLightsHardware but mesh is not exact fuel-can match", MeshText
    end

    return nil, "unknown scope", MeshText
end

function WarthogAccessoryMIDKey(MID)
    return tostring(SafeFullName(MID) or SafeToString(MID) or "")
end

function WarthogAccessoryRoleForMID(MID)
    local Key = WarthogAccessoryMIDKey(MID)
    if Key == "" then return nil end
    return WarthogAccessoryRoleByMID[Key]
end

function WarthogAccessoriesReady(MIDs)
    local Roles = {}
    for _, RawMID in ipairs(MIDs or {}) do
        local Role = WarthogAccessoryRoleForMID(Unwrap(RawMID))
        if type(Role) == "string" then Roles[Role] = true end
    end
    -- These four roles are present on the standard Warthog and are enough to
    -- declare the delayed accessory pass complete. VehicleInteriorPaint is an
    -- optional tiny olive cockpit piece; include it whenever discovered, but do
    -- not keep rescanning the world just because a particular Warthog lacks it.
    return Roles.TurretBarrelRingPaint == true
        and Roles.TurretShieldPanel == true
        and Roles.TurretMountBarrelPaint == true
        and Roles.WheelInteriorPaint == true
end

function WarthogCollectAttachedPaintMIDs(Vehicle, ExistingMIDs)
    local Added = {}
    local Seen = {}
    for _, MID in ipairs(ExistingMIDs or {}) do
        Seen[tostring(SafeFullName(MID) or SafeToString(MID) or "")] = true
    end

    -- Only inspect the proven vehicle/turret material families. This avoids the
    -- broad development pass that promoted unrelated Warthog slots and caused
    -- large first-use stalls.
    local Scopes = { { Actor=Vehicle, Label="vehicle" } }
    local Actors = nil
    pcall(function() Actors = FindAllOf("BP_WarthogChaingunVehicleActor_C") end)
    for _, RawActor in ipairs(ArrayValues(Actors)) do
        local Actor = Unwrap(RawActor)
        if IsValidObject(Actor) and WarthogActorAttachedToVehicle(Actor, Vehicle) then
            Scopes[#Scopes + 1] = { Actor=Actor, Label="chaingun" }
        end
    end

    for _, Scope in ipairs(Scopes) do
        for _, RawComponent in ipairs(WarthogGetActorComponents(Scope.Actor)) do
            local Component = Unwrap(RawComponent)
            if IsValidObject(Component) then
                for _, Entry in ipairs(WarthogComponentMaterialSlots(Component)) do
                    local Material = Unwrap(Entry.Material)
                    local Slot = tonumber(Entry.Slot) or 0
                    if IsValidObject(Material) then
                        local Role, _, MeshText = WarthogAccessoryMaterialRole(Scope.Label, Component, Material)
                        if Role ~= nil then
                            local MaterialKey = tostring(SafeFullName(Material) or SafeToString(Material) or "")

                            -- A Restart Mission may keep the existing WarthogColorMID
                            -- alive but clears WarthogAccessoryRoleByMID because UObject
                            -- references are world-local. Rebuild the role immediately
                            -- from the MID's parent even if this MID is already in Seen.
                            if WarthogIsDynamicMaterial(Material) and MaterialKey ~= "" then
                                WarthogAccessoryRoleByMID[MaterialKey] = Role
                            end

                            if not Seen[MaterialKey] then
                                local MID, CreateInfo = WarthogCreateDynamicPaintMID(Component, Slot, Material)
                                if IsValidObject(MID) then
                                    local MIDKey = tostring(SafeFullName(MID) or SafeToString(MID) or "")
                                    if MIDKey ~= "" then WarthogAccessoryRoleByMID[MIDKey] = Role end
                                    if not Seen[MIDKey] then
                                        Seen[MIDKey] = true
                                        Added[#Added + 1] = MID
                                    end
                                else
                                    Log("WARTHOG COLOR accessory material setup failed role=%s scope=%s slot=%d mesh=%s reason=%s",
                                        tostring(Role), tostring(Scope.Label), Slot,
                                        WarthogRecolorClip(MeshText, 500), tostring(CreateInfo))
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    return Added
end

function WarthogInvalidateVehiclePaintCache(Key, Reason)
    WarthogPaintMIDCacheByVehicle[Key] = nil
    WarthogPaintApplyPlanCacheByVehicle[Key] = nil
    -- Keep WarthogColorIndexByVehicle: an invalid MID is a runtime-cache problem,
    -- not a request to reset the selected paint state.
end

function WarthogCachedPaintMIDs(Vehicle)
    local Key = WarthogVehicleToken(Vehicle)
    local CachedEntry = WarthogPaintMIDCacheByVehicle[Key]
    if type(CachedEntry) ~= "table" then return nil end

    -- New cache shape keeps the actor identity next to its MIDs. This prevents
    -- a stale valid UObject/MID set from being reused if Unreal ever recycles an
    -- actor token after restart/travel, and makes multi-Warthog state explicit.
    local CachedVehicle = CachedEntry.Vehicle
    local Cached = CachedEntry.MIDs
    if not IsValidObject(CachedVehicle) or not WarthogSameObject(CachedVehicle, Vehicle) then
        WarthogInvalidateVehiclePaintCache(Key, "vehicle identity changed")
        return nil
    end
    if type(Cached) ~= "table" or #Cached == 0 then
        WarthogInvalidateVehiclePaintCache(Key, "empty MID cache")
        return nil
    end

    local Valid = {}
    for _, MID in ipairs(Cached) do
        if IsValidObject(MID) then Valid[#Valid + 1] = MID end
    end
    if #Valid == #Cached and #Valid > 0 then
        return Valid, CachedEntry.AccessoryPending == true
    end
    WarthogInvalidateVehiclePaintCache(Key, "cached MID invalid")
    return nil
end

-- Build one world-local lookup of the proven body-paint MIDs once per runtime
-- generation and index already-live Warthogs by DamageMaskRT.
function WarthogMIDDamageMaskVehicleToken(MID)
    local Values = nil
    pcall(function() Values = MID.TextureParameterValues end)
    for _, RawEntry in ipairs(ArrayValues(Values)) do
        local Entry = Unwrap(RawEntry)
        local Value = nil
        pcall(function() Value = Unwrap(Entry.ParameterValue) end)
        local ValueText = tostring(SafeFullName(Value) or SafeToString(Value) or "")
        local Token = string.match(ValueText, "(BP_WarthogVehicleActor_C_[%w_%-]+)")
        if Token ~= nil and Token ~= "" then return Token end
    end
    return nil
end

function WarthogBuildBodyPaintMIDIndex(ForceRefresh)
    if WarthogBodyPaintMIDIndexBuilt and not ForceRefresh then
        return WarthogBodyPaintMIDIndexByVehicle, "cached world body index"
    end

    local Objects = nil
    local Ok, Err = pcall(function() Objects = FindAllOf("MaterialInstanceDynamic") end)
    if not Ok or Objects == nil then
        return nil, "body MID index unavailable: " .. tostring(Err)
    end

    local Started = os.clock()
    local Index = {}
    local Scanned, Candidates, Indexed = 0, 0, 0
    for _, RawObject in ipairs(Objects) do
        local Object = Unwrap(RawObject)
        if IsValidObject(Object) then
            Scanned = Scanned + 1
            local Full = tostring(SafeFullName(Object) or SafeToString(Object) or "")
            local Lower = string.lower(Full)
            local NameCandidate =
                string.find(Lower, "mid_mi_warthog_greenhull_", 1, true) ~= nil or
                string.find(Lower, "mid_mip_warthog_default_", 1, true) ~= nil
            if NameCandidate then
                Candidates = Candidates + 1
                local Parent = nil
                pcall(function() Parent = Unwrap(Object.Parent) end)
                local Kind = WarthogDesiredPaintParentKind(Parent)
                local Token = Kind ~= nil and WarthogMIDDamageMaskVehicleToken(Object) or nil
                if Kind ~= nil and Token ~= nil then
                    Index[Token] = Index[Token] or {}
                    if not IsValidObject(Index[Token][Kind]) then
                        Index[Token][Kind] = Object
                        Indexed = Indexed + 1
                    end
                end
            end
        end
    end
    WarthogBodyPaintMIDIndexByVehicle = Index
    WarthogBodyPaintMIDIndexBuilt = true
    local VehicleCount = 0
    for _ in pairs(Index) do VehicleCount = VehicleCount + 1 end
    local ElapsedMs = (os.clock() - Started) * 1000.0
    return Index, string.format("new world body index scanned=%d indexed=%d elapsed=%.2fms", Scanned, Indexed, ElapsedMs)
end

function WarthogFindPaintMIDsForVehicle(Vehicle)
    local Token = WarthogVehicleToken(Vehicle)
    local Cached, AccessoryPending = WarthogCachedPaintMIDs(Vehicle)
    if Cached ~= nil then
        if AccessoryPending then
            local Added = WarthogCollectAttachedPaintMIDs(Vehicle, Cached)
            for _, MID in ipairs(Added or {}) do Cached[#Cached + 1] = MID end
            local Entry = WarthogPaintMIDCacheByVehicle[Token]
            if type(Entry) == "table" then
                Entry.MIDs = Cached
                Entry.AccessoryPending = not WarthogAccessoriesReady(Cached)
            end
            if #(Added or {}) > 0 and WarthogExtendPaintApplyPlanWithMIDs ~= nil then
                WarthogExtendPaintApplyPlanWithMIDs(Vehicle, Added)
            end
            return Cached, string.format("cached selected paint MIDs=%d accessoryPending=%s retryAdded=%d",
                #Cached, tostring(type(Entry) == "table" and Entry.AccessoryPending == true), #(Added or {}))
        end
        return Cached, string.format("cached selected paint MIDs=%d", #Cached)
    end

    local BodyIndex, IndexRoute = WarthogBuildBodyPaintMIDIndex(false)
    if BodyIndex == nil then return {}, tostring(IndexRoute) end
    local BodyEntry = BodyIndex[Token]
    if type(BodyEntry) ~= "table" then
        -- The world index may have been built before this vehicle spawned.
        BodyIndex, IndexRoute = WarthogBuildBodyPaintMIDIndex(true)
        BodyEntry = type(BodyIndex) == "table" and BodyIndex[Token] or nil
    end

    local PaintMIDs = {}
    local FoundKinds = {}
    if type(BodyEntry) == "table" then
        for _, Kind in ipairs({"DefaultPaint", "GreenHull"}) do
            local Object = Unwrap(BodyEntry[Kind])
            if IsValidObject(Object) then
                local Matches = WarthogMIDDamageMaskMatchesVehicle(Object, Token)
                local Parent = nil
                pcall(function() Parent = Unwrap(Object.Parent) end)
                local PaintInfoCount = WarthogPaintLayerInfoCount(Parent)
                if Matches and WarthogDesiredPaintParentKind(Parent) == Kind and PaintInfoCount == 3 then
                    FoundKinds[Kind] = true
                    PaintMIDs[#PaintMIDs + 1] = Object
                end
            end
        end
    end

    local AttachedPaintMIDs = WarthogCollectAttachedPaintMIDs(Vehicle, PaintMIDs)
    for _, MID in ipairs(AttachedPaintMIDs or {}) do PaintMIDs[#PaintMIDs + 1] = MID end

    local Pending = not WarthogAccessoriesReady(PaintMIDs)
    if #PaintMIDs > 0 then
        WarthogPaintMIDCacheByVehicle[Token] = {
            Vehicle=Vehicle, MIDs=PaintMIDs, AccessoryPending=Pending,
        }
    end
    return PaintMIDs, string.format(
        "selected paint materials=%d accessory=%d pending=%s body=%s defaultPaint=%s; %s",
        #PaintMIDs, #(AttachedPaintMIDs or {}), tostring(Pending),
        tostring(FoundKinds.GreenHull == true), tostring(FoundKinds.DefaultPaint == true), tostring(IndexRoute))
end

function WarthogPaintInfosForParent(Parent)
    if not IsValidObject(Parent) then return nil end
    local Key = tostring(SafeFullName(Parent) or SafeToString(Parent) or "")
    local Cached = WarthogPaintInfoCacheByParent[Key]
    if type(Cached) == "table" and Cached.Top ~= nil and Cached.Mid ~= nil and Cached.Bottom ~= nil then
        return Cached
    end

    -- Accessory MICs can inherit the actual layer ParameterInfo structs from a
    -- Warthog material ancestor. Use the first complete layer-1 paint set in
    -- the parent chain; the MID can still override those exact infos.
    local Source, Infos = WarthogPaintInfoSourceInChain(Parent)
    if Source ~= nil and type(Infos) == "table"
        and Infos.Top ~= nil and Infos.Mid ~= nil and Infos.Bottom ~= nil then
        WarthogPaintInfoCacheByParent[Key] = Infos
        return Infos
    end
    return nil
end

function WarthogUsesExpandedAccessoryColorInfos(Parent)
    local Lower = string.lower(tostring(SafeFullName(Parent) or SafeToString(Parent) or ""))
    return string.find(Lower, "warthogturret", 1, true) ~= nil
        or string.find(Lower, "mi_warthog_enginelightshardware", 1, true) ~= nil
end

-- Build a per-vehicle apply plan once, then color changes only execute the
-- minimum SetVectorParameterValueByInfo calls. Parent parameter discovery is
-- cached so normal color changes do not re-walk material ancestry.
function WarthogCopyLinearColor(Value)
    Value = Unwrap(Value)
    if Value == nil then return nil end
    local R, G, B, A = nil, nil, nil, nil
    pcall(function() R = tonumber(SafeToString(Unwrap(Value.R))) end)
    pcall(function() G = tonumber(SafeToString(Unwrap(Value.G))) end)
    pcall(function() B = tonumber(SafeToString(Unwrap(Value.B))) end)
    pcall(function() A = tonumber(SafeToString(Unwrap(Value.A))) end)
    if R == nil or G == nil or B == nil then return nil end
    return { R=R, G=G, B=B, A=A or 1.0 }
end

function VehiclePaintStableAuthoredMaterial(Material)
    local Current = Unwrap(Material)
    local LastValid = Current
    local Seen = {}
    for _ = 1, 12 do
        if not IsValidObject(Current) then break end
        local Key = tostring(SafeFullName(Current) or SafeToString(Current) or "")
        if Key == "" or Seen[Key] then break end
        Seen[Key] = true
        LastValid = Current
        if not WarthogIsDynamicMaterial(Current) then
            return Current, Key
        end
        local Parent = WarthogMaterialParent(Current)
        if not IsValidObject(Parent) then break end
        Current = Parent
    end
    local Key = tostring(SafeFullName(LastValid) or SafeToString(LastValid) or "")
    return LastValid, Key
end

function VehiclePaintOriginalSignature(Material, Role, Name, Association, Index)
    local _, MaterialKey = VehiclePaintStableAuthoredMaterial(Material)
    return table.concat({
        tostring(MaterialKey or ""),
        "role=" .. tostring(Role or "Paint"),
        tostring(Name or ""),
        tostring(Association or 0),
        tostring(Index or 0),
    }, "|")
end

function WarthogRememberAuthoredOriginal(Material, Role, Entry, Candidate)
    if type(Entry) ~= "table" then return WarthogCopyLinearColor(Candidate) end
    local Key = VehiclePaintOriginalSignature(
        Material, Role, Entry.Name, Entry.Association, Entry.Index)
    local Cached = WarthogOriginalColorValueCache[Key]
    if Cached ~= nil then return WarthogCopyLinearColor(Cached) end
    local Copy = WarthogCopyLinearColor(Candidate)
    if Copy ~= nil then
        WarthogOriginalColorValueCache[Key] = WarthogCopyLinearColor(Copy)
    end
    return Copy
end

function WarthogParentValueForInfo(Parent, NameText, AssociationWanted, IndexWanted)
    local Current = Unwrap(Parent)
    local SeenMaterials = {}
    for _ = 1, 10 do
        if not IsValidObject(Current) then break end
        local MaterialKey = tostring(SafeFullName(Current) or SafeToString(Current) or "")
        if SeenMaterials[MaterialKey] then break end
        SeenMaterials[MaterialKey] = true

        local Values = nil
        pcall(function() Values = Current.VectorParameterValues end)
        for _, RawEntry in ipairs(ArrayValues(Values)) do
            local Entry = Unwrap(RawEntry)
            local _, Name, Association, Index = WarthogRecolorParameterInfoFields(Entry)
            if tostring(SafeToString(Name)) == tostring(NameText)
                and tonumber(SafeToString(Association)) == tonumber(AssociationWanted)
                and tonumber(SafeToString(Index)) == tonumber(IndexWanted) then
                local ParameterValue = nil
                pcall(function() ParameterValue = Entry.ParameterValue end)
                local Copy = WarthogCopyLinearColor(ParameterValue)
                if Copy ~= nil then return Copy end
            end
        end
        Current = WarthogMaterialParent(Current)
    end
    return nil
end

function WarthogLooksLikeOriginalOlive(Value)
    local C = WarthogCopyLinearColor(Value)
    if C == nil then return false end
    local MaxRG = math.max(C.R, C.G)
    local MinRG = math.min(C.R, C.G)
    if MaxRG < 0.045 or MinRG < 0.035 then return false end
    -- Warthog olive layers have R/G relatively close together and a clearly
    -- lower blue channel. Gray/black hardware layers therefore do not qualify.
    if (MinRG / MaxRG) < 0.58 then return false end
    if C.B >= (MinRG * 0.90) then return false end
    return true
end

function WarthogClonePaintInfoEntries(Entries)
    local Output = {}
    for _, Entry in ipairs(Entries or {}) do
        Output[#Output + 1] = {
            Name=Entry.Name, Info=Entry.Info, Association=Entry.Association,
            Index=Entry.Index, Original=Entry.Original, Olive=Entry.Olive,
        }
    end
    return Output
end

function WarthogAccessoryAllowedLayerIndexes(Role)
    -- Release layer mapping verified in-game.
    if Role == "TurretMountBarrelPaint" then
        return { [2]=true }
    end
    if Role == "TurretShieldPanel" then
        return { [2]=true }
    end
    if Role == "TurretBarrelRingPaint" then
        return { [2]=true }
    end
    if Role == "VehicleInteriorPaint" then
        return { [1]=true, [2]=true }
    end
    return { [1]=true }
end

function WarthogCollectWheelInteriorColorInfos(Parent)
    Parent = Unwrap(Parent)
    if not IsValidObject(Parent) then return {} end

    local ParentKey = tostring(SafeFullName(Parent) or SafeToString(Parent) or "")
    local CacheKey = ParentKey .. "|role=WheelInteriorPaint"
    local Cached = WarthogAccessoryInfoCacheByParent[CacheKey]
    if type(Cached) == "table" and #Cached > 0 then
        return WarthogClonePaintInfoEntries(Cached)
    end

    local Output = {}
    local Seen = {}
    local Current = Parent
    local SeenMaterials = {}
    for _ = 1, 10 do
        if not IsValidObject(Current) then break end
        local MaterialKey = tostring(SafeFullName(Current) or SafeToString(Current) or "")
        if SeenMaterials[MaterialKey] then break end
        SeenMaterials[MaterialKey] = true

        local Values = nil
        pcall(function() Values = Current.VectorParameterValues end)
        for _, RawEntry in ipairs(ArrayValues(Values)) do
            local Entry = Unwrap(RawEntry)
            local Info, Name, Association, Index = WarthogRecolorParameterInfoFields(Entry)
            local ParameterValue = nil
            pcall(function() ParameterValue = Entry.ParameterValue end)
            if Info ~= nil and WarthogLooksLikeOriginalOlive(ParameterValue) then
                local NameText = tostring(SafeToString(Name))
                local AssociationNumber = tonumber(SafeToString(Association))
                local IndexNumber = tonumber(SafeToString(Index))
                local Key = string.format("%s:%s:%s", NameText, tostring(AssociationNumber), tostring(IndexNumber))
                if not Seen[Key] then
                    Seen[Key] = true
                    Output[#Output + 1] = {
                        Name=NameText, Info=Info, Association=AssociationNumber,
                        Index=IndexNumber, Original=WarthogCopyLinearColor(ParameterValue), Olive=true,
                    }
                end
            end
        end
        Current = WarthogMaterialParent(Current)
    end

    table.sort(Output, function(A, B)
        local AI = tonumber(A.Index) or -999
        local BI = tonumber(B.Index) or -999
        if AI ~= BI then return AI < BI end
        return tostring(A.Name) < tostring(B.Name)
    end)

    if #Output > 0 then
        WarthogAccessoryInfoCacheByParent[CacheKey] = WarthogClonePaintInfoEntries(Output)
    end
    return WarthogClonePaintInfoEntries(Output)
end

function WarthogCollectOptimizedAccessoryColorInfos(Parent, Role)
    Parent = Unwrap(Parent)
    if not IsValidObject(Parent) then return {} end

    local ParentKey = tostring(SafeFullName(Parent) or SafeToString(Parent) or "")
    local CacheKey = ParentKey .. "|role=" .. tostring(Role or "generic")
    local Cached = WarthogAccessoryInfoCacheByParent[CacheKey]
    if type(Cached) == "table" and #Cached > 0 then
        return WarthogClonePaintInfoEntries(Cached)
    end

    local AllowedIndexes = WarthogAccessoryAllowedLayerIndexes(Role)
    local ByKey = {}
    local FoundPerIndex = {}
    local Current = Parent
    local SeenMaterials = {}
    for _ = 1, 10 do
        if not IsValidObject(Current) then break end
        local MaterialKey = tostring(SafeFullName(Current) or SafeToString(Current) or "")
        if SeenMaterials[MaterialKey] then break end
        SeenMaterials[MaterialKey] = true

        local Values = nil
        pcall(function() Values = Current.VectorParameterValues end)
        for _, RawEntry in ipairs(ArrayValues(Values)) do
            local Entry = Unwrap(RawEntry)
            local Info, Name, Association, Index = WarthogRecolorParameterInfoFields(Entry)
            local NameText = tostring(SafeToString(Name))
            local AssociationNumber = tonumber(SafeToString(Association))
            local IndexNumber = tonumber(SafeToString(Index))
            if Info ~= nil and AssociationNumber == 0 and IndexNumber ~= nil
                and AllowedIndexes[IndexNumber] == true
                and (NameText == "Color Top" or NameText == "Color Mid" or NameText == "Color Bottom") then
                local Key = string.format("%s:%d", NameText, IndexNumber)
                if ByKey[Key] == nil then
                    local ParameterValue = nil
                    pcall(function() ParameterValue = Entry.ParameterValue end)
                    ByKey[Key] = {
                        Name=NameText, Info=Info, Association=AssociationNumber,
                        Index=IndexNumber, Original=WarthogCopyLinearColor(ParameterValue),
                    }
                    FoundPerIndex[IndexNumber] = (FoundPerIndex[IndexNumber] or 0) + 1
                end
            end
        end

        local Complete = true
        for WantedIndex, _ in pairs(AllowedIndexes) do
            if (FoundPerIndex[WantedIndex] or 0) < 3 then Complete = false break end
        end
        if Complete then break end
        Current = WarthogMaterialParent(Current)
    end

    local Output = {}
    local IndexLabels = {}
    local OrderedIndexes = {}
    for I, _ in pairs(AllowedIndexes) do OrderedIndexes[#OrderedIndexes + 1] = I end
    table.sort(OrderedIndexes)
    for _, I in ipairs(OrderedIndexes) do
        local Entries = {}
        for _, Entry in pairs(ByKey) do
            if Entry.Index == I then Entries[#Entries + 1] = Entry end
        end
        table.sort(Entries, function(A, B) return tostring(A.Name) < tostring(B.Name) end)
        for _, Entry in ipairs(Entries) do Output[#Output + 1] = Entry end
        if #Entries > 0 then IndexLabels[#IndexLabels + 1] = tostring(I) end
    end

    if #Output > 0 and CacheKey ~= "" then
        WarthogAccessoryInfoCacheByParent[CacheKey] = WarthogClonePaintInfoEntries(Output)
    end
    return WarthogClonePaintInfoEntries(Output)
end

function WarthogBuildPaintPlanItems(MIDs)
    local Plan = {}
    local TotalInfos = 0
    local AccessoryInfos = 0

    for _, MID in ipairs(MIDs or {}) do
        MID = Unwrap(MID)
        if IsValidObject(MID) then
            local Parent = nil
            pcall(function() Parent = Unwrap(MID.Parent) end)
            if IsValidObject(Parent) then
                local Entries = {}
                local Role = WarthogAccessoryRoleForMID(MID)
                local Accessory = Role ~= nil or WarthogUsesExpandedAccessoryColorInfos(Parent)
                if Accessory then
                    if Role == "WheelInteriorPaint" or Role == "VehicleInteriorPaint" then
                        Entries = WarthogCollectWheelInteriorColorInfos(Parent)
                    else
                        Entries = WarthogCollectOptimizedAccessoryColorInfos(Parent, Role)
                    end
                else
                    local Infos = WarthogPaintInfosForParent(Parent)
                    if Infos ~= nil then
                        Entries = {
                            { Name="Color Top", Info=Infos.Top, Association=0, Index=1,
                              Original=WarthogParentValueForInfo(Parent, "Color Top", 0, 1) },
                            { Name="Color Mid", Info=Infos.Mid, Association=0, Index=1,
                              Original=WarthogParentValueForInfo(Parent, "Color Mid", 0, 1) },
                            { Name="Color Bottom", Info=Infos.Bottom, Association=0, Index=1,
                              Original=WarthogParentValueForInfo(Parent, "Color Bottom", 0, 1) },
                        }
                    end
                end

                local ValidEntries = {}
                for _, Entry in ipairs(Entries or {}) do
                    if Entry.Info ~= nil then
                        -- Never define ORIGINAL from the current MID value here. A
                        -- checkpoint/restart can preserve our previous color override
                        -- on that MID. Remember the first authored parent value by a
                        -- stable material/role/parameter signature and reuse it across
                        -- all world-local cache rebuilds.
                        local RoleKey = Role or (Accessory and "AccessoryPaint" or "BodyPaint")
                        local Original = WarthogRememberAuthoredOriginal(
                            Parent, RoleKey, Entry, Entry.Original)
                        if Original ~= nil then
                            Entry.Original = Original
                            ValidEntries[#ValidEntries + 1] = Entry
                        end
                    end
                end

                if #ValidEntries > 0 then
                    Plan[#Plan + 1] = {
                        MID=MID, Parent=Parent, Infos=ValidEntries,
                        Accessory=Accessory, Role=Role,
                    }
                    TotalInfos = TotalInfos + #ValidEntries
                    if Accessory then AccessoryInfos = AccessoryInfos + #ValidEntries end
                end
            end
        end
    end
    return Plan, TotalInfos, AccessoryInfos
end

function WarthogBuildPaintApplyPlan(Vehicle, MIDs)
    local VehicleKey = WarthogVehicleToken(Vehicle)
    local Plan, TotalInfos, AccessoryInfos = WarthogBuildPaintPlanItems(MIDs)
    if #Plan > 0 then
        WarthogPaintApplyPlanCacheByVehicle[VehicleKey] = { Vehicle=Vehicle, Plan=Plan }
    end
    return Plan
end

function WarthogExtendPaintApplyPlanWithMIDs(Vehicle, AddedMIDs)
    local VehicleKey = WarthogVehicleToken(Vehicle)
    local CachedEntry = WarthogPaintApplyPlanCacheByVehicle[VehicleKey]
    if type(CachedEntry) ~= "table" or type(CachedEntry.Plan) ~= "table" then return nil end
    local NewItems, NewInfos, NewAccessoryInfos = WarthogBuildPaintPlanItems(AddedMIDs)
    if #NewItems == 0 then return nil end
    for _, Item in ipairs(NewItems) do CachedEntry.Plan[#CachedEntry.Plan + 1] = Item end
    return NewItems
end


function WarthogPaintApplyPlanForVehicle(Vehicle, MIDs)
    local VehicleKey = WarthogVehicleToken(Vehicle)
    local CachedEntry = WarthogPaintApplyPlanCacheByVehicle[VehicleKey]
    if type(CachedEntry) == "table" then
        local CachedVehicle = CachedEntry.Vehicle
        local Cached = CachedEntry.Plan
        local Valid = IsValidObject(CachedVehicle) and WarthogSameObject(CachedVehicle, Vehicle)
            and type(Cached) == "table" and #Cached > 0
        if Valid then
            for _, Item in ipairs(Cached) do
                if not IsValidObject(Item.MID) or type(Item.Infos) ~= "table" or #Item.Infos == 0 then
                    Valid = false
                    break
                end
            end
        end
        if Valid then return Cached, "cached apply plan" end
        WarthogPaintApplyPlanCacheByVehicle[VehicleKey] = nil
    end
    return WarthogBuildPaintApplyPlan(Vehicle, MIDs), "new apply plan"
end

function WarthogApplyPaintPlan(Plan, Color, RestoreOriginal)
    local AppliedMaterials = 0
    local FailedMaterials = 0
    local SetterCalls = 0
    local SetterFailures = 0
    local Linear = nil
    if not RestoreOriginal then Linear = WarthogColorLinear(Color) end

    for _, Item in ipairs(Plan or {}) do
        local Successes = 0
        local Total = #(Item.Infos or {})
        if IsValidObject(Item.MID) then
            for _, Entry in ipairs(Item.Infos or {}) do
                local Value = nil
                if RestoreOriginal then
                    Value = Entry.Original
                else
                    Value = Linear
                end
                if Value ~= nil then
                    SetterCalls = SetterCalls + 1
                    local Ok, Err = pcall(function() Item.MID:SetVectorParameterValueByInfo(Entry.Info, Value) end)
                    if Ok then
                        Successes = Successes + 1
                    else
                        SetterFailures = SetterFailures + 1
                        Log("WARTHOG COLOR optimized setter FAILED material=%s name=%s index=%s: %s",
                            WarthogRecolorDescribe(Item.MID), tostring(Entry.Name), tostring(Entry.Index),
                            WarthogRecolorClip(Err, 500))
                    end
                end
            end
        end
        if Successes == Total and Total > 0 then AppliedMaterials = AppliedMaterials + 1
        else FailedMaterials = FailedMaterials + 1 end
    end

    return AppliedMaterials > 0,
        string.format("materialsApplied=%d materialsFailed=%d setterCalls=%d setterFailures=%d",
            AppliedMaterials, FailedMaterials, SetterCalls, SetterFailures),
        AppliedMaterials, FailedMaterials, SetterCalls
end

function WarthogScheduleAccessoryRepair(PlayerIndex, VehicleKey, Attempt)
    Attempt = tonumber(Attempt) or 1
    if Attempt > 6 then return end

    local ScheduleKey = tostring(PlayerIndex) .. ":" .. tostring(VehicleKey)
    if WarthogAccessoryRepairScheduledByVehicle[ScheduleKey] then return end
    WarthogAccessoryRepairScheduledByVehicle[ScheduleKey] = true
    local RuntimeGeneration = WarthogColorRuntimeGeneration
    local DelayMs = 250 + ((Attempt - 1) * 350)

    ExecuteInGameThreadWithDelay(DelayMs, function()
        WarthogAccessoryRepairScheduledByVehicle[ScheduleKey] = nil
        if RuntimeGeneration ~= WarthogColorRuntimeGeneration or not MissionReady then return end

        local Vehicle = nil
        pcall(function() Vehicle = select(1, WarthogFindDriverVehicleFast(PlayerIndex)) end)
        if not IsValidObject(Vehicle) or tostring(WarthogVehicleToken(Vehicle)) ~= tostring(VehicleKey) then return end

        local MIDs = WarthogFindPaintMIDsForVehicle(Vehicle)
        local Plan = nil
        local PlanEntry = WarthogPaintApplyPlanCacheByVehicle[VehicleKey]
        if type(PlanEntry) == "table" then Plan = PlanEntry.Plan end
        if type(Plan) ~= "table" or #Plan == 0 then
            Plan = WarthogBuildPaintApplyPlan(Vehicle, MIDs)
        end

        -- Apply the selected state on every bounded repair pass. If Halo exposes
        -- a wheel/turret component late, the newly-added plan item is corrected
        -- immediately instead of waiting for another manual color press.
        local State = tonumber(WarthogColorIndexByVehicle[VehicleKey])
        if State ~= nil and type(Plan) == "table" and #Plan > 0 then
            local IsOriginal = State == 0
            local Color = IsOriginal and nil or WarthogCEColors[State]
            WarthogApplyPaintPlan(Plan, Color, IsOriginal)
        end

        local CacheEntry = WarthogPaintMIDCacheByVehicle[VehicleKey]
        if type(CacheEntry) == "table" and CacheEntry.AccessoryPending == true then
            WarthogScheduleAccessoryRepair(PlayerIndex, VehicleKey, Attempt + 1)
        end
    end)
end

function CycleOccupiedWarthogColor(PlayerIndex, Delta, Source)
    if not MissionReady then return false end
    local Controller = GetPlayer(PlayerIndex)
    if not IsValidObject(Controller) then return false end

    -- Normal driver proof stays pawn-local and bounded. A hybrid network session
    -- can expose P2's Warthog relationship only from the vehicle side, so P2 gets
    -- one additional bounded snapshot recovery per runtime generation. That path
    -- is eligible only when an already-cached remote peer proves this is a hybrid
    -- session; it never guesses by distance or nearest vehicle.
    local Vehicle, DriverRoute = WarthogFindDriverVehicleFast(PlayerIndex, false)
    if not IsValidObject(Vehicle) and PlayerIndex == 2 then
        local HybridVehicle, HybridRoute = WarthogFindHybridDriverVehicleP2()
        if IsValidObject(HybridVehicle) then
            Vehicle = HybridVehicle
            DriverRoute = HybridRoute
        else
            DriverRoute = tostring(DriverRoute) .. "; " .. tostring(HybridRoute)
        end
    end
    if not IsValidObject(Vehicle) then
        Log("VEHNET v1.9.0 DRIVER GATE rejected P%d source=%s route=%s",
            PlayerIndex, tostring(Source or "unknown"), tostring(DriverRoute))
        return false
    end

    local PaintMIDs, MIDRoute = WarthogFindPaintMIDsForVehicle(Vehicle)
    if PaintMIDs == nil or #PaintMIDs == 0 then
        Log("WARTHOG COLOR P%d selected material mapping failed: %s", PlayerIndex, tostring(MIDRoute))
        ScreenMessage(PlayerIndex, Controller, "WARTHOG COLOR: MATERIAL ERROR")
        return false
    end

    local VehicleKey = WarthogVehicleToken(Vehicle)
    local Plan = WarthogPaintApplyPlanForVehicle(Vehicle, PaintMIDs)
    if Plan == nil or #Plan == 0 then
        Log("WARTHOG COLOR P%d apply plan failed vehicle=%s", PlayerIndex, tostring(VehicleKey))
        ScreenMessage(PlayerIndex, Controller, "WARTHOG COLOR: MATERIAL ERROR")
        return false
    end

    -- State 0 is the exact paint values captured before the first recolor.
    -- States 1..18 are the original Halo CE multiplayer armor colors.
    local Current = tonumber(WarthogColorIndexByVehicle[VehicleKey])
    local UsedCheckpointCarry = false
    if Current == nil then
        local Carry = tonumber(WarthogCheckpointColorCarryByPlayer[PlayerIndex])
        if Carry ~= nil then
            Current = Carry
            UsedCheckpointCarry = true
        else
            Current = 0
        end
    end
    local Step = (tonumber(Delta) or 1) < 0 and -1 or 1
    local Next = Current + Step
    if Next > #WarthogCEColors then Next = 0 end
    if Next < 0 then Next = #WarthogCEColors end

    local IsOriginal = Next == 0
    local Color = IsOriginal and nil or WarthogCEColors[Next]
    local Applied, ApplyInfo = WarthogApplyPaintPlan(Plan, Color, IsOriginal)
    if not Applied then
        Log("WARTHOG COLOR P%d apply failed vehicle=%s state=%s: %s",
            PlayerIndex, tostring(VehicleKey), IsOriginal and "ORIGINAL" or tostring(Color.Name), tostring(ApplyInfo))
        ScreenMessage(PlayerIndex, Controller, "WARTHOG COLOR: APPLY ERROR")
        return false
    end

    WarthogColorIndexByVehicle[VehicleKey] = Next
    WarthogLastColorIndexByPlayer[PlayerIndex] = Next
    VehicleNetworkPostLocalPaint(Vehicle, "Warthog", IsOriginal and "ORIGINAL" or tostring(Color.Name))
    local PaintCacheEntry = WarthogPaintMIDCacheByVehicle[VehicleKey]
    if type(PaintCacheEntry) == "table" and PaintCacheEntry.AccessoryPending == true then
        WarthogScheduleAccessoryRepair(PlayerIndex, VehicleKey, 1)
    end
    if UsedCheckpointCarry then WarthogCheckpointColorCarryByPlayer[PlayerIndex] = nil end
    if IsOriginal then
        ScreenMessage(PlayerIndex, Controller, "WARTHOG COLOR: ORIGINAL")
    else
        ScreenMessage(PlayerIndex, Controller,
            string.format("WARTHOG COLOR %02d/%02d: %s", Next, #WarthogCEColors, tostring(Color.Name)))
    end
    return true
end


-- Driver-only Scorpion color cycling ----------------------------------------
-- Uses the same 18 Halo CE multiplayer colors as the Warthog. Only the
-- positively identified Scorpion driver can change color. The verified paint
-- mapping includes hull/body paint, tread outer armor/skirt paint, and the
-- painted cannon/anti-infantry turret surfaces. Tracks, wheels, suspension,
-- vents, lamps, glass, metal hardware and decals retain their authored values.
ScorpionColorRuntimeGeneration = ScorpionColorRuntimeGeneration or 0
ScorpionColorIndexByVehicle = ScorpionColorIndexByVehicle or {}
ScorpionLastColorIndexByPlayer = ScorpionLastColorIndexByPlayer or {}
ScorpionCheckpointColorCarryByPlayer = ScorpionCheckpointColorCarryByPlayer or {}
ScorpionPaintPlanCacheByVehicle = ScorpionPaintPlanCacheByVehicle or {}
ScorpionColorInfoCacheByMaterial = ScorpionColorInfoCacheByMaterial or {}
-- Same rule as Warthog: authored originals survive runtime invalidation while
-- UObject/MID plans do not. This is especially important for the late
-- anti-infantry turret after Restart Mission.
ScorpionOriginalColorValueCache = ScorpionOriginalColorValueCache or {}
ScorpionDriverComponentIndexByPlayer = ScorpionDriverComponentIndexByPlayer or {}
ScorpionTurretCandidateCache = ScorpionTurretCandidateCache or { Generation=-1, Components={} }
ScorpionTurretRepairScheduledByVehicle = ScorpionTurretRepairScheduledByVehicle or {}
ScorpionTurretRepairReadyByVehicle = ScorpionTurretRepairReadyByVehicle or {}

function InvalidateScorpionColorRuntime(Reason, PreserveColorCarry)
    local PreviousTurretCandidates = ScorpionTurretCandidateCache
    local ReasonLower = string.lower(tostring(Reason or ""))
    local PreserveTurretCandidates = PreserveColorCarry == true
        and string.find(ReasonLower, "restartlevel", 1, true) ~= nil

    ScorpionColorRuntimeGeneration = (tonumber(ScorpionColorRuntimeGeneration) or 0) + 1
    if PreserveColorCarry then
        for PlayerIndex = 1, 2 do
            local Last = tonumber(ScorpionLastColorIndexByPlayer[PlayerIndex])
            if Last ~= nil then ScorpionCheckpointColorCarryByPlayer[PlayerIndex] = Last end
        end
    end
    ScorpionPaintPlanCacheByVehicle = {}
    ScorpionDriverComponentIndexByPlayer = {}

    -- RestartLevel usually keeps the physical turret components alive even when
    -- the hull paint plan has to be rebuilt. Retaining only still-valid candidate
    -- refs avoids another world-wide mesh scan on the first post-restart color
    -- press. Real map travel/teardown still drops every UObject reference.
    if PreserveTurretCandidates and type(PreviousTurretCandidates) == "table"
        and type(PreviousTurretCandidates.Components) == "table" then
        local ValidCandidates = {}
        for _, Component in ipairs(PreviousTurretCandidates.Components) do
            if IsValidObject(Component) then ValidCandidates[#ValidCandidates + 1] = Component end
        end
        if #ValidCandidates > 0 then
            ScorpionTurretCandidateCache = {
                Generation=ScorpionColorRuntimeGeneration, Components=ValidCandidates
            }
        else
            ScorpionTurretCandidateCache = { Generation=-1, Components={} }
        end
    else
        ScorpionTurretCandidateCache = { Generation=-1, Components={} }
    end
    ScorpionTurretRepairScheduledByVehicle = {}
    ScorpionTurretRepairReadyByVehicle = {}
end

function ResetScorpionColorState(Reason)
    ScorpionColorRuntimeGeneration = (tonumber(ScorpionColorRuntimeGeneration) or 0) + 1
    ScorpionColorIndexByVehicle = {}
    ScorpionLastColorIndexByPlayer = {}
    ScorpionCheckpointColorCarryByPlayer = {}
    ScorpionPaintPlanCacheByVehicle = {}
    ScorpionColorInfoCacheByMaterial = {}
    ScorpionOriginalColorValueCache = {}
    ScorpionDriverComponentIndexByPlayer = {}
    ScorpionTurretCandidateCache = { Generation=-1, Components={} }
    ScorpionTurretRepairScheduledByVehicle = {}
    ScorpionTurretRepairReadyByVehicle = {}
end

function ScorpionIsScorpionActor(Object)
    Object = Unwrap(Object)
    if not IsValidObject(Object) then return false end
    local Class = nil
    pcall(function() Class = Unwrap(Object:GetClass()) end)
    local ClassText = string.lower(tostring(SafeFullName(Class) or SafeToString(Class) or ""))
    return string.find(ClassText, "bp_scorpionvehicleactor_c", 1, true) ~= nil
        or string.find(ClassText, "scorpionvehicleactor", 1, true) ~= nil
end

function ScorpionResolveVehicleFromObject(Object)
    local Current = Unwrap(Object)
    local Seen = {}
    for _ = 1, 10 do
        if not IsValidObject(Current) then return nil end
        local Key = tostring(SafeFullName(Current) or SafeToString(Current) or "")
        if Key == "" or Seen[Key] then return nil end
        Seen[Key] = true
        if ScorpionIsScorpionActor(Current) then return Current end

        local Next = nil
        pcall(function() Next = Unwrap(Current.AttachParent) end)
        if not IsValidObject(Next) then pcall(function() Next = Unwrap(Current:GetAttachParent()) end) end
        if not IsValidObject(Next) then pcall(function() Next = Unwrap(Current:GetOwner()) end) end
        if not IsValidObject(Next) then pcall(function() Next = Unwrap(Current.Owner) end) end
        if not IsValidObject(Next) then return nil end
        Current = Next
    end
    return nil
end

function ScorpionVehicleToken(Vehicle)
    Vehicle = Unwrap(Vehicle)
    if not IsValidObject(Vehicle) then return "" end
    local Name = nil
    pcall(function() Name = Vehicle:GetFName():ToString() end)
    if Name ~= nil and tostring(Name) ~= "" then return tostring(Name) end
    return tostring(SafeFullName(Vehicle) or SafeToString(Vehicle) or "")
end

function ScorpionTraceAttachmentChain(Component)
    local Current = Unwrap(Component)
    local Chain = {}
    local Seen = {}
    for _ = 1, 10 do
        if not IsValidObject(Current) then break end
        local Key = tostring(SafeFullName(Current) or SafeToString(Current) or "")
        if Key == "" or Seen[Key] then break end
        Seen[Key] = true
        Chain[#Chain + 1] = Current

        if ScorpionIsScorpionActor(Current) then return Current, Chain end

        local CurrentText = WarthogObjectNameLower(Current)
        if string.find(CurrentText, "bp_scorpionvehicleactor", 1, true) ~= nil
            and string.find(CurrentText, ".hull", 1, true) ~= nil then
            local Owner = nil
            pcall(function() Owner = Unwrap(Current:GetOwner()) end)
            if not IsValidObject(Owner) then pcall(function() Owner = Unwrap(Current.Owner) end) end
            if ScorpionIsScorpionActor(Owner) then return Owner, Chain end
        end

        local Parent = nil
        pcall(function() Parent = Unwrap(Current.AttachParent) end)
        if not IsValidObject(Parent) then pcall(function() Parent = Unwrap(Current:GetAttachParent()) end) end
        if not IsValidObject(Parent) then pcall(function() Parent = Unwrap(Current:GetOwner()) end) end
        if not IsValidObject(Parent) then pcall(function() Parent = Unwrap(Current.Owner) end) end
        if not IsValidObject(Parent) then break end
        Current = Parent
    end
    return nil, Chain
end

function ScorpionDirectHullDriverProof(Chain)
    local Count = #(Chain or {})
    if Count < 2 or Count > 4 then return nil end

    local Hull = Unwrap(Chain[Count])
    local SeatRoot = Unwrap(Chain[Count - 1])
    if not IsValidObject(Hull) or not IsValidObject(SeatRoot) then return nil end

    local HullText = WarthogObjectNameLower(Hull)
    if string.find(HullText, "bp_scorpionvehicleactor", 1, true) == nil
        or string.find(HullText, ".hull", 1, true) == nil then
        return nil
    end

    local SocketValue = nil
    pcall(function() SocketValue = SeatRoot:GetAttachSocketName() end)
    if SocketValue == nil then pcall(function() SocketValue = SeatRoot.AttachSocketName end) end
    local SocketText = string.lower(tostring(WarthogSeatNameText(SocketValue) or ""))

    if string.find(SocketText, "passenger", 1, true) ~= nil
        or string.find(SocketText, "gunner", 1, true) ~= nil
        or string.find(SocketText, "rider", 1, true) ~= nil then
        return false
    end
    if string.find(SocketText, "driver", 1, true) ~= nil
        or string.find(SocketText, "pilot", 1, true) ~= nil then
        return true
    end

    -- Verified driver signature from the B40 Scorpion: the Spartan seat root is
    -- attached directly to Hull on hullbody_m at approximately (1.5,-49.1,23.7).
    -- Requiring both socket and local position avoids treating tread passengers
    -- as drivers merely because they also attach directly to the tank hull.
    local RelativeLocation = nil
    pcall(function() RelativeLocation = SeatRoot.RelativeLocation end)
    local RX, RY, RZ = nil, nil, nil
    if RelativeLocation ~= nil then
        pcall(function() RX = tonumber(RelativeLocation.X) end)
        pcall(function() RY = tonumber(RelativeLocation.Y) end)
        pcall(function() RZ = tonumber(RelativeLocation.Z) end)
    end
    local SocketMatches = string.find(SocketText, "hullbody_m", 1, true) ~= nil
    local PositionMatches = RX ~= nil and RY ~= nil and RZ ~= nil
        and math.abs(RX - 1.5) <= 20.0
        and math.abs(RY + 49.1) <= 24.0
        and math.abs(RZ - 23.7) <= 28.0
    if SocketMatches and PositionMatches then return true end
    return nil
end

function ScorpionDriverChainProof(Chain)
    for _, RawObject in ipairs(Chain or {}) do
        local Object = Unwrap(RawObject)
        local Text = WarthogObjectNameLower(Object)
        if string.find(Text, "passenger", 1, true) ~= nil
            or string.find(Text, "gunner", 1, true) ~= nil
            or string.find(Text, "rider", 1, true) ~= nil
            or string.find(Text, "turretseat", 1, true) ~= nil then
            return false
        end
        if string.find(Text, "driver", 1, true) ~= nil
            or string.find(Text, "pilot", 1, true) ~= nil then
            return true
        end

        local Role = nil
        pcall(function() Role = select(1, WarthogSeatRoleFromObject(Object)) end)
        if Role ~= nil then return Role end

        local SocketValue = nil
        pcall(function() SocketValue = Object:GetAttachSocketName() end)
        if SocketValue == nil then pcall(function() SocketValue = Object.AttachSocketName end) end
        local SocketText = string.lower(tostring(WarthogSeatNameText(SocketValue) or ""))
        if string.find(SocketText, "driver", 1, true) ~= nil
            or string.find(SocketText, "pilot", 1, true) ~= nil then
            return true
        end
        if string.find(SocketText, "passenger", 1, true) ~= nil
            or string.find(SocketText, "gunner", 1, true) ~= nil
            or string.find(SocketText, "rider", 1, true) ~= nil then
            return false
        end
    end
    return ScorpionDirectHullDriverProof(Chain)
end

function ScorpionFindDriverVehicleFast(PlayerIndex, FastOnly)
    local Controller = GetPlayer(PlayerIndex)
    if not IsValidObject(Controller) then return nil, nil, nil end
    local Pawn = nil
    pcall(function() Pawn = Unwrap(Controller.Pawn) end)
    if not IsValidObject(Pawn) then return nil, nil, nil end

    for _, Source in ipairs({Controller, Pawn}) do
        for _, Name in ipairs({"DrivingVehicle", "DrivenVehicle"}) do
            local Value = nil
            pcall(function() Value = Unwrap(Source[Name]) end)
            local Vehicle = ScorpionResolveVehicleFromObject(Value)
            if IsValidObject(Vehicle) then return Vehicle, Pawn, true end
        end
    end

    local Components = WarthogGetActorComponents(Pawn)
    local SeenIndices = {}
    local OccupiedVehicle = nil
    local OccupiedDriverState = nil

    local function InspectComponent(I)
        I = tonumber(I)
        if I == nil or I < 1 or I > #Components or SeenIndices[I] then return nil end
        SeenIndices[I] = true
        local Component = Unwrap(Components[I])
        if not IsValidObject(Component) then return nil end
        local Vehicle, Chain = ScorpionTraceAttachmentChain(Component)
        if not IsValidObject(Vehicle) then return nil end

        local PropertyDriver = nil
        pcall(function() PropertyDriver = select(1, WarthogDriverPropertyProof(Vehicle, Pawn)) end)
        local DriverState = PropertyDriver
        if DriverState == nil then DriverState = ScorpionDriverChainProof(Chain) end
        if DriverState == true then
            ScorpionDriverComponentIndexByPlayer[PlayerIndex] = I
            return Vehicle, true
        end
        if OccupiedVehicle == nil then
            OccupiedVehicle = Vehicle
            OccupiedDriverState = DriverState
        end
        return nil, DriverState
    end

    local CandidateIndices = {}
    local CachedIndex = tonumber(ScorpionDriverComponentIndexByPlayer[PlayerIndex])
    if CachedIndex ~= nil then CandidateIndices[#CandidateIndices + 1] = CachedIndex end
    for _, I in ipairs({35,34,36,33,37,32,38,31,39,30,40,29,41,28,42}) do
        CandidateIndices[#CandidateIndices + 1] = I
    end
    for _, I in ipairs(CandidateIndices) do
        local Vehicle = select(1, InspectComponent(I))
        if IsValidObject(Vehicle) then return Vehicle, Pawn, true end
    end

    if FastOnly then return nil, Pawn, OccupiedDriverState, OccupiedVehicle end

    local RecoveryStarted = os.clock()
    local MaxComponents = math.min(#Components, 96)
    for I = 1, MaxComponents do
        if not SeenIndices[I] then
            local Vehicle = select(1, InspectComponent(I))
            if IsValidObject(Vehicle) then
                local RecoveryMs = (os.clock() - RecoveryStarted) * 1000.0
                Log("VEHNET v1.9.0 SCORPION DRIVER RECOVERY success P%d component=%d time=%.2fms",
                    PlayerIndex, I, RecoveryMs)
                return Vehicle, Pawn, true
            end
        end
    end
    return nil, Pawn, OccupiedDriverState, OccupiedVehicle
end

function ScorpionCreateDynamicPaintMID(Component, Slot, SourceMaterial)
    if not IsValidObject(Component) or not IsValidObject(SourceMaterial) then return nil end
    if WarthogIsDynamicMaterial(SourceMaterial) then return SourceMaterial end

    local MID = nil
    pcall(function()
        MID = Unwrap(Component:CreateDynamicMaterialInstance(Slot, SourceMaterial, FName("ScorpionColorMID")))
    end)
    if not IsValidObject(MID) then
        pcall(function() MID = Unwrap(Component:CreateAndSetMaterialInstanceDynamicFromMaterial(Slot, SourceMaterial)) end)
    end
    if not IsValidObject(MID) then
        pcall(function() MID = Unwrap(Component:CreateAndSetMaterialInstanceDynamic(Slot)) end)
    end
    return IsValidObject(MID) and MID or nil
end

function ScorpionCloneBasePaintInfos(Entries)
    local Output = {}
    for _, Entry in ipairs(Entries or {}) do
        Output[#Output + 1] = {
            Name=Entry.Name, Info=Entry.Info, Association=Entry.Association,
            Index=Entry.Index, Original=Entry.Original,
        }
    end
    return Output
end

function ScorpionBasePaintInfosForMaterial(Material)
    Material = Unwrap(Material)
    if not IsValidObject(Material) then return {} end

    -- Restart Mission can preserve a ScorpionColorMID whose current override is
    -- still the previously selected color. Build parameter metadata and ORIGINAL
    -- values from the authored parent instead of treating that runtime override as
    -- the base color. This is especially important for the attached anti-infantry
    -- turret, which can outlive/reappear later than the hull components.
    local BaseMaterial, MaterialKey = VehiclePaintStableAuthoredMaterial(Material)
    if not IsValidObject(BaseMaterial) then BaseMaterial = Material end
    MaterialKey = tostring(MaterialKey or SafeFullName(BaseMaterial) or SafeToString(BaseMaterial) or "")
    local Cached = ScorpionColorInfoCacheByMaterial[MaterialKey]
    if type(Cached) == "table" then return ScorpionCloneBasePaintInfos(Cached) end

    local Output = {}
    local ParamSeen = {}
    local Current = BaseMaterial
    local SeenMaterials = {}
    for _ = 1, 10 do
        if not IsValidObject(Current) then break end
        local CurrentKey = tostring(SafeFullName(Current) or SafeToString(Current) or "")
        if CurrentKey == "" or SeenMaterials[CurrentKey] then break end
        SeenMaterials[CurrentKey] = true

        local Values = nil
        pcall(function() Values = Current.VectorParameterValues end)
        for _, RawEntry in ipairs(ArrayValues(Values)) do
            local Entry = Unwrap(RawEntry)
            local Info, Name, Association, Index = WarthogRecolorParameterInfoFields(Entry)
            local NameText = tostring(SafeToString(Name))
            local AssociationNumber = tonumber(SafeToString(Association))
            local IndexNumber = tonumber(SafeToString(Index))
            local IsBasePaint = Info ~= nil and AssociationNumber == 0
                and IndexNumber ~= nil and IndexNumber >= 1 and IndexNumber <= 4
                and (NameText == "Color Top" or NameText == "Color Mid" or NameText == "Color Bottom")
            if IsBasePaint then
                local ParamKey = NameText .. "@" .. tostring(IndexNumber)
                if not ParamSeen[ParamKey] then
                    ParamSeen[ParamKey] = true
                    local ParameterValue = nil
                    pcall(function() ParameterValue = Entry.ParameterValue end)
                    local OriginalKey = table.concat({
                        tostring(MaterialKey), NameText,
                        tostring(AssociationNumber), tostring(IndexNumber)
                    }, "|")
                    local Original = WarthogCopyLinearColor(ScorpionOriginalColorValueCache[OriginalKey])
                    if Original == nil then
                        Original = WarthogCopyLinearColor(ParameterValue)
                        if Original ~= nil then
                            ScorpionOriginalColorValueCache[OriginalKey] = WarthogCopyLinearColor(Original)
                        end
                    end
                    Output[#Output + 1] = {
                        Name=NameText, Info=Info, Association=AssociationNumber,
                        Index=IndexNumber, Original=Original,
                    }
                end
            end
        end
        Current = WarthogMaterialParent(Current)
    end

    table.sort(Output, function(A, B)
        local AI, BI = tonumber(A.Index) or -1, tonumber(B.Index) or -1
        if AI ~= BI then return AI < BI end
        return tostring(A.Name) < tostring(B.Name)
    end)
    ScorpionColorInfoCacheByMaterial[MaterialKey] = ScorpionCloneBasePaintInfos(Output)
    return ScorpionCloneBasePaintInfos(Output)
end

function ScorpionPaintSlotWanted(MeshText, MaterialText, ComponentText, MaterialObject)
    local MeshLower = string.lower(tostring(MeshText or ""))
    local MaterialLower = string.lower(tostring(MaterialText or ""))
    local ComponentLower = string.lower(tostring(ComponentText or ""))

    -- Once a slot has been recolored its current material can be our generic
    -- ScorpionColorMID, whose transient name no longer contains the authored
    -- MI_Scorpion_*_Paint token. Always include the stable authored parent in
    -- classification so a later repair/restart still recognizes the same slot.
    local AuthoredText = ""
    local AuthoredMaterial = nil
    if IsValidObject(Unwrap(MaterialObject)) then
        AuthoredMaterial = select(1, VehiclePaintStableAuthoredMaterial(MaterialObject))
    end
    if IsValidObject(AuthoredMaterial) then
        AuthoredText = tostring(SafeFullName(AuthoredMaterial) or SafeToString(AuthoredMaterial) or "")
        if AuthoredText ~= "" then
            MaterialLower = MaterialLower .. " | " .. string.lower(AuthoredText)
        end
    end

    local Combined = MeshLower .. " | " .. MaterialLower .. " | " .. ComponentLower

    local IsPaintMaterial =
        string.find(MaterialLower, "scorpion_hull_paint", 1, true) ~= nil
        or string.find(MaterialLower, "scorpion_turret_paint", 1, true) ~= nil
        or string.find(MaterialLower, "scorpion_tread_paint", 1, true) ~= nil
        or string.find(MaterialLower, "_paint_", 1, true) ~= nil
    if not IsPaintMaterial then return false end

    -- Verified paint-bearing armor above/beside the tracks.
    if string.find(MeshLower, "_tread_outer_", 1, true) ~= nil then
        return string.find(Combined, "lamp", 1, true) == nil
            and string.find(Combined, "glass", 1, true) == nil
    end
    if string.find(MeshLower, "_tread_shield", 1, true) ~= nil then return true end

    -- All remaining tread mechanics and obvious detail materials stay stock.
    for _, Token in ipairs({
        "tread", "track", "wheel", "suspension", "vent", "lamp", "glass",
        "fauxleather", "metal_char", "rearbar", "_garbage"
    }) do
        if string.find(Combined, Token, 1, true) ~= nil then return false end
    end
    return true
end

function ScorpionObjectAttachedToVehicle(Object, Vehicle)
    Object = Unwrap(Object)
    Vehicle = Unwrap(Vehicle)
    if not IsValidObject(Object) or not IsValidObject(Vehicle) then return false end

    local Queue = {{Object=Object, Depth=0}}
    local Seen = {}
    local Q = 1
    while Q <= #Queue do
        local Item = Queue[Q]
        Q = Q + 1
        local Current = Unwrap(Item.Object)
        if IsValidObject(Current) then
            local Key = tostring(SafeFullName(Current) or SafeToString(Current) or "")
            if Key ~= "" and not Seen[Key] then
                Seen[Key] = true
                if WarthogSameObject(Current, Vehicle) then return true end
                if (tonumber(Item.Depth) or 0) < 6 then
                    local function Add(Value)
                        Value = Unwrap(Value)
                        if IsValidObject(Value) then
                            Queue[#Queue + 1] = {Object=Value, Depth=(tonumber(Item.Depth) or 0) + 1}
                        end
                    end
                    local V = nil
                    pcall(function() V = Current:GetOwner() end); Add(V)
                    V = nil; pcall(function() V = Current.Owner end); Add(V)
                    V = nil; pcall(function() V = Current:GetAttachParent() end); Add(V)
                    V = nil; pcall(function() V = Current.AttachParent end); Add(V)
                    V = nil; pcall(function() V = Current:GetAttachParentActor() end); Add(V)
                    V = nil; pcall(function() V = Current.RootComponent end); Add(V)
                end
            end
        end
    end
    return false
end

function ScorpionAntiInfantryPaintSlotSignature(MeshText, Slot)
    local MeshLower = string.lower(tostring(MeshText or ""))
    Slot = tonumber(Slot) or -1
    local Signatures = {
        {"sm_scorpionantiinfantry_gunbase_m_shieldleft_default", 1, "shield-left"},
        {"sm_scorpionantiinfantry_gunbase_m_shieldright_default", 0, "shield-right"},
        {"sm_scorpionantiinfantry_gun_m_shield_default", 0, "gun-shield"},
        {"sm_scorpionantiinfantry_gunbase_m_default", 3, "gun-base"},
        {"sm_scorpionantiinfantry_gun_m_default", 1, "gun"},
        {"sk_scorpionantiinfantry", 0, "skeletal-base"},
    }
    for _, Entry in ipairs(Signatures) do
        if Slot == Entry[2] and string.find(MeshLower, Entry[1], 1, true) ~= nil then
            return Entry[3]
        end
    end
    return nil
end

function ScorpionObjectWorldLocation(Object)
    Object = Unwrap(Object)
    if not IsValidObject(Object) then return nil, nil, nil end
    local Location = nil
    pcall(function() Location = Unwrap(Object:K2_GetComponentLocation()) end)
    if Location == nil then pcall(function() Location = Unwrap(Object:GetComponentLocation()) end) end
    if Location == nil then pcall(function() Location = Unwrap(Object:K2_GetActorLocation()) end) end
    if Location == nil then pcall(function() Location = Unwrap(Object:GetActorLocation()) end) end
    if Location == nil then
        local Root = nil
        pcall(function() Root = Unwrap(Object.RootComponent) end)
        if IsValidObject(Root) then
            pcall(function() Location = Unwrap(Root:K2_GetComponentLocation()) end)
            if Location == nil then pcall(function() Location = Unwrap(Root:GetComponentLocation()) end) end
        end
    end
    if Location == nil then return nil, nil, nil end
    local X, Y, Z = nil, nil, nil
    pcall(function() X = tonumber(Location.X) end)
    pcall(function() Y = tonumber(Location.Y) end)
    pcall(function() Z = tonumber(Location.Z) end)
    if X == nil or Y == nil or Z == nil then return nil, nil, nil end
    return X, Y, Z
end

function ScorpionAntiInfantryNearVehicle(Component, Vehicle)
    local MeshText = WarthogComponentMeshAssetText(Component)
    if string.find(string.lower(tostring(MeshText or "")), "scorpionantiinfantry", 1, true) == nil then
        return false
    end
    local CX, CY, CZ = ScorpionObjectWorldLocation(Component)
    local VX, VY, VZ = ScorpionObjectWorldLocation(Vehicle)
    if CX == nil or VX == nil then return false end
    local DX, DY, DZ = CX - VX, CY - VY, CZ - VZ
    -- The anti-infantry gun is mounted on the hull. 700 UE units is generous
    -- enough for every verified piece while rejecting unrelated Scorpions in
    -- normal campaign spacing.
    return (DX * DX + DY * DY + DZ * DZ) <= (700 * 700)
end

function ScorpionTurretComponentCandidates(ForceRefresh)
    local Cache = ScorpionTurretCandidateCache
    if not ForceRefresh and type(Cache) == "table"
        and tonumber(Cache.Generation) == tonumber(ScorpionColorRuntimeGeneration)
        and type(Cache.Components) == "table" then
        local Valid = {}
        for _, Component in ipairs(Cache.Components) do
            if IsValidObject(Component) then Valid[#Valid + 1] = Component end
        end
        Cache.Components = Valid
        -- An empty carried cache is still useful: callers that only want a cheap
        -- pass should not silently trigger a full FindAllOf scan. Explicit
        -- ForceRefresh is used by the single bounded fallback repair instead.
        return Valid
    end

    local Output = {}
    local Seen = {}
    for _, ClassName in ipairs({"StaticMeshComponent", "SkeletalMeshComponent"}) do
        local Objects = nil
        pcall(function() Objects = FindAllOf(ClassName) end)
        for _, RawObject in ipairs(ArrayValues(Objects)) do
            local Component = Unwrap(RawObject)
            if IsValidObject(Component) then
                local Key = tostring(SafeFullName(Component) or SafeToString(Component) or "")
                if Key ~= "" and not Seen[Key] then
                    local Lower = string.lower(Key)
                    local Candidate = string.find(Lower, "scorpion", 1, true) ~= nil
                        or string.find(Lower, "m808", 1, true) ~= nil
                        or string.find(Lower, "scorpioncannon", 1, true) ~= nil
                        or string.find(Lower, "scorpionantiinfantry", 1, true) ~= nil
                    if Candidate then
                        Seen[Key] = true
                        Output[#Output + 1] = Component
                    end
                end
            end
        end
    end
    ScorpionTurretCandidateCache = { Generation=ScorpionColorRuntimeGeneration, Components=Output }
    return Output
end

function ScorpionExtraTurretComponents(Vehicle, SeenComponentKeys, ForceRefresh)
    local Output = {}
    SeenComponentKeys = SeenComponentKeys or {}
    for _, Component in ipairs(ScorpionTurretComponentCandidates(ForceRefresh)) do
        if IsValidObject(Component) then
            local Key = tostring(SafeFullName(Component) or SafeToString(Component) or "")
            if Key ~= "" and not SeenComponentKeys[Key] then
                local MeshText = WarthogComponentMeshAssetText(Component)
                local MeshLower = string.lower(tostring(MeshText or ""))
                if string.find(MeshLower, "/vehicles/scorpion/turrets/", 1, true) ~= nil then
                    local Attached = ScorpionObjectAttachedToVehicle(Component, Vehicle)
                    -- RestartLevel can leave the anti-infantry child actor visually
                    -- mounted while its attachment/owner chain no longer resolves to
                    -- the hull. Use a tight spatial fallback only for this verified
                    -- turret family; cannon components still require real attachment.
                    local NearAntiInfantry = (not Attached)
                        and ScorpionAntiInfantryNearVehicle(Component, Vehicle)
                    if Attached or NearAntiInfantry then
                        SeenComponentKeys[Key] = true
                        Output[#Output + 1] = Component
                    end
                end
            end
        end
    end
    return Output
end

function ScorpionDiscoverPaintPlan(Vehicle)
    local VehicleActor = ScorpionResolveVehicleFromObject(Vehicle)
    if IsValidObject(VehicleActor) then Vehicle = VehicleActor end
    if not ScorpionIsScorpionActor(Vehicle) then return nil end

    local VehicleKey = ScorpionVehicleToken(Vehicle)
    local Cached = ScorpionPaintPlanCacheByVehicle[VehicleKey]
    if type(Cached) == "table" and WarthogSameObject(Cached.Vehicle, Vehicle) and type(Cached.Plan) == "table" then
        local Valid = #Cached.Plan > 0
        for _, Item in ipairs(Cached.Plan) do
            if not IsValidObject(Item.MID) or type(Item.Infos) ~= "table" or #Item.Infos == 0 then
                Valid = false break
            end
        end
        if Valid then return Cached.Plan end
    end

    local Components = {}
    local SeenComponentKeys = {}
    for _, RawComponent in ipairs(WarthogGetActorComponents(Vehicle)) do
        local Component = Unwrap(RawComponent)
        if IsValidObject(Component) then
            local Key = tostring(SafeFullName(Component) or SafeToString(Component) or "")
            if Key ~= "" and not SeenComponentKeys[Key] then
                SeenComponentKeys[Key] = true
                Components[#Components + 1] = Component
            end
        end
    end
    local ExtraTurretComponents = ScorpionExtraTurretComponents(Vehicle, SeenComponentKeys)
    for _, Component in ipairs(ExtraTurretComponents) do
        Components[#Components + 1] = Component
    end
    -- Do not mark the late anti-infantry turret ready merely because its mesh
    -- components exist. Restart Mission can create the components first and
    -- replace their slot materials/MIDs a little later. Readiness is confirmed
    -- only by the bounded repair pass after all six known paint slots are seen.

    local Plan = {}
    local PlanByMID = {}
    local SeenSlots = {}
    local AntiInfantryPaintSlotSeen = {}
    local MIDFailures = 0

    local function AddMID(MID, Infos, MaterialText)
        local MIDKey = tostring(SafeFullName(MID) or SafeToString(MID) or tostring(MID))
        local Item = PlanByMID[MIDKey]
        if Item == nil then
            Item = { MID=MID, Infos={}, SeenInfo={}, Material=MaterialText }
            PlanByMID[MIDKey] = Item
            Plan[#Plan + 1] = Item
        end
        for _, InfoEntry in ipairs(Infos or {}) do
            local InfoKey = tostring(InfoEntry.Name) .. "@" .. tostring(InfoEntry.Index)
            if not Item.SeenInfo[InfoKey] then
                -- ORIGINAL must always come from the authored/base material. A
                -- ScorpionColorMID can survive Restart Mission with the previous
                -- custom color still applied; reading that MID here would make
                -- a surviving custom color become a false ORIGINAL.
                local Original = InfoEntry.Original
                if Original ~= nil then
                    Item.SeenInfo[InfoKey] = true
                    Item.Infos[#Item.Infos + 1] = {
                        Name=InfoEntry.Name, Info=InfoEntry.Info, Index=InfoEntry.Index,
                        Original=WarthogCopyLinearColor(Original),
                    }
                end
            end
        end
    end

    for _, Component in ipairs(Components) do
        if IsValidObject(Component) then
            local MeshText = WarthogComponentMeshAssetText(Component)
            local ComponentText = tostring(SafeFullName(Component) or SafeToString(Component) or "")
            for _, SlotEntry in ipairs(WarthogComponentMaterialSlots(Component)) do
                local Slot = tonumber(SlotEntry.Slot) or 0
                local Material = Unwrap(SlotEntry.Material)
                if IsValidObject(Material) then
                    local SlotKey = ComponentText .. "|" .. tostring(Slot)
                    if not SeenSlots[SlotKey] then
                        SeenSlots[SlotKey] = true
                        local MaterialText = tostring(SafeFullName(Material) or SafeToString(Material) or "")
                        if ScorpionPaintSlotWanted(MeshText, MaterialText, ComponentText, Material) then
                            local Infos = ScorpionBasePaintInfosForMaterial(Material)
                            if #Infos > 0 then
                                local MID = ScorpionCreateDynamicPaintMID(Component, Slot, Material)
                                if IsValidObject(MID) then
                                    local AntiSignature = ScorpionAntiInfantryPaintSlotSignature(MeshText, Slot)
                                    if AntiSignature ~= nil then AntiInfantryPaintSlotSeen[AntiSignature] = true end
                                    AddMID(MID, Infos, MaterialText)
                                else
                                    MIDFailures = MIDFailures + 1
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    local CompactPlan = {}
    for _, Item in ipairs(Plan) do
        Item.SeenInfo = nil
        if IsValidObject(Item.MID) and #Item.Infos > 0 then CompactPlan[#CompactPlan + 1] = Item end
    end
    if #CompactPlan == 0 then
        Log("SCORPION COLOR material mapping failed vehicle=%s midFailures=%d", tostring(VehicleKey), MIDFailures)
        return nil
    end

    local AntiInfantryPaintSlots = 0
    for _, _ in pairs(AntiInfantryPaintSlotSeen) do AntiInfantryPaintSlots = AntiInfantryPaintSlots + 1 end
    ScorpionPaintPlanCacheByVehicle[VehicleKey] = {
        Vehicle=Vehicle, Plan=CompactPlan, AntiInfantryPaintSlots=AntiInfantryPaintSlots
    }
    if AntiInfantryPaintSlots >= 6 then
        ScorpionTurretRepairReadyByVehicle[VehicleKey] = ScorpionColorRuntimeGeneration
    end
    return CompactPlan
end

function ScorpionCollectLateTurretPlanItems(Vehicle, ExistingPlan, ForceCandidateRefresh)
    Vehicle = Unwrap(Vehicle)
    if not ScorpionIsScorpionActor(Vehicle) then return {}, 0, {} end

    local ExistingMIDKeys = {}
    for _, Item in ipairs(ExistingPlan or {}) do
        local MID = Unwrap(Item.MID)
        if IsValidObject(MID) then
            local Key = tostring(SafeFullName(MID) or SafeToString(MID) or "")
            if Key ~= "" then ExistingMIDKeys[Key] = true end
        end
    end

    -- Repair starts with the Scorpion actor's own components. Some RestartLevel
    -- paths migrate the anti-infantry meshes onto the vehicle actor itself, which
    -- an attached-only repair can miss these components after RestartLevel.
    local Components = {}
    local SeenComponentKeys = {}
    local function AddComponent(Component)
        Component = Unwrap(Component)
        if not IsValidObject(Component) then return end
        local Key = tostring(SafeFullName(Component) or SafeToString(Component) or "")
        if Key == "" or SeenComponentKeys[Key] then return end
        local MeshText = WarthogComponentMeshAssetText(Component)
        if string.find(string.lower(tostring(MeshText or "")), "scorpionantiinfantry", 1, true) ~= nil then
            SeenComponentKeys[Key] = true
            Components[#Components + 1] = Component
        end
    end
    for _, Component in ipairs(WarthogGetActorComponents(Vehicle)) do AddComponent(Component) end
    for _, Component in ipairs(ScorpionExtraTurretComponents(Vehicle, SeenComponentKeys, ForceCandidateRefresh)) do
        AddComponent(Component)
    end

    local Added = {}
    local SeenAdded = {}
    local CurrentTurretPlan = {}
    local CurrentPlanByMID = {}
    local AntiInfantryPaintSlotSeen = {}

    local function BuildItem(MID, Infos, MaterialText)
        local MIDKey = tostring(SafeFullName(MID) or SafeToString(MID) or "")
        if MIDKey == "" then return nil, MIDKey end
        local Item = CurrentPlanByMID[MIDKey]
        if Item == nil then
            Item = { MID=MID, Infos={}, SeenInfo={}, Material=MaterialText }
            CurrentPlanByMID[MIDKey] = Item
            CurrentTurretPlan[#CurrentTurretPlan + 1] = Item
        end
        for _, InfoEntry in ipairs(Infos or {}) do
            if InfoEntry.Info ~= nil and InfoEntry.Original ~= nil then
                local InfoKey = tostring(InfoEntry.Name) .. "@" .. tostring(InfoEntry.Index)
                if not Item.SeenInfo[InfoKey] then
                    Item.SeenInfo[InfoKey] = true
                    Item.Infos[#Item.Infos + 1] = {
                        Name=InfoEntry.Name,
                        Info=InfoEntry.Info,
                        Index=InfoEntry.Index,
                        Original=WarthogCopyLinearColor(InfoEntry.Original),
                    }
                end
            end
        end
        return Item, MIDKey
    end

    for _, Component in ipairs(Components) do
        local MeshText = WarthogComponentMeshAssetText(Component)
        local ComponentText = tostring(SafeFullName(Component) or SafeToString(Component) or "")
        for _, SlotEntry in ipairs(WarthogComponentMaterialSlots(Component)) do
            local Slot = tonumber(SlotEntry.Slot) or 0
            local Signature = ScorpionAntiInfantryPaintSlotSignature(MeshText, Slot)
            if Signature ~= nil then
                local Material = Unwrap(SlotEntry.Material)
                if IsValidObject(Material) then
                    local MaterialText = tostring(SafeFullName(Material) or SafeToString(Material) or "")
                    if ScorpionPaintSlotWanted(MeshText, MaterialText, ComponentText, Material) then
                        local Infos = ScorpionBasePaintInfosForMaterial(Material)
                        if #Infos > 0 then
                            local MID = ScorpionCreateDynamicPaintMID(Component, Slot, Material)
                            if IsValidObject(MID) then
                                AntiInfantryPaintSlotSeen[Signature] = true
                                local Item, MIDKey = BuildItem(MID, Infos, MaterialText)
                                if Item ~= nil and not ExistingMIDKeys[MIDKey] and not SeenAdded[MIDKey] then
                                    SeenAdded[MIDKey] = true
                                    Added[#Added + 1] = Item
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    local CompactCurrent = {}
    for _, Item in ipairs(CurrentTurretPlan) do
        Item.SeenInfo = nil
        if IsValidObject(Item.MID) and #Item.Infos > 0 then CompactCurrent[#CompactCurrent + 1] = Item end
    end
    local AntiInfantryPaintSlots = 0
    for _, _ in pairs(AntiInfantryPaintSlotSeen) do AntiInfantryPaintSlots = AntiInfantryPaintSlots + 1 end
    return Added, AntiInfantryPaintSlots, CompactCurrent
end

function ScorpionScheduleTurretRepair(PlayerIndex, VehicleKey, Attempt)
    Attempt = tonumber(Attempt) or 1
    if Attempt > 2 then return end

    local ScheduleKey = tostring(PlayerIndex) .. ":" .. tostring(VehicleKey)
    if ScorpionTurretRepairScheduledByVehicle[ScheduleKey] then return end
    ScorpionTurretRepairScheduledByVehicle[ScheduleKey] = true

    local RuntimeGeneration = ScorpionColorRuntimeGeneration
    local DelayMs = Attempt == 1 and 450 or 1400
    ExecuteInGameThreadWithDelay(DelayMs, function()
        ScorpionTurretRepairScheduledByVehicle[ScheduleKey] = nil
        if RuntimeGeneration ~= ScorpionColorRuntimeGeneration or not MissionReady then return end

        local CacheEntry = ScorpionPaintPlanCacheByVehicle[VehicleKey]
        if type(CacheEntry) ~= "table" or not IsValidObject(CacheEntry.Vehicle)
            or type(CacheEntry.Plan) ~= "table" or #CacheEntry.Plan == 0 then
            return
        end

        local Vehicle = CacheEntry.Vehicle
        if tostring(ScorpionVehicleToken(Vehicle)) ~= tostring(VehicleKey) then return end

        -- Attempt 1 is cheap: direct vehicle components + retained turret cache.
        -- Only if that cannot resolve all six exact slots do we allow one fresh
        -- global candidate scan on the final bounded fallback pass.
        local ForceCandidateRefresh = Attempt == 2
        local Added, AntiInfantryPaintSlots, CurrentTurretPlan = ScorpionCollectLateTurretPlanItems(
            Vehicle, CacheEntry.Plan, ForceCandidateRefresh)
        if #Added > 0 then
            for _, Item in ipairs(Added) do CacheEntry.Plan[#CacheEntry.Plan + 1] = Item end
        end
        CacheEntry.AntiInfantryPaintSlots = AntiInfantryPaintSlots

        -- Reapply only the six anti-infantry paint slots; refreshing the entire
        -- Scorpion paint plan here is unnecessary and can cause a visible hitch.
        local State = tonumber(ScorpionColorIndexByVehicle[VehicleKey])
        if State ~= nil and type(CurrentTurretPlan) == "table" and #CurrentTurretPlan > 0 then
            local IsOriginal = State == 0
            local Color = IsOriginal and nil or ScorpionCEColors[State]
            ScorpionApplyPaintPlan(CurrentTurretPlan, Color, IsOriginal)
        end

        if AntiInfantryPaintSlots >= 6 then
            ScorpionTurretRepairReadyByVehicle[VehicleKey] = ScorpionColorRuntimeGeneration
            return
        end

        if Attempt < 2 then
            ScorpionScheduleTurretRepair(PlayerIndex, VehicleKey, Attempt + 1)
        else
            Log("SCORPION COLOR anti-infantry turret repair incomplete vehicle=%s slots=%d/6",
                tostring(VehicleKey), tonumber(AntiInfantryPaintSlots) or 0)
        end
    end)
end

function ScorpionApplyPaintPlan(Plan, Color, RestoreOriginal)
    local SelectedLinear = (not RestoreOriginal and Color ~= nil) and WarthogColorLinear(Color) or nil
    local AppliedMIDs = 0
    local Failures = 0
    for _, Item in ipairs(Plan or {}) do
        local AppliedThisMID = false
        for _, Entry in ipairs(Item.Infos or {}) do
            local Value = RestoreOriginal and Entry.Original or SelectedLinear
            if Value ~= nil then
                local Ok = pcall(function() Item.MID:SetVectorParameterValueByInfo(Entry.Info, Value) end)
                if Ok then AppliedThisMID = true else Failures = Failures + 1 end
            end
        end
        if AppliedThisMID then AppliedMIDs = AppliedMIDs + 1 end
    end
    return AppliedMIDs > 0 and Failures == 0, AppliedMIDs, Failures
end

function CycleOccupiedScorpionColor(PlayerIndex, Delta, Source)
    if not MissionReady then return false end
    local Controller = GetPlayer(PlayerIndex)
    if not IsValidObject(Controller) then return false end

    local Vehicle, Pawn, DriverState, OccupiedVehicle = ScorpionFindDriverVehicleFast(PlayerIndex, false)
    if not IsValidObject(Vehicle) then
        if IsValidObject(OccupiedVehicle) and DriverState == false then
            ScreenMessage(PlayerIndex, Controller, "SCORPION COLOR: DRIVER ONLY")
        end
        return false
    end

    local Plan = ScorpionDiscoverPaintPlan(Vehicle)
    if type(Plan) ~= "table" or #Plan == 0 then
        ScreenMessage(PlayerIndex, Controller, "SCORPION COLOR: MATERIAL ERROR")
        return false
    end

    local VehicleKey = ScorpionVehicleToken(Vehicle)
    local Current = tonumber(ScorpionColorIndexByVehicle[VehicleKey])
    local UsedCheckpointCarry = false
    if Current == nil then
        local Carry = tonumber(ScorpionCheckpointColorCarryByPlayer[PlayerIndex])
        if Carry ~= nil then
            Current = Carry
            UsedCheckpointCarry = true
        else
            Current = 0
        end
    end

    local Step = (tonumber(Delta) or 1) < 0 and -1 or 1
    local Next = Current + Step
    if Next > #ScorpionCEColors then Next = 0 end
    if Next < 0 then Next = #ScorpionCEColors end
    local IsOriginal = Next == 0
    local Color = IsOriginal and nil or ScorpionCEColors[Next]
    local Applied, AppliedMIDs, Failures = ScorpionApplyPaintPlan(Plan, Color, IsOriginal)
    if not Applied then
        Log("SCORPION COLOR apply failed vehicle=%s state=%s mids=%d failures=%d",
            tostring(VehicleKey), IsOriginal and "ORIGINAL" or tostring(Color.Name),
            tonumber(AppliedMIDs) or 0, tonumber(Failures) or 0)
        ScreenMessage(PlayerIndex, Controller, "SCORPION COLOR: APPLY ERROR")
        return false
    end

    ScorpionColorIndexByVehicle[VehicleKey] = Next
    ScorpionLastColorIndexByPlayer[PlayerIndex] = Next
    VehicleNetworkPostLocalPaint(Vehicle, "Scorpion", IsOriginal and "ORIGINAL" or tostring(Color.Name))
    if UsedCheckpointCarry then ScorpionCheckpointColorCarryByPlayer[PlayerIndex] = nil end

    -- If Restart Mission rebuilt the hull before the attached anti-infantry
    -- turret, repair that late accessory in the background and immediately
    -- apply the already-authorized selected color when it appears.
    if tonumber(ScorpionTurretRepairReadyByVehicle[VehicleKey]) ~= tonumber(ScorpionColorRuntimeGeneration) then
        ScorpionScheduleTurretRepair(PlayerIndex, VehicleKey, 1)
    end

    if IsOriginal then
        ScreenMessage(PlayerIndex, Controller, "SCORPION COLOR: ORIGINAL")
    else
        ScreenMessage(PlayerIndex, Controller,
            string.format("SCORPION COLOR %02d/%02d: %s", Next, #ScorpionCEColors, tostring(Color.Name)))
    end
    return true
end

function CycleOccupiedVehicleColor(PlayerIndex, Delta, Source)
    if CycleOccupiedWarthogColor(PlayerIndex, Delta, Source) then return true end
    return CycleOccupiedScorpionColor(PlayerIndex, Delta, Source)
end


-- Default Spartan armor-skin cycling -----------------------------------------
-- v1.11.0 RC2 integrates the proven HCEArmor compact VT route directly into
-- Co-op Expanded. Stock MI_Chief_Armor stays in place; only its layered
-- "Diffuse Map" texture parameters are replaced on runtime MIDs.
--
-- The logical skin order deliberately reuses WarthogCEColors so on-foot armor
-- and Warthog/Scorpion paint can never drift apart:
--   0 ORIGINAL GREEN, then BLACK, RED, BLUE ... WHITE.
-- Hold X + D-pad Left/Right (or Ctrl+PageUp/PageDown) cycles this skin list on foot.
-- RB+LS/RS remains dedicated to Warthog/Scorpion vehicle paint.
-- RB+D-pad Left/Right remains the separate authored armor-model browser.
IdentityNameProtocol = 2
ArmorSkinTextureCache = ArmorSkinTextureCache or {}
ArmorSkinAppliedByTarget = ArmorSkinAppliedByTarget or {}
-- V12: Classic armor is a real user selection, not merely a runtime material cache.
-- Keep it through respawn, map/menu travel and process restarts on both Steam/Win64
-- and GamePass/WinGDK.  The file lives beside settings.ini in the mod directory.
ClassicArmorMenuSelectedByPlayer = ClassicArmorMenuSelectedByPlayer or { [1] = 0, [2] = 0 }
ClassicArmorPersistentStatePath = ClassicArmorPersistentStatePath or GetModFilePath("classic_armor_state.ini")
ClassicArmorPersistentLastSaved = ClassicArmorPersistentLastSaved or ""
ClassicArmorPersistentLoaded = ClassicArmorPersistentLoaded == true

function ClassicArmorPersistentSignature()
    local P1 = math.max(0, math.min(#WarthogCEColors, tonumber(ClassicArmorMenuSelectedByPlayer[1]) or 0))
    local P2 = math.max(0, math.min(#WarthogCEColors, tonumber(ClassicArmorMenuSelectedByPlayer[2]) or 0))
    return string.format("P1=%d\nP2=%d\n", P1, P2)
end

function ClassicArmorSavePersistentState(Source)
    if type(io) ~= "table" or type(io.open) ~= "function" then return false end
    local Body = ClassicArmorPersistentSignature()
    if Body == tostring(ClassicArmorPersistentLastSaved or "") then return true end
    local F, Err = io.open(ClassicArmorPersistentStatePath, "w")
    if not F then
        Log("CLASSIC18V12 persistence write failed path=%s error=%s source=%s",
            tostring(ClassicArmorPersistentStatePath), tostring(Err), tostring(Source or "selection"))
        return false
    end
    F:write("# HCE Co-op Expanded Classic armor selection\n")
    F:write(Body)
    F:close()
    ClassicArmorPersistentLastSaved = Body
    Log("CLASSIC18V12 persistence saved P1=%s P2=%s source=%s",
        ArmorSkinColorLabel and ArmorSkinColorLabel(tonumber(ClassicArmorMenuSelectedByPlayer[1]) or 0) or tostring(ClassicArmorMenuSelectedByPlayer[1]),
        ArmorSkinColorLabel and ArmorSkinColorLabel(tonumber(ClassicArmorMenuSelectedByPlayer[2]) or 0) or tostring(ClassicArmorMenuSelectedByPlayer[2]),
        tostring(Source or "selection"))
    return true
end

function ClassicArmorLoadPersistentState()
    if ClassicArmorPersistentLoaded then return true end
    ClassicArmorPersistentLoaded = true
    if type(io) ~= "table" or type(io.open) ~= "function" then return false end
    local F = io.open(ClassicArmorPersistentStatePath, "r")
    if not F then
        ClassicArmorPersistentLastSaved = ClassicArmorPersistentSignature()
        Log("CLASSIC18V12 persistence no prior state; using ORIGINAL GREEN")
        return false
    end
    local P1, P2 = nil, nil
    for Line in F:lines() do
        local I, V = string.match(Line, "^%s*P([12])%s*=%s*(%d+)%s*$")
        I, V = tonumber(I), tonumber(V)
        if I and V and V >= 0 and V <= #WarthogCEColors then
            if I == 1 then P1 = V elseif I == 2 then P2 = V end
        end
    end
    F:close()
    if P1 ~= nil then ClassicArmorMenuSelectedByPlayer[1] = P1 end
    if P2 ~= nil then ClassicArmorMenuSelectedByPlayer[2] = P2 end
    ClassicArmorPersistentLastSaved = ClassicArmorPersistentSignature()
    Log("CLASSIC18V12 persistence loaded P1=%s P2=%s path=%s",
        tostring(ClassicArmorMenuSelectedByPlayer[1]), tostring(ClassicArmorMenuSelectedByPlayer[2]),
        tostring(ClassicArmorPersistentStatePath))
    return true
end

function ClassicArmorSetPersistentSelection(PlayerIndex, ColorIndex, Source)
    PlayerIndex = math.max(1, math.min(2, tonumber(PlayerIndex) or 1))
    ColorIndex = math.max(0, math.min(#WarthogCEColors, tonumber(ColorIndex) or 0))
    ClassicArmorMenuSelectedByPlayer[PlayerIndex] = ColorIndex
    if type(ArmorSkinLocalIndexByPlayer) == "table" then ArmorSkinLocalIndexByPlayer[PlayerIndex] = ColorIndex end
    ClassicArmorSavePersistentState(Source or "selection")
    return ColorIndex
end

ClassicArmorLoadPersistentState()
ArmorSkinLocalIndexByPlayer = ArmorSkinLocalIndexByPlayer or {
    [1] = tonumber(ClassicArmorMenuSelectedByPlayer[1]) or 0,
    [2] = tonumber(ClassicArmorMenuSelectedByPlayer[2]) or 0,
}
ArmorSkinLocalApplyToken = ArmorSkinLocalApplyToken or { [1] = 0, [2] = 0 }
ArmorSkinLocalSettledToken = ArmorSkinLocalSettledToken or { [1] = 0, [2] = 0 }
ArmorSkinMaintainCounter = ArmorSkinMaintainCounter or { [1] = 0, [2] = 0 }
-- First-person arms are constructed on a slightly different lifecycle from the
-- third-person biped. Keep retry/backoff state per rendered target so a color
-- selected before the arms mesh exists can repair itself without rebuilding
-- third-person MIDs every frame.
ArmorSkinFirstPersonRetryByTarget = ArmorSkinFirstPersonRetryByTarget or {}
ArmorSkinPerspectiveRebindToken = ArmorSkinPerspectiveRebindToken or { [1] = 0, [2] = 0 }
ArmorSkinNetworkColorByPlayerId = ArmorSkinNetworkColorByPlayerId or {}
ArmorSkinNetworkPendingTokenByPlayerId = ArmorSkinNetworkPendingTokenByPlayerId or {}
ArmorSkinNetworkSequence = ArmorSkinNetworkSequence or 0
ArmorSkinNetworkUplinkSequence = ArmorSkinNetworkUplinkSequence or 0
ArmorSkinNetworkLastReceivedSequenceByPlayerId = ArmorSkinNetworkLastReceivedSequenceByPlayerId or {}
ArmorSkinNetworkLastUplinkSequenceByController = ArmorSkinNetworkLastUplinkSequenceByController or {}
ArmorSkinHostCapabilitySeen = ArmorSkinHostCapabilitySeen or false
ArmorSkinCapabilityAckByController = ArmorSkinCapabilityAckByController or {}
ArmorSkinNetworkResolveRouteByPlayerId = ArmorSkinNetworkResolveRouteByPlayerId or {}
ArmorSkinNetworkLastPublishedLocalColorByPlayerId = ArmorSkinNetworkLastPublishedLocalColorByPlayerId or {}
ArmorSkinUplinkControllerByPlayerId = ArmorSkinUplinkControllerByPlayerId or {}
ArmorSkinUplinkRouteMetaByPlayerId = ArmorSkinUplinkRouteMetaByPlayerId or {}
ArmorSkinUplinkProbeGenerationByController = ArmorSkinUplinkProbeGenerationByController or {}
-- RC3_42: preserve the originating LOCAL slot (P1/P2) as separate network
-- metadata. PlayerId is only an opaque replicated identity and is never used
-- to infer split-screen slot order.
ArmorSkinNetworkOriginSlotByPlayerId = ArmorSkinNetworkOriginSlotByPlayerId or {}
-- RC3_49: authority-local P1->P2 render-space vector.  The authority knows
-- exact local biped identity via Pawn.Children, so send only the relative
-- vector; observer-specific world/presentation translation cancels out.
ArmorSkinPairVectorSequence = ArmorSkinPairVectorSequence or 0
ArmorSkinPairVectorUplinkSequence = ArmorSkinPairVectorUplinkSequence or 0
ArmorSkinRemotePairVector = ArmorSkinRemotePairVector or nil
ArmorSkinPairVectorLastSignatureByController = ArmorSkinPairVectorLastSignatureByController or {}
ArmorSkinPairVectorLastClientUplinkSignature = ArmorSkinPairVectorLastClientUplinkSignature or ""
ArmorSkinPairVectorLastUplinkSequenceByController = ArmorSkinPairVectorLastUplinkSequenceByController or {}
ArmorSkinPairVectorAuditLogged = ArmorSkinPairVectorAuditLogged or {}
ArmorSkinPairVectorRetryTokenByController = ArmorSkinPairVectorRetryTokenByController or {}
ArmorSkinPairVectorSourceReadyGeneration = ArmorSkinPairVectorSourceReadyGeneration or -1
ArmorSkinPairVectorReadyCheckCounter = ArmorSkinPairVectorReadyCheckCounter or 0
ArmorSkinRespawnPairVectorToken = ArmorSkinRespawnPairVectorToken or 0
ArmorSkinRespawnLocalReapplyToken = ArmorSkinRespawnLocalReapplyToken or 0
ArmorSkinRespawnSettleToken = ArmorSkinRespawnSettleToken or 0
ArmorSkinBipedWriteQuietUntilClock = tonumber(ArmorSkinBipedWriteQuietUntilClock) or 0
-- RC3_58: remember only the current BP_SpartansBipedActor construction burst.
-- This lets a receiver distinguish freshly respawned remote presentation bodies
-- from old corpses without suffix/order guesses or a global reflection scan.
ArmorSkinFreshBipedByKey = ArmorSkinFreshBipedByKey or {}
ArmorSkinLastBipedConstructionClock = tonumber(ArmorSkinLastBipedConstructionClock) or 0
ArmorSkinFreshBipedWindowSeconds = 0.75

-- RC3_59: old per-slot MIDs caused visible hitches even when time-sliced.
-- Jobs now bind shared world-owned palette MIDs; expensive parameter setup occurs
-- once per unique source-material/scope/color instead of once per armor slot.
ArmorSkinSlicedJobsByTarget = ArmorSkinSlicedJobsByTarget or {}
ArmorSkinSlicedJobOrder = ArmorSkinSlicedJobOrder or {}
ArmorSkinSlicedPumpToken = tonumber(ArmorSkinSlicedPumpToken) or 0
ArmorSkinSlicedPumpScheduled = ArmorSkinSlicedPumpScheduled or false
ArmorSkinSlicedSerial = tonumber(ArmorSkinSlicedSerial) or 0
-- RC3_59 shared-palette path: once a palette MID exists, slot work is only a
-- cheap SetMaterial/GetMaterial binding operation. Process a small batch per pump
-- so a full 38-slot Spartan completes quickly without the old per-slot MID cost.
ArmorSkinSlicedSliceDelayMs = 8
ArmorSkinSlicedUpdateDelayMs = 8
ArmorSkinSlicedVerifyPasses = 2
ArmorSkinPaletteBindBatchSize = 8
ArmorSkinPaletteMIDByKey = ArmorSkinPaletteMIDByKey or {}
ArmorSkinPaletteSourceByMIDKey = ArmorSkinPaletteSourceByMIDKey or {}
ArmorSkinPaletteLibraryCache = ArmorSkinPaletteLibraryCache or nil
ArmorSkinPaletteSerial = tonumber(ArmorSkinPaletteSerial) or 0
ArmorSkinPaletteCreatedCount = tonumber(ArmorSkinPaletteCreatedCount) or 0
-- RC3_60: one mutable shared MID set per logical player + stock parent/scope.
-- Textures are already prewarmed in frontend. Color changes now mutate only these
-- 2-3 shared MIDs; the 20/38 mesh slots remain bound to the same material objects.
ArmorSkinPlayerMIDByKey = ArmorSkinPlayerMIDByKey or {}
ArmorSkinPlayerMIDPrewarmToken = tonumber(ArmorSkinPlayerMIDPrewarmToken) or 0
ArmorSkinPlayerMIDPrewarmGeneration = tonumber(ArmorSkinPlayerMIDPrewarmGeneration) or -1
ArmorSkinPlayerMIDCreatedCount = tonumber(ArmorSkinPlayerMIDCreatedCount) or 0
ArmorSkinPersistentPlayerMIDSerial = tonumber(ArmorSkinPersistentPlayerMIDSerial) or 0
ArmorSkinLocalReassertToken = ArmorSkinLocalReassertToken or { [1]=0, [2]=0 }
ArmorSkinRespawnIdentityRetryToken = tonumber(ArmorSkinRespawnIdentityRetryToken) or 0
ArmorSkinRespawnIdentitySettledGeneration = tonumber(ArmorSkinRespawnIdentitySettledGeneration) or -1
IdentityNameUplinkSequence = IdentityNameUplinkSequence or 0
IdentityNameLastPublishedByPlayerId = IdentityNameLastPublishedByPlayerId or {}
IdentityNameLastUplinkSequenceByController = IdentityNameLastUplinkSequenceByController or {}
IdentityFrontendNamePublishToken = IdentityFrontendNamePublishToken or 0
IdentityFrontendNameLastSignature = IdentityFrontendNameLastSignature or ""
ArmorSkinRemoteSplitSlotAuditLogged = ArmorSkinRemoteSplitSlotAuditLogged or {}
-- RC3_43: world travel destroys all render/MID objects, but color choice is
-- logical fireteam state. Keep only remote logical color + explicit source slot
-- across mission/frontend travel. Runtime PlayerId tables are still cleared,
-- then safely repopulated only for PlayerIds that exist in the new world.
-- PlayerId is NEVER interpreted as P1/P2; it is only an opaque identity key.
ArmorSkinPersistentRemoteColorByPlayerId = ArmorSkinPersistentRemoteColorByPlayerId or {}
ArmorSkinPersistentRemoteOriginSlotByPlayerId = ArmorSkinPersistentRemoteOriginSlotByPlayerId or {}
ArmorSkinPersistentRestoreAuditGeneration = ArmorSkinPersistentRestoreAuditGeneration or -1
ArmorSkinTexturePrewarmToken = ArmorSkinTexturePrewarmToken or 0
ArmorSkinTexturePrewarmComplete = ArmorSkinTexturePrewarmComplete or false
ArmorSkinTextureKeeperByColor = ArmorSkinTextureKeeperByColor or {}
ArmorSkinTextureKeeperParent = ArmorSkinTextureKeeperParent
ArmorSkinTextureKeeperClass = ArmorSkinTextureKeeperClass
ArmorSkinTextureKeeperGameInstance = ArmorSkinTextureKeeperGameInstance
ArmorSkinTexturePrewarmRequestedGeneration = ArmorSkinTexturePrewarmRequestedGeneration or -1
ArmorSkinRemoteBipedRouteLogged = ArmorSkinRemoteBipedRouteLogged or {}
ArmorSkinRemoteBipedFailureLogged = ArmorSkinRemoteBipedFailureLogged or {}
ArmorSkinRemoteAttachedAuditLogged = ArmorSkinRemoteAttachedAuditLogged or {}
-- RC3_34: network observers do not expose the rendered Spartan through the
-- replicated Pawn component tree. Cache only the two *specific* presentation
-- classes involved in Spartan rendering; never scan generic mesh components.
ArmorSkinBipedClass = ArmorSkinBipedClass
ArmorSkinBipedInstanceCache = ArmorSkinBipedInstanceCache or {}
ArmorSkinBipedInstanceSeen = ArmorSkinBipedInstanceSeen or {}
ArmorSkinBipedExactScanGeneration = ArmorSkinBipedExactScanGeneration or -1
-- RC3_35: exact BP_SpartansBipedActor instances are the useful remote render
-- containers.  They are not necessarily outered/attached to the replicated
-- BP_MeteoritePawn on an observing peer, so keep an explicit pawn->biped map.
ArmorSkinBipedAssignmentByPawnKey = ArmorSkinBipedAssignmentByPawnKey or {}
ArmorSkinBipedAssignmentMetaByPawnKey = ArmorSkinBipedAssignmentMetaByPawnKey or {}
-- V15: string-only identity memory survives assignment invalidation safely.
-- Never retain extra UObject refs here; keys are used only to recognize a remote
-- player whose presentation biped did NOT change while the other player respawned.
ArmorSkinLastKnownBipedKeyByPlayerId = ArmorSkinLastKnownBipedKeyByPlayerId or {}
ArmorSkinBipedAssignmentAuditLogged = ArmorSkinBipedAssignmentAuditLogged or {}
ArmorSkinBipedAnchorPendingLogged = ArmorSkinBipedAnchorPendingLogged or {}
-- RC3_39: multi-remote identity helpers. These are bounded to the already
-- discovered BP_SpartansBipedActor_C objects; never generic mesh scans.
ArmorSkinBipedMotionBaseline = ArmorSkinBipedMotionBaseline or {}
ArmorSkinBipedOrdinalAuditLogged = ArmorSkinBipedOrdinalAuditLogged or {}
-- RC3_42: safe multi-remote identity. PlayerId remains an opaque replicated
-- identity token. P1/P2 is carried explicitly as origin-slot metadata in armor
-- protocol 2, so join order and numeric PlayerId assignment are irrelevant.
-- The only inferred presentation rule is the repeatedly observed two-player
-- REMOTE split pair: its generated biped instance order is reversed relative to
-- the originating local P1/P2 slot order. No movement/global mesh scan is used.
ArmorSkinPlayerIdOrdinalHint = ArmorSkinPlayerIdOrdinalHint
ArmorSkinOrdinalHintSentByController = ArmorSkinOrdinalHintSentByController or {}
ArmorSkinOrdinalAuditLogged = ArmorSkinOrdinalAuditLogged or {}
ArmorSkinTopologySentinelPlayerId = 2147483646
ArmorSkinTopologySameCode = 100
ArmorSkinTopologyReverseCode = 101
ArmorSkinCVWSkeletalClass = ArmorSkinCVWSkeletalClass
ArmorSkinCVWSkeletalCache = ArmorSkinCVWSkeletalCache or {}
ArmorSkinCVWSkeletalSeen = ArmorSkinCVWSkeletalSeen or {}
ArmorSkinCVWExactScanGeneration = ArmorSkinCVWExactScanGeneration or -1
ArmorSkinCVWConstructionListenerReady = ArmorSkinCVWConstructionListenerReady or false
ArmorSkinChiefPresentationClasses = ArmorSkinChiefPresentationClasses or {}
ArmorSkinChiefPresentationClassSeen = ArmorSkinChiefPresentationClassSeen or {}
ArmorSkinSyncReflectionAuditLogged = ArmorSkinSyncReflectionAuditLogged or {}
ArmorSkinBipedConstructionListenerReady = ArmorSkinBipedConstructionListenerReady or false
ArmorSkinDefaultCatalogIndex = ArmorSkinDefaultCatalogIndex

function ArmorSkinContainsCI(Haystack, Needle)
    return string.find(string.lower(tostring(Haystack or "")), string.lower(tostring(Needle or "")), 1, true) ~= nil
end

function ArmorSkinPlayerIdFromController(Controller)
    Controller = Unwrap(Controller)
    if not IsValidObject(Controller) or not IsValidObject(Controller.PlayerState) then return nil end
    local Value = nil
    pcall(function() Value = Unwrap(Controller.PlayerState.PlayerId) end)
    return tonumber(Value)
end

function ArmorSkinPlayerIdFromPawn(Pawn)
    Pawn = Unwrap(Pawn)
    if not IsValidObject(Pawn) then return nil end
    local State = nil
    pcall(function() State = Unwrap(Pawn.PlayerState) end)
    if IsValidObject(State) then
        local Value = nil
        pcall(function() Value = Unwrap(State.PlayerId) end)
        if tonumber(Value) ~= nil then return tonumber(Value) end
    end
    local Controller = nil
    pcall(function() Controller = Unwrap(Pawn.Controller) end)
    if not IsValidObject(Controller) then pcall(function() Controller = Unwrap(Pawn:GetController()) end) end
    return ArmorSkinPlayerIdFromController(Controller)
end

function ArmorSkinTargetKey(PlayerId, PlayerIndex)
    local NumericId = tonumber(PlayerId)
    if NumericId ~= nil then return "P:" .. tostring(math.floor(NumericId)) end
    return "LOCAL:" .. tostring(tonumber(PlayerIndex) or 0)
end

-- UE4SS may materialize a fresh Lua wrapper for the same UObject on separate
-- lookups. Lua table/userdata identity therefore cannot be used to decide that
-- a pawn or biped was replaced. Full UObject names include the actor instance
-- path and remain stable for the lifetime of that instance.
function ArmorSkinObjectKey(Object)
    Object = Unwrap(Object)
    if not IsValidObject(Object) then return nil end
    local Name = SafeFullName(Object)
    if Name ~= nil and tostring(Name) ~= "" then return tostring(Name) end
    return nil
end

function ArmorSkinGetPawnFromController(Controller)
    Controller = Unwrap(Controller)
    if not IsValidObject(Controller) then return nil end
    local Pawn = nil
    pcall(function() Pawn = Unwrap(Controller.Pawn) end)
    if not IsValidObject(Pawn) then pcall(function() Pawn = Unwrap(Controller:GetPawn()) end) end
    return IsValidObject(Pawn) and Pawn or nil
end

function ArmorSkinPlayerIdFromState(State)
    State = Unwrap(State)
    if not IsValidObject(State) then return nil end
    local Value = nil
    pcall(function() Value = Unwrap(State.PlayerId) end)
    return tonumber(Value)
end

function ArmorSkinPawnFromPlayerState(State)
    State = Unwrap(State)
    if not IsValidObject(State) then return nil end
    local Pawn = nil
    -- APlayerState::GetPawn is replicated-client friendly in UE5. If the
    -- reflected call is unavailable on a build, PawnPrivate/property fallbacks
    -- are harmless and remain bounded to the already-matched PlayerState.
    pcall(function() Pawn = Unwrap(State:GetPawn()) end)
    if not IsValidObject(Pawn) then pcall(function() Pawn = Unwrap(State.PawnPrivate) end) end
    if not IsValidObject(Pawn) then pcall(function() Pawn = Unwrap(State.Pawn) end) end
    return IsValidObject(Pawn) and Pawn or nil
end

function ArmorSkinGameState()
    local GameState = nil
    pcall(function()
        local World = UEHelpers.GetWorldContextObject()
        if IsValidObject(World) then GameState = Unwrap(World.GameState) end
    end)
    if not IsValidObject(GameState) then
        pcall(function()
            GameState = Unwrap(GetGameplayStatics():GetGameState(UEHelpers.GetWorldContextObject()))
        end)
    end
    return IsValidObject(GameState) and GameState or nil
end

function ArmorSkinResolvePawnByPlayerId(TargetPlayerId)
    TargetPlayerId = tonumber(TargetPlayerId)
    if TargetPlayerId == nil then return nil, nil, "invalid-player-id" end

    -- Local players first: cheapest and exact for standalone/listen-host and
    -- for the originating network client receiving its own relayed state.
    for PlayerIndex = 1, 2 do
        local Controller = GetPlayer(PlayerIndex)
        if IsValidObject(Controller) and ArmorSkinPlayerIdFromController(Controller) == TargetPlayerId then
            local Pawn = ArmorSkinGetPawnFromController(Controller)
            if IsValidObject(Pawn) then
                return Pawn, Controller, string.format("local-controller-P%d", PlayerIndex)
            end
        end
    end

    -- RC3_29: on an owning network client, remote PlayerControllers normally do
    -- not exist locally. PlayerStates do: GameState.PlayerArray is replicated to
    -- every peer and PlayerState:GetPawn()/PawnPrivate gives us the corresponding
    -- remote pawn. This is the player equivalent of the stable cross-peer
    -- identity lookup already used by Warthog/Scorpion network paint.
    local GameState = ArmorSkinGameState()
    if IsValidObject(GameState) then
        local PlayerArray = nil
        pcall(function() PlayerArray = GameState.PlayerArray end)
        for _, RawState in ipairs(ArrayValues(PlayerArray)) do
            local State = Unwrap(RawState)
            if IsValidObject(State) and ArmorSkinPlayerIdFromState(State) == TargetPlayerId then
                local Pawn = ArmorSkinPawnFromPlayerState(State)
                if IsValidObject(Pawn) then
                    local Controller = nil
                    pcall(function() Controller = Unwrap(Pawn.Controller) end)
                    if not IsValidObject(Controller) then pcall(function() Controller = Unwrap(Pawn:GetController()) end) end
                    return Pawn, IsValidObject(Controller) and Controller or nil, "GameState.PlayerArray/PlayerState.GetPawn"
                end

                -- Some builds expose the PlayerState on the pawn but not GetPawn
                -- to Lua. Match the already-identified PlayerState object directly
                -- before falling back to PlayerId reads from every pawn.
                local StateKey = ArmorSkinObjectKey(State)
                if StateKey ~= nil then
                    local Pawns = nil
                    pcall(function() Pawns = FindAllOf("BP_MeteoritePawn_C") end)
                    for _, RawPawn in ipairs(Pawns or {}) do
                        local Candidate = Unwrap(RawPawn)
                        if IsValidObject(Candidate) then
                            local CandidateState = nil
                            pcall(function() CandidateState = Unwrap(Candidate.PlayerState) end)
                            if IsValidObject(CandidateState) and ArmorSkinObjectKey(CandidateState) == StateKey then
                                local Controller = nil
                                pcall(function() Controller = Unwrap(Candidate.Controller) end)
                                return Candidate, IsValidObject(Controller) and Controller or nil,
                                    "GameState.PlayerArray/PlayerState-object-match"
                            end
                        end
                    end
                end
            end
        end
    end

    -- Existing exact-pawn fallback retained for builds where Pawn.PlayerState is
    -- directly exposed and no GameState helper is needed.
    local Anchor = GetPlayer(1)
    local LevelPrefix = ""
    if IsValidObject(Anchor) then
        LevelPrefix = string.match(SafeFullName(Anchor) or "", "^(.-:PersistentLevel)") or ""
    end

    local Pawns = nil
    pcall(function() Pawns = FindAllOf("BP_MeteoritePawn_C") end)
    for _, RawPawn in ipairs(Pawns or {}) do
        local Pawn = Unwrap(RawPawn)
        if IsValidObject(Pawn) then
            local Name = SafeFullName(Pawn) or ""
            local SameLevel = LevelPrefix == "" or string.find(Name, LevelPrefix, 1, true) ~= nil
            if SameLevel and not string.find(Name, "Default__", 1, true) and ArmorSkinPlayerIdFromPawn(Pawn) == TargetPlayerId then
                local Controller = nil
                pcall(function() Controller = Unwrap(Pawn.Controller) end)
                if not IsValidObject(Controller) then pcall(function() Controller = Unwrap(Pawn:GetController()) end) end
                return Pawn, IsValidObject(Controller) and Controller or nil, "BP_MeteoritePawn PlayerId scan"
            end
        end
    end
    return nil, nil, "unresolved"
end

function ArmorSkinSameObject(A, B)
    A, B = Unwrap(A), Unwrap(B)
    if not IsValidObject(A) or not IsValidObject(B) then return false end
    local AK, BK = ArmorSkinObjectKey(A), ArmorSkinObjectKey(B)
    if AK ~= nil and BK ~= nil then return AK == BK end
    return tostring(SafeFullName(A) or "") == tostring(SafeFullName(B) or "")
end

function ArmorSkinObjectChainReachesPawn(Object, Pawn)
    Object, Pawn = Unwrap(Object), Unwrap(Pawn)
    if not IsValidObject(Object) or not IsValidObject(Pawn) then return false, "invalid" end
    local Queue = {{Object=Object, Depth=0, Route="biped"}}
    local Seen, Q = {}, 1
    while Q <= #Queue and Q <= 64 do
        local Item = Queue[Q]; Q = Q + 1
        local Current = Unwrap(Item.Object)
        if IsValidObject(Current) then
            if ArmorSkinSameObject(Current, Pawn) then return true, Item.Route end
            local Key = ArmorSkinObjectKey(Current) or tostring(SafeFullName(Current) or "")
            if Key ~= "" and not Seen[Key] then
                Seen[Key] = true
                if (tonumber(Item.Depth) or 0) < 5 then
                    local function Add(Value, Edge)
                        Value = Unwrap(Value)
                        if IsValidObject(Value) then
                            Queue[#Queue + 1] = {Object=Value, Depth=(tonumber(Item.Depth) or 0)+1,
                                Route=tostring(Item.Route) .. "->" .. tostring(Edge)}
                        end
                    end
                    local V = nil
                    pcall(function() V = Current:GetOwner() end); Add(V, "GetOwner")
                    V = nil; pcall(function() V = Current.Owner end); Add(V, "Owner")
                    V = nil; pcall(function() V = Current:GetOuter() end); Add(V, "GetOuter")
                    V = nil; pcall(function() V = Current:GetAttachParentActor() end); Add(V, "GetAttachParentActor")
                    V = nil; pcall(function() V = Current:GetAttachParent() end); Add(V, "GetAttachParent")
                    V = nil; pcall(function() V = Current:GetParentActor() end); Add(V, "GetParentActor")
                    V = nil; pcall(function() V = Current:GetParentComponent() end); Add(V, "GetParentComponent")
                    V = nil; pcall(function() V = Current.AttachParent end); Add(V, "AttachParent")
                    V = nil; pcall(function() V = Current.ParentComponent end); Add(V, "ParentComponent")
                    V = nil; pcall(function() V = Current.RootComponent end); Add(V, "RootComponent")
                    V = nil; pcall(function() V = Current:GetInstigator() end); Add(V, "GetInstigator")
                    V = nil; pcall(function() V = Current.Instigator end); Add(V, "Instigator")
                end
            end
        end
    end
    return false, "unlinked"
end

-- RC3_34 remote presentation discovery ---------------------------------------
-- Warthog/Scorpion have a replicated actor with a stable Blam identifier and
-- reachable material components. The Spartan presentation is different: the
-- replicated BP_MeteoritePawn can be a simulation shell while the visible body
-- is generated by the Blam mesh-synchronization layer. The helpers below cache
-- only BP_SpartansBipedActor_C and CVW BPC_SkeletalMesh_C instances and map
-- those small candidate sets to PlayerState pawns. This avoids RC3_32's unsafe
-- FindAllOf(SkeletalMeshComponent/StaticMeshComponent) world scan entirely.
function ArmorSkinCacheBipedInstance(Biped, Source)
    Biped = Unwrap(Biped)
    if not IsValidObject(Biped) then return false end
    local Full = tostring(SafeFullName(Biped) or "")
    if not ArmorSkinContainsCI(Full, "BP_SpartansBipedActor_C") or string.find(Full, "Default__", 1, true) then return false end
    local Key = ArmorSkinObjectKey(Biped) or Full
    if Key == "" then return false end
    if not ArmorSkinBipedInstanceSeen[Key] then
        ArmorSkinBipedInstanceSeen[Key] = true
        if #ArmorSkinBipedInstanceCache < 96 then ArmorSkinBipedInstanceCache[#ArmorSkinBipedInstanceCache+1] = Biped end
    end
    if not IsValidObject(ArmorSkinBipedClass) then
        local C = nil; pcall(function() C = Unwrap(Biped:GetClass()) end)
        if IsValidObject(C) then
            ArmorSkinBipedClass = C
            Log("ARMORSKIN exact biped UClass cached class=%s source=%s", tostring(SafeFullName(C) or C), tostring(Source or "runtime"))
        end
    end
    return true
end

function ArmorSkinEnsureBipedClass()
    if IsValidObject(ArmorSkinBipedClass) then return ArmorSkinBipedClass end
    local C = nil
    -- Live RC3_34 logs show the runtime class is the SynchronizationTestContent
    -- prototype class, not /Game/Blueprints/BP_SpartansBipedActor.
    pcall(function() C = Unwrap(StaticFindObject("/Game/_Prototypes/SynchronizationTestContent/TestActor/BP_SpartansBipedActor.BP_SpartansBipedActor_C")) end)
    if not IsValidObject(C) then
        pcall(function() C = Unwrap(StaticFindObject("/Game/Blueprints/BP_SpartansBipedActor.BP_SpartansBipedActor_C")) end)
    end
    if IsValidObject(C) then ArmorSkinBipedClass = C; return C end
    for PlayerIndex=1,2 do
        local Pawn = ArmorSkinGetPawnFromController(GetPlayer(PlayerIndex))
        if IsValidObject(Pawn) then
            local Children=nil; pcall(function() Children=Pawn.Children end)
            for _,Raw in ipairs(ArrayValues(Children)) do
                local O=Unwrap(Raw)
                if IsValidObject(O) and ArmorSkinContainsCI(SafeFullName(O), "BP_SpartansBipedActor_C") then
                    ArmorSkinCacheBipedInstance(O, "local Pawn.Children class seed")
                    if IsValidObject(ArmorSkinBipedClass) then return ArmorSkinBipedClass end
                end
            end
        end
    end
    return nil
end

function ArmorSkinAllKnownPlayerPawns()
    local Out, Seen = {}, {}
    local function Add(P)
        P=Unwrap(P); if not IsValidObject(P) then return end
        local K=ArmorSkinObjectKey(P) or tostring(SafeFullName(P) or "")
        if K ~= "" and not Seen[K] then Seen[K]=true; Out[#Out+1]=P end
    end
    for I=1,2 do Add(ArmorSkinGetPawnFromController(GetPlayer(I))) end
    local GS=ArmorSkinGameState()
    if IsValidObject(GS) then
        local Arr=nil; pcall(function() Arr=GS.PlayerArray end)
        for I,RawState in ipairs(ArrayValues(Arr)) do
            if I > 16 then break end
            Add(ArmorSkinPawnFromPlayerState(Unwrap(RawState)))
        end
    end
    return Out
end

function ArmorSkinSpatialCandidateMatchesPawn(Candidate, Pawn)
    Candidate, Pawn = Unwrap(Candidate), Unwrap(Pawn)
    if not IsValidObject(Candidate) or not IsValidObject(Pawn) then return false, nil, "invalid" end
    local CX,CY,CZ=ScorpionObjectWorldLocation(Candidate)
    local PX,PY,PZ=ScorpionObjectWorldLocation(Pawn)
    if CX==nil or PX==nil then return false,nil,"no-location" end
    local dx,dy,dz=CX-PX,CY-PY,CZ-PZ
    local targetD2=dx*dx+dy*dy+dz*dz
    -- A biped/CVW component should be at or very close to its simulation pawn.
    -- 500 uu is intentionally generous for origin/bone offsets, but the nearest
    -- pawn test below prevents assigning a presentation to the wrong player.
    if targetD2 > 500*500 then return false, math.sqrt(targetD2), "too-far" end
    local targetKey=ArmorSkinObjectKey(Pawn) or tostring(SafeFullName(Pawn) or "")
    local nearestKey,nearestD2,secondD2=nil,nil,nil
    for _,P in ipairs(ArmorSkinAllKnownPlayerPawns()) do
        local X,Y,Z=ScorpionObjectWorldLocation(P)
        if X~=nil then
            local a,b,c=CX-X,CY-Y,CZ-Z
            local d2=a*a+b*b+c*c
            if nearestD2==nil or d2 < nearestD2 then
                secondD2=nearestD2; nearestD2=d2; nearestKey=ArmorSkinObjectKey(P) or tostring(SafeFullName(P) or "")
            elseif secondD2==nil or d2 < secondD2 then secondD2=d2 end
        end
    end
    if nearestKey ~= targetKey then return false, math.sqrt(targetD2), "nearest-other-pawn" end
    -- Exact/co-located origins are decisive. Otherwise require useful separation
    -- from the runner-up if another pawn happens to be standing nearby.
    if targetD2 <= 35*35 then return true, math.sqrt(targetD2), "co-located" end
    if secondD2 ~= nil and secondD2 - targetD2 < 75*75 then
        return false, math.sqrt(targetD2), "ambiguous-nearest"
    end
    return true, math.sqrt(targetD2), "unique-nearest"
end

function ArmorSkinFNameString(Value)
    Value = Unwrap(Value)
    if Value == nil then return "" end
    local S = nil
    pcall(function() S = Value:ToString() end)
    if S ~= nil and tostring(S) ~= "" then return tostring(S) end
    return tostring(Value or "")
end

function ArmorSkinClassShortName(ClassObject, Fallback)
    ClassObject = Unwrap(ClassObject)
    if IsValidObject(ClassObject) then
        local N = nil
        pcall(function() N = ClassObject:GetFName():ToString() end)
        if N ~= nil and tostring(N) ~= "" then return tostring(N) end
    end
    local F = tostring(Fallback or "")
    if F ~= "" and string.find(F, "FNameUserdata", 1, true) == nil then return F end
    return ""
end

function ArmorSkinTargetedFindObjects(ClassObject, ShortClassName, Limit)
    local Out, Seen = {}, {}
    Limit=tonumber(Limit) or 128
    local function AddList(List)
        for _,Raw in ipairs(List or {}) do
            if #Out >= Limit then break end
            local O=Unwrap(Raw)
            if IsValidObject(O) then
                local K=ArmorSkinObjectKey(O) or tostring(SafeFullName(O) or "")
                if K ~= "" and not Seen[K] and not string.find(K,"Default__",1,true) then
                    Seen[K]=true; Out[#Out+1]=O
                end
            end
        end
    end

    local ClassName = ArmorSkinClassShortName(ClassObject, ShortClassName)
    if ClassName == "" then return Out end

    -- Correct UE4SS signature: FindObjects(count, short-class-name, object-name,
    -- required/banned flags, exactClass). Do NOT pass UClass as the class-name
    -- argument; RC3_34 did that and its result counts were not trustworthy.
    local L=nil
    pcall(function() L=FindObjects(Limit, ClassName, nil, 0, 0, true) end)
    AddList(L)
    if #Out == 0 then
        L=nil; pcall(function() L=FindAllOf(ClassName) end); AddList(L)
    end
    return Out
end

function ArmorSkinSeedExactBipedCache()
    if tonumber(ArmorSkinBipedExactScanGeneration) == tonumber(WarthogColorRuntimeGeneration) then return end
    ArmorSkinBipedExactScanGeneration = tonumber(WarthogColorRuntimeGeneration) or 0
    local C=ArmorSkinEnsureBipedClass()
    local Found=ArmorSkinTargetedFindObjects(C,"BP_SpartansBipedActor_C",64)
    for _,O in ipairs(Found) do ArmorSkinCacheBipedInstance(O,"exact-class seed") end
    Log("ARMORSKIN exact biped class seed generation=%d found=%d cached=%d",
        tonumber(WarthogColorRuntimeGeneration) or 0,#Found,#ArmorSkinBipedInstanceCache)
end

-- RC3_35 exact Spartan presentation assignment -------------------------------
-- The live RC3_34 run proved there are exactly three instances of the runtime
-- BP_SpartansBipedActor class in a 3-player session, even though the remote
-- BP_MeteoritePawn exposes no biped in Children/Components.  Treat those biped
-- actors as the render containers and map them explicitly to replicated pawns.

function ArmorSkinWorldObject(Object)
    Object=Unwrap(Object); if not IsValidObject(Object) then return nil end
    local W=nil
    pcall(function() W=Unwrap(Object:GetWorld()) end)
    if not IsValidObject(W) then pcall(function() W=Unwrap(Object.World) end) end
    return IsValidObject(W) and W or nil
end

function ArmorSkinSharesRuntimeWorld(A,B)
    local WA,WB=ArmorSkinWorldObject(A),ArmorSkinWorldObject(B)
    if IsValidObject(WA) and IsValidObject(WB) then return ArmorSkinSameObject(WA,WB) end
    -- Missing reflected GetWorld must not reject a candidate. Identity and
    -- component-position checks below are still bounded to <=96 biped actors.
    return true
end

function ArmorSkinDirectBipedChild(Pawn)
    Pawn=Unwrap(Pawn); if not IsValidObject(Pawn) then return nil end
    local Children=nil; pcall(function() Children=Pawn.Children end)
    for _,Raw in ipairs(ArrayValues(Children)) do
        local B=Unwrap(Raw)
        if IsValidObject(B) and ArmorSkinContainsCI(SafeFullName(B),"BP_SpartansBipedActor_C") then
            ArmorSkinCacheBipedInstance(B,"direct child mapping")
            return B
        end
    end
    return nil
end

function ArmorSkinBipedChiefSlotCount(Biped)
    Biped=Unwrap(Biped); if not IsValidObject(Biped) then return 0 end
    local N=0
    for I,C in ipairs(WarthogGetActorComponents(Biped) or {}) do
        if I>96 then break end
        C=Unwrap(C)
        if IsValidObject(C) and not ArmorSkinObjectLooksLikeWeapon(C) then
            for _,S in ipairs(ArmorSkinGetMaterialSlots(C)) do
                if ArmorSkinMaterialLooksLikeChief(S.Material) then N=N+1 end
            end
        end
    end
    return N
end

function ArmorSkinBipedDistanceToPawn(Biped,Pawn)
    Biped,Pawn=Unwrap(Biped),Unwrap(Pawn)
    if not IsValidObject(Biped) or not IsValidObject(Pawn) then return nil,"invalid" end
    local PX,PY,PZ=ScorpionObjectWorldLocation(Pawn)
    if PX==nil then return nil,"pawn-no-location" end

    local BestChief,BestAny=nil,nil
    local Components=WarthogGetActorComponents(Biped) or {}
    for I,Raw in ipairs(Components) do
        if I>96 then break end
        local C=Unwrap(Raw)
        if IsValidObject(C) and not ArmorSkinObjectLooksLikeWeapon(C) then
            local Slots=ArmorSkinGetMaterialSlots(C)
            if #Slots>0 then
                local CX,CY,CZ=ScorpionObjectWorldLocation(C)
                if CX~=nil then
                    local dx,dy,dz=CX-PX,CY-PY,CZ-PZ
                    local D=math.sqrt(dx*dx+dy*dy+dz*dz)
                    if BestAny==nil or D<BestAny then BestAny=D end
                    local Chief=false
                    for _,S in ipairs(Slots) do
                        if ArmorSkinMaterialLooksLikeChief(S.Material) then Chief=true; break end
                    end
                    if Chief and (BestChief==nil or D<BestChief) then BestChief=D end
                end
            end
        end
    end
    if BestChief~=nil then return BestChief,"chief-component" end
    if BestAny~=nil then return BestAny,"material-component" end
    local BX,BY,BZ=ScorpionObjectWorldLocation(Biped)
    if BX~=nil then
        local dx,dy,dz=BX-PX,BY-PY,BZ-PZ
        return math.sqrt(dx*dx+dy*dy+dz*dz),"actor"
    end
    return nil,"no-location"
end


-- RC3_37: A30 proved that the generated Chief mesh components can live in a
-- presentation coordinate space thousands of units away from BP_MeteoritePawn.
-- For multi-remote assignment, first try the biped actor transform itself, then
-- calibrate the presentation-space translation from identity-safe local anchors.
function ArmorSkinBipedActorDistanceToPawn(Biped,Pawn)
    Biped,Pawn=Unwrap(Biped),Unwrap(Pawn)
    if not IsValidObject(Biped) or not IsValidObject(Pawn) then return nil end
    local BX,BY,BZ=ScorpionObjectWorldLocation(Biped)
    local PX,PY,PZ=ScorpionObjectWorldLocation(Pawn)
    if BX==nil or PX==nil then return nil end
    local X,Y,Z=BX-PX,BY-PY,BZ-PZ
    return math.sqrt(X*X+Y*Y+Z*Z)
end

function ArmorSkinBipedChiefReferenceLocation(Biped)
    Biped=Unwrap(Biped); if not IsValidObject(Biped) then return nil,nil,nil,0 end
    local SX,SY,SZ,N=0,0,0,0
    for I,Raw in ipairs(WarthogGetActorComponents(Biped) or {}) do
        if I>96 then break end
        local C=Unwrap(Raw)
        if IsValidObject(C) and not ArmorSkinObjectLooksLikeWeapon(C) then
            local Chief=false
            for _,S in ipairs(ArmorSkinGetMaterialSlots(C)) do
                if ArmorSkinMaterialLooksLikeChief(S.Material) then Chief=true; break end
            end
            if Chief then
                local X,Y,Z=ScorpionObjectWorldLocation(C)
                if X~=nil then SX=SX+X; SY=SY+Y; SZ=SZ+Z; N=N+1 end
            end
        end
    end
    if N>0 then return SX/N,SY/N,SZ/N,N end
    local X,Y,Z=ScorpionObjectWorldLocation(Biped)
    if X~=nil then return X,Y,Z,0 end
    return nil,nil,nil,0
end

function ArmorSkinPresentationOffsetFromLocalAnchors(Records,Assignments)
    local Offsets={}
    for _,R in ipairs(Records or {}) do
        if R.LocalIndex~=nil then
            local B=Unwrap((Assignments or {})[R.Key])
            if IsValidObject(B) then
                local BX,BY,BZ=ArmorSkinBipedChiefReferenceLocation(B)
                local PX,PY,PZ=ScorpionObjectWorldLocation(R.Pawn)
                if BX~=nil and PX~=nil then Offsets[#Offsets+1]={X=BX-PX,Y=BY-PY,Z=BZ-PZ} end
            end
        end
    end
    if #Offsets==0 then return nil,nil,nil,0,nil end
    local SX,SY,SZ=0,0,0
    for _,O in ipairs(Offsets) do SX=SX+O.X; SY=SY+O.Y; SZ=SZ+O.Z end
    local AX,AY,AZ=SX/#Offsets,SY/#Offsets,SZ/#Offsets
    local MaxSpread=0
    for _,O in ipairs(Offsets) do
        local X,Y,Z=O.X-AX,O.Y-AY,O.Z-AZ
        local D=math.sqrt(X*X+Y*Y+Z*Z)
        if D>MaxSpread then MaxSpread=D end
    end
    -- Multiple local anchors must agree. A single local anchor is still an
    -- identity-safe calibration source because its Pawn.Children relation is exact.
    if #Offsets>1 and MaxSpread>1000.0 then return nil,nil,nil,#Offsets,MaxSpread end
    return AX,AY,AZ,#Offsets,MaxSpread
end

function ArmorSkinBipedCalibratedDistanceToPawn(Biped,Pawn,OX,OY,OZ)
    if OX==nil then return nil end
    local BX,BY,BZ=ArmorSkinBipedChiefReferenceLocation(Biped)
    local PX,PY,PZ=ScorpionObjectWorldLocation(Pawn)
    if BX==nil or PX==nil then return nil end
    local X,Y,Z=BX-(PX+OX),BY-(PY+OY),BZ-(PZ+OZ)
    return math.sqrt(X*X+Y*Y+Z*Z)
end


-- RC3_46: immediate deterministic remote identity from an exact LOCAL anchor.
-- BP_MeteoritePawn and the generated Chief render body can live in coordinate
-- spaces separated by a large translation.  A local Pawn.Children relation is
-- exact identity, so its Chief-reference offset calibrates those spaces.  We
-- then solve the remaining remote pawn<->biped assignment one-to-one by the
-- calibrated residual.  No PlayerId numeric ordering, instance suffix, network
-- role, or construction order participates in the decision.
function ArmorSkinTryCalibratedRemoteAssignment(Records,NewAssign,RemotePending,Available,Assign,Compact)
    if #RemotePending<2 or #Available~=#RemotePending or #RemotePending>4 then return false end
    local OX,OY,OZ,AnchorCount,AnchorSpread=ArmorSkinPresentationOffsetFromLocalAnchors(Records,NewAssign)
    if OX==nil or (tonumber(AnchorCount) or 0)<1 then return false end

    local Cost={}
    for I,R in ipairs(RemotePending) do
        Cost[I]={}
        for J,A in ipairs(Available) do
            local D=ArmorSkinBipedCalibratedDistanceToPawn(A.Biped,R.Pawn,OX,OY,OZ)
            if D==nil then return false end
            Cost[I][J]=D
        end
    end

    local Best,Second=nil,nil
    local Used,Choice={},{}
    local function Evaluate()
        local SumSq,MaxErr=0,0
        local Residual={}
        for I=1,#RemotePending do
            local D=Cost[I][Choice[I]]
            Residual[I]=D
            SumSq=SumSq+D*D
            if D>MaxErr then MaxErr=D end
        end
        local C={Score=math.sqrt(SumSq/#RemotePending),MaxErr=MaxErr,Choice={},Residual=Residual}
        for I=1,#RemotePending do C.Choice[I]=Choice[I] end
        if Best==nil or C.Score<Best.Score then Second=Best; Best=C
        elseif Second==nil or C.Score<Second.Score then Second=C end
    end
    local function Recurse(I)
        if I>#RemotePending then Evaluate(); return end
        for J=1,#Available do
            if not Used[J] then
                Used[J]=true; Choice[I]=J; Recurse(I+1); Used[J]=nil
            end
        end
    end
    Recurse(1)
    if Best==nil then return false end

    local SecondScore=Second and Second.Score or nil
    local Margin=SecondScore and (SecondScore-Best.Score) or 999999
    local Ratio=(SecondScore and Best.Score>0.001) and (SecondScore/Best.Score) or 999999

    -- Keep this conservative.  Correct pairs should collapse close to the
    -- local-anchor translation; wrong cross-pairs differ by inter-player
    -- spacing.  If the players overlap so tightly that the two permutations
    -- are not distinguishable, WAIT instead of painting the wrong Spartan.
    local Decisive = Best.MaxErr<=600.0 and (Second==nil or Margin>=40.0 or Ratio>=1.35)

    local MatrixParts={}
    for I,R in ipairs(RemotePending) do
        local Row={}
        for J,A in ipairs(Available) do
            Row[#Row+1]=string.format("%s=%.1f",tostring(string.match(A.Key or "","BP_SpartansBipedActor_C_%d+") or J),Cost[I][J])
        end
        MatrixParts[#MatrixParts+1]=string.format("pid%s[P%s]:%s",tostring(R.PlayerId or "?"),
            tostring(ArmorSkinNetworkOriginSlotForPlayerId(R.PlayerId) or "?"),table.concat(Row,","))
    end

    if not Decisive then
        local K="calibrated-wait:"..tostring(WarthogColorRuntimeGeneration or 0)
        if not ArmorSkinBipedOrdinalAuditLogged[K] then
            ArmorSkinBipedOrdinalAuditLogged[K]=true
            Log("ARMORSKIN calibrated identity WAIT anchors=%d spread=%s best=%.1f maxErr=%.1f second=%s margin=%.1f ratio=%.2f matrix=%s",
                tonumber(AnchorCount) or 0,tostring(AnchorSpread or "-"),Best.Score,Best.MaxErr,
                SecondScore and string.format("%.1f",SecondScore) or "-",Margin,Ratio,table.concat(MatrixParts," | "))
        end
        return false
    end

    local Mapping={}
    for I,R in ipairs(RemotePending) do
        local A=Available[Best.Choice[I]]
        Mapping[#Mapping+1]=string.format("%s[P%s]->%s(err=%.1f)",tostring(R.PlayerId or "?"),
            tostring(ArmorSkinNetworkOriginSlotForPlayerId(R.PlayerId) or "?"),
            tostring(string.match(A.Key or "","BP_SpartansBipedActor_C_%d+") or A.Key),Best.Residual[I] or -1)
        Assign(R,A,"local-anchor-calibrated",Best.Residual[I],"local-Pawn.Children/presentation-offset")
    end
    Compact()
    Log("ARMORSKIN calibrated identity mapping anchors=%d spread=%s rms=%.1f maxErr=%.1f second=%s margin=%.1f ratio=%.2f map=%s matrix=%s",
        tonumber(AnchorCount) or 0,tostring(AnchorSpread or "-"),Best.Score,Best.MaxErr,
        SecondScore and string.format("%.1f",SecondScore) or "-",Margin,Ratio,table.concat(Mapping," | "),table.concat(MatrixParts," | "))
    return #Mapping>0
end

function ArmorSkinAllKnownPlayerPawnRecords()
    local Out,ByKey={},{ }
    local function Add(P,Pid,LocalIndex)
        P=Unwrap(P); if not IsValidObject(P) then return end
        local K=ArmorSkinObjectKey(P) or tostring(SafeFullName(P) or "")
        if K=="" then return end
        local R=ByKey[K]
        if not R then
            R={Pawn=P,Key=K,PlayerId=tonumber(Pid) or ArmorSkinPlayerIdFromPawn(P),LocalIndex=LocalIndex}
            ByKey[K]=R; Out[#Out+1]=R
        else
            if R.PlayerId==nil then R.PlayerId=tonumber(Pid) or ArmorSkinPlayerIdFromPawn(P) end
            if R.LocalIndex==nil and LocalIndex~=nil then R.LocalIndex=LocalIndex end
        end
    end
    for I=1,2 do
        local C=GetPlayer(I); local P=ArmorSkinGetPawnFromController(C)
        Add(P,ArmorSkinPlayerIdFromController(C),IsValidObject(P) and I or nil)
    end
    local GS=ArmorSkinGameState()
    if IsValidObject(GS) then
        local Arr=nil; pcall(function() Arr=GS.PlayerArray end)
        for I,RawState in ipairs(ArrayValues(Arr)) do
            if I>16 then break end
            local S=Unwrap(RawState)
            Add(ArmorSkinPawnFromPlayerState(S),ArmorSkinPlayerIdFromState(S),nil)
        end
    end
    table.sort(Out,function(A,B)
        local AP=tonumber(A.PlayerId) or 9999999
        local BP=tonumber(B.PlayerId) or 9999999
        if AP~=BP then return AP<BP end
        return tostring(A.Key)<tostring(B.Key)
    end)
    return Out
end

function ArmorSkinLocalPlayerIndexForPawn(Pawn)
    Pawn=Unwrap(Pawn); if not IsValidObject(Pawn) then return nil end
    for I=1,2 do
        local P=ArmorSkinGetPawnFromController(GetPlayer(I))
        if IsValidObject(P) and ArmorSkinSameObject(P,Pawn) then return I end
    end
    return nil
end

function ArmorSkinBipedDirectOwnerPawnKey(Biped, Records)
    Biped=Unwrap(Biped); if not IsValidObject(Biped) then return nil end
    for _,R in ipairs(Records or ArmorSkinAllKnownPlayerPawnRecords()) do
        local Direct=ArmorSkinDirectBipedChild(R.Pawn)
        if IsValidObject(Direct) and ArmorSkinSameObject(Direct,Biped) then return R.Key end
    end
    return nil
end


-- RC3_41 observer-local session-ordinal identity ------------------------------
-- Important: this path never samples movement and never calls unknown game
-- functions. PlayerId is used only as the replicated session identity/ordering
-- token; values such as 256/257/258 are NOT hard-coded to P1/P2. Exact local
-- Pawn.Children anchors and observer role determine presentation orientation.
function ArmorSkinResolvePlayerIdOrdinalOrientation(Records, AllBipeds, NewAssign, AllowNetworkHint)
    if type(Records)~="table" or type(AllBipeds)~="table" then return nil,nil,nil,"invalid" end
    local N=#Records
    if N<2 or N>4 or #AllBipeds~=N then return nil,nil,nil,"count-mismatch" end

    local RR,BB={},{}
    for _,R in ipairs(Records) do
        if tonumber(R.PlayerId)==nil then return nil,nil,nil,"missing-player-id" end
        RR[#RR+1]=R
    end
    for _,A in ipairs(AllBipeds) do
        local S=ArmorSkinNumericInstanceSuffix(A.Biped)
        if S==nil then return nil,nil,nil,"missing-biped-suffix" end
        A.OrdinalSuffix=S
        BB[#BB+1]=A
    end
    table.sort(RR,function(A,B)
        local X,Y=tonumber(A.PlayerId),tonumber(B.PlayerId)
        if X==Y then return tostring(A.Key)<tostring(B.Key) end
        return X<Y
    end)
    table.sort(BB,function(A,B)
        if A.OrdinalSuffix==B.OrdinalSuffix then return tostring(A.Key)<tostring(B.Key) end
        return A.OrdinalSuffix>B.OrdinalSuffix
    end)
    for I=2,N do
        if tonumber(RR[I].PlayerId)==tonumber(RR[I-1].PlayerId) then return nil,nil,nil,"duplicate-player-id" end
        if tonumber(BB[I].OrdinalSuffix)==tonumber(BB[I-1].OrdinalSuffix) then return nil,nil,nil,"duplicate-biped-suffix" end
    end

    local SameOk,ReverseOk=true,true
    local Anchors=0
    local AnchorParts={}
    for I,R in ipairs(RR) do
        local Direct=nil
        if type(NewAssign)=="table" then Direct=Unwrap(NewAssign[R.Key]) end
        if not IsValidObject(Direct) and R.LocalIndex~=nil then Direct=ArmorSkinDirectBipedChild(R.Pawn) end
        if IsValidObject(Direct) and R.LocalIndex~=nil then
            Anchors=Anchors+1
            local SameMatch=ArmorSkinSameObject(Direct,BB[I].Biped)
            local RevMatch=ArmorSkinSameObject(Direct,BB[N-I+1].Biped)
            if not SameMatch then SameOk=false end
            if not RevMatch then ReverseOk=false end
            AnchorParts[#AnchorParts+1]=string.format("P%s/L%s->%s same=%s rev=%s",
                tostring(R.PlayerId),tostring(R.LocalIndex),
                tostring(string.match(tostring(SafeFullName(Direct) or ""),"BP_SpartansBipedActor_C_%d+") or SafeFullName(Direct) or "?"),
                tostring(SameMatch),tostring(RevMatch))
        end
    end
    if Anchors<=0 then return nil,RR,BB,"no-local-anchor" end

    local Orientation=nil
    local Source=nil
    if SameOk~=ReverseOk then
        -- A direct local Pawn.Children anchor is always stronger than any
        -- inferred ordering and remains valid regardless of host/client role.
        Orientation=SameOk and "same" or "reverse"
        Source="local-anchor-proof"
    elseif SameOk and ReverseOk then
        -- RC3_40 proved the topology orientation is NOT transferable between
        -- machines. In the 3-player / two-remote case a middle-ranked local
        -- anchor is compatible with both permutations. Live RC3_40 evidence
        -- showed the listen server's render order is SAME while the observing
        -- network client's generated remote presentation order is REVERSE.
        -- Decide locally from authority role and never consume the peer hint.
        if N==3 and LivesAuthorityResolved==true then
            if LivesNetworkClientBlocked==true then
                Orientation="reverse"
                Source="observer-local-network-client"
            elseif LivesAuthorityAllowed==true then
                Orientation="same"
                Source="observer-local-authority"
            end
        end
    end

    local Detail=string.format("anchors=%d same=%s reverse=%s peerHint=%s ignored=true source=%s %s",
        Anchors,tostring(SameOk),tostring(ReverseOk),tostring(ArmorSkinPlayerIdOrdinalHint or "-"),
        tostring(Source or "unresolved"),table.concat(AnchorParts," | "))
    return Orientation,RR,BB,Detail
end

-- RC3_42 explicit remote split-slot identity -------------------------------
function ArmorSkinNetworkRememberOriginSlot(PlayerId, Slot, Source)
    PlayerId=tonumber(PlayerId); Slot=tonumber(Slot)
    if PlayerId==nil or (Slot~=1 and Slot~=2) then return false end
    local K=tostring(math.floor(PlayerId))
    local Old=tonumber(ArmorSkinNetworkOriginSlotByPlayerId[K])
    ArmorSkinNetworkOriginSlotByPlayerId[K]=Slot
    if Old~=Slot then
        Log("ARMORSKIN NET origin-slot learned playerId=%d slot=P%d source=%s",PlayerId,Slot,tostring(Source or "network"))
        -- A changed/first slot label can make a previously ambiguous pair exact.
        ArmorSkinBipedAssignmentByPawnKey={}
        ArmorSkinBipedAssignmentMetaByPawnKey={}
        ArmorSkinBipedAssignmentAuditLogged={}
        ArmorSkinBipedAnchorPendingLogged={}
    end
    return true
end

function ArmorSkinNetworkOriginSlotForPlayerId(PlayerId)
    PlayerId=tonumber(PlayerId); if PlayerId==nil then return nil end
    local LocalIndex=ArmorSkinLocalPlayerIndexForPlayerId(PlayerId)
    if LocalIndex==1 or LocalIndex==2 then return LocalIndex end
    local Slot=tonumber(ArmorSkinNetworkOriginSlotByPlayerId[tostring(math.floor(PlayerId))])
    if Slot==1 or Slot==2 then return Slot end
    return nil
end


-- RC3_49: map a two-player remote split-screen pair from the source machine's
-- exact P1->P2 visible-biped displacement. Translation cancels; suffix/order is
-- never consulted. If the pair is too close or direction is not decisive, wait.
function ArmorSkinTryPairVectorAssignment(RemotePending,Available,Assign,Compact)
    local V=ArmorSkinRemotePairVector
    if type(V)~="table" or #RemotePending~=2 or #Available<2 then return false end
    if tonumber(V.Generation)~=tonumber(WarthogColorRuntimeGeneration) then return false end
    local R1,R2=nil,nil
    for _,R in ipairs(RemotePending) do
        local PID=tonumber(R.PlayerId)
        if PID==tonumber(V.P1) then R1=R elseif PID==tonumber(V.P2) then R2=R end
    end
    if R1==nil or R2==nil then return false end

    local HL=tonumber(V.Length) or math.sqrt(V.DX*V.DX+V.DY*V.DY+V.DZ*V.DZ)
    if HL<40 then return false end
    local Gen=tostring(WarthogColorRuntimeGeneration or 0)
    local AuditKey=string.format("%s:%s",Gen,tostring(V.Seq or 0))

    -- RC3_58: after respawn, old corpses can coexist with the two new remote
    -- presentation bipeds. Prefer only actors constructed in the latest burst.
    if #Available > 2 then
        local Fresh={}
        local Last=tonumber(ArmorSkinLastBipedConstructionClock) or 0
        local Cutoff=Last-(tonumber(ArmorSkinFreshBipedWindowSeconds) or 0.75)
        local G=tonumber(WarthogColorRuntimeGeneration) or 0
        for _,A in ipairs(Available) do
            local M=ArmorSkinFreshBipedByKey and ArmorSkinFreshBipedByKey[A.Key] or nil
            if type(M)=="table" and tonumber(M.Generation)==G and (tonumber(M.Clock) or 0)>=Cutoff then
                Fresh[#Fresh+1]=A
            end
        end
        if #Fresh>=2 then
            local FK=AuditKey..":fresh"
            if not ArmorSkinPairVectorAuditLogged[FK] then
                ArmorSkinPairVectorAuditLogged[FK]=true
                Log("ARMORSKIN PAIRVEC FRESH FILTER seq=%s available=%d fresh=%d",
                    tostring(V.Seq or "?"),#Available,#Fresh)
            end
            Available=Fresh
        end
    end

    -- Preserve the already-proven two-candidate behavior unchanged.
    if #Available==2 then
        local A1,A2=Available[1],Available[2]
        local X1,Y1,Z1=ArmorSkinBipedChiefReferenceLocation(A1.Biped)
        local X2,Y2,Z2=ArmorSkinBipedChiefReferenceLocation(A2.Biped)
        if X1==nil or X2==nil then return false end
        local LX,LY,LZ=X2-X1,Y2-Y1,Z2-Z1
        local LL=math.sqrt(LX*LX+LY*LY+LZ*LZ)
        local Dot=LX*V.DX+LY*V.DY+LZ*V.DZ
        local Cos=(LL>0 and HL>0) and (Dot/(LL*HL)) or 0
        if LL<40 or math.abs(Cos)<0.35 then
            if not ArmorSkinPairVectorAuditLogged[AuditKey] then
                ArmorSkinPairVectorAuditLogged[AuditKey]=true
                Log("ARMORSKIN PAIRVEC WAIT seq=%s hostLen=%.1f remoteLen=%.1f cos=%.3f reason=ambiguous/too-close",
                    tostring(V.Seq or "?"),HL,LL,Cos)
            end
            return false
        end
        local First,Second=A1,A2
        if Cos<0 then First,Second=A2,A1 end
        Assign(R1,First,"source-pair-vector",0,"exact-source-P1P2-relative-vector")
        Assign(R2,Second,"source-pair-vector",0,"exact-source-P1P2-relative-vector")
        Compact()
        Log("ARMORSKIN PAIRVEC MAPPING seq=%s P1=%s->%s P2=%s->%s hostLen=%.1f remoteLen=%.1f cos=%.3f",
            tostring(V.Seq or "?"),tostring(R1.PlayerId or "?"),tostring(string.match(First.Key or "","BP_SpartansBipedActor_C_%d+") or First.Key),
            tostring(R2.PlayerId or "?"),tostring(string.match(Second.Key or "","BP_SpartansBipedActor_C_%d+") or Second.Key),HL,LL,Cos)
        return true
    end

    -- RC3_54 respawn path: dead presentation actors may coexist briefly with the
    -- two newly spawned remote bipeds.  Do not fall back to creation/suffix order.
    -- Instead evaluate every ORDERED candidate pair against the fresh source
    -- P1->P2 vector. World translation cancels, and identical UE units mean both
    -- direction and length should agree. Only a single decisive match is accepted.
    local P={}
    for I,A in ipairs(Available) do
        local X,Y,Z=ArmorSkinBipedChiefReferenceLocation(A.Biped)
        if X~=nil then P[I]={A=A,X=X,Y=Y,Z=Z} end
    end
    local Matches={}
    for I,PI in pairs(P) do
        for J,PJ in pairs(P) do
            if I~=J then
                local LX,LY,LZ=PJ.X-PI.X,PJ.Y-PI.Y,PJ.Z-PI.Z
                local LL=math.sqrt(LX*LX+LY*LY+LZ*LZ)
                if LL>=40 then
                    local Dot=LX*V.DX+LY*V.DY+LZ*V.DZ
                    local Cos=Dot/(LL*HL)
                    local LenErr=math.abs(LL-HL)/math.max(LL,HL)
                    if Cos>=0.85 and LenErr<=0.30 then
                        local Score=(1-Cos)+(LenErr*1.5)
                        Matches[#Matches+1]={First=PI.A,Second=PJ.A,LL=LL,Cos=Cos,LenErr=LenErr,Score=Score}
                    end
                end
            end
        end
    end
    table.sort(Matches,function(A,B) return A.Score<B.Score end)
    local Best=Matches[1]
    if Best==nil then
        if not ArmorSkinPairVectorAuditLogged[AuditKey] then
            ArmorSkinPairVectorAuditLogged[AuditKey]=true
            Log("ARMORSKIN PAIRVEC MULTI WAIT seq=%s available=%d hostLen=%.1f reason=no-direction+length-match",
                tostring(V.Seq or "?"),#Available,HL)
        end
        return false
    end
    local Second=Matches[2]
    local Margin=Second and (Second.Score-Best.Score) or 999
    if Second and Margin<0.08 then
        if not ArmorSkinPairVectorAuditLogged[AuditKey] then
            ArmorSkinPairVectorAuditLogged[AuditKey]=true
            Log("ARMORSKIN PAIRVEC MULTI WAIT seq=%s available=%d bestCos=%.3f bestLenErr=%.3f margin=%.3f reason=non-unique",
                tostring(V.Seq or "?"),#Available,Best.Cos,Best.LenErr,Margin)
        end
        return false
    end

    Assign(R1,Best.First,"source-pair-vector",0,"exact-source-P1P2-relative-vector-multi")
    Assign(R2,Best.Second,"source-pair-vector",0,"exact-source-P1P2-relative-vector-multi")
    Compact()
    Log("ARMORSKIN PAIRVEC MULTI MAPPING seq=%s available=%d P1=%s->%s P2=%s->%s hostLen=%.1f remoteLen=%.1f cos=%.3f lenErr=%.3f margin=%.3f",
        tostring(V.Seq or "?"),#Available,tostring(R1.PlayerId or "?"),
        tostring(string.match(Best.First.Key or "","BP_SpartansBipedActor_C_%d+") or Best.First.Key),
        tostring(R2.PlayerId or "?"),tostring(string.match(Best.Second.Key or "","BP_SpartansBipedActor_C_%d+") or Best.Second.Key),
        HL,Best.LL,Best.Cos,Best.LenErr,Margin)
    return true
end

function ArmorSkinTryPlayerIdOrdinalAssignment(Records,NewAssign,RemotePending,Available,Assign,Compact,SourcePawn)
    if #RemotePending<2 then return false end
    local AllBipeds=ArmorSkinAllCurrentBipedEntries(SourcePawn)
    local Orientation,RR,BB,Detail=ArmorSkinResolvePlayerIdOrdinalOrientation(Records,AllBipeds,NewAssign,true)
    if Orientation==nil then
        local K="pid-ordinal-wait:"..tostring(WarthogColorRuntimeGeneration or 0)
        if not ArmorSkinOrdinalAuditLogged[K] then
            ArmorSkinOrdinalAuditLogged[K]=true
            Log("ARMORSKIN PlayerId ordinal WAIT records=%d bipeds=%d remote=%d detail=%s",#Records,#AllBipeds,#RemotePending,tostring(Detail))
        end
        return false
    end

    local AvailableByKey={}
    for _,A in ipairs(Available) do AvailableByKey[A.Key]=A end
    local N=#RR
    local Mapping={}
    for I,R in ipairs(RR) do
        if R.LocalIndex==nil and not NewAssign[R.Key] then
            local J=(Orientation=="reverse") and (N-I+1) or I
            local Ranked=BB[J]
            local A=Ranked and AvailableByKey[Ranked.Key] or nil
            if A==nil then return false end
            Mapping[#Mapping+1]=string.format("%s->%s",tostring(R.PlayerId or "?"),
                tostring(string.match(A.Key or "","BP_SpartansBipedActor_C_%d+") or A.Key))
            Assign(R,A,"playerid-ordinal-"..Orientation,0,"validated-playerid-order")
        end
    end
    Compact()
    Log("ARMORSKIN PlayerId ordinal mapping orientation=%s map=%s detail=%s",tostring(Orientation),table.concat(Mapping," | "),tostring(Detail))
    return #RemotePending==0
end

function ArmorSkinComputeLocalPlayerIdOrdinalOrientation()
    local SourcePawn=ArmorSkinGetPawnFromController(GetPlayer(1))
    if not IsValidObject(SourcePawn) then return nil,"no-local-pawn" end
    ArmorSkinSeedExactBipedCache()
    local Records=ArmorSkinAllKnownPlayerPawnRecords()
    local AllBipeds=ArmorSkinAllCurrentBipedEntries(SourcePawn)
    local Anchored={}
    for _,R in ipairs(Records) do
        if R.LocalIndex~=nil then
            local D=ArmorSkinDirectBipedChild(R.Pawn)
            if IsValidObject(D) then Anchored[R.Key]=D end
        end
    end
    local Orientation,_,_,Detail=ArmorSkinResolvePlayerIdOrdinalOrientation(Records,AllBipeds,Anchored,false)
    return Orientation,Detail
end

function ArmorSkinNetworkMaybeSendOrdinalHint(Controller,Reason)
    -- RC3_41: presentation ordering is observer-local, so sending the host's
    -- orientation to another machine is actively wrong (RC3_40 swapped P1/P2
    -- on the one-player network client). Keep this no-op for call compatibility.
    return false
end


-- RC3_39 multi-remote identity ------------------------------------------------
-- RC3_38 proved that a single-frame common-translation fit is mathematically
-- ambiguous for the 2-remote topology in A30 (both permutations can have the
-- same residual).  Use lifecycle identity instead: the game constructs each
-- BP_MeteoritePawn and its generated BP_SpartansBipedActor in the same player
-- order.  We never trust that assumption blindly: direct Pawn.Children links
-- from local players must validate the rank orientation first.
function ArmorSkinActorCreationTime(Object)
    Object=Unwrap(Object); if not IsValidObject(Object) then return nil end
    local V=nil
    pcall(function() V=Object.CreationTime end)
    if tonumber(V)==nil then pcall(function() V=Object:GetPropertyValue("CreationTime") end) end
    V=tonumber(V)
    if V==nil or V~=V or math.abs(V)>1000000000 then return nil end
    return V
end

function ArmorSkinNumericInstanceSuffix(Object)
    local S=tostring(SafeFullName(Unwrap(Object)) or "")
    local N=string.match(S,"_([0-9]+)$")
    return tonumber(N)
end

function ArmorSkinAllCurrentBipedEntries(SourcePawn)
    local Out,Seen={},{}
    for I,Raw in ipairs(ArmorSkinBipedInstanceCache or {}) do
        if I>96 then break end
        local B=Unwrap(Raw)
        if IsValidObject(B) and ArmorSkinSharesRuntimeWorld(B,SourcePawn) then
            local K=ArmorSkinObjectKey(B) or tostring(SafeFullName(B) or "")
            if K~="" and not Seen[K] then
                local Chief=ArmorSkinBipedChiefSlotCount(B)
                if Chief>0 then
                    Seen[K]=true
                    Out[#Out+1]={Biped=B,Key=K,ChiefSlots=Chief}
                end
            end
        end
    end
    return Out
end

function ArmorSkinTryValidatedOrdinalAssignment(Records,NewAssign,RemotePending,Available,Assign,Compact,SourcePawn,Mode)
    if #RemotePending<2 then return false end
    local AllBipeds=ArmorSkinAllCurrentBipedEntries(SourcePawn)
    if #AllBipeds~=#Records or #Records<2 or #Records>4 then return false end

    local RankedRecords,RankedBipeds={},{}
    for _,R in ipairs(Records) do RankedRecords[#RankedRecords+1]=R end
    for _,A in ipairs(AllBipeds) do RankedBipeds[#RankedBipeds+1]=A end

    local function RMetric(R)
        if Mode=="creation-time" then return ArmorSkinActorCreationTime(R.Pawn) end
        return ArmorSkinNumericInstanceSuffix(R.Pawn)
    end
    local function BMetric(A)
        if Mode=="creation-time" then return ArmorSkinActorCreationTime(A.Biped) end
        return ArmorSkinNumericInstanceSuffix(A.Biped)
    end
    for _,R in ipairs(RankedRecords) do if RMetric(R)==nil then return false end end
    for _,A in ipairs(RankedBipeds) do if BMetric(A)==nil then return false end end

    local Asc = Mode=="creation-time"
    table.sort(RankedRecords,function(A,B)
        local X,Y=RMetric(A),RMetric(B)
        if X==Y then return tostring(A.Key)<tostring(B.Key) end
        return Asc and X<Y or X>Y
    end)
    table.sort(RankedBipeds,function(A,B)
        local X,Y=BMetric(A),BMetric(B)
        if X==Y then return tostring(A.Key)<tostring(B.Key) end
        return Asc and X<Y or X>Y
    end)

    -- If the metric collapses to the same value for adjacent actors, it cannot
    -- establish lifecycle order safely.
    for I=2,#RankedRecords do
        if math.abs((RMetric(RankedRecords[I]) or 0)-(RMetric(RankedRecords[I-1]) or 0))<0.000001 then return false end
    end
    for I=2,#RankedBipeds do
        if math.abs((BMetric(RankedBipeds[I]) or 0)-(BMetric(RankedBipeds[I-1]) or 0))<0.000001 then return false end
    end

    local AnchorCount=0
    local function OrientationValid(Reverse)
        local SeenAnchor=0
        for I,R in ipairs(RankedRecords) do
            local Direct=Unwrap(NewAssign[R.Key])
            if IsValidObject(Direct) and R.LocalIndex~=nil then
                SeenAnchor=SeenAnchor+1
                local J=Reverse and (#RankedBipeds-I+1) or I
                if not ArmorSkinSameObject(Direct,RankedBipeds[J].Biped) then return false,SeenAnchor end
            end
        end
        return SeenAnchor>0,SeenAnchor
    end
    local SameOk,SameAnchors=OrientationValid(false)
    local RevOk,RevAnchors=OrientationValid(true)
    AnchorCount=math.max(SameAnchors or 0,RevAnchors or 0)
    if SameOk==RevOk then
        local K="ordinal-wait:"..tostring(WarthogColorRuntimeGeneration or 0)..":"..tostring(Mode)
        if not ArmorSkinBipedOrdinalAuditLogged[K] then
            ArmorSkinBipedOrdinalAuditLogged[K]=true
            Log("ARMORSKIN validated ordinal WAIT mode=%s records=%d bipeds=%d anchors=%d same=%s reverse=%s",
                tostring(Mode),#RankedRecords,#RankedBipeds,AnchorCount,tostring(SameOk),tostring(RevOk))
        end
        return false
    end
    local Reverse=RevOk==true

    -- Build a lookup for the still-available remote biped entries. Local bodies
    -- have already been consumed by direct identity anchors.
    local AvailableByKey={}
    for _,A in ipairs(Available) do AvailableByKey[A.Key]=A end
    local Mapping={}
    for I,R in ipairs(RankedRecords) do
        if R.LocalIndex==nil and not NewAssign[R.Key] then
            local J=Reverse and (#RankedBipeds-I+1) or I
            local RankedA=RankedBipeds[J]
            local A=AvailableByKey[RankedA.Key]
            if A==nil then return false end
            Mapping[#Mapping+1]=string.format("%s->%s",tostring(R.PlayerId or "?"),
                tostring(string.match(A.Key or "","BP_SpartansBipedActor_C_%d+") or A.Key))
            Assign(R,A,"validated-"..tostring(Mode).."-ordinal-"..(Reverse and "reverse" or "same"),0,"lifecycle-order")
        end
    end
    Compact()
    Log("ARMORSKIN validated ordinal mapping mode=%s orientation=%s anchors=%d map=%s",
        tostring(Mode),Reverse and "reverse" or "same",AnchorCount,table.concat(Mapping," | "))
    return #Mapping>0
end

-- Translation can be huge, but movement DELTAS are translation invariant. If
-- lifecycle order is unavailable/ambiguous, remember one bounded snapshot and
-- match later displacement vectors. This never scans outside the exact biped
-- cache and naturally becomes decisive as soon as either remote player moves.
function ArmorSkinTryMotionAssignment(RemotePending,Available,Assign,Compact,LocationMode)
    if #RemotePending<2 or #Available~=#RemotePending or #RemotePending>4 then return false end
    local PawnLoc,BipedLoc={},{}
    local SigParts={tostring(LocationMode)}
    for I,R in ipairs(RemotePending) do
        local X,Y,Z=ScorpionObjectWorldLocation(R.Pawn); if X==nil then return false end
        PawnLoc[I]={X=X,Y=Y,Z=Z,Key=R.Key}
        SigParts[#SigParts+1]="P:"..tostring(R.Key)
    end
    for J,A in ipairs(Available) do
        local X,Y,Z
        if LocationMode=="actor" then X,Y,Z=ScorpionObjectWorldLocation(A.Biped)
        else X,Y,Z=ArmorSkinBipedChiefReferenceLocation(A.Biped) end
        if X==nil then return false end
        BipedLoc[J]={X=X,Y=Y,Z=Z,Key=A.Key}
        SigParts[#SigParts+1]="B:"..tostring(A.Key)
    end
    local Signature=table.concat(SigParts,"|")
    local Gen=tostring(WarthogColorRuntimeGeneration or 0)
    local BaseKey=Gen..":"..tostring(LocationMode)
    local Base=ArmorSkinBipedMotionBaseline[BaseKey]
    if Base==nil or Base.Signature~=Signature then
        local P0,B0={},{}
        for I,V in ipairs(PawnLoc) do P0[V.Key]={X=V.X,Y=V.Y,Z=V.Z} end
        for J,V in ipairs(BipedLoc) do B0[V.Key]={X=V.X,Y=V.Y,Z=V.Z} end
        ArmorSkinBipedMotionBaseline[BaseKey]={Signature=Signature,P=P0,B=B0}
        Log("ARMORSKIN motion identity baseline armed mode=%s players=%d",tostring(LocationMode),#RemotePending)
        return false
    end

    local PDelta,BDelta={},{}
    local MaxPawnMove,MaxBipedMove=0,0
    for I,V in ipairs(PawnLoc) do
        local O=Base.P[V.Key]; if not O then return false end
        local DX,DY,DZ=V.X-O.X,V.Y-O.Y,V.Z-O.Z
        local M=math.sqrt(DX*DX+DY*DY+DZ*DZ); if M>MaxPawnMove then MaxPawnMove=M end
        PDelta[I]={X=DX,Y=DY,Z=DZ,M=M}
    end
    for J,V in ipairs(BipedLoc) do
        local O=Base.B[V.Key]; if not O then return false end
        local DX,DY,DZ=V.X-O.X,V.Y-O.Y,V.Z-O.Z
        local M=math.sqrt(DX*DX+DY*DY+DZ*DZ); if M>MaxBipedMove then MaxBipedMove=M end
        BDelta[J]={X=DX,Y=DY,Z=DZ,M=M}
    end
    if MaxPawnMove<25.0 or MaxBipedMove<25.0 then return false end

    local Best,Second=nil,nil
    local Used,Choice={},{}
    local function Evaluate()
        local SumSq,MaxErr=0,0
        local Residual={}
        for I=1,#RemotePending do
            local P,B=PDelta[I],BDelta[Choice[I]]
            local DX,DY,DZ=B.X-P.X,B.Y-P.Y,B.Z-P.Z
            local E=math.sqrt(DX*DX+DY*DY+DZ*DZ)
            Residual[I]=E; SumSq=SumSq+E*E; if E>MaxErr then MaxErr=E end
        end
        local RMS=math.sqrt(SumSq/#RemotePending)
        local C={Score=RMS,MaxErr=MaxErr,Choice={},Residual=Residual}
        for I=1,#RemotePending do C.Choice[I]=Choice[I] end
        if Best==nil or C.Score<Best.Score then Second=Best; Best=C
        elseif Second==nil or C.Score<Second.Score then Second=C end
    end
    local function Recurse(I)
        if I>#RemotePending then Evaluate(); return end
        for J=1,#Available do if not Used[J] then
            Used[J]=true; Choice[I]=J; Recurse(I+1); Used[J]=nil
        end end
    end
    Recurse(1)
    if Best==nil then return false end
    local SecondScore=Second and Second.Score or nil
    local Margin=SecondScore and (SecondScore-Best.Score) or 999999
    if Best.Score>175.0 or Best.MaxErr>300.0 or (Second~=nil and Margin<50.0) then
        return false
    end
    local Mapping={}
    for I,R in ipairs(RemotePending) do
        local A=Available[Best.Choice[I]]
        Mapping[#Mapping+1]=string.format("%s->%s(err=%.1f)",tostring(R.PlayerId or "?"),
            tostring(string.match(A.Key or "","BP_SpartansBipedActor_C_%d+") or A.Key),Best.Residual[I] or -1)
        Assign(R,A,"motion-delta-"..tostring(LocationMode),Best.Residual[I],"translation-invariant-motion")
    end
    Compact()
    Log("ARMORSKIN motion identity mapping mode=%s players=%d rms=%.1f maxErr=%.1f margin=%.1f pawnMove=%.1f bipedMove=%.1f map=%s",
        tostring(LocationMode),#Mapping,Best.Score,Best.MaxErr,Margin,MaxPawnMove,MaxBipedMove,table.concat(Mapping," | "))
    return #Mapping>0
end

function ArmorSkinClearBipedAssignments(Reason)
    ArmorSkinBipedAssignmentByPawnKey = {}
    ArmorSkinBipedAssignmentMetaByPawnKey = {}
    ArmorSkinBipedAssignmentAuditLogged = {}
    ArmorSkinBipedAnchorPendingLogged = {}
    ArmorSkinBipedMotionBaseline = {}
    ArmorSkinBipedOrdinalAuditLogged = {}
    ArmorSkinOrdinalAuditLogged = {}
    ArmorSkinRemoteSplitSlotAuditLogged = {}
    if Reason ~= nil and tostring(Reason) ~= "" then
        Log("ARMORSKIN biped assignments invalidated reason=%s", tostring(Reason))
    end
end

function ArmorSkinBuildBipedAssignments(SourcePawn)
    SourcePawn=Unwrap(SourcePawn)
    if not IsValidObject(SourcePawn) then return end
    ArmorSkinSeedExactBipedCache()

    local Records=ArmorSkinAllKnownPlayerPawnRecords()
    local NewAssign,NewMeta,UsedBiped={}, {}, {}
    local RemotePending={}
    local MissingLocalAnchors=0

    -- Direct Pawn.Children is the strongest identity anchor and is mandatory for
    -- every local split-screen player before remote inference is allowed.
    for _,R in ipairs(Records) do
        local Direct=ArmorSkinDirectBipedChild(R.Pawn)
        if IsValidObject(Direct) then
            local BK=ArmorSkinObjectKey(Direct) or tostring(SafeFullName(Direct) or "")
            NewAssign[R.Key]=Direct
            NewMeta[R.Key]={Route="Pawn.Children",Distance=0,PlayerId=R.PlayerId,ChiefSlots=ArmorSkinBipedChiefSlotCount(Direct)}
            if BK~="" then
                UsedBiped[BK]=true
                if tonumber(R.PlayerId)~=nil then
                    ArmorSkinLastKnownBipedKeyByPlayerId[tostring(math.floor(tonumber(R.PlayerId)))]=BK
                end
            end
        elseif R.LocalIndex~=nil then
            MissingLocalAnchors=MissingLocalAnchors+1
        else
            RemotePending[#RemotePending+1]=R
        end
    end

    ArmorSkinBipedAssignmentByPawnKey=NewAssign
    ArmorSkinBipedAssignmentMetaByPawnKey=NewMeta

    if MissingLocalAnchors>0 then
        local K="gen:"..tostring(WarthogColorRuntimeGeneration or 0)
        if not ArmorSkinBipedAnchorPendingLogged[K] then
            ArmorSkinBipedAnchorPendingLogged[K]=true
            Log("ARMORSKIN biped assignment WAIT localAnchors=%d records=%d cached=%d; remote guessing disabled",
                MissingLocalAnchors,#Records,#(ArmorSkinBipedInstanceCache or {}))
        end
        return
    end

    local Available={}
    -- RC3_58 fast respawn path: when two remote split players are unresolved,
    -- look at only the actors from the latest construction burst first. This
    -- avoids touching old corpse presentation actors at all.
    local FreshSource={}
    if #RemotePending==2 and (tonumber(ArmorSkinLastBipedConstructionClock) or 0)>0 then
        local Last=tonumber(ArmorSkinLastBipedConstructionClock) or 0
        local Cutoff=Last-(tonumber(ArmorSkinFreshBipedWindowSeconds) or 0.75)
        local G=tonumber(WarthogColorRuntimeGeneration) or 0
        for K,M in pairs(ArmorSkinFreshBipedByKey or {}) do
            if type(M)=="table" and tonumber(M.Generation)==G and (tonumber(M.Clock) or 0)>=Cutoff then
                FreshSource[#FreshSource+1]=M.Biped
            end
        end
    end
    local SourceList=(#FreshSource>=2) and FreshSource or (ArmorSkinBipedInstanceCache or {})
    for I,Raw in ipairs(SourceList) do
        if I>96 then break end
        local B=Unwrap(Raw)
        if IsValidObject(B) and ArmorSkinSharesRuntimeWorld(B,SourcePawn) then
            local BK=ArmorSkinObjectKey(B) or tostring(SafeFullName(B) or "")
            if BK~="" and not UsedBiped[BK] then
                local ChiefSlots=ArmorSkinBipedChiefSlotCount(B)
                if ChiefSlots>0 then Available[#Available+1]={Biped=B,Key=BK,ChiefSlots=ChiefSlots} end
            end
        end
    end
    if #FreshSource>=2 then
        local FK="fresh-fast:"..tostring(WarthogColorRuntimeGeneration or 0)..":"..tostring(#FreshSource)..":"..tostring(#Available)
        if not ArmorSkinBipedOrdinalAuditLogged[FK] then
            ArmorSkinBipedOrdinalAuditLogged[FK]=true
            Log("ARMORSKIN fresh respawn candidate fast-path remote=%d freshSource=%d available=%d",
                #RemotePending,#FreshSource,#Available)
        end
    end
    table.sort(Available,function(A,B) return tostring(A.Key)<tostring(B.Key) end)
    if #RemotePending==0 or #Available==0 then return end

    local function Assign(R,A,Route,Distance,DistanceRoute)
        NewAssign[R.Key]=A.Biped
        NewMeta[R.Key]={Route=Route,Distance=Distance,DistanceRoute=DistanceRoute,PlayerId=R.PlayerId,ChiefSlots=A.ChiefSlots}
        UsedBiped[A.Key]=true
        if tonumber(R.PlayerId)~=nil and tostring(A.Key or "")~="" then
            ArmorSkinLastKnownBipedKeyByPlayerId[tostring(math.floor(tonumber(R.PlayerId)))]=tostring(A.Key)
        end
    end
    local function Compact()
        local RP,AV={},{}
        for _,R in ipairs(RemotePending) do if not NewAssign[R.Key] then RP[#RP+1]=R end end
        for _,A in ipairs(Available) do if not UsedBiped[A.Key] then AV[#AV+1]=A end end
        RemotePending,Available=RP,AV
        ArmorSkinBipedAssignmentByPawnKey=NewAssign
        ArmorSkinBipedAssignmentMetaByPawnKey=NewMeta
    end

    -- V15 two-player respawn identity: after local Pawn.Children anchors have
    -- reserved the local body, one freshly constructed *unused* biped is exact
    -- evidence that the sole remote player respawned. If the fresh biped was
    -- consumed by the local anchor instead, the remote player did not respawn,
    -- so reuse only its previously proven string key. No suffix/order guessing.
    if #RemotePending==1 then
        local R=RemotePending[1]
        local FreshCandidates={}
        local LastConstruction=tonumber(ArmorSkinLastBipedConstructionClock) or 0
        local Cutoff=LastConstruction-(tonumber(ArmorSkinFreshBipedWindowSeconds) or 0.75)
        local G=tonumber(WarthogColorRuntimeGeneration) or 0
        for _,A in ipairs(Available) do
            local FM=ArmorSkinFreshBipedByKey and ArmorSkinFreshBipedByKey[A.Key] or nil
            if type(FM)=="table" and tonumber(FM.Generation)==G and (tonumber(FM.Clock) or 0)>=Cutoff then
                FreshCandidates[#FreshCandidates+1]=A
            end
        end
        if #FreshCandidates==1 then
            local A=FreshCandidates[1]
            local D,DR=ArmorSkinBipedDistanceToPawn(A.Biped,R.Pawn)
            Assign(R,A,"single-remote-fresh-respawn",D,DR)
            Compact()
            Log("CLASSIC18V15 remote identity lifecycle fresh playerId=%s biped=%s",
                tostring(R.PlayerId or "?"),tostring(A.Key or "?"))
            return
        end
        local LastKey=tonumber(R.PlayerId)~=nil and ArmorSkinLastKnownBipedKeyByPlayerId[tostring(math.floor(tonumber(R.PlayerId)))] or nil
        if LastKey~=nil then
            for _,A in ipairs(Available) do
                if tostring(A.Key)==tostring(LastKey) then
                    local D,DR=ArmorSkinBipedDistanceToPawn(A.Biped,R.Pawn)
                    Assign(R,A,"single-remote-previous-proven-key",D,DR)
                    Compact()
                    Log("CLASSIC18V15 remote identity preserved playerId=%s biped=%s",
                        tostring(R.PlayerId or "?"),tostring(A.Key or "?"))
                    return
                end
            end
        end
    end

    -- First use actual UObject owner/attachment/parent identity when the remote
    -- presentation exposes it. Require a one-to-one match on both sides.
    local Matches,Reverse={},{}
    for RI,R in ipairs(RemotePending) do
        Matches[RI]={}
        for AI,A in ipairs(Available) do
            local Linked,Route=ArmorSkinObjectChainReachesPawn(A.Biped,R.Pawn)
            if Linked then
                Matches[RI][#Matches[RI]+1]={AI=AI,Route=Route}
                Reverse[AI]=(Reverse[AI] or 0)+1
            end
        end
    end
    for RI,M in ipairs(Matches) do
        if #M==1 and Reverse[M[1].AI]==1 then
            local R,A=RemotePending[RI],Available[M[1].AI]
            Assign(R,A,"biped-object-chain:"..tostring(M[1].Route),0,"identity")
        end
    end
    Compact()
    if #RemotePending==0 then return end

    -- After every local anchor is reserved, one remaining remote body is exact
    -- by elimination. This is the RC3_35/36 route already proven in 2-player net.
    if #RemotePending==1 and #Available==1 then
        local R,A=RemotePending[1],Available[1]
        local D,DR=ArmorSkinBipedDistanceToPawn(A.Biped,R.Pawn)
        Assign(R,A,"unique-remainder",D,DR)
        Compact(); return
    end
    if #Available < #RemotePending then return end

    -- RC3_49: prefer the source machine's exact P1->P2 biped displacement.
    -- This is identity-safe under arbitrary translation and never uses suffix order.
    if ArmorSkinTryPairVectorAssignment(RemotePending,Available,Assign,Compact) then return end

    -- RC3_53: do NOT run RC3_47 reflection from the live color-apply path.
    -- When the split pair-vector is missing this scan blocks the game thread for
    -- seconds and still cannot prove identity. SAFE WAIT is preferable to a hitch.

    -- Retain motion only as a cheap translation-invariant fallback. The RC3_46
    -- calibrated absolute-space fit is intentionally disabled: live data showed
    -- the two remote pawns collapse to the same presentation-space matrix.
    if ArmorSkinTryMotionAssignment(RemotePending,Available,Assign,Compact,"actor") then return end
    if ArmorSkinTryMotionAssignment(RemotePending,Available,Assign,Compact,"chief") then return end

    local K="multi-safe-wait:"..tostring(WarthogColorRuntimeGeneration or 0)
    if not ArmorSkinBipedAnchorPendingLogged[K] then
        ArmorSkinBipedAnchorPendingLogged[K]=true
        local Slots={}
        for _,R in ipairs(RemotePending) do
            Slots[#Slots+1]=string.format("%s:P%s",tostring(R.PlayerId or "?"),tostring(ArmorSkinNetworkOriginSlotForPlayerId(R.PlayerId) or "?"))
        end
        Log("ARMORSKIN biped assignment SAFE WAIT remote=%d available=%d slots=%s; deterministic identity pending (object-chain/lifecycle/motion); no suffix/role guessing",
            #RemotePending,#Available,table.concat(Slots,","))
    end

end

function ArmorSkinFindAssignedBiped(Pawn)
    Pawn=Unwrap(Pawn); if not IsValidObject(Pawn) then return nil end
    local PK=ArmorSkinObjectKey(Pawn) or tostring(SafeFullName(Pawn) or "")

    -- Always re-check the identity-safe direct relation before trusting cache.
    -- This repairs the exact lifecycle race seen in RC3_35 when Pawn.Children
    -- becomes populated after the first network message.
    local Direct=ArmorSkinDirectBipedChild(Pawn)
    if IsValidObject(Direct) then
        local Old=Unwrap(ArmorSkinBipedAssignmentByPawnKey[PK])
        if not IsValidObject(Old) or not ArmorSkinSameObject(Old,Direct) then
            ArmorSkinBipedAssignmentAuditLogged[PK]=nil
        end
        ArmorSkinBipedAssignmentByPawnKey[PK]=Direct
        ArmorSkinBipedAssignmentMetaByPawnKey[PK]={Route="Pawn.Children",Distance=0,PlayerId=ArmorSkinPlayerIdFromPawn(Pawn),ChiefSlots=ArmorSkinBipedChiefSlotCount(Direct)}
        return Direct
    end

    -- A local player without its direct biped anchor is still constructing.
    -- Never let a spatial/remainder resolver paint another player's body.
    if ArmorSkinLocalPlayerIndexForPawn(Pawn)~=nil then
        ArmorSkinBipedAssignmentByPawnKey[PK]=nil
        ArmorSkinBipedAssignmentMetaByPawnKey[PK]=nil
        ArmorSkinBuildBipedAssignments(Pawn)
        return nil
    end

    local B=Unwrap(ArmorSkinBipedAssignmentByPawnKey[PK])
    if IsValidObject(B) then
        -- If a previously assigned remote biped later becomes the direct child
        -- of some other pawn, invalidate immediately and rebuild.
        local OwnerKey=ArmorSkinBipedDirectOwnerPawnKey(B)
        if OwnerKey~=nil and tostring(OwnerKey)~=tostring(PK) then
            ArmorSkinBipedAssignmentByPawnKey[PK]=nil
            ArmorSkinBipedAssignmentMetaByPawnKey[PK]=nil
            ArmorSkinBipedAssignmentAuditLogged[PK]=nil
            B=nil
        end
    end
    if not IsValidObject(B) then
        ArmorSkinBuildBipedAssignments(Pawn)
        B=Unwrap(ArmorSkinBipedAssignmentByPawnKey[PK])
    end

    if IsValidObject(B) then
        local Meta=ArmorSkinBipedAssignmentMetaByPawnKey[PK] or {}
        if not ArmorSkinBipedAssignmentAuditLogged[PK] then
            ArmorSkinBipedAssignmentAuditLogged[PK]=true
            Log("ARMORSKIN biped assignment playerId=%s pawn=%s biped=%s route=%s distance=%s distanceRoute=%s chiefSlots=%s",
                tostring(Meta.PlayerId or ArmorSkinPlayerIdFromPawn(Pawn) or "?"),tostring(SafeFullName(Pawn) or Pawn),
                tostring(SafeFullName(B) or B),tostring(Meta.Route or "cached"),
                Meta.Distance~=nil and string.format("%.1f",tonumber(Meta.Distance) or -1) or "-",
                tostring(Meta.DistanceRoute or "-"),tostring(Meta.ChiefSlots or ArmorSkinBipedChiefSlotCount(B)))
        end
        return B
    end

    if not ArmorSkinBipedAssignmentAuditLogged["fail:"..PK] then
        ArmorSkinBipedAssignmentAuditLogged["fail:"..PK]=true
        local Parts={}
        for I,Raw in ipairs(ArmorSkinBipedInstanceCache or {}) do
            if I>8 then break end
            local C=Unwrap(Raw)
            if IsValidObject(C) then
                local D,DR=ArmorSkinBipedDistanceToPawn(C,Pawn)
                Parts[#Parts+1]=string.format("#%d %s chief=%d dist=%s via=%s world=%s",I,tostring(SafeFullName(C) or C),ArmorSkinBipedChiefSlotCount(C),D and string.format("%.1f",D) or "-",tostring(DR),tostring(ArmorSkinSharesRuntimeWorld(C,Pawn)))
            end
        end
        Log("ARMORSKIN biped assignment unresolved playerId=%s pawn=%s cached=%d detail=%s",tostring(ArmorSkinPlayerIdFromPawn(Pawn) or "?"),tostring(SafeFullName(Pawn) or Pawn),#(ArmorSkinBipedInstanceCache or {}),table.concat(Parts," | "))
    end
    return nil
end

function ArmorSkinFindSpatialBiped(Pawn)
    Pawn=Unwrap(Pawn); if not IsValidObject(Pawn) then return nil end
    return ArmorSkinFindAssignedBiped(Pawn)
end

function ArmorSkinFindThirdPersonBiped(Pawn)
    Pawn = Unwrap(Pawn)
    if not IsValidObject(Pawn) then return nil end

    -- Fast/local route retained unchanged.
    local Children = nil
    pcall(function() Children = Pawn.Children end)
    for _, ChildValue in ipairs(ArrayValues(Children)) do
        local Child = Unwrap(ChildValue)
        if IsValidObject(Child) and ArmorSkinContainsCI(SafeFullName(Child), "BP_SpartansBipedActor_C") then
            ArmorSkinCacheBipedInstance(Child, "Pawn.Children")
            return Child
        end
    end

    -- Replicated ChildActorComponent children are not guaranteed to appear in
    -- AActor.Children. The component itself still belongs to the exact pawn, so
    -- ChildActor/GetChildActor and attached-component owner are identity-safe.
    for ComponentIndex, RawComponent in ipairs(WarthogGetActorComponents(Pawn) or {}) do
        if ComponentIndex > 128 then break end
        local Component = Unwrap(RawComponent)
        if IsValidObject(Component) then
            local Candidate = nil
            pcall(function() Candidate = Unwrap(Component:GetChildActor()) end)
            if not IsValidObject(Candidate) then pcall(function() Candidate = Unwrap(Component.ChildActor) end) end
            if IsValidObject(Candidate) and ArmorSkinContainsCI(SafeFullName(Candidate), "BP_SpartansBipedActor_C") then
                local PawnKey = ArmorSkinObjectKey(Pawn) or tostring(SafeFullName(Pawn) or "")
                if not ArmorSkinRemoteBipedRouteLogged[PawnKey] then
                    ArmorSkinRemoteBipedRouteLogged[PawnKey] = true
                    Log("ARMORSKIN remote biped resolved pawn=%s biped=%s route=PawnComponent[%d].ChildActor",
                        tostring(SafeFullName(Pawn) or Pawn), tostring(SafeFullName(Candidate) or Candidate), ComponentIndex)
                end
                ArmorSkinCacheBipedInstance(Candidate, "PawnComponent.ChildActor")
                return Candidate
            end

            local AttachChildren = nil
            pcall(function() AttachChildren = Component.AttachChildren end)
            for ChildIndex, RawChildComponent in ipairs(ArrayValues(AttachChildren)) do
                if ChildIndex > 48 then break end
                local ChildComponent = Unwrap(RawChildComponent)
                if IsValidObject(ChildComponent) then
                    local Owner = nil
                    pcall(function() Owner = Unwrap(ChildComponent:GetOwner()) end)
                    if IsValidObject(Owner) and ArmorSkinContainsCI(SafeFullName(Owner), "BP_SpartansBipedActor_C") then
                        local Linked = select(1, ArmorSkinObjectChainReachesPawn(Owner, Pawn))
                        if Linked then
                            local PawnKey = ArmorSkinObjectKey(Pawn) or tostring(SafeFullName(Pawn) or "")
                            if not ArmorSkinRemoteBipedRouteLogged[PawnKey] then
                                ArmorSkinRemoteBipedRouteLogged[PawnKey] = true
                                Log("ARMORSKIN remote biped resolved pawn=%s biped=%s route=PawnComponent[%d].AttachChildren[%d].Owner",
                                    tostring(SafeFullName(Pawn) or Pawn), tostring(SafeFullName(Owner) or Owner), ComponentIndex, ChildIndex)
                            end
                            ArmorSkinCacheBipedInstance(Owner, "AttachChildren.Owner")
                            return Owner
                        end
                    end
                end
            end
        end
    end

    -- RC3_41: do not perform a separate global FindAllOf here. Exact biped
    -- instances are cached by the runtime-class listener / bounded seed and
    -- identity-mapped below.
    local PawnName = tostring(SafeFullName(Pawn) or "")
    local Candidates = {}

    -- RC3_34: exact-UClass cache + spatial player assignment. This scans only
    -- BP_SpartansBipedActor_C instances and is therefore safe on WinGDK.
    local SpatialBiped = ArmorSkinFindSpatialBiped(Pawn)
    if IsValidObject(SpatialBiped) then return SpatialBiped end

    local PawnKey = ArmorSkinObjectKey(Pawn) or PawnName
    if not ArmorSkinRemoteBipedFailureLogged[PawnKey] then
        ArmorSkinRemoteBipedFailureLogged[PawnKey] = true
        local Detail = {}
        local Shown = 0
        for _, RawCandidate in ipairs(Candidates or {}) do
            if Shown >= 6 then break end
            local Candidate = Unwrap(RawCandidate)
            if IsValidObject(Candidate) then
                local CandidateName = tostring(SafeFullName(Candidate) or "")
                if ArmorSkinSharesRuntimeWorld(Candidate, Pawn) then
                    Shown = Shown + 1
                    local Owner, ParentActor, ParentComponent = nil, nil, nil
                    pcall(function() Owner = Unwrap(Candidate:GetOwner()) end)
                    pcall(function() ParentActor = Unwrap(Candidate:GetParentActor()) end)
                    pcall(function() ParentComponent = Unwrap(Candidate:GetParentComponent()) end)
                    Detail[#Detail + 1] = string.format("#%d owner=%s parentActor=%s parentComp=%s",
                        Shown,
                        tostring(SafeFullName(Owner) or "-"),
                        tostring(SafeFullName(ParentActor) or "-"),
                        tostring(SafeFullName(ParentComponent) or "-"))
                end
            end
        end
        Log("ARMORSKIN remote biped unresolved pawn=%s candidates=%d detail=%s",
            PawnName, Shown, table.concat(Detail, " | "))
    end
    return nil
end

function ArmorSkinGetMaterialSlots(Component)
    local Output = {}
    Component = Unwrap(Component)
    if not IsValidObject(Component) then return Output end
    local Count = nil
    pcall(function() Count = tonumber(Component:GetNumMaterials()) end)
    if Count == nil or Count <= 0 or Count >= 64 then return Output end
    for Slot = 0, Count - 1 do
        local Material = nil
        pcall(function() Material = Unwrap(Component:GetMaterial(Slot)) end)
        if IsValidObject(Material) then Output[#Output + 1] = { Slot = Slot, Material = Material } end
    end
    return Output
end

function ArmorSkinParameterInfoFields(Entry)
    Entry = Unwrap(Entry)
    if Entry == nil then return nil, "", nil, nil end
    local Info = nil
    pcall(function() Info = Unwrap(Entry.ParameterInfo) end)
    if Info == nil then return nil, "", nil, nil end
    local Name, Association, Index = nil, nil, nil
    pcall(function() Name = Unwrap(Info.Name) end)
    pcall(function() Association = Unwrap(Info.Association) end)
    pcall(function() Index = Unwrap(Info.Index) end)
    return Info, SafeToString(Name), Association, Index
end

function ArmorSkinFindDiffuseParams(Material)
    Material = Unwrap(Material)
    if not IsValidObject(Material) then return nil, "material unavailable" end
    local Out, SeenParam, SeenMaterial = {}, {}, {}
    local Current = Material
    for _ = 1, 8 do
        if not IsValidObject(Current) then break end
        local MK = tostring(SafeFullName(Current) or "")
        if MK == "" or SeenMaterial[MK] then break end
        SeenMaterial[MK] = true
        local Values = nil
        pcall(function() Values = Current.TextureParameterValues end)
        for _, Entry in ipairs(ArrayValues(Values)) do
            local Info, Name, Association, Index = ArmorSkinParameterInfoFields(Entry)
            local Texture = nil
            pcall(function() Texture = Unwrap(Entry.ParameterValue) end)
            if Info ~= nil and IsValidObject(Texture) and string.lower(tostring(Name or "")) == "diffuse map" then
                local K = tostring(Association or 0) .. ":" .. tostring(Index or 0)
                if not SeenParam[K] then
                    SeenParam[K] = true
                    Out[#Out + 1] = { Info = Info, Association = Association, Index = Index }
                end
            end
        end
        Current = WarthogMaterialParent(Current)
    end
    if #Out == 0 then return nil, "layered Diffuse Map parameters unavailable" end
    return Out, nil
end

-- RC3_27: the RC3_26 live log proved the discovered BPC_FP_SkeletalMesh_C
-- remains bound to all seven MIDs (detachedBefore=0), yet the visible first-person
-- arms stay green. That rules out the old rebind theory. First-person materials
-- can use a different Infinite-derived parameter layout from the third-person
-- Spartan material, so discover their color-bearing texture/vector overrides too.
function ArmorSkinFirstPersonParamKey(Name, Association, Index)
    return string.lower(tostring(Name or "")) .. "|" .. tostring(Association or 0) .. "|" .. tostring(Index or 0)
end

function ArmorSkinFirstPersonTextureParamCandidate(Name, Texture)
    local N = string.lower(tostring(Name or ""))
    local T = string.lower(tostring(SafeFullName(Unwrap(Texture)) or ""))
    local Excluded = string.find(N, "normal", 1, true) ~= nil
        or string.find(N, "rough", 1, true) ~= nil
        or string.find(N, "metal", 1, true) ~= nil
        or string.find(N, "spec", 1, true) ~= nil
        or string.find(N, "mask", 1, true) ~= nil
        or string.find(N, "orm", 1, true) ~= nil
        or string.find(N, "emiss", 1, true) ~= nil
        or string.find(N, "opacity", 1, true) ~= nil
        or string.find(N, "height", 1, true) ~= nil
    if Excluded then return false end
    if string.find(N, "diffuse", 1, true) ~= nil
        or string.find(N, "albedo", 1, true) ~= nil
        or string.find(N, "base color", 1, true) ~= nil
        or string.find(N, "basecolor", 1, true) ~= nil
        or string.find(N, "color map", 1, true) ~= nil
        or string.find(N, "colormap", 1, true) ~= nil then
        return true
    end
    return string.find(T, "chief", 1, true) ~= nil
        or string.find(T, "spartan", 1, true) ~= nil
        or string.find(T, "markv", 1, true) ~= nil
        or string.find(T, "mark_v", 1, true) ~= nil
        or string.find(T, "armor", 1, true) ~= nil
        or string.find(T, "arm_", 1, true) ~= nil
        or string.find(T, "arms", 1, true) ~= nil
        or string.find(T, "glove", 1, true) ~= nil
end

function ArmorSkinFirstPersonVectorParamCandidate(Name, Value)
    local N = string.lower(tostring(Name or ""))
    local Excluded = string.find(N, "emiss", 1, true) ~= nil
        or string.find(N, "light", 1, true) ~= nil
        or string.find(N, "fresnel", 1, true) ~= nil
        or string.find(N, "rim", 1, true) ~= nil
        or string.find(N, "spec", 1, true) ~= nil
        or string.find(N, "rough", 1, true) ~= nil
        or string.find(N, "metal", 1, true) ~= nil
        or string.find(N, "shield", 1, true) ~= nil
        or string.find(N, "damage", 1, true) ~= nil
        or string.find(N, "blood", 1, true) ~= nil
    if Excluded then return false end
    if WarthogLooksLikeOriginalOlive(Value) then return true end
    return string.find(N, "tint", 1, true) ~= nil
        or string.find(N, "primary", 1, true) ~= nil
        or string.find(N, "armor", 1, true) ~= nil
        or string.find(N, "armour", 1, true) ~= nil
        or string.find(N, "paint", 1, true) ~= nil
        or string.find(N, "base color", 1, true) ~= nil
        or string.find(N, "basecolor", 1, true) ~= nil
        or N == "color" or N == "colour"
end

function ArmorSkinCollectFirstPersonParams(Material)
    local TextureParams, VectorParams = {}, {}
    local SeenTex, SeenVec, SeenMaterial = {}, {}, {}
    local Current = Unwrap(Material)
    for _ = 1, 10 do
        if not IsValidObject(Current) then break end
        local MaterialKey = tostring(SafeFullName(Current) or "")
        if MaterialKey == "" or SeenMaterial[MaterialKey] then break end
        SeenMaterial[MaterialKey] = true

        local Textures = nil
        pcall(function() Textures = Current.TextureParameterValues end)
        for _, RawEntry in ipairs(ArrayValues(Textures)) do
            local Entry = Unwrap(RawEntry)
            local Info, Name, Association, Index = ArmorSkinParameterInfoFields(Entry)
            local ParameterValue = nil
            pcall(function() ParameterValue = Unwrap(Entry.ParameterValue) end)
            local Key = ArmorSkinFirstPersonParamKey(Name, Association, Index)
            if Info ~= nil and not SeenTex[Key] and ArmorSkinFirstPersonTextureParamCandidate(Name, ParameterValue) then
                SeenTex[Key] = true
                TextureParams[#TextureParams + 1] = {
                    Info=Info, Name=Name, Association=Association, Index=Index, Original=ParameterValue,
                }
            end
        end

        local Vectors = nil
        pcall(function() Vectors = Current.VectorParameterValues end)
        for _, RawEntry in ipairs(ArrayValues(Vectors)) do
            local Entry = Unwrap(RawEntry)
            local Info, Name, Association, Index = ArmorSkinParameterInfoFields(Entry)
            local ParameterValue = nil
            pcall(function() ParameterValue = Unwrap(Entry.ParameterValue) end)
            local Copy = WarthogCopyLinearColor(ParameterValue)
            local Key = ArmorSkinFirstPersonParamKey(Name, Association, Index)
            if Info ~= nil and Copy ~= nil and not SeenVec[Key]
                and ArmorSkinFirstPersonVectorParamCandidate(Name, Copy) then
                SeenVec[Key] = true
                VectorParams[#VectorParams + 1] = {
                    Info=Info, Name=Name, Association=Association, Index=Index, Original=Copy,
                }
            end
        end
        Current = WarthogMaterialParent(Current)
    end
    return TextureParams, VectorParams
end

function ArmorSkinSetFirstPersonOverrides(MID, DiffuseParams, TextureParams, VectorParams, Texture, ColorIndex)
    MID = Unwrap(MID)
    Texture = Unwrap(Texture)
    if not IsValidObject(MID) or not IsValidObject(Texture) then return false, 0, 0, 0 end
    local TextureSets, NameSets, VectorSets = 0, 0, 0
    local SeenByInfo = {}

    for _, Param in ipairs(DiffuseParams or {}) do
        local Key = ArmorSkinFirstPersonParamKey("Diffuse Map", Param.Association, Param.Index)
        local Ok = pcall(function() MID:SetTextureParameterValueByInfo(Param.Info, Texture) end)
        if Ok then TextureSets = TextureSets + 1; SeenByInfo[Key] = true end
    end
    for _, Param in ipairs(TextureParams or {}) do
        local Key = ArmorSkinFirstPersonParamKey(Param.Name, Param.Association, Param.Index)
        if not SeenByInfo[Key] then
            local Ok = pcall(function() MID:SetTextureParameterValueByInfo(Param.Info, Texture) end)
            if Ok then TextureSets = TextureSets + 1; SeenByInfo[Key] = true end
        end
        if tostring(Param.Name or "") ~= "" then
            local Ok = pcall(function() MID:SetTextureParameterValue(FName(tostring(Param.Name)), Texture) end)
            if Ok then NameSets = NameSets + 1 end
        end
    end

    local Color = WarthogCEColors[tonumber(ColorIndex) or 0]
    local Linear = Color and WarthogColorLinear(Color) or nil
    if Linear ~= nil then
        for _, Param in ipairs(VectorParams or {}) do
            local Ok = pcall(function() MID:SetVectorParameterValueByInfo(Param.Info, Linear) end)
            if Ok then VectorSets = VectorSets + 1 end
            if tostring(Param.Name or "") ~= "" then
                pcall(function() MID:SetVectorParameterValue(FName(tostring(Param.Name)), Linear) end)
            end
        end
    end
    return (TextureSets + NameSets + VectorSets) > 0, TextureSets, NameSets, VectorSets
end

function ArmorSkinRefreshComponent(Component)
    Component = Unwrap(Component)
    if not IsValidObject(Component) then return end
    pcall(function() Component:MarkRenderStateDirty() end)
    pcall(function() Component:UpdateMaterialInstances() end)
end

function ArmorSkinCreateMID(Item, Serial)
    local MID = nil
    local Errors = {}
    local Ok, Err = pcall(function()
        MID = Unwrap(Item.Component:CreateDynamicMaterialInstance(
            Item.Slot, Item.OriginalMaterial, FName("HCECoopArmorSkin_" .. tostring(Serial))))
    end)
    if not Ok then Errors[#Errors + 1] = tostring(Err) end
    if not IsValidObject(MID) then
        Ok, Err = pcall(function()
            MID = Unwrap(Item.Component:CreateAndSetMaterialInstanceDynamicFromMaterial(Item.Slot, Item.OriginalMaterial))
        end)
        if not Ok then Errors[#Errors + 1] = tostring(Err) end
    end
    return IsValidObject(MID) and MID or nil, table.concat(Errors, " | ")
end

function ArmorSkinSetTextureOnMID(MID, Params, Texture)
    MID = Unwrap(MID)
    Texture = Unwrap(Texture)
    if not IsValidObject(MID) or not IsValidObject(Texture) then return false, 0 end
    local Count = 0
    for _, Param in ipairs(Params or {}) do
        local Ok, Err = pcall(function() MID:SetTextureParameterValueByInfo(Param.Info, Texture) end)
        if not Ok then
            Log("ARMORSKIN texture set failed association=%s index=%s error=%s",
                SafeToString(Param.Association), SafeToString(Param.Index), tostring(Err))
            return false, Count
        end
        Count = Count + 1
    end
    return Count > 0, Count
end

function ArmorSkinColorLabel(ColorIndex)
    ColorIndex = tonumber(ColorIndex) or 0
    if ColorIndex == 0 then return "ORIGINAL GREEN" end
    local Color = WarthogCEColors[ColorIndex]
    return Color and tostring(Color.Name) or tostring(ColorIndex)
end

function ArmorSkinLoadTexture(ColorIndex)
    ColorIndex = tonumber(ColorIndex)
    if ColorIndex == nil or ColorIndex < 1 or ColorIndex > #WarthogCEColors then return nil, "invalid color index" end
    local Color = WarthogCEColors[ColorIndex]
    local Cached = ArmorSkinTextureCache[Color.Name]
    if IsValidObject(Cached) then return Cached, nil end
    local AssetName = "T_HCEChief_Color_" .. tostring(Color.Name)
    local Path = "/Game/Mods/HCECoopArmor/" .. AssetName
    local FullPath = Path .. "." .. AssetName
    local Texture = nil
    local LastError = "load returned invalid"

    -- Both forms are valid UE object references on the builds tested. Frontend
    -- LoadAsset accepted the package form; network-client sessions sometimes
    -- returned an invalid UObject there, so RC3_29 also tries the explicit
    -- object form before falling back to already-loaded object lookup.
    for _, CandidatePath in ipairs({ Path, FullPath }) do
        if not IsValidObject(Texture) then
            local Ok, Err = pcall(function() Texture = Unwrap(LoadAsset(CandidatePath)) end)
            if not Ok then LastError = tostring(Err) end
        end
    end
    if not IsValidObject(Texture) then pcall(function() Texture = Unwrap(StaticFindObject(FullPath)) end) end
    if not IsValidObject(Texture) then pcall(function() Texture = Unwrap(StaticFindObject(Path)) end) end
    if not IsValidObject(Texture) then
        return nil, string.format("%s unavailable/not cooked (%s)", AssetName, tostring(LastError))
    end
    ArmorSkinTextureCache[Color.Name] = Texture
    Log("ARMORSKIN VT loaded index=%d color=%s asset=%s", ColorIndex, tostring(Color.Name), SafeFullName(Texture))
    return Texture, nil
end

function ArmorSkinFindPersistentGameInstance()
    local Cached = Unwrap(ArmorSkinTextureKeeperGameInstance)
    if IsValidObject(Cached) then return Cached end

    local World = nil
    pcall(function() World = Unwrap(UEHelpers.GetWorldContextObject()) end)
    local GameInstance = nil
    if IsValidObject(World) then
        pcall(function() GameInstance = Unwrap(World:GetGameInstance()) end)
        if not IsValidObject(GameInstance) then pcall(function() GameInstance = Unwrap(World.OwningGameInstance) end) end
    end
    if not IsValidObject(GameInstance) then
        pcall(function() GameInstance = Unwrap(FindFirstOf("GameInstance")) end)
    end
    if not IsValidObject(GameInstance) then
        local Instances = nil
        pcall(function() Instances = FindAllOf("HaloOnlineGameInstance") end)
        for _, Candidate in ipairs(Instances or {}) do
            Candidate = Unwrap(Candidate)
            if IsValidObject(Candidate) then GameInstance = Candidate break end
        end
    end
    if IsValidObject(GameInstance) then
        ArmorSkinTextureKeeperGameInstance = GameInstance
        return GameInstance
    end
    return nil
end

function ArmorSkinFindKeeperParentMaterial()
    local Cached = Unwrap(ArmorSkinTextureKeeperParent)
    if IsValidObject(Cached) then return Cached end
    local Paths = {
        "/Game/Characters/Spartans/Default/Materials/MI_Chief_Armor",
        "/Game/Characters/Spartans/Default/Materials/MI_Chief_Armor.MI_Chief_Armor",
    }
    local Parent = nil
    for _, Path in ipairs(Paths) do
        if not IsValidObject(Parent) then pcall(function() Parent = Unwrap(LoadAsset(Path)) end) end
    end
    if not IsValidObject(Parent) then
        pcall(function() Parent = Unwrap(StaticFindObject("/Game/Characters/Spartans/Default/Materials/MI_Chief_Armor.MI_Chief_Armor")) end)
    end
    if IsValidObject(Parent) then ArmorSkinTextureKeeperParent = Parent return Parent end
    return nil
end

function ArmorSkinEnsurePersistentTextureKeeper(ColorIndex, Texture)
    ColorIndex = tonumber(ColorIndex)
    Texture = Unwrap(Texture)
    if ColorIndex == nil or not IsValidObject(Texture) then return false, "texture unavailable" end
    local Color = WarthogCEColors[ColorIndex]
    if Color == nil then return false, "invalid color" end
    local Existing = Unwrap(ArmorSkinTextureKeeperByColor[Color.Name])
    if IsValidObject(Existing) then return true, "existing" end

    local GameInstance = ArmorSkinFindPersistentGameInstance()
    if not IsValidObject(GameInstance) then return false, "GameInstance unavailable" end
    local Parent = ArmorSkinFindKeeperParentMaterial()
    if not IsValidObject(Parent) then return false, "MI_Chief_Armor unavailable" end

    local MIDClass = Unwrap(ArmorSkinTextureKeeperClass)
    if not IsValidObject(MIDClass) then
        pcall(function() MIDClass = Unwrap(StaticFindObject("/Script/Engine.MaterialInstanceDynamic")) end)
        if IsValidObject(MIDClass) then ArmorSkinTextureKeeperClass = MIDClass end
    end
    if not IsValidObject(MIDClass) then return false, "MaterialInstanceDynamic class unavailable" end

    local Keeper = nil
    local Name = FName("HCEArmorTextureKeeper_" .. tostring(Color.Name))
    local ConstructErr = ""
    local Ok, Err = pcall(function()
        -- Mirrors UE4SS BPML_GenericFunctions' persistent-object pattern:
        -- GameInstance outer + GarbageCollectionKeepFlags. RF_Standalone is
        -- added as a second safety net because these keepers live for process life.
        Keeper = Unwrap(StaticConstructObject(MIDClass, GameInstance, Name, 0x00000042, 0x0E000000,
            false, false, nil, nil, nil))
    end)
    if not Ok then ConstructErr = tostring(Err) end
    if not IsValidObject(Keeper) then return false, "keeper construct failed: " .. ConstructErr end

    local ParentOk = pcall(function() Keeper.Parent = Parent end)
    local SetOk, SetErr = pcall(function() Keeper:SetTextureParameterValue(FName("Diffuse Map"), Texture) end)
    if not SetOk then
        -- Some UE builds accept a string/FName wrapper differently; keep this
        -- bounded fallback rather than failing the whole network feature.
        SetOk, SetErr = pcall(function() Keeper:SetTextureParameterValue("Diffuse Map", Texture) end)
    end
    if not SetOk then
        return false, string.format("keeper texture bind failed parentSet=%s error=%s", tostring(ParentOk), tostring(SetErr))
    end

    ArmorSkinTextureKeeperByColor[Color.Name] = Keeper
    return true, "created"
end

function ArmorSkinTexturePrewarmPass(Source)
    local Loaded, Failed, Kept, KeeperFailed = 0, 0, 0, 0
    local FailureText = {}
    for Index = 1, #WarthogCEColors do
        local Texture, Err = ArmorSkinLoadTexture(Index)
        if IsValidObject(Texture) then
            Loaded = Loaded + 1
            local KeepOk, KeepInfo = ArmorSkinEnsurePersistentTextureKeeper(Index, Texture)
            if KeepOk then
                Kept = Kept + 1
            else
                KeeperFailed = KeeperFailed + 1
                if #FailureText < 4 then FailureText[#FailureText + 1] = ArmorSkinColorLabel(Index) .. ":" .. tostring(KeepInfo) end
            end
        else
            Failed = Failed + 1
            if #FailureText < 4 then FailureText[#FailureText + 1] = ArmorSkinColorLabel(Index) .. ":" .. tostring(Err) end
        end
    end
    ArmorSkinTexturePrewarmComplete = Loaded == #WarthogCEColors and Kept == #WarthogCEColors
    Log("ARMORSKIN texture prewarm source=%s loaded=%d failed=%d kept=%d keeperFailed=%d complete=%s detail=%s",
        tostring(Source or "prewarm"), Loaded, Failed, Kept, KeeperFailed,
        tostring(ArmorSkinTexturePrewarmComplete == true), table.concat(FailureText, " | "))
    return ArmorSkinTexturePrewarmComplete == true
end

function ArmorSkinScheduleTexturePrewarm(Source)
    ArmorSkinTexturePrewarmToken = (tonumber(ArmorSkinTexturePrewarmToken) or 0) + 1
    local Token = ArmorSkinTexturePrewarmToken
    local Generation = ModTravelGeneration
    for _, DelayMs in ipairs({ 250, 900, 1800, 3200 }) do
        local ThisDelay = DelayMs
        ExecuteInGameThreadWithDelay(ThisDelay, function()
            if ModTeardownGuard or Token ~= ArmorSkinTexturePrewarmToken or Generation ~= ModTravelGeneration then return end
            if ArmorSkinTexturePrewarmComplete == true then return end
            if ArmorSkinTexturePrewarmPass(string.format("%s +%dms", tostring(Source or "frontend"), ThisDelay)) then
                ArmorSkinTexturePrewarmToken = Token + 1
            end
        end)
    end
end

function ArmorSkinArmFrontendTexturePrewarm(Source)
    if ArmorSkinTexturePrewarmComplete == true then return true end
    if CurrentWorldSessionKind() ~= "frontend" then return false end
    local Generation = ModTravelGeneration
    if tonumber(ArmorSkinTexturePrewarmRequestedGeneration) == tonumber(Generation) then return false end
    ArmorSkinTexturePrewarmRequestedGeneration = Generation

    -- The frontend BP LogicMod actors are created just before the squad widget
    -- becomes usable. Wait a tiny amount so HCECoopArmor is fully registered,
    -- then execute an immediate pass rather than relying on startup timers.
    ExecuteInGameThreadWithDelay(120, function()
        if Generation ~= ModTravelGeneration or CurrentWorldSessionKind() ~= "frontend" then return end
        if ModTeardownGuard then
            -- Post-load guard normally releases within this window. The regular
            -- bounded scheduler provides the retry path once it does.
            ArmorSkinScheduleTexturePrewarm(tostring(Source or "frontend signal") .. " guard-wait")
            return
        end
        if ArmorSkinTexturePrewarmPass(tostring(Source or "frontend signal") .. " immediate") then return end
        ArmorSkinScheduleTexturePrewarm(tostring(Source or "frontend signal") .. " retry")
    end)
    Log("ARMORSKIN texture prewarm ARMED source=%s generation=%d", tostring(Source or "frontend signal"), tonumber(Generation) or -1)
    return true
end

function ArmorSkinObjectDescriptionForDetection(Object)
    Object = Unwrap(Object)
    if not IsValidObject(Object) then return "" end
    local Full = tostring(SafeFullName(Object) or "")
    local ClassFull = ""
    pcall(function()
        local Class = Object:GetClass()
        if IsValidObject(Class) then ClassFull = tostring(SafeFullName(Class) or "") end
    end)
    return Full .. " | class=" .. ClassFull
end

function ArmorSkinObjectLooksLikeWeapon(Object)
    local Lower = string.lower(ArmorSkinObjectDescriptionForDetection(Object))
    return string.find(Lower, "weaponactor", 1, true) ~= nil
        or (string.find(Lower, "bp_fp_", 1, true) ~= nil and string.find(Lower, "weapon", 1, true) ~= nil)
end

function ArmorSkinFirstPersonCandidates(Pawn)
    Pawn = Unwrap(Pawn)
    if not IsValidObject(Pawn) then return {}, "pawn unavailable" end
    local Out, Seen, Routes = {}, {}, {}

    local function Add(Object, Route)
        Object = Unwrap(Object)
        if not IsValidObject(Object) or ArmorSkinObjectLooksLikeWeapon(Object) then return end
        local Key = ArmorSkinObjectKey(Object) or ArmorSkinObjectDescriptionForDetection(Object)
        if Key == nil or Key == "" or Seen[Key] then return end
        Seen[Key] = true
        Out[#Out + 1] = Object
        Routes[#Routes + 1] = tostring(Route or "candidate")
    end

    -- Preferred route when this property is reflected correctly.
    local Direct = nil
    pcall(function() Direct = Unwrap(Pawn.FirstPersonArmsSkeletalMesh) end)
    if IsValidObject(Direct) then Add(Direct, "Pawn.FirstPersonArmsSkeletalMesh") end

    -- RC3_24 critical fallback: enumerate pawn components even when the direct
    -- property is unavailable. The weapon-skin detector already proved this
    -- class-description route is safe for Halo's CVW first-person components.
    local Components = WarthogGetActorComponents(Pawn) or {}
    for I, RawComponent in ipairs(Components) do
        if I > 96 then break end
        local Component = Unwrap(RawComponent)
        if IsValidObject(Component) then
            local Lower = string.lower(ArmorSkinObjectDescriptionForDetection(Component))
            local IsFpArms = string.find(Lower, "bpc_fp_skeletalmesh_c", 1, true) ~= nil
                or string.find(Lower, "firstpersonarmsskeletalmesh", 1, true) ~= nil
            if IsFpArms then Add(Component, string.format("PawnComponents[%d]", I)) end
        end
    end

    -- Last bounded recovery for builds where GetComponentsByClass omits the CVW
    -- wrapper but UE4SS still publishes BPC_FP_SkeletalMesh_C globally. Require
    -- the same pawn instance path so P1/P2 can never cross-wire their arms.
    if #Out == 0 then
        local PawnName = string.lower(tostring(SafeFullName(Pawn) or ""))
        local Candidates = nil
        pcall(function() Candidates = FindAllOf("BPC_FP_SkeletalMesh_C") end)
        for I, RawCandidate in ipairs(ArrayValues(Candidates)) do
            if I > 32 then break end
            local Candidate = Unwrap(RawCandidate)
            local Full = string.lower(tostring(SafeFullName(Candidate) or ""))
            if IsValidObject(Candidate) and PawnName ~= "" and string.find(Full, PawnName, 1, true) ~= nil then
                Add(Candidate, string.format("FindAllOf.BPC_FP_SkeletalMesh_C[%d]", I))
            end
        end
    end

    if #Out == 0 then
        local Components = WarthogGetActorComponents(Pawn) or {}
        local Hints = {}
        for I, RawComponent in ipairs(Components) do
            if I > 96 or #Hints >= 8 then break end
            local Component = Unwrap(RawComponent)
            if IsValidObject(Component) then
                local Desc = ArmorSkinObjectDescriptionForDetection(Component)
                local Lower = string.lower(Desc)
                if string.find(Lower, "/game/blueprints/cvw/", 1, true) ~= nil
                    or string.find(Lower, "bpc_fp_", 1, true) ~= nil
                    or string.find(Lower, "firstperson", 1, true) ~= nil then
                    Hints[#Hints + 1] = string.format("[%d]%s", I, Desc)
                end
            end
        end
        if #Hints > 0 then
            local Joined = table.concat(Hints, " ; ")
            if #Joined > 1800 then Joined = string.sub(Joined, 1, 1800) .. "..." end
            Log("ARMORSKIN first-person discovery hints=%s", Joined)
        end
    end
    return Out, (#Routes > 0 and table.concat(Routes, ",") or "unavailable")
end

function ArmorSkinFirstPersonAnchor(Pawn)
    local Candidates, Route = ArmorSkinFirstPersonCandidates(Pawn)
    local Arms = Unwrap(Candidates[1])
    if not IsValidObject(Arms) then return nil, nil, Route end
    return Arms, ArmorSkinObjectKey(Arms), Route
end

function ArmorSkinAppendMatchingSlots(Object, Scope, Slots, Seen, ExplicitArmsObject)
    Object = Unwrap(Object)
    if not IsValidObject(Object) then return 0 end
    local Added = 0
    local ComponentName = SafeFullName(Object) or ""
    local SafeExplicitArms = ExplicitArmsObject == true and not ArmorSkinObjectLooksLikeWeapon(Object)
    for _, SlotEntry in ipairs(ArmorSkinGetMaterialSlots(Object)) do
        local MaterialName = SafeFullName(SlotEntry.Material) or ""
        local LowerMaterialName = string.lower(MaterialName)
        local IsChiefArmor = string.find(LowerMaterialName, "mi_chief_armor", 1, true) ~= nil
        local IsChiefArms = string.find(LowerMaterialName, "chief", 1, true) ~= nil
            and (string.find(LowerMaterialName, "armor", 1, true) ~= nil
                or string.find(LowerMaterialName, "arms", 1, true) ~= nil
                or string.find(LowerMaterialName, "hand", 1, true) ~= nil)
        local IsChiefViaParent = false
        if not SafeExplicitArms then
            pcall(function() IsChiefViaParent = ArmorSkinMaterialLooksLikeChief(SlotEntry.Material) == true end)
        end

        -- The explicit first-person arms object is allowed to use a generic or
        -- dynamic material name. Weapon actors are excluded before this point,
        -- and the later Diffuse Map parameter gate must still match before a MID
        -- can be created. Third-person components keep the strict Chief filter.
        if IsChiefArmor or IsChiefArms or IsChiefViaParent or SafeExplicitArms then
            local Key = ComponentName .. "|" .. tostring(SlotEntry.Slot)
            if not Seen[Key] then
                Seen[Key] = true
                Slots[#Slots + 1] = {
                    Component = Object,
                    ComponentName = ComponentName,
                    Slot = SlotEntry.Slot,
                    OriginalMaterial = SlotEntry.Material,
                    Scope = Scope,
                }
                Added = Added + 1
            end
        end
    end
    return Added
end

-- RC3_33 crash-safe remote visual resolver.
-- RC3_32 proved that global FindAllOf(SkeletalMeshComponent/StaticMeshComponent)
-- on the game thread can stall WinGDK hard. This route never performs a global
-- mesh scan. It only walks objects already attached to the exact replicated pawn.
function ArmorSkinMaterialLooksLikeChief(Material)
    Material = Unwrap(Material)
    if not IsValidObject(Material) then return false end
    local Current, Seen = Material, {}
    for _ = 1, 8 do
        if not IsValidObject(Current) then break end
        local Full = tostring(SafeFullName(Current) or "")
        if Full == "" or Seen[Full] then break end
        Seen[Full] = true
        local Lower = string.lower(Full)
        if string.find(Lower, "mi_chief_armor", 1, true) ~= nil
            or (string.find(Lower, "/characters/spartans/default/", 1, true) ~= nil
                and (string.find(Lower, "armor", 1, true) ~= nil or string.find(Lower, "chief", 1, true) ~= nil)) then
            return true
        end
        local Values = nil
        pcall(function() Values = Current.TextureParameterValues end)
        for _, RawEntry in ipairs(ArrayValues(Values)) do
            local Entry = Unwrap(RawEntry)
            local Texture = nil
            pcall(function() Texture = Unwrap(Entry.ParameterValue) end)
            local T = string.lower(tostring(SafeFullName(Texture) or ""))
            if string.find(T, "t_spartans_default_armor_d", 1, true) ~= nil then return true end
        end
        Current = WarthogMaterialParent(Current)
    end
    return false
end

function ArmorSkinAppendRemoteAttachedSlots(Object, Scope, Slots, Seen)
    Object = Unwrap(Object)
    if not IsValidObject(Object) or ArmorSkinObjectLooksLikeWeapon(Object) then return 0 end
    local Desc = string.lower(ArmorSkinObjectDescriptionForDetection(Object))
    if string.find(Desc, "firstperson", 1, true) ~= nil or string.find(Desc, "bpc_fp_", 1, true) ~= nil then return 0 end
    local OnlyOwner = false
    pcall(function() OnlyOwner = Object.bOnlyOwnerSee == true end)
    if OnlyOwner then return 0 end
    local Added = 0
    local ComponentName = tostring(SafeFullName(Object) or "")
    for _, SlotEntry in ipairs(ArmorSkinGetMaterialSlots(Object)) do
        if ArmorSkinMaterialLooksLikeChief(SlotEntry.Material) then
            local Params = ArmorSkinFindDiffuseParams(SlotEntry.Material)
            if Params ~= nil then
                local K = ComponentName .. "|" .. tostring(SlotEntry.Slot)
                if not Seen[K] then
                    Seen[K] = true
                    Slots[#Slots+1] = {
                        Component=Object, ComponentName=ComponentName, Slot=SlotEntry.Slot,
                        OriginalMaterial=SlotEntry.Material, Scope=Scope,
                    }
                    Added = Added + 1
                end
            end
        end
    end
    return Added
end

function ArmorSkinAppendCrashSafeRemoteVisuals(Pawn, Slots, Seen)
    Pawn = Unwrap(Pawn)
    if not IsValidObject(Pawn) then return 0, "invalid-pawn" end
    local Queue, SeenObj, Audit = {}, {}, {}
    local function Add(Object, Route)
        Object = Unwrap(Object)
        if not IsValidObject(Object) or ArmorSkinSameObject(Object, Pawn) then return end
        local K = ArmorSkinObjectKey(Object) or tostring(SafeFullName(Object) or "")
        if K == "" or SeenObj[K] then return end
        SeenObj[K] = true
        if #Queue < 96 then Queue[#Queue+1] = {Object=Object, Route=Route} end
    end

    -- Actor-level children/attachments if the engine exposes them.
    local Values = nil
    pcall(function() Values = Pawn.Children end)
    for I,V in ipairs(ArrayValues(Values)) do if I > 24 then break end; Add(V, "Pawn.Children") end
    Values = nil
    pcall(function() Values = Pawn:GetAttachedActors() end)
    for I,V in ipairs(ArrayValues(Values)) do if I > 24 then break end; Add(V, "Pawn.GetAttachedActors") end
    Values = nil
    pcall(function() Values = Pawn.AttachedActors end)
    for I,V in ipairs(ArrayValues(Values)) do if I > 24 then break end; Add(V, "Pawn.AttachedActors") end

    -- Component tree: this is bounded to components already owned by Pawn.
    local Components = WarthogGetActorComponents(Pawn) or {}
    for I,Raw in ipairs(Components) do
        if I > 96 then break end
        local C = Unwrap(Raw)
        if IsValidObject(C) then
            Add(C, "Pawn.Component")
            local ChildActor = nil
            pcall(function() ChildActor = Unwrap(C:GetChildActor()) end)
            if not IsValidObject(ChildActor) then pcall(function() ChildActor = Unwrap(C.ChildActor) end) end
            Add(ChildActor, "Pawn.Component.ChildActor")
            local Children = nil
            pcall(function() Children = C.AttachChildren end)
            for J,RawChild in ipairs(ArrayValues(Children)) do
                if J > 24 then break end
                local CC = Unwrap(RawChild)
                Add(CC, "Pawn.Component.AttachChild")
                local Owner = nil
                pcall(function() Owner = Unwrap(CC:GetOwner()) end)
                Add(Owner, "Pawn.Component.AttachChild.Owner")
            end
        end
    end

    -- A few likely direct properties are cheap to probe and are protected by pcall.
    for _,Name in ipairs({"Mesh","Body","CharacterMesh","ThirdPersonMesh","Biped","BipedActor","ThirdPersonActor","SkeletalMeshComponent"}) do
        local V=nil; pcall(function() V=Unwrap(Pawn[Name]) end); Add(V, "Pawn."..Name)
    end

    local Added = 0
    for I,Item in ipairs(Queue) do
        if I > 96 then break end
        local O = Unwrap(Item.Object)
        if IsValidObject(O) and not ArmorSkinObjectLooksLikeWeapon(O) then
            Added = Added + ArmorSkinAppendRemoteAttachedSlots(O, "third-person-remote-attached", Slots, Seen)
            local Sub = WarthogGetActorComponents(O) or {}
            for J,SC in ipairs(Sub) do
                if J > 64 then break end
                Added = Added + ArmorSkinAppendRemoteAttachedSlots(SC, "third-person-remote-attached-component", Slots, Seen)
            end
            if #Audit < 16 then
                local Mats = #ArmorSkinGetMaterialSlots(O)
                Audit[#Audit+1] = string.format("%s route=%s mats=%d", tostring(SafeFullName(O) or "?"), tostring(Item.Route), Mats)
            end
        end
    end

    local PawnKey = ArmorSkinObjectKey(Pawn) or tostring(SafeFullName(Pawn) or "")
    if Added > 0 then
        Log("ARMORSKIN remote attached visual resolved pawn=%s slots=%d candidates=%d",
            tostring(SafeFullName(Pawn) or Pawn), Added, #Queue)
        return Added, "pawn-attached-visual"
    end
    if not ArmorSkinRemoteAttachedAuditLogged[PawnKey] then
        ArmorSkinRemoteAttachedAuditLogged[PawnKey] = true
        local D = table.concat(Audit, " | ")
        if #D > 2600 then D = string.sub(D,1,2600).."..." end
        Log("ARMORSKIN remote attached visual unresolved pawn=%s candidates=%d audit=%s",
            tostring(SafeFullName(Pawn) or Pawn), #Queue, D)
    end
    return 0, "pawn-attached-visual-unresolved"
end

-- RC3_34: learn the exact UClass(es) that carry Chief third-person armor on
-- the local player, then scan ONLY those exact classes for observer-side peers.
-- This is safer and more precise than assuming a particular generated mesh class.
function ArmorSkinCacheChiefPresentationClass(Component, Source)
    Component=Unwrap(Component)
    if not IsValidObject(Component) then return false end
    local C=nil
    pcall(function() C=Unwrap(Component:GetClass()) end)
    if not IsValidObject(C) then return false end
    local K=ArmorSkinObjectKey(C) or tostring(SafeFullName(C) or "")
    if K=="" then return false end
    local KL=string.lower(K)
    -- Never promote native generic mesh base classes into a world scan. RC3_32
    -- proved those pools are unsafe on WinGDK. Blueprint/specialized subclasses
    -- such as BPC_SkeletalMesh_C are the intended candidates.
    if string.find(KL,"/script/engine.skeletalmeshcomponent",1,true)
        or string.find(KL,"/script/engine.staticmeshcomponent",1,true)
        or string.find(KL,"/script/engine.meshcomponent",1,true) then
        return false
    end
    if ArmorSkinChiefPresentationClassSeen[K] then return true end
    ArmorSkinChiefPresentationClassSeen[K]=true
    if #ArmorSkinChiefPresentationClasses<12 then
        ArmorSkinChiefPresentationClasses[#ArmorSkinChiefPresentationClasses+1]={Class=C,Name=K,Source=tostring(Source or "local-chief")}
        Log("ARMORSKIN learned Chief presentation UClass class=%s source=%s",K,tostring(Source or "local-chief"))
    end
    return true
end

function ArmorSkinSeedChiefPresentationClassesFromLocalPlayers()
    if #ArmorSkinChiefPresentationClasses>0 then return #ArmorSkinChiefPresentationClasses end
    for PlayerIndex=1,2 do
        local Pawn=ArmorSkinGetPawnFromController(GetPlayer(PlayerIndex))
        if IsValidObject(Pawn) then
            local Biped=ArmorSkinFindThirdPersonBiped(Pawn)
            if IsValidObject(Biped) then
                for I,C in ipairs(WarthogGetActorComponents(Biped) or {}) do
                    if I>128 then break end
                    local HasChief=false
                    for _,S in ipairs(ArmorSkinGetMaterialSlots(C)) do
                        if ArmorSkinMaterialLooksLikeChief(S.Material) then HasChief=true; break end
                    end
                    if HasChief then
                        ArmorSkinCacheChiefPresentationClass(C,string.format("local P%d biped",PlayerIndex))
                    end
                end
            end
        end
    end
    return #ArmorSkinChiefPresentationClasses
end

function ArmorSkinAppendExactChiefClassRemoteVisuals(Pawn, Slots, Seen)
    Pawn=Unwrap(Pawn)
    if not IsValidObject(Pawn) then return 0,"invalid-pawn" end
    ArmorSkinSeedChiefPresentationClassesFromLocalPlayers()
    local Added,Matched,CandidateCount=0,0,0
    local Audit={}
    local PawnName=tostring(SafeFullName(Pawn) or "")
    for ClassIndex,Entry in ipairs(ArmorSkinChiefPresentationClasses or {}) do
        if ClassIndex>12 then break end
        local CClass=Unwrap(Entry.Class)
        if IsValidObject(CClass) then
            local ShortClass=ArmorSkinClassShortName(CClass,nil)
            local Found=ArmorSkinTargetedFindObjects(CClass,ShortClass,256)
            for I,Raw in ipairs(Found) do
                if I>256 then break end
                local O=Unwrap(Raw)
                if IsValidObject(O) and not ArmorSkinObjectLooksLikeWeapon(O) then
                    local ON=tostring(SafeFullName(O) or "")
                    local SameWorld=ArmorSkinSharesRuntimeWorld(O,Pawn)
                    if SameWorld then
                        local HasChief=false
                        for _,S in ipairs(ArmorSkinGetMaterialSlots(O)) do
                            if ArmorSkinMaterialLooksLikeChief(S.Material) then HasChief=true; break end
                        end
                        if HasChief then
                            CandidateCount=CandidateCount+1
                            local Linked,LinkRoute=ArmorSkinObjectChainReachesPawn(O,Pawn)
                            local Match,Dist,Why=false,nil,"not-spatial"
                            if Linked then Match=true; Why="linked-"..tostring(LinkRoute)
                            else Match,Dist,Why=ArmorSkinSpatialCandidateMatchesPawn(O,Pawn) end
                            if Match then
                                local N=ArmorSkinAppendRemoteAttachedSlots(O,"third-person-remote-exact-chief-class",Slots,Seen)
                                if N>0 then Added=Added+N; Matched=Matched+1 end
                                if #Audit<16 then
                                    Audit[#Audit+1]=string.format("MATCH class=%s obj=%s slots=%d dist=%s why=%s",tostring(Entry.Name),ON,N,Dist and string.format("%.1f",Dist) or "-",tostring(Why))
                                end
                            elseif #Audit<16 then
                                Audit[#Audit+1]=string.format("skip class=%s obj=%s dist=%s why=%s",tostring(Entry.Name),ON,Dist and string.format("%.1f",Dist) or "-",tostring(Why))
                            end
                        end
                    end
                end
            end
        end
    end
    local Key=ArmorSkinObjectKey(Pawn) or PawnName
    if Added>0 then
        Log("ARMORSKIN remote exact Chief-class visual resolved pawn=%s slots=%d matchedComponents=%d candidates=%d classes=%d detail=%s",
            PawnName,Added,Matched,CandidateCount,#ArmorSkinChiefPresentationClasses,table.concat(Audit," | "))
        return Added,"exact-chief-presentation-class"
    end
    if not ArmorSkinSyncReflectionAuditLogged["chiefclass:"..Key] then
        ArmorSkinSyncReflectionAuditLogged["chiefclass:"..Key]=true
        local D=table.concat(Audit," | ")
        if #D>3600 then D=string.sub(D,1,3600).."..." end
        Log("ARMORSKIN remote exact Chief-class visual unresolved pawn=%s candidates=%d classes=%d detail=%s",PawnName,CandidateCount,#ArmorSkinChiefPresentationClasses,D)
    end
    return 0,"exact-chief-class-unresolved"
end

-- RC3_34: event-driven cache of the actual CVW skeletal presentation components.
-- Campaign Evolved's BlamMeshSynchronization RuntimeRegions spawn skeletal
-- geometry through /Game/Blueprints/CVW/BPC_SkeletalMesh. This specific-class
-- cache lets remote armor target those generated components without touching
-- the global SkeletalMeshComponent pool.
function ArmorSkinCacheCVWSkeletal(Component, Source)
    Component=Unwrap(Component)
    if not IsValidObject(Component) then return false end
    local Full=tostring(SafeFullName(Component) or "")
    if not ArmorSkinContainsCI(Full,"BPC_SkeletalMesh_C") or string.find(Full,"Default__",1,true) then return false end
    local Key=ArmorSkinObjectKey(Component) or Full
    if Key=="" then return false end
    if not ArmorSkinCVWSkeletalSeen[Key] then
        ArmorSkinCVWSkeletalSeen[Key]=true
        if #ArmorSkinCVWSkeletalCache < 512 then ArmorSkinCVWSkeletalCache[#ArmorSkinCVWSkeletalCache+1]=Component end
    end
    if not IsValidObject(ArmorSkinCVWSkeletalClass) then
        local C=nil; pcall(function() C=Unwrap(Component:GetClass()) end)
        if IsValidObject(C) then ArmorSkinCVWSkeletalClass=C end
    end
    return true
end

function ArmorSkinEnsureCVWSkeletalClass()
    if IsValidObject(ArmorSkinCVWSkeletalClass) then return ArmorSkinCVWSkeletalClass end
    local C=nil
    pcall(function() C=Unwrap(StaticFindObject("/Game/Blueprints/CVW/BPC_SkeletalMesh.BPC_SkeletalMesh_C")) end)
    if IsValidObject(C) then ArmorSkinCVWSkeletalClass=C; return C end
    return nil
end

function ArmorSkinSeedCVWSkeletalCache()
    if not ArmorSkinCVWConstructionListenerReady then pcall(RegisterArmorSkinCVWConstructionListener) end
    if tonumber(ArmorSkinCVWExactScanGeneration)==tonumber(WarthogColorRuntimeGeneration) then return end
    ArmorSkinCVWExactScanGeneration=tonumber(WarthogColorRuntimeGeneration) or 0
    local C=ArmorSkinEnsureCVWSkeletalClass()
    local Found=ArmorSkinTargetedFindObjects(C,"BPC_SkeletalMesh_C",256)
    for _,O in ipairs(Found) do ArmorSkinCacheCVWSkeletal(O,"exact CVW class seed") end
    Log("ARMORSKIN CVW exact-class seed generation=%d found=%d cached=%d class=%s",
        tonumber(WarthogColorRuntimeGeneration) or 0,#Found,#ArmorSkinCVWSkeletalCache,tostring(SafeFullName(C) or "unavailable"))
end

function ArmorSkinRemoteCandidateDebug(Object)
    Object=Unwrap(Object); if not IsValidObject(Object) then return "invalid" end
    local Owner,Outer,Parent=nil,nil,nil
    pcall(function() Owner=Unwrap(Object:GetOwner()) end)
    pcall(function() Outer=Unwrap(Object:GetOuter()) end)
    pcall(function() Parent=Unwrap(Object:GetAttachParent()) end)
    return string.format("owner=%s outer=%s parent=%s",tostring(SafeFullName(Owner) or "-"),tostring(SafeFullName(Outer) or "-"),tostring(SafeFullName(Parent) or "-"))
end

function ArmorSkinAppendCVWRemoteVisuals(Pawn, Slots, Seen)
    Pawn=Unwrap(Pawn); if not IsValidObject(Pawn) then return 0,"invalid-pawn" end
    ArmorSkinSeedCVWSkeletalCache()
    local Added,ChiefCandidates,Matched=0,0,0
    local Audit={}
    local PawnName=tostring(SafeFullName(Pawn) or "")
    for I,Raw in ipairs(ArmorSkinCVWSkeletalCache or {}) do
        if I > 512 then break end
        local C=Unwrap(Raw)
        if IsValidObject(C) and not ArmorSkinObjectLooksLikeWeapon(C) then
            local CN=tostring(SafeFullName(C) or "")
            local SameWorld=ArmorSkinSharesRuntimeWorld(C,Pawn)
            if SameWorld then
                local HasChief=false
                for _,S in ipairs(ArmorSkinGetMaterialSlots(C)) do
                    if ArmorSkinMaterialLooksLikeChief(S.Material) then HasChief=true; break end
                end
                if HasChief then
                    ChiefCandidates=ChiefCandidates+1
                    local Linked,LinkRoute=ArmorSkinObjectChainReachesPawn(C,Pawn)
                    local Match,Dist,Why=false,nil,"not-spatial"
                    if Linked then Match=true; Why="linked-"..tostring(LinkRoute)
                    else Match,Dist,Why=ArmorSkinSpatialCandidateMatchesPawn(C,Pawn) end
                    if Match then
                        local N=ArmorSkinAppendRemoteAttachedSlots(C,"third-person-remote-cvw",Slots,Seen)
                        if N>0 then Added=Added+N; Matched=Matched+1 end
                        if #Audit<12 then Audit[#Audit+1]=string.format("MATCH %s slots=%d dist=%s why=%s %s",CN,N,Dist and string.format("%.1f",Dist) or "-",tostring(Why),ArmorSkinRemoteCandidateDebug(C)) end
                    elseif #Audit<12 then
                        Audit[#Audit+1]=string.format("skip %s dist=%s why=%s %s",CN,Dist and string.format("%.1f",Dist) or "-",tostring(Why),ArmorSkinRemoteCandidateDebug(C))
                    end
                end
            end
        end
    end
    local Key=ArmorSkinObjectKey(Pawn) or PawnName
    if Added>0 then
        Log("ARMORSKIN remote CVW visual resolved pawn=%s slots=%d matchedComponents=%d chiefCandidates=%d cached=%d detail=%s",
            PawnName,Added,Matched,ChiefCandidates,#ArmorSkinCVWSkeletalCache,table.concat(Audit," | "))
        return Added,"cvw-bpc-skeletal"
    end
    if not ArmorSkinSyncReflectionAuditLogged["cvw:"..Key] then
        ArmorSkinSyncReflectionAuditLogged["cvw:"..Key]=true
        local D=table.concat(Audit," | "); if #D>3200 then D=string.sub(D,1,3200).."..." end
        Log("ARMORSKIN remote CVW visual unresolved pawn=%s chiefCandidates=%d cached=%d detail=%s",PawnName,ChiefCandidates,#ArmorSkinCVWSkeletalCache,D)
    end
    return 0,"cvw-unresolved"
end

function ArmorSkinPropertyMeta(Property)
    Property=Unwrap(Property)
    if Property==nil then return "","" end
    local Name,TypeName="",""
    pcall(function() Name=Property:GetFName():ToString() end)
    pcall(function()
        local C=Unwrap(Property:GetClass())
        if C~=nil then TypeName=C:GetFName():ToString() end
    end)
    return tostring(Name or ""),tostring(TypeName or "")
end

function ArmorSkinReflectionInterestingName(Name)
    local L=string.lower(tostring(Name or ""))
    for _,Needle in ipairs({"mesh","component","actor","visual","render","spawn","generated","instance","active","current","body","biped","child","sync"}) do
        if string.find(L,Needle,1,true) then return true end
    end
    return false
end

function ArmorSkinAppendReflectedSyncVisuals(Pawn, Slots, Seen)
    Pawn=Unwrap(Pawn); if not IsValidObject(Pawn) then return 0,"invalid-pawn" end
    local Queue,ObjSeen,Audit,FunctionAudit={}, {}, {}, {}
    local function Add(O,Route)
        O=Unwrap(O); if not IsValidObject(O) or ArmorSkinSameObject(O,Pawn) then return end
        local K=ArmorSkinObjectKey(O) or tostring(SafeFullName(O) or "")
        if K=="" or ObjSeen[K] or #Queue>=128 then return end
        ObjSeen[K]=true; Queue[#Queue+1]={Object=O,Route=Route,Depth=0}
    end

    -- Start ONLY from the synchronization/presentation components already owned
    -- by this exact pawn. The latest network audit proved these exist remotely.
    for I,Raw in ipairs(WarthogGetActorComponents(Pawn) or {}) do
        if I>128 then break end
        local O=Unwrap(Raw); local D=string.lower(tostring(SafeFullName(O) or ""))
        if string.find(D,"mesh synchronization",1,true) or string.find(D,"meshsynchronization",1,true)
            or string.find(D,"skeletonsynchronization",1,true) or string.find(D,"haloassetgroup",1,true) then
            Add(O,"pawn-sync-component")
        end
    end

    local Seeds=#Queue
    for Q=1,math.min(#Queue,16) do
        local Item=Queue[Q]; local O=Unwrap(Item.Object)
        if IsValidObject(O) then
            local Class=nil; pcall(function() Class=Unwrap(O:GetClass()) end)
            local ClassDepth,Props=0,0
            while IsValidObject(Class) and ClassDepth<5 and Props<160 do
                ClassDepth=ClassDepth+1
                pcall(function()
                    Class:ForEachProperty(function(P)
                        if Props>=160 then return true end
                        Props=Props+1
                        local PN,PT=ArmorSkinPropertyMeta(P)
                        local PNLower=string.lower(PN); local PTLower=string.lower(PT)
                        if #Audit<90 then Audit[#Audit+1]=string.format("%s:%s",PN,PT) end
                        local ObjectLike=string.find(PTLower,"objectproperty",1,true)~=nil
                            or string.find(PTLower,"weakobjectproperty",1,true)~=nil
                            or string.find(PTLower,"arrayproperty",1,true)~=nil
                            or string.find(PTLower,"mapproperty",1,true)~=nil
                            or string.find(PTLower,"setproperty",1,true)~=nil
                        local Interesting=ArmorSkinReflectionInterestingName(PN)
                        -- RuntimeRegions is authoring/config data and can be huge; do
                        -- not traverse it. We want runtime object references only.
                        if ObjectLike and Interesting and PNLower~="runtimeregions" and not string.find(PNLower,"materialoverrides",1,true) then
                            local V=nil; pcall(function() V=O:GetPropertyValue(PN) end)
                            local Direct=Unwrap(V)
                            if IsValidObject(Direct) then Add(Direct,"reflection."..PN) end
                            local N=0
                            for _,Elem in ipairs(ArrayValues(V)) do
                                N=N+1; if N>32 then break end
                                local E=Unwrap(Elem); if IsValidObject(E) then Add(E,"reflection."..PN.."[]") end
                            end
                            pcall(function()
                                V:ForEach(function(A,B)
                                    if N>=48 then return true end
                                    N=N+1
                                    local EV=B or A
                                    EV=Unwrap(EV)
                                    if IsValidObject(EV) then Add(EV,"reflection."..PN.."{}") end
                                    return false
                                end)
                            end)
                        end
                        return false
                    end)
                end)
                local Super=nil; pcall(function() Super=Unwrap(Class:GetSuperStruct()) end)
                if not IsValidObject(Super) or ArmorSkinSameObject(Super,Class) then break end
                Class=Super
            end
            -- Functions are logged only; no unknown game function is invoked.
            if Q<=4 then
                local C=nil; pcall(function() C=Unwrap(O:GetClass()) end)
                if IsValidObject(C) then pcall(function()
                    C:ForEachFunction(function(F)
                        local FN=""; pcall(function() FN=F:GetFName():ToString() end)
                        if ArmorSkinReflectionInterestingName(FN) and #FunctionAudit<40 then FunctionAudit[#FunctionAudit+1]=FN end
                        return false
                    end)
                end) end
            end
        end
    end

    local Added=0
    for I,Item in ipairs(Queue) do
        if I>128 then break end
        local O=Unwrap(Item.Object)
        if IsValidObject(O) and not ArmorSkinObjectLooksLikeWeapon(O) then
            local Linked=select(1,ArmorSkinObjectChainReachesPawn(O,Pawn))
            local Spatial=false
            if not Linked then Spatial=select(1,ArmorSkinSpatialCandidateMatchesPawn(O,Pawn)) end
            if Linked or Spatial then
                Added=Added+ArmorSkinAppendRemoteAttachedSlots(O,"third-person-remote-sync-reflection",Slots,Seen)
                for J,SC in ipairs(WarthogGetActorComponents(O) or {}) do
                    if J>64 then break end
                    Added=Added+ArmorSkinAppendRemoteAttachedSlots(SC,"third-person-remote-sync-reflection-component",Slots,Seen)
                end
            end
        end
    end
    local Key=ArmorSkinObjectKey(Pawn) or tostring(SafeFullName(Pawn) or "")
    if Added>0 then
        Log("ARMORSKIN remote sync reflection resolved pawn=%s slots=%d seeds=%d objects=%d",tostring(SafeFullName(Pawn) or Pawn),Added,Seeds,#Queue)
        return Added,"sync-reflection"
    end
    if not ArmorSkinSyncReflectionAuditLogged["reflect:"..Key] then
        ArmorSkinSyncReflectionAuditLogged["reflect:"..Key]=true
        local P=table.concat(Audit,","); if #P>4200 then P=string.sub(P,1,4200).."..." end
        local F=table.concat(FunctionAudit,","); if #F>1800 then F=string.sub(F,1,1800).."..." end
        Log("ARMORSKIN sync reflection audit pawn=%s seeds=%d objects=%d props=%s functions=%s",
            tostring(SafeFullName(Pawn) or Pawn),Seeds,#Queue,P,F)
    end
    return 0,"sync-reflection-unresolved"
end

function RegisterArmorSkinCVWConstructionListener()
    if ArmorSkinCVWConstructionListenerReady then return true end
    local Ok,Err=pcall(function()
        NotifyOnNewObject("/Game/Blueprints/CVW/BPC_SkeletalMesh.BPC_SkeletalMesh_C",function(Component)
            ArmorSkinCacheCVWSkeletal(Component,"NotifyOnNewObject")
        end)
    end)
    if Ok then
        ArmorSkinCVWConstructionListenerReady=true
        Log("ARMORSKIN CVW BPC_SkeletalMesh construction listener ready; remote presentation cache is event-driven")
        return true
    end
    Log("ARMORSKIN CVW BPC_SkeletalMesh construction listener unavailable: %s",tostring(Err))
    return false
end

function ArmorSkinStateFirstPersonCount(State)
    if type(State) ~= "table" then return 0 end
    local Count = 0
    for _, Item in ipairs(State.Items or {}) do
        local Scope = string.lower(tostring(Item.Scope or ""))
        if string.find(Scope, "first-person", 1, true) == 1 then Count = Count + 1 end
    end
    return Count
end

function ArmorSkinScanSlots(Pawn)
    Pawn = Unwrap(Pawn)
    if not IsValidObject(Pawn) then return {}, nil, "pawn unavailable", nil end
    local Biped = ArmorSkinFindThirdPersonBiped(Pawn)
    local Slots = {}
    local Seen = {}
    local ThirdPersonSlots = 0
    local FirstPersonSlots = 0
    local ThirdPersonRoute = "biped-components"
    if IsValidObject(Biped) then
        for _, Component in ipairs(WarthogGetActorComponents(Biped) or {}) do
            ThirdPersonSlots = ThirdPersonSlots
                + ArmorSkinAppendMatchingSlots(Component, "third-person", Slots, Seen, false)
        end
    else
        -- First retain the stable RC3_31 direct pawn-component route.
        for ComponentIndex, Component in ipairs(WarthogGetActorComponents(Pawn) or {}) do
            if ComponentIndex > 128 then break end
            ThirdPersonSlots = ThirdPersonSlots
                + ArmorSkinAppendMatchingSlots(Component, "third-person-pawn-fallback", Slots, Seen, false)
        end
        if ThirdPersonSlots > 0 then
            Biped = Pawn
            ThirdPersonRoute = "pawn-components-fallback"
            Log("ARMORSKIN remote third-person pawn-component fallback pawn=%s slots=%d",
                tostring(SafeFullName(Pawn) or Pawn), ThirdPersonSlots)
        else
            -- RC3_36: exact BP_SpartansBipedActor assignment is now the only
            -- observer-side presentation route. The A15 live test proved this
            -- works. Do not scan hundreds of CVW components while the biped is
            -- still constructing; network retries + NotifyOnNewObject will reapply.
            local PendingKind = ArmorSkinLocalPlayerIndexForPawn(Pawn) ~= nil and "local" or "remote"
            return {}, nil, PendingKind .. " third-person Spartan biped pending", nil
        end
    end

    -- RC3_24: this discovery is deliberately independent of the reflected
    -- Pawn.FirstPersonArmsSkeletalMesh property. The RC3_23 live log reported
    -- arms=unavailable on every scan, which meant the old component fallback was
    -- never entered at all.
    local FirstPersonCandidates, FirstPersonRoute = ArmorSkinFirstPersonCandidates(Pawn)
    local ArmsKey = nil
    for CandidateIndex, RawCandidate in ipairs(FirstPersonCandidates) do
        if CandidateIndex > 8 then break end
        local Candidate = Unwrap(RawCandidate)
        if IsValidObject(Candidate) and not ArmorSkinObjectLooksLikeWeapon(Candidate) then
            ArmsKey = ArmsKey or ArmorSkinObjectKey(Candidate)
            FirstPersonSlots = FirstPersonSlots
                + ArmorSkinAppendMatchingSlots(Candidate, "first-person-root", Slots, Seen, true)

            for _, Name in ipairs({"AttachParent", "LeaderPoseComponent", "MasterPoseComponent"}) do
                local Value = nil
                pcall(function() Value = Unwrap(Candidate[Name]) end)
                if IsValidObject(Value) and not ArmorSkinObjectLooksLikeWeapon(Value) then
                    FirstPersonSlots = FirstPersonSlots
                        + ArmorSkinAppendMatchingSlots(Value, "first-person-pose", Slots, Seen, true)
                    for _, Component in ipairs(WarthogGetActorComponents(Value) or {}) do
                        local LowerComponent = string.lower(ArmorSkinObjectDescriptionForDetection(Component))
                        local LooksLikeArmsMesh = string.find(LowerComponent, "bpc_fp_skeletalmesh", 1, true) ~= nil
                            or string.find(LowerComponent, "firstpersonarms", 1, true) ~= nil
                            or string.find(LowerComponent, "arms", 1, true) ~= nil
                            or string.find(LowerComponent, "hand", 1, true) ~= nil
                        FirstPersonSlots = FirstPersonSlots
                            + ArmorSkinAppendMatchingSlots(Component, "first-person-pose-component", Slots, Seen, LooksLikeArmsMesh)
                    end
                end
            end

            -- AttachChildren can include the held weapon or a weapon-owned render
            -- component. RC3_27 descends one bounded level and inspects the child's
            -- owner/components too. Anything that looks like a weapon keeps the strict
            -- Chief/arms material-name gate so weapon skins cannot be recolored.
            local Children = nil
            pcall(function() Children = Candidate.AttachChildren end)
            for ChildIndex, ChildValue in ipairs(ArrayValues(Children)) do
                if ChildIndex > 20 then break end
                local Child = Unwrap(ChildValue)
                if IsValidObject(Child) then
                    local ChildWeapon = ArmorSkinObjectLooksLikeWeapon(Child)
                    if not ChildWeapon then
                        FirstPersonSlots = FirstPersonSlots
                            + ArmorSkinAppendMatchingSlots(Child, "first-person-child", Slots, Seen, false)
                    end
                    local Owner = nil
                    pcall(function() Owner = Unwrap(Child:GetOwner()) end)
                    if IsValidObject(Owner) then
                        for OwnerIndex, OwnerComponent in ipairs(WarthogGetActorComponents(Owner) or {}) do
                            if OwnerIndex > 64 then break end
                            local Desc = string.lower(ArmorSkinObjectDescriptionForDetection(OwnerComponent))
                            local LooksArm = string.find(Desc, "arm", 1, true) ~= nil
                                or string.find(Desc, "hand", 1, true) ~= nil
                                or string.find(Desc, "glove", 1, true) ~= nil
                                or string.find(Desc, "chief", 1, true) ~= nil
                                or string.find(Desc, "spartan", 1, true) ~= nil
                            FirstPersonSlots = FirstPersonSlots
                                + ArmorSkinAppendMatchingSlots(OwnerComponent, "first-person-attached-owner", Slots, Seen, LooksArm)
                        end
                    end
                end
            end

            -- Also inspect owner-only / FP-marked pawn render components with the
            -- strict material-name gate. This catches builds where the visible arms
            -- are a sibling render component rather than the BPC_FP wrapper itself.
            for ComponentIndex, RawComponent in ipairs(WarthogGetActorComponents(Pawn) or {}) do
                if ComponentIndex > 96 then break end
                local Component = Unwrap(RawComponent)
                if IsValidObject(Component) and not ArmorSkinObjectLooksLikeWeapon(Component) then
                    local Desc = string.lower(ArmorSkinObjectDescriptionForDetection(Component))
                    local OnlyOwner = false
                    pcall(function() OnlyOwner = Component.bOnlyOwnerSee == true end)
                    local LooksFp = OnlyOwner or string.find(Desc, "firstperson", 1, true) ~= nil
                        or string.find(Desc, "bpc_fp_", 1, true) ~= nil
                    if LooksFp then
                        FirstPersonSlots = FirstPersonSlots
                            + ArmorSkinAppendMatchingSlots(Component, "first-person-sibling", Slots, Seen, false)
                    end
                end
            end
        end
    end

    Log("ARMORSKIN slot scan thirdPerson=%d firstPerson=%d total=%d arms=%s route=%s candidates=%d thirdRoute=%s",
        ThirdPersonSlots, FirstPersonSlots, #Slots, tostring(ArmsKey or "unavailable"),
        tostring(FirstPersonRoute or "unavailable"), #FirstPersonCandidates, tostring(ThirdPersonRoute))
    local ScanInfo = {
        ThirdPersonSlots = ThirdPersonSlots,
        ThirdPersonRoute = ThirdPersonRoute,
        FirstPersonSlots = FirstPersonSlots,
        FirstPersonArmsKey = ArmsKey,
        FirstPersonCandidateCount = #FirstPersonCandidates,
        FirstPersonRoute = FirstPersonRoute,
    }
    if #Slots == 0 then return {}, Biped, "default Chief armor/arms material slots unavailable", ScanInfo end
    return Slots, Biped, nil, ScanInfo
end

function ArmorSkinRestoreTarget(TargetKey, Reason)
    local State = ArmorSkinAppliedByTarget[TargetKey]
    if type(State) ~= "table" then return true end
    -- V12: network-local Classic state intentionally retains no component UObjects.
    -- Never attempt restore through old V11 network refs across respawn/model swaps.
    if State.NetworkLocalTPStateless == true or State.NetworkLocalTPOnly == true then
        ArmorSkinAppliedByTarget[TargetKey] = nil
        Log("CLASSIC18V12 NET STATE DROP target=%s reason=%s no-cached-component-restore",
            tostring(TargetKey), tostring(Reason or "model/lifecycle"))
        return true
    end
    local Restored, Failed = 0, 0
    for _, Item in ipairs(State.Items or {}) do
        if IsValidObject(Item.Component) and IsValidObject(Item.OriginalMaterial) then
            local Ok = pcall(function() Item.Component:SetMaterial(Item.Slot, Item.OriginalMaterial) end)
            if Ok then
                Restored = Restored + 1
            else
                Failed = Failed + 1
            end
        end
    end
    ArmorSkinAppliedByTarget[TargetKey] = nil
    Log("ARMORSKIN restore target=%s reason=%s restored=%d failed=%d",
        tostring(TargetKey), tostring(Reason or "original"), Restored, Failed)
    return Failed == 0
end

function ArmorSkinDropAllRuntimeRefs(Reason)
    if ArmorSkinCancelSlicedJobs ~= nil then ArmorSkinCancelSlicedJobs(Reason or "runtime refs dropped") end
    ArmorSkinAppliedByTarget = {}
    ArmorSkinFirstPersonRetryByTarget = {}
    ArmorSkinPerspectiveRebindToken = { [1] = 0, [2] = 0 }
    ArmorSkinLocalSettledToken = { [1] = 0, [2] = 0 }
    ArmorSkinLocalReassertToken = { [1] = (tonumber(ArmorSkinLocalReassertToken[1]) or 0)+1, [2] = (tonumber(ArmorSkinLocalReassertToken[2]) or 0)+1 }
    Log("ARMORSKIN runtime MID refs dropped: %s", tostring(Reason or "world boundary"))
end

function ArmorSkinCancelSlicedJobs(Reason)
    ArmorSkinSlicedPumpToken=(tonumber(ArmorSkinSlicedPumpToken) or 0)+1
    ArmorSkinSlicedJobsByTarget={}
    ArmorSkinSlicedJobOrder={}
    ArmorSkinSlicedPumpScheduled=false
    Log("ARMORSKIN sliced jobs cancelled: %s",tostring(Reason or "lifecycle boundary"))
end

function ArmorSkinDropTargetRuntimeRefs(TargetKey, Reason)
    if TargetKey==nil then return end
    ArmorSkinAppliedByTarget[TargetKey]=nil
    ArmorSkinFirstPersonRetryByTarget[TargetKey]=nil
    local J=ArmorSkinSlicedJobsByTarget[TargetKey]
    if type(J)=="table" then ArmorSkinSlicedJobsByTarget[TargetKey]=nil end
    Log("ARMORSKIN target runtime refs dropped target=%s reason=%s",tostring(TargetKey),tostring(Reason or "rebind"))
end

function ArmorSkinItemMIDIsBound(Item)
    if type(Item)~="table" or not IsValidObject(Item.Component) or not IsValidObject(Item.MID) then return false end
    local Current=nil
    pcall(function() Current=Unwrap(Item.Component:GetMaterial(Item.Slot)) end)
    if not IsValidObject(Current) then return false end
    return ArmorSkinSameObject(Current,Item.MID)
end

-- RC3_59 shared palette -------------------------------------------------------
-- A component-owned MID dies with the old respawn mesh.  Creating/configuring a
-- new MID for every one of 20/38 slots is the source of the visible hitching.
-- Build one MID per (stock source material, TP/FP scope, CE color) with WORLD as
-- its outer, then reuse that material interface across every compatible slot and
-- every respawn in the current world.  Respawn/recolor becomes SetMaterial only.
function ArmorSkinPaletteScopeKey(Item)
    local Scope=string.lower(tostring(type(Item)=="table" and Item.Scope or ""))
    if string.find(Scope,"first-person",1,true)==1 then return "FP" end
    return "TP"
end

function ArmorSkinPaletteCanonicalSource(Material)
    Material=Unwrap(Material)
    if not IsValidObject(Material) then return nil end
    local K=ArmorSkinObjectKey(Material)
    local Source=K and ArmorSkinPaletteSourceByMIDKey[K] or nil
    Source=Unwrap(Source)
    if IsValidObject(Source) then return Source end
    return Material
end

function ArmorSkinPaletteReset(Reason)
    ArmorSkinPaletteMIDByKey={}
    ArmorSkinPlayerMIDByKey={}
    ArmorSkinPaletteSourceByMIDKey={}
    ArmorSkinPaletteLibraryCache=nil
    ArmorSkinPaletteCreatedCount=0
    ArmorSkinPlayerMIDCreatedCount=0
    ArmorSkinPlayerMIDPrewarmToken=(tonumber(ArmorSkinPlayerMIDPrewarmToken) or 0)+1
    ArmorSkinPlayerMIDPrewarmGeneration=-1
    Log("ARMORSKIN shared/player material cache reset: %s",tostring(Reason or "world boundary"))
end

function ArmorSkinPaletteLibrary()
    local L=Unwrap(ArmorSkinPaletteLibraryCache)
    if IsValidObject(L) then return L end
    pcall(function() L=Unwrap(StaticFindObject("/Script/Engine.Default__KismetMaterialLibrary")) end)
    if IsValidObject(L) then ArmorSkinPaletteLibraryCache=L; return L end
    return nil
end

function ArmorSkinCreateWorldPaletteMID(SourceMaterial,ScopeKey,ColorIndex,Texture)
    SourceMaterial=ArmorSkinPaletteCanonicalSource(SourceMaterial)
    Texture=Unwrap(Texture)
    if not IsValidObject(SourceMaterial) or not IsValidObject(Texture) then return nil,0,"invalid source/texture" end
    local Library=ArmorSkinPaletteLibrary()
    local Context=nil
    pcall(function() Context=Unwrap(UEHelpers.GetWorldContextObject()) end)
    if not IsValidObject(Library) or not IsValidObject(Context) then return nil,0,"KismetMaterialLibrary/world unavailable" end
    ArmorSkinPaletteSerial=(tonumber(ArmorSkinPaletteSerial) or 0)+1
    local Name=FName(string.format("HCEArmorPalette_%s_%02d_%d",tostring(ScopeKey),tonumber(ColorIndex) or 0,ArmorSkinPaletteSerial))
    local MID=nil
    local LastErr="CreateDynamicMaterialInstance failed"
    local Ok,Err=pcall(function()
        MID=Unwrap(Library:CreateDynamicMaterialInstance(Context,SourceMaterial,Name,0))
    end)
    if not Ok or not IsValidObject(MID) then
        LastErr=tostring(Err or LastErr)
        Ok,Err=pcall(function()
            MID=Unwrap(Library:CreateDynamicMaterialInstance(Context,SourceMaterial,Name))
        end)
        if not Ok then LastErr=tostring(Err or LastErr) end
    end
    if not IsValidObject(MID) then return nil,0,LastErr end

    local Count=0
    if tostring(ScopeKey)=="FP" then
        local Diffuse=ArmorSkinFindDiffuseParams(SourceMaterial) or {}
        local TP,VP=ArmorSkinCollectFirstPersonParams(SourceMaterial)
        local Good,A,B,C=ArmorSkinSetFirstPersonOverrides(MID,Diffuse,TP,VP,Texture,ColorIndex)
        Count=(tonumber(A) or 0)+(tonumber(B) or 0)+(tonumber(C) or 0)
        if not Good then return nil,Count,"FP palette parameter setup failed" end
    else
        local Params=ArmorSkinFindDiffuseParams(SourceMaterial)
        if Params==nil or #Params<=0 then return nil,0,"no diffuse params" end
        local Good,N=ArmorSkinSetTextureOnMID(MID,Params,Texture)
        Count=tonumber(N) or 0
        if not Good then return nil,Count,"TP palette parameter setup failed" end
    end
    ArmorSkinPaletteCreatedCount=(tonumber(ArmorSkinPaletteCreatedCount) or 0)+1
    local MK=ArmorSkinObjectKey(MID)
    if MK~=nil then ArmorSkinPaletteSourceByMIDKey[MK]=SourceMaterial end
    Log("ARMORSKIN shared palette CREATED #%d scope=%s color=%s parent=%s parameterSets=%d",
        tonumber(ArmorSkinPaletteCreatedCount) or 0,tostring(ScopeKey),ArmorSkinColorLabel(ColorIndex),
        tostring(SafeFullName(SourceMaterial) or SourceMaterial),Count)
    return MID,Count,nil
end

function ArmorSkinPaletteMIDForItem(Item,ColorIndex,Texture)
    if type(Item)~="table" then return nil,0,false,"invalid item" end
    local Source=ArmorSkinPaletteCanonicalSource(Item.OriginalMaterial)
    if not IsValidObject(Source) then return nil,0,false,"invalid original material" end
    Item.OriginalMaterial=Source
    local ScopeKey=ArmorSkinPaletteScopeKey(Item)
    local SourceKey=ArmorSkinObjectKey(Source) or tostring(SafeFullName(Source) or Source)
    local Key=string.format("%s|%s|%d",tostring(SourceKey),tostring(ScopeKey),tonumber(ColorIndex) or 0)
    local Entry=ArmorSkinPaletteMIDByKey[Key]
    if type(Entry)=="table" and IsValidObject(Unwrap(Entry.MID)) then
        return Unwrap(Entry.MID),0,false,nil
    end
    local MID,Count,Err=ArmorSkinCreateWorldPaletteMID(Source,ScopeKey,ColorIndex,Texture)
    if not IsValidObject(MID) then return nil,tonumber(Count) or 0,false,Err end
    ArmorSkinPaletteMIDByKey[Key]={MID=MID,SourceMaterial=Source,ScopeKey=ScopeKey,ColorIndex=tonumber(ColorIndex) or 0}
    return MID,tonumber(Count) or 0,true,nil
end

-- RC3_60 mutable per-player shared materials ---------------------------------
-- A color palette per color still requires SetMaterial on every slot whenever
-- the color changes. Instead, keep one MID per (PlayerId, source material, TP/FP)
-- and leave every compatible slot permanently bound to it for the life of the
-- current biped. Recolor then changes parameters on only 2-3 MIDs total.
function ArmorSkinPlayerMIDKey(PlayerId,SourceMaterial,ScopeKey)
    local Pid=tonumber(PlayerId)
    SourceMaterial=ArmorSkinPaletteCanonicalSource(SourceMaterial)
    if Pid==nil or not IsValidObject(SourceMaterial) then return nil end
    local SourceKey=ArmorSkinObjectKey(SourceMaterial) or tostring(SafeFullName(SourceMaterial) or SourceMaterial)
    return string.format("P:%d|%s|%s",math.floor(Pid),tostring(SourceKey),tostring(ScopeKey or "TP"))
end

function ArmorSkinConfigurePlayerSharedMID(MID,SourceMaterial,ScopeKey,ColorIndex,Texture)
    MID=Unwrap(MID); SourceMaterial=ArmorSkinPaletteCanonicalSource(SourceMaterial); Texture=Unwrap(Texture)
    if not IsValidObject(MID) or not IsValidObject(SourceMaterial) or not IsValidObject(Texture) then return false,0 end
    if tostring(ScopeKey)=="FP" then
        local Diffuse=ArmorSkinFindDiffuseParams(SourceMaterial) or {}
        local TP,VP=ArmorSkinCollectFirstPersonParams(SourceMaterial)
        local Good,A,B,C=ArmorSkinSetFirstPersonOverrides(MID,Diffuse,TP,VP,Texture,ColorIndex)
        return Good,(tonumber(A) or 0)+(tonumber(B) or 0)+(tonumber(C) or 0)
    end
    local Params=ArmorSkinFindDiffuseParams(SourceMaterial)
    if Params==nil or #Params<=0 then return false,0 end
    return ArmorSkinSetTextureOnMID(MID,Params,Texture)
end

function ArmorSkinPlayerSharedMIDForItem(Item,PlayerId,ColorIndex,Texture)
    if type(Item)~="table" then return nil,0,false,"invalid item" end
    local Source=ArmorSkinPaletteCanonicalSource(Item.OriginalMaterial)
    if not IsValidObject(Source) then return nil,0,false,"invalid original material" end
    local ScopeKey=ArmorSkinPaletteScopeKey(Item)
    local Key=ArmorSkinPlayerMIDKey(PlayerId,Source,ScopeKey)
    if Key==nil then return nil,0,false,"invalid player id" end
    local Entry=ArmorSkinPlayerMIDByKey[Key]
    local MID=type(Entry)=="table" and Unwrap(Entry.MID) or nil
    if IsValidObject(MID) then
        local Sets=0
        if tonumber(Entry.ColorIndex)~=tonumber(ColorIndex) then
            local Good,N=ArmorSkinConfigurePlayerSharedMID(MID,Source,ScopeKey,ColorIndex,Texture)
            if not Good then return nil,tonumber(N) or 0,false,"shared MID recolor failed" end
            Entry.ColorIndex=tonumber(ColorIndex) or 0
            Sets=tonumber(N) or 0
        end
        return MID,Sets,false,nil
    end
    -- RC3_62: use Unreal's normal world/Kismet MID creation path. Do not manually
    -- construct a MaterialInstanceDynamic under GameInstance; that RC3_61 experiment
    -- correlated with both untouched default Spartans turning gray before any skin bind.
    local NewMID,Sets,Err=ArmorSkinCreateWorldPaletteMID(Source,ScopeKey,ColorIndex,Texture)
    if not IsValidObject(NewMID) then return nil,tonumber(Sets) or 0,false,Err end
    ArmorSkinPlayerMIDCreatedCount=(tonumber(ArmorSkinPlayerMIDCreatedCount) or 0)+1
    ArmorSkinPlayerMIDByKey[Key]={MID=NewMID,SourceMaterial=Source,ScopeKey=ScopeKey,
        PlayerId=tonumber(PlayerId),ColorIndex=tonumber(ColorIndex) or 0}
    Log("ARMORSKIN player material CREATED #%d playerId=%s scope=%s color=%s parent=%s parameterSets=%d",
        tonumber(ArmorSkinPlayerMIDCreatedCount) or 0,tostring(PlayerId),tostring(ScopeKey),ArmorSkinColorLabel(ColorIndex),
        tostring(SafeFullName(Source) or Source),tonumber(Sets) or 0)
    return NewMID,tonumber(Sets) or 0,true,nil
end

function ArmorSkinApplySharedPlayerColor(State,PlayerId,ColorIndex,Texture,Source)
    if type(State)~="table" or #(State.Items or {})<=0 then return false,"no verified items" end
    local Seen,Unique,Sets={},0,0
    for _,Item in ipairs(State.Items or {}) do
        local SourceMat=ArmorSkinPaletteCanonicalSource(Item.OriginalMaterial)
        local ScopeKey=ArmorSkinPaletteScopeKey(Item)
        local K=ArmorSkinPlayerMIDKey(PlayerId,SourceMat,ScopeKey)
        if K~=nil and not Seen[K] then
            Seen[K]=true
            local MID,N,Created,Err=ArmorSkinPlayerSharedMIDForItem(Item,PlayerId,ColorIndex,Texture)
            if not IsValidObject(MID) then return false,tostring(Err or "shared player MID unavailable") end
            Unique=Unique+1; Sets=Sets+(tonumber(N) or 0)
        end
    end
    -- Every slot is already bound to these exact mutable MIDs. No GetMaterial,
    -- SetMaterial or per-slot work is needed for a normal same-biped recolor.
    State.ColorIndex=tonumber(ColorIndex) or State.ColorIndex
    ArmorSkinAppliedByTarget[ArmorSkinTargetKey(PlayerId,State.PlayerIndex)]=State
    Log("ARMORSKIN shared-player recolor playerId=%s color=%s uniqueMIDs=%d parameterSets=%d source=%s",
        tostring(PlayerId),ArmorSkinColorLabel(ColorIndex),Unique,Sets,tostring(Source or "cycle"))
    return Unique>0,string.format("shared-player recolor mids=%d sets=%d",Unique,Sets)
end

function ArmorSkinForceReassertPlayerState(State,PlayerId,ColorIndex,Texture,Source)
    if type(State)~="table" or #(State.Items or {})<=0 then return false,0,0,"state unavailable" end
    local Seen,Unique,Sets={},0,0
    for _,Item in ipairs(State.Items or {}) do
        local SourceMat=ArmorSkinPaletteCanonicalSource(Item.OriginalMaterial)
        local ScopeKey=ArmorSkinPaletteScopeKey(Item)
        local K=ArmorSkinPlayerMIDKey(PlayerId,SourceMat,ScopeKey)
        if K~=nil and not Seen[K] then
            Seen[K]=true
            local Entry=ArmorSkinPlayerMIDByKey[K]
            local MID=type(Entry)=="table" and Unwrap(Entry.MID) or nil
            if not IsValidObject(MID) then
                MID=select(1,ArmorSkinPlayerSharedMIDForItem(Item,PlayerId,ColorIndex,Texture))
                Entry=ArmorSkinPlayerMIDByKey[K]
            end
            if not IsValidObject(MID) then return false,Unique,Sets,"shared MID unavailable" end
            local Good,N=ArmorSkinConfigurePlayerSharedMID(MID,SourceMat,ScopeKey,ColorIndex,Texture)
            if not Good then return false,Unique,Sets,"shared MID reassert failed" end
            if type(Entry)=="table" then Entry.ColorIndex=tonumber(ColorIndex) or Entry.ColorIndex end
            Unique=Unique+1; Sets=Sets+(tonumber(N) or 0)
        end
    end
    Log("ARMORSKIN shared-player FORCE REASSERT playerId=%s color=%s uniqueMIDs=%d parameterSets=%d source=%s",
        tostring(PlayerId),ArmorSkinColorLabel(ColorIndex),Unique,Sets,tostring(Source or "lifecycle"))
    return Unique>0,Unique,Sets,nil
end

function ArmorSkinRebindDetachedStateItems(State,Source)
    if type(State)~="table" then return 0,0 end
    local Detached,Rebound=0,0
    for _,Item in ipairs(State.Items or {}) do
        if IsValidObject(Item.Component) and IsValidObject(Item.MID) and not ArmorSkinItemMIDIsBound(Item) then
            Detached=Detached+1
            local Ok=pcall(function() Item.Component:SetMaterial(Item.Slot,Item.MID) end)
            if Ok then Rebound=Rebound+1 end
        end
    end
    if Detached>0 then
        Log("ARMORSKIN lifecycle binding LATCH detached=%d rebound=%d source=%s",Detached,Rebound,tostring(Source or "lifecycle"))
    end
    return Detached,Rebound
end

function ArmorSkinScheduleLocalStateReassert(PlayerIndex,TargetKey,BipedKey,PlayerId,ColorIndex,Source)
    PlayerIndex=tonumber(PlayerIndex)
    if PlayerIndex~=1 and PlayerIndex~=2 then return end
    ArmorSkinLocalReassertToken[PlayerIndex]=(tonumber(ArmorSkinLocalReassertToken[PlayerIndex]) or 0)+1
    local Token=ArmorSkinLocalReassertToken[PlayerIndex]
    local Generation=tonumber(WarthogColorRuntimeGeneration) or 0
    for _,Delay in ipairs({700,2400}) do
        ExecuteInGameThreadWithDelay(Delay,function()
            if Token~=ArmorSkinLocalReassertToken[PlayerIndex] or ModTeardownGuard or not MissionReady
                or (tonumber(WarthogColorRuntimeGeneration) or 0)~=Generation then return end
            local State=ArmorSkinAppliedByTarget[TargetKey]
            if type(State)~="table" or tostring(State.BipedKey or "")~=tostring(BipedKey or "")
                or tonumber(State.ColorIndex)~=tonumber(ColorIndex) then return end
            local Texture=ArmorSkinLoadTexture(ColorIndex)
            if not IsValidObject(Texture) then return end
            local Detached,Rebound=ArmorSkinRebindDetachedStateItems(State,string.format("P%d +%dms %s",PlayerIndex,Delay,tostring(Source or "reassert")))
            local Ok,Unique,Sets=ArmorSkinForceReassertPlayerState(State,PlayerId,ColorIndex,Texture,
                string.format("P%d +%dms %s",PlayerIndex,Delay,tostring(Source or "reassert")))
            Log("ARMORSKIN local lifecycle REASSERT P%d delay=%dms detached=%d rebound=%d uniqueMIDs=%d parameterSets=%d ok=%s",
                PlayerIndex,Delay,tonumber(Detached) or 0,tonumber(Rebound) or 0,tonumber(Unique) or 0,tonumber(Sets) or 0,tostring(Ok==true))
        end)
    end
end

function ArmorSkinFindKnownStockMaterial(Path)
    local M=nil
    pcall(function() M=Unwrap(StaticFindObject(Path)) end)
    if not IsValidObject(M) then pcall(function() M=Unwrap(LoadAsset(Path)) end) end
    if not IsValidObject(M) then
        local Package=string.match(tostring(Path or ""),"^([^%.]+)")
        if Package and Package~="" then pcall(function() M=Unwrap(LoadAsset(Package)) end) end
    end
    if not IsValidObject(M) then pcall(function() M=Unwrap(StaticFindObject(Path)) end) end
    return IsValidObject(M) and M or nil
end

function ArmorSkinPrewarmPlayerMIDSet(PlayerId,Source,SeedColorIndex)
    PlayerId=tonumber(PlayerId)
    if PlayerId==nil then return 0,0 end
    local Seed=tonumber(SeedColorIndex) or 1
    if Seed<1 or Seed>#WarthogCEColors then Seed=1 end
    local Texture=ArmorSkinLoadTexture(Seed) -- all 18 textures are already process-prewarmed in frontend.
    if not IsValidObject(Texture) then return 0,3 end
    local Base=ArmorSkinFindKnownStockMaterial("/Game/Characters/Spartans/Default/Materials/MI_Chief_Armor.MI_Chief_Armor")
    local Masked=ArmorSkinFindKnownStockMaterial("/Game/Characters/Spartans/Default/Materials/MI_Chief_Armor_Masked.MI_Chief_Armor_Masked")
    local Combos={}
    if IsValidObject(Base) then
        Combos[#Combos+1]={OriginalMaterial=Base,Scope="third-person prewarm"}
        Combos[#Combos+1]={OriginalMaterial=Base,Scope="first-person prewarm"}
    end
    if IsValidObject(Masked) then Combos[#Combos+1]={OriginalMaterial=Masked,Scope="third-person masked prewarm"} end
    local Ready,Failed=0,0
    for _,Item in ipairs(Combos) do
        local MID,_,_,Err=ArmorSkinPlayerSharedMIDForItem(Item,PlayerId,Seed,Texture)
        if IsValidObject(MID) then Ready=Ready+1 else Failed=Failed+1; Log("ARMORSKIN player material PREWARM miss playerId=%s reason=%s",tostring(PlayerId),tostring(Err)) end
    end
    Log("ARMORSKIN player material PREWARM playerId=%s seed=%s ready=%d failed=%d source=%s",tostring(PlayerId),ArmorSkinColorLabel(Seed),Ready,Failed,tostring(Source or "mission load"))
    return Ready,Failed
end

-- RC3_63 crash fix: material prewarm must never enumerate GameState.PlayerArray.
-- The RC3_62 WinGDK crash dump is an access violation inside UE4SS.dll while
-- ArrayValues() recursively calls Value:get() on a PlayerArray element. Lua pcall
-- cannot catch that native invalid-pointer read. Prewarm therefore uses only
-- explicit local controllers plus already-known numeric PlayerIds stored in Lua.
function ArmorSkinPrewarmSafeKnownIds(Source)
    if ModTeardownGuard or not MissionReady then return false end
    local Seen,Players,Ready,Failed={},0,0,0
    local function SeedFor(Pid,LocalIndex)
        local Key=tostring(math.floor(Pid))
        local Seed=tonumber(ArmorSkinNetworkColorByPlayerId[Key])
        if (Seed==nil or Seed<=0) and tonumber(LocalIndex)~=nil then
            Seed=tonumber(ArmorSkinLocalIndexByPlayer[tonumber(LocalIndex)])
        end
        if Seed==nil or Seed<=0 then Seed=tonumber(ArmorSkinPersistentRemoteColorByPlayerId[Key]) end
        if Seed==nil or Seed<=0 then Seed=1 end
        return Seed
    end
    local function Add(Pid,LocalIndex,Why)
        Pid=tonumber(Pid)
        if Pid==nil then return end
        Pid=math.floor(Pid)
        if Seen[Pid] then return end
        Seen[Pid]=true; Players=Players+1
        local Seed=SeedFor(Pid,LocalIndex)
        local A,B=ArmorSkinPrewarmPlayerMIDSet(Pid,
            string.format("%s [%s]",tostring(Source or "mission load"),tostring(Why or "known-id")),Seed)
        Ready=Ready+(tonumber(A) or 0); Failed=Failed+(tonumber(B) or 0)
    end

    -- Explicit local slots only; do not cross into GameState.PlayerArray here.
    for I=1,2 do
        local C=Unwrap(GetPlayer(I))
        if IsValidObject(C) then Add(ArmorSkinPlayerIdFromController(C),I,"local-P"..tostring(I)) end
    end

    -- Numeric identities learned earlier by the network protocol are plain Lua
    -- table keys and are safe to prewarm without touching live remote UObjects.
    for K,_ in pairs(ArmorSkinNetworkColorByPlayerId or {}) do Add(tonumber(K),nil,"network-cache") end
    for K,_ in pairs(ArmorSkinPersistentRemoteColorByPlayerId or {}) do Add(tonumber(K),nil,"persistent-remote") end
    for K,_ in pairs(ArmorSkinNetworkOriginSlotByPlayerId or {}) do Add(tonumber(K),nil,"origin-slot-cache") end

    Log("ARMORSKIN SAFE-ID PREWARM COMPLETE players=%d materials=%d failed=%d source=%s",
        Players,Ready,Failed,tostring(Source or "mission load"))
    return Players>0 and Failed==0
end

function ArmorSkinSchedulePlayerMIDPrewarm(Source)
    ArmorSkinPlayerMIDPrewarmToken=(tonumber(ArmorSkinPlayerMIDPrewarmToken) or 0)+1
    local Token=ArmorSkinPlayerMIDPrewarmToken
    local G=tonumber(WarthogColorRuntimeGeneration) or 0
    ArmorSkinPlayerMIDPrewarmGeneration=G
    ArmorSkinPrewarmSafeKnownIds(tostring(Source or "mission load") .. " immediate")
    ExecuteInGameThreadWithDelay(450,function()
        if Token~=ArmorSkinPlayerMIDPrewarmToken or ModTeardownGuard or not MissionReady then return end
        if (tonumber(WarthogColorRuntimeGeneration) or 0)~=G then return end
        ArmorSkinPrewarmSafeKnownIds(tostring(Source or "mission load") .. " +450ms")
    end)
end

function ArmorSkinApplyColorLegacyToExistingItem(Item,Texture,ColorIndex,ForceBind)
    if type(Item)~="table" or not IsValidObject(Item.Component) or not IsValidObject(Item.MID) or not IsValidObject(Texture) then
        return false,0,false
    end
    local ScopeLower=string.lower(tostring(Item.Scope or ""))
    local IsFirstPerson=string.find(ScopeLower,"first-person",1,true)==1
    local Good,Count=false,0
    if IsFirstPerson then
        local TSet,NSet,VSet=0,0,0
        Good,TSet,NSet,VSet=ArmorSkinSetFirstPersonOverrides(Item.MID,Item.Params,
            Item.FPTextureParams,Item.FPVectorParams,Texture,ColorIndex)
        Count=(tonumber(TSet) or 0)+(tonumber(NSet) or 0)+(tonumber(VSet) or 0)
    else
        Good,Count=ArmorSkinSetTextureOnMID(Item.MID,Item.Params,Texture)
    end
    if not Good then return false,tonumber(Count) or 0,false end
    local WasBound=ArmorSkinItemMIDIsBound(Item)
    local BindOk=true
    if ForceBind==true or not WasBound then
        BindOk=pcall(function() Item.Component:SetMaterial(Item.Slot,Item.MID) end)
    end
    return BindOk,tonumber(Count) or 0,not WasBound
end

function ArmorSkinApplyColorToExistingItem(Item,Texture,ColorIndex,ForceBind,PlayerId)
    if type(Item)~="table" or not IsValidObject(Item.Component) or not IsValidObject(Texture) then
        return false,0,false
    end
    local SharedMID,SetupCount,Created,SharedErr=ArmorSkinPlayerSharedMIDForItem(Item,PlayerId,ColorIndex,Texture)
    if IsValidObject(SharedMID) then
        Item.MID=SharedMID
        local WasBound=ArmorSkinItemMIDIsBound(Item)
        local BindOk=true
        if ForceBind==true or not WasBound then
            BindOk=pcall(function() Item.Component:SetMaterial(Item.Slot,SharedMID) end)
        end
        return BindOk,tonumber(SetupCount) or 0,not WasBound
    end
    -- Conservative fallback: retain RC3_59 immutable palette path if the new
    -- per-player shared MID path cannot be built on a specific game build.
    local PaletteMID,PaletteCount,_,PaletteErr=ArmorSkinPaletteMIDForItem(Item,ColorIndex,Texture)
    if IsValidObject(PaletteMID) then
        Item.MID=PaletteMID
        local WasBound=ArmorSkinItemMIDIsBound(Item)
        local BindOk=true
        if ForceBind==true or not WasBound then BindOk=pcall(function() Item.Component:SetMaterial(Item.Slot,PaletteMID) end) end
        Log("ARMORSKIN player-MID FALLBACK palette scope=%s color=%s reason=%s",ArmorSkinPaletteScopeKey(Item),ArmorSkinColorLabel(ColorIndex),tostring(SharedErr or "unknown"))
        return BindOk,tonumber(PaletteCount) or 0,not WasBound
    end
    if IsValidObject(Item.MID) then
        Log("ARMORSKIN player-MID FALLBACK legacy scope=%s color=%s reason=%s / %s",
            ArmorSkinPaletteScopeKey(Item),ArmorSkinColorLabel(ColorIndex),tostring(SharedErr or "unknown"),tostring(PaletteErr or "unknown"))
        return ArmorSkinApplyColorLegacyToExistingItem(Item,Texture,ColorIndex,ForceBind)
    end
    return false,(tonumber(SetupCount) or 0)+(tonumber(PaletteCount) or 0),false
end

function ArmorSkinFinishSlicedJob(Job)
    if type(Job)~="table" then return end
    local TargetKey=Job.TargetKey
    if Job.Mode=="update" then
        local State=Job.ExistingState
        if type(State)~="table" or #(State.Items or {})<=0 then
            ArmorSkinSlicedJobsByTarget[TargetKey]=nil
            Log("ARMORSKIN sliced update FAILED target=%s playerId=%s color=%s reason=state-lost source=%s",
                tostring(TargetKey),tostring(Job.PlayerId),ArmorSkinColorLabel(Job.ColorIndex),tostring(Job.Source))
            return
        end
        State.ColorIndex=Job.ColorIndex
        State.Biped=Job.Biped; State.BipedKey=Job.BipedKey
        State.Pawn=Job.Pawn; State.PawnKey=Job.PawnKey
        ArmorSkinAppliedByTarget[TargetKey]=State
        ArmorSkinSlicedJobsByTarget[TargetKey]=nil
        Log("ARMORSKIN palette bind UPDATE COMPLETE target=%s playerId=%s color=%s slots=%d applied=%d rebound=%d failed=%d textureSets=%d source=%s",
            tostring(TargetKey),tostring(Job.PlayerId),ArmorSkinColorLabel(Job.ColorIndex),#(Job.Slots or {}),
            tonumber(Job.Applied) or 0,tonumber(Job.Rebound) or 0,tonumber(Job.Failed) or 0,tonumber(Job.TextureSets) or 0,tostring(Job.Source))
        return
    end

    if (tonumber(Job.Applied) or 0)<=0 then
        ArmorSkinSlicedJobsByTarget[TargetKey]=nil
        Log("ARMORSKIN sliced rebuild FAILED target=%s playerId=%s color=%s failures=%d source=%s",
            tostring(TargetKey),tostring(Job.PlayerId),ArmorSkinColorLabel(Job.ColorIndex),
            tonumber(Job.Failed) or 0,tostring(Job.Source))
        return
    end
    ArmorSkinAppliedByTarget[TargetKey]={
        Biped=Job.Biped,BipedKey=Job.BipedKey,Pawn=Job.Pawn,PawnKey=Job.PawnKey,
        PlayerId=Job.PlayerId,PlayerIndex=Job.PlayerIndex,ColorIndex=Job.ColorIndex,
        Items=Job.Items,
        FirstPersonArmsKey=Job.ScanInfo and Job.ScanInfo.FirstPersonArmsKey or Job.CurrentArmsKey,
        FirstPersonSlotCount=Job.ScanInfo and tonumber(Job.ScanInfo.FirstPersonSlots) or 0,
        FirstPersonCandidateCount=Job.ScanInfo and tonumber(Job.ScanInfo.FirstPersonCandidateCount) or 0,
        FirstPersonRoute=Job.ScanInfo and Job.ScanInfo.FirstPersonRoute or Job.CurrentArmsRoute,
    }
    ArmorSkinSlicedJobsByTarget[TargetKey]=nil
    local State=ArmorSkinAppliedByTarget[TargetKey]
    if ArmorSkinStateFirstPersonCount(State)>0 then ArmorSkinFirstPersonRetryByTarget[TargetKey]=nil end
    -- RC3_62 retains the RC3_61 finding: a local respawn/customization pass can mutate the parameters of a
    -- still-bound shared MID back toward authored green. Binding equality alone
    -- is therefore insufficient. Reassert each unique shared MID once after every
    -- lifecycle rebuild, then repeat twice for local players without rescanning.
    local ReassertTexture=Job.Texture
    if IsValidObject(ReassertTexture) then
        ArmorSkinForceReassertPlayerState(State,Job.PlayerId,Job.ColorIndex,ReassertTexture,"post-build lifecycle")
    end
    if tonumber(Job.PlayerIndex)==1 or tonumber(Job.PlayerIndex)==2 then
        ArmorSkinScheduleLocalStateReassert(Job.PlayerIndex,TargetKey,Job.BipedKey,Job.PlayerId,Job.ColorIndex,"post-build lifecycle")
    end
    Log("ARMORSKIN palette bind VERIFIED target=%s playerId=%s color=%s slots=%d applied=%d rebound=%d verifyPasses=%d failed=%d textureSets=%d source=%s",
        tostring(TargetKey),tostring(Job.PlayerId),ArmorSkinColorLabel(Job.ColorIndex),#(Job.Slots or {}),
        tonumber(Job.Applied) or 0,tonumber(Job.Rebound) or 0,tonumber(Job.VerifyPass) or 0,
        tonumber(Job.Failed) or 0,tonumber(Job.TextureSets) or 0,tostring(Job.Source))
end

function ArmorSkinProcessOneSlicedSlot(Job)
    if type(Job)~="table" then return false end

    if Job.Mode=="update" then
        local I=tonumber(Job.NextIndex) or 1
        local Item=Job.Slots and Job.Slots[I] or nil
        if Item==nil then ArmorSkinFinishSlicedJob(Job); return false end
        Job.NextIndex=I+1
        local Ok,Count,WasDetached=ArmorSkinApplyColorToExistingItem(Item,Job.Texture,Job.ColorIndex,false,Job.PlayerId)
        if Ok then
            Job.Applied=(tonumber(Job.Applied) or 0)+1
            Job.TextureSets=(tonumber(Job.TextureSets) or 0)+(tonumber(Count) or 0)
            if WasDetached then Job.Rebound=(tonumber(Job.Rebound) or 0)+1 end
        else
            Job.Failed=(tonumber(Job.Failed) or 0)+1
        end
        return true
    end

    local Phase=tostring(Job.Phase or "paint")
    if Phase=="verify" then
        local I=tonumber(Job.VerifyIndex) or 1
        local Item=Job.Items and Job.Items[I] or nil
        if Item==nil then
            local MaxPass=math.max(1,tonumber(ArmorSkinSlicedVerifyPasses) or 2)
            if (tonumber(Job.VerifyPass) or 1)<MaxPass then
                Job.VerifyPass=(tonumber(Job.VerifyPass) or 1)+1
                Job.VerifyIndex=1
                return true
            end
            ArmorSkinFinishSlicedJob(Job)
            return false
        end
        Job.VerifyIndex=I+1
        -- The game can silently put its authored green material back into a slot
        -- after our first write. Retint the cached MID with the latest desired
        -- color and rebind only if it is no longer the live slot material.
        local Ok,Count,WasDetached=ArmorSkinApplyColorToExistingItem(Item,Job.Texture,Job.ColorIndex,false,Job.PlayerId)
        if Ok then
            Job.TextureSets=(tonumber(Job.TextureSets) or 0)+(tonumber(Count) or 0)
            if WasDetached then Job.Rebound=(tonumber(Job.Rebound) or 0)+1 end
        else
            Job.VerifyFailed=(tonumber(Job.VerifyFailed) or 0)+1
        end
        return true
    end

    local I=tonumber(Job.NextIndex) or 1
    local Item=Job.Slots and Job.Slots[I] or nil
    if Item==nil then
        Job.Phase="verify"
        Job.VerifyPass=1
        Job.VerifyIndex=1
        return true
    end
    Job.NextIndex=I+1
    if not IsValidObject(Item.Component) or not IsValidObject(Item.OriginalMaterial) or not IsValidObject(Job.Texture) then
        Job.Failed=(tonumber(Job.Failed) or 0)+1; return true
    end
    local ScopeLower=string.lower(tostring(Item.Scope or ""))
    local IsFirstPerson=string.find(ScopeLower,"first-person",1,true)==1
    local Params=ArmorSkinFindDiffuseParams(Item.OriginalMaterial)
    local FPTextureParams,FPVectorParams={},{}
    if IsFirstPerson then
        FPTextureParams,FPVectorParams=ArmorSkinCollectFirstPersonParams(Item.OriginalMaterial)
    end
    if Params==nil and not (IsFirstPerson and (#FPTextureParams>0 or #FPVectorParams>0)) then
        Job.Failed=(tonumber(Job.Failed) or 0)+1; return true
    end
    local NewItem={Component=Item.Component,ComponentName=Item.ComponentName,Slot=Item.Slot,
        OriginalMaterial=ArmorSkinPaletteCanonicalSource(Item.OriginalMaterial),MID=nil,Params=Params or {},FPTextureParams=FPTextureParams,
        FPVectorParams=FPVectorParams,Scope=Item.Scope}
    local Good,Count,WasDetached=ArmorSkinApplyColorToExistingItem(NewItem,Job.Texture,Job.ColorIndex,true,Job.PlayerId)
    if not Good then
        -- Fallback only if shared world-owned palette creation is unavailable.
        ArmorSkinSlicedSerial=(tonumber(ArmorSkinSlicedSerial) or 0)+1
        local MID=ArmorSkinCreateMID(Item,ArmorSkinSlicedSerial)
        if IsValidObject(MID) then
            NewItem.MID=MID
            Good,Count,WasDetached=ArmorSkinApplyColorLegacyToExistingItem(NewItem,Job.Texture,Job.ColorIndex,true)
        end
    end
    if not Good then Job.Failed=(tonumber(Job.Failed) or 0)+1; return true end
    Job.Applied=(tonumber(Job.Applied) or 0)+1
    Job.TextureSets=(tonumber(Job.TextureSets) or 0)+(tonumber(Count) or 0)
    Job.Items[#Job.Items+1]=NewItem
    return true
end

function ArmorSkinSlicedPump()
    ArmorSkinSlicedPumpScheduled=false
    if ModTeardownGuard or not MissionReady then return end
    if (tonumber(ArmorSkinBipedWriteQuietUntilClock) or 0)>os.clock() then
        ArmorSkinSlicedPumpScheduled=true
        local T=ArmorSkinSlicedPumpToken
        ExecuteInGameThreadWithDelay(120,function() if T==ArmorSkinSlicedPumpToken then ArmorSkinSlicedPump() end end)
        return
    end
    local Pick=nil
    while #ArmorSkinSlicedJobOrder>0 do
        local K=table.remove(ArmorSkinSlicedJobOrder,1)
        local J=ArmorSkinSlicedJobsByTarget[K]
        if type(J)=="table" then Pick=J; break end
    end
    if Pick~=nil then
        local Still=true
        local Batch=math.max(1,tonumber(ArmorSkinPaletteBindBatchSize) or 8)
        for _=1,Batch do
            if not Still or ArmorSkinSlicedJobsByTarget[Pick.TargetKey]~=Pick then break end
            Still=ArmorSkinProcessOneSlicedSlot(Pick)
        end
        if Still and ArmorSkinSlicedJobsByTarget[Pick.TargetKey]==Pick then
            ArmorSkinSlicedJobOrder[#ArmorSkinSlicedJobOrder+1]=Pick.TargetKey
        end
    end
    if next(ArmorSkinSlicedJobsByTarget)~=nil then
        ArmorSkinSlicedPumpScheduled=true
        local T=ArmorSkinSlicedPumpToken
        local Delay=tonumber(ArmorSkinSlicedSliceDelayMs) or 55
        if Pick and Pick.Mode=="update" then Delay=tonumber(ArmorSkinSlicedUpdateDelayMs) or 35 end
        ExecuteInGameThreadWithDelay(Delay,function()
            if T==ArmorSkinSlicedPumpToken then ArmorSkinSlicedPump() end
        end)
    end
end

function ArmorSkinEnsureSlicedPump()
    if ArmorSkinSlicedPumpScheduled or next(ArmorSkinSlicedJobsByTarget)==nil then return end
    ArmorSkinSlicedPumpScheduled=true
    local T=ArmorSkinSlicedPumpToken
    ExecuteInGameThreadWithDelay(1,function() if T==ArmorSkinSlicedPumpToken then ArmorSkinSlicedPump() end end)
end

function ArmorSkinRetargetExistingSlicedJob(Job,ColorIndex,Texture,Source)
    if type(Job)~="table" then return false end
    local Old=tonumber(Job.ColorIndex)
    Job.ColorIndex=tonumber(ColorIndex) or Job.ColorIndex
    Job.Texture=Texture
    Job.Source=Source or Job.Source
    if Old~=tonumber(Job.ColorIndex) then
        Log("ARMORSKIN palette bind RETARGET target=%s playerId=%s old=%s new=%s mode=%s source=%s",
            tostring(Job.TargetKey),tostring(Job.PlayerId),ArmorSkinColorLabel(Old),ArmorSkinColorLabel(Job.ColorIndex),
            tostring(Job.Mode or "build"),tostring(Source or "cycle"))
    end
    return true
end

function ArmorSkinQueueSlicedExistingUpdate(Pawn,PlayerId,PlayerIndex,ColorIndex,Texture,Source,TargetKey,Existing,Biped,BipedKey)
    local Active=ArmorSkinSlicedJobsByTarget[TargetKey]
    if type(Active)=="table" and tostring(Active.BipedKey or "")==tostring(BipedKey or "") then
        ArmorSkinRetargetExistingSlicedJob(Active,ColorIndex,Texture,Source)
        ArmorSkinEnsureSlicedPump()
        return true,"sliced job retargeted"
    end
    local Items={}
    for _,Item in ipairs(type(Existing)=="table" and (Existing.Items or {}) or {}) do Items[#Items+1]=Item end
    if #Items<=0 then return false,"no existing MID items" end
    local Job={Mode="update",TargetKey=TargetKey,Pawn=Pawn,PawnKey=ArmorSkinObjectKey(Pawn),Biped=Biped,BipedKey=BipedKey,
        PlayerId=PlayerId,PlayerIndex=PlayerIndex,ColorIndex=ColorIndex,Texture=Texture,Source=Source or "cycle",
        Slots=Items,Items=Items,NextIndex=1,ExistingState=Existing,Applied=0,Failed=0,Rebound=0,TextureSets=0}
    ArmorSkinSlicedJobsByTarget[TargetKey]=Job
    local Seen=false
    for _,K in ipairs(ArmorSkinSlicedJobOrder) do if K==TargetKey then Seen=true break end end
    if not Seen then ArmorSkinSlicedJobOrder[#ArmorSkinSlicedJobOrder+1]=TargetKey end
    Log("ARMORSKIN palette bind UPDATE QUEUED target=%s playerId=%s color=%s slots=%d slice=%dms source=%s",
        tostring(TargetKey),tostring(PlayerId),ArmorSkinColorLabel(ColorIndex),#Items,
        tonumber(ArmorSkinSlicedUpdateDelayMs) or 35,tostring(Source or "cycle"))
    ArmorSkinEnsureSlicedPump()
    return true,string.format("sliced update queued slots=%d",#Items)
end

function ArmorSkinQueueSlicedRebuild(Pawn,PlayerId,PlayerIndex,ColorIndex,Texture,Source,TargetKey,CurrentArmsKey,CurrentArmsRoute)
    local ExistingJob=ArmorSkinSlicedJobsByTarget[TargetKey]
    local Biped=ArmorSkinFindThirdPersonBiped(Pawn)
    local BipedKey=ArmorSkinObjectKey(Biped)
    if type(ExistingJob)=="table" and ExistingJob.BipedKey~=nil and BipedKey~=nil
        and tostring(ExistingJob.BipedKey)==tostring(BipedKey) then
        ArmorSkinRetargetExistingSlicedJob(ExistingJob,ColorIndex,Texture,Source)
        ArmorSkinEnsureSlicedPump()
        return true,"sliced rebuild retargeted"
    end
    local Slots,NewBiped,ScanErr,ScanInfo=ArmorSkinScanSlots(Pawn)
    if #Slots==0 or not IsValidObject(NewBiped) then return false,tostring(ScanErr) end
    BipedKey=ArmorSkinObjectKey(NewBiped)
    local Job={Mode="build",Phase="paint",TargetKey=TargetKey,Pawn=Pawn,PawnKey=ArmorSkinObjectKey(Pawn),Biped=NewBiped,BipedKey=BipedKey,
        PlayerId=PlayerId,PlayerIndex=PlayerIndex,ColorIndex=ColorIndex,Texture=Texture,Source=Source or "cycle",
        Slots=Slots,NextIndex=1,Items={},Applied=0,Failed=0,Rebound=0,VerifyFailed=0,TextureSets=0,ScanInfo=ScanInfo,
        CurrentArmsKey=CurrentArmsKey,CurrentArmsRoute=CurrentArmsRoute}
    ArmorSkinSlicedJobsByTarget[TargetKey]=Job
    local Seen=false
    for _,K in ipairs(ArmorSkinSlicedJobOrder) do if K==TargetKey then Seen=true break end end
    if not Seen then ArmorSkinSlicedJobOrder[#ArmorSkinSlicedJobOrder+1]=TargetKey end
    Log("ARMORSKIN palette bind QUEUED target=%s playerId=%s color=%s slots=%d slice=%dms verifyPasses=%d source=%s",
        tostring(TargetKey),tostring(PlayerId),ArmorSkinColorLabel(ColorIndex),#Slots,
        tonumber(ArmorSkinSlicedSliceDelayMs) or 55,tonumber(ArmorSkinSlicedVerifyPasses) or 2,tostring(Source or "cycle"))
    ArmorSkinEnsureSlicedPump()
    return true,string.format("sliced rebuild queued slots=%d",#Slots)
end

function ArmorSkinApplyToPawn(Pawn, PlayerId, PlayerIndex, ColorIndex, Source)
    Pawn=Unwrap(Pawn)
    ColorIndex=tonumber(ColorIndex) or 0
    if not IsValidObject(Pawn) or ColorIndex<0 or ColorIndex>#WarthogCEColors then return false,"invalid pawn/color" end
    local QuietUntil=tonumber(ArmorSkinBipedWriteQuietUntilClock) or 0
    if QuietUntil>os.clock() then return false,"biped construction settle gate" end
    local TargetKey=ArmorSkinTargetKey(PlayerId,PlayerIndex)

    if ColorIndex==0 then
        local Active=ArmorSkinSlicedJobsByTarget[TargetKey]
        if type(Active)=="table" then ArmorSkinSlicedJobsByTarget[TargetKey]=nil end
        ArmorSkinRestoreTarget(TargetKey,Source or "original")
        return true,"ORIGINAL GREEN"
    end

    local Texture,TexErr=ArmorSkinLoadTexture(ColorIndex)
    if not IsValidObject(Texture) then return false,tostring(TexErr) end
    local Biped=ArmorSkinFindThirdPersonBiped(Pawn)
    local BipedKey=ArmorSkinObjectKey(Biped)
    local Existing=ArmorSkinAppliedByTarget[TargetKey]
    local ExistingBipedKey=nil
    if type(Existing)=="table" then ExistingBipedKey=Existing.BipedKey or ArmorSkinObjectKey(Existing.Biped) end
    local SameBiped=type(Existing)=="table" and BipedKey~=nil and tostring(ExistingBipedKey or "")==tostring(BipedKey)
    local CurrentArms,CurrentArmsKey,CurrentArmsRoute=ArmorSkinFirstPersonAnchor(Pawn)
    local ExistingFirstPerson=ArmorSkinStateFirstPersonCount(Existing)
    local FirstPersonNeedsRescan=SameBiped and IsValidObject(CurrentArms)
        and (ExistingFirstPerson<=0 or (Existing.FirstPersonArmsKey~=nil and CurrentArmsKey~=nil
            and tostring(Existing.FirstPersonArmsKey)~=tostring(CurrentArmsKey)))

    local Active=ArmorSkinSlicedJobsByTarget[TargetKey]
    if type(Active)=="table" and Active.BipedKey~=nil and BipedKey~=nil
        and tostring(Active.BipedKey)==tostring(BipedKey) then
        ArmorSkinRetargetExistingSlicedJob(Active,ColorIndex,Texture,Source)
        ArmorSkinEnsureSlicedPump()
        return true,"sliced job retargeted"
    end

    if SameBiped and #(Existing.Items or {})>0 and not FirstPersonNeedsRescan then
        if tonumber(Existing.ColorIndex)==tonumber(ColorIndex) then return true,"already verified settled" end
        -- RC3_60: the slots stay bound to one mutable shared MID set per player.
        -- Normal color changes touch only the 2-3 unique shared MIDs: no 38-slot
        -- SetMaterial pass and no per-slot GetMaterial verification on the hot path.
        return ArmorSkinApplySharedPlayerColor(Existing,PlayerId,ColorIndex,Texture,Source)
    end

    -- Never restore every slot merely because FP arms or the presentation biped
    -- changed. That caused RC3_57 to flash/revert the whole Spartan to green.
    -- Drop only Lua refs and let the new verified sliced rebuild replace live slots.
    if type(Existing)=="table" then
        ArmorSkinDropTargetRuntimeRefs(TargetKey,FirstPersonNeedsRescan and "FP/binding lifecycle changed" or "biped lifecycle changed")
    end

    return ArmorSkinQueueSlicedRebuild(Pawn,PlayerId,PlayerIndex,ColorIndex,Texture,
        Source,TargetKey,CurrentArmsKey,CurrentArmsRoute)
end

function ArmorSkinFindDefaultCatalogEntry()
    if ArmorSkinDefaultCatalogIndex ~= nil and ArmorCatalog ~= nil and ArmorCatalog[ArmorSkinDefaultCatalogIndex] ~= nil then
        return ArmorSkinDefaultCatalogIndex, ArmorCatalog[ArmorSkinDefaultCatalogIndex]
    end
    if ArmorCatalog == nil or #ArmorCatalog == 0 then BuildCatalog() end
    if ArmorCatalog == nil or #ArmorCatalog == 0 then return nil, nil end

    local Fallback = 1
    for I, Entry in ipairs(ArmorCatalog) do
        local Skin = string.lower(tostring(Entry.Skin or ""))
        local Short = string.lower(tostring(Entry.Short or ""))
        local Model = string.lower(tostring(Entry.Model or ""))
        if Skin == "blam.customization.masterchief.default" or string.match(Skin, "%.default$") or Short == "default" then
            ArmorSkinDefaultCatalogIndex = I
            Log("ARMORSKIN default Spartan catalog entry=%d skin=%s model=%s", I, tostring(Entry.Skin), tostring(Entry.Model))
            return I, Entry
        end
        if string.find(Model, "default", 1, true) ~= nil then Fallback = I end
    end
    ArmorSkinDefaultCatalogIndex = Fallback
    Log("ARMORSKIN default Spartan exact tag not found; using catalog fallback entry=%d skin=%s model=%s",
        Fallback, tostring(ArmorCatalog[Fallback].Skin), tostring(ArmorCatalog[Fallback].Model))
    return Fallback, ArmorCatalog[Fallback]
end

function ArmorSkinCurrentModelIsDefault(PlayerIndex)
    local Settings = GetUserSettings(PlayerIndex)
    if not IsValidObject(Settings) then return false, "settings unavailable" end
    local _, CurrentName = FindMasterChiefSelection(Settings)
    if CurrentName == nil or CurrentName == "" or CurrentName == "None" then
        -- A fresh local user may have no explicit customization tag; Halo then uses
        -- the authored green default Spartan.
        return true, "implicit default"
    end
    local _, DefaultEntry = ArmorSkinFindDefaultCatalogEntry()
    if DefaultEntry == nil then return false, "default catalog entry unavailable" end
    return string.lower(tostring(CurrentName)) == string.lower(tostring(DefaultEntry.Skin)), tostring(CurrentName)
end

function ArmorSkinEnsureDefaultModel(PlayerIndex, Source)
    local IsDefault, Current = ArmorSkinCurrentModelIsDefault(PlayerIndex)
    if IsDefault then return true, false end
    local DefaultIndex, DefaultEntry = ArmorSkinFindDefaultCatalogEntry()
    if DefaultIndex == nil or DefaultEntry == nil then return false, false, "default Spartan catalog entry unavailable" end

    local Ok, Info = ApplyDirect(PlayerIndex, DefaultEntry)
    if not Ok then return false, false, tostring(Info) end
    CatalogIndex[PlayerIndex] = DefaultIndex
    IndexInitialized[PlayerIndex] = true
    Log("ARMORSKIN P%d model fallback %s -> default Spartan before skin cycle source=%s",
        PlayerIndex, tostring(Current), tostring(Source or "skin input"))
    return true, true, tostring(Info)
end

-- V15: desired Classic color is separate from committed/persisted/network state.
-- A peer must never see a color until this machine has successfully applied it.
ClassicArmorPendingCommitByPlayer = ClassicArmorPendingCommitByPlayer or {}
-- V16: last exact local biped proof may survive benign assignment-table rebuilds,
-- but NEVER a new Spartan construction event or world/runtime generation change.
ClassicArmorV16BipedEpoch = ClassicArmorV16BipedEpoch or 0
ClassicArmorV16LocalBipedProofByPlayer = ClassicArmorV16LocalBipedProofByPlayer or {}

function ArmorSkinV15BeginPendingCommit(PlayerIndex, ColorIndex, Source)
    PlayerIndex=math.max(1,math.min(2,tonumber(PlayerIndex) or 1))
    ColorIndex=math.max(0,math.min(#WarthogCEColors,tonumber(ColorIndex) or 0))
    ArmorSkinLocalIndexByPlayer[PlayerIndex]=ColorIndex
    ClassicArmorPendingCommitByPlayer[PlayerIndex]={ColorIndex=ColorIndex,Source=tostring(Source or "Classic input")}
    Log("CLASSIC18V15 PENDING P%d color=%s source=%s",PlayerIndex,ArmorSkinColorLabel(ColorIndex),tostring(Source or "Classic input"))
end

function ArmorSkinV15CommitPending(PlayerIndex, ColorIndex, Source)
    PlayerIndex=math.max(1,math.min(2,tonumber(PlayerIndex) or 1))
    ColorIndex=tonumber(ColorIndex) or 0
    local P=ClassicArmorPendingCommitByPlayer[PlayerIndex]
    if type(P)~="table" or tonumber(P.ColorIndex)~=ColorIndex then return false end
    ClassicArmorPendingCommitByPlayer[PlayerIndex]=nil
    ClassicArmorSetPersistentSelection(PlayerIndex,ColorIndex,tostring(Source or P.Source or "Classic").." V15 commit")
    Log("CLASSIC18V15 COMMIT P%d color=%s source=%s",
        PlayerIndex,ArmorSkinColorLabel(ColorIndex),tostring(Source or P.Source or "Classic"))
    return true
end

function ArmorSkinV15AbortPending(PlayerIndex, ColorIndex, Source, Info)
    PlayerIndex=math.max(1,math.min(2,tonumber(PlayerIndex) or 1))
    ColorIndex=tonumber(ColorIndex) or 0
    local P=ClassicArmorPendingCommitByPlayer[PlayerIndex]
    if type(P)~="table" or tonumber(P.ColorIndex)~=ColorIndex then return false end
    ClassicArmorPendingCommitByPlayer[PlayerIndex]=nil
    local Committed=tonumber(ClassicArmorMenuSelectedByPlayer[PlayerIndex]) or 0
    ArmorSkinLocalIndexByPlayer[PlayerIndex]=Committed
    Log("CLASSIC18V15 ABORT P%d requested=%s reverted=%s source=%s info=%s",
        PlayerIndex,ArmorSkinColorLabel(ColorIndex),ArmorSkinColorLabel(Committed),tostring(Source or P.Source or "Classic"),tostring(Info or "apply failed"))
    return true
end

function ArmorSkinScheduleLocalApply(PlayerIndex, ColorIndex, Source, ModelChanged)
    ArmorSkinLocalApplyToken[PlayerIndex] = (tonumber(ArmorSkinLocalApplyToken[PlayerIndex]) or 0) + 1
    local Token = ArmorSkinLocalApplyToken[PlayerIndex]
    ArmorSkinLocalSettledToken[PlayerIndex] = 0

    -- V13: schedule retries as a CHAIN instead of enqueueing every future attempt
    -- up front. Rapid Classic input in V12 could leave dozens of stale UE4SS
    -- delayed callbacks in flight even though their tokens were obsolete. Only one
    -- retry callback per local player may now exist at a time.
    local Gaps = ModelChanged and { 80, 140, 230, 300, 300, 350 } or { 0, 180, 420 }
    if VehicleMessageOfflineFastPath ~= true then
        Gaps = ModelChanged
            and { 2500, 350, 600, 900, 1300, 1800 }
            or { 0, 180, 420, 600, 1000, 1300, 2000 }
    end

    local function QueueAttempt(AttemptIndex)
        if AttemptIndex > #Gaps then return end
        local GapMs = tonumber(Gaps[AttemptIndex]) or 0
        ExecuteInGameThreadWithDelay(GapMs, function()
            if ModTeardownGuard or Token ~= ArmorSkinLocalApplyToken[PlayerIndex] then return end
            if ArmorSkinLocalSettledToken[PlayerIndex] == Token then return end
            if tonumber(ArmorSkinLocalIndexByPlayer[PlayerIndex]) ~= tonumber(ColorIndex) then return end

            local Controller = GetPlayer(PlayerIndex)
            local Pawn = ArmorSkinGetPawnFromController(Controller)
            local Ok, Info = false, "pawn unavailable"
            if IsValidObject(Pawn) then
                local PlayerId = ArmorSkinPlayerIdFromController(Controller)
                Ok, Info = ArmorSkinApplyToPawn(Pawn, PlayerId, PlayerIndex, ColorIndex, Source)
            end

            if Ok then
                ArmorSkinLocalSettledToken[PlayerIndex] = Token
                if type(ArmorSkinV15CommitPending)=="function" then
                    ArmorSkinV15CommitPending(PlayerIndex,ColorIndex,Source)
                end
                if ColorIndex > 0 and PerspectiveThirdPerson[PlayerIndex] ~= true
                    and type(ArmorSkinSchedulePerspectiveFirstPersonRebind) == "function" then
                    ArmorSkinSchedulePerspectiveFirstPersonRebind(PlayerIndex,
                        tostring(Source or "local armor apply") .. " first-person settle")
                end
                return
            end

            if AttemptIndex >= #Gaps then
                Log("ARMORSKIN P%d delayed apply exhausted color=%s source=%s info=%s",
                    PlayerIndex, ArmorSkinColorLabel(ColorIndex), tostring(Source), tostring(Info))
                if type(ArmorSkinV15AbortPending)=="function" then
                    ArmorSkinV15AbortPending(PlayerIndex,ColorIndex,Source,Info)
                end
                return
            end
            QueueAttempt(AttemptIndex + 1)
        end)
    end

    QueueAttempt(1)
end

function ArmorSkinRebindFirstPersonMIDs(PlayerIndex, Source)
    PlayerIndex = math.max(1, math.min(2, tonumber(PlayerIndex) or 1))
    if ModTeardownGuard or not MissionReady then return false, "mission unavailable" end
    local ColorIndex = tonumber(ArmorSkinLocalIndexByPlayer[PlayerIndex]) or 0
    if ColorIndex <= 0 then return false, "original green selected" end

    local Controller = GetPlayer(PlayerIndex)
    local Pawn = ArmorSkinGetPawnFromController(Controller)
    if not IsValidObject(Pawn) then return false, "pawn unavailable" end
    local PlayerId = ArmorSkinPlayerIdFromController(Controller)
    local TargetKey = ArmorSkinTargetKey(PlayerId, PlayerIndex)
    local State = ArmorSkinAppliedByTarget[TargetKey]

    -- If the FP component instance changed (respawn/view reconstruction), use
    -- the normal apply path; it already knows how to restore and rescan safely.
    local CurrentArms, CurrentArmsKey, CurrentRoute = ArmorSkinFirstPersonAnchor(Pawn)
    if type(State) ~= "table" or #(State.Items or {}) == 0 then
        local Ok, Info = ArmorSkinApplyToPawn(Pawn, PlayerId, PlayerIndex, ColorIndex,
            tostring(Source or "first-person bind") .. " missing-state rebuild")
        return Ok, tostring(Info)
    end
    if IsValidObject(CurrentArms) and CurrentArmsKey ~= nil and State.FirstPersonArmsKey ~= nil
        and tostring(CurrentArmsKey) ~= tostring(State.FirstPersonArmsKey) then
        ArmorSkinDropTargetRuntimeRefs(TargetKey, "first-person component changed before rebind")
        local Ok, Info = ArmorSkinApplyToPawn(Pawn, PlayerId, PlayerIndex, ColorIndex,
            tostring(Source or "first-person bind") .. " changed-arms rebuild")
        return Ok, tostring(Info)
    end

    local Texture, TexErr = ArmorSkinLoadTexture(ColorIndex)
    if not IsValidObject(Texture) then return false, tostring(TexErr) end
    local FirstPersonItems, Rebound, TextureSets, Failed, DetachedBefore = 0, 0, 0, 0, 0
    for _, Item in ipairs(State.Items or {}) do
        local ScopeLower = string.lower(tostring(Item.Scope or ""))
        if string.find(ScopeLower, "first-person", 1, true) == 1 then
            FirstPersonItems = FirstPersonItems + 1
            if IsValidObject(Item.Component) and IsValidObject(Item.MID) then
                local CurrentMaterial = nil
                pcall(function() CurrentMaterial = Unwrap(Item.Component:GetMaterial(Item.Slot)) end)
                local CurrentKey = ArmorSkinObjectKey(CurrentMaterial)
                local MidKey = ArmorSkinObjectKey(Item.MID)
                if CurrentKey == nil or MidKey == nil or tostring(CurrentKey) ~= tostring(MidKey) then
                    DetachedBefore = DetachedBefore + 1
                end

                local TextureOk, TSet, NSet, VSet = ArmorSkinSetFirstPersonOverrides(Item.MID, Item.Params,
                    Item.FPTextureParams, Item.FPVectorParams, Texture, ColorIndex)
                local Count = (tonumber(TSet) or 0) + (tonumber(NSet) or 0) + (tonumber(VSet) or 0)
                local BindOk = pcall(function() Item.Component:SetMaterial(Item.Slot, Item.MID) end)
                if TextureOk and BindOk then
                    Rebound = Rebound + 1
                    TextureSets = TextureSets + Count
                    ArmorSkinRefreshComponent(Item.Component)
                else
                    Failed = Failed + 1
                end
            else
                Failed = Failed + 1
            end
        end
    end

    if FirstPersonItems <= 0 then
        -- A candidate exists but the old state has no FP MIDs: let the existing
        -- split-lifecycle code perform a safe rescan/rebuild.
        local Ok, Info = ArmorSkinApplyToPawn(Pawn, PlayerId, PlayerIndex, ColorIndex,
            tostring(Source or "first-person bind") .. " no-fp-items rebuild")
        return Ok, tostring(Info)
    end

    Log("ARMORSKIN first-person MID rebind P%d color=%s items=%d rebound=%d detachedBefore=%d failed=%d textureSets=%d arms=%s route=%s source=%s",
        PlayerIndex, ArmorSkinColorLabel(ColorIndex), FirstPersonItems, Rebound, DetachedBefore, Failed, TextureSets,
        tostring(CurrentArmsKey or State.FirstPersonArmsKey or "unavailable"), tostring(CurrentRoute or State.FirstPersonRoute or "unavailable"),
        tostring(Source or "first-person bind"))
    return Rebound > 0 and Failed == 0, string.format("rebound=%d failed=%d detached=%d", Rebound, Failed, DetachedBefore)
end

function ArmorSkinSchedulePerspectiveFirstPersonRebind(PlayerIndex, Source)
    PlayerIndex = math.max(1, math.min(2, tonumber(PlayerIndex) or 1))
    ArmorSkinPerspectiveRebindToken[PlayerIndex] = (tonumber(ArmorSkinPerspectiveRebindToken[PlayerIndex]) or 0) + 1
    local Token = ArmorSkinPerspectiveRebindToken[PlayerIndex]
    local Delays = { 80, 350, 1200 }
    for _, DelayMs in ipairs(Delays) do
        local ThisDelay = DelayMs
        ExecuteInGameThreadWithDelay(ThisDelay, function()
            if ModTeardownGuard or Token ~= ArmorSkinPerspectiveRebindToken[PlayerIndex] or not MissionReady then return end
            -- Cancel stale delayed work if the player has already gone back to
            -- third person. Default/false is first person in the native helper.
            if PerspectiveThirdPerson[PlayerIndex] == true then return end
            ArmorSkinRebindFirstPersonMIDs(PlayerIndex,
                string.format("%s +%dms", tostring(Source or "first-person presentation"), ThisDelay))
        end)
    end
end

function ArmorSkinScheduleNetworkApply(PlayerId, ColorIndex, Source)
    PlayerId = tonumber(PlayerId)
    ColorIndex = tonumber(ColorIndex)
    if PlayerId == nil or ColorIndex == nil then return end
    local Key = tostring(math.floor(PlayerId))
    ArmorSkinNetworkPendingTokenByPlayerId[Key] = (tonumber(ArmorSkinNetworkPendingTokenByPlayerId[Key]) or 0) + 1
    local Token = ArmorSkinNetworkPendingTokenByPlayerId[Key]
    local Delays = { 0, 250, 900, 2500, 7000 }
    for _, DelayMs in ipairs(Delays) do
        local ThisDelay = DelayMs
        ExecuteInGameThreadWithDelay(ThisDelay, function()
            if ModTeardownGuard or ArmorSkinNetworkPendingTokenByPlayerId[Key] ~= Token then return end
            if tonumber(ArmorSkinNetworkColorByPlayerId[Key]) ~= ColorIndex then return end
            local Pawn, _, ResolveRoute = ArmorSkinResolvePawnByPlayerId(PlayerId)
            if not IsValidObject(Pawn) then
                if ThisDelay == Delays[#Delays] then
                    Log("ARMORSKIN NET resolve exhausted playerId=%d color=%s source=%s route=%s",
                        PlayerId, ArmorSkinColorLabel(ColorIndex), tostring(Source), tostring(ResolveRoute or "unresolved"))
                end
                return
            end
            -- V10: a host downlink may contain this client's own numeric PlayerId.
            -- Never feed that pawn through the remote/TP-only cache path: it shares
            -- the same P:<PlayerId> target key as local input and can poison a later
            -- local hot-swap with a 19-TP-only cache. Classify exact local ids first.
            local ApplyLocalIndex = ArmorSkinLocalPlayerIndexForPlayerId(PlayerId)
            local Ok, Info = ArmorSkinApplyToPawn(Pawn, PlayerId, ApplyLocalIndex, ColorIndex, Source)
            if Ok then
                ArmorSkinNetworkPendingTokenByPlayerId[Key] = Token + 1
                local PreviousRoute = ArmorSkinNetworkResolveRouteByPlayerId[Key]
                if tostring(PreviousRoute or "") ~= tostring(ResolveRoute or "") then
                    ArmorSkinNetworkResolveRouteByPlayerId[Key] = tostring(ResolveRoute or "unknown")
                    Log("ARMORSKIN NET apply resolved playerId=%d color=%s route=%s pawn=%s",
                        PlayerId, ArmorSkinColorLabel(ColorIndex), tostring(ResolveRoute or "unknown"),
                        tostring(SafeFullName(Pawn) or Pawn))
                end
            elseif ThisDelay == Delays[#Delays] then
                Log("ARMORSKIN NET delayed apply exhausted playerId=%d color=%s source=%s route=%s info=%s",
                    PlayerId, ArmorSkinColorLabel(ColorIndex), tostring(Source), tostring(ResolveRoute or "unknown"), tostring(Info))
            end
        end)
    end
end

-- RC3_43 same-fireteam cross-mission logical color carry -------------------
function ArmorSkinPersistentRememberRemote(PlayerId, ColorIndex, OriginSlot, Source)
    PlayerId=tonumber(PlayerId); ColorIndex=tonumber(ColorIndex); OriginSlot=tonumber(OriginSlot)
    if PlayerId==nil or ColorIndex==nil or ColorIndex<0 or ColorIndex>#WarthogCEColors then return false end
    local K=tostring(math.floor(PlayerId))
    -- If the identity is currently local on this machine, its authoritative
    -- persistence is ClassicArmorMenuSelectedByPlayer, not this remote cache.
    if ArmorSkinLocalPlayerIndexForPlayerId(PlayerId)~=nil then
        ArmorSkinPersistentRemoteColorByPlayerId[K]=nil
        ArmorSkinPersistentRemoteOriginSlotByPlayerId[K]=nil
        return false
    end
    local Old=tonumber(ArmorSkinPersistentRemoteColorByPlayerId[K])
    ArmorSkinPersistentRemoteColorByPlayerId[K]=ColorIndex
    if OriginSlot==1 or OriginSlot==2 then ArmorSkinPersistentRemoteOriginSlotByPlayerId[K]=OriginSlot end
    if Old~=ColorIndex then
        Log("ARMORSKIN persistent remote color remembered playerId=%d originSlot=%s color=%s source=%s",
            PlayerId,(OriginSlot==1 or OriginSlot==2) and ("P"..tostring(OriginSlot)) or "?",
            ArmorSkinColorLabel(ColorIndex),tostring(Source or "network"))
    end
    return true
end

function ArmorSkinPersistentRestoreRemoteStates(Source)
    if not MissionReady then return 0 end
    local Records=ArmorSkinAllKnownPlayerPawnRecords()
    if type(Records)~="table" or #Records==0 then return 0 end
    local Restored=0
    local Present={}
    for _,R in ipairs(Records) do
        local Pid=tonumber(R.PlayerId)
        if Pid~=nil then
            local K=tostring(math.floor(Pid)); Present[K]=true
            if R.LocalIndex==nil then
                local C=tonumber(ArmorSkinPersistentRemoteColorByPlayerId[K])
                if C~=nil and C>=0 and C<=#WarthogCEColors then
                    ArmorSkinNetworkColorByPlayerId[K]=C
                    local S=tonumber(ArmorSkinPersistentRemoteOriginSlotByPlayerId[K])
                    if S==1 or S==2 then ArmorSkinNetworkOriginSlotByPlayerId[K]=S end
                    Restored=Restored+1
                end
            else
                -- Never let a stale remote-cache entry shadow a now-local player.
                ArmorSkinPersistentRemoteColorByPlayerId[K]=nil
                ArmorSkinPersistentRemoteOriginSlotByPlayerId[K]=nil
            end
        end
    end
    local G=tonumber(WarthogColorRuntimeGeneration) or 0
    if Restored>0 and tonumber(ArmorSkinPersistentRestoreAuditGeneration)~=G then
        ArmorSkinPersistentRestoreAuditGeneration=G
        local Parts={}
        for _,R in ipairs(Records) do
            if R.LocalIndex==nil and R.PlayerId~=nil then
                local K=tostring(math.floor(tonumber(R.PlayerId)))
                local C=tonumber(ArmorSkinPersistentRemoteColorByPlayerId[K])
                if C~=nil then
                    local S=tonumber(ArmorSkinPersistentRemoteOriginSlotByPlayerId[K])
                    Parts[#Parts+1]=string.format("%s/P%s=%s",K,(S==1 or S==2) and tostring(S) or "?",ArmorSkinColorLabel(C))
                end
            end
        end
        Log("ARMORSKIN persistent remote restore count=%d generation=%d source=%s states=%s",
            Restored,G,tostring(Source or "mission"),#Parts>0 and table.concat(Parts," | ") or "-")
    end
    return Restored
end

-- RC3_52: the client->host color can be remembered correctly while the new
-- mission's remote presentation biped is still constructing.  Poll only the
-- already-known player records and the safe biped resolver at a modest cadence
-- until every non-green persistent remote color has been applied.  This is
-- deliberately bounded and contains no reflection/order/suffix guessing.
ArmorSkinMissionCarryRemoteRetryGeneration = ArmorSkinMissionCarryRemoteRetryGeneration or -1
ArmorSkinMissionCarryRemoteSettledGeneration = ArmorSkinMissionCarryRemoteSettledGeneration or -1

function ArmorSkinMissionCarryIdentityReady(Records)
    local LocalCount,Anchored,RemoteCount=0,0,0
    for _,R in ipairs(type(Records)=="table" and Records or {}) do
        if R.LocalIndex~=nil then
            LocalCount=LocalCount+1
            local Pawn=Unwrap(R.Pawn)
            if not IsValidObject(Pawn) and tonumber(R.LocalIndex) then
                Pawn=ArmorSkinGetPawnFromController(GetPlayer(tonumber(R.LocalIndex)))
            end
            if IsValidObject(Pawn) and IsValidObject(ArmorSkinDirectBipedChild(Pawn)) then Anchored=Anchored+1 end
        else
            RemoteCount=RemoteCount+1
        end
    end
    if RemoteCount<=0 then return true end
    if LocalCount<=0 or Anchored<LocalCount then return false end
    if RemoteCount==1 then return true end
    if RemoteCount==2 then
        local V=ArmorSkinRemotePairVector
        return type(V)=="table" and tonumber(V.Generation)==(tonumber(WarthogColorRuntimeGeneration) or 0)
    end
    return false
end

function ArmorSkinScheduleMissionCarryRemoteReapply(Source)
    if not MissionReady then return false end
    local G=tonumber(WarthogColorRuntimeGeneration) or 0
    if tonumber(ArmorSkinMissionCarryRemoteRetryGeneration)==G then return false end
    ArmorSkinMissionCarryRemoteRetryGeneration=G
    ArmorSkinMissionCarryRemoteSettledGeneration=-1
    local Delays={700,2500,7000,15000,30000}
    for _,DelayMs in ipairs(Delays) do
        local ThisDelay=DelayMs
        ExecuteInGameThreadWithDelay(ThisDelay,function()
            if ModTeardownGuard or not MissionReady or (tonumber(WarthogColorRuntimeGeneration) or 0)~=G then return end
            if tonumber(ArmorSkinMissionCarryRemoteSettledGeneration)==G then return end
            ArmorSkinPersistentRestoreRemoteStates(string.format("mission-carry retry +%dms",ThisDelay))
            local Records=ArmorSkinAllKnownPlayerPawnRecords()
            local Needed,Applied=0,0
            local IdentityReady=ArmorSkinMissionCarryIdentityReady(Records)
            for _,R in ipairs(type(Records)=="table" and Records or {}) do
                local Pid=tonumber(R.PlayerId)
                if R.LocalIndex==nil and Pid~=nil then
                    local K=tostring(math.floor(Pid))
                    local C=tonumber(ArmorSkinPersistentRemoteColorByPlayerId[K])
                    if C~=nil and C>0 and C<=#WarthogCEColors then
                        Needed=Needed+1
                        ArmorSkinNetworkColorByPlayerId[K]=C
                        local S=tonumber(ArmorSkinPersistentRemoteOriginSlotByPlayerId[K])
                        if S==1 or S==2 then ArmorSkinNetworkOriginSlotByPlayerId[K]=S end
                        if IdentityReady then
                            local Pawn=Unwrap(R.Pawn)
                            if not IsValidObject(Pawn) then Pawn=select(1,ArmorSkinResolvePawnByPlayerId(Pid)) end
                            if IsValidObject(Pawn) then
                                local Ok=ArmorSkinApplyToPawn(Pawn,Pid,nil,C,string.format("mission-carry remote reapply +%dms",ThisDelay))
                                if Ok then Applied=Applied+1 end
                            end
                        end
                    end
                end
            end
            if Needed>0 and Applied>=Needed then
                ArmorSkinMissionCarryRemoteSettledGeneration=G
                Log("ARMORSKIN mission-carry remote settled generation=%d applied=%d delay=%dms source=%s",G,Applied,ThisDelay,tostring(Source or "mission"))
            elseif ThisDelay==Delays[#Delays] and Needed>0 then
                Log("ARMORSKIN mission-carry remote retry exhausted generation=%d applied=%d/%d identityReady=%s source=%s",G,Applied,Needed,tostring(IdentityReady),tostring(Source or "mission"))
            end
        end)
    end
    return true
end

-- v1.11.0 native Classic12 cleanup ------------------------------------------
-- The retired vehicle-style Classic armor RPC transport (HCECEA*) has been
-- removed. Classic armor is now selected through cooked native customization
-- rows, so Halo owns replication just like ordinary armor/customization.
-- Keep only this generic local-id helper because dormant local presentation
-- helpers still use it for exact local-vs-remote classification.
function ArmorSkinLocalPlayerIndexForPlayerId(PlayerId)
    PlayerId=tonumber(PlayerId); if PlayerId==nil then return nil end
    for I=1,2 do
        local C=GetPlayer(I)
        if tonumber(ArmorSkinPlayerIdFromController(C))==PlayerId then return I end
    end
    return nil
end

function ArmorSkinPrepareForModelSwap(PlayerIndex, Source)
    if type(ClassicArmorPendingCommitByPlayer)=="table" then
        ClassicArmorPendingCommitByPlayer[PlayerIndex]=nil
    end
    local Previous = tonumber(ArmorSkinLocalIndexByPlayer[PlayerIndex]) or 0
    local WasDefault = select(1, ArmorSkinCurrentModelIsDefault(PlayerIndex))
    if WasDefault and ArmorCatalog ~= nil then
        local CurrentCatalogIndex = tonumber(CatalogIndex[PlayerIndex])
        if CurrentCatalogIndex ~= nil and ArmorCatalog[CurrentCatalogIndex] ~= nil then
            ArmorSkinDefaultCatalogIndex = CurrentCatalogIndex
            Log("ARMORSKIN learned default Spartan catalog entry=%d before model swap skin=%s",
                CurrentCatalogIndex, tostring(ArmorCatalog[CurrentCatalogIndex].Skin))
        end
    end
    local Controller = GetPlayer(PlayerIndex)
    local PlayerId = ArmorSkinPlayerIdFromController(Controller)
    local TargetKey = ArmorSkinTargetKey(PlayerId, PlayerIndex)
    ArmorSkinLocalApplyToken[PlayerIndex] = (tonumber(ArmorSkinLocalApplyToken[PlayerIndex]) or 0) + 1
    ArmorSkinLocalSettledToken[PlayerIndex] = 0
    ArmorSkinRestoreTarget(TargetKey, "armor model swap")
    ClassicArmorSetPersistentSelection(PlayerIndex, 0, Source or "armor model swap")
    if Previous ~= 0 then
        Log("ARMORSKIN P%d reset to ORIGINAL GREEN before separate armor-model swap", PlayerIndex)
    end
end

function ArmorSkinTraceAnyVehicle(Object)
    local Current = Unwrap(Object)
    local Seen = {}
    for _ = 1, 8 do
        if not IsValidObject(Current) then return nil end
        local Token = SafeFullName(Current) or tostring(Current)
        if Seen[Token] then return nil end
        Seen[Token] = true
        local Lower = string.lower(tostring(Token or ""))
        if string.find(Lower, "vehicleactor", 1, true) ~= nil or
           string.find(Lower, "vehicle_actor", 1, true) ~= nil then
            return Current
        end

        local Owner = nil
        pcall(function() Owner = Unwrap(Current:GetOwner()) end)
        if IsValidObject(Owner) then
            local OwnerName = string.lower(tostring(SafeFullName(Owner) or ""))
            if string.find(OwnerName, "vehicleactor", 1, true) ~= nil or
               string.find(OwnerName, "vehicle_actor", 1, true) ~= nil then
                return Owner
            end
        end

        local Parent = nil
        pcall(function() Parent = Unwrap(Current:GetAttachParent()) end)
        if not IsValidObject(Parent) then pcall(function() Parent = Unwrap(Current.AttachParent) end) end
        if not IsValidObject(Parent) then pcall(function() Parent = Unwrap(Current:GetAttachParentActor()) end) end
        if not IsValidObject(Parent) then return nil end
        Current = Parent
    end
    return nil
end

function ArmorSkinPlayerInAnyVehicle(PlayerIndex)
    local Controller = GetPlayer(PlayerIndex)
    local Pawn = ArmorSkinGetPawnFromController(Controller)
    if not IsValidObject(Pawn) then return false, "pawn unavailable" end

    for _, Source in ipairs({ Controller, Pawn }) do
        for _, Name in ipairs({ "DrivingVehicle", "DrivenVehicle", "CurrentVehicle", "Vehicle", "MountedVehicle" }) do
            local Value = nil
            pcall(function() Value = Unwrap(Source[Name]) end)
            if IsValidObject(Value) then
                local Text = string.lower(tostring(SafeFullName(Value) or ""))
                local Warthog, Scorpion = nil, nil
                pcall(function() Warthog = WarthogResolveVehicleFromObject(Value) end)
                pcall(function() Scorpion = ScorpionResolveVehicleFromObject(Value) end)
                local AnyVehicle = ArmorSkinTraceAnyVehicle(Value)
                if string.find(Text, "vehicle", 1, true) ~= nil or IsValidObject(Warthog) or
                   IsValidObject(Scorpion) or IsValidObject(AnyVehicle) then
                    return true, tostring(Name)
                end
            end
        end
    end

    local Components = WarthogGetActorComponents(Pawn) or {}
    local MaxComponents = math.min(#Components, 96)
    for I = 1, MaxComponents do
        local Component = Unwrap(Components[I])
        if IsValidObject(Component) then
            local Warthog = nil
            pcall(function() Warthog = select(1, WarthogTraceAttachmentChain(Component, "armor-skin occupancy")) end)
            if IsValidObject(Warthog) then return true, "Warthog attachment" end
            local Scorpion = nil
            pcall(function() Scorpion = select(1, ScorpionTraceAttachmentChain(Component)) end)
            if IsValidObject(Scorpion) then return true, "Scorpion attachment" end
            local AnyVehicle = ArmorSkinTraceAnyVehicle(Component)
            if IsValidObject(AnyVehicle) then
                return true, "generic vehicle attachment: " .. tostring(SafeFullName(AnyVehicle) or AnyVehicle)
            end
        end
    end
    return false, "on foot"
end

function CycleDefaultSpartanSkin(PlayerIndex, Delta, Source)
    if not MissionReady then return false end
    local Controller = GetPlayer(PlayerIndex)
    if not IsValidObject(Controller) then return false end

    local IsDefault = select(1, ArmorSkinCurrentModelIsDefault(PlayerIndex))
    if not IsDefault then
        -- A non-default authored armor model has no HCEChief skin state. Start its
        -- skin gesture from ORIGINAL GREEN so next/previous is deterministic.
        ArmorSkinPrepareForModelSwap(PlayerIndex, "skin input from non-default model")
    end

    local Current = tonumber(ArmorSkinLocalIndexByPlayer[PlayerIndex]) or 0
    local Step = (tonumber(Delta) or 1) < 0 and -1 or 1
    local Next = Current + Step
    if Next > #WarthogCEColors then Next = 0 end
    if Next < 0 then Next = #WarthogCEColors end

    local TextureReady = true
    local TextureError = nil
    if Next > 0 then
        local Texture, TexErr = ArmorSkinLoadTexture(Next)
        TextureReady = IsValidObject(Texture)
        TextureError = TexErr
        if not TextureReady then
            local NetworkClientCanPublish = LivesAuthorityResolved and LivesNetworkClientBlocked == true
                and ArmorSkinHostCapabilitySeen == true and VehicleMessageUplinkReady == true
            if not NetworkClientCanPublish then
                ScreenMessage(PlayerIndex, Controller, "ARMOR SKIN ASSETS MISSING - SEE UE4SS.LOG")
                Log("ARMORSKIN P%d cycle blocked color=%s error=%s", PlayerIndex, ArmorSkinColorLabel(Next), tostring(TexErr))
                return false
            end
            Log("ARMORSKIN P%d network-client cycle continuing with deferred local texture color=%s error=%s",
                PlayerIndex, ArmorSkinColorLabel(Next), tostring(TexErr))
        end
    end

    local DefaultOk, ModelChanged, DefaultInfo = ArmorSkinEnsureDefaultModel(PlayerIndex, Source)
    if not DefaultOk then
        ScreenMessage(PlayerIndex, Controller, "ARMOR SKIN: DEFAULT SPARTAN UNAVAILABLE")
        Log("ARMORSKIN P%d default-model fallback failed source=%s info=%s", PlayerIndex, tostring(Source), tostring(DefaultInfo))
        return false
    end

    ClassicArmorSetPersistentSelection(PlayerIndex, Next, Source or "skin cycle")
    ArmorSkinScheduleLocalApply(PlayerIndex, Next, Source or "skin cycle", ModelChanged)
    local Ordinal = Next + 1
    local Total = #WarthogCEColors + 1
    ScreenMessage(PlayerIndex, Controller,
        string.format("P%d ARMOR SKIN %02d/%02d: %s", PlayerIndex, Ordinal, Total, ArmorSkinColorLabel(Next)))
    Log("ARMORSKIN P%d cycle source=%s current=%d next=%d label=%s modelChanged=%s",
        PlayerIndex, tostring(Source), Current, Next, ArmorSkinColorLabel(Next), tostring(ModelChanged == true))
    return true
end

-- Classic menu rows intentionally retain the stock Default tag. The game can
-- therefore perform its usual model/entitlement work, while this handler owns
-- only the free CE color overlay.
ClassicArmorMenuSelectedByPlayer = ClassicArmorMenuSelectedByPlayer or { [1] = 0, [2] = 0 }
ClassicArmorMenuActivationHookReady = ClassicArmorMenuActivationHookReady or false
ClassicArmorMenuLastPlayerIndex = ClassicArmorMenuLastPlayerIndex or 1
ClassicArmorMenuSelectionSyncGuard = ClassicArmorMenuSelectionSyncGuard or false
ClassicArmorMenuReplayByWidget = ClassicArmorMenuReplayByWidget or {}
ClassicArmorMenuReplayGuard = ClassicArmorMenuReplayGuard or false
ClassicArmorMenuPostReplayTokenByWidget = ClassicArmorMenuPostReplayTokenByWidget or {}

function ClassicArmorMenuColorIndex(Entry)
    Entry = Unwrap(Entry)
    local FullName = tostring(SafeFullName(Entry) or "")
    local Name = string.match(string.upper(FullName), "DA_HCECLASSIC_([A-Z]+)")
    if Name == nil then return nil, nil end
    for Index, Color in ipairs(WarthogCEColors) do
        if Color.Name == Name then return Index, Name end
    end
    return nil, Name
end

function ClassicArmorMenuPlayerIndex(Controller)
    Controller = Unwrap(Controller)
    local CandidateName = tostring(SafeFullName(Controller) or "")
    for PlayerIndex = 1, 2 do
        local Player = GetPlayer(PlayerIndex)
        if IsValidObject(Player) and CandidateName ~= "" and CandidateName == tostring(SafeFullName(Player) or "") then
            return PlayerIndex
        end
    end
    local ControllerId = nil
    pcall(function()
        if IsValidObject(Controller) and IsValidObject(Controller.Player) then
            ControllerId = tonumber(Unwrap(Controller.Player.ControllerId))
        end
    end)
    if ControllerId == 1 then return 2 end
    return 1
end

function ApplyClassicArmorSkin(PlayerIndex, ColorIndex, Source)
    PlayerIndex = tonumber(PlayerIndex) or 1
    ColorIndex = tonumber(ColorIndex)
    if ColorIndex == nil or ColorIndex < 1 or ColorIndex > #WarthogCEColors then return false end

    local Texture, TextureError = ArmorSkinLoadTexture(ColorIndex)
    if not IsValidObject(Texture) then
        Log("CLASSIC menu selection blocked color=%s error=%s", ArmorSkinColorLabel(ColorIndex), tostring(TextureError))
        return false
    end

    -- Keep the selection through the frontend-to-mission boundary. The runtime
    -- reset restores this value and the ordinary mission-ready reapply path then
    -- paints the newly constructed Default Spartan.
    ClassicArmorSetPersistentSelection(PlayerIndex, ColorIndex, Source or "Classic menu")

    if not MissionReady then
        Log("CLASSIC menu selected P%d color=%s source=%s state=deferred-until-mission",
            PlayerIndex, ArmorSkinColorLabel(ColorIndex), tostring(Source or "Classic menu"))
        return true
    end

    local DefaultOk, ModelChanged, Info = ArmorSkinEnsureDefaultModel(PlayerIndex, Source or "Classic menu")
    if not DefaultOk then
        Log("CLASSIC menu P%d apply deferred color=%s info=%s", PlayerIndex, ArmorSkinColorLabel(ColorIndex), tostring(Info))
        return false
    end
    ArmorSkinScheduleLocalApply(PlayerIndex, ColorIndex, Source or "Classic menu", ModelChanged)
    Log("CLASSIC menu applied P%d color=%s modelChanged=%s", PlayerIndex,
        ArmorSkinColorLabel(ColorIndex), tostring(ModelChanged == true))
    return true
end

function RegisterClassicArmorMenuActivationHook()
    if ClassicArmorMenuActivationHookReady then return true end
    local Ok, Err = pcall(function()
        RegisterHook(
            "/Game/UI/Frontend/Customization/Widgets/WBP_CustomizationList.WBP_CustomizationList_C:HandleItemActivated",
            function(Context, Controller, LocalUserIndex, Entry)
                if InternalApply then return end
                local ColorIndex, ColorName = ClassicArmorMenuColorIndex(Entry)
                local PlayerIndex = ClassicArmorMenuPlayerIndex(Controller)
                -- UE4SS hook parameter wrappers are transient. Keep only the
                -- object's stable full name across delayed callbacks, then resolve
                -- a fresh live UObject instead of retaining Context itself.
                local MenuKey = tostring(SafeFullName(Unwrap(Context)) or "")
                ClassicArmorMenuLastPlayerIndex = PlayerIndex
                if ColorIndex == nil then
                    local SkinName = ""
                    pcall(function() SkinName = string.lower(GetTagName(Unwrap(Entry).SkinGameplayTag) or "") end)
                    if string.find(SkinName, "blam.customization.masterchief.", 1, true) == 1 then
                        ClassicArmorSetPersistentSelection(PlayerIndex, 0, "normal armor menu selection")
                    end
                    return
                end

                -- Record the choice before the stock handler rebuilds selection from
                -- the shared Default tag. The delayed apply still owns persistence
                -- and the mission-side color overlay.
                ClassicArmorSetPersistentSelection(PlayerIndex, ColorIndex, "Classic menu activation")
                ExecuteInGameThreadWithDelay(120, function()
                    ApplyClassicArmorSkin(PlayerIndex, ColorIndex, "Classic menu " .. tostring(ColorName))
                end)
                for _, DelayMs in ipairs({ 160, 360, 900 }) do
                    ExecuteInGameThreadWithDelay(DelayMs, function()
                        local Menu = ClassicArmorFindLiveMenuByKey(MenuKey)
                        if IsValidObject(Menu) and ClassicArmorMenuIsArmor(Menu) then
                            ClassicArmorSyncMenuSelection(Menu, PlayerIndex, "Classic activation")
                        end
                    end)
                end
            end,
            function(Context, Controller, LocalUserIndex, Entry) end
        )
    end)
    if Ok then
        ClassicArmorMenuActivationHookReady = true
        Log("CLASSIC menu activation hook ready; free CE entries map to Default Spartan only")
        return true
    end
    Log("CLASSIC menu activation hook unavailable: %s", tostring(Err))
    return false
end

ClassicArmorMenuEntryPaths = {
    "/Game/Mods/HCEClassicArmor/Entries/DA_HCEClassic_BLACK",
    "/Game/Mods/HCEClassicArmor/Entries/DA_HCEClassic_RED",
    "/Game/Mods/HCEClassicArmor/Entries/DA_HCEClassic_BLUE",
    "/Game/Mods/HCEClassicArmor/Entries/DA_HCEClassic_GRAY",
    "/Game/Mods/HCEClassicArmor/Entries/DA_HCEClassic_YELLOW",
    "/Game/Mods/HCEClassicArmor/Entries/DA_HCEClassic_GREEN",
    "/Game/Mods/HCEClassicArmor/Entries/DA_HCEClassic_PINK",
    "/Game/Mods/HCEClassicArmor/Entries/DA_HCEClassic_PURPLE",
    "/Game/Mods/HCEClassicArmor/Entries/DA_HCEClassic_CYAN",
    "/Game/Mods/HCEClassicArmor/Entries/DA_HCEClassic_COBALT",
    "/Game/Mods/HCEClassicArmor/Entries/DA_HCEClassic_ORANGE",
    "/Game/Mods/HCEClassicArmor/Entries/DA_HCEClassic_TEAL",
    "/Game/Mods/HCEClassicArmor/Entries/DA_HCEClassic_SAGE",
    "/Game/Mods/HCEClassicArmor/Entries/DA_HCEClassic_BROWN",
    "/Game/Mods/HCEClassicArmor/Entries/DA_HCEClassic_TAN",
    "/Game/Mods/HCEClassicArmor/Entries/DA_HCEClassic_MAROON",
    "/Game/Mods/HCEClassicArmor/Entries/DA_HCEClassic_SALMON",
    "/Game/Mods/HCEClassicArmor/Entries/DA_HCEClassic_WHITE",
}
ClassicArmorMenuListListenerReady = ClassicArmorMenuListListenerReady or false
ClassicArmorMenuRefreshHookReady = ClassicArmorMenuRefreshHookReady or false
ClassicArmorMenuBlueprintRefreshHookReady = ClassicArmorMenuBlueprintRefreshHookReady or false
ClassicArmorMenuListResetHookReady = ClassicArmorMenuListResetHookReady or false
ClassicArmorMenuResetSignalQueued = ClassicArmorMenuResetSignalQueued or false
ClassicArmorMenuVisibilityHookReady = ClassicArmorMenuVisibilityHookReady or false
ClassicArmorMenuAddItemHookReady = ClassicArmorMenuAddItemHookReady or false
ClassicArmorMenuAddItemGuard = ClassicArmorMenuAddItemGuard or false
ClassicArmorMenuRefreshGeneration = ClassicArmorMenuRefreshGeneration or 0
ClassicArmorMenuInjectedByWidget = ClassicArmorMenuInjectedByWidget or {}
ClassicArmorMenuRefreshPendingByWidget = ClassicArmorMenuRefreshPendingByWidget or {}
ClassicArmorMenuEntryCache = ClassicArmorMenuEntryCache or {}

function ClassicLoadMenuEntry(Path)
    local Cached = ClassicArmorMenuEntryCache[Path]
    if IsValidObject(Cached) then return Cached, Path .. " (cached)" end
    local AssetName = string.match(tostring(Path or ""), "([^/]+)$")
    local Candidates = { Path }
    if AssetName ~= nil and AssetName ~= "" then
        Candidates[#Candidates + 1] = tostring(Path) .. "." .. AssetName
    end
    for _, Candidate in ipairs(Candidates) do
        local Entry = nil
        pcall(function() Entry = Unwrap(LoadAsset(Candidate)) end)
        if IsValidObject(Entry) then
            ClassicArmorMenuEntryCache[Path] = Entry
            return Entry, Candidate
        end
        pcall(function() Entry = Unwrap(StaticFindObject(Candidate)) end)
        if IsValidObject(Entry) then
            ClassicArmorMenuEntryCache[Path] = Entry
            return Entry, Candidate
        end
    end
    return nil, nil
end

function ClassicArmorListViewIsArmor(ListView)
    ListView = Unwrap(ListView)
    if not IsValidObject(ListView) then return false end
    local Items = nil
    local Ok = pcall(function() Items = ListView:GetListItems() end)
    if not Ok or Items == nil then return false end
    for _, Value in ipairs(ArrayValues(Items)) do
        local Entry = Unwrap(Value)
        local Skin = ""
        pcall(function() Skin = string.lower(GetTagName(Entry.SkinGameplayTag) or "") end)
        if string.find(Skin, "blam.customization.masterchief.", 1, true) == 1 then
            return true
        end
        if string.find(Skin, "blam.customization.", 1, true) == 1 then
            return false
        end
    end
    return false
end

function ClassicArmorMenuIsArmor(Menu)
    Menu = Unwrap(Menu)
    if not IsValidObject(Menu) then return false end
    local ListView = nil
    pcall(function() ListView = Unwrap(Menu.CustomizationListView) end)
    return ClassicArmorListViewIsArmor(ListView)
end

function ClassicArmorFindLiveMenuByKey(MenuKey)
    MenuKey = tostring(MenuKey or "")
    if MenuKey == "" then return nil end
    local Menus = FindAllOf("WBP_CustomizationList_C") or {}
    for _, RawMenu in ipairs(ArrayValues(Menus)) do
        local Menu = Unwrap(RawMenu)
        if IsValidObject(Menu) and tostring(SafeFullName(Menu) or "") == MenuKey then
            return Menu
        end
    end
    return nil
end

function ClassicMenuEntryDisplayName(Entry)
    local Name = ""
    pcall(function() Name = SafeToString(Unwrap(Entry).EntryName) end)
    return WeaponSkinFriendlyName(Name, "")
end

function ClassicMenuHasInjectedRows(ListView)
    local Items = nil
    local Ok = pcall(function() Items = ListView:GetListItems() end)
    if not Ok or Items == nil then return false end
    for _, Value in ipairs(ArrayValues(Items)) do
        local FullName = tostring(SafeFullName(Unwrap(Value)) or "")
        if string.find(FullName, "DA_HCEClassic_BLACK", 1, true) ~= nil then return true end
    end
    return false
end

function ClassicArmorEntryObjectKey(Entry)
    Entry = Unwrap(Entry)
    if not IsValidObject(Entry) then return "" end
    return tostring(SafeFullName(Entry) or "")
end

function ClassicArmorGetListItemObjectFromWidget(Widget)
    Widget = Unwrap(Widget)
    if not IsValidObject(Widget) then return nil, "widget unavailable" end

    local Library = nil
    pcall(function() Library = StaticFindObject("/Script/UMG.Default__UserObjectListEntryLibrary") end)
    if IsValidObject(Library) then
        local Item = nil
        local Ok = pcall(function() Item = Unwrap(Library:GetListItemObject(Widget)) end)
        if Ok and IsValidObject(Item) then return Item, "UserObjectListEntryLibrary" end
    end

    -- Blueprint wrappers sometimes expose the assigned object directly. Try a
    -- short allow-list rather than reflecting arbitrary fields every refresh.
    for _, Name in ipairs({"ListItemObject", "ItemObject", "ListItem", "Item", "Data", "EntryData"}) do
        local Item = nil
        pcall(function() Item = Unwrap(Widget[Name]) end)
        if IsValidObject(Item) then return Item, "Widget." .. Name end
    end
    return nil, "unresolved"
end

function ClassicArmorBuildDisplayedWidgetMap(ListView)
    ListView = Unwrap(ListView)
    local Map = {}
    if not IsValidObject(ListView) then return Map, 0, 0, "list unavailable" end
    local Widgets = nil
    local Route = "GetDisplayedEntryWidgets"
    local Ok = pcall(function() Widgets = ListView:GetDisplayedEntryWidgets() end)
    if not Ok or Widgets == nil then
        Route = "BP_GetDisplayedEntryWidgets"
        pcall(function() Widgets = ListView:BP_GetDisplayedEntryWidgets() end)
    end
    local Values = ArrayValues(Widgets)
    local Mapped = 0
    for _, RawWidget in ipairs(Values) do
        local Widget = Unwrap(RawWidget)
        if IsValidObject(Widget) then
            local Item, ItemRoute = ClassicArmorGetListItemObjectFromWidget(Widget)
            local Key = ClassicArmorEntryObjectKey(Item)
            if Key ~= "" then
                Map[Key] = Widget
                Map[Key .. "#route"] = ItemRoute
                Mapped = Mapped + 1
            end
        end
    end
    return Map, #Values, Mapped, Route
end

function ClassicArmorCheckmarkChildCandidates(Widget)
    Widget = Unwrap(Widget)
    local Result, Seen = {}, {}
    if not IsValidObject(Widget) then return Result end

    local function Add(Value, Why)
        Value = Unwrap(Value)
        if not IsValidObject(Value) then return end
        local Key = tostring(SafeFullName(Value) or tostring(Value))
        if Seen[Key] then return end
        Seen[Key] = true
        Result[#Result + 1] = { Widget = Value, Why = Why }
    end

    -- Common authored names first, even if WidgetTree enumeration is unavailable.
    for _, Name in ipairs({"Equipped", "EquippedIcon", "EquippedImage", "EquippedIndicator",
                           "Checkmark", "CheckMark", "CheckmarkImage", "CheckImage", "Image_Equipped"}) do
        local Value = nil
        pcall(function() Value = Widget[Name] end)
        if IsValidObject(Value) then Add(Value, "field:" .. Name) end
    end

    local Tree = nil
    pcall(function() Tree = Unwrap(Widget.WidgetTree) end)
    local Children = nil
    if IsValidObject(Tree) then pcall(function() Children = Tree:GetAllWidgets() end) end
    for I, RawChild in ipairs(ArrayValues(Children)) do
        if I > 128 then break end
        local Child = Unwrap(RawChild)
        if IsValidObject(Child) then
            local Desc = string.lower(ArmorSkinObjectDescriptionForDetection(Child))
            local LooksLikeCheck = string.find(Desc, "equip", 1, true) ~= nil
                or string.find(Desc, "checkmark", 1, true) ~= nil
                or string.find(Desc, "check_mark", 1, true) ~= nil
                or string.find(Desc, "checkimage", 1, true) ~= nil
            if LooksLikeCheck then Add(Child, "tree-name") end
        end
    end
    return Result
end

function ClassicArmorForceCheckmarkVisual(Widget, Wanted)
    Widget = Unwrap(Widget)
    if not IsValidObject(Widget) then return 0 end
    local Count = 0
    local Visibility = Wanted and 0 or 1 -- ESlateVisibility Visible / Collapsed
    local Opacity = Wanted and 1.0 or 0.0
    for _, Candidate in ipairs(ClassicArmorCheckmarkChildCandidates(Widget)) do
        local Child = Unwrap(Candidate.Widget)
        local Changed = false
        if IsValidObject(Child) then
            local Ok = pcall(function() Child:SetVisibility(Visibility) end)
            Changed = Changed or Ok
            Ok = pcall(function() Child:SetRenderOpacity(Opacity) end)
            Changed = Changed or Ok
            Ok = pcall(function() Child:SetIsChecked(Wanted) end)
            Changed = Changed or Ok
        end
        if Changed then Count = Count + 1 end
    end
    return Count
end

function ClassicArmorSetEntryVisualSelected(ListView, Entry, Selected, DisplayedMap)
    ListView = Unwrap(ListView)
    Entry = Unwrap(Entry)
    if not IsValidObject(ListView) or not IsValidObject(Entry) then return false, 0, "invalid" end
    local EntryKey = ClassicArmorEntryObjectKey(Entry)
    local Widget = nil
    local Route = "BP_GetEntryWidgetFromItem"
    pcall(function() Widget = Unwrap(ListView:BP_GetEntryWidgetFromItem(Entry)) end)
    if not IsValidObject(Widget) then
        Route = "GetEntryWidgetFromItem"
        pcall(function() Widget = Unwrap(ListView:GetEntryWidgetFromItem(Entry)) end)
    end
    if not IsValidObject(Widget) and type(DisplayedMap) == "table" then
        Widget = Unwrap(DisplayedMap[EntryKey])
        Route = tostring(DisplayedMap[EntryKey .. "#route"] or "displayed-widget-map")
    end
    if not IsValidObject(Widget) then return false, 0, "widget-not-materialized" end

    local Wanted = Selected == true
    local Applied = false
    local Ok = pcall(function() Widget:BP_OnItemSelectionChanged(Wanted) end)
    Applied = Applied or Ok
    Ok = pcall(function() Widget:SetIsSelected(Wanted) end)
    Applied = Applied or Ok
    if not Ok then
        Ok = pcall(function() Widget:SetIsSelected(Wanted, false) end)
        Applied = Applied or Ok
    end
    Ok = pcall(function() Widget:SetIsEquipped(Wanted) end)
    Applied = Applied or Ok
    Ok = pcall(function() Widget:SetEquipped(Wanted) end)
    Applied = Applied or Ok
    Ok = pcall(function() Widget:BP_SetEquipped(Wanted) end)
    Applied = Applied or Ok

    -- The game's actual equipped Spartan remains Default green, so its stock
    -- equipped indicator is expected to say green even though our Classic color
    -- is a texture-only overlay. Explicitly mirror the remembered color onto the
    -- visible check/equipped child and hide it on the stock Default row.
    local Forced = ClassicArmorForceCheckmarkVisual(Widget, Wanted)
    return Applied or Forced > 0, Forced, Route
end

function ClassicArmorReplayExactSelection(Menu, PlayerIndex, TargetEntry, Source)
    if ClassicArmorMenuReplayGuard or ModTeardownGuard then return false, "guarded" end
    Menu = Unwrap(Menu)
    TargetEntry = Unwrap(TargetEntry)
    PlayerIndex = tonumber(PlayerIndex) or 1
    if not IsValidObject(Menu) or not IsValidObject(TargetEntry) then return false, "invalid menu/entry" end

    local ColorIndex = ClassicArmorMenuColorIndex(TargetEntry)
    if ColorIndex == nil then return false, "not a Classic row" end
    local MenuKey = tostring(SafeFullName(Menu) or "")
    if MenuKey == "" then return false, "menu key unavailable" end
    if tonumber(ClassicArmorMenuReplayByWidget[MenuKey]) == tonumber(ColorIndex) then
        return true, "already-replayed"
    end

    local Controller = GetPlayer(PlayerIndex)
    if not IsValidObject(Controller) then return false, "player controller unavailable" end
    local LocalUserIndex = math.max(0, PlayerIndex - 1)
    local WasInternalApply = InternalApply == true
    ClassicArmorMenuReplayGuard = true
    InternalApply = true
    local Started = os.clock()
    local Ok, Err = pcall(function()
        Menu:HandleItemActivated(Controller, LocalUserIndex, TargetEntry)
    end)
    InternalApply = WasInternalApply
    ClassicArmorMenuReplayGuard = false
    local ElapsedMs = (os.clock() - Started) * 1000.0

    if Ok then
        ClassicArmorMenuReplayByWidget[MenuKey] = ColorIndex
        ClassicArmorMenuPostReplayTokenByWidget[MenuKey] = (tonumber(ClassicArmorMenuPostReplayTokenByWidget[MenuKey]) or 0) + 1
        local CleanupToken = ClassicArmorMenuPostReplayTokenByWidget[MenuKey]
        for _, DelayMs in ipairs({ 45, 140, 360 }) do
            local ThisDelay = DelayMs
            ExecuteInGameThreadWithDelay(ThisDelay, function()
                if ModTeardownGuard or ClassicArmorMenuPostReplayTokenByWidget[MenuKey] ~= CleanupToken then return end
                if tonumber(ClassicArmorMenuSelectedByPlayer[PlayerIndex]) ~= tonumber(ColorIndex) then return end
                local LiveMenu = ClassicArmorFindLiveMenuByKey(MenuKey)
                if IsValidObject(LiveMenu) and ClassicArmorMenuIsArmor(LiveMenu) then
                    ClassicArmorSyncMenuSelection(LiveMenu, PlayerIndex,
                        string.format("post-replay check cleanup +%dms", ThisDelay))
                end
            end)
        end
        Log("CLASSIC exact activation replay P%d color=%s source=%s result=ok %.2fms",
            PlayerIndex, ArmorSkinColorLabel(ColorIndex), tostring(Source or "menu restore"), ElapsedMs)
        return true, "ok"
    end
    Log("CLASSIC exact activation replay P%d color=%s source=%s result=failed error=%s",
        PlayerIndex, ArmorSkinColorLabel(ColorIndex), tostring(Source or "menu restore"), tostring(Err))
    return false, tostring(Err)
end

function ClassicArmorSyncMenuSelection(Menu, PlayerIndex, Source)
    if ClassicArmorMenuSelectionSyncGuard or ModTeardownGuard then return false end
    Menu = Unwrap(Menu)
    if not IsValidObject(Menu) then return false end

    PlayerIndex = tonumber(PlayerIndex) or tonumber(ClassicArmorMenuLastPlayerIndex) or 1
    local ColorIndex = tonumber(ClassicArmorMenuSelectedByPlayer[PlayerIndex]) or 0
    if ColorIndex < 1 or ColorIndex > #WarthogCEColors then return false end

    local ListView = nil
    pcall(function() ListView = Unwrap(Menu.CustomizationListView) end)
    if not IsValidObject(ListView) then return false end

    local Items = nil
    local ItemsOk = pcall(function() Items = ListView:GetListItems() end)
    if not ItemsOk or Items == nil then return false end

    local TargetEntry = nil
    for _, Value in ipairs(ArrayValues(Items)) do
        local Entry = Unwrap(Value)
        local EntryColorIndex = ClassicArmorMenuColorIndex(Entry)
        if EntryColorIndex == ColorIndex then
            TargetEntry = Entry
            break
        end
    end
    if not IsValidObject(TargetEntry) then return false end

    -- The stock Mark V and Classic rows intentionally share the Default gameplay
    -- tag. Do not ClearSelection: that old clear/select pair exposed a Premium
    -- preview for a frame. Instead explicitly deselect only the competing Default
    -- rows, then select the exact Classic UObject. This makes UListView emit the
    -- normal per-entry selection-change event used by Halo's row Blueprint.
    local TargetKey = tostring(SafeFullName(TargetEntry) or "")
    ClassicArmorMenuSelectionSyncGuard = true
    for _, Value in ipairs(ArrayValues(Items)) do
        local Entry = Unwrap(Value)
        local Skin = ""
        pcall(function() Skin = string.lower(GetTagName(Entry.SkinGameplayTag) or "") end)
        if Skin == "blam.customization.masterchief.default" then
            local EntryKey = tostring(SafeFullName(Entry) or "")
            if EntryKey ~= TargetKey then
                pcall(function() ListView:BP_SetItemSelection(Entry, false) end)
            end
        end
    end
    local SelectOk, SelectErr = pcall(function() ListView:BP_SetItemSelection(TargetEntry, true) end)
    if not SelectOk then
        SelectOk, SelectErr = pcall(function() ListView:BP_SetSelectedItem(TargetEntry) end)
    end
    pcall(function() ListView:RequestScrollItemIntoView(TargetEntry) end)
    ClassicArmorMenuSelectionSyncGuard = false

    if not SelectOk then
        Log("CLASSIC menu selection sync failed source=%s select=%s",
            tostring(Source or "menu refresh"), tostring(SelectErr))
        return false
    end

    -- The remembered Classic color is authoritative for the UI. Gameplay must
    -- remain the real Default Spartan, so the stock equipped-state resolver will
    -- otherwise keep its checkmark on green forever. Build a live map of the
    -- materialized row widgets and explicitly move that visual indicator.
    local DisplayedMap, DisplayedCount, DisplayedMapped, DisplayRoute = ClassicArmorBuildDisplayedWidgetMap(ListView)
    local VisualRows, VisualUpdated, CheckForced = 0, 0, 0
    for _, Value in ipairs(ArrayValues(Items)) do
        local Entry = Unwrap(Value)
        local Skin = ""
        pcall(function() Skin = string.lower(GetTagName(Entry.SkinGameplayTag) or "") end)
        if Skin == "blam.customization.masterchief.default" then
            local EntryKey = tostring(SafeFullName(Entry) or "")
            VisualRows = VisualRows + 1
            local Updated, Forced = ClassicArmorSetEntryVisualSelected(ListView, Entry, EntryKey == TargetKey, DisplayedMap)
            if Updated then VisualUpdated = VisualUpdated + 1 end
            CheckForced = CheckForced + (tonumber(Forced) or 0)
        end
    end
    local ReplayStatus = "skipped"
    local SourceLower = string.lower(tostring(Source or ""))
    if string.find(SourceLower, "classic activation", 1, true) == nil then
        local TargetMapKey = ClassicArmorEntryObjectKey(TargetEntry)
        local TargetWidget = type(DisplayedMap) == "table" and Unwrap(DisplayedMap[TargetMapKey]) or nil
        if IsValidObject(TargetWidget) then
            local ReplayOk, ReplayInfo = ClassicArmorReplayExactSelection(Menu, PlayerIndex, TargetEntry, Source)
            ReplayStatus = ReplayOk and tostring(ReplayInfo or "ok") or ("failed:" .. tostring(ReplayInfo or "unknown"))
        else
            ReplayStatus = "waiting-target-widget"
        end
    else
        ReplayStatus = "manual-activation"
    end

    Log("CLASSIC menu selection sync source=%s P%d color=%s defaultRows=%d visualUpdated=%d checkForced=%d displayed=%d mapped=%d route=%s replay=%s",
        tostring(Source or "menu refresh"), PlayerIndex, ArmorSkinColorLabel(ColorIndex), VisualRows, VisualUpdated,
        CheckForced, DisplayedCount, DisplayedMapped, tostring(DisplayRoute or "unknown"), tostring(ReplayStatus))
    return true
end

function ClassicArmorInjectMenuRows(Menu)
    Menu = Unwrap(Menu)
    if not IsValidObject(Menu) then return false end
    local MenuKey = tostring(SafeFullName(Menu) or "")
    if MenuKey == "" or ClassicArmorMenuInjectedByWidget[MenuKey] == "failed" then return false end

    local ListView = nil
    pcall(function() ListView = Unwrap(Menu.CustomizationListView) end)
    if not IsValidObject(ListView) then
        Log("CLASSIC menu rows waiting: CustomizationListView not ready")
        return false
    end
    if not ClassicArmorListViewIsArmor(ListView) then return false end
    if ClassicMenuHasInjectedRows(ListView) then
        ClassicArmorMenuInjectedByWidget[MenuKey] = true
        ClassicArmorSyncMenuSelection(Menu, ClassicArmorMenuLastPlayerIndex, "existing rows")
        return true
    end
    if ClassicArmorMenuInjectedByWidget[MenuKey] == true then
        ClassicArmorMenuInjectedByWidget[MenuKey] = nil
        Log("CLASSIC menu rows were reset by the stock widget; reinserting safely")
    end

    local Entries = {}
    for _, Path in ipairs(ClassicArmorMenuEntryPaths) do
        local Entry, ResolvedPath = ClassicLoadMenuEntry(Path)
        if not IsValidObject(Entry) then
            Log("CLASSIC menu rows waiting: not mounted/cooked %s", tostring(Path))
            return false
        end
        Log("CLASSIC menu asset resolved: %s", tostring(ResolvedPath))
        Entries[#Entries + 1] = Entry
    end

    -- UListView's native ClearListItems path invalidates live entries in this
    -- game build. Append only: it is stable and never mutates stock UI objects.
    local Added = 0
    for _, Entry in ipairs(Entries) do
        local Ok, Err = pcall(function() ListView:AddItem(Entry) end)
        if not Ok then
            ClassicArmorMenuInjectedByWidget[MenuKey] = "failed"
            Log("CLASSIC menu row add failed after %d rows: %s", Added, tostring(Err))
            return false
        end
        Added = Added + 1
    end
    ClassicArmorMenuInjectedByWidget[MenuKey] = true
    ClassicArmorSyncMenuSelection(Menu, ClassicArmorMenuLastPlayerIndex, "rows added")
    Log("CLASSIC menu rows added=%d; stock Owned and Premium lists were left unchanged", Added)
    return true
end

function ClassicArmorMenuContextIsMenu(Context)
    local Name = tostring(SafeFullName(Unwrap(Context)) or "")
    return string.find(Name, "WBP_CustomizationList_C", 1, true) ~= nil
end

function QueueClassicArmorMenuRefreshSignal(Source)
    if ClassicArmorMenuResetSignalQueued or ModTeardownGuard then return end
    ClassicArmorMenuResetSignalQueued = true
    ExecuteInGameThreadWithDelay(40, function()
        ClassicArmorMenuResetSignalQueued = false
        if ModTeardownGuard then return end
        local Menu = FindCustomizationList()
        if IsValidObject(Menu) then
            ScheduleClassicArmorMenuRefresh(Menu, Source or "Customization visibility change")
        end
    end)
end

function ClassicArmorInsertRowsBeforePremium(ListView)
    ListView = Unwrap(ListView)
    if ClassicArmorMenuAddItemGuard or not IsValidObject(ListView) then return false end
    if not ClassicArmorListViewIsArmor(ListView) then return false end
    local Menu = ClassicArmorMenuForListView(ListView)
    local MenuKey = tostring(SafeFullName(Menu) or "")
    if ClassicMenuHasInjectedRows(ListView) then
        if MenuKey ~= "" then ClassicArmorMenuInjectedByWidget[MenuKey] = true end
        return true
    end

    local Entries = {}
    for _, Path in ipairs(ClassicArmorMenuEntryPaths) do
        local Entry = ClassicLoadMenuEntry(Path)
        if not IsValidObject(Entry) then
            Log("CLASSIC owned insert waiting: not mounted/cooked %s", tostring(Path))
            return false
        end
        Entries[#Entries + 1] = Entry
    end

    ClassicArmorMenuAddItemGuard = true
    local Added = 0
    for _, Entry in ipairs(Entries) do
        local Ok, Err = pcall(function() ListView:AddItem(Entry) end)
        if not Ok then
            ClassicArmorMenuAddItemGuard = false
            Log("CLASSIC owned insert failed after %d rows: %s", Added, tostring(Err))
            return false
        end
        Added = Added + 1
    end
    ClassicArmorMenuAddItemGuard = false
    if IsValidObject(Menu) then
        local RestorePlayer = tonumber(ClassicArmorMenuLastPlayerIndex) or 1
        local RestoreColor = tonumber(ClassicArmorMenuSelectedByPlayer[RestorePlayer]) or 0
        if MenuKey ~= "" then
            ClassicArmorMenuInjectedByWidget[MenuKey] = true
            -- RC3_28: AddItem-after-stock means the list has just been rebuilt.
            -- A replay cached for the previous realization of this same menu
            -- widget is no longer sufficient: newly materialized Default rows can
            -- ask Halo's stock equipped resolver again and resurrect the green
            -- checkmark. Invalidate only the exact-replay cache for this rebuilt
            -- list, then allow one fresh exact activation once the remembered
            -- Classic target row becomes a live widget.
            ClassicArmorMenuReplayByWidget[MenuKey] = nil
            ClassicArmorMenuPostReplayTokenByWidget[MenuKey] =
                (tonumber(ClassicArmorMenuPostReplayTokenByWidget[MenuKey]) or 0) + 1
        end

        ClassicArmorSyncMenuSelection(Menu, RestorePlayer, "Owned rows inserted")

        -- During frontend-only navigation the target Classic row is often not
        -- materialized yet on the exact frame where the 18 rows are appended.
        -- RC3_27 therefore logged replay=waiting-target-widget and then got no
        -- later lifecycle signal before the user returned to the list. Schedule
        -- a small bounded settle sequence directly from the rebuild itself. The
        -- first pass that sees the target widget performs the exact stock
        -- HandleItemActivated replay; later passes are idempotent via the cache.
        if RestoreColor >= 1 and RestoreColor <= #WarthogCEColors and MenuKey ~= "" then
            for _, DelayMs in ipairs({ 90, 240, 520, 950 }) do
                local ThisDelay = DelayMs
                ExecuteInGameThreadWithDelay(ThisDelay, function()
                    if ModTeardownGuard then return end
                    if tonumber(ClassicArmorMenuSelectedByPlayer[RestorePlayer]) ~= RestoreColor then return end
                    local LiveMenu = ClassicArmorFindLiveMenuByKey(MenuKey)
                    if IsValidObject(LiveMenu) and ClassicArmorMenuIsArmor(LiveMenu) then
                        ClassicArmorSyncMenuSelection(LiveMenu, RestorePlayer,
                            string.format("post-insert exact restore +%dms", ThisDelay))
                    end
                end)
            end
        end
    end
    Log("CLASSIC menu rows inserted under Owned before Premium=%d", Added)
    return true
end

function RegisterClassicArmorMenuRepairHooks()
    -- SetVisibility fires continuously while the customization screen animates
    -- and previously queued hundreds of refresh generations. Construction,
    -- activation, and AddItem-before-Premium provide bounded lifecycle signals.
    ClassicArmorMenuVisibilityHookReady = false

    if not ClassicArmorMenuAddItemHookReady then
        local Ok, Err = pcall(function()
            RegisterHook(
                "/Script/UMG.ListView:AddItem",
                function(Context, Entry)
                    if ClassicArmorMenuAddItemGuard then return end
                    local ListView = Unwrap(Context)
                    if not IsValidObject(ClassicArmorMenuForListView(ListView)) then return end
                    local Name = string.lower(ClassicMenuEntryDisplayName(Entry))
                    if Name == "available for purchase" then
                        ClassicArmorInsertRowsBeforePremium(ListView)
                    end
                end,
                function(Context, Entry) end
            )
        end)
        if Ok then
            ClassicArmorMenuAddItemHookReady = true
            Log("CLASSIC menu Owned-order hook ready")
        else
            Log("CLASSIC menu Owned-order hook unavailable: %s", tostring(Err))
        end
    end
    return ClassicArmorMenuVisibilityHookReady or ClassicArmorMenuAddItemHookReady
end

function RegisterClassicArmorMenuRefreshHook()
    if ClassicArmorMenuRefreshHookReady then return true end
    local Ok, Err = pcall(function()
        RegisterHook(
            "/Script/CommonUI.CommonActivatableWidget:BP_OnActivated",
            function(Context, ...) end,
            function(Context, ...)
                local Menu = Unwrap(Context)
                local FullName = tostring(SafeFullName(Menu) or "")
                if string.find(FullName, "WBP_CustomizationList_C", 1, true) == nil then return end
                ScheduleClassicArmorMenuRefresh(Menu, "CommonActivatableWidget activation")
            end
        )
    end)
    if Ok then
        ClassicArmorMenuRefreshHookReady = true
        Log("CLASSIC menu refresh hook ready")
        return true
    end
    Log("CLASSIC menu refresh hook unavailable: %s", tostring(Err))
    return false
end

function ScheduleClassicArmorMenuRefresh(Menu, Source)
    Menu = Unwrap(Menu)
    if not IsValidObject(Menu) then return end
    local MenuKey = tostring(SafeFullName(Menu) or "")
    if MenuKey == "" or ClassicArmorMenuRefreshPendingByWidget[MenuKey] then return end
    ClassicArmorMenuRefreshPendingByWidget[MenuKey] = true
    -- Match the proven Controller Settings repair pattern. The stock list can
    -- rebuild more than once after activation, so each real UI signal owns a
    -- bounded callback generation rather than a permanent scan.
    ClassicArmorMenuRefreshGeneration = ClassicArmorMenuRefreshGeneration + 1
    local Generation = ClassicArmorMenuRefreshGeneration
    Log("CLASSIC menu refresh scheduled by %s generation=%d", tostring(Source or "UI event"), Generation)
    for _, DelayMs in ipairs({ 80, 300, 900, 1600 }) do
        ExecuteInGameThreadWithDelay(DelayMs, function()
            if ModTeardownGuard then return end
            local LiveMenu = ClassicArmorFindLiveMenuByKey(MenuKey)
            if IsValidObject(LiveMenu) then ClassicArmorInjectMenuRows(LiveMenu) end
        end)
    end
    ExecuteInGameThreadWithDelay(1700, function()
        ClassicArmorMenuRefreshPendingByWidget[MenuKey] = nil
    end)
end

function TryRegisterClassicArmorMenuBlueprintRefreshHook(Quiet)
    if ClassicArmorMenuBlueprintRefreshHookReady then return true end
    local Ok, Err = pcall(function()
        RegisterHook(
            "/Game/UI/Frontend/Customization/Widgets/WBP_CustomizationList.WBP_CustomizationList_C:BP_OnActivated",
            function(Context, ...) end,
            function(Context, ...)
                ScheduleClassicArmorMenuRefresh(Unwrap(Context), "WBP_CustomizationList_C.BP_OnActivated")
            end
        )
    end)
    if Ok then
        ClassicArmorMenuBlueprintRefreshHookReady = true
        Log("CLASSIC menu exact BP_OnActivated hook ready")
        return true
    end
    if not Quiet then Log("CLASSIC menu exact BP_OnActivated hook unavailable: %s", tostring(Err)) end
    return false
end

function ClassicArmorMenuForListView(ListView)
    ListView = Unwrap(ListView)
    if not IsValidObject(ListView) then return nil end
    local ListKey = tostring(SafeFullName(ListView) or "")
    if ListKey == "" then return nil end
    local Menus = FindAllOf("WBP_CustomizationList_C") or {}
    for _, RawMenu in ipairs(ArrayValues(Menus)) do
        local Menu = Unwrap(RawMenu)
        if IsValidObject(Menu) then
            local Candidate = nil
            pcall(function() Candidate = Unwrap(Menu.CustomizationListView) end)
            if IsValidObject(Candidate) and tostring(SafeFullName(Candidate) or "") == ListKey then
                return Menu
            end
        end
    end
    return nil
end

function QueueClassicArmorMenuResetRefresh(ListView, Source)
    if ClassicArmorMenuResetSignalQueued or ModTeardownGuard then return end
    local Menu = ClassicArmorMenuForListView(ListView)
    if not IsValidObject(Menu) then return end
    ClassicArmorMenuResetSignalQueued = true
    ExecuteInGameThreadWithDelay(40, function()
        ClassicArmorMenuResetSignalQueued = false
        if ModTeardownGuard then return end
        ScheduleClassicArmorMenuRefresh(Menu, Source)
    end)
end

function RegisterClassicArmorMenuListResetHooks()
    if ClassicArmorMenuListResetHookReady then return true end
    local Registered = false
    for _, FunctionPath in ipairs({
        "/Script/UMG.ListViewBase:ClearListItems",
        "/Script/UMG.ListView:SetListItems",
    }) do
        local HookPath = FunctionPath
        local Ok, Err = pcall(function()
            RegisterHook(
                HookPath,
                function(Context, ...) end,
                function(Context, ...)
                    QueueClassicArmorMenuResetRefresh(Unwrap(Context), HookPath)
                end
            )
        end)
        if Ok then
            Registered = true
            Log("CLASSIC menu list-reset hook ready: %s", HookPath)
        else
            Log("CLASSIC menu list-reset hook unavailable: %s (%s)", HookPath, tostring(Err))
        end
    end
    ClassicArmorMenuListResetHookReady = Registered
    return Registered
end

function RegisterClassicArmorMenuListListener()
    if ClassicArmorMenuListListenerReady then return true end
    local Ok, Err = pcall(function()
        NotifyOnNewObject(
            "/Game/UI/Frontend/Customization/Widgets/WBP_CustomizationList.WBP_CustomizationList_C",
            function(Menu)
                -- The Blueprint function becomes hookable only after its first
                -- live instance on some Modkit/game builds.
                RegisterClassicArmorMenuActivationHook()
                TryRegisterClassicArmorMenuBlueprintRefreshHook(true)
                ScheduleClassicArmorMenuRefresh(Menu, "WBP_CustomizationList_C construction")
            end
        )
    end)
    if Ok then
        ClassicArmorMenuListListenerReady = true
        RegisterClassicArmorMenuRefreshHook()
        RegisterClassicArmorMenuListResetHooks()
        RegisterClassicArmorMenuRepairHooks()
        Log("CLASSIC menu list listener ready")
        return true
    end
    Log("CLASSIC menu list listener unavailable: %s", tostring(Err))
    return false
end

function CycleContextColor(PlayerIndex, Delta, Source)
    local InVehicle, VehicleInfo = ArmorSkinPlayerInAnyVehicle(PlayerIndex)
    if InVehicle then
        Log("COLOR INPUT P%d context=vehicle route=%s source=%s", PlayerIndex, tostring(VehicleInfo), tostring(Source))
        return CycleOccupiedVehicleColor(PlayerIndex, Delta, Source)
    end
    Log("COLOR INPUT P%d context=on-foot armor-skin source=%s", PlayerIndex, tostring(Source))
    return CycleDefaultSpartanSkin(PlayerIndex, Delta, Source)
end

function ArmorSkinMaintenanceTick(PlayerIndex)
    if not MissionReady then return end

    -- RC3_56: ReceiveTick still calls this every frame, but the armor watchdog
    -- must not do UObject/component work every few dozen frames. Presentation
    -- changes are event-driven via NotifyOnNewObject; this is only a slow safety
    -- net for missed lifecycle events and late FP-arms publication.
    local Now=os.clock()
    if (tonumber(ArmorSkinBipedWriteQuietUntilClock) or 0) > Now then return end
    ArmorSkinMaintenanceNextClock=ArmorSkinMaintenanceNextClock or { [1]=0, [2]=0 }
    ArmorSkinPairVectorNextReadyCheckClock=tonumber(ArmorSkinPairVectorNextReadyCheckClock) or 0

    local ColorIndex = tonumber(ArmorSkinLocalIndexByPlayer[PlayerIndex]) or 0
    if ColorIndex <= 0 then return end
    -- V12: network Classic is event/input driven only. V11 still fell through to
    -- ArmorSkinFirstPersonAnchor/Pawn component scans every 2.5s after respawn,
    -- defeating the TP-only isolation and keeping risky UObject refs alive.
    if VehicleMessageOfflineFastPath ~= true then
        return
    end
    if Now < (tonumber(ArmorSkinMaintenanceNextClock[PlayerIndex]) or 0) then return end
    ArmorSkinMaintenanceNextClock[PlayerIndex]=Now+2.5

    local Controller = GetPlayer(PlayerIndex)
    local Pawn = ArmorSkinGetPawnFromController(Controller)
    if not IsValidObject(Pawn) then return end
    local PlayerId = ArmorSkinPlayerIdFromController(Controller)
    local TargetKey = ArmorSkinTargetKey(PlayerId, PlayerIndex)
    local State = ArmorSkinAppliedByTarget[TargetKey]
    local Biped = ArmorSkinFindThirdPersonBiped(Pawn)
    if not IsValidObject(Biped) then return end

    local BipedKey = ArmorSkinObjectKey(Biped)
    local StateBipedKey = nil
    if type(State) == "table" then
        StateBipedKey = State.BipedKey or ArmorSkinObjectKey(State.Biped)
    end
    if type(State) ~= "table" or BipedKey == nil or StateBipedKey ~= BipedKey then
        ArmorSkinScheduleLocalApply(PlayerIndex, ColorIndex, "lightweight biped watchdog", true)
        return
    end

    local Arms, ArmsKey, ArmsRoute = ArmorSkinFirstPersonAnchor(Pawn)
    local FirstPersonCount = ArmorSkinStateFirstPersonCount(State)
    local ArmsChanged = IsValidObject(Arms) and ArmsKey ~= nil and State.FirstPersonArmsKey ~= nil
        and tostring(ArmsKey) ~= tostring(State.FirstPersonArmsKey)
    local ArmsMissingFromState = IsValidObject(Arms) and FirstPersonCount <= 0
    if ArmsChanged or ArmsMissingFromState then
        local Retry = ArmorSkinFirstPersonRetryByTarget[TargetKey] or { Attempts = 0, NextClock = 0 }
        if Now >= (tonumber(Retry.NextClock) or 0) then
            Retry.Attempts = (tonumber(Retry.Attempts) or 0) + 1
            local BackoffSeconds = { 2, 4, 8, 16 }
            local DelaySeconds = BackoffSeconds[math.min(Retry.Attempts, #BackoffSeconds)] or 16
            Retry.NextClock = Now + DelaySeconds
            ArmorSkinFirstPersonRetryByTarget[TargetKey] = Retry
            Log("ARMORSKIN first-person repair P%d attempt=%d reason=%s nextRetry=%.1fs arms=%s",
                PlayerIndex, Retry.Attempts, ArmsChanged and "arms-instance-changed" or "missing-first-person-MID",
                DelaySeconds, tostring((ArmsKey or "unavailable") .. " route=" .. tostring(ArmsRoute or "unavailable")))
            ArmorSkinScheduleLocalApply(PlayerIndex, ColorIndex, "first-person arms lightweight repair", false)
        end
    else
        ArmorSkinFirstPersonRetryByTarget[TargetKey] = nil
        -- Binding drift is intentionally sampled only by this 2.5s watchdog, not
        -- every 25 frames. Check FP items only; TP lifecycle has its own event.
        local Detached = 0
        for _, Item in ipairs(State.Items or {}) do
            local ScopeLower = string.lower(tostring(Item.Scope or ""))
            if string.find(ScopeLower, "first-person", 1, true) == 1
                and IsValidObject(Item.Component) and IsValidObject(Item.MID) then
                local CurrentMaterial = nil
                pcall(function() CurrentMaterial = Unwrap(Item.Component:GetMaterial(Item.Slot)) end)
                local CurrentKey = ArmorSkinObjectKey(CurrentMaterial)
                local MidKey = ArmorSkinObjectKey(Item.MID)
                if CurrentKey == nil or MidKey == nil or tostring(CurrentKey) ~= tostring(MidKey) then
                    Detached = Detached + 1
                end
            end
        end
        if Detached > 0 and PerspectiveThirdPerson[PlayerIndex] ~= true then
            Log("ARMORSKIN first-person binding drift P%d detached=%d; scheduling MID rebind", PlayerIndex, Detached)
            ArmorSkinSchedulePerspectiveFirstPersonRebind(PlayerIndex, "lightweight watchdog binding drift")
        end
    end
end

function ArmorSkinScheduleTrackedReapply(Reason)
    local RuntimeGeneration = WarthogColorRuntimeGeneration
    ExecuteInGameThreadWithDelay(350, function()
        if ModTeardownGuard or RuntimeGeneration ~= WarthogColorRuntimeGeneration or not MissionReady then return end
        if ArmorSkinPersistentRestoreRemoteStates ~= nil then
            ArmorSkinPersistentRestoreRemoteStates(Reason or "tracked reapply")
        end
        if ArmorSkinScheduleMissionCarryRemoteReapply ~= nil then
            ArmorSkinScheduleMissionCarryRemoteReapply(Reason or "tracked reapply")
        end
        for PlayerIndex = 1, 2 do
            local ColorIndex = tonumber(ArmorSkinLocalIndexByPlayer[PlayerIndex]) or 0
            if ColorIndex > 0 and IsValidObject(GetPlayer(PlayerIndex)) then
                ArmorSkinScheduleLocalApply(PlayerIndex, ColorIndex, Reason or "mission ready", true)
            end
        end
        for Key, ColorIndex in pairs(ArmorSkinNetworkColorByPlayerId or {}) do
            local PlayerId = tonumber(Key)
            if PlayerId ~= nil and tonumber(ColorIndex) ~= nil and tonumber(ColorIndex) > 0 then
                ArmorSkinScheduleNetworkApply(PlayerId, tonumber(ColorIndex), Reason or "mission ready")
            end
        end
    end)
end

function ArmorSkinScheduleRespawnRemoteIdentityRetry(Source)
    ArmorSkinRespawnIdentityRetryToken=(tonumber(ArmorSkinRespawnIdentityRetryToken) or 0)+1
    local Token=ArmorSkinRespawnIdentityRetryToken
    local Generation=tonumber(WarthogColorRuntimeGeneration) or 0
    ArmorSkinRespawnIdentitySettledGeneration=-1
    -- Identity-only retries are intentionally sparse. They touch no material until
    -- the pair-vector becomes decisive, so waiting for remote presentation actors
    -- to settle costs only two position reads plus the bounded resolver.
    local Delays={2500,6000,11000,17000,24000}
    for _,Delay in ipairs(Delays) do
        local D=Delay
        ExecuteInGameThreadWithDelay(D,function()
            if Token~=ArmorSkinRespawnIdentityRetryToken or ModTeardownGuard or not MissionReady
                or Generation~=(tonumber(WarthogColorRuntimeGeneration) or 0) then return end
            if tonumber(ArmorSkinRespawnIdentitySettledGeneration)==Generation then return end
            local V=ArmorSkinRemotePairVector
            if type(V)~="table" or tonumber(V.Generation)~=Generation then return end
            local Records=ArmorSkinAllKnownPlayerPawnRecords()
            local Remote={}
            for _,R in ipairs(type(Records)=="table" and Records or {}) do
                if R.LocalIndex==nil and tonumber(R.PlayerId)~=nil then
                    local K=tostring(math.floor(tonumber(R.PlayerId)))
                    local C=tonumber(ArmorSkinPersistentRemoteColorByPlayerId[K])
                    if C~=nil and C>0 and C<=#WarthogCEColors then Remote[#Remote+1]={R=R,C=C} end
                end
            end
            if #Remote~=2 then return end
            local Probe=Unwrap(Remote[1].R.Pawn)
            if IsValidObject(Probe) then ArmorSkinBuildBipedAssignments(Probe) end
            local Ready=true
            for _,E in ipairs(Remote) do
                local B=ArmorSkinFindAssignedBiped(E.R.Pawn)
                if not IsValidObject(B) then Ready=false; break end
            end
            if not Ready then
                if D==Delays[#Delays] then
                    Log("ARMORSKIN respawn identity retry exhausted generation=%d source=%s",Generation,tostring(Source or "respawn"))
                end
                return
            end
            local Applied=0
            for _,E in ipairs(Remote) do
                local Pid=tonumber(E.R.PlayerId)
                local Pawn=Unwrap(E.R.Pawn)
                if not IsValidObject(Pawn) then Pawn=select(1,ArmorSkinResolvePawnByPlayerId(Pid)) end
                if IsValidObject(Pawn) then
                    local Ok=ArmorSkinApplyToPawn(Pawn,Pid,nil,E.C,string.format("respawn identity settled +%dms",D))
                    if Ok then Applied=Applied+1 end
                end
            end
            if Applied>=#Remote then
                ArmorSkinRespawnIdentitySettledGeneration=Generation
                Log("ARMORSKIN respawn remote identity SETTLED generation=%d applied=%d delay=%dms source=%s",
                    Generation,Applied,D,tostring(Source or "respawn"))
            end
        end)
    end
end

function ArmorSkinScheduleRespawnSettledRebind(Source)
    ArmorSkinRespawnSettleToken=(tonumber(ArmorSkinRespawnSettleToken) or 0)+1
    local Token=ArmorSkinRespawnSettleToken
    local Generation=WarthogColorRuntimeGeneration
    -- Debounce the entire construction burst. Multiple BP_SpartansBipedActor
    -- objects are created for the same respawn/transition; only the last event may
    -- arm a rebind. No material/MID pointers are captured in this delayed closure.
    ExecuteInGameThreadWithDelay(2200,function()
        if Token~=ArmorSkinRespawnSettleToken or ModTeardownGuard or not MissionReady
            or Generation~=WarthogColorRuntimeGeneration then return end
        if (tonumber(ArmorSkinBipedWriteQuietUntilClock) or 0) > os.clock() then return end
        Log("ARMORSKIN respawn settle gate OPEN generation=%s source=%s",
            tostring(Generation),tostring(Source or "biped construction"))
        -- Reuse the established tokenized apply/retry paths only after the world
        -- is quiet. They reacquire Controller/Pawn/components at execution time.
        ArmorSkinScheduleTrackedReapply("respawn settled")
        if ArmorSkinScheduleRespawnRemoteIdentityRetry ~= nil then
            ArmorSkinScheduleRespawnRemoteIdentityRetry("respawn settled")
        end
        if ArmorSkinScheduleRespawnPairVectorRepublish ~= nil then
            ArmorSkinScheduleRespawnPairVectorRepublish("respawn settled")
        end
    end)
end

-- V15: the stock customization layer can rewrite the freshly spawned Default
-- Chief after the first 2.2s rebind. Reassert committed local Classic state later,
-- but only through the exact-local-anchor V15 path.
local ArmorSkinScheduleRespawnSettledRebindV15Base = ArmorSkinScheduleRespawnSettledRebind
function ArmorSkinScheduleRespawnSettledRebind(Source)
    ArmorSkinScheduleRespawnSettledRebindV15Base(Source)
    local Generation=WarthogColorRuntimeGeneration
    local Token=tonumber(ArmorSkinRespawnSettleToken) or 0
    for _,Delay in ipairs({5000,8000}) do
        ExecuteInGameThreadWithDelay(Delay,function()
            if ModTeardownGuard or not MissionReady or Generation~=WarthogColorRuntimeGeneration
                or Token~=(tonumber(ArmorSkinRespawnSettleToken) or 0) then return end
            for PlayerIndex=1,2 do
                local ColorIndex=tonumber(ClassicArmorMenuSelectedByPlayer[PlayerIndex]) or 0
                if ColorIndex>0 and IsValidObject(GetPlayer(PlayerIndex)) then
                    ArmorSkinLocalIndexByPlayer[PlayerIndex]=ColorIndex
                    ArmorSkinScheduleLocalApply(PlayerIndex,ColorIndex,
                        string.format("V15 post-respawn committed reassert +%dms",Delay),false)
                end
            end
        end)
    end
end

function ArmorSkinScheduleRespawnPairVectorRepublish(Source)
    -- Retired with the custom HCECEA armor network transport.
    return false
end

function RegisterArmorSkinBipedConstructionListener()
    if ArmorSkinBipedConstructionListenerReady then return true end
    local Ok, Err = pcall(function()
        NotifyOnNewObject(
            "/Game/_Prototypes/SynchronizationTestContent/TestActor/BP_SpartansBipedActor.BP_SpartansBipedActor_C",
            function(Biped)
                ClassicArmorV16BipedEpoch = (tonumber(ClassicArmorV16BipedEpoch) or 0) + 1
                -- V17: keep string-only local biped proofs across construction events.
                -- The epoch marks them stale so the resolver revalidates them against
                -- current spatial/fresh candidates before reuse; no UObject is retained.
                ArmorSkinCacheBipedInstance(Biped, "NotifyOnNewObject")
                local FreshKey=ArmorSkinObjectKey(Biped)
                local FreshClock=os.clock()
                ArmorSkinLastBipedConstructionClock=FreshClock
                if FreshKey~=nil then
                    ArmorSkinFreshBipedByKey[FreshKey]={Biped=Unwrap(Biped),Clock=FreshClock,
                        Generation=tonumber(WarthogColorRuntimeGeneration) or 0}
                end
                ArmorSkinClearBipedAssignments("new Spartan biped constructed")
                -- RC3_55 native crash fix: never retain Component/MID references
                -- across biped replacement. RC3_54 could update an old P1 MID and
                -- then dereference a just-freed P2 component, producing a native
                -- EXCEPTION_ACCESS_VIOLATION that Lua pcall cannot catch. Dropping
                -- the Lua references is safe; do NOT restore old materials here.
                ArmorSkinDropAllRuntimeRefs("new Spartan biped constructed; stale MID refs discarded")
                ArmorSkinRemotePairVector=nil
                ArmorSkinPairVectorAuditLogged={}
                ArmorSkinPairVectorSourceReadyGeneration=-1
                ArmorSkinPairVectorLastClientUplinkSignature=""
                ArmorSkinPairVectorLastSignatureByController={}
                -- Extend the no-touch window on every construction event so a burst
                -- of P1/P2/remote presentation actors produces one settled rebind.
                ArmorSkinBipedWriteQuietUntilClock=math.max(tonumber(ArmorSkinBipedWriteQuietUntilClock) or 0,os.clock()+2.0)
                if ArmorSkinScheduleRespawnSettledRebind ~= nil then
                    ArmorSkinScheduleRespawnSettledRebind("new Spartan biped constructed")
                end
            end
        )
    end)
    if Ok then
        ArmorSkinBipedConstructionListenerReady = true
        Log("ARMORSKIN Spartan biped construction listener ready; respawn reapply is event-driven")
        return true
    end
    Log("ARMORSKIN Spartan biped construction listener unavailable: %s", tostring(Err))
    return false
end

function ArmorSkinResetSessionState(Reason)
    if ArmorSkinPaletteReset ~= nil then ArmorSkinPaletteReset("session/world reset: " .. tostring(Reason or "session boundary")) end
    ArmorSkinAppliedByTarget = {}
    ArmorSkinLocalIndexByPlayer = {
        [1] = tonumber(ClassicArmorMenuSelectedByPlayer[1]) or 0,
        [2] = tonumber(ClassicArmorMenuSelectedByPlayer[2]) or 0,
    }
    ArmorSkinLocalApplyToken = { [1] = 0, [2] = 0 }
    ArmorSkinLocalSettledToken = { [1] = 0, [2] = 0 }
    ArmorSkinMaintainCounter = { [1] = 0, [2] = 0 }
    ArmorSkinMaintenanceNextClock = { [1] = 0, [2] = 0 }
    ArmorSkinPairVectorNextReadyCheckClock = 0
    ArmorSkinFirstPersonRetryByTarget = {}
    ArmorSkinPerspectiveRebindToken = { [1] = 0, [2] = 0 }
    ArmorSkinRemoteBipedRouteLogged = {}
    ArmorSkinRemoteBipedFailureLogged = {}
    ArmorSkinRemoteAttachedAuditLogged = {}
    ArmorSkinBipedInstanceCache = {}
    ArmorSkinBipedInstanceSeen = {}
    ArmorSkinFreshBipedByKey = {}
    ArmorSkinLastBipedConstructionClock = 0
    if ArmorSkinCancelSlicedJobs ~= nil then ArmorSkinCancelSlicedJobs("session state reset") end
    ArmorSkinBipedExactScanGeneration = -1
    ArmorSkinBipedAssignmentByPawnKey = {}
    ArmorSkinBipedAssignmentMetaByPawnKey = {}
    ArmorSkinLastKnownBipedKeyByPlayerId = {}
    ClassicArmorPendingCommitByPlayer = {}
    ArmorSkinBipedAssignmentAuditLogged = {}
    ArmorSkinBipedAnchorPendingLogged = {}
    ArmorSkinBipedMotionBaseline = {}
    ArmorSkinBipedOrdinalAuditLogged = {}
    ArmorSkinPlayerIdOrdinalHint = nil
    ArmorSkinOrdinalHintSentByController = {}
    ArmorSkinOrdinalAuditLogged = {}
    ArmorSkinCVWSkeletalCache = {}
    ArmorSkinCVWSkeletalSeen = {}
    ArmorSkinCVWExactScanGeneration = -1
    ArmorSkinChiefPresentationClasses = {}
    ArmorSkinChiefPresentationClassSeen = {}
    ArmorSkinSyncReflectionAuditLogged = {}
    ArmorSkinTexturePrewarmRequestedGeneration = -1
    ClassicArmorMenuReplayByWidget = {}
    ClassicArmorMenuPostReplayTokenByWidget = {}
    -- Runtime network state is world-local. RC3_43 deliberately keeps
    -- ArmorSkinPersistentRemote* intact so unchanged fireteam members retain
    -- their logical color across mission travel; live protocol-2 state overrides it.
    ArmorSkinNetworkColorByPlayerId = {}
    ArmorSkinNetworkPendingTokenByPlayerId = {}
    ArmorSkinNetworkSequence = 0
    ArmorSkinNetworkUplinkSequence = 0
    ArmorSkinNetworkLastReceivedSequenceByPlayerId = {}
    ArmorSkinNetworkLastUplinkSequenceByController = {}
    ArmorSkinNetworkResolveRouteByPlayerId = {}
    ArmorSkinNetworkLastPublishedLocalColorByPlayerId = {}
    -- P2 callsign transport is independent from the retired armor protocol, but
    -- its bounded publish/de-duplication state must still reset at world boundaries.
    IdentityNameLastPublishedByPlayerId = {}
    IdentityNameLastUplinkSequenceByController = {}
    IdentityFrontendNameLastSignature = ""
    IdentityFrontendNamePublishToken = (tonumber(IdentityFrontendNamePublishToken) or 0) + 1
    Log("ARMORSKIN session state reset: %s", tostring(Reason or "session boundary"))
end

-- In-game weapon skin switching --------------------------------------------
-- Release path: exact runtime actor names only. The seven families below were
-- verified in-game. Unknown BP_FP weapon actors are treated as unsupported
-- immediately; no deep reflection fallback runs from public shortcuts.
WeaponSkinDefinitions = WeaponSkinDefinitions or {
    AssaultRifle = {
        Label = "ASSAULT RIFLE",
        Prefix = "Blam.Customization.AssaultRifle.",
        Asset = "/Game/DataTables/DT_AssaultRifleCustomization",
        ActorToken = "bp_fp_assaultrifle_weaponactor_c",
    },
    BattleRifle = {
        Label = "BATTLE RIFLE",
        Prefix = "Blam.Customization.BattleRifle.",
        Asset = "/Game/DataTables/DT_BattleRifleCustomization",
        ActorToken = "bp_fp_battlerifle_weaponactor_c",
    },
    EnergySword = {
        Label = "ENERGY SWORD",
        Prefix = "Blam.Customization.EnergySword.",
        Asset = "/Game/DataTables/DT_EnergySwordCustomization",
        ActorToken = "bp_fp_energysword_weaponactor_c",
    },
    FuelRod = {
        Label = "FUEL ROD GUN",
        Prefix = "Blam.Customization.FuelRod.",
        Asset = "/Game/DataTables/DT_FuelRodCustomization",
        -- The shipped Fuel Rod weapon actor uses the internal FlakCannon name.
        ActorToken = "bp_fp_flakcannon_weaponactor_c",
    },
    Magnum = {
        Label = "MAGNUM",
        Prefix = "Blam.Customization.Magnum.",
        Asset = "/Game/DataTables/DT_MagnumCustomization",
        ActorToken = "bp_fp_magnum_weaponactor_c",
    },
    SniperRifle = {
        Label = "SNIPER RIFLE",
        Prefix = "Blam.Customization.SniperRifle.",
        Asset = "/Game/DataTables/DT_SniperRifleCustomization",
        ActorToken = "bp_fp_sniperrifle_weaponactor_c",
    },
    Spnkr = {
        Label = "SPNKR ROCKET LAUNCHER",
        Prefix = "Blam.Customization.Spnkr.",
        Asset = "/Game/DataTables/DT_SpnkrCustomization",
        ActorToken = "bp_fp_rocketlauncher_weaponactor_c",
    },
}
WeaponSkinDefinitionOrder = WeaponSkinDefinitionOrder or {
    "AssaultRifle", "BattleRifle", "EnergySword", "FuelRod", "Magnum", "SniperRifle", "Spnkr",
}
WeaponSkinCatalogs = WeaponSkinCatalogs or {}
WeaponSkinNativeStatics = WeaponSkinNativeStatics or nil
CustomizationOwnedPackageCache = CustomizationOwnedPackageCache or { [1] = {}, [2] = {} }
CustomizationEntitlementRequests = CustomizationEntitlementRequests or {}
CustomizationOwnershipLog = CustomizationOwnershipLog or {}
WeaponSkinFastVisualCache = WeaponSkinFastVisualCache or {
    [1] = { Pawn = nil, Anchors = nil },
    [2] = { Pawn = nil, Anchors = nil },
}

function WeaponSkinClip(Value, Limit)
    local Text = tostring(Value or "")
    local Max = tonumber(Limit) or 420
    Text = string.gsub(Text, "[\r\n\t]+", " ")
    if #Text > Max then Text = string.sub(Text, 1, Max) .. "..." end
    return Text
end

function WeaponSkinObjectDescription(Value)
    local Object = Unwrap(Value)
    if not IsValidObject(Object) then return WeaponSkinClip(SafeToString(Object), 420) end
    local Full = SafeFullName(Object) or tostring(Object)
    local ClassFull = ""
    pcall(function()
        local Class = Object:GetClass()
        if IsValidObject(Class) then ClassFull = SafeFullName(Class) or "" end
    end)
    -- Keep the tag field from the proven bounded detector. Most mesh components
    -- have no tag, but preserving the exact description path avoids changing
    -- weapon recognition behavior during release cleanup.
    local Tag = GetTagName(Object)
    if Tag ~= nil and Tag ~= "" then
        return WeaponSkinClip(string.format("object=%s | class=%s | tag=%s", Full, ClassFull, Tag), 620)
    end
    return WeaponSkinClip(string.format("object=%s | class=%s", Full, ClassFull), 620)
end

function WeaponSkinFriendlyName(Value, Skin)
    local Text = SafeToString(Value)
    if Text == nil then Text = "" end
    Text = tostring(Text)
    local LastQuoted = nil
    for Part in string.gmatch(Text, '"([^"]+)"') do LastQuoted = Part end
    if LastQuoted ~= nil and LastQuoted ~= "" then Text = LastQuoted end
    Text = string.gsub(Text, "^%s+", "")
    Text = string.gsub(Text, "%s+$", "")
    if Text == "" or Text == "<nil>" or string.find(Text, "NSLOCTEXT", 1, true) then
        Text = string.match(tostring(Skin or ""), "%.([^%.]+)$") or tostring(Skin or "SKIN")
    end
    return Text
end

function BuildWeaponSkinCatalog(TypeName)
    if WeaponSkinCatalogs[TypeName] ~= nil and #WeaponSkinCatalogs[TypeName] > 0 then
        return WeaponSkinCatalogs[TypeName]
    end
    local Def = WeaponSkinDefinitions[TypeName]
    if Def == nil then return nil end
    local Lib = GetDataTableLibrary()
    local Table = nil
    pcall(function() Table = LoadAsset(Def.Asset) end)
    if not IsValidObject(Table) then
        pcall(function() Table = StaticFindObject(Def.Asset .. "." .. string.match(Def.Asset, "([^/]+)$")) end)
    end
    if not IsValidObject(Lib) or not IsValidObject(Table) then
        Log("Weapon skin catalog unavailable: %s", tostring(Def.Label))
        return nil
    end

    local Skins = GetColumnStrings(Lib, Table, "CustomizationName")
    local Packages = GetColumnStrings(Lib, Table, "PackageName")
    local Names = GetColumnStrings(Lib, Table, "UIName")
    local Catalog = {}
    for I, SkinCell in ipairs(Skins) do
        local Skin = ParseTagCell(SkinCell)
        if Skin ~= nil and Skin ~= "" then
            local Package = ParseTagCell(Packages[I] or "")
            Catalog[#Catalog + 1] = {
                Skin = Skin,
                Package = Package or "",
                Name = WeaponSkinFriendlyName(Names[I], Skin),
            }
        end
    end
    WeaponSkinCatalogs[TypeName] = Catalog
    return Catalog
end

function GetWeaponSkinNativeStatics()
    if IsValidObject(WeaponSkinNativeStatics) then return WeaponSkinNativeStatics end
    local Candidate = nil
    pcall(function() Candidate = StaticFindObject("/Script/Meteorite.Default__MeteoriteUIStatics") end)
    if not IsValidObject(Candidate) then
        pcall(function() Candidate = FindFirstOf("MeteoriteUIStatics") end)
    end
    Candidate = Unwrap(Candidate)
    if IsValidObject(Candidate) then
        WeaponSkinNativeStatics = Candidate
        return Candidate
    end
    return nil
end

function CustomizationBool(Value)
    local Unwrapped = Unwrap(Value)
    if Unwrapped == true then return true end
    if type(Unwrapped) == "number" then return Unwrapped ~= 0 end
    local Text = string.lower(SafeToString(Unwrapped) or "")
    return Text == "true" or Text == "1"
end

function CustomizationRequestEntitlements(Controller, Statics)
    if not IsValidObject(Controller) or not IsValidObject(Statics) then return end
    local ControllerKey = SafeFullName(Controller) or tostring(Controller)
    if CustomizationEntitlementRequests[ControllerKey] then return end
    CustomizationEntitlementRequests[ControllerKey] = true
    local Ok, Err = pcall(function() Statics:RequestWaypointEntitlements(Controller) end)
    Log("CUSTOMIZATION entitlement refresh controller=%s result=%s%s",
        tostring(ControllerKey), tostring(Ok), Ok and "" or (" error=" .. tostring(Err)))
end

function CustomizationPackageCandidates(PackageName)
    local Package = tostring(PackageName or "")
    local Result = {}
    local Seen = {}
    local function Add(Value)
        Value = tostring(Value or "")
        if Value ~= "" and not Seen[string.lower(Value)] then
            Seen[string.lower(Value)] = true
            Result[#Result + 1] = Value
        end
    end
    Add(Package)
    Add(string.match(Package, "CustomizationPackage%.(.+)$"))
    return Result
end

CustomizationAlwaysFreeSkins = CustomizationAlwaysFreeSkins or {
    ["blam.customization.masterchief.originalce"] = true,
    ["blam.customization.masterchief.blackandgold"] = true,
    ["blam.customization.masterchief.purple_001"] = true,
    ["blam.customization.masterchief.blue_001"] = true,
    ["blam.customization.assaultrifle.originalce"] = true,
    ["blam.customization.assaultrifle.blackandgold"] = true,
    ["blam.customization.assaultrifle.ship_001"] = true,
}

-- Empty package tags are the game's Owned rows. A small explicit allowlist
-- corrects stock metadata that marks known free/non-premium rows as gated.
-- All other non-empty packages still require Halo's native entitlement result.
function IsCustomizationEntryAvailable(PlayerIndex, Entry)
    if Entry == nil then return false, "missing entry" end
    local SkinKey = string.lower(tostring(Entry.Skin or ""))
    if CustomizationAlwaysFreeSkins[SkinKey] then return true, "project free row" end
    local Package = tostring(Entry.Package or "")
    if Package == "" or Package == "None" then return true, "owned row" end

    PlayerIndex = math.max(1, math.min(2, tonumber(PlayerIndex) or 1))
    local Cache = CustomizationOwnedPackageCache[PlayerIndex]
    if Cache == nil then
        Cache = {}
        CustomizationOwnedPackageCache[PlayerIndex] = Cache
    end
    local PackageKey = string.lower(Package)
    if Cache[PackageKey] == true then return true, "cached entitlement" end

    local Controller = GetPlayer(PlayerIndex)
    local Statics = GetWeaponSkinNativeStatics()
    if not IsValidObject(Controller) or not IsValidObject(Statics) then
        return false, "ownership API unavailable"
    end
    CustomizationRequestEntitlements(Controller, Statics)

    local Checked = {}
    for _, Candidate in ipairs(CustomizationPackageCandidates(Package)) do
        local Ok, Owned = pcall(function()
            return Statics:IsDLCPurchased(Controller, FName(Candidate))
        end)
        Checked[#Checked + 1] = string.format("%s=%s", Candidate, Ok and SafeToString(Owned) or "error")
        if Ok and CustomizationBool(Owned) then
            Cache[PackageKey] = true
            local LogKey = string.format("%d:%s:true", PlayerIndex, PackageKey)
            if not CustomizationOwnershipLog[LogKey] then
                CustomizationOwnershipLog[LogKey] = true
                Log("CUSTOMIZATION package allowed P%d package=%s via=%s",
                    PlayerIndex, Package, Candidate)
            end
            return true, "entitlement confirmed"
        end
    end

    local DeniedLogKey = string.format("%d:%s:false", PlayerIndex, PackageKey)
    if not CustomizationOwnershipLog[DeniedLogKey] then
        CustomizationOwnershipLog[DeniedLogKey] = true
        Log("CUSTOMIZATION package denied P%d package=%s checks=%s",
            PlayerIndex, Package, table.concat(Checked, ", "))
    end
    return false, "premium package not owned"
end

function FindNextAvailableCustomizationIndex(PlayerIndex, Catalog, CurrentIndex, Delta)
    if Catalog == nil or #Catalog == 0 then return nil, 0 end
    local Direction = (tonumber(Delta) or 1) < 0 and -1 or 1
    local Index = tonumber(CurrentIndex) or 1
    local Skipped = 0
    for _ = 1, #Catalog do
        Index = Index + Direction
        if Index > #Catalog then Index = 1 end
        if Index < 1 then Index = #Catalog end
        local Allowed = IsCustomizationEntryAvailable(PlayerIndex, Catalog[Index])
        if Allowed then return Index, Skipped end
        Skipped = Skipped + 1
    end
    return nil, Skipped
end

function ApplyWeaponSkinNative(PlayerIndex, Controller, Entry)
    if not IsValidObject(Controller) or Entry == nil then return false, "controller/entry unavailable" end
    local Statics = GetWeaponSkinNativeStatics()
    if not IsValidObject(Statics) then return false, "MeteoriteUIStatics default object unavailable" end
    local Tag = MakeGameplayTag(Entry.Skin)
    if Tag == nil then return false, "gameplay tag construction failed" end
    local Ok, Err = pcall(function()
        Statics:SetEquippedObjectSkin(Controller, Tag)
    end)
    if not Ok then return false, tostring(Err) end
    return true, "SetEquippedObjectSkin"
end

function FindWeaponCustomizationSelection(Settings, Def)
    if not IsValidObject(Settings) or Def == nil then return nil, "" end
    local Values = nil
    pcall(function() Values = Settings.ObjectCustomizationNames end)
    local PrefixLower = string.lower(Def.Prefix or "")
    for _, Candidate in ipairs(ArrayValues(Values)) do
        local Tag = Unwrap(Candidate)
        local Name = GetTagName(Tag)
        if string.find(string.lower(Name or ""), PrefixLower, 1, true) == 1 then
            return Tag, Name
        end
    end
    return nil, ""
end

function WeaponSkinCurrentIndex(Settings, Def, Catalog)
    local _, CurrentName = FindWeaponCustomizationSelection(Settings, Def)
    if CurrentName ~= "" then
        for I, Entry in ipairs(Catalog) do
            if string.lower(Entry.Skin or "") == string.lower(CurrentName) then return I, CurrentName end
        end
    end
    -- Default weapon skins are not normally stored in ObjectCustomizationNames.
    for I, Entry in ipairs(Catalog) do
        if string.lower(Entry.Skin or ""):match("%.default$") then return I, "<default>" end
    end
    return 1, CurrentName ~= "" and CurrentName or "<default>"
end

function ApplyWeaponSkinDirect(PlayerIndex, TypeName, Entry)
    local Def = WeaponSkinDefinitions[TypeName]
    if Def == nil or Entry == nil then return false, "missing weapon definition/catalog entry" end
    local Available, AvailabilityInfo = IsCustomizationEntryAvailable(PlayerIndex, Entry)
    if not Available then return false, AvailabilityInfo end
    local Settings, SettingsInfo = GetUserSettings(PlayerIndex)
    if not IsValidObject(Settings) then return false, SettingsInfo end

    local NewTag = MakeGameplayTag(Entry.Skin)
    local CurrentTag = nil
    local CurrentName = ""
    local MatchOk = pcall(function() CurrentTag = Settings:FindCustomizationMatching(NewTag) end)
    CurrentTag = Unwrap(CurrentTag)
    if CurrentTag ~= nil then CurrentName = GetTagName(CurrentTag) end
    if not MatchOk or CurrentTag == nil or CurrentName == "" or CurrentName == "None" then
        CurrentTag, CurrentName = FindWeaponCustomizationSelection(Settings, Def)
    end
    if CurrentTag == nil then CurrentTag = NewTag end

    local ApplyOk, ApplyErr = pcall(function()
        Settings:AddOrReplaceCustomization(CurrentTag, NewTag)
    end)
    if not ApplyOk then return false, tostring(ApplyErr) end

    local Controller = GetPlayer(PlayerIndex)
    local NativeOk, NativeInfo = ApplyWeaponSkinNative(PlayerIndex, Controller, Entry)
    if not NativeOk then return false, "native live apply failed: " .. tostring(NativeInfo) end
    return true, "ok"
end

function WeaponSkinTypeFromText(Text)
    local Lower = string.lower(tostring(Text or ""))
    if Lower == "" then return nil end
    for _, TypeName in ipairs(WeaponSkinDefinitionOrder) do
        local Def = WeaponSkinDefinitions[TypeName]
        if Def ~= nil and Def.ActorToken ~= nil
            and string.find(Lower, string.lower(Def.ActorToken), 1, true) ~= nil then
            return TypeName
        end
    end
    return nil
end

function WeaponSkinGetAllPawnComponents(Pawn)
    if not IsValidObject(Pawn) then return {}, "pawn unavailable" end
    local ActorComponentClass = nil
    pcall(function() ActorComponentClass = StaticFindObject("/Script/Engine.ActorComponent") end)
    if not IsValidObject(ActorComponentClass) then return {}, "ActorComponent class unavailable" end
    local Components = nil
    local Route = "K2_GetComponentsByClass"
    local Ok = pcall(function() Components = Pawn:K2_GetComponentsByClass(ActorComponentClass) end)
    if not Ok or Components == nil then
        Route = "GetComponentsByClass"
        pcall(function() Components = Pawn:GetComponentsByClass(ActorComponentClass) end)
    end
    return ArrayValues(Components), Route
end

function WeaponSkinFastVisualReset(PlayerIndex)
    if PlayerIndex == nil then
        WeaponSkinFastVisualCache[1] = { Pawn = nil, Anchors = nil }
        WeaponSkinFastVisualCache[2] = { Pawn = nil, Anchors = nil }
        return
    end
    WeaponSkinFastVisualCache[PlayerIndex] = { Pawn = nil, Anchors = nil }
end

function WeaponSkinFastVisualAddAnchor(Anchors, Seen, Object, Label)
    Object = Unwrap(Object)
    if not IsValidObject(Object) then return end
    local Key = SafeFullName(Object) or tostring(Object)
    if Seen[Key] then return end
    Seen[Key] = true
    Anchors[#Anchors + 1] = { Object = Object, Label = tostring(Label or "anchor") }
end

function WeaponSkinBuildFastVisualAnchors(PlayerIndex, Pawn)
    if not IsValidObject(Pawn) then return {}, "pawn unavailable" end
    local Cache = WeaponSkinFastVisualCache[PlayerIndex]
    if Cache ~= nil and Cache.Pawn == Pawn and type(Cache.Anchors) == "table" and #Cache.Anchors > 0 then
        return Cache.Anchors, "cached"
    end

    local Anchors = {}
    local Seen = {}
    local DirectArmsFound = false

    -- Primary route: BP_MeteoritePawn exposes the exact first-person arms CVW
    -- component directly. FirstPersonArmsSkeletalMesh is BPC_FP_SkeletalMesh_C,
    -- and the supported weapon actor sits under its
    -- attachment parent/children. This avoids depending on class-path filtering
    -- across the complete component array.
    local Arms = nil
    pcall(function() Arms = Pawn.FirstPersonArmsSkeletalMesh end)
    Arms = Unwrap(Arms)
    if IsValidObject(Arms) then
        DirectArmsFound = true
        WeaponSkinFastVisualAddAnchor(Anchors, Seen, Arms, "Pawn.FirstPersonArmsSkeletalMesh")
        for _, Name in ipairs({"AttachParent", "LeaderPoseComponent", "MasterPoseComponent"}) do
            local Value = nil
            pcall(function() Value = Arms[Name] end)
            WeaponSkinFastVisualAddAnchor(Anchors, Seen, Value, "Pawn.FirstPersonArmsSkeletalMesh." .. Name)
        end
    end

    -- Fallback/secondary route: keep the proven bounded CVW component discovery.
    -- This is evaluated only on a weapon-skin shortcut and cached per pawn.
    local Components, Route = WeaponSkinGetAllPawnComponents(Pawn)
    for I, ComponentValue in ipairs(Components) do
        local Component = Unwrap(ComponentValue)
        if IsValidObject(Component) then
            local Desc = string.lower(WeaponSkinObjectDescription(Component))
            if string.find(Desc, "/game/blueprints/cvw/", 1, true) ~= nil
                and string.find(Desc, "bpc_fp_", 1, true) ~= nil then
                WeaponSkinFastVisualAddAnchor(Anchors, Seen, Component, string.format("Visual[%d]", I))
                for _, Name in ipairs({"AttachParent", "LeaderPoseComponent", "MasterPoseComponent"}) do
                    local Value = nil
                    pcall(function() Value = Component[Name] end)
                    WeaponSkinFastVisualAddAnchor(Anchors, Seen, Value, string.format("Visual[%d].%s", I, Name))
                end
            end
        end
    end
    WeaponSkinFastVisualCache[PlayerIndex] = { Pawn = Pawn, Anchors = Anchors }
    Log("Weapon skin detector P%d anchors=%d directArms=%s route=%s",
        PlayerIndex, #Anchors, tostring(DirectArmsFound), tostring(Route))
    return Anchors, DirectArmsFound and ("FirstPersonArmsSkeletalMesh + " .. tostring(Route)) or Route
end

function WeaponSkinIsWeaponActorText(Text)
    local Lower = string.lower(tostring(Text or ""))
    return string.find(Lower, "bp_fp_", 1, true) ~= nil
        and string.find(Lower, "weaponactor", 1, true) ~= nil
end

function DetectHeldWeaponTypeFastVisual(PlayerIndex, Pawn)
    local Anchors, Route = WeaponSkinBuildFastVisualAnchors(PlayerIndex, Pawn)
    if type(Anchors) ~= "table" or #Anchors == 0 then
        return nil, "no cached CVW anchors (" .. tostring(Route) .. ")", false
    end

    local BestType = nil
    local BestDetail = nil
    local UnsupportedDetail = nil
    for _, Anchor in ipairs(Anchors) do
        local Object = Unwrap(Anchor.Object)
        if IsValidObject(Object) then
            local DirectText = WeaponSkinObjectDescription(Object)
            local DirectType = WeaponSkinTypeFromText(DirectText)
            if DirectType ~= nil then
                BestType = BestType or DirectType
                BestDetail = BestDetail or (tostring(Anchor.Label) .. " => " .. DirectText)
            elseif WeaponSkinIsWeaponActorText(DirectText) and UnsupportedDetail == nil then
                UnsupportedDetail = tostring(Anchor.Label) .. " => " .. DirectText
            end

            local Children = nil
            pcall(function() Children = Object.AttachChildren end)
            for ChildIndex, ChildValue in ipairs(ArrayValues(Children)) do
                if ChildIndex > 16 then break end
                local Child = Unwrap(ChildValue)
                if IsValidObject(Child) then
                    local ChildText = WeaponSkinObjectDescription(Child)
                    if WeaponSkinIsWeaponActorText(ChildText) then
                        local ChildType = WeaponSkinTypeFromText(ChildText)
                        if ChildType ~= nil then
                            if BestType ~= nil and BestType ~= ChildType then
                                return nil, string.format("ambiguous active weapon actors: %s/%s", tostring(BestType), tostring(ChildType)), false
                            end
                            BestType = ChildType
                            BestDetail = string.format("%s.AttachChildren[%d] => %s", tostring(Anchor.Label), ChildIndex, ChildText)
                        elseif UnsupportedDetail == nil then
                            UnsupportedDetail = string.format("%s.AttachChildren[%d] => %s", tostring(Anchor.Label), ChildIndex, ChildText)
                        end
                    end
                end
            end
        end
    end

    if BestType ~= nil then return BestType, tostring(BestDetail or "matched"), false end
    if UnsupportedDetail ~= nil then return nil, tostring(UnsupportedDetail), true end
    return nil, "no active BP_FP weapon actor found", false
end

-- Third-person recovery: the third-person skull keeps normal synchronized
-- BP_*_WeaponActor_C actors directly under Pawn.Children. The equipped weapon's
-- RootComponent is attached to the Spartan body at Grip_R, while holstered
-- weapons use other sockets such as Hip_R. This fallback runs only after the
-- proven first-person detector misses and only inspects direct pawn children.
function WeaponSkinThirdPersonTypeFromText(Text)
    local Lower = string.lower(tostring(Text or ""))
    if Lower == "" then return nil end
    for _, TypeName in ipairs(WeaponSkinDefinitionOrder) do
        local Def = WeaponSkinDefinitions[TypeName]
        if Def ~= nil and Def.ActorToken ~= nil then
            local ThirdPersonToken = string.gsub(string.lower(Def.ActorToken), "bp_fp_", "bp_", 1)
            if ThirdPersonToken ~= "" and string.find(Lower, ThirdPersonToken, 1, true) ~= nil then
                return TypeName
            end
        end
    end
    return nil
end

function WeaponSkinThirdPersonSocketName(Object)
    Object = Unwrap(Object)
    if not IsValidObject(Object) then return "" end
    local Value = nil
    pcall(function() Value = Object.AttachSocketName end)
    local Text = SafeToString(Value)
    if Text ~= nil and Text ~= "" and Text ~= "None" and Text ~= "<nil>" then
        return tostring(Text)
    end
    Value = nil
    pcall(function() Value = Object:GetAttachSocketName() end)
    Text = SafeToString(Value)
    if Text ~= nil and Text ~= "" and Text ~= "None" and Text ~= "<nil>" then
        return tostring(Text)
    end
    return ""
end

function WeaponSkinIsThirdPersonWeaponActorText(Text)
    local Lower = string.lower(tostring(Text or ""))
    return string.find(Lower, "bp_", 1, true) ~= nil
        and string.find(Lower, "_weaponactor_c", 1, true) ~= nil
        and string.find(Lower, "bp_fp_", 1, true) == nil
end

function DetectHeldWeaponTypeThirdPersonGrip(PlayerIndex, Pawn)
    if not IsValidObject(Pawn) then return nil, "third-person pawn unavailable", false end
    local Children = nil
    pcall(function() Children = Pawn.Children end)
    local ChildActors = ArrayValues(Children)
    local BestType = nil
    local BestDetail = nil
    local UnsupportedDetail = nil

    for I, ChildValue in ipairs(ChildActors) do
        if I > 16 then break end
        local Child = Unwrap(ChildValue)
        if IsValidObject(Child) then
            local Desc = WeaponSkinObjectDescription(Child)
            local TypeName = WeaponSkinThirdPersonTypeFromText(Desc)
            local IsWeaponActor = TypeName ~= nil or WeaponSkinIsThirdPersonWeaponActorText(Desc)
            if IsWeaponActor then
                local Root = nil
                pcall(function() Root = Child.RootComponent end)
                Root = Unwrap(Root)
                local Socket = WeaponSkinThirdPersonSocketName(Root)
                if string.lower(tostring(Socket)) == "grip_r" then
                    local Detail = string.format("Pawn.Children[%d] Grip_R => %s", I, Desc)
                    if TypeName ~= nil then
                        if BestType ~= nil and BestType ~= TypeName then
                            return nil, string.format("ambiguous third-person Grip_R weapon actors: %s/%s", tostring(BestType), tostring(TypeName)), false
                        end
                        BestType = TypeName
                        BestDetail = Detail
                    elseif UnsupportedDetail == nil then
                        UnsupportedDetail = Detail
                    end
                end
            end
        end
    end

    if BestType ~= nil then
        Log("Weapon skin P%d third-person recovery type=%s socket=Grip_R", PlayerIndex, tostring(BestType))
        return BestType, tostring(BestDetail or "third-person Grip_R match"), false
    end
    if UnsupportedDetail ~= nil then return nil, UnsupportedDetail, true end
    return nil, "no supported third-person Grip_R weapon actor found", false
end

function DetectHeldWeaponType(PlayerIndex)
    local Controller = GetPlayer(PlayerIndex)
    if not IsValidObject(Controller) then return nil, "controller unavailable", false end
    local Pawn = nil
    pcall(function() Pawn = Controller.Pawn end)
    if not IsValidObject(Pawn) then return nil, "pawn unavailable", false end

    local TypeName, Info, Unsupported = DetectHeldWeaponTypeFastVisual(PlayerIndex, Pawn)
    if TypeName ~= nil or Unsupported == true then
        return TypeName, Info, Unsupported == true
    end

    local ThirdPersonType, ThirdPersonInfo, ThirdPersonUnsupported =
        DetectHeldWeaponTypeThirdPersonGrip(PlayerIndex, Pawn)
    if ThirdPersonType ~= nil or ThirdPersonUnsupported == true then
        return ThirdPersonType, ThirdPersonInfo, ThirdPersonUnsupported == true
    end
    return nil, tostring(Info) .. " | " .. tostring(ThirdPersonInfo), false
end

function CycleHeldWeaponSkin(PlayerIndex, Source)
    if not MissionReady then return false end
    local Controller = GetPlayer(PlayerIndex)
    if not IsValidObject(Controller) then return false end
    local TypeName, DetectInfo, Unsupported = DetectHeldWeaponType(PlayerIndex)
    if TypeName == nil then
        if Unsupported then
            ScreenMessage(PlayerIndex, Controller, "WEAPON SKIN: NO SUPPORTED SKIN FOR THIS WEAPON")
        else
            ScreenMessage(PlayerIndex, Controller, "WEAPON SKIN: CURRENT WEAPON NOT DETECTED")
        end
        Log("Weapon skin P%d detection miss source=%s unsupported=%s | %s",
            PlayerIndex, tostring(Source), tostring(Unsupported == true), WeaponSkinClip(DetectInfo, 700))
        return false
    end

    local Def = WeaponSkinDefinitions[TypeName]
    local Catalog = BuildWeaponSkinCatalog(TypeName)
    if Catalog == nil or #Catalog < 2 then
        ScreenMessage(PlayerIndex, Controller, string.format("%s: NO ALTERNATE SKIN FOUND", tostring(Def and Def.Label or TypeName)))
        return false
    end
    local Settings, SettingsInfo = GetUserSettings(PlayerIndex)
    if not IsValidObject(Settings) then
        Log("Weapon skin P%d settings unavailable: %s", PlayerIndex, tostring(SettingsInfo))
        return false
    end
    local CurrentIndex = WeaponSkinCurrentIndex(Settings, Def, Catalog)
    local NextIndex, Skipped = FindNextAvailableCustomizationIndex(PlayerIndex, Catalog, CurrentIndex, 1)
    if NextIndex == nil or NextIndex == CurrentIndex then
        ScreenMessage(PlayerIndex, Controller,
            string.format("%s: NO OTHER OWNED SKIN FOUND", tostring(Def and Def.Label or TypeName)))
        Log("Weapon skin P%d no eligible alternate type=%s skipped=%d",
            PlayerIndex, tostring(TypeName), tonumber(Skipped) or 0)
        return false
    end
    local Entry = Catalog[NextIndex]
    local Ok, Info = ApplyWeaponSkinDirect(PlayerIndex, TypeName, Entry)
    if not Ok then
        ScreenMessage(PlayerIndex, Controller, "WEAPON SKIN CHANGE FAILED - SEE UE4SS.LOG")
        Log("Weapon skin P%d apply failed: %s", PlayerIndex, tostring(Info))
        return false
    end
    Log("Weapon skin P%d cycle source=%s type=%s index=%d/%d skin=%s lockedSkipped=%d",
        PlayerIndex, tostring(Source), tostring(TypeName), NextIndex, #Catalog, tostring(Entry.Skin),
        tonumber(Skipped) or 0)
    ScreenMessage(PlayerIndex, Controller,
        string.format("P%d %s SKIN %02d/%02d - %s", PlayerIndex, Def.Label, NextIndex, #Catalog, Entry.Name))
    return true
end

local function EnsureCarrier(Quiet)
    if IsValidObject(ArmorCustomizationCarrier) and IsValidObject(ArmorCustomizationList) then return true end

    local Wrapper = FindLiveWrapperByEntry(
        "Splintered Warden",
        "Blam.Customization.MasterChief.Blammite"
    )
    if not IsValidObject(Wrapper) then
        local Wrappers = nil
        pcall(function() Wrappers = FindAllOf("BP_CustomizationListDataWrapper_C") end)
        if Wrappers ~= nil then
            for _, Candidate in ipairs(Wrappers) do
                if IsValidObject(Candidate) then Wrapper = Candidate break end
            end
        end
    end
    local List = FindCustomizationList()
    if not IsValidObject(Wrapper) or not IsValidObject(List) then
        return false
    end

    ArmorCustomizationCarrier = Wrapper
    ArmorCustomizationList = List
    local Current = ""
    pcall(function() Current = GetTagName(Wrapper.SkinGameplayTag) end)
    if ArmorCatalog ~= nil then
        for I, Entry in ipairs(ArmorCatalog) do
            if Entry.Skin == Current then
                CatalogIndex[1] = I
                CatalogIndex[2] = I
                break
            end
        end
    end
    if not Quiet then
        Log("ARMOR carrier cached | current=%s | p1index=%d p2index=%d",
            Current, CatalogIndex[1], CatalogIndex[2])
    else
        Log("ARMOR auto-cached live customization carrier/list | current=%s", Current)
    end
    return true
end

-- Legacy frontend bootstrap polling removed; the bounded fallback in MainStateTick
-- is sufficient when the direct armor settings path is unavailable.

local function ApplyArmorSelection(PlayerIndex, Index)
    if ArmorCatalog == nil or #ArmorCatalog == 0 then
        if not BuildCatalog() then return false end
    end
    if Index < 1 then Index = #ArmorCatalog end
    if Index > #ArmorCatalog then Index = 1 end

    local Player = GetPlayer(PlayerIndex)
    if not IsValidObject(Player) then return false end
    local Entry = ArmorCatalog[Index]
    local Available, AvailabilityInfo = IsCustomizationEntryAvailable(PlayerIndex, Entry)
    if not Available then
        Log("ARMOR P%d blocked package=%s skin=%s reason=%s",
            PlayerIndex, tostring(Entry.Package), tostring(Entry.Skin), tostring(AvailabilityInfo))
        ScreenMessage(PlayerIndex, Player, "ARMOR: PREMIUM CONTENT NOT OWNED")
        return false
    end

    -- Primary armor route: use the per-local-user settings API. This works without
    -- ever constructing/opening the customization menu and naturally supports
    -- singleplayer (local user 0) as well as splitscreen P2 (local user 1).
    local DirectOk, DirectInfo = ApplyDirect(PlayerIndex, Entry)
    if DirectOk then
        CatalogIndex[PlayerIndex] = Index
        ScreenMessage(PlayerIndex, Player,
            string.format("P%d ARMOR %02d/%02d - %s", PlayerIndex, Index, #ArmorCatalog, Entry.Short))
        return true
    end
    Log("ARMOR P%d direct route unavailable (%s); trying legacy widget fallback",
        PlayerIndex, tostring(DirectInfo))

    if not EnsureCarrier(false) then
        ScreenMessage(PlayerIndex, Player, "Armor browser: direct settings API unavailable; see UE4SS.log")
        Log("ARMOR P%d apply aborted: direct route and legacy carrier/list unavailable", PlayerIndex)
        return false
    end

    local Wrapper = ArmorCustomizationCarrier
    local List = ArmorCustomizationList
    local SkinTag, PackageTag, OriginalUnlocked = nil, nil, nil
    pcall(function() SkinTag = Wrapper.SkinGameplayTag end)
    pcall(function() PackageTag = Wrapper.PackageGameplayTag end)
    pcall(function() OriginalUnlocked = Wrapper.Unlocked end)
    if SkinTag == nil or PackageTag == nil then return false end

    local OriginalSkin = GetTagName(SkinTag)
    local OriginalPackage = GetTagName(PackageTag)
    local SkinOk = SetTagName(SkinTag, Entry.Skin)
    if not SkinOk then return false end
    local PackageOk = SetTagName(PackageTag, Entry.Package)
    if not PackageOk then
        SetTagName(SkinTag, OriginalSkin)
        return false
    end
    local UnlockOk = pcall(function() Wrapper.Unlocked = true end)
    if not UnlockOk then
        SetTagName(SkinTag, OriginalSkin)
        SetTagName(PackageTag, OriginalPackage)
        return false
    end

    local Started = os.clock()
    InternalApply = true
    local ReplayOk, ReplayErr = pcall(function()
        List:HandleItemActivated(Player, 0, Wrapper)
    end)
    InternalApply = false
    local ElapsedMs = (os.clock() - Started) * 1000.0

    SetTagName(SkinTag, OriginalSkin)
    SetTagName(PackageTag, OriginalPackage)
    pcall(function() Wrapper.Unlocked = OriginalUnlocked end)

    if ReplayOk then CatalogIndex[PlayerIndex] = Index end
    Log("ARMOR P%d APPLY [%02d/%02d] %s | replay=%s | %.2fms",
        PlayerIndex, Index, #ArmorCatalog, Entry.Short,
        ReplayOk and "ok" or tostring(ReplayErr), ElapsedMs)
    if ReplayOk then
        ScreenMessage(PlayerIndex, Player,
            string.format("P%d ARMOR %02d/%02d - %s", PlayerIndex, Index, #ArmorCatalog, Entry.Short))
    end
    return ReplayOk
end

function ProtectedInputKeyDown(Player, Key)
    return Player:IsInputKeyDown(Key)
end

local function IsKeyDown(Player, Key)
    local Ok, Down = pcall(ProtectedInputKeyDown, Player, Key)
    return Ok and Down == true
end

-- Menu-only controller drop-out. Reuse the already-running 40 ms state worker
-- instead of creating a new timer. The hot path is dormant unless a real local P2
-- exists AND the lifecycle has confirmed the actual Frontend. The input query is
-- made against a dedicated frontend P2 binding so a still-valid campaign controller
-- left behind by travel can never steal the leave gesture.
P2MenuLeaveController = P2MenuLeaveController or nil
P2MenuLeaveBindingName = P2MenuLeaveBindingName or ""
P2MenuLeaveHoldTicks = P2MenuLeaveHoldTicks or 0
P2MenuLeaveHoldLatched = P2MenuLeaveHoldLatched or false
P2MenuLeaveHoldThresholdTicks = 50 -- nominally about 2 seconds

function RefreshFrontendP2LeaveBinding()
    if not PlayerTwoExpected then
        P2MenuLeaveController = nil
        P2MenuLeaveBindingName = ""
        return false
    end

    local CurrentP2 = FindLocalPlayerController(1)
    if not IsValidObject(CurrentP2) then
        P2MenuLeaveController = nil
        P2MenuLeaveBindingName = ""
        return false
    end

    local CurrentName = EarlyFullName(CurrentP2)
    if not string.find(string.lower(CurrentName or ""), "/game/levels/ui/frontend/", 1, true) then
        P2MenuLeaveController = nil
        P2MenuLeaveBindingName = ""
        return false
    end

    P2MenuLeaveController = CurrentP2
    PlayerControllerTable[2] = CurrentP2
    if P2MenuLeaveBindingName ~= CurrentName then
        P2MenuLeaveBindingName = CurrentName
        Log("P2MENU bound leave gesture to current frontend P2 controller")
    end
    return true
end

function PollFrontendP2LeaveHold()
    local P2 = P2MenuLeaveController
    if not FrontendBoundarySeen or not PlayerTwoExpected or not IsValidObject(P2) then
        P2MenuLeaveHoldTicks = 0
        P2MenuLeaveHoldLatched = false
        return
    end

    local Down = IsKeyDown(P2, KeyFaceButtonBottom)
    if not Down then
        P2MenuLeaveHoldTicks = 0
        P2MenuLeaveHoldLatched = false
        return
    end

    if P2MenuLeaveHoldLatched then return end

    P2MenuLeaveHoldTicks = P2MenuLeaveHoldTicks + 1
    if P2MenuLeaveHoldTicks == 1 then
        Log("P2MENU hold A started on current frontend P2; hold to leave")
    end

    if P2MenuLeaveHoldTicks >= P2MenuLeaveHoldThresholdTicks then
        P2MenuLeaveHoldLatched = true
        Log("P2MENU hold A completed; removing local P2")
        DestroyPlayer("P2 hold A")
    end
end

local InputState = {
    [1] = { Left=false, Right=false, Up=false, Down=false, Weapon=false, Voice=false, SkinPrev=false, SkinNext=false, VehiclePrev=false, VehicleNext=false, Perspective=false },
    [2] = { Left=false, Right=false, Up=false, Down=false, Weapon=false, Voice=false, SkinPrev=false, SkinNext=false, VehiclePrev=false, VehicleNext=false, Perspective=false },
}

KeyboardPendingArmorDelta = KeyboardPendingArmorDelta or 0
KeyboardPendingWeaponSkin = KeyboardPendingWeaponSkin or false
KeyboardPendingWeaponSkinLabel = KeyboardPendingWeaponSkinLabel or "Ctrl+X"
KeyboardPendingLives = KeyboardPendingLives or false
KeyboardPendingVoiceToggle = KeyboardPendingVoiceToggle or false
KeyboardPendingSplit = KeyboardPendingSplit or false
KeyboardPendingVehicleColorDelta = KeyboardPendingVehicleColorDelta or 0
KeyboardPendingPerspective = KeyboardPendingPerspective or false

-- Controllers=1 can leave CommonUI's keyboard Back/Escape route without a
-- usable P1 target after P2 opens and closes the local pause/settings stack.
-- Keyboard Escape recovery -----------------------------------------------------
-- In either controller-count mode Halo can leave its native P1 keyboard pause
-- route unusable after P2 has owned and released a fullscreen menu. Recovery is
-- deliberately narrow:
--   1. never consume/replace the physical Escape press;
--   2. give Halo's native P1 UI route a short grace window;
--   3. never interfere while P2 owns active CommonUI;
--   4. if native P1 Escape produced no UI, re-enter through HaloUIManager's own
--      authored OpenWidgetFullscreen(UI.Widget.OptionsMenu, P1, nil) path.
--
-- This authored path safely performs Halo's internal fullscreen-player handoff.
-- Do not call SetCurrentFullscreenPlayer directly: development testing proved
-- that invoking that native setter out of context can crash Halo.
KeyboardEscapePending = KeyboardEscapePending or false
KeyboardEscapeRequestGeneration = KeyboardEscapeRequestGeneration or 0
KeyboardEscapeUiActivityGenerationP1 = KeyboardEscapeUiActivityGenerationP1 or 0
KeyboardEscapeActivityP1AtRequest = KeyboardEscapeActivityP1AtRequest or 0
KeyboardEscapeRecoveryHooksReady = KeyboardEscapeRecoveryHooksReady or false
KeyboardEscapeRecoveryDelayMs = 160

function KeyboardEscapeWidgetControllerId(Widget)
    if not IsValidObject(Widget) then return nil end
    local Controller = nil
    pcall(function() Controller = Widget:GetOwningPlayer() end)
    if not IsValidObject(Controller) then return nil end
    if Controller == PlayerControllerTable[1] then return 0 end
    if Controller == PlayerControllerTable[2] then return 1 end
    local Id = nil
    pcall(function()
        if IsValidObject(Controller.Player) then Id = Controller.Player.ControllerId end
    end)
    return tonumber(Id)
end

function KeyboardEscapeNoteUiActivity(Source, Widget)
    if KeyboardEscapeWidgetControllerId(Widget) == 0 then
        KeyboardEscapeUiActivityGenerationP1 = KeyboardEscapeUiActivityGenerationP1 + 1
    end
end

function KeyboardEscapeControllerIdForPlayerController(Controller)
    local C = Unwrap(Controller)
    if not IsValidObject(C) then return nil end
    if C == PlayerControllerTable[1] then return 0 end
    if C == PlayerControllerTable[2] then return 1 end
    local Id = nil
    pcall(function()
        if IsValidObject(C.Player) then Id = C.Player.ControllerId end
    end)
    return tonumber(Id)
end

function KeyboardEscapePlatformUserInternalId(Value)
    local V = Unwrap(Value)
    if V == nil then return nil end
    local Internal = nil
    pcall(function() Internal = V.InternalId end)
    if Internal == nil and type(V) == 'table' then
        Internal = V.InternalId or V.internalId or V.InternalID or V[1]
    end
    return tonumber(Internal)
end

function KeyboardEscapeReadCurrentFullscreenPlayerId(Manager)
    local M = Manager
    if not IsValidObject(M) then M = FindLive('HaloUIManagerSubsystem') end
    if not IsValidObject(M) then return false, nil, 'HaloUIManagerSubsystem unavailable' end
    local Ok, Value = pcall(function() return M:GetCurrentFullscreenPlayerId() end)
    if not Ok then return false, nil, tostring(Value or 'GetCurrentFullscreenPlayerId failed') end
    return true, Unwrap(Value), ''
end

function KeyboardEscapeObserveHaloFullscreenOwner(Source)
    local Manager = FindLive('HaloUIManagerSubsystem')
    if not IsValidObject(Manager) then
        Log('INPUT ESC owner read unavailable source=%s', tostring(Source or 'observe'))
        return nil
    end

    local CurrentOk, Current, CurrentErr = KeyboardEscapeReadCurrentFullscreenPlayerId(Manager)
    local CurrentInternal = KeyboardEscapePlatformUserInternalId(Current)
    local InputOk, InputEnabled = pcall(function() return Manager:IsInputEnabled() end)
    Log('INPUT ESC owner (%s): current_ok=%s current_internal=%s input_ok=%s input_enabled=%s err=%s',
        tostring(Source or 'observe'), tostring(CurrentOk), tostring(CurrentInternal),
        tostring(InputOk), tostring(InputEnabled), tostring(CurrentErr or ''))
    return CurrentInternal
end

function KeyboardEscapeHasActiveCommonUIForControllerId(ControllerId)
    local Objects = nil
    local Ok = pcall(function() Objects = FindAllOf('CommonActivatableWidget') end)
    if not Ok or Objects == nil then return false, nil end
    for _, Raw in ipairs(ArrayValues(Objects)) do
        local Widget = Unwrap(Raw)
        if IsValidObject(Widget) and KeyboardEscapeWidgetControllerId(Widget) == ControllerId then
            local Active = false
            pcall(function() Active = Widget:IsActivated() == true end)
            if not Active then pcall(function() Active = Widget.bIsActive == true end) end
            if Active then return true, tostring(SafeFullName(Widget) or '') end
        end
    end
    return false, nil
end

function KeyboardEscapeTryP1CommonUIBack()
    local Objects = nil
    local FindOk, FindErr = pcall(function() Objects = FindAllOf('CommonActivatableWidget') end)
    if not FindOk or Objects == nil then
        Log('INPUT ESC recovery: CommonActivatableWidget scan unavailable: %s', tostring(FindErr))
        return false
    end

    local Candidates = {}
    for _, Raw in ipairs(ArrayValues(Objects)) do
        local Widget = Unwrap(Raw)
        if IsValidObject(Widget) and KeyboardEscapeWidgetControllerId(Widget) == 0 then
            local Active = false
            pcall(function() Active = Widget:IsActivated() == true end)
            if not Active then pcall(function() Active = Widget.bIsActive == true end) end
            if Active then
                local Name = tostring(SafeFullName(Widget) or '')
                local Lower = string.lower(Name)
                local Score = #Name
                if string.find(Lower, 'controller', 1, true) then Score = Score + 6000 end
                if string.find(Lower, 'settings', 1, true) then Score = Score + 5000 end
                if string.find(Lower, 'pause', 1, true) then Score = Score + 4000 end
                if string.find(Lower, 'menu', 1, true) then Score = Score + 2000 end
                local BackHandler = false
                pcall(function() BackHandler = Widget.bIsBackHandler == true end)
                Candidates[#Candidates + 1] = {
                    Widget = Widget,
                    Name = Name,
                    Score = Score,
                    BackHandler = BackHandler,
                }
            end
        end
    end

    if #Candidates == 0 then return false end
    table.sort(Candidates, function(A, B) return A.Score > B.Score end)

    for _, Candidate in ipairs(Candidates) do
        local Handled = false
        local Ok = pcall(function() Handled = Candidate.Widget:BP_OnHandleBackAction() == true end)
        if Ok and Handled then
            Log('INPUT ESC recovery: routed Blueprint CommonUI Back to P1 target=%s', Candidate.Name)
            return true
        end
    end

    for _, Candidate in ipairs(Candidates) do
        if Candidate.BackHandler then
            local NativeOk = pcall(function() Candidate.Widget:HandleBackAction() end)
            if NativeOk then
                Log('INPUT ESC recovery: routed native CommonUI Back to P1 target=%s', Candidate.Name)
                return true
            end
            local DeactivateOk = pcall(function() Candidate.Widget:DeactivateWidget() end)
            if DeactivateOk then
                Log('INPUT ESC recovery: deactivated P1 back-handler target=%s', Candidate.Name)
                return true
            end
        end
    end
    return false
end

function KeyboardEscapeTryDirectHaloP1OptionsOpen(Request, OwnerBefore)
    if Request ~= KeyboardEscapeRequestGeneration or ModTeardownGuard then return false end
    local OwnerNumber = tonumber(OwnerBefore)
    -- Only the two local fullscreen-owner IDs observed in split-screen are accepted.
    -- Unknown values fail closed rather than forcing a menu into an uncertain state.
    if OwnerNumber ~= 0 and OwnerNumber ~= 1 then
        Log('INPUT ESC direct reentry skipped: current_internal=%s', tostring(OwnerBefore))
        return false
    end

    local Manager = FindLive('HaloUIManagerSubsystem')
    local P1 = GetPlayer(1)
    if not IsValidObject(Manager) or not IsValidObject(P1) then
        Log('INPUT ESC direct reentry unavailable: manager=%s p1=%s',
            tostring(IsValidObject(Manager)), tostring(IsValidObject(P1)))
        return false
    end

    local ControllerId = KeyboardEscapeControllerIdForPlayerController(P1)
    if tonumber(ControllerId) ~= 0 then
        Log('INPUT ESC direct reentry blocked: P1 ControllerId=%s', tostring(ControllerId))
        return false
    end

    local Tag = MakeGameplayTag('UI.Widget.OptionsMenu')
    if Tag == nil then
        Log('INPUT ESC direct reentry unavailable: failed to construct UI.Widget.OptionsMenu tag')
        return false
    end

    local BeforeP1 = KeyboardEscapeUiActivityGenerationP1
    Log('INPUT ESC direct reentry: request=%d owner_before=%s controller_id=0',
        tonumber(Request) or 0, tostring(OwnerNumber))

    -- The third reflected parameter behaves as transient/out scratch storage on
    -- authored calls. Passing nil lets ProcessEvent provide the proper parameter
    -- buffer instead of retaining a stale UE4SS hook wrapper.
    local CallOk, CallErr = pcall(function()
        Manager:OpenWidgetFullscreen(Tag, P1, nil)
    end)
    if not CallOk then
        Log('INPUT ESC direct reentry failed: %s', tostring(CallErr))
        return false
    end

    if BeforeP1 ~= KeyboardEscapeUiActivityGenerationP1 then
        Log('INPUT ESC direct reentry success: P1 pause UI opened owner_before=%s', tostring(OwnerNumber))
    end

    ExecuteInGameThreadWithDelay(180, function()
        if Request ~= KeyboardEscapeRequestGeneration or ModTeardownGuard then return end
        if BeforeP1 ~= KeyboardEscapeUiActivityGenerationP1 then return end
        local OwnerAfter = KeyboardEscapeObserveHaloFullscreenOwner('direct reentry settle')
        Log('INPUT ESC direct reentry produced no P1 UI owner_after=%s', tostring(OwnerAfter))
    end)
    return true
end

function KeyboardEscapeScheduleRecovery()
    if not KeyboardEscapePending then return end
    KeyboardEscapePending = false
    if (ConfiguredControllerCount ~= 1 and ConfiguredControllerCount ~= 2) or ModTeardownGuard then return end
    if CurrentWorldSessionKind() ~= 'campaign' then return end
    if not IsValidObject(GetPlayer(2)) then return end

    local Request = KeyboardEscapeRequestGeneration
    local P1ActivityAtKey = KeyboardEscapeActivityP1AtRequest
    ExecuteInGameThreadWithDelay(KeyboardEscapeRecoveryDelayMs, function()
        if ModTeardownGuard or (ConfiguredControllerCount ~= 1 and ConfiguredControllerCount ~= 2) then return end
        if Request ~= KeyboardEscapeRequestGeneration then return end
        if P1ActivityAtKey ~= KeyboardEscapeUiActivityGenerationP1 then
            Log('INPUT ESC recovery: native P1 UI route handled Escape')
            return
        end

        local P2OwnsUi, P2Target = KeyboardEscapeHasActiveCommonUIForControllerId(1)
        if P2OwnsUi then
            Log('INPUT ESC recovery: suppressed while P2 owns CommonUI target=%s', tostring(P2Target or 'P2 UI'))
            return
        end

        local P1OwnsUi = KeyboardEscapeHasActiveCommonUIForControllerId(0)
        if P1OwnsUi then
            KeyboardEscapeTryP1CommonUIBack()
            return
        end

        local CurrentOwner = KeyboardEscapeObserveHaloFullscreenOwner('failed native Escape')
        if KeyboardEscapeTryDirectHaloP1OptionsOpen(Request, CurrentOwner) then return end
        Log('INPUT ESC recovery: direct HaloUI reentry not started current_internal=%s', tostring(CurrentOwner))
    end)
end

function RegisterKeyboardEscapeRecoveryHooks()
    if KeyboardEscapeRecoveryHooksReady then return true end

    -- Native activation/deactivation is the authoritative signal. BP events are
    -- retained as secondary coverage for unusual derived CommonUI widgets.
    local ActivateOk = pcall(function()
        RegisterHook(
            '/Script/CommonUI.CommonActivatableWidget:ActivateWidget',
            function(Context, ...) end,
            function(Context, ...) KeyboardEscapeNoteUiActivity('ActivateWidget', Unwrap(Context)) end
        )
    end)
    local DeactivateOk = pcall(function()
        RegisterHook(
            '/Script/CommonUI.CommonActivatableWidget:DeactivateWidget',
            function(Context, ...) end,
            function(Context, ...) KeyboardEscapeNoteUiActivity('DeactivateWidget', Unwrap(Context)) end
        )
    end)
    local BPActivatedOk = pcall(function()
        RegisterHook(
            '/Script/CommonUI.CommonActivatableWidget:BP_OnActivated',
            function(Context, ...) end,
            function(Context, ...) KeyboardEscapeNoteUiActivity('BP_OnActivated', Unwrap(Context)) end
        )
    end)
    local BPDeactivatedOk = pcall(function()
        RegisterHook(
            '/Script/CommonUI.CommonActivatableWidget:BP_OnDeactivated',
            function(Context, ...) end,
            function(Context, ...) KeyboardEscapeNoteUiActivity('BP_OnDeactivated', Unwrap(Context)) end
        )
    end)

    KeyboardEscapeRecoveryHooksReady = ActivateOk or DeactivateOk or BPActivatedOk or BPDeactivatedOk
    Log('INPUT ESC recovery hooks: activate=%s deactivate=%s bp_activated=%s bp_deactivated=%s',
        tostring(ActivateOk), tostring(DeactivateOk), tostring(BPActivatedOk), tostring(BPDeactivatedOk))
    return KeyboardEscapeRecoveryHooksReady
end

function ProcessPendingKeyboardInput()
    -- RegisterKeyBind callbacks are not guaranteed to execute on Halo's game thread.
    -- Queue only tiny flags there and consume them from the existing P1 ReceiveTick
    -- hook, which is the same game-thread path already proven by the controller binds.
    if KeyboardPendingArmorDelta ~= 0 then
        local Delta = KeyboardPendingArmorDelta
        KeyboardPendingArmorDelta = 0
        if MissionReady and IsValidObject(GetPlayer(1)) then
            PendingApply[1] = Delta
            Log("ARMOR keyboard P1 %s armor: %s", Delta < 0 and "previous" or "next", Delta < 0 and "Ctrl+Left" or "Ctrl+Right")
        else
            Log("ARMOR keyboard ignored: campaign P1 HUD not ready")
        end
    end

    if KeyboardPendingWeaponSkin then
        KeyboardPendingWeaponSkin = false
        local Label = tostring(KeyboardPendingWeaponSkinLabel or "Ctrl+X")
        if MissionReady then
            CycleHeldWeaponSkin(1, "keyboard " .. Label)
        end
    end

    if KeyboardPendingLives then
        KeyboardPendingLives = false
        if LivesNetworkClientBlocked then
            ShowLimitedRespawnsHostOnlyNotice("keyboard Ctrl+Up")
        elseif SetupActive and not SelectionLocked then
            CycleMissionLives()
        else
            Log("LIVES Ctrl+Up ignored P1 setupActive=%s locked=%s", tostring(SetupActive), tostring(SelectionLocked))
        end
    end

    if KeyboardPendingVoiceToggle then
        KeyboardPendingVoiceToggle = false
        if MissionReady then
            ToggleLivesVoiceAnnouncements(1, "keyboard Ctrl+F8")
        else
            Log("LIVESVOICE Ctrl+F8 ignored: campaign P1 HUD not ready")
        end
    end

    if KeyboardPendingSplit then
        KeyboardPendingSplit = false
        if IsValidObject(GetPlayer(2)) then
            ToggleSplitOrientation("keyboard Ctrl+Down")
        else
            Log("SPLIT Ctrl+Down ignored: no local P2")
        end
    end

    if KeyboardPendingClassicSkinDelta ~= 0 then
        -- V7: drain one queued Classic step per game-thread tick instead of
        -- collapsing rapid Shift+Arrow presses while a model swap is settling.
        local Pending = tonumber(KeyboardPendingClassicSkinDelta) or 0
        local Delta = Pending < 0 and -1 or 1
        KeyboardPendingClassicSkinDelta = Pending - Delta
        CycleDefaultSpartanSkin(1, Delta,
            Delta < 0 and "keyboard Shift+Left" or "keyboard Shift+Right")
    end

    if KeyboardPendingVehicleColorDelta ~= 0 then
        local Delta = KeyboardPendingVehicleColorDelta
        KeyboardPendingVehicleColorDelta = 0
        CycleOccupiedVehicleColor(1, Delta,
            Delta < 0 and "keyboard Ctrl+PageUp" or "keyboard Ctrl+PageDown")
    end

    if KeyboardPendingPerspective then
        KeyboardPendingPerspective = false
        TogglePerspectivePlayer(1, "keyboard Ctrl+B")
    end
end

-- Controller shortcuts use Halo/Unreal's normal reflected local-player key state.
local function PollPlayerInput(PlayerIndex)
    local Player = GetPlayer(PlayerIndex)
    local State = InputState[PlayerIndex]
    -- GetPlayer already performs the guarded UObject validity check.
    if Player == nil then
        State.Left = false
        State.Right = false
        State.Up = false
        State.Down = false
        State.Weapon = false
        State.Voice = false
        State.SkinPrev = false
        State.SkinNext = false
        State.VehiclePrev = false
        State.VehicleNext = false
        State.Perspective = false
        return
    end

    if PlayerIndex == 1 and OrientationToggleCooldownTicks > 0 then
        OrientationToggleCooldownTicks = OrientationToggleCooldownTicks - 1
    end

    local HasLocalP2 = (PlayerIndex == 2) or GetPlayer(2) ~= nil
    if PlayerIndex == 1 then
        SetPerspectiveNativeMode(HasLocalP2, "controller topology")
        SetPerspectiveContextShift(PerspectiveShouldUseNetworkClientShift(Player, HasLocalP2), "controller topology")
    end

    local Shoulder = IsKeyDown(Player, KeyRightShoulder)
    local ColorModifier = IsKeyDown(Player, KeyFaceButtonLeft)
    if not Shoulder and not ColorModifier then
        State.Left = false
        State.Right = false
        State.Up = false
        State.Down = false
        State.Weapon = false
        State.Voice = false
        State.SkinPrev = false
        State.SkinNext = false
        State.VehiclePrev = false
        State.VehicleNext = false
        State.Perspective = false
        return
    end

    local LeftDown = Shoulder and IsKeyDown(Player, KeyDPadLeft) or false
    local RightDown = Shoulder and IsKeyDown(Player, KeyDPadRight) or false
    local UpDown = Shoulder and IsKeyDown(Player, KeyDPadUp) or false
    local DownDown = HasLocalP2 and Shoulder and IsKeyDown(Player, KeyDPadDown) or false
    local WeaponDown = Shoulder and IsKeyDown(Player, KeyFaceButtonLeft) or false
    -- Limited Respawns and its voice setting are host-P1 authoritative.
    -- P2 must never be able to toggle the host broadcast.
    local VoiceDown = PlayerIndex == 1 and Shoulder and IsKeyDown(Player, KeyFaceButtonTop) or false
    local PerspectiveDown = Shoulder and IsKeyDown(Player, KeyFaceButtonRight) or false
    local SkinPrevDown = ColorModifier and IsKeyDown(Player, KeyDPadLeft) or false
    local SkinNextDown = ColorModifier and IsKeyDown(Player, KeyDPadRight) or false
    local VehiclePrevDown = Shoulder and IsKeyDown(Player, KeyLeftThumbstick) or false
    local VehicleNextDown = Shoulder and IsKeyDown(Player, KeyRightThumbstick) or false

    local LeftCombo = Shoulder and LeftDown
    local RightCombo = Shoulder and RightDown
    local UpCombo = Shoulder and UpDown
    local DownCombo = HasLocalP2 and Shoulder and DownDown
    local WeaponCombo = Shoulder and WeaponDown
    local VoiceCombo = Shoulder and VoiceDown
    local PerspectiveCombo = Shoulder and PerspectiveDown
    local SkinPrevCombo = SkinPrevDown
    local SkinNextCombo = SkinNextDown
    local VehiclePrevCombo = Shoulder and VehiclePrevDown
    local VehicleNextCombo = Shoulder and VehicleNextDown
    local LeftPressed = LeftCombo and not State.Left
    local RightPressed = RightCombo and not State.Right
    local UpPressed = UpCombo and not State.Up
    local DownPressed = DownCombo and not State.Down
    local WeaponPressed = WeaponCombo and not State.Weapon
    local VoicePressed = VoiceCombo and not State.Voice
    local PerspectivePressed = PerspectiveCombo and not State.Perspective
    local SkinPrevPressed = SkinPrevCombo and not State.SkinPrev
    local SkinNextPressed = SkinNextCombo and not State.SkinNext
    local VehiclePrevPressed = VehiclePrevCombo and not State.VehiclePrev
    local VehicleNextPressed = VehicleNextCombo and not State.VehicleNext
    State.Left = LeftCombo
    State.Right = RightCombo
    State.Up = UpCombo
    State.Down = DownCombo
    State.Weapon = WeaponCombo
    State.Voice = VoiceCombo
    State.Perspective = PerspectiveCombo
    State.SkinPrev = SkinPrevCombo
    State.SkinNext = SkinNextCombo
    State.VehiclePrev = VehiclePrevCombo
    State.VehicleNext = VehicleNextCombo

    if LeftPressed or RightPressed then
        Log("ARMOR P%d COMBO edge: RB=%s LEFT=%s RIGHT=%s",
            PlayerIndex, tostring(Shoulder), tostring(LeftPressed), tostring(RightPressed))
    end

    if UpPressed then
        if PlayerIndex == 1 and LivesNetworkClientBlocked then
            ShowLimitedRespawnsHostOnlyNotice("controller P1 RB+DPAD_UP")
        elseif PlayerIndex == 1 and SetupActive and not SelectionLocked then
            CycleMissionLives()
        else
            Log("LIVES RB+DPAD_UP ignored P%d setupActive=%s locked=%s",
                PlayerIndex, tostring(SetupActive), tostring(SelectionLocked))
        end
    end

    if DownPressed and OrientationToggleCooldownTicks <= 0 then
        OrientationToggleCooldownTicks = 15
        Log("SPLIT controller orientation request P%d shoulder=%s",
            PlayerIndex, tostring(Shoulder))
        ToggleSplitOrientation(string.format("controller P%d", PlayerIndex))
    end

    if WeaponPressed and MissionReady then
        CycleHeldWeaponSkin(PlayerIndex, string.format("controller P%d RB+X", PlayerIndex))
    end

    if VoicePressed and MissionReady and PlayerIndex == 1 then
        ToggleLivesVoiceAnnouncements(1, "controller P1 RB+Y")
    end

    if PerspectivePressed and MissionReady then
        Log("PERSPECTIVE P%d RB+B combo edge CONFIRMED", PlayerIndex)
        TogglePerspectivePlayer(PlayerIndex, string.format("controller P%d RB+B", PlayerIndex))
    end

    if VehiclePrevPressed and MissionReady then
        CycleOccupiedVehicleColor(PlayerIndex, -1, string.format("controller P%d RB+LS", PlayerIndex))
    elseif VehicleNextPressed and MissionReady then
        CycleOccupiedVehicleColor(PlayerIndex, 1, string.format("controller P%d RB+RS", PlayerIndex))
    end

    if (SkinPrevPressed or SkinNextPressed) and MissionReady then
        local Delta = SkinPrevPressed and -1 or 1
        CycleDefaultSpartanSkin(PlayerIndex, Delta,
            string.format("controller P%d X+DPAD_%s", PlayerIndex, SkinPrevPressed and "LEFT" or "RIGHT"))
    end

    if LeftPressed then
        PendingApply[PlayerIndex] = -1
    elseif RightPressed then
        PendingApply[PlayerIndex] = 1
    end
end

function ProcessPendingApply()
    if ApplyBusy then return end
    if ApplyCooldownTicks > 0 then
        ApplyCooldownTicks = ApplyCooldownTicks - 1
        return
    end

    local First = PendingTurn
    local Second = (First == 1) and 2 or 1
    local PlayerIndex = nil
    if PendingApply[First] ~= 0 then
        PlayerIndex = First
    elseif PendingApply[Second] ~= 0 then
        PlayerIndex = Second
    end
    if PlayerIndex == nil then return end

    local Delta = PendingApply[PlayerIndex]
    PendingApply[PlayerIndex] = 0
    PendingTurn = (PlayerIndex == 1) and 2 or 1
    ApplyBusy = true

    if ArmorCatalog == nil or #ArmorCatalog == 0 then BuildCatalog() end
    if ArmorCatalog ~= nil and not IndexInitialized[PlayerIndex] then
        local Settings = GetUserSettings(PlayerIndex)
        if IsValidObject(Settings) then SyncCatalogIndex(PlayerIndex, Settings) end
    end

    local FromIndex = CatalogIndex[PlayerIndex]
    local TargetIndex, Skipped = FindNextAvailableCustomizationIndex(
        PlayerIndex, ArmorCatalog, FromIndex, Delta)
    if TargetIndex == nil or TargetIndex == FromIndex then
        local Controller = GetPlayer(PlayerIndex)
        if IsValidObject(Controller) then
            ScreenMessage(PlayerIndex, Controller, "ARMOR: NO OTHER OWNED MODEL FOUND")
        end
        Log("INPUT P%d ARMOR no eligible alternate from=%d delta=%d skipped=%d",
            PlayerIndex, FromIndex, Delta, tonumber(Skipped) or 0)
        ApplyBusy = false
        ApplyCooldownTicks = 5
        return
    end
    Log("INPUT P%d ARMOR apply begin from=%d delta=%d target=%d lockedSkipped=%d",
        PlayerIndex, FromIndex, Delta, TargetIndex, tonumber(Skipped) or 0)
    if ArmorSkinPrepareForModelSwap ~= nil then
        ArmorSkinPrepareForModelSwap(PlayerIndex, "separate armor-model browser")
    end
    local ApplyOk = ApplyArmorSelection(PlayerIndex, TargetIndex)
    Log("INPUT P%d ARMOR apply result=%s finalIndex=%d",
        PlayerIndex, tostring(ApplyOk == true), CatalogIndex[PlayerIndex])
    ApplyBusy = false
    ApplyCooldownTicks = 5
end

local function ResetInputState(Reason)
    InputState[1] = { Left=false, Right=false, Up=false, Down=false, Weapon=false, SkinPrev=false, SkinNext=false, VehiclePrev=false, VehicleNext=false, Perspective=false }
    InputState[2] = { Left=false, Right=false, Up=false, Down=false, Weapon=false, SkinPrev=false, SkinNext=false, VehiclePrev=false, VehicleNext=false, Perspective=false }
    OrientationToggleCooldownTicks = 0
    OrientationToggleRequested = false
    OrientationReapplyRequested = false
    OrientationToggleSource = ""
    OrientationHudStage = 0
    OrientationHudRemaining = 0.0
    PendingApply[1] = 0
    PendingApply[2] = 0
    ApplyBusy = false
    ApplyCooldownTicks = 0
    InternalApply = false
    WeaponSkinFastVisualReset()
    KeyboardPendingArmorDelta = 0
    KeyboardPendingWeaponSkin = false
    KeyboardPendingWeaponSkinLabel = "Ctrl+X"
    KeyboardPendingLives = false
    KeyboardPendingSplit = false
    KeyboardPendingVehicleColorDelta = 0
    KeyboardPendingClassicSkinDelta = 0
    KeyboardPendingPerspective = false
    -- V13: never carry an input cooldown or stale queued Classic press across
    -- respawn/map teardown/menu transitions. Invalidate any delayed unlock callback.
    if type(ClassicArmorInputCooldownActive) == "table" then
        ClassicArmorInputCooldownActive[1] = false
        ClassicArmorInputCooldownActive[2] = false
    end
    if type(ClassicArmorInputCooldownToken) == "table" then
        ClassicArmorInputCooldownToken[1] = (tonumber(ClassicArmorInputCooldownToken[1]) or 0) + 1
        ClassicArmorInputCooldownToken[2] = (tonumber(ClassicArmorInputCooldownToken[2]) or 0) + 1
    end
    KeyboardEscapePending = false
    KeyboardEscapeRequestGeneration = KeyboardEscapeRequestGeneration + 1
    KeyboardEscapeActivityP1AtRequest = KeyboardEscapeUiActivityGenerationP1
    if ArmorSkinDropAllRuntimeRefs ~= nil then
        ArmorSkinDropAllRuntimeRefs("input reset: " .. tostring(Reason or "state change"))
    end
    Log("GAMEPLAY input state reset: %s", tostring(Reason or "state change"))
end

local function ClearCarrier(Reason)
    ArmorCustomizationCarrier = nil
    ArmorCustomizationList = nil
    Log("ARMOR carrier cleared: %s", tostring(Reason or "state change"))
end

-- Central state worker. The bundled HCE UE4SS runtime provides the owned
-- game-thread delayed-action API. Keep one stable callback on the game thread
-- instead of a LoopAsync thread creating ExecuteInGameThread refs every 40 ms.
MainStateWorkerStarted = false
MainStateWorkerHandle = MainStateWorkerHandle or nil
ControllerRefreshCounter = 0
-- Late Blueprint binding compatibility for the HCE-specific UE4SS runtime.
-- That runtime intentionally starts Lua before campaign Blueprint UFunctions
-- exist, so the first ReceiveTick/RegisterHook attempt can legitimately fail.
ArmorTickHookRetryTicks = 0
ArmorTickFallbackRefreshTicks = 0

-- Local guest naming. P2 receives one randomized Spartan-style identity when
-- the mod-created local player becomes valid, e.g. Rook-308 or Kael-096. The
-- chosen identity is retained across mission travel and rerolled only after P2
-- is explicitly removed and created again.
P2NameRepairActive = false
P2NameRepairTicks = 0
P2NameRepairAttempts = 0
P2SpartanSessionName = P2SpartanSessionName or ""
P2SpartanRandomState = tonumber(P2SpartanRandomState) or 0
P2SpartanNamePool = P2SpartanNamePool or {
    "Elias","Rook","Kellan","Soren","Dax","Talon","Kael","Orin","Jace","Silas",
    "Niko","Vance","Dorian","Ronan","Axel","Mason","Cade","Drake","Reeve","Knox",
    "Torin","Bren","Ryker","Zane","Garrick","Nolan","Corbin","Lucan","Merrick","Rafe",
    "Declan","Seth","Jarek","Damon","Trent","Cole","Wade","Kane","Garrett","Owen",
    "Landon","Viktor","Caleb","Rowan","Marcus","Evan","Leon","Adrian","Roman","Trevor",
    "Grant","Connor","Alec","Nathan","Eric","Jason","Logan","Derek","Ethan","Julian"
}

function P2SpartanRandomNext(MaxValue)
    MaxValue=math.max(1,math.floor(tonumber(MaxValue) or 1))
    if P2SpartanRandomState<=0 then
        local Seed=tonumber(os.time()) or 1
        Seed=Seed+math.floor((tonumber(os.clock()) or 0)*1000000)+(tonumber(WarthogColorRuntimeGeneration) or 0)*7919
        P2SpartanRandomState=Seed%2147483647
        if P2SpartanRandomState<=0 then P2SpartanRandomState=1357911 end
    end
    P2SpartanRandomState=(P2SpartanRandomState*48271)%2147483647
    return (P2SpartanRandomState%MaxValue)+1
end

function EnsureP2SpartanSessionName()
    if TrimName(P2SpartanSessionName)~="" then return TrimName(P2SpartanSessionName) end
    local Base=P2SpartanNamePool[P2SpartanRandomNext(#P2SpartanNamePool)] or "Rook"
    local Number=P2SpartanRandomNext(999)
    P2SpartanSessionName=string.format("%s-%03d",tostring(Base),Number)
    Log("IDENTITY local P2 Spartan identity generated: %s",P2SpartanSessionName)
    return P2SpartanSessionName
end

function IdentityString(Value)
    if Value == nil then return "" end
    local Current = Value
    for _ = 1, 5 do
        local OkText, Text = pcall(function() return Current:ToString() end)
        if OkText and Text ~= nil then
            local S = tostring(Text)
            if S ~= "" and not string.find(S, "RemoteUnrealParam:", 1, true) and
               not string.find(S, "FString:", 1, true) and
               not string.find(S, "TrivialObject:", 1, true) then
                return S
            end
        end
        local OkGet, Next = pcall(function() return Current:get() end)
        if not OkGet or Next == nil or Next == Current then break end
        Current = Next
    end
    local S = tostring(Current or "")
    if string.find(S, "FString:", 1, true) or string.find(S, "TrivialObject:", 1, true) then return "" end
    return S
end

function TrimName(Name)
    local S = tostring(Name or "")
    S = string.gsub(S, "^%s+", "")
    S = string.gsub(S, "%s+$", "")
    return S
end

function ReadPlayerName(Controller)
    if not IsValidObject(Controller) or not IsValidObject(Controller.PlayerState) then return "" end
    local Raw = nil
    pcall(function() Raw = Controller.PlayerState:GetPlayerName() end)
    return TrimName(IdentityString(Raw))
end

function NameReady(Name)
    local S = TrimName(Name)
    if S == "" or string.match(S, "^%d+$") then return false end
    local Lower = string.lower(S)
    return Lower ~= "none" and Lower ~= "guest" and Lower ~= "player" and
        Lower ~= "player 1" and Lower ~= "player1" and Lower ~= "local player"
end

function PlayerStatesAliased(P1, P2)
    if not IsValidObject(P1) or not IsValidObject(P2) or
       not IsValidObject(P1.PlayerState) or not IsValidObject(P2.PlayerState) then return true end
    local Same = false
    pcall(function() Same = (P1.PlayerState == P2.PlayerState) end)
    if Same then return true end
    local A, B = SafeFullName(P1.PlayerState), SafeFullName(P2.PlayerState)
    return A ~= "" and B ~= "" and A == B
end

function IdentityControllerIsSecondarySplit(Controller)
    Controller=Unwrap(Controller)
    if not IsValidObject(Controller) then return false end
    local Player=nil
    pcall(function() Player=Unwrap(Controller.Player) end)
    local N=string.lower(tostring(SafeFullName(Player) or Player or ""))
    return string.find(N,"childconnection",1,true)~=nil
end

function IdentityNetworkMaybeSendP2NameFrontend(Source)
    local C2=Unwrap(GetPlayer(2))
    if not IsValidObject(C2) then C2=Unwrap(PlayerControllerTable and PlayerControllerTable[2] or nil) end
    local Name=TrimName(P2SpartanSessionName)
    if not IsValidObject(C2) or not string.match(Name,"^[A-Za-z]+%-%d%d%d$") or #Name>24 then return false end
    local Pid=ArmorSkinPlayerIdFromController(C2)
    if Pid==nil then Pid=NetworkIdentityRemotePlayerId(C2) end
    if Pid==nil then return false end
    local Sig=string.format("%d:%s",math.floor(Pid),Name)
    -- A successful local ServerExecRPC invocation is not proof that the frontend
    -- net connection was already ready, so do not suppress the bounded retries.
    IdentityNameUplinkSequence=(tonumber(IdentityNameUplinkSequence) or 0)+1
    local Msg=string.format("HCECENM|%d|%d|%d|%s",IdentityNameProtocol,IdentityNameUplinkSequence,math.floor(Pid),Name)
    local Ok,Err=pcall(function() C2:ServerExecRPC(Msg) end)
    if Ok then
        IdentityFrontendNameLastSignature=Sig
        Log("IDENTITY P2 NAME FRONTEND UPLINK TX seq=%d playerId=%d name='%s' route=%s source=%s",
            IdentityNameUplinkSequence,Pid,Name,tostring(SafeFullName(C2) or C2),tostring(Source or "P2 frontend name"))
        return true
    end
    Log("IDENTITY P2 NAME FRONTEND UPLINK failed playerId=%s name='%s' error=%s",tostring(Pid),Name,tostring(Err))
    return false
end

function IdentityNetworkScheduleFrontendP2NamePublish(Source)
    IdentityFrontendNamePublishToken=(tonumber(IdentityFrontendNamePublishToken) or 0)+1
    local Token=IdentityFrontendNamePublishToken
    local Delays={0,250,600,1200,2200,4000}
    for _,Delay in ipairs(Delays) do
        ExecuteInGameThreadWithDelay(Delay,function()
            if Token~=IdentityFrontendNamePublishToken or ModTeardownGuard then return end
            -- Intentionally send every bounded attempt. The client can observe its
            -- own reflected call even when the lobby connection is not ready yet;
            -- only the host can prove receipt, and duplicate authoritative writes
            -- of the same generated name are harmless.
            IdentityNetworkMaybeSendP2NameFrontend(string.format("%s +%dms",tostring(Source or "P2 join"),Delay))
        end)
    end
end

-- Mission-time P2 name resend via the retired armor route-proof map was removed.
-- The bounded frontend P2-name publisher remains independent and is handled by
-- HCECENM using the secondary ChildConnection proof on the host.

function IdentityNetworkHandleNameUplink(Message,Controller,ControllerToken)
    local Proto,Seq,Claimed,Name=string.match(Message,"^HCECENM|(%d+)|(%d+)|(%d+)|([A-Za-z]+%-%d%d%d)$")
    Proto,Seq,Claimed=tonumber(Proto),tonumber(Seq),tonumber(Claimed)
    Controller=Unwrap(Controller)
    if Proto~=IdentityNameProtocol or Seq==nil or Claimed==nil or not IsValidObject(Controller) or Name==nil or #Name>24 then
        Log("IDENTITY P2 NAME UPLINK rejected client=%s reason=invalid-payload",tostring(ControllerToken)); return
    end
    local ServerPid=ArmorSkinPlayerIdFromController(Controller)
    local Secondary=(IdentityControllerIsSecondarySplit~=nil and IdentityControllerIsSecondarySplit(Controller))
    if ServerPid==nil or math.floor(ServerPid)~=math.floor(Claimed) or not Secondary then
        Log("IDENTITY P2 NAME UPLINK rejected client=%s claimed=%s server=%s child=%s",
            tostring(ControllerToken),tostring(Claimed),tostring(ServerPid),tostring(Secondary)); return
    end
    local Last=tonumber(IdentityNameLastUplinkSequenceByController[ControllerToken])
    if Last~=nil and Seq<=Last then return end
    IdentityNameLastUplinkSequenceByController[ControllerToken]=Seq
    if not IsValidObject(Controller.PlayerState) then return end
    local Before=NetworkIdentityRemotePlayerName(Controller)
    local WriteOk=pcall(function() Controller.PlayerState.PlayerNamePrivate=Name end)
    local RepOk=false
    if WriteOk then
        RepOk=pcall(function() Controller.PlayerState:OnRep_PlayerName() end)
        pcall(function() Controller.PlayerState:ForceNetUpdate() end)
    end
    local After=NetworkIdentityRemotePlayerName(Controller)
    Log("IDENTITY P2 NAME UPLINK RX seq=%d playerId=%d write=%s onrep=%s before='%s' target='%s' after='%s' client=%s",
        Seq,ServerPid,tostring(WriteOk),tostring(RepOk),tostring(Before),tostring(Name),tostring(After),tostring(ControllerToken))
end

function TryRepairP2Name()
    local P1, P2 = PlayerControllerTable[1], PlayerControllerTable[2]
    if not IsValidObject(P1) or not IsValidObject(P2) then
        pcall(function() RefreshCachedControllers() end)
        P1, P2 = PlayerControllerTable[1], PlayerControllerTable[2]
    end
    if not IsValidObject(P1) or not IsValidObject(P2) then return false end

    local P1Name = ReadPlayerName(P1)
    local Target = EnsureP2SpartanSessionName()
    if TrimName(Target)=="" then return false end
    local Before = ReadPlayerName(P2)
    if string.lower(TrimName(Before)) == string.lower(Target) then return true end
    if PlayerStatesAliased(P1, P2) then return false end

    local WriteOk = pcall(function() P2.PlayerState.PlayerNamePrivate = Target end)
    local RepOk = false
    if WriteOk then
        RepOk = pcall(function() P2.PlayerState:OnRep_PlayerName() end)
        if LivesAuthorityResolved and LivesAuthorityAllowed==true then
            pcall(function() P2.PlayerState:ForceNetUpdate() end)
        end
    end
    local After = ReadPlayerName(P2)
    local P1After = ReadPlayerName(P1)
    if WriteOk and TrimName(P1After) ~= TrimName(P1Name) then
        pcall(function() P1.PlayerState.PlayerNamePrivate = P1Name end)
        pcall(function() P1.PlayerState:OnRep_PlayerName() end)
        Log("IDENTITY alias collision prevented; restored P1 '%s'", tostring(P1Name))
        return true
    end
    local Repaired = string.lower(TrimName(After)) == string.lower(Target)
    Log("IDENTITY local guest repair attempt=%d write=%s onrep=%s p1='%s' before='%s' target='%s' after='%s'",
        P2NameRepairAttempts, tostring(WriteOk), tostring(RepOk), tostring(P1Name),
        tostring(Before), tostring(Target), tostring(After))
    if Repaired then
        if IdentityNetworkScheduleFrontendP2NamePublish~=nil then
            IdentityNetworkScheduleFrontendP2NamePublish("local P2 repair")
        end
    end
    return Repaired
end

function P2NameRepairTick()
    if not P2NameRepairActive then return end
    P2NameRepairTicks = P2NameRepairTicks + 1
    if P2NameRepairTicks ~= 5 and P2NameRepairTicks ~= 25 and
       P2NameRepairTicks ~= 75 and P2NameRepairTicks ~= 125 and
       P2NameRepairTicks ~= 200 then return end
    P2NameRepairAttempts = P2NameRepairAttempts + 1
    if TryRepairP2Name() or P2NameRepairTicks >= 200 then
        P2NameRepairActive = false
    end
end

-- Frontend rejoin recovery. These are globals intentionally because main.lua is
-- already close to Lua's 200-local main-chunk limit.
FrontendPlayerOneFallbackLogged = false

function ResolveCurrentFrontendPlayerOne(Reason)
    if IsValidObject(PlayerControllerTable[1]) then return PlayerControllerTable[1] end

    local World = nil
    local Candidate = nil
    pcall(function() World = UEHelpers.GetWorld() end)
    if IsValidObject(World) then
        pcall(function()
            Candidate = GetGameplayStatics():GetPlayerController(World, 0)
        end)
    end
    if not IsValidObject(Candidate) then
        pcall(function() Candidate = UEHelpers.GetPlayerController() end)
    end
    if not IsValidObject(Candidate) then return nil end

    local Name = SafeFullName(Candidate) or ""
    local Id = nil
    pcall(function()
        if IsValidObject(Candidate.Player) then Id = Candidate.Player.ControllerId end
    end)
    local InFrontend = string.find(string.lower(Name), "/game/levels/ui/frontend/", 1, true) ~= nil
    if Id ~= 0 and not InFrontend then return nil end

    PlayerControllerTable[1] = Candidate
    if not FrontendPlayerOneFallbackLogged then
        FrontendPlayerOneFallbackLogged = true
        Log("Frontend P1 fallback resolved current controller: ControllerId=%s reason=%s",
            tostring(Id), tostring(Reason or "unspecified"))
    end
    return Candidate
end

function RestartJoinStateMachineWorker(Reason)
    -- Keep exactly one owned loop for the full mod lifetime. Map travel/native
    -- join no longer creates a replacement async worker that can overlap the old
    -- one while UE4SS is collecting Lua callback references.
    if MainStateWorkerHandle ~= nil then
        local Active = false
        pcall(function() Active = IsDelayedActionActive(MainStateWorkerHandle) end)
        if Active then
            MainStateWorkerStarted = true
            return
        end
    end

    local Ok, HandleOrErr = pcall(function()
        return LoopInGameThreadWithDelay(MainStatePollIntervalMs, function()
            local TickOk, TickErr = pcall(MainStateTick)
            if not TickOk then Log("State worker tick error: %s", tostring(TickErr)) end
        end)
    end)
    if Ok and HandleOrErr ~= nil then
        MainStateWorkerHandle = HandleOrErr
        MainStateWorkerStarted = true
        Log("Game-thread state worker ready: %s", tostring(Reason or "startup"))
    else
        MainStateWorkerHandle = nil
        MainStateWorkerStarted = false
        Log("Game-thread state worker unavailable: %s", tostring(HandleOrErr))
    end
end

function ScheduleJoinVerification(Attempt)
    Attempt = tonumber(Attempt) or 1
    if not JoinVerificationActive or Attempt > 24 then return end
    ExecuteInGameThreadWithDelay(250, function()
        if ModTeardownGuard or not JoinVerificationActive then return end
        VerifyJoinOnce(true)
        if JoinVerificationActive and Attempt < 24 then
            ScheduleJoinVerification(Attempt + 1)
        elseif JoinVerificationActive then
            JoinVerificationActive = false
            Log("Join verification timed out after about 6 seconds; join can be tried again")
        end
    end)
end

function SchedulePlayerTwoNameRepair(Attempt)
    Attempt = tonumber(Attempt) or 1
    if Attempt > 5 then return end
    ExecuteInGameThreadWithDelay(400, function()
        if ModTeardownGuard then return end
        CachePlayerControllers()
        if not IsValidObject(PlayerControllerTable[1]) then
            ResolveCurrentFrontendPlayerOne("P2 name repair")
        end
        P2NameRepairAttempts = P2NameRepairAttempts + 1
        if TryRepairP2Name() then
            P2NameRepairActive = false
            return
        end
        if Attempt < 5 then SchedulePlayerTwoNameRepair(Attempt + 1) end
    end)
end

function VerifyJoinOnce(Force)
    if not JoinVerificationActive then return end
    JoinVerificationTicks = JoinVerificationTicks + 1
    -- Only scan every ~200 ms during the long-lived worker path. The bounded
    -- one-shot verifier passes Force=true so rejoin can finish even if that worker
    -- was removed by UE4SS during the previous campaign session.
    if not Force and (JoinVerificationTicks % 5) ~= 0 then return end

    CachePlayerControllers()
    local P1 = PlayerControllerTable[1]
    if (not IsValidObject(P1)) and ResolveCurrentFrontendPlayerOne ~= nil then
        P1 = ResolveCurrentFrontendPlayerOne("join verification fallback")
    end
    local P2 = PlayerControllerTable[2]
    if IsValidObject(P1) and IsValidObject(P2) then
        local P1Id, P2Id = nil, nil
        pcall(function() if IsValidObject(P1.Player) then P1Id = P1.Player.ControllerId end end)
        pcall(function() if IsValidObject(P2.Player) then P2Id = P2.Player.ControllerId end end)
        local P1Name = SafeFullName(P1) or ""
        local P1IsFrontend = string.find(string.lower(P1Name), "/game/levels/ui/frontend/", 1, true) ~= nil
        if (P1Id == 0 or P1IsFrontend) and P2Id == 1 then
            if ConfiguredControllerCount == 1 then
                local RouterCallOk, RouterReady = pcall(EnsureAdaptiveSteamInputRouting, "join verification liveness", true)
                if not RouterCallOk or RouterReady ~= true or XInputSteamRouterSlot1Connected ~= true then
                    if Force or (JoinVerificationTicks % 25) == 0 then
                        Log("Join verification waiting for live logical P2 slot: ready=%s kind=%d game1=%s entry=%s",
                            tostring(RouterCallOk and RouterReady == true), XInputSteamRouterLastKind,
                            XInputSteamRouterRcText(XInputSteamRouterGameSlot1Rc),
                            XInputSteamRouterEntryKindText(XInputSteamRouterEntryKindBefore))
                    end
                    return
                end
            end
            JoinVerificationActive = false
            pcall(function() RefreshCachedControllers() end)
            Log("Join verified: P1 ControllerId=0, P2 ControllerId=1")
            if ConfiguredControllerCount == 1 then
                XInputSteamRouterPostJoinTicks = 125 -- ~5 seconds
                XInputSteamRouterPostJoinIntervalTicks = 0
                Log("INPUT ROUTER post-join liveness window armed: kind=%d game1=%s",
                    XInputSteamRouterLastKind, XInputSteamRouterRcText(XInputSteamRouterGameSlot1Rc))
            end
            SyncPlayerTwoSettingsFromP1("P2 join verified before split/HUD writes")
            P2MenuLeaveController = P2
            P2MenuLeaveBindingName = EarlyFullName(P2)
            P2NameRepairActive = true
            P2NameRepairTicks = 0
            P2NameRepairAttempts = 0
            SchedulePlayerTwoNameRepair(1)

            -- One safe activation pass only; repeated native layout passes were
            -- removed because the second pass coincided with the crash.
            ApplyLocalMultiplayerSettings()
            RunConsoleCommand(ViewportHoldCVar .. " 0")
            RefreshSplitscreenLayout()
            EnableHaloUISplitscreen()
            ScheduleHaloHUDRebuild(100, "verified player creation")
            Log("Split-screen activation pass complete")
            return
        end
    end

    if JoinVerificationTicks >= 100 then
        JoinVerificationActive = false
        Log("Join verification timed out before Player 2 ControllerId 1 became available")
    end
end

-- ---------------------------------------------------------------------------
-- Native Controller Settings help
-- ---------------------------------------------------------------------------
-- Reuses Halo's existing WBP_ControllerMenu_C widgets so font, color, spacing
-- and button icons remain native. All UI writes are scheduled onto the game
-- thread and are event-driven from Controller Menu construction/activation plus
-- Halo's settings nav events. Reapply retries piggyback on the existing 40 ms
-- state worker for at most ~1.2 s after a real UI event; there is no permanent
-- Controller Settings scan and no delayed-callback fan-out.

ControllerHelpTextCache = ControllerHelpTextCache or {}
ControllerHelpLastWidgetName = ControllerHelpLastWidgetName or nil
ControllerHelpTemplatePatched = ControllerHelpTemplatePatched or false
ControllerHelpListenerReady = ControllerHelpListenerReady or false
ControllerHelpPageHookReady = ControllerHelpPageHookReady or false
ControllerHelpActivationHookReady = ControllerHelpActivationHookReady or false
ControllerHelpButtonHookReady = ControllerHelpButtonHookReady or false
ControllerHelpApplyActive = ControllerHelpApplyActive or false
ControllerHelpApplyTickCount = ControllerHelpApplyTickCount or 0
ControllerHelpApplyGeneration = ControllerHelpApplyGeneration or 0
ControllerHelpWriteGuard = ControllerHelpWriteGuard or false
ControllerHelpTextRefreshHookReady = ControllerHelpTextRefreshHookReady or false
ControllerHelpVisibilityHookReady = ControllerHelpVisibilityHookReady or false
ControllerHelpBlueprintActivationHookReady = ControllerHelpBlueprintActivationHookReady or false
ControllerHelpSignalQueued = ControllerHelpSignalQueued or false
ControllerHelpSignalSource = ControllerHelpSignalSource or nil

function ControllerHelpGetText(Key, Value)
    local Cached = ControllerHelpTextCache[Key]
    if Cached then return Cached end
    local TextLibrary = StaticFindObject("/Script/Engine.Default__KismetTextLibrary")
    if not IsValidObject(TextLibrary) then return nil end
    local Converted = TextLibrary:Conv_StringToText(Value)
    ControllerHelpTextCache[Key] = Converted
    return Converted
end

function ControllerHelpSetBlock(Block, Key, Value)
    if not IsValidObject(Block) then return 0 end
    local Text = ControllerHelpGetText(Key, Value)
    if not Text then return 0 end
    -- TextBlock:SetText is also used as an event source below so deferred Halo
    -- refreshes can be repaired. Guard our own writes to avoid self-triggered
    -- reapply batches.
    local PreviousGuard = ControllerHelpWriteGuard
    ControllerHelpWriteGuard = true
    local Ok = pcall(function() Block:SetText(Text) end)
    ControllerHelpWriteGuard = PreviousGuard
    return Ok and 1 or 0
end

function ControllerHelpSetAction(Display, Key, Value)
    if not IsValidObject(Display) then return 0 end
    local Block1 = nil
    local Block2 = nil
    pcall(function() Block1 = Display.InputActionTextBlock end)
    pcall(function() Block2 = Display.InputActionTextBlock2 end)

    local Count = ControllerHelpSetBlock(Block1, Key .. "_1", Value)
    -- WBP_InputActionDisplay carries a second text layer/variant. Keep both in
    -- sync so Halo cannot reveal the original label when its visual state flips.
    Count = Count + ControllerHelpSetBlock(Block2, Key .. "_2", Value)
    return Count
end

function ApplyControllerHelpToLiveMenu()
    -- Controller Settings exists in both the frontend and each local player's
    -- in-game pause stack. ModTeardownGuard already prevents writes during map
    -- teardown, so do not suppress the real campaign instances here.
    local Objects = nil
    local FindOk, FindErr = pcall(function() Objects = FindAllOf("WBP_ControllerMenu_C") end)
    if not FindOk or Objects == nil then
        Log("UI CONTROLS: FindAllOf(WBP_ControllerMenu_C) failed: %s", tostring(FindErr))
        return 0
    end

    local UpdatedWidgets = 0
    for _, Raw in ipairs(ArrayValues(Objects)) do
        local Widget = Unwrap(Raw)
        if IsValidObject(Widget) then
            local Name = tostring(SafeFullName(Widget) or "")
            local Lower = string.lower(Name)
            if string.find(Lower, "/engine/transient.", 1, true) ~= nil
                and string.find(Lower, "wbp_controllermenu_c_", 1, true) ~= nil
                and string.find(Name, "Default__", 1, true) == nil then

                local Header = nil
                local Description = nil
                local Layout = nil
                pcall(function() Header = Widget.HeaderLabel end)
                pcall(function() Description = Widget.DescriptionTextBlock end)
                pcall(function() Layout = Widget.WBP_ButtonLayoutDisplay end)

                local WidgetWrites = 0
                WidgetWrites = WidgetWrites + ControllerHelpSetBlock(
                    Header,
                    "header",
                    "CO-OP EXPANDED CONTROLS"
                )
                WidgetWrites = WidgetWrites + ControllerHelpSetBlock(
                    Description,
                    "description",
                    "Co-op Expanded shortcuts are shown beneath the standard controls."
                )

                if IsValidObject(Layout) then
                    local DpadUp, DpadLeft, DpadDown, DpadRight = nil, nil, nil, nil
                    local FaceLeft, FaceRight, FaceBottom, FaceTop = nil, nil, nil, nil
                    local RightBumper, LeftStickIn, RightStickIn = nil, nil, nil
                    pcall(function() DpadUp = Layout.InputActionDisplayDpadUp end)
                    pcall(function() DpadLeft = Layout.InputActionDisplayDpadLeft end)
                    pcall(function() DpadDown = Layout.InputActionDisplayDpadDown end)
                    pcall(function() DpadRight = Layout.InputActionDisplayDpadRight end)
                    pcall(function() FaceLeft = Layout.InputActionDisplayFaceLeft end)
                    pcall(function() FaceRight = Layout.InputActionDisplayFaceRight end)
                    pcall(function() FaceBottom = Layout.InputActionDisplayFaceBottom end)
                    pcall(function() FaceTop = Layout.InputActionDisplayFaceTop end)
                    pcall(function() RightBumper = Layout.InputActionDisplayRightBumper end)
                    pcall(function() LeftStickIn = Layout.InputActionDisplayLeftStickIn end)
                    pcall(function() RightStickIn = Layout.InputActionDisplayRightStickIn end)

                    WidgetWrites = WidgetWrites + ControllerHelpSetAction(
                        RightBumper,
                        "rb",
                        "Use Equipment\nCo-op Expanded Modifier"
                    )
                    WidgetWrites = WidgetWrites + ControllerHelpSetAction(
                        DpadUp,
                        "dpad_up",
                        "Toggle Flashlight\nRB: Respawn Limit"
                    )
                    WidgetWrites = WidgetWrites + ControllerHelpSetAction(
                        DpadLeft,
                        "dpad_left",
                        "X: Previous Armor Skin\nRB: Previous Armor Model"
                    )
                    WidgetWrites = WidgetWrites + ControllerHelpSetAction(
                        DpadDown,
                        "dpad_down",
                        "Drop Weapon\nRB: Split Orientation"
                    )
                    WidgetWrites = WidgetWrites + ControllerHelpSetAction(
                        DpadRight,
                        "dpad_right",
                        "Switch Grenade\nX: Next Armor Skin\nRB: Next Armor Model"
                    )
                    WidgetWrites = WidgetWrites + ControllerHelpSetAction(
                        FaceLeft,
                        "face_left",
                        "Interact / Reload\nHold: Armor Skin\nRB: Weapon Skin"
                    )
                    WidgetWrites = WidgetWrites + ControllerHelpSetAction(
                        FaceRight,
                        "face_right",
                        "Crouch / Switch Seats\nRB: 1st / 3rd Person"
                    )
                    WidgetWrites = WidgetWrites + ControllerHelpSetAction(
                        FaceBottom,
                        "face_bottom",
                        "Jump / Brake\nMenu: Join / Hold Leave P2"
                    )
                    WidgetWrites = WidgetWrites + ControllerHelpSetAction(
                        FaceTop,
                        "face_top",
                        "Switch Weapon\nRB: Respawn Voice (P1)"
                    )
                    WidgetWrites = WidgetWrites + ControllerHelpSetAction(
                        LeftStickIn,
                        "left_stick",
                        "Sprint\nRB: Previous Vehicle Color"
                    )
                    WidgetWrites = WidgetWrites + ControllerHelpSetAction(
                        RightStickIn,
                        "right_stick",
                        "Melee / Zoom Level\nRB: Next Vehicle Color"
                    )
                end

                UpdatedWidgets = UpdatedWidgets + 1
                if ControllerHelpLastWidgetName ~= Name then
                    Log("UI CONTROLS: applied native controller help to %s (%d text writes)", Name, WidgetWrites)
                    ControllerHelpLastWidgetName = Name
                end
            end
        end
    end

    return UpdatedWidgets
end

function ApplyControllerHelpTemplate()
    -- The class template is shared by frontend and pause-menu instances. The
    -- live-object pass remains authoritative; patching this template simply
    -- reduces the window in which Halo can expose vanilla labels.
    local Header = nil
    local Description = nil
    pcall(function()
        Header = StaticFindObject("/Game/UI/Shared/Settings/Widgets/WBP_ControllerMenu.WBP_ControllerMenu_C:WidgetTree.HeaderLabel")
    end)
    pcall(function()
        Description = StaticFindObject("/Game/UI/Shared/Settings/Widgets/WBP_ControllerMenu.WBP_ControllerMenu_C:WidgetTree.DescriptionTextBlock")
    end)

    local Count = 0
    Count = Count + ControllerHelpSetBlock(Header, "template_header", "CO-OP EXPANDED CONTROLS")
    Count = Count + ControllerHelpSetBlock(
        Description,
        "template_description",
        "Co-op Expanded shortcuts are shown beneath the standard controls."
    )

    if Count > 0 and not ControllerHelpTemplatePatched then
        ControllerHelpTemplatePatched = true
        Log("UI CONTROLS: Controller Menu template patched (%d text writes)", Count)
    end
    return Count
end

function ControllerHelpApplyPass()
    if ModTeardownGuard then return end
    pcall(function() ApplyControllerHelpTemplate() end)
    pcall(function() ApplyControllerHelpToLiveMenu() end)
end

function ScheduleControllerHelpApply(Source)
    -- Controller Settings is used in the frontend and in each local player's
    -- pause/settings stack. Drive the bounded repair directly from real UI events
    -- rather than relying on a permanent poll. A generation token makes older
    -- callback batches harmless when several refresh events arrive together.
    ControllerHelpApplyGeneration = ControllerHelpApplyGeneration + 1
    local Generation = ControllerHelpApplyGeneration
    ControllerHelpApplyTickCount = 0
    ControllerHelpApplyActive = false
    if Source ~= nil and tostring(Source) ~= "" then
        Log("UI CONTROLS: reapply scheduled by %s generation=%d", tostring(Source), Generation)
    end

    local Delays = { 0, 80, 250, 700, 1400 }
    for _, DelayMs in ipairs(Delays) do
        ExecuteInGameThreadWithDelay(DelayMs, function()
            if ModTeardownGuard or Generation ~= ControllerHelpApplyGeneration then return end
            ControllerHelpApplyPass()
        end)
    end
end

function ControllerHelpApplyTick()
    -- Kept as a no-op because MainStateTick still calls it. Controller Settings
    -- reapply is now fully owned by the bounded UI-event callback batch above.
    return
end

function ControllerHelpContextIsControllerMenu(Context)
    local Name = ""
    local Object = Unwrap(Context)
    pcall(function() Name = SafeFullName(Object) or "" end)
    return string.find(Name, "WBP_ControllerMenu_C", 1, true) ~= nil
end

function QueueControllerHelpRefreshSignal(Source)
    if ModTeardownGuard or ControllerHelpWriteGuard then return end
    if ControllerHelpSignalQueued then return end
    ControllerHelpSignalQueued = true
    ControllerHelpSignalSource = tostring(Source or "Controller Menu refresh")
    -- Coalesce a burst of SetText/SetVisibility calls into one bounded repair.
    ExecuteInGameThreadWithDelay(40, function()
        local PendingSource = ControllerHelpSignalSource
        ControllerHelpSignalQueued = false
        ControllerHelpSignalSource = nil
        if ModTeardownGuard then return end
        ScheduleControllerHelpApply(PendingSource)
    end)
end

function TryRegisterControllerMenuBlueprintActivationHook(Quiet)
    if ControllerHelpBlueprintActivationHookReady then return true end
    local Ok, Err = pcall(function()
        RegisterHook(
            "/Game/UI/Shared/Settings/Widgets/WBP_ControllerMenu.WBP_ControllerMenu_C:BP_OnActivated",
            function(Context, ...) end,
            function(Context, ...)
                QueueControllerHelpRefreshSignal("WBP_ControllerMenu_C.BP_OnActivated")
            end
        )
    end)
    if Ok then
        ControllerHelpBlueprintActivationHookReady = true
        Log("UI CONTROLS: exact Controller Menu BP_OnActivated hook ready")
        return true
    end
    if not Quiet then
        Log("UI CONTROLS: exact Controller Menu BP_OnActivated hook unavailable: %s", tostring(Err))
    end
    return false
end

function RegisterControllerHelpRefreshHooks()
    -- Halo's Settings stack can reuse the same Controller Menu instance and
    -- repopulate its TextBlocks without firing the nav hooks we originally used.
    -- Listen to the actual write/visibility operations and filter to this menu.
    if not ControllerHelpTextRefreshHookReady then
        local Ok, Err = pcall(function()
            RegisterHook(
                "/Script/UMG.TextBlock:SetText",
                function(Context, ...) end,
                function(Context, ...)
                    if not ControllerHelpWriteGuard and ControllerHelpContextIsControllerMenu(Context) then
                        QueueControllerHelpRefreshSignal("Controller Menu TextBlock refresh")
                    end
                end
            )
        end)
        if Ok then
            ControllerHelpTextRefreshHookReady = true
            Log("UI CONTROLS: Controller Menu TextBlock refresh hook ready")
        else
            Log("UI CONTROLS: TextBlock refresh hook unavailable: %s", tostring(Err))
        end
    end

    if not ControllerHelpVisibilityHookReady then
        local Ok, Err = pcall(function()
            RegisterHook(
                "/Script/UMG.Widget:SetVisibility",
                function(Context, ...) end,
                function(Context, ...)
                    if ControllerHelpContextIsControllerMenu(Context) then
                        QueueControllerHelpRefreshSignal("Controller Menu visibility change")
                    end
                end
            )
        end)
        if Ok then
            ControllerHelpVisibilityHookReady = true
            Log("UI CONTROLS: Controller Menu visibility hook ready")
        else
            Log("UI CONTROLS: visibility hook unavailable: %s", tostring(Err))
        end
    end

    -- This UFunction may not exist until the Blueprint class is constructed;
    -- the construction listener retries it below.
    TryRegisterControllerMenuBlueprintActivationHook(true)
    return ControllerHelpTextRefreshHookReady or ControllerHelpVisibilityHookReady or ControllerHelpBlueprintActivationHookReady
end

function RegisterControllerHelpPageHook()
    RegisterControllerHelpRefreshHooks()
    if ControllerHelpPageHookReady and ControllerHelpActivationHookReady and ControllerHelpButtonHookReady then
        return true
    end

    -- v1.10.0's HandlePageChanged-only fix was too early/insufficient on the
    -- live Settings stack. Keep it, add the nav-button event, and most importantly
    -- listen to CommonActivatableWidget::BP_OnActivated filtered to the actual
    -- WBP_ControllerMenu_C instance.
    if not ControllerHelpPageHookReady then
        local Ok, Err = pcall(function()
            RegisterHook(
                "/Script/HaloUI.HaloUINavBarWidget:HandlePageChanged",
                function(Context, ...) end,
                function(Context, ...)
                    ScheduleControllerHelpApply("HaloUINavBarWidget.HandlePageChanged")
                end
            )
        end)
        if Ok then
            ControllerHelpPageHookReady = true
            Log("UI CONTROLS: settings page-change hook ready")
        else
            Log("UI CONTROLS: settings page-change hook unavailable: %s", tostring(Err))
        end
    end

    if not ControllerHelpButtonHookReady then
        local Ok, Err = pcall(function()
            RegisterHook(
                "/Script/HaloUI.HaloUINavBarWidget:HandleButtonClicked",
                function(Context, ...) end,
                function(Context, ...)
                    ScheduleControllerHelpApply("HaloUINavBarWidget.HandleButtonClicked")
                end
            )
        end)
        if Ok then
            ControllerHelpButtonHookReady = true
            Log("UI CONTROLS: settings nav-button hook ready")
        else
            Log("UI CONTROLS: settings nav-button hook unavailable: %s", tostring(Err))
        end
    end

    if not ControllerHelpActivationHookReady then
        local Ok, Err = pcall(function()
            RegisterHook(
                "/Script/CommonUI.CommonActivatableWidget:BP_OnActivated",
                function(Context, ...) end,
                function(Context, ...)
                    if ControllerHelpContextIsControllerMenu(Context) then
                        ScheduleControllerHelpApply("WBP_ControllerMenu activation")
                    end
                end
            )
        end)
        if Ok then
            ControllerHelpActivationHookReady = true
            Log("UI CONTROLS: Controller Menu activation hook ready")
        else
            Log("UI CONTROLS: Controller Menu activation hook unavailable: %s", tostring(Err))
        end
    end

    return ControllerHelpPageHookReady or ControllerHelpButtonHookReady or ControllerHelpActivationHookReady
end

function RegisterControllerHelpListener()
    if ControllerHelpListenerReady then
        RegisterControllerHelpPageHook()
        return true
    end
    local Ok, Err = pcall(function()
        NotifyOnNewObject(
            "/Game/UI/Shared/Settings/Widgets/WBP_ControllerMenu.WBP_ControllerMenu_C",
            function()
                -- The derived BP_OnActivated UFunction is reliably discoverable
                -- after the first instance exists; bind it now for future returns.
                TryRegisterControllerMenuBlueprintActivationHook(true)
                ScheduleControllerHelpApply("Controller Menu construction")
            end
        )
    end)
    if Ok then
        ControllerHelpListenerReady = true
        Log("UI CONTROLS: Controller Menu construction listener ready")
        RegisterControllerHelpPageHook()
        ScheduleControllerHelpApply("startup")
        return true
    end
    Log("UI CONTROLS: Controller Menu construction listener unavailable: %s", tostring(Err))
    return false
end

function MainStateTick()
    if ModTeardownGuard then return end

    AdaptiveInputRouterWarmupTick()
    KeyboardEscapeScheduleRecovery()
    ControllerHelpApplyTick()
    ControllerRefreshCounter = ControllerRefreshCounter + 1

    -- Cheap menu-only drop-out gesture. No extra loop/timer and zero input queries
    -- during campaign because FrontendBoundarySeen is false there.
    PollFrontendP2LeaveHold()

    VerifyJoinOnce()
    LivesHookRetryTick()
    if P2NameRepairActive then P2NameRepairTick() end

    -- BP_MeteoritePlayerController.ReceiveTick is the preferred mission input
    -- source. The compatibility runtime can launch Lua before that Blueprint
    -- UFunction exists, so retry the hook and use this worker only as fallback.
    if not ArmorTickHookArmed then
        ArmorTickFallbackRefreshTicks = ArmorTickFallbackRefreshTicks + 1
        ArmorTickHookRetryTicks = ArmorTickHookRetryTicks + 1

        if ArmorTickFallbackRefreshTicks >= 25 then
            ArmorTickFallbackRefreshTicks = 0
            pcall(function() RefreshCachedControllers() end)
        end

        if ArmorTickHookRetryTicks >= 25 then
            ArmorTickHookRetryTicks = 0
            local WasArmed = ArmorTickHookArmed
            local Bound = false
            pcall(function() Bound = RegisterArmorTickHook(true) end)
            if Bound and not WasArmed then
                Log("ARMOR mission ReceiveTick hook late-bound after Blueprint construction")
                pcall(function() RefreshCachedControllers() end)
            end
        end

        if not ArmorTickHookArmed and ArmorControllerTick ~= nil then
            local P1 = GetPlayer(1)
            if P1 ~= nil then
                ArmorControllerTick(P1, MainStatePollIntervalMs / 1000.0)
            end
            local P2 = GetPlayer(2)
            if P2 ~= nil then ArmorControllerTick(P2) end
        end
    end

    -- The native A sign-in UFunction can be late for the same reason.
    if not NativeJoinSigninHookReady and not NativeJoinSubsystemHookReady then
        NativeJoinHookRetryTicks = NativeJoinHookRetryTicks + 1
        if NativeJoinHookRetryTicks >= 25 then
            NativeJoinHookRetryTicks = 0
            local HadJoinHook = NativeJoinSigninHookReady or NativeJoinSubsystemHookReady
            local JoinBound = RegisterNativeSplitscreenJoinHook(true)
            if JoinBound and not HadJoinHook then
                Log("Native A join hook late-bound after frontend Blueprint construction")
            end
        end
    end

    -- Recover only when a cached controller is actually missing or invalid.
    if (not IsValidObject(PlayerControllerTable[1])) or
       (PlayerTwoExpected and not IsValidObject(PlayerControllerTable[2])) then
        if ControllerRefreshCounter >= 50 then
            ControllerRefreshCounter = 0
            pcall(function() RefreshCachedControllers() end)
        end
    else
        ControllerRefreshCounter = 0
    end

    -- After an explicit A join request, do not create P2 until the routed
    -- logical game slot1 is actually live. This closes the Steam Input publication
    -- race without requiring the user to press A again.
    if XInputSteamRouterJoinWaitActive then
        if ModTeardownGuard then
            XInputSteamRouterJoinWaitActive = false
            XInputSteamRouterJoinWaitTicks = 0
        else
            XInputSteamRouterJoinWaitTicks = XInputSteamRouterJoinWaitTicks - 1
            XInputSteamRouterJoinWaitIntervalTicks = XInputSteamRouterJoinWaitIntervalTicks - 1
            if XInputSteamRouterJoinWaitIntervalTicks <= 0 then
                XInputSteamRouterJoinWaitIntervalTicks = 10 -- ~400 ms
                XInputSteamRouterJoinWaitAttempt = XInputSteamRouterJoinWaitAttempt + 1
                local RouterCallOk, RouterReady = pcall(EnsureAdaptiveSteamInputRouting,
                    "pending P2 join liveness retry " .. tostring(XInputSteamRouterJoinWaitAttempt), true)
                if RouterCallOk and RouterReady == true and XInputSteamRouterSlot1Connected == true then
                    XInputSteamRouterJoinWaitActive = false
                    XInputSteamRouterJoinWaitTicks = 0
                    Log("INPUT ROUTER pending P2 join released attempt=%d kind=%d game1=%s",
                        XInputSteamRouterJoinWaitAttempt, XInputSteamRouterLastKind,
                        XInputSteamRouterRcText(XInputSteamRouterGameSlot1Rc))
                    CreatePlayer()
                elseif XInputSteamRouterJoinWaitTicks <= 0 then
                    XInputSteamRouterJoinWaitActive = false
                    Log("INPUT ROUTER pending P2 join timed out after %d attempts; kind=%d game1=%s entry=%s",
                        XInputSteamRouterJoinWaitAttempt, XInputSteamRouterLastKind,
                        XInputSteamRouterRcText(XInputSteamRouterGameSlot1Rc),
                        XInputSteamRouterEntryKindText(XInputSteamRouterEntryKindBefore))
                end
            end
        end
    end

    -- Keep a short liveness window after a verified join. If Steam republishes its
    -- If Steam republishes its virtual XInput device immediately after CreatePlayer, v0.7.4 can switch a
    -- now-dead native route back to the captured Steam relay/shift automatically.
    if XInputSteamRouterPostJoinTicks > 0 then
        if ModTeardownGuard or not IsValidObject(PlayerControllerTable[2]) then
            XInputSteamRouterPostJoinTicks = 0
        else
            XInputSteamRouterPostJoinTicks = XInputSteamRouterPostJoinTicks - 1
            XInputSteamRouterPostJoinIntervalTicks = XInputSteamRouterPostJoinIntervalTicks - 1
            if XInputSteamRouterPostJoinIntervalTicks <= 0 then
                XInputSteamRouterPostJoinIntervalTicks = 10 -- ~400 ms
                local PostCallOk, PostReady = pcall(EnsureAdaptiveSteamInputRouting, "post-join liveness", true)
                if not PostCallOk or PostReady ~= true or XInputSteamRouterSlot1Connected ~= true then
                    Log("INPUT ROUTER post-join liveness waiting: ready=%s kind=%d game1=%s entry=%s",
                        tostring(PostCallOk and PostReady == true), XInputSteamRouterLastKind,
                        XInputSteamRouterRcText(XInputSteamRouterGameSlot1Rc),
                        XInputSteamRouterEntryKindText(XInputSteamRouterEntryKindBefore))
                end
            end
        end
    end

    -- Native P2 join debounce, handled without another delayed callback.
    if PendingJoinScheduled and JoinDelayTicksRemaining > 0 then
        JoinDelayTicksRemaining = JoinDelayTicksRemaining - 1
        if JoinDelayTicksRemaining <= 0 then
            if JoinScheduledGeneration ~= JoinTravelGeneration then
                PendingJoinScheduled = false
            else
                CachePlayerControllers()
                if #PlayerControllerTable >= 2 then
                    PendingJoinScheduled = false
                else
                    Log("Native join delay complete; creating player 2.")
                    PendingJoinScheduled = false
                    CreatePlayer()
                end
            end
        end
    end
end

function MissionHudRepairTick(ControllerId, Controller, SharedControllerName, SharedFullscreenBlocked)
    if ControllerId ~= 0 then return end

    -- PERF: the cinematic hooks are event driven. In a settled mission we
    -- should not fetch GameViewportClient or stringify the controller every frame.
    -- A controller-object change is the lifecycle boundary; only then resolve its
    -- full path. The game-owned fullscreen flag is sampled only while the initial
    -- three HUD repair passes are still pending.
    if CinematicActive == true or SharedFullscreenBlocked == true then
        if HudScaleApplied then RestoreHudScale() end
        return
    end

    if HudControllerName == "" then
        local ControllerName = SharedControllerName or SafeFullName(Controller)
        HudControllerName = ControllerName
        HudRepairTicks = 0
        HudRepairPass = 0
        HudSoloRestored = false
        Log("HUD mission controller detected once; repair sequence reset: %s", ControllerName)
    end

    local P2 = PlayerControllerTable[2]
    if not IsValidObject(P2) then
        -- ApplicationScale is global. Never leave the split correction active in
        -- a mission that currently has only one local player.
        if HudScaleApplied and not HudSoloRestored then
            RestoreHudScale()
            HudSoloRestored = true
        end
        return
    end

    HudSoloRestored = false

    -- Only the construction window needs the reflective viewport safety check.
    -- Once pass 3 is complete this function becomes a Lua-only early return.
    if HudRepairPass >= 3 then
        AdaptiveHudViewportTick()
        return
    end
    if IsSplitForceDisabled ~= nil and IsSplitForceDisabled() then
        if HudScaleApplied then RestoreHudScale() end
        return
    end

    HudRepairTicks = HudRepairTicks + 1
    local ShouldRepair =
        (HudRepairPass == 0 and HudRepairTicks >= 30) or
        (HudRepairPass == 1 and HudRepairTicks >= 120) or
        (HudRepairPass == 2 and HudRepairTicks >= 300)

    if not ShouldRepair then return end

    HudRepairPass = HudRepairPass + 1
    -- Orientation detection logs its result, so evaluate it only on the three
    -- repair frames instead of spamming the log from ReceiveTick.
    if not WantsSideBySide() then
        RestoreHudScale()
        Log("HUD mission repair pass %d/3 skipped: layout is top/bottom",
            HudRepairPass)
        return
    end

    local ScaleOk = ApplyHudScale()
    local HaloUiOk = EnableHaloUISplitscreen()
    Log("HUD mission repair pass %d/3 at tick %d: scale=%s HaloUI=%s",
        HudRepairPass, HudRepairTicks, tostring(ScaleOk), tostring(HaloUiOk))
end

-- Limited Respawns HUD / mission lifecycle ----------------------------------
-- This build observes Halo's player-death event plus one targeted native
-- CampaignFlow.RestartLevel lifecycle hook so Pause -> Restart Mission can
-- reset Limited Respawns. Broad restart/respawn trace hooks stay
-- hard-disabled. Status is routed through Halo's existing per-player
-- WBP_Banner widget because ClientMessage is not rendered.
-- Globals are intentional: this main chunk is close to Lua's 200-local limit.
LivesHooks = LivesHooks or {}
LivesHookAttempts = LivesHookAttempts or {}
SimulatedLives = 3
LastDeathByPlayer = LastDeathByPlayer or {}
LivesMissionControllerName = ""
MissionControllerObject = nil
HookRetryTicks = 0
LivesTextLibrary = nil
-- Performance: once the stable mission HUD gate has identified P1/P2 banners,
-- reuse those widgets for later lives/countdown messages. This avoids a
-- global FindAllOf("WBP_Banner_C") on every displayed countdown digit.
BannerCache = BannerCache or {}
-- HUD rebind: campaign travel can leave more than one valid WBP_Banner_C
-- owned by the same local controller. DisplayMessage() can succeed on a stale
-- hidden banner, producing a misleading shown=2 log while nothing is visible.
-- Cache every banner candidate discovered by the bounded HUD-ready scan and
-- fan each message out to the small cached set. No per-message global scan is
-- added during normal gameplay.
BannerCandidates = BannerCandidates or {[0] = {}, [1] = {}}
-- Timer resilience: UE4SS 3.0.1 can invalidate the shared delayed-callback
-- registry after a script hook is added at mission load. Limited Respawns must
-- therefore not depend on ExecuteWithDelay for any core timer. These globals are
-- advanced from P1 ReceiveTick using the already-supplied DeltaSeconds value.
SetupIntroPhase = 0
SetupIntroRemaining = 0.0
SetupIntroGeneration = -1
SetupIntroActiveToken = -1
CountdownPhase = 0
CountdownRemaining = 0.0
CountdownDigit = 0
CountdownGeneration = -1
CountdownToken = -1
ReinforcementRemaining = 0.0
ReinforcementNextShown = 0
ReinforcementGeneration = -1
GameOverRestartRemaining = 0.0
GameOverRestartTravelGeneration = -1
RestartRearmRemaining = 0.0
RestartRearmArmedToken = -1
StartingExtraLives = 0
MissionLivesEnabled = false
GameOverPending = false
-- Network safety: Limited Respawns is authoritative gameplay state. Standalone
-- and listen-server/host worlds own an AuthorityGameMode; ordinary network
-- clients do not. Resolve this only at stable mission/lifecycle boundaries and
-- keep the cached result out of the hot input/death paths.
LivesAuthorityResolved = false
LivesAuthorityAllowed = true
LivesNetworkClientBlocked = false
LivesAuthorityNoticeShown = false
RestartDelayMs = 4500
ReinforcementDelaySeconds = 120
ReinforcementLastShown = -1
-- Reinforcement timing is advanced by the existing P1 ReceiveTick DeltaSeconds;
-- no separate engine-time poll or delayed-callback chain is used.
ReinforcementActive = false
-- HUD progress updates remain timer-driven from that same ReceiveTick path.
ReinforcementUpdateSeconds = 10
LivesOptions = {0, 5, 10, 20, 30}
LivesOptionIndex = 1

-- Vanilla-compatible voice announcements ------------------------------------
-- Halo's own WBP_Meteorite_Chat -> SendCurrentInput path is used with the
-- sender-side MeteoriteVoiceSubsystem TTS switch enabled. This was verified to
-- reach a completely vanilla network peer as synthesized speech while the large
-- chat widget stayed hidden. Existing HCECELV modded-peer HUD text remains
-- independent and is never disabled by this feature.
--
-- No config file option is exposed: Co-op Expanded is couch-first. Voice is ON
-- by default. Only authoritative host P1 can toggle the broadcast with RB+Y;
-- Ctrl+F8 is the keyboard/mouse parity shortcut. P2 and network clients cannot
-- change the host setting.
if LivesVoiceAnnouncementsEnabled == nil then LivesVoiceAnnouncementsEnabled = true end
LivesVoiceQueue = LivesVoiceQueue or {}
LivesVoicePhase = LivesVoicePhase or 0
LivesVoicePhaseRemaining = LivesVoicePhaseRemaining or 0.0
LivesVoiceCurrentMessage = LivesVoiceCurrentMessage or ""
LivesVoiceCurrentReason = LivesVoiceCurrentReason or ""
LivesVoiceOriginalTTS = LivesVoiceOriginalTTS
LivesVoiceChatWidget = LivesVoiceChatWidget
LivesVoiceSubsystem = LivesVoiceSubsystem
LivesVoiceTextLibrary = LivesVoiceTextLibrary
LivesVoiceSettleSeconds = 0.15
LivesVoiceRestoreSeconds = 0.55
LivesVoiceMaxQueued = 8
LivesVoiceNoRemoteLogged = LivesVoiceNoRemoteLogged or false
LivesVoicePendingDeathLives = LivesVoicePendingDeathLives
LivesVoicePendingDeathRemaining = LivesVoicePendingDeathRemaining or 0.0
LivesVoiceDeathCoalesceSeconds = 0.50
LivesVoiceToggleBannerRemaining = LivesVoiceToggleBannerRemaining or 0.0
LivesVoiceToggleBannerSeconds = 4.0
ReinforcementVoiceLastSecond = ReinforcementVoiceLastSecond or -1

function LivesVoiceHideChat(Chat)
    if not IsValidObject(Chat) then return end
    pcall(function() Chat:HideChatWidget() end)
    pcall(function() Chat:DeactivateChatFocus() end)
end

function LivesVoiceChatWidgetScore(Widget)
    if not IsValidObject(Widget) then return -100000 end
    local Input = nil
    pcall(function() Input = Widget.InputTxt end)
    if not IsValidObject(Input) then return -100000 end

    local Name = string.lower(tostring(SafeFullName(Widget) or ""))
    local Score = 0
    if string.find(Name, "/engine/transient.", 1, true) then Score = Score + 100 end
    if string.find(Name, "wbp_hud_main", 1, true) then Score = Score + 80 end
    if string.find(Name, "chatwidget", 1, true) then Score = Score + 30 end
    if string.find(Name, "meteoritegameinstance", 1, true) then Score = Score + 20 end
    if string.find(Name, "loadingscreen", 1, true) then Score = Score - 120 end
    if string.find(Name, ":widgettree.", 1, true) and
       string.find(Name, "/engine/transient.", 1, true) == nil then
        Score = Score - 60
    end
    return Score
end

function LivesVoiceResolveTransport()
    if IsValidObject(LivesVoiceChatWidget) and
       IsValidObject(LivesVoiceSubsystem) and
       IsValidObject(LivesVoiceTextLibrary) then
        return LivesVoiceChatWidget, LivesVoiceSubsystem, LivesVoiceTextLibrary, "cache"
    end

    LivesVoiceChatWidget = nil
    LivesVoiceSubsystem = nil
    LivesVoiceTextLibrary = nil

    pcall(function()
        LivesVoiceTextLibrary = StaticFindObject("/Script/Engine.Default__KismetTextLibrary")
    end)
    if not IsValidObject(LivesVoiceTextLibrary) then
        return nil, nil, nil, "KismetTextLibrary unavailable"
    end

    local Widgets = nil
    local FindOk, FindErr = pcall(function() Widgets = FindAllOf("WBP_Meteorite_Chat_C") end)
    if not FindOk or type(Widgets) ~= "table" then
        return nil, nil, nil, "FindAllOf(WBP_Meteorite_Chat_C) failed: " .. tostring(FindErr)
    end

    local Best = nil
    local BestScore = -100000
    for _, Widget in ipairs(Widgets) do
        local Score = LivesVoiceChatWidgetScore(Widget)
        if Score > BestScore then
            Best = Widget
            BestScore = Score
        end
    end
    if not IsValidObject(Best) or BestScore < 0 then
        return nil, nil, nil, string.format("no active chat widget; candidates=%d bestScore=%d", #Widgets, BestScore)
    end

    local VoiceSubsystem = nil
    pcall(function() VoiceSubsystem = Best.CachedVoiceSubsystem end)
    VoiceSubsystem = Unwrap(VoiceSubsystem)
    if not IsValidObject(VoiceSubsystem) then
        local Subsystems = nil
        pcall(function() Subsystems = FindAllOf("MeteoriteVoiceSubsystem") end)
        for _, Candidate in ipairs(Subsystems or {}) do
            Candidate = Unwrap(Candidate)
            if IsValidObject(Candidate) then
                VoiceSubsystem = Candidate
                break
            end
        end
    end
    if not IsValidObject(VoiceSubsystem) then
        return nil, nil, nil, "MeteoriteVoiceSubsystem unavailable"
    end

    LivesVoiceChatWidget = Best
    LivesVoiceSubsystem = VoiceSubsystem
    LivesVoiceHideChat(Best)
    return Best, VoiceSubsystem, LivesVoiceTextLibrary,
        string.format("resolved score=%d", BestScore)
end

function LivesVoiceReadOriginalTTS()
    local Settings = nil
    pcall(function() Settings = select(1, GetUserSettings(1)) end)
    if not IsValidObject(Settings) then return false, "settings unavailable; fallback=false" end

    local Original = nil
    pcall(function() Original = Unwrap(Settings.bTTSAndSTTEnabled) end)
    if type(Original) ~= "boolean" then
        return false, "bTTSAndSTTEnabled unreadable; fallback=false"
    end
    return Original, "P1 accessibility settings"
end

function LivesVoiceSetRuntimeTTS(Subsystem, Enabled, Reason)
    if not IsValidObject(Subsystem) then return false end
    local Ok, Err = pcall(function()
        Subsystem:BP_SetTextToSpeechEnabled(Enabled == true)
    end)
    if not Ok then
        Log("LIVESVOICE TTS switch failed enabled=%s reason=%s error=%s",
            tostring(Enabled == true), tostring(Reason or "state"), tostring(Err))
    end
    return Ok
end

function LivesVoiceSendHidden(Chat, TextLibrary, Message, Reason)
    if not IsValidObject(Chat) or not IsValidObject(TextLibrary) then return false end
    local Input = nil
    pcall(function() Input = Chat.InputTxt end)
    if not IsValidObject(Input) then return false end

    local PreviousText = nil
    pcall(function() PreviousText = Input:GetText() end)
    local Converted = nil
    local ConvertOk, ConvertErr = pcall(function()
        Converted = TextLibrary:Conv_StringToText(tostring(Message or ""))
    end)
    if not ConvertOk or Converted == nil then
        Log("LIVESVOICE text conversion failed reason=%s error=%s", tostring(Reason or "send"), tostring(ConvertErr))
        return false
    end

    LivesVoiceHideChat(Chat)
    local SetOk, SetErr = pcall(function() Input:SetText(Converted) end)
    if not SetOk then
        Log("LIVESVOICE input write failed reason=%s error=%s", tostring(Reason or "send"), tostring(SetErr))
        return false
    end

    local Result = false
    local SendOk, SendErr = pcall(function() Result = Chat:SendCurrentInput() end)
    if PreviousText ~= nil then pcall(function() Input:SetText(PreviousText) end) end
    LivesVoiceHideChat(Chat)

    if not SendOk or Result ~= true then
        Log("LIVESVOICE send failed reason=%s callOk=%s result=%s error=%s text=%s",
            tostring(Reason or "send"), tostring(SendOk), tostring(Result),
            SendOk and "-" or tostring(SendErr), tostring(Message))
        return false
    end
    Log("LIVESVOICE TX reason=%s text=%s", tostring(Reason or "state"), tostring(Message))
    return true
end

function LivesVoiceRemotePeerAvailable()
    if not MissionReady or not LivesAuthorityResolved or not LivesAuthorityAllowed then return false end

    local Cached = {}
    pcall(function() Cached = VehicleMessageCachedRemoteControllerCandidates() or {} end)
    if #Cached > 0 then return true end
    if VehicleMessageCapabilityMissionPrimed and VehicleMessageOfflineFastPath then return false end

    -- Only an explicit voice event can reach this bounded fallback scan. There is
    -- no periodic voice/network discovery work in ReceiveTick.
    local Candidates = {}
    pcall(function() Candidates = VehicleMessageRemoteControllerCandidates() or {} end)
    return #Candidates > 0
end

function LivesVoiceNumberWords(Value)
    local N = math.max(0, math.floor(tonumber(Value) or 0))
    local Small = {
        [0]="zero", [1]="one", [2]="two", [3]="three", [4]="four",
        [5]="five", [6]="six", [7]="seven", [8]="eight", [9]="nine",
        [10]="ten", [11]="eleven", [12]="twelve", [13]="thirteen",
        [14]="fourteen", [15]="fifteen", [16]="sixteen", [17]="seventeen",
        [18]="eighteen", [19]="nineteen"
    }
    if Small[N] ~= nil then return Small[N] end
    local Tens = {
        [2]="twenty", [3]="thirty", [4]="forty", [5]="fifty",
        [6]="sixty", [7]="seventy", [8]="eighty", [9]="ninety"
    }
    if N < 100 then
        local T = math.floor(N / 10)
        local O = N % 10
        local Prefix = Tens[T] or tostring(T * 10)
        if O == 0 then return Prefix end
        return Prefix .. " " .. (Small[O] or tostring(O))
    end
    return tostring(N)
end

function LivesVoiceRestoreStatusBanner()
    if not MissionReady then return false end

    if GameOverPending then
        return DisplayLivesBanner("NO LIVES - RESTARTING") == true
    end

    if ReinforcementActive then
        local Seconds = math.floor(tonumber(ReinforcementLastShown) or -1)
        if Seconds < 0 then
            Seconds = math.max(0, math.ceil((tonumber(ReinforcementRemaining) or 0.0) / 10.0) * 10)
        end
        return DisplayLivesBanner(string.format("REINFORCEMENTS: %d SEC", Seconds)) == true
    end

    if SetupActive and not SelectionLocked then
        return DisplayLivesBanner(CurrentSelectionText()) == true
    end

    if SelectionLocked then
        if MissionLivesEnabled then
            return DisplayLivesBanner(string.format("LIVES: %d", SimulatedLives)) == true
        end
        return DisplayLivesBanner("RESPAWN LIMIT: OFF") == true
    end

    return DisplayLivesBanner(" ") == true
end

function LivesVoiceScheduleDeathAnnouncement(Lives)
    if not LivesVoiceAnnouncementsEnabled then return false end
    Lives = math.max(0, math.floor(tonumber(Lives) or 0))
    LivesVoicePendingDeathLives = Lives
    LivesVoicePendingDeathRemaining = LivesVoiceDeathCoalesceSeconds
    Log("LIVESVOICE death coalesce armed lives=%d delay=%.2fs", Lives, LivesVoiceDeathCoalesceSeconds)
    return true
end

function LivesVoiceResetRuntime(Reason)
    LivesVoiceQueue = {}
    if LivesVoicePhase ~= 0 and IsValidObject(LivesVoiceSubsystem) and
       type(LivesVoiceOriginalTTS) == "boolean" then
        LivesVoiceSetRuntimeTTS(LivesVoiceSubsystem, LivesVoiceOriginalTTS, "runtime reset")
    end
    LivesVoiceHideChat(LivesVoiceChatWidget)
    LivesVoicePhase = 0
    LivesVoicePhaseRemaining = 0.0
    LivesVoiceCurrentMessage = ""
    LivesVoiceCurrentReason = ""
    LivesVoiceOriginalTTS = nil
    LivesVoiceChatWidget = nil
    LivesVoiceSubsystem = nil
    LivesVoiceTextLibrary = nil
    LivesVoicePendingDeathLives = nil
    LivesVoicePendingDeathRemaining = 0.0
    LivesVoiceToggleBannerRemaining = 0.0
    LivesVoiceNoRemoteLogged = false
    if Reason ~= nil and tostring(Reason) ~= "" then
        Log("LIVESVOICE runtime reset reason=%s enabled=%s", tostring(Reason), tostring(LivesVoiceAnnouncementsEnabled))
    end
end

function LivesVoiceQueueAnnouncement(Message, Reason)
    Message = tostring(Message or "")
    if Message == "" or not LivesVoiceAnnouncementsEnabled then return false end
    if not MissionReady or not LivesAuthorityResolved or not LivesAuthorityAllowed or LivesNetworkClientBlocked then
        return false
    end
    if not LivesVoiceRemotePeerAvailable() then
        if not LivesVoiceNoRemoteLogged then
            LivesVoiceNoRemoteLogged = true
            Log("LIVESVOICE dormant: no remote network peer; local/modded HUD text remains unaffected")
        end
        return false
    end
    LivesVoiceNoRemoteLogged = false

    if LivesVoiceCurrentMessage == Message then return false end
    local Last = LivesVoiceQueue[#LivesVoiceQueue]
    if type(Last) == "table" and tostring(Last.Text or "") == Message then return false end
    if #LivesVoiceQueue >= LivesVoiceMaxQueued then
        Log("LIVESVOICE queue full; dropping reason=%s text=%s", tostring(Reason or "state"), Message)
        return false
    end

    LivesVoiceQueue[#LivesVoiceQueue + 1] = { Text = Message, Reason = tostring(Reason or "state") }
    Log("LIVESVOICE queued depth=%d reason=%s text=%s", #LivesVoiceQueue, tostring(Reason or "state"), Message)
    return true
end

function LivesVoiceAnnounceLives(Lives, IncludeActivatedPrefix)
    Lives = math.max(0, math.floor(tonumber(Lives) or 0))
    local Message = ""
    if IncludeActivatedPrefix then
        if Lives == 1 then
            Message = "Limited respawns activated. Last life."
        else
            Message = "Limited respawns activated. " .. LivesVoiceNumberWords(Lives) .. " lives remaining."
        end
    elseif Lives <= 0 then
        Message = "No lives remaining."
    elseif Lives == 1 then
        Message = "Last life."
    else
        Message = LivesVoiceNumberWords(Lives) .. " lives remaining."
    end
    return LivesVoiceQueueAnnouncement(Message, IncludeActivatedPrefix and "limit activated" or "lives changed")
end

function LivesVoiceMaybeAnnounceReinforcement(Seconds)
    Seconds = math.max(0, math.floor(tonumber(Seconds) or 0))
    local Message = nil
    if Seconds == 120 then
        Message = "Reinforcements in two minutes."
    elseif Seconds == 90 then
        Message = "Reinforcements in ninety seconds."
    elseif Seconds == 60 then
        Message = "Reinforcements in one minute."
    elseif Seconds == 30 then
        Message = "Reinforcements in thirty seconds."
    end
    if Message ~= nil then
        return LivesVoiceQueueAnnouncement(Message, "reinforcement milestone")
    end
    return false
end

function LivesVoiceTick(Delta)
    Delta = tonumber(Delta) or (1.0 / 60.0)

    if LivesVoiceToggleBannerRemaining > 0.0 then
        LivesVoiceToggleBannerRemaining = LivesVoiceToggleBannerRemaining - Delta
        if LivesVoiceToggleBannerRemaining <= 0.0 then
            LivesVoiceToggleBannerRemaining = 0.0
            LivesVoiceRestoreStatusBanner()
        end
    end

    if not LivesVoiceAnnouncementsEnabled then
        if LivesVoicePhase ~= 0 or #LivesVoiceQueue > 0 then
            LivesVoiceResetRuntime("voice announcements disabled")
        end
        return
    end

    if LivesVoicePendingDeathLives ~= nil then
        LivesVoicePendingDeathRemaining = LivesVoicePendingDeathRemaining - Delta
        if LivesVoicePendingDeathRemaining <= 0.0 then
            local FinalLives = LivesVoicePendingDeathLives
            LivesVoicePendingDeathLives = nil
            LivesVoicePendingDeathRemaining = 0.0
            LivesVoiceAnnounceLives(FinalLives, false)
        end
    end

    if LivesVoicePhase == 0 then
        if #LivesVoiceQueue == 0 then return end
        if not LivesVoiceRemotePeerAvailable() then
            local Dropped = table.remove(LivesVoiceQueue, 1)
            Log("LIVESVOICE dropped queued announcement after peer vanished text=%s",
                type(Dropped) == "table" and tostring(Dropped.Text or "") or "")
            return
        end

        local Chat, Subsystem, TextLibrary, Detail = LivesVoiceResolveTransport()
        if not IsValidObject(Chat) or not IsValidObject(Subsystem) or not IsValidObject(TextLibrary) then
            local Dropped = table.remove(LivesVoiceQueue, 1)
            Log("LIVESVOICE transport unavailable; dropped text=%s detail=%s",
                type(Dropped) == "table" and tostring(Dropped.Text or "") or "", tostring(Detail))
            return
        end

        local Item = table.remove(LivesVoiceQueue, 1)
        LivesVoiceCurrentMessage = tostring(Item.Text or "")
        LivesVoiceCurrentReason = tostring(Item.Reason or "state")
        LivesVoiceOriginalTTS = select(1, LivesVoiceReadOriginalTTS())
        LivesVoiceHideChat(Chat)
        if not LivesVoiceSetRuntimeTTS(Subsystem, true, "announcement prepare") then
            LivesVoiceCurrentMessage = ""
            LivesVoiceCurrentReason = ""
            LivesVoiceOriginalTTS = nil
            return
        end
        LivesVoicePhase = 1
        LivesVoicePhaseRemaining = LivesVoiceSettleSeconds
        return
    end

    LivesVoicePhaseRemaining = LivesVoicePhaseRemaining - Delta
    if LivesVoicePhaseRemaining > 0.0 then return end

    if LivesVoicePhase == 1 then
        if not IsValidObject(LivesVoiceChatWidget) or not IsValidObject(LivesVoiceTextLibrary) then
            LivesVoiceResetRuntime("transport invalid before send")
            return
        end
        LivesVoiceSendHidden(
            LivesVoiceChatWidget,
            LivesVoiceTextLibrary,
            LivesVoiceCurrentMessage,
            LivesVoiceCurrentReason
        )
        LivesVoicePhase = 2
        LivesVoicePhaseRemaining = LivesVoiceRestoreSeconds
        return
    end

    if LivesVoicePhase == 2 then
        if IsValidObject(LivesVoiceSubsystem) and type(LivesVoiceOriginalTTS) == "boolean" then
            LivesVoiceSetRuntimeTTS(LivesVoiceSubsystem, LivesVoiceOriginalTTS, "announcement restore")
        end
        LivesVoiceHideChat(LivesVoiceChatWidget)
        LivesVoicePhase = 0
        LivesVoicePhaseRemaining = 0.0
        LivesVoiceCurrentMessage = ""
        LivesVoiceCurrentReason = ""
        LivesVoiceOriginalTTS = nil
    end
end

function ToggleLivesVoiceAnnouncements(PlayerIndex, Source)
    if tonumber(PlayerIndex) ~= 1 then
        Log("LIVESVOICE toggle ignored: host P1 only source=%s", tostring(Source or "RB+Y"))
        return false
    end
    if LivesNetworkClientBlocked or (LivesAuthorityResolved and not LivesAuthorityAllowed) then
        Log("LIVESVOICE toggle ignored on network client source=%s", tostring(Source or "RB+Y"))
        return false
    end

    LivesVoiceAnnouncementsEnabled = not LivesVoiceAnnouncementsEnabled
    if not LivesVoiceAnnouncementsEnabled then
        LivesVoiceResetRuntime("voice toggle OFF")
    end

    local Status = LivesVoiceAnnouncementsEnabled and "VOICE ANNOUNCEMENTS: ON" or "VOICE ANNOUNCEMENTS: OFF"
    DisplayLivesBanner(Status)
    LivesVoiceToggleBannerRemaining = LivesVoiceToggleBannerSeconds
    Log("LIVESVOICE toggle -> %s source=%s", LivesVoiceAnnouncementsEnabled and "ON" or "OFF", tostring(Source or "RB+Y"))
    return true
end

-- Dynamic Limited Respawns input hint. Halo/UE CommonInput tracks the most
-- recently used input method. Resolve P1's subsystem only when the short setup
-- hint is about to be shown, then sample that cached subsystem at a bounded
-- interval while the hint is visible. No permanent input-method polling is added.
LivesCommonInputSubsystem = LivesCommonInputSubsystem or nil
LivesCommonInputResolveAttempted = LivesCommonInputResolveAttempted or false
LivesInputHintKind = LivesInputHintKind or "unknown"
LivesInputHintRefreshAccumulator = LivesInputHintRefreshAccumulator or 0.0
LivesInputHintRefreshInterval = 0.25

-- Limited Respawns is configured only after the campaign HUD is live.
-- Frontend/difficulty/fireteam selection is completely disabled. P1 uses
-- RB + D-pad UP during a short mission-start setup window. Any selection restarts
-- the idle delay;
-- after a visible callback-driven 5-second countdown the choice is locked.
SetupActive = false
SelectionLocked = false
PromptShown = false
SelectionTouched = false
IdleBeforeCountdownSeconds = 3.0
CountdownSeconds = 5
-- Startup presentation is callback-driven. OFF is re-asserted after HUD
-- repair settles, then the input hint appears later if P1 still has not touched
-- the selector. Mission-start timing remains free of per-frame time polling.
MissionReady = false
LivesMissionGeneration = 0
MissionCandidateName = ""
MissionCandidateTicks = 0
MissionStableTicksRequired = 180
HudReadyTicks = 0
-- Keep the HUD stability gate bounded: sample WBP_Banner_C only every 10 mission
-- ticks and require four successful samples before the mission HUD is considered ready.
HudReadyTicksRequired = 4
-- Seamless campaign restart does not reliably trigger RegisterLoadMap hooks.
-- Track entry into the travel/frontend controller world so the mission selector and
-- game-over state are reset exactly once at that confirmed lifecycle boundary.
TravelResetActive = false
-- RestartLevel can return the players to gameplay on the SAME campaign
-- controller long before SeamlessTravelTEst appears. Re-arm the selector from the
-- successful RestartLevel dispatch itself after a short one-shot grace period.
RestartRearmDelayMs = 5000
RestartRearmToken = 0
-- Mission-start timing uses the existing P1 ReceiveTick DeltaSeconds and avoids
-- per-frame engine-time queries or extra delayed callbacks.
MissionCountdownToken = 0
-- Restart handling: SeamlessTravelTEst is the manual Restart Mission boundary.
-- The existing ReceiveTick stability gate resolves travel without another timer.
TravelRecoveryToken = 0
TravelRecoveryRecoveredToken = -1
-- Presentation: re-assert OFF after the final startup HUD repair has had
-- time to settle, then show the control hint later. This makes OFF reliably
-- become the first visible Limited Respawns message after a fresh start/restart.
SetupIntroGenerationToken = 0
SetupOffReaffirmDelayMs = 2500
SetupHintAfterOffDelayMs = 3000
LimitedRespawnsHintVisibleMs = 5500 -- Keep the startup control hint readable before returning to OFF.
-- Countdown: the banner animates text too slowly to redraw a full phrase
-- once per second. Show the phrase once, then only the single digits.
CountdownHeaderMs = 1500
-- SeamlessTravelTEst is used both between campaign missions and internally
-- during the startup/streaming of a mission (A30 demonstrates this). Do not
-- destroy a valid Limited Respawns selection merely because the temporary test
-- controller appears. Defer classification until a real campaign controller
-- returns, then compare its campaign map key with the map we came from.
CurrentCampaignMapKey = CurrentCampaignMapKey or ""
CampaignGameStateListenerReady = CampaignGameStateListenerReady or false
TravelPending = false
TravelSourceMapKey = ""
TravelSourceGeneration = -1
TravelWasSetupActive = false
TravelWasSelectionTouched = false
-- A return to the real Frontend is an authoritative end-of-session
-- boundary. The frontend controller has no local ControllerId on this build, so
-- The local-player filter must not hide this boundary before MissionTick can clear a same-map snapshot.
-- Track the boundary explicitly so starting the same campaign map again cannot
-- inherit a locked respawn limit from the previous session.
FrontendBoundarySeen = false

function ResolveLimitedRespawnsAuthority(Controller, Reason)
    local GameMode = nil
    local GameModeOk, GameModeErr = pcall(function()
        GameMode = UEHelpers.GetGameModeBase()
    end)
    local Authority = GameModeOk and IsValidObject(GameMode)

    -- Fallback to the replicated Actor role only if the helper cannot see a
    -- valid AuthorityGameMode. ROLE_Authority is 3 in UE; network-client local
    -- controllers are normally ROLE_AutonomousProxy (2).
    local RoleValue = nil
    local RoleOk = false
    if IsValidObject(Controller) then
        RoleOk = pcall(function() RoleValue = Unwrap(Controller.Role) end)
    end
    local RoleNumber = tonumber(RoleValue)
    local RoleText = string.lower(tostring(RoleValue or ""))
    if not Authority and RoleOk then
        if RoleNumber == 3 or string.find(RoleText, "authority", 1, true) then
            Authority = true
        end
    end

    LivesAuthorityResolved = true
    LivesAuthorityAllowed = Authority == true
    LivesNetworkClientBlocked = not LivesAuthorityAllowed
    local HasLocalP2ForPerspective = IsValidObject(GetPlayer(2))
    SetPerspectiveContextShift(LivesNetworkClientBlocked and HasLocalP2ForPerspective, "authority/topology resolved")
    local AuthorityMode = LivesAuthorityAllowed and "authority" or "network-client"
    LivesAuthorityNoticeShown = false

    local GameModeName = "<none>"
    if IsValidObject(GameMode) then GameModeName = SafeFullName(GameMode) or "<valid>" end
    Log("LIVES authority resolved: allowed=%s mode=%s gameMode=%s role=%s source=%s helperOk=%s%s",
        tostring(LivesAuthorityAllowed), tostring(AuthorityMode),
        tostring(GameModeName), tostring(RoleValue), tostring(Reason or "mission boundary"),
        tostring(GameModeOk), GameModeOk and "" or (" err=" .. tostring(GameModeErr)))
    return LivesAuthorityAllowed
end

function DisableLimitedRespawnsForNetworkClient(Reason, ShowMessage)
    SetupIntroGenerationToken = SetupIntroGenerationToken + 1
    MissionCountdownToken = MissionCountdownToken + 1
    SetupIntroPhase = 0
    SetupIntroRemaining = 0.0
    CountdownPhase = 0
    CountdownRemaining = 0.0
    CountdownDigit = 0
    GameOverRestartRemaining = 0.0
    RestartRearmRemaining = 0.0
    SetupActive = false
    SelectionLocked = true
    PromptShown = true
    SelectionTouched = false
    LivesOptionIndex = 1
    StartingExtraLives = 0
    SimulatedLives = 0
    MissionLivesEnabled = false
    GameOverPending = false
    CancelReinforcementTimer("network client authority gate")

    if ShowMessage and not LivesAuthorityNoticeShown then
        if LivesRemoteHostSyncSeen then
            LivesNetworkDisplayRemoteState("authority gate")
        else
            DisplayLivesBanner("LIMITED RESPAWNS: NETWORK HOST ONLY")
        end
        LivesAuthorityNoticeShown = true
    end
    Log("LIVES network-client safety gate ACTIVE: Limited Respawns disabled; host P1 owns this feature (%s)",
        tostring(Reason or "authority check"))
end

function ShowLimitedRespawnsHostOnlyNotice(Source)
    if not LivesNetworkClientBlocked then return end

    -- Explicit client input should explain why the selector did not change,
    -- regardless of the host's current mirrored Lives status. Give the banner
    -- enough time for its built-in typewriter animation to finish and be read.
    LivesHostOnlyNoticeToken = (tonumber(LivesHostOnlyNoticeToken) or 0) + 1
    LivesRemoteOffDisplayToken = (tonumber(LivesRemoteOffDisplayToken) or 0) + 1
    local NoticeToken = LivesHostOnlyNoticeToken
    local NoticeGeneration = LivesMissionGeneration
    local RemoteRevision = LivesRemoteHostStateRevision
    DisplayLivesBanner("LIMITED RESPAWNS: NETWORK HOST ONLY")
    LivesAuthorityNoticeShown = true

    -- Restore an active host status after the one-shot notice. If the host is OFF
    -- (or no snapshot exists yet), clear the banner instead of returning to a
    -- permanent OFF message. A newer host update invalidates this callback and
    -- displays immediately via LivesNetworkHandleMessage. No polling is added.
    ExecuteInGameThreadWithDelay(LivesHostOnlyNoticeVisibleMs, function()
        if ModTeardownGuard or not MissionReady or not LivesNetworkClientBlocked then return end
        if NoticeToken ~= LivesHostOnlyNoticeToken then return end
        if NoticeGeneration ~= LivesMissionGeneration then return end
        if RemoteRevision ~= LivesRemoteHostStateRevision then return end

        if LivesRemoteHostSyncSeen and tostring(LivesRemoteHostState or "") ~= "O" then
            DisplayLivesBanner(LivesNetworkRemoteBannerText())
            Log("LIVES network-client HOST ONLY notice expired after %.1fs; restored host state=%s value=%d",
                LivesHostOnlyNoticeVisibleMs / 1000.0,
                tostring(LivesRemoteHostState or ""), tonumber(LivesRemoteHostValue) or 0)
        else
            DisplayLivesBanner(" ")
            Log("LIVES network-client HOST ONLY notice expired after %.1fs; banner cleared hostState=%s",
                LivesHostOnlyNoticeVisibleMs / 1000.0, tostring(LivesRemoteHostState or "<none>"))
        end
    end)

    Log("LIVES input ignored on network client (%s); Limited Respawns is host P1 only",
        tostring(Source or "input"))
end

function ReadIncidentField(Value, Field)
    local Object = Unwrap(Value)
    local Result = nil
    pcall(function() Result = Object[Field] end)
    return Unwrap(Result)
end

function IncidentValueText(Value)
    local Unwrapped = Unwrap(Value)
    if Unwrapped == nil then return "<nil>" end
    if IsValidObject(Unwrapped) then return SafeFullName(Unwrapped) end
    return SafeToString(Unwrapped)
end

-- Limited Respawns uses Halo's existing per-player HUD banner queue. Unlike ClientMessage,
-- this is a real game widget already sized and anchored by each local HUD.
function GetTextLibrary()
    if IsValidObject(LivesTextLibrary) then return LivesTextLibrary end
    pcall(function()
        LivesTextLibrary = StaticFindObject("/Script/Engine.Default__KismetTextLibrary")
    end)
    return LivesTextLibrary
end

function ClearBannerCache(Reason)
    BannerCache[0] = nil
    BannerCache[1] = nil
    BannerCandidates[0] = {}
    BannerCandidates[1] = {}
    if Reason ~= nil then
        Log("LIVESHUD banner cache cleared: %s", tostring(Reason))
    end
end

function GetBannerControllerId(Banner)
    if not IsValidObject(Banner) then return nil end
    local ControllerId = nil
    pcall(function()
        local Controller = Banner:GetOwningPlayer()
        if IsValidObject(Controller) and IsValidObject(Controller.Player) then
            ControllerId = Controller.Player.ControllerId
        end
    end)
    if type(ControllerId) == "number" and ControllerId >= 0 and ControllerId <= 1 then
        return ControllerId
    end
    return nil
end

function RequiredHudControllers()
    -- Single-player has only the P1 HUD. Treat one live local controller as a
    -- complete HUD target so banner discovery cannot wait forever for P2.
    return IsValidObject(PlayerControllerTable[2]) and 2 or 1
end

function CacheBannerCandidate(ControllerId, Banner)
    if type(ControllerId) ~= "number" or ControllerId < 0 or ControllerId > 1 or
       not IsValidObject(Banner) then
        return false
    end

    local CandidateName = SafeFullName(Banner) or ""
    local ExistingList = BannerCandidates[ControllerId]
    if type(ExistingList) ~= "table" then ExistingList = {} end
    local NewList = {}
    local AlreadyPresent = false

    for _, Existing in ipairs(ExistingList) do
        if IsValidObject(Existing) and GetBannerControllerId(Existing) == ControllerId then
            NewList[#NewList + 1] = Existing
            if (SafeFullName(Existing) or "") == CandidateName then
                AlreadyPresent = true
            end
        end
    end

    if not AlreadyPresent then
        NewList[#NewList + 1] = Banner
    end
    BannerCandidates[ControllerId] = NewList
    -- Retain the original single-widget cache for compatibility with older code.
    BannerCache[ControllerId] = Banner
    return not AlreadyPresent
end

function DisplayLivesBanner(Message)
    local TextLibrary = GetTextLibrary()
    if not IsValidObject(TextLibrary) then
        Log("LIVESHUD unavailable: KismetTextLibrary not found")
        return false
    end

    local HaloText = nil
    local TextOk, TextErr = pcall(function()
        HaloText = TextLibrary:Conv_StringToText(tostring(Message or ""))
    end)
    if not TextOk or HaloText == nil then
        Log("LIVESHUD text conversion failed: %s", tostring(TextErr))
        return false
    end

    local ShownControllers = 0
    local WidgetCalls = 0
    local SeenControllerIds = {}
    local UsedFallbackScan = false
    local RequiredControllers = RequiredHudControllers()

    -- Fast path: send the message to every currently valid banner candidate
    -- for each local controller. Campaign transitions can temporarily leave stale
    -- but callable WBP_Banner_C instances alive; fanning out to the bounded cached
    -- set ensures the actually visible HUD receives the same message too.
    for ControllerId = 0, RequiredControllers - 1 do
        local Candidates = BannerCandidates[ControllerId]
        if type(Candidates) ~= "table" then Candidates = {} end

        -- Compatibility: if a candidate set has not been built yet, seed it with
        -- the single cached banner entry before deciding whether to scan.
        if #Candidates == 0 then
            local LegacyBanner = BannerCache[ControllerId]
            if IsValidObject(LegacyBanner) and
               GetBannerControllerId(LegacyBanner) == ControllerId then
                Candidates = {LegacyBanner}
            end
        end

        local Kept = {}
        local Delivered = false
        local SeenNames = {}
        for _, Banner in ipairs(Candidates) do
            if IsValidObject(Banner) and GetBannerControllerId(Banner) == ControllerId then
                local BannerName = SafeFullName(Banner) or ""
                if not SeenNames[BannerName] then
                    SeenNames[BannerName] = true
                    local CallOk = pcall(function()
                        Banner:DisplayMessage(HaloText, 1, 0, true)
                    end)
                    if CallOk then
                        Kept[#Kept + 1] = Banner
                        WidgetCalls = WidgetCalls + 1
                        Delivered = true
                    end
                end
            end
        end

        BannerCandidates[ControllerId] = Kept
        if #Kept > 0 then
            BannerCache[ControllerId] = Kept[#Kept]
        else
            BannerCache[ControllerId] = nil
        end
        if Delivered then
            SeenControllerIds[ControllerId] = true
            ShownControllers = ShownControllers + 1
        end
    end

    -- Fallback only when one or more currently-required local controllers have
    -- no usable cached banner. In single-player this target is P1 only, avoiding
    -- a permanent scan loop that can never find a nonexistent P2 HUD.
    if ShownControllers < RequiredControllers then
        UsedFallbackScan = true
        local Banners = nil
        pcall(function() Banners = FindAllOf("WBP_Banner_C") end)
        for _, Banner in ipairs(Banners or {}) do
            if IsValidObject(Banner) and
               not string.find(SafeFullName(Banner), "Default__", 1, true) then
                local ControllerId = GetBannerControllerId(Banner)
                if ControllerId ~= nil and ControllerId < RequiredControllers then
                    local Added = CacheBannerCandidate(ControllerId, Banner)
                    if Added then
                        local CallOk, CallErr = pcall(function()
                            Banner:DisplayMessage(HaloText, 1, 0, true)
                        end)
                        if CallOk then
                            WidgetCalls = WidgetCalls + 1
                            if not SeenControllerIds[ControllerId] then
                                SeenControllerIds[ControllerId] = true
                                ShownControllers = ShownControllers + 1
                            end
                            Log("LIVESHUD banner candidate discovered P%d widget=%s",
                                ControllerId + 1, SafeFullName(Banner))
                        else
                            Log("LIVESHUD banner failed P%d: %s", ControllerId + 1, tostring(CallErr))
                        end
                    end
                end
            end
        end
    end

    Log("LIVESHUD display result controllers=%d target=%d widgets=%d source=%s text=%s",
        ShownControllers, RequiredControllers, WidgetCalls,
        UsedFallbackScan and "scan" or "cache", tostring(Message))
    return ShownControllers > 0
end

-- Pre-mission/difficulty/fireteam selection is intentionally absent.

function CancelReinforcementTimer(Reason)
    if ReinforcementActive then
        Log("LIVES reinforcement timer cancelled: %s", tostring(Reason or "state change"))
    end
    ReinforcementActive = false
        ReinforcementLastShown = -1
        ReinforcementRemaining = 0.0
    ReinforcementNextShown = 0
    ReinforcementGeneration = -1
    ReinforcementVoiceLastSecond = -1
end

function ShowCountdown(Seconds)
    if ReinforcementLastShown == Seconds then return end
    ReinforcementLastShown = Seconds
    DisplayLivesBanner(string.format("REINFORCEMENTS: %d SEC", Seconds))
    LivesNetworkBroadcastState("R", Seconds, "reinforcement countdown")
    LivesVoiceMaybeAnnounceReinforcement(Seconds)
end

function StartReinforcementTimer()
    if LivesNetworkClientBlocked or not LivesAuthorityAllowed then return false end
    if not MissionLivesEnabled or GameOverPending or
       SimulatedLives ~= 0 or ReinforcementActive then return false end

    ReinforcementActive = true
        ReinforcementLastShown = -1
    ReinforcementRemaining = tonumber(ReinforcementDelaySeconds) or 120.0
    ReinforcementNextShown = math.max(0, ReinforcementDelaySeconds - ReinforcementUpdateSeconds)
    ReinforcementGeneration = LivesMissionGeneration
    ReinforcementVoiceLastSecond = -1
    ShowCountdown(ReinforcementDelaySeconds)
    Log("LIVES reinforcement armed: one life in %d seconds; HUD updates every %d seconds from ReceiveTick DeltaSeconds; no delayed callbacks",
        ReinforcementDelaySeconds, ReinforcementUpdateSeconds)
    return true
end

function ExecuteRestartRearm(Token)
    if ModTeardownGuard or Token ~= RestartRearmToken then return end

    if not LivesAuthorityResolved then
        ResolveLimitedRespawnsAuthority(PlayerControllerTable[1], "RestartLevel rearm")
    end
    if LivesNetworkClientBlocked or not LivesAuthorityAllowed then
        DisableLimitedRespawnsForNetworkClient("RestartLevel rearm blocked on network client", true)
        return
    end

    -- RestartLevel can keep the same campaign controller alive. Reset the old
    -- selection, then reopen OFF directly if the current campaign HUD is ready.
    ResetMissionSelection("successful RestartLevel dispatch")
    LastDeathByPlayer = {}
    HudReadyTicks = 0

    local P1 = PlayerControllerTable[1]
    local Name = IsValidObject(P1) and (SafeFullName(P1) or "") or ""
    local LowerName = string.lower(Name)
    local InTravel = string.find(LowerName, "/game/levels/test/seamlesstraveltest", 1, true) ~= nil or
        string.find(LowerName, "/game/levels/ui/frontend/", 1, true) ~= nil
    local Pawn = nil
    if IsValidObject(P1) then pcall(function() Pawn = P1.Pawn end) end
    local CampaignPawnReady = IsValidObject(Pawn) and
        string.find(SafeFullName(Pawn) or "", "BP_MeteoritePawn_C", 1, true) ~= nil

    if IsValidObject(P1) and not InTravel and CampaignPawnReady and MissionHudReady() then
        LivesMissionControllerName = Name
        MissionControllerObject = P1
        MissionCandidateName = Name
        MissionCandidateTicks = MissionStableTicksRequired
        HudReadyTicks = HudReadyTicksRequired
        MissionReady = true
        SetupActive = true
        SelectionLocked = false
        SelectionTouched = false
        StartingExtraLives = 0
        SimulatedLives = 0
        MissionLivesEnabled = false
        DisplayLivesBanner("RESPAWN LIMIT: OFF")
        LivesNetworkBroadcastState("O", 0, "restart rearm")
        ScheduleSetupHint()
        Log("Limited Respawns reopened after Restart Mission on the existing campaign controller")
    else
        DisplayLivesBanner(" ")
        MissionCandidateName = ""
        MissionCandidateTicks = 0
        Log("Limited Respawns reset after Restart Mission; waiting for the campaign HUD")
    end
end

function ScheduleRestartRearm()
    RestartRearmToken = RestartRearmToken + 1
    RestartRearmArmedToken = RestartRearmToken
    RestartRearmRemaining = RestartRearmDelayMs / 1000.0
    Log("Limited Respawns restart rearm scheduled in %.1f seconds", RestartRearmRemaining)
end

function RestartMissionAfterGameOver()
    if LivesNetworkClientBlocked or not LivesAuthorityAllowed then
        DisableLimitedRespawnsForNetworkClient("game-over restart blocked on network client", true)
        return
    end
    if GameOverPending then return end
    CancelReinforcementTimer("game over")
    GameOverPending = true
    DisplayLivesBanner("NO LIVES - RESTARTING")
    LivesNetworkBroadcastState("G", 0, "game over")
    if LivesVoiceAnnouncementsEnabled then
        LivesVoiceResetRuntime("game over priority")
        LivesVoiceQueueAnnouncement("No lives. Restarting.", "game over")
    end
    GameOverRestartRemaining = RestartDelayMs / 1000.0
    GameOverRestartTravelGeneration = ModTravelGeneration
    Log("Limited Respawns game over; Restart Mission in %.1f seconds", GameOverRestartRemaining)
end

function DispatchGameOverRestart()
    if LivesNetworkClientBlocked or not LivesAuthorityAllowed then
        GameOverRestartRemaining = 0.0
        GameOverPending = false
        return
    end
    if not GameOverPending or ModTeardownGuard or
       GameOverRestartTravelGeneration ~= ModTravelGeneration then
        GameOverRestartRemaining = 0.0
        return
    end

    local CampaignFlow = FindLive("BlamCampaignFlowGameSubsystem")
    if not IsValidObject(CampaignFlow) then
        GameOverPending = false
        DisplayLivesBanner("RESTART FAILED - USE PAUSE MENU")
        Log("Limited Respawns restart failed: campaign-flow subsystem unavailable")
        return
    end

    local RestartOk, RestartErr = pcall(function() CampaignFlow:RestartLevel() end)
    if RestartOk then
        Log("Limited Respawns RestartLevel dispatched")
        ScheduleRestartRearm()
    else
        GameOverPending = false
        DisplayLivesBanner("RESTART FAILED - USE PAUSE MENU")
        Log("Limited Respawns restart failed: %s", tostring(RestartErr))
    end
end

function HandlePlayerDeath(Context, ...)
    if LivesNetworkClientBlocked or (LivesAuthorityResolved and not LivesAuthorityAllowed) then return end
    local Args = {...}
    local Incident = Unwrap(Args[1])
    local EffectIndex = ReadIncidentField(Incident, "EffectPlayerAbsoluteIndex")
    local EffectActor = ReadIncidentField(Incident, "EffectObjectActor")

    -- Halo can deliver the same Blueprint death incident more than once. Count
    -- at most one matching victim event within a two-second window.
    local VictimKey = IncidentValueText(EffectIndex) .. "|" .. IncidentValueText(EffectActor)
    local Now = os.clock()
    pcall(function()
        Now = GetGameplayStatics():GetRealTimeSeconds(UEHelpers.GetWorldContextObject())
    end)
    local Last = LastDeathByPlayer[VictimKey]
    if Last ~= nil and (Now - Last) < 2.0 then return end
    LastDeathByPlayer[VictimKey] = Now

    if TravelPending or not MissionLivesEnabled or GameOverPending then return end

    if SimulatedLives > 0 then
        SimulatedLives = SimulatedLives - 1
        if SimulatedLives == 0 then
            DisplayLivesBanner("LIVES: 0 - LAST CHANCE")
            LivesVoicePendingDeathLives = nil
            LivesVoicePendingDeathRemaining = 0.0
            LivesVoiceAnnounceLives(0, false)
            StartReinforcementTimer()
        else
            DisplayLivesBanner(string.format("LIVES: %d", SimulatedLives))
            LivesNetworkBroadcastState("L", SimulatedLives, "death counted")
            LivesVoiceScheduleDeathAnnouncement(SimulatedLives)
        end
    else
        RestartMissionAfterGameOver()
    end
    Log("Limited Respawns death counted; lives remaining=%d", SimulatedLives)
end

function TryRegisterLivesHook(Label, Path, Callback, LogPost)
    if LivesHooks[Label] then return true end
    LivesHookAttempts[Label] = (LivesHookAttempts[Label] or 0) + 1
    local Ok, Err = pcall(function()
        RegisterHook(Path,
            function(Context, ...)
                local CallOk, CallErr = pcall(Callback, "PRE", Context, ...)
                if not CallOk then
                    Log("Limited Respawns hook callback error %s PRE: %s", Label, tostring(CallErr))
                end
            end,
            function(Context, ...)
                if not LogPost then return end
                local CallOk, CallErr = pcall(Callback, "POST", Context, ...)
                if not CallOk then
                    Log("Limited Respawns hook callback error %s POST: %s", Label, tostring(CallErr))
                end
            end)
    end)
    if Ok then
        LivesHooks[Label] = true
        Log("Limited Respawns hook ready: %s", Label)
        return true
    end
    if LivesHookAttempts[Label] == 1 or (LivesHookAttempts[Label] % 30) == 0 then
        Log("Limited Respawns hook pending: %s | %s", Label, tostring(Err))
    end
    return false
end

function HandleCampaignRestartLevel(Phase, Context, ...)
    if Phase ~= "POST" then return end

    -- Vehicle repair remains valid on both host and client; only the Limited
    -- Respawns campaign-rule state is authority-gated.
    if InvalidateWarthogColorRuntime ~= nil then
        pcall(function() InvalidateWarthogColorRuntime("native RestartLevel / checkpoint-or-restart", true) end)
    end
    if InvalidateScorpionColorRuntime ~= nil then
        pcall(function() InvalidateScorpionColorRuntime("native RestartLevel / checkpoint-or-restart", true) end)
    end

    if not LivesAuthorityResolved then
        ResolveLimitedRespawnsAuthority(PlayerControllerTable[1], "RestartLevel hook")
    end
    if LivesNetworkClientBlocked or not LivesAuthorityAllowed then
        DisableLimitedRespawnsForNetworkClient("RestartLevel observed on network client", false)
        Log("Limited Respawns RestartLevel ignored on network client; no local rearm/restart ownership")
        return
    end

    -- The game-over path already schedules its own rearm after dispatching RestartLevel.
    if GameOverPending then return end

    ResetMissionSelection("native RestartLevel hook")
    LastDeathByPlayer = {}
    LivesMissionControllerName = ""
    MissionControllerObject = nil
    DisplayLivesBanner(" ")
    ScheduleRestartRearm()
    Log("Limited Respawns detected Restart Mission; OFF setup scheduled")
end

LivesPlayerDeathConstructionListenerReady = LivesPlayerDeathConstructionListenerReady or false

function RegisterLivesPlayerDeathConstructionListener()
    if LivesPlayerDeathConstructionListenerReady then return true end
    local Ok, Err = pcall(function()
        NotifyOnNewObject(
            "/Game/Blueprints/BPC_MeteoriteIncidentHandlerComponent.BPC_MeteoriteIncidentHandlerComponent_C",
            function()
                -- Object construction proves the Blueprint class/UFunction is live.
                -- Queue one game-thread registration attempt instead of polling RegisterHook.
                ExecuteInGameThreadWithDelay(50, function()
                    if not LivesHooks["PlayerDeath"] then
                        RegisterLivesHooks()
                    end
                end)
            end
        )
    end)
    if Ok then
        LivesPlayerDeathConstructionListenerReady = true
        Log("Limited Respawns PlayerDeath construction listener ready; polling retry disabled")
        return true
    end
    Log("Limited Respawns PlayerDeath construction listener unavailable: %s", tostring(Err))
    return false
end

function RegisterLivesHooks()
    TryRegisterLivesHook("PlayerDeath",
        "/Game/Blueprints/BPC_MeteoriteIncidentHandlerComponent.BPC_MeteoriteIncidentHandlerComponent_C:HandlePlayerDeath",
        function(Phase, Context, ...)
            if Phase == "PRE" then HandlePlayerDeath(Context, ...) end
        end, false)

    -- The native RestartLevel function exists at startup on supported builds.
    -- Limit failed registration attempts so a missing path can never become a
    -- recurring gameplay cost.
    if LivesHooks["CampaignRestartLevel"] or
       (LivesHookAttempts["CampaignRestartLevel"] or 0) < 3 then
        TryRegisterLivesHook("CampaignRestartLevel",
            "/Script/BlamEngine.BlamCampaignFlowGameSubsystem:RestartLevel",
            HandleCampaignRestartLevel, true)
    end
end

function LivesHookRetryTick()
    if LivesHooks["PlayerDeath"] then return end
    -- Normal path is event-driven through NotifyOnNewObject. Only if that listener
    -- could not be installed do a very slow bounded compatibility retry; never the
    -- old ~2-second RegisterHook cadence that could create regular frame hitches.
    if LivesPlayerDeathConstructionListenerReady then return end
    HookRetryTicks = HookRetryTicks + 1
    if HookRetryTicks == 1 or (HookRetryTicks % 250) == 0 then
        RegisterLivesHooks()
    end
end

function MissionHudReady()
    local Banners = nil
    local Ok = pcall(function() Banners = FindAllOf("WBP_Banner_C") end)
    if not Ok or Banners == nil then return false end
    local Seen = {}
    local RequiredControllers = RequiredHudControllers()

    -- Build the complete current banner candidate set during the bounded HUD
    -- readiness gate. No global banner scan is performed after the mission settles.
    BannerCandidates[0] = {}
    BannerCandidates[1] = {}
    BannerCache[0] = nil
    BannerCache[1] = nil

    for _, Banner in ipairs(Banners or {}) do
        if IsValidObject(Banner) and not string.find(SafeFullName(Banner) or "", "Default__", 1, true) then
            local ControllerId = GetBannerControllerId(Banner)
            if ControllerId ~= nil then
                Seen[ControllerId] = true
                CacheBannerCandidate(ControllerId, Banner)
            end
        end
    end
    return Seen[0] == true and (RequiredControllers == 1 or Seen[1] == true)
end

function LivesResolveCommonInputSubsystem()
    if IsValidObject(LivesCommonInputSubsystem) then
        return LivesCommonInputSubsystem
    end
    if LivesCommonInputResolveAttempted then return nil end
    LivesCommonInputResolveAttempted = true

    local P1 = GetPlayer(1)
    if not IsValidObject(P1) then return nil end

    -- Precise route: ask UE for the CommonInput LocalPlayerSubsystem belonging
    -- specifically to P1's PlayerController. This is attempted once per mission.
    -- If the reflected Blueprint-library route is unavailable, keep the old
    -- combined hint rather than performing repeated global object scans.
    local Library = StaticFindObject("/Script/Engine.Default__SubsystemBlueprintLibrary")
    local CommonInputClass = StaticFindObject("/Script/CommonInput.CommonInputSubsystem")
    if IsValidObject(Library) and IsValidObject(CommonInputClass) then
        local Ok, Subsystem = pcall(function()
            return Library:GetLocalPlayerSubSystemFromPlayerController(P1, CommonInputClass)
        end)
        if Ok and IsValidObject(Subsystem) then
            LivesCommonInputSubsystem = Subsystem
            Log("LIVES CommonInput: cached P1 subsystem via PlayerController route")
            return Subsystem
        end
    end

    Log("LIVES CommonInput: P1 subsystem unavailable; using combined input hint fallback")
    return nil
end

function LivesReadCurrentInputKind()
    local Subsystem = LivesResolveCommonInputSubsystem()
    if not IsValidObject(Subsystem) then return "unknown" end

    local Value = nil
    local Ok = pcall(function() Value = Subsystem:GetCurrentInputType() end)
    if not Ok then
        pcall(function() Value = Subsystem.CurrentInputType end)
    end
    if Value == nil then return "unknown" end

    local Raw = Value
    pcall(function() Raw = Value:get() end)
    local Number = tonumber(Raw)
    local Text = string.lower(tostring(Raw or Value or ""))

    -- ECommonInputType: MouseAndKeyboard=0, Gamepad=1, Touch=2.
    if Number == 1 or string.find(Text, "gamepad", 1, true) then
        return "gamepad"
    end
    if Number == 0 or string.find(Text, "keyboard", 1, true)
        or string.find(Text, "mouse", 1, true) then
        return "keyboard"
    end
    return "unknown"
end

function LivesSetupInputHintText(Kind)
    local Prefix = "LIMITED RESPAWNS: OFF / 5 / 10 / 20 / 30\n"
    if Kind == "gamepad" then
        return Prefix .. "RB + UP TO CHANGE"
    end
    if Kind == "keyboard" then
        return Prefix .. "CTRL + UP TO CHANGE"
    end
    -- Safe fallback if CommonInput is unavailable on a particular build.
    return Prefix .. "RB + UP / CTRL+UP TO CHANGE"
end

function LivesShowSetupInputHint(Reason)
    local Kind = LivesReadCurrentInputKind()
    LivesInputHintKind = Kind
    LivesInputHintRefreshAccumulator = 0.0
    DisplayLivesBanner(LivesSetupInputHintText(Kind))
    Log("LIVES CommonInput hint: mode=%s source=%s", tostring(Kind), tostring(Reason or "show"))
end

function LivesRefreshSetupInputHint(Delta)
    if SetupIntroPhase ~= 3 or not PromptShown then return end
    LivesInputHintRefreshAccumulator = LivesInputHintRefreshAccumulator + Delta
    if LivesInputHintRefreshAccumulator < LivesInputHintRefreshInterval then return end
    LivesInputHintRefreshAccumulator = 0.0

    local Kind = LivesReadCurrentInputKind()
    if Kind == "unknown" or Kind == LivesInputHintKind then return end
    LivesInputHintKind = Kind
    DisplayLivesBanner(LivesSetupInputHintText(Kind))
    Log("LIVES CommonInput hint switched -> %s", tostring(Kind))
end

function ResetMissionSelection(Reason)
    LivesMissionGeneration = LivesMissionGeneration + 1
    MissionCountdownToken = MissionCountdownToken + 1
    SetupIntroPhase = 0
    SetupIntroRemaining = 0.0
    CountdownPhase = 0
    CountdownRemaining = 0.0
    CountdownDigit = 0
    GameOverRestartRemaining = 0.0
    RestartRearmRemaining = 0.0
    SetupActive = false
    SelectionLocked = false
    PromptShown = false
    LivesCommonInputSubsystem = nil
    LivesCommonInputResolveAttempted = false
    LivesInputHintKind = "unknown"
    LivesInputHintRefreshAccumulator = 0.0
    SelectionTouched = false
    MissionReady = false
    HudReadyTicks = 0
    LivesOptionIndex = 1
    StartingExtraLives = 0
    SimulatedLives = 0
    MissionLivesEnabled = false
    GameOverPending = false
    CancelReinforcementTimer("mission selection reset")
    LivesVoiceResetRuntime("mission selection reset")
    Log("Limited Respawns reset: %s; default=OFF generation=%d",
        tostring(Reason or "state change"), LivesMissionGeneration)
end

function ScheduleSetupHint()
    SetupIntroGenerationToken = SetupIntroGenerationToken + 1
    SetupIntroActiveToken = SetupIntroGenerationToken
    SetupIntroGeneration = LivesMissionGeneration
    SetupIntroPhase = 1
    SetupIntroRemaining = SetupOffReaffirmDelayMs / 1000.0
    Log("Limited Respawns setup hint scheduled: OFF reaffirm %.1fs, hint %.1fs later for %.1fs",
        SetupIntroRemaining, SetupHintAfterOffDelayMs / 1000.0,
        LimitedRespawnsHintVisibleMs / 1000.0)
end

function CurrentSelectionText()
    if StartingExtraLives <= 0 then
        return "RESPAWN LIMIT: OFF"
    end
    return string.format("RESPAWN LIMIT: %d", StartingExtraLives)
end

function MissionCountdownCallbackValid(Token, MissionGeneration)
    return not ModTeardownGuard and
        Token == MissionCountdownToken and
        MissionGeneration == LivesMissionGeneration and
        MissionReady and SetupActive and
        not SelectionLocked and SelectionTouched
end

function ScheduleMissionStartCountdown()
    MissionCountdownToken = MissionCountdownToken + 1
    CountdownToken = MissionCountdownToken
    CountdownGeneration = LivesMissionGeneration
    CountdownPhase = 1
    CountdownRemaining = IdleBeforeCountdownSeconds
    CountdownDigit = CountdownSeconds
    SetupIntroPhase = 0
    SetupIntroRemaining = 0.0

    Log("LIVES mission-start countdown armed choice=%s idle=%.1fs header=%.1fs digits=%ds via ReceiveTick DeltaSeconds",
        CurrentSelectionText(), IdleBeforeCountdownSeconds,
        CountdownHeaderMs / 1000.0, CountdownSeconds)
end

function CycleMissionLives()
    if LivesNetworkClientBlocked or not LivesAuthorityAllowed then
        ShowLimitedRespawnsHostOnlyNotice("P1 selector")
        return
    end
    if not SetupActive or SelectionLocked then return end
    SelectionTouched = true
    LivesOptionIndex = (LivesOptionIndex % #LivesOptions) + 1
    StartingExtraLives = LivesOptions[LivesOptionIndex]
    -- Use the DeltaSeconds already supplied by ReceiveTick. No engine-time
    -- query and no delayed callback is allocated for the countdown.
    DisplayLivesBanner(CurrentSelectionText())
    ScheduleMissionStartCountdown()
    Log("LIVES P1 RB+DPAD_UP selection -> %s index=%d; countdown reset",
        CurrentSelectionText(), LivesOptionIndex)
end

function LockMissionSelection()
    if LivesNetworkClientBlocked or not LivesAuthorityAllowed then
        DisableLimitedRespawnsForNetworkClient("selection lock blocked on network client", true)
        return
    end
    if SelectionLocked then return end
    SelectionLocked = true
    SetupActive = false
    SimulatedLives = StartingExtraLives
    -- Limited Respawns is valid in both solo and local co-op. P1 is the
    -- authoritative timer/input owner; P2 is optional.
    MissionLivesEnabled = StartingExtraLives > 0 and IsValidObject(PlayerControllerTable[1])

    if MissionLivesEnabled then
        DisplayLivesBanner(string.format("RESPAWN LIMIT: %d", SimulatedLives))
        Log("LIVES selection LOCKED: RESPAWN_LIMIT=%d", SimulatedLives)
    else
        DisplayLivesBanner("RESPAWN LIMIT: OFF")
        Log("LIVES selection LOCKED: RESPAWN_LIMIT=OFF")
    end
    LivesNetworkBroadcastSnapshot("selection locked")
    if MissionLivesEnabled then
        LivesVoiceAnnounceLives(SimulatedLives, true)
    end
end

function AnyRespawnTimerActive()
    return SetupIntroPhase ~= 0 or CountdownPhase ~= 0 or
        ReinforcementActive or GameOverRestartRemaining > 0.0 or
        RestartRearmRemaining > 0.0 or LivesVoicePhase ~= 0 or #LivesVoiceQueue > 0 or
        LivesVoicePendingDeathLives ~= nil or LivesVoiceToggleBannerRemaining > 0.0
end

function GetTickParamValue(Value)
    return Value:get()
end

function ReadDeltaSeconds(RawDelta)
    local Delta = nil
    if type(RawDelta) == "number" then
        Delta = RawDelta
    elseif RawDelta ~= nil then
        local GetOk, Unwrapped = pcall(GetTickParamValue, RawDelta)
        if GetOk and Unwrapped ~= nil then
            Delta = tonumber(Unwrapped)
        else
            Delta = tonumber(RawDelta)
        end
    end
    if type(Delta) ~= "number" or Delta <= 0 or Delta > 0.25 then
        Delta = 1.0 / 60.0
    end
    return Delta
end

function RespawnTimerTick(Delta)
    if ModTeardownGuard then return end

    LivesVoiceTick(Delta)

    -- Setup intro: OFF -> OFF reaffirm -> input hint.
    if SetupIntroPhase ~= 0 then
        if SetupIntroGeneration ~= LivesMissionGeneration or
           SetupIntroActiveToken ~= SetupIntroGenerationToken or
           not MissionReady or not SetupActive or SelectionLocked or
           SelectionTouched then
            SetupIntroPhase = 0
            SetupIntroRemaining = 0.0
        else
            if SetupIntroPhase == 3 then
                LivesRefreshSetupInputHint(Delta)
            end
            SetupIntroRemaining = SetupIntroRemaining - Delta
            if SetupIntroRemaining <= 0.0 then
                if SetupIntroPhase == 1 then
                    DisplayLivesBanner("RESPAWN LIMIT: OFF")
                    Log("Limited Respawns: OFF reaffirmed before input hint")
                    SetupIntroPhase = 2
                    SetupIntroRemaining = SetupHintAfterOffDelayMs / 1000.0
                elseif SetupIntroPhase == 2 then
                    PromptShown = true
                    SetupIntroPhase = 3
                    LivesShowSetupInputHint("startup setup hint")
                    Log("Limited Respawns: setup input hint shown temporarily")
                    SetupIntroRemaining = LimitedRespawnsHintVisibleMs / 1000.0
                else
                    DisplayLivesBanner("RESPAWN LIMIT: OFF")
                    Log("Limited Respawns: setup returned to persistent RESPAWN LIMIT: OFF")
                    SetupIntroPhase = 0
                    SetupIntroRemaining = 0.0
                end
            end
        end
    end

    -- Mission-start countdown: 3s idle -> START IN -> 5/4/3/2/1 -> lock.
    if CountdownPhase ~= 0 then
        if not MissionCountdownCallbackValid(CountdownToken, CountdownGeneration) then
            CountdownPhase = 0
            CountdownRemaining = 0.0
        else
            CountdownRemaining = CountdownRemaining - Delta
            if CountdownRemaining <= 0.0 then
                if CountdownPhase == 1 then
                    DisplayLivesBanner("START IN")
                    Log("LIVES mission-start countdown HEADER")
                    CountdownPhase = 2
                    CountdownRemaining = CountdownHeaderMs / 1000.0
                elseif CountdownPhase == 2 then
                    CountdownDigit = CountdownSeconds
                    DisplayLivesBanner(tostring(CountdownDigit))
                    Log("LIVES mission-start countdown %d", CountdownDigit)
                    CountdownPhase = 3
                    CountdownRemaining = 1.0
                elseif CountdownDigit > 1 then
                    CountdownDigit = CountdownDigit - 1
                    DisplayLivesBanner(tostring(CountdownDigit))
                    Log("LIVES mission-start countdown %d", CountdownDigit)
                    CountdownRemaining = 1.0
                else
                    CountdownPhase = 0
                    CountdownRemaining = 0.0
                    Log("LIVES mission-start countdown COMPLETE choice=%s",
                        CurrentSelectionText())
                    LockMissionSelection()
                end
            end
        end
    end

    -- Reinforcement: pure DeltaSeconds arithmetic; HUD updates only every 10s.
    if ReinforcementActive then
        if ReinforcementGeneration ~= LivesMissionGeneration or
           SimulatedLives ~= 0 or not MissionLivesEnabled or GameOverPending then
            CancelReinforcementTimer("reinforcement state changed")
        else
            ReinforcementRemaining = ReinforcementRemaining - Delta
            if ReinforcementRemaining <= 0.0 then
                ReinforcementActive = false
                ReinforcementRemaining = 0.0
                ReinforcementNextShown = 0
                SimulatedLives = 1
                DisplayLivesBanner("LIVES: 1")
                LivesNetworkBroadcastState("L", 1, "reinforcement granted")
                LivesVoiceQueueAnnouncement("One reinforcement available.", "reinforcement granted")
                Log("LIVES reinforcement granted; pool capped at 1")
            else
                local VoiceSecond = math.max(1, math.ceil(ReinforcementRemaining))
                if VoiceSecond <= 5 and ReinforcementVoiceLastSecond ~= 5 then
                    ReinforcementVoiceLastSecond = 5
                    LivesVoiceQueueAnnouncement("Reinforcements in five seconds.", "reinforcement final warning")
                end
                if ReinforcementNextShown > 0 and
                   ReinforcementRemaining <= ReinforcementNextShown then
                    ShowCountdown(ReinforcementNextShown)
                    ReinforcementNextShown = ReinforcementNextShown - ReinforcementUpdateSeconds
                end
            end
        end
    end

    -- Game-over restart delay and post-RestartLevel rearm also avoid the fragile
    -- delayed-callback registry. Each path executes once when its timer expires.
    if GameOverRestartRemaining > 0.0 then
        GameOverRestartRemaining = GameOverRestartRemaining - Delta
        if GameOverRestartRemaining <= 0.0 then
            GameOverRestartRemaining = 0.0
            DispatchGameOverRestart()
        end
    end

    if RestartRearmRemaining > 0.0 then
        RestartRearmRemaining = RestartRearmRemaining - Delta
        if RestartRearmRemaining <= 0.0 then
            RestartRearmRemaining = 0.0
            ExecuteRestartRearm(RestartRearmArmedToken)
        end
    end
end

function CampaignMapKey(Name)
    local Lower = string.lower(tostring(Name or ""))
    local GameName, MissionName = string.match(Lower,
        "/game/levels/([^/]+)/solo/([^/]+)/")
    if GameName and MissionName then
        return tostring(GameName) .. "/" .. tostring(MissionName)
    end
    return ""
end

function CurrentCampaignWorldMapKey()
    local WorldName = ""
    pcall(function()
        local World = UEHelpers.GetWorldContextObject()
        if IsValidObject(World) then
            WorldName = SafeFullName(World) or SafeToString(World) or ""
        end
    end)
    return CampaignMapKey(WorldName), WorldName
end


function HandleCampaignWorldKeyEvent(NewMapKey, Source)
    NewMapKey = tostring(NewMapKey or "")
    if NewMapKey == "" then return false end

    if CurrentCampaignMapKey == "" then
        CurrentCampaignMapKey = NewMapKey
        return true
    end
    if NewMapKey == CurrentCampaignMapKey then return true end

    local PreviousMapKey = CurrentCampaignMapKey
    local Reason = string.format("campaign world boundary %s -> %s via %s",
        tostring(PreviousMapKey), tostring(NewMapKey), tostring(Source or "GameState construction"))
    if ResetWarthogColorState ~= nil then
        pcall(function() ResetWarthogColorState(Reason) end)
    end
    if ResetScorpionColorState ~= nil then
        pcall(function() ResetScorpionColorState(Reason) end)
    end
    ResetMissionSelection(Reason)
    MissionCandidateName = ""
    MissionCandidateTicks = 0
    HudReadyTicks = 0
    LastDeathByPlayer = {}
    CurrentCampaignMapKey = NewMapKey
    ClearPendingTravel()
    ClearBannerCache("fresh campaign world boundary")
    Log("LIVES event-driven campaign world boundary old=%s new=%s; setup reset to OFF source=%s",
        tostring(PreviousMapKey), tostring(NewMapKey), tostring(Source or "GameState construction"))
    return true
end

function ObserveCampaignGameStateConstruction(GameState)
    local Name = ""
    pcall(function() Name = SafeFullName(GameState) or "" end)
    local NewMapKey = CampaignMapKey(Name)
    if NewMapKey == "" then return end
    HandleCampaignWorldKeyEvent(NewMapKey, "BP_MeteoriteGameState construction")
end

function RegisterCampaignGameStateListener()
    if CampaignGameStateListenerReady then return true end
    local Ok, Err = pcall(function()
        NotifyOnNewObject(
            "/Game/Blueprints/BP_MeteoriteGameState.BP_MeteoriteGameState_C",
            function(GameState)
                local EventOk, EventErr = pcall(ObserveCampaignGameStateConstruction, GameState)
                if not EventOk then
                    Log("LIVES campaign GameState event error: %s", tostring(EventErr))
                end
            end
        )
    end)
    if Ok then
        CampaignGameStateListenerReady = true
        Log("LIVES campaign GameState construction listener ready; no periodic world-name sampling")
        return true
    end
    Log("LIVES campaign GameState construction listener unavailable: %s", tostring(Err))
    return false
end

function ObserveConstructedLocalP1ForLives(Controller)
    if not MissionReady or not IsValidObject(Controller) then return false end

    local IsLocal = nil
    local ControllerId = nil
    pcall(function() IsLocal = Controller:IsLocalController() == true end)
    pcall(function()
        if IsValidObject(Controller.Player) then ControllerId = Controller.Player.ControllerId end
    end)
    if IsLocal ~= true or ControllerId ~= 0 then return false end

    local Name = SafeFullName(Controller) or ""
    if Name == "" or Name == LivesMissionControllerName then return false end
    local MapKey = CampaignMapKey(Name)
    if MapKey == "" or CurrentCampaignMapKey == "" or MapKey ~= CurrentCampaignMapKey then return false end

    LivesMissionControllerName = Name
    MissionControllerObject = Controller
    MissionCandidateName = Name
    MissionCandidateTicks = MissionStableTicksRequired
    HudReadyTicks = HudReadyTicksRequired
    LastDeathByPlayer = {}
    ResolveLimitedRespawnsAuthority(Controller, "same-map controller construction event")
    LivesVoiceRestoreStatusBanner()
    Log("LIVES same-map local P1 construction PRESERVED map=%s lives=%d enabled=%s locked=%s reinforcement=%s",
        tostring(MapKey), SimulatedLives, tostring(MissionLivesEnabled),
        tostring(SelectionLocked), tostring(ReinforcementActive))
    return true
end

function ClearPendingTravel()
    TravelPending = false
    TravelSourceMapKey = ""
    TravelSourceGeneration = -1
    TravelWasSetupActive = false
    TravelWasSelectionTouched = false
end

function ResolvePostTravelCampaign(Name, Attempt, Source)
    local WorldMapKey = CurrentCampaignWorldMapKey()
    local NewMapKey = WorldMapKey ~= "" and WorldMapKey or CampaignMapKey(Name)
    local GenerationUnchanged = TravelSourceGeneration == LivesMissionGeneration
    local SameCampaignMap = TravelPending and GenerationUnchanged and
        TravelSourceMapKey ~= "" and NewMapKey ~= "" and
        TravelSourceMapKey == NewMapKey

    LivesMissionControllerName = Name
    MissionControllerObject = IsValidObject(PlayerControllerTable[1]) and PlayerControllerTable[1] or nil
    MissionCandidateName = Name
    MissionCandidateTicks = MissionStableTicksRequired
    HudReadyTicks = HudReadyTicksRequired
    LastDeathByPlayer = {}
    MissionReady = true

    local AuthorityAllowed = ResolveLimitedRespawnsAuthority(MissionControllerObject,
        "post-travel campaign resolution")
    if not AuthorityAllowed then
        -- On a fresh map still perform the non-lives vehicle-state boundary reset,
        -- then bind the new controller back as a ready gameplay mission.
        if not SameCampaignMap then
            local Reason = string.format("campaign boundary %s -> %s via %s",
                tostring(TravelSourceMapKey), tostring(NewMapKey),
                tostring(Source or "recovery"))
            if ResetWarthogColorState ~= nil then
                pcall(function() ResetWarthogColorState(Reason) end)
            end
            if ResetScorpionColorState ~= nil then
                pcall(function() ResetScorpionColorState(Reason) end)
            end
            ResetMissionSelection(Reason)
            LivesMissionControllerName = Name
            MissionControllerObject = IsValidObject(PlayerControllerTable[1]) and PlayerControllerTable[1] or nil
            MissionCandidateName = Name
            MissionCandidateTicks = MissionStableTicksRequired
            HudReadyTicks = HudReadyTicksRequired
            MissionReady = true
            CurrentCampaignMapKey = NewMapKey
        end
        DisableLimitedRespawnsForNetworkClient("post-travel campaign resolution", true)
        TravelRecoveryRecoveredToken = TravelRecoveryToken
        ClearPendingTravel()
        return true
    end

    if SameCampaignMap then
        -- Internal seamless travel inside the same mission: keep the selected
        -- limit, remaining lives, reinforcement timer and locked/open state.
        -- Only the controller/HUD identity is rebound.
        CurrentCampaignMapKey = NewMapKey
        if SelectionLocked then
            SetupActive = false
            if MissionLivesEnabled then
                DisplayLivesBanner(string.format("LIVES: %d", SimulatedLives))
            elseif StartingExtraLives <= 0 then
                DisplayLivesBanner("RESPAWN LIMIT: OFF")
            end
        else
            -- If the state is unlocked when the same mission returns, the
            -- selector should be available again. This also covers a RestartLevel
            -- reset that happened just before the seamless-travel controller appeared.
            SetupActive = true
            if SetupActive then
                PromptShown = false
                DisplayLivesBanner(CurrentSelectionText())
                if SelectionTouched or TravelWasSelectionTouched then
                    SelectionTouched = true
                    ScheduleMissionStartCountdown()
                else
                    ScheduleSetupHint()
                end
            end
        end
        Log("LIVES same-mission seamless travel PRESERVED map=%s lives=%d enabled=%s locked=%s setup=%s source=%s attempt=%d",
            tostring(NewMapKey), SimulatedLives, tostring(MissionLivesEnabled),
            tostring(SelectionLocked), tostring(SetupActive),
            tostring(Source or "recovery"), tonumber(Attempt) or 0)
    else
        -- A different campaign map, or an authoritative reset that changed the
        -- mission generation while travel was in progress, is a real fresh
        -- mission boundary. Start the selector again at OFF.
        local Reason = string.format("campaign boundary %s -> %s via %s",
            tostring(TravelSourceMapKey), tostring(NewMapKey),
            tostring(Source or "recovery"))
        if ResetWarthogColorState ~= nil then
            pcall(function() ResetWarthogColorState(Reason) end)
        end
        if ResetScorpionColorState ~= nil then
            pcall(function() ResetScorpionColorState(Reason) end)
        end
        ResetMissionSelection(Reason)
        LivesMissionControllerName = Name
        MissionControllerObject = IsValidObject(PlayerControllerTable[1]) and PlayerControllerTable[1] or nil
        MissionCandidateName = Name
        MissionCandidateTicks = MissionStableTicksRequired
        HudReadyTicks = HudReadyTicksRequired
        MissionReady = true
        SetupActive = true
        SelectionLocked = false
        SelectionTouched = false
        StartingExtraLives = 0
        SimulatedLives = 0
        MissionLivesEnabled = false
        CurrentCampaignMapKey = NewMapKey
        Log("LIVESHUD fresh-map banner candidates P1=%d P2=%d map=%s",
            #(BannerCandidates[0] or {}), #(BannerCandidates[1] or {}),
            tostring(NewMapKey))
        DisplayLivesBanner("RESPAWN LIMIT: OFF")
        ScheduleSetupHint()
        Log("LIVES fresh campaign setup OPENED map=%s sourceMap=%s source=%s attempt=%d",
            tostring(NewMapKey), tostring(TravelSourceMapKey),
            tostring(Source or "recovery"), tonumber(Attempt) or 0)
    end

    TravelRecoveryRecoveredToken = TravelRecoveryToken
    ClearPendingTravel()
    return true
end

function SchedulePostTravelRecovery()
    TravelRecoveryToken = TravelRecoveryToken + 1
    TravelRecoveryRecoveredToken = -1
    -- Do not allocate delayed recovery callbacks. The existing ReceiveTick
    -- stable-controller/HUD gate already resolves same-map vs new-map travel.
    Log("LIVES post-travel recovery delegated to normal ReceiveTick stable HUD gate; token=%d",
        TravelRecoveryToken)
end

function MissionTick(ControllerId, Controller, SharedControllerName, SharedFullscreenBlocked)
    if ControllerId ~= 0 then return end
    -- Vehicle networking has no periodic ReceiveTick work. Once the stable mission
    -- gate has resolved host authority, prime the remote-controller cache exactly once.
    if MissionReady and LivesAuthorityResolved and LivesAuthorityAllowed and
       not VehicleMessageCapabilityMissionPrimed then
        VehicleMessageCapabilityPrimeMission()
    end

    -- Steady-state mission lifecycle is now event-driven. v1.10.0 sampled the
    -- UWorld/controller path every 30 P1 ReceiveTicks to catch seamless campaign
    -- changes. That reflective cadence is a strong suspect for the recurring hitch
    -- reported on a network split-screen client. BP_MeteoriteGameState construction
    -- now owns real campaign-map boundaries, frontend UI signals own session exit,
    -- and local P1 construction owns same-map controller replacement. A settled
    -- mission therefore has zero world/path reflection here.
    if MissionReady and LivesMissionControllerName ~= "" then
        return
    end

    local Name = SharedControllerName or SafeFullName(Controller) or ""
    local LowerName = string.lower(Name)

    -- SeamlessTravelTEst is ambiguous. It is used for real mission changes
    -- and also for internal same-mission streaming. Defer the destructive reset
    -- until the next real campaign controller tells us whether the map changed.
    -- Frontend travel remains an immediate hard reset.
    local InSeamlessTravel = string.find(LowerName, "/game/levels/test/seamlesstraveltest", 1, true) ~= nil
    local InFrontend = string.find(LowerName, "/game/levels/ui/frontend/", 1, true) ~= nil
    if InSeamlessTravel or InFrontend then
        -- SeamlessTravelTEst commonly appears immediately before Frontend.
        -- TravelResetActive is therefore already true when the frontend
        -- controller arrives. Frontend must still win and hard-reset the session
        -- exactly once; otherwise a new game on the same map is misclassified as
        -- an internal same-mission travel and restores the old locked lives.
        local HandleBoundary = not TravelResetActive
        if InFrontend and not FrontendBoundarySeen then
            HandleBoundary = true
        end
        if HandleBoundary then
            TravelResetActive = true
            local HadMissionState = MissionReady or SetupActive or SelectionLocked or
                MissionLivesEnabled or GameOverPending or LivesMissionControllerName ~= "" or
                TravelPending or CurrentCampaignMapKey ~= ""
            if HadMissionState then
                if InSeamlessTravel then
                    TravelPending = true
                    TravelSourceMapKey = CurrentCampaignMapKey
                    if TravelSourceMapKey == "" then
                        TravelSourceMapKey = CampaignMapKey(LivesMissionControllerName)
                    end
                    TravelSourceGeneration = LivesMissionGeneration
                    TravelWasSetupActive = SetupActive
                    TravelWasSelectionTouched = SelectionTouched

                    -- Freeze only mission-start presentation/input while the test
                    -- controller is active. Do not touch lives/reinforcement state.
                    MissionCountdownToken = MissionCountdownToken + 1
                    SetupIntroGenerationToken = SetupIntroGenerationToken + 1
                    MissionReady = false
                    SetupActive = false
                    LivesMissionControllerName = ""
                    MissionControllerObject = nil
                    LastDeathByPlayer = {}
                    if InvalidateWarthogColorRuntime ~= nil then
                        pcall(function() InvalidateWarthogColorRuntime("seamless travel boundary", true) end)
                    end
                    if InvalidateScorpionColorRuntime ~= nil then
                        pcall(function() InvalidateScorpionColorRuntime("seamless travel boundary", true) end)
                    end
                    DisplayLivesBanner(" ")
                    ClearBannerCache("travel boundary")
                    SchedulePostTravelRecovery()
                    Log("LIVES seamless travel DEFERRED sourceMap=%s generation=%d lives=%d enabled=%s locked=%s setupWas=%s",
                        tostring(TravelSourceMapKey), TravelSourceGeneration,
                        SimulatedLives, tostring(MissionLivesEnabled),
                        tostring(SelectionLocked), tostring(TravelWasSetupActive))
                else
                    FrontendBoundarySeen = true
                    ResetMissionSelection("frontend session boundary: " .. tostring(Name))
                    if ResetWarthogColorState ~= nil then
                        pcall(function() ResetWarthogColorState("frontend controller boundary: " .. tostring(Name)) end)
                    end
                    if ResetScorpionColorState ~= nil then
                        pcall(function() ResetScorpionColorState("frontend controller boundary: " .. tostring(Name)) end)
                    end
                    LivesMissionControllerName = ""
                    MissionControllerObject = nil
                    LastDeathByPlayer = {}
                    DisplayLivesBanner(" ")
                    ClearBannerCache("travel boundary")
                    TravelRecoveryToken = TravelRecoveryToken + 1
                    CurrentCampaignMapKey = ""
                    ClearPendingTravel()
                    Log("LIVES frontend session boundary RESET; next campaign setup defaults to OFF even if the same map is started again")
                end
            end
        end
        MissionCandidateName = ""
        MissionCandidateTicks = 0
        HudReadyTicks = 0
        return
    end
    TravelResetActive = false

    -- Campaign pawns/HUD widgets can exist before an intro cinematic has
    -- finished. Keep Limited Respawns and its banner completely out of that
    -- fullscreen presentation; the normal stability gate restarts afterward.
    local FullscreenBlocked = SharedFullscreenBlocked
    if FullscreenBlocked == nil then
        FullscreenBlocked = CinematicActive == true
        if not FullscreenBlocked and not MissionReady and IsSplitForceDisabled ~= nil then
            FullscreenBlocked = IsSplitForceDisabled()
        end
    end
    if FullscreenBlocked then
        MissionCandidateName = ""
        MissionCandidateTicks = 0
        HudReadyTicks = 0
        return
    end

    -- Once this exact mission controller has passed the bounded HUD
    -- gate, the lives setup has no per-frame work. Return before pawn reflection,
    -- map-key parsing and banner checks. A travel/menu controller changes Name and
    -- therefore immediately falls through to the full lifecycle path.
    if MissionReady and Name == LivesMissionControllerName then
        return
    end

    -- A real campaign controller means we have left Frontend. Re-arm the
    -- one-shot detector for the next time the player returns to the menu.
    if CampaignMapKey(Name) ~= "" then
        FrontendBoundarySeen = false
    end

    local Pawn = nil
    pcall(function() Pawn = Controller.Pawn end)
    if not IsValidObject(Pawn) or
       not string.find(SafeFullName(Pawn) or "", "BP_MeteoritePawn_C", 1, true) then
        MissionCandidateName = ""
        MissionCandidateTicks = 0
        HudReadyTicks = 0
        return
    end

    -- Require the same live mission controller/pawn to survive several seconds
    -- before touching lives state. No banner calls happen during map construction.
    if Name ~= MissionCandidateName then
        MissionCandidateName = Name
        MissionCandidateTicks = 0
        HudReadyTicks = 0
        return
    end
    MissionCandidateTicks = MissionCandidateTicks + 1
    if MissionCandidateTicks < MissionStableTicksRequired then return end

    -- HUD readiness is still proven repeatedly, but global banner
    -- discovery is sampled once per 10 ticks instead of once per frame.
    if (MissionCandidateTicks % 10) ~= 0 then return end
    if not MissionHudReady() then
        HudReadyTicks = 0
        return
    end
    HudReadyTicks = HudReadyTicks + 1
    if HudReadyTicks < HudReadyTicksRequired then return end

    if Name ~= LivesMissionControllerName then
        -- If a real campaign controller became stable before the delayed
        -- recovery fired, resolve the same-vs-new mission classification here.
        if TravelPending then
            ResolvePostTravelCampaign(Name, 0, "normal stable HUD gate")
            return
        end

        local PreviousMapKey = CurrentCampaignMapKey
        local StableWorldMapKey = CurrentCampaignWorldMapKey()
        local NewMapKey = StableWorldMapKey ~= "" and StableWorldMapKey or CampaignMapKey(Name)
        local SameKnownMap = PreviousMapKey ~= "" and NewMapKey ~= "" and PreviousMapKey == NewMapKey
        local PreserveSameMapState = SameKnownMap and MissionReady

        LivesMissionControllerName = Name
        MissionControllerObject = Controller
        LastDeathByPlayer = {}
        CurrentCampaignMapKey = NewMapKey

        if PreserveSameMapState then
            -- A live campaign PlayerController can be reconstructed/replaced while
            -- the UWorld remains the same mission. Controller identity alone must
            -- never turn an active Limited Respawns run back to OFF. Rebind the
            -- controller and preserve the locked selector, current lives, game-over
            -- state and reinforcement timer exactly as they were.
            MissionCandidateName = Name
            MissionCandidateTicks = MissionStableTicksRequired
            HudReadyTicks = HudReadyTicksRequired
            ResolveLimitedRespawnsAuthority(Controller, "same-map controller replacement")
            -- Reuse the normal status renderer so reinforcement stays on its
            -- ten-second presentation cadence and setup/locked wording stays
            -- identical to the rest of the feature.
            LivesVoiceRestoreStatusBanner()
            Log("LIVES same-map controller replacement PRESERVED map=%s lives=%d enabled=%s locked=%s reinforcement=%s",
                tostring(NewMapKey), SimulatedLives, tostring(MissionLivesEnabled),
                tostring(SelectionLocked), tostring(ReinforcementActive))
        else
            ResetMissionSelection("stable mission HUD/controller: " .. tostring(Name))
        end
    end

    if not MissionReady then
        local HasSecondLocalPlayer = IsValidObject(PlayerControllerTable[2])
        local AuthorityAllowed = ResolveLimitedRespawnsAuthority(Controller, "stable mission HUD/controller")
        if AuthorityAllowed and VehicleMessageCapabilityMissionPrimed then
            local CurrentPrefix = string.match(Name or "", "^(.-:PersistentLevel)") or ""
            local CacheMatchesCurrentWorld = false
            for _, CachedController in ipairs(VehicleMessageCachedRemoteControllerCandidates()) do
                local CachedName = SafeFullName(CachedController) or ""
                if CurrentPrefix ~= "" and string.find(CachedName, CurrentPrefix, 1, true) ~= nil then
                    CacheMatchesCurrentWorld = true
                    break
                end
            end
            if not CacheMatchesCurrentWorld then
                VehicleMessageResetCapabilityState("stable authority mission detected stale prior-world cache")
            end
        end
        MissionReady = true
        if ArmorSkinSchedulePlayerMIDPrewarm ~= nil then
            ArmorSkinSchedulePlayerMIDPrewarm("stable mission HUD/controller")
        end
        SelectionTouched = false
        StartingExtraLives = 0
        SimulatedLives = 0
        MissionLivesEnabled = false

        if HasSecondLocalPlayer and TrimName(P2SpartanSessionName)~="" then
            P2NameRepairActive=true
            P2NameRepairTicks=0
            P2NameRepairAttempts=0
            SchedulePlayerTwoNameRepair(1)
        end

        -- RC3_43: hydrate logical remote colors before capability/snapshot traffic
        -- starts in the new world. This keeps same-fireteam mission travel from
        -- briefly reverting remote Spartans to authored green while waiting for
        -- a fresh client uplink.
        if ArmorSkinPersistentRestoreRemoteStates ~= nil then
            ArmorSkinPersistentRestoreRemoteStates("stable mission pre-capability")
        end

        if AuthorityAllowed then
            SetupActive = true
            SelectionLocked = false
            DisplayLivesBanner("RESPAWN LIMIT: OFF")
            ScheduleSetupHint()
            if not VehicleMessageCapabilityMissionPrimed then
                VehicleMessageCapabilityPrimeMission()
            end
            if ArmorSkinScheduleTrackedReapply ~= nil then
                ArmorSkinScheduleTrackedReapply("stable mission HUD/controller")
            end
            Log("LIVES stable mission HUD ready; setup OPEN mode=%s authority=host/standalone default=OFF waitingForFirstInput=true idleDelay=%.1fs header=%.1fs digits=%ds",
                HasSecondLocalPlayer and "local-coop" or "solo",
                IdleBeforeCountdownSeconds, CountdownHeaderMs / 1000.0, CountdownSeconds)
        else
            DisableLimitedRespawnsForNetworkClient("stable mission HUD/controller", true)
            if ArmorSkinScheduleTrackedReapply ~= nil then
                ArmorSkinScheduleTrackedReapply("stable network-client mission HUD/controller")
            end
            Log("LIVES stable mission HUD ready; setup BLOCKED mode=network-client host-P1-only")
        end
    end
end

-- Kept as a named function so pcall does not allocate a fresh closure for every
-- controller ReceiveTick. All guarded behavior is identical to the former body.
function ArmorControllerTickBody(ControllerId, Controller, RawFrameDeltaSeconds, PlayerIndex)
    MissionHudRepairTick(ControllerId, Controller, nil, CinematicActive == true)
    MissionTick(ControllerId, Controller, nil, CinematicActive == true)
    local FrameDeltaSeconds = nil
    local TimersActive = ControllerId == 0 and AnyRespawnTimerActive()
    local OrientationActive = ControllerId == 0 and OrientationNeedsTick()
    if TimersActive or OrientationActive then
        FrameDeltaSeconds = ReadDeltaSeconds(RawFrameDeltaSeconds)
    end
    if TimersActive then
        RespawnTimerTick(FrameDeltaSeconds)
    end
    if OrientationActive then
        OrientationRuntimeTick(FrameDeltaSeconds)
    end
    if ControllerId == 0 then ProcessPendingKeyboardInput() end
    PollPlayerInput(PlayerIndex)
    if ArmorSkinMaintenanceTick ~= nil then ArmorSkinMaintenanceTick(PlayerIndex) end
    if ControllerId == 0 then ProcessPendingApply() end
end

function ArmorControllerTick(Context, ...)
    if ModTeardownGuard or ArmorTickBusy then return end

    local Controller = Unwrap(Context)
    if not IsValidObject(Controller) then return end

    -- PERF: most ReceiveTick calls are from the same two cached controller
    -- objects. Resolve those with Lua identity first; only a new/unknown controller
    -- crosses into reflection for LocalPlayer.ControllerId.
    local ControllerId = nil
    if Controller == PlayerControllerTable[1] then
        ControllerId = 0
    elseif Controller == PlayerControllerTable[2] then
        ControllerId = 1
    else
        pcall(function()
            if IsValidObject(Controller.Player) then ControllerId = Controller.Player.ControllerId end
        end)
    end
    if type(ControllerId) ~= "number" or ControllerId < 0 or ControllerId > 1 then
        local FrontendName = SafeFullName(Controller) or ""
        if string.find(string.lower(FrontendName), "/game/levels/ui/frontend/", 1, true) then
            MissionTick(0, Controller, FrontendName, false)
        end
        return
    end

    local PlayerIndex = ControllerId + 1
    PlayerControllerTable[PlayerIndex] = Controller
    local RawFrameDeltaSeconds = nil
    if ControllerId == 0 then RawFrameDeltaSeconds = select(1, ...) end

    -- No controller-name or GameViewportClient sample is taken here. Lifecycle/HUD paths
    -- resolve those only at actual lifecycle boundaries / the short HUD setup window.
    ArmorTickBusy = true
    local Ok, Err = pcall(ArmorControllerTickBody,
        ControllerId, Controller, RawFrameDeltaSeconds, PlayerIndex)
    ArmorTickBusy = false
    if not Ok then
        Log("ARMOR controller-tick error P%d: %s", PlayerIndex, tostring(Err))
    end
end

function RegisterArmorTickHook(Quiet)
    if ArmorTickHookArmed then return true end
    local Ok, Err = pcall(function()
        RegisterHook(
            "/Game/Blueprints/BP_MeteoritePlayerController.BP_MeteoritePlayerController_C:ReceiveTick",
            function(Context, ...)
                ArmorControllerTick(Context, ...)
            end,
            function(Context, ...) end
        )
    end)
    if Ok then
        ArmorTickHookArmed = true
        Log("ARMOR mission controller ReceiveTick hook ready")
        return true
    end
    if not Quiet then
        Log("ARMOR ReceiveTick hook unavailable; using game-thread fallback until Blueprint is ready: %s", tostring(Err))
    end
    return false
end

function StartGameplaySystems()
    if MainStateWorkerStarted then return end
    MainStateWorkerStarted = true
    RegisterArmorTickHook()
    -- Native cooked Classic12 uses Halo's normal customization/replication path;
    -- the retired biped/MID armor-network presentation listener is not started.
    RegisterClassicArmorMenuActivationHook()
    RegisterClassicArmorMenuListListener()
    RegisterLivesPlayerDeathConstructionListener()
    RegisterLivesHooks()
    RegisterPauseCloseHudHook()
    RegisterCinematicHooks()
    -- Limited Respawns selection is mission-only; the frontend does not run it.
    Log("Limited Respawns ready: standalone/local co-op/network-host P1 only; network clients auto-disable; reinforcement after %ds at zero lives.", ReinforcementDelaySeconds)
    Log("Armor switching ready: authored Owned/entitled models plus integrated default-Spartan skin cycling.")
    RestartJoinStateMachineWorker("startup")
end

LoadInputSettings()
if ConfiguredControllerCount == 1 then
    RouterStartupCallOk, RouterStartupResult = pcall(EnsureAdaptiveSteamInputRouting, "startup before initial frontend", true)
    if not RouterStartupCallOk or RouterStartupResult ~= true then
        Log("INPUT ROUTER startup did not confirm a controller route; arming bounded readiness worker")
        ScheduleAdaptiveInputRouterRetries("startup")
    end
end
LoadPerspectiveNative()
LoadPerspectiveContextShiftBridge()
InstallVehicleMessageClientHook()
InstallVehicleMessageServerHook()
RegisterVehicleMessageControllerConstructionListener()
RegisterCampaignGameStateListener()
ScheduleInputRouting(1, "startup")
StartGameplaySystems()
RegisterStaticFrontendJoinPrompt()
RegisterLoadedHeader()
RegisterControllerHelpListener()

RegisterKeyBind(Key.Y, {ModifierKey.CONTROL}, CreatePlayer)
RegisterKeyBind(Key.U, {ModifierKey.CONTROL}, function() DestroyPlayer("Ctrl+U") end)
RegisterKeyBind(Key.O, {ModifierKey.CONTROL}, function()
    if IsValidObject(GetPlayer(2)) then
        Log("SPLIT keyboard orientation request: Ctrl+O legacy")
        ToggleSplitOrientation("keyboard Ctrl+O")
    else
        Log("SPLIT Ctrl+O ignored: no local P2")
    end
end)
RegisterNativeSplitscreenJoinHook()

-- Keyboard/mouse parity for the public gameplay features. RegisterKeyBind may
-- fire off the game thread, so these callbacks only queue tiny flags. The P1
-- ReceiveTick handler consumes them safely on the game thread.
RegisterKeyBind(Key.LEFT_ARROW, {ModifierKey.CONTROL}, function()
    KeyboardPendingArmorDelta = -1
    Log("ARMOR keyboard shortcut queued: Ctrl+Left")
end)

RegisterKeyBind(Key.RIGHT_ARROW, {ModifierKey.CONTROL}, function()
    KeyboardPendingArmorDelta = 1
    Log("ARMOR keyboard shortcut queued: Ctrl+Right")
end)

-- Classic Spartan color is deliberately independent from vehicle context.
-- It therefore works both on foot and while seated in a vehicle.
RegisterKeyBind(Key.LEFT_ARROW, {ModifierKey.SHIFT}, function()
    KeyboardPendingClassicSkinDelta = (tonumber(KeyboardPendingClassicSkinDelta) or 0) - 1
    Log("CLASSIC keyboard shortcut queued: Shift+Left pending=%d", tonumber(KeyboardPendingClassicSkinDelta) or 0)
end)

RegisterKeyBind(Key.RIGHT_ARROW, {ModifierKey.SHIFT}, function()
    KeyboardPendingClassicSkinDelta = (tonumber(KeyboardPendingClassicSkinDelta) or 0) + 1
    Log("CLASSIC keyboard shortcut queued: Shift+Right pending=%d", tonumber(KeyboardPendingClassicSkinDelta) or 0)
end)

RegisterKeyBind(Key.X, {ModifierKey.CONTROL}, function()
    KeyboardPendingWeaponSkin = true
    KeyboardPendingWeaponSkinLabel = "Ctrl+X"
end)


RegisterKeyBind(Key.UP_ARROW, {ModifierKey.CONTROL}, function()
    KeyboardPendingLives = true
    Log("LIVES keyboard shortcut queued: Ctrl+Up")
end)

RegisterKeyBind(Key.DOWN_ARROW, {ModifierKey.CONTROL}, function()
    KeyboardPendingSplit = true
    Log("SPLIT keyboard shortcut queued: Ctrl+Down")
end)

-- Ctrl+F8 is intentionally used for voice-announcement parity. It is unused by
-- every other Co-op Expanded runtime binding; Ctrl+H remains reserved by UE4SS.
RegisterKeyBind(Key.F8, {ModifierKey.CONTROL}, function()
    KeyboardPendingVoiceToggle = true
    Log("LIVESVOICE keyboard shortcut queued: Ctrl+F8")
end)

RegisterKeyBind(Key.PAGE_UP, {ModifierKey.CONTROL}, function()
    KeyboardPendingVehicleColorDelta = -1
    Log("VEHICLE COLOR keyboard shortcut queued: Ctrl+PageUp")
end)

RegisterKeyBind(Key.PAGE_DOWN, {ModifierKey.CONTROL}, function()
    KeyboardPendingVehicleColorDelta = 1
    Log("VEHICLE COLOR keyboard shortcut queued: Ctrl+PageDown")
end)

RegisterKeyBind(Key.B, {ModifierKey.CONTROL}, function()
    KeyboardPendingPerspective = true
    Log("PERSPECTIVE keyboard shortcut queued: Ctrl+B")
end)

-- Do not consume or replace Halo's normal Escape behavior. In Controllers=1/2
-- we only arm a delayed P1/CommonUI fallback; native P1 activation/deactivation
-- cancels the fallback before it can run. P2 UI churn is deliberately ignored.
RegisterKeyBind(Key.ESCAPE, function()
    if ConfiguredControllerCount == 1 or ConfiguredControllerCount == 2 then
        KeyboardEscapeRequestGeneration = KeyboardEscapeRequestGeneration + 1
        KeyboardEscapeActivityP1AtRequest = KeyboardEscapeUiActivityGenerationP1
        KeyboardEscapePending = true
    end
end)

RegisterKeyboardEscapeRecoveryHooks()

Log("Co-op Expanded v1.11.0 development build loaded.")
Log("Frontend split-screen join/leave ready: A sign-in; hold A on P2 about 2s to leave; Ctrl+Y/Ctrl+U fallbacks.")
Log("Gameplay features ready: split orientation, armor models + default-Spartan skins, Limited Respawns, vanilla-compatible voice announcements, HUD and cinematic fixes.")
Log("Weapon skin switching ready: 7 verified weapon families; Owned/entitled rows only; RB+X or Ctrl+X.")
Log("Color cycling ready: Spartan Classic = X+DPad Left/Right or Shift+Left/Right in any context; vehicle paint = RB+LS/RS or Ctrl+PageUp/PageDown; same Halo CE order.")
Log("Perspective switching ready: RB+B toggles each local player independently; Ctrl+B toggles P1 only.")
Log("Limited Respawns voice announcements ready: default=ON; host P1 RB+Y or Ctrl+F8 toggles broadcast; toggle banner=4.0s; death voice coalesces for 0.50s; modded HUD text remains always enabled.")
Log("Vehicle network sync ready: capability-gated protocol=3, proven ACK/READY uplink route, one-shot mission discovery, no periodic network polling.")
Log("Armor customization sync ready: native cooked rows use Halo's ordinary replication; retired custom ARMORSKIN NET transport is disabled.")
Log("Perspective network-client local split routing ready: Steam uses native 1=P1/2=P2; WinGDK compensates its reversed local camera order in Lua; context 0 stays vanilla.")
Log("UI CONTROLS ready: Controller Settings help covers frontend and per-player pause stacks; construction/activation/nav plus target TextBlock/visibility refresh driven; bounded retries only.")
Log("INPUT ESC recovery ready: Controllers=1/2 use HaloUI OpenWidgetFullscreen fallback after failed native P1 Escape; P2 ownership is preserved and SetCurrentFullscreenPlayer is never called directly.")
Log("INPUT ROUTER ready: Controllers=1 router v0.7.4 validates logical P2 liveness, recovers late Steam Input publication, and keeps WinGDK native Xbox/XInput only.")

-- Map travel rebuilds the player layers and can discard the corrected geometry.
-- Retry once the campaign HUD has had time to construct, then once more for
-- slower machines and streaming transitions. (JoacoL999)
PreLoadHookOk, PreLoadHookErr = pcall(function()
    RegisterLoadMapPreHook(function()
        ModTeardownGuard = true
        ModTravelGeneration = ModTravelGeneration + 1

        -- Never carry a frontend input binding across map travel. The LocalPlayer
        -- may survive while the PlayerController object is replaced. Rebind only
        -- when the real Frontend UI is seen again.
        P2MenuLeaveController = nil
        P2MenuLeaveBindingName = ""
        P2MenuLeaveHoldTicks = 0
        P2MenuLeaveHoldLatched = false

        CreatePlayerInProgress = false
        JoinVerificationActive = false
        JoinVerificationTicks = 0
        XInputSteamRouterJoinWaitActive = false
        XInputSteamRouterJoinWaitTicks = 0
        XInputSteamRouterJoinWaitIntervalTicks = 0
        XInputSteamRouterJoinWaitAttempt = 0
        XInputSteamRouterPostJoinTicks = 0
        XInputSteamRouterPostJoinIntervalTicks = 0
        HudControllerName = ""
        HudRepairTicks = 0
        HudRepairPass = 0
        HudSoloRestored = false
        LastViewportW = nil
        LastViewportH = nil
        HudRelayoutTicks = 0
        HudRelayoutReason = ""
        LivesMissionControllerName = ""
        MissionControllerObject = nil
        ClearBannerCache("map teardown")
        LastDeathByPlayer = {}
        ResetMissionSelection("map teardown")
        TravelRecoveryToken = TravelRecoveryToken + 1
        TravelRecoveryRecoveredToken = -1
        CurrentCampaignMapKey = ""
        ClearPendingTravel()
        FrontendBoundarySeen = false
        -- Hook state is per-world. Never let a stale cinematic=true survive
        -- map teardown; the new world will emit its own cinematic signals.
        CinematicSignals = {}
        if CinematicActive then
            SetShowAllPlayerWidgets(false)
        end
        -- The viewport client survives map travel. If this mod forced split-screen
        -- off, release that ownership before the old world disappears so the next map
        -- cannot inherit a stale fullscreen override.
        if CinematicOverrideOwned then
            pcall(function()
                GetGameplayStatics():SetForceDisableSplitscreen(UEHelpers.GetWorldContextObject(), false)
            end)
        end
        CinematicActive = false
        CinematicOverrideOwned = false
        RestartRearmToken = RestartRearmToken + 1
        MissionLivesEnabled = false
        GameOverPending = false
        LivesAuthorityResolved = false
        LivesAuthorityAllowed = true
        LivesNetworkClientBlocked = false
        LivesAuthorityNoticeShown = false
        CancelReinforcementTimer("map teardown")
        CancelPendingNativeJoin("map teardown")
        if InvalidateWarthogColorRuntime ~= nil then
            pcall(function() InvalidateWarthogColorRuntime("map teardown/checkpoint", true) end)
        end
        if InvalidateScorpionColorRuntime ~= nil then
            pcall(function() InvalidateScorpionColorRuntime("map teardown/checkpoint", true) end)
        end
        ResetInputState("map teardown")
        ResetPerspectiveNative("map teardown")
        IndexInitialized[1] = false
        IndexInitialized[2] = false
        Log("Safe teardown guard enabled before map travel.")
    end)
end)

if not PreLoadHookOk then
    Log("Could not register pre-load teardown guard: %s", tostring(PreLoadHookErr))
end

PostLoadHookOk, PostLoadHookErr = pcall(function()
    RegisterLoadMapPostHook(function()
        CancelPendingNativeJoin("map travel complete")
        if ConfiguredControllerCount == 1 then
            local RouterBoundaryCallOk, RouterBoundaryResult = pcall(EnsureAdaptiveSteamInputRouting, "map load boundary", true)
            if not RouterBoundaryCallOk or RouterBoundaryResult ~= true then
                Log("INPUT ROUTER map-boundary revalidation did not confirm a controller route; arming bounded readiness worker")
                ScheduleAdaptiveInputRouterRetries("map load boundary")
            elseif not UseGamePassPlatformJoin and XInputSteamRouterLastKind == 1 then
                -- Steam can install its XInput relay after the proxy was first seen as
                -- native/original. Keep a bounded worker window alive through frontend
                -- settle so a late Steam Input hook is converted to the virtual shift.
                ScheduleAdaptiveInputRouterRetries("Steam frontend hook settle", true)
            end
        end
        local LoadedGeneration = ModTravelGeneration
        ExecuteInGameThreadWithDelay(2000, function()
                if LoadedGeneration ~= ModTravelGeneration then return end
                ModTeardownGuard = false
                if InvalidateWarthogColorRuntime ~= nil then
                    pcall(function() InvalidateWarthogColorRuntime("map load complete/checkpoint", true) end)
                end
                if InvalidateScorpionColorRuntime ~= nil then
                    pcall(function() InvalidateScorpionColorRuntime("map load complete/checkpoint", true) end)
                end
                ResetInputState("map load complete")
                FrontendPlayerOneFallbackLogged = false
                if RestartJoinStateMachineWorker ~= nil then
                    RestartJoinStateMachineWorker("map load complete")
                end

                -- Refresh controllers ONCE at the lifecycle boundary, never in the hot loop.
                RefreshCachedControllers()

                -- Keep any legacy fallback carrier while travelling into campaign.
                -- Clear it on return to Frontend so a future fallback discovers fresh UI objects.
                local SessionKind = CurrentWorldSessionKind()
                if SessionKind == "frontend" then
                    ClearCarrier("returned to frontend")
                    if ArmorSkinTexturePrewarmComplete ~= true and ArmorSkinTexturePrewarmPass ~= nil then
                        pcall(function() ArmorSkinTexturePrewarmPass("settled frontend lifecycle immediate") end)
                    end
                    if ArmorSkinTexturePrewarmComplete ~= true and ArmorSkinScheduleTexturePrewarm ~= nil then
                        ArmorSkinScheduleTexturePrewarm("settled frontend lifecycle retry")
                    end
                else
                    Log("ARMOR retaining customization carrier across campaign travel")
                end

                -- Do not call Limited Respawns reset/banner logic during map load.
                -- Only invalidate mission identity. The stable mission tick performs the
                -- actual OFF reset after controller + pawn + both HUD banners are settled.
                LivesMissionControllerName = ""
                MissionControllerObject = nil
                HudControllerName = ""
                HudRepairTicks = 0
                HudRepairPass = 0
                HudSoloRestored = false
                        LastViewportW = nil
                LastViewportH = nil
                HudRelayoutTicks = 0
                HudRelayoutReason = ""
                ClearBannerCache("map load complete")
                MissionCandidateName = ""
                MissionCandidateTicks = 0
                HudReadyTicks = 0
                LastDeathByPlayer = {}
                MissionReady = false
                SetupActive = false
                SelectionLocked = false
                MissionLivesEnabled = false
                GameOverPending = false
                LivesAuthorityResolved = false
                LivesAuthorityAllowed = true
                LivesNetworkClientBlocked = false
                LivesAuthorityNoticeShown = false
                CancelReinforcementTimer("map load complete")
                Log("Safe teardown guard released after map load; state worker retained.")
                ScheduleHaloHUDRebuild(250, "post-load stable rebuild")
                -- Campaign travel replaces the frontend pawns. The retired automatic
                -- appearance-copy experiment is intentionally not scheduled.
                -- Armor switching now uses the direct customization data/settings path.

        end)
    end)
end)

if not PostLoadHookOk then
    Log("Could not register post-load HUD rebuilds: %s", tostring(PostLoadHookErr))
end

-- Legacy runtime Classic-overlay experiment removed for v1.11.0.
-- Classic12 now uses native cooked customization rows below.






-- CLASSIC12_NATIVE_GUARD: native cooked customization owns Classic armor.
-- The old vehicle-style Classic armor replication experiment is retired.
-- Disable every remaining runtime overlay/custom-armor-network entry point so
-- only Halo's native cooked customization replication can own armor state.
do
    local disabled = {
        'ArmorSkinApplyToPawn', 'ArmorSkinApplySharedPlayerColor',
        'ArmorSkinApplyColorLegacyToExistingItem', 'ArmorSkinApplyColorToExistingItem',
        'ArmorSkinForceReassertPlayerState', 'ArmorSkinRestoreTarget',
        'ArmorSkinMaintenanceTick', 'ArmorSkinScheduleLocalApply',
        'ArmorSkinScheduleNetworkApply', 'ArmorSkinScheduleTrackedReapply',
        'ArmorSkinSchedulePerspectiveFirstPersonRebind',
        'ArmorSkinScheduleRespawnRemoteIdentityRetry', 'ArmorSkinScheduleRespawnSettledRebind',
        'ArmorSkinScheduleLocalStateReassert', 'ArmorSkinSchedulePlayerMIDPrewarm',
        'ArmorSkinScheduleTexturePrewarm', 'ArmorSkinTexturePrewarmPass',
        'ArmorSkinPrewarmPlayerMIDSet', 'ArmorSkinPrewarmSafeKnownIds',
        'ArmorSkinScheduleRespawnPairVectorRepublish',
        'ArmorSkinNetworkRememberOriginSlot', 'ArmorSkinNetworkOriginSlotForPlayerId'
    }
    for _, key in ipairs(disabled) do
        if type(_G[key]) == 'function' then
            _G[key] = function() return false, 'CLASSIC12_NATIVE_GUARD: legacy overlay disabled' end
        end
    end
    print('[CLASSIC12_NATIVE] legacy overlay disabled; native cooked selection active\n')
end



-- CLASSIC12_NATIVE: cooked variants and persisted frontend initialization.
do
    local definitions = {
        {18,'WHITE','ClassicWhite'}, {1,'BLACK','ClassicBlack'},
        {2,'RED','ClassicRed'}, {3,'BLUE','ClassicBlue'},
        {9,'CYAN','ClassicCyan'}, {11,'ORANGE','ClassicOrange'},
        {4,'GRAY','OriginalCE'}, {5,'YELLOW','Ship_005'},
        {8,'PURPLE','Ship_006'}, {10,'COBALT','Ship_011'},
        {15,'TAN','Ship_007'}, {17,'SALMON','Ship_008'},
    }
    local byIndex, byTag = {}, {}
    local function log(s) print('[CLASSIC12_NATIVE] '..tostring(s)..'\n') end

    -- The early xinput1_4 bootstrap writes this marker only after the matching
    -- cooked native package is active. Lua follows the actual installed mode,
    -- not merely the requested settings.ini value.
    local replaceStock=true
    local modeFile=io.open(GetModFilePath('classic_active_mode.txt'),'r')
    if modeFile then
        replaceStock=modeFile:read('*a'):match('^%s*0%s*$')==nil
        modeFile:close()
    end
    if not replaceStock then
        -- Mode 0 keeps only the six Classic colors with dedicated native tags.
        -- The six shared tags are stock armor again in the Mode0 cooked package.
        for i=#definitions,7,-1 do table.remove(definitions,i) end
    end
    log('ACTIVE ReplaceStockArmorWithClassic='..(replaceStock and '1' or '0'))

    for _, d in ipairs(definitions) do
        local c = {index=d[1], name=d[2], tag='Blam.Customization.MasterChief.'..d[3]}
        byIndex[c.index]=c; byTag[string.lower(c.tag)]=c
    end

    -- Native customization table supplies the 12 rows. Stop legacy duplicate rows/replays.
    ClassicArmorMenuEntryPaths = {}
    ClassicArmorInjectMenuRows = function() return true end
    ClassicArmorInsertRowsBeforePremium = function() return false end
    ClassicArmorSyncMenuSelection = function() return false end
    ClassicArmorReplayExactSelection = function() return false, 'native rows' end
    local oldEntryColor = ClassicArmorMenuColorIndex
    function ClassicArmorMenuColorIndex(entry)
        local skin=''
        pcall(function() skin=GetTagName(Unwrap(entry).SkinGameplayTag) or '' end)
        local c=byTag[string.lower(skin)]
        if c then return c.index,c.name end
        local index,name=oldEntryColor(entry)
        if byIndex[index] then return index,name end
        return nil,nil
    end

    local function applyNative(player,index,source)
        local c=byIndex[tonumber(index)]
        if not c then return true,'not Classic' end
        local settings,why=GetUserSettings(player)
        local controller=GetPlayer(player)
        local statics=GetWeaponSkinNativeStatics()
        if not IsValidObject(settings) then return false,tostring(why) end
        if not IsValidObject(controller) or not IsValidObject(statics) then return false,'native controller not ready' end
        local ok,detail=pcall(function()
            local current=FindMasterChiefSelection(settings)
            local target=MakeGameplayTag(c.tag)
            settings:AddOrReplaceCustomization(Unwrap(current) or target,target)
            settings:ApplyHaloUserSettings()
            statics:SetEquippedObjectSkin(controller,target)
        end)
        local _,after=FindMasterChiefSelection(settings)
        local committed=ok and string.lower(tostring(after))==string.lower(c.tag)
        log('APPLY P'..player..' color='..c.name..' source='..source..' stored='..tostring(after)..' ok='..tostring(committed)..' detail='..tostring(detail))
        return committed,detail
    end

    function ApplyClassicArmorSkin(player,index,source)
        player=tonumber(player) or 1;index=tonumber(index)
        if not byIndex[index] then return false,'removed Classic color' end
        ClassicArmorSetPersistentSelection(player,index,source or 'native Classic selection')
        return applyNative(player,index,source or 'menu')
    end

    -- Keyboard and controller already dispatch here on the game thread.
    -- Replace the old 18-color overlay path with the same native selection as the menu.
    function CycleDefaultSpartanSkin(player,delta,source)
        player=tonumber(player) or 1
        delta=tonumber(delta) or 0
        if delta==0 then return false,'no direction' end
        local order={}
        for _,index in ipairs({1,2,3,4,5,8,9,10,11,15,17,18}) do
            if byIndex[index] then order[#order+1]=index end
        end
        local settings=GetUserSettings(player)
        if not IsValidObject(settings) then return false,'settings not ready' end
        local _,tag=FindMasterChiefSelection(settings)
        local current=byTag[string.lower(tostring(tag or ''))]
        local position=nil
        for i,index in ipairs(order) do
            if current and index==current.index then position=i;break end
        end
        local step=delta<0 and -1 or 1
        local nextPosition=position and ((position-1+step)%#order+1) or (step>0 and 1 or #order)
        return ApplyClassicArmorSkin(player,order[nextPosition],source or 'native Classic cycle')
    end

    -- Ctrl+arrows and RB+D-pad share this catalog selector. Keep native Classic
    -- rows available to the menu, but skip only the Classic rows active in this mode.
    local previousNext=FindNextAvailableCustomizationIndex
    function FindNextAvailableCustomizationIndex(player,catalog,current,delta)
        if catalog~=ArmorCatalog then return previousNext(player,catalog,current,delta) end
        if not catalog or #catalog==0 then return nil,0 end
        local direction=(tonumber(delta) or 1)<0 and -1 or 1
        local index=tonumber(current) or 1
        for skipped=0,#catalog-1 do
            index=(index-1+direction)%#catalog+1
            local entry=catalog[index]
            if not byTag[string.lower(tostring(entry.Skin or ''))]
                and IsCustomizationEntryAvailable(player,entry) then
                return index,skipped
            end
        end
        return nil,#catalog
    end

    -- Preserve/cancel saved Classic selection when using the existing stock cycling controls.
    local previousDirect=ApplyDirect
    function ApplyDirect(player,entry)
        local ok,detail=previousDirect(player,entry)
        if ok then
            local c=byTag[string.lower(tostring(entry.Skin or ''))]
            ClassicArmorSetPersistentSelection(player,c and c.index or 0,'native armor cycle')
        end
        return ok,detail
    end

    ClassicArmorLoadPersistentState()
    for player=1,2 do
        local saved=tonumber(ClassicArmorMenuSelectedByPlayer[player]) or 0
        if saved~=0 and not byIndex[saved] then
            ClassicArmorSetPersistentSelection(player,0,'removed color migration')
            log('P'..player..' removed saved color='..saved..'; automatic Classic restore cleared')
        end
    end

    local generation=0
    local function schedule(source)
        generation=generation+1
        local token=generation
        local committed={}
        local function attempt(n)
            if token~=generation or ModTeardownGuard or CurrentWorldSessionKind()~='frontend' then return end
            if n>60 then log('FRONTEND timeout source='..source);return end
            ExecuteInGameThreadWithDelay(n==1 and 3000 or 1000,function()
                if token~=generation or ModTeardownGuard or CurrentWorldSessionKind()~='frontend' then return end
                local waiting=false
                for player=1,2 do
                    local index=tonumber(ClassicArmorMenuSelectedByPlayer[player]) or 0
                    if byIndex[index] and committed[player]~=index then
                        local ok=applyNative(player,index,source)
                        if ok then committed[player]=index else waiting=true end
                    end
                end
                if waiting then attempt(n+1) else log('FRONTEND completed source='..source..'; ordinary skins untouched') end
            end)
        end
        attempt(1)
    end
    local listener,why=pcall(function()
        NotifyOnNewObject('/Game/UI/Shared/Widgets/Squad/WBP_SquadWidget.WBP_SquadWidget_C',function()
            if CurrentWorldSessionKind()=='frontend' then schedule('squad widget') end
        end)
    end)
    schedule('startup')
    log('READY '..tostring(#definitions)..' cooked Classic colors; restore only saved Classic; legacy IDs preserved; listener='..tostring(listener)..' '..tostring(why))
end
