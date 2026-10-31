-- Gera o index.xml do ReaPack com todos os arquivos de LiveSections/.
-- Rode da raiz do repositório:
--   lua tools/gerar_index.lua [URL base] [versão]
-- Sem URL base, usa file:// deste repositório (instalação local para teste).
-- Para publicar, passe a URL "raw" da pasta do repositório, por exemplo
-- https://raw.githubusercontent.com/<usuário>/live-sections/main
--
-- O ReaPack não declara dependência de outro pacote: a ReaImGui fica na
-- descrição, e o script mostra como instalá-la quando ela falta (RF-100).

local base = arg[1]
local version = arg[2] or "0.1.0"
if not base then
  local p = io.popen("pwd")
  base = "file://" .. p:read("l")
  p:close()
end
base = base:gsub("/$", "")

local AUTHOR = "Igor Jacaúna"
local DESC = [[Performance ao vivo por seções no REAPER, no estilo do Ableton: cada música começa num marcador SONG:, as regiões são as seções, saltos com quantize e fila cancelável, loop de seção, um Kontakt por música com camadas e faders, MIDI learn com LEDs e modo palco.

Requer a extensão ReaImGui, do repositório ReaTeam Extensions (já vem no ReaPack): Extensions > ReaPack > Browse packages > ReaImGui > Install.]]

local function xml(s)
  return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

local function url_path(path)
  return (path:gsub("[^%w%-%._~/]", function(c) return string.format("%%%02X", c:byte()) end))
end

local files = {}
local p = io.popen("cd LiveSections && find . -type f ! -name '.*' | sort")
for line in p:lines() do files[#files + 1] = line:gsub("^%./", "") end
p:close()

local out = {}
local function w(s) out[#out + 1] = s end
w('<?xml version="1.0" encoding="utf-8"?>')
w('<index version="1" name="Live Sections">')
w('  <category name="Performance">')
w('    <reapack name="LiveSections.lua" type="script" desc="Live Sections">')
w('      <metadata>')
w('        <description><![CDATA[' .. DESC .. ']]></description>')
w('        <link rel="website">https://github.com/ReaTeam/Extensions</link>')
w('      </metadata>')
w(string.format('      <version name="%s" author="%s" time="%s">', version, xml(AUTHOR), os.date("!%Y-%m-%dT%H:%M:%SZ")))
for _, f in ipairs(files) do
  -- o script principal e as actions entram na lista de actions do REAPER
  local main = (f == "LiveSections.lua" or f:match("^actions/Live Sections %- ")) and ' main="main"' or ""
  w(string.format('        <source file="%s"%s>%s/LiveSections/%s</source>', xml(f), main, base, url_path(f)))
end
w('      </version>')
w('    </reapack>')
w('  </category>')
w('</index>')

local fh = assert(io.open("index.xml", "w"))
fh:write(table.concat(out, "\n") .. "\n")
fh:close()
print(#files .. " arquivos no index.xml (" .. base .. ")")
