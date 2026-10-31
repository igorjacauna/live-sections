-- Live Sections: Quantize Imediato
-- Envia o comando para a janela do Live Sections aberta.
local _, path = reaper.get_action_context()
package.path = path:match("^(.*[/\\])") .. "?.lua;" .. package.path
require("remote").run_action("set_quantize", "now")
