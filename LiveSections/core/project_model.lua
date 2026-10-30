-- Modelo de músicas e seções lido do projeto.
--
-- Uma música começa num marcador "SONG: <nome>" e vai até o próximo marcador
-- SONG: ou até o fim do projeto. Sem nenhum marcador SONG:, o projeto inteiro
-- é uma música. Cada região que começa dentro da música é uma seção; os
-- trechos da música sem região ficam em `gaps` e não ocupam slot.
--
-- O projeto é a fonte da verdade: o modelo só guarda uma cópia, relida quando
-- GetProjectStateChangeCount muda.

local M = {}

local SONG_PREFIX = "SONG:"
local DEFAULT_SONG_NAME = "Projeto"
local EPS = 1e-6

local cache = { proj = nil, state_count = nil, songs = {} }

local function song_name(marker_name)
  if marker_name:sub(1, #SONG_PREFIX) ~= SONG_PREFIX then return nil end
  return (marker_name:sub(#SONG_PREFIX + 1):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Lê marcadores SONG: e regiões, já ordenados por posição.
local function read_markers(proj)
  local song_markers, regions = {}, {}
  local last_end = 0
  local i = 0
  while true do
    local ret, isrgn, pos, rgnend, name, idx, color = reaper.EnumProjectMarkers3(proj, i)
    if ret == 0 then break end
    if isrgn then
      regions[#regions + 1] = { pos = pos, rgnend = rgnend, name = name, idx = idx, color = color }
      if rgnend > last_end then last_end = rgnend end
    else
      local name_ = song_name(name)
      if name_ then song_markers[#song_markers + 1] = { pos = pos, name = name_, idx = idx } end
      if pos > last_end then last_end = pos end
    end
    i = i + 1
  end
  table.sort(regions, function(a, b)
    if a.pos ~= b.pos then return a.pos < b.pos end
    return a.idx < b.idx
  end)
  return song_markers, regions, last_end
end

local function compute_gaps(song)
  local gaps, cursor = {}, song.start_pos
  for _, sec in ipairs(song.sections) do
    if sec.start_pos > cursor + EPS then gaps[#gaps + 1] = { start_pos = cursor, end_pos = sec.start_pos } end
    if sec.end_pos > cursor then cursor = sec.end_pos end
  end
  if song.end_pos > cursor + EPS then gaps[#gaps + 1] = { start_pos = cursor, end_pos = song.end_pos } end
  return gaps
end

local function build(proj)
  local song_markers, regions, last_end = read_markers(proj)
  local project_end = math.max(reaper.GetProjectLength(proj), last_end)

  local songs = {}
  if #song_markers == 0 then
    songs[1] = { id = 0, name = DEFAULT_SONG_NAME, start_pos = 0, end_pos = project_end, marker_idx = nil }
  else
    for n, m in ipairs(song_markers) do
      local nxt = song_markers[n + 1]
      songs[n] = { id = m.idx, name = m.name, start_pos = m.pos, end_pos = nxt and nxt.pos or project_end, marker_idx = m.idx }
    end
  end

  for _, song in ipairs(songs) do
    song.sections, song.layers = {}, {}
    for _, rgn in ipairs(regions) do
      if rgn.pos >= song.start_pos - EPS and rgn.pos < song.end_pos - EPS then
        song.sections[#song.sections + 1] = {
          name = rgn.name, color = rgn.color, start_pos = rgn.pos, end_pos = rgn.rgnend,
          region_idx = rgn.idx, slot = #song.sections + 1,
        }
      end
    end
    song.gaps = compute_gaps(song)
  end
  return songs
end

-- Relê o projeto só quando ele mudou. Retorna true se o modelo foi refeito.
function M.refresh(proj)
  proj = proj or 0
  local count = reaper.GetProjectStateChangeCount(proj)
  if cache.proj == proj and cache.state_count == count then return false end
  cache.proj, cache.state_count = proj, count
  cache.songs = build(proj)
  return true
end

function M.songs() return cache.songs end

-- Música e seção na posição `pos` (segundos). A seção é nil num trecho sem seção.
function M.song_at(pos)
  for _, song in ipairs(cache.songs) do
    if pos >= song.start_pos - EPS and pos < song.end_pos - EPS then
      for _, sec in ipairs(song.sections) do
        if pos >= sec.start_pos - EPS and pos < sec.end_pos - EPS then return song, sec end
      end
      return song, nil
    end
  end
  return nil, nil
end

return M
