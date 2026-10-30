-- Alinhamento de tempo para músicas gravadas sem grid (tempo constante).
--
-- O áudio não é tocado: um marcador de tempo no primeiro tempo forte da
-- música faz o grid coincidir com o áudio. Para não mudar o tempo das músicas
-- seguintes, um marcador no início da música seguinte guarda o tempo e a
-- fórmula que valiam ali antes da mudança.

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

-- ------------------------------------------------------------------ marcadores

local function markers_between(a, b)
  local out = {}
  for i = 0, reaper.CountTempoTimeSigMarkers(PROJ) - 1 do
    local _, time = reaper.GetTempoTimeSigMarker(PROJ, i)
    if time >= a - EPS and time < b - EPS then out[#out + 1] = i end
  end
  return out
end

local function marker_at(time)
  for i = 0, reaper.CountTempoTimeSigMarkers(PROJ) - 1 do
    local _, t = reaper.GetTempoTimeSigMarker(PROJ, i)
    if math.abs(t - time) < EPS then return i end
  end
end

-- Garante um marcador no início da próxima música com o tempo que vale lá.
local function preserve_next(next_song)
  if not next_song or marker_at(next_song.start_pos) then return end
  local num, denom, bpm = reaper.TimeMap_GetTimeSigAtTime(PROJ, next_song.start_pos)
  reaper.SetTempoTimeSigMarker(PROJ, -1, next_song.start_pos, -1, -1, bpm, num, denom, false)
end

local function limit(song, next_song) return next_song and next_song.start_pos or math.huge end

local function undoable(desc, fn)
  reaper.Undo_BeginBlock()
  fn()
  reaper.Undo_EndBlock("Live Sections: " .. desc, -1)
end

-- Marca o compasso 1 da música em `pos` (o primeiro tempo forte do áudio) com
-- `bpm`. Substitui os marcadores de tempo que existiam dentro da música.
function M.set_downbeat(song, next_song, pos, bpm, round_mode)
  if pos < song.start_pos - EPS or pos >= limit(song, next_song) - EPS then return false, "outside_song" end
  if not bpm or bpm <= 0 then return false, "no_bpm" end
  bpm = M.round(bpm, round_mode)
  local num, denom = reaper.TimeMap_GetTimeSigAtTime(PROJ, pos)
  undoable("marcar compasso 1", function()
    preserve_next(next_song)
    local old = markers_between(song.start_pos, limit(song, next_song))
    for i = #old, 1, -1 do reaper.DeleteTempoTimeSigMarker(PROJ, old[i]) end
    reaper.SetTempoTimeSigMarker(PROJ, -1, pos, -1, -1, bpm, num, denom, false)
  end)
  return true, bpm
end

-- Ajuste fino: BPM em `d_bpm` e posição do compasso 1 em `d_ms` milissegundos.
-- Retorna ok, bpm, posição do compasso 1.
function M.nudge(song, next_song, d_bpm, d_ms)
  local idx = markers_between(song.start_pos, limit(song, next_song))[1]
  if not idx then return false, "no_downbeat" end
  local _, time, _, _, bpm, num, denom = reaper.GetTempoTimeSigMarker(PROJ, idx)
  local new_time = time + (d_ms or 0) / 1000
  local new_bpm = M.round(bpm + (d_bpm or 0))
  if new_time < song.start_pos - EPS or new_time >= limit(song, next_song) - EPS or new_bpm <= 0 then
    return false, "out_of_range"
  end
  undoable("ajuste fino do tempo", function()
    preserve_next(next_song)
    reaper.SetTempoTimeSigMarker(PROJ, idx, new_time, -1, -1, new_bpm, num, denom, false)
  end)
  return true, new_bpm, new_time
end

return M
