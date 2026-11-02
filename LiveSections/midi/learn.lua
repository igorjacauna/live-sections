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
-- Em série (tela Mapeamento, RF-111): M.start_series(handler) fica ativo até
-- M.cancel(); cada mensagem ainda não mapeada chama handler(msg) uma vez, com
-- msg = { port_name, msg_type, channel, number }, e o handler devolve o
-- mapeamento criado. Mexer de novo um controle que já virou linha não faz
-- nada.
--
-- Os controles do Mapeamento (ação "kontakt_cc") nunca tiram a mensagem de
-- outro controle: se ela já é usada, nada muda e o learn devolve
-- { conflict = Mapping } (RF-140). As outras ações continuam tomando a
-- mensagem para si.
--
-- control = { action, arg? }
-- M.feed(event) -> Mapping? | { conflict = Mapping }
-- M.state() -> { mode = "control"|"global"|"series", control? }?

local mappings = require("midi.mappings")

local M = {}

local ACCEPTED = { note = true, cc = true, pc = true, pb = true }

local current = nil

function M.start(control) current = { mode = "control", control = control } end
function M.start_global() current = { mode = "global" } end
function M.start_series(handler) current = { mode = "series", handler = handler } end
function M.cancel() current = nil end
function M.state() return current end

function M.select(control)
  if current and current.mode == "global" then current.control = control end
end

local KONTAKT = "kontakt_cc"

local function feed_series(event, msg)
  local used = mappings.match(event)
  if used then
    if used.action == KONTAKT then return nil end
    return { conflict = used }
  end
  return current.handler({ port_name = event.port_name, msg_type = msg.msg_type,
    channel = msg.channel, number = msg.number })
end

function M.feed(event)
  if not current then return nil end
  local msg = mappings.decode(event)
  if not msg or not ACCEPTED[msg.msg_type] then return nil end
  if current.mode == "series" then return feed_series(event, msg) end
  if not current.control then return nil end
  if current.control.action == KONTAKT then
    local used = mappings.match(event)
    if used and not (used.action == KONTAKT and used.arg == current.control.arg) then
      if current.mode == "control" then current = nil end
      return { conflict = used }
    end
  end
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
