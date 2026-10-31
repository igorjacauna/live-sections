-- Cifras: o texto de cada música (estilo Cifra Club) separado por seção e
-- acompanhado pelo compasso.
--
-- Texto: cabeçalhos [Nome] abrem um bloco; o nome casa com a seção de mesmo
-- nome ("Refrão 2" usa o segundo [Refrão], ou o primeiro se só houver um).
-- O que vem antes do primeiro cabeçalho (tom, capotraste…) é a introdução.
--
-- Cada bloco vira uma lista de versos: uma linha de acordes com a letra logo
-- abaixo forma um verso; uma linha só de acordes ou só de letra também é um
-- verso. Uma linha em grade, "| G | D | Em C |", é um verso que dura
-- exatamente um compasso por célula; os compassos que sobram na seção se
-- dividem igualmente entre os outros versos. Assim a linha atual sai do
-- compasso em que a música está.
--
-- O texto fica no projeto: ProjExtState("LiveSections", "chart:<GUID do
-- marcador SONG:>"), com quebras de linha escapadas.
--
-- M.parse(text) -> { intro = { linhas }, blocks = { { name, units } } }
-- M.get_text(song) -> texto; M.set_text(song, text)
-- M.for_song(song) -> parse do texto da música (em cache)
-- M.units_for(parsed, section) -> versos da seção, ou nil
-- M.view(units, bar, bars, max_lines, next_name, next_units) -> rows
--   rows: { kind = "chords"|"lyrics"|"grid"|"next", text, current?, cells?, cell? }

local M = {}

local PROJ = 0
local EXT_SECTION = "LiveSections"
local KEY_PREFIX = "chart:"

-- ------------------------------------------------------------------ texto

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

-- Nome para comparar: minúsculo, sem acento e sem espaços repetidos.
local ACCENTS = {
  ["á"] = "a", ["à"] = "a", ["â"] = "a", ["ã"] = "a", ["é"] = "e", ["ê"] = "e", ["í"] = "i",
  ["ó"] = "o", ["ô"] = "o", ["õ"] = "o", ["ú"] = "u", ["ç"] = "c",
  ["Á"] = "a", ["À"] = "a", ["Â"] = "a", ["Ã"] = "a", ["É"] = "e", ["Ê"] = "e", ["Í"] = "i",
  ["Ó"] = "o", ["Ô"] = "o", ["Õ"] = "o", ["Ú"] = "u", ["Ç"] = "c",
}
local function norm(s)
  s = s:gsub("[\xC3][\x80-\xBF]", function(c) return ACCENTS[c] or c end)
  return trim(s:lower():gsub("%s+", " "))
end

local function base_name(s) return (s:gsub("%s+%d+$", "")) end

-- Acorde: G, Am, F#m7, Bb7M, C7(9), D/F#, Gº, E7(b9)/G#, Asus4, Cmaj7…
local SUFFIXES = { "maj", "min", "dim", "aug", "sus", "add", "m", "M", "º", "°", "+", "-", "#", "b", "(", ")", ",", "/" }

local function is_chord(tok)
  local rest = tok:match("^[A-G][#b]?(.*)$")
  if not rest then return false end
  local bass = rest:match("/([A-G][#b]?)$")
  if bass then rest = rest:sub(1, #rest - #bass - 1) end
  while rest ~= "" do
    local d = rest:match("^%d+")
    if d then
      rest = rest:sub(#d + 1)
    else
      local hit = false
      for _, sfx in ipairs(SUFFIXES) do
        if rest:sub(1, #sfx) == sfx then rest = rest:sub(#sfx + 1); hit = true; break end
      end
      if not hit then return false end
    end
  end
  return true
end

local function is_filler(tok)
  return tok == "|" or tok == "||" or tok == "-" or tok == "%" or tok:match("^%(?x%d+%)?$") or tok:match("^%(%)$")
end

-- "chords", "grid", "lyrics" ou "blank"
local function line_kind(line)
  if trim(line) == "" then return "blank" end
  local chords, other = 0, 0
  for tok in line:gmatch("[^%s|]+") do
    if is_chord(tok) then chords = chords + 1 elseif not is_filler(tok) then other = other + 1 end
  end
  if chords > 0 and other == 0 then
    return line:find("|", 1, true) and "grid" or "chords"
  end
  return "lyrics"
end

-- Células de uma linha em grade: o texto entre as barras.
local function grid_cells(line)
  local cells = {}
  local inner = trim(line):gsub("^|+", ""):gsub("|+$", "")
  for cell in (inner .. "|"):gmatch("([^|]*)|") do
    local c = trim(cell)
    if c ~= "" then cells[#cells + 1] = c end
  end
  return cells
end

local function units_of(lines)
  local units, i = {}, 1
  while i <= #lines do
    local l = lines[i]
    local kind = line_kind(l)
    if kind == "grid" then
      local cells = grid_cells(l)
      units[#units + 1] = { kind = "grid", lines = { l }, cells = cells, bars = #cells }
    elseif kind == "chords" and lines[i + 1] and line_kind(lines[i + 1]) == "lyrics" then
      units[#units + 1] = { kind = "pair", lines = { l, lines[i + 1] } }
      i = i + 1
    elseif kind ~= "blank" then
      units[#units + 1] = { kind = kind, lines = { l } }
    end
    i = i + 1
  end
  return units
end

function M.parse(text)
  local out = { intro = {}, blocks = {} }
  local current, lines = nil, {}
  local function close()
    if current then current.units = units_of(lines) end
  end
  for raw in ((text or "") .. "\n"):gmatch("([^\n]*)\n") do
    local line = raw:gsub("\r$", ""):gsub("\t", "    ")
    local header = line:match("^%s*%[([^%]]+)%]%s*$")
    if header and line_kind(line) ~= "grid" then
      close()
      current, lines = { name = trim(header) }, {}
      out.blocks[#out.blocks + 1] = current
    elseif current then
      lines[#lines + 1] = line
    elseif trim(line) ~= "" then
      out.intro[#out.intro + 1] = line
    end
  end
  close()
  return out
end

-- ------------------------------------------------------------------ casamento

-- Versos da seção: nome igual; senão a N-ésima ocorrência do nome base
-- ("Refrão 2" → 2º [Refrão]), ou a primeira se não houver tantas.
function M.units_for(parsed, section)
  if not parsed or not section then return nil end
  local want = norm(section.name)
  for _, b in ipairs(parsed.blocks) do
    if norm(b.name) == want then return b.units end
  end
  local base = norm(base_name(section.name))
  local n = tonumber(section.name:match("%s(%d+)$")) or 1
  local found = {}
  for _, b in ipairs(parsed.blocks) do
    if norm(base_name(b.name)) == base then found[#found + 1] = b end
  end
  local b = found[n] or found[1]
  return b and b.units or nil
end

-- ------------------------------------------------------------------ tempo

-- Compasso de início de cada verso e a duração dele, em compassos.
local function timeline(units, bars)
  local fixed, flex = 0, 0
  for _, u in ipairs(units) do
    if u.bars then fixed = fixed + u.bars else flex = flex + 1 end
  end
  local each = flex > 0 and math.max(bars - fixed, 0) / flex or 0
  local starts, at = {}, 0
  for i, u in ipairs(units) do
    starts[i] = at
    at = at + (u.bars or each)
  end
  return starts
end

-- Linhas para exibir: a partir do verso atual, até `max_lines` linhas de
-- texto (um verso nunca é cortado). Se sobrar espaço no fim da seção, entra
-- "A seguir" com o começo da próxima. `bar` é o compasso dentro da seção
-- (0 = primeiro, fracionário).
function M.view(units, bar, bars, max_lines, next_name, next_units)
  local rows, used = {}, 0
  units = units or {}
  max_lines = math.max(max_lines or 6, 2)
  local starts = timeline(units, bars or 0)
  local cur = 1
  for i = 1, #units do if (bar or 0) >= starts[i] - 1e-6 then cur = i end end

  local function add_unit(u, current, start)
    if used + #u.lines > max_lines and used > 0 then return false end
    for _, l in ipairs(u.lines) do
      local kind = u.kind == "grid" and "grid" or line_kind(l) == "chords" and "chords" or "lyrics"
      local row = { kind = kind, text = l, current = current or nil }
      if u.kind == "grid" then
        row.cells = u.cells
        if current then row.cell = math.min(#u.cells, math.floor((bar or 0) - start) + 1) end
      end
      rows[#rows + 1] = row
      used = used + 1
    end
    return true
  end

  for i = cur, #units do
    if not add_unit(units[i], i == cur, starts[i]) then return rows end
  end
  if next_name and used < max_lines then
    rows[#rows + 1] = { kind = "next", text = next_name }
    used = used + 1
    for _, u in ipairs(next_units or {}) do
      if not add_unit(u, false, 0) then break end
    end
  end
  return rows
end

-- ------------------------------------------------------------------ projeto

local function marker_guid(song)
  if not song.marker_idx then return "projeto" end
  local i = 0
  while true do
    local ret, isrgn, _, _, _, idx = reaper.EnumProjectMarkers3(PROJ, i)
    if ret == 0 then return nil end
    if not isrgn and idx == song.marker_idx then
      local _, guid = reaper.GetSetProjectInfo_String(PROJ, "MARKER_GUID:" .. i, "", false)
      return guid
    end
    i = i + 1
  end
end

local function escape(s) return (s:gsub("\\", "\\\\"):gsub("\r?\n", "\\n")) end
local function unescape(s)
  return (s:gsub("\\(.)", function(c) return c == "n" and "\n" or c end))
end

function M.get_text(song)
  local guid = song and marker_guid(song)
  if not guid then return "" end
  local ok, v = reaper.GetProjExtState(PROJ, EXT_SECTION, KEY_PREFIX .. guid)
  if ok == 0 or not v then return "" end
  return unescape(v)
end

local cache = {}   -- [texto] = parse

function M.set_text(song, text)
  local guid = marker_guid(song)
  if not guid then return false, "no_song" end
  reaper.SetProjExtState(PROJ, EXT_SECTION, KEY_PREFIX .. guid, escape(text or ""))
  return true
end

function M.for_song(song)
  local text = M.get_text(song)
  if text == "" then return nil end
  if not cache[text] then cache = { [text] = M.parse(text) } end
  return cache[text]
end

return M
