module("lua.comm.common", package.seeall)

local ffi = require "ffi"
local json   = require(require("ffi").os=="Windows" and "resty.dkjson" or "cjson")
--local zlib   = require "lua.comm.zlib"
local lock   = require "resty.lock"
--local pgmoon = require "resty.pgmoon.init"
local manager = require("resty.tlc.manager")
local tlc_cache   = manager.get("default_cache")

function get_main_json_config()
  local cache_ngx = ngx.shared.cache_ngx
  local main_json = cache_ngx:get("ngx_main_json")
  if nil == main_json then
    local prefix = ngx.config.prefix()
    local f = io.open(prefix.."/conf/ngx_main_config.json", 'r')
    main_json = f:read("*all")
    f:close()
    cache_ngx:set("ngx_main_json", main_json)

    ngx.log(ngx.WARN, " main_json:", main_json)
  end

  return main_json
end

function parse_cloud_query(data)
    local args = {}
    local regex = [[(\w+)=([\S\s]*?)\r\n]]
    for m in ngx.re.gmatch(data,regex) do
        local name = m[1]
        local value = m[2]
        args[name] = value
     end
    return args
end

function get_file_cache(key)
    local cache_ngx = ngx.shared.file_level_cache
    local value = cache_ngx:get(key)
    return value
end

function set_file_cache(key, value, exptime)
    if not exptime then
        exptime = 0
    end
    local cache_ngx = ngx.shared.file_level_cache
    local succ, err, forcible = cache_ngx:set(key, value, exptime)
    return succ
end

function del_file_cache(key)
    local cache_ngx = ngx.shared.file_level_cache
    cache_ngx:delete(key)
end

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

function query_from_db( sql )
    ngx.log(ngx.DEBUG, sql)
    local ngx_share  = ngx.shared.ngx_cache_sql
    local sql_expire   = 30 -- 30seconds for expire

    ngx_share:add("sql_index", 0)
    local new_index = ngx_share:incr("sql_index", 1)

    local succ, err = ngx_share:set(new_index, sql, sql_expire)
    if not succ then
        ngx.log(ngx.ERR, "put the sql to ngx_share failed:", err)
        return false, nil
    end

    local res = ngx.location.capture('/postgres', { args = {id = new_index } } )
    ngx_share:delete(new_index)

    ngx.log(ngx.WARN, "sql:", sql)
    ngx.log(ngx.WARN, "status:", res.status, " body:", res.body)

    local status = res.status
    local body = nil


    if status == 200 then
        status = true
        body = json_decode(res.body)
    else
        status = false
    end

    return status, body
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

function get_data_worker_shm( opts, fun, ... )
  -- get from tlc_cache
  local values = tlc_cache:get(opts.key)
  if values then
    return values.res, values.err
  end

  -- tlc_cache miss!
  local ngx_dict_name = "cache_ngx"
  local lock = lock:new(ngx_dict_name, opts.lock)
  local elapsed, err = lock:lock("lock_" .. opts.key)
  if not elapsed then
    return nil, string.format("get data with cache lock fail err: %s", err)
  end

  -- someone might have already put the value into the cache
  -- so we check it here again:
  values = tlc_cache:get(opts.key)
  if values then
    lock:unlock()
    return values.res, values.err
  end

  -- get data
  local exp_time = opts.exp_time or 0 -- default 0s mean forever
  local res, err = fun(...)
  if err then
    exp_time = opts.exp_time_fail or exp_time
  else
    exp_time = opts.exp_time_succ or exp_time
  end

  --  update the shm cache with the newly fetched value
  if tonumber(exp_time) >= 0 then
    tlc_cache:set(opts.key, {res=res, err=err}, exp_time)
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

function is_version_A_newer_than_B(ver_A, ver_B)
    local t_ver_A = split_no_pat(ver_A, ".")
    local t_ver_B = split_no_pat(ver_B, ".")

    if #t_ver_A ~= #t_ver_B then
        return false
    else
        for index = 1, #t_ver_A, 1 do
            if tonumber(t_ver_A[index]) > tonumber(t_ver_B[index]) then
                return true
            elseif tonumber(t_ver_A[index]) < tonumber(t_ver_B[index]) then
                return false
            end
        end
        return false
    end
end

--edit by aifei
function conver_table_clients_to_gap(clients_count)
	local gap = 10 -- set default value just for safe
	local convert_table = {{0, 10},{100, 15},{2000, 30},{5000, 60},{10000, 180},{20000, 300}} --add this table and keep first value increase
  for _, table in ipairs(convert_table) do
		if clients_count >= table[1] then
			gap = table[2]
		else
			break;
		end
	end
	return gap
end

ffi.cdef[[
typedef unsigned char u_char;
uint32_t ngx_murmur_hash2(u_char *data, size_t len);
]]

function murmurhash(value)
    
end

function split(str, pat)
   local t = {}
   if str == '' or str == nil then
       return t
   end

   local fpat = "(.-)" .. pat
   local last_end = 1
   local s, e, cap = str:find(fpat, 1)
   while s do
      if s ~= 1 or cap ~= "" then
         --print(cap)
         table.insert(t,cap)
      end
      last_end = e+1
      s, e, cap = str:find(fpat, last_end)
   end
   if last_end <= #str then
      cap = str:sub(last_end)
      table.insert(t, cap)
   end
   return t
end

function split_no_pat(s, delim, max_lines)

    if type(s) ~= "string" or string.len(s) <= 0 then
        return {}
    end

    if type(delim) ~= "string" or string.len(delim) <= 0 then
        return {}
    end

    if nil == max_lines or max_lines < 1 then
        max_lines = 0
    end

    local count = 0
    local start = 1
    local t = {}
    while true do
        local pos = s:find(delim, start, true) -- plain find
        if not pos then
          break
        end

        table.insert (t, s:sub(start, pos - 1))
        start = pos + string.len (delim)
        count = count + 1
        -- print(count, max_lines)
        if max_lines > 0 and count >= max_lines then
            break
        end
    end

    if not (max_lines > 0 and count >= max_lines) then
        table.insert (t, s:sub(start))
    end

    return t
end

function check_format_base64( str )
    if "string" ~= type(str) then
        return false
    end

    for i=1, #str do
        local c = str:sub(i, i)
        if not (
            (c >= 'A' and c <= 'Z') or
            (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or
            (c == '+') or
            (c == '/') or
            (c == '=') or
            (c == '\n') or
            (c == '-') or
            (c == '_') or
            (c == ',')
         ) then
            return false
        end
    end

    return true
end

function check_format_hex( str, correct_len )
    if "string" ~= type(str) then
        return false
    end

    local start, stop = ngx.re.find(str, "^[0-9A-Fa-f]+$", "jo")
    if not start then
        return false
    end

    if correct_len and correct_len ~= stop then
        return false
    end

    return true
end

--parse content-Type  multipart/form-data  according to RFC2388.
function parse_form_protocol(query_data)
    local result = {}
    local boundary = get_boundary()

    if boundary == nil or nil == query_data then
        return result
    end

    boundary = "--" .. boundary
    local regex = [[name="(\w+)"\r\n\r\n([\s\S]+?)\r\n]] .. boundary
    for m in ngx.re.gmatch(query_data, regex) do
        local name = m[1]
        local value =m[2]

        if name and name ~= '' then
          result[name] = value
        end
    end

    return result
end

function parse_post_args(query_data)
    local result = {}
    if nil == query_data then
        return result
    end

    local regex = [[([\w\d]+?)=([^&]+)]]
    for m in ngx.re.gmatch(query_data, regex) do
        local name = m[1]
        local value =m[2]
        result[name] = value
    end
    return result
end

function get_boundary()
    local header = ngx.var.content_type
    if not header then
        return nil
    end

    return string.match(header, ";%s+boundary=(%S+)")
end

-------------- table functions
function table_contains(table, element)
    for _, value in pairs(table) do
        if value == element then
            return true
        end
    end
    return false
end

local function find(a, tbl)
  for _,a_ in ipairs(tbl) do
      if a_==a then
          return true
      end
  end
end

function union(a, b)
    a = {unpack(a)}
    for _,b_ in ipairs(b) do
        if not find(b_, a) then table.insert(a, b_) end
    end
    return a
end

function intersection(a, b)
    local ret = {}
    for _,b_ in ipairs(b) do
            if find(b_,a) then table.insert(ret, b_) end
    end
    return ret
end

function difference(a, b)
    local ret = {}
    for _,a_ in ipairs(a) do
        if not find(a_,b) then table.insert(ret, a_) end
    end
    return ret
end

function symmetric(a, b)
    return difference(union(a,b), intersection(a,b))
end
--------------

function encrypt_md5(md5)
    if #md5 ~= 32 then
        md5 = string.sub(md5, 2 , -2)
    end
    local salt = ';)]<m:=?)$k3Y=3H'
    local md5 = string.lower(md5)
    return ngx.md5(md5 .. salt)
end

function file_exists(path)
    local file = io.open(path, "rb")
    if file then
        file:close()
    end
    return file ~= nil
end

function get_file_length(path)
    local fh, err = io.open(path, "rb")
    if nil == err and fh then
        local len = fh:seek("end")
        fh:close()
        return len
    end
    return 0, err
end

function file_set_empty(file)
    local fh = io.open (file, "w+")
    if fh then
        fh:close()
    end
end

function strip(s)
-- return (string.gsub(s, "^%s*(.-)%s*$", "%1"))
  if type(s) == 'string' then
    return (string.gsub(s, "^%s*(.-)%s*$", "%1"))
  else
    return s
  end
end

function get_host(url)
  local host = ''
  local regex = [[//([\S]+?)/]]
  local url = string.lower(url)
  local m, err = ngx.re.match(url, regex)
  if m then
    host = m[1]
  end
  return host
end

function convert_string_to_timestamp(time2convert)
  -- Assuming a date pattern like: yyyy-mm-dd hh:mm:ss
  local pattern = "(%d+)-(%d+)-(%d+) (%d+):(%d+):(%d+)"
  local runyear, runmonth, runday, runhour, runminute, runseconds = time2convert:match(pattern)

  local converted_timestamp = os.time({year = runyear, month = runmonth, day = runday, hour = runhour, min = runminute, sec = runseconds})
  return converted_timestamp
end


function get_ip_long(ip_str)
    local u = split_no_pat(ip_str, '.')
    if #u ~= 4 then
        return nil, "unvalid  format"
    end

    local n
    for k,v in ipairs(u) do
        n = tonumber(v)
        if nil == n or n < 0 or n > 255 then
          return nil, "unvalid format"
        end
        u[k] = n
    end

    local ip_long = u[1]*256*256*256 + u[2]*256*256 + u[3]*256 + u[4]

    if ip_long == nil or ip_long < 0 or ip_long > 0xffffffff then
        -- ngx.log(ngx.ERR, "invalid ip number:", ip_long)
        return nil, "invalid ip number"
    end
    return ip_long
end

function get_post_info()
    ngx.req.read_body()
    local method = ngx.var.request_method
    local query_data = ngx.req.get_body_data()
    if method ~= 'POST' or not query_data then
        ngx.exit(ngx.HTTP_BAD_REQUEST)
        --ngx.say(method)
        return
    end
    return method,query_data
end

function check_args(args, require_key)
    if not args or "table" ~= type(args) then
      return false
    end

    local key, value
    for k,_ in ipairs(require_key) do
        key = require_key[k]
        value = args[key]

        if nil == value then
            return false
        elseif "string" == type(value) and #value == 0 then
            return false
        end
    end

    return true
end

function check_args_template(args, template)
    if type(args) ~= type(template) then
      return false
    elseif "table" ~= type(args) then
      return true
    end

    for k,v in pairs(template) do
      if type(v) ~= type(args[k]) then
        return false
      elseif "table" == type(v) then
        if not check_args_template(args[k], v) then
          return false
        end
      end
    end

    return true
end

function check_args_array_type( args, require_key )
  if not args or "table" ~= type(args) then
      return false
  end

  local ret  = false
  for _, v in ipairs(args) do
    if check_args(v, require_key) == false then
        return false
    end
    ret = true
  end

  return ret
end


function json_decode( str )
    local ok, json_value = pcall(json.decode, str)
    if ok then
        return json_value
    end
end


function json_encode( data, empty_table_as_object )
  --lua的数据类型里面，array和dict是同一个东西。对应到json encode的时候，就会有不同的判断
  --对于linux，我们用的是cjson库：A Lua table with only positive integer keys of type number will be encoded as a JSON array. All other tables will be encoded as a JSON object.
  --cjson对于空的table，就会被处理为object，也就是{}
  --dkjson默认对空table会处理为array，也就是[]
  --处理方法：对于cjson，使用encode_empty_table_as_object这个方法。文档里面没有，看源码
  --对于dkjson，需要设置meta信息。local a= {}；a.s = {};a.b='中文';setmetatable(a.s,  { __jsontype = 'object' });ngx.say(comm.json_encode(a))
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

function safe_read_body(  )
    ngx.req.read_body()
    local data = ngx.req.get_body_data()
    if nil == data then
        return
    end

    local args    = ngx.req.get_uri_args()
    if args.ver == "2.0" then

        local pos = data:find("]", 1, true)
        local flag= data:sub(1, pos)
        data= data:sub(pos+1)
        ngx.log(ngx.WARN, "flag:", flag)
        ngx.log(ngx.WARN, "data:", data)

        flag= json_decode(flag) or {}  -- [len, random, checksum]

        local correct_sum = ngx.md5(args.mid .. args.ver .. (flag[2] or "") .. data .. "D82E248725B55E20")
        if correct_sum:sub(1, 4) ~= flag[3] then
          ngx.log(ngx.WARN, "checksum is invalid:", correct_sum:sub(1, 4))
          ngx.exit(400) -- 内容被修改
        else
          local ngx_valid_msg = ngx.shared.ngx_valid_msg
          local ok = ngx_valid_msg:add(correct_sum, 1, 5*60)
          if not ok then
            ngx.log(ngx.WARN, "same package, the checksum is duplicate:", correct_sum)
            ngx.exit(400) -- 重复包
          end
        end

        -- local aes_128_cbc_md5 = aes:new("96323AE92F544122")
        -- data = aes_128_cbc_md5:decrypt(data)
        --
        -- local a, b, c, d = string.byte(data, 1, 4)
        -- local len = tonumber(string.format("%02x", a) .. string.format("%02x", b) ..
        --                         string.format("%02x", c) .. string.format("%02x", d), 16)
        -- data = zlib.uncompress(data:sub(5, -1), len)

        if nil == data then
          ngx.log(ngx.WARN, "uncompress data failed")
          ngx.exit(400) -- 内容被修改
        end

        ngx.req.set_body_data(data)
    end
end


local function delay_commit_back_worker( premature, lock, lock_key, fn_push, key, chan, type )
  if premature then
    lock:unlock()
    return
  end

  if ngx.worker.exiting() then
    lock:unlock()
    return
  end

  local all_done = fn_push(key, chan, type)
  if all_done then
    lock:unlock()

    ngx.log(ngx.WARN, "delay commiter work all done ", ngx.time())
    return
  end

  local ok, err = ngx.timer.at(0, delay_commit_back_worker, lock, lock_key, fn_push, key, chan, type)
  if not ok then
      ngx.log(ngx.ERR, "failed to create delay_commit timer: ", err)
      return
  end
end

-- fn_push 函数指针，入参为空，返回值代表是否已经同步完毕
function delay_commit( key, msec, fn_push, chan, type )
  -- body
  local lock = lock:new("cache_ngx", {timeout=0, exptime=msec+10})
  local lock_key     = "lock_" .. key
  local elapsed, err = lock:lock(lock_key)
  if err then
    ngx.log(ngx.WARN, "try to get lock for delay commit failed:", err)
    return
  end

  local ok, err = ngx.timer.at(msec, delay_commit_back_worker, lock, lock_key, fn_push, key, chan, type)
  if not ok then
      ngx.log(ngx.ERR, "failed to create delay_commit timer: ", err)
      return
  end

end

--通过pgmoon访问pg数据库
--[==[
function  pgmoon_query( sql )
    local db_json = get_skylar_user_config()
    local db_info = json_decode(db_json or "{}")

    local pg = pgmoon.new({
        host = db_info.PgsqlHost or "127.0.0.1",
        port = db_info.PgsqlPort or "5360",
        database = "skylar",
        user = db_info.PgsqlUser or "postgres",
        password = db_info.PgsqlPassword or "postgres"
    })

    local success, err = pg:connect()
    if not success then
        return nil, err
    end

    local res, err = pg:query(sql)
    if not res then
        return res, err
    end

    pg:keepalive(60*1000, 10)

    return res, err
end
]==]


function log_echo( log_level, ... )
  get_data_with_cache({key=ngx.md5_bin(json_encode({...})),
                      exp_time_succ=3,
                      exp_time_fail=-1},
                      ngx.log, log_level, ...)
end

function log( log_level, ... )
  local args = {...}
  local t
  for i,v in ipairs(args) do
    t = type(v)
    if "table" == t then
      args[i] = json_encode(v)
    end
  end

  ngx.log(log_level, table.concat( args, " "))
end

function table_isequal(o1, o2, compare_mt)
    if o1 == o2 then return true end
    local o1Type = type(o1)
    local o2Type = type(o2)
    if o1Type ~= o2Type then return false end
    if o1Type ~= 'table' then return false end

    if compare_mt then
        local mt1 = getmetatable(o1)
        if mt1 and mt1.__eq then
            --compare using built in method
            return o1 == o2
        end
    end

    local keySet = {}

    for key1, value1 in pairs(o1) do
        local value2 = o2[key1]
        if value2 == nil or table_isequal(value1, value2, compare_mt) == false then
            return false
        end
        keySet[key1] = true
    end

    for key2, _ in pairs(o2) do
        if not keySet[key2] then return false end
    end
    return true
end


function copy_table(ori_tab)
    if type(ori_tab) ~= "table" then
        return
    end
    local new_tab = {}
    for k,v in pairs(ori_tab) do
        local vtype = type(v)
        if vtype == "table" then
            new_tab[k] = copy_table(v)
        else
            new_tab[k] = v
        end
    end
    return new_tab
end

-- to prevent use of casual module global variables
getmetatable(lua.comm.common).__newindex = function (table, key, val)
    error('attempt to write to undeclared variable "' .. key .. '": '
            .. debug.traceback())
end
