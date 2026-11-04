-- Live Sections: performance ao vivo por seções no REAPER
-- Entrypoint: checa dependências, prepara os módulos e roda o loop da janela.
--
-- Copyright (C) 2026 Igor Jacaúna. Licença GPL-3.0-or-later: este programa é
-- software livre; veja o arquivo LICENSE ou https://www.gnu.org/licenses/.
-- https://github.com/igorjacauna/live-sections

local APP_NAME = "Live Sections"
local MIN_REAPER_VERSION = 7.0
local IMGUI_API_VERSION = "0.9"

local MSG_OLD_REAPER = [[
O Live Sections precisa do REAPER 7.0 ou mais recente.

Versão instalada: %s]]

local MSG_NO_IMGUI = [[
O Live Sections precisa da extensão ReaImGui, que não está instalada.

Para instalar:
1. Extensions → ReaPack → Browse packages
2. Busque por "ReaImGui"
3. Clique com o botão direito → Install, depois Apply
4. Reinicie o REAPER e rode o Live Sections de novo

Sem o ReaPack? Baixe em https://reapack.com]]

local function script_dir()
  local _, path = reaper.get_action_context()
  return path:match("^(.*[/\\])") or "./"
end

local function check_dependencies()
  local version_str = reaper.GetAppVersion()
  local version = tonumber(version_str:match("^(%d+%.%d+)"))
  if not version or version < MIN_REAPER_VERSION then
    return false, MSG_OLD_REAPER:format(version_str)
  end
  if not reaper.ImGui_GetBuiltinPath then
    return false, MSG_NO_IMGUI
  end
  return true
end

local ok, err = check_dependencies()
if not ok then
  reaper.MB(err, APP_NAME, 0)
  return
end

package.path = script_dir() .. "?.lua;" .. reaper.ImGui_GetBuiltinPath() .. "/?.lua;" .. package.path
local ImGui = require("imgui")(IMGUI_API_VERSION)

local theme = require("ui.theme")
local anim = require("ui.anim")
local widgets = require("ui.widgets")
local view = require("ui.performance_view")
local editor = require("ui.editor_view")
local settings_view = require("ui.settings_view")
local mapping_view = require("ui.mapping_view")
local input = require("midi.input")
local learn = require("midi.learn")
local mappings = require("midi.mappings")
local feedback = require("midi.feedback")
local perf = require("core.performance")
local layers = require("core.layers")
local model = require("core.project_model")
local remote = require("actions.remote")
local stage = require("core.stage")
local chart_view = require("ui.chart_view")
local kontakt_jsfx = require("core.kontakt_jsfx")
local kontakt_cc = require("core.kontakt_cc")

local ctx = ImGui.CreateContext(APP_NAME)
theme.init(ctx, ImGui, script_dir())
widgets.init(ImGui, theme, anim, learn, mappings)
mappings.load()
input.init()
-- Configurações globais (chave "settings" do config.json), editadas na tela
-- de configurações.
local cfg = mappings.settings()
feedback.configure(cfg)
layers.configure({ keyboard_port = cfg.keyboard_port, bypass_tail_s = cfg.bypass_tail_s })
perf.init({ quantize = cfg.quantize, tolerance_ms = cfg.tolerance_ms })
anim.set_reduced(cfg.reduced_motion == true)
-- JSFX do Mapeamento: regravado a cada abertura (atualiza com a versão).
-- Uma falha não impede abrir; a tela Mapeamento mostra o problema de novo.
local jsfx_status = {}
jsfx_status.ok, jsfx_status.err, jsfx_status.path = kontakt_jsfx.write_file()
if not jsfx_status.ok then
  reaper.ShowConsoleMsg(string.format("Live Sections: não consegui gravar o JSFX do Mapeamento em %s (%s)\n",
    jsfx_status.path, tostring(jsfx_status.err)))
end
kontakt_cc.init({ mappings = mappings, jsfx = kontakt_jsfx, layers = layers })
local layer_params = require("core.layer_params")
layer_params.init({ layers = layers, kontakt_cc = kontakt_cc })
local stems = require("core.stems")
stems.init({ layers = layers })
-- biblioteca de músicas (exportar e montar setlist)
local library = require("core.library")
library.init({ mappings = mappings })
local song_deps = {
  layers = layers, layer_params = layer_params, chart = require("core.chart"),
  song_notes = require("core.song_notes"), kontakt_cc = kontakt_cc,
  tempo_align = require("core.tempo_align"), jsfx = kontakt_jsfx,
}
require("core.song_package").init(song_deps)
require("core.song_import").init(song_deps)
local library_view = require("ui.library_view")
local wizard = require("ui.kontakt_wizard")
wizard.init({ ImGui = ImGui, theme = theme, layers = layers, kit = view.kit })
editor.init({
  ImGui = ImGui, theme = theme, widgets = widgets, perf = perf, layers = layers, model = model,
  editor_ops = require("core.editor_ops"), validator = require("core.validator"),
  tempo_align = require("core.tempo_align"), kontakt_wizard = wizard, kit = view.kit, kontakt_cc = kontakt_cc,
  library_view = library_view,
})
view.init({
  ImGui = ImGui, theme = theme, anim = anim, widgets = widgets,
  perf = perf, layers = layers, feedback = feedback, mappings = mappings,
  learn = learn, input = input, model = model, editor = editor, settings = settings_view, stage = stage,
  kontakt_cc = kontakt_cc, mapping = mapping_view, layer_params = layer_params, library_view = library_view,
})
chart_view.init({ ImGui = ImGui, theme = theme, kit = view.kit })
library_view.init({
  ImGui = ImGui, theme = theme, kit = view.kit, library = library, song_package = require("core.song_package"),
  song_import = require("core.song_import"),
})
mapping_view.init({
  ImGui = ImGui, theme = theme, kit = view.kit, kontakt_cc = kontakt_cc, learn = learn, feedback = feedback,
  ui = view.ui(), label = settings_view.label, jsfx = kontakt_jsfx, layers = layers, model = model,
  jsfx_status = jsfx_status,
})
settings_view.init({
  ImGui = ImGui, theme = theme, kit = view.kit, mappings = mappings, feedback = feedback,
  layers = layers, perf = perf, anim = anim, learn = learn, model = model, ui = view.ui(), library = library,
})

-- Tamanho mínimo: a janela não abre estreita mesmo com um tamanho antigo
-- salvo pelo ReaImGui.
local MIN_W, MIN_H = 720, 480

-- Maximizar/restaurar (botão no topo, F11 ou duplo clique no título): a posição e o tamanho só valem
-- antes do Begin, então o pedido fica para o ciclo seguinte.
local win = { pending = nil, restore = nil }
local last_error = nil

-- Área útil (sem barra de menus/tarefas) do monitor onde está a janela. No
-- ReaImGui cada janela é um viewport próprio, então a área de trabalho dele
-- é a própria janela: quem sabe o tamanho do monitor é o REAPER, em
-- coordenadas nativas (no macOS o eixo y é invertido, daí a conversão).
local function monitor_area(px, py, pw, ph)
  if reaper.my_getViewport and ImGui.PointConvertNative then
    local ax, ay = ImGui.PointConvertNative(ctx, px, py, true)
    local bx, by = ImGui.PointConvertNative(ctx, px + pw, py + ph, true)
    local l, t, r, b = reaper.my_getViewport(0, 0, 0, 0,
      math.min(ax, bx), math.min(ay, by), math.max(ax, bx), math.max(ay, by), true)
    local x1, y1 = ImGui.PointConvertNative(ctx, l, t, false)
    local x2, y2 = ImGui.PointConvertNative(ctx, r, b, false)
    local w, h = math.abs(x2 - x1), math.abs(y2 - y1)
    if w > MIN_W and h > MIN_H then return math.min(x1, x2), math.min(y1, y2), w, h end
  end
  local vp = ImGui.GetMainViewport(ctx)
  local vx, vy = ImGui.Viewport_GetWorkPos(vp)
  local vw, vh = ImGui.Viewport_GetWorkSize(vp)
  return vx, vy, vw, vh
end

local function toggle_maximize(ui)
  if ui.maximized then
    win.pending, ui.maximized = win.restore, false
    return
  end
  local px, py = ImGui.GetWindowPos(ctx)
  local pw, ph = ImGui.GetWindowSize(ctx)
  win.restore = { px, py, pw, ph }
  win.pending, ui.maximized = { monitor_area(px, py, pw, ph) }, true
end

-- Duplo clique na barra de título maximiza/restaura, como numa janela comum
-- (o recolher do ImGui fica desligado: a janela sumia e não voltava ao
-- tamanho de antes).
local function title_double_clicked()
  if not ImGui.IsMouseDoubleClicked(ctx, ImGui.MouseButton_Left) then return false end
  if not ImGui.IsWindowHovered(ctx) then return false end
  local _, wy = ImGui.GetWindowPos(ctx)
  local _, my = ImGui.GetMousePos(ctx)
  return my >= wy and my < wy + ImGui.GetFrameHeight(ctx)
end

-- Redimensionar pelas bordas da janela, não só pelo canto.
if ImGui.ConfigVar_WindowsResizeFromEdges then
  ImGui.SetConfigVar(ctx, ImGui.ConfigVar_WindowsResizeFromEdges, 1)
end

local diag = require("core.diag")

local function loop()
  local now = reaper.time_precise()
  remote.heartbeat(now)
  -- comandos das actions da lista do REAPER (actions/*.lua)
  for _, c in ipairs(remote.poll()) do view.run(c.action, c.arg, c.value) end
  diag.part("actions", now)
  view.update(now)
  widgets.frame(ctx, now)
  theme.push(ctx)
  local t = theme.font(ctx, "body")
  if win.pending then
    ImGui.SetNextWindowPos(ctx, win.pending[1], win.pending[2], ImGui.Cond_Always)
    ImGui.SetNextWindowSize(ctx, win.pending[3], win.pending[4], ImGui.Cond_Always)
    win.pending = nil
  end
  ImGui.SetNextWindowSize(ctx, 1100, 760, ImGui.Cond_FirstUseEver)
  ImGui.SetNextWindowSizeConstraints(ctx, MIN_W, MIN_H, 100000, 100000)
  ImGui.SetNextWindowCollapsed(ctx, false, ImGui.Cond_Always)
  local visible, open = ImGui.Begin(ctx, APP_NAME, true, ImGui.WindowFlags_NoCollapse)
  local ui = view.ui()
  if visible then
    local title_dbl = title_double_clicked()
    -- um erro no desenho não pode deixar a janela sem End(): mostra o erro e
    -- segue rodando (o áudio nunca depende do script)
    local depth = theme.font_depth()
    local t_draw = reaper.time_precise()
    local ok, err = xpcall(view.draw, debug.traceback, ctx)
    diag.part("tela " .. tostring(ui.mode), t_draw)
    if not ok then
      theme.recover_fonts(ctx, depth)
      if err ~= last_error then
        last_error = err
        reaper.ShowConsoleMsg(string.format("Live Sections %s (REAPER %s): erro ao desenhar a tela\n%s\n",
          require("version"), reaper.GetAppVersion(), tostring(err)))
      end
      ImGui.TextColored(ctx, theme.C.danger, "Erro ao desenhar a tela (detalhes no console do REAPER).")
    end
    local f11 = ImGui.IsWindowFocused(ctx, ImGui.FocusedFlags_RootAndChildWindows)
      and ImGui.IsKeyPressed(ctx, ImGui.Key_F11, false)
    if ui.toggle_max or f11 or title_dbl then
      ui.toggle_max = false
      toggle_maximize(ui)
    end
    ImGui.End(ctx)
  end
  -- janela "Cifra": separada, pode ir para outro monitor
  local t_chart = reaper.time_precise()
  if ui.chart_open and not chart_view.draw(ctx, view.stage_state()) then ui.chart_open = false end
  diag.part("janela Cifra", t_chart)
  theme.pop_font(ctx, t)
  theme.pop(ctx)
  diag.cycle(now, reaper.time_precise())
  if open then reaper.defer(loop) end
end

reaper.atexit(feedback.clear)
reaper.atexit(remote.shutdown)
reaper.atexit(stage.shutdown)
reaper.defer(loop)
