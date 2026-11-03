-- Todas as chamadas que mexem no transporte do REAPER.
--
-- O salto é feito pelo motor de áudio: smooth seek (1 compasso) com
-- SetEditCurPos nos modos de compasso, GoToRegion no modo "fim da seção".
-- Para cancelar um salto já entregue, um seek para a própria virada substitui
-- o pendente (validado no spike 02). A parada no fim da música também é do
-- motor: loop points na música, repeat desligado e a action 41834 ligada.

local M = {}

M.SMOOTH_SEEK = 40390          -- Options: Toggle smooth seek
M.STOP_AT_LOOP_END = 41834     -- Transport: stop at end of loop if repeat is disabled
M.ALL_NOTES_OFF = 40345        -- Send all-notes-off to all MIDI outputs/plug-ins

local PROJ = 0

local restore = nil
local warnings = {}

local function ensure_toggle(cmd)
  if reaper.GetToggleCommandState(cmd) ~= 1 then
    reaper.Main_OnCommand(cmd, 0)
    return true
  end
  return false
end

-- Liga o que o transporte precisa e registra a restauração na saída do script.
-- Retorna a lista de avisos (vazia quando está tudo certo).
function M.ensure_setup()
  if not restore then
    restore = { [M.SMOOTH_SEEK] = false, [M.STOP_AT_LOOP_END] = false, repeat_state = reaper.GetSetRepeat(-1) }
    reaper.atexit(M.restore)
  end
  if ensure_toggle(M.SMOOTH_SEEK) then restore[M.SMOOTH_SEEK] = true end
  if ensure_toggle(M.STOP_AT_LOOP_END) then restore[M.STOP_AT_LOOP_END] = true end

  warnings = {}
  local _, meas = reaper.get_config_var_string("smoothseekmeas")
  if tonumber(meas) ~= 1 then
    warnings[#warnings + 1] = {
      id = "smoothseekmeas",
      text = string.format("O smooth seek está em %s compassos. Os saltos precisam de 1 compasso: ajuste em Preferences → Audio → Playback → Smooth seek.", meas ~= "" and meas or "?"),
    }
  end
  return warnings
end

function M.warnings() return warnings end

-- Desfaz o que ensure_setup mudou.
function M.restore()
  if not restore then return end
  for _, cmd in ipairs({ M.SMOOTH_SEEK, M.STOP_AT_LOOP_END }) do
    if restore[cmd] and reaper.GetToggleCommandState(cmd) == 1 then reaper.Main_OnCommand(cmd, 0) end
  end
  reaper.GetSetRepeat(restore.repeat_state)
  restore = nil
end

-- Posição da região na ordem da timeline (1-based), como o GoToRegion espera.
local function timeline_order(region_idx)
  local order, i = 0, 0
  while true do
    local ret, isrgn, _, _, _, idx = reaper.EnumProjectMarkers3(PROJ, i)
    if ret == 0 then return nil end
    if isrgn then
      order = order + 1
      if idx == region_idx then return order end
    end
    i = i + 1
  end
end

-- Entrega o salto ao REAPER. `region_idx` é a região de destino, usada no modo
-- "section_end"; sem ela, o salto cai no smooth seek.
function M.hand_off(target_pos, mode, region_idx)
  if mode == "section_end" and region_idx then
    local order = timeline_order(region_idx)
    if order then
      reaper.GoToRegion(PROJ, order, true)
      return
    end
  end
  reaper.SetEditCurPos(target_pos, false, true)
end

-- Cancela um salto já entregue: o seek para a própria virada substitui o
-- pendente e a música segue sem interrupção.
function M.cancel_hand_off(boundary)
  reaper.SetEditCurPos(boundary, false, true)
end

-- Salto feito pelo script (modos batida e imediato). Com o smooth seek ligado
-- o seek esperaria o compasso, então ele é desligado só durante o seek.
-- Validado no spike 05: o salto sai na hora e o smooth seek volta ligado.
function M.jump_now(pos)
  local smooth = reaper.GetToggleCommandState(M.SMOOTH_SEEK) == 1
  if smooth then reaper.Main_OnCommand(M.SMOOTH_SEEK, 0) end
  reaper.SetEditCurPos(pos, false, true)
  if smooth then reaper.Main_OnCommand(M.SMOOTH_SEEK, 0) end
end

function M.is_playing() return reaper.GetPlayState() & 1 == 1 end

-- Posição de reprodução, ou o cursor de edição com o transporte parado.
function M.position()
  if M.is_playing() then return reaper.GetPlayPosition2() end
  return reaper.GetCursorPosition()
end

-- Cursor de edição (onde o play começa), mesmo tocando.
function M.cursor() return reaper.GetCursorPosition() end

function M.play() reaper.OnPlayButton() end
function M.stop() reaper.OnStopButton() end
-- Solta notas presas em todos os plugins e saídas MIDI (inclusive o Kontakt).
function M.all_notes_off() reaper.Main_OnCommand(M.ALL_NOTES_OFF, 0) end

function M.move_cursor(pos) reaper.SetEditCurPos(pos, true, false) end

function M.start_at(pos)
  M.move_cursor(pos)
  M.play()
end

-- Prende a reprodução na seção (on) ou volta a seguir a timeline até o fim
-- da música (off).
function M.set_loop(section, on, song)
  if on then
    reaper.GetSet_LoopTimeRange2(PROJ, true, true, section.start_pos, section.end_pos, false)
    reaper.GetSetRepeat(1)
  elseif song then
    M.arm_song_end(song)
  else
    reaper.GetSetRepeat(0)
  end
end

-- Faz o motor parar no fim da música.
function M.arm_song_end(song)
  reaper.GetSet_LoopTimeRange2(PROJ, true, true, song.start_pos, song.end_pos, false)
  reaper.GetSetRepeat(0)
end

return M
