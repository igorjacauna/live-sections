-- Spike 02: o cancelamento de um salto já entregue ao smooth seek soa limpo?
--
-- Pré-requisito: um projeto com áudio contínuo (uma música ou stems).
-- O próprio script liga o smooth seek, desliga o repeat e cria duas regiões de
-- teste (A e B) se o projeto não tiver regiões. Ao fechar, ele restaura o
-- smooth seek e o repeat.
--
-- Teclas (com a janela do spike em foco):
--   1  enfileira salto para o início da 1ª região do projeto (SetEditCurPos + smooth seek)
--   2  enfileira salto para a próxima região via GoToRegion (para ver se espera compasso ou fim de região)
--   C  CANCELA: smooth seek para a própria virada do compasso
--   Esc sai
--
-- O console registra todo salto detectado na posição de reprodução. Se o
-- cancelamento funcionar, a virada aparece como "virada sem salto". Escute
-- também se há estalo ou falha no áudio nesse ponto.

local JUMP_THRESHOLD = 0.05 -- segundos de discrepância para considerar salto

local function out(s) reaper.ShowConsoleMsg(tostring(s) .. "\n") end
local function bars(pos) return reaper.format_timestr_pos(pos, "", 2) end

local function next_measure_time(pos)
  local _, measure = reaper.TimeMap2_timeToBeats(0, pos)
  return reaper.TimeMap2_beatsToTime(0, 0, measure + 1)
end

local function regions()
  local list, i = {}, 0
  while true do
    local ret, isrgn, pos, rgnend, name, idx = reaper.EnumProjectMarkers3(0, i)
    if ret == 0 then break end
    if isrgn then list[#list + 1] = { pos = pos, rgnend = rgnend, name = name, idx = idx } end
    i = i + 1
  end
  table.sort(list, function(a, b) return a.pos < b.pos end)
  return list
end

local state = {
  pending = nil,     -- { kind, target, boundary, requested_at }
  last_pos = nil,
  last_t = nil,
  status = "Dê play e aperte 1, 2 ou C",
}

local function queue_first_region()
  local rgns = regions()
  if #rgns == 0 then state.status = "Projeto sem regiões"; return end
  local pos = reaper.GetPlayPosition2()
  local boundary = next_measure_time(pos)
  reaper.SetEditCurPos(rgns[1].pos, false, true)
  state.pending = { kind = "SetEditCurPos", target = rgns[1].pos, boundary = boundary }
  out(string.format("[fila] SetEditCurPos -> %s (%s) | virada esperada em %s", bars(rgns[1].pos), rgns[1].name, bars(boundary)))
  state.status = "Salto na fila: aperte C para cancelar"
end

local function queue_next_region()
  local rgns = regions()
  local pos = reaper.GetPlayPosition2()
  local target
  for n, r in ipairs(rgns) do
    if r.pos > pos then target = { r = r, order = n }; break end
  end
  if not target then state.status = "Nenhuma região depois da posição atual"; return end
  local boundary = next_measure_time(pos)
  reaper.GoToRegion(0, target.order, true)
  state.pending = { kind = "GoToRegion", target = target.r.pos, boundary = boundary }
  out(string.format("[fila] GoToRegion(%d) -> %s (%s) | próxima virada de compasso em %s",
    target.order, bars(target.r.pos), target.r.name, bars(boundary)))
  state.status = "GoToRegion na fila: observe quando o salto acontece"
end

local function cancel()
  local pos = reaper.GetPlayPosition2()
  local boundary = next_measure_time(pos)
  reaper.SetEditCurPos(boundary, false, true)
  out(string.format("[cancelar] smooth seek para a própria virada %s (pos atual %s)", bars(boundary), bars(pos)))
  if state.pending then state.pending.cancelled_to = boundary end
  state.status = "Cancelado: a música deve seguir sem emenda"
end

local function monitor()
  local playing = reaper.GetPlayState() & 1 == 1
  local t = reaper.time_precise()
  local pos = reaper.GetPlayPosition2()
  if playing and state.last_pos then
    local rate = reaper.Master_GetPlayRate(0)
    local expected = state.last_pos + (t - state.last_t) * rate
    local diff = pos - expected
    if math.abs(diff) > JUMP_THRESHOLD then
      out(string.format("[SALTO] %s -> %s (desvio %.3fs)", bars(state.last_pos), bars(pos), diff))
      state.pending = nil
    elseif state.pending and state.pending.cancelled_to and pos >= state.pending.cancelled_to then
      out(string.format("[ok] virada %s passou sem salto", bars(state.pending.cancelled_to)))
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
  gfx.drawstr("Posição: " .. bars(reaper.GetPlayPosition2()))
  gfx.x, gfx.y = 12, 40
  gfx.drawstr(state.status)
  gfx.x, gfx.y = 12, 80
  gfx.drawstr("1 = fila p/ 1ª região   2 = GoToRegion próxima   C = cancelar   Esc = sair")
  gfx.update()
end

local function loop()
  local ch = gfx.getchar()
  if ch < 0 or ch == 27 then return end
  if ch == string.byte("1") then queue_first_region()
  elseif ch == string.byte("2") then queue_next_region()
  elseif ch == string.byte("c") or ch == string.byte("C") then cancel() end
  monitor()
  draw()
  reaper.defer(loop)
end

local SMOOTH_SEEK_TOGGLE = 40390

local function measure_start(measure) return reaper.TimeMap2_beatsToTime(0, 0, measure) end

local function setup()
  local restore = {}
  if reaper.GetToggleCommandState(SMOOTH_SEEK_TOGGLE) ~= 1 then
    reaper.Main_OnCommand(SMOOTH_SEEK_TOGGLE, 0)
    restore.smooth = true
  end
  if reaper.GetSetRepeat(-1) == 1 then
    reaper.GetSetRepeat(0)
    restore.rpt = true
  end
  if #regions() < 2 then
    reaper.Undo_BeginBlock()
    reaper.AddProjectMarker2(0, true, measure_start(0), measure_start(4), "A (teste)", -1, 0)
    reaper.AddProjectMarker2(0, true, measure_start(8), measure_start(12), "B (teste)", -1, 0)
    reaper.Undo_EndBlock("Spike 02: regiões de teste", -1)
    out("Criadas regiões de teste: A (compassos 1-4) e B (compassos 9-12). Ctrl+Z remove.")
  end
  local _, smooth = reaper.get_config_var_string("smoothseek")
  local _, meas = reaper.get_config_var_string("smoothseekmeas")
  out(string.format("Smooth seek ligado (smoothseek=%s, smoothseekmeas=%s). Repeat desligado.", smooth, meas))
  reaper.atexit(function()
    if restore.smooth then reaper.Main_OnCommand(SMOOTH_SEEK_TOGGLE, 0) end
    if restore.rpt then reaper.GetSetRepeat(1) end
  end)
end

reaper.ClearConsole()
setup()
gfx.init("Spike 02: cancelar salto", 560, 120)
gfx.setfont(1, "Arial", 15)
loop()
