-- Operações de edição da estrutura: dividir, juntar, redimensionar, renomear
-- e criar música, sobre regiões e marcadores nativos do REAPER.
--
-- Toda posição recebida é ajustada ao compasso mais próximo. Nenhuma operação
-- cria sobreposição nem seção com menos de um compasso, e cada uma é um único
-- passo de undo. Retornam ok, err. Os argumentos vêm do project_model; depois
-- de uma operação, chame project_model.refresh para reler o projeto.

local M = {}

local PROJ = 0
local EPS = 1e-6
local SONG_PREFIX = "SONG: "
local DEFAULT_SECTION = "Seção"

-- ------------------------------------------------------------------ compassos

local function measure_of(pos)
  local beat, measure, cml = reaper.TimeMap2_timeToBeats(PROJ, pos)
  if beat >= cml / 2 - EPS then measure = measure + 1 end
  return measure
end

local function measure_start(measure) return reaper.TimeMap2_beatsToTime(PROJ, 0, measure) end

-- Posição do compasso mais próximo.
function M.snap(pos) return measure_start(measure_of(pos)) end

-- Posição `n` compassos depois (ou antes, n < 0) de um início de compasso.
local function bars_from(pos, n) return measure_start(measure_of(pos) + n) end

-- ------------------------------------------------------------------ nomes

local function base_name(name) return (name:gsub("%s+%d+$", "")) end

-- `base`, ou "base 2", "base 3"… se o nome já existir na música.
function M.unique_name(song, base, except)
  local used = {}
  for _, s in ipairs(song.sections) do
    if s ~= except and (not except or s.region_idx ~= except.region_idx) then used[s.name] = true end
  end
  if not used[base] then return base end
  local k = 2
  while used[base .. " " .. k] do k = k + 1 end
  return base .. " " .. k
end

-- ------------------------------------------------------------------ apoio

local function undoable(desc, fn)
  reaper.Undo_BeginBlock()
  fn()
  reaper.Undo_EndBlock("Live Sections: " .. desc, -1)
end

local function set_region(sec, start_pos, end_pos, name)
  reaper.SetProjectMarker3(PROJ, sec.region_idx, true, start_pos, end_pos, name or sec.name, sec.color)
end

local function neighbors(song, section)
  for i, s in ipairs(song.sections) do
    if s.region_idx == section.region_idx then return song.sections[i - 1], song.sections[i + 1] end
  end
end

local function adjacent(a_end, b_start) return math.abs(a_end - b_start) < EPS end

-- ------------------------------------------------------------------ operações

-- Divide a seção que contém `pos` no compasso mais próximo. A segunda parte
-- herda a cor e ganha o mesmo nome numerado.
function M.split(song, pos)
  local at = M.snap(pos)
  for _, sec in ipairs(song.sections) do
    if at > sec.start_pos + EPS and at < sec.end_pos - EPS then
      local name = M.unique_name(song, base_name(sec.name))
      undoable("dividir seção", function()
        set_region(sec, sec.start_pos, at)
        reaper.AddProjectMarker2(PROJ, true, at, sec.end_pos, name, -1, sec.color)
      end)
      return true
    end
    if math.abs(at - sec.start_pos) < EPS or math.abs(at - sec.end_pos) < EPS then
      return false, "boundary"
    end
  end
  return false, "no_section"
end

-- Junta a seção com a próxima. Um trecho sem seção entre as duas passa a ser
-- da primeira.
function M.merge_next(song, section)
  local _, nxt = neighbors(song, section)
  if not nxt then return false, "no_next" end
  undoable("juntar seções", function()
    set_region(section, section.start_pos, nxt.end_pos)
    reaper.DeleteProjectMarker(PROJ, nxt.region_idx, true)
  end)
  return true
end

-- Move a borda `edge` ("start" ou "end") da seção para `pos`. Se a seção
-- vizinha encosta nessa borda, ela se move junto. A posição é limitada para
-- nenhuma das duas ficar com menos de um compasso nem invadir outra seção.
function M.resize(song, section, edge, pos)
  local prev, nxt = neighbors(song, section)
  local at = M.snap(pos)
  local min, max, linked
  if edge == "end" then
    linked = nxt and adjacent(section.end_pos, nxt.start_pos)
    min = bars_from(section.start_pos, 1)
    max = nxt and (linked and bars_from(nxt.end_pos, -1) or nxt.start_pos) or song.end_pos
  elseif edge == "start" then
    linked = prev and adjacent(prev.end_pos, section.start_pos)
    max = bars_from(section.end_pos, -1)
    min = prev and (linked and bars_from(prev.start_pos, 1) or prev.end_pos) or song.start_pos
  else
    error("editor_ops.resize: borda desconhecida: " .. tostring(edge), 2)
  end
  if max < min - EPS then return false, "no_room" end
  at = math.max(min, math.min(max, at))
  local current = edge == "end" and section.end_pos or section.start_pos
  if math.abs(at - current) < EPS then return true end

  undoable("redimensionar seção", function()
    if edge == "end" then
      set_region(section, section.start_pos, at)
      if linked then set_region(nxt, at, nxt.end_pos) end
    else
      set_region(section, at, section.end_pos)
      if linked then set_region(prev, prev.start_pos, at) end
    end
  end)
  return true
end

-- Muda a duração da seção para `bars` compassos, movendo a borda final.
function M.set_length(song, section, bars)
  bars = math.floor(bars + 0.5)
  if bars < 1 then return false, "too_short" end
  return M.resize(song, section, "end", bars_from(section.start_pos, bars))
end

-- Renomeia a seção. Nome repetido na música ganha numeração ("Verso 2").
-- Retorna ok e o nome final.
function M.rename(song, section, name, color)
  name = name:gsub("^%s+", ""):gsub("%s+$", "")
  if name == "" then return false, "empty" end
  local final = M.unique_name(song, name, section)
  undoable("renomear seção", function()
    reaper.SetProjectMarker3(PROJ, section.region_idx, true, section.start_pos, section.end_pos, final, color or section.color)
  end)
  return true, final
end

local function project_end()
  local last = reaper.GetProjectLength(PROJ)
  local i = 0
  while true do
    local ret, isrgn, pos, rgnend = reaper.EnumProjectMarkers3(PROJ, i)
    if ret == 0 then return last end
    last = math.max(last, isrgn and rgnend or pos)
    i = i + 1
  end
end

-- Cria o marcador "SONG: <nome>" no compasso mais próximo de `pos` e uma seção
-- inicial que vai até a próxima seção, a próxima música ou o fim do projeto.
-- `songs` é a lista do project_model.
function M.create_song(songs, pos, name)
  local at = M.snap(pos)
  local limit = project_end()
  for _, song in ipairs(songs) do
    if song.marker_idx and math.abs(song.start_pos - at) < EPS then return false, "song_exists" end
    for _, sec in ipairs(song.sections) do
      if at > sec.start_pos + EPS and at < sec.end_pos - EPS then return false, "inside_section" end
      if sec.start_pos > at + EPS and sec.start_pos < limit then limit = sec.start_pos end
    end
    if song.marker_idx and song.start_pos > at + EPS and song.start_pos < limit then limit = song.start_pos end
  end
  local starts_at_section = false
  for _, song in ipairs(songs) do
    for _, sec in ipairs(song.sections) do
      if math.abs(sec.start_pos - at) < EPS then starts_at_section = true end
    end
  end
  undoable("criar música", function()
    reaper.AddProjectMarker2(PROJ, false, at, 0, SONG_PREFIX .. name, -1, 0)
    if not starts_at_section and limit > at + EPS then
      reaper.AddProjectMarker2(PROJ, true, at, limit, DEFAULT_SECTION, -1, 0)
    end
  end)
  return true
end

return M
