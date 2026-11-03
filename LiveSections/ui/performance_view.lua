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

local diag = require("core.diag")

local ImGui, theme, anim, widgets
local perf, layers, feedback, mappings, learn, input, model, editor, settings_view, stage
local kontakt_cc, mapping_view, layer_params

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
  mode = "performance",    -- "performance" | "edit" | "settings" | "mapping"
  stage = false,
  setlist_open = false,    -- setlist completa aberta no modo palco
  chart_open = false,      -- janela "Cifra"
  maximized = false,       -- janela ocupando a área útil do monitor
  toggle_max = false,      -- pedido de maximizar/restaurar (aplicado pelo entrypoint)
  learn_conflict = nil,    -- { mapping, at }: o learn do Mapeamento recusou um controle
  param_pick = nil,        -- { slot }: "+ parâmetro" esperando um controle
  param_error = nil,       -- { text, at }: ligar o parâmetro falhou
}
local stage_state = {}
local meters = {}          -- medidor por camada: [slot] = { l, r, hold, hold_at, t }
local now = 0
local last_song_id = nil
local last_port_check = -math.huge
local disconnected = {}    -- nomes de portas
local last_value = {}      -- [mapping] = último valor (borda de subida de CC/pitch bend)
local snap = {}
local rename = nil         -- { slot, buf }: popup de renomear camada
local name_edit = nil      -- { song, row_id, buf, open }: quadro do nome do parâmetro

function M.init(deps)
  ImGui, theme, anim, widgets = deps.ImGui, deps.theme, deps.anim, deps.widgets
  perf, layers, feedback = deps.perf, deps.layers, deps.feedback
  mappings, learn, input, model = deps.mappings, deps.learn, deps.input, deps.model
  editor, settings_view, stage = deps.editor, deps.settings, deps.stage
  kontakt_cc, mapping_view, layer_params = deps.kontakt_cc, deps.mapping, deps.layer_params
  ui.mode, ui.stage, ui.setlist_open = "performance", false, false
  last_song_id, last_port_check, disconnected, last_value = nil, -math.huge, {}, {}
  last_high = {}
  meters = {}
end

-- A espera do "+ parâmetro" termina ao trocar de música, sair do
-- Performance ou entrar no Palco (RF-153).
local function cancel_pick()
  ui.param_pick = nil
  local st = learn.state()
  if st and st.mode == "pick" then learn.cancel() end
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
    if m and m.conflict then
      ui.learn_conflict = { mapping = m.conflict, at = now }
    elseif m and m.action then
      widgets.flash(m)
      input.watch(M.mapped_ports())
    end
    return
  end
  local m, value, released = mappings.match(e)
  if not m then return end
  -- controles do Mapeamento: o CC vai para o Kontakt da música atual
  if m.action == "kontakt_cc" then
    if kontakt_cc then kontakt_cc.handle(m, value, released, now) end
    feedback.touch(m)
    return
  end
  if released then return end
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
  if kontakt_cc then ctx.kontakt_on = kontakt_cc.led end
  for _, m in ipairs(mappings.all()) do feedback.set_state(m, feedback.state_for(m, ctx)) end
  feedback.flush(now)
end

-- Fader e knob absoluto só importam pelo último valor: das mensagens de um
-- ciclo, fica a última de cada controle. Um fader manda centenas por
-- segundo, e tratar cada uma travava a thread principal do REAPER.
local function coalesce_key(e)
  if learn.state() then return nil end
  local kind = e.status & 0xF0
  if kind ~= 0xB0 and kind ~= 0xE0 then return nil end
  local m = mappings.match(e)
  if not m then return nil end
  local absolute = CONTINUOUS[m.action] or (m.action == "kontakt_cc" and kontakt_cc and kontakt_cc.absolute(m.arg))
  if not absolute then return nil end
  return e.port_name .. ":" .. e.status .. ":" .. (kind == 0xB0 and e.data1 or "")
end

function M.update(t)
  now = t
  layers.begin_cycle()
  local events = input.poll()
  diag.events(#events)
  local keys, last = {}, {}
  for i, e in ipairs(events) do
    keys[i] = coalesce_key(e)
    if keys[i] then last[keys[i]] = i end
  end
  for i, e in ipairs(events) do
    if not keys[i] or last[keys[i]] == i then M.handle_event(e) end
  end
  perf.tick()
  snap = build_snapshot()

  local id = snap.song and snap.song.id
  if id ~= last_song_id then
    if last_song_id ~= nil then cancel_pick() end
    last_song_id = id
    layers.activate(snap.song, model.songs(), now)
    -- depois do activate: o Kontakt já saiu do bypass e o JSFX processa
    if kontakt_cc then kontakt_cc.on_song(snap.song) end
  end
  layers.tick(now)
  if kontakt_cc then kontakt_cc.tick(now) end

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
  -- o learn em série do Mapeamento só vale na tela dele
  local function set_mode(mode)
    local st = learn.state()
    if mode ~= "mapping" and st and st.mode == "series" then learn.cancel() end
    if mode ~= "performance" then cancel_pick() end
    ui.mode = mode
    if mode ~= "performance" then ui.stage = false end
  end
  local clicked, bw = button(ctx, "mode_perf", "Performance", cx, y + 12, 32, { active = ui.mode == "performance" })
  if clicked then set_mode("performance") end
  cx = cx + bw + 6
  clicked, bw = button(ctx, "mode_edit", "Editar", cx, y + 12, 32, { active = ui.mode == "edit" })
  if clicked then set_mode("edit") end
  cx = cx + bw + 6
  clicked, bw = button(ctx, "mode_settings", "Configurações", cx, y + 12, 32, { active = ui.mode == "settings" })
  if clicked then set_mode("settings") end
  cx = cx + bw + 6
  clicked, bw = button(ctx, "mode_mapping", "Mapeamento", cx, y + 12, 32, { active = ui.mode == "mapping" })
  if clicked then set_mode("mapping") end
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
local PARAM_H, PARAM_GAP, ADD_H = 50, 6, 34

-- "+ parâmetro": a camada espera um controle; linha do Mapeamento existente
-- ou controle novo (vira linha) passam a ser parâmetro dela e abrem o quadro
-- do nome (RF-153–RF-157).
local function start_pick(song, slot)
  ui.param_pick = { slot = slot }
  learn.start_pick(function(p)
    ui.param_pick = nil
    local row_id = p.row_id or kontakt_cc.add_from_learn(p.msg).id
    local ok, err = layer_params.bind(song, slot, row_id)
    if ok then
      name_edit = { song = song, row_id = row_id, buf = "", open = true }
    else
      ui.param_error = { text = err == "full" and "A camada já tem 4 parâmetros" or "Não deu para ligar o parâmetro", at = now }
    end
    return kontakt_cc.mapping(row_id)
  end)
end

local function add_button(ctx, dl, x, y, w, song, slot)
  local waiting = ui.param_pick ~= nil and ui.param_pick.slot == slot
  if button(ctx, "padd" .. slot, "", x, y, ADD_H, { w = w, active = waiting, accent = theme.C.learn }) then
    cancel_pick()
    if not waiting then start_pick(song, slot) end
    waiting = not waiting
  end
  local fg = waiting and theme.C.ink or theme.C.learn
  local lines = waiting and { "Mexa o", "controle…" } or { "+ parâmetro" }
  local ty = y + (ADD_H - #lines * 14) / 2
  for _, s in ipairs(lines) do
    txt(ctx, dl, "small", x + (w - size(ctx, "small", s)) / 2, ty, fg, s)
    ty = ty + 14
  end
end

-- Quadro do nome depois de ligar: Enter salva; vazio ou Esc fica com o nome
-- da linha do Mapeamento (RF-157, RF-158).
local function name_popup(ctx)
  if not name_edit then return end
  if name_edit.open then
    ImGui.OpenPopup(ctx, "param_name")
    name_edit.open, name_edit.focus = false, true
  end
  if not ImGui.BeginPopup(ctx, "param_name") then
    name_edit = nil
    return
  end
  local row = kontakt_cc.get(name_edit.row_id)
  ImGui.Text(ctx, "Nome do parâmetro nesta música")
  if name_edit.focus then
    ImGui.SetKeyboardFocusHere(ctx)
    name_edit.focus = false
  end
  ImGui.SetNextItemWidth(ctx, 240)
  local _, buf = ImGui.InputTextWithHint(ctx, "##param_name", row and row.name or "", name_edit.buf)
  name_edit.buf = buf
  local close = false
  if ImGui.Button(ctx, "Salvar") or ImGui.IsKeyPressed(ctx, ImGui.Key_Enter, false) then
    layer_params.rename(name_edit.song, name_edit.row_id, name_edit.buf)
    close = true
  end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "Enviar p/ Learn") then kontakt_cc.send_learn(name_edit.row_id, now) end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "Abrir Kontakt") then kontakt_cc.open_kontakt() end
  if ImGui.IsKeyPressed(ctx, ImGui.Key_Escape, false) then close = true end
  if close then
    name_edit = nil
    ImGui.CloseCurrentPopup(ctx)
  end
  ImGui.EndPopup(ctx)
end

-- Parâmetro fixo da camada (RF-143–RF-149): nome em cima; knob com o valor
-- grande e uma barra; botão com a pílula ON/OFF; "—" sem valor conhecido.
-- A borda acende por um instante quando o controle é mexido.
local function param_box(ctx, dl, x, y, w, p)
  ImGui.DrawList_AddRectFilled(dl, x, y, x + w, y + PARAM_H, theme.C.raise, theme.R.r1)
  ImGui.DrawList_AddRect(dl, x, y, x + w, y + PARAM_H, p.flash and theme.C.text or theme.C.line, theme.R.r1, 0, p.flash and 2 or 1)
  ImGui.DrawList_PushClipRect(dl, x + 6, y, x + w - 6, y + PARAM_H, true)
  txt(ctx, dl, "small", x + 7, y + 5, theme.C.muted, p.name)
  ImGui.DrawList_PopClipRect(dl)
  local iy, iw = y + 22, w - 14
  if p.kind == "knob" or p.kind == "encoder" then
    txt(ctx, dl, "readout", x + 7, iy - 1, theme.C.text, p.value and tostring(p.value) or "—")
    local by = y + PARAM_H - 8
    ImGui.DrawList_AddRectFilled(dl, x + 7, by, x + 7 + iw, by + 3, theme.C.bg, 2)
    if p.value then ImGui.DrawList_AddRectFilled(dl, x + 7, by, x + 7 + iw * p.value / 127, by + 3, theme.C.loop, 2) end
    return
  end
  local on, known = p.on, p.value ~= nil
  if p.kind == "momentary" then on = p.held end
  local label = not known and "—" or on and "ON" or "OFF"
  ImGui.DrawList_AddRectFilled(dl, x + 7, iy, x + 7 + iw, iy + 20, on and theme.C.ok or theme.C.bg, 10)
  local tw = size(ctx, "label", label)
  txt(ctx, dl, "label", x + 7 + (iw - tw) / 2, iy + 4, on and theme.C.ink or theme.C.muted, label)
end

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
  local params, most = {}, 0
  for i in ipairs(list) do
    params[i] = layer_params and layer_params.for_layer(song, i, now) or {}
    most = math.max(most, #params[i])
  end
  -- "+ parâmetro" só no Performance, em camada com menos de 4 (RF-152)
  local editable = not ui.stage and layer_params ~= nil and kontakt_cc ~= nil
  if not editable then cancel_pick() end
  local st_learn = learn.state()
  if ui.param_pick and not (st_learn and st_learn.mode == "pick") then ui.param_pick = nil end
  local room = editable and most < layer_params.MAX
  if editable and not room then
    for i in ipairs(list) do room = room or #params[i] < layer_params.MAX end
  end
  local ph = most * (PARAM_H + PARAM_GAP) + (room and ADD_H + PARAM_GAP or 0)
  for i in ipairs(list) do
    local st = layers.layer_state(i)
    local lx = x + (i - 1) * (lw + GAP)
    if not st or lx + lw > x + w then break end
    ImGui.DrawList_AddRectFilled(dl, lx, y, lx + lw, y + fh + 92 + ph, theme.C.panel, theme.R.r2)
    ImGui.DrawList_PushClipRect(dl, lx + 6, y, lx + lw - 6, y + 30, true)
    txt(ctx, dl, "button", lx + 10, y + 10, theme.C.text, st.name)
    ImGui.DrawList_PopClipRect(dl)
    -- duplo clique no nome renomeia a camada desta música (a track)
    ImGui.SetCursorScreenPos(ctx, lx + 6, y + 4)
    ImGui.InvisibleButton(ctx, "lname" .. i, lw - 12, 26)
    if ImGui.IsItemHovered(ctx) then
      ImGui.SetTooltip(ctx, "Duplo clique para renomear")
      if ImGui.IsMouseDoubleClicked(ctx, ImGui.MouseButton_Left) then
        rename = { slot = i, buf = st.name }
        ImGui.OpenPopup(ctx, "rename_layer")
      end
    end

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
    -- LIGADO aceso = camada tocando (mute invertido), como o LED do controle
    if button(ctx, "on" .. i, "LIGADO", lx + 12, by, 26, { w = lw - 24, active = not st.mute, accent = theme.C.ok, style = "label" }) then
      layers.toggle_mute(i)
    end
    widgets.mappable(ctx, { action = "layer_mute", arg = i }, "Liga/desliga " .. st.name)

    local py = by + 26 + 12
    for _, p in ipairs(params[i]) do
      param_box(ctx, dl, lx + 6, py, lw - 12, p)
      py = py + PARAM_H + PARAM_GAP
    end
    if editable and #params[i] < layer_params.MAX then add_button(ctx, dl, lx + 6, py, lw - 12, song, i) end
  end
  name_popup(ctx)
  if rename and ImGui.BeginPopup(ctx, "rename_layer") then
    ImGui.Text(ctx, "Nome da camada nesta música")
    ImGui.SetNextItemWidth(ctx, 220)
    local _, buf = ImGui.InputText(ctx, "##layer_name", rename.buf)
    rename.buf = buf
    if ImGui.Button(ctx, "Renomear") or ImGui.IsKeyPressed(ctx, ImGui.Key_Enter, false) then
      if layers.rename_layer(rename.slot, rename.buf) then
        rename = nil
        ImGui.CloseCurrentPopup(ctx)
      end
    end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Cancelar") then
      rename = nil
      ImGui.CloseCurrentPopup(ctx)
    end
    ImGui.EndPopup(ctx)
  end
  return 22 + fh + 92 + ph
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

-- Aviso "Cutoff 64" por 2 s ao mexer um controle do Mapeamento (RF-135),
-- no topo da área da música, por cima do resto. Parâmetros de camada já
-- ficam fixos na coluna e não ganham aviso (RF-151).
local function banner(ctx, x, y, w, s, color)
  local style = ui.stage and "title" or "strong"
  local tw, th = size(ctx, style, s)
  local pw, ph = tw + 40, th + 24
  local px, py = x + (w - pw) / 2, y + 8
  local dl = ImGui.GetWindowDrawList(ctx)
  ImGui.DrawList_AddRectFilled(dl, px, py, px + pw, py + ph, theme.C.raise2, theme.R.r2)
  ImGui.DrawList_AddRect(dl, px, py, px + pw, py + ph, theme.C.line2, theme.R.r2)
  txt(ctx, dl, style, px + 20, py + 12, color, s)
end

local function touch_toast(ctx, x, y, w)
  local t = kontakt_cc and kontakt_cc.last_touch(now)
  if not t then return end
  if layer_params and snap.song and layer_params.is_param(snap.song, t.row.id) then return end
  local v = t.value or 0
  banner(ctx, x, y, w, t.row.name .. "  " .. ((t.row.kind == "knob" or t.row.kind == "encoder") and tostring(v) or (v >= 64 and "ON" or "OFF")), theme.C.text)
end

-- Avisos da espera do "+ parâmetro": controle de uma ação (RF-156) ou
-- camada cheia.
local NOTICE_S = 3
local function pick_notice(ctx, x, y, w)
  local c = ui.learn_conflict
  if ui.param_pick and c and now - c.at < NOTICE_S then
    local label = settings_view and settings_view.label and settings_view.label(c.mapping) or c.mapping.action
    banner(ctx, x, y, w, string.format('Esse controle já é "%s"', label), theme.C.queue)
  elseif ui.param_error and now - ui.param_error.at < NOTICE_S then
    banner(ctx, x, y, w, ui.param_error.text, theme.C.queue)
  end
end

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
  if ui.mode == "mapping" then
    if mapping_view then mapping_view.draw(ctx, x, y, w, h, snap) end
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
  touch_toast(ctx, cx, y, cw)
  pick_notice(ctx, cx, y, cw)

  ImGui.SetCursorScreenPos(ctx, x, y)
  ImGui.Dummy(ctx, w, math.max(0, cy - y))
end

return M
