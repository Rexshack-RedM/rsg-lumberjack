-- rsg-lumberjack - Server
-- Ground logs/wood/wagon/carry state is in-memory only and resets on resource
-- restart. Planted trees persist in the database (rsg_lumberjack_trees) so growth
-- progress survives restarts, matching the original script's tree table and
-- growth-scheduling logic.

local RSGCore = exports['rsg-core']:GetCoreObject()
lib.locale()

-- ============================================================================
-- STATE
-- ============================================================================
local PlantedTrees = {}     -- [id] = { id, identifier, x, y, z, heading, model, stage, state, watered, fertilized, next_stage_at, owner_citizenid }
local GroundLogs = {}       -- [id] = { id, x, y, z, owner }
local WoodPieces = {}       -- [id] = { id, x, y, z, owner }
local WagonLoads = {}       -- [wagonNetId] = { logCount = n, positions = { posIndex, ... } }
local CarryingPlayers = {}  -- [src] = true
local PendingActions = {}   -- [src] = { kind, targetId, startedAt, duration }
local LastChopAt = {}       -- [src] = GetGameTimer()

local nextLogId = 1
local nextWoodId = 1

-- ============================================================================
-- HELPERS
-- ============================================================================
local function DebugPrint(...)
    if Config.Debug then
        print('[rsg-lumberjack]', ...)
    end
end

local function Notify(src, descKey, descArgs, type)
    TriggerClientEvent('ox_lib:notify', src, {
        title = locale('notify_title'),
        description = descArgs and locale(descKey, table.unpack(descArgs)) or locale(descKey),
        type = type or 'inform',
        duration = 5000
    })
end

local function NotifySuccess(src, key, args) Notify(src, key, args, 'success') end
local function NotifyError(src, key, args) Notify(src, key, args, 'error') end

local function GetDistance(c1, c2)
    if not c1 or not c2 then return math.huge end
    local dx, dy, dz = c1.x - c2.x, c1.y - c2.y, c1.z - c2.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function IsFiniteNumber(n)
    return type(n) == 'number' and n == n and n ~= math.huge and n ~= -math.huge
end

local function GetPlayerCoords(src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return nil end
    return GetEntityCoords(ped)
end

local function GetPlayerIdentifier(src)
    local Player = RSGCore.Functions.GetPlayer(src)
    if Player and Player.PlayerData and Player.PlayerData.citizenid then
        return Player.PlayerData.citizenid
    end
    for _, id in pairs(GetPlayerIdentifiers(src)) do
        if id:find('license:') == 1 then return id end
    end
    return GetPlayerName(src)
end

local function GetAllGroundLogs()
    local logs = {}
    for _, data in pairs(GroundLogs) do logs[#logs + 1] = data end
    return logs
end

local function GetAllWoodPieces()
    local woods = {}
    for _, data in pairs(WoodPieces) do woods[#woods + 1] = data end
    return woods
end

local function ParseDateTime(str)
    if not str or type(str) ~= 'string' then return nil end
    local y, M, d, h, m, s = string.match(str, '^(%d+)%-(%d+)%-(%d+) (%d+):(%d+):(%d+)$')
    if not y then return nil end
    return os.time({ year = tonumber(y), month = tonumber(M), day = tonumber(d), hour = tonumber(h), min = tonumber(m), sec = tonumber(s) })
end

-- Builds the payload sent to clients for a tree. When a growth timer is
-- actively running, this includes the total stage duration and the seconds
-- remaining *right now* so clients can render a live progress bar without
-- needing to trust/parse the server's wall-clock DATETIME themselves.
local function BuildTreePayload(t)
    local payload = {}
    for k, v in pairs(t) do payload[k] = v end

    if t.state == 'growing' and t.next_stage_at then
        local ts = ParseDateTime(t.next_stage_at)
        local duration = Config.Planting.GrowthDurations[math.max(1, math.min(t.stage, 3))] or 60
        payload.growth_duration = duration
        payload.growth_remaining = ts and math.max(0, ts - os.time()) or duration
    else
        payload.growth_duration = nil
        payload.growth_remaining = nil
    end

    return payload
end

-- ============================================================================
-- TREE PERSISTENCE (rsg_lumberjack_trees) - same schema/columns as the original
-- lumbercompany_trees table, just renamed since it's no longer company-owned.
-- ============================================================================
local function LoadPlantedTreesFromDB()
    DB.fetchAll('SELECT * FROM rsg_lumberjack_trees WHERE state != ?', { 'chopped' }, function(rows)
        PlantedTrees = {}
        for _, r in ipairs(rows or {}) do
            PlantedTrees[r.id] = {
                id = r.id,
                identifier = r.identifier,
                owner_citizenid = r.owner_citizenid,
                x = r.x, y = r.y, z = r.z,
                heading = r.heading,
                model = r.model,
                stage = tonumber(r.stage) or 1,
                state = r.state,
                watered = tonumber(r.watered) or 0,
                fertilized = tonumber(r.fertilized) or 0,
                next_stage_at = r.next_stage_at
            }
        end
        DebugPrint('Loaded', rows and #rows or 0, 'planted trees from database')
    end)
end

CreateThread(function()
    Wait(1000)

    DB.execute([[
        CREATE TABLE IF NOT EXISTS `rsg_lumberjack_trees` (
            `id` INT UNSIGNED NOT NULL AUTO_INCREMENT,
            `identifier` VARCHAR(64) NOT NULL,
            `owner_citizenid` VARCHAR(50) NOT NULL,
            `x` DOUBLE NOT NULL,
            `y` DOUBLE NOT NULL,
            `z` DOUBLE NOT NULL,
            `heading` FLOAT NOT NULL DEFAULT 0,
            `model` VARCHAR(64) NOT NULL DEFAULT 'p_tree_birch_01_sapling',
            `stage` TINYINT UNSIGNED NOT NULL DEFAULT 1,
            `state` ENUM('planted','growing','ready','chopped') NOT NULL DEFAULT 'planted',
            `watered` TINYINT(1) NOT NULL DEFAULT 0,
            `fertilized` TINYINT(1) NOT NULL DEFAULT 0,
            `planted_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
            `next_stage_at` DATETIME NULL,
            PRIMARY KEY (`id`),
            INDEX `idx_stage` (`stage`),
            INDEX `idx_state` (`state`),
            INDEX `idx_owner` (`owner_citizenid`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    ]])

    LoadPlantedTreesFromDB()
end)

-- ============================================================================
-- USEABLE ITEMS
-- ============================================================================
RSGCore.Functions.CreateUseableItem(Config.Planting.SeedItem, function(src, item)
    TriggerClientEvent('rsg-lumberjack:client:useSeed', src)
end)

RSGCore.Functions.CreateUseableItem(Config.Planting.WaterItem, function(src, item)
    TriggerClientEvent('rsg-lumberjack:client:useWater', src)
end)

-- ============================================================================
-- GROUND ITEMS / TREES REQUEST (on player join)
-- ============================================================================
RegisterNetEvent('rsg-lumberjack:server:requestGroundItems', function()
    local src = source
    TriggerClientEvent('rsg-lumberjack:client:syncGroundLogs', src, GetAllGroundLogs())
    TriggerClientEvent('rsg-lumberjack:client:syncWoodPieces', src, GetAllWoodPieces())

    local carryingList = {}
    for serverId, _ in pairs(CarryingPlayers) do
        carryingList[#carryingList + 1] = serverId
    end
    TriggerClientEvent('rsg-lumberjack:client:syncCarryingPlayers', src, carryingList)
end)

RegisterNetEvent('rsg-lumberjack:server:requestTrees', function()
    local src = source
    local list = {}
    for _, t in pairs(PlantedTrees) do list[#list + 1] = BuildTreePayload(t) end
    TriggerClientEvent('rsg-lumberjack:client:setTrees', src, list)
end)

-- ============================================================================
-- SECURE CHOP ACTION (wild tree / ground log / planted tree)
-- Golden rule: the client never unilaterally decides "I chopped something".
-- It must request authorization first, then report completion; the server
-- validates axe ownership, cooldown, carry-state, proximity (where a real
-- server-tracked target exists) and elapsed time before granting anything.
-- ============================================================================
local VALID_KINDS = { wildtree = true, groundlog = true, plantedtree = true }

local function GetDurationForKind(kind)
    if kind == 'groundlog' then return Config.Chopping.LogChopDuration end
    return Config.Chopping.TreeChopDuration
end

RSGCore.Functions.CreateCallback('rsg-lumberjack:server:requestChop', function(source, cb, kind, targetId, clientCoords)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player then return cb({ ok = false }) end

    if not VALID_KINDS[kind] then return cb({ ok = false, reason = 'invalid_request' }) end

    -- Cooldown
    local last = LastChopAt[src] or 0
    if (GetGameTimer() - last) < Config.Chopping.ChopCooldownMs then
        local remaining = math.ceil((Config.Chopping.ChopCooldownMs - (GetGameTimer() - last)) / 1000)
        return cb({ ok = false, reason = 'cooldown_wait', args = { remaining } })
    end

    -- Already mid-action
    local pending = PendingActions[src]
    if pending and (GetGameTimer() - pending.startedAt) < (pending.duration + Config.Chopping.ActionTimeoutMs) then
        return cb({ ok = false, reason = 'busy' })
    end

    -- Wild/planted tree chops grant a carried log - can't already be carrying one
    if kind ~= 'groundlog' and CarryingPlayers[src] then
        return cb({ ok = false, reason = 'already_carrying' })
    end

    -- Axe check
    if Config.Chopping.RequireAxe then
        local axeItem = Player.Functions.GetItemByName(Config.Chopping.AxeItem)
        if not axeItem or (axeItem.amount or axeItem.count or 0) <= 0 then
            return cb({ ok = false, reason = 'need_axe' })
        end
    end

    if kind == 'groundlog' then
        local logData = GroundLogs[targetId]
        if not logData then return cb({ ok = false, reason = 'log_not_found' }) end
        local pCoords = GetPlayerCoords(src)
        if GetDistance(pCoords, vector3(logData.x, logData.y, logData.z)) > (Config.Chopping.InteractDistance + 2.0) then
            return cb({ ok = false, reason = 'not_nearby' })
        end
    elseif kind == 'plantedtree' then
        local t = PlantedTrees[targetId]
        if not t then return cb({ ok = false, reason = 'tree_not_found' }) end
        if t.stage < 4 or t.state ~= 'ready' then return cb({ ok = false, reason = 'tree_not_ready' }) end
        local pCoords = GetPlayerCoords(src)
        if GetDistance(pCoords, vector3(t.x, t.y, t.z)) > (Config.Chopping.InteractDistance + 2.0) then
            return cb({ ok = false, reason = 'not_nearby' })
        end
    else -- wildtree: no server-tracked entity exists for static world props, so we can only
        -- sanity-check the coordinates the client reports it is standing at. The
        -- cooldown/axe/token/elapsed-time checks below are what actually prevent farming.
        if not (clientCoords and IsFiniteNumber(clientCoords.x) and IsFiniteNumber(clientCoords.y) and IsFiniteNumber(clientCoords.z)) then
            return cb({ ok = false, reason = 'invalid_request' })
        end
    end

    local duration = GetDurationForKind(kind)
    PendingActions[src] = { kind = kind, targetId = targetId, startedAt = GetGameTimer(), duration = duration }
    cb({ ok = true, duration = duration })
end)

RegisterNetEvent('rsg-lumberjack:server:completeChop', function(kind, targetId)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player then return end

    local pending = PendingActions[src]
    PendingActions[src] = nil -- single use, always clear regardless of outcome

    if not pending or pending.kind ~= kind or pending.targetId ~= targetId then
        NotifyError(src, 'invalid_request')
        return
    end

    local elapsed = GetGameTimer() - pending.startedAt
    if elapsed < (pending.duration - 1500) then
        -- finished suspiciously fast for the configured duration
        NotifyError(src, 'invalid_request')
        return
    end
    if elapsed > (pending.duration + Config.Chopping.ActionTimeoutMs) then
        NotifyError(src, 'action_expired')
        return
    end

    LastChopAt[src] = GetGameTimer()

    -- Server rolls the axe-break chance, never the client
    local axeBroke = false
    if Config.Chopping.RequireAxe and Config.Chopping.AxeBreakChance > 0 and math.random(100) <= Config.Chopping.AxeBreakChance then
        local axeItem = Player.Functions.GetItemByName(Config.Chopping.AxeItem)
        if axeItem and (axeItem.amount or axeItem.count or 0) > 0 then
            Player.Functions.RemoveItem(Config.Chopping.AxeItem, 1)
            TriggerClientEvent('rsg-inventory:client:ItemBox', src, RSGCore.Shared.Items[Config.Chopping.AxeItem], 'remove', 1)
            axeBroke = true
        end
    end

    if kind == 'groundlog' then
        local logData = GroundLogs[targetId]
        if not logData then
            NotifyError(src, 'log_not_found')
            return
        end

        GroundLogs[targetId] = nil
        TriggerClientEvent('rsg-lumberjack:client:removeGroundLog', -1, targetId)

        local woodCount = Config.Items.WoodAmountFromLog or 4
        for _ = 1, woodCount do
            local woodId = nextWoodId
            nextWoodId = nextWoodId + 1
            local offsetX = (math.random() - 0.5) * (Config.Items.SpawnRadius or 3.0)
            local offsetY = (math.random() - 0.5) * (Config.Items.SpawnRadius or 3.0)
            local woodData = { id = woodId, x = logData.x + offsetX, y = logData.y + offsetY, z = logData.z, owner = src }
            WoodPieces[woodId] = woodData
            TriggerClientEvent('rsg-lumberjack:client:addWoodPiece', -1, woodData)
        end

        NotifySuccess(src, 'chop_success_log')
    else
        -- wildtree / plantedtree: grant a carried log
        if kind == 'plantedtree' then
            local t = PlantedTrees[targetId]
            if not t or t.stage < 4 or t.state ~= 'ready' then
                NotifyError(src, 'tree_not_ready')
                return
            end
            PlantedTrees[targetId] = nil
            DB.execute('DELETE FROM rsg_lumberjack_trees WHERE id = ?', { targetId })
            TriggerClientEvent('rsg-lumberjack:client:removeTree', -1, targetId)
        end

        CarryingPlayers[src] = true
        TriggerClientEvent('rsg-lumberjack:client:playerStartedCarrying', -1, src)
        NotifySuccess(src, 'chop_success_tree')
    end

    if axeBroke then
        NotifyError(src, 'axe_broken')
    end

    DebugPrint('Player', src, 'completed chop', kind, targetId)
end)

-- ============================================================================
-- CARRYING / GROUND LOG SYSTEM
-- ============================================================================
RegisterNetEvent('rsg-lumberjack:server:dropLog', function(x, y, z)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player then return end

    if not CarryingPlayers[src] then
        NotifyError(src, 'not_carrying')
        return
    end

    if not (IsFiniteNumber(x) and IsFiniteNumber(y) and IsFiniteNumber(z)) then return end

    CarryingPlayers[src] = nil
    TriggerClientEvent('rsg-lumberjack:client:playerStoppedCarrying', -1, src)

    local logId = nextLogId
    nextLogId = nextLogId + 1
    local logData = { id = logId, x = x, y = y, z = z, owner = src }
    GroundLogs[logId] = logData

    TriggerClientEvent('rsg-lumberjack:client:addGroundLog', -1, logData)
    NotifySuccess(src, 'log_dropped')
    DebugPrint('Player', src, 'dropped log', logId)
end)

RegisterNetEvent('rsg-lumberjack:server:pickupLog', function(logId)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player then return end

    if CarryingPlayers[src] then
        NotifyError(src, 'already_carrying')
        return
    end

    local logData = GroundLogs[logId]
    if not logData then
        NotifyError(src, 'log_not_found')
        return
    end

    local pCoords = GetPlayerCoords(src)
    if GetDistance(pCoords, vector3(logData.x, logData.y, logData.z)) > (Config.Chopping.InteractDistance + 2.0) then
        NotifyError(src, 'not_nearby')
        return
    end

    GroundLogs[logId] = nil
    TriggerClientEvent('rsg-lumberjack:client:removeGroundLog', -1, logId)

    CarryingPlayers[src] = true
    TriggerClientEvent('rsg-lumberjack:client:playerStartedCarrying', -1, src)
    NotifySuccess(src, 'log_picked_up')

    DebugPrint('Player', src, 'picked up log', logId)
end)

RegisterNetEvent('rsg-lumberjack:server:pickupWood', function(woodId)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player then return end

    local woodData = WoodPieces[woodId]
    if not woodData then
        NotifyError(src, 'wood_not_found')
        return
    end

    local pCoords = GetPlayerCoords(src)
    if GetDistance(pCoords, vector3(woodData.x, woodData.y, woodData.z)) > (Config.Chopping.InteractDistance + 2.0) then
        NotifyError(src, 'not_nearby')
        return
    end

    WoodPieces[woodId] = nil
    TriggerClientEvent('rsg-lumberjack:client:removeWoodPiece', -1, woodId)

    Player.Functions.AddItem(Config.Items.Wood, 1)
    TriggerClientEvent('rsg-inventory:client:ItemBox', src, RSGCore.Shared.Items[Config.Items.Wood], 'add', 1)
    NotifySuccess(src, 'wood_picked_up')

    DebugPrint('Player', src, 'picked up wood', woodId)
end)

-- ============================================================================
-- TREE PLANTING / GROWING SYSTEM (plant anywhere; persisted to the database)
-- ============================================================================
RegisterNetEvent('rsg-lumberjack:server:plantTree', function(pos, heading)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player then return end

    if not (pos and IsFiniteNumber(pos.x) and IsFiniteNumber(pos.y) and IsFiniteNumber(pos.z)) then
        NotifyError(src, 'invalid_location')
        return
    end
    heading = tonumber(heading) or 0.0

    local identifier = GetPlayerIdentifier(src)
    local citizenid = Player.PlayerData.citizenid

    local ownedCount = 0
    for _, t in pairs(PlantedTrees) do
        if t.owner_citizenid == citizenid and t.state ~= 'chopped' then
            ownedCount = ownedCount + 1
        end
        local dist = GetDistance(vector3(t.x, t.y, t.z), vector3(pos.x, pos.y, pos.z))
        if dist < Config.Planting.MinPlantDistance then
            NotifyError(src, 'too_close_to_tree')
            return
        end
    end

    if ownedCount >= Config.Planting.MaxTreesPerPlayer then
        NotifyError(src, 'max_trees_reached', { Config.Planting.MaxTreesPerPlayer })
        return
    end

    local seedItem = Player.Functions.GetItemByName(Config.Planting.SeedItem)
    if not seedItem or (seedItem.amount or seedItem.count or 0) <= 0 then
        NotifyError(src, 'need_seed')
        return
    end
    Player.Functions.RemoveItem(Config.Planting.SeedItem, 1)
    TriggerClientEvent('rsg-inventory:client:ItemBox', src, RSGCore.Shared.Items[Config.Planting.SeedItem], 'remove', 1)

    local model = Config.Planting.StageModels[1]

    DB.insert_id(
        'INSERT INTO rsg_lumberjack_trees (identifier, owner_citizenid, x, y, z, heading, model, stage, state, watered, fertilized) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        { identifier, citizenid, pos.x, pos.y, pos.z, heading, model, 1, 'planted', 0, 0 },
        function(newId)
            local id = tonumber(newId) or 0
            local tree = {
                id = id,
                identifier = identifier,
                owner_citizenid = citizenid,
                x = pos.x, y = pos.y, z = pos.z,
                heading = heading,
                model = model,
                stage = 1,
                state = 'planted',
                watered = 0,
                fertilized = 0,
                next_stage_at = nil
            }
            PlantedTrees[id] = tree
            TriggerClientEvent('rsg-lumberjack:client:updateTreeVisual', -1, BuildTreePayload(tree))
            NotifySuccess(src, 'tree_planted')
            DebugPrint('Player', src, 'planted tree', id)
        end
    )
end)

-- Mirrors the original script's MaybeScheduleGrowth: only starts the growth
-- timer once the watering requirement is satisfied, then persists it.
function MaybeScheduleGrowth(id)
    local t = PlantedTrees[id]
    if not t or t.stage >= 4 then return end

    local canGrow = Config.Debug or (not Config.Planting.RequireWater or t.watered == 1)
    if not canGrow then return end

    local duration = Config.Planting.GrowthDurations[math.max(1, math.min(t.stage, 3))] or 60
    local nextAt = os.date('%Y-%m-%d %H:%M:%S', os.time() + duration)
    t.next_stage_at = nextAt
    t.state = 'growing'
    DB.execute('UPDATE rsg_lumberjack_trees SET state = ?, next_stage_at = ? WHERE id = ?', { 'growing', nextAt, id })
    TriggerClientEvent('rsg-lumberjack:client:updateTreeVisual', -1, BuildTreePayload(t))
    DebugPrint('Tree', id, 'scheduled for growth at', nextAt)
end

RegisterNetEvent('rsg-lumberjack:server:waterTree', function(id)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player then return end

    local t = PlantedTrees[id]
    if not t then
        NotifyError(src, 'tree_not_found')
        return
    end
    if t.stage >= 4 then
        NotifyError(src, 'tree_already_grown')
        return
    end

    local pCoords = GetPlayerCoords(src)
    if GetDistance(pCoords, vector3(t.x, t.y, t.z)) > (Config.Chopping.InteractDistance + 2.0) then
        NotifyError(src, 'not_nearby')
        return
    end

    if Config.Planting.RequireWater then
        local waterItem = Player.Functions.GetItemByName(Config.Planting.WaterItem)
        if not waterItem or (waterItem.amount or waterItem.count or 0) <= 0 then
            NotifyError(src, 'need_water')
            return
        end
        Player.Functions.RemoveItem(Config.Planting.WaterItem, 1)
        TriggerClientEvent('rsg-inventory:client:ItemBox', src, RSGCore.Shared.Items[Config.Planting.WaterItem], 'remove', 1)
    end

    t.watered = 1
    DB.execute('UPDATE rsg_lumberjack_trees SET watered = 1 WHERE id = ?', { id })
    MaybeScheduleGrowth(id) -- broadcasts the updated tree (with a fresh growth timer) itself
    NotifySuccess(src, 'tree_watered')
end)

CreateThread(function()
    while true do
        Wait(60 * 1000)
        local changed = {}
        local now = os.time()

        for id, t in pairs(PlantedTrees) do
            if t.state ~= 'chopped' and t.stage < 4 and t.next_stage_at then
                local ts = ParseDateTime(t.next_stage_at)
                if ts and now >= ts then
                    t.stage = t.stage + 1
                    if t.stage >= 4 then
                        t.stage = 4
                        t.state = 'ready'
                        t.next_stage_at = nil
                    else
                        t.state = 'growing'
                        t.next_stage_at = nil
                    end
                    t.watered = 0
                    t.fertilized = 0
                    DB.execute('UPDATE rsg_lumberjack_trees SET stage = ?, state = ?, next_stage_at = NULL, watered = 0, fertilized = 0 WHERE id = ?',
                        { t.stage, t.state, id })
                    changed[#changed + 1] = t
                end
            end
        end

        for _, t in ipairs(changed) do
            TriggerClientEvent('rsg-lumberjack:client:updateTreeVisual', -1, BuildTreePayload(t))
            if t.stage == 4 and t.state == 'ready' then
                local ownerPlayer = RSGCore.Functions.GetPlayerByCitizenId(t.owner_citizenid)
                if ownerPlayer then
                    NotifySuccess(ownerPlayer.PlayerData.source, 'tree_ready')
                end
            end
        end
    end
end)

-- ============================================================================
-- WAGON SYSTEM (load / unload / sell at multiple locations)
-- ============================================================================
local function GetWagonEntity(wagonNetId)
    local wagon = NetworkGetEntityFromNetworkId(wagonNetId)
    if not wagon or wagon == 0 or not DoesEntityExist(wagon) then return nil end
    return wagon
end

RegisterNetEvent('rsg-lumberjack:server:addLogToWagon', function(wagonNetId)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player then return end

    if not CarryingPlayers[src] then
        NotifyError(src, 'not_carrying')
        return
    end

    local wagon = GetWagonEntity(wagonNetId)
    if not wagon then
        NotifyError(src, 'error_generic')
        return
    end

    local pCoords = GetPlayerCoords(src)
    if GetDistance(pCoords, GetEntityCoords(wagon)) > Config.Wagon.LoadDistance then
        NotifyError(src, 'not_nearby')
        return
    end

    if not WagonLoads[wagonNetId] then
        WagonLoads[wagonNetId] = { logCount = 0, positions = {} }
    end
    local load = WagonLoads[wagonNetId]

    if load.logCount >= Config.Wagon.MaxLogsOnWagon then
        NotifyError(src, 'wagon_full')
        return
    end

    local posIndex = load.logCount + 1
    load.logCount = posIndex
    table.insert(load.positions, posIndex)

    CarryingPlayers[src] = nil
    TriggerClientEvent('rsg-lumberjack:client:playerStoppedCarrying', -1, src)
    TriggerClientEvent('rsg-lumberjack:client:logAddedToWagon', -1, wagonNetId, posIndex, src)

    NotifySuccess(src, 'log_loaded', { load.logCount, Config.Wagon.MaxLogsOnWagon })
    DebugPrint('Wagon', wagonNetId, 'log count now', load.logCount)
end)

RegisterNetEvent('rsg-lumberjack:server:removeLogFromWagon', function(wagonNetId)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player then return end

    if CarryingPlayers[src] then
        NotifyError(src, 'already_carrying')
        return
    end

    local load = WagonLoads[wagonNetId]
    if not load or load.logCount <= 0 then
        NotifyError(src, 'not_nearby')
        return
    end

    local wagon = GetWagonEntity(wagonNetId)
    if not wagon then
        NotifyError(src, 'error_generic')
        return
    end

    local pCoords = GetPlayerCoords(src)
    if GetDistance(pCoords, GetEntityCoords(wagon)) > Config.Wagon.LoadDistance then
        NotifyError(src, 'not_nearby')
        return
    end

    local posIndex = table.remove(load.positions)
    if not posIndex then
        NotifyError(src, 'not_nearby')
        return
    end
    load.logCount = load.logCount - 1

    CarryingPlayers[src] = true
    TriggerClientEvent('rsg-lumberjack:client:logRemovedFromWagon', -1, wagonNetId, posIndex, src)
    TriggerClientEvent('rsg-lumberjack:client:playerStartedCarrying', -1, src)

    NotifySuccess(src, 'log_unloaded')
    DebugPrint('Wagon', wagonNetId, 'log removed, count now', load.logCount)
end)

RegisterNetEvent('rsg-lumberjack:server:requestWagonSync', function(wagonNetId)
    local src = source
    local load = WagonLoads[wagonNetId]
    TriggerClientEvent('rsg-lumberjack:client:syncWagonLogs', src, wagonNetId, load and load.positions or {})
end)

RSGCore.Functions.CreateCallback('rsg-lumberjack:server:getWagonLogs', function(source, cb, wagonNetId)
    local load = WagonLoads[wagonNetId]
    cb(load and { logCount = load.logCount, positions = load.positions } or { logCount = 0, positions = {} })
end)

RegisterNetEvent('rsg-lumberjack:server:sellWagonLoad', function(wagonNetId, locationIndex)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player then return end

    local wagon = GetWagonEntity(wagonNetId)
    if not wagon or GetEntityModel(wagon) ~= Config.Wagon.Model then
        NotifyError(src, 'need_wagon')
        return
    end

    -- Player must actually be seated in the wagon they're claiming to sell
    local ped = GetPlayerPed(src)
    if GetVehiclePedIsIn(ped, false) ~= wagon then
        NotifyError(src, 'need_wagon')
        return
    end

    local load = WagonLoads[wagonNetId]
    if not load or load.logCount < Config.Wagon.MaxLogsOnWagon then
        NotifyError(src, 'wagon_not_full', { load and load.logCount or 0, Config.Wagon.MaxLogsOnWagon })
        return
    end

    -- Never trust a client-supplied price - always resolve the price from a
    -- server-side config entry whose radius actually contains the wagon.
    local wagonCoords = GetEntityCoords(wagon)
    local location = nil
    if type(locationIndex) == 'number' and Config.WagonSellLocations[locationIndex] then
        local candidate = Config.WagonSellLocations[locationIndex]
        if GetDistance(wagonCoords, candidate.coords) <= candidate.radius then
            location = candidate
        end
    end
    if not location then
        for _, candidate in ipairs(Config.WagonSellLocations) do
            if GetDistance(wagonCoords, candidate.coords) <= candidate.radius then
                location = candidate
                break
            end
        end
    end

    if not location then
        NotifyError(src, 'not_at_sell_location')
        return
    end

    Player.Functions.AddMoney('cash', location.price, 'lumber-wagon-sale')
    WagonLoads[wagonNetId] = nil
    TriggerClientEvent('rsg-lumberjack:client:resetWagon', -1, wagonNetId)

    NotifySuccess(src, 'wagon_sold', { location.price })
    DebugPrint('Player', src, 'sold wagon', wagonNetId, 'at', location.name, 'for', location.price)
end)

-- ============================================================================
-- CLEANUP
-- ============================================================================
AddEventHandler('playerDropped', function()
    local src = source
    if CarryingPlayers[src] then
        CarryingPlayers[src] = nil
        TriggerClientEvent('rsg-lumberjack:client:playerStoppedCarrying', -1, src)
    end
    PendingActions[src] = nil
    LastChopAt[src] = nil
end)

AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    Wait(500)
    GroundLogs = {}
    WoodPieces = {}
    WagonLoads = {}
    CarryingPlayers = {}
    PendingActions = {}
    LastChopAt = {}
    nextLogId, nextWoodId = 1, 1
    LoadPlantedTreesFromDB()
    DebugPrint('rsg-lumberjack server started (ephemeral state reset, trees reloaded from DB)')
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    GroundLogs = {}
    WoodPieces = {}
    WagonLoads = {}
    CarryingPlayers = {}
    PendingActions = {}
    DebugPrint('rsg-lumberjack server stopped - state cleared')
end)
