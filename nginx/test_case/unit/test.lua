local tb       = (require "test_case.test_base").new({unit_name="test"})
local json     = require(require("ffi").os=="Windows" and "resty.dkjson" or "cjson")
local http     = require "resty.http"
local httpc    = http.new()

local redis = require "lua.db_redis.db_base"
local red = redis:new()

function tb:init(  )
    --self.sid = string.rep('0',32)
end

function tb:http( url, param )
    return httpc:request_uri("http://" .. ngx.var.server_addr .. ":" 
                                .. ngx.var.server_port .. url, 
                                param)
end

function tb:test_like()
    red:hset('user', '1', 'nickname')
    red:hset('user', '2', 'Jerry')
    red:del('like:1')
    red:zadd('like:1', 1, '2')

    local res = ngx.location.capture(
        "/pcc?action=like&oid=1&uid=1",
        { 
          method = ngx.HTTP_POST
        }
    )
    
    if 200 ~= res.status then
        error("failed code:" .. res.status)
    end

    local data = json.decode(res.body)
    if not data.like_list or #(data.like_list) ~= 2 then
        error('error data:'..res.body)
    end
end

function tb:test_is_like()
    red:del('like:1')
    red:zadd('like:1', 0, '2')

    local res = ngx.location.capture(
        "/pcc?action=is_like&oid=1&uid=2",
        { 
          method = ngx.HTTP_POST
        }
    )

    if 200 ~= res.status then
        error("failed code:" .. res.status)
    end

    local data = json.decode(res.body)
    if not data.is_like or data.is_like ~= 1 then
        error('error data:'..res.body)
    end
end

function tb:test_count()
    red:del('like:1')
    
    for i=1, 1024 do
        red:zadd('like:1', i, tostring(i))
    end

    local res = ngx.location.capture(
        "/pcc?action=count&oid=1",
        { 
          method = ngx.HTTP_POST
        }
    )

    if 200 ~= res.status then
        error("failed code:" .. res.status)
    end

    local data = json.decode(res.body)
    if not data.count or data.count ~= 1024 then
        error('error data:'..res.body)
    end
end

tb:run()



