-- Tela Mapeamento (RF-108): controles do controlador que viram um CC fixo
-- para o Kontakt da música atual (core/kontakt_cc).
--
-- "Aprender vários" liga o learn em série: cada controle mexido vira uma
-- linha com tipo, CC e nome sugeridos (RF-111). Cada linha edita nome, CC e
-- tipo, reaprende o controle físico e é removida aqui (RF-115–RF-117). Os
-- avisos não bloqueiam (RF-122–RF-124, RF-141).
--
-- Para dar segurança: cada linha mostra o valor atual numa barra e uma luz
-- que acende quando o CC sai do JSFX (RF-118, RF-119), com Testar e Enviar
-- p/ Learn (RF-120, RF-121); o topo conta as músicas cujo Kontakt tem o
-- JSFX e instala nas que faltam (RF-128, RF-129).
--
-- M.init(deps)   ImGui, theme, kit, kontakt_cc, learn, feedback, ui,
--                label (texto de uma ação: settings_view.label),
--                jsfx (core/kontakt_jsfx), layers, model,
--                jsfx_status = { ok, err, path } da gravação do JSFX
-- M.draw(ctx, x, y, w, h, snap) -> altura usada

local M = {}

local ImGui, theme, kit, kcc, learn, feedback, ui, label, jsfx, layers, model
local jsfx_status = { ok = true }

local GAP = 12
local ROW_H = 44
local CONFLICT_S = 5
local COVERAGE_S = 1.0   -- recontagem das músicas com o JSFX
local BAR_W = 90
local KIND_LABEL = { knob = "Knob", toggle = "Liga/desliga", momentary = "Segurar" }
local KINDS = { "knob", "toggle", "momentary" }

local name_buf = {}      -- [id] = texto do nome enquanto é editado
local height = 0
local coverage, coverage_at = nil, -math.huge

function M.init(deps)
  ImGui, theme, kit = deps.ImGui, deps.theme, deps.kit
  kcc, learn, feedback, ui, label = deps.kontakt_cc, deps.learn, deps.feedback, deps.ui, deps.label
  jsfx, layers, model = deps.jsfx, deps.layers, deps.model
  jsfx_status = deps.jsfx_status or { ok = true }
  name_buf, height, coverage, coverage_at = {}, 0, nil, -math.huge
end

-- ------------------------------------------------------------------ apoio

local function series_on()
  local st = learn.state()
  return st ~= nil and st.mode == "series"
end

local function relearning(id)
  local st = learn.state()
  return st ~= nil and st.mode == "control" and st.control.action == "kontakt_cc" and st.control.arg == id
end

local function start_series()
  learn.start_series(function(msg)
    local row = kcc.add_from_learn(msg)
    return kcc.mapping(row.id)
  end)
end

local function warning_text(w)
  if w.kind == "duplicate" then return string.format('CC repetido com "%s"', w.other.name)
  elseif w.kind == "reserved" then return "CC que o Kontakt já usa (modulação, volume, sustain…)"
  else return "Sem controle físico: uma ação do Live Sections aprendeu o mesmo controle. Reaprenda." end
end

local function body_font(ctx) return theme.font(ctx, "body") end

-- ------------------------------------------------------------------ partes

local function header(ctx, dl, ix, iw, cy)
  kit.txt(ctx, dl, "title", ix, cy, theme.C.text, "Mapeamento")
  local on = series_on()
  local bl = on and "Parar de aprender" or "Aprender vários"
  local bw = kit.size(ctx, "button", bl) + 46
  if kit.button(ctx, "kcc_series", bl, ix + iw - bw, cy - 2, 30, { icon = "learn", w = bw, active = on }) then
    if on then learn.cancel() else start_series() end
  end
  cy = cy + 40
  cy = cy + kit.wrapped(ctx, "small", ix, cy, iw - bw - 16, theme.C.muted,
    "Cada controle do controlador vira um CC fixo que vai só para o Kontakt da música atual, como no Gig Performer. No Kontakt, use Learn MIDI CC# Automation num knob e mexa o controle (ou use Enviar p/ Learn).") + 12
  return cy
end

local function get_coverage(now)
  if not coverage or now - coverage_at >= COVERAGE_S then
    coverage, coverage_at = jsfx.coverage(model.songs(), layers.track_of), now
  end
  return coverage
end

local function install_missing(cov)
  reaper.Undo_BeginBlock()
  for _, song in ipairs(cov.missing) do
    local tr = layers.track_of(song)
    if tr then jsfx.install(tr) end
  end
  reaper.Undo_EndBlock("Live Sections: instalar o JSFX do Mapeamento", -1)
  coverage = nil
end

local function coverage_line(ctx, dl, ix, iw, cy, now)
  local cov = get_coverage(now)
  if cov.total == 0 then
    return cy + kit.wrapped(ctx, "small", ix, cy, iw, theme.C.muted,
      "Nenhuma música deste projeto tem Kontakt vinculado. Vincule no modo Editar para os controles chegarem a ele.") + 12
  end
  local all = cov.installed == cov.total
  local text = string.format("JSFX instalado em %d de %d músicas com Kontakt", cov.installed, cov.total)
  kit.txt(ctx, dl, "button", ix + (all and 22 or 0), cy + 6, all and theme.C.ok or theme.C.queue, text)
  if all then
    theme.icon(dl, "check", ix, cy + 6, 16, theme.C.ok)
  else
    local bl = "Instalar em todas"
    local bw = kit.size(ctx, "button", bl) + 24
    local bx = ix + kit.size(ctx, "button", text) + 16
    if kit.button(ctx, "kcc_install_all", bl, bx, cy, 30, { w = bw }) then install_missing(cov) end
  end
  return cy + 42
end

local function banners(ctx, dl, ix, iw, cy, now)
  if not jsfx_status.ok then
    cy = cy + kit.wrapped(ctx, "small", ix, cy, iw, theme.C.danger, string.format(
      "Não consegui gravar o JSFX do Mapeamento em %s (%s). Sem ele os controles não chegam ao Kontakt.",
      tostring(jsfx_status.path), tostring(jsfx_status.err))) + 10
  end
  if series_on() then
    cy = cy + kit.wrapped(ctx, "strong", ix, cy, iw, theme.C.learn,
      "Mexa os controles, um de cada vez. Cada um vira uma linha. Clique em Parar de aprender quando terminar.") + 10
  end
  local c = ui.learn_conflict
  if c and now - c.at < CONFLICT_S then
    cy = cy + kit.wrapped(ctx, "small", ix, cy, iw, theme.C.queue, string.format(
      'Esse controle já é "%s". Ele continua com essa ação; remova o mapeamento em Configurações para usá-lo aqui.',
      label(c.mapping))) + 10
  end
  return cy
end

local function row_controls(ctx, dl, row, cols, cy)
  local m = kcc.mapping(row.id)
  -- nome
  local body = body_font(ctx)
  ImGui.SetCursorScreenPos(ctx, cols.name, cy + 4)
  ImGui.SetNextItemWidth(ctx, cols.name_w)
  local changed, text = ImGui.InputText(ctx, "##kname_" .. row.id, name_buf[row.id] or row.name)
  if changed then name_buf[row.id] = text end
  if ImGui.IsItemDeactivatedAfterEdit(ctx) and name_buf[row.id] then
    kcc.update(row.id, { name = name_buf[row.id] })
    name_buf[row.id] = nil
  end
  -- CC de saída
  ImGui.SetCursorScreenPos(ctx, cols.cc, cy + 4)
  ImGui.SetNextItemWidth(ctx, cols.cc_w)
  local moved, cc = ImGui.InputInt(ctx, "##kcc_" .. row.id, row.cc, 1, 10)
  if moved then kcc.update(row.id, { cc = math.max(0, math.min(127, cc)) }) end
  -- tipo
  ImGui.SetCursorScreenPos(ctx, cols.kind, cy + 4)
  ImGui.SetNextItemWidth(ctx, cols.kind_w)
  if ImGui.BeginCombo(ctx, "##kkind_" .. row.id, KIND_LABEL[row.kind]) then
    for _, k in ipairs(KINDS) do
      if ImGui.Selectable(ctx, KIND_LABEL[k], k == row.kind) then kcc.update(row.id, { kind = k }) end
    end
    ImGui.EndCombo(ctx)
  end
  theme.pop_font(ctx, body)
  -- controle físico
  local phys = m and kcc.physical_name(m) or "Sem controle"
  ImGui.DrawList_PushClipRect(dl, cols.phys, cy, cols.phys + cols.phys_w, cy + ROW_H, true)
  kit.txt(ctx, dl, "button", cols.phys, cy + 4, m and theme.C.text or theme.C.danger, phys)
  if m then kit.txt(ctx, dl, "small", cols.phys, cy + 22, theme.C.faint, m.port_name) end
  ImGui.DrawList_PopClipRect(dl)
end

-- Valor atual (barra) e a luz de envio do CC.
local function row_signal(dl, row, x, cy, now)
  local v = kcc.value(row.id)
  local by = cy + 16
  ImGui.DrawList_AddRectFilled(dl, x, by, x + BAR_W, by + 8, theme.C.raise2, 4)
  if v then ImGui.DrawList_AddRectFilled(dl, x, by, x + BAR_W * v / 127, by + 8, theme.C.text, 4) end
  local lit = kcc.flashed(row.id, now)
  ImGui.DrawList_AddCircleFilled(dl, x + BAR_W + 14, by + 4, 5, lit and theme.C.ok or theme.C.raise2)
end

local ROW_BUTTONS = {
  { "remove", "kdel_", "Remover" },
  { "relearn", "krelearn_", "Reaprender" },
  { "send_learn", "klearn_", "Enviar p/ Learn" },
  { "test", "ktest_", "Testar" },
}

-- Botões à direita da linha; devolve a ação pedida.
local function row_buttons(ctx, row, right, cy)
  local x = right
  for _, b in ipairs(ROW_BUTTONS) do
    local relearn = b[1] == "relearn" and relearning(row.id)
    local l = relearn and "Mexa o controle…" or b[3]
    local bw = kit.size(ctx, "button", l) + 24
    x = x - bw
    if kit.button(ctx, b[2] .. row.id, l, x, cy + 4, 28, { w = bw, active = relearn }) then
      return relearn and "cancel_learn" or b[1]
    end
    x = x - 6
  end
end

local function buttons_width(ctx)
  local w = 0
  for _, b in ipairs(ROW_BUTTONS) do
    w = w + kit.size(ctx, "button", b[1] == "relearn" and "Mexa o controle…" or b[3]) + 30
  end
  return w
end

-- O campo do CC tem os botões - e +, quadrados da altura do campo: a
-- largura soma os dois e o espaço de "127", na fonte das linhas.
local function cc_width(ctx)
  local body = body_font(ctx)
  local digits = ImGui.CalcTextSize(ctx, "1270") or 36
  local frame = ImGui.GetFrameHeight(ctx) or 34
  theme.pop_font(ctx, body)
  return math.ceil(digits + 22 + (frame + 6) * 2)
end

local function rows_table(ctx, dl, ix, iw, cy, now)
  local rows = kcc.rows()
  if #rows == 0 then
    return cy + kit.wrapped(ctx, "small", ix, cy, iw, theme.C.muted,
      "Nenhum controle ainda. Clique em Aprender vários e mexa os knobs, faders e botões que devem mexer no Kontakt.") + 12
  end
  local actions_w = buttons_width(ctx)
  local cc_w = cc_width(ctx)
  local free = iw - actions_w - cc_w - 130 - BAR_W - 28 - GAP * 5
  local cols = { name = ix, name_w = math.max(110, free * 0.55) }
  cols.phys = cols.name + cols.name_w + GAP
  cols.phys_w = math.max(90, free * 0.45)
  cols.cc = cols.phys + cols.phys_w + GAP
  cols.cc_w = cc_w
  cols.kind = cols.cc + cols.cc_w + GAP
  cols.kind_w = 130
  cols.signal = cols.kind + cols.kind_w + GAP
  kit.txt(ctx, dl, "label", cols.name, cy, theme.C.muted, "NOME")
  kit.txt(ctx, dl, "label", cols.phys, cy, theme.C.muted, "CONTROLE")
  kit.txt(ctx, dl, "label", cols.cc, cy, theme.C.muted, "CC")
  kit.txt(ctx, dl, "label", cols.kind, cy, theme.C.muted, "TIPO")
  kit.txt(ctx, dl, "label", cols.signal, cy, theme.C.muted, "SINAL")
  cy = cy + 22
  local warnings = kcc.warnings()
  local act, act_row
  for _, row in ipairs(rows) do
    ImGui.DrawList_AddLine(dl, ix, cy, ix + iw, cy, theme.C.line)
    row_controls(ctx, dl, row, cols, cy + 4)
    row_signal(dl, row, cols.signal, cy + 4, now)
    local a = row_buttons(ctx, row, ix + iw, cy + 4)
    if a then act, act_row = a, row end
    cy = cy + ROW_H
    for _, w in ipairs(warnings[row.id] or {}) do
      cy = cy + kit.wrapped(ctx, "small", cols.name, cy, iw, w.kind == "unmapped" and theme.C.danger or theme.C.queue,
        warning_text(w)) + 4
    end
    cy = cy + 6
  end
  if act == "remove" then
    local m = kcc.mapping(act_row.id)
    if m then feedback.forget(m) end
    kcc.remove(act_row.id)
    name_buf[act_row.id] = nil
  elseif act == "relearn" then
    learn.start({ action = "kontakt_cc", arg = act_row.id })
  elseif act == "cancel_learn" then
    learn.cancel()
  elseif act == "test" then
    kcc.test(act_row.id, now)
  elseif act == "send_learn" then
    kcc.send_learn(act_row.id, now)
  end
  return cy
end

-- ------------------------------------------------------------------ desenho

function M.draw(ctx, x, y, w, h, snap)
  local now = reaper.time_precise()
  local dl = ImGui.GetWindowDrawList(ctx)
  ImGui.DrawList_AddRectFilled(dl, x, y, x + w, y + height, theme.C.panel, theme.R.r2)
  local ix, iw = x + 16, w - 32
  local cy = y + 16
  cy = header(ctx, dl, ix, iw, cy)
  cy = coverage_line(ctx, dl, ix, iw, cy, now)
  cy = banners(ctx, dl, ix, iw, cy, now)
  cy = rows_table(ctx, dl, ix, iw, cy, now)
  height = cy - y + 16
  ImGui.SetCursorScreenPos(ctx, x, y)
  ImGui.Dummy(ctx, w, height)
  return height
end

return M
