-- Live Sections: Ir para música 13
-- Envia o comando para a janela do Live Sections aberta.
local _, path = reaper.get_action_context()
package.path = path:match("^(.*[/\\])") .. "?.lua;" .. package.path
require("remote").run_action("goto_song", 13)
