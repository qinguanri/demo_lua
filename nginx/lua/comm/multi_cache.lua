local lrucache     = require "resty.lrucache"
local lock_c       = require "resty.lock"
local common       = require "lua.comm.common"


local json_decode  = common.json_decode
local json_encode  = common.json_encode
local shm_name     = "cache_ngx"
local share_memory = ngx.shared[shm_name]
local worker_cache = lrucache.new(1024*5)


local _M = { _VERSION = '0.01' }


function _M.worker(opt, fun, ...)
    local key           = opt.key
    local exp_time_succ = opt.exp_time_succ or 5
    local exp_time_fail = opt.exp_time_fail or 1

    local t = worker_cache:get(key)
    if t then
        return t.res, t.err
    end
    ngx.log(ngx.INFO, "CACHE MISSING")

    -- cache miss!
    local lock = lock_c:new(shm_name)
    local elapsed, err = lock:lock("cache_worker_" .. key .. ngx.worker.pid())
    if not elapsed then
        return nil, "get the worker parallels lock fail"
    end

    -- someone might have already put the value into the cache
    -- so we check it here again:
    t = worker_cache:get(key)
    if t then
        lock:unlock()

        return t.res, t.err
    end

    res, err = fun(...)

    -- free lock
    lock:unlock()

    worker_cache:set(key, {res=res, err=err},
                          err and exp_time_fail or exp_time_succ)

    return res, err
end


local function _shm(opt, fun, ...)
    local key           = "shm_cache#" .. opt.key
    local exp_time_succ = opt.exp_time_succ or 5
    local exp_time_fail = opt.exp_time_fail or 1

    local t = share_memory:get(key)
    if t then
        t = json_decode(t) or {}
        return t.res, t.err
    end

    -- cache miss!
    local lock = lock_c:new(shm_name)
    local elapsed, err = lock:lock("cache_shm_" .. key .. ngx.worker.pid())
    if not elapsed then
        return nil, "get the shm parallels lock fail"
    end

    -- someone might have already put the value into the cache
    -- so we check it here again:
    t = share_memory:get(key)
    if t then
        lock:unlock()

        t = json_decode(t) or {}
        return t.res, t.err
    end

    local res, err
    if fun then
        res, err = fun(...)
    else
        lock:unlock()
        return nil, "cache missing"
    end

    -- free lock
    lock:unlock()

    share_memory:set(key, json_encode({res=res, err=err}),
                          err and exp_time_fail or exp_time_succ)

    return res, err
end


function _M.shm(opt, fun, ...)
    local res, err = _shm(opt, fun, ...)

    if err then
        -- use the old cache if error
        local values = share_memory:get_stale(key)
        if values then
          values   = json_decode(values) or {}
          return values.res, values.err
        end
    end

    return res, err
end


function _M.worker_shm(opt, fun, ...)
    return _M.worker(opt, _M.shm, opt, fun, ...)
end


return _M
