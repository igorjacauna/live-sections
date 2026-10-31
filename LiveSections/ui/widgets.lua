-- Widgets desenhados com a DrawList, no visual do protótipo aprovado.
--
-- Controle mapeável (RF-030, RF-031, RF-034, RF-036): qualquer item da tela
-- ligado a um controle { action, arg? } ganha menu de clique direito (Learn
-- MIDI, Remover mapeamento, Ver mapeamento), pulsa em lilás com "Aguardando
-- MIDI…" durante o learn, fica tracejado no Learn global e pisca quando
-- recebe o comando.
--
-- Card de seção (RF-072, RF-073): cor da região, progresso quando tocando,
-- borda tracejada pulsando na fila com contagem regressiva em batidas e ✕.
--
-- M.init(ImGui, theme, anim, learn, mappings)
-- M.frame(ctx, now)                          uma vez por frame: Esc, relógio
-- M.mappable(ctx, control, label)            depois do item que o representa
-- M.flash(control)                           o controle recebeu o comando
-- M.section_card(ctx, id, card, w, h) -> "trigger"|"cancel"|nil
--   card = { name, color (nativa do REAPER), slot, bars, state, progress, beats_left, control? }
--   state: "idle"|"cursor"|"playing"|"queued"|"loop"
-- M.describe(mapping) -> texto do mapeamento

local M = {}

local ImGui, theme, anim, learn, mappings
local now = 0
local flashes = {}          -- [chave do controle] = instante
local FLASH_S = 0.45
local CARD_PAD = 14

function M.init(imgui, theme_mod, anim_mod, learn_mod, mappings_mod)
  ImGui, theme, anim, learn, mappings = imgui, theme_mod, anim_mod, learn_mod, mappings_mod
  flashes = {}
end

local function key(control) return control.action .. ":" .. tostring(control.arg or "") end

local function same_control(a, b) return a and b and a.action == b.action and a.arg == b.arg end

-- ------------------------------------------------------------------ textos

local CHANNEL = " · canal %d"

function M.describe(m)
  if not m then return "Sem mapeamento" end
  local text
  if m.msg_type == "note" then text = ("Nota %d" .. CHANNEL):format(m.number, m.channel)
  elseif m.msg_type == "cc" then text = ("CC %d" .. CHANNEL):format(m.number, m.channel)
  elseif m.msg_type == "pc" then text = ("Program Change %d" .. CHANNEL):format(m.number, m.channel)
  else text = ("Pitch bend" .. CHANNEL):format(m.channel) end
  return text .. "\n" .. m.port_name
end

-- ------------------------------------------------------------------ desenho

local function text(ctx, dl, style, x, y, color, s)
  local pushed = theme.font(ctx, style)
  ImGui.DrawList_AddText(dl, x, y, color, s)
  theme.pop_font(ctx, pushed)
end

local function text_size(ctx, style, s)
  local pushed = theme.font(ctx, style)
  local w, h = ImGui.CalcTextSize(ctx, s)
  theme.pop_font(ctx, pushed)
  return w, h
end

-- Retângulo tracejado (bordas retas; os cantos ficam abertos).
local function dashed_rect(dl, x1, y1, x2, y2, color, r, thick, phase)
  local dash, gap = 7, 5
  local function seg(ax, ay, bx, by)
    local len = math.sqrt((bx - ax) ^ 2 + (by - ay) ^ 2)
    local dx, dy = (bx - ax) / len, (by - ay) / len
    local t = -phase % (dash + gap)
    while t < len do
      local a, b = math.max(0, t), math.min(len, t + dash)
      if b > a then ImGui.DrawList_AddLine(dl, ax + dx * a, ay + dy * a, ax + dx * b, ay + dy * b, color, thick) end
      t = t + dash + gap
    end
  end
  seg(x1 + r, y1, x2 - r, y1)
  seg(x2, y1 + r, x2, y2 - r)
  seg(x2 - r, y2, x1 + r, y2)
  seg(x1, y2 - r, x1, y1 + r)
end

-- Cor nativa de região do REAPER → 0xRRGGBBAA. Sem cor, a padrão.
function M.region_color(native)
  if not native or native == 0 then return theme.rgba(theme.DEFAULT_SECTION_COLOR) end
  local r, g, b = reaper.ColorFromNative(native & 0xFFFFFF)
  return (r << 24) | (g << 16) | (b << 8) | 0xFF
end

-- ------------------------------------------------------------------ mapeável

function M.frame(ctx, t)
  now = t
  if learn.state() and ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) then learn.cancel() end
end

function M.flash(control) flashes[key(control)] = now end

local function menu(ctx, control, label)
  local id = "##map:" .. key(control)
  if ImGui.IsItemClicked(ctx, ImGui.MouseButton_Right) then ImGui.OpenPopup(ctx, id) end
  if not ImGui.BeginPopup(ctx, id) then return end
  local m = mappings.get(control.action, control.arg)
  local pushed = theme.font(ctx, "label")
  ImGui.TextColored(ctx, theme.C.muted, label:upper())
  theme.pop_font(ctx, pushed)
  if ImGui.MenuItem(ctx, "Learn MIDI") then learn.start(control) end
  if ImGui.MenuItem(ctx, "Remover mapeamento", nil, false, m ~= nil) then
    mappings.remove(control.action, control.arg)
    mappings.save()
  end
  if ImGui.BeginMenu(ctx, "Ver mapeamento", m ~= nil) then
    ImGui.Text(ctx, M.describe(m))
    ImGui.EndMenu(ctx)
  end
  ImGui.EndPopup(ctx)
end

-- Chamar logo depois do item (botão, card, fader) que representa o controle.
function M.mappable(ctx, control, label)
  local x1, y1 = ImGui.GetItemRectMin(ctx)
  local x2, y2 = ImGui.GetItemRectMax(ctx)
  local dl = ImGui.GetWindowDrawList(ctx)
  local state = learn.state()

  if state and state.mode == "global" and ImGui.IsItemClicked(ctx, ImGui.MouseButton_Left) then
    learn.select(control)
  end
  menu(ctx, control, label)

  local learning = state and same_control(state.control, control)
  if learning then
    local p = anim.pulse(now, 0.9)
    ImGui.DrawList_AddRect(dl, x1 - 3, y1 - 3, x2 + 3, y2 + 3, theme.C.learn, theme.R.r2, 0, 2)
    ImGui.DrawList_AddRect(dl, x1 - 3 - 7 * p, y1 - 3 - 7 * p, x2 + 3 + 7 * p, y2 + 3 + 7 * p,
      theme.mix(theme.C.learn, theme.C.learn & 0xFFFFFF00, p), theme.R.r2 + 4, 0, 2)
    local tip = theme.STATE.learn.label
    local tw, th = text_size(ctx, "button", tip)
    local tx, ty = (x1 + x2) / 2 - tw / 2 - 12, y1 - th - 22
    ImGui.DrawList_AddRectFilled(ImGui.GetForegroundDrawList(ctx), tx, ty, tx + tw + 24, ty + th + 14, theme.C.learn, 9)
    text(ctx, ImGui.GetForegroundDrawList(ctx), "button", tx + 12, ty + 7, theme.C.ink, tip)
  elseif state and state.mode == "global" then
    local hovered = ImGui.IsItemHovered(ctx)
    if hovered then
      ImGui.DrawList_AddRect(dl, x1 - 2, y1 - 2, x2 + 2, y2 + 2, theme.C.learn, theme.R.r2, 0, 1.5)
    else
      dashed_rect(dl, x1 - 2, y1 - 2, x2 + 2, y2 + 2, theme.mix(theme.C.learn, theme.C.bg, 0.25), 6, 1.5, 0)
    end
  end

  local at = flashes[key(control)]
  if at then
    local k = (now - at) / FLASH_S
    if k >= 1 or anim.reduced() then
      flashes[key(control)] = nil
    else
      local grow = 4 * k
      local color = theme.mix(theme.C.text, theme.C.text & 0xFFFFFF00, k)
      ImGui.DrawList_AddRect(dl, x1 - 3 - grow, y1 - 3 - grow, x2 + 3 + grow, y2 + 3 + grow, color, 14, 0, 2)
    end
  end
end

-- ------------------------------------------------------------------ card

local STATUS = {
  idle    = { label = "Pronta" },
  cursor  = { label = "No cursor" },
  playing = { icon = "play", label = "Tocando" },
  queued  = { icon = "clock", label = "Na fila" },
  loop    = { icon = "loop", label = "Loop" },
}
M.CARD_STATUS = STATUS

function M.section_card(ctx, id, card, w, h)
  local x, y = ImGui.GetCursorScreenPos(ctx)
  local result = nil
  local state = card.state or "idle"
  local bx, by = x + w - CARD_PAD - 28, y + CARD_PAD

  -- o ✕ vem antes do card: entre itens sobrepostos, o primeiro fica com o clique
  local x_hovered = false
  if state == "queued" then
    ImGui.SetCursorScreenPos(ctx, bx, by)
    if ImGui.InvisibleButton(ctx, id .. ":x", 28, 28) then result = "cancel" end
    x_hovered = ImGui.IsItemHovered(ctx)
    ImGui.SetCursorScreenPos(ctx, x, y)
  end
  ImGui.InvisibleButton(ctx, id, w, h)
  local hovered = ImGui.IsItemHovered(ctx)
  if ImGui.IsItemClicked(ctx, ImGui.MouseButton_Left) and not (learn.state() and learn.state().mode == "global") then
    result = "trigger"
  end
  if card.control then M.mappable(ctx, card.control, card.name) end

  local dl = ImGui.GetWindowDrawList(ctx)
  local c = M.region_color(card.color)
  local lift = anim.value(id .. ":lift", hovered and -2 or 0, ImGui.GetDeltaTime(ctx))
  local y1, x2, y2 = y + lift, x + w, y + h + lift
  local r = theme.R.r3

  -- fundo: a cor da região sobre o painel, mais forte em cima
  ImGui.DrawList_AddRectFilled(dl, x, y1, x2, y2, theme.mix(theme.C.panel, c, 0.12), r)
  ImGui.DrawList_AddRectFilled(dl, x, y1, x2, y1 + h * 0.5, theme.mix(theme.C.panel, c, 0.2) & 0xFFFFFF80, r, ImGui.DrawFlags_RoundCornersTop)

  -- progresso (tocando ou em loop, inclusive quando a seção repete)
  if state == "playing" or state == "loop" then
    local p = math.max(0, math.min(1, card.progress or 0))
    local fill = state == "loop" and (theme.C.loop & 0xFFFFFF4D) or (c & 0xFFFFFF61)
    ImGui.DrawList_PushClipRect(dl, x, y1, x + w * p, y2, true)
    ImGui.DrawList_AddRectFilled(dl, x, y1, x2, y2, fill, r)
    ImGui.DrawList_PopClipRect(dl)
  end

  -- borda
  if state == "queued" then
    local p = anim.pulse(now, 1)
    ImGui.DrawList_AddRect(dl, x - 9 * p, y1 - 9 * p, x2 + 9 * p, y2 + 9 * p,
      theme.mix(theme.C.queue & 0xFFFFFF73, theme.C.queue & 0xFFFFFF00, p), r + 6, 0, 2)
    dashed_rect(dl, x, y1, x2, y2, theme.C.queue, r, 2, anim.reduced() and 0 or now * 12)
  elseif state == "playing" then
    ImGui.DrawList_AddRect(dl, x, y1, x2, y2, c, r, 0, 2)
  elseif state == "loop" then
    ImGui.DrawList_AddRect(dl, x, y1, x2, y2, theme.C.loop, r, 0, 2)
  elseif state == "cursor" then
    ImGui.DrawList_AddRect(dl, x, y1, x2, y2, theme.mix(theme.C.line, theme.C.text, 0.45), r, 0, 1)
  else
    ImGui.DrawList_AddRect(dl, x, y1, x2, y2, theme.mix(theme.C.line, c, hovered and 0.65 or 0.3), r, 0, 1)
  end

  -- topo: número do slot e duração, ou contagem regressiva e ✕ na fila
  local px, py = x + CARD_PAD, y1 + CARD_PAD
  if card.slot then
    local s = tostring(card.slot)
    local sw = text_size(ctx, "num", s)
    local bw = math.max(28, sw + 14)
    ImGui.DrawList_AddRectFilled(dl, px, py, px + bw, py + 28, c, theme.R.r1)
    text(ctx, dl, "num", px + (bw - sw) / 2, py + 6, theme.C.ink, s)
  end
  if state == "queued" then
    local xh = x_hovered
    ImGui.DrawList_AddRectFilled(dl, bx, py, bx + 28, py + 28, xh and theme.C.queue or theme.mix(theme.C.panel, theme.C.queue, 0.2), theme.R.r1)
    theme.icon(dl, "x", bx + 6, py + 6, 16, xh and theme.C.ink or theme.C.queue)
    local n = tostring(card.beats_left or 0)
    local nw = text_size(ctx, "readout", n)
    local lw = text_size(ctx, "label", "BAT.")
    local cx = bx - 10 - lw - 4 - nw
    text(ctx, dl, "readout", cx, py + 4, theme.C.queue, n)
    text(ctx, dl, "label", cx + nw + 4, py + 10, theme.C.queue, "BAT.")
  elseif card.bars then
    local s = card.bars == 1 and "1 compasso" or (card.bars .. " compassos")
    local sw = text_size(ctx, "small", s)
    text(ctx, dl, "small", x2 - CARD_PAD - sw, py + 6, theme.C.muted, s)
  end

  -- base: estado (ícone + texto) e nome
  local st = STATUS[state]
  local st_color = (state == "queued" and theme.C.queue) or (state == "loop" and theme.C.loop)
    or ((state == "playing" or state == "cursor") and theme.C.text) or theme.C.muted
  local _, nh = text_size(ctx, "title", card.name)
  local ny = y2 - CARD_PAD - nh
  local sy = ny - 20
  local sx = px
  if st.icon then
    theme.icon(dl, st.icon, sx, sy, 14, st_color)
    sx = sx + 20
  end
  text(ctx, dl, "label", sx, sy + 1, st_color, st.label:upper())
  ImGui.DrawList_PushClipRect(dl, x, y1, x2 - CARD_PAD, y2, true)
  text(ctx, dl, "title", px, ny, theme.C.text, card.name)
  ImGui.DrawList_PopClipRect(dl)

  ImGui.SetCursorScreenPos(ctx, x, y + h)
  ImGui.Dummy(ctx, 0, 0)
  return result
end

return M
