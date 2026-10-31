-- Tema visual: tokens do protótipo aprovado (prototype/index.html) aplicados
-- à ReaImGui. Substitui todas as cores e estilos padrão (RF-075) e carrega as
-- fontes do pacote (assets/fonts, licença OFL).
--
-- A API de fontes da ReaImGui mudou entre versões; o carregamento fica só
-- aqui. O script pede a API 0.9: CreateFont(arquivo, tamanho) + Attach antes
-- do primeiro frame.
--
-- Cores em 0xRRGGBBAA, como a ReaImGui espera.
--
-- M.init(ctx, ImGui, base_dir) -> ok, err   cria e anexa as fontes
-- M.push(ctx) / M.pop(ctx)                   estilo da janela inteira
-- M.font(ctx, style) / M.pop_font(ctx)       estilo de texto (M.TEXT)
-- M.rgba(hex, alpha) -> cor
-- M.STATE[state] -> { color, icon, label }   estado com ícone e texto (RF-078)
-- M.icon(draw_list, name, x, y, size, color) desenha um ícone de 16×16 em escala

local M = {}

local ImGui = nil

-- ------------------------------------------------------------------ cores

function M.rgba(hex, alpha)
  local rgb = tonumber(hex:gsub("^#", ""), 16)
  return (rgb << 8) | math.floor((alpha or 1) * 255 + 0.5)
end

-- Mistura duas cores 0xRRGGBBAA (t = 0 → a, 1 → b).
function M.mix(a, b, t)
  local out = 0
  for shift = 24, 0, -8 do
    local ca, cb = (a >> shift) & 0xFF, (b >> shift) & 0xFF
    out = out | (math.floor(ca + (cb - ca) * t + 0.5) << shift)
  end
  return out
end

local hex = {
  bg = "#0A0D12", panel = "#10151D", raise = "#171E29", raise2 = "#1F2835",
  line = "#222C3A", line2 = "#2F3B4D", text = "#ECF0F6", muted = "#93A0B4",
  faint = "#5F6B7E", ink = "#0A0D12", queue = "#FFB547", loop = "#5CD6E8",
  learn = "#E28CFF", ok = "#4BDB9C", danger = "#FF6B6B",
}

M.C = {}
for name, h in pairs(hex) do M.C[name] = M.rgba(h) end

-- Cores dos chips de nome de seção; nomes fora da lista usam DEFAULT.
M.SECTION_COLORS = {
  { name = "Intro", color = "#5B8DEF" }, { name = "Verso", color = "#2BB39A" },
  { name = "Pré", color = "#E0A43A" }, { name = "Refrão", color = "#E5566B" },
  { name = "Ponte", color = "#9B6BE8" }, { name = "Solo", color = "#E8C547" },
  { name = "Drop", color = "#E3559F" }, { name = "Outro", color = "#7A8AA6" },
}
M.DEFAULT_SECTION_COLOR = "#6C9AB0"

M.R = { r1 = 8, r2 = 12, r3 = 16 }           -- raios
M.S = { xs = 4, sm = 8, md = 12, lg = 16, xl = 24 }  -- espaçamentos

-- ------------------------------------------------------------------ estados

-- Todo estado tem ícone e texto, não só cor (RF-078).
M.STATE = {
  playing = { color = M.C.ok,     icon = "play",  label = "Tocando" },
  queued  = { color = M.C.queue,  icon = "clock", label = "Na fila" },
  loop    = { color = M.C.loop,   icon = "loop",  label = "Loop" },
  error   = { color = M.C.danger, icon = "warn",  label = "Erro" },
  learn   = { color = M.C.learn,  icon = "learn", label = "Aguardando MIDI…" },
}

-- ------------------------------------------------------------------ fontes

local FILES = {
  ui = "Manrope-SemiBold.ttf",
  ui_bold = "Manrope-Bold.ttf",
  ui_heavy = "Manrope-ExtraBold.ttf",
  num = "JetBrainsMono-Medium.ttf",
  num_bold = "JetBrainsMono-Bold.ttf",
}

-- Estilos de texto do protótipo: arquivo + tamanho em px.
M.TEXT = {
  body     = { "ui", 14 },
  small    = { "ui", 12 },
  label    = { "ui_bold", 11 },     -- rótulos em caixa alta
  button   = { "ui_bold", 13 },
  strong   = { "ui_heavy", 15 },
  title    = { "ui_heavy", 20 },
  h1       = { "ui_heavy", 34 },
  num      = { "num_bold", 13 },
  readout  = { "num_bold", 17 },
  big      = { "num_bold", 34 },
  tick     = { "num", 11 },
}

local fonts = {}          -- [style] = font

local function exists(path)
  local f = io.open(path, "rb")
  if f then f:close() end
  return f ~= nil
end

function M.init(ctx, imgui, base_dir)
  ImGui = imgui
  fonts = {}
  local dir = base_dir .. "assets/fonts/"
  local by_key, missing = {}, nil
  for style, spec in pairs(M.TEXT) do
    local file, size = dir .. FILES[spec[1]], spec[2]
    if exists(file) then
      local key = file .. "@" .. size
      if not by_key[key] then
        by_key[key] = ImGui.CreateFont(file, size)
        ImGui.Attach(ctx, by_key[key])
      end
      fonts[style] = by_key[key]
    else
      missing = FILES[spec[1]]
    end
  end
  if missing then return false, "font_missing: " .. missing end
  return true
end

-- Sem a fonte (arquivo ausente), o texto sai na fonte padrão.
function M.font(ctx, style)
  local f = fonts[style]
  if f then ImGui.PushFont(ctx, f) end
  return f ~= nil
end

function M.pop_font(ctx, pushed)
  if pushed ~= false then ImGui.PopFont(ctx) end
end

-- ------------------------------------------------------------------ estilo

local function colors()
  local C = M.C
  local clear = 0x00000000
  return {
    Text = C.text, TextDisabled = C.faint,
    WindowBg = C.bg, ChildBg = clear, PopupBg = C.panel,
    Border = C.line, BorderShadow = clear,
    FrameBg = C.bg, FrameBgHovered = C.raise, FrameBgActive = C.raise2,
    TitleBg = C.bg, TitleBgActive = C.panel, TitleBgCollapsed = C.bg, MenuBarBg = C.panel,
    ScrollbarBg = clear, ScrollbarGrab = C.line2, ScrollbarGrabHovered = C.faint, ScrollbarGrabActive = C.muted,
    CheckMark = C.text, SliderGrab = C.text, SliderGrabActive = C.text,
    Button = C.raise, ButtonHovered = C.raise2, ButtonActive = C.line2,
    Header = C.raise, HeaderHovered = C.raise2, HeaderActive = C.line2,
    Separator = C.line, SeparatorHovered = C.line2, SeparatorActive = C.muted,
    ResizeGrip = clear, ResizeGripHovered = C.line2, ResizeGripActive = C.muted,
    Tab = C.panel, TabHovered = C.raise2, TabActive = C.raise,
    TabUnfocused = C.panel, TabUnfocusedActive = C.raise,
    PlotLines = C.muted, PlotLinesHovered = C.text, PlotHistogram = C.muted, PlotHistogramHovered = C.text,
    TableHeaderBg = C.panel, TableBorderStrong = C.line2, TableBorderLight = C.line,
    TableRowBg = clear, TableRowBgAlt = M.rgba("#FFFFFF", 0.02),
    TextSelectedBg = M.rgba(hex.loop, 0.3), DragDropTarget = C.queue,
    NavHighlight = C.loop, NavWindowingHighlight = C.text,
    NavWindowingDimBg = M.rgba(hex.bg, 0.6), ModalWindowDimBg = M.rgba(hex.bg, 0.7),
  }
end

local function vars()
  local R, S = M.R, M.S
  return {
    WindowRounding = { R.r2 }, ChildRounding = { R.r2 }, FrameRounding = { R.r1 },
    PopupRounding = { R.r2 }, GrabRounding = { R.r1 }, ScrollbarRounding = { R.r1 },
    TabRounding = { R.r1 },
    WindowPadding = { S.lg, S.lg }, FramePadding = { 11, 8 }, ItemSpacing = { S.md, S.md },
    WindowBorderSize = { 0 }, FrameBorderSize = { 1 }, PopupBorderSize = { 1 }, ScrollbarSize = { 10 },
  }
end

local pushed = { colors = 0, vars = 0 }

-- Nomes ausentes na versão da ReaImGui são ignorados.
function M.push(ctx)
  pushed.colors, pushed.vars = 0, 0
  for name, color in pairs(colors()) do
    local idx = ImGui["Col_" .. name]
    if idx then
      ImGui.PushStyleColor(ctx, idx, color)
      pushed.colors = pushed.colors + 1
    end
  end
  for name, v in pairs(vars()) do
    local idx = ImGui["StyleVar_" .. name]
    if idx then
      ImGui.PushStyleVar(ctx, idx, v[1], v[2])
      pushed.vars = pushed.vars + 1
    end
  end
end

function M.pop(ctx)
  if pushed.vars > 0 then ImGui.PopStyleVar(ctx, pushed.vars) end
  if pushed.colors > 0 then ImGui.PopStyleColor(ctx, pushed.colors) end
  pushed.colors, pushed.vars = 0, 0
end

-- ------------------------------------------------------------------ ícones

-- Ícones do protótipo em coordenadas 16×16, desenhados com a DrawList.
local function stroke(dl, pts, x, y, k, color, thick, closed)
  for i = 1, #pts - 1 do
    local a, b = pts[i], pts[i + 1]
    ImGui.DrawList_AddLine(dl, x + a[1] * k, y + a[2] * k, x + b[1] * k, y + b[2] * k, color, thick)
  end
  if closed then
    local a, b = pts[#pts], pts[1]
    ImGui.DrawList_AddLine(dl, x + a[1] * k, y + a[2] * k, x + b[1] * k, y + b[2] * k, color, thick)
  end
end

local ICONS = {
  play = function(dl, x, y, k, c)
    ImGui.DrawList_AddTriangleFilled(dl, x + 4.5 * k, y + 2.8 * k, x + 4.5 * k, y + 13.2 * k, x + 13 * k, y + 8 * k, c)
  end,
  stop = function(dl, x, y, k, c)
    ImGui.DrawList_AddRectFilled(dl, x + 3.5 * k, y + 3.5 * k, x + 12.5 * k, y + 12.5 * k, c, 1.5 * k)
  end,
  clock = function(dl, x, y, k, c, t)
    ImGui.DrawList_AddCircle(dl, x + 8 * k, y + 8 * k, 5.6 * k, c, 0, t)
    stroke(dl, { { 8, 5 }, { 8, 8.3 }, { 10.1, 9.6 } }, x, y, k, c, t)
  end,
  loop = function(dl, x, y, k, c, t)
    local cx, cy, r = x + 8 * k, y + 8 * k, 5 * k
    ImGui.DrawList_PathArcTo(dl, cx, cy, r, math.pi * 1.05, math.pi * 1.85)
    ImGui.DrawList_PathStroke(dl, c, 0, t)
    ImGui.DrawList_PathArcTo(dl, cx, cy, r, math.pi * 0.05, math.pi * 0.85)
    ImGui.DrawList_PathStroke(dl, c, 0, t)
    stroke(dl, { { 13, 2.5 }, { 13, 6 }, { 9.5, 6 } }, x, y, k, c, t)
    stroke(dl, { { 3, 13.5 }, { 3, 10 }, { 6.5, 10 } }, x, y, k, c, t)
  end,
  x = function(dl, x, y, k, c, t)
    stroke(dl, { { 4.5, 4.5 }, { 11.5, 11.5 } }, x, y, k, c, t)
    stroke(dl, { { 11.5, 4.5 }, { 4.5, 11.5 } }, x, y, k, c, t)
  end,
  warn = function(dl, x, y, k, c, t)
    stroke(dl, { { 8, 2.2 }, { 14.2, 13.2 }, { 1.8, 13.2 } }, x, y, k, c, t, true)
    stroke(dl, { { 8, 6.5 }, { 8, 9.7 } }, x, y, k, c, t)
    ImGui.DrawList_AddCircleFilled(dl, x + 8 * k, y + 11.5 * k, t * 0.7, c)
  end,
  check = function(dl, x, y, k, c, t)
    stroke(dl, { { 3, 8.5 }, { 6.2, 11.5 }, { 13, 4.5 } }, x, y, k, c, t)
  end,
  learn = function(dl, x, y, k, c, t)
    ImGui.DrawList_AddCircle(dl, x + 8 * k, y + 8 * k, 5.6 * k, c, 0, t)
    ImGui.DrawList_AddCircleFilled(dl, x + 8 * k, y + 8 * k, 2.2 * k, c)
  end,
  left = function(dl, x, y, k, c, t) stroke(dl, { { 10, 3.5 }, { 5.5, 8 }, { 10, 12.5 } }, x, y, k, c, t) end,
  right = function(dl, x, y, k, c, t) stroke(dl, { { 6, 3.5 }, { 10.5, 8 }, { 6, 12.5 } }, x, y, k, c, t) end,
  plus = function(dl, x, y, k, c, t)
    stroke(dl, { { 8, 3 }, { 8, 13 } }, x, y, k, c, t)
    stroke(dl, { { 3, 8 }, { 13, 8 } }, x, y, k, c, t)
  end,
  stage = function(dl, x, y, k, c, t)
    ImGui.DrawList_AddRect(dl, x + 2 * k, y + 3 * k, x + 14 * k, y + 13 * k, c, 2 * k, 0, t)
    stroke(dl, { { 2, 6.5 }, { 14, 6.5 } }, x, y, k, c, t)
  end,
  list = function(dl, x, y, k, c, t)
    for _, ly in ipairs({ 4, 8, 12 }) do
      stroke(dl, { { 5.5, ly }, { 13.5, ly } }, x, y, k, c, t)
      ImGui.DrawList_AddCircleFilled(dl, x + 2.5 * k, y + ly * k, t * 0.6, c)
    end
  end,
  prev_song = function(dl, x, y, k, c)
    ImGui.DrawList_AddRectFilled(dl, x + 3.5 * k, y + 3 * k, x + 5.1 * k, y + 13 * k, c)
    ImGui.DrawList_AddTriangleFilled(dl, x + 13 * k, y + 3.2 * k, x + 13 * k, y + 12.8 * k, x + 5.8 * k, y + 8 * k, c)
  end,
  next_song = function(dl, x, y, k, c)
    ImGui.DrawList_AddRectFilled(dl, x + 10.9 * k, y + 3 * k, x + 12.5 * k, y + 13 * k, c)
    ImGui.DrawList_AddTriangleFilled(dl, x + 3 * k, y + 3.2 * k, x + 3 * k, y + 12.8 * k, x + 10.2 * k, y + 8 * k, c)
  end,
}

M.ICON_NAMES = {}
for name in pairs(ICONS) do M.ICON_NAMES[#M.ICON_NAMES + 1] = name end
table.sort(M.ICON_NAMES)

function M.icon(dl, name, x, y, size, color)
  local draw = ICONS[name]
  if not draw then error("theme.icon: ícone desconhecido: " .. tostring(name), 2) end
  local k = size / 16
  draw(dl, x, y, k, color, math.max(1, 1.6 * k))
end

return M
