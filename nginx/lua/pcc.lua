local common = require "lua.comm.common"
local redis_op = require "lua.db_redis.db"

ngx.req.read_body()

------ 主要数据结构 ------
--[==[

1. hash user:uid:nickname e.g:hset user uid nickname

2. sort key 的名称为 friend:uid, 集合中的元素为uid。 e.g: sadd friend:11 12, sadd friend:12 11

3. sort, key 的名称为 like:oid, 集合中的元素为uid。 e.g: sadd like:101 11, sadd like:101 12

sort 
]==]

--[==[
function get_plat_time_with_cache( )
  local offset = common.get_data_with_cache({key="plat_time_offset",
                                             exp_time_succ=10,
                                             exp_time_fail=-1},
                                  get_plat_time_offset)

    return ngx.time() + (offset or 0)
end

function limit_parrelles_add( max_conn, timeout )
    if max_conn <= 0 then
        return 0
    end

    timeout = timeout or 60*60

    local dict = ngx.shared.limit_conn
    dict:add("seq_id", 1)

    local dict_keys = dict:get_keys(0)
    if #dict_keys - 1 >= max_conn then
        return nil, "reach to max connection"
    end

    local seq_id = dict:incr("seq_id", 1)
    dict:set(seq_id, true, timeout) -- 1hour will expire
    return seq_id
end
]==]

local function _action_like()
    local oid = ngx.req.get_uri_args().oid
    local uid = ngx.req.get_uri_args().uid

    local like_list, err = redis_op.like(oid, uid)

    local res = {
        oid       = tonumber(oid),
        uid       = tonumber(uid),
        like_list = like_list}

    return res, err
end

local function _action_is_like()
    local oid = ngx.req.get_uri_args().oid
    local uid = ngx.req.get_uri_args().uid

    local is_like, err = redis_op.is_like(oid, uid)

    local res = {
        oid     = tonumber(oid),
        uid     = tonumber(uid),
        is_like = is_like}

    return res, err
end

local function _action_count()
    local oid = ngx.req.get_uri_args().oid
    local count, err = redis_op.count(oid)

    local res = {
        oid   = tonumber(oid),
        count = count}

    return res, err 
end

local function _action_list()
    local args = {
        oid       = ngx.req.get_uri_args().oid,
        uid       = ngx.req.get_uri_args().uid,
        coursor   = ngx.req.get_uri_args().coursor or 0,
        page_size = ngx.req.get_uri_args().page_size or 512,
        is_friend = tonumber(ngx.req.get_uri_args().is_friend or 0) }

    local res, err = redis_op.list(args)
    return res, err
end

local action = ngx.req.get_uri_args().action
ngx.log(ngx.INFO, "action=", action)
local res, err
if action == 'like' then
    res, err = _action_like()
elseif action == 'is_like' then
    res, err = _action_is_like()
elseif action == 'count' then
    res, err = _action_count()
elseif action == 'list' then
    res, err = _action_list()
else
    res = {
        error_code = 501,
        error_message = 'unexpected action' .. (action or "nil")
    }
end

ngx.say(common.json_encode(res))
