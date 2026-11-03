-- Ações de performance: o que a tela e o MIDI disparam.
--
-- Liga o modelo (músicas e seções), a fila e o transporte. Chame M.tick() a
-- cada ciclo do defer; as ações podem ser chamadas a qualquer momento.

local model = require("core.project_model")
local queue = require("core.queue")
local quantize = require("core.quantize")
local transport = require("core.transport")

local M = {}

local PROJ = 0
local SONG_END_MARGIN = 0.25   -- s: parada a menos disso do fim conta como fim da música
local START_WINDOW_S = 1.0     -- s: depois do play, posições impossíveis valem o ponto de partida
local START_AHEAD_S = 0.25     -- s: folga à frente do tempo que já passou desde o play

local state = {
  quantize = "bar",
  tolerance_s = 0.03,
  loop_section = nil,      -- seção presa em loop
  song = nil,              -- música atual (onde a reprodução está)
  was_playing = false,
  last_pos = 0,
  play_from = nil,         -- onde o play começou (primeiro segundo da reprodução)
  play_at = 0,             -- quando (time_precise)
}

-- ------------------------------------------------------------------ estado

function M.init(opts)
  opts = opts or {}
  state.quantize = opts.quantize or "bar"
  state.tolerance_s = (opts.tolerance_ms or 30) / 1000
  state.loop_section, state.song = nil, nil
  -- já tocando ao abrir o script não conta como play (a proteção do 1º
  -- segundo usaria o cursor, longe de onde a reprodução está)
  state.was_playing, state.last_pos, state.play_from = transport.is_playing(), transport.position(), nil
  queue.cancel()
  model.refresh(PROJ)
  return transport.ensure_setup()
end

function M.quantize() return state.quantize end
function M.tolerance_ms() return state.tolerance_s * 1000 end
function M.set_tolerance(ms) state.tolerance_s = ms / 1000 end
function M.loop_section() return state.loop_section end
function M.current_song() return state.song end
function M.queued() return queue.current() end

function M.set_quantize(mode)
  for _, m in ipairs(quantize.MODES) do
    if m == mode then state.quantize = mode; return true end
  end
  return false
end

-- Avança (dir = 1) ou volta (dir = -1) nos valores de quantize, em ciclo.
function M.cycle_quantize(dir)
  local modes = quantize.MODES
  for i, m in ipairs(modes) do
    if m == state.quantize then
      state.quantize = modes[(i - 1 + (dir or 1)) % #modes + 1]
      return state.quantize
    end
  end
end

-- ------------------------------------------------------------------ apoio

-- Posição de reprodução. Logo depois do play, o REAPER pode informar uma
-- posição impossível (spike 09): 0,01 ms antes do cursor (arredondamento) ou,
-- no primeiro ciclo, onde a reprodução anterior parou. Com o cursor no início
-- exato de uma música, isso caía na anterior: o motor trocava de música,
-- marcava o fim dela como trecho de parada, o REAPER parava ali e o motor
-- voltava para a música atual, em ciclo. No primeiro segundo, uma posição
-- antes do ponto de partida ou à frente do tempo que já passou vale o ponto
-- de partida.
local function play_pos()
  local pos = transport.position()
  local from = state.play_from
  if from and transport.is_playing() then
    local elapsed = reaper.time_precise() - state.play_at
    if elapsed > START_WINDOW_S then
      state.play_from = nil
    elseif pos < from or pos > from + elapsed + START_AHEAD_S then
      return from
    end
  end
  return pos
end

local function where()
  local pos = play_pos()
  local song, section = model.song_at(pos)
  return pos, song or state.song, section
end

-- O modelo é refeito a cada mudança no projeto: compare músicas pelo id.
local function same_song(a, b) return a ~= nil and b ~= nil and a.id == b.id end

local function enter_song(song)
  if not song then return end
  if not same_song(song, state.song) then transport.arm_song_end(song) end
  state.song = song
end

local function undo_hand_off(entry)
  if entry and entry.handed_to_reaper then transport.cancel_hand_off(entry.jump_pos) end
end

local function stop_loop(song)
  if state.loop_section then
    state.loop_section = nil
    transport.set_loop(nil, false, song)
  end
end

local function target_start(target)
  if target.kind == "section" then return target.ref.start_pos, target.ref.region_idx end
  local first = target.ref.sections[1]
  if first then return first.start_pos, first.region_idx end
  return target.ref.start_pos, nil
end

-- Coloca o alvo na fila (ou salta na hora com o transporte parado).
local function launch(target)
  local pos, song, section = where()
  if not transport.is_playing() then
    queue.cancel()
    stop_loop(song)
    local start = target.at or target_start(target)
    if target.kind == "song" then
      transport.move_cursor(start)
    else
      transport.start_at(start)
    end
    enter_song(model.song_at(start))
    return "started"
  end
  stop_loop(song)
  local status, previous = queue.enqueue(target, state.quantize, pos,
    { proj = PROJ, song = song, section = section }, state.tolerance_s)
  undo_hand_off(previous)
  return status
end

-- ------------------------------------------------------------------ ações

-- Dispara a seção `section` da música atual. Com o transporte parado, `at`
-- (opcional, dentro da seção) começa dali em vez do início dela.
function M.trigger_section(section, at)
  return launch({ kind = "section", ref = section, at = at })
end

-- Dispara a N-ésima seção da música atual. Slot sem seção é ignorado.
function M.trigger_slot(n)
  local _, song = where()
  local section = song and song.sections[n]
  if not section then return nil end
  return M.trigger_section(section)
end

local function step_section(dir)
  local pos, song, section = where()
  if not song then return nil end
  local list = song.sections
  if section then
    local nxt = list[section.slot + dir]
    return nxt and M.trigger_section(nxt) or nil
  end
  -- num trecho sem seção: a próxima que começa depois, ou a última que terminou antes
  local pick
  for _, s in ipairs(list) do
    if dir > 0 and s.start_pos > pos then pick = s; break end
    if dir < 0 and s.end_pos <= pos then pick = s end
  end
  return pick and M.trigger_section(pick) or nil
end

function M.next_section() return step_section(1) end
function M.prev_section() return step_section(-1) end

-- Vai para a música N (1-based), caindo na 1ª seção dela.
function M.goto_song(n)
  local song = model.songs()[n]
  if not song then return nil end
  return launch({ kind = "song", ref = song })
end

local function song_index(song)
  for i, s in ipairs(model.songs()) do
    if same_song(s, song) then return i end
  end
end

function M.next_song()
  local _, song = where()
  return M.goto_song((song_index(song) or 0) + 1)
end

function M.prev_song()
  local _, song = where()
  return M.goto_song((song_index(song) or 2) - 1)
end

-- Liga/desliga o loop da seção atual. Sem seção na posição, não liga.
function M.toggle_loop()
  local _, song, section = where()
  if state.loop_section then
    stop_loop(song)
    return false
  end
  if not section then return nil, "no_section" end
  undo_hand_off(queue.cancel())
  state.loop_section = section
  transport.set_loop(section, true, song)
  return true
end

function M.cancel()
  local entry = queue.cancel()
  undo_hand_off(entry)
  return entry ~= nil
end

function M.stop()
  if not transport.is_playing() then return "stopped" end
  M.cancel()
  stop_loop(state.song)
  transport.stop()
  return "stopped"
end

-- Tocando, não faz nada (o Play do REAPER voltaria ao cursor).
function M.play()
  if not transport.is_playing() then transport.play() end
  return "playing"
end

function M.play_stop()
  if transport.is_playing() then return M.stop() end
  return M.play()
end

-- Para tudo, solta as notas presas, esvazia a fila e volta o cursor ao
-- início da música atual.
function M.panic()
  local _, song = where()
  queue.cancel()
  stop_loop(song)
  transport.stop()
  transport.all_notes_off()
  if song then transport.move_cursor(song.start_pos) end
end

-- ------------------------------------------------------------------ ciclo

local function next_song_after(song)
  local i = song_index(song)
  return i and model.songs()[i + 1] or nil
end

-- Chamado a cada ciclo do defer. Retorna a ação da fila executada (ou nil).
function M.tick()
  model.refresh(PROJ)
  local playing = transport.is_playing()
  if playing and not state.was_playing then state.play_from, state.play_at = transport.cursor(), reaper.time_precise() end
  if not playing then state.play_from = nil end
  local pos = play_pos()

  -- Fim da música: o motor parou no fim dela; o cursor vai para a próxima.
  if state.was_playing and not playing and state.song and state.last_pos >= state.song.end_pos - SONG_END_MARGIN then
    queue.cancel()
    state.loop_section = nil
    local nxt = next_song_after(state.song)
    if nxt then
      transport.move_cursor(nxt.start_pos)
      enter_song(nxt)
    end
    state.was_playing = false
    return nil
  end
  state.was_playing, state.last_pos = playing, pos

  if not playing then
    enter_song(model.song_at(pos))
    return nil
  end

  local action = queue.tick(pos, model.songs())
  if action then
    if action.type == "hand_off" then
      local start, region_idx = target_start(action.target)
      transport.hand_off(start, action.mode, region_idx)
    elseif action.type == "jump_now" then
      local start = target_start(action.target)
      transport.jump_now(start)
      enter_song(model.song_at(start))
    elseif action.type == "cancelled" then
      undo_hand_off(action.entry)
    end
  end
  enter_song(model.song_at(pos))
  return action
end

return M
