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
M.MIN_BPM, M.MAX_BPM = 20, 400

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

-- Marcador só de tempo: o REAPER pode devolver fórmula -1 (não só 0);
-- aqui fica sempre 0.
local function tempo_marker(idx)
  local _, time, _, _, bpm, num, denom, linear = reaper.GetTempoTimeSigMarker(PROJ, idx)
  if num <= 0 then num, denom = 0, 0 end
  return { idx = idx, time = time, bpm = bpm, num = num, denom = denom, linear = linear }
end

local function tempo_markers_between(a, b)
  local out = {}
  for i = 0, reaper.CountTempoTimeSigMarkers(PROJ) - 1 do
    local m = tempo_marker(i)
    if m.time >= a - EPS and m.time < b - EPS then out[#out + 1] = m end
  end
  return out
end

local function delete_tempo_from(a)
  local list = tempo_markers_between(a, math.huge)
  for i = #list, 1, -1 do reaper.DeleteTempoTimeSigMarker(PROJ, list[i].idx) end
end

local function add_tempo(time, bpm, num, denom)
  reaper.SetTempoTimeSigMarker(PROJ, -1, time, -1, -1, bpm, num or 0, denom or 0, false)
end

-- Compasso 1 já marcado na música: o primeiro marcador com fórmula de compasso.
local function downbeat_of(start_pos, end_pos)
  for _, m in ipairs(tempo_markers_between(start_pos, end_pos)) do
    if m.num > 0 then return m end
  end
end

local function limit(next_song) return next_song and next_song.start_pos or math.huge end

-- ------------------------------------------------------------------ contagem de batidas
--
-- As contas usam a lista de marcadores, não o TimeMap: assim não dependem de
-- quando o REAPER recalcula o mapa no meio da operação e podem ser testadas
-- fora dele.
--
-- Grade = { time, beat (semínimas desde a última linha de compasso),
--           bar (semínimas por compasso), bpm }

local function bar_qn(num, denom) return num * 4 / denom end

-- Grade em `t` vista a partir de `g`, sem marcadores no meio.
local function advance(g, t)
  local beat = (g.beat + (t - g.time) * g.bpm / 60) % g.bar
  if g.bar - beat < 1e-6 then beat = 0 end
  return { time = t, beat = beat, bar = g.bar, bpm = g.bpm }
end

-- Grade em `t` considerando só os marcadores antes de `t`. Antes do primeiro
-- marcador valem o tempo e a fórmula do projeto (denominador 4).
local function grid_before(t)
  local bpm, num = reaper.GetProjectTimeSignature2(PROJ)
  local g = { time = 0, beat = 0, bar = bar_qn(num, 4), bpm = bpm }
  local linear = false
  for _, m in ipairs(tempo_markers_between(-math.huge, t)) do
    if linear then g.bpm = (g.bpm + m.bpm) / 2 end -- rampa: tempo médio do trecho
    g = advance(g, m.time)
    g.bpm, linear = m.bpm, m.linear
    if m.num > 0 then g.beat, g.bar = 0, bar_qn(m.num, m.denom) end
  end
  return advance(g, t)
end

-- Tempo e fórmula em vigor em `t` (marcadores até `t`, inclusive).
local function tempo_at(t)
  local bpm, num = reaper.GetProjectTimeSignature2(PROJ)
  local denom = 4
  for _, m in ipairs(tempo_markers_between(-math.huge, t + 2 * EPS)) do
    bpm = m.bpm
    if m.num > 0 then num, denom = m.num, m.denom end
  end
  return bpm, num, denom
end

-- Andamento de um marcador só de tempo em `from` (grade `g`) que põe uma
-- linha de compasso exatamente em `to`, o mais perto possível de `target_bpm`.
local function lead_in_bpm(g, to, target_bpm)
  local to_bar = g.beat < 1e-6 and 0 or g.bar - g.beat
  local span = to - g.time
  local k = math.max(0, math.floor((span * target_bpm / 60 - to_bar) / g.bar + 0.5))
  if to_bar < 1e-6 and k == 0 then k = 1 end
  return 60 * (to_bar + k * g.bar) / span
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
-- vinham depois, a partir da grade `g`. A entrada antes de cada mudança de
-- fórmula é recalculada para a linha de compasso continuar no mesmo ponto.
local function rebuild_after(later, g)
  for i, m in ipairs(later) do
    g = advance(g, m.time)
    local nxt = later[i + 1]
    local bpm = m.bpm
    if m.num == 0 and nxt and nxt.num > 0 then bpm = lead_in_bpm(g, nxt.time, nxt.bpm) end
    add_tempo(m.time, bpm, m.num, m.denom)
    g.bpm = bpm
    if m.num > 0 then g.beat, g.bar = 0, bar_qn(m.num, m.denom) end
  end
end

-- Põe o compasso 1 da música em `pos` com `bpm`, trocando os marcadores que a
-- música tinha e preservando tudo o que vem depois. Com `tempo_only`, só troca
-- o tempo no início da música (sem compasso 1 marcado, a grade continua).
local function place_downbeat(song, next_song, pos, bpm, tempo_only)
  local _, num, denom = tempo_at(pos)
  local later = tempo_markers_between(limit(next_song), math.huge)
  if next_song and not (later[1] and math.abs(later[1].time - next_song.start_pos) < EPS) then
    -- guarda o tempo que valia no início da música seguinte
    local next_bpm = tempo_at(next_song.start_pos)
    table.insert(later, 1, { time = next_song.start_pos, bpm = next_bpm, num = 0, denom = 0 })
  end
  local markers = snapshot_markers()
  local start = grid_before(song.start_pos)

  delete_tempo_from(song.start_pos)
  if tempo_only then
    add_tempo(song.start_pos, bpm)
    start.bpm = bpm
    rebuild_after(later, start)
  else
    if pos - song.start_pos > EPS then add_tempo(song.start_pos, lead_in_bpm(start, pos, bpm)) end
    add_tempo(pos, bpm, num, denom)
    rebuild_after(later, { time = pos, beat = 0, bar = bar_qn(num, denom), bpm = bpm })
  end
  reaper.UpdateTimeline()
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

-- Compasso 1 já marcado na música: posição e BPM, ou nil.
function M.downbeat(song, next_song)
  local db = downbeat_of(song.start_pos, limit(next_song))
  if db then return db.time, db.bpm end
end

-- BPM da música: o do compasso 1 marcado, senão o que vale no início dela.
function M.song_bpm(song, next_song)
  local db = downbeat_of(song.start_pos, limit(next_song))
  return db and db.bpm or (tempo_at(song.start_pos))
end

-- Troca o BPM da música (digitado). Com compasso 1 marcado ele fica no mesmo
-- ponto; sem, só o tempo do início da música muda. Retorna ok, bpm.
function M.set_bpm(song, next_song, bpm)
  if not bpm or bpm < M.MIN_BPM or bpm > M.MAX_BPM then return false, "bad_bpm" end
  bpm = M.round(bpm)
  local db = downbeat_of(song.start_pos, limit(next_song))
  undoable("BPM da música", function()
    place_downbeat(song, next_song, db and db.time or song.start_pos, bpm, not db)
  end)
  return true, bpm
end

-- Ajuste fino: BPM em `d_bpm` e posição do compasso 1 em `d_ms` milissegundos.
-- Sem compasso 1 marcado, só o BPM pode mudar. Retorna ok, bpm, posição do
-- compasso 1 (nil sem ele).
function M.nudge(song, next_song, d_bpm, d_ms)
  local db = downbeat_of(song.start_pos, limit(next_song))
  if not db then
    if (d_ms or 0) ~= 0 then return false, "no_downbeat" end
    local new_bpm = M.round(M.song_bpm(song, next_song) + (d_bpm or 0))
    if new_bpm < M.MIN_BPM or new_bpm > M.MAX_BPM then return false, "out_of_range" end
    undoable("ajuste fino do tempo", function() place_downbeat(song, next_song, song.start_pos, new_bpm, true) end)
    return true, new_bpm
  end
  local new_time = db.time + (d_ms or 0) / 1000
  local new_bpm = M.round(db.bpm + (d_bpm or 0))
  if new_time < song.start_pos - EPS or new_time >= limit(next_song) - EPS or new_bpm < M.MIN_BPM or new_bpm > M.MAX_BPM then
    return false, "out_of_range"
  end
  undoable("ajuste fino do tempo", function() place_downbeat(song, next_song, new_time, new_bpm) end)
  return true, new_bpm, new_time
end

return M
