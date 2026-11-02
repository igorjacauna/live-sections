-- Mapeamento: controles físicos que viram um CC fixo para o Kontakt.
--
-- Cada linha liga um controle do controlador (mapeamento "kontakt_cc" em
-- midi/mappings, arg = id da linha) a um CC de saída. A lista é global,
-- salva no config.json junto dos mapeamentos (RF-125).
--
-- Row = { id = "k1", name, cc (0–127), kind = "knob"|"encoder"|"toggle"|"momentary" }
--
-- "encoder" é o knob sem fim (relativo): cada giro manda só o passo, 1–63
-- para a direita e 65–127 para a esquerda (bit de sinal, 65 = -1, ou
-- complemento de dois, 127 = -1). O valor da linha soma os passos vezes a
-- sensibilidade da linha (speed = 1, 2, 4 ou 8; sem speed vale 1).
--
-- M.init({ mappings, jsfx, layers })  carrega as linhas
-- M.rows() -> { Row }; M.get(id) -> Row?; M.mapping(id) -> Mapping?
-- M.add_from_learn(msg) -> Row       msg = { port_name, msg_type, channel, number, value? }
--                                    sugere tipo, CC e nome (RF-112–RF-114)
-- M.update(id, { name?, cc?, kind?, speed? }) -> ok, err
-- M.SPEEDS                           { 1, 2, 4, 8 }
-- M.remove(id); M.save() -> ok, err
-- M.suggest_cc() -> n?               menor CC livre fora dos reservados (RF-113)
-- M.RESERVED                         { [cc] = true }
-- M.warnings() -> { [id] = { Warning } }   Warning = { kind = "duplicate"|"reserved"|
--                                    "unmapped", other = Row? } — avisam, não bloqueiam (RF-141)
-- M.physical_name(msg) -> "Knob CC16" | "Botão C-2" | "Fader 1" | "Botão PC 5"
--
-- Ao vivo, o CC vai só para o JSFX (core/kontakt_jsfx) da track do Kontakt
-- da música atual (RF-126); sem Kontakt ou sem JSFX nada é enviado, mas o
-- valor da linha muda do mesmo jeito (RF-127, RF-137).
-- M.handle(mapping, value, released, now)   evento casado com kontakt_cc;
--                                    value 0–1 de midi/mappings
-- M.on_song(song)                    depois de layers.activate: lê os valores
--                                    salvos da música e pede o reenvio (RF-133)
-- M.tick(now)                        Testar, Enviar p/ Learn e a luz de envio
-- M.test(id, now)                    varre 0→127 em 2 s e volta (RF-120)
-- M.send_learn(id, now)              uma variação do CC e volta (RF-121)
-- M.value(id) -> 0–127?; M.is_on(id) -> bool
-- M.led(id) -> bool?                 LED do botão liga/desliga; nil nos outros tipos
-- M.flashed(id, now) -> bool         o CC da linha saiu do JSFX (RF-119)
-- M.last_touch(now) -> { row, value }?   até TOUCH_S depois do último toque
-- M.has_kontakt() -> bool            a música atual tem Kontakt
-- M.open_kontakt() -> ok, err        abre (ou fecha, se aberta) a janela do
--                                    Kontakt da música atual; err = "no_kontakt"

local M = {}

local ACTION = "kontakt_cc"
local KINDS = { knob = true, encoder = true, toggle = true, momentary = true }
M.SPEEDS = { 1, 2, 4, 8 }
local NOTES = { "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" }

-- Modulação, volume, pan, expressão, sustain/portamento/sostenuto/soft,
-- bank select e mensagens de modo de canal: o Kontakt já usa para outra coisa.
M.RESERVED = { [0] = true, [1] = true, [7] = true, [10] = true, [11] = true, [32] = true,
  [64] = true, [65] = true, [66] = true, [67] = true }
for cc = 120, 127 do M.RESERVED[cc] = true end

local TEST_S = 2.0      -- duração da varredura do Testar
local LEARN_S = 0.15    -- tempo da variação do Enviar p/ Learn antes de voltar
local FLASH_S = 0.3     -- luz de envio acesa
local TOUCH_S = 2.0     -- aviso "Nome valor" na tela

local mappings, jsfx, layers
local rows = {}
local track = nil       -- track do Kontakt da música atual
local values = {}       -- [id] = 0–127
local raw = {}          -- [id] = último value (0–1) recebido, para a subida
local sweeps = {}       -- [id] = { kind = "test"|"learn", from, restore }
local pending = {}      -- ids enviados desde a última leitura do contador
local sent_seen = nil   -- contador "enviados" do JSFX na última leitura
local flash_until = {}  -- [id] = instante
local touch = nil       -- { id, at }

function M.init(deps)
  mappings, jsfx, layers = deps.mappings, deps.jsfx, deps.layers
  rows = mappings.kontakt_rows()
  track, values, raw, sweeps, pending, sent_seen, flash_until, touch = nil, {}, {}, {}, {}, nil, {}, nil
end

function M.rows() return rows end

function M.get(id)
  for _, row in ipairs(rows) do
    if row.id == id then return row end
  end
end

function M.mapping(id) return mappings.get(ACTION, id) end

function M.save() return mappings.save_kontakt_rows(rows) end

-- ------------------------------------------------------------------ sugestões

-- Nota 0 = C-2, como no SMC-Mixer e no Gig Performer.
local function note_name(n) return NOTES[n % 12 + 1] .. tostring(n // 12 - 2) end

function M.physical_name(msg)
  if msg.msg_type == "cc" then return "Knob CC" .. msg.number
  elseif msg.msg_type == "note" then return "Botão " .. note_name(msg.number)
  elseif msg.msg_type == "pb" then return "Fader " .. msg.channel
  else return "Botão PC " .. msg.number end
end

-- Um CC que chega com 1–3 ou 125–127 (ou 65–67) no primeiro giro é quase
-- sempre um knob sem fim mandando o passo.
local function relative_value(v)
  return v ~= nil and ((v >= 1 and v <= 3) or (v >= 65 and v <= 67) or v >= 125)
end

local function suggest_kind(msg)
  if msg.msg_type == "cc" and relative_value(msg.value) then return "encoder" end
  return (msg.msg_type == "cc" or msg.msg_type == "pb") and "knob" or "toggle"
end

-- passo de um knob sem fim: até 96 é bit de sinal, acima é complemento de dois
local function step_of(v)
  if v < 64 then return v end
  if v > 96 then return v - 128 end
  return -(v - 64)
end

function M.suggest_cc()
  local used = {}
  for _, row in ipairs(rows) do used[row.cc] = true end
  for cc = 0, 127 do
    if not used[cc] and not M.RESERVED[cc] then return cc end
  end
end

local function next_id()
  local max = 0
  for _, row in ipairs(rows) do
    local n = tonumber(row.id:match("^k(%d+)$"))
    if n and n > max then max = n end
  end
  return "k" .. (max + 1)
end

function M.add_from_learn(msg)
  local row = { id = next_id(), name = M.physical_name(msg), cc = M.suggest_cc() or 0, kind = suggest_kind(msg) }
  rows[#rows + 1] = row
  mappings.set({ action = ACTION, arg = row.id, port_name = msg.port_name,
    msg_type = msg.msg_type, channel = msg.channel, number = msg.number })
  M.save()
  return row
end

-- ------------------------------------------------------------------ edição

function M.update(id, fields)
  local row = M.get(id)
  if not row then return false, "not_found" end
  if fields.name ~= nil then
    local name = tostring(fields.name):gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" then return false, "empty_name" end
    row.name = name
  end
  if fields.cc ~= nil then
    local cc = tonumber(fields.cc)
    if not cc or cc ~= math.floor(cc) or cc < 0 or cc > 127 then return false, "invalid_cc" end
    row.cc = math.floor(cc)
  end
  if fields.speed ~= nil then
    local ok = false
    for _, s in ipairs(M.SPEEDS) do ok = ok or s == fields.speed end
    if not ok then return false, "invalid_speed" end
    row.speed = fields.speed ~= 1 and fields.speed or nil
  end
  if fields.kind ~= nil then
    if not KINDS[fields.kind] then return false, "invalid_kind" end
    row.kind = fields.kind
  end
  return M.save()
end

function M.remove(id)
  for i = #rows, 1, -1 do
    if rows[i].id == id then table.remove(rows, i) end
  end
  mappings.remove(ACTION, id)
  return M.save()
end

-- ------------------------------------------------------------------ ao vivo

local function send(row, v)
  if track and jsfx.set_cc(track, row.cc, v) then pending[row.id] = true end
end

local function set_value(row, v, now)
  values[row.id] = v
  sweeps[row.id] = nil
  touch = { id = row.id, at = now }
  send(row, v)
end

function M.handle(mapping, value, released, now)
  local row = M.get(mapping.arg)
  if not row then return end
  local before = raw[row.id] or 0
  raw[row.id] = released and 0 or value
  if row.kind == "knob" then
    set_value(row, math.floor(value * 127 + 0.5), now)
  elseif row.kind == "encoder" then
    local v = (values[row.id] or 0) + step_of(math.floor(value * 127 + 0.5)) * (row.speed or 1)
    set_value(row, math.max(0, math.min(127, v)), now)
  elseif row.kind == "momentary" then
    set_value(row, (not released and value >= 0.5) and 127 or 0, now)
  else
    -- liga/desliga: só a subida (nota apertada ou CC que passa da metade)
    local press = not released and value >= 0.5 and (mapping.msg_type ~= "cc" or before < 0.5)
    if press then set_value(row, M.is_on(row.id) and 0 or 127, now) end
  end
end

function M.on_song(song)
  track = song and layers.track_of(song) or nil
  values, raw, sweeps, pending, flash_until = {}, {}, {}, {}, {}
  sent_seen = track and jsfx.sent_count(track) or nil
  if not track then return end
  for _, row in ipairs(rows) do
    local v = jsfx.value(track, row.cc)
    if v and v >= 0 then values[row.id] = v end
  end
  jsfx.resend(track)
end

function M.test(id, now)
  local row = M.get(id)
  if not row then return end
  sweeps[id] = { kind = "test", from = now, restore = values[id] }
  send(row, 0)
end

function M.send_learn(id, now)
  local row = M.get(id)
  if not row then return end
  local cur = values[id]
  sweeps[id] = { kind = "learn", from = now, restore = cur }
  send(row, (cur or 0) >= 64 and 0 or 127)
end

local function end_sweep(row, sw)
  sweeps[row.id] = nil
  local final = sw.restore or (sw.kind == "test" and 127 or nil)
  if final then
    values[row.id] = final
    send(row, final)
  end
end

function M.tick(now)
  for _, row in ipairs(rows) do
    local sw = sweeps[row.id]
    if sw then
      local len = sw.kind == "test" and TEST_S or LEARN_S
      local t = (now - sw.from) / len
      if t >= 1 then end_sweep(row, sw)
      elseif sw.kind == "test" then send(row, math.floor(t * 127)) end
    end
  end
  local count = track and jsfx.sent_count(track)
  if count and sent_seen and count ~= sent_seen then
    for id in pairs(pending) do flash_until[id] = now + FLASH_S end
    pending = {}
  end
  sent_seen = count
end

function M.value(id) return values[id] end
function M.is_on(id) return (values[id] or 0) >= 64 end

function M.led(id)
  local row = M.get(id)
  if not row or row.kind ~= "toggle" then return nil end
  return M.is_on(id)
end
function M.flashed(id, now) return (flash_until[id] or -math.huge) > now end

function M.last_touch(now)
  if not touch or now - touch.at >= TOUCH_S then return nil end
  local row = M.get(touch.id)
  if not row then return nil end
  return { row = row, value = values[row.id] }
end

-- ------------------------------------------------------------------ janela

-- O JSFX do Mapeamento também tem "Kontakt" no nome: fica de fora.
local function kontakt_fx()
  if not track then return nil end
  local ours = jsfx.find(track)
  for i = 0, reaper.TrackFX_GetCount(track) - 1 do
    local _, name = reaper.TrackFX_GetFXName(track, i, "")
    if i ~= ours and name:lower():find("kontakt", 1, true) then return i end
  end
  return nil
end

function M.has_kontakt() return kontakt_fx() ~= nil end

function M.open_kontakt()
  local i = kontakt_fx()
  if not i then return false, "no_kontakt" end
  -- 3 = janela flutuante, 2 = fechar a flutuante
  reaper.TrackFX_Show(track, i, reaper.TrackFX_GetOpen(track, i) and 2 or 3)
  return true
end

-- ------------------------------------------------------------------ avisos

function M.warnings()
  local out = {}
  local function add(id, w)
    out[id] = out[id] or {}
    out[id][#out[id] + 1] = w
  end
  for i, row in ipairs(rows) do
    for j, other in ipairs(rows) do
      if i ~= j and other.cc == row.cc then add(row.id, { kind = "duplicate", other = other }); break end
    end
    if M.RESERVED[row.cc] then add(row.id, { kind = "reserved" }) end
    -- o controle físico foi aprendido por uma ação depois: a linha ficou sem
    if not M.mapping(row.id) then add(row.id, { kind = "unmapped" }) end
  end
  return out
end

return M
