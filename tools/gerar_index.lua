-- Gera o index.xml do ReaPack com todos os arquivos de LiveSections/.
-- Rode da raiz do repositório:
--   lua tools/gerar_index.lua [URL base] [versão] [arquivo de saída]
-- A versão padrão vem do arquivo VERSION e as notas, de CHANGELOG.txt.
-- O ReaPack só atualiza quem já instalou quando a versão muda.
-- Sem URL base, usa file:// deste repositório (instalação local para teste).
-- Para publicar, passe a URL "raw" da pasta do repositório, por exemplo
-- https://raw.githubusercontent.com/<usuário>/live-sections/main
--
-- O ReaPack não declara dependência de outro pacote: a ReaImGui fica na
-- descrição, e o script mostra como instalá-la quando ela falta (RF-100).

local base = arg[1]
local function read(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local t = f:read("a")
  f:close()
  return t
end
local version = arg[2] or (read("VERSION") or "0.1.0"):gsub("%s+", "")
-- a janela mostra a versão de LiveSections/version.lua: as duas andam juntas
local shown = (read("LiveSections/version.lua") or ""):match('return "([^"]+)"')
if shown ~= version then
  io.stderr:write(string.format("LiveSections/version.lua (%s) difere da versão publicada (%s)\n", tostring(shown), version))
  os.exit(1)
end
local changelog = read("CHANGELOG.txt")
local output = arg[3] or "index.xml"
if not base then
  local p = io.popen("pwd")
  base = "file://" .. p:read("l")
  p:close()
end
base = base:gsub("/$", "")

local AUTHOR = "Igor Jacaúna"
local SITE = "https://live-sections.igor-jacauna-cloudflare.workers.dev"
local DESC = [[Performance ao vivo por seções no REAPER, no estilo do Ableton: cada música começa num marcador SONG:, as regiões são as seções, saltos com quantize e fila cancelável, loop de seção, um Kontakt por música com camadas e faders, MIDI learn com LEDs e modo palco.

Software livre sob a licença GPL-3.0. Requer a extensão ReaImGui, do repositório ReaTeam Extensions (já vem no ReaPack): Extensions > ReaPack > Browse packages > ReaImGui > Install.]]

local WEB_DESC = [[Página da Web Interface do REAPER que mostra no celular ou tablet a música, a seção e a cifra acompanhando o compasso, publicadas pelo Live Sections.

Ative em Preferences > Control/OSC/web > Add > Web browser interface, escolha "livesections.html" como página padrão e abra o endereço mostrado no celular (mesma rede Wi-Fi).]]

local function xml(s)
  return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

local function url_path(path)
  return (path:gsub("[^%w%-%._~/()]", function(c) return string.format("%%%02X", c:byte()) end))
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
w('        <link rel="website">' .. SITE .. '</link>')
w('        <link rel="website">https://github.com/igorjacauna/live-sections</link>')
w('      </metadata>')
w(string.format('      <version name="%s" author="%s" time="%s">', version, xml(AUTHOR), os.date("!%Y-%m-%dT%H:%M:%SZ")))
if changelog then w('        <changelog><![CDATA[' .. changelog .. ']]></changelog>') end
local web = {}
for _, f in ipairs(files) do
  if f:match("^www/") then
    web[#web + 1] = f
  else
    -- o script principal e as actions entram na lista de actions do REAPER
    local main = (f == "LiveSections.lua" or f:match("^actions/Live Sections %- ")) and ' main="main"' or ""
    w(string.format('        <source file="%s"%s>%s/LiveSections/%s</source>', xml(f), main, base, url_path(f)))
  end
end
w('      </version>')
w('    </reapack>')
-- página de cifra para celular/tablet: vai para a pasta da Web Interface
w('    <reapack name="livesections.html" type="webinterface" desc="Live Sections: cifra no celular">')
w('      <metadata>')
w('        <description><![CDATA[' .. WEB_DESC .. ']]></description>')
w('      </metadata>')
w(string.format('      <version name="%s" author="%s" time="%s">', version, xml(AUTHOR), os.date("!%Y-%m-%dT%H:%M:%SZ")))
if changelog then w('        <changelog><![CDATA[' .. changelog .. ']]></changelog>') end
-- a URL leva ".txt": a Cloudflare redireciona ".html" para o endereço sem
-- extensão (307); o nome instalado vem de file="…", não da URL
for _, f in ipairs(web) do
  w(string.format('        <source file="%s">%s/LiveSections/%s.txt</source>', xml(f:gsub("^www/", "")), base, url_path(f)))
end
w('      </version>')
w('    </reapack>')
w('  </category>')
w('</index>')

local fh = assert(io.open(output, "w"))
fh:write(table.concat(out, "\n") .. "\n")
fh:close()
print(#files .. " arquivos em " .. output .. " (" .. base .. ")")
