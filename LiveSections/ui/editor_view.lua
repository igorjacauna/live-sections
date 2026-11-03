-- Modo Editar: faixa de estrutura da música atual sobre a régua de compassos
-- (RF-080–088, RF-095, RF-096), painel de tempo com tap e alinhamento do
-- compasso 1 (RF-097–099) e painel de avisos com correção (RF-091, RF-092).
--
-- Toda mudança passa por core/editor_ops ou core/validator: snap no compasso,
-- nenhuma sobreposição e um passo de undo por operação. O projeto é a fonte
-- da verdade; a tela só redesenha o que o project_model relê.
--
-- Faixa (ferramenta Selecionar): clicar numa seção seleciona (parado, o
-- cursor vai para o início dela; clicar de novo põe o cursor no compasso
-- clicado); duplo clique toca a partir dela; arrastar a
-- borda move as duas seções vizinhas juntas. O botão alterna Tocar daqui /
-- Pausar / Continuar; Espaço toca da seção selecionada e para (para ouvir
-- trechos rápido), como o Stop. Remover deixa
-- o trecho sem seção. Dividir: clicar
-- divide no compasso. Desenhar: arrastar cria uma seção. Na régua, clicar
-- move o cursor e arrastar desenha. `S` divide no cursor; Ctrl/Cmd+Z desfaz.
-- Zoom: Ctrl/Cmd+roda no ponto do mouse ou os botões −/+/Inteira; com zoom,
-- a roda rola e o mini-mapa abaixo mostra e arrasta o trecho visível. Tocando,
-- a faixa acompanha o cursor quando ele sai do trecho visível.
--
-- M.init(deps)          ImGui, theme, widgets, perf, layers, model, editor_ops,
--                       validator, tempo_align, kontakt_wizard e
--                       kit = { txt, size, button } da performance_view
-- M.tap()               um toque do tap tempo (ação mapeável tap_tempo)
-- M.draw(ctx, x, y, w, h, snap) -> altura usada
-- M.state()             ferramenta, seleção e mensagem (para testes)

local chart = require("core.chart")
local notes = require("core.song_notes")

local M = {}

local ImGui, theme, widgets, perf, layers, model, ops, validator, kit, tempo, wizard, kontakt_cc

local PROJ = 0
local EPS = 1e-6
local GAP = 12
local SIDE_W = 320
local NARROW_W = 900       -- abaixo disso os avisos vão para baixo
local RULER_H, LANE_H = 26, 92
local NAV_H = 24           -- mini-mapa e botões de zoom abaixo da faixa
local ZOOM_STEP = 1.5
local MIN_VIEW_BARS = 2    -- zoom máximo: 2 compassos na faixa
local SCROLL_STEP = 0.1    -- fração do trecho visível por passo da roda
local EDGE_PX = 6          -- distância do mouse até a borda para arrastá-la
local MAGNET_PX = 10       -- ímã: bordas de seção e início/fim da música
local STATUS_S = 4
local WARN_REFRESH_S = 0.5

local TOOLS = { { "select", "Selecionar" }, { "split", "Dividir" }, { "draw", "Desenhar" } }
local TOOL_HINT = {
  select = "Clique numa seção para editar; clique de novo nela para pôr o cursor no compasso. Tocar daqui (ou Espaço) toca do cursor. Duplo clique toca do início dela. Arraste a borda entre duas seções para mover as duas juntas. Clique na régua para mover o cursor; arraste nela para desenhar. Ctrl/Cmd+roda dá zoom; com zoom, a roda rola.",
  split = "Clique num compasso dentro de uma seção para dividir ali. Atalho: S divide no cursor.",
  draw = "Arraste sobre a faixa para criar uma seção, com snap no compasso e ímã nas bordas das seções e no início e fim da música. Se ela invadir outra, a vizinha é recortada.",
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
  view = nil,              -- { song, t0, span, play_in }: trecho visível da faixa
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
  tempo, wizard = deps.tempo_align, deps.kontakt_wizard
  kontakt_cc = deps.kontakt_cc
  st.round, st.tap_bpm = "int", nil
  st.tool, st.selected, st.drag, st.menu_section = "select", nil, nil, nil
  st.view = nil
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

local function wrapped(...) return kit.wrapped(...) end

-- ------------------------------------------------------------------ operações

-- Toca a partir da seção; com `at`, do ponto `at` dentro dela.
local function play_from(section, at)
  st.selected = section.region_idx
  perf.trigger_section(section, at)
  if at then
    local _, measure = reaper.TimeMap2_timeToBeats(PROJ, at)
    say(string.format("Tocando de %s, compasso %d.", section.name, measure + 1))
  else
    say("Tocando a partir de " .. section.name .. ".")
  end
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

-- Tocar daqui / Pausar / Continuar: parado, toca do cursor (a seção onde ele
-- está passa a ser a selecionada); tocando, pausa; pausado, continua de onde
-- parou. Selecionar uma seção já leva o cursor ao início dela.
local function transport_state()
  local ps = reaper.GetPlayState()
  if ps & 2 == 2 then return "paused" end
  if ps & 1 == 1 then return "playing" end
  return "stopped"
end

local PLAY_LABEL = { stopped = "Tocar daqui", playing = "Pausar", paused = "Continuar" }
local PLAY_ICON = { stopped = "play", playing = "stop", paused = "play" }

local function toggle_play(song)
  local state = transport_state()
  if state == "stopped" then
    local cur = reaper.GetCursorPosition()
    local section = song and section_at(song, cur)
    if section then
      play_from(section, cur > section.start_pos + EPS and cur or nil)
    else
      perf.play_stop()
    end
  else
    reaper.OnPauseButton()
    say(state == "playing" and "Pausado." or "Continuando.")
  end
end

local function stop()
  if transport_state() == "playing" then perf.play_stop() else reaper.OnStopButton() end
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
  elseif not mod and ImGui.IsKeyPressed(ctx, ImGui.Key_Space, false) then
    -- ouvir trechos rápido: toca do cursor e para
    if transport_state() == "stopped" then toggle_play(song) else stop() end
  end
end

-- ------------------------------------------------------------------ músicas

local function song_bar(ctx, x, y, w, snap)
  local dl = ImGui.GetWindowDrawList(ctx)
  local h = 48
  panel(dl, x, y, w, h)
  local cx = x + 8
  local plus_w = kit.size(ctx, "button", "Música") + 46
  local ren_w = kit.size(ctx, "button", "Renomear") + 24
  local chart_w = kit.size(ctx, "button", "Cifra") + 24
  local note_w = kit.size(ctx, "button", "Anotação") + 24
  for i, song in ipairs(model.songs()) do
    local label = i .. ". " .. song.name
    local bw = kit.size(ctx, "button", label) + 24
    if cx + bw > x + w - plus_w - ren_w - chart_w - note_w - 34 then break end
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
  if snap.song and kit.button(ctx, "rename_song", "Renomear", x + w - plus_w - ren_w - 14, y + 8, 32, { w = ren_w }) then
    st.song_name = snap.song.name
    ImGui.OpenPopup(ctx, "rename_song")
  end
  if snap.song and kit.button(ctx, "song_chart", "Cifra", x + w - plus_w - ren_w - chart_w - 20, y + 8, 32, { w = chart_w }) then
    st.chart_song, st.chart_buf = snap.song, chart.get_text(snap.song)
    st.chart_open = true
  end
  if snap.song and kit.button(ctx, "song_note", "Anotação", x + w - plus_w - ren_w - chart_w - note_w - 26, y + 8, 32, { w = note_w }) then
    st.note_song, st.note_buf = snap.song, notes.get(snap.song)
    ImGui.OpenPopup(ctx, "song_note")
  end
  if ImGui.BeginPopup(ctx, "song_note") then
    ImGui.Text(ctx, "Anotação de " .. (st.note_song and st.note_song.name or ""))
    ImGui.TextColored(ctx, theme.C.faint, "Curta: tom, como começa a intro, uma dica. Aparece no Performance,\nno Palco, na janela de cifra e no celular. Ex.: Tom: G · Intro: piano sozinho, 4 comp.")
    local _, buf = ImGui.InputTextMultiline(ctx, "##song_note", st.note_buf or "", 460, 84)
    st.note_buf = buf
    local left = notes.MAX_CHARS - #(st.note_buf or "")
    ImGui.TextColored(ctx, left < 0 and theme.C.danger or theme.C.faint, string.format("%d caracteres restantes", math.max(0, left)))
    if ImGui.Button(ctx, "Salvar") and st.note_song then
      notes.set(st.note_song, st.note_buf)
      reaper.MarkProjectDirty(PROJ)
      say("Anotação de " .. st.note_song.name .. " salva no projeto.")
      ImGui.CloseCurrentPopup(ctx)
    end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Cancelar") then ImGui.CloseCurrentPopup(ctx) end
    ImGui.EndPopup(ctx)
  end
  if ImGui.BeginPopup(ctx, "rename_song") then
    ImGui.Text(ctx, "Nome da música")
    ImGui.SetNextItemWidth(ctx, 220)
    local _, name = ImGui.InputText(ctx, "##song_name", st.song_name or "")
    st.song_name = name
    if ImGui.Button(ctx, "Renomear") or ImGui.IsKeyPressed(ctx, ImGui.Key_Enter, false) then
      local ok, final = ops.rename_song(snap.song, st.song_name)
      report(ok, final, ok and ('Música renomeada para "' .. tostring(final) .. '".') or nil)
      if ok then ImGui.CloseCurrentPopup(ctx) end
    end
    ImGui.EndPopup(ctx)
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

-- ------------------------------------------------------------------ cifra

local CHART_HELP = "Cole a cifra da música (estilo Cifra Club). Cada seção começa com um cabeçalho com o nome dela entre colchetes, como [Intro], [Verso], [Refrão]. Os acordes ficam na linha de cima da letra, em fonte monoespaçada. Para acompanhar compasso a compasso, escreva uma linha em grade: | G | D | Em | C |"

local function chart_modal(ctx)
  if st.chart_open then ImGui.OpenPopup(ctx, "Cifra da música"); st.chart_open = false end
  ImGui.SetNextWindowSize(ctx, 900, 620, ImGui.Cond_Appearing)
  if not ImGui.BeginPopupModal(ctx, "Cifra da música", true) then return end
  local song = st.chart_song
  local w, h = ImGui.GetContentRegionAvail(ctx)
  ImGui.TextColored(ctx, theme.C.muted, (song and song.name or ""):upper())
  ImGui.PushTextWrapPos(ctx, 0)
  ImGui.TextColored(ctx, theme.C.faint, CHART_HELP)
  ImGui.PopTextWrapPos(ctx)

  local list_w = 230
  local mono = theme.font(ctx, "num")
  local _, buf = ImGui.InputTextMultiline(ctx, "##chart_text", st.chart_buf or "", w - list_w - 12, h - 130)
  theme.pop_font(ctx, mono)
  st.chart_buf = buf
  ImGui.SameLine(ctx)

  -- seções da música e se cada uma achou o trecho dela
  ImGui.BeginGroup(ctx)
  ImGui.Text(ctx, "Seções")
  local parsed = chart.parse(st.chart_buf or "")
  for _, sec in ipairs(song and song.sections or {}) do
    local units = chart.units_for(parsed, sec)
    if units then
      ImGui.TextColored(ctx, theme.C.ok, sec.name .. "  ok")
    else
      ImGui.TextColored(ctx, theme.C.queue, sec.name .. "  sem cifra")
    end
  end
  ImGui.EndGroup(ctx)

  ImGui.Separator(ctx)
  if ImGui.Button(ctx, "Salvar") and song then
    chart.set_text(song, st.chart_buf or "")
    reaper.MarkProjectDirty(PROJ)
    say("Cifra de " .. song.name .. " salva no projeto.")
    ImGui.CloseCurrentPopup(ctx)
  end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "Cancelar") then ImGui.CloseCurrentPopup(ctx) end
  ImGui.EndPopup(ctx)
end

-- ------------------------------------------------------------------ faixa de estrutura

-- ------------------------------------------------------------------ zoom da faixa

local function full_span(song) return math.max(song.end_pos - song.start_pos, EPS) end

-- Trecho visível da faixa, sempre dentro da música; volta à música inteira
-- ao trocar de música.
local function view_of(song)
  local full = full_span(song)
  local v = st.view
  if not v or v.song ~= song.id then
    v = { song = song.id, t0 = song.start_pos, span = full }
    st.view = v
  end
  local _, m = reaper.TimeMap2_timeToBeats(PROJ, song.start_pos)
  local bar = reaper.TimeMap2_beatsToTime(PROJ, 0, m + 1) - reaper.TimeMap2_beatsToTime(PROJ, 0, m)
  v.span = math.max(math.min(full, MIN_VIEW_BARS * bar), math.min(full, v.span))
  v.t0 = math.max(song.start_pos, math.min(song.end_pos - v.span, v.t0))
  return v
end

local function zoomed(song) return view_of(song).span < full_span(song) - EPS end

-- Zoom por `factor` (>1 aproxima) mantendo `anchor` no mesmo ponto da faixa.
local function zoom(song, factor, anchor)
  local v = view_of(song)
  anchor = anchor or v.t0 + v.span / 2
  local k = (anchor - v.t0) / v.span
  v.span = v.span / factor
  v.t0 = anchor - k * v.span
  view_of(song)
end

-- A roda do mouse sobre a faixa não rola a janela (ReaImGui sem a função: rola
-- as duas).
local function claim_wheel(ctx)
  local ok, f = pcall(function() return ImGui.SetItemKeyOwner end)
  local ok2, key = pcall(function() return ImGui.Key_MouseWheelY end)
  if ok and f and ok2 and key then f(ctx, key) end
end

-- Mini-mapa (música inteira, trecho visível arrastável) e botões de zoom.
local function strip_nav(ctx, x, y, w, song)
  local dl = ImGui.GetWindowDrawList(ctx)
  local v = view_of(song)
  local full = full_span(song)
  local bx = x + w
  local function zbutton(id, label, fn)
    local bw = kit.size(ctx, "small", label) + 20
    bx = bx - bw
    if kit.button(ctx, id, label, bx, y, NAV_H, { w = bw, style = "small" }) then fn() end
    bx = bx - 4
  end
  zbutton("zoom_all", "Inteira", function() v.t0, v.span = song.start_pos, full end)
  zbutton("zoom_in", "+", function() zoom(song, ZOOM_STEP) end)
  zbutton("zoom_out", "−", function() zoom(song, 1 / ZOOM_STEP) end)
  local mw = bx - 4 - x
  if mw < 40 then return end

  local function mx_of(t) return x + (t - song.start_pos) / full * mw end
  ImGui.DrawList_AddRectFilled(dl, x, y, x + mw, y + NAV_H, theme.C.bg, theme.R.r1)
  for _, s in ipairs(song.sections) do
    local c = widgets.region_color(s.color)
    ImGui.DrawList_AddRectFilled(dl, mx_of(s.start_pos) + 1, y + 5, mx_of(s.end_pos) - 1, y + NAV_H - 5, theme.mix(theme.C.panel, c, 0.5), 2)
  end
  ImGui.SetCursorScreenPos(ctx, x, y)
  ImGui.InvisibleButton(ctx, "minimap", mw, NAV_H)
  if zoomed(song) then
    local vx1, vx2 = mx_of(v.t0), mx_of(v.t0 + v.span)
    ImGui.DrawList_AddRectFilled(dl, vx1, y, vx2, y + NAV_H, theme.rgba("#E8EDF5", 0.12), theme.R.r1)
    ImGui.DrawList_AddRect(dl, vx1, y, vx2, y + NAV_H, theme.C.text, theme.R.r1, 0, 2)
    if ImGui.IsItemActive(ctx) then
      local mx = ImGui.GetMousePos(ctx)
      v.t0 = song.start_pos + (mx - x) / mw * full - v.span / 2
      view_of(song)
    end
  end
  ImGui.DrawList_AddRect(dl, x, y, x + mw, y + NAV_H, theme.C.line2, theme.R.r1)
end

local function strip(ctx, x, y, w, song, snap)
  local dl = ImGui.GetWindowDrawList(ctx)
  local v = view_of(song)
  local v0, span = v.t0, v.span
  local function to_x(t) return x + (t - v0) / span * w end
  local function to_t(px) return v0 + math.max(0, math.min(1, (px - x) / w)) * span end
  local lane_y = y + RULER_H + 8

  -- tocando, a faixa acompanha o cursor que sai do trecho visível (não no
  -- meio de um arraste; se você rolou para longe, ela fica onde está)
  local pos = snap.pos or 0
  local inside = pos >= v0 - EPS and pos <= v0 + span + EPS
  if snap.playing and not inside and v.play_in and not st.drag then
    v.t0 = pos - span * SCROLL_STEP
    view_of(song)
    v0 = v.t0
    inside = true
  end
  v.play_in = inside

  ImGui.DrawList_PushClipRect(dl, x, y, x + w, lane_y + LANE_H, true)

  -- régua: um traço por compasso, número a cada `step`
  local first, last = bar_at(song.start_pos), bar_at(song.end_pos)
  local _, vfirst = reaper.TimeMap2_timeToBeats(PROJ, v0)
  local _, vlast = reaper.TimeMap2_timeToBeats(PROJ, v0 + span)
  vfirst, vlast = math.max(first, vfirst), math.min(last, vlast + 1)
  local n = math.max(1, vlast - vfirst)
  local step = 1
  while step < 64 and w / n * step < 36 do step = step * 2 end
  ImGui.DrawList_AddLine(dl, x, y + RULER_H, x + w, y + RULER_H, theme.C.line)
  for m = vfirst, vlast do
    local tx = to_x(reaper.TimeMap2_beatsToTime(PROJ, 0, m))
    local major = (m - first) % step == 0
    ImGui.DrawList_AddLine(dl, tx, y + RULER_H - (major and 11 or 5), tx, y + RULER_H, major and theme.C.faint or theme.C.line2)
    if major and m < last then kit.txt(ctx, dl, "tick", tx + 3, y + 2, theme.C.muted, tostring(m + 1)) end
  end

  -- faixa: trechos sem seção hachurados, seções coloridas
  ImGui.DrawList_AddRectFilled(dl, x, lane_y, x + w, lane_y + LANE_H, theme.C.bg, theme.R.r2)
  for _, g in ipairs(song.gaps or {}) do
    local gx1, gx2 = math.max(x, to_x(g.start_pos)), math.min(x + w, to_x(g.end_pos))
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
    -- com zoom, o nome segue visível mesmo com o início da seção fora da faixa
    local lx = math.max(sx1, x) + 10
    ImGui.DrawList_PushClipRect(dl, math.max(sx1, x) + 8, top, math.min(sx2, x + w) - 8, bottom, true)
    kit.txt(ctx, dl, "button", lx, top + 8, theme.C.text, s.name)
    kit.txt(ctx, dl, "small", lx, bottom - 22, theme.mix(theme.C.text, c, 0.3), bars(s.start_pos, s.end_pos) .. " comp.")
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
  -- roda: Ctrl/Cmd dá zoom no ponto do mouse; com zoom, rola
  if hovered then
    local wy, wx = ImGui.GetMouseWheel(ctx)
    wy, wx = wy or 0, wx or 0
    local mod = ImGui.IsKeyDown(ctx, ImGui.Mod_Ctrl) or (ImGui.Mod_Super and ImGui.IsKeyDown(ctx, ImGui.Mod_Super))
    if mod or zoomed(song) then claim_wheel(ctx) end
    if mod and wy ~= 0 then
      zoom(song, ZOOM_STEP ^ wy, to_t(mx))
    elseif not mod and (wy ~= 0 or wx ~= 0) and zoomed(song) then
      v.t0 = v.t0 - (wy + wx) * v.span * SCROLL_STEP
      view_of(song)
    end
  end
  -- ímã: perto de uma borda de seção ou do início/fim da música, gruda nela
  local function magnet(raw, skip)
    local best, dist = nil, MAGNET_PX / w * span
    local function try(c)
      if c ~= skip and math.abs(raw - c) <= dist then best, dist = c, math.abs(raw - c) end
    end
    try(song.start_pos); try(song.end_pos)
    for _, s in ipairs(song.sections) do try(s.start_pos); try(s.end_pos) end
    return best or raw, best ~= nil
  end
  -- posição final de um ponto do arraste: o ímã, senão o compasso mais próximo
  local function settle(raw, hit)
    if hit then return raw end
    return ops.snap(raw)
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
  if d then
    local skip = d.kind == "edge" and (d.edge == "end" and d.section.end_pos or d.section.start_pos) or nil
    if not d.mag0 then d.t0, d.hit0 = magnet(d.t0, skip); d.mag0 = true end
    d.t, d.hit = magnet(t, skip)
  end
  if hovered and ImGui.IsMouseClicked(ctx, ImGui.MouseButton_Right) then
    st.menu_section = section_at(song, t)
    if st.menu_section then
      st.selected = st.menu_section.region_idx
      ImGui.OpenPopup(ctx, "section_menu")
    end
  end

  -- prévia do arraste
  if d and ImGui.IsItemActive(ctx) then
    local p0, p1 = settle(d.t0, d.hit0), settle(d.t, d.hit)
    local a, b = math.min(p0, p1), math.max(p0, p1)
    if d.hit then
      local gx = to_x(d.t)
      ImGui.DrawList_AddLine(dl, gx, y, gx, lane_y + LANE_H, theme.C.loop, 2)
    end
    if d.kind == "edge" then
      local gx = to_x(p1)
      ImGui.DrawList_AddLine(dl, gx, y + RULER_H, gx, lane_y + LANE_H, theme.C.queue, 2)
      kit.txt(ctx, dl, "num", gx + 6, y + RULER_H + 2, theme.C.queue, "comp. " .. (bar_at(p1) + 1))
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
    local moved = math.abs(settle(d.t, d.hit) - settle(d.t0, d.hit0)) > EPS
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
      if s and ImGui.IsMouseDoubleClicked(ctx, ImGui.MouseButton_Left) then
        play_from(s)
      elseif s and s.region_idx == st.selected then
        -- clicar de novo na seção selecionada põe o cursor no compasso clicado
        if not snap.playing then
          local _, measure = reaper.TimeMap2_timeToBeats(PROJ, d.t)
          reaper.SetEditCurPos(reaper.TimeMap2_beatsToTime(PROJ, 0, measure), true, false)
        end
      elseif s then
        st.selected = s.region_idx
        if not snap.playing then reaper.SetEditCurPos(s.start_pos, true, false) end
      elseif not snap.playing then
        reaper.SetEditCurPos(ops.snap(d.t), true, false)
      end
    end
  end

  -- cursor / posição de reprodução
  if pos >= song.start_pos and pos <= song.end_pos then
    local px = to_x(pos)
    ImGui.DrawList_AddLine(dl, px, y + 4, px, lane_y + LANE_H, theme.C.text, 2)
    ImGui.DrawList_AddTriangleFilled(dl, px - 5, y + 4, px + 5, y + 4, px, y + 12, theme.C.text)
  end
  ImGui.DrawList_PopClipRect(dl)

  strip_nav(ctx, x, lane_y + LANE_H + 8, w, song)

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

  return RULER_H + 8 + LANE_H + 8 + NAV_H
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
  local state = transport_state()
  local pw = kit.size(ctx, "button", "Tocar daqui") + 46
  if kit.button(ctx, "play_from", PLAY_LABEL[state], ix + 132, cy - 2, 36,
    { icon = PLAY_ICON[state], w = pw, active = state ~= "stopped", accent = state == "playing" and theme.C.ok or nil }) then
    toggle_play(song)
  end
  if ix + 132 + pw + 6 + 40 <= ix + iw
    and kit.button(ctx, "stop", "", ix + 132 + pw + 6, cy - 2, 36, { icon = "stop", w = 40 }) then
    stop()
  end
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

-- ------------------------------------------------------------------ tempo

local METRONOME = 40364   -- Options: Toggle metronome
local ROUNDS = { { "exact", "Exato" }, { "int", "Inteiro" }, { "half", "Meio BPM" } }
local SIGNATURES = { { 2, 4 }, { 3, 4 }, { 4, 4 }, { 5, 4 }, { 6, 8 }, { 7, 8 }, { 12, 8 } }
local TEMPO_ERRORS = {
  outside_song = "O cursor precisa estar dentro da música atual.",
  no_bpm = "Toque o tap pelo menos 4 vezes antes.",
  no_downbeat = "Marque o compasso 1 antes de ajustar a posição dele.",
  bad_bpm = "Digite um BPM entre 20 e 400.",
  bad_signature = "Digite a fórmula como 7/8: de 1 a 32 tempos, sobre 1, 2, 4, 8, 16 ou 32.",
  out_of_range = "O ajuste sairia da música.",
}

local function next_song_of(song)
  local songs = model.songs()
  for i, s in ipairs(songs) do if s.id == song.id then return songs[i + 1] end end
end

local function fmt_bpm(v)
  local s = string.format("%.2f", v):gsub("0+$", ""):gsub("%.$", "")
  return (s:gsub("%.", ","))
end

-- Um toque do tap tempo (botão da tela ou controle mapeado).
function M.tap()
  local bpm = tempo.tap(reaper.time_precise())
  st.tap_bpm = bpm
  return bpm
end

local function tap_value()
  return st.tap_bpm and tempo.round(st.tap_bpm, st.round ~= "exact" and st.round or nil)
end

-- O resultado aparece no próprio painel de tempo, perto do botão clicado.
local function tempo_report(ok, err, done)
  local text = ok and done or (TEMPO_ERRORS[err] or ERRORS[err] or ("Não foi possível: " .. tostring(err)))
  st.tempo_msg = { text = text, err = not ok, ["until"] = now() + STATUS_S }
end

-- "7/8" -> 7, 8
local function parse_signature(text)
  local a, b = tostring(text):match("^%s*(%d+)%s*/%s*(%d+)%s*$")
  return tonumber(a), tonumber(b)
end

-- "95,5" ou "95.5" -> 95.5
local function parse_bpm(text)
  return tonumber((tostring(text):gsub("%s", ""):gsub(",", ".")))
end

local function tempo_panel(ctx, x, y, w, song)
  local dl = ImGui.GetWindowDrawList(ctx)
  local pad = 16
  local ix, iw = x + pad, w - 2 * pad
  local cy = y + pad
  local nxt = next_song_of(song)
  local db_pos, db_bpm = tempo.downbeat(song, nxt)

  kit.txt(ctx, dl, "label", ix, cy, theme.C.muted, "TEMPO E GRID")
  local note = "assume tempo constante"
  kit.txt(ctx, dl, "small", x + w - pad - kit.size(ctx, "small", note), cy - 1, theme.C.faint, note)
  cy = cy + 24

  -- tap: círculo à esquerda, BPM medido e arredondamento à direita
  local d = 104
  ImGui.SetCursorScreenPos(ctx, ix, cy)
  if ImGui.InvisibleButton(ctx, "tap", d, d) then M.tap() end
  local hov = ImGui.IsItemHovered(ctx)
  widgets.mappable(ctx, { action = "tap_tempo" }, "Tap tempo")
  local n = tempo.tap_count()
  ImGui.DrawList_AddCircleFilled(dl, ix + d / 2, cy + d / 2, d / 2, hov and theme.C.raise2 or theme.C.raise)
  ImGui.DrawList_AddCircle(dl, ix + d / 2, cy + d / 2, d / 2, theme.C.line2, 0, 2)
  kit.txt(ctx, dl, "title", ix + d / 2 - kit.size(ctx, "title", "TAP") / 2, cy + d / 2 - 20, theme.C.text, "TAP")
  local sub = n == 0 and "toque 4 vezes" or n < 4 and string.format("mais %d", 4 - n) or string.format("%d toques", n)
  kit.txt(ctx, dl, "small", ix + d / 2 - kit.size(ctx, "small", sub) / 2, cy + d / 2 + 6, theme.C.muted, sub)

  local rx = ix + d + 16
  kit.txt(ctx, dl, "label", rx, cy, theme.C.muted, "BPM MEDIDO")
  local v = tap_value()
  kit.txt(ctx, dl, "big", rx, cy + 16, v and theme.C.text or theme.C.faint, v and fmt_bpm(v) or "—")
  local bx = rx
  for _, rd in ipairs(ROUNDS) do
    local clicked, bw = kit.button(ctx, "round_" .. rd[1], rd[2], bx, cy + 60, 28, { active = st.round == rd[1], style = "small" })
    if clicked then st.round = rd[1] end
    bx = bx + bw + 4
  end
  cy = cy + d + 14

  -- compasso 1 no cursor, com o BPM medido (ou o da música)
  local bpm = v or db_bpm or select(3, reaper.TimeMap_GetTimeSigAtTime(PROJ, song.start_pos))
  local mark = "Marcar compasso 1 no cursor"
  local mw = kit.size(ctx, "button", mark) + 24
  if kit.button(ctx, "mark_bar1", mark, ix, cy, 32, { w = math.min(mw, iw) }) then
    local ok, used = tempo.set_downbeat(song, nxt, reaper.GetCursorPosition(), bpm)
    if ok then tempo.reset_taps(); st.tap_bpm = nil end
    tempo_report(ok, used, ok and string.format("Compasso 1 marcado no cursor a %s BPM.", fmt_bpm(used or bpm)))
  end
  cy = cy + 42

  -- BPM da música: digitado (Enter ou clicar fora aplica) ou no ajuste fino,
  -- ouvindo o metrônomo
  local song_bpm = tempo.song_bpm(song, nxt)
  local rows = {
    { "BPM DA MÚSICA", nil, { { "bpm_dn", "−0,01", -0.01, 0 }, { "bpm_up", "+0,01", 0.01, 0 } } },
    { "COMPASSO 1", db_pos and string.format("%.3f s", db_pos):gsub("%.", ",") or "—", { { "ms_dn", "−1 ms", 0, -1 }, { "ms_up", "+1 ms", 0, 1 } } },
  }
  for _, row in ipairs(rows) do
    kit.txt(ctx, dl, "label", ix, cy + 9, theme.C.muted, row[1])
    if row[2] then
      kit.txt(ctx, dl, "num", ix + 120, cy + 7, db_pos and theme.C.text or theme.C.faint, row[2])
    else
      if not st.bpm_editing then st.bpm_buf = fmt_bpm(song_bpm) end
      local body = theme.font(ctx, "body")
      ImGui.SetCursorScreenPos(ctx, ix + 116, cy)
      ImGui.SetNextItemWidth(ctx, 84)
      local _, buf = ImGui.InputText(ctx, "##song_bpm", st.bpm_buf)
      st.bpm_buf = buf
      st.bpm_editing = ImGui.IsItemActive(ctx)
      if ImGui.IsItemDeactivatedAfterEdit(ctx) then
        st.bpm_editing = false
        local typed = parse_bpm(st.bpm_buf)
        if typed and math.abs(typed - song_bpm) < 0.005 then
          st.bpm_buf = fmt_bpm(song_bpm)
        else
          local ok, nb = tempo.set_bpm(song, nxt, typed)
          tempo_report(ok, nb, ok and string.format("BPM da música: %s.", fmt_bpm(nb or 0)))
        end
      end
      theme.pop_font(ctx, body)
    end
    local fx = x + w - pad
    for k = #row[3], 1, -1 do
      local b = row[3][k]
      local bw = kit.size(ctx, "small", b[2]) + 20
      fx = fx - bw
      if kit.button(ctx, b[1], b[2], fx, cy, 28, { w = bw, style = "small" }) then
        local ok, nb, np = tempo.nudge(song, nxt, b[3], b[4])
        local done = ok and (np and string.format("Compasso 1 em %.3f s a %s BPM.", np, fmt_bpm(nb)):gsub("(%d)%.(%d)", "%1,%2")
          or string.format("BPM da música: %s.", fmt_bpm(nb)))
        tempo_report(ok, nb, done)
      end
      fx = fx - 4
    end
    cy = cy + 34
  end
  -- fórmula de compasso da música: digitada (qualquer uma) ou nos atalhos
  local num, denom = tempo.song_signature(song, nxt)
  local function apply_signature(n, d)
    local ok, err = tempo.set_signature(song, nxt, n, d)
    tempo_report(ok, err, string.format("Fórmula da música: %s/%s.", tostring(n), tostring(d)))
  end
  kit.txt(ctx, dl, "label", ix, cy + 9, theme.C.muted, "FÓRMULA")
  if not st.sig_editing then st.sig_buf = num .. "/" .. denom end
  local body = theme.font(ctx, "body")
  ImGui.SetCursorScreenPos(ctx, ix + 116, cy)
  ImGui.SetNextItemWidth(ctx, 84)
  local _, sbuf = ImGui.InputText(ctx, "##song_sig", st.sig_buf)
  st.sig_buf = sbuf
  st.sig_editing = ImGui.IsItemActive(ctx)
  if ImGui.IsItemDeactivatedAfterEdit(ctx) then
    st.sig_editing = false
    local n, d = parse_signature(st.sig_buf)
    if n ~= num or d ~= denom then apply_signature(n, d) end
  end
  theme.pop_font(ctx, body)
  cy = cy + 34
  local fx = ix + 116
  for _, sig in ipairs(SIGNATURES) do
    local label = sig[1] .. "/" .. sig[2]
    local bw = kit.size(ctx, "small", label) + 18
    if fx + bw > ix + iw then fx, cy = ix + 116, cy + 32 end
    local current = sig[1] == num and sig[2] == denom
    if kit.button(ctx, "sig_" .. sig[1] .. "_" .. sig[2], label, fx, cy, 28, { w = bw, style = "small", active = current })
      and not current then
      apply_signature(sig[1], sig[2])
    end
    fx = fx + bw + 4
  end
  cy = cy + 38
  local metro = reaper.GetToggleCommandState(METRONOME) == 1
  if kit.button(ctx, "metronome", metro and "Metrônomo ligado" or "Metrônomo", ix, cy, 28,
    { style = "small", active = metro, accent = metro and theme.C.loop or nil }) then
    reaper.Main_OnCommand(METRONOME, 0)
  end
  cy = cy + 38
  local m = st.tempo_msg
  if m and now() < m["until"] then
    cy = cy + wrapped(ctx, "small", ix, cy, iw, m.err and theme.C.danger or theme.C.text, m.text) + 8
  end
  cy = cy + wrapped(ctx, "small", ix, cy, iw, theme.C.faint,
    "O áudio não é esticado: o grid é que passa a seguir o áudio. O ajuste desta música não muda o tempo das outras.")
  return cy - y + pad
end

-- ------------------------------------------------------------------ avisos

local function refresh_warnings()
  local count = reaper.GetProjectStateChangeCount(PROJ)
  if count == st.warn_count and now() - st.warn_at < WARN_REFRESH_S then return end
  st.warn_count, st.warn_at = count, now()
  local songs = model.songs()
  st.warnings = validator.check(songs, { links = layers.links(songs), keyboard_input = layers.keyboard_input(),
    mapping_rows = kontakt_cc and #kontakt_cc.rows() or 0 })
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

-- ------------------------------------------------------------------ Kontakt

local function kontakt_card(ctx, x, y, w, song)
  local dl = ImGui.GetWindowDrawList(ctx)
  local pad = 16
  local ix, iw = x + pad, w - 2 * pad
  local cy = y + pad
  kit.txt(ctx, dl, "label", ix, cy, theme.C.muted, "KONTAKT DESTA MÚSICA")
  cy = cy + 24
  local track = layers.track_of(song)
  if track then
    local _, tname = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
    local names = {}
    for _, l in ipairs(layers.layers(song)) do names[#names + 1] = l.name end
    local rows = {
      { "Track", tname ~= "" and tname or "(sem nome)" },
      { "Camadas", #names > 0 and table.concat(names, ", ") or "nenhuma" },
      { "Entrada MIDI", layers.keyboard_port() or "teclado não escolhido" },
    }
    for _, row in ipairs(rows) do
      kit.txt(ctx, dl, "small", ix, cy, theme.C.muted, row[1])
      cy = cy + wrapped(ctx, "button", ix + 96, cy - 1, iw - 96, theme.C.text, row[2]) + 8
    end
  else
    cy = cy + wrapped(ctx, "small", ix, cy, iw, theme.C.muted,
      "Nenhum Kontakt vinculado. O assistente vincula a track e cria as camadas a partir das saídas (multi-out).") + 10
  end
  local label = track and "Refazer vínculo" or "Assistente de Kontakt"
  if kit.button(ctx, "kontakt_wizard", label, ix, cy, 32, { w = math.min(iw, kit.size(ctx, "button", label) + 24) }) then
    wizard.open(song)
  end
  return cy + 32 + pad - y
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
        return tempo_panel(ctx, x + iw + GAP, cy, mw - iw - GAP, song)
      end)
      cy = cy + math.max(ih, th) + GAP
    else
      cy = cy + ih + GAP
      cy = cy + panel_behind(ctx, "tempo", x, cy, mw, function() return tempo_panel(ctx, x, cy, mw, song) end) + GAP
    end
  end

  local side_y = narrow and cy or y
  local sx, sw = narrow and x or x + mw + GAP, narrow and w or SIDE_W
  local wh = panel_behind(ctx, "warnings", sx, side_y, sw, function() return warnings_panel(ctx, sx, side_y, sw, song) end)
  local side_bottom = side_y + wh + GAP
  if song and wizard then
    local ky = side_bottom
    side_bottom = side_bottom + panel_behind(ctx, "kontakt", sx, ky, sw, function() return kontakt_card(ctx, sx, ky, sw, song) end) + GAP
    local msg = wizard.draw(ctx)
    if msg then say(msg); st.warn_count = nil end
  end
  chart_modal(ctx)
  local bottom = math.max(cy, side_bottom)

  ImGui.SetCursorScreenPos(ctx, x, y)
  ImGui.Dummy(ctx, w, math.max(0, bottom - y))
  return bottom - y
end

return M
