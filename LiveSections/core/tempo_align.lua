-- Alinhamento de tempo para músicas gravadas sem grid (tempo constante).
--
-- O áudio não é tocado: marcadores de tempo fazem o grid coincidir com o
-- áudio. Requer o projeto com timebase em tempo (Project Settings): em
-- timebase de batidas, mudar o tempo arrasta itens, regiões e marcadores
-- (visto no spike 06).
--
-- O REAPER só aceita mudança de fórmula de compasso numa linha de compasso.
-- Por isso o compasso 1 é preparado por um marcador só de tempo no início da
-- música (a "entrada"), com o andamento que faz uma linha de compasso cair
-- exatamente no primeiro tempo forte. Ali entra o marcador com o BPM da música.
-- A música seguinte ganha um marcador no início dela que guarda o tempo e,
-- se ela já estava alinhada, a entrada dela é recalculada.

local M = {}

local PROJ = 0
local EPS = 1e-6
local MIN_TAPS = 4
local TAP_RESET_S = 2.0        -- pausa maior que isso começa uma nova contagem
local MAX_TAPS = 16

local taps = {}

-- ------------------------------------------------------------------ tap tempo

-- Arredonda o BPM: "int" (inteiro), "half" (meio BPM) ou exato (2 casas).
function M.round(bpm, mode)
  if mode == "int" then return math.floor(bpm + 0.5) end
  if mode == "half" then return math.floor(bpm * 2 + 0.5) / 2 end
  return math.floor(bpm * 100 + 0.5) / 100
end

function M.reset_taps() taps = {} end
function M.tap_count() return #taps end

-- Registra um toque no instante `t` (segundos). A partir de 4 toques, retorna
-- o BPM pela média dos intervalos.
function M.tap(t, round_mode)
  if #taps > 0 and t - taps[#taps] > TAP_RESET_S then taps = {} end
  taps[#taps + 1] = t
  if #taps > MAX_TAPS then table.remove(taps, 1) end
  if #taps < MIN_TAPS then return nil end
  local avg = (taps[#taps] - taps[1]) / (#taps - 1)
  return M.round(60 / avg, round_mode)
end

-- ------------------------------------------------------------------ timebase

-- O projeto precisa estar em timebase de tempo para itens, marcadores e o
-- mapa de tempo. Retorna true ou false e o nome da configuração errada.
function M.check_timebase()
  for _, var in ipairs({ "itemtimelock", "tempoenvtimelock" }) do
    local ok, v = reaper.get_config_var_string(var)
    if ok and tonumber(v) ~= 0 then return false, var end
  end
  return true
end

-- ------------------------------------------------------------------ marcadores

local function marker(idx)
  local _, time, _, _, bpm, num, denom = reaper.GetTempoTimeSigMarker(PROJ, idx)
  return { idx = idx, time = time, bpm = bpm, num = num, denom = denom }
end

local function markers_between(a, b)
  local out = {}
  for i = 0, reaper.CountTempoTimeSigMarkers(PROJ) - 1 do
    local m = marker(i)
    if m.time >= a - EPS and m.time < b - EPS then out[#out + 1] = m end
  end
  return out
end

local function marker_at(time)
  for i = 0, reaper.CountTempoTimeSigMarkers(PROJ) - 1 do
    local m = marker(i)
    if math.abs(m.time - time) < EPS then return m end
  end
end

local function delete_between(a, b)
  local list = markers_between(a, b)
  for i = #list, 1, -1 do reaper.DeleteTempoTimeSigMarker(PROJ, list[i].idx) end
end

-- Compasso 1 já marcado na música: o primeiro marcador com fórmula de compasso.
local function downbeat_of(start_pos, end_pos)
  for _, m in ipairs(markers_between(start_pos, end_pos)) do
    if m.num > 0 then return m end
  end
end

local function limit(next_song) return next_song and next_song.start_pos or math.huge end

-- Marcador só de tempo em `from` com o andamento que põe uma linha de compasso
-- exatamente em `to`, o mais perto possível de `target_bpm`.
local function lead_in(from, to, target_bpm)
  if to - from < EPS then return end
  local _, _, bpm_now = reaper.TimeMap_GetTimeSigAtTime(PROJ, from)
  local beat, measure = reaper.TimeMap2_timeToBeats(PROJ, from)
  local bar_start = reaper.TimeMap2_beatsToTime(PROJ, 0, measure)
  local next_bar = reaper.TimeMap2_beatsToTime(PROJ, 0, measure + 1)
  local bar_len = next_bar - bar_start
  local to_bar = beat < EPS and 0 or next_bar - from
  -- Mudar o andamento por um fator f divide as durações por f.
  local k = math.max(0, math.floor(((to - from) * target_bpm / bpm_now - to_bar) / bar_len + 0.5))
  if to_bar < EPS and k == 0 then k = 1 end
  local f = (to_bar + k * bar_len) / (to - from)
  reaper.SetTempoTimeSigMarker(PROJ, -1, from, -1, -1, bpm_now * f, 0, 0, false)
end

-- Põe o compasso 1 da música em `pos` com `bpm`, trocando os marcadores que a
-- música tinha.
local function place_downbeat(song, next_song, pos, bpm)
  local num, denom = reaper.TimeMap_GetTimeSigAtTime(PROJ, pos)
  local next_num, next_denom, next_bpm
  if next_song then next_num, next_denom, next_bpm = reaper.TimeMap_GetTimeSigAtTime(PROJ, next_song.start_pos) end
  local next_downbeat = next_song and downbeat_of(next_song.start_pos + EPS, math.huge)

  delete_between(song.start_pos, limit(next_song))
  lead_in(song.start_pos, pos, bpm)
  reaper.SetTempoTimeSigMarker(PROJ, -1, pos, -1, -1, bpm, num, denom, false)

  if next_song then
    if next_downbeat and next_downbeat.time < (next_song.end_pos or math.huge) then
      -- A música seguinte já estava alinhada: refaz a entrada dela.
      local old = marker_at(next_song.start_pos)
      if old then reaper.DeleteTempoTimeSigMarker(PROJ, old.idx) end
      lead_in(next_song.start_pos, next_downbeat.time, next_downbeat.bpm)
    elseif not marker_at(next_song.start_pos) then
      reaper.SetTempoTimeSigMarker(PROJ, -1, next_song.start_pos, -1, -1, next_bpm, 0, 0, false)
    end
  end
  return num, denom
end

-- Itens com timebase de batidas próprio ignoram o do projeto e andariam com a
-- mudança de tempo (spike 06). Ficam em tempo durante a operação e depois
-- voltam ao modo original, sem sair do lugar.
local function with_items_locked(fn)
  local changed = {}
  for i = 0, reaper.CountMediaItems(PROJ) - 1 do
    local it = reaper.GetMediaItem(PROJ, i)
    local mode = reaper.GetMediaItemInfo_Value(it, "C_BEATATTACHMODE")
    if mode == 1 or mode == 2 then
      changed[#changed + 1] = { it, mode }
      reaper.SetMediaItemInfo_Value(it, "C_BEATATTACHMODE", 0)
    end
  end
  fn()
  for _, c in ipairs(changed) do reaper.SetMediaItemInfo_Value(c[1], "C_BEATATTACHMODE", c[2]) end
end

local function undoable(desc, fn)
  reaper.Undo_BeginBlock()
  with_items_locked(fn)
  reaper.Undo_EndBlock("Live Sections: " .. desc, -1)
end

-- Marca o compasso 1 da música em `pos` (o primeiro tempo forte do áudio) com
-- `bpm`. Retorna ok e o BPM aplicado, ou false e o motivo.
function M.set_downbeat(song, next_song, pos, bpm, round_mode)
  if pos < song.start_pos - EPS or pos >= limit(next_song) - EPS then return false, "outside_song" end
  if not bpm or bpm <= 0 then return false, "no_bpm" end
  local tb_ok, var = M.check_timebase()
  if not tb_ok then return false, "timebase_beats", var end
  bpm = M.round(bpm, round_mode)
  undoable("marcar compasso 1", function() place_downbeat(song, next_song, pos, bpm) end)
  return true, bpm
end

-- Ajuste fino: BPM em `d_bpm` e posição do compasso 1 em `d_ms` milissegundos.
-- Retorna ok, bpm, posição do compasso 1.
function M.nudge(song, next_song, d_bpm, d_ms)
  local db = downbeat_of(song.start_pos, limit(next_song))
  if not db then return false, "no_downbeat" end
  local tb_ok, var = M.check_timebase()
  if not tb_ok then return false, "timebase_beats", var end
  local new_time = db.time + (d_ms or 0) / 1000
  local new_bpm = M.round(db.bpm + (d_bpm or 0))
  if new_time < song.start_pos - EPS or new_time >= limit(next_song) - EPS or new_bpm <= 0 then
    return false, "out_of_range"
  end
  undoable("ajuste fino do tempo", function() place_downbeat(song, next_song, new_time, new_bpm) end)
  return true, new_bpm, new_time
end

return M
