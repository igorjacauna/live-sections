-- Medição do ciclo da instância, para achar travadas no REAPER do usuário.
--
-- O loop marca o começo e o fim de cada ciclo; a tela de Configurações
-- mostra a média dos últimos WINDOW_S segundos e os últimos engasgos.
--
-- Engasgo: um intervalo entre o começo de dois ciclos maior que HITCH_MS
-- (normal: 16–33 ms), ou uma falha de áudio que o REAPER registrou
-- (GetUnderrunTime: áudio = o buffer da placa esvaziou; mídia = leitura de
-- disco atrasou), mesmo sem a tela travar. O registro diz quanto disso foi o script (o ciclo
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
local HITCH_MS = 70
local RECENT_S = 0.5       -- notas dos ciclos deste intervalo antes da falha
local MAX_HITCHES = 30

local samples = {}   -- { at, ms, events }
local pending_events = 0
local parts, notes = {}, {}
local prev = nil     -- { started, ms, parts, notes }
local recent = {}    -- { { at, notes } } dos últimos RECENT_S
local xrun = nil     -- { audio, media } últimos carimbos vistos
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

local function recent_notes()
  local out = {}
  for _, c in ipairs(recent) do
    for what, n in pairs(c.notes) do out[what] = (out[what] or 0) + n end
  end
  return out
end

local function record(h)
  local ok, info = pcall(function() return info_fn and info_fn() or nil end)
  h.at, h.info = os.date("%H:%M:%S"), ok and info or nil
  hitches[#hitches + 1] = h
  if #hitches > MAX_HITCHES then table.remove(hitches, 1) end
end

-- Falha de áudio nova desde o ciclo anterior: "áudio", "mídia" ou nil.
local function new_xrun()
  local ok, get = pcall(function() return reaper.GetUnderrunTime end)
  if not ok or not get then return nil end
  local audio, media = get()
  local seen = xrun
  xrun = { audio = audio or 0, media = media or 0 }
  if not seen then return nil end
  if xrun.audio ~= seen.audio and xrun.audio > 0 then return "áudio" end
  if xrun.media ~= seen.media and xrun.media > 0 then return "mídia" end
end

function M.cycle(started, finished)
  local ms = (finished - started) * 1000
  samples[#samples + 1] = { at = finished, ms = ms, events = pending_events }
  pending_events = 0
  while samples[1] and finished - samples[1].at > WINDOW_S do table.remove(samples, 1) end

  local gap = prev and (started - prev.started) * 1000
  local kind = new_xrun()
  if kind or (gap and gap > HITCH_MS) then
    record({
      kind = kind and ("falha de " .. kind) or "pausa",
      gap_ms = gap or 0, script_ms = prev and prev.ms or 0,
      parts = top_parts(prev and prev.parts or {}, 4), notes = recent_notes(),
    })
  end
  recent[#recent + 1] = { at = started, notes = notes }
  while recent[1] and started - recent[1].at > RECENT_S do table.remove(recent, 1) end
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
  return string.format("%s  %s · ciclo %.0f ms · script %.0f ms (%s)%s%s", h.at, h.kind or "pausa", h.gap_ms, h.script_ms,
    table.concat(ps, ", "), #ns > 0 and " · mexeu: " .. table.concat(ns, ", ") or "",
    h.info and " · " .. h.info or "")
end

function M.report()
  local out = { string.format("Live Sections %s · REAPER %s · %s", require("version"), reaper.GetAppVersion(), os.date("%Y-%m-%d")) }
  for _, h in ipairs(hitches) do out[#out + 1] = M.line(h) end
  if #hitches == 0 then out[#out + 1] = "Nenhum engasgo registrado." end
  return table.concat(out, "\n")
end

function M.reset() samples, pending_events, parts, notes, prev, hitches, recent = {}, 0, {}, {}, nil, {}, {} end

return M
