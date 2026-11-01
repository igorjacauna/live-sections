-- Anotação curta de cada música: o tom, como começa a intro, uma dica de
-- melodia. Aparece no Performance, no Palco, na janela de cifra e no
-- celular.
--
-- Fica no projeto: ProjExtState("LiveSections", "note:<GUID do marcador
-- SONG:>"), como a cifra.
--
-- M.get(song) -> texto ("" quando não tem)
-- M.set(song, text) -> ok, err
-- M.lines(text) -> linhas não vazias, sem espaços nas pontas

local chart = require("core.chart")

local M = {}

local KEY_PREFIX = "note:"
M.MAX_CHARS = 300

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

function M.get(song) return trim(chart.song_value(song, KEY_PREFIX)) end

function M.set(song, text)
  text = trim(text or "")
  if #text > M.MAX_CHARS then text = text:sub(1, M.MAX_CHARS):gsub("[\xC0-\xFF][\x80-\xBF]*$", "") end
  return chart.set_song_value(song, KEY_PREFIX, text)
end

function M.lines(text)
  local out = {}
  for line in ((text or "") .. "\n"):gmatch("(.-)\r?\n") do
    line = trim(line)
    if line ~= "" then out[#out + 1] = line end
  end
  return out
end

return M
