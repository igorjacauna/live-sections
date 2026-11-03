-- Mapeamentos MIDI: mensagem → ação, globais (independentes do projeto).
--
-- Um mapeamento casa por porta + tipo + canal + número. A mesma mensagem por
-- outra porta não dispara nada (RF-045). Cada controle (ação + argumento) tem
-- no máximo um mapeamento, e cada mensagem dispara no máximo um controle.
--
-- Ficam em GetResourcePath()/Data/LiveSections/config.json, na chave
-- "mappings"; as outras chaves do arquivo são preservadas ao salvar.
--
-- Mapping = { action, arg?, port_name, msg_type = "note"|"cc"|"pc"|"pb",
--             channel (1–16), number (nil em "pb") }
--
-- M.decode(event) -> Msg?        { msg_type, channel, number, value (0–1) }
-- M.match(event) -> Mapping?, value, released
--   released = true: Note Off do mapeamento de nota (o botão foi solto)
-- M.set(mapping); M.remove(action, arg); M.get(action, arg); M.all()
-- M.settings() -> tabela "settings"; M.save_settings(settings) grava junto
-- M.kontakt_rows() -> linhas do Mapeamento (chave "kontakt_cc")
-- M.save_kontakt_rows(rows) -> ok, err
-- M.load() -> ok, err;  M.save() -> ok, err

local json = require("vendor.json")

local M = {}

local CONFIG_VERSION = 1

-- Ações mapeáveis (RF-037). `arg`: o que o argumento significa.
M.ACTIONS = {
  trigger_slot   = { arg = "slot" },      -- N-ésima seção da música atual
  next_section   = {},
  prev_section   = {},
  next_song      = {},
  prev_song      = {},
  goto_song      = { arg = "song" },      -- música N
  toggle_loop    = {},
  set_quantize   = { arg = "quantize" },  -- modo de core/quantize
  cycle_quantize = { arg = "dir" },       -- 1 ou -1
  play_stop      = {},                    -- um botão só: alterna
  play           = {},                    -- botões separados de Play e Stop
  stop           = {},
  cancel         = {},
  panic          = {},
  layer_volume   = { arg = "layer" },     -- camada N
  layer_mute     = { arg = "layer" },    -- liga/desliga a camada N (mute invertido)
  toggle_setlist = {},                    -- setlist completa no modo palco (RF-074)
  tap_tempo      = {},                    -- toque do tap tempo no modo Editar (RF-097)
  kontakt_cc     = { arg = "row" },       -- linha da tela Mapeamento (id "k1"…)
}

local list = {}
local doc = { version = CONFIG_VERSION }

local function config_dir() return reaper.GetResourcePath() .. "/Data/LiveSections" end
function M.config_path() return config_dir() .. "/config.json" end

-- ------------------------------------------------------------------ mensagens

-- Decodifica um evento de midi/input. Note Off (ou Note On com velocity 0)
-- vira "note_off"; aftertouch e mensagens de sistema voltam nil.
function M.decode(event)
  local kind, channel = event.status & 0xF0, (event.status & 0x0F) + 1
  if event.status >= 0xF0 then return nil end
  if kind == 0x90 and event.data2 > 0 then
    return { msg_type = "note", channel = channel, number = event.data1, value = event.data2 / 127 }
  elseif kind == 0x80 or kind == 0x90 then
    return { msg_type = "note_off", channel = channel, number = event.data1, value = 0 }
  elseif kind == 0xB0 then
    return { msg_type = "cc", channel = channel, number = event.data1, value = event.data2 / 127 }
  elseif kind == 0xC0 then
    return { msg_type = "pc", channel = channel, number = event.data1, value = 1 }
  elseif kind == 0xE0 then
    return { msg_type = "pb", channel = channel, value = ((event.data2 << 7) | event.data1) / 16383 }
  end
  return nil
end

local function same_msg(m, port_name, msg)
  return m.port_name == port_name and m.msg_type == msg.msg_type
    and m.channel == msg.channel and m.number == msg.number
end

local function same_control(m, action, arg) return m.action == action and m.arg == arg end

function M.match(event)
  local msg = M.decode(event)
  if not msg then return nil end
  if msg.msg_type == "note_off" then
    local on = { msg_type = "note", channel = msg.channel, number = msg.number }
    for _, m in ipairs(list) do
      if same_msg(m, event.port_name, on) then return m, 0, true end
    end
    return nil
  end
  for _, m in ipairs(list) do
    if same_msg(m, event.port_name, msg) then return m, msg.value end
  end
  return nil
end

-- ------------------------------------------------------------------ edição

function M.all() return list end

function M.get(action, arg)
  for _, m in ipairs(list) do
    if same_control(m, action, arg) then return m end
  end
end

-- Substitui o mapeamento do controle e tira a mensagem de outro controle.
function M.set(mapping)
  if not M.ACTIONS[mapping.action] then
    error("mappings.set: ação desconhecida: " .. tostring(mapping.action), 2)
  end
  for i = #list, 1, -1 do
    local m = list[i]
    if same_control(m, mapping.action, mapping.arg) or same_msg(m, mapping.port_name, mapping) then
      table.remove(list, i)
    end
  end
  list[#list + 1] = mapping
end

function M.remove(action, arg)
  for i = #list, 1, -1 do
    if same_control(list[i], action, arg) then table.remove(list, i) end
  end
end

-- ------------------------------------------------------------------ arquivo

local function valid(m)
  return type(m) == "table" and M.ACTIONS[m.action] ~= nil and type(m.port_name) == "string"
    and (m.msg_type == "note" or m.msg_type == "cc" or m.msg_type == "pc" or m.msg_type == "pb")
    and type(m.channel) == "number" and (m.msg_type == "pb" or type(m.number) == "number")
end

-- Lê o arquivo. Sem arquivo, começa vazio. Um arquivo ilegível é renomeado
-- para config.json.bak, para não ser sobrescrito sem aviso.
function M.load()
  list, doc = {}, { version = CONFIG_VERSION }
  local path = M.config_path()
  local f = io.open(path, "r")
  if not f then return true end
  local text = f:read("a")
  f:close()
  local ok, data = pcall(json.decode, text)
  if not ok or type(data) ~= "table" then
    os.rename(path, path .. ".bak")
    return false, "invalid_config"
  end
  doc = data
  for _, m in ipairs(type(data.mappings) == "table" and data.mappings or {}) do
    if valid(m) then list[#list + 1] = m end
  end
  return true
end

-- Configurações globais (chave "settings" do mesmo arquivo). Salvar por aqui
-- evita que o arquivo seja gravado de dois lugares e um apague o outro.
function M.settings()
  if type(doc.settings) ~= "table" then doc.settings = {} end
  return doc.settings
end

function M.save_settings(settings)
  doc.settings = settings
  return M.save()
end

local KINDS = { knob = true, encoder = true, toggle = true, momentary = true }
local SPEEDS = { [1] = true, [2] = true, [4] = true, [8] = true }

local function valid_row(row)
  return type(row) == "table" and type(row.id) == "string" and type(row.name) == "string"
    and type(row.cc) == "number" and row.cc == math.floor(row.cc) and row.cc >= 0 and row.cc <= 127
    and KINDS[row.kind] == true
end

-- Linhas da tela Mapeamento (RF-125); as inválidas ficam de fora.
function M.kontakt_rows()
  local out = {}
  for _, row in ipairs(type(doc.kontakt_cc) == "table" and doc.kontakt_cc or {}) do
    if valid_row(row) then
      out[#out + 1] = { id = row.id, name = row.name, cc = math.floor(row.cc), kind = row.kind,
        speed = SPEEDS[row.speed] and row.speed or nil }
    end
  end
  return out
end

function M.save_kontakt_rows(rows)
  doc.kontakt_cc = rows
  return M.save()
end

function M.save()
  reaper.RecursiveCreateDirectory(config_dir(), 0)
  doc.version = doc.version or CONFIG_VERSION
  doc.mappings = list
  local f, err = io.open(M.config_path(), "w")
  if not f then return false, err end
  f:write(json.encode(doc))
  f:close()
  return true
end

return M
