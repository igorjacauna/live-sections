-- Medição do ciclo da instância, para achar travadas no REAPER do usuário.
--
-- O loop marca o começo e o fim de cada ciclo; a tela de Configurações
-- mostra a média dos últimos WINDOW_S segundos e os últimos engasgos.
--
-- Engasgo: um intervalo entre o começo de dois ciclos maior que HITCH_MS
-- (normal: 16–33 ms). O registro diz quanto disso foi o script (o ciclo
-- anterior, com o tempo de cada parte) e o que o ciclo anterior mexeu no
-- REAPER (notas): o REAPER faz parte do trabalho dessas mudanças depois que o
-- script devolve o controle (ponto de undo, estado do FX), fora do tempo
-- medido do script.
--
-- M.cycle(started, finished)   tempos de reaper.time_precise() do ciclo
-- M.events(n)                  mensagens MIDI lidas no ciclo
-- M.part(name, started)        soma o tempo desde `started` à parte `name`
-- M.note(what)                 o ciclo mexeu no REAPER ("FX param", "bypass"…)
-- M.set_info(fn)               fn() -> texto do estado (modo, posição…)
-- M.stats(now) -> { fps, avg_ms, max_ms, midi_per_s }?   nil sem medição
-- M.hitches() -> { { at, gap_ms, script_ms, parts, notes, info } } mais novo por último
-- M.report() -> texto para copiar

local M = {}

local WINDOW_S = 2.0
local HITCH_MS = 150
local MAX_HITCHES = 30

local samples = {}   -- { at, ms, events }
local pending_events = 0
local parts, notes = {}, {}
local prev = nil     -- { started, ms, parts, notes }
local hitches = {}
local info_fn = nil

function M.events(n) pending_events = pending_events + n end

function M.part(name, started)
  parts[name] = (parts[name] or 0) + (reaper.time_precise() - started) * 1000
end

function M.note(what) notes[what] = (notes[what] or 0) + 1 end

function M.set_info(fn) info_fn = fn end

local function top_parts(list, n)
  local out = {}
  for name, ms in pairs(list) do out[#out + 1] = { name = name, ms = ms } end
  table.sort(out, function(a, b) return a.ms > b.ms end)
  while #out > n do table.remove(out) end
  return out
end

function M.cycle(started, finished)
  local ms = (finished - started) * 1000
  samples[#samples + 1] = { at = finished, ms = ms, events = pending_events }
  pending_events = 0
  while samples[1] and finished - samples[1].at > WINDOW_S do table.remove(samples, 1) end

  if prev then
    local gap = (started - prev.started) * 1000
    if gap > HITCH_MS then
      local ok, info = pcall(function() return info_fn and info_fn() or nil end)
      hitches[#hitches + 1] = {
        at = os.date("%H:%M:%S"), gap_ms = gap, script_ms = prev.ms,
        parts = top_parts(prev.parts, 4), notes = prev.notes, info = ok and info or nil,
      }
      if #hitches > MAX_HITCHES then table.remove(hitches, 1) end
    end
  end
  prev = { started = started, ms = ms, parts = parts, notes = notes }
  parts, notes = {}, {}
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

function M.hitches() return hitches end

-- Uma linha por engasgo: hora, pausa, quanto foi do script, partes e notas.
function M.line(h)
  local ps = {}
  for _, p in ipairs(h.parts) do ps[#ps + 1] = string.format("%s %.0f", p.name, p.ms) end
  local ns = {}
  for what, n in pairs(h.notes) do ns[#ns + 1] = n > 1 and (what .. " x" .. n) or what end
  table.sort(ns)
  return string.format("%s  pausa %.0f ms · script %.0f ms (%s)%s%s", h.at, h.gap_ms, h.script_ms,
    table.concat(ps, ", "), #ns > 0 and " · mexeu: " .. table.concat(ns, ", ") or "",
    h.info and " · " .. h.info or "")
end

function M.report()
  local out = { string.format("Live Sections %s · REAPER %s · %s", require("version"), reaper.GetAppVersion(), os.date("%Y-%m-%d")) }
  for _, h in ipairs(hitches) do out[#out + 1] = M.line(h) end
  if #hitches == 0 then out[#out + 1] = "Nenhum engasgo registrado." end
  return table.concat(out, "\n")
end

function M.reset() samples, pending_events, parts, notes, prev, hitches = {}, 0, {}, {}, nil, {} end

return M
