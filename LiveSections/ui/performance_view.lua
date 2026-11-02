-- Tela de performance (RF-070–074, RF-076, RF-101) e o ciclo que a alimenta:
-- MIDI → ações → modelo/fila → camadas → LEDs → desenho.
--
-- No modo Performance nada edita a estrutura: só disparos, transporte, loop,
-- quantize e camadas (RF-070). O modo Editar vem em ui/editor_view.
--
-- M.init(deps)     módulos e configurações (ver `deps` abaixo)
-- M.update(now)    uma vez por ciclo, antes do desenho: MIDI, fila, camadas, LEDs
-- M.draw(ctx)      desenha a tela dentro da janela já aberta
-- M.run(action, arg, value)   executa uma ação mapeável (RF-037)
-- M.handle_event(event)       um evento de midi/input
-- M.snapshot() -> estado da tela (música, seção, fila, progresso…)

local M = {}

local ImGui, theme, anim, widgets
local perf, layers, feedback, mappings, learn, input, model, editor, settings_view, stage

local VERSION = require("version")

local PROJ = 0
local PORT_CHECK_S = 1.0
local SETLIST_W = 240
local NARROW_W = 760       -- abaixo disso a setlist vira faixa compacta
local CARD_MIN_W = 190
local CARD_H, STAGE_CARD_H = 140, 190
local GAP = 12

local QUANTIZE_LABEL = {
  now = "Imediato", beat = "Batida", bar = "1 comp.", ["2bar"] = "2 comp.",
  ["4bar"] = "4 comp.", ["8bar"] = "8 comp.", section_end = "Fim da seção",
}
M.QUANTIZE_LABEL = QUANTIZE_LABEL

local ui = {
  mode = "performance",    -- "performance" | "edit" | "settings"
  stage = false,
  setlist_open = false,    -- setlist completa aberta no modo palco
  chart_open = false,      -- janela "Cifra"
  maximized = false,       -- janela ocupando a área útil do monitor
  toggle_max = false,      -- pedido de maximizar/restaurar (aplicado pelo entrypoint)
}
local stage_state = {}
local meters = {}          -- medidor por camada: [slot] = { l, r, hold, hold_at, t }
local now = 0
local last_song_id = nil
local last_port_check = -math.huge
local disconnected = {}    -- nomes de portas
local last_value = {}      -- [mapping] = último valor (borda de subida de CC/pitch bend)
local snap = {}

function M.init(deps)
  ImGui, theme, anim, widgets = deps.ImGui, deps.theme, deps.anim, deps.widgets
  perf, layers, feedback = deps.perf, deps.layers, deps.feedback
  mappings, learn, input, model = deps.mappings, deps.learn, deps.input, deps.model
  editor, settings_view, stage = deps.editor, deps.settings, deps.stage
  ui.mode, ui.stage, ui.setlist_open = "performance", false, false
  last_song_id, last_port_check, disconnected, last_value = nil, -math.huge, {}, {}
  last_high = {}
  meters = {}
end

function M.ui() return ui end

-- ------------------------------------------------------------------ ações

local CONTINUOUS = { layer_volume = true }

function M.run(action, arg, value)
  if action == "trigger_slot" then return perf.trigger_slot(arg)
  elseif action == "next_section" then return perf.next_section()
  elseif action == "prev_section" then return perf.prev_section()
  elseif action == "next_song" then return perf.next_song()
  elseif action == "prev_song" then return perf.prev_song()
  elseif action == "goto_song" then return perf.goto_song(arg)
  elseif action == "toggle_loop" then return perf.toggle_loop()
  elseif action == "set_quantize" then return perf.set_quantize(arg)
  elseif action == "cycle_quantize" then return perf.cycle_quantize(arg or 1)
  elseif action == "play_stop" then return perf.play_stop()
  elseif action == "play" then return perf.play()
  elseif action == "stop" then return perf.stop()
  elseif action == "cancel" then return perf.cancel()
  elseif action == "panic" then feedback.reset(); return perf.panic()
  elseif action == "layer_volume" then return layers.set_layer_volume(arg, value or 0)
  elseif action == "layer_mute" then return layers.toggle_mute(arg)
  elseif action == "layer_solo" then return layers.toggle_solo(arg)
  elseif action == "toggle_setlist" then ui.setlist_open = not ui.setlist_open; return ui.setlist_open
  elseif action == "tap_tempo" then return editor and editor.tap()
  end
end

-- Botões mandam Note On, Program Change ou um CC/pitch bend que sobe; só a
-- subida dispara. Há controladores que mandam o CC alto a cada toque e nunca
-- o baixo: um valor alto depois de um tempo sem mensagens altas também é um
-- toque novo. Faders (ações contínuas) seguem o valor.
local REPRESS_S = 0.25
local last_high = {}       -- [mapping] = hora da última mensagem alta

local function pressed(m, value)
  if m.msg_type == "note" or m.msg_type == "pc" then return true end
  local before = last_value[m] or 0
  last_value[m] = value
  if value < 0.5 then return false end
  local quiet = now - (last_high[m] or -math.huge) >= REPRESS_S
  last_high[m] = now
  return before < 0.5 or quiet
end

function M.handle_event(e)
  layers.feed(e)
  if learn.state() then
    local m = learn.feed(e)
    if m and m.action then
      widgets.flash(m)
      input.watch(M.mapped_ports())
    end
    return
  end
  local m, value, released = mappings.match(e)
  if not m or released then return end
  feedback.touch(m)
  if CONTINUOUS[m.action] then
    M.run(m.action, m.arg, value)
  elseif pressed(m, value) then
    M.run(m.action, m.arg, value)
    widgets.flash(m)
  end
end

function M.mapped_ports()
  local seen, out = {}, {}
  for _, m in ipairs(mappings.all()) do
    if not seen[m.port_name] then seen[m.port_name] = true; out[#out + 1] = m.port_name end
  end
  return out
end

-- ------------------------------------------------------------------ estado

local function fullbeats(t)
  local _, _, _, fb = reaper.TimeMap2_timeToBeats(PROJ, t)
  return fb
end

local function measure(t)
  local _, m = reaper.TimeMap2_timeToBeats(PROJ, t)
  return m
end

local function same_section(a, b) return a ~= nil and b ~= nil and a.region_idx == b.region_idx end

-- Estado derivado para o desenho e os LEDs.
local function build_snapshot()
  local pos = reaper.GetPlayState() & 1 == 1 and reaper.GetPlayPosition2(PROJ) or reaper.GetCursorPosition()
  local playing = reaper.GetPlayState() & 1 == 1
  local song = perf.current_song() or model.song_at(pos)
  local _, section = model.song_at(pos)
  local entry = perf.queued()
  local s = {
    pos = pos, playing = playing, song = song, section = section, entry = entry,
    looping = perf.loop_section(), quantize = perf.quantize(),
  }
  if entry then
    s.queued_section = entry.target.kind == "section" and entry.target.ref or nil
    s.queued_song = entry.target.kind == "song" and entry.target.ref or nil
    s.beats_left = math.max(0, math.ceil(fullbeats(entry.jump_pos) - fullbeats(pos) - 1e-6))
  end
  if section then
    local len = section.end_pos - section.start_pos
    s.progress = len > 0 and math.max(0, math.min(1, (pos - section.start_pos) / len)) or 0
  end
  return s
end

function M.snapshot() return snap end

-- Nomes das saídas MIDI ativas, para o diagnóstico dos LEDs.
local function midi_outputs()
  local list = {}
  for i = 0, reaper.GetMaxMidiOutputs() - 1 do
    local ok, name = reaper.GetMIDIOutputName(i, "")
    if ok then list[#list + 1] = name end
  end
  if #list == 0 then list[1] = "(nenhuma)" end
  return list
end

-- Estado do card de uma seção.
function M.card_state(section, s)
  if same_section(section, s.queued_section) then return "queued" end
  if same_section(section, s.looping) then return "loop" end
  if same_section(section, s.section) then return s.playing and "playing" or "cursor" end
  return "idle"
end

local function update_leds()
  local s = snap
  local ctx = {
    sections = s.song and s.song.sections or {},
    playing = s.playing and s.section or nil,
    queued = s.queued_section,
    looping = s.looping,
    transport = s.playing,
  }
  local layer_cache = {}
  function ctx.layer(slot)
    if layer_cache[slot] == nil then layer_cache[slot] = layers.layer_state(slot) or false end
    return layer_cache[slot] or nil
  end
  for _, m in ipairs(mappings.all()) do feedback.set_state(m, feedback.state_for(m, ctx)) end
  feedback.flush(now)
end

function M.update(t)
  now = t
  for _, e in ipairs(input.poll()) do M.handle_event(e) end
  perf.tick()
  snap = build_snapshot()

  local id = snap.song and snap.song.id
  if id ~= last_song_id then
    last_song_id = id
    layers.activate(snap.song, model.songs(), now)
  end
  layers.tick(now)

  if now - last_port_check >= PORT_CHECK_S then
    last_port_check = now
    input.watch(M.mapped_ports())
    input.check_ports()
    disconnected = {}
    for _, name in ipairs(M.mapped_ports()) do
      if not input.is_connected(name) then disconnected[#disconnected + 1] = name end
    end
  end
  snap.disconnected = disconnected
  update_leds()
  snap.no_led_output = feedback.missing_outputs()

  -- estado de palco: janela de cifra e página do celular/tablet
  if stage then
    stage_state = stage.build(snap, { max_lines = mappings.settings().chart_lines })
    stage.publish(stage_state, now)
  end
end

function M.stage_state() return stage_state end

-- ------------------------------------------------------------------ desenho: apoio

local function txt(ctx, dl, style, x, y, color, s)
  local pushed = theme.font(ctx, style)
  ImGui.DrawList_AddText(dl, x, y, color, s)
  theme.pop_font(ctx, pushed)
end

local function size(ctx, style, s)
  local pushed = theme.font(ctx, style)
  local w, h = ImGui.CalcTextSize(ctx, s)
  theme.pop_font(ctx, pushed)
  return w, h
end

-- Botão desenhado; `opts`: icon, active, accent, style, w. Retorna clicado.
local function button(ctx, id, label, x, y, h, opts)
  opts = opts or {}
  local style = opts.style or "button"
  local tw = label ~= "" and size(ctx, style, label) or 0
  local w = opts.w or (tw + (opts.icon and 22 or 0) + 24)
  ImGui.SetCursorScreenPos(ctx, x, y)
  local clicked = ImGui.InvisibleButton(ctx, id, w, h)
  local hovered = ImGui.IsItemHovered(ctx)
  local dl = ImGui.GetWindowDrawList(ctx)
  local accent = opts.accent
  local bg = opts.active and (accent or theme.C.text) or (hovered and theme.C.raise2 or theme.C.raise)
  local fg = opts.active and theme.C.ink or (accent or theme.C.text)
  ImGui.DrawList_AddRectFilled(dl, x, y, x + w, y + h, bg, theme.R.r1 + 2)
  if not opts.active then ImGui.DrawList_AddRect(dl, x, y, x + w, y + h, theme.C.line2, theme.R.r1 + 2) end
  local cx = x + (w - tw - (opts.icon and 22 or 0)) / 2
  if opts.icon then
    theme.icon(dl, opts.icon, cx, y + (h - 16) / 2, 16, fg)
    cx = cx + 22
  end
  if label ~= "" then
    local _, th = size(ctx, style, label)
    txt(ctx, dl, style, cx, y + (h - th) / 2, fg, label)
  end
  return clicked, w
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

-- Peças de desenho compartilhadas com ui/editor_view e ui/settings_view.
M.kit = { txt = txt, size = size, button = button, wrapped = wrapped }

local function fmt_time(t)
  local m = math.floor(t / 60)
  return string.format("%d:%04.1f", m, t - m * 60)
end

-- ------------------------------------------------------------------ desenho: partes

-- Marca com a versão logo abaixo, para saber o que está instalado ao
-- relatar um problema.
local function top_bar(ctx, x, y, w)
  local dl = ImGui.GetWindowDrawList(ctx)
  local s = snap
  local h = 56
  ImGui.DrawList_AddRectFilled(dl, x, y, x + w, y + h, theme.C.panel, theme.R.r2)

  -- marca e modos
  local cx = x + 16
  txt(ctx, dl, "strong", cx, y + 11, theme.C.text, "Live Sections")
  local ver = "v" .. VERSION
  txt(ctx, dl, "label", cx, y + 31, theme.C.faint, ver)
  cx = cx + math.max(size(ctx, "strong", "Live Sections"), size(ctx, "label", ver)) + 16
  local clicked, bw = button(ctx, "mode_perf", "Performance", cx, y + 12, 32, { active = ui.mode == "performance" })
  if clicked then ui.mode = "performance" end
  cx = cx + bw + 6
  clicked, bw = button(ctx, "mode_edit", "Editar", cx, y + 12, 32, { active = ui.mode == "edit" })
  if clicked then ui.mode = "edit"; ui.stage = false end
  cx = cx + bw + 6
  clicked, bw = button(ctx, "mode_settings", "Configurações", cx, y + 12, 32, { active = ui.mode == "settings" })
  if clicked then ui.mode = "settings"; ui.stage = false end
  cx = cx + bw + 16

  -- leituras: posição, tempo, BPM e fórmula
  local num, denom, bpm = reaper.TimeMap_GetTimeSigAtTime(PROJ, s.pos or 0)
  local reads = {
    { "COMPASSO", reaper.format_timestr_pos(s.pos or 0, "", 2) },
    { "TEMPO", fmt_time(s.pos or 0) },
    { "BPM", string.format("%g", math.floor(bpm * 100 + 0.5) / 100) },
    { "FÓRMULA", num .. "/" .. denom },
  }
  for _, r in ipairs(reads) do
    if cx + 80 > x + w - 490 then break end
    txt(ctx, dl, "label", cx, y + 9, theme.C.muted, r[1])
    txt(ctx, dl, "readout", cx, y + 25, theme.C.text, r[2])
    cx = cx + math.max(size(ctx, "readout", r[2]), size(ctx, "label", r[1])) + 20
  end

  -- direita: maximizar, cifra, palco, MIDI e quantize
  local rx = x + w - 16 - 32
  if button(ctx, "maximize", "", rx, y + 12, 32, { icon = ui.maximized and "restore" or "maximize", w = 32 }) then
    ui.toggle_max = true
  end
  if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, ui.maximized and "Restaurar (F11)" or "Maximizar (F11)") end
  local cw = size(ctx, "button", "Cifra") + 24
  rx = rx - cw - 6
  if button(ctx, "chart", "Cifra", rx, y + 12, 32, { active = ui.chart_open, w = cw }) then
    ui.chart_open = not ui.chart_open
  end
  local stage_label = ui.stage and "Sair do palco" or "Palco"
  local sw = size(ctx, "button", stage_label) + 46
  rx = rx - sw - 6
  if ui.mode == "performance" then
    if button(ctx, "stage", stage_label, rx, y + 12, 32, { icon = "stage", active = ui.stage, w = sw }) then
      ui.stage = not ui.stage
      ui.setlist_open = false
    end
  end

  -- pílula MIDI: vermelha se uma porta mapeada sumiu, âmbar se os LEDs
  -- não têm saída com o nome da porta
  local midi_ok = #(s.disconnected or {}) == 0
  local no_leds = s.no_led_output or {}
  local leds_ok = #no_leds == 0
  local midi_label = not midi_ok and "MIDI desconectado" or not leds_ok and "LEDs sem saída" or "MIDI ok"
  local mw = size(ctx, "label", midi_label) + 34
  rx = rx - mw - 10
  local pill = not midi_ok and theme.C.danger or not leds_ok and theme.C.queue or theme.C.ok
  ImGui.DrawList_AddRectFilled(dl, rx, y + 14, rx + mw, y + 42, theme.C.bg, 14)
  ImGui.DrawList_AddRect(dl, rx, y + 14, rx + mw, y + 42, midi_ok and leds_ok and theme.C.line or pill, 14)
  if midi_ok and leds_ok then
    ImGui.DrawList_AddCircleFilled(dl, rx + 14, y + 28, 4, pill)
  else
    theme.icon(dl, "warn", rx + 7, y + 21, 14, pill)
  end
  txt(ctx, dl, "label", rx + 24, y + 22, midi_ok and leds_ok and theme.C.text or pill, midi_label)
  ImGui.SetCursorScreenPos(ctx, rx, y + 14)
  ImGui.InvisibleButton(ctx, "midi_pill", mw, 28)
  if ImGui.IsItemHovered(ctx) then
    if not midi_ok then
      ImGui.SetTooltip(ctx, "Sem sinal de:\n" .. table.concat(s.disconnected, "\n")
        .. "\n\nOs mapeamentos voltam a funcionar quando o dispositivo for reconectado.")
    elseif not leds_ok then
      ImGui.SetTooltip(ctx, "Nenhuma saída MIDI com o nome:\n" .. table.concat(no_leds, "\n")
        .. "\n\nSaídas ativas no REAPER:\n" .. table.concat(midi_outputs(), "\n")
        .. "\n\nAtive a saída do controlador em Preferences → MIDI Devices.")
    end
  end

  -- quantize: botão que abre a lista; mapeável (percorrer os valores)
  local qlabel = "Quantize: " .. QUANTIZE_LABEL[s.quantize or "bar"]
  local qw = size(ctx, "button", qlabel) + 24
  rx = rx - qw - 10
  if rx > cx then
    if button(ctx, "quantize", qlabel, rx, y + 12, 32, { w = qw }) then ImGui.OpenPopup(ctx, "quantize_menu") end
    widgets.mappable(ctx, { action = "cycle_quantize", arg = 1 }, "Quantize")
    if ImGui.BeginPopup(ctx, "quantize_menu") then
      for _, mode in ipairs(require("core.quantize").MODES) do
        if ImGui.MenuItem(ctx, QUANTIZE_LABEL[mode], nil, mode == s.quantize) then perf.set_quantize(mode) end
      end
      ImGui.EndPopup(ctx)
    end
  end
  return h
end

local function song_status(song, i, s)
  if s.queued_song and s.queued_song.id == song.id then
    return "clock", "Na fila · em " .. (s.beats_left or 0) .. " bat.", theme.C.queue
  end
  if s.song and s.song.id == song.id then
    if s.playing then return "play", "Tocando", theme.C.ok end
    return nil, "Atual · pronta", theme.C.text
  end
  if not layers.track_of(song) then return nil, "Sem Kontakt", theme.C.faint end
  return nil, "Kontakt em bypass", theme.C.faint
end

local function setlist(ctx, x, y, w, h)
  local dl = ImGui.GetWindowDrawList(ctx)
  local s = snap
  ImGui.DrawList_AddRectFilled(dl, x, y, x + w, y + h, theme.C.panel, theme.R.r2)
  txt(ctx, dl, "label", x + 16, y + 14, theme.C.muted, "SETLIST")
  local cy = y + 40
  for i, song in ipairs(model.songs()) do
    if cy + 58 > y + h then break end
    local current = s.song and s.song.id == song.id
    ImGui.SetCursorScreenPos(ctx, x + 8, cy)
    if ImGui.InvisibleButton(ctx, "song" .. i, w - 16, 54) then perf.goto_song(i) end
    local hovered = ImGui.IsItemHovered(ctx)
    widgets.mappable(ctx, { action = "goto_song", arg = i }, song.name)
    if current or hovered then
      ImGui.DrawList_AddRectFilled(dl, x + 8, cy, x + w - 8, cy + 54, current and theme.C.raise2 or theme.C.raise, theme.R.r2)
    end
    if current then ImGui.DrawList_AddRectFilled(dl, x + 8, cy + 10, x + 11, cy + 44, theme.C.text, 2) end
    ImGui.DrawList_AddRectFilled(dl, x + 18, cy + 14, x + 44, cy + 40, theme.C.raise2, theme.R.r1)
    local n = tostring(i)
    txt(ctx, dl, "num", x + 31 - size(ctx, "num", n) / 2, cy + 19, theme.C.muted, n)
    ImGui.DrawList_PushClipRect(dl, x + 52, cy, x + w - 12, cy + 54, true)
    txt(ctx, dl, "strong", x + 54, cy + 9, theme.C.text, song.name)
    local icon, label, color = song_status(song, i, s)
    local lx = x + 54
    if icon then theme.icon(dl, icon, lx, cy + 32, 12, color); lx = lx + 16 end
    txt(ctx, dl, "label", lx, cy + 32, color, label:upper())
    ImGui.DrawList_PopClipRect(dl)
    cy = cy + 58
  end
end

-- Faixa compacta: anterior, atual (destaque) e próxima. Clicar abre a setlist.
local function setlist_strip(ctx, x, y, w)
  local dl = ImGui.GetWindowDrawList(ctx)
  local s = snap
  local songs = model.songs()
  local idx = 1
  for i, song in ipairs(songs) do if s.song and song.id == s.song.id then idx = i end end
  local h = 64
  local parts = { { songs[idx - 1], "Anterior", 0.28 }, { songs[idx], "Atual", 0.44 }, { songs[idx + 1], "Próxima", 0.28 } }
  local cx = x
  for k, p in ipairs(parts) do
    local pw = (w - 2 * GAP) * p[3]
    ImGui.SetCursorScreenPos(ctx, cx, y)
    if ImGui.InvisibleButton(ctx, "strip" .. k, pw, h) then
      if p[1] and k ~= 2 then perf.goto_song(idx + k - 2) else ui.setlist_open = not ui.setlist_open end
    end
    if k == 2 then widgets.mappable(ctx, { action = "toggle_setlist" }, "Setlist") end
    ImGui.DrawList_AddRectFilled(dl, cx, y, cx + pw, y + h, k == 2 and theme.C.raise2 or theme.C.panel, theme.R.r2)
    local queued = p[1] and s.queued_song and s.queued_song.id == p[1].id
    if queued then ImGui.DrawList_AddRect(dl, cx, y, cx + pw, y + h, theme.C.queue, theme.R.r2, 0, 2) end
    ImGui.DrawList_PushClipRect(dl, cx, y, cx + pw - 10, y + h, true)
    local label = queued and ("Na fila · em " .. (s.beats_left or 0) .. " bat.") or p[2]
    txt(ctx, dl, "label", cx + 14, y + 12, queued and theme.C.queue or theme.C.muted, label:upper())
    txt(ctx, dl, k == 2 and "title" or "strong", cx + 14, y + (k == 2 and 30 or 33), p[1] and theme.C.text or theme.C.faint,
      p[1] and p[1].name or "—")
    ImGui.DrawList_PopClipRect(dl)
    cx = cx + pw + GAP
  end
  return h
end

local function empty_state(ctx, x, y, w)
  local dl = ImGui.GetWindowDrawList(ctx)
  local h = 200
  for i = 0, 1 do
    local yy = i == 0 and y or y + h
    for xx = x, x + w - 8, 12 do ImGui.DrawList_AddLine(dl, xx, yy, math.min(xx + 7, x + w), yy, theme.C.line2, 1) end
  end
  local title = "Esta música ainda não tem seções"
  local tip = "Crie seções no modo Editar ou desenhando regiões na régua do REAPER."
  txt(ctx, dl, "strong", x + (w - size(ctx, "strong", title)) / 2, y + 50, theme.C.text, title)
  txt(ctx, dl, "small", x + (w - size(ctx, "small", tip)) / 2, y + 80, theme.C.muted, tip)
  local bw = size(ctx, "button", "Seção") + 46
  if button(ctx, "add_section", "Seção", x + (w - bw) / 2, y + 116, 36, { icon = "plus", w = bw }) then
    ui.mode = "edit"
    ui.stage = false
  end
  return h
end

local function cards(ctx, x, y, w)
  local s = snap
  local song = s.song
  local list = song and song.sections or {}
  if #list == 0 then return empty_state(ctx, x, y, w) end
  local card_h = ui.stage and STAGE_CARD_H or CARD_H
  local cols = math.max(1, math.floor((w + GAP) / (CARD_MIN_W + GAP)))
  local cw = (w - (cols - 1) * GAP) / cols
  for i, sec in ipairs(list) do
    local col, row = (i - 1) % cols, (i - 1) // cols
    ImGui.SetCursorScreenPos(ctx, x + col * (cw + GAP), y + row * (card_h + GAP))
    local state = M.card_state(sec, s)
    local res = widgets.section_card(ctx, "sec" .. sec.region_idx, {
      name = sec.name, color = sec.color, slot = sec.slot,
      bars = measure(sec.end_pos) - measure(sec.start_pos),
      state = state, progress = s.progress, beats_left = s.beats_left,
      control = { action = "trigger_slot", arg = sec.slot },
    }, cw, card_h)
    if res == "trigger" then perf.trigger_section(sec)
    elseif res == "cancel" then perf.cancel() end
  end
  local rows = (#list + cols - 1) // cols
  return rows * card_h + (rows - 1) * GAP
end

-- Medidor de nível: escala -60 a +6 dB; desce suave e segura o pico 1,5 s.
local METER_MIN_DB, METER_MAX_DB = -60, 6
local METER_FALL = 1.5        -- escala por segundo
local HOLD_S = 1.5

local function meter_level(lin)
  if not lin or lin <= 0 then return 0 end
  local db = 20 * math.log(lin, 10)
  return math.max(0, math.min(1, (db - METER_MIN_DB) / (METER_MAX_DB - METER_MIN_DB)))
end

local function db_level(db) return (db - METER_MIN_DB) / (METER_MAX_DB - METER_MIN_DB) end

local function meter_state(slot, peak_l, peak_r)
  local m = meters[slot] or { l = 0, r = 0, hold = 0, hold_at = -math.huge, t = now }
  local dt = math.max(0, now - m.t)
  m.t = now
  m.l = math.max(meter_level(peak_l), m.l - METER_FALL * dt)
  m.r = math.max(meter_level(peak_r), m.r - METER_FALL * dt)
  local top = math.max(m.l, m.r)
  if top >= m.hold or now - m.hold_at > HOLD_S then m.hold, m.hold_at = top, now end
  meters[slot] = m
  return m
end

local function meter(dl, x, y, w, h, level)
  ImGui.DrawList_AddRectFilled(dl, x, y, x + w, y + h, theme.C.bg, 2)
  local zones = {
    { 0, db_level(-12), theme.C.ok }, { db_level(-12), db_level(-3), theme.C.queue }, { db_level(-3), 1, theme.C.danger },
  }
  for _, z in ipairs(zones) do
    local a, b = z[1], math.min(z[2], level)
    if b > a then ImGui.DrawList_AddRectFilled(dl, x, y + h * (1 - b), x + w, y + h * (1 - a), z[3], 1) end
  end
end

-- Camadas como colunas de mixer. No palco (`fh` menor) o fader é mais
-- baixo, para sobrar espaço para os cards, e sem camadas nada aparece.
local FADER_H, STAGE_FADER_H = 132, 96

local function layer_strip(ctx, x, y, w, fh)
  local dl = ImGui.GetWindowDrawList(ctx)
  local song = snap.song
  local list = song and layers.layers(song) or {}
  if ui.stage and #list == 0 then return 0 end
  txt(ctx, dl, "label", x, y, theme.C.muted, "CAMADAS")
  y = y + 22
  if #list == 0 then
    local note = song and not layers.track_of(song) and "Sem Kontakt vinculado a esta música. Vincule no modo Editar."
      or "O Kontakt desta música não tem camadas (tracks filhas)."
    ImGui.DrawList_AddRect(dl, x, y, x + w, y + 44, theme.C.line2, theme.R.r2)
    txt(ctx, dl, "small", x + 14, y + 14, theme.C.muted, note)
    return 66
  end
  local lw = 96
  fh = fh or FADER_H
  for i in ipairs(list) do
    local st = layers.layer_state(i)
    local lx = x + (i - 1) * (lw + GAP)
    if not st or lx + lw > x + w then break end
    ImGui.DrawList_AddRectFilled(dl, lx, y, lx + lw, y + fh + 92, theme.C.panel, theme.R.r2)
    ImGui.DrawList_PushClipRect(dl, lx + 6, y, lx + lw - 6, y + 30, true)
    txt(ctx, dl, "button", lx + 10, y + 10, theme.C.text, st.name)
    ImGui.DrawList_PopClipRect(dl)

    -- fader: arrastar na tela muda o volume; o físico precisa alcançar de novo
    local fx, fy = lx + (lw - 40) / 2, y + 34
    ImGui.SetCursorScreenPos(ctx, fx, fy)
    ImGui.InvisibleButton(ctx, "fader" .. i, 40, fh)
    if ImGui.IsItemActive(ctx) then
      local _, my = ImGui.GetMousePos(ctx)
      layers.set_volume_ui(i, 1 - (my - fy) / fh)
      st = layers.layer_state(i)
    end
    widgets.mappable(ctx, { action = "layer_volume", arg = i }, "Volume " .. st.name)
    ImGui.DrawList_AddRectFilled(dl, fx, fy, fx + 40, fy + fh, theme.C.bg, 10)
    ImGui.DrawList_AddRect(dl, fx, fy, fx + 40, fy + fh, theme.C.line, 10)
    local vy = fy + fh * (1 - st.pos)
    ImGui.DrawList_AddRectFilled(dl, fx + 3, vy, fx + 37, fy + fh - 3, st.mute and theme.C.line2 or theme.C.muted & 0xFFFFFF66, 8)
    ImGui.DrawList_AddRectFilled(dl, fx - 3, vy - 4, fx + 43, vy + 4, theme.C.text, 3)

    -- nível de saída da camada, ao lado do fader
    local m = meter_state(i, st.peak_l, st.peak_r)
    local mx = fx + 50
    meter(dl, mx, fy, 5, fh, m.l)
    meter(dl, mx + 7, fy, 5, fh, m.r)
    if m.hold > 0 then
      local hy = fy + fh * (1 - m.hold)
      local hc = m.hold >= db_level(-3) and theme.C.danger or m.hold >= db_level(-12) and theme.C.queue or theme.C.ok
      ImGui.DrawList_AddLine(dl, mx, hy, mx + 12, hy, hc, 2)
    end

    -- soft takeover: onde está o fader físico e para onde movê-lo
    local dir = layers.takeover(i)
    if dir then
      txt(ctx, dl, "label", lx + 10, fy + fh + 6, theme.C.queue, dir == "up" and "SUBA O FADER" or "DESÇA O FADER")
    end

    local by = fy + fh + 26
    if button(ctx, "mute" .. i, "M", lx + 12, by, 26, { w = 32, active = st.mute, accent = theme.C.queue, style = "num" }) then
      layers.toggle_mute(i)
    end
    widgets.mappable(ctx, { action = "layer_mute", arg = i }, "Mute " .. st.name)
    if button(ctx, "solo" .. i, "S", lx + lw - 44, by, 26, { w = 32, active = st.solo, accent = theme.C.ok, style = "num" }) then
      layers.toggle_solo(i)
    end
    widgets.mappable(ctx, { action = "layer_solo", arg = i }, "Solo " .. st.name)
  end
  return 22 + fh + 92
end

-- Espaço: Play/Stop no Performance e no Palco (fora de campos de texto).
local function space_key(ctx)
  if not ImGui.IsWindowFocused(ctx) or ImGui.IsAnyItemActive(ctx) then return end
  local mod = ImGui.IsKeyDown(ctx, ImGui.Mod_Ctrl) or (ImGui.Mod_Super and ImGui.IsKeyDown(ctx, ImGui.Mod_Super))
  if not mod and ImGui.IsKeyPressed(ctx, ImGui.Key_Space, false) then perf.play_stop() end
end

local function action_bar(ctx, x, y, w)
  local s = snap
  local h = 44
  local items = {
    { "prev_song", "Música anterior", "prev_song", function() perf.prev_song() end },
    { "toggle_loop", s.looping and "Loop ligado" or "Loop", "loop", function() perf.toggle_loop() end, s.looping and theme.C.loop },
    { "cancel", "Cancelar fila", "x", function() perf.cancel() end, s.entry and theme.C.queue },
    { "play", "Play", "play", function() perf.play() end, s.playing and theme.C.ok },
    { "stop", "Stop", "stop", function() perf.stop() end },
    { "next_song", "Próxima música", "next_song", function() perf.next_song() end },
    { "panic", "Panic", "warn", function() M.run("panic") end, theme.C.danger },
  }
  local bw = math.max(96, (w - (#items - 1) * GAP) / #items)
  local cx = x
  for _, it in ipairs(items) do
    if cx + 60 > x + w then break end
    local width = math.min(bw, x + w - cx)
    local active = it[5] ~= nil and it[1] ~= "panic"
    if button(ctx, "act_" .. it[1], width >= 120 and it[2] or "", cx, y, h, { icon = it[3], w = width, active = active, accent = it[5] }) then
      it[4]()
    end
    widgets.mappable(ctx, { action = it[1] }, it[2])
    cx = cx + width + GAP
  end
  return h
end

local function song_header(ctx, x, y, w)
  local dl = ImGui.GetWindowDrawList(ctx)
  local song = snap.song
  txt(ctx, dl, "label", x, y, theme.C.muted, "MÚSICA ATUAL")
  local name = song and song.name or "Sem músicas"
  ImGui.DrawList_PushClipRect(dl, x, y, x + w, y + 60, true)
  txt(ctx, dl, "h1", x, y + 16, theme.C.text, name)
  ImGui.DrawList_PopClipRect(dl)
  return 62
end

-- Anotação da música (tom, intro, dica): faixa com destaque âmbar à
-- esquerda, uma linha por linha do texto. A altura do fundo é a do ciclo
-- anterior (o texto só é medido ao ser desenhado).
local note_h = {}

local function note_box(ctx, x, y, w, style)
  local note = stage_state.note
  if not note then return 0 end
  local dl = ImGui.GetWindowDrawList(ctx)
  local h = note_h[style] or 0
  ImGui.DrawList_AddRectFilled(dl, x, y, x + w, y + h, theme.C.panel, theme.R.r2)
  ImGui.DrawList_AddRectFilled(dl, x, y, x + 4, y + h, theme.C.queue, 2)
  local cy = y + 10
  for _, line in ipairs(require("core.song_notes").lines(note)) do
    cy = cy + wrapped(ctx, style, x + 18, cy, w - 32, theme.C.text, line) + 4
  end
  note_h[style] = cy - y + 6
  return note_h[style]
end

-- ------------------------------------------------------------------ desenho

function M.draw(ctx)
  local x, y = ImGui.GetCursorScreenPos(ctx)
  local w, h = ImGui.GetContentRegionAvail(ctx)
  if w <= 0 then return end

  local bar_h = top_bar(ctx, x, y, w) + GAP
  y, h = y + bar_h, h - bar_h

  if ui.mode == "edit" then
    if editor then editor.draw(ctx, x, y, w, h, snap) end
    return
  end
  if ui.mode == "settings" then
    if settings_view then settings_view.draw(ctx, x, y, w, h, snap) end
    return
  end

  space_key(ctx)
  local compact = ui.stage or w < NARROW_W
  local cx, cw = x, w
  if compact then
    y = y + setlist_strip(ctx, x, y, w) + GAP
    if ui.setlist_open then
      local list_h = math.min(#model.songs() * 58 + 48, math.max(160, h - 200))
      setlist(ctx, x, y, w, list_h)
      y = y + list_h + GAP
    end
  else
    setlist(ctx, x, y, SETLIST_W, math.max(200, h))
    cx, cw = x + SETLIST_W + GAP + 4, w - SETLIST_W - GAP - 4
  end

  local cy = y
  if ui.stage then
    local nh = note_box(ctx, cx, cy, cw, "title")
    if nh > 0 then cy = cy + nh + GAP end
  else
    cy = cy + song_header(ctx, cx, cy, cw)
    local nh = note_box(ctx, cx, cy, cw, "strong")
    cy = cy + (nh > 0 and nh + GAP or 0) + GAP
  end
  cy = cy + cards(ctx, cx, cy, cw) + GAP * 2
  local lh = layer_strip(ctx, cx, cy, cw, ui.stage and STAGE_FADER_H or FADER_H)
  if lh > 0 then cy = cy + lh + GAP end
  cy = cy + action_bar(ctx, cx, cy, cw) + GAP

  ImGui.SetCursorScreenPos(ctx, x, y)
  ImGui.Dummy(ctx, w, math.max(0, cy - y))
end

return M
