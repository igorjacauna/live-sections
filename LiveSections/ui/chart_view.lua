-- Janela "Cifra": música, anotação, seção com barra de progresso, próxima
-- seção com contagem e as linhas da cifra da seção, a partir do estado de
-- core/stage. É uma
-- janela separada da principal: dá para arrastá-la para outro monitor ou TV.
--
-- M.init(deps)            ImGui, theme, kit
-- M.draw(ctx, state) -> open   desenha a janela; false quando o usuário fecha

local notes = require("core.song_notes")

local M = {}

local ImGui, theme, kit

local TITLE = "Cifra · Live Sections"
local PAD = 20
local NEXT_H = 34          -- altura da linha "A seguir"
local FOCUS_AT = 0.42      -- altura do ponto de leitura na área da cifra
local FOLLOW = 6           -- quão rápido a tela alcança o ponto de leitura (1/s)

-- Teleprompter: o ponto de leitura (state.focus, em linhas) fica fixo perto
-- do meio e a cifra rola contínua até ele. Ao entrar na seção seguinte, o
-- "A seguir" da anterior vira o cabeçalho da nova no mesmo lugar e a rolagem
-- continua; um salto para outra seção muda direto.
local shown = nil          -- { key, song, section, rows, focus, at }

local function index_of(rows, kind)
  for i, r in ipairs(rows or {}) do if r.kind == kind then return i - 1 end end
end

function M.init(deps) ImGui, theme, kit = deps.ImGui, deps.theme, deps.kit end

local function rgba(hex) return theme.rgba(hex or theme.DEFAULT_SECTION_COLOR) end

-- Fonte grande se a linha mais longa couber; senão a pequena.
local function pick_sizes(ctx, rows, w)
  local widest = 0
  for _, row in ipairs(rows) do
    if row.kind ~= "next" and row.kind ~= "header" then
      local tw = kit.size(ctx, "chord_lg", row.text)
      if tw > widest then widest = tw end
    end
  end
  if widest <= w then return "chart_lg", "chord_lg", 46 end
  return "chart_sm", "chord_sm", 32
end

local function header(ctx, dl, x, y, w, state)
  local cy = y
  kit.txt(ctx, dl, "label", x, cy, theme.C.muted, (state.song or "Sem música"):upper())
  cy = cy + 20
  local name = state.section or "Trecho sem seção"
  local color = rgba(state.color)
  ImGui.DrawList_AddRectFilled(dl, x, cy + 6, x + 8, cy + 38, color, 3)
  kit.txt(ctx, dl, "h1", x + 18, cy, theme.C.text, name)
  if state.bars then
    local pos = string.format("comp. %d/%d", state.bar, state.bars)
    kit.txt(ctx, dl, "readout", x + w - kit.size(ctx, "readout", pos), cy + 10, theme.C.muted, pos)
  end
  cy = cy + 46
  -- progresso da seção, na cor dela
  if state.progress then
    ImGui.DrawList_AddRectFilled(dl, x, cy, x + w, cy + 6, theme.C.raise, 3)
    ImGui.DrawList_AddRectFilled(dl, x, cy, x + w * state.progress, cy + 6, color, 3)
  end
  cy = cy + 16
  if state.next then
    local label = state.queued and string.format("NA FILA · %s em %d bat.", state.next, state.beats_left or 0)
      or ("A SEGUIR · " .. state.next)
    kit.txt(ctx, dl, "button", x, cy, state.queued and theme.C.queue or theme.C.muted, label)
    cy = cy + 26
  end
  if state.note then
    local top = cy + 2
    for _, line in ipairs(notes.lines(state.note)) do
      cy = cy + kit.wrapped(ctx, "strong", x + 14, cy + 2, w - 14, theme.C.text, line) + 4
    end
    ImGui.DrawList_AddRectFilled(dl, x, top, x + 4, cy, theme.C.queue, 2)
    cy = cy + 4
  end
  ImGui.DrawList_AddLine(dl, x, cy + 6, x + w, cy + 6, theme.C.line)
  return cy + 18 - y
end

local function grid_row(ctx, dl, x, y, w, row, lyric, chord, line_h)
  local cells = row.cells or {}
  local cw = math.min(180, w / math.max(1, #cells))
  for i, c in ipairs(cells) do
    local cx = x + (i - 1) * cw
    local on = row.cell == i
    ImGui.DrawList_AddRectFilled(dl, cx + 2, y, cx + cw - 4, y + line_h - 6, on and theme.C.text or theme.C.raise, 8)
    kit.txt(ctx, dl, chord, cx + 12, y + 4, on and theme.C.ink or (row.current and theme.C.queue or theme.C.muted), c)
  end
end

function M.draw(ctx, state)
  ImGui.SetNextWindowSize(ctx, 760, 560, ImGui.Cond_FirstUseEver)
  ImGui.SetNextWindowCollapsed(ctx, false, ImGui.Cond_Always)
  local visible, open = ImGui.Begin(ctx, TITLE, true, ImGui.WindowFlags_NoCollapse)
  if not visible then return open end
  local x, y = ImGui.GetCursorScreenPos(ctx)
  local w, h = ImGui.GetContentRegionAvail(ctx)
  local dl = ImGui.GetWindowDrawList(ctx)
  x, w = x + PAD / 2, w - PAD

  if not state or not state.song then
    kit.txt(ctx, dl, "title", x, y + 20, theme.C.muted, "Nenhuma música no cursor.")
  else
    local cy = y + header(ctx, dl, x, y, w, state)
    local rows = state.rows
    if not rows or #rows == 0 then
      local msg = state.has_chart and "Sem cifra para esta seção." or "Esta música não tem cifra."
      kit.txt(ctx, dl, "title", x, cy + 10, theme.C.muted, msg)
      kit.wrapped(ctx, "small", x, cy + 44, w, theme.C.faint,
        "Cole a cifra no modo Editar → Cifra, com cabeçalhos [Intro], [Verso], [Refrão]… iguais aos nomes das seções.")
    else
      local lyric, chord, line_h = pick_sizes(ctx, rows, w - 16)
      local now = reaper.time_precise()
      local target = state.focus or 0
      local key = tostring(state.song) .. "\0" .. tostring(state.section)
      if shown and shown.key ~= key and shown.song == state.song and state.prev == shown.section then
        -- seção seguinte: o "A seguir" de antes é o cabeçalho de agora
        local old_i, new_i = index_of(shown.rows, "next"), index_of(rows, "header")
        if old_i and new_i then shown.focus, shown.key = shown.focus + new_i - old_i, key end
      end
      if not shown or shown.key ~= key or target < shown.focus - 3 then
        shown = { key = key, focus = target, at = now }
      else
        local k = 1 - math.exp(-FOLLOW * math.max(0, now - shown.at))
        shown.focus, shown.at = shown.focus + (target - shown.focus) * k, now
      end
      shown.song, shown.section, shown.rows = state.song, state.section, rows

      local function row_h(r) return (r.kind == "next" or r.kind == "header") and NEXT_H or line_h end
      -- y (desde o topo da cifra) do ponto `f`, em linhas
      local function y_of(f)
        local yy, i = 0, 1
        while i <= #rows and i <= f do yy = yy + row_h(rows[i]); i = i + 1 end
        local r = rows[math.floor(f) + 1]
        return yy + (r and (f - math.floor(f)) * row_h(r) or 0)
      end

      local top, bottom = cy, y + h
      ImGui.DrawList_PushClipRect(dl, x, top, x + w + PAD / 2, bottom, true)
      cy = top + (bottom - top) * FOCUS_AT - y_of(shown.focus)
      -- fundo do verso atual
      local cur_top, cur_bottom = nil, nil
      local yy = cy
      for _, r in ipairs(rows) do
        if r.current then cur_top = cur_top or yy; cur_bottom = yy + row_h(r) end
        yy = yy + row_h(r)
      end
      if cur_top then
        ImGui.DrawList_AddRectFilled(dl, x, cur_top - 2, x + w, cur_bottom - 4, theme.C.raise, 8)
        ImGui.DrawList_AddRectFilled(dl, x, cur_top - 2, x + 4, cur_bottom - 4, theme.C.queue, 2)
      end
      for _, row in ipairs(rows) do
        local rh = row_h(row)
        if cy > bottom then break end
        if cy + rh > top then
          if row.kind == "next" then
            kit.txt(ctx, dl, "label", x + 16, cy + 12, theme.C.faint, "A SEGUIR · " .. row.text:upper())
          elseif row.kind == "header" then
            kit.txt(ctx, dl, "label", x + 16, cy + 12, theme.C.muted, row.text:upper())
          elseif row.kind == "grid" then
            grid_row(ctx, dl, x + 16, cy, w - 16, row, lyric, chord, line_h)
          elseif row.kind == "chords" then
            kit.txt(ctx, dl, chord, x + 16, cy, row.past and theme.C.faint or theme.C.queue, row.text)
          else
            kit.txt(ctx, dl, lyric, x + 16, cy, row.past and theme.C.faint or theme.C.text, row.text)
          end
        end
        cy = cy + rh
      end
      ImGui.DrawList_PopClipRect(dl)
    end
  end
  ImGui.SetCursorScreenPos(ctx, x, y)
  ImGui.Dummy(ctx, w, 1)
  ImGui.End(ctx)
  return open
end

return M
