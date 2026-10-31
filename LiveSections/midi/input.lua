-- Entrada MIDI: lê os eventos recentes do REAPER a cada ciclo e acompanha as
-- portas que sumem e voltam.
--
-- MIDI_GetRecentInputEvent devolve do mais novo (índice 0) para o mais velho,
-- com um número de sequência crescente. Cada poll lê até o último número já
-- visto e devolve os novos em ordem de chegada.
--
-- Em "Enable input for control messages" (spike 04) o devIdx vem com o bit
-- 0x10000 e cada evento chega duas vezes, às vezes em blocos intercalados.
-- A cópia é descartada por pareamento: a primeira ocorrência de uma mensagem
-- passa e fica pendente; a próxima igual, da mesma porta, é a cópia. Uma
-- pendência sem par expira em DUP_WINDOW_S.
--
-- Os mapeamentos guardam o nome da porta. Uma porta desconectada não gera
-- eventos; quando volta com o mesmo nome, seus eventos voltam a casar.
--
-- M.init()                    começa a ler a partir de agora
-- M.poll() -> Event[]         { port_name, status, data1, data2, ts, control }
-- M.watch(names)              portas a acompanhar (as dos mapeamentos)
-- M.check_ports() -> Change[] { port_name, connected } desde a última checagem
-- M.is_connected(name) -> bool

local M = {}

local CONTROL_FLAG = 0x10000
local DEV_MASK = 0xFFFF
local MAX_EVENTS = 256          -- tamanho máximo lido por ciclo
local DUP_WINDOW_S = 0.2

local last_seq = 0
local names = {}                -- [dev] = nome, cache de GetMIDIInputName
local pending = {}              -- { key, at }: mensagens de controle esperando a cópia
local watched = {}              -- [nome] = conectado (bool)

local function port_name(dev)
  if names[dev] == nil then
    local _, name = reaper.GetMIDIInputName(dev, "")
    names[dev] = name or ("dev " .. dev)
  end
  return names[dev]
end

local function present_ports()
  local out = {}
  for dev = 0, reaper.GetNumMIDIInputs() - 1 do
    local ok, name = reaper.GetMIDIInputName(dev, "")
    if ok and name then out[name] = true end
  end
  return out
end

-- true se o evento é a cópia de um já entregue.
local function is_copy(key, now)
  for i = #pending, 1, -1 do
    if now - pending[i].at > DUP_WINDOW_S then table.remove(pending, i) end
  end
  for i, p in ipairs(pending) do
    if p.key == key then
      table.remove(pending, i)
      return true
    end
  end
  pending[#pending + 1] = { key = key, at = now }
  return false
end

function M.init()
  last_seq = reaper.MIDI_GetRecentInputEvent(0)
  names, pending = {}, {}
end

function M.poll()
  local fresh, idx = {}, 0
  while idx < MAX_EVENTS do
    local seq, buf, ts, dev = reaper.MIDI_GetRecentInputEvent(idx)
    if seq == 0 or seq == last_seq then break end
    fresh[#fresh + 1] = { seq = seq, buf = buf, ts = ts, dev = dev }
    idx = idx + 1
  end
  if #fresh > 0 then last_seq = fresh[1].seq end

  local now = reaper.time_precise()
  local events = {}
  for n = #fresh, 1, -1 do
    local e = fresh[n]
    local dev = e.dev & DEV_MASK
    local control = e.dev & CONTROL_FLAG ~= 0
    if not (control and is_copy(dev .. ":" .. e.buf, now)) then
      events[#events + 1] = {
        port_name = port_name(dev),
        status = e.buf:byte(1) or 0,
        data1 = e.buf:byte(2) or 0,
        data2 = e.buf:byte(3) or 0,
        ts = e.ts,
        control = control,
      }
    end
  end
  return events
end

function M.watch(list)
  local new = {}
  for _, name in ipairs(list) do new[name] = watched[name] ~= false end
  watched = new
end

-- Compara as portas acompanhadas com as presentes. Os índices podem mudar
-- quando um dispositivo volta, então o cache de nomes é refeito.
function M.check_ports()
  local present = present_ports()
  names = {}
  local changes = {}
  for name, was in pairs(watched) do
    local now = present[name] == true
    if now ~= was then
      watched[name] = now
      changes[#changes + 1] = { port_name = name, connected = now }
    end
  end
  table.sort(changes, function(a, b) return a.port_name < b.port_name end)
  return changes
end

function M.is_connected(name) return watched[name] == true end

return M
