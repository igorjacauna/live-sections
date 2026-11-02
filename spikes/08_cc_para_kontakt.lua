-- Spike 08: o Kontakt recebe CC gerado por um JSFX no início da cadeia?
--
-- Ideia para "Controles do Kontakt" (como no Gig Performer: o knob do
-- controlador vira um CC fixo que só o Kontakt da música atual recebe). O
-- controlador continua em "control messages"; quem gera o CC é um JSFX na
-- própria track do Kontakt, comandado pelo script com TrackFX_SetParam.
--
-- O spike grava dois JSFX em <REAPER>/Effects/LiveSections/ e instala na
-- track selecionada: FX 0 = gerador de CC, FX 1 = monitor de CC, FX 2+ =
-- Kontakt. A janela mostra o diagnóstico de cada etapa:
--   "blocos"     sobe sozinho → o REAPER está processando a cadeia de FX;
--   "enviados"   sobe ao mexer → o gerador mandou o CC;
--   "recebidos"  sobe ao mexer → o CC chegou na porta do Kontakt.
-- Se os três sobem e o Kontakt não aprende, o problema é o Kontakt (VST3).
--
-- Plano B, sem MIDI: "Parâmetro do Kontakt" mexe direto num parâmetro de
-- automação do Kontakt (aba Auto → Host Automation, arraste #000 no knob).
-- "Remover" tira os dois JSFX da track.

local JSFX_DIR = reaper.GetResourcePath() .. "/Effects/LiveSections"
local GEN_FILE, MON_FILE = "ls_cc_spike.jsfx", "ls_cc_monitor.jsfx"
local GEN_TAG, MON_TAG = "CC para o Kontakt", "Monitor de CC"

local GEN = [[
desc:Live Sections - CC para o Kontakt (spike)
// O script muda os sliders; quando mudam, manda o CC no canal 1.
// Não chama midirecv: o MIDI que chega (teclado) passa direto.
slider1:cc=20<0,127,1>CC
slider2:val=0<0,127,1>Valor
slider3:sent=0<0,1000000,1>Enviados
slider4:blocks=0<0,1000000,1>Blocos
in_pin:none
out_pin:none

@init
pending = 0;

@slider
pending = 1;

@block
blocks = (blocks + 1) % 1000000;
pending ? (
  midisend(0, 0xB0, cc, val);
  sent += 1;
  pending = 0;
);
]]

local MON = [[
desc:Live Sections - Monitor de CC (spike)
// Conta os CCs que passam e repassa tudo (teclado incluso).
slider1:lcc=0<0,127,1>Último CC
slider2:lval=0<0,127,1>Último valor
slider3:got=0<0,1000000,1>CCs recebidos
in_pin:none
out_pin:none

@block
while (midirecv(offs, m1, m2, m3)) (
  (m1 & 0xF0) == 0xB0 ? ( lcc = m2; lval = m3; got += 1; );
  midisend(offs, m1, m2, m3);
);
]]

local function out(s) reaper.ShowConsoleMsg(tostring(s) .. "\n") end

if not reaper.ImGui_GetBuiltinPath then
  reaper.MB("Este spike usa a ReaImGui (a mesma do Live Sections).", "Spike 08", 0)
  return
end
package.path = reaper.ImGui_GetBuiltinPath() .. "/?.lua;" .. package.path
local ImGui = require("imgui")("0.9")

local function write(name, text)
  local f = assert(io.open(JSFX_DIR .. "/" .. name, "w"))
  f:write(text)
  f:close()
end

reaper.RecursiveCreateDirectory(JSFX_DIR, 0)
write(GEN_FILE, GEN)
write(MON_FILE, MON)

reaper.ClearConsole()
out("Spike 08: JSFX gravados em " .. JSFX_DIR)

local track = nil
local cc, val = 20, 0
local sweep_from = nil
local toggle = false
local kparam, kval = 0, 0

local function track_name(tr)
  local _, name = reaper.GetTrackName(tr)
  return name
end

local function find_fx(tr, tag)
  for i = 0, reaper.TrackFX_GetCount(tr) - 1 do
    local _, name = reaper.TrackFX_GetFXName(tr, i, "")
    if name:find(tag, 1, true) then return i end
  end
  return -1
end

local function find_kontakt(tr)
  for i = 0, reaper.TrackFX_GetCount(tr) - 1 do
    local _, name = reaper.TrackFX_GetFXName(tr, i, "")
    if name:find("Kontakt", 1, true) and not name:find("Live Sections", 1, true) then return i end
  end
  return -1
end

local function param(tr, fx, p)
  if fx < 0 then return 0 end
  return math.floor(reaper.TrackFX_GetParam(tr, fx, p) + 0.5)
end

local function send(v)
  val = v
  local fx = track and find_fx(track, GEN_TAG) or -1
  if fx < 0 then return end
  reaper.TrackFX_SetParamNormalized(track, fx, 0, cc / 127)
  reaper.TrackFX_SetParamNormalized(track, fx, 1, v / 127)
end

local function strip(tr)
  for _, tag in ipairs({ MON_TAG, GEN_TAG }) do
    local i = find_fx(tr, tag)
    while i >= 0 do
      reaper.TrackFX_Delete(tr, i)
      i = find_fx(tr, tag)
    end
  end
end

local function install()
  local tr = reaper.GetSelectedTrack(0, 0)
  if not tr then out("Selecione a track do Kontakt antes."); return end
  strip(tr)
  local g = reaper.TrackFX_AddByName(tr, "JS:LiveSections/" .. GEN_FILE, false, -1000)
  local m = reaper.TrackFX_AddByName(tr, "JS:LiveSections/" .. MON_FILE, false, -1001)
  track = tr
  out(string.format("Instalar em \"%s\": gerador %d, monitor %d (esperado 0 e 1)", track_name(tr), g, m))
  for k = 0, reaper.TrackFX_GetCount(tr) - 1 do
    local _, name = reaper.TrackFX_GetFXName(tr, k, "")
    out(string.format("  FX %d: %s", k, name))
  end
  out(string.format("  armada: %d  entrada: %d  monitoramento: %d  FX ligados: %d",
    reaper.GetMediaTrackInfo_Value(tr, "I_RECARM"), reaper.GetMediaTrackInfo_Value(tr, "I_RECINPUT"),
    reaper.GetMediaTrackInfo_Value(tr, "I_RECMON"), reaper.GetMediaTrackInfo_Value(tr, "I_FXEN")))
  if find_kontakt(tr) < 0 then out("  ATENÇÃO: não achei o Kontakt nesta track.") end
end

local function remove()
  if track and reaper.ValidatePtr(track, "MediaTrack*") then
    strip(track)
    out("JSFX removidos de \"" .. track_name(track) .. "\"")
  end
  track = nil
end

local function last_touched(kfx)
  local ok, tnum, fxnum, pnum = reaper.GetLastTouchedFX()
  if not ok then return end
  local mine = reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER")
  if tnum == mine and fxnum == kfx then kparam = pnum
  else out("O último parâmetro mexido não é do Kontakt desta track.") end
end

local ctx = ImGui.CreateContext("Spike 08")

local function cc_section(gen, mon)
  local changed
  changed, cc = ImGui.SliderInt(ctx, "CC", cc, 0, 127)
  if changed then send(val) end
  local moved, v = ImGui.SliderInt(ctx, "Valor", val, 0, 127)
  if moved then send(v) end
  if ImGui.Button(ctx, "Varredura 0→127 (2 s)") then sweep_from = reaper.time_precise() end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "Botão 0↔127") then toggle = not toggle; send(toggle and 127 or 0) end
  if sweep_from then
    local t = (reaper.time_precise() - sweep_from) / 2
    if t >= 1 then sweep_from = nil; send(127) else send(math.floor(t * 127)) end
  end
  ImGui.Text(ctx, string.format("blocos: %d   enviados: %d", param(track, gen, 3), param(track, gen, 2)))
  ImGui.Text(ctx, string.format("recebidos no monitor: %d   (último: CC %d = %d)",
    param(track, mon, 2), param(track, mon, 0), param(track, mon, 1)))
end

local function kontakt_section(kfx)
  local n = reaper.TrackFX_GetNumParams(track, kfx)
  if n <= 0 then ImGui.Text(ctx, "O Kontakt não expôs parâmetros."); return end
  local _
  _, kparam = ImGui.SliderInt(ctx, "Parâmetro", math.min(kparam, n - 1), 0, n - 1)
  local _, pname = reaper.TrackFX_GetParamName(track, kfx, kparam, "")
  ImGui.Text(ctx, "Nome: " .. pname)
  local moved, v = ImGui.SliderDouble(ctx, "Valor do parâmetro", kval, 0, 1)
  if moved then
    kval = v
    reaper.TrackFX_SetParamNormalized(track, kfx, kparam, v)
  end
  ImGui.Text(ctx, string.format("O Kontakt diz: %.3f", reaper.TrackFX_GetParamNormalized(track, kfx, kparam)))
  if ImGui.Button(ctx, "Usar o último parâmetro mexido no Kontakt") then last_touched(kfx) end
end

local function loop()
  if track and not reaper.ValidatePtr(track, "MediaTrack*") then track = nil end
  if not track then
    -- Rodou de novo com o spike já instalado: adota a track selecionada.
    local sel = reaper.GetSelectedTrack(0, 0)
    if sel and find_kontakt(sel) >= 0 then track = sel end
  end
  local gen = track and find_fx(track, GEN_TAG) or -1
  local mon = track and find_fx(track, MON_TAG) or -1
  local kfx = track and find_kontakt(track) or -1

  ImGui.SetNextWindowSize(ctx, 460, 420, ImGui.Cond_FirstUseEver)
  local visible, open = ImGui.Begin(ctx, "Spike 08: CC para o Kontakt", true)
  if visible then
    ImGui.Text(ctx, track and ("Track: " .. track_name(track) .. "  (gerador FX " .. gen .. ", monitor FX " .. mon
      .. ", Kontakt FX " .. kfx .. ")") or "Nenhuma track instalada")
    if ImGui.Button(ctx, "Instalar na track selecionada") then install() end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Remover") then remove() end
    if track and gen >= 0 then
      ImGui.SeparatorText(ctx, "A. CC via JSFX")
      cc_section(gen, mon)
    end
    if track and kfx >= 0 then
      ImGui.SeparatorText(ctx, "B. Parâmetro do Kontakt (sem MIDI)")
      kontakt_section(kfx)
    end
    ImGui.End(ctx)
  end
  if open then reaper.defer(loop) end
end

reaper.defer(loop)
