-- Modo Editar: faixa de estrutura da música atual sobre a régua de compassos
-- (RF-080–088, RF-095, RF-096) e painel de avisos com correção (RF-091, RF-092).
--
-- Toda mudança passa por core/editor_ops ou core/validator: snap no compasso,
-- nenhuma sobreposição e um passo de undo por operação. O projeto é a fonte
-- da verdade; a tela só redesenha o que o project_model relê.
--
-- Faixa (ferramenta Selecionar): clicar numa seção seleciona e toca a partir
-- dela; arrastar a borda move as duas seções vizinhas juntas. Remover deixa
-- o trecho sem seção. Dividir: clicar
-- divide no compasso. Desenhar: arrastar cria uma seção. Na régua, clicar
-- move o cursor e arrastar desenha. `S` divide no cursor; Ctrl/Cmd+Z desfaz.
--
-- M.init(deps)          ImGui, theme, widgets, perf, layers, model, editor_ops,
--                       validator e kit = { txt, size, button } da performance_view
-- M.draw(ctx, x, y, w, h, snap) -> altura usada
-- M.state()             ferramenta, seleção e mensagem (para testes)

local M = {}

local ImGui, theme, widgets, perf, layers, model, ops, validator, kit

local PROJ = 0
local EPS = 1e-6
local GAP = 12
local SIDE_W = 320
local NARROW_W = 900       -- abaixo disso os avisos vão para baixo
local RULER_H, LANE_H = 26, 92
local EDGE_PX = 6          -- distância do mouse até a borda para arrastá-la
local STATUS_S = 4
local WARN_REFRESH_S = 0.5

local TOOLS = { { "select", "Selecionar" }, { "split", "Dividir" }, { "draw", "Desenhar" } }
local TOOL_HINT = {
  select = "Clique numa seção para tocar a partir dela e editar. Arraste a borda entre duas seções para mover as duas juntas. Clique na régua para mover o cursor; arraste nela para desenhar.",
  split = "Clique num compasso dentro de uma seção para dividir ali. Atalho: S divide no cursor.",
  draw = "Arraste sobre a faixa para criar uma seção, com snap no compasso. Se ela invadir outra, a vizinha é recortada.",
}
local ERRORS = {
  boundary = "Esse ponto já é a borda de uma seção.",
  no_section = "Não há seção nesse ponto para dividir.",
  no_next = "Esta é a última seção da música.",
  no_room = "Não cabe uma seção aí.",
  too_short = "A seção precisa ter pelo menos 1 compasso.",
  empty = "O nome não pode ficar vazio.",
  song_exists = "Já existe uma música nesse ponto.",
  inside_section = "O cursor está no meio de uma seção. Mova-o para a borda de uma seção ou para um trecho sem seção.",
  no_keyboard = "Escolha o teclado nas configurações antes de corrigir.",
}

local st = {
  tool = "select",
  selected = nil,          -- region_idx da seção selecionada
  drag = nil,              -- { kind, t0, t, section?, edge? }
  menu_section = nil,      -- seção do menu de contexto
  status = nil, status_until = 0,
  name_buf = nil, len_buf = nil, buf_for = nil,
  new_song = "Nova música",
  warnings = {}, warn_at = -math.huge, warn_count = nil,
}

function M.init(deps)
  ImGui, theme, widgets = deps.ImGui, deps.theme, deps.widgets
  perf, layers, model = deps.perf, deps.layers, deps.model
  ops, validator, kit = deps.editor_ops, deps.validator, deps.kit
  st.tool, st.selected, st.drag, st.menu_section = "select", nil, nil, nil
  st.status, st.status_until, st.buf_for = nil, 0, nil
  st.warnings, st.warn_at, st.warn_count = {}, -math.huge, nil
end

function M.state() return st end

-- ------------------------------------------------------------------ apoio

local function now() return reaper.time_precise() end

local function say(text)
  st.status, st.status_until = text, now() + STATUS_S
end

-- Mensagem do resultado de uma operação do editor.
local function report(ok, err, done)
  if ok then
    if done then say(done) end
  else
    say(ERRORS[err] or ("Não foi possível: " .. tostring(err)))
  end
  return ok
end

-- Índice do compasso (0-based) mais próximo de `t`.
local function bar_at(t)
  local beat, measure, cml = reaper.TimeMap2_timeToBeats(PROJ, t)
  if beat >= cml / 2 - EPS then measure = measure + 1 end
  return measure
end

local function bars(a, b) return bar_at(b) - bar_at(a) end

local function hex_to_native(hex)
  local v = tonumber(hex:gsub("^#", ""), 16)
  return reaper.ColorToNative((v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF) | 0x1000000
end

local CHIP_COLOR = {}
for _, c in ipairs(require("ui.theme").SECTION_COLORS) do CHIP_COLOR[c.name] = c.color end

local function section_by_idx(song, idx)
  for _, s in ipairs(song and song.sections or {}) do
    if s.region_idx == idx then return s end
  end
end

local function section_at(song, t)
  for _, s in ipairs(song.sections) do
    if t >= s.start_pos - EPS and t < s.end_pos - EPS then return s end
  end
end

local function cursor_pos(snap)
  return snap.playing and snap.pos or reaper.GetCursorPosition()
end

local function panel(dl, x, y, w, h)
  ImGui.DrawList_AddRectFilled(dl, x, y, x + w, y + h, theme.C.panel, theme.R.r2)
end

-- Texto com quebra de linha por palavra em `w`; retorna a altura.
local function wrapped(ctx, style, x, y, w, color, text)
  local dl = ImGui.GetWindowDrawList(ctx)
  local pushed = theme.font(ctx, style)
  local line, cy, lh = nil, y, 0
  local function flush()
    if not line then return end
    local _, th = ImGui.CalcTextSize(ctx, line)
    lh = th
    ImGui.DrawList_AddText(dl, x, cy, color, line)
    cy = cy + th + 3
  end
  for word in text:gmatch("%S+") do
    local try = line and (line .. " " .. word) or word
    if line and ImGui.CalcTextSize(ctx, try) > w then
      flush()
      line = word
    else
      line = try
    end
  end
  flush()
  theme.pop_font(ctx, pushed)
  return math.max(lh, cy - y - 3)
end

-- ------------------------------------------------------------------ operações

local function play_from(section)
  st.selected = section.region_idx
  perf.trigger_section(section)
  say("Tocando a partir de " .. section.name .. ".")
end

local function split_at(song, t)
  local at = ops.snap(t)
  local ok, err = ops.split(song, t)
  report(ok, err, string.format("Dividida no compasso %d.", bar_at(at) + 1))
end

local function draw_section(song, a, b)
  local ok, name = ops.draw(song, a, b)
  if ok then
    model.refresh(PROJ)
    local created = section_at(model.song_at(ops.snap(math.min(a, b))) or song, ops.snap(math.min(a, b)))
    if created then st.selected = created.region_idx end
    say(string.format('Seção "%s" criada. Vizinhas recortadas, se havia.', name))
  else
    report(false, name)
  end
end

local function remove(section)
  ops.remove(section)
  if st.selected == section.region_idx then st.selected = nil end
  say(section.name .. " removida. O trecho fica sem seção e toca normalmente.")
end

local function undo()
  local label = reaper.Undo_CanUndo2(PROJ)
  if not label then return end
  reaper.Undo_DoUndo2(PROJ)
  say("Desfeito: " .. label)
end

local function shortcuts(ctx, song, snap)
  if not ImGui.IsWindowFocused(ctx) or ImGui.IsAnyItemActive(ctx) then return end
  local mod = ImGui.IsKeyDown(ctx, ImGui.Mod_Ctrl) or (ImGui.Mod_Super and ImGui.IsKeyDown(ctx, ImGui.Mod_Super))
  if mod and ImGui.IsKeyPressed(ctx, ImGui.Key_Z, false) then
    if ImGui.IsKeyDown(ctx, ImGui.Mod_Shift) then
      local label = reaper.Undo_CanRedo2(PROJ)
      if label then reaper.Undo_DoRedo2(PROJ); say("Refeito: " .. label) end
    else
      undo()
    end
  elseif not mod and song and ImGui.IsKeyPressed(ctx, ImGui.Key_S, false) then
    split_at(song, cursor_pos(snap))
  end
end

-- ------------------------------------------------------------------ músicas

local function song_bar(ctx, x, y, w, snap)
  local dl = ImGui.GetWindowDrawList(ctx)
  local h = 48
  panel(dl, x, y, w, h)
  local cx = x + 8
  local plus_w = kit.size(ctx, "button", "Música") + 46
  for i, song in ipairs(model.songs()) do
    local label = i .. ". " .. song.name
    local bw = kit.size(ctx, "button", label) + 24
    if cx + bw > x + w - plus_w - 16 then break end
    local current = snap.song and snap.song.id == song.id
    if kit.button(ctx, "esong" .. i, label, cx, y + 8, 32, { active = current, w = bw }) then
      perf.goto_song(i)
      st.selected = nil
    end
    cx = cx + bw + 6
  end
  if kit.button(ctx, "add_song", "Música", x + w - plus_w - 8, y + 8, 32, { icon = "plus", w = plus_w }) then
    ImGui.OpenPopup(ctx, "new_song")
  end
  if ImGui.BeginPopup(ctx, "new_song") then
    ImGui.Text(ctx, "Nova música no cursor")
    ImGui.SetNextItemWidth(ctx, 220)
    local _, name = ImGui.InputText(ctx, "##new_song", st.new_song)
    st.new_song = name
    if ImGui.Button(ctx, "Criar") or ImGui.IsKeyPressed(ctx, ImGui.Key_Enter, false) then
      local nm = st.new_song:gsub("^%s+", ""):gsub("%s+$", "")
      if nm ~= "" then
        local ok, err = ops.create_song(model.songs(), reaper.GetCursorPosition(), nm)
        report(ok, err, 'Música "' .. nm .. '" criada no cursor, com uma seção até a próxima música.')
        ImGui.CloseCurrentPopup(ctx)
      end
    end
    ImGui.EndPopup(ctx)
  end
  return h
end

-- ------------------------------------------------------------------ faixa de estrutura

local function strip(ctx, x, y, w, song, snap)
  local dl = ImGui.GetWindowDrawList(ctx)
  local span = math.max(song.end_pos - song.start_pos, EPS)
  local function to_x(t) return x + (t - song.start_pos) / span * w end
  local function to_t(px) return song.start_pos + math.max(0, math.min(1, (px - x) / w)) * span end
  local lane_y = y + RULER_H + 8

  -- régua: um traço por compasso, número a cada `step`
  local first, last = bar_at(song.start_pos), bar_at(song.end_pos)
  local n = math.max(1, last - first)
  local step = 1
  while step < 64 and w / n * step < 36 do step = step * 2 end
  ImGui.DrawList_AddLine(dl, x, y + RULER_H, x + w, y + RULER_H, theme.C.line)
  for m = first, last do
    local tx = to_x(reaper.TimeMap2_beatsToTime(PROJ, 0, m))
    local major = (m - first) % step == 0
    ImGui.DrawList_AddLine(dl, tx, y + RULER_H - (major and 11 or 5), tx, y + RULER_H, major and theme.C.faint or theme.C.line2)
    if major and m < last then kit.txt(ctx, dl, "tick", tx + 3, y + 2, theme.C.muted, tostring(m + 1)) end
  end

  -- faixa: trechos sem seção hachurados, seções coloridas
  ImGui.DrawList_AddRectFilled(dl, x, lane_y, x + w, lane_y + LANE_H, theme.C.bg, theme.R.r2)
  for _, g in ipairs(song.gaps or {}) do
    local gx1, gx2 = to_x(g.start_pos), to_x(g.end_pos)
    ImGui.DrawList_PushClipRect(dl, gx1, lane_y, gx2, lane_y + LANE_H, true)
    for hx = gx1 - LANE_H, gx2, 8 do
      ImGui.DrawList_AddLine(dl, hx, lane_y + LANE_H, hx + LANE_H, lane_y, theme.C.raise)
    end
    if gx2 - gx1 > 80 then
      local label = "SEM SEÇÃO"
      kit.txt(ctx, dl, "label", (gx1 + gx2 - kit.size(ctx, "label", label)) / 2, lane_y + LANE_H / 2 - 7, theme.C.faint, label)
    end
    ImGui.DrawList_PopClipRect(dl)
  end
  ImGui.DrawList_AddRect(dl, x, lane_y, x + w, lane_y + LANE_H, theme.C.line2, theme.R.r2)

  local mx, my = ImGui.GetMousePos(ctx)
  local hover_edge
  for _, s in ipairs(song.sections) do
    local sx1, sx2 = to_x(s.start_pos) + 1, to_x(s.end_pos) - 1
    local c = widgets.region_color(s.color)
    local top, bottom = lane_y + 6, lane_y + LANE_H - 6
    ImGui.DrawList_AddRectFilled(dl, sx1, top, sx2, bottom, theme.mix(theme.C.panel, c, 0.32), theme.R.r1 + 2)
    ImGui.DrawList_AddRect(dl, sx1, top, sx2, bottom, theme.mix(theme.C.line2, c, 0.6), theme.R.r1 + 2)
    if s.region_idx == st.selected then
      ImGui.DrawList_AddRect(dl, sx1 - 1, top - 1, sx2 + 1, bottom + 1, theme.C.text, theme.R.r1 + 3, 0, 2)
    end
    ImGui.DrawList_PushClipRect(dl, sx1 + 8, top, sx2 - 8, bottom, true)
    kit.txt(ctx, dl, "button", sx1 + 10, top + 8, theme.C.text, s.name)
    kit.txt(ctx, dl, "small", sx1 + 10, bottom - 22, theme.mix(theme.C.text, c, 0.3), bars(s.start_pos, s.end_pos) .. " comp.")
    ImGui.DrawList_PopClipRect(dl)
    if st.tool == "select" and my >= lane_y and my <= lane_y + LANE_H then
      if math.abs(mx - sx2) <= EDGE_PX then hover_edge = { section = s, edge = "end" }
      elseif math.abs(mx - sx1) <= EDGE_PX and not hover_edge then hover_edge = { section = s, edge = "start" } end
    end
  end

  -- um único botão cobre régua e faixa; o alvo sai da posição do mouse
  ImGui.SetCursorScreenPos(ctx, x, y)
  ImGui.InvisibleButton(ctx, "strip", w, RULER_H + 8 + LANE_H)
  local hovered = ImGui.IsItemHovered(ctx)
  if hovered and (hover_edge or (st.drag and st.drag.kind == "edge")) then
    ImGui.SetMouseCursor(ctx, ImGui.MouseCursor_ResizeEW)
  end
  local t = to_t(mx)
  if ImGui.IsItemActivated(ctx) then
    local on_ruler = my < y + RULER_H + 4
    if on_ruler then st.drag = { kind = "ruler", t0 = t, t = t }
    elseif hover_edge then st.drag = { kind = "edge", t0 = t, t = t, section = hover_edge.section, edge = hover_edge.edge }
    elseif st.tool == "draw" then st.drag = { kind = "draw", t0 = t, t = t }
    elseif st.tool == "split" then st.drag = { kind = "split", t0 = t, t = t }
    else st.drag = { kind = "pick", t0 = t, t = t } end
  end
  local d = st.drag
  if d then d.t = t end
  if hovered and ImGui.IsMouseClicked(ctx, ImGui.MouseButton_Right) then
    st.menu_section = section_at(song, t)
    if st.menu_section then
      st.selected = st.menu_section.region_idx
      ImGui.OpenPopup(ctx, "section_menu")
    end
  end

  -- prévia do arraste
  if d and ImGui.IsItemActive(ctx) then
    local a, b = ops.snap(math.min(d.t0, d.t)), ops.snap(math.max(d.t0, d.t))
    if d.kind == "edge" then
      local gx = to_x(ops.snap(d.t))
      ImGui.DrawList_AddLine(dl, gx, y + RULER_H, gx, lane_y + LANE_H, theme.C.queue, 2)
      kit.txt(ctx, dl, "num", gx + 6, y + RULER_H + 2, theme.C.queue, "comp. " .. (bar_at(d.t) + 1))
    elseif (d.kind == "draw" or d.kind == "ruler") and (b > a + EPS or d.kind == "draw") then
      if b <= a + EPS then
        -- clique sem arrastar desenha o compasso onde caiu
        local _, m = reaper.TimeMap2_timeToBeats(PROJ, d.t0)
        a, b = reaper.TimeMap2_beatsToTime(PROJ, 0, m), reaper.TimeMap2_beatsToTime(PROJ, 0, m + 1)
      end
      local px1, px2 = to_x(a), to_x(b)
      ImGui.DrawList_AddRectFilled(dl, px1, lane_y + 4, px2, lane_y + LANE_H - 4, theme.rgba("#E8EDF5", 0.1), theme.R.r1 + 2)
      ImGui.DrawList_AddRect(dl, px1, lane_y + 4, px2, lane_y + LANE_H - 4, theme.C.text, theme.R.r1 + 2, 0, 2)
      kit.txt(ctx, dl, "num", px1 + 8, lane_y + LANE_H / 2 - 8, theme.C.text, bars(a, b) .. " comp.")
    end
  end

  if d and ImGui.IsItemDeactivated(ctx) then
    st.drag = nil
    local moved = math.abs(bar_at(d.t) - bar_at(d.t0)) >= 1
    if d.kind == "ruler" then
      if moved then draw_section(song, d.t0, d.t)
      else reaper.SetEditCurPos(ops.snap(d.t), true, false) end
    elseif d.kind == "edge" then
      report(ops.resize(song, d.section, d.edge, d.t))
    elseif d.kind == "draw" then
      draw_section(song, d.t0, d.t)
    elseif d.kind == "split" then
      split_at(song, d.t)
    else
      local s = section_at(song, d.t)
      if s then play_from(s) else reaper.SetEditCurPos(ops.snap(d.t), true, false) end
    end
  end

  -- cursor / posição de reprodução
  local pos = snap.pos or 0
  if pos >= song.start_pos and pos <= song.end_pos then
    local px = to_x(pos)
    ImGui.DrawList_AddLine(dl, px, y + 4, px, lane_y + LANE_H, theme.C.text, 2)
    ImGui.DrawList_AddTriangleFilled(dl, px - 5, y + 4, px + 5, y + 4, px, y + 12, theme.C.text)
  end

  -- menu de contexto da seção
  if ImGui.BeginPopup(ctx, "section_menu") then
    local s = st.menu_section
    if s then
      if ImGui.MenuItem(ctx, "Tocar daqui") then play_from(s) end
      if ImGui.MenuItem(ctx, "Juntar com a próxima") then
        report(ops.merge_next(song, s), nil, s.name .. " juntada com a próxima.")
      end
      if ImGui.MenuItem(ctx, "Dividir no cursor") then split_at(song, cursor_pos(snap)) end
      ImGui.Separator(ctx)
      if ImGui.MenuItem(ctx, "Remover seção") then remove(s) end
    end
    ImGui.EndPopup(ctx)
  end

  return RULER_H + 8 + LANE_H
end

local function structure_panel(ctx, x, y, w, song, snap)
  local dl = ImGui.GetWindowDrawList(ctx)
  local pad = 16
  local ix, iw = x + pad, w - 2 * pad
  local cy = y + pad
  local num, denom = reaper.TimeMap_GetTimeSigAtTime(PROJ, song.start_pos)
  local eyebrow = string.format("ESTRUTURA · %d COMPASSOS · %d/%d", bars(song.start_pos, song.end_pos), num, denom)

  -- ferramentas e desfazer, à direita do título
  local undo_label = reaper.Undo_CanUndo2(PROJ)
  local ulabel = undo_label and ("Desfazer: " .. undo_label) or "Desfazer"
  local uw = math.min(260, kit.size(ctx, "button", ulabel) + 24)
  local rx = x + w - pad - uw
  local tools_w = 0
  for _, tl in ipairs(TOOLS) do tools_w = tools_w + kit.size(ctx, "button", tl[2]) + 24 end
  tools_w = tools_w + 4 * (#TOOLS - 1)
  local stack = rx - tools_w - 12 < ix + 220
  local ty = stack and cy + 58 or cy + 4

  local title_h = 52
  kit.txt(ctx, dl, "label", ix, cy, theme.C.muted, eyebrow)
  ImGui.DrawList_PushClipRect(dl, ix, cy, stack and x + w - pad or rx - tools_w - 12, cy + 50, true)
  kit.txt(ctx, dl, "title", ix, cy + 18, theme.C.text, song.name)
  ImGui.DrawList_PopClipRect(dl)

  local tx = stack and ix or rx - tools_w - 12
  for _, tl in ipairs(TOOLS) do
    local clicked, bw = kit.button(ctx, "tool_" .. tl[1], tl[2], tx, ty, 32, { active = st.tool == tl[1] })
    if clicked then st.tool = tl[1] end
    tx = tx + bw + 4
  end
  if kit.button(ctx, "undo", ulabel, stack and tx + 8 or rx, ty, 32, { w = uw }) then undo() end
  cy = cy + (stack and title_h + 44 or title_h)

  -- dica da ferramenta, ou o resultado da última operação
  local msg, color = TOOL_HINT[st.tool], theme.C.muted
  if st.status and now() < st.status_until then msg, color = st.status, theme.C.text end
  cy = cy + wrapped(ctx, "small", ix, cy, iw, color, msg) + 10

  cy = cy + strip(ctx, ix, cy, iw, song, snap) + 10

  if #song.sections == 0 then
    local tip = "Esta música ainda não tem seções. Desenhe na faixa acima ou crie uma seção com a música inteira e divida depois."
    cy = cy + wrapped(ctx, "small", ix, cy, iw, theme.C.muted, tip) + 8
    local bw = kit.size(ctx, "button", "Seção") + 46
    if kit.button(ctx, "add_section", "Seção", ix, cy, 34, { icon = "plus", w = bw }) then
      draw_section(song, song.start_pos, song.end_pos)
    end
    cy = cy + 34 + 6
  end

  return cy - y + pad - 10
end

-- ------------------------------------------------------------------ inspetor

local function inspector(ctx, x, y, w, song, snap)
  local dl = ImGui.GetWindowDrawList(ctx)
  local pad = 16
  local ix, iw = x + pad, w - 2 * pad
  local cy = y + pad
  local sec = section_by_idx(song, st.selected)

  if not sec then
    kit.txt(ctx, dl, "label", ix, cy, theme.C.muted, "SEÇÃO")
    cy = cy + 20
    cy = cy + wrapped(ctx, "small", ix, cy, iw, theme.C.muted,
      "Selecione uma seção na faixa para mudar o nome, a duração e a cor. Os chips dão nome e cor num clique.") + pad
    return cy - y
  end

  if st.buf_for ~= sec.region_idx then
    st.buf_for, st.name_buf, st.len_buf = sec.region_idx, sec.name, bars(sec.start_pos, sec.end_pos)
  end
  local first = bar_at(sec.start_pos) + 1
  kit.txt(ctx, dl, "label", ix, cy, theme.C.muted, "SEÇÃO SELECIONADA")
  local range = string.format("comp. %d–%d", first, bar_at(sec.end_pos))
  kit.txt(ctx, dl, "num", x + w - pad - kit.size(ctx, "num", range), cy - 1, theme.C.faint, range)
  cy = cy + 22

  -- nome: aplica ao sair do campo ou com Enter
  local body = theme.font(ctx, "body")
  ImGui.SetCursorScreenPos(ctx, ix, cy)
  ImGui.SetNextItemWidth(ctx, iw)
  local _, name = ImGui.InputText(ctx, "##sec_name", st.name_buf)
  st.name_buf = name
  if ImGui.IsItemDeactivatedAfterEdit(ctx) and st.name_buf ~= sec.name then
    local ok, final = ops.rename(song, sec, st.name_buf)
    if ok then st.name_buf = final; say('Renomeada para "' .. final .. '".') else report(false, final) end
  end
  theme.pop_font(ctx, body)
  cy = cy + 40

  -- chips: nome e cor num clique; nome repetido ganha número
  local chx = ix
  for _, c in ipairs(theme.SECTION_COLORS) do
    local cw = kit.size(ctx, "button", c.name) + 30
    if chx + cw > ix + iw then chx, cy = ix, cy + 34 end
    ImGui.SetCursorScreenPos(ctx, chx, cy)
    local clicked = ImGui.InvisibleButton(ctx, "chip_" .. c.name, cw, 28)
    local hov = ImGui.IsItemHovered(ctx)
    local col = theme.rgba(c.color)
    ImGui.DrawList_AddRectFilled(dl, chx, cy, chx + cw, cy + 28, theme.mix(theme.C.panel, col, hov and 0.3 or 0.14), 14)
    ImGui.DrawList_AddRect(dl, chx, cy, chx + cw, cy + 28, theme.mix(theme.C.line2, col, 0.45), 14)
    ImGui.DrawList_AddCircleFilled(dl, chx + 13, cy + 14, 4.5, col)
    kit.txt(ctx, dl, "button", chx + 22, cy + 6, theme.C.text, c.name)
    if clicked then
      local ok, final = ops.rename(song, sec, c.name, hex_to_native(CHIP_COLOR[c.name]))
      if ok then st.buf_for = nil; say('Renomeada para "' .. final .. '".') else report(false, final) end
    end
    chx = chx + cw + 6
  end
  cy = cy + 40

  -- duração em compassos
  kit.txt(ctx, dl, "label", ix, cy, theme.C.muted, "DURAÇÃO (COMPASSOS)")
  cy = cy + 18
  body = theme.font(ctx, "body")
  ImGui.SetCursorScreenPos(ctx, ix, cy)
  ImGui.SetNextItemWidth(ctx, 120)
  local _, len = ImGui.InputInt(ctx, "##sec_len", st.len_buf, 1, 4)
  st.len_buf = len
  local len_done = ImGui.IsItemDeactivatedAfterEdit(ctx)
  theme.pop_font(ctx, body)
  if len_done and st.len_buf ~= bars(sec.start_pos, sec.end_pos) then
    local want = st.len_buf
    if report(ops.set_length(song, sec, want)) then
      model.refresh(PROJ)
      local now_sec = section_by_idx(model.song_at(sec.start_pos) or song, sec.region_idx)
      local got = now_sec and bars(now_sec.start_pos, now_sec.end_pos) or want
      st.buf_for = nil
      say(got == want and string.format("%s agora tem %d compassos.", sec.name, got)
        or string.format("A duração ficou em %d compassos: é o máximo antes da próxima seção.", got))
    end
  end
  local pw = kit.size(ctx, "button", "Tocar daqui") + 46
  if kit.button(ctx, "play_from", "Tocar daqui", ix + 132, cy - 2, 36, { icon = "play", w = pw }) then play_from(sec) end
  cy = cy + 46

  local bx = ix
  local nxt
  for i, s in ipairs(song.sections) do if s.region_idx == sec.region_idx then nxt = song.sections[i + 1] end end
  local clicked, bw = kit.button(ctx, "merge", "Juntar com a próxima", bx, cy, 30)
  if clicked then
    if nxt then report(ops.merge_next(song, sec), nil, sec.name .. " juntada com a próxima.") else report(false, "no_next") end
  end
  bx = bx + bw + 6
  if bx + 150 > ix + iw then bx, cy = ix, cy + 36 end
  clicked, bw = kit.button(ctx, "split_cursor", "Dividir no cursor  S", bx, cy, 30)
  if clicked then split_at(song, cursor_pos(snap)) end
  bx = bx + bw + 6
  if bx + 90 > ix + iw then bx, cy = ix, cy + 36 end
  if kit.button(ctx, "remove", "Remover", bx, cy, 30, { accent = theme.C.danger }) then remove(sec) end
  cy = cy + 30 + pad
  return cy - y
end

local function tempo_placeholder(ctx, x, y, w)
  local dl = ImGui.GetWindowDrawList(ctx)
  kit.txt(ctx, dl, "label", x + 16, y + 16, theme.C.muted, "TEMPO E GRID")
  local h = wrapped(ctx, "small", x + 16, y + 38, w - 32, theme.C.faint,
    "Tap tempo e alinhamento do compasso 1 chegam na próxima etapa.")
  return 38 + h + 16
end

-- ------------------------------------------------------------------ avisos

local function refresh_warnings()
  local count = reaper.GetProjectStateChangeCount(PROJ)
  if count == st.warn_count and now() - st.warn_at < WARN_REFRESH_S then return end
  st.warn_count, st.warn_at = count, now()
  local songs = model.songs()
  st.warnings = validator.check(songs, { links = layers.links(songs), keyboard_input = layers.keyboard_input() })
end

local function warnings_panel(ctx, x, y, w, song)
  local dl = ImGui.GetWindowDrawList(ctx)
  local pad = 16
  local ix, iw = x + pad, w - 2 * pad
  local cy = y + pad
  local list = {}
  for _, wn in ipairs(st.warnings) do if song and wn.song == song.name then list[#list + 1] = wn end end
  for _, wn in ipairs(st.warnings) do if not (song and wn.song == song.name) then list[#list + 1] = wn end end

  kit.txt(ctx, dl, "label", ix, cy, theme.C.muted, "AVISOS")
  local count = tostring(#list)
  kit.txt(ctx, dl, "num", x + w - pad - kit.size(ctx, "num", count), cy - 1, #list > 0 and theme.C.queue or theme.C.faint, count)
  cy = cy + 24

  if #list == 0 then
    cy = cy + wrapped(ctx, "small", ix, cy, iw, theme.C.muted,
      "Nenhum problema. Se uma edição manual na régua do REAPER criar sobreposição, região fora de música ou seção fora do compasso, o aviso aparece aqui com a correção.")
    return cy - y + pad
  end

  for i, wn in ipairs(list) do
    local color = wn.severity == "error" and theme.C.danger or theme.C.queue
    local top = cy
    theme.icon(dl, "warn", ix, cy + 1, 14, color)
    local meta = (wn.severity == "error" and "ERRO" or "AVISO") .. " · " .. (wn.song or "Projeto"):upper()
    ImGui.DrawList_PushClipRect(dl, ix + 20, cy, ix + iw, cy + 16, true)
    kit.txt(ctx, dl, "label", ix + 20, cy + 2, color, meta)
    ImGui.DrawList_PopClipRect(dl)
    cy = cy + 20
    cy = cy + wrapped(ctx, "small", ix + 20, cy, iw - 20, theme.C.text, wn.text) + 8
    local fw = math.min(iw - 20, kit.size(ctx, "button", wn.fix_label) + 24)
    if kit.button(ctx, "fix" .. i, wn.fix_label, ix + 20, cy, 30, { w = fw }) then
      local ok, err = validator.apply(wn)
      st.warn_count = nil
      report(ok, err, "Corrigido: " .. wn.fix_label .. ".")
    end
    cy = cy + 30 + 12
    ImGui.DrawList_AddLine(dl, ix, top - 6, ix + iw, top - 6, i > 1 and theme.C.line or 0)
  end
  return cy - y + pad - 12
end

-- ------------------------------------------------------------------ desenho

-- Painel com fundo atrás do conteúdo: a altura só é conhecida depois de
-- desenhar, então o fundo usa a altura medida no ciclo anterior.
local heights = {}
local function panel_behind(ctx, id, x, y, w, fn)
  panel(ImGui.GetWindowDrawList(ctx), x, y, w, heights[id] or 0)
  local h = fn()
  heights[id] = h
  return h
end

function M.draw(ctx, x, y, w, h, snap)
  local song = snap.song
  refresh_warnings()
  shortcuts(ctx, song, snap)

  local narrow = w < NARROW_W
  local mw = narrow and w or w - SIDE_W - GAP
  local cy = y
  cy = cy + song_bar(ctx, x, cy, mw, snap) + GAP

  if not song then
    local dl = ImGui.GetWindowDrawList(ctx)
    kit.txt(ctx, dl, "small", x, cy, theme.C.muted, "Nenhuma música. Use \"+ Música\" para criar a primeira no cursor.")
    cy = cy + 30
  else
    if st.selected and not section_by_idx(song, st.selected) then st.selected = nil end
    cy = cy + panel_behind(ctx, "structure", x, cy, mw, function() return structure_panel(ctx, x, cy, mw, song, snap) end) + GAP
    local two = mw >= 640
    local iw = two and math.floor((mw - GAP) * 0.55) or mw
    local ih = panel_behind(ctx, "inspector", x, cy, iw, function() return inspector(ctx, x, cy, iw, song, snap) end)
    if two then
      local th = panel_behind(ctx, "tempo", x + iw + GAP, cy, mw - iw - GAP, function()
        return tempo_placeholder(ctx, x + iw + GAP, cy, mw - iw - GAP)
      end)
      cy = cy + math.max(ih, th) + GAP
    else
      cy = cy + ih + GAP
      cy = cy + panel_behind(ctx, "tempo", x, cy, mw, function() return tempo_placeholder(ctx, x, cy, mw) end) + GAP
    end
  end

  local side_y = narrow and cy or y
  local sx, sw = narrow and x or x + mw + GAP, narrow and w or SIDE_W
  local wh = panel_behind(ctx, "warnings", sx, side_y, sw, function() return warnings_panel(ctx, sx, side_y, sw, song) end)
  local bottom = math.max(cy, side_y + wh + GAP)

  ImGui.SetCursorScreenPos(ctx, x, y)
  ImGui.Dummy(ctx, w, math.max(0, bottom - y))
  return bottom - y
end

return M
