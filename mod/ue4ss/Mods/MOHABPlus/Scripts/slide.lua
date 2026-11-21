-- Sprint slide: crouching (turn stick down) while sprinting starts a short slide along the current direction.
-- The slide starts a bit faster than the current speed and decelerates to the crouched walking speed, so its length
-- is proportional to the sprint speed. The player ends crouched. A floor-scrape sound plays during the slide.
--
-- Movement: during the slide we run right after BP_R6PlayerController.TickInput (like the sprint) and drive
-- CharacterMovement.MaxWalkSpeed plus a movement input along the slide direction.
local U = require("util")
local C = require("config")

local M = {}

M.active = false
M.blockGesture = false      -- set after a slide: the arm-swing must stop once before it can stand the player up

local dir = nil             -- unit vector (X, Y)
local speed0, decel, endSpeed = 0, 0, 0
local startTime = 0
local soundEvent, stopEvent = nil, nil

-- ---------------------------------------------------------------------------------------------
-- Sound (Wwise). Events need their sound bank loaded; we load the event's RequiredBank once.
-- ---------------------------------------------------------------------------------------------
local SOUNDS = {
    body = { play = "/Game/R6/Audio/AI/Skits/131/Play_SKT_131_BodySlideOnTruck.Play_SKT_131_BodySlideOnTruck" },
    wood = { play = "/Game/R6/Audio/Interactibles/Doors/Wood/Play_Door_Wood_Scrape_Switch.Play_Door_Wood_Scrape_Switch",
             stop = "/Game/R6/Audio/Interactibles/Doors/Wood/Stop_Door_Wood_Scrape_Switch.Stop_Door_Wood_Scrape_Switch" },
    metal = { play = "/Game/R6/Audio/Interactibles/Doors/Metal/Play_Door_Metal_Scrape.Play_Door_Metal_Scrape",
              stop = "/Game/R6/Audio/Interactibles/Doors/Metal/Stop_Door_Metal_Scrape.Stop_Door_Metal_Scrape" },
}
M.SOUND_NAMES = { "body", "wood", "metal", "off" }

local ak = nil
local loadedBanks = {}
local function akStatics()
    if not U.valid(ak) then ak = StaticFindObject("/Script/AkAudio.Default__AkGameplayStatics") end
    return ak
end

local function loadEvent(path)
    if not path then return nil end
    local ev = StaticFindObject(path)
    if not U.valid(ev) then
        pcall(LoadAsset, path)
        ev = StaticFindObject(path)
    end
    if not U.valid(ev) then return nil end
    local bank = U.get(ev, "RequiredBank")
    if U.valid(bank) and not loadedBanks[bank:GetAddress()] then
        -- SynchronizeSoundBanks MUST be false: true makes Wwise unload every bank not in this list
        -- (all of the game's sounds and music).
        local ok = U.call(akStatics(), "LoadBanks", { bank }, false)
        loadedBanks[bank:GetAddress()] = ok
        U.dlog("sound bank %s loaded=%s", bank:GetFName():ToString(), tostring(ok))
    end
    return ev
end

local function playSound(pawn, name)
    local def = SOUNDS[name]
    if not def then return false end
    local ev = loadEvent(def.play)
    if not ev then return false end
    stopEvent = loadEvent(def.stop)
    soundEvent = ev
    local ok, id = U.call(akStatics(), "PostEventAttached", ev, pawn, FName("None"), true, "")
    return ok and id
end

local function stopSound(pawn)
    if U.valid(stopEvent) then
        U.call(akStatics(), "PostEventAttached", stopEvent, pawn, FName("None"), true, "")
    elseif U.valid(soundEvent) then
        -- ExecuteActionOnEvent(Stop) with a short fade
        U.call(akStatics(), "ExecuteActionOnEvent", soundEvent, 0, pawn, 200, 4, 0)
    end
    soundEvent, stopEvent = nil, nil
end

function M.debugPlay(pawn, name)
    local def = SOUNDS[name]
    if not def then return "unknown sound" end
    local ev = loadEvent(def.play)
    if not ev then return "event not found" end
    local bank = U.get(ev, "RequiredBank")
    local okI, inf = U.call(ev, "GetIsInfinite")
    local okD, dur = U.call(ev, "GetMaximumDuration")
    local id = playSound(pawn, name)
    return string.format("bank=%s infinite=%s maxDur=%s playingId=%s", U.valid(bank) and bank:GetFName():ToString() or "none",
        tostring(inf), tostring(dur), tostring(id))
end

-- ---------------------------------------------------------------------------------------------
-- Slide
-- ---------------------------------------------------------------------------------------------
local function horizontalVelocity(pawn)
    local cmc = U.get(pawn, "CharacterMovement")
    local v = U.get(cmc, "Velocity")
    if not v then return nil end
    return v.X or 0, v.Y or 0
end

-- Tries to start a slide. Returns true if it started.
function M.tryStart(pawn, ctrl, now, walkSpeed)
    if not C.get("slide_enabled") or M.active then return false end
    local cmc = U.get(pawn, "CharacterMovement")
    local okF, falling = U.call(cmc, "IsFalling")
    if okF and falling then U.dlog("slide refused: falling"); return false end
    local vx, vy = horizontalVelocity(pawn)
    if not vx then U.dlog("slide refused: no velocity"); return false end
    local s = math.sqrt(vx * vx + vy * vy)
    if s < walkSpeed * 1.15 then                        -- not really running
        U.dlog("slide refused: speed %.0f < %.0f", s, walkSpeed * 1.15)
        return false
    end

    dir = { X = vx / s, Y = vy / s }
    local strength = U.clamp(C.get("slide_strength"), 0.5, 2.0)
    speed0 = s * (1.0 + 0.25 * strength)
    decel = 650 / strength
    local crouchMult = U.get(ctrl, "CrouchSpeedMultiplier")
    if type(crouchMult) ~= "number" or crouchMult <= 0 then crouchMult = 0.5 end
    endSpeed = walkSpeed * crouchMult
    startTime = now
    -- Initial push: set the velocity directly (the movement component's acceleration would cap the boost).
    local vz = 0
    pcall(function() vz = cmc.Velocity.Z end)
    pcall(function() cmc.Velocity = { X = dir.X * speed0, Y = dir.Y * speed0, Z = vz } end)
    M.active = true
    M.blockGesture = true
    pcall(function() ctrl.IsSprinting = false end)
    local snd = C.get("slide_sound")
    if snd ~= "off" then playSound(pawn, snd) end
    U.dlog("slide start: speed %.0f -> %.0f, decel %.0f", s, speed0, decel)
    return true
end

function M.stop(pawn, reason)
    if not M.active then return end
    M.active = false
    if U.valid(pawn) then stopSound(pawn) end
    U.dlog("slide end (%s)", reason or "")
end

-- Post-hook of TickInput. Returns true while sliding (the sprint logic must not run).
function M.update(ctrl, pawn, now)
    if not M.active then return false end
    local cmc = U.get(pawn, "CharacterMovement")
    local t = now - startTime
    local target = speed0 - decel * t
    if target <= endSpeed or t > 2.5 then
        M.stop(pawn, "finished")
        return false
    end
    local okF, falling = U.call(cmc, "IsFalling")
    if okF and falling then
        M.stop(pawn, "falling")
        return false
    end
    -- Hit a wall / obstacle: actual speed far below the slide speed.
    local vx, vy = horizontalVelocity(pawn)
    if vx and t > 0.15 then
        local actual = math.sqrt(vx * vx + vy * vy)
        if actual < target * 0.45 then
            M.stop(pawn, "blocked")
            return false
        end
    end
    pcall(function() ctrl.IsSprinting = false end)
    pcall(function() cmc.MaxWalkSpeed = target end)
    U.call(pawn, "AddMovementInput", { X = dir.X, Y = dir.Y, Z = 0 }, 1.0, true)
    return true
end

-- The arm-swing gesture may stand the player up again only after it stopped once.
function M.gestureReleased()
    M.blockGesture = false
end

function M.reset(pawn)
    if M.active then M.stop(pawn, "reset") end
    M.blockGesture = false
end

return M
