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
local SCROLL_S = 0.45      -- duração da rolagem quando a seção avança
local NEXT_H = 34          -- altura da linha "A seguir"

-- Rolagem suave: quando as linhas avançam (as de cima saem e as de baixo
-- entram), as que saíram continuam desenhadas acima e tudo desliza até o
-- lugar novo. Troca de seção ou volta (loop) muda direto.
local prev_rows = nil
local scroll = nil         -- { from, gone = { linhas que saíram } }

function M.init(deps) ImGui, theme, kit = deps.ImGui, deps.theme, deps.kit end

local function rgba(hex) return theme.rgba(hex or theme.DEFAULT_SECTION_COLOR) end

-- Fonte grande se a linha mais longa couber; senão a pequena.
local function pick_sizes(ctx, rows, w)
  local widest = 0
  for _, row in ipairs(rows) do
    if row.kind ~= "next" then
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

local function same_row(a, b) return a.kind == b.kind and a.text == b.text end

-- Quantas linhas do começo de `old` saíram para formar `new`; nil se `new`
-- não é `old` avançado.
local function advanced_by(old, new)
  if not old or #new == 0 then return nil end
  for k = 1, #old - 1 do
    local n = math.min(#old - k, #new)
    local ok = true
    for i = 1, n do
      if not same_row(old[k + i], new[i]) then ok = false; break end
    end
    if ok then return k end
  end
end

local function rows_equal(a, b)
  if not a or #a ~= #b then return false end
  for i = 1, #a do if not same_row(a[i], b[i]) then return false end end
  return true
end

local function ease_out(t) return 1 - (1 - t) ^ 3 end

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
      if not rows_equal(prev_rows, rows) then
        local k = advanced_by(prev_rows, rows)
        scroll = k and { from = now, gone = { table.unpack(prev_rows, 1, k) } } or nil
        prev_rows = rows
      end
      local list, shift = rows, 0
      if scroll then
        local t = (now - scroll.from) / SCROLL_S
        if t >= 1 then
          scroll = nil
        else
          list = {}
          for _, r in ipairs(scroll.gone) do
            list[#list + 1] = r
            shift = shift + (r.kind == "next" and NEXT_H or line_h)
          end
          for _, r in ipairs(rows) do list[#list + 1] = r end
          shift = shift * ease_out(t)
        end
      end
      local top = cy
      ImGui.DrawList_PushClipRect(dl, x, top, x + w + PAD / 2, y + h, true)
      cy = cy - shift
      -- parado, só linhas inteiras; rolando, a de baixo entra cortada
      local limit = shift > 0 and y + h + line_h or y + h
      for _, row in ipairs(list) do
        if cy + line_h > limit then break end
        if row.kind == "next" then
          if cy + NEXT_H > top then
            kit.txt(ctx, dl, "label", x + 16, cy + 12, theme.C.faint, "A SEGUIR · " .. row.text:upper())
          end
          cy = cy + NEXT_H
        else
          if cy + line_h > top then
            if row.kind == "grid" then
              grid_row(ctx, dl, x + 16, cy, w - 16, row, lyric, chord, line_h)
            elseif row.kind == "chords" then
              kit.txt(ctx, dl, chord, x + 16, cy, theme.C.queue, row.text)
            else
              kit.txt(ctx, dl, lyric, x + 16, cy, theme.C.text, row.text)
            end
          end
          cy = cy + line_h
        end
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
