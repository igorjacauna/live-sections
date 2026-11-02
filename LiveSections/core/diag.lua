-- Medição do ciclo da instância, para achar travadas no REAPER do usuário.
--
-- O loop marca o começo e o fim de cada ciclo; a tela de Configurações
-- mostra a média dos últimos WINDOW_S segundos.
--
-- M.cycle(started, finished)   tempos de reaper.time_precise() do ciclo
-- M.events(n)                  mensagens MIDI lidas no ciclo
-- M.stats(now) -> { fps, avg_ms, max_ms, midi_per_s }?   nil sem medição

local M = {}

local WINDOW_S = 2.0

local samples = {}   -- { at, ms, events }
local pending_events = 0

function M.events(n) pending_events = pending_events + n end

function M.cycle(started, finished)
  samples[#samples + 1] = { at = finished, ms = (finished - started) * 1000, events = pending_events }
  pending_events = 0
  while samples[1] and finished - samples[1].at > WINDOW_S do table.remove(samples, 1) end
end

function M.stats(now)
  local n = #samples
  if n < 2 or now - samples[n].at > WINDOW_S then return nil end
  local span = samples[n].at - samples[1].at
  if span <= 0 then return nil end
  local sum, max, events = 0, 0, 0
  for _, s in ipairs(samples) do
    sum, events = sum + s.ms, events + s.events
    if s.ms > max then max = s.ms end
  end
  return { fps = (n - 1) / span, avg_ms = sum / n, max_ms = max, midi_per_s = events / span }
end

function M.reset() samples, pending_events = {}, 0 end

return M
