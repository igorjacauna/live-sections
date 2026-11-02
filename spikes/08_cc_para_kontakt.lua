-- Spike 08: o Kontakt recebe CC gerado por um JSFX no início da cadeia?
--
-- Ideia para "Controles do Kontakt" (como no Gig Performer: o knob do
-- controlador vira um CC fixo que só o Kontakt da música atual recebe). O
-- controlador continua em "control messages"; quem gera o CC é um JSFX na
-- própria track do Kontakt, comandado pelo script com TrackFX_SetParam.
--
-- O spike grava o JSFX em <REAPER>/Effects/LiveSections/ e abre uma janela:
--   1. selecione a track do Kontakt e clique "Instalar na track selecionada";
--   2. no Kontakt, clique direito num knob → Learn MIDI CC# Automation e
--      mexa o slider "Valor" do spike: o Kontakt deve aprender o CC;
--   3. mexa de novo o slider / "Varredura" / "Botão 0↔127": o knob segue?
--   4. repita com o Live Sections aberto, com a música dessa track atual
--      (track armada só no teclado) e depois com outra música atual (Kontakt
--      em bypass: não deve responder, e ao voltar deve responder de novo).
--   5. toque o teclado enquanto mexe: as notas continuam normais?
-- "Remover" tira o JSFX da track.

local JSFX_DIR = reaper.GetResourcePath() .. "/Effects/LiveSections"
local JSFX_FILE = "ls_cc_spike.jsfx"
local JSFX_NAME = "JS:LiveSections/" .. JSFX_FILE

local JSFX = [[
desc:Live Sections - CC para o Kontakt (spike)
// O script muda os sliders; quando mudam, manda o CC no canal 1.
// Não chama midirecv: o MIDI que chega (teclado) passa direto.
slider1:cc=20<0,127,1>CC
slider2:val=0<0,127,1>Valor
in_pin:none
out_pin:none

@init
pending = 0;

@slider
pending = 1;

@block
pending ? (
  midisend(0, 0xB0, cc, val);
  pending = 0;
);
]]

local function out(s) reaper.ShowConsoleMsg(tostring(s) .. "\n") end

if not reaper.ImGui_GetBuiltinPath then
  reaper.MB("Este spike usa a ReaImGui (a mesma do Live Sections).", "Spike 08", 0)
  return
end
package.path = reaper.ImGui_GetBuiltinPath() .. "/?.lua;" .. package.path
local ImGui = require("imgui")("0.9")

reaper.RecursiveCreateDirectory(JSFX_DIR, 0)
local f = assert(io.open(JSFX_DIR .. "/" .. JSFX_FILE, "w"))
f:write(JSFX)
f:close()

reaper.ClearConsole()
out("Spike 08: JSFX gravado em " .. JSFX_DIR .. "/" .. JSFX_FILE)

local track, fx = nil, -1
local cc, val = 20, 0
local sweep_from = nil
local toggle = false

local function track_name(tr)
  local _, name = reaper.GetTrackName(tr)
  return name
end

local function find_fx(tr)
  for i = 0, reaper.TrackFX_GetCount(tr) - 1 do
    local _, name = reaper.TrackFX_GetFXName(tr, i, "")
    if name:find("CC para o Kontakt", 1, true) then return i end
  end
  return -1
end

local function send(v)
  val = v
  if not track or fx < 0 then return end
  reaper.TrackFX_SetParamNormalized(track, fx, 0, cc / 127)
  reaper.TrackFX_SetParamNormalized(track, fx, 1, v / 127)
end

local function install()
  local tr = reaper.GetSelectedTrack(0, 0)
  if not tr then out("Selecione a track do Kontakt antes."); return end
  local i = find_fx(tr)
  if i < 0 then i = reaper.TrackFX_AddByName(tr, JSFX_NAME, false, -1000) end
  track, fx = tr, i
  out(string.format("Instalar em \"%s\": índice %d (esperado 0)", track_name(tr), i))
  if i >= 0 then
    for k = 0, reaper.TrackFX_GetCount(tr) - 1 do
      local _, name = reaper.TrackFX_GetFXName(tr, k, "")
      out(string.format("  FX %d: %s", k, name))
    end
    out(string.format("  armada: %d  entrada: %d  FX ligados: %d",
      reaper.GetMediaTrackInfo_Value(tr, "I_RECARM"), reaper.GetMediaTrackInfo_Value(tr, "I_RECINPUT"),
      reaper.GetMediaTrackInfo_Value(tr, "I_FXEN")))
  end
end

local function remove()
  if track and reaper.ValidatePtr(track, "MediaTrack*") then
    local i = find_fx(track)
    if i >= 0 then reaper.TrackFX_Delete(track, i); out("JSFX removido de \"" .. track_name(track) .. "\"") end
  end
  track, fx = nil, -1
end

local ctx = ImGui.CreateContext("Spike 08")

local function loop()
  if track and not reaper.ValidatePtr(track, "MediaTrack*") then track, fx = nil, -1 end
  if track then fx = find_fx(track) end

  ImGui.SetNextWindowSize(ctx, 420, 260, ImGui.Cond_FirstUseEver)
  local visible, open = ImGui.Begin(ctx, "Spike 08: CC para o Kontakt", true)
  if visible then
    ImGui.Text(ctx, track and fx >= 0 and ("Track: " .. track_name(track) .. "  (JSFX no FX " .. fx .. ")")
      or "Nenhuma track com o JSFX")
    if ImGui.Button(ctx, "Instalar na track selecionada") then install() end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Remover") then remove() end
    ImGui.Separator(ctx)
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
    ImGui.End(ctx)
  end
  if open then reaper.defer(loop) end
end

reaper.defer(loop)
