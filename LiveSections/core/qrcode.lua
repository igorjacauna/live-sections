-- QR Code para o endereço da página do celular: modo byte, correção de erro
-- nível M (até ~15% do código danificado), versões 1 a 9 (até 180 bytes).
-- Segue a ISO/IEC 18004; conferido contra o segno e lido pelo OpenCV.
--
-- M.encode(text, mask?) -> matriz ([linha][coluna] = true se escuro), lado
--   ou nil, "too_long". `mask` (0–7) força a máscara; sem ela, escolhe a de
--   menor penalidade.

local M = {}

-- ------------------------------------------------------------------ GF(256)

local EXP, LOG = {}, {}
do
  local x = 1
  for i = 0, 254 do
    EXP[i], LOG[x] = x, i
    x = x << 1
    if x & 0x100 ~= 0 then x = x ~ 0x11D end
  end
  for i = 255, 511 do EXP[i] = EXP[i - 255] end
end

local function mul(a, b)
  if a == 0 or b == 0 then return 0 end
  return EXP[LOG[a] + LOG[b]]
end

-- Polinômio gerador de grau n: coeficientes do maior para o menor grau.
local function generator(n)
  local g = { 1 }
  for i = 0, n - 1 do
    local ng = {}
    for j = 1, #g + 1 do ng[j] = 0 end
    for j = 1, #g do
      ng[j] = ng[j] ~ g[j]
      ng[j + 1] = ng[j + 1] ~ mul(g[j], EXP[i])
    end
    g = ng
  end
  return g
end

local function ec_codewords(data, n)
  local g = generator(n)
  local res = {}
  for i = 1, n do res[i] = 0 end
  for _, d in ipairs(data) do
    local factor = d ~ res[1]
    table.remove(res, 1)
    res[n] = 0
    for i = 1, n do res[i] = res[i] ~ mul(g[i + 1], factor) end
  end
  return res
end

-- ------------------------------------------------------------------ tabelas (nível M)

-- [versão] = { codewords de correção por bloco, { blocos, dados por bloco }... }
local BLOCKS = {
  { 10, { 1, 16 } }, { 16, { 1, 28 } }, { 26, { 1, 44 } }, { 18, { 2, 32 } }, { 24, { 2, 43 } },
  { 16, { 4, 27 } }, { 18, { 4, 31 } }, { 22, { 2, 38 }, { 2, 39 } }, { 22, { 3, 36 }, { 2, 37 } },
}
local ALIGN = {
  {}, { 6, 18 }, { 6, 22 }, { 6, 26 }, { 6, 30 }, { 6, 34 }, { 6, 22, 38 }, { 6, 24, 42 }, { 6, 26, 46 },
}
local ECL_M = 0          -- bits do nível M no formato

local function data_capacity(v)
  local n = 0
  for i = 2, #BLOCKS[v] do n = n + BLOCKS[v][i][1] * BLOCKS[v][i][2] end
  return n
end

-- ------------------------------------------------------------------ dados

local function codewords(text, v)
  local bits = {}
  local function put(value, len)
    for i = len - 1, 0, -1 do bits[#bits + 1] = (value >> i) & 1 end
  end
  put(4, 4)                -- modo byte
  put(#text, 8)            -- contagem (versões 1–9)
  for i = 1, #text do put(text:byte(i), 8) end
  local cap = data_capacity(v) * 8
  put(0, math.min(4, cap - #bits))
  while #bits % 8 ~= 0 do bits[#bits + 1] = 0 end
  local out = {}
  for i = 1, #bits, 8 do
    local b = 0
    for k = 0, 7 do b = (b << 1) | bits[i + k] end
    out[#out + 1] = b
  end
  -- enchimento alterna 0xEC e 0x11 até a capacidade
  local k = 0
  while #out < cap // 8 do
    out[#out + 1] = (k % 2 == 0) and 0xEC or 0x11
    k = k + 1
  end
  return out
end

local function interleave(data, v)
  local spec = BLOCKS[v]
  local ec_len = spec[1]
  local blocks, pos = {}, 1
  for g = 2, #spec do
    for _ = 1, spec[g][1] do
      local b = {}
      for i = 1, spec[g][2] do b[i] = data[pos]; pos = pos + 1 end
      blocks[#blocks + 1] = { data = b, ec = ec_codewords(b, ec_len) }
    end
  end
  local out, longest = {}, 0
  for _, b in ipairs(blocks) do longest = math.max(longest, #b.data) end
  for i = 1, longest do
    for _, b in ipairs(blocks) do if b.data[i] then out[#out + 1] = b.data[i] end end
  end
  for i = 1, ec_len do
    for _, b in ipairs(blocks) do out[#out + 1] = b.ec[i] end
  end
  return out
end

-- ------------------------------------------------------------------ matriz

local function new_grid(size)
  local mod, fn = {}, {}
  for y = 0, size - 1 do
    mod[y], fn[y] = {}, {}
    for x = 0, size - 1 do mod[y][x], fn[y][x] = false, false end
  end
  return mod, fn
end

local function draw_function_patterns(mod, fn, size, v)
  local function set(x, y, dark) mod[y][x], fn[y][x] = dark, true end
  for i = 0, size - 1 do
    set(6, i, i % 2 == 0)
    set(i, 6, i % 2 == 0)
  end
  local function finder(cx, cy)
    for dy = -4, 4 do
      for dx = -4, 4 do
        local x, y = cx + dx, cy + dy
        if x >= 0 and x < size and y >= 0 and y < size then
          local d = math.max(math.abs(dx), math.abs(dy))
          set(x, y, d ~= 2 and d ~= 4)
        end
      end
    end
  end
  finder(3, 3)
  finder(size - 4, 3)
  finder(3, size - 4)
  local pos = ALIGN[v]
  local n = #pos
  for i = 1, n do
    for j = 1, n do
      if not (i == 1 and j == 1 or i == 1 and j == n or i == n and j == 1) then
        for dy = -2, 2 do
          for dx = -2, 2 do set(pos[i] + dx, pos[j] + dy, math.max(math.abs(dx), math.abs(dy)) ~= 1) end
        end
      end
    end
  end
  if v >= 7 then
    local rem = v
    for _ = 1, 12 do rem = (rem << 1) ~ ((rem >> 11) * 0x1F25) end
    local bits = (v << 12) | rem
    for i = 0, 17 do
      local dark = (bits >> i) & 1 == 1
      local a, b = size - 11 + i % 3, i // 3
      set(a, b, dark)
      set(b, a, dark)
    end
  end
end

local function draw_format(mod, fn, size, mask)
  local function set(x, y, dark) mod[y][x], fn[y][x] = dark, true end
  local data = (ECL_M << 3) | mask
  local rem = data
  for _ = 1, 10 do rem = (rem << 1) ~ ((rem >> 9) * 0x537) end
  local bits = ((data << 10) | rem) ~ 0x5412
  local function bit(i) return (bits >> i) & 1 == 1 end
  for i = 0, 5 do set(8, i, bit(i)) end
  set(8, 7, bit(6))
  set(8, 8, bit(7))
  set(7, 8, bit(8))
  for i = 9, 14 do set(14 - i, 8, bit(i)) end
  for i = 0, 7 do set(size - 1 - i, 8, bit(i)) end
  for i = 8, 14 do set(8, size - 15 + i, bit(i)) end
  set(8, size - 8, true)
end

local function draw_codewords(mod, fn, size, data)
  local total, i = #data * 8, 0
  local right = size - 1
  while right >= 1 do
    if right == 6 then right = 5 end
    for vert = 0, size - 1 do
      for j = 0, 1 do
        local x = right - j
        local upward = (right + 1) & 2 == 0
        local y = upward and (size - 1 - vert) or vert
        if not fn[y][x] and i < total then
          mod[y][x] = (data[(i >> 3) + 1] >> (7 - (i & 7))) & 1 == 1
          i = i + 1
        end
      end
    end
    right = right - 2
  end
end

local MASKS = {
  [0] = function(x, y) return (x + y) % 2 == 0 end,
  function(_, y) return y % 2 == 0 end,
  function(x, _) return x % 3 == 0 end,
  function(x, y) return (x + y) % 3 == 0 end,
  function(x, y) return (x // 3 + y // 2) % 2 == 0 end,
  function(x, y) return x * y % 2 + x * y % 3 == 0 end,
  function(x, y) return (x * y % 2 + x * y % 3) % 2 == 0 end,
  function(x, y) return ((x + y) % 2 + x * y % 3) % 2 == 0 end,
}

local function apply_mask(mod, fn, size, mask)
  local f = MASKS[mask]
  for y = 0, size - 1 do
    for x = 0, size - 1 do
      if not fn[y][x] and f(x, y) then mod[y][x] = not mod[y][x] end
    end
  end
end

local FINDER_A = { true, false, true, true, true, false, true, false, false, false, false }
local FINDER_B = { false, false, false, false, true, false, true, true, true, false, true }

local function penalty(mod, size)
  local score = 0
  local function line(get)
    local run, prev = 0, nil
    for i = 0, size - 1 do
      local c = get(i)
      if c == prev then run = run + 1 else
        if run >= 5 then score = score + 3 + run - 5 end
        run, prev = 1, c
      end
    end
    if run >= 5 then score = score + 3 + run - 5 end
    for i = 0, size - 11 do
      local a, b = true, true
      for k = 1, 11 do
        local c = get(i + k - 1)
        if c ~= FINDER_A[k] then a = false end
        if c ~= FINDER_B[k] then b = false end
      end
      if a then score = score + 40 end
      if b then score = score + 40 end
    end
  end
  for y = 0, size - 1 do line(function(i) return mod[y][i] end) end
  for x = 0, size - 1 do line(function(i) return mod[i][x] end) end
  local dark = 0
  for y = 0, size - 1 do
    for x = 0, size - 1 do
      local c = mod[y][x]
      if c then dark = dark + 1 end
      if x < size - 1 and y < size - 1 and c == mod[y][x + 1] and c == mod[y + 1][x] and c == mod[y + 1][x + 1] then
        score = score + 3
      end
    end
  end
  local total = size * size
  score = score + (math.ceil(math.abs(dark * 20 - total * 10) / total) - 1) * 10
  return score
end

-- ------------------------------------------------------------------ API

function M.encode(text, mask)
  local v
  for ver = 1, #BLOCKS do
    if 12 + 8 * #text <= data_capacity(ver) * 8 then v = ver; break end
  end
  if not v then return nil, "too_long" end
  local size = 17 + 4 * v
  local data = interleave(codewords(text, v), v)
  local mod, fn = new_grid(size)
  draw_function_patterns(mod, fn, size, v)
  draw_format(mod, fn, size, 0)          -- reserva a área do formato
  draw_codewords(mod, fn, size, data)

  if not mask then
    local best
    for m = 0, 7 do
      apply_mask(mod, fn, size, m)
      draw_format(mod, fn, size, m)
      local p = penalty(mod, size)
      if not best or p < best then best, mask = p, m end
      apply_mask(mod, fn, size, m)       -- desfaz (XOR)
    end
  end
  apply_mask(mod, fn, size, mask)
  draw_format(mod, fn, size, mask)

  local out = {}
  for y = 0, size - 1 do
    out[y + 1] = {}
    for x = 0, size - 1 do out[y + 1][x + 1] = mod[y][x] end
  end
  return out, size
end

return M
