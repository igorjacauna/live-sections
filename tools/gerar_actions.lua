-- Gera os scripts de LiveSections/actions/, um por ação do RF-037.
-- Rode da raiz do repositório: lua tools/gerar_actions.lua
-- Os scripts antigos com o prefixo "Live Sections - " são apagados antes.

local DIR = "LiveSections/actions/"
local SLOTS, SONGS, LAYERS, STEMS = 16, 16, 8, 8

local QUANTIZE = {
  { "now", "Imediato" }, { "beat", "Batida" }, { "bar", "1 compasso" }, { "2bar", "2 compassos" },
  { "4bar", "4 compassos" }, { "8bar", "8 compassos" }, { "section_end", "Fim da seção" },
}

local list = {
  { "Próxima seção", "next_section" }, { "Seção anterior", "prev_section" },
  { "Próxima música", "next_song" }, { "Música anterior", "prev_song" },
  { "Loop liga-desliga", "toggle_loop" }, { "Play-Stop", "play_stop" },
  { "Play", "play" }, { "Stop", "stop" },
  { "Cancelar fila", "cancel" }, { "Panic", "panic" },
  { "Quantize próximo", "cycle_quantize", 1 }, { "Quantize anterior", "cycle_quantize", -1 },
  { "Setlist abrir-fechar", "toggle_setlist" }, { "Tap tempo", "tap_tempo" },
}
for i = 1, SLOTS do list[#list + 1] = { string.format("Disparar seção %02d", i), "trigger_slot", i } end
for i = 1, SONGS do list[#list + 1] = { string.format("Ir para música %02d", i), "goto_song", i } end
for _, q in ipairs(QUANTIZE) do list[#list + 1] = { "Quantize " .. q[2], "set_quantize", q[1] } end
for i = 1, LAYERS do
  list[#list + 1] = { string.format("Camada %d volume (CC)", i), "layer_volume", i }
  list[#list + 1] = { string.format("Camada %d liga-desliga", i), "layer_mute", i }
end
for i = 1, STEMS do
  list[#list + 1] = { string.format("Multitrack %d volume (CC)", i), "stem_volume", i }
  list[#list + 1] = { string.format("Multitrack %d liga-desliga", i), "stem_mute", i }
end

local TEMPLATE = [[
-- Live Sections: %s
-- Envia o comando para a janela do Live Sections aberta.
local _, path = reaper.get_action_context()
package.path = path:match("^(.*[/\\])") .. "?.lua;" .. package.path
require("remote").run_action(%q%s)
]]

os.execute("rm -f '" .. DIR .. "Live Sections - '*.lua")
for _, a in ipairs(list) do
  local arg = a[3] == nil and "" or (", " .. (type(a[3]) == "string" and string.format("%q", a[3]) or tostring(a[3])))
  local f = assert(io.open(DIR .. "Live Sections - " .. a[1] .. ".lua", "w"))
  f:write(TEMPLATE:format(a[1], a[2], arg))
  f:close()
end
print(#list .. " actions geradas em " .. DIR)
