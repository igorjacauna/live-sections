-- Parâmetros nas camadas: quais linhas do Mapeamento aparecem fixas em cada
-- camada da música, com o nome que têm nesta música.
--
-- O Mapeamento é global (controle → CC), mas o que cada knob faz muda de
-- música para música (o Learn de cada Kontakt é diferente). Por isso a lista
-- é por música, no ProjExtState("LiveSections", "params:<GUID do marcador
-- SONG:>"), em JSON, com a camada pelo GUID da track: reordenar as camadas
-- não troca o parâmetro de instrumento (RF-162).
--
-- Param = { row = "k3", layer = "{GUID da track}", name = "Reverb" | "" }
--         nome vazio usa o nome da linha do Mapeamento
--
-- M.init({ layers, kontakt_cc })
-- M.MAX                                   4 por camada (RF-144)
-- M.list(song) -> { Param }               só linhas que ainda existem (RF-172)
-- M.for_layer(song, slot, now) -> { View } até MAX; [] sem a camada (RF-173)
--   View = { row = Row, name, kind, value = 0–127?, on = bool?, held = bool,
--            flash = bool }   value nil: ainda não conhecido na música
-- M.count(song, slot) -> n
-- M.is_param(song, row_id) -> bool        a linha é parâmetro de uma camada
--                                         da música (o toast não aparece)
-- M.bind(song, slot, row_id) -> ok, err   liga a linha à camada; se já era de
--                                         outra camada, move (RF-159);
--                                         err = "full"|"no_layer"|"no_row"
-- M.move(song, row_id, slot) -> ok, err   err também "not_param"
-- M.rename(song, row_id, name) -> ok, err
-- M.remove(song, row_id) -> ok, err
--
-- Cada gravação é um passo de undo (RF-163) e tira da lista as linhas que
-- não existem mais no Mapeamento. JSON ilegível vira lista vazia (RF-175).

local json = require("vendor.json")

local M = {}

local PROJ = 0
local EXT_SECTION = "LiveSections"
local KEY_PREFIX = "params:"
local UNDO = "Live Sections: parâmetro da camada"
M.MAX = 4

local layers, kcc
local cache = nil       -- { key, state, list }: lido uma vez por mudança do projeto

function M.init(deps)
  layers, kcc = deps.layers, deps.kontakt_cc
  cache = nil
end

local function key_of(song)
  local guid = song and layers.song_key(song)
  return guid and KEY_PREFIX .. guid
end

local function decode(text)
  local ok, data = pcall(json.decode, text)
  if not ok or type(data) ~= "table" then return {} end
  local out = {}
  for _, p in ipairs(data) do
    if type(p) == "table" and type(p.row) == "string" and type(p.layer) == "string" then
      out[#out + 1] = { row = p.row, layer = p.layer, name = type(p.name) == "string" and p.name or "" }
    end
  end
  return out
end

-- Lista salva da música, inclusive linhas que já não existem.
local function read(key)
  local state = reaper.GetProjectStateChangeCount(PROJ)
  if cache and cache.key == key and cache.state == state then return cache.list end
  local ok, text = reaper.GetProjExtState(PROJ, EXT_SECTION, key)
  local list = (ok ~= 0 and text ~= "") and decode(text) or {}
  cache = { key = key, state = state, list = list }
  return list
end

local function alive(list)
  local out = {}
  for _, p in ipairs(list) do
    if kcc.get(p.row) then out[#out + 1] = { row = p.row, layer = p.layer, name = p.name } end
  end
  return out
end

local function write(key, list)
  reaper.Undo_BeginBlock()
  reaper.SetProjExtState(PROJ, EXT_SECTION, key, #list > 0 and json.encode(list) or "")
  reaper.Undo_EndBlock(UNDO, -1)
  cache = nil
end

local function find(list, row_id)
  for i, p in ipairs(list) do
    if p.row == row_id then return i, p end
  end
end

local function layer_guids(song)
  local out = {}
  for _, l in ipairs(layers.layers(song)) do out[l.track_guid] = l end
  return out
end

-- ------------------------------------------------------------------ leitura

function M.list(song)
  local key = key_of(song)
  if not key then return {} end
  return alive(read(key))
end

function M.for_layer(song, slot, now)
  local layer = layers.layers(song)[slot]
  if not layer then return {} end
  local out = {}
  for _, p in ipairs(M.list(song)) do
    if p.layer == layer.track_guid then
      local row = kcc.get(p.row)
      local v = kcc.value(row.id)
      local on = nil
      if row.kind == "toggle" and v ~= nil then on = v >= 64 end
      out[#out + 1] = {
        row = row, name = p.name ~= "" and p.name or row.name, kind = row.kind, value = v, on = on,
        held = row.kind == "momentary" and (v or 0) >= 64,
        flash = kcc.touched(row.id, now),
      }
      if #out == M.MAX then break end
    end
  end
  return out
end

function M.count(song, slot)
  local layer = layers.layers(song)[slot]
  if not layer then return 0 end
  local n = 0
  for _, p in ipairs(M.list(song)) do
    if p.layer == layer.track_guid then n = n + 1 end
  end
  return math.min(n, M.MAX)
end

function M.is_param(song, row_id)
  local _, p = find(M.list(song), row_id)
  return p ~= nil and layer_guids(song)[p.layer] ~= nil
end

-- ------------------------------------------------------------------ edição

function M.bind(song, slot, row_id)
  local key = key_of(song)
  local layer = key and layers.layers(song)[slot]
  if not layer then return false, "no_layer" end
  if not kcc.get(row_id) then return false, "no_row" end
  local list = alive(read(key))
  local i, p = find(list, row_id)
  if p and p.layer == layer.track_guid then return true end
  local n = 0
  for _, q in ipairs(list) do
    if q.layer == layer.track_guid then n = n + 1 end
  end
  if n >= M.MAX then return false, "full" end
  if i then table.remove(list, i) end
  list[#list + 1] = { row = row_id, layer = layer.track_guid, name = p and p.name or "" }
  write(key, list)
  return true
end

function M.move(song, row_id, slot)
  if not find(M.list(song), row_id) then return false, "not_param" end
  return M.bind(song, slot, row_id)
end

function M.rename(song, row_id, name)
  local key = key_of(song)
  if not key then return false, "not_param" end
  local list = alive(read(key))
  local _, p = find(list, row_id)
  if not p then return false, "not_param" end
  p.name = tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", "")
  write(key, list)
  return true
end

function M.remove(song, row_id)
  local key = key_of(song)
  if not key then return false, "not_param" end
  local list = alive(read(key))
  local i = find(list, row_id)
  if not i then return false, "not_param" end
  table.remove(list, i)
  write(key, list)
  return true
end

return M
