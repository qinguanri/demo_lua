local pcall, type = pcall, type
local ngx = ngx
local resty_lrucache = require "resty.lrucache"
local resty_lrucache_ffi = require "resty.lrucache.pureffi"
local ngx_log = ngx.log
local ngx_DEBUG = ngx.DEBUG
local ngx_ERR = ngx.ERR
local cjson = require(require("ffi").os=="Windows" and "resty.dkjson" or "cjson")
local json_encode = cjson.encode
local json_decode = cjson.decode
local ngx_time = ngx.time

local ok, tab_new = pcall(require, "table.new")
if not ok then
    tab_new = function (narr, nrec) return {} end
end

local _M = tab_new(0, 7)
_M._VERSION = "0.01"
local mt = { __index = _M }


local DEBUG = false

local default_size = 200
local dict_types = {
    ["boolean"] = true,
    ["number"] = true,
    ["string"] = true,
    ["nil"] = true
}


local function safe_json_encode(str)
    local ok, json = pcall(json_encode, str)
    if ok then
        return json
    else
        return nil, json
    end
end


local function safe_json_decode(json)
    local ok, json = pcall(json_decode, json)
    if ok then
        return json
    else
        return nil, json
    end
end


local function init_lru_cache(size, pureffi, loadfactor)
    local resty_lrucache = resty_lrucache
    if pureffi == true then
        resty_lrucache = resty_lrucache_ffi
    end

    local lrucache, err = resty_lrucache.new(size or default_size, loadfactor or 0.5)
    if not lrucache then
        return error("failed to create the cache: " .. (err or "unknown"))
    end
    return lrucache
end


function _M.new(_, opts)
    local opts = opts or {}
    if not opts.dict then
        return error("No dictionary specified")
    end

    local dict
    if type(opts.dict) == 'string' then
        dict = ngx.shared[opts.dict]
        if not dict then
            return error("Shared dictionary '" .. opts.dict .. "' not found")
        end
    else
        -- Assume this is a shared dictionary object not a string name
        dict = opts.dict
    end

    local self = {
        -- Retain options for later
        opts = opts,
        -- (Un)serialise functions
        serialiser =   (opts.serialiser   or safe_json_encode),
        unserialiser = (opts.unserialiser or safe_json_decode),
        -- Cache objects
        dict = dict,
        lru = init_lru_cache(opts.size, opts.pureffi, opts.loadfactor)
    }

    return setmetatable(self, mt)
end


function _M.set(self, key, value, ttl)
    -- Set the raw value in the lrucache
    if DEBUG then ngx_log(ngx_DEBUG, "Saving key '", key, "' with ttl ", (ttl or 0), "s...") end
    self.lru:set(key, value, ttl)
    if DEBUG then ngx_log(ngx_DEBUG, "Saved to LRU") end

    -- Shared dictionary does not accept a nil ttl
    local ttl = ttl or 0
    local flags = 0

    -- Attempt to serialise the value if not valid for a shared dict
    if not dict_types[type(value)] then
        if DEBUG then ngx_log(ngx_DEBUG, "Attempting to serialise...") end
        local data, err = self.serialiser(value)
        if not data then
            return nil, err
        end
        value = data
        flags = 1 -- set flag to indicate this value should be unserialised
        if DEBUG then ngx_log(ngx_DEBUG, "Serialised") end
    end

    -- Save value
    local success, err, forcible = self.dict:set(key, value, ttl, flags)
    if not success then
        return nil, "Error saving to shared dictionary for key '"..key.."': "..err
    end
    if DEBUG then ngx_log(ngx_DEBUG, "Saved to dictionary") end

    -- Save expiry time
    if ttl ~= 0 then
        local expires = ngx_time() + ttl
        local success, err, forcible = self.dict:set(key.."|tlc_expires", expires, ttl)
        if not success then
            return nil, "Error saving expiry time to shared dictionary for key '"..key.."': "..err
        end
        if DEBUG then ngx_log(ngx_DEBUG, "Saved expiry '", expires, "'' to shared dictionary") end
    end

    return true
end


function _M.get(self, key)
    -- Check LRU cache
    local data, stale_data = self.lru:get(key)
    if data then
        if DEBUG then ngx_log(ngx_DEBUG, "Found key '", key, "' in LRU cache") end
        return data, stale_data
    elseif DEBUG then
        ngx_log(ngx_DEBUG, "Key '", key, "' not found in LRU cache: ", tostring(stale_data))
    end

    -- Fall back to shared dictionary
    local data, flags = self.dict:get(key)
    if data then
        if DEBUG then ngx_log(ngx_DEBUG, "Found key '", key, "' in shared dictionary") end
        -- Unserialise
        if flags == 1 then
            if DEBUG then ngx_log(ngx_DEBUG, "Attempting to unserialise...") end
            local ok, err = self.unserialiser(data)
            if not ok then
                if DEBUG then ngx_log(ngx_DEBUG, "Unserialise failed: ", err) end
                return nil, err
            end
            data = ok
            if DEBUG then ngx_log(ngx_DEBUG, "Unserialised") end
        end

        -- Calculate remaining TTL and populate the LRU cache
        local expiry, err = self.dict:get(key.."|tlc_expires")
        local ttl
        if expiry then
            ttl = expiry - ngx_time()
            if DEBUG then ngx_log(ngx_DEBUG, "Calculated ttl: ", ttl) end
        end

        -- Repopulate lru cache
        self.lru:set(key, data, ttl)
        if DEBUG then ngx_log(ngx_DEBUG, "Repopulated lru cache") end

        return data
    end
    return nil, flags
end


function _M.delete(self, key)
    self.lru:delete(key)
    if DEBUG then ngx_log(ngx_DEBUG, "Deleted key '", key, "' from lru cache") end
    self.dict:delete(key)
    if DEBUG then ngx_log(ngx_DEBUG, "Deleted key '", key, "' from shared dictionary") end
end


function _M.flush(self, hard)
    self.lru = init_lru_cache(self.opts.size, self.opts.pureffi, self.opts.loadfactor)
    if DEBUG then ngx_log(ngx_DEBUG, "Initialised ", ("ffi " and self.opts.pureffi or ""), "lrucache with size ", (self.opts.size or default_size)) end

    if self.dict then
        if DEBUG then ngx_log(ngx_DEBUG, "Flushing dictionary") end
        self.dict:flush_all()
        if hard then
            local flushed = self.dict:flush_expired()
            if DEBUG then ngx_log(ngx_DEBUG, "Flushed ", flushed, " keys from memory") end
        end
    end
end


function _M._debug(debug)
    DEBUG = debug
end


return _M
