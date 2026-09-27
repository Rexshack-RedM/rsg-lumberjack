-- rsg-lumberjack - Client

local RSGCore = exports['rsg-core']:GetCoreObject()
lib.locale()

local isLoggedIn = false
local PlayerData = {}

local State = {
    chopping = false,
    carryingLog = false,
    logObj = nil,
    wagonLogEntities = {},   -- [wagonNetId] = { { prop, posIndex }, ... }
    plantedTrees = {},
    treeEntities = {},
    groundLogs = {},
    woodPieces = {},
    otherPlayersCarrying = {},
}

-- ============================================================================
-- NOTIFICATIONS (ox_lib)
-- ============================================================================
local function Notify(descKey, descArgs, ntype)
    lib.notify({
        title = locale('notify_title'),
        description = descArgs and locale(descKey, table.unpack(descArgs)) or locale(descKey),
        type = ntype or 'inform',
        duration = 5000
    })
end

local function NotifySuccess(key, args) Notify(key, args, 'success') end
local function NotifyError(key, args) Notify(key, args, 'error') end

local function NotifyResultError(result)
    if not result or not result.reason then return end
    NotifyError(result.reason, result.args)
end

local function DebugPrint(...)
    if Config.Debug then
        print('[rsg-lumberjack]', ...)
    end
end

local function DrawText3D(x, y, z, text)
    local onScreen, _x, _y = GetScreenCoordFromWorldCoord(x, y, z)
    if onScreen then
        SetTextScale(0.35, 0.35)
        SetTextFontForCurrentCommand(1)
        SetTextColor(255, 255, 255, 215)
        DisplayText(CreateVarString(10, "LITERAL_STRING", text), _x, _y)
    end
end

local function DrawTreeProgressBar(x, y, z, progress, label)
    local onScreen, sx, sy = GetScreenCoordFromWorldCoord(x, y, z)
    if not onScreen then return end

    if progress < 0.0 then progress = 0.0 end
    if progress > 1.0 then progress = 1.0 end

    local barWidth, barHeight = 0.055, 0.011

    -- Label is drawn well above the bar (separate world-space offset) and
    -- centered on it, so it never overlaps the bar itself.
    local labelOnScreen, lx, ly = GetScreenCoordFromWorldCoord(x, y, z + 0.35)
    if labelOnScreen then
        SetTextScale(0.35, 0.35)
        SetTextFontForCurrentCommand(1)
        SetTextColor(255, 255, 255, 215)
        SetTextCentre(true)
        DisplayText(CreateVarString(10, "LITERAL_STRING", label), lx, ly)
    end

    -- background track
    DrawRect(sx, sy, barWidth, barHeight, 15, 15, 15, 160)
    -- border
    DrawRect(sx, sy, barWidth + 0.002, barHeight + 0.004, 0, 0, 0, 200)

    if progress > 0.0 then
        local fgWidth = barWidth * progress
        local fgX = sx - (barWidth / 2.0) + (fgWidth / 2.0)
        DrawRect(fgX, sy, fgWidth, barHeight, 90, 200, 110, 220)
    end
end

-- ============================================================================
-- PLAYER LOAD / UNLOAD
-- ============================================================================
CreateThread(function()
    Wait(500)
    PlayerData = RSGCore.Functions.GetPlayerData()
end)

AddEventHandler('RSGCore:Client:OnPlayerLoaded', function()
    isLoggedIn = true
    PlayerData = RSGCore.Functions.GetPlayerData()
    TriggerServerEvent('rsg-lumberjack:server:requestGroundItems')
    TriggerServerEvent('rsg-lumberjack:server:requestTrees')
end)

RegisterNetEvent('RSGCore:Client:OnPlayerUnload', function()
    isLoggedIn = false
    PlayerData = {}
end)

-- ============================================================================
-- CARRY HELPER FUNCTIONS
-- ============================================================================
local function ClearCarryMovement(ped)
    if type(ResetPedMovementClipset) == 'function' then
        ResetPedMovementClipset(ped, 0.0)
    end
end

local function ResolveCarryBone(ped, attach)
    local boneIndex = -1
    if type(attach.bone) == 'number' then
        boneIndex = attach.bone
    elseif type(attach.bone) == 'string' then
        boneIndex = GetEntityBoneIndexByName(ped, attach.bone)
        if boneIndex == -1 then boneIndex = GetEntityBoneIndexByName(ped, 'PH_R_HAND') end
        if boneIndex == -1 then boneIndex = GetEntityBoneIndexByName(ped, 'SKEL_R_HAND') end
        if boneIndex == -1 then boneIndex = GetEntityBoneIndexByName(ped, 'SKEL_R_Clavicle') end
        if boneIndex == -1 then boneIndex = GetEntityBoneIndexByName(ped, 'SKEL_R_UpperArm') end
    end
    if not boneIndex or boneIndex == -1 then boneIndex = 7966 end
    return boneIndex
end

local function GetCarryAttach()
    return Config.Carry.AttachBox or { bone = 7966, pos = { x = 0.10, y = 0.28, z = 0.02 }, rot = { x = 0.0, y = 90.0, z = 10.0 } }
end

local function ApplyCarryMovement(ped)
    local clipset = Config.Carry.MoveClipset
    if not clipset or clipset == '' then return end
    if type(RequestAnimSet) ~= 'function' or type(HasAnimSetLoaded) ~= 'function' or type(SetPedMovementClipset) ~= 'function' then
        return
    end
    RequestAnimSet(clipset)
    local timeout = GetGameTimer() + 5000
    while not HasAnimSetLoaded(clipset) and GetGameTimer() < timeout do Wait(0) end
    if HasAnimSetLoaded(clipset) then
        SetPedMovementClipset(ped, clipset, 0.0)
    end
end

local function AttachLogToPed(ped)
    local model = Config.Models.CarryLog
    RequestModel(model)
    local timeout = GetGameTimer() + 5000
    while not HasModelLoaded(model) and GetGameTimer() < timeout do Wait(0) end

    local coords = GetEntityCoords(ped)
    local obj = CreateObject(model, coords.x, coords.y, coords.z, false, false, false)
    if not DoesEntityExist(obj) then return 0 end

    SetEntityAsMissionEntity(obj, true, true)

    local attach = GetCarryAttach()
    local boneIndex = ResolveCarryBone(ped, attach)
    AttachEntityToEntity(
        obj, ped, boneIndex,
        attach.pos.x or 0.0, attach.pos.y or 0.28, attach.pos.z or 0.02,
        attach.rot.x or 0.0, attach.rot.y or 90.0, attach.rot.z or 10.0,
        true, true, false, true, 1, true
    )
    return obj
end

local function StartCarryAnimLoop(ped)
    CreateThread(function()
        local dict = Config.Carry.AnimDict or 'amb_wander@code_human_hay_bale_wander@male_a@base'
        local clip = Config.Carry.AnimClip or 'base'
        local flag = Config.Carry.AnimFlag or 25
        RequestAnimDict(dict)
        local start = GetGameTimer()
        while not HasAnimDictLoaded(dict) and (GetGameTimer() - start) < 3000 do Wait(20) end
        local lastReplay = 0
        while State.carryingLog do
            if not IsEntityPlayingAnim(ped, dict, clip, 3) or (GetGameTimer() - lastReplay) > 1500 then
                TaskPlayAnim(ped, dict, clip, 2.0, 2.0, -1, flag or 25, 0, false, false, false)
                lastReplay = GetGameTimer()
            end
            Wait(0)
        end
    end)
end

function AttachLogToPlayer()
    if State.carryingLog then return end
    local playerPed = PlayerPedId()
    local obj = AttachLogToPed(playerPed)
    if obj == 0 or not DoesEntityExist(obj) then return end

    State.logObj = obj
    State.carryingLog = true

    ApplyCarryMovement(playerPed)
    SetCurrentPedWeapon(playerPed, `WEAPON_UNARMED`, true)
    StartCarryAnimLoop(playerPed)
    SetPedMoveRateOverride(playerPed, 1.0)
end

local function AttachLogToOtherPlayer(serverId)
    local playerId = GetPlayerFromServerId(serverId)
    if playerId == -1 then return nil end

    local ped = GetPlayerPed(playerId)
    if not ped or not DoesEntityExist(ped) then return nil end

    local model = Config.Models.CarryLog
    RequestModel(model)
    local timeout = GetGameTimer() + 5000
    while not HasModelLoaded(model) and GetGameTimer() < timeout do Wait(10) end
    if not HasModelLoaded(model) then return nil end

    local coords = GetEntityCoords(ped)
    local obj = CreateObject(model, coords.x, coords.y, coords.z, false, false, false)
    if not obj or not DoesEntityExist(obj) then return nil end

    SetEntityAsMissionEntity(obj, true, true)

    local attach = GetCarryAttach()
    local boneIndex = ResolveCarryBone(ped, attach)
    AttachEntityToEntity(
        obj, ped, boneIndex,
        attach.pos.x or 0.0, attach.pos.y or 0.28, attach.pos.z or 0.02,
        attach.rot.x or 0.0, attach.rot.y or 90.0, attach.rot.z or 10.0,
        true, true, false, true, 1, true
    )
    return obj
end

local function RemoveLogFromOtherPlayer(serverId)
    local entity = State.otherPlayersCarrying[serverId]
    if entity and DoesEntityExist(entity) then
        DeleteEntity(entity)
    end
    State.otherPlayersCarrying[serverId] = nil
end

-- All carry start/stop visuals are driven by the server - it is the only
-- source of truth for whether a player is legitimately carrying a log.
RegisterNetEvent('rsg-lumberjack:client:playerStartedCarrying', function(serverId)
    local myServerId = GetPlayerServerId(PlayerId())
    if serverId == myServerId then
        AttachLogToPlayer()
    else
        RemoveLogFromOtherPlayer(serverId)
        local entity = AttachLogToOtherPlayer(serverId)
        if entity then State.otherPlayersCarrying[serverId] = entity end
    end
end)

RegisterNetEvent('rsg-lumberjack:client:playerStoppedCarrying', function(serverId)
    local myServerId = GetPlayerServerId(PlayerId())
    if serverId == myServerId then
        if State.logObj and DoesEntityExist(State.logObj) then
            DeleteEntity(State.logObj)
        end
        State.carryingLog = false
        State.logObj = nil
        local ped = PlayerPedId()
        ClearCarryMovement(ped)
        ClearPedTasks(ped)
        SetPedMoveRateOverride(ped, 1.0)
        LocalPlayer.state:set('inv_busy', false, true)
    else
        RemoveLogFromOtherPlayer(serverId)
    end
end)

RegisterNetEvent('rsg-lumberjack:client:syncCarryingPlayers', function(carryingPlayers)
    local myServerId = GetPlayerServerId(PlayerId())
    for _, serverId in ipairs(carryingPlayers) do
        if serverId ~= myServerId then
            SetTimeout(1000, function()
                local entity = AttachLogToOtherPlayer(serverId)
                if entity then State.otherPlayersCarrying[serverId] = entity end
            end)
        end
    end
end)

function DropLog()
    if not State.carryingLog then return end

    local playerPed = PlayerPedId()
    local coords = GetEntityCoords(playerPed)
    local forward = GetEntityForwardVector(playerPed)
    local dropPos = coords + forward * 1.0

    local foundGround, groundZ = GetGroundZFor_3dCoord(dropPos.x, dropPos.y, dropPos.z, false)
    if not foundGround then groundZ = dropPos.z - 0.5 end

    TriggerServerEvent('rsg-lumberjack:server:dropLog', dropPos.x, dropPos.y, groundZ)
end

function PickupLog(logId)
    if State.carryingLog then
        NotifyError('already_carrying')
        return
    end
    TriggerServerEvent('rsg-lumberjack:server:pickupLog', logId)
end

-- ============================================================================
-- E KEY PROMPT TO DROP LOG
-- ============================================================================
CreateThread(function()
    while true do
        Wait(0)
        if State.carryingLog then
            local ped = PlayerPedId()
            local coords = GetEntityCoords(ped)
            DrawText3D(coords.x, coords.y, coords.z + 1.1, locale('press_e_drop_log'))

            if IsControlJustPressed(0, 0xCEFD9220) then
                DropLog()
            end
        else
            Wait(200)
        end
    end
end)

-- ============================================================================
-- SECURE CHOP FLOW (wild tree / ground log / planted tree)
-- Requests authorization from the server before running the progress bar,
-- then reports completion - the server decides whether the chop succeeded.
-- ============================================================================
local function RunChopFlow(kind, targetId)
    if State.chopping then return end

    local coords = GetEntityCoords(PlayerPedId())

    RSGCore.Functions.TriggerCallback('rsg-lumberjack:server:requestChop', function(result)
        if not result or not result.ok then
            NotifyResultError(result)
            return
        end

        State.chopping = true
        LocalPlayer.state:set('inv_busy', true, true)

        local isLog = kind == 'groundlog'
        local success = lib.progressBar({
            duration = result.duration,
            label = isLog and locale('chop_log_label') or locale('chop_tree_label'),
            useWhileDead = false,
            canCancel = true,
            disable = { move = false, car = true, combat = true },
            anim = isLog and {
                dict = 'amb_work@prop_human_wood_chop@pre_chop@male_a@trans',
                clip = 'prechop_trans_postchop_07_08_a',
                flag = 15,
            } or {
                dict = 'amb_work@world_human_tree_chop_new@working@pre_swing@male_a@trans',
                clip = 'pre_swing_trans_after_swing',
                flag = 17,
            },
            prop = {
                model = `p_axe02x`,
                bone = 7966,
                pos = vec3(0.03, 0.03, 0.02),
                rot = vec3(0.0, 0.0, -1.5)
            },
        })

        State.chopping = false
        LocalPlayer.state:set('inv_busy', false, true)

        if success then
            TriggerServerEvent('rsg-lumberjack:server:completeChop', kind, targetId)
        else
            NotifyError('chop_cancelled')
        end
    end, kind, targetId, coords)
end

-- ============================================================================
-- WILD TREE CHOPPING
-- ============================================================================
CreateThread(function()
    Wait(2000)
    if Config.Trees and #Config.Trees > 0 then
        local plantedModels = {}
        for _, model in ipairs(Config.Planting.StageModels) do
            plantedModels[GetHashKey(model)] = true
        end

        local wildTrees = {}
        for _, treeModel in ipairs(Config.Trees) do
            if not plantedModels[treeModel] then
                wildTrees[#wildTrees + 1] = treeModel
            end
        end

        if #wildTrees > 0 then
            pcall(function()
                exports['rsg-target']:AddTargetModel(wildTrees, {
                    options = {
                        {
                            type = 'client',
                            action = function(entity)
                                RunChopFlow('wildtree', 0)
                            end,
                            icon = 'fas fa-tree',
                            label = 'Chop Tree',
                        },
                    },
                    distance = Config.Chopping.InteractDistance
                })
            end)
        end
        DebugPrint('Added targets to', #wildTrees, 'wild tree models')
    end
end)

-- ============================================================================
-- GROUND LOG SYSTEM (Server-synced)
-- ============================================================================
local function SpawnGroundLogEntity(logData)
    local model = GetHashKey('p_cedar_log_06x')
    RequestModel(model)
    local timeout = GetGameTimer() + 5000
    while not HasModelLoaded(model) and GetGameTimer() < timeout do Wait(10) end
    if not HasModelLoaded(model) then return nil end

    local obj = CreateObject(model, logData.x, logData.y, logData.z, false, false, false)
    if not obj or not DoesEntityExist(obj) then return nil end

    PlaceObjectOnGroundProperly(obj)
    FreezeEntityPosition(obj, true)
    SetEntityAsMissionEntity(obj, true, true)

    pcall(function()
        if DoesEntityExist(obj) then
            exports['rsg-target']:AddTargetEntity(obj, {
                options = {
                    {
                        type = 'client',
                        action = function() RunChopFlow('groundlog', logData.id) end,
                        icon = 'fas fa-axe',
                        label = 'Process into Wood',
                    },
                    {
                        type = 'client',
                        action = function() PickupLog(logData.id) end,
                        icon = 'fas fa-hand-paper',
                        label = 'Pick Up Log',
                    }
                },
                distance = 2.0
            })
        end
    end)

    return obj
end

local function RemoveGroundLogEntity(logId)
    local entity = State.groundLogs[logId]
    if entity and DoesEntityExist(entity) then
        exports['rsg-target']:RemoveTargetEntity(entity)
        DeleteEntity(entity)
    end
    State.groundLogs[logId] = nil
end

RegisterNetEvent('rsg-lumberjack:client:syncGroundLogs', function(logs)
    for _, entity in pairs(State.groundLogs) do
        if DoesEntityExist(entity) then
            exports['rsg-target']:RemoveTargetEntity(entity)
            DeleteEntity(entity)
        end
    end
    State.groundLogs = {}

    for _, logData in pairs(logs) do
        local entity = SpawnGroundLogEntity(logData)
        if entity then State.groundLogs[logData.id] = entity end
    end
end)

RegisterNetEvent('rsg-lumberjack:client:addGroundLog', function(logData)
    local entity = SpawnGroundLogEntity(logData)
    if entity then State.groundLogs[logData.id] = entity end
end)

RegisterNetEvent('rsg-lumberjack:client:removeGroundLog', function(logId)
    RemoveGroundLogEntity(logId)
end)

-- ============================================================================
-- WOOD PICKUP SYSTEM (Server-synced)
-- ============================================================================
local function SpawnWoodEntity(woodData)
    local model = Config.Models.WoodProp
    RequestModel(model)
    local timeout = GetGameTimer() + 5000
    while not HasModelLoaded(model) and GetGameTimer() < timeout do Wait(10) end

    local obj = CreateObject(model, woodData.x, woodData.y, woodData.z, false, false, false)
    if not DoesEntityExist(obj) then return nil end

    PlaceObjectOnGroundProperly(obj)
    FreezeEntityPosition(obj, true)
    SetEntityAsMissionEntity(obj, true, true)

    pcall(function()
        if DoesEntityExist(obj) then
            exports['rsg-target']:AddTargetEntity(obj, {
                options = {
                    {
                        type = 'client',
                        action = function() TriggerServerEvent('rsg-lumberjack:server:pickupWood', woodData.id) end,
                        icon = 'fas fa-hand-paper',
                        label = 'Pick Up Wood',
                    }
                },
                distance = 2.0
            })
        end
    end)

    return obj
end

local function RemoveWoodEntity(woodId)
    local entity = State.woodPieces[woodId]
    if entity and DoesEntityExist(entity) then
        exports['rsg-target']:RemoveTargetEntity(entity)
        DeleteEntity(entity)
    end
    State.woodPieces[woodId] = nil
end

RegisterNetEvent('rsg-lumberjack:client:syncWoodPieces', function(woods)
    for _, entity in pairs(State.woodPieces) do
        if DoesEntityExist(entity) then
            exports['rsg-target']:RemoveTargetEntity(entity)
            DeleteEntity(entity)
        end
    end
    State.woodPieces = {}

    for _, woodData in pairs(woods) do
        local entity = SpawnWoodEntity(woodData)
        if entity then State.woodPieces[woodData.id] = entity end
    end
end)

RegisterNetEvent('rsg-lumberjack:client:addWoodPiece', function(woodData)
    local entity = SpawnWoodEntity(woodData)
    if entity then State.woodPieces[woodData.id] = entity end
end)

RegisterNetEvent('rsg-lumberjack:client:removeWoodPiece', function(woodId)
    RemoveWoodEntity(woodId)
end)

-- ============================================================================
-- WAGON SYSTEM (load / unload / sell)
-- ============================================================================
local function SpawnWagonLogProp(wagon, wagonNetId, posIndex)
    if not wagon or not DoesEntityExist(wagon) then return end

    local existing = State.wagonLogEntities[wagonNetId]
    if existing then
        for _, logData in ipairs(existing) do
            if logData.posIndex == posIndex then return end -- already spawned
        end
    else
        State.wagonLogEntities[wagonNetId] = {}
    end

    local pos = Config.Wagon.LogPositions[posIndex]
    if not pos then return end

    local modelHash = Config.Wagon.LogStackModel
    RequestModel(modelHash)
    local timeout = GetGameTimer() + 5000
    while not HasModelLoaded(modelHash) and GetGameTimer() < timeout do Wait(10) end
    if not HasModelLoaded(modelHash) then return end

    local logProp = CreateObject(modelHash, 0, 0, 0, false, false, false)
    if not logProp or not DoesEntityExist(logProp) then return end

    AttachEntityToEntity(logProp, wagon, 0, pos.x, pos.y, pos.z, pos.rotX, pos.rotY, pos.rotZ, true, true, true, true, 1, true)
    table.insert(State.wagonLogEntities[wagonNetId], { prop = logProp, posIndex = posIndex })

    pcall(function()
        if DoesEntityExist(logProp) then
            exports['rsg-target']:AddTargetEntity(logProp, {
                options = {
                    {
                        type = 'client',
                        action = function()
                            if State.carryingLog then
                                NotifyError('already_carrying')
                                return
                            end
                            TriggerServerEvent('rsg-lumberjack:server:removeLogFromWagon', wagonNetId)
                        end,
                        icon = 'fas fa-hand-paper',
                        label = 'Remove Log',
                    }
                },
                distance = 3.0
            })
        end
    end)
end

local function RemoveWagonLogProp(wagonNetId, posIndex)
    local logEntities = State.wagonLogEntities[wagonNetId]
    if not logEntities then return end

    for i = #logEntities, 1, -1 do
        if logEntities[i].posIndex == posIndex then
            local logData = table.remove(logEntities, i)
            if logData.prop and DoesEntityExist(logData.prop) then
                exports['rsg-target']:RemoveTargetEntity(logData.prop)
                DeleteEntity(logData.prop)
            end
            break
        end
    end
end

local function ClearWagonLogProps(wagonNetId)
    local logEntities = State.wagonLogEntities[wagonNetId]
    if logEntities then
        for _, logData in ipairs(logEntities) do
            if logData.prop and DoesEntityExist(logData.prop) then
                exports['rsg-target']:RemoveTargetEntity(logData.prop)
                DeleteEntity(logData.prop)
            end
        end
    end
    State.wagonLogEntities[wagonNetId] = nil
end

CreateThread(function()
    pcall(function()
        exports['rsg-target']:AddTargetModel({ Config.Wagon.Model }, {
            options = {
                {
                    type = 'client',
                    action = function(entity)
                        if not State.carryingLog then
                            NotifyError('not_carrying')
                            return
                        end
                        local wagonNetId = NetworkGetNetworkIdFromEntity(entity)
                        TriggerServerEvent('rsg-lumberjack:server:addLogToWagon', wagonNetId)
                    end,
                    icon = 'fas fa-truck-loading',
                    label = 'Load Log onto Wagon',
                    canInteract = function() return State.carryingLog end
                },
                {
                    type = 'client',
                    action = function(entity)
                        local wagonNetId = NetworkGetNetworkIdFromEntity(entity)
                        RSGCore.Functions.TriggerCallback('rsg-lumberjack:server:getWagonLogs', function(result)
                            Notify('wagon_check', { result.logCount or 0, Config.Wagon.MaxLogsOnWagon })
                        end, wagonNetId)
                        TriggerServerEvent('rsg-lumberjack:server:requestWagonSync', wagonNetId)
                    end,
                    icon = 'fas fa-clipboard-check',
                    label = 'Check Wagon',
                }
            },
            distance = 3.0
        })
    end)
end)

RegisterNetEvent('rsg-lumberjack:client:logAddedToWagon', function(wagonNetId, posIndex)
    local wagon = NetworkGetEntityFromNetworkId(wagonNetId)
    SpawnWagonLogProp(wagon, wagonNetId, posIndex)
end)

RegisterNetEvent('rsg-lumberjack:client:logRemovedFromWagon', function(wagonNetId, posIndex)
    RemoveWagonLogProp(wagonNetId, posIndex)
end)

RegisterNetEvent('rsg-lumberjack:client:resetWagon', function(wagonNetId)
    ClearWagonLogProps(wagonNetId)
end)

RegisterNetEvent('rsg-lumberjack:client:syncWagonLogs', function(wagonNetId, positions)
    local wagon = NetworkGetEntityFromNetworkId(wagonNetId)
    if not wagon or not DoesEntityExist(wagon) then return end
    for _, posIndex in ipairs(positions or {}) do
        SpawnWagonLogProp(wagon, wagonNetId, posIndex)
    end
end)

-- ============================================================================
-- WAGON SELL LOCATIONS (multiple locations, each with its own price)
-- ============================================================================
CreateThread(function()
    for i, location in ipairs(Config.WagonSellLocations) do
        if location.blip then
            local blip = N_0x554d9d53f696d002(1664425300, location.coords)
            SetBlipSprite(blip, location.blip.sprite, 1)
            SetBlipScale(blip, location.blip.scale or 0.2)
            Citizen.InvokeNative(0x9CB1A1623062F402, blip, location.blip.label or location.name or 'Sell Logs')
        end

        local locationIndex = i
        CreateThread(function()
            local lastNotify = 0
            while true do
                Wait(0)
                local ped = PlayerPedId()
                local coords = GetEntityCoords(ped)
                local dist = #(coords - location.coords)
                local vehicle = GetVehiclePedIsIn(ped, false)

                if dist < location.radius and vehicle ~= 0 and GetEntityModel(vehicle) == Config.Wagon.Model then
                    if GetGameTimer() - lastNotify > 5000 then
                        Notify('press_e_sell')
                        lastNotify = GetGameTimer()
                    end

                    if IsControlJustPressed(0, 0xCEFD9220) then
                        local wagonNetId = NetworkGetNetworkIdFromEntity(vehicle)
                        TriggerServerEvent('rsg-lumberjack:server:sellWagonLoad', wagonNetId, locationIndex)
                        Wait(1000)
                    end
                else
                    Wait(200)
                end
            end
        end)
    end
end)

-- ============================================================================
-- TREE PLANTING SYSTEM (Growing) - plant anywhere on the map
-- ============================================================================
RegisterNetEvent('rsg-lumberjack:client:useSeed', function()
    TryPlantTree()
end)

function TryPlantTree()
    local ped = PlayerPedId()
    local coords = GetEntityCoords(ped)

    local fwd = GetEntityForwardVector(ped)
    local from = coords + (fwd * 0.5)
    local to = coords + (fwd * Config.Chopping.RaycastDistance)

    local rayHandle = StartShapeTestRay(from.x, from.y, from.z + 0.5, to.x, to.y, to.z - 1.0, 1, ped, 7)
    local _, hit, endCoords = GetShapeTestResult(rayHandle)

    if hit ~= 1 then
        local guess = coords + (fwd * (Config.Chopping.RaycastDistance - 0.5))
        local found, gz = GetGroundZFor_3dCoord(guess.x, guess.y, guess.z, false)
        endCoords = vector3(guess.x, guess.y, (found and gz) or guess.z)
    end

    FreezeEntityPosition(ped, true)
    TaskStartScenarioInPlace(ped, `WORLD_HUMAN_FARMER_WEEDING`, 0, true)
    Wait(5000)
    ClearPedTasks(ped)
    SetCurrentPedWeapon(ped, `WEAPON_UNARMED`, true)
    FreezeEntityPosition(ped, false)

    local heading = GetEntityHeading(ped)
    TriggerServerEvent('rsg-lumberjack:server:plantTree', { x = endCoords.x, y = endCoords.y, z = endCoords.z }, heading)
end

RegisterNetEvent('rsg-lumberjack:client:useWater', function()
    if Config.Planting.RequireWater then
        local hasWater = RSGCore.Functions.HasItem(Config.Planting.WaterItem, 1)
        if not hasWater then
            NotifyError('need_water')
            return
        end
    end

    local ped = PlayerPedId()
    local pcoords = GetEntityCoords(ped)
    local nearestId, nearestDist

    for id, t in pairs(State.plantedTrees) do
        if (t.stage or 1) < 4 and (t.watered or 0) == 0 then
            local dist = #(pcoords - vector3(t.x, t.y, t.z))
            if not nearestDist or dist < nearestDist then
                nearestDist = dist
                nearestId = id
            end
        end
    end

    if nearestId and nearestDist and nearestDist <= (Config.Chopping.InteractDistance + 1.0) then
        DoWaterTree(nearestId)
    else
        NotifyError('no_tree_nearby_water')
    end
end)

function DoWaterTree(id)
    local ped = PlayerPedId()
    LocalPlayer.state:set('inv_busy', true, true)
    FreezeEntityPosition(ped, true)
    TaskStartScenarioInPlace(ped, `WORLD_HUMAN_BUCKET_POUR_LOW`, 0, true)
    Wait(8000)
    ClearPedTasks(ped)
    SetCurrentPedWeapon(ped, `WEAPON_UNARMED`, true)
    FreezeEntityPosition(ped, false)
    TriggerServerEvent('rsg-lumberjack:server:waterTree', id)
    LocalPlayer.state:set('inv_busy', false, true)
end

-- Stamps a tree payload with the local time it was received, so the owner's
-- growth progress bar can count down locally (via GetGameTimer() deltas)
-- without depending on the client's wall clock matching the server's.
local function StampTreeReceived(tree)
    tree.stage = tonumber(tree.stage) or 1
    tree.watered = tonumber(tree.watered) or 0
    tree.receivedAt = GetGameTimer()
    return tree
end

RegisterNetEvent('rsg-lumberjack:client:updateTreeVisual', function(tree)
    StampTreeReceived(tree)
    State.plantedTrees[tree.id] = tree
    -- Only refresh the entity immediately if it's already rendered (in range);
    -- otherwise the streaming loop will spawn it correctly next tick if/when
    -- the player comes into range.
    if State.treeEntities[tree.id] and DoesEntityExist(State.treeEntities[tree.id]) then
        SpawnOrUpdatePlantedTree(tree)
    end
end)

RegisterNetEvent('rsg-lumberjack:client:setTrees', function(list)
    State.plantedTrees = {}
    for _, t in ipairs(list or {}) do
        StampTreeReceived(t)
        State.plantedTrees[t.id] = t
    end
    -- Entity creation is left entirely to the streaming loop below so we
    -- don't spawn props for trees that are far from the player.
end)

RegisterNetEvent('rsg-lumberjack:client:removeTree', function(id)
    RemovePlantedTreeEntity(id)
end)

-- Despawns just the visual entity (used when the player walks out of render
-- range) while keeping the tree's data so it can respawn when back in range.
function DespawnPlantedTreeEntity(id)
    local ent = State.treeEntities[id]
    if ent and DoesEntityExist(ent) then
        exports['rsg-target']:RemoveTargetEntity(ent)
        DeleteEntity(ent)
    end
    State.treeEntities[id] = nil
end

-- Fully removes a tree (chopped/no longer exists) - clears both the entity
-- and its data.
function RemovePlantedTreeEntity(id)
    DespawnPlantedTreeEntity(id)
    State.plantedTrees[id] = nil
end

function SpawnOrUpdatePlantedTree(tree)
    local current = State.treeEntities[tree.id]
    local modelName = Config.Planting.StageModels[tree.stage] or Config.Planting.StageModels[4]
    local desiredModel = GetHashKey(modelName)

    if current and DoesEntityExist(current) then
        if GetEntityModel(current) == desiredModel then
            return
        else
            RemovePlantedTreeEntity(tree.id)
            State.plantedTrees[tree.id] = tree -- RemovePlantedTreeEntity clears this; put it back before respawning
        end
    end

    RequestModel(desiredModel)
    local timeout = GetGameTimer() + 5000
    while not HasModelLoaded(desiredModel) and GetGameTimer() < timeout do Wait(10) end
    if not HasModelLoaded(desiredModel) then return end

    local obj = CreateObject(desiredModel, tree.x, tree.y, tree.z, false, false, false)
    if not DoesEntityExist(obj) then return end

    SetEntityHeading(obj, tree.heading or 0.0)
    SetEntityAsMissionEntity(obj, true)
    PlaceObjectOnGroundProperly(obj)
    FreezeEntityPosition(obj, true)
    State.treeEntities[tree.id] = obj

    Wait(100)
    RegisterPlantedTreeTarget(tree.id, obj, tree)
end

function RegisterPlantedTreeTarget(id, ent, tree)
    local options = {}

    if tree.stage == 4 and tree.state == 'ready' then
        options[#options + 1] = {
            type = 'client',
            action = function() RunChopFlow('plantedtree', id) end,
            icon = 'fas fa-axe',
            label = 'Chop Tree',
        }
    elseif (tree.watered or 0) == 0 then
        options[#options + 1] = {
            type = 'client',
            action = function()
                if Config.Planting.RequireWater then
                    local hasWater = RSGCore.Functions.HasItem(Config.Planting.WaterItem, 1)
                    if not hasWater then
                        NotifyError('need_water')
                        return
                    end
                end
                DoWaterTree(id)
            end,
            icon = 'fas fa-droplet',
            label = 'Water Tree',
        }
    end

    if ent and DoesEntityExist(ent) and #options > 0 then
        pcall(function()
            if DoesEntityExist(ent) then
                exports['rsg-target']:AddTargetEntity(ent, { options = options, distance = Config.Chopping.InteractDistance })
            end
        end)
    end
end

-- ============================================================================
-- TREE STREAMING (only render tree props while a player is nearby)
-- ============================================================================
CreateThread(function()
    while true do
        Wait(1000)
        local pCoords = GetEntityCoords(PlayerPedId())
        local renderDist = Config.Planting.RenderDistance or 40.0

        for id, t in pairs(State.plantedTrees) do
            local dist = #(pCoords - vector3(t.x, t.y, t.z))
            local hasEntity = State.treeEntities[id] and DoesEntityExist(State.treeEntities[id])

            if dist <= renderDist then
                if not hasEntity then
                    SpawnOrUpdatePlantedTree(t)
                end
            elseif hasEntity then
                DespawnPlantedTreeEntity(id)
            end
        end
    end
end)

-- ============================================================================
-- OWNER GROWTH PROGRESS BAR
-- ============================================================================
CreateThread(function()
    while true do
        local sleep = 500
        local myCitizenId = PlayerData and PlayerData.citizenid

        if myCitizenId then
            local pCoords = GetEntityCoords(PlayerPedId())
            local barDist = Config.Planting.ProgressBarDistance or 12.0

            for id, t in pairs(State.plantedTrees) do
                if t.owner_citizenid == myCitizenId and t.state == 'growing' and t.growth_remaining and t.growth_duration then
                    local dist = #(pCoords - vector3(t.x, t.y, t.z))
                    if dist <= barDist then
                        sleep = 0 -- draw every frame while an owned growing tree is nearby

                        local elapsed = (GetGameTimer() - (t.receivedAt or GetGameTimer())) / 1000.0
                        local remaining = math.max(0, t.growth_remaining - elapsed)
                        local progress = 1.0 - (remaining / t.growth_duration)

                        DrawTreeProgressBar(t.x, t.y, t.z + 2.3, progress, locale('tree_growing_label', math.floor(progress * 100)))
                    end
                end
            end
        end

        Wait(sleep)
    end
end)

-- ============================================================================
-- DEBUG COMMANDS
-- ============================================================================
if Config.Debug then
    RegisterCommand('spawnlog', function()
        if State.carryingLog then
            lib.notify({ description = 'Already carrying a log!', type = 'error' })
            return
        end
        AttachLogToPlayer()
        lib.notify({ description = '[DEBUG] Log spawned in hands!', type = 'success' })
    end, false)

    RegisterCommand('clearlog', function()
        if State.logObj and DoesEntityExist(State.logObj) then
            DeleteEntity(State.logObj)
        end
        State.carryingLog = false
        State.logObj = nil
        ClearPedTasks(PlayerPedId())
        SetPedMoveRateOverride(PlayerPedId(), 1.0)
        LocalPlayer.state:set('inv_busy', false, true)
        lib.notify({ description = '[DEBUG] Log cleared!', type = 'success' })
    end, false)

    RegisterCommand('spawnwagon', function()
        local playerPed = PlayerPedId()
        local coords = GetEntityCoords(playerPed)
        local forward = GetEntityForwardVector(playerPed)
        local spawnPos = coords + forward * 5.0

        local model = Config.Wagon.Model
        RequestModel(model)
        while not HasModelLoaded(model) do Wait(10) end

        local wagon = CreateVehicle(model, spawnPos.x, spawnPos.y, spawnPos.z, GetEntityHeading(playerPed), true, true)
        SetEntityAsMissionEntity(wagon, true, true)
        lib.notify({ description = '[DEBUG] Wagon spawned!', type = 'success' })
    end, false)
end

-- ============================================================================
-- RESOURCE START / STOP
-- ============================================================================
AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    Wait(1000)

    PlayerData = RSGCore.Functions.GetPlayerData()
    if PlayerData and PlayerData.citizenid then
        isLoggedIn = true
        TriggerServerEvent('rsg-lumberjack:server:requestGroundItems')
        TriggerServerEvent('rsg-lumberjack:server:requestTrees')
    end

    DebugPrint('rsg-lumberjack client started')
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end

    if State.logObj and DoesEntityExist(State.logObj) then
        DeleteEntity(State.logObj)
    end
    State.carryingLog = false
    ClearPedTasks(PlayerPedId())
    SetPedMoveRateOverride(PlayerPedId(), 1.0)
    LocalPlayer.state:set('inv_busy', false, true)

    for _, entity in pairs(State.otherPlayersCarrying) do
        if DoesEntityExist(entity) then DeleteEntity(entity) end
    end

    for _, entity in pairs(State.groundLogs) do
        if DoesEntityExist(entity) then
            exports['rsg-target']:RemoveTargetEntity(entity)
            DeleteEntity(entity)
        end
    end

    for _, entity in pairs(State.woodPieces) do
        if DoesEntityExist(entity) then
            exports['rsg-target']:RemoveTargetEntity(entity)
            DeleteEntity(entity)
        end
    end

    for _, ent in pairs(State.treeEntities) do
        if DoesEntityExist(ent) then
            exports['rsg-target']:RemoveTargetEntity(ent)
            DeleteEntity(ent)
        end
    end

    for _, logEntities in pairs(State.wagonLogEntities) do
        for _, logData in ipairs(logEntities) do
            if logData.prop and DoesEntityExist(logData.prop) then
                exports['rsg-target']:RemoveTargetEntity(logData.prop)
                DeleteEntity(logData.prop)
            end
        end
    end

    State.otherPlayersCarrying = {}
    State.groundLogs = {}
    State.woodPieces = {}
    State.treeEntities = {}
    State.plantedTrees = {}
    State.wagonLogEntities = {}

    DebugPrint('rsg-lumberjack client stopped - cleanup complete')
end)
