-- Multitracks: tracks de áudio de cada música (bateria, baixo, vozes…) que
-- aparecem com fader no grupo MULTITRACKS, ao lado das camadas do Kontakt.
--
-- A escolha é por música, no ProjExtState("LiveSections", "stems:<GUID do
-- marcador SONG:>"), em JSON com os GUIDs das tracks (RF-214). Na leitura,
-- saem as tracks apagadas e as que são o Kontakt ou camadas dele (RF-232);
-- a ordem é a das tracks no projeto. Até 8 por música (RF-215). Cada
-- mudança é um passo de undo sem o estado dos plugins (RF-216).
--
-- O volume segue a curva do mixer (core/fader) com soft takeover próprio,
-- reiniciado ao trocar de música (RF-222, RF-234), como nas camadas.
--
-- M.init({ layers })
-- M.MAX                                   8
-- M.candidates(song) -> { { track, name, on } }   tracks com item na música
--                                         e as já escolhidas, sem Kontakt
--                                         nem camadas (RF-212, RF-213)
-- M.list(song) -> { track }
-- M.set(song, tracks) -> ok, err ("full")
-- M.toggle(song, track) -> ok, err
-- M.activate(song)                        música atual
-- M.count() -> n                          multitracks da música atual
-- M.set_volume(slot, value) -> "set"|"waiting"|"no_stem"   value 0–1
-- M.takeover(slot) -> nil|"up"|"down"
-- M.set_volume_ui(slot, pos) -> bool      fader da tela; o físico alcança de novo
-- M.toggle_mute(slot) -> bool
-- M.rename(slot, name) -> ok, final|err ("empty_name", "no_stem")
-- M.state(slot) -> { name, pos, mute, peak_l, peak_r, color? }?

local json = require("vendor.json")
local fader = require("core.fader")
local track_color = require("core.track_color")

local M = {}

local PROJ = 0
local EXT_SECTION = "LiveSections"
local KEY_PREFIX = "stems:"
local UNDO = "Live Sections: multitracks da música"
local EPS = 1e-6
local TAKEOVER_TOL = 0.02
M.MAX = 8

local layers
local cache = nil       -- { state, key, list }: relido quando o projeto muda
local current = nil     -- música atual
local hw, engaged = {}, {}

function M.init(deps)
  layers = deps.layers
  cache, current, hw, engaged = nil, nil, {}, {}
end

-- ------------------------------------------------------------------ lista

local function key_of(song)
  local guid = song and layers.song_key(song)
  return guid and KEY_PREFIX .. guid
end

-- Tracks que nunca são multitrack: o Kontakt da música e as camadas dele.
local function excluded(song)
  local out = {}
  local kontakt = layers.track_of(song)
  if kontakt then
    out[kontakt] = true
    for _, tr in ipairs(layers.layers_of(kontakt)) do out[tr] = true end
  end
  return out
end

local function read_guids(key)
  local ok, text = reaper.GetProjExtState(PROJ, EXT_SECTION, key)
  if ok == 0 or text == "" then return {} end
  local good, data = pcall(json.decode, text)
  if not good or type(data) ~= "table" then return {} end
  local out = {}
  for _, g in ipairs(data) do if type(g) == "string" then out[g] = true end end
  return out
end

function M.list(song)
  local key = key_of(song)
  if not key then return {} end
  local state = reaper.GetProjectStateChangeCount(PROJ)
  if cache and cache.key == key and cache.state == state then return cache.list end
  local guids, skip, list = read_guids(key), excluded(song), {}
  for i = 0, reaper.CountTracks(PROJ) - 1 do
    local tr = reaper.GetTrack(PROJ, i)
    if guids[reaper.GetTrackGUID(tr)] and not skip[tr] and #list < M.MAX then list[#list + 1] = tr end
  end
  cache = { key = key, state = state, list = list }
  return list
end

local function has_item_in(tr, song)
  for k = 0, reaper.CountTrackMediaItems(tr) - 1 do
    local p = reaper.GetMediaItemInfo_Value(reaper.GetTrackMediaItem(tr, k), "D_POSITION")
    if p >= song.start_pos - EPS and p < song.end_pos - EPS then return true end
  end
  return false
end

function M.candidates(song)
  local chosen = {}
  for _, tr in ipairs(M.list(song)) do chosen[tr] = true end
  local skip, out = excluded(song), {}
  for i = 0, reaper.CountTracks(PROJ) - 1 do
    local tr = reaper.GetTrack(PROJ, i)
    if not skip[tr] and (chosen[tr] or has_item_in(tr, song)) then
      local _, name = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
      out[#out + 1] = { track = tr, name = name ~= "" and name or ("Track " .. (i + 1)), on = chosen[tr] == true }
    end
  end
  return out
end

function M.set(song, tracks)
  local key = key_of(song)
  if not key then return false, "no_song" end
  if #tracks > M.MAX then return false, "full" end
  local guids = {}
  for _, tr in ipairs(tracks) do guids[#guids + 1] = reaper.GetTrackGUID(tr) end
  reaper.Undo_BeginBlock()
  reaper.SetProjExtState(PROJ, EXT_SECTION, key, #guids > 0 and json.encode(guids) or "")
  reaper.Undo_EndBlock(UNDO, 8)   -- só extensões do projeto, sem estado de plugins
  cache = nil
  return true
end

function M.toggle(song, track)
  local list, out, found = M.list(song), {}, false
  for _, tr in ipairs(list) do
    if tr == track then found = true else out[#out + 1] = tr end
  end
  if not found then
    if #list >= M.MAX then return false, "full" end
    out[#out + 1] = track
  end
  return M.set(song, out)
end

-- ------------------------------------------------------------------ ao vivo

function M.activate(song)
  if not (song and current and song.id == current.id) then hw, engaged = {}, {} end
  current = song
end

local function stem_track(slot)
  return current and M.list(current)[slot]
end

function M.count() return current and #M.list(current) or 0 end

function M.set_volume(slot, value)
  local track = stem_track(slot)
  local last = hw[slot]
  hw[slot] = value
  if not track then return "no_stem" end
  if not engaged[slot] then
    local target = fader.pos_of(track)
    local crossed = last ~= nil and (last - target) * (value - target) <= 0
    if not crossed and math.abs(value - target) > TAKEOVER_TOL then return "waiting" end
    engaged[slot] = true
  end
  reaper.SetMediaTrackInfo_Value(track, "D_VOL", fader.volume_of(value))
  return "set"
end

function M.takeover(slot)
  local track = stem_track(slot)
  if not track or engaged[slot] or hw[slot] == nil then return nil end
  return hw[slot] < fader.pos_of(track) and "up" or "down"
end

function M.set_volume_ui(slot, pos)
  local track = stem_track(slot)
  if not track then return false end
  reaper.SetMediaTrackInfo_Value(track, "D_VOL", fader.volume_of(math.max(0, math.min(1, pos))))
  engaged[slot] = nil
  return true
end

function M.toggle_mute(slot)
  local track = stem_track(slot)
  if not track then return false end
  local on = reaper.GetMediaTrackInfo_Value(track, "B_MUTE") ~= 0
  reaper.SetMediaTrackInfo_Value(track, "B_MUTE", on and 0 or 1)
  return true
end

function M.rename(slot, name)
  local final = tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if final == "" then return false, "empty_name" end
  local track = stem_track(slot)
  if not track then return false, "no_stem" end
  reaper.Undo_BeginBlock()
  reaper.GetSetMediaTrackInfo_String(track, "P_NAME", final, true)
  reaper.Undo_EndBlock("Live Sections: renomear multitrack", 1)
  return true, final
end

function M.state(slot)
  local tr = stem_track(slot)
  if not tr then return nil end
  local _, name = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
  return {
    name = name, pos = fader.pos_of(tr),
    mute = reaper.GetMediaTrackInfo_Value(tr, "B_MUTE") ~= 0, color = track_color.get(tr),
    peak_l = reaper.Track_GetPeakInfo(tr, 0), peak_r = reaper.Track_GetPeakInfo(tr, 1),
  }
end

return M
