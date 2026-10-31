-- Live Sections: performance ao vivo por seções no REAPER
-- Entrypoint: checa dependências, prepara os módulos e roda o loop da janela.

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
local input = require("midi.input")
local learn = require("midi.learn")
local mappings = require("midi.mappings")
local feedback = require("midi.feedback")
local perf = require("core.performance")
local layers = require("core.layers")
local model = require("core.project_model")

-- Configurações globais (config.json, chave "settings"); a tela de
-- configurações (task 4.6) passa a editá-las.
local function settings()
  local f = io.open(mappings.config_path(), "r")
  if not f then return {} end
  local ok, data = pcall(require("vendor.json").decode, f:read("a"))
  f:close()
  return ok and type(data) == "table" and type(data.settings) == "table" and data.settings or {}
end

local ctx = ImGui.CreateContext(APP_NAME)
theme.init(ctx, ImGui, script_dir())
widgets.init(ImGui, theme, anim, learn, mappings)
mappings.load()
input.init()
local cfg = settings()
feedback.configure(cfg)
layers.configure({ keyboard_port = cfg.keyboard_port, bypass_tail_s = cfg.bypass_tail_s })
perf.init({ quantize = cfg.quantize, tolerance_ms = cfg.tolerance_ms })
anim.set_reduced(cfg.reduced_motion == true)
view.init({
  ImGui = ImGui, theme = theme, anim = anim, widgets = widgets,
  perf = perf, layers = layers, feedback = feedback, mappings = mappings,
  learn = learn, input = input, model = model,
})

-- Tamanho mínimo: a janela não abre estreita mesmo com um tamanho antigo
-- salvo pelo ReaImGui.
local MIN_W, MIN_H = 720, 480

local function loop()
  local now = reaper.time_precise()
  view.update(now)
  widgets.frame(ctx, now)
  theme.push(ctx)
  local t = theme.font(ctx, "body")
  ImGui.SetNextWindowSize(ctx, 1100, 760, ImGui.Cond_FirstUseEver)
  ImGui.SetNextWindowSizeConstraints(ctx, MIN_W, MIN_H, 100000, 100000)
  local visible, open = ImGui.Begin(ctx, APP_NAME, true)
  if visible then
    view.draw(ctx)
    ImGui.End(ctx)
  end
  theme.pop_font(ctx, t)
  theme.pop(ctx)
  if open then reaper.defer(loop) end
end

reaper.defer(loop)
