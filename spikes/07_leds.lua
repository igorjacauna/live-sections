-- Spike 07: o controlador obedece aos LEDs que o script envia?
--
-- Pare o Live Sections antes. O spike lista as saídas MIDI, procura a saída
-- com o nome abaixo e, durante 8 s, alterna os LEDs do Select 1 (nota 24) e do
-- Solo 1 (nota 8): um aceso e o outro apagado, trocando a cada segundo. No fim
-- apaga os dois. Apagar = Note On com velocity 0, como o Live Sections faz.

local PORT = "Jieli Technology - SINCO - SMC-Mixer-Master"
local NOTES = { 24, 8 }
local DURATION_S = 8

local function out(s) reaper.ShowConsoleMsg(tostring(s) .. "\n") end

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

local start = reaper.time_precise()
local last = -1
local function loop()
  local t = reaper.time_precise() - start
  if t >= DURATION_S then
    for _, n in ipairs(NOTES) do led(n, false) end
    out("Fim: os dois LEDs devem estar apagados.")
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
