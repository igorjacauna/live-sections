-- Ponte entre os scripts da lista de actions e a instância aberta do Live
-- Sections (RF-037), via ExtState global (não salva em disco).
--
-- A instância marca que está viva a cada ciclo (M.heartbeat) e lê a fila no
-- ciclo seguinte (M.poll). Cada action põe um comando na fila (M.send); sem
-- instância viva, avisa. Tudo roda na thread principal do REAPER, então a
-- fila não tem concorrência.
--
-- M.heartbeat(now)            instância: marca viva
-- M.shutdown()                instância: ao fechar
-- M.poll() -> { { action, arg, value } }   instância: comandos pendentes
-- M.send(action, arg, value) -> ok, err ("not_running")   action
-- M.run_action(action, arg)   corpo de cada script em actions/: lê o valor do
--                             MIDI (ação contínua) e envia, avisando se falhar

local M = {}

local SECTION = "LiveSections"
local ALIVE, QUEUE = "alive", "queue"
local ALIVE_S = 2.0   -- sem sinal de vida há mais que isso: instância fechada

function M.heartbeat(now)
  reaper.SetExtState(SECTION, ALIVE, string.format("%.3f", now), false)
end

function M.shutdown()
  reaper.DeleteExtState(SECTION, ALIVE, false)
  reaper.DeleteExtState(SECTION, QUEUE, false)
end

local function running()
  local t = tonumber(reaper.GetExtState(SECTION, ALIVE))
  return t ~= nil and reaper.time_precise() - t <= ALIVE_S
end

-- Linha: ação \t argumento \t valor; argumento numérico volta como número.
local function encode(action, arg, value)
  return table.concat({ action, arg == nil and "" or tostring(arg), value == nil and "" or tostring(value) }, "\t")
end

local function decode(line)
  local action, arg, value = line:match("^([^\t]*)\t([^\t]*)\t([^\t]*)$")
  if not action or action == "" then return nil end
  return { action = action, arg = arg ~= "" and (tonumber(arg) or arg) or nil, value = tonumber(value) }
end

function M.send(action, arg, value)
  if not running() then return false, "not_running" end
  local q = reaper.GetExtState(SECTION, QUEUE)
  reaper.SetExtState(SECTION, QUEUE, q .. encode(action, arg, value) .. "\n", false)
  return true
end

function M.poll()
  local q = reaper.GetExtState(SECTION, QUEUE)
  if q == "" then return {} end
  reaper.SetExtState(SECTION, QUEUE, "", false)
  local out = {}
  for line in q:gmatch("[^\n]+") do out[#out + 1] = decode(line) end
  return out
end

-- Valor 0–1 de um controle MIDI ligado à action (CC absoluto); nil se a
-- action foi disparada sem MIDI.
local function midi_value()
  local _, _, _, _, _, resolution, val = reaper.get_action_context()
  if resolution and resolution > 0 and val and val >= 0 then return val / resolution end
end

function M.run_action(action, arg)
  local value = midi_value()
  if (action == "layer_volume" or action == "stem_volume") and not value then
    reaper.MB("Esta action controla um volume: ligue-a a um fader ou knob (CC) na lista de actions ou no ReaLearn.",
      "Live Sections", 0)
    return
  end
  local ok = M.send(action, arg, value)
  if not ok then
    reaper.MB("O Live Sections não está aberto. Abra o script LiveSections.lua e dispare a action de novo.",
      "Live Sections", 0)
  end
end

return M
