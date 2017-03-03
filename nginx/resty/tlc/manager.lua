local tbl_insert = table.insert
local tlc_cache = require "resty.tlc.cache"

local ok, tab_new = pcall(require, "table.new")
if not ok then
    tab_new = function (narr, nrec) return {} end
end

local _M = tab_new(0, 4)
_M._VERSION = "0.01"

local instances = {}


function _M.new(name, opts)
    -- Initialise a new 2 layer cache instance and save it to the global instances table
    if not name and type(name) ~= "string" and type(name) ~= "number" then
        return error("Must set an alphanumeric instance name")
    end

    local instance, err = tlc_cache:new(opts)
    if not instance then
        return nil, err
    end

    instances[name] = instance
    return instance
end


function _M.get(name)
    return instances[name]
end


function _M.delete(name)
    -- TODO: Flush here too?
    instances[name] = nil
end


function _M.list()
    local ret = {}
    for name, instance in pairs(instances) do
        tbl_insert(ret, name)
    end
    return ret
end


return _M
