-- Spike 03: o script enxerga o MIDI do controlador? E consegue acender os LEDs?
--
-- Mostra no console toda mensagem recebida via MIDI_GetRecentInputEvent, com
-- o dispositivo de origem. Teste com o controlador habilitado em
-- Preferences > MIDI Inputs de duas formas: "Enable input" e
-- "Enable input for control messages" (só controle).
--
-- Com ECHO_LED = true, cada Note On recebida é devolvida para a saída MIDI de
-- mesmo nome (velocity 127 e depois 0), para testar o feedback de LEDs. A
-- saída precisa estar habilitada em Preferences > MIDI Outputs.

local ECHO_LED = true

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
  end
  return string.format("raw %02X %02X %02X", status, d1, d2)
end

local function latest_seq()
  local seq = reaper.MIDI_GetRecentInputEvent(0)
  return seq
end

local last_seq = latest_seq()

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
    local dev_idx = e.dev & 0xFFFF
    local name = input_name(dev_idx)
    local text, kind, note, ch = describe(e.buf)
    out(string.format("[%s] dev=0x%X  %s", name, e.dev, text))
    if ECHO_LED and kind == "on" then
      local o = output_index_by_name(name)
      if o then
        reaper.StuffMIDIMessage(16 + o, 0x90 + ch - 1, note, 127)
      else
        out("   (sem saída MIDI habilitada com o nome '" .. name .. "')")
      end
    elseif ECHO_LED and kind == "off" then
      local o = output_index_by_name(name)
      if o then reaper.StuffMIDIMessage(16 + o, 0x90 + ch - 1, note, 0) end
    end
  end
  if #fresh > 0 then last_seq = fresh[1].seq end
  reaper.defer(poll)
end

reaper.ClearConsole()
out("Spike 03: aperte pads, mova faders. Para parar: rode o script de novo e escolha 'Terminate'.")
poll()
