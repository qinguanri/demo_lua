module(..., package.seeall)
local redis = require "lua.db_redis.db_base"
local common = require "lua.comm.common"
--local murmurhash2 = require "resty.murmurhash2"
local red = redis:new()

------------
function like(oid, uid)
    local timestamp = ngx.time()
    local res, err = red:zadd('like:'..oid, timestamp, uid)
    if err then
        return nil, err
    end

    if res == 0 then
        err = "object already been liked"
    end
    
    local uids, err = red:zrange('like:'..oid, -20, -1)
    ngx.log(ngx.ERR, "action like, like_list"..common.json_encode(uids))
    ngx.log(ngx.ERR, "type="..type(uids))
    local like_list = {}
    if uids and type(uids) == 'table' then
        for _, uid in pairs(uids) do
            local nickname, err = red:hget('user', uid)
            if nickname ~= nil then
                table.insert(like_list, { [uid] = nickname})
            end
            --ngx.log(ngx.ERR, "like_list="..common.json_encode(like_list))
        end
    end

    return like_list, err
end

function is_like(oid, uid)
    local _is_like = function(oid, uid)
        local is_like, err = red:zscore('like:'..oid, uid)
        return is_like and 1 or 0, err
    end

    local is_like, err = common.get_data_with_cache({
        key="like_count_"..oid.."_"..uid,
        exp_time_succ=5,
        exp_time_fail=-1},
        _is_like, oid, uid)

    return is_like, err
end

function count(oid)
    local _get_like_count = function(oid)
        local count, err = red:zcard('like:'..oid)
        return count, err
    end

    local count, err = common.get_data_with_cache({
        key="like_count_"..oid,
        exp_time_succ=5,
        exp_time_fail=-1},
        _get_like_count, oid)

    return count, err
end

--action=list&cursor=xxx&page_size=xxx&is_friend=1|0
function list(args)
    local like_list = {}
    local next_cursor = -1
    if args.cursor < 0 then
        local res = {
            like_list = {},
            next_cursor = -1,
            oid = tonumber(oid)
        }
        return res, nil
    end
    
    local oid = args.oid
    local uid = args.uid
    local cursor = args.cursor   --ngx.req.get_uri_args().cursor or 0,
    local page_size = args.page_size --ngx.req.get_uri_args().page_size or 512,
    local is_friend = args.is_friend --ngx.req.get_uri_args().is_friend or 0 } 
    
    local target_list, size, err
    -- 只返回好友的uid
    if args.is_friend == 1 then
        target_list = "friend_like_list:"..uid
        size, err = red:zinterstore(target_list, 2, "like:"..oid, "friend:"..uid)
    else
        target_list = "like:"..oid
        size, err = red:zcard(target_list)
    end

    local start, stop
    if cursor == 0 then
        stop = -1
        start = size - page_size
    else
        stop = cursor
        start = stop - page_size
    end
    
    if stop > size then
        stop = size
    end
    if start < 0 then
        start = 0
    end
    next_cursor = start - 1
    
    local uids, err = red:zrange(target_list, start, stop) 
    if uids ~= nil and type(uids) == 'table' then
        for _, uid in pairs(uids) do
            local nickname, err = red:hget('user', uid)
            table.insert(like_list, {[uid] = nickname})
        end
    end
    
    local res = {
        like_list = like_list,
        next_cursor = next_cursor,
        oid = tonumber(oid)
    }
    return res, err
end

-- to prevent use of casual module global variables
getmetatable(lua.db_redis.db).__newindex = function (table, key, val)
    error('attempt to write to undeclared variable "' .. key .. '": '
            .. debug.traceback())
end
