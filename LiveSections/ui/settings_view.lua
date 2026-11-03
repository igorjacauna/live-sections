-- Tela de configurações globais (RF-041, RF-042, RF-046, RF-061): teclado do
-- Kontakt e cauda do bypass, saída e velocities dos LEDs (com teste no
-- controlador), tolerância do disparo, cifra no palco (linhas e como abrir no
-- celular), a pasta da biblioteca de músicas, os modos MIDI do REAPER e a
-- lista de mapeamentos.
--
-- Tudo vale para todos os projetos e fica na chave "settings" do config.json,
-- gravada por midi/mappings. Cada mudança é aplicada na hora.
--
-- M.init(deps)    ImGui, theme, kit, mappings, feedback, layers, perf, anim,
--                 learn, model, ui (estado de modo da performance_view),
--                 library (pasta da biblioteca de músicas, RF-192)
-- M.draw(ctx, x, y, w, h, snap) -> altura usada

local web = require("core.web_remote")
local qr = require("core.qrcode")

local M = {}

local ImGui, theme, kit, mappings, feedback, layers, perf, anim, learn, model, ui, library

local GAP = 12
local TWO_COLS_W = 900
local PREVIEW_S = 1.5

local LEDS = {
  { "empty", "Vazio", "pad sem seção" }, { "idle", "Parado", "seção disponível" },
  { "playing", "Tocando", "seção atual" }, { "queued", "Na fila", "pisca até a virada" },
  { "loop", "Loop", "seção presa em loop" },
}

local ACTION_LABEL = {
  trigger_slot = "Seção %d", next_section = "Próxima seção", prev_section = "Seção anterior",
  next_song = "Próxima música", prev_song = "Música anterior", goto_song = "Música %d",
  toggle_loop = "Loop", set_quantize = "Quantize: %s", cycle_quantize = "Quantize (percorrer)",
  play_stop = "Play/Stop", play = "Play", stop = "Stop", cancel = "Cancelar fila", panic = "Panic",
  layer_volume = "Volume da camada %d", layer_mute = "Liga/desliga a camada %d",
  toggle_setlist = "Setlist", tap_tempo = "Tap tempo",
}

local heights = {}

function M.init(deps)
  ImGui, theme, kit = deps.ImGui, deps.theme, deps.kit
  mappings, feedback, layers, perf = deps.mappings, deps.feedback, deps.layers, deps.perf
  anim, learn, model, ui = deps.anim, deps.learn, deps.model, deps.ui
  library = deps.library
end

-- ------------------------------------------------------------------ apoio

local function cfg() return mappings.settings() end
local function save() mappings.save_settings(cfg()) end

function M.label(m)
  local fmt = ACTION_LABEL[m.action] or m.action
  return m.arg ~= nil and fmt:format(m.arg) or (fmt:gsub(" %%[ds]", ""))
end

local function midi_inputs()
  local out = {}
  for i = 0, reaper.GetNumMIDIInputs() - 1 do
    local ok, name = reaper.GetMIDIInputName(i, "")
    if ok and name ~= "" then out[#out + 1] = name end
  end
  return out
end

local function midi_outputs()
  local out = {}
  for i = 0, reaper.GetMaxMidiOutputs() - 1 do
    local ok, name = reaper.GetMIDIOutputName(i, "")
    if ok and name ~= "" then out[#out + 1] = name end
  end
  return out
end

local function apply_layers(snap)
  local c = cfg()
  layers.configure({ keyboard_port = c.keyboard_port, bypass_tail_s = c.bypass_tail_s })
  if snap and snap.song then layers.activate(snap.song, model.songs(), reaper.time_precise()) end
end

local function title(ctx, dl, x, y, text)
  kit.txt(ctx, dl, "title", x, y, theme.C.text, text)
  return 32
end

local function field_label(ctx, dl, x, y, text)
  kit.txt(ctx, dl, "label", x, y, theme.C.muted, text)
  return 18
end

-- Combo com a lista `items`; `none_label` é a primeira opção (valor nil).
local function combo(ctx, id, x, y, w, value, items, none_label)
  ImGui.SetCursorScreenPos(ctx, x, y)
  ImGui.SetNextItemWidth(ctx, w)
  local picked, changed = value, false
  if ImGui.BeginCombo(ctx, id, value or none_label) then
    if none_label and ImGui.Selectable(ctx, none_label, value == nil) then picked, changed = nil, true end
    for _, it in ipairs(items) do
      if ImGui.Selectable(ctx, it, it == value) then picked, changed = it, true end
    end
    ImGui.EndCombo(ctx)
  end
  return changed, picked
end

-- ------------------------------------------------------------------ cartões

local function controller_card(ctx, x, y, w)
  local dl = ImGui.GetWindowDrawList(ctx)
  local ix, iw = x + 16, w - 32
  local cy = y + 16
  cy = cy + title(ctx, dl, ix, cy, "Controlador de performance")
  local modes = {
    { "Enable input for control messages", true,
      "Pads e faders controlam só o Live Sections e não chegam às tracks. Nenhuma nota dos pads vaza para o Kontakt." },
    { "Enable input", false,
      "As mensagens também chegam às tracks. Funciona, mas os pads tocariam notas numa track em All MIDI inputs." },
  }
  for _, m in ipairs(modes) do
    local top = cy
    kit.txt(ctx, dl, "button", ix + 12, cy + 10, theme.C.text, m[1])
    if m[2] then
      local rw = kit.size(ctx, "label", "RECOMENDADO") + 14
      local rx = ix + 12 + kit.size(ctx, "button", m[1]) + 8
      if rx + rw > ix + iw then rx = ix + 12 end
      ImGui.DrawList_AddRectFilled(dl, rx, cy + 8, rx + rw, cy + 26, theme.rgba("#4BDB9C", 0.18), 9)
      kit.txt(ctx, dl, "label", rx + 7, cy + 11, theme.C.ok, "RECOMENDADO")
    end
    cy = cy + 32
    cy = cy + kit.wrapped(ctx, "small", ix + 12, cy, iw - 24, theme.C.muted, m[3]) + 10
    ImGui.DrawList_AddRect(dl, ix, top, ix + iw, cy, m[2] and theme.C.ok or theme.C.line2, theme.R.r1 + 2)
    cy = cy + 8
  end
  cy = cy + kit.wrapped(ctx, "small", ix, cy, iw, theme.C.faint,
    "O modo é escolhido no REAPER: Preferences → MIDI Devices, clique com o botão direito na porta do controlador.")
  return cy - y + 16
end

local function keyboard_card(ctx, x, y, w, snap)
  local dl = ImGui.GetWindowDrawList(ctx)
  local ix, iw = x + 16, w - 32
  local cy = y + 16
  local c = cfg()
  cy = cy + title(ctx, dl, ix, cy, "Teclado do Kontakt")
  cy = cy + field_label(ctx, dl, ix, cy, "PORTA DO TECLADO")
  local body = theme.font(ctx, "body")
  local changed, port = combo(ctx, "##kbd", ix, cy, iw, c.keyboard_port, midi_inputs(), "Nenhum")
  if changed then c.keyboard_port = port; save(); apply_layers(snap) end
  theme.pop_font(ctx, body)
  cy = cy + 44
  cy = cy + kit.wrapped(ctx, "small", ix, cy, iw, theme.C.muted,
    "A track do Kontakt de cada música recebe só este teclado, nunca All MIDI inputs. Só a música atual fica armada; as outras entram em bypass depois da cauda.") + 12
  cy = cy + field_label(ctx, dl, ix, cy, "CAUDA ANTES DO BYPASS")
  body = theme.font(ctx, "body")
  ImGui.SetCursorScreenPos(ctx, ix, cy)
  ImGui.SetNextItemWidth(ctx, iw)
  local moved, tail = ImGui.SliderDouble(ctx, "##tail", c.bypass_tail_s or 5, 0, 15, "%.1f s")
  if moved then c.bypass_tail_s = math.floor(tail * 2 + 0.5) / 2; apply_layers() end
  if ImGui.IsItemDeactivatedAfterEdit(ctx) then save() end
  theme.pop_font(ctx, body)
  cy = cy + 40
  return cy - y + 8
end

local function leds_card(ctx, x, y, w)
  local dl = ImGui.GetWindowDrawList(ctx)
  local ix, iw = x + 16, w - 32
  local cy = y + 16
  local c = cfg()
  cy = cy + title(ctx, dl, ix, cy, "Feedback dos LEDs")
  cy = cy + field_label(ctx, dl, ix, cy, "SAÍDA MIDI")
  local body = theme.font(ctx, "body")
  local changed, out = combo(ctx, "##ledout", ix, cy, iw, c.feedback_out_port, midi_outputs(),
    "Automática (mesmo nome da entrada)")
  if changed then c.feedback_out_port = out; save(); feedback.configure(c) end
  theme.pop_font(ctx, body)
  cy = cy + 48

  local vel = feedback.velocities()
  for _, led in ipairs(LEDS) do
    local state = led[1]
    local v = vel[state] or 0
    -- pad com o brilho da velocity
    ImGui.DrawList_AddRectFilled(dl, ix, cy + 2, ix + 28, cy + 30, theme.C.bg, 6)
    ImGui.DrawList_AddRectFilled(dl, ix + 4, cy + 6, ix + 24, cy + 26, theme.rgba("#E8EDF5", v / 127), 4)
    ImGui.DrawList_AddRect(dl, ix, cy + 2, ix + 28, cy + 30, theme.C.line2, 6)
    kit.txt(ctx, dl, "button", ix + 40, cy + 1, theme.C.text, led[2])
    kit.txt(ctx, dl, "small", ix + 40, cy + 18, theme.C.muted, led[3])
    local tw = kit.size(ctx, "button", "Testar") + 24
    if kit.button(ctx, "ledtest_" .. state, "Testar", ix + iw - tw, cy + 2, 28, { w = tw }) then
      feedback.preview(state, reaper.time_precise(), PREVIEW_S)
    end
    body = theme.font(ctx, "body")
    ImGui.SetCursorScreenPos(ctx, ix + iw - tw - 128, cy + 1)
    ImGui.SetNextItemWidth(ctx, 120)
    local moved, nv = ImGui.InputInt(ctx, "##vel_" .. state, v, 1, 10)
    theme.pop_font(ctx, body)
    if moved then
      c.led_velocity = c.led_velocity or {}
      c.led_velocity[state] = math.max(0, math.min(127, nv))
      feedback.configure(c)
      save()
    end
    cy = cy + 40
  end
  cy = cy + kit.wrapped(ctx, "small", ix, cy, iw, theme.C.faint,
    "A velocity de cada cor depende do controlador. Confira na tabela do manual e use Testar para ver no aparelho.")
  return cy - y + 16
end

local function transport_card(ctx, x, y, w)
  local dl = ImGui.GetWindowDrawList(ctx)
  local ix, iw = x + 16, w - 32
  local cy = y + 16
  local c = cfg()
  cy = cy + title(ctx, dl, ix, cy, "Transporte")
  cy = cy + field_label(ctx, dl, ix, cy, "JANELA DE TOLERÂNCIA")
  local body = theme.font(ctx, "body")
  ImGui.SetCursorScreenPos(ctx, ix, cy)
  ImGui.SetNextItemWidth(ctx, iw)
  local moved, tol = ImGui.SliderInt(ctx, "##tol", math.floor(perf.tolerance_ms() + 0.5), 0, 100, "%d ms")
  if moved then
    tol = math.floor(tol / 5 + 0.5) * 5
    c.tolerance_ms = tol
    perf.set_tolerance(tol)
  end
  if ImGui.IsItemDeactivatedAfterEdit(ctx) then save() end
  theme.pop_font(ctx, body)
  cy = cy + 40
  cy = cy + kit.wrapped(ctx, "small", ix, cy, iw, theme.C.muted, string.format(
    "Um disparo que chega até %d ms depois da virada conta como se tivesse chegado antes dela.",
    math.floor(perf.tolerance_ms() + 0.5))) + 14
  body = theme.font(ctx, "body")
  ImGui.SetCursorScreenPos(ctx, ix, cy)
  local toggled, reduced = ImGui.Checkbox(ctx, "Reduzir animações", c.reduced_motion == true)
  if toggled then c.reduced_motion = reduced; anim.set_reduced(reduced); save() end
  theme.pop_font(ctx, body)
  cy = cy + 32
  return cy - y + 8
end

-- QR Code do endereço: fundo branco com a margem de 4 módulos que os
-- leitores pedem; cada linha escura vira um retângulo só.
local QR_MAX_PX = 240
local QR_QUIET = 4
local qr_pick = 1
local qr_cache = {}      -- [texto] = { matriz, lado }

local function draw_qr(dl, x, y, max_px, text)
  if not qr_cache[text] then qr_cache[text] = { qr.encode(text) } end
  local m, n = qr_cache[text][1], qr_cache[text][2]
  if not m then return 0 end
  local px = math.max(2, math.floor(max_px / (n + 2 * QR_QUIET)))
  local side = px * (n + 2 * QR_QUIET)
  ImGui.DrawList_AddRectFilled(dl, x, y, x + side, y + side, 0xFFFFFFFF, 6)
  local ox, oy = x + px * QR_QUIET, y + px * QR_QUIET
  for r, row in ipairs(m) do
    local c = 1
    while c <= n do
      if row[c] then
        local start = c
        while c <= n and row[c] do c = c + 1 end
        ImGui.DrawList_AddRectFilled(dl, ox + (start - 1) * px, oy + (r - 1) * px, ox + (c - 1) * px, oy + r * px, 0x000000FF)
      else
        c = c + 1
      end
    end
  end
  return side
end

local function chart_card(ctx, x, y, w)
  local dl = ImGui.GetWindowDrawList(ctx)
  local ix, iw = x + 16, w - 32
  local cy = y + 16
  local c = cfg()
  cy = cy + title(ctx, dl, ix, cy, "Cifra no palco")
  cy = cy + field_label(ctx, dl, ix, cy, "LINHAS DA PRÓXIMA SEÇÃO")
  local body = theme.font(ctx, "body")
  ImGui.SetCursorScreenPos(ctx, ix, cy)
  ImGui.SetNextItemWidth(ctx, 120)
  local moved, n = ImGui.InputInt(ctx, "##chart_lines", c.chart_lines or 6, 1, 2)
  theme.pop_font(ctx, body)
  if moved then c.chart_lines = math.max(2, math.min(16, n)); save() end
  cy = cy + 40
  cy = cy + kit.wrapped(ctx, "small", ix, cy, iw, theme.C.muted,
    "A cifra rola como um teleprompter: o verso atual fica destacado no meio da tela e os que passaram ficam apagados. No fim da seção aparecem até estas linhas da próxima (acordes e letra contam separado).") + 14
  cy = cy + field_label(ctx, dl, ix, cy, "NO CELULAR OU TABLET")
  local info = web.info()
  local problems = {}
  if not info.page_installed then
    problems[#problems + 1] = "Página não instalada: Extensions → ReaPack → Synchronize packages (pacote \"livesections.html\")."
  end
  if #info.ports == 0 then
    problems[#problems + 1] = "Web Interface desligada: Preferences → Control/OSC/web → Add → Web browser interface → OK."
  elseif #info.ips == 0 then
    problems[#problems + 1] = "Não achei o IP deste computador na rede local. Ele está conectado ao Wi-Fi ou a um cabo de rede?"
  end
  for _, t in ipairs(problems) do cy = cy + kit.wrapped(ctx, "small", ix, cy, iw, theme.C.queue, t) + 6 end
  if #info.urls > 0 then
    cy = cy + kit.wrapped(ctx, "small", ix, cy, iw, theme.C.muted,
      "Com o celular no mesmo Wi-Fi deste computador, aponte a câmera para o código ou abra o endereço no navegador:") + 10
    if not info.urls[qr_pick] then qr_pick = 1 end
    cy = cy + draw_qr(dl, ix, cy, math.min(iw, QR_MAX_PX), info.urls[qr_pick]) + 12
    for i, url in ipairs(info.urls) do
      local cw = kit.size(ctx, "button", "Copiar") + 24
      local qw = #info.urls > 1 and kit.size(ctx, "button", "QR") + 24 or 0
      ImGui.DrawList_PushClipRect(dl, ix, cy, ix + iw - cw - qw - 12, cy + 30, true)
      kit.txt(ctx, dl, "strong", ix, cy + 6, i == qr_pick and theme.C.text or theme.C.muted, url)
      ImGui.DrawList_PopClipRect(dl)
      if qw > 0 and kit.button(ctx, "qr_url" .. i, "QR", ix + iw - cw - qw - 6, cy, 30, { w = qw, active = i == qr_pick }) then
        qr_pick = i
      end
      if kit.button(ctx, "copy_url" .. i, "Copiar", ix + iw - cw, cy, 30, { w = cw }) then
        ImGui.SetClipboardText(ctx, url)
      end
      cy = cy + 38
    end
  end
  if #info.urls > 0 and reaper.GetOS():lower():match("^win") then
    cy = cy + kit.wrapped(ctx, "small", ix, cy, iw, theme.C.faint,
      "Não abre no celular? No Windows, o firewall precisa liberar o REAPER em rede privada (ele pergunta na primeira vez), e o Wi-Fi deve estar como rede privada, não pública.") + 8
  end
  if #info.urls > 0 then
    cy = cy + kit.wrapped(ctx, "small", ix, cy, iw, theme.C.faint,
      "Chrome do Android com erro \"too many retries\"? Nas configurações do celular: Apps → Chrome → Permissões → permita \"Dispositivos por perto\".") + 8
  end
  local rw = kit.size(ctx, "button", "Verificar de novo") + 24
  if kit.button(ctx, "web_refresh", "Verificar de novo", ix, cy + 4, 30, { w = rw }) then web.info(true) end
  return cy + 4 + 30 - y + 16
end

local function mappings_card(ctx, x, y, w)
  local dl = ImGui.GetWindowDrawList(ctx)
  local ix, iw = x + 16, w - 32
  local cy = y + 16
  title(ctx, dl, ix, cy, "Mapeamentos MIDI")
  local gl = "Learn global"
  local gw = kit.size(ctx, "button", gl) + 46
  if kit.button(ctx, "learn_global", gl, ix + iw - gw, cy - 2, 30, { icon = "learn", w = gw }) then
    learn.start_global()
    ui.mode = "performance"
  end
  cy = cy + 40

  local list = {}
  -- os controles do Mapeamento ficam na tela dele
  for _, m in ipairs(mappings.all()) do
    if m.action ~= "kontakt_cc" then list[#list + 1] = m end
  end
  table.sort(list, function(a, b) return M.label(a) < M.label(b) end)
  if #list == 0 then
    cy = cy + kit.wrapped(ctx, "small", ix, cy, iw, theme.C.muted, "Nenhum mapeamento ainda.") + 10
  else
    local cols = { ix, ix + iw * 0.34, ix + iw * 0.58 }
    field_label(ctx, dl, cols[1], cy, "CONTROLE")
    field_label(ctx, dl, cols[2], cy, "MENSAGEM")
    field_label(ctx, dl, cols[3], cy, "DISPOSITIVO")
    cy = cy + 24
    local remove
    for i, m in ipairs(list) do
      ImGui.DrawList_AddLine(dl, ix, cy - 4, ix + iw, cy - 4, theme.C.line)
      ImGui.DrawList_PushClipRect(dl, ix, cy, ix + iw - 100, cy + 30, true)
      kit.txt(ctx, dl, "button", cols[1], cy + 6, theme.C.text, M.label(m))
      kit.txt(ctx, dl, "num", cols[2], cy + 6, theme.C.muted, require("ui.widgets").describe(m))
      kit.txt(ctx, dl, "small", cols[3], cy + 7, theme.C.muted, m.port_name)
      ImGui.DrawList_PopClipRect(dl)
      local rw = kit.size(ctx, "button", "Remover") + 24
      if kit.button(ctx, "unmap" .. i, "Remover", ix + iw - rw, cy, 28, { w = rw }) then remove = m end
      cy = cy + 36
    end
    if remove then
      mappings.remove(remove.action, remove.arg)
      mappings.save()
      feedback.forget(remove)
    end
  end
  cy = cy + kit.wrapped(ctx, "small", ix, cy, iw, theme.C.faint,
    "Os mapeamentos valem para todos os projetos. Cada um responde só à porta em que foi aprendido. Para mapear, clique com o botão direito num controle e escolha Learn MIDI.")
  return cy - y + 16
end

local copied_at = nil

-- Ciclos por segundo e tempo de cada ciclo (core/diag): se o REAPER engasga
-- com o Live Sections aberto, estes números dizem onde.
local function perf_card(ctx, x, y, w)
  local dl = ImGui.GetWindowDrawList(ctx)
  local ix, iw = x + 16, w - 32
  local cy = y + 16
  cy = cy + title(ctx, dl, ix, cy, "Desempenho")
  local s = require("core.diag").stats(reaper.time_precise())
  local text = s and string.format("%.0f ciclos/s · ciclo %.1f ms (máx. %.0f ms) · %.0f mensagens MIDI/s",
    s.fps, s.avg_ms, s.max_ms, s.midi_per_s) or "Medindo…"
  local slow = s and (s.fps < 20 or s.max_ms > 50)
  kit.txt(ctx, dl, "num", ix, cy, slow and theme.C.danger or theme.C.text, text)
  cy = cy + 26
  cy = cy + kit.wrapped(ctx, "small", ix, cy, iw, theme.C.faint,
    "Normal: uns 30 ciclos/s e ciclo de poucos ms. Se ficar vermelho ao mexer num fader, mande estes números.")
  cy = cy + 10

  -- engasgos: pausas do REAPER inteiro, com o que o script fazia antes
  local diag = require("core.diag")
  local list = diag.hitches()
  kit.txt(ctx, dl, "label", ix, cy, theme.C.muted, string.format("ENGASGOS (%d)", #list))
  cy = cy + 20
  if #list == 0 then
    cy = cy + kit.wrapped(ctx, "small", ix, cy, iw, theme.C.faint, "Nenhuma pausa maior que 70 ms nem falha de áudio desde que o script abriu.")
  else
    for i = #list, math.max(1, #list - 4), -1 do
      cy = cy + kit.wrapped(ctx, "small", ix, cy, iw, theme.C.text, diag.line(list[i])) + 4
    end
  end
  cy = cy + 8
  local clicked, bw = kit.button(ctx, "diag_copy", "Copiar relatório", ix, cy, 30, { style = "small" })
  if clicked then
    ImGui.SetClipboardText(ctx, diag.report())
    copied_at = reaper.time_precise()
  end
  if kit.button(ctx, "diag_clear", "Limpar", ix + bw + 6, cy, 30, { style = "small" }) then diag.reset() end
  if copied_at and reaper.time_precise() - copied_at < 3 then
    kit.txt(ctx, dl, "small", ix + bw + 6 + kit.size(ctx, "small", "Limpar") + 36, cy + 7, theme.C.ok, "Copiado.")
  end
  cy = cy + 40
  cy = cy + kit.wrapped(ctx, "small", ix, cy, iw, theme.C.faint,
    "\"falha de áudio\" é o REAPER avisando que o áudio cortou (mesmo sem a tela travar). \"ciclo\" é o intervalo entre dois quadros da tela; \"script\" é quanto o Live Sections demorou no quadro anterior; o resto foi o REAPER (áudio, plugins, salvamento automático). \"mexeu\" diz o que o script mudou no REAPER no meio segundo antes.")
  return cy - y + 16
end

-- Pasta da biblioteca de músicas (RF-192). Sem SWS não há seletor de pasta:
-- Escolher pede qualquer arquivo de dentro dela; o caminho também pode ser
-- digitado.
local lib_buf = nil

local function parent(path) return path and path:match("^(.*)[\\/][^\\/]*$") end

-- Pasta da biblioteca a partir do arquivo escolhido: um musica.json ou um
-- áudio de uma música apontam para a pasta acima da música.
local function library_of(file)
  local folder = parent(file)
  local name = (file or ""):match("([^\\/]*)$"):lower()
  if name == "musica.json" then return parent(folder) end
  if folder and folder:match("[\\/]audio$") and reaper.file_exists(parent(folder) .. "/musica.json") then
    return parent(parent(folder))
  end
  return folder
end

local function library_card(ctx, x, y, w)
  local dl = ImGui.GetWindowDrawList(ctx)
  local ix, iw = x + 16, w - 32
  local cy = y + 16
  cy = cy + title(ctx, dl, ix, cy, "Biblioteca de músicas")
  cy = cy + field_label(ctx, dl, ix, cy, "PASTA DA BIBLIOTECA")
  local path, ok = library.dir()
  local chosen = type(cfg().library_dir) == "string" and cfg().library_dir ~= ""
  local body = theme.font(ctx, "body")
  ImGui.SetCursorScreenPos(ctx, ix, cy)
  ImGui.SetNextItemWidth(ctx, iw)
  local _, buf = ImGui.InputText(ctx, "##library_dir", lib_buf or path)
  lib_buf = buf ~= path and buf or nil
  if ImGui.IsItemDeactivatedAfterEdit(ctx) then
    local typed = (buf or ""):gsub("^%s+", ""):gsub("%s+$", "")
    library.set_dir(typed ~= "" and typed or nil)
    lib_buf = nil
  end
  theme.pop_font(ctx, body)
  cy = cy + 36
  local status = not ok and "Pasta não encontrada. Escolha outra ou volte à padrão."
    or chosen and "Pasta escolhida." or "Pasta padrão, nos recursos do REAPER."
  cy = cy + kit.wrapped(ctx, "small", ix, cy, iw, ok and theme.C.muted or theme.C.danger, status) + 10
  local bx = ix
  local choose_w = kit.size(ctx, "button", "Escolher") + 24
  if kit.button(ctx, "library_choose", "Escolher", bx, cy, 30, { w = choose_w }) then
    local picked, file = reaper.GetUserFileNameForRead("", "Escolha qualquer arquivo dentro da pasta da biblioteca", "")
    local folder = picked and library_of(file)
    if folder and folder ~= "" then library.set_dir(folder); lib_buf = nil end
  end
  bx = bx + choose_w + 6
  if chosen then
    local def_w = kit.size(ctx, "button", "Padrão") + 24
    if kit.button(ctx, "library_default", "Padrão", bx, cy, 30, { w = def_w }) then
      library.set_dir(nil)
      lib_buf = nil
    end
    bx = bx + def_w + 6
  end
  local open_w = kit.size(ctx, "button", "Abrir pasta") + 24
  if ok and kit.button(ctx, "library_open", "Abrir pasta", bx, cy, 30, { w = open_w }) then
    library.open_folder(path)
  end
  cy = cy + 40
  cy = cy + kit.wrapped(ctx, "small", ix, cy, iw, theme.C.faint,
    "Cada música exportada fica numa pasta com os áudios. Para montar setlists em outro computador, leve esta pasta.") + 4
  return cy - y + 16
end

-- ------------------------------------------------------------------ desenho

local function card(ctx, id, x, y, w, fn)
  local dl = ImGui.GetWindowDrawList(ctx)
  ImGui.DrawList_AddRectFilled(dl, x, y, x + w, y + (heights[id] or 0), theme.C.panel, theme.R.r2)
  local h = fn(ctx, x, y, w)
  heights[id] = h
  return h
end

function M.draw(ctx, x, y, w, h, snap)
  local two = w >= TWO_COLS_W
  local cw = two and (w - GAP) / 2 or w
  local col_y = { y, y }
  local function place(id, fn, col)
    col = two and col or 1
    local cx = x + (col - 1) * (cw + GAP)
    col_y[col] = col_y[col] + card(ctx, id, cx, col_y[col], cw, fn) + GAP
  end
  place("controller", controller_card, 1)
  place("keyboard", function(c, cx, cy, ww) return keyboard_card(c, cx, cy, ww, snap) end, 2)
  place("leds", leds_card, 1)
  place("perf", perf_card, 1)
  place("transport", transport_card, 2)
  place("chart", chart_card, 2)
  if library then place("library", library_card, 1) end
  local wide_y = math.max(col_y[1], col_y[2])
  local mh = card(ctx, "mappings", x, wide_y, w, mappings_card)
  local bottom = wide_y + mh + GAP
  ImGui.SetCursorScreenPos(ctx, x, y)
  ImGui.Dummy(ctx, w, math.max(0, bottom - y))
  return bottom - y
end

return M
