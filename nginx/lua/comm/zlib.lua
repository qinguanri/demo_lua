module(..., package.seeall)

local ffi = require("ffi")
ffi.cdef[[
unsigned long compressBound(unsigned long sourceLen);
int compress2(uint8_t *dest, unsigned long *destLen,
          const uint8_t *source, unsigned long sourceLen, int level);
int uncompress(uint8_t *dest, unsigned long *destLen,
           const uint8_t *source, unsigned long sourceLen);
]]
local zlib = ffi.load(ffi.os == "Windows" and "zlib" or "z")

function compress(txt, level)
  local n = zlib.compressBound(#txt)
  local buf = ffi.new("uint8_t[?]", n)
  local buflen = ffi.new("unsigned long[1]", n)
  local res = zlib.compress2(buf, buflen, txt, #txt, level or 9)
  assert(res == 0)
  return ffi.string(buf, buflen[0])
end

function uncompress(comp, n)
  local buf = ffi.new("uint8_t[?]", n)
  local buflen = ffi.new("unsigned long[1]", n)
  local res = zlib.uncompress(buf, buflen, comp, #comp)
  if res ~= 0 then 
    return nil
  end
  return ffi.string(buf, buflen[0])
end


-- some common function in 360ent
function uncompress_hex4( data, max_length )
  local a, b, c, d = string.byte(data, 1, 4)
  local len = tonumber(string.format("%02x", a) .. string.format("%02x", b) .. 
                          string.format("%02x", c) .. string.format("%02x", d), 16)
  if max_length and len > tonumber(max_length) then
    ngx.log(ngx.WARN, "clear data is bigger than normal:", len)
    return nil
  end

  local compress_data = data:sub(5)
  ngx.log(ngx.WARN, "compress len:", len)
  return uncompress(compress_data, len)
end

function compress_hex4( data )
  local len  = #data
  local compress_data = compress(data, -1)
  len = string.format("%08x", len)
  data = string.char('0x' .. string.sub(len, 1, 2)) .. 
            string.char('0x' .. string.sub(len, 3, 4)) .. 
            string.char('0x' .. string.sub(len, 5, 6)) .. 
            string.char('0x' .. string.sub(len, 7, 8)) .. compress_data
  return data
end
