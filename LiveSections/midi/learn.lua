-- MIDI learn: liga a próxima mensagem recebida a um controle.
--
-- Por controle: M.start(control) espera uma mensagem e termina.
-- Global (RF-034): M.start_global() fica ativo; a tela escolhe o controle com
-- M.select(control) e cada mensagem mapeia o controle escolhido. Termina com
-- M.cancel().
--
-- Aceita Note On, CC, Program Change e pitch bend (RF-032, spike 04) e ignora
-- Note Off, aftertouch e mensagens de sistema (RF-033). O mapeamento é salvo
-- na hora.
--
-- control = { action, arg? }
-- M.feed(event) -> Mapping?    o mapeamento criado, ou nil
-- M.state() -> { mode = "control"|"global", control? }?

local mappings = require("midi.mappings")

local M = {}

local ACCEPTED = { note = true, cc = true, pc = true, pb = true }

local current = nil

function M.start(control) current = { mode = "control", control = control } end
function M.start_global() current = { mode = "global" } end
function M.cancel() current = nil end
function M.state() return current end

function M.select(control)
  if current and current.mode == "global" then current.control = control end
end

function M.feed(event)
  if not current or not current.control then return nil end
  local msg = mappings.decode(event)
  if not msg or not ACCEPTED[msg.msg_type] then return nil end
  local mapping = {
    action = current.control.action, arg = current.control.arg, port_name = event.port_name,
    msg_type = msg.msg_type, channel = msg.channel, number = msg.number,
  }
  mappings.set(mapping)
  mappings.save()
  if current.mode == "control" then current = nil else current.control = nil end
  return mapping
end

return M
