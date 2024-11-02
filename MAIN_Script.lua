local HttpService = game:GetService("HttpService")
local function LPH_CRASH(...) return ... end;
local function LPH_ENCSTR(...) return ... end;
--------------------------------------------------------------------------------------------------------------------------
-- sha2.lua
--------------------------------------------------------------------------------------------------------------------------
-- VERSION: 12 (2022-02-23)
-- AUTHOR:  Egor Skriptunoff
-- LICENSE: MIT (the same license as Lua itself)
-- URL:     https://github.com/Egor-Skriptunoff/pure_lua_SHA
--
-- DESCRIPTION:
--    This module contains functions to calculate SHA digest:
--       MD5, SHA-1,
--       SHA-224, SHA-256, SHA-512/224, SHA-512/256, SHA-384, SHA-512,
--       SHA3-224, SHA3-256, SHA3-384, SHA3-512, SHAKE128, SHAKE256,
--       HMAC,
--       BLAKE2b, BLAKE2s, BLAKE2bp, BLAKE2sp, BLAKE2Xb, BLAKE2Xs,
--       BLAKE3, BLAKE3_KDF
--    Written in pure Lua.
--    Compatible with:
--       Lua 5.1, Lua 5.2, Lua 5.3, Lua 5.4, Fengari, LuaJIT 2.0/2.1 (any CPU endianness).
--    Main feature of this module: it was heavily optimized for speed.
--    For every Lua version the module contains particular implementation branch to get benefits from version-specific features.
--       - branch for Lua 5.1 (emulating bitwise operators using look-up table)
--       - branch for Lua 5.2 (using bit32/bit library), suitable for both Lua 5.2 with native "bit32" and Lua 5.1 with external library "bit"
--       - branch for Lua 5.3/5.4 (using native 64-bit bitwise operators)
--       - branch for Lua 5.3/5.4 (using native 32-bit bitwise operators) for Lua built with LUA_INT_TYPE=LUA_INT_INT
--       - branch for LuaJIT without FFI library (useful in a sandboxed environment)
--       - branch for LuaJIT x86 without FFI library (LuaJIT x86 has oddity because of lack of CPU registers)
--       - branch for LuaJIT 2.0 with FFI library (bit.* functions work only with Lua numbers)
--       - branch for LuaJIT 2.1 with FFI library (bit.* functions can work with "int64_t" arguments)
--
--
-- USAGE:
--    Input data should be provided as a binary string: either as a whole string or as a sequence of substrings (chunk-by-chunk loading, total length < 9*10^15 bytes).
--    Result (SHA digest) is returned in hexadecimal representation as a string of lowercase hex digits.
--    Simplest usage example:
--       local sha = require("sha2")
--       local your_hash = sha.sha256("your string")
--    See file "sha2_test.lua" for more examples.
--
--
-- CHANGELOG:
--  version     date      description
--  -------  ----------   -----------
--    12     2022-02-23   Now works in Luau (but NOT optimized for speed)
--    11     2022-01-09   BLAKE3 added
--    10     2022-01-02   BLAKE2 functions added
--     9     2020-05-10   Now works in OpenWrt's Lua (dialect of Lua 5.1 with "double" + "invisible int32")
--     8     2019-09-03   SHA-3 functions added
--     7     2019-03-17   Added functions to convert to/from base64
--     6     2018-11-12   HMAC added
--     5     2018-11-10   SHA-1 added
--     4     2018-11-03   MD5 added
--     3     2018-11-02   Bug fixed: incorrect hashing of long (2 GByte) data streams on Lua 5.3/5.4 built with "int32" integers
--     2     2018-10-07   Decreased module loading time in Lua 5.1 implementation branch (thanks to Peter Melnichenko for giving a hint)
--     1     2018-10-06   First release (only SHA-2 functions)
-----------------------------------------------------------------------------


local print_debug_messages = false  -- set to true to view some messages about your system's abilities and implementation branch chosen for your system

local unpack, table_concat, byte, char, string_rep, sub, gsub, gmatch, string_format, floor, ceil, math_min, math_max, tonumber, type, math_huge =
   table.unpack or unpack, table.concat, string.byte, string.char, string.rep, string.sub, string.gsub, string.gmatch, string.format, math.floor, math.ceil, math.min, math.max, tonumber, type, math.huge


--------------------------------------------------------------------------------
-- EXAMINING YOUR SYSTEM
--------------------------------------------------------------------------------

local function get_precision(one)
   -- "one" must be either float 1.0 or integer 1
   -- returns bits_precision, is_integer
   -- This function works correctly with all floating point datatypes (including non-IEEE-754)
   local k, n, m, prev_n = 0, one, one
   while true do
      k, prev_n, n, m = k + 1, n, n + n + 1, m + m + k % 2
      if k > 256 or n - (n - 1) ~= 1 or m - (m - 1) ~= 1 or n == m then
         return k, false   -- floating point datatype
      elseif n == prev_n then
         return k, true    -- integer datatype
      end
   end
end

-- Make sure Lua has "double" numbers
local x = 2/3
local Lua_has_double = x * 5 > 3 and x * 4 < 3 and get_precision(1.0) >= 53
assert(Lua_has_double, "at least 53-bit floating point numbers are required")

-- Q:
--    SHA2 was designed for FPU-less machines.
--    So, why floating point numbers are needed for this module?
-- A:
--    53-bit "double" numbers are useful to calculate "magic numbers" used in SHA.
--    I prefer to write 50 LOC "magic numbers calculator" instead of storing more than 200 constants explicitly in this source file.

local int_prec, Lua_has_integers = get_precision(1)
local Lua_has_int64 = Lua_has_integers and int_prec == 64
local Lua_has_int32 = Lua_has_integers and int_prec == 32
assert(Lua_has_int64 or Lua_has_int32 or not Lua_has_integers, "Lua integers must be either 32-bit or 64-bit")

-- Q:
--    Does it mean that almost all non-standard configurations are not supported?
-- A:
--    Yes.  Sorry, too many problems to support all possible Lua numbers configurations.
--       Lua 5.1/5.2    with "int32"               will not work.
--       Lua 5.1/5.2    with "int64"               will not work.
--       Lua 5.1/5.2    with "int128"              will not work.
--       Lua 5.1/5.2    with "float"               will not work.
--       Lua 5.1/5.2    with "double"              is OK.          (default config for Lua 5.1, Lua 5.2, LuaJIT)
--       Lua 5.3/5.4    with "int32"  + "float"    will not work.
--       Lua 5.3/5.4    with "int64"  + "float"    will not work.
--       Lua 5.3/5.4    with "int128" + "float"    will not work.
--       Lua 5.3/5.4    with "int32"  + "double"   is OK.          (config used by Fengari)
--       Lua 5.3/5.4    with "int64"  + "double"   is OK.          (default config for Lua 5.3, Lua 5.4)
--       Lua 5.3/5.4    with "int128" + "double"   will not work.
--   Using floating point numbers better than "double" instead of "double" is OK (non-IEEE-754 floating point implementation are allowed).
--   Using "int128" instead of "int64" is not OK: "int128" would require different branch of implementation for optimized SHA512.

-- Check for LuaJIT and 32-bit bitwise libraries
local is_LuaJIT = ({false, [1] = true})[1] and _VERSION ~= "Luau" and (type(jit) ~= "table" or jit.version_num >= 20000)  -- LuaJIT 1.x.x and Luau are treated as vanilla Lua 5.1/5.2
local is_LuaJIT_21  -- LuaJIT 2.1+
local LuaJIT_arch
local ffi           -- LuaJIT FFI library (as a table)
local b             -- 32-bit bitwise library (as a table)
local library_name

if is_LuaJIT then
   -- Assuming "bit" library is always available on LuaJIT
   b = require"bit"
   library_name = "bit"
   -- "ffi" is intentionally disabled on some systems for safety reason
   local LuaJIT_has_FFI, result = pcall(require, "ffi")
   if LuaJIT_has_FFI then
      ffi = result
   end
   is_LuaJIT_21 = not not loadstring"b=0b0"
   LuaJIT_arch = type(jit) == "table" and jit.arch or ffi and ffi.arch or nil
else
   -- For vanilla Lua, "bit"/"bit32" libraries are searched in global namespace only.  No attempt is made to load a library if it's not loaded yet.
   for _, libname in ipairs(_VERSION == "Lua 5.2" and {"bit32", "bit"} or {"bit", "bit32"}) do
      if type(_G[libname]) == "table" and _G[libname].bxor then
         b = _G[libname]
         library_name = libname
         break
      end
   end
end

--------------------------------------------------------------------------------
-- You can disable here some of your system's abilities (for testing purposes)
--------------------------------------------------------------------------------
-- is_LuaJIT = nil
-- is_LuaJIT_21 = nil
-- ffi = nil
-- Lua_has_int32 = nil
-- Lua_has_int64 = nil
-- b, library_name = nil
--------------------------------------------------------------------------------

if print_debug_messages then
   -- Printing list of abilities of your system
   print("Abilities:")
   print("   Lua version:               "..(is_LuaJIT and "LuaJIT "..(is_LuaJIT_21 and "2.1 " or "2.0 ")..(LuaJIT_arch or "")..(ffi and " with FFI" or " without FFI") or _VERSION))
   print("   Integer bitwise operators: "..(Lua_has_int64 and "int64" or Lua_has_int32 and "int32" or "no"))
   print("   32-bit bitwise library:    "..(library_name or "not found"))
end

-- Selecting the most suitable implementation for given set of abilities
local method, branch
if is_LuaJIT and ffi then
   method = "Using 'ffi' library of LuaJIT"
   branch = "FFI"
elseif is_LuaJIT then
   method = "Using special code for sandboxed LuaJIT (no FFI)"
   branch = "LJ"
elseif Lua_has_int64 then
   method = "Using native int64 bitwise operators"
   branch = "INT64"
elseif Lua_has_int32 then
   method = "Using native int32 bitwise operators"
   branch = "INT32"
elseif library_name then   -- when bitwise library is available (Lua 5.2 with native library "bit32" or Lua 5.1 with external library "bit")
   method = "Using '"..library_name.."' library"
   branch = "LIB32"
else
   method = "Emulating bitwise operators using look-up table"
   branch = "EMUL"
end

if print_debug_messages then
   -- Printing the implementation selected to be used on your system
   print("Implementation selected:")
   print("   "..method)
end


--------------------------------------------------------------------------------
-- BASIC 32-BIT BITWISE FUNCTIONS
--------------------------------------------------------------------------------

local AND, OR, XOR, SHL, SHR, ROL, ROR, NOT, NORM, HEX, XOR_BYTE
-- Only low 32 bits of function arguments matter, high bits are ignored
-- The result of all functions (except HEX) is an integer inside "correct range":
--    for "bit" library:    (-2^31)..(2^31-1)
--    for "bit32" library:        0..(2^32-1)

if branch == "FFI" or branch == "LJ" or branch == "LIB32" then

   -- Your system has 32-bit bitwise library (either "bit" or "bit32")

   AND  = b.band                -- 2 arguments
   OR   = b.bor                 -- 2 arguments
   XOR  = b.bxor                -- 2..5 arguments
   SHL  = b.lshift              -- second argument is integer 0..31
   SHR  = b.rshift              -- second argument is integer 0..31
   ROL  = b.rol or b.lrotate    -- second argument is integer 0..31
   ROR  = b.ror or b.rrotate    -- second argument is integer 0..31
   NOT  = b.bnot                -- only for LuaJIT
   NORM = b.tobit               -- only for LuaJIT
   HEX  = b.tohex               -- returns string of 8 lowercase hexadecimal digits
   assert(AND and OR and XOR and SHL and SHR and ROL and ROR and NOT, "Library '"..library_name.."' is incomplete")
   XOR_BYTE = XOR               -- XOR of two bytes (0..255)

elseif branch == "EMUL" then

   -- Emulating 32-bit bitwise operations using 53-bit floating point arithmetic

   function SHL(x, n)
      return (x * 2^n) % 2^32
   end

   function SHR(x, n)
      x = x % 2^32 / 2^n
      return x - x % 1
   end

   function ROL(x, n)
      x = x % 2^32 * 2^n
      local r = x % 2^32
      return r + (x - r) / 2^32
   end

   function ROR(x, n)
      x = x % 2^32 / 2^n
      local r = x % 1
      return r * 2^32 + (x - r)
   end

   local AND_of_two_bytes = {[0] = 0}  -- look-up table (256*256 entries)
   local idx = 0
   for y = 0, 127 * 256, 256 do
      for x = y, y + 127 do
         x = AND_of_two_bytes[x] * 2
         AND_of_two_bytes[idx] = x
         AND_of_two_bytes[idx + 1] = x
         AND_of_two_bytes[idx + 256] = x
         AND_of_two_bytes[idx + 257] = x + 1
         idx = idx + 2
      end
      idx = idx + 256
   end

   local function and_or_xor(x, y, operation)
      -- operation: nil = AND, 1 = OR, 2 = XOR
      local x0 = x % 2^32
      local y0 = y % 2^32
      local rx = x0 % 256
      local ry = y0 % 256
      local res = AND_of_two_bytes[rx + ry * 256]
      x = x0 - rx
      y = (y0 - ry) / 256
      rx = x % 65536
      ry = y % 256
      res = res + AND_of_two_bytes[rx + ry] * 256
      x = (x - rx) / 256
      y = (y - ry) / 256
      rx = x % 65536 + y % 256
      res = res + AND_of_two_bytes[rx] * 65536
      res = res + AND_of_two_bytes[(x + y - rx) / 256] * 16777216
      if operation then
         res = x0 + y0 - operation * res
      end
      return res
   end

   function AND(x, y)
      return and_or_xor(x, y)
   end

   function OR(x, y)
      return and_or_xor(x, y, 1)
   end

   function XOR(x, y, z, t, u)          -- 2..5 arguments
      if z then
         if t then
            if u then
               t = and_or_xor(t, u, 2)
            end
            z = and_or_xor(z, t, 2)
         end
         y = and_or_xor(y, z, 2)
      end
      return and_or_xor(x, y, 2)
   end

   function XOR_BYTE(x, y)
      return x + y - 2 * AND_of_two_bytes[x + y * 256]
   end

end

HEX = HEX
   or
      pcall(string_format, "%x", 2^31) and
      function (x)  -- returns string of 8 lowercase hexadecimal digits
         return string_format("%08x", x % 4294967296)
      end
   or
      function (x)  -- for OpenWrt's dialect of Lua
         return string_format("%08x", (x + 2^31) % 2^32 - 2^31)
      end

local function XORA5(x, y)
   return XOR(x, y or 0xA5A5A5A5) % 4294967296
end

local function create_array_of_lanes()
   return {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}
end


--------------------------------------------------------------------------------
-- CREATING OPTIMIZED INNER LOOP
--------------------------------------------------------------------------------

-- Inner loop functions
local sha256_feed_64, sha512_feed_128, md5_feed_64, sha1_feed_64, keccak_feed, blake2s_feed_64, blake2b_feed_128, blake3_feed_64

-- Arrays of SHA-2 "magic numbers" (in "INT64" and "FFI" branches "*_lo" arrays contain 64-bit values)
local sha2_K_lo, sha2_K_hi, sha2_H_lo, sha2_H_hi, sha3_RC_lo, sha3_RC_hi = {}, {}, {}, {}, {}, {}
local sha2_H_ext256 = {[224] = {}, [256] = sha2_H_hi}
local sha2_H_ext512_lo, sha2_H_ext512_hi = {[384] = {}, [512] = sha2_H_lo}, {[384] = {}, [512] = sha2_H_hi}
local md5_K, md5_sha1_H = {}, {0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0}
local md5_next_shift = {0, 0, 0, 0, 0, 0, 0, 0, 28, 25, 26, 27, 0, 0, 10, 9, 11, 12, 0, 15, 16, 17, 18, 0, 20, 22, 23, 21}
local HEX64, lanes_index_base  -- defined only for branches that internally use 64-bit integers: "INT64" and "FFI"
local common_W = {}    -- temporary table shared between all calculations (to avoid creating new temporary table every time)
local common_W_blake2b, common_W_blake2s, v_for_blake2s_feed_64 = common_W, common_W, {}
local K_lo_modulo, hi_factor, hi_factor_keccak = 4294967296, 0, 0
local sigma = {
   {  1,  2,  3,  4,  5,  6,  7,  8,  9, 10, 11, 12, 13, 14, 15, 16 },
   { 15, 11,  5,  9, 10, 16, 14,  7,  2, 13,  1,  3, 12,  8,  6,  4 },
   { 12,  9, 13,  1,  6,  3, 16, 14, 11, 15,  4,  7,  8,  2, 10,  5 },
   {  8, 10,  4,  2, 14, 13, 12, 15,  3,  7,  6, 11,  5,  1, 16,  9 },
   { 10,  1,  6,  8,  3,  5, 11, 16, 15,  2, 12, 13,  7,  9,  4, 14 },
   {  3, 13,  7, 11,  1, 12,  9,  4,  5, 14,  8,  6, 16, 15,  2, 10 },
   { 13,  6,  2, 16, 15, 14,  5, 11,  1,  8,  7,  4, 10,  3,  9, 12 },
   { 14, 12,  8, 15, 13,  2,  4, 10,  6,  1, 16,  5,  9,  7,  3, 11 },
   {  7, 16, 15, 10, 12,  4,  1,  9, 13,  3, 14,  8,  2,  5, 11,  6 },
   { 11,  3,  9,  5,  8,  7,  2,  6, 16, 12, 10, 15,  4, 13, 14,  1 },
};  sigma[11], sigma[12] = sigma[1], sigma[2]
local perm_blake3 = {
   1, 3, 4, 11, 13, 10, 12, 6,
   1, 3, 4, 11, 13, 10,
   2, 7, 5, 8, 14, 15, 16, 9,
   2, 7, 5, 8, 14, 15,
}

local function build_keccak_format(elem)
   local keccak_format = {}
   for _, size in ipairs{1, 9, 13, 17, 18, 21} do
      keccak_format[size] = "<"..string_rep(elem, size)
   end
   return keccak_format
end


if branch == "FFI" then

   local common_W_FFI_int32 = ffi.new("int32_t[?]", 80)   -- 64 is enough for SHA256, but 80 is needed for SHA-1
   common_W_blake2s = common_W_FFI_int32
   v_for_blake2s_feed_64 = ffi.new("int32_t[?]", 16)
   perm_blake3 = ffi.new("uint8_t[?]", #perm_blake3 + 1, 0, unpack(perm_blake3))
   for j = 1, 10 do
      sigma[j] = ffi.new("uint8_t[?]", #sigma[j] + 1, 0, unpack(sigma[j]))
   end;  sigma[11], sigma[12] = sigma[1], sigma[2]


   -- SHA256 implementation for "LuaJIT with FFI" branch

   function sha256_feed_64(H, str, offs, size)
      -- offs >= 0, size >= 0, size is multiple of 64
      local W, K = common_W_FFI_int32, sha2_K_hi
      for pos = offs, offs + size - 1, 64 do
         for j = 0, 15 do
            pos = pos + 4
            local a, b, c, d = byte(str, pos - 3, pos)   -- slow, but doesn't depend on endianness
            W[j] = OR(SHL(a, 24), SHL(b, 16), SHL(c, 8), d)
         end
         for j = 16, 63 do
            local a, b = W[j-15], W[j-2]
            W[j] = NORM( XOR(ROR(a, 7), ROL(a, 14), SHR(a, 3)) + XOR(ROL(b, 15), ROL(b, 13), SHR(b, 10)) + W[j-7] + W[j-16] )
         end
         local a, b, c, d, e, f, g, h = H[1], H[2], H[3], H[4], H[5], H[6], H[7], H[8]
         for j = 0, 63, 8 do  -- Thanks to Peter Cawley for this workaround (unroll the loop to avoid "PHI shuffling too complex" due to PHIs overlap)
            local z = NORM( XOR(g, AND(e, XOR(f, g))) + XOR(ROR(e, 6), ROR(e, 11), ROL(e, 7)) + (W[j] + K[j+1] + h) )
            h, g, f, e = g, f, e, NORM( d + z )
            d, c, b, a = c, b, a, NORM( XOR(AND(a, XOR(b, c)), AND(b, c)) + XOR(ROR(a, 2), ROR(a, 13), ROL(a, 10)) + z )
            z = NORM( XOR(g, AND(e, XOR(f, g))) + XOR(ROR(e, 6), ROR(e, 11), ROL(e, 7)) + (W[j+1] + K[j+2] + h) )
            h, g, f, e = g, f, e, NORM( d + z )
            d, c, b, a = c, b, a, NORM( XOR(AND(a, XOR(b, c)), AND(b, c)) + XOR(ROR(a, 2), ROR(a, 13), ROL(a, 10)) + z )
            z = NORM( XOR(g, AND(e, XOR(f, g))) + XOR(ROR(e, 6), ROR(e, 11), ROL(e, 7)) + (W[j+2] + K[j+3] + h) )
            h, g, f, e = g, f, e, NORM( d + z )
            d, c, b, a = c, b, a, NORM( XOR(AND(a, XOR(b, c)), AND(b, c)) + XOR(ROR(a, 2), ROR(a, 13), ROL(a, 10)) + z )
            z = NORM( XOR(g, AND(e, XOR(f, g))) + XOR(ROR(e, 6), ROR(e, 11), ROL(e, 7)) + (W[j+3] + K[j+4] + h) )
            h, g, f, e = g, f, e, NORM( d + z )
            d, c, b, a = c, b, a, NORM( XOR(AND(a, XOR(b, c)), AND(b, c)) + XOR(ROR(a, 2), ROR(a, 13), ROL(a, 10)) + z )
            z = NORM( XOR(g, AND(e, XOR(f, g))) + XOR(ROR(e, 6), ROR(e, 11), ROL(e, 7)) + (W[j+4] + K[j+5] + h) )
            h, g, f, e = g, f, e, NORM( d + z )
            d, c, b, a = c, b, a, NORM( XOR(AND(a, XOR(b, c)), AND(b, c)) + XOR(ROR(a, 2), ROR(a, 13), ROL(a, 10)) + z )
            z = NORM( XOR(g, AND(e, XOR(f, g))) + XOR(ROR(e, 6), ROR(e, 11), ROL(e, 7)) + (W[j+5] + K[j+6] + h) )
            h, g, f, e = g, f, e, NORM( d + z )
            d, c, b, a = c, b, a, NORM( XOR(AND(a, XOR(b, c)), AND(b, c)) + XOR(ROR(a, 2), ROR(a, 13), ROL(a, 10)) + z )
            z = NORM( XOR(g, AND(e, XOR(f, g))) + XOR(ROR(e, 6), ROR(e, 11), ROL(e, 7)) + (W[j+6] + K[j+7] + h) )
            h, g, f, e = g, f, e, NORM( d + z )
            d, c, b, a = c, b, a, NORM( XOR(AND(a, XOR(b, c)), AND(b, c)) + XOR(ROR(a, 2), ROR(a, 13), ROL(a, 10)) + z )
            z = NORM( XOR(g, AND(e, XOR(f, g))) + XOR(ROR(e, 6), ROR(e, 11), ROL(e, 7)) + (W[j+7] + K[j+8] + h) )
            h, g, f, e = g, f, e, NORM( d + z )
            d, c, b, a = c, b, a, NORM( XOR(AND(a, XOR(b, c)), AND(b, c)) + XOR(ROR(a, 2), ROR(a, 13), ROL(a, 10)) + z )
         end
         H[1], H[2], H[3], H[4] = NORM(a + H[1]), NORM(b + H[2]), NORM(c + H[3]), NORM(d + H[4])
         H[5], H[6], H[7], H[8] = NORM(e + H[5]), NORM(f + H[6]), NORM(g + H[7]), NORM(h + H[8])
      end
   end


   local common_W_FFI_int64 = ffi.new("int64_t[?]", 80)
   common_W_blake2b = common_W_FFI_int64
   local int64 = ffi.typeof"int64_t"
   local int32 = ffi.typeof"int32_t"
   local uint32 = ffi.typeof"uint32_t"
   hi_factor = int64(2^32)

   if is_LuaJIT_21 then   -- LuaJIT 2.1 supports bitwise 64-bit operations

      local AND64, OR64, XOR64, NOT64, SHL64, SHR64, ROL64, ROR64  -- introducing synonyms for better code readability
          = AND,   OR,   XOR,   NOT,   SHL,   SHR,   ROL,   ROR
      HEX64 = HEX


      -- BLAKE2b implementation for "LuaJIT 2.1 + FFI" branch

      do
         local v = ffi.new("int64_t[?]", 16)
         local W = common_W_blake2b

         local function G(a, b, c, d, k1, k2)
            local va, vb, vc, vd = v[a], v[b], v[c], v[d]
            va = W[k1] + (va + vb)
            vd = ROR64(XOR64(vd, va), 32)
            vc = vc + vd
            vb = ROR64(XOR64(vb, vc), 24)
            va = W[k2] + (va + vb)
            vd = ROR64(XOR64(vd, va), 16)
            vc = vc + vd
            vb = ROL64(XOR64(vb, vc), 1)
            v[a], v[b], v[c], v[d] = va, vb, vc, vd
         end

         function blake2b_feed_128(H, _, str, offs, size, bytes_compressed, last_block_size, is_last_node)
            -- offs >= 0, size >= 0, size is multiple of 128
            local h1, h2, h3, h4, h5, h6, h7, h8 = H[1], H[2], H[3], H[4], H[5], H[6], H[7], H[8]
            for pos = offs, offs + size - 1, 128 do
               if str then
                  for j = 1, 16 do
                     pos = pos + 8
                     local a, b, c, d, e, f, g, h = byte(str, pos - 7, pos)
                     W[j] = XOR64(OR(SHL(h, 24), SHL(g, 16), SHL(f, 8), e) * int64(2^32), uint32(int32(OR(SHL(d, 24), SHL(c, 16), SHL(b, 8), a))))
                  end
               end
               v[0x0], v[0x1], v[0x2], v[0x3], v[0x4], v[0x5], v[0x6], v[0x7] = h1, h2, h3, h4, h5, h6, h7, h8
               v[0x8], v[0x9], v[0xA], v[0xB], v[0xD], v[0xE], v[0xF] = sha2_H_lo[1], sha2_H_lo[2], sha2_H_lo[3], sha2_H_lo[4], sha2_H_lo[6], sha2_H_lo[7], sha2_H_lo[8]
               bytes_compressed = bytes_compressed + (last_block_size or 128)
               v[0xC] = XOR64(sha2_H_lo[5], bytes_compressed)  -- t0 = low_8_bytes(bytes_compressed)
               -- t1 = high_8_bytes(bytes_compressed) = 0,  message length is always below 2^53 bytes
               if last_block_size then  -- flag f0
                  v[0xE] = NOT64(v[0xE])
               end
               if is_last_node then  -- flag f1
                  v[0xF] = NOT64(v[0xF])
               end
               for j = 1, 12 do
                  local row = sigma[j]
                  G(0, 4,  8, 12, row[ 1], row[ 2])
                  G(1, 5,  9, 13, row[ 3], row[ 4])
                  G(2, 6, 10, 14, row[ 5], row[ 6])
                  G(3, 7, 11, 15, row[ 7], row[ 8])
                  G(0, 5, 10, 15, row[ 9], row[10])
                  G(1, 6, 11, 12, row[11], row[12])
                  G(2, 7,  8, 13, row[13], row[14])
                  G(3, 4,  9, 14, row[15], row[16])
               end
               h1 = XOR64(h1, v[0x0], v[0x8])
               h2 = XOR64(h2, v[0x1], v[0x9])
               h3 = XOR64(h3, v[0x2], v[0xA])
               h4 = XOR64(h4, v[0x3], v[0xB])
               h5 = XOR64(h5, v[0x4], v[0xC])
               h6 = XOR64(h6, v[0x5], v[0xD])
               h7 = XOR64(h7, v[0x6], v[0xE])
               h8 = XOR64(h8, v[0x7], v[0xF])
            end
            H[1], H[2], H[3], H[4], H[5], H[6], H[7], H[8] = h1, h2, h3, h4, h5, h6, h7, h8
            return bytes_compressed
         end

      end


      -- SHA-3 implementation for "LuaJIT 2.1 + FFI" branch

      local arr64_t = ffi.typeof"int64_t[?]"
      -- lanes array is indexed from 0
      lanes_index_base = 0
      hi_factor_keccak = int64(2^32)

      function create_array_of_lanes()
         return arr64_t(30)  -- 25 + 5 for temporary usage
      end

      function keccak_feed(lanes, _, str, offs, size, block_size_in_bytes)
         -- offs >= 0, size >= 0, size is multiple of block_size_in_bytes, block_size_in_bytes is positive multiple of 8
         local RC = sha3_RC_lo
         local qwords_qty = SHR(block_size_in_bytes, 3)
         for pos = offs, offs + size - 1, block_size_in_bytes do
            for j = 0, qwords_qty - 1 do
               pos = pos + 8
               local h, g, f, e, d, c, b, a = byte(str, pos - 7, pos)   -- slow, but doesn't depend on endianness
               lanes[j] = XOR64(lanes[j], OR64(OR(SHL(a, 24), SHL(b, 16), SHL(c, 8), d) * int64(2^32), uint32(int32(OR(SHL(e, 24), SHL(f, 16), SHL(g, 8), h)))))
            end
            for round_idx = 1, 24 do
               for j = 0, 4 do
                  lanes[25 + j] = XOR64(lanes[j], lanes[j+5], lanes[j+10], lanes[j+15], lanes[j+20])
               end
               local D = XOR64(lanes[25], ROL64(lanes[27], 1))
               lanes[1], lanes[6], lanes[11], lanes[16] = ROL64(XOR64(D, lanes[6]), 44), ROL64(XOR64(D, lanes[16]), 45), ROL64(XOR64(D, lanes[1]), 1), ROL64(XOR64(D, lanes[11]), 10)
               lanes[21] = ROL64(XOR64(D, lanes[21]), 2)
               D = XOR64(lanes[26], ROL64(lanes[28], 1))
               lanes[2], lanes[7], lanes[12], lanes[22] = ROL64(XOR64(D, lanes[12]), 43), ROL64(XOR64(D, lanes[22]), 61), ROL64(XOR64(D, lanes[7]), 6), ROL64(XOR64(D, lanes[2]), 62)
               lanes[17] = ROL64(XOR64(D, lanes[17]), 15)
               D = XOR64(lanes[27], ROL64(lanes[29], 1))
               lanes[3], lanes[8], lanes[18], lanes[23] = ROL64(XOR64(D, lanes[18]), 21), ROL64(XOR64(D, lanes[3]), 28), ROL64(XOR64(D, lanes[23]), 56), ROL64(XOR64(D, lanes[8]), 55)
               lanes[13] = ROL64(XOR64(D, lanes[13]), 25)
               D = XOR64(lanes[28], ROL64(lanes[25], 1))
               lanes[4], lanes[14], lanes[19], lanes[24] = ROL64(XOR64(D, lanes[24]), 14), ROL64(XOR64(D, lanes[19]), 8), ROL64(XOR64(D, lanes[4]), 27), ROL64(XOR64(D, lanes[14]), 39)
               lanes[9] = ROL64(XOR64(D, lanes[9]), 20)
               D = XOR64(lanes[29], ROL64(lanes[26], 1))
               lanes[5], lanes[10], lanes[15], lanes[20] = ROL64(XOR64(D, lanes[10]), 3), ROL64(XOR64(D, lanes[20]), 18), ROL64(XOR64(D, lanes[5]), 36), ROL64(XOR64(D, lanes[15]), 41)
               lanes[0] = XOR64(D, lanes[0])
               lanes[0], lanes[1], lanes[2], lanes[3], lanes[4] = XOR64(lanes[0], AND64(NOT64(lanes[1]), lanes[2]), RC[round_idx]), XOR64(lanes[1], AND64(NOT64(lanes[2]), lanes[3])), XOR64(lanes[2], AND64(NOT64(lanes[3]), lanes[4])), XOR64(lanes[3], AND64(NOT64(lanes[4]), lanes[0])), XOR64(lanes[4], AND64(NOT64(lanes[0]), lanes[1]))
               lanes[5], lanes[6], lanes[7], lanes[8], lanes[9] = XOR64(lanes[8], AND64(NOT64(lanes[9]), lanes[5])), XOR64(lanes[9], AND64(NOT64(lanes[5]), lanes[6])), XOR64(lanes[5], AND64(NOT64(lanes[6]), lanes[7])), XOR64(lanes[6], AND64(NOT64(lanes[7]), lanes[8])), XOR64(lanes[7], AND64(NOT64(lanes[8]), lanes[9]))
               lanes[10], lanes[11], lanes[12], lanes[13], lanes[14] = XOR64(lanes[11], AND64(NOT64(lanes[12]), lanes[13])), XOR64(lanes[12], AND64(NOT64(lanes[13]), lanes[14])), XOR64(lanes[13], AND64(NOT64(lanes[14]), lanes[10])), XOR64(lanes[14], AND64(NOT64(lanes[10]), lanes[11])), XOR64(lanes[10], AND64(NOT64(lanes[11]), lanes[12]))
               lanes[15], lanes[16], lanes[17], lanes[18], lanes[19] = XOR64(lanes[19], AND64(NOT64(lanes[15]), lanes[16])), XOR64(lanes[15], AND64(NOT64(lanes[16]), lanes[17])), XOR64(lanes[16], AND64(NOT64(lanes[17]), lanes[18])), XOR64(lanes[17], AND64(NOT64(lanes[18]), lanes[19])), XOR64(lanes[18], AND64(NOT64(lanes[19]), lanes[15]))
               lanes[20], lanes[21], lanes[22], lanes[23], lanes[24] = XOR64(lanes[22], AND64(NOT64(lanes[23]), lanes[24])), XOR64(lanes[23], AND64(NOT64(lanes[24]), lanes[20])), XOR64(lanes[24], AND64(NOT64(lanes[20]), lanes[21])), XOR64(lanes[20], AND64(NOT64(lanes[21]), lanes[22])), XOR64(lanes[21], AND64(NOT64(lanes[22]), lanes[23]))
            end
         end
      end


      local A5_long = 0xA5A5A5A5 * int64(2^32 + 1)  -- It's impossible to use constant 0xA5A5A5A5A5A5A5A5LL because it will raise syntax error on other Lua versions

      function XORA5(long, long2)
         return XOR64(long, long2 or A5_long)
      end


      -- SHA512 implementation for "LuaJIT 2.1 + FFI" branch

      function sha512_feed_128(H, _, str, offs, size)
         -- offs >= 0, size >= 0, size is multiple of 128
         local W, K = common_W_FFI_int64, sha2_K_lo
         for pos = offs, offs + size - 1, 128 do
            for j = 0, 15 do
               pos = pos + 8
               local a, b, c, d, e, f, g, h = byte(str, pos - 7, pos)   -- slow, but doesn't depend on endianness
               W[j] = OR64(OR(SHL(a, 24), SHL(b, 16), SHL(c, 8), d) * int64(2^32), uint32(int32(OR(SHL(e, 24), SHL(f, 16), SHL(g, 8), h))))
            end
            for j = 16, 79 do
               local a, b = W[j-15], W[j-2]
               W[j] = XOR64(ROR64(a, 1), ROR64(a, 8), SHR64(a, 7)) + XOR64(ROR64(b, 19), ROL64(b, 3), SHR64(b, 6)) + W[j-7] + W[j-16]
            end
            local a, b, c, d, e, f, g, h = H[1], H[2], H[3], H[4], H[5], H[6], H[7], H[8]
            for j = 0, 79, 8 do
               local z = XOR64(ROR64(e, 14), ROR64(e, 18), ROL64(e, 23)) + XOR64(g, AND64(e, XOR64(f, g))) + h + K[j+1] + W[j]
               h, g, f, e = g, f, e, z + d
               d, c, b, a = c, b, a, XOR64(AND64(XOR64(a, b), c), AND64(a, b)) + XOR64(ROR64(a, 28), ROL64(a, 25), ROL64(a, 30)) + z
               z = XOR64(ROR64(e, 14), ROR64(e, 18), ROL64(e, 23)) + XOR64(g, AND64(e, XOR64(f, g))) + h + K[j+2] + W[j+1]
               h, g, f, e = g, f, e, z + d
               d, c, b, a = c, b, a, XOR64(AND64(XOR64(a, b), c), AND64(a, b)) + XOR64(ROR64(a, 28), ROL64(a, 25), ROL64(a, 30)) + z
               z = XOR64(ROR64(e, 14), ROR64(e, 18), ROL64(e, 23)) + XOR64(g, AND64(e, XOR64(f, g))) + h + K[j+3] + W[j+2]
               h, g, f, e = g, f, e, z + d
               d, c, b, a = c, b, a, XOR64(AND64(XOR64(a, b), c), AND64(a, b)) + XOR64(ROR64(a, 28), ROL64(a, 25), ROL64(a, 30)) + z
               z = XOR64(ROR64(e, 14), ROR64(e, 18), ROL64(e, 23)) + XOR64(g, AND64(e, XOR64(f, g))) + h + K[j+4] + W[j+3]
               h, g, f, e = g, f, e, z + d
               d, c, b, a = c, b, a, XOR64(AND64(XOR64(a, b), c), AND64(a, b)) + XOR64(ROR64(a, 28), ROL64(a, 25), ROL64(a, 30)) + z
               z = XOR64(ROR64(e, 14), ROR64(e, 18), ROL64(e, 23)) + XOR64(g, AND64(e, XOR64(f, g))) + h + K[j+5] + W[j+4]
               h, g, f, e = g, f, e, z + d
               d, c, b, a = c, b, a, XOR64(AND64(XOR64(a, b), c), AND64(a, b)) + XOR64(ROR64(a, 28), ROL64(a, 25), ROL64(a, 30)) + z
               z = XOR64(ROR64(e, 14), ROR64(e, 18), ROL64(e, 23)) + XOR64(g, AND64(e, XOR64(f, g))) + h + K[j+6] + W[j+5]
               h, g, f, e = g, f, e, z + d
               d, c, b, a = c, b, a, XOR64(AND64(XOR64(a, b), c), AND64(a, b)) + XOR64(ROR64(a, 28), ROL64(a, 25), ROL64(a, 30)) + z
               z = XOR64(ROR64(e, 14), ROR64(e, 18), ROL64(e, 23)) + XOR64(g, AND64(e, XOR64(f, g))) + h + K[j+7] + W[j+6]
               h, g, f, e = g, f, e, z + d
               d, c, b, a = c, b, a, XOR64(AND64(XOR64(a, b), c), AND64(a, b)) + XOR64(ROR64(a, 28), ROL64(a, 25), ROL64(a, 30)) + z
               z = XOR64(ROR64(e, 14), ROR64(e, 18), ROL64(e, 23)) + XOR64(g, AND64(e, XOR64(f, g))) + h + K[j+8] + W[j+7]
               h, g, f, e = g, f, e, z + d
               d, c, b, a = c, b, a, XOR64(AND64(XOR64(a, b), c), AND64(a, b)) + XOR64(ROR64(a, 28), ROL64(a, 25), ROL64(a, 30)) + z
            end
            H[1] = a + H[1]
            H[2] = b + H[2]
            H[3] = c + H[3]
            H[4] = d + H[4]
            H[5] = e + H[5]
            H[6] = f + H[6]
            H[7] = g + H[7]
            H[8] = h + H[8]
         end
      end

   else  -- LuaJIT 2.0 doesn't support 64-bit bitwise operations

      local U = ffi.new("union{int64_t i64; struct{int32_t "..(ffi.abi("le") and "lo, hi" or "hi, lo")..";} i32;}[3]")
      -- this array of unions is used for fast splitting int64 into int32_high and int32_low

      -- "xorrific" 64-bit functions :-)
      -- int64 input is splitted into two int32 parts, some bitwise 32-bit operations are performed, finally the result is converted to int64
      -- these functions are needed because bit.* functions in LuaJIT 2.0 don't work with int64_t

      local function XORROR64_1(a)
         -- return XOR64(ROR64(a, 1), ROR64(a, 8), SHR64(a, 7))
         U[0].i64 = a
         local a_lo, a_hi = U[0].i32.lo, U[0].i32.hi
         local t_lo = XOR(SHR(a_lo, 1), SHL(a_hi, 31), SHR(a_lo, 8), SHL(a_hi, 24), SHR(a_lo, 7), SHL(a_hi, 25))
         local t_hi = XOR(SHR(a_hi, 1), SHL(a_lo, 31), SHR(a_hi, 8), SHL(a_lo, 24), SHR(a_hi, 7))
         return t_hi * int64(2^32) + uint32(int32(t_lo))
      end

      local function XORROR64_2(b)
         -- return XOR64(ROR64(b, 19), ROL64(b, 3), SHR64(b, 6))
         U[0].i64 = b
         local b_lo, b_hi = U[0].i32.lo, U[0].i32.hi
         local u_lo = XOR(SHR(b_lo, 19), SHL(b_hi, 13), SHL(b_lo, 3), SHR(b_hi, 29), SHR(b_lo, 6), SHL(b_hi, 26))
         local u_hi = XOR(SHR(b_hi, 19), SHL(b_lo, 13), SHL(b_hi, 3), SHR(b_lo, 29), SHR(b_hi, 6))
         return u_hi * int64(2^32) + uint32(int32(u_lo))
      end

      local function XORROR64_3(e)
         -- return XOR64(ROR64(e, 14), ROR64(e, 18), ROL64(e, 23))
         U[0].i64 = e
         local e_lo, e_hi = U[0].i32.lo, U[0].i32.hi
         local u_lo = XOR(SHR(e_lo, 14), SHL(e_hi, 18), SHR(e_lo, 18), SHL(e_hi, 14), SHL(e_lo, 23), SHR(e_hi, 9))
         local u_hi = XOR(SHR(e_hi, 14), SHL(e_lo, 18), SHR(e_hi, 18), SHL(e_lo, 14), SHL(e_hi, 23), SHR(e_lo, 9))
         return u_hi * int64(2^32) + uint32(int32(u_lo))
      end

      local function XORROR64_6(a)
         -- return XOR64(ROR64(a, 28), ROL64(a, 25), ROL64(a, 30))
         U[0].i64 = a
         local b_lo, b_hi = U[0].i32.lo, U[0].i32.hi
         local u_lo = XOR(SHR(b_lo, 28), SHL(b_hi, 4), SHL(b_lo, 30), SHR(b_hi, 2), SHL(b_lo, 25), SHR(b_hi, 7))
         local u_hi = XOR(SHR(b_hi, 28), SHL(b_lo, 4), SHL(b_hi, 30), SHR(b_lo, 2), SHL(b_hi, 25), SHR(b_lo, 7))
         return u_hi * int64(2^32) + uint32(int32(u_lo))
      end

      local function XORROR64_4(e, f, g)
         -- return XOR64(g, AND64(e, XOR64(f, g)))
         U[0].i64 = f
         U[1].i64 = g
         U[2].i64 = e
         local f_lo, f_hi = U[0].i32.lo, U[0].i32.hi
         local g_lo, g_hi = U[1].i32.lo, U[1].i32.hi
         local e_lo, e_hi = U[2].i32.lo, U[2].i32.hi
         local result_lo = XOR(g_lo, AND(e_lo, XOR(f_lo, g_lo)))
         local result_hi = XOR(g_hi, AND(e_hi, XOR(f_hi, g_hi)))
         return result_hi * int64(2^32) + uint32(int32(result_lo))
      end

      local function XORROR64_5(a, b, c)
         -- return XOR64(AND64(XOR64(a, b), c), AND64(a, b))
         U[0].i64 = a
         U[1].i64 = b
         U[2].i64 = c
         local a_lo, a_hi = U[0].i32.lo, U[0].i32.hi
         local b_lo, b_hi = U[1].i32.lo, U[1].i32.hi
         local c_lo, c_hi = U[2].i32.lo, U[2].i32.hi
         local result_lo = XOR(AND(XOR(a_lo, b_lo), c_lo), AND(a_lo, b_lo))
         local result_hi = XOR(AND(XOR(a_hi, b_hi), c_hi), AND(a_hi, b_hi))
         return result_hi * int64(2^32) + uint32(int32(result_lo))
      end

      local function XORROR64_7(a, b, m)
         -- return ROR64(XOR64(a, b), m), m = 1..31
         U[0].i64 = a
         U[1].i64 = b
         local a_lo, a_hi = U[0].i32.lo, U[0].i32.hi
         local b_lo, b_hi = U[1].i32.lo, U[1].i32.hi
         local c_lo, c_hi = XOR(a_lo, b_lo), XOR(a_hi, b_hi)
         local t_lo = XOR(SHR(c_lo, m), SHL(c_hi, -m))
         local t_hi = XOR(SHR(c_hi, m), SHL(c_lo, -m))
         return t_hi * int64(2^32) + uint32(int32(t_lo))
      end

      local function XORROR64_8(a, b)
         -- return ROL64(XOR64(a, b), 1)
         U[0].i64 = a
         U[1].i64 = b
         local a_lo, a_hi = U[0].i32.lo, U[0].i32.hi
         local b_lo, b_hi = U[1].i32.lo, U[1].i32.hi
         local c_lo, c_hi = XOR(a_lo, b_lo), XOR(a_hi, b_hi)
         local t_lo = XOR(SHL(c_lo, 1), SHR(c_hi, 31))
         local t_hi = XOR(SHL(c_hi, 1), SHR(c_lo, 31))
         return t_hi * int64(2^32) + uint32(int32(t_lo))
      end

      local function XORROR64_9(a, b)
         -- return ROR64(XOR64(a, b), 32)
         U[0].i64 = a
         U[1].i64 = b
         local a_lo, a_hi = U[0].i32.lo, U[0].i32.hi
         local b_lo, b_hi = U[1].i32.lo, U[1].i32.hi
         local t_hi, t_lo = XOR(a_lo, b_lo), XOR(a_hi, b_hi)
         return t_hi * int64(2^32) + uint32(int32(t_lo))
      end

      local function XOR64(a, b)
         -- return XOR64(a, b)
         U[0].i64 = a
         U[1].i64 = b
         local a_lo, a_hi = U[0].i32.lo, U[0].i32.hi
         local b_lo, b_hi = U[1].i32.lo, U[1].i32.hi
         local t_lo, t_hi = XOR(a_lo, b_lo), XOR(a_hi, b_hi)
         return t_hi * int64(2^32) + uint32(int32(t_lo))
      end

      local function XORROR64_11(a, b, c)
         -- return XOR64(a, b, c)
         U[0].i64 = a
         U[1].i64 = b
         U[2].i64 = c
         local a_lo, a_hi = U[0].i32.lo, U[0].i32.hi
         local b_lo, b_hi = U[1].i32.lo, U[1].i32.hi
         local c_lo, c_hi = U[2].i32.lo, U[2].i32.hi
         local t_lo, t_hi = XOR(a_lo, b_lo, c_lo), XOR(a_hi, b_hi, c_hi)
         return t_hi * int64(2^32) + uint32(int32(t_lo))
      end

      function XORA5(long, long2)
         -- return XOR64(long, long2 or 0xA5A5A5A5A5A5A5A5)
         U[0].i64 = long
         local lo32, hi32 = U[0].i32.lo, U[0].i32.hi
         local long2_lo, long2_hi = 0xA5A5A5A5, 0xA5A5A5A5
         if long2 then
            U[1].i64 = long2
            long2_lo, long2_hi = U[1].i32.lo, U[1].i32.hi
         end
         lo32 = XOR(lo32, long2_lo)
         hi32 = XOR(hi32, long2_hi)
         return hi32 * int64(2^32) + uint32(int32(lo32))
      end

      function HEX64(long)
         U[0].i64 = long
         return HEX(U[0].i32.hi)..HEX(U[0].i32.lo)
      end


      -- SHA512 implementation for "LuaJIT 2.0 + FFI" branch

      function sha512_feed_128(H, _, str, offs, size)
         -- offs >= 0, size >= 0, size is multiple of 128
         local W, K = common_W_FFI_int64, sha2_K_lo
         for pos = offs, offs + size - 1, 128 do
            for j = 0, 15 do
               pos = pos + 8
               local a, b, c, d, e, f, g, h = byte(str, pos - 7, pos)   -- slow, but doesn't depend on endianness
               W[j] = OR(SHL(a, 24), SHL(b, 16), SHL(c, 8), d) * int64(2^32) + uint32(int32(OR(SHL(e, 24), SHL(f, 16), SHL(g, 8), h)))
            end
            for j = 16, 79 do
               W[j] = XORROR64_1(W[j-15]) + XORROR64_2(W[j-2]) + W[j-7] + W[j-16]
            end
            local a, b, c, d, e, f, g, h = H[1], H[2], H[3], H[4], H[5], H[6], H[7], H[8]
            for j = 0, 79, 8 do
               local z = XORROR64_3(e) + XORROR64_4(e, f, g) + h + K[j+1] + W[j]
               h, g, f, e = g, f, e, z + d
               d, c, b, a = c, b, a, XORROR64_5(a, b, c) + XORROR64_6(a) + z
               z = XORROR64_3(e) + XORROR64_4(e, f, g) + h + K[j+2] + W[j+1]
               h, g, f, e = g, f, e, z + d
               d, c, b, a = c, b, a, XORROR64_5(a, b, c) + XORROR64_6(a) + z
               z = XORROR64_3(e) + XORROR64_4(e, f, g) + h + K[j+3] + W[j+2]
               h, g, f, e = g, f, e, z + d
               d, c, b, a = c, b, a, XORROR64_5(a, b, c) + XORROR64_6(a) + z
               z = XORROR64_3(e) + XORROR64_4(e, f, g) + h + K[j+4] + W[j+3]
               h, g, f, e = g, f, e, z + d
               d, c, b, a = c, b, a, XORROR64_5(a, b, c) + XORROR64_6(a) + z
               z = XORROR64_3(e) + XORROR64_4(e, f, g) + h + K[j+5] + W[j+4]
               h, g, f, e = g, f, e, z + d
               d, c, b, a = c, b, a, XORROR64_5(a, b, c) + XORROR64_6(a) + z
               z = XORROR64_3(e) + XORROR64_4(e, f, g) + h + K[j+6] + W[j+5]
               h, g, f, e = g, f, e, z + d
               d, c, b, a = c, b, a, XORROR64_5(a, b, c) + XORROR64_6(a) + z
               z = XORROR64_3(e) + XORROR64_4(e, f, g) + h + K[j+7] + W[j+6]
               h, g, f, e = g, f, e, z + d
               d, c, b, a = c, b, a, XORROR64_5(a, b, c) + XORROR64_6(a) + z
               z = XORROR64_3(e) + XORROR64_4(e, f, g) + h + K[j+8] + W[j+7]
               h, g, f, e = g, f, e, z + d
               d, c, b, a = c, b, a, XORROR64_5(a, b, c) + XORROR64_6(a) + z
            end
            H[1] = a + H[1]
            H[2] = b + H[2]
            H[3] = c + H[3]
            H[4] = d + H[4]
            H[5] = e + H[5]
            H[6] = f + H[6]
            H[7] = g + H[7]
            H[8] = h + H[8]
         end
      end


      -- BLAKE2b implementation for "LuaJIT 2.0 + FFI" branch

      do
         local v = ffi.new("int64_t[?]", 16)
         local W = common_W_blake2b

         local function G(a, b, c, d, k1, k2)
            local va, vb, vc, vd = v[a], v[b], v[c], v[d]
            va = W[k1] + (va + vb)
            vd = XORROR64_9(vd, va)
            vc = vc + vd
            vb = XORROR64_7(vb, vc, 24)
            va = W[k2] + (va + vb)
            vd = XORROR64_7(vd, va, 16)
            vc = vc + vd
            vb = XORROR64_8(vb, vc)
            v[a], v[b], v[c], v[d] = va, vb, vc, vd
         end

         function blake2b_feed_128(H, _, str, offs, size, bytes_compressed, last_block_size, is_last_node)
            -- offs >= 0, size >= 0, size is multiple of 128
            local h1, h2, h3, h4, h5, h6, h7, h8 = H[1], H[2], H[3], H[4], H[5], H[6], H[7], H[8]
            for pos = offs, offs + size - 1, 128 do
               if str then
                  for j = 1, 16 do
                     pos = pos + 8
                     local a, b, c, d, e, f, g, h = byte(str, pos - 7, pos)
                     W[j] = XOR64(OR(SHL(h, 24), SHL(g, 16), SHL(f, 8), e) * int64(2^32), uint32(int32(OR(SHL(d, 24), SHL(c, 16), SHL(b, 8), a))))
                  end
               end
               v[0x0], v[0x1], v[0x2], v[0x3], v[0x4], v[0x5], v[0x6], v[0x7] = h1, h2, h3, h4, h5, h6, h7, h8
               v[0x8], v[0x9], v[0xA], v[0xB], v[0xD], v[0xE], v[0xF] = sha2_H_lo[1], sha2_H_lo[2], sha2_H_lo[3], sha2_H_lo[4], sha2_H_lo[6], sha2_H_lo[7], sha2_H_lo[8]
               bytes_compressed = bytes_compressed + (last_block_size or 128)
               v[0xC] = XOR64(sha2_H_lo[5], bytes_compressed)  -- t0 = low_8_bytes(bytes_compressed)
               -- t1 = high_8_bytes(bytes_compressed) = 0,  message length is always below 2^53 bytes
               if last_block_size then  -- flag f0
                  v[0xE] = -1 - v[0xE]
               end
               if is_last_node then  -- flag f1
                  v[0xF] = -1 - v[0xF]
               end
               for j = 1, 12 do
                  local row = sigma[j]
                  G(0, 4,  8, 12, row[ 1], row[ 2])
                  G(1, 5,  9, 13, row[ 3], row[ 4])
                  G(2, 6, 10, 14, row[ 5], row[ 6])
                  G(3, 7, 11, 15, row[ 7], row[ 8])
                  G(0, 5, 10, 15, row[ 9], row[10])
                  G(1, 6, 11, 12, row[11], row[12])
                  G(2, 7,  8, 13, row[13], row[14])
                  G(3, 4,  9, 14, row[15], row[16])
               end
               h1 = XORROR64_11(h1, v[0x0], v[0x8])
               h2 = XORROR64_11(h2, v[0x1], v[0x9])
               h3 = XORROR64_11(h3, v[0x2], v[0xA])
               h4 = XORROR64_11(h4, v[0x3], v[0xB])
               h5 = XORROR64_11(h5, v[0x4], v[0xC])
               h6 = XORROR64_11(h6, v[0x5], v[0xD])
               h7 = XORROR64_11(h7, v[0x6], v[0xE])
               h8 = XORROR64_11(h8, v[0x7], v[0xF])
            end
            H[1], H[2], H[3], H[4], H[5], H[6], H[7], H[8] = h1, h2, h3, h4, h5, h6, h7, h8
            return bytes_compressed
         end

      end

   end


   -- MD5 implementation for "LuaJIT with FFI" branch

   function md5_feed_64(H, str, offs, size)
      -- offs >= 0, size >= 0, size is multiple of 64
      local W, K = common_W_FFI_int32, md5_K
      for pos = offs, offs + size - 1, 64 do
         for j = 0, 15 do
            pos = pos + 4
            local a, b, c, d = byte(str, pos - 3, pos)   -- slow, but doesn't depend on endianness
            W[j] = OR(SHL(d, 24), SHL(c, 16), SHL(b, 8), a)
         end
         local a, b, c, d = H[1], H[2], H[3], H[4]
         for j = 0, 15, 4 do
            a, d, c, b = d, c, b, NORM(ROL(XOR(d, AND(b, XOR(c, d))) + (K[j+1] + W[j  ] + a),  7) + b)
            a, d, c, b = d, c, b, NORM(ROL(XOR(d, AND(b, XOR(c, d))) + (K[j+2] + W[j+1] + a), 12) + b)
            a, d, c, b = d, c, b, NORM(ROL(XOR(d, AND(b, XOR(c, d))) + (K[j+3] + W[j+2] + a), 17) + b)
            a, d, c, b = d, c, b, NORM(ROL(XOR(d, AND(b, XOR(c, d))) + (K[j+4] + W[j+3] + a), 22) + b)
         end
         for j = 16, 31, 4 do
            local g = 5*j
            a, d, c, b = d, c, b, NORM(ROL(XOR(c, AND(d, XOR(b, c))) + (K[j+1] + W[AND(g + 1, 15)] + a),  5) + b)
            a, d, c, b = d, c, b, NORM(ROL(XOR(c, AND(d, XOR(b, c))) + (K[j+2] + W[AND(g + 6, 15)] + a),  9) + b)
            a, d, c, b = d, c, b, NORM(ROL(XOR(c, AND(d, XOR(b, c))) + (K[j+3] + W[AND(g - 5, 15)] + a), 14) + b)
            a, d, c, b = d, c, b, NORM(ROL(XOR(c, AND(d, XOR(b, c))) + (K[j+4] + W[AND(g    , 15)] + a), 20) + b)
         end
         for j = 32, 47, 4 do
            local g = 3*j
            a, d, c, b = d, c, b, NORM(ROL(XOR(b, c, d) + (K[j+1] + W[AND(g + 5, 15)] + a),  4) + b)
            a, d, c, b = d, c, b, NORM(ROL(XOR(b, c, d) + (K[j+2] + W[AND(g + 8, 15)] + a), 11) + b)
            a, d, c, b = d, c, b, NORM(ROL(XOR(b, c, d) + (K[j+3] + W[AND(g - 5, 15)] + a), 16) + b)
            a, d, c, b = d, c, b, NORM(ROL(XOR(b, c, d) + (K[j+4] + W[AND(g - 2, 15)] + a), 23) + b)
         end
         for j = 48, 63, 4 do
            local g = 7*j
            a, d, c, b = d, c, b, NORM(ROL(XOR(c, OR(b, NOT(d))) + (K[j+1] + W[AND(g    , 15)] + a),  6) + b)
            a, d, c, b = d, c, b, NORM(ROL(XOR(c, OR(b, NOT(d))) + (K[j+2] + W[AND(g + 7, 15)] + a), 10) + b)
            a, d, c, b = d, c, b, NORM(ROL(XOR(c, OR(b, NOT(d))) + (K[j+3] + W[AND(g - 2, 15)] + a), 15) + b)
            a, d, c, b = d, c, b, NORM(ROL(XOR(c, OR(b, NOT(d))) + (K[j+4] + W[AND(g + 5, 15)] + a), 21) + b)
         end
         H[1], H[2], H[3], H[4] = NORM(a + H[1]), NORM(b + H[2]), NORM(c + H[3]), NORM(d + H[4])
      end
   end


   -- SHA-1 implementation for "LuaJIT with FFI" branch

   function sha1_feed_64(H, str, offs, size)
      -- offs >= 0, size >= 0, size is multiple of 64
      local W = common_W_FFI_int32
      for pos = offs, offs + size - 1, 64 do
         for j = 0, 15 do
            pos = pos + 4
            local a, b, c, d = byte(str, pos - 3, pos)   -- slow, but doesn't depend on endianness
            W[j] = OR(SHL(a, 24), SHL(b, 16), SHL(c, 8), d)
         end
         for j = 16, 79 do
            W[j] = ROL(XOR(W[j-3], W[j-8], W[j-14], W[j-16]), 1)
         end
         local a, b, c, d, e = H[1], H[2], H[3], H[4], H[5]
         for j = 0, 19, 5 do
            e, d, c, b, a = d, c, ROR(b, 2), a, NORM(ROL(a, 5) + XOR(d, AND(b, XOR(d, c))) + (W[j]   + 0x5A827999 + e))          -- constant = floor(2^30 * sqrt(2))
            e, d, c, b, a = d, c, ROR(b, 2), a, NORM(ROL(a, 5) + XOR(d, AND(b, XOR(d, c))) + (W[j+1] + 0x5A827999 + e))
            e, d, c, b, a = d, c, ROR(b, 2), a, NORM(ROL(a, 5) + XOR(d, AND(b, XOR(d, c))) + (W[j+2] + 0x5A827999 + e))
            e, d, c, b, a = d, c, ROR(b, 2), a, NORM(ROL(a, 5) + XOR(d, AND(b, XOR(d, c))) + (W[j+3] + 0x5A827999 + e))
            e, d, c, b, a = d, c, ROR(b, 2), a, NORM(ROL(a, 5) + XOR(d, AND(b, XOR(d, c))) + (W[j+4] + 0x5A827999 + e))
         end
         for j = 20, 39, 5 do
            e, d, c, b, a = d, c, ROR(b, 2), a, NORM(ROL(a, 5) + XOR(b, c, d) + (W[j]   + 0x6ED9EBA1 + e))                       -- 2^30 * sqrt(3)
            e, d, c, b, a = d, c, ROR(b, 2), a, NORM(ROL(a, 5) + XOR(b, c, d) + (W[j+1] + 0x6ED9EBA1 + e))
            e, d, c, b, a = d, c, ROR(b, 2), a, NORM(ROL(a, 5) + XOR(b, c, d) + (W[j+2] + 0x6ED9EBA1 + e))
            e, d, c, b, a = d, c, ROR(b, 2), a, NORM(ROL(a, 5) + XOR(b, c, d) + (W[j+3] + 0x6ED9EBA1 + e))
            e, d, c, b, a = d, c, ROR(b, 2), a, NORM(ROL(a, 5) + XOR(b, c, d) + (W[j+4] + 0x6ED9EBA1 + e))
         end
         for j = 40, 59, 5 do
            e, d, c, b, a = d, c, ROR(b, 2), a, NORM(ROL(a, 5) + XOR(AND(d, XOR(b, c)), AND(b, c)) + (W[j]   + 0x8F1BBCDC + e))  -- 2^30 * sqrt(5)
            e, d, c, b, a = d, c, ROR(b, 2), a, NORM(ROL(a, 5) + XOR(AND(d, XOR(b, c)), AND(b, c)) + (W[j+1] + 0x8F1BBCDC + e))
            e, d, c, b, a = d, c, ROR(b, 2), a, NORM(ROL(a, 5) + XOR(AND(d, XOR(b, c)), AND(b, c)) + (W[j+2] + 0x8F1BBCDC + e))
            e, d, c, b, a = d, c, ROR(b, 2), a, NORM(ROL(a, 5) + XOR(AND(d, XOR(b, c)), AND(b, c)) + (W[j+3] + 0x8F1BBCDC + e))
            e, d, c, b, a = d, c, ROR(b, 2), a, NORM(ROL(a, 5) + XOR(AND(d, XOR(b, c)), AND(b, c)) + (W[j+4] + 0x8F1BBCDC + e))
         end
         for j = 60, 79, 5 do
            e, d, c, b, a = d, c, ROR(b, 2), a, NORM(ROL(a, 5) + XOR(b, c, d) + (W[j]   + 0xCA62C1D6 + e))                       -- 2^30 * sqrt(10)
            e, d, c, b, a = d, c, ROR(b, 2), a, NORM(ROL(a, 5) + XOR(b, c, d) + (W[j+1] + 0xCA62C1D6 + e))
            e, d, c, b, a = d, c, ROR(b, 2), a, NORM(ROL(a, 5) + XOR(b, c, d) + (W[j+2] + 0xCA62C1D6 + e))
            e, d, c, b, a = d, c, ROR(b, 2), a, NORM(ROL(a, 5) + XOR(b, c, d) + (W[j+3] + 0xCA62C1D6 + e))
            e, d, c, b, a = d, c, ROR(b, 2), a, NORM(ROL(a, 5) + XOR(b, c, d) + (W[j+4] + 0xCA62C1D6 + e))
         end
         H[1], H[2], H[3], H[4], H[5] = NORM(a + H[1]), NORM(b + H[2]), NORM(c + H[3]), NORM(d + H[4]), NORM(e + H[5])
      end
   end

end


if branch == "FFI" and not is_LuaJIT_21 or branch == "LJ" then

   if branch == "FFI" then
      local arr32_t = ffi.typeof"int32_t[?]"

      function create_array_of_lanes()
         return arr32_t(31)  -- 25 + 5 + 1 (due to 1-based indexing)
      end

   end


   -- SHA-3 implementation for "LuaJIT 2.0 + FFI" and "LuaJIT without FFI" branches

   function keccak_feed(lanes_lo, lanes_hi, str, offs, size, block_size_in_bytes)
      -- offs >= 0, size >= 0, size is multiple of block_size_in_bytes, block_size_in_bytes is positive multiple of 8
      local RC_lo, RC_hi = sha3_RC_lo, sha3_RC_hi
      local qwords_qty = SHR(block_size_in_bytes, 3)
      for pos = offs, offs + size - 1, block_size_in_bytes do
         for j = 1, qwords_qty do
            local a, b, c, d = byte(str, pos + 1, pos + 4)
            lanes_lo[j] = XOR(lanes_lo[j], OR(SHL(d, 24), SHL(c, 16), SHL(b, 8), a))
            pos = pos + 8
            a, b, c, d = byte(str, pos - 3, pos)
            lanes_hi[j] = XOR(lanes_hi[j], OR(SHL(d, 24), SHL(c, 16), SHL(b, 8), a))
         end
         for round_idx = 1, 24 do
            for j = 1, 5 do
               lanes_lo[25 + j] = XOR(lanes_lo[j], lanes_lo[j + 5], lanes_lo[j + 10], lanes_lo[j + 15], lanes_lo[j + 20])
            end
            for j = 1, 5 do
               lanes_hi[25 + j] = XOR(lanes_hi[j], lanes_hi[j + 5], lanes_hi[j + 10], lanes_hi[j + 15], lanes_hi[j + 20])
            end
            local D_lo = XOR(lanes_lo[26], SHL(lanes_lo[28], 1), SHR(lanes_hi[28], 31))
            local D_hi = XOR(lanes_hi[26], SHL(lanes_hi[28], 1), SHR(lanes_lo[28], 31))
            lanes_lo[2], lanes_hi[2], lanes_lo[7], lanes_hi[7], lanes_lo[12], lanes_hi[12], lanes_lo[17], lanes_hi[17] = XOR(SHR(XOR(D_lo, lanes_lo[7]), 20), SHL(XOR(D_hi, lanes_hi[7]), 12)), XOR(SHR(XOR(D_hi, lanes_hi[7]), 20), SHL(XOR(D_lo, lanes_lo[7]), 12)), XOR(SHR(XOR(D_lo, lanes_lo[17]), 19), SHL(XOR(D_hi, lanes_hi[17]), 13)), XOR(SHR(XOR(D_hi, lanes_hi[17]), 19), SHL(XOR(D_lo, lanes_lo[17]), 13)), XOR(SHL(XOR(D_lo, lanes_lo[2]), 1), SHR(XOR(D_hi, lanes_hi[2]), 31)), XOR(SHL(XOR(D_hi, lanes_hi[2]), 1), SHR(XOR(D_lo, lanes_lo[2]), 31)), XOR(SHL(XOR(D_lo, lanes_lo[12]), 10), SHR(XOR(D_hi, lanes_hi[12]), 22)), XOR(SHL(XOR(D_hi, lanes_hi[12]), 10), SHR(XOR(D_lo, lanes_lo[12]), 22))
            local L, H = XOR(D_lo, lanes_lo[22]), XOR(D_hi, lanes_hi[22])
            lanes_lo[22], lanes_hi[22] = XOR(SHL(L, 2), SHR(H, 30)), XOR(SHL(H, 2), SHR(L, 30))
            D_lo = XOR(lanes_lo[27], SHL(lanes_lo[29], 1), SHR(lanes_hi[29], 31))
            D_hi = XOR(lanes_hi[27], SHL(lanes_hi[29], 1), SHR(lanes_lo[29], 31))
            lanes_lo[3], lanes_hi[3], lanes_lo[8], lanes_hi[8], lanes_lo[13], lanes_hi[13], lanes_lo[23], lanes_hi[23] = XOR(SHR(XOR(D_lo, lanes_lo[13]), 21), SHL(XOR(D_hi, lanes_hi[13]), 11)), XOR(SHR(XOR(D_hi, lanes_hi[13]), 21), SHL(XOR(D_lo, lanes_lo[13]), 11)), XOR(SHR(XOR(D_lo, lanes_lo[23]), 3), SHL(XOR(D_hi, lanes_hi[23]), 29)), XOR(SHR(XOR(D_hi, lanes_hi[23]), 3), SHL(XOR(D_lo, lanes_lo[23]), 29)), XOR(SHL(XOR(D_lo, lanes_lo[8]), 6), SHR(XOR(D_hi, lanes_hi[8]), 26)), XOR(SHL(XOR(D_hi, lanes_hi[8]), 6), SHR(XOR(D_lo, lanes_lo[8]), 26)), XOR(SHR(XOR(D_lo, lanes_lo[3]), 2), SHL(XOR(D_hi, lanes_hi[3]), 30)), XOR(SHR(XOR(D_hi, lanes_hi[3]), 2), SHL(XOR(D_lo, lanes_lo[3]), 30))
            L, H = XOR(D_lo, lanes_lo[18]), XOR(D_hi, lanes_hi[18])
            lanes_lo[18], lanes_hi[18] = XOR(SHL(L, 15), SHR(H, 17)), XOR(SHL(H, 15), SHR(L, 17))
            D_lo = XOR(lanes_lo[28], SHL(lanes_lo[30], 1), SHR(lanes_hi[30], 31))
            D_hi = XOR(lanes_hi[28], SHL(lanes_hi[30], 1), SHR(lanes_lo[30], 31))
            lanes_lo[4], lanes_hi[4], lanes_lo[9], lanes_hi[9], lanes_lo[19], lanes_hi[19], lanes_lo[24], lanes_hi[24] = XOR(SHL(XOR(D_lo, lanes_lo[19]), 21), SHR(XOR(D_hi, lanes_hi[19]), 11)), XOR(SHL(XOR(D_hi, lanes_hi[19]), 21), SHR(XOR(D_lo, lanes_lo[19]), 11)), XOR(SHL(XOR(D_lo, lanes_lo[4]), 28), SHR(XOR(D_hi, lanes_hi[4]), 4)), XOR(SHL(XOR(D_hi, lanes_hi[4]), 28), SHR(XOR(D_lo, lanes_lo[4]), 4)), XOR(SHR(XOR(D_lo, lanes_lo[24]), 8), SHL(XOR(D_hi, lanes_hi[24]), 24)), XOR(SHR(XOR(D_hi, lanes_hi[24]), 8), SHL(XOR(D_lo, lanes_lo[24]), 24)), XOR(SHR(XOR(D_lo, lanes_lo[9]), 9), SHL(XOR(D_hi, lanes_hi[9]), 23)), XOR(SHR(XOR(D_hi, lanes_hi[9]), 9), SHL(XOR(D_lo, lanes_lo[9]), 23))
            L, H = XOR(D_lo, lanes_lo[14]), XOR(D_hi, lanes_hi[14])
            lanes_lo[14], lanes_hi[14] = XOR(SHL(L, 25), SHR(H, 7)), XOR(SHL(H, 25), SHR(L, 7))
            D_lo = XOR(lanes_lo[29], SHL(lanes_lo[26], 1), SHR(lanes_hi[26], 31))
            D_hi = XOR(lanes_hi[29], SHL(lanes_hi[26], 1), SHR(lanes_lo[26], 31))
            lanes_lo[5], lanes_hi[5], lanes_lo[15], lanes_hi[15], lanes_lo[20], lanes_hi[20], lanes_lo[25], lanes_hi[25] = XOR(SHL(XOR(D_lo, lanes_lo[25]), 14), SHR(XOR(D_hi, lanes_hi[25]), 18)), XOR(SHL(XOR(D_hi, lanes_hi[25]), 14), SHR(XOR(D_lo, lanes_lo[25]), 18)), XOR(SHL(XOR(D_lo, lanes_lo[20]), 8), SHR(XOR(D_hi, lanes_hi[20]), 24)), XOR(SHL(XOR(D_hi, lanes_hi[20]), 8), SHR(XOR(D_lo, lanes_lo[20]), 24)), XOR(SHL(XOR(D_lo, lanes_lo[5]), 27), SHR(XOR(D_hi, lanes_hi[5]), 5)), XOR(SHL(XOR(D_hi, lanes_hi[5]), 27), SHR(XOR(D_lo, lanes_lo[5]), 5)), XOR(SHR(XOR(D_lo, lanes_lo[15]), 25), SHL(XOR(D_hi, lanes_hi[15]), 7)), XOR(SHR(XOR(D_hi, lanes_hi[15]), 25), SHL(XOR(D_lo, lanes_lo[15]), 7))
            L, H = XOR(D_lo, lanes_lo[10]), XOR(D_hi, lanes_hi[10])
            lanes_lo[10], lanes_hi[10] = XOR(SHL(L, 20), SHR(H, 12)), XOR(SHL(H, 20), SHR(L, 12))
            D_lo = XOR(lanes_lo[30], SHL(lanes_lo[27], 1), SHR(lanes_hi[27], 31))
            D_hi = XOR(lanes_hi[30], SHL(lanes_hi[27], 1), SHR(lanes_lo[27], 31))
            lanes_lo[6], lanes_hi[6], lanes_lo[11], lanes_hi[11], lanes_lo[16], lanes_hi[16], lanes_lo[21], lanes_hi[21] = XOR(SHL(XOR(D_lo, lanes_lo[11]), 3), SHR(XOR(D_hi, lanes_hi[11]), 29)), XOR(SHL(XOR(D_hi, lanes_hi[11]), 3), SHR(XOR(D_lo, lanes_lo[11]), 29)), XOR(SHL(XOR(D_lo, lanes_lo[21]), 18), SHR(XOR(D_hi, lanes_hi[21]), 14)), XOR(SHL(XOR(D_hi, lanes_hi[21]), 18), SHR(XOR(D_lo, lanes_lo[21]), 14)), XOR(SHR(XOR(D_lo, lanes_lo[6]), 28), SHL(XOR(D_hi, lanes_hi[6]), 4)), XOR(SHR(XOR(D_hi, lanes_hi[6]), 28), SHL(XOR(D_lo, lanes_lo[6]), 4)), XOR(SHR(XOR(D_lo, lanes_lo[16]), 23), SHL(XOR(D_hi, lanes_hi[16]), 9)), XOR(SHR(XOR(D_hi, lanes_hi[16]), 23), SHL(XOR(D_lo, lanes_lo[16]), 9))
            lanes_lo[1], lanes_hi[1] = XOR(D_lo, lanes_lo[1]), XOR(D_hi, lanes_hi[1])
            lanes_lo[1], lanes_lo[2], lanes_lo[3], lanes_lo[4], lanes_lo[5] = XOR(lanes_lo[1], AND(NOT(lanes_lo[2]), lanes_lo[3]), RC_lo[round_idx]), XOR(lanes_lo[2], AND(NOT(lanes_lo[3]), lanes_lo[4])), XOR(lanes_lo[3], AND(NOT(lanes_lo[4]), lanes_lo[5])), XOR(lanes_lo[4], AND(NOT(lanes_lo[5]), lanes_lo[1])), XOR(lanes_lo[5], AND(NOT(lanes_lo[1]), lanes_lo[2]))
            lanes_lo[6], lanes_lo[7], lanes_lo[8], lanes_lo[9], lanes_lo[10] = XOR(lanes_lo[9], AND(NOT(lanes_lo[10]), lanes_lo[6])), XOR(lanes_lo[10], AND(NOT(lanes_lo[6]), lanes_lo[7])), XOR(lanes_lo[6], AND(NOT(lanes_lo[7]), lanes_lo[8])), XOR(lanes_lo[7], AND(NOT(lanes_lo[8]), lanes_lo[9])), XOR(lanes_lo[8], AND(NOT(lanes_lo[9]), lanes_lo[10]))
            lanes_lo[11], lanes_lo[12], lanes_lo[13], lanes_lo[14], lanes_lo[15] = XOR(lanes_lo[12], AND(NOT(lanes_lo[13]), lanes_lo[14])), XOR(lanes_lo[13], AND(NOT(lanes_lo[14]), lanes_lo[15])), XOR(lanes_lo[14], AND(NOT(lanes_lo[15]), lanes_lo[11])), XOR(lanes_lo[15], AND(NOT(lanes_lo[11]), lanes_lo[12])), XOR(lanes_lo[11], AND(NOT(lanes_lo[12]), lanes_lo[13]))
            lanes_lo[16], lanes_lo[17], lanes_lo[18], lanes_lo[19], lanes_lo[20] = XOR(lanes_lo[20], AND(NOT(lanes_lo[16]), lanes_lo[17])), XOR(lanes_lo[16], AND(NOT(lanes_lo[17]), lanes_lo[18])), XOR(lanes_lo[17], AND(NOT(lanes_lo[18]), lanes_lo[19])), XOR(lanes_lo[18], AND(NOT(lanes_lo[19]), lanes_lo[20])), XOR(lanes_lo[19], AND(NOT(lanes_lo[20]), lanes_lo[16]))
            lanes_lo[21], lanes_lo[22], lanes_lo[23], lanes_lo[24], lanes_lo[25] = XOR(lanes_lo[23], AND(NOT(lanes_lo[24]), lanes_lo[25])), XOR(lanes_lo[24], AND(NOT(lanes_lo[25]), lanes_lo[21])), XOR(lanes_lo[25], AND(NOT(lanes_lo[21]), lanes_lo[22])), XOR(lanes_lo[21], AND(NOT(lanes_lo[22]), lanes_lo[23])), XOR(lanes_lo[22], AND(NOT(lanes_lo[23]), lanes_lo[24]))
            lanes_hi[1], lanes_hi[2], lanes_hi[3], lanes_hi[4], lanes_hi[5] = XOR(lanes_hi[1], AND(NOT(lanes_hi[2]), lanes_hi[3]), RC_hi[round_idx]), XOR(lanes_hi[2], AND(NOT(lanes_hi[3]), lanes_hi[4])), XOR(lanes_hi[3], AND(NOT(lanes_hi[4]), lanes_hi[5])), XOR(lanes_hi[4], AND(NOT(lanes_hi[5]), lanes_hi[1])), XOR(lanes_hi[5], AND(NOT(lanes_hi[1]), lanes_hi[2]))
            lanes_hi[6], lanes_hi[7], lanes_hi[8], lanes_hi[9], lanes_hi[10] = XOR(lanes_hi[9], AND(NOT(lanes_hi[10]), lanes_hi[6])), XOR(lanes_hi[10], AND(NOT(lanes_hi[6]), lanes_hi[7])), XOR(lanes_hi[6], AND(NOT(lanes_hi[7]), lanes_hi[8])), XOR(lanes_hi[7], AND(NOT(lanes_hi[8]), lanes_hi[9])), XOR(lanes_hi[8], AND(NOT(lanes_hi[9]), lanes_hi[10]))
            lanes_hi[11], lanes_hi[12], lanes_hi[13], lanes_hi[14], lanes_hi[15] = XOR(lanes_hi[12], AND(NOT(lanes_hi[13]), lanes_hi[14])), XOR(lanes_hi[13], AND(NOT(lanes_hi[14]), lanes_hi[15])), XOR(lanes_hi[14], AND(NOT(lanes_hi[15]), lanes_hi[11])), XOR(lanes_hi[15], AND(NOT(lanes_hi[11]), lanes_hi[12])), XOR(lanes_hi[11], AND(NOT(lanes_hi[12]), lanes_hi[13]))
            lanes_hi[16], lanes_hi[17], lanes_hi[18], lanes_hi[19], lanes_hi[20] = XOR(lanes_hi[20], AND(NOT(lanes_hi[16]), lanes_hi[17])), XOR(lanes_hi[16], AND(NOT(lanes_hi[17]), lanes_hi[18])), XOR(lanes_hi[17], AND(NOT(lanes_hi[18]), lanes_hi[19])), XOR(lanes_hi[18], AND(NOT(lanes_hi[19]), lanes_hi[20])), XOR(lanes_hi[19], AND(NOT(lanes_hi[20]), lanes_hi[16]))
            lanes_hi[21], lanes_hi[22], lanes_hi[23], lanes_hi[24], lanes_hi[25] = XOR(lanes_hi[23], AND(NOT(lanes_hi[24]), lanes_hi[25])), XOR(lanes_hi[24], AND(NOT(lanes_hi[25]), lanes_hi[21])), XOR(lanes_hi[25], AND(NOT(lanes_hi[21]), lanes_hi[22])), XOR(lanes_hi[21], AND(NOT(lanes_hi[22]), lanes_hi[23])), XOR(lanes_hi[22], AND(NOT(lanes_hi[23]), lanes_hi[24]))
         end
      end
   end

end


if branch == "LJ" then


   -- SHA256 implementation for "LuaJIT without FFI" branch

   function sha256_feed_64(H, str, offs, size)
      -- offs >= 0, size >= 0, size is multiple of 64
      local W, K = common_W, sha2_K_hi
      for pos = offs, offs + size - 1, 64 do
         for j = 1, 16 do
            pos = pos + 4
            local a, b, c, d = byte(str, pos - 3, pos)
            W[j] = OR(SHL(a, 24), SHL(b, 16), SHL(c, 8), d)
         end
         for j = 17, 64 do
            local a, b = W[j-15], W[j-2]
            W[j] = NORM( NORM( XOR(ROR(a, 7), ROL(a, 14), SHR(a, 3)) + XOR(ROL(b, 15), ROL(b, 13), SHR(b, 10)) ) + NORM( W[j-7] + W[j-16] ) )
         end
         local a, b, c, d, e, f, g, h = H[1], H[2], H[3], H[4], H[5], H[6], H[7], H[8]
         for j = 1, 64, 8 do  -- Thanks to Peter Cawley for this workaround (unroll the loop to avoid "PHI shuffling too complex" due to PHIs overlap)
            local z = NORM( XOR(ROR(e, 6), ROR(e, 11), ROL(e, 7)) + XOR(g, AND(e, XOR(f, g))) + (K[j] + W[j] + h) )
            h, g, f, e = g, f, e, NORM(d + z)
            d, c, b, a = c, b, a, NORM( XOR(AND(a, XOR(b, c)), AND(b, c)) + XOR(ROR(a, 2), ROR(a, 13), ROL(a, 10)) + z )
            z = NORM( XOR(ROR(e, 6), ROR(e, 11), ROL(e, 7)) + XOR(g, AND(e, XOR(f, g))) + (K[j+1] + W[j+1] + h) )
            h, g, f, e = g, f, e, NORM(d + z)
            d, c, b, a = c, b, a, NORM( XOR(AND(a, XOR(b, c)), AND(b, c)) + XOR(ROR(a, 2), ROR(a, 13), ROL(a, 10)) + z )
            z = NORM( XOR(ROR(e, 6), ROR(e, 11), ROL(e, 7)) + XOR(g, AND(e, XOR(f, g))) + (K[j+2] + W[j+2] + h) )
            h, g, f, e = g, f, e, NORM(d + z)
            d, c, b, a = c, b, a, NORM( XOR(AND(a, XOR(b, c)), AND(b, c)) + XOR(ROR(a, 2), ROR(a, 13), ROL(a, 10)) + z )
            z = NORM( XOR(ROR(e, 6), ROR(e, 11), ROL(e, 7)) + XOR(g, AND(e, XOR(f, g))) + (K[j+3] + W[j+3] + h) )
            h, g, f, e = g, f, e, NORM(d + z)
            d, c, b, a = c, b, a, NORM( XOR(AND(a, XOR(b, c)), AND(b, c)) + XOR(ROR(a, 2), ROR(a, 13), ROL(a, 10)) + z )
            z = NORM( XOR(ROR(e, 6), ROR(e, 11), ROL(e, 7)) + XOR(g, AND(e, XOR(f, g))) + (K[j+4] + W[j+4] + h) )
            h, g, f, e = g, f, e, NORM(d + z)
            d, c, b, a = c, b, a, NORM( XOR(AND(a, XOR(b, c)), AND(b, c)) + XOR(ROR(a, 2), ROR(a, 13), ROL(a, 10)) + z )
            z = NORM( XOR(ROR(e, 6), ROR(e, 11), ROL(e, 7)) + XOR(g, AND(e, XOR(f, g))) + (K[j+5] + W[j+5] + h) )
            h, g, f, e = g, f, e, NORM(d + z)
            d, c, b, a = c, b, a, NORM( XOR(AND(a, XOR(b, c)), AND(b, c)) + XOR(ROR(a, 2), ROR(a, 13), ROL(a, 10)) + z )
            z = NORM( XOR(ROR(e, 6), ROR(e, 11), ROL(e, 7)) + XOR(g, AND(e, XOR(f, g))) + (K[j+6] + W[j+6] + h) )
            h, g, f, e = g, f, e, NORM(d + z)
            d, c, b, a = c, b, a, NORM( XOR(AND(a, XOR(b, c)), AND(b, c)) + XOR(ROR(a, 2), ROR(a, 13), ROL(a, 10)) + z )
            z = NORM( XOR(ROR(e, 6), ROR(e, 11), ROL(e, 7)) + XOR(g, AND(e, XOR(f, g))) + (K[j+7] + W[j+7] + h) )
            h, g, f, e = g, f, e, NORM(d + z)
            d, c, b, a = c, b, a, NORM( XOR(AND(a, XOR(b, c)), AND(b, c)) + XOR(ROR(a, 2), ROR(a, 13), ROL(a, 10)) + z )
         end
         H[1], H[2], H[3], H[4] = NORM(a + H[1]), NORM(b + H[2]), NORM(c + H[3]), NORM(d + H[4])
         H[5], H[6], H[7], H[8] = NORM(e + H[5]), NORM(f + H[6]), NORM(g + H[7]), NORM(h + H[8])
      end
   end

   local function ADD64_4(a_lo, a_hi, b_lo, b_hi, c_lo, c_hi, d_lo, d_hi)
      local sum_lo = a_lo % 2^32 + b_lo % 2^32 + c_lo % 2^32 + d_lo % 2^32
      local sum_hi = a_hi + b_hi + c_hi + d_hi
      local result_lo = NORM( sum_lo )
      local result_hi = NORM( sum_hi + floor(sum_lo / 2^32) )
      return result_lo, result_hi
   end

   if LuaJIT_arch == "x86" then  -- Special trick is required to avoid "PHI shuffling too complex" on x86 platform


      -- SHA512 implementation for "LuaJIT x86 without FFI" branch

      function sha512_feed_128(H_lo, H_hi, str, offs, size)
         -- offs >= 0, size >= 0, size is multiple of 128
         -- W1_hi, W1_lo, W2_hi, W2_lo, ...   Wk_hi = W[2*k-1], Wk_lo = W[2*k]
         local W, K_lo, K_hi = common_W, sha2_K_lo, sha2_K_hi
         for pos = offs, offs + size - 1, 128 do
            for j = 1, 16*2 do
               pos = pos + 4
               local a, b, c, d = byte(str, pos - 3, pos)
               W[j] = OR(SHL(a, 24), SHL(b, 16), SHL(c, 8), d)
            end
            for jj = 17*2, 80*2, 2 do
               local a_lo, a_hi = W[jj-30], W[jj-31]
               local t_lo = XOR(OR(SHR(a_lo, 1), SHL(a_hi, 31)), OR(SHR(a_lo, 8), SHL(a_hi, 24)), OR(SHR(a_lo, 7), SHL(a_hi, 25)))
               local t_hi = XOR(OR(SHR(a_hi, 1), SHL(a_lo, 31)), OR(SHR(a_hi, 8), SHL(a_lo, 24)), SHR(a_hi, 7))
               local b_lo, b_hi = W[jj-4], W[jj-5]
               local u_lo = XOR(OR(SHR(b_lo, 19), SHL(b_hi, 13)), OR(SHL(b_lo, 3), SHR(b_hi, 29)), OR(SHR(b_lo, 6), SHL(b_hi, 26)))
               local u_hi = XOR(OR(SHR(b_hi, 19), SHL(b_lo, 13)), OR(SHL(b_hi, 3), SHR(b_lo, 29)), SHR(b_hi, 6))
               W[jj], W[jj-1] = ADD64_4(t_lo, t_hi, u_lo, u_hi, W[jj-14], W[jj-15], W[jj-32], W[jj-33])
            end
            local a_lo, b_lo, c_lo, d_lo, e_lo, f_lo, g_lo, h_lo = H_lo[1], H_lo[2], H_lo[3], H_lo[4], H_lo[5], H_lo[6], H_lo[7], H_lo[8]
            local a_hi, b_hi, c_hi, d_hi, e_hi, f_hi, g_hi, h_hi = H_hi[1], H_hi[2], H_hi[3], H_hi[4], H_hi[5], H_hi[6], H_hi[7], H_hi[8]
            local zero = 0
            for j = 1, 80 do
               local t_lo = XOR(g_lo, AND(e_lo, XOR(f_lo, g_lo)))
               local t_hi = XOR(g_hi, AND(e_hi, XOR(f_hi, g_hi)))
               local u_lo = XOR(OR(SHR(e_lo, 14), SHL(e_hi, 18)), OR(SHR(e_lo, 18), SHL(e_hi, 14)), OR(SHL(e_lo, 23), SHR(e_hi, 9)))
               local u_hi = XOR(OR(SHR(e_hi, 14), SHL(e_lo, 18)), OR(SHR(e_hi, 18), SHL(e_lo, 14)), OR(SHL(e_hi, 23), SHR(e_lo, 9)))
               local sum_lo = u_lo % 2^32 + t_lo % 2^32 + h_lo % 2^32 + K_lo[j] + W[2*j] % 2^32
               local z_lo, z_hi = NORM( sum_lo ), NORM( u_hi + t_hi + h_hi + K_hi[j] + W[2*j-1] + floor(sum_lo / 2^32) )
               zero = zero + zero  -- this thick is needed to avoid "PHI shuffling too complex" due to PHIs overlap
               h_lo, h_hi, g_lo, g_hi, f_lo, f_hi = OR(zero, g_lo), OR(zero, g_hi), OR(zero, f_lo), OR(zero, f_hi), OR(zero, e_lo), OR(zero, e_hi)
               local sum_lo = z_lo % 2^32 + d_lo % 2^32
               e_lo, e_hi = NORM( sum_lo ), NORM( z_hi + d_hi + floor(sum_lo / 2^32) )
               d_lo, d_hi, c_lo, c_hi, b_lo, b_hi = OR(zero, c_lo), OR(zero, c_hi), OR(zero, b_lo), OR(zero, b_hi), OR(zero, a_lo), OR(zero, a_hi)
               u_lo = XOR(OR(SHR(b_lo, 28), SHL(b_hi, 4)), OR(SHL(b_lo, 30), SHR(b_hi, 2)), OR(SHL(b_lo, 25), SHR(b_hi, 7)))
               u_hi = XOR(OR(SHR(b_hi, 28), SHL(b_lo, 4)), OR(SHL(b_hi, 30), SHR(b_lo, 2)), OR(SHL(b_hi, 25), SHR(b_lo, 7)))
               t_lo = OR(AND(d_lo, c_lo), AND(b_lo, XOR(d_lo, c_lo)))
               t_hi = OR(AND(d_hi, c_hi), AND(b_hi, XOR(d_hi, c_hi)))
               local sum_lo = z_lo % 2^32 + t_lo % 2^32 + u_lo % 2^32
               a_lo, a_hi = NORM( sum_lo ), NORM( z_hi + t_hi + u_hi + floor(sum_lo / 2^32) )
            end
            H_lo[1], H_hi[1] = ADD64_4(H_lo[1], H_hi[1], a_lo, a_hi, 0, 0, 0, 0)
            H_lo[2], H_hi[2] = ADD64_4(H_lo[2], H_hi[2], b_lo, b_hi, 0, 0, 0, 0)
            H_lo[3], H_hi[3] = ADD64_4(H_lo[3], H_hi[3], c_lo, c_hi, 0, 0, 0, 0)
            H_lo[4], H_hi[4] = ADD64_4(H_lo[4], H_hi[4], d_lo, d_hi, 0, 0, 0, 0)
            H_lo[5], H_hi[5] = ADD64_4(H_lo[5], H_hi[5], e_lo, e_hi, 0, 0, 0, 0)
            H_lo[6], H_hi[6] = ADD64_4(H_lo[6], H_hi[6], f_lo, f_hi, 0, 0, 0, 0)
            H_lo[7], H_hi[7] = ADD64_4(H_lo[7], H_hi[7], g_lo, g_hi, 0, 0, 0, 0)
            H_lo[8], H_hi[8] = ADD64_4(H_lo[8], H_hi[8], h_lo, h_hi, 0, 0, 0, 0)
         end
      end

   else  -- all platforms except x86


      -- SHA512 implementation for "LuaJIT non-x86 without FFI" branch

      function sha512_feed_128(H_lo, H_hi, str, offs, size)
         -- offs >= 0, size >= 0, size is multiple of 128
         -- W1_hi, W1_lo, W2_hi, W2_lo, ...   Wk_hi = W[2*k-1], Wk_lo = W[2*k]
         local W, K_lo, K_hi = common_W, sha2_K_lo, sha2_K_hi
         for pos = offs, offs + size - 1, 128 do
            for j = 1, 16*2 do
               pos = pos + 4
               local a, b, c, d = byte(str, pos - 3, pos)
               W[j] = OR(SHL(a, 24), SHL(b, 16), SHL(c, 8), d)
            end
            for jj = 17*2, 80*2, 2 do
               local a_lo, a_hi = W[jj-30], W[jj-31]
               local t_lo = XOR(OR(SHR(a_lo, 1), SHL(a_hi, 31)), OR(SHR(a_lo, 8), SHL(a_hi, 24)), OR(SHR(a_lo, 7), SHL(a_hi, 25)))
               local t_hi = XOR(OR(SHR(a_hi, 1), SHL(a_lo, 31)), OR(SHR(a_hi, 8), SHL(a_lo, 24)), SHR(a_hi, 7))
               local b_lo, b_hi = W[jj-4], W[jj-5]
               local u_lo = XOR(OR(SHR(b_lo, 19), SHL(b_hi, 13)), OR(SHL(b_lo, 3), SHR(b_hi, 29)), OR(SHR(b_lo, 6), SHL(b_hi, 26)))
               local u_hi = XOR(OR(SHR(b_hi, 19), SHL(b_lo, 13)), OR(SHL(b_hi, 3), SHR(b_lo, 29)), SHR(b_hi, 6))
               W[jj], W[jj-1] = ADD64_4(t_lo, t_hi, u_lo, u_hi, W[jj-14], W[jj-15], W[jj-32], W[jj-33])
            end
            local a_lo, b_lo, c_lo, d_lo, e_lo, f_lo, g_lo, h_lo = H_lo[1], H_lo[2], H_lo[3], H_lo[4], H_lo[5], H_lo[6], H_lo[7], H_lo[8]
            local a_hi, b_hi, c_hi, d_hi, e_hi, f_hi, g_hi, h_hi = H_hi[1], H_hi[2], H_hi[3], H_hi[4], H_hi[5], H_hi[6], H_hi[7], H_hi[8]
            for j = 1, 80 do
               local t_lo = XOR(g_lo, AND(e_lo, XOR(f_lo, g_lo)))
               local t_hi = XOR(g_hi, AND(e_hi, XOR(f_hi, g_hi)))
               local u_lo = XOR(OR(SHR(e_lo, 14), SHL(e_hi, 18)), OR(SHR(e_lo, 18), SHL(e_hi, 14)), OR(SHL(e_lo, 23), SHR(e_hi, 9)))
               local u_hi = XOR(OR(SHR(e_hi, 14), SHL(e_lo, 18)), OR(SHR(e_hi, 18), SHL(e_lo, 14)), OR(SHL(e_hi, 23), SHR(e_lo, 9)))
               local sum_lo = u_lo % 2^32 + t_lo % 2^32 + h_lo % 2^32 + K_lo[j] + W[2*j] % 2^32
               local z_lo, z_hi = NORM( sum_lo ), NORM( u_hi + t_hi + h_hi + K_hi[j] + W[2*j-1] + floor(sum_lo / 2^32) )
               h_lo, h_hi, g_lo, g_hi, f_lo, f_hi = g_lo, g_hi, f_lo, f_hi, e_lo, e_hi
               local sum_lo = z_lo % 2^32 + d_lo % 2^32
               e_lo, e_hi = NORM( sum_lo ), NORM( z_hi + d_hi + floor(sum_lo / 2^32) )
               d_lo, d_hi, c_lo, c_hi, b_lo, b_hi = c_lo, c_hi, b_lo, b_hi, a_lo, a_hi
               u_lo = XOR(OR(SHR(b_lo, 28), SHL(b_hi, 4)), OR(SHL(b_lo, 30), SHR(b_hi, 2)), OR(SHL(b_lo, 25), SHR(b_hi, 7)))
               u_hi = XOR(OR(SHR(b_hi, 28), SHL(b_lo, 4)), OR(SHL(b_hi, 30), SHR(b_lo, 2)), OR(SHL(b_hi, 25), SHR(b_lo, 7)))
               t_lo = OR(AND(d_lo, c_lo), AND(b_lo, XOR(d_lo, c_lo)))
               t_hi = OR(AND(d_hi, c_hi), AND(b_hi, XOR(d_hi, c_hi)))
               local sum_lo = z_lo % 2^32 + u_lo % 2^32 + t_lo % 2^32
               a_lo, a_hi = NORM( sum_lo ), NORM( z_hi + u_hi + t_hi + floor(sum_lo / 2^32) )
            end
            H_lo[1], H_hi[1] = ADD64_4(H_lo[1], H_hi[1], a_lo, a_hi, 0, 0, 0, 0)
            H_lo[2], H_hi[2] = ADD64_4(H_lo[2], H_hi[2], b_lo, b_hi, 0, 0, 0, 0)
            H_lo[3], H_hi[3] = ADD64_4(H_lo[3], H_hi[3], c_lo, c_hi, 0, 0, 0, 0)
            H_lo[4], H_hi[4] = ADD64_4(H_lo[4], H_hi[4], d_lo, d_hi, 0, 0, 0, 0)
            H_lo[5], H_hi[5] = ADD64_4(H_lo[5], H_hi[5], e_lo, e_hi, 0, 0, 0, 0)
            H_lo[6], H_hi[6] = ADD64_4(H_lo[6], H_hi[6], f_lo, f_hi, 0, 0, 0, 0)
            H_lo[7], H_hi[7] = ADD64_4(H_lo[7], H_hi[7], g_lo, g_hi, 0, 0, 0, 0)
            H_lo[8], H_hi[8] = ADD64_4(H_lo[8], H_hi[8], h_lo, h_hi, 0, 0, 0, 0)
         end
      end

   end


   -- MD5 implementation for "LuaJIT without FFI" branch

   function md5_feed_64(H, str, offs, size)
      -- offs >= 0, size >= 0, size is multiple of 64
      local W, K = common_W, md5_K
      for pos = offs, offs + size - 1, 64 do
         for j = 1, 16 do
            pos = pos + 4
            local a, b, c, d = byte(str, pos - 3, pos)
            W[j] = OR(SHL(d, 24), SHL(c, 16), SHL(b, 8), a)
         end
         local a, b, c, d = H[1], H[2], H[3], H[4]
         for j = 1, 16, 4 do
            a, d, c, b = d, c, b, NORM(ROL(XOR(d, AND(b, XOR(c, d))) + (K[j  ] + W[j  ] + a),  7) + b)
            a, d, c, b = d, c, b, NORM(ROL(XOR(d, AND(b, XOR(c, d))) + (K[j+1] + W[j+1] + a), 12) + b)
            a, d, c, b = d, c, b, NORM(ROL(XOR(d, AND(b, XOR(c, d))) + (K[j+2] + W[j+2] + a), 17) + b)
            a, d, c, b = d, c, b, NORM(ROL(XOR(d, AND(b, XOR(c, d))) + (K[j+3] + W[j+3] + a), 22) + b)
         end
         for j = 17, 32, 4 do
            local g = 5*j-4
            a, d, c, b = d, c, b, NORM(ROL(XOR(c, AND(d, XOR(b, c))) + (K[j  ] + W[AND(g     , 15) + 1] + a),  5) + b)
            a, d, c, b = d, c, b, NORM(ROL(XOR(c, AND(d, XOR(b, c))) + (K[j+1] + W[AND(g +  5, 15) + 1] + a),  9) + b)
            a, d, c, b = d, c, b, NORM(ROL(XOR(c, AND(d, XOR(b, c))) + (K[j+2] + W[AND(g + 10, 15) + 1] + a), 14) + b)
            a, d, c, b = d, c, b, NORM(ROL(XOR(c, AND(d, XOR(b, c))) + (K[j+3] + W[AND(g -  1, 15) + 1] + a), 20) + b)
         end
         for j = 33, 48, 4 do
            local g = 3*j+2
            a, d, c, b = d, c, b, NORM(ROL(XOR(b, c, d) + (K[j  ] + W[AND(g    , 15) + 1] + a),  4) + b)
            a, d, c, b = d, c, b, NORM(ROL(XOR(b, c, d) + (K[j+1] + W[AND(g + 3, 15) + 1] + a), 11) + b)
            a, d, c, b = d, c, b, NORM(ROL(XOR(b, c, d) + (K[j+2] + W[AND(g + 6, 15) + 1] + a), 16) + b)
            a, d, c, b = d, c, b, NORM(ROL(XOR(b, c, d) + (K[j+3] + W[AND(g - 7, 15) + 1] + a), 23) + b)
         end
         for j = 49, 64, 4 do
            local g = j*7
            a, d, c, b = d, c, b, NORM(ROL(XOR(c, OR(b, NOT(d))) + (K[j  ] + W[AND(g - 7, 15) + 1] + a),  6) + b)
            a, d, c, b = d, c, b, NORM(ROL(XOR(c, OR(b, NOT(d))) + (K[j+1] + W[AND(g    , 15) + 1] + a), 10) + b)
            a, d, c, b = d, c, b, NORM(ROL(XOR(c, OR(b, NOT(d))) + (K[j+2] + W[AND(g + 7, 15) + 1] + a), 15) + b)
            a, d, c, b = d, c, b, NORM(ROL(XOR(c, OR(b, NOT(d))) + (K[j+3] + W[AND(g - 2, 15) + 1] + a), 21) + b)
         end
         H[1], H[2], H[3], H[4] = NORM(a + H[1]), NORM(b + H[2]), NORM(c + H[3]), NORM(d + H[4])
      end
   end


   -- SHA-1 implementation for "LuaJIT without FFI" branch

   function sha1_feed_64(H, str, offs, size)
      -- offs >= 0, size >= 0, size is multiple of 64
      local W = common_W
      for pos = offs, offs + size - 1, 64 do
         for j = 1, 16 do
            pos = pos + 4
            local a, b, c, d = byte(str, pos - 3, pos)
            W[j] = OR(SHL(a, 24), SHL(b, 16), SHL(c, 8), d)
         end
         for j = 17, 80 do
            W[j] = ROL(XOR(W[j-3], W[j-8], W[j-14], W[j-16]), 1)
         end
         local a, b, c, d, e = H[1], H[2], H[3], H[4], H[5]
         for j = 1, 20, 5 do
            e, d, c, b, a = d, c, ROR(b, 2), a, NORM(ROL(a, 5) + XOR(d, AND(b, XOR(d, c))) + (W[j]   + 0x5A827999 + e))          -- constant = floor(2^30 * sqrt(2))
            e, d, c, b, a = d, c, ROR(b, 2), a, NORM(ROL(a, 5) + XOR(d, AND(b, XOR(d, c))) + (W[j+1] + 0x5A827999 + e))
            e, d, c, b, a = d, c, ROR(b, 2), a, NORM(ROL(a, 5) + XOR(d, AND(b, XOR(d, c))) + (W[j+2] + 0x5A827999 + e))
            e, d, c, b, a = d, c, ROR(b, 2), a, NORM(ROL(a, 5) + XOR(d, AND(b, XOR(d, c))) + (W[j+3] + 0x5A827999 + e))
            e, d, c, b, a = d, c, ROR(b, 2), a, NORM(ROL(a, 5) + XOR(d, AND(b, XOR(d, c))) + (W[j+4] + 0x5A827999 + e))
         end
         for j = 21, 40, 5 do
            e, d, c, b, a = d, c, ROR(b, 2), a, NORM(ROL(a, 5) + XOR(b, c, d) + (W[j]   + 0x6ED9EBA1 + e))                       -- 2^30 * sqrt(3)
            e, d, c, b, a = d, c, ROR(b, 2), a, NORM(ROL(a, 5) + XOR(b, c, d) + (W[j+1] + 0x6ED9EBA1 + e))
            e, d, c, b, a = d, c, ROR(b, 2), a, NORM(ROL(a, 5) + XOR(b, c, d) + (W[j+2] + 0x6ED9EBA1 + e))
            e, d, c, b, a = d, c, ROR(b, 2), a, NORM(ROL(a, 5) + XOR(b, c, d) + (W[j+3] + 0x6ED9EBA1 + e))
            e, d, c, b, a = d, c, ROR(b, 2), a, NORM(ROL(a, 5) + XOR(b, c, d) + (W[j+4] + 0x6ED9EBA1 + e))
         end
         for j = 41, 60, 5 do
            e, d, c, b, a = d, c, ROR(b, 2), a, NORM(ROL(a, 5) + XOR(AND(d, XOR(b, c)), AND(b, c)) + (W[j]   + 0x8F1BBCDC + e))  -- 2^30 * sqrt(5)
            e, d, c, b, a = d, c, ROR(b, 2), a, NORM(ROL(a, 5) + XOR(AND(d, XOR(b, c)), AND(b, c)) + (W[j+1] + 0x8F1BBCDC + e))
            e, d, c, b, a = d, c, ROR(b, 2), a, NORM(ROL(a, 5) + XOR(AND(d, XOR(b, c)), AND(b, c)) + (W[j+2] + 0x8F1BBCDC + e))
            e, d, c, b, a = d, c, ROR(b, 2), a, NORM(ROL(a, 5) + XOR(AND(d, XOR(b, c)), AND(b, c)) + (W[j+3] + 0x8F1BBCDC + e))
            e, d, c, b, a = d, c, ROR(b, 2), a, NORM(ROL(a, 5) + XOR(AND(d, XOR(b, c)), AND(b, c)) + (W[j+4] + 0x8F1BBCDC + e))
         end
         for j = 61, 80, 5 do
            e, d, c, b, a = d, c, ROR(b, 2), a, NORM(ROL(a, 5) + XOR(b, c, d) + (W[j]   + 0xCA62C1D6 + e))                       -- 2^30 * sqrt(10)
            e, d, c, b, a = d, c, ROR(b, 2), a, NORM(ROL(a, 5) + XOR(b, c, d) + (W[j+1] + 0xCA62C1D6 + e))
            e, d, c, b, a = d, c, ROR(b, 2), a, NORM(ROL(a, 5) + XOR(b, c, d) + (W[j+2] + 0xCA62C1D6 + e))
            e, d, c, b, a = d, c, ROR(b, 2), a, NORM(ROL(a, 5) + XOR(b, c, d) + (W[j+3] + 0xCA62C1D6 + e))
            e, d, c, b, a = d, c, ROR(b, 2), a, NORM(ROL(a, 5) + XOR(b, c, d) + (W[j+4] + 0xCA62C1D6 + e))
         end
         H[1], H[2], H[3], H[4], H[5] = NORM(a + H[1]), NORM(b + H[2]), NORM(c + H[3]), NORM(d + H[4]), NORM(e + H[5])
      end
   end


   -- BLAKE2b implementation for "LuaJIT without FFI" branch

   do
      local v_lo, v_hi = {}, {}

      local function G(a, b, c, d, k1, k2)
         local W = common_W
         local va_lo, vb_lo, vc_lo, vd_lo = v_lo[a], v_lo[b], v_lo[c], v_lo[d]
         local va_hi, vb_hi, vc_hi, vd_hi = v_hi[a], v_hi[b], v_hi[c], v_hi[d]
         local z = W[2*k1-1] + (va_lo % 2^32 + vb_lo % 2^32)
         va_lo = NORM(z)
         va_hi = NORM(W[2*k1] + (va_hi + vb_hi + floor(z / 2^32)))
         vd_lo, vd_hi = XOR(vd_hi, va_hi), XOR(vd_lo, va_lo)
         z = vc_lo % 2^32 + vd_lo % 2^32
         vc_lo = NORM(z)
         vc_hi = NORM(vc_hi + vd_hi + floor(z / 2^32))
         vb_lo, vb_hi = XOR(vb_lo, vc_lo), XOR(vb_hi, vc_hi)
         vb_lo, vb_hi = XOR(SHR(vb_lo, 24), SHL(vb_hi, 8)), XOR(SHR(vb_hi, 24), SHL(vb_lo, 8))
         z = W[2*k2-1] + (va_lo % 2^32 + vb_lo % 2^32)
         va_lo = NORM(z)
         va_hi = NORM(W[2*k2] + (va_hi + vb_hi + floor(z / 2^32)))
         vd_lo, vd_hi = XOR(vd_lo, va_lo), XOR(vd_hi, va_hi)
         vd_lo, vd_hi = XOR(SHR(vd_lo, 16), SHL(vd_hi, 16)), XOR(SHR(vd_hi, 16), SHL(vd_lo, 16))
         z = vc_lo % 2^32 + vd_lo % 2^32
         vc_lo = NORM(z)
         vc_hi = NORM(vc_hi + vd_hi + floor(z / 2^32))
         vb_lo, vb_hi = XOR(vb_lo, vc_lo), XOR(vb_hi, vc_hi)
         vb_lo, vb_hi = XOR(SHL(vb_lo, 1), SHR(vb_hi, 31)), XOR(SHL(vb_hi, 1), SHR(vb_lo, 31))
         v_lo[a], v_lo[b], v_lo[c], v_lo[d] = va_lo, vb_lo, vc_lo, vd_lo
         v_hi[a], v_hi[b], v_hi[c], v_hi[d] = va_hi, vb_hi, vc_hi, vd_hi
      end

      function blake2b_feed_128(H_lo, H_hi, str, offs, size, bytes_compressed, last_block_size, is_last_node)
         -- offs >= 0, size >= 0, size is multiple of 128
         local W = common_W
         local h1_lo, h2_lo, h3_lo, h4_lo, h5_lo, h6_lo, h7_lo, h8_lo = H_lo[1], H_lo[2], H_lo[3], H_lo[4], H_lo[5], H_lo[6], H_lo[7], H_lo[8]
         local h1_hi, h2_hi, h3_hi, h4_hi, h5_hi, h6_hi, h7_hi, h8_hi = H_hi[1], H_hi[2], H_hi[3], H_hi[4], H_hi[5], H_hi[6], H_hi[7], H_hi[8]
         for pos = offs, offs + size - 1, 128 do
            if str then
               for j = 1, 32 do
                  pos = pos + 4
                  local a, b, c, d = byte(str, pos - 3, pos)
                  W[j] = d * 2^24 + OR(SHL(c, 16), SHL(b, 8), a)
               end
            end
            v_lo[0x0], v_lo[0x1], v_lo[0x2], v_lo[0x3], v_lo[0x4], v_lo[0x5], v_lo[0x6], v_lo[0x7] = h1_lo, h2_lo, h3_lo, h4_lo, h5_lo, h6_lo, h7_lo, h8_lo
            v_lo[0x8], v_lo[0x9], v_lo[0xA], v_lo[0xB], v_lo[0xC], v_lo[0xD], v_lo[0xE], v_lo[0xF] = sha2_H_lo[1], sha2_H_lo[2], sha2_H_lo[3], sha2_H_lo[4], sha2_H_lo[5], sha2_H_lo[6], sha2_H_lo[7], sha2_H_lo[8]
            v_hi[0x0], v_hi[0x1], v_hi[0x2], v_hi[0x3], v_hi[0x4], v_hi[0x5], v_hi[0x6], v_hi[0x7] = h1_hi, h2_hi, h3_hi, h4_hi, h5_hi, h6_hi, h7_hi, h8_hi
            v_hi[0x8], v_hi[0x9], v_hi[0xA], v_hi[0xB], v_hi[0xC], v_hi[0xD], v_hi[0xE], v_hi[0xF] = sha2_H_hi[1], sha2_H_hi[2], sha2_H_hi[3], sha2_H_hi[4], sha2_H_hi[5], sha2_H_hi[6], sha2_H_hi[7], sha2_H_hi[8]
            bytes_compressed = bytes_compressed + (last_block_size or 128)
            local t0_lo = bytes_compressed % 2^32
            local t0_hi = floor(bytes_compressed / 2^32)
            v_lo[0xC] = XOR(v_lo[0xC], t0_lo)  -- t0 = low_8_bytes(bytes_compressed)
            v_hi[0xC] = XOR(v_hi[0xC], t0_hi)
            -- t1 = high_8_bytes(bytes_compressed) = 0,  message length is always below 2^53 bytes
            if last_block_size then  -- flag f0
               v_lo[0xE] = NOT(v_lo[0xE])
               v_hi[0xE] = NOT(v_hi[0xE])
            end
            if is_last_node then  -- flag f1
               v_lo[0xF] = NOT(v_lo[0xF])
               v_hi[0xF] = NOT(v_hi[0xF])
            end
            for j = 1, 12 do
               local row = sigma[j]
               G(0, 4,  8, 12, row[ 1], row[ 2])
               G(1, 5,  9, 13, row[ 3], row[ 4])
               G(2, 6, 10, 14, row[ 5], row[ 6])
               G(3, 7, 11, 15, row[ 7], row[ 8])
               G(0, 5, 10, 15, row[ 9], row[10])
               G(1, 6, 11, 12, row[11], row[12])
               G(2, 7,  8, 13, row[13], row[14])
               G(3, 4,  9, 14, row[15], row[16])
            end
            h1_lo = XOR(h1_lo, v_lo[0x0], v_lo[0x8])
            h2_lo = XOR(h2_lo, v_lo[0x1], v_lo[0x9])
            h3_lo = XOR(h3_lo, v_lo[0x2], v_lo[0xA])
            h4_lo = XOR(h4_lo, v_lo[0x3], v_lo[0xB])
            h5_lo = XOR(h5_lo, v_lo[0x4], v_lo[0xC])
            h6_lo = XOR(h6_lo, v_lo[0x5], v_lo[0xD])
            h7_lo = XOR(h7_lo, v_lo[0x6], v_lo[0xE])
            h8_lo = XOR(h8_lo, v_lo[0x7], v_lo[0xF])
            h1_hi = XOR(h1_hi, v_hi[0x0], v_hi[0x8])
            h2_hi = XOR(h2_hi, v_hi[0x1], v_hi[0x9])
            h3_hi = XOR(h3_hi, v_hi[0x2], v_hi[0xA])
            h4_hi = XOR(h4_hi, v_hi[0x3], v_hi[0xB])
            h5_hi = XOR(h5_hi, v_hi[0x4], v_hi[0xC])
            h6_hi = XOR(h6_hi, v_hi[0x5], v_hi[0xD])
            h7_hi = XOR(h7_hi, v_hi[0x6], v_hi[0xE])
            h8_hi = XOR(h8_hi, v_hi[0x7], v_hi[0xF])
         end
         H_lo[1], H_lo[2], H_lo[3], H_lo[4], H_lo[5], H_lo[6], H_lo[7], H_lo[8] = h1_lo % 2^32, h2_lo % 2^32, h3_lo % 2^32, h4_lo % 2^32, h5_lo % 2^32, h6_lo % 2^32, h7_lo % 2^32, h8_lo % 2^32
         H_hi[1], H_hi[2], H_hi[3], H_hi[4], H_hi[5], H_hi[6], H_hi[7], H_hi[8] = h1_hi % 2^32, h2_hi % 2^32, h3_hi % 2^32, h4_hi % 2^32, h5_hi % 2^32, h6_hi % 2^32, h7_hi % 2^32, h8_hi % 2^32
         return bytes_compressed
      end

   end
end


if branch == "FFI" or branch == "LJ" then


   -- BLAKE2s and BLAKE3 implementations for "LuaJIT with FFI" and "LuaJIT without FFI" branches

   do
      local W = common_W_blake2s
      local v = v_for_blake2s_feed_64

      local function G(a, b, c, d, k1, k2)
         local va, vb, vc, vd = v[a], v[b], v[c], v[d]
         va = NORM(W[k1] + (va + vb))
         vd = ROR(XOR(vd, va), 16)
         vc = NORM(vc + vd)
         vb = ROR(XOR(vb, vc), 12)
         va = NORM(W[k2] + (va + vb))
         vd = ROR(XOR(vd, va), 8)
         vc = NORM(vc + vd)
         vb = ROR(XOR(vb, vc), 7)
         v[a], v[b], v[c], v[d] = va, vb, vc, vd
      end

      function blake2s_feed_64(H, str, offs, size, bytes_compressed, last_block_size, is_last_node)
         -- offs >= 0, size >= 0, size is multiple of 64
         local h1, h2, h3, h4, h5, h6, h7, h8 = NORM(H[1]), NORM(H[2]), NORM(H[3]), NORM(H[4]), NORM(H[5]), NORM(H[6]), NORM(H[7]), NORM(H[8])
         for pos = offs, offs + size - 1, 64 do
            if str then
               for j = 1, 16 do
                  pos = pos + 4
                  local a, b, c, d = byte(str, pos - 3, pos)
                  W[j] = OR(SHL(d, 24), SHL(c, 16), SHL(b, 8), a)
               end
            end
            v[0x0], v[0x1], v[0x2], v[0x3], v[0x4], v[0x5], v[0x6], v[0x7] = h1, h2, h3, h4, h5, h6, h7, h8
            v[0x8], v[0x9], v[0xA], v[0xB], v[0xE], v[0xF] = NORM(sha2_H_hi[1]), NORM(sha2_H_hi[2]), NORM(sha2_H_hi[3]), NORM(sha2_H_hi[4]), NORM(sha2_H_hi[7]), NORM(sha2_H_hi[8])
            bytes_compressed = bytes_compressed + (last_block_size or 64)
            local t0 = bytes_compressed % 2^32
            local t1 = floor(bytes_compressed / 2^32)
            v[0xC] = XOR(sha2_H_hi[5], t0)  -- t0 = low_4_bytes(bytes_compressed)
            v[0xD] = XOR(sha2_H_hi[6], t1)  -- t1 = high_4_bytes(bytes_compressed
            if last_block_size then  -- flag f0
               v[0xE] = NOT(v[0xE])
            end
            if is_last_node then  -- flag f1
               v[0xF] = NOT(v[0xF])
            end
            for j = 1, 10 do
               local row = sigma[j]
               G(0, 4,  8, 12, row[ 1], row[ 2])
               G(1, 5,  9, 13, row[ 3], row[ 4])
               G(2, 6, 10, 14, row[ 5], row[ 6])
               G(3, 7, 11, 15, row[ 7], row[ 8])
               G(0, 5, 10, 15, row[ 9], row[10])
               G(1, 6, 11, 12, row[11], row[12])
               G(2, 7,  8, 13, row[13], row[14])
               G(3, 4,  9, 14, row[15], row[16])
            end
            h1 = XOR(h1, v[0x0], v[0x8])
            h2 = XOR(h2, v[0x1], v[0x9])
            h3 = XOR(h3, v[0x2], v[0xA])
            h4 = XOR(h4, v[0x3], v[0xB])
            h5 = XOR(h5, v[0x4], v[0xC])
            h6 = XOR(h6, v[0x5], v[0xD])
            h7 = XOR(h7, v[0x6], v[0xE])
            h8 = XOR(h8, v[0x7], v[0xF])
         end
         H[1], H[2], H[3], H[4], H[5], H[6], H[7], H[8] = h1, h2, h3, h4, h5, h6, h7, h8
         return bytes_compressed
      end

      function blake3_feed_64(str, offs, size, flags, chunk_index, H_in, H_out, wide_output, block_length)
         -- offs >= 0, size >= 0, size is multiple of 64
         block_length = block_length or 64
         local h1, h2, h3, h4, h5, h6, h7, h8 = NORM(H_in[1]), NORM(H_in[2]), NORM(H_in[3]), NORM(H_in[4]), NORM(H_in[5]), NORM(H_in[6]), NORM(H_in[7]), NORM(H_in[8])
         H_out = H_out or H_in
         for pos = offs, offs + size - 1, 64 do
            if str then
               for j = 1, 16 do
                  pos = pos + 4
                  local a, b, c, d = byte(str, pos - 3, pos)
                  W[j] = OR(SHL(d, 24), SHL(c, 16), SHL(b, 8), a)
               end
            end
            v[0x0], v[0x1], v[0x2], v[0x3], v[0x4], v[0x5], v[0x6], v[0x7] = h1, h2, h3, h4, h5, h6, h7, h8
            v[0x8], v[0x9], v[0xA], v[0xB] = NORM(sha2_H_hi[1]), NORM(sha2_H_hi[2]), NORM(sha2_H_hi[3]), NORM(sha2_H_hi[4])
            v[0xC] = NORM(chunk_index % 2^32)   -- t0 = low_4_bytes(chunk_index)
            v[0xD] = floor(chunk_index / 2^32)  -- t1 = high_4_bytes(chunk_index)
            v[0xE], v[0xF] = block_length, flags
            for j = 1, 7 do
               G(0, 4,  8, 12, perm_blake3[j],      perm_blake3[j + 14])
               G(1, 5,  9, 13, perm_blake3[j + 1],  perm_blake3[j + 2])
               G(2, 6, 10, 14, perm_blake3[j + 16], perm_blake3[j + 7])
               G(3, 7, 11, 15, perm_blake3[j + 15], perm_blake3[j + 17])
               G(0, 5, 10, 15, perm_blake3[j + 21], perm_blake3[j + 5])
               G(1, 6, 11, 12, perm_blake3[j + 3],  perm_blake3[j + 6])
               G(2, 7,  8, 13, perm_blake3[j + 4],  perm_blake3[j + 18])
               G(3, 4,  9, 14, perm_blake3[j + 19], perm_blake3[j + 20])
            end
            if wide_output then
               H_out[ 9] = XOR(h1, v[0x8])
               H_out[10] = XOR(h2, v[0x9])
               H_out[11] = XOR(h3, v[0xA])
               H_out[12] = XOR(h4, v[0xB])
               H_out[13] = XOR(h5, v[0xC])
               H_out[14] = XOR(h6, v[0xD])
               H_out[15] = XOR(h7, v[0xE])
               H_out[16] = XOR(h8, v[0xF])
            end
            h1 = XOR(v[0x0], v[0x8])
            h2 = XOR(v[0x1], v[0x9])
            h3 = XOR(v[0x2], v[0xA])
            h4 = XOR(v[0x3], v[0xB])
            h5 = XOR(v[0x4], v[0xC])
            h6 = XOR(v[0x5], v[0xD])
            h7 = XOR(v[0x6], v[0xE])
            h8 = XOR(v[0x7], v[0xF])
         end
         H_out[1], H_out[2], H_out[3], H_out[4], H_out[5], H_out[6], H_out[7], H_out[8] = h1, h2, h3, h4, h5, h6, h7, h8
      end

   end

end


if branch == "INT64" then


   -- implementation for Lua 5.3/5.4

   hi_factor = 4294967296
   hi_factor_keccak = 4294967296
   lanes_index_base = 1

   HEX64, XORA5, XOR_BYTE, sha256_feed_64, sha512_feed_128, md5_feed_64, sha1_feed_64, keccak_feed, blake2s_feed_64, blake2b_feed_128, blake3_feed_64 = load[=[-- branch "INT64"
      local md5_next_shift, md5_K, sha2_K_lo, sha2_K_hi, build_keccak_format, sha3_RC_lo, sigma, common_W, sha2_H_lo, sha2_H_hi, perm_blake3 = ...
      local string_format, string_unpack = string.format, string.unpack

      local function HEX64(x)
         return string_format("%016x", x)
      end

      local function XORA5(x, y)
         return x ~ (y or 0xa5a5a5a5a5a5a5a5)
      end

      local function XOR_BYTE(x, y)
         return x ~ y
      end

      local function sha256_feed_64(H, str, offs, size)
         -- offs >= 0, size >= 0, size is multiple of 64
         local W, K = common_W, sha2_K_hi
         local h1, h2, h3, h4, h5, h6, h7, h8 = H[1], H[2], H[3], H[4], H[5], H[6], H[7], H[8]
         for pos = offs + 1, offs + size, 64 do
            W[1], W[2], W[3], W[4], W[5], W[6], W[7], W[8], W[9], W[10], W[11], W[12], W[13], W[14], W[15], W[16] =
               string_unpack(">I4I4I4I4I4I4I4I4I4I4I4I4I4I4I4I4", str, pos)
            for j = 17, 64 do
               local a = W[j-15]
               a = a<<32 | a
               local b = W[j-2]
               b = b<<32 | b
               W[j] = (a>>7 ~ a>>18 ~ a>>35) + (b>>17 ~ b>>19 ~ b>>42) + W[j-7] + W[j-16] & (1<<32)-1
            end
            local a, b, c, d, e, f, g, h = h1, h2, h3, h4, h5, h6, h7, h8
            for j = 1, 64 do
               e = e<<32 | e & (1<<32)-1
               local z = (e>>6 ~ e>>11 ~ e>>25) + (g ~ e & (f ~ g)) + h + K[j] + W[j]
               h = g
               g = f
               f = e
               e = z + d
               d = c
               c = b
               b = a
               a = a<<32 | a & (1<<32)-1
               a = z + ((a ~ c) & d ~ a & c) + (a>>2 ~ a>>13 ~ a>>22)
            end
            h1 = a + h1
            h2 = b + h2
            h3 = c + h3
            h4 = d + h4
            h5 = e + h5
            h6 = f + h6
            h7 = g + h7
            h8 = h + h8
         end
         H[1], H[2], H[3], H[4], H[5], H[6], H[7], H[8] = h1, h2, h3, h4, h5, h6, h7, h8
      end

      local function sha512_feed_128(H, _, str, offs, size)
         -- offs >= 0, size >= 0, size is multiple of 128
         local W, K = common_W, sha2_K_lo
         local h1, h2, h3, h4, h5, h6, h7, h8 = H[1], H[2], H[3], H[4], H[5], H[6], H[7], H[8]
         for pos = offs + 1, offs + size, 128 do
            W[1], W[2], W[3], W[4], W[5], W[6], W[7], W[8], W[9], W[10], W[11], W[12], W[13], W[14], W[15], W[16] =
               string_unpack(">i8i8i8i8i8i8i8i8i8i8i8i8i8i8i8i8", str, pos)
            for j = 17, 80 do
               local a = W[j-15]
               local b = W[j-2]
               W[j] = (a >> 1 ~ a >> 7 ~ a >> 8 ~ a << 56 ~ a << 63) + (b >> 6 ~ b >> 19 ~ b >> 61 ~ b << 3 ~ b << 45) + W[j-7] + W[j-16]
            end
            local a, b, c, d, e, f, g, h = h1, h2, h3, h4, h5, h6, h7, h8
            for j = 1, 80 do
               local z = (e >> 14 ~ e >> 18 ~ e >> 41 ~ e << 23 ~ e << 46 ~ e << 50) + (g ~ e & (f ~ g)) + h + K[j] + W[j]
               h = g
               g = f
               f = e
               e = z + d
               d = c
               c = b
               b = a
               a = z + ((a ~ c) & d ~ a & c) + (a >> 28 ~ a >> 34 ~ a >> 39 ~ a << 25 ~ a << 30 ~ a << 36)
            end
            h1 = a + h1
            h2 = b + h2
            h3 = c + h3
            h4 = d + h4
            h5 = e + h5
            h6 = f + h6
            h7 = g + h7
            h8 = h + h8
         end
         H[1], H[2], H[3], H[4], H[5], H[6], H[7], H[8] = h1, h2, h3, h4, h5, h6, h7, h8
      end

      local function md5_feed_64(H, str, offs, size)
         -- offs >= 0, size >= 0, size is multiple of 64
         local W, K, md5_next_shift = common_W, md5_K, md5_next_shift
         local h1, h2, h3, h4 = H[1], H[2], H[3], H[4]
         for pos = offs + 1, offs + size, 64 do
            W[1], W[2], W[3], W[4], W[5], W[6], W[7], W[8], W[9], W[10], W[11], W[12], W[13], W[14], W[15], W[16] =
               string_unpack("<I4I4I4I4I4I4I4I4I4I4I4I4I4I4I4I4", str, pos)
            local a, b, c, d = h1, h2, h3, h4
            local s = 32-7
            for j = 1, 16 do
               local F = (d ~ b & (c ~ d)) + a + K[j] + W[j]
               a = d
               d = c
               c = b
               b = ((F<<32 | F & (1<<32)-1) >> s) + b
               s = md5_next_shift[s]
            end
            s = 32-5
            for j = 17, 32 do
               local F = (c ~ d & (b ~ c)) + a + K[j] + W[(5*j-4 & 15) + 1]
               a = d
               d = c
               c = b
               b = ((F<<32 | F & (1<<32)-1) >> s) + b
               s = md5_next_shift[s]
            end
            s = 32-4
            for j = 33, 48 do
               local F = (b ~ c ~ d) + a + K[j] + W[(3*j+2 & 15) + 1]
               a = d
               d = c
               c = b
               b = ((F<<32 | F & (1<<32)-1) >> s) + b
               s = md5_next_shift[s]
            end
            s = 32-6
            for j = 49, 64 do
               local F = (c ~ (b | ~d)) + a + K[j] + W[(j*7-7 & 15) + 1]
               a = d
               d = c
               c = b
               b = ((F<<32 | F & (1<<32)-1) >> s) + b
               s = md5_next_shift[s]
            end
            h1 = a + h1
            h2 = b + h2
            h3 = c + h3
            h4 = d + h4
         end
         H[1], H[2], H[3], H[4] = h1, h2, h3, h4
      end

      local function sha1_feed_64(H, str, offs, size)
         -- offs >= 0, size >= 0, size is multiple of 64
         local W = common_W
         local h1, h2, h3, h4, h5 = H[1], H[2], H[3], H[4], H[5]
         for pos = offs + 1, offs + size, 64 do
            W[1], W[2], W[3], W[4], W[5], W[6], W[7], W[8], W[9], W[10], W[11], W[12], W[13], W[14], W[15], W[16] =
               string_unpack(">I4I4I4I4I4I4I4I4I4I4I4I4I4I4I4I4", str, pos)
            for j = 17, 80 do
               local a = W[j-3] ~ W[j-8] ~ W[j-14] ~ W[j-16]
               W[j] = (a<<32 | a) << 1 >> 32
            end
            local a, b, c, d, e = h1, h2, h3, h4, h5
            for j = 1, 20 do
               local z = ((a<<32 | a & (1<<32)-1) >> 27) + (d ~ b & (c ~ d)) + 0x5A827999 + W[j] + e      -- constant = floor(2^30 * sqrt(2))
               e = d
               d = c
               c = (b<<32 | b & (1<<32)-1) >> 2
               b = a
               a = z
            end
            for j = 21, 40 do
               local z = ((a<<32 | a & (1<<32)-1) >> 27) + (b ~ c ~ d) + 0x6ED9EBA1 + W[j] + e            -- 2^30 * sqrt(3)
               e = d
               d = c
               c = (b<<32 | b & (1<<32)-1) >> 2
               b = a
               a = z
            end
            for j = 41, 60 do
               local z = ((a<<32 | a & (1<<32)-1) >> 27) + ((b ~ c) & d ~ b & c) + 0x8F1BBCDC + W[j] + e  -- 2^30 * sqrt(5)
               e = d
               d = c
               c = (b<<32 | b & (1<<32)-1) >> 2
               b = a
               a = z
            end
            for j = 61, 80 do
               local z = ((a<<32 | a & (1<<32)-1) >> 27) + (b ~ c ~ d) + 0xCA62C1D6 + W[j] + e            -- 2^30 * sqrt(10)
               e = d
               d = c
               c = (b<<32 | b & (1<<32)-1) >> 2
               b = a
               a = z
            end
            h1 = a + h1
            h2 = b + h2
            h3 = c + h3
            h4 = d + h4
            h5 = e + h5
         end
         H[1], H[2], H[3], H[4], H[5] = h1, h2, h3, h4, h5
      end

      local keccak_format_i8 = build_keccak_format("i8")

      local function keccak_feed(lanes, _, str, offs, size, block_size_in_bytes)
         -- offs >= 0, size >= 0, size is multiple of block_size_in_bytes, block_size_in_bytes is positive multiple of 8
         local RC = sha3_RC_lo
         local qwords_qty = block_size_in_bytes / 8
         local keccak_format = keccak_format_i8[qwords_qty]
         for pos = offs + 1, offs + size, block_size_in_bytes do
            local qwords_from_message = {string_unpack(keccak_format, str, pos)}
            for j = 1, qwords_qty do
               lanes[j] = lanes[j] ~ qwords_from_message[j]
            end
            local L01, L02, L03, L04, L05, L06, L07, L08, L09, L10, L11, L12, L13, L14, L15, L16, L17, L18, L19, L20, L21, L22, L23, L24, L25 =
               lanes[1], lanes[2], lanes[3], lanes[4], lanes[5], lanes[6], lanes[7], lanes[8], lanes[9], lanes[10], lanes[11], lanes[12], lanes[13],
               lanes[14], lanes[15], lanes[16], lanes[17], lanes[18], lanes[19], lanes[20], lanes[21], lanes[22], lanes[23], lanes[24], lanes[25]
            for round_idx = 1, 24 do
               local C1 = L01 ~ L06 ~ L11 ~ L16 ~ L21
               local C2 = L02 ~ L07 ~ L12 ~ L17 ~ L22
               local C3 = L03 ~ L08 ~ L13 ~ L18 ~ L23
               local C4 = L04 ~ L09 ~ L14 ~ L19 ~ L24
               local C5 = L05 ~ L10 ~ L15 ~ L20 ~ L25
               local D = C1 ~ C3<<1 ~ C3>>63
               local T0 = D ~ L02
               local T1 = D ~ L07
               local T2 = D ~ L12
               local T3 = D ~ L17
               local T4 = D ~ L22
               L02 = T1<<44 ~ T1>>20
               L07 = T3<<45 ~ T3>>19
               L12 = T0<<1 ~ T0>>63
               L17 = T2<<10 ~ T2>>54
               L22 = T4<<2 ~ T4>>62
               D = C2 ~ C4<<1 ~ C4>>63
               T0 = D ~ L03
               T1 = D ~ L08
               T2 = D ~ L13
               T3 = D ~ L18
               T4 = D ~ L23
               L03 = T2<<43 ~ T2>>21
               L08 = T4<<61 ~ T4>>3
               L13 = T1<<6 ~ T1>>58
               L18 = T3<<15 ~ T3>>49
               L23 = T0<<62 ~ T0>>2
               D = C3 ~ C5<<1 ~ C5>>63
               T0 = D ~ L04
               T1 = D ~ L09
               T2 = D ~ L14
               T3 = D ~ L19
               T4 = D ~ L24
               L04 = T3<<21 ~ T3>>43
               L09 = T0<<28 ~ T0>>36
               L14 = T2<<25 ~ T2>>39
               L19 = T4<<56 ~ T4>>8
               L24 = T1<<55 ~ T1>>9
               D = C4 ~ C1<<1 ~ C1>>63
               T0 = D ~ L05
               T1 = D ~ L10
               T2 = D ~ L15
               T3 = D ~ L20
               T4 = D ~ L25
               L05 = T4<<14 ~ T4>>50
               L10 = T1<<20 ~ T1>>44
               L15 = T3<<8 ~ T3>>56
               L20 = T0<<27 ~ T0>>37
               L25 = T2<<39 ~ T2>>25
               D = C5 ~ C2<<1 ~ C2>>63
               T1 = D ~ L06
               T2 = D ~ L11
               T3 = D ~ L16
               T4 = D ~ L21
               L06 = T2<<3 ~ T2>>61
               L11 = T4<<18 ~ T4>>46
               L16 = T1<<36 ~ T1>>28
               L21 = T3<<41 ~ T3>>23
               L01 = D ~ L01
               L01, L02, L03, L04, L05 = L01 ~ ~L02 & L03, L02 ~ ~L03 & L04, L03 ~ ~L04 & L05, L04 ~ ~L05 & L01, L05 ~ ~L01 & L02
               L06, L07, L08, L09, L10 = L09 ~ ~L10 & L06, L10 ~ ~L06 & L07, L06 ~ ~L07 & L08, L07 ~ ~L08 & L09, L08 ~ ~L09 & L10
               L11, L12, L13, L14, L15 = L12 ~ ~L13 & L14, L13 ~ ~L14 & L15, L14 ~ ~L15 & L11, L15 ~ ~L11 & L12, L11 ~ ~L12 & L13
               L16, L17, L18, L19, L20 = L20 ~ ~L16 & L17, L16 ~ ~L17 & L18, L17 ~ ~L18 & L19, L18 ~ ~L19 & L20, L19 ~ ~L20 & L16
               L21, L22, L23, L24, L25 = L23 ~ ~L24 & L25, L24 ~ ~L25 & L21, L25 ~ ~L21 & L22, L21 ~ ~L22 & L23, L22 ~ ~L23 & L24
               L01 = L01 ~ RC[round_idx]
            end
            lanes[1]  = L01
            lanes[2]  = L02
            lanes[3]  = L03
            lanes[4]  = L04
            lanes[5]  = L05
            lanes[6]  = L06
            lanes[7]  = L07
            lanes[8]  = L08
            lanes[9]  = L09
            lanes[10] = L10
            lanes[11] = L11
            lanes[12] = L12
            lanes[13] = L13
            lanes[14] = L14
            lanes[15] = L15
            lanes[16] = L16
            lanes[17] = L17
            lanes[18] = L18
            lanes[19] = L19
            lanes[20] = L20
            lanes[21] = L21
            lanes[22] = L22
            lanes[23] = L23
            lanes[24] = L24
            lanes[25] = L25
         end
      end

      local function blake2s_feed_64(H, str, offs, size, bytes_compressed, last_block_size, is_last_node)
         -- offs >= 0, size >= 0, size is multiple of 64
         local W = common_W
         local h1, h2, h3, h4, h5, h6, h7, h8 = H[1], H[2], H[3], H[4], H[5], H[6], H[7], H[8]
         for pos = offs + 1, offs + size, 64 do
            if str then
               W[1], W[2], W[3], W[4], W[5], W[6], W[7], W[8], W[9], W[10], W[11], W[12], W[13], W[14], W[15], W[16] =
                  string_unpack("<I4I4I4I4I4I4I4I4I4I4I4I4I4I4I4I4", str, pos)
            end
            local v0, v1, v2, v3, v4, v5, v6, v7 = h1, h2, h3, h4, h5, h6, h7, h8
            local v8, v9, vA, vB, vC, vD, vE, vF = sha2_H_hi[1], sha2_H_hi[2], sha2_H_hi[3], sha2_H_hi[4], sha2_H_hi[5], sha2_H_hi[6], sha2_H_hi[7], sha2_H_hi[8]
            bytes_compressed = bytes_compressed + (last_block_size or 64)
            vC = vC ~ bytes_compressed        -- t0 = low_4_bytes(bytes_compressed)
            vD = vD ~ bytes_compressed >> 32  -- t1 = high_4_bytes(bytes_compressed)
            if last_block_size then  -- flag f0
               vE = ~vE
            end
            if is_last_node then  -- flag f1
               vF = ~vF
            end
            for j = 1, 10 do
               local row = sigma[j]
               v0 = v0 + v4 + W[row[1]]
               vC = vC ~ v0
               vC = (vC & (1<<32)-1) >> 16 | vC << 16
               v8 = v8 + vC
               v4 = v4 ~ v8
               v4 = (v4 & (1<<32)-1) >> 12 | v4 << 20
               v0 = v0 + v4 + W[row[2]]
               vC = vC ~ v0
               vC = (vC & (1<<32)-1) >> 8 | vC << 24
               v8 = v8 + vC
               v4 = v4 ~ v8
               v4 = (v4 & (1<<32)-1) >> 7 | v4 << 25
               v1 = v1 + v5 + W[row[3]]
               vD = vD ~ v1
               vD = (vD & (1<<32)-1) >> 16 | vD << 16
               v9 = v9 + vD
               v5 = v5 ~ v9
               v5 = (v5 & (1<<32)-1) >> 12 | v5 << 20
               v1 = v1 + v5 + W[row[4]]
               vD = vD ~ v1
               vD = (vD & (1<<32)-1) >> 8 | vD << 24
               v9 = v9 + vD
               v5 = v5 ~ v9
               v5 = (v5 & (1<<32)-1) >> 7 | v5 << 25
               v2 = v2 + v6 + W[row[5]]
               vE = vE ~ v2
               vE = (vE & (1<<32)-1) >> 16 | vE << 16
               vA = vA + vE
               v6 = v6 ~ vA
               v6 = (v6 & (1<<32)-1) >> 12 | v6 << 20
               v2 = v2 + v6 + W[row[6]]
               vE = vE ~ v2
               vE = (vE & (1<<32)-1) >> 8 | vE << 24
               vA = vA + vE
               v6 = v6 ~ vA
               v6 = (v6 & (1<<32)-1) >> 7 | v6 << 25
               v3 = v3 + v7 + W[row[7]]
               vF = vF ~ v3
               vF = (vF & (1<<32)-1) >> 16 | vF << 16
               vB = vB + vF
               v7 = v7 ~ vB
               v7 = (v7 & (1<<32)-1) >> 12 | v7 << 20
               v3 = v3 + v7 + W[row[8]]
               vF = vF ~ v3
               vF = (vF & (1<<32)-1) >> 8 | vF << 24
               vB = vB + vF
               v7 = v7 ~ vB
               v7 = (v7 & (1<<32)-1) >> 7 | v7 << 25
               v0 = v0 + v5 + W[row[9]]
               vF = vF ~ v0
               vF = (vF & (1<<32)-1) >> 16 | vF << 16
               vA = vA + vF
               v5 = v5 ~ vA
               v5 = (v5 & (1<<32)-1) >> 12 | v5 << 20
               v0 = v0 + v5 + W[row[10]]
               vF = vF ~ v0
               vF = (vF & (1<<32)-1) >> 8 | vF << 24
               vA = vA + vF
               v5 = v5 ~ vA
               v5 = (v5 & (1<<32)-1) >> 7 | v5 << 25
               v1 = v1 + v6 + W[row[11]]
               vC = vC ~ v1
               vC = (vC & (1<<32)-1) >> 16 | vC << 16
               vB = vB + vC
               v6 = v6 ~ vB
               v6 = (v6 & (1<<32)-1) >> 12 | v6 << 20
               v1 = v1 + v6 + W[row[12]]
               vC = vC ~ v1
               vC = (vC & (1<<32)-1) >> 8 | vC << 24
               vB = vB + vC
               v6 = v6 ~ vB
               v6 = (v6 & (1<<32)-1) >> 7 | v6 << 25
               v2 = v2 + v7 + W[row[13]]
               vD = vD ~ v2
               vD = (vD & (1<<32)-1) >> 16 | vD << 16
               v8 = v8 + vD
               v7 = v7 ~ v8
               v7 = (v7 & (1<<32)-1) >> 12 | v7 << 20
               v2 = v2 + v7 + W[row[14]]
               vD = vD ~ v2
               vD = (vD & (1<<32)-1) >> 8 | vD << 24
               v8 = v8 + vD
               v7 = v7 ~ v8
               v7 = (v7 & (1<<32)-1) >> 7 | v7 << 25
               v3 = v3 + v4 + W[row[15]]
               vE = vE ~ v3
               vE = (vE & (1<<32)-1) >> 16 | vE << 16
               v9 = v9 + vE
               v4 = v4 ~ v9
               v4 = (v4 & (1<<32)-1) >> 12 | v4 << 20
               v3 = v3 + v4 + W[row[16]]
               vE = vE ~ v3
               vE = (vE & (1<<32)-1) >> 8 | vE << 24
               v9 = v9 + vE
               v4 = v4 ~ v9
               v4 = (v4 & (1<<32)-1) >> 7 | v4 << 25
            end
            h1 = h1 ~ v0 ~ v8
            h2 = h2 ~ v1 ~ v9
            h3 = h3 ~ v2 ~ vA
            h4 = h4 ~ v3 ~ vB
            h5 = h5 ~ v4 ~ vC
            h6 = h6 ~ v5 ~ vD
            h7 = h7 ~ v6 ~ vE
            h8 = h8 ~ v7 ~ vF
         end
         H[1], H[2], H[3], H[4], H[5], H[6], H[7], H[8] = h1, h2, h3, h4, h5, h6, h7, h8
         return bytes_compressed
      end

      local function blake2b_feed_128(H, _, str, offs, size, bytes_compressed, last_block_size, is_last_node)
         -- offs >= 0, size >= 0, size is multiple of 128
         local W = common_W
         local h1, h2, h3, h4, h5, h6, h7, h8 = H[1], H[2], H[3], H[4], H[5], H[6], H[7], H[8]
         for pos = offs + 1, offs + size, 128 do
            if str then
               W[1], W[2], W[3], W[4], W[5], W[6], W[7], W[8], W[9], W[10], W[11], W[12], W[13], W[14], W[15], W[16] =
                  string_unpack("<i8i8i8i8i8i8i8i8i8i8i8i8i8i8i8i8", str, pos)
            end
            local v0, v1, v2, v3, v4, v5, v6, v7 = h1, h2, h3, h4, h5, h6, h7, h8
            local v8, v9, vA, vB, vC, vD, vE, vF = sha2_H_lo[1], sha2_H_lo[2], sha2_H_lo[3], sha2_H_lo[4], sha2_H_lo[5], sha2_H_lo[6], sha2_H_lo[7], sha2_H_lo[8]
            bytes_compressed = bytes_compressed + (last_block_size or 128)
            vC = vC ~ bytes_compressed  -- t0 = low_8_bytes(bytes_compressed)
            -- t1 = high_8_bytes(bytes_compressed) = 0,  message length is always below 2^53 bytes
            if last_block_size then  -- flag f0
               vE = ~vE
            end
            if is_last_node then  -- flag f1
               vF = ~vF
            end
            for j = 1, 12 do
               local row = sigma[j]
               v0 = v0 + v4 + W[row[1]]
               vC = vC ~ v0
               vC = vC >> 32 | vC << 32
               v8 = v8 + vC
               v4 = v4 ~ v8
               v4 = v4 >> 24 | v4 << 40
               v0 = v0 + v4 + W[row[2]]
               vC = vC ~ v0
               vC = vC >> 16 | vC << 48
               v8 = v8 + vC
               v4 = v4 ~ v8
               v4 = v4 >> 63 | v4 << 1
               v1 = v1 + v5 + W[row[3]]
               vD = vD ~ v1
               vD = vD >> 32 | vD << 32
               v9 = v9 + vD
               v5 = v5 ~ v9
               v5 = v5 >> 24 | v5 << 40
               v1 = v1 + v5 + W[row[4]]
               vD = vD ~ v1
               vD = vD >> 16 | vD << 48
               v9 = v9 + vD
               v5 = v5 ~ v9
               v5 = v5 >> 63 | v5 << 1
               v2 = v2 + v6 + W[row[5]]
               vE = vE ~ v2
               vE = vE >> 32 | vE << 32
               vA = vA + vE
               v6 = v6 ~ vA
               v6 = v6 >> 24 | v6 << 40
               v2 = v2 + v6 + W[row[6]]
               vE = vE ~ v2
               vE = vE >> 16 | vE << 48
               vA = vA + vE
               v6 = v6 ~ vA
               v6 = v6 >> 63 | v6 << 1
               v3 = v3 + v7 + W[row[7]]
               vF = vF ~ v3
               vF = vF >> 32 | vF << 32
               vB = vB + vF
               v7 = v7 ~ vB
               v7 = v7 >> 24 | v7 << 40
               v3 = v3 + v7 + W[row[8]]
               vF = vF ~ v3
               vF = vF >> 16 | vF << 48
               vB = vB + vF
               v7 = v7 ~ vB
               v7 = v7 >> 63 | v7 << 1
               v0 = v0 + v5 + W[row[9]]
               vF = vF ~ v0
               vF = vF >> 32 | vF << 32
               vA = vA + vF
               v5 = v5 ~ vA
               v5 = v5 >> 24 | v5 << 40
               v0 = v0 + v5 + W[row[10]]
               vF = vF ~ v0
               vF = vF >> 16 | vF << 48
               vA = vA + vF
               v5 = v5 ~ vA
               v5 = v5 >> 63 | v5 << 1
               v1 = v1 + v6 + W[row[11]]
               vC = vC ~ v1
               vC = vC >> 32 | vC << 32
               vB = vB + vC
               v6 = v6 ~ vB
               v6 = v6 >> 24 | v6 << 40
               v1 = v1 + v6 + W[row[12]]
               vC = vC ~ v1
               vC = vC >> 16 | vC << 48
               vB = vB + vC
               v6 = v6 ~ vB
               v6 = v6 >> 63 | v6 << 1
               v2 = v2 + v7 + W[row[13]]
               vD = vD ~ v2
               vD = vD >> 32 | vD << 32
               v8 = v8 + vD
               v7 = v7 ~ v8
               v7 = v7 >> 24 | v7 << 40
               v2 = v2 + v7 + W[row[14]]
               vD = vD ~ v2
               vD = vD >> 16 | vD << 48
               v8 = v8 + vD
               v7 = v7 ~ v8
               v7 = v7 >> 63 | v7 << 1
               v3 = v3 + v4 + W[row[15]]
               vE = vE ~ v3
               vE = vE >> 32 | vE << 32
               v9 = v9 + vE
               v4 = v4 ~ v9
               v4 = v4 >> 24 | v4 << 40
               v3 = v3 + v4 + W[row[16]]
               vE = vE ~ v3
               vE = vE >> 16 | vE << 48
               v9 = v9 + vE
               v4 = v4 ~ v9
               v4 = v4 >> 63 | v4 << 1
            end
            h1 = h1 ~ v0 ~ v8
            h2 = h2 ~ v1 ~ v9
            h3 = h3 ~ v2 ~ vA
            h4 = h4 ~ v3 ~ vB
            h5 = h5 ~ v4 ~ vC
            h6 = h6 ~ v5 ~ vD
            h7 = h7 ~ v6 ~ vE
            h8 = h8 ~ v7 ~ vF
         end
         H[1], H[2], H[3], H[4], H[5], H[6], H[7], H[8] = h1, h2, h3, h4, h5, h6, h7, h8
         return bytes_compressed
      end

      local function blake3_feed_64(str, offs, size, flags, chunk_index, H_in, H_out, wide_output, block_length)
         -- offs >= 0, size >= 0, size is multiple of 64
         block_length = block_length or 64
         local W = common_W
         local h1, h2, h3, h4, h5, h6, h7, h8 = H_in[1], H_in[2], H_in[3], H_in[4], H_in[5], H_in[6], H_in[7], H_in[8]
         H_out = H_out or H_in
         for pos = offs + 1, offs + size, 64 do
            if str then
               W[1], W[2], W[3], W[4], W[5], W[6], W[7], W[8], W[9], W[10], W[11], W[12], W[13], W[14], W[15], W[16] =
                  string_unpack("<I4I4I4I4I4I4I4I4I4I4I4I4I4I4I4I4", str, pos)
            end
            local v0, v1, v2, v3, v4, v5, v6, v7 = h1, h2, h3, h4, h5, h6, h7, h8
            local v8, v9, vA, vB = sha2_H_hi[1], sha2_H_hi[2], sha2_H_hi[3], sha2_H_hi[4]
            local t0 = chunk_index % 2^32         -- t0 = low_4_bytes(chunk_index)
            local t1 = (chunk_index - t0) / 2^32  -- t1 = high_4_bytes(chunk_index)
            local vC, vD, vE, vF = 0|t0, 0|t1, block_length, flags
            for j = 1, 7 do
               v0 = v0 + v4 + W[perm_blake3[j]]
               vC = vC ~ v0
               vC = (vC & (1<<32)-1) >> 16 | vC << 16
               v8 = v8 + vC
               v4 = v4 ~ v8
               v4 = (v4 & (1<<32)-1) >> 12 | v4 << 20
               v0 = v0 + v4 + W[perm_blake3[j + 14]]
               vC = vC ~ v0
               vC = (vC & (1<<32)-1) >> 8 | vC << 24
               v8 = v8 + vC
               v4 = v4 ~ v8
               v4 = (v4 & (1<<32)-1) >> 7 | v4 << 25
               v1 = v1 + v5 + W[perm_blake3[j + 1]]
               vD = vD ~ v1
               vD = (vD & (1<<32)-1) >> 16 | vD << 16
               v9 = v9 + vD
               v5 = v5 ~ v9
               v5 = (v5 & (1<<32)-1) >> 12 | v5 << 20
               v1 = v1 + v5 + W[perm_blake3[j + 2]]
               vD = vD ~ v1
               vD = (vD & (1<<32)-1) >> 8 | vD << 24
               v9 = v9 + vD
               v5 = v5 ~ v9
               v5 = (v5 & (1<<32)-1) >> 7 | v5 << 25
               v2 = v2 + v6 + W[perm_blake3[j + 16]]
               vE = vE ~ v2
               vE = (vE & (1<<32)-1) >> 16 | vE << 16
               vA = vA + vE
               v6 = v6 ~ vA
               v6 = (v6 & (1<<32)-1) >> 12 | v6 << 20
               v2 = v2 + v6 + W[perm_blake3[j + 7]]
               vE = vE ~ v2
               vE = (vE & (1<<32)-1) >> 8 | vE << 24
               vA = vA + vE
               v6 = v6 ~ vA
               v6 = (v6 & (1<<32)-1) >> 7 | v6 << 25
               v3 = v3 + v7 + W[perm_blake3[j + 15]]
               vF = vF ~ v3
               vF = (vF & (1<<32)-1) >> 16 | vF << 16
               vB = vB + vF
               v7 = v7 ~ vB
               v7 = (v7 & (1<<32)-1) >> 12 | v7 << 20
               v3 = v3 + v7 + W[perm_blake3[j + 17]]
               vF = vF ~ v3
               vF = (vF & (1<<32)-1) >> 8 | vF << 24
               vB = vB + vF
               v7 = v7 ~ vB
               v7 = (v7 & (1<<32)-1) >> 7 | v7 << 25
               v0 = v0 + v5 + W[perm_blake3[j + 21]]
               vF = vF ~ v0
               vF = (vF & (1<<32)-1) >> 16 | vF << 16
               vA = vA + vF
               v5 = v5 ~ vA
               v5 = (v5 & (1<<32)-1) >> 12 | v5 << 20
               v0 = v0 + v5 + W[perm_blake3[j + 5]]
               vF = vF ~ v0
               vF = (vF & (1<<32)-1) >> 8 | vF << 24
               vA = vA + vF
               v5 = v5 ~ vA
               v5 = (v5 & (1<<32)-1) >> 7 | v5 << 25
               v1 = v1 + v6 + W[perm_blake3[j + 3]]
               vC = vC ~ v1
               vC = (vC & (1<<32)-1) >> 16 | vC << 16
               vB = vB + vC
               v6 = v6 ~ vB
               v6 = (v6 & (1<<32)-1) >> 12 | v6 << 20
               v1 = v1 + v6 + W[perm_blake3[j + 6]]
               vC = vC ~ v1
               vC = (vC & (1<<32)-1) >> 8 | vC << 24
               vB = vB + vC
               v6 = v6 ~ vB
               v6 = (v6 & (1<<32)-1) >> 7 | v6 << 25
               v2 = v2 + v7 + W[perm_blake3[j + 4]]
               vD = vD ~ v2
               vD = (vD & (1<<32)-1) >> 16 | vD << 16
               v8 = v8 + vD
               v7 = v7 ~ v8
               v7 = (v7 & (1<<32)-1) >> 12 | v7 << 20
               v2 = v2 + v7 + W[perm_blake3[j + 18]]
               vD = vD ~ v2
               vD = (vD & (1<<32)-1) >> 8 | vD << 24
               v8 = v8 + vD
               v7 = v7 ~ v8
               v7 = (v7 & (1<<32)-1) >> 7 | v7 << 25
               v3 = v3 + v4 + W[perm_blake3[j + 19]]
               vE = vE ~ v3
               vE = (vE & (1<<32)-1) >> 16 | vE << 16
               v9 = v9 + vE
               v4 = v4 ~ v9
               v4 = (v4 & (1<<32)-1) >> 12 | v4 << 20
               v3 = v3 + v4 + W[perm_blake3[j + 20]]
               vE = vE ~ v3
               vE = (vE & (1<<32)-1) >> 8 | vE << 24
               v9 = v9 + vE
               v4 = v4 ~ v9
               v4 = (v4 & (1<<32)-1) >> 7 | v4 << 25
            end
            if wide_output then
               H_out[ 9] = h1 ~ v8
               H_out[10] = h2 ~ v9
               H_out[11] = h3 ~ vA
               H_out[12] = h4 ~ vB
               H_out[13] = h5 ~ vC
               H_out[14] = h6 ~ vD
               H_out[15] = h7 ~ vE
               H_out[16] = h8 ~ vF
            end
            h1 = v0 ~ v8
            h2 = v1 ~ v9
            h3 = v2 ~ vA
            h4 = v3 ~ vB
            h5 = v4 ~ vC
            h6 = v5 ~ vD
            h7 = v6 ~ vE
            h8 = v7 ~ vF
         end
         H_out[1], H_out[2], H_out[3], H_out[4], H_out[5], H_out[6], H_out[7], H_out[8] = h1, h2, h3, h4, h5, h6, h7, h8
      end

      return HEX64, XORA5, XOR_BYTE, sha256_feed_64, sha512_feed_128, md5_feed_64, sha1_feed_64, keccak_feed, blake2s_feed_64, blake2b_feed_128, blake3_feed_64
   ]=](md5_next_shift, md5_K, sha2_K_lo, sha2_K_hi, build_keccak_format, sha3_RC_lo, sigma, common_W, sha2_H_lo, sha2_H_hi, perm_blake3)

end


if branch == "INT32" then


   -- implementation for Lua 5.3/5.4 having non-standard numbers config "int32"+"double" (built with LUA_INT_TYPE=LUA_INT_INT)

   K_lo_modulo = 2^32

   function HEX(x) -- returns string of 8 lowercase hexadecimal digits
      return string_format("%08x", x)
   end

   XORA5, XOR_BYTE, sha256_feed_64, sha512_feed_128, md5_feed_64, sha1_feed_64, keccak_feed, blake2s_feed_64, blake2b_feed_128, blake3_feed_64 = load[=[-- branch "INT32"
      local md5_next_shift, md5_K, sha2_K_lo, sha2_K_hi, build_keccak_format, sha3_RC_lo, sha3_RC_hi, sigma, common_W, sha2_H_lo, sha2_H_hi, perm_blake3 = ...
      local string_unpack, floor = string.unpack, math.floor

      local function XORA5(x, y)
         return x ~ (y and (y + 2^31) % 2^32 - 2^31 or 0xA5A5A5A5)
      end

      local function XOR_BYTE(x, y)
         return x ~ y
      end

      local function sha256_feed_64(H, str, offs, size)
         -- offs >= 0, size >= 0, size is multiple of 64
         local W, K = common_W, sha2_K_hi
         local h1, h2, h3, h4, h5, h6, h7, h8 = H[1], H[2], H[3], H[4], H[5], H[6], H[7], H[8]
         for pos = offs + 1, offs + size, 64 do
            W[1], W[2], W[3], W[4], W[5], W[6], W[7], W[8], W[9], W[10], W[11], W[12], W[13], W[14], W[15], W[16] =
               string_unpack(">i4i4i4i4i4i4i4i4i4i4i4i4i4i4i4i4", str, pos)
            for j = 17, 64 do
               local a, b = W[j-15], W[j-2]
               W[j] = (a>>7 ~ a<<25 ~ a<<14 ~ a>>18 ~ a>>3) + (b<<15 ~ b>>17 ~ b<<13 ~ b>>19 ~ b>>10) + W[j-7] + W[j-16]
            end
            local a, b, c, d, e, f, g, h = h1, h2, h3, h4, h5, h6, h7, h8
            for j = 1, 64 do
               local z = (e>>6 ~ e<<26 ~ e>>11 ~ e<<21 ~ e>>25 ~ e<<7) + (g ~ e & (f ~ g)) + h + K[j] + W[j]
               h = g
               g = f
               f = e
               e = z + d
               d = c
               c = b
               b = a
               a = z + ((a ~ c) & d ~ a & c) + (a>>2 ~ a<<30 ~ a>>13 ~ a<<19 ~ a<<10 ~ a>>22)
            end
            h1 = a + h1
            h2 = b + h2
            h3 = c + h3
            h4 = d + h4
            h5 = e + h5
            h6 = f + h6
            h7 = g + h7
            h8 = h + h8
         end
         H[1], H[2], H[3], H[4], H[5], H[6], H[7], H[8] = h1, h2, h3, h4, h5, h6, h7, h8
      end

      local function sha512_feed_128(H_lo, H_hi, str, offs, size)
         -- offs >= 0, size >= 0, size is multiple of 128
         -- W1_hi, W1_lo, W2_hi, W2_lo, ...   Wk_hi = W[2*k-1], Wk_lo = W[2*k]
         local floor, W, K_lo, K_hi = floor, common_W, sha2_K_lo, sha2_K_hi
         local h1_lo, h2_lo, h3_lo, h4_lo, h5_lo, h6_lo, h7_lo, h8_lo = H_lo[1], H_lo[2], H_lo[3], H_lo[4], H_lo[5], H_lo[6], H_lo[7], H_lo[8]
         local h1_hi, h2_hi, h3_hi, h4_hi, h5_hi, h6_hi, h7_hi, h8_hi = H_hi[1], H_hi[2], H_hi[3], H_hi[4], H_hi[5], H_hi[6], H_hi[7], H_hi[8]
         for pos = offs + 1, offs + size, 128 do
            W[1], W[2], W[3], W[4], W[5], W[6], W[7], W[8], W[9], W[10], W[11], W[12], W[13], W[14], W[15], W[16],
               W[17], W[18], W[19], W[20], W[21], W[22], W[23], W[24], W[25], W[26], W[27], W[28], W[29], W[30], W[31], W[32] =
               string_unpack(">i4i4i4i4i4i4i4i4i4i4i4i4i4i4i4i4i4i4i4i4i4i4i4i4i4i4i4i4i4i4i4i4", str, pos)
            for jj = 17*2, 80*2, 2 do
               local a_lo, a_hi, b_lo, b_hi = W[jj-30], W[jj-31], W[jj-4], W[jj-5]
               local tmp =
                  (a_lo>>1 ~ a_hi<<31 ~ a_lo>>8 ~ a_hi<<24 ~ a_lo>>7 ~ a_hi<<25) % 2^32
                  + (b_lo>>19 ~ b_hi<<13 ~ b_lo<<3 ~ b_hi>>29 ~ b_lo>>6 ~ b_hi<<26) % 2^32
                  + W[jj-14] % 2^32 + W[jj-32] % 2^32
               W[jj-1] =
                  (a_hi>>1 ~ a_lo<<31 ~ a_hi>>8 ~ a_lo<<24 ~ a_hi>>7)
                  + (b_hi>>19 ~ b_lo<<13 ~ b_hi<<3 ~ b_lo>>29 ~ b_hi>>6)
                  + W[jj-15] + W[jj-33] + floor(tmp / 2^32)
               W[jj] = 0|((tmp + 2^31) % 2^32 - 2^31)
            end
            local a_lo, b_lo, c_lo, d_lo, e_lo, f_lo, g_lo, h_lo = h1_lo, h2_lo, h3_lo, h4_lo, h5_lo, h6_lo, h7_lo, h8_lo
            local a_hi, b_hi, c_hi, d_hi, e_hi, f_hi, g_hi, h_hi = h1_hi, h2_hi, h3_hi, h4_hi, h5_hi, h6_hi, h7_hi, h8_hi
            for j = 1, 80 do
               local jj = 2*j
               local z_lo = (e_lo>>14 ~ e_hi<<18 ~ e_lo>>18 ~ e_hi<<14 ~ e_lo<<23 ~ e_hi>>9) % 2^32 + (g_lo ~ e_lo & (f_lo ~ g_lo)) % 2^32 + h_lo % 2^32 + K_lo[j] + W[jj] % 2^32
               local z_hi = (e_hi>>14 ~ e_lo<<18 ~ e_hi>>18 ~ e_lo<<14 ~ e_hi<<23 ~ e_lo>>9) + (g_hi ~ e_hi & (f_hi ~ g_hi)) + h_hi + K_hi[j] + W[jj-1] + floor(z_lo / 2^32)
               z_lo = z_lo % 2^32
               h_lo = g_lo;  h_hi = g_hi
               g_lo = f_lo;  g_hi = f_hi
               f_lo = e_lo;  f_hi = e_hi
               e_lo = z_lo + d_lo % 2^32
               e_hi = z_hi + d_hi + floor(e_lo / 2^32)
               e_lo = 0|((e_lo + 2^31) % 2^32 - 2^31)
               d_lo = c_lo;  d_hi = c_hi
               c_lo = b_lo;  c_hi = b_hi
               b_lo = a_lo;  b_hi = a_hi
               z_lo = z_lo + (d_lo & c_lo ~ b_lo & (d_lo ~ c_lo)) % 2^32 + (b_lo>>28 ~ b_hi<<4 ~ b_lo<<30 ~ b_hi>>2 ~ b_lo<<25 ~ b_hi>>7) % 2^32
               a_hi = z_hi + (d_hi & c_hi ~ b_hi & (d_hi ~ c_hi)) + (b_hi>>28 ~ b_lo<<4 ~ b_hi<<30 ~ b_lo>>2 ~ b_hi<<25 ~ b_lo>>7) + floor(z_lo / 2^32)
               a_lo = 0|((z_lo + 2^31) % 2^32 - 2^31)
            end
            a_lo = h1_lo % 2^32 + a_lo % 2^32
            h1_hi = h1_hi + a_hi + floor(a_lo / 2^32)
            h1_lo = 0|((a_lo + 2^31) % 2^32 - 2^31)
            a_lo = h2_lo % 2^32 + b_lo % 2^32
            h2_hi = h2_hi + b_hi + floor(a_lo / 2^32)
            h2_lo = 0|((a_lo + 2^31) % 2^32 - 2^31)
            a_lo = h3_lo % 2^32 + c_lo % 2^32
            h3_hi = h3_hi + c_hi + floor(a_lo / 2^32)
            h3_lo = 0|((a_lo + 2^31) % 2^32 - 2^31)
            a_lo = h4_lo % 2^32 + d_lo % 2^32
            h4_hi = h4_hi + d_hi + floor(a_lo / 2^32)
            h4_lo = 0|((a_lo + 2^31) % 2^32 - 2^31)
            a_lo = h5_lo % 2^32 + e_lo % 2^32
            h5_hi = h5_hi + e_hi + floor(a_lo / 2^32)
            h5_lo = 0|((a_lo + 2^31) % 2^32 - 2^31)
            a_lo = h6_lo % 2^32 + f_lo % 2^32
            h6_hi = h6_hi + f_hi + floor(a_lo / 2^32)
            h6_lo = 0|((a_lo + 2^31) % 2^32 - 2^31)
            a_lo = h7_lo % 2^32 + g_lo % 2^32
            h7_hi = h7_hi + g_hi + floor(a_lo / 2^32)
            h7_lo = 0|((a_lo + 2^31) % 2^32 - 2^31)
            a_lo = h8_lo % 2^32 + h_lo % 2^32
            h8_hi = h8_hi + h_hi + floor(a_lo / 2^32)
            h8_lo = 0|((a_lo + 2^31) % 2^32 - 2^31)
         end
         H_lo[1], H_lo[2], H_lo[3], H_lo[4], H_lo[5], H_lo[6], H_lo[7], H_lo[8] = h1_lo, h2_lo, h3_lo, h4_lo, h5_lo, h6_lo, h7_lo, h8_lo
         H_hi[1], H_hi[2], H_hi[3], H_hi[4], H_hi[5], H_hi[6], H_hi[7], H_hi[8] = h1_hi, h2_hi, h3_hi, h4_hi, h5_hi, h6_hi, h7_hi, h8_hi
      end

      local function md5_feed_64(H, str, offs, size)
         -- offs >= 0, size >= 0, size is multiple of 64
         local W, K, md5_next_shift = common_W, md5_K, md5_next_shift
         local h1, h2, h3, h4 = H[1], H[2], H[3], H[4]
         for pos = offs + 1, offs + size, 64 do
            W[1], W[2], W[3], W[4], W[5], W[6], W[7], W[8], W[9], W[10], W[11], W[12], W[13], W[14], W[15], W[16] =
               string_unpack("<i4i4i4i4i4i4i4i4i4i4i4i4i4i4i4i4", str, pos)
            local a, b, c, d = h1, h2, h3, h4
            local s = 32-7
            for j = 1, 16 do
               local F = (d ~ b & (c ~ d)) + a + K[j] + W[j]
               a = d
               d = c
               c = b
               b = (F << 32-s | F>>s) + b
               s = md5_next_shift[s]
            end
            s = 32-5
            for j = 17, 32 do
               local F = (c ~ d & (b ~ c)) + a + K[j] + W[(5*j-4 & 15) + 1]
               a = d
               d = c
               c = b
               b = (F << 32-s | F>>s) + b
               s = md5_next_shift[s]
            end
            s = 32-4
            for j = 33, 48 do
               local F = (b ~ c ~ d) + a + K[j] + W[(3*j+2 & 15) + 1]
               a = d
               d = c
               c = b
               b = (F << 32-s | F>>s) + b
               s = md5_next_shift[s]
            end
            s = 32-6
            for j = 49, 64 do
               local F = (c ~ (b | ~d)) + a + K[j] + W[(j*7-7 & 15) + 1]
               a = d
               d = c
               c = b
               b = (F << 32-s | F>>s) + b
               s = md5_next_shift[s]
            end
            h1 = a + h1
            h2 = b + h2
            h3 = c + h3
            h4 = d + h4
         end
         H[1], H[2], H[3], H[4] = h1, h2, h3, h4
      end

      local function sha1_feed_64(H, str, offs, size)
         -- offs >= 0, size >= 0, size is multiple of 64
         local W = common_W
         local h1, h2, h3, h4, h5 = H[1], H[2], H[3], H[4], H[5]
         for pos = offs + 1, offs + size, 64 do
            W[1], W[2], W[3], W[4], W[5], W[6], W[7], W[8], W[9], W[10], W[11], W[12], W[13], W[14], W[15], W[16] =
               string_unpack(">i4i4i4i4i4i4i4i4i4i4i4i4i4i4i4i4", str, pos)
            for j = 17, 80 do
               local a = W[j-3] ~ W[j-8] ~ W[j-14] ~ W[j-16]
               W[j] = a << 1 ~ a >> 31
            end
            local a, b, c, d, e = h1, h2, h3, h4, h5
            for j = 1, 20 do
               local z = (a << 5 ~ a >> 27) + (d ~ b & (c ~ d)) + 0x5A827999 + W[j] + e      -- constant = floor(2^30 * sqrt(2))
               e = d
               d = c
               c = b << 30 ~ b >> 2
               b = a
               a = z
            end
            for j = 21, 40 do
               local z = (a << 5 ~ a >> 27) + (b ~ c ~ d) + 0x6ED9EBA1 + W[j] + e            -- 2^30 * sqrt(3)
               e = d
               d = c
               c = b << 30 ~ b >> 2
               b = a
               a = z
            end
            for j = 41, 60 do
               local z = (a << 5 ~ a >> 27) + ((b ~ c) & d ~ b & c) + 0x8F1BBCDC + W[j] + e  -- 2^30 * sqrt(5)
               e = d
               d = c
               c = b << 30 ~ b >> 2
               b = a
               a = z
            end
            for j = 61, 80 do
               local z = (a << 5 ~ a >> 27) + (b ~ c ~ d) + 0xCA62C1D6 + W[j] + e            -- 2^30 * sqrt(10)
               e = d
               d = c
               c = b << 30 ~ b >> 2
               b = a
               a = z
            end
            h1 = a + h1
            h2 = b + h2
            h3 = c + h3
            h4 = d + h4
            h5 = e + h5
         end
         H[1], H[2], H[3], H[4], H[5] = h1, h2, h3, h4, h5
      end

      local keccak_format_i4i4 = build_keccak_format("i4i4")

      local function keccak_feed(lanes_lo, lanes_hi, str, offs, size, block_size_in_bytes)
         -- offs >= 0, size >= 0, size is multiple of block_size_in_bytes, block_size_in_bytes is positive multiple of 8
         local RC_lo, RC_hi = sha3_RC_lo, sha3_RC_hi
         local qwords_qty = block_size_in_bytes / 8
         local keccak_format = keccak_format_i4i4[qwords_qty]
         for pos = offs + 1, offs + size, block_size_in_bytes do
            local dwords_from_message = {string_unpack(keccak_format, str, pos)}
            for j = 1, qwords_qty do
               lanes_lo[j] = lanes_lo[j] ~ dwords_from_message[2*j-1]
               lanes_hi[j] = lanes_hi[j] ~ dwords_from_message[2*j]
            end
            local L01_lo, L01_hi, L02_lo, L02_hi, L03_lo, L03_hi, L04_lo, L04_hi, L05_lo, L05_hi, L06_lo, L06_hi, L07_lo, L07_hi, L08_lo, L08_hi,
               L09_lo, L09_hi, L10_lo, L10_hi, L11_lo, L11_hi, L12_lo, L12_hi, L13_lo, L13_hi, L14_lo, L14_hi, L15_lo, L15_hi, L16_lo, L16_hi,
               L17_lo, L17_hi, L18_lo, L18_hi, L19_lo, L19_hi, L20_lo, L20_hi, L21_lo, L21_hi, L22_lo, L22_hi, L23_lo, L23_hi, L24_lo, L24_hi, L25_lo, L25_hi =
               lanes_lo[1], lanes_hi[1], lanes_lo[2], lanes_hi[2], lanes_lo[3], lanes_hi[3], lanes_lo[4], lanes_hi[4], lanes_lo[5], lanes_hi[5],
               lanes_lo[6], lanes_hi[6], lanes_lo[7], lanes_hi[7], lanes_lo[8], lanes_hi[8], lanes_lo[9], lanes_hi[9], lanes_lo[10], lanes_hi[10],
               lanes_lo[11], lanes_hi[11], lanes_lo[12], lanes_hi[12], lanes_lo[13], lanes_hi[13], lanes_lo[14], lanes_hi[14], lanes_lo[15], lanes_hi[15],
               lanes_lo[16], lanes_hi[16], lanes_lo[17], lanes_hi[17], lanes_lo[18], lanes_hi[18], lanes_lo[19], lanes_hi[19], lanes_lo[20], lanes_hi[20],
               lanes_lo[21], lanes_hi[21], lanes_lo[22], lanes_hi[22], lanes_lo[23], lanes_hi[23], lanes_lo[24], lanes_hi[24], lanes_lo[25], lanes_hi[25]
            for round_idx = 1, 24 do
               local C1_lo = L01_lo ~ L06_lo ~ L11_lo ~ L16_lo ~ L21_lo
               local C1_hi = L01_hi ~ L06_hi ~ L11_hi ~ L16_hi ~ L21_hi
               local C2_lo = L02_lo ~ L07_lo ~ L12_lo ~ L17_lo ~ L22_lo
               local C2_hi = L02_hi ~ L07_hi ~ L12_hi ~ L17_hi ~ L22_hi
               local C3_lo = L03_lo ~ L08_lo ~ L13_lo ~ L18_lo ~ L23_lo
               local C3_hi = L03_hi ~ L08_hi ~ L13_hi ~ L18_hi ~ L23_hi
               local C4_lo = L04_lo ~ L09_lo ~ L14_lo ~ L19_lo ~ L24_lo
               local C4_hi = L04_hi ~ L09_hi ~ L14_hi ~ L19_hi ~ L24_hi
               local C5_lo = L05_lo ~ L10_lo ~ L15_lo ~ L20_lo ~ L25_lo
               local C5_hi = L05_hi ~ L10_hi ~ L15_hi ~ L20_hi ~ L25_hi
               local D_lo = C1_lo ~ C3_lo<<1 ~ C3_hi>>31
               local D_hi = C1_hi ~ C3_hi<<1 ~ C3_lo>>31
               local T0_lo = D_lo ~ L02_lo
               local T0_hi = D_hi ~ L02_hi
               local T1_lo = D_lo ~ L07_lo
               local T1_hi = D_hi ~ L07_hi
               local T2_lo = D_lo ~ L12_lo
               local T2_hi = D_hi ~ L12_hi
               local T3_lo = D_lo ~ L17_lo
               local T3_hi = D_hi ~ L17_hi
               local T4_lo = D_lo ~ L22_lo
               local T4_hi = D_hi ~ L22_hi
               L02_lo = T1_lo>>20 ~ T1_hi<<12
               L02_hi = T1_hi>>20 ~ T1_lo<<12
               L07_lo = T3_lo>>19 ~ T3_hi<<13
               L07_hi = T3_hi>>19 ~ T3_lo<<13
               L12_lo = T0_lo<<1 ~ T0_hi>>31
               L12_hi = T0_hi<<1 ~ T0_lo>>31
               L17_lo = T2_lo<<10 ~ T2_hi>>22
               L17_hi = T2_hi<<10 ~ T2_lo>>22
               L22_lo = T4_lo<<2 ~ T4_hi>>30
               L22_hi = T4_hi<<2 ~ T4_lo>>30
               D_lo = C2_lo ~ C4_lo<<1 ~ C4_hi>>31
               D_hi = C2_hi ~ C4_hi<<1 ~ C4_lo>>31
               T0_lo = D_lo ~ L03_lo
               T0_hi = D_hi ~ L03_hi
               T1_lo = D_lo ~ L08_lo
               T1_hi = D_hi ~ L08_hi
               T2_lo = D_lo ~ L13_lo
               T2_hi = D_hi ~ L13_hi
               T3_lo = D_lo ~ L18_lo
               T3_hi = D_hi ~ L18_hi
               T4_lo = D_lo ~ L23_lo
               T4_hi = D_hi ~ L23_hi
               L03_lo = T2_lo>>21 ~ T2_hi<<11
               L03_hi = T2_hi>>21 ~ T2_lo<<11
               L08_lo = T4_lo>>3 ~ T4_hi<<29
               L08_hi = T4_hi>>3 ~ T4_lo<<29
               L13_lo = T1_lo<<6 ~ T1_hi>>26
               L13_hi = T1_hi<<6 ~ T1_lo>>26
               L18_lo = T3_lo<<15 ~ T3_hi>>17
               L18_hi = T3_hi<<15 ~ T3_lo>>17
               L23_lo = T0_lo>>2 ~ T0_hi<<30
               L23_hi = T0_hi>>2 ~ T0_lo<<30
               D_lo = C3_lo ~ C5_lo<<1 ~ C5_hi>>31
               D_hi = C3_hi ~ C5_hi<<1 ~ C5_lo>>31
               T0_lo = D_lo ~ L04_lo
               T0_hi = D_hi ~ L04_hi
               T1_lo = D_lo ~ L09_lo
               T1_hi = D_hi ~ L09_hi
               T2_lo = D_lo ~ L14_lo
               T2_hi = D_hi ~ L14_hi
               T3_lo = D_lo ~ L19_lo
               T3_hi = D_hi ~ L19_hi
               T4_lo = D_lo ~ L24_lo
               T4_hi = D_hi ~ L24_hi
               L04_lo = T3_lo<<21 ~ T3_hi>>11
               L04_hi = T3_hi<<21 ~ T3_lo>>11
               L09_lo = T0_lo<<28 ~ T0_hi>>4
               L09_hi = T0_hi<<28 ~ T0_lo>>4
               L14_lo = T2_lo<<25 ~ T2_hi>>7
               L14_hi = T2_hi<<25 ~ T2_lo>>7
               L19_lo = T4_lo>>8 ~ T4_hi<<24
               L19_hi = T4_hi>>8 ~ T4_lo<<24
               L24_lo = T1_lo>>9 ~ T1_hi<<23
               L24_hi = T1_hi>>9 ~ T1_lo<<23
               D_lo = C4_lo ~ C1_lo<<1 ~ C1_hi>>31
               D_hi = C4_hi ~ C1_hi<<1 ~ C1_lo>>31
               T0_lo = D_lo ~ L05_lo
               T0_hi = D_hi ~ L05_hi
               T1_lo = D_lo ~ L10_lo
               T1_hi = D_hi ~ L10_hi
               T2_lo = D_lo ~ L15_lo
               T2_hi = D_hi ~ L15_hi
               T3_lo = D_lo ~ L20_lo
               T3_hi = D_hi ~ L20_hi
               T4_lo = D_lo ~ L25_lo
               T4_hi = D_hi ~ L25_hi
               L05_lo = T4_lo<<14 ~ T4_hi>>18
               L05_hi = T4_hi<<14 ~ T4_lo>>18
               L10_lo = T1_lo<<20 ~ T1_hi>>12
               L10_hi = T1_hi<<20 ~ T1_lo>>12
               L15_lo = T3_lo<<8 ~ T3_hi>>24
               L15_hi = T3_hi<<8 ~ T3_lo>>24
               L20_lo = T0_lo<<27 ~ T0_hi>>5
               L20_hi = T0_hi<<27 ~ T0_lo>>5
               L25_lo = T2_lo>>25 ~ T2_hi<<7
               L25_hi = T2_hi>>25 ~ T2_lo<<7
               D_lo = C5_lo ~ C2_lo<<1 ~ C2_hi>>31
               D_hi = C5_hi ~ C2_hi<<1 ~ C2_lo>>31
               T1_lo = D_lo ~ L06_lo
               T1_hi = D_hi ~ L06_hi
               T2_lo = D_lo ~ L11_lo
               T2_hi = D_hi ~ L11_hi
               T3_lo = D_lo ~ L16_lo
               T3_hi = D_hi ~ L16_hi
               T4_lo = D_lo ~ L21_lo
               T4_hi = D_hi ~ L21_hi
               L06_lo = T2_lo<<3 ~ T2_hi>>29
               L06_hi = T2_hi<<3 ~ T2_lo>>29
               L11_lo = T4_lo<<18 ~ T4_hi>>14
               L11_hi = T4_hi<<18 ~ T4_lo>>14
               L16_lo = T1_lo>>28 ~ T1_hi<<4
               L16_hi = T1_hi>>28 ~ T1_lo<<4
               L21_lo = T3_lo>>23 ~ T3_hi<<9
               L21_hi = T3_hi>>23 ~ T3_lo<<9
               L01_lo = D_lo ~ L01_lo
               L01_hi = D_hi ~ L01_hi
               L01_lo, L02_lo, L03_lo, L04_lo, L05_lo = L01_lo ~ ~L02_lo & L03_lo, L02_lo ~ ~L03_lo & L04_lo, L03_lo ~ ~L04_lo & L05_lo, L04_lo ~ ~L05_lo & L01_lo, L05_lo ~ ~L01_lo & L02_lo
               L01_hi, L02_hi, L03_hi, L04_hi, L05_hi = L01_hi ~ ~L02_hi & L03_hi, L02_hi ~ ~L03_hi & L04_hi, L03_hi ~ ~L04_hi & L05_hi, L04_hi ~ ~L05_hi & L01_hi, L05_hi ~ ~L01_hi & L02_hi
               L06_lo, L07_lo, L08_lo, L09_lo, L10_lo = L09_lo ~ ~L10_lo & L06_lo, L10_lo ~ ~L06_lo & L07_lo, L06_lo ~ ~L07_lo & L08_lo, L07_lo ~ ~L08_lo & L09_lo, L08_lo ~ ~L09_lo & L10_lo
               L06_hi, L07_hi, L08_hi, L09_hi, L10_hi = L09_hi ~ ~L10_hi & L06_hi, L10_hi ~ ~L06_hi & L07_hi, L06_hi ~ ~L07_hi & L08_hi, L07_hi ~ ~L08_hi & L09_hi, L08_hi ~ ~L09_hi & L10_hi
               L11_lo, L12_lo, L13_lo, L14_lo, L15_lo = L12_lo ~ ~L13_lo & L14_lo, L13_lo ~ ~L14_lo & L15_lo, L14_lo ~ ~L15_lo & L11_lo, L15_lo ~ ~L11_lo & L12_lo, L11_lo ~ ~L12_lo & L13_lo
               L11_hi, L12_hi, L13_hi, L14_hi, L15_hi = L12_hi ~ ~L13_hi & L14_hi, L13_hi ~ ~L14_hi & L15_hi, L14_hi ~ ~L15_hi & L11_hi, L15_hi ~ ~L11_hi & L12_hi, L11_hi ~ ~L12_hi & L13_hi
               L16_lo, L17_lo, L18_lo, L19_lo, L20_lo = L20_lo ~ ~L16_lo & L17_lo, L16_lo ~ ~L17_lo & L18_lo, L17_lo ~ ~L18_lo & L19_lo, L18_lo ~ ~L19_lo & L20_lo, L19_lo ~ ~L20_lo & L16_lo
               L16_hi, L17_hi, L18_hi, L19_hi, L20_hi = L20_hi ~ ~L16_hi & L17_hi, L16_hi ~ ~L17_hi & L18_hi, L17_hi ~ ~L18_hi & L19_hi, L18_hi ~ ~L19_hi & L20_hi, L19_hi ~ ~L20_hi & L16_hi
               L21_lo, L22_lo, L23_lo, L24_lo, L25_lo = L23_lo ~ ~L24_lo & L25_lo, L24_lo ~ ~L25_lo & L21_lo, L25_lo ~ ~L21_lo & L22_lo, L21_lo ~ ~L22_lo & L23_lo, L22_lo ~ ~L23_lo & L24_lo
               L21_hi, L22_hi, L23_hi, L24_hi, L25_hi = L23_hi ~ ~L24_hi & L25_hi, L24_hi ~ ~L25_hi & L21_hi, L25_hi ~ ~L21_hi & L22_hi, L21_hi ~ ~L22_hi & L23_hi, L22_hi ~ ~L23_hi & L24_hi
               L01_lo = L01_lo ~ RC_lo[round_idx]
               L01_hi = L01_hi ~ RC_hi[round_idx]
            end
            lanes_lo[1]  = L01_lo;  lanes_hi[1]  = L01_hi
            lanes_lo[2]  = L02_lo;  lanes_hi[2]  = L02_hi
            lanes_lo[3]  = L03_lo;  lanes_hi[3]  = L03_hi
            lanes_lo[4]  = L04_lo;  lanes_hi[4]  = L04_hi
            lanes_lo[5]  = L05_lo;  lanes_hi[5]  = L05_hi
            lanes_lo[6]  = L06_lo;  lanes_hi[6]  = L06_hi
            lanes_lo[7]  = L07_lo;  lanes_hi[7]  = L07_hi
            lanes_lo[8]  = L08_lo;  lanes_hi[8]  = L08_hi
            lanes_lo[9]  = L09_lo;  lanes_hi[9]  = L09_hi
            lanes_lo[10] = L10_lo;  lanes_hi[10] = L10_hi
            lanes_lo[11] = L11_lo;  lanes_hi[11] = L11_hi
            lanes_lo[12] = L12_lo;  lanes_hi[12] = L12_hi
            lanes_lo[13] = L13_lo;  lanes_hi[13] = L13_hi
            lanes_lo[14] = L14_lo;  lanes_hi[14] = L14_hi
            lanes_lo[15] = L15_lo;  lanes_hi[15] = L15_hi
            lanes_lo[16] = L16_lo;  lanes_hi[16] = L16_hi
            lanes_lo[17] = L17_lo;  lanes_hi[17] = L17_hi
            lanes_lo[18] = L18_lo;  lanes_hi[18] = L18_hi
            lanes_lo[19] = L19_lo;  lanes_hi[19] = L19_hi
            lanes_lo[20] = L20_lo;  lanes_hi[20] = L20_hi
            lanes_lo[21] = L21_lo;  lanes_hi[21] = L21_hi
            lanes_lo[22] = L22_lo;  lanes_hi[22] = L22_hi
            lanes_lo[23] = L23_lo;  lanes_hi[23] = L23_hi
            lanes_lo[24] = L24_lo;  lanes_hi[24] = L24_hi
            lanes_lo[25] = L25_lo;  lanes_hi[25] = L25_hi
         end
      end

      local function blake2s_feed_64(H, str, offs, size, bytes_compressed, last_block_size, is_last_node)
         -- offs >= 0, size >= 0, size is multiple of 64
         local W = common_W
         local h1, h2, h3, h4, h5, h6, h7, h8 = H[1], H[2], H[3], H[4], H[5], H[6], H[7], H[8]
         for pos = offs + 1, offs + size, 64 do
            if str then
               W[1], W[2], W[3], W[4], W[5], W[6], W[7], W[8], W[9], W[10], W[11], W[12], W[13], W[14], W[15], W[16] =
                  string_unpack("<i4i4i4i4i4i4i4i4i4i4i4i4i4i4i4i4", str, pos)
            end
            local v0, v1, v2, v3, v4, v5, v6, v7 = h1, h2, h3, h4, h5, h6, h7, h8
            local v8, v9, vA, vB, vC, vD, vE, vF = sha2_H_hi[1], sha2_H_hi[2], sha2_H_hi[3], sha2_H_hi[4], sha2_H_hi[5], sha2_H_hi[6], sha2_H_hi[7], sha2_H_hi[8]
            bytes_compressed = bytes_compressed + (last_block_size or 64)
            local t0 = bytes_compressed % 2^32
            local t1 = (bytes_compressed - t0) / 2^32
            t0 = (t0 + 2^31) % 2^32 - 2^31  -- convert to int32 range (-2^31)..(2^31-1) to avoid "number has no integer representation" error while XORing
            vC = vC ~ t0  -- t0 = low_4_bytes(bytes_compressed)
            vD = vD ~ t1  -- t1 = high_4_bytes(bytes_compressed)
            if last_block_size then  -- flag f0
               vE = ~vE
            end
            if is_last_node then  -- flag f1
               vF = ~vF
            end
            for j = 1, 10 do
               local row = sigma[j]
               v0 = v0 + v4 + W[row[1]]
               vC = vC ~ v0
               vC = vC >> 16 | vC << 16
               v8 = v8 + vC
               v4 = v4 ~ v8
               v4 = v4 >> 12 | v4 << 20
               v0 = v0 + v4 + W[row[2]]
               vC = vC ~ v0
               vC = vC >> 8 | vC << 24
               v8 = v8 + vC
               v4 = v4 ~ v8
               v4 = v4 >> 7 | v4 << 25
               v1 = v1 + v5 + W[row[3]]
               vD = vD ~ v1
               vD = vD >> 16 | vD << 16
               v9 = v9 + vD
               v5 = v5 ~ v9
               v5 = v5 >> 12 | v5 << 20
               v1 = v1 + v5 + W[row[4]]
               vD = vD ~ v1
               vD = vD >> 8 | vD << 24
               v9 = v9 + vD
               v5 = v5 ~ v9
               v5 = v5 >> 7 | v5 << 25
               v2 = v2 + v6 + W[row[5]]
               vE = vE ~ v2
               vE = vE >> 16 | vE << 16
               vA = vA + vE
               v6 = v6 ~ vA
               v6 = v6 >> 12 | v6 << 20
               v2 = v2 + v6 + W[row[6]]
               vE = vE ~ v2
               vE = vE >> 8 | vE << 24
               vA = vA + vE
               v6 = v6 ~ vA
               v6 = v6 >> 7 | v6 << 25
               v3 = v3 + v7 + W[row[7]]
               vF = vF ~ v3
               vF = vF >> 16 | vF << 16
               vB = vB + vF
               v7 = v7 ~ vB
               v7 = v7 >> 12 | v7 << 20
               v3 = v3 + v7 + W[row[8]]
               vF = vF ~ v3
               vF = vF >> 8 | vF << 24
               vB = vB + vF
               v7 = v7 ~ vB
               v7 = v7 >> 7 | v7 << 25
               v0 = v0 + v5 + W[row[9]]
               vF = vF ~ v0
               vF = vF >> 16 | vF << 16
               vA = vA + vF
               v5 = v5 ~ vA
               v5 = v5 >> 12 | v5 << 20
               v0 = v0 + v5 + W[row[10]]
               vF = vF ~ v0
               vF = vF >> 8 | vF << 24
               vA = vA + vF
               v5 = v5 ~ vA
               v5 = v5 >> 7 | v5 << 25
               v1 = v1 + v6 + W[row[11]]
               vC = vC ~ v1
               vC = vC >> 16 | vC << 16
               vB = vB + vC
               v6 = v6 ~ vB
               v6 = v6 >> 12 | v6 << 20
               v1 = v1 + v6 + W[row[12]]
               vC = vC ~ v1
               vC = vC >> 8 | vC << 24
               vB = vB + vC
               v6 = v6 ~ vB
               v6 = v6 >> 7 | v6 << 25
               v2 = v2 + v7 + W[row[13]]
               vD = vD ~ v2
               vD = vD >> 16 | vD << 16
               v8 = v8 + vD
               v7 = v7 ~ v8
               v7 = v7 >> 12 | v7 << 20
               v2 = v2 + v7 + W[row[14]]
               vD = vD ~ v2
               vD = vD >> 8 | vD << 24
               v8 = v8 + vD
               v7 = v7 ~ v8
               v7 = v7 >> 7 | v7 << 25
               v3 = v3 + v4 + W[row[15]]
               vE = vE ~ v3
               vE = vE >> 16 | vE << 16
               v9 = v9 + vE
               v4 = v4 ~ v9
               v4 = v4 >> 12 | v4 << 20
               v3 = v3 + v4 + W[row[16]]
               vE = vE ~ v3
               vE = vE >> 8 | vE << 24
               v9 = v9 + vE
               v4 = v4 ~ v9
               v4 = v4 >> 7 | v4 << 25
            end
            h1 = h1 ~ v0 ~ v8
            h2 = h2 ~ v1 ~ v9
            h3 = h3 ~ v2 ~ vA
            h4 = h4 ~ v3 ~ vB
            h5 = h5 ~ v4 ~ vC
            h6 = h6 ~ v5 ~ vD
            h7 = h7 ~ v6 ~ vE
            h8 = h8 ~ v7 ~ vF
         end
         H[1], H[2], H[3], H[4], H[5], H[6], H[7], H[8] = h1, h2, h3, h4, h5, h6, h7, h8
         return bytes_compressed
      end

      local function blake2b_feed_128(H_lo, H_hi, str, offs, size, bytes_compressed, last_block_size, is_last_node)
         -- offs >= 0, size >= 0, size is multiple of 128
         local W = common_W
         local h1_lo, h2_lo, h3_lo, h4_lo, h5_lo, h6_lo, h7_lo, h8_lo = H_lo[1], H_lo[2], H_lo[3], H_lo[4], H_lo[5], H_lo[6], H_lo[7], H_lo[8]
         local h1_hi, h2_hi, h3_hi, h4_hi, h5_hi, h6_hi, h7_hi, h8_hi = H_hi[1], H_hi[2], H_hi[3], H_hi[4], H_hi[5], H_hi[6], H_hi[7], H_hi[8]
         for pos = offs + 1, offs + size, 128 do
            if str then
               W[1], W[2], W[3], W[4], W[5], W[6], W[7], W[8], W[9], W[10], W[11], W[12], W[13], W[14], W[15], W[16],
               W[17], W[18], W[19], W[20], W[21], W[22], W[23], W[24], W[25], W[26], W[27], W[28], W[29], W[30], W[31], W[32] =
                  string_unpack("<i4i4i4i4i4i4i4i4i4i4i4i4i4i4i4i4i4i4i4i4i4i4i4i4i4i4i4i4i4i4i4i4", str, pos)
            end
            local v0_lo, v1_lo, v2_lo, v3_lo, v4_lo, v5_lo, v6_lo, v7_lo = h1_lo, h2_lo, h3_lo, h4_lo, h5_lo, h6_lo, h7_lo, h8_lo
            local v0_hi, v1_hi, v2_hi, v3_hi, v4_hi, v5_hi, v6_hi, v7_hi = h1_hi, h2_hi, h3_hi, h4_hi, h5_hi, h6_hi, h7_hi, h8_hi
            local v8_lo, v9_lo, vA_lo, vB_lo, vC_lo, vD_lo, vE_lo, vF_lo = sha2_H_lo[1], sha2_H_lo[2], sha2_H_lo[3], sha2_H_lo[4], sha2_H_lo[5], sha2_H_lo[6], sha2_H_lo[7], sha2_H_lo[8]
            local v8_hi, v9_hi, vA_hi, vB_hi, vC_hi, vD_hi, vE_hi, vF_hi = sha2_H_hi[1], sha2_H_hi[2], sha2_H_hi[3], sha2_H_hi[4], sha2_H_hi[5], sha2_H_hi[6], sha2_H_hi[7], sha2_H_hi[8]
            bytes_compressed = bytes_compressed + (last_block_size or 128)
            local t0_lo = bytes_compressed % 2^32
            local t0_hi = (bytes_compressed - t0_lo) / 2^32
            t0_lo = (t0_lo + 2^31) % 2^32 - 2^31  -- convert to int32 range (-2^31)..(2^31-1) to avoid "number has no integer representation" error while XORing
            vC_lo = vC_lo ~ t0_lo  -- t0 = low_8_bytes(bytes_compressed)
            vC_hi = vC_hi ~ t0_hi
            -- t1 = high_8_bytes(bytes_compressed) = 0,  message length is always below 2^53 bytes
            if last_block_size then  -- flag f0
               vE_lo = ~vE_lo
               vE_hi = ~vE_hi
            end
            if is_last_node then  -- flag f1
               vF_lo = ~vF_lo
               vF_hi = ~vF_hi
            end
            for j = 1, 12 do
               local row = sigma[j]
               local k = row[1] * 2
               v0_lo = v0_lo % 2^32 + v4_lo % 2^32 + W[k-1] % 2^32
               v0_hi = v0_hi + v4_hi + floor(v0_lo / 2^32) + W[k]
               v0_lo = 0|((v0_lo + 2^31) % 2^32 - 2^31)
               vC_lo, vC_hi = vC_hi ~ v0_hi, vC_lo ~ v0_lo
               v8_lo = v8_lo % 2^32 + vC_lo % 2^32
               v8_hi = v8_hi + vC_hi + floor(v8_lo / 2^32)
               v8_lo = 0|((v8_lo + 2^31) % 2^32 - 2^31)
               v4_lo, v4_hi = v4_lo ~ v8_lo, v4_hi ~ v8_hi
               v4_lo, v4_hi = v4_lo >> 24 | v4_hi << 8, v4_hi >> 24 | v4_lo << 8
               k = row[2] * 2
               v0_lo = v0_lo % 2^32 + v4_lo % 2^32 + W[k-1] % 2^32
               v0_hi = v0_hi + v4_hi + floor(v0_lo / 2^32) + W[k]
               v0_lo = 0|((v0_lo + 2^31) % 2^32 - 2^31)
               vC_lo, vC_hi = vC_lo ~ v0_lo, vC_hi ~ v0_hi
               vC_lo, vC_hi = vC_lo >> 16 | vC_hi << 16, vC_hi >> 16 | vC_lo << 16
               v8_lo = v8_lo % 2^32 + vC_lo % 2^32
               v8_hi = v8_hi + vC_hi + floor(v8_lo / 2^32)
               v8_lo = 0|((v8_lo + 2^31) % 2^32 - 2^31)
               v4_lo, v4_hi = v4_lo ~ v8_lo, v4_hi ~ v8_hi
               v4_lo, v4_hi = v4_lo << 1 | v4_hi >> 31, v4_hi << 1 | v4_lo >> 31
               k = row[3] * 2
               v1_lo = v1_lo % 2^32 + v5_lo % 2^32 + W[k-1] % 2^32
               v1_hi = v1_hi + v5_hi + floor(v1_lo / 2^32) + W[k]
               v1_lo = 0|((v1_lo + 2^31) % 2^32 - 2^31)
               vD_lo, vD_hi = vD_hi ~ v1_hi, vD_lo ~ v1_lo
               v9_lo = v9_lo % 2^32 + vD_lo % 2^32
               v9_hi = v9_hi + vD_hi + floor(v9_lo / 2^32)
               v9_lo = 0|((v9_lo + 2^31) % 2^32 - 2^31)
               v5_lo, v5_hi = v5_lo ~ v9_lo, v5_hi ~ v9_hi
               v5_lo, v5_hi = v5_lo >> 24 | v5_hi << 8, v5_hi >> 24 | v5_lo << 8
               k = row[4] * 2
               v1_lo = v1_lo % 2^32 + v5_lo % 2^32 + W[k-1] % 2^32
               v1_hi = v1_hi + v5_hi + floor(v1_lo / 2^32) + W[k]
               v1_lo = 0|((v1_lo + 2^31) % 2^32 - 2^31)
               vD_lo, vD_hi = vD_lo ~ v1_lo, vD_hi ~ v1_hi
               vD_lo, vD_hi = vD_lo >> 16 | vD_hi << 16, vD_hi >> 16 | vD_lo << 16
               v9_lo = v9_lo % 2^32 + vD_lo % 2^32
               v9_hi = v9_hi + vD_hi + floor(v9_lo / 2^32)
               v9_lo = 0|((v9_lo + 2^31) % 2^32 - 2^31)
               v5_lo, v5_hi = v5_lo ~ v9_lo, v5_hi ~ v9_hi
               v5_lo, v5_hi = v5_lo << 1 | v5_hi >> 31, v5_hi << 1 | v5_lo >> 31
               k = row[5] * 2
               v2_lo = v2_lo % 2^32 + v6_lo % 2^32 + W[k-1] % 2^32
               v2_hi = v2_hi + v6_hi + floor(v2_lo / 2^32) + W[k]
               v2_lo = 0|((v2_lo + 2^31) % 2^32 - 2^31)
               vE_lo, vE_hi = vE_hi ~ v2_hi, vE_lo ~ v2_lo
               vA_lo = vA_lo % 2^32 + vE_lo % 2^32
               vA_hi = vA_hi + vE_hi + floor(vA_lo / 2^32)
               vA_lo = 0|((vA_lo + 2^31) % 2^32 - 2^31)
               v6_lo, v6_hi = v6_lo ~ vA_lo, v6_hi ~ vA_hi
               v6_lo, v6_hi = v6_lo >> 24 | v6_hi << 8, v6_hi >> 24 | v6_lo << 8
               k = row[6] * 2
               v2_lo = v2_lo % 2^32 + v6_lo % 2^32 + W[k-1] % 2^32
               v2_hi = v2_hi + v6_hi + floor(v2_lo / 2^32) + W[k]
               v2_lo = 0|((v2_lo + 2^31) % 2^32 - 2^31)
               vE_lo, vE_hi = vE_lo ~ v2_lo, vE_hi ~ v2_hi
               vE_lo, vE_hi = vE_lo >> 16 | vE_hi << 16, vE_hi >> 16 | vE_lo << 16
               vA_lo = vA_lo % 2^32 + vE_lo % 2^32
               vA_hi = vA_hi + vE_hi + floor(vA_lo / 2^32)
               vA_lo = 0|((vA_lo + 2^31) % 2^32 - 2^31)
               v6_lo, v6_hi = v6_lo ~ vA_lo, v6_hi ~ vA_hi
               v6_lo, v6_hi = v6_lo << 1 | v6_hi >> 31, v6_hi << 1 | v6_lo >> 31
               k = row[7] * 2
               v3_lo = v3_lo % 2^32 + v7_lo % 2^32 + W[k-1] % 2^32
               v3_hi = v3_hi + v7_hi + floor(v3_lo / 2^32) + W[k]
               v3_lo = 0|((v3_lo + 2^31) % 2^32 - 2^31)
               vF_lo, vF_hi = vF_hi ~ v3_hi, vF_lo ~ v3_lo
               vB_lo = vB_lo % 2^32 + vF_lo % 2^32
               vB_hi = vB_hi + vF_hi + floor(vB_lo / 2^32)
               vB_lo = 0|((vB_lo + 2^31) % 2^32 - 2^31)
               v7_lo, v7_hi = v7_lo ~ vB_lo, v7_hi ~ vB_hi
               v7_lo, v7_hi = v7_lo >> 24 | v7_hi << 8, v7_hi >> 24 | v7_lo << 8
               k = row[8] * 2
               v3_lo = v3_lo % 2^32 + v7_lo % 2^32 + W[k-1] % 2^32
               v3_hi = v3_hi + v7_hi + floor(v3_lo / 2^32) + W[k]
               v3_lo = 0|((v3_lo + 2^31) % 2^32 - 2^31)
               vF_lo, vF_hi = vF_lo ~ v3_lo, vF_hi ~ v3_hi
               vF_lo, vF_hi = vF_lo >> 16 | vF_hi << 16, vF_hi >> 16 | vF_lo << 16
               vB_lo = vB_lo % 2^32 + vF_lo % 2^32
               vB_hi = vB_hi + vF_hi + floor(vB_lo / 2^32)
               vB_lo = 0|((vB_lo + 2^31) % 2^32 - 2^31)
               v7_lo, v7_hi = v7_lo ~ vB_lo, v7_hi ~ vB_hi
               v7_lo, v7_hi = v7_lo << 1 | v7_hi >> 31, v7_hi << 1 | v7_lo >> 31
               k = row[9] * 2
               v0_lo = v0_lo % 2^32 + v5_lo % 2^32 + W[k-1] % 2^32
               v0_hi = v0_hi + v5_hi + floor(v0_lo / 2^32) + W[k]
               v0_lo = 0|((v0_lo + 2^31) % 2^32 - 2^31)
               vF_lo, vF_hi = vF_hi ~ v0_hi, vF_lo ~ v0_lo
               vA_lo = vA_lo % 2^32 + vF_lo % 2^32
               vA_hi = vA_hi + vF_hi + floor(vA_lo / 2^32)
               vA_lo = 0|((vA_lo + 2^31) % 2^32 - 2^31)
               v5_lo, v5_hi = v5_lo ~ vA_lo, v5_hi ~ vA_hi
               v5_lo, v5_hi = v5_lo >> 24 | v5_hi << 8, v5_hi >> 24 | v5_lo << 8
               k = row[10] * 2
               v0_lo = v0_lo % 2^32 + v5_lo % 2^32 + W[k-1] % 2^32
               v0_hi = v0_hi + v5_hi + floor(v0_lo / 2^32) + W[k]
               v0_lo = 0|((v0_lo + 2^31) % 2^32 - 2^31)
               vF_lo, vF_hi = vF_lo ~ v0_lo, vF_hi ~ v0_hi
               vF_lo, vF_hi = vF_lo >> 16 | vF_hi << 16, vF_hi >> 16 | vF_lo << 16
               vA_lo = vA_lo % 2^32 + vF_lo % 2^32
               vA_hi = vA_hi + vF_hi + floor(vA_lo / 2^32)
               vA_lo = 0|((vA_lo + 2^31) % 2^32 - 2^31)
               v5_lo, v5_hi = v5_lo ~ vA_lo, v5_hi ~ vA_hi
               v5_lo, v5_hi = v5_lo << 1 | v5_hi >> 31, v5_hi << 1 | v5_lo >> 31
               k = row[11] * 2
               v1_lo = v1_lo % 2^32 + v6_lo % 2^32 + W[k-1] % 2^32
               v1_hi = v1_hi + v6_hi + floor(v1_lo / 2^32) + W[k]
               v1_lo = 0|((v1_lo + 2^31) % 2^32 - 2^31)
               vC_lo, vC_hi = vC_hi ~ v1_hi, vC_lo ~ v1_lo
               vB_lo = vB_lo % 2^32 + vC_lo % 2^32
               vB_hi = vB_hi + vC_hi + floor(vB_lo / 2^32)
               vB_lo = 0|((vB_lo + 2^31) % 2^32 - 2^31)
               v6_lo, v6_hi = v6_lo ~ vB_lo, v6_hi ~ vB_hi
               v6_lo, v6_hi = v6_lo >> 24 | v6_hi << 8, v6_hi >> 24 | v6_lo << 8
               k = row[12] * 2
               v1_lo = v1_lo % 2^32 + v6_lo % 2^32 + W[k-1] % 2^32
               v1_hi = v1_hi + v6_hi + floor(v1_lo / 2^32) + W[k]
               v1_lo = 0|((v1_lo + 2^31) % 2^32 - 2^31)
               vC_lo, vC_hi = vC_lo ~ v1_lo, vC_hi ~ v1_hi
               vC_lo, vC_hi = vC_lo >> 16 | vC_hi << 16, vC_hi >> 16 | vC_lo << 16
               vB_lo = vB_lo % 2^32 + vC_lo % 2^32
               vB_hi = vB_hi + vC_hi + floor(vB_lo / 2^32)
               vB_lo = 0|((vB_lo + 2^31) % 2^32 - 2^31)
               v6_lo, v6_hi = v6_lo ~ vB_lo, v6_hi ~ vB_hi
               v6_lo, v6_hi = v6_lo << 1 | v6_hi >> 31, v6_hi << 1 | v6_lo >> 31
               k = row[13] * 2
               v2_lo = v2_lo % 2^32 + v7_lo % 2^32 + W[k-1] % 2^32
               v2_hi = v2_hi + v7_hi + floor(v2_lo / 2^32) + W[k]
               v2_lo = 0|((v2_lo + 2^31) % 2^32 - 2^31)
               vD_lo, vD_hi = vD_hi ~ v2_hi, vD_lo ~ v2_lo
               v8_lo = v8_lo % 2^32 + vD_lo % 2^32
               v8_hi = v8_hi + vD_hi + floor(v8_lo / 2^32)
               v8_lo = 0|((v8_lo + 2^31) % 2^32 - 2^31)
               v7_lo, v7_hi = v7_lo ~ v8_lo, v7_hi ~ v8_hi
               v7_lo, v7_hi = v7_lo >> 24 | v7_hi << 8, v7_hi >> 24 | v7_lo << 8
               k = row[14] * 2
               v2_lo = v2_lo % 2^32 + v7_lo % 2^32 + W[k-1] % 2^32
               v2_hi = v2_hi + v7_hi + floor(v2_lo / 2^32) + W[k]
               v2_lo = 0|((v2_lo + 2^31) % 2^32 - 2^31)
               vD_lo, vD_hi = vD_lo ~ v2_lo, vD_hi ~ v2_hi
               vD_lo, vD_hi = vD_lo >> 16 | vD_hi << 16, vD_hi >> 16 | vD_lo << 16
               v8_lo = v8_lo % 2^32 + vD_lo % 2^32
               v8_hi = v8_hi + vD_hi + floor(v8_lo / 2^32)
               v8_lo = 0|((v8_lo + 2^31) % 2^32 - 2^31)
               v7_lo, v7_hi = v7_lo ~ v8_lo, v7_hi ~ v8_hi
               v7_lo, v7_hi = v7_lo << 1 | v7_hi >> 31, v7_hi << 1 | v7_lo >> 31
               k = row[15] * 2
               v3_lo = v3_lo % 2^32 + v4_lo % 2^32 + W[k-1] % 2^32
               v3_hi = v3_hi + v4_hi + floor(v3_lo / 2^32) + W[k]
               v3_lo = 0|((v3_lo + 2^31) % 2^32 - 2^31)
               vE_lo, vE_hi = vE_hi ~ v3_hi, vE_lo ~ v3_lo
               v9_lo = v9_lo % 2^32 + vE_lo % 2^32
               v9_hi = v9_hi + vE_hi + floor(v9_lo / 2^32)
               v9_lo = 0|((v9_lo + 2^31) % 2^32 - 2^31)
               v4_lo, v4_hi = v4_lo ~ v9_lo, v4_hi ~ v9_hi
               v4_lo, v4_hi = v4_lo >> 24 | v4_hi << 8, v4_hi >> 24 | v4_lo << 8
               k = row[16] * 2
               v3_lo = v3_lo % 2^32 + v4_lo % 2^32 + W[k-1] % 2^32
               v3_hi = v3_hi + v4_hi + floor(v3_lo / 2^32) + W[k]
               v3_lo = 0|((v3_lo + 2^31) % 2^32 - 2^31)
               vE_lo, vE_hi = vE_lo ~ v3_lo, vE_hi ~ v3_hi
               vE_lo, vE_hi = vE_lo >> 16 | vE_hi << 16, vE_hi >> 16 | vE_lo << 16
               v9_lo = v9_lo % 2^32 + vE_lo % 2^32
               v9_hi = v9_hi + vE_hi + floor(v9_lo / 2^32)
               v9_lo = 0|((v9_lo + 2^31) % 2^32 - 2^31)
               v4_lo, v4_hi = v4_lo ~ v9_lo, v4_hi ~ v9_hi
               v4_lo, v4_hi = v4_lo << 1 | v4_hi >> 31, v4_hi << 1 | v4_lo >> 31
            end
            h1_lo = h1_lo ~ v0_lo ~ v8_lo
            h2_lo = h2_lo ~ v1_lo ~ v9_lo
            h3_lo = h3_lo ~ v2_lo ~ vA_lo
            h4_lo = h4_lo ~ v3_lo ~ vB_lo
            h5_lo = h5_lo ~ v4_lo ~ vC_lo
            h6_lo = h6_lo ~ v5_lo ~ vD_lo
            h7_lo = h7_lo ~ v6_lo ~ vE_lo
            h8_lo = h8_lo ~ v7_lo ~ vF_lo
            h1_hi = h1_hi ~ v0_hi ~ v8_hi
            h2_hi = h2_hi ~ v1_hi ~ v9_hi
            h3_hi = h3_hi ~ v2_hi ~ vA_hi
            h4_hi = h4_hi ~ v3_hi ~ vB_hi
            h5_hi = h5_hi ~ v4_hi ~ vC_hi
            h6_hi = h6_hi ~ v5_hi ~ vD_hi
            h7_hi = h7_hi ~ v6_hi ~ vE_hi
            h8_hi = h8_hi ~ v7_hi ~ vF_hi
         end
         H_lo[1], H_lo[2], H_lo[3], H_lo[4], H_lo[5], H_lo[6], H_lo[7], H_lo[8] = h1_lo, h2_lo, h3_lo, h4_lo, h5_lo, h6_lo, h7_lo, h8_lo
         H_hi[1], H_hi[2], H_hi[3], H_hi[4], H_hi[5], H_hi[6], H_hi[7], H_hi[8] = h1_hi, h2_hi, h3_hi, h4_hi, h5_hi, h6_hi, h7_hi, h8_hi
         return bytes_compressed
      end

      local function blake3_feed_64(str, offs, size, flags, chunk_index, H_in, H_out, wide_output, block_length)
         -- offs >= 0, size >= 0, size is multiple of 64
         block_length = block_length or 64
         local W = common_W
         local h1, h2, h3, h4, h5, h6, h7, h8 = H_in[1], H_in[2], H_in[3], H_in[4], H_in[5], H_in[6], H_in[7], H_in[8]
         H_out = H_out or H_in
         for pos = offs + 1, offs + size, 64 do
            if str then
               W[1], W[2], W[3], W[4], W[5], W[6], W[7], W[8], W[9], W[10], W[11], W[12], W[13], W[14], W[15], W[16] =
                  string_unpack("<i4i4i4i4i4i4i4i4i4i4i4i4i4i4i4i4", str, pos)
            end
            local v0, v1, v2, v3, v4, v5, v6, v7 = h1, h2, h3, h4, h5, h6, h7, h8
            local v8, v9, vA, vB = sha2_H_hi[1], sha2_H_hi[2], sha2_H_hi[3], sha2_H_hi[4]
            local t0 = chunk_index % 2^32         -- t0 = low_4_bytes(chunk_index)
            local t1 = (chunk_index - t0) / 2^32  -- t1 = high_4_bytes(chunk_index)
            t0 = (t0 + 2^31) % 2^32 - 2^31  -- convert to int32 range (-2^31)..(2^31-1) to avoid "number has no integer representation" error while ORing
            local vC, vD, vE, vF = 0|t0, 0|t1, block_length, flags
            for j = 1, 7 do
               v0 = v0 + v4 + W[perm_blake3[j]]
               vC = vC ~ v0
               vC = vC >> 16 | vC << 16
               v8 = v8 + vC
               v4 = v4 ~ v8
               v4 = v4 >> 12 | v4 << 20
               v0 = v0 + v4 + W[perm_blake3[j + 14]]
               vC = vC ~ v0
               vC = vC >> 8 | vC << 24
               v8 = v8 + vC
               v4 = v4 ~ v8
               v4 = v4 >> 7 | v4 << 25
               v1 = v1 + v5 + W[perm_blake3[j + 1]]
               vD = vD ~ v1
               vD = vD >> 16 | vD << 16
               v9 = v9 + vD
               v5 = v5 ~ v9
               v5 = v5 >> 12 | v5 << 20
               v1 = v1 + v5 + W[perm_blake3[j + 2]]
               vD = vD ~ v1
               vD = vD >> 8 | vD << 24
               v9 = v9 + vD
               v5 = v5 ~ v9
               v5 = v5 >> 7 | v5 << 25
               v2 = v2 + v6 + W[perm_blake3[j + 16]]
               vE = vE ~ v2
               vE = vE >> 16 | vE << 16
               vA = vA + vE
               v6 = v6 ~ vA
               v6 = v6 >> 12 | v6 << 20
               v2 = v2 + v6 + W[perm_blake3[j + 7]]
               vE = vE ~ v2
               vE = vE >> 8 | vE << 24
               vA = vA + vE
               v6 = v6 ~ vA
               v6 = v6 >> 7 | v6 << 25
               v3 = v3 + v7 + W[perm_blake3[j + 15]]
               vF = vF ~ v3
               vF = vF >> 16 | vF << 16
               vB = vB + vF
               v7 = v7 ~ vB
               v7 = v7 >> 12 | v7 << 20
               v3 = v3 + v7 + W[perm_blake3[j + 17]]
               vF = vF ~ v3
               vF = vF >> 8 | vF << 24
               vB = vB + vF
               v7 = v7 ~ vB
               v7 = v7 >> 7 | v7 << 25
               v0 = v0 + v5 + W[perm_blake3[j + 21]]
               vF = vF ~ v0
               vF = vF >> 16 | vF << 16
               vA = vA + vF
               v5 = v5 ~ vA
               v5 = v5 >> 12 | v5 << 20
               v0 = v0 + v5 + W[perm_blake3[j + 5]]
               vF = vF ~ v0
               vF = vF >> 8 | vF << 24
               vA = vA + vF
               v5 = v5 ~ vA
               v5 = v5 >> 7 | v5 << 25
               v1 = v1 + v6 + W[perm_blake3[j + 3]]
               vC = vC ~ v1
               vC = vC >> 16 | vC << 16
               vB = vB + vC
               v6 = v6 ~ vB
               v6 = v6 >> 12 | v6 << 20
               v1 = v1 + v6 + W[perm_blake3[j + 6]]
               vC = vC ~ v1
               vC = vC >> 8 | vC << 24
               vB = vB + vC
               v6 = v6 ~ vB
               v6 = v6 >> 7 | v6 << 25
               v2 = v2 + v7 + W[perm_blake3[j + 4]]
               vD = vD ~ v2
               vD = vD >> 16 | vD << 16
               v8 = v8 + vD
               v7 = v7 ~ v8
               v7 = v7 >> 12 | v7 << 20
               v2 = v2 + v7 + W[perm_blake3[j + 18]]
               vD = vD ~ v2
               vD = vD >> 8 | vD << 24
               v8 = v8 + vD
               v7 = v7 ~ v8
               v7 = v7 >> 7 | v7 << 25
               v3 = v3 + v4 + W[perm_blake3[j + 19]]
               vE = vE ~ v3
               vE = vE >> 16 | vE << 16
               v9 = v9 + vE
               v4 = v4 ~ v9
               v4 = v4 >> 12 | v4 << 20
               v3 = v3 + v4 + W[perm_blake3[j + 20]]
               vE = vE ~ v3
               vE = vE >> 8 | vE << 24
               v9 = v9 + vE
               v4 = v4 ~ v9
               v4 = v4 >> 7 | v4 << 25
            end
            if wide_output then
               H_out[ 9] = h1 ~ v8
               H_out[10] = h2 ~ v9
               H_out[11] = h3 ~ vA
               H_out[12] = h4 ~ vB
               H_out[13] = h5 ~ vC
               H_out[14] = h6 ~ vD
               H_out[15] = h7 ~ vE
               H_out[16] = h8 ~ vF
            end
            h1 = v0 ~ v8
            h2 = v1 ~ v9
            h3 = v2 ~ vA
            h4 = v3 ~ vB
            h5 = v4 ~ vC
            h6 = v5 ~ vD
            h7 = v6 ~ vE
            h8 = v7 ~ vF
         end
         H_out[1], H_out[2], H_out[3], H_out[4], H_out[5], H_out[6], H_out[7], H_out[8] = h1, h2, h3, h4, h5, h6, h7, h8
      end

      return XORA5, XOR_BYTE, sha256_feed_64, sha512_feed_128, md5_feed_64, sha1_feed_64, keccak_feed, blake2s_feed_64, blake2b_feed_128, blake3_feed_64
   ]=](md5_next_shift, md5_K, sha2_K_lo, sha2_K_hi, build_keccak_format, sha3_RC_lo, sha3_RC_hi, sigma, common_W, sha2_H_lo, sha2_H_hi, perm_blake3)

end

XOR = XOR or XORA5

if branch == "LIB32" or branch == "EMUL" then


   -- implementation for Lua 5.1/5.2 (with or without bitwise library available)

   function sha256_feed_64(H, str, offs, size)
      -- offs >= 0, size >= 0, size is multiple of 64
      local W, K = common_W, sha2_K_hi
      local h1, h2, h3, h4, h5, h6, h7, h8 = H[1], H[2], H[3], H[4], H[5], H[6], H[7], H[8]
      for pos = offs, offs + size - 1, 64 do
         for j = 1, 16 do
            pos = pos + 4
            local a, b, c, d = byte(str, pos - 3, pos)
            W[j] = ((a * 256 + b) * 256 + c) * 256 + d
         end
         for j = 17, 64 do
            local a, b = W[j-15], W[j-2]
            local a7, a18, b17, b19 = a / 2^7, a / 2^18, b / 2^17, b / 2^19
            W[j] = (XOR(a7 % 1 * (2^32 - 1) + a7, a18 % 1 * (2^32 - 1) + a18, (a - a % 2^3) / 2^3) + W[j-16] + W[j-7]
               + XOR(b17 % 1 * (2^32 - 1) + b17, b19 % 1 * (2^32 - 1) + b19, (b - b % 2^10) / 2^10)) % 2^32
         end
         local a, b, c, d, e, f, g, h = h1, h2, h3, h4, h5, h6, h7, h8
         for j = 1, 64 do
            e = e % 2^32
            local e6, e11, e7 = e / 2^6, e / 2^11, e * 2^7
            local e7_lo = e7 % 2^32
            local z = AND(e, f) + AND(-1-e, g) + h + K[j] + W[j]
               + XOR(e6 % 1 * (2^32 - 1) + e6, e11 % 1 * (2^32 - 1) + e11, e7_lo + (e7 - e7_lo) / 2^32)
            h = g
            g = f
            f = e
            e = z + d
            d = c
            c = b
            b = a % 2^32
            local b2, b13, b10 = b / 2^2, b / 2^13, b * 2^10
            local b10_lo = b10 % 2^32
            a = z + AND(d, c) + AND(b, XOR(d, c)) +
               XOR(b2 % 1 * (2^32 - 1) + b2, b13 % 1 * (2^32 - 1) + b13, b10_lo + (b10 - b10_lo) / 2^32)
         end
         h1, h2, h3, h4 = (a + h1) % 2^32, (b + h2) % 2^32, (c + h3) % 2^32, (d + h4) % 2^32
         h5, h6, h7, h8 = (e + h5) % 2^32, (f + h6) % 2^32, (g + h7) % 2^32, (h + h8) % 2^32
      end
      H[1], H[2], H[3], H[4], H[5], H[6], H[7], H[8] = h1, h2, h3, h4, h5, h6, h7, h8
   end


   function sha512_feed_128(H_lo, H_hi, str, offs, size)
      -- offs >= 0, size >= 0, size is multiple of 128
      -- W1_hi, W1_lo, W2_hi, W2_lo, ...   Wk_hi = W[2*k-1], Wk_lo = W[2*k]
      local W, K_lo, K_hi = common_W, sha2_K_lo, sha2_K_hi
      local h1_lo, h2_lo, h3_lo, h4_lo, h5_lo, h6_lo, h7_lo, h8_lo = H_lo[1], H_lo[2], H_lo[3], H_lo[4], H_lo[5], H_lo[6], H_lo[7], H_lo[8]
      local h1_hi, h2_hi, h3_hi, h4_hi, h5_hi, h6_hi, h7_hi, h8_hi = H_hi[1], H_hi[2], H_hi[3], H_hi[4], H_hi[5], H_hi[6], H_hi[7], H_hi[8]
      for pos = offs, offs + size - 1, 128 do
         for j = 1, 16*2 do
            pos = pos + 4
            local a, b, c, d = byte(str, pos - 3, pos)
            W[j] = ((a * 256 + b) * 256 + c) * 256 + d
         end
         for jj = 17*2, 80*2, 2 do
            local a_hi, a_lo, b_hi, b_lo = W[jj-31], W[jj-30], W[jj-5], W[jj-4]
            local b_hi_6, b_hi_19, b_hi_29, b_lo_19, b_lo_29, a_hi_1, a_hi_7, a_hi_8, a_lo_1, a_lo_8 =
               b_hi % 2^6, b_hi % 2^19, b_hi % 2^29, b_lo % 2^19, b_lo % 2^29, a_hi % 2^1, a_hi % 2^7, a_hi % 2^8, a_lo % 2^1, a_lo % 2^8
            local tmp1 = XOR((a_lo - a_lo_1) / 2^1 + a_hi_1 * 2^31, (a_lo - a_lo_8) / 2^8 + a_hi_8 * 2^24, (a_lo - a_lo % 2^7) / 2^7 + a_hi_7 * 2^25) % 2^32
               + XOR((b_lo - b_lo_19) / 2^19 + b_hi_19 * 2^13, b_lo_29 * 2^3 + (b_hi - b_hi_29) / 2^29, (b_lo - b_lo % 2^6) / 2^6 + b_hi_6 * 2^26) % 2^32
               + W[jj-14] + W[jj-32]
            local tmp2 = tmp1 % 2^32
            W[jj-1] = (XOR((a_hi - a_hi_1) / 2^1 + a_lo_1 * 2^31, (a_hi - a_hi_8) / 2^8 + a_lo_8 * 2^24, (a_hi - a_hi_7) / 2^7)
               + XOR((b_hi - b_hi_19) / 2^19 + b_lo_19 * 2^13, b_hi_29 * 2^3 + (b_lo - b_lo_29) / 2^29, (b_hi - b_hi_6) / 2^6)
               + W[jj-15] + W[jj-33] + (tmp1 - tmp2) / 2^32) % 2^32
            W[jj] = tmp2
         end
         local a_lo, b_lo, c_lo, d_lo, e_lo, f_lo, g_lo, h_lo = h1_lo, h2_lo, h3_lo, h4_lo, h5_lo, h6_lo, h7_lo, h8_lo
         local a_hi, b_hi, c_hi, d_hi, e_hi, f_hi, g_hi, h_hi = h1_hi, h2_hi, h3_hi, h4_hi, h5_hi, h6_hi, h7_hi, h8_hi
         for j = 1, 80 do
            local jj = 2*j
            local e_lo_9, e_lo_14, e_lo_18, e_hi_9, e_hi_14, e_hi_18 = e_lo % 2^9, e_lo % 2^14, e_lo % 2^18, e_hi % 2^9, e_hi % 2^14, e_hi % 2^18
            local tmp1 = (AND(e_lo, f_lo) + AND(-1-e_lo, g_lo)) % 2^32 + h_lo + K_lo[j] + W[jj]
               + XOR((e_lo - e_lo_14) / 2^14 + e_hi_14 * 2^18, (e_lo - e_lo_18) / 2^18 + e_hi_18 * 2^14, e_lo_9 * 2^23 + (e_hi - e_hi_9) / 2^9) % 2^32
            local z_lo = tmp1 % 2^32
            local z_hi = AND(e_hi, f_hi) + AND(-1-e_hi, g_hi) + h_hi + K_hi[j] + W[jj-1] + (tmp1 - z_lo) / 2^32
               + XOR((e_hi - e_hi_14) / 2^14 + e_lo_14 * 2^18, (e_hi - e_hi_18) / 2^18 + e_lo_18 * 2^14, e_hi_9 * 2^23 + (e_lo - e_lo_9) / 2^9)
            h_lo = g_lo;  h_hi = g_hi
            g_lo = f_lo;  g_hi = f_hi
            f_lo = e_lo;  f_hi = e_hi
            tmp1 = z_lo + d_lo
            e_lo = tmp1 % 2^32
            e_hi = (z_hi + d_hi + (tmp1 - e_lo) / 2^32) % 2^32
            d_lo = c_lo;  d_hi = c_hi
            c_lo = b_lo;  c_hi = b_hi
            b_lo = a_lo;  b_hi = a_hi
            local b_lo_2, b_lo_7, b_lo_28, b_hi_2, b_hi_7, b_hi_28 = b_lo % 2^2, b_lo % 2^7, b_lo % 2^28, b_hi % 2^2, b_hi % 2^7, b_hi % 2^28
            tmp1 = z_lo + (AND(d_lo, c_lo) + AND(b_lo, XOR(d_lo, c_lo))) % 2^32
               + XOR((b_lo - b_lo_28) / 2^28 + b_hi_28 * 2^4, b_lo_2 * 2^30 + (b_hi - b_hi_2) / 2^2, b_lo_7 * 2^25 + (b_hi - b_hi_7) / 2^7) % 2^32
            a_lo = tmp1 % 2^32
            a_hi = (z_hi + AND(d_hi, c_hi) + AND(b_hi, XOR(d_hi, c_hi)) + (tmp1 - a_lo) / 2^32
               + XOR((b_hi - b_hi_28) / 2^28 + b_lo_28 * 2^4, b_hi_2 * 2^30 + (b_lo - b_lo_2) / 2^2, b_hi_7 * 2^25 + (b_lo - b_lo_7) / 2^7)) % 2^32
         end
         a_lo = h1_lo + a_lo
         h1_lo = a_lo % 2^32
         h1_hi = (h1_hi + a_hi + (a_lo - h1_lo) / 2^32) % 2^32
         a_lo = h2_lo + b_lo
         h2_lo = a_lo % 2^32
         h2_hi = (h2_hi + b_hi + (a_lo - h2_lo) / 2^32) % 2^32
         a_lo = h3_lo + c_lo
         h3_lo = a_lo % 2^32
         h3_hi = (h3_hi + c_hi + (a_lo - h3_lo) / 2^32) % 2^32
         a_lo = h4_lo + d_lo
         h4_lo = a_lo % 2^32
         h4_hi = (h4_hi + d_hi + (a_lo - h4_lo) / 2^32) % 2^32
         a_lo = h5_lo + e_lo
         h5_lo = a_lo % 2^32
         h5_hi = (h5_hi + e_hi + (a_lo - h5_lo) / 2^32) % 2^32
         a_lo = h6_lo + f_lo
         h6_lo = a_lo % 2^32
         h6_hi = (h6_hi + f_hi + (a_lo - h6_lo) / 2^32) % 2^32
         a_lo = h7_lo + g_lo
         h7_lo = a_lo % 2^32
         h7_hi = (h7_hi + g_hi + (a_lo - h7_lo) / 2^32) % 2^32
         a_lo = h8_lo + h_lo
         h8_lo = a_lo % 2^32
         h8_hi = (h8_hi + h_hi + (a_lo - h8_lo) / 2^32) % 2^32
      end
      H_lo[1], H_lo[2], H_lo[3], H_lo[4], H_lo[5], H_lo[6], H_lo[7], H_lo[8] = h1_lo, h2_lo, h3_lo, h4_lo, h5_lo, h6_lo, h7_lo, h8_lo
      H_hi[1], H_hi[2], H_hi[3], H_hi[4], H_hi[5], H_hi[6], H_hi[7], H_hi[8] = h1_hi, h2_hi, h3_hi, h4_hi, h5_hi, h6_hi, h7_hi, h8_hi
   end


   if branch == "LIB32" then

      function md5_feed_64(H, str, offs, size)
         -- offs >= 0, size >= 0, size is multiple of 64
         local W, K, md5_next_shift = common_W, md5_K, md5_next_shift
         local h1, h2, h3, h4 = H[1], H[2], H[3], H[4]
         for pos = offs, offs + size - 1, 64 do
            for j = 1, 16 do
               pos = pos + 4
               local a, b, c, d = byte(str, pos - 3, pos)
               W[j] = ((d * 256 + c) * 256 + b) * 256 + a
            end
            local a, b, c, d = h1, h2, h3, h4
            local s = 25
            for j = 1, 16 do
               local F = ROR(AND(b, c) + AND(-1-b, d) + a + K[j] + W[j], s) + b
               s = md5_next_shift[s]
               a = d
               d = c
               c = b
               b = F
            end
            s = 27
            for j = 17, 32 do
               local F = ROR(AND(d, b) + AND(-1-d, c) + a + K[j] + W[(5*j-4) % 16 + 1], s) + b
               s = md5_next_shift[s]
               a = d
               d = c
               c = b
               b = F
            end
            s = 28
            for j = 33, 48 do
               local F = ROR(XOR(XOR(b, c), d) + a + K[j] + W[(3*j+2) % 16 + 1], s) + b
               s = md5_next_shift[s]
               a = d
               d = c
               c = b
               b = F
            end
            s = 26
            for j = 49, 64 do
               local F = ROR(XOR(c, OR(b, -1-d)) + a + K[j] + W[(j*7-7) % 16 + 1], s) + b
               s = md5_next_shift[s]
               a = d
               d = c
               c = b
               b = F
            end
            h1 = (a + h1) % 2^32
            h2 = (b + h2) % 2^32
            h3 = (c + h3) % 2^32
            h4 = (d + h4) % 2^32
         end
         H[1], H[2], H[3], H[4] = h1, h2, h3, h4
      end

   elseif branch == "EMUL" then

      function md5_feed_64(H, str, offs, size)
         -- offs >= 0, size >= 0, size is multiple of 64
         local W, K, md5_next_shift = common_W, md5_K, md5_next_shift
         local h1, h2, h3, h4 = H[1], H[2], H[3], H[4]
         for pos = offs, offs + size - 1, 64 do
            for j = 1, 16 do
               pos = pos + 4
               local a, b, c, d = byte(str, pos - 3, pos)
               W[j] = ((d * 256 + c) * 256 + b) * 256 + a
            end
            local a, b, c, d = h1, h2, h3, h4
            local s = 25
            for j = 1, 16 do
               local z = (AND(b, c) + AND(-1-b, d) + a + K[j] + W[j]) % 2^32 / 2^s
               local y = z % 1
               s = md5_next_shift[s]
               a = d
               d = c
               c = b
               b = y * 2^32 + (z - y) + b
            end
            s = 27
            for j = 17, 32 do
               local z = (AND(d, b) + AND(-1-d, c) + a + K[j] + W[(5*j-4) % 16 + 1]) % 2^32 / 2^s
               local y = z % 1
               s = md5_next_shift[s]
               a = d
               d = c
               c = b
               b = y * 2^32 + (z - y) + b
            end
            s = 28
            for j = 33, 48 do
               local z = (XOR(XOR(b, c), d) + a + K[j] + W[(3*j+2) % 16 + 1]) % 2^32 / 2^s
               local y = z % 1
               s = md5_next_shift[s]
               a = d
               d = c
               c = b
               b = y * 2^32 + (z - y) + b
            end
            s = 26
            for j = 49, 64 do
               local z = (XOR(c, OR(b, -1-d)) + a + K[j] + W[(j*7-7) % 16 + 1]) % 2^32 / 2^s
               local y = z % 1
               s = md5_next_shift[s]
               a = d
               d = c
               c = b
               b = y * 2^32 + (z - y) + b
            end
            h1 = (a + h1) % 2^32
            h2 = (b + h2) % 2^32
            h3 = (c + h3) % 2^32
            h4 = (d + h4) % 2^32
         end
         H[1], H[2], H[3], H[4] = h1, h2, h3, h4
      end

   end


   function sha1_feed_64(H, str, offs, size)
      -- offs >= 0, size >= 0, size is multiple of 64
      local W = common_W
      local h1, h2, h3, h4, h5 = H[1], H[2], H[3], H[4], H[5]
      for pos = offs, offs + size - 1, 64 do
         for j = 1, 16 do
            pos = pos + 4
            local a, b, c, d = byte(str, pos - 3, pos)
            W[j] = ((a * 256 + b) * 256 + c) * 256 + d
         end
         for j = 17, 80 do
            local a = XOR(W[j-3], W[j-8], W[j-14], W[j-16]) % 2^32 * 2
            local b = a % 2^32
            W[j] = b + (a - b) / 2^32
         end
         local a, b, c, d, e = h1, h2, h3, h4, h5
         for j = 1, 20 do
            local a5 = a * 2^5
            local z = a5 % 2^32
            z = z + (a5 - z) / 2^32 + AND(b, c) + AND(-1-b, d) + 0x5A827999 + W[j] + e        -- constant = floor(2^30 * sqrt(2))
            e = d
            d = c
            c = b / 2^2
            c = c % 1 * (2^32 - 1) + c
            b = a
            a = z % 2^32
         end
         for j = 21, 40 do
            local a5 = a * 2^5
            local z = a5 % 2^32
            z = z + (a5 - z) / 2^32 + XOR(b, c, d) + 0x6ED9EBA1 + W[j] + e                    -- 2^30 * sqrt(3)
            e = d
            d = c
            c = b / 2^2
            c = c % 1 * (2^32 - 1) + c
            b = a
            a = z % 2^32
         end
         for j = 41, 60 do
            local a5 = a * 2^5
            local z = a5 % 2^32
            z = z + (a5 - z) / 2^32 + AND(d, c) + AND(b, XOR(d, c)) + 0x8F1BBCDC + W[j] + e   -- 2^30 * sqrt(5)
            e = d
            d = c
            c = b / 2^2
            c = c % 1 * (2^32 - 1) + c
            b = a
            a = z % 2^32
         end
         for j = 61, 80 do
            local a5 = a * 2^5
            local z = a5 % 2^32
            z = z + (a5 - z) / 2^32 + XOR(b, c, d) + 0xCA62C1D6 + W[j] + e                    -- 2^30 * sqrt(10)
            e = d
            d = c
            c = b / 2^2
            c = c % 1 * (2^32 - 1) + c
            b = a
            a = z % 2^32
         end
         h1 = (a + h1) % 2^32
         h2 = (b + h2) % 2^32
         h3 = (c + h3) % 2^32
         h4 = (d + h4) % 2^32
         h5 = (e + h5) % 2^32
      end
      H[1], H[2], H[3], H[4], H[5] = h1, h2, h3, h4, h5
   end


   function keccak_feed(lanes_lo, lanes_hi, str, offs, size, block_size_in_bytes)
      -- This is an example of a Lua function having 79 local variables :-)
      -- offs >= 0, size >= 0, size is multiple of block_size_in_bytes, block_size_in_bytes is positive multiple of 8
      local RC_lo, RC_hi = sha3_RC_lo, sha3_RC_hi
      local qwords_qty = block_size_in_bytes / 8
      for pos = offs, offs + size - 1, block_size_in_bytes do
         for j = 1, qwords_qty do
            local a, b, c, d = byte(str, pos + 1, pos + 4)
            lanes_lo[j] = XOR(lanes_lo[j], ((d * 256 + c) * 256 + b) * 256 + a)
            pos = pos + 8
            a, b, c, d = byte(str, pos - 3, pos)
            lanes_hi[j] = XOR(lanes_hi[j], ((d * 256 + c) * 256 + b) * 256 + a)
         end
         local L01_lo, L01_hi, L02_lo, L02_hi, L03_lo, L03_hi, L04_lo, L04_hi, L05_lo, L05_hi, L06_lo, L06_hi, L07_lo, L07_hi, L08_lo, L08_hi,
            L09_lo, L09_hi, L10_lo, L10_hi, L11_lo, L11_hi, L12_lo, L12_hi, L13_lo, L13_hi, L14_lo, L14_hi, L15_lo, L15_hi, L16_lo, L16_hi,
            L17_lo, L17_hi, L18_lo, L18_hi, L19_lo, L19_hi, L20_lo, L20_hi, L21_lo, L21_hi, L22_lo, L22_hi, L23_lo, L23_hi, L24_lo, L24_hi, L25_lo, L25_hi =
            lanes_lo[1], lanes_hi[1], lanes_lo[2], lanes_hi[2], lanes_lo[3], lanes_hi[3], lanes_lo[4], lanes_hi[4], lanes_lo[5], lanes_hi[5],
            lanes_lo[6], lanes_hi[6], lanes_lo[7], lanes_hi[7], lanes_lo[8], lanes_hi[8], lanes_lo[9], lanes_hi[9], lanes_lo[10], lanes_hi[10],
            lanes_lo[11], lanes_hi[11], lanes_lo[12], lanes_hi[12], lanes_lo[13], lanes_hi[13], lanes_lo[14], lanes_hi[14], lanes_lo[15], lanes_hi[15],
            lanes_lo[16], lanes_hi[16], lanes_lo[17], lanes_hi[17], lanes_lo[18], lanes_hi[18], lanes_lo[19], lanes_hi[19], lanes_lo[20], lanes_hi[20],
            lanes_lo[21], lanes_hi[21], lanes_lo[22], lanes_hi[22], lanes_lo[23], lanes_hi[23], lanes_lo[24], lanes_hi[24], lanes_lo[25], lanes_hi[25]
         for round_idx = 1, 24 do
            local C1_lo = XOR(L01_lo, L06_lo, L11_lo, L16_lo, L21_lo)
            local C1_hi = XOR(L01_hi, L06_hi, L11_hi, L16_hi, L21_hi)
            local C2_lo = XOR(L02_lo, L07_lo, L12_lo, L17_lo, L22_lo)
            local C2_hi = XOR(L02_hi, L07_hi, L12_hi, L17_hi, L22_hi)
            local C3_lo = XOR(L03_lo, L08_lo, L13_lo, L18_lo, L23_lo)
            local C3_hi = XOR(L03_hi, L08_hi, L13_hi, L18_hi, L23_hi)
            local C4_lo = XOR(L04_lo, L09_lo, L14_lo, L19_lo, L24_lo)
            local C4_hi = XOR(L04_hi, L09_hi, L14_hi, L19_hi, L24_hi)
            local C5_lo = XOR(L05_lo, L10_lo, L15_lo, L20_lo, L25_lo)
            local C5_hi = XOR(L05_hi, L10_hi, L15_hi, L20_hi, L25_hi)
            local D_lo = XOR(C1_lo, C3_lo * 2 + (C3_hi % 2^32 - C3_hi % 2^31) / 2^31)
            local D_hi = XOR(C1_hi, C3_hi * 2 + (C3_lo % 2^32 - C3_lo % 2^31) / 2^31)
            local T0_lo = XOR(D_lo, L02_lo)
            local T0_hi = XOR(D_hi, L02_hi)
            local T1_lo = XOR(D_lo, L07_lo)
            local T1_hi = XOR(D_hi, L07_hi)
            local T2_lo = XOR(D_lo, L12_lo)
            local T2_hi = XOR(D_hi, L12_hi)
            local T3_lo = XOR(D_lo, L17_lo)
            local T3_hi = XOR(D_hi, L17_hi)
            local T4_lo = XOR(D_lo, L22_lo)
            local T4_hi = XOR(D_hi, L22_hi)
            L02_lo = (T1_lo % 2^32 - T1_lo % 2^20) / 2^20 + T1_hi * 2^12
            L02_hi = (T1_hi % 2^32 - T1_hi % 2^20) / 2^20 + T1_lo * 2^12
            L07_lo = (T3_lo % 2^32 - T3_lo % 2^19) / 2^19 + T3_hi * 2^13
            L07_hi = (T3_hi % 2^32 - T3_hi % 2^19) / 2^19 + T3_lo * 2^13
            L12_lo = T0_lo * 2 + (T0_hi % 2^32 - T0_hi % 2^31) / 2^31
            L12_hi = T0_hi * 2 + (T0_lo % 2^32 - T0_lo % 2^31) / 2^31
            L17_lo = T2_lo * 2^10 + (T2_hi % 2^32 - T2_hi % 2^22) / 2^22
            L17_hi = T2_hi * 2^10 + (T2_lo % 2^32 - T2_lo % 2^22) / 2^22
            L22_lo = T4_lo * 2^2 + (T4_hi % 2^32 - T4_hi % 2^30) / 2^30
            L22_hi = T4_hi * 2^2 + (T4_lo % 2^32 - T4_lo % 2^30) / 2^30
            D_lo = XOR(C2_lo, C4_lo * 2 + (C4_hi % 2^32 - C4_hi % 2^31) / 2^31)
            D_hi = XOR(C2_hi, C4_hi * 2 + (C4_lo % 2^32 - C4_lo % 2^31) / 2^31)
            T0_lo = XOR(D_lo, L03_lo)
            T0_hi = XOR(D_hi, L03_hi)
            T1_lo = XOR(D_lo, L08_lo)
            T1_hi = XOR(D_hi, L08_hi)
            T2_lo = XOR(D_lo, L13_lo)
            T2_hi = XOR(D_hi, L13_hi)
            T3_lo = XOR(D_lo, L18_lo)
            T3_hi = XOR(D_hi, L18_hi)
            T4_lo = XOR(D_lo, L23_lo)
            T4_hi = XOR(D_hi, L23_hi)
            L03_lo = (T2_lo % 2^32 - T2_lo % 2^21) / 2^21 + T2_hi * 2^11
            L03_hi = (T2_hi % 2^32 - T2_hi % 2^21) / 2^21 + T2_lo * 2^11
            L08_lo = (T4_lo % 2^32 - T4_lo % 2^3) / 2^3 + T4_hi * 2^29 % 2^32
            L08_hi = (T4_hi % 2^32 - T4_hi % 2^3) / 2^3 + T4_lo * 2^29 % 2^32
            L13_lo = T1_lo * 2^6 + (T1_hi % 2^32 - T1_hi % 2^26) / 2^26
            L13_hi = T1_hi * 2^6 + (T1_lo % 2^32 - T1_lo % 2^26) / 2^26
            L18_lo = T3_lo * 2^15 + (T3_hi % 2^32 - T3_hi % 2^17) / 2^17
            L18_hi = T3_hi * 2^15 + (T3_lo % 2^32 - T3_lo % 2^17) / 2^17
            L23_lo = (T0_lo % 2^32 - T0_lo % 2^2) / 2^2 + T0_hi * 2^30 % 2^32
            L23_hi = (T0_hi % 2^32 - T0_hi % 2^2) / 2^2 + T0_lo * 2^30 % 2^32
            D_lo = XOR(C3_lo, C5_lo * 2 + (C5_hi % 2^32 - C5_hi % 2^31) / 2^31)
            D_hi = XOR(C3_hi, C5_hi * 2 + (C5_lo % 2^32 - C5_lo % 2^31) / 2^31)
            T0_lo = XOR(D_lo, L04_lo)
            T0_hi = XOR(D_hi, L04_hi)
            T1_lo = XOR(D_lo, L09_lo)
            T1_hi = XOR(D_hi, L09_hi)
            T2_lo = XOR(D_lo, L14_lo)
            T2_hi = XOR(D_hi, L14_hi)
            T3_lo = XOR(D_lo, L19_lo)
            T3_hi = XOR(D_hi, L19_hi)
            T4_lo = XOR(D_lo, L24_lo)
            T4_hi = XOR(D_hi, L24_hi)
            L04_lo = T3_lo * 2^21 % 2^32 + (T3_hi % 2^32 - T3_hi % 2^11) / 2^11
            L04_hi = T3_hi * 2^21 % 2^32 + (T3_lo % 2^32 - T3_lo % 2^11) / 2^11
            L09_lo = T0_lo * 2^28 % 2^32 + (T0_hi % 2^32 - T0_hi % 2^4) / 2^4
            L09_hi = T0_hi * 2^28 % 2^32 + (T0_lo % 2^32 - T0_lo % 2^4) / 2^4
            L14_lo = T2_lo * 2^25 % 2^32 + (T2_hi % 2^32 - T2_hi % 2^7) / 2^7
            L14_hi = T2_hi * 2^25 % 2^32 + (T2_lo % 2^32 - T2_lo % 2^7) / 2^7
            L19_lo = (T4_lo % 2^32 - T4_lo % 2^8) / 2^8 + T4_hi * 2^24 % 2^32
            L19_hi = (T4_hi % 2^32 - T4_hi % 2^8) / 2^8 + T4_lo * 2^24 % 2^32
            L24_lo = (T1_lo % 2^32 - T1_lo % 2^9) / 2^9 + T1_hi * 2^23 % 2^32
            L24_hi = (T1_hi % 2^32 - T1_hi % 2^9) / 2^9 + T1_lo * 2^23 % 2^32
            D_lo = XOR(C4_lo, C1_lo * 2 + (C1_hi % 2^32 - C1_hi % 2^31) / 2^31)
            D_hi = XOR(C4_hi, C1_hi * 2 + (C1_lo % 2^32 - C1_lo % 2^31) / 2^31)
            T0_lo = XOR(D_lo, L05_lo)
            T0_hi = XOR(D_hi, L05_hi)
            T1_lo = XOR(D_lo, L10_lo)
            T1_hi = XOR(D_hi, L10_hi)
            T2_lo = XOR(D_lo, L15_lo)
            T2_hi = XOR(D_hi, L15_hi)
            T3_lo = XOR(D_lo, L20_lo)
            T3_hi = XOR(D_hi, L20_hi)
            T4_lo = XOR(D_lo, L25_lo)
            T4_hi = XOR(D_hi, L25_hi)
            L05_lo = T4_lo * 2^14 + (T4_hi % 2^32 - T4_hi % 2^18) / 2^18
            L05_hi = T4_hi * 2^14 + (T4_lo % 2^32 - T4_lo % 2^18) / 2^18
            L10_lo = T1_lo * 2^20 % 2^32 + (T1_hi % 2^32 - T1_hi % 2^12) / 2^12
            L10_hi = T1_hi * 2^20 % 2^32 + (T1_lo % 2^32 - T1_lo % 2^12) / 2^12
            L15_lo = T3_lo * 2^8 + (T3_hi % 2^32 - T3_hi % 2^24) / 2^24
            L15_hi = T3_hi * 2^8 + (T3_lo % 2^32 - T3_lo % 2^24) / 2^24
            L20_lo = T0_lo * 2^27 % 2^32 + (T0_hi % 2^32 - T0_hi % 2^5) / 2^5
            L20_hi = T0_hi * 2^27 % 2^32 + (T0_lo % 2^32 - T0_lo % 2^5) / 2^5
            L25_lo = (T2_lo % 2^32 - T2_lo % 2^25) / 2^25 + T2_hi * 2^7
            L25_hi = (T2_hi % 2^32 - T2_hi % 2^25) / 2^25 + T2_lo * 2^7
            D_lo = XOR(C5_lo, C2_lo * 2 + (C2_hi % 2^32 - C2_hi % 2^31) / 2^31)
            D_hi = XOR(C5_hi, C2_hi * 2 + (C2_lo % 2^32 - C2_lo % 2^31) / 2^31)
            T1_lo = XOR(D_lo, L06_lo)
            T1_hi = XOR(D_hi, L06_hi)
            T2_lo = XOR(D_lo, L11_lo)
            T2_hi = XOR(D_hi, L11_hi)
            T3_lo = XOR(D_lo, L16_lo)
            T3_hi = XOR(D_hi, L16_hi)
            T4_lo = XOR(D_lo, L21_lo)
            T4_hi = XOR(D_hi, L21_hi)
            L06_lo = T2_lo * 2^3 + (T2_hi % 2^32 - T2_hi % 2^29) / 2^29
            L06_hi = T2_hi * 2^3 + (T2_lo % 2^32 - T2_lo % 2^29) / 2^29
            L11_lo = T4_lo * 2^18 + (T4_hi % 2^32 - T4_hi % 2^14) / 2^14
            L11_hi = T4_hi * 2^18 + (T4_lo % 2^32 - T4_lo % 2^14) / 2^14
            L16_lo = (T1_lo % 2^32 - T1_lo % 2^28) / 2^28 + T1_hi * 2^4
            L16_hi = (T1_hi % 2^32 - T1_hi % 2^28) / 2^28 + T1_lo * 2^4
            L21_lo = (T3_lo % 2^32 - T3_lo % 2^23) / 2^23 + T3_hi * 2^9
            L21_hi = (T3_hi % 2^32 - T3_hi % 2^23) / 2^23 + T3_lo * 2^9
            L01_lo = XOR(D_lo, L01_lo)
            L01_hi = XOR(D_hi, L01_hi)
            L01_lo, L02_lo, L03_lo, L04_lo, L05_lo = XOR(L01_lo, AND(-1-L02_lo, L03_lo)), XOR(L02_lo, AND(-1-L03_lo, L04_lo)), XOR(L03_lo, AND(-1-L04_lo, L05_lo)), XOR(L04_lo, AND(-1-L05_lo, L01_lo)), XOR(L05_lo, AND(-1-L01_lo, L02_lo))
            L01_hi, L02_hi, L03_hi, L04_hi, L05_hi = XOR(L01_hi, AND(-1-L02_hi, L03_hi)), XOR(L02_hi, AND(-1-L03_hi, L04_hi)), XOR(L03_hi, AND(-1-L04_hi, L05_hi)), XOR(L04_hi, AND(-1-L05_hi, L01_hi)), XOR(L05_hi, AND(-1-L01_hi, L02_hi))
            L06_lo, L07_lo, L08_lo, L09_lo, L10_lo = XOR(L09_lo, AND(-1-L10_lo, L06_lo)), XOR(L10_lo, AND(-1-L06_lo, L07_lo)), XOR(L06_lo, AND(-1-L07_lo, L08_lo)), XOR(L07_lo, AND(-1-L08_lo, L09_lo)), XOR(L08_lo, AND(-1-L09_lo, L10_lo))
            L06_hi, L07_hi, L08_hi, L09_hi, L10_hi = XOR(L09_hi, AND(-1-L10_hi, L06_hi)), XOR(L10_hi, AND(-1-L06_hi, L07_hi)), XOR(L06_hi, AND(-1-L07_hi, L08_hi)), XOR(L07_hi, AND(-1-L08_hi, L09_hi)), XOR(L08_hi, AND(-1-L09_hi, L10_hi))
            L11_lo, L12_lo, L13_lo, L14_lo, L15_lo = XOR(L12_lo, AND(-1-L13_lo, L14_lo)), XOR(L13_lo, AND(-1-L14_lo, L15_lo)), XOR(L14_lo, AND(-1-L15_lo, L11_lo)), XOR(L15_lo, AND(-1-L11_lo, L12_lo)), XOR(L11_lo, AND(-1-L12_lo, L13_lo))
            L11_hi, L12_hi, L13_hi, L14_hi, L15_hi = XOR(L12_hi, AND(-1-L13_hi, L14_hi)), XOR(L13_hi, AND(-1-L14_hi, L15_hi)), XOR(L14_hi, AND(-1-L15_hi, L11_hi)), XOR(L15_hi, AND(-1-L11_hi, L12_hi)), XOR(L11_hi, AND(-1-L12_hi, L13_hi))
            L16_lo, L17_lo, L18_lo, L19_lo, L20_lo = XOR(L20_lo, AND(-1-L16_lo, L17_lo)), XOR(L16_lo, AND(-1-L17_lo, L18_lo)), XOR(L17_lo, AND(-1-L18_lo, L19_lo)), XOR(L18_lo, AND(-1-L19_lo, L20_lo)), XOR(L19_lo, AND(-1-L20_lo, L16_lo))
            L16_hi, L17_hi, L18_hi, L19_hi, L20_hi = XOR(L20_hi, AND(-1-L16_hi, L17_hi)), XOR(L16_hi, AND(-1-L17_hi, L18_hi)), XOR(L17_hi, AND(-1-L18_hi, L19_hi)), XOR(L18_hi, AND(-1-L19_hi, L20_hi)), XOR(L19_hi, AND(-1-L20_hi, L16_hi))
            L21_lo, L22_lo, L23_lo, L24_lo, L25_lo = XOR(L23_lo, AND(-1-L24_lo, L25_lo)), XOR(L24_lo, AND(-1-L25_lo, L21_lo)), XOR(L25_lo, AND(-1-L21_lo, L22_lo)), XOR(L21_lo, AND(-1-L22_lo, L23_lo)), XOR(L22_lo, AND(-1-L23_lo, L24_lo))
            L21_hi, L22_hi, L23_hi, L24_hi, L25_hi = XOR(L23_hi, AND(-1-L24_hi, L25_hi)), XOR(L24_hi, AND(-1-L25_hi, L21_hi)), XOR(L25_hi, AND(-1-L21_hi, L22_hi)), XOR(L21_hi, AND(-1-L22_hi, L23_hi)), XOR(L22_hi, AND(-1-L23_hi, L24_hi))
            L01_lo = XOR(L01_lo, RC_lo[round_idx])
            L01_hi = L01_hi + RC_hi[round_idx]      -- RC_hi[] is either 0 or 0x80000000, so we could use fast addition instead of slow XOR
         end
         lanes_lo[1]  = L01_lo;  lanes_hi[1]  = L01_hi
         lanes_lo[2]  = L02_lo;  lanes_hi[2]  = L02_hi
         lanes_lo[3]  = L03_lo;  lanes_hi[3]  = L03_hi
         lanes_lo[4]  = L04_lo;  lanes_hi[4]  = L04_hi
         lanes_lo[5]  = L05_lo;  lanes_hi[5]  = L05_hi
         lanes_lo[6]  = L06_lo;  lanes_hi[6]  = L06_hi
         lanes_lo[7]  = L07_lo;  lanes_hi[7]  = L07_hi
         lanes_lo[8]  = L08_lo;  lanes_hi[8]  = L08_hi
         lanes_lo[9]  = L09_lo;  lanes_hi[9]  = L09_hi
         lanes_lo[10] = L10_lo;  lanes_hi[10] = L10_hi
         lanes_lo[11] = L11_lo;  lanes_hi[11] = L11_hi
         lanes_lo[12] = L12_lo;  lanes_hi[12] = L12_hi
         lanes_lo[13] = L13_lo;  lanes_hi[13] = L13_hi
         lanes_lo[14] = L14_lo;  lanes_hi[14] = L14_hi
         lanes_lo[15] = L15_lo;  lanes_hi[15] = L15_hi
         lanes_lo[16] = L16_lo;  lanes_hi[16] = L16_hi
         lanes_lo[17] = L17_lo;  lanes_hi[17] = L17_hi
         lanes_lo[18] = L18_lo;  lanes_hi[18] = L18_hi
         lanes_lo[19] = L19_lo;  lanes_hi[19] = L19_hi
         lanes_lo[20] = L20_lo;  lanes_hi[20] = L20_hi
         lanes_lo[21] = L21_lo;  lanes_hi[21] = L21_hi
         lanes_lo[22] = L22_lo;  lanes_hi[22] = L22_hi
         lanes_lo[23] = L23_lo;  lanes_hi[23] = L23_hi
         lanes_lo[24] = L24_lo;  lanes_hi[24] = L24_hi
         lanes_lo[25] = L25_lo;  lanes_hi[25] = L25_hi
      end
   end


   function blake2s_feed_64(H, str, offs, size, bytes_compressed, last_block_size, is_last_node)
      -- offs >= 0, size >= 0, size is multiple of 64
      local W = common_W
      local h1, h2, h3, h4, h5, h6, h7, h8 = H[1], H[2], H[3], H[4], H[5], H[6], H[7], H[8]
      for pos = offs, offs + size - 1, 64 do
         if str then
            for j = 1, 16 do
               pos = pos + 4
               local a, b, c, d = byte(str, pos - 3, pos)
               W[j] = ((d * 256 + c) * 256 + b) * 256 + a
            end
         end
         local v0, v1, v2, v3, v4, v5, v6, v7 = h1, h2, h3, h4, h5, h6, h7, h8
         local v8, v9, vA, vB, vC, vD, vE, vF = sha2_H_hi[1], sha2_H_hi[2], sha2_H_hi[3], sha2_H_hi[4], sha2_H_hi[5], sha2_H_hi[6], sha2_H_hi[7], sha2_H_hi[8]
         bytes_compressed = bytes_compressed + (last_block_size or 64)
         local t0 = bytes_compressed % 2^32
         local t1 = (bytes_compressed - t0) / 2^32
         vC = XOR(vC, t0)  -- t0 = low_4_bytes(bytes_compressed)
         vD = XOR(vD, t1)  -- t1 = high_4_bytes(bytes_compressed)
         if last_block_size then  -- flag f0
            vE = -1 - vE
         end
         if is_last_node then  -- flag f1
            vF = -1 - vF
         end
         for j = 1, 10 do
            local row = sigma[j]
            v0 = v0 + v4 + W[row[1]]
            vC = XOR(vC, v0) % 2^32 / 2^16
            vC = vC % 1 * (2^32 - 1) + vC
            v8 = v8 + vC
            v4 = XOR(v4, v8) % 2^32 / 2^12
            v4 = v4 % 1 * (2^32 - 1) + v4
            v0 = v0 + v4 + W[row[2]]
            vC = XOR(vC, v0) % 2^32 / 2^8
            vC = vC % 1 * (2^32 - 1) + vC
            v8 = v8 + vC
            v4 = XOR(v4, v8) % 2^32 / 2^7
            v4 = v4 % 1 * (2^32 - 1) + v4
            v1 = v1 + v5 + W[row[3]]
            vD = XOR(vD, v1) % 2^32 / 2^16
            vD = vD % 1 * (2^32 - 1) + vD
            v9 = v9 + vD
            v5 = XOR(v5, v9) % 2^32 / 2^12
            v5 = v5 % 1 * (2^32 - 1) + v5
            v1 = v1 + v5 + W[row[4]]
            vD = XOR(vD, v1) % 2^32 / 2^8
            vD = vD % 1 * (2^32 - 1) + vD
            v9 = v9 + vD
            v5 = XOR(v5, v9) % 2^32 / 2^7
            v5 = v5 % 1 * (2^32 - 1) + v5
            v2 = v2 + v6 + W[row[5]]
            vE = XOR(vE, v2) % 2^32 / 2^16
            vE = vE % 1 * (2^32 - 1) + vE
            vA = vA + vE
            v6 = XOR(v6, vA) % 2^32 / 2^12
            v6 = v6 % 1 * (2^32 - 1) + v6
            v2 = v2 + v6 + W[row[6]]
            vE = XOR(vE, v2) % 2^32 / 2^8
            vE = vE % 1 * (2^32 - 1) + vE
            vA = vA + vE
            v6 = XOR(v6, vA) % 2^32 / 2^7
            v6 = v6 % 1 * (2^32 - 1) + v6
            v3 = v3 + v7 + W[row[7]]
            vF = XOR(vF, v3) % 2^32 / 2^16
            vF = vF % 1 * (2^32 - 1) + vF
            vB = vB + vF
            v7 = XOR(v7, vB) % 2^32 / 2^12
            v7 = v7 % 1 * (2^32 - 1) + v7
            v3 = v3 + v7 + W[row[8]]
            vF = XOR(vF, v3) % 2^32 / 2^8
            vF = vF % 1 * (2^32 - 1) + vF
            vB = vB + vF
            v7 = XOR(v7, vB) % 2^32 / 2^7
            v7 = v7 % 1 * (2^32 - 1) + v7
            v0 = v0 + v5 + W[row[9]]
            vF = XOR(vF, v0) % 2^32 / 2^16
            vF = vF % 1 * (2^32 - 1) + vF
            vA = vA + vF
            v5 = XOR(v5, vA) % 2^32 / 2^12
            v5 = v5 % 1 * (2^32 - 1) + v5
            v0 = v0 + v5 + W[row[10]]
            vF = XOR(vF, v0) % 2^32 / 2^8
            vF = vF % 1 * (2^32 - 1) + vF
            vA = vA + vF
            v5 = XOR(v5, vA) % 2^32 / 2^7
            v5 = v5 % 1 * (2^32 - 1) + v5
            v1 = v1 + v6 + W[row[11]]
            vC = XOR(vC, v1) % 2^32 / 2^16
            vC = vC % 1 * (2^32 - 1) + vC
            vB = vB + vC
            v6 = XOR(v6, vB) % 2^32 / 2^12
            v6 = v6 % 1 * (2^32 - 1) + v6
            v1 = v1 + v6 + W[row[12]]
            vC = XOR(vC, v1) % 2^32 / 2^8
            vC = vC % 1 * (2^32 - 1) + vC
            vB = vB + vC
            v6 = XOR(v6, vB) % 2^32 / 2^7
            v6 = v6 % 1 * (2^32 - 1) + v6
            v2 = v2 + v7 + W[row[13]]
            vD = XOR(vD, v2) % 2^32 / 2^16
            vD = vD % 1 * (2^32 - 1) + vD
            v8 = v8 + vD
            v7 = XOR(v7, v8) % 2^32 / 2^12
            v7 = v7 % 1 * (2^32 - 1) + v7
            v2 = v2 + v7 + W[row[14]]
            vD = XOR(vD, v2) % 2^32 / 2^8
            vD = vD % 1 * (2^32 - 1) + vD
            v8 = v8 + vD
            v7 = XOR(v7, v8) % 2^32 / 2^7
            v7 = v7 % 1 * (2^32 - 1) + v7
            v3 = v3 + v4 + W[row[15]]
            vE = XOR(vE, v3) % 2^32 / 2^16
            vE = vE % 1 * (2^32 - 1) + vE
            v9 = v9 + vE
            v4 = XOR(v4, v9) % 2^32 / 2^12
            v4 = v4 % 1 * (2^32 - 1) + v4
            v3 = v3 + v4 + W[row[16]]
            vE = XOR(vE, v3) % 2^32 / 2^8
            vE = vE % 1 * (2^32 - 1) + vE
            v9 = v9 + vE
            v4 = XOR(v4, v9) % 2^32 / 2^7
            v4 = v4 % 1 * (2^32 - 1) + v4
         end
         h1 = XOR(h1, v0, v8)
         h2 = XOR(h2, v1, v9)
         h3 = XOR(h3, v2, vA)
         h4 = XOR(h4, v3, vB)
         h5 = XOR(h5, v4, vC)
         h6 = XOR(h6, v5, vD)
         h7 = XOR(h7, v6, vE)
         h8 = XOR(h8, v7, vF)
      end
      H[1], H[2], H[3], H[4], H[5], H[6], H[7], H[8] = h1, h2, h3, h4, h5, h6, h7, h8
      return bytes_compressed
   end


   function blake2b_feed_128(H_lo, H_hi, str, offs, size, bytes_compressed, last_block_size, is_last_node)
      -- offs >= 0, size >= 0, size is multiple of 128
      local W = common_W
      local h1_lo, h2_lo, h3_lo, h4_lo, h5_lo, h6_lo, h7_lo, h8_lo = H_lo[1], H_lo[2], H_lo[3], H_lo[4], H_lo[5], H_lo[6], H_lo[7], H_lo[8]
      local h1_hi, h2_hi, h3_hi, h4_hi, h5_hi, h6_hi, h7_hi, h8_hi = H_hi[1], H_hi[2], H_hi[3], H_hi[4], H_hi[5], H_hi[6], H_hi[7], H_hi[8]
      for pos = offs, offs + size - 1, 128 do
         if str then
            for j = 1, 32 do
               pos = pos + 4
               local a, b, c, d = byte(str, pos - 3, pos)
               W[j] = ((d * 256 + c) * 256 + b) * 256 + a
            end
         end
         local v0_lo, v1_lo, v2_lo, v3_lo, v4_lo, v5_lo, v6_lo, v7_lo = h1_lo, h2_lo, h3_lo, h4_lo, h5_lo, h6_lo, h7_lo, h8_lo
         local v0_hi, v1_hi, v2_hi, v3_hi, v4_hi, v5_hi, v6_hi, v7_hi = h1_hi, h2_hi, h3_hi, h4_hi, h5_hi, h6_hi, h7_hi, h8_hi
         local v8_lo, v9_lo, vA_lo, vB_lo, vC_lo, vD_lo, vE_lo, vF_lo = sha2_H_lo[1], sha2_H_lo[2], sha2_H_lo[3], sha2_H_lo[4], sha2_H_lo[5], sha2_H_lo[6], sha2_H_lo[7], sha2_H_lo[8]
         local v8_hi, v9_hi, vA_hi, vB_hi, vC_hi, vD_hi, vE_hi, vF_hi = sha2_H_hi[1], sha2_H_hi[2], sha2_H_hi[3], sha2_H_hi[4], sha2_H_hi[5], sha2_H_hi[6], sha2_H_hi[7], sha2_H_hi[8]
         bytes_compressed = bytes_compressed + (last_block_size or 128)
         local t0_lo = bytes_compressed % 2^32
         local t0_hi = (bytes_compressed - t0_lo) / 2^32
         vC_lo = XOR(vC_lo, t0_lo)  -- t0 = low_8_bytes(bytes_compressed)
         vC_hi = XOR(vC_hi, t0_hi)
         -- t1 = high_8_bytes(bytes_compressed) = 0,  message length is always below 2^53 bytes
         if last_block_size then  -- flag f0
            vE_lo = -1 - vE_lo
            vE_hi = -1 - vE_hi
         end
         if is_last_node then  -- flag f1
            vF_lo = -1 - vF_lo
            vF_hi = -1 - vF_hi
         end
         for j = 1, 12 do
            local row = sigma[j]
            local k = row[1] * 2
            local z = v0_lo % 2^32 + v4_lo % 2^32 + W[k-1]
            v0_lo = z % 2^32
            v0_hi = v0_hi + v4_hi + (z - v0_lo) / 2^32 + W[k]
            vC_lo, vC_hi = XOR(vC_hi, v0_hi), XOR(vC_lo, v0_lo)
            z = v8_lo % 2^32 + vC_lo % 2^32
            v8_lo = z % 2^32
            v8_hi = v8_hi + vC_hi + (z - v8_lo) / 2^32
            v4_lo, v4_hi = XOR(v4_lo, v8_lo), XOR(v4_hi, v8_hi)
            local z_lo, z_hi = v4_lo % 2^24, v4_hi % 2^24
            v4_lo, v4_hi = (v4_lo - z_lo) / 2^24 % 2^8 + z_hi * 2^8, (v4_hi - z_hi) / 2^24 % 2^8 + z_lo * 2^8
            k = row[2] * 2
            z = v0_lo % 2^32 + v4_lo % 2^32 + W[k-1]
            v0_lo = z % 2^32
            v0_hi = v0_hi + v4_hi + (z - v0_lo) / 2^32 + W[k]
            vC_lo, vC_hi = XOR(vC_lo, v0_lo), XOR(vC_hi, v0_hi)
            z_lo, z_hi = vC_lo % 2^16, vC_hi % 2^16
            vC_lo, vC_hi = (vC_lo - z_lo) / 2^16 % 2^16 + z_hi * 2^16, (vC_hi - z_hi) / 2^16 % 2^16 + z_lo * 2^16
            z = v8_lo % 2^32 + vC_lo % 2^32
            v8_lo = z % 2^32
            v8_hi = v8_hi + vC_hi + (z - v8_lo) / 2^32
            v4_lo, v4_hi = XOR(v4_lo, v8_lo), XOR(v4_hi, v8_hi)
            z_lo, z_hi = v4_lo % 2^31, v4_hi % 2^31
            v4_lo, v4_hi = z_lo * 2^1 + (v4_hi - z_hi) / 2^31 % 2^1, z_hi * 2^1 + (v4_lo - z_lo) / 2^31 % 2^1
            k = row[3] * 2
            z = v1_lo % 2^32 + v5_lo % 2^32 + W[k-1]
            v1_lo = z % 2^32
            v1_hi = v1_hi + v5_hi + (z - v1_lo) / 2^32 + W[k]
            vD_lo, vD_hi = XOR(vD_hi, v1_hi), XOR(vD_lo, v1_lo)
            z = v9_lo % 2^32 + vD_lo % 2^32
            v9_lo = z % 2^32
            v9_hi = v9_hi + vD_hi + (z - v9_lo) / 2^32
            v5_lo, v5_hi = XOR(v5_lo, v9_lo), XOR(v5_hi, v9_hi)
            z_lo, z_hi = v5_lo % 2^24, v5_hi % 2^24
            v5_lo, v5_hi = (v5_lo - z_lo) / 2^24 % 2^8 + z_hi * 2^8, (v5_hi - z_hi) / 2^24 % 2^8 + z_lo * 2^8
            k = row[4] * 2
            z = v1_lo % 2^32 + v5_lo % 2^32 + W[k-1]
            v1_lo = z % 2^32
            v1_hi = v1_hi + v5_hi + (z - v1_lo) / 2^32 + W[k]
            vD_lo, vD_hi = XOR(vD_lo, v1_lo), XOR(vD_hi, v1_hi)
            z_lo, z_hi = vD_lo % 2^16, vD_hi % 2^16
            vD_lo, vD_hi = (vD_lo - z_lo) / 2^16 % 2^16 + z_hi * 2^16, (vD_hi - z_hi) / 2^16 % 2^16 + z_lo * 2^16
            z = v9_lo % 2^32 + vD_lo % 2^32
            v9_lo = z % 2^32
            v9_hi = v9_hi + vD_hi + (z - v9_lo) / 2^32
            v5_lo, v5_hi = XOR(v5_lo, v9_lo), XOR(v5_hi, v9_hi)
            z_lo, z_hi = v5_lo % 2^31, v5_hi % 2^31
            v5_lo, v5_hi = z_lo * 2^1 + (v5_hi - z_hi) / 2^31 % 2^1, z_hi * 2^1 + (v5_lo - z_lo) / 2^31 % 2^1
            k = row[5] * 2
            z = v2_lo % 2^32 + v6_lo % 2^32 + W[k-1]
            v2_lo = z % 2^32
            v2_hi = v2_hi + v6_hi + (z - v2_lo) / 2^32 + W[k]
            vE_lo, vE_hi = XOR(vE_hi, v2_hi), XOR(vE_lo, v2_lo)
            z = vA_lo % 2^32 + vE_lo % 2^32
            vA_lo = z % 2^32
            vA_hi = vA_hi + vE_hi + (z - vA_lo) / 2^32
            v6_lo, v6_hi = XOR(v6_lo, vA_lo), XOR(v6_hi, vA_hi)
            z_lo, z_hi = v6_lo % 2^24, v6_hi % 2^24
            v6_lo, v6_hi = (v6_lo - z_lo) / 2^24 % 2^8 + z_hi * 2^8, (v6_hi - z_hi) / 2^24 % 2^8 + z_lo * 2^8
            k = row[6] * 2
            z = v2_lo % 2^32 + v6_lo % 2^32 + W[k-1]
            v2_lo = z % 2^32
            v2_hi = v2_hi + v6_hi + (z - v2_lo) / 2^32 + W[k]
            vE_lo, vE_hi = XOR(vE_lo, v2_lo), XOR(vE_hi, v2_hi)
            z_lo, z_hi = vE_lo % 2^16, vE_hi % 2^16
            vE_lo, vE_hi = (vE_lo - z_lo) / 2^16 % 2^16 + z_hi * 2^16, (vE_hi - z_hi) / 2^16 % 2^16 + z_lo * 2^16
            z = vA_lo % 2^32 + vE_lo % 2^32
            vA_lo = z % 2^32
            vA_hi = vA_hi + vE_hi + (z - vA_lo) / 2^32
            v6_lo, v6_hi = XOR(v6_lo, vA_lo), XOR(v6_hi, vA_hi)
            z_lo, z_hi = v6_lo % 2^31, v6_hi % 2^31
            v6_lo, v6_hi = z_lo * 2^1 + (v6_hi - z_hi) / 2^31 % 2^1, z_hi * 2^1 + (v6_lo - z_lo) / 2^31 % 2^1
            k = row[7] * 2
            z = v3_lo % 2^32 + v7_lo % 2^32 + W[k-1]
            v3_lo = z % 2^32
            v3_hi = v3_hi + v7_hi + (z - v3_lo) / 2^32 + W[k]
            vF_lo, vF_hi = XOR(vF_hi, v3_hi), XOR(vF_lo, v3_lo)
            z = vB_lo % 2^32 + vF_lo % 2^32
            vB_lo = z % 2^32
            vB_hi = vB_hi + vF_hi + (z - vB_lo) / 2^32
            v7_lo, v7_hi = XOR(v7_lo, vB_lo), XOR(v7_hi, vB_hi)
            z_lo, z_hi = v7_lo % 2^24, v7_hi % 2^24
            v7_lo, v7_hi = (v7_lo - z_lo) / 2^24 % 2^8 + z_hi * 2^8, (v7_hi - z_hi) / 2^24 % 2^8 + z_lo * 2^8
            k = row[8] * 2
            z = v3_lo % 2^32 + v7_lo % 2^32 + W[k-1]
            v3_lo = z % 2^32
            v3_hi = v3_hi + v7_hi + (z - v3_lo) / 2^32 + W[k]
            vF_lo, vF_hi = XOR(vF_lo, v3_lo), XOR(vF_hi, v3_hi)
            z_lo, z_hi = vF_lo % 2^16, vF_hi % 2^16
            vF_lo, vF_hi = (vF_lo - z_lo) / 2^16 % 2^16 + z_hi * 2^16, (vF_hi - z_hi) / 2^16 % 2^16 + z_lo * 2^16
            z = vB_lo % 2^32 + vF_lo % 2^32
            vB_lo = z % 2^32
            vB_hi = vB_hi + vF_hi + (z - vB_lo) / 2^32
            v7_lo, v7_hi = XOR(v7_lo, vB_lo), XOR(v7_hi, vB_hi)
            z_lo, z_hi = v7_lo % 2^31, v7_hi % 2^31
            v7_lo, v7_hi = z_lo * 2^1 + (v7_hi - z_hi) / 2^31 % 2^1, z_hi * 2^1 + (v7_lo - z_lo) / 2^31 % 2^1
            k = row[9] * 2
            z = v0_lo % 2^32 + v5_lo % 2^32 + W[k-1]
            v0_lo = z % 2^32
            v0_hi = v0_hi + v5_hi + (z - v0_lo) / 2^32 + W[k]
            vF_lo, vF_hi = XOR(vF_hi, v0_hi), XOR(vF_lo, v0_lo)
            z = vA_lo % 2^32 + vF_lo % 2^32
            vA_lo = z % 2^32
            vA_hi = vA_hi + vF_hi + (z - vA_lo) / 2^32
            v5_lo, v5_hi = XOR(v5_lo, vA_lo), XOR(v5_hi, vA_hi)
            z_lo, z_hi = v5_lo % 2^24, v5_hi % 2^24
            v5_lo, v5_hi = (v5_lo - z_lo) / 2^24 % 2^8 + z_hi * 2^8, (v5_hi - z_hi) / 2^24 % 2^8 + z_lo * 2^8
            k = row[10] * 2
            z = v0_lo % 2^32 + v5_lo % 2^32 + W[k-1]
            v0_lo = z % 2^32
            v0_hi = v0_hi + v5_hi + (z - v0_lo) / 2^32 + W[k]
            vF_lo, vF_hi = XOR(vF_lo, v0_lo), XOR(vF_hi, v0_hi)
            z_lo, z_hi = vF_lo % 2^16, vF_hi % 2^16
            vF_lo, vF_hi = (vF_lo - z_lo) / 2^16 % 2^16 + z_hi * 2^16, (vF_hi - z_hi) / 2^16 % 2^16 + z_lo * 2^16
            z = vA_lo % 2^32 + vF_lo % 2^32
            vA_lo = z % 2^32
            vA_hi = vA_hi + vF_hi + (z - vA_lo) / 2^32
            v5_lo, v5_hi = XOR(v5_lo, vA_lo), XOR(v5_hi, vA_hi)
            z_lo, z_hi = v5_lo % 2^31, v5_hi % 2^31
            v5_lo, v5_hi = z_lo * 2^1 + (v5_hi - z_hi) / 2^31 % 2^1, z_hi * 2^1 + (v5_lo - z_lo) / 2^31 % 2^1
            k = row[11] * 2
            z = v1_lo % 2^32 + v6_lo % 2^32 + W[k-1]
            v1_lo = z % 2^32
            v1_hi = v1_hi + v6_hi + (z - v1_lo) / 2^32 + W[k]
            vC_lo, vC_hi = XOR(vC_hi, v1_hi), XOR(vC_lo, v1_lo)
            z = vB_lo % 2^32 + vC_lo % 2^32
            vB_lo = z % 2^32
            vB_hi = vB_hi + vC_hi + (z - vB_lo) / 2^32
            v6_lo, v6_hi = XOR(v6_lo, vB_lo), XOR(v6_hi, vB_hi)
            z_lo, z_hi = v6_lo % 2^24, v6_hi % 2^24
            v6_lo, v6_hi = (v6_lo - z_lo) / 2^24 % 2^8 + z_hi * 2^8, (v6_hi - z_hi) / 2^24 % 2^8 + z_lo * 2^8
            k = row[12] * 2
            z = v1_lo % 2^32 + v6_lo % 2^32 + W[k-1]
            v1_lo = z % 2^32
            v1_hi = v1_hi + v6_hi + (z - v1_lo) / 2^32 + W[k]
            vC_lo, vC_hi = XOR(vC_lo, v1_lo), XOR(vC_hi, v1_hi)
            z_lo, z_hi = vC_lo % 2^16, vC_hi % 2^16
            vC_lo, vC_hi = (vC_lo - z_lo) / 2^16 % 2^16 + z_hi * 2^16, (vC_hi - z_hi) / 2^16 % 2^16 + z_lo * 2^16
            z = vB_lo % 2^32 + vC_lo % 2^32
            vB_lo = z % 2^32
            vB_hi = vB_hi + vC_hi + (z - vB_lo) / 2^32
            v6_lo, v6_hi = XOR(v6_lo, vB_lo), XOR(v6_hi, vB_hi)
            z_lo, z_hi = v6_lo % 2^31, v6_hi % 2^31
            v6_lo, v6_hi = z_lo * 2^1 + (v6_hi - z_hi) / 2^31 % 2^1, z_hi * 2^1 + (v6_lo - z_lo) / 2^31 % 2^1
            k = row[13] * 2
            z = v2_lo % 2^32 + v7_lo % 2^32 + W[k-1]
            v2_lo = z % 2^32
            v2_hi = v2_hi + v7_hi + (z - v2_lo) / 2^32 + W[k]
            vD_lo, vD_hi = XOR(vD_hi, v2_hi), XOR(vD_lo, v2_lo)
            z = v8_lo % 2^32 + vD_lo % 2^32
            v8_lo = z % 2^32
            v8_hi = v8_hi + vD_hi + (z - v8_lo) / 2^32
            v7_lo, v7_hi = XOR(v7_lo, v8_lo), XOR(v7_hi, v8_hi)
            z_lo, z_hi = v7_lo % 2^24, v7_hi % 2^24
            v7_lo, v7_hi = (v7_lo - z_lo) / 2^24 % 2^8 + z_hi * 2^8, (v7_hi - z_hi) / 2^24 % 2^8 + z_lo * 2^8
            k = row[14] * 2
            z = v2_lo % 2^32 + v7_lo % 2^32 + W[k-1]
            v2_lo = z % 2^32
            v2_hi = v2_hi + v7_hi + (z - v2_lo) / 2^32 + W[k]
            vD_lo, vD_hi = XOR(vD_lo, v2_lo), XOR(vD_hi, v2_hi)
            z_lo, z_hi = vD_lo % 2^16, vD_hi % 2^16
            vD_lo, vD_hi = (vD_lo - z_lo) / 2^16 % 2^16 + z_hi * 2^16, (vD_hi - z_hi) / 2^16 % 2^16 + z_lo * 2^16
            z = v8_lo % 2^32 + vD_lo % 2^32
            v8_lo = z % 2^32
            v8_hi = v8_hi + vD_hi + (z - v8_lo) / 2^32
            v7_lo, v7_hi = XOR(v7_lo, v8_lo), XOR(v7_hi, v8_hi)
            z_lo, z_hi = v7_lo % 2^31, v7_hi % 2^31
            v7_lo, v7_hi = z_lo * 2^1 + (v7_hi - z_hi) / 2^31 % 2^1, z_hi * 2^1 + (v7_lo - z_lo) / 2^31 % 2^1
            k = row[15] * 2
            z = v3_lo % 2^32 + v4_lo % 2^32 + W[k-1]
            v3_lo = z % 2^32
            v3_hi = v3_hi + v4_hi + (z - v3_lo) / 2^32 + W[k]
            vE_lo, vE_hi = XOR(vE_hi, v3_hi), XOR(vE_lo, v3_lo)
            z = v9_lo % 2^32 + vE_lo % 2^32
            v9_lo = z % 2^32
            v9_hi = v9_hi + vE_hi + (z - v9_lo) / 2^32
            v4_lo, v4_hi = XOR(v4_lo, v9_lo), XOR(v4_hi, v9_hi)
            z_lo, z_hi = v4_lo % 2^24, v4_hi % 2^24
            v4_lo, v4_hi = (v4_lo - z_lo) / 2^24 % 2^8 + z_hi * 2^8, (v4_hi - z_hi) / 2^24 % 2^8 + z_lo * 2^8
            k = row[16] * 2
            z = v3_lo % 2^32 + v4_lo % 2^32 + W[k-1]
            v3_lo = z % 2^32
            v3_hi = v3_hi + v4_hi + (z - v3_lo) / 2^32 + W[k]
            vE_lo, vE_hi = XOR(vE_lo, v3_lo), XOR(vE_hi, v3_hi)
            z_lo, z_hi = vE_lo % 2^16, vE_hi % 2^16
            vE_lo, vE_hi = (vE_lo - z_lo) / 2^16 % 2^16 + z_hi * 2^16, (vE_hi - z_hi) / 2^16 % 2^16 + z_lo * 2^16
            z = v9_lo % 2^32 + vE_lo % 2^32
            v9_lo = z % 2^32
            v9_hi = v9_hi + vE_hi + (z - v9_lo) / 2^32
            v4_lo, v4_hi = XOR(v4_lo, v9_lo), XOR(v4_hi, v9_hi)
            z_lo, z_hi = v4_lo % 2^31, v4_hi % 2^31
            v4_lo, v4_hi = z_lo * 2^1 + (v4_hi - z_hi) / 2^31 % 2^1, z_hi * 2^1 + (v4_lo - z_lo) / 2^31 % 2^1
         end
         h1_lo = XOR(h1_lo, v0_lo, v8_lo) % 2^32
         h2_lo = XOR(h2_lo, v1_lo, v9_lo) % 2^32
         h3_lo = XOR(h3_lo, v2_lo, vA_lo) % 2^32
         h4_lo = XOR(h4_lo, v3_lo, vB_lo) % 2^32
         h5_lo = XOR(h5_lo, v4_lo, vC_lo) % 2^32
         h6_lo = XOR(h6_lo, v5_lo, vD_lo) % 2^32
         h7_lo = XOR(h7_lo, v6_lo, vE_lo) % 2^32
         h8_lo = XOR(h8_lo, v7_lo, vF_lo) % 2^32
         h1_hi = XOR(h1_hi, v0_hi, v8_hi) % 2^32
         h2_hi = XOR(h2_hi, v1_hi, v9_hi) % 2^32
         h3_hi = XOR(h3_hi, v2_hi, vA_hi) % 2^32
         h4_hi = XOR(h4_hi, v3_hi, vB_hi) % 2^32
         h5_hi = XOR(h5_hi, v4_hi, vC_hi) % 2^32
         h6_hi = XOR(h6_hi, v5_hi, vD_hi) % 2^32
         h7_hi = XOR(h7_hi, v6_hi, vE_hi) % 2^32
         h8_hi = XOR(h8_hi, v7_hi, vF_hi) % 2^32
      end
      H_lo[1], H_lo[2], H_lo[3], H_lo[4], H_lo[5], H_lo[6], H_lo[7], H_lo[8] = h1_lo, h2_lo, h3_lo, h4_lo, h5_lo, h6_lo, h7_lo, h8_lo
      H_hi[1], H_hi[2], H_hi[3], H_hi[4], H_hi[5], H_hi[6], H_hi[7], H_hi[8] = h1_hi, h2_hi, h3_hi, h4_hi, h5_hi, h6_hi, h7_hi, h8_hi
      return bytes_compressed
   end


   function blake3_feed_64(str, offs, size, flags, chunk_index, H_in, H_out, wide_output, block_length)
      -- offs >= 0, size >= 0, size is multiple of 64
      block_length = block_length or 64
      local W = common_W
      local h1, h2, h3, h4, h5, h6, h7, h8 = H_in[1], H_in[2], H_in[3], H_in[4], H_in[5], H_in[6], H_in[7], H_in[8]
      H_out = H_out or H_in
      for pos = offs, offs + size - 1, 64 do
         if str then
            for j = 1, 16 do
               pos = pos + 4
               local a, b, c, d = byte(str, pos - 3, pos)
               W[j] = ((d * 256 + c) * 256 + b) * 256 + a
            end
         end
         local v0, v1, v2, v3, v4, v5, v6, v7 = h1, h2, h3, h4, h5, h6, h7, h8
         local v8, v9, vA, vB = sha2_H_hi[1], sha2_H_hi[2], sha2_H_hi[3], sha2_H_hi[4]
         local vC = chunk_index % 2^32         -- t0 = low_4_bytes(chunk_index)
         local vD = (chunk_index - vC) / 2^32  -- t1 = high_4_bytes(chunk_index)
         local vE, vF = block_length, flags
         for j = 1, 7 do
            v0 = v0 + v4 + W[perm_blake3[j]]
            vC = XOR(vC, v0) % 2^32 / 2^16
            vC = vC % 1 * (2^32 - 1) + vC
            v8 = v8 + vC
            v4 = XOR(v4, v8) % 2^32 / 2^12
            v4 = v4 % 1 * (2^32 - 1) + v4
            v0 = v0 + v4 + W[perm_blake3[j + 14]]
            vC = XOR(vC, v0) % 2^32 / 2^8
            vC = vC % 1 * (2^32 - 1) + vC
            v8 = v8 + vC
            v4 = XOR(v4, v8) % 2^32 / 2^7
            v4 = v4 % 1 * (2^32 - 1) + v4
            v1 = v1 + v5 + W[perm_blake3[j + 1]]
            vD = XOR(vD, v1) % 2^32 / 2^16
            vD = vD % 1 * (2^32 - 1) + vD
            v9 = v9 + vD
            v5 = XOR(v5, v9) % 2^32 / 2^12
            v5 = v5 % 1 * (2^32 - 1) + v5
            v1 = v1 + v5 + W[perm_blake3[j + 2]]
            vD = XOR(vD, v1) % 2^32 / 2^8
            vD = vD % 1 * (2^32 - 1) + vD
            v9 = v9 + vD
            v5 = XOR(v5, v9) % 2^32 / 2^7
            v5 = v5 % 1 * (2^32 - 1) + v5
            v2 = v2 + v6 + W[perm_blake3[j + 16]]
            vE = XOR(vE, v2) % 2^32 / 2^16
            vE = vE % 1 * (2^32 - 1) + vE
            vA = vA + vE
            v6 = XOR(v6, vA) % 2^32 / 2^12
            v6 = v6 % 1 * (2^32 - 1) + v6
            v2 = v2 + v6 + W[perm_blake3[j + 7]]
            vE = XOR(vE, v2) % 2^32 / 2^8
            vE = vE % 1 * (2^32 - 1) + vE
            vA = vA + vE
            v6 = XOR(v6, vA) % 2^32 / 2^7
            v6 = v6 % 1 * (2^32 - 1) + v6
            v3 = v3 + v7 + W[perm_blake3[j + 15]]
            vF = XOR(vF, v3) % 2^32 / 2^16
            vF = vF % 1 * (2^32 - 1) + vF
            vB = vB + vF
            v7 = XOR(v7, vB) % 2^32 / 2^12
            v7 = v7 % 1 * (2^32 - 1) + v7
            v3 = v3 + v7 + W[perm_blake3[j + 17]]
            vF = XOR(vF, v3) % 2^32 / 2^8
            vF = vF % 1 * (2^32 - 1) + vF
            vB = vB + vF
            v7 = XOR(v7, vB) % 2^32 / 2^7
            v7 = v7 % 1 * (2^32 - 1) + v7
            v0 = v0 + v5 + W[perm_blake3[j + 21]]
            vF = XOR(vF, v0) % 2^32 / 2^16
            vF = vF % 1 * (2^32 - 1) + vF
            vA = vA + vF
            v5 = XOR(v5, vA) % 2^32 / 2^12
            v5 = v5 % 1 * (2^32 - 1) + v5
            v0 = v0 + v5 + W[perm_blake3[j + 5]]
            vF = XOR(vF, v0) % 2^32 / 2^8
            vF = vF % 1 * (2^32 - 1) + vF
            vA = vA + vF
            v5 = XOR(v5, vA) % 2^32 / 2^7
            v5 = v5 % 1 * (2^32 - 1) + v5
            v1 = v1 + v6 + W[perm_blake3[j + 3]]
            vC = XOR(vC, v1) % 2^32 / 2^16
            vC = vC % 1 * (2^32 - 1) + vC
            vB = vB + vC
            v6 = XOR(v6, vB) % 2^32 / 2^12
            v6 = v6 % 1 * (2^32 - 1) + v6
            v1 = v1 + v6 + W[perm_blake3[j + 6]]
            vC = XOR(vC, v1) % 2^32 / 2^8
            vC = vC % 1 * (2^32 - 1) + vC
            vB = vB + vC
            v6 = XOR(v6, vB) % 2^32 / 2^7
            v6 = v6 % 1 * (2^32 - 1) + v6
            v2 = v2 + v7 + W[perm_blake3[j + 4]]
            vD = XOR(vD, v2) % 2^32 / 2^16
            vD = vD % 1 * (2^32 - 1) + vD
            v8 = v8 + vD
            v7 = XOR(v7, v8) % 2^32 / 2^12
            v7 = v7 % 1 * (2^32 - 1) + v7
            v2 = v2 + v7 + W[perm_blake3[j + 18]]
            vD = XOR(vD, v2) % 2^32 / 2^8
            vD = vD % 1 * (2^32 - 1) + vD
            v8 = v8 + vD
            v7 = XOR(v7, v8) % 2^32 / 2^7
            v7 = v7 % 1 * (2^32 - 1) + v7
            v3 = v3 + v4 + W[perm_blake3[j + 19]]
            vE = XOR(vE, v3) % 2^32 / 2^16
            vE = vE % 1 * (2^32 - 1) + vE
            v9 = v9 + vE
            v4 = XOR(v4, v9) % 2^32 / 2^12
            v4 = v4 % 1 * (2^32 - 1) + v4
            v3 = v3 + v4 + W[perm_blake3[j + 20]]
            vE = XOR(vE, v3) % 2^32 / 2^8
            vE = vE % 1 * (2^32 - 1) + vE
            v9 = v9 + vE
            v4 = XOR(v4, v9) % 2^32 / 2^7
            v4 = v4 % 1 * (2^32 - 1) + v4
         end
         if wide_output then
            H_out[ 9] = XOR(h1, v8)
            H_out[10] = XOR(h2, v9)
            H_out[11] = XOR(h3, vA)
            H_out[12] = XOR(h4, vB)
            H_out[13] = XOR(h5, vC)
            H_out[14] = XOR(h6, vD)
            H_out[15] = XOR(h7, vE)
            H_out[16] = XOR(h8, vF)
         end
         h1 = XOR(v0, v8)
         h2 = XOR(v1, v9)
         h3 = XOR(v2, vA)
         h4 = XOR(v3, vB)
         h5 = XOR(v4, vC)
         h6 = XOR(v5, vD)
         h7 = XOR(v6, vE)
         h8 = XOR(v7, vF)
      end
      H_out[1], H_out[2], H_out[3], H_out[4], H_out[5], H_out[6], H_out[7], H_out[8] = h1, h2, h3, h4, h5, h6, h7, h8
   end

end


--------------------------------------------------------------------------------
-- MAGIC NUMBERS CALCULATOR
--------------------------------------------------------------------------------
-- Q:
--    Is 53-bit "double" math enough to calculate square roots and cube roots of primes with 64 correct bits after decimal point?
-- A:
--    Yes, 53-bit "double" arithmetic is enough.
--    We could obtain first 40 bits by direct calculation of p^(1/3) and next 40 bits by one step of Newton's method.

do
   local function mul(src1, src2, factor, result_length)
      -- src1, src2 - long integers (arrays of digits in base 2^24)
      -- factor - small integer
      -- returns long integer result (src1 * src2 * factor) and its floating point approximation
      local result, carry, value, weight = {}, 0.0, 0.0, 1.0
      for j = 1, result_length do
         for k = math_max(1, j + 1 - #src2), math_min(j, #src1) do
            carry = carry + factor * src1[k] * src2[j + 1 - k]  -- "int32" is not enough for multiplication result, that's why "factor" must be of type "double"
         end
         local digit = carry % 2^24
         result[j] = floor(digit)
         carry = (carry - digit) / 2^24
         value = value + digit * weight
         weight = weight * 2^24
      end
      return result, value
   end

   local idx, step, p, one, sqrt_hi, sqrt_lo = 0, {4, 1, 2, -2, 2}, 4, {1}, sha2_H_hi, sha2_H_lo
   repeat
      p = p + step[p % 6]
      local d = 1
      repeat
         d = d + step[d % 6]
         if d*d > p then -- next prime number is found
            local root = p^(1/3)
            local R = root * 2^40
            R = mul({R - R % 1}, one, 1.0, 2)
            local _, delta = mul(R, mul(R, R, 1.0, 4), -1.0, 4)
            local hi = R[2] % 65536 * 65536 + floor(R[1] / 256)
            local lo = R[1] % 256 * 16777216 + floor(delta * (2^-56 / 3) * root / p)
            if idx < 16 then
               root = p^(1/2)
               R = root * 2^40
               R = mul({R - R % 1}, one, 1.0, 2)
               _, delta = mul(R, R, -1.0, 2)
               local hi = R[2] % 65536 * 65536 + floor(R[1] / 256)
               local lo = R[1] % 256 * 16777216 + floor(delta * 2^-17 / root)
               local idx = idx % 8 + 1
               sha2_H_ext256[224][idx] = lo
               sqrt_hi[idx], sqrt_lo[idx] = hi, lo + hi * hi_factor
               if idx > 7 then
                  sqrt_hi, sqrt_lo = sha2_H_ext512_hi[384], sha2_H_ext512_lo[384]
               end
            end
            idx = idx + 1
            sha2_K_hi[idx], sha2_K_lo[idx] = hi, lo % K_lo_modulo + hi * hi_factor
            break
         end
      until p % d == 0
   until idx > 79
end

-- Calculating IVs for SHA512/224 and SHA512/256
for width = 224, 256, 32 do
   local H_lo, H_hi = {}
   if HEX64 then
      for j = 1, 8 do
         H_lo[j] = XORA5(sha2_H_lo[j])
      end
   else
      H_hi = {}
      for j = 1, 8 do
         H_lo[j] = XORA5(sha2_H_lo[j])
         H_hi[j] = XORA5(sha2_H_hi[j])
      end
   end
   sha512_feed_128(H_lo, H_hi, "SHA-512/"..tostring(width).."\128"..string_rep("\0", 115).."\88", 0, 128)
   sha2_H_ext512_lo[width] = H_lo
   sha2_H_ext512_hi[width] = H_hi
end

-- Constants for MD5
do
   local sin, abs, modf = math.sin, math.abs, math.modf
   for idx = 1, 64 do
      -- we can't use formula floor(abs(sin(idx))*2^32) because its result may be beyond integer range on Lua built with 32-bit integers
      local hi, lo = modf(abs(sin(idx)) * 2^16)
      md5_K[idx] = hi * 65536 + floor(lo * 2^16)
   end
end

-- Constants for SHA-3
do
   local sh_reg = 29

   local function next_bit()
      local r = sh_reg % 2
      sh_reg = XOR_BYTE((sh_reg - r) / 2, 142 * r)
      return r
   end

   for idx = 1, 24 do
      local lo, m = 0
      for _ = 1, 6 do
         m = m and m * m * 2 or 1
         lo = lo + next_bit() * m
      end
      local hi = next_bit() * m
      sha3_RC_hi[idx], sha3_RC_lo[idx] = hi, lo + hi * hi_factor_keccak
   end
end

if branch == "FFI" then
   sha2_K_hi = ffi.new("uint32_t[?]", #sha2_K_hi + 1, 0, unpack(sha2_K_hi))
   sha2_K_lo = ffi.new("int64_t[?]",  #sha2_K_lo + 1, 0, unpack(sha2_K_lo))
   --md5_K = ffi.new("uint32_t[?]", #md5_K + 1, 0, unpack(md5_K))
   if hi_factor_keccak == 0 then
      sha3_RC_lo = ffi.new("uint32_t[?]", #sha3_RC_lo + 1, 0, unpack(sha3_RC_lo))
      sha3_RC_hi = ffi.new("uint32_t[?]", #sha3_RC_hi + 1, 0, unpack(sha3_RC_hi))
   else
      sha3_RC_lo = ffi.new("int64_t[?]", #sha3_RC_lo + 1, 0, unpack(sha3_RC_lo))
   end
end


--------------------------------------------------------------------------------
-- MAIN FUNCTIONS
--------------------------------------------------------------------------------

local function sha256ext(width, message)
   -- Create an instance (private objects for current calculation)
   local H, length, tail = {unpack(sha2_H_ext256[width])}, 0.0, ""

   local function partial(message_part)
      if message_part then
         if tail then
            length = length + #message_part
            local offs = 0
            if tail ~= "" and #tail + #message_part >= 64 then
               offs = 64 - #tail
               sha256_feed_64(H, tail..sub(message_part, 1, offs), 0, 64)
               tail = ""
            end
            local size = #message_part - offs
            local size_tail = size % 64
            sha256_feed_64(H, message_part, offs, size - size_tail)
            tail = tail..sub(message_part, #message_part + 1 - size_tail)
            return partial
         else
            error("Adding more chunks is not allowed after receiving the result", 2)
         end
      else
         if tail then
            local final_blocks = {tail, "\128", string_rep("\0", (-9 - length) % 64 + 1)}
            tail = nil
            -- Assuming user data length is shorter than (2^53)-9 bytes
            -- Anyway, it looks very unrealistic that someone would spend more than a year of calculations to process 2^53 bytes of data by using this Lua script :-)
            -- 2^53 bytes = 2^56 bits, so "bit-counter" fits in 7 bytes
            length = length * (8 / 256^7)  -- convert "byte-counter" to "bit-counter" and move decimal point to the left
            for j = 4, 10 do
               length = length % 1 * 256
               final_blocks[j] = char(floor(length))
            end
            final_blocks = table_concat(final_blocks)
            sha256_feed_64(H, final_blocks, 0, #final_blocks)
            local max_reg = width / 32
            for j = 1, max_reg do
               H[j] = HEX(H[j])
            end
            H = table_concat(H, "", 1, max_reg)
         end
         return H
      end
   end

   if message then
      -- Actually perform calculations and return the SHA256 digest of a message
      return partial(message)()
   else
      -- Return function for chunk-by-chunk loading
      -- User should feed every chunk of input data as single argument to this function and finally get SHA256 digest by invoking this function without an argument
      return partial
   end
end


local function sha512ext(width, message)
   -- Create an instance (private objects for current calculation)
   local length, tail, H_lo, H_hi = 0.0, "", {unpack(sha2_H_ext512_lo[width])}, not HEX64 and {unpack(sha2_H_ext512_hi[width])}

   local function partial(message_part)
      if message_part then
         if tail then
            length = length + #message_part
            local offs = 0
            if tail ~= "" and #tail + #message_part >= 128 then
               offs = 128 - #tail
               sha512_feed_128(H_lo, H_hi, tail..sub(message_part, 1, offs), 0, 128)
               tail = ""
            end
            local size = #message_part - offs
            local size_tail = size % 128
            sha512_feed_128(H_lo, H_hi, message_part, offs, size - size_tail)
            tail = tail..sub(message_part, #message_part + 1 - size_tail)
            return partial
         else
            error("Adding more chunks is not allowed after receiving the result", 2)
         end
      else
         if tail then
            local final_blocks = {tail, "\128", string_rep("\0", (-17-length) % 128 + 9)}
            tail = nil
            -- Assuming user data length is shorter than (2^53)-17 bytes
            -- 2^53 bytes = 2^56 bits, so "bit-counter" fits in 7 bytes
            length = length * (8 / 256^7)  -- convert "byte-counter" to "bit-counter" and move floating point to the left
            for j = 4, 10 do
               length = length % 1 * 256
               final_blocks[j] = char(floor(length))
            end
            final_blocks = table_concat(final_blocks)
            sha512_feed_128(H_lo, H_hi, final_blocks, 0, #final_blocks)
            local max_reg = ceil(width / 64)
            if HEX64 then
               for j = 1, max_reg do
                  H_lo[j] = HEX64(H_lo[j])
               end
            else
               for j = 1, max_reg do
                  H_lo[j] = HEX(H_hi[j])..HEX(H_lo[j])
               end
               H_hi = nil
            end
            H_lo = sub(table_concat(H_lo, "", 1, max_reg), 1, width / 4)
         end
         return H_lo
      end
   end

   if message then
      -- Actually perform calculations and return the SHA512 digest of a message
      return partial(message)()
   else
      -- Return function for chunk-by-chunk loading
      -- User should feed every chunk of input data as single argument to this function and finally get SHA512 digest by invoking this function without an argument
      return partial
   end
end


local function md5(message)
   -- Create an instance (private objects for current calculation)
   local H, length, tail = {unpack(md5_sha1_H, 1, 4)}, 0.0, ""

   local function partial(message_part)
      if message_part then
         if tail then
            length = length + #message_part
            local offs = 0
            if tail ~= "" and #tail + #message_part >= 64 then
               offs = 64 - #tail
               md5_feed_64(H, tail..sub(message_part, 1, offs), 0, 64)
               tail = ""
            end
            local size = #message_part - offs
            local size_tail = size % 64
            md5_feed_64(H, message_part, offs, size - size_tail)
            tail = tail..sub(message_part, #message_part + 1 - size_tail)
            return partial
         else
            error("Adding more chunks is not allowed after receiving the result", 2)
         end
      else
         if tail then
            local final_blocks = {tail, "\128", string_rep("\0", (-9 - length) % 64)}
            tail = nil
            length = length * 8  -- convert "byte-counter" to "bit-counter"
            for j = 4, 11 do
               local low_byte = length % 256
               final_blocks[j] = char(low_byte)
               length = (length - low_byte) / 256
            end
            final_blocks = table_concat(final_blocks)
            md5_feed_64(H, final_blocks, 0, #final_blocks)
            for j = 1, 4 do
               H[j] = HEX(H[j])
            end
            H = gsub(table_concat(H), "(..)(..)(..)(..)", "%4%3%2%1")
         end
         return H
      end
   end

   if message then
      -- Actually perform calculations and return the MD5 digest of a message
      return partial(message)()
   else
      -- Return function for chunk-by-chunk loading
      -- User should feed every chunk of input data as single argument to this function and finally get MD5 digest by invoking this function without an argument
      return partial
   end
end


local function sha1(message)
   -- Create an instance (private objects for current calculation)
   local H, length, tail = {unpack(md5_sha1_H)}, 0.0, ""

   local function partial(message_part)
      if message_part then
         if tail then
            length = length + #message_part
            local offs = 0
            if tail ~= "" and #tail + #message_part >= 64 then
               offs = 64 - #tail
               sha1_feed_64(H, tail..sub(message_part, 1, offs), 0, 64)
               tail = ""
            end
            local size = #message_part - offs
            local size_tail = size % 64
            sha1_feed_64(H, message_part, offs, size - size_tail)
            tail = tail..sub(message_part, #message_part + 1 - size_tail)
            return partial
         else
            error("Adding more chunks is not allowed after receiving the result", 2)
         end
      else
         if tail then
            local final_blocks = {tail, "\128", string_rep("\0", (-9 - length) % 64 + 1)}
            tail = nil
            -- Assuming user data length is shorter than (2^53)-9 bytes
            -- 2^53 bytes = 2^56 bits, so "bit-counter" fits in 7 bytes
            length = length * (8 / 256^7)  -- convert "byte-counter" to "bit-counter" and move decimal point to the left
            for j = 4, 10 do
               length = length % 1 * 256
               final_blocks[j] = char(floor(length))
            end
            final_blocks = table_concat(final_blocks)
            sha1_feed_64(H, final_blocks, 0, #final_blocks)
            for j = 1, 5 do
               H[j] = HEX(H[j])
            end
            H = table_concat(H)
         end
         return H
      end
   end

   if message then
      -- Actually perform calculations and return the SHA-1 digest of a message
      return partial(message)()
   else
      -- Return function for chunk-by-chunk loading
      -- User should feed every chunk of input data as single argument to this function and finally get SHA-1 digest by invoking this function without an argument
      return partial
   end
end


local function keccak(block_size_in_bytes, digest_size_in_bytes, is_SHAKE, message)
   -- "block_size_in_bytes" is multiple of 8
   if type(digest_size_in_bytes) ~= "number" then
      -- arguments in SHAKE are swapped:
      --    NIST FIPS 202 defines SHAKE(message,num_bits)
      --    this module   defines SHAKE(num_bytes,message)
      -- it's easy to forget about this swap, hence the check
      error("Argument 'digest_size_in_bytes' must be a number", 2)
   end
   -- Create an instance (private objects for current calculation)
   local tail, lanes_lo, lanes_hi = "", create_array_of_lanes(), hi_factor_keccak == 0 and create_array_of_lanes()
   local result

   local function partial(message_part)
      if message_part then
         if tail then
            local offs = 0
            if tail ~= "" and #tail + #message_part >= block_size_in_bytes then
               offs = block_size_in_bytes - #tail
               keccak_feed(lanes_lo, lanes_hi, tail..sub(message_part, 1, offs), 0, block_size_in_bytes, block_size_in_bytes)
               tail = ""
            end
            local size = #message_part - offs
            local size_tail = size % block_size_in_bytes
            keccak_feed(lanes_lo, lanes_hi, message_part, offs, size - size_tail, block_size_in_bytes)
            tail = tail..sub(message_part, #message_part + 1 - size_tail)
            return partial
         else
            error("Adding more chunks is not allowed after receiving the result", 2)
         end
      else
         if tail then
            -- append the following bits to the message: for usual SHA-3: 011(0*)1, for SHAKE: 11111(0*)1
            local gap_start = is_SHAKE and 31 or 6
            tail = tail..(#tail + 1 == block_size_in_bytes and char(gap_start + 128) or char(gap_start)..string_rep("\0", (-2 - #tail) % block_size_in_bytes).."\128")
            keccak_feed(lanes_lo, lanes_hi, tail, 0, #tail, block_size_in_bytes)
            tail = nil
            local lanes_used = 0
            local total_lanes = floor(block_size_in_bytes / 8)
            local qwords = {}

            local function get_next_qwords_of_digest(qwords_qty)
               -- returns not more than 'qwords_qty' qwords ('qwords_qty' might be non-integer)
               -- doesn't go across keccak-buffer boundary
               -- block_size_in_bytes is a multiple of 8, so, keccak-buffer contains integer number of qwords
               if lanes_used >= total_lanes then
                  keccak_feed(lanes_lo, lanes_hi, "\0\0\0\0\0\0\0\0", 0, 8, 8)
                  lanes_used = 0
               end
               qwords_qty = floor(math_min(qwords_qty, total_lanes - lanes_used))
               if hi_factor_keccak ~= 0 then
                  for j = 1, qwords_qty do
                     qwords[j] = HEX64(lanes_lo[lanes_used + j - 1 + lanes_index_base])
                  end
               else
                  for j = 1, qwords_qty do
                     qwords[j] = HEX(lanes_hi[lanes_used + j])..HEX(lanes_lo[lanes_used + j])
                  end
               end
               lanes_used = lanes_used + qwords_qty
               return
                  gsub(table_concat(qwords, "", 1, qwords_qty), "(..)(..)(..)(..)(..)(..)(..)(..)", "%8%7%6%5%4%3%2%1"),
                  qwords_qty * 8
            end

            local parts = {}      -- digest parts
            local last_part, last_part_size = "", 0

            local function get_next_part_of_digest(bytes_needed)
               -- returns 'bytes_needed' bytes, for arbitrary integer 'bytes_needed'
               bytes_needed = bytes_needed or 1
               if bytes_needed <= last_part_size then
                  last_part_size = last_part_size - bytes_needed
                  local part_size_in_nibbles = bytes_needed * 2
                  local result = sub(last_part, 1, part_size_in_nibbles)
                  last_part = sub(last_part, part_size_in_nibbles + 1)
                  return result
               end
               local parts_qty = 0
               if last_part_size > 0 then
                  parts_qty = 1
                  parts[parts_qty] = last_part
                  bytes_needed = bytes_needed - last_part_size
               end
               -- repeats until the length is enough
               while bytes_needed >= 8 do
                  local next_part, next_part_size = get_next_qwords_of_digest(bytes_needed / 8)
                  parts_qty = parts_qty + 1
                  parts[parts_qty] = next_part
                  bytes_needed = bytes_needed - next_part_size
               end
               if bytes_needed > 0 then
                  last_part, last_part_size = get_next_qwords_of_digest(1)
                  parts_qty = parts_qty + 1
                  parts[parts_qty] = get_next_part_of_digest(bytes_needed)
               else
                  last_part, last_part_size = "", 0
               end
               return table_concat(parts, "", 1, parts_qty)
            end

            if digest_size_in_bytes < 0 then
               result = get_next_part_of_digest
            else
               result = get_next_part_of_digest(digest_size_in_bytes)
            end
         end
         return result
      end
   end

   if message then
      -- Actually perform calculations and return the SHA-3 digest of a message
      return partial(message)()
   else
      -- Return function for chunk-by-chunk loading
      -- User should feed every chunk of input data as single argument to this function and finally get SHA-3 digest by invoking this function without an argument
      return partial
   end
end


local hex_to_bin, bin_to_hex, bin_to_base64, base64_to_bin
do
   function hex_to_bin(hex_string)
      return (gsub(hex_string, "%x%x",
         function (hh)
            return char(tonumber(hh, 16))
         end
      ))
   end

   function bin_to_hex(binary_string)
      return (gsub(binary_string, ".",
         function (c)
            return string_format("%02x", byte(c))
         end
      ))
   end

   local base64_symbols = {
      ['+'] = 62, ['-'] = 62,  [62] = '+',
      ['/'] = 63, ['_'] = 63,  [63] = '/',
      ['='] = -1, ['.'] = -1,  [-1] = '='
   }
   local symbol_index = 0
   for j, pair in ipairs{'AZ', 'az', '09'} do
      for ascii = byte(pair), byte(pair, 2) do
         local ch = char(ascii)
         base64_symbols[ch] = symbol_index
         base64_symbols[symbol_index] = ch
         symbol_index = symbol_index + 1
      end
   end

   function bin_to_base64(binary_string)
      local result = {}
      for pos = 1, #binary_string, 3 do
         local c1, c2, c3, c4 = byte(sub(binary_string, pos, pos + 2)..'\0', 1, -1)
         result[#result + 1] =
            base64_symbols[floor(c1 / 4)]
            ..base64_symbols[c1 % 4 * 16 + floor(c2 / 16)]
            ..base64_symbols[c3 and c2 % 16 * 4 + floor(c3 / 64) or -1]
            ..base64_symbols[c4 and c3 % 64 or -1]
      end
      return table_concat(result)
   end

   function base64_to_bin(base64_string)
      local result, chars_qty = {}, 3
      for pos, ch in gmatch(gsub(base64_string, '%s+', ''), '()(.)') do
         local code = base64_symbols[ch]
         if code < 0 then
            chars_qty = chars_qty - 1
            code = 0
         end
         local idx = pos % 4
         if idx > 0 then
            result[-idx] = code
         else
            local c1 = result[-1] * 4 + floor(result[-2] / 16)
            local c2 = (result[-2] % 16) * 16 + floor(result[-3] / 4)
            local c3 = (result[-3] % 4) * 64 + code
            result[#result + 1] = sub(char(c1, c2, c3), 1, chars_qty)
         end
      end
      return table_concat(result)
   end

end


local block_size_for_HMAC  -- this table will be initialized at the end of the module

local function pad_and_xor(str, result_length, byte_for_xor)
   return gsub(str, ".",
      function(c)
         return char(XOR_BYTE(byte(c), byte_for_xor))
      end
   )..string_rep(char(byte_for_xor), result_length - #str)
end

local function hmac(hash_func, key, message)
   -- Create an instance (private objects for current calculation)
   local block_size = block_size_for_HMAC[hash_func]
   if not block_size then
      error("Unknown hash function", 2)
   end
   if #key > block_size then
      key = hex_to_bin(hash_func(key))
   end
   local append = hash_func()(pad_and_xor(key, block_size, 0x36))
   local result

   local function partial(message_part)
      if not message_part then
         result = result or hash_func(pad_and_xor(key, block_size, 0x5C)..hex_to_bin(append()))
         return result
      elseif result then
         error("Adding more chunks is not allowed after receiving the result", 2)
      else
         append(message_part)
         return partial
      end
   end

   if message then
      -- Actually perform calculations and return the HMAC of a message
      return partial(message)()
   else
      -- Return function for chunk-by-chunk loading of a message
      -- User should feed every chunk of the message as single argument to this function and finally get HMAC by invoking this function without an argument
      return partial
   end
end


local function xor_blake2_salt(salt, letter, H_lo, H_hi)
   -- salt: concatenation of "Salt"+"Personalization" fields
   local max_size = letter == "s" and 16 or 32
   local salt_size = #salt
   if salt_size > max_size then
      error(string_format("For BLAKE2%s/BLAKE2%sp/BLAKE2X%s the 'salt' parameter length must not exceed %d bytes", letter, letter, letter, max_size), 2)
   end
   if H_lo then
      local offset, blake2_word_size, xor = 0, letter == "s" and 4 or 8, letter == "s" and XOR or XORA5
      for j = 5, 4 + ceil(salt_size / blake2_word_size) do
         local prev, last
         for _ = 1, blake2_word_size, 4 do
            offset = offset + 4
            local a, b, c, d = byte(salt, offset - 3, offset)
            local four_bytes = (((d or 0) * 256 + (c or 0)) * 256 + (b or 0)) * 256 + (a or 0)
            prev, last = last, four_bytes
         end
         H_lo[j] = xor(H_lo[j], prev and last * hi_factor + prev or last)
         if H_hi then
            H_hi[j] = xor(H_hi[j], last)
         end
      end
   end
end

local function blake2s(message, key, salt, digest_size_in_bytes, XOF_length, B2_offset)
   -- message:  binary string to be hashed (or nil for "chunk-by-chunk" input mode)
   -- key:      (optional) binary string up to 32 bytes, by default empty string
   -- salt:     (optional) binary string up to 16 bytes, by default empty string
   -- digest_size_in_bytes: (optional) integer from 1 to 32, by default 32
   -- The last two parameters "XOF_length" and "B2_offset" are for internal use only, user must omit them (or pass nil)
   digest_size_in_bytes = digest_size_in_bytes or 32
   if digest_size_in_bytes < 1 or digest_size_in_bytes > 32 then
      error("BLAKE2s digest length must be from 1 to 32 bytes", 2)
   end
   key = key or ""
   local key_length = #key
   if key_length > 32 then
      error("BLAKE2s key length must not exceed 32 bytes", 2)
   end
   salt = salt or ""
   local bytes_compressed, tail, H = 0.0, "", {unpack(sha2_H_hi)}
   if B2_offset then
      H[1] = XOR(H[1], digest_size_in_bytes)
      H[2] = XOR(H[2], 0x20)
      H[3] = XOR(H[3], B2_offset)
      H[4] = XOR(H[4], 0x20000000 + XOF_length)
   else
      H[1] = XOR(H[1], 0x01010000 + key_length * 256 + digest_size_in_bytes)
      if XOF_length then
         H[4] = XOR(H[4], XOF_length)
      end
   end
   if salt ~= "" then
      xor_blake2_salt(salt, "s", H)
   end

   local function partial(message_part)
      if message_part then
         if tail then
            local offs = 0
            if tail ~= "" and #tail + #message_part > 64 then
               offs = 64 - #tail
               bytes_compressed = blake2s_feed_64(H, tail..sub(message_part, 1, offs), 0, 64, bytes_compressed)
               tail = ""
            end
            local size = #message_part - offs
            local size_tail = size > 0 and (size - 1) % 64 + 1 or 0
            bytes_compressed = blake2s_feed_64(H, message_part, offs, size - size_tail, bytes_compressed)
            tail = tail..sub(message_part, #message_part + 1 - size_tail)
            return partial
         else
            error("Adding more chunks is not allowed after receiving the result", 2)
         end
      else
         if tail then
            if B2_offset then
               blake2s_feed_64(H, nil, 0, 64, 0, 32)
            else
               blake2s_feed_64(H, tail..string_rep("\0", 64 - #tail), 0, 64, bytes_compressed, #tail)
            end
            tail = nil
            if not XOF_length or B2_offset then
               local max_reg = ceil(digest_size_in_bytes / 4)
               for j = 1, max_reg do
                  H[j] = HEX(H[j])
               end
               H = sub(gsub(table_concat(H, "", 1, max_reg), "(..)(..)(..)(..)", "%4%3%2%1"), 1, digest_size_in_bytes * 2)
            end
         end
         return H
      end
   end

   if key_length > 0 then
      partial(key..string_rep("\0", 64 - key_length))
   end
   if B2_offset then
      return partial()
   elseif message then
      -- Actually perform calculations and return the BLAKE2s digest of a message
      return partial(message)()
   else
      -- Return function for chunk-by-chunk loading
      -- User should feed every chunk of input data as single argument to this function and finally get BLAKE2s digest by invoking this function without an argument
      return partial
   end
end

local function blake2b(message, key, salt, digest_size_in_bytes, XOF_length, B2_offset)
   -- message:  binary string to be hashed (or nil for "chunk-by-chunk" input mode)
   -- key:      (optional) binary string up to 64 bytes, by default empty string
   -- salt:     (optional) binary string up to 32 bytes, by default empty string
   -- digest_size_in_bytes: (optional) integer from 1 to 64, by default 64
   -- The last two parameters "XOF_length" and "B2_offset" are for internal use only, user must omit them (or pass nil)
   digest_size_in_bytes = floor(digest_size_in_bytes or 64)
   if digest_size_in_bytes < 1 or digest_size_in_bytes > 64 then
      error("BLAKE2b digest length must be from 1 to 64 bytes", 2)
   end
   key = key or ""
   local key_length = #key
   if key_length > 64 then
      error("BLAKE2b key length must not exceed 64 bytes", 2)
   end
   salt = salt or ""
   local bytes_compressed, tail, H_lo, H_hi = 0.0, "", {unpack(sha2_H_lo)}, not HEX64 and {unpack(sha2_H_hi)}
   if B2_offset then
      if H_hi then
         H_lo[1] = XORA5(H_lo[1], digest_size_in_bytes)
         H_hi[1] = XORA5(H_hi[1], 0x40)
         H_lo[2] = XORA5(H_lo[2], B2_offset)
         H_hi[2] = XORA5(H_hi[2], XOF_length)
      else
         H_lo[1] = XORA5(H_lo[1], 0x40 * hi_factor + digest_size_in_bytes)
         H_lo[2] = XORA5(H_lo[2], XOF_length * hi_factor + B2_offset)
      end
      H_lo[3] = XORA5(H_lo[3], 0x4000)
   else
      H_lo[1] = XORA5(H_lo[1], 0x01010000 + key_length * 256 + digest_size_in_bytes)
      if XOF_length then
         if H_hi then
            H_hi[2] = XORA5(H_hi[2], XOF_length)
         else
            H_lo[2] = XORA5(H_lo[2], XOF_length * hi_factor)
         end
      end
   end
   if salt ~= "" then
      xor_blake2_salt(salt, "b", H_lo, H_hi)
   end

   local function partial(message_part)
      if message_part then
         if tail then
            local offs = 0
            if tail ~= "" and #tail + #message_part > 128 then
               offs = 128 - #tail
               bytes_compressed = blake2b_feed_128(H_lo, H_hi, tail..sub(message_part, 1, offs), 0, 128, bytes_compressed)
               tail = ""
            end
            local size = #message_part - offs
            local size_tail = size > 0 and (size - 1) % 128 + 1 or 0
            bytes_compressed = blake2b_feed_128(H_lo, H_hi, message_part, offs, size - size_tail, bytes_compressed)
            tail = tail..sub(message_part, #message_part + 1 - size_tail)
            return partial
         else
            error("Adding more chunks is not allowed after receiving the result", 2)
         end
      else
         if tail then
            if B2_offset then
               blake2b_feed_128(H_lo, H_hi, nil, 0, 128, 0, 64)
            else
               blake2b_feed_128(H_lo, H_hi, tail..string_rep("\0", 128 - #tail), 0, 128, bytes_compressed, #tail)
            end
            tail = nil
            if XOF_length and not B2_offset then
               if H_hi then
                  for j = 8, 1, -1 do
                     H_lo[j*2] = H_hi[j]
                     H_lo[j*2-1] = H_lo[j]
                  end
                  return H_lo, 16
               end
            else
               local max_reg = ceil(digest_size_in_bytes / 8)
               if H_hi then
                  for j = 1, max_reg do
                     H_lo[j] = HEX(H_hi[j])..HEX(H_lo[j])
                  end
               else
                  for j = 1, max_reg do
                     H_lo[j] = HEX64(H_lo[j])
                  end
               end
               H_lo = sub(gsub(table_concat(H_lo, "", 1, max_reg), "(..)(..)(..)(..)(..)(..)(..)(..)", "%8%7%6%5%4%3%2%1"), 1, digest_size_in_bytes * 2)
            end
            H_hi = nil
         end
         return H_lo
      end
   end

   if key_length > 0 then
      partial(key..string_rep("\0", 128 - key_length))
   end
   if B2_offset then
      return partial()
   elseif message then
      -- Actually perform calculations and return the BLAKE2b digest of a message
      return partial(message)()
   else
      -- Return function for chunk-by-chunk loading
      -- User should feed every chunk of input data as single argument to this function and finally get BLAKE2b digest by invoking this function without an argument
      return partial
   end
end

local function blake2sp(message, key, salt, digest_size_in_bytes)
   -- message:  binary string to be hashed (or nil for "chunk-by-chunk" input mode)
   -- key:      (optional) binary string up to 32 bytes, by default empty string
   -- salt:     (optional) binary string up to 16 bytes, by default empty string
   -- digest_size_in_bytes: (optional) integer from 1 to 32, by default 32
   digest_size_in_bytes = digest_size_in_bytes or 32
   if digest_size_in_bytes < 1 or digest_size_in_bytes > 32 then
      error("BLAKE2sp digest length must be from 1 to 32 bytes", 2)
   end
   key = key or ""
   local key_length = #key
   if key_length > 32 then
      error("BLAKE2sp key length must not exceed 32 bytes", 2)
   end
   salt = salt or ""
   local instances, length, first_dword_of_parameter_block, result = {}, 0.0, 0x02080000 + key_length * 256 + digest_size_in_bytes
   for j = 1, 8 do
      local bytes_compressed, tail, H = 0.0, "", {unpack(sha2_H_hi)}
      instances[j] = {bytes_compressed, tail, H}
      H[1] = XOR(H[1], first_dword_of_parameter_block)
      H[3] = XOR(H[3], j-1)
      H[4] = XOR(H[4], 0x20000000)
      if salt ~= "" then
         xor_blake2_salt(salt, "s", H)
      end
   end

   local function partial(message_part)
      if message_part then
         if instances then
            local from = 0
            while true do
               local to = math_min(from + 64 - length % 64, #message_part)
               if to > from then
                  local inst = instances[floor(length / 64) % 8 + 1]
                  local part = sub(message_part, from + 1, to)
                  length, from = length + to - from, to
                  local bytes_compressed, tail = inst[1], inst[2]
                  if #tail < 64 then
                     tail = tail..part
                  else
                     local H = inst[3]
                     bytes_compressed = blake2s_feed_64(H, tail, 0, 64, bytes_compressed)
                     tail = part
                  end
                  inst[1], inst[2] = bytes_compressed, tail
               else
                  break
               end
            end
            return partial
         else
            error("Adding more chunks is not allowed after receiving the result", 2)
         end
      else
         if instances then
            local root_H = {unpack(sha2_H_hi)}
            root_H[1] = XOR(root_H[1], first_dword_of_parameter_block)
            root_H[4] = XOR(root_H[4], 0x20010000)
            if salt ~= "" then
               xor_blake2_salt(salt, "s", root_H)
            end
            for j = 1, 8 do
               local inst = instances[j]
               local bytes_compressed, tail, H = inst[1], inst[2], inst[3]
               blake2s_feed_64(H, tail..string_rep("\0", 64 - #tail), 0, 64, bytes_compressed, #tail, j == 8)
               if j % 2 == 0 then
                  local index = 0
                  for k = j - 1, j do
                     local inst = instances[k]
                     local H = inst[3]
                     for i = 1, 8 do
                        index = index + 1
                        common_W_blake2s[index] = H[i]
                     end
                  end
                  blake2s_feed_64(root_H, nil, 0, 64, 64 * (j/2 - 1), j == 8 and 64, j == 8)
               end
            end
            instances = nil
            local max_reg = ceil(digest_size_in_bytes / 4)
            for j = 1, max_reg do
               root_H[j] = HEX(root_H[j])
            end
            result = sub(gsub(table_concat(root_H, "", 1, max_reg), "(..)(..)(..)(..)", "%4%3%2%1"), 1, digest_size_in_bytes * 2)
         end
         return result
      end
   end

   if key_length > 0 then
      key = key..string_rep("\0", 64 - key_length)
      for j = 1, 8 do
         partial(key)
      end
   end
   if message then
      -- Actually perform calculations and return the BLAKE2sp digest of a message
      return partial(message)()
   else
      -- Return function for chunk-by-chunk loading
      -- User should feed every chunk of input data as single argument to this function and finally get BLAKE2sp digest by invoking this function without an argument
      return partial
   end

end

local function blake2bp(message, key, salt, digest_size_in_bytes)
   -- message:  binary string to be hashed (or nil for "chunk-by-chunk" input mode)
   -- key:      (optional) binary string up to 64 bytes, by default empty string
   -- salt:     (optional) binary string up to 32 bytes, by default empty string
   -- digest_size_in_bytes: (optional) integer from 1 to 64, by default 64
   digest_size_in_bytes = digest_size_in_bytes or 64
   if digest_size_in_bytes < 1 or digest_size_in_bytes > 64 then
      error("BLAKE2bp digest length must be from 1 to 64 bytes", 2)
   end
   key = key or ""
   local key_length = #key
   if key_length > 64 then
      error("BLAKE2bp key length must not exceed 64 bytes", 2)
   end
   salt = salt or ""
   local instances, length, first_dword_of_parameter_block, result = {}, 0.0, 0x02040000 + key_length * 256 + digest_size_in_bytes
   for j = 1, 4 do
      local bytes_compressed, tail, H_lo, H_hi = 0.0, "", {unpack(sha2_H_lo)}, not HEX64 and {unpack(sha2_H_hi)}
      instances[j] = {bytes_compressed, tail, H_lo, H_hi}
      H_lo[1] = XORA5(H_lo[1], first_dword_of_parameter_block)
      H_lo[2] = XORA5(H_lo[2], j-1)
      H_lo[3] = XORA5(H_lo[3], 0x4000)
      if salt ~= "" then
         xor_blake2_salt(salt, "b", H_lo, H_hi)
      end
   end

   local function partial(message_part)
      if message_part then
         if instances then
            local from = 0
            while true do
               local to = math_min(from + 128 - length % 128, #message_part)
               if to > from then
                  local inst = instances[floor(length / 128) % 4 + 1]
                  local part = sub(message_part, from + 1, to)
                  length, from = length + to - from, to
                  local bytes_compressed, tail = inst[1], inst[2]
                  if #tail < 128 then
                     tail = tail..part
                  else
                     local H_lo, H_hi = inst[3], inst[4]
                     bytes_compressed = blake2b_feed_128(H_lo, H_hi, tail, 0, 128, bytes_compressed)
                     tail = part
                  end
                  inst[1], inst[2] = bytes_compressed, tail
               else
                  break
               end
            end
            return partial
         else
            error("Adding more chunks is not allowed after receiving the result", 2)
         end
      else
         if instances then
            local root_H_lo, root_H_hi = {unpack(sha2_H_lo)}, not HEX64 and {unpack(sha2_H_hi)}
            root_H_lo[1] = XORA5(root_H_lo[1], first_dword_of_parameter_block)
            root_H_lo[3] = XORA5(root_H_lo[3], 0x4001)
            if salt ~= "" then
               xor_blake2_salt(salt, "b", root_H_lo, root_H_hi)
            end
            for j = 1, 4 do
               local inst = instances[j]
               local bytes_compressed, tail, H_lo, H_hi = inst[1], inst[2], inst[3], inst[4]
               blake2b_feed_128(H_lo, H_hi, tail..string_rep("\0", 128 - #tail), 0, 128, bytes_compressed, #tail, j == 4)
               if j % 2 == 0 then
                  local index = 0
                  for k = j - 1, j do
                     local inst = instances[k]
                     local H_lo, H_hi = inst[3], inst[4]
                     for i = 1, 8 do
                        index = index + 1
                        common_W_blake2b[index] = H_lo[i]
                        if H_hi then
                           index = index + 1
                           common_W_blake2b[index] = H_hi[i]
                        end
                     end
                  end
                  blake2b_feed_128(root_H_lo, root_H_hi, nil, 0, 128, 128 * (j/2 - 1), j == 4 and 128, j == 4)
               end
            end
            instances = nil
            local max_reg = ceil(digest_size_in_bytes / 8)
            if HEX64 then
               for j = 1, max_reg do
                  root_H_lo[j] = HEX64(root_H_lo[j])
               end
            else
               for j = 1, max_reg do
                  root_H_lo[j] = HEX(root_H_hi[j])..HEX(root_H_lo[j])
               end
            end
            result = sub(gsub(table_concat(root_H_lo, "", 1, max_reg), "(..)(..)(..)(..)(..)(..)(..)(..)", "%8%7%6%5%4%3%2%1"), 1, digest_size_in_bytes * 2)
         end
         return result
      end
   end

   if key_length > 0 then
      key = key..string_rep("\0", 128 - key_length)
      for j = 1, 4 do
         partial(key)
      end
   end
   if message then
      -- Actually perform calculations and return the BLAKE2bp digest of a message
      return partial(message)()
   else
      -- Return function for chunk-by-chunk loading
      -- User should feed every chunk of input data as single argument to this function and finally get BLAKE2bp digest by invoking this function without an argument
      return partial
   end

end

local function blake2x(inner_func, inner_func_letter, common_W_blake2, block_size, digest_size_in_bytes, message, key, salt)
   local XOF_digest_length_limit, XOF_digest_length, chunk_by_chunk_output = 2^(block_size / 2) - 1
   if digest_size_in_bytes == -1 then  -- infinite digest
      digest_size_in_bytes = math_huge
      XOF_digest_length = floor(XOF_digest_length_limit)
      chunk_by_chunk_output = true
   else
      if digest_size_in_bytes < 0 then
         digest_size_in_bytes = -1.0 * digest_size_in_bytes
         chunk_by_chunk_output = true
      end
      XOF_digest_length = floor(digest_size_in_bytes)
      if XOF_digest_length >= XOF_digest_length_limit then
         error("Requested digest is too long.  BLAKE2X"..inner_func_letter.." finite digest is limited by (2^"..floor(block_size / 2)..")-2 bytes.  Hint: you can generate infinite digest.", 2)
      end
   end
   salt = salt or ""
   if salt ~= "" then
      xor_blake2_salt(salt, inner_func_letter)  -- don't xor, only check the size of salt
   end
   local inner_partial = inner_func(nil, key, salt, nil, XOF_digest_length)
   local result

   local function partial(message_part)
      if message_part then
         if inner_partial then
            inner_partial(message_part)
            return partial
         else
            error("Adding more chunks is not allowed after receiving the result", 2)
         end
      else
         if inner_partial then
            local half_W, half_W_size = inner_partial()
            half_W_size, inner_partial = half_W_size or 8

            local function get_hash_block(block_no)
               -- block_no = 0...(2^32-1)
               local size = math_min(block_size, digest_size_in_bytes - block_no * block_size)
               if size <= 0 then
                  return ""
               end
               for j = 1, half_W_size do
                  common_W_blake2[j] = half_W[j]
               end
               for j = half_W_size + 1, 2 * half_W_size do
                  common_W_blake2[j] = 0
               end
               return inner_func(nil, nil, salt, size, XOF_digest_length, floor(block_no))
            end

            local hash = {}
            if chunk_by_chunk_output then
               local pos, period, cached_block_no, cached_block = 0, block_size * 2^32

               local function get_next_part_of_digest(arg1, arg2)
                  if arg1 == "seek" then
                     -- Usage #1:  get_next_part_of_digest("seek", new_pos)
                     pos = arg2 % period
                  else
                     -- Usage #2:  hex_string = get_next_part_of_digest(size)
                     local size, index = arg1 or 1, 0
                     while size > 0 do
                        local block_offset = pos % block_size
                        local block_no = (pos - block_offset) / block_size
                        local part_size = math_min(size, block_size - block_offset)
                        if cached_block_no ~= block_no then
                           cached_block_no = block_no
                           cached_block = get_hash_block(block_no)
                        end
                        index = index + 1
                        hash[index] = sub(cached_block, block_offset * 2 + 1, (block_offset + part_size) * 2)
                        size = size - part_size
                        pos = (pos + part_size) % period
                     end
                     return table_concat(hash, "", 1, index)
                  end
               end

               result = get_next_part_of_digest
            else
               for j = 1.0, ceil(digest_size_in_bytes / block_size) do
                  hash[j] = get_hash_block(j - 1.0)
               end
               result = table_concat(hash)
            end
         end
         return result
      end
   end

   if message then
      -- Actually perform calculations and return the BLAKE2X digest of a message
      return partial(message)()
   else
      -- Return function for chunk-by-chunk loading
      -- User should feed every chunk of input data as single argument to this function and finally get BLAKE2X digest by invoking this function without an argument
      return partial
   end
end

local function blake2xs(digest_size_in_bytes, message, key, salt)
   -- digest_size_in_bytes:
   --    0..65534       = get finite digest as single Lua string
   --    (-1)           = get infinite digest in "chunk-by-chunk" output mode
   --    (-2)..(-65534) = get finite digest in "chunk-by-chunk" output mode
   -- message:  binary string to be hashed (or nil for "chunk-by-chunk" input mode)
   -- key:      (optional) binary string up to 32 bytes, by default empty string
   -- salt:     (optional) binary string up to 16 bytes, by default empty string
   return blake2x(blake2s, "s", common_W_blake2s, 32, digest_size_in_bytes, message, key, salt)
end

local function blake2xb(digest_size_in_bytes, message, key, salt)
   -- digest_size_in_bytes:
   --    0..4294967294       = get finite digest as single Lua string
   --    (-1)                = get infinite digest in "chunk-by-chunk" output mode
   --    (-2)..(-4294967294) = get finite digest in "chunk-by-chunk" output mode
   -- message:  binary string to be hashed (or nil for "chunk-by-chunk" input mode)
   -- key:      (optional) binary string up to 64 bytes, by default empty string
   -- salt:     (optional) binary string up to 32 bytes, by default empty string
   return blake2x(blake2b, "b", common_W_blake2b, 64, digest_size_in_bytes, message, key, salt)
end


local function blake3(message, key, digest_size_in_bytes, message_flags, K, return_array)
   -- message:  binary string to be hashed (or nil for "chunk-by-chunk" input mode)
   -- key:      (optional) binary string up to 32 bytes, by default empty string
   -- digest_size_in_bytes: (optional) by default 32
   --    0,1,2,3,4,...  = get finite digest as single Lua string
   --    (-1)           = get infinite digest in "chunk-by-chunk" output mode
   --    -2,-3,-4,...   = get finite digest in "chunk-by-chunk" output mode
   -- The last three parameters "message_flags", "K" and "return_array" are for internal use only, user must omit them (or pass nil)
   key = key or ""
   digest_size_in_bytes = digest_size_in_bytes or 32
   message_flags = message_flags or 0
   if key == "" then
      K = K or sha2_H_hi
   else
      local key_length = #key
      if key_length > 32 then
         error("BLAKE3 key length must not exceed 32 bytes", 2)
      end
      key = key..string_rep("\0", 32 - key_length)
      K = {}
      for j = 1, 8 do
         local a, b, c, d = byte(key, 4*j-3, 4*j)
         K[j] = ((d * 256 + c) * 256 + b) * 256 + a
      end
      message_flags = message_flags + 16  -- flag:KEYED_HASH
   end
   local tail, H, chunk_index, blocks_in_chunk, stack_size, stack = "", {}, 0, 0, 0, {}
   local final_H_in, final_block_length, chunk_by_chunk_output, result, wide_output = K
   local final_compression_flags = 3      -- flags:CHUNK_START,CHUNK_END

   local function feed_blocks(str, offs, size)
      -- size >= 0, size is multiple of 64
      while size > 0 do
         local part_size_in_blocks, block_flags, H_in = 1, 0, H
         if blocks_in_chunk == 0 then
            block_flags = 1               -- flag:CHUNK_START
            H_in, final_H_in = K, H
            final_compression_flags = 2   -- flag:CHUNK_END
         elseif blocks_in_chunk == 15 then
            block_flags = 2               -- flag:CHUNK_END
            final_compression_flags = 3   -- flags:CHUNK_START,CHUNK_END
            final_H_in = K
         else
            part_size_in_blocks = math_min(size / 64, 15 - blocks_in_chunk)
         end
         local part_size = part_size_in_blocks * 64
         blake3_feed_64(str, offs, part_size, message_flags + block_flags, chunk_index, H_in, H)
         offs, size = offs + part_size, size - part_size
         blocks_in_chunk = (blocks_in_chunk + part_size_in_blocks) % 16
         if blocks_in_chunk == 0 then
            -- completing the currect chunk
            chunk_index = chunk_index + 1.0
            local divider = 2.0
            while chunk_index % divider == 0 do
               divider = divider * 2.0
               stack_size = stack_size - 8
               for j = 1, 8 do
                  common_W_blake2s[j] = stack[stack_size + j]
               end
               for j = 1, 8 do
                  common_W_blake2s[j + 8] = H[j]
               end
               blake3_feed_64(nil, 0, 64, message_flags + 4, 0, K, H)  -- flag:PARENT
            end
            for j = 1, 8 do
               stack[stack_size + j] = H[j]
            end
            stack_size = stack_size + 8
         end
      end
   end

   local function get_hash_block(block_no)
      local size = math_min(64, digest_size_in_bytes - block_no * 64)
      if block_no < 0 or size <= 0 then
         return ""
      end
      if chunk_by_chunk_output then
         for j = 1, 16 do
            common_W_blake2s[j] = stack[j + 16]
         end
      end
      blake3_feed_64(nil, 0, 64, final_compression_flags, block_no, final_H_in, stack, wide_output, final_block_length)
      if return_array then
         return stack
      end
      local max_reg = ceil(size / 4)
      for j = 1, max_reg do
         stack[j] = HEX(stack[j])
      end
      return sub(gsub(table_concat(stack, "", 1, max_reg), "(..)(..)(..)(..)", "%4%3%2%1"), 1, size * 2)
   end

   local function partial(message_part)
      if message_part then
         if tail then
            local offs = 0
            if tail ~= "" and #tail + #message_part > 64 then
               offs = 64 - #tail
               feed_blocks(tail..sub(message_part, 1, offs), 0, 64)
               tail = ""
            end
            local size = #message_part - offs
            local size_tail = size > 0 and (size - 1) % 64 + 1 or 0
            feed_blocks(message_part, offs, size - size_tail)
            tail = tail..sub(message_part, #message_part + 1 - size_tail)
            return partial
         else
            error("Adding more chunks is not allowed after receiving the result", 2)
         end
      else
         if tail then
            final_block_length = #tail
            tail = tail..string_rep("\0", 64 - #tail)
            if common_W_blake2s[0] then
               for j = 1, 16 do
                  local a, b, c, d = byte(tail, 4*j-3, 4*j)
                  common_W_blake2s[j] = OR(SHL(d, 24), SHL(c, 16), SHL(b, 8), a)
               end
            else
               for j = 1, 16 do
                  local a, b, c, d = byte(tail, 4*j-3, 4*j)
                  common_W_blake2s[j] = ((d * 256 + c) * 256 + b) * 256 + a
               end
            end
            tail = nil
            for stack_size = stack_size - 8, 0, -8 do
               blake3_feed_64(nil, 0, 64, message_flags + final_compression_flags, chunk_index, final_H_in, H, nil, final_block_length)
               chunk_index, final_block_length, final_H_in, final_compression_flags = 0, 64, K, 4  -- flag:PARENT
               for j = 1, 8 do
                  common_W_blake2s[j] = stack[stack_size + j]
               end
               for j = 1, 8 do
                  common_W_blake2s[j + 8] = H[j]
               end
            end
            final_compression_flags = message_flags + final_compression_flags + 8  -- flag:ROOT
            if digest_size_in_bytes < 0 then
               if digest_size_in_bytes == -1 then  -- infinite digest
                  digest_size_in_bytes = math_huge
               else
                  digest_size_in_bytes = -1.0 * digest_size_in_bytes
               end
               chunk_by_chunk_output = true
               for j = 1, 16 do
                  stack[j + 16] = common_W_blake2s[j]
               end
            end
            digest_size_in_bytes = math_min(2^53, digest_size_in_bytes)
            wide_output = digest_size_in_bytes > 32
            if chunk_by_chunk_output then
               local pos, cached_block_no, cached_block = 0.0

               local function get_next_part_of_digest(arg1, arg2)
                  if arg1 == "seek" then
                     -- Usage #1:  get_next_part_of_digest("seek", new_pos)
                     pos = arg2 * 1.0
                  else
                     -- Usage #2:  hex_string = get_next_part_of_digest(size)
                     local size, index = arg1 or 1, 32
                     while size > 0 do
                        local block_offset = pos % 64
                        local block_no = (pos - block_offset) / 64
                        local part_size = math_min(size, 64 - block_offset)
                        if cached_block_no ~= block_no then
                           cached_block_no = block_no
                           cached_block = get_hash_block(block_no)
                        end
                        index = index + 1
                        stack[index] = sub(cached_block, block_offset * 2 + 1, (block_offset + part_size) * 2)
                        size = size - part_size
                        pos = pos + part_size
                     end
                     return table_concat(stack, "", 33, index)
                  end
               end

               result = get_next_part_of_digest
            elseif digest_size_in_bytes <= 64 then
               result = get_hash_block(0)
            else
               local last_block_no = ceil(digest_size_in_bytes / 64) - 1
               for block_no = 0.0, last_block_no do
                  stack[33 + block_no] = get_hash_block(block_no)
               end
               result = table_concat(stack, "", 33, 33 + last_block_no)
            end
         end
         return result
      end
   end

   if message then
      -- Actually perform calculations and return the BLAKE3 digest of a message
      return partial(message)()
   else
      -- Return function for chunk-by-chunk loading
      -- User should feed every chunk of input data as single argument to this function and finally get BLAKE3 digest by invoking this function without an argument
      return partial
   end
end

local function blake3_derive_key(key_material, context_string, derived_key_size_in_bytes)
   -- key_material: (string) your source of entropy to derive a key from (for example, it can be a master password)
   --               set to nil for feeding the key material in "chunk-by-chunk" input mode
   -- context_string: (string) unique description of the derived key
   -- digest_size_in_bytes: (optional) by default 32
   --    0,1,2,3,4,...  = get finite derived key as single Lua string
   --    (-1)           = get infinite derived key in "chunk-by-chunk" output mode
   --    -2,-3,-4,...   = get finite derived key in "chunk-by-chunk" output mode
   if type(context_string) ~= "string" then
      error("'context_string' parameter must be a Lua string", 2)
   end
   local K = blake3(context_string, nil, nil, 32, nil, true)           -- flag:DERIVE_KEY_CONTEXT
   return blake3(key_material, nil, derived_key_size_in_bytes, 64, K)  -- flag:DERIVE_KEY_MATERIAL
end



local sha = {
   md5        = md5,                                                                                                                   -- MD5
   sha1       = sha1,                                                                                                                  -- SHA-1
   -- SHA-2 hash functions:
   sha224     = function (message)                       return sha256ext(224, message)                                           end, -- SHA-224
   sha256     = function (message)                       return sha256ext(256, message)                                           end, -- SHA-256
   sha512_224 = function (message)                       return sha512ext(224, message)                                           end, -- SHA-512/224
   sha512_256 = function (message)                       return sha512ext(256, message)                                           end, -- SHA-512/256
   sha384     = function (message)                       return sha512ext(384, message)                                           end, -- SHA-384
   sha512     = function (message)                       return sha512ext(512, message)                                           end, -- SHA-512
   -- SHA-3 hash functions:
   sha3_224   = function (message)                       return keccak((1600 - 2 * 224) / 8, 224 / 8, false, message)             end, -- SHA3-224
   sha3_256   = function (message)                       return keccak((1600 - 2 * 256) / 8, 256 / 8, false, message)             end, -- SHA3-256
   sha3_384   = function (message)                       return keccak((1600 - 2 * 384) / 8, 384 / 8, false, message)             end, -- SHA3-384
   sha3_512   = function (message)                       return keccak((1600 - 2 * 512) / 8, 512 / 8, false, message)             end, -- SHA3-512
   shake128   = function (digest_size_in_bytes, message) return keccak((1600 - 2 * 128) / 8, digest_size_in_bytes, true, message) end, -- SHAKE128
   shake256   = function (digest_size_in_bytes, message) return keccak((1600 - 2 * 256) / 8, digest_size_in_bytes, true, message) end, -- SHAKE256
   -- HMAC:
   hmac       = hmac,  -- HMAC(hash_func, key, message) is applicable to any hash function from this module except SHAKE* and BLAKE*
   -- misc utilities:
   hex_to_bin    = hex_to_bin,     -- converts hexadecimal representation to binary string
   bin_to_hex    = bin_to_hex,     -- converts binary string to hexadecimal representation
   base64_to_bin = base64_to_bin,  -- converts base64 representation to binary string
   bin_to_base64 = bin_to_base64,  -- converts binary string to base64 representation
   -- old style names for backward compatibility:
   hex2bin       = hex_to_bin,
   bin2hex       = bin_to_hex,
   base642bin    = base64_to_bin,
   bin2base64    = bin_to_base64,
   -- BLAKE2 hash functions:
   blake2b  = blake2b,   -- BLAKE2b (message, key, salt, digest_size_in_bytes)
   blake2s  = blake2s,   -- BLAKE2s (message, key, salt, digest_size_in_bytes)
   blake2bp = blake2bp,  -- BLAKE2bp(message, key, salt, digest_size_in_bytes)
   blake2sp = blake2sp,  -- BLAKE2sp(message, key, salt, digest_size_in_bytes)
   blake2xb = blake2xb,  -- BLAKE2Xb(digest_size_in_bytes, message, key, salt)
   blake2xs = blake2xs,  -- BLAKE2Xs(digest_size_in_bytes, message, key, salt)
   -- BLAKE2 aliases:
   blake2      = blake2b,
   blake2b_160 = function (message, key, salt) return blake2b(message, key, salt, 20) end, -- BLAKE2b-160
   blake2b_256 = function (message, key, salt) return blake2b(message, key, salt, 32) end, -- BLAKE2b-256
   blake2b_384 = function (message, key, salt) return blake2b(message, key, salt, 48) end, -- BLAKE2b-384
   blake2b_512 = blake2b,                                                      -- 64       -- BLAKE2b-512
   blake2s_128 = function (message, key, salt) return blake2s(message, key, salt, 16) end, -- BLAKE2s-128
   blake2s_160 = function (message, key, salt) return blake2s(message, key, salt, 20) end, -- BLAKE2s-160
   blake2s_224 = function (message, key, salt) return blake2s(message, key, salt, 28) end, -- BLAKE2s-224
   blake2s_256 = blake2s,                                                      -- 32       -- BLAKE2s-256
   -- BLAKE3 hash function
   blake3            = blake3,             -- BLAKE3    (message, key, digest_size_in_bytes)
   blake3_derive_key = blake3_derive_key,  -- BLAKE3_KDF(key_material, context_string, derived_key_size_in_bytes)
}


block_size_for_HMAC = {
   [sha.md5]        =  64,
   [sha.sha1]       =  64,
   [sha.sha224]     =  64,
   [sha.sha256]     =  64,
   [sha.sha512_224] = 128,
   [sha.sha512_256] = 128,
   [sha.sha384]     = 128,
   [sha.sha512]     = 128,
   [sha.sha3_224]   = 144,  -- (1600 - 2 * 224) / 8
   [sha.sha3_256]   = 136,  -- (1600 - 2 * 256) / 8
   [sha.sha3_384]   = 104,  -- (1600 - 2 * 384) / 8
   [sha.sha3_512]   =  72,  -- (1600 - 2 * 512) / 8
}

-- local cjson  = require 'cjson'
-- local base64 = require 'base64'
-- local crypto = require 'crypto'
local base64 = (function()
    local a='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'local function b(c)return(c:gsub('.',function(d)local e,a='',d:byte()for f=8,1,-1 do e=e..(a%2^f-a%2^(f-1)>0 and'1'or'0')end;return e end)..'0000'):gsub('%d%d%d?%d?%d?%d?',function(d)if#d<6 then return''end;local g=0;for f=1,6 do g=g+(d:sub(f,f)=='1'and 2^(6-f)or 0)end;return a:sub(g+1,g+1)end)..({'','==','='})[#c%3+1]end;local function h(c)c=string.gsub(c,'[^'..a..'=]','')return c:gsub('.',function(d)if d=='='then return''end;local e,i='',a:find(d)-1;for f=6,1,-1 do e=e..(i%2^f-i%2^(f-1)>0 and'1'or'0')end;return e end):gsub('%d%d%d?%d?%d?%d?%d?%d?',function(d)if#d~=8 then return''end;local g=0;for f=1,8 do g=g+(d:sub(f,f)=='1'and 2^(8-f)or 0)end;return string.char(g)end)end;return{encode=b,decode=h}
end)()

local alg_sign = {
	['HS256'] = function(data, key) 
        -- crypto.hmac.digest('sha256', data, key, true)
        return hmac("sha256", key, data)

    end,
	['HS384'] = function(data, key) return hmac('sha384', key, data) end,
	['HS512'] = function(data, key) return hmac('sha512', key, data) end,
}

local alg_verify = {
	['HS256'] = function(data, signature, key) return signature == alg_sign['HS256'](data, key) end,
	['HS384'] = function(data, signature, key) return signature == alg_sign['HS384'](data, key) end,
	['HS512'] = function(data, signature, key) return signature == alg_sign['HS512'](data, key) end,
}

local function b64_encode(input)	
	local result = base64.encode(input)
	
	result = result:gsub('+','-'):gsub('/','_'):gsub('=','')

	return result
end

local function b64_decode(input)
--	input = input:gsub('\n', ''):gsub(' ', '')

	local reminder = #input % 4

	if reminder > 0 then
		local padlen = 4 - reminder
		input = input .. string.rep('=', padlen)
	end

	input = input:gsub('-','+'):gsub('_','/')

	return base64.decode(input)
end

local function tokenize(str, div, len)
	local result, pos = {}, 0

	for st, sp in function() return str:find(div, pos, true) end do

		result[#result + 1] = str:sub(pos, st-1)
		pos = sp + 1

		len = len - 1

		if len <= 1 then
			break
		end
	end

	result[#result + 1] = str:sub(pos)

	return result
end

local M = {}

function M.encode(data, key, alg)
	if type(data) ~= 'table' then return nil, "Argument #1 must be table" end
	if type(key) ~= 'string' then return nil, "Argument #2 must be string" end

	alg = alg or "HS256" 

	if not alg_sign[alg] then
		return nil, "Algorithm not supported"
	end

	local header = { typ='JWT', alg=alg }

	local segments = {
		b64_encode(HttpService:JSONEncode(header)),
		b64_encode(HttpService:JSONEncode(data))
	}
    local signature = key
	segments[#segments+1] = b64_encode(signature)

	return table.concat(segments, ".")
end

function M.decode(data, key, verify)
	if key and verify == nil then verify = true end
	if type(data) ~= 'string' then return nil, "Argument #1 must be string" end
	if verify and type(key) ~= 'string' then return nil, "Argument #2 must be string" end

	local token = tokenize(data, '.', 3)

	if #token ~= 3 then
		return nil, "Invalid token"
	end

	local headerb64, bodyb64, sigb64 = token[1], token[2], token[3]

	local ok, header, body, sig = pcall(function ()

		return	HttpService:JSONDecode(b64_decode(headerb64)), 
			HttpService:JSONEncode(b64_decode(bodyb64)),
			b64_decode(sigb64)
	end)	

	if not ok then
		return nil, "Invalid json"
	end

	if verify then

		if not header.typ or header.typ ~= "JWT" then
			return nil, "Invalid typ"
		end

		if not header.alg or type(header.alg) ~= "string" then
			return nil, "Invalid alg"
		end

		if body.exp and type(body.exp) ~= "number" then
			return nil, "exp must be number"
		end

		if body.nbf and type(body.nbf) ~= "number" then
			return nil, "nbf must be number"
		end

		if not alg_verify[header.alg] then
			return nil, "Algorithm not supported"
		end

		if not alg_verify[header.alg](headerb64 .. "." .. bodyb64, sig, key) then
			return nil, "Invalid signature"
		end

		if body.exp and os.time() >= body.exp then
			return nil, "Not acceptable by exp"
		end

		if body.nbf and os.time() < body.nbf then
			return nil, "Not acceptable by nbf"
		end
	end

	return body
end


-- if getgenv().Kusnokix then return end;
-- getgenv().Kusnokix = true

local version = LPH_ENCSTR("0x01")
local hash1 = LPH_ENCSTR("2EMy18MOYqEg0y3Nxqmtigua3z0AynYQ")
local hash2 = LPH_ENCSTR("bYRVe6XeDJGiwN8VKlaFcJszzmRpUQN9")
local host = "http://103.216.158.57:4399"
local HttpService = game:GetService("HttpService")
local Hwid = game:GetService("RbxAnalyticsService"):GetClientId()
if not gethwid then
    error("Missing function gethwid", 7)
    return
end
local HwidSign = gethwid()

local r = HttpService:JSONDecode(request({
    Url = host .. "/getIdentitfy",
    Headers = {
        ["Content-Type"] = "application/json",
        ["x-discord-id"] = getgenv().Discord_ID,
        ["x-hwid"] = Hwid,
        ["x-hwid-signature"] =  HwidSign,
        ["x-project-id"] = getgenv().ProjectId,
        ["x-type"] = version
    },
    Body = HttpService:JSONEncode({
        ["x-signature-client"] = M.encode({
            ["hwid"] = Hwid
        }, sha.md5('{"discordId":"' .. getgenv().Discord_ID .. '","projectId":"' ..  getgenv().ProjectId ..'","type":"0x01","key":"' .. Hwid .. '"}')),
        ["x-signature-timestamp"] = DateTime.now().UnixTimestampMillis
    }),
    Method = "POST"
}).Body)
if r["code"] ~= 0 then
    game:GetService("Players").LocalPlayer:Kick("Vertifaction failed code : (" .. r["code"] .. ")")
end
function mod_exp(base, exp, mod)
    local result = 1
    base = base % mod
    while exp > 0 do
        if exp % 2 == 1 then  -- If exp is odd
            result = (result * base) % mod
        end
        exp = math.floor(exp / 2) -- Divide exp by 2
        base = (base * base) % mod
    end
    return result
end
local identitfy = r
local token = sha.md5('{"discordId":"' .. getgenv().Discord_ID .. '","hwid":"' .. Hwid .. '","projectId":"' .. getgenv().ProjectId .. '","type":"' .. version .. '","seed":{"oi":' .. ((identitfy.data.oi / 2 * 3) + 2321) .. ',"sd":' .. ((identitfy.data.sd % 4) + 5) .. ',"sj":' .. ((mod_exp(identitfy.data.sj, 333, 222) / 10)) .. ',"sk":' .. identitfy.data.sk .. '}}' .. HwidSign .. "0x00")
local verify = sha.md5('{"code":0,"discordId":"' .. getgenv().Discord_ID .. '","hwid":"' .. Hwid .. '","projectId":"' .. getgenv().ProjectId .. '","key":"' .. getgenv().Script_Key .. '","data":{"token":"' .. token .. '","' .. hash1 .. '":true,"' .. hash2 .. '":[0,0,0,0,0,1,1,1,1]}}')
local rv =request({
    Url = host .. "/verify/",
    Headers = {
        ["Content-Type"] = "application/json",
    },
    Body = HttpService:JSONEncode({
        ["key"] =  getgenv().Script_Key,
        ["hwid"] =  Hwid,
        ['discord-id'] =  getgenv().Discord_ID,
        ['project-id'] = getgenv().ProjectId,
        ["token"] = token,
    }),
    Method = "POST"
}).Body
local vertifyRequest = HttpService:JSONDecode(rv)

if vertifyRequest["code"] ~= 0 then
    game:GetService("Players").LocalPlayer:Kick( vertifyRequest["reason"] .. " (" .. vertifyRequest["code"] .. ")")
end

if verify ~= vertifyRequest["data"] then
    game:GetService("Players").LocalPlayer:Kick("Verification token mismatch")
end

getgenv().Kusnokix = nil
print("Whitelist !")
--* Your code here *--
local Fluent = loadstring(game:HttpGet("https://github.com/dawid-scripts/Fluent/releases/latest/download/main.lua"))()
local SaveManager = loadstring(game:HttpGet("https://raw.githubusercontent.com/dawid-scripts/Fluent/master/Addons/SaveManager.lua"))()
local InterfaceManager = loadstring(game:HttpGet("https://raw.githubusercontent.com/dawid-scripts/Fluent/master/Addons/InterfaceManager.lua"))()
--------------------------------------------------------------------------------------------------------------------------------------------
local Window = Fluent:CreateWindow({
    Title = "Oxygen Hub |",
    SubTitle = "Blox Fruit Premium Script",
    TabWidth = 160,
    Size = UDim2.fromOffset(500, 400),
    Acrylic = false, -- The blur may be detectable, setting this to false disables blur entirely
    Theme = "Purple",
    MinimizeKey = Enum.KeyCode.End -- Used when theres no MinimizeKeybind
})
local Tabs = {
    Main = Window:AddTab({ Title = "Main", Icon = "home" }),
    Stats = Window:AddTab({ Title = "Stats", Icon = "plus-circle" }),
	Mastery = Window:AddTab({ Title = "Mastery", Icon = "bar-chart-3" }),
	OtherFarms = Window:AddTab({ Title = "OtherFarms", Icon = "archive" }),
	Material = Window:AddTab({ Title = "Material", Icon = "shovel" }),
	items = Window:AddTab({ Title = "items", Icon = "boxes" }),
    Player = Window:AddTab({ Title = "Player", Icon = "person-standing" }),
    Teleport = Window:AddTab({ Title = "Teleport", Icon = "palmtree" }),
    Fruit = Window:AddTab({ Title = "Devil Fruit", Icon = "cherry" }),
    Raid = Window:AddTab({ Title = "Dungeon", Icon = "swords" }),
    Race = Window:AddTab({ Title = "Race V4", Icon = "chevrons-right" }),
    Shop = Window:AddTab({ Title = "Shop", Icon = "shopping-cart" }),
    Setting = Window:AddTab({ Title = "Setting", Icon = "settings" }),
	Misc = Window:AddTab({ Title = "Misc", Icon = "list-plus" }),
}
local Options = Fluent.Options

do
--------------------------------------------------------------------------------------------------------------------------------------------
    repeat wait() until game.Players
    repeat wait() until game.Players.LocalPlayer
    repeat wait() until game.ReplicatedStorage
    repeat wait() until game.ReplicatedStorage:FindFirstChild("Remotes");
    repeat wait() until game.Players.LocalPlayer:FindFirstChild("PlayerGui");
    repeat wait() until game.Players.LocalPlayer.PlayerGui:FindFirstChild("Main");
    repeat wait() until game:GetService("Players")
    repeat wait() until game:GetService("Players").LocalPlayer.Character:FindFirstChild("Energy")
    
    wait(0.1)
    
    if not game:IsLoaded() then repeat game.Loaded:Wait() until game:IsLoaded() end
    
    if game:GetService("Players").LocalPlayer.PlayerGui.Main:FindFirstChild("ChooseTeam") then
        repeat wait()
            if game:GetService("Players").LocalPlayer.PlayerGui:WaitForChild("Main").ChooseTeam.Visible == true then
                if _G.Team == "Pirate" then
                    for i, v in pairs(getconnections(game:GetService("Players").LocalPlayer.PlayerGui.Main.ChooseTeam.Container.Pirates.Frame.ViewportFrame.TextButton.Activated)) do                                                                                                
                        v.Function()
                    end
                elseif _G.Team == "Marine" then
                    for i, v in pairs(getconnections(game:GetService("Players").LocalPlayer.PlayerGui.Main.ChooseTeam.Container.Marines.Frame.ViewportFrame.TextButton.Activated)) do                                                                                                
                        v.Function()
                    end
                else
                    for i, v in pairs(getconnections(game:GetService("Players").LocalPlayer.PlayerGui.Main.ChooseTeam.Container.Pirates.Frame.ViewportFrame.TextButton.Activated)) do                                                                                                
                        v.Function()
                    end
                end
            end
        until game.Players.LocalPlayer.Team ~= nil and game:IsLoaded()
    end
	

------// BLOX FRUIT
--// Sea world
First_Sea = false
Second_Sea = false
Third_Sea = false
local placeId = game.PlaceId
if placeId == 2753915549 then
First_Sea = true
elseif placeId == 4442272183 then
Second_Sea = true
elseif placeId == 7449423635 then
Third_Sea = true
end

--// Check Quest
function CheckLevel()
local Lv = game:GetService("Players").LocalPlayer.Data.Level.Value
if First_Sea then
if Lv == 1 or Lv <= 9 or SelectMonster == "Bandit" or SelectArea == 'Jungle' then -- Bandit
Ms = "Bandit"
NameQuest = "BanditQuest1"
QuestLv = 1
NameMon = "Bandit"
CFrameQ = CFrame.new(1060.9383544922, 16.455066680908, 1547.7841796875)
CFrameMon = CFrame.new(1038.5533447266, 41.296249389648, 1576.5098876953)
elseif Lv == 10 or Lv <= 14 or SelectMonster == "Monkey" or SelectArea == 'Jungle' then -- Monkey
Ms = "Monkey"
NameQuest = "JungleQuest"
QuestLv = 1
NameMon = "Monkey"
CFrameQ = CFrame.new(-1601.6553955078, 36.85213470459, 153.38809204102)
CFrameMon = CFrame.new(-1448.1446533203, 50.851993560791, 63.60718536377)
elseif Lv == 15 or Lv <= 29 or SelectMonster == "Gorilla" or SelectArea == 'Jungle' then -- Gorilla
Ms = "Gorilla"
NameQuest = "JungleQuest"
QuestLv = 2
NameMon = "Gorilla"
CFrameQ = CFrame.new(-1601.6553955078, 36.85213470459, 153.38809204102)
CFrameMon = CFrame.new(-1142.6488037109, 40.462348937988, -515.39227294922)
elseif Lv == 30 or Lv <= 39 or SelectMonster == "Pirate" or SelectArea == 'Buggy' then -- Pirate
Ms = "Pirate"
NameQuest = "BuggyQuest1"
QuestLv = 1
NameMon = "Pirate"
CFrameQ = CFrame.new(-1140.1761474609, 4.752049446106, 3827.4057617188)
CFrameMon = CFrame.new(-1201.0881347656, 40.628940582275, 3857.5966796875)
elseif Lv == 40 or Lv <= 59 or SelectMonster == "Brute" or SelectArea == 'Buggy' then -- Brute
Ms = "Brute"
NameQuest = "BuggyQuest1"
QuestLv = 2
NameMon = "Brute"
CFrameQ = CFrame.new(-1140.1761474609, 4.752049446106, 3827.4057617188)
CFrameMon = CFrame.new(-1387.5324707031, 24.592035293579, 4100.9575195313)
elseif Lv == 60 or Lv <= 74 or SelectMonster == "Desert Bandit" or SelectArea == 'Desert' then -- Desert Bandit
Ms = "Desert Bandit"
NameQuest = "DesertQuest"
QuestLv = 1
NameMon = "Desert Bandit"
CFrameQ = CFrame.new(896.51721191406, 6.4384617805481, 4390.1494140625)
CFrameMon = CFrame.new(984.99896240234, 16.109552383423, 4417.91015625)
elseif Lv == 75 or Lv <= 89 or SelectMonster == "Desert Officer" or SelectArea == 'Desert' then -- Desert Officer
Ms = "Desert Officer"
NameQuest = "DesertQuest"
QuestLv = 2
NameMon = "Desert Officer"
CFrameQ = CFrame.new(896.51721191406, 6.4384617805481, 4390.1494140625)
CFrameMon = CFrame.new(1547.1510009766, 14.452038764954, 4381.8002929688)
elseif Lv == 90 or Lv <= 99 or SelectMonster == "Snow Bandit" or SelectArea == 'Snow' then -- Snow Bandit
Ms = "Snow Bandit"
NameQuest = "SnowQuest"
QuestLv = 1
NameMon = "Snow Bandit"
CFrameQ = CFrame.new(1386.8073730469, 87.272789001465, -1298.3576660156)
CFrameMon = CFrame.new(1356.3028564453, 105.76865386963, -1328.2418212891)
elseif Lv == 100 or Lv <= 119 or SelectMonster == "Snowman" or SelectArea == 'Snow' then -- Snowman
Ms = "Snowman"
NameQuest = "SnowQuest"
QuestLv = 2
NameMon = "Snowman"
CFrameQ = CFrame.new(1386.8073730469, 87.272789001465, -1298.3576660156)
CFrameMon = CFrame.new(1218.7956542969, 138.01184082031, -1488.0262451172)
elseif Lv == 120 or Lv <= 149 or SelectMonster == "Chief Petty Officer" or SelectArea == 'Marine' then -- Chief Petty Officer
Ms = "Chief Petty Officer"
NameQuest = "MarineQuest2"
QuestLv = 1
NameMon = "Chief Petty Officer"
CFrameQ = CFrame.new(-5035.49609375, 28.677835464478, 4324.1840820313)
CFrameMon = CFrame.new(-4931.1552734375, 65.793113708496, 4121.8393554688)
elseif Lv == 150 or Lv <= 174 or SelectMonster == "Sky Bandit" or SelectArea == 'Sky' then -- Sky Bandit
Ms = "Sky Bandit"
NameQuest = "SkyQuest"
QuestLv = 1
NameMon = "Sky Bandit"
CFrameQ = CFrame.new(-4842.1372070313, 717.69543457031, -2623.0483398438)
CFrameMon = CFrame.new(-4955.6411132813, 365.46365356445, -2908.1865234375)
elseif Lv == 175 or Lv <= 189 or SelectMonster == "Dark Master" or SelectArea == 'Sky' then -- Dark Master
Ms = "Dark Master"
NameQuest = "SkyQuest"
QuestLv = 2
NameMon = "Dark Master"
CFrameQ = CFrame.new(-4842.1372070313, 717.69543457031, -2623.0483398438)
CFrameMon = CFrame.new(-5148.1650390625, 439.04571533203, -2332.9611816406)
elseif Lv == 190 or Lv <= 209 or SelectMonster == "Prisoner" or SelectArea == 'Prison' then -- Prisoner
Ms = "Prisoner"
NameQuest = "PrisonerQuest"
QuestLv = 1
NameMon = "Prisoner"
CFrameQ = CFrame.new(5310.60547, 0.350014925, 474.946594, 0.0175017118, 0, 0.999846935, 0, 1, 0, -0.999846935, 0, 0.0175017118)
CFrameMon = CFrame.new(4937.31885, 0.332031399, 649.574524, 0.694649816, 0, -0.719348073, 0, 1, 0, 0.719348073, 0, 0.694649816)
elseif Lv == 210 or Lv <= 249 or SelectMonster == "Dangerous Prisoner" or SelectArea == 'Prison' then -- Dangerous Prisoner
Ms = "Dangerous Prisoner"
NameQuest = "PrisonerQuest"
QuestLv = 2
NameMon = "Dangerous Prisoner"
CFrameQ = CFrame.new(5310.60547, 0.350014925, 474.946594, 0.0175017118, 0, 0.999846935, 0, 1, 0, -0.999846935, 0, 0.0175017118)
CFrameMon = CFrame.new(5099.6626, 0.351562679, 1055.7583, 0.898906827, 0, -0.438139856, 0, 1, 0, 0.438139856, 0, 0.898906827)
elseif Lv == 250 or Lv <= 274 or SelectMonster == "Toga Warrior" or SelectArea == 'Colosseum' then -- Toga Warrior
Ms = "Toga Warrior"
NameQuest = "ColosseumQuest"
QuestLv = 1
NameMon = "Toga Warrior"
CFrameQ = CFrame.new(-1577.7890625, 7.4151420593262, -2984.4838867188)
CFrameMon = CFrame.new(-1872.5166015625, 49.080215454102, -2913.810546875)
elseif Lv == 275 or Lv <= 299 or SelectMonster == "Gladiator" or SelectArea == 'Colosseum' then -- Gladiator
Ms = "Gladiator"
NameQuest = "ColosseumQuest"
QuestLv = 2
NameMon = "Gladiator"
CFrameQ = CFrame.new(-1577.7890625, 7.4151420593262, -2984.4838867188)
CFrameMon = CFrame.new(-1521.3740234375, 81.203170776367, -3066.3139648438)
elseif Lv == 300 or Lv <= 324 or SelectMonster == "Military Soldier" or SelectArea == 'Magma' then -- Military Soldier
Ms = "Military Soldier"
NameQuest = "MagmaQuest"
QuestLv = 1
NameMon = "Military Soldier"
CFrameQ = CFrame.new(-5316.1157226563, 12.262831687927, 8517.00390625)
CFrameMon = CFrame.new(-5369.0004882813, 61.24352645874, 8556.4921875)
elseif Lv == 325 or Lv <= 374 or SelectMonster == "Military Spy" or SelectArea == 'Magma' then -- Military Spy
Ms = "Military Spy"
NameQuest = "MagmaQuest"
QuestLv = 2
NameMon = "Military Spy"
CFrameQ = CFrame.new(-5316.1157226563, 12.262831687927, 8517.00390625)
CFrameMon = CFrame.new(-5787.00293, 75.8262634, 8651.69922, 0.838590562, 0, -0.544762194, 0, 1, 0, 0.544762194, 0, 0.838590562)
elseif Lv == 375 or Lv <= 399 or SelectMonster == "Fishman Warrior" or SelectArea == 'Fishman' then -- Fishman Warrior
Ms = "Fishman Warrior"
NameQuest = "FishmanQuest"
QuestLv = 1
NameMon = "Fishman Warrior"
CFrameQ = CFrame.new(61122.65234375, 18.497442245483, 1569.3997802734)
CFrameMon = CFrame.new(60844.10546875, 98.462875366211, 1298.3985595703)
if Auto_Farm and (CFrameMon.Position - game.Players.LocalPlayer.Character.HumanoidRootPart.Position).Magnitude > 3000 then
game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("requestEntrance",Vector3.new(61163.8515625, 11.6796875, 1819.7841796875))
end
elseif Lv == 400 or Lv <= 449 or SelectMonster == "Fishman Commando" or SelectArea == 'Fishman' then -- Fishman Commando
Ms = "Fishman Commando"
NameQuest = "FishmanQuest"
QuestLv = 2
NameMon = "Fishman Commando"
CFrameQ = CFrame.new(61122.65234375, 18.497442245483, 1569.3997802734)
CFrameMon = CFrame.new(61738.3984375, 64.207321166992, 1433.8375244141)
if Auto_Farm and (CFrameMon.Position - game.Players.LocalPlayer.Character.HumanoidRootPart.Position).Magnitude > 3000 then
game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("requestEntrance",Vector3.new(61163.8515625, 11.6796875, 1819.7841796875))
end
elseif Lv == 450 or Lv <= 474 or SelectMonster == "God's Guard" or SelectArea == 'Sky Island' then -- God's Guard
Ms = "God's Guard"
NameQuest = "SkyExp1Quest"
QuestLv = 1
NameMon = "God's Guard"
CFrameQ = CFrame.new(-4721.8603515625, 845.30297851563, -1953.8489990234)
CFrameMon = CFrame.new(-4628.0498046875, 866.92877197266, -1931.2352294922)
if Auto_Farm and (CFrameMon.Position - game.Players.LocalPlayer.Character.HumanoidRootPart.Position).Magnitude > 3000 then
game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("requestEntrance",Vector3.new(-4607.82275, 872.54248, -1667.55688))
end
elseif Lv == 475 or Lv <= 524 or SelectMonster == "Shanda" or SelectArea == 'Sky Island' then -- Shanda
Ms = "Shanda"
NameQuest = "SkyExp1Quest"
QuestLv = 2
NameMon = "Shanda"
CFrameQ = CFrame.new(-7863.1596679688, 5545.5190429688, -378.42266845703)
CFrameMon = CFrame.new(-7685.1474609375, 5601.0751953125, -441.38876342773)
if Auto_Farm and (CFrameMon.Position - game.Players.LocalPlayer.Character.HumanoidRootPart.Position).Magnitude > 3000 then
game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("requestEntrance",Vector3.new(-7894.6176757813, 5547.1416015625, -380.29119873047))
end
elseif Lv == 525 or Lv <= 549 or SelectMonster == "Royal Squad" or SelectArea == 'Sky Island' then -- Royal Squad
Ms = "Royal Squad"
NameQuest = "SkyExp2Quest"
QuestLv = 1
NameMon = "Royal Squad"
CFrameQ = CFrame.new(-7903.3828125, 5635.9897460938, -1410.923828125)
CFrameMon = CFrame.new(-7654.2514648438, 5637.1079101563, -1407.7550048828)
elseif Lv == 550 or Lv <= 624 or SelectMonster == "Royal Soldier" or SelectArea == 'Sky Island' then -- Royal Soldier
Ms = "Royal Soldier"
NameQuest = "SkyExp2Quest"
QuestLv = 2
NameMon = "Royal Soldier"
CFrameQ = CFrame.new(-7903.3828125, 5635.9897460938, -1410.923828125)
CFrameMon = CFrame.new(-7760.4106445313, 5679.9077148438, -1884.8112792969)
elseif Lv == 625 or Lv <= 649 or SelectMonster == "Galley Pirate" or SelectArea == 'Fountain' then -- Galley Pirate
Ms = "Galley Pirate"
NameQuest = "FountainQuest"
QuestLv = 1
NameMon = "Galley Pirate"
CFrameQ = CFrame.new(5258.2788085938, 38.526931762695, 4050.044921875)
CFrameMon = CFrame.new(5557.1684570313, 152.32717895508, 3998.7758789063)
elseif Lv >= 650 or SelectMonster == "Galley Captain" or SelectArea == 'Fountain' then -- Galley Captain
Ms = "Galley Captain"
NameQuest = "FountainQuest"
QuestLv = 2
NameMon = "Galley Captain"
CFrameQ = CFrame.new(5258.2788085938, 38.526931762695, 4050.044921875)
CFrameMon = CFrame.new(5677.6772460938, 92.786109924316, 4966.6323242188)
end
end
if Second_Sea then
if Lv == 700 or Lv <= 724 or SelectMonster == "Raider" or SelectArea == 'Area 1' then -- Raider
Ms = "Raider"
NameQuest = "Area1Quest"
QuestLv = 1
NameMon = "Raider"
CFrameQ = CFrame.new(-427.72567749023, 72.99634552002, 1835.9426269531)
CFrameMon = CFrame.new(68.874565124512, 93.635643005371, 2429.6752929688)
elseif Lv == 725 or Lv <= 774 or SelectMonster == "Mercenary" or SelectArea == 'Area 1' then -- Mercenary
Ms = "Mercenary"
NameQuest = "Area1Quest"
QuestLv = 2
NameMon = "Mercenary"
CFrameQ = CFrame.new(-427.72567749023, 72.99634552002, 1835.9426269531)
CFrameMon = CFrame.new(-864.85009765625, 122.47104644775, 1453.1505126953)
elseif Lv == 775 or Lv <= 799 or SelectMonster == "Swan Pirate" or SelectArea == 'Area 2' then -- Swan Pirate
Ms = "Swan Pirate"
NameQuest = "Area2Quest"
QuestLv = 1
NameMon = "Swan Pirate"
CFrameQ = CFrame.new(635.61151123047, 73.096351623535, 917.81298828125)
CFrameMon = CFrame.new(1065.3669433594, 137.64012145996, 1324.3798828125)
elseif Lv == 800 or Lv <= 874 or SelectMonster == "Factory Staff" or SelectArea == 'Area 2' then -- Factory Staff
Ms = "Factory Staff"
NameQuest = "Area2Quest"
QuestLv = 2
NameMon = "Factory Staff"
CFrameQ = CFrame.new(635.61151123047, 73.096351623535, 917.81298828125)
CFrameMon = CFrame.new(533.22045898438, 128.46876525879, 355.62615966797)
elseif Lv == 875 or Lv <= 899 or SelectMonster == "Marine Lieutenan" or SelectArea == 'Marine' then -- Marine Lieutenant
Ms = "Marine Lieutenant"
NameQuest = "MarineQuest3"
QuestLv = 1
NameMon = "Marine Lieutenant"
CFrameQ = CFrame.new(-2440.9934082031, 73.04190826416, -3217.7082519531)
CFrameMon = CFrame.new(-2489.2622070313, 84.613594055176, -3151.8830566406)
elseif Lv == 900 or Lv <= 949 or SelectMonster == "Marine Captain" or SelectArea == 'Marine' then -- Marine Captain
Ms = "Marine Captain"
NameQuest = "MarineQuest3"
QuestLv = 2
NameMon = "Marine Captain"
CFrameQ = CFrame.new(-2440.9934082031, 73.04190826416, -3217.7082519531)
CFrameMon = CFrame.new(-2335.2026367188, 79.786659240723, -3245.8674316406)
elseif Lv == 950 or Lv <= 974 or SelectMonster == "Zombie" or SelectArea == 'Zombie' then -- Zombie
Ms = "Zombie"
NameQuest = "ZombieQuest"
QuestLv = 1
NameMon = "Zombie"
CFrameQ = CFrame.new(-5494.3413085938, 48.505931854248, -794.59094238281)
CFrameMon = CFrame.new(-5536.4970703125, 101.08577728271, -835.59075927734)
elseif Lv == 975 or Lv <= 999 or SelectMonster == "Vampire" or SelectArea == 'Zombie' then -- Vampire
Ms = "Vampire"
NameQuest = "ZombieQuest"
QuestLv = 2
NameMon = "Vampire"
CFrameQ = CFrame.new(-5494.3413085938, 48.505931854248, -794.59094238281)
CFrameMon = CFrame.new(-5806.1098632813, 16.722528457642, -1164.4384765625)
elseif Lv == 1000 or Lv <= 1049 or SelectMonster == "Snow Trooper" or SelectArea == 'Snow Mountain' then -- Snow Trooper
Ms = "Snow Trooper"
NameQuest = "SnowMountainQuest"
QuestLv = 1
NameMon = "Snow Trooper"
CFrameQ = CFrame.new(607.05963134766, 401.44781494141, -5370.5546875)
CFrameMon = CFrame.new(535.21051025391, 432.74209594727, -5484.9165039063)
elseif Lv == 1050 or Lv <= 1099 or SelectMonster == "Winter Warrior" or SelectArea == 'Snow Mountain' then -- Winter Warrior
Ms = "Winter Warrior"
NameQuest = "SnowMountainQuest"
QuestLv = 2
NameMon = "Winter Warrior"
CFrameQ = CFrame.new(607.05963134766, 401.44781494141, -5370.5546875)
CFrameMon = CFrame.new(1234.4449462891, 456.95419311523, -5174.130859375)
elseif Lv == 1100 or Lv <= 1124 or SelectMonster == "Lab Subordinate" or SelectArea == 'Ice Fire' then -- Lab Subordinate
Ms = "Lab Subordinate"
NameQuest = "IceSideQuest"
QuestLv = 1
NameMon = "Lab Subordinate"
CFrameQ = CFrame.new(-6061.841796875, 15.926671981812, -4902.0385742188)
CFrameMon = CFrame.new(-5720.5576171875, 63.309471130371, -4784.6103515625)
elseif Lv == 1125 or Lv <= 1174 or SelectMonster == "Horned Warrior" or SelectArea == 'Ice Fire' then -- Horned Warrior
Ms = "Horned Warrior"
NameQuest = "IceSideQuest"
QuestLv = 2
NameMon = "Horned Warrior"
CFrameQ = CFrame.new(-6061.841796875, 15.926671981812, -4902.0385742188)
CFrameMon = CFrame.new(-6292.751953125, 91.181983947754, -5502.6499023438)
elseif Lv == 1175 or Lv <= 1199 or SelectMonster == "Magma Ninja" or SelectArea == 'Ice Fire' then -- Magma Ninja
Ms = "Magma Ninja"
NameQuest = "FireSideQuest"
QuestLv = 1
NameMon = "Magma Ninja"
CFrameQ = CFrame.new(-5429.0473632813, 15.977565765381, -5297.9614257813)
CFrameMon = CFrame.new(-5461.8388671875, 130.36347961426, -5836.4702148438)
elseif Lv == 1200 or Lv <= 1249 or SelectMonster == "Lava Pirate" or SelectArea == 'Ice Fire' then -- Lava Pirate
Ms = "Lava Pirate"
NameQuest = "FireSideQuest"
QuestLv = 2
NameMon = "Lava Pirate"
CFrameQ = CFrame.new(-5429.0473632813, 15.977565765381, -5297.9614257813)
CFrameMon = CFrame.new(-5251.1889648438, 55.164535522461, -4774.4096679688)
elseif Lv == 1250 or Lv <= 1274 or SelectMonster == "Ship Deckhand" or SelectArea == 'Ship' then -- Ship Deckhand
Ms = "Ship Deckhand"
NameQuest = "ShipQuest1"
QuestLv = 1
NameMon = "Ship Deckhand"
CFrameQ = CFrame.new(1040.2927246094, 125.08293151855, 32911.0390625)
CFrameMon = CFrame.new(921.12365722656, 125.9839553833, 33088.328125)
if Auto_Farm and (CFrameMon.Position - game.Players.LocalPlayer.Character.HumanoidRootPart.Position).Magnitude > 20000 then
game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("requestEntrance",Vector3.new(923.21252441406, 126.9760055542, 32852.83203125))
end
elseif Lv == 1275 or Lv <= 1299 or SelectMonster == "Ship Engineer" or SelectArea == 'Ship' then -- Ship Engineer
Ms = "Ship Engineer"
NameQuest = "ShipQuest1"
QuestLv = 2
NameMon = "Ship Engineer"
CFrameQ = CFrame.new(1040.2927246094, 125.08293151855, 32911.0390625)
CFrameMon = CFrame.new(886.28179931641, 40.47790145874, 32800.83203125)
if Auto_Farm and (CFrameMon.Position - game.Players.LocalPlayer.Character.HumanoidRootPart.Position).Magnitude > 20000 then
game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("requestEntrance",Vector3.new(923.21252441406, 126.9760055542, 32852.83203125))
end
elseif Lv == 1300 or Lv <= 1324 or SelectMonster == "Ship Steward" or SelectArea == 'Ship' then -- Ship Steward
Ms = "Ship Steward"
NameQuest = "ShipQuest2"
QuestLv = 1
NameMon = "Ship Steward"
CFrameQ = CFrame.new(971.42065429688, 125.08293151855, 33245.54296875)
CFrameMon = CFrame.new(943.85504150391, 129.58183288574, 33444.3671875)
if Auto_Farm and (CFrameMon.Position - game.Players.LocalPlayer.Character.HumanoidRootPart.Position).Magnitude > 20000 then
game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("requestEntrance",Vector3.new(923.21252441406, 126.9760055542, 32852.83203125))
end
elseif Lv == 1325 or Lv <= 1349 or SelectMonster == "Ship Officer" or SelectArea == 'Ship' then -- Ship Officer
Ms = "Ship Officer"
NameQuest = "ShipQuest2"
QuestLv = 2
NameMon = "Ship Officer"
CFrameQ = CFrame.new(971.42065429688, 125.08293151855, 33245.54296875)
CFrameMon = CFrame.new(955.38458251953, 181.08335876465, 33331.890625)
if Auto_Farm and (CFrameMon.Position - game.Players.LocalPlayer.Character.HumanoidRootPart.Position).Magnitude > 20000 then
game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("requestEntrance",Vector3.new(923.21252441406, 126.9760055542, 32852.83203125))
end
elseif Lv == 1350 or Lv <= 1374 or SelectMonster == "Arctic Warrior" or SelectArea == 'Frost' then -- Arctic Warrior
Ms = "Arctic Warrior"
NameQuest = "FrostQuest"
QuestLv = 1
NameMon = "Arctic Warrior"
CFrameQ = CFrame.new(5668.1372070313, 28.202531814575, -6484.6005859375)
CFrameMon = CFrame.new(5935.4541015625, 77.26016998291, -6472.7568359375)
if Auto_Farm and (CFrameMon.Position - game.Players.LocalPlayer.Character.HumanoidRootPart.Position).Magnitude > 20000 then
game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("requestEntrance",Vector3.new(-6508.5581054688, 89.034996032715, -132.83953857422))
end
elseif Lv == 1375 or Lv <= 1424 or SelectMonster == "Snow Lurker" or SelectArea == 'Frost' then -- Snow Lurker
Ms = "Snow Lurker"
NameQuest = "FrostQuest"
QuestLv = 2
NameMon = "Snow Lurker"
CFrameQ = CFrame.new(5668.1372070313, 28.202531814575, -6484.6005859375)
CFrameMon = CFrame.new(5628.482421875, 57.574996948242, -6618.3481445313)
elseif Lv == 1425 or Lv <= 1449 or SelectMonster == "Sea Soldier" or SelectArea == 'Forgotten' then -- Sea Soldier
Ms = "Sea Soldier"
NameQuest = "ForgottenQuest"
QuestLv = 1
NameMon = "Sea Soldier"
CFrameQ = CFrame.new(-3054.5827636719, 236.87213134766, -10147.790039063)
CFrameMon = CFrame.new(-3185.0153808594, 58.789089202881, -9663.6064453125)
elseif Lv >= 1450 or SelectMonster == "Water Fighter" or SelectArea == 'Forgotten' then -- Water Fighter
Ms = "Water Fighter"
NameQuest = "ForgottenQuest"
QuestLv = 2
NameMon = "Water Fighter"
CFrameQ = CFrame.new(-3054.5827636719, 236.87213134766, -10147.790039063)
CFrameMon = CFrame.new(-3262.9301757813, 298.69036865234, -10552.529296875)
end
end
if Third_Sea then
if Lv == 1500 or Lv <= 1524 or SelectMonster == "Pirate Millionaire" or SelectArea == 'Pirate Port' then -- Pirate Millionaire
Ms = "Pirate Millionaire"
NameQuest = "PiratePortQuest"
QuestLv = 1
NameMon = "Pirate Millionaire"
CFrameQ = CFrame.new(-289.61752319336, 43.819011688232, 5580.0903320313)
CFrameMon = CFrame.new(-435.68109130859, 189.69866943359, 5551.0756835938)
elseif Lv == 1525 or Lv <= 1574 or SelectMonster == "Pistol Billionaire" or SelectArea == 'Pirate Port' then -- Pistol Billoonaire
Ms = "Pistol Billionaire"
NameQuest = "PiratePortQuest"
QuestLv = 2
NameMon = "Pistol Billionaire"
CFrameQ = CFrame.new(-289.61752319336, 43.819011688232, 5580.0903320313)
CFrameMon = CFrame.new(-236.53652954102, 217.46676635742, 6006.0883789063)
elseif Lv == 1575 or Lv <= 1599 or SelectMonster == "Dragon Crew Warrior" or SelectArea == 'Amazon' then -- Dragon Crew Warrior
Ms = "Dragon Crew Warrior"
NameQuest = "AmazonQuest"
QuestLv = 1
NameMon = "Dragon Crew Warrior"
CFrameQ = CFrame.new(5833.1147460938, 51.60498046875, -1103.0693359375)
CFrameMon = CFrame.new(6301.9975585938, 104.77153015137, -1082.6075439453)
elseif Lv == 1600 or Lv <= 1624 or SelectMonster == "Dragon Crew Archer" or SelectArea == 'Amazon' then -- Dragon Crew Archer
Ms = "Dragon Crew Archer"
NameQuest = "AmazonQuest"
QuestLv = 2
NameMon = "Dragon Crew Archer"
CFrameQ = CFrame.new(5833.1147460938, 51.60498046875, -1103.0693359375)
CFrameMon = CFrame.new(6831.1171875, 441.76708984375, 446.58615112305)
elseif Lv == 1625 or Lv <= 1649 or SelectMonster == "Female Islander" or SelectArea == 'Amazon' then -- Female Islander
Ms = "Female Islander"
NameQuest = "AmazonQuest2"
QuestLv = 1
NameMon = "Female Islander"
CFrameQ = CFrame.new(5446.8793945313, 601.62945556641, 749.45672607422)
CFrameMon = CFrame.new(5792.5166015625, 848.14392089844, 1084.1818847656)
elseif Lv == 1650 or Lv <= 1699 or SelectMonster == "Giant Islander" or SelectArea == 'Amazon' then -- Giant Islander
Ms = "Giant Islander"
NameQuest = "AmazonQuest2"
QuestLv = 2
NameMon = "Giant Islander"
CFrameQ = CFrame.new(5446.8793945313, 601.62945556641, 749.45672607422)
CFrameMon = CFrame.new(5009.5068359375, 664.11071777344, -40.960144042969)
elseif Lv == 1700 or Lv <= 1724 or SelectMonster == "Marine Commodore" or SelectArea == 'Marine Tree' then -- Marine Commodore
Ms = "Marine Commodore"
NameQuest = "MarineTreeIsland"
QuestLv = 1
NameMon = "Marine Commodore"
CFrameQ = CFrame.new(2179.98828125, 28.731239318848, -6740.0551757813)
CFrameMon = CFrame.new(2198.0063476563, 128.71075439453, -7109.5043945313)
elseif Lv == 1725 or Lv <= 1774 or SelectMonster == "Marine Rear Admiral" or SelectArea == 'Marine Tree' then -- Marine Rear Admiral
Ms = "Marine Rear Admiral"
NameQuest = "MarineTreeIsland"
QuestLv = 2
NameMon = "Marine Rear Admiral"
CFrameQ = CFrame.new(2179.98828125, 28.731239318848, -6740.0551757813)
CFrameMon = CFrame.new(3294.3142089844, 385.41125488281, -7048.6342773438)
elseif Lv == 1775 or Lv <= 1799 or SelectMonster == "Fishman Raider" or SelectArea == 'Deep Forest' then -- Fishman Raide
Ms = "Fishman Raider"
NameQuest = "DeepForestIsland3"
QuestLv = 1
NameMon = "Fishman Raider"
CFrameQ = CFrame.new(-10582.759765625, 331.78845214844, -8757.666015625)
CFrameMon = CFrame.new(-10553.268554688, 521.38439941406, -8176.9458007813)
elseif Lv == 1800 or Lv <= 1824 or SelectMonster == "Fishman Captain" or SelectArea == 'Deep Forest' then -- Fishman Captain
Ms = "Fishman Captain"
NameQuest = "DeepForestIsland3"
QuestLv = 2
NameMon = "Fishman Captain"
CFrameQ = CFrame.new(-10583.099609375, 331.78845214844, -8759.4638671875)
CFrameMon = CFrame.new(-10789.401367188, 427.18637084961, -9131.4423828125)
elseif Lv == 1825 or Lv <= 1849 or SelectMonster == "Forest Pirate" or SelectArea == 'Deep Forest' then -- Forest Pirate
Ms = "Forest Pirate"
NameQuest = "DeepForestIsland"
QuestLv = 1
NameMon = "Forest Pirate"
CFrameQ = CFrame.new(-13232.662109375, 332.40396118164, -7626.4819335938)
CFrameMon = CFrame.new(-13489.397460938, 400.30349731445, -7770.251953125)
elseif Lv == 1850 or Lv <= 1899 or SelectMonster == "Mythological Pirate" or SelectArea == 'Deep Forest' then -- Mythological Pirate
Ms = "Mythological Pirate"
NameQuest = "DeepForestIsland"
QuestLv = 2
NameMon = "Mythological Pirate"
CFrameQ = CFrame.new(-13232.662109375, 332.40396118164, -7626.4819335938)
CFrameMon = CFrame.new(-13508.616210938, 582.46228027344, -6985.3037109375)
elseif Lv == 1900 or Lv <= 1924 or SelectMonster == "Jungle Pirate" or SelectArea == 'Deep Forest' then -- Jungle Pirate
Ms = "Jungle Pirate"
NameQuest = "DeepForestIsland2"
QuestLv = 1
NameMon = "Jungle Pirate"
CFrameQ = CFrame.new(-12682.096679688, 390.88653564453, -9902.1240234375)
CFrameMon = CFrame.new(-12267.103515625, 459.75262451172, -10277.200195313)
elseif Lv == 1925 or Lv <= 1974 or SelectMonster == "Musketeer Pirate" or SelectArea == 'Deep Forest' then -- Musketeer Pirate
Ms = "Musketeer Pirate"
NameQuest = "DeepForestIsland2"
QuestLv = 2
NameMon = "Musketeer Pirate"
CFrameQ = CFrame.new(-12682.096679688, 390.88653564453, -9902.1240234375)
CFrameMon = CFrame.new(-13291.5078125, 520.47338867188, -9904.638671875)
elseif Lv == 1975 or Lv <= 1999 or SelectMonster == "Reborn Skeleton" or SelectArea == 'Haunted Castle' then
Ms = "Reborn Skeleton"
NameQuest = "HauntedQuest1"
QuestLv = 1
NameMon = "Reborn Skeleton"
CFrameQ = CFrame.new(-9480.80762, 142.130661, 5566.37305, -0.00655503059, 4.52954225e-08, -0.999978542, 2.04920472e-08, 1, 4.51620679e-08, 0.999978542, -2.01955679e-08, -0.00655503059)
CFrameMon = CFrame.new(-8761.77148, 183.431747, 6168.33301, 0.978073597, -1.3950732e-05, -0.208259016, -1.08073925e-06, 1, -7.20630269e-05, 0.208259016, 7.07080399e-05, 0.978073597)
elseif Lv == 2000 or Lv <= 2024 or SelectMonster == "Living Zombie" or SelectArea == 'Haunted Castle' then
Ms = "Living Zombie"
NameQuest = "HauntedQuest1"
QuestLv = 2
NameMon = "Living Zombie"
CFrameQ = CFrame.new(-9480.80762, 142.130661, 5566.37305, -0.00655503059, 4.52954225e-08, -0.999978542, 2.04920472e-08, 1, 4.51620679e-08, 0.999978542, -2.01955679e-08, -0.00655503059)
CFrameMon = CFrame.new(-10103.7529, 238.565979, 6179.75977, 0.999474227, 2.77547141e-08, 0.0324240364, -2.58006327e-08, 1, -6.06848474e-08, -0.0324240364, 5.98163865e-08, 0.999474227)
elseif Lv == 2025 or Lv <= 2049 or SelectMonster == "Demonic Soul" or SelectArea == 'Haunted Castle' then
Ms = "Demonic Soul"
NameQuest = "HauntedQuest2"
QuestLv = 1
NameMon = "Demonic Soul"
CFrameQ = CFrame.new(-9516.9931640625, 178.00651550293, 6078.4653320313)
CFrameMon = CFrame.new(-9712.03125, 204.69589233398, 6193.322265625)
elseif Lv == 2050 or Lv <= 2074 or SelectMonster == "Posessed Mummy" or SelectArea == 'Haunted Castle' then
Ms = "Posessed Mummy"
NameQuest = "HauntedQuest2"
QuestLv = 2
NameMon = "Posessed Mummy"
CFrameQ = CFrame.new(-9516.9931640625, 178.00651550293, 6078.4653320313)
CFrameMon = CFrame.new(-9545.7763671875, 69.619895935059, 6339.5615234375)
elseif Lv == 2075 or Lv <= 2099 or SelectMonster == "Peanut Scout" or SelectArea == 'Nut Island' then
Ms = "Peanut Scout"
NameQuest = "NutsIslandQuest"
QuestLv = 1
NameMon = "Peanut Scout"
CFrameQ = CFrame.new(-2105.53198, 37.2495995, -10195.5088, -0.766061664, 0, -0.642767608, 0, 1, 0, 0.642767608, 0, -0.766061664)
CFrameMon = CFrame.new(-2150.587890625, 122.49767303467, -10358.994140625)
elseif Lv == 2100 or Lv <= 2124 or SelectMonster == "Peanut President" or SelectArea == 'Nut Island' then
Ms = "Peanut President"
NameQuest = "NutsIslandQuest"
QuestLv = 2
NameMon = "Peanut President"
CFrameQ = CFrame.new(-2105.53198, 37.2495995, -10195.5088, -0.766061664, 0, -0.642767608, 0, 1, 0, 0.642767608, 0, -0.766061664)
CFrameMon = CFrame.new(-2150.587890625, 122.49767303467, -10358.994140625)
elseif Lv == 2125 or Lv <= 2149 or SelectMonster == "Ice Cream Chef" or SelectArea == 'Ice Cream Island' then
Ms = "Ice Cream Chef"
NameQuest = "IceCreamIslandQuest"
QuestLv = 1
NameMon = "Ice Cream Chef"
CFrameQ = CFrame.new(-819.376709, 64.9259796, -10967.2832, -0.766061664, 0, 0.642767608, 0, 1, 0, -0.642767608, 0, -0.766061664)
CFrameMon = CFrame.new(-789.941528, 209.382889, -11009.9805, -0.0703101531, -0, -0.997525156, -0, 1.00000012, -0, 0.997525275, 0, -0.0703101456)
elseif Lv == 2150 or Lv <= 2199 or SelectMonster == "Ice Cream Commander" or SelectArea == 'Ice Cream Island' then
Ms = "Ice Cream Commander"
NameQuest = "IceCreamIslandQuest"
QuestLv = 2
NameMon = "Ice Cream Commander"
CFrameQ = CFrame.new(-819.376709, 64.9259796, -10967.2832, -0.766061664, 0, 0.642767608, 0, 1, 0, -0.642767608, 0, -0.766061664)
CFrameMon = CFrame.new(-789.941528, 209.382889, -11009.9805, -0.0703101531, -0, -0.997525156, -0, 1.00000012, -0, 0.997525275, 0, -0.0703101456)
elseif Lv == 2200 or Lv <= 2224 or SelectMonster == "Cookie Crafter" or SelectArea == 'Cake Island' then
Ms = "Cookie Crafter"
NameQuest = "CakeQuest1"
QuestLv = 1
NameMon = "Cookie Crafter"
CFrameQ = CFrame.new(-2022.29858, 36.9275894, -12030.9766, -0.961273909, 0, -0.275594592, 0, 1, 0, 0.275594592, 0, -0.961273909)
CFrameMon = CFrame.new(-2321.71216, 36.699482, -12216.7871, -0.780074954, 0, 0.625686109, 0, 1, 0, -0.625686109, 0, -0.780074954)
elseif Lv == 2225 or Lv <= 2249 or SelectMonster == "Cake Guard" or SelectArea == 'Cake Island' then
Ms = "Cake Guard"
NameQuest = "CakeQuest1"
QuestLv = 2
NameMon = "Cake Guard"
CFrameQ = CFrame.new(-2022.29858, 36.9275894, -12030.9766, -0.961273909, 0, -0.275594592, 0, 1, 0, 0.275594592, 0, -0.961273909)
CFrameMon = CFrame.new(-1418.11011, 36.6718941, -12255.7324, 0.0677844882, 0, 0.997700036, 0, 1, 0, -0.997700036, 0, 0.0677844882)
elseif Lv == 2250 or Lv <= 2274 or SelectMonster == "Baking Staff" or SelectArea == 'Cake Island' then
Ms = "Baking Staff"
NameQuest = "CakeQuest2"
QuestLv = 1
NameMon = "Baking Staff"
CFrameQ = CFrame.new(-1928.31763, 37.7296638, -12840.626, 0.951068401, -0, -0.308980465, 0, 1, -0, 0.308980465, 0, 0.951068401)
CFrameMon = CFrame.new(-1980.43848, 36.6716766, -12983.8418, -0.254443765, 0, -0.967087567, 0, 1, 0, 0.967087567, 0, -0.254443765)
elseif Lv == 2275 or Lv <= 2299 or SelectMonster == "Head Baker" or SelectArea == 'Cake Island' then
Ms = "Head Baker"
NameQuest = "CakeQuest2"
QuestLv = 2
NameMon = "Head Baker"
CFrameQ = CFrame.new(-1928.31763, 37.7296638, -12840.626, 0.951068401, -0, -0.308980465, 0, 1, -0, 0.308980465, 0, 0.951068401)
CFrameMon = CFrame.new(-2251.5791, 52.2714615, -13033.3965, -0.991971016, 0, -0.126466095, 0, 1, 0, 0.126466095, 0, -0.991971016)
elseif Lv == 2300 or Lv <= 2324 or SelectMonster == "Cocoa Warrior" or SelectArea == 'Choco Island' then
Ms = "Cocoa Warrior"
NameQuest = "ChocQuest1"
QuestLv = 1
NameMon = "Cocoa Warrior"
CFrameQ = CFrame.new(231.75, 23.9003029, -12200.292, -1, 0, 0, 0, 1, 0, 0, 0, -1)
CFrameMon = CFrame.new(167.978516, 26.2254658, -12238.874, -0.939700961, 0, 0.341998369, 0, 1, 0, -0.341998369, 0, -0.939700961)
elseif Lv == 2325 or Lv <= 2349 or SelectMonster == "Chocolate Bar Battler" or SelectArea == 'Choco Island' then
Ms = "Chocolate Bar Battler"
NameQuest = "ChocQuest1"
QuestLv = 2
NameMon = "Chocolate Bar Battler"
CFrameQ = CFrame.new(231.75, 23.9003029, -12200.292, -1, 0, 0, 0, 1, 0, 0, 0, -1)
CFrameMon = CFrame.new(701.312073, 25.5824986, -12708.2148, -0.342042685, 0, -0.939684391, 0, 1, 0, 0.939684391, 0, -0.342042685)
elseif Lv == 2350 or Lv <= 2374 or SelectMonster == "Sweet Thief" or SelectArea == 'Choco Island' then
Ms = "Sweet Thief"
NameQuest = "ChocQuest2"
QuestLv = 1
NameMon = "Sweet Thief"
CFrameQ = CFrame.new(151.198242, 23.8907146, -12774.6172, 0.422592998, 0, 0.906319618, 0, 1, 0, -0.906319618, 0, 0.422592998)
CFrameMon = CFrame.new(-140.258301, 25.5824986, -12652.3115, 0.173624337, -0, -0.984811902, 0, 1, -0, 0.984811902, 0, 0.173624337)
elseif Lv == 2375 or Lv <= 2400 or SelectMonster == "Candy Rebel" or SelectArea == 'Choco Island' then
Ms = "Candy Rebel"
NameQuest = "ChocQuest2"
QuestLv = 2
NameMon = "Candy Rebel"
CFrameQ = CFrame.new(151.198242, 23.8907146, -12774.6172, 0.422592998, 0, 0.906319618, 0, 1, 0, -0.906319618, 0, 0.422592998)
CFrameMon = CFrame.new(47.9231453, 25.5824986, -13029.2402, -0.819156051, 0, -0.573571265, 0, 1, 0, 0.573571265, 0, -0.819156051)
elseif Lv == 2400 or Lv <= 2424 or SelectMonster == "Candy Pirate" or SelectArea == 'Candy Island' then
Ms = "Candy Pirate"
NameQuest = "CandyQuest1"
QuestLv = 1
NameMon = "Candy Pirate"
CFrameQ = CFrame.new(-1149.328, 13.5759039, -14445.6143, -0.156446099, 0, -0.987686574, 0, 1, 0, 0.987686574, 0, -0.156446099)
CFrameMon = CFrame.new(-1437.56348, 17.1481285, -14385.6934, 0.173624337, -0, -0.984811902, 0, 1, -0, 0.984811902, 0, 0.173624337)
elseif Lv == 2425 or Lv <= 2449 or SelectMonster == "Snow Demon" or SelectArea == 'Candy Island' then
Ms = "Snow Demon"
NameQuest = "CandyQuest1"
QuestLv = 2
NameMon = "Snow Demon"
CFrameQ = CFrame.new(-1149.328, 13.5759039, -14445.6143, -0.156446099, 0, -0.987686574, 0, 1, 0, 0.987686574, 0, -0.156446099)
CFrameMon = CFrame.new(-916.222656, 17.1481285, -14638.8125, 0.866007268, 0, 0.500031412, 0, 1, 0, -0.500031412, 0, 0.866007268)
elseif Lv == 2450 or Lv <= 2474 or SelectMonster == "Isle Outlaw" or SelectArea == 'Tiki Outpost' then
Ms = "Isle Outlaw"
NameQuest = "TikiQuest1"
QuestLv = 1
NameMon = "Isle Outlaw"
CFrameQ = CFrame.new(-16549.890625, 55.68635559082031, -179.91360473632812)
CFrameMon = CFrame.new(-16162.8193359375, 11.6863374710083, -96.45481872558594)
elseif Lv == 2475 or Lv <= 2524 or SelectMonster == "Island Boy" or SelectArea == 'Tiki Outpost' then
Ms = "Island Boy"
NameQuest = "TikiQuest1"
QuestLv = 2
NameMon = "Island Boy"
CFrameQ = CFrame.new(-16549.890625, 55.68635559082031, -179.91360473632812)
CFrameMon = CFrame.new(-16912.130859375, 11.787443161010742, -133.0850830078125)
elseif Lv >= 2525 or SelectMonster == "Isle Champion" or SelectArea == 'Tiki Outpost' then
Ms = "Isle Champion"
NameQuest = "TikiQuest2"
QuestLv = 2
NameMon = "Isle Champion"
CFrameQ = CFrame.new(-16542.447265625, 55.68632888793945, 1044.41650390625)
CFrameMon = CFrame.new(-16848.94140625, 21.68633460998535, 1041.4490966796875)
end
end
end

--// Select Monster
if First_Sea then
tableMon = {
  "Bandit","Monkey","Gorilla","Pirate","Brute","Desert Bandit","Desert Officer","Snow Bandit","Snowman","Chief Petty Officer","Sky Bandit","Dark Master","Prisoner", "Dangerous Prisoner","Toga Warrior","Gladiator","Military Soldier","Military Spy","Fishman Warrior","Fishman Commando","God's Guard","Shanda","Royal Squad","Royal Soldier","Galley Pirate","Galley Captain"
} elseif Second_Sea then
tableMon = {
  "Raider","Mercenary","Swan Pirate","Factory Staff","Marine Lieutenant","Marine Captain","Zombie","Vampire","Snow Trooper","Winter Warrior","Lab Subordinate","Horned Warrior","Magma Ninja","Lava Pirate","Ship Deckhand","Ship Engineer","Ship Steward","Ship Officer","Arctic Warrior","Snow Lurker","Sea Soldier","Water Fighter"
} elseif Third_Sea then
tableMon = {
  "Pirate Millionaire","Dragon Crew Warrior","Dragon Crew Archer","Female Islander","Giant Islander","Marine Commodore","Marine Rear Admiral","Fishman Raider","Fishman Captain","Forest Pirate","Mythological Pirate","Jungle Pirate","Musketeer Pirate","Reborn Skeleton","Living Zombie","Demonic Soul","Posessed Mummy", "Peanut Scout", "Peanut President", "Ice Cream Chef", "Ice Cream Commander", "Cookie Crafter", "Cake Guard", "Baking Staff", "Head Baker", "Cocoa Warrior", "Chocolate Bar Battler", "Sweet Thief", "Candy Rebel", "Candy Pirate", "Snow Demon","Isle Outlaw","Island Boy","Isle Champion"
}
end

--// Select Island
if First_Sea then
AreaList = {
  'Jungle', 'Buggy', 'Desert', 'Snow', 'Marine', 'Sky', 'Prison', 'Colosseum', 'Magma', 'Fishman', 'Sky Island', 'Fountain'
} elseif Second_Sea then
AreaList = {
  'Area 1', 'Area 2', 'Zombie', 'Marine', 'Snow Mountain', 'Ice fire', 'Ship', 'Frost', 'Forgotten'
} elseif Third_Sea then
AreaList = {
  'Pirate Port', 'Amazon', 'Marine Tree', 'Deep Forest', 'Haunted Castle', 'Nut Island', 'Ice Cream Island', 'Cake Island', 'Choco Island', 'Candy Island','Tiki Outpost'
}
end

--// Check Boss Quest
function CheckBossQuest()
if First_Sea then
if SelectBoss == "The Gorilla King" then
BossMon = "The Gorilla King"
NameBoss = 'The Gorrila King'
NameQuestBoss = "JungleQuest"
QuestLvBoss = 3
RewardBoss = "Reward:\n$2,000\n7,000 Exp."
CFrameQBoss = CFrame.new(-1601.6553955078, 36.85213470459, 153.38809204102)
CFrameBoss = CFrame.new(-1088.75977, 8.13463783, -488.559906, -0.707134247, 0, 0.707079291, 0, 1, 0, -0.707079291, 0, -0.707134247)
elseif SelectBoss == "Bobby" then
BossMon = "Bobby"
NameBoss = 'Bobby'
NameQuestBoss = "BuggyQuest1"
QuestLvBoss = 3
RewardBoss = "Reward:\n$8,000\n35,000 Exp."
CFrameQBoss = CFrame.new(-1140.1761474609, 4.752049446106, 3827.4057617188)
CFrameBoss = CFrame.new(-1087.3760986328, 46.949409484863, 4040.1462402344)
elseif SelectBoss == "The Saw" then
BossMon = "The Saw"
NameBoss = 'The Saw'
CFrameBoss = CFrame.new(-784.89715576172, 72.427383422852, 1603.5822753906)
elseif SelectBoss == "Yeti" then
BossMon = "Yeti"
NameBoss = 'Yeti'
NameQuestBoss = "SnowQuest"
QuestLvBoss = 3
RewardBoss = "Reward:\n$10,000\n180,000 Exp."
CFrameQBoss = CFrame.new(1386.8073730469, 87.272789001465, -1298.3576660156)
CFrameBoss = CFrame.new(1218.7956542969, 138.01184082031, -1488.0262451172)
elseif SelectBoss == "Mob Leader" then
BossMon = "Mob Leader"
NameBoss = 'Mob Leader'
CFrameBoss = CFrame.new(-2844.7307128906, 7.4180502891541, 5356.6723632813)
elseif SelectBoss == "Vice Admiral" then
BossMon = "Vice Admiral"
NameBoss = 'Vice Admiral'
NameQuestBoss = "MarineQuest2"
QuestLvBoss = 2
RewardBoss = "Reward:\n$10,000\n180,000 Exp."
CFrameQBoss = CFrame.new(-5036.2465820313, 28.677835464478, 4324.56640625)
CFrameBoss = CFrame.new(-5006.5454101563, 88.032081604004, 4353.162109375)
elseif SelectBoss == "Saber Expert" then
NameBoss = 'Saber Expert'
BossMon = "Saber Expert"
CFrameBoss = CFrame.new(-1458.89502, 29.8870335, -50.633564)
elseif SelectBoss == "Warden" then
BossMon = "Warden"
NameBoss = 'Warden'
NameQuestBoss = "ImpelQuest"
QuestLvBoss = 1
RewardBoss = "Reward:\n$6,000\n850,000 Exp."
CFrameBoss = CFrame.new(5278.04932, 2.15167475, 944.101929, 0.220546961, -4.49946401e-06, 0.975376427, -1.95412576e-05, 1, 9.03162072e-06, -0.975376427, -2.10519756e-05, 0.220546961)
CFrameQBoss = CFrame.new(5191.86133, 2.84020686, 686.438721, -0.731384635, 0, 0.681965172, 0, 1, 0, -0.681965172, 0, -0.731384635)
elseif SelectBoss == "Chief Warden" then
BossMon = "Chief Warden"
NameBoss = 'Chief Warden'
NameQuestBoss = "ImpelQuest"
QuestLvBoss = 2
RewardBoss = "Reward:\n$10,000\n1,000,000 Exp."
CFrameBoss = CFrame.new(5206.92578, 0.997753382, 814.976746, 0.342041343, -0.00062915677, 0.939684749, 0.00191645394, 0.999998152, -2.80422337e-05, -0.939682961, 0.00181045406, 0.342041939)
CFrameQBoss = CFrame.new(5191.86133, 2.84020686, 686.438721, -0.731384635, 0, 0.681965172, 0, 1, 0, -0.681965172, 0, -0.731384635)
elseif SelectBoss == "Swan" then
BossMon = "Swan"
NameBoss = 'Swan'
NameQuestBoss = "ImpelQuest"
QuestLvBoss = 3
RewardBoss = "Reward:\n$15,000\n1,600,000 Exp."
CFrameBoss = CFrame.new(5325.09619, 7.03906584, 719.570679, -0.309060812, 0, 0.951042235, 0, 1, 0, -0.951042235, 0, -0.309060812)
CFrameQBoss = CFrame.new(5191.86133, 2.84020686, 686.438721, -0.731384635, 0, 0.681965172, 0, 1, 0, -0.681965172, 0, -0.731384635)
elseif SelectBoss == "Magma Admiral" then
BossMon = "Magma Admiral"
NameBoss = 'Magma Admiral'
NameQuestBoss = "MagmaQuest"
QuestLvBoss = 3
RewardBoss = "Reward:\n$15,000\n2,800,000 Exp."
CFrameQBoss = CFrame.new(-5314.6220703125, 12.262420654297, 8517.279296875)
CFrameBoss = CFrame.new(-5765.8969726563, 82.92064666748, 8718.3046875)
elseif SelectBoss == "Fishman Lord" then
BossMon = "Fishman Lord"
NameBoss = 'Fishman Lord'
NameQuestBoss = "FishmanQuest"
QuestLvBoss = 3
RewardBoss = "Reward:\n$15,000\n4,000,000 Exp."
CFrameQBoss = CFrame.new(61122.65234375, 18.497442245483, 1569.3997802734)
CFrameBoss = CFrame.new(61260.15234375, 30.950881958008, 1193.4329833984)
elseif SelectBoss == "Wysper" then
BossMon = "Wysper"
NameBoss = 'Wysper'
NameQuestBoss = "SkyExp1Quest"
QuestLvBoss = 3
RewardBoss = "Reward:\n$15,000\n4,800,000 Exp."
CFrameQBoss = CFrame.new(-7861.947265625, 5545.517578125, -379.85974121094)
CFrameBoss = CFrame.new(-7866.1333007813, 5576.4311523438, -546.74816894531)
elseif SelectBoss == "Thunder God" then
BossMon = "Thunder God"
NameBoss = 'Thunder God'
NameQuestBoss = "SkyExp2Quest"
QuestLvBoss = 3
RewardBoss = "Reward:\n$20,000\n5,800,000 Exp."
CFrameQBoss = CFrame.new(-7903.3828125, 5635.9897460938, -1410.923828125)
CFrameBoss = CFrame.new(-7994.984375, 5761.025390625, -2088.6479492188)
elseif SelectBoss == "Cyborg" then
BossMon = "Cyborg"
NameBoss = 'Cyborg'
NameQuestBoss = "FountainQuest"
QuestLvBoss = 3
RewardBoss = "Reward:\n$20,000\n7,500,000 Exp."
CFrameQBoss = CFrame.new(5258.2788085938, 38.526931762695, 4050.044921875)
CFrameBoss = CFrame.new(6094.0249023438, 73.770050048828, 3825.7348632813)
elseif SelectBoss == "Ice Admiral" then
BossMon = "Ice Admiral"
NameBoss = 'Ice Admiral'
CFrameBoss = CFrame.new(1266.08948, 26.1757946, -1399.57678, -0.573599219, 0, -0.81913656, 0, 1, 0, 0.81913656, 0, -0.573599219)
elseif SelectBoss == "Greybeard" then
BossMon = "Greybeard"
NameBoss = 'Greybeard'
CFrameBoss = CFrame.new(-5081.3452148438, 85.221641540527, 4257.3588867188)
end
end
if Second_Sea then
if SelectBoss == "Diamond" then
BossMon = "Diamond"
NameBoss = 'Diamond'
NameQuestBoss = "Area1Quest"
QuestLvBoss = 3
RewardBoss = "Reward:\n$25,000\n9,000,000 Exp."
CFrameQBoss = CFrame.new(-427.5666809082, 73.313781738281, 1835.4208984375)
CFrameBoss = CFrame.new(-1576.7166748047, 198.59265136719, 13.724286079407)
elseif SelectBoss == "Jeremy" then
BossMon = "Jeremy"
NameBoss = 'Jeremy'
NameQuestBoss = "Area2Quest"
QuestLvBoss = 3
RewardBoss = "Reward:\n$25,000\n11,500,000 Exp."
CFrameQBoss = CFrame.new(636.79943847656, 73.413787841797, 918.00415039063)
CFrameBoss = CFrame.new(2006.9261474609, 448.95666503906, 853.98284912109)
elseif SelectBoss == "Fajita" then
BossMon = "Fajita"
NameBoss = 'Fajita'
NameQuestBoss = "MarineQuest3"
QuestLvBoss = 3
RewardBoss = "Reward:\n$25,000\n15,000,000 Exp."
CFrameQBoss = CFrame.new(-2441.986328125, 73.359344482422, -3217.5324707031)
CFrameBoss = CFrame.new(-2172.7399902344, 103.32216644287, -4015.025390625)
elseif SelectBoss == "Don Swan" then
BossMon = "Don Swan"
NameBoss = 'Don Swan'
CFrameBoss = CFrame.new(2286.2004394531, 15.177839279175, 863.8388671875)
elseif SelectBoss == "Smoke Admiral" then
BossMon = "Smoke Admiral"
NameBoss = 'Smoke Admiral'
NameQuestBoss = "IceSideQuest"
QuestLvBoss = 3
RewardBoss = "Reward:\n$20,000\n25,000,000 Exp."
CFrameQBoss = CFrame.new(-5429.0473632813, 15.977565765381, -5297.9614257813)
CFrameBoss = CFrame.new(-5275.1987304688, 20.757257461548, -5260.6669921875)
elseif SelectBoss == "Awakened Ice Admiral" then
BossMon = "Awakened Ice Admiral"
NameBoss = 'Awakened Ice Admiral'
NameQuestBoss = "FrostQuest"
QuestLvBoss = 3
RewardBoss = "Reward:\n$20,000\n36,000,000 Exp."
CFrameQBoss = CFrame.new(5668.9780273438, 28.519989013672, -6483.3520507813)
CFrameBoss = CFrame.new(6403.5439453125, 340.29766845703, -6894.5595703125)
elseif SelectBoss == "Tide Keeper" then
BossMon = "Tide Keeper"
NameBoss = 'Tide Keeper'
NameQuestBoss = "ForgottenQuest"
QuestLvBoss = 3
RewardBoss = "Reward:\n$12,500\n38,000,000 Exp."
CFrameQBoss = CFrame.new(-3053.9814453125, 237.18954467773, -10145.0390625)
CFrameBoss = CFrame.new(-3795.6423339844, 105.88877105713, -11421.307617188)
elseif SelectBoss == "Darkbeard" then
BossMon = "Darkbeard"
NameBoss = 'Darkbeard'
CFrameMon = CFrame.new(3677.08203125, 62.751937866211, -3144.8332519531)
elseif SelectBoss == "Cursed Captain" then
BossMon = "Cursed Captain"
NameBoss = 'Cursed Captain'
CFrameBoss = CFrame.new(916.928589, 181.092773, 33422)
elseif SelectBoss == "Order" then
BossMon = "Order"
NameBoss = 'Order'
CFrameBoss = CFrame.new(-6217.2021484375, 28.047645568848, -5053.1357421875)
end
end
if Third_Sea then
if SelectBoss == "Stone" then
BossMon = "Stone"
NameBoss = 'Stone'
NameQuestBoss = "PiratePortQuest"
QuestLvBoss = 3
RewardBoss = "Reward:\n$25,000\n40,000,000 Exp."
CFrameQBoss = CFrame.new(-289.76705932617, 43.819011688232, 5579.9384765625)
CFrameBoss = CFrame.new(-1027.6512451172, 92.404174804688, 6578.8530273438)
elseif SelectBoss == "Island Empress" then
BossMon = "Island Empress"
NameBoss = 'Island Empress'
NameQuestBoss = "AmazonQuest2"
QuestLvBoss = 3
RewardBoss = "Reward:\n$30,000\n52,000,000 Exp."
CFrameQBoss = CFrame.new(5445.9541015625, 601.62945556641, 751.43792724609)
CFrameBoss = CFrame.new(5543.86328125, 668.97399902344, 199.0341796875)
elseif SelectBoss == "Kilo Admiral" then
BossMon = "Kilo Admiral"
NameBoss = 'Kilo Admiral'
NameQuestBoss = "MarineTreeIsland"
QuestLvBoss = 3
RewardBoss = "Reward:\n$35,000\n56,000,000 Exp."
CFrameQBoss = CFrame.new(2179.3010253906, 28.731239318848, -6739.9741210938)
CFrameBoss = CFrame.new(2764.2233886719, 432.46154785156, -7144.4580078125)
elseif SelectBoss == "Captain Elephant" then
BossMon = "Captain Elephant"
NameBoss = 'Captain Elephant'
NameQuestBoss = "DeepForestIsland"
QuestLvBoss = 3
RewardBoss = "Reward:\n$40,000\n67,000,000 Exp."
CFrameQBoss = CFrame.new(-13232.682617188, 332.40396118164, -7626.01171875)
CFrameBoss = CFrame.new(-13376.7578125, 433.28689575195, -8071.392578125)
elseif SelectBoss == "Beautiful Pirate" then
BossMon = "Beautiful Pirate"
NameBoss = 'Beautiful Pirate'
NameQuestBoss = "DeepForestIsland2"
QuestLvBoss = 3
RewardBoss = "Reward:\n$50,000\n70,000,000 Exp."
CFrameQBoss = CFrame.new(-12682.096679688, 390.88653564453, -9902.1240234375)
CFrameBoss = CFrame.new(5283.609375, 22.56223487854, -110.78285217285)
elseif SelectBoss == "Cake Queen" then
BossMon = "Cake Queen"
NameBoss = 'Cake Queen'
NameQuestBoss = "IceCreamIslandQuest"
QuestLvBoss = 3
RewardBoss = "Reward:\n$30,000\n112,500,000 Exp."
CFrameQBoss = CFrame.new(-819.376709, 64.9259796, -10967.2832, -0.766061664, 0, 0.642767608, 0, 1, 0, -0.642767608, 0, -0.766061664)
CFrameBoss = CFrame.new(-678.648804, 381.353943, -11114.2012, -0.908641815, 0.00149294338, 0.41757378, 0.00837114919, 0.999857843, 0.0146408929, -0.417492568, 0.0167988986, -0.90852499)
elseif SelectBoss == "Longma" then
BossMon = "Longma"
NameBoss = 'Longma'
CFrameBoss = CFrame.new(-10238.875976563, 389.7912902832, -9549.7939453125)
elseif SelectBoss == "Soul Reaper" then
BossMon = "Soul Reaper"
NameBoss = 'Soul Reaper'
CFrameBoss = CFrame.new(-9524.7890625, 315.80429077148, 6655.7192382813)
elseif SelectBoss == "rip_indra True Form" then
BossMon = "rip_indra True Form"
NameBoss = 'rip_indra True Form'
CFrameBoss = CFrame.new(-5415.3920898438, 505.74133300781, -2814.0166015625)
end
end
end

--// Check Material
function MaterialMon()
if SelectMaterial == "Radioactive Material" then
MMon = "Factory Staff"
MPos = CFrame.new(295,73,-56)
SP = "Default"
elseif SelectMaterial == "Mystic Droplet" then
MMon = "Water Fighter"
MPos = CFrame.new(-3385,239,-10542)
SP = "Default"
elseif SelectMaterial == "Magma Ore" then
if First_Sea then
MMon = "Military Spy"
MPos = CFrame.new(-5815,84,8820)
SP = "Default"
elseif Second_Sea then
MMon = "Magma Ninja"
MPos = CFrame.new(-5428,78,-5959)
SP = "Default"
end
elseif SelectMaterial == "Angel Wings" then
MMon = "God's Guard"
MPos = CFrame.new(-4698,845,-1912)
SP = "Default"
if (game.Players.LocalPlayer.Character.HumanoidRootPart.Position - Vector3.new(-7859.09814, 5544.19043, -381.476196)).Magnitude >= 5000 then
game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("requestEntrance",Vector3.new(-7859.09814, 5544.19043, -381.476196))
end
elseif SelectMaterial == "Leather" then
if First_Sea then
MMon = "Brute"
MPos = CFrame.new(-1145,15,4350)
SP = "Default"
elseif Second_Sea then
MMon = "Marine Captain"
MPos = CFrame.new(-2010.5059814453125, 73.00115966796875, -3326.620849609375)
SP = "Default"
elseif Third_Sea then
MMon = "Jungle Pirate"
MPos = CFrame.new(-11975.78515625, 331.7734069824219, -10620.0302734375)
SP = "Default"
end
elseif SelectMaterial == "Scrap Metal" then
if First_Sea then
MMon = "Brute"
MPos = CFrame.new(-1145,15,4350)
SP = "Default"
elseif Second_Sea then
MMon = "Swan Pirate"
MPos = CFrame.new(878,122,1235)
SP = "Default"
elseif Third_Sea then
MMon = "Jungle Pirate"
MPos = CFrame.new(-12107,332,-10549)
SP = "Default"
end
elseif SelectMaterial == "Fish Tail" then
if Third_Sea then
MMon = "Fishman Raider"
MPos = CFrame.new(-10993,332,-8940)
SP = "Default"
elseif First_Sea then
MMon = "Fishman Warrior"
MPos = CFrame.new(61123,19,1569)
SP = "Default"
if (game.Players.LocalPlayer.Character.HumanoidRootPart.Position - Vector3.new(61163.8515625, 5.342342376708984, 1819.7841796875)).Magnitude >= 17000 then
game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("requestEntrance",Vector3.new(61163.8515625, 5.342342376708984, 1819.7841796875))
end
end
elseif SelectMaterial == "Demonic Wisp" then
MMon = "Demonic Soul"
MPos = CFrame.new(-9507,172,6158)
SP = "Default"
elseif SelectMaterial == "Vampire Fang" then
MMon = "Vampire"
MPos = CFrame.new(-6033,7,-1317)
SP = "Default"
elseif SelectMaterial == "Conjured Cocoa" then
MMon = "Chocolate Bar Battler"
MPos = CFrame.new(620.6344604492188,78.93644714355469, -12581.369140625)
SP = "Default"
elseif SelectMaterial == "Dragon Scale" then
MMon = "Dragon Crew Archer"
MPos = CFrame.new(6594,383,139)
SP = "Default"
elseif SelectMaterial == "Gunpowder" then
MMon = "Pistol Billionaire"
MPos = CFrame.new(-469,74,5904)
SP = "Default"
elseif SelectMaterial == "Mini Tusk" then
MMon = "Mythological Pirate"
MPos = CFrame.new(-13545,470,-6917)
SP = "Default"
end
end




---------------------Esp

function UpdateIslandESP() 
    for i,v in pairs(game:GetService("Workspace")["_WorldOrigin"].Locations:GetChildren()) do
        pcall(function()
            if IslandESP then 
                if v.Name ~= "Sea" then
                    if not v:FindFirstChild('NameEsp') then
                        local bill = Instance.new('BillboardGui',v)
                        bill.Name = 'NameEsp'
                        bill.ExtentsOffset = Vector3.new(0, 1, 0)
                        bill.Size = UDim2.new(1,200,1,30)
                        bill.Adornee = v
                        bill.AlwaysOnTop = true
                        local name = Instance.new('TextLabel',bill)
                        name.Font = "GothamBold"
                        name.FontSize = "Size14"
                        name.TextWrapped = true
                        name.Size = UDim2.new(1,0,1,0)
                        name.TextYAlignment = 'Top'
                        name.BackgroundTransparency = 1
                        name.TextStrokeTransparency = 0.5
                        name.TextColor3 = Color3.fromRGB(7, 236, 240)
                    else
                        v['NameEsp'].TextLabel.Text = (v.Name ..'   \n'.. round((game:GetService('Players').LocalPlayer.Character.Head.Position - v.Position).Magnitude/3) ..' Distance')
                    end
                end
            else
                if v:FindFirstChild('NameEsp') then
                    v:FindFirstChild('NameEsp'):Destroy()
                end
            end
        end)
    end
end

function isnil(thing)
return (thing == nil)
end
local function round(n)
return math.floor(tonumber(n) + 0.5)
end
Number = math.random(1, 1000000)
function UpdatePlayerChams()
for i,v in pairs(game:GetService'Players':GetChildren()) do
    pcall(function()
        if not isnil(v.Character) then
            if ESPPlayer then
                if not isnil(v.Character.Head) and not v.Character.Head:FindFirstChild('NameEsp'..Number) then
                    local bill = Instance.new('BillboardGui',v.Character.Head)
                    bill.Name = 'NameEsp'..Number
                    bill.ExtentsOffset = Vector3.new(0, 1, 0)
                    bill.Size = UDim2.new(1,200,1,30)
                    bill.Adornee = v.Character.Head
                    bill.AlwaysOnTop = true
                    local name = Instance.new('TextLabel',bill)
                    name.Font = Enum.Font.GothamSemibold
                    name.FontSize = "Size14"
                    name.TextWrapped = true
                    name.Text = (v.Name ..' \n'.. round((game:GetService('Players').LocalPlayer.Character.Head.Position - v.Character.Head.Position).Magnitude/3) ..' Distance')
                    name.Size = UDim2.new(1,0,1,0)
                    name.TextYAlignment = 'Top'
                    name.BackgroundTransparency = 1
                    name.TextStrokeTransparency = 0.5
                    if v.Team == game.Players.LocalPlayer.Team then
                        name.TextColor3 = Color3.new(0,255,0)
                    else
                        name.TextColor3 = Color3.new(255,0,0)
                    end
                else
                    v.Character.Head['NameEsp'..Number].TextLabel.Text = (v.Name ..' | '.. round((game:GetService('Players').LocalPlayer.Character.Head.Position - v.Character.Head.Position).Magnitude/3) ..' Distance\nHealth : ' .. round(v.Character.Humanoid.Health*100/v.Character.Humanoid.MaxHealth) .. '%')
                end
            else
                if v.Character.Head:FindFirstChild('NameEsp'..Number) then
                    v.Character.Head:FindFirstChild('NameEsp'..Number):Destroy()
                end
            end
        end
    end)
end
end
function UpdateChestChams() 
for i,v in pairs(game.Workspace:GetChildren()) do
    pcall(function()
        if string.find(v.Name,"Chest") then
            if ChestESP then
                if string.find(v.Name,"Chest") then
                    if not v:FindFirstChild('NameEsp'..Number) then
                        local bill = Instance.new('BillboardGui',v)
                        bill.Name = 'NameEsp'..Number
                        bill.ExtentsOffset = Vector3.new(0, 1, 0)
                        bill.Size = UDim2.new(1,200,1,30)
                        bill.Adornee = v
                        bill.AlwaysOnTop = true
                        local name = Instance.new('TextLabel',bill)
                        name.Font = Enum.Font.GothamSemibold
                        name.FontSize = "Size14"
                        name.TextWrapped = true
                        name.Size = UDim2.new(1,0,1,0)
                        name.TextYAlignment = 'Top'
                        name.BackgroundTransparency = 1
                        name.TextStrokeTransparency = 0.5
                        if v.Name == "Chest1" then
                            name.TextColor3 = Color3.fromRGB(109, 109, 109)
                            name.Text = ("Chest 1" ..' \n'.. round((game:GetService('Players').LocalPlayer.Character.Head.Position - v.Position).Magnitude/3) ..' Distance')
                        end
                        if v.Name == "Chest2" then
                            name.TextColor3 = Color3.fromRGB(173, 158, 21)
                            name.Text = ("Chest 2" ..' \n'.. round((game:GetService('Players').LocalPlayer.Character.Head.Position - v.Position).Magnitude/3) ..' Distance')
                        end
                        if v.Name == "Chest3" then
                            name.TextColor3 = Color3.fromRGB(85, 255, 255)
                            name.Text = ("Chest 3" ..' \n'.. round((game:GetService('Players').LocalPlayer.Character.Head.Position - v.Position).Magnitude/3) ..' Distance')
                        end
                    else
                        v['NameEsp'..Number].TextLabel.Text = (v.Name ..'   \n'.. round((game:GetService('Players').LocalPlayer.Character.Head.Position - v.Position).Magnitude/3) ..' Distance')
                    end
                end
            else
                if v:FindFirstChild('NameEsp'..Number) then
                    v:FindFirstChild('NameEsp'..Number):Destroy()
                end
            end
        end
    end)
end
end
function UpdateDevilChams() 
for i,v in pairs(game.Workspace:GetChildren()) do
    pcall(function()
        if DevilFruitESP then
            if string.find(v.Name, "Fruit") then   
                if not v.Handle:FindFirstChild('NameEsp'..Number) then
                    local bill = Instance.new('BillboardGui',v.Handle)
                    bill.Name = 'NameEsp'..Number
                    bill.ExtentsOffset = Vector3.new(0, 1, 0)
                    bill.Size = UDim2.new(1,200,1,30)
                    bill.Adornee = v.Handle
                    bill.AlwaysOnTop = true
                    local name = Instance.new('TextLabel',bill)
                    name.Font = Enum.Font.GothamSemibold
                    name.FontSize = "Size14"
                    name.TextWrapped = true
                    name.Size = UDim2.new(1,0,1,0)
                    name.TextYAlignment = 'Top'
                    name.BackgroundTransparency = 1
                    name.TextStrokeTransparency = 0.5
                    name.TextColor3 = Color3.fromRGB(255, 255, 255)
                    name.Text = (v.Name ..' \n'.. round((game:GetService('Players').LocalPlayer.Character.Head.Position - v.Handle.Position).Magnitude/3) ..' Distance')
                else
                    v.Handle['NameEsp'..Number].TextLabel.Text = (v.Name ..'   \n'.. round((game:GetService('Players').LocalPlayer.Character.Head.Position - v.Handle.Position).Magnitude/3) ..' Distance')
                end
            end
        else
            if v.Handle:FindFirstChild('NameEsp'..Number) then
                v.Handle:FindFirstChild('NameEsp'..Number):Destroy()
            end
        end
    end)
end
end
function UpdateFlowerChams() 
for i,v in pairs(game.Workspace:GetChildren()) do
    pcall(function()
        if v.Name == "Flower2" or v.Name == "Flower1" then
            if FlowerESP then 
                if not v:FindFirstChild('NameEsp'..Number) then
                    local bill = Instance.new('BillboardGui',v)
                    bill.Name = 'NameEsp'..Number
                    bill.ExtentsOffset = Vector3.new(0, 1, 0)
                    bill.Size = UDim2.new(1,200,1,30)
                    bill.Adornee = v
                    bill.AlwaysOnTop = true
                    local name = Instance.new('TextLabel',bill)
                    name.Font = Enum.Font.GothamSemibold
                    name.FontSize = "Size14"
                    name.TextWrapped = true
                    name.Size = UDim2.new(1,0,1,0)
                    name.TextYAlignment = 'Top'
                    name.BackgroundTransparency = 1
                    name.TextStrokeTransparency = 0.5
                    name.TextColor3 = Color3.fromRGB(255, 0, 0)
                    if v.Name == "Flower1" then 
                        name.Text = ("Blue Flower" ..' \n'.. round((game:GetService('Players').LocalPlayer.Character.Head.Position - v.Position).Magnitude/3) ..' Distance')
                        name.TextColor3 = Color3.fromRGB(0, 0, 255)
                    end
                    if v.Name == "Flower2" then
                        name.Text = ("Red Flower" ..' \n'.. round((game:GetService('Players').LocalPlayer.Character.Head.Position - v.Position).Magnitude/3) ..' Distance')
                        name.TextColor3 = Color3.fromRGB(255, 0, 0)
                    end
                else
                    v['NameEsp'..Number].TextLabel.Text = (v.Name ..'   \n'.. round((game:GetService('Players').LocalPlayer.Character.Head.Position - v.Position).Magnitude/3) ..' Distance')
                end
            else
                if v:FindFirstChild('NameEsp'..Number) then
                v:FindFirstChild('NameEsp'..Number):Destroy()
                end
            end
        end   
    end)
end
end
function UpdateRealFruitChams() 
for i,v in pairs(game.Workspace.AppleSpawner:GetChildren()) do
    if v:IsA("Tool") then
        if RealFruitESP then 
            if not v.Handle:FindFirstChild('NameEsp'..Number) then
                local bill = Instance.new('BillboardGui',v.Handle)
                bill.Name = 'NameEsp'..Number
                bill.ExtentsOffset = Vector3.new(0, 1, 0)
                bill.Size = UDim2.new(1,200,1,30)
                bill.Adornee = v.Handle
                bill.AlwaysOnTop = true
                local name = Instance.new('TextLabel',bill)
                name.Font = Enum.Font.GothamSemibold
                name.FontSize = "Size14"
                name.TextWrapped = true
                name.Size = UDim2.new(1,0,1,0)
                name.TextYAlignment = 'Top'
                name.BackgroundTransparency = 1
                name.TextStrokeTransparency = 0.5
                name.TextColor3 = Color3.fromRGB(255, 0, 0)
                name.Text = (v.Name ..' \n'.. round((game:GetService('Players').LocalPlayer.Character.Head.Position - v.Handle.Position).Magnitude/3) ..' Distance')
            else
                v.Handle['NameEsp'..Number].TextLabel.Text = (v.Name ..' '.. round((game:GetService('Players').LocalPlayer.Character.Head.Position - v.Handle.Position).Magnitude/3) ..' Distance')
            end
        else
            if v.Handle:FindFirstChild('NameEsp'..Number) then
                v.Handle:FindFirstChild('NameEsp'..Number):Destroy()
            end
        end 
    end
end
for i,v in pairs(game.Workspace.PineappleSpawner:GetChildren()) do
    if v:IsA("Tool") then
        if RealFruitESP then 
            if not v.Handle:FindFirstChild('NameEsp'..Number) then
                local bill = Instance.new('BillboardGui',v.Handle)
                bill.Name = 'NameEsp'..Number
                bill.ExtentsOffset = Vector3.new(0, 1, 0)
                bill.Size = UDim2.new(1,200,1,30)
                bill.Adornee = v.Handle
                bill.AlwaysOnTop = true
                local name = Instance.new('TextLabel',bill)
                name.Font = Enum.Font.GothamSemibold
                name.FontSize = "Size14"
                name.TextWrapped = true
                name.Size = UDim2.new(1,0,1,0)
                name.TextYAlignment = 'Top'
                name.BackgroundTransparency = 1
                name.TextStrokeTransparency = 0.5
                name.TextColor3 = Color3.fromRGB(255, 174, 0)
                name.Text = (v.Name ..' \n'.. round((game:GetService('Players').LocalPlayer.Character.Head.Position - v.Handle.Position).Magnitude/3) ..' Distance')
            else
                v.Handle['NameEsp'..Number].TextLabel.Text = (v.Name ..' '.. round((game:GetService('Players').LocalPlayer.Character.Head.Position - v.Handle.Position).Magnitude/3) ..' Distance')
            end
        else
            if v.Handle:FindFirstChild('NameEsp'..Number) then
                v.Handle:FindFirstChild('NameEsp'..Number):Destroy()
            end
        end 
    end
end
for i,v in pairs(game.Workspace.BananaSpawner:GetChildren()) do
    if v:IsA("Tool") then
        if RealFruitESP then 
            if not v.Handle:FindFirstChild('NameEsp'..Number) then
                local bill = Instance.new('BillboardGui',v.Handle)
                bill.Name = 'NameEsp'..Number
                bill.ExtentsOffset = Vector3.new(0, 1, 0)
                bill.Size = UDim2.new(1,200,1,30)
                bill.Adornee = v.Handle
                bill.AlwaysOnTop = true
                local name = Instance.new('TextLabel',bill)
                name.Font = Enum.Font.GothamSemibold
                name.FontSize = "Size14"
                name.TextWrapped = true
                name.Size = UDim2.new(1,0,1,0)
                name.TextYAlignment = 'Top'
                name.BackgroundTransparency = 1
                name.TextStrokeTransparency = 0.5
                name.TextColor3 = Color3.fromRGB(251, 255, 0)
                name.Text = (v.Name ..' \n'.. round((game:GetService('Players').LocalPlayer.Character.Head.Position - v.Handle.Position).Magnitude/3) ..' Distance')
            else
                v.Handle['NameEsp'..Number].TextLabel.Text = (v.Name ..' '.. round((game:GetService('Players').LocalPlayer.Character.Head.Position - v.Handle.Position).Magnitude/3) ..' Distance')
            end
        else
            if v.Handle:FindFirstChild('NameEsp'..Number) then
                v.Handle:FindFirstChild('NameEsp'..Number):Destroy()
            end
        end 
    end
end
end

function UpdateIslandESP() 
    for i,v in pairs(game:GetService("Workspace")["_WorldOrigin"].Locations:GetChildren()) do
        pcall(function()
            if IslandESP then 
                if v.Name ~= "Sea" then
                    if not v:FindFirstChild('NameEsp') then
                        local bill = Instance.new('BillboardGui',v)
                        bill.Name = 'NameEsp'
                        bill.ExtentsOffset = Vector3.new(0, 1, 0)
                        bill.Size = UDim2.new(1,200,1,30)
                        bill.Adornee = v
                        bill.AlwaysOnTop = true
                        local name = Instance.new('TextLabel',bill)
                        name.Font = "GothamBold"
                        name.FontSize = "Size14"
                        name.TextWrapped = true
                        name.Size = UDim2.new(1,0,1,0)
                        name.TextYAlignment = 'Top'
                        name.BackgroundTransparency = 1
                        name.TextStrokeTransparency = 0.5
                        name.TextColor3 = Color3.fromRGB(7, 236, 240)
                    else
                        v['NameEsp'].TextLabel.Text = (v.Name ..'   \n'.. round((game:GetService('Players').LocalPlayer.Character.Head.Position - v.Position).Magnitude/3) ..' Distance')
                    end
                end
            else
                if v:FindFirstChild('NameEsp') then
                    v:FindFirstChild('NameEsp'):Destroy()
                end
            end
        end)
    end
end

function isnil(thing)
return (thing == nil)
end
local function round(n)
return math.floor(tonumber(n) + 0.5)
end
Number = math.random(1, 1000000)
function UpdatePlayerChams()
for i,v in pairs(game:GetService'Players':GetChildren()) do
    pcall(function()
        if not isnil(v.Character) then
            if ESPPlayer then
                if not isnil(v.Character.Head) and not v.Character.Head:FindFirstChild('NameEsp'..Number) then
                    local bill = Instance.new('BillboardGui',v.Character.Head)
                    bill.Name = 'NameEsp'..Number
                    bill.ExtentsOffset = Vector3.new(0, 1, 0)
                    bill.Size = UDim2.new(1,200,1,30)
                    bill.Adornee = v.Character.Head
                    bill.AlwaysOnTop = true
                    local name = Instance.new('TextLabel',bill)
                    name.Font = Enum.Font.GothamSemibold
                    name.FontSize = "Size14"
                    name.TextWrapped = true
                    name.Text = (v.Name ..' \n'.. round((game:GetService('Players').LocalPlayer.Character.Head.Position - v.Character.Head.Position).Magnitude/3) ..' Distance')
                    name.Size = UDim2.new(1,0,1,0)
                    name.TextYAlignment = 'Top'
                    name.BackgroundTransparency = 1
                    name.TextStrokeTransparency = 0.5
                    if v.Team == game.Players.LocalPlayer.Team then
                        name.TextColor3 = Color3.new(0,255,0)
                    else
                        name.TextColor3 = Color3.new(255,0,0)
                    end
                else
                    v.Character.Head['NameEsp'..Number].TextLabel.Text = (v.Name ..' | '.. round((game:GetService('Players').LocalPlayer.Character.Head.Position - v.Character.Head.Position).Magnitude/3) ..' Distance\nHealth : ' .. round(v.Character.Humanoid.Health*100/v.Character.Humanoid.MaxHealth) .. '%')
                end
            else
                if v.Character.Head:FindFirstChild('NameEsp'..Number) then
                    v.Character.Head:FindFirstChild('NameEsp'..Number):Destroy()
                end
            end
        end
    end)
end
end
function UpdateChestChams() 
for i,v in pairs(game.Workspace:GetChildren()) do
    pcall(function()
        if string.find(v.Name,"Chest") then
            if ChestESP then
                if string.find(v.Name,"Chest") then
                    if not v:FindFirstChild('NameEsp'..Number) then
                        local bill = Instance.new('BillboardGui',v)
                        bill.Name = 'NameEsp'..Number
                        bill.ExtentsOffset = Vector3.new(0, 1, 0)
                        bill.Size = UDim2.new(1,200,1,30)
                        bill.Adornee = v
                        bill.AlwaysOnTop = true
                        local name = Instance.new('TextLabel',bill)
                        name.Font = Enum.Font.GothamSemibold
                        name.FontSize = "Size14"
                        name.TextWrapped = true
                        name.Size = UDim2.new(1,0,1,0)
                        name.TextYAlignment = 'Top'
                        name.BackgroundTransparency = 1
                        name.TextStrokeTransparency = 0.5
                        if v.Name == "Chest1" then
                            name.TextColor3 = Color3.fromRGB(109, 109, 109)
                            name.Text = ("Chest 1" ..' \n'.. round((game:GetService('Players').LocalPlayer.Character.Head.Position - v.Position).Magnitude/3) ..' Distance')
                        end
                        if v.Name == "Chest2" then
                            name.TextColor3 = Color3.fromRGB(173, 158, 21)
                            name.Text = ("Chest 2" ..' \n'.. round((game:GetService('Players').LocalPlayer.Character.Head.Position - v.Position).Magnitude/3) ..' Distance')
                        end
                        if v.Name == "Chest3" then
                            name.TextColor3 = Color3.fromRGB(85, 255, 255)
                            name.Text = ("Chest 3" ..' \n'.. round((game:GetService('Players').LocalPlayer.Character.Head.Position - v.Position).Magnitude/3) ..' Distance')
                        end
                    else
                        v['NameEsp'..Number].TextLabel.Text = (v.Name ..'   \n'.. round((game:GetService('Players').LocalPlayer.Character.Head.Position - v.Position).Magnitude/3) ..' Distance')
                    end
                end
            else
                if v:FindFirstChild('NameEsp'..Number) then
                    v:FindFirstChild('NameEsp'..Number):Destroy()
                end
            end
        end
    end)
end
end
function UpdateDevilChams() 
for i,v in pairs(game.Workspace:GetChildren()) do
    pcall(function()
        if DevilFruitESP then
            if string.find(v.Name, "Fruit") then   
                if not v.Handle:FindFirstChild('NameEsp'..Number) then
                    local bill = Instance.new('BillboardGui',v.Handle)
                    bill.Name = 'NameEsp'..Number
                    bill.ExtentsOffset = Vector3.new(0, 1, 0)
                    bill.Size = UDim2.new(1,200,1,30)
                    bill.Adornee = v.Handle
                    bill.AlwaysOnTop = true
                    local name = Instance.new('TextLabel',bill)
                    name.Font = Enum.Font.GothamSemibold
                    name.FontSize = "Size14"
                    name.TextWrapped = true
                    name.Size = UDim2.new(1,0,1,0)
                    name.TextYAlignment = 'Top'
                    name.BackgroundTransparency = 1
                    name.TextStrokeTransparency = 0.5
                    name.TextColor3 = Color3.fromRGB(255, 255, 255)
                    name.Text = (v.Name ..' \n'.. round((game:GetService('Players').LocalPlayer.Character.Head.Position - v.Handle.Position).Magnitude/3) ..' Distance')
                else
                    v.Handle['NameEsp'..Number].TextLabel.Text = (v.Name ..'   \n'.. round((game:GetService('Players').LocalPlayer.Character.Head.Position - v.Handle.Position).Magnitude/3) ..' Distance')
                end
            end
        else
            if v.Handle:FindFirstChild('NameEsp'..Number) then
                v.Handle:FindFirstChild('NameEsp'..Number):Destroy()
            end
        end
    end)
end
end
function UpdateFlowerChams() 
for i,v in pairs(game.Workspace:GetChildren()) do
    pcall(function()
        if v.Name == "Flower2" or v.Name == "Flower1" then
            if FlowerESP then 
                if not v:FindFirstChild('NameEsp'..Number) then
                    local bill = Instance.new('BillboardGui',v)
                    bill.Name = 'NameEsp'..Number
                    bill.ExtentsOffset = Vector3.new(0, 1, 0)
                    bill.Size = UDim2.new(1,200,1,30)
                    bill.Adornee = v
                    bill.AlwaysOnTop = true
                    local name = Instance.new('TextLabel',bill)
                    name.Font = Enum.Font.GothamSemibold
                    name.FontSize = "Size14"
                    name.TextWrapped = true
                    name.Size = UDim2.new(1,0,1,0)
                    name.TextYAlignment = 'Top'
                    name.BackgroundTransparency = 1
                    name.TextStrokeTransparency = 0.5
                    name.TextColor3 = Color3.fromRGB(255, 0, 0)
                    if v.Name == "Flower1" then 
                        name.Text = ("Blue Flower" ..' \n'.. round((game:GetService('Players').LocalPlayer.Character.Head.Position - v.Position).Magnitude/3) ..' Distance')
                        name.TextColor3 = Color3.fromRGB(0, 0, 255)
                    end
                    if v.Name == "Flower2" then
                        name.Text = ("Red Flower" ..' \n'.. round((game:GetService('Players').LocalPlayer.Character.Head.Position - v.Position).Magnitude/3) ..' Distance')
                        name.TextColor3 = Color3.fromRGB(255, 0, 0)
                    end
                else
                    v['NameEsp'..Number].TextLabel.Text = (v.Name ..'   \n'.. round((game:GetService('Players').LocalPlayer.Character.Head.Position - v.Position).Magnitude/3) ..' Distance')
                end
            else
                if v:FindFirstChild('NameEsp'..Number) then
                v:FindFirstChild('NameEsp'..Number):Destroy()
                end
            end
        end   
    end)
end
end
function UpdateRealFruitChams() 
for i,v in pairs(game.Workspace.AppleSpawner:GetChildren()) do
    if v:IsA("Tool") then
        if RealFruitESP then 
            if not v.Handle:FindFirstChild('NameEsp'..Number) then
                local bill = Instance.new('BillboardGui',v.Handle)
                bill.Name = 'NameEsp'..Number
                bill.ExtentsOffset = Vector3.new(0, 1, 0)
                bill.Size = UDim2.new(1,200,1,30)
                bill.Adornee = v.Handle
                bill.AlwaysOnTop = true
                local name = Instance.new('TextLabel',bill)
                name.Font = Enum.Font.GothamSemibold
                name.FontSize = "Size14"
                name.TextWrapped = true
                name.Size = UDim2.new(1,0,1,0)
                name.TextYAlignment = 'Top'
                name.BackgroundTransparency = 1
                name.TextStrokeTransparency = 0.5
                name.TextColor3 = Color3.fromRGB(255, 0, 0)
                name.Text = (v.Name ..' \n'.. round((game:GetService('Players').LocalPlayer.Character.Head.Position - v.Handle.Position).Magnitude/3) ..' Distance')
            else
                v.Handle['NameEsp'..Number].TextLabel.Text = (v.Name ..' '.. round((game:GetService('Players').LocalPlayer.Character.Head.Position - v.Handle.Position).Magnitude/3) ..' Distance')
            end
        else
            if v.Handle:FindFirstChild('NameEsp'..Number) then
                v.Handle:FindFirstChild('NameEsp'..Number):Destroy()
            end
        end 
    end
end
for i,v in pairs(game.Workspace.PineappleSpawner:GetChildren()) do
    if v:IsA("Tool") then
        if RealFruitESP then 
            if not v.Handle:FindFirstChild('NameEsp'..Number) then
                local bill = Instance.new('BillboardGui',v.Handle)
                bill.Name = 'NameEsp'..Number
                bill.ExtentsOffset = Vector3.new(0, 1, 0)
                bill.Size = UDim2.new(1,200,1,30)
                bill.Adornee = v.Handle
                bill.AlwaysOnTop = true
                local name = Instance.new('TextLabel',bill)
                name.Font = Enum.Font.GothamSemibold
                name.FontSize = "Size14"
                name.TextWrapped = true
                name.Size = UDim2.new(1,0,1,0)
                name.TextYAlignment = 'Top'
                name.BackgroundTransparency = 1
                name.TextStrokeTransparency = 0.5
                name.TextColor3 = Color3.fromRGB(255, 174, 0)
                name.Text = (v.Name ..' \n'.. round((game:GetService('Players').LocalPlayer.Character.Head.Position - v.Handle.Position).Magnitude/3) ..' Distance')
            else
                v.Handle['NameEsp'..Number].TextLabel.Text = (v.Name ..' '.. round((game:GetService('Players').LocalPlayer.Character.Head.Position - v.Handle.Position).Magnitude/3) ..' Distance')
            end
        else
            if v.Handle:FindFirstChild('NameEsp'..Number) then
                v.Handle:FindFirstChild('NameEsp'..Number):Destroy()
            end
        end 
    end
end
for i,v in pairs(game.Workspace.BananaSpawner:GetChildren()) do
    if v:IsA("Tool") then
        if RealFruitESP then 
            if not v.Handle:FindFirstChild('NameEsp'..Number) then
                local bill = Instance.new('BillboardGui',v.Handle)
                bill.Name = 'NameEsp'..Number
                bill.ExtentsOffset = Vector3.new(0, 1, 0)
                bill.Size = UDim2.new(1,200,1,30)
                bill.Adornee = v.Handle
                bill.AlwaysOnTop = true
                local name = Instance.new('TextLabel',bill)
                name.Font = Enum.Font.GothamSemibold
                name.FontSize = "Size14"
                name.TextWrapped = true
                name.Size = UDim2.new(1,0,1,0)
                name.TextYAlignment = 'Top'
                name.BackgroundTransparency = 1
                name.TextStrokeTransparency = 0.5
                name.TextColor3 = Color3.fromRGB(251, 255, 0)
                name.Text = (v.Name ..' \n'.. round((game:GetService('Players').LocalPlayer.Character.Head.Position - v.Handle.Position).Magnitude/3) ..' Distance')
            else
                v.Handle['NameEsp'..Number].TextLabel.Text = (v.Name ..' '.. round((game:GetService('Players').LocalPlayer.Character.Head.Position - v.Handle.Position).Magnitude/3) ..' Distance')
            end
        else
            if v.Handle:FindFirstChild('NameEsp'..Number) then
                v.Handle:FindFirstChild('NameEsp'..Number):Destroy()
            end
        end 
    end
end
end

spawn(function()
while wait() do
    pcall(function()
        if MobESP then
            for i,v in pairs(game:GetService("Workspace").Enemies:GetChildren()) do
                if v:FindFirstChild('HumanoidRootPart') then
                    if not v:FindFirstChild("MobEap") then
                        local BillboardGui = Instance.new("BillboardGui")
                        local TextLabel = Instance.new("TextLabel")

                        BillboardGui.Parent = v
                        BillboardGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
                        BillboardGui.Active = true
                        BillboardGui.Name = "MobEap"
                        BillboardGui.AlwaysOnTop = true
                        BillboardGui.LightInfluence = 1.000
                        BillboardGui.Size = UDim2.new(0, 200, 0, 50)
                        BillboardGui.StudsOffset = Vector3.new(0, 2.5, 0)

                        TextLabel.Parent = BillboardGui
                        TextLabel.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
                        TextLabel.BackgroundTransparency = 1.000
                        TextLabel.Size = UDim2.new(0, 200, 0, 50)
                        TextLabel.Font = Enum.Font.GothamBold
                        TextLabel.TextColor3 = Color3.fromRGB(7, 236, 240)
                        TextLabel.Text.Size = 35
                    end
                    local Dis = math.floor((game.Players.LocalPlayer.Character.HumanoidRootPart.Position - v.HumanoidRootPart.Position).Magnitude)
                    v.MobEap.TextLabel.Text = v.Name.." - "..Dis.." Distance"
                end
            end
        else
            for i,v in pairs(game:GetService("Workspace").Enemies:GetChildren()) do
                if v:FindFirstChild("MobEap") then
                    v.MobEap:Destroy()
                end
            end
        end
    end)
end
end)

spawn(function()
while wait() do
    pcall(function()
        if SeaESP then
            for i,v in pairs(game:GetService("Workspace").SeaBeasts:GetChildren()) do
                if v:FindFirstChild('HumanoidRootPart') then
                    if not v:FindFirstChild("Seaesps") then
                        local BillboardGui = Instance.new("BillboardGui")
                        local TextLabel = Instance.new("TextLabel")

                        BillboardGui.Parent = v
                        BillboardGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
                        BillboardGui.Active = true
                        BillboardGui.Name = "Seaesps"
                        BillboardGui.AlwaysOnTop = true
                        BillboardGui.LightInfluence = 1.000
                        BillboardGui.Size = UDim2.new(0, 200, 0, 50)
                        BillboardGui.StudsOffset = Vector3.new(0, 2.5, 0)

                        TextLabel.Parent = BillboardGui
                        TextLabel.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
                        TextLabel.BackgroundTransparency = 1.000
                        TextLabel.Size = UDim2.new(0, 200, 0, 50)
                        TextLabel.Font = Enum.Font.GothamBold
                        TextLabel.TextColor3 = Color3.fromRGB(7, 236, 240)
                        TextLabel.Text.Size = 35
                    end
                    local Dis = math.floor((game.Players.LocalPlayer.Character.HumanoidRootPart.Position - v.HumanoidRootPart.Position).Magnitude)
                    v.Seaesps.TextLabel.Text = v.Name.." - "..Dis.." Distance"
                end
            end
        else
            for i,v in pairs (game:GetService("Workspace").SeaBeasts:GetChildren()) do
                if v:FindFirstChild("Seaesps") then
                    v.Seaesps:Destroy()
                end
            end
        end
    end)
end
end)

spawn(function()
while wait() do
    pcall(function()
        if NpcESP then
            for i,v in pairs(game:GetService("Workspace").NPCs:GetChildren()) do
                if v:FindFirstChild('HumanoidRootPart') then
                    if not v:FindFirstChild("NpcEspes") then
                        local BillboardGui = Instance.new("BillboardGui")
                        local TextLabel = Instance.new("TextLabel")

                        BillboardGui.Parent = v
                        BillboardGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
                        BillboardGui.Active = true
                        BillboardGui.Name = "NpcEspes"
                        BillboardGui.AlwaysOnTop = true
                        BillboardGui.LightInfluence = 1.000
                        BillboardGui.Size = UDim2.new(0, 200, 0, 50)
                        BillboardGui.StudsOffset = Vector3.new(0, 2.5, 0)

                        TextLabel.Parent = BillboardGui
                        TextLabel.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
                        TextLabel.BackgroundTransparency = 1.000
                        TextLabel.Size = UDim2.new(0, 200, 0, 50)
                        TextLabel.Font = Enum.Font.GothamBold
                        TextLabel.TextColor3 = Color3.fromRGB(7, 236, 240)
                        TextLabel.Text.Size = 35
                    end
                    local Dis = math.floor((game.Players.LocalPlayer.Character.HumanoidRootPart.Position - v.HumanoidRootPart.Position).Magnitude)
                    v.NpcEspes.TextLabel.Text = v.Name.." - "..Dis.." Distance"
                end
            end
        else
            for i,v in pairs (game:GetService("Workspace").NPCs:GetChildren()) do
                if v:FindFirstChild("NpcEspes") then
                    v.NpcEspes:Destroy()
                end
            end
        end
    end)
end
end)

function isnil(thing)
return (thing == nil)
end
local function round(n)
return math.floor(tonumber(n) + 0.5)
end
Number = math.random(1, 1000000)

function UpdateIslandMirageESP() 
for i,v in pairs(game:GetService("Workspace")["_WorldOrigin"].Locations:GetChildren()) do
    pcall(function()
        if MirageIslandESP then 
            if v.Name == "Mirage Island" then
                if not v:FindFirstChild('NameEsp') then
                    local bill = Instance.new('BillboardGui',v)
                    bill.Name = 'NameEsp'
                    bill.ExtentsOffset = Vector3.new(0, 1, 0)
                    bill.Size = UDim2.new(1,200,1,30)
                    bill.Adornee = v
                    bill.AlwaysOnTop = true
                    local name = Instance.new('TextLabel',bill)
                    name.Font = "Code"
                    name.FontSize = "Size14"
                    name.TextWrapped = true
                    name.Size = UDim2.new(1,0,1,0)
                    name.TextYAlignment = 'Top'
                    name.BackgroundTransparency = 1
                    name.TextStrokeTransparency = 0.5
                    name.TextColor3 = Color3.fromRGB(80, 245, 245)
                else
                    v['NameEsp'].TextLabel.Text = (v.Name ..'   \n'.. round((game:GetService('Players').LocalPlayer.Character.Head.Position - v.Position).Magnitude/3) ..' M')
                end
            end
        else
            if v:FindFirstChild('NameEsp') then
                v:FindFirstChild('NameEsp'):Destroy()
            end
        end
    end)
end
end

function isnil(thing)
return (thing == nil)
end
local function round(n)
return math.floor(tonumber(n) + 0.5)
end
Number = math.random(1, 1000000)

function UpdateAfdESP() 
for i,v in pairs(game:GetService("Workspace").NPCs:GetChildren()) do
    pcall(function()
        if AfdESP then 
            if v.Name == "Advanced Fruit Dealer" then
                if not v:FindFirstChild('NameEsp') then
                    local bill = Instance.new('BillboardGui',v)
                    bill.Name = 'NameEsp'
                    bill.ExtentsOffset = Vector3.new(0, 1, 0)
                    bill.Size = UDim2.new(1,200,1,30)
                    bill.Adornee = v
                    bill.AlwaysOnTop = true
                    local name = Instance.new('TextLabel',bill)
                    name.Font = "Code"
                    name.FontSize = "Size14"
                    name.TextWrapped = true
                    name.Size = UDim2.new(1,0,1,0)
                    name.TextYAlignment = 'Top'
                    name.BackgroundTransparency = 1
                    name.TextStrokeTransparency = 0.5
                    name.TextColor3 = Color3.fromRGB(80, 245, 245)
                else
                    v['NameEsp'].TextLabel.Text = (v.Name ..'   \n'.. round((game:GetService('Players').LocalPlayer.Character.Head.Position - v.Position).Magnitude/3) ..' M')
                end
            end
        else
            if v:FindFirstChild('NameEsp') then
                v:FindFirstChild('NameEsp'):Destroy()
            end
        end
    end)
end
end

function UpdateAuraESP() 
for i,v in pairs(game:GetService("Workspace").NPCs:GetChildren()) do
    pcall(function()
        if AuraESP then 
            if v.Name == "Master of Enhancement" then
                if not v:FindFirstChild('NameEsp') then
                    local bill = Instance.new('BillboardGui',v)
                    bill.Name = 'NameEsp'
                    bill.ExtentsOffset = Vector3.new(0, 1, 0)
                    bill.Size = UDim2.new(1,200,1,30)
                    bill.Adornee = v
                    bill.AlwaysOnTop = true
                    local name = Instance.new('TextLabel',bill)
                    name.Font = "Code"
                    name.FontSize = "Size14"
                    name.TextWrapped = true
                    name.Size = UDim2.new(1,0,1,0)
                    name.TextYAlignment = 'Top'
                    name.BackgroundTransparency = 1
                    name.TextStrokeTransparency = 0.5
                    name.TextColor3 = Color3.fromRGB(80, 245, 245)
                else
                    v['NameEsp'].TextLabel.Text = (v.Name ..'   \n'.. round((game:GetService('Players').LocalPlayer.Character.Head.Position - v.Position).Magnitude/3) ..' M')
                end
            end
        else
            if v:FindFirstChild('NameEsp') then
                v:FindFirstChild('NameEsp'):Destroy()
            end
        end
    end)
end
end

function UpdateLSDESP() 
for i,v in pairs(game:GetService("Workspace").NPCs:GetChildren()) do
    pcall(function()
        if LADESP then 
            if v.Name == "Legendary Sword Dealer" then
                if not v:FindFirstChild('NameEsp') then
                    local bill = Instance.new('BillboardGui',v)
                    bill.Name = 'NameEsp'
                    bill.ExtentsOffset = Vector3.new(0, 1, 0)
                    bill.Size = UDim2.new(1,200,1,30)
                    bill.Adornee = v
                    bill.AlwaysOnTop = true
                    local name = Instance.new('TextLabel',bill)
                    name.Font = "Code"
                    name.FontSize = "Size14"
                    name.TextWrapped = true
                    name.Size = UDim2.new(1,0,1,0)
                    name.TextYAlignment = 'Top'
                    name.BackgroundTransparency = 1
                    name.TextStrokeTransparency = 0.5
                    name.TextColor3 = Color3.fromRGB(80, 245, 245)
                else
                    v['NameEsp'].TextLabel.Text = (v.Name ..'   \n'.. round((game:GetService('Players').LocalPlayer.Character.Head.Position - v.Position).Magnitude/3) ..' M')
                end
            end
        else
            if v:FindFirstChild('NameEsp') then
                v:FindFirstChild('NameEsp'):Destroy()
            end
        end
    end)
end
end

function UpdateGeaESP() 
for i,v in pairs(game:GetService("Workspace").Map.MysticIsland:GetChildren()) do 
    pcall(function()
        if GearESP then 
            if v.Name == "MeshPart" then
                if not v:FindFirstChild('NameEsp') then
                    local bill = Instance.new('BillboardGui',v)
                    bill.Name = 'NameEsp'
                    bill.ExtentsOffset = Vector3.new(0, 1, 0)
                    bill.Size = UDim2.new(1,200,1,30)
                    bill.Adornee = v
                    bill.AlwaysOnTop = true
                    local name = Instance.new('TextLabel',bill)
                    name.Font = "Code"
                    name.FontSize = "Size14"
                    name.TextWrapped = true
                    name.Size = UDim2.new(1,0,1,0)
                    name.TextYAlignment = 'Top'
                    name.BackgroundTransparency = 1
                    name.TextStrokeTransparency = 0.5
                    name.TextColor3 = Color3.fromRGB(80, 245, 245)
                else
                    v['NameEsp'].TextLabel.Text = (v.Name ..'   \n'.. round((game:GetService('Players').LocalPlayer.Character.Head.Position - v.Position).Magnitude/3) ..' M')
                end
            end
        else
            if v:FindFirstChild('NameEsp') then
                v:FindFirstChild('NameEsp'):Destroy()
            end
        end
    end)
end
end

----------Tween




    
        --// Tween Island
        function TP2(P1)
        local Distance = (P1.Position - game.Players.LocalPlayer.Character.HumanoidRootPart.Position).Magnitude
        if Distance >= 1 then
        Speed = 350
        end
        game:GetService("TweenService"):Create(game.Players.LocalPlayer.Character.HumanoidRootPart,TweenInfo.new(Distance/Speed, Enum.EasingStyle.Linear), {
          CFrame = P1
        }):Play()
        if _G.CancelTween2 then
        game:GetService("TweenService"):Create(game.Players.LocalPlayer.Character.HumanoidRootPart,TweenInfo.new(Distance/Speed, Enum.EasingStyle.Linear), {
          CFrame = P1
        }):Cancel()
        end
        _G.Clip2 = true
        wait(Distance/Speed)
        _G.Clip2 = false
        end



 function Tween(Pos)
        Distance = (Pos.Position - game.Players.LocalPlayer.Character.HumanoidRootPart.Position).Magnitude
        if game.Players.LocalPlayer.Character.Humanoid.Sit == true then game.Players.LocalPlayer.Character.Humanoid.Sit = true end
        pcall(function() tween = game:GetService("TweenService"):Create(game.Players.LocalPlayer.Character.HumanoidRootPart,TweenInfo.new(Distance/350, Enum.EasingStyle.Linear),{CFrame = Pos}) end)
        tween:Play()
        if Distance <= 350 then
            tween:Cancel()
            game.Players.LocalPlayer.Character.HumanoidRootPart.CFrame = Pos
        end
        if _G.StopTween == true then
            tween:Cancel()
            _G.Clip = false
        end
    end
    
    --function TP to Boat/Ship
    function TPB(CFgo)
        local tween_s = game:service"TweenService"
        local info = TweenInfo.new((game:GetService("Workspace").Boats.MarineBrigade.VehicleSeat.CFrame.Position - CFgo.Position).Magnitude/300, Enum.EasingStyle.Linear)
        tween = tween_s:Create(game:GetService("Workspace").Boats.MarineBrigade.VehicleSeat, info, {CFrame = CFgo})
        tween:Play()
    
        local tweenfunc = {}
    
        function tweenfunc:Stop()
            tween:Cancel()
        end
    
        return tweenfunc
    end
    
    function TPP(CFgo)
        if game.Players.LocalPlayer.Character:WaitForChild("Humanoid").Health <= 0 or not game:GetService("Players").LocalPlayer.Character:WaitForChild("Humanoid") then tween:Cancel() repeat wait() until game:GetService("Players").LocalPlayer.Character:WaitForChild("Humanoid") and game:GetService("Players").LocalPlayer.Character:WaitForChild("Humanoid").Health > 0 wait(7) return end
        local tween_s = game:service"TweenService"
        local info = TweenInfo.new((game:GetService("Players")["LocalPlayer"].Character.HumanoidRootPart.Position - CFgo.Position).Magnitude/325, Enum.EasingStyle.Linear)
        tween = tween_s:Create(game.Players.LocalPlayer.Character["HumanoidRootPart"], info, {CFrame = CFgo})
        tween:Play()
    
        local tweenfunc = {}
    
        function tweenfunc:Stop()
            tween:Cancel()
        end
    
        return tweenfunc
    end

 
--select weapon
function EquipTool(ToolSe)
		if game.Players.LocalPlayer.Backpack:FindFirstChild(ToolSe) then
			local tool = game.Players.LocalPlayer.Backpack:FindFirstChild(ToolSe)
			wait(0.4)
			game.Players.LocalPlayer.Character.Humanoid:EquipTool(tool)
		end
	end


    --aimbot mastery
	spawn(function()
		local gg = getrawmetatable(game)
		local old = gg.__namecall
		setreadonly(gg,false)
		gg.__namecall = newcclosure(function(...)
		  local method = getnamecallmethod()
		  local args = {
			...
		  }
		  if tostring(method) == "FireServer" then
		  if tostring(args[1]) == "RemoteEvent" then
		  if tostring(args[2]) ~= "true" and tostring(args[2]) ~= "false" then
		  if _G.UseSkill then
		  if type(args[2]) == "vector" then
		  args[2] = PositionSkillMasteryDevilFruit
		  else
			args[2] = CFrame.new(PositionSkillMasteryDevilFruit)
		  end
		  return old(unpack(args))
		  end
		  end
		  end
		  end
		  return old(...)
		  end)
		end)
	  
--Equip Gun
spawn(function()
  pcall(function()
    while task.wait() do
    for i,v in pairs(game:GetService("Players").LocalPlayer.Backpack:GetChildren()) do
    if v:IsA("Tool") then
    if v:FindFirstChild("RemoteFunctionShoot") then
    CurrentEquipGun = v.Name
    end
    end
    end
    end
    end)
  end)



-- [Body Gyro]
   spawn(function()
			while task.wait() do
				pcall(function()
					if _G.TeleportIsland or _G.AutoQuestRace or _G.AutoBuyBoat or _G.dao or _G.AutoMirage or AutoFarmAcient or _G.AutoQuestRace or Auto_Law or _G.AutoAllBoss or _G.Autotushita or _G.AutoHolyTorch or _G.AutoTerrorshark or _G.farmpiranya or _G.DriveMytic or _G.AutoDoughKingV2 or PirateShip or _G.AutoSeaBeast or _G.AutoNear or _G.BossRaid or _G.GrabChest or AutoCitizen or _G.Ecto or AutoEvoRace or AutoBartilo or AutoFactory or BringChestz or BringFruitz or _G.AutoLevel or _G.Clip2 or AutoFarmNoQuest or _G.AutoBone or AutoFarmSelectMonsterQuest or AutoFarmSelectMonsterNoQuest or _G.AutoBoss or AutoFarmBossQuest or AutoFarmMasGun or AutoFarmMasDevilFruit or AutoFarmSelectArea or AutoSecondSea or AutoThirdSea or AutoDeathStep or AutoSuperhuman or AutoSharkman or AutoElectricClaw or AutoDragonTalon or AutoGodhuman or AutoRengoku or AutoBuddySword or AutoPole or AutoHallowSycthe or AutoCavander or AutoTushita or AutoDarkDagger or _G.CakePrince or _G.AutoElite or AutoRainbowHaki or AutoSaber or AutoFarmKen or AutoKenHop or AutoKenV2 or KillPlayerMelee or KillPlayerGun or KillPlayerFruit or AutoDungeon or AutoNextIsland or AutoAdvanceDungeon or Musketeer or RipIndra or Auto_Serpent_Bow or AutoTorch or AutoSoulGuitar or Auto_Cursed_Dual_Katana or _G.AutoMaterial or Auto_Quest_Yama_1 or Auto_Quest_Yama_2 or Auto_Quest_Yama_3 or Auto_Quest_Tushita_1 or Auto_Quest_Tushita_2 or Auto_Quest_Tushita_3 or _G.Factory or _G.SwanGlasses or AutoBartilo or AutoEvoRace or _G.Ecto then
						if not game:GetService("Players").LocalPlayer.Character.HumanoidRootPart:FindFirstChild("BodyClip") then
							local Noclip = Instance.new("BodyVelocity")
							Noclip.Name = "BodyClip"
							Noclip.Parent = game:GetService("Players").LocalPlayer.Character.HumanoidRootPart
							Noclip.MaxForce = Vector3.new(100000,100000,100000)
							Noclip.Velocity = Vector3.new(0,0,0)
						end
					else
						game:GetService("Players").LocalPlayer.Character.HumanoidRootPart:FindFirstChild("BodyClip"):Destroy()
					end
				end)
			end
		end)

	
--//No CLip Auto Farm
spawn(function()
  pcall(function()
    game:GetService("RunService").Stepped:Connect(function()
      if _G.TeleportIsland or _G.AutoQuestRace or _G.AutoBuyBoat or _G.dao or AutoFarmAcient or _G.AutoMirage or Auto_Law or _G.AutoQuestRace or _G.AutoAllBoss or _G.AutoHolyTorch or _G.Autotushita or _G.farmpiranya or _G.AutoTerrorshark or _G.AutoNear or _G.AutoDoughKingV2 or PirateShip or _G.AutoSeaBeast or _G.DriveMytic or _G.BossRaid or _G.GrabChest or AutoCitizen or _G.Ecto or AutoEvoRace or AutoBartilo or AutoFactory or BringChestz or BringFruitz or _G.AutoLevel or _G.Clip2 or AutoFarmNoQuest or _G.AutoBone or AutoFarmSelectMonsterQuest or AutoFarmSelectMonsterNoQuest or _G.AutoBoss or AutoFarmBossQuest or AutoFarmMasGun or AutoFarmMasDevilFruit or AutoFarmSelectArea or AutoSecondSea or AutoThirdSea or AutoDeathStep or AutoSuperhuman or AutoSharkman or AutoElectricClaw or AutoDragonTalon or AutoGodhuman or AutoRengoku or AutoBuddySword or AutoPole or AutoHallowSycthe or AutoCavander or AutoTushita or AutoDarkDagger or _G.CakePrince or _G.AutoElite or AutoRainbowHaki or AutoSaber or AutoFarmKen or AutoKenHop or AutoKenV2 or KillPlayerMelee or KillPlayerGun or KillPlayerFruit or AutoDungeon or AutoNextIsland or AutoAdvanceDungeon or Musketeer or RipIndra or Auto_Serpent_Bow or AutoTorch or AutoSoulGuitar or Auto_Cursed_Dual_Katana or _G.AutoMaterial or Auto_Quest_Yama_1 or Auto_Quest_Yama_2 or Auto_Quest_Yama_3 or Auto_Quest_Tushita_1 or Auto_Quest_Tushita_2 or Auto_Quest_Tushita_3 or _G.Factory or _G.SwanGlasses or AutoBartilo or AutoEvoRace or _G.Ecto then
      for i,v in pairs(game:GetService("Players").LocalPlayer.Character:GetDescendants()) do
      if v:IsA("BasePart") then
      v.CanCollide = false
      end
      end
      end
      end)
    end)
  end)


--Check Material
function CheckMaterial(matname)
for i,v in pairs(game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("getInventory")) do
if type(v) == "table" then
if v.Type == "Material" then
if v.Name == matname then
return v.Count
end
end
end
end
return 0
end

-----Click

function Click()
	if not _G.FastAttack then
		local Module = require(game.Players.LocalPlayer.PlayerScripts.CombatFramework)
		local CombatFramework = debug.getupvalues(Module)[2]
		local CamShake = require(game.ReplicatedStorage.Util.CameraShaker)
		CamShake:Stop()
		CombatFramework.activeController.attacking = false
		CombatFramework.activeController.timeToNextAttack = 0
		CombatFramework.activeController.hitboxMagnitude = 180
		game:GetService'VirtualUser':CaptureController()
		game:GetService'VirtualUser':Button1Down(Vector2.new(1280, 672))
	end
end

--Attack Mastery
    function NormalAttack()
        if not _G.NormalAttack then
            local Module = require(game.Players.LocalPlayer.PlayerScripts.CombatFramework)
            local CombatFramework = debug.getupvalues(Module)[2]
            local CamShake = require(game.ReplicatedStorage.Util.CameraShaker)
            CamShake:Stop()
            CombatFramework.activeController.attacking = false
            CombatFramework.activeController.timeToNextAttack = 0
            CombatFramework.activeController.hitboxMagnitude = 180
            game:GetService'VirtualUser':CaptureController()
            game:GetService'VirtualUser':Button1Down(Vector2.new(1280, 672))
        end
    end


--Sword Weapon
function GetWeaponInventory(Weaponname)
for i,v in pairs(game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("getInventory")) do
if type(v) == "table" then
if v.Type == "Sword" then
if v.Name == Weaponname then
return true
end
end
end
end
return false
end




---Method Wait Mob
Type11 = 1
spawn(function()
    while wait(.1) do
        if Type1 == 1 then
            Pos2 = CFrame.new(120,60,0)
        elseif Type1 == 2 then
            Pos2 = CFrame.new(-120,60,0)
        end
        end
    end)

spawn(function()
    while wait(.1) do
        Type1 = 1
        wait(2)
        Type1 = 2
        wait(2)
    end
end)


---Method Farm
Type1 = 1
spawn(function()
    while wait(.1) do
        if Type == 1 then
            Pos = CFrame.new(0,60,0)
        elseif Type == 2 then
            Pos = CFrame.new(-30,0,-30)
        elseif Type == 3 then
            Pos = CFrame.new(0,0,-60)
        elseif Type == 4 then
            Pos = CFrame.new(-60,0,0)	
        end
        end
    end)

spawn(function()
    while wait(.1) do
        Type = 1
        wait(1)
        Type = 2
        wait(1)
        Type = 3
        wait(1)
        Type = 4
        wait(1)
    end
end)

  function AutoHaki()
    if not game:GetService("Players").LocalPlayer.Character:FindFirstChild("HasBuso") then
        game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("Buso")
    end
end
---Bypass Teleport
function BTP(P)
    if game.Players.LocalPlayer.Character.Humanoid.Health > 0 then 
  game.Players.LocalPlayer.Character.Humanoid:ChangeState(15)
    end
    if game.Players.LocalPlayer.Character.Humanoid.Health == 0 then 
    repeat wait(0.05)
        game.Players.LocalPlayer.Character.Humanoid:ChangeState(15)
        game.Players.LocalPlayer.Character.HumanoidRootPart.CFrame = P
      until (P.Position - game.Players.LocalPlayer.Character.HumanoidRootPart.Position).Magnitude <= 2000
  end
end

function BTP(p)
    pcall(function()
        local character = game.Players.LocalPlayer.Character
        local humanoidRootPart = character.HumanoidRootPart
        local humanoid = character.Humanoid

        if (p.Position - humanoidRootPart.Position).Magnitude >= 2000 and not Auto_Raid and humanoid.Health > 0 then
        if NQuest == "FishmanQuest" then
          Tween(game.Players.LocalPlayer.Character.HumanoidRootPart.CFrame)
          wait(0.0075)
          game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("requestEntrance",Vector3.new(61163.8515625, 11.6796875, 1819.7841796875))
        elseif Mon == "God's Guard"  then
          Tween(game.Players.LocalPlayer.Character.HumanoidRootPart.CFrame)
          wait(0.0075)
          game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("requestEntrance",Vector3.new(-4607.82275, 872.54248, -1667.55688))
        elseif NQuest == "SkyExp1Quest" then
          Tween(game.Players.LocalPlayer.Character.HumanoidRootPart.CFrame)
          wait(0.0075)
          game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("requestEntrance",Vector3.new(-7894.6176757813, 5547.1416015625, -380.29119873047))
        elseif NQuest == "ShipQuest1" then
          Tween(game.Players.LocalPlayer.Character.HumanoidRootPart.CFrame)
          wait(0.0075)
          game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("requestEntrance",Vector3.new(923.21252441406, 126.9760055542, 32852.83203125))
        elseif NQuest == "ShipQuest2" then
          Tween(game.Players.LocalPlayer.Character.HumanoidRootPart.CFrame)
          wait(0.0075)
          game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("requestEntrance",Vector3.new(923.21252441406, 126.9760055542, 32852.83203125))
        elseif NQuest == "FrostQuest" then
          Tween(game.Players.LocalPlayer.Character.HumanoidRootPart.CFrame)
          wait(0.0075)
          game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("requestEntrance",Vector3.new(-6508.5581054688, 89.034996032715, -132.83953857422))
            else
                Mix_Farm = true
                repeat
                    wait(0.05)
                    humanoidRootPart.CFrame = p
                    wait(0.05)
                    humanoidRootPart.CFrame = p
                until (p.Position - humanoidRootPart.Position).Magnitude < 1500 and humanoid.Health > 0
                wait(0.0075)
                Mix_Farm = nil
            end
        end
    end)
end
-- Anti Kick 70%
function AntiKick()
    for i,v in pairs(game:GetService("Players").LocalPlayer.Character:GetDescendants()) do
        if v:IsA("LocalScript") then
            if v.Name == "General" or v.Name == "Shiftlock"  or v.Name == "FallDamage" or v.Name == "4444" or v.Name == "CamBob" or v.Name == "JumpCD" or v.Name == "Looking" or v.Name == "Run" then
                v:Destroy()
            end
        end
     end
     for i,v in pairs(game:GetService("Players").LocalPlayer.PlayerScripts:GetDescendants()) do
        if v:IsA("LocalScript") then
            if v.Name == "RobloxMotor6DBugFix" or v.Name == "Clans"  or v.Name == "Codes" or v.Name == "CustomForceField" or v.Name == "MenuBloodSp"  or v.Name == "PlayerList" then
                v:Destroy()
            end
        end
    end
end
AntiKick()







--------------------------------------------------------------------------------------------------------------------------------------------
-- Hehe
local posX = 0
local posY = 60
local posZ = 0
--------------------------------------------------------------------------------------------------------------------------------------------

local listfastattack = {'Normal Attack','Fast Attack','Super Attack'}

    local DropdownDelayAttack = Tabs.Main:AddDropdown("DropdownDelayAttack", {
        Title = "Fast Attack  ",
        Description = "",
        Values = listfastattack,
        Multi = false,
        Default = 1,
    })
    DropdownDelayAttack:SetValue("Fast Attack")
    DropdownDelayAttack:OnChanged(function(Value)
    _G.SelectSpeedFast = Value
	if _G.FastAttackheheHub == "Fast Attack" then
		_G.Fast_Delay = 0.07
	elseif _G.FastAttackheheHub == "Normal Attack" then
		_G.Fast_Delay = 0.12
	elseif _G.FastAttackheheHub == "Super Attack" then
		_G.Fast_Delay = 0.02
	end
end)
local CombatFramework = require(game:GetService("Players").LocalPlayer.PlayerScripts:WaitForChild("CombatFramework"))
local CombatFrameworkR = getupvalues(CombatFramework)[2]
local RigController = require(game:GetService("Players")["LocalPlayer"].PlayerScripts.CombatFramework.RigController)
local RigControllerR = getupvalues(RigController)[2]
function CurrentWeapon()
	local ac = CombatFrameworkR.activeController
	local ret = ac.blades[1]
	if not ret then return game.Players.LocalPlayer.Character:FindFirstChildOfClass("Tool").Name end
	pcall(function()
		while ret.Parent~=game.Players.LocalPlayer.Character do ret=ret.Parent end
	end)
	if not ret then return game.Players.LocalPlayer.Character:FindFirstChildOfClass("Tool").Name end
	return ret
end
function getAllBladeHitsPlayers(Sizes)
	local Hits = {}
	local Client = game.Players.LocalPlayer
	local Characters = game:GetService("Workspace").Characters:GetChildren()
	for i=1,#Characters do local v = Characters[i]
		local Human = v:FindFirstChildOfClass("Humanoid")
		if v.Name ~= game.Players.LocalPlayer.Name and Human and Human.RootPart and Human.Health > 0 and Client:DistanceFromCharacter(Human.RootPart.Position) < Sizes+5 then
			table.insert(Hits,Human.RootPart)
		end
	end
	return Hits
end
function getAllBladeHits(Sizes)
	local Hits = {}
	local Client = game.Players.LocalPlayer
	local Enemies = game:GetService("Workspace").Enemies:GetChildren()
	for i=1,#Enemies do local v = Enemies[i]
		local Human = v:FindFirstChildOfClass("Humanoid")
		if Human and Human.RootPart and Human.Health > 0 and Client:DistanceFromCharacter(Human.RootPart.Position) < Sizes+5 then
			table.insert(Hits,Human.RootPart)
		end
	end
	return Hits
end
function DamageAura()
	local ac = CombatFrameworkR.activeController
	if ac and ac.equipped then
		for indexincrement = 1, 1 do
			local bladehit = getAllBladeHits(150) local a = getAllBladeHitsPlayers(150)
			if #bladehit or #a > 0 then
				local AcAttack8 = debug.getupvalue(ac.attack, 5)
				local AcAttack9 = debug.getupvalue(ac.attack, 6)
				local AcAttack7 = debug.getupvalue(ac.attack, 4)
				local AcAttack10 = debug.getupvalue(ac.attack, 7)
				local NumberAc12 = (AcAttack8 * 798405 + AcAttack7 * 727595) % AcAttack9
				local NumberAc13 = AcAttack7 * 798405
				(function()
					NumberAc12 = (NumberAc12 * AcAttack9 + NumberAc13) % 1099511627776
					AcAttack8 = math.floor(NumberAc12 / AcAttack9)
					AcAttack7 = NumberAc12 - AcAttack8 * AcAttack9
				end)()
				AcAttack10 = AcAttack10 + 1
				debug.setupvalue(ac.attack, 5, AcAttack8)
				debug.setupvalue(ac.attack, 6, AcAttack9)
				debug.setupvalue(ac.attack, 4, AcAttack7)
				debug.setupvalue(ac.attack, 7, AcAttack10)
				for k, v in pairs(ac.animator.anims.basic) do
					v:Play(0.01,0.01,0.01)
				end                 
				if game.Players.LocalPlayer.Character:FindFirstChildOfClass("Tool") and ac.blades and ac.blades[1] then 
					game:GetService("ReplicatedStorage").RigControllerEvent:FireServer("weaponChange",tostring(CurrentWeapon()))
					game.ReplicatedStorage.Remotes.Validator:FireServer(math.floor(NumberAc12 / 1099511627776 * 16777215), AcAttack10)
                    game:GetService("ReplicatedStorage").RigControllerEvent:FireServer("hit", bladehit, indexincrement, "") 
				end
			end
		end
	end
end
function AttackFunction()
	local ac = CombatFrameworkR.activeController
	if ac and ac.equipped then
		for indexincrement = 1, 1 do
			local bladehit = getAllBladeHits(60)
			if #bladehit > 0 then
				local AcAttack8 = debug.getupvalue(ac.attack, 5)
				local AcAttack9 = debug.getupvalue(ac.attack, 6)
				local AcAttack7 = debug.getupvalue(ac.attack, 4)
				local AcAttack10 = debug.getupvalue(ac.attack, 7)
				local NumberAc12 = (AcAttack8 * 798405 + AcAttack7 * 727595) % AcAttack9
				local NumberAc13 = AcAttack7 * 798405
				(function()
					NumberAc12 = (NumberAc12 * AcAttack9 + NumberAc13) % 1099511627776
					AcAttack8 = math.floor(NumberAc12 / AcAttack9)
					AcAttack7 = NumberAc12 - AcAttack8 * AcAttack9
				end)()
				AcAttack10 = AcAttack10 + 1 
				debug.setupvalue(ac.attack, 5, AcAttack8)
				debug.setupvalue(ac.attack, 6, AcAttack9)
				debug.setupvalue(ac.attack, 4, AcAttack7)
				debug.setupvalue(ac.attack, 7, AcAttack10)
				for k, v in pairs(ac.animator.anims.basic) do
					v:Play(0.01,0.01,0.01)
				end                 
				if game.Players.LocalPlayer.Character:FindFirstChildOfClass("Tool") and ac.blades and ac.blades[1] then 
					game:GetService("ReplicatedStorage").RigControllerEvent:FireServer("weaponChange",tostring(CurrentWeapon()))
					game.ReplicatedStorage.Remotes.Validator:FireServer(math.floor(NumberAc12 / 1099511627776 * 16777215), AcAttack10)
                    game:GetService("ReplicatedStorage").RigControllerEvent:FireServer("hit", bladehit, indexincrement, "")
				end
			end
		end
	end
end

task.spawn(function()
    pcall(function()
    while task.wait(_G.Fast_Delay) do
        if FastAttackSpeed then
            AttackFunction()
           end
        end
    end)
end)

    local DropdownSelectWeapon = Tabs.Main:AddDropdown("SelectWeapon", {
        Title = "Weapon ",
        Values = {'Melee','Sword','Blox Fruit'},
        Multi = false,
        Default = 1,
    })
    DropdownSelectWeapon:SetValue('Melee')
    DropdownSelectWeapon:OnChanged(function(Value)
        ChooseWeapon = Value
    end)
    task.spawn(function()
        while wait() do
            pcall(function()
                if ChooseWeapon == "Melee" then
                    for i ,v in pairs(game.Players.LocalPlayer.Backpack:GetChildren()) do
                        if v.ToolTip == "Melee" then
                            if game.Players.LocalPlayer.Backpack:FindFirstChild(tostring(v.Name)) then
                                SelectWeapon = v.Name
                            end
                        end
                    end
                elseif ChooseWeapon == "Sword" then
                    for i ,v in pairs(game.Players.LocalPlayer.Backpack:GetChildren()) do
                        if v.ToolTip == "Sword" then
                            if game.Players.LocalPlayer.Backpack:FindFirstChild(tostring(v.Name)) then
                                SelectWeapon = v.Name
                            end
                        end
                    end
                elseif ChooseWeapon == " Blox Fruit" then
                    for i ,v in pairs(game.Players.LocalPlayer.Backpack:GetChildren()) do
                        if v.ToolTip == "Blox Fruit" then
                            if game.Players.LocalPlayer.Backpack:FindFirstChild(tostring(v.Name)) then
                                SelectWeapon = v.Name
                            end
                        end
                    end
                else
                    for i ,v in pairs(game.Players.LocalPlayer.Backpack:GetChildren()) do
                        if v.ToolTip == "Melee" then
                            if game.Players.LocalPlayer.Backpack:FindFirstChild(tostring(v.Name)) then
                                SelectWeapon = v.Name
                            end
                        end
                    end
                end
            end)
        end
    end)


    local ToggleAutoFarmLevel = Tabs.Main:AddToggle("ToggleAutoFarmLevel", {Title = "Auto Farm Level", Default = false })
    ToggleAutoFarmLevel:OnChanged(function(Value)
        _G.AutoLevel = Value
    end)
    Options.ToggleAutoFarmLevel:SetValue(false)
    spawn(function()
        while task.wait() do
        if _G.AutoLevel then
        pcall(function()
          CheckLevel()
          if not string.find(game:GetService("Players").LocalPlayer.PlayerGui.Main.Quest.Container.QuestTitle.Title.Text, NameMon) or game:GetService("Players").LocalPlayer.PlayerGui.Main.Quest.Visible == false then
          game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("AbandonQuest")
          if BypassTP then
          if (game.Players.LocalPlayer.Character.HumanoidRootPart.Position - CFrameQ.Position).Magnitude > 2500 then
          BTP(CFrameQ)
          elseif (game.Players.LocalPlayer.Character.HumanoidRootPart.Position - CFrameQ.Position).Magnitude < 2500 then
          Tween(CFrameQ)
          end
    else
            Tween(CFrameQ)
            end
          if (CFrameQ.Position - game:GetService("Players").LocalPlayer.Character.HumanoidRootPart.Position).Magnitude <= 5 then
          game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("StartQuest",NameQuest,QuestLv)
          end
          elseif string.find(game:GetService("Players").LocalPlayer.PlayerGui.Main.Quest.Container.QuestTitle.Title.Text, NameMon) or game:GetService("Players").LocalPlayer.PlayerGui.Main.Quest.Visible == true then
          for i,v in pairs(game:GetService("Workspace").Enemies:GetChildren()) do
          if v:FindFirstChild("Humanoid") and v:FindFirstChild("HumanoidRootPart") and v.Humanoid.Health > 0 then
          if v.Name == Ms then
          repeat game:GetService("RunService").Heartbeat:wait()
          AutoHaki()
          EquipTool(SelectWeapon)
          Tween(v.HumanoidRootPart.CFrame * CFrame.new(posX,posY,posZ))
          v.HumanoidRootPart.Size = Vector3.new(60, 60, 60)
          v.HumanoidRootPart.Transparency = 1
          v.Humanoid.JumpPower = 0
          v.Humanoid.WalkSpeed = 0
          v.HumanoidRootPart.CanCollide = false
          FarmPos = v.HumanoidRootPart.CFrame
          MonFarm = v.Name
          Click()
          until not _G.AutoLevel or not v.Parent or v.Humanoid.Health <= 0 or not game:GetService("Workspace").Enemies:FindFirstChild(v.Name) or game.Players.LocalPlayer.PlayerGui.Main.Quest.Visible == false
          end   
          end
          end
          for i,v in pairs(game:GetService("Workspace")["_WorldOrigin"].EnemySpawns:GetChildren()) do
          if string.find(v.Name,NameMon) then
          if (game.Players.LocalPlayer.Character.HumanoidRootPart.Position - v.Position).Magnitude >= 10 then
            Tween(v.CFrame * CFrame.new(posX,posY,posZ))
          end
          end
          end
          end
          Tween(v.HumanoidRootPart.CFrame * Pos2)
          end)
        end
        end
        end)


    if game:GetService("ReplicatedStorage").Effect.Container:FindFirstChild("Death") then
        game:GetService("ReplicatedStorage").Effect.Container.Death:Destroy()
    end
    if game:GetService("ReplicatedStorage").Effect.Container:FindFirstChild("Respawn") then
        game:GetService("ReplicatedStorage").Effect.Container.Respawn:Destroy()
    end

    local ToggleMobAura = Tabs.Main:AddToggle("ToggleMobAura", {Title = "Auto Near Mob", Default = false })
    ToggleMobAura:OnChanged(function(Value)
        _G.AutoNear = Value
    end)
    Options.ToggleMobAura:SetValue(false)
    spawn(function()
        while wait(.1) do
        if _G.AutoNear then
        pcall(function()
          for i,v in pairs (game.Workspace.Enemies:GetChildren()) do
          if v:FindFirstChild("Humanoid") and v:FindFirstChild("HumanoidRootPart") and v.Humanoid.Health > 0 then
          if v.Name then
          if (game.Players.LocalPlayer.Character.HumanoidRootPart.Position - v:FindFirstChild("HumanoidRootPart").Position).Magnitude <= 5000 then
          repeat task.wait(0.1)
          AutoHaki()
          EquipTool(SelectWeapon)
          Tween(v.HumanoidRootPart.CFrame * Pos)
          v.HumanoidRootPart.Size = Vector3.new(1, 1, 1)
          v.HumanoidRootPart.Transparency = 1
          v.Humanoid.JumpPower = 0
          v.Humanoid.WalkSpeed = 0
          v.HumanoidRootPart.CanCollide = false
          FarmPos = v.HumanoidRootPart.CFrame
          MonFarm = v.Name
          Click()
          until not _G.AutoNear or not v.Parent or v.Humanoid.Health <= 0 or not game.Workspace.Enemies:FindFirstChild(v.Name)
          end
          end
          end
          end
          end)
        end
        end
      end)




--Mastery

    local DropdownMastery = Tabs.Mastery:AddDropdown("DropdownMastery", {
        Title = "Farm Mode",
        Values = {"Level","Near Mobs",},
        Multi = false,
        Default = 1,
    })

    DropdownMastery:SetValue("Level")

    DropdownMastery:OnChanged(function(Value)
        TypeMastery = Value
    end)

    local ToggleMasteryFruit = Tabs.Mastery:AddToggle("ToggleMasteryFruit", {Title = "Auto BF Mastery", Default = false })
    ToggleMasteryFruit:OnChanged(function(Value)
        AutoFarmMasDevilFruit = Value
    end)
    Options.ToggleMasteryFruit:SetValue(false)

    local ToggleMasteryGun = Tabs.Mastery:AddToggle("ToggleMasteryGun", {Title = "Auto Gun Mastery", Default = false })
    ToggleMasteryGun:OnChanged(function(Value)
        AutoFarmMasGun = Value
    end)
    Options.ToggleMasteryGun:SetValue(false)



    KillPercent = 40
    local SliderHealt = Tabs.Mastery:AddSlider("SliderHealt", {
        Title = "Health %",
        Description = "",
        Default = 40,
        Min = 0,
        Max = 100,
        Rounding = 1,
        Callback = function(Value)
            KillPercent = Value
        end
    })

    SliderHealt:OnChanged(function(Value)
        KillPercent = Value
    end)

    SliderHealt:SetValue(40)
    
	spawn(function()
        while task.wait(.1) do
        if AutoFarmMasGun and TypeMastery == 'Level' then
        pcall(function()
          CheckLevel(SelectMonster)
          if not string.find(game:GetService("Players").LocalPlayer.PlayerGui.Main.Quest.Container.QuestTitle.Title.Text, NameMon) or game:GetService("Players").LocalPlayer.PlayerGui.Main.Quest.Visible == false then
          game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("AbandonQuest")
            Tween(CFrameQ)
          if (CFrameQ.Position - game:GetService("Players").LocalPlayer.Character.HumanoidRootPart.Position).Magnitude <= 5 then
          game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("StartQuest",NameQuest,QuestLv)
          end
          elseif string.find(game:GetService("Players").LocalPlayer.PlayerGui.Main.Quest.Container.QuestTitle.Title.Text, NameMon) or game:GetService("Players").LocalPlayer.PlayerGui.Main.Quest.Visible == true then
          for i,v in pairs(game:GetService("Workspace").Enemies:GetChildren()) do
          if v:FindFirstChild("Humanoid") and v:FindFirstChild("HumanoidRootPart") then
          if v.Name == Ms then
          repeat game:GetService("RunService").Heartbeat:wait()
          if v.Humanoid.Health <= v.Humanoid.MaxHealth * KillPercent / 100 then
          EquipTool(CurrentEquipGun)
          game.Players.LocalPlayer.Character.HumanoidRootPart.CFrame = v.HumanoidRootPart.CFrame * Pos
          game:GetService("Players").LocalPlayer.Character[CurrentEquipGun].Cooldown.Value = 0
          UseSkillGun = true
          else
            UseSkillGun = false
            AutoHaki()
          EquipTool(SelectWeapon)
             Click()
          Tween(v.HumanoidRootPart.CFrame * CFrame.new(posX,posY,posZ))
          v.HumanoidRootPart.Size = Vector3.new(1, 1, 1)
          v.HumanoidRootPart.Transparency = 1
          v.Humanoid.JumpPower = 0
          v.Humanoid.WalkSpeed = 0
          v.HumanoidRootPart.CanCollide = false
      --v.Humanoid:ChangeState(11)
      --v.Humanoid:ChangeState(14)
         Click()
          FarmPos = v.HumanoidRootPart.CFrame
          MonFarm = v.Name
         
          end
          until not AutoFarmMasGun or not v.Parent or v.Humanoid.Health <= 0 or game:GetService("Players").LocalPlayer.PlayerGui.Main.Quest.Visible == false or not game:GetService("Workspace").Enemies:FindFirstChild(v.Name) or not TypeMastery == 'Queat'
          UseSkillGun = false
          end
          end
         
          end
          UseSkillGun = false
          Tween(CFrameQ)
          end
          end)
        elseif AutoFarmMasGun and TypeMastery == 'No Quest' then
        pcall(function()
          if BypassTP then
          if (game.Players.LocalPlayer.Character.HumanoidRootPart.Position - CFrameMon.Position).Magnitude > 2000 then
          BTP(CFrameMon)
          elseif (game.Players.LocalPlayer.Character.HumanoidRootPart.Position - CFrameMon.Position).Magnitude < 2000 then
          Tween(CFrameMon)
          end
          else
            Tween(CFrameMon)
          end
          CheckLevel()
          if game.Workspace.Enemies:FindFirstChild(Ms) then
          for i,v in pairs (game.Workspace.Enemies:GetChildren()) do
          if v.Name == Ms and v:FindFirstChild("Humanoid") and v:FindFirstChild("HumanoidRootPart") then
          repeat game:GetService("RunService").Heartbeat:wait()
          if v.Humanoid.Health <= v.Humanoid.MaxHealth * KillPercent / 100 then
          EquipTool(CurrentEquipGun)
          game.Players.LocalPlayer.Character.HumanoidRootPart.CFrame = v.HumanoidRootPart.CFrame * Pos
          game:GetService("Players").LocalPlayer.Character[CurrentEquipGun].Cooldown.Value = 0
          UseSkillGun = true
          else
            UseSkillGun = false
            AutoHaki()
          EquipTool(SelectWeapon)
          Tween(v.HumanoidRootPart.CFrame * CFrame.new(posX,posY,posZ))
          v.HumanoidRootPart.Size = Vector3.new(1, 1, 1)
          v.HumanoidRootPart.Transparency = 1
          v.Humanoid.JumpPower = 0
          v.Humanoid.WalkSpeed = 0
          v.HumanoidRootPart.CanCollide = false
        --v.Humanoid:ChangeState(11)
        --v.Humanoid:ChangeState(14)
          FarmPos = v.HumanoidRootPart.CFrame
          MonFarm = v.Name
          
          end
          until not AutoFarmMasGun or not v.Parent or v.Humanoid.Health <= 0 or not game:GetService("Workspace").Enemies:FindFirstChild(v.Name) or not TypeMastery == 'No Quest'
          end
          end
          else
            UseSkillGun = false
          Tween(CFrameMon)
          end
          end)
        elseif AutoFarmMasGun and TypeMastery == 'Near Mobs' then
        pcall(function()
          for i,v in pairs (game.Workspace.Enemies:GetChildren()) do
          if v.Name and v:FindFirstChild("Humanoid") and v:FindFirstChild("HumanoidRootPart") then
          if (game.Players.LocalPlayer.Character.HumanoidRootPart.Position - v:FindFirstChild("HumanoidRootPart").Position).Magnitude <= 2000 then
          repeat game:GetService("RunService").Heartbeat:wait()
          if v.Humanoid.Health <= v.Humanoid.MaxHealth * KillPercent / 100 then
          EquipTool(CurrentEquipGun)
          game.Players.LocalPlayer.Character.HumanoidRootPart.CFrame = v.HumanoidRootPart.CFrame * Pos
          game:GetService("Players").LocalPlayer.Character[CurrentEquipGun].Cooldown.Value = 0
          UseSkillGun = true
          else
            UseSkillGun = false
            AutoHaki()
               
          EquipTool(SelectWeapon)
          Tween(v.HumanoidRootPart.CFrame * CFrame.new(posX,posY,posZ))
          v.HumanoidRootPart.Size = Vector3.new(1, 1, 1)
          v.HumanoidRootPart.Transparency = 1
          v.Humanoid.JumpPower = 0
          v.Humanoid.WalkSpeed = 0
          v.HumanoidRootPart.CanCollide = false
      --v.Humanoid:ChangeState(11)
      --v.Humanoid:ChangeState(14)
      Click()
          FarmPos = v.HumanoidRootPart.CFrame
          MonFarm = v.Name
          Click()
         
          end
          until not AutoFarmMasGun or not MasteryType == 'Near Mobs' or not v.Parent or v.Humanoid.Health <= 0 or not TypeMastery == 'Near Mobs'
          UseSkillGun = false
          end
         
          end
          end
          end)
        elseif AutoFarmMasGun and TypeMastery == 'Boss' then
        if game:GetService("Players").LocalPlayer.PlayerGui.Main.Quest.Visible == false then
        CheckBossQuest()
        if BypassTP then
        if (game.Players.LocalPlayer.Character.HumanoidRootPart.Position - CFrameQBoss.Position).Magnitude > 2000 then
        BTP(CFrameQBoss)
        wait(3)
        elseif (game.Players.LocalPlayer.Character.HumanoidRootPart.Position - CFrameQBoss.Position).Magnitude < 2000 then
        Tween(CFrameQBoss)
        end
        else
          Tween(CFrameQBoss)
        end
      
        if (CFrameQBoss.Position - game:GetService("Players").LocalPlayer.Character.HumanoidRootPart.Position).Magnitude <= 5 then
        game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("StartQuest",NameQuestBoss,QuestLvBoss)
        end
        elseif game:GetService("Players").LocalPlayer.PlayerGui.Main.Quest.Visible == true then
        pcall(function()
          CheckBossQuest()
          if game:GetService("Workspace").Enemies:FindFirstChild(SelectBoss) then
          for i,v in pairs(game:GetService("Workspace").Enemies:GetChildren()) do
          if v.Name == selectBoss and v:FindFirstChild("Humanoid") and v:FindFirstChild("HumanoidRootPart") then
          repeat game:GetService("RunService").Heartbeat:wait()
          if v.Humanoid.Health <= v.Humanoid.MaxHealth * KillPercent / 100 then
          EquipTool(CurrentEquipGun)
          Tween(v.HumanoidRootPart.CFrame * CFrame.new(posX,posY,posZ))
          game:GetService("Players").LocalPlayer.Character[CurrentEquipGun].Cooldown.Value = 0
          UseSkillGun = true
          else
            UseSkillGun = false
            AutoHaki()
          EquipTool(SelectWeapon)
          Tween(v.HumanoidRootPart.CFrame * CFrame.new(posX,posY,posZ))
          v.HumanoidRootPart.Size = Vector3.new(1, 1, 1)
          v.HumanoidRootPart.Transparency = 1
          v.Humanoid.JumpPower = 0
          v.Humanoid.WalkSpeed = 0
          v.HumanoidRootPart.CanCollide = false
      --v.Humanoid:ChangeState(11)
      --v.Humanoid:ChangeState(14)
          FarmPos = v.HumanoidRootPart.CFrame
          MonFarm = v.Name
        
          end
          until not AutoFarmMasGun or not TypeMastery == 'Boss' or not v.Parent or v.Humanoid.Health <= 0 or game.Players.LocalPlayer.PlayerGui.Main.Quest.Visible == false or not game:GetService("Workspace").Enemies:FindFirstChild(v.Name)
          end
          end
          else
            UseSkillGun = false
          Tween(game:GetService("ReplicatedStorage"):FindFirstChild(SelectBoss).HumanoidRootPart.CFrame * CFrame.new(posX,posY,posZ))
          end
          end)
        end
        end
        end
        end)
      
      spawn(function()
        game:GetService("RunService").RenderStepped:Connect(function()
          if UseSkillGun then
          pcall(function()
            for i,v in pairs(game:GetService("Workspace").Enemies:GetChildren()) do
            if v.Name == MonFarm then
            game:GetService("Players").LocalPlayer.Character[CurrentEquipGun].RemoteFunctionShoot:InvokeServer(v.HumanoidRootPart.Position,v.HumanoidRootPart)
            ClickCamera()
            end
            end
            end)
          end
          end)
        end)






        spawn(function()
            while wait(1) do
                if UseSkillGun then
                    pcall(function()
                        CheckLevel()
                        for i,v in pairs(game:GetService("Workspace").Enemies:GetChildren()) do                                                 
                                if SkillZ then
                                    local args = {
                                        [1] = FarmPosMasteryGun.Position
                                    }
                                    game:GetService("Players").LocalPlayer.Character[game:GetService("Players").LocalPlayer.Character:FindFirstChildOfClass("Tool").Name].RemoteEvent:FireServer(unpack(args))                        
                                    game:GetService("VirtualInputManager"):SendKeyEvent(true,"Z",false,game)
                                    game:GetService("VirtualInputManager"):SendKeyEvent(false,"Z",false,game)
                                end
                                if SkillX then          
                                    local args = {
                                        [1] = FarmPosMasteryGun.Position
                                    }
                                    game:GetService("Players").LocalPlayer.Character[game:GetService("Players").LocalPlayer.Character:FindFirstChildOfClass("Tool").Name].RemoteEvent:FireServer(unpack(args))               
                                    game:GetService("VirtualInputManager"):SendKeyEvent(true,"X",false,game)
                                    game:GetService("VirtualInputManager"):SendKeyEvent(false,"X",false,game)
                            end
                        end
                    end)
                end
            end
        end)
    
        
        
        spawn(function()
            pcall(function()
                game:GetService("RunService").RenderStepped:Connect(function()
                    if UseSkillGun then
                        local args = {
                            [1] = FarmPosMasteryGun.Position
                        }
                        game:GetService("Players").LocalPlayer.Character[game:GetService("Players").LocalPlayer.Data.Gun.Value].RemoteEvent:FireServer(unpack(args))
                    end
                end)
            end)
        end)



spawn(function()
while task.wait(1) do
if _G.UseSkill then
pcall(function()
  if _G.UseSkill then
  for i,v in pairs(game:GetService("Workspace").Enemies:GetChildren()) do
  if v.Name == MonFarm and v:FindFirstChild("Humanoid") and v:FindFirstChild("HumanoidRootPart") and v.Humanoid.Health <= v.Humanoid.MaxHealth * KillPercent / 100 then
  repeat game:GetService("RunService").Heartbeat:wait()
  EquipTool(game.Players.LocalPlayer.Data.DevilFruit.Value)
  Tween(v.HumanoidRootPart.CFrame * CFrame.new(posX,posY,posZ))
  PositionSkillMasteryDevilFruit = v.HumanoidRootPart.Position
  if game:GetService("Players").LocalPlayer.Character:FindFirstChild(game.Players.LocalPlayer.Data.DevilFruit.Value) then
  game:GetService("Players").LocalPlayer.Character:FindFirstChild(game.Players.LocalPlayer.Data.DevilFruit.Value).MousePos.Value = PositionSkillMasteryDevilFruit
  local DevilFruitMastery = game:GetService("Players").LocalPlayer.Character:FindFirstChild(game.Players.LocalPlayer.Data.DevilFruit.Value).Level.Value
  if SkillZ and DevilFruitMastery >= 1 then
  game:service('VirtualInputManager'):SendKeyEvent(true, "Z", false, game)
  wait(.1)
  game:service('VirtualInputManager'):SendKeyEvent(false, "Z", false, game)
  end
  if SkillX and DevilFruitMastery >= 2 then
  game:service('VirtualInputManager'):SendKeyEvent(true, "X", false, game)
  wait(.2)
  game:service('VirtualInputManager'):SendKeyEvent(false, "X", false, game)
  end
  if SkillC and DevilFruitMastery >= 3 then
  game:service('VirtualInputManager'):SendKeyEvent(true, "C", false, game)
  wait(.3)
  game:service('VirtualInputManager'):SendKeyEvent(false, "C", false, game)
  end
  if SkillV and DevilFruitMastery >= 4 then
  game:service('VirtualInputManager'):SendKeyEvent(true, "V", false, game)
  wait(.4)
  game:service('VirtualInputManager'):SendKeyEvent(false, "V", false, game)
  end
  if SkillF and DevilFruitMastery >= 5 then
  game:GetService("VirtualInputManager"):SendKeyEvent(true, "F", false, game)
  wait(.5)
  game:GetService("VirtualInputManager"):SendKeyEvent(false, "F", false, game)
  end
  end
  until not AutoFarmMasDevilFruit or not _G.UseSkill or v.Humanoid.Health == 0
  end
  end
  end
  end)
end
end
end)

spawn(function()
while task.wait(.1) do
if AutoFarmMasDevilFruit and TypeMastery == 'Level' then
pcall(function()
  CheckLevel(SelectMonster)
  if not string.find(game:GetService("Players").LocalPlayer.PlayerGui.Main.Quest.Container.QuestTitle.Title.Text, NameMon) or game:GetService("Players").LocalPlayer.PlayerGui.Main.Quest.Visible == false then
  game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("AbandonQuest")
  if BypassTP then
  if (game.Players.LocalPlayer.Character.HumanoidRootPart.Position - CFrameQ.Position).Magnitude > 2500 then
  BTP(CFrameQ)
  wait(0.2)
  elseif (game.Players.LocalPlayer.Character.HumanoidRootPart.Position - CFrameQ.Position).Magnitude < 2500 then
  Tween(CFrameQ)
  end
  else
    Tween(CFrameQ)
  end
  if (CFrameQ.Position - game:GetService("Players").LocalPlayer.Character.HumanoidRootPart.Position).Magnitude <= 5 then
  game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("StartQuest",NameQuest,QuestLv)
  end
  elseif string.find(game:GetService("Players").LocalPlayer.PlayerGui.Main.Quest.Container.QuestTitle.Title.Text, NameMon) or game:GetService("Players").LocalPlayer.PlayerGui.Main.Quest.Visible == true then
  for i,v in pairs(game:GetService("Workspace").Enemies:GetChildren()) do
  if v:FindFirstChild("Humanoid") and v:FindFirstChild("HumanoidRootPart") then
  if v.Name == Ms then
  repeat game:GetService("RunService").Heartbeat:wait()
  if v.Humanoid.Health <= v.Humanoid.MaxHealth * KillPercent / 100 then

  _G.UseSkill = true
  else
    _G.UseSkill = false
AutoHaki()
  EquipTool(SelectWeapon)
     Click()
  Tween(v.HumanoidRootPart.CFrame * CFrame.new(posX,posY,posZ))
  v.HumanoidRootPart.Size = Vector3.new(1, 1, 1)
  v.HumanoidRootPart.Transparency = 1
  v.Humanoid.JumpPower = 0
  v.Humanoid.WalkSpeed = 0
  v.HumanoidRootPart.CanCollide = false
--v.Humanoid:ChangeState(11)
--v.Humanoid:ChangeState(14)
  Click()
  FarmPos = v.HumanoidRootPart.CFrame
  MonFarm = v.Name

 
  end
  until not AutoFarmMasDevilFruit or not v.Parent or v.Humanoid.Health == 0 or game:GetService("Players").LocalPlayer.PlayerGui.Main.Quest.Visible == false or not game:GetService("Workspace").Enemies:FindFirstChild(v.Name) or not TypeMastery == 'Level'
  _G.UseSkill = false
 
  end
  end
  end
  _G.UseSkill = false
  Tween(Q)
  end
  end)
elseif AutoFarmMasDevilFruit and TypeMastery == 'No Quest' then
pcall(function()
  CheckLevel()
  if BypassTP then
  if (game.Players.LocalPlayer.Character.HumanoidRootPart.Position - CFrameMon.Position).Magnitude > 2000 then
  BTP(CFrameMon)
  elseif (game.Players.LocalPlayer.Character.HumanoidRootPart.Position - CFrameMon.Position).Magnitude < 2000 then
  Tween(CFrameMon)
  end
  else
    Tween(CFrameMon)
  end
  if game.Workspace.Enemies:FindFirstChild(Ms) then
  for i,v in pairs (game.Workspace.Enemies:GetChildren()) do
  if v.Name == Ms and v:FindFirstChild("Humanoid") and v:FindFirstChild("HumanoidRootPart") then
  repeat game:GetService("RunService").Heartbeat:wait()
  if v.Humanoid.Health <= v.Humanoid.MaxHealth * KillPercent / 100 then
  _G.UseSkill = true
  else
    _G.UseSkill = false
    AutoHaki()
  EquipTool(SelectWeapon)
  Tween(v.HumanoidRootPart.CFrame * CFrame.new(posX,posY,posZ))
  v.HumanoidRootPart.Size = Vector3.new(1, 1, 1)
  v.HumanoidRootPart.Transparency = 1
  v.Humanoid.JumpPower = 0
  v.Humanoid.WalkSpeed = 0
  v.HumanoidRootPart.CanCollide = false
--v.Humanoid:ChangeState(11)
--v.Humanoid:ChangeState(14)
  FarmPos = v.HumanoidRootPart.CFrame
  MonFarm = v.Name
  end
  until not AutoFarmMasDevilFruit or not v.Parent or v.Humanoid.Health == 0 or not game:GetService("Workspace").Enemies:FindFirstChild(v.Name) or not TypeMastery == 'No Quest'
  _G.UseSkill = false
  end
  end
  else
    _G.UseSkill = false
  Tween(CFrameMon)
  end
  end)
elseif AutoFarmMasDevilFruit and TypeMastery == 'Near Mobs' then
pcall(function()
  for i,v in pairs (game.Workspace.Enemies:GetChildren()) do
  if v.Name and v:FindFirstChild("Humanoid") and v:FindFirstChild("HumanoidRootPart") then
  if (game.Players.LocalPlayer.Character.HumanoidRootPart.Position - v:FindFirstChild("HumanoidRootPart").Position).Magnitude <= 2000 then
  repeat game:GetService("RunService").Heartbeat:wait()
  if v.Humanoid.Health <= v.Humanoid.MaxHealth * KillPercent / 100 then
  _G.UseSkill = true
  else
    _G.UseSkill = false
    AutoHaki()
       
  EquipTool(SelectWeapon)
  Tween(v.HumanoidRootPart.CFrame * CFrame.new(posX,posY,posZ))
  v.HumanoidRootPart.Size = Vector3.new(1, 1, 1)
  v.HumanoidRootPart.Transparency = 1
  v.Humanoid.JumpPower = 0
  v.Humanoid.WalkSpeed = 0
  v.HumanoidRootPart.CanCollide = false
--v.Humanoid:ChangeState(11)
--v.Humanoid:ChangeState(14)
  FarmPos = v.HumanoidRootPart.CFrame
  MonFarm = v.Name
  Click()
 
  end
  until not AutoFarmMasDevilFruit or not MasteryType == 'Nearest' or not v.Parent or v.Humanoid.Health == 0 or not TypeMastery == 'Nearest'
  _G.UseSkill = false
  end
 
  end
  end
  end)
elseif AutoFarmMasDevilFruit and TypeMastery == 'Boss' then
if game:GetService("Players").LocalPlayer.PlayerGui.Main.Quest.Visible == false then
CheckBossQuest()
if BypassTP then
if (game.Players.LocalPlayer.Character.HumanoidRootPart.Position - CFrameQBoss.Position).Magnitude > 2000 then
BTP(CFrameQBoss)
wait(3)
elseif (game.Players.LocalPlayer.Character.HumanoidRootPart.Position - CFrameQBoss.Position).Magnitude < 2000 then
Tween(CFrameQBoss)
end
else
  Tween(CFrameQBoss)
end

if (CFrameQBoss.Position - game:GetService("Players").LocalPlayer.Character.HumanoidRootPart.Position).Magnitude <= 5 then
game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("StartQuest",NameQuestBoss,QuestLvBoss)
end
elseif game:GetService("Players").LocalPlayer.PlayerGui.Main.Quest.Visible == true then
pcall(function()
  CheckBossQuest()
  if game:GetService("Workspace").Enemies:FindFirstChild(SelectBoss) then
  for i,v in pairs(game:GetService("Workspace").Enemies:GetChildren()) do
  if v.Name == selectBoss and v:FindFirstChild("Humanoid") and v:FindFirstChild("HumanoidRootPart") then
  repeat game:GetService("RunService").Heartbeat:wait()
  if v.Humanoid.Health <= v.Humanoid.MaxHealth * KillPercent / 100 then
  _G.UseSkill = true
  else
    _G.UseSkill = false
    AutoHaki()
  EquipTool(SelectWeapon)
  Tween(v.HumanoidRootPart.CFrame * CFrame.new(posX,posY,posZ))
  v.HumanoidRootPart.Size = Vector3.new(1, 1, 1)
  v.HumanoidRootPart.Transparency = 1
  v.Humanoid.JumpPower = 0
  v.Humanoid.WalkSpeed = 0
  v.HumanoidRootPart.CanCollide = false
--v.Humanoid:ChangeState(11)
--v.Humanoid:ChangeState(14)
  FarmPos = v.HumanoidRootPart.CFrame
  MonFarm = v.Name
  
  end
  until not AutoFarmMasDevilFruit or not TypeMastery == 'Boss' or not v.Parent or v.Humanoid.Health == 0 or game.Players.LocalPlayer.PlayerGui.Main.Quest.Visible == false or not game:GetService("Workspace").Enemies:FindFirstChild(v.Name)
  end
  end
  else
    _G.UseSkill = false
  Tween(game:GetService("ReplicatedStorage"):FindFirstChild(SelectBoss).HumanoidRootPart.CFrame * PosY)
  end
  end)
end
end
end
end)




local ToggleBone = Tabs.OtherFarms:AddToggle("ToggleBone", {Title = "Auto Farm Bone", Default = false })
ToggleBone:OnChanged(function(Value)
    _G.AutoBone = Value
end)
Options.ToggleBone:SetValue(false)
local FaiFaoQuestBone =  CFrame.new(-9515.75, 174.8521728515625, 6079.40625)


spawn(function()
    while wait() do
        if _G.AutoBone then
            pcall(function()
                local QuestTitle = game:GetService("Players").LocalPlayer.PlayerGui.Main.Quest.Container.QuestTitle.Title.Text
                if not string.find(QuestTitle, "Demonic Soul") then
                    game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("AbandonQuest")
                end
                if game:GetService("Players").LocalPlayer.PlayerGui.Main.Quest.Visible == false then
                    if BypassTP then
                        wait()
                       if (game.Players.LocalPlayer.Character.HumanoidRootPart.Position - FaiFaoQuestBone.Position).Magnitude > 2500 then
                       BTP(FaiFaoQuestBone)
              
                       elseif (game.Players.LocalPlayer.Character.HumanoidRootPart.Position - FaiFaoQuestBone.Position).Magnitude < 2500 then
               
                       Tween(FaiFaoQuestBone)
                       end
                 else
          
                         Tween(FaiFaoQuestBone)
                         end
                if (FaiFaoQuestBone.Position - game:GetService("Players").LocalPlayer.Character.HumanoidRootPart.Position).Magnitude <= 3 then    
                    game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("StartQuest","HauntedQuest2",1)
                    end
                elseif game:GetService("Players").LocalPlayer.PlayerGui.Main.Quest.Visible == true then
                    if game:GetService("Workspace").Enemies:FindFirstChild("Reborn Skeleton") or game:GetService("Workspace").Enemies:FindFirstChild("Living Zombie") or game:GetService("Workspace").Enemies:FindFirstChild("Demonic Soul") or game:GetService("Workspace").Enemies:FindFirstChild("Posessed Mummy") then
                        for i,v in pairs(game:GetService("Workspace").Enemies:GetChildren()) do
                            if v:FindFirstChild("HumanoidRootPart") and v:FindFirstChild("Humanoid") and v.Humanoid.Health > 0 then
                                if v.Name == "Reborn Skeleton" or v.Name == "Living Zombie" or v.Name == "Demonic Soul" or v.Name == "Posessed Mummy" then
                                    if string.find(game:GetService("Players").LocalPlayer.PlayerGui.Main.Quest.Container.QuestTitle.Title.Text, "Demonic Soul") then
                                        repeat task.wait()
                                            AutoHaki()
                                            EquipTool(SelectWeapon)
                                            Tween(v.HumanoidRootPart.CFrame * Pos)
			                                v.HumanoidRootPart.Size = Vector3.new(1, 1, 1)
                                            v.HumanoidRootPart.Transparency = 1
                                            v.Humanoid.JumpPower = 0
                                            v.Humanoid.WalkSpeed = 0
                                            v.HumanoidRootPart.CanCollide = false
                                            FarmPos = v.HumanoidRootPart.CFrame
                                            MonFarm = v.Name
                                            Click()
                                        until not _G.AutoBone or v.Humanoid.Health <= 0 or not v.Parent or game:GetService("Players").LocalPlayer.PlayerGui.Main.Quest.Visible == false
                                    else
                                        game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("AbandonQuest")
                                    end
                                end
                            end
                        end
                    else
                        if game:GetService("ReplicatedStorage"):FindFirstChild("Demonic Soul") then
                        Tween(v.HumanoidRootPart.CFrame * Pos2)
                        end
                    end
                    
                end
            end)
        end
    end
end)

local ToggleCake = Tabs.OtherFarms:AddToggle("ToggleCake", {Title = "Auto Farm Cake Prince", Default = false })
ToggleCake:OnChanged(function(Value)
 _G.CakePrince = Value
end)
Options.ToggleCake:SetValue(false)

spawn(function()
    while task.wait() do
    if _G.CakePrince then
    game.ReplicatedStorage.Remotes.CommF_:InvokeServer("CakePrinceSpawner")
    if game.ReplicatedStorage:FindFirstChild("Cake Prince") or game:GetService("Workspace").Enemies:FindFirstChild("Cake Prince") then
    if game:GetService("Workspace").Enemies:FindFirstChild("Cake Prince") then
    for i,v in pairs(game.Workspace.Enemies:GetChildren()) do
    if _G.CakePrince and v.Name == "Cake Prince" and v:FindFirstChild("HumanoidRootPart") and v:FindFirstChild("Humanoid") and v.Humanoid.Health > 0 then
    repeat task.wait()
    AutoHaki()
    EquipTool(SelectWeapon)
    Tween(v.HumanoidRootPart.CFrame * Pos)
    v.HumanoidRootPart.Size = Vector3.new(60, 60, 60)
    v.HumanoidRootPart.Transparency = 1
    v.Humanoid.JumpPower = 0
    v.Humanoid.WalkSpeed = 0
    v.HumanoidRootPart.CanCollide = false
    FarmPos = v.HumanoidRootPart.CFrame
    MonFarm = v.Name
    game:GetService'VirtualUser':CaptureController()
    game:GetService'VirtualUser':Button1Down(Vector2.new(1280, 672),workspace.CurrentCamera.CFrame)
	BringMobs = false
    until not _G.CakePrince or not v.Parent or v.Humanoid.Health <= 0
	BringMobs = true
    end
    end
    else
      if game:GetService("Workspace").Map.CakeLoaf.BigMirror.Other.Transparency == 0 and (CFrame.new(-1990.672607421875, 4532.99951171875, -14973.6748046875).Position - game.Players.LocalPlayer.Character.HumanoidRootPart.Position).Magnitude >= 2000 then
    Tween(CFrame.new(-2151.82153, 149.315704, -12404.9053))
	BirngMobs = true
    end
    end
    else
      if game:GetService("Workspace").Enemies:FindFirstChild("Cookie Crafter") or game:GetService("Workspace").Enemies:FindFirstChild("Cake Guard") or game:GetService("Workspace").Enemies:FindFirstChild("Baking Staff") or game:GetService("Workspace").Enemies:FindFirstChild("Head Baker") then
    for i,v in pairs(game.Workspace.Enemies:GetChildren()) do
    if v:FindFirstChild("Humanoid") and v:FindFirstChild("HumanoidRootPart") and v.Humanoid.Health > 0 then
    if (v.Name == "Cookie Crafter" or v.Name == "Cake Guard" or v.Name == "Baking Staff" or v.Name == "Head Baker") and v:FindFirstChild("HumanoidRootPart") and v:FindFirstChild("Humanoid") and v.Humanoid.Health > 0 then
    repeat task.wait()
    AutoHaki()
    EquipTool(SelectWeapon)
    Tween(v.HumanoidRootPart.CFrame * Pos)
    v.HumanoidRootPart.Size = Vector3.new(60, 60, 60)
    v.HumanoidRootPart.Transparency = 1
    v.Humanoid.JumpPower = 0
    v.Humanoid.WalkSpeed = 0
    v.HumanoidRootPart.CanCollide = false
    FarmPos = v.HumanoidRootPart.CFrame
    MonFarm = v.Name
    game:GetService'VirtualUser':CaptureController()
    game:GetService'VirtualUser':Button1Down(Vector2.new(1280, 672),workspace.CurrentCamera.CFrame)
    until not _G.CakePrince or not v.Parent or v.Humanoid.Health <= 0
    end
    end
    end
    else
      local cakepos = CFrame.new(-2077, 252, -12373)
    if BypassTP then
    if (game.Players.LocalPlayer.Character.HumanoidRootPart.Position - cakepos.Position).Magnitude > 2000 then
    BTP(cakepos)
    wait(3)
    elseif (game.Players.LocalPlayer.Character.HumanoidRootPart.Position - cakepos.Position).Magnitude < 2000 then
    Tween(cakepos)
    end
    else
    Tween(v.HumanoidRootPart.CFrame * Pos2)
    end
    end
    end
    end
    end
    end)



    local ToggleVatChatKiDi = Tabs.OtherFarms:AddToggle("ToggleVatChatKiDi", {Title = "Auto Farm Ectoplasm", Default = false })
    ToggleVatChatKiDi:OnChanged(function(Value)
        _G.Ecto = Value
    end)
    Options.ToggleVatChatKiDi:SetValue(false)

    spawn(function()
        while wait(.1) do
            pcall(function()
                if _G.Ecto then
                    if game:GetService("Workspace").Enemies:FindFirstChild("Ship Deckhand") or game:GetService("Workspace").Enemies:FindFirstChild("Ship Engineer") or game:GetService("Workspace").Enemies:FindFirstChild("Ship Steward") or game:GetService("Workspace").Enemies:FindFirstChild("Ship Officer") then
                        for i,v in pairs(game:GetService("Workspace").Enemies:GetChildren()) do
                            if v.Name == "Ship Steward" or v.Name == "Ship Engineer" or v.Name == "Ship Deckhand" or v.Name == "Ship Officer" and v:FindFirstChild("Humanoid") then
                                if v.Humanoid.Health > 0 then
                                    repeat game:GetService("RunService").Heartbeat:wait()
                                        AutoHaki()
                                        EquipTool(SelectWeapon)
                                        Tween(v.HumanoidRootPart.CFrame * Pos)
                                        v.HumanoidRootPart.Size = Vector3.new(60, 60, 60)
                                        v.HumanoidRootPart.Transparency = 1
                                        v.Humanoid.JumpPower = 0
                                        v.Humanoid.WalkSpeed = 0
                                        v.HumanoidRootPart.CanCollide = false
                                        --v.Humanoid:ChangeState(11)
                                        --v.Humanoid:ChangeState(14)
                                        FarmPos = v.HumanoidRootPart.CFrame
                                        MonFarm = v.Name
                                        Click()
                                    until _G.Ecto == false or not v.Parent or v.Humanoid.Health == 0 or not game:GetService("Workspace").Enemies:FindFirstChild(v.Name)
                                end
                            end
                        end
                    else
                        local Distance = (Vector3.new(904.4072265625, 181.05767822266, 33341.38671875) - game.Players.LocalPlayer.Character.HumanoidRootPart.Position).Magnitude
                        if Distance > 20000 then
                            game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("requestEntrance",Vector3.new(923.21252441406, 126.9760055542, 32852.83203125))
                        end
                        Tween(CFrame.new(904.4072265625, 181.05767822266, 33341.38671875))
                    end
                end
            end)
        end
    end)








    Tabs.OtherFarms:AddParagraph({
        Title = "Boss Farm",
        Content = ""
    })




    if First_Sea then
		tableBoss = {"The Gorilla King","Bobby","Yeti","Mob Leader","Vice Admiral","Warden","Chief Warden","Swan","Magma Admiral","Fishman Lord","Wysper","Thunder God","Cyborg","Saber Expert"}
	elseif Second_Sea then
		tableBoss = {"Diamond","Jeremy","Fajita","Don Swan","Smoke Admiral","Cursed Captain","Darkbeard","Order","Awakened Ice Admiral","Tide Keeper"}
	elseif Third_Sea then
		tableBoss = {"Stone","Island Empress","Kilo Admiral","Captain Elephant","Beautiful Pirate","rip_indra True Form","Longma","Soul Reaper","Cake Queen"}
	end


    local DropdownBoss = Tabs.OtherFarms:AddDropdown("Boss", {
        Title = "Boss",
        Values = tableBoss,
        Multi = false,
        Default = 1,
    })

    DropdownBoss:SetValue("")
    DropdownBoss:OnChanged(function(Value)
		_G.SelectBoss = Value
    end)


	local ToggleAutoFarmBoss = Tabs.OtherFarms:AddToggle("ToggleAutoFarmBoss", {Title = "Auto Farm Boss", Default = false })

    ToggleAutoFarmBoss:OnChanged(function(Value)
		_G.AutoBoss = Value
    end)

    Options.ToggleAutoFarmBoss:SetValue(false)
	spawn(function()
        while wait() do
            if _G.AutoBoss and BypassTP then
                pcall(function()
                    if game:GetService("Workspace").Enemies:FindFirstChild(_G.SelectBoss) then
                        for i,v in pairs(game:GetService("Workspace").Enemies:GetChildren()) do
                            if v.Name == _G.SelectBoss then
                                if v:FindFirstChild("Humanoid") and v:FindFirstChild("HumanoidRootPart") and v.Humanoid.Health > 0 then
                                    repeat task.wait()
                                        AutoHaki()
                                        EquipTool(SelectWeapon)
                                        v.HumanoidRootPart.CanCollide = false
                                        v.Humanoid.WalkSpeed = 0
                                        v.HumanoidRootPart.Size = Vector3.new(80,80,80)                             
                                        Tween(v.HumanoidRootPart.CFrame * Pos)
                                       Click()
									   BringMobs = false
                                        sethiddenproperty(game:GetService("Players").LocalPlayer,"SimulationRadius",math.huge)
                                    until not _G.AutoBoss or not v.Parent or v.Humanoid.Health <= 0
                                end
                            end
							BringMobs = true
                        end
                    elseif game.ReplicatedStorage:FindFirstChild(_G.SelectBoss) then
						if ((game.ReplicatedStorage:FindFirstChild(_G.SelectBoss).HumanoidRootPart.CFrame).Position - game.Players.LocalPlayer.Character.HumanoidRootPart.Position).magnitude <= 1500 then
							Tween(game.ReplicatedStorage:FindFirstChild(_G.SelectBoss).HumanoidRootPart.CFrame)
						else
							BTP(game.ReplicatedStorage:FindFirstChild(_G.SelectBoss).HumanoidRootPart.CFrame)
					    end
						BringMobs = true
                    end
                end)
            end
        end
    end)
    
    spawn(function()
        while wait() do
            if _G.AutoBoss and not BypassTP then
                pcall(function()
                    if game:GetService("Workspace").Enemies:FindFirstChild(_G.SelectBoss) then
                        for i,v in pairs(game:GetService("Workspace").Enemies:GetChildren()) do
                            if v.Name == _G.SelectBoss then
                                if v:FindFirstChild("Humanoid") and v:FindFirstChild("HumanoidRootPart") and v.Humanoid.Health > 0 then
                                    repeat task.wait()
                                        AutoHaki()
                                        EquipTool(SelectWeapon)
                                        v.HumanoidRootPart.CanCollide = false
                                        v.Humanoid.WalkSpeed = 0
                                        v.HumanoidRootPart.Size = Vector3.new(80,80,80)                             
                                        Tween(v.HumanoidRootPart.CFrame * Pos)
                                        Click()
										BringMobs = false
                                    until not _G.AutoBoss or not v.Parent or v.Humanoid.Health <= 0
                                end
								BringMobs = true
                            end
                        end
                    else
                        if game:GetService("ReplicatedStorage"):FindFirstChild(_G.SelectBoss) then
                            Tween(game:GetService("ReplicatedStorage"):FindFirstChild(_G.SelectBoss).HumanoidRootPart.CFrame * CFrame.new(5,10,7))
                        end
                    end
                end)
				BringMobs = true
            end
        end
    end)

    Tabs.Material:AddParagraph({
        Title = "Material",
        Content = "Farm Material"
    })

    if First_Sea then
        MaterialList = {
          "Scrap Metal","Leather","Angel Wings","Magma Ore","Fish Tail"
        } elseif Second_Sea then
        MaterialList = {
          "Scrap Metal","Leather","Radioactive Material","Mystic Droplet","Magma Ore","Vampire Fang"
        } elseif Third_Sea then
        MaterialList = {
          "Scrap Metal","Leather","Demonic Wisp","Conjured Cocoa","Dragon Scale","Gunpowder","Fish Tail","Mini Tusk"
        }
        end

    local DropdownMaterial = Tabs.Material:AddDropdown("Material", {
        Title = "Material",
        Values = MaterialList,
        Multi = false,
        Default = 1,
    })

    DropdownMaterial:SetValue("Conjured Cocoa")

    DropdownMaterial:OnChanged(function(Value)
        SelectMaterial = Value
    end)


    local ToggleMaterial = Tabs.Material:AddToggle("ToggleMaterial", {Title = "Auto Farm Material", Default = false })

    ToggleMaterial:OnChanged(function(Value)
        _G.AutoMaterial = Value
    end)
    Options.ToggleMaterial:SetValue(false)
    spawn(function()
        while task.wait() do
        if _G.AutoMaterial then
        pcall(function()
          MaterialMon(SelectMaterial)
          if BypassTP then
          if (game.Players.LocalPlayer.Character.HumanoidRootPart.Position - MPos.Position).Magnitude > 3500 then
          BTP(MPos)
          elseif (game.Players.LocalPlayer.Character.HumanoidRootPart.Position - MPos.Position).Magnitude < 3500 then
          Tween(MPos)
          end
          else
            Tween(MPos)
          end
          if game:GetService("Workspace").Enemies:FindFirstChild(MMon) then
          for i,v in pairs (game.Workspace.Enemies:GetChildren()) do
          if v:FindFirstChild("Humanoid") and v:FindFirstChild("HumanoidRootPart") and v.Humanoid.Health > 0 then
          if v.Name == MMon then
          repeat task.wait()
          AutoHaki()
          EquipTool(SelectWeapon)
          Tween(v.HumanoidRootPart.CFrame * CFrame.new(posX,posY,posZ))
          v.HumanoidRootPart.Size = Vector3.new(60, 60, 60)
          v.HumanoidRootPart.Transparency = 1
          v.Humanoid.JumpPower = 0
          v.Humanoid.WalkSpeed = 0
          v.HumanoidRootPart.CanCollide = false
          FarmPos = v.HumanoidRootPart.CFrame
          MonFarm = v.Name
          Click()
          until not _G.AutoMaterial or not v.Parent or v.Humanoid.Health <= 0
          end
          end
          end
          else
            for i,v in pairs(game:GetService("Workspace")["_WorldOrigin"].EnemySpawns:GetChildren()) do
          if string.find(v.Name, Mon) then
          if (game.Players.LocalPlayer.Character.HumanoidRootPart.Position - v.Position).Magnitude >= 10 then
          Tween(v.CFrame * CFrame.new(posX,posY,posZ))
          end
          end
          end
          end
          end)
        end
        end
      end)


if Third_Sea then

      Tabs.Main:AddParagraph({
        Title = "Rough Sea",
        Content = "Auto rough sea"
    })


    local ToggleBoat = Tabs.Main:AddToggle("ToggleBoat", {Title = "Auto Buy Boat", Default = false })

    ToggleBoat:OnChanged(function(Value)
        _G.AutoBuyBoat = Value
    end)
    Options.ToggleBoat:SetValue(false)
    task.spawn(function()
        while wait() do
            pcall(function()
                if _G.AutoBuyBoat then
                    if not game:GetService("Workspace").SeaBeasts:FindFirstChild("SeaBeast1") then
                        if not game:GetService("Workspace").Boats:FindFirstChild("PirateBrigade") then 
                            if not game:GetService("Workspace").Boats:FindFirstChild("PirateBasic") then
                                if not game:GetService("Workspace").Boats:FindFirstChild("PirateBrigade") then
                                    buyb = TPP(CFrame.new(-4513.90087890625, 16.76398277282715, -2658.820556640625))
                                    if (CFrame.new(-4513.90087890625, 16.76398277282715, -2658.820556640625).Position - game.Players.LocalPlayer.Character.HumanoidRootPart.Position).magnitude <= 10 then
                                        if buyb then buyb:Stop() end
                                        local args = {
                                            [1] = "BuyBoat",
                                            [2] = "PirateBrigade"
                                        }
            
                                        game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer(unpack(args))
                                    end
                                elseif game:GetService("Workspace").Boats:FindFirstChild("PirateBrigade") then
                                    if game.Players.LocalPlayer.Character:WaitForChild("Humanoid").Sit == false then
                                        TPP(game:GetService("Workspace").Boats.PirateBrigade.VehicleSeat.CFrame * CFrame.new(0,1,0))
                                    elseif game.Players.LocalPlayer.Character:WaitForChild("Humanoid").Sit == true then
                                        repeat wait()
                                            if (game:GetService("Workspace").Boats.PirateBrigade.VehicleSeat.CFrame.Position - game.Players.LocalPlayer.Character.HumanoidRootPart.Position).magnitude <= 10 then
                                                TPB(CFrame.new(35.04552459716797, 17.750778198242188, 4819.267578125))
                                            end
                                        until game:GetService("Workspace").SeaBeasts:FindFirstChild("SeaBeast1") or _G.AutoBuyBoat == false
                                    end
                                end
                            elseif game:GetService("Workspace").Boats:FindFirstChild("PirateBrigade") then
                                for is,vs in pairs(game:GetService("Workspace").Boats:GetChildren()) do
                                    if vs.Name == "PirateBrigade" then
                                        if vs:FindFirstChild("VehicleSeat") then
                                            repeat wait()
                                                game.Players.LocalPlayer.Character:WaitForChild("Humanoid").Sit = false
                                                TPP(vs.VehicleSeat.CFrame * CFrame.new(0,1,0))
                                            until not game:GetService("Workspace").Boats:FindFirstChild("PirateBrigade") or _G.AutoBuyBoat == false
                                        end
                                    end
                                end
                            end
                        elseif game:GetService("Workspace").Boats:FindFirstChild("PirateBrigade") then
                            for iss,v in pairs(game:GetService("Workspace").Boats:GetChildren()) do
                                if v.Name == "PirateBrigade" then
                                    if v:FindFirstChild("VehicleSeat") then
                                        repeat wait()
                                            game.Players.LocalPlayer.Character:WaitForChild("Humanoid").Sit = false
                                            TPP(v.VehicleSeat.CFrame * CFrame.new(0,1,0))
                                        until not game:GetService("Workspace").Boats:FindFirstChild("PirateBrigade") or _G.AutoBuyBoat == false
                                    end
                                end
                            end
                        end
                    elseif game:GetService("Workspace").SeaBeasts:FindFirstChild("SeaBeast1") then  
                        for i,v in pairs(game:GetService("Workspace").SeaBeasts:GetChildren()) do
                            if v:FindFirstChild("HumanoidRootPart") then
                                repeat wait()
                                    game.Players.LocalPlayer.Character:WaitForChild("Humanoid").Sit = false
                                    TPP(v.HumanoidRootPart.CFrame * CFrame.new(0,500,0))
                                    EquipAllWeapon()  
                                    AutoSkill = true
                                    AimBotSkillPosition = v.HumanoidRootPart
                                    Skillaimbot = true
                                until not v:FindFirstChild("HumanoidRootPart") or _G.AutoBuyBoat == false
                                AutoSkill = false
                                Skillaimbot = false
                            end
                        end
                    end
                end
            end)
        end
    end)


   local ToggleTW = Tabs.Main:AddToggle("ToggleTW", {Title = "Auto Press W", Default = false })

   ToggleTW:OnChanged(function(Value)
    _G.AutoW = Value
    end)
    Options.ToggleTW:SetValue(false)
    spawn(function()
        while wait() do
            pcall(function()
                if _G.AutoW then
                    game:GetService("VirtualInputManager"):SendKeyEvent(true,"W",false,game)
                end
            end)
        end
        end)
    


    local ToggleTerrorshark = Tabs.Main:AddToggle("ToggleTerrorshark", {Title = "Auto Kill Terrorshark", Default = false })

    ToggleTerrorshark:OnChanged(function(Value)
        _G.AutoTerrorshark = Value
    end)
    Options.ToggleTerrorshark:SetValue(false)
    spawn(function()
        while wait() do
            if  _G.AutoTerrorshark then
                pcall(function()
                    if game:GetService("Workspace").Enemies:FindFirstChild("Terrorshark") then
                        for i,v in pairs(game:GetService("Workspace").Enemies:GetChildren()) do
                            if v.Name == "Terrorshark" then
                                if v:FindFirstChild("Humanoid") and v:FindFirstChild("HumanoidRootPart") and v.Humanoid.Health > 0 then
                                    repeat task.wait()
                                        AutoHaki()
                                        EquipTool(SelectWeapon)
                                        v.HumanoidRootPart.CanCollide = false
                                        v.Humanoid.WalkSpeed = 0
                                        v.HumanoidRootPart.Size = Vector3.new(50,50,50)
                                        Click()
                                        Tween(v.HumanoidRootPart.CFrame * CFrame.new(posX,posY,posZ))
                                    until not  _G.AutoTerrorshark or not v.Parent or v.Humanoid.Health <= 0
                                end
                            end
                        end
                    else
                      
                        if game:GetService("ReplicatedStorage"):FindFirstChild("Terrorshark") then
                            Tween(game:GetService("ReplicatedStorage"):FindFirstChild("Terrorshark").HumanoidRootPart.CFrame * CFrame.new(2,20,2))
                        else
                        end
                    end
                end)
            end
        end
     end)



     local TogglePiranha = Tabs.Main:AddToggle("TogglePiranha", {Title = "Auto Kill Piranha", Default = false })

     TogglePiranha:OnChanged(function(Value)
        _G.farmpiranya = Value
     end)
     Options.TogglePiranha:SetValue(false)

     spawn(function()
        while wait() do
            if  _G.farmpiranya then
                pcall(function()
                    if game:GetService("Workspace").Enemies:FindFirstChild("Piranha") then
                        for i,v in pairs(game:GetService("Workspace").Enemies:GetChildren()) do
                            if v.Name == "Piranha" then
                                if v:FindFirstChild("Humanoid") and v:FindFirstChild("HumanoidRootPart") and v.Humanoid.Health > 0 then
                                    repeat task.wait()
                                        AutoHaki()
                                        EquipTool(SelectWeapon)
                                        v.HumanoidRootPart.CanCollide = false
                                        v.Humanoid.WalkSpeed = 0
                                        v.HumanoidRootPart.Size = Vector3.new(50,50,50)
                                        Click()
                                        Tween(v.HumanoidRootPart.CFrame * CFrame.new(posX,posY,posZ))
                                    until not  _G.farmpiranya or not v.Parent or v.Humanoid.Health <= 0
                                end
                            end
                        end
                    else
                     
                        if game:GetService("ReplicatedStorage"):FindFirstChild("Piranha") then
                            Tween(game:GetService("ReplicatedStorage"):FindFirstChild("Piranha").HumanoidRootPart.CFrame * CFrame.new(2,20,2))
                        else  
                        end
                    end
                end)
            end
        end
     end)



     Tabs.Main:AddParagraph({
        Title = "Elite Hunter",
        Content = "Auto find and kill boss elite"
    })


    local ToggleElite = Tabs.Main:AddToggle("ToggleElite", {Title = "Auto Elite Hunter", Default = false })

    ToggleElite:OnChanged(function(Value)
       _G.AutoElite = Value
       end)
       Options.ToggleElite:SetValue(false)
       spawn(function()
           while task.wait() do
               if _G.AutoElite then
                   pcall(function()
                       if game:GetService("Players").LocalPlayer.PlayerGui.Main.Quest.Visible == true then
                           if string.find(game:GetService("Players").LocalPlayer.PlayerGui.Main.Quest.Container.QuestTitle.Title.Text,"Diablo") or string.find(game:GetService("Players").LocalPlayer.PlayerGui.Main.Quest.Container.QuestTitle.Title.Text,"Deandre") or string.find(game:GetService("Players").LocalPlayer.PlayerGui.Main.Quest.Container.QuestTitle.Title.Text,"Urban") then
                               if game:GetService("Workspace").Enemies:FindFirstChild("Diablo") or game:GetService("Workspace").Enemies:FindFirstChild("Deandre") or game:GetService("Workspace").Enemies:FindFirstChild("Urban") then
                                   for i,v in pairs(game:GetService("Workspace").Enemies:GetChildren()) do
                                       if v:FindFirstChild("Humanoid") and v:FindFirstChild("HumanoidRootPart") and v.Humanoid.Health > 0 then
                                           if v.Name == "Diablo" or v.Name == "Deandre" or v.Name == "Urban" then
                                               repeat task.wait()
                                                   EquipTool(SelectWeapon)
                                                   AutoHaki()
                                                   Tween(v.HumanoidRootPart.CFrame * Pos)
                                                   MonsterPosition = v.HumanoidRootPart.CFrame
                                                   v.HumanoidRootPart.CFrame = v.HumanoidRootPart.CFrame
                                                   v.Humanoid.JumpPower = 0
                                                   v.Humanoid.WalkSpeed = 0
                                                   v.HumanoidRootPart.CanCollide = false
                                                   --v.Humanoid:ChangeState(14)
                                                   --v.Humanoid:ChangeState(11)
                                                   Click()
                                                   FarmPos = v.HumanoidRootPart.CFrame
                                                   MonFarm = v.Name
                                                   v.HumanoidRootPart.Size = Vector3.new(1, 1, 1)
                                                   BringMobs = false
                                               until _G.AutoElite == false or v.Humanoid.Health <= 0 or not v.Parent
                                           end
                                           BringMobs = true
                                       end
                                   end
                               else
                                   if BypassTP then
                                   if game:GetService("ReplicatedStorage"):FindFirstChild("Diablo") then
                                       BTP(game:GetService("ReplicatedStorage"):FindFirstChild("Diablo").HumanoidRootPart.CFrame * CFrame.new(posX,posY,posZ))
                                   elseif game:GetService("ReplicatedStorage"):FindFirstChild("Deandre") then
                                       BTP(game:GetService("ReplicatedStorage"):FindFirstChild("Deandre").HumanoidRootPart.CFrame * CFrame.new(posX,posY,posZ))
                                   elseif game:GetService("ReplicatedStorage"):FindFirstChild("Urban") then
                                       BTP(game:GetService("ReplicatedStorage"):FindFirstChild("Urban").HumanoidRootPart.CFrame * CFrame.new(posX,posY,posZ))
                                   end
                               else
                                   if game:GetService("ReplicatedStorage"):FindFirstChild("Diablo") then
                                       Tween(game:GetService("ReplicatedStorage"):FindFirstChild("Diablo").HumanoidRootPart.CFrame * CFrame.new(posX,posY,posZ))
                                   elseif game:GetService("ReplicatedStorage"):FindFirstChild("Deandre") then
                                       Tween(game:GetService("ReplicatedStorage"):FindFirstChild("Deandre").HumanoidRootPart.CFrame * CFrame.new(posX,posY,posZ))
                                   elseif game:GetService("ReplicatedStorage"):FindFirstChild("Urban") then
                                       Tween(game:GetService("ReplicatedStorage"):FindFirstChild("Urban").HumanoidRootPart.CFrame * CFrame.new(posX,posY,posZ))
                                   end
   
                               end
                               end
                           end
                       else
                           game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("EliteHunter")
                       end
                   end)
               end
			   BirngMobs = true
           end
       end)
   
    end

if Third_Sea then

       Tabs.Main:AddParagraph({
        Title = "Sea Beast",
        Content = "Auto Kill Sea Beast"
    })


local ToggleSeaBeAst = Tabs.Main:AddToggle("ToggleSeaBeAst", {Title = "Auto Sea Beast", Default = false })

ToggleSeaBeAst:OnChanged(function(Value)
    _G.AutoSeaBeast = Value
    end)
    Options.ToggleSeaBeAst:SetValue(false)
    local gg = getrawmetatable(game)
    local old = gg.__namecall
    setreadonly(gg,false)
    gg.__namecall = newcclosure(function(...)
        local method = getnamecallmethod()
        local args = {...}
        if tostring(method) == "FireServer" then
            if tostring(args[1]) == "RemoteEvent" then
                if tostring(args[2]) ~= "true" and tostring(args[2]) ~= "false" then
                    if Skillaimbot then
                        args[2] = AimBotSkillPosition
                        return old(unpack(args))
                    end
                end
            end
        end
        return old(...)
    end)
    
    
    Skillz = true
    Skillx = true
    Skillc = true
    Skillv = true
    
    spawn(function()
        while wait() do
            pcall(function()
                if AutoSkill then
                    if Skillz then
                        game:service('VirtualInputManager'):SendKeyEvent(true, "Z", false, game)
                        wait(.1)
                        game:service('VirtualInputManager'):SendKeyEvent(false, "Z", false, game)
                    end
                    if Skillx then
                        game:service('VirtualInputManager'):SendKeyEvent(true, "X", false, game)
                        wait(.1)
                        game:service('VirtualInputManager'):SendKeyEvent(false, "X", false, game)
                    end
                    if Skillc then
                        game:service('VirtualInputManager'):SendKeyEvent(true, "C", false, game)
                        wait(.1)
                        game:service('VirtualInputManager'):SendKeyEvent(false, "C", false, game)
                    end
                    if Skillv then
                        game:service('VirtualInputManager'):SendKeyEvent(true, "V", false, game)
                        wait(.1)
                        game:service('VirtualInputManager'):SendKeyEvent(false, "V", false, game)
                    end
                end
            end)
        end
    end)
    task.spawn(function()
        while wait() do
            pcall(function()
                if _G.AutoSeaBeast then
                    if not game:GetService("Workspace").SeaBeasts:FindFirstChild("SeaBeast1") then
                        if not game:GetService("Workspace").Boats:FindFirstChild("PirateBrigade") then 
                            if not game:GetService("Workspace").Boats:FindFirstChild("PirateBasic") then
                                if not game:GetService("Workspace").Boats:FindFirstChild("PirateBrigade") then
                                    buyb = TPP(CFrame.new(-4513.90087890625, 16.76398277282715, -2658.820556640625))
                                    if (CFrame.new(-4513.90087890625, 16.76398277282715, -2658.820556640625).Position - game.Players.LocalPlayer.Character.HumanoidRootPart.Position).magnitude <= 10 then
                                        if buyb then buyb:Stop() end
                                        local args = {
                                            [1] = "BuyBoat",
                                            [2] = "PirateBrigade"
                                        }
            
                                        game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer(unpack(args))
                                    end
                                elseif game:GetService("Workspace").Boats:FindFirstChild("PirateBrigade") then
                                    if game.Players.LocalPlayer.Character:WaitForChild("Humanoid").Sit == false then
                                        TPP(game:GetService("Workspace").Boats.PirateBrigade.VehicleSeat.CFrame * CFrame.new(0,1,0))
                                    elseif game.Players.LocalPlayer.Character:WaitForChild("Humanoid").Sit == true then
                                        repeat wait()
                                            if (game:GetService("Workspace").Boats.PirateBrigade.VehicleSeat.CFrame.Position - game.Players.LocalPlayer.Character.HumanoidRootPart.Position).magnitude <= 10 then
                                                TPB(CFrame.new(35.04552459716797, 17.750778198242188, 4819.267578125))
                                            end
                                        until game:GetService("Workspace").SeaBeasts:FindFirstChild("SeaBeast1") or _G.AutoSeaBeast == false
                                    end
                                end
                            elseif game:GetService("Workspace").Boats:FindFirstChild("PirateBrigade") then
                                for is,vs in pairs(game:GetService("Workspace").Boats:GetChildren()) do
                                    if vs.Name == "PirateBrigade" then
                                        if vs:FindFirstChild("VehicleSeat") then
                                            repeat wait()
                                                game.Players.LocalPlayer.Character:WaitForChild("Humanoid").Sit = false
                                                TPP(vs.VehicleSeat.CFrame * CFrame.new(0,1,0))
                                            until not game:GetService("Workspace").Boats:FindFirstChild("PirateBrigade") or _G.AutoSeaBeast == false
                                        end
                                    end
                                end
                            end
                        elseif game:GetService("Workspace").Boats:FindFirstChild("PirateBrigade") then
                            for iss,v in pairs(game:GetService("Workspace").Boats:GetChildren()) do
                                if v.Name == "PirateBrigade" then
                                    if v:FindFirstChild("VehicleSeat") then
                                        repeat wait()
                                            game.Players.LocalPlayer.Character:WaitForChild("Humanoid").Sit = false
                                            TPP(v.VehicleSeat.CFrame * CFrame.new(0,1,0))
                                        until not game:GetService("Workspace").Boats:FindFirstChild("PirateBrigade") or _G.AutoSeaBeast == false
                                    end
                                end
                            end
                        end
                    elseif game:GetService("Workspace").SeaBeasts:FindFirstChild("SeaBeast1") then  
                        for i,v in pairs(game:GetService("Workspace").SeaBeasts:GetChildren()) do
                            if v:FindFirstChild("HumanoidRootPart") then
                                repeat wait()
                                    game.Players.LocalPlayer.Character:WaitForChild("Humanoid").Sit = false
                                    TPP(v.HumanoidRootPart.CFrame * CFrame.new(0,500,0))
                                    EquipAllWeapon()  
                                    AutoSkill = true
                                    AimBotSkillPosition = v.HumanoidRootPart
                                    Skillaimbot = true
                                until not v:FindFirstChild("HumanoidRootPart") or _G.AutoSeaBeast == false
                                AutoSkill = false
                                Skillaimbot = false
                            end
                        end
                    end
                end
            end)
        end
    end)

local ToggleAutoW = Tabs.Main:AddToggle("ToggleAutoW", {Title = "Auto Press W", Default = false })
ToggleAutoW:OnChanged(function(Value)
    _G.AutoW = Value
    end)
 Options.ToggleAutoW:SetValue(false)
 spawn(function()
    while wait() do
        pcall(function()
            if _G.AutoW then
                game:GetService("VirtualInputManager"):SendKeyEvent(true,"W",false,game)
            end
        end)
    end
    end)




 Tabs.Main:AddParagraph({
    Title = "Mirage Island",
    Content = "Auto Summon Mystic Island"
})



local ToggleMirage = Tabs.Main:AddToggle("ToggleMirage", {Title = "Auto Mirage Island", Default = false })
ToggleMirage:OnChanged(function(Value)
    if state then
        _G.dao = true
    else
        _G.dao = false
    end


if _G.dao then
local args = {
    [1] = "requestEntrance",
    [2] = Vector3.new(-12463.6025390625, 378.3270568847656, -7566.0830078125)
}
game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer(unpack(args))
wait(1)
BTPZ(CFrame.new(-5411.22021, 778.609863, -2682.27759, 0.927179396, 0, 0.374617696, 0, 1, 0, -0.374617696, 0, 0.927179396))

local args = {
    [1] = "BuyBoat",
    [2] = "MarineBrigade"
}
game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer(unpack(args))

function two(gotoCFrame) --- Tween
      pcall(function()
          game.Players.LocalPlayer.Character.Humanoid.Sit = false
          game.Players.LocalPlayer.Character.HumanoidRootPart.Anchored = false
      end)
      if (game:GetService("Players")["LocalPlayer"].Character.HumanoidRootPart.Position - gotoCFrame.Position).Magnitude <= 200 then
          pcall(function() 
              tweenz:Cancel()
          end)
          game:GetService("Players")["LocalPlayer"].Character.HumanoidRootPart.CFrame = gotoCFrame
      else
          local tween_s = game:service"TweenService"
          local info = TweenInfo.new((game:GetService("Players")["LocalPlayer"].Character.HumanoidRootPart.Position - gotoCFrame.Position).Magnitude/325, Enum.EasingStyle.Linear)
           tween, err = pcall(function()
              tweenz = tween_s:Create(game.Players.LocalPlayer.Character["HumanoidRootPart"], info, {CFrame = gotoCFrame})
              tweenz:Play()
          end)
          if not tween then return err end
      end
      function _TweenCanCle()
          tweenz:Cancel()
      end
  
end
two(CFrame.new(-5100.7085, 29.968586, -6792.45459, -0.33648631, -0.0396691673, 0.940852463, -6.40461678e-07, 0.999112308, 0.0421253517, -0.941688359, 0.0141740013, -0.336187631))

wait(13)
for _,v in next, workspace.Boats.MarineBrigade:GetDescendants() do
    if v.Name:find("VehicleSeat") then
    game.Players.LocalPlayer.Character.HumanoidRootPart.CFrame = v.CFrame
     if game:GetService("Workspace").Map:FindFirstChild("MysticIsland") then
                           Tween(game:GetService("Workspace").Map:FindFirstChild("MysticIsland").HumanoidRootPart.CFrame * CFrame.new(0,500,-100))
   
    end
    end
end
end
end) 

 Options.ToggleMirage:SetValue(false)


 local AutoW = Tabs.Main:AddToggle("AutoW", {Title = "Auto Press W", Default = false })
 AutoW:OnChanged(function(Value)
    _G.AutoW = Value
     end)
  Options.AutoW:SetValue(false)
  spawn(function()
    while wait() do
        pcall(function()
            if _G.AutoW then
                game:GetService("VirtualInputManager"):SendKeyEvent(true,"W",false,game)
            end
        end)
    end
    end)
end

     Tabs.items:AddParagraph({
        Title = "Items",
        Content = "Auto Get Items"
    })


    local ToggleHallow = Tabs.items:AddToggle("ToggleHallow", {Title = "Auto Hallow Scythe [Fully]", Default = false })

    ToggleHallow:OnChanged(function(Value)
        AutoHallowSycthe = Value
    end)
    Options.ToggleHallow:SetValue(false)
    spawn(function()
        while wait() do
            if AutoHallowSycthe then
                pcall(function()
                    if game:GetService("Workspace").Enemies:FindFirstChild("Soul Reaper") then
                        for i,v in pairs(game:GetService("Workspace").Enemies:GetChildren()) do
                            if string.find(v.Name , "Soul Reaper") then
                                repeat task.wait()
                                    AutoHaki()
                                    EquipTool(SelectWeapon)
                                    v.HumanoidRootPart.Size = Vector3.new(50,50,50)
                                    Tween(v.HumanoidRootPart.CFrame * Pos)
                                    v.HumanoidRootPart.Transparency = 1
                                    sethiddenproperty(game.Players.LocalPlayer,"SimulationRadius",math.huge)
									Click()
                                until v.Humanoid.Health <= 0 or AutoHallowSycthe == false
                            end
                        end
                    elseif game:GetService("Players").LocalPlayer.Backpack:FindFirstChild("Hallow Essence") or game:GetService("Players").LocalPlayer.Character:FindFirstChild("Hallow Essence") then
                        repeat Tween(CFrame.new(-8932.322265625, 146.83154296875, 6062.55078125)) wait() until (CFrame.new(-8932.322265625, 146.83154296875, 6062.55078125).Position - game.Players.LocalPlayer.Character.HumanoidRootPart.Position).Magnitude <= 8                        
                        EquipTool("Hallow Essence")
                    else
                        if game:GetService("ReplicatedStorage"):FindFirstChild("Soul Reaper") then
                            Tween(game:GetService("ReplicatedStorage"):FindFirstChild("Soul Reaper").HumanoidRootPart.CFrame * CFrame.new(2,20,2))
                        else
                        end
                    end
                end)
            end
        end
    end)
	
	
	spawn(function()
           while wait(0.001) do
           if AutoHallowSycthe then
           local args = {
            [1] = "Bones",
            [2] = "Buy",
            [3] = 1,
            [4] = 1
           }
          
           game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer(unpack(args))
           end
           end
           end)
        
           
           local ToggleYama = Tabs.items:AddToggle("ToggleYama", {Title = "Auto Get Yama", Default = false })
           ToggleYama:OnChanged(function(Value)
            _G.AutoYama = Value
           end)
           Options.ToggleYama:SetValue(false)
           spawn(function()
            while wait() do
                if _G.AutoYama then
                    if game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("EliteHunter","Progress") >= 30 then
                        repeat wait(.1)
                            fireclickdetector(game:GetService("Workspace").Map.Waterfall.SealedKatana.Handle.ClickDetector)
                        until game:GetService("Players").LocalPlayer.Backpack:FindFirstChild("Yama") or not _G.AutoYama
                    end
                end
            end
        end)


        local ToggleTushita = Tabs.items:AddToggle("ToggleTushita", {Title = "Auto Tushita", Default = false })
        ToggleTushita:OnChanged(function(Value)
            AutoTushita = Value
        end)
        Options.ToggleTushita:SetValue(false)
        local FaiFaoTushita = CFrame.new(-10238.875976563, 389.7912902832, -9549.7939453125)
        spawn(function()
            while task.wait(.1) do
                if AutoTushita then
                    pcall(function()
                        autoTushita()
                    end)
                end
            end
        end)
        function enemyrip()
            Tween(CFrame.new(-5332.30371, 423.985413, -2673.48218))
            wait()
            if game.Workspace.Enemies:FindFirstChild("rip_indra True Form") then
                local mobs = game.Workspace.Enemies:GetChildren()
                for i,v in pairs(mobs) do
                    if v.Name == "rip_indra True Form" and v:IsA("Model") and v:FindFirstChild("Humanoid") and
                        v:FindFirstChild("HumanoidRootPart") and v.Humanoid.Health > 0 then
                        return v
                    end
                end
            end
            return game.ReplicatedStorage:FindFirstChild("rip_indra True Form")
        end
        function enemyEliteBoss()
            if game.Workspace.Enemies:FindFirstChild("Deandre") or game.Workspace.Enemies:FindFirstChild("Urban") or game.Workspace.Enemies:FindFirstChild("Diablo") then
                local mobs = game.Workspace.Enemies:GetChildren()
                for i,v in pairs(mobs) do
                    if v.Name == "Deandre" or v.Name == "Diablo" or v.Name == "Urban"  and v:IsA("Model") and v:FindFirstChild("Humanoid") and
                        v:FindFirstChild("HumanoidRootPart") and v.Humanoid.Health > 0 then
                        return v
                    end
                end
            end
            return game.ReplicatedStorage:FindFirstChild("Deandre") or game.ReplicatedStorage:FindFirstChild("Urban") or game.ReplicatedStorage:FindFirstChild("Diablo")
        end
        function enemylongma()
            Tween(CFrame.new(-10171.7051, 406.981995, -9552.31738))
            if game.Workspace.Enemies:FindFirstChild("Longma") then
                local mobs = game.Workspace.Enemies:GetChildren()
                for i,v in pairs(mobs) do
                    if v.Name == "Longma" and v:IsA("Model") and v:FindFirstChild("Humanoid") and
                        v:FindFirstChild("HumanoidRootPart") and v.Humanoid.Health > 0 then
                        return v
                    end
                end
            end
            return game.ReplicatedStorage:FindFirstChild("Longma")
        end
        function autoTushita()
            if not game.Players.LocalPlayer.Backpack:FindFirstChild("God's Chalice") and not game.Players.LocalPlayer.Character:FindFirstChild("God's Chalice") then
                if game.Workspace.Enemies:FindFirstChild("Deandre") or game.Workspace.Enemies:FindFirstChild("Urban") or game.Workspace.Enemies:FindFirstChild("Diablo") or game.ReplicatedStorage:FindFirstChild("Deandre") or game.ReplicatedStorage:FindFirstChild("Urban") or game.ReplicatedStorage:FindFirstChild("Diablo") then
                    if game:GetService("Players").LocalPlayer.PlayerGui.Main.Quest.Visible == false then
                        repeat Tween(CFrame.new(5420.49219, 314.446045, -2823.07373)) wait() until not AutoTushita or (game.Players.LocalPlayer.Character.HumanoidRootPart.Position-Vector3.new(5420.49219, 314.446045, -2823.07373)).Magnitude <= 10
                        wait(1)
                        repeat Tween(CFrame.new(5420.49219, 314.446045, -2823.07373)) wait() until not AutoTushita or (game.Players.LocalPlayer.Character.HumanoidRootPart.Position-Vector3.new(5420.49219, 314.446045, -2823.07373)).Magnitude <= 10
                        wait(1.1)
                        game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("EliteHunter")
                        wait(1)
                    elseif game:GetService("Players").LocalPlayer.PlayerGui.Main.Quest.Visible == true then
                        CheckLevel()
                        AutoHaki()
                        pcall(function()
                            EquipTool(SelectWeapon)
                            pcall(function()
                                local v = enemyEliteBoss()
                                v.HumanoidRootPart.CanCollide = false
                                v.HumanoidRootPart.Size = Vector3.new(50, 50, 50)
                                Tween(v.HumanoidRootPart.CFrame * CFrame.new(posX,posY,posZ))
                                Click()
                            end)
                        end)
                    end
                else
                    Tween(CFrame.new(-12554.9443, 337.194092, -7501.44727))
                end
            elseif game.Players.LocalPlayer.Backpack:FindFirstChild("God's Chalice") or game.Players.LocalPlayer.Character:FindFirstChild("God's Chalice") then
                game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("activateColor","Winter Sky")
                wait(0.5)
                repeat Tween(CFrame.new(-5420.16602, 1084.9657, -2666.8208)) wait() until not AutoTushita or (game.Players.LocalPlayer.Character.HumanoidRootPart.Position-Vector3.new(-5420.16602, 1084.9657, -2666.8208)).Magnitude <= 10
                wait(0.5)
                game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("activateColor","Pure Red")
                wait(0.5)
                repeat Tween(CFrame.new(-5414.41357, 309.865753, -2212.45776)) wait() until not AutoTushita or (game.Players.LocalPlayer.Character.HumanoidRootPart.Position-Vector3.new(-5414.41357, 309.865753, -2212.45776)).Magnitude <= 10
                wait(0.5)
                game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("activateColor","Snow White")
                wait(0.5)
                repeat Tween(CFrame.new(-4971.47559, 331.565765, -3720.02954)) wait() until not AutoTushita or (game.Players.LocalPlayer.Character.HumanoidRootPart.Position-Vector3.new(-4971.47559, 331.565765, -3720.02954)).Magnitude <= 10
                wait(0.5)
                EquipTool("God's Chalice")
                wait(0.5)
                repeat Tween(CFrame.new(-5560.27295, 313.915466, -2663.89795)) wait() until not AutoTushita or (game.Players.LocalPlayer.Character.HumanoidRootPart.Position-Vector3.new(-5560.27295, 313.915466, -2663.89795)).Magnitude <= 10
                wait(0.5)
                repeat Tween(CFrame.new(-5561.37451, 313.342529, -2663.4948)) wait() until not AutoTushita or (game.Players.LocalPlayer.Character.HumanoidRootPart.Position-Vector3.new(5420.49219, 314.446045, -2823.07373)).Magnitude <= 10
                wait(1)
                repeat Tween(CFrame.new(5154.17676, 141.786423, 911.046326)) wait() until not AutoTushita or (game.Players.LocalPlayer.Character.HumanoidRootPart.Position-Vector3.new(5420.49219, 314.446045, -2823.07373)).Magnitude <= 10
                wait(0.2)
                repeat Tween(CFrame.new(5148.03613, 162.352493, 910.548218)) wait() until not AutoTushita or (game.Players.LocalPlayer.Character.HumanoidRootPart.Position-Vector3.new(5420.49219, 314.446045, -2823.07373)).Magnitude <= 10
                wait(1)
                EquipTool("Holy Torch")
                wait(1)
                wait(0.4)
                repeat Tween(CFrame.new(-10752.7695, 412.229523, -9366.36328)) wait() until not AutoTushita or (game.Players.LocalPlayer.Character.HumanoidRootPart.Position-Vector3.new(5420.49219, 314.446045, -2823.07373)).Magnitude <= 10
                wait(0.4)
                repeat Tween(CFrame.new(-11673.4111, 331.749023, -9474.34668)) wait() until not AutoTushita or (game.Players.LocalPlayer.Character.HumanoidRootPart.Position-Vector3.new(5420.49219, 314.446045, -2823.07373)).Magnitude <= 10
                wait(0.4)
                repeat Tween(CFrame.new(-12133.3389, 519.47522, -10653.1904)) wait() until not AutoTushita or (game.Players.LocalPlayer.Character.HumanoidRootPart.Position-Vector3.new(5420.49219, 314.446045, -2823.07373)).Magnitude <= 10
                wait(0.4)
                repeat Tween(CFrame.new(-13336.5, 485.280396, -6983.35254)) wait() until not AutoTushita or (game.Players.LocalPlayer.Character.HumanoidRootPart.Position-Vector3.new(5420.49219, 314.446045, -2823.07373)).Magnitude <= 10
                wait(0.4)
                repeat Tween(CFrame.new(-13487.4131, 334.84845, -7926.34863)) wait() until not AutoTushita or (game.Players.LocalPlayer.Character.HumanoidRootPart.Position-Vector3.new(5420.49219, 314.446045, -2823.07373)).Magnitude <= 10
                wait(1)
            elseif game.Workspace.Enemies:FindFirstChild("Longma") or game.ReplicatedStorage:FindFirstChild("Longma") then
                pcall(function()
                    EquipTool(SelectWeapon)
                    AutoHaki()
                    pcall(function()
                        local v = enemylongma()
                        v.HumanoidRootPart.CanCollide = false
                        v.HumanoidRootPart.Size = Vector3.new(50, 50, 50)
                        Tween(v.HumanoidRootPart.CFrame * CFrame.new(posX,posY,posZ))
                        Click()
                    end)
                end)
            elseif game.Workspace.Enemies:FindFirstChild("rip_indra True Form")  or game.ReplicatedStorage:FindFirstChild("rip_indra True Form") then
                pcall(function()
                    EquipTool(SelectWeapon)
                    AutoHaki()
                    pcall(function()
                        local v = enemyrip()
                        v.HumanoidRootPart.CanCollide = false
                        v.HumanoidRootPart.Size = Vector3.new(50, 50, 50)
                        Tween(v.HumanoidRootPart.CFrame * CFrame.new(posX,posY,posZ))
                        Click()
                    end)
                end)
            else
                Tween(CFrame.new(-12554.9443, 337.194092, -7501.44727))
            end
        end



        local ToggleFactory = Tabs.items:AddToggle("ToggleFactory", {Title = "Auto Farm Factory", Default = false })
        ToggleFactory:OnChanged(function(Value)
            _G.Factory = Value
        end)
        Options.ToggleFactory:SetValue(false)

        spawn(function()
            while wait() do
                if _G.Factory then
                    if game.Workspace.Enemies:FindFirstChild("Core") then
                        for i,v in pairs(game.Workspace.Enemies:GetChildren()) do
                            if v.Name == "Core" and v.Humanoid.Health > 0 then
                                repeat wait(.1)
                                    repeat Tween(CFrame.new(448.46756, 199.356781, -441.389252))
                                        wait()
                                    until not _G.Factory or (game.Players.LocalPlayer.Character.HumanoidRootPart.Position-Vector3.new(448.46756, 199.356781, -441.389252)).Magnitude <= 10
                                    EquipTool(SelectWeapon)
                                    AutoHaki()
                                    Tween(v.HumanoidRootPart.CFrame * CFrame.new(posX,posY,posZ))
                                    v.HumanoidRootPart.Size = Vector3.new(60, 60, 60)
                                    v.HumanoidRootPart.Transparency = 1
                                    v.Humanoid.JumpPower = 0
                                    v.Humanoid.WalkSpeed = 0
                                    v.HumanoidRootPart.CanCollide = false
                                    FarmPos = v.HumanoidRootPart.CFrame
                                    MonFarm = v.Name
                                    Click()
                                until not v.Parent or v.Humanoid.Health <= 0  or _G.Factory == false
                            end
                        end
                    elseif game.ReplicatedStorage:FindFirstChild("Core") then
                        repeat Tween(CFrame.new(448.46756, 199.356781, -441.389252))
                            wait()
                        until not _G.Factory or (game.Players.LocalPlayer.Character.HumanoidRootPart.Position-Vector3.new(448.46756, 199.356781, -441.389252)).Magnitude <= 10
                    end
                end
            end
        end)




   
--------------------------------------------------------------------------------------------------------------------------------------------
--Setting
    Tabs.Setting:AddParagraph({
        Title = "Setting",
        Content = "Setting Farm"
    })

    local ToggleFastAttack = Tabs.Setting:AddToggle("ToggleFastAttack", {Title = "Fast Attack", Default = true })
    ToggleFastAttack:OnChanged(function(vu)
        FastAttack = vu
    end)
    Options.ToggleFastAttack:SetValue(true)




_G.FastAttackDelay = 0.13

    local Client = game.Players.LocalPlayer
    local STOP = require(Client.PlayerScripts.CombatFramework.Particle)
    local STOPRL = require(game:GetService("ReplicatedStorage").CombatFramework.RigLib)
    spawn(function()
        while task.wait() do
            pcall(function()
                if not shared.orl then shared.orl = STOPRL.wrapAttackAnimationAsync end
                if not shared.cpc then shared.cpc = STOP.play end
                    STOPRL.wrapAttackAnimationAsync = function(a,b,c,d,func)
                    local Hits = STOPRL.getBladeHits(b,c,d)
                    if Hits then
                        if FastAttack then
                            STOP.play = function() end
                            a:Play(0.01,0.01,0.01)
                            func(Hits)
                            STOP.play = shared.cpc
                            wait(a.length * 0.5)
                            a:Stop()
                        else
                            a:Play()
                        end
                    end
                end
            end)
        end
    end)

function GetBladeHit()
    local CombatFrameworkLib = debug.getupvalues(require(game:GetService("Players").LocalPlayer.PlayerScripts.CombatFramework))
    local CmrFwLib = CombatFrameworkLib[2]
    local p13 = CmrFwLib.activeController
    local weapon = p13.blades[1]
    if not weapon then 
        return weapon
    end
    while weapon.Parent ~= game.Players.LocalPlayer.Character do
        weapon = weapon.Parent 
    end
    return weapon
end
function AttackHit()
    local CombatFrameworkLib = debug.getupvalues(require(game:GetService("Players").LocalPlayer.PlayerScripts.CombatFramework))
    local CmrFwLib = CombatFrameworkLib[2]
    local plr = game.Players.LocalPlayer
    for i = 1, 1 do
        local bladehit = require(game.ReplicatedStorage.CombatFramework.RigLib).getBladeHits(plr.Character,{plr.Character.HumanoidRootPart},60)
        local cac = {}
        local hash = {}
        for k, v in pairs(bladehit) do
            if v.Parent:FindFirstChild("HumanoidRootPart") and not hash[v.Parent] then
                table.insert(cac, v.Parent.HumanoidRootPart)
                hash[v.Parent] = true
            end
        end
        bladehit = cac
        if #bladehit > 0 then
            pcall(function()
                CmrFwLib.activeController.timeToNextAttack = 1
                CmrFwLib.activeController.attacking = false
                CmrFwLib.activeController.blocking = false
                CmrFwLib.activeController.timeToNextBlock = 0
                CmrFwLib.activeController.increment = 3
                CmrFwLib.activeController.hitboxMagnitude = 60
                CmrFwLib.activeController.focusStart = 0
                game:GetService("ReplicatedStorage").RigControllerEvent:FireServer("weaponChange",tostring(GetBladeHit()))
                game:GetService("ReplicatedStorage").RigControllerEvent:FireServer("hit", bladehit, i, "")
            end)
        end
    end
end
spawn(function()
    while wait(.1) do
        if FastAttack then
            pcall(function()
                repeat task.wait(_G.FastAttackDelay)
                    AttackHit()
                until not FastAttack
            end)
        end
    end
end)

local CamShake = require(game.ReplicatedStorage.Util.CameraShaker)
CamShake:Stop()



    local ToggleBringMob = Tabs.Setting:AddToggle("ToggleBringMob", {Title = "Bring Mob", Default = true })
    ToggleBringMob:OnChanged(function(Value)
        BringMobs = Value
    end)
    Options.ToggleBringMob:SetValue(true)
	task.spawn(function()
        while task.wait() do
        if BringMobs then
        pcall(function()
          for i,v in pairs(game.Workspace.Enemies:GetChildren()) do
          if not string.find(v.Name,"Boss") and v.Name == MonFarm and (v.HumanoidRootPart.Position - game.Players.LocalPlayer.Character.HumanoidRootPart.Position).Magnitude <= 350 then
          if InMyNetWork(v.HumanoidRootPart) then
            if InMyNetWork(v.HumanoidRootPart) then
          v.HumanoidRootPart.CFrame = FarmPos
          v.HumanoidRootPart.CanCollide = false
          v.HumanoidRootPart.Size = Vector3.new(1,1,1)
		  if v.Humanoid:FindFirstChild("Animator") then
			v.Humanoid.Animator:Destroy()
		end
          end
        end
          end
          end
          end)
        end

    end
        end)
      
      task.spawn(function()
        while true do wait()
        if setscriptable then
        setscriptable(game.Players.LocalPlayer,"SimulationRadius",true)
        end
        if sethiddenproperty then
        sethiddenproperty(game.Players.LocalPlayer,"SimulationRadius",math.huge)
        end
        end
        end)
      
      function InMyNetWork(object)
      if isnetworkowner then
      return isnetworkowner(object)
      else
        if (object.Position - game.Players.LocalPlayer.Character.HumanoidRootPart.Position).Magnitude <= 350 then
      return true
      end
      return false
      end
      end



    local ToggleBypassTP = Tabs.Setting:AddToggle("ToggleBypassTP", {Title = "Bypass Tp", Default = false })
    ToggleBypassTP:OnChanged(function(Value)
        BypassTP = Value
    end)
    Options.ToggleBypassTP:SetValue(true)
end


    Tabs.Setting:AddButton({
        Title = "Fps Booster",
        Description = "Boost your fps",
        Callback = function()
            FPSBooster()
        end
    })

    function FPSBooster()
        local decalsyeeted = true
        local g = game
        local w = g.Workspace
        local l = g.Lighting
        local t = w.Terrain
        sethiddenproperty(l,"Technology",2)
        sethiddenproperty(t,"Decoration",false)
        t.WaterWaveSize = 0
        t.WaterWaveSpeed = 0
        t.WaterReflectance = 0
        t.WaterTransparency = 0
        l.GlobalShadows = false
        l.FogEnd = 9e9
        l.Brightness = 0
        settings().Rendering.QualityLevel = "Level01"
        for i, v in pairs(g:GetDescendants()) do
            if v:IsA("Part") or v:IsA("Union") or v:IsA("CornerWedgePart") or v:IsA("TrussPart") then
                v.Material = "Plastic"
                v.Reflectance = 0
            elseif v:IsA("Decal") or v:IsA("Texture") and decalsyeeted then
                v.Transparency = 1
            elseif v:IsA("ParticleEmitter") or v:IsA("Trail") then
                v.Lifetime = NumberRange.new(0)
            elseif v:IsA("Explosion") then
                v.BlastPressure = 1
                v.BlastRadius = 1
            elseif v:IsA("Fire") or v:IsA("SpotLight") or v:IsA("Smoke") or v:IsA("Sparkles") then
                v.Enabled = false
            elseif v:IsA("MeshPart") then
                v.Material = "Plastic"
                v.Reflectance = 0
                v.TextureID = 10385902758728957
            end
        end
        for i, e in pairs(l:GetChildren()) do
            if e:IsA("BlurEffect") or e:IsA("SunRaysEffect") or e:IsA("ColorCorrectionEffect") or e:IsA("BloomEffect") or e:IsA("DepthOfFieldEffect") then
                e.Enabled = false
            end
        end
    end


local ToggleRemove = Tabs.Setting:AddToggle("ToggleRemove", {Title = "Remove Dame Text", Default = true })
ToggleRemove:OnChanged(function(Value)
    FaiFaoRemovetext = Value
    end)
    Options.ToggleRemove:SetValue(true)

    spawn(function()
        while wait() do
            if FaiFaoRemovetext then
                game:GetService("ReplicatedStorage").Assets.GUI.DamageCounter.Enabled = false
            else
                game:GetService("ReplicatedStorage").Assets.GUI.DamageCounter.Enabled = true
            end
        end
        end)



Tabs.Setting:AddParagraph({
    Title = "Setting Skill",
    Content = "Skill use for farm mastery"
})

local ToggleZ = Tabs.Setting:AddToggle("ToggleZ", {Title = "Skill Z", Default = true })
ToggleZ:OnChanged(function(Value)
    SkillZ = Value
end)
Options.ToggleZ:SetValue(true)

local ToggleX = Tabs.Setting:AddToggle("ToggleX", {Title = "Skill X", Default = true })
ToggleX:OnChanged(function(Value)
    SkillX = Value
end)
Options.ToggleX:SetValue(true)


local ToggleC = Tabs.Setting:AddToggle("ToggleC", {Title = "Skill C", Default = true })
ToggleC:OnChanged(function(Value)
    SkillC = Value
end)
Options.ToggleC:SetValue(true)


local ToggleV = Tabs.Setting:AddToggle("ToggleV", {Title = "Skill V", Default = true })
ToggleV:OnChanged(function(Value)
    SkillV = Value
end)
Options.ToggleV:SetValue(true)


local ToggleF = Tabs.Setting:AddToggle("ToggleF", {Title = "Skill F", Default = true })
ToggleF:OnChanged(function(Value)
   SkillF = Value
    end)
Options.ToggleF:SetValue(true)

--------------------------------------------------------------------------------------------------------------------------------------------
--Stats
local ToggleMelee = Tabs.Stats:AddToggle("ToggleMelee", {Title = "Auto Melee", Default = false })
ToggleMelee:OnChanged(function(Value)
    _G.Auto_Stats_Melee = Value
    end)
Options.ToggleMelee:SetValue(false)




local ToggleDe = Tabs.Stats:AddToggle("ToggleDe", {Title = "Auto Defense", Default = false })
ToggleDe:OnChanged(function(Value)
    _G.Auto_Stats_Defense = Value
    end)
Options.ToggleDe:SetValue(false)



local ToggleSword = Tabs.Stats:AddToggle("ToggleSword", {Title = "Auto Sword", Default = false })
ToggleSword:OnChanged(function(Value)
    _G.Auto_Stats_Sword = Value
    end)
Options.ToggleSword:SetValue(false)



local ToggleGun = Tabs.Stats:AddToggle("ToggleGun", {Title = "Auto Gun", Default = false })
ToggleGun:OnChanged(function(Value)
    _G.Auto_Stats_Gun = Value
    end)
Options.ToggleGun:SetValue(false)


local ToggleFruit = Tabs.Stats:AddToggle("ToggleFruit", {Title = "Auto Demon Fruit", Default = false })
ToggleFruit:OnChanged(function(Value)
    _G.Auto_Stats_Devil_Fruit = Value
    end)
Options.ToggleFruit:SetValue(false)


spawn(function()
    while wait() do
        if _G.Auto_Stats_Devil_Fruit then
            local args = {
                [1] = "AddPoint",
                [2] = "Demon Fruit",
                [3] = 3
            }
                        
            game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer(unpack(args))
        end
    end
end)

spawn(function()
    while wait() do
        if _G.Auto_Stats_Gun then
            local args = {
                [1] = "AddPoint",
                [2] = "Gun",
                [3] = 3
            }
                        
            game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer(unpack(args))
        end
    end
end)


spawn(function()
    while wait() do
        if _G.Auto_Stats_Sword then
            local args = {
                [1] = "AddPoint",
                [2] = "Sword",
                [3] = 3
            }
                        
            game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer(unpack(args))
        end
    end
end)

spawn(function()
    while wait() do
        if _G.Auto_Stats_Defense then
            local args = {
                [1] = "AddPoint",
                [2] = "Defense",
                [3] = 3
            }
                        
            game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer(unpack(args))
        end
    end
end)


spawn(function()
    while wait() do
        if _G.Auto_Stats_Melee then
            local args = {
                [1] = "AddPoint",
                [2] = "Melee",
                [3] = 3
            }
                        
            game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer(unpack(args))
        end
    end
end)
--------------------------------------------------------------------------------------------------------------------------------------------
--Player

local Playerslist = {}
for i,v in pairs(game:GetService("Players"):GetChildren()) do
    table.insert(Playerslist,v.Name)
end

local SelectedPly = Tabs.Player:AddDropdown("SelectedPly", {
    Title = "SelectedPly",
    Values = Playerslist,
    Multi = false,
    Default = 1,
})

SelectedPly:SetValue("nil")
SelectedPly:OnChanged(function(Value)
    _G.SelectPly = Value
end)

    
Tabs.Player:AddButton({
    Title = "Refresh Dropdown",
    Description = "Refresh player list",
    Callback = function()
        Playerslist = {}
        SelectedPly:Clear()
        for i,v in pairs(game:GetService("Players"):GetChildren()) do  
            SelectedPly:Add(v.Name)
        end
    end          
})

local ToggleTeleport = Tabs.Player:AddToggle("ToggleTeleport", {Title = "Teleport To Player", Default = false })
ToggleTeleport:OnChanged(function(Value)
    _G.TeleportPly = Value
    pcall(function()
        if _G.TeleportPly then
            repeat Tween(game:GetService("Players")[_G.SelectPly].Character.HumanoidRootPart.CFrame) wait() until _G.TeleportPly == false
        end
    end)
end)

Options.ToggleTeleport:SetValue(false)



local ToggleQuanSat = Tabs.Player:AddToggle("ToggleQuanSat", {Title = "Spectate Player", Default = false })
ToggleQuanSat:OnChanged(function(Value)
    SpectatePlys = Value
    local plr1 = game:GetService("Players").LocalPlayer.Character.Humanoid
    local plr2 = game:GetService("Players"):FindFirstChild(_G.SelectPly)
    repeat wait(.1)
        game:GetService("Workspace").Camera.CameraSubject = game:GetService("Players"):FindFirstChild(_G.SelectPly).Character.Humanoid
    until SpectatePlys == false 
    game:GetService("Workspace").Camera.CameraSubject = game:GetService("Players").LocalPlayer.Character.Humanoid
end)
Options.ToggleQuanSat:SetValue(false)


-----------------------------------------------------------------------------------------------------------------------------------------------
--Teleport
Tabs.Teleport:AddParagraph({
    Title = "World",
    Content = "Sea1 & Sea2 & Sea3"
})

Tabs.Teleport:AddButton({
    Title = "First Sea",
    Description = "",
    Callback = function()
        game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("TravelMain")
    end
})



Tabs.Teleport:AddButton({
    Title = "Second Sea",
    Description = "",
    Callback = function()
        game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("TravelDressrosa")
    end
})



Tabs.Teleport:AddButton({
    Title = "Third Sea",
    Description = "",
    Callback = function()
        game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("TravelZou")
    end
})



Tabs.Teleport:AddParagraph({
    Title = "Island",
    Content = "Teleport to Island"
})

if First_Sea then
 IslandList = {
                "WindMill",
                "Marine",
                "Middle Town",
                "Jungle",
                "Pirate Village",
                "Desert",
                "Snow Island",
                "MarineFord",
                "Colosseum",
                "Sky Island 1",
                "Sky Island 2",
                "Sky Island 3",
                "Prison",
                "Magma Village",
                "Under Water Island",
                "Fountain City",
                "Shank Room",
                "Mob Island",
}

elseif Second_Sea then
       IslandList = {
        "The Cafe",
        "Frist Spot",
        "Dark Area",
        "Flamingo Mansion",
        "Flamingo Room",
        "Green Zone",
        "Factory",
        "Colossuim",
        "Zombie Island",
        "Two Snow Mountain",
        "Punk Hazard",
        "Cursed Ship",
        "Ice Castle",
        "Forgotten Island",
        "Ussop Island",
        "Mini Sky Island",
       }

elseif Third_Sea then
    IslandList = {
        "Mansion",
        "Port Town",
        "Great Tree",
        "Castle On The Sea",
        "MiniSky", 
        "Hydra Island",
        "Floating Turtle",
        "Haunted Castle",
        "Ice Cream Island",
        "Peanut Island",
        "Cake Island",
        "Cocoa Island",
        "Candy Island",
       }
    end

local DropdownIsland = Tabs.Teleport:AddDropdown("Island",{
    Title = "Island",
    Values = IslandList,
    Multi = false,
    Default = 1,
})

DropdownIsland:SetValue("...")
DropdownIsland:OnChanged(function(Value)
    _G.SelectIsland = Value
end)



local ToggleIsland = Tabs.Teleport:AddToggle("ToggleIsland", {Title = "Teleport", Default = false })
ToggleIsland:OnChanged(function(Value)
    _G.TeleportIsland = Value
    if _G.TeleportIsland == true then
        repeat wait()
            if _G.SelectIsland == "WindMill" then
                Tween(CFrame.new(979.79895019531, 16.516613006592, 1429.0466308594))
            elseif _G.SelectIsland == "Marine" then
                Tween(CFrame.new(-2566.4296875, 6.8556680679321, 2045.2561035156))
            elseif _G.SelectIsland == "Middle Town" then
                Tween(CFrame.new(-690.33081054688, 15.09425163269, 1582.2380371094))
            elseif _G.SelectIsland == "Jungle" then
                Tween(CFrame.new(-1612.7957763672, 36.852081298828, 149.12843322754))
            elseif _G.SelectIsland == "Pirate Village" then
                Tween(CFrame.new(-1181.3093261719, 4.7514905929565, 3803.5456542969))
            elseif _G.SelectIsland == "Desert" then
                Tween(CFrame.new(944.15789794922, 20.919729232788, 4373.3002929688))
            elseif _G.SelectIsland == "Snow Island" then
                Tween(CFrame.new(1347.8067626953, 104.66806030273, -1319.7370605469))
            elseif _G.SelectIsland == "MarineFord" then
                Tween(CFrame.new(-4914.8212890625, 50.963626861572, 4281.0278320313))
            elseif _G.SelectIsland == "Colosseum" then
                Tween( CFrame.new(-1427.6203613281, 7.2881078720093, -2792.7722167969))
            elseif _G.SelectIsland == "Sky Island 1" then
                Tween(CFrame.new(-4869.1025390625, 733.46051025391, -2667.0180664063))
            elseif _G.SelectIsland == "Sky Island 2" then  
                game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("requestEntrance",Vector3.new(-4607.82275, 872.54248, -1667.55688))
            elseif _G.SelectIsland == "Sky Island 3" then
                game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("requestEntrance",Vector3.new(-7894.6176757813, 5547.1416015625, -380.29119873047))
            elseif _G.SelectIsland == "Prison" then
                Tween( CFrame.new(4875.330078125, 5.6519818305969, 734.85021972656))
            elseif _G.SelectIsland == "Magma Village" then
                Tween(CFrame.new(-5247.7163085938, 12.883934020996, 8504.96875))
            elseif _G.SelectIsland == "Under Water Island" then
                game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("requestEntrance",Vector3.new(61163.8515625, 11.6796875, 1819.7841796875))
            elseif _G.SelectIsland == "Fountain City" then
                Tween(CFrame.new(5127.1284179688, 59.501365661621, 4105.4458007813))
            elseif _G.SelectIsland == "Shank Room" then
                Tween(CFrame.new(-1442.16553, 29.8788261, -28.3547478))
            elseif _G.SelectIsland == "Mob Island" then
                Tween(CFrame.new(-2850.20068, 7.39224768, 5354.99268))
            elseif _G.SelectIsland == "The Cafe" then
                Tween(CFrame.new(-380.47927856445, 77.220390319824, 255.82550048828))
            elseif _G.SelectIsland == "Frist Spot" then
                Tween(CFrame.new(-11.311455726624, 29.276733398438, 2771.5224609375))
            elseif _G.SelectIsland == "Dark Area" then
                Tween(CFrame.new(3780.0302734375, 22.652164459229, -3498.5859375))
            elseif _G.SelectIsland == "Flamingo Mansion" then
                Tween(CFrame.new(-483.73370361328, 332.0383605957, 595.32708740234))
            elseif _G.SelectIsland == "Flamingo Room" then
                Tween(CFrame.new(2284.4140625, 15.152037620544, 875.72534179688))
            elseif _G.SelectIsland == "Green Zone" then
                Tween( CFrame.new(-2448.5300292969, 73.016105651855, -3210.6306152344))
            elseif _G.SelectIsland == "Factory" then
                Tween(CFrame.new(424.12698364258, 211.16171264648, -427.54049682617))
            elseif _G.SelectIsland == "Colossuim" then
                Tween( CFrame.new(-1503.6224365234, 219.7956237793, 1369.3101806641))
            elseif _G.SelectIsland == "Zombie Island" then
                Tween(CFrame.new(-5622.033203125, 492.19604492188, -781.78552246094))
            elseif _G.SelectIsland == "Two Snow Mountain" then
                Tween(CFrame.new(753.14288330078, 408.23559570313, -5274.6147460938))
            elseif _G.SelectIsland == "Punk Hazard" then
                Tween(CFrame.new(-6127.654296875, 15.951762199402, -5040.2861328125))
            elseif _G.SelectIsland == "Cursed Ship" then
                Tween(CFrame.new(923.40197753906, 125.05712890625, 32885.875))
            elseif _G.SelectIsland == "Ice Castle" then
                Tween(CFrame.new(6148.4116210938, 294.38687133789, -6741.1166992188))
            elseif _G.SelectIsland == "Forgotten Island" then
                Tween(CFrame.new(-3032.7641601563, 317.89672851563, -10075.373046875))
            elseif _G.SelectIsland == "Ussop Island" then
                Tween(CFrame.new(4816.8618164063, 8.4599885940552, 2863.8195800781))
            elseif _G.SelectIsland == "Mini Sky Island" then
                Tween(CFrame.new(-288.74060058594, 49326.31640625, -35248.59375))
            elseif _G.SelectIsland == "Great Tree" then
                Tween(CFrame.new(2681.2736816406, 1682.8092041016, -7190.9853515625))
            elseif _G.SelectIsland == "Castle On The Sea" then
                BTPZ(CFrame.new(-5075.50927734375, 314.5155029296875, -3150.0224609375))
            elseif _G.SelectIsland == "MiniSky" then
                Tween(CFrame.new(-260.65557861328, 49325.8046875, -35253.5703125))
            elseif _G.SelectIsland == "Port Town" then
                Tween(CFrame.new(-290.7376708984375, 6.729952812194824, 5343.5537109375))
            elseif _G.SelectIsland == "Hydra Island" then
                Tween(CFrame.new(5228.8842773438, 604.23400878906, 345.0400390625))
            elseif _G.SelectIsland == "Floating Turtle" then
                Tween(CFrame.new(-13274.528320313, 531.82073974609, -7579.22265625))
            elseif _G.SelectIsland == "Mansion" then
                game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("requestEntrance",Vector3.new(-12471.169921875, 374.94024658203, -7551.677734375))
            elseif _G.SelectIsland == "Haunted Castle" then
                Tween(CFrame.new(-9515.3720703125, 164.00624084473, 5786.0610351562))
            elseif _G.SelectIsland == "Ice Cream Island" then
                Tween(CFrame.new(-902.56817626953, 79.93204498291, -10988.84765625))
            elseif _G.SelectIsland == "Peanut Island" then
                Tween(CFrame.new(-2062.7475585938, 50.473892211914, -10232.568359375))
            elseif _G.SelectIsland == "Cake Island" then
                Tween(CFrame.new(-1884.7747802734375, 19.327526092529297, -11666.8974609375))
            elseif _G.SelectIsland == "Cocoa Island" then
                Tween(CFrame.new(87.94276428222656, 73.55451202392578, -12319.46484375))
            elseif _G.SelectIsland == "Candy Island" then
                Tween(CFrame.new(-1014.4241943359375, 149.11068725585938, -14555.962890625))
            end
        until not _G.TeleportIsland
    end
end)
Options.ToggleIsland:SetValue(false)

function BTPZ(Point)
    game.Players.LocalPlayer.Character.HumanoidRootPart.CFrame = Point
    task.wait()
    game.Players.LocalPlayer.Character.HumanoidRootPart.CFrame = Point
        end

--------------------------------------------------------------------------------------------------------------------------------------------
--Fruit

local Remote_GetFruits = game.ReplicatedStorage:FindFirstChild("Remotes").CommF_:InvokeServer("GetFruits");
Table_DevilFruitSniper = {}
ShopDevilSell = {}
for i,v in next,Remote_GetFruits do
    table.insert(Table_DevilFruitSniper,v.Name)
    if v.OnSale then 
        table.insert(ShopDevilSell,v.Name)
    end
end

_G.SelectFruit = ""

local DropdownFruit = Tabs.Fruit:AddDropdown("DropdownFruit", {
    Title = "Fruit",
    Values = Table_DevilFruitSniper,
    Multi = false,
    Default = 1,
})

DropdownFruit:SetValue("...")

DropdownFruit:OnChanged(function(Value)
    _G.SelectFruit = Value
end)


local ToggleFruit = Tabs.Fruit:AddToggle("ToggleFruit", {Title = "Buy Fruit Sniper", Default = false })
ToggleFruit:OnChanged(function(Value)
    _G.AutoBuyFruitSniper = Value
end)
Options.ToggleFruit:SetValue(false)
spawn(function()
    pcall(function()
        while wait(.1) do
            if _G.AutoBuyFruitSniper then
                game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("GetFruits")
                game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("PurchaseRawFruit","_G.SelectFruit",false)
            end 
        end
    end)
end)


local ToggleStore = Tabs.Fruit:AddToggle("ToggleStore", {Title = "Store Fruit", Default = false })
ToggleStore:OnChanged(function(Value)
    _G.AutoStoreFruit = Value
end)
Options.ToggleStore:SetValue(false)

spawn(function()
    while task.wait() do
        if _G.AutoStoreFruit then
            pcall(function()
                if _G.AutoStoreFruit then
                    if game:GetService("Players").LocalPlayer.Character:FindFirstChild("Bomb Fruit") or game:GetService("Players").LocalPlayer.Backpack:FindFirstChild("Bomb Fruit") then
                        game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("StoreFruit","Bomb-Bomb",game:GetService("Players").LocalPlayer.Backpack:FindFirstChild("Bomb Fruit"))
                    end
                    if game:GetService("Players").LocalPlayer.Character:FindFirstChild("Spike Fruit") or game:GetService("Players").LocalPlayer.Backpack:FindFirstChild("Spike Fruit") then
                        game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("StoreFruit","Spike-Spike",game:GetService("Players").LocalPlayer.Backpack:FindFirstChild("Spike Fruit"))
                    end
                    if game:GetService("Players").LocalPlayer.Character:FindFirstChild("Chop Fruit") or game:GetService("Players").LocalPlayer.Backpack:FindFirstChild("Chop Fruit") then
                        game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("StoreFruit","Chop-Chop",game:GetService("Players").LocalPlayer.Backpack:FindFirstChild("Chop Fruit"))
                    end
                    if game:GetService("Players").LocalPlayer.Character:FindFirstChild("Spring Fruit") or game:GetService("Players").LocalPlayer.Backpack:FindFirstChild("Spring Fruit") then
                        game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("StoreFruit","Spring-Spring",game:GetService("Players").LocalPlayer.Backpack:FindFirstChild("Spring Fruit"))
                    end
                    if game:GetService("Players").LocalPlayer.Character:FindFirstChild("Rocket Fruit") or game:GetService("Players").LocalPlayer.Backpack:FindFirstChild("Kilo Fruit") then
                        game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("StoreFruit","Rocket-Rocket",game:GetService("Players").LocalPlayer.Backpack:FindFirstChild("Kilo Fruit"))
                    end
                    if game:GetService("Players").LocalPlayer.Character:FindFirstChild("Smoke Fruit") or game:GetService("Players").LocalPlayer.Backpack:FindFirstChild("Smoke Fruit") then
                        game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("StoreFruit","Smoke-Smoke",game:GetService("Players").LocalPlayer.Backpack:FindFirstChild("Smoke Fruit"))
                    end
                    if game:GetService("Players").LocalPlayer.Character:FindFirstChild("Spin Fruit") or game:GetService("Players").LocalPlayer.Backpack:FindFirstChild("Spin Fruit") then
                        game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("StoreFruit","Spin-Spin",game:GetService("Players").LocalPlayer.Backpack:FindFirstChild("Spin Fruit"))
                    end
                    if game:GetService("Players").LocalPlayer.Character:FindFirstChild("Flame Fruit") or game:GetService("Players").LocalPlayer.Backpack:FindFirstChild("Flame Fruit") then
                        game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("StoreFruit","Flame-Flame",game:GetService("Players").LocalPlayer.Backpack:FindFirstChild("Flame Fruit"))
                    end
                    if game:GetService("Players").LocalPlayer.Character:FindFirstChild("Bird: Falcon Fruit") or game:GetService("Players").LocalPlayer.Backpack:FindFirstChild("Bird: Falcon Fruit") then
                        game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("StoreFruit","Bird-Bird: Falcon",game:GetService("Players").LocalPlayer.Backpack:FindFirstChild("Bird: Falcon Fruit"))
                    end
                    if game:GetService("Players").LocalPlayer.Character:FindFirstChild("Ice Fruit") or game:GetService("Players").LocalPlayer.Backpack:FindFirstChild("Ice Fruit") then
                        game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("StoreFruit","Ice-Ice",game:GetService("Players").LocalPlayer.Backpack:FindFirstChild("Ice Fruit"))
                    end
                    if game:GetService("Players").LocalPlayer.Character:FindFirstChild("Sand Fruit") or game:GetService("Players").LocalPlayer.Backpack:FindFirstChild("Sand Fruit") then
                        game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("StoreFruit","Sand-Sand",game:GetService("Players").LocalPlayer.Backpack:FindFirstChild("Sand Fruit"))
                    end
                    if game:GetService("Players").LocalPlayer.Character:FindFirstChild("Dark Fruit") or game:GetService("Players").LocalPlayer.Backpack:FindFirstChild("Dark Fruit") then
                        game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("StoreFruit","Dark-Dark",game:GetService("Players").LocalPlayer.Backpack:FindFirstChild("Dark Fruit"))
                    end
                    if game:GetService("Players").LocalPlayer.Character:FindFirstChild("Ghost Fruit") or game:GetService("Players").LocalPlayer.Backpack:FindFirstChild("Revive Fruit") then
                        game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("StoreFruit","Ghost-Ghost",game:GetService("Players").LocalPlayer.Backpack:FindFirstChild("Revive Fruit"))
                    end
                    if game:GetService("Players").LocalPlayer.Character:FindFirstChild("Diamond Fruit") or game:GetService("Players").LocalPlayer.Backpack:FindFirstChild("Diamond Fruit") then
                        game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("StoreFruit","Diamond-Diamond",game:GetService("Players").LocalPlayer.Backpack:FindFirstChild("Diamond Fruit"))
                    end
                    if game:GetService("Players").LocalPlayer.Character:FindFirstChild("Light Fruit") or game:GetService("Players").LocalPlayer.Backpack:FindFirstChild("Light Fruit") then
                        game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("StoreFruit","Light-Light",game:GetService("Players").LocalPlayer.Backpack:FindFirstChild("Light Fruit"))
                    end
                    if game:GetService("Players").LocalPlayer.Character:FindFirstChild("Love Fruit") or game:GetService("Players").LocalPlayer.Backpack:FindFirstChild("Love Fruit") then
                        game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("StoreFruit","Love-Love",game:GetService("Players").LocalPlayer.Backpack:FindFirstChild("Love Fruit"))
                    end
                    if game:GetService("Players").LocalPlayer.Character:FindFirstChild("Rubber Fruit") or game:GetService("Players").LocalPlayer.Backpack:FindFirstChild("Rubber Fruit") then
                        game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("StoreFruit","Rubber-Rubber",game:GetService("Players").LocalPlayer.Backpack:FindFirstChild("Rubber Fruit"))
                    end
                    if game:GetService("Players").LocalPlayer.Character:FindFirstChild("Barrier Fruit") or game:GetService("Players").LocalPlayer.Backpack:FindFirstChild("Barrier Fruit") then
                        game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("StoreFruit","Barrier-Barrier",game:GetService("Players").LocalPlayer.Backpack:FindFirstChild("Barrier Fruit"))
                    end
                    if game:GetService("Players").LocalPlayer.Character:FindFirstChild("Magma Fruit") or game:GetService("Players").LocalPlayer.Backpack:FindFirstChild("Magma Fruit") then
                        game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("StoreFruit","Magma-Magma",game:GetService("Players").LocalPlayer.Backpack:FindFirstChild("Magma Fruit"))
                    end
                    if game:GetService("Players").LocalPlayer.Character:FindFirstChild("Portal Fruit") or game:GetService("Players").LocalPlayer.Backpack:FindFirstChild("Door Fruit") then
                        game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("StoreFruit","Door-Door",game:GetService("Players").LocalPlayer.Backpack:FindFirstChild("Portal Fruit"))
                    end

                    if game:GetService("Players").LocalPlayer.Character:FindFirstChild("Quake Fruit") or game:GetService("Players").LocalPlayer.Backpack:FindFirstChild("Quake Fruit") then
                        game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("StoreFruit","Quake-Quake",game:GetService("Players").LocalPlayer.Backpack:FindFirstChild("Quake Fruit"))
                    end
                    if game:GetService("Players").LocalPlayer.Character:FindFirstChild("Human-Human: Buddha Fruit") or game:GetService("Players").LocalPlayer.Backpack:FindFirstChild("Human-Human: Buddha Fruit") then
                        game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("StoreFruit","Human-Human: Buddha",game:GetService("Players").LocalPlayer.Backpack:FindFirstChild("Human-Human: Buddha Fruit"))
                    end
                    if game:GetService("Players").LocalPlayer.Character:FindFirstChild("Spider Fruit") or game:GetService("Players").LocalPlayer.Backpack:FindFirstChild("Spider Fruit") then
                        game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("StoreFruit","Spider-Spider",game:GetService("Players").LocalPlayer.Backpack:FindFirstChild("Spider Fruit"))
                    end
                    if game:GetService("Players").LocalPlayer.Character:FindFirstChild("Bird: Phoenix Fruit") or game:GetService("Players").LocalPlayer.Backpack:FindFirstChild("Bird: Phoenix Fruit") then
                        game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("StoreFruit","Bird-Bird: Phoenix",game:GetService("Players").LocalPlayer.Backpack:FindFirstChild("Bird: Phoenix Fruit"))
                    end
                    if game:GetService("Players").LocalPlayer.Character:FindFirstChild("Rumble Fruit") or game:GetService("Players").LocalPlayer.Backpack:FindFirstChild("Rumble Fruit") then
                        game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("StoreFruit","Rumble-Rumble",game:GetService("Players").LocalPlayer.Backpack:FindFirstChild("Rumble Fruit"))
                    end
                    if game:GetService("Players").LocalPlayer.Character:FindFirstChild("Pain Fruit") or game:GetService("Players").LocalPlayer.Backpack:FindFirstChild("Paw Fruit") then
                        game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("StoreFruit","Pain-Pain",game:GetService("Players").LocalPlayer.Backpack:FindFirstChild("Paw Fruit"))
                    end
                    if game:GetService("Players").LocalPlayer.Character:FindFirstChild("Gravity Fruit") or game:GetService("Players").LocalPlayer.Backpack:FindFirstChild("Gravity Fruit") then
                        game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("StoreFruit","Gravity-Gravity",game:GetService("Players").LocalPlayer.Backpack:FindFirstChild("Gravity Fruit"))
                    end
                    if game:GetService("Players").LocalPlayer.Character:FindFirstChild("Dough Fruit") or game:GetService("Players").LocalPlayer.Backpack:FindFirstChild("Dough Fruit") then
                        game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("StoreFruit","Dough-Dough",game:GetService("Players").LocalPlayer.Backpack:FindFirstChild("Dough Fruit"))
                    end
                    if game:GetService("Players").LocalPlayer.Character:FindFirstChild("Shadow Fruit") or game:GetService("Players").LocalPlayer.Backpack:FindFirstChild("Shadow Fruit") then
                        game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("StoreFruit","Shadow-Shadow",game:GetService("Players").LocalPlayer.Backpack:FindFirstChild("Shadow Fruit"))
                    end
                    if game:GetService("Players").LocalPlayer.Character:FindFirstChild("Venom Fruit") or game:GetService("Players").LocalPlayer.Backpack:FindFirstChild("Venom Fruit") then
                        game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("StoreFruit","Venom-Venom",game:GetService("Players").LocalPlayer.Backpack:FindFirstChild("Venom Fruit"))
                    end
                    if game:GetService("Players").LocalPlayer.Character:FindFirstChild("Control Fruit") or game:GetService("Players").LocalPlayer.Backpack:FindFirstChild("Control Fruit") then
                        game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("StoreFruit","Control-Control",game:GetService("Players").LocalPlayer.Backpack:FindFirstChild("Control Fruit"))
                    end
                    if game:GetService("Players").LocalPlayer.Character:FindFirstChild("Spirit Fruit") or game:GetService("Players").LocalPlayer.Backpack:FindFirstChild("Soul Fruit") then
                        game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("StoreFruit","Soul-Soul",game:GetService("Players").LocalPlayer.Backpack:FindFirstChild("Spirit Fruit"))
                    end
                    if game:GetService("Players").LocalPlayer.Character:FindFirstChild("Dragon Fruit") or game:GetService("Players").LocalPlayer.Backpack:FindFirstChild("Dragon Fruit") then
                        game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("StoreFruit","Dragon-Dragon",game:GetService("Players").LocalPlayer.Backpack:FindFirstChild("Dragon Fruit"))
                        if game:GetService("Players").LocalPlayer.Character:FindFirstChild("Leopard Fruit") or game:GetService("Players").LocalPlayer.Backpack:FindFirstChild("Leopard Fruit") then
                        game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("StoreFruit","Leopard-Leopard",game:GetService("Players").LocalPlayer.Backpack:FindFirstChild("Leopard Fruit"))
                    end
                end
                end
            end)
        end
        wait(0.3)
    end
    end)



local ToggleRandomFruit = Tabs.Fruit:AddToggle("ToggleRandomFruit", {Title = "Random Fruit", Default = false })
ToggleRandomFruit:OnChanged(function(Value)
    _G.Random_Auto = Value
end)
Options.ToggleRandomFruit:SetValue(false)
spawn(function()
    pcall(function()
        while wait(.1) do
            if _G.Random_Auto then
                game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("Cousin","Buy")
            end 
        end
    end)
end)

local ToggleCollect = Tabs.Fruit:AddToggle("ToggleCollect", {Title = "Collect Devil Fruit", Default = false })
ToggleCollect:OnChanged(function(Value)
    _G.Tweenfruit = Value
end)
Options.ToggleCollect:SetValue(false)

spawn(function()
    while wait(.1) do
        if _G.Tweenfruit then
            for i,v in pairs(game.Workspace:GetChildren()) do
                if string.find(v.Name, "Fruit") then
                    TP2(v.Handle.CFrame)
                end
            end
        end
end
end)

Tabs.Fruit:AddParagraph({
    Title = "Esp",
    Content = ""
})


local ToggleEspPlayer = Tabs.Fruit:AddToggle("ToggleEspPlayer", {Title = "Esp Player", Default = false })

ToggleEspPlayer:OnChanged(function(Value)
    ESPPlayer = Value
	UpdatePlayerChams()
end)
Options.ToggleEspPlayer:SetValue(false)


local ToggleEspFruit = Tabs.Fruit:AddToggle("ToggleEspFruit", {Title = "Esp Devil Fruit", Default = false })

ToggleEspFruit:OnChanged(function(Value)
    DevilFruitESP = Value
    while DevilFruitESP do wait()
        UpdateDevilChams() 
    end
end)
Options.ToggleEspFruit:SetValue(false)




local ToggleEspIsland = Tabs.Fruit:AddToggle("ToggleEspIsland", {Title = "Esp Island", Default = false })

ToggleEspIsland:OnChanged(function(Value)
    IslandESP = Value
    while IslandESP do wait()
        UpdateIslandESP() 
    end
end)
Options.ToggleEspIsland:SetValue(false)


local ToggleEspFlower = Tabs.Fruit:AddToggle("ToggleEspFlower", {Title = "Esp Flower", Default = false })

ToggleEspFlower:OnChanged(function(Value)
    FlowerESP = Value
	UpdateFlowerChams() 
end)
Options.ToggleEspFlower:SetValue(false)


spawn(function()
    while wait(2) do
        if FlowerESP then
            UpdateFlowerChams() 
        end
        if DevilFruitESP then
            UpdateDevilChams() 
        end
        if ChestESP then
            UpdateChestChams() 
        end
        if ESPPlayer then
            UpdatePlayerChams()
        end
        if RealFruitESP then
            UpdateRealFruitChams()
        end
    end
end)







--------------------------------------------------------------------------------------------------------------------------------------------
--Raid



local Chips = {"Flame","Ice","Quake","Light","Dark","Spider","Rumble","Magma","Buddha","Sand","Phoenix","Dough"}

local DropdownRaid = Tabs.Raid:AddDropdown("DropdownRaid", {
    Title = "Raid",
    Values = Chips,
    Multi = false,
    Default = 1,
})
DropdownRaid:SetValue("...")
DropdownRaid:OnChanged(function(Value)
    SelectChip = Value
end)

local ToggleBuy = Tabs.Raid:AddToggle("ToggleBuy", {Title = "Buy Chip", Default = false })
ToggleBuy:OnChanged(function(Value)
    _G.Auto_Buy_Chips_Dungeon = Value
end)
Options.ToggleBuy:SetValue(false)
spawn(function()
    while wait() do
		if _G.Auto_Buy_Chips_Dungeon then
			pcall(function()
				local args = {
					[1] = "RaidsNpc",
					[2] = "Select",
					[3] = SelectChip
				}
				game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer(unpack(args))
			end)
        end
    end
end)


    local ToggleStart = Tabs.Raid:AddToggle("ToggleStart", {Title = "Start Raid", Default = false })
    ToggleStart:OnChanged(function(Value)
        _G.Auto_StartRaid = Value
end)
Options.ToggleStart:SetValue(false)

spawn(function()
    while wait(.1) do
        pcall(function()
            if _G.Auto_StartRaid then
                if game:GetService("Players")["LocalPlayer"].PlayerGui.Main.Timer.Visible == false then
                    if not game:GetService("Workspace")["_WorldOrigin"].Locations:FindFirstChild("Island 1") and game:GetService("Players").LocalPlayer.Backpack:FindFirstChild("Special Microchip") or game:GetService("Players").LocalPlayer.Character:FindFirstChild("Special Microchip") then
                        if Second_Sea then
                            fireclickdetector(game:GetService("Workspace").Map.CircleIsland.RaidSummon2.Button.Main.ClickDetector)
                        elseif Third_Sea then
                            fireclickdetector(game:GetService("Workspace").Map["Boat Castle"].RaidSummon2.Button.Main.ClickDetector)
                        end
                    end
                end
            end
        end)
    end
end)


local ToggleKillAura = Tabs.Raid:AddToggle("ToggleKillAura", {Title = "Kill Aura", Default = false })
ToggleKillAura:OnChanged(function(Value)
    KillAura = Value
end)
Options.ToggleKillAura:SetValue(false)
spawn(function()
    while wait() do
        if KillAura then
            pcall(function()
                for i,v in pairs(game.Workspace.Enemies:GetDescendants()) do
                    if v:FindFirstChild("Humanoid") and v:FindFirstChild("HumanoidRootPart") and v.Humanoid.Health > 0 then
                        repeat task.wait()
                            sethiddenproperty(game:GetService('Players').LocalPlayer,"SimulationRadius",math.huge)
                            v.Humanoid.Health = 0
                            v.HumanoidRootPart.CanCollide = false
                        until not KillAura or not v.Parent or v.Humanoid.Health <= 0
                    end
                end
            end)
        end
    end
end)


local ToggleNextIsland = Tabs.Raid:AddToggle("ToggleNextIsland", {Title = "Next Island", Default = false })
ToggleNextIsland:OnChanged(function(Value)
    AutoNextIsland = Value
end)
Options.ToggleNextIsland:SetValue(false)
spawn(function()
    while task.wait() do
        if AutoNextIsland then
            pcall(function()
                if game:GetService("Players")["LocalPlayer"].PlayerGui.Main.Timer.Visible == true then
                    if game:GetService("Workspace")["_WorldOrigin"].Locations:FindFirstChild("Island 5") then
                        Tween(game:GetService("Workspace")["_WorldOrigin"].Locations:FindFirstChild("Island 5").CFrame * CFrame.new(0,70,100))
                    elseif game:GetService("Workspace")["_WorldOrigin"].Locations:FindFirstChild("Island 4") then
                        Tween(game:GetService("Workspace")["_WorldOrigin"].Locations:FindFirstChild("Island 4").CFrame * CFrame.new(0,70,100))
                    elseif game:GetService("Workspace")["_WorldOrigin"].Locations:FindFirstChild("Island 3") then
                        Tween(game:GetService("Workspace")["_WorldOrigin"].Locations:FindFirstChild("Island 3").CFrame * CFrame.new(0,70,100))
                    elseif game:GetService("Workspace")["_WorldOrigin"].Locations:FindFirstChild("Island 2") then
                        Tween(game:GetService("Workspace")["_WorldOrigin"].Locations:FindFirstChild("Island 2").CFrame * CFrame.new(0,70,100))
                    elseif game:GetService("Workspace")["_WorldOrigin"].Locations:FindFirstChild("Island 1") then
                        Tween(game:GetService("Workspace")["_WorldOrigin"].Locations:FindFirstChild("Island 1").CFrame * CFrame.new(0,70,100))
                    end
                end
            end)
        end
    end
end)



local ToggleAwake = Tabs.Raid:AddToggle("ToggleAwake", {Title = "Auto Awake", Default = false })
ToggleAwake:OnChanged(function(Value)
    AutoAwakenAbilities = Value
end)
Options.ToggleAwake:SetValue(false)
spawn(function()
    while task.wait() do
        if AutoAwakenAbilities then
            pcall(function()
                game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("Awakener","Awaken")
            end)
        end
    end
end)


local ToggleGetFruit = Tabs.Raid:AddToggle("ToggleGetFruit", {Title = "Get Fruit Low Bely", Default = false })
ToggleGetFruit:OnChanged(function(Value)
    _G.Autofruit = Value
end)

spawn(function()
    while wait(.1) do
        pcall(function()
     if _G.Autofruit then
         
local args = {
    [1] = "LoadFruit",
    [2] = "Rocket-Rocket"
}

game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer(unpack(args))




local args = {
    [1] = "LoadFruit",
    [2] = "Spin-Spin"
}

game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer(unpack(args))


local args = {
    [1] = "LoadFruit",
    [2] = "Chop-Chop"
}

game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer(unpack(args))





local args = {
    [1] = "LoadFruit",
    [2] = "Spring-Spring"
}

game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer(unpack(args))


local args = {
    [1] = "LoadFruit",
    [2] = "Bomb-Bomb"
}

game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer(unpack(args))


local args = {
    [1] = "LoadFruit",
    [2] = "Smoke-Smoke"
}

game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer(unpack(args))


local args = {
    [1] = "LoadFruit",
    [2] = "Spike-Spike"
}

game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer(unpack(args))


local args = {
    [1] = "LoadFruit",
    [2] = "Flame-Flame"
}

game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer(unpack(args))


local args = {
    [1] = "LoadFruit",
    [2] = "Falcon-Falcon"
}

game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer(unpack(args))


local args = {
    [1] = "LoadFruit",
    [2] = "Ice-Ice"
}

game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer(unpack(args))


local args = {
    [1] = "LoadFruit",
    [2] = "Sand-Sand"
}

game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer(unpack(args))


local args = {
    [1] = "LoadFruit",
    [2] = "Dark-Dark"
}

game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer(unpack(args))


local args = {
    [1] = "LoadFruit",
    [2] = "Ghost-Ghost"
}

game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer(unpack(args))


local args = {
    [1] = "LoadFruit",
    [2] = "Diamond-Diamond"
}

game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer(unpack(args))


local args = {
    [1] = "LoadFruit",
    [2] = "Light-Light"
}

game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer(unpack(args))


local args = {
    [1] = "LoadFruit",
    [2] = "Rubber-Rubber"
}

game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer(unpack(args))


local args = {
    [1] = "LoadFruit",
    [2] = "Barrier-Barrier"
}

game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer(unpack(args))
end
end)
end
end)


if Second_Sea then
Tabs.Raid:AddButton({
    Title = "Raid Lab",
    Description = "",
    Callback = function()
        TP2(CFrame.new(-6438.73535, 250.645355, -4501.50684))
    end
})
elseif Third_Sea then
    Tabs.Raid:AddButton({
        Title = "Raid Lab",
        Description = "",
        Callback = function()
            TP2(CFrame.new(-5017.40869, 314.844055, -2823.0127, -0.925743818, 4.48217499e-08, -0.378151238, 4.55503146e-09, 1, 1.07377559e-07, 0.378151238, 9.7681621e-08, -0.925743818))
        end
    })
end



Tabs.Raid:AddParagraph({
    Title = "Raid Law",
    Content = ""
})


local ToggleLaw = Tabs.Raid:AddToggle("ToggleLaw", {Title = "Auto Law", Default = false })

ToggleLaw:OnChanged(function(Value)
    Auto_Law = Value
end)
Options.ToggleLaw:SetValue(false)
spawn(function()
    pcall(function()
        while wait() do
            if Auto_Law then
                if not game:GetService("Players").LocalPlayer.Character:FindFirstChild("Microchip") and not game:GetService("Players").LocalPlayer.Backpack:FindFirstChild("Microchip") and not game:GetService("Workspace").Enemies:FindFirstChild("Order") and not game:GetService("ReplicatedStorage"):FindFirstChild("Order") then
                    wait(1)
                    game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("BlackbeardReward","Microchip","1")
                    game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("BlackbeardReward","Microchip","2")
                end
            end
        end
    end)
end)

spawn(function()
    pcall(function()
        while wait(.1) do
            if Auto_Law then
                if not game:GetService("Workspace").Enemies:FindFirstChild("Order") and not game:GetService("ReplicatedStorage"):FindFirstChild("Order") then
                    if game:GetService("Players").LocalPlayer.Character:FindFirstChild("Microchip") or game:GetService("Players").LocalPlayer.Backpack:FindFirstChild("Microchip") then
                        fireclickdetector(game:GetService("Workspace").Map.CircleIsland.RaidSummon.Button.Main.ClickDetector)
                    end
                end
                if game:GetService("ReplicatedStorage"):FindFirstChild("Order") or game:GetService("Workspace").Enemies:FindFirstChild("Order") then
                    if game:GetService("Workspace").Enemies:FindFirstChild("Order") then
                        for i,v in pairs(game:GetService("Workspace").Enemies:GetChildren()) do
                            if v.Name == "Order" then
                                repeat game:GetService("RunService").Heartbeat:wait()
                                    AutoHaki()
                                    EquipTool(SelectWeapon)
                                    Tween(v.HumanoidRootPart.CFrame * Pos)
                                    v.HumanoidRootPart.CanCollide = false
                                    v.HumanoidRootPart.Size = Vector3.new(120, 120, 120)
                                    Click()
                                until not v.Parent or v.Humanoid.Health <= 0 or Auto_Law == false
                            end
                        end
                    elseif game:GetService("ReplicatedStorage"):FindFirstChild("Order") then
                        Tween(CFrame.new(-6217.2021484375, 28.047645568848, -5053.1357421875))
                    end
                end
            end
        end
    end)
end)

--------------------------------------------------------------------------------------------------------------------------------------------
--RaceV4


Tabs.Race:AddButton({
    Title = "Timple Of Time",
    Description = "",
    Callback = function()
        game:GetService("Players").LocalPlayer.Character.HumanoidRootPart.CFrame = CFrame.new(28286.35546875, 14895.3017578125, 102.62469482421875)
    end
})


Tabs.Race:AddButton({
    Title = "Lever Pull",
    Description = "",
    Callback = function()
        TP2(CFrame.new(28575.181640625, 14936.6279296875, 72.31636810302734))
    end
})


Tabs.Race:AddButton({
    Title = "Acient One",
    Description = "",
    Callback = function()
        TP2(CFrame.new(28981.552734375, 14888.4267578125, -120.245849609375))
    end
})


Tabs.Race:AddParagraph({
    Title = "Auto Race",
    Content = ""
})


Tabs.Race:AddButton({
    Title = "Race Door",
    Description = "",
    Callback = function()
        Game:GetService("Players").LocalPlayer.Character.HumanoidRootPart.CFrame = CFrame.new(28286.35546875, 14895.3017578125, 102.62469482421875) 
        wait(0.1)
           Game:GetService("Players").LocalPlayer.Character.HumanoidRootPart.CFrame = CFrame.new(28286.35546875, 14895.3017578125, 102.62469482421875) 
           wait(0.1)
              Game:GetService("Players").LocalPlayer.Character.HumanoidRootPart.CFrame = CFrame.new(28286.35546875, 14895.3017578125, 102.62469482421875) 
              wait(0.1)
                 Game:GetService("Players").LocalPlayer.Character.HumanoidRootPart.CFrame = CFrame.new(28286.35546875, 14895.3017578125, 102.62469482421875) 
            wait(0.5)
                    if game:GetService("Players").LocalPlayer.Data.Race.Value == "Human" then
                    TP2(CFrame.new(29221.822265625, 14890.9755859375, -205.99114990234375))
                    elseif game:GetService("Players").LocalPlayer.Data.Race.Value == "Skypiea" then
                    TP2(CFrame.new(28960.158203125, 14919.6240234375, 235.03948974609375))
                    elseif game:GetService("Players").LocalPlayer.Data.Race.Value == "Fishman" then
                    TP2(CFrame.new(28231.17578125, 14890.9755859375, -211.64173889160156))
                    elseif game:GetService("Players").LocalPlayer.Data.Race.Value == "Cyborg" then
                    TP2(CFrame.new(28502.681640625, 14895.9755859375, -423.7279357910156))
                    elseif game:GetService("Players").LocalPlayer.Data.Race.Value == "Ghoul" then
                    TP2(CFrame.new(28674.244140625, 14890.6767578125, 445.4310607910156))
                    elseif game:GetService("Players").LocalPlayer.Data.Race.Value == "Mink" then
                    TP2(CFrame.new(29012.341796875, 14890.9755859375, -380.1492614746094))
                    end
    end
})


local ToggleHumanandghoul = Tabs.Race:AddToggle("ToggleHumanandghoul", {Title = "Auto [ Human / Ghoul ] Trial", Default = false })
ToggleHumanandghoul:OnChanged(function(Value)
    KillAura = Value
end)
Options.ToggleHumanandghoul:SetValue(false)


local ToggleAutotrial = Tabs.Race:AddToggle("ToggleAutotrial", {Title = "Auto Trial", Default = false })
ToggleAutotrial:OnChanged(function(Value)
    _G.AutoQuestRace = Value
end)
Options.ToggleAutotrial:SetValue(false)
spawn(function()
    pcall(function()
        while wait() do
            if _G.AutoQuestRace then
				if game:GetService("Players").LocalPlayer.Data.Race.Value == "Human" then
					for i,v in pairs(game.Workspace.Enemies:GetDescendants()) do
						if v:FindFirstChild("Humanoid") and v:FindFirstChild("HumanoidRootPart") and v.Humanoid.Health > 0 then
							pcall(function()
								repeat wait(.1)
									v.Humanoid.Health = 0
									v.HumanoidRootPart.CanCollide = false
									sethiddenproperty(game.Players.LocalPlayer, "SimulationRadius", math.huge)
								until not _G.AutoQuestRace or not v.Parent or v.Humanoid.Health <= 0
							end)
						end
					end
				elseif game:GetService("Players").LocalPlayer.Data.Race.Value == "Skypiea" then
					for i,v in pairs(game:GetService("Workspace").Map.SkyTrial.Model:GetDescendants()) do
						if v.Name ==  "snowisland_Cylinder.081" then
							Tween(v.CFrame* CFrame.new(0,0,0))
						end
					end
				elseif game:GetService("Players").LocalPlayer.Data.Race.Value == "Fishman" then
					for i,v in pairs(game:GetService("Workspace").SeaBeasts.SeaBeast1:GetDescendants()) do
						if v.Name ==  "HumanoidRootPart" then
							Tween(v.CFrame* Pos)
							for i,v in pairs(game.Players.LocalPlayer.Backpack:GetChildren()) do
								if v:IsA("Tool") then
									if v.ToolTip == "Melee" then -- "Blox Fruit" , "Sword" , "Wear" , "Agility"
										game.Players.LocalPlayer.Character.Humanoid:EquipTool(v)
									end
								end
							end
							game:GetService("VirtualInputManager"):SendKeyEvent(true,122,false,game.Players.LocalPlayer.Character.HumanoidRootPart)
							game:GetService("VirtualInputManager"):SendKeyEvent(false,122,false,game.Players.LocalPlayer.Character.HumanoidRootPart)
							wait(.2)
							game:GetService("VirtualInputManager"):SendKeyEvent(true,120,false,game.Players.LocalPlayer.Character.HumanoidRootPart)
							game:GetService("VirtualInputManager"):SendKeyEvent(false,120,false,game.Players.LocalPlayer.Character.HumanoidRootPart)
							wait(.2)
							game:GetService("VirtualInputManager"):SendKeyEvent(true,99,false,game.Players.LocalPlayer.Character.HumanoidRootPart)
							game:GetService("VirtualInputManager"):SendKeyEvent(false,99,false,game.Players.LocalPlayer.Character.HumanoidRootPart)
							for i,v in pairs(game.Players.LocalPlayer.Backpack:GetChildren()) do
								if v:IsA("Tool") then
									if v.ToolTip == "Blox Fruit" then -- "Blox Fruit" , "Sword" , "Wear" , "Agility"
										game.Players.LocalPlayer.Character.Humanoid:EquipTool(v)
									end
								end
							end
							game:GetService("VirtualInputManager"):SendKeyEvent(true,122,false,game.Players.LocalPlayer.Character.HumanoidRootPart)
							game:GetService("VirtualInputManager"):SendKeyEvent(false,122,false,game.Players.LocalPlayer.Character.HumanoidRootPart)
							wait(.2)
							game:GetService("VirtualInputManager"):SendKeyEvent(true,120,false,game.Players.LocalPlayer.Character.HumanoidRootPart)
							game:GetService("VirtualInputManager"):SendKeyEvent(false,120,false,game.Players.LocalPlayer.Character.HumanoidRootPart)
							wait(.2)
							game:GetService("VirtualInputManager"):SendKeyEvent(true,99,false,game.Players.LocalPlayer.Character.HumanoidRootPart)
							game:GetService("VirtualInputManager"):SendKeyEvent(false,99,false,game.Players.LocalPlayer.Character.HumanoidRootPart)
					
							wait(0.5)
							for i,v in pairs(game.Players.LocalPlayer.Backpack:GetChildren()) do
								if v:IsA("Tool") then
									if v.ToolTip == "Sword" then -- "Blox Fruit" , "Sword" , "Wear" , "Agility"
										game.Players.LocalPlayer.Character.Humanoid:EquipTool(v)
									end
								end
							end
							game:GetService("VirtualInputManager"):SendKeyEvent(true,122,false,game.Players.LocalPlayer.Character.HumanoidRootPart)
							game:GetService("VirtualInputManager"):SendKeyEvent(false,122,false,game.Players.LocalPlayer.Character.HumanoidRootPart)
							wait(.2)
							game:GetService("VirtualInputManager"):SendKeyEvent(true,120,false,game.Players.LocalPlayer.Character.HumanoidRootPart)
							game:GetService("VirtualInputManager"):SendKeyEvent(false,120,false,game.Players.LocalPlayer.Character.HumanoidRootPart)
							wait(.2)
							game:GetService("VirtualInputManager"):SendKeyEvent(true,99,false,game.Players.LocalPlayer.Character.HumanoidRootPart)
							game:GetService("VirtualInputManager"):SendKeyEvent(false,99,false,game.Players.LocalPlayer.Character.HumanoidRootPart)
							wait(0.5)
							for i,v in pairs(game.Players.LocalPlayer.Backpack:GetChildren()) do
								if v:IsA("Tool") then
									if v.ToolTip == "Gun" then -- "Blox Fruit" , "Sword" , "Wear" , "Agility"
										game.Players.LocalPlayer.Character.Humanoid:EquipTool(v)
									end
								end
							end
							game:GetService("VirtualInputManager"):SendKeyEvent(true,122,false,game.Players.LocalPlayer.Character.HumanoidRootPart)
							game:GetService("VirtualInputManager"):SendKeyEvent(false,122,false,game.Players.LocalPlayer.Character.HumanoidRootPart)
							wait(.2)
							game:GetService("VirtualInputManager"):SendKeyEvent(true,120,false,game.Players.LocalPlayer.Character.HumanoidRootPart)
							game:GetService("VirtualInputManager"):SendKeyEvent(false,120,false,game.Players.LocalPlayer.Character.HumanoidRootPart)
							wait(.2)
							game:GetService("VirtualInputManager"):SendKeyEvent(true,99,false,game.Players.LocalPlayer.Character.HumanoidRootPart)
							game:GetService("VirtualInputManager"):SendKeyEvent(false,99,false,game.Players.LocalPlayer.Character.HumanoidRootPart)
						end
					end
				elseif game:GetService("Players").LocalPlayer.Data.Race.Value == "Cyborg" then
					Tween(CFrame.new(28654, 14898.7832, -30, 1, 0, 0, 0, 1, 0, 0, 0, 1))
				elseif game:GetService("Players").LocalPlayer.Data.Race.Value == "Ghoul" then
					for i,v in pairs(game.Workspace.Enemies:GetDescendants()) do
						if v:FindFirstChild("Humanoid") and v:FindFirstChild("HumanoidRootPart") and v.Humanoid.Health > 0 then
							pcall(function()
								repeat wait(.1)
									v.Humanoid.Health = 0
									v.HumanoidRootPart.CanCollide = false
									sethiddenproperty(game.Players.LocalPlayer, "SimulationRadius", math.huge)
								until not _G.AutoQuestRace or not v.Parent or v.Humanoid.Health <= 0
							end)
						end
					end
				elseif game:GetService("Players").LocalPlayer.Data.Race.Value == "Mink" then
					for i,v in pairs(game:GetService("Workspace"):GetDescendants()) do
						if v.Name == "StartPoint" then
							Tween(v.CFrame* CFrame.new(0,10,0))
					  	end
				   	end
				end
			end
        end
    end)
end)




Tabs.Race:AddParagraph({
    Title = "Misc Race",
    Content = "Auto Farm Acient Quest"
})



local ToggleAutoAcientQuest = Tabs.Race:AddToggle("ToggleAutoAcientQuest", {Title = "Auto Acient Quest", Default = false })
ToggleAutoAcientQuest:OnChanged(function(Value)
    AutoFarmAcient = Value
end)
Options.ToggleAutoAcientQuest:SetValue(false)


local AcientCframe = CFrame.new(216.211181640625, 126.9352035522461, -12599.0732421875)


spawn(function()
    while wait() do 
        if AutoFarmAcient then
            pcall(function()
                if game:GetService("Workspace").Enemies:FindFirstChild("Cocoa Warrior") or game:GetService("Workspace").Enemies:FindFirstChild("Chocolate Bar Battler") or game:GetService("Workspace").Enemies:FindFirstChild("Sweet Thief") or game:GetService("Workspace").Enemies:FindFirstChild("Candy Rebel") then
                    for i,v in pairs(game:GetService("Workspace").Enemies:GetChildren()) do
                        if v.Name == "Cocoa Warrior" or v.Name == "Chocolate Bar Battler" or v.Name == "Sweet Thief" or v.Name == "Candy Rebel" then
                           if v:FindFirstChild("Humanoid") and v:FindFirstChild("HumanoidRootPart") and v.Humanoid.Health > 0 then
                               repeat task.wait()
                                    AutoHaki()
                                    EquipTool(SelectWeapon)
                                    BringAcient = true
                                    v.HumanoidRootPart.CanCollide = false
                                    v.Humanoid.WalkSpeed = 0
                                    v.Head.CanCollide = false 
                                    FarmPos = v.HumanoidRootPart.CFrame
                                    Tween(v.HumanoidRootPart.CFrame * Pos)
                                    Click()
                                until not AutoFarmAcient or not v.Parent or v.Humanoid.Health <= 0
                                BringAcient = false
                            end
                        end
                    end
                else
        
                    if BypassTP then
                        BTP(AcientCframe)
                    else
                        Tween(AcientCframe)
                    end

                    for i,v in pairs(game:GetService("ReplicatedStorage"):GetChildren()) do 
                        if v.Name == "Cocoa Warrior" then
                            Tween(v.HumanoidRootPart.CFrame * CFrame.new(2,20,2))
                        elseif v.Name == "Chocolate Bar Battler" then
                            Tween(v.HumanoidRootPart.CFrame * CFrame.new(2,20,2))
                        elseif v.Name == "Sweet Thief" then
                            Tween(v.HumanoidRootPart.CFrame * CFrame.new(2,20,2))
                        elseif v.Name == "Candy Rebel" then
                            Tween(v.HumanoidRootPart.CFrame * CFrame.new(2,20,2))
                        end
                    end
                end
            end)
        end
    end
end)
spawn(function()
    pcall(function()
        while wait() do
            if AutoFarmAcient then
                if game.Players.LocalPlayer.Character.RaceTransformed.Value == false then
                    AutoFarmAcient = true
                end
            end
        end
    end)
end)
spawn(function()
while wait() do
    pcall(function()
        if AutoFarmAcient then
            game:GetService("VirtualInputManager"):SendKeyEvent(true,"Y",false,game)
            wait(0.1)
            game:GetService("VirtualInputManager"):SendKeyEvent(false,"Y",false,game)
        end
    end)
end
end)

--------------------------------------------------------------------------------------------------------------------------------------------
--shop

local ToggleRandomBone = Tabs.Shop:AddToggle("ToggleRandomBone", {Title = "Random Bone", Default = false })
ToggleRandomBone:OnChanged(function(Value)  
		_G.AutoRandomBone = Value
end)
Options.ToggleRandomBone:SetValue(false)
	
spawn(function()
	while wait(0.0000000000000000000000000000000000000000000000000001) do
	if _G.AutoRandomBone then
	local args = {
	 [1] = "Bones",
	 [2] = "Buy",
	 [3] = 1,
	 [4] = 1
	}
	game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer(unpack(args))
	end
	end
	end)


Tabs.Shop:AddButton({
	Title = "Geppo",
	Description = "",
	Callback = function()
		game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("BuyHaki","Geppo")
	end
})



Tabs.Shop:AddButton({
	Title = "Buso Haki",
	Description = "",
	Callback = function()
		game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("BuyHaki","Buso")
	end
})




Tabs.Shop:AddButton({
	Title = "Soru",
	Description = "",
	Callback = function()
		game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("BuyHaki","Soru")
	end
})


Tabs.Shop:AddButton({
	Title = "Ken Haki",
	Description = "",
	Callback = function()
        game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("KenTalk","Buy")
	end
})


Tabs.Shop:AddParagraph({
	Title = "Fighting Style",
	Content = ""
})



Tabs.Shop:AddButton({
	Title = "Black Leg",
	Description = "",
	Callback = function()
		game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("BuyBlackLeg")
	end
})

Tabs.Shop:AddButton({
	Title = "Electro",
	Description = "",
	Callback = function()
		game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("BuyElectro")
	end
})
Tabs.Shop:AddButton({
	Title = "Fishman Karate",
	Description = "",
	Callback = function()
        game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("BuyFishmanKarate")
	end
})
Tabs.Shop:AddButton({
	Title = "Dragon Claw",
	Description = "",
	Callback = function()
		game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("BlackbeardReward","DragonClaw","1")
        game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("BlackbeardReward","DragonClaw","2")
	end
})
Tabs.Shop:AddButton({
	Title = "Superhuman",
	Description = "",
	Callback = function()
		game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("BuySuperhuman")
	end
})
Tabs.Shop:AddButton({
	Title = "Death Step",
	Description = "",
	Callback = function()
		game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("BuyDeathStep")
	end
})
Tabs.Shop:AddButton({
	Title = "Sharkman Karate",
	Description = "",
	Callback = function()
        game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("BuySharkmanKarate",true)
        game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("BuySharkmanKarate")
	end
})
Tabs.Shop:AddButton({
	Title = "Electric Claw",
	Description = "",
	Callback = function()
		game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("BuyElectricClaw")
	end
})
Tabs.Shop:AddButton({
	Title = "Dragon Talon",
	Description = "",
	Callback = function()
		game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("BuyDragonTalon")
	end
})
Tabs.Shop:AddButton({
	Title = "Godhuman",
	Description = "",
	Callback = function()
		game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("BuyGodhuman")
	end
})


Tabs.Shop:AddParagraph({
	Title = "Items",
	Content = ""
})

Tabs.Shop:AddButton({
	Title = "Refund Stats",
	Description = "",
	Callback = function()
		game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("BlackbeardReward","Refund","1")
		game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("BlackbeardReward","Refund","2")
	end
})
Tabs.Shop:AddButton({
	Title = "Reroll Race",
	Description = "",
	Callback = function()
		game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("BlackbeardReward","Reroll","1")
		game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("BlackbeardReward","Reroll","2")
	end
})
--------------------------------------------------------------------------------------------------------------------------------------------
--misc


      Tabs.Misc:AddButton({
        Title = "Redeem All Code",
        Description = "Redeem all code x2 Exp",
        Callback = function()
            UseCode()
        end
    })

    function UseCode(Text)
        game:GetService("ReplicatedStorage").Remotes.Redeem:InvokeServer(Text)
    end
    UseCode("Sub2Fer999")
    UseCode("Enyu_is_Pro")
    UseCode("Magicbus")
    UseCode("JCWK")
    UseCode("Starcodeheo")
    UseCode("Bluxxy")
    UseCode("THEGREATACE")
    UseCode("SUB2GAMERROBOT_EXP1")
    UseCode("StrawHatMaine")
    UseCode("Sub2OfficialNoobie")
    UseCode("SUB2NOOBMASTER123")
    UseCode("Sub2Daigrock")
    UseCode("Axiore")
    UseCode("TantaiGaming")
    UseCode("STRAWHATMAINE")



Tabs.Misc:AddButton({
	Title = "Rejoin Server",
	Description = "",
	Callback = function()
		game:GetService("TeleportService"):Teleport(game.PlaceId, game:GetService("Players").LocalPlayer)
	end
})



Tabs.Misc:AddButton({
	Title = "Hop Server",
	Description = "",
	Callback = function()
		Hop()
	end
})

function Hop()
	local PlaceID = game.PlaceId
	local AllIDs = {}
	local foundAnything = ""
	local actualHour = os.date("!*t").hour
	local Deleted = false
	function TPReturner()
		local Site;
		if foundAnything == "" then
			Site = game.HttpService:JSONDecode(game:HttpGet('https://games.roblox.com/v1/games/' .. PlaceID .. '/servers/Public?sortOrder=Asc&limit=100'))
		else
			Site = game.HttpService:JSONDecode(game:HttpGet('https://games.roblox.com/v1/games/' .. PlaceID .. '/servers/Public?sortOrder=Asc&limit=100&cursor=' .. foundAnything))
		end
		local ID = ""
		if Site.nextPageCursor and Site.nextPageCursor ~= "null" and Site.nextPageCursor ~= nil then
			foundAnything = Site.nextPageCursor
		end
		local num = 0;
		for i,v in pairs(Site.data) do
			local Possible = true
			ID = tostring(v.id)
			if tonumber(v.maxPlayers) > tonumber(v.playing) then
				for _,Existing in pairs(AllIDs) do
					if num ~= 0 then
						if ID == tostring(Existing) then
							Possible = false
						end
					else
						if tonumber(actualHour) ~= tonumber(Existing) then
							local delFile = pcall(function()
								AllIDs = {}
								table.insert(AllIDs, actualHour)
							end)
						end
					end
					num = num + 1
				end
				if Possible == true then
					table.insert(AllIDs, ID)
					wait()
					pcall(function()
						wait()
						game:GetService("TeleportService"):TeleportToPlaceInstance(PlaceID, ID, game.Players.LocalPlayer)
					end)
					wait(4)
				end
			end
		end
	end
	function Teleport() 
		while wait() do
			pcall(function()
				TPReturner()
				if foundAnything ~= "" then
					TPReturner()
				end
			end)
		end
	end
	Teleport()
end       

function UpdateIslandESP() 
	for i,v in pairs(game:GetService("Workspace")["_WorldOrigin"].Locations:GetChildren()) do
		pcall(function()
			if IslandESP then 
				if v.Name ~= "Sea" then
					if not v:FindFirstChild('NameEsp') then
						local bill = Instance.new('BillboardGui',v)
						bill.Name = 'NameEsp'
						bill.ExtentsOffset = Vector3.new(0, 1, 0)
						bill.Size = UDim2.new(1,200,1,30)
						bill.Adornee = v
						bill.AlwaysOnTop = true
						local name = Instance.new('TextLabel',bill)
						name.Font = "GothamBold"
						name.FontSize = "Size14"
						name.TextWrapped = true
						name.Size = UDim2.new(1,0,1,0)
						name.TextYAlignment = 'Top'
						name.BackgroundTransparency = 1
						name.TextStrokeTransparency = 0.5
						name.TextColor3 = Color3.fromRGB(7, 236, 240)
					else
						v['NameEsp'].TextLabel.Text = (v.Name ..'   \n'.. round((game:GetService('Players').LocalPlayer.Character.Head.Position - v.Position).Magnitude/3) ..' Distance')
					end
				end
			else
				if v:FindFirstChild('NameEsp') then
					v:FindFirstChild('NameEsp'):Destroy()
				end
			end
		end)
	end
end

function isnil(thing)
return (thing == nil)
end
local function round(n)
return math.floor(tonumber(n) + 0.5)
end
Number = math.random(1, 1000000)





Tabs.Misc:AddButton({
	Title = "Hop Server Low Player",
	Description = "",
	Callback = function()
		getgenv().AutoTeleport = true
        getgenv().DontTeleportTheSameNumber = true 
        getgenv().CopytoClipboard = false
        if not game:IsLoaded() then
            print("Game is loading waiting...")
        end
        local maxplayers = math.huge
        local serversmaxplayer;
        local goodserver;
        local gamelink = "https://games.roblox.com/v1/games/" .. game.PlaceId .. "/servers/Public?sortOrder=Asc&limit=100" 
        function serversearch()
            for _, v in pairs(game:GetService("HttpService"):JSONDecode(game:HttpGetAsync(gamelink)).data) do
                if type(v) == "table" and v.playing ~= nil and maxplayers > v.playing then
                    serversmaxplayer = v.maxPlayers
                    maxplayers = v.playing
                    goodserver = v.id
                end
            end       
        end
        function getservers()
            serversearch()
            for i,v in pairs(game:GetService("HttpService"):JSONDecode(game:HttpGetAsync(gamelink))) do
                if i == "nextPageCursor" then
                    if gamelink:find("&cursor=") then
                        local a = gamelink:find("&cursor=")
                        local b = gamelink:sub(a)
                        gamelink = gamelink:gsub(b, "")
                    end
                    gamelink = gamelink .. "&cursor=" ..v
                    getservers()
                end
            end
        end 
        getservers()
        if AutoTeleport then
            if DontTeleportTheSameNumber then 
                if #game:GetService("Players"):GetPlayers() - 4  == maxplayers then
                    return warn("It has same number of players (except you)")
                elseif goodserver == game.JobId then
                    return warn("Your current server is the most empty server atm") 
                end
            end
            game:GetService("TeleportService"):TeleportToPlaceInstance(game.PlaceId, goodserver)
        end
	end
})

Tabs.Misc:AddParagraph({
	Title = "Open Ui",
	Content = ""

})
Tabs.Misc:AddButton({
	Title = "Devil Shop",
	Description = "",
	Callback = function()
		game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("GetFruits")
        game:GetService("Players").LocalPlayer.PlayerGui.Main.FruitShop.Visible = true
	end
})



Tabs.Misc:AddButton({
	Title = "Color Haki",
	Description = "",
	Callback = function()
		game.Players.localPlayer.PlayerGui.Main.Colors.Visible = true
	end
})



Tabs.Misc:AddButton({
	Title = "Title Name",
	Description = "",
	Callback = function()
		local args = {
			[1] = "getTitles"
		}
		game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer(unpack(args))
		game.Players.localPlayer.PlayerGui.Main.Titles.Visible = true
	end
})

Tabs.Misc:AddButton({
	Title = "Kaitun Cap",
	Description = "",
	Callback = function()


local inventoryController = require(game:GetService("Players").LocalPlayer.PlayerGui.Main.UIController.Inventory)
local inventoryData = game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("getInventory")
local items = {}
local rarityLevels = {"Mythical", "Legendary", "Rare", "Uncommon", "Common"}
local rarityColors = {
    ["Common"] = Color3.fromRGB(179, 179, 179),
    ["Uncommon"] = Color3.fromRGB(92, 140, 211),
    ["Rare"] = Color3.fromRGB(140, 82, 255),
    ["Legendary"] = Color3.fromRGB(213, 43, 228),
    ["Mythical"] = Color3.fromRGB(238, 47, 50)
}
function getRarity(color)
    for k, v in pairs(rarityColors) do
        if v == color then
            return k
        end
    end
end

for k, v in pairs(inventoryData) do
    items[v.Name] = v
end

local totalItems = #getupvalue(inventoryController.UpdateRender, 4)
local rarityContainers = {}
local allItems = {}
local totalContainers = 0
while totalContainers < totalItems do
    local i = 0
    while i < 25000 and totalContainers < totalItems do
        game:GetService("Players").LocalPlayer.PlayerGui.Main.InventoryContainer.Right.Content.ScrollingFrame.CanvasPosition = Vector2.new(0, i)
        for _, container in pairs(game:GetService("Players").LocalPlayer.PlayerGui.Main.InventoryContainer.Right.Content.ScrollingFrame.Frame:GetChildren()) do
            if container:IsA("Frame") and not rarityContainers[container.ItemName.Text] and container.ItemName.Visible == true then
                local itemRarity = getRarity(container.Background.BackgroundColor3)
                if itemRarity then
                    print("Container Found")
                    if not allItems[itemRarity] then
                        allItems[itemRarity] = {}
                    end
                    table.insert(allItems[itemRarity], container:Clone())
                end
                totalContainers = totalContainers + 1
                rarityContainers[container.ItemName.Text] = true
            end
        end
        i = i + 20
    end
    wait()
end

function GetXY(vec)
    return vec * 100
end

local uiListLayout = Instance.new("UIListLayout")
uiListLayout.FillDirection = Enum.FillDirection.Vertical
uiListLayout.SortOrder = 2
uiListLayout.Padding = UDim.new(0, 20)

local leftFrame = Instance.new("Frame", game.Players.LocalPlayer.PlayerGui.BubbleChat)
leftFrame.BackgroundTransparency = 1
leftFrame.Size = UDim2.new(.5, 0, 1, 0)
uiListLayout.Parent = leftFrame

local rightFrame = Instance.new("Frame", game.Players.LocalPlayer.PlayerGui.BubbleChat)
rightFrame.BackgroundTransparency = 1
rightFrame.Size = UDim2.new(.5, 0, 1, 0)
rightFrame.Position = UDim2.new(.6, 0, 0, 0)
rightFrame.Name = "Right"
uiListLayout:Clone().Parent = rightFrame
local masteryLabel
for rarity, containers in pairs(allItems) do
    local rarityFrameLeft = Instance.new("Frame", leftFrame)
    rarityFrameLeft.BackgroundTransparency = 1
    rarityFrameLeft.Size = UDim2.new(1, 0, 0, 0)
    rarityFrameLeft.LayoutOrder = table.find(rarityLevels, rarity)

    local rarityFrameRight = Instance.new("Frame", rightFrame)
    rarityFrameRight.BackgroundTransparency = 1
    rarityFrameRight.Size = UDim2.new(1, 0, 0, 0)
    rarityFrameRight.LayoutOrder = table.find(rarityLevels, rarity)

    local gridLayoutLeft = Instance.new("UIGridLayout", rarityFrameLeft)
    gridLayoutLeft.CellPadding = UDim2.new(.005, 0, .005, 0)
    gridLayoutLeft.CellSize = UDim2.new(0, 70, 0, 70)
    gridLayoutLeft.FillDirectionMaxCells = 100
    gridLayoutLeft.FillDirection = Enum.FillDirection.Horizontal

    local gridLayoutRight = gridLayoutLeft:Clone()
    gridLayoutRight.Parent = rarityFrameRight
    for _, container in pairs(containers) do
        if items[container.ItemName.Text] and items[container.ItemName.Text].Mastery then
            if container.ItemLine2.Text ~= "Accessory" then
                masteryLabel = container.ItemName:Clone()
                masteryLabel.BackgroundTransparency = 1
                masteryLabel.TextSize = 10
                masteryLabel.TextXAlignment = 2
                masteryLabel.TextYAlignment = 2
                masteryLabel.ZIndex = 5
                masteryLabel.Text = items[container.ItemName.Text].Mastery
                masteryLabel.Size = UDim2.new(.5, 0, .5, 0)
                masteryLabel.Position = UDim2.new(.5, 0, .5, 0)
                masteryLabel.Parent = container
            end
            container.Parent = rarityFrameLeft
        elseif container.ItemLine2.Text == "Blox Fruit" then
            container.Parent = rarityFrameRight
        end
    end
    rarityFrameLeft.AutomaticSize = 2
    rarityFrameRight.AutomaticSize = 2
end

local meleeGearFrame = Instance.new("Frame", rightFrame)
meleeGearFrame.BackgroundTransparency = 1
meleeGearFrame.Size = UDim2.new(1, 0, 0, 0)
meleeGearFrame.LayoutOrder = table.find(rarityLevels, k)
meleeGearFrame.AutomaticSize = 2
meleeGearFrame.LayoutOrder = 100
local gridLayoutMelee = Instance.new("UIGridLayout", meleeGearFrame)
gridLayoutMelee.CellPadding = UDim2.new(.005, 0, .005, 0)
gridLayoutMelee.CellSize = UDim2.new(0, 70, 0, 70)
gridLayoutMelee.FillDirectionMaxCells = 100
gridLayoutMelee.FillDirection = Enum.FillDirection.Horizontal
local meleeItems = {
    ["Superhuman"] = Vector2.new(3, 2),
    ["DeathStep"] = Vector2.new(4, 3),
    ["ElectricClaw"] = Vector2.new(2, 0),
    ["SharkmanKarate"] = Vector2.new(0, 0),
    ["DragonTalon"] = Vector2.new(1, 5),
    ["Godhuman"] = "rbxassetid://10338473987"
}
local itemInstances = {}
for item, position in pairs(meleeItems) do
    if game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("Buy" .. item, true) == 1 then
        local itemImage = Instance.new("ImageLabel", meleeGearFrame)
        if type(position) == "string" then
            itemImage.Image = position
        else
            itemImage.Image = "rbxassetid://9945562382"
            itemImage.ImageRectSize = Vector2.new(100, 100)
            itemImage.ImageRectOffset = position * 100
        end
        itemInstances[item] = itemImage
    end
end
local currentItemIndex = 1
function FindNextItem()
    for item, instance in pairs(itemInstances) do
        if not instance:FindFirstChild("Level") then
            game:GetService("ReplicatedStorage").Remotes.CommF_:InvokeServer("Buy" .. item)
            wait(.1)
            local itemInstance = FindItemInBackpack(item)
            if itemInstance then
                itemInstance:WaitForChild("Level")
                local levelLabel = masteryLabel:Clone()
                levelLabel.Name = "Level"
                levelLabel.BackgroundTransparency = 1
                levelLabel.TextSize = 10
                levelLabel.TextXAlignment = 2
                levelLabel.TextYAlignment = 2
                levelLabel.ZIndex = 5
                levelLabel.Text = itemInstance.Level.Value
                levelLabel.Size = UDim2.new(.5, 0, .5, 0)
                levelLabel.Position = UDim2.new(.5, 0, .5, 0)
                levelLabel.Parent = instance
                currentItemIndex = currentItemIndex + 1
            end
        end
    end
end
spawn(function()
    local itemCount = #itemInstances
    local completedCount = 0
    while completedCount < itemCount do
        FindNextItem()
        wait()
    end
end)
game:GetService("Players").LocalPlayer.PlayerGui.Main.AwakeningToggler.Visible = true
repeat
    wait()
until game:GetService("Players").LocalPlayer.PlayerGui.Main.AwakeningToggler.TopContainer.Frame:FindFirstChild("Z")
local awakeningFrame = game:GetService("Players").LocalPlayer.PlayerGui.Main.AwakeningToggler:Clone()
awakeningFrame.LayoutOrder = 101
game:GetService("Players").LocalPlayer.PlayerGui.Main.AwakeningToggler.Visible = false
awakeningFrame.Parent = rightFrame
awakeningFrame.Size = UDim2.new(1, 0, 0.3, 0)
function formatNumber(number)
    return tostring(number):reverse():gsub("%d%d%d", "%1,"):reverse():gsub("^,", "")
end
local fragmentLabel = game:GetService("Players").LocalPlayer.PlayerGui.Main.Fragments:Clone()
fragmentLabel.Parent = game:GetService("Players").LocalPlayer.PlayerGui.BubbleChat
fragmentLabel.Position = UDim2.new(0, 6, 0.85799, 0)
local fragmentsCount = formatNumber(game.Players.LocalPlayer.Data.Fragments.Value)
fragmentLabel.Text = "ƒ" .. fragmentsCount
print("Done")
pcall(function()
    game:GetService("Players").LocalPlayer.PlayerGui.Main.MenuButton.Visible = false
end)
pcall(function()
    game:GetService("Players").LocalPlayer.PlayerGui.Main.HP.Visible = false
end)
pcall(function()
    game:GetService("Players").LocalPlayer.PlayerGui.Main.Energy.Visible = false
end)
pcall(function()
    game:GetService("Players").LocalPlayer.PlayerGui.Main.Compass:Destroy()
end)


	end
})


local ach = loadstring(game:HttpGet("https://raw.githubusercontent.com/SixZensED/Scripts/main/Luxury%20V2/Include/ach.lua"))().create()
print("Oxygen Hub BLOX FRUIT SCRIPT")


--* Example Code to show user data *-- 
--print(' Logged In!')
--print(' User Data')
--print(' Username:' .. data.info.username)
--print(' IP Address:' .. data.info.ip)
--print(' Created at:' .. data.info.createdate)
--print(' Last login at:' .. data.info.lastlogin)
