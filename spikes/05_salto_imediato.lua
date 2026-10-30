-- Spike 05: com o smooth seek ligado, dá para saltar na hora (modos batida e imediato)?
--
-- Pré-requisito: um projeto com áudio contínuo (uma música ou stems).
-- O script liga o smooth seek, desliga o repeat e cria uma região de teste
-- se o projeto não tiver nenhuma. Ao fechar, restaura o smooth seek e o repeat.
--
-- Teclas (com a janela do spike em foco e o REAPER tocando):
--   1  seek comum, sem mexer no smooth seek (controle: deve esperar o compasso)
--   2  desliga o smooth seek, faz o seek e religa na mesma hora (o que o Live Sections faz hoje)
--   3  desliga o smooth seek, faz o seek e religa no ciclo seguinte do script
--   Esc sai
--
-- Todo salto vai para o início da 1ª região. O console mostra quanto tempo o
-- salto levou e se ele esperou a virada do compasso. Escute também se há
-- estalo no ponto do salto.

local SMOOTH_SEEK = 40390
local JUMP_THRESHOLD = 0.05 -- segundos de discrepância para considerar salto
local IMMEDIATE_MS = 100     -- abaixo disso, conta como salto imediato

local function out(s) reaper.ShowConsoleMsg(tostring(s) .. "\n") end
local function bars(pos) return reaper.format_timestr_pos(pos, "", 2) end

local function next_measure_time(pos)
  local _, measure = reaper.TimeMap2_timeToBeats(0, pos)
  return reaper.TimeMap2_beatsToTime(0, 0, measure + 1)
end

local function measure_start(measure) return reaper.TimeMap2_beatsToTime(0, 0, measure) end

local function first_region()
  local i = 0
  while true do
    local ret, isrgn, pos, _, name = reaper.EnumProjectMarkers3(0, i)
    if ret == 0 then return nil end
    if isrgn then return { pos = pos, name = name } end
    i = i + 1
  end
end

local function smooth_on() return reaper.GetToggleCommandState(SMOOTH_SEEK) == 1 end

local VARIANTS = {
  ["1"] = "1 · seek comum (controle)",
  ["2"] = "2 · desliga, seek, religa na hora",
  ["3"] = "3 · desliga, seek, religa no ciclo seguinte",
}

local state = {
  pending = nil,          -- { variant, target, requested_at, boundary_ms }
  reenable_next = false,
  last_pos = nil,
  last_t = nil,
  status = "Dê play e aperte 1, 2 ou 3",
}

local function request(variant)
  if reaper.GetPlayState() & 1 ~= 1 then state.status = "Dê play antes"; return end
  local rgn = first_region()
  local pos = reaper.GetPlayPosition2()
  local now = reaper.time_precise()
  local boundary = next_measure_time(pos)
  local rate = reaper.Master_GetPlayRate(0)

  if variant ~= "1" then reaper.Main_OnCommand(SMOOTH_SEEK, 0) end
  reaper.SetEditCurPos(rgn.pos, false, true)
  if variant == "2" then reaper.Main_OnCommand(SMOOTH_SEEK, 0) end
  if variant == "3" then state.reenable_next = true end

  state.pending = { variant = variant, target = rgn.pos, requested_at = now, boundary_ms = (boundary - pos) / rate * 1000 }
  out(string.format("[%s] pedido em %s -> %s | virada do compasso em %.0f ms",
    VARIANTS[variant], bars(pos), bars(rgn.pos), state.pending.boundary_ms))
  state.status = "Aguardando o salto…"
end

local function monitor()
  if state.reenable_next then
    state.reenable_next = false
    reaper.Main_OnCommand(SMOOTH_SEEK, 0)
  end
  local playing = reaper.GetPlayState() & 1 == 1
  local t = reaper.time_precise()
  local pos = reaper.GetPlayPosition2()
  if playing and state.last_pos then
    local expected = state.last_pos + (t - state.last_t) * reaper.Master_GetPlayRate(0)
    if math.abs(pos - expected) > JUMP_THRESHOLD and state.pending then
      local p = state.pending
      local ms = (t - p.requested_at) * 1000
      local verdict = ms < IMMEDIATE_MS and "IMEDIATO" or (math.abs(ms - p.boundary_ms) < IMMEDIATE_MS and "ESPEROU O COMPASSO" or "ATRASADO")
      out(string.format("[%s] salto depois de %.0f ms -> %s | smooth seek agora: %s",
        VARIANTS[p.variant], ms, verdict, smooth_on() and "ligado" or "DESLIGADO"))
      state.status = string.format("Último: %s em %.0f ms (%s)", VARIANTS[p.variant], ms, verdict)
      state.pending = nil
    end
  end
  state.last_pos = playing and pos or nil
  state.last_t = t
end

local function draw()
  gfx.set(0.1, 0.1, 0.12); gfx.rect(0, 0, gfx.w, gfx.h, 1)
  gfx.set(0.9, 0.9, 0.9)
  gfx.x, gfx.y = 12, 12
  gfx.drawstr("Posição: " .. bars(reaper.GetPlayPosition2()) .. "   smooth seek: " .. (smooth_on() and "ligado" or "DESLIGADO"))
  gfx.x, gfx.y = 12, 40
  gfx.drawstr(state.status)
  gfx.x, gfx.y = 12, 80
  gfx.drawstr("1 = seek comum   2 = religa na hora   3 = religa no ciclo seguinte   Esc = sair")
  gfx.update()
end

local function loop()
  local ch = gfx.getchar()
  if ch < 0 or ch == 27 then return end
  local key = ch > 0 and ch < 256 and string.char(ch) or nil
  if key and VARIANTS[key] then request(key) end
  monitor()
  draw()
  reaper.defer(loop)
end

local function setup()
  local restore = {}
  if not smooth_on() then
    reaper.Main_OnCommand(SMOOTH_SEEK, 0)
    restore.smooth = true
  end
  if reaper.GetSetRepeat(-1) == 1 then
    reaper.GetSetRepeat(0)
    restore.rpt = true
  end
  if not first_region() then
    reaper.Undo_BeginBlock()
    reaper.AddProjectMarker2(0, true, measure_start(0), measure_start(4), "Alvo (teste)", -1, 0)
    reaper.Undo_EndBlock("Spike 05: região de teste", -1)
    out("Criada a região de teste \"Alvo\" (compassos 1-4). Ctrl+Z remove.")
  end
  local _, meas = reaper.get_config_var_string("smoothseekmeas")
  out(string.format("Smooth seek ligado (smoothseekmeas=%s). Repeat desligado. Os saltos vão para a 1ª região.", meas))
  reaper.atexit(function()
    -- Garante o estado original mesmo se a variante 3 ficou no meio.
    local want_on = not restore.smooth
    if smooth_on() ~= want_on then reaper.Main_OnCommand(SMOOTH_SEEK, 0) end
    if restore.rpt then reaper.GetSetRepeat(1) end
  end)
end

reaper.ClearConsole()
setup()
gfx.init("Spike 05: salto imediato", 620, 120)
gfx.setfont(1, "Arial", 15)
loop()
