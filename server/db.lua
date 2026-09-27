-- Database wrapper for rsg-lumberjack
-- Supports both oxmysql and mysql-async

DB = {}

local function detectDatabase()
    if GetResourceState('oxmysql') == 'started' then
        return 'oxmysql'
    elseif GetResourceState('mysql-async') == 'started' or GetResourceState('ghmattimysql') == 'started' then
        return 'mysql-async'
    else
        if Config.Debug then print('[rsg-lumberjack] ERROR: No MySQL resource detected!') end
        return nil
    end
end

local dbType = detectDatabase()

if dbType == 'oxmysql' then
    DB.execute = function(query, params, cb)
        exports.oxmysql:execute(query, params or {}, function(result)
            if cb then cb(result) end
        end)
    end

    DB.fetchAll = function(query, params, cb)
        exports.oxmysql:fetch(query, params or {}, function(result)
            if cb then cb(result) end
        end)
    end

    DB.fetchScalar = function(query, params, cb)
        exports.oxmysql:scalar(query, params or {}, function(result)
            if cb then cb(result) end
        end)
    end

    DB.insert_id = function(query, params, cb)
        exports.oxmysql:insert(query, params or {}, function(id)
            if cb then cb(id) end
        end)
    end

elseif dbType == 'mysql-async' then
    DB.execute = function(query, params, cb)
        exports['mysql-async']:mysql_execute(query, params or {}, function(result)
            if cb then cb(result) end
        end)
    end

    DB.fetchAll = function(query, params, cb)
        exports['mysql-async']:mysql_fetch_all(query, params or {}, function(result)
            if cb then cb(result) end
        end)
    end

    DB.fetchScalar = function(query, params, cb)
        exports['mysql-async']:mysql_fetch_scalar(query, params or {}, function(result)
            if cb then cb(result) end
        end)
    end

    DB.insert_id = function(query, params, cb)
        exports['mysql-async']:mysql_insert(query, params or {}, function(id)
            if cb then cb(id) end
        end)
    end
else
    DB.execute = function(query, params, cb) if cb then cb(0) end end
    DB.fetchAll = function(query, params, cb) if cb then cb({}) end end
    DB.fetchScalar = function(query, params, cb) if cb then cb(nil) end end
    DB.insert_id = function(query, params, cb) if cb then cb(0) end end
end
