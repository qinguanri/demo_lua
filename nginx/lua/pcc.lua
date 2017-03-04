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
        cursor   = ngx.req.get_uri_args().cursor or 0,
        page_size = ngx.req.get_uri_args().page_size or 512,
        is_friend = tonumber(ngx.req.get_uri_args().is_friend or 0) }
    
    ngx.log(ngx.ERR, "args="..common.json_encode(args))

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
