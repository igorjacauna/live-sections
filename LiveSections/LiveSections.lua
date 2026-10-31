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
local wizard = require("ui.kontakt_wizard")
wizard.init({ ImGui = ImGui, theme = theme, layers = layers, kit = view.kit })
editor.init({
  ImGui = ImGui, theme = theme, widgets = widgets, perf = perf, layers = layers, model = model,
  editor_ops = require("core.editor_ops"), validator = require("core.validator"),
  tempo_align = require("core.tempo_align"), kontakt_wizard = wizard, kit = view.kit,
})
view.init({
  ImGui = ImGui, theme = theme, anim = anim, widgets = widgets,
  perf = perf, layers = layers, feedback = feedback, mappings = mappings,
  learn = learn, input = input, model = model, editor = editor, settings = settings_view, stage = stage,
})
chart_view.init({ ImGui = ImGui, theme = theme, kit = view.kit })
settings_view.init({
  ImGui = ImGui, theme = theme, kit = view.kit, mappings = mappings, feedback = feedback,
  layers = layers, perf = perf, anim = anim, learn = learn, model = model, ui = view.ui(),
})

-- Tamanho mínimo: a janela não abre estreita mesmo com um tamanho antigo
-- salvo pelo ReaImGui.
local MIN_W, MIN_H = 720, 480

-- Maximizar/restaurar (botão no topo ou F11): a posição e o tamanho só valem
-- antes do Begin, então o pedido fica para o ciclo seguinte.
local win = { pending = nil, restore = nil }

local function toggle_maximize(ui)
  if ui.maximized then
    win.pending, ui.maximized = win.restore, false
    return
  end
  local px, py = ImGui.GetWindowPos(ctx)
  local pw, ph = ImGui.GetWindowSize(ctx)
  win.restore = { px, py, pw, ph }
  local vp = ImGui.GetWindowViewport(ctx)
  local vx, vy = ImGui.Viewport_GetWorkPos(vp)
  local vw, vh = ImGui.Viewport_GetWorkSize(vp)
  win.pending, ui.maximized = { vx, vy, vw, vh }, true
end

-- Redimensionar pelas bordas da janela, não só pelo canto.
if ImGui.ConfigVar_WindowsResizeFromEdges then
  ImGui.SetConfigVar(ctx, ImGui.ConfigVar_WindowsResizeFromEdges, 1)
end

local function loop()
  local now = reaper.time_precise()
  remote.heartbeat(now)
  -- comandos das actions da lista do REAPER (actions/*.lua)
  for _, c in ipairs(remote.poll()) do view.run(c.action, c.arg, c.value) end
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
  local visible, open = ImGui.Begin(ctx, APP_NAME, true)
  local ui = view.ui()
  if visible then
    view.draw(ctx)
    local f11 = ImGui.IsWindowFocused(ctx, ImGui.FocusedFlags_RootAndChildWindows)
      and ImGui.IsKeyPressed(ctx, ImGui.Key_F11, false)
    if ui.toggle_max or f11 then
      ui.toggle_max = false
      toggle_maximize(ui)
    end
    ImGui.End(ctx)
  end
  -- janela "Cifra": separada, pode ir para outro monitor
  if ui.chart_open and not chart_view.draw(ctx, view.stage_state()) then ui.chart_open = false end
  theme.pop_font(ctx, t)
  theme.pop(ctx)
  if open then reaper.defer(loop) end
end

reaper.atexit(feedback.clear)
reaper.atexit(remote.shutdown)
reaper.atexit(stage.shutdown)
reaper.defer(loop)
