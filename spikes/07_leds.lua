-- Spike 07: o controlador obedece aos LEDs que o script envia?
--
-- Pare o Live Sections antes. O spike lista as saídas MIDI, procura a saída
-- com o nome abaixo e, durante 8 s, alterna os LEDs do Select 1 (nota 24) e do
-- Solo 1 (nota 8): um aceso e o outro apagado, trocando a cada segundo. No fim
-- apaga os dois. Apagar = Note On com velocity 0, como o Live Sections faz.
--
-- Depois, por 30 s, o spike escuta o controlador: aperte o botão que está
-- aceso. Ele mostra a mensagem do botão, o mapeamento do Live Sections ligado
-- a ela (se houver) e, ao soltar, manda apagar aquele LED.

local PORT = "Jieli Technology - SINCO - SMC-Mixer-Master"
local NOTES = { 24, 8 }
local DURATION_S = 8
local LISTEN_S = 30
local DUP_S = 0.2 -- o controlador manda cada evento duas vezes

local function out(s) reaper.ShowConsoleMsg(tostring(s) .. "\n") end

local function script_dir()
  local _, path = reaper.get_action_context()
  return path:match("^(.*[/\\])")
end
package.path = script_dir() .. "../LiveSections/?.lua;" .. package.path
local json = require("vendor.json")

-- Mapeamentos salvos pelo Live Sections.
local function load_mappings()
  local f = io.open(reaper.GetResourcePath() .. "/Data/LiveSections/config.json", "r")
  if not f then return {} end
  local ok, data = pcall(json.decode, f:read("a"))
  f:close()
  return ok and type(data) == "table" and data.mappings or {}
end

reaper.ClearConsole()
out("Saídas MIDI ativas:")
local idx
for i = 0, reaper.GetMaxMidiOutputs() - 1 do
  local ok, name = reaper.GetMIDIOutputName(i, "")
  if ok then
    out(string.format("  %d: %s", i, name))
    if name == PORT then idx = i end
  end
end
if not idx then
  out('\nNenhuma saída chamada "' .. PORT .. '". Os LEDs não têm por onde sair.')
  return
end
out(string.format('\nUsando a saída %d. Olhe os LEDs do Select 1 e do Solo 1.', idx))

local function led(note, on) reaper.StuffMIDIMessage(16 + idx, 0x90, note, on and 127 or 0) end

local function input_name(dev)
  local ok, name = reaper.GetMIDIInputName(dev & 0xFFFF, "")
  return ok and name or ("dev " .. dev)
end

local function output_of(name)
  for i = 0, reaper.GetMaxMidiOutputs() - 1 do
    local ok, oname = reaper.GetMIDIOutputName(i, "")
    if ok and oname == name then return i end
  end
end

-- Tipo, canal e número no formato dos mapeamentos.
local function decode(buf)
  local st, d1, d2 = buf:byte(1), buf:byte(2) or 0, buf:byte(3) or 0
  local kind, ch = st & 0xF0, (st & 0x0F) + 1
  if kind == 0x90 and d2 > 0 then return "note", ch, d1, d2, true end
  if kind == 0x80 or kind == 0x90 then return "note", ch, d1, d2, false end
  if kind == 0xB0 then return "cc", ch, d1, d2, d2 > 0 end
  if kind == 0xC0 then return "pc", ch, d1, 0, true end
  if kind == 0xE0 then return "pb", ch, nil, (d2 << 7) | d1, true end
end

local function mapping_for(maps, port, msg_type, ch, number)
  for _, m in ipairs(maps) do
    if m.port_name == port and m.msg_type == msg_type and m.channel == ch
      and (msg_type == "pb" or m.number == number) then
      return m
    end
  end
end

local function listen()
  local maps = load_mappings()
  out(string.format("\nEscutando por %d s (%d mapeamentos no config.json).", LISTEN_S, #maps))
  out("Aperte o botão que está aceso.")
  local last_seq = reaper.MIDI_GetRecentInputEvent(0)
  local seen = {}
  local stop = reaper.time_precise() + LISTEN_S
  local function poll()
    local now = reaper.time_precise()
    local fresh, i = {}, 0
    while i <= 256 do
      local seq, buf, _, dev = reaper.MIDI_GetRecentInputEvent(i)
      if seq == 0 or seq == last_seq then break end
      fresh[#fresh + 1] = { buf = buf, dev = dev }
      i = i + 1
    end
    if #fresh > 0 then last_seq = reaper.MIDI_GetRecentInputEvent(0) end
    for n = #fresh, 1, -1 do
      local e = fresh[n]
      local port = input_name(e.dev)
      local msg_type, ch, number, value, press = decode(e.buf)
      local k = table.concat({ port, e.buf:byte(1, -1) }, ":")
      if msg_type and not (seen[k] and now - seen[k] < DUP_S) then
        seen[k] = now
        local m = mapping_for(maps, port, msg_type, ch, number)
        local where = m and string.format("mapeado: %s%s", m.action, m.arg and (" " .. tostring(m.arg)) or "")
          or "sem mapeamento no Live Sections"
        out(string.format("[%s] %s ch%d %s val %d %s  ->  %s", port, msg_type, ch,
          number and ("n" .. number) or "", value, press and "(aperta)" or "(solta)", where))
        if msg_type == "note" and not press then
          local o = output_of(port)
          if o then
            reaper.StuffMIDIMessage(16 + o, 0x90 + ch - 1, number, 0)
            out(string.format("   mandei apagar o LED n%d. Ele apagou?", number))
          end
        end
      end
    end
    if now < stop then reaper.defer(poll) else out("\nFim da escuta.") end
  end
  poll()
end

local start = reaper.time_precise()
local last = -1
local function loop()
  local t = reaper.time_precise() - start
  if t >= DURATION_S then
    for _, n in ipairs(NOTES) do led(n, false) end
    out("Fim: os dois LEDs devem estar apagados.")
    listen()
    return
  end
  local step = math.floor(t)
  if step ~= last then
    last = step
    local first = step % 2 == 0
    led(NOTES[1], first)
    led(NOTES[2], not first)
    out(string.format("%d s: Select 1 %s, Solo 1 %s", step, first and "aceso" or "apagado", first and "apagado" or "aceso"))
  end
  reaper.defer(loop)
end
loop()
