-- Kontakt por música e camadas.
--
-- Cada música pode ser vinculada à track do Kontakt dela, pelo GUID, em
-- ProjExtState("LiveSections", "kontakt:<GUID do marcador SONG:>") (RF-050).
-- As camadas são as tracks filhas diretas, na ordem do projeto (RF-051).
--
-- Ao trocar de música, só a track da música atual fica armada e monitorando,
-- com entrada no teclado escolhido nas configurações, nunca "All MIDI
-- inputs" (RF-052, RF-061). Com notas ou sustain segurados, a track anterior
-- continua armada até tudo ser solto (RF-053). Os Kontakts das outras músicas
-- entram em bypass (I_FXEN = 0) depois do tempo de cauda (RF-054, RF-055).
-- Música sem vínculo não roteia nada (RF-105).
--
-- Faders e botões de camada agem na camada N da música atual: volume nativo
-- da track filha (D_VOL, com a curva do fader do REAPER), mute e solo
-- (RF-056, RF-057, RF-060). Soft takeover (RF-058): depois de trocar de
-- música, o fader físico só assume quando cruza o valor atual da camada; até
-- lá, M.takeover(slot) diz para onde movê-lo (RF-059).
--
-- M.configure({ keyboard_port, bypass_tail_s })
-- M.link(song, track); M.unlink(song); M.track_of(song) -> track?
-- M.links(songs) -> { [song.id] = { key, track_guid } }   (para o validator)
-- M.layers(song) -> { { track, track_guid, name, slot } }
-- M.feed(event)                  eventos de midi/input (só os do teclado contam)
-- M.held() -> bool               há nota ou sustain segurado
-- M.activate(song, songs, now) -> ok, err ("no_keyboard")
-- M.tick(now)
-- M.set_layer_volume(slot, value) -> "set"|"waiting"|"no_layer"   value 0–1 do fader
-- M.takeover(slot) -> nil|"up"|"down"   direção para o fader alcançar a camada
-- M.toggle_mute(slot); M.toggle_solo(slot)
-- M.layer_state(slot) -> { name, pos (0–1), mute, solo }?
-- M.set_volume_ui(slot, pos)   fader da tela; o físico precisa alcançar de novo
-- M.release_takeover()   o fader físico precisa alcançar de novo (ex.: o
--                        volume mudou pela tela)

local M = {}

local PROJ = 0
local EXT_SECTION = "LiveSections"
local KEY_PREFIX = "kontakt:"
local MIDI_INPUT = 4096
local SUSTAIN_CC = 64
local TAKEOVER_TOL = 0.02   -- distância (0–1) em que o fader já conta como alcançado
local SOLO_IN_PLACE = 2

local settings = { keyboard_port = nil, bypass_tail_s = 5 }
local notes = {}        -- [canal * 128 + nota] = true
local sustain = {}      -- [canal] = true
local current = nil     -- track armada da música atual
local releasing = nil   -- track anterior, armada até o teclado ser solto
local bypass_at = {}    -- [track] = instante do bypass
local current_song = nil
local hw = {}           -- [slot] = última posição do fader físico (0–1)
local engaged = {}      -- [slot] = true quando o fader controla a camada

function M.configure(opts)
  settings.keyboard_port = opts.keyboard_port
  settings.bypass_tail_s = opts.bypass_tail_s or 5
end

-- ------------------------------------------------------------------ vínculo

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

local function link_key(song)
  local guid = marker_guid(song)
  return guid and KEY_PREFIX .. guid
end

local function track_by_guid(guid)
  for i = 0, reaper.CountTracks(PROJ) - 1 do
    local tr = reaper.GetTrack(PROJ, i)
    if reaper.GetTrackGUID(tr) == guid then return tr end
  end
end

function M.link(song, track)
  reaper.SetProjExtState(PROJ, EXT_SECTION, link_key(song), reaper.GetTrackGUID(track))
end

function M.unlink(song)
  reaper.SetProjExtState(PROJ, EXT_SECTION, link_key(song), "")
end

local function linked_guid(song)
  local key = link_key(song)
  if not key then return nil end
  local ok, guid = reaper.GetProjExtState(PROJ, EXT_SECTION, key)
  if ok == 0 or guid == "" then return nil end
  return guid, key
end

function M.track_of(song)
  local guid = linked_guid(song)
  return guid and track_by_guid(guid)
end

function M.links(songs)
  local out = {}
  for _, song in ipairs(songs) do
    local guid, key = linked_guid(song)
    if guid then out[song.id] = { key = key, track_guid = guid } end
  end
  return out
end

function M.layers(song)
  local kontakt = M.track_of(song)
  local out = {}
  if not kontakt then return out end
  for i = 0, reaper.CountTracks(PROJ) - 1 do
    local tr = reaper.GetTrack(PROJ, i)
    if reaper.GetParentTrack(tr) == kontakt then
      local _, name = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
      out[#out + 1] = { track = tr, track_guid = reaper.GetTrackGUID(tr), name = name, slot = #out + 1 }
    end
  end
  return out
end

-- ------------------------------------------------------------------ teclado

function M.feed(event)
  if event.port_name ~= settings.keyboard_port then return end
  local kind, ch = event.status & 0xF0, event.status & 0x0F
  if kind == 0x90 and event.data2 > 0 then
    notes[ch * 128 + event.data1] = true
  elseif kind == 0x80 or kind == 0x90 then
    notes[ch * 128 + event.data1] = nil
  elseif kind == 0xB0 and event.data1 == SUSTAIN_CC then
    sustain[ch] = event.data2 >= 64 or nil
  end
end

function M.held() return next(notes) ~= nil or next(sustain) ~= nil end

local function keyboard_index()
  if not settings.keyboard_port then return nil end
  for dev = 0, reaper.GetNumMIDIInputs() - 1 do
    local _, name = reaper.GetMIDIInputName(dev, "")
    if name == settings.keyboard_port then return dev end
  end
end

-- ------------------------------------------------------------------ troca

local function set(track, key, value)
  if reaper.GetMediaTrackInfo_Value(track, key) ~= value then
    reaper.SetMediaTrackInfo_Value(track, key, value)
  end
end

local function disarm(track)
  if not reaper.ValidatePtr(track, "MediaTrack*") then return end
  set(track, "I_RECARM", 0)
  set(track, "I_RECMON", 0)
end

local function arm(track, dev)
  set(track, "I_RECINPUT", MIDI_INPUT + (dev << 5))   -- canal 0: todos os canais
  set(track, "I_RECMON", 1)
  set(track, "I_RECARM", 1)
end

local function release(track)
  if track == releasing then releasing = nil end
  disarm(track)
end

function M.activate(song, songs, now)
  local track = song and M.track_of(song)
  local dev = keyboard_index()
  if track and not dev then return false, "no_keyboard" end
  if song ~= current_song and not (song and current_song and song.id == current_song.id) then
    engaged = {}
  end
  current_song = song

  if current and current ~= track then
    if M.held() then
      if releasing and releasing ~= current then release(releasing) end
      releasing = current
    else
      release(current)
    end
  end
  current = track
  if track then
    if track == releasing then releasing = nil end
    bypass_at[track] = nil
    set(track, "I_FXEN", 1)
    arm(track, dev)
  end

  for _, other in ipairs(songs or {}) do
    local tr = M.track_of(other)
    if tr and tr ~= track and bypass_at[tr] == nil and reaper.GetMediaTrackInfo_Value(tr, "I_FXEN") ~= 0 then
      bypass_at[tr] = now + settings.bypass_tail_s
    end
  end
  return true
end

function M.tick(now)
  if releasing and not M.held() then release(releasing) end
  for track, at in pairs(bypass_at) do
    if now >= at then
      bypass_at[track] = nil
      if track ~= current and reaper.ValidatePtr(track, "MediaTrack*") then set(track, "I_FXEN", 0) end
    end
  end
end

-- ------------------------------------------------------------------ camadas

local function layer_track(slot)
  if not current_song then return nil end
  local layer = M.layers(current_song)[slot]
  return layer and layer.track
end

local function fader_pos(track)
  local vol = reaper.GetMediaTrackInfo_Value(track, "D_VOL")
  if vol <= 0 then return 0 end
  return math.max(0, math.min(1, reaper.DB2SLIDER(20 * math.log(vol, 10)) / 1000))
end

local function volume_of(pos)
  if pos <= 0 then return 0 end
  return 10 ^ (reaper.SLIDER2DB(pos * 1000) / 20)
end

function M.set_layer_volume(slot, value)
  local track = layer_track(slot)
  local last = hw[slot]
  hw[slot] = value
  if not track then return "no_layer" end
  if not engaged[slot] then
    local target = fader_pos(track)
    local crossed = last ~= nil and (last - target) * (value - target) <= 0
    if not crossed and math.abs(value - target) > TAKEOVER_TOL then return "waiting" end
    engaged[slot] = true
  end
  reaper.SetMediaTrackInfo_Value(track, "D_VOL", volume_of(value))
  return "set"
end

function M.takeover(slot)
  local track = layer_track(slot)
  if not track or engaged[slot] or hw[slot] == nil then return nil end
  return hw[slot] < fader_pos(track) and "up" or "down"
end

function M.release_takeover() engaged = {} end

function M.layer_state(slot)
  local layer = current_song and M.layers(current_song)[slot]
  if not layer then return nil end
  local tr = layer.track
  return {
    name = layer.name, pos = fader_pos(tr),
    mute = reaper.GetMediaTrackInfo_Value(tr, "B_MUTE") ~= 0,
    solo = reaper.GetMediaTrackInfo_Value(tr, "I_SOLO") ~= 0,
  }
end

function M.set_volume_ui(slot, pos)
  local track = layer_track(slot)
  if not track then return false end
  reaper.SetMediaTrackInfo_Value(track, "D_VOL", volume_of(math.max(0, math.min(1, pos))))
  engaged[slot] = nil
  return true
end

local function toggle(slot, key, on_value)
  local track = layer_track(slot)
  if not track then return false end
  local on = reaper.GetMediaTrackInfo_Value(track, key) ~= 0
  reaper.SetMediaTrackInfo_Value(track, key, on and 0 or on_value)
  return true
end

function M.toggle_mute(slot) return toggle(slot, "B_MUTE", 1) end
function M.toggle_solo(slot) return toggle(slot, "I_SOLO", SOLO_IN_PLACE) end

-- Volta ao estado inicial (para testes e para recarregar o projeto).
function M.reset()
  notes, sustain, current, releasing, bypass_at = {}, {}, nil, nil, {}
  current_song, hw, engaged = nil, {}, {}
end

return M
