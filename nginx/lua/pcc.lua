local common = require "lua.comm.common"
local redis_op = require "lua.db_redis.db"

ngx.req.discard_body()

------ 主要数据结构 ------
--[==[

1. user, hash 类型, e.g: hset user uid nickname

2. friend, zset 类型，集合中的元素为 uid 及 时间。 e.g: zadd friend:11 nowtime 12

3. like, zset 类型, 集合中的元素为uid 及 时间。 e.g: zadd like:101 11

]==]

local uri_args = ngx.req.get_uri_args()

local function _action_like()
    local oid = uri_args.oid
    local uid = uri_args.uid

    local like_list, err = redis_op.like(oid, uid)

    local res = {
        oid       = tonumber(oid),
        uid       = tonumber(uid),
        like_list = like_list}

    return res, err
end

local function _action_is_like()
    local oid = uri_args.oid
    local uid = uri_args.uid

    local is_like, err = redis_op.is_like(oid, uid)

    local res = {
        oid     = tonumber(oid),
        uid     = tonumber(uid),
        is_like = is_like}

    return res, err
end

local function _action_count()
    local oid = uri_args.oid
    local count, err = redis_op.count(oid)

    local res = {
        oid   = tonumber(oid),
        count = count}

    return res, err 
end

local function _action_list()
    local args = {
        oid       = uri_args.oid,
        uid       = uri_args.uid,
        cursor   = tonumber(uri_args.cursor or 0),
        page_size = uri_args.page_size or 512,
        is_friend = tonumber(uri_args.is_friend or 0) }

    local res, err = redis_op.list(args)
    return res, err
end

local action = uri_args.action

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
    err = 'unexpected action' .. (action or "nil")
end

if err then
    res = {
        error_code = 501,
        error_message = err,
        oid = uri_args.oid,
        uid = uri_args.uid}
end

ngx.say(common.json_encode(res))
