-- Feedback de LEDs: o estado de cada controle mapeado volta ao controlador
-- pelo mesmo mapeamento (mesmo tipo, canal e número), com a velocity
-- configurada para o estado. Sem presets por controlador (RF-042).
--
-- A saída é a de mesmo nome da porta de entrada do mapeamento, ou a saída
-- escolhida nas configurações (RF-041). Só Note e CC têm feedback.
--
-- "queued" pisca no próprio script, alternando a velocity da fila com a de
-- "idle", porque nem todo controlador pisca sozinho (o SMC-Mixer só acende e
-- apaga). Uma mensagem só é enviada quando a velocity daquele LED muda, e
-- tudo é reenviado a cada REFRESH_S: o controlador (ou outro programa) pode
-- acender um LED por conta própria e ele ficaria preso.
--
-- Estados: "idle" (parado), "playing", "queued", "loop", "empty" (sem seção).
-- Mute e solo de camada e o Play (tocando) acendem com a velocity de
-- "playing": é o "aceso" do controlador.
--
-- M.configure(settings)                { led_velocity, feedback_out_port?, led_blink? }
-- M.state_for(mapping, ctx) -> state   ctx = { sections, playing, queued, looping,
--                                      transport, layer = function(slot) -> { mute, solo } }
-- M.set_state(mapping, state)
-- M.flush(now)                         envia o que mudou; `now` em segundos
-- M.reset()                            esquece o que foi enviado (reenvia tudo)
-- M.touch(mapping)                     reenvia aquele LED (o botão foi tocado)
-- M.clear()                            apaga os LEDs mapeados (ao fechar o script)
-- M.preview(state, now, secs)          acende todos os LEDs com a velocity do
--                                      estado por `secs` (testar nas configurações)
-- M.velocities() -> { [state] = velocity }
-- M.missing_outputs() -> { nome }      portas sem saída MIDI no último flush

local M = {}

local BLINK_PERIOD_S = 0.5
local REFRESH_S = 2.0
local DEFAULT_VELOCITY = { idle = 0, playing = 127, queued = 127, loop = 127, empty = 0 }

local velocity = DEFAULT_VELOCITY
local out_override = nil
local blink = true
local wanted = {}     -- [key] = { mapping, state }
local sent = {}       -- [key] = velocity enviada
local missing = {}    -- nomes sem saída no último flush
local last_refresh = -math.huge
local preview = nil   -- { state, until_t }

local STATUS = { note = 0x90, cc = 0xB0 }

local function key(m) return table.concat({ m.port_name, m.msg_type, m.channel, m.number or "" }, ":") end

function M.configure(settings)
  settings = settings or {}
  velocity = {}
  for state, v in pairs(DEFAULT_VELOCITY) do
    velocity[state] = (settings.led_velocity or {})[state] or v
  end
  out_override = settings.feedback_out_port
  blink = settings.led_blink ~= false
  sent = {}
  last_refresh = -math.huge
end

function M.reset() sent = {} end

function M.touch(mapping) sent[key(mapping)] = nil end

-- ------------------------------------------------------------------ estados

local function same_section(a, b) return a ~= nil and b ~= nil and a.region_idx == b.region_idx end

-- Estado do LED de um mapeamento a partir do que está acontecendo:
--   ctx.sections  seções da música atual (slot = índice)
--   ctx.playing   seção tocando agora
--   ctx.queued    seção na fila
--   ctx.looping   seção presa em loop
--   ctx.transport true com o transporte tocando
--   ctx.layer     função: estado { mute, solo } da camada N, ou nil
function M.state_for(mapping, ctx)
  if mapping.action == "trigger_slot" then
    local section = ctx.sections and ctx.sections[mapping.arg]
    if not section then return "empty" end
    if same_section(section, ctx.queued) then return "queued" end
    if same_section(section, ctx.looping) then return "loop" end
    if same_section(section, ctx.playing) then return "playing" end
    return "idle"
  elseif mapping.action == "toggle_loop" then
    return ctx.looping and "loop" or "idle"
  elseif mapping.action == "play" or mapping.action == "play_stop" then
    return ctx.transport and "playing" or "idle"
  elseif mapping.action == "layer_mute" or mapping.action == "layer_solo" then
    local st = ctx.layer and ctx.layer(mapping.arg)
    local on = st and (mapping.action == "layer_mute" and st.mute or mapping.action == "layer_solo" and st.solo)
    return on and "playing" or "idle"
  end
  return "idle"
end

function M.set_state(mapping, state)
  if not STATUS[mapping.msg_type] then return end
  wanted[key(mapping)] = { mapping = mapping, state = state }
end

-- ------------------------------------------------------------------ envio

-- Saída com o nome da porta; sem diferenciar maiúsculas se não houver igual.
local function output_index(name)
  local loose
  for i = 0, reaper.GetMaxMidiOutputs() - 1 do
    local ok, oname = reaper.GetMIDIOutputName(i, "")
    if ok and oname == name then return i end
    if ok and not loose and oname:lower() == name:lower() then loose = i end
  end
  return loose
end

function M.missing_outputs() return missing end

function M.velocities() return velocity end

function M.preview(state, now, secs)
  preview = { state = state, until_t = now + (secs or 1.5) }
  sent = {}
end

local function velocity_of(state, now)
  if preview then
    if now < preview.until_t then state = preview.state else preview = nil; sent = {} end
  end
  if state == "queued" and blink and math.floor(now / BLINK_PERIOD_S) % 2 == 1 then
    return velocity.idle
  end
  return velocity[state] or velocity.idle
end

function M.flush(now)
  local outputs = {}
  missing = {}
  now = now or 0
  if now - last_refresh >= REFRESH_S then
    last_refresh = now
    sent = {}
  end
  for k, w in pairs(wanted) do
    local v = velocity_of(w.state, now)
    if sent[k] ~= v then
      local name = out_override or w.mapping.port_name
      if outputs[name] == nil then
        outputs[name] = output_index(name) or false
        if not outputs[name] then missing[#missing + 1] = name end
      end
      local out = outputs[name]
      if out then
        local m = w.mapping
        reaper.StuffMIDIMessage(16 + out, STATUS[m.msg_type] + m.channel - 1, m.number, v)
        sent[k] = v
      end
    end
  end
end

function M.clear()
  for k, w in pairs(wanted) do
    local m = w.mapping
    local out = output_index(out_override or m.port_name)
    if out then reaper.StuffMIDIMessage(16 + out, STATUS[m.msg_type] + m.channel - 1, m.number, 0) end
    sent[k] = 0
  end
end

-- Esquece os LEDs de mapeamentos que deixaram de existir.
function M.forget(mapping)
  local k = key(mapping)
  wanted[k], sent[k] = nil, nil
end

return M
