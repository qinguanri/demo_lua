local ffi = require "ffi"
local common = require "lua.comm.common"
local split = common.split
local find = ngx.re.find
local gsub = ngx.re.gsub

local _M = {}

_M.is_windows = (ffi.os == 'Windows')


-- Check regular file or directory is existed
function _M.exists(filepath)
   local ok, err, code = os.rename(filepath, filepath)
   if not ok then
      if code == 13 then
         -- Permission denied, but it exists
         return true
      end
   end
   return ok, err
end

if _M.is_windows then
    _M.sep = '\\'

    ffi.cdef([[
        int _mkdir(const char *pathname);
        char* strerror(int errnum);
        int _getcwd (char *buf, size_t size);
    ]])

    _M.mkdir = function(path)
        -- Windows 版 _mkdir 支持递归创建目录
        local err = ffi.C['_mkdir'](path)
        if err ~= 0 then
            err = ffi.errno()
            -- 17 means EEXIST
            if err ~= 17 then
                return nil, ffi.string(ffi.C.strerror(err))
            end
        end
        return true
    end

    _M.currentdir = function ()
        local MAXPATHLEN = 260
        local buff = ffi.new("char[?]", MAXPATHLEN)
        ffi.C['_getcwd'](buff, MAXPATHLEN)
        return ffi.string(buff)
    end
else
    _M.sep = '/'

    ffi.cdef([[
        int mkdir(const char *pathname, unsigned int mode);
        char* strerror(int errnum);
        int getcwd (char *buf, size_t size);
    ]])

    _M.mkdir = function(path, mode)
        -- lua 没有八进制数的直接表示法
        mode = mode or 509
        local err = ffi.C['mkdir'](path, mode)
        if err ~= 0 then
            err = ffi.errno()
            -- 17 means EEXIST
            if err ~= 17 then
                return nil, ffi.string(ffi.C.strerror(err))
            end
        end
        return true
    end

    _M.currentdir = function ()
        local MAXPATHLEN = 4096
        local buff = ffi.new("char[?]", MAXPATHLEN)
        ffi.C['getcwd'](buff, MAXPATHLEN)
        return ffi.string(buff)
    end
end

-- 关于 Windows 下的路径规则，参见
-- https://msdn.microsoft.com/en-us/library/windows/desktop/aa365247(v=vs.85).aspx
function _M.isabs(path)
    local root = path:sub(1,1)
    if _M.is_windows then
        return root == '/' or root == '\\' or path:sub(2,3) == ':\\'
    else
        return root == '/'
    end
end

function _M.join(p1, p2, ...)
    local len = select('#', ...)
    if len > 0 then
        local p = _M.join(p1, p2)
        for i = 1, len do
            p = _M.join(p, select(i, ...))
        end
        return p
    end
    if _M.isabs(p2) then
        return p2
    end

    local has_sep
    local tail = p1:sub(#p1, #p1)
    if _M.is_windows then
        has_sep = (tail == _M.sep or tail == '/' or tail == '')
        if p2:sub(2, 2) == ':' then
            p2 = p2:sub(3)
        end
    else
        has_sep = (tail == _M.sep)
    end
    if not has_sep then
        p1 = p1 .. _M.sep
    end
    return p1 .. p2
end

function _M.abspath(path, pwd)
    path = gsub(path, "[\\/]$", '', 'jo')
    pwd = pwd or _M.currentdir()
    if not _M.isabs(path) then
        path = _M.join(pwd, path)
    elseif _M.is_windows and path:sub(2, 2) ~= ':' and path:sub(2, 2) ~= '\\' then
        -- Use currentdir's drive
        path = pwd:sub(1, 2) .. path
    end
    return _M.normpath(path)
end

function _M.normpath(path)
    -- Split path into anchor and relative path.
    local anchor
    local root = path:sub(1,1)
    if _M.is_windows then
        if find(path, [[^\\\\]], 'jo') then -- UNC
            anchor = [[\\]]
            path = path:sub(3)
        elseif root == '/' or root == '\\' then
            anchor = '\\'
            path = path:sub(2)
        elseif path:sub(2, 2) == ':' then
            anchor = path:sub(1, 2)
            path = path:sub(3)
            if path:sub(1, 1) == '/' or path:sub(1, 1) == '\\' then
                anchor = anchor .. '\\'
                path = path:sub(2)
            end
        end
        path = gsub(path, '/', '\\', 'jo')
    else
        -- According to POSIX, in path start '//' and '/' are distinct,
        -- but '///+' is equivalent to '/'.
        if find(path, '^//', 'jo') and path:sub(3, 3) ~= '/' then
            anchor = '//'
            path = path:sub(3)
        elseif root == '/' then
            anchor = '/'
            path = path:sub(find(path, '^/*(.*)$'))
        end
    end
    local parts = {}
    for _, part in ipairs(split(path, '[\\/]')) do
        if part == '..' then
            if #parts ~= 0 and parts[#parts] ~= '..' then
                table.remove(parts)
            else
                parts[#parts+1] = part
            end
        elseif part ~= '.' and part ~= '' then
            parts[#parts+1] = part
        end
    end
    path = anchor .. table.concat(parts, _M.sep)
    if path == '' then
        path = '.'
    end
    return path
end

return _M
