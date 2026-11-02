-- Mapeamento: controles físicos que viram um CC fixo para o Kontakt.
--
-- Cada linha liga um controle do controlador (mapeamento "kontakt_cc" em
-- midi/mappings, arg = id da linha) a um CC de saída. A lista é global,
-- salva no config.json junto dos mapeamentos (RF-125).
--
-- Row = { id = "k1", name, cc (0–127), kind = "knob"|"toggle"|"momentary" }
--
-- M.init({ mappings })               carrega as linhas
-- M.rows() -> { Row }; M.get(id) -> Row?; M.mapping(id) -> Mapping?
-- M.add_from_learn(msg) -> Row       msg = { port_name, msg_type, channel, number }
--                                    sugere tipo, CC e nome (RF-112–RF-114)
-- M.update(id, { name?, cc?, kind? }) -> ok, err
-- M.remove(id); M.save() -> ok, err
-- M.suggest_cc() -> n?               menor CC livre fora dos reservados (RF-113)
-- M.RESERVED                         { [cc] = true }
-- M.warnings() -> { [id] = { Warning } }   Warning = { kind = "duplicate"|"reserved"|
--                                    "unmapped", other = Row? } — avisam, não bloqueiam (RF-141)
-- M.physical_name(msg) -> "Knob CC16" | "Botão C-2" | "Fader 1" | "Botão PC 5"

local M = {}

local ACTION = "kontakt_cc"
local KINDS = { knob = true, toggle = true, momentary = true }
local NOTES = { "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" }

-- Modulação, volume, pan, expressão, sustain/portamento/sostenuto/soft,
-- bank select e mensagens de modo de canal: o Kontakt já usa para outra coisa.
M.RESERVED = { [0] = true, [1] = true, [7] = true, [10] = true, [11] = true, [32] = true,
  [64] = true, [65] = true, [66] = true, [67] = true }
for cc = 120, 127 do M.RESERVED[cc] = true end

local mappings
local rows = {}

function M.init(deps)
  mappings = deps.mappings
  rows = mappings.kontakt_rows()
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

local function suggest_kind(msg)
  return (msg.msg_type == "cc" or msg.msg_type == "pb") and "knob" or "toggle"
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
