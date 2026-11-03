-- Spike 09: que posição o REAPER informa logo depois do play?
--
-- Com o cursor exatamente no marcador "SONG:" da 2ª música, o Live Sections
-- mostrava a 1ª por um instante e a 2ª não tocava; com o áudio movido um
-- compasso para frente (marcadores no lugar), tocava. Suspeita: nos primeiros
-- ciclos, GetPlayPosition2 vem um pouco ANTES do cursor (ainda na 1ª música).
--
-- Rode com o Live Sections FECHADO e o cursor no marcador da 2ª música. O
-- script dá play, registra a posição nos primeiros ciclos, para e devolve o
-- cursor. Depois, mova o cursor 1 compasso para dentro da música e rode de
-- novo, para comparar.

local CYCLES = 25

local function out(s) reaper.ShowConsoleMsg(tostring(s) .. "\n") end

local function config(name)
  if not reaper.get_config_var_string then return "?" end
  local ok, v = reaper.get_config_var_string(name)
  return ok and v or "?"
end

local cursor = reaper.GetCursorPosition()
out(string.format("\n== Spike 09 · REAPER %s ==", reaper.GetAppVersion()))
out(string.format("cursor: %.6f s (%s)", cursor, reaper.format_timestr_pos(cursor, "", 2)))

-- marcador SONG: mais perto do cursor
local best, i = nil, 0
while true do
  local ret, isrgn, pos, rgnend, name = reaper.EnumProjectMarkers3(0, i)
  if ret == 0 then break end
  if not isrgn and name:match("^SONG:") and (not best or math.abs(pos - cursor) < math.abs(best.pos - cursor)) then
    best = { pos = pos, name = name }
  end
  if isrgn and math.abs(rgnend - cursor) < 0.01 then
    out(string.format("região termina no cursor: %q (fim %.6f, diferença %.3f ms)", name, rgnend, (rgnend - cursor) * 1000))
  end
  i = i + 1
end
if best then
  out(string.format("marcador mais perto: %q em %.6f s (cursor - marcador = %.3f ms)", best.name, best.pos, (cursor - best.pos) * 1000))
end
local ts_a, ts_b = reaper.GetSet_LoopTimeRange2(0, false, true, 0, 0, false)
out(string.format("loop/time selection: %.3f – %.3f · repeat %d", ts_a, ts_b, reaper.GetSetRepeat(-1)))
out("pre-roll (preroll / prerollmeas): " .. config("preroll") .. " / " .. config("prerollmeas"))

local rows, n, t0 = {}, 0, reaper.time_precise()
reaper.OnPlayButton()

local function finish()
  reaper.OnStopButton()
  reaper.SetEditCurPos(cursor, false, false)
  out("ciclo  tempo   estado  PlayPosition2 (dif. ms)   PlayPosition (dif. ms)")
  for _, r in ipairs(rows) do out(r) end
  local before = 0
  for _, r in ipairs(rows) do if r:find("ANTES") then before = before + 1 end end
  out(before > 0 and string.format("=> %d ciclo(s) com a posição ANTES do cursor", before)
    or "=> a posição nunca ficou antes do cursor")
  out("Mande este console.")
end

local function tick()
  n = n + 1
  local p2, p1 = reaper.GetPlayPosition2(), reaper.GetPlayPosition()
  local d2, d1 = (p2 - cursor) * 1000, (p1 - cursor) * 1000
  rows[#rows + 1] = string.format("%5d  %5.0f ms  %d  %.6f (%+.2f)%s   %.6f (%+.2f)", n,
    (reaper.time_precise() - t0) * 1000, reaper.GetPlayState(), p2, d2, d2 < -0.001 and " ANTES" or "", p1, d1)
  if n >= CYCLES then return finish() end
  reaper.defer(tick)
end

reaper.defer(tick)
