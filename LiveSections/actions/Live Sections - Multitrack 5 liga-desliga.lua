-- Live Sections: Multitrack 5 liga-desliga
-- Envia o comando para a janela do Live Sections aberta.
local _, path = reaper.get_action_context()
package.path = path:match("^(.*[/\\])") .. "?.lua;" .. package.path
require("remote").run_action("stem_mute", 5)
