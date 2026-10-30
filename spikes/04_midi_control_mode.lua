-- Spike 04: o script enxerga o controlador em "Enable input for control messages"?
--
-- Responde três perguntas para o RF-047:
--   1. MIDI_GetRecentInputEvent recebe as mensagens nesse modo?
--   2. O feedback de LEDs (StuffMIDIMessage) continua funcionando?
--   3. Nesse modo, os pads deixam de chegar às tracks?
--
-- Para a pergunta 3, o script cria uma track temporária "Spike 04 (teste)" com
-- ReaSynth, armada com entrada "All MIDI inputs" e monitoramento ligado. Se você
-- ouvir som ao apertar um pad, as mensagens estão chegando às tracks. A track é
-- removida quando o script termina.
--
-- Cada evento é impresso com o valor bruto de devIdx em hexadecimal, para
-- identificar se o REAPER marca de alguma forma os dispositivos em modo de controle.

local ECHO_LED = true
local TEST_TRACK_NAME = "Spike 04 (teste)"
local ALL_MIDI_INPUTS = 4096 + (63 << 5) -- I_RECINPUT: MIDI, todos os dispositivos, todos os canais

local function out(s) reaper.ShowConsoleMsg(tostring(s) .. "\n") end

local function input_name(dev)
  local ok, name = reaper.GetMIDIInputName(dev, "")
  return ok and name or ("dev " .. dev)
end

local function output_index_by_name(name)
  for i = 0, reaper.GetMaxMidiOutputs() - 1 do
    local ok, oname = reaper.GetMIDIOutputName(i, "")
    if ok and oname == name then return i end
  end
end

local function describe(buf)
  local status, d1, d2 = buf:byte(1), buf:byte(2) or 0, buf:byte(3) or 0
  local kind, ch = status & 0xF0, (status & 0x0F) + 1
  if kind == 0x90 and d2 > 0 then return string.format("Note On  ch%d n%d v%d", ch, d1, d2), "on", d1, ch
  elseif kind == 0x80 or kind == 0x90 then return string.format("Note Off ch%d n%d", ch, d1), "off", d1, ch
  elseif kind == 0xB0 then return string.format("CC       ch%d #%d = %d", ch, d1, d2)
  elseif kind == 0xC0 then return string.format("PC       ch%d #%d", ch, d1)
  elseif kind == 0xD0 then return string.format("Pressure ch%d = %d", ch, d1)
  end
  return string.format("raw %02X %02X %02X", status, d1, d2)
end

local function create_test_track()
  reaper.Undo_BeginBlock()
  local idx = reaper.CountTracks(0)
  reaper.InsertTrackAtIndex(idx, true)
  local track = reaper.GetTrack(0, idx)
  reaper.GetSetMediaTrackInfo_String(track, "P_NAME", TEST_TRACK_NAME, true)
  reaper.TrackFX_AddByName(track, "ReaSynth", false, -1)
  reaper.SetMediaTrackInfo_Value(track, "I_RECINPUT", ALL_MIDI_INPUTS)
  reaper.SetMediaTrackInfo_Value(track, "I_RECMODE", 2) -- sem gravação de fato
  reaper.SetMediaTrackInfo_Value(track, "I_RECMON", 1)
  reaper.SetMediaTrackInfo_Value(track, "I_RECARM", 1)
  reaper.Undo_EndBlock("Spike 04: track de teste", -1)
  return track
end

local function remove_test_track(track)
  if track and reaper.ValidatePtr(track, "MediaTrack*") then
    reaper.DeleteTrack(track)
  end
end

local test_track = create_test_track()
local last_seq = reaper.MIDI_GetRecentInputEvent(0)
local counts = {}

local function poll()
  local fresh, idx = {}, 0
  while true do
    local seq, buf, ts, dev = reaper.MIDI_GetRecentInputEvent(idx)
    if seq == 0 or seq == last_seq then break end
    fresh[#fresh + 1] = { seq = seq, buf = buf, ts = ts, dev = dev }
    idx = idx + 1
    if idx > 256 then break end
  end
  for n = #fresh, 1, -1 do
    local e = fresh[n]
    local name = input_name(e.dev & 0xFFFF)
    counts[name] = (counts[name] or 0) + 1
    local text, kind, note, ch = describe(e.buf)
    out(string.format("[%s] dev=0x%X  %s", name, e.dev, text))
    if ECHO_LED and (kind == "on" or kind == "off") then
      local o = output_index_by_name(name)
      if o then
        reaper.StuffMIDIMessage(16 + o, 0x90 + ch - 1, note, kind == "on" and 127 or 0)
      elseif kind == "on" then
        out("   (sem saída MIDI habilitada com o nome '" .. name .. "')")
      end
    end
  end
  if #fresh > 0 then last_seq = fresh[1].seq end
  reaper.defer(poll)
end

reaper.atexit(function()
  remove_test_track(test_track)
  out("\n== Resumo: eventos recebidos por porta ==")
  local any = false
  for name, n in pairs(counts) do out(string.format("  %-50s %d", name, n)); any = true end
  if not any then out("  nenhum evento recebido") end
  out("Track de teste removida. Copie todo este console e mande de volta.")
end)

reaper.ClearConsole()
out("Spike 04: aperte pads e mova faders do controlador.")
out("Track '" .. TEST_TRACK_NAME .. "' criada com ReaSynth e entrada All MIDI inputs: escute se os pads tocam som.")
out("Para parar: rode o script de novo e escolha 'Terminate instances'.\n")
poll()
