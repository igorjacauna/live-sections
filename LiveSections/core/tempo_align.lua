-- Alinhamento de tempo para músicas gravadas sem grid (tempo constante).
--
-- O áudio não é tocado: marcadores de tempo fazem o grid coincidir com o
-- áudio.
--
-- O REAPER só aceita mudança de fórmula de compasso numa linha de compasso.
-- Por isso o compasso 1 é preparado por um marcador só de tempo no início da
-- música (a "entrada"), com o andamento que faz uma linha de compasso cair
-- exatamente no primeiro tempo forte. Ali entra o marcador com o BPM da música.
--
-- No padrão do REAPER (timebase em batidas), mudar o tempo arrasta tudo o que
-- vem depois (spike 06). Para nada sair do lugar:
--   - itens ficam em timebase de tempo durante a operação e depois voltam;
--   - marcadores e regiões voltam à posição em segundos que tinham antes;
--   - os marcadores de tempo depois da música são recriados na mesma posição
--     em segundos, em ordem, e a entrada de cada música já alinhada é
--     recalculada para o compasso 1 dela continuar no mesmo ponto do áudio.
-- Automação de tracks não é preservada (fora do uso previsto).

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

-- ------------------------------------------------------------------ marcadores de tempo

local function tempo_marker(idx)
  local _, time, _, _, bpm, num, denom = reaper.GetTempoTimeSigMarker(PROJ, idx)
  return { idx = idx, time = time, bpm = bpm, num = num, denom = denom }
end

local function tempo_markers_between(a, b)
  local out = {}
  for i = 0, reaper.CountTempoTimeSigMarkers(PROJ) - 1 do
    local m = tempo_marker(i)
    if m.time >= a - EPS and m.time < b - EPS then out[#out + 1] = m end
  end
  return out
end

-- O REAPER só recalcula o mapa de tempo (TimeMap*) depois de UpdateTimeline:
-- sem isso, a entrada seguinte era calculada sobre o mapa antigo (spike 06).
local function delete_tempo(idx)
  reaper.DeleteTempoTimeSigMarker(PROJ, idx)
  reaper.UpdateTimeline()
end

local function delete_tempo_from(a)
  local list = tempo_markers_between(a, math.huge)
  for i = #list, 1, -1 do reaper.DeleteTempoTimeSigMarker(PROJ, list[i].idx) end
  reaper.UpdateTimeline()
end

local function add_tempo(time, bpm, num, denom)
  reaper.SetTempoTimeSigMarker(PROJ, -1, time, -1, -1, bpm, num or 0, denom or 0, false)
  reaper.UpdateTimeline()
end

-- Compasso 1 já marcado na música: o primeiro marcador com fórmula de compasso.
local function downbeat_of(start_pos, end_pos)
  for _, m in ipairs(tempo_markers_between(start_pos, end_pos)) do
    if m.num > 0 then return m end
  end
end

local function limit(next_song) return next_song and next_song.start_pos or math.huge end

-- Andamento de um marcador só de tempo em `from` que põe uma linha de
-- compasso exatamente em `to`, o mais perto possível de `target_bpm`.
local function lead_in_bpm(from, to, target_bpm)
  local _, _, bpm_now = reaper.TimeMap_GetTimeSigAtTime(PROJ, from)
  local beat, measure = reaper.TimeMap2_timeToBeats(PROJ, from)
  local bar_start = reaper.TimeMap2_beatsToTime(PROJ, 0, measure)
  local next_bar = reaper.TimeMap2_beatsToTime(PROJ, 0, measure + 1)
  local bar_len = next_bar - bar_start
  local to_bar = beat < EPS and 0 or next_bar - from
  -- Mudar o andamento por um fator f divide as durações por f.
  local k = math.max(0, math.floor(((to - from) * target_bpm / bpm_now - to_bar) / bar_len + 0.5))
  if to_bar < EPS and k == 0 then k = 1 end
  return bpm_now * (to_bar + k * bar_len) / (to - from)
end

local function add_lead_in(from, to, target_bpm)
  if to - from < EPS then return end
  add_tempo(from, lead_in_bpm(from, to, target_bpm))
end

-- ------------------------------------------------------------------ preservar o que vem depois

local function snapshot_markers()
  local list, i = {}, 0
  while true do
    local ret, isrgn, pos, rgnend, name, idx, color = reaper.EnumProjectMarkers3(PROJ, i)
    if ret == 0 then return list end
    list[#list + 1] = { isrgn = isrgn, pos = pos, rgnend = rgnend, name = name, idx = idx, color = color }
    i = i + 1
  end
end

local function restore_markers(list)
  for _, m in ipairs(list) do
    reaper.SetProjectMarker3(PROJ, m.idx, m.isrgn, m.pos, m.isrgn and m.rgnend or 0, m.name, m.color)
  end
end

-- Itens ficam em timebase de tempo durante `fn` e depois voltam ao modo
-- original, sem sair do lugar.
local function with_items_locked(fn)
  local changed = {}
  for i = 0, reaper.CountMediaItems(PROJ) - 1 do
    local it = reaper.GetMediaItem(PROJ, i)
    local mode = reaper.GetMediaItemInfo_Value(it, "C_BEATATTACHMODE")
    if mode ~= 0 then
      changed[#changed + 1] = { it, mode }
      reaper.SetMediaItemInfo_Value(it, "C_BEATATTACHMODE", 0)
    end
  end
  fn()
  for _, c in ipairs(changed) do reaper.SetMediaItemInfo_Value(c[1], "C_BEATATTACHMODE", c[2]) end
end

-- Recria, em ordem e na mesma posição em segundos, os marcadores de tempo que
-- vinham depois. Antes de cada mudança de fórmula, a entrada que a precede é
-- recalculada para a linha de compasso continuar no mesmo ponto.
local function rebuild_after(later, after_time)
  local last = nil -- último marcador recriado: { time, num }
  for _, m in ipairs(later) do
    if m.num > 0 then
      if last and last.num == 0 and last.time > after_time + EPS then
        delete_tempo(tempo_markers_between(last.time, last.time + 2 * EPS)[1].idx)
        add_lead_in(last.time, m.time, m.bpm)
      end
    end
    add_tempo(m.time, m.bpm, m.num, m.denom)
    last = m
  end
end

-- Põe o compasso 1 da música em `pos` com `bpm`, trocando os marcadores que a
-- música tinha e preservando tudo o que vem depois.
local function place_downbeat(song, next_song, pos, bpm)
  local num, denom = reaper.TimeMap_GetTimeSigAtTime(PROJ, pos)
  local later = tempo_markers_between(limit(next_song), math.huge)
  if next_song and not (later[1] and math.abs(later[1].time - next_song.start_pos) < EPS) then
    -- guarda o tempo que valia no início da música seguinte
    local _, _, next_bpm = reaper.TimeMap_GetTimeSigAtTime(PROJ, next_song.start_pos)
    table.insert(later, 1, { time = next_song.start_pos, bpm = next_bpm, num = 0, denom = 0 })
  end
  local markers = snapshot_markers()

  delete_tempo_from(song.start_pos)
  add_lead_in(song.start_pos, pos, bpm)
  add_tempo(pos, bpm, num, denom)
  rebuild_after(later, pos)
  restore_markers(markers)
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
  bpm = M.round(bpm, round_mode)
  undoable("marcar compasso 1", function() place_downbeat(song, next_song, pos, bpm) end)
  return true, bpm
end

-- Ajuste fino: BPM em `d_bpm` e posição do compasso 1 em `d_ms` milissegundos.
-- Retorna ok, bpm, posição do compasso 1.
function M.nudge(song, next_song, d_bpm, d_ms)
  local db = downbeat_of(song.start_pos, limit(next_song))
  if not db then return false, "no_downbeat" end
  local new_time = db.time + (d_ms or 0) / 1000
  local new_bpm = M.round(db.bpm + (d_bpm or 0))
  if new_time < song.start_pos - EPS or new_time >= limit(next_song) - EPS or new_bpm <= 0 then
    return false, "out_of_range"
  end
  undoable("ajuste fino do tempo", function() place_downbeat(song, next_song, new_time, new_bpm) end)
  return true, new_bpm, new_time
end

return M
