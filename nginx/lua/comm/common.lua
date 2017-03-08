module("lua.comm.common", package.seeall)

local ffi = require "ffi"
local json   = require(require("ffi").os=="Windows" and "resty.dkjson" or "cjson")
local lock   = require "resty.lock"

function get_cache(key)
    local cache_ngx = ngx.shared.cache_ngx
    local value = cache_ngx:get(key)
    return value
end

function set_cache(key, value, exptime)
    if not exptime then
        exptime = 0
    end
    local cache_ngx = ngx.shared.cache_ngx
    local succ, err, forcible = cache_ngx:set(key, value, exptime)
    return succ, err
end

function del_cache(key)
    local cache_ngx = ngx.shared.cache_ngx
    cache_ngx:delete(key)
end

-- {
--   key="...",           cache key
--   exp_time=0,          default expire time
--   exp_time_fail=3,     success expire time
--   exp_time_succ=60*30, failed  expire time
--   lock={...}           lock opsts(resty.lock)
-- }
function get_data_with_cache( opts, fun, ... )
  local ngx_dict_name = "cache_ngx"

  -- get from cache
  local cache_ngx = ngx.shared[ngx_dict_name]
  local values = cache_ngx:get(opts.key)
  if values then
    values = json_decode(values)
    return values.res, values.err
  end

  -- cache miss!
  local lock = lock:new(ngx_dict_name, opts.lock)
  local elapsed, err = lock:lock("lock_" .. opts.key)
  if not elapsed then
    return nil, "get data with cache lock fail err: " .. err
  end

  -- someone might have already put the value into the cache
  -- so we check it here again:
  values = cache_ngx:get(opts.key)
  if values then
    lock:unlock()

    values = json_decode(values)
    return values.res, values.err
  end

  -- get data
  local exp_time = opts.exp_time or 0 -- default 0s mean forever
  local res, err = fun(...)
  if err then
    -- use the old cache at first
    values = cache_ngx:get_stale(opts.key)
    if values then
      values = json_decode(values)
      res, err = values.res, values.err
    end

    exp_time = opts.exp_time_fail or exp_time
  else
    exp_time = opts.exp_time_succ or exp_time
  end

  --  update the shm cache with the newly fetched value
  if tonumber(exp_time) >= 0 then
    cache_ngx:set(opts.key, json_encode({res=res, err=err}), exp_time)
  end
  lock:unlock()
  return res, err
end


function clear_cache(table_key)
  	local cache_ngx = ngx.shared['cache_ngx']
  	if not table_key then
  		return
  	end

  	--delete if from ngx dict
    local md5s = cache_ngx:get(table_key)
    for _,sql_md5 in pairs(split(md5s, '#')) do
      cache_ngx:delete(sql_md5) -- clear the sql cache
    end
  	cache_ngx:delete(table_key) -- clear the table_key cache
end

function flush_tlc_cache()
    tlc_cache:flush()
end


function json_decode( str )
    local ok, json_value = pcall(json.decode, str)
    if ok then
        return json_value
    end
end


function json_encode( data, empty_table_as_object )
    local json_value = nil
    if json.encode_empty_table_as_object then
        json.encode_empty_table_as_object(empty_table_as_object or false) -- 空的table默认为array
    end
    if require("ffi").os ~= "Windows" then
        json.encode_sparse_array(true)
    end
    --json_value = json.encode(data)
    local ok, json_value = pcall(json.encode, data)
    if ok then
        return json_value
    end
end

-- to prevent use of casual module global variables
getmetatable(lua.comm.common).__newindex = function (table, key, val)
    error('attempt to write to undeclared variable "' .. key .. '": '
            .. debug.traceback())
end
