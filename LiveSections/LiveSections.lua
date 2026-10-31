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

local ctx = ImGui.CreateContext(APP_NAME)
local fonts_ok = theme.init(ctx, ImGui, script_dir())

-- Amostra do tema (task 4.1) até as telas existirem: tipografia e estados.
local function preview()
  local t = theme.font(ctx, "label")
  ImGui.TextColored(ctx, theme.C.muted, "MÚSICA ATUAL")
  theme.pop_font(ctx, t)
  t = theme.font(ctx, "h1")
  ImGui.Text(ctx, APP_NAME)
  theme.pop_font(ctx, t)
  t = theme.font(ctx, "readout")
  ImGui.TextColored(ctx, theme.C.text, "96 BPM · 4/4 · 12.3")
  theme.pop_font(ctx, t)
  if not fonts_ok then ImGui.TextColored(ctx, theme.C.danger, "Fontes do pacote não encontradas") end

  local dl = ImGui.GetWindowDrawList(ctx)
  local pulse = anim.pulse(reaper.time_precise(), 1)
  for _, state in ipairs({ "playing", "queued", "loop", "error" }) do
    local s = theme.STATE[state]
    local x, y = ImGui.GetCursorScreenPos(ctx)
    local color = state == "queued" and theme.mix(theme.C.faint, s.color, pulse) or s.color
    theme.icon(dl, s.icon, x, y + 2, 16, color)
    ImGui.SetCursorScreenPos(ctx, x + 24, y)
    t = theme.font(ctx, "label")
    ImGui.TextColored(ctx, s.color, s.label:upper())
    theme.pop_font(ctx, t)
  end
end

local function loop()
  theme.push(ctx)
  local t = theme.font(ctx, "body")
  local visible, open = ImGui.Begin(ctx, APP_NAME, true)
  if visible then
    preview()
    ImGui.End(ctx)
  end
  theme.pop_font(ctx, t)
  theme.pop(ctx)
  if open then reaper.defer(loop) end
end

reaper.defer(loop)
